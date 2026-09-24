"""Tests for the apiKit flavour table and its loader."""

from __future__ import annotations

import copy
import io
import json
import tempfile
import unittest
from contextlib import redirect_stdout
from pathlib import Path

from tooling.api import flavours as module


VALID_TABLE = {
    "verified": "2026-09-24",
    "mirror": {
        "repository": "Example/wow-ui-source",
        "documentationPath": "Interface/AddOns/Blizzard_APIDocumentationGenerated",
    },
    "probes": {"projectId": "WOW_PROJECT_ID", "testBuild": "IsTestBuild", "betaBuild": "IsBetaBuild"},
    "flavours": [
        {
            "id": "retail",
            "displayName": "Retail",
            "namespace": "wow.retail.api",
            "runtimeFile": "flavours/Retail.lua",
            "branches": ["live"],
            "detection": {"projectId": 1, "testBuild": False, "betaBuild": False},
        },
        {
            "id": "classic-era",
            "displayName": "Classic Era",
            "namespace": "wow.classic.era.api",
            "runtimeFile": "flavours/ClassicEra.lua",
            "branches": ["classic_era"],
            "detection": {"projectId": 2, "testBuild": False, "betaBuild": False},
        },
        {
            "id": "ptr",
            "displayName": "Public Test Realm",
            "namespace": "wow.ptr.api",
            "runtimeFile": "flavours/Ptr.lua",
            "branches": ["ptr", "ptr2"],
            "detection": {"projectId": 1, "testBuild": True, "betaBuild": False},
        },
    ],
}


class FlavourParsingTests(unittest.TestCase):
    def table(self) -> dict:
        return copy.deepcopy(VALID_TABLE)

    def test_valid_table_is_parsed_in_order(self):
        table = module.parse_flavours(self.table())

        self.assertEqual("2026-09-24", table.verified)
        self.assertEqual(["retail", "classic-era", "ptr"], table.ids())
        self.assertEqual("Example/wow-ui-source", table.mirror.repository)
        self.assertEqual("IsBetaBuild", table.probes.beta_build)
        self.assertEqual(("ptr", "ptr2"), table.by_id("ptr").branches)
        self.assertEqual(2, table.by_id("classic-era").detection.project_id)
        self.assertEqual("classic-era", table.by_id("classic-era").directory)

    def test_unknown_id_names_the_known_ones(self):
        table = module.parse_flavours(self.table())

        with self.assertRaisesRegex(KeyError, "retail, classic-era, ptr"):
            table.by_id("wrath")

    def test_markdown_rows_quote_every_column(self):
        table = module.parse_flavours(self.table())

        self.assertEqual(
            "| `ptr` | Public Test Realm | `wow.ptr.api` | `flavours/Ptr.lua` | `ptr`, `ptr2` |",
            table.markdown_rows()[2],
        )

    def test_unknown_table_key_is_rejected(self):
        table = self.table()
        table["extra"] = True

        with self.assertRaisesRegex(module.FlavoursError, "exactly the keys"):
            module.parse_flavours(table)

    def test_verified_must_be_an_iso_date(self):
        table = self.table()
        table["verified"] = "yesterday"

        with self.assertRaisesRegex(module.FlavoursError, "ISO date"):
            module.parse_flavours(table)

    def test_flavour_id_must_be_lowercase_hyphenated(self):
        table = self.table()
        table["flavours"][0]["id"] = "Retail"

        with self.assertRaisesRegex(module.FlavoursError, r"flavours\[0\]\.id"):
            module.parse_flavours(table)

    def test_namespace_must_start_with_wow_and_end_with_api(self):
        table = self.table()
        table["flavours"][0]["namespace"] = "retail.api"

        with self.assertRaisesRegex(module.FlavoursError, r"flavours\[0\]\.namespace"):
            module.parse_flavours(table)

    def test_runtime_file_must_be_a_pascal_case_file_under_flavours(self):
        table = self.table()
        table["flavours"][0]["runtimeFile"] = "Retail.lua"

        with self.assertRaisesRegex(module.FlavoursError, r"flavours\[0\]\.runtimeFile"):
            module.parse_flavours(table)

    def test_branches_must_be_non_empty_and_distinct(self):
        table = self.table()
        table["flavours"][2]["branches"] = []
        with self.assertRaisesRegex(module.FlavoursError, "non-empty array"):
            module.parse_flavours(table)

        table = self.table()
        table["flavours"][2]["branches"] = ["ptr", "ptr"]
        with self.assertRaisesRegex(module.FlavoursError, "same branch twice"):
            module.parse_flavours(table)

    def test_detection_fields_are_typed(self):
        table = self.table()
        table["flavours"][0]["detection"]["projectId"] = "1"
        with self.assertRaisesRegex(module.FlavoursError, "projectId must be a positive integer"):
            module.parse_flavours(table)

        table = self.table()
        table["flavours"][0]["detection"]["testBuild"] = "no"
        with self.assertRaisesRegex(module.FlavoursError, "testBuild must be true or false"):
            module.parse_flavours(table)

    def test_duplicate_id_namespace_file_or_detection_is_rejected(self):
        for key, value, label in (
            ("id", "retail", "id"),
            ("namespace", "wow.retail.api", "namespace"),
            ("runtimeFile", "flavours/Retail.lua", "runtimeFile"),
            ("detection", {"projectId": 1, "testBuild": False, "betaBuild": False}, "detection"),
        ):
            table = self.table()
            table["flavours"][1][key] = value
            with self.assertRaisesRegex(module.FlavoursError, f"same {label} twice"):
                module.parse_flavours(table)

    def test_load_reads_a_file(self):
        with tempfile.TemporaryDirectory() as directory:
            path = Path(directory) / "flavours.json"
            path.write_text(json.dumps(self.table()), encoding="utf-8")

            self.assertEqual(["retail", "classic-era", "ptr"], module.load_flavours(path).ids())


class RepositoryTableTests(unittest.TestCase):
    """The committed table is the one the design document describes."""

    def test_repository_table_is_valid_and_lists_the_five_flavours(self):
        table = module.load_flavours()

        self.assertEqual(["retail", "classic-era", "classic-mop", "ptr", "beta"], table.ids())
        self.assertEqual("Gethe/wow-ui-source", table.mirror.repository)

    def test_namespaces_follow_the_design_document(self):
        table = module.load_flavours()

        self.assertEqual(
            [
                "wow.retail.api",
                "wow.classic.era.api",
                "wow.classic.mop.api",
                "wow.ptr.api",
                "wow.beta.api",
            ],
            [flavour.namespace for flavour in table.flavours],
        )

    def test_test_builds_share_retail_project_id(self):
        table = module.load_flavours()

        for flavour_id in ("retail", "ptr", "beta"):
            self.assertEqual(1, table.by_id(flavour_id).detection.project_id)
        self.assertFalse(table.by_id("retail").detection.test_build)
        self.assertTrue(table.by_id("ptr").detection.test_build)
        self.assertFalse(table.by_id("ptr").detection.beta_build)
        self.assertTrue(table.by_id("beta").detection.beta_build)

    def test_main_prints_the_table(self):
        output = io.StringIO()
        with redirect_stdout(output):
            status = module.main([])

        self.assertEqual(0, status)
        self.assertIn("| `retail` | Retail | `wow.retail.api` |", output.getvalue())


if __name__ == "__main__":
    unittest.main()
