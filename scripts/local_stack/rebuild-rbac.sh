#!/usr/bin/env bash
# Rebuild the current local RBAC image and recreate RBAC services.
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
REBUILD_SCOPE=rbac
RBAC_CONFIG_REPO="${RBAC_CONFIG_REPO:-}"

usage() {
  cat <<'EOF'
Usage: rebuild-rbac.sh [--rebuild=rbac|--rebuild=rbac,rbac-config]

Build the current checkout and recreate RBAC services in the local full-kessel
stack. The rbac,rbac-config mode also compiles the local stage KSL schema,
loads it into SpiceDB, refreshes Relations API, and reseeds RBAC.

Environment:
  INVENTORY_API_REPO  Path to the inventory-api checkout
  RBAC_CONFIG_REPO    Path to the local rbac-config checkout (combined mode)
  RBAC_IMAGE          Image tag for the rebuilt RBAC services
  COMPOSE_PULL_MODE   Compose pull mode (default: missing)
EOF
}

if [[ "${1:-}" == "-h" || "${1:-}" == "--help" ]]; then
  usage
  exit 0
fi
if [[ $# -gt 0 ]]; then
  case "$1" in
    --rebuild=rbac|--rebuild=rbac,rbac-config) REBUILD_SCOPE="${1#--rebuild=}" ;;
    *)
      log-err "Unknown option: $1"
      usage
      exit 1
      ;;
  esac
  shift
fi
if [[ $# -gt 0 ]]; then
  log-err "Unknown option: $1"
  usage
  exit 1
fi

prepare_local_rbac_config() {
  [[ "${REBUILD_SCOPE}" == 'rbac,rbac-config' ]] || return 0
  [[ -n "${RBAC_CONFIG_REPO}" ]] || {
    log-err 'rbac,rbac-config requires RBAC_CONFIG_REPO (or rbac_config_repo=<path>).'
    exit 1
  }

  local config_repo=""
  config_repo="$(cd "${RBAC_CONFIG_REPO}" 2>/dev/null && pwd)" || {
    log-err "RBAC_CONFIG_REPO is not a directory: ${RBAC_CONFIG_REPO}"
    exit 1
  }
  RBAC_CONFIG_REPO="${config_repo}"
  RBAC_CONFIG_FILE="${RBAC_CONFIG_REPO}/_private/configmaps/stage/rbac-config.yml"
  SCHEMA_ZED_FILE="${RBAC_CONFIG_REPO}/_private/test-schema/stage-schema.zed"
  [[ -f "${RBAC_CONFIG_FILE}" ]] || {
    log-err "Stage ConfigMap not found: ${RBAC_CONFIG_FILE}"
    exit 1
  }

  log-info 'Building local rbac-config stage schema from KSL...'
  make -C "${RBAC_CONFIG_REPO}" ksl-test-schema-stage
  [[ -f "${SCHEMA_ZED_FILE}" ]] || {
    log-err "Generated stage schema not found: ${SCHEMA_ZED_FILE}"
    exit 1
  }
  export RBAC_CONFIG_FILE SCHEMA_ZED_FILE
  log-info "Using generated stage schema ${SCHEMA_ZED_FILE}"
}

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
prepare_local_rbac_config

COMPOSE_DIR="${INVENTORY_API_REPO}/development/full-kessel"
ENV_FILE="${COMPOSE_DIR}/.env"
[[ -f "${ENV_FILE}" ]] || {
  log-err "Full-kessel Compose environment not found: ${ENV_FILE}"
  exit 1
}

log-info "Building local RBAC image ${RBAC_IMAGE}..."
"${CONTAINER_RUNTIME}" build -t "${RBAC_IMAGE}" "${REPO_ROOT}"

export RBAC_IMAGE

if [[ "${REBUILD_SCOPE}" == 'rbac,rbac-config' ]]; then
  export COMPOSE_PULL_MODE
  export RBAC_CONFIG_REFRESH=true
  log-info 'Refreshing Kessel schema, Relations API, RBAC seeding, and RBAC services...'
  "${SCRIPT_DIR}/start-kessel-compose.sh" \
    "${INVENTORY_API_REPO}" \
    "${RBAC_OVERRIDE_FILE}"
  log-info "RBAC and rbac-config rebuilt with ${RBAC_IMAGE}."
  exit 0
fi

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
  rbac-server rbac-worker rbac-scheduler rbac-kafka-consumer

log-info "RBAC services rebuilt with ${RBAC_IMAGE}."
