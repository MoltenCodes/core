import io
import tempfile
import unittest
from pathlib import Path
from types import SimpleNamespace
from unittest import mock

import tooling.lint as module


class LuaLintDiscoveryTests(unittest.TestCase):
    def setUp(self):
        self.tempdir = tempfile.TemporaryDirectory()
        self.root = Path(self.tempdir.name)
        self.packages = self.root / "packages"
        self.packages.mkdir()
        self.examples = self.root / "examples"
        self.shared_support = self.root / "tests" / "support"
        self.examples.mkdir()
        self.shared_support.mkdir(parents=True)

        self.originals = (
            module.ROOT,
            module.PACKAGES,
            module.EXAMPLES,
            module.SHARED_TEST_SUPPORT,
        )
        module.ROOT = self.root
        module.PACKAGES = self.packages
        module.EXAMPLES = self.examples
        module.SHARED_TEST_SUPPORT = self.shared_support

    def tearDown(self):
        (
            module.ROOT,
            module.PACKAGES,
            module.EXAMPLES,
            module.SHARED_TEST_SUPPORT,
        ) = self.originals
        self.tempdir.cleanup()

    def test_discovers_nested_runtime_lua_files(self):
        nested = self.packages / "eventKit" / "src" / "internal"
        nested.mkdir(parents=True)
        top = self.packages / "eventKit" / "src" / "EventKit.lua"
        child = nested / "Dispatcher.lua"
        top.write_text("", encoding="utf-8")
        child.write_text("", encoding="utf-8")
        (nested / "notes.txt").write_text("", encoding="utf-8")

        files = module.discover_runtime_lua_files()

        self.assertEqual([top, child], files)

    def test_run_invokes_selene_with_every_runtime_lua_file(self):
        source = self.packages / "eventKit" / "src"
        source.mkdir(parents=True)
        first = source / "EventKit.lua"
        second = source / "internal" / "Dispatcher.lua"
        second.parent.mkdir()
        first.write_text("", encoding="utf-8")
        second.write_text("", encoding="utf-8")
        # The test scope must discover something too, otherwise `run` refuses
        # before it reaches Selene.
        (self.shared_support / "FrameworkTestEnv.lua").write_text("", encoding="utf-8")

        with (
            mock.patch.object(module.shutil, "which", return_value="/fake/selene"),
            mock.patch.object(
                module.subprocess, "run", return_value=SimpleNamespace(returncode=0)
            ) as run_process,
            mock.patch("sys.stdout", io.StringIO()),
        ):
            result = module.run()

        self.assertEqual(0, result)
        command = run_process.call_args_list[0].args[0]
        self.assertEqual("/fake/selene", command[0])
        self.assertIn("packages/eventKit/src/EventKit.lua", command)
        self.assertIn("packages/eventKit/src/internal/Dispatcher.lua", command)


class LintScopeTests(unittest.TestCase):
    """Runtime and test Lua are discovered separately and judged separately."""

    def setUp(self):
        self.tempdir = tempfile.TemporaryDirectory()
        self.root = Path(self.tempdir.name)
        self.packages = self.root / "packages"
        self.examples = self.root / "examples"
        self.shared_support = self.root / "tests" / "support"
        self.packages.mkdir()
        (self.examples / "tests").mkdir(parents=True)
        self.shared_support.mkdir(parents=True)

        self.originals = (
            module.ROOT,
            module.PACKAGES,
            module.EXAMPLES,
            module.SHARED_TEST_SUPPORT,
        )
        module.ROOT = self.root
        module.PACKAGES = self.packages
        module.EXAMPLES = self.examples
        module.SHARED_TEST_SUPPORT = self.shared_support

    def tearDown(self):
        (
            module.ROOT,
            module.PACKAGES,
            module.EXAMPLES,
            module.SHARED_TEST_SUPPORT,
        ) = self.originals
        self.tempdir.cleanup()

    def create_tree(self):
        source = self.packages / "eventKit" / "src"
        tests = self.packages / "eventKit" / "tests" / "support"
        source.mkdir(parents=True)
        tests.mkdir(parents=True)
        self.runtime = source / "EventKit.lua"
        self.spec = tests.parent / "EventKit_spec.lua"
        self.package_support = tests / "EventKitTestEnv.lua"
        self.example_source = self.examples / "Core.lua"
        self.example_spec = self.examples / "tests" / "ExampleAddon_spec.lua"
        self.fixture = self.shared_support / "FrameworkTestEnv.lua"
        for path in (
            self.runtime,
            self.spec,
            self.package_support,
            self.example_source,
            self.example_spec,
            self.fixture,
        ):
            path.write_text("", encoding="utf-8")

    def test_runtime_scope_holds_the_example_addon_source(self):
        self.create_tree()

        files = module.discover_runtime_lua_files()

        self.assertIn(self.runtime, files)
        self.assertIn(self.example_source, files)
        self.assertNotIn(self.spec, files)
        self.assertNotIn(self.example_spec, files)

    def test_test_scope_holds_specs_support_and_the_shared_fixture(self):
        self.create_tree()

        files = module.discover_test_lua_files()

        self.assertIn(self.spec, files)
        self.assertIn(self.package_support, files)
        self.assertIn(self.example_spec, files)
        self.assertIn(self.fixture, files)
        self.assertNotIn(self.runtime, files)
        self.assertNotIn(self.example_source, files)

    def test_test_scope_selects_the_busted_configuration(self):
        self.create_tree()

        scopes, errors = module.discover_scopes()

        self.assertEqual([], errors)
        runtime, tests = scopes
        self.assertIsNone(runtime.config)
        self.assertEqual(module.TEST_CONFIG, tests.config)
        self.assertEqual(
            ["--config", module.TEST_CONFIG], tests.command_arguments()[:2]
        )

    def test_reports_an_empty_scope_instead_of_linting_nothing(self):
        scopes, errors = module.discover_scopes()

        self.assertEqual(2, len(scopes))
        self.assertEqual(
            ["no runtime Lua files were discovered", "no test Lua files were discovered"],
            errors,
        )

    def test_runs_both_scopes_even_when_the_first_one_fails(self):
        self.create_tree()

        with (
            mock.patch.object(module.shutil, "which", return_value="/fake/selene"),
            mock.patch.object(
                module.subprocess,
                "run",
                side_effect=[SimpleNamespace(returncode=1), SimpleNamespace(returncode=0)],
            ) as run_process,
            mock.patch("sys.stdout", io.StringIO()),
        ):
            status = module.run()

        self.assertEqual(1, status)
        self.assertEqual(2, run_process.call_count)


if __name__ == "__main__":
    unittest.main()
