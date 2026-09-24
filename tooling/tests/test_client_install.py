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

    def test_installs_several_test_addons_in_one_command(self):
        status, _, errors = self.run_command("--package", "registry", "--package", "signalKit")

        self.assertEqual(0, status, errors)
        self.assertTrue((self.addons / "MoltenCodesTest_Registry" / "RegistrySuite.lua").is_file())
        self.assertTrue((self.addons / "MoltenCodesTest_SignalKit" / "SignalKitSuite.lua").is_file())

    def test_registry_signalkit_and_eventkit_are_the_packages_with_a_test_addon(self):
        manifests, _ = load_manifests()

        available = module.available_test_packages(manifests)

        self.assertIn("registry", available)
        self.assertIn("signalKit", available)
        self.assertIn("eventKit", available)
        self.assertNotIn("timerKit", available)

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
        status, _, errors = self.run_command("--package", "timerKit")

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
            (folder / "SomeoneElsesAddon.lua").write_text("Other = {}\n")

        status, output, errors = self.run_command("--remove")

        self.assertEqual(0, status, errors)
        self.assertEqual(["SomeoneElsesAddon"], [path.name for path in self.addons.iterdir()])
        for folder in (account, character):
            self.assertEqual(["SomeoneElsesAddon.lua"], [path.name for path in folder.iterdir()])
        self.assertEqual(8, output.count("removed "))

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
