#!/usr/bin/env python3
"""Batch-lookup BOP user_ids for usernames with empty RBAC user_id.

Reads usernames from empty_user_id_usernames_prod.txt (one per line), queries
BOP /v1/users in batches, and writes found mappings to a CSV.

Credentials are loaded from .cursor/skills/config.env:
  bop_prod_dns=...
  apitoken=...

Optional env overrides:
  BOP_PROD_DNS, BOP_APITOKEN, HTTPS_PROXY / PROXY
"""

from __future__ import annotations

import argparse
import csv
import json
import os
import ssl
import sys
import time
import urllib.error
import urllib.request
from pathlib import Path

ROOT = Path(__file__).resolve().parents[4]
DEFAULT_INPUT = ROOT / "empty_user_id_usernames_prod.txt"
DEFAULT_FOUND = ROOT / "empty_user_id_bop_user_ids_prod.csv"
DEFAULT_MISSING = ROOT / "empty_user_id_bop_not_found_prod.txt"
DEFAULT_PROGRESS = ROOT / "empty_user_id_bop_lookup_progress.txt"
CONFIG_ENV = ROOT / ".cursor/skills/config.env"


def load_config_env(path: Path) -> dict[str, str]:
    """Load key=value pairs from a config.env file, ignoring comments and blanks."""
    values: dict[str, str] = {}
    if not path.exists():
        return values
    for raw in path.read_text().splitlines():
        line = raw.strip()
        if not line or line.startswith("#") or "=" not in line:
            continue
        key, _, value = line.partition("=")
        values[key.strip()] = value.strip().strip('"').strip("'")
    return values


def build_opener(proxy: str | None, *, insecure: bool):
    """Build a urllib opener with optional proxy and TLS verification settings."""
    handlers: list = []
    if proxy:
        handlers.append(urllib.request.ProxyHandler({"http": proxy, "https": proxy}))
    else:
        handlers.append(urllib.request.ProxyHandler({}))
    if insecure:
        ctx = ssl._create_unverified_context()
        handlers.append(urllib.request.HTTPSHandler(context=ctx))
    return urllib.request.build_opener(*handlers)


def query_bop(
    opener,
    host: str,
    apitoken: str,
    usernames: list[str],
    *,
    timeout: float,
) -> list[dict]:
    """Query the BOP /v1/users endpoint for the given usernames and return user records."""
    url = (
        f"https://{host}/v1/users"
        "?include_permissions=false"
        "&queryBy=principal"
        "&status=all"
        "&admin_only=false"
        f"&offset=0&limit={len(usernames)}"
        "&sortBy=principal"
    )
    body = json.dumps({"users": usernames}).encode("utf-8")
    req = urllib.request.Request(
        url,
        data=body,
        method="POST",
        headers={
            "accept": "application/json",
            "Content-Type": "application/json",
            "x-rh-apitoken": apitoken,
            "x-rh-clientid": "insights-rbac",
            "x-rh-insights-env": "prod",
        },
    )
    with opener.open(req, timeout=timeout) as resp:
        payload = json.loads(resp.read().decode("utf-8"))
    if isinstance(payload, dict):
        users = payload.get("users", [])
    elif isinstance(payload, list):
        users = payload
    else:
        raise RuntimeError(f"Unexpected BOP response type: {type(payload)}")
    return users


def read_usernames(path: Path) -> list[str]:
    """Read non-empty usernames from a text file, one per line."""
    names: list[str] = []
    with path.open() as f:
        for line in f:
            name = line.strip()
            if name:
                names.append(name)
    return names


def read_progress(path: Path) -> int:
    """Read the saved batch offset from a progress file, returning 0 if absent."""
    if not path.exists():
        return 0
    text = path.read_text().strip()
    return int(text) if text else 0


def write_progress(path: Path, offset: int) -> None:
    """Persist the current batch offset to the progress file."""
    path.write_text(str(offset))


def main() -> int:
    """Look up BOP user IDs for usernames with empty RBAC user_id in batches."""
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--input", type=Path, default=DEFAULT_INPUT)
    parser.add_argument("--found-out", type=Path, default=DEFAULT_FOUND)
    parser.add_argument("--missing-out", type=Path, default=DEFAULT_MISSING)
    parser.add_argument("--progress", type=Path, default=DEFAULT_PROGRESS)
    parser.add_argument("--batch-size", type=int, default=100)
    parser.add_argument("--sleep", type=float, default=0.05, help="Seconds between batches")
    parser.add_argument("--timeout", type=float, default=60.0)
    parser.add_argument("--max-batches", type=int, default=0, help="0 = no limit (useful for dry runs)")
    parser.add_argument("--reset", action="store_true", help="Ignore progress and rewrite outputs")
    parser.add_argument(
        "--insecure",
        action="store_true",
        help="Disable TLS certificate verification (needed behind some corp proxies)",
    )
    args = parser.parse_args()

    cfg = load_config_env(CONFIG_ENV)
    host = os.environ.get("BOP_PROD_DNS") or cfg.get("bop_prod_dns")
    apitoken = os.environ.get("BOP_APITOKEN") or cfg.get("apitoken")
    proxy = os.environ.get("HTTPS_PROXY") or os.environ.get("HTTP_PROXY") or cfg.get("PROXY")

    if not host or not apitoken:
        print("Missing bop_prod_dns / apitoken in config.env (or BOP_PROD_DNS / BOP_APITOKEN)", file=sys.stderr)
        return 1
    if not args.input.exists():
        print(f"Input file not found: {args.input}", file=sys.stderr)
        return 1

    usernames = read_usernames(args.input)
    start = 0 if args.reset else read_progress(args.progress)
    if start > len(usernames):
        start = len(usernames)

    mode = "w" if args.reset or start == 0 else "a"
    if args.reset or start == 0:
        for path in (args.found_out, args.missing_out, args.progress):
            if path.exists():
                path.unlink()

    opener = build_opener(proxy, insecure=args.insecure)
    print(
        f"Loaded {len(usernames)} usernames; starting at offset {start}; "
        f"batch_size={args.batch_size}; host={host}; proxy={'yes' if proxy else 'no'}; "
        f"insecure={args.insecure}",
        flush=True,
    )

    found_total = 0
    missing_total = 0
    batches = 0

    with args.found_out.open(mode, newline="") as found_f, args.missing_out.open(mode) as missing_f:
        writer = csv.writer(found_f)
        if mode == "w":
            writer.writerow(["username", "user_id", "org_id", "is_active", "is_org_admin", "email"])

        offset = start
        while offset < len(usernames):
            if args.max_batches and batches >= args.max_batches:
                print(f"Stopping early after {batches} batches (--max-batches)", flush=True)
                break

            batch = usernames[offset : offset + args.batch_size]
            try:
                users = query_bop(opener, host, apitoken, batch, timeout=args.timeout)
            except urllib.error.HTTPError as err:
                body = err.read().decode("utf-8", errors="replace")
                print(f"HTTP {err.code} at offset {offset}: {body[:500]}", file=sys.stderr)
                write_progress(args.progress, offset)
                return 1
            except Exception as err:  # noqa: BLE001 - surface and stop so progress is saved
                print(f"Error at offset {offset}: {err}", file=sys.stderr)
                write_progress(args.progress, offset)
                return 1

            by_lower = {}
            for user in users:
                uname = user.get("username")
                if not uname:
                    continue
                by_lower[uname.lower()] = user

            for requested in batch:
                user = by_lower.get(requested.lower())
                if not user or user.get("id") in (None, ""):
                    missing_f.write(requested + "\n")
                    missing_total += 1
                    continue
                writer.writerow(
                    [
                        requested,
                        user.get("id"),
                        user.get("org_id", ""),
                        user.get("is_active", ""),
                        user.get("is_org_admin", ""),
                        user.get("email", ""),
                    ]
                )
                found_total += 1

            offset += len(batch)
            batches += 1
            write_progress(args.progress, offset)
            found_f.flush()
            missing_f.flush()

            if batches % 10 == 0 or offset >= len(usernames):
                print(
                    f"progress offset={offset}/{len(usernames)} "
                    f"({100.0 * offset / len(usernames):.1f}%) "
                    f"batch_found~ recent batches logged; "
                    f"session_found={found_total} session_missing={missing_total}",
                    flush=True,
                )

            if args.sleep:
                time.sleep(args.sleep)

    print(
        f"DONE offset={offset}/{len(usernames)} "
        f"session_found={found_total} session_missing={missing_total}\n"
        f"found -> {args.found_out}\n"
        f"missing -> {args.missing_out}",
        flush=True,
    )
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
