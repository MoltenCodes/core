import copy
import io
import json
import tempfile
import unittest
from contextlib import redirect_stdout
from pathlib import Path

from tooling.validation import interface_numbers as module


VALID_TABLE = {
    "verified": "2026-09-23",
    "source": "https://example.invalid/patches",
    "clients": [
        {
            "flavour": "Retail",
            "interface": 120100,
            "patch": "12.1.0",
            "tocSuffix": "_Mainline",
            "promised": True,
        },
        {
            "flavour": "Classic Era",
            "interface": 11509,
            "patch": "1.15.9",
            "tocSuffix": "_Vanilla",
            "promised": True,
        },
    ],
}


class SupportedClientsParsingTests(unittest.TestCase):
    def table(self):
        return copy.deepcopy(VALID_TABLE)

    def test_valid_table_is_parsed_in_order(self):
        clients = module.parse_supported_clients(self.table())

        self.assertEqual("2026-09-23", clients.verified)
        self.assertEqual([120100, 11509], clients.interface_numbers())
        self.assertEqual("_Mainline", clients.clients[0].toc_suffix)

    def test_toc_line_lists_every_number_in_table_order(self):
        clients = module.parse_supported_clients(self.table())

        self.assertEqual("## Interface: 120100, 11509", clients.toc_line())

    def test_markdown_rows_match_the_documented_table_shape(self):
        clients = module.parse_supported_clients(self.table())

        self.assertEqual(
            [
                "| Retail | `120100` | 12.1.0 | `_Mainline` |",
                "| Classic Era | `11509` | 1.15.9 | `_Vanilla` |",
            ],
            clients.markdown_rows(),
        )

    def test_duplicate_interface_number_is_rejected(self):
        table = self.table()
        table["clients"][1]["interface"] = 120100

        with self.assertRaisesRegex(module.SupportedClientsError, "twice"):
            module.parse_supported_clients(table)

    def test_unknown_client_key_is_rejected(self):
        table = self.table()
        table["clients"][0]["suffix"] = "_Mainline"

        with self.assertRaisesRegex(module.SupportedClientsError, r"clients\[0\]"):
            module.parse_supported_clients(table)

    def test_non_integer_interface_is_rejected(self):
        table = self.table()
        table["clients"][0]["interface"] = "120100"

        with self.assertRaisesRegex(module.SupportedClientsError, "positive integer"):
            module.parse_supported_clients(table)

    def test_verified_must_be_an_iso_date(self):
        table = self.table()
        table["verified"] = "September 2026"

        with self.assertRaisesRegex(module.SupportedClientsError, "ISO date"):
            module.parse_supported_clients(table)

    def test_empty_client_list_is_rejected(self):
        table = self.table()
        table["clients"] = []

        with self.assertRaisesRegex(module.SupportedClientsError, "non-empty"):
            module.parse_supported_clients(table)

    def test_load_reads_a_file(self):
        with tempfile.TemporaryDirectory() as directory:
            path = Path(directory) / "clients.json"
            path.write_text(json.dumps(self.table()), encoding="utf-8")

            clients = module.load_supported_clients(path)

        self.assertEqual([120100, 11509], clients.interface_numbers())


class RepositoryTableTests(unittest.TestCase):
    """The table the repository ships is valid and the command prints from it."""

    def test_repository_table_is_valid(self):
        clients = module.load_supported_clients()

        self.assertTrue(clients.clients)
        self.assertTrue(any(client.promised for client in clients.clients))

    def test_main_prints_the_toc_line(self):
        output = io.StringIO()
        with redirect_stdout(output):
            status = module.main([])

        self.assertEqual(0, status)
        self.assertEqual(module.load_supported_clients().toc_line(), output.getvalue().strip())

    def test_main_prints_the_table_rows(self):
        output = io.StringIO()
        with redirect_stdout(output):
            status = module.main(["--table"])

        self.assertEqual(0, status)
        self.assertEqual(
            module.load_supported_clients().markdown_rows(), output.getvalue().splitlines()
        )


if __name__ == "__main__":
    unittest.main()
