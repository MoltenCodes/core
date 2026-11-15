"""Tests for `tooling.docs.split_roadmap`, which moves ROADMAP's records into one file per package."""

from __future__ import annotations

import tempfile
import unittest
from pathlib import Path

from tooling.docs import split_roadmap

FACADES = {"TimerKit": "timerKit", "SettingsKit": "settingsKit"}
PACKAGES = {"timerKit", "settingsKit", "registry"}


def record(title: str, kind: str, status: str = "implemented 2026-11-15; tests") -> str:
    points = "".join(f"{number}. Point {number}.\n" for number in range(1, 9))
    return f"**{title}** — {kind}\n\n{points}9. Status: {status}.\n"


ROADMAP = (
    "# Roadmap\n\nIntro prose.\n\n## Phase 1\n\nBefore the records.\n\n"
    + record("timerKit", "facade `TimerKit`")
    + "\n"
    + record("settingsKit views", "a change to facade `SettingsKit`", "recorded 2026-11-15; code follows")
    + "\nAn appendix of the settingsKit record.\n\n---\n\nBetween two runs.\n\n"
    + record("Lua limits gate", "repository tooling, no facade")
    + "\n## Phase 2\n\nAfter.\n"
)


class SplitTests(unittest.TestCase):
    def setUp(self):
        self.result = split_roadmap.split(ROADMAP, FACADES, PACKAGES)

    def test_records_go_to_the_package_their_kind_or_title_names(self):
        self.assertEqual(
            ["timerKit", "settingsKit", "tooling"],
            [item.package for item in self.result.records],
        )

    def test_an_appendix_travels_with_its_record(self):
        self.assertIn("An appendix of the settingsKit record.", self.result.files["settingsKit"])
        self.assertNotIn("An appendix", self.result.roadmap)

    def test_record_text_moves_byte_for_byte(self):
        for item in self.result.records:
            self.assertIn(item.text, self.result.files[item.package])
        self.assertNotIn("Point 3.", self.result.roadmap)

    def test_every_other_line_of_the_roadmap_stays_in_order(self):
        kept = [line for line in self.result.roadmap.splitlines() if not line.startswith("|")]
        expected = [
            "# Roadmap",
            "Intro prose.",
            "## Phase 1",
            "Before the records.",
            "---",
            "Between two runs.",
            "## Phase 2",
            "After.",
        ]
        self.assertEqual(expected, [line for line in kept if line.strip()])

    def test_each_run_of_records_becomes_one_table(self):
        tables = self.result.roadmap.count("| Record | Package | Status |")
        self.assertEqual(2, tables)
        self.assertIn(
            "| [settingsKit views](records/settingsKit.md#settingskit-views) | `settingsKit` | "
            "recorded 2026-11-15 |",
            self.result.roadmap,
        )

    def test_a_record_file_names_its_section_and_gives_each_record_a_heading(self):
        text = self.result.files["timerKit"]
        self.assertTrue(text.startswith("# timerKit records\n"))
        self.assertIn("Moved from `docs/ROADMAP.md` (Phase 1).", text)
        self.assertIn("## timerKit\n", text)

    def test_a_record_nobody_owns_stops_the_split(self):
        text = ROADMAP + record("A mystery", "something else")
        with self.assertRaisesRegex(split_roadmap.SplitError, 'cannot tell whose record "A mystery"'):
            split_roadmap.split(text, FACADES, PACKAGES)


class CheckTests(unittest.TestCase):
    def setUp(self):
        directory = tempfile.TemporaryDirectory()
        self.addCleanup(directory.cleanup)
        self.root = Path(directory.name)
        (self.root / "docs" / "records").mkdir(parents=True)

    def test_nothing_to_check_before_the_split(self):
        self.assertEqual([], split_roadmap.check_records(Path(tempfile.mkdtemp())))

    def test_unlinked_files_and_incomplete_records_are_reported(self):
        (self.root / "docs" / "ROADMAP.md").write_text("see records/timerKit.md\n", encoding="utf-8")
        (self.root / "docs" / "records" / "timerKit.md").write_text(
            record("timerKit", "facade `TimerKit`"), encoding="utf-8"
        )
        broken = record("settingsKit", "facade `SettingsKit`").replace("4. Point 4.\n", "")
        (self.root / "docs" / "records" / "settingsKit.md").write_text(broken, encoding="utf-8")

        problems = split_roadmap.check_records(self.root)

        self.assertIn("docs/ROADMAP.md: does not link records/settingsKit.md", problems)
        self.assertTrue(any("lacks point(s) 4" in item for item in problems))
        self.assertEqual(2, len(problems))


class RepositoryTests(unittest.TestCase):
    def test_the_records_are_split_and_hold_together(self):
        root = split_roadmap.ROOT
        self.assertEqual([], split_roadmap.check_records(root))
        records = [
            record
            for path in sorted((root / split_roadmap.RECORDS_DIRECTORY).glob("*.md"))
            for record in split_roadmap.find_records(path.read_text(encoding="utf-8").splitlines(keepends=True))
        ]
        self.assertGreater(len(records), 50)
        roadmap = (root / split_roadmap.ROADMAP_PATH).read_text(encoding="utf-8")
        self.assertEqual([], split_roadmap.find_records(roadmap.splitlines(keepends=True)))

if __name__ == "__main__":
    unittest.main()
