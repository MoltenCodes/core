import json
import os
import tempfile
import unittest
from pathlib import Path
from types import SimpleNamespace
from unittest import mock

from tooling.test import run as module
from tooling.validation import validate_manifests


class TestRunnerTests(unittest.TestCase):
    def setUp(self):
        self.tempdir = tempfile.TemporaryDirectory()
        self.root = Path(self.tempdir.name)
        self.packages = self.root / "packages"
        self.packages.mkdir()

        self.original_runner_root = module.ROOT
        self.original_runner_packages = module.PACKAGES
        self.original_validator_root = validate_manifests.ROOT
        self.original_validator_packages = validate_manifests.PACKAGES

        module.ROOT = self.root
        module.PACKAGES = self.packages
        validate_manifests.ROOT = self.root
        validate_manifests.PACKAGES = self.packages

    def tearDown(self):
        module.ROOT = self.original_runner_root
        module.PACKAGES = self.original_runner_packages
        validate_manifests.ROOT = self.original_validator_root
        validate_manifests.PACKAGES = self.original_validator_packages
        self.tempdir.cleanup()

    def create_package(self, name: str, *, dependencies=None) -> None:
        package = self.packages / name
        (package / "src").mkdir(parents=True)
        (package / "tests" / "support").mkdir(parents=True)
        (package / "tests" / f"{name}_spec.lua").write_text("", encoding="utf-8")
        manifest = {
            "name": name,
            "displayName": name,
            "description": "test",
            "version": "1.0.0",
            "api": 1,
            "revision": 1,
            "dependencies": dependencies or {},
        }
        (package / "package.manifest.json").write_text(
            json.dumps(manifest), encoding="utf-8"
        )

    def test_selects_all_packages_in_deterministic_order(self):
        self.create_package("zetaKit")
        self.create_package("alphaKit")
        manifests, errors = module.load_valid_manifests()
        self.assertEqual([], errors)

        selected, errors = module.select_test_packages([], manifests)

        self.assertEqual([], errors)
        self.assertEqual(["alphaKit", "zetaKit"], selected)

    def test_rejects_unknown_requested_package(self):
        self.create_package("registry")
        manifests, errors = module.load_valid_manifests()
        self.assertEqual([], errors)

        selected, errors = module.select_test_packages(["missing"], manifests)

        self.assertEqual([], selected)
        self.assertTrue(any("unknown package" in error for error in errors))

    def test_resolves_transitive_runtime_dependencies(self):
        self.create_package("baseKit")
        self.create_package("signalKit", dependencies={"baseKit": {"api": 1}})
        self.create_package("eventKit", dependencies={"signalKit": {"api": 1}})
        manifests, errors = module.load_valid_manifests()
        self.assertEqual([], errors)

        packages = module.dependency_closure("eventKit", manifests)

        self.assertEqual(["baseKit", "signalKit", "eventKit"], packages)

    def test_builds_lua_path_for_source_and_support(self):
        self.create_package("registry")

        lua_path = module.build_lua_path(
            ["registry"], ["registry"], inherited="existing-path"
        )

        self.assertIn(str(self.packages / "registry" / "src" / "?.lua"), lua_path)
        self.assertIn(
            str(self.packages / "registry" / "tests" / "support" / "?.lua"),
            lua_path,
        )
        self.assertTrue(lua_path.endswith("existing-path"))

    def test_dependency_test_support_is_not_required(self):
        self.create_package("baseKit")
        self.create_package("eventKit", dependencies={"baseKit": {"api": 1}})

        lua_path = module.build_lua_path(
            ["eventKit", "baseKit"], support_packages=["eventKit"]
        )

        self.assertIn(str(self.packages / "baseKit" / "src" / "?.lua"), lua_path)
        self.assertNotIn(
            str(self.packages / "baseKit" / "tests" / "support" / "?.lua"),
            lua_path,
        )
        self.assertIn(
            str(self.packages / "eventKit" / "tests" / "support" / "?.lua"),
            lua_path,
        )

    def test_preserves_lua_default_path_when_environment_is_unset(self):
        self.create_package("registry")

        lua_path = module.build_lua_path(["registry"], ["registry"])

        self.assertTrue(lua_path.endswith(";;"))

    def test_run_uses_one_busted_process_per_selected_package(self):
        self.create_package("baseKit")
        self.create_package("eventKit", dependencies={"baseKit": {"api": 1}})

        with (
            mock.patch.object(module.shutil, "which", return_value="/fake/busted"),
            mock.patch.object(
                module.subprocess, "run", return_value=SimpleNamespace(returncode=0)
            ) as run_process,
        ):
            result = module.run(["baseKit", "eventKit"])

        self.assertEqual(0, result)
        self.assertEqual(2, run_process.call_count)
        first_command = run_process.call_args_list[0].args[0]
        second_command = run_process.call_args_list[1].args[0]
        self.assertEqual(["/fake/busted", "packages/baseKit/tests"], first_command)
        self.assertEqual(["/fake/busted", "packages/eventKit/tests"], second_command)

        events_env = run_process.call_args_list[1].kwargs["env"]
        self.assertIn(str(self.packages / "eventKit" / "src" / "?.lua"), events_env["LUA_PATH"])
        self.assertIn(str(self.packages / "baseKit" / "src" / "?.lua"), events_env["LUA_PATH"])

    def test_finds_package_test_directory(self):
        self.create_package("registry")

        target, error = module.package_test_target("registry")

        self.assertIsNone(error)
        self.assertEqual(os.path.join("packages", "registry", "tests"), target)


if __name__ == "__main__":
    unittest.main()
