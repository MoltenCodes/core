"""Tests for the apiKit LuaCATS definition renderer.

Every fixture is the invented `sample_metadata()` of the model tests, extended
where a rule needs a shape the sample lacks (design document, section 16).
The one test class that reads real metadata does so from a directory named by
an environment variable, which is unset in the repository and on CI; it
asserts on counts and on the formatter's verdict, never on content, and skips
when the variable is unset.
"""

from __future__ import annotations

import dataclasses
import os
import shutil
import subprocess
import tempfile
import unittest
from pathlib import Path

from tooling.api import flavours, model
from tooling.api import render_types as module
from tooling.tests.test_api_model import sample_metadata
from tooling.validation.validate_manifests import ROOT


#: Names a real normalised Retail metadata directory, when this machine has one.
#: The same variable serves the diff tests, so one setting covers both.
CORPUS_ENV = "MOLTENCODES_API_METADATA"
#: The metadata the corpus tests run against: the directory `MOLTENCODES_API_METADATA`
#: names, else the committed Retail metadata, so the checks run in CI too.
COMMITTED_RETAIL_METADATA = ROOT / "packages" / "apiKit" / "metadata" / "retail"
CORPUS_DIRECTORY = Path(os.environ[CORPUS_ENV]) if os.environ.get(CORPUS_ENV) else COMMITTED_RETAIL_METADATA

HOST_TYPES = model.parse_host_types(
    {
        "verified": "2026-09-24",
        "types": {
            "IDOrLink": {"kind": "alias", "lua": "number|string"},
            "ItemLocation": {"kind": "class", "lua": "ItemLocation"},
            "StoreError": {"kind": "opaque", "lua": "any"},
            "WOWGUID": {"kind": "alias", "lua": "string"},
            "bool": {"kind": "primitive", "lua": "boolean"},
            "cstring": {"kind": "primitive", "lua": "string"},
            "number": {"kind": "primitive", "lua": "number"},
            "string": {"kind": "primitive", "lua": "string"},
            "table": {"kind": "primitive", "lua": "table"},
        },
    }
)

#: What `defined_lua_types` yields for `sample_metadata()`.
DEFINED = {"Enum.PhaseReason", "Point", "MeasureCallback", "Clock"}


def flavour_named(identifier: str) -> flavours.Flavour:
    """One row of the repository's flavour table."""
    for flavour in flavours.load_flavours().flavours:
        if flavour.id == identifier:
            return flavour
    raise AssertionError(f"no flavour {identifier!r}")


RETAIL = flavour_named("retail")
CLASSIC_ERA = flavour_named("classic-era")


def extended_metadata() -> model.FlavourMetadata:
    """The sample plus the shapes the renderer has rules for and the sample lacks.

    Added: a global system with a keyword-named parameter, documentation,
    restriction markers and a nilable second return; a callback with returns;
    a structure with a map field and an optional array field; an event whose
    payload uses a keyword name and an enum; a constant given as an expression.
    """
    metadata = sample_metadata()
    unit = model.Namespace(
        wrapper="unit",
        kind="global",
        system="Unit",
        functions=(
            model.Function(
                name="UnitName",
                wrapper="name",
                binding="UnitName",
                arguments=(model.Parameter(name="end", type="cstring"),),
                returns=(
                    model.Parameter(name="name", type="cstring"),
                    model.Parameter(name="realm", type="cstring", nilable=True),
                ),
                documentation=("The unit's name.", "Realm follows when the unit is elsewhere."),
                has_restrictions=True,
                is_protected=True,
            ),
        ),
    )
    ticker = model.Callback(
        name="TickerCallback",
        arguments=(model.Parameter(name="count", type="number", nilable=True),),
        returns=(
            model.Parameter(name="keepGoing", type="bool"),
            model.Parameter(name="guid", type="WOWGUID"),
        ),
    )
    registry = model.Structure(
        name="Registry",
        fields=(
            model.Parameter(name="byName", type="table", inner_type="Point", key_type="cstring"),
            model.Parameter(
                name="points",
                type="table",
                inner_type="Point",
                nilable=True,
                documentation=("Optional list.",),
            ),
        ),
    )
    login = model.Event(
        name="PlayerLogin",
        wrapper="playerLogin",
        literal_name="PLAYER_LOGIN",
        system="System",
        payload=(
            model.Parameter(name="function", type="MeasureCallback"),
            model.Parameter(name="reason", type="PhaseReason", nilable=True),
        ),
        documentation=("Fired once at login.",),
    )
    expression = model.ConstantValue(
        name="LAST", type="number", expression="Constants.AuctionConstants.FIRST + 1"
    )
    constants = dataclasses.replace(
        metadata.constants[0], values=(*metadata.constants[0].values, expression)
    )
    return dataclasses.replace(
        metadata,
        namespaces=(*metadata.namespaces, unit),
        callbacks=(*metadata.callbacks, ticker),
        structures=(*metadata.structures, registry),
        events=(*metadata.events, login),
        constants=(constants,),
    )


def render(
    metadata: model.FlavourMetadata | None = None, flavour: flavours.Flavour = RETAIL
) -> dict[str, str]:
    return module.render_types(metadata or extended_metadata(), flavour, HOST_TYPES)


class LuaTypeTests(unittest.TestCase):
    def lua_type(self, **fields) -> str:
        fields.setdefault("name", "value")
        return module.lua_type(model.Parameter(**fields), HOST_TYPES, DEFINED)

    def test_primitive_and_alias_use_their_lua_spelling(self):
        self.assertEqual("boolean", self.lua_type(type="bool"))
        self.assertEqual("string", self.lua_type(type="cstring"))
        self.assertEqual("string", self.lua_type(type="WOWGUID"))

    def test_class_is_its_own_name(self):
        self.assertEqual("ItemLocation", self.lua_type(type="ItemLocation"))

    def test_opaque_is_any(self):
        self.assertEqual("any", self.lua_type(type="StoreError"))

    def test_enum_is_under_the_enum_table(self):
        self.assertEqual("Enum.PhaseReason", self.lua_type(type="PhaseReason"))

    def test_structure_callback_and_object_keep_their_names(self):
        self.assertEqual("Point", self.lua_type(type="Point"))
        self.assertEqual("MeasureCallback", self.lua_type(type="MeasureCallback"))
        self.assertEqual("Clock", self.lua_type(type="Clock"))

    def test_table_with_inner_type_is_an_array(self):
        self.assertEqual("Point[]", self.lua_type(type="table", inner_type="Point"))
        self.assertEqual("string[]", self.lua_type(type="table", inner_type="cstring"))

    def test_table_with_key_type_is_a_map(self):
        self.assertEqual(
            "table<string, Point>", self.lua_type(type="table", inner_type="Point", key_type="cstring")
        )

    def test_plain_table_stays_table(self):
        self.assertEqual("table", self.lua_type(type="table"))

    def test_nilable_appends_a_question_mark(self):
        self.assertEqual("number?", self.lua_type(type="number", nilable=True))
        self.assertEqual("Point[]?", self.lua_type(type="table", inner_type="Point", nilable=True))

    def test_nilable_union_is_bracketed(self):
        self.assertEqual("(number|string)?", self.lua_type(type="IDOrLink", nilable=True))

    def test_unknown_name_falls_back_to_any(self):
        self.assertEqual("any", self.lua_type(type="NeverHeardOf"))
        self.assertEqual("any[]", self.lua_type(type="table", inner_type="NeverHeardOf"))

    def test_defined_lua_types_spell_enums_under_the_enum_table(self):
        self.assertEqual(DEFINED, module.defined_lua_types(sample_metadata()))


class HeaderTests(unittest.TestCase):
    def test_every_file_starts_with_meta_and_provenance(self):
        files = render()

        self.assertEqual(sorted(module.TYPES_FILES), sorted(files))
        for text in files.values():
            lines = text.splitlines()
            self.assertEqual("---@meta", lines[0])
            self.assertEqual("---@diagnostic disable: missing-return", lines[1])
            self.assertIn("tooling.api.generate", lines[2])
            self.assertIn("retail metadata", lines[2])
            self.assertIn("Example/wow-ui-source", lines[3])
            self.assertIn("client 12.1.0 build 69933", lines[3])
            self.assertEqual("-- Commit: " + "a" * 40, lines[4])
            self.assertIn("Do not edit", lines[5])

    def test_missing_version_and_build_are_written_as_unknown(self):
        provenance = dataclasses.replace(extended_metadata().provenance, version=None, build=None)

        lines = module.header_lines(provenance)

        self.assertIn("client unknown build unknown", lines[3])


class ApiFileTests(unittest.TestCase):
    def setUp(self):
        self.text = render()["api.lua"]

    def test_global_and_flavour_path_are_declared(self):
        self.assertIn("---@class wow\n---@field retail wow.retail\n", self.text)
        self.assertIn("---@class wow.retail\n---@field api wow.retail.api\n", self.text)
        self.assertIn("---@class wow\n---@field retail wow.retail\nwow = {}\n", self.text)
        self.assertNotIn("---@type wow", self.text)
        self.assertIn("---@diagnostic disable: missing-return", self.text.splitlines()[1])

    def test_nested_namespace_path_builds_one_class_per_segment(self):
        text = render(flavour=CLASSIC_ERA)["api.lua"]

        self.assertIn("---@class wow\n---@field classic wow.classic\n", text)
        self.assertIn("---@class wow.classic\n---@field era wow.classic.era\n", text)
        self.assertIn("---@class wow.classic.era\n---@field api wow.classic.era.api\n", text)
        self.assertIn("---@class wow.classic.era.api\n", text)
        self.assertIn("---@class wow.classic.era.api.addOnProfiler\n", text)
        self.assertNotIn("wow.retail", text)

    def test_api_class_lists_namespaces_aliases_and_reserved_tables(self):
        self.assertIn("---@field addOnProfiler wow.retail.api.addOnProfiler\n", self.text)
        self.assertIn("---@field profiler wow.retail.api.addOnProfiler\n", self.text)
        self.assertIn("---@field unit wow.retail.api.unit\n", self.text)
        self.assertIn("---@field events wow.retail.api.events\n", self.text)
        self.assertIn("---@field enums wow.retail.api.enums\n", self.text)
        self.assertIn("---@field constants wow.retail.api.constants\n", self.text)

    def test_object_namespaces_are_not_part_of_the_api_class(self):
        self.assertNotIn("clock", self.text)

    def test_namespace_class_and_function_stub(self):
        expected = (
            "---Wraps `C_AddOnProfiler`.\n"
            "---@class wow.retail.api.addOnProfiler\n"
            "api.addOnProfiler = {}\n"
            "\n"
            "---Restrictions: secretArguments=AllowedWhenUntainted, RequiresClubsInitialized\n"
            "---@param callback MeasureCallback\n"
            "---@param label? string\n"
            "---@return number? elapsed\n"
            "function api.addOnProfiler.measureCall(callback, label) end\n"
        )
        self.assertIn(expected, self.text)

    def test_global_system_documentation_keyword_parameter_and_restrictions(self):
        expected = (
            "---Wraps the global functions of the `Unit` system.\n"
            "---@class wow.retail.api.unit\n"
            "api.unit = {}\n"
            "\n"
            "---The unit's name.\n"
            "---Realm follows when the unit is elsewhere.\n"
            "---Restrictions: hasRestrictions, isProtected\n"
            "---@param end_ string\n"
            "---@return string name\n"
            "---@return string? realm\n"
            "function api.unit.name(end_) end\n"
        )
        self.assertIn(expected, self.text)

    def test_may_return_nothing_marks_every_return_nilable(self):
        self.assertIn("---@return number? elapsed\n", self.text)

    def test_namespaces_are_sorted_by_wrapper(self):
        self.assertLess(self.text.index("api.addOnProfiler = {}"), self.text.index("api.unit = {}"))

    def test_long_function_stub_is_broken_like_stylua_breaks_it(self):
        parameters = [f"parameter{index}" for index in range(8)]

        lines = module.function_stub_lines("api.namespace.aVeryLongFunctionNameIndeed", parameters)

        self.assertEqual("function api.namespace.aVeryLongFunctionNameIndeed(", lines[0])
        self.assertEqual("  parameter0,", lines[1])
        self.assertEqual("  parameter7", lines[8])
        self.assertEqual([")", "end"], lines[9:])

    def test_short_function_stub_stays_on_one_line(self):
        self.assertEqual(
            ["function api.clock.now() end"], module.function_stub_lines("api.clock.now", [])
        )

    def test_reserved_word_wrapper_is_refused(self):
        metadata = extended_metadata()
        broken = dataclasses.replace(metadata.namespaces[0], wrapper="end", alias=None)
        metadata = dataclasses.replace(metadata, namespaces=(broken,))

        with self.assertRaisesRegex(module.TypesRenderError, "reserved word"):
            render(metadata)


class EventsFileTests(unittest.TestCase):
    def setUp(self):
        self.text = render()["events.lua"]

    def test_events_class_maps_wrapper_to_literal(self):
        self.assertIn(
            '---@class wow.retail.api.events\n---@field addonLoaded "ADDON_LOADED"\n', self.text
        )
        self.assertIn('---Fired once at login.\n---@field playerLogin "PLAYER_LOGIN"\n', self.text)

    def test_payload_class_describes_handler_arguments(self):
        self.assertIn("---@class wow.retail.api.eventPayloads\n", self.text)
        self.assertIn("---@field ADDON_LOADED fun(addOnName: string)\n", self.text)
        self.assertIn(
            "---@field PLAYER_LOGIN fun(function_: MeasureCallback, reason?: Enum.PhaseReason)\n",
            self.text,
        )


class EnumsFileTests(unittest.TestCase):
    def setUp(self):
        self.text = render()["enums.lua"]

    def test_enum_table_is_declared_once_and_assigned_plainly(self):
        self.assertIn("---@class Enum\n---@field PhaseReason Enum.PhaseReason\nEnum = {}\n", self.text)
        self.assertNotIn("Enum or {}", self.text)

    def test_enum_values_keep_table_order_and_field_documentation(self):
        expected = (
            "---@enum Enum.PhaseReason\n"
            "Enum.PhaseReason = {\n"
            "  Phasing = 0,\n"
            "  ---Shards.\n"
            "  Sharding = 1,\n"
            "}\n"
        )
        self.assertIn(expected, self.text)

    def test_enums_class_maps_wrapper_to_enum(self):
        self.assertIn(
            "---@class wow.retail.api.enums\n---@field phaseReason Enum.PhaseReason\n", self.text
        )


class StructuresFileTests(unittest.TestCase):
    def setUp(self):
        self.text = render()["structures.lua"]

    def test_structure_fields(self):
        self.assertIn("---@class Point\n---@field x number\n---@field y number\n", self.text)

    def test_map_array_and_optional_fields(self):
        expected = (
            "---@class Registry\n"
            "---@field byName table<string, Point>\n"
            "---Optional list.\n"
            "---@field points? Point[]\n"
        )
        self.assertIn(expected, self.text)

    def test_callback_alias_with_and_without_returns(self):
        self.assertIn("---@alias MeasureCallback fun(value: number)\n", self.text)
        self.assertIn("---@alias TickerCallback fun(count?: number): boolean, string\n", self.text)


class ConstantsFileTests(unittest.TestCase):
    def setUp(self):
        self.text = render()["constants.lua"]

    def test_constants_table_class_per_table_and_wrapper_class(self):
        self.assertIn(
            "---@class Constants\n---@field AuctionConstants Constants.AuctionConstants\nConstants = {}\n",
            self.text,
        )
        self.assertIn(
            "---@class Constants.AuctionConstants\n---@field DEFAULT_MULTIPLIER number\n", self.text
        )
        self.assertIn(
            "---@class wow.retail.api.constants\n---@field auctionConstants Constants.AuctionConstants\n",
            self.text,
        )

    def test_expression_constant_uses_its_declared_type_or_any(self):
        self.assertIn("---@field LAST number\n", self.text)
        value = model.ConstantValue(name="MYSTERY", type="Nowhere", expression="Nowhere.X")
        metadata = extended_metadata()
        table = dataclasses.replace(metadata.constants[0], values=(value,))
        metadata = dataclasses.replace(metadata, constants=(table,))

        self.assertIn("---@field MYSTERY any\n", render(metadata)["constants.lua"])


class ObjectsFileTests(unittest.TestCase):
    def test_object_class_uses_blizzard_method_names(self):
        text = render()["objects.lua"]

        self.assertIn("---@class Clock\nlocal Clock = {}\n\nfunction Clock:Now() end\n", text)
        self.assertNotIn("now()", text)


class HostFileTests(unittest.TestCase):
    def test_aliases_and_classes_only(self):
        text = render()["host.lua"]

        self.assertIn("---@alias WOWGUID string\n", text)
        self.assertIn("---@alias IDOrLink number|string\n", text)
        self.assertIn("---@class ItemLocation\n", text)
        for primitive_or_opaque in ("bool", "cstring", "StoreError", "number"):
            self.assertNotRegex(text, rf"@(alias|class) {primitive_or_opaque}\b")


class DocumentationTests(unittest.TestCase):
    def test_paragraphs_wrap_at_the_documentation_width(self):
        lines = module.wrap_documentation(" ".join(["word"] * 60))

        self.assertGreater(len(lines), 1)
        for line in lines:
            self.assertTrue(line.startswith("---"))
            self.assertLessEqual(len(line), module.DOC_COLUMN_WIDTH)

    def test_embedded_line_breaks_are_kept(self):
        self.assertEqual(["---one", "---two"], module.wrap_documentation("one\ntwo"))

    def test_indented_documentation_wraps_shorter(self):
        lines = module.wrap_documentation(" ".join(["word"] * 60), indent=module.INDENT)

        for line in lines:
            self.assertTrue(line.startswith(module.INDENT + "---"))
            self.assertLessEqual(len(line), module.DOC_COLUMN_WIDTH)


def lines_over_width(files: dict[str, str]) -> list[str]:
    """Lines longer than StyLua's column width that are not unwrappable annotations.

    An `---@field` or `---@alias` line carries a single signature or literal and
    cannot be broken, so it is the one kind of line allowed past the width; the
    renderer keeps prose off those lines to make that true.
    """
    offending = []
    for name, text in files.items():
        for line in text.splitlines():
            if len(line) > module.STYLUA_COLUMN_WIDTH and not line.startswith("---@"):
                offending.append(f"{name}: {line}")
    return offending


def stylua_check(files: dict[str, str]) -> subprocess.CompletedProcess[str]:
    """Write the files to a temporary directory and let StyLua judge them."""
    stylua = shutil.which("stylua")
    assert stylua is not None
    with tempfile.TemporaryDirectory() as directory:
        for name, text in files.items():
            (Path(directory) / name).write_text(text, encoding="utf-8")
        return subprocess.run(
            [stylua, "--check", "--config-path", str(ROOT / "stylua.toml"), directory],
            capture_output=True,
            text=True,
            check=False,
        )


class OutputShapeTests(unittest.TestCase):
    def test_rendering_is_deterministic(self):
        self.assertEqual(render(), render())

    def test_sample_output_has_no_line_over_the_column_width(self):
        for name, text in render().items():
            for line in text.splitlines():
                self.assertLessEqual(len(line), module.STYLUA_COLUMN_WIDTH, f"{name}: {line}")

    def test_sample_output_is_formatted_as_stylua_wants(self):
        if shutil.which("stylua") is None:
            self.skipTest("stylua is not on PATH")

        completed = stylua_check(render())

        self.assertEqual(0, completed.returncode, completed.stdout + completed.stderr)


class RetailCorpusTests(unittest.TestCase):
    """Structural checks on a real Retail capture, when `MOLTENCODES_API_METADATA` names one."""

    def setUp(self):
        if CORPUS_DIRECTORY is None or not (CORPUS_DIRECTORY / model.PROVENANCE_FILE).is_file():
            self.skipTest(f"{CORPUS_ENV} does not name a normalised metadata directory")
        self.metadata = model.read_metadata(CORPUS_DIRECTORY)
        self.files = module.render_types(self.metadata, RETAIL, model.load_host_types())

    def test_every_entry_has_its_declaration(self):
        wrapped = [namespace for namespace in self.metadata.namespaces if namespace.kind != "object"]
        objects = [namespace for namespace in self.metadata.namespaces if namespace.kind == "object"]

        self.assertEqual(len(wrapped), self.files["api.lua"].count("\n---@class wow.retail.api."))
        self.assertEqual(len(self.metadata.enums), self.files["enums.lua"].count("\n---@enum Enum."))
        self.assertEqual(
            len(self.metadata.structures), self.files["structures.lua"].count("\n---@class ")
        )
        self.assertEqual(len(self.metadata.callbacks), self.files["structures.lua"].count("\n---@alias "))
        self.assertEqual(len(objects), self.files["objects.lua"].count("\nlocal "))
        self.assertEqual(
            len(self.metadata.events) * 2, self.files["events.lua"].count("\n---@field ")
        )

    def test_only_unwrappable_annotations_pass_the_column_width(self):
        self.assertEqual([], lines_over_width(self.files))

    def test_corpus_output_is_formatted_as_stylua_wants(self):
        if shutil.which("stylua") is None:
            self.skipTest("stylua is not on PATH")

        completed = stylua_check(self.files)

        self.assertEqual(0, completed.returncode, (completed.stdout + completed.stderr)[:2000])


if __name__ == "__main__":
    unittest.main()
