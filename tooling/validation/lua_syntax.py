"""A Lua 5.1 lexer and parser that turns runtime source into a syntax tree.

The client API availability gate (`tooling.validation.flavour_api`) has to know
where a Kit reads a client global, what it does with the value and which
conditions surround that use. Regular expressions over raw text cannot tell a
call from a comment, a string from code, or a guarded use from an unguarded
one, so this module reads the source the way the Lua 5.1 compiler does and
hands back a tree of plain dataclasses.

The grammar is Lua 5.1's, exactly as the reference manual (section 8) states
it, because the World of Warcraft client runs Lua 5.1: no `goto`, no labels,
no integer division, no bitwise operators. Anything outside that grammar is a
`LuaSyntaxError` naming the file, line and column, since a file this module
cannot read is a file the gate cannot vouch for.

Literal scanning (strings with every escape Lua 5.1 accepts, long brackets,
numbers, comments) is shared with `tooling.api.lua_tables`, which reads the
client's documentation tables, so both tools read a Lua literal identically.

    python3 -m tooling.validation.lua_syntax FILE...   # parse, report errors
"""

from __future__ import annotations

import argparse
import sys
from dataclasses import dataclass, field
from pathlib import Path
from typing import Iterator, Sequence

# The scanner and literal readers are shared with the documentation-table
# parser on purpose (see the module docstring); they are module-private there
# only because that module has no other consumer of them.
from tooling.api.lua_tables import (
    LUA_KEYWORDS,
    LuaTableError,
    _LONG_BRACKET_OPEN_RE,
    _NAME_RE,
    _Scanner,
    _read_long_string,
    _read_number,
    _read_quoted_string,
    _skip_whitespace_and_comments,
    _starts_number,
)


#: Token kinds.
TOKEN_NAME = "name"
TOKEN_KEYWORD = "keyword"
TOKEN_STRING = "string"
TOKEN_NUMBER = "number"
TOKEN_SYMBOL = "symbol"
TOKEN_END = "end of input"

#: Multi-character symbols, longest first so `...` wins over `..`.
_LONG_SYMBOLS = ("...", "..", "==", "~=", "<=", ">=")

#: Single-character symbols of Lua 5.1.
_SHORT_SYMBOLS = frozenset("+-*/%^#<>=(){}[];:,.")

#: Binary operator priorities as (left, right), from `lparser.c`. A right
#: priority lower than the left one makes the operator right-associative.
BINARY_PRIORITY = {
    "or": (1, 1),
    "and": (2, 2),
    "<": (3, 3),
    ">": (3, 3),
    "<=": (3, 3),
    ">=": (3, 3),
    "~=": (3, 3),
    "==": (3, 3),
    "..": (5, 4),
    "+": (6, 6),
    "-": (6, 6),
    "*": (7, 7),
    "/": (7, 7),
    "%": (7, 7),
    "^": (10, 9),
}

#: Priority of the unary operators `not`, `#` and `-`.
UNARY_PRIORITY = 8

#: The UTF-8 byte order mark as a decoded character.
_BYTE_ORDER_MARK = "﻿"


class LuaSyntaxError(ValueError):
    """The source is not valid Lua 5.1; the message is `<where>:<line>:<column>: <detail>`."""

    def __init__(self, where: str, line: int, column: int, detail: str) -> None:
        super().__init__(f"{where}:{line}:{column}: {detail}")
        self.where = where
        self.line = line
        self.column = column
        self.detail = detail


@dataclass(frozen=True)
class Token:
    """One lexical unit and the position of its first character."""

    kind: str
    value: object
    line: int
    column: int


def tokenize(text: str, where: str = "<string>") -> list[Token]:
    """Split Lua source into tokens, dropping whitespace and comments.

    The list always ends with one `TOKEN_END` token. A leading byte order mark,
    which the client's loader accepts, and a leading `#!` line, which the
    standalone interpreter skips, are both ignored.
    """
    if text.startswith(_BYTE_ORDER_MARK):
        text = text[len(_BYTE_ORDER_MARK) :]
    scanner = _Scanner(text, where)
    if text.startswith("#"):
        line_end = text.find("\n")
        scanner.advance(len(text) if line_end < 0 else line_end)
    tokens: list[Token] = []
    try:
        while True:
            _skip_whitespace_and_comments(scanner)
            if scanner.at_end():
                tokens.append(Token(TOKEN_END, None, scanner.line, scanner.column))
                return tokens
            tokens.append(_read_token(scanner))
    except LuaTableError as failure:
        raise LuaSyntaxError(failure.where, failure.line, failure.column, failure.detail) from None


def _read_token(scanner: _Scanner) -> Token:
    character = scanner.peek()
    line, column = scanner.line, scanner.column
    if character in ('"', "'"):
        literal = _read_quoted_string(scanner)
        return Token(TOKEN_STRING, literal.value, line, column)
    if character == "[" and scanner.match(_LONG_BRACKET_OPEN_RE) is not None:
        literal = _read_long_string(scanner)
        return Token(TOKEN_STRING, literal.value, line, column)
    if _starts_number(scanner):
        literal = _read_number(scanner)
        return Token(TOKEN_NUMBER, literal.value, line, column)
    name = scanner.match(_NAME_RE)
    if name is not None:
        word = scanner.advance(len(name.group()))
        kind = TOKEN_KEYWORD if word in LUA_KEYWORDS else TOKEN_NAME
        return Token(kind, word, line, column)
    for symbol in _LONG_SYMBOLS:
        if scanner.text.startswith(symbol, scanner.index):
            scanner.advance(len(symbol))
            return Token(TOKEN_SYMBOL, symbol, line, column)
    if character in _SHORT_SYMBOLS:
        scanner.advance(1)
        return Token(TOKEN_SYMBOL, character, line, column)
    raise scanner.error(f"unexpected character {character!r}")


# Syntax tree -----------------------------------------------------------------
#
# Every node records the line and column of its first token. Nodes compare by
# identity (`eq=False`), because the analysis keys facts on the node objects
# themselves and two textually equal expressions are still two expressions.


@dataclass(eq=False)
class Node:
    """Base of every syntax tree node."""

    line: int
    column: int


@dataclass(eq=False)
class Expression(Node):
    """Base of every expression node."""


@dataclass(eq=False)
class Statement(Node):
    """Base of every statement node."""


@dataclass(eq=False)
class Block(Node):
    """A sequence of statements; the last may be `return` or `break`."""

    statements: list[Statement] = field(default_factory=list)


@dataclass(eq=False)
class Nil(Expression):
    """`nil`."""


@dataclass(eq=False)
class Boolean(Expression):
    """`true` or `false`."""

    value: bool = False


@dataclass(eq=False)
class Number(Expression):
    """A numeric literal."""

    value: float = 0


@dataclass(eq=False)
class String(Expression):
    """A string literal, escapes decoded."""

    value: str = ""


@dataclass(eq=False)
class Vararg(Expression):
    """`...`."""


@dataclass(eq=False)
class Name(Expression):
    """A variable reference: a local, an upvalue or a global."""

    name: str = ""


@dataclass(eq=False)
class Index(Expression):
    """`target[key]`, or `target.key` with `dotted` set and `key` a `String`."""

    target: Expression | None = None
    key: Expression | None = None
    dotted: bool = False


@dataclass(eq=False)
class Call(Expression):
    """`function(arguments)`."""

    function: Expression | None = None
    arguments: list[Expression] = field(default_factory=list)


@dataclass(eq=False)
class MethodCall(Expression):
    """`receiver:method(arguments)`."""

    receiver: Expression | None = None
    method: str = ""
    method_line: int = 0
    method_column: int = 0
    arguments: list[Expression] = field(default_factory=list)


@dataclass(eq=False)
class Function(Expression):
    """A function body: `function (parameters) ... end`."""

    parameters: list["Name"] = field(default_factory=list)
    is_vararg: bool = False
    body: Block | None = None
    #: A method declared with `:` receives an implicit first parameter `self`.
    is_method: bool = False


@dataclass(eq=False)
class TableField(Node):
    """One field of a table constructor; `key` is `None` for a positional field."""

    key: Expression | None = None
    value: Expression | None = None


@dataclass(eq=False)
class Table(Expression):
    """A table constructor."""

    fields: list[TableField] = field(default_factory=list)


@dataclass(eq=False)
class BinaryOperation(Expression):
    """`left operator right`."""

    operator: str = ""
    left: Expression | None = None
    right: Expression | None = None


@dataclass(eq=False)
class UnaryOperation(Expression):
    """`operator operand`, for `not`, `#` and `-`."""

    operator: str = ""
    operand: Expression | None = None


@dataclass(eq=False)
class Parenthesized(Expression):
    """`(expression)`, which truncates a call's results to one value."""

    expression: Expression | None = None


@dataclass(eq=False)
class Local(Statement):
    """`local names = values`."""

    names: list[Name] = field(default_factory=list)
    values: list[Expression] = field(default_factory=list)


@dataclass(eq=False)
class LocalFunction(Statement):
    """`local function name ... end`; the name is in scope inside the body."""

    name: Name | None = None
    function: Function | None = None


@dataclass(eq=False)
class FunctionDeclaration(Statement):
    """`function a.b.c:d ... end`; `target` is the assigned expression."""

    target: Expression | None = None
    function: Function | None = None


@dataclass(eq=False)
class Assign(Statement):
    """`targets = values`."""

    targets: list[Expression] = field(default_factory=list)
    values: list[Expression] = field(default_factory=list)


@dataclass(eq=False)
class CallStatement(Statement):
    """A call used as a statement."""

    call: Expression | None = None


@dataclass(eq=False)
class Do(Statement):
    """`do ... end`."""

    body: Block | None = None


@dataclass(eq=False)
class While(Statement):
    """`while condition do ... end`."""

    condition: Expression | None = None
    body: Block | None = None


@dataclass(eq=False)
class Repeat(Statement):
    """`repeat ... until condition`; the condition sees the body's locals."""

    body: Block | None = None
    condition: Expression | None = None


@dataclass(eq=False)
class IfClause(Node):
    """One `if` or `elseif` arm."""

    condition: Expression | None = None
    body: Block | None = None


@dataclass(eq=False)
class If(Statement):
    """`if ... elseif ... else ... end`; `orelse` is `None` without `else`."""

    clauses: list[IfClause] = field(default_factory=list)
    orelse: Block | None = None


@dataclass(eq=False)
class NumericFor(Statement):
    """`for variable = start, stop[, step] do ... end`."""

    variable: Name | None = None
    start: Expression | None = None
    stop: Expression | None = None
    step: Expression | None = None
    body: Block | None = None


@dataclass(eq=False)
class GenericFor(Statement):
    """`for names in values do ... end`."""

    names: list[Name] = field(default_factory=list)
    values: list[Expression] = field(default_factory=list)
    body: Block | None = None


@dataclass(eq=False)
class Return(Statement):
    """`return values`."""

    values: list[Expression] = field(default_factory=list)


@dataclass(eq=False)
class Break(Statement):
    """`break`."""


@dataclass(eq=False)
class Chunk(Node):
    """A whole source file."""

    body: Block | None = None
    where: str = ""


# Parser ------------------------------------------------------------------------


class _Parser:
    """Recursive-descent parser following Lua 5.1's `lparser.c`."""

    def __init__(self, text: str, where: str) -> None:
        self.where = where
        self.tokens = tokenize(text, where)
        self.position = 0

    # Token helpers

    def peek(self, offset: int = 0) -> Token:
        index = min(self.position + offset, len(self.tokens) - 1)
        return self.tokens[index]

    def advance(self) -> Token:
        token = self.tokens[self.position]
        if token.kind != TOKEN_END:
            self.position += 1
        return token

    def at(self, value: str, offset: int = 0) -> bool:
        """Whether the token `offset` ahead is the symbol or keyword `value`."""
        token = self.peek(offset)
        return token.kind in (TOKEN_SYMBOL, TOKEN_KEYWORD) and token.value == value

    def accept(self, value: str) -> bool:
        if self.at(value):
            self.advance()
            return True
        return False

    def expect(self, value: str, opened: Token | None = None) -> Token:
        if self.at(value):
            return self.advance()
        detail = f"expected '{value}' but found {_describe(self.peek())}"
        if opened is not None:
            detail += f" (to close '{opened.value}' at line {opened.line})"
        raise self.error(self.peek(), detail)

    def expect_name(self) -> Token:
        token = self.peek()
        if token.kind != TOKEN_NAME:
            raise self.error(token, f"expected a name but found {_describe(token)}")
        return self.advance()

    def error(self, token: Token, detail: str) -> LuaSyntaxError:
        return LuaSyntaxError(self.where, token.line, token.column, detail)

    # Blocks and statements

    def parse_chunk(self) -> Chunk:
        first = self.peek()
        body = self.parse_block()
        if self.peek().kind != TOKEN_END:
            raise self.error(self.peek(), f"unexpected {_describe(self.peek())}")
        return Chunk(first.line, first.column, body=body, where=self.where)

    def _block_ends(self) -> bool:
        token = self.peek()
        if token.kind == TOKEN_END:
            return True
        return token.kind == TOKEN_KEYWORD and token.value in ("end", "else", "elseif", "until")

    def parse_block(self) -> Block:
        first = self.peek()
        block = Block(first.line, first.column)
        while not self._block_ends():
            if self.at("return"):
                block.statements.append(self.parse_return())
                break
            if self.at("break"):
                token = self.advance()
                block.statements.append(Break(token.line, token.column))
                self.accept(";")
                break
            statement = self.parse_statement()
            if statement is not None:
                block.statements.append(statement)
        return block

    def parse_return(self) -> Return:
        token = self.expect("return")
        values: list[Expression] = []
        if not self._block_ends() and not self.at(";"):
            values = self.parse_expression_list()
        self.accept(";")
        return Return(token.line, token.column, values=values)

    def parse_statement(self) -> Statement | None:
        token = self.peek()
        if self.accept(";"):
            return None
        if token.kind == TOKEN_KEYWORD:
            handler = {
                "if": self.parse_if,
                "while": self.parse_while,
                "do": self.parse_do,
                "for": self.parse_for,
                "repeat": self.parse_repeat,
                "function": self.parse_function_declaration,
                "local": self.parse_local,
            }.get(str(token.value))
            if handler is not None:
                return handler()
        return self.parse_expression_statement()

    def parse_if(self) -> If:
        token = self.expect("if")
        statement = If(token.line, token.column)
        condition = self.parse_expression()
        self.expect("then")
        statement.clauses.append(IfClause(token.line, token.column, condition, self.parse_block()))
        while self.at("elseif"):
            clause_token = self.advance()
            condition = self.parse_expression()
            self.expect("then")
            statement.clauses.append(
                IfClause(clause_token.line, clause_token.column, condition, self.parse_block())
            )
        if self.accept("else"):
            statement.orelse = self.parse_block()
        self.expect("end", token)
        return statement

    def parse_while(self) -> While:
        token = self.expect("while")
        condition = self.parse_expression()
        self.expect("do")
        body = self.parse_block()
        self.expect("end", token)
        return While(token.line, token.column, condition=condition, body=body)

    def parse_do(self) -> Do:
        token = self.expect("do")
        body = self.parse_block()
        self.expect("end", token)
        return Do(token.line, token.column, body=body)

    def parse_repeat(self) -> Repeat:
        token = self.expect("repeat")
        body = self.parse_block()
        self.expect("until", token)
        condition = self.parse_expression()
        return Repeat(token.line, token.column, body=body, condition=condition)

    def parse_for(self) -> Statement:
        token = self.expect("for")
        first = self.expect_name()
        first_name = Name(first.line, first.column, name=str(first.value))
        if self.accept("="):
            start = self.parse_expression()
            self.expect(",")
            stop = self.parse_expression()
            step = self.parse_expression() if self.accept(",") else None
            self.expect("do")
            body = self.parse_block()
            self.expect("end", token)
            return NumericFor(
                token.line, token.column, variable=first_name, start=start, stop=stop, step=step, body=body
            )
        names = [first_name]
        while self.accept(","):
            name = self.expect_name()
            names.append(Name(name.line, name.column, name=str(name.value)))
        self.expect("in")
        values = self.parse_expression_list()
        self.expect("do")
        body = self.parse_block()
        self.expect("end", token)
        return GenericFor(token.line, token.column, names=names, values=values, body=body)

    def parse_function_declaration(self) -> FunctionDeclaration:
        token = self.expect("function")
        first = self.expect_name()
        target: Expression = Name(first.line, first.column, name=str(first.value))
        is_method = False
        while self.at(".") or self.at(":"):
            separator = self.advance()
            key = self.expect_name()
            target = Index(
                target.line,
                target.column,
                target=target,
                key=String(key.line, key.column, value=str(key.value)),
                dotted=True,
            )
            if separator.value == ":":
                is_method = True
                break
        function = self.parse_function_body(token, is_method)
        return FunctionDeclaration(token.line, token.column, target=target, function=function)

    def parse_local(self) -> Statement:
        token = self.expect("local")
        if self.accept("function"):
            name_token = self.expect_name()
            name = Name(name_token.line, name_token.column, name=str(name_token.value))
            function = self.parse_function_body(token, False)
            return LocalFunction(token.line, token.column, name=name, function=function)
        names: list[Name] = []
        while True:
            name_token = self.expect_name()
            names.append(Name(name_token.line, name_token.column, name=str(name_token.value)))
            if not self.accept(","):
                break
        values = self.parse_expression_list() if self.accept("=") else []
        return Local(token.line, token.column, names=names, values=values)

    def parse_expression_statement(self) -> Statement:
        first = self.peek()
        expression = self.parse_suffixed_expression()
        if self.at("=") or self.at(","):
            targets = [expression]
            while self.accept(","):
                targets.append(self.parse_suffixed_expression())
            self.expect("=")
            values = self.parse_expression_list()
            for target in targets:
                if not isinstance(target, (Name, Index)):
                    raise self.error(first, "cannot assign to this expression")
            return Assign(first.line, first.column, targets=targets, values=values)
        if not isinstance(expression, (Call, MethodCall)):
            raise self.error(first, "syntax error: expected a call or an assignment")
        return CallStatement(first.line, first.column, call=expression)

    # Functions

    def parse_function_body(self, opened: Token, is_method: bool) -> Function:
        open_parenthesis = self.expect("(")
        parameters: list[Name] = []
        is_vararg = False
        if not self.at(")"):
            while True:
                if self.accept("..."):
                    is_vararg = True
                    break
                parameter = self.expect_name()
                parameters.append(Name(parameter.line, parameter.column, name=str(parameter.value)))
                if not self.accept(","):
                    break
        self.expect(")", open_parenthesis)
        body = self.parse_block()
        self.expect("end", opened)
        return Function(
            opened.line,
            opened.column,
            parameters=parameters,
            is_vararg=is_vararg,
            body=body,
            is_method=is_method,
        )

    # Expressions

    def parse_expression_list(self) -> list[Expression]:
        expressions = [self.parse_expression()]
        while self.accept(","):
            expressions.append(self.parse_expression())
        return expressions

    def parse_expression(self, limit: int = 0) -> Expression:
        token = self.peek()
        if token.kind in (TOKEN_KEYWORD, TOKEN_SYMBOL) and token.value in ("not", "#", "-"):
            self.advance()
            operand = self.parse_expression(UNARY_PRIORITY)
            left: Expression = UnaryOperation(
                token.line, token.column, operator=str(token.value), operand=operand
            )
        else:
            left = self.parse_simple_expression()
        while True:
            operator_token = self.peek()
            operator = operator_token.value
            if operator_token.kind not in (TOKEN_KEYWORD, TOKEN_SYMBOL) or operator not in BINARY_PRIORITY:
                return left
            left_priority, right_priority = BINARY_PRIORITY[str(operator)]
            if left_priority <= limit:
                return left
            self.advance()
            right = self.parse_expression(right_priority)
            left = BinaryOperation(left.line, left.column, operator=str(operator), left=left, right=right)

    def parse_simple_expression(self) -> Expression:
        token = self.peek()
        if token.kind == TOKEN_NUMBER:
            self.advance()
            return Number(token.line, token.column, value=token.value)  # type: ignore[arg-type]
        if token.kind == TOKEN_STRING:
            self.advance()
            return String(token.line, token.column, value=str(token.value))
        if token.kind == TOKEN_KEYWORD:
            if token.value == "nil":
                self.advance()
                return Nil(token.line, token.column)
            if token.value in ("true", "false"):
                self.advance()
                return Boolean(token.line, token.column, value=token.value == "true")
            if token.value == "function":
                self.advance()
                return self.parse_function_body(token, False)
        if self.at("..."):
            self.advance()
            return Vararg(token.line, token.column)
        if self.at("{"):
            return self.parse_table()
        return self.parse_suffixed_expression()

    def parse_primary_expression(self) -> Expression:
        token = self.peek()
        if token.kind == TOKEN_NAME:
            self.advance()
            return Name(token.line, token.column, name=str(token.value))
        if self.at("("):
            self.advance()
            inner = self.parse_expression()
            self.expect(")", token)
            return Parenthesized(token.line, token.column, expression=inner)
        raise self.error(token, f"unexpected {_describe(token)}")

    def parse_suffixed_expression(self) -> Expression:
        expression = self.parse_primary_expression()
        while True:
            token = self.peek()
            if self.at("."):
                self.advance()
                key = self.expect_name()
                expression = Index(
                    expression.line,
                    expression.column,
                    target=expression,
                    key=String(key.line, key.column, value=str(key.value)),
                    dotted=True,
                )
            elif self.at("["):
                self.advance()
                key_expression = self.parse_expression()
                self.expect("]", token)
                expression = Index(expression.line, expression.column, target=expression, key=key_expression)
            elif self.at(":"):
                self.advance()
                method = self.expect_name()
                arguments = self.parse_call_arguments()
                expression = MethodCall(
                    expression.line,
                    expression.column,
                    receiver=expression,
                    method=str(method.value),
                    method_line=method.line,
                    method_column=method.column,
                    arguments=arguments,
                )
            elif self.at("(") or self.at("{") or token.kind == TOKEN_STRING:
                arguments = self.parse_call_arguments()
                expression = Call(expression.line, expression.column, function=expression, arguments=arguments)
            else:
                return expression

    def parse_call_arguments(self) -> list[Expression]:
        token = self.peek()
        if token.kind == TOKEN_STRING:
            self.advance()
            return [String(token.line, token.column, value=str(token.value))]
        if self.at("{"):
            return [self.parse_table()]
        self.expect("(")
        if self.accept(")"):
            return []
        arguments = self.parse_expression_list()
        self.expect(")", token)
        return arguments

    def parse_table(self) -> Table:
        token = self.expect("{")
        table = Table(token.line, token.column)
        while not self.at("}"):
            field_token = self.peek()
            if self.at("["):
                self.advance()
                key = self.parse_expression()
                self.expect("]", field_token)
                self.expect("=")
                value = self.parse_expression()
                table.fields.append(TableField(field_token.line, field_token.column, key=key, value=value))
            elif field_token.kind == TOKEN_NAME and self.at("=", 1):
                self.advance()
                self.advance()
                key_node = String(field_token.line, field_token.column, value=str(field_token.value))
                value = self.parse_expression()
                table.fields.append(TableField(field_token.line, field_token.column, key=key_node, value=value))
            else:
                value = self.parse_expression()
                table.fields.append(TableField(field_token.line, field_token.column, key=None, value=value))
            if not (self.accept(",") or self.accept(";")):
                break
        self.expect("}", token)
        return table


def _describe(token: Token) -> str:
    if token.kind == TOKEN_END:
        return TOKEN_END
    if token.kind in (TOKEN_SYMBOL, TOKEN_KEYWORD):
        return f"'{token.value}'"
    return f"{token.kind} {token.value!r}"


def parse(text: str, where: str = "<string>") -> Chunk:
    """Parse Lua 5.1 source into a `Chunk`; raises `LuaSyntaxError` on invalid input."""
    return _Parser(text, where).parse_chunk()


def parse_file(path: Path, where: str | None = None) -> Chunk:
    """Parse one file, labelling errors with `where` (the path by default)."""
    return parse(path.read_text(encoding="utf-8"), str(path) if where is None else where)


def children(node: Node) -> Iterator[Node]:
    """Yield the direct child nodes of `node` in source order."""
    for value in vars(node).values():
        if isinstance(value, Node):
            yield value
        elif isinstance(value, list):
            for item in value:
                if isinstance(item, Node):
                    yield item


def walk(node: Node) -> Iterator[Node]:
    """Yield `node` and every node below it, parents before children."""
    stack = [node]
    while stack:
        current = stack.pop()
        yield current
        stack.extend(reversed(list(children(current))))


def parse_args(argv: Sequence[str] | None = None) -> argparse.Namespace:
    parser = argparse.ArgumentParser(
        prog="python3 -m tooling.validation.lua_syntax",
        description="Parse Lua 5.1 files and report the first syntax error in each.",
    )
    parser.add_argument("paths", nargs="+", type=Path, help="Lua files to parse")
    return parser.parse_args(argv)


def main(argv: Sequence[str] | None = None) -> int:
    """Parse every file given and print one line per file."""
    arguments = parse_args(argv)
    failures = 0
    for path in arguments.paths:
        try:
            chunk = parse_file(path)
        except (LuaSyntaxError, OSError, UnicodeDecodeError) as failure:
            failures += 1
            print(f"error: {failure}", file=sys.stderr)
            continue
        print(f"{path}: {len(chunk.body.statements) if chunk.body else 0} top-level statement(s)")
    return 1 if failures else 0


if __name__ == "__main__":
    raise SystemExit(main())
