"""Tests for the apiKit normaliser, over invented documentation tables."""

from __future__ import annotations

import io
import json
import tempfile
import textwrap
import unittest
from contextlib import redirect_stderr, redirect_stdout
from pathlib import Path

from tooling.api import lua_tables, model, naming
from tooling.api import normalize as module


RULES = naming.parse_naming_rules(
    {
        "words": ["PvP"],
        "namespaceAliases": {"addOnProfiler": "profiler"},
        "namespaceExceptions": {},
        "functionExceptions": {},
    }
)

PROFILER_TABLE = textwrap.dedent(
    """
    local AddOnProfiler =
    {
    \tName = "AddOnProfiler",
    \tType = "System",
    \tNamespace = "C_AddOnProfiler",
    \tEnvironment = "All",

    \tFunctions =
    \t{
    \t\t{
    \t\t\tName = "MeasureCall",
    \t\t\tType = "Function",
    \t\t\tSecretArguments = "AllowedWhenUntainted",
    \t\t\tMayReturnNothing = true,
    \t\t\tRequiresSomething = true,
    \t\t\tNotRelevant = false,
    \t\t\tFailureMode = "ReturnNothing",
    \t\t\tDocumentation = { "Times a call." },

    \t\t\tArguments =
    \t\t\t{
    \t\t\t\t{ Name = "callback", Type = "MeasureCallback", Nilable = false },
    \t\t\t\t{ Name = "label", Type = "cstring", Nilable = true, Default = "x" },
    \t\t\t},

    \t\t\tReturns =
    \t\t\t{
    \t\t\t\t{ Name = "elapsed", Type = "number", Nilable = false, NeverSecret = true },
    \t\t\t},
    \t\t},
    \t},

    \tEvents =
    \t{
    \t\t{
    \t\t\tName = "ProfilerReset",
    \t\t\tType = "Event",
    \t\t\tLiteralName = "PROFILER_RESET",
    \t\t\tSynchronousEvent = true,
    \t\t\tPayload =
    \t\t\t{
    \t\t\t\t{ Name = "reason", Type = "cstring", Nilable = false },
    \t\t\t},
    \t\t},
    \t},

    \tTables =
    \t{
    \t\t{
    \t\t\tName = "MeasureCallback",
    \t\t\tType = "CallbackType",

    \t\t\tArguments =
    \t\t\t{
    \t\t\t\t{ Name = "value", Type = "number", Nilable = false },
    \t\t\t},
    \t\t},
    \t\t{
    \t\t\tName = "Metric",
    \t\t\tType = "Enumeration",
    \t\t\tNumValues = 2,
    \t\t\tMinValue = 0,
    \t\t\tMaxValue = 1,
    \t\t\tFields =
    \t\t\t{
    \t\t\t\t{ Name = "Average", Type = "Metric", EnumValue = 0 },
    \t\t\t\t{ Name = "Peak", Type = "Metric", EnumValue = 1, Documentation = { "The worst tick." } },
    \t\t\t},
    \t\t},
    \t\t{
    \t\t\tName = "Sample",
    \t\t\tType = "Structure",
    \t\t\tFields =
    \t\t\t{
    \t\t\t\t{ Name = "elapsed", Type = "number", Nilable = false },
    \t\t\t\t{ Name = "tags", Type = "table", InnerType = "cstring", Nilable = true },
    \t\t\t},
    \t\t},
    \t},

    \tPredicates =
    \t{
    \t\t{
    \t\t\tName = "HasRestrictions",
    \t\t\tType = "Precondition",
    \t\t\tFailureMode = "Error",
    \t\t},
    \t},
    };

    APIDocumentation:AddDocumentationTable(AddOnProfiler);
    """
)

UNIT_TABLE = textwrap.dedent(
    """
    local Unit =
    {
    \tName = "Unit",
    \tType = "System",
    \tEnvironment = "All",

    \tFunctions =
    \t{
    \t\t{
    \t\t\tName = "UnitName",
    \t\t\tType = "Function",
    \t\t\tArguments = { { Name = "unit", Type = "UnitToken", Nilable = false } },
    \t\t\tReturns = { { Name = "name", Type = "cstring", Nilable = false } },
    \t\t},
    \t\t{
    \t\t\tName = "GetPvPRank",
    \t\t\tType = "Function",
    \t\t\tReturns = { { Name = "rank", Type = "number", Nilable = false } },
    \t\t},
    \t},

    \tEvents = { },
    \tTables = { },
    \tPredicates = { },
    };

    APIDocumentation:AddDocumentationTable(Unit);
    """
)

CONSTANTS_TABLE = textwrap.dedent(
    """
    local UnitConstants =
    {
    \tTables =
    \t{
    \t\t{
    \t\t\tName = "UnitConstants",
    \t\t\tType = "Constants",
    \t\t\tValues =
    \t\t\t{
    \t\t\t\t{ Name = "MAX_UNITS", Type = "number", Value = 40 },
    \t\t\t\t{ Name = "FIRST_UNIT", Type = "Metric", Value = Enum.Metric.Average },
    \t\t\t\t{ Name = "UNIT_COUNT", Type = "number", Value = Constants.UnitConstants.MAX_UNITS - 1 },
    \t\t\t},
    \t\t},
    \t},

    \tPredicates =
    \t{
    \t},
    };

    APIDocumentation:AddDocumentationTable(UnitConstants);
    """
)

CLOCK_OBJECT = textwrap.dedent(
    """
    local ClockAPI =
    {
    \tName = "ClockAPI",
    \tType = "ScriptObject",
    \tObjectType = "Userdata",
    \tEnvironment = "All",

    \tFunctions =
    \t{
    \t\t{
    \t\t\tName = "Now",
    \t\t\tType = "Function",
    \t\t\tReturns = { { Name = "seconds", Type = "number", Nilable = false } },
    \t\t},
    \t},

    \tEvents = { },
    \tTables = { },
    \tPredicates = { },
    };

    APIDocumentation:AddDocumentationTable(ClockAPI);
    """
)


def provenance() -> model.Provenance:
    return model.Provenance(
        flavour="retail",
        repository="Example/mirror",
        branch="live",
        commit="b" * 40,
        committed_at="2026-09-22T00:00:00Z",
        subject="12.1.0 (1)",
        version="12.1.0",
        build=1,
        documentation_path="Interface/Docs",
        captured_on="2026-09-24",
        file_count=1,
    )


def normalise(*sources: tuple[str, str]) -> model.FlavourMetadata:
    normalizer = module.Normalizer(RULES)
    for name, text in sources:
        normalizer.add_file(name, lua_tables.parse_documentation_file(text, where=name))
    return normalizer.build(provenance())


def write_capture(directory: Path, files: dict[str, str]) -> Path:
    """Lay out a capture the way `tooling.api.fetch` does."""
    capture = directory / "retail" / ("b" * 40)
    (capture / "documentation").mkdir(parents=True)
    for name, text in files.items():
        (capture / "documentation" / name).write_text(text, encoding="utf-8")
    capture_json = {
        "flavourId": "retail",
        "repository": "Example/mirror",
        "branch": "live",
        "commit": "b" * 40,
        "committedAt": "2026-09-22T00:00:00Z",
        "subject": "12.1.0 (1)",
        "version": "12.1.0",
        "build": 1,
        "documentationPath": "Interface/Docs",
        "capturedOn": "2026-09-24",
        "fileCount": len(files),
        "files": sorted(files),
    }
    (capture / "capture.json").write_text(json.dumps(capture_json), encoding="utf-8")
    return capture


class NamespaceTests(unittest.TestCase):
    def test_namespaced_functions_bind_through_their_namespace(self):
        metadata = normalise(("Profiler.lua", PROFILER_TABLE))

        namespace = metadata.namespaces[0]
        self.assertEqual("addOnProfiler", namespace.wrapper)
        self.assertEqual("profiler", namespace.alias)
        self.assertEqual("namespace", namespace.kind)
        self.assertEqual("C_AddOnProfiler", namespace.blizzard_namespace)
        self.assertEqual("All", namespace.environment)
        function = namespace.functions[0]
        self.assertEqual("measureCall", function.wrapper)
        self.assertEqual("C_AddOnProfiler.MeasureCall", function.binding)
        self.assertEqual("Profiler.lua", function.source)

    def test_markers_are_typed_flagged_or_kept(self):
        function = normalise(("Profiler.lua", PROFILER_TABLE)).namespaces[0].functions[0]

        self.assertEqual("AllowedWhenUntainted", function.secret_arguments)
        self.assertTrue(function.may_return_nothing)
        self.assertEqual(("RequiresSomething",), function.flags)
        self.assertEqual({"FailureMode": "ReturnNothing"}, function.attributes)
        self.assertEqual(("Times a call.",), function.documentation)

    def test_parameters_keep_defaults_and_flags(self):
        function = normalise(("Profiler.lua", PROFILER_TABLE)).namespaces[0].functions[0]

        label = function.arguments[1]
        self.assertTrue(label.nilable)
        self.assertTrue(label.has_default)
        self.assertEqual("x", label.default)
        self.assertFalse(function.arguments[0].has_default)
        self.assertEqual(("NeverSecret",), function.returns[0].flags)

    def test_global_functions_bind_by_name_and_drop_the_system_prefix(self):
        namespace = normalise(("Unit.lua", UNIT_TABLE)).namespaces[0]

        self.assertEqual("global", namespace.kind)
        self.assertEqual("unit", namespace.wrapper)
        self.assertIsNone(namespace.blizzard_namespace)
        by_name = {function.name: function for function in namespace.functions}
        self.assertEqual("name", by_name["UnitName"].wrapper)
        self.assertEqual("UnitName", by_name["UnitName"].binding)
        self.assertEqual("getPvPRank", by_name["GetPvPRank"].wrapper)

    def test_object_methods_are_typed_but_not_bound(self):
        namespace = normalise(("Clock.lua", CLOCK_OBJECT)).namespaces[0]

        self.assertEqual("object", namespace.kind)
        self.assertEqual("Userdata", namespace.object_type)
        self.assertEqual("clockAPI", namespace.wrapper)
        self.assertIsNone(namespace.functions[0].binding)
        self.assertIn("Clock", normalise(("Clock.lua", CLOCK_OBJECT)).defined_type_names())

    def test_two_files_for_one_namespace_are_merged(self):
        second = PROFILER_TABLE.replace("AddOnProfiler =", "AddOnProfilerExtra =", 1)
        second = second.replace('Name = "AddOnProfiler"', 'Name = "AddOnProfilerExtra"')
        second = second.replace("MeasureCall", "MeasureOther").replace("ProfilerReset", "ProfilerCleared")
        second = second.replace("PROFILER_RESET", "PROFILER_CLEARED")
        second = second.replace('Name = "MeasureCallback"', 'Name = "OtherCallback"')
        second = second.replace('Type = "MeasureCallback"', 'Type = "OtherCallback"')
        second = second.replace('Name = "Metric"', 'Name = "OtherMetric"').replace('Type = "Metric"', 'Type = "OtherMetric"')
        second = second.replace('Name = "Sample"', 'Name = "OtherSample"')
        second = second.replace('Name = "HasRestrictions"', 'Name = "OtherRestriction"')
        second = second.replace("AddDocumentationTable(AddOnProfiler)", "AddDocumentationTable(AddOnProfilerExtra)")

        metadata = normalise(("Profiler.lua", PROFILER_TABLE), ("ProfilerExtra.lua", second))

        self.assertEqual(1, len(metadata.namespaces))
        namespace = metadata.namespaces[0]
        self.assertEqual("AddOnProfiler", namespace.system)
        self.assertEqual(["MeasureCall", "MeasureOther"], [function.name for function in namespace.functions])
        self.assertEqual(("Profiler.lua", "ProfilerExtra.lua"), namespace.sources)

    def test_the_same_function_twice_is_a_problem(self):
        with self.assertRaisesRegex(module.NormalizeError, "MeasureCall: documented twice"):
            normalise(("Profiler.lua", PROFILER_TABLE), ("Again.lua", PROFILER_TABLE.replace("ProfilerReset", "Other").replace("PROFILER_RESET", "OTHER").replace('Name = "MeasureCallback"', 'Name = "X"').replace('Name = "Metric"', 'Name = "Y"').replace('Name = "Sample"', 'Name = "Z"').replace('Name = "HasRestrictions"', 'Name = "W"')))


class MemberTests(unittest.TestCase):
    def test_events_are_flat_and_named_from_their_pascal_case_name(self):
        event = normalise(("Profiler.lua", PROFILER_TABLE)).events[0]

        self.assertEqual("ProfilerReset", event.name)
        self.assertEqual("profilerReset", event.wrapper)
        self.assertEqual("PROFILER_RESET", event.literal_name)
        self.assertEqual("AddOnProfiler", event.system)
        self.assertTrue(event.synchronous)
        self.assertEqual("reason", event.payload[0].name)

    def test_tables_are_sorted_into_their_kinds(self):
        metadata = normalise(("Profiler.lua", PROFILER_TABLE))

        self.assertEqual("MeasureCallback", metadata.callbacks[0].name)
        self.assertEqual("Metric", metadata.enums[0].name)
        self.assertEqual("metric", metadata.enums[0].wrapper)
        self.assertEqual((0, 1), tuple(field.value for field in metadata.enums[0].fields))
        self.assertEqual(("The worst tick.",), metadata.enums[0].fields[1].documentation)
        self.assertEqual("Sample", metadata.structures[0].name)
        self.assertEqual("cstring", metadata.structures[0].fields[1].inner_type)

    def test_predicates_become_restrictions_scoped_to_their_system(self):
        restriction = normalise(("Profiler.lua", PROFILER_TABLE)).restrictions[0]

        self.assertEqual("HasRestrictions", restriction.name)
        self.assertEqual("precondition", restriction.kind)
        self.assertEqual("Error", restriction.failure_mode)
        self.assertEqual("AddOnProfiler", restriction.system)

    def test_the_same_predicate_in_two_systems_is_allowed(self):
        unit = UNIT_TABLE.replace("\tPredicates = { },", '\tPredicates = { { Name = "HasRestrictions", Type = "Precondition", FailureMode = "ReturnNothing" } },')

        metadata = normalise(("Profiler.lua", PROFILER_TABLE), ("Unit.lua", unit))

        self.assertEqual([("AddOnProfiler", "Error"), ("Unit", "ReturnNothing")], [(r.system, r.failure_mode) for r in metadata.restrictions])

    def test_constants_keep_literals_and_carry_expressions_as_text(self):
        table = normalise(("Profiler.lua", PROFILER_TABLE), ("UnitConstants.lua", CONSTANTS_TABLE)).constants[0]

        self.assertEqual("unitConstants", table.wrapper)
        self.assertIsNone(table.system)
        by_name = {value.name: value for value in table.values}
        self.assertEqual(40, by_name["MAX_UNITS"].value)
        self.assertIsNone(by_name["MAX_UNITS"].expression)
        self.assertEqual("Enum.Metric.Average", by_name["FIRST_UNIT"].expression)
        self.assertEqual("Constants.UnitConstants.MAX_UNITS - 1", by_name["UNIT_COUNT"].expression)

    def test_unknown_table_type_is_a_problem(self):
        broken = PROFILER_TABLE.replace('Type = "Structure"', 'Type = "Mystery"')

        with self.assertRaisesRegex(module.NormalizeError, "unknown table Type 'Mystery'"):
            normalise(("Profiler.lua", broken))

    def test_unknown_top_level_type_is_a_problem(self):
        broken = PROFILER_TABLE.replace('Type = "System"', 'Type = "Thing"')

        with self.assertRaisesRegex(module.NormalizeError, "unknown top-level Type 'Thing'"):
            normalise(("Profiler.lua", broken))

    def test_a_colliding_wrapper_name_is_a_problem_that_names_the_fix(self):
        colliding = UNIT_TABLE.replace('Name = "GetPvPRank"', 'Name = "Name"')

        with self.assertRaisesRegex(module.NormalizeError, "unit.name would be shared .* functionExceptions"):
            normalise(("Unit.lua", colliding))

    def test_a_namespace_exception_renames_the_namespace(self):
        rules = naming.parse_naming_rules(
            {"words": [], "namespaceAliases": {}, "namespaceExceptions": {"Unit": "units"}, "functionExceptions": {"Unit.UnitName": "displayName"}}
        )
        normalizer = module.Normalizer(rules)
        normalizer.add_file("Unit.lua", lua_tables.parse_documentation_file(UNIT_TABLE, where="Unit.lua"))

        namespace = normalizer.build(provenance()).namespaces[0]

        self.assertEqual("units", namespace.wrapper)
        self.assertEqual("displayName", namespace.functions[1].wrapper)

    def test_output_is_sorted_and_deterministic(self):
        first = normalise(("Unit.lua", UNIT_TABLE), ("Profiler.lua", PROFILER_TABLE), ("Clock.lua", CLOCK_OBJECT))
        second = normalise(("Clock.lua", CLOCK_OBJECT), ("Profiler.lua", PROFILER_TABLE), ("Unit.lua", UNIT_TABLE))

        self.assertEqual(["addOnProfiler", "clockAPI", "unit"], [namespace.wrapper for namespace in first.namespaces])
        self.assertEqual(first.to_files(), second.to_files())


class CaptureTests(unittest.TestCase):
    def test_capture_is_normalised_and_written(self):
        with tempfile.TemporaryDirectory() as directory:
            capture = write_capture(Path(directory), {"Profiler.lua": PROFILER_TABLE, "Unit.lua": UNIT_TABLE})
            out = Path(directory) / "metadata"

            output = io.StringIO()
            with redirect_stdout(output):
                status = module.main(["--capture", str(capture), "--out", str(out)])

            self.assertEqual(0, status, output.getvalue())
            self.assertIn("namespaces: 2  functions: 3", output.getvalue())
            written = model.read_metadata(out)
            self.assertEqual("b" * 40, written.provenance.commit)
            self.assertEqual(1, written.provenance.build)

    def test_nothing_is_written_when_validation_fails(self):
        broken = PROFILER_TABLE.replace('Type = "MeasureCallback"', 'Type = "Mystery"')
        with tempfile.TemporaryDirectory() as directory:
            capture = write_capture(Path(directory), {"Profiler.lua": broken})
            out = Path(directory) / "metadata"

            errors = io.StringIO()
            with redirect_stderr(errors):
                status = module.main(["--capture", str(capture), "--out", str(out)])

            self.assertEqual(1, status)
            self.assertIn("'Mystery'", errors.getvalue())
            self.assertFalse(out.exists())

    def test_a_parse_error_names_the_file_and_line(self):
        with tempfile.TemporaryDirectory() as directory:
            capture = write_capture(Path(directory), {"Broken.lua": "local X = { Name = }\n"})

            errors = io.StringIO()
            with redirect_stderr(errors):
                status = module.main(["--capture", str(capture), "--out", str(Path(directory) / "m")])

            self.assertEqual(1, status)
            self.assertIn("Broken.lua:1:", errors.getvalue())

    def test_an_unregistered_table_is_a_problem(self):
        unregistered = PROFILER_TABLE.replace("APIDocumentation:AddDocumentationTable(AddOnProfiler);", "")
        with tempfile.TemporaryDirectory() as directory:
            capture = write_capture(Path(directory), {"Profiler.lua": unregistered})

            with self.assertRaisesRegex(module.NormalizeError, "never registered"):
                module.normalize_capture(capture, RULES)

    def test_missing_capture_file_is_reported(self):
        with tempfile.TemporaryDirectory() as directory:
            with self.assertRaisesRegex(module.NormalizeError, "capture.json: missing"):
                module.normalize_capture(Path(directory), RULES)


if __name__ == "__main__":
    unittest.main()
