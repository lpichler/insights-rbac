#
# Copyright 2024 Red Hat, Inc.
#
#    This program is free software: you can redistribute it and/or modify
#    it under the terms of the GNU Affero General Public License as
#    published by the Free Software Foundation, either version 3 of the
#    License, or (at your option) any later version.
#
#    This program is distributed in the hope that it will be useful,
#    but WITHOUT ANY WARRANTY; without even the implied warranty of
#    MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the
#    GNU Affero General Public License for more details.
#
#    You should have received a copy of the GNU Affero General Public License
#    along with this program.  If not, see <https://www.gnu.org/licenses/>.
#
"""Custom management command to wait for the database schema to be current."""

import os
import time

from django.core.management.base import BaseCommand, CommandError
from django.db import connections
from django.db.migrations.executor import MigrationExecutor


class Command(BaseCommand):
    """Wait until all Django migrations have been applied to the database.

    Useful for init containers of non-migrating workloads (workers, schedulers)
    that need to wait for a separate migration service to finish before starting.
    """

    help = "Wait for database schema to be current (all migrations applied)"

    def add_arguments(self, parser):
        """Add command arguments."""
        parser.add_argument(
            "--timeout",
            type=int,
            default=None,
            help="Max seconds to wait (default: SCHEMA_READINESS_TIMEOUT env or 300)",
        )
        parser.add_argument(
            "--poll-interval",
            type=int,
            default=5,
            help="Seconds between checks (default: 5)",
        )

    def handle(self, *args, **options):
        """Handle the command execution."""
        timeout = options["timeout"]
        if timeout is None:
            raw = os.environ.get("SCHEMA_READINESS_TIMEOUT", "300")
            try:
                timeout = int(raw)
            except ValueError:
                raise CommandError("SCHEMA_READINESS_TIMEOUT must be an integer, got %r" % raw)
        poll_interval = options["poll_interval"]
        if timeout <= 0 or poll_interval <= 0:
            raise CommandError("timeout and poll-interval must be positive integers")

        self.stdout.write("Waiting for schema readiness (timeout=%ds, poll=%ds)..." % (timeout, poll_interval))

        deadline = time.monotonic() + timeout
        while True:
            remaining = deadline - time.monotonic()
            if remaining <= 0:
                break

            try:
                connection = connections["default"]
                connection.prepare_database()
                executor = MigrationExecutor(connection)
                targets = executor.loader.graph.leaf_nodes()
                plan = executor.migration_plan(targets)

                if not plan:
                    self.stdout.write(self.style.SUCCESS("Schema is current — all migrations applied."))
                    return

                pending_count = len(plan)
                self.stdout.write("%d unapplied migration(s). Retrying in %ds..." % (pending_count, poll_interval))
            except Exception as exc:
                self.stdout.write("Schema check error: %s. Retrying in %ds..." % (exc, poll_interval))

            sleep_time = min(poll_interval, deadline - time.monotonic())
            if sleep_time > 0:
                time.sleep(sleep_time)

        raise CommandError(
            "Schema not ready after %ds. "
            "Ensure the migration service has completed before this workload starts." % timeout
        )
