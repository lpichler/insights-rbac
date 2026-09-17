#!/usr/bin/env bash
# Start the full local integration stack:
#   Kessel (Inventory API + Relations + SpiceDB) + Debezium + RBAC + Host Inventory
#
# Uses project-kessel/inventory-api development/full-kessel (make kessel-up) for
# Kessel/Debezium/RBAC, then attaches insights-host-inventory on the `kessel`
# Docker network.
#
# Prerequisites:
#   docker or podman (with compose), curl
#   Kessel Inventory and Host Inventory are resolved from upstream checkouts
#   under .local-deps/.
#
# Usage:
#   make docker-local-full-up rbac=local rbac-config=upstream
#   make docker-local-full-up rbac=<rbac-pr-url> rbac-config=<config-pr-url>
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "${SCRIPT_DIR}/../.." && pwd)"
# shellcheck source=../common/logging.sh
source "${SCRIPT_DIR}/../common/logging.sh"
# shellcheck source=../common/container_runtime.sh
source "${SCRIPT_DIR}/../common/container_runtime.sh"

RBAC_UPSTREAM_REPO_URL="https://github.com/project-kessel/insights-rbac.git"
RBAC_CONFIG_UPSTREAM_REPO_URL="https://github.com/project-kessel/rbac-config.git"
INVENTORY_API_UPSTREAM_REPO_URL="https://github.com/project-kessel/inventory-api.git"
HBI_UPSTREAM_REPO_URL="https://github.com/RedHatInsights/insights-host-inventory.git"

INVENTORY_API_REPO="${REPO_ROOT}/.local-deps/inventory-api"
HBI_REPO="${REPO_ROOT}/.local-deps/insights-host-inventory"
RBAC_IMAGE="${RBAC_IMAGE:-}"
RBAC_SOURCE="${RBAC_SOURCE:-local}"
RBAC_CONFIG_SOURCE="${RBAC_CONFIG_SOURCE:-upstream}"
RBAC_PR_NUMBER=""
RBAC_PR_URL=""
RBAC_CONFIG_PR_URL=""
RBAC_CONFIG_REPO="${RBAC_CONFIG_REPO:-${REPO_ROOT}/../rbac-config}"
RBAC_SOURCE_KIND="local"
RBAC_SOURCE_REF=""
RBAC_CONFIG_SOURCE_KIND="upstream"
RBAC_CONFIG_SOURCE_REF=""
COMPOSE_PULL_MODE="${COMPOSE_PULL_MODE:-missing}"
HBI_COMPOSE_PROJECT="${HBI_COMPOSE_PROJECT:-hbi-kessel-local}"
STACK_WAS_RUNNING=false
RBAC_SOURCE_LABEL="${RBAC_SOURCE}"
RBAC_CONFIG_SOURCE_LABEL="${RBAC_CONFIG_SOURCE}"
unset RBAC_CONFIG_FILE SCHEMA_ZED_FILE RBAC_CONFIG_URL SCHEMA_ZED_URL

usage() {
  cat <<'EOF'
Usage: up-full.sh

Source selection is made by make:
  make docker-local-full-up rbac=<source> rbac-config=<source>

Sources:
  local         Use the current checkout.
  upstream      Use the latest commit from the hard-coded upstream repository.
  <PR URL>      Fetch and use the GitHub pull request.
  <commit SHA>  Fetch and use the specified commit.

Hard-coded upstream repositories:
  RBAC          https://github.com/project-kessel/insights-rbac.git
  rbac-config   https://github.com/project-kessel/rbac-config.git
  Inventory     https://github.com/project-kessel/inventory-api.git
  HBI           https://github.com/RedHatInsights/insights-host-inventory.git

Defaults:
  RBAC          local
  rbac-config   upstream
  Kessel Inventory and Host Inventory are always upstream.

When the stack is already running, the selected sources are rebuilt or
refreshed and a summary is printed.

Environment:
  RBAC_IMAGE           Docker image tag for RBAC services (default depends on source)
  INVENTORY_DB_PORT    Host port for HBI Postgres (default: 15433)
  HBI_WEB_PORT         Host port for HBI API (default: 8080)
  UNLEASH_TOKEN        Required by Host Inventory dev.yml parsing (default: local-dev-token)
EOF
}

if [[ $# -gt 0 ]]; then
  log-err "Source selection must use make variables: rbac=<source> rbac-config=<source>."
  usage
  exit 1
fi

require_cmd() {
  if ! command -v "$1" &>/dev/null; then
    log-err "Required command not found: $1"
    exit 1
  fi
}

start_rbac_worktree() {
  [[ "${RBAC_SOURCE_KIND}" != local ]] || return 0
  [[ -z "${RBAC_PR_WORKTREE:-}" ]] || return 0

  local fetch_ref repository pr_number worktree_prefix
  case "${RBAC_SOURCE_KIND}" in
    upstream)
      fetch_ref=HEAD
      worktree_prefix=upstream
      ;;
    pr)
      fetch_ref="pull/${RBAC_PR_NUMBER}/head"
      worktree_prefix="pr-${RBAC_PR_NUMBER}"
      ;;
    sha)
      fetch_ref="${RBAC_SOURCE_REF}"
      worktree_prefix="sha-${RBAC_SOURCE_REF:0:12}"
      ;;
    *)
      log-err "Unsupported RBAC source kind: ${RBAC_SOURCE_KIND}"
      exit 1
      ;;
  esac

  repository="${RBAC_UPSTREAM_REPO_URL}"
  local pr_worktree status
  pr_worktree="$(mktemp -d "${TMPDIR:-/tmp}/insights-rbac-${worktree_prefix}.XXXXXX")"
  rmdir "${pr_worktree}"
  log-info "Fetching RBAC ${RBAC_SOURCE_LABEL} from ${repository}..."
  git -C "${REPO_ROOT}" fetch --no-tags "${repository}" "${fetch_ref}"
  git -C "${REPO_ROOT}" worktree add --detach "${pr_worktree}" FETCH_HEAD >/dev/null

  cp "${SCRIPT_DIR}/up-full.sh" "${pr_worktree}/scripts/local_stack/up-full.sh"
  cp "${SCRIPT_DIR}/full-kessel.rbac-override.yml" \
    "${pr_worktree}/scripts/local_stack/full-kessel.rbac-override.yml"
  cp "${SCRIPT_DIR}/prepare-full-kessel-configs.sh" \
    "${pr_worktree}/scripts/local_stack/prepare-full-kessel-configs.sh"
  chmod +x "${pr_worktree}/scripts/local_stack/up-full.sh"

  log-info "Using RBAC ${RBAC_SOURCE_LABEL} checkout at ${pr_worktree}"
  if RBAC_PR_WORKTREE=true RBAC_SOURCE=local RBAC_SOURCE_LABEL="${RBAC_SOURCE_LABEL}" \
    RBAC_CONFIG_SOURCE="${RBAC_CONFIG_SOURCE}" RBAC_CONFIG_REPO="${RBAC_CONFIG_REPO}" \
    INVENTORY_API_REPO="${INVENTORY_API_REPO}" HBI_REPO="${HBI_REPO}" \
    RBAC_IMAGE="${RBAC_IMAGE}" \
    "${pr_worktree}/scripts/local_stack/up-full.sh"; then
    status=0
  else
    status=$?
  fi

  git -C "${REPO_ROOT}" worktree remove --force "${pr_worktree}" >/dev/null 2>&1 || true
  exit "${status}"
}

select_rbac_config_pr() {
  [[ -n "${RBAC_CONFIG_PR_URL}" ]] || return 0

  local repository pr_number raw_base
  if [[ "${RBAC_CONFIG_PR_URL}" =~ ^https://github\.com/([^/]+/[^/]+)/pull/([0-9]+)(/.*)?$ ]]; then
    repository="${BASH_REMATCH[1]}"
    pr_number="${BASH_REMATCH[2]}"
  else
    log-err "RBAC_CONFIG_PR_URL must be a GitHub pull request URL: ${RBAC_CONFIG_PR_URL}"
    exit 1
  fi

  raw_base="https://raw.githubusercontent.com/${repository}/refs/pull/${pr_number}/head"
  export RBAC_CONFIG_URL="${raw_base}/_private/configmaps/stage/rbac-config.yml"

  # A local generated schema is more specific than the schema committed by the PR.
  # This is useful while iterating on KSL before schema.zed has been updated.
  if [[ -z "${SCHEMA_ZED_FILE:-}" ]]; then
    export SCHEMA_ZED_URL="${raw_base}/configs/stage/schemas/schema.zed"
    log-info "Using rbac-config PR #${pr_number} stage ConfigMap and committed schema.zed"
  else
    log-info "Using rbac-config PR #${pr_number} stage ConfigMap and local generated schema"
  fi
}

select_local_rbac_config() {
  [[ -n "${RBAC_CONFIG_REPO}" ]] || return 0
  if [[ -n "${RBAC_CONFIG_PR_URL}" ]]; then
    log-err 'Use either RBAC_CONFIG_REPO or RBAC_CONFIG_PR_URL, not both.'
    exit 1
  fi

  local config_repo config_file schema_file
  config_repo="$(cd "${RBAC_CONFIG_REPO}" 2>/dev/null && pwd)" || {
    log-err "RBAC_CONFIG_REPO is not a directory: ${RBAC_CONFIG_REPO}"
    exit 1
  }
  config_file="${config_repo}/_private/configmaps/stage/rbac-config.yml"
  [[ -f "${config_file}" ]] || {
    log-err "Stage ConfigMap not found: ${config_file}"
    exit 1
  }

  export RBAC_CONFIG_FILE="${config_file}"
  if [[ -z "${SCHEMA_ZED_FILE:-}" ]]; then
    schema_file="${config_repo}/_private/test-schema/stage-schema.zed"
    log-info "Building local rbac-config stage schema..."
    make -C "${config_repo}" ksl-test-schema-stage
    [[ -f "${schema_file}" ]] || {
      log-err "Generated stage schema not found: ${schema_file}"
      exit 1
    }
    export SCHEMA_ZED_FILE="${schema_file}"
    log-info "Using local rbac-config checkout at ${config_repo} and its generated stage schema"
  else
    log-info "Using local rbac-config ConfigMap and explicit local schema"
  fi
}

is_commit_sha() {
  [[ "${1}" =~ ^[0-9a-fA-F]{7,64}$ ]]
}

select_rbac_source() {
  case "${RBAC_SOURCE}" in
    local)
      RBAC_SOURCE_KIND=local
      RBAC_IMAGE="${RBAC_IMAGE:-insights-rbac-local:dev}"
      ;;
    upstream)
      RBAC_SOURCE_KIND=upstream
      RBAC_IMAGE="${RBAC_IMAGE:-insights-rbac-local:dev}"
      ;;
    https://github.com/*/pull/[0-9]*|https://github.com/*/pull/[0-9]*/*)
      RBAC_SOURCE_KIND=pr
      RBAC_PR_URL="${RBAC_SOURCE}"
      if [[ "${RBAC_PR_URL}" =~ ^https://github\.com/[^/]+/[^/]+/pull/([0-9]+)(/.*)?$ ]]; then
        RBAC_PR_NUMBER="${BASH_REMATCH[1]}"
      else
        log-err "RBAC source must be local, upstream, or a GitHub pull request URL: ${RBAC_SOURCE}"
        exit 1
      fi
      RBAC_IMAGE="${RBAC_IMAGE:-insights-rbac-pr-${RBAC_PR_NUMBER}:dev}"
      ;;
    *)
      if is_commit_sha "${RBAC_SOURCE}"; then
        RBAC_SOURCE_KIND=sha
        RBAC_SOURCE_REF="${RBAC_SOURCE}"
        RBAC_IMAGE="${RBAC_IMAGE:-insights-rbac-sha-${RBAC_SOURCE:0:12}:dev}"
        return 0
      fi
      log-err "RBAC source must be local, upstream, a GitHub pull request URL, or a commit SHA: ${RBAC_SOURCE}"
      usage
      exit 1
      ;;
  esac
}

select_rbac_config_source() {
  case "${RBAC_CONFIG_SOURCE}" in
    upstream)
      RBAC_CONFIG_SOURCE_KIND=upstream
      export RBAC_CONFIG_URL="https://raw.githubusercontent.com/project-kessel/rbac-config/refs/heads/master/_private/configmaps/stage/rbac-config.yml"
      export SCHEMA_ZED_URL="https://raw.githubusercontent.com/project-kessel/rbac-config/refs/heads/master/configs/stage/schemas/schema.zed"
      log-info "Using upstream rbac-config stage configuration from ${RBAC_CONFIG_UPSTREAM_REPO_URL}."
      ;;
    local)
      RBAC_CONFIG_SOURCE_KIND=local
      select_local_rbac_config
      ;;
    https://github.com/*/pull/[0-9]*|https://github.com/*/pull/[0-9]*/*)
      RBAC_CONFIG_SOURCE_KIND=pr
      RBAC_CONFIG_PR_URL="${RBAC_CONFIG_SOURCE}"
      select_rbac_config_pr
      ;;
    *)
      if is_commit_sha "${RBAC_CONFIG_SOURCE}"; then
        RBAC_CONFIG_SOURCE_KIND=sha
        RBAC_CONFIG_SOURCE_REF="${RBAC_CONFIG_SOURCE}"
        export RBAC_CONFIG_URL="https://raw.githubusercontent.com/project-kessel/rbac-config/${RBAC_CONFIG_SOURCE}/_private/configmaps/stage/rbac-config.yml"
        export SCHEMA_ZED_URL="https://raw.githubusercontent.com/project-kessel/rbac-config/${RBAC_CONFIG_SOURCE}/configs/stage/schemas/schema.zed"
        log-info "Using rbac-config commit ${RBAC_CONFIG_SOURCE}."
        return 0
      fi
      log-err "rbac-config source must be local, upstream, a GitHub pull request URL, or a commit SHA: ${RBAC_CONFIG_SOURCE}"
      usage
      exit 1
      ;;
  esac
}

stack_is_running() {
  [[ "$("${CONTAINER_RUNTIME}" container inspect --format '{{.State.Running}}' full-kessel-rbac-server-1 2>/dev/null || true)" == true ]]
}

print_source_summary() {
  log-info "Deployment sources: RBAC=${RBAC_SOURCE_LABEL}, rbac-config=${RBAC_CONFIG_SOURCE_LABEL}, HBI=upstream, Kessel Inventory=upstream."
  if [[ "${STACK_WAS_RUNNING}" == true ]]; then
    log-info 'Existing Docker stack detected; rebuilding or refreshing services for the selected sources.'
  fi
}

resolve_inventory_api_repo() {
  if [[ ! -f "${INVENTORY_API_REPO}/scripts/start-full-kessel.sh" ]]; then
    if [[ -e "${INVENTORY_API_REPO}" ]]; then
      log-err "Upstream inventory-api checkout is incomplete: ${INVENTORY_API_REPO}"
      exit 1
    fi
    log-info "Cloning upstream inventory-api into ${INVENTORY_API_REPO}..."
    mkdir -p "$(dirname "${INVENTORY_API_REPO}")"
    git clone --depth 1 "${INVENTORY_API_UPSTREAM_REPO_URL}" "${INVENTORY_API_REPO}"
  fi
  log-info "Using inventory-api at ${INVENTORY_API_REPO}"
}

resolve_hbi_repo() {
  if [[ ! -f "${HBI_REPO}/dev.yml" ]]; then
    if [[ -e "${HBI_REPO}" ]]; then
      log-err "Upstream insights-host-inventory checkout is incomplete: ${HBI_REPO}"
      exit 1
    fi
    log-info "Cloning upstream insights-host-inventory into ${HBI_REPO}..."
    mkdir -p "$(dirname "${HBI_REPO}")"
    git clone --depth 1 "${HBI_UPSTREAM_REPO_URL}" "${HBI_REPO}"
  fi
  log-info "Using Host Inventory at ${HBI_REPO}"
}

initialize_hbi_submodules() {
  log-info "Initializing Host Inventory git submodules..."
  git -C "${HBI_REPO}" submodule update --init --recursive
}

pull_repository() {
  local name="$1"
  local repository="$2"
  local upstream_url="$3"

  log-info "Updating upstream ${name} from ${upstream_url}..."
  git -C "${repository}" fetch --no-tags "${upstream_url}" HEAD
  git -C "${repository}" merge --ff-only FETCH_HEAD
}

start_kessel_stack() {
  export RBAC_IMAGE
  export COMPOSE_PULL_MODE
  export DOCKER="${CONTAINER_RUNTIME}"
  export RBAC_FORCE_RECREATE
  export STACK_WAS_RUNNING
  log-info "Building and starting Kessel + Debezium + RBAC (RBAC_IMAGE=${RBAC_IMAGE})..."
  "${SCRIPT_DIR}/start-kessel-compose.sh" \
    "${INVENTORY_API_REPO}" \
    "${REPO_ROOT}/scripts/local_stack/full-kessel.rbac-override.yml"
}

start_hbi() {
  export UNLEASH_TOKEN="${UNLEASH_TOKEN:-local-dev-token}"
  export INVENTORY_DB_PORT="${INVENTORY_DB_PORT:-15433}"
  export HBI_WEB_PORT="${HBI_WEB_PORT:-8080}"

  log-info "Creating HBI Kafka topics on Kessel broker..."
  "${SCRIPT_DIR}/ensure-hbi-kafka-topics.sh" "${INVENTORY_API_REPO}"

  log-info "Building and starting Host Inventory from ${HBI_REPO}..."

  "${COMPOSE_CMD[@]}" -p "${HBI_COMPOSE_PROJECT}" \
    -f "${HBI_REPO}/dev.yml" \
    -f "${REPO_ROOT}/scripts/local_stack/hbi.integration.yml" \
    up -d --build --no-deps db hbi-web hbi-mq
}

print_endpoints() {
  cat <<EOF

Stack endpoints:
  RBAC API:          http://localhost:9080
  RBAC Postgres:     localhost:15432
  Relations API:     localhost:9000
  SpiceDB (zed):     localhost:50051
  Inventory API:     localhost:9081
  Kafka Connect:     http://localhost:8083
  HBI API:           http://localhost:${HBI_WEB_PORT:-8080}
  HBI Postgres:      localhost:${INVENTORY_DB_PORT:-15433}

Verify workspace create + RYW (after stack is healthy):
  ./scripts/validations/api/create-workspace-local.sh --no-start

Verify a workspace permission (replace <workspace-uuid>):
  ./scripts/zed_local.sh check rbac/workspace:<workspace-uuid> view rbac/principal:redhat/1111111

EOF
}

require_cmd curl
require_cmd git

select_rbac_source
start_rbac_worktree
select_rbac_config_source

detect_container_runtime
if stack_is_running; then
  STACK_WAS_RUNNING=true
fi
print_source_summary

resolve_inventory_api_repo
pull_repository "inventory-api" "${INVENTORY_API_REPO}" "${INVENTORY_API_UPSTREAM_REPO_URL}"

log-info "Building local RBAC image ${RBAC_IMAGE}..."
"${CONTAINER_RUNTIME}" build -t "${RBAC_IMAGE}" "${REPO_ROOT}"
export RBAC_FORCE_RECREATE=true

start_kessel_stack

resolve_hbi_repo
pull_repository "insights-host-inventory" "${HBI_REPO}" "${HBI_UPSTREAM_REPO_URL}"
initialize_hbi_submodules
start_hbi

if [[ "${STACK_WAS_RUNNING}" == true ]]; then
  log-info 'Existing Docker stack rebuilt for the selected sources.'
else
  log-info 'Full local stack started.'
fi
print_endpoints
