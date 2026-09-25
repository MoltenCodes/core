"""Tests for the real-client result matrix, against fixture files and a fake game folder.

Nothing here reads the owner's game folder: every test copies the fixtures in
``fixtures/client/`` into a temporary ``World of Warcraft`` folder or names
them directly, and writes ``results.json`` and ``RESULTS.md`` in a temporary
directory.
"""

from __future__ import annotations

import contextlib
import io
import json
import shutil
import tempfile
import unittest
from pathlib import Path

from tooling.client import report as module


#: Saved-variables files as the client writes them (`.lua.txt`, so the Lua
#: formatter leaves their bytes alone; see test_client_saved_variables.py).
FIXTURES = Path(__file__).resolve().parent / "fixtures" / "client"
RETAIL_FIXTURE = FIXTURES / "retail_schema2.lua.txt"
CLASSIC_FIXTURE = FIXTURES / "classic_era_schema1.lua.txt"


def legacy_row(package: str, tests: int, skipped: int) -> module.Row:
    """A row as the README's table recorded it: no commit, no skip reasons."""
    return module.Row(
        flavour="retail",
        package=package,
        mode="default",
        tests=tests,
        passed=tests - skipped,
        failed=0,
        skipped=skipped,
        timeout=0,
        version="12.1.0",
        build="69933",
        interface=120100,
        locale="enUS",
        os="macOS",
        date="2026-09-24/2026-09-25",
        skips=None if skipped else [],
    )


class ReportTestCase(unittest.TestCase):
    """A temporary folder with a fake game folder and output paths."""

    def setUp(self):
        self.tempdir = tempfile.TemporaryDirectory()
        self.base = Path(self.tempdir.name).resolve()
        self.wow = self.base / "World of Warcraft"
        self.results = self.base / "results.json"
        self.matrix = self.base / "RESULTS.md"

    def tearDown(self):
        self.tempdir.cleanup()

    def install_fixture(self, fixture: Path, flavour_directory: str, account: str = "1#1") -> Path:
        """Copy a fixture where the client of ``flavour_directory`` would write it."""
        folder = self.wow / flavour_directory / "WTF" / "Account" / account / "SavedVariables"
        folder.mkdir(parents=True, exist_ok=True)
        destination = folder / "MoltenCodesTest.lua"
        shutil.copyfile(fixture, destination)
        return destination

    def run_command(self, *arguments: str) -> tuple[int, str, str]:
        """Run ``main`` with the temporary output paths; return status, stdout, stderr."""
        stdout, stderr = io.StringIO(), io.StringIO()
        with contextlib.redirect_stdout(stdout), contextlib.redirect_stderr(stderr):
            status = module.main(
                ["--results", str(self.results), "--matrix", str(self.matrix), *arguments]
            )
        return status, stdout.getvalue(), stderr.getvalue()

    def write_recorded(self, rows: list[module.Row], unavailable: dict | None = None) -> None:
        record = module.Record(rows, unavailable or {})
        self.results.write_text(module.render_results_json(record), encoding="utf-8")

    def recorded(self) -> dict[tuple[str, str, str], module.Row]:
        return {row.key: row for row in module.load_results(self.results).rows}


class ReadingTests(ReportTestCase):
    def test_a_schema_2_entry_becomes_a_row_with_its_client_commit_and_tests(self):
        runs = module.read_saved_runs(RETAIL_FIXTURE, warn=self.fail)

        rows = {run.row.key: run.row for run in runs}
        registry = rows[("retail", "registry", "default")]
        counts = [getattr(registry, name) for name in module.TOTAL_FIELDS]
        self.assertEqual([3, 1, 1, 1, 0], counts)
        self.assertEqual("0123456789abcdef0123456789abcdef01234567", registry.commit)
        self.assertIs(False, registry.dirty)
        self.assertEqual("macOS", registry.os)
        self.assertEqual("69933", registry.build)
        self.assertEqual(120100, registry.interface)
        self.assertEqual(
            [
                {
                    "suite": "registry.lookup",
                    "test": "a player named Péter is read",
                    "reason": "the client has no C_Spell.GetSpellInfo (Classic Era)",
                }
            ],
            registry.skips,
        )
        self.assertEqual("failed", registry.problems[0]["status"])
        self.assertIn("RegistrySuite.lua:185", registry.problems[0]["message"])

    def test_a_combat_entry_is_its_own_row(self):
        runs = module.read_saved_runs(RETAIL_FIXTURE, warn=self.fail)

        combat = {run.row.key: run.row for run in runs}[("retail", "hookKit", "combat")]
        self.assertEqual(1, combat.passed)
        self.assertIs(True, combat.dirty)

    def test_a_schema_1_entry_is_attributed_by_the_project_id_and_has_no_commit(self):
        warnings: list[str] = []

        runs = module.read_saved_runs(CLASSIC_FIXTURE, warn=warnings.append)

        self.assertEqual(1, len(runs))
        row = runs[0].row
        self.assertEqual(("classic-era", "registry", "default"), row.key)
        self.assertIsNone(row.commit)
        self.assertIsNone(row.os)
        self.assertEqual("70001", row.build)
        self.assertEqual([], row.skips)
        # The broken entry is reported and skipped, not fatal.
        self.assertEqual(1, len(warnings))
        self.assertIn("schema 9", warnings[0])

    def test_the_client_decides_the_flavour_not_the_folder(self):
        # A Classic Era results file copied into the Retail folder is still Classic Era.
        path = self.install_fixture(CLASSIC_FIXTURE, "_retail_")

        runs = module.read_saved_runs(path, warn=lambda _: None)

        self.assertEqual("classic-era", runs[0].row.flavour)

    def test_the_folder_decides_when_the_client_did_not_say(self):
        text = RETAIL_FIXTURE.read_bytes().replace(b'["projectId"] = 1,', b"")
        text = text.replace(b'["flavourDirectory"] = "_retail_",', b"")
        folder = self.wow / "_classic_" / "WTF" / "Account" / "A" / "SavedVariables"
        folder.mkdir(parents=True)
        path = folder / "MoltenCodesTest.lua"
        path.write_bytes(text)

        runs = module.read_saved_runs(path, warn=self.fail)

        self.assertEqual({"classic-mop"}, {run.row.flavour for run in runs})

    def test_a_run_on_a_test_build_is_left_out_with_a_warning(self):
        text = RETAIL_FIXTURE.read_bytes().replace(
            b'["projectId"] = 1,\n["flavour"]',
            b'["projectId"] = 1,\n["testBuild"] = true,\n["flavour"]',
        )
        path = self.base / "MoltenCodesTest.lua"
        path.write_bytes(text)
        warnings: list[str] = []

        runs = module.read_saved_runs(path, warn=warnings.append)

        self.assertEqual([("retail", "hookKit", "combat")], [run.row.key for run in runs])
        self.assertIn("test build", warnings[0])

    def test_a_run_installed_into_a_test_realm_folder_is_left_out_with_a_warning(self):
        text = RETAIL_FIXTURE.read_bytes().replace(b'"_retail_"', b'"_classic_era_ptr_"')
        path = self.base / "MoltenCodesTest.lua"
        path.write_bytes(text)
        warnings: list[str] = []

        runs = module.read_saved_runs(path, warn=warnings.append)

        self.assertEqual([], runs)
        self.assertEqual(2, len(warnings))
        self.assertIn("_classic_era_ptr_", warnings[0])

    def test_an_unparsable_file_is_an_error_naming_it(self):
        path = self.base / "MoltenCodesTest.lua"
        path.write_text("MoltenCodesTestResults = { print('x') }\n", encoding="utf-8")

        with self.assertRaises(module.ReportError) as caught:
            module.read_saved_runs(path, warn=self.fail)
        self.assertIn(str(path), str(caught.exception))

    def test_finds_account_wide_files_of_the_existing_flavour_folders_only(self):
        retail = self.install_fixture(RETAIL_FIXTURE, "_retail_")
        classic = self.install_fixture(CLASSIC_FIXTURE, "_classic_era_", account="2#1")
        backup = retail.with_name("MoltenCodesTest.lua.bak")
        backup.write_text("ignored", encoding="utf-8")

        found = module.find_saved_variables(self.wow, ["_retail_", "_classic_era_", "_classic_"])

        self.assertEqual([retail, classic], found)


class MergeTests(ReportTestCase):
    def test_a_run_replaces_its_row_and_keeps_every_other_row(self):
        recorded = [legacy_row("registry", 17, 0), legacy_row("apiKit", 23, 0)]
        runs = module.read_saved_runs(RETAIL_FIXTURE, warn=self.fail)

        outcome = module.merge_rows(recorded, runs)

        rows = {row.key: row for row in outcome.rows}
        self.assertEqual(3, rows[("retail", "registry", "default")].tests)
        self.assertEqual(23, rows[("retail", "apiKit", "default")].tests)
        self.assertEqual("2026-09-24/2026-09-25", rows[("retail", "apiKit", "default")].date)
        self.assertIn(("retail", "hookKit", "combat"), rows)
        self.assertTrue(any(line.startswith("updated retail registry") for line in outcome.lines))
        self.assertTrue(
            any(line.startswith("added retail hookKit (combat)") for line in outcome.lines)
        )

    def test_a_recorded_row_newer_than_the_run_is_kept(self):
        newer = legacy_row("registry", 99, 0)
        newer.date = "2026-12-31 23:59:59"
        runs = module.read_saved_runs(RETAIL_FIXTURE, warn=self.fail)

        outcome = module.merge_rows([newer], runs)

        rows = {row.key: row for row in outcome.rows}
        self.assertEqual(99, rows[("retail", "registry", "default")].tests)
        self.assertTrue(any(line.startswith("kept retail registry") for line in outcome.lines))

    def test_of_two_runs_in_the_inputs_the_later_one_wins(self):
        runs = module.read_saved_runs(RETAIL_FIXTURE, warn=self.fail)
        older = [run for run in runs if run.row.package == "registry"][0]
        later = module.SavedRun(module.row_from_json(older.row.to_json(), 0), older.source)
        later.row.date = "2026-09-27 09:00:00"
        later.row.tests = 5

        outcome = module.merge_rows([], [later, older])

        rows = {row.key: row for row in outcome.rows}
        self.assertEqual(5, rows[("retail", "registry", "default")].tests)

    def test_the_readme_interval_sorts_before_any_run_on_its_last_day(self):
        self.assertLess(
            module.date_order_key("2026-09-24/2026-09-25"),
            module.date_order_key("2026-09-25 00:00:01"),
        )
        self.assertEqual("", module.date_order_key(None))


class RenderingTests(ReportTestCase):
    def rows(self) -> list[module.Row]:
        recorded = [legacy_row("apiKit", 23, 0), legacy_row("hookKit", 38, 2)]
        runs = module.read_saved_runs(RETAIL_FIXTURE, warn=self.fail)
        runs += module.read_saved_runs(CLASSIC_FIXTURE, warn=lambda _: None)
        return module.merge_rows(recorded, runs).rows

    def test_the_matrix_has_one_column_group_per_flavour(self):
        text = module.render_matrix(module.Record(self.rows()), ["hookKit"])

        header = next(line for line in text.splitlines() if line.startswith("| Package | Retail"))
        self.assertEqual(
            "| Package | Retail tests | passed | failed | skipped | timeout "
            "| Classic Era tests | passed | failed | skipped | timeout "
            "| Mists Classic tests | passed | failed | skipped | timeout |",
            header,
        )
        self.assertIn(
            "| `registry` | 3 | 1 | 1 | 1 | 0 | 2 | 2 | 0 | 0 | 0 | not run | - | - | - | - |", text
        )
        self.assertIn("| `hookKit` (combat) | 1 | 1 | 0 | 0 | 0 | - |", text)
        # The total counts default runs only; a combat run repeats tests of its package.
        self.assertIn(
            "| **total (default runs)** | **64** | **60** | **1** | **3** | **0** "
            "| **2** | **2** | **0** | **0** | **0** | not run | - | - | - | - |",
            text,
        )

    def test_runs_show_build_locale_os_date_and_commit(self):
        text = module.render_matrix(module.Record(self.rows()), [])

        self.assertIn(
            "| `registry` | 12.1.0 (69933) | 120100 | enUS | macOS | 2026-09-26 10:00:00 "
            "| `0123456789ab` |",
            text,
        )
        self.assertIn("| `hookKit` (combat) | 12.1.0 (69933) | 120100 | enUS | unknown |", text)
        self.assertIn("`0123456789ab` (changes) |", text)
        self.assertIn(
            "| `apiKit` | 12.1.0 (69933) | 120100 | enUS | macOS | 2026-09-24/2026-09-25 "
            "| unknown |",
            text,
        )
        self.assertIn("| `registry` | 1.15.9 (70001) | 11509 | deDE | unknown |", text)
        self.assertIn("No run recorded yet (install into `_classic_`).", text)

    def test_skips_are_listed_with_their_reasons_and_never_as_passes(self):
        text = module.render_matrix(module.Record(self.rows()), [])

        self.assertIn(
            "| `registry` | registry.lookup: a player named Péter is read "
            "| the client has no C_Spell.GetSpellInfo (Classic Era) |",
            text,
        )
        self.assertIn("- `hookKit`: 2 skipped", text)

    def test_failures_are_listed_and_pipes_are_escaped(self):
        text = module.render_matrix(module.Record(self.rows()), [])

        self.assertIn(
            "| Retail | `registry` | failed | registry.facade: the facade carries the revision "
            "\\| of the manifest | RegistrySuite.lua:185: expected number 11 to be number 12 |",
            text,
        )

    def test_gaps_name_windows_groups_missing_flavours_packages_and_combat_runs(self):
        text = module.render_matrix(module.Record(self.rows()), ["hookKit", "lifecycleKit"])
        gaps = text.split("## Gaps", 1)[1]

        self.assertIn("**Windows client**", gaps)
        self.assertIn("**Group communication with a second character**", gaps)
        self.assertIn("**Conditions a solo session cannot create**", gaps)
        self.assertIn("**Mists Classic**: no run recorded yet.", gaps)
        self.assertIn("**Classic Era**: no run recorded for `apiKit`, `hookKit`.", gaps)
        self.assertIn(
            "**Retail combat runs**: no `/mct run <package> combat` recorded for `lifecycleKit`",
            gaps,
        )
        self.assertIn(
            "**Classic Era combat runs**: no `/mct run <package> combat` recorded for "
            "`hookKit`, `lifecycleKit`",
            gaps,
        )
        self.assertIn("**Skip reasons**: 1 rows", gaps)

    def test_an_optional_flavour_gets_columns_only_once_it_has_a_run(self):
        rows = self.rows()
        text = module.render_matrix(module.Record(rows), [])
        self.assertNotIn("TBC Anniversary tests", text)
        self.assertIn(
            "| TBC Anniversary | `_anniversary_` | optional (not promised); not run yet |", text
        )
        self.assertIn("- **TBC Anniversary** (optional, not promised): no run recorded yet.", text)

        anniversary = module.row_from_json(rows[0].to_json(), 0)
        anniversary.flavour = "tbc-anniversary"
        text = module.render_matrix(module.Record([*rows, anniversary]), [])
        self.assertIn("TBC Anniversary tests", text)

    def test_an_unavailable_flavour_shows_as_not_run_with_its_reason(self):
        record = module.Record(self.rows(), {"classic-mop": "no client session available"})

        text = module.render_matrix(record, [])

        self.assertIn(
            "| Mists Classic | `_classic_` | not run (no client session available) |", text
        )
        self.assertIn("Not run: no client session available.", text)
        self.assertIn("- **Mists Classic**: not run: no client session available.", text)
        self.assertIn("| Classic Era | `_classic_era_` | 1 package recorded, latest", text)

    def test_a_windows_run_removes_the_windows_gap(self):
        rows = self.rows()
        rows[0].os = "Windows"

        self.assertNotIn("**Windows client**", module.render_matrix(module.Record(rows), []))

    def test_results_json_round_trips(self):
        rows = self.rows()
        self.write_recorded(rows)

        self.assertEqual(
            [row.to_json() for row in module.sort_rows(rows)],
            [row.to_json() for row in module.load_results(self.results).rows],
        )

    def test_the_combat_scan_finds_the_suite_option(self):
        folder = self.base / "tests" / "MoltenCodesTest_HookKit"
        folder.mkdir(parents=True)
        (folder / "HookKitSuite.lua").write_text(
            'local PACKAGE_ID = "hookKit"\nnewSuite("combat", { combat = true })\n',
            encoding="utf-8",
        )
        other = self.base / "tests" / "MoltenCodesTest_TimerKit"
        other.mkdir()
        (other / "TimerKitSuite.lua").write_text(
            'local PACKAGE_ID = "timerKit"\nlocal inCombat = true\n', encoding="utf-8"
        )

        self.assertEqual(["hookKit"], module.combat_suite_packages(self.base / "tests"))


class CommandLineTests(ReportTestCase):
    def test_merges_every_flavour_folder_found_and_writes_both_files(self):
        self.write_recorded([legacy_row("apiKit", 23, 0)])
        self.install_fixture(RETAIL_FIXTURE, "_retail_")
        self.install_fixture(CLASSIC_FIXTURE, "_classic_era_")

        status, output, errors = self.run_command("--wow-dir", str(self.wow))

        self.assertEqual(0, status, errors)
        self.assertIn("schema 9", errors)
        recorded = self.recorded()
        self.assertIn(("retail", "apiKit", "default"), recorded)
        self.assertIn(("retail", "registry", "default"), recorded)
        self.assertIn(("classic-era", "registry", "default"), recorded)
        self.assertIn(f"wrote {self.matrix}", output)
        self.assertTrue(self.matrix.read_text(encoding="utf-8").startswith("# Real-client results"))

    def test_flavour_dir_limits_the_folders_read(self):
        self.install_fixture(RETAIL_FIXTURE, "_retail_")
        self.install_fixture(CLASSIC_FIXTURE, "_classic_era_")

        status, _, errors = self.run_command(
            "--wow-dir", str(self.wow), "--flavour-dir", "_classic_era_"
        )

        self.assertEqual(0, status, errors)
        self.assertEqual({"classic-era"}, {key[0] for key in self.recorded()})

    def test_saved_variables_names_a_file_directly(self):
        status, _, errors = self.run_command("--saved-variables", str(RETAIL_FIXTURE))

        self.assertEqual(0, status, errors)
        self.assertEqual(2, len(self.recorded()))

    def test_check_passes_when_the_files_match_and_fails_when_they_do_not(self):
        self.run_command("--saved-variables", str(RETAIL_FIXTURE))

        status, output, _ = self.run_command("--saved-variables", str(RETAIL_FIXTURE), "--check")
        self.assertEqual(0, status)
        self.assertIn("up to date", output)

        status, _, errors = self.run_command("--saved-variables", str(CLASSIC_FIXTURE), "--check")
        self.assertEqual(1, status)
        self.assertIn("differs: added classic-era registry", errors)

        self.matrix.write_text("edited by hand\n", encoding="utf-8")
        status, _, errors = self.run_command("--check")
        self.assertEqual(1, status)
        self.assertIn(str(self.matrix), errors)

    def test_check_writes_nothing(self):
        status, _, _ = self.run_command("--saved-variables", str(RETAIL_FIXTURE), "--check")

        self.assertEqual(1, status)
        self.assertFalse(self.results.exists())
        self.assertFalse(self.matrix.exists())

    def test_dry_run_prints_the_changes_and_writes_nothing(self):
        self.write_recorded([legacy_row("registry", 17, 0)])
        before = self.results.read_text(encoding="utf-8")

        status, output, _ = self.run_command("--saved-variables", str(RETAIL_FIXTURE), "--dry-run")

        self.assertEqual(0, status)
        self.assertIn("dry run: updated retail registry (default)", output)
        self.assertIn(f"would write {self.results}", output)
        self.assertEqual(before, self.results.read_text(encoding="utf-8"))
        self.assertFalse(self.matrix.exists())

    def test_a_second_run_with_the_same_input_changes_nothing(self):
        self.run_command("--saved-variables", str(RETAIL_FIXTURE))

        status, output, _ = self.run_command("--saved-variables", str(RETAIL_FIXTURE))

        self.assertEqual(0, status)
        self.assertIn("nothing changed", output)
        self.assertIn("unchanged retail registry", output)

    def test_refuses_a_game_folder_without_results(self):
        (self.wow / "_retail_").mkdir(parents=True)

        status, _, errors = self.run_command("--wow-dir", str(self.wow))

        self.assertEqual(1, status)
        self.assertIn("no MoltenCodesTest.lua", errors)

    def test_refuses_a_missing_flavour_folder_and_a_flavour_without_a_game_folder(self):
        self.install_fixture(RETAIL_FIXTURE, "_retail_")

        status, _, errors = self.run_command(
            "--wow-dir", str(self.wow), "--flavour-dir", "_classic_"
        )
        self.assertEqual(1, status)
        self.assertIn("_classic_ does not exist", errors)

        status, _, errors = self.run_command("--flavour-dir", "_retail_")
        self.assertEqual(1, status)
        self.assertIn("--flavour-dir needs --wow-dir", errors)

    def test_unavailable_and_available_record_and_drop_a_reason(self):
        self.write_recorded([legacy_row("apiKit", 23, 0)])

        status, output, errors = self.run_command(
            "--unavailable", "classic-era=no active game time", "--unavailable", "classic-mop=same"
        )
        self.assertEqual(0, status, errors)
        self.assertIn("recorded classic-era as unavailable: no active game time", output)
        record = module.load_results(self.results)
        self.assertEqual(
            {"classic-era": "no active game time", "classic-mop": "same"}, record.unavailable
        )
        self.assertIn("not run (no active game time)", self.matrix.read_text(encoding="utf-8"))

        status, output, _ = self.run_command("--available", "classic-mop")
        self.assertEqual(0, status)
        self.assertIn("cleared the unavailable reason of classic-mop", output)
        self.assertEqual({"classic-era"}, set(module.load_results(self.results).unavailable))

    def test_a_recorded_run_clears_the_unavailable_reason_of_its_flavour(self):
        self.write_recorded([], {"classic-era": "no active game time"})

        status, output, errors = self.run_command("--saved-variables", str(CLASSIC_FIXTURE))

        self.assertEqual(0, status, errors)
        self.assertIn("cleared the unavailable reason of classic-era: a run is recorded", output)
        self.assertEqual({}, module.load_results(self.results).unavailable)

    def test_unavailable_refuses_an_unknown_flavour_a_missing_reason_and_a_flavour_with_runs(self):
        self.write_recorded([legacy_row("apiKit", 23, 0)])

        for argument, message in (
            ("ptr=closed", 'unknown flavour "ptr"'),
            ("classic-era", "needs FLAVOUR=REASON"),
            ("classic-era=  ", "needs FLAVOUR=REASON"),
            ("retail=no time", "retail has recorded runs"),
        ):
            with self.subTest(argument=argument):
                status, _, errors = self.run_command("--unavailable", argument)
                self.assertEqual(1, status)
                self.assertIn(message, errors)

    def test_refuses_a_malformed_results_file(self):
        self.results.write_text(json.dumps({"schema": 1, "rows": [{"flavour": "tbc"}]}))

        status, _, errors = self.run_command()

        self.assertEqual(1, status)
        self.assertIn("rows[0].flavour", errors)


class CommittedMatrixTests(unittest.TestCase):
    def test_the_committed_matrix_is_what_the_record_renders(self):
        # The same comparison `python3 -m tooling.client.report --check` makes.
        record = module.load_results(module.DEFAULT_RESULTS_PATH)

        self.assertEqual(
            module.render_results_json(record),
            module.DEFAULT_RESULTS_PATH.read_text(encoding="utf-8"),
        )
        self.assertEqual(
            module.render_matrix(record, module.combat_suite_packages()),
            module.DEFAULT_MATRIX_PATH.read_text(encoding="utf-8"),
        )


if __name__ == "__main__":
    unittest.main()
