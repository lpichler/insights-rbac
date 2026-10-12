#!/usr/bin/env python3
"""Export usernames of non-cross-account user principals with empty user_id."""

from __future__ import annotations

import json
import os
import subprocess
import sys
from pathlib import Path

ROOT = Path(__file__).resolve().parents[4]  # insights-rbac/
OUT = ROOT / "empty_user_id_usernames_prod.txt"
BATCH = 5000


def run_gabi(sql: str) -> dict:
    """Execute a SQL query via gabi.sh and return the parsed JSON result."""
    result = subprocess.run(
        ["sh", str(ROOT / ".cursor/skills/gabi/scripts/gabi.sh"), "prod", sql],
        capture_output=True,
        text=True,
        cwd=str(ROOT),
        env=os.environ.copy(),
    )
    out = result.stdout
    if result.returncode != 0:
        raise RuntimeError(
            f"gabi.sh failed rc={result.returncode} stderr={result.stderr[-800:]!r} stdout={out[:500]!r}"
        )
    start = out.find("{")
    if start < 0:
        raise RuntimeError(f"No JSON from gabi. stderr={result.stderr[-800:]!r} stdout={out[:500]!r}")
    data = json.loads(out[start:])
    if data.get("error"):
        raise RuntimeError(f"SQL error: {data['error']}")
    return data


def main() -> int:
    """Export usernames of principals with empty user_id to a text file."""
    if not os.environ.get("TOKEN"):
        print("TOKEN is not set", file=sys.stderr)
        return 1

    last_id = 0
    total = 0
    with OUT.open("w") as f:
        while True:
            sql = (
                "SELECT id, username FROM management_principal "
                "WHERE type = 'user' "
                "AND (user_id IS NULL OR user_id = '') "
                "AND (cross_account IS NULL OR cross_account = false) "
                f"AND id > {last_id} "
                "ORDER BY id "
                f"LIMIT {BATCH}"
            )
            rows = run_gabi(sql)["result"][1:]
            if not rows:
                break
            for pid, username in rows:
                f.write(f"{username}\n")
                last_id = int(pid)
                total += 1
            print(f"fetched {len(rows)}, total={total}, last_id={last_id}", flush=True)
            if len(rows) < BATCH:
                break

    print(f"DONE total={total} file={OUT}")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
