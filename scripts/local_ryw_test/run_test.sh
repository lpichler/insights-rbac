#!/bin/bash
# =============================================================================
# Local RYW (Read-Your-Writes) Pipeline Test
# =============================================================================
#
# Tests the full Debezium CDC pipeline locally:
#   Outbox → Debezium → Kafka → Consumer → Mock Kessel → pg_notify → RYW
#
# Also reproduces and recovers from the Debezium FAILED state after DB restore.
#
# THE ISSUE (Debezium 3.2+, DBZ-9118, PR #6488):
# ------------------------------------------------
#   1. Debezium streams WAL changes and stores its last-read position (LSN)
#      in the Kafka "connect-offsets" topic
#   2. Database is restored from an earlier backup:
#      → old DB is renamed (or dropped), new DB created from backup
#      → replication slot is not in pg_dump, so the new DB has no slot
#        (slots are cluster-level objects tied to a database by OID)
#   3. Debezium restarts, reads its stored LSN from connect-offsets
#   4. validateLogPosition() queries pg_replication_slots → no slot found
#      → returns false
#   5. Since Debezium 3.2: throws DebeziumException → task FAILED
#      (before 3.2: logged WARN and silently continued)
#
# RECOVERY (Kafka Connect 3.6+, KIP-875):
# ------------------------------------------------
#   1. Stop the connector:  PUT /connectors/<name>/stop
#   2. Reset the offsets:   DELETE /connectors/<name>/offsets
#   3. (Skip for PostgreSQL — schema history topic only applies to MySQL/SQL Server)
#   4. Drop stale replication slot if it exists
#   5. Resume the connector: PUT /connectors/<name>/resume
#   6. Debezium starts fresh, snapshots table, creates new slot,
#      resumes streaming from current WAL position
#   7. Events from the gap (between backup and restore) are skipped
#
# Components:
#   Docker:  PostgreSQL (port 15432), Kafka (port 29092), Kafka Connect (8083)
#   Local:   RBAC API server (port 8000), Kafka consumer, Mock Kessel gRPC (50051)
#
# Prerequisites:
#   - Docker/Podman running
#   - Python virtualenv with project dependencies active
#   - Port 15432 (PostgreSQL), 29092 (Kafka), 8083 (Connect), 50051 (mock Kessel)
#
# Usage:
#   ./scripts/local_ryw_test/run_test.sh          # Full setup + test + break + recover
#   ./scripts/local_ryw_test/run_test.sh --test    # Run test only (infra already up)
#   ./scripts/local_ryw_test/run_test.sh --recover # Recover a failed connector
#   ./scripts/local_ryw_test/run_test.sh --clean   # Tear down everything
#   ./scripts/local_ryw_test/run_test.sh --help    # Show help
# =============================================================================

set -e

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_DIR="$(cd "$SCRIPT_DIR/../.." && pwd)"

# Detect Python virtualenv
if [ -n "$VIRTUAL_ENV" ]; then
    PYTHON="python"
elif PIPENV_VENV=$(cd "$PROJECT_DIR" && pipenv --venv 2>/dev/null); then
    PYTHON="$PIPENV_VENV/bin/python"
else
    # Auto-detect: find an insights-rbac virtualenv with Django installed
    FOUND_VENV=""
    for venv_dir in "$HOME/.local/share/virtualenvs"/insights-rbac-*/; do
        if [ -x "$venv_dir/bin/python" ] && "$venv_dir/bin/python" -c "import django" 2>/dev/null; then
            FOUND_VENV="$venv_dir"
        fi
    done
    if [ -n "$FOUND_VENV" ]; then
        PYTHON="${FOUND_VENV}bin/python"
    else
        echo "ERROR: No Python virtualenv found. Either:"
        echo "  - Activate a virtualenv: pipenv shell / source .venv/bin/activate"
        echo "  - Or create one: cd $PROJECT_DIR && pipenv install --dev"
        exit 1
    fi
fi
echo "[INFO] Using Python: $PYTHON"

# Detect container runtime
if command -v docker &> /dev/null && docker info &> /dev/null 2>&1; then
    CONTAINER_RUNTIME="docker"
    COMPOSE_CMD="docker compose"
elif command -v podman &> /dev/null && podman info &> /dev/null 2>&1; then
    CONTAINER_RUNTIME="podman"
    COMPOSE_CMD="podman compose"
else
    echo "ERROR: Neither Docker nor Podman is running."
    echo "  - Docker: install and start Docker Desktop, or 'docker context use ...'"
    echo "  - Podman: 'podman machine init && podman machine start'"
    exit 1
fi

# Common environment variables
export ACG_CONFIG="$SCRIPT_DIR/clowder-config-local.json"
export DATABASE_HOST=localhost
export DATABASE_PORT=15432
export DATABASE_NAME=postgres
export DATABASE_USER=postgres
export DATABASE_PASSWORD=postgres
export PGSSLMODE=disable
export DEVELOPMENT=True
export V2_APIS_ENABLED=True
export V2_BOOTSTRAP_TENANT=True
export REPLICATION_TO_RELATION_ENABLED=True
export READ_YOUR_WRITES_WORKSPACE_ENABLED=True
export READ_YOUR_WRITES_TIMEOUT_SECONDS=30
export RELATION_API_SERVER=localhost:50051
export PRINCIPAL_USER_DOMAIN=redhat
export ENV_NAME=local-ryw-test
export DJANGO_CACHE_BACKEND=locmem
export ACCESS_CACHE_ENABLED=False
# System role UUIDs required for V2 tenant bootstrap
export SYSTEM_DEFAULT_ROOT_WORKSPACE_ROLE_UUID="e31b93d4-8570-4cfe-a79f-8421560e1487"
export SYSTEM_DEFAULT_TENANT_ROLE_UUID="1607fbde-7781-436e-8860-ef73b83c9aa1"
export SYSTEM_ADMIN_ROOT_WORKSPACE_ROLE_UUID="2c2d2bb1-24dc-42ca-b739-7c59ecd4a9ab"
export SYSTEM_ADMIN_TENANT_ROLE_UUID="51b5fd3b-9733-46e8-bbe2-f77f99871d49"

# Colors
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
CYAN='\033[0;36m'
NC='\033[0m'

info()    { echo -e "${BLUE}[INFO]${NC} $1"; }
success() { echo -e "${GREEN}[OK]${NC} $1"; }
warn()    { echo -e "${YELLOW}[WARN]${NC} $1"; }
error()   { echo -e "${RED}[ERROR]${NC} $1"; }
header()  { echo -e "\n${CYAN}=== $1 ===${NC}"; }

BOLD='\033[1m'
DIM='\033[2m'

# Global state
PIDS_DIR="$SCRIPT_DIR/.pids"
mkdir -p "$PIDS_DIR"
LAST_BACKUP_FILE=""

# Checkpoint storage
declare -a CP_LABELS=()
declare -a CP_CONNECTOR=()
declare -a CP_SNAPSHOT_MODE=()
declare -a CP_SLOT=()
declare -a CP_OFFSET_LSN=()
declare -a CP_OFFSET_LSN_PROC=()
declare -a CP_OFFSET_LSN_COMMIT=()
declare -a CP_CONSUMER=()
declare -a CP_WAL=()
declare -a CP_PHASE=()

capture_checkpoint() {
    local label="$1"
    local phase="${2:-}"
    local idx=${#CP_LABELS[@]}
    CP_LABELS[$idx]="$label"
    CP_PHASE[$idx]="$phase"

    # 1. Connector status + task status
    local conn_status="n/a"
    local tmpfile
    tmpfile=$(mktemp)
    local http_code
    http_code=$(curl -s -o "$tmpfile" -w '%{http_code}' http://localhost:8083/connectors/rbac-debezium/status 2>/dev/null) || true
    if [ "$http_code" = "200" ]; then
        conn_status=$(python3 -c "
import json, sys
d = json.load(open(sys.argv[1]))
cs = d.get('connector',{}).get('state','?')
ts = d.get('tasks',[{}])[0].get('state','NO_TASKS') if d.get('tasks') else 'NO_TASKS'
print(f'{cs}/{ts}')
" "$tmpfile" 2>/dev/null) || conn_status="parse error"
    elif [ "$http_code" = "404" ]; then
        conn_status="DELETED"
    elif [ "$http_code" = "000" ]; then
        conn_status="unreachable"
    fi
    rm -f "$tmpfile"
    CP_CONNECTOR[$idx]="$conn_status"

    # 2. snapshot.mode from connector config
    local snap_mode="n/a"
    if [ "$http_code" = "200" ] || [ "$conn_status" != "DELETED" ]; then
        local config_json
        config_json=$(curl -s http://localhost:8083/connectors/rbac-debezium/config 2>/dev/null)
        if [ -n "$config_json" ] && echo "$config_json" | python3 -c "import json,sys; json.load(sys.stdin)" 2>/dev/null; then
            snap_mode=$(echo "$config_json" | python3 -c "
import json,sys
d=json.load(sys.stdin)
print(d.get('snapshot.mode','initial (default)'))
" 2>/dev/null) || snap_mode="n/a"
        else
            snap_mode="n/a"
        fi
    fi
    CP_SNAPSHOT_MODE[$idx]="$snap_mode"

    # 3. Replication slot
    local slot="n/a"
    slot=$($CONTAINER_RUNTIME exec rbac_db psql -U postgres -t -c \
        "SELECT COALESCE(confirmed_flush_lsn::text, 'exists/no LSN') FROM pg_replication_slots WHERE slot_name = 'debezium';" \
        2>/dev/null | xargs) || true
    if [ -z "$slot" ]; then
        slot="NO SLOT"
    fi
    CP_SLOT[$idx]="$slot"

    # 4. Debezium stored offsets (lsn, lsn_proc, lsn_commit)
    #    Primary: REST API /connectors/{name}/offsets (instant, no timeout)
    #    Fallback: kafka-console-consumer from offset topic (when connector deleted)
    local dbz_lsn="n/a" dbz_lsn_proc="n/a" dbz_lsn_commit="n/a"
    local offset_parsed=""

    if [ "$conn_status" != "DELETED" ] && [ "$conn_status" != "unreachable" ] && [ "$conn_status" != "n/a" ]; then
        offset_parsed=$(curl -s http://localhost:8083/connectors/rbac-debezium/offsets 2>/dev/null | python3 -c "
import sys, json
def to_hex(v):
    if v is None: return 'n/a'
    v = int(v)
    return f'{v >> 32:X}/{v & 0xFFFFFFFF:08X}'
try:
    d = json.load(sys.stdin)
    o = d.get('offsets', [{}])[0].get('offset', {})
    lsn = to_hex(o.get('lsn'))
    if lsn == 'n/a': raise ValueError('no lsn')
    print(lsn)
    print(to_hex(o.get('lsn_proc')))
    print(to_hex(o.get('lsn_commit')))
except Exception:
    pass
" 2>/dev/null) || true
    fi

    if [ -z "$offset_parsed" ]; then
        local offset_raw
        offset_raw=$($CONTAINER_RUNTIME exec insights-rbac-kafka-1 kafka-console-consumer \
            --bootstrap-server localhost:9092 \
            --topic my_connect_offsets \
            --from-beginning \
            --timeout-ms 5000 \
            2>/dev/null | tail -1) || true
        if [ -n "$offset_raw" ]; then
            offset_parsed=$(echo "$offset_raw" | python3 -c "
import sys, json
def to_hex(v):
    if v is None: return 'n/a'
    v = int(v)
    return f'{v >> 32:X}/{v & 0xFFFFFFFF:08X}'
try:
    d = json.load(sys.stdin)
    if 'payload' in d and isinstance(d.get('payload'), dict):
        d = d['payload']
    lsn = to_hex(d.get('lsn'))
    if lsn == 'n/a': raise ValueError('no lsn')
    print(lsn)
    print(to_hex(d.get('lsn_proc')))
    print(to_hex(d.get('lsn_commit')))
except Exception:
    pass
" 2>/dev/null) || true
        fi
    fi

    if [ -n "$offset_parsed" ]; then
        dbz_lsn=$(echo "$offset_parsed" | sed -n '1p')
        dbz_lsn_proc=$(echo "$offset_parsed" | sed -n '2p')
        dbz_lsn_commit=$(echo "$offset_parsed" | sed -n '3p')
    fi
    CP_OFFSET_LSN[$idx]="${dbz_lsn:-n/a}"
    CP_OFFSET_LSN_PROC[$idx]="${dbz_lsn_proc:-n/a}"
    CP_OFFSET_LSN_COMMIT[$idx]="${dbz_lsn_commit:-n/a}"

    # 5. Consumer group offset
    local consumer="-"
    local cg_line
    cg_line=$($CONTAINER_RUNTIME exec insights-rbac-kafka-1 kafka-consumer-groups \
        --bootstrap-server localhost:9092 \
        --group rbac-consumer-group-local \
        --describe 2>/dev/null \
        | grep "outbox.event") || true
    consumer=$(echo "$cg_line" | awk '{print $4}')
    CP_CONSUMER[$idx]="${consumer:--}"

    # 6. WAL position
    local wal="n/a"
    wal=$($CONTAINER_RUNTIME exec rbac_db psql -U postgres -t -c \
        "SELECT pg_current_wal_lsn();" 2>/dev/null | xargs) || true
    CP_WAL[$idx]="${wal:-n/a}"

    show_checkpoint_summary
}

show_checkpoint_summary() {
    local n=${#CP_LABELS[@]}
    [ "$n" -eq 0 ] && return
    local i=$((n - 1))
    local current="${CP_LABELS[$i]}"
    local phase="${CP_PHASE[$i]}"

    echo
    echo -e "  ${BOLD}DR Recovery — Checkpoint: ${current}${NC} ${DIM}(${phase})${NC}"
    printf "  "; printf '─%.0s' $(seq 1 50); echo

    _c() {
        local v="$1" m="$2"
        case "$m:$v" in
            connector:RUNNING/RUNNING)  echo -e "${GREEN}${v}${NC}" ;;
            connector:*FAILED*)         echo -e "${RED}${v}${NC}" ;;
            connector:DELETED)          echo -e "${YELLOW}${v}${NC}" ;;
            snapshot:when_needed)       echo -e "${GREEN}${v}${NC}" ;;
            slot:"NO SLOT")             echo -e "${RED}${v}${NC}" ;;
            slot:n/a)                   echo -e "${DIM}${v}${NC}" ;;
            slot:*)                     echo -e "${GREEN}${v}${NC}" ;;
            lag:"0 B")                  echo -e "${GREEN}${v}${NC}" ;;
            lag:n/a)                    echo -e "${DIM}${v}${NC}" ;;
            lag:*)                      echo -e "${YELLOW}${v}${NC}" ;;
            *)                          echo -e "${DIM}${v}${NC}" ;;
        esac
    }

    _lsn_pretty() {
        local v="$1"
        [[ "$v" =~ ^[0-9A-Fa-f]+/[0-9A-Fa-f]+$ ]] || return 0
        python3 -c "
v='$v'.split('/');b=(int(v[0],16)<<32)|int(v[1],16)
print(f'{b}B' if b<1024 else f'~{b/1024:.2f}K' if b<1048576 else f'~{b/1048576:.4f}M' if b<1073741824 else f'~{b/1073741824:.6f}G')
" 2>/dev/null || true
    }

    # format: "Label:colorkey:array:fmt:source"
    local metrics=("Connector:connector:CP_CONNECTOR::Connect REST API /connectors/status"
                   "snapshot.mode:snapshot:CP_SNAPSHOT_MODE::Connect REST API /connectors/config"
                   "Slot LSN (flushed):slot:CP_SLOT:lsn:PostgreSQL pg_replication_slots.confirmed_flush_lsn"
                   "WAL Position:slot:CP_WAL:lsn:PostgreSQL pg_current_wal_lsn()"
                   "Offset lsn:offset:CP_OFFSET_LSN:lsn:Kafka Connect /connectors/offsets or connect-offsets topic"
                   "Offset lsn_proc:offset:CP_OFFSET_LSN_PROC:lsn:Kafka Connect /connectors/offsets or connect-offsets topic"
                   "Offset lsn_commit:offset:CP_OFFSET_LSN_COMMIT:lsn:Kafka Connect /connectors/offsets or connect-offsets topic"
                   "Consumer Offset:consumer:CP_CONSUMER::Kafka consumer-groups --describe (CURRENT-OFFSET)")
    for entry in "${metrics[@]}"; do
        IFS=: read -r label metric arr fmt source <<< "$entry"
        local ref="${arr}[$i]"
        local val="${!ref}"
        if [ "$fmt" = "lsn" ] && [[ "$val" =~ ^[0-9A-Fa-f]+/[0-9A-Fa-f]+$ ]]; then
            local pretty
            pretty=$(_lsn_pretty "$val") || true
            [ -n "$pretty" ] && val="${val} (${pretty})"
        fi
        printf "  %-20s %b  ${DIM}← %s${NC}\n" "$label" "$(_c "$val" "$metric")" "$source"
    done

    # Replication Lag = WAL Position - Slot LSN (computed, not from any single source)
    local ref_wal="CP_WAL[$i]" ref_slot="CP_SLOT[$i]"
    local wal_val="${!ref_wal}" slot_val="${!ref_slot}"
    local lag="n/a"
    if [[ "$wal_val" =~ ^[0-9A-Fa-f]+/[0-9A-Fa-f]+$ ]] && [[ "$slot_val" =~ ^[0-9A-Fa-f]+/[0-9A-Fa-f]+$ ]]; then
        lag=$(python3 -c "
w,s='$wal_val'.split('/'),'$slot_val'.split('/')
d=(int(w[0],16)<<32|int(w[1],16))-(int(s[0],16)<<32|int(s[1],16))
print('0 B' if d==0 else f'{d} B' if d<1024 else f'{d/1024:.1f} KB' if d<1048576 else f'{d/1048576:.1f} MB')
" 2>/dev/null) || lag="n/a"
    fi
    printf "  %-20s %b  ${DIM}← WAL Position − Slot LSN${NC}\n" "Replication Lag" "$(_c "$lag" "lag")"

    printf "  "; printf '─%.0s' $(seq 1 50); echo
    echo
}

cleanup_processes() {
    info "Stopping local processes..."
    for pidfile in "$PIDS_DIR"/*.pid; do
        [ -f "$pidfile" ] || continue
        pid=$(cat "$pidfile")
        name=$(basename "$pidfile" .pid)
        if kill -0 "$pid" 2>/dev/null; then
            info "Stopping $name (PID $pid)..."
            kill "$pid" 2>/dev/null || true
            # Wait briefly then force kill
            sleep 1
            kill -9 "$pid" 2>/dev/null || true
        fi
        rm -f "$pidfile"
    done
}

cleanup_docker() {
    info "Stopping Docker infrastructure..."
    cd "$PROJECT_DIR"
    $COMPOSE_CMD -f docker-compose.debezium-local.yml down -v --remove-orphans 2>/dev/null || true
}

cleanup_all() {
    cleanup_processes
    cleanup_docker
}

trap cleanup_processes EXIT

# ---------------------------------------------------------------------------
# Infrastructure setup
# ---------------------------------------------------------------------------

ensure_network() {
    if ! $CONTAINER_RUNTIME network ls | grep -q rbac-network; then
        info "Creating Docker network 'rbac-network'..."
        $CONTAINER_RUNTIME network create rbac-network
    fi
    success "Network 'rbac-network' exists"
}

ensure_database() {
    header "PostgreSQL"

    # Check if rbac_db container is running
    if ! $CONTAINER_RUNTIME ps | grep -q rbac_db; then
        # Try starting an existing stopped container first
        if $CONTAINER_RUNTIME ps -a | grep -q rbac_db; then
            info "Starting existing rbac_db container..."
            $CONTAINER_RUNTIME start rbac_db
        else
            info "Starting PostgreSQL via 'make start-db'..."
            cd "$PROJECT_DIR"
            make start-db
        fi
        sleep 3
    fi

    # Ensure rbac_db is on the shared network so Kafka Connect can reach it
    if ! $CONTAINER_RUNTIME network inspect rbac-network 2>/dev/null | grep -q rbac_db; then
        info "Connecting rbac_db to rbac-network..."
        $CONTAINER_RUNTIME network connect rbac-network rbac_db 2>/dev/null || true
    fi
    success "rbac_db connected to rbac-network"

    # Wait for PostgreSQL to be ready
    info "Waiting for PostgreSQL on port 15432..."
    local attempts=0
    while ! pg_isready -h localhost -p 15432 -U postgres -q 2>/dev/null; do
        attempts=$((attempts + 1))
        if [ $attempts -ge 30 ]; then
            error "PostgreSQL not ready after 30 attempts"
            exit 1
        fi
        sleep 1
    done
    success "PostgreSQL is ready"

    # Enable logical replication
    info "Configuring logical replication..."
    $CONTAINER_RUNTIME exec rbac_db psql -U postgres -c "ALTER SYSTEM SET wal_level = logical;" > /dev/null 2>&1
    $CONTAINER_RUNTIME exec rbac_db psql -U postgres -c "ALTER SYSTEM SET max_replication_slots = 4;" > /dev/null 2>&1
    $CONTAINER_RUNTIME exec rbac_db psql -U postgres -c "ALTER SYSTEM SET max_wal_senders = 4;" > /dev/null 2>&1

    # Check current wal_level
    local current_wal_level=$($CONTAINER_RUNTIME exec rbac_db psql -U postgres -t -c "SHOW wal_level;" | xargs)
    if [ "$current_wal_level" != "logical" ]; then
        warn "wal_level is '$current_wal_level', restarting PostgreSQL..."
        $CONTAINER_RUNTIME restart rbac_db
        sleep 3
        while ! pg_isready -h localhost -p 15432 -U postgres -q 2>/dev/null; do
            sleep 1
        done
        success "PostgreSQL restarted with logical replication"
    else
        success "Logical replication already enabled"
    fi

    # Clean up stale replication slots
    local slots=$($CONTAINER_RUNTIME exec rbac_db psql -U postgres -t -c \
        "SELECT slot_name FROM pg_replication_slots;" 2>/dev/null | xargs)
    if [ -n "$slots" ]; then
        info "Cleaning up replication slots: $slots"
        for slot in $slots; do
            $CONTAINER_RUNTIME exec rbac_db psql -U postgres -c \
                "SELECT pg_drop_replication_slot('$slot');" 2>/dev/null || true
        done
    fi

    # Drop stale publication
    $CONTAINER_RUNTIME exec rbac_db psql -U postgres -c \
        "DROP PUBLICATION IF EXISTS dbz_publication;" > /dev/null 2>&1 || true
}

run_migrations() {
    header "Database Migrations"
    cd "$PROJECT_DIR/rbac"

    info "Running migrations..."
    $PYTHON manage.py migrate --noinput 2>&1 | tail -5 || true
    success "Migrations complete"

    info "Running seeds (platform default groups)..."
    $PYTHON manage.py seeds 2>&1 | tail -5 || true
    success "Seeds complete"
}

start_kafka_infra() {
    header "Kafka + Debezium Infrastructure"
    cd "$PROJECT_DIR"

    # Check if already running
    if $CONTAINER_RUNTIME ps | grep -q insights-rbac-kafka-1; then
        warn "Kafka infrastructure already running"
        return
    fi

    info "Starting Kafka, Zookeeper, Kafka Connect, Kafdrop..."
    $COMPOSE_CMD -f docker-compose.debezium-local.yml up -d

    # Wait for Kafka Connect
    info "Waiting for Kafka Connect (port 8083)..."
    local attempts=0
    while ! curl -s -f http://localhost:8083/connectors > /dev/null 2>&1; do
        attempts=$((attempts + 1))
        if [ $attempts -ge 90 ]; then
            error "Kafka Connect not ready after 90 attempts"
            $CONTAINER_RUNTIME logs insights-rbac-kafka-connect-1 --tail 20
            exit 1
        fi
        echo -n "."
        sleep 2
    done
    echo
    success "Kafka Connect is ready"

    # Create topic
    info "Creating Kafka topic..."
    $CONTAINER_RUNTIME exec insights-rbac-kafka-1 kafka-topics \
        --bootstrap-server localhost:9092 --create \
        --topic outbox.event.relations-replication-event \
        --partitions 1 --replication-factor 1 2>/dev/null || true
    success "Topic ready"
}

create_debezium_connector() {
    header "Debezium Connector"

    # Check if connector exists
    if curl -s http://localhost:8083/connectors | grep -q "rbac-debezium"; then
        local status=$(curl -s http://localhost:8083/connectors/rbac-debezium/status)
        if echo "$status" | grep -q '"state":"FAILED"'; then
            warn "Connector is in FAILED state, recreating..."
            curl -s -X DELETE http://localhost:8083/connectors/rbac-debezium > /dev/null
            sleep 3
        else
            success "Connector already running"
            return
        fi
    fi

    info "Creating Debezium connector..."
    local response=$(curl -s -X POST http://localhost:8083/connectors \
        -H "Content-Type: application/json" \
        -d @"$SCRIPT_DIR/debezium-connector-local.json")

    if echo "$response" | grep -q '"name":"rbac-debezium"'; then
        success "Debezium connector created"
    else
        error "Failed to create connector"
        echo "$response"
        exit 1
    fi

    # Wait for connector to start capturing
    sleep 5
    local status=$(curl -s http://localhost:8083/connectors/rbac-debezium/status)
    if echo "$status" | grep -q '"state":"RUNNING"'; then
        success "Connector is RUNNING"
    else
        warn "Connector status: $status"
    fi
}

# ---------------------------------------------------------------------------
# Local process management
# ---------------------------------------------------------------------------

start_mock_kessel() {
    header "Mock Kessel gRPC Server"

    if [ -f "$PIDS_DIR/mock_kessel.pid" ] && kill -0 $(cat "$PIDS_DIR/mock_kessel.pid") 2>/dev/null; then
        warn "Mock Kessel server already running"
        return
    fi

    info "Starting mock Kessel gRPC server on port 50051..."
    cd "$PROJECT_DIR"
    $PYTHON scripts/local_ryw_test/mock_kessel_server.py 50051 > "$SCRIPT_DIR/mock_kessel.log" 2>&1 &
    echo $! > "$PIDS_DIR/mock_kessel.pid"
    sleep 1

    if kill -0 $(cat "$PIDS_DIR/mock_kessel.pid") 2>/dev/null; then
        success "Mock Kessel server started (PID $(cat "$PIDS_DIR/mock_kessel.pid"))"
    else
        error "Mock Kessel server failed to start"
        cat "$SCRIPT_DIR/mock_kessel.log"
        exit 1
    fi
}

start_api_server() {
    header "RBAC API Server"

    if [ -f "$PIDS_DIR/api_server.pid" ] && kill -0 $(cat "$PIDS_DIR/api_server.pid") 2>/dev/null; then
        warn "API server already running"
        return
    fi

    info "Starting Django API server on port 8000..."
    cd "$PROJECT_DIR/rbac"

    V2_READ_ONLY_API_MODE=False \
    MOCK_KAFKA=True \
    WORKSPACE_HIERARCHY_DEPTH_LIMIT=5 \
    WORKSPACE_ORG_CREATION_LIMIT=3000 \
    DJANGO_LOG_HANDLERS=console \
    DJANGO_LOG_FILE=/tmp/rbac_ryw_test.log \
    $PYTHON manage.py runserver 0.0.0.0:8000 > "$SCRIPT_DIR/api_server.log" 2>&1 &
    echo $! > "$PIDS_DIR/api_server.pid"

    # Wait for server to be ready
    local attempts=0
    while ! curl -s http://localhost:8000/api/v2/workspaces/ > /dev/null 2>&1; do
        attempts=$((attempts + 1))
        if [ $attempts -ge 30 ]; then
            error "API server failed to start"
            tail -30 "$SCRIPT_DIR/api_server.log"
            exit 1
        fi
        sleep 1
    done
    success "API server started (PID $(cat "$PIDS_DIR/api_server.pid"))"
}

start_kafka_consumer() {
    header "RBAC Kafka Consumer"

    if [ -f "$PIDS_DIR/kafka_consumer.pid" ] && kill -0 $(cat "$PIDS_DIR/kafka_consumer.pid") 2>/dev/null; then
        warn "Kafka consumer already running"
        return
    fi

    info "Starting Kafka consumer (connecting to localhost:29092)..."
    cd "$PROJECT_DIR/rbac"

    KAFKA_ENABLED=True \
    RBAC_KAFKA_CUSTOM_CONSUMER_BROKER=localhost:29092 \
    RBAC_KAFKA_CONSUMER_TOPIC=outbox.event.relations-replication-event \
    RBAC_KAFKA_CONSUMER_GROUP_ID=rbac-consumer-group-local \
    DJANGO_LOG_HANDLERS=console \
    DJANGO_LOG_FILE=/tmp/rbac_consumer_ryw_test.log \
    $PYTHON manage.py launch-rbac-kafka-consumer > "$SCRIPT_DIR/kafka_consumer.log" 2>&1 &
    echo $! > "$PIDS_DIR/kafka_consumer.pid"

    # Give consumer time to connect and subscribe
    sleep 5

    if kill -0 $(cat "$PIDS_DIR/kafka_consumer.pid") 2>/dev/null; then
        success "Kafka consumer started (PID $(cat "$PIDS_DIR/kafka_consumer.pid"))"
    else
        error "Kafka consumer failed to start"
        tail -30 "$SCRIPT_DIR/kafka_consumer.log"
        exit 1
    fi
}

# ---------------------------------------------------------------------------
# Test execution
# ---------------------------------------------------------------------------

run_test() {
    header "Running RYW Pipeline Test — Init Phase"
    cd "$PROJECT_DIR"

    $PYTHON scripts/local_ryw_test/test_ryw.py \
        --api-url http://localhost:8000 \
        --db-host localhost \
        --db-port 15432 \
        --listen \
        --save-results "$SCRIPT_DIR/init_results.json"
}

backup_database() {
    header "Database Backup"
    local timestamp=$(date +%Y%m%d_%H%M%S)
    local backup_file="rbac_backup_${timestamp}.sql"
    LAST_BACKUP_FILE="/tmp/${backup_file}"

    info "Backing up database to ${LAST_BACKUP_FILE} ..."
    $CONTAINER_RUNTIME exec rbac_db pg_dump -U postgres postgres > "${LAST_BACKUP_FILE}"
    success "Database backed up to ${LAST_BACKUP_FILE} ($(du -h "${LAST_BACKUP_FILE}" | cut -f1))"
}

stop_database() {
    header "Stopping PostgreSQL"
    if $CONTAINER_RUNTIME ps | grep -q rbac_db; then
        info "Stopping rbac_db container..."
        $CONTAINER_RUNTIME stop rbac_db
        success "rbac_db stopped"
    else
        warn "rbac_db is not running"
    fi
}

stop_debezium_connector() {
    header "Stopping Debezium Connector"
    if curl -s http://localhost:8083/connectors 2>/dev/null | grep -q "rbac-debezium"; then
        info "Deleting Debezium connector (offsets stay in connect-offsets topic)..."
        curl -s -X DELETE http://localhost:8083/connectors/rbac-debezium > /dev/null
        sleep 2
        success "Debezium connector deleted"
    else
        warn "Debezium connector not found (Kafka Connect may be down)"
    fi
}

start_debezium_connector() {
    header "Starting Debezium Connector"
    info "Recreating Debezium connector (will read old offsets from connect-offsets)..."
    local response=$(curl -s -X POST http://localhost:8083/connectors \
        -H "Content-Type: application/json" \
        -d @"$SCRIPT_DIR/debezium-connector-local.json")

    if echo "$response" | grep -q '"name":"rbac-debezium"'; then
        success "Debezium connector created"
    else
        error "Failed to create connector"
        echo "$response"
    fi
}

check_debezium_running() {
    header "Debezium Connector Status Check"
    echo
    local response http_code tmpfile
    tmpfile=$(mktemp)
    http_code=$(curl -s -o "$tmpfile" -w '%{http_code}' http://localhost:8083/connectors/rbac-debezium/status 2>/dev/null) || true
    response=$(<"$tmpfile")
    rm -f "$tmpfile"
    if [ "$http_code" = "000" ]; then
        warn "Kafka Connect not reachable"
        return
    fi
    if [ "$http_code" = "404" ]; then
        warn "Connector 'rbac-debezium' does not exist (HTTP 404)"
        return
    fi
    if [ -z "$response" ]; then
        warn "Empty response from Kafka Connect (HTTP $http_code)"
        return
    fi

    # Parse all fields with a single Python call for clean formatting
    # Note: pass JSON via env var, NOT stdin — heredoc uses stdin for the Python code
    local parsed
    parsed=$(DBZ_RESPONSE="$response" python3 << 'PYEOF'
import json, os, re

try:
    d = json.loads(os.environ['DBZ_RESPONSE'])
except (json.JSONDecodeError, ValueError, KeyError):
    print("PARSE_ERROR='true'")
    raise SystemExit(0)
conn = d.get('connector', {})
tasks = d.get('tasks', [])
task = tasks[0] if tasks else {}

connector_state = conn.get('state', 'UNKNOWN')
connector_worker = conn.get('worker_id', '?')
task_state = task.get('state', 'NO_TASKS')
task_worker = task.get('worker_id', '?')
task_id = task.get('id', '?')
trace = task.get('trace', '')

error_msg = ''
error_class = ''
stored_lsn = ''
stack_frames = []
if trace:
    lines = trace.strip().split('\n')
    first_line = lines[0] if lines else ''
    m = re.match(r'^([\w.]+Exception):\s*(.+)', first_line)
    if m:
        error_class = m.group(1).split('.')[-1]
        full_msg = m.group(2)
        lsn_match = re.search(r'lsn=LSN\{([^}]+)\}', full_msg)
        if lsn_match:
            stored_lsn = lsn_match.group(1)
        clean = re.sub(
            r'PostgresOffsetContext \[.*?\]',
            'LSN{' + stored_lsn + '}' if stored_lsn else '<unavailable>',
            full_msg)
        error_msg = clean.strip()
    else:
        error_msg = first_line

    for line in lines[1:]:
        line = line.strip()
        if line.startswith('at '):
            frame = line[3:]
            if 'debezium' in frame or 'kafka.connect' in frame:
                frame = frame.replace('io.debezium.connector.common.', 'debezium...')
                frame = frame.replace('io.debezium.connector.postgresql.', 'debezium.pg...')
                frame = frame.replace('org.apache.kafka.connect.runtime.', 'kafka.connect...')
                stack_frames.append(frame)

# Quote values for safe shell eval
def q(s):
    return "'" + str(s).replace("'", "'\\''") + "'"

print('CONNECTOR_STATE=' + q(connector_state))
print('CONNECTOR_WORKER=' + q(connector_worker))
print('TASK_ID=' + q(task_id))
print('TASK_STATE=' + q(task_state))
print('TASK_WORKER=' + q(task_worker))
print('ERROR_CLASS=' + q(error_class))
print('ERROR_MSG=' + q(error_msg))
print('STORED_LSN=' + q(stored_lsn))
print('STACK_FRAMES=' + q('|'.join(stack_frames[:5])))
PYEOF
    )

    if [ -z "$parsed" ]; then
        warn "Could not parse connector status, showing raw response:"
        echo "$response" | python3 -m json.tool 2>/dev/null || echo "$response"
        return
    fi

    # Load parsed values into shell variables
    eval "$parsed"

    if [ "${PARSE_ERROR:-}" = "true" ]; then
        warn "Response is not valid JSON, showing raw response:"
        echo "$response"
        return
    fi

    # Display formatted status
    echo -e "  Connector:  ${CONNECTOR_STATE}  (worker: ${CONNECTOR_WORKER})"
    echo -e "  Task 0:     ${TASK_STATE}  (worker: ${TASK_WORKER})"

    if [ "$TASK_STATE" = "FAILED" ] || [ "$CONNECTOR_STATE" = "FAILED" ]; then
        echo
        echo -e "  ${RED}╔══════════════════════════════════════════════════════════╗${NC}"
        echo -e "  ${RED}║  CONNECTOR TASK FAILED                                  ║${NC}"
        echo -e "  ${RED}╚══════════════════════════════════════════════════════════╝${NC}"
        echo
        echo -e "  ${RED}Exception:${NC}  ${ERROR_CLASS}"
        if [ -n "$STORED_LSN" ]; then
            echo -e "  ${RED}Stored LSN:${NC} ${STORED_LSN}  (no longer available on PostgreSQL server)"
        fi
        echo
        echo -e "  ${RED}Message:${NC}"
        echo -e "    ${ERROR_MSG}" | fold -s -w 72 | sed 's/^/    /'
        if [ -n "$STACK_FRAMES" ]; then
            echo
            echo -e "  ${YELLOW}Stack trace (Debezium + Kafka Connect frames):${NC}"
            echo "$STACK_FRAMES" | tr '|' '\n' | while read -r frame; do
                echo -e "    at ${frame}"
            done
        fi
        echo
        echo -e "  ${CYAN}Root cause:${NC} Debezium has a stored offset in Kafka connect-offsets but"
        echo -e "  the replication slot does not exist on the restored database. Slots are"
        echo -e "  cluster-level objects tied to a DB by OID and not included in pg_dump."
        echo -e "  Since Debezium 3.2 (DBZ-9118), this is a fatal error instead of a warning."
        echo
        echo -e "  ${CYAN}Fix (Kafka Connect 3.6+):${NC} Use the offset reset API:"
        echo -e "    1. ${GREEN}PUT  /connectors/<name>/stop${NC}     — stop the connector"
        echo -e "    2. ${GREEN}DELETE /connectors/<name>/offsets${NC} — reset stored offsets"
        echo -e "    3. ${GREEN}PUT  /connectors/<name>/resume${NC}   — resume with fresh state"
    elif [ "$TASK_STATE" = "RUNNING" ] && [ "$CONNECTOR_STATE" = "RUNNING" ]; then
        echo
        success "Connector and task are RUNNING"
    fi

    # Check Kafka Connect logs for recent errors/warnings
    echo
    echo "  --- Recent Kafka Connect errors/warnings ---"
    local log_errors
    log_errors=$($CONTAINER_RUNTIME logs insights-rbac-kafka-connect-1 --tail 50 2>&1 \
        | grep -i "error\|warn\|fail\|cannot" \
        | grep -i "slot\|replication\|offset\|lsn\|connect" \
        | tail -10)
    if [ -n "$log_errors" ]; then
        echo -e "${YELLOW}${log_errors}${NC}"
    else
        echo "  (no recent replication errors in logs)"
    fi
}

drop_replication_slot() {
    header "Dropping Replication Slot"
    local slot_count
    slot_count=$($CONTAINER_RUNTIME exec rbac_db psql -U postgres -t -c \
        "SELECT COUNT(*) FROM pg_replication_slots WHERE slot_name = 'debezium';" \
        2>/dev/null | xargs) || true
    if [ "${slot_count:-0}" -gt 0 ]; then
        info "Dropping replication slot 'debezium'..."
        $CONTAINER_RUNTIME exec rbac_db psql -U postgres -c \
            "SELECT pg_drop_replication_slot('debezium');" > /dev/null 2>&1 || true
        success "Replication slot dropped"
    else
        info "No replication slot 'debezium' found (expected — slots are not in pg_dump)"
    fi
}

restore_database() {
    header "Database Restore"
    local backup_file="$1"

    if [ ! -f "$backup_file" ]; then
        error "Backup file not found: $backup_file"
        return 1
    fi

    # Start rbac_db if not running
    if ! $CONTAINER_RUNTIME ps | grep -q rbac_db; then
        info "Starting rbac_db container..."
        $CONTAINER_RUNTIME start rbac_db
        sleep 3
    fi

    # Wait for PostgreSQL to be ready
    info "Waiting for PostgreSQL..."
    local attempts=0
    while ! pg_isready -h localhost -p 15432 -U postgres -q 2>/dev/null; do
        attempts=$((attempts + 1))
        if [ $attempts -ge 30 ]; then
            error "PostgreSQL not ready after 30 attempts"
            return 1
        fi
        sleep 1
    done

    # Terminate all connections to the database
    info "Terminating existing connections..."
    $CONTAINER_RUNTIME exec rbac_db psql -U postgres -d template1 -c \
        "SELECT pg_terminate_backend(pid) FROM pg_stat_activity WHERE datname = 'postgres' AND pid <> pg_backend_pid();" \
        > /dev/null 2>&1 || true

    # Rename current database (preserves it for inspection, keeps replication slot alive)
    local old_db="postgres_pre_restore_$(date +%H%M%S)"
    info "Renaming current database to '${old_db}' (preserving old data)..."
    $CONTAINER_RUNTIME exec rbac_db psql -U postgres -d template1 -c \
        "ALTER DATABASE postgres RENAME TO ${old_db};" > /dev/null 2>&1 || true

    # Create fresh database and restore
    info "Creating new database 'postgres'..."
    $CONTAINER_RUNTIME exec rbac_db createdb -U postgres postgres

    info "Restoring from ${backup_file} ..."
    cat "$backup_file" | $CONTAINER_RUNTIME exec -i rbac_db psql -U postgres postgres > /dev/null 2>&1
    success "Database restored from ${backup_file}"
    info "Old database preserved as '${old_db}'"
    info "Replication slot is NOT in pg_dump — new database has no slot"

    # Ensure rbac_db is on the shared network
    if ! $CONTAINER_RUNTIME network inspect rbac-network 2>/dev/null | grep -q rbac_db; then
        info "Reconnecting rbac_db to rbac-network..."
        $CONTAINER_RUNTIME network connect rbac-network rbac_db 2>/dev/null || true
    fi

    # Re-enable logical replication (might be lost after restore)
    info "Re-configuring logical replication..."
    $CONTAINER_RUNTIME exec rbac_db psql -U postgres -d template1 -c \
        "ALTER SYSTEM SET wal_level = logical;" > /dev/null 2>&1 || true
    $CONTAINER_RUNTIME exec rbac_db psql -U postgres -d template1 -c \
        "ALTER SYSTEM SET max_replication_slots = 4;" > /dev/null 2>&1 || true
    $CONTAINER_RUNTIME exec rbac_db psql -U postgres -d template1 -c \
        "ALTER SYSTEM SET max_wal_senders = 4;" > /dev/null 2>&1 || true

    local current_wal_level
    current_wal_level=$($CONTAINER_RUNTIME exec rbac_db psql -U postgres -d template1 -t -c \
        "SHOW wal_level;" 2>/dev/null | xargs) || true
    if [ "$current_wal_level" != "logical" ]; then
        warn "wal_level is '$current_wal_level', restarting PostgreSQL..."
        $CONTAINER_RUNTIME restart rbac_db
        sleep 3
        while ! pg_isready -h localhost -p 15432 -U postgres -q 2>/dev/null; do
            sleep 1
        done
        success "PostgreSQL restarted with logical replication"
    fi
    success "Database restored and logical replication configured"
}

recover_debezium_connector() {
    header "Recovering Debezium Connector (Kafka Connect 3.6+ Offset Reset)"
    echo
    info "Step 1/8: Check connector state..."
    local conn_http_code
    conn_http_code=$(curl -s -o /dev/null -w '%{http_code}' \
        http://localhost:8083/connectors/rbac-debezium/status 2>/dev/null) || true

    if [ "$conn_http_code" = "404" ]; then
        warn "Connector 'rbac-debezium' does not exist — creating it first..."
        local create_resp
        create_resp=$(curl -s -X POST http://localhost:8083/connectors \
            -H "Content-Type: application/json" \
            -d @"$SCRIPT_DIR/debezium-connector-local.json")
        if echo "$create_resp" | grep -q '"name":"rbac-debezium"'; then
            success "Connector created (will likely FAIL due to stale offset / missing slot)"
            sleep 5
        else
            error "Failed to create connector"
            echo "$create_resp"
            return 1
        fi
    elif [ "$conn_http_code" = "000" ]; then
        error "Kafka Connect is not reachable"
        return 1
    else
        success "Connector exists (HTTP $conn_http_code)"
    fi

    info "Step 2/8: Show Debezium stored offset BEFORE recovery..."
    echo "  --- Debezium Committed Offset (connect-offsets) ---"
    $CONTAINER_RUNTIME exec insights-rbac-kafka-1 kafka-console-consumer \
        --bootstrap-server localhost:9092 \
        --topic my_connect_offsets \
        --from-beginning \
        --property print.key=true \
        --property key.separator=" => " \
        --timeout-ms 5000 \
        2>/dev/null | tail -5 || echo "(not available)"
    echo
    echo "  --- Kafka Consumer Group Offset BEFORE recovery ---"
    $CONTAINER_RUNTIME exec insights-rbac-kafka-1 kafka-consumer-groups \
        --bootstrap-server localhost:9092 \
        --group rbac-consumer-group-local \
        --describe 2>/dev/null || echo "(not available)"

    info "Step 3/8: Stop the connector (PUT /connectors/rbac-debezium/stop)..."
    local stop_code
    stop_code=$(curl -s -o /dev/null -w '%{http_code}' -X PUT \
        -H "Content-Type: application/json" \
        http://localhost:8083/connectors/rbac-debezium/stop 2>/dev/null) || true
    if [ "$stop_code" = "202" ] || [ "$stop_code" = "204" ] || [ "$stop_code" = "200" ]; then
        success "Connector stop accepted (HTTP $stop_code)"
    else
        warn "Stop returned HTTP $stop_code (connector may already be stopped)"
    fi
    info "Waiting for connector to gracefully shutdown (5s)..."
    sleep 5

    info "Step 4/8: Reset connector offsets (DELETE /connectors/rbac-debezium/offsets)..."
    info "  (Schema history topic removal skipped — not needed for PostgreSQL connectors)"
    local reset_tmpfile reset_code reset_response
    reset_tmpfile=$(mktemp)
    reset_code=$(curl -s -o "$reset_tmpfile" -w '%{http_code}' -X DELETE \
        -H "Content-Type: application/json" \
        http://localhost:8083/connectors/rbac-debezium/offsets 2>/dev/null) || true
    reset_response=$(<"$reset_tmpfile")
    rm -f "$reset_tmpfile"
    if [ "$reset_code" = "200" ]; then
        success "Connector offsets reset successfully (HTTP $reset_code)"
        echo "  Response: $reset_response"
    else
        warn "Offset reset returned HTTP $reset_code"
        echo "  Response: $reset_response"
        if echo "$reset_response" | grep -qi "must be in.*stop\|is not stopped"; then
            error "Connector must be in STOPPED state before resetting offsets."
            error "Ensure PUT /stop succeeded before retrying."
            return 1
        fi
    fi

    info "Step 5/8: Drop old replication slot if it exists..."
    $CONTAINER_RUNTIME exec rbac_db psql -U postgres -c \
        "SELECT slot_name, restart_lsn, confirmed_flush_lsn FROM pg_replication_slots WHERE slot_name = 'debezium';" \
        2>/dev/null || echo "(no slot found)"
    if $CONTAINER_RUNTIME exec rbac_db psql -U postgres -t -c \
        "SELECT COUNT(*) FROM pg_replication_slots WHERE slot_name = 'debezium';" 2>/dev/null | grep -q "1"; then
        $CONTAINER_RUNTIME exec rbac_db psql -U postgres -c \
            "SELECT pg_drop_replication_slot('debezium');" > /dev/null 2>&1
        success "Old replication slot dropped"
    else
        info "No existing replication slot to drop (expected after DB restore)"
    fi

    info "Step 6/8: Resume the connector (PUT /connectors/rbac-debezium/resume)..."
    local resume_code
    resume_code=$(curl -s -o /dev/null -w '%{http_code}' -X PUT \
        -H "Content-Type: application/json" \
        http://localhost:8083/connectors/rbac-debezium/resume 2>/dev/null) || true
    if [ "$resume_code" = "202" ] || [ "$resume_code" = "200" ]; then
        success "Connector resume accepted (HTTP $resume_code)"
    else
        warn "Resume returned HTTP $resume_code"
    fi

    info "Waiting for connector to start and perform initial snapshot (15s)..."
    sleep 15

    info "Step 7/8: Verify connector is RUNNING and check LSN..."
    echo
    check_debezium_running

    echo
    echo "  --- Replication Slot After Recovery ---"
    $CONTAINER_RUNTIME exec rbac_db psql -U postgres -c \
        "SELECT slot_name, restart_lsn, confirmed_flush_lsn FROM pg_replication_slots WHERE slot_name = 'debezium';" \
        2>/dev/null || echo "(no slot)"

    echo
    echo "  --- Current WAL Position ---"
    $CONTAINER_RUNTIME exec rbac_db psql -U postgres -t -c \
        "SELECT pg_current_wal_lsn();" 2>/dev/null || echo "(not available)"

    echo
    info "Recovery complete (offsets reset via Kafka Connect 3.6+ API)."
    info "Connector is streaming from the current WAL position."
    info "Events from the gap (between backup and restore) are skipped — this is expected."

    info "Step 8/8: Post-recovery verification — create workspaces and check consumer offset..."
    echo

    # Helper: capture pipeline state into a set of variables with a given prefix
    # Usage: capture_pipeline_state "before"  →  sets slot_lsn_before, consumer_offset_before, etc.
    capture_pipeline_state() {
        local prefix="$1"
        local _slot _consumer _wal _dbz_lsn _kafka_log_end

        _slot=$($CONTAINER_RUNTIME exec rbac_db psql -U postgres -t -c \
            "SELECT COALESCE(confirmed_flush_lsn::text, 'n/a') FROM pg_replication_slots WHERE slot_name = 'debezium';" \
            2>/dev/null | xargs) || true

        # kafka-consumer-groups --describe: CURRENT-OFFSET is column 4, LOG-END-OFFSET is column 5
        local cg_line
        cg_line=$($CONTAINER_RUNTIME exec insights-rbac-kafka-1 kafka-consumer-groups \
            --bootstrap-server localhost:9092 \
            --group rbac-consumer-group-local \
            --describe 2>/dev/null \
            | grep "outbox.event") || true
        _consumer=$(echo "$cg_line" | awk '{print $4}')
        _kafka_log_end=$(echo "$cg_line" | awk '{print $5}')

        _wal=$($CONTAINER_RUNTIME exec rbac_db psql -U postgres -t -c \
            "SELECT pg_current_wal_lsn();" 2>/dev/null | xargs) || true

        # Debezium stores LSN as integer in connect-offsets; convert to PG hex format
        _dbz_lsn=$($CONTAINER_RUNTIME exec insights-rbac-kafka-1 kafka-console-consumer \
            --bootstrap-server localhost:9092 \
            --topic my_connect_offsets \
            --from-beginning \
            --timeout-ms 5000 \
            2>/dev/null | tail -1 | python3 -c "
import sys, json
try:
    d = json.load(sys.stdin)
    lsn = d.get('lsn')
    if lsn is not None:
        hi = int(lsn) >> 32
        lo = int(lsn) & 0xFFFFFFFF
        print(f'{hi:X}/{lo:08X}')
    else:
        print('n/a')
except Exception:
    print('n/a')
" 2>/dev/null) || true

        eval "slot_lsn_${prefix}='${_slot:-no slot}'"
        eval "consumer_offset_${prefix}='${_consumer:--}'"
        eval "kafka_log_end_${prefix}='${_kafka_log_end:--}'"
        eval "wal_lsn_${prefix}='${_wal:-n/a}'"
        eval "debezium_lsn_${prefix}='${_dbz_lsn:-n/a}'"
    }

    capture_pipeline_state "before"

    echo "  --- State BEFORE post-recovery test ---"
    echo "  Replication Slot LSN:  $slot_lsn_before"
    echo "  Debezium Stored LSN:   $debezium_lsn_before"
    echo "  Kafka Log-End Offset:  $kafka_log_end_before"
    echo "  Consumer Offset:       $consumer_offset_before"
    echo "  WAL Position:          $wal_lsn_before"

    echo
    info "Creating 2 workspaces after recovery to verify the pipeline works..."
    cd "$PROJECT_DIR"
    $PYTHON scripts/local_ryw_test/test_ryw.py \
        --api-url http://localhost:8000 \
        --db-host localhost \
        --db-port 15432 \
        --count 2

    sleep 5  # Let Debezium capture + consumer process messages

    capture_pipeline_state "after"

    # Comparison table
    echo
    echo -e "  ${CYAN}╔══════════════════════════════════════════════════════════════════════╗${NC}"
    echo -e "  ${CYAN}║           Post-Recovery Pipeline Comparison                        ║${NC}"
    echo -e "  ${CYAN}╠═══════════════════════╦═════════════════════╦════════════════════════╣${NC}"
    echo -e "  ${CYAN}║${NC} Metric                ${CYAN}║${NC} Before              ${CYAN}║${NC} After                ${CYAN}║${NC}"
    echo -e "  ${CYAN}╠═══════════════════════╬═════════════════════╬════════════════════════╣${NC}"
    printf "  ${CYAN}║${NC} %-21s ${CYAN}║${NC} %-19s ${CYAN}║${NC} %-22s ${CYAN}║${NC}\n" "Replication Slot LSN" "$slot_lsn_before" "$slot_lsn_after"
    printf "  ${CYAN}║${NC} %-21s ${CYAN}║${NC} %-19s ${CYAN}║${NC} %-22s ${CYAN}║${NC}\n" "Debezium Stored LSN" "$debezium_lsn_before" "$debezium_lsn_after"
    printf "  ${CYAN}║${NC} %-21s ${CYAN}║${NC} %-19s ${CYAN}║${NC} %-22s ${CYAN}║${NC}\n" "Kafka Log-End Offset" "$kafka_log_end_before" "$kafka_log_end_after"
    printf "  ${CYAN}║${NC} %-21s ${CYAN}║${NC} %-19s ${CYAN}║${NC} %-22s ${CYAN}║${NC}\n" "Consumer Offset" "$consumer_offset_before" "$consumer_offset_after"
    printf "  ${CYAN}║${NC} %-21s ${CYAN}║${NC} %-19s ${CYAN}║${NC} %-22s ${CYAN}║${NC}\n" "WAL Position" "$wal_lsn_before" "$wal_lsn_after"
    echo -e "  ${CYAN}╚═══════════════════════╩═════════════════════╩════════════════════════╝${NC}"

    echo
    # Check multiple signals: slot LSN advanced, or Kafka log-end advanced, or consumer advanced
    local pipeline_ok=false
    if [ "$slot_lsn_before" != "$slot_lsn_after" ] && [ "$slot_lsn_after" != "no slot" ]; then
        pipeline_ok=true
        success "Replication Slot LSN advanced ($slot_lsn_before -> $slot_lsn_after)"
    fi
    if [ "$kafka_log_end_before" != "$kafka_log_end_after" ] && [ "$kafka_log_end_after" != "-" ]; then
        pipeline_ok=true
        success "Kafka Log-End Offset advanced ($kafka_log_end_before -> $kafka_log_end_after)"
    fi
    if [ "$consumer_offset_before" != "$consumer_offset_after" ] && [ "$consumer_offset_after" != "-" ]; then
        pipeline_ok=true
        success "Consumer Offset advanced ($consumer_offset_before -> $consumer_offset_after)"
    fi
    if [ "$pipeline_ok" = true ]; then
        echo
        success "Pipeline is working after recovery!"
    else
        echo
        warn "No offset changes detected — pipeline may not be working. Check logs."
    fi
}

run_phase2() {
    header "Running RYW Pipeline Test — Phase 2"
    cd "$PROJECT_DIR"

    if [ ! -f "$SCRIPT_DIR/init_results.json" ]; then
        error "No init results found. Run the full test first."
        return 1
    fi

    $PYTHON scripts/local_ryw_test/test_ryw.py \
        --api-url http://localhost:8000 \
        --db-host localhost \
        --db-port 15432 \
        --phase2-from "$SCRIPT_DIR/init_results.json"
}

show_logs() {
    header "Recent Logs"
    echo
    echo "--- Mock Kessel Server ---"
    tail -10 "$SCRIPT_DIR/mock_kessel.log" 2>/dev/null || echo "(no log)"
    echo
    echo "--- Kafka Consumer ---"
    tail -20 "$SCRIPT_DIR/kafka_consumer.log" 2>/dev/null || echo "(no log)"
    echo
    echo "--- API Server (last errors) ---"
    grep -i "error\|exception\|traceback" "$SCRIPT_DIR/api_server.log" 2>/dev/null | tail -10 || echo "(no errors)"
}

show_diagnostics() {
    header "Pipeline Diagnostics"

    echo
    echo "--- Workspace Count ---"
    $CONTAINER_RUNTIME exec rbac_db psql -U postgres -c \
        "SELECT tenant_id, COUNT(*) AS workspace_count FROM management_workspace GROUP BY tenant_id ORDER BY workspace_count DESC;" \
        2>/dev/null || echo "(not available — database may be down)"

    echo
    echo "--- PostgreSQL Replication Slots ---"
    $CONTAINER_RUNTIME exec rbac_db psql -U postgres -c \
        "SELECT slot_name, plugin, slot_type, active, restart_lsn, confirmed_flush_lsn FROM pg_replication_slots;" \
        2>/dev/null || echo "(not available)"

    echo
    echo "--- Kafka Consumer Group Offsets ---"
    $CONTAINER_RUNTIME exec insights-rbac-kafka-1 kafka-consumer-groups \
        --bootstrap-server localhost:9092 \
        --group rbac-consumer-group-local \
        --describe 2>/dev/null || echo "(not available)"

    echo
    echo "--- Debezium Connector Status ---"
    curl -s http://localhost:8083/connectors/rbac-debezium/status 2>/dev/null \
        | python3 -m json.tool 2>/dev/null || echo "(not available)"

    echo
    echo "--- Kafka connect-offsets (Debezium offsets) ---"
    $CONTAINER_RUNTIME exec insights-rbac-kafka-1 kafka-console-consumer \
        --bootstrap-server localhost:9092 \
        --topic my_connect_offsets \
        --from-beginning \
        --property print.key=true \
        --property key.separator=" => " \
        --timeout-ms 5000 \
        2>/dev/null || echo "(not available)"

    echo
    echo "--- Kafka Topic Offsets (outbox.event.relations-replication-event) ---"
    $CONTAINER_RUNTIME exec insights-rbac-kafka-1 kafka-run-class kafka.tools.GetOffsetShell \
        --broker-list localhost:9092 \
        --topic outbox.event.relations-replication-event \
        2>/dev/null || echo "(not available)"
}

# ---------------------------------------------------------------------------
# Main
# ---------------------------------------------------------------------------

CHECKPOINTS_ONLY=false
if [ "${1:-}" = "--compact" ]; then
    CHECKPOINTS_ONLY=true
    shift
fi

_run() {
    local msg="$1"; shift
    if [ "$CHECKPOINTS_ONLY" = true ]; then
        echo -e "  ${DIM}▸ ${msg}${NC}"
        "$@" > /dev/null 2>&1 || true
    else
        "$@"
    fi
}

case "${1:-}" in
    --help|-h)
        echo "Usage: $0 [OPTION]"
        echo
        echo "Options:"
        echo "  (none)     Full setup + test: start infra, services, run test"
        echo "  --compact  Same as above but only show checkpoint tables + phase one-liners"
        echo "  --test     Run test only (assumes infra and services are already up)"
        echo "  --clean    Stop all processes and Docker containers"
        echo "  --logs     Show recent logs from all components"
        echo "  --diag     Show pipeline diagnostics (replication slots, offsets)"
        echo "  --infra    Start Docker infrastructure only"
        echo "  --services Start local services only (mock Kessel, API, consumer)"
        echo "  --check-connector  Check Debezium connector status"
        echo "  --recover  Recover failed connector using Kafka Connect 3.6+ offset reset"
        echo "  --help     Show this help"
        echo
        echo "Log files:"
        echo "  $SCRIPT_DIR/mock_kessel.log"
        echo "  $SCRIPT_DIR/api_server.log"
        echo "  $SCRIPT_DIR/kafka_consumer.log"
        ;;

    --clean)
        header "Cleanup"
        cleanup_all
        success "All cleaned up"
        ;;

    --logs)
        show_logs
        ;;

    --diag)
        show_diagnostics
        ;;

    --test)
        run_test
        show_logs
        ;;

    --infra)
        ensure_network
        ensure_database
        run_migrations
        start_kafka_infra
        create_debezium_connector
        success "Infrastructure ready"
        ;;

    --services)
        start_mock_kessel
        start_api_server
        start_kafka_consumer
        success "Services ready"
        ;;

    --check-connector)
        check_debezium_running
        ;;

    --recover)
        recover_debezium_connector
        ;;

    *)
        if [ "$CHECKPOINTS_ONLY" != true ]; then
            header "Local RYW Pipeline Test"
            echo
            info "Using $CONTAINER_RUNTIME"
            echo
        fi

        # Phase 1-2: Infrastructure + services
        _run "Phase 1: Creating network..." ensure_network
        _run "Phase 1: Setting up PostgreSQL..." ensure_database
        _run "Phase 1: Running migrations..." run_migrations
        _run "Phase 1: Starting Kafka + Debezium..." start_kafka_infra
        _run "Phase 1: Creating Debezium connector..." create_debezium_connector
        _run "Phase 2: Starting mock Kessel..." start_mock_kessel
        _run "Phase 2: Starting API server..." start_api_server
        _run "Phase 2: Starting Kafka consumer..." start_kafka_consumer

        # Phase 3: Pipeline test (create, backup, delete, create)
        sleep 3
        _run "Phase 3a: Creating 3 workspaces..." run_test
        _run "Phase 3b: Backing up database for later restore..." backup_database
        _run "Phase 3c+3d: Deleting 2 + creating 2 workspaces..." run_phase2
        _run "Phase 3: Collecting logs..." show_logs
        _run "Phase 3: Running diagnostics..." show_diagnostics

        if [ "$CHECKPOINTS_ONLY" != true ]; then
            echo
            success "========================================="
            success "  Pipeline test complete"
            success "========================================="
            echo
        fi

        # ── CP1: Everything healthy before disaster ──
        capture_checkpoint "Healthy" "Phase 3"

        # Phase 4: Stop DB only — connector stays registered
        _run "Phase 4: Stopping database..." stop_database

        # Phase 5: Restore database from backup + drop stale slot
        _run "Phase 5: Restoring database from backup..." restore_database "$LAST_BACKUP_FILE"
        _run "Phase 5: Dropping stale replication slot..." drop_replication_slot
        _run "Phase 5: Waiting for connector to detect missing slot (15s)..." sleep 15
        _run "Phase 5: Checking connector status..." check_debezium_running

        # ── CP2: DB restored, slot dropped, connector FAILED ──
        capture_checkpoint "DB restored" "Phase 5"

        # Phase 6: Delete the failed connector
        _run "Phase 6: Deleting failed connector..." stop_debezium_connector

        # ── CP3: Connector deleted, stale offset stays in Kafka ──
        capture_checkpoint "Conn deleted" "Phase 6"

        # Phase 7: Recreate connector (default config) → FAILS again
        _run "Phase 7: Recreating connector (default config)..." start_debezium_connector
        _run "Phase 7: Waiting for connector to fail (15s)..." sleep 15
        _run "Phase 7: Checking connector status..." check_debezium_running

        # ── CP4: Recreated but FAILED (stale LSN, no slot) ──
        capture_checkpoint "Conn recreated" "Phase 7"

        # Phase 8: Fix — recover with Kafka Connect 3.6+ offset reset API (KIP-875)
        _run "Phase 8: Recovering with Kafka Connect 3.6+ offset reset..." recover_debezium_connector

        # ── CP5: Fixed with offset reset (stop → delete offsets → resume) ──
        capture_checkpoint "Fixed" "Phase 8"

        # Phase 9: Create data to prove the pipeline is live
        _run "Phase 9: Creating 2 workspaces to trigger CDC pipeline..." \
            $PYTHON scripts/local_ryw_test/test_ryw.py \
                --api-url http://localhost:8000 \
                --db-host localhost \
                --db-port 15432 \
                --count 2
        _run "Phase 9: Waiting for Debezium to flush new offset (10s)..." sleep 10

        # ── CP6: Offset Topic LSN should have advanced (old entry superseded) ──
        capture_checkpoint "New data" "Phase 9"

        echo
        info "Services are still running. Use '$0 --clean' to stop everything."
        info "Use '$0 --test' to re-run the test."
        info "Use '$0 --recover' to re-run recovery only."
        info "Kafdrop UI: http://localhost:9001"
        ;;
esac
