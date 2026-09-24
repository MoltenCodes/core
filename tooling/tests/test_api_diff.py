"""Tests for the apiKit build-to-build metadata comparison, report and history."""

from __future__ import annotations

import dataclasses
import io
import json
import os
import tempfile
import unittest
from contextlib import redirect_stderr, redirect_stdout
from pathlib import Path
from typing import Any

from tooling.api import diff as module
from tooling.api import model
from tooling.tests.test_api_model import sample_metadata, sample_provenance


#: A real metadata directory to self-diff, when one is available on this machine.
CORPUS_ENV = "MOLTENCODES_API_METADATA"
CORPUS_DIRECTORY = Path(os.environ.get(CORPUS_ENV, "")) if os.environ.get(CORPUS_ENV) else None


def later_provenance() -> model.Provenance:
    return dataclasses.replace(
        sample_provenance(),
        commit="b" * 40,
        committed_at="2026-10-01T09:00:00Z",
        subject="12.1.1 (70001)",
        version="12.1.1",
        build=70001,
        captured_on="2026-10-02",
    )


def later(metadata: model.FlavourMetadata, **changes: Any) -> model.FlavourMetadata:
    """The sample metadata as a later capture, with the given top-level fields replaced."""
    return dataclasses.replace(metadata, provenance=later_provenance(), **changes)


def replace_namespace(
    metadata: model.FlavourMetadata, wrapper: str, **changes: Any
) -> model.FlavourMetadata:
    namespaces = tuple(
        dataclasses.replace(namespace, **changes) if namespace.wrapper == wrapper else namespace
        for namespace in metadata.namespaces
    )
    return later(metadata, namespaces=namespaces)


def measure_call(metadata: model.FlavourMetadata) -> model.Function:
    return next(namespace for namespace in metadata.namespaces if namespace.wrapper == "addOnProfiler").functions[0]


def replace_measure_call(metadata: model.FlavourMetadata, **changes: Any) -> model.FlavourMetadata:
    """The sample metadata with `addOnProfiler.measureCall` replaced field by field."""
    function = dataclasses.replace(measure_call(metadata), **changes)
    return replace_namespace(metadata, "addOnProfiler", functions=(function,))


def replace_argument(function: model.Function, name: str, **changes: Any) -> tuple[model.Parameter, ...]:
    return tuple(
        dataclasses.replace(argument, **changes) if argument.name == name else argument
        for argument in function.arguments
    )


def replace_enum(metadata: model.FlavourMetadata, **changes: Any) -> model.FlavourMetadata:
    return later(metadata, enums=(dataclasses.replace(metadata.enums[0], **changes),))


def with_constants(metadata: model.FlavourMetadata, *values: model.ConstantValue) -> model.FlavourMetadata:
    """The metadata with the single constants table holding exactly `values`; provenance untouched."""
    return dataclasses.replace(metadata, constants=(dataclasses.replace(metadata.constants[0], values=values),))


def replace_constants(metadata: model.FlavourMetadata, *values: model.ConstantValue) -> model.FlavourMetadata:
    return later(with_constants(metadata, *values))


def changes_of(diff: module.Diff, kind: str, change: str) -> list[module.Change]:
    return [entry for entry in diff.changes if entry.kind == kind and entry.change == change]


def only_change(diff: module.Diff) -> module.Change:
    """The single change a test expects; fails loudly when the diff has more."""
    if len(diff.changes) != 1:
        raise AssertionError(f"expected exactly one change, got {diff.changes}")
    return diff.changes[0]


class EmptyDiffTests(unittest.TestCase):
    def test_identical_metadata_has_no_changes(self):
        diff = module.diff_metadata(sample_metadata(), sample_metadata())

        self.assertTrue(diff.is_empty())
        self.assertEqual((), diff.changes)
        self.assertEqual({}, diff.counts())

    def test_provenance_differences_are_not_changes(self):
        diff = module.diff_metadata(sample_metadata(), later(sample_metadata()))

        self.assertTrue(diff.is_empty())
        self.assertEqual(70001, diff.new.build)

    def test_empty_report_is_one_paragraph(self):
        report = module.render_change_report(module.diff_metadata(sample_metadata(), later(sample_metadata())))

        self.assertIn("# retail: 12.1.0 (69933) → 12.1.1 (70001)", report)
        self.assertIn("No API differences between the two captures.", report)
        self.assertNotIn("## Summary", report)

    def test_source_file_moves_are_not_changes(self):
        after = replace_measure_call(sample_metadata(), source="Elsewhere.lua")

        self.assertTrue(module.diff_metadata(sample_metadata(), after).is_empty())


class NamespaceTests(unittest.TestCase):
    def test_added_and_removed_by_wrapper(self):
        before = sample_metadata()
        renamed = dataclasses.replace(before.namespaces[1], wrapper="timer")
        after = later(before, namespaces=(before.namespaces[0], renamed))

        diff = module.diff_metadata(before, after)

        self.assertEqual([module.Change("namespace", "added", "timer")], changes_of(diff, "namespace", "added"))
        self.assertEqual([module.Change("namespace", "removed", "clock")], changes_of(diff, "namespace", "removed"))
        self.assertEqual(["timer.now"], [change.name for change in changes_of(diff, "function", "added")])
        self.assertEqual(["clock.now"], [change.name for change in changes_of(diff, "function", "removed")])

    def test_alias_change(self):
        after = replace_namespace(sample_metadata(), "addOnProfiler", alias="prof")

        change = only_change(module.diff_metadata(sample_metadata(), after))

        self.assertEqual(module.Change("namespace", "changed", "addOnProfiler", ("alias profiler → prof",)), change)

    def test_alias_removed_and_environment_added(self):
        after = replace_namespace(sample_metadata(), "clock", environment="Secure")
        after = replace_namespace(after, "addOnProfiler", alias=None)

        diff = module.diff_metadata(sample_metadata(), after)

        self.assertEqual(
            [("addOnProfiler", ("alias removed: profiler",)), ("clock", ("environment added: Secure",))],
            [(change.name, change.details) for change in diff.changes],
        )

    def test_documentation_only_change(self):
        after = replace_namespace(sample_metadata(), "clock", documentation=("Tells the time.",))

        change = only_change(module.diff_metadata(sample_metadata(), after))

        self.assertEqual(("documentation changed",), change.details)


class FunctionTests(unittest.TestCase):
    def detail_for(self, **changes: Any) -> tuple[str, ...]:
        after = replace_measure_call(sample_metadata(), **changes)
        change = only_change(module.diff_metadata(sample_metadata(), after))
        self.assertEqual(("function", "changed", "addOnProfiler.measureCall"), (change.kind, change.change, change.name))
        return change.details

    def test_argument_type_change(self):
        arguments = replace_argument(measure_call(sample_metadata()), "label", type="string")

        self.assertEqual(("argument label: type cstring → string",), self.detail_for(arguments=arguments))

    def test_return_nilable_change(self):
        returns = (dataclasses.replace(measure_call(sample_metadata()).returns[0], nilable=True),)

        self.assertEqual(("return elapsed: nilable false → true",), self.detail_for(returns=returns))

    def test_default_added(self):
        arguments = replace_argument(measure_call(sample_metadata()), "callback", has_default=True, default=0)

        self.assertEqual(("argument callback: default added: 0",), self.detail_for(arguments=arguments))

    def test_default_removed(self):
        arguments = replace_argument(measure_call(sample_metadata()), "label", has_default=False, default=None)

        self.assertEqual(("argument label: default removed: x",), self.detail_for(arguments=arguments))

    def test_default_changed_to_false_is_still_reported(self):
        arguments = replace_argument(measure_call(sample_metadata()), "label", default=False)

        self.assertEqual(("argument label: default x → false",), self.detail_for(arguments=arguments))

    def test_binding_change(self):
        self.assertEqual(
            ("binding C_AddOnProfiler.MeasureCall → C_AddOnProfiler.Measure",),
            self.detail_for(binding="C_AddOnProfiler.Measure"),
        )

    def test_flags_added_and_removed(self):
        self.assertEqual(
            ("flags: +RequiresX -RequiresClubsInitialized",), self.detail_for(flags=("RequiresX",))
        )

    def test_attribute_change(self):
        self.assertEqual(
            ("attribute FailureMode ReturnNothing → Error",), self.detail_for(attributes={"FailureMode": "Error"})
        )

    def test_boolean_markers(self):
        self.assertEqual(("mayReturnNothing true → false",), self.detail_for(may_return_nothing=False))
        self.assertEqual(("isProtected false → true",), self.detail_for(is_protected=True))
        self.assertEqual(("hasRestrictions false → true",), self.detail_for(has_restrictions=True))

    def test_argument_added_removed_and_reordered(self):
        function = measure_call(sample_metadata())
        callback, label = function.arguments
        extra = model.Parameter(name="count", type="number")

        self.assertEqual(
            ("argument count added: number", "argument order: callback, label → label, callback"),
            self.detail_for(arguments=(label, extra, callback)),
        )
        self.assertEqual(("argument label removed: cstring",), self.detail_for(arguments=(callback,)))

    def test_documentation_only_change_on_function(self):
        self.assertEqual(("documentation changed",), self.detail_for(documentation=("Times a call.",)))

    def test_documentation_only_change_on_a_parameter(self):
        arguments = replace_argument(measure_call(sample_metadata()), "callback", documentation=("Other words.",))

        self.assertEqual(("documentation changed",), self.detail_for(arguments=arguments))

    def test_several_details_are_ordered_code_first(self):
        arguments = replace_argument(measure_call(sample_metadata()), "label", type="string", documentation=("Doc.",))

        self.assertEqual(
            ("binding C_AddOnProfiler.MeasureCall → C_A.B", "argument label: type cstring → string"),
            self.detail_for(binding="C_A.B", arguments=arguments),
        )

    def test_function_added_inside_existing_namespace(self):
        before = sample_metadata()
        new_function = model.Function(name="Reset", wrapper="reset", binding="C_AddOnProfiler.Reset")
        after = replace_namespace(before, "addOnProfiler", functions=(measure_call(before), new_function))

        change = only_change(module.diff_metadata(before, after))

        self.assertEqual(module.Change("function", "added", "addOnProfiler.reset"), change)


class EventTests(unittest.TestCase):
    def test_event_keyed_by_literal_name(self):
        before = sample_metadata()
        event = dataclasses.replace(before.events[0], name="AddOnLoaded", wrapper="addOnLoaded")
        after = later(before, events=(event,))

        change = only_change(module.diff_metadata(before, after))

        self.assertEqual("ADDON_LOADED", change.name)
        self.assertEqual(("name AddonLoaded → AddOnLoaded", "wrapper addonLoaded → addOnLoaded"), change.details)

    def test_payload_and_markers(self):
        before = sample_metadata()
        payload = (model.Parameter(name="addOnName", type="cstring", nilable=True), model.Parameter("failed", "bool"))
        after = later(before, events=(dataclasses.replace(before.events[0], payload=payload, synchronous=False),))

        change = only_change(module.diff_metadata(before, after))

        self.assertEqual(
            ("payload failed added: bool", "payload addOnName: nilable false → true", "synchronous true → false"),
            change.details,
        )

    def test_event_added_and_removed(self):
        before = sample_metadata()
        new_event = model.Event(name="PlayerLogin", wrapper="playerLogin", literal_name="PLAYER_LOGIN", system="System")

        diff = module.diff_metadata(before, later(before, events=(new_event,)))

        self.assertEqual(
            [module.Change("event", "added", "PLAYER_LOGIN"), module.Change("event", "removed", "ADDON_LOADED")],
            list(diff.changes),
        )


class EnumTests(unittest.TestCase):
    def test_field_value_change(self):
        fields = (model.EnumField("Phasing", 0), model.EnumField("Sharding", 2, ("Shards.",)))

        change = only_change(module.diff_metadata(sample_metadata(), replace_enum(sample_metadata(), fields=fields)))

        self.assertEqual(module.Change("enumField", "changed", "Enum.PhaseReason.Sharding", ("value 1 → 2",)), change)

    def test_field_added_and_bounds_change(self):
        before = sample_metadata()
        fields = before.enums[0].fields + (model.EnumField("Warmode", 2),)
        after = replace_enum(before, fields=fields, num_values=3, max_value=2)

        diff = module.diff_metadata(before, after)

        self.assertEqual(
            [
                module.Change("enum", "changed", "Enum.PhaseReason", ("numValues 2 → 3", "maxValue 1 → 2")),
                module.Change("enumField", "added", "Enum.PhaseReason.Warmode"),
            ],
            list(diff.changes),
        )

    def test_field_removed(self):
        after = replace_enum(sample_metadata(), fields=(model.EnumField("Phasing", 0),))

        self.assertEqual(
            module.Change("enumField", "removed", "Enum.PhaseReason.Sharding"),
            only_change(module.diff_metadata(sample_metadata(), after)),
        )

    def test_field_documentation_only(self):
        fields = (model.EnumField("Phasing", 0), model.EnumField("Sharding", 1, ("Other.",)))

        change = only_change(module.diff_metadata(sample_metadata(), replace_enum(sample_metadata(), fields=fields)))

        self.assertEqual(("documentation changed",), change.details)

    def test_removed_enum_lists_its_fields(self):
        diff = module.diff_metadata(sample_metadata(), later(sample_metadata(), enums=()))

        self.assertEqual(
            ["Enum.PhaseReason", "Enum.PhaseReason.Phasing", "Enum.PhaseReason.Sharding"],
            [change.name for change in diff.changes],
        )
        self.assertEqual({"enum": {"added": 0, "removed": 1, "changed": 0}, "enumField": {"added": 0, "removed": 2, "changed": 0}}, diff.counts())


class StructureAndCallbackTests(unittest.TestCase):
    def test_structure_field_change(self):
        before = sample_metadata()
        fields = (model.Parameter("x", "number"), model.Parameter("y", "number", nilable=True, has_default=True, default=0))
        after = later(before, structures=(dataclasses.replace(before.structures[0], fields=fields),))

        change = only_change(module.diff_metadata(before, after))

        self.assertEqual(
            module.Change("structure", "changed", "Point", ("field y: nilable false → true", "field y: default added: 0")),
            change,
        )

    def test_structure_field_inner_type_and_mixin(self):
        before = sample_metadata()
        fields = (model.Parameter("x", "table", inner_type="Point", mixin="PointMixin"), before.structures[0].fields[1])
        after = later(before, structures=(dataclasses.replace(before.structures[0], fields=fields),))

        change = only_change(module.diff_metadata(before, after))

        self.assertEqual(
            ("field x: type number → table", "field x: innerType added: Point", "field x: mixin added: PointMixin"),
            change.details,
        )

    def test_callback_argument_change(self):
        before = sample_metadata()
        callback = dataclasses.replace(before.callbacks[0], arguments=(model.Parameter("value", "string"),))

        change = only_change(module.diff_metadata(before, later(before, callbacks=(callback,))))

        self.assertEqual(module.Change("callback", "changed", "MeasureCallback", ("argument value: type number → string",)), change)

    def test_callback_return_added(self):
        before = sample_metadata()
        callback = dataclasses.replace(before.callbacks[0], returns=(model.Parameter("ok", "bool"),))

        change = only_change(module.diff_metadata(before, later(before, callbacks=(callback,))))

        self.assertEqual(("return ok added: bool",), change.details)


class ConstantsTests(unittest.TestCase):
    def test_value_change(self):
        after = replace_constants(sample_metadata(), model.ConstantValue("DEFAULT_MULTIPLIER", "number", 2))

        change = only_change(module.diff_metadata(sample_metadata(), after))

        self.assertEqual(
            module.Change("constant", "changed", "Constants.AuctionConstants.DEFAULT_MULTIPLIER", ("value 1.5 → 2",)),
            change,
        )

    def test_expression_change(self):
        before = with_constants(sample_metadata(), model.ConstantValue("LAST", "number", expression="Enum.Kind.A"))
        after = later(with_constants(before, model.ConstantValue("LAST", "number", expression="Enum.Kind.B")))

        change = only_change(module.diff_metadata(before, after))

        self.assertEqual(("expression Enum.Kind.A → Enum.Kind.B",), change.details)

    def test_literal_becomes_expression(self):
        after = replace_constants(
            sample_metadata(), model.ConstantValue("DEFAULT_MULTIPLIER", "number", expression="Constants.X.Y + 1")
        )

        change = only_change(module.diff_metadata(sample_metadata(), after))

        self.assertEqual(("value 1.5 → expression Constants.X.Y + 1",), change.details)

    def test_constant_added_and_type_change(self):
        after = replace_constants(
            sample_metadata(),
            model.ConstantValue("DEFAULT_MULTIPLIER", "luaIndex", 1.5),
            model.ConstantValue("MAXIMUM", "number", 10),
        )

        diff = module.diff_metadata(sample_metadata(), after)

        self.assertEqual(
            [
                module.Change("constant", "added", "Constants.AuctionConstants.MAXIMUM"),
                module.Change(
                    "constant", "changed", "Constants.AuctionConstants.DEFAULT_MULTIPLIER", ("type number → luaIndex",)
                ),
            ],
            list(diff.changes),
        )

    def test_table_wrapper_change_is_on_the_table(self):
        before = sample_metadata()
        table = dataclasses.replace(before.constants[0], wrapper="auction")

        change = only_change(module.diff_metadata(before, later(before, constants=(table,))))

        self.assertEqual(
            module.Change("constantsTable", "changed", "Constants.AuctionConstants", ("wrapper auctionConstants → auction",)),
            change,
        )


class RestrictionTests(unittest.TestCase):
    def test_failure_mode_change(self):
        before = sample_metadata()
        restriction = dataclasses.replace(before.restrictions[0], failure_mode="ReturnNothing")

        change = only_change(module.diff_metadata(before, later(before, restrictions=(restriction,))))

        self.assertEqual(
            module.Change("restriction", "changed", "HasRestrictions", ("failureMode Error → ReturnNothing",)), change
        )

    def test_key_includes_the_system(self):
        before = sample_metadata()
        restriction = model.Restriction(name="HasRestrictions", kind="secret", system="AddOns")

        diff = module.diff_metadata(before, later(before, restrictions=before.restrictions + (restriction,)))

        self.assertEqual(module.Change("restriction", "added", "AddOns/HasRestrictions"), only_change(diff))


class OrderingAndCountsTests(unittest.TestCase):
    def mixed_diff(self) -> module.Diff:
        before = sample_metadata()
        after = replace_measure_call(before, binding="C_AddOnProfiler.Measure")
        after = dataclasses.replace(
            after,
            events=(),
            enums=after.enums + (model.Enum(name="Aa", wrapper="aa", fields=(model.EnumField("One", 1),)),),
            restrictions=(dataclasses.replace(before.restrictions[0], kind="secret"),),
        )
        return module.diff_metadata(before, after)

    def test_changes_are_sorted_by_kind_change_and_name(self):
        diff = self.mixed_diff()

        self.assertEqual(
            [
                ("function", "changed", "addOnProfiler.measureCall"),
                ("event", "removed", "ADDON_LOADED"),
                ("enum", "added", "Enum.Aa"),
                ("enumField", "added", "Enum.Aa.One"),
                ("restriction", "changed", "HasRestrictions"),
            ],
            [(change.kind, change.change, change.name) for change in diff.changes],
        )

    def test_counts_omit_untouched_kinds(self):
        self.assertEqual(
            {
                "function": {"added": 0, "removed": 0, "changed": 1},
                "event": {"added": 0, "removed": 1, "changed": 0},
                "enum": {"added": 1, "removed": 0, "changed": 0},
                "enumField": {"added": 1, "removed": 0, "changed": 0},
                "restriction": {"added": 0, "removed": 0, "changed": 1},
            },
            self.mixed_diff().counts(),
        )

    def test_diff_is_deterministic(self):
        self.assertEqual(self.mixed_diff(), self.mixed_diff())


class ReportTests(unittest.TestCase):
    def report(self) -> str:
        before = sample_metadata()
        arguments = replace_argument(measure_call(before), "label", type="string")
        after = replace_measure_call(before, arguments=arguments, flags=("RequiresX",))
        after = dataclasses.replace(after, events=(), enums=after.enums + (model.Enum(name="Aa", wrapper="aa", fields=()),))
        return module.render_change_report(module.diff_metadata(before, after))

    def test_title_and_provenance(self):
        report = self.report()

        self.assertTrue(report.startswith("# retail: 12.1.0 (69933) → 12.1.1 (70001)\n"))
        self.assertIn("| Commit | " + "a" * 40 + " | " + "b" * 40 + " |", report)
        self.assertIn("| Captured on | 2026-09-24 | 2026-10-02 |", report)
        self.assertIn("| Repository | Example/wow-ui-source | Example/wow-ui-source |", report)

    def test_summary_and_sections(self):
        report = self.report()

        self.assertIn("## Summary\n\n| Kind | Added | Removed | Changed |\n|---|---|---|---|\n| Functions | 0 | 0 | 1 |\n| Events | 0 | 1 | 0 |\n| Enums | 1 | 0 | 0 |\n", report)
        self.assertIn("## Functions\n\n### Changed\n\n- `addOnProfiler.measureCall`\n  - argument label: type cstring → string\n  - flags: +RequiresX -RequiresClubsInitialized\n", report)
        self.assertIn("## Events\n\n### Removed\n\n- `ADDON_LOADED`\n", report)
        self.assertIn("## Enums\n\n### Added\n\n- `Enum.Aa`\n", report)
        self.assertNotIn("## Structures", report)
        self.assertTrue(report.endswith("\n"))
        self.assertFalse(report.endswith("\n\n"))

    def test_report_is_deterministic(self):
        self.assertEqual(self.report(), self.report())

    def test_unknown_version_and_build_fall_back_to_the_commit(self):
        before = sample_metadata()
        unknown = dataclasses.replace(later_provenance(), version=None, build=None)
        diff = module.diff_metadata(before, dataclasses.replace(before, provenance=unknown))

        self.assertIn(f"→ unknown version ({'b' * 12})", module.render_change_report(diff))


class FileNameTests(unittest.TestCase):
    def test_builds(self):
        diff = module.diff_metadata(sample_metadata(), later(sample_metadata()))

        self.assertEqual("69933-70001.md", module.diff_file_name(diff))

    def test_missing_build_uses_the_short_commit(self):
        before = sample_metadata()
        unknown = dataclasses.replace(later_provenance(), build=None)
        diff = module.diff_metadata(before, dataclasses.replace(before, provenance=unknown))

        self.assertEqual(f"69933-{'b' * 12}.md", module.diff_file_name(diff))


class HistoryTests(unittest.TestCase):
    def setUp(self):
        self.tempdir = tempfile.TemporaryDirectory()
        self.path = Path(self.tempdir.name) / module.HISTORY_FILE

    def tearDown(self):
        self.tempdir.cleanup()

    def first_entry(self) -> module.HistoryEntry:
        return module.HistoryEntry.from_provenance(sample_provenance(), {}, None)

    def second_entry(self) -> module.HistoryEntry:
        counts = {"function": {"added": 1, "removed": 0, "changed": 0}}
        return module.HistoryEntry.from_provenance(later_provenance(), counts, "docs/changes/retail/69933-70001.md")

    def test_missing_file_is_empty(self):
        self.assertEqual([], module.read_history(self.path))

    def test_append_writes_camel_case_json(self):
        module.append_history(self.path, self.first_entry())

        data = json.loads(self.path.read_text(encoding="utf-8"))
        self.assertEqual(1, data["schema"])
        self.assertEqual(
            [{"build": 69933, "capturedOn": "2026-09-24", "commit": "a" * 40, "committedAt": "2026-09-22T14:31:12Z", "version": "12.1.0"}],
            data["entries"],
        )

    def test_append_then_read_round_trips(self):
        module.append_history(self.path, self.first_entry())
        entries = module.append_history(self.path, self.second_entry())

        self.assertEqual([self.first_entry(), self.second_entry()], entries)
        self.assertEqual(entries, module.read_history(self.path))

    def test_append_is_idempotent_for_the_same_commit(self):
        module.append_history(self.path, self.first_entry())
        first_bytes = self.path.read_bytes()

        entries = module.append_history(self.path, self.first_entry())

        self.assertEqual([self.first_entry()], entries)
        self.assertEqual(first_bytes, self.path.read_bytes())

    def test_malformed_history_is_reported(self):
        self.path.write_text("{", encoding="utf-8")
        with self.assertRaisesRegex(model.MetadataError, "not valid JSON"):
            module.read_history(self.path)

        self.path.write_text('{"schema": 2, "entries": []}', encoding="utf-8")
        with self.assertRaisesRegex(model.MetadataError, "expected schema 1"):
            module.read_history(self.path)

        self.path.write_text('{"schema": 1, "entries": [{"build": 1}]}', encoding="utf-8")
        with self.assertRaisesRegex(model.MetadataError, "entry 0 is malformed"):
            module.read_history(self.path)

        self.path.write_text('{"schema": 1, "entries": {}}', encoding="utf-8")
        with self.assertRaisesRegex(model.MetadataError, "must be a list"):
            module.read_history(self.path)

    def test_json_shape_round_trips(self):
        entries = [self.first_entry(), self.second_entry()]

        self.assertEqual(entries, module.history_from_json(module.history_to_json(entries)))


class CommandLineTests(unittest.TestCase):
    def setUp(self):
        self.tempdir = tempfile.TemporaryDirectory()
        self.root = Path(self.tempdir.name)
        self.old_directory = self.root / "old"
        self.new_directory = self.root / "new"
        model.write_metadata(sample_metadata(), self.old_directory)

    def tearDown(self):
        self.tempdir.cleanup()

    def run_main(self, *argv: str) -> tuple[int, str, str]:
        stdout, stderr = io.StringIO(), io.StringIO()
        with redirect_stdout(stdout), redirect_stderr(stderr):
            status = module.main(list(argv))
        return status, stdout.getvalue(), stderr.getvalue()

    def test_identical_directories(self):
        model.write_metadata(later(sample_metadata()), self.new_directory)

        status, out, err = self.run_main(str(self.old_directory), str(self.new_directory))

        self.assertEqual(0, status)
        self.assertIn("No API differences", out)
        self.assertEqual("", err)

    def test_differences_print_the_summary_and_write_the_report(self):
        model.write_metadata(replace_measure_call(sample_metadata(), binding="C_A.B"), self.new_directory)
        report = self.root / "changes" / "retail" / "69933-70001.md"

        status, out, err = self.run_main(str(self.old_directory), str(self.new_directory), "--report", str(report))

        self.assertEqual(0, status)
        self.assertIn("| Functions | 0 | 0 | 1 |", out)
        self.assertIn("retail: 12.1.0 (69933) → 12.1.1 (70001)", out)
        self.assertTrue(report.exists())
        self.assertIn("binding C_AddOnProfiler.MeasureCall → C_A.B", report.read_text(encoding="utf-8"))

    def test_unreadable_directory_is_status_1(self):
        status, _, err = self.run_main(str(self.old_directory), str(self.root / "missing"))

        self.assertEqual(1, status)
        self.assertIn("error:", err)
        self.assertIn("provenance.json: missing", err)

    def test_different_flavours_is_status_2(self):
        other_flavour = later(sample_metadata())
        other_flavour = dataclasses.replace(other_flavour, provenance=dataclasses.replace(other_flavour.provenance, flavour="classic-era"))
        model.write_metadata(other_flavour, self.new_directory)

        status, _, err = self.run_main(str(self.old_directory), str(self.new_directory))

        self.assertEqual(2, status)
        self.assertIn("cannot compare flavour 'retail' with 'classic-era'", err)


@unittest.skipUnless(
    CORPUS_DIRECTORY is not None and CORPUS_DIRECTORY.is_dir(),
    f"set {CORPUS_ENV} to a normalised metadata directory to self-diff a real capture",
)
class CorpusTests(unittest.TestCase):
    """Smoke test on a real capture: a directory compared with itself has no differences."""

    def test_self_diff_is_empty(self):
        metadata = model.read_metadata(CORPUS_DIRECTORY)
        again = model.read_metadata(CORPUS_DIRECTORY)

        diff = module.diff_metadata(metadata, again)

        self.assertTrue(diff.is_empty(), diff.changes[:5])
        self.assertIn("No API differences", module.render_change_report(diff))

    def test_removing_everything_lists_every_identity_once(self):
        metadata = model.read_metadata(CORPUS_DIRECTORY)
        empty = model.FlavourMetadata(provenance=metadata.provenance)

        diff = module.diff_metadata(metadata, empty)

        names = [(change.kind, change.name) for change in diff.changes]
        self.assertEqual(len(names), len(set(names)))
        self.assertEqual(
            sum(len(namespace.functions) for namespace in metadata.namespaces),
            diff.counts()["function"]["removed"],
        )


if __name__ == "__main__":
    unittest.main()
