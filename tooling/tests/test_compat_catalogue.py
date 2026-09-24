"""The CompatKit catalogue names real documented APIs, per flavour.

`CompatKit.CATALOGUE` lists taint-hostile Blizzard subsystems with their
sanctioned replacements. A row whose replacement is a documented client API
names it in `replacementApi` and lists, in `flavours`, the apiKit flavours whose
committed metadata documents that function. This suite loads the package under
Lua 5.1 against the real Registry, prints the catalogue, and checks every such
row against `packages/apiKit/metadata/<flavour>/namespaces.json`: the function
must be documented by at least one flavour, and the row's flavour list must be
exactly the set of flavours that document it. A row without a `replacementApi`
must list no flavour. The same rows must appear, in the same order, in the
table under "Catalogue of taint-hostile subsystems" in `docs/EMBEDDING.md`.

The suite needs a Lua 5.1 interpreter on the path and is skipped without one.
"""

from __future__ import annotations

import json
import re
import shutil
import subprocess
import tempfile
import textwrap
import unittest
from pathlib import Path

from tooling.validation.validate_manifests import ROOT


METADATA_DIR = ROOT / "packages" / "apiKit" / "metadata"
FLAVOURS_FILE = ROOT / "tooling" / "api" / "flavours.json"
REGISTRY_SOURCE = ROOT / "packages" / "registry" / "src" / "Registry.lua"
COMPATKIT_SOURCE = ROOT / "packages" / "compatKit" / "src" / "CompatKit.lua"
EMBEDDING_DOC = ROOT / "docs" / "EMBEDDING.md"
CATALOGUE_HEADING = "### Catalogue of taint-hostile subsystems"

#: Field separator in the harness output; no catalogue text contains it.
SEPARATOR = "\t"

#: Loads Registry and CompatKit and prints one catalogue row per line.
HARNESS = textwrap.dedent(
    """\
    local registryFile, compatKitFile = arg[1], arg[2]
    assert(loadfile(registryFile))()
    local CompatKit = assert(loadfile(compatKitFile))()
    for index = 1, CompatKit.CATALOGUE_COUNT do
        local row = CompatKit.CATALOGUE[index]
        local flavours = {}
        for position = 1, row.flavourCount do
            flavours[position] = row.flavours[position]
        end
        print(table.concat({
            row.subsystem,
            row.replacementApi or "",
            table.concat(flavours, ","),
        }, "\\t"))
    end
    """
)


def documented_functions(flavour_dir: Path) -> set[str]:
    """Return every documented function of one flavour as `Namespace.Function` or `Function`."""
    data = json.loads((flavour_dir / "namespaces.json").read_text(encoding="utf-8"))
    names: set[str] = set()
    for namespace in data["namespaces"]:
        for function in namespace.get("functions", []):
            if namespace["kind"] == "namespace":
                names.add(f"{namespace['blizzardNamespace']}.{function['name']}")
            elif namespace["kind"] == "global":
                names.add(function["name"])
    return names


def flavour_ids() -> list[str]:
    """Return the flavour ids `tooling/api/flavours.json` declares, sorted."""
    data = json.loads(FLAVOURS_FILE.read_text(encoding="utf-8"))
    return sorted(entry["id"] for entry in data["flavours"])


def documented_subsystems() -> list[str]:
    """Return the first cell of every data row of the EMBEDDING.md catalogue table, in order."""
    text = EMBEDDING_DOC.read_text(encoding="utf-8")
    start = text.index(CATALOGUE_HEADING)
    section = text[start + len(CATALOGUE_HEADING) :]
    next_heading = section.find("\n## ")
    if next_heading >= 0:
        section = section[:next_heading]
    subsystems: list[str] = []
    for line in section.splitlines():
        match = re.match(r"^\|\s*`?([^|`]+?)`?\s*\|", line)
        if match is None:
            continue
        first = match.group(1)
        if first == "Subsystem" or re.fullmatch(r"-+", first):
            continue
        subsystems.append(first)
    return subsystems


class CompatCatalogueTests(unittest.TestCase):
    def setUp(self) -> None:
        self.lua = shutil.which("lua") or shutil.which("lua5.1")
        if self.lua is None:
            self.skipTest("no Lua 5.1 interpreter on the path")
        self.flavours = {
            path.name: documented_functions(path) for path in sorted(METADATA_DIR.iterdir()) if path.is_dir()
        }
        self.rows = self._load_catalogue()

    def _load_catalogue(self) -> list[tuple[str, str, list[str]]]:
        # `lua -e` leaves `arg` unset, so the harness runs from a file.
        with tempfile.TemporaryDirectory() as scratch:
            harness = Path(scratch) / "catalogue_harness.lua"
            harness.write_text(HARNESS, encoding="utf-8")
            result = subprocess.run(
                [self.lua, str(harness), str(REGISTRY_SOURCE), str(COMPATKIT_SOURCE)],
                capture_output=True,
                text=True,
                check=False,
            )
        self.assertEqual(0, result.returncode, result.stderr)
        rows: list[tuple[str, str, list[str]]] = []
        for line in result.stdout.splitlines():
            subsystem, replacement_api, flavours = line.split(SEPARATOR)
            rows.append((subsystem, replacement_api, [f for f in flavours.split(",") if f]))
        return rows

    def test_metadata_covers_every_declared_flavour(self):
        self.assertEqual(flavour_ids(), sorted(self.flavours))

    def test_rows_name_declared_flavours_only(self):
        declared = set(flavour_ids())
        for subsystem, _, flavours in self.rows:
            for flavour in flavours:
                self.assertIn(flavour, declared, subsystem)

    def test_catalogue_has_the_required_rows(self):
        subsystems = "\n".join(subsystem for subsystem, _, _ in self.rows)
        for required in (
            "UIDropDownMenu",
            "StaticPopup",
            "ActionButton_ShowOverlayGlow",
            "tooltip scanning",
            "GetAddOnMetadata",
            "ShowUIPanel",
            "InterfaceOptionsFrame_OpenToCategory",
            "SetOverrideBindingClick",
            "CompactUnitFrame",
        ):
            self.assertIn(required, subsystems)

    def test_every_replacement_api_is_documented_by_at_least_one_flavour(self):
        for subsystem, replacement_api, _ in self.rows:
            if not replacement_api:
                continue
            documenting = [name for name, functions in self.flavours.items() if replacement_api in functions]
            self.assertTrue(documenting, f"{subsystem}: {replacement_api} is documented by no flavour")

    def test_flavour_lists_match_the_metadata_exactly(self):
        for subsystem, replacement_api, flavours in self.rows:
            expected = sorted(name for name, functions in self.flavours.items() if replacement_api in functions)
            if not replacement_api:
                expected = []
            self.assertEqual(expected, flavours, f"{subsystem}: flavours of {replacement_api}")

    def test_rows_mirror_the_embedding_document_in_order(self):
        self.assertEqual([subsystem for subsystem, _, _ in self.rows], documented_subsystems())


if __name__ == "__main__":
    unittest.main()
