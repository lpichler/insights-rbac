#!/bin/bash
# Wrapper so BOP lookup can run with the same network path as other skill scripts.
set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT="$(cd "${SCRIPT_DIR}/../../../.." && pwd)"
CONFIG_FILE="${SCRIPT_DIR}/../../config.env"

if [ -f "$CONFIG_FILE" ]; then
  # shellcheck disable=SC1090
  source "$CONFIG_FILE"
fi

if [ -n "${PROXY:-}" ]; then
  export HTTPS_PROXY="$PROXY"
  export HTTP_PROXY="$PROXY"
fi

cd "$ROOT"
exec python3 "${SCRIPT_DIR}/lookup_bop_user_ids.py" "$@"
