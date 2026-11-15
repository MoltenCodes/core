"""Tests for the in-client benchmark's profiles, planner, side sets and the AceConfigDialog pin."""

from __future__ import annotations

import contextlib
import io
import re
import unittest

from tooling.bench import ace3, client_install
from tooling.bench import client_workloads as workloads

#: A case name as a client-only Lua module declares it.
CASE_NAME_RE = re.compile(r'^\s*name = "([a-z0-9-]+)",?$', re.M)


def lua_case_names(workload: workloads.ClientWorkload) -> set[str]:
    """The literal case names a client-only workload's Lua module declares."""
    text = workload.lua_file.read_text(encoding="utf-8")
    return set(CASE_NAME_RE.findall(text))


class ProfileTests(unittest.TestCase):
    def test_the_smoke_profile_is_thirteen_cases_of_known_workloads(self):
        self.assertEqual(13, len(workloads.SMOKE_PROFILE))
        host_cases = client_install.host_case_lists()
        for name, case in workloads.SMOKE_PROFILE:
            with self.subTest(workload=name, case=case):
                self.assertIn(name, workloads.BY_NAME)
                if name in workloads.SHARED_IN_CLIENT:
                    self.assertIn(case, host_cases[name])
                else:
                    self.assertIn(case, workloads.CLIENT_CASES[name])

    def test_listed_client_cases_are_declared_by_their_lua_modules(self):
        for workload in workloads.CLIENT_ONLY:
            declared = lua_case_names(workload)
            for case in workloads.CLIENT_CASES[workload.name]:
                if workload.name in ("login", "savedVariables"):
                    continue  # built from a loop over sets and sizes, checked below
                with self.subTest(workload=workload.name, case=case):
                    self.assertIn(case, declared)

    def test_the_set_workloads_build_their_cases_from_the_sets_and_sizes(self):
        login = workloads.BY_NAME["login"].lua_file.read_text(encoding="utf-8")
        self.assertIn('local SETS = { "minimum", "typical", "full" }', login)
        saved = workloads.BY_NAME["savedVariables"].lua_file.read_text(encoding="utf-8")
        self.assertIn("local SIZES = { { 1, 200 }, { 20, 200 } }", saved)

    def test_the_all_profile_covers_every_workload(self):
        entries = workloads.all_profile(client_install.host_case_lists())
        names = {name for name, _ in entries}
        expected = set(workloads.SHARED_IN_CLIENT) | {
            workload.name for workload in workloads.CLIENT_ONLY if workloads.CLIENT_CASES[workload.name]
        }
        self.assertEqual(expected, names)

    def test_only_the_set_workloads_leave_the_side_unloaded(self):
        self.assertEqual(
            {"login", "savedVariables"},
            {workload.name for workload in workloads.CLIENT_WORKLOADS if not workload.loads_side},
        )


class PlannerTests(unittest.TestCase):
    def test_a_smoke_run_is_26_sessions(self):
        plan = workloads.plan("smoke", workloads.SMOKE_PROFILE)
        self.assertEqual((26, 26), (plan.items, plan.reloads))
        # 9 batch cases and 2 window/timer cases at 10 s, 60 s and 300 s, both sides, plus reloads.
        self.assertEqual((11 * 10 + 60 + 300) * 2 + 26 * 20, plan.seconds)

    def test_rounds_and_reload_time_scale_the_plan(self):
        plan = workloads.plan("smoke", workloads.SMOKE_PROFILE, rounds=5, reload_seconds=30)
        self.assertEqual(130, plan.items)
        self.assertIn("130 sessions, 130 reloads", plan.describe())

    def test_the_plan_command_installs_nothing(self):
        output = io.StringIO()
        with contextlib.redirect_stdout(output):
            status = client_install.main(["--wow-dir", "/nonexistent", "--plan", "smoke"])
        self.assertEqual(0, status)
        self.assertIn("smoke: 13 cases x 2 sides x 1 round(s) = 26 sessions", output.getvalue())
        self.assertIn("nothing was installed", output.getvalue())


class SideSetTests(unittest.TestCase):
    def test_set_addon_names(self):
        sets = {side_set.name: side_set for side_set in workloads.SIDE_SETS}
        self.assertEqual("MoltenCodesBench_Kits", client_install.set_addon("moltencodes", sets["full"]))
        self.assertEqual(
            "MoltenCodesBench_KitsMinimum", client_install.set_addon("moltencodes", sets["minimum"])
        )
        self.assertEqual("MoltenCodesBench_Ace3Full", client_install.set_addon("ace3", sets["full"]))

    def test_every_ace3_set_file_is_pinned(self):
        for side_set in workloads.SIDE_SETS:
            for path in client_install.set_ace3_files(side_set):
                with self.subTest(set=side_set.name, path=path):
                    self.assertIn(path, ace3.PINNED_FILES)

    def test_the_full_ace3_set_carries_the_options_dialog(self):
        full = next(side_set for side_set in workloads.SIDE_SETS if side_set.name == "full")
        files = client_install.set_ace3_files(full)
        self.assertIn("AceConfig-3.0/AceConfigDialog-3.0/AceConfigDialog-3.0.lua", files)
        self.assertNotIn(client_install.ACE3_LICENSE, files)

    def test_the_saved_set_declares_one_saved_variable_per_side(self):
        saved = next(side_set for side_set in workloads.SIDE_SETS if side_set.name == "saved")
        self.assertEqual(
            {"moltencodes": "MoltenCodesBenchKitsSavedDB", "ace3": "MoltenCodesBenchAce3SavedDB"},
            dict(saved.saved_variables),
        )
        toc = client_install.side_toc("X", "notes", "## Interface: 1", ["a.lua"], "SomeDB")
        self.assertIn("## SavedVariables: SomeDB\n", toc)


class DialogPinTests(unittest.TestCase):
    def test_existing_workloads_keep_exactly_their_files(self):
        self.assertEqual(28, len(ace3.LOADED_FILES))
        self.assertFalse(set(ace3.LOADED_FILES) & set(ace3.DIALOG_FILES))
        self.assertEqual((*ace3.LOADED_FILES, *ace3.DIALOG_FILES), ace3.PINNED_FILES)

    def test_the_dialog_files_are_the_options_dialog_and_the_controls_it_creates(self):
        self.assertEqual(11, len(ace3.DIALOG_FILES))
        self.assertEqual(
            "AceConfig-3.0/AceConfigDialog-3.0/AceConfigDialog-3.0.lua", ace3.DIALOG_FILES[-1]
        )


if __name__ == "__main__":
    unittest.main()
