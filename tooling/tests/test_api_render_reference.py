"""Tests for the apiKit Markdown reference and search index renderer.

The fixtures extend `sample_metadata()` with the shapes the reference must
show: an alias, an object type, an expression constant, a nilable argument
with a default, a `table<K, V>` field, a global system, and a function whose
wrapper collides with a section heading so GitHub's duplicate-anchor rule is
exercised. The one test that reads real metadata does so from a directory
named by an environment variable, unset in the repository and on CI, and
asserts only that the rendered reference is self-consistent and its counts
match the metadata.
"""

from __future__ import annotations

import dataclasses
import json
import os
import re
import unittest
from pathlib import Path

from tooling.validation.validate_manifests import ROOT
from tooling.api import flavours, model
from tooling.api import render_reference as module
from tooling.tests.test_api_model import sample_metadata

#: Names a metadata directory (`python3 -m tooling.api.normalize` output) for the corpus test.
METADATA_DIRECTORY_VARIABLE = "MOLTENCODES_API_METADATA"

RETAIL = flavours.load_flavours().by_id("retail")

#: The files every reference carries besides the namespace pages.
FIXED_FILES = {
    "README.md",
    "events.md",
    "enums.md",
    "structures.md",
    "callbacks.md",
    "constants.md",
    "objects.md",
    "restrictions.md",
}


def extended_metadata() -> model.FlavourMetadata:
    """The sample metadata plus the shapes the reference must render."""
    sample = sample_metadata()
    unit_name = model.Function(
        name="UnitName",
        wrapper="name",
        binding="UnitName",
        arguments=(model.Parameter(name="unit", type="cstring", documentation=("A unit token.",)),),
        returns=(
            model.Parameter(name="name", type="cstring", nilable=True),
            model.Parameter(name="reason", type="PhaseReason", nilable=True),
        ),
        documentation=(
            "Returns the name of the unit.",
            "Second paragraph | with a pipe\nand a line break.",
        ),
        has_restrictions=True,
        is_protected=True,
        source="UnitDocumentation.lua",
    )
    functions_function = model.Function(
        name="UnitFunctions",
        wrapper="functions",
        binding="UnitFunctions",
        returns=(model.Parameter(name="points", type="table", inner_type="Point"),),
        source="UnitDocumentation.lua",
    )
    unit = model.Namespace(
        wrapper="unit",
        kind="global",
        system="Unit",
        environment="All",
        documentation=("Functions about units.",),
        functions=(unit_name, functions_function),
        sources=("UnitDocumentation.lua",),
    )
    budget = model.Structure(
        name="Budget",
        fields=(
            model.Parameter(name="limits", type="table", inner_type="number", key_type="PhaseReason", nilable=True),
            model.Parameter(name="origin", type="Point", mixin="PointMixin", has_default=True, default=False),
        ),
        system="Housing",
        documentation=("How much may be spent.",),
    )
    constants = model.ConstantsTable(
        name="CalendarConstants",
        wrapper="calendarConstants",
        values=(
            model.ConstantValue("DEFAULT_TYPE", "PhaseReason", expression="Enum.PhaseReason.Sharding"),
            model.ConstantValue("MAX_DAYS", "number", 31, documentation=("Days per page.",)),
        ),
    )
    restriction = model.Restriction(
        name="HasRestrictions",
        kind="precondition",
        failure_mode="ReturnNothing",
        system="Unit",
        documentation=("Only when the unit is visible.",),
    )
    return dataclasses.replace(
        sample,
        namespaces=(*sample.namespaces, unit),
        structures=(*sample.structures, budget),
        constants=(*sample.constants, constants),
        restrictions=(*sample.restrictions, restriction),
    )


def render() -> dict[str, str]:
    return module.render_reference(extended_metadata(), RETAIL)


def table_rows(text: str) -> list[str]:
    return [line for line in text.splitlines() if line.startswith("| ")]


class HeadingAnchorTests(unittest.TestCase):
    def test_lowercases_and_removes_punctuation(self):
        self.assertEqual("apiaddonprofiler", module.heading_anchor("api.addOnProfiler"))
        self.assertEqual("measurecall", module.heading_anchor("`measureCall`"))

    def test_keeps_hyphens_underscores_and_digits(self):
        self.assertEqual("addon_loaded", module.heading_anchor("ADDON_LOADED"))
        self.assertEqual("base64variant", module.heading_anchor("Base64Variant"))
        self.assertEqual("classic-era-events", module.heading_anchor("Classic-Era events"))

    def test_spaces_become_hyphens(self):
        anchor = module.heading_anchor("Retail API reference (wow.retail.api)")

        self.assertEqual("retail-api-reference-wowretailapi", anchor)

    def test_surrounding_whitespace_is_ignored(self):
        self.assertEqual("functions", module.heading_anchor("  Functions  "))

    def test_duplicate_headings_are_suffixed_the_way_github_does(self):
        text = "# Dup\n\n## Dup\n\n### Dup\n\n[a](#dup) [b](#dup-1) [c](#dup-2)\n"

        self.assertEqual([], module.check_links({"page.md": text}))
        self.assertEqual(1, len(module.check_links({"page.md": text + "[d](#dup-3)\n"})))


class CheckLinksTests(unittest.TestCase):
    def test_rendered_reference_is_self_consistent(self):
        self.assertEqual([], module.check_links(render()))

    def test_missing_file_is_reported(self):
        files = {"README.md": "# Title\n\n[gone](namespaces/nothing.md)\n"}

        problems = module.check_links(files)

        self.assertEqual(1, len(problems))
        self.assertIn("no such file 'namespaces/nothing.md'", problems[0])

    def test_missing_anchor_is_reported(self):
        files = {"README.md": "# Title\n\n[x](enums.md#missing)\n", "enums.md": "# Enums\n\n### Present\n"}

        problems = module.check_links(files)

        self.assertEqual(1, len(problems))
        self.assertIn("no heading with anchor 'missing'", problems[0])

    def test_links_are_resolved_relative_to_the_linking_file(self):
        files = {
            "README.md": "# Title\n",
            "namespaces/unit.md": "# api.unit\n\n[back](../README.md) [self](#apiunit) [bad](README.md)\n",
        }

        problems = module.check_links(files)

        self.assertEqual(1, len(problems))
        self.assertIn("'README.md'", problems[0])
        self.assertIn("namespaces/README.md", problems[0])

    def test_external_links_are_ignored(self):
        files = {"README.md": "# Title\n\n[site](https://example.com/x#y) [mail](mailto:someone@example.com)\n"}

        self.assertEqual([], module.check_links(files))

    def test_fenced_code_is_neither_heading_nor_link(self):
        text = "# Title\n\n```lua\n# not a heading\nlocal x = [a](#nowhere)\n```\n\n[ok](#title)\n"

        self.assertEqual([], module.check_links({"page.md": text}))
        self.assertEqual(1, len(module.check_links({"page.md": text + "[bad](#not-a-heading)\n"})))


class RenderedFilesTests(unittest.TestCase):
    def setUp(self):
        self.files = render()

    def test_every_expected_file_is_rendered(self):
        self.assertEqual(
            FIXED_FILES | {"namespaces/addOnProfiler.md", "namespaces/unit.md"}, set(self.files)
        )

    def test_object_namespaces_get_no_page(self):
        self.assertNotIn("namespaces/clock.md", self.files)

    def test_every_file_starts_with_the_generated_comment_then_a_title(self):
        for name, text in self.files.items():
            with self.subTest(file=name):
                first, blank, title = text.splitlines()[:3]
                self.assertEqual(
                    "<!-- Generated by tooling.api.generate from the retail metadata "
                    "(Example/wow-ui-source@aaaaaaaaaaaa, 12.1.0 build 69933). Do not edit. -->",
                    first,
                )
                self.assertEqual("", blank)
                self.assertTrue(title.startswith("# "), title)

    def test_table_rows_have_one_line_and_a_constant_number_of_cells(self):
        for name, text in self.files.items():
            rows = table_rows(text)
            for row in rows:
                with self.subTest(file=name, row=row[:40]):
                    self.assertNotIn("\n", row)
            for header, separator, *body in _tables(text):
                expected = header.count("|")
                for row in body:
                    with self.subTest(file=name, row=row[:40]):
                        self.assertEqual(expected, len(re.findall(r"(?<!\\)\|", row)))

    def test_rendering_is_deterministic(self):
        self.assertEqual(render(), self.files)

    def test_case_colliding_file_names_are_refused(self):
        sample = sample_metadata()
        profiler = sample.namespaces[0]
        twin = dataclasses.replace(profiler, wrapper="addonProfiler", alias=None)
        metadata = dataclasses.replace(sample, namespaces=(profiler, twin))

        with self.assertRaisesRegex(module.ReferenceRenderError, "differ only by case"):
            module.render_reference(metadata, RETAIL)


def _tables(text: str) -> list[list[str]]:
    """Group consecutive table lines of a Markdown text."""
    tables: list[list[str]] = []
    current: list[str] = []
    for line in text.splitlines():
        if line.startswith("|"):
            current.append(line)
        elif current:
            tables.append(current)
            current = []
    if current:
        tables.append(current)
    return tables


class IndexPageTests(unittest.TestCase):
    def setUp(self):
        self.text = render()["README.md"]

    def test_title_names_the_flavour_and_namespace(self):
        self.assertIn("# Retail API reference (wow.retail.api)", self.text)

    def test_provenance_paragraph(self):
        expected_pieces = (
            "`Example/wow-ui-source`",
            "branch `live`",
            "`" + "a" * 40 + "`",
            "`12.1.0`",
            "`69933`",
            "captured on 2026-09-24",
        )
        for expected in expected_pieces:
            self.assertIn(expected, self.text)

    def test_usage_and_raw_escape_hatch(self):
        self.assertIn("local api = wow.retail.api", self.text)
        self.assertIn("MoltenCodes.wow.retail.api", self.text)
        self.assertIn("raw Blizzard calls stay valid", self.text)

    def test_counts_table(self):
        self.assertIn("| Namespaces (`C_*` namespaces and global systems) | 2 |", self.text)
        self.assertIn("| Object types | 1 |", self.text)
        self.assertIn("| Functions (including object methods) | 4 |", self.text)
        self.assertIn("| Events | 1 |", self.text)
        self.assertIn("| Structures | 2 |", self.text)
        self.assertIn("| Constants tables | 2 |", self.text)
        self.assertIn("| Restriction predicates | 2 |", self.text)

    def test_namespace_table_links_pages_and_shows_alias(self):
        self.assertIn("| Wrapper | Raw | Kind | Functions | Alias |", self.text)
        self.assertIn(
            "| [`api.addOnProfiler`](namespaces/addOnProfiler.md) | `C_AddOnProfiler` "
            "| namespace | 1 | `api.profiler` |",
            self.text,
        )
        self.assertIn("| [`api.unit`](namespaces/unit.md) | `Unit` system | global | 2 |  |", self.text)
        self.assertNotIn("clock", self.text)

    def test_other_files_are_linked(self):
        for name in sorted(FIXED_FILES - {"README.md"}):
            self.assertIn(f"]({name})", self.text)


class NamespacePageTests(unittest.TestCase):
    def setUp(self):
        files = render()
        self.profiler = files["namespaces/addOnProfiler.md"]
        self.unit = files["namespaces/unit.md"]

    def test_title_alias_raw_namespace_environment_and_sources(self):
        self.assertIn("# api.addOnProfiler\n", self.profiler)
        self.assertIn("Also `api.profiler`", self.profiler)
        self.assertIn("Raw namespace: `C_AddOnProfiler`.", self.profiler)
        self.assertIn("Environment: `All`.", self.profiler)
        self.assertIn("Sources: `ProfilerDocumentation.lua`.", self.profiler)
        self.assertIn("[Back to the reference index](../README.md)", self.profiler)

    def test_global_system_page(self):
        self.assertIn("# api.unit\n", self.unit)
        self.assertIn("Global functions of the `Unit` system.", self.unit)
        self.assertIn("Functions about units.", self.unit)

    def test_signature_marks_optional_arguments_and_defaults(self):
        self.assertIn('api.addOnProfiler.measureCall(callback, label? = "x") -> elapsed: number', self.profiler)
        self.assertIn("api.unit.name(unit) -> name: cstring?, reason: PhaseReason?", self.unit)
        self.assertIn("api.unit.functions() -> points: Point[]", self.unit)

    def test_binding_line(self):
        self.assertIn("Binds to: `C_AddOnProfiler.MeasureCall`.", self.profiler)
        self.assertIn("Binds to: `UnitName`.", self.unit)

    def test_argument_and_return_tables(self):
        self.assertIn("| Name | Type | Nilable | Default | Notes |", self.profiler)
        self.assertIn(
            "| `callback` | [`MeasureCallback`](../callbacks.md#measurecallback) | no |  | What to time. |",
            self.profiler,
        )
        self.assertIn('| `label` | `cstring` | yes | `"x"` |  |', self.profiler)
        self.assertIn("| `elapsed` | `number` | no | flags `NeverSecret` |", self.profiler)
        self.assertIn("| `reason` | [`PhaseReason`](../enums.md#phasereason) | yes |  |", self.unit)
        self.assertIn("| `points` | `table` | no | element type [`Point`](../structures.md#point) |", self.unit)

    def test_restrictions_line_is_compact_and_omitted_when_empty(self):
        self.assertIn(
            "Restrictions: secret arguments `AllowedWhenUntainted`; may return nothing; "
            "flags `RequiresClubsInitialized`; attributes `FailureMode=ReturnNothing`.",
            self.profiler,
        )
        self.assertIn("Restrictions: has restrictions; protected.", self.unit)
        start = self.unit.index("### functions")
        end = self.unit.index("### ", start + 1)
        self.assertNotIn("Restrictions:", self.unit[start:end])

    def test_documentation_paragraphs_are_one_line_each(self):
        self.assertIn("Returns the name of the unit.\n", self.unit)
        self.assertIn("Second paragraph | with a pipe and a line break.\n", self.unit)


class CataloguePageTests(unittest.TestCase):
    def setUp(self):
        self.files = render()

    def test_events(self):
        text = self.files["events.md"]
        self.assertIn("### ADDON_LOADED", text)
        self.assertIn("Wrapper: `api.events.addonLoaded` (`AddonLoaded` in the tables). System: `AddOns`.", text)
        self.assertIn("Flags: synchronous.", text)
        self.assertIn("| `addOnName` | `cstring` | no |  |", text)

    def test_enums(self):
        text = self.files["enums.md"]
        self.assertIn("### PhaseReason", text)
        self.assertIn("`Enum.PhaseReason`, exposed as `api.enums.phaseReason`.", text)
        self.assertIn("2 values, minimum 0, maximum 1, system `Unit`.", text)
        self.assertIn("| Field | Value | Notes |", text)
        self.assertIn("| `Sharding` | 1 | Shards. |", text)

    def test_structures_link_types_and_show_maps(self):
        text = self.files["structures.md"]
        self.assertIn("### Budget", text)
        self.assertIn("System: `Housing`.", text)
        self.assertIn(
            "| `limits` | `table` | yes |  | element type `number`; key type [`PhaseReason`](enums.md#phasereason) |",
            text,
        )
        self.assertIn("| `origin` | [`Point`](structures.md#point) | no | `false` | mixin `PointMixin` |", text)

    def test_callbacks(self):
        text = self.files["callbacks.md"]
        self.assertIn("### MeasureCallback", text)
        self.assertIn("callback(value)", text)
        self.assertIn("| `value` | `number` | no |  |  |", text)

    def test_constants_show_expressions_as_code(self):
        text = self.files["constants.md"]
        self.assertIn("### CalendarConstants", text)
        self.assertIn("`Constants.CalendarConstants`, exposed as `api.constants.calendarConstants`.", text)
        self.assertIn("| Name | Type | Value | Notes |", text)
        self.assertIn(
            "| `DEFAULT_TYPE` | [`PhaseReason`](enums.md#phasereason) | `Enum.PhaseReason.Sharding` | expression |",
            text,
        )
        self.assertIn("| `MAX_DAYS` | `number` | `31` | Days per page. |", text)
        self.assertIn("| `DEFAULT_MULTIPLIER` | `number` | `1.5` |  |", text)

    def test_objects(self):
        text = self.files["objects.md"]
        self.assertIn("### Clock", text)
        self.assertIn("Object type: `Userdata`.", text)
        self.assertIn("| Method | Signature |", text)
        self.assertIn("| `Now` | `object:Now()` |", text)

    def test_restrictions(self):
        text = self.files["restrictions.md"]
        self.assertIn("| System | Predicate | Kind | Failure mode | Notes |", text)
        self.assertIn("|  | `HasRestrictions` | precondition | `Error` |  |", text)
        self.assertIn(
            "| `Unit` | `HasRestrictions` | precondition | `ReturnNothing` | Only when the unit is visible. |", text
        )


class SearchIndexTests(unittest.TestCase):
    def setUp(self):
        self.metadata = extended_metadata()
        self.index = module.render_search_index(self.metadata, RETAIL)
        self.entries = self.index["entries"]

    def test_head_fields(self):
        self.assertEqual(1, self.index["schema"])
        self.assertEqual("retail", self.index["flavour"])
        self.assertEqual(69933, self.index["build"])

    def test_is_json_serialisable(self):
        json.dumps(self.index)

    def test_entries_are_sorted_by_kind_then_name(self):
        keys = [(entry["kind"], entry["name"]) for entry in self.entries]

        self.assertEqual(sorted(keys), keys)

    def test_every_entry_has_the_documented_fields(self):
        for entry in self.entries:
            self.assertEqual({"kind", "name", "wrapper", "path", "summary"}, set(entry))

    def test_function_entry(self):
        entry = self._entry("function", "UnitName")

        self.assertEqual("api.unit.name", entry["wrapper"])
        self.assertEqual("namespaces/unit.md#name", entry["path"])
        self.assertEqual("Returns the name of the unit.", entry["summary"])

    def test_duplicate_heading_gets_the_github_suffix(self):
        entry = self._entry("function", "UnitFunctions")

        self.assertEqual("namespaces/unit.md#functions-1", entry["path"])

    def test_namespace_event_enum_constants_and_object_entries(self):
        self.assertEqual("api.addOnProfiler", self._entry("namespace", "C_AddOnProfiler")["wrapper"])
        self.assertEqual("namespaces/unit.md#apiunit", self._entry("namespace", "Unit")["path"])
        self.assertEqual("events.md#addon_loaded", self._entry("event", "ADDON_LOADED")["path"])
        self.assertEqual("api.enums.phaseReason", self._entry("enum", "Enum.PhaseReason")["wrapper"])
        constants = self._entry("constants", "Constants.CalendarConstants")
        self.assertEqual("constants.md#calendarconstants", constants["path"])
        self.assertEqual("objects.md#clock", self._entry("object", "Clock")["path"])
        self.assertEqual("objects.md#clock", self._entry("method", "Clock:Now")["path"])
        self.assertEqual("", self._entry("structure", "Point")["wrapper"])
        self.assertEqual("restrictions.md", self._entry("restriction", "Unit.HasRestrictions")["path"])

    def test_every_path_resolves_in_the_rendered_reference(self):
        files = module.render_reference(self.metadata, RETAIL)
        links = "\n\n".join(f"[{entry['name']}]({entry['path']})" for entry in self.entries)
        files["probe.md"] = "# Probe\n\n" + links + "\n"

        self.assertEqual([], module.check_links(files))

    def test_summary_is_empty_without_documentation(self):
        self.assertEqual("", self._entry("event", "ADDON_LOADED")["summary"])

    def test_summary_is_cut_at_a_word_boundary(self):
        words = " ".join(f"word{index}" for index in range(60))

        summary = module.summarise((words, "second paragraph"))

        self.assertLessEqual(len(summary), module.SUMMARY_LENGTH)
        self.assertTrue(summary.endswith("..."))
        head = summary[: -len("...")]
        self.assertTrue(words.startswith(head))
        self.assertEqual(" ", words[len(head)])

    def test_short_summary_is_kept_whole(self):
        self.assertEqual("Short.", module.summarise(("Short.",)))
        self.assertEqual("", module.summarise(()))

    def test_index_is_deterministic(self):
        self.assertEqual(self.index, module.render_search_index(extended_metadata(), RETAIL))

    def _entry(self, kind: str, name: str) -> dict[str, str]:
        matches = [entry for entry in self.entries if entry["kind"] == kind and entry["name"] == name]
        self.assertEqual(1, len(matches), f"{kind} {name}")
        return matches[0]


class CorpusTests(unittest.TestCase):
    """Render a real metadata directory when one is named.

    Point `MOLTENCODES_API_METADATA` at a directory `tooling.api.normalize`
    wrote for the Retail flavour. Nothing from it is copied into the
    repository; the test asserts only that the reference is self-consistent
    and that its counts are the metadata's.
    """

    def test_real_metadata_renders_a_self_consistent_reference(self):
        directory_name = os.environ.get(METADATA_DIRECTORY_VARIABLE) or str(
            ROOT / "packages" / "apiKit" / "metadata" / "retail"
        )
        if not directory_name or not Path(directory_name).is_dir():
            self.skipTest(f"{METADATA_DIRECTORY_VARIABLE} does not name an existing directory")
        metadata = model.read_metadata(Path(directory_name))
        flavour = flavours.load_flavours().by_id(metadata.provenance.flavour)

        files = module.render_reference(metadata, flavour)
        index = module.render_search_index(metadata, flavour)

        self.assertEqual([], module.check_links(files))
        counts = module.reference_counts(metadata)
        readme = files["README.md"]
        self.assertIn(f"| Events | {counts['events']} |", readme)
        self.assertIn(f"| Enumerations | {counts['enums']} |", readme)
        self.assertIn(f"| Structures | {counts['structures']} |", readme)
        self.assertIn(f"| Functions (including object methods) | {counts['functions']} |", readme)
        self.assertEqual(len(metadata.events), sum(1 for entry in index["entries"] if entry["kind"] == "event"))
        self.assertEqual(
            counts["functions"],
            sum(1 for entry in index["entries"] if entry["kind"] in ("function", "method")),
        )
        namespace_pages = [name for name in files if name.startswith("namespaces/")]
        self.assertEqual(counts["namespaces"], len(namespace_pages))
        self.assertEqual(counts["enums"], files["enums.md"].count("\n### "))


if __name__ == "__main__":
    unittest.main()
