#!/bin/bash
# Batch bootstrap users from empty_user_id_bop_user_ids_prod.csv
set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
CONFIG_FILE="${SCRIPT_DIR}/../../config.env"
ROOT="$(cd "${SCRIPT_DIR}/../../../.." && pwd)"

if [ -f "$CONFIG_FILE" ]; then
  # shellcheck disable=SC1090
  source "$CONFIG_FILE"
fi

if [ -z "${SESSION:-}" ]; then
  echo "Error: SESSION is not set. Put it in config.env or: export SESSION=..."
  exit 1
fi
export SESSION

cd "$ROOT"
exec python3 "${SCRIPT_DIR}/bootstrap_users_from_csv.py" "$@"
