"""Tests for the apiKit metadata model and its JSON form."""

from __future__ import annotations

import copy
import json
import tempfile
import unittest
from pathlib import Path

from tooling.api import model as module


def sample_provenance() -> module.Provenance:
    return module.Provenance(
        flavour="retail",
        repository="Example/wow-ui-source",
        branch="live",
        commit="a" * 40,
        committed_at="2026-09-22T14:31:12Z",
        subject="12.1.0 (69933)",
        version="12.1.0",
        build=69933,
        documentation_path="Interface/AddOns/Blizzard_APIDocumentationGenerated",
        captured_on="2026-09-24",
        file_count=2,
    )


def sample_metadata() -> module.FlavourMetadata:
    measure_call = module.Function(
        name="MeasureCall",
        wrapper="measureCall",
        binding="C_AddOnProfiler.MeasureCall",
        arguments=(
            module.Parameter(name="callback", type="MeasureCallback", documentation=("What to time.",)),
            module.Parameter(name="label", type="cstring", nilable=True, has_default=True, default="x"),
        ),
        returns=(module.Parameter(name="elapsed", type="number", flags=("NeverSecret",)),),
        secret_arguments="AllowedWhenUntainted",
        may_return_nothing=True,
        flags=("RequiresClubsInitialized",),
        attributes={"FailureMode": "ReturnNothing"},
        source="ProfilerDocumentation.lua",
    )
    return module.FlavourMetadata(
        provenance=sample_provenance(),
        namespaces=(
            module.Namespace(
                wrapper="addOnProfiler",
                kind="namespace",
                system="AddOnProfiler",
                blizzard_namespace="C_AddOnProfiler",
                alias="profiler",
                environment="All",
                functions=(measure_call,),
                sources=("ProfilerDocumentation.lua",),
            ),
            module.Namespace(
                wrapper="clock",
                kind="object",
                system="Clock",
                object_type="Userdata",
                functions=(module.Function(name="Now", wrapper="now", binding=None),),
            ),
        ),
        events=(
            module.Event(
                name="AddonLoaded",
                wrapper="addonLoaded",
                literal_name="ADDON_LOADED",
                system="AddOns",
                payload=(module.Parameter(name="addOnName", type="cstring"),),
                synchronous=True,
                source="AddOnsDocumentation.lua",
            ),
        ),
        enums=(
            module.Enum(
                name="PhaseReason",
                wrapper="phaseReason",
                fields=(module.EnumField("Phasing", 0), module.EnumField("Sharding", 1, ("Shards.",))),
                num_values=2,
                min_value=0,
                max_value=1,
                system="Unit",
            ),
        ),
        structures=(
            module.Structure(
                name="Point", fields=(module.Parameter("x", "number"), module.Parameter("y", "number"))
            ),
        ),
        callbacks=(module.Callback(name="MeasureCallback", arguments=(module.Parameter("value", "number"),)),),
        constants=(
            module.ConstantsTable(
                name="AuctionConstants",
                wrapper="auctionConstants",
                values=(module.ConstantValue("DEFAULT_MULTIPLIER", "number", 1.5),),
            ),
        ),
        restrictions=(module.Restriction(name="HasRestrictions", kind="precondition", failure_mode="Error"),),
    )


class JsonObjectTests(unittest.TestCase):
    def test_none_and_empty_containers_are_left_out(self):
        self.assertEqual({"kept": False, "zero": 0}, module.json_object(kept=False, zero=0, gone=None, empty=[], also={}))

    def test_dump_is_sorted_and_readable(self):
        text = module.dump_json({"b": "ü", "a": [1]})

        self.assertEqual('{\n  "a": [\n    1\n  ],\n  "b": "ü"\n}\n', text)


class RoundTripTests(unittest.TestCase):
    def test_every_entry_survives_json(self):
        metadata = sample_metadata()

        with tempfile.TemporaryDirectory() as directory:
            module.write_metadata(metadata, Path(directory))
            read_back = module.read_metadata(Path(directory))

        self.assertEqual(metadata, read_back)

    def test_default_is_kept_even_when_falsy(self):
        parameter = module.Parameter(name="flag", type="bool", has_default=True, default=False)

        data = parameter.to_json()

        self.assertIn("default", data)
        self.assertFalse(data["default"])
        self.assertEqual(parameter, module.Parameter.from_json(data))

    def test_absent_default_is_not_written(self):
        self.assertNotIn("default", module.Parameter(name="flag", type="bool").to_json())

    def test_false_markers_are_omitted(self):
        function = module.Function(name="A", wrapper="a", binding="A")

        data = function.to_json()

        for key in ("mayReturnNothing", "hasRestrictions", "isProtected", "flags", "attributes"):
            self.assertNotIn(key, data)

    def test_files_are_named_and_carry_the_schema_and_flavour(self):
        files = sample_metadata().to_files()

        self.assertEqual(
            sorted(["provenance.json", *module.METADATA_FILES.values()]), sorted(files)
        )
        enums = json.loads(files["enums.json"])
        self.assertEqual(module.SCHEMA_VERSION, enums["schema"])
        self.assertEqual("retail", enums["flavour"])
        self.assertEqual("PhaseReason", enums["enums"][0]["name"])

    def test_writing_is_deterministic(self):
        first = sample_metadata().to_files()
        second = sample_metadata().to_files()

        self.assertEqual(first, second)

    def test_referenced_types(self):
        parameter = module.Parameter(name="map", type="table", inner_type="Point", key_type="string")

        self.assertEqual(["table", "Point", "string"], parameter.referenced_types())

    def test_defined_type_names_include_object_systems(self):
        self.assertEqual(
            {"PhaseReason", "Point", "MeasureCallback", "Clock"}, sample_metadata().defined_type_names()
        )


class WriteReadTests(unittest.TestCase):
    def test_stale_json_files_are_removed(self):
        with tempfile.TemporaryDirectory() as directory:
            stale = Path(directory) / "old.json"
            stale.write_text("{}", encoding="utf-8")

            module.write_metadata(sample_metadata(), Path(directory))

            self.assertFalse(stale.exists())

    def test_files_other_tools_own_survive_a_rewrite(self):
        with tempfile.TemporaryDirectory() as directory:
            (Path(directory) / "history.json").write_text("{}", encoding="utf-8")

            module.write_metadata(sample_metadata(), Path(directory))

            self.assertTrue((Path(directory) / "history.json").exists())

    def test_missing_file_is_reported(self):
        with tempfile.TemporaryDirectory() as directory:
            module.write_metadata(sample_metadata(), Path(directory))
            (Path(directory) / "events.json").unlink()

            with self.assertRaisesRegex(module.MetadataError, "events.json: missing"):
                module.read_metadata(Path(directory))

    def test_schema_mismatch_is_reported(self):
        with tempfile.TemporaryDirectory() as directory:
            module.write_metadata(sample_metadata(), Path(directory))
            path = Path(directory) / "enums.json"
            data = json.loads(path.read_text(encoding="utf-8"))
            data["schema"] = 99
            path.write_text(json.dumps(data), encoding="utf-8")

            with self.assertRaisesRegex(module.MetadataError, "expected schema"):
                module.read_metadata(Path(directory))

    def test_flavour_mismatch_between_files_is_reported(self):
        with tempfile.TemporaryDirectory() as directory:
            module.write_metadata(sample_metadata(), Path(directory))
            path = Path(directory) / "enums.json"
            data = json.loads(path.read_text(encoding="utf-8"))
            data["flavour"] = "beta"
            path.write_text(json.dumps(data), encoding="utf-8")

            with self.assertRaisesRegex(module.MetadataError, "flavour 'beta' is not 'retail'"):
                module.read_metadata(Path(directory))

    def test_malformed_entry_is_reported(self):
        with tempfile.TemporaryDirectory() as directory:
            module.write_metadata(sample_metadata(), Path(directory))
            path = Path(directory) / "events.json"
            path.write_text(json.dumps({"schema": 1, "flavour": "retail", "events": [{"name": "X"}]}), encoding="utf-8")

            with self.assertRaisesRegex(module.MetadataError, "malformed entry"):
                module.read_metadata(Path(directory))


VALID_HOST_TYPES = {
    "verified": "2026-09-24",
    "types": {
        "WOWGUID": {"kind": "alias", "lua": "string"},
        "bool": {"kind": "primitive", "lua": "boolean"},
        "number": {"kind": "primitive", "lua": "number"},
    },
}


class HostTypesTests(unittest.TestCase):
    def test_valid_table_is_parsed(self):
        types = module.parse_host_types(copy.deepcopy(VALID_HOST_TYPES))

        self.assertIn("bool", types)
        self.assertNotIn("Frame", types)
        self.assertEqual("string", types.types["WOWGUID"].lua)
        self.assertEqual(["WOWGUID", "bool", "number"], types.names())

    def test_unknown_kind_is_rejected(self):
        data = copy.deepcopy(VALID_HOST_TYPES)
        data["types"]["bool"]["kind"] = "thing"

        with self.assertRaisesRegex(module.MetadataError, "kind must be one of"):
            module.parse_host_types(data)

    def test_types_must_be_sorted(self):
        data = {"verified": "2026-09-24", "types": {"number": {"kind": "primitive", "lua": "number"}, "bool": {"kind": "primitive", "lua": "boolean"}}}

        with self.assertRaisesRegex(module.MetadataError, "sorted"):
            module.parse_host_types(data)

    def test_verified_must_be_a_date(self):
        data = copy.deepcopy(VALID_HOST_TYPES)
        data["verified"] = "20260924"

        with self.assertRaisesRegex(module.MetadataError, "ISO date"):
            module.parse_host_types(data)

    def test_repository_table_is_valid_and_covers_the_primitives(self):
        types = module.load_host_types()

        for name in ("number", "bool", "cstring", "string", "table", "luaIndex", "WOWGUID", "UnitToken"):
            self.assertIn(name, types)
        self.assertEqual("boolean", types.types["bool"].lua)


if __name__ == "__main__":
    unittest.main()
