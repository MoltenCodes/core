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
        self.original_root = module.ROOT
        self.original_packages = module.PACKAGES
        module.ROOT = self.root
        module.PACKAGES = self.packages

    def tearDown(self):
        module.ROOT = self.original_root
        module.PACKAGES = self.original_packages
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

        with (
            mock.patch.object(module.shutil, "which", return_value="/fake/selene"),
            mock.patch.object(
                module.subprocess, "run", return_value=SimpleNamespace(returncode=0)
            ) as run_process,
        ):
            result = module.run()

        self.assertEqual(0, result)
        command = run_process.call_args.args[0]
        self.assertEqual("/fake/selene", command[0])
        self.assertIn("packages/eventKit/src/EventKit.lua", command)
        self.assertIn("packages/eventKit/src/internal/Dispatcher.lua", command)


if __name__ == "__main__":
    unittest.main()
