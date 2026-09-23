"""Tests that keep the example addon in step with the framework it embeds."""

from __future__ import annotations

import shutil
import subprocess
import unittest

from tooling.package import build as package_build
from tooling.validation.validate_manifests import ROOT, load_manifests

# Reading ``embeds.xml`` belongs to the validator, which enforces the example's
# editor configuration against it; the tests read it through the same helpers so
# the two can never disagree about what the example embeds.
from tooling.validation.validate_repository import embedded_script_names, package_id_for


EXAMPLES = ROOT / "examples"


class ExampleAddonLayoutTests(unittest.TestCase):
    def setUp(self):
        self.manifests, errors = load_manifests()
        self.assertEqual([], errors)
        self.scripts = embedded_script_names(EXAMPLES / "embeds.xml")

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
        self.assertGreaterEqual(len(entries), 2)
        self.assertEqual("embeds.xml", entries[0])
        self.assertEqual("Core.lua", entries[1])
        # `.toc` paths use the client's backslashes; every one must name a file
        # that ships with the example.
        for entry in entries:
            self.assertTrue(
                (EXAMPLES / entry.replace("\\", "/")).is_file(),
                f"ExampleAddon.toc lists {entry}, which does not exist under examples/",
            )

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
