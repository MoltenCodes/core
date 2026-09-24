"""Tests for the real-client installer, always against a fake game folder.

Every test builds its own World of Warcraft folder in a temporary directory:
``<wow>/_retail_/Interface/AddOns`` with a neighbouring addon that must never
be touched, and ``<wow>/_retail_/WTF/Account/...`` with saved variables. The
real bundle is built from the repository, because what is installed is what
the owner's client will load.
"""

from __future__ import annotations

import contextlib
import io
import shutil
import subprocess
import tempfile
import unittest
from pathlib import Path

from tooling.client import install as module
from tooling.validation.validate_manifests import load_manifests


class FakeClientTests(unittest.TestCase):
    """A fake game folder per test, and helpers to run the command against it."""

    def setUp(self):
        self.tempdir = tempfile.TemporaryDirectory()
        # Resolved, because the command prints resolved paths (/var is a link on macOS).
        self.base = Path(self.tempdir.name).resolve()
        self.wow = self.base / "World of Warcraft"
        self.flavour = self.wow / "_retail_"
        self.addons = self.flavour / "Interface" / "AddOns"
        self.addons.mkdir(parents=True)

        self.neighbour = self.addons / "SomeoneElsesAddon"
        self.neighbour.mkdir()
        (self.neighbour / "SomeoneElsesAddon.toc").write_text("## Title: Other\n", encoding="utf-8")

    def tearDown(self):
        self.tempdir.cleanup()

    def run_command(self, *arguments: str) -> tuple[int, str, str]:
        """Run ``main`` against the fake folder; return status, stdout, stderr."""
        stdout, stderr = io.StringIO(), io.StringIO()
        with contextlib.redirect_stdout(stdout), contextlib.redirect_stderr(stderr):
            status = module.main(["--wow-dir", str(self.wow), *arguments])
        return status, stdout.getvalue(), stderr.getvalue()

    def saved_variables(self, *parts: str) -> Path:
        """Create ``WTF/Account/<parts>/SavedVariables`` and return it."""
        folder = self.flavour / "WTF" / "Account" / Path(*parts) / "SavedVariables"
        folder.mkdir(parents=True)
        return folder

    def assert_neighbour_untouched(self):
        self.assertTrue((self.neighbour / "SomeoneElsesAddon.toc").is_file())


class InstallTests(FakeClientTests):
    def test_installs_the_bundle_the_harness_and_the_registry_test_addon(self):
        status, output, errors = self.run_command("--package", "registry")

        self.assertEqual(0, status, errors)
        self.assertTrue((self.addons / "MoltenCodes" / "MoltenCodes.toc").is_file())
        self.assertTrue((self.addons / "MoltenCodes" / "registry" / "Registry.lua").is_file())
        harness = self.addons / "MoltenCodesTest"
        self.assertEqual(
            ["Expected.lua", "Harness.lua", "MoltenCodesTest.toc", "TestKit.lua"],
            sorted(path.name for path in harness.iterdir()),
        )
        self.assertEqual(
            module.TEST_KIT_SOURCE.read_bytes(), (harness / "TestKit.lua").read_bytes()
        )
        registry_addon = self.addons / "MoltenCodesTest_Registry"
        self.assertEqual(
            ["MoltenCodesTest_Registry.toc", "RegistrySuite.lua"],
            sorted(path.name for path in registry_addon.iterdir()),
        )
        self.assertIn("installed", output)
        self.assert_neighbour_untouched()

    def test_installs_the_signalkit_test_addon_without_its_expected_md(self):
        status, output, errors = self.run_command("--package", "signalKit")

        self.assertEqual(0, status, errors)
        signal_kit_addon = self.addons / "MoltenCodesTest_SignalKit"
        self.assertEqual(
            ["MoltenCodesTest_SignalKit.toc", "SignalKitSuite.lua"],
            sorted(path.name for path in signal_kit_addon.iterdir()),
        )
        self.assertTrue((self.addons / "MoltenCodesTest" / "Harness.lua").is_file())
        self.assertFalse((self.addons / "MoltenCodesTest_Registry").exists())
        self.assertIn(str(signal_kit_addon), output)
        self.assert_neighbour_untouched()

    def test_installs_the_eventkit_test_addon_without_its_expected_md(self):
        status, output, errors = self.run_command("--package", "eventKit")

        self.assertEqual(0, status, errors)
        event_kit_addon = self.addons / "MoltenCodesTest_EventKit"
        self.assertEqual(
            ["EventKitSuite.lua", "MoltenCodesTest_EventKit.toc"],
            sorted(path.name for path in event_kit_addon.iterdir()),
        )
        toc = (event_kit_addon / "MoltenCodesTest_EventKit.toc").read_text(encoding="utf-8")
        self.assertIn("## Dependencies: MoltenCodesTest\n", toc)
        self.assertTrue((self.addons / "MoltenCodes" / "eventKit" / "EventKit.lua").is_file())
        self.assertTrue((self.addons / "MoltenCodesTest" / "Harness.lua").is_file())
        self.assertFalse((self.addons / "MoltenCodesTest_SignalKit").exists())
        self.assertIn(str(event_kit_addon), output)
        self.assert_neighbour_untouched()

    def test_installs_the_lifecyclekit_test_addon_without_its_expected_md(self):
        status, output, errors = self.run_command("--package", "lifecycleKit")

        self.assertEqual(0, status, errors)
        lifecycle_kit_addon = self.addons / "MoltenCodesTest_LifecycleKit"
        self.assertEqual(
            ["LifecycleKitSuite.lua", "MoltenCodesTest_LifecycleKit.toc"],
            sorted(path.name for path in lifecycle_kit_addon.iterdir()),
        )
        toc = (lifecycle_kit_addon / "MoltenCodesTest_LifecycleKit.toc").read_text(encoding="utf-8")
        self.assertIn("## Dependencies: MoltenCodesTest\n", toc)
        self.assertIn("\nLifecycleKitSuite.lua\n", toc)
        bundle = self.addons / "MoltenCodes"
        self.assertTrue((bundle / "lifecycleKit" / "LifecycleKit.lua").is_file())
        # The capability test reads every Kit CLOSES_ADDON_SCOPES names from the bundle.
        for kit in (
            "timerKit/TimerKit.lua",
            "schedulerKit/SchedulerKit.lua",
            "hookKit/HookKit.lua",
            "commandKit/CommandKit.lua",
            "commKit/CommKit.lua",
        ):
            with self.subTest(kit=kit):
                self.assertTrue((bundle / kit).is_file())
        self.assertTrue((self.addons / "MoltenCodesTest" / "Harness.lua").is_file())
        self.assertFalse((self.addons / "MoltenCodesTest_EventKit").exists())
        self.assertIn(str(lifecycle_kit_addon), output)
        self.assert_neighbour_untouched()

    def test_installs_the_timerkit_test_addon_without_its_expected_md(self):
        status, output, errors = self.run_command("--package", "timerKit")

        self.assertEqual(0, status, errors)
        timer_kit_addon = self.addons / "MoltenCodesTest_TimerKit"
        self.assertEqual(
            ["MoltenCodesTest_TimerKit.toc", "TimerKitSuite.lua"],
            sorted(path.name for path in timer_kit_addon.iterdir()),
        )
        toc = (timer_kit_addon / "MoltenCodesTest_TimerKit.toc").read_text(encoding="utf-8")
        self.assertIn("## Dependencies: MoltenCodesTest\n", toc)
        self.assertIn("\nTimerKitSuite.lua\n", toc)
        bundle = self.addons / "MoltenCodes"
        self.assertTrue((bundle / "timerKit" / "TimerKit.lua").is_file())
        # The ForAddon test logs the logout route LifecycleKit provides.
        self.assertTrue((bundle / "lifecycleKit" / "LifecycleKit.lua").is_file())
        self.assertTrue((self.addons / "MoltenCodesTest" / "Harness.lua").is_file())
        self.assertFalse((self.addons / "MoltenCodesTest_Registry").exists())
        self.assertIn(str(timer_kit_addon), output)
        self.assert_neighbour_untouched()

    def test_installs_the_modulekit_test_addon_without_its_expected_md(self):
        status, output, errors = self.run_command("--package", "moduleKit")

        self.assertEqual(0, status, errors)
        module_kit_addon = self.addons / "MoltenCodesTest_ModuleKit"
        self.assertEqual(
            ["ModuleKitSuite.lua", "MoltenCodesTest_ModuleKit.toc"],
            sorted(path.name for path in module_kit_addon.iterdir()),
        )
        toc = (module_kit_addon / "MoltenCodesTest_ModuleKit.toc").read_text(encoding="utf-8")
        self.assertIn("## Dependencies: MoltenCodesTest\n", toc)
        self.assertIn("\nModuleKitSuite.lua\n", toc)
        bundle = self.addons / "MoltenCodes"
        self.assertTrue((bundle / "moduleKit" / "ModuleKit.lua").is_file())
        # The scope and injection tests use every Kit behind module.scope and
        # SchemaKit for the schema form of implements, all from the bundle.
        for kit in (
            "timerKit/TimerKit.lua",
            "eventKit/EventKit.lua",
            "schedulerKit/SchedulerKit.lua",
            "hookKit/HookKit.lua",
            "commandKit/CommandKit.lua",
            "commKit/CommKit.lua",
            "signalKit/SignalKit.lua",
            "schemaKit/SchemaKit.lua",
        ):
            with self.subTest(kit=kit):
                self.assertTrue((bundle / kit).is_file())
        self.assertTrue((self.addons / "MoltenCodesTest" / "Harness.lua").is_file())
        self.assertFalse((self.addons / "MoltenCodesTest_LifecycleKit").exists())
        self.assertIn(str(module_kit_addon), output)
        self.assert_neighbour_untouched()

    def test_installs_the_poolkit_test_addon_without_its_expected_md(self):
        status, output, errors = self.run_command("--package", "poolKit")

        self.assertEqual(0, status, errors)
        pool_kit_addon = self.addons / "MoltenCodesTest_PoolKit"
        self.assertEqual(
            ["MoltenCodesTest_PoolKit.toc", "PoolKitSuite.lua"],
            sorted(path.name for path in pool_kit_addon.iterdir()),
        )
        toc = (pool_kit_addon / "MoltenCodesTest_PoolKit.toc").read_text(encoding="utf-8")
        self.assertIn("## Dependencies: MoltenCodesTest\n", toc)
        self.assertIn("\nPoolKitSuite.lua\n", toc)
        self.assertTrue((self.addons / "MoltenCodes" / "poolKit" / "PoolKit.lua").is_file())
        self.assertTrue((self.addons / "MoltenCodesTest" / "Harness.lua").is_file())
        self.assertFalse((self.addons / "MoltenCodesTest_Registry").exists())
        self.assertIn(str(pool_kit_addon), output)
        self.assert_neighbour_untouched()

    def test_installs_the_cachekit_test_addon_without_its_expected_md(self):
        status, output, errors = self.run_command("--package", "cacheKit")

        self.assertEqual(0, status, errors)
        cache_kit_addon = self.addons / "MoltenCodesTest_CacheKit"
        self.assertEqual(
            ["CacheKitSuite.lua", "MoltenCodesTest_CacheKit.toc"],
            sorted(path.name for path in cache_kit_addon.iterdir()),
        )
        toc = (cache_kit_addon / "MoltenCodesTest_CacheKit.toc").read_text(encoding="utf-8")
        self.assertIn("## Dependencies: MoltenCodesTest\n", toc)
        self.assertIn("\nCacheKitSuite.lua\n", toc)
        bundle = self.addons / "MoltenCodes"
        self.assertTrue((bundle / "cacheKit" / "CacheKit.lua").is_file())
        # The ClearOn tests need EventKit, CacheKit's optional dependency,
        # from the same bundle.
        self.assertTrue((bundle / "eventKit" / "EventKit.lua").is_file())
        self.assertTrue((self.addons / "MoltenCodesTest" / "Harness.lua").is_file())
        self.assertFalse((self.addons / "MoltenCodesTest_EventKit").exists())
        self.assertIn(str(cache_kit_addon), output)
        self.assert_neighbour_untouched()

    def test_installs_the_profilekit_test_addon_without_its_expected_md(self):
        status, output, errors = self.run_command("--package", "profileKit")

        self.assertEqual(0, status, errors)
        profile_kit_addon = self.addons / "MoltenCodesTest_ProfileKit"
        self.assertEqual(
            ['MoltenCodesTest_ProfileKit.toc', 'ProfileKitSuite.lua'],
            sorted(path.name for path in profile_kit_addon.iterdir()),
        )
        toc = (profile_kit_addon / "MoltenCodesTest_ProfileKit.toc").read_text(encoding="utf-8")
        self.assertIn("## Dependencies: MoltenCodesTest\n", toc)
        self.assertIn("\nProfileKitSuite.lua\n", toc)
        self.assertTrue((self.addons / "MoltenCodes" / "profileKit" / "ProfileKit.lua").is_file())
        self.assertTrue((self.addons / "MoltenCodesTest" / "Harness.lua").is_file())
        self.assertFalse((self.addons / "MoltenCodesTest_Registry").exists())
        self.assertIn(str(profile_kit_addon), output)
        self.assert_neighbour_untouched()

    def test_installs_the_readinesskit_test_addon_without_its_expected_md(self):
        status, output, errors = self.run_command("--package", "readinessKit")

        self.assertEqual(0, status, errors)
        readiness_kit_addon = self.addons / "MoltenCodesTest_ReadinessKit"
        self.assertEqual(
            ['MoltenCodesTest_ReadinessKit.toc', 'ReadinessKitSuite.lua'],
            sorted(path.name for path in readiness_kit_addon.iterdir()),
        )
        toc = (readiness_kit_addon / "MoltenCodesTest_ReadinessKit.toc").read_text(encoding="utf-8")
        self.assertIn("## Dependencies: MoltenCodesTest\n", toc)
        self.assertIn("\nReadinessKitSuite.lua\n", toc)
        self.assertTrue((self.addons / "MoltenCodes" / "readinessKit" / "ReadinessKit.lua").is_file())
        self.assertTrue((self.addons / "MoltenCodesTest" / "Harness.lua").is_file())
        self.assertFalse((self.addons / "MoltenCodesTest_Registry").exists())
        self.assertIn(str(readiness_kit_addon), output)
        self.assert_neighbour_untouched()

    def test_installs_the_schemakit_test_addon_without_its_expected_md(self):
        status, output, errors = self.run_command("--package", "schemaKit")

        self.assertEqual(0, status, errors)
        schema_kit_addon = self.addons / "MoltenCodesTest_SchemaKit"
        self.assertEqual(
            ['MoltenCodesTest_SchemaKit.toc', 'SchemaKitSuite.lua'],
            sorted(path.name for path in schema_kit_addon.iterdir()),
        )
        toc = (schema_kit_addon / "MoltenCodesTest_SchemaKit.toc").read_text(encoding="utf-8")
        self.assertIn("## Dependencies: MoltenCodesTest\n", toc)
        self.assertIn("\nSchemaKitSuite.lua\n", toc)
        self.assertTrue((self.addons / "MoltenCodes" / "schemaKit" / "SchemaKit.lua").is_file())
        self.assertTrue((self.addons / "MoltenCodesTest" / "Harness.lua").is_file())
        self.assertFalse((self.addons / "MoltenCodesTest_Registry").exists())
        self.assertIn(str(schema_kit_addon), output)
        self.assert_neighbour_untouched()

    def test_installs_the_localekit_test_addon_without_its_expected_md(self):
        status, output, errors = self.run_command("--package", "localeKit")

        self.assertEqual(0, status, errors)
        locale_kit_addon = self.addons / "MoltenCodesTest_LocaleKit"
        self.assertEqual(
            ['LocaleKitSuite.lua', 'MoltenCodesTest_LocaleKit.toc'],
            sorted(path.name for path in locale_kit_addon.iterdir()),
        )
        toc = (locale_kit_addon / "MoltenCodesTest_LocaleKit.toc").read_text(encoding="utf-8")
        self.assertIn("## Dependencies: MoltenCodesTest\n", toc)
        self.assertIn("\nLocaleKitSuite.lua\n", toc)
        self.assertTrue((self.addons / "MoltenCodes" / "localeKit" / "LocaleKit.lua").is_file())
        self.assertTrue((self.addons / "MoltenCodesTest" / "Harness.lua").is_file())
        self.assertFalse((self.addons / "MoltenCodesTest_Registry").exists())
        self.assertIn(str(locale_kit_addon), output)
        self.assert_neighbour_untouched()

    def test_installs_the_hookkit_test_addon_without_its_expected_md(self):
        status, output, errors = self.run_command("--package", "hookKit")

        self.assertEqual(0, status, errors)
        hook_kit_addon = self.addons / "MoltenCodesTest_HookKit"
        self.assertEqual(
            ['HookKitSuite.lua', 'MoltenCodesTest_HookKit.toc'],
            sorted(path.name for path in hook_kit_addon.iterdir()),
        )
        toc = (hook_kit_addon / "MoltenCodesTest_HookKit.toc").read_text(encoding="utf-8")
        self.assertIn("## Dependencies: MoltenCodesTest\n", toc)
        self.assertIn("\nHookKitSuite.lua\n", toc)
        self.assertTrue((self.addons / "MoltenCodes" / "hookKit" / "HookKit.lua").is_file())
        self.assertTrue((self.addons / "MoltenCodesTest" / "Harness.lua").is_file())
        self.assertFalse((self.addons / "MoltenCodesTest_Registry").exists())
        self.assertIn(str(hook_kit_addon), output)
        self.assert_neighbour_untouched()

    def test_installs_the_settingskit_test_addon_without_its_expected_md(self):
        status, output, errors = self.run_command("--package", "settingsKit")

        self.assertEqual(0, status, errors)
        settings_kit_addon = self.addons / "MoltenCodesTest_SettingsKit"
        self.assertEqual(
            ['MoltenCodesTest_SettingsKit.toc', 'SettingsKitSuite.lua'],
            sorted(path.name for path in settings_kit_addon.iterdir()),
        )
        toc = (settings_kit_addon / "MoltenCodesTest_SettingsKit.toc").read_text(encoding="utf-8")
        self.assertIn("## Dependencies: MoltenCodesTest\n", toc)
        self.assertIn("## SavedVariables: MoltenCodesTest_SettingsKitDB\n", toc)
        self.assertIn("## SavedVariablesPerCharacter: MoltenCodesTest_SettingsKitCharDB\n", toc)
        self.assertIn("\nSettingsKitSuite.lua\n", toc)
        self.assertTrue((self.addons / "MoltenCodes" / "settingsKit" / "SettingsKit.lua").is_file())
        self.assertTrue((self.addons / "MoltenCodesTest" / "Harness.lua").is_file())
        self.assertFalse((self.addons / "MoltenCodesTest_Registry").exists())
        self.assertIn(str(settings_kit_addon), output)
        self.assert_neighbour_untouched()

    def test_installs_the_optionskit_test_addon_without_its_expected_md(self):
        status, output, errors = self.run_command("--package", "optionsKit")

        self.assertEqual(0, status, errors)
        options_kit_addon = self.addons / "MoltenCodesTest_OptionsKit"
        self.assertEqual(
            ['MoltenCodesTest_OptionsKit.toc', 'OptionsKitSuite.lua'],
            sorted(path.name for path in options_kit_addon.iterdir()),
        )
        toc = (options_kit_addon / "MoltenCodesTest_OptionsKit.toc").read_text(encoding="utf-8")
        self.assertIn("## Dependencies: MoltenCodesTest\n", toc)
        self.assertNotIn("## SavedVariables", toc)
        self.assertIn("\nOptionsKitSuite.lua\n", toc)
        self.assertTrue((self.addons / "MoltenCodes" / "optionsKit" / "OptionsKit.lua").is_file())
        self.assertTrue((self.addons / "MoltenCodesTest" / "Harness.lua").is_file())
        self.assertFalse((self.addons / "MoltenCodesTest_Registry").exists())
        self.assertIn(str(options_kit_addon), output)
        self.assert_neighbour_untouched()

    def test_installs_the_commandkit_test_addon_without_its_expected_md(self):
        status, output, errors = self.run_command("--package", "commandKit")

        self.assertEqual(0, status, errors)
        command_kit_addon = self.addons / "MoltenCodesTest_CommandKit"
        self.assertEqual(
            ['CommandKitSuite.lua', 'MoltenCodesTest_CommandKit.toc'],
            sorted(path.name for path in command_kit_addon.iterdir()),
        )
        toc = (command_kit_addon / "MoltenCodesTest_CommandKit.toc").read_text(encoding="utf-8")
        self.assertIn("## Dependencies: MoltenCodesTest\n", toc)
        self.assertIn("\nCommandKitSuite.lua\n", toc)
        self.assertTrue((self.addons / "MoltenCodes" / "commandKit" / "CommandKit.lua").is_file())
        self.assertTrue((self.addons / "MoltenCodesTest" / "Harness.lua").is_file())
        self.assertFalse((self.addons / "MoltenCodesTest_Registry").exists())
        self.assertIn(str(command_kit_addon), output)
        self.assert_neighbour_untouched()

    def test_installs_the_codeckit_test_addon_without_its_expected_md(self):
        status, output, errors = self.run_command("--package", "codecKit")

        self.assertEqual(0, status, errors)
        codec_kit_addon = self.addons / "MoltenCodesTest_CodecKit"
        self.assertEqual(
            ['CodecKitSuite.lua', 'MoltenCodesTest_CodecKit.toc'],
            sorted(path.name for path in codec_kit_addon.iterdir()),
        )
        toc = (codec_kit_addon / "MoltenCodesTest_CodecKit.toc").read_text(encoding="utf-8")
        self.assertIn("## Dependencies: MoltenCodesTest\n", toc)
        self.assertIn("\nCodecKitSuite.lua\n", toc)
        self.assertTrue((self.addons / "MoltenCodes" / "codecKit" / "CodecKit.lua").is_file())
        self.assertTrue((self.addons / "MoltenCodesTest" / "Harness.lua").is_file())
        self.assertFalse((self.addons / "MoltenCodesTest_Registry").exists())
        self.assertIn(str(codec_kit_addon), output)
        self.assert_neighbour_untouched()

    def test_installs_the_commkit_test_addon_without_its_expected_md(self):
        status, output, errors = self.run_command("--package", "commKit")

        self.assertEqual(0, status, errors)
        comm_kit_addon = self.addons / "MoltenCodesTest_CommKit"
        self.assertEqual(
            ['CommKitSuite.lua', 'MoltenCodesTest_CommKit.toc'],
            sorted(path.name for path in comm_kit_addon.iterdir()),
        )
        toc = (comm_kit_addon / "MoltenCodesTest_CommKit.toc").read_text(encoding="utf-8")
        self.assertIn("## Dependencies: MoltenCodesTest\n", toc)
        self.assertIn("\nCommKitSuite.lua\n", toc)
        self.assertTrue((self.addons / "MoltenCodes" / "commKit" / "CommKit.lua").is_file())
        self.assertTrue((self.addons / "MoltenCodesTest" / "Harness.lua").is_file())
        self.assertFalse((self.addons / "MoltenCodesTest_Registry").exists())
        self.assertIn(str(comm_kit_addon), output)
        self.assert_neighbour_untouched()

    def test_installs_the_schedulerkit_test_addon_without_its_expected_md(self):
        status, output, errors = self.run_command("--package", "schedulerKit")

        self.assertEqual(0, status, errors)
        scheduler_kit_addon = self.addons / "MoltenCodesTest_SchedulerKit"
        self.assertEqual(
            ["MoltenCodesTest_SchedulerKit.toc", "SchedulerKitSuite.lua"],
            sorted(path.name for path in scheduler_kit_addon.iterdir()),
        )
        toc = (scheduler_kit_addon / "MoltenCodesTest_SchedulerKit.toc").read_text(
            encoding="utf-8"
        )
        self.assertIn("## Dependencies: MoltenCodesTest\n", toc)
        self.assertIn("\nSchedulerKitSuite.lua\n", toc)
        bundle = self.addons / "MoltenCodes"
        self.assertTrue((bundle / "schedulerKit" / "SchedulerKit.lua").is_file())
        # SchedulerKit's delays are TimerKit timers, and the ForAddon test logs
        # the logout route LifecycleKit provides.
        for kit in ("timerKit/TimerKit.lua", "lifecycleKit/LifecycleKit.lua"):
            with self.subTest(kit=kit):
                self.assertTrue((bundle / kit).is_file())
        self.assertTrue((self.addons / "MoltenCodesTest" / "Harness.lua").is_file())
        self.assertFalse((self.addons / "MoltenCodesTest_TimerKit").exists())
        self.assertIn(str(scheduler_kit_addon), output)
        self.assert_neighbour_untouched()

    def test_installs_the_clientkit_test_addon_without_its_expected_md(self):
        status, output, errors = self.run_command("--package", "clientKit")

        self.assertEqual(0, status, errors)
        client_kit_addon = self.addons / "MoltenCodesTest_ClientKit"
        self.assertEqual(
            ["ClientKitSuite.lua", "MoltenCodesTest_ClientKit.toc"],
            sorted(path.name for path in client_kit_addon.iterdir()),
        )
        toc = (client_kit_addon / "MoltenCodesTest_ClientKit.toc").read_text(encoding="utf-8")
        self.assertIn("## Dependencies: MoltenCodesTest\n", toc)
        self.assertIn("\nClientKitSuite.lua\n", toc)
        # The manifest and shim suites read these fields back from the client.
        for field in (
            "## Version: 1.0.0\n",
            "## Author: MoltenCodes\n",
            "## Notes-enUS: ",
            "## Title-deDE: ",
            "## X-MoltenCodes-Probe: yes\n",
        ):
            with self.subTest(field=field):
                self.assertIn(field, toc)
        self.assertTrue((self.addons / "MoltenCodes" / "clientKit" / "ClientKit.lua").is_file())
        self.assertTrue((self.addons / "MoltenCodesTest" / "Harness.lua").is_file())
        self.assertFalse((self.addons / "MoltenCodesTest_Registry").exists())
        self.assertIn(str(client_kit_addon), output)
        self.assert_neighbour_untouched()

    def test_installs_several_test_addons_in_one_command(self):
        status, _, errors = self.run_command("--package", "registry", "--package", "signalKit")

        self.assertEqual(0, status, errors)
        self.assertTrue((self.addons / "MoltenCodesTest_Registry" / "RegistrySuite.lua").is_file())
        self.assertTrue((self.addons / "MoltenCodesTest_SignalKit" / "SignalKitSuite.lua").is_file())

    def test_registry_signalkit_eventkit_and_lifecyclekit_are_packages_with_a_test_addon(self):
        manifests, _ = load_manifests()

        available = module.available_test_packages(manifests)

        self.assertIn("registry", available)
        self.assertIn("signalKit", available)
        self.assertIn("eventKit", available)
        self.assertIn("lifecycleKit", available)
        self.assertIn("timerKit", available)
        self.assertIn("moduleKit", available)
        self.assertIn("schedulerKit", available)
        self.assertIn("poolKit", available)
        self.assertIn("cacheKit", available)
        self.assertIn("clientKit", available)
        self.assertIn("profileKit", available)
        self.assertIn("readinessKit", available)
        self.assertIn("schemaKit", available)
        self.assertIn("localeKit", available)
        self.assertIn("hookKit", available)
        self.assertIn("settingsKit", available)
        self.assertIn("optionsKit", available)
        self.assertIn("commandKit", available)
        self.assertIn("codecKit", available)
        self.assertIn("commKit", available)
        self.assertNotIn("widgetKit", available)

    def test_expected_lua_lists_every_bundled_package_and_testkit_at_their_manifest_revisions(self):
        self.run_command("--package", "registry")

        text = (self.addons / "MoltenCodesTest" / "Expected.lua").read_text(encoding="utf-8")
        manifests, _ = load_manifests()
        for package_id, manifest in manifests.items():
            with self.subTest(package=package_id):
                self.assertIn(
                    f'{{ id = "{package_id}", api = {manifest["api"]}, '
                    f'revision = {manifest["revision"]}, ',
                    text,
                )
        self.assertIn('id = "testKit"', text)
        self.assertIn("bundled = false", text)

    def test_expected_lua_is_valid_lua_when_luac_is_available(self):
        luac = shutil.which("luac")
        if luac is None:
            self.skipTest("luac is not on PATH")
        self.run_command("--package", "registry")

        result = subprocess.run(
            [luac, "-p", str(self.addons / "MoltenCodesTest" / "Expected.lua")],
            capture_output=True,
            text=True,
            check=False,
        )
        self.assertEqual(0, result.returncode, result.stderr)

    def test_replaces_earlier_copies_of_exactly_its_own_folders(self):
        stale = self.addons / "MoltenCodes" / "stale.lua"
        stale.parent.mkdir()
        stale.write_text("-- old\n", encoding="utf-8")
        other_test_addon = self.addons / "MoltenCodesTest_TimerKit"
        other_test_addon.mkdir()

        status, output, errors = self.run_command("--package", "registry")

        self.assertEqual(0, status, errors)
        self.assertFalse(stale.exists())
        self.assertIn("replaced", output)
        # Only the requested test addons are replaced; others stay until --remove.
        self.assertTrue(other_test_addon.is_dir())
        self.assert_neighbour_untouched()

    def test_refuses_a_package_without_a_test_addon(self):
        status, _, errors = self.run_command("--package", "widgetKit")

        self.assertEqual(1, status)
        self.assertIn("has no test addon", errors)
        self.assertIn("signalKit", errors)
        self.assertFalse((self.addons / "MoltenCodes").exists())

    def test_refuses_an_unknown_package(self):
        status, _, errors = self.run_command("--package", "noSuchKit")

        self.assertEqual(1, status)
        self.assertIn('unknown package "noSuchKit"', errors)

    def test_dry_run_installs_nothing(self):
        status, output, _ = self.run_command("--package", "registry", "--dry-run")

        self.assertEqual(0, status)
        self.assertIn("would install", output)
        self.assertEqual(["SomeoneElsesAddon"], [path.name for path in self.addons.iterdir()])

    def test_refuses_when_the_addons_folder_does_not_exist(self):
        shutil.rmtree(self.flavour / "Interface")

        status, _, errors = self.run_command("--package", "registry")

        self.assertEqual(1, status)
        self.assertIn("does not exist", errors)

    def test_refuses_a_flavour_folder_that_does_not_exist(self):
        status, _, errors = self.run_command("--flavour-dir", "_classic_", "--package", "registry")

        self.assertEqual(1, status)
        self.assertIn("_classic_", errors)


class RemoveTests(FakeClientTests):
    def test_removes_its_addons_and_every_harness_saved_variables_file(self):
        self.run_command("--package", "registry")
        (self.addons / "MoltenCodesTest_EventKit").mkdir()
        account = self.saved_variables("ACCOUNT")
        character = self.saved_variables("ACCOUNT", "Realm", "Character")
        for folder in (account, character):
            (folder / "MoltenCodesTest.lua").write_text("MoltenCodesTestResults = {}\n")
            (folder / "MoltenCodesTest.lua.bak").write_text("MoltenCodesTestResults = {}\n")
            (folder / "MoltenCodesTest_SettingsKit.lua").write_text("MoltenCodesTest_SettingsKitDB = {}\n")
            (folder / "MoltenCodesTest_SettingsKit.lua.bak").write_text("x = 1\n")
            (folder / "SomeoneElsesAddon.lua").write_text("Other = {}\n")

        status, output, errors = self.run_command("--remove")

        self.assertEqual(0, status, errors)
        self.assertEqual(["SomeoneElsesAddon"], [path.name for path in self.addons.iterdir()])
        for folder in (account, character):
            self.assertEqual(["SomeoneElsesAddon.lua"], [path.name for path in folder.iterdir()])
        self.assertEqual(12, output.count("removed "))

    def test_dry_run_prints_what_would_be_removed_and_removes_nothing(self):
        (self.addons / "MoltenCodes").mkdir()
        account = self.saved_variables("ACCOUNT")
        (account / "MoltenCodesTest.lua").write_text("MoltenCodesTestResults = {}\n")

        status, output, _ = self.run_command("--remove", "--dry-run")

        self.assertEqual(0, status)
        self.assertIn(f"would remove {self.addons / 'MoltenCodes'}", output)
        self.assertIn(f"would remove {account / 'MoltenCodesTest.lua'}", output)
        self.assertTrue((self.addons / "MoltenCodes").is_dir())
        self.assertTrue((account / "MoltenCodesTest.lua").is_file())

    def test_never_follows_a_link_out_of_the_game_folder(self):
        outside = self.base / "outside"
        outside_addon = outside / "addon"
        outside_addon.mkdir(parents=True)
        (outside_addon / "keep.lua").write_text("-- keep\n")
        (self.addons / "MoltenCodesTest_Linked").symlink_to(outside_addon, target_is_directory=True)

        outside_account = outside / "account"
        (outside_account / "SavedVariables").mkdir(parents=True)
        (outside_account / "SavedVariables" / "MoltenCodesTest.lua").write_text("x = 1\n")
        accounts = self.flavour / "WTF" / "Account"
        accounts.mkdir(parents=True)
        (accounts / "LINKED").symlink_to(outside_account, target_is_directory=True)

        status, output, errors = self.run_command("--remove")

        self.assertEqual(0, status, errors)
        self.assertFalse((self.addons / "MoltenCodesTest_Linked").is_symlink())
        self.assertTrue((outside_addon / "keep.lua").is_file())
        self.assertTrue((outside_account / "SavedVariables" / "MoltenCodesTest.lua").is_file())
        self.assertIn("skipped", output)
        self.assert_neighbour_untouched()

    def test_reports_when_there_is_nothing_to_remove(self):
        status, output, _ = self.run_command("--remove")

        self.assertEqual(0, status)
        self.assertIn("nothing to remove", output)
        self.assert_neighbour_untouched()

    def test_refuses_when_the_addons_folder_does_not_exist(self):
        shutil.rmtree(self.flavour / "Interface")
        account = self.saved_variables("ACCOUNT")
        (account / "MoltenCodesTest.lua").write_text("x = 1\n")

        status, _, errors = self.run_command("--remove")

        self.assertEqual(1, status)
        self.assertIn("does not exist", errors)
        self.assertTrue((account / "MoltenCodesTest.lua").is_file())


class CommandLineTests(unittest.TestCase):
    def test_install_and_remove_are_mutually_exclusive(self):
        with contextlib.redirect_stderr(io.StringIO()), self.assertRaises(SystemExit):
            module.parse_args(["--wow-dir", "x", "--package", "registry", "--remove"])

    def test_one_of_install_or_remove_is_required(self):
        with contextlib.redirect_stderr(io.StringIO()), self.assertRaises(SystemExit):
            module.parse_args(["--wow-dir", "x"])

    def test_packages_accumulate(self):
        args = module.parse_args(
            ["--wow-dir", "x", "--package", "registry", "--package", "signalKit"]
        )
        self.assertEqual(["registry", "signalKit"], args.packages)
        self.assertEqual("_retail_", args.flavour_dir)


if __name__ == "__main__":
    unittest.main()
