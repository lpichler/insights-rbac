"""Tests for the wait_for_schema management command."""

from unittest.mock import MagicMock, patch

from django.core.management import CommandError, call_command
from django.test import TestCase


class TestWaitForSchema(TestCase):
    """Tests for the wait_for_schema management command."""

    @patch("management.management.commands.wait_for_schema.MigrationExecutor")
    @patch("management.management.commands.wait_for_schema.connections")
    def test_schema_ready_immediately(self, mock_connections, mock_executor_cls):
        """When all migrations are applied, command returns immediately."""
        mock_conn = MagicMock()
        mock_connections.__getitem__.return_value = mock_conn

        mock_executor = MagicMock()
        mock_executor.loader.graph.leaf_nodes.return_value = [("app", "0001_initial")]
        mock_executor.migration_plan.return_value = []
        mock_executor_cls.return_value = mock_executor

        call_command("wait_for_schema", timeout=10, poll_interval=1)

        mock_conn.prepare_database.assert_called_once()
        mock_executor.migration_plan.assert_called_once_with([("app", "0001_initial")])

    @patch("management.management.commands.wait_for_schema.time")
    @patch("management.management.commands.wait_for_schema.MigrationExecutor")
    @patch("management.management.commands.wait_for_schema.connections")
    def test_schema_pending_then_ready(self, mock_connections, mock_executor_cls, mock_time):
        """When migrations are pending, command polls until ready."""
        mock_conn = MagicMock()
        mock_connections.__getitem__.return_value = mock_conn
        mock_time.sleep = MagicMock()

        # monotonic() calls: init(0), remaining-check(0), sleep-calc(0), remaining-check(6)
        mock_time.monotonic = MagicMock(side_effect=[0, 0, 0, 6])

        mock_executor = MagicMock()
        mock_executor.loader.graph.leaf_nodes.return_value = [("app", "0002_add_field")]

        # First call: 2 pending migrations; second call: ready
        mock_executor.migration_plan.side_effect = [
            [("app", "0001"), ("app", "0002")],
            [],
        ]
        mock_executor_cls.return_value = mock_executor

        call_command("wait_for_schema", timeout=30, poll_interval=5)

        self.assertEqual(mock_executor.migration_plan.call_count, 2)
        mock_time.sleep.assert_called_once_with(5)

    @patch("management.management.commands.wait_for_schema.time")
    @patch("management.management.commands.wait_for_schema.MigrationExecutor")
    @patch("management.management.commands.wait_for_schema.connections")
    def test_schema_timeout(self, mock_connections, mock_executor_cls, mock_time):
        """When schema never becomes ready, command raises CommandError after timeout."""
        mock_conn = MagicMock()
        mock_connections.__getitem__.return_value = mock_conn
        mock_time.sleep = MagicMock()

        # monotonic() calls: init(0), remaining(0), sleep-calc(0),
        #   remaining(6), sleep-calc(6), remaining(12 -> expired)
        mock_time.monotonic = MagicMock(side_effect=[0, 0, 0, 6, 6, 12])

        mock_executor = MagicMock()
        mock_executor.loader.graph.leaf_nodes.return_value = [("app", "0003")]
        mock_executor.migration_plan.return_value = [("app", "0003")]
        mock_executor_cls.return_value = mock_executor

        with self.assertRaises(CommandError) as ctx:
            call_command("wait_for_schema", timeout=10, poll_interval=5)

        self.assertIn("Schema not ready after 10s", str(ctx.exception))
        self.assertEqual(mock_time.sleep.call_count, 2)

    @patch("management.management.commands.wait_for_schema.time")
    @patch("management.management.commands.wait_for_schema.MigrationExecutor")
    @patch("management.management.commands.wait_for_schema.connections")
    def test_db_error_then_recovery(self, mock_connections, mock_executor_cls, mock_time):
        """When DB connection fails temporarily, command retries and succeeds."""
        mock_conn = MagicMock()
        mock_connections.__getitem__.return_value = mock_conn
        mock_time.sleep = MagicMock()

        # monotonic() calls: init(0), remaining(0), sleep-calc(0), remaining(6)
        mock_time.monotonic = MagicMock(side_effect=[0, 0, 0, 6])

        # First call: prepare_database raises; second call: succeeds
        mock_conn.prepare_database.side_effect = [Exception("connection refused"), None, None]

        mock_executor = MagicMock()
        mock_executor.loader.graph.leaf_nodes.return_value = [("app", "0001")]
        mock_executor.migration_plan.return_value = []
        mock_executor_cls.return_value = mock_executor

        call_command("wait_for_schema", timeout=30, poll_interval=5)

        mock_time.sleep.assert_called_once_with(5)

    @patch("management.management.commands.wait_for_schema.os")
    @patch("management.management.commands.wait_for_schema.time")
    @patch("management.management.commands.wait_for_schema.MigrationExecutor")
    @patch("management.management.commands.wait_for_schema.connections")
    def test_timeout_from_env(self, mock_connections, mock_executor_cls, mock_time, mock_os):
        """Timeout defaults to SCHEMA_READINESS_TIMEOUT env var."""
        mock_conn = MagicMock()
        mock_connections.__getitem__.return_value = mock_conn
        mock_os.environ.get.return_value = "600"

        # monotonic() calls: init(0), remaining(0)
        mock_time.monotonic = MagicMock(side_effect=[0, 0])

        mock_executor = MagicMock()
        mock_executor.loader.graph.leaf_nodes.return_value = [("app", "0001")]
        mock_executor.migration_plan.return_value = []
        mock_executor_cls.return_value = mock_executor

        call_command("wait_for_schema")

        mock_os.environ.get.assert_called_with("SCHEMA_READINESS_TIMEOUT", "300")

    @patch("management.management.commands.wait_for_schema.time")
    @patch("management.management.commands.wait_for_schema.MigrationExecutor")
    @patch("management.management.commands.wait_for_schema.connections")
    def test_executor_error_then_timeout(self, mock_connections, mock_executor_cls, mock_time):
        """When MigrationExecutor consistently fails, command times out."""
        mock_conn = MagicMock()
        mock_connections.__getitem__.return_value = mock_conn
        mock_time.sleep = MagicMock()

        # monotonic() calls: init(0), remaining(0), sleep-calc(0),
        #   remaining(6), sleep-calc(6), remaining(12 -> expired)
        mock_time.monotonic = MagicMock(side_effect=[0, 0, 0, 6, 6, 12])

        mock_executor_cls.side_effect = Exception("django_migrations table does not exist")

        with self.assertRaises(CommandError) as ctx:
            call_command("wait_for_schema", timeout=10, poll_interval=5)

        self.assertIn("Schema not ready after 10s", str(ctx.exception))

    def test_negative_timeout_raises_error(self):
        """Negative timeout raises CommandError instead of silently exiting."""
        with self.assertRaises(CommandError) as ctx:
            call_command("wait_for_schema", timeout=-1, poll_interval=5)

        self.assertIn("timeout and poll-interval must be positive integers", str(ctx.exception))

    def test_zero_timeout_raises_error(self):
        """Zero timeout raises CommandError instead of using env fallback."""
        with self.assertRaises(CommandError) as ctx:
            call_command("wait_for_schema", timeout=0, poll_interval=5)

        self.assertIn("timeout and poll-interval must be positive integers", str(ctx.exception))

    def test_negative_poll_interval_raises_error(self):
        """Negative poll-interval raises CommandError."""
        with self.assertRaises(CommandError) as ctx:
            call_command("wait_for_schema", timeout=10, poll_interval=-1)

        self.assertIn("timeout and poll-interval must be positive integers", str(ctx.exception))

    @patch("management.management.commands.wait_for_schema.os")
    def test_non_numeric_env_timeout_raises_error(self, mock_os):
        """Non-numeric SCHEMA_READINESS_TIMEOUT env raises CommandError."""
        mock_os.environ.get.return_value = "not_a_number"

        with self.assertRaises(CommandError) as ctx:
            call_command("wait_for_schema")

        self.assertIn("SCHEMA_READINESS_TIMEOUT must be an integer", str(ctx.exception))

    @patch("management.management.commands.wait_for_schema.time")
    @patch("management.management.commands.wait_for_schema.MigrationExecutor")
    @patch("management.management.commands.wait_for_schema.connections")
    def test_sleep_capped_to_remaining_time(self, mock_connections, mock_executor_cls, mock_time):
        """When remaining time is less than poll_interval, sleep is capped."""
        mock_conn = MagicMock()
        mock_connections.__getitem__.return_value = mock_conn
        mock_time.sleep = MagicMock()

        # monotonic() calls: init(0), remaining(0), sleep-calc(0),
        #   remaining(7), sleep-calc(7), remaining(12 -> expired)
        mock_time.monotonic = MagicMock(side_effect=[0, 0, 0, 7, 7, 12])

        mock_executor = MagicMock()
        mock_executor.loader.graph.leaf_nodes.return_value = [("app", "0003")]
        mock_executor.migration_plan.return_value = [("app", "0003")]
        mock_executor_cls.return_value = mock_executor

        with self.assertRaises(CommandError):
            call_command("wait_for_schema", timeout=10, poll_interval=5)

        # Second sleep should be capped to remaining time (3s, not 5s)
        self.assertEqual(mock_time.sleep.call_count, 2)
        mock_time.sleep.assert_any_call(5)
        mock_time.sleep.assert_any_call(3)
