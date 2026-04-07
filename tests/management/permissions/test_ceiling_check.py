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

"""Tests for the permission ceiling check (RoleBindingCeilingPermission).

These are unit tests that mock the Kessel Inventory API to verify the
ceiling logic without requiring a running SpiceDB instance.
"""

from unittest.mock import MagicMock, Mock, patch
from uuid import uuid4

from django.test import TestCase

from management.models import Permission
from management.permissions.ceiling_check import RoleBindingCeilingPermission
from management.role.v2_model import RoleV2


class TestRoleBindingCeilingPermission(TestCase):
    """Test RoleBindingCeilingPermission logic."""

    def setUp(self):
        self.perm_class = RoleBindingCeilingPermission()

    def _make_request(self, method="POST", data=None, query_params=None, is_admin=False):
        request = MagicMock()
        request.method = method
        request.data = data or {}
        request.query_params = query_params or {}
        request.user = MagicMock()
        request.user.admin = is_admin
        request.user.system = False
        return request

    def _make_view(self, action):
        view = MagicMock()
        view.action = action
        return view

    # ── Read actions pass through ──────────────────────────────────

    def test_list_action_passes_through(self):
        request = self._make_request()
        view = self._make_view("list")
        assert self.perm_class.has_permission(request, view) is True

    def test_by_subject_get_passes_through(self):
        request = self._make_request(method="GET")
        view = self._make_view("by_subject")
        assert self.perm_class.has_permission(request, view) is True

    # ── Org-admin bypass ───────────────────────────────────────────

    def test_org_admin_bypasses_ceiling_check(self):
        """Org-admins implicitly hold all permissions."""
        request = self._make_request(
            method="POST",
            data={
                "requests": [
                    {
                        "role": {"id": str(uuid4())},
                        "resource": {"type": "workspace", "id": str(uuid4())},
                        "subject": {"type": "group", "id": str(uuid4())},
                    }
                ]
            },
            is_admin=True,
        )
        view = self._make_view("batch_create")
        assert self.perm_class.has_permission(request, view) is True

    # ── batch_create ceiling checks ────────────────────────────────

    @patch("management.permissions.ceiling_check.get_kessel_principal_id")
    @patch("management.permissions.ceiling_check.WorkspaceInventoryAccessChecker")
    def test_batch_create_denied_when_granter_lacks_permission(self, mock_checker_cls, mock_get_principal):
        """Granter lacks a permission in the target role -> denied."""
        mock_get_principal.return_value = "localhost/user1"
        mock_checker = MagicMock()
        mock_checker.check_resource_access.return_value = False
        mock_checker_cls.return_value = mock_checker

        role_uuid = str(uuid4())
        resource_id = str(uuid4())

        # Create a mock role with permissions
        mock_role = MagicMock(spec=RoleV2)
        mock_role.uuid = role_uuid
        mock_perm = MagicMock(spec=Permission)
        mock_perm.v2_string.return_value = "inventory:hosts:read"
        mock_role.permissions.all.return_value = [mock_perm]

        with patch.object(
            RoleV2.objects, "filter", return_value=MagicMock(prefetch_related=MagicMock(return_value=[mock_role]))
        ):
            request = self._make_request(
                data={
                    "requests": [
                        {
                            "role": {"id": role_uuid},
                            "resource": {"type": "workspace", "id": resource_id},
                            "subject": {"type": "group", "id": str(uuid4())},
                        }
                    ]
                },
            )
            view = self._make_view("batch_create")
            result = self.perm_class.has_permission(request, view)

        assert result is False
        mock_checker.check_resource_access.assert_called_once_with(
            resource_type="workspace",
            resource_id=resource_id,
            principal_id="localhost/user1",
            relation="inventory:hosts:read",
        )

    @patch("management.permissions.ceiling_check.get_kessel_principal_id")
    @patch("management.permissions.ceiling_check.WorkspaceInventoryAccessChecker")
    def test_batch_create_allowed_when_granter_holds_all_permissions(self, mock_checker_cls, mock_get_principal):
        """Granter holds all permissions in the target role -> allowed."""
        mock_get_principal.return_value = "localhost/user1"
        mock_checker = MagicMock()
        mock_checker.check_resource_access.return_value = True
        mock_checker_cls.return_value = mock_checker

        role_uuid = str(uuid4())
        resource_id = str(uuid4())

        mock_role = MagicMock(spec=RoleV2)
        mock_role.uuid = role_uuid
        mock_perm1 = MagicMock(spec=Permission)
        mock_perm1.v2_string.return_value = "inventory:hosts:read"
        mock_perm2 = MagicMock(spec=Permission)
        mock_perm2.v2_string.return_value = "inventory:hosts:write"
        mock_role.permissions.all.return_value = [mock_perm1, mock_perm2]

        with patch.object(
            RoleV2.objects, "filter", return_value=MagicMock(prefetch_related=MagicMock(return_value=[mock_role]))
        ):
            request = self._make_request(
                data={
                    "requests": [
                        {
                            "role": {"id": role_uuid},
                            "resource": {"type": "workspace", "id": resource_id},
                            "subject": {"type": "group", "id": str(uuid4())},
                        }
                    ]
                },
            )
            view = self._make_view("batch_create")
            result = self.perm_class.has_permission(request, view)

        assert result is True
        assert mock_checker.check_resource_access.call_count == 2

    # ── PUT by_subject ceiling checks ──────────────────────────────

    def test_put_by_subject_empty_roles_allowed(self):
        """Removing all roles (empty list) should always be allowed."""
        request = self._make_request(
            method="PUT",
            data={"roles": []},
            query_params={
                "resource_type": "workspace",
                "resource_id": str(uuid4()),
                "subject_type": "group",
                "subject_id": str(uuid4()),
            },
        )
        view = self._make_view("by_subject")
        assert self.perm_class.has_permission(request, view) is True

    def test_put_by_subject_missing_resource_params_denied(self):
        """Missing resource params on PUT by_subject should deny."""
        request = self._make_request(
            method="PUT",
            data={"roles": [{"id": str(uuid4())}]},
            query_params={},
        )
        view = self._make_view("by_subject")
        assert self.perm_class.has_permission(request, view) is False

    # ── Malformed input handling ───────────────────────────────────

    def test_batch_create_malformed_data_denied(self):
        """Non-dict request data should be denied."""
        request = self._make_request(data="not a dict")
        view = self._make_view("batch_create")
        assert self.perm_class.has_permission(request, view) is False

    def test_batch_create_missing_requests_denied(self):
        """Missing 'requests' key should be denied."""
        request = self._make_request(data={"foo": "bar"})
        view = self._make_view("batch_create")
        assert self.perm_class.has_permission(request, view) is False
