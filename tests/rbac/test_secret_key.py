"""Tests for SECRET_KEY configuration in settings.py."""

import importlib
import os
from unittest import mock

from django.core.exceptions import ImproperlyConfigured
from django.test import TestCase


class SecretKeyConfigurationTests(TestCase):
    """Verify SECRET_KEY is handled securely depending on DEBUG and env."""

    @staticmethod
    def _reload_settings(**env_overrides):
        """Reload settings module with the given environment overrides."""
        with mock.patch.dict(os.environ, env_overrides, clear=False):
            import rbac.settings as settings_mod

            importlib.reload(settings_mod)
            return settings_mod

    def test_explicit_key_used_when_set(self):
        """DJANGO_SECRET_KEY env var should be used verbatim."""
        mod = self._reload_settings(DJANGO_SECRET_KEY="explicit-test-key")
        self.assertEqual(mod.SECRET_KEY, "explicit-test-key")

    def test_random_key_generated_in_debug_mode(self):
        """When DEBUG=True and no key is set, a random key should be generated."""
        env = {k: v for k, v in os.environ.items() if k != "DJANGO_SECRET_KEY"}
        env["DJANGO_DEBUG"] = "True"
        with mock.patch.dict(os.environ, env, clear=True):
            import rbac.settings as settings_mod

            importlib.reload(settings_mod)
            self.assertTrue(len(settings_mod.SECRET_KEY) >= 50)

    def test_missing_key_raises_in_non_debug(self):
        """When DEBUG=False and no key is set, ImproperlyConfigured should be raised."""
        env = {k: v for k, v in os.environ.items() if k != "DJANGO_SECRET_KEY"}
        env["DJANGO_DEBUG"] = "False"
        with mock.patch.dict(os.environ, env, clear=True):
            import rbac.settings as settings_mod

            with self.assertRaises(ImproperlyConfigured) as ctx:
                importlib.reload(settings_mod)
            self.assertIn("DJANGO_SECRET_KEY", str(ctx.exception))

    def tearDown(self):
        """Restore settings to working state after each test."""
        import rbac.settings as settings_mod

        # Reload with original env to leave settings in a valid state
        importlib.reload(settings_mod)
