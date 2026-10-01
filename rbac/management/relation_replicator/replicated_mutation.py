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
"""Thin abstraction layer for outbox-coupled DB mutations.

Usage::

    with replicated_mutation(
        ReplicationEventType.CREATE_CUSTOM_ROLE,
        info={"role_uuid": str(role.uuid), "org_id": str(tenant.org_id)},
        tuples=lambda: (RoleV2.tuples_for_create(role=role, cached_permissions=perms), []),
    ):
        role.save()
        role.permissions.set(perms)

The ``tuples`` callable is evaluated *after* the mutation block completes so it
can reference objects that only exist post-save (e.g. auto-generated PKs) while
still closing over pre-mutation snapshots captured by the caller (e.g.
``old_permissions``).

The context manager owns:
- replicator resolution (enabled-flag + NoopReplicator/OutboxReplicator default)
- empty-event guard (skip if both add and remove are empty)
- ``raise_dual_write_exception`` wrapping (preserves SerializationFailure re-raise
  so ``@atomic_with_retry`` can retry the whole transaction)

The caller retains explicit control over:
- pre-mutation snapshots (``select_for_update`` + prefetch before the ``with`` block)
- the mutation itself (``role.save()``, ``role.permissions.set()``, etc.)
- which ``ReplicationEventType`` and ``info`` metadata to use
"""

from contextlib import contextmanager
from typing import Callable, Optional

from django.conf import settings

from management.relation_replicator.noop_replicator import NoopReplicator
from management.relation_replicator.outbox_replicator import OutboxReplicator
from management.relation_replicator.relation_replicator import (
    PartitionKey,
    RelationReplicator,
    ReplicationEvent,
    ReplicationEventType,
    raise_dual_write_exception,
)
from management.relation_replicator.types import RelationTuple


def default_replicator(replicator: Optional[RelationReplicator] = None) -> RelationReplicator:
    """Return the appropriate replicator based on settings and optional override.

    Centralises the enabled-flag check and default-implementation selection that
    was previously duplicated in every DualWriteHandler.__init__.
    """
    if not settings.REPLICATION_TO_RELATION_ENABLED:
        return NoopReplicator()
    return replicator if replicator is not None else OutboxReplicator()


@contextmanager
def replicated_mutation(
    event_type: ReplicationEventType,
    *,
    info: dict,
    tuples: Callable[[], tuple[list[RelationTuple], list[RelationTuple]]],
    replicator: Optional[RelationReplicator] = None,
):
    """Context manager that couples a DB mutation to a single outbox replication event.

    Must be used inside an active ``@atomic`` (SERIALIZABLE) transaction so that
    the outbox write and the model mutation commit or roll back together.

    Args:
        event_type: The business-level replication event type.
        info: Metadata dict attached to the ReplicationEvent (org_id, uuid, etc.).
        tuples: Zero-argument callable returning ``(add, remove)`` tuple lists.
                Evaluated after the mutation block so it can reference post-save
                state while closing over pre-mutation snapshots.
        replicator: Optional replicator override; defaults to OutboxReplicator or
                    NoopReplicator depending on settings.
    """
    repl = default_replicator(replicator)
    yield
    add, remove = tuples()
    if not add and not remove:
        return
    try:
        repl.replicate(
            ReplicationEvent(
                event_type=event_type,
                info=info,
                partition_key=PartitionKey.byEnvironment(),
                add=add,
                remove=remove,
            )
        )
    except Exception as e:
        raise_dual_write_exception(e, context=f"Failed to replicate {event_type}")
