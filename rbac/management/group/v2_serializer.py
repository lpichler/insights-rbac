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
"""Serializers for GroupV2 API."""

from uuid import UUID

from management.group.model import Group
from management.group.v2_service import GroupV2Service
from management.utils import normalize_blank_or_none
from rest_framework import serializers

RESERVED_GROUP_NAMES = {"custom default access", "default access"}
VALID_ORDER_BY_FIELDS = {prefix + field for field in GroupV2Service.ORDER_BY_FIELD_MAPPING for prefix in ("", "-")}
MAX_BULK_PRINCIPALS = 100

# Each entry in role_names/principals produces a separate chained JOIN in GroupV2Service.list();
# cap entry count to bound worst-case query cost.
MAX_CSV_FILTER_ENTRIES = 50


def _split_csv(value: str) -> list[str] | None:
    """Split a comma-separated value, ignoring blank entries. Returns None when no entries remain."""
    return [item for item in (v.strip() for v in value.split(",")) if item] or None


def _split_csv_bounded(value: str) -> list[str] | None:
    """Split a comma-separated value, dedupe case-insensitively, and reject more than MAX_CSV_FILTER_ENTRIES entries."""
    items = _split_csv(value)
    if not items:
        return items
    deduped = list({item.lower(): item for item in items}.values())
    if len(deduped) > MAX_CSV_FILTER_ENTRIES:
        raise serializers.ValidationError(f"A maximum of {MAX_CSV_FILTER_ENTRIES} comma-separated values is allowed.")
    return deduped


class GroupV2ResponseSerializer(serializers.ModelSerializer):
    """Output serializer for the Group V2 API."""

    principal_count = serializers.IntegerField(source="principal_count_annotation", read_only=True)
    role_count = serializers.IntegerField(source="role_count_annotation", read_only=True)

    class Meta:
        model = Group
        fields = (
            "uuid",
            "name",
            "description",
            "principal_count",
            "role_count",
            "created",
            "modified",
            "system",
            "platform_default",
            "admin_default",
        )


class GroupV2RequestSerializer(serializers.Serializer):
    """Input serializer for Group V2 create/update requests."""

    name = serializers.CharField(min_length=1, max_length=150)
    description = serializers.CharField(max_length=1000, required=False, allow_blank=True, allow_null=True)

    def validate_name(self, value):
        """Reject names reserved for default groups."""
        if value.strip().lower() in RESERVED_GROUP_NAMES:
            raise serializers.ValidationError(f"'{value}' is reserved, please use another name.")
        return value


class GroupV2ListInputSerializer(serializers.Serializer):
    """Input serializer for Group V2 list query parameters."""

    name = serializers.CharField(
        required=False,
        allow_blank=True,
        help_text="Filter by name. Case-insensitive substring match by default; use * for glob patterns.",
    )
    uuid = serializers.CharField(
        required=False,
        allow_blank=True,
        help_text="Filter by comma-separated group UUIDs.",
    )
    username = serializers.CharField(
        required=False,
        allow_blank=True,
        max_length=150,
        help_text="Filter groups with a member username matching the value. Substring match; use * for globs.",
    )
    exclude_username = serializers.CharField(
        required=False,
        allow_blank=True,
        max_length=150,
        help_text="Exclude groups with a member username containing the value. Mutually exclusive with username.",
    )
    role_names = serializers.CharField(
        required=False,
        allow_blank=True,
        max_length=2000,
        help_text="Filter groups by comma-separated role names. Use role_discriminator to control match logic.",
    )
    role_discriminator = serializers.ChoiceField(
        choices=GroupV2Service.ROLE_DISCRIMINATORS,
        required=False,
        allow_blank=True,
        default=GroupV2Service.ROLE_DISCRIMINATOR_ANY,
        help_text="Match groups with 'any' (default) or 'all' of the role_names.",
    )
    principals = serializers.CharField(
        required=False,
        allow_blank=True,
        max_length=2000,
        help_text="Filter groups containing all of the comma-separated principal usernames.",
    )
    scope = serializers.ChoiceField(
        choices=GroupV2Service.SCOPES,
        required=False,
        allow_blank=True,
        default=GroupV2Service.ORG_ID_SCOPE,
        help_text="'org_id' (default) returns all groups; 'principal' returns only the requester's groups.",
    )
    system = serializers.BooleanField(required=False, allow_null=True, default=None)
    platform_default = serializers.BooleanField(required=False, allow_null=True, default=None)
    admin_default = serializers.BooleanField(required=False, allow_null=True, default=None)
    order_by = serializers.CharField(
        required=False,
        allow_blank=True,
        help_text=f"Sort by field, prefix with '-' for descending. Valid: {', '.join(sorted(VALID_ORDER_BY_FIELDS))}.",
    )

    validate_name = staticmethod(normalize_blank_or_none)
    validate_username = staticmethod(normalize_blank_or_none)
    validate_exclude_username = staticmethod(normalize_blank_or_none)
    validate_role_names = staticmethod(_split_csv_bounded)
    validate_principals = staticmethod(_split_csv_bounded)

    def validate_role_discriminator(self, value):
        """Map a blank role_discriminator to the default."""
        return value or GroupV2Service.ROLE_DISCRIMINATOR_ANY

    def validate_scope(self, value):
        """Map a blank scope to the default."""
        return value or GroupV2Service.ORG_ID_SCOPE

    def validate_uuid(self, value):
        """Parse comma-separated UUIDs, ignoring empty entries. Returns None when no UUIDs remain."""
        uuids = []
        for item in _split_csv(value) or ():
            try:
                uuids.append(UUID(item))
            except ValueError:
                raise serializers.ValidationError(f"'{item}' is not a valid UUID.")
        return uuids or None

    def validate_order_by(self, value):
        """Reject order_by values outside the allowed set; a blank value falls back to the default."""
        if not value:
            return None
        if value not in VALID_ORDER_BY_FIELDS:
            raise serializers.ValidationError(
                f"Invalid order_by value '{value}'. Valid values: {', '.join(sorted(VALID_ORDER_BY_FIELDS))}"
            )
        return value

    def validate(self, attrs):
        """Reject username and exclude_username supplied together."""
        if attrs.get("username") and attrs.get("exclude_username"):
            raise serializers.ValidationError(
                {"exclude_username": "username and exclude_username are mutually exclusive."}
            )
        return attrs


def _parse_csv_set(value: str) -> set:
    """Parse a comma-separated string into a set of stripped, non-empty values."""
    return {item.strip() for item in value.split(",") if item.strip()}


def _validate_batch_size(values: set) -> set:
    """Reject a deduplicated identifier set larger than MAX_BULK_PRINCIPALS.

    Applied after deduplication (not on the raw request payload) so add and remove enforce the same
    limit consistently -- e.g. the same identifier repeated over 100 times is one identifier, not a
    violation.
    """
    if len(values) > MAX_BULK_PRINCIPALS:
        raise serializers.ValidationError(f"A maximum of {MAX_BULK_PRINCIPALS} identifiers may be provided.")
    return values


class GroupV2AddPrincipalsInputSerializer(serializers.Serializer):
    """Input serializer for adding principals to a group. At least one field must contain items."""

    usernames = serializers.ListField(
        child=serializers.CharField(min_length=1),
        min_length=1,
        required=False,
        help_text=f"Usernames to add. Maximum {MAX_BULK_PRINCIPALS} unique identifiers per request.",
    )
    service_accounts = serializers.ListField(
        child=serializers.CharField(min_length=1),
        min_length=1,
        required=False,
        help_text=f"Service account client IDs to add. Maximum {MAX_BULK_PRINCIPALS} unique identifiers per request.",
    )

    def validate_usernames(self, value):
        """Normalize usernames to lower case, matching how they are stored on Principal, and deduplicate."""
        return _validate_batch_size({username.lower() for username in value})

    def validate_service_accounts(self, value):
        """Deduplicate service account client IDs."""
        return _validate_batch_size(set(value))

    def validate(self, data):
        """Require at least one of usernames or service_accounts to be present."""
        if not data.get("usernames") and not data.get("service_accounts"):
            raise serializers.ValidationError("At least one of usernames or service_accounts must contain items.")
        return data


class GroupV2ListPrincipalsInputSerializer(serializers.Serializer):
    """Input serializer for listing a group's member principals."""

    VALID_PRINCIPAL_TYPES = ("user", "service-account", "all")
    VALID_ORDER_BY_FIELDS = {"username", "-username"}

    principal_type = serializers.ChoiceField(
        choices=VALID_PRINCIPAL_TYPES,
        required=False,
        allow_blank=True,
        help_text="Filter by principal type: 'user' (default), 'service-account', or 'all'.",
    )
    username = serializers.CharField(required=False, allow_blank=True)
    principal_username = serializers.CharField(required=False, allow_blank=True)
    username_only = serializers.BooleanField(
        required=False,
        default=False,
        help_text=(
            "Accepted for API compatibility with the V1 endpoint. This service performs pure local "
            "Principal-table lookups with no external identity-service enrichment, so the response never "
            "contains enriched fields regardless of this flag -- it is always effectively satisfied."
        ),
    )
    admin_only = serializers.BooleanField(
        required=False,
        default=False,
        help_text=(
            "NOT YET IMPLEMENTED: org-admin status is not stored on the local Principal model and "
            "determining it requires a BOP/IT lookup, which is out of scope for this pure-local-lookup "
            "endpoint. This flag is currently accepted but has no filtering effect."
        ),
    )
    service_account_name = serializers.CharField(required=False, allow_blank=True)
    service_account_description = serializers.CharField(required=False, allow_blank=True)
    service_account_client_ids = serializers.CharField(
        required=False,
        allow_blank=True,
        help_text="Comma-separated service account client IDs. Incompatible with any other filter parameter.",
    )
    order_by = serializers.CharField(required=False, allow_blank=True)

    validate_username = staticmethod(normalize_blank_or_none)
    validate_principal_username = staticmethod(normalize_blank_or_none)
    validate_service_account_name = staticmethod(normalize_blank_or_none)
    validate_service_account_description = staticmethod(normalize_blank_or_none)

    def validate_principal_type(self, value):
        """Fall back to 'user' when omitted or blank."""
        return value or "user"

    def validate_service_account_client_ids(self, value):
        """Parse the comma-separated client IDs; return None when no IDs remain."""
        return _parse_csv_set(value) or None

    def validate_order_by(self, value):
        """Reject order_by values outside the allowed set; a blank value falls back to the default."""
        if not value:
            return "username"
        if value not in self.VALID_ORDER_BY_FIELDS:
            valid_values = ", ".join(sorted(self.VALID_ORDER_BY_FIELDS))
            raise serializers.ValidationError(f"Invalid order_by value '{value}'. Valid values: {valid_values}")
        return value

    def validate(self, data):
        """service_account_client_ids is incompatible with any other filter parameter."""
        if data.get("service_account_client_ids"):
            other_keys = set(self.initial_data.keys()) - {"service_account_client_ids", "limit", "offset"}
            if other_keys:
                raise serializers.ValidationError(
                    "service_account_client_ids is incompatible with any other query parameter."
                )
        return data


class GroupV2RemovePrincipalsInputSerializer(serializers.Serializer):
    """Input serializer for bulk-removing principals from a group via query parameters."""

    usernames = serializers.CharField(
        required=False, allow_blank=True, help_text="Comma-separated usernames to remove."
    )
    service_accounts = serializers.CharField(
        required=False, allow_blank=True, help_text="Comma-separated service account client IDs to remove."
    )

    def validate_usernames(self, value):
        """Parse the comma-separated usernames, normalized to lower case."""
        return _validate_batch_size({username.lower() for username in _parse_csv_set(value)})

    def validate_service_accounts(self, value):
        """Parse the comma-separated service account client IDs."""
        return _validate_batch_size(_parse_csv_set(value))

    def validate(self, data):
        """Require at least one of usernames or service_accounts to be present."""
        if not data.get("usernames") and not data.get("service_accounts"):
            raise serializers.ValidationError("At least one of usernames or service_accounts must be provided.")
        return data
