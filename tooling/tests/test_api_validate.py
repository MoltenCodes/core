"""Tests for the apiKit metadata validator."""

from __future__ import annotations

import dataclasses
import io
import tempfile
import unittest
from contextlib import redirect_stderr, redirect_stdout
from pathlib import Path

from tooling.api import model
from tooling.api import validate as module
from tooling.tests.test_api_model import sample_metadata


HOST_TYPES = model.parse_host_types(
    {
        "verified": "2026-09-24",
        "types": {
            "bool": {"kind": "primitive", "lua": "boolean"},
            "cstring": {"kind": "primitive", "lua": "string"},
            "number": {"kind": "primitive", "lua": "number"},
            "string": {"kind": "primitive", "lua": "string"},
            "table": {"kind": "primitive", "lua": "table"},
        },
    }
)

KNOWN_FLAVOURS = ["retail", "classic-era"]


def problems_for(metadata: model.FlavourMetadata) -> list[str]:
    return module.validate_metadata(metadata, HOST_TYPES, KNOWN_FLAVOURS)


class ValidMetadataTests(unittest.TestCase):
    def test_sample_metadata_is_valid(self):
        self.assertEqual([], problems_for(sample_metadata()))


class ProvenanceTests(unittest.TestCase):
    def test_unknown_flavour_is_reported(self):
        metadata = sample_metadata()
        metadata = dataclasses.replace(metadata, provenance=dataclasses.replace(metadata.provenance, flavour="wrath"))

        self.assertTrue(any("flavour 'wrath'" in problem for problem in problems_for(metadata)))

    def test_short_commit_is_reported(self):
        metadata = sample_metadata()
        metadata = dataclasses.replace(metadata, provenance=dataclasses.replace(metadata.provenance, commit="abc"))

        self.assertTrue(any("full lowercase sha" in problem for problem in problems_for(metadata)))


class UniquenessTests(unittest.TestCase):
    def test_duplicate_namespace_wrapper_is_reported(self):
        metadata = sample_metadata()
        twin = dataclasses.replace(metadata.namespaces[1], wrapper="addOnProfiler", kind="global", system="Other", functions=())
        metadata = dataclasses.replace(metadata, namespaces=(metadata.namespaces[0], twin))

        self.assertIn("namespace wrapper 'addOnProfiler' is used twice", problems_for(metadata))

    def test_reserved_wrapper_names_are_refused(self):
        metadata = sample_metadata()
        first = dataclasses.replace(metadata.namespaces[0], alias="events")
        metadata = dataclasses.replace(metadata, namespaces=(first, metadata.namespaces[1]))

        self.assertTrue(any("'events' is reserved" in problem for problem in problems_for(metadata)))

    def test_alias_colliding_with_a_namespace_is_reported(self):
        metadata = sample_metadata()
        first = dataclasses.replace(metadata.namespaces[0], alias="clock")
        metadata = dataclasses.replace(metadata, namespaces=(first, metadata.namespaces[1]))

        self.assertIn("alias 'clock' of addOnProfiler is also a namespace wrapper", problems_for(metadata))

    def test_duplicate_function_wrapper_is_reported(self):
        metadata = sample_metadata()
        namespace = metadata.namespaces[0]
        twin = dataclasses.replace(namespace.functions[0], name="MeasureCall2", binding="C_AddOnProfiler.MeasureCall2")
        namespace = dataclasses.replace(namespace, functions=(namespace.functions[0], twin))
        metadata = dataclasses.replace(metadata, namespaces=(namespace, metadata.namespaces[1]))

        self.assertIn("addOnProfiler.measureCall is used by two functions", problems_for(metadata))

    def test_duplicate_binding_across_namespaces_is_reported(self):
        metadata = sample_metadata()
        stray = model.Namespace(
            wrapper="other",
            kind="global",
            system="Other",
            functions=(model.Function(name="X", wrapper="x", binding="C_AddOnProfiler.MeasureCall"),),
        )
        metadata = dataclasses.replace(metadata, namespaces=(*metadata.namespaces, stray))

        self.assertIn("binding 'C_AddOnProfiler.MeasureCall' is produced twice", problems_for(metadata))

    def test_object_functions_must_not_have_bindings(self):
        metadata = sample_metadata()
        clock = metadata.namespaces[1]
        clock = dataclasses.replace(clock, functions=(dataclasses.replace(clock.functions[0], binding="Now"),))
        metadata = dataclasses.replace(metadata, namespaces=(metadata.namespaces[0], clock))

        self.assertIn("clock.now: binding does not match kind object", problems_for(metadata))

    def test_kind_and_blizzard_namespace_must_agree(self):
        metadata = sample_metadata()
        broken = dataclasses.replace(metadata.namespaces[0], kind="global")
        metadata = dataclasses.replace(metadata, namespaces=(broken, metadata.namespaces[1]))

        self.assertIn("namespace addOnProfiler: kind global with a blizzardNamespace", problems_for(metadata))

    def test_duplicate_event_wrapper_and_literal_are_reported(self):
        metadata = sample_metadata()
        metadata = dataclasses.replace(metadata, events=(metadata.events[0], metadata.events[0]))

        problems = problems_for(metadata)
        self.assertIn("event wrapper 'addonLoaded' is used twice", problems)
        self.assertIn("event 'ADDON_LOADED' is documented twice", problems)

    def test_bad_wrapper_spelling_is_reported(self):
        metadata = sample_metadata()
        broken = dataclasses.replace(metadata.enums[0], wrapper="PhaseReason")
        metadata = dataclasses.replace(metadata, enums=(broken,))

        self.assertIn("enum PhaseReason: wrapper 'PhaseReason' is not lowerCamelCase", problems_for(metadata))


class BindingTests(unittest.TestCase):
    """A binding must be the one the function's own `Namespace` attribute names."""

    def with_function(self, metadata: model.FlavourMetadata, **changes) -> model.FlavourMetadata:
        namespace = metadata.namespaces[0]
        function = dataclasses.replace(namespace.functions[0], **changes)
        namespace = dataclasses.replace(namespace, functions=(function,))
        return dataclasses.replace(metadata, namespaces=(namespace, *metadata.namespaces[1:]))

    def test_a_binding_that_ignores_an_empty_namespace_attribute_is_refused(self):
        metadata = self.with_function(
            sample_metadata(),
            attributes={"Namespace": ""},
            binding="C_AddOnProfiler.MeasureCall",
        )

        self.assertIn(
            "addOnProfiler.measureCall: binding 'C_AddOnProfiler.MeasureCall' should be 'MeasureCall': "
            "its Namespace attribute is ''",
            problems_for(metadata),
        )

    def test_a_binding_that_follows_the_attribute_is_accepted(self):
        metadata = self.with_function(sample_metadata(), attributes={"Namespace": "table"}, binding="table.MeasureCall")

        self.assertEqual([], problems_for(metadata))

    def test_a_binding_through_another_table_without_the_attribute_is_refused(self):
        metadata = self.with_function(sample_metadata(), binding="table.MeasureCall")

        self.assertIn(
            "addOnProfiler.measureCall: binding 'table.MeasureCall' should be 'C_AddOnProfiler.MeasureCall': "
            "its namespace is namespace C_AddOnProfiler",
            problems_for(metadata),
        )

    def test_a_namespace_attribute_that_is_not_a_string_is_refused(self):
        metadata = self.with_function(sample_metadata(), attributes={"Namespace": 3})

        self.assertTrue(any("Namespace must be a string" in problem for problem in problems_for(metadata)))

    def test_an_object_method_with_a_namespace_attribute_is_refused(self):
        metadata = sample_metadata()
        clock = metadata.namespaces[1]
        method = dataclasses.replace(clock.functions[0], attributes={"Namespace": ""})
        metadata = dataclasses.replace(
            metadata, namespaces=(metadata.namespaces[0], dataclasses.replace(clock, functions=(method,)))
        )

        self.assertIn(
            "clock.now: a script object method cannot carry a Namespace attribute", problems_for(metadata)
        )


class EnumTests(unittest.TestCase):
    def test_counts_and_bounds_must_match_the_fields(self):
        metadata = sample_metadata()
        broken = dataclasses.replace(metadata.enums[0], num_values=3, min_value=1, max_value=5)
        metadata = dataclasses.replace(metadata, enums=(broken,))

        problems = problems_for(metadata)
        self.assertIn("enum PhaseReason: numValues is 3 but 2 fields are listed", problems)
        self.assertIn("enum PhaseReason: minValue is 1 but the smallest field is 0", problems)
        self.assertIn("enum PhaseReason: maxValue is 5 but the largest field is 1", problems)


class TypeReferenceTests(unittest.TestCase):
    def test_unresolved_type_is_reported_once_with_its_uses(self):
        metadata = sample_metadata()
        structure = model.Structure(name="Q", fields=(model.Parameter("a", "Mystery"), model.Parameter("b", "table", inner_type="Mystery")))
        metadata = dataclasses.replace(metadata, structures=(*metadata.structures, structure))

        problems = [problem for problem in problems_for(metadata) if "'Mystery'" in problem]
        self.assertEqual(1, len(problems), problems)
        self.assertIn("structure Q field a", problems[0])
        self.assertIn("structure Q field b", problems[0])

    def test_types_defined_by_the_flavour_resolve(self):
        metadata = sample_metadata()
        structure = model.Structure(
            name="Q",
            fields=(model.Parameter("a", "PhaseReason"), model.Parameter("b", "Point"), model.Parameter("c", "Clock")),
        )
        metadata = dataclasses.replace(metadata, structures=(*metadata.structures, structure))

        self.assertEqual([], problems_for(metadata))

    def test_constant_value_types_are_checked(self):
        metadata = sample_metadata()
        table = model.ConstantsTable(name="T", wrapper="t", values=(model.ConstantValue("A", "Mystery", 1),))
        metadata = dataclasses.replace(metadata, constants=(*metadata.constants, table))

        self.assertTrue(any("'Mystery'" in problem and "constants T value A" in problem for problem in problems_for(metadata)))


class CommandLineTests(unittest.TestCase):
    def test_valid_directory_passes(self):
        with tempfile.TemporaryDirectory() as directory:
            model.write_metadata(sample_metadata(), Path(directory))
            output = io.StringIO()
            with redirect_stdout(output):
                status = module.main([directory])

        self.assertEqual(0, status)
        self.assertIn("valid (retail, build 69933)", output.getvalue())

    def test_problems_are_printed_and_fail(self):
        metadata = sample_metadata()
        metadata = dataclasses.replace(metadata, events=(metadata.events[0], metadata.events[0]))
        with tempfile.TemporaryDirectory() as directory:
            model.write_metadata(metadata, Path(directory))
            errors = io.StringIO()
            with redirect_stderr(errors):
                status = module.main([directory])

        self.assertEqual(1, status)
        self.assertIn("event 'ADDON_LOADED' is documented twice", errors.getvalue())

    def test_missing_directory_fails_cleanly(self):
        errors = io.StringIO()
        with redirect_stderr(errors):
            status = module.main(["/nonexistent/metadata"])

        self.assertEqual(1, status)
        self.assertIn("error:", errors.getvalue())


if __name__ == "__main__":
    unittest.main()
