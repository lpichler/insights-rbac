# V2 Org Determination at the `/access` Endpoint

## Overview

The determination of whether an organization has been migrated to V2 (and thus whether it is subject to V2 access control restrictions) uses a **two-layer check** that examines both the application being queried and two independent signals from the database and feature flags.

This document explains how the `/api/v1/access/` endpoint identifies v2 orgs and enforces access restrictions accordingly.

## The Two Independent Signals

There are two separate signals that can mark an org as "v2-enabled":

### 1. Database Flag: `TenantMapping.v2_write_activated_at`

**Source:** PostgreSQL `management_tenantmapping` table

**What it means:** The org has **actually performed a write via V2 APIs** (roles, role bindings, etc.). Once set, this is **irreversible** and persists even if the Unleash feature flag is later disabled.

**Code reference:** `rbac/management/tenant_mapping/v2_activation.py:89`
```python
def is_v2_write_activated(tenant: Tenant):
    """Check if the tenant has been activated for V2 writes (without locking)."""
    mapping = TenantMapping.objects.get(tenant=tenant)
    return mapping.v2_write_activated_at is not None
```

### 2. Unleash Feature Flags

**Source:** Unleash feature flag service, evaluated per `orgId` context

Two related flags:
- **`platform.rbac.workspaces`** — General V2 write API enablement
- **`hbi.rbac-v2`** — Strict V2 access checks for HBI application specifically

**What they mean:** Orgs are **opted into v2** via feature flag — this is **reversible** until a V2 write actually occurs.

**Code reference:** `rbac/feature_flags.py:208, 300`
```python
def is_v2_edit_api_enabled(self, org_id: str) -> bool:
    """Check whether v2 write APIs are enabled for the given org."""
    return self.is_enabled(
        feature_name=self.TOGGLE_V2_EDIT_API_ENABLED,  # "platform.rbac.workspaces"
        context={"orgId": str(org_id)},
    )

def is_v2_strict_access_check_enabled(self, org_id: str) -> bool:
    """Check whether strict V2 access checks are required in the given org."""
    return self.is_enabled(
        feature_name=self.TOGGLE_V2_ADDITIONAL_MANDATORY_ACCESS_CHECK_REQUIRED,  # "hbi.rbac-v2"
        context={"orgId": str(org_id)},
    )
```

## The Two-Layer Check: `is_v2_access_check_required_for_request`

At the `/access` endpoint, the determination happens in `rbac/management/permissions/v2_edit_api_access.py:40`:

```python
def is_v2_access_check_required_for_request(request, requested_apps: Iterable[str]) -> bool:
    """Check if V2 access check is required for the provided request."""
    requested_apps = set(requested_apps)

    # Layer 1: Check if ANY requested app is in the strict access check list
    if not requested_apps.isdisjoint(settings.V2_STRICT_ACCESS_CHECK_FLAG_APPLICATION_NAMES):
        return is_v2_write_activated(request.tenant) or FEATURE_FLAGS.is_v2_strict_access_check_enabled(
            request.user.org_id
        )

    # Layer 2: All other apps check the general V2 write flag
    return is_v2_edit_enabled_for_request(request)
```

### Layer 1: Strict-Access-Check Applications (e.g., HBI)

If **any** of the requested applications are in `V2_STRICT_ACCESS_CHECK_FLAG_APPLICATION_NAMES`:

**Org is v2-enabled if:**
```
TenantMapping.v2_write_activated_at IS NOT NULL
OR
Unleash flag "hbi.rbac-v2" is enabled for orgId
```

Applications in this list have stricter requirements and opt into V2 access checks independently of general V2 write enablement.

### Layer 2: All Other Applications

For applications not in the strict list:

**Org is v2-enabled if:**
```
TenantMapping.v2_write_activated_at IS NOT NULL
OR
Unleash flag "platform.rbac.workspaces" is enabled for orgId
```

This covers the standard V2 write API enablement path.

## Effect on the `/access` Endpoint

When `is_v2_access_check_required_for_request` returns true, the `/access` endpoint calls `validate_v2_application_param` to enforce restrictions.

**Reference:** `rbac/management/access/view.py:201`

### Validation Rules

1. **Required:** The `application=` query parameter must be specified (no empty application list)
   - Returns: HTTP 400 `"V2 orgs must specify an application from the allowed list."`

2. **Allowlist:** All requested applications must be in the V2 migration exclude list
   - The exclude list is retrieved via `v2_role_excluded_applications()`
   - Returns: HTTP 400 with disallowed applications listed if any fail

### Metrics and Logging

When a V2-enabled org's `/access` call is rejected:

```python
v1_access_by_v2_org_total.labels(
    org_id=request.user.org_id,
    application=app_param,
    caller_type="service_account" | "user",
).inc()
```

And a structured log is written with full context: `org_id`, `application`, `caller_type`, `user_id`, `client_id`, `is_org_admin`, `request_id`, `user_agent`.

## Transition States

### V1 Org → V2 Org (One-way door)

1. **Opt-in phase:** `platform.rbac.workspaces` flag enabled in Unleash
   - `/access` endpoint enforces V2 restrictions (cannot query non-excluded apps)
   - V2 write APIs are available
   - V1 write APIs are blocked (via `V1WriteBlockedWhenWorkspacesEnabled` permission)

2. **Activation phase:** Org performs first V2 write
   - `TenantMapping.v2_write_activated_at` is set (irreversible)
   - Even if Unleash flag is later disabled, the org remains v2

### Unlock Scenario

If Unleash flag is disabled but `v2_write_activated_at` is set:
- `/access` endpoint still enforces V2 restrictions (DB flag takes precedence)
- This prevents orgs from getting "stuck" in a state where both V1 and V2 are blocked

## Key Invariants

1. **DB flag trumps feature flag:** Once `v2_write_activated_at` is set, it cannot be unset. The org is permanently v2.
2. **Feature flag is reversible:** Unleash flags can be toggled on/off without affecting orgs that have already written via V2.
3. **Strict access checks are per-app:** The `hbi.rbac-v2` flag only affects HBI access checks; other apps follow the general `platform.rbac.workspaces` flag.
4. **Migration exclude list is gating:** V2-enabled orgs can only query `/access` for applications in the exclude list (apps not yet migrated to V2).

## Configuration References

### Settings

- `V2_STRICT_ACCESS_CHECK_FLAG_APPLICATION_NAMES` — List of apps requiring strict V2 access checks
- `V2_MIGRATION_APP_EXCLUDE_LIST` — Applications allowed for V2-enabled orgs to query via `/access`
- `V2_EDIT_API_ENABLED` — Environment variable fallback for `platform.rbac.workspaces` flag

### Unleash Flags

| Flag Name | Context | Default | Purpose |
|-----------|---------|---------|---------|
| `platform.rbac.workspaces` | `orgId` | False | Enable V2 write APIs and enforce V2 access checks for this org |
| `hbi.rbac-v2` | `orgId` | False | Enforce strict V2 access checks for HBI application in this org |

## Implementation Files

- **Permission/feature check:** `rbac/management/permissions/v2_edit_api_access.py`
- **V2 write activation/locking:** `rbac/management/tenant_mapping/v2_activation.py`
- **Feature flags:** `rbac/feature_flags.py`
- **/access endpoint:** `rbac/management/access/view.py`
- **Permission classes (enforcement):** Various `view.py` files use `V1WriteBlockedWhenWorkspacesEnabled`, `V1ApiBlockedWhenWorkspacesEnabled`, `V2WriteRequiresWorkspacesEnabled`

## Debugging

To check if an org is v2-enabled:

```python
from management.tenant_mapping.v2_activation import is_v2_write_activated
from feature_flags import FEATURE_FLAGS

is_db_activated = is_v2_write_activated(tenant)
is_flag_enabled = FEATURE_FLAGS.is_v2_edit_api_enabled(org_id)
is_v2 = is_db_activated or is_flag_enabled
```

To check metrics:

```bash
# V1 /access calls from v2-enabled orgs (rejected)
curl http://localhost:8000/metrics | grep rbac_v1_access_v2_org_total
```
