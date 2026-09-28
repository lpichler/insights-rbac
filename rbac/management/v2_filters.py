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
"""Shared V2 query filter utilities."""

import re
from typing import Optional

from django.db.models import Q, QuerySet


def _glob_to_regex(pattern: str) -> str:
    """Convert a glob pattern with '*' wildcards to a regex."""
    parts = pattern.split("*", maxsplit=10)
    return "^" + ".*".join(re.escape(p) for p in parts) + "$"


def v2_name_query(name: str, field: str = "name") -> Optional[Q]:
    """Build a Q object for name filtering with '*' glob support.

    Without wildcards, performs case-insensitive substring match.
    With '*' wildcards, converts to regex for pattern matching.
    A bare '*' matches everything, represented as None (no filter needed).
    """
    if name == "*":
        return None
    if "*" in name:
        return Q(**{f"{field}__iregex": _glob_to_regex(name)})
    return Q(**{f"{field}__icontains": name})


def v2_name_filter(queryset: QuerySet, name: str, field: str = "name", extra_filters: dict | None = None) -> QuerySet:
    """Filter a queryset by name with '*' glob support.

    Without wildcards, performs case-insensitive substring match.
    With '*' wildcards, converts to regex for pattern matching.
    A bare '*' matches everything on the name itself, but extra_filters (if given) still apply.

    extra_filters, when given, are merged into the same filter() call so they constrain the
    same joined row as the name lookup (rather than an independently-joined row).
    """
    extra_filters = extra_filters or {}
    query = v2_name_query(name, field=field)
    if query is None:
        return queryset.filter(**extra_filters) if extra_filters else queryset
    return queryset.filter(query, **extra_filters)
