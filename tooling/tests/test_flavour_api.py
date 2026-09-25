"""Tests for the client API availability gate.

The verdict rules and the allow-list are tested on invented surfaces and
references; the table files and the flavour mapping are tested as committed,
because a malformed committed table must fail here before it fails CI.
"""

from __future__ import annotations

import copy
import io
import json
import tempfile
import unittest
from contextlib import redirect_stderr, redirect_stdout
from pathlib import Path
from unittest import mock

from tooling.api import flavours as api_flavours
from tooling.validation import flavour_api as gate
from tooling.validation import lua_references as references
from tooling.validation.interface_numbers import load_supported_clients
from tooling.validation.validate_manifests import ROOT


KNOWN_FLAVOURS = ("retail", "classic-era", "classic-mop", "ptr", "beta")


def surface(names=(), methods=(), events=()) -> gate.FlavourSurface:
    return gate.FlavourSurface("retail", frozenset(names), frozenset(methods), frozenset(events))


def reference(name: str, kind: str = references.KIND_GLOBAL, uses=(), line: int = 10) -> references.Reference:
    found = references.Reference("packages/sampleKit/src/SampleKit.lua", line, 1, kind, name)
    for use_line, alternatives in uses:
        found.unguarded_uses.append(references.Use(use_line, "called", tuple(alternatives)))
    return found


def finding(name: str, kind: str = references.KIND_GLOBAL, uses=()) -> gate.Finding:
    result = gate.Finding("sampleKit", kind, name)
    result.references.append(reference(name, kind, uses))
    return result


class SurfaceTests(unittest.TestCase):
    def test_committed_retail_metadata_documents_the_basics(self):
        retail = gate.metadata_surface("retail")

        self.assertTrue(retail.provides(references.KIND_GLOBAL, "C_Timer"))
        self.assertTrue(retail.provides(references.KIND_MEMBER, "C_Timer.After"))
        self.assertTrue(retail.provides(references.KIND_GLOBAL, "Enum"))
        self.assertTrue(retail.provides(references.KIND_GLOBAL, "Constants"))
        self.assertTrue(retail.provides(references.KIND_EVENT, "PLAYER_LOGIN"))
        self.assertTrue(retail.provides(references.KIND_METHOD, "SetPoint"))
        self.assertFalse(retail.provides(references.KIND_DYNAMIC, "C_Timer"))

    def test_unknown_flavour_directory_is_a_gate_error(self):
        with tempfile.TemporaryDirectory() as directory:
            with self.assertRaises(gate.GateError):
                gate.metadata_surface("retail", Path(directory))


class VerdictTests(unittest.TestCase):
    def test_documented_name_is_present_even_when_unguarded(self):
        verdict = gate.judge(finding("C_Timer", uses=[(3, ["C_Timer"])]), "retail", set(), surface(["C_Timer"]))

        self.assertEqual(gate.PRESENT, verdict)

    def test_curated_name_is_present(self):
        verdict = gate.judge(finding("CreateFrame", uses=[(3, ["CreateFrame"])]), "retail", {"CreateFrame"}, surface())

        self.assertEqual(gate.PRESENT, verdict)

    def test_absent_but_guarded(self):
        self.assertEqual(gate.GUARDED, gate.judge(finding("Missing"), "retail", set(), surface()))

    def test_absent_and_unguarded_is_missing(self):
        verdict = gate.judge(finding("Missing", uses=[(3, ["Missing"])]), "retail", set(), surface())

        self.assertEqual(gate.MISSING, verdict)

    def test_alternative_present_is_a_fallback(self):
        unpack = finding("table.unpack", references.KIND_MEMBER, uses=[(3, ["table.unpack", "unpack"])])

        self.assertEqual(gate.FALLBACK, gate.judge(unpack, "retail", {"unpack"}, surface()))
        self.assertEqual(gate.MISSING, gate.judge(unpack, "retail", set(), surface()))

    def test_dynamic_reference_is_never_present(self):
        dynamic = finding("readGlobal(…)", references.KIND_DYNAMIC, uses=[(3, ["readGlobal(…)"])])

        self.assertEqual(gate.MISSING, gate.judge(dynamic, "retail", {"readGlobal(…)"}, surface()))

    def test_methods_and_events_use_their_own_tables(self):
        method = finding("SetFixedFrameStrata", references.KIND_METHOD, uses=[(3, ["SetFixedFrameStrata"])])
        event = finding("PLAYER_LOGIN", references.KIND_EVENT, uses=[(3, ["PLAYER_LOGIN"])])

        self.assertEqual(gate.PRESENT, gate.judge(method, "retail", set(), surface(methods=["SetFixedFrameStrata"])))
        self.assertEqual(gate.MISSING, gate.judge(method, "retail", set(), surface(names=["SetFixedFrameStrata"])))
        self.assertEqual(gate.PRESENT, gate.judge(event, "retail", set(), surface(events=["PLAYER_LOGIN"])))


class HostNamesTests(unittest.TestCase):
    def valid(self) -> dict:
        return {
            "verified": "2026-09-25",
            "framework": {"reason": "own globals", "names": ["MoltenCodes"]},
            "lua": {"source": "Lua 5.1 manual", "names": ["pairs"]},
            "client": [{"name": "CreateFrame", "source": "used at load", "evidence": {"retail": "File.lua:1"}}],
        }

    def test_committed_table_parses(self):
        names = gate.load_host_names(KNOWN_FLAVOURS)

        self.assertIn("MoltenCodes", names.framework)
        self.assertIn("string.format", names.provided_on("classic-era"))
        self.assertIn("CreateFrame", names.provided_on("classic-mop"))

    def test_provided_on_respects_evidence(self):
        names = gate.parse_host_names(self.valid(), KNOWN_FLAVOURS)

        self.assertEqual({"pairs", "CreateFrame"}, set(names.provided_on("retail")))
        self.assertEqual({"pairs"}, set(names.provided_on("classic-era")))

    def test_rejections(self):
        cases = {
            "unknown flavour": lambda data: data["client"][0]["evidence"].update({"tbc": "File.lua:1"}),
            "missing source": lambda data: data["client"][0].pop("source"),
            "duplicate": lambda data: data["client"].append(copy.deepcopy(data["client"][0])),
            "empty lua source": lambda data: data["lua"].update({"source": " "}),
            "duplicate lua name": lambda data: data["lua"]["names"].append("pairs"),
            "no evidence": lambda data: data["client"][0].update({"evidence": {}}),
        }
        for label, change in cases.items():
            with self.subTest(label):
                data = self.valid()
                change(data)
                with self.assertRaises(gate.GateError):
                    gate.parse_host_names(data, KNOWN_FLAVOURS)


class AllowListTests(unittest.TestCase):
    def entry(self, **overrides) -> dict:
        entry = {
            "package": "clientKit",
            "api": "GetSpellInfo",
            "flavours": ["retail"],
            "guard": "packages/clientKit/src/ClientKit.lua:1",
            "reason": "tested by its only reader",
        }
        entry.update(overrides)
        return entry

    def parse(self, *entries: dict) -> list[gate.AllowEntry]:
        return gate.parse_allowlist({"entries": list(entries)}, KNOWN_FLAVOURS)

    def test_committed_allowlist_parses(self):
        entries = gate.load_allowlist(KNOWN_FLAVOURS)

        for entry in entries:
            self.assertTrue(entry.reason.strip())

    def test_shape_rejections(self):
        cases = {
            "unknown key": self.entry(note="x"),
            "empty reason": self.entry(reason=""),
            "no flavours": self.entry(flavours=[]),
            "unknown flavour": self.entry(flavours=["tbc"]),
            "repeated flavour": self.entry(flavours=["retail", "retail"]),
        }
        for label, entry in cases.items():
            with self.subTest(label):
                with self.assertRaises(gate.GateError):
                    self.parse(entry)
        with self.assertRaises(gate.GateError):
            self.parse(self.entry(), self.entry())

    def findings(self, verdict: str) -> dict[str, list[gate.Finding]]:
        spell = finding("GetSpellInfo", uses=[(3, ["GetSpellInfo"])])
        spell.package = "clientKit"
        spell.verdicts["retail"] = verdict
        return {"clientKit": [spell]}

    def test_entry_turns_a_miss_into_allowed(self):
        findings = self.findings(gate.MISSING)

        errors = gate.apply_allowlist(self.parse(self.entry()), findings, None)

        self.assertEqual([], errors)
        self.assertEqual(gate.ALLOWED, findings["clientKit"][0].verdicts["retail"])

    def test_entry_is_stale_once_the_name_is_present(self):
        errors = gate.apply_allowlist(self.parse(self.entry()), self.findings(gate.PRESENT), None)

        self.assertEqual(1, len(errors))
        self.assertIn("stale for retail", errors[0])

    def test_entry_is_stale_once_the_reference_is_gone(self):
        errors = gate.apply_allowlist(self.parse(self.entry(api="GetItemInfo")), self.findings(gate.MISSING), None)

        self.assertIn("no longer references GetItemInfo", errors[0])

    def test_guard_must_be_a_line_of_the_package(self):
        cases = {
            "other package": "packages/commKit/src/CommKit.lua:1",
            "no line": "packages/clientKit/src/ClientKit.lua",
            "past the end": "packages/clientKit/src/ClientKit.lua:999999",
            "missing file": "packages/clientKit/src/Missing.lua:1",
        }
        for label, guard in cases.items():
            with self.subTest(label):
                errors = gate.apply_allowlist(
                    self.parse(self.entry(guard=guard)), self.findings(gate.MISSING), None
                )
                self.assertTrue(any("guard" in error for error in errors), errors)

    def test_entries_of_unscanned_packages_are_not_judged(self):
        errors = gate.apply_allowlist(self.parse(self.entry()), {}, ["commKit"])

        self.assertEqual([], errors)


class FlavourResolutionTests(unittest.TestCase):
    def test_every_supported_client_is_mapped(self):
        for client in load_supported_clients().clients:
            with self.subTest(client=client.flavour):
                self.assertIn(client.toc_suffix, gate.CLIENT_FLAVOURS)

    def test_promised_report_only_and_not_captured(self):
        promised, report_only, not_captured, errors = gate.resolve_flavours(list(KNOWN_FLAVOURS))

        self.assertEqual([], errors)
        self.assertEqual({"retail", "classic-mop", "classic-era"}, {flavour for flavour, _ in promised})
        self.assertEqual(["ptr", "beta"], [flavour for flavour, _ in report_only])
        self.assertTrue(any("Anniversary" in name for name in not_captured))

    def test_promised_client_without_metadata_is_an_error(self):
        _, _, _, errors = gate.resolve_flavours(["retail", "classic-mop"])

        self.assertTrue(any("Classic Era" in error for error in errors), errors)

    def test_generated_flavour_files_are_excluded(self):
        excluded = gate.excluded_sources()
        runtime_files = {flavour.runtime_file for flavour in api_flavours.load_flavours().flavours}

        self.assertEqual(len(runtime_files), len(excluded))
        for path in excluded:
            self.assertTrue(path.is_file(), path)


class ScanTests(unittest.TestCase):
    def test_framework_globals_are_not_host_references(self):
        found = [
            reference("MoltenCodes.Registry", references.KIND_MEMBER),
            reference("MoltenCodes", references.KIND_GLOBAL),
            reference("CreateFrame"),
        ]

        grouped = gate._group("sampleKit", found, frozenset({"MoltenCodes"}))

        self.assertEqual(["CreateFrame"], [item.name for item in grouped])

    def test_scan_package_reads_sources(self):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            source = root / "packages" / "sampleKit" / "src"
            source.mkdir(parents=True)
            (source / "SampleKit.lua").write_text('local f = rawget(_G, "HostFunction")\nf()\n', encoding="utf-8")

            found = gate.scan_package(root / "packages" / "sampleKit", {}, frozenset(), frozenset(), root)

        self.assertEqual(["HostFunction"], [item.name for item in found])
        self.assertEqual("packages/sampleKit/src/SampleKit.lua", found[0].file)

    def test_syntax_error_is_a_gate_error(self):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            source = root / "packages" / "sampleKit" / "src"
            source.mkdir(parents=True)
            (source / "SampleKit.lua").write_text("local = 1\n", encoding="utf-8")

            with self.assertRaises(gate.GateError) as raised:
                gate.scan_package(root / "packages" / "sampleKit", {}, frozenset(), frozenset(), root)

        self.assertIn("SampleKit.lua:1:7", str(raised.exception))


class ReportTests(unittest.TestCase):
    def report(self, verdict: str) -> gate.Report:
        item = finding("Missing", uses=[(3, ["Missing"])])
        item.verdicts = {"retail": verdict, "ptr": gate.MISSING}
        return gate.Report(
            promised=[("retail", "Retail")],
            report_only=[("ptr", "Public Test Realm")],
            not_captured=["Anniversary"],
            findings={"sampleKit": [item]},
            errors=[],
        )

    def test_missing_on_a_promised_flavour_fails(self):
        report = self.report(gate.MISSING)
        lines = gate.format_report(report)

        self.assertFalse(report.passed)
        self.assertIn("    MISSING       global Missing", lines)
        self.assertIn(
            "                  unguarded use at packages/sampleKit/src/SampleKit.lua:3 (called)", lines
        )
        self.assertTrue(lines[-2].startswith("Result: FAILED. 1 missing"))

    def test_report_only_flavour_never_fails(self):
        report = self.report(gate.GUARDED)

        self.assertTrue(report.passed)
        self.assertIn("(report only)", "\n".join(gate.format_report(report)))

    def test_main_exit_status(self):
        for verdict, status in ((gate.GUARDED, 0), (gate.MISSING, 1)):
            with self.subTest(verdict=verdict):
                output, errors = io.StringIO(), io.StringIO()
                with mock.patch.object(gate, "run_gate", return_value=self.report(verdict)):
                    with redirect_stdout(output), redirect_stderr(errors):
                        self.assertEqual(status, gate.main([]))

    def test_gate_error_exits_one(self):
        errors = io.StringIO()
        with mock.patch.object(gate, "run_gate", side_effect=gate.GateError("broken table")):
            with redirect_stderr(errors):
                self.assertEqual(1, gate.main([]))

        self.assertIn("error: broken table", errors.getvalue())


class CommittedTablesTests(unittest.TestCase):
    def test_tables_are_formatted_json(self):
        for path in (gate.HOST_NAMES_PATH, gate.ALLOWLIST_PATH):
            with self.subTest(path=path.name):
                data = json.loads(path.read_text(encoding="utf-8"))
                self.assertIsInstance(data, dict)
                self.assertTrue(path.is_relative_to(ROOT))


if __name__ == "__main__":
    unittest.main()
