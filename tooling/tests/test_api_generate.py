"""Tests for the apiKit generator that writes every output of a flavour."""

from __future__ import annotations

import dataclasses
import io
import json
import tempfile
import unittest
from contextlib import redirect_stderr, redirect_stdout
from pathlib import Path

from tooling.api import flavours, model
from tooling.api import generate as module
from tooling.tests.test_api_model import sample_metadata


RETAIL = flavours.load_flavours().by_id("retail")


class GeneratorFixture(unittest.TestCase):
    """A temporary package directory holding the sample metadata for Retail."""

    def setUp(self):
        self.tempdir = tempfile.TemporaryDirectory()
        self.package_dir = Path(self.tempdir.name) / "apiKit"
        self.metadata_dir = self.package_dir / "metadata" / "retail"
        model.write_metadata(sample_metadata(), self.metadata_dir)

    def tearDown(self):
        self.tempdir.cleanup()

    def run_main(self, *arguments: str) -> tuple[int, str, str]:
        output, errors = io.StringIO(), io.StringIO()
        with redirect_stdout(output), redirect_stderr(errors):
            status = module.main(["--package-dir", str(self.package_dir), *arguments])
        return status, output.getvalue(), errors.getvalue()


class PlanTests(GeneratorFixture):
    def test_plan_lists_every_output_as_changed_on_a_fresh_package(self):
        result = module.plan_flavour(RETAIL, package_dir=self.package_dir)

        changed = {path.relative_to(self.package_dir).as_posix() for path in result.changed}
        self.assertIn("src/flavours/Retail.lua", changed)
        self.assertIn("types/retail/api.lua", changed)
        self.assertIn("docs/reference/retail/README.md", changed)
        self.assertIn("metadata/retail/search.json", changed)
        self.assertIn("metadata/retail/history.json", changed)
        self.assertEqual([], result.removed)

    def test_invalid_metadata_is_refused(self):
        metadata = sample_metadata()
        broken = dataclasses.replace(metadata, events=(metadata.events[0], metadata.events[0]))
        model.write_metadata(broken, self.metadata_dir)

        with self.assertRaisesRegex(module.GenerateError, "not valid"):
            module.plan_flavour(RETAIL, package_dir=self.package_dir)

    def test_metadata_of_another_flavour_is_refused(self):
        other = flavours.load_flavours().by_id("beta")

        with self.assertRaisesRegex(module.GenerateError, "not 'beta'"):
            module.plan_flavour(other, package_dir=self.package_dir, metadata_dir=self.metadata_dir)

    def test_missing_metadata_is_refused(self):
        with self.assertRaisesRegex(module.GenerateError, "missing"):
            module.plan_flavour(flavours.load_flavours().by_id("beta"), package_dir=self.package_dir)


class WriteTests(GeneratorFixture):
    def test_generation_writes_and_a_second_run_is_up_to_date(self):
        status, output, errors = self.run_main("--flavour", "retail")

        self.assertEqual(0, status, errors)
        self.assertTrue((self.package_dir / "src" / "flavours" / "Retail.lua").is_file())
        self.assertTrue((self.package_dir / "types" / "retail" / "api.lua").is_file())
        self.assertTrue((self.package_dir / "docs" / "reference" / "retail" / "README.md").is_file())
        self.assertTrue((self.metadata_dir / "search.json").is_file())
        history = json.loads((self.metadata_dir / "history.json").read_text(encoding="utf-8"))
        self.assertEqual(1, len(history["entries"]))
        self.assertEqual(69933, history["entries"][0]["build"])
        self.assertIsNone(history["entries"][0].get("report"))

        status, output, errors = self.run_main("--flavour", "retail", "--check")

        self.assertEqual(0, status, errors)
        self.assertIn("would change 0 file(s)", output)

    def test_check_fails_when_an_output_is_stale(self):
        self.run_main("--flavour", "retail")
        (self.package_dir / "src" / "flavours" / "Retail.lua").write_text("-- edited\n", encoding="utf-8")

        status, output, errors = self.run_main("--flavour", "retail", "--check")

        self.assertEqual(1, status)
        self.assertIn("Retail.lua", output)
        self.assertIn("out of date", errors)

    def test_stale_files_in_a_generated_directory_are_removed(self):
        self.run_main("--flavour", "retail")
        stray = self.package_dir / "types" / "retail" / "old.lua"
        stray.write_text("-- stray\n", encoding="utf-8")

        status, output, errors = self.run_main("--flavour", "retail")

        self.assertEqual(0, status, errors)
        self.assertFalse(stray.exists())
        self.assertIn("removed 1", output)

    def test_previous_metadata_produces_a_report_and_a_history_entry(self):
        self.run_main("--flavour", "retail")
        previous_dir = Path(self.tempdir.name) / "previous"
        model.write_metadata(sample_metadata(), previous_dir)
        newer = sample_metadata()
        newer = dataclasses.replace(
            newer,
            provenance=dataclasses.replace(newer.provenance, commit="c" * 40, build=70000, version="12.1.5"),
            events=(),
        )
        model.write_metadata(newer, self.metadata_dir)

        status, output, errors = self.run_main("--flavour", "retail", "--previous", str(previous_dir))

        self.assertEqual(0, status, errors)
        report = self.package_dir / "docs" / "changes" / "retail" / "69933-70000.md"
        self.assertTrue(report.is_file())
        self.assertIn("ADDON_LOADED", report.read_text(encoding="utf-8"))
        history = json.loads((self.metadata_dir / "history.json").read_text(encoding="utf-8"))
        self.assertEqual(2, len(history["entries"]))
        self.assertEqual("docs/changes/retail/69933-70000.md", history["entries"][1]["report"])
        self.assertEqual({"added": 0, "removed": 1, "changed": 0}, history["entries"][1]["counts"]["event"])

    def test_history_is_not_repeated_for_the_same_commit(self):
        self.run_main("--flavour", "retail")
        self.run_main("--flavour", "retail")

        history = json.loads((self.metadata_dir / "history.json").read_text(encoding="utf-8"))
        self.assertEqual(1, len(history["entries"]))

    def test_all_selects_every_flavour_with_metadata(self):
        status, output, errors = self.run_main("--all")

        self.assertEqual(0, status, errors)
        self.assertIn("retail:", output)
        self.assertNotIn("beta:", output)

    def test_all_rejects_flavour_specific_options(self):
        with self.assertRaises(SystemExit):
            self.run_main("--all", "--previous", str(self.metadata_dir))

    def test_unknown_flavour_is_an_error(self):
        status, output, errors = self.run_main("--flavour", "wrath")

        self.assertEqual(1, status)
        self.assertIn("unknown flavour", errors)


if __name__ == "__main__":
    unittest.main()
