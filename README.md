# insights-rbac

Role-Based Access Control (RBAC) service for [console.redhat.com](https://console.redhat.com). Manages roles, permissions, groups, and workspaces that control user access across the Hybrid Cloud Console platform.

## Overview

insights-rbac is a Django REST Framework microservice that provides two API versions:

- **V1 API** -- stable, widely consumed REST API for managing roles, groups, policies, and permissions
- **V2 API** -- next-generation API with workspace-based access control, RFC 7807 error responses, and Kessel integration for authorization

The service is multi-tenant: every request is scoped to an organization (tenant) via identity headers injected by the platform's authentication gateway.

## Tech Stack

- **Language**: Python 3.12
- **Framework**: Django 5.2 / Django REST Framework
- **Database**: PostgreSQL 16
- **Cache**: Redis
- **Task Queue**: Celery (Redis broker)
- **Authorization**: Kessel Relations (SpiceDB-based, gRPC)
- **Messaging**: Kafka (Debezium CDC outbox pattern)
- **Metrics**: Prometheus

## Quick Start

### Prerequisites

- Python 3.12
- [Pipenv](https://pipenv.pypa.io/)
- Docker / Podman (for PostgreSQL and Redis)

### Option 1: Docker Compose (full stack)

Starts the RBAC server, PostgreSQL, Redis, Celery worker, and Celery beat scheduler:

```bash
make docker-up       # App available at http://localhost:9080
make docker-logs     # Tail all container logs
make docker-down     # Stop and remove containers
```

### Option 2: Local Python (app only)

Run the Django server locally, using Docker only for PostgreSQL:

```bash
pipenv install --dev     # Install dependencies
make start-db            # Start Postgres on port 15432
make run-migrations      # Apply database migrations
make serve               # App available at http://localhost:8000
```

### Option 3: Full Kessel and Host Inventory integration stack

Start RBAC with Kessel Inventory, Kessel Relations, SpiceDB, Kafka, Debezium,
and Host Inventory:

```bash
make docker-local-full-up
```

The command builds `insights-rbac-local:dev`, uses Docker or Podman Compose,
and discovers sibling `../inventory-api` and `../insights-host-inventory`
checkouts. If either checkout is absent, it creates a shallow clone under
`.local-deps/`. Ensure the container VM has enough memory for the full stack.

#### Local full-stack quick start

The full-stack command uses the checked-out RBAC source and discovered
`inventory-api` and `insights-host-inventory` sources. It discovers sibling
checkouts first and otherwise uses clones under `.local-deps/`. It intentionally
does not pull existing checkouts, so local work is never overwritten.

##### Latest version of all repositories

With each repository already on the branch you want to test, fast-forward all
three checkouts, then build and deploy the current RBAC checkout:

```bash
make docker-local-full-up-latest
```

The command resolves sibling repositories or the automatically cloned
`.local-deps/` copies, fast-forwards them sequentially, initializes HBI
submodules, and then starts the stack. Processing stops at the first
fast-forward failure (for example because a checkout has local commits or
conflicts), but repositories updated earlier in the sequence will already
have been fast-forwarded.

##### Current local RBAC changes

Build and deploy the current RBAC checkout, including uncommitted changes:

```bash
make docker-local-full-up local
```

##### Rebuild running RBAC services

When the full stack is already running, rebuild only the RBAC services without
tearing down the entire stack:

```bash
make docker-local-full-up local rebuild=rbac
```

This rebuilds the local RBAC Docker image, runs migrations, and recreates the
RBAC server, worker, scheduler, and Kafka consumer. Other services remain
untouched.

To also rebuild a local `rbac-config` checkout (compile KSL schema, refresh
SpiceDB and Relations API, reseed role definitions):

```bash
make docker-local-full-up local rebuild=rbac,rbac-config \
  rbac_config_repo="$(cd ../rbac-config && pwd)"
```

##### An RBAC pull request

To test a pull request without checking out its branch, pass its complete
GitHub PR URL as the `pr` make variable:

```bash
make docker-local-full-up pr=https://github.com/project-kessel/insights-rbac/pull/3309
```

The PR command fetches the PR head into a temporary Git worktree, builds an
`insights-rbac-pr-<number>:dev` image, and starts the integrated stack with
that image. A normal build forces recreation of the full-Kessel Compose
services, so the server, migrations, worker, scheduler, and Kafka consumer
all use the new code. The temporary worktree is removed after startup; the
locally built image and Compose volumes remain available for testing.

##### An RBAC Config pull request, local checkout, or generated KSL schema

The full stack uses the **stage** configuration by default: the stage role
ConfigMap and the stage `schema.zed` from `project-kessel/rbac-config`.
To test an RBAC Config PR with an RBAC PR (or with local RBAC code), pass its
complete URL using `rbac_config_pr`:

```bash
make docker-local-full-up \
  pr=https://github.com/project-kessel/insights-rbac/pull/3309 \
  rbac_config_pr=https://github.com/project-kessel/rbac-config/pull/123
```

That selects the PR's stage `_private/configmaps/stage/rbac-config.yml` and
its generated `configs/stage/schemas/schema.zed`. The files are copied or
downloaded into Inventory API's local full-Kessel configuration before the
Relations API starts.

To test changes in a local `rbac-config` checkout instead, use
`rbac_config_repo`. It uses the checkout's stage ConfigMap and automatically
runs its non-destructive `ksl-test-schema-stage` target, then loads the
generated stage schema:

```bash
make docker-local-full-up local rbac_config_repo="$(cd ../rbac-config && pwd)"
```

When the local full stack is already running, this command does **not** rebuild
the local RBAC image or Host Inventory and does not recreate the full stack.
It refreshes only Relations API (to load the schema), runs `rbac-migrate` (to
reseed the role definitions), and restarts `rbac-server`, `rbac-worker`,
`rbac-scheduler`, and `rbac-kafka-consumer`. On a first launch,
it performs the normal full build and startup because the local image and
dependencies do not exist yet.

During a refresh, the selected schema is also written directly to SpiceDB
before those services restart, so KSL changes take effect immediately.

By default, this is enough for uncommitted KSL changes. To use a separately
generated schema file instead, provide `schema_zed_file`:

```bash
make docker-local-full-up local \
  rbac_config_repo="$(cd ../rbac-config && pwd)" \
  schema_zed_file="$(cd ../rbac-config && pwd)/_private/test-schema/stage-schema.zed"
```

`schema_zed_file` takes precedence only for the SpiceDB schema; the role
definitions still come from the selected RBAC Config PR or checkout. The
automatic local build uses the safe `ksl-test-schema-stage` target, which writes
under `_private/` rather than replacing the committed `schema.zed`.

##### Run the basic V2 API validation

After the stack is healthy, run the basic V2 API lifecycle validation:

```bash
scripts/validations/api/v2-crud.sh
```

The validator requires no identity setup. It exercises every V2 API route:
workspace CRUD/query/move, role CRUD, role-binding create/read/update, and the
read-only principal routes. It temporarily enables V2 writes and adds the
minimum local Kessel authorization tuples, then removes its test resources and
restores the original V2-write setting and Kessel graph. It prints the direct
Kessel tuples for read-only scenarios and verifies the expected persisted tuple
after every write; deletion checks verify that the tuple disappears.

The validator creates a temporary user from an in-memory YAML fixture in
`org_id=11111` with a unique `v2-crud-user-<timestamp>-<pid>` identity. It
deletes that user, its temporary role, and its binding during cleanup. The
workspace RYW validation uses the existing local seeded V2 identity by
default: `org_id=11111`, account `10001`, `user_dev`, user ID `51736777`.
The identity can be overridden with `RYW_ORG_ID`, `RYW_ACCOUNT_ID`,
`RYW_USERNAME`, and `RYW_USER_ID`; the full mapping is listed in the
[local Docker/Podman validation guide](docs/local-docker-validation.md).
The full stack includes HBI, but the current RYW helper validates the RBAC
workspace path only; `--check-hbi` is informational until an HBI assertion is
implemented.

To inspect the organizations, persisted users/principals, V2 roles, and role
bindings in the running RBAC container, run the read-only action:

```bash
scripts/validations/api/actions/list-rbac-users.sh
```

The same action can generate a local admin or non-admin identity for V1 or V2
API testing; see the [local Docker/Podman validation guide](docs/local-docker-validation.md).

To create persisted local users, bootstrap a tenant, and configure groups,
V2 roles, and role bindings, apply the declarative fixture described in the
[local Docker/Podman validation guide](docs/local-docker-validation.md):

```bash
scripts/validations/api/actions/apply-rbac-users-config.sh
```

##### Run every local validation

Run every shell validation below `scripts/validations/` in lexical order. The
command stops at the first failure:

```bash
make docker-local-full-validate
```

See [Local Validation Script Guidelines](docs/validation-script-guidelines.md)
when adding a validation for a new feature.

For the complete local Docker/Podman startup and validation workflow, see the
[Local Docker/Podman validation guide](docs/local-docker-validation.md).

Useful endpoints after startup:

| Service | Endpoint |
| --- | --- |
| RBAC API and metrics | http://localhost:9080 and http://localhost:9080/metrics |
| Kessel Relations API | http://localhost:9000 |
| Kessel Inventory API | http://localhost:9081 |
| Kafka Connect | http://localhost:8083 |
| Host Inventory API | http://localhost:8080 |

For an existing image, skip the RBAC build:

```bash
RBAC_IMAGE=<existing-image-tag> ./scripts/local_stack/up-full.sh --no-build
```

To start only Kessel, Debezium, and RBAC, omit Host Inventory:

```bash
./scripts/local_stack/up-full.sh --no-hbi
```

Verify a workspace create, the RBAC Read-Your-Writes notification, and that
the workspace is visible through Kessel Inventory, which Host Inventory uses
as its workspace source of truth:

```bash
./scripts/validations/api/create-workspace-local.sh --no-start --check-hbi
```

Stop the full stack with `make docker-local-full-down`. This preserves volumes;
pass `--volumes` to `scripts/local_stack/down-full.sh` when a clean HBI data
volume is required. If the RBAC Kafka consumer is unhealthy, restart the stack
with `make docker-local-full-up`; the consumer should report that it acquired a
fencing lock and is listening on `outbox.event.relations-replication-event`.

## Testing

Tests require a running PostgreSQL instance (SQLite is not supported):

```bash
make start-db                                      # Ensure Postgres is running

# Full test suite with coverage
pipenv run tox -e py312

# Fast test suite (no coverage)
pipenv run tox -e py312-fast

# Single test module (dotted path, not file path)
pipenv run tox -e py312-fast -- tests.management.role.test_view
```

See [docs/testing-guidelines.md](docs/testing-guidelines.md) for base classes, v2 test setup, and mocking patterns.

## Linting and Formatting

```bash
pipenv run tox -e lint                          # flake8 + black --check
pipenv run black -t py312 -l 119 rbac tests     # Auto-format
pipenv run pre-commit run --all-files            # Run all pre-commit hooks
```

## Database

```bash
make make-migrations     # Generate migration files
make run-migrations      # Apply migrations
make reinitdb            # Drop, recreate, and migrate
```

Direct access: `psql postgres -U postgres -h localhost -p 15432`

## API Documentation

- V1 API specs: [docs/source/specs/](docs/source/specs/)
- V2 OpenAPI spec: [docs/source/specs/v2/openapi.yaml](docs/source/specs/v2/openapi.yaml)
- V2 TypeSpec source: [docs/source/specs/typespec/main.tsp](docs/source/specs/typespec/main.tsp)
- MCP endpoint (AI agent interface): [docs/MCP.md](docs/MCP.md)

Regenerate the v2 spec from TypeSpec:

```bash
make generate_v2_spec
```

## Environment Variables

Key environment variables (see [docker-compose.yml](docker-compose.yml) for a full reference):

| Variable | Description | Default |
|----------|-------------|---------|
| `DATABASE_HOST` | PostgreSQL host | `localhost` |
| `DATABASE_PORT` | PostgreSQL port | `15432` |
| `DATABASE_NAME` | Database name | `postgres` |
| `REDIS_HOST` | Redis host | `rbac_redis` |
| `API_PATH_PREFIX` | API URL prefix | `/api/rbac` |
| `V2_APIS_ENABLED` | Enable v2 API routes | `False` |
| `KAFKA_ENABLED` | Enable Kafka producer/consumer | `False` |
| `DEVELOPMENT` | Development mode flag | `False` |
| `MCP_ENABLED` | Enable MCP endpoint (`/_private/_a2s/mcp/`) | `True` |
| `MCP_WRITE_ENABLED` | Enable MCP write operations | `False` |

## Project Structure

```
rbac/
  api/            # V1 API views, serializers, URLs
  management/     # Core business logic (models, services, views per domain)
  internal/       # Internal/service-to-service API
  core/           # Shared utilities, middleware, error handling
  rbac/           # Django project settings, WSGI, Celery config
  migration_tool/ # V1-to-V2 migration utilities
tests/            # Test suite (mirrors rbac/ structure)
docs/             # Architecture and domain guideline docs
```

## Further Reading

- [CONTRIBUTING.md](CONTRIBUTING.md) -- How to contribute
- [AGENTS.md](AGENTS.md) -- AI agent guidance and codebase conventions
- [docs/ARCHITECTURE.md](docs/ARCHITECTURE.md) -- System architecture and data flow
- [docs/security-guidelines.md](docs/security-guidelines.md) -- Authentication and authorization
- [docs/api-contracts-guidelines.md](docs/api-contracts-guidelines.md) -- API versioning and contracts
- [docs/database-guidelines.md](docs/database-guidelines.md) -- Multi-tenancy, models, migrations
- [docs/integration-guidelines.md](docs/integration-guidelines.md) -- Kessel, Kafka, external services
- [docs/performance-guidelines.md](docs/performance-guidelines.md) -- Caching, query optimization
- [docs/error-handling-guidelines.md](docs/error-handling-guidelines.md) -- Error formats and exceptions
- [docs/testing-guidelines.md](docs/testing-guidelines.md) -- Test runner, base classes, patterns
- [docs/MCP.md](docs/MCP.md) -- MCP endpoint developer guide (protocol, tools, adding tools)
- [docs/MCP-operator-guide.md](docs/MCP-operator-guide.md) -- MCP endpoint operator guide (deployment, config, security)

## License

This project is licensed under the GNU AGPL v3. See [LICENSE](LICENSE) for details.
