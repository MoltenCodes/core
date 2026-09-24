"""Tests for the generated runtime bindings file."""

from __future__ import annotations

import dataclasses
import shutil
import subprocess
import tempfile
import textwrap
import unittest
from pathlib import Path

from tooling.api import flavours, model
from tooling.api import render_runtime as module
from tooling.tests.test_api_model import sample_metadata
from tooling.validation.validate_manifests import ROOT


RETAIL = flavours.load_flavours().by_id("retail")


def render(metadata: model.FlavourMetadata | None = None) -> str:
    return module.render_runtime(metadata or sample_metadata(), RETAIL)


class HeaderAndDependencyTests(unittest.TestCase):
    def test_header_names_the_flavour_and_the_provenance(self):
        text = render()

        self.assertIn("-- MoltenCodes ApiKit: Retail bindings (wow.retail.api)", text)
        self.assertIn("GENERATED FILE. Do not edit.", text)
        self.assertIn(f"Example/wow-ui-source@{'a' * 40} (live)", text)
        self.assertIn("client 12.1.0, build 69933, captured 2026-09-24", text)

    def test_facade_is_resolved_through_registry_api_2(self):
        text = render()

        self.assertIn('rawget(generations, 2)', text)
        self.assertIn('local getPackage = rawget(Registry, "Get")', text)
        self.assertIn('local ApiKit = getPackage(Registry, "apiKit", 1)', text)
        self.assertIn('or rawget(ApiKit, "API") ~= 1', text)
        self.assertIn("requires Registry API 2 to be loaded first", text)
        self.assertIn("requires ApiKit API 1 to be loaded first", text)
        self.assertIn('ApiKit:RegisterFlavor("retail", function(api, host)', text)
        self.assertTrue(text.endswith('end, { version = "12.1.0", build = 69933 })\n'))

    def test_long_error_messages_wrap_like_stylua(self):
        long_flavour = dataclasses.replace(RETAIL, display_name="Mists of Pandaria Classic Public Test Realm")

        text = module.render_runtime(sample_metadata(), long_flavour)

        self.assertIn("  error(\n    \"MoltenCodes ApiKit (Mists of Pandaria Classic Public Test Realm bindings) requires Registry API 2 to be loaded first\",\n    2\n  )\n", text)

    def test_registration_without_a_known_build_passes_no_info(self):
        metadata = sample_metadata()
        metadata = dataclasses.replace(
            metadata, provenance=dataclasses.replace(metadata.provenance, version=None, build=None)
        )

        self.assertTrue(render(metadata).endswith("end)\n"))


class BindingTests(unittest.TestCase):
    def test_namespace_functions_are_direct_aliases_guarded_by_the_host_table(self):
        text = render()

        block = textwrap.dedent(
            """\
                do
                  local source = host.C_AddOnProfiler
                  if source then
                    local target = {}
                    api.addOnProfiler = target
                    api.profiler = target
                    target.measureCall = source.MeasureCall
                  end
                end
            """
        )
        self.assertIn(textwrap.indent(block, module.INDENT), text)

    def test_global_functions_are_read_from_the_host_by_name(self):
        metadata = sample_metadata()
        unit = model.Namespace(
            wrapper="unit",
            kind="global",
            system="Unit",
            functions=(model.Function(name="UnitName", wrapper="name", binding="UnitName"),),
        )
        metadata = dataclasses.replace(metadata, namespaces=(*metadata.namespaces, unit))

        text = render(metadata)

        self.assertIn("    api.unit = target\n    target.name = host.UnitName\n", text)

    def test_object_types_produce_nothing(self):
        self.assertNotIn("Clock", render().replace("Example/wow-ui-source", ""))

    def test_events_enums_and_constants_blocks(self):
        text = render()

        self.assertIn('  api.events = {\n    addonLoaded = "ADDON_LOADED",\n  }\n', text)
        self.assertIn("    local source = host.Enum or {}\n", text)
        self.assertIn("    api.enums = target\n    target.phaseReason = source.PhaseReason\n", text)
        self.assertIn("    local source = host.Constants or {}\n", text)
        self.assertIn("    target.auctionConstants = source.AuctionConstants\n", text)

    def test_names_that_are_not_identifiers_use_bracket_access(self):
        metadata = sample_metadata()
        odd = model.Namespace(
            wrapper="odd",
            kind="global",
            system="Odd",
            functions=(model.Function(name="end", wrapper="end", binding="end"),),
        )
        metadata = dataclasses.replace(metadata, namespaces=(*metadata.namespaces, odd))

        text = render(metadata)

        self.assertIn('target["end"] = host["end"]', text)

    def test_long_bindings_wrap_after_the_equals_sign(self):
        long_name = "GetActionLossOfControlCooldownDurationForTheCurrentlyHoveredActionSlot"
        metadata = sample_metadata()
        namespace = metadata.namespaces[0]
        function = model.Function(
            name=long_name, wrapper=long_name[0].lower() + long_name[1:], binding=f"C_AddOnProfiler.{long_name}"
        )
        namespace = dataclasses.replace(namespace, functions=(function,))
        metadata = dataclasses.replace(metadata, namespaces=(namespace, metadata.namespaces[1]))

        text = render(metadata)

        self.assertIn(f"      target.{function.wrapper} =\n        source.{long_name}\n", text)
        self.assertTrue(all(len(line) <= 100 for line in text.splitlines()), "a line exceeds 100 columns")

    def test_indentation_is_built_from_one_two_space_unit(self):
        self.assertEqual("  ", module.INDENT)
        for line in render().splitlines():
            leading = len(line) - len(line.lstrip(" "))
            self.assertEqual(0, leading % len(module.INDENT), repr(line))

    def test_reserved_wrapper_names_are_refused(self):
        metadata = sample_metadata()
        first = dataclasses.replace(metadata.namespaces[0], alias="events")
        metadata = dataclasses.replace(metadata, namespaces=(first, metadata.namespaces[1]))

        with self.assertRaisesRegex(module.RuntimeRenderError, "reserved"):
            render(metadata)

    def test_rendering_is_deterministic(self):
        self.assertEqual(render(), render())

    def test_runtime_file_name_comes_from_the_flavour_table(self):
        self.assertEqual("flavours/Retail.lua", module.runtime_file_name(RETAIL))


HARNESS = textwrap.dedent(
    """\
    local installers = {}
    local ApiKit = {
        API = 1,
        RegisterFlavor = function(_, flavour, install)
            installers[flavour] = install
        end,
    }
    MoltenCodes = { Registries = { [2] = { API = 2, Get = function() return ApiKit end } } }
    local infos = {}
    ApiKit.RegisterFlavor = function(_, flavour, install, info)
        installers[flavour] = install
        infos[flavour] = info
    end
    assert(loadfile(arg[1]))()
    assert(infos.retail.build == 69933 and infos.retail.version == "12.1.0", "info")
    local function measure() return 1 end
    local host = {
        C_AddOnProfiler = { MeasureCall = measure },
        UnitName = function() return "name" end,
        Enum = { PhaseReason = { Phasing = 0 } },
    }
    local api = {}
    installers.retail(api, host)
    assert(api.addOnProfiler.measureCall == measure, "alias")
    assert(api.profiler == api.addOnProfiler, "alias table")
    assert(api.missing == nil, "namespace absent from the host is not bound")
    assert(api.unit.name() == "name", "global")
    assert(api.events.addonLoaded == "ADDON_LOADED", "event")
    assert(api.enums.phaseReason.Phasing == 0, "enum")
    assert(api.constants.auctionConstants == nil, "constants table absent from the host")
    print("ok")
    """
)


class LuaExecutionTests(unittest.TestCase):
    """The generated file runs under Lua 5.1 against a stub host and binds as documented."""

    def setUp(self):
        self.lua = shutil.which("lua") or shutil.which("lua5.1")
        if self.lua is None:
            self.skipTest("no Lua interpreter on PATH")

    def test_generated_file_installs_direct_aliases(self):
        metadata = sample_metadata()
        missing = model.Namespace(
            wrapper="missing",
            kind="namespace",
            system="Missing",
            blizzard_namespace="C_Missing",
            functions=(model.Function(name="Gone", wrapper="gone", binding="C_Missing.Gone"),),
        )
        unit = model.Namespace(
            wrapper="unit",
            kind="global",
            system="Unit",
            functions=(model.Function(name="UnitName", wrapper="name", binding="UnitName"),),
        )
        metadata = dataclasses.replace(metadata, namespaces=(*metadata.namespaces, missing, unit))

        with tempfile.TemporaryDirectory() as directory:
            runtime = Path(directory) / "Retail.lua"
            runtime.write_text(render(metadata), encoding="utf-8")
            harness = Path(directory) / "harness.lua"
            harness.write_text(HARNESS, encoding="utf-8")

            completed = subprocess.run(
                [self.lua, str(harness), str(runtime)], capture_output=True, text=True, check=False
            )

        self.assertEqual(0, completed.returncode, completed.stderr)
        self.assertEqual("ok", completed.stdout.strip())

    def test_generated_file_is_formatted_as_stylua_wants(self):
        stylua = shutil.which("stylua")
        if stylua is None:
            self.skipTest("stylua is not on PATH")
        with tempfile.TemporaryDirectory() as directory:
            runtime = Path(directory) / "Retail.lua"
            runtime.write_text(render(), encoding="utf-8")
            completed = self._stylua_check(stylua, runtime)

        self.assertEqual(0, completed.returncode, completed.stdout + completed.stderr)

    def test_wrapping_at_the_column_limit_matches_stylua(self):
        """Bindings one column either side of the limit, at every nesting depth, need no reformatting."""
        stylua = shutil.which("stylua")
        if stylua is None:
            self.skipTest("stylua is not on PATH")
        metadata = sample_metadata()
        namespace = metadata.namespaces[0]
        namespaced = []
        global_functions = []
        # `target.<wrapper> = source.<Name>` at depth 3 and `= host.<Name>` at
        # depth 2: a wrapper of n letters and a name of n or n + 1 letters walk
        # the line length across the limit one column at a time.
        for length in range(36, 46):
            for extra, marker in enumerate("AB"):
                name = f"G{marker}" + "x" * (length - 2 + extra)
                wrapper = f"g{marker.lower()}" + "x" * (length - 2)
                namespaced.append(
                    model.Function(name=name, wrapper=wrapper, binding=f"C_AddOnProfiler.{name}")
                )
                global_functions.append(model.Function(name=name, wrapper=wrapper, binding=name))
        namespace = dataclasses.replace(namespace, functions=tuple(namespaced))
        globals_namespace = model.Namespace(
            wrapper="edge", kind="global", system="Edge", functions=tuple(global_functions)
        )
        metadata = dataclasses.replace(
            metadata, namespaces=(namespace, metadata.namespaces[1], globals_namespace)
        )
        text = render(metadata)
        lengths = {len(line) for line in text.splitlines()}
        self.assertIn(100, lengths, "no binding sits exactly at the limit")
        self.assertTrue(any("=" == line.rstrip()[-1:] for line in text.splitlines()), "nothing wrapped")

        with tempfile.TemporaryDirectory() as directory:
            runtime = Path(directory) / "Retail.lua"
            runtime.write_text(text, encoding="utf-8")
            completed = self._stylua_check(stylua, runtime)

        self.assertEqual(0, completed.returncode, completed.stdout + completed.stderr)

    @staticmethod
    def _stylua_check(stylua: str, path: Path) -> subprocess.CompletedProcess:
        return subprocess.run(
            [stylua, "--check", "--config-path", str(ROOT / "stylua.toml"), str(path)],
            capture_output=True,
            text=True,
            check=False,
        )


if __name__ == "__main__":
    unittest.main()
