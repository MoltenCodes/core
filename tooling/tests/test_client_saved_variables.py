"""Tests for the saved-variables reader: the Lua literal subset, never executed."""

from __future__ import annotations

import math
import unittest
from pathlib import Path

from tooling.client.saved_variables import (
    MAX_DEPTH,
    SavedVariablesError,
    as_list,
    parse_saved_variables,
)


#: Saved-variables files as the client writes them. They end in `.lua.txt` so
#: the repository's Lua formatter and linters leave their bytes alone: one of
#: them holds a byte that is not UTF-8, on purpose.
FIXTURES = Path(__file__).resolve().parent / "fixtures" / "client"
RETAIL_FIXTURE = FIXTURES / "retail_schema2.lua.txt"
CLASSIC_FIXTURE = FIXTURES / "classic_era_schema1.lua.txt"


def parse(text: str) -> dict:
    """Parse ``text`` as the client would have written it, in UTF-8."""
    return parse_saved_variables(text.encode("utf-8"))


class ValueTests(unittest.TestCase):
    def test_reads_every_assignment_of_the_chunk(self):
        result = parse("First = 1\nSecond = true\nThird = nil\n")

        self.assertEqual({"First": 1, "Second": True, "Third": None}, result)

    def test_integers_floats_exponents_hex_and_signs(self):
        result = parse("A = { 7, -3, 0.25, -1.5e-3, 1E2, 0x1F, -0x10, .5 }")

        self.assertEqual([7, -3, 0.25, -0.0015, 100.0, 31, -16, 0.5], result["A"])
        self.assertIsInstance(result["A"][0], int)
        self.assertIsInstance(result["A"][4], float)

    def test_non_finite_spellings_of_a_c_runtime(self):
        result = parse("A = { inf, -inf, 1.#INF, -1.#INF, nan, -nan(ind), 1.#QNAN }")

        values = result["A"]
        self.assertEqual([math.inf, -math.inf, math.inf, -math.inf], values[:4])
        self.assertTrue(all(math.isnan(value) for value in values[4:]))

    def test_every_lua_5_1_escape(self):
        source = r'A = "q\"s\'b\\n\nt\tr\ra\ab\bf\fv\v d\065\66\0067"'

        self.assertEqual("q\"s'b\\n\nt\tr\ra\ab\bf\fv\v dAB\x067", parse(source)["A"])

    def test_decimal_escapes_are_bytes_decoded_as_utf8(self):
        self.assertEqual("Péter", parse(r'A = "P\195\169ter"')["A"])

    def test_a_backslash_before_a_newline_is_a_newline(self):
        self.assertEqual("one\ntwo", parse('A = "one\\\ntwo"')["A"])

    def test_single_quoted_and_long_bracket_strings(self):
        result = parse("A = { 'single', [[\nlong]], [==[a]]b]==] }")

        self.assertEqual(["single", "long", "a]]b"], result["A"])

    def test_comments_are_skipped(self):
        result = parse("-- header\nA = { -- [1]\n 1, --[[ block\n comment ]] 2 }\n")

        self.assertEqual([1, 2], result["A"])

    def test_bytes_that_are_not_utf8_are_replaced_not_refused(self):
        result = parse_saved_variables(b'A = "caf\xe9"\n')

        self.assertEqual("caf�", result["A"])

    def test_a_byte_order_mark_is_ignored(self):
        self.assertEqual({"A": 1}, parse_saved_variables(b"\xef\xbb\xbfA = 1"))


class TableTests(unittest.TestCase):
    def test_sequential_positional_fields_become_a_list(self):
        self.assertEqual([1, "two", False], parse('A = { 1, "two", false, }')["A"])

    def test_bracketed_and_named_keys_become_a_dict(self):
        result = parse('A = { ["key"] = 1, name = 2, [3] = "x"; [true] = "t" }')

        self.assertEqual({"key": 1, "name": 2, 3: "x", True: "t"}, result["A"])

    def test_explicit_keys_one_to_n_are_a_list_in_key_order(self):
        self.assertEqual(["a", "b"], parse('A = { [2] = "b", [1] = "a" }')["A"])

    def test_a_float_key_with_an_integral_value_is_that_integer(self):
        self.assertEqual(["a"], parse('A = { [1.0] = "a" }')["A"])

    def test_a_nil_value_leaves_no_field(self):
        result = parse("A = { key = nil, 1, nil, 3 }")

        self.assertEqual({1: 1, 3: 3}, result["A"])

    def test_an_empty_table_is_an_empty_dict_and_reads_as_an_empty_list(self):
        result = parse("A = {}")

        self.assertEqual({}, result["A"])
        self.assertEqual([], as_list(result["A"]))

    def test_nested_tables(self):
        result = parse('A = { ["x"] = { { ["y"] = { 1 } } } }')

        self.assertEqual({"x": [{"y": [1]}]}, result["A"])

    def test_nesting_deeper_than_the_bound_is_refused(self):
        source = "A = " + "{" * (MAX_DEPTH + 1) + "}" * (MAX_DEPTH + 1)

        with self.assertRaises(SavedVariablesError) as caught:
            parse(source)
        self.assertIn("nest deeper", str(caught.exception))


class RefusalTests(unittest.TestCase):
    def test_a_function_call_is_refused_with_its_position(self):
        with self.assertRaises(SavedVariablesError) as caught:
            parse("A = {\n  os.execute('x'),\n}")

        self.assertIn("line 2", str(caught.exception))

    def test_an_operator_is_refused(self):
        with self.assertRaises(SavedVariablesError):
            parse("A = 1 + 2")

    def test_an_unfinished_string_is_refused(self):
        with self.assertRaises(SavedVariablesError) as caught:
            parse('A = "open')

        self.assertIn("unfinished string", str(caught.exception))

    def test_an_invalid_escape_is_refused(self):
        with self.assertRaises(SavedVariablesError):
            parse(r'A = "\q"')

    def test_a_missing_separator_is_refused(self):
        with self.assertRaises(SavedVariablesError) as caught:
            parse("A = { 1 2 }")

        self.assertIn('expected "," or "}"', str(caught.exception))

    def test_a_nil_key_is_refused(self):
        with self.assertRaises(SavedVariablesError):
            parse("A = { [nil] = 1 }")

    def test_a_keyword_is_not_a_variable_name(self):
        with self.assertRaises(SavedVariablesError):
            parse("true = 1")

    def test_a_malformed_number_is_refused(self):
        with self.assertRaises(SavedVariablesError):
            parse("A = 12abc")


class FixtureTests(unittest.TestCase):
    def test_reads_the_schema_2_fixture_the_harness_writes(self):
        variables = parse_saved_variables(RETAIL_FIXTURE.read_bytes())

        results = variables["MoltenCodesTestResults"]
        self.assertEqual({"registry", "hookKit:combat"}, set(results))
        registry = results["registry"]
        self.assertEqual("caf�", registry["client"]["note"])
        self.assertEqual(
            'quoted "text" and a back\\slash\nsecond line',
            registry["report"]["suites"][0]["tests"][0]["logs"][0],
        )
        self.assertEqual(
            "a player named Péter is read", registry["report"]["suites"][0]["tests"][1]["name"]
        )
        self.assertEqual(-0.5, registry["report"]["suites"][1]["tests"][0]["durationMs"])

    def test_reads_the_schema_1_fixture(self):
        variables = parse_saved_variables(CLASSIC_FIXTURE.read_bytes())

        entry = variables["MoltenCodesTestResults"]["registry"]
        self.assertEqual(2, entry["client"]["projectId"])
        self.assertEqual({}, entry["report"]["suites"])


if __name__ == "__main__":
    unittest.main()
