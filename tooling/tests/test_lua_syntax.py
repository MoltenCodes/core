"""Tests for the Lua 5.1 lexer and parser behind the client API availability gate.

The fixtures are small invented snippets. One test parses every runtime source
file of the repository, because the gate can only vouch for a file this parser
reads.
"""

from __future__ import annotations

import io
import tempfile
import unittest
from contextlib import redirect_stderr, redirect_stdout
from pathlib import Path

from tooling.validation import lua_syntax as syntax
from tooling.validation.validate_manifests import ROOT


def first_statement(source: str) -> syntax.Statement:
    chunk = syntax.parse(source)
    assert chunk.body is not None
    return chunk.body.statements[0]


def returned_expression(source: str) -> syntax.Expression:
    statement = first_statement(f"return {source}")
    assert isinstance(statement, syntax.Return)
    return statement.values[0]


class TokenizerTests(unittest.TestCase):
    def test_comments_and_strings_are_single_tokens(self):
        tokens = syntax.tokenize('-- rawget(_G, "A")\nlocal s = "rawget(_G, \\"B\\")" --[[ C ]] .. [[D]]')

        kinds = [(token.kind, token.value) for token in tokens]

        self.assertEqual(
            [
                (syntax.TOKEN_KEYWORD, "local"),
                (syntax.TOKEN_NAME, "s"),
                (syntax.TOKEN_SYMBOL, "="),
                (syntax.TOKEN_STRING, 'rawget(_G, "B")'),
                (syntax.TOKEN_SYMBOL, ".."),
                (syntax.TOKEN_STRING, "D"),
                (syntax.TOKEN_END, None),
            ],
            kinds,
        )

    def test_longest_symbol_wins(self):
        values = [token.value for token in syntax.tokenize("a ~= b == c ... d .. e <= f >= g")]

        self.assertEqual(["a", "~=", "b", "==", "c", "...", "d", "..", "e", "<=", "f", ">=", "g", None], values)

    def test_positions_are_one_based(self):
        tokens = syntax.tokenize("x\n  y")

        self.assertEqual((1, 1), (tokens[0].line, tokens[0].column))
        self.assertEqual((2, 3), (tokens[1].line, tokens[1].column))

    def test_byte_order_mark_is_ignored(self):
        tokens = syntax.tokenize("﻿local x")

        self.assertEqual("local", tokens[0].value)

    def test_unexpected_character_names_its_position(self):
        with self.assertRaises(syntax.LuaSyntaxError) as raised:
            syntax.tokenize("local x = 1\nlocal y = @", "sample.lua")

        self.assertEqual(("sample.lua", 2, 11), (raised.exception.where, raised.exception.line, raised.exception.column))


class ExpressionTests(unittest.TestCase):
    def test_and_binds_tighter_than_or(self):
        expression = returned_expression("a or b and c")

        self.assertIsInstance(expression, syntax.BinaryOperation)
        self.assertEqual("or", expression.operator)
        self.assertEqual("and", expression.right.operator)

    def test_comparison_binds_tighter_than_and(self):
        expression = returned_expression('type(x) == "function" and x')

        self.assertEqual("and", expression.operator)
        self.assertEqual("==", expression.left.operator)

    def test_concatenation_is_right_associative(self):
        expression = returned_expression("a .. b .. c")

        self.assertEqual("..", expression.operator)
        self.assertIsInstance(expression.left, syntax.Name)
        self.assertEqual("..", expression.right.operator)

    def test_power_binds_tighter_than_unary_minus(self):
        expression = returned_expression("-x ^ 2")

        self.assertIsInstance(expression, syntax.UnaryOperation)
        self.assertEqual("^", expression.operand.operator)

    def test_not_applies_to_the_operand_only(self):
        expression = returned_expression("not a == b")

        self.assertEqual("==", expression.operator)
        self.assertIsInstance(expression.left, syntax.UnaryOperation)

    def test_suffixes_build_index_call_and_method_call(self):
        expression = returned_expression('a.b["c"](1):d "e"')

        self.assertIsInstance(expression, syntax.MethodCall)
        self.assertEqual("d", expression.method)
        self.assertEqual("e", expression.arguments[0].value)
        call = expression.receiver
        self.assertIsInstance(call, syntax.Call)
        self.assertIsInstance(call.function, syntax.Index)
        self.assertFalse(call.function.dotted)
        self.assertTrue(call.function.target.dotted)

    def test_table_constructor_fields(self):
        expression = returned_expression("{ 1, x = 2, [k] = 3; }")

        self.assertIsInstance(expression, syntax.Table)
        self.assertIsNone(expression.fields[0].key)
        self.assertEqual("x", expression.fields[1].key.value)
        self.assertIsInstance(expression.fields[2].key, syntax.Name)


class StatementTests(unittest.TestCase):
    def test_method_declaration_is_a_method_function(self):
        statement = first_statement("function Kit.Widget:Show(a, ...) return a end")

        self.assertIsInstance(statement, syntax.FunctionDeclaration)
        self.assertTrue(statement.function.is_method)
        self.assertTrue(statement.function.is_vararg)
        self.assertEqual(["a"], [parameter.name for parameter in statement.function.parameters])
        self.assertEqual("Show", statement.target.key.value)

    def test_if_elseif_else(self):
        statement = first_statement("if a then x() elseif b then y() else z() end")

        self.assertIsInstance(statement, syntax.If)
        self.assertEqual(2, len(statement.clauses))
        self.assertIsNotNone(statement.orelse)

    def test_loops(self):
        chunk = syntax.parse(
            "for i = 1, 10, 2 do end\nfor k, v in pairs(t) do end\nwhile x do break end\nrepeat local y until y"
        )

        kinds = [type(statement) for statement in chunk.body.statements]

        self.assertEqual([syntax.NumericFor, syntax.GenericFor, syntax.While, syntax.Repeat], kinds)

    def test_multiple_assignment(self):
        statement = first_statement("a, b.c = 1, 2")

        self.assertIsInstance(statement, syntax.Assign)
        self.assertEqual(2, len(statement.targets))

    def test_a_bare_expression_is_not_a_statement(self):
        with self.assertRaises(syntax.LuaSyntaxError) as raised:
            syntax.parse("x + 1", "sample.lua")

        self.assertIn("expected a call or an assignment", str(raised.exception))

    def test_unclosed_block_names_the_opening_line(self):
        with self.assertRaises(syntax.LuaSyntaxError) as raised:
            syntax.parse("if a then\n  x()\n", "sample.lua")

        self.assertIn("to close 'if' at line 1", str(raised.exception))

    def test_goto_is_not_lua_5_1(self):
        with self.assertRaises(syntax.LuaSyntaxError):
            syntax.parse("goto done")

    def test_walk_visits_every_node_in_order(self):
        chunk = syntax.parse("local a = f(b)")

        names = [node.name for node in syntax.walk(chunk) if isinstance(node, syntax.Name)]

        self.assertEqual(["a", "f", "b"], names)


class RepositorySourceTests(unittest.TestCase):
    def test_every_runtime_source_parses(self):
        sources = sorted(ROOT.glob("packages/*/src/**/*.lua"))
        self.assertTrue(sources)

        for path in sources:
            with self.subTest(path=path.relative_to(ROOT).as_posix()):
                syntax.parse_file(path)


class CommandLineTests(unittest.TestCase):
    def test_reports_each_file(self):
        with tempfile.TemporaryDirectory() as directory:
            good = Path(directory) / "good.lua"
            bad = Path(directory) / "bad.lua"
            good.write_text("local x = 1\n", encoding="utf-8")
            bad.write_text("local = 1\n", encoding="utf-8")
            output, errors = io.StringIO(), io.StringIO()

            with redirect_stdout(output), redirect_stderr(errors):
                status = syntax.main([str(good), str(bad)])

        self.assertEqual(1, status)
        self.assertIn("good.lua: 1 top-level statement(s)", output.getvalue())
        self.assertIn("bad.lua:1:7: expected a name", errors.getvalue())


if __name__ == "__main__":
    unittest.main()
