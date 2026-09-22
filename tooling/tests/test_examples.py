"""Tests that keep the example addon in step with the framework it embeds."""

from __future__ import annotations

import re
import shutil
import subprocess
import unittest
from pathlib import Path

from tooling.package import build as package_build
from tooling.validation.validate_manifests import ROOT, load_manifests


EXAMPLES = ROOT / "examples"
SCRIPT_RE = re.compile(r'<Script\s+file="([^"]+)"\s*/>')


def embedded_script_names() -> list[str]:
    """Return the Lua file names ``embeds.xml`` lists, in load order."""
    xml = (EXAMPLES / "embeds.xml").read_text(encoding="utf-8")
    return [reference.replace("\\", "/").rsplit("/", 1)[-1] for reference in SCRIPT_RE.findall(xml)]


def package_id_for(script_name: str) -> str:
    """Map ``SignalKit.lua`` to the package ID ``signalKit``."""
    facade = script_name[: -len(".lua")]
    return facade[0].lower() + facade[1:]


class ExampleAddonLayoutTests(unittest.TestCase):
    def setUp(self):
        self.manifests, errors = load_manifests()
        self.assertEqual([], errors)
        self.scripts = embedded_script_names()

    def test_embeds_xml_lists_scripts(self):
        self.assertTrue(self.scripts, "embeds.xml lists no scripts")

    def test_every_embedded_script_belongs_to_a_package(self):
        for script in self.scripts:
            package_id = package_id_for(script)
            self.assertIn(package_id, self.manifests, f"{script} has no package")
            source = ROOT / "packages" / package_id / "src" / script
            self.assertTrue(source.is_file(), f"missing source: {source}")

    def test_embedded_scripts_are_in_dependency_order(self):
        seen: set[str] = set()
        for script in self.scripts:
            package_id = package_id_for(script)
            dependencies = self.manifests[package_id].get("dependencies", {})
            for dependency in sorted(dependencies):
                self.assertIn(
                    dependency,
                    seen,
                    f"{script} is listed before its dependency {dependency}",
                )
            seen.add(package_id)

    def test_toc_loads_embeds_before_addon_code(self):
        toc = (EXAMPLES / "ExampleAddon.toc").read_text(encoding="utf-8")
        entries = [
            line.strip()
            for line in toc.splitlines()
            if line.strip() and not line.strip().startswith(("#", "##"))
        ]
        self.assertEqual(["embeds.xml", "Core.lua"], entries)

    def test_toc_declares_the_fields_the_documentation_promises(self):
        toc = (EXAMPLES / "ExampleAddon.toc").read_text(encoding="utf-8")
        for field in ("## Interface:", "## Title:", "## Notes:", "## Version:", "## SavedVariables:"):
            self.assertIn(field, toc)

    def test_load_order_matches_the_builder(self):
        """The builder's `loadOrder` is what the documentation tells readers to copy."""
        ordered = package_build.load_order(
            [package_id_for(script) for script in self.scripts], self.manifests
        )
        expected = [f"{name}/{package_build.facade_file_name(name)}" for name in ordered]
        actual = [f"{package_id_for(script)}/{script}" for script in self.scripts]
        self.assertEqual(expected, actual)


class ExampleAddonSpecTests(unittest.TestCase):
    def test_busted_spec_passes(self):
        busted = shutil.which("busted")
        if busted is None:
            self.skipTest("Busted is not on PATH; see docs/DEVELOPMENT.md")

        result = subprocess.run(
            [busted, "examples/tests"],
            cwd=ROOT,
            check=False,
            capture_output=True,
            text=True,
        )
        self.assertEqual(0, result.returncode, result.stdout + result.stderr)


if __name__ == "__main__":
    unittest.main()
