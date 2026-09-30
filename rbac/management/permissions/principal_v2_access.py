#
# Copyright 2026 Red Hat, Inc.
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

"""Principal V2 access permissions."""

import logging

from management.permissions.utils import KESSEL_PRINCIPAL_READ_RELATION, check_v2_kessel_access
from rest_framework import permissions

from rbac.env import ENVIRONMENT

logger = logging.getLogger(__name__)


class PrincipalV2AccessPermission(permissions.BasePermission):
    """Permission class for Principal V2 API access.

    Uses org-admin or principal:read from the V1 access dict, with a Kessel
    fallback for V2-migrated orgs (tenant-level rbac_principal_read).
    """

    def has_permission(self, request, view):
        """Check if the user has permission to access Principal V2 APIs."""
        if ENVIRONMENT.get_value("ALLOW_ANY", default=False, cast=bool):
            return True
        if request.user.admin:
            return True
        if request.method in permissions.SAFE_METHODS:
            principal_read = request.user.access.get("principal", {}).get("read", [])
            if principal_read:
                return True
            if check_v2_kessel_access(request, relation=KESSEL_PRINCIPAL_READ_RELATION):
                return True

        # Authorization failure - SEC-MON-REQ-1 compliance (EOI-8 authorization_failure)
        logger.warning(
            "Authorization denied",
            extra={
                "action": request.method,
                "resource_type": "principal_v2",
                "outcome": "failure",
                "org_id": getattr(request.user, "org_id", None),
                "username": getattr(request.user, "username", None),
                "reason": "insufficient_permissions",
                "endpoint": request.path,
            },
        )
        return False
