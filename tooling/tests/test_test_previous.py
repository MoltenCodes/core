"""Tests for `tooling.test.previous`, the previous revision the conformance suite upgrades from.

Git is replaced by a fake history, so the tests need no repository of their own.
"""

from __future__ import annotations

import json
import tempfile
import unittest
from pathlib import Path
from unittest import mock

from tooling.test import previous


class FakeHistory:
    """Answers the read-only git commands `previous` runs, from a dict of commits."""

    def __init__(self, commits: dict[str, dict[str, str]]):
        # Newest first, as `git log` lists them.
        self.commits = commits

    def __call__(self, arguments: list[str], root: Path) -> str | None:
        command = arguments[0]
        if command == "log":
            return "\n".join(self.commits) + "\n"
        if command == "show":
            commit, path = arguments[1].split(":", 1)
            return self.commits.get(commit, {}).get(path)
        if command == "ls-tree":
            commit, prefix = arguments[3], arguments[4]
            return "\n".join(path for path in self.commits[commit] if path.startswith(prefix))
        return None


def manifest(revision: int) -> str:
    return json.dumps({"name": "fooKit", "revision": revision})


class PreviousRevisionTests(unittest.TestCase):
    def setUp(self):
        directory = tempfile.TemporaryDirectory()
        self.addCleanup(directory.cleanup)
        self.root = Path(directory.name)
        package = self.root / "packages" / "fooKit"
        package.mkdir(parents=True)
        (package / "package.manifest.json").write_text(manifest(3), encoding="utf-8")
        self.history = FakeHistory(
            {
                "c3": {"packages/fooKit/package.manifest.json": manifest(3)},
                "c2": {
                    "packages/fooKit/package.manifest.json": manifest(2),
                    "packages/fooKit/src/FooKit.lua": "-- revision 2\n",
                    "packages/fooKit/src/parts/FooKit-Extra.lua": "-- part\n",
                    "packages/fooKit/src/.luarc.json": "{}",
                },
                "c1": {"packages/fooKit/package.manifest.json": manifest(1)},
            }
        )

    def test_the_newest_commit_one_revision_back_is_found(self):
        with mock.patch.object(previous, "_git", self.history):
            self.assertEqual("c2", previous.find_previous_commit("fooKit", self.root))

    def test_its_facade_and_parts_are_extracted(self):
        destination = self.root / "out"
        with mock.patch.object(previous, "_git", self.history):
            self.assertTrue(previous.extract_previous_revision("fooKit", destination, self.root))
        self.assertEqual("-- revision 2\n", (destination / "FooKit.lua").read_text(encoding="utf-8"))
        self.assertTrue((destination / "FooKit-Extra.lua").is_file())
        self.assertFalse((destination / ".luarc.json").exists())

    def test_nothing_without_history(self):
        with mock.patch.object(previous, "_git", lambda arguments, root: None):
            self.assertIsNone(previous.find_previous_commit("fooKit", self.root))
            self.assertFalse(previous.extract_previous_revision("fooKit", self.root / "out", self.root))

    def test_nothing_for_revision_one(self):
        (self.root / "packages" / "fooKit" / "package.manifest.json").write_text(
            manifest(1), encoding="utf-8"
        )
        with mock.patch.object(previous, "_git", self.history):
            self.assertIsNone(previous.find_previous_commit("fooKit", self.root))


if __name__ == "__main__":
    unittest.main()
