#!/bin/bash
set -e

export ACCESS_CACHE_CONNECT_SIGNALS=False

echo "Starting init container script."
MIGRATE=$(echo "$MIGRATE_AND_SEED_ON_INIT" | tr '[:upper:]' '[:lower:]')

if [[ "$MIGRATE" = "true" ]]
then
    # In ephemeral/test, this makes sure the db is available when init container run
    python /opt/rbac/rbac/manage.py wait_for_db

    echo "Running schema migrations <----"
    python /opt/rbac/rbac/manage.py migrate --noinput

    # In Ephemeral, wait for Debezium connector to be streaming before seeds write to outbox
    if [[ "${REPLICATION_TO_RELATION_ENABLED}" == "True" && "${EPH_ENV}" == "True" ]]; then
        echo "Waiting for rbac-debezium connector to be RUNNING..."
        MAX_WAIT=120
        ELAPSED=0
        # In ephemeral, the connect instance is the same as the namespace
        KAFKA_CONNECT_URL="http://kessel-kafka-connect-connect-api:8083"
        while [[ $ELAPSED -lt $MAX_WAIT ]]; do
            if python3 /opt/rbac/deploy/check_debezium.py "$KAFKA_CONNECT_URL"; then
                echo "rbac-debezium connector and task are RUNNING."
                break
            fi
            sleep 2
            ELAPSED=$((ELAPSED + 2))
        done
        if [[ $ELAPSED -ge $MAX_WAIT ]]; then
            echo "WARNING: Debezium not ready after ${MAX_WAIT}s. Seeds will run but outbox events may be lost."
        fi
    fi

    echo "Running seeds <-------"
    python /opt/rbac/rbac/manage.py seeds
else
    echo "Migrations should not be run <----"
    # Other deployments may assign migrations to a separate service. Do not
    # start this process until that service has applied the full schema.
    python /opt/rbac/rbac/manage.py wait_for_db

    MAX_WAIT=600
    WAIT_INTERVAL=5
    ELAPSED=0
    echo "Waiting for schema migrations to finish..."
    until python /opt/rbac/rbac/manage.py migrate --check --noinput --verbosity 0 >/dev/null 2>&1; do
        if [[ ${ELAPSED} -ge ${MAX_WAIT} ]]; then
            echo "ERROR: database migrations are still pending after ${MAX_WAIT}s."
            exit 1
        fi
        sleep "${WAIT_INTERVAL}"
        ELAPSED=$((ELAPSED + WAIT_INTERVAL))
    done
    echo "Database schema is up to date."
fi
