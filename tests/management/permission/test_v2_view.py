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
"""Test the PermissionV2 viewset."""

from importlib import reload

from django.test import override_settings
from django.urls import clear_url_caches, reverse
from rest_framework import status
from rest_framework.test import APIClient

from management.models import Access, Permission, Role
from rbac import urls
from tests.identity_request import IdentityRequest


@override_settings(V2_APIS_ENABLED=True)
class PermissionV2ViewsetTests(IdentityRequest):
    """Test the PermissionV2 viewset."""

    def setUp(self):
        """Set up the permission v2 viewset tests."""
        reload(urls)
        clear_url_caches()
        super().setUp()

        self.list_url = reverse("v2_management:permissions-list")
        self.options_url = reverse("v2_management:permissions-options")

        self.client = APIClient()

        self.permissionA = Permission.objects.create(permission="rbac:roles:read", tenant=self.tenant)
        self.permissionB = Permission.objects.create(permission="rbac:*:*", tenant=self.tenant)
        self.permissionC = Permission.objects.create(permission="acme:*:*", tenant=self.tenant)
        self.permissionD = Permission.objects.create(
            permission="foo:bar:baz", description="Description test.", tenant=self.tenant
        )
        self.permissionD.permissions.add(self.permissionA)

        self.roleA = Role.objects.create(name="roleA", tenant=self.tenant)
        Access.objects.create(permission=self.permissionA, role=self.roleA, tenant=self.tenant)

    def tearDown(self):
        """Tear down permission v2 viewset tests."""
        Permission.objects.all().delete()
        Role.objects.all().delete()

    def test_list_permissions_success(self):
        """Test that the v2 permissions list endpoint returns the expected shape."""
        response = self.client.get(self.list_url, **self.headers)

        self.assertEqual(response.status_code, status.HTTP_200_OK)
        for keyname in ["meta", "links", "data"]:
            self.assertIn(keyname, response.data)
        self.assertEqual(len(response.data["data"]), 4)

        for perm in response.data["data"]:
            self.assertIsNotNone(perm.get("application"))
            self.assertIsNotNone(perm.get("resource_type"))
            self.assertIsNotNone(perm.get("operation"))
            self.assertIsNotNone(perm.get("permission"))
            self.assertNotIn("verb", perm)
            if perm["permission"] == "foo:bar:baz":
                self.assertEqual(perm["description"], "Description test.")
                self.assertEqual(perm["requires"], ["rbac:roles:read"])
            else:
                self.assertEqual(perm["requires"], [])

    def test_list_permissions_application_filter(self):
        """Test filtering by application."""
        response = self.client.get(f"{self.list_url}?application=rbac", **self.headers)

        self.assertEqual(response.status_code, status.HTTP_200_OK)
        self.assertEqual(len(response.data["data"]), 2)

    def test_list_permissions_operation_filter(self):
        """Test filtering by operation (v2 name for verb)."""
        response = self.client.get(f"{self.list_url}?operation=read", **self.headers)

        self.assertEqual(response.status_code, status.HTTP_200_OK)
        self.assertEqual(len(response.data["data"]), 1)
        self.assertEqual(response.data["data"][0]["permission"], "rbac:roles:read")

    def test_list_permissions_exclude_globals(self):
        """Test excluding wildcard/global permissions."""
        response = self.client.get(f"{self.list_url}?exclude_globals=true", **self.headers)

        self.assertEqual(response.status_code, status.HTTP_200_OK)
        permissions = {p["permission"] for p in response.data["data"]}
        self.assertEqual(permissions, {"rbac:roles:read", "foo:bar:baz"})

    def test_list_permissions_exclude_roles(self):
        """Test excluding permissions already assigned to given role(s)."""
        response = self.client.get(f"{self.list_url}?exclude_roles={self.roleA.uuid}", **self.headers)

        self.assertEqual(response.status_code, status.HTTP_200_OK)
        permissions = {p["permission"] for p in response.data["data"]}
        self.assertNotIn("rbac:roles:read", permissions)

    def test_list_permissions_invalid_exclude_roles(self):
        """Test that an invalid role uuid in exclude_roles returns a 400."""
        response = self.client.get(f"{self.list_url}?exclude_roles=not-a-uuid", **self.headers)

        self.assertEqual(response.status_code, status.HTTP_400_BAD_REQUEST)

    def test_list_permissions_fields_selection(self):
        """Test that the fields parameter restricts returned fields."""
        response = self.client.get(f"{self.list_url}?fields=permission,operation", **self.headers)

        self.assertEqual(response.status_code, status.HTTP_200_OK)
        for perm in response.data["data"]:
            self.assertEqual(set(perm.keys()), {"permission", "operation"})

    def test_list_permissions_invalid_fields(self):
        """Test that an unknown field in the fields parameter returns a 400."""
        response = self.client.get(f"{self.list_url}?fields=not_a_field", **self.headers)

        self.assertEqual(response.status_code, status.HTTP_400_BAD_REQUEST)

    def test_list_permissions_order_by_descending(self):
        """Test descending order_by."""
        response = self.client.get(f"{self.list_url}?order_by=-permission", **self.headers)

        self.assertEqual(response.status_code, status.HTTP_200_OK)
        permissions = [p["permission"] for p in response.data["data"]]
        self.assertEqual(permissions, sorted(permissions, reverse=True))

    def test_list_permissions_invalid_order_by(self):
        """Test that an invalid order_by field returns a 400."""
        response = self.client.get(f"{self.list_url}?order_by=bogus", **self.headers)

        self.assertEqual(response.status_code, status.HTTP_400_BAD_REQUEST)

    def test_options_application(self):
        """Test the options endpoint for distinct application values."""
        response = self.client.get(f"{self.options_url}?field=application", **self.headers)

        self.assertEqual(response.status_code, status.HTTP_200_OK)
        self.assertEqual(set(response.data["data"]), {"rbac", "acme", "foo"})

    def test_options_invalid_field(self):
        """Test that an invalid field parameter returns a 400."""
        response = self.client.get(f"{self.options_url}?field=bogus", **self.headers)

        self.assertEqual(response.status_code, status.HTTP_400_BAD_REQUEST)
