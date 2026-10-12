#!/usr/bin/env python3
"""Batch-bootstrap RBAC users from empty_user_id_bop_user_ids_prod.csv via internal API.

Calls POST utils/bootstrap_users_from_user_ids/ in batches (default 50),
prints progress, and sleeps between batches.

Requires SESSION in the environment (Turnpike session cookie) and
STAGE_DOMAIN / PROD_DOMAIN / PROXY in .cursor/skills/config.env.
"""

from __future__ import annotations

import argparse
import csv
import hashlib
import json
import os
import re
import subprocess
import sys
import time
from pathlib import Path

ROOT = Path(__file__).resolve().parents[4]
CONFIG_ENV = ROOT / ".cursor/skills/config.env"
INTERNAL_API_SH = Path(__file__).resolve().parent / "internal-api.sh"
DEFAULT_INPUT = ROOT / "empty_user_id_bop_user_ids_prod.csv"

# Defaults are resolved after arg parsing so they can incorporate --env and --dry-run;
# see _resolve_output_defaults().  These constants are only used as argparse sentinels.
_SENTINEL_RESULTS = None
_SENTINEL_PROGRESS = None
_SENTINEL_RETRY = None


def _resolve_output_defaults(args: argparse.Namespace) -> None:
    """Fill in env/mode-aware default paths for any output arg the user did not override."""
    dry_tag = "_dry" if args.dry_run else ""
    if args.results_out is None:
        args.results_out = ROOT / f"empty_user_id_bootstrap_results_{args.env}{dry_tag}.csv"
    if args.progress is None:
        args.progress = ROOT / f"empty_user_id_bootstrap_progress_{args.env}.json"
    if args.retry_out is None:
        args.retry_out = ROOT / f"empty_user_id_bootstrap_retry_{args.env}{dry_tag}.txt"


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


def read_user_ids(path: Path, *, active_only: bool) -> list[str]:
    """Read deduplicated user IDs from a CSV file, optionally filtering to active rows."""
    user_ids: list[str] = []
    seen: set[str] = set()
    with path.open() as f:
        reader = csv.DictReader(f)
        for row in reader:
            uid = (row.get("user_id") or "").strip()
            if not uid or uid in seen:
                continue
            if active_only and str(row.get("is_active", "")).lower() not in ("true", "1", "yes"):
                continue
            seen.add(uid)
            user_ids.append(uid)
    return user_ids


def compute_progress_fingerprint(env: str, input_path: Path, active_only: bool) -> str:
    """Compute a fingerprint tying progress to the current run parameters."""
    key = f"{env}|{input_path.resolve()}|{active_only}"
    return hashlib.md5(key.encode()).hexdigest()[:12]


def read_progress(path: Path, fingerprint: str) -> int:
    """Read the saved batch offset, returning 0 if absent or fingerprint mismatches."""
    if not path.exists():
        return 0
    text = path.read_text().strip()
    if not text:
        return 0
    try:
        data = json.loads(text)
        if data.get("fingerprint") != fingerprint:
            return 0
        return int(data.get("offset", 0))
    except (json.JSONDecodeError, ValueError):
        return 0


def write_progress(path: Path, offset: int, fingerprint: str) -> None:
    """Persist the current batch offset with a fingerprint for run-parameter validation."""
    path.write_text(json.dumps({"offset": offset, "fingerprint": fingerprint}))


def bootstrap_batch(
    env_name: str,
    session: str,
    user_ids: list[str],
    *,
    dry_run: bool,
    retries: int = 5,
    retry_sleep: float = 5.0,
) -> dict:
    """Call internal-api.sh so auth/proxy match the existing skill scripts."""
    cmd = [
        "sh",
        str(INTERNAL_API_SH),
        env_name,
        "POST",
        "utils/bootstrap_users_from_user_ids/",
    ]
    if dry_run:
        cmd.append("dry_run=true")
    cmd.append(json.dumps({"user_ids": user_ids}))

    env = os.environ.copy()
    env["SESSION"] = session
    # Avoid inheriting a broken proxy for prod (internal-api.sh handles stage proxy itself).
    for key in ("HTTP_PROXY", "HTTPS_PROXY", "http_proxy", "https_proxy", "ALL_PROXY", "all_proxy"):
        env.pop(key, None)

    last_err = ""
    for attempt in range(1, retries + 1):
        result = subprocess.run(cmd, capture_output=True, text=True, cwd=str(ROOT), env=env)
        if result.returncode == 0:
            out = result.stdout.strip()
            start = out.find("{")
            if start < 0:
                raise RuntimeError(f"No JSON in internal-api response: {out[:500]!r}")
            raw = out[start:]
            # BOP usernames can embed raw control chars; strip Cc chars that break json.loads.
            cleaned = re.sub(r"[\x00-\x08\x0b\x0c\x0e-\x1f]", "", raw)
            try:
                return json.loads(cleaned)
            except json.JSONDecodeError as err:
                raise RuntimeError(f"Invalid JSON from API: {err}; body[:300]={cleaned[:300]!r}") from err

        last_err = (result.stderr or result.stdout)[:800]
        transient = any(
            token in last_err
            for token in (
                "Connection reset",
                "Failed to connect",
                "Could not resolve",
                "timed out",
                "Empty reply",
                "TLS",
                "HTTP 502",
                "HTTP 503",
                "HTTP 504",
            )
        )
        if not transient or attempt >= retries:
            break
        print(
            f"  transient error (attempt {attempt}/{retries}), sleeping {retry_sleep}s: {last_err.strip()}",
            flush=True,
        )
        time.sleep(retry_sleep * attempt)

    raise RuntimeError(f"internal-api.sh failed: {last_err}")


def main() -> int:
    """Parse arguments, process user IDs in batches, and write results to CSV."""
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--env", choices=("stage", "prod"), default="prod")
    parser.add_argument("--input", type=Path, default=DEFAULT_INPUT)
    parser.add_argument("--results-out", type=Path, default=_SENTINEL_RESULTS)
    parser.add_argument("--retry-out", type=Path, default=_SENTINEL_RETRY)
    parser.add_argument("--progress", type=Path, default=_SENTINEL_PROGRESS)
    parser.add_argument("--batch-size", type=int, default=50)
    parser.add_argument("--sleep", type=float, default=1.0, help="Seconds to pause between batches")
    parser.add_argument("--max-batches", type=int, default=0, help="0 = no limit")
    parser.add_argument("--dry-run", action="store_true", help="Pass dry_run=true to the API")
    parser.add_argument("--reset", action="store_true", help="Ignore progress and rewrite results")
    parser.add_argument(
        "--active-only",
        action=argparse.BooleanOptionalAction,
        default=True,
        help="Only bootstrap rows with is_active=True (default: true)",
    )
    args = parser.parse_args()
    _resolve_output_defaults(args)

    cfg = load_config_env(CONFIG_ENV)
    session = os.environ.get("SESSION") or cfg.get("SESSION")
    if not session:
        print("SESSION is not set (export SESSION=... or put it in config.env)", file=sys.stderr)
        return 1

    if not args.input.exists():
        print(f"Input file not found: {args.input}", file=sys.stderr)
        return 1

    user_ids = read_user_ids(args.input, active_only=args.active_only)
    fingerprint = compute_progress_fingerprint(args.env, args.input, args.active_only)
    # Dry runs never resume from a live checkpoint — always start from offset 0.
    start = 0 if (args.reset or args.dry_run) else read_progress(args.progress, fingerprint)
    if start > len(user_ids):
        start = len(user_ids)

    mode = "w" if args.reset or start == 0 else "a"
    # Only delete output files on explicit --reset and never during a dry run.
    # mode="w" already truncates on first write, so deletion at start==0 is
    # unnecessary and previously caused cross-env/cross-mode data loss.
    if args.reset and not args.dry_run:
        for path in (args.results_out, args.progress, args.retry_out):
            if path.exists():
                path.unlink()

    print(
        f"Loaded {len(user_ids)} user_ids (active_only={args.active_only}); "
        f"starting at offset {start}; batch_size={args.batch_size}; "
        f"sleep={args.sleep}s; dry_run={args.dry_run}; env={args.env}",
        flush=True,
    )

    status_counts: dict[str, int] = {}
    batches = 0

    with args.results_out.open(mode, newline="") as out_f:
        writer = csv.DictWriter(
            out_f,
            fieldnames=["user_id", "status", "username", "org_id", "detail", "tenant_ready", "is_org_admin"],
            extrasaction="ignore",
        )
        if mode == "w":
            writer.writeheader()

        offset = start
        while offset < len(user_ids):
            if args.max_batches and batches >= args.max_batches:
                print(f"Stopping early after {batches} batches (--max-batches)", flush=True)
                break

            batch = user_ids[offset : offset + args.batch_size]
            batch_num = batches + 1
            print(
                f"[batch {batch_num}] offset={offset}/{len(user_ids)} "
                f"({100.0 * offset / len(user_ids):.1f}%) size={len(batch)} ...",
                flush=True,
            )

            try:
                payload = bootstrap_batch(
                    args.env,
                    session,
                    batch,
                    dry_run=args.dry_run,
                )
            except Exception as err:  # noqa: BLE001
                err_text = str(err)
                if "Invalid JSON" in err_text and len(batch) > 1:
                    print(
                        f"  batch JSON parse failed; falling back to per-user_id for offset {offset}: {err}",
                        flush=True,
                    )
                    results = []
                    for uid in batch:
                        try:
                            single = bootstrap_batch(
                                args.env,
                                session,
                                [uid],
                                dry_run=args.dry_run,
                            )
                            results.extend(single.get("results", []))
                        except Exception as single_err:  # noqa: BLE001
                            print(f"  per-user failure user_id={uid}: {single_err}", file=sys.stderr)
                            results.append(
                                {
                                    "user_id": uid,
                                    "status": "error",
                                    "detail": str(single_err)[:300],
                                }
                            )
                        if args.sleep > 0:
                            time.sleep(min(args.sleep, 0.2))
                    payload = {"results": results}
                else:
                    print(f"Error at offset {offset}: {err}", file=sys.stderr)
                    if not args.dry_run:
                        write_progress(args.progress, offset, fingerprint)
                    return 1

            results = payload.get("results", [])
            failed_ids: list[str] = []
            for item in results:
                status = item.get("status", "unknown")
                status_counts[status] = status_counts.get(status, 0) + 1
                writer.writerow(
                    {
                        "user_id": item.get("user_id", ""),
                        "status": status,
                        "username": item.get("username", ""),
                        "org_id": item.get("org_id", ""),
                        "detail": item.get("detail", ""),
                        "tenant_ready": item.get("tenant_ready", ""),
                        "is_org_admin": item.get("is_org_admin", ""),
                    }
                )
                if status == "error":
                    uid = item.get("user_id", "")
                    if uid:
                        failed_ids.append(uid)
            out_f.flush()

            # Write failed IDs to retry file as CSV so the file can be passed
            # back as --input to read_user_ids (which expects a CSV header).
            if failed_ids:
                write_header = not args.retry_out.exists() or args.retry_out.stat().st_size == 0
                with args.retry_out.open("a", newline="") as retry_f:
                    retry_writer = csv.DictWriter(retry_f, fieldnames=["user_id", "is_active"])
                    if write_header:
                        retry_writer.writeheader()
                    for uid in failed_ids:
                        retry_writer.writerow({"user_id": uid, "is_active": "true"})
                print(
                    f"  {len(failed_ids)} failed user_id(s) written to {args.retry_out}",
                    flush=True,
                )

            offset += len(batch)
            batches += 1
            # Do not advance the live checkpoint during dry runs.
            if not args.dry_run:
                write_progress(args.progress, offset, fingerprint)

            print(
                f"[batch {batch_num}] done -> offset={offset}/{len(user_ids)} "
                f"({100.0 * offset / len(user_ids):.1f}%) "
                f"session_status_counts={status_counts}",
                flush=True,
            )

            if offset < len(user_ids) and args.sleep > 0:
                time.sleep(args.sleep)

    print(
        f"DONE offset={offset}/{len(user_ids)} status_counts={status_counts}\n" f"results -> {args.results_out}",
        flush=True,
    )
    if args.retry_out.exists():
        print(f"retry  -> {args.retry_out}", flush=True)
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
