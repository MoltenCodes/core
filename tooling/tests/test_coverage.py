"""Tests for the LuaCov coverage report, `tooling.test.coverage`.

Busted and `luacov` are never started: `test_run.run`, `shutil.which` and
`subprocess.run` are replaced, and the report text is written by the test.
"""

from __future__ import annotations

import io
import tempfile
import unittest
from contextlib import redirect_stderr, redirect_stdout
from pathlib import Path
from unittest import mock

from tooling.test import coverage as module


REPORT = """\
==============================================================================
/root/packages/timerKit/src/TimerKit.lua
==============================================================================
   1 local TimerKit = {}

==============================================================================
Summary
==============================================================================

File                                                 Hits Missed Coverage
-------------------------------------------------------------------------
/root/packages/apiKit/src/ApiKit.lua                 10   0      100.00%
/root/packages/apiKit/src/flavours/Retail.lua        30   10     75.00%
/root/packages/timerKit/src/TimerKit.lua             90   10     90.00%
/root/tests/support/FrameworkTestEnv.lua             5    5      50.00%
-------------------------------------------------------------------------
Total                                                135  25     84.38%
"""


class ParseReportTests(unittest.TestCase):
    def test_rows_are_summed_per_package_and_sorted(self):
        self.assertEqual(
            [
                module.PackageCoverage("apiKit", 40, 10),
                module.PackageCoverage("timerKit", 90, 10),
            ],
            module.parse_report(REPORT),
        )

    def test_a_report_without_a_summary_has_no_rows(self):
        self.assertEqual([], module.parse_report("no summary here\n"))

    def test_windows_separators_are_accepted(self):
        text = "\nSummary\nC:\\root\\packages\\poolKit\\src\\PoolKit.lua 3 1 75.00%\n"

        self.assertEqual([module.PackageCoverage("poolKit", 3, 1)], module.parse_report(text))

    def test_percent_of_nothing_measured_is_zero(self):
        self.assertEqual(0.0, module.PackageCoverage("emptyKit", 0, 0).percent)


class MergeStatisticsTests(unittest.TestCase):
    def test_relative_and_absolute_spellings_are_summed_under_the_absolute_path(self):
        root = Path("/repo")
        text = (
            "3:/repo/packages/registry/src/Registry.lua\n0 2 0\n"
            "4:packages/registry/src/Registry.lua\n1 0 0 5\n"
        )

        merged = module.merge_statistics(text, root)

        self.assertEqual("4:/repo/packages/registry/src/Registry.lua\n1 2 0 5\n", merged)

    def test_distinct_files_stay_apart_in_their_first_order(self):
        root = Path("/repo")
        text = "1:/repo/b.lua\n1\n1:/repo/a.lua\n2\n"

        self.assertEqual("1:/repo/b.lua\n1\n1:/repo/a.lua\n2\n", module.merge_statistics(text, root))

    def test_empty_statistics_stay_empty(self):
        self.assertEqual("", module.merge_statistics("", Path("/repo")))


class RenderMarkdownTests(unittest.TestCase):
    def test_rows_and_total_are_rendered(self):
        rows = module.parse_report(REPORT)

        markdown = module.render_markdown(rows, tests_passed=True)

        self.assertIn("| `apiKit` | 40 | 10 | 80.0% |", markdown)
        self.assertIn("| **total** | 130 | 20 | 86.7% |", markdown)
        self.assertIn("Every suite passed under coverage.", markdown)

    def test_failed_specs_are_explained_rather_than_hidden(self):
        markdown = module.render_markdown([], tests_passed=False)

        self.assertIn("Some specs failed under coverage", markdown)
        self.assertIn("| **total** | 0 | 0 | 0.0% |", markdown)


class RunTests(unittest.TestCase):
    def setUp(self):
        self.tempdir = tempfile.TemporaryDirectory()
        root = Path(self.tempdir.name)
        patches = [
            mock.patch.object(module, "ROOT", root),
            mock.patch.object(module, "STATS_FILE", root / "luacov.stats.out"),
            mock.patch.object(module, "REPORT_FILE", root / "luacov.report.out"),
            mock.patch.object(module.shutil, "which", return_value="/usr/bin/luacov"),
        ]
        for patch in patches:
            patch.start()
            self.addCleanup(patch.stop)
        self.root = root

    def tearDown(self):
        self.tempdir.cleanup()

    def run_module(self, suite_status: int, report: str | None, luacov_status: int = 0, summary=None):
        def fake_luacov(*_args, **_kwargs):
            if report is not None:
                module.REPORT_FILE.write_text(report, encoding="utf-8")
            return mock.Mock(returncode=luacov_status)

        stdout, stderr = io.StringIO(), io.StringIO()
        with mock.patch.object(module.test_run, "run", return_value=suite_status) as suites, \
                mock.patch.object(module.subprocess, "run", side_effect=fake_luacov), \
                redirect_stdout(stdout), redirect_stderr(stderr):
            status = module.run(["timerKit"], summary)
        return status, suites, stdout.getvalue(), stderr.getvalue()

    def test_busted_runs_with_coverage_and_the_table_is_printed(self):
        status, suites, stdout, _ = self.run_module(0, REPORT)

        self.assertEqual(0, status)
        suites.assert_called_once_with(["timerKit"], ["--coverage"])
        self.assertIn("| `timerKit` | 90 | 10 | 90.0% |", stdout)

    def test_failed_specs_do_not_fail_the_report(self):
        status, _, stdout, _ = self.run_module(1, REPORT)

        self.assertEqual(0, status)
        self.assertIn("Some specs failed under coverage", stdout)

    def test_the_summary_file_is_appended_to(self):
        summary = self.root / "summary.md"
        summary.write_text("before\n", encoding="utf-8")

        self.run_module(0, REPORT, summary=str(summary))

        text = summary.read_text(encoding="utf-8")
        self.assertTrue(text.startswith("before\n## Line coverage"))

    def test_statistics_from_an_earlier_run_are_removed_first(self):
        module.STATS_FILE.write_text("stale", encoding="utf-8")

        self.run_module(0, REPORT)

        self.assertFalse(module.STATS_FILE.exists())

    def test_the_statistics_are_merged_before_luacov_reports(self):
        def run_suites(*_args):
            module.STATS_FILE.write_text(
                "1:packages/timerKit/src/TimerKit.lua\n1\n"
                f"1:{self.root}/packages/timerKit/src/TimerKit.lua\n2\n",
                encoding="utf-8",
            )
            return 0

        with mock.patch.object(module.test_run, "run", side_effect=run_suites), \
                mock.patch.object(module.subprocess, "run", return_value=mock.Mock(returncode=1)), \
                redirect_stdout(io.StringIO()), redirect_stderr(io.StringIO()):
            module.run([], None)

        self.assertEqual(
            f"1:{self.root.resolve()}/packages/timerKit/src/TimerKit.lua\n3\n",
            module.STATS_FILE.read_text(encoding="utf-8"),
        )

    def test_a_missing_luacov_is_reported(self):
        with mock.patch.object(module.shutil, "which", return_value=None), \
                redirect_stderr(io.StringIO()) as stderr:
            self.assertEqual(127, module.run([], None))
        self.assertIn("luarocks install luacov", stderr.getvalue())

    def test_a_setup_failure_of_the_runner_is_passed_on(self):
        status, _, _, _ = self.run_module(127, REPORT)

        self.assertEqual(127, status)

    def test_a_failed_luacov_is_an_error(self):
        status, _, _, stderr = self.run_module(0, None, luacov_status=1)

        self.assertEqual(1, status)
        self.assertIn("did not write luacov.report.out", stderr)

    def test_a_report_without_package_rows_is_an_error(self):
        status, _, _, stderr = self.run_module(0, "\nSummary\nTotal 0 0 0.00%\n")

        self.assertEqual(1, status)
        self.assertIn("no package rows", stderr)


if __name__ == "__main__":
    unittest.main()
