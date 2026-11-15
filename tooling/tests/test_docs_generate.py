"""Tests for `tooling.docs.generate`, the package lists rendered from the manifests."""

from __future__ import annotations

import contextlib
import io
import tempfile
import unittest
from pathlib import Path
from unittest import mock

from tooling.docs import generate
from tooling.validation import validate_manifests

MANIFESTS = {
    "timerKit": {"displayName": "TimerKit", "description": "Timers.", "summary": "Timers with scopes."},
    "registry": {"displayName": "Registry", "description": "The registry."},
    "testKit": {
        "displayName": "TestKit",
        "description": "In-client tests.",
        "distribution": "development",
    },
    "commKit": {"displayName": "CommKit", "description": "Messages."},
    "barKit": {"displayName": "BarKit", "description": "Bars."},
}


def packages() -> list[generate.Package]:
    """The fixture manifests in list order."""
    return generate.ordered_packages(MANIFESTS)


class OrderAndTextTests(unittest.TestCase):
    def test_registry_first_then_release_by_name_then_development(self):
        self.assertEqual(
            ["registry", "barKit", "commKit", "timerKit", "testKit"],
            [package.name for package in packages()],
        )

    def test_order_ignores_case(self):
        names = generate.ordered_packages(
            {
                "commandKit": {"displayName": "CommandKit", "description": "a."},
                "commKit": {"displayName": "CommKit", "description": "b."},
            }
        )
        self.assertEqual(["commandKit", "commKit"], [package.name for package in names])

    def test_summary_is_preferred_and_description_is_the_fallback(self):
        purposes = {package.name: package.purpose for package in packages()}
        self.assertEqual("Timers with scopes.", purposes["timerKit"])
        self.assertEqual("Bars.", purposes["barKit"])

    def test_numbers_in_words(self):
        self.assertEqual("one", generate.number_in_words(1))
        self.assertEqual("nineteen", generate.number_in_words(19))
        self.assertEqual("forty", generate.number_in_words(40))
        self.assertEqual("forty-one", generate.number_in_words(41))
        with self.assertRaises(generate.GenerateError):
            generate.number_in_words(100)

    def test_count_sentence(self):
        self.assertEqual(
            "Four release packages and one development package.",
            generate.render_package_count_sentence(packages()),
        )
        only_release = generate.ordered_packages({"barKit": MANIFESTS["barKit"]})
        self.assertEqual(
            "One release package.", generate.render_package_count_sentence(only_release)
        )

    def test_package_table(self):
        text = generate.render_package_table(packages())
        lines = text.splitlines()
        self.assertEqual("| Package | Purpose |", lines[0])
        self.assertEqual("| [`registry`](packages/registry/) | The registry. |", lines[2])
        self.assertEqual("| [`testKit`](packages/testKit/) | In-client tests. |", lines[-1])

    def test_indexes(self):
        self.assertIn(
            "- [`TimerKit`](../packages/timerKit/README.md) — Timers with scopes.\n",
            generate.render_documentation_index(packages()),
        )
        self.assertIn("- [`barKit`](barKit/) — Bars.\n", generate.render_package_index(packages()))

    def test_tree_keeps_the_fence_and_the_future_lines(self):
        lines = generate.render_package_tree(packages()).splitlines()
        self.assertEqual(["```text", "packages/", "├── registry/"], lines[:3])
        self.assertEqual(["├── <future-package>/", "└── ...", "```"], lines[-3:])

    def test_naming_lists_leave_out_registry(self):
        self.assertEqual(
            "`barKit`, `commKit`, `timerKit`, `testKit`", generate.render_package_ids(packages())
        )
        self.assertEqual(
            "`BarKit`, `CommKit`, `TimerKit`, `TestKit`", generate.render_facade_names(packages())
        )

    def test_move_folders_ship_release_packages_only(self):
        text = generate.render_move_folders(packages())
        self.assertIn("  MoltenCodes/packages/barKit/src: MoltenCodes/barKit\n", text)
        self.assertIn("  MoltenCodes/packages/barKit/docs: MoltenCodes/barKit/docs\n", text)
        self.assertNotIn("testKit", text)

    def test_github_lists_name_every_package(self):
        self.assertIn('- name: "kit: testKit"', generate.render_kit_labels(packages()))
        self.assertIn(
            '      - any-glob-to-any-file: "packages/commKit/**"',
            generate.render_kit_labeler(packages()),
        )
        self.assertEqual(
            "        - registry\n        - barKit\n        - commKit\n        - timerKit\n"
            "        - testKit\n",
            generate.render_kit_options(packages()),
        )


class MarkerTests(unittest.TestCase):
    def setUp(self):
        directory = tempfile.TemporaryDirectory()
        self.addCleanup(directory.cleanup)
        self.root = Path(directory.name)
        self.blocks = (
            generate.Block("table", Path("README.md"), "markdown", generate.render_package_table),
            generate.Block("total", Path("README.md"), "inline", generate.render_package_total),
            generate.Block("labels", Path("labels.yml"), "yaml", generate.render_kit_labels),
        )
        patcher = mock.patch.object(generate, "BLOCKS", self.blocks)
        patcher.start()
        self.addCleanup(patcher.stop)

    def write(self, relative: str, text: str) -> Path:
        path = self.root / relative
        path.write_text(text, encoding="utf-8")
        return path

    def test_unmarked_files_fail_while_markers_are_required(self):
        self.write("README.md", "No markers here.\n")
        found = generate.findings(packages(), self.root)
        self.assertEqual({"table", "total"}, {finding.block.name for finding in found})
        self.assertTrue(all(not finding.marked for finding in found))
        errors = generate.stale_block_errors(packages(), self.root)
        self.assertEqual(2, len(errors))
        self.assertIn('has no generated "table" block', errors[0])
        with mock.patch.object(generate, "MARKERS_REQUIRED", False):
            self.assertEqual([], generate.stale_block_errors(packages(), self.root))


    def test_stale_blocks_fail_with_the_replacement(self):
        self.write(
            "README.md",
            "We ship <!-- generated:total -->3<!-- /generated:total --> Kits.\n\n"
            "<!-- generated:table -->\n| old |\n<!-- /generated:table -->\n",
        )
        errors = generate.stale_block_errors(packages(), self.root)
        self.assertEqual(2, len(errors))
        self.assertIn("<!-- generated:total -->5<!-- /generated:total -->", errors[1])
        self.assertIn("| [`barKit`](packages/barKit/) | Bars. |", errors[0])

    def test_write_replaces_only_between_markers(self):
        path = self.write(
            "README.md",
            "Intro.\n\nWe ship <!-- generated:total -->3<!-- /generated:total --> Kits.\n\n"
            "<!-- generated:table -->\n| old |\n<!-- /generated:table -->\n\nOutro.\n",
        )
        labels = self.write(
            "labels.yml",
            "- name: bug\n# generated:labels\n- name: old\n# /generated:labels\n- name: area\n",
        )
        changed = generate.write_blocks(packages(), self.root)

        self.assertEqual({path, labels}, set(changed))
        text = path.read_text(encoding="utf-8")
        self.assertTrue(text.startswith("Intro.\n\nWe ship <!-- generated:total -->5<!--"))
        self.assertTrue(text.endswith("<!-- /generated:table -->\n\nOutro.\n"))
        self.assertEqual(
            [], [finding for finding in generate.findings(packages(), self.root) if finding.marked]
        )
        yaml = labels.read_text(encoding="utf-8")
        self.assertTrue(yaml.startswith("- name: bug\n# generated:labels\n- name: \"kit: registry\""))
        self.assertTrue(yaml.endswith("# /generated:labels\n- name: area\n"))

    def test_write_adds_no_marker(self):
        path = self.write("README.md", "Nothing to generate.\n")
        self.assertEqual([], generate.write_blocks(packages(), self.root))
        self.assertEqual("Nothing to generate.\n", path.read_text(encoding="utf-8"))

    def test_unbalanced_markers_are_refused(self):
        self.write("README.md", "<!-- generated:table -->\n| old |\n")
        with self.assertRaisesRegex(generate.GenerateError, 'unbalanced "table"'):
            generate.findings(packages(), self.root)

    def test_marked_text_indents_yaml_markers_like_the_entries(self):
        block = generate.Block("opts", Path("x.yml"), "yaml", generate.render_kit_options)
        text = generate.marked(block, generate.render_kit_options(packages()))
        self.assertTrue(text.startswith("        # generated:opts\n        - registry\n"))
        self.assertTrue(text.endswith("        # /generated:opts\n"))


class RepositoryTests(unittest.TestCase):
    def test_every_listed_file_carries_its_markers_and_markers_are_required(self):
        self.assertTrue(generate.MARKERS_REQUIRED)
        self.assertEqual([], generate.findings(generate.load_packages()))

    def test_every_marked_block_of_the_repository_is_current(self):
        stale = [finding for finding in generate.findings(generate.load_packages()) if finding.marked]
        self.assertEqual([], [finding.message() for finding in stale])

    def test_print_and_check_commands(self):
        with contextlib.redirect_stdout(io.StringIO()) as printed:
            self.assertEqual(0, generate.main(["--block", "package-total"]))
        self.assertIn("<!-- generated:package-total -->", printed.getvalue())
        with contextlib.redirect_stderr(io.StringIO()):
            self.assertEqual(2, generate.main(["--block", "nonsense"]))


class SummaryFieldTests(unittest.TestCase):
    def test_summary_rules(self):
        self.assertEqual([], validate_manifests.summary_problems({}))
        self.assertEqual([], validate_manifests.summary_problems({"summary": "Good."}))
        self.assertIn(
            '"summary" must be a non-empty string',
            validate_manifests.summary_problems({"summary": " "}),
        )
        self.assertIn(
            '"summary" must end with a full stop',
            validate_manifests.summary_problems({"summary": "No stop"}),
        )
        self.assertTrue(validate_manifests.summary_problems({"summary": "a\nb."}))
        self.assertTrue(validate_manifests.summary_problems({"summary": "a | b."}))
        self.assertTrue(validate_manifests.summary_problems({"summary": "x" * 240 + "."}))


if __name__ == "__main__":
    unittest.main()
