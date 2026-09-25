"""Read a World of Warcraft saved-variables file without running Lua.

The client writes each addon's saved variables as a Lua chunk of assignments,
``Name = <value>``, where every value is a literal: a string, a number, a
boolean, ``nil`` or a table constructor. ``python3 -m tooling.client.report``
reads the harness's file that way, so this module parses exactly that subset of
Lua and nothing else. It never executes anything: a file that holds a function
call, an operator or any other expression is refused with the line and column
of the first token it does not accept.

What the subset covers, following the Lua 5.1 reference manual (section 2.1
for the lexical rules, 2.5.7 for table constructors):

* strings in double or single quotes with every Lua 5.1 escape (``\\n``,
  ``\\"``, ``\\ddd`` decimal bytes, a backslash before a newline, ...), and
  long brackets (``[[...]]``, ``[==[...]==]``);
* numbers: decimal integers and floats with an optional exponent, hexadecimal
  integers, an optional leading minus sign, and the spellings a C runtime uses
  for infinities and NaN (``inf``, ``-inf``, ``nan``, ``1.#INF``, ``-nan(ind)``)
  because a client may write a non-finite number that way;
* ``true``, ``false`` and ``nil``;
* table constructors with ``[key] = value``, ``name = value`` and positional
  fields, separated by ``,`` or ``;``, with an optional trailing separator;
* ``--`` line comments and ``--[[ ... ]]`` block comments.

The client may write bytes that are not UTF-8 (a player name, a message from
another addon), so the caller hands this module ``bytes``; they are decoded
with ``errors="replace"``, and each escaped ``\\ddd`` byte sequence inside a
string is decoded the same way. A table becomes a Python ``list`` when its keys
are exactly ``1..n``, and a ``dict`` otherwise; an empty table becomes an empty
``dict``, and :func:`as_list` reads either as a list.
"""

from __future__ import annotations

import math
import re
from typing import Any


#: How deeply tables may nest. The harness writes about eight levels; the
#: bound keeps a malformed or hostile file from exhausting Python's stack.
MAX_DEPTH = 64

#: Escapes of a quoted Lua 5.1 string that stand for one character.
SIMPLE_ESCAPES = {
    "a": "\a",
    "b": "\b",
    "f": "\f",
    "n": "\n",
    "r": "\r",
    "t": "\t",
    "v": "\v",
    "\\": "\\",
    '"': '"',
    "'": "'",
}

#: A name: a variable of the chunk or a key written without brackets.
NAME_RE = re.compile(r"[A-Za-z_][A-Za-z0-9_]*")

#: A decimal number, with or without a fraction and exponent.
DECIMAL_RE = re.compile(r"(?:[0-9]+(?:\.[0-9]*)?|\.[0-9]+)(?:[eE][+-]?[0-9]+)?")

#: A hexadecimal integer.
HEXADECIMAL_RE = re.compile(r"0[xX][0-9A-Fa-f]+")

#: The non-finite spellings of a C runtime (``1.#INF``, ``1.#QNAN``,
#: ``nan(ind)``), matched after the optional sign.
NON_FINITE_RE = re.compile(
    r"(?:1\.#INF0*|inf(?:inity)?|1\.#(?:QNAN|IND|SNAN)0*|nan(?:\([A-Za-z0-9_]*\))?)",
    re.IGNORECASE,
)

#: The opening of a long bracket, ``[[`` or ``[==[``.
LONG_BRACKET_RE = re.compile(r"\[(=*)\[")

#: Lua keywords that are values, not names.
VALUE_KEYWORDS = {"true": True, "false": False, "nil": None}


class SavedVariablesError(ValueError):
    """The text is not a chunk of literal assignments; the message names where."""


class _Parser:
    """A recursive-descent parser over the decoded text, one instance per parse."""

    def __init__(self, text: str) -> None:
        self.text = text
        self.position = 0

    # Positions and errors ----------------------------------------------------------

    def where(self, position: int | None = None) -> str:
        """``line L, column C`` of ``position`` (default: the current one), both from 1."""
        index = self.position if position is None else position
        line = self.text.count("\n", 0, index) + 1
        column = index - (self.text.rfind("\n", 0, index) + 1) + 1
        return f"line {line}, column {column}"

    def fail(self, message: str, position: int | None = None) -> SavedVariablesError:
        """An error naming ``message`` and where it happened."""
        return SavedVariablesError(f"{message} at {self.where(position)}")

    # Whitespace and comments -------------------------------------------------------

    def skip_space(self) -> None:
        """Skip whitespace and comments up to the next token."""
        text = self.text
        while self.position < len(text):
            character = text[self.position]
            if character in " \t\r\n\f\v":
                self.position += 1
            elif text.startswith("--", self.position):
                self.skip_comment()
            else:
                return

    def skip_comment(self) -> None:
        """Skip one ``--`` comment, a long-bracket block or the rest of the line."""
        start = self.position
        self.position += 2
        bracket = LONG_BRACKET_RE.match(self.text, self.position)
        if bracket is not None:
            self.read_long_bracket(bracket, start)
            return
        end = self.text.find("\n", self.position)
        self.position = len(self.text) if end < 0 else end + 1

    # Chunk -----------------------------------------------------------------------------

    def parse_chunk(self) -> dict[str, Any]:
        """Every ``Name = value`` assignment of the chunk, in order; a later one wins."""
        assignments: dict[str, Any] = {}
        self.skip_space()
        while self.position < len(self.text):
            name_match = NAME_RE.match(self.text, self.position)
            if name_match is None or name_match.group() in VALUE_KEYWORDS:
                raise self.fail("expected a variable name")
            self.position = name_match.end()
            self.skip_space()
            self.expect("=")
            assignments[name_match.group()] = self.parse_value(depth=0)
            self.skip_space()
            if self.peek(";"):
                self.position += 1
                self.skip_space()
        return assignments

    def peek(self, token: str) -> bool:
        """Whether the text continues with ``token`` at the current position."""
        return self.text.startswith(token, self.position)

    def expect(self, token: str) -> None:
        """Consume ``token``, or fail naming it."""
        if not self.peek(token):
            raise self.fail(f'expected "{token}"')
        self.position += len(token)

    # Values ------------------------------------------------------------------------------

    def parse_value(self, depth: int) -> Any:
        """One literal value."""
        self.skip_space()
        if self.position >= len(self.text):
            raise self.fail("expected a value, found the end of the file")
        character = self.text[self.position]
        if character == "{":
            return self.parse_table(depth + 1)
        if character in "\"'":
            return self.parse_quoted_string()
        bracket = LONG_BRACKET_RE.match(self.text, self.position)
        if bracket is not None:
            start = self.position
            return self.read_long_bracket(bracket, start)
        name_match = NAME_RE.match(self.text, self.position)
        if name_match is not None and name_match.group() in VALUE_KEYWORDS:
            self.position = name_match.end()
            return VALUE_KEYWORDS[name_match.group()]
        return self.parse_number()

    def parse_number(self) -> int | float:
        """A number literal, with its optional minus sign."""
        start = self.position
        negative = self.peek("-")
        if negative:
            self.position += 1
            self.skip_space()
        sign = -1 if negative else 1
        text = self.text

        hexadecimal = HEXADECIMAL_RE.match(text, self.position)
        if hexadecimal is not None:
            self.position = hexadecimal.end()
            return sign * int(hexadecimal.group(), 16)

        non_finite = NON_FINITE_RE.match(text, self.position)
        if non_finite is not None:
            self.position = non_finite.end()
            spelling = non_finite.group().lower()
            if "inf" in spelling:
                return sign * math.inf
            return math.nan

        decimal = DECIMAL_RE.match(text, self.position)
        if decimal is None:
            raise self.fail("expected a value", start)
        self.position = decimal.end()
        if NAME_RE.match(text, self.position) is not None:
            raise self.fail("malformed number", start)
        literal = decimal.group()
        if any(marker in literal for marker in ".eE"):
            return sign * float(literal)
        return sign * int(literal)

    def parse_quoted_string(self) -> str:
        """A string in double or single quotes, with its escapes resolved."""
        start = self.position
        quote = self.text[self.position]
        self.position += 1
        pieces: list[str] = []
        pending_bytes = bytearray()

        def flush_bytes() -> None:
            if pending_bytes:
                pieces.append(pending_bytes.decode("utf-8", errors="replace"))
                pending_bytes.clear()

        text = self.text
        while True:
            if self.position >= len(text):
                raise self.fail("unfinished string", start)
            character = text[self.position]
            if character == quote:
                self.position += 1
                flush_bytes()
                return "".join(pieces)
            if character == "\n":
                raise self.fail("unfinished string", start)
            if character != "\\":
                flush_bytes()
                pieces.append(character)
                self.position += 1
                continue
            self.position += 1
            if self.position >= len(text):
                raise self.fail("unfinished string", start)
            escaped = text[self.position]
            if escaped.isdigit() and escaped.isascii():
                digits = re.match(r"[0-9]{1,3}", text[self.position : self.position + 3])
                assert digits is not None
                value = int(digits.group())
                if value > 255:
                    raise self.fail("escape sequence too large")
                pending_bytes.append(value)
                self.position += len(digits.group())
                continue
            flush_bytes()
            if escaped in SIMPLE_ESCAPES:
                pieces.append(SIMPLE_ESCAPES[escaped])
            elif escaped == "\n":
                pieces.append("\n")
            elif escaped == "\r":
                pieces.append("\n")
                if text.startswith("\n", self.position + 1):
                    self.position += 1
            else:
                raise self.fail(f'invalid escape "\\{escaped}"')
            self.position += 1

    def read_long_bracket(self, opening: re.Match[str], start: int) -> str:
        """The content of a long bracket whose opening ``opening`` matched.

        As in Lua, a newline right after the opening is not part of the content.
        """
        closing = "]" + opening.group(1) + "]"
        content_start = opening.end()
        end = self.text.find(closing, content_start)
        if end < 0:
            raise self.fail("unfinished long bracket", start)
        content = self.text[content_start:end]
        if content.startswith("\r\n"):
            content = content[2:]
        elif content.startswith("\n"):
            content = content[1:]
        self.position = end + len(closing)
        return content

    def parse_table(self, depth: int) -> dict[Any, Any] | list[Any]:
        """A table constructor; a list when its keys are exactly ``1..n``."""
        if depth > MAX_DEPTH:
            raise self.fail(f"tables nest deeper than {MAX_DEPTH} levels")
        self.expect("{")
        fields: dict[Any, Any] = {}
        next_index = 1
        while True:
            self.skip_space()
            if self.peek("}"):
                self.position += 1
                return listed(fields)
            key, value, positional = self.parse_field(depth)
            if positional:
                key = next_index
                next_index += 1
            if value is not None:
                fields[key] = value
            else:
                fields.pop(key, None)
            self.skip_space()
            if self.peek(",") or self.peek(";"):
                self.position += 1
            elif not self.peek("}"):
                raise self.fail('expected "," or "}" in a table')

    def parse_field(self, depth: int) -> tuple[Any, Any, bool]:
        """One field: ``(key, value, positional)``."""
        if self.peek("[") and LONG_BRACKET_RE.match(self.text, self.position) is None:
            self.position += 1
            key_position = self.position
            key = self.parse_value(depth)
            if key is None or (isinstance(key, float) and math.isnan(key)):
                raise self.fail("a table key cannot be nil or NaN", key_position)
            self.skip_space()
            self.expect("]")
            self.skip_space()
            self.expect("=")
            return normalised_key(key), self.parse_value(depth), False
        name_match = NAME_RE.match(self.text, self.position)
        if name_match is not None and name_match.group() not in VALUE_KEYWORDS:
            after = name_match.end()
            probe = after
            while probe < len(self.text) and self.text[probe] in " \t\r\n\f\v":
                probe += 1
            if self.text.startswith("=", probe) and not self.text.startswith("==", probe):
                self.position = probe + 1
                return name_match.group(), self.parse_value(depth), False
        return None, self.parse_value(depth), True


def normalised_key(key: Any) -> Any:
    """A float key with an integral value is the same key as that integer, as in Lua."""
    if isinstance(key, float) and key.is_integer():
        return int(key)
    return key


def listed(fields: dict[Any, Any]) -> dict[Any, Any] | list[Any]:
    """``fields`` as a list when its keys are exactly the integers ``1..n``, n > 0."""
    count = len(fields)
    if count and all(
        isinstance(key, int) and not isinstance(key, bool) and 1 <= key <= count for key in fields
    ):
        return [fields[index] for index in range(1, count + 1)]
    return fields


def parse_saved_variables(data: bytes) -> dict[str, Any]:
    """Every variable a saved-variables file assigns, by name.

    Raises :class:`SavedVariablesError` naming the line and column of the first
    thing that is not a literal assignment.
    """
    text = data.decode("utf-8", errors="replace")
    if text.startswith("﻿"):
        text = text[1:]
    return _Parser(text).parse_chunk()


def as_list(value: Any) -> list[Any]:
    """A table read as a sequence: a list as it is, an empty table as ``[]``.

    Anything else, including a table with other keys, is not a sequence and
    reads as ``[]`` too; callers that must tell the difference check the type.
    """
    if isinstance(value, list):
        return value
    return []
