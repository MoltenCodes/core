"""Tests for host reference extraction and guard detection.

Each test is a small invented Lua snippet in the shape the Kits use, with the
verdict the gate relies on. The unguarded cases matter as much as the guarded
ones: they are the ways a guard can look present without protecting the use,
and the gate must never pass them.
"""

from __future__ import annotations

import textwrap
import unittest

from tooling.validation import lua_references as references


def analyse(source: str, methods: tuple[str, ...] = (), events: tuple[str, ...] = ()) -> list[references.Reference]:
    return references.analyse_source(textwrap.dedent(source), "Kit.lua", methods, events)


def only(found: list[references.Reference], name: str) -> references.Reference:
    matching = [reference for reference in found if reference.name == name]
    if len(matching) != 1:
        raise AssertionError(f"expected one reference to {name}, found {[r.name for r in found]}")
    return matching[0]


class DirectReadTests(unittest.TestCase):
    def test_type_test_guards_the_call(self):
        found = analyse(
            """
            local f = rawget(_G, "HostFunction")
            if type(f) == "function" then
              f()
            end
            """
        )

        reference = only(found, "HostFunction")
        self.assertEqual(references.KIND_GLOBAL, reference.kind)
        self.assertTrue(reference.guarded)

    def test_unguarded_call_is_reported_with_its_line(self):
        found = analyse(
            """
            local f = rawget(_G, "HostFunction")
            f()
            """
        )

        reference = only(found, "HostFunction")
        self.assertFalse(reference.guarded)
        self.assertEqual([(3, "called")], [(use.line, use.reason) for use in reference.unguarded_uses])

    def test_early_exit_guards_what_follows(self):
        found = analyse(
            """
            local function run()
              local f = rawget(_G, "HostFunction")
              if type(f) ~= "function" then
                return
              end
              f()
            end
            """
        )

        self.assertTrue(only(found, "HostFunction").guarded)

    def test_error_is_an_early_exit(self):
        found = analyse(
            """
            local f = rawget(_G, "HostFunction")
            if f == nil then
              error("missing")
            end
            f()
            """
        )

        self.assertTrue(only(found, "HostFunction").guarded)

    def test_a_test_in_one_branch_does_not_guard_code_after_it(self):
        found = analyse(
            """
            local f = rawget(_G, "HostFunction")
            if type(f) == "function" then
              f()
            end
            f()
            """
        )

        self.assertFalse(only(found, "HostFunction").guarded)

    def test_facts_do_not_enter_a_closure(self):
        found = analyse(
            """
            local f = rawget(_G, "HostFunction")
            if f then
              local function later()
                f()
              end
            end
            """
        )

        self.assertFalse(only(found, "HostFunction").guarded)

    def test_reassignment_invalidates_the_test(self):
        found = analyse(
            """
            local f = rawget(_G, "HostFunction")
            if f then
              f = rawget(_G, "OtherFunction")
              f()
            end
            """
        )

        self.assertFalse(only(found, "OtherFunction").guarded)

    def test_short_circuit_and_guards_its_right_side(self):
        found = analyse(
            """
            local f = rawget(_G, "HostFunction")
            local value = type(f) == "function" and f() or nil
            """
        )

        self.assertTrue(only(found, "HostFunction").guarded)

    def test_certain_fallback_assignment_guards_later_uses(self):
        found = analyse(
            """
            local function run()
              local f = rawget(_G, "HostFunction")
              if not f then
                f = function() end
              end
              f()
            end
            """
        )

        self.assertTrue(only(found, "HostFunction").guarded)

    def test_pcall_handles_an_absent_function(self):
        found = analyse('pcall(rawget(_G, "HostFunction"), 1)')

        self.assertTrue(only(found, "HostFunction").guarded)

    def test_passing_an_untested_value_along_is_unguarded(self):
        found = analyse('store(rawget(_G, "HostFunction"))')

        reference = only(found, "HostFunction")
        self.assertEqual(["passed to a function"], [use.reason for use in reference.unguarded_uses])

    def test_global_table_forms_and_aliases(self):
        found = analyse(
            """
            local GLOBALS = _G
            local a = _G.First
            local b = _G["Second"]
            local c = GLOBALS.Third
            """
        )

        self.assertEqual(["First", "Second", "Third"], [reference.name for reference in found])

    def test_string_constant_names_the_global(self):
        found = analyse(
            """
            local PROJECT_GLOBAL = "WOW_PROJECT_ID"
            local id = rawget(_G, PROJECT_GLOBAL)
            """
        )

        self.assertEqual(["WOW_PROJECT_ID"], [reference.name for reference in found])

    def test_comments_and_strings_are_not_references(self):
        found = analyse(
            """
            -- rawget(_G, "Commented")
            local text = 'rawget(_G, "Quoted")'
            """
        )

        self.assertEqual([], found)

    def test_free_names_and_their_fields(self):
        found = analyse("local s = string.format('%d', select('#', 1))")

        self.assertEqual({"select", "string.format"}, {reference.name for reference in found})

    def test_local_alias_of_type_is_still_a_type_test(self):
        found = analyse(
            """
            local type = type
            local f = rawget(_G, "HostFunction")
            if type(f) == "function" then
              f()
            end
            """
        )

        self.assertTrue(only(found, "HostFunction").guarded)


class MemberTests(unittest.TestCase):
    def test_namespace_function_needs_its_own_guard(self):
        found = analyse(
            """
            local timer = rawget(_G, "C_Timer")
            if type(timer) == "table" then
              timer.After(1, print)
              if type(timer.NewTicker) == "function" then
                timer.NewTicker(1, print)
              end
            end
            """
        )

        self.assertTrue(only(found, "C_Timer").guarded)
        self.assertFalse(only(found, "C_Timer.After").guarded)
        tickers = [reference for reference in found if reference.name == "C_Timer.NewTicker"]
        self.assertEqual(2, len(tickers), "the test site and the call site")
        self.assertTrue(all(reference.guarded for reference in tickers))

    def test_or_offers_an_alternative(self):
        found = analyse(
            """
            local unpackValues = rawget(table, "unpack") or rawget(_G, "unpack")
            unpackValues({})
            """
        )

        reference = only(found, "table.unpack")
        self.assertEqual([("table.unpack", "unpack")], [use.alternatives for use in reference.unguarded_uses])

    def test_a_test_stored_in_a_local_guards_what_it_tested(self):
        found = analyse(
            """
            local function open()
              local picker = rawget(_G, "Picker")
              local setup = type(picker) == "table" and picker.Setup or nil
              if type(setup) ~= "function" or not check(picker) then
                return
              end
              setup(picker)
            end
            """
        )

        self.assertTrue(only(found, "Picker").guarded)
        self.assertTrue(only(found, "Picker.Setup").guarded)

    def test_value_assigned_inside_its_test_is_not_carried(self):
        found = analyse(
            """
            local function limit()
              local count = 5
              local host = rawget(_G, "MAX_COUNT")
              if type(host) == "number" and host < count then
                count = host
              end
              for index = 1, count do
              end
            end
            """
        )

        self.assertTrue(only(found, "MAX_COUNT").guarded)


class HelperTests(unittest.TestCase):
    def test_reader_helper_call_sites_are_references(self):
        found = analyse(
            """
            local function readGlobal(name)
              return rawget(_G, name)
            end
            local probe = readGlobal("Guarded")
            if probe then
              probe()
            end
            readGlobal("Unguarded")()
            """
        )

        guarded = only(found, "Guarded")
        self.assertEqual("readGlobal", guarded.via)
        self.assertTrue(guarded.guarded)
        self.assertFalse(only(found, "Unguarded").guarded)

    def test_probe_helper_makes_its_reads_guarded(self):
        found = analyse(
            """
            local function has(name)
              return type(rawget(_G, name)) == "table"
            end
            local present = has("C_Namespace")
            """
        )

        self.assertTrue(only(found, "C_Namespace").guarded)

    def test_helper_returning_false_when_absent_still_needs_a_guard(self):
        found = analyse(
            """
            local function readFunction(name)
              local value = rawget(_G, name)
              if type(value) ~= "function" then
                return false
              end
              return value
            end
            readFunction("HostFunction")()
            """
        )

        self.assertFalse(only(found, "HostFunction").guarded)

    def test_helper_with_a_present_fallback_never_returns_absent(self):
        found = analyse(
            """
            local function clientText(name, fallback)
              local value = rawget(_G, name)
              if type(value) == "string" then
                return value
              end
              return fallback
            end
            button:SetText(clientText("ACCEPT", "Accept"))
            """
        )

        self.assertTrue(only(found, "ACCEPT").guarded)

    def test_namespace_helper_keeps_or_alternatives(self):
        found = analyse(
            """
            local function readNamespaceFunction(namespace, name)
              local space = rawget(_G, namespace)
              if type(space) ~= "table" then
                return false
              end
              local value = rawget(space, name)
              if type(value) ~= "function" then
                return false
              end
              return value
            end
            local function readGlobalFunction(name)
              local value = rawget(_G, name)
              if type(value) ~= "function" then
                return false
              end
              return value
            end
            local function readAddOnFunction(name)
              return readNamespaceFunction("C_AddOns", name) or readGlobalFunction(name)
            end
            store(readAddOnFunction("GetAddOnInfo"))
            """
        )

        reference = only(found, "C_AddOns.GetAddOnInfo")
        self.assertEqual(
            [("C_AddOns.GetAddOnInfo", "GetAddOnInfo")],
            [use.alternatives for use in reference.unguarded_uses],
        )
        self.assertTrue(only(found, "C_AddOns").guarded)

    def test_unknown_name_is_a_dynamic_reference(self):
        found = analyse(
            """
            local function readGlobal(name)
              return rawget(_G, name)
            end
            for key in next, list do
              local value = readGlobal("SLASH_" .. key)
              if type(value) == "string" then
                print(value:upper())
              end
            end
            """
        )

        reference = only(found, 'readGlobal("SLASH_" .. key)')
        self.assertEqual(references.KIND_DYNAMIC, reference.kind)
        self.assertTrue(reference.guarded)

    def test_escaping_helper_reports_its_read(self):
        found = analyse(
            """
            local function read(name)
              return rawget(_G, name)
            end
            Kit.Read = read
            """
        )

        reference = only(found, "read(…)")
        self.assertEqual(references.KIND_DYNAMIC, reference.kind)
        self.assertFalse(reference.guarded)


class MethodAndEventTests(unittest.TestCase):
    def test_widget_method_guard(self):
        found = analyse(
            """
            local frame = makeFrame()
            if type(frame.SetFixedFrameStrata) == "function" then
              frame:SetFixedFrameStrata(true)
            end
            frame:SetFixedFrameStrata(true)
            frame:OwnMethod()
            """,
            methods=("SetFixedFrameStrata",),
        )

        methods = [reference for reference in found if reference.kind == references.KIND_METHOD]
        self.assertEqual([True, True, False], [reference.guarded for reference in methods])
        self.assertNotIn("OwnMethod", {reference.name for reference in found})

    def test_string_methods_on_a_host_value_are_not_members(self):
        found = analyse(
            """
            local text = rawget(_G, "HOST_TEXT")
            if type(text) == "string" then
              local upper = text:upper()
            end
            """
        )

        self.assertEqual(["HOST_TEXT"], [reference.name for reference in found])

    def test_event_literals_and_registrations(self):
        found = analyse(
            """
            local LOGOUT = "PLAYER_LOGOUT"
            EventKit:Connect("PLAYER_LOGIN", handler)
            EventKit:Connect("NOT_A_DOCUMENTED_EVENT", handler)
            local label = "PLAYER_LOGIN is fired once"
            """,
            events=("PLAYER_LOGIN", "PLAYER_LOGOUT"),
        )

        events = sorted(reference.name for reference in found if reference.kind == references.KIND_EVENT)
        self.assertEqual(["NOT_A_DOCUMENTED_EVENT", "PLAYER_LOGIN", "PLAYER_LOGOUT"], events)


if __name__ == "__main__":
    unittest.main()
