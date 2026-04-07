#
# Copyright 2025 Red Hat, Inc.
#
# This program is free software: you can redistribute it and/or modify
# it under the terms of the GNU Affero General Public License as
# published by the Free Software Foundation, either version 3 of the
# License, or (at your option) any later version.
#
# This program is distributed in the hope that it will be useful,
# but WITHOUT ANY WARRANTY; without even the implied warranty of
# MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the
# GNU Affero General Public License for more details.
#
# You should have received a copy of the GNU Affero General Public License
# along with this program.  If not, see <https://www.gnu.org/licenses/>.
#

"""Permission ceiling check for role binding operations.

Implements the "you can only grant what you have" principle: a granter
must themselves possess every permission contained in the role they are
binding to a subject.  This is an API-layer complementary check that
runs alongside (not instead of) the existing SpiceDB relation checks.

Architecture
------------
The ceiling check is designed as a *composable DRF permission class*
(``RoleBindingCeilingPermission``) that can be appended to the existing
permission_classes tuple on ``RoleBindingViewSet``.  It runs after
``RoleBindingKesselAccessPermission`` has already verified that the
granter has the ``role_binding_grant`` relation on the target workspace.

The check works by:

1. Extracting the role UUIDs from the request body (batch_create or
   PUT by_subject).
2. Loading the Permission objects attached to those roles.
3. For each permission, calling ``CheckForUpdate`` on the Kessel
   Inventory API to verify the granter themselves has that permission
   on the target resource.

If *any* permission in the target role is not held by the granter,
the request is denied.

Performance
-----------
Each permission requires one gRPC ``CheckForUpdate`` call.  For a
typical role with 3-5 permissions this adds 3-5 sequential calls
(~5-15 ms each on a co-located network).

Potential optimisations:
- **Batch the checks** via asyncio/threading (cut wall-clock from
  N * latency to ~1 * latency).
- **Cache the granter's permissions** for the duration of the request
  using ``LookupResources`` once (1 call instead of N).
- **Short-circuit** on org-admin (they implicitly hold all
  permissions).
"""

import logging

from management.permissions.workspace_inventory_access import (
    WorkspaceInventoryAccessChecker,
)
from management.principal.proxy import get_kessel_principal_id
from management.role.v2_model import RoleV2
from rest_framework import permissions

logger = logging.getLogger(__name__)


class RoleBindingCeilingPermission(permissions.BasePermission):
    """Deny a grant when the granter does not hold every permission in the target role.

    This is a proof-of-concept implementation.  It only activates for
    write actions (batch_create, PUT by_subject) and passes through
    on reads.
    """

    def has_permission(self, request, view) -> bool:
        action = getattr(view, "action", None)

        # Only enforce ceiling on write paths
        if action == "batch_create":
            return self._check_batch_create_ceiling(request)
        elif action == "by_subject" and request.method == "PUT":
            return self._check_by_subject_ceiling(request)

        # Read actions: no ceiling needed
        return True

    # ── batch_create ────────────────────────────────────────────────

    def _check_batch_create_ceiling(self, request) -> bool:
        """Verify ceiling for every role in a batch create request."""
        data = getattr(request, "data", {})
        if not isinstance(data, dict):
            return False

        requests_data = data.get("requests")
        if not requests_data or not isinstance(requests_data, list):
            return False

        # Collect (role_uuid, resource_type, resource_id) triples
        checks: list[tuple[str, str, str]] = []
        for item in requests_data:
            if not isinstance(item, dict):
                return False
            role_info = item.get("role", {})
            resource_info = item.get("resource", {})
            role_id = str(role_info.get("id") or "").replace("\x00", "")
            resource_type = str(resource_info.get("type") or "").replace("\x00", "").lower()
            resource_id = str(resource_info.get("id") or "").replace("\x00", "")
            if not role_id or not resource_type or not resource_id:
                return False
            checks.append((role_id, resource_type, resource_id))

        return self._enforce_ceiling(request, checks)

    # ── PUT by_subject ──────────────────────────────────────────────

    def _check_by_subject_ceiling(self, request) -> bool:
        """Verify ceiling for every role in a PUT by-subject request."""
        resource_type = request.query_params.get("resource_type", "").replace("\x00", "").lower()
        resource_id = request.query_params.get("resource_id", "").replace("\x00", "")
        if not resource_type or not resource_id:
            return False

        roles_data = request.data.get("roles", [])
        if not isinstance(roles_data, list):
            return False

        checks = []
        for role_entry in roles_data:
            role_id = str(role_entry.get("id") or "").replace("\x00", "")
            if role_id:
                checks.append((role_id, resource_type, resource_id))

        if not checks:
            # Removing all roles (empty list) is always allowed
            return True

        return self._enforce_ceiling(request, checks)

    # ── Core ceiling logic ──────────────────────────────────────────

    def _enforce_ceiling(
        self,
        request,
        checks: list[tuple[str, str, str]],
    ) -> bool:
        """For each (role_uuid, resource_type, resource_id), verify the
        granter holds every permission in that role on that resource.

        Org-admins bypass the ceiling check (they implicitly have all
        permissions).
        """
        # Short-circuit: org-admins can grant anything
        if getattr(request.user, "admin", False):
            logger.debug("Ceiling check: org-admin bypass")
            return True

        principal_id = get_kessel_principal_id(request)
        if not principal_id:
            logger.debug("Ceiling check: could not resolve principal_id")
            return False

        # Deduplicate role UUIDs to avoid loading the same role twice
        role_uuids = list({c[0] for c in checks})
        roles = {str(r.uuid): r for r in RoleV2.objects.filter(uuid__in=role_uuids).prefetch_related("permissions")}

        # Build a set of (permission_v2_string, resource_type, resource_id)
        # that the granter must hold
        required: set[tuple[str, str, str]] = set()
        for role_uuid, resource_type, resource_id in checks:
            role = roles.get(role_uuid)
            if role is None:
                # Unknown role -- let the downstream serializer handle the error
                continue
            for perm in role.permissions.all():
                required.add((perm.v2_string(), resource_type, resource_id))

        if not required:
            return True

        checker = WorkspaceInventoryAccessChecker()
        denied_permissions: list[str] = []

        for perm_string, resource_type, resource_id in required:
            # Each permission in a V2 role corresponds to a relation in
            # SpiceDB (e.g. "inventory:hosts:read").  We check whether the
            # granter's principal has that relation on the target resource.
            #
            # NOTE: This is the expensive part -- one gRPC call per
            # unique (permission, resource) pair.
            has_perm = checker.check_resource_access(
                resource_type=resource_type,
                resource_id=resource_id,
                principal_id=principal_id,
                relation=perm_string,
            )
            if not has_perm:
                denied_permissions.append(f"{perm_string} on {resource_type}/{resource_id}")
                # Fail fast on first denial
                logger.info(
                    "Ceiling check DENIED: principal=%s lacks %s on %s/%s",
                    principal_id,
                    perm_string,
                    resource_type,
                    resource_id,
                )
                return False

        logger.debug(
            "Ceiling check PASSED: principal=%s holds all %d required permissions",
            principal_id,
            len(required),
        )
        return True
