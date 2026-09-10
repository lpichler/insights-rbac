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
"""Backfill remote principals in SpiceDB via TenantMapping update_user."""

import logging

from django.db import transaction
from management.models import Principal

logger = logging.getLogger(__name__)


def backfill_remote_principal(bootstrap_service, user, tenant):
    """Backfill a single user's TenantMapping membership via update_user.

    Checks whether the user's Principal record already has a ``user_id`` set;
    if so, no sync is needed.  System users and service accounts are skipped.

    Args:
        bootstrap_service: TenantBootstrapService instance.
        user: User object to sync.
        tenant: Tenant instance for principal lookup.
    """
    if user.system or user.is_service_account:
        return
    if not user.username:
        return

    try:
        principal = Principal.objects.get(username__iexact=user.username, tenant=tenant)
        if principal.user_id is not None:
            return
    except Principal.DoesNotExist:
        pass  # New principal — needs sync.

    try:
        with transaction.atomic():
            bootstrap_service.update_user(user, upsert=True)
    except Exception:
        logger.warning(
            "Failed to backfill remote principal %s in org %s",
            user.username,
            tenant.org_id,
            exc_info=True,
        )


def backfill_remote_principals(bootstrap_service, users, tenant):
    """Backfill a list of users' TenantMapping membership via update_user.

    Args:
        bootstrap_service: TenantBootstrapService instance.
        users: Iterable of User objects to sync.
        tenant: Tenant instance for principal lookup.
    """
    for user in users:
        backfill_remote_principal(bootstrap_service, user, tenant)
