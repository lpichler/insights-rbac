# Local Docker/Podman validation

This guide runs the local RBAC API validations against the full Kessel stack.
The commands use Podman when it is available, but Docker is also supported.

## Start the stack

Select the source for each configurable service with `rbac=` and
`rbac-config=`:

| Source | Meaning |
| --- | --- |
| `local` | Current local checkout, including uncommitted changes |
| `upstream` | Latest changes from the hard-coded upstream repository |
| `<GitHub PR URL>` | Source fetched from the specified pull request |
| `<commit SHA>` | Source fetched at the specified commit |

HBI and Kessel Inventory always use upstream sources for now. Their checkouts
are maintained under `.local-deps/` and updated for each deployment. The
hard-coded upstream repositories are
[insights-rbac](https://github.com/project-kessel/insights-rbac),
[rbac-config](https://github.com/project-kessel/rbac-config),
[inventory-api](https://github.com/project-kessel/inventory-api), and
[insights-host-inventory](https://github.com/RedHatInsights/insights-host-inventory).

| Scenario | Command |
| --- | --- |
| Local RBAC with upstream config | `make docker-local-full-up rbac=local rbac-config=upstream` |
| Local RBAC and local config | `make docker-local-full-up rbac=local rbac-config=local` |
| Latest upstream RBAC and config | `make docker-local-full-up rbac=upstream rbac-config=upstream` |
| RBAC and config commits | `make docker-local-full-up rbac=<rbac-commit-sha> rbac-config=<config-commit-sha>` |
| RBAC PR | `make docker-local-full-up rbac=<rbac-pr-url>` |
| Config PR | `make docker-local-full-up rbac=local rbac-config=<config-pr-url>` |
| RBAC PR and config PR | `make docker-local-full-up rbac=<rbac-pr-url> rbac-config=<config-pr-url>` |

For `rbac-config=local`, the sibling checkout at `../rbac-config` is used. The
command compiles its stage schema with `ksl-test-schema-stage` before starting
the stack.

### Running stack behavior

When the stack is already running, the command rebuilds and recreates the
services affected by the selected sources and prints a deployment summary. A
local RBAC and local config deployment rebuilds RBAC, refreshes the selected
schema and role definitions, and rebuilds the upstream Kessel and HBI services.

Wait until the RBAC API is available at `http://localhost:9080`.

## Run all validations

```bash
make docker-local-full-validate
```

The Make target discovers every `*.sh` file below `scripts/validations/` and
runs them in lexical order. The current local checks include:

- workspace creation and read-your-writes pipeline validation;
- V2 workspace, role, principal, and role-binding CRUD validation, including
  persisted Kessel relations and relation cleanup;
- read-only inspection of all RBAC organizations and their persisted users.

### Identity used by each validation

The scripts print the runtime identity they use. This is the complete local
mapping:

| Script/action | API/version | Organization and account | User | Persistence |
| --- | --- | --- | --- | --- |
| `api/v2-crud.sh` | V2 | `org_id=11111`, `account_id=10001` | Unique temporary `v2-crud-user-<timestamp>-<pid>`, `admin: true` | Created from a temporary YAML fixture and deleted on exit |
| `api/create-workspace-local.sh` | V2 | `org_id=11111`, `account_id=10001` by default | `user_dev`, user ID `51736777` by default | Uses the existing local seeded tenant/principal; override with `RYW_ORG_ID`, `RYW_ACCOUNT_ID`, `RYW_USERNAME`, and `RYW_USER_ID` |
| `api/actions/apply-rbac-users-config.sh` | V2 fixture loader | Values come from `actions/rbac-users.yaml` or `--file` | Values come from each YAML `users` entry | Persists users, groups, roles, and bindings until changed/deleted |
| `api/actions/list-rbac-users.sh` | No API mutation | Reads every tenant in the running RBAC database | Lists persisted principals; `generate-user` defaults to org `11111`, account `10001`, and a generated user ID | `list` is read-only; `generate-user` creates only a header |

`v2-crud.sh` is self-contained: it does not use `user_dev` or any pre-existing
user. Its temporary YAML fixture creates the principal, a temporary V2 access
role, and a tenant-level binding. The script sends that user in
`X-RH-Identity`, runs the V2 CRUD scenarios, removes API/Kessel test data, and
deletes the fixture user. `admin: true` is metadata; the V2 role binding is
what grants the write permissions.

`create-workspace-local.sh` exercises only V2 workspace creation and the
read-your-writes pipeline. It uses the existing local seeded V2 identity by
default and does not use the V1 API. If you override the identity, the tenant
and principal must already exist in the RBAC database.

## Run individual checks

Run the V2 API lifecycle check:

```bash
scripts/validations/api/v2-crud.sh
```

Run workspace creation and read-your-writes directly when the stack is already
running:

```bash
scripts/validations/api/create-workspace-local.sh --no-start
```

This check validates the V2 workspace RYW path. The full stack still starts
HBI and its Inventory API, but the current `test_ryw.py` helper does not assert
HBI replication; `--check-hbi` is therefore informational and prints a warning
instead of passing unsupported arguments to the helper.

List organizations and users/principals from the running RBAC container:

```bash
scripts/validations/api/actions/list-rbac-users.sh
```

The users action is read-only. It uses the container's Django ORM and prints
each organization, account, principal count, username, user ID, principal
type, and UUID. It also lists every V2 role with its permissions and every
role binding with its role, resource, and user/group subjects.

Generate an identity header for a new local test user without changing the
database:

```bash
scripts/validations/api/actions/list-rbac-users.sh generate-user --admin --v2
scripts/validations/api/actions/list-rbac-users.sh generate-user --non-admin --v1
```

The command prints the identity JSON, its base64 `X-RH-Identity` value, and a
ready-to-run `curl` example. Use `--org-id`, `--account-number`, `--username`,
or `--user-id` to override the generated values. This command is deliberately
header-only: it does not create a database user, bootstrap a tenant, or grant
Kessel permissions. The `--admin` flag only changes the identity header's
`is_org_admin` value.

To create real local users and bootstrap their tenant, use the declarative
fixture action:

```bash
scripts/validations/api/actions/apply-rbac-users-config.sh
scripts/validations/api/actions/apply-rbac-users-config.sh --dry-run
scripts/validations/api/actions/apply-rbac-users-config.sh \
  --file /absolute/path/to/rbac-users.yaml
```

For a validation-only fixture, mark the tenant `temporary: true`. The action
can then remove the declared custom roles and users through the normal RBAC
disable path:

```bash
scripts/validations/api/actions/apply-rbac-users-config.sh \
  --file /absolute/path/to/temporary-users.yaml --delete
```

Deletion is refused unless every tenant in the YAML is explicitly marked
temporary, so a normal persistent fixture cannot be removed accidentally.

The example fixture is
[`scripts/validations/api/actions/rbac-users.yaml`](../scripts/validations/api/actions/rbac-users.yaml).
It supports, per tenant:

- `bootstrap: true` to create the tenant and its default workspaces;
- `users` with a username, external user ID, admin metadata, and group membership;
- `groups` with members and group-level role bindings;
- V2 custom `roles` with application/resource/operation permissions; and
- role bindings for users or groups at the user, group, or tenant level.

Applying the same fixture again is safe for the same tenant, user IDs, role
names, and binding subjects. User creation goes through the normal RBAC
bootstrap service, so the persisted principals and their outbox/Kessel
relations are visible to the running API. Authorization still comes from role
bindings; `admin: true` is identity metadata and is not a substitute for a
binding.

To inspect the schema currently loaded in local SpiceDB:

```bash
./scripts/zed_local.sh schema
```

## Output and colors

The users action colors interactive terminal output automatically. Override it
when needed:

```bash
COLOR=always scripts/validations/api/actions/list-rbac-users.sh
COLOR=never scripts/validations/api/actions/list-rbac-users.sh
NO_COLOR=1 scripts/validations/api/actions/list-rbac-users.sh
```

## Stop the stack

```bash
make docker-local-full-down
```

This stops the local full stack and keeps its volumes.
