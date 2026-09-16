#!/usr/bin/env bash
# Start inventory-api full-kessel compose (Kessel + Debezium + RBAC) without requiring
# a host yq install.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "${SCRIPT_DIR}/../.." && pwd)"
# shellcheck source=../common/logging.sh
source "${SCRIPT_DIR}/../common/logging.sh"
# shellcheck source=../common/container_runtime.sh
source "${SCRIPT_DIR}/../common/container_runtime.sh"
# shellcheck source=prepare-full-kessel-configs.sh
source "${SCRIPT_DIR}/prepare-full-kessel-configs.sh"

INVENTORY_API_REPO="${1:?inventory-api repo path required}"
RBAC_OVERRIDE_FILE="${2:?compose override file required}"

detect_container_runtime

COMPOSE_DIR="${INVENTORY_API_REPO}/development/full-kessel"
ENV_FILE="${COMPOSE_DIR}/.env"

prepare_full_kessel_configs "${INVENTORY_API_REPO}" "${REPO_ROOT}"

NETWORK_CHECK=$("${CONTAINER_RUNTIME}" network ls --filter name=kessel --format json)
if [[ -z "${NETWORK_CHECK}" || "${NETWORK_CHECK}" == "[]" ]]; then
  "${CONTAINER_RUNTIME}" network create kessel
fi

export DOCKER="${CONTAINER_RUNTIME}"
export COMPOSE_PULL_MODE="${COMPOSE_PULL_MODE:-missing}"
export RBAC_IMAGE="${RBAC_IMAGE:?RBAC_IMAGE must be set by up-full.sh}"

write_spicedb_schema() {
  local spicedb_token schema_file
  schema_file="${COMPOSE_DIR}/configs/schema.zed"
  spicedb_token=$(awk -F= '$1 == "SPICEDB_GRPC_PRESHARED_KEY" {print substr($0, index($0, "=") + 1); exit}' "${ENV_FILE}")
  [[ -n "${spicedb_token}" ]] || {
    log-err "SPICEDB_GRPC_PRESHARED_KEY is missing from ${ENV_FILE}"
    exit 1
  }

  # Relations API reads this file but does not reliably write it into SpiceDB
  # during startup. Apply it directly before dependent services are restarted.
  log-info 'Applying schema directly to SpiceDB...'
  "${CONTAINER_RUNTIME}" run --rm --network kessel \
    -e "ZED_TOKEN=${spicedb_token}" \
    -e ZED_ENDPOINT=spicedb:50051 \
    -e ZED_INSECURE=true \
    -v "${schema_file}:/schema.zed:ro,z" \
    docker.io/authzed/zed:latest schema write /schema.zed
}

if [[ "${RBAC_CONFIG_REFRESH:-false}" == true ]]; then
  # schema.zed is mounted only by Relations API. Role definitions are consumed
  # by rbac-migrate during seeding and mounted by rbac-server. Everything else
  # continues running with the unchanged image and dependencies.
  write_spicedb_schema
  log-info 'Restarting Relations API, reseeding RBAC roles, and restarting RBAC server...'
  "${COMPOSE_CMD[@]}" --env-file "${ENV_FILE}" \
    --profile relations --profile consumer --profile rbac \
    -f "${COMPOSE_DIR}/docker-compose.yaml" \
    -f "${RBAC_OVERRIDE_FILE}" \
    up --pull "${COMPOSE_PULL_MODE}" -d --force-recreate --no-deps relations-api
  "${COMPOSE_CMD[@]}" --env-file "${ENV_FILE}" \
    --profile relations --profile consumer --profile rbac \
    -f "${COMPOSE_DIR}/docker-compose.yaml" \
    -f "${RBAC_OVERRIDE_FILE}" \
    up --pull "${COMPOSE_PULL_MODE}" --force-recreate --no-deps rbac-migrate
  "${COMPOSE_CMD[@]}" --env-file "${ENV_FILE}" \
    --profile relations --profile consumer --profile rbac \
    -f "${COMPOSE_DIR}/docker-compose.yaml" \
    -f "${RBAC_OVERRIDE_FILE}" \
    up --pull "${COMPOSE_PULL_MODE}" -d --force-recreate --no-deps \
    rbac-server rbac-worker rbac-scheduler rbac-kafka-consumer
  exit 0
fi

compose_up_args=(up --pull "${COMPOSE_PULL_MODE}" -d)
if [[ "${RBAC_FORCE_RECREATE:-false}" == "true" ]]; then
  compose_up_args+=(--force-recreate)
fi

"${COMPOSE_CMD[@]}" --env-file "${ENV_FILE}" \
  --profile relations --profile consumer --profile rbac \
  -f "${COMPOSE_DIR}/docker-compose.yaml" \
  -f "${RBAC_OVERRIDE_FILE}" \
  "${compose_up_args[@]}"
