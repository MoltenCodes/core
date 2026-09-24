"""The apiKit naming rules: how a Blizzard name becomes a wrapper name.

`docs/API_KIT_DESIGN.md` (section 6) promises that wrapper names are produced
by documented rules, that the systematic name is canonical, that a short
alias is reviewed data, and that a collision fails generation rather than
being resolved by a silent suffix. This module is those rules; `naming.json`
beside it is the reviewed data:

- `words`: the mixed-case words the generic splitter cannot recognise
  (`PvP`, `BNet`, `CVar`). Without them `PvPScoreInfo` would split into
  `Pv`, `P`, `Score`, `Info` and lowerCamelCase to `pvPScoreInfo`.
- `namespaceAliases`: the short alias of a systematic namespace name
  (`addOnProfiler` → `profiler`). Both names reach the same table.
- `namespaceExceptions`: a hand-chosen wrapper name for one Blizzard
  namespace or global system, used only to resolve a collision the rules
  produce. Keys are the Blizzard namespace (`C_Foo`) or, for a global system,
  the system name.
- `functionExceptions`: the same for one function, keyed
  `<Blizzard namespace or system>.<Function>`.

The rules:

1. A Blizzard name is split into words at PascalCase boundaries: a lowercase
   letter followed by an uppercase one starts a word (`AddOn` → `Add`, `On`),
   and a run of capitals followed by a lowercase letter ends before its last
   capital (`NPCName` → `NPC`, `Name`). Digits stay with the word they follow
   (`Axe1H` is one word, written `axe1h`; `Bar2Foo` → `Bar2`, `Foo`). A word from `words` is
   taken whole wherever it occurs. An underscore separates words, and an
   all-capitals piece between underscores is one word written as a name:
   `LFG_ROLEConstants` → `Lfg`, `Role`, `Constants`; `ZoomIn_Position` →
   `Zoom`, `In`, `Position`.
2. lowerCamelCase writes the first word in lowercase and the rest unchanged:
   `GetNPCName` → `getNPCName`, `UIWidgetManager` → `uiWidgetManager`,
   `PvPScoreInfo` → `pvpScoreInfo`.
3. A `C_` namespace drops the prefix before rule 1: `C_AddOnProfiler` →
   `addOnProfiler`. A namespace without the prefix (`string`, `table`) is
   treated the same way. A global system (functions without a namespace) is
   named from its documentation system name: `Unit` → `unit`.
4. A global function drops its system's words when its name starts with them
   and more words follow: `UnitName` in `Unit` → `name`; `GetTime` in
   `System` keeps its whole name → `getTime`. Functions in a `C_` namespace
   never drop anything.
5. Events are named from their documented PascalCase name (`AddonLoaded` →
   `addonLoaded`), enums, constants tables and structures from their names
   (`PhaseReason` → `phaseReason`).

Everything else (collisions, the exception lookups) is decided by the
normaliser, which asks this module for the systematic name and applies the
exception tables on top.
"""

from __future__ import annotations

import json
import re
from dataclasses import dataclass, field
from pathlib import Path
from typing import Any, Sequence

from tooling.validation.validate_manifests import ROOT


#: Location of the rules data relative to the repository root.
NAMING_PATH = Path("tooling") / "api" / "naming.json"

#: Default absolute location, derived from the relative one.
DEFAULT_NAMING_FILE = ROOT / NAMING_PATH

#: The keys the rules file carries, and nothing else.
RULES_KEYS = {"words", "namespaceAliases", "namespaceExceptions", "functionExceptions"}

#: The prefix Blizzard gives its namespaced API tables.
NAMESPACE_PREFIX = "C_"

#: A Blizzard identifier: letters and digits, starting with a letter or underscore.
IDENTIFIER_RE = re.compile(r"^[A-Za-z_][A-Za-z0-9_]*$")

#: A wrapper name: lowerCamelCase, letters and digits only.
WRAPPER_NAME_RE = re.compile(r"^[a-z][A-Za-z0-9]*$")

#: Words Lua reserves. A wrapper name that is one of them would need bracket
#: access everywhere, so the validator refuses it and asks for an exception.
LUA_KEYWORDS = frozenset(
    "and break do else elseif end false for function if in local nil not or repeat "
    "return then true until while".split()
)


class NamingError(ValueError):
    """The rules file exists but does not have the shape this module documents."""


@dataclass(frozen=True)
class NamingRules:
    """The reviewed naming data: known words, aliases and exceptions."""

    words: tuple[str, ...]
    namespace_aliases: dict[str, str] = field(default_factory=dict)
    namespace_exceptions: dict[str, str] = field(default_factory=dict)
    function_exceptions: dict[str, str] = field(default_factory=dict)

    def alias_for(self, namespace_wrapper: str) -> str | None:
        """Return the short alias of a systematic namespace name, if one is listed."""
        return self.namespace_aliases.get(namespace_wrapper)


def split_words(name: str, known_words: Sequence[str] = ()) -> list[str]:
    """Split a PascalCase, camelCase or underscored Blizzard name into words (rule 1).

    `known_words` are matched first at every position, longest first, so a
    listed mixed-case word is never cut by the generic boundaries. An
    underscore separates words, and in an underscored name every all-capitals
    word (`ITEM_WEAPON_SUBCLASS`, `LFG_ROLEConstants`) is written as a name
    (`Item`, `Weapon`, `Subclass`; `Lfg`, `Role`, `Constants`), because such
    pieces are the words of a constant, not initialisms.
    """
    if "_" in name:
        words: list[str] = []
        for piece in name.split("_"):
            for word in split_words(piece, known_words):
                is_capitals_piece = word.isupper() and len(word) > 1
                words.append(word.capitalize() if is_capitals_piece else word)
        return words

    ordered_known = sorted(known_words, key=len, reverse=True)
    words = []
    current = ""
    position = 0
    while position < len(name):
        known = _known_word_at(name, position, ordered_known)
        if known is not None:
            if current:
                words.append(current)
                current = ""
            words.append(known)
            position += len(known)
            continue

        character = name[position]
        if current and _starts_new_word(current, character, name[position + 1 : position + 2]):
            words.append(current)
            current = ""
        current += character
        position += 1

    if current:
        words.append(current)
    return words


def _known_word_at(name: str, position: int, ordered_known: Sequence[str]) -> str | None:
    """Return the listed word that starts at `position`, if the boundary is clean.

    A known word only counts when what follows it is not a lowercase letter or
    digit; otherwise `PvPer` would be cut into `PvP`, `er`.
    """
    for word in ordered_known:
        if not name.startswith(word, position):
            continue
        following = name[position + len(word) : position + len(word) + 1]
        if following and (following.islower() or following.isdigit()):
            continue
        return word
    return None


def _starts_new_word(current: str, character: str, following: str) -> bool:
    """Decide whether `character` begins a new word after the word `current`."""
    if not character.isupper():
        return False
    previous = current[-1]
    if previous.islower():
        return True
    if previous.isdigit():
        # `Bar2Foo` splits before `Foo`; `Axe1H` keeps `H` (nothing lowercase follows).
        return following.islower()
    # `previous` is uppercase: a run of capitals ends before a capital that is
    # followed by a lowercase letter (`NPCName` → `NPC` | `Name`).
    return following.islower()


def lower_camel(words: Sequence[str]) -> str:
    """Join words as lowerCamelCase (rule 2): first word lowercase, the rest unchanged."""
    if not words:
        raise NamingError("cannot name an empty list of words")
    first, *rest = words
    return first.lower() + "".join(rest)


def namespace_wrapper_name(blizzard_namespace: str, rules: NamingRules) -> str:
    """Return the systematic wrapper name of a Blizzard namespace (rule 3).

    `C_AddOnProfiler` → `addOnProfiler`; `string` → `string`.
    """
    bare = blizzard_namespace
    if bare.startswith(NAMESPACE_PREFIX):
        bare = bare[len(NAMESPACE_PREFIX) :]
    if not bare:
        raise NamingError(f"namespace {blizzard_namespace!r} has no name after the prefix")
    return lower_camel(split_words(bare, rules.words))


def global_system_wrapper_name(system_name: str, rules: NamingRules) -> str:
    """Return the wrapper name of a global system (rule 3): `Unit` → `unit`."""
    return lower_camel(split_words(system_name, rules.words))


def function_wrapper_name(
    function_name: str,
    rules: NamingRules,
    *,
    global_system: str | None = None,
) -> str:
    """Return the systematic wrapper name of a function (rules 2 and 4).

    `global_system` is the documentation system name of a function without a
    Blizzard namespace; its words are dropped from the front of the function
    name when more words follow. Pass `None` for a namespaced function.
    """
    words = split_words(function_name, rules.words)
    if global_system is not None:
        system_words = split_words(global_system, rules.words)
        prefix_matches = words[: len(system_words)] == system_words
        if prefix_matches and len(words) > len(system_words):
            words = words[len(system_words) :]
    return lower_camel(words)


def member_wrapper_name(name: str, rules: NamingRules) -> str:
    """Return the wrapper name of an event, enum, constants table or structure (rule 5)."""
    return lower_camel(split_words(name, rules.words))


def _require_string_mapping(where: str, value: Any, key_pattern: re.Pattern[str] | None) -> dict[str, str]:
    if not isinstance(value, dict):
        raise NamingError(f"{where} must be an object")
    for key, target in value.items():
        if not isinstance(key, str) or not key:
            raise NamingError(f"{where} has an empty key")
        if key_pattern is not None and not key_pattern.fullmatch(key):
            raise NamingError(f"{where} key {key!r} does not match {key_pattern.pattern}")
        if not isinstance(target, str) or not WRAPPER_NAME_RE.fullmatch(target):
            raise NamingError(f"{where}.{key} must be a lowerCamelCase wrapper name")
    return dict(value)


def parse_naming_rules(data: Any) -> NamingRules:
    """Validate the decoded rules file and convert it to `NamingRules`.

    A listed word must be one the generic splitter would cut (`PvP`, `BNet`);
    a word it already keeps whole (`GUID`) is noise here and is refused. Words
    are sorted and unique, so a reviewer can see what changed. Aliases must
    not point at themselves or at another alias.
    """
    if not isinstance(data, dict) or set(data) != RULES_KEYS:
        raise NamingError(f"rules must be an object with exactly {sorted(RULES_KEYS)}")

    words = data["words"]
    if not isinstance(words, list) or not all(isinstance(word, str) for word in words):
        raise NamingError("words must be an array of strings")
    for word in words:
        if not IDENTIFIER_RE.fullmatch(word) or len(split_words(word)) == 1:
            raise NamingError(f"words: {word!r} is not a word the generic splitter would cut")
    if words != sorted(words):
        raise NamingError("words must be sorted")
    if len(set(words)) != len(words):
        raise NamingError("words lists the same word twice")

    aliases = _require_string_mapping("namespaceAliases", data["namespaceAliases"], WRAPPER_NAME_RE)
    for systematic, alias in aliases.items():
        if alias == systematic:
            raise NamingError(f"namespaceAliases.{systematic} points at itself")
        if alias in aliases:
            raise NamingError(f"namespaceAliases.{systematic}: {alias!r} is itself aliased")
    if len(set(aliases.values())) != len(aliases):
        raise NamingError("namespaceAliases gives one alias to two namespaces")

    namespace_exceptions = _require_string_mapping(
        "namespaceExceptions", data["namespaceExceptions"], IDENTIFIER_RE
    )
    function_exceptions = _require_string_mapping(
        "functionExceptions",
        data["functionExceptions"],
        re.compile(r"^[A-Za-z_][A-Za-z0-9_]*\.[A-Za-z_][A-Za-z0-9_]*$"),
    )
    return NamingRules(
        words=tuple(words),
        namespace_aliases=aliases,
        namespace_exceptions=namespace_exceptions,
        function_exceptions=function_exceptions,
    )


def load_naming_rules(path: Path = DEFAULT_NAMING_FILE) -> NamingRules:
    """Read and validate the rules at `path`.

    Raises `OSError` when the file cannot be read, `json.JSONDecodeError` (a
    `ValueError`) when it is not JSON, and `NamingError` when its shape is wrong.
    """
    return parse_naming_rules(json.loads(path.read_text(encoding="utf-8")))
