"""Parser for the client's API documentation tables, which are Lua literals.

The World of Warcraft client documents its own API as Lua files under
`Interface/AddOns/Blizzard_APIDocumentationGenerated/`, one per system or
constants group. Every file declares one local table and hands it to the
client's documentation registry:

    local Example =
    {
        Name = "Example",
        Type = "System",
        Functions = { ... },
        Events = { ... },
        Tables = { ... },
        Predicates = { },
    };

    APIDocumentation:AddDocumentationTable(Example);

The tables are pure data: strings, numbers, booleans and nested table
constructors, plus the occasional reference to a global constant. The `apiKit`
normaliser (`docs/API_KIT_DESIGN.md`, section 14) needs that data as Python
values without running Lua, so this module reads the Lua literal syntax
directly. It parses only what a data table can contain; anything that would
need evaluation (a call, an operator) is an error naming the offending token,
because a change in the source format must fail loudly rather than be guessed
at.

Conversion rules, the contract the normaliser depends on:

- A table whose fields are all positional (`{ "a", "b" }`) becomes a `list`
  in source order.
- A table whose fields are all keyed (`Name = v`, `["Name"] = v`, `[1] = v`)
  becomes a `dict` with `str`, `int` or `float` keys.
- An empty table `{ }` becomes an empty `list`, because in these files only
  the list-valued keys (`Functions`, `Events`, `Tables`, `Predicates`,
  `Payload`, `Arguments`, `Returns`, `Fields`, `Documentation`) are ever
  empty.
- A table mixing positional and keyed fields is a `LuaTableError`: it never
  occurs in these files, and silently choosing one shape would hide a format
  change.
- A key that appears twice in one table is a `LuaTableError`.
- `nil` becomes `None`; `true` and `false` become booleans; integer literals,
  decimal or `0x` hexadecimal, become `int`; every other number becomes
  `float`. A `-` directly before a number literal negates it.
- A bare or dotted name in value position (`MAX_RAID_MARKERS`,
  `Enum.SecretAspect.Cooldown`) becomes a `LuaName` carrying the dotted path.
  About thirty of the client's constants files record a value by referring to
  a global constant or an enum member instead of writing the number, so the
  reference is preserved as a value the normaliser must resolve or record;
  it is never guessed at here.
- A sum or difference of such names and numbers (`Constants.Pets.MAX_SLOTS +
  Constants.Pets.EXTRA_SLOTS`, `Last - First + 1`) becomes a `LuaExpression`
  holding the operands and operators in source order. Three of the client's
  constants files write a value this way; `+` and `-` are the only operators
  they use, so they are the only ones accepted. Any other non-literal (a call,
  another operator, a reserved word) is a `LuaTableError` naming the token.
- Quoted strings (`"..."` or `'...'`) have Lua's escape sequences decoded:
  `\\n`, `\\t`, `\\r`, `\\a`, `\\b`, `\\f`, `\\v`, `\\\\`, `\\"`, `\\'`, up
  to three decimal digits (`\\065`), `\\xhh`, `\\z` (which skips the
  whitespace after it) and a backslash before a line break, which stands for
  that line break. A decimal or hexadecimal escape yields the character with
  that code point.
- Long-bracket strings (`[[...]]`, `[==[...]==]`) are taken verbatim, except
  that a line break directly after the opening bracket is dropped and every
  line break inside is normalised to `\\n`, both as Lua does.
- Fields are separated by `,` or `;`, with an optional trailing separator.
  `--` line comments and `--[[ ]]` block comments may appear wherever
  whitespace may.

Every failure is a `LuaTableError` whose message carries the source label,
the line and the column, so a problem in a 5,000-line file can be found
without a debugger. The tokenizer works on hand-written scanning and simple
character-class patterns, so a file of that size parses in well under a
second and no input can make it backtrack.

    python3 -m tooling.api.lua_tables PATH...    # parse files or directories
"""

from __future__ import annotations

import argparse
import json
import re
import sys
from dataclasses import dataclass
from pathlib import Path
from typing import Any, Iterator, Sequence


#: The global the documentation files hand their table to.
REGISTRY_NAME = "APIDocumentation"

#: The method of that global which receives the table.
REGISTRY_METHOD = "AddDocumentationTable"

#: Token kinds produced by `_tokenize`.
TOKEN_STRING = "string"
TOKEN_NUMBER = "number"
TOKEN_NAME = "name"
TOKEN_SYMBOL = "symbol"
TOKEN_END = "end of input"

#: The names that are values rather than identifiers.
KEYWORD_VALUES: dict[str, Any] = {"nil": None, "true": True, "false": False}

#: Every Lua reserved word; none of them can be a variable name or a field key.
LUA_KEYWORDS = frozenset(
    "and break do else elseif end false for function goto if in local nil not "
    "or repeat return then true until while".split()
)

#: The one-character symbols a data table can contain.
_SYMBOLS = frozenset("{}[]()=,;:-+.")

#: The binary operators a constants file may combine names and numbers with.
_ADDITIVE_OPERATORS = frozenset("+-")

#: Whitespace as Lua's lexer defines it.
_WHITESPACE_RE = re.compile(r"[ \t\r\n\f\v]+")

#: Any one line break: Windows, old Mac, Unix or the reversed pair Lua accepts.
_LINE_BREAK_RE = re.compile(r"\r\n|\n\r|\r|\n")

#: A Lua name. Reserved words match too; the parser tells them apart.
_NAME_RE = re.compile(r"[A-Za-z_][A-Za-z0-9_]*")

#: A hexadecimal integer literal.
_HEX_INTEGER_RE = re.compile(r"0[xX][0-9A-Fa-f]+")

#: A decimal literal: integer or float, with an optional exponent.
_DECIMAL_NUMBER_RE = re.compile(r"(?:[0-9]+(?:\.[0-9]*)?|\.[0-9]+)(?:[eE][+-]?[0-9]+)?")

#: The opening of a long bracket, `[[` or `[=[` and so on; group 1 is the level.
_LONG_BRACKET_OPEN_RE = re.compile(r"\[(=*)\[")

#: A run of ordinary characters inside a quoted string. It stops at a
#: backslash, at either quote character and at a line break, which the string
#: reader then handles one at a time.
_QUOTED_RUN_RE = re.compile(r"""[^\\"'\r\n]+""")

#: The escape sequences that stand for exactly one character.
_SIMPLE_ESCAPES = {
    "n": "\n",
    "t": "\t",
    "r": "\r",
    "a": "\a",
    "b": "\b",
    "f": "\f",
    "v": "\v",
    "\\": "\\",
    '"': '"',
    "'": "'",
}

#: Up to three decimal digits after a backslash.
_DECIMAL_ESCAPE_RE = re.compile(r"[0-9]{1,3}")

#: Exactly two hexadecimal digits after `\x`.
_HEX_ESCAPE_RE = re.compile(r"[0-9A-Fa-f]{2}")

#: The largest code an escape may produce; Lua strings are byte strings.
_MAX_ESCAPE_CODE = 255


class LuaTableError(ValueError):
    """The text is not a Lua data table this module accepts.

    The message always reads `<where>:<line>:<column>: <what was expected>`, and
    the same facts are available as attributes so tooling can group failures by
    file without parsing the message.
    """

    def __init__(self, where: str, line: int, column: int, detail: str) -> None:
        super().__init__(f"{where}:{line}:{column}: {detail}")
        self.where = where
        self.line = line
        self.column = column
        self.detail = detail


@dataclass(frozen=True)
class _Token:
    """One lexical unit with the position of its first character."""

    kind: str
    value: Any
    line: int
    column: int


@dataclass(frozen=True)
class LuaName:
    """A reference to a global by name, found where a literal was expected.

    `path` is the dotted path exactly as written (`NUM_BAG_SLOTS`,
    `Enum.SecretAspect.Cooldown`). The parser cannot know the referenced value
    and does not pretend to; the normaliser decides whether to resolve it from
    the enumerations it has already read or to record it as a reference.
    """

    path: str

    @property
    def parts(self) -> tuple[str, ...]:
        """The path split at the dots: `("Enum", "SecretAspect", "Cooldown")`."""
        return tuple(self.path.split("."))


@dataclass(frozen=True)
class LuaExpression:
    """A sum or difference of numbers and name references, kept unevaluated.

    `operands` has one more entry than `operators`; `operators[i]` sits between
    `operands[i]` and `operands[i + 1]`, all in source order. The parser could
    not evaluate the expression without knowing the referenced globals, and
    which of the operands are resolvable is the normaliser's knowledge.
    """

    operands: tuple[int | float | LuaName, ...]
    operators: tuple[str, ...]

    @property
    def text(self) -> str:
        """The expression as Lua source with single spaces: `A.B - A.C + 1`."""
        pieces = [_operand_text(self.operands[0])]
        for operator, operand in zip(self.operators, self.operands[1:]):
            pieces.append(operator)
            pieces.append(_operand_text(operand))
        return " ".join(pieces)


def _operand_text(operand: int | float | LuaName) -> str:
    if isinstance(operand, LuaName):
        return operand.path
    return repr(operand)


@dataclass(frozen=True)
class DocumentationFile:
    """One parsed documentation file.

    `table` is always a `dict`: a file whose top-level table has no keyed fields
    is rejected, because the normaliser reads `Name`, `Functions` and the other
    keys from it. `registered` records whether the trailing
    `APIDocumentation:AddDocumentationTable(<variable>)` call is present; the
    client only sees tables that are registered, so the normaliser treats an
    unregistered table as absent.
    """

    variable_name: str
    table: dict
    registered: bool


class _Scanner:
    """A cursor over the source text that keeps its line and column in step.

    Positions are one-based, as editors show them. Every move goes through
    `advance`, which counts the line breaks it passes, so the tokenizer never
    tracks lines by hand.
    """

    def __init__(self, text: str, where: str) -> None:
        self.text = text
        self.where = where
        self.index = 0
        self.line = 1
        self.line_start = 0

    @property
    def column(self) -> int:
        return self.index - self.line_start + 1

    def at_end(self) -> bool:
        return self.index >= len(self.text)

    def peek(self, offset: int = 0) -> str:
        """The character `offset` places ahead, or an empty string past the end."""
        position = self.index + offset
        return self.text[position : position + 1]

    def match(self, pattern: re.Pattern[str], offset: int = 0) -> re.Match[str] | None:
        """Match `pattern` anchored `offset` places ahead of the cursor."""
        return pattern.match(self.text, self.index + offset)

    def advance(self, length: int) -> str:
        """Move past `length` characters and return them, counting line breaks."""
        span = self.text[self.index : self.index + length]
        self.index += length
        last_break_end = None
        for line_break in _LINE_BREAK_RE.finditer(span):
            self.line += 1
            last_break_end = line_break.end()
        if last_break_end is not None:
            self.line_start = self.index - (len(span) - last_break_end)
        return span

    def error(
        self, detail: str, line: int | None = None, column: int | None = None
    ) -> LuaTableError:
        """A `LuaTableError` at the cursor, or at an explicit earlier position."""
        return LuaTableError(
            self.where,
            self.line if line is None else line,
            self.column if column is None else column,
            detail,
        )


def _skip_whitespace_and_comments(scanner: _Scanner) -> None:
    while not scanner.at_end():
        whitespace = scanner.match(_WHITESPACE_RE)
        if whitespace is not None:
            scanner.advance(len(whitespace.group()))
        elif scanner.peek() == "-" and scanner.peek(1) == "-":
            _skip_comment(scanner)
        else:
            return


def _skip_comment(scanner: _Scanner) -> None:
    """Skip a `--` comment: a long bracket right after the dashes, else the rest of the line."""
    if scanner.match(_LONG_BRACKET_OPEN_RE, offset=2) is not None:
        scanner.advance(2)
        _read_long_bracket(scanner, "comment")
        return
    line_break = _LINE_BREAK_RE.search(scanner.text, scanner.index)
    end = len(scanner.text) if line_break is None else line_break.start()
    scanner.advance(end - scanner.index)


def _read_long_bracket(scanner: _Scanner, what: str) -> str:
    """Read `[=*[ ... ]=*]` at the cursor and return the body as Lua would.

    Lua drops a line break that directly follows the opening bracket and
    normalises every other line break in the body to a newline.
    """
    opening = scanner.match(_LONG_BRACKET_OPEN_RE)
    assert opening is not None, "caller checks the opening bracket"
    start_line, start_column = scanner.line, scanner.column
    closing = "]" + opening.group(1) + "]"
    body_start = opening.end()
    body_end = scanner.text.find(closing, body_start)
    if body_end < 0:
        raise scanner.error(f"unterminated long bracket {what}", start_line, start_column)
    scanner.advance(body_end + len(closing) - scanner.index)
    body = scanner.text[body_start:body_end]
    leading_break = _LINE_BREAK_RE.match(body)
    if leading_break is not None:
        body = body[leading_break.end() :]
    return _LINE_BREAK_RE.sub("\n", body)


def _read_escape(scanner: _Scanner) -> str:
    """Decode the escape sequence starting at the backslash under the cursor."""
    escaped = scanner.peek(1)
    if escaped in _SIMPLE_ESCAPES:
        scanner.advance(2)
        return _SIMPLE_ESCAPES[escaped]
    if escaped in ("\r", "\n"):
        line_break = scanner.match(_LINE_BREAK_RE, offset=1)
        assert line_break is not None, "a line break character always matches"
        scanner.advance(1 + len(line_break.group()))
        return "\n"
    if escaped == "x":
        return _read_hexadecimal_escape(scanner)
    if escaped.isdigit():
        return _read_decimal_escape(scanner)
    if escaped == "z":
        scanner.advance(2)
        whitespace = scanner.match(_WHITESPACE_RE)
        if whitespace is not None:
            scanner.advance(len(whitespace.group()))
        return ""
    if escaped == "":
        raise scanner.error("unterminated string: the text ends after a backslash")
    raise scanner.error(f"unknown escape sequence '\\{escaped}' in string")


def _read_hexadecimal_escape(scanner: _Scanner) -> str:
    digits = scanner.match(_HEX_ESCAPE_RE, offset=2)
    if digits is None:
        raise scanner.error("escape '\\x' must be followed by exactly two hexadecimal digits")
    scanner.advance(4)
    return chr(int(digits.group(), 16))


def _read_decimal_escape(scanner: _Scanner) -> str:
    digits = scanner.match(_DECIMAL_ESCAPE_RE, offset=1)
    assert digits is not None, "caller checks the first digit"
    code = int(digits.group())
    if code > _MAX_ESCAPE_CODE:
        raise scanner.error(f"decimal escape '\\{digits.group()}' is above {_MAX_ESCAPE_CODE}")
    scanner.advance(1 + len(digits.group()))
    return chr(code)


def _read_quoted_string(scanner: _Scanner) -> _Token:
    """Read a `"..."` or `'...'` string, decoding escapes as it goes."""
    start_line, start_column = scanner.line, scanner.column
    quote = scanner.advance(1)
    pieces: list[str] = []
    while True:
        if scanner.at_end():
            raise scanner.error("unterminated string", start_line, start_column)
        run = scanner.match(_QUOTED_RUN_RE)
        if run is not None:
            pieces.append(scanner.advance(len(run.group())))
            continue
        character = scanner.peek()
        if character == quote:
            scanner.advance(1)
            return _Token(TOKEN_STRING, "".join(pieces), start_line, start_column)
        if character == "\\":
            pieces.append(_read_escape(scanner))
        elif character in ("\r", "\n"):
            raise scanner.error("unterminated string: a line break needs a backslash before it")
        else:
            pieces.append(scanner.advance(1))


def _read_long_string(scanner: _Scanner) -> _Token:
    start_line, start_column = scanner.line, scanner.column
    body = _read_long_bracket(scanner, "string")
    return _Token(TOKEN_STRING, body, start_line, start_column)


def _read_number(scanner: _Scanner) -> _Token:
    start_line, start_column = scanner.line, scanner.column
    hexadecimal = scanner.match(_HEX_INTEGER_RE)
    if hexadecimal is not None:
        text = scanner.advance(len(hexadecimal.group()))
        value: int | float = int(text, 16)
    else:
        decimal = scanner.match(_DECIMAL_NUMBER_RE)
        assert decimal is not None, "caller checks the first character"
        text = scanner.advance(len(decimal.group()))
        value = int(text) if text.isdigit() else float(text)
    following = scanner.peek()
    if following == "." or _NAME_RE.match(following):
        raise scanner.error(f"malformed number starting with {text!r}", start_line, start_column)
    return _Token(TOKEN_NUMBER, value, start_line, start_column)


def _starts_number(scanner: _Scanner) -> bool:
    first = scanner.peek()
    return first.isdigit() or (first == "." and scanner.peek(1).isdigit())


def _read_token(scanner: _Scanner) -> _Token:
    """Read one token; the caller has skipped whitespace and comments."""
    character = scanner.peek()
    if character in ('"', "'"):
        return _read_quoted_string(scanner)
    if character == "[" and scanner.match(_LONG_BRACKET_OPEN_RE) is not None:
        return _read_long_string(scanner)
    if _starts_number(scanner):
        return _read_number(scanner)
    name = scanner.match(_NAME_RE)
    if name is not None:
        token = _Token(TOKEN_NAME, name.group(), scanner.line, scanner.column)
        scanner.advance(len(name.group()))
        return token
    if character in _SYMBOLS:
        token = _Token(TOKEN_SYMBOL, character, scanner.line, scanner.column)
        scanner.advance(1)
        return token
    raise scanner.error(f"unexpected character {character!r}")


def _tokenize(text: str, where: str) -> Iterator[_Token]:
    """Yield the tokens of `text`, ending with one `TOKEN_END` token.

    `where` labels the source in error messages. Comments and whitespace are
    dropped here, so the parser only ever sees meaningful tokens.
    """
    scanner = _Scanner(text, where)
    while True:
        _skip_whitespace_and_comments(scanner)
        if scanner.at_end():
            yield _Token(TOKEN_END, None, scanner.line, scanner.column)
            return
        yield _read_token(scanner)


def _describe(token: _Token) -> str:
    """Name a token the way an error message should."""
    if token.kind == TOKEN_END:
        return TOKEN_END
    if token.kind == TOKEN_SYMBOL:
        return f"'{token.value}'"
    if token.kind == TOKEN_NAME:
        return f"identifier {token.value!r}"
    return f"{token.kind} {token.value!r}"


class _Parser:
    """Recursive-descent parser over the token stream of one source text."""

    def __init__(self, text: str, where: str) -> None:
        self.where = where
        self.tokens = list(_tokenize(text, where))
        self.position = 0

    def peek(self, offset: int = 0) -> _Token:
        """The token `offset` places ahead; past the end it is the end token."""
        position = min(self.position + offset, len(self.tokens) - 1)
        return self.tokens[position]

    def advance(self) -> _Token:
        token = self.peek()
        if token.kind != TOKEN_END:
            self.position += 1
        return token

    def error(self, token: _Token, detail: str) -> LuaTableError:
        return LuaTableError(self.where, token.line, token.column, detail)

    def at_symbol(self, symbol: str, offset: int = 0) -> bool:
        token = self.peek(offset)
        return token.kind == TOKEN_SYMBOL and token.value == symbol

    def expect_symbol(self, symbol: str) -> _Token:
        if not self.at_symbol(symbol):
            raise self.error(self.peek(), f"expected '{symbol}', found {_describe(self.peek())}")
        return self.advance()

    def expect_name(self, name: str | None = None) -> _Token:
        """Consume a name; the given one, or any name that is not a reserved word."""
        token = self.peek()
        if name is not None:
            if token.kind != TOKEN_NAME or token.value != name:
                raise self.error(token, f"expected '{name}', found {_describe(token)}")
        elif token.kind != TOKEN_NAME or token.value in LUA_KEYWORDS:
            raise self.error(token, f"expected a name, found {_describe(token)}")
        return self.advance()

    def expect_end(self) -> None:
        token = self.peek()
        if token.kind != TOKEN_END:
            raise self.error(token, f"expected {TOKEN_END}, found {_describe(token)}")

    def skip_symbol(self, symbol: str) -> bool:
        """Consume `symbol` when it is next; report whether it was."""
        if self.at_symbol(symbol):
            self.advance()
            return True
        return False

    def parse_value(self) -> Any:
        """Parse one value by the conversion rules in the module docstring."""
        token = self.peek()
        if token.kind == TOKEN_STRING:
            return self.advance().value
        if self.at_symbol("{"):
            return self.parse_table()
        operand = self._parse_operand()
        if self._at_additive_operator():
            return self._parse_expression_tail(operand)
        return operand

    def _parse_operand(self) -> Any:
        """A number, a negated number, a keyword value or a name reference."""
        token = self.peek()
        if token.kind == TOKEN_NUMBER:
            return self.advance().value
        if token.kind == TOKEN_NAME:
            return self._parse_name_value()
        if self.at_symbol("-"):
            return self._parse_negated_number()
        raise self.error(token, f"expected a value, found {_describe(token)}")

    def _at_additive_operator(self) -> bool:
        token = self.peek()
        return token.kind == TOKEN_SYMBOL and token.value in _ADDITIVE_OPERATORS

    def _parse_expression_tail(self, first: Any) -> LuaExpression:
        """Continue `first + ... - ...` after the first operand has been read."""
        operands = [self._require_arithmetic_operand(first, self.peek())]
        operators: list[str] = []
        while self._at_additive_operator():
            operators.append(self.advance().value)
            operand_token = self.peek()
            operands.append(self._require_arithmetic_operand(self._parse_operand(), operand_token))
        return LuaExpression(operands=tuple(operands), operators=tuple(operators))

    def _require_arithmetic_operand(self, operand: Any, token: _Token) -> int | float | LuaName:
        if isinstance(operand, bool) or not isinstance(operand, (int, float, LuaName)):
            raise self.error(
                token, f"only numbers and names can be added or subtracted, found {operand!r}"
            )
        return operand

    def _parse_name_value(self) -> Any:
        """A keyword value, or a global reference such as `Enum.Kind.Member`."""
        token = self.advance()
        if token.value in KEYWORD_VALUES:
            return KEYWORD_VALUES[token.value]
        if token.value in LUA_KEYWORDS:
            raise self.error(token, f"expected a value, found reserved word {token.value!r}")
        parts = [token.value]
        while self.skip_symbol("."):
            parts.append(self.expect_name().value)
        self._reject_call(token)
        return LuaName(".".join(parts))

    def _reject_call(self, name_token: _Token) -> None:
        """A name followed by `(` or `:` would be a call, which only Lua could evaluate."""
        if self.at_symbol("(") or self.at_symbol(":"):
            raise self.error(
                name_token,
                f"expected a value, found a call on {name_token.value!r}; "
                "only literals and names are allowed",
            )

    def _parse_negated_number(self) -> int | float:
        self.expect_symbol("-")
        token = self.peek()
        if token.kind != TOKEN_NUMBER:
            raise self.error(token, f"expected a number after '-', found {_describe(token)}")
        self.advance()
        return -token.value

    def parse_table(self) -> list | dict:
        """Parse `{ ... }` and convert it by the rules in the module docstring."""
        opening = self.expect_symbol("{")
        positional: list[Any] = []
        keyed: dict[Any, Any] = {}
        while not self.at_symbol("}"):
            self._parse_field(positional, keyed)
            if not self._skip_separator():
                break
        self.expect_symbol("}")
        return self._convert_table(opening, positional, keyed)

    def _skip_separator(self) -> bool:
        return self.skip_symbol(",") or self.skip_symbol(";")

    def _parse_field(self, positional: list[Any], keyed: dict[Any, Any]) -> None:
        token = self.peek()
        if token.kind == TOKEN_NAME and self.at_symbol("=", offset=1):
            self.expect_name()
            self.expect_symbol("=")
            self._store_keyed(keyed, token, token.value, self.parse_value())
        elif self.at_symbol("["):
            key = self._parse_bracket_key()
            self.expect_symbol("=")
            self._store_keyed(keyed, token, key, self.parse_value())
        else:
            positional.append(self.parse_value())

    def _parse_bracket_key(self) -> str | int | float:
        self.expect_symbol("[")
        token = self.peek()
        if token.kind in (TOKEN_STRING, TOKEN_NUMBER):
            key: str | int | float = self.advance().value
        elif self.at_symbol("-"):
            key = self._parse_negated_number()
        else:
            raise self.error(token, f"expected a string or number key, found {_describe(token)}")
        self.expect_symbol("]")
        return key

    def _store_keyed(self, keyed: dict[Any, Any], token: _Token, key: Any, value: Any) -> None:
        if key in keyed:
            raise self.error(token, f"key {key!r} appears twice in one table")
        keyed[key] = value

    def _convert_table(
        self, opening: _Token, positional: list[Any], keyed: dict[Any, Any]
    ) -> list | dict:
        if positional and keyed:
            raise self.error(
                opening,
                "table mixes positional and keyed fields; the documentation format never does",
            )
        if keyed:
            return keyed
        return positional


def parse_lua_value(text: str, *, where: str = "<string>") -> Any:
    """Parse one Lua literal and return its Python value.

    `text` holds a table constructor, a string, a number, `true`, `false` or
    `nil`, optionally surrounded by whitespace and comments. Anything after
    the literal is a `LuaTableError`, so a caller cannot mistake a partially
    read text for a complete one. `where` labels the source in error
    messages.
    """
    parser = _Parser(text, where)
    value = parser.parse_value()
    parser.expect_end()
    return value


def _parse_registration(parser: _Parser, variable_name: str) -> bool:
    """Parse the optional `APIDocumentation:AddDocumentationTable(<name>);` if present.

    Returns whether it was there. The name it registers must be the declared one.
    """
    if parser.peek().kind == TOKEN_END:
        return False
    parser.expect_name(REGISTRY_NAME)
    parser.expect_symbol(":")
    parser.expect_name(REGISTRY_METHOD)
    parser.expect_symbol("(")
    argument = parser.expect_name()
    if argument.value != variable_name:
        raise parser.error(
            argument,
            f"{REGISTRY_METHOD} registers {argument.value!r} "
            f"but the file declares {variable_name!r}",
        )
    parser.expect_symbol(")")
    parser.skip_symbol(";")
    return True


def parse_documentation_file(text: str, *, where: str) -> DocumentationFile:
    """Parse one documentation file into its variable name, table and registration.

    The accepted shape is exactly `local <Name> = { ... }`, an optional `;`,
    then optionally `APIDocumentation:AddDocumentationTable(<Name>)` with an
    optional `;`, then the end of the text, with comments allowed anywhere
    between tokens. The registration must name the declared variable: a file
    registering some other name would be a client bug or a format change, and
    either deserves a failure rather than a silent `registered=False`. The
    top-level table must have keyed fields, since the normaliser reads it by
    key. `where` is required because a file is always read from somewhere and
    the label is what makes the error message actionable.
    """
    parser = _Parser(text, where)
    parser.expect_name("local")
    variable_name = parser.expect_name().value
    parser.expect_symbol("=")
    table_token = parser.peek()
    if not parser.at_symbol("{"):
        raise parser.error(
            table_token, f"expected a table constructor, found {_describe(table_token)}"
        )
    table = parser.parse_table()
    if not isinstance(table, dict):
        raise parser.error(
            table_token, "the documentation table must have keyed fields such as Name or Tables"
        )
    parser.skip_symbol(";")
    registered = _parse_registration(parser, variable_name)
    parser.expect_end()
    return DocumentationFile(variable_name=variable_name, table=table, registered=registered)


def _collect_lua_files(paths: Sequence[Path]) -> list[Path]:
    """Expand each argument: a file is itself, a directory is its `*.lua` files, sorted."""
    files: list[Path] = []
    for path in paths:
        if path.is_dir():
            files.extend(sorted(path.rglob("*.lua")))
        else:
            files.append(path)
    return files


def _json_fallback(value: Any) -> str:
    """Render the two non-JSON value kinds as their Lua source text."""
    if isinstance(value, LuaName):
        return value.path
    if isinstance(value, LuaExpression):
        return value.text
    raise TypeError(f"{type(value).__name__} is not a documentation table value")


def _summary_line(path: Path, document: DocumentationFile) -> str:
    counts = ", ".join(
        f"{len(document.table.get(key, []))} {key.lower()}"
        for key in ("Functions", "Events", "Tables")
        if key in document.table
    )
    state = "registered" if document.registered else "not registered"
    return f"{path}: {document.variable_name} ({state}; {counts or 'no entries'})"


def main(argv: Sequence[str] | None = None) -> int:
    """Parse documentation files and report every failure before exiting non-zero.

    This is a development aid for checking a freshly fetched directory: it
    prints one summary line per file, or the parsed table as JSON for a single
    file with `--json`. Every file is attempted so one report shows the whole
    picture, as the tooling design rules ask.
    """
    parser = argparse.ArgumentParser(
        prog="python3 -m tooling.api.lua_tables",
        description="Parse World of Warcraft API documentation tables and report failures.",
    )
    parser.add_argument(
        "paths", nargs="+", type=Path, help="documentation files or directories of them"
    )
    parser.add_argument(
        "--json", action="store_true", help="print the parsed table of a single file as JSON"
    )
    arguments = parser.parse_args(argv)

    files = _collect_lua_files(arguments.paths)
    if arguments.json and len(files) != 1:
        print("error: --json needs exactly one file", file=sys.stderr)
        return 2

    failures = 0
    for path in files:
        try:
            document = parse_documentation_file(path.read_text(encoding="utf-8"), where=str(path))
        except (OSError, UnicodeDecodeError, LuaTableError) as failure:
            print(f"error: {failure}", file=sys.stderr)
            failures += 1
            continue
        if arguments.json:
            print(json.dumps(document.table, indent=2, ensure_ascii=False, default=_json_fallback))
        else:
            print(_summary_line(path, document))

    if failures:
        print(f"error: {failures} of {len(files)} files failed to parse", file=sys.stderr)
        return 1
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
