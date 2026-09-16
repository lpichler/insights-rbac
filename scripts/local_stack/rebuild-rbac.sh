#!/usr/bin/env bash
# Rebuild the current local RBAC image and recreate only RBAC services.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "${SCRIPT_DIR}/../.." && pwd)"
# shellcheck source=../common/logging.sh
source "${SCRIPT_DIR}/../common/logging.sh"
# shellcheck source=../common/container_runtime.sh
source "${SCRIPT_DIR}/../common/container_runtime.sh"
# shellcheck source=prepare-full-kessel-configs.sh
source "${SCRIPT_DIR}/prepare-full-kessel-configs.sh"

INVENTORY_API_REPO="${INVENTORY_API_REPO:-${KESSEL_REPO:-}}"
RBAC_IMAGE="${RBAC_IMAGE:-insights-rbac-local:dev}"
COMPOSE_PULL_MODE="${COMPOSE_PULL_MODE:-missing}"
RBAC_OVERRIDE_FILE="${REPO_ROOT}/scripts/local_stack/full-kessel.rbac-override.yml"

usage() {
  cat <<'EOF'
Usage: rebuild-rbac.sh

Build the current checkout and recreate only rbac-migrate, rbac-server,
rbac-worker, and rbac-scheduler in the local full-kessel stack.

Environment:
  INVENTORY_API_REPO  Path to the inventory-api checkout
  RBAC_IMAGE          Image tag for the rebuilt RBAC services
  COMPOSE_PULL_MODE   Compose pull mode (default: missing)
EOF
}

if [[ "${1:-}" == "-h" || "${1:-}" == "--help" ]]; then
  usage
  exit 0
fi
if [[ $# -gt 0 ]]; then
  log-err "Unknown option: $1"
  usage
  exit 1
fi

resolve_inventory_api_repo() {
  if [[ -z "${INVENTORY_API_REPO}" || ! -f "${INVENTORY_API_REPO}/scripts/start-full-kessel.sh" ]]; then
    INVENTORY_API_REPO="${REPO_ROOT}/.local-deps/inventory-api"
  fi
  [[ -f "${INVENTORY_API_REPO}/scripts/start-full-kessel.sh" ]] || {
    log-err "inventory-api checkout not found. Set INVENTORY_API_REPO to a valid checkout."
    exit 1
  }
  log-info "Using inventory-api at ${INVENTORY_API_REPO}"
}

detect_container_runtime
resolve_inventory_api_repo

COMPOSE_DIR="${INVENTORY_API_REPO}/development/full-kessel"
ENV_FILE="${COMPOSE_DIR}/.env"
[[ -f "${ENV_FILE}" ]] || {
  log-err "Full-kessel Compose environment not found: ${ENV_FILE}"
  exit 1
}

log-info "Building local RBAC image ${RBAC_IMAGE}..."
"${CONTAINER_RUNTIME}" build -t "${RBAC_IMAGE}" "${REPO_ROOT}"

export RBAC_IMAGE
prepare_full_kessel_configs "${INVENTORY_API_REPO}" "${REPO_ROOT}"

compose_args=(
  --env-file "${ENV_FILE}"
  --profile relations
  --profile consumer
  --profile rbac
  -f "${COMPOSE_DIR}/docker-compose.yaml"
  -f "${RBAC_OVERRIDE_FILE}"
)

log-info 'Running RBAC migrations...'
"${COMPOSE_CMD[@]}" "${compose_args[@]}" \
  up --pull "${COMPOSE_PULL_MODE}" --force-recreate --no-deps rbac-migrate

log-info 'Recreating RBAC services...'
"${COMPOSE_CMD[@]}" "${compose_args[@]}" \
  up --pull "${COMPOSE_PULL_MODE}" -d --force-recreate --no-deps \
  rbac-server rbac-worker rbac-scheduler

log-info "RBAC services rebuilt with ${RBAC_IMAGE}."
