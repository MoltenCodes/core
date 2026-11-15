"""Tests for `tooling.client.session`: prepare, collect and clean one client session."""

from __future__ import annotations

import contextlib
import io
import tempfile
import unittest
from pathlib import Path
from unittest import mock

from tooling.client import install, report, session

EXPECTED_MD = """# FixtureKit

**Before the run.** Be in a party of two
with Blizzard's party frames.

## After `/mct run fixtureKit`

```text
MoltenCodes Test: fixtureKit: 4 passed, 0 failed, 1 skipped, 0 timed out (5 tests)
```

## Combat run

Stand at a training dummy.

## Per flavour

Classic Era skips one more.
"""

SUITE_LUA = """local clicks = Harness:Suite(PACKAGE_ID, "clicks", addonName, {
  interactive = "right-click your own unit frame",
})
"""


def row(mode: str, passed: int, skipped: int = 1, tests: int = 5) -> report.Row:
    return report.Row("retail", "fixtureKit", mode, tests, passed, 0, skipped, 0)


class ReadingTests(unittest.TestCase):
    def setUp(self):
        directory = tempfile.TemporaryDirectory()
        self.addCleanup(directory.cleanup)
        self.suite = Path(directory.name) / "MoltenCodesTest_FixtureKit"
        self.suite.mkdir()
        (self.suite / "EXPECTED.md").write_text(EXPECTED_MD, encoding="utf-8")
        (self.suite / "FixtureKitSuite.lua").write_text(SUITE_LUA, encoding="utf-8")

    def test_expected_totals_preconditions_and_interactive_suites_are_read(self):
        expected = session.read_expected("fixtureKit", self.suite)
        self.assertEqual((5, 4, 0, 1, 0), expected.totals())
        self.assertEqual(
            (
                "Before the run: Be in a party of two with Blizzard's party frames.",
                "Combat run: Stand at a training dummy.",
                "Per flavour: Classic Era skips one more.",
            ),
            expected.preconditions,
        )
        self.assertEqual(("fixtureKit.clicks: right-click your own unit frame",), expected.interactive)

    def test_a_suite_registered_through_a_wrapper_is_read_too(self):
        (self.suite / "FixtureKitSuite.lua").write_text(
            'local party = newSuite("party", {\n  interactive = "be in a party of two",\n})\n',
            encoding="utf-8",
        )
        expected = session.read_expected("fixtureKit", self.suite)
        self.assertEqual(("fixtureKit.party: be in a party of two",), expected.interactive)

    def test_the_committed_interactive_suites(self):
        found = sorted(
            item for expected in session.expected_by_package().values() for item in expected.interactive
        )
        self.assertEqual(
            ["editModeKit.editMode", "menuKit.extensions", "rangeKit.player", "unitFrameKit.party"],
            [item.split(":", 1)[0] for item in found],
        )

    def test_a_suite_without_a_totals_line_is_left_out(self):
        (self.suite / "EXPECTED.md").write_text("# nothing\n", encoding="utf-8")
        self.assertIsNone(session.read_expected("fixtureKit", self.suite))

    def test_the_sheet_lists_steps_preconditions_interactive_suites_and_totals(self):
        sheet = session.render_sheet(
            {"fixtureKit": session.read_expected("fixtureKit", self.suite)}, "_retail_"
        )
        lines = sheet.splitlines()
        self.assertEqual("MoltenCodes client session for _retail_", lines[0])
        self.assertIn("1. /mct run all", sheet)
        self.assertLess(sheet.index("/mct run all"), sheet.index("/mct run guided"))
        self.assertLess(sheet.index("/mct run guided"), sheet.index("/mct run combat"))
        self.assertIn("  - fixtureKit: Combat run: Stand at a training dummy.", lines)
        self.assertIn("  - fixtureKit.clicks: right-click your own unit frame", lines)
        self.assertIn("  fixtureKit: 4 passed, 0 failed, 1 skipped, 0 timed out (5 tests)", lines)

    def test_every_committed_suite_has_a_readable_totals_line(self):
        self.assertEqual(41, len(session.expected_by_package()))


class CompareTests(unittest.TestCase):
    def setUp(self):
        self.expected = {
            "fixtureKit": session.Expected("fixtureKit", 5, 4, 0, 1, 0, (), ()),
        }

    def test_as_expected(self):
        self.assertEqual(
            ["fixtureKit: as expected (5 tests)"],
            session.compare(self.expected, [row("default", 4)], "retail"),
        )

    def test_unattended_and_guided_runs_are_summed(self):
        rows = [row("unattended", 3, skipped=1, tests=4), row("guided", 1, skipped=0, tests=1)]
        self.assertEqual(
            ["fixtureKit: as expected (5 tests)"], session.compare(self.expected, rows, "retail")
        )

    def test_differs_names_both_totals(self):
        lines = session.compare(self.expected, [row("default", 3)], "retail")
        self.assertEqual(
            [
                "fixtureKit: differs: expected 5 tests: 4 passed, 0 failed, 1 skipped, 0 timed out, "
                "recorded 5 tests: 3 passed, 0 failed, 1 skipped, 0 timed out"
            ],
            lines,
        )

    def test_not_run_and_other_flavours_ignored(self):
        self.assertEqual(
            ["fixtureKit: not run"],
            session.compare(self.expected, [row("default", 4)], "classic-era"),
        )

    def test_flavour_folders(self):
        self.assertEqual("classic-mop", session.flavour_id("_classic_"))
        with self.assertRaises(session.SessionError):
            session.flavour_id("_nope_")


class CleanTests(unittest.TestCase):
    def setUp(self):
        directory = tempfile.TemporaryDirectory()
        self.addCleanup(directory.cleanup)
        flavour = Path(directory.name) / "_retail_"
        addons = flavour / "Interface" / "AddOns"
        (addons / install.HARNESS_ADDON).mkdir(parents=True)
        (addons / install.HARNESS_ADDON / install.EXPECTED_FILE_NAME).write_text(
            '  installedAt = "2026-11-15T20:00:00Z",\n', encoding="utf-8"
        )
        self.layout = install.ClientLayout(Path(directory.name), flavour, addons)
        (flavour / session.SHEET_NAME).write_text("sheet", encoding="utf-8")

    def test_clean_refuses_an_uncollected_installation(self):
        with mock.patch.object(install, "remove") as remove:
            with self.assertRaisesRegex(session.SessionError, "has not been collected"):
                session.clean(self.layout, say=lambda text: None)
        remove.assert_not_called()

    def test_clean_after_collect_removes_the_installation_sheet_and_marker(self):
        (self.layout.flavour_dir / session.COLLECTED_NAME).write_text(
            "2026-11-15T20:00:00Z\n", encoding="utf-8"
        )
        with mock.patch.object(install, "remove") as remove:
            session.clean(self.layout, say=lambda text: None)
        remove.assert_called_once()
        self.assertFalse((self.layout.flavour_dir / session.SHEET_NAME).exists())
        self.assertFalse((self.layout.flavour_dir / session.COLLECTED_NAME).exists())

    def test_force_overrides_and_says_what_is_lost(self):
        said: list[str] = []
        with mock.patch.object(install, "remove"):
            session.clean(self.layout, force=True, say=said.append)
        self.assertIn("deleted unrecorded", said[0])

    def test_the_installed_time_is_read_from_expected_lua(self):
        self.assertEqual("2026-11-15T20:00:00Z", session.installed_at(self.layout))


class PrepareTests(unittest.TestCase):
    def test_a_dry_run_prepare_prints_the_sheet_and_writes_nothing(self):
        with tempfile.TemporaryDirectory() as directory:
            addons = Path(directory) / "_retail_" / "Interface" / "AddOns"
            addons.mkdir(parents=True)
            output = io.StringIO()
            with contextlib.redirect_stdout(output):
                status = session.main(
                    ["prepare", "--wow-dir", directory, "--packages", "registry", "--dry-run"]
                )
            self.assertEqual(0, status)
            self.assertIn("MoltenCodes client session for _retail_", output.getvalue())
            self.assertFalse((Path(directory) / "_retail_" / session.SHEET_NAME).exists())
            self.assertEqual([], list(addons.iterdir()))


if __name__ == "__main__":
    unittest.main()
