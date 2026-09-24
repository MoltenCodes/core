"""Tests for the Lua documentation-table parser.

Every fixture here is written by the project in the documentation format with
invented names; none of it comes from a client file (design document, section
16). The one test that reads real files does so from a scratch directory named
by an environment variable, which is unset in the repository and on CI, and it
asserts only on shape.
"""

from __future__ import annotations

import io
import os
import tempfile
import textwrap
import unittest
from contextlib import redirect_stderr, redirect_stdout
from pathlib import Path

from tooling.api import lua_tables as module


#: Names the scratch directory the fetch writes the client's tables into. The
#: tests never embed its content; they only check that every file there parses.
SAMPLE_DIRECTORY_VARIABLE = "MOLTENCODES_DOCUMENTATION_SAMPLES"

#: An invented system file in the documentation format, exercising every
#: section the normaliser reads.
LANTERN_FILE = textwrap.dedent(
    """\
    -- Documentation for the invented Lantern system.
    local Lantern =
    {
    \tName = "Lantern",
    \tType = "System",
    \tNamespace = "C_Lantern",
    \tEnvironment = "All",

    \tFunctions =
    \t{
    \t\t{
    \t\t\tName = "LightLantern",
    \t\t\tType = "Function",
    \t\t\tSecretArguments = "AllowedWhenUntainted",

    \t\t\tArguments =
    \t\t\t{
    \t\t\t\t{ Name = "lanternID", Type = "number", Nilable = false },
    \t\t\t\t{ Name = "brightness", Type = "number", Nilable = false, Default = 1.5 },
    \t\t\t},

    \t\t\tReturns =
    \t\t\t{
    \t\t\t\t{ Name = "success", Type = "bool", Nilable = false },
    \t\t\t},

    \t\t\tDocumentation = { "Lights the lantern.", "Fails when it is already lit." },
    \t\t},
    \t\t{
    \t\t\tName = "GetLanternCount",
    \t\t\tType = "Function",
    \t\t\tMayReturnNothing = true,

    \t\t\tReturns =
    \t\t\t{
    \t\t\t\t{ Name = "count", Type = "number", Nilable = false },
    \t\t\t},
    \t\t},
    \t},

    \tEvents =
    \t{
    \t\t{
    \t\t\tName = "LanternLit",
    \t\t\tType = "Event",
    \t\t\tLiteralName = "LANTERN_LIT",
    \t\t\tSynchronousEvent = true,
    \t\t\tPayload =
    \t\t\t{
    \t\t\t\t{ Name = "lanternID", Type = "number", Nilable = false },
    \t\t\t},
    \t\t},
    \t},

    \tTables =
    \t{
    \t\t{
    \t\t\tName = "LanternColor",
    \t\t\tType = "Enumeration",
    \t\t\tNumValues = 2,
    \t\t\tMinValue = -1,
    \t\t\tMaxValue = 0,
    \t\t\tFields =
    \t\t\t{
    \t\t\t\t{ Name = "Unknown", Type = "LanternColor", EnumValue = -1 },
    \t\t\t\t{ Name = "Amber", Type = "LanternColor", EnumValue = 0 },
    \t\t\t},
    \t\t},
    \t\t{
    \t\t\tName = "LanternInfo",
    \t\t\tType = "Structure",
    \t\t\tFields =
    \t\t\t{
    \t\t\t\t{ Name = "name", Type = "cstring", Nilable = false },
    \t\t\t\t{ Name = "lit", Type = "bool", Nilable = false },
    \t\t\t},
    \t\t},
    \t},

    \tPredicates =
    \t{
    \t},
    };

    APIDocumentation:AddDocumentationTable(Lantern);
    """
)

#: An invented constants-only file: no `Name`, only `Tables` and `Predicates`,
#: with values written as references and as an expression.
LANTERN_CONSTANTS_FILE = textwrap.dedent(
    """\
    local LanternConstants =
    {
    \tTables =
    \t{
    \t\t{
    \t\t\tName = "LanternConsts",
    \t\t\tType = "Constants",
    \t\t\tValues =
    \t\t\t{
    \t\t\t\t{ Name = "MAX_LANTERNS", Type = "number", Value = 8 },
    \t\t\t\t{ Name = "DEFAULT_COLOR", Type = "LanternColor", Value = Enum.LanternColor.Amber },
    \t\t\t\t{ Name = "MAX_WICKS", Type = "number", Value = MAX_LANTERN_WICKS },
    \t\t\t\t{ Name = "NUM_COLORS", Type = "number", Value = Enum.Meta.LAST - Enum.Meta.FIRST + 1 },
    \t\t\t},
    \t\t},
    \t},
    \tPredicates =
    \t{
    \t},
    };

    APIDocumentation:AddDocumentationTable(LanternConstants);
    """
)


class TableConversionTests(unittest.TestCase):
    """The table-to-Python rules the normaliser depends on."""

    def test_positional_table_becomes_a_list_in_order(self):
        self.assertEqual(["first", "second", 3], module.parse_lua_value('{ "first", "second", 3 }'))

    def test_keyed_table_becomes_a_dict(self):
        self.assertEqual(
            {"Name": "unit", "Nilable": False},
            module.parse_lua_value('{ Name = "unit", Nilable = false }'),
        )

    def test_bracketed_keys_may_be_strings_or_numbers(self):
        value = module.parse_lua_value('{ ["Name"] = "a", [1] = "b", [2.5] = "c", [-1] = "d" }')

        self.assertEqual({"Name": "a", 1: "b", 2.5: "c", -1: "d"}, value)

    def test_empty_table_becomes_an_empty_list(self):
        self.assertEqual([], module.parse_lua_value("{ }"))
        self.assertEqual([], module.parse_lua_value("{}"))

    def test_nested_tables_convert_recursively(self):
        text = '{ Arguments = { { Name = "a" }, { Name = "b" } }, Returns = { } }'

        value = module.parse_lua_value(text)

        self.assertEqual({"Arguments": [{"Name": "a"}, {"Name": "b"}], "Returns": []}, value)

    def test_semicolon_separators_and_trailing_separator_are_accepted(self):
        self.assertEqual([1, 2, 3], module.parse_lua_value("{ 1; 2, 3; }"))
        self.assertEqual({"a": 1}, module.parse_lua_value("{ a = 1, }"))

    def test_mixed_positional_and_keyed_table_is_rejected(self):
        with self.assertRaisesRegex(module.LuaTableError, "mixes positional and keyed"):
            module.parse_lua_value('{ "text", Name = "x" }')

    def test_duplicate_key_is_rejected_whichever_spelling(self):
        with self.assertRaisesRegex(module.LuaTableError, "key 'Name' appears twice"):
            module.parse_lua_value('{ Name = "a", Name = "b" }')
        with self.assertRaisesRegex(module.LuaTableError, "key 'Name' appears twice"):
            module.parse_lua_value('{ Name = "a", ["Name"] = "b" }')

    def test_missing_separator_between_fields_is_rejected(self):
        with self.assertRaisesRegex(module.LuaTableError, r"expected '}', found identifier 'Type'"):
            module.parse_lua_value('{ Name = "a" Type = "b" }')

    def test_reserved_word_cannot_be_a_field_key(self):
        with self.assertRaisesRegex(
            module.LuaTableError, "expected a name, found identifier 'end'"
        ):
            module.parse_lua_value("{ end = 1 }")

    def test_bracketed_key_must_be_a_string_or_number(self):
        with self.assertRaisesRegex(module.LuaTableError, "expected a string or number key"):
            module.parse_lua_value("{ [nil] = 1 }")


class ScalarConversionTests(unittest.TestCase):
    def test_keyword_values(self):
        self.assertIsNone(module.parse_lua_value("nil"))
        self.assertIs(True, module.parse_lua_value("true"))
        self.assertIs(False, module.parse_lua_value("false"))

    def test_integers_are_int_and_other_numbers_are_float(self):
        self.assertEqual(42, module.parse_lua_value("42"))
        self.assertIsInstance(module.parse_lua_value("42"), int)
        self.assertEqual(1.5, module.parse_lua_value("1.5"))
        self.assertEqual(2.0, module.parse_lua_value("2."))
        self.assertEqual(0.5, module.parse_lua_value(".5"))
        self.assertEqual(1500.0, module.parse_lua_value("1.5e3"))
        self.assertIsInstance(module.parse_lua_value("1e3"), float)

    def test_negative_numbers(self):
        self.assertEqual(-1, module.parse_lua_value("-1"))
        self.assertEqual(-2.5, module.parse_lua_value("- 2.5"))
        self.assertEqual({"MinValue": -10}, module.parse_lua_value("{ MinValue = -10 }"))

    def test_hexadecimal_integers(self):
        self.assertEqual(255, module.parse_lua_value("0xFF"))
        self.assertEqual(16, module.parse_lua_value("0X10"))

    def test_malformed_numbers_are_rejected(self):
        for text in ("1.2.3", "12abc", "0x1p4", "0x"):
            with self.subTest(text=text):
                with self.assertRaisesRegex(module.LuaTableError, "malformed number"):
                    module.parse_lua_value(text)

    def test_minus_must_be_followed_by_a_number(self):
        with self.assertRaisesRegex(module.LuaTableError, "expected a number after '-'"):
            module.parse_lua_value('-"text"')


class NameReferenceTests(unittest.TestCase):
    """Constants files refer to globals and enum members by name."""

    def test_bare_name_becomes_a_lua_name(self):
        value = module.parse_lua_value("{ Value = MAX_LANTERN_WICKS }")

        self.assertEqual({"Value": module.LuaName("MAX_LANTERN_WICKS")}, value)

    def test_dotted_name_keeps_its_path_and_parts(self):
        value = module.parse_lua_value("Enum.LanternColor.Amber")

        self.assertEqual(module.LuaName("Enum.LanternColor.Amber"), value)
        self.assertEqual(("Enum", "LanternColor", "Amber"), value.parts)

    def test_name_may_be_positional(self):
        value = module.parse_lua_value("{ Enum.Aspect.Heat }")

        self.assertEqual([module.LuaName("Enum.Aspect.Heat")], value)

    def test_sum_and_difference_of_names_and_numbers_become_an_expression(self):
        value = module.parse_lua_value("Range.LAST - Range.FIRST + 1")

        self.assertEqual(
            module.LuaExpression(
                operands=(module.LuaName("Range.LAST"), module.LuaName("Range.FIRST"), 1),
                operators=("-", "+"),
            ),
            value,
        )
        self.assertEqual("Range.LAST - Range.FIRST + 1", value.text)

    def test_expression_may_start_with_a_number(self):
        value = module.parse_lua_value("1 + Flags.Second")

        self.assertEqual((1, module.LuaName("Flags.Second")), value.operands)
        self.assertEqual("1 + Flags.Second", value.text)

    def test_only_numbers_and_names_may_be_added(self):
        with self.assertRaisesRegex(module.LuaTableError, "only numbers and names can be added"):
            module.parse_lua_value("true + 1")
        with self.assertRaisesRegex(module.LuaTableError, "only numbers and names can be added"):
            module.parse_lua_value("Flags.A + false")

    def test_other_operators_are_rejected(self):
        with self.assertRaisesRegex(module.LuaTableError, r"unexpected character '\*'"):
            module.parse_lua_value("2 * 3")
        with self.assertRaisesRegex(module.LuaTableError, r"unexpected character '/'"):
            module.parse_lua_value("Flags.A / 2")

    def test_function_calls_are_rejected_naming_the_callee(self):
        with self.assertRaisesRegex(module.LuaTableError, "found a call on 'GetValue'"):
            module.parse_lua_value("{ Value = GetValue(1) }")
        with self.assertRaisesRegex(module.LuaTableError, "found a call on 'Registry'"):
            module.parse_lua_value("Registry:Lookup()")

    def test_reserved_words_are_rejected_as_values(self):
        with self.assertRaisesRegex(module.LuaTableError, "reserved word 'function'"):
            module.parse_lua_value("{ Value = function }")

    def test_dotted_name_must_end_in_a_name(self):
        with self.assertRaisesRegex(module.LuaTableError, "expected a name, found '}'"):
            module.parse_lua_value("{ Enum. }")


class QuotedStringTests(unittest.TestCase):
    def test_plain_double_and_single_quoted_strings(self):
        self.assertEqual("text", module.parse_lua_value('"text"'))
        self.assertEqual("text", module.parse_lua_value("'text'"))

    def test_the_other_quote_is_an_ordinary_character(self):
        self.assertEqual("it's", module.parse_lua_value('"it\'s"'))
        self.assertEqual('say "hi"', module.parse_lua_value("'say \"hi\"'"))

    def test_single_character_escapes(self):
        cases = {
            r"\n": "\n",
            r"\t": "\t",
            r"\r": "\r",
            r"\a": "\a",
            r"\b": "\b",
            r"\f": "\f",
            r"\v": "\v",
            r"\\": "\\",
            r"\"": '"',
            r"\'": "'",
        }
        for escape, expected in cases.items():
            with self.subTest(escape=escape):
                self.assertEqual(f"[{expected}]", module.parse_lua_value(f'"[{escape}]"'))

    def test_decimal_escapes_take_up_to_three_digits(self):
        self.assertEqual("A", module.parse_lua_value(r'"\65"'))
        self.assertEqual("A", module.parse_lua_value(r'"\065"'))
        self.assertEqual("\x01" + "23", module.parse_lua_value(r'"\00123"'))
        self.assertEqual("\x7f", module.parse_lua_value(r'"\127"'))

    def test_decimal_escape_above_255_is_rejected(self):
        with self.assertRaisesRegex(module.LuaTableError, r"decimal escape '\\300' is above 255"):
            module.parse_lua_value(r'"\300"')

    def test_hexadecimal_escape(self):
        self.assertEqual("A!", module.parse_lua_value(r'"\x41!"'))

    def test_hexadecimal_escape_needs_two_digits(self):
        with self.assertRaisesRegex(module.LuaTableError, "exactly two hexadecimal digits"):
            module.parse_lua_value(r'"\x4"')

    def test_z_escape_skips_following_whitespace_including_line_breaks(self):
        self.assertEqual("ab", module.parse_lua_value('"a\\z  \n\t  b"'))

    def test_backslash_before_a_line_break_is_that_line_break(self):
        self.assertEqual("a\nb", module.parse_lua_value('"a\\\nb"'))
        self.assertEqual("a\nb", module.parse_lua_value('"a\\\r\nb"'))

    def test_unknown_escape_is_rejected(self):
        with self.assertRaisesRegex(module.LuaTableError, r"unknown escape sequence '\\q'"):
            module.parse_lua_value(r'"\q"')

    def test_unterminated_string_reports_where_it_started(self):
        with self.assertRaisesRegex(module.LuaTableError, "<string>:1:1: unterminated string"):
            module.parse_lua_value('"never closed')

    def test_raw_line_break_inside_a_string_is_rejected(self):
        with self.assertRaisesRegex(module.LuaTableError, "line break needs a backslash"):
            module.parse_lua_value('"a\nb"')

    def test_non_ascii_text_is_preserved(self):
        self.assertEqual("Ünïcödé — ok", module.parse_lua_value('"Ünïcödé — ok"'))


class LongBracketStringTests(unittest.TestCase):
    def test_body_is_verbatim_including_backslashes_and_quotes(self):
        self.assertEqual('a\\n "b"', module.parse_lua_value('[[a\\n "b"]]'))

    def test_first_line_break_is_dropped(self):
        self.assertEqual("line one\nline two", module.parse_lua_value("[[\nline one\nline two]]"))
        self.assertEqual("line one", module.parse_lua_value("[[\r\nline one]]"))

    def test_line_breaks_inside_are_normalised(self):
        self.assertEqual("a\nb", module.parse_lua_value("[[a\r\nb]]"))

    def test_levelled_brackets_may_contain_plain_closing_brackets(self):
        self.assertEqual("x]]y", module.parse_lua_value("[==[x]]y]==]"))

    def test_unterminated_long_string_is_rejected(self):
        with self.assertRaisesRegex(module.LuaTableError, "unterminated long bracket string"):
            module.parse_lua_value("[==[never closed]]")


class CommentTests(unittest.TestCase):
    def test_line_comments_before_after_and_between_fields(self):
        text = (
            '-- leading\n{ -- after brace\n  Name = "a", -- after field\n'
            '  Type = "b"\n} -- trailing'
        )

        self.assertEqual({"Name": "a", "Type": "b"}, module.parse_lua_value(text))

    def test_block_comments_in_odd_places(self):
        text = (
            '{ Name --[[ between key and equals ]] = --[[ before value ]] "a"'
            ' --[[\nmulti\nline\n]], Type = "b" }'
        )

        self.assertEqual({"Name": "a", "Type": "b"}, module.parse_lua_value(text))

    def test_levelled_block_comment_may_contain_plain_closing_brackets(self):
        self.assertEqual(1, module.parse_lua_value("--[==[ a ]] b ]==] 1"))

    def test_comment_markers_inside_strings_are_text(self):
        self.assertEqual("a -- b --[[ c ]]", module.parse_lua_value('"a -- b --[[ c ]]"'))

    def test_line_comment_at_end_without_line_break(self):
        self.assertEqual(7, module.parse_lua_value("7 -- done"))

    def test_unterminated_block_comment_is_rejected(self):
        with self.assertRaisesRegex(module.LuaTableError, "unterminated long bracket comment"):
            module.parse_lua_value("1 --[[ never closed")


class ParseValueBoundaryTests(unittest.TestCase):
    def test_trailing_whitespace_and_comments_are_allowed(self):
        self.assertEqual([1], module.parse_lua_value("  { 1 }  \n-- end\n"))

    def test_trailing_tokens_are_rejected(self):
        with self.assertRaisesRegex(
            module.LuaTableError, "expected end of input, found identifier 'extra'"
        ):
            module.parse_lua_value("{ 1 } extra")

    def test_empty_text_is_rejected(self):
        with self.assertRaisesRegex(module.LuaTableError, "expected a value, found end of input"):
            module.parse_lua_value("   ")

    def test_unexpected_character_is_named(self):
        with self.assertRaisesRegex(module.LuaTableError, "unexpected character '@'"):
            module.parse_lua_value("@")


class ErrorLocationTests(unittest.TestCase):
    def test_message_carries_where_line_and_column(self):
        text = "{\n  Name = GetName(),\n}"

        with self.assertRaises(module.LuaTableError) as caught:
            module.parse_lua_value(text, where="fixture.lua")

        failure = caught.exception
        self.assertTrue(str(failure).startswith("fixture.lua:2:10: "), str(failure))
        self.assertEqual("fixture.lua", failure.where)
        self.assertEqual(2, failure.line)
        self.assertEqual(10, failure.column)
        self.assertIn("call on 'GetName'", failure.detail)

    def test_lines_are_counted_across_windows_line_breaks(self):
        text = '{\r\n\tName = "a",\r\n\tName = "b",\r\n}'

        with self.assertRaisesRegex(module.LuaTableError, "<string>:3:2: key 'Name' appears twice"):
            module.parse_lua_value(text)

    def test_lines_are_counted_inside_block_comments_and_long_strings(self):
        text = "{\n  --[[\n  two\n  lines ]] Text = [[\n  long\n  string]],\n  Bad = @\n}"

        with self.assertRaisesRegex(module.LuaTableError, "<string>:7:9: unexpected character '@'"):
            module.parse_lua_value(text)

    def test_mixed_table_error_points_at_the_opening_brace(self):
        with self.assertRaisesRegex(module.LuaTableError, "<string>:2:3: table mixes"):
            module.parse_lua_value('{\n  { 1, Name = "x" }\n}')

    def test_error_is_a_value_error(self):
        with self.assertRaises(ValueError):
            module.parse_lua_value("{")


class DocumentationFileTests(unittest.TestCase):
    def test_full_system_file_is_parsed(self):
        document = module.parse_documentation_file(LANTERN_FILE, where="LanternDocumentation.lua")

        self.assertEqual("Lantern", document.variable_name)
        self.assertTrue(document.registered)
        self.assertEqual(
            [
                "Name",
                "Type",
                "Namespace",
                "Environment",
                "Functions",
                "Events",
                "Tables",
                "Predicates",
            ],
            list(document.table),
        )
        self.assertEqual("C_Lantern", document.table["Namespace"])
        self.assertEqual([], document.table["Predicates"])

    def test_functions_carry_arguments_returns_and_documentation(self):
        document = module.parse_documentation_file(LANTERN_FILE, where="LanternDocumentation.lua")
        light, get_count = document.table["Functions"]

        self.assertEqual("LightLantern", light["Name"])
        self.assertEqual(
            {"Name": "brightness", "Type": "number", "Nilable": False, "Default": 1.5},
            light["Arguments"][1],
        )
        self.assertEqual([{"Name": "success", "Type": "bool", "Nilable": False}], light["Returns"])
        self.assertEqual(
            ["Lights the lantern.", "Fails when it is already lit."], light["Documentation"]
        )
        self.assertIs(True, get_count["MayReturnNothing"])
        self.assertNotIn("Arguments", get_count)

    def test_events_carry_literal_name_and_payload(self):
        document = module.parse_documentation_file(LANTERN_FILE, where="LanternDocumentation.lua")
        event = document.table["Events"][0]

        self.assertEqual("LANTERN_LIT", event["LiteralName"])
        self.assertIs(True, event["SynchronousEvent"])
        self.assertEqual(
            [{"Name": "lanternID", "Type": "number", "Nilable": False}], event["Payload"]
        )

    def test_tables_carry_enumerations_and_structures(self):
        document = module.parse_documentation_file(LANTERN_FILE, where="LanternDocumentation.lua")
        enumeration, structure = document.table["Tables"]

        self.assertEqual("Enumeration", enumeration["Type"])
        self.assertEqual(-1, enumeration["MinValue"])
        self.assertEqual(
            [
                {"Name": "Unknown", "Type": "LanternColor", "EnumValue": -1},
                {"Name": "Amber", "Type": "LanternColor", "EnumValue": 0},
            ],
            enumeration["Fields"],
        )
        self.assertEqual("Structure", structure["Type"])
        self.assertEqual(["name", "lit"], [field["Name"] for field in structure["Fields"]])

    def test_constants_only_file_has_tables_but_no_name(self):
        document = module.parse_documentation_file(
            LANTERN_CONSTANTS_FILE, where="LanternConstantsDocumentation.lua"
        )

        self.assertEqual("LanternConstants", document.variable_name)
        self.assertTrue(document.registered)
        self.assertEqual(["Tables", "Predicates"], list(document.table))
        values = document.table["Tables"][0]["Values"]
        self.assertEqual(8, values[0]["Value"])
        self.assertEqual(module.LuaName("Enum.LanternColor.Amber"), values[1]["Value"])
        self.assertEqual(module.LuaName("MAX_LANTERN_WICKS"), values[2]["Value"])
        self.assertEqual("Enum.Meta.LAST - Enum.Meta.FIRST + 1", values[3]["Value"].text)

    def test_file_without_registration_is_not_registered(self):
        text = 'local Quiet = { Name = "Quiet" };'

        document = module.parse_documentation_file(text, where="Quiet.lua")

        self.assertEqual("Quiet", document.variable_name)
        self.assertFalse(document.registered)

    def test_semicolons_are_optional(self):
        text = 'local Quiet = { Name = "Quiet" }\nAPIDocumentation:AddDocumentationTable(Quiet)\n'

        document = module.parse_documentation_file(text, where="Quiet.lua")

        self.assertTrue(document.registered)

    def test_registration_of_a_different_variable_is_rejected(self):
        text = 'local Quiet = { Name = "Quiet" };\nAPIDocumentation:AddDocumentationTable(Loud);'

        with self.assertRaisesRegex(
            module.LuaTableError,
            "Quiet.lua:2:40: AddDocumentationTable registers 'Loud' but the file declares 'Quiet'",
        ):
            module.parse_documentation_file(text, where="Quiet.lua")

    def test_registration_must_use_the_documented_registry(self):
        text = 'local Quiet = { Name = "Quiet" };\nOtherRegistry:AddDocumentationTable(Quiet);'

        with self.assertRaisesRegex(
            module.LuaTableError, "expected 'APIDocumentation', found identifier 'OtherRegistry'"
        ):
            module.parse_documentation_file(text, where="Quiet.lua")

    def test_file_must_start_with_local(self):
        with self.assertRaisesRegex(
            module.LuaTableError, "Quiet.lua:1:1: expected 'local', found identifier 'Quiet'"
        ):
            module.parse_documentation_file('Quiet = { Name = "Quiet" }', where="Quiet.lua")

    def test_empty_file_is_rejected(self):
        with self.assertRaisesRegex(
            module.LuaTableError, "Empty.lua:1:1: expected 'local', found end of input"
        ):
            module.parse_documentation_file("", where="Empty.lua")

    def test_variable_name_cannot_be_a_reserved_word(self):
        with self.assertRaisesRegex(
            module.LuaTableError, "expected a name, found identifier 'end'"
        ):
            module.parse_documentation_file("local end = { Name = 'x' }", where="Bad.lua")

    def test_top_level_must_be_a_table_constructor(self):
        with self.assertRaisesRegex(
            module.LuaTableError, "expected a table constructor, found string 'text'"
        ):
            module.parse_documentation_file('local Quiet = "text"', where="Quiet.lua")

    def test_top_level_table_must_be_keyed(self):
        with self.assertRaisesRegex(
            module.LuaTableError, "Quiet.lua:1:15: the documentation table must have keyed fields"
        ):
            module.parse_documentation_file("local Quiet = { }", where="Quiet.lua")

    def test_text_after_registration_is_rejected(self):
        text = (
            'local Quiet = { Name = "Quiet" };\n'
            'APIDocumentation:AddDocumentationTable(Quiet);\n'
            'print("done")'
        )

        with self.assertRaisesRegex(
            module.LuaTableError, "Quiet.lua:3:1: expected end of input, found identifier 'print'"
        ):
            module.parse_documentation_file(text, where="Quiet.lua")

    def test_comments_are_allowed_between_every_part(self):
        text = (
            "--[[ header ]] local --[[ a ]] Quiet --[[ b ]] = --[[ c ]] { Name = 'Quiet' } -- d\n"
            "--[[ e ]] APIDocumentation --[[ f ]] : AddDocumentationTable --[[ g ]] ( Quiet ) ;"
            " -- h\n"
        )

        document = module.parse_documentation_file(text, where="Quiet.lua")

        self.assertTrue(document.registered)
        self.assertEqual({"Name": "Quiet"}, document.table)

    def test_result_is_immutable(self):
        document = module.parse_documentation_file(LANTERN_FILE, where="LanternDocumentation.lua")

        with self.assertRaises(AttributeError):
            document.registered = False  # type: ignore[misc]


class SampleCorpusTests(unittest.TestCase):
    """Every fetched client file parses; the content itself is never inspected or embedded.

    Point `MOLTENCODES_DOCUMENTATION_SAMPLES` at a scratch directory holding
    the client's documentation files (subdirectories included) to run this.
    """

    def test_every_sample_file_parses_to_a_documentation_table(self):
        directory_name = os.environ.get(SAMPLE_DIRECTORY_VARIABLE)
        if not directory_name or not Path(directory_name).is_dir():
            self.skipTest(f"{SAMPLE_DIRECTORY_VARIABLE} does not name an existing directory")
        sample_files = [
            path for path in sorted(Path(directory_name).rglob("*.lua")) if path.stat().st_size > 0
        ]
        if not sample_files:
            self.skipTest(f"{directory_name} holds no non-empty Lua files")

        for path in sample_files:
            with self.subTest(file=path.name):
                document = module.parse_documentation_file(
                    path.read_text(encoding="utf-8"), where=path.name
                )

                self.assertIsInstance(document.table, dict)
                self.assertTrue("Name" in document.table or "Tables" in document.table)
                self.assertTrue(document.registered)


class CommandLineTests(unittest.TestCase):
    def write(self, directory: str, name: str, text: str) -> Path:
        path = Path(directory) / name
        path.write_text(text, encoding="utf-8")
        return path

    def test_main_summarises_every_file_in_a_directory(self):
        with tempfile.TemporaryDirectory() as directory:
            self.write(directory, "LanternDocumentation.lua", LANTERN_FILE)
            self.write(directory, "LanternConstantsDocumentation.lua", LANTERN_CONSTANTS_FILE)
            output = io.StringIO()

            with redirect_stdout(output):
                status = module.main([directory])

            self.assertEqual(0, status)
            self.assertIn(
                "Lantern (registered; 2 functions, 1 events, 2 tables)", output.getvalue()
            )
            self.assertIn("LanternConstants (registered; 1 tables)", output.getvalue())

    def test_main_reports_every_failure_and_exits_non_zero(self):
        with tempfile.TemporaryDirectory() as directory:
            self.write(directory, "BrokenDocumentation.lua", "local Broken = { Name = ")
            self.write(directory, "LanternDocumentation.lua", LANTERN_FILE)
            output, errors = io.StringIO(), io.StringIO()

            with redirect_stdout(output), redirect_stderr(errors):
                status = module.main([directory])

            self.assertEqual(1, status)
            self.assertIn(
                "BrokenDocumentation.lua:1:25: expected a value, found end of input",
                errors.getvalue(),
            )
            self.assertIn("1 of 2 files failed to parse", errors.getvalue())
            self.assertIn("Lantern (registered", output.getvalue())

    def test_main_prints_json_for_a_single_file_rendering_references_as_text(self):
        with tempfile.TemporaryDirectory() as directory:
            path = self.write(
                directory, "LanternConstantsDocumentation.lua", LANTERN_CONSTANTS_FILE
            )
            output = io.StringIO()

            with redirect_stdout(output):
                status = module.main([str(path), "--json"])

            self.assertEqual(0, status)
            self.assertIn('"Value": "Enum.LanternColor.Amber"', output.getvalue())
            self.assertIn('"Value": "Enum.Meta.LAST - Enum.Meta.FIRST + 1"', output.getvalue())

    def test_json_needs_exactly_one_file(self):
        with tempfile.TemporaryDirectory() as directory:
            self.write(directory, "A.lua", LANTERN_FILE)
            self.write(directory, "B.lua", LANTERN_FILE)
            errors = io.StringIO()

            with redirect_stderr(errors):
                status = module.main([directory, "--json"])

            self.assertEqual(2, status)
            self.assertIn("exactly one file", errors.getvalue())


if __name__ == "__main__":
    unittest.main()
