import io
import json
import os
import shutil
import tempfile
import unittest
from contextlib import redirect_stderr
from pathlib import Path
from types import SimpleNamespace
from unittest import mock

import tooling.spell as module


#: Set to 1 to run the tests that download and run the pinned cspell. The CI
#: spell job sets it; a plain `unittest discover` stays offline and fast.
INTEGRATION_ENV = "MOLTENCODES_SPELL_INTEGRATION"


class SpellConfigurationTests(unittest.TestCase):
    def test_globs_come_from_the_repository_configuration(self):
        globs = module.configured_globs()

        self.assertIn("README.md", globs)
        self.assertIn("docs/**/*.md", globs)
        self.assertIn("packages/*/docs/*.md", globs)

    def test_generated_package_documentation_is_ignored(self):
        """apiKit's generated reference and change reports are data, not prose."""
        config = json.loads((module.ROOT / module.CONFIG_NAME).read_text(encoding="utf-8"))

        self.assertIn("packages/*/docs/reference/**", config["ignorePaths"])
        self.assertIn("packages/*/docs/changes/**", config["ignorePaths"])

    def test_configuration_uses_the_project_dictionary(self):
        config = json.loads((module.ROOT / module.CONFIG_NAME).read_text(encoding="utf-8"))
        paths = [definition["path"] for definition in config["dictionaryDefinitions"]]

        self.assertEqual(["./tooling/spell-words.txt"], paths)
        self.assertTrue((module.ROOT / "tooling" / "spell-words.txt").is_file())

    def test_malformed_files_list_is_rejected(self):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            (root / module.CONFIG_NAME).write_text('{"files": "README.md"}', encoding="utf-8")

            with self.assertRaisesRegex(ValueError, "files"):
                module.configured_globs(root)

    def test_project_dictionary_is_sorted_within_each_group(self):
        """Keeps additions reviewable: a new word lands in a predictable place."""
        groups: list[list[str]] = [[]]
        for line in (module.ROOT / "tooling" / "spell-words.txt").read_text().splitlines():
            if line.startswith("#") or not line.strip():
                if groups[-1]:
                    groups.append([])
                continue
            groups[-1].append(line.strip())

        for group in groups:
            self.assertEqual(sorted(group, key=str.lower), group)


class NodeDetectionTests(unittest.TestCase):
    def test_parses_node_version_output(self):
        self.assertEqual((26, 9), module.parse_node_version("v26.9.0\n"))
        self.assertIsNone(module.parse_node_version("not a version"))

    def test_missing_node_is_a_problem(self):
        with mock.patch.object(module.shutil, "which", return_value=None):
            self.assertIn("not found", module.node_problem())

    def test_old_node_is_a_problem(self):
        with (
            mock.patch.object(module.shutil, "which", return_value="/usr/bin/node"),
            mock.patch.object(
                module.subprocess, "run", return_value=SimpleNamespace(stdout="v20.11.0\n")
            ),
        ):
            self.assertIn("older than", module.node_problem())

    def test_supported_node_is_not_a_problem(self):
        major, minor = module.MINIMUM_NODE
        with (
            mock.patch.object(module.shutil, "which", return_value="/usr/bin/node"),
            mock.patch.object(
                module.subprocess,
                "run",
                return_value=SimpleNamespace(stdout=f"v{major}.{minor}.0\n"),
            ),
        ):
            self.assertIsNone(module.node_problem())


class SpellRunTests(unittest.TestCase):
    def test_without_node_the_check_is_skipped_with_a_note(self):
        stderr = io.StringIO()
        with (
            mock.patch.object(module, "node_problem", return_value="Node.js was not found"),
            redirect_stderr(stderr),
        ):
            status = module.run()

        self.assertEqual(0, status)
        self.assertIn("note: Node.js was not found", stderr.getvalue())

    def test_without_node_require_fails(self):
        stderr = io.StringIO()
        with (
            mock.patch.object(module, "node_problem", return_value="Node.js was not found"),
            redirect_stderr(stderr),
        ):
            status = module.run(require=True)

        self.assertNotEqual(0, status)
        self.assertIn("error:", stderr.getvalue())

    def test_runs_the_pinned_cspell_over_the_configured_globs(self):
        with (
            mock.patch.object(module, "node_problem", return_value=None),
            mock.patch.object(
                module.subprocess, "run", return_value=SimpleNamespace(returncode=1)
            ) as run,
        ):
            status = module.run()

        self.assertEqual(1, status)
        command = run.call_args.args[0]
        self.assertIn(f"cspell@{module.CSPELL_VERSION}", command)
        self.assertIn("--no-progress", command)
        self.assertEqual(module.configured_globs(), command[-len(module.configured_globs()) :])
        self.assertEqual(module.ROOT, run.call_args.kwargs["cwd"])

    def test_main_passes_require_through(self):
        with mock.patch.object(module, "run", return_value=0) as run:
            module.main(["--require"])

        run.assert_called_once_with(require=True)


@unittest.skipUnless(
    os.environ.get(INTEGRATION_ENV) == "1", f"set {INTEGRATION_ENV}=1 to run cspell itself"
)
class SpellIntegrationTests(unittest.TestCase):
    """Run the real, pinned cspell against a copy of the configuration."""

    def setUp(self):
        self.tempdir = tempfile.TemporaryDirectory()
        self.root = Path(self.tempdir.name)
        shutil.copy(module.ROOT / module.CONFIG_NAME, self.root / module.CONFIG_NAME)
        (self.root / "tooling").mkdir()
        shutil.copy(
            module.ROOT / "tooling" / "spell-words.txt", self.root / "tooling" / "spell-words.txt"
        )

    def tearDown(self):
        self.tempdir.cleanup()

    def check(self, text: str) -> int:
        (self.root / "README.md").write_text(text, encoding="utf-8")
        with redirect_stderr(io.StringIO()):
            return module.run(require=True, root=self.root)

    def test_a_misspelled_word_fails_the_gate(self):
        self.assertNotEqual(0, self.check("The dispatcher is recieved by every listener.\n"))

    def test_a_project_word_passes(self):
        self.assertEqual(0, self.check("Use `securecallfunction` and read the pkgmeta file.\n"))

    def test_fenced_code_is_not_checked(self):
        self.assertEqual(0, self.check("Example:\n\n```lua\nlocal qzxv = wrdlbrmpft\n```\n"))


if __name__ == "__main__":
    unittest.main()
