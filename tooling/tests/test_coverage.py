"""Tests for the LuaCov coverage report, `tooling.test.coverage`.

Busted and `luacov` are never started: `test_run.run`, `shutil.which` and
`subprocess.run` are replaced, and the report text and the floors file are
written by the test.
"""

from __future__ import annotations

import io
import json
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


class WholePercentTests(unittest.TestCase):
    def test_the_percentage_is_rounded_down(self):
        self.assertEqual(66, module.PackageCoverage("kit", 2, 1).whole_percent)
        self.assertEqual(99, module.PackageCoverage("kit", 999, 1).whole_percent)

    def test_full_coverage_is_exactly_one_hundred(self):
        self.assertEqual(100, module.PackageCoverage("kit", 57, 0).whole_percent)

    def test_nothing_measured_is_zero(self):
        self.assertEqual(0, module.PackageCoverage("kit", 0, 0).whole_percent)

    def test_a_floor_is_met_at_or_above_it_and_missed_below_it(self):
        row = module.PackageCoverage("kit", 2, 1)

        self.assertTrue(row.meets(66))
        self.assertFalse(row.meets(67))
        self.assertTrue(module.PackageCoverage("kit", 50, 50).meets(50))


class LoadFloorsTests(unittest.TestCase):
    def setUp(self):
        self.tempdir = tempfile.TemporaryDirectory()
        self.addCleanup(self.tempdir.cleanup)
        self.path = Path(self.tempdir.name) / "coverage-floors.json"

    def load(self, text: str) -> dict[str, int]:
        self.path.write_text(text, encoding="utf-8")
        return module.load_floors(self.path)

    def test_floors_are_read_as_a_package_to_percent_map(self):
        self.assertEqual({"apiKit": 80, "timerKit": 100}, self.load('{"apiKit": 80, "timerKit": 100}'))

    def test_a_missing_file_is_an_error(self):
        with self.assertRaisesRegex(module.FloorsError, "does not exist"):
            module.load_floors(self.path)

    def test_invalid_json_is_an_error(self):
        with self.assertRaises(module.FloorsError):
            self.load("{not json")

    def test_a_non_object_is_an_error(self):
        with self.assertRaisesRegex(module.FloorsError, "JSON object"):
            self.load("[80]")

    def test_non_whole_or_out_of_range_floors_are_errors(self):
        for value in ("80.5", "-1", "101", '"80"', "true", "null"):
            with self.subTest(value=value), self.assertRaisesRegex(module.FloorsError, "apiKit"):
                self.load(f'{{"apiKit": {value}}}')

    def test_written_floors_are_sorted_and_read_back(self):
        module.write_floors(self.path, {"timerKit": 90, "apiKit": 80})

        self.assertEqual('{\n  "apiKit": 80,\n  "timerKit": 90\n}\n', self.path.read_text(encoding="utf-8"))
        self.assertEqual({"apiKit": 80, "timerKit": 90}, module.load_floors(self.path))

    def test_the_committed_floors_file_is_valid_and_sorted(self):
        floors = module.load_floors(module.FLOORS_FILE)

        self.assertEqual(sorted(floors), list(floors))
        manifests = sorted(path.parent.name for path in module.ROOT.glob("packages/*/package.manifest.json"))
        self.assertEqual(manifests, list(floors))


class CheckFloorsTests(unittest.TestCase):
    ROWS = [
        module.PackageCoverage("apiKit", 80, 20),
        module.PackageCoverage("timerKit", 90, 10),
    ]

    def failures(self, floors: dict[str, int], full_run: bool = True) -> list[str]:
        verdicts = module.check_floors(self.ROWS, floors, full_run)
        return [verdict.message for verdict in verdicts if not verdict.passed]

    def test_packages_at_or_above_their_floor_pass(self):
        self.assertEqual([], self.failures({"apiKit": 80, "timerKit": 85}))

    def test_a_package_below_its_floor_fails(self):
        self.assertEqual(
            ["apiKit: 80.0% is below its floor of 81%"], self.failures({"apiKit": 81, "timerKit": 90})
        )

    def test_a_package_without_a_floor_fails(self):
        self.assertEqual(["timerKit: no coverage floor"], self.failures({"apiKit": 80}))

    def test_a_floor_without_a_measurement_fails_a_full_run(self):
        floors = {"apiKit": 80, "timerKit": 90, "goneKit": 50}

        self.assertEqual(["goneKit: has a floor but no line of it was measured"], self.failures(floors))

    def test_a_floor_without_a_measurement_is_ignored_on_a_partial_run(self):
        floors = {"apiKit": 80, "timerKit": 90, "goneKit": 50}

        self.assertEqual([], self.failures(floors, full_run=False))

    def test_only_the_requested_packages_are_judged(self):
        self.assertEqual([self.ROWS[1]], module.judged_packages(self.ROWS, ["timerKit", "examples"]))
        self.assertEqual(self.ROWS, module.judged_packages(self.ROWS, []))


class RatchetFloorsTests(unittest.TestCase):
    def test_floors_rise_to_the_measured_whole_percent(self):
        rows = [module.PackageCoverage("apiKit", 857, 143)]

        self.assertEqual({"apiKit": 85}, module.ratchet_floors({"apiKit": 80}, rows))

    def test_floors_are_never_lowered(self):
        rows = [module.PackageCoverage("apiKit", 70, 30)]

        self.assertEqual({"apiKit": 80}, module.ratchet_floors({"apiKit": 80}, rows))

    def test_missing_packages_are_added_and_unmeasured_ones_kept(self):
        rows = [module.PackageCoverage("newKit", 2, 1)]

        self.assertEqual({"oldKit": 90, "newKit": 66}, module.ratchet_floors({"oldKit": 90}, rows))

    def test_the_input_is_not_modified(self):
        floors = {"apiKit": 10}

        module.ratchet_floors(floors, [module.PackageCoverage("apiKit", 1, 0)])

        self.assertEqual({"apiKit": 10}, floors)


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

        markdown = module.render_markdown(rows, tests_passed=True, floors={"apiKit": 75, "timerKit": 90})

        self.assertIn("| `apiKit` | 40 | 10 | 80.0% | 75% |", markdown)
        self.assertIn("| **total** | 130 | 20 | 86.7% | |", markdown)
        self.assertIn("Every spec passed under coverage", markdown)
        self.assertIn("Every judged package meets its coverage floor.", markdown)

    def test_below_missing_and_unjudged_floors_are_marked(self):
        rows = module.parse_report(REPORT)

        markdown = module.render_markdown(
            rows, True, floors={"apiKit": 81}, judged={"apiKit"}, failures=["apiKit: below"]
        )

        self.assertIn("| `apiKit` | 40 | 10 | 80.0% | 81% **below** |", markdown)
        self.assertIn("| `timerKit` | 90 | 10 | 90.0% | not judged |", markdown)
        self.assertIn("- apiKit: below", markdown)
        self.assertIn("**missing**", module.render_markdown(rows, True, floors={"apiKit": 1}))

    def test_failed_specs_are_reported(self):
        markdown = module.render_markdown([], tests_passed=False)

        self.assertIn("Some specs failed under coverage", markdown)
        self.assertIn("| **total** | 0 | 0 | 0.0% | |", markdown)


class RunTests(unittest.TestCase):
    def setUp(self):
        self.tempdir = tempfile.TemporaryDirectory()
        root = Path(self.tempdir.name)
        patches = [
            mock.patch.object(module, "ROOT", root),
            mock.patch.object(module, "STATS_FILE", root / "luacov.stats.out"),
            mock.patch.object(module, "REPORT_FILE", root / "luacov.report.out"),
            mock.patch.object(module, "FLOORS_FILE", root / "coverage-floors.json"),
            mock.patch.object(module.shutil, "which", return_value="/usr/bin/luacov"),
        ]
        for patch in patches:
            patch.start()
            self.addCleanup(patch.stop)
        self.root = root
        self.write_floors({"timerKit": 90})

    def write_floors(self, floors: dict[str, int]) -> None:
        module.FLOORS_FILE.write_text(json.dumps(floors), encoding="utf-8")

    def read_floors(self) -> dict[str, int]:
        return json.loads(module.FLOORS_FILE.read_text(encoding="utf-8"))

    def tearDown(self):
        self.tempdir.cleanup()

    def run_module(
        self,
        suite_status: int,
        report: str | None,
        luacov_status: int = 0,
        summary=None,
        packages=("timerKit",),
        update_floors=False,
    ):
        def fake_luacov(*_args, **_kwargs):
            if report is not None:
                module.REPORT_FILE.write_text(report, encoding="utf-8")
            return mock.Mock(returncode=luacov_status)

        stdout, stderr = io.StringIO(), io.StringIO()
        with mock.patch.object(module.test_run, "run", return_value=suite_status) as suites, \
                mock.patch.object(module.subprocess, "run", side_effect=fake_luacov), \
                redirect_stdout(stdout), redirect_stderr(stderr):
            status = module.run(list(packages), summary, update_floors)
        return status, suites, stdout.getvalue(), stderr.getvalue()

    def test_busted_runs_with_coverage_without_allocation_specs(self):
        status, suites, stdout, _ = self.run_module(0, REPORT)

        self.assertEqual(0, status)
        suites.assert_called_once_with(["timerKit"], ["--coverage", "--exclude-tags=allocation"])
        self.assertIn("| `timerKit` | 90 | 10 | 90.0% | 90% |", stdout)

    def test_failed_specs_fail_the_run(self):
        status, _, stdout, _ = self.run_module(1, REPORT)

        self.assertEqual(1, status)
        self.assertIn("Some specs failed under coverage", stdout)

    def test_a_package_below_its_floor_fails_the_run(self):
        self.write_floors({"timerKit": 91})

        status, _, stdout, stderr = self.run_module(0, REPORT)

        self.assertEqual(1, status)
        self.assertIn("91% **below**", stdout)
        self.assertIn("timerKit: 90.0% is below its floor of 91%", stderr)

    def test_a_measured_package_without_a_floor_fails_a_full_run(self):
        self.write_floors({"timerKit": 90})

        status, _, _, stderr = self.run_module(0, REPORT, packages=())

        self.assertEqual(1, status)
        self.assertIn("apiKit: no coverage floor", stderr)

    def test_a_partial_run_judges_only_its_own_packages(self):
        status, _, stdout, _ = self.run_module(0, REPORT, packages=("timerKit",))

        self.assertEqual(0, status)
        self.assertIn("| `apiKit` | 40 | 10 | 80.0% | not judged |", stdout)

    def test_an_unreadable_floors_file_stops_before_the_suites(self):
        module.FLOORS_FILE.write_text("[", encoding="utf-8")

        status, suites, _, stderr = self.run_module(0, REPORT)

        self.assertEqual(2, status)
        suites.assert_not_called()
        self.assertIn("coverage-floors.json", stderr)

    def test_update_floors_raises_adds_and_never_lowers(self):
        self.write_floors({"apiKit": 85, "timerKit": 80})

        status, _, _, _ = self.run_module(0, REPORT, packages=(), update_floors=True)

        self.assertEqual(1, status)  # apiKit at 80% stays below its kept floor of 85
        self.assertEqual({"apiKit": 85, "timerKit": 90}, self.read_floors())

    def test_update_floors_adds_a_missing_package_and_passes(self):
        self.write_floors({"timerKit": 90})

        status, _, _, _ = self.run_module(0, REPORT, packages=(), update_floors=True)

        self.assertEqual(0, status)
        self.assertEqual({"apiKit": 80, "timerKit": 90}, self.read_floors())

    def test_update_floors_refuses_a_run_with_failing_specs(self):
        self.write_floors({})

        status, _, _, stderr = self.run_module(1, REPORT, packages=(), update_floors=True)

        self.assertEqual(1, status)
        self.assertEqual({}, self.read_floors())
        self.assertIn("not updated", stderr)

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
