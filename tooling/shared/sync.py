"""Copy the shared helpers into the Kits that carry them, and check the copies.

    python3 -m tooling.shared.sync              # rewrite every block from its source
    python3 -m tooling.shared.sync --check      # fail when a block differs from its source
    python3 -m tooling.shared.sync --list       # the hand-written copies still to convert

Every Kit is embeddable on its own, so the helpers each needs (the secret
probe, error reporting, key descriptions, the facade check, the limits loop)
live in its own file. Written by hand, those copies drifted: 28 copies of
`isSecret` had 10 bodies. Each helper now has one source under
`tooling/shared/lua/`, and a Kit carries a verbatim copy between markers:

    -- shared:begin validateFacade 1 __FACADE__=GlowKit
    -- Copied from tooling/shared/lua/validateFacade.lua by python3 -m tooling.shared.sync; edit that file, not this copy.
    ...the source's body, with __FACADE__ replaced by GlowKit...
    -- shared:end validateFacade

The copy is committed, so the specs, the language server, selene, the
flavour gate and coverage read the shipped file; `--check` (in the
`repository` CI job and `python3 -m tooling.lint`) makes a hand edit inside
the markers fail with the name of the file to edit instead.

A source file (`tooling/shared/lua/<name>.lua`) carries a header with
`-- shared revision: N`, `-- shared requires: a, b` (blocks that must come
earlier in a Kit's file) and `-- shared parameters: __FACADE__`. Its body runs
from `-- shared:body` to `-- shared:exports`; what comes before the body
(stand-ins that let the source lint and compile alone) and the exports after
it are never copied. Body lines are at most `MAX_SOURCE_COLUMNS` wide, so an
indented copy never needs StyLua to rewrap it.

A block names the revision it was copied at. A block older than its source
fails, unless `tooling/shared/pins.json` pins that Kit's helper to it with a
reason; a pinned block is left as it is. `pins.json` also lists the Kits that
opt out of a helper, which `--list` then leaves out. The gate never fails
because a Kit has no blocks: converting a Kit is that Kit's own change
(docs/CONTRIBUTING.md, "Shared helper blocks").
"""

from __future__ import annotations

import argparse
import json
import re
import sys
from dataclasses import dataclass, field
from pathlib import Path
from typing import Sequence

from tooling.validation.validate_manifests import ROOT

#: Where the canonical sources live, relative to the repository root.
SOURCES_PATH = Path("tooling") / "shared" / "lua"

#: The pins and opt-outs, relative to the repository root.
PINS_PATH = Path("tooling") / "shared" / "pins.json"

#: The widest body line a source may have: StyLua's 100 columns minus room for
#: five levels of indentation in a Kit.
MAX_SOURCE_COLUMNS = 90

#: The length a parameter is measured at in the column check: the longest
#: facade name today is 12 characters (`UnitFrameKit`), with room for two more.
LONGEST_PARAMETER_VALUE = 14

#: A parameter name inside a source, and a parameter value a block gives.
PARAMETER_RE = re.compile(r"^__[A-Z]+__$")
PARAMETER_VALUE_RE = re.compile(r"^[A-Za-z_][A-Za-z0-9_]*$")

#: `-- shared:begin <name> <revision> [PARAM=value ...]`, any indentation.
BEGIN_RE = re.compile(r"^(?P<indent>[ \t]*)-- shared:begin (?P<rest>.*)$")
END_RE = re.compile(r"^(?P<indent>[ \t]*)-- shared:end (?P<name>\S+)\s*$")

#: The hand-written helper definitions `--list` looks for, by helper.
HAND_WRITTEN = {
    "isSecret": re.compile(r"^\s*local function (isSecret|isSecretValue)\("),
    "reportError": re.compile(r"^\s*local function reportError\("),
    "describeKey": re.compile(r"^\s*local function describeKey\("),
    "validateFacade": re.compile(r"^\s*local function validateFacade\("),
    "limits": re.compile(r"^\s*local function validateLimitUpdate\("),
}


class SyncError(ValueError):
    """A source or the pins file does not have the documented shape."""


@dataclass(frozen=True)
class Source:
    """One canonical helper."""

    name: str
    path: Path
    revision: int
    requires: tuple[str, ...]
    parameters: tuple[str, ...]
    body: tuple[str, ...]

    def notice(self) -> str:
        """The first line of every copy, naming the file to edit."""
        return (
            f"-- Copied from {(SOURCES_PATH / (self.name + '.lua')).as_posix()} by "
            "python3 -m tooling.shared.sync; edit that file, not this copy."
        )

    def render(self, indent: str, values: dict[str, str]) -> list[str]:
        """The lines between a block's markers: the notice, then the body."""
        lines = [indent + self.notice()]
        for line in self.body:
            for parameter, value in values.items():
                line = line.replace(parameter, value)
            lines.append(indent + line if line else "")
        return lines


@dataclass
class Block:
    """One marked copy in a Kit's file."""

    path: Path
    name: str
    revision: int
    values: dict[str, str]
    indent: str
    begin: int  # index of the begin line
    end: int  # index of the end line
    problems: list[str] = field(default_factory=list)


@dataclass(frozen=True)
class Pins:
    """Deliberate departures: blocks held at an older revision, and opt-outs."""

    pinned: dict[tuple[str, str], int]
    opted_out: set[tuple[str, str]]


# Sources ----------------------------------------------------------------------------------


def _header_value(lines: Sequence[str], key: str, path: Path) -> str:
    prefix = f"-- shared {key}:"
    for line in lines:
        if line.startswith(prefix):
            return line[len(prefix) :].strip()
    raise SyncError(f"{path}: has no `{prefix}` line")


def _names(value: str) -> tuple[str, ...]:
    return tuple(item.strip() for item in value.split(",") if item.strip())


def parse_source(path: Path) -> Source:
    """Read one canonical source."""
    lines = path.read_text(encoding="utf-8").splitlines()
    try:
        body_start = lines.index("-- shared:body") + 1
        body_end = lines.index("-- shared:exports")
    except ValueError as failure:
        raise SyncError(f"{path}: needs `-- shared:body` and `-- shared:exports` lines") from failure
    if body_end <= body_start:
        raise SyncError(f"{path}: `-- shared:exports` must come after `-- shared:body`")
    header = lines[:body_start]
    revision_text = _header_value(header, "revision", path)
    if not revision_text.isdigit() or int(revision_text) < 1:
        raise SyncError(f"{path}: the revision must be a positive integer")
    parameters = _names(_header_value(header, "parameters", path))
    for parameter in parameters:
        if not PARAMETER_RE.match(parameter):
            raise SyncError(f"{path}: parameter {parameter!r} must look like __NAME__")
    body = tuple(lines[body_start:body_end])
    for number, line in enumerate(body, start=body_start + 1):
        # A parameter is measured at the longest value it may take.
        for parameter in parameters:
            line = line.replace(parameter, "X" * LONGEST_PARAMETER_VALUE)
        if len(line) > MAX_SOURCE_COLUMNS:
            raise SyncError(
                f"{path}:{number}: {len(line)} columns; body lines are at most "
                f"{MAX_SOURCE_COLUMNS} so an indented copy needs no rewrapping"
            )
    return Source(
        name=path.stem,
        path=path,
        revision=int(revision_text),
        requires=_names(_header_value(header, "requires", path)),
        parameters=parameters,
        body=body,
    )


def load_sources(root: Path = ROOT) -> dict[str, Source]:
    """Read every canonical source, by helper name."""
    sources = {path.stem: parse_source(path) for path in sorted((root / SOURCES_PATH).glob("*.lua"))}
    for source in sources.values():
        for required in source.requires:
            if required not in sources:
                raise SyncError(f"{source.path}: requires unknown helper {required!r}")
    return sources


def load_pins(root: Path = ROOT) -> Pins:
    """Read `pins.json`: `{"pins": [...], "optOuts": [...]}`, every entry with a reason."""
    path = root / PINS_PATH
    if not path.is_file():
        return Pins({}, set())
    data = json.loads(path.read_text(encoding="utf-8"))
    pinned: dict[tuple[str, str], int] = {}
    opted_out: set[tuple[str, str]] = set()
    for entry in data.get("pins", []):
        if not isinstance(entry.get("reason"), str) or not entry["reason"].strip():
            raise SyncError(f"{path}: every pin needs a reason")
        pinned[(entry["package"], entry["helper"])] = int(entry["revision"])
    for entry in data.get("optOuts", []):
        if not isinstance(entry.get("reason"), str) or not entry["reason"].strip():
            raise SyncError(f"{path}: every opt-out needs a reason")
        helpers = entry.get("helpers", [])
        for helper in helpers:
            opted_out.add((entry["package"], helper))
    return Pins(pinned, opted_out)


# Blocks -------------------------------------------------------------------------------------


def _parse_begin(rest: str) -> tuple[str, int | None, dict[str, str], list[str]]:
    words = rest.split()
    problems: list[str] = []
    if len(words) < 2 or not words[1].isdigit():
        return (words[0] if words else "", None, {}, ["a begin marker is `-- shared:begin <name> <revision>`"])
    values: dict[str, str] = {}
    for word in words[2:]:
        parameter, separator, value = word.partition("=")
        if not separator or not PARAMETER_RE.match(parameter) or not PARAMETER_VALUE_RE.match(value):
            problems.append(f"cannot read the parameter {word!r}; write __NAME__=Value")
            continue
        values[parameter] = value
    return words[0], int(words[1]), values, problems


def find_blocks(path: Path, lines: Sequence[str]) -> tuple[list[Block], list[str]]:
    """Return the blocks of one file, and any marker that cannot be read."""
    blocks: list[Block] = []
    problems: list[str] = []
    open_block: Block | None = None
    for index, line in enumerate(lines):
        begin = BEGIN_RE.match(line)
        if begin:
            if open_block is not None:
                problems.append(f"{path}:{index + 1}: a block begins inside block {open_block.name!r}")
                continue
            name, revision, values, marker_problems = _parse_begin(begin.group("rest"))
            for problem in marker_problems:
                problems.append(f"{path}:{index + 1}: {problem}")
            if revision is None:
                continue
            open_block = Block(path, name, revision, values, begin.group("indent"), index, -1)
            continue
        end = END_RE.match(line)
        if end:
            if open_block is None or end.group("name") != open_block.name:
                problems.append(f"{path}:{index + 1}: an end marker without its begin marker")
                continue
            open_block.end = index
            blocks.append(open_block)
            open_block = None
    if open_block is not None:
        problems.append(f"{path}:{open_block.begin + 1}: block {open_block.name!r} is never closed")
    return blocks, problems


def package_of(path: Path, root: Path) -> str:
    """The package ID a Kit file belongs to (`packages/<id>/src/...`)."""
    relative = path.relative_to(root)
    return relative.parts[1] if len(relative.parts) > 1 and relative.parts[0] == "packages" else ""


def kit_files(root: Path = ROOT) -> list[Path]:
    """Every runtime Lua file of every package: facades and parts."""
    return sorted(path for path in (root / "packages").glob("*/src/**/*.lua") if path.is_file())


#: How a block compares with its source: equal, a copy `sync` can rewrite
#: (stale content or an older revision), or a problem only a person can fix.
CURRENT, REWRITABLE, BROKEN = "current", "rewritable", "broken"


def source_file(name: str) -> str:
    """The repository path of a helper's source, as messages name it."""
    return (SOURCES_PATH / (name + ".lua")).as_posix()


def check_block(
    block: Block,
    lines: Sequence[str],
    sources: dict[str, Source],
    pins: Pins,
    earlier: set[str],
    package: str,
) -> tuple[str, list[str]]:
    """Compare one block with its source: its state and what is wrong."""
    where = f"{block.path}:{block.begin + 1}"
    source = sources.get(block.name)
    if source is None:
        known = ", ".join(sorted(sources))
        return BROKEN, [f"{where}: unknown shared helper {block.name!r}; known: {known}"]
    problems: list[str] = []
    missing = [parameter for parameter in source.parameters if parameter not in block.values]
    unknown = [parameter for parameter in block.values if parameter not in source.parameters]
    if missing:
        problems.append(f"{where}: {block.name} needs {', '.join(missing)}=<value> on its begin line")
    if unknown:
        problems.append(f"{where}: {block.name} takes no parameter {', '.join(unknown)}")
    for required in source.requires:
        if required not in earlier:
            problems.append(f"{where}: {block.name} needs the {required} block earlier in the file")
    if problems:
        return BROKEN, problems
    if block.revision != source.revision:
        if pins.pinned.get((package, block.name)) == block.revision:
            return CURRENT, []
        return REWRITABLE, [
            f"{where}: {block.name} is at revision {block.revision} but {source_file(block.name)} "
            f"is at {source.revision}; run python3 -m tooling.shared.sync, or pin it in "
            f"{PINS_PATH.as_posix()} with a reason"
        ]
    expected = source.render(block.indent, block.values)
    if list(lines[block.begin + 1 : block.end]) != expected:
        return REWRITABLE, [
            f"{where}: the {block.name} block differs from {source_file(block.name)}; edit "
            "the source and run python3 -m tooling.shared.sync. Expected:\n" + "\n".join(expected)
        ]
    return CURRENT, []


def render_block(block: Block, source: Source) -> list[str]:
    """The whole block, markers included, at the source's revision."""
    begin = f"{block.indent}-- shared:begin {block.name} {source.revision}"
    for parameter, value in block.values.items():
        begin += f" {parameter}={value}"
    return [begin, *source.render(block.indent, block.values), f"{block.indent}-- shared:end {block.name}"]


def process_file(
    path: Path,
    sources: dict[str, Source],
    pins: Pins,
    root: Path,
    write: bool,
) -> list[str]:
    """Check one file's blocks, or rewrite the stale ones when `write` is set.

    Returns the problems left: every difference when checking, and only what
    a person must fix when writing.
    """
    text = path.read_text(encoding="utf-8")
    lines = text.splitlines()
    blocks, problems = find_blocks(path, lines)
    package = package_of(path, root)
    earlier: set[str] = set()
    stale: list[Block] = []
    for block in blocks:
        state, block_problems = check_block(block, lines, sources, pins, earlier, package)
        earlier.add(block.name)
        if state == REWRITABLE and write:
            stale.append(block)
        else:
            problems.extend(block_problems)
    if stale:
        for block in reversed(stale):
            lines[block.begin : block.end + 1] = render_block(block, sources[block.name])
        path.write_text("\n".join(lines) + ("\n" if text.endswith("\n") else ""), encoding="utf-8")
    return problems


def run_check(root: Path = ROOT, write: bool = False, paths: Sequence[Path] = ()) -> list[str]:
    """Check (or rewrite) every Kit file, or only `paths`; return the problems."""
    sources = load_sources(root)
    pins = load_pins(root)
    problems: list[str] = []
    for path in paths or kit_files(root):
        problems.extend(process_file(path, sources, pins, root, write))
    return problems


# Migration list ----------------------------------------------------------------------------


def normalised(lines: Sequence[str]) -> list[str]:
    """Lines without comments, blank lines or indentation, for comparing behaviour."""
    result: list[str] = []
    for line in lines:
        code = re.sub(r"--.*$", "", line).strip()
        if code:
            result.append(code)
    return result


def function_lines(lines: Sequence[str], start: int) -> list[str]:
    """The lines of the `local function` starting at `start`, through its closing `end`."""
    indent = lines[start][: len(lines[start]) - len(lines[start].lstrip())]
    for index in range(start + 1, len(lines)):
        if lines[index] == indent + "end":
            return list(lines[start : index + 1])
    return list(lines[start:])


def matches_source(source: Source, copy: Sequence[str], facade: str) -> bool:
    """Whether a hand-written copy has exactly the source's code (comments aside)."""
    body = [line.replace("__FACADE__", facade) for line in source.body]
    return normalised(copy) == normalised(body)


def facade_names(root: Path) -> dict[str, str]:
    """Each package's facade name (`displayName`), for comparing `validateFacade` copies."""
    names: dict[str, str] = {}
    for manifest in (root / "packages").glob("*/package.manifest.json"):
        data = json.loads(manifest.read_text(encoding="utf-8"))
        names[manifest.parent.name] = str(data.get("displayName", ""))
    return names


def migration_list(root: Path = ROOT) -> list[str]:
    """Every hand-written helper outside a block, as `package file:line helper (verdict)`.

    "identical" means the copy's code, comments and indentation aside, is the
    source's body, so converting it cannot change behaviour. "compare" means
    the text differs: the conversion's author compares the two (the record of
    each helper in docs/ROADMAP.md lists the known behaviour changes) and bumps
    the Kit's revision where behaviour changes.
    """
    sources = load_sources(root)
    pins = load_pins(root)
    facades = facade_names(root)
    rows: list[str] = []
    for path in kit_files(root):
        lines = path.read_text(encoding="utf-8").splitlines()
        blocks, _ = find_blocks(path, lines)
        inside = {index for block in blocks for index in range(block.begin, block.end + 1)}
        package = package_of(path, root)
        for index, line in enumerate(lines):
            if index in inside:
                continue
            for helper, pattern in HAND_WRITTEN.items():
                if not pattern.match(line) or (package, helper) in pins.opted_out:
                    continue
                source = sources.get(helper)
                same = source is not None and matches_source(
                    source, function_lines(lines, index), facades.get(package, "")
                )
                verdict = "identical" if same else "compare"
                relative = path.relative_to(root).as_posix()
                rows.append(f"{package}: {relative}:{index + 1} {helper} ({verdict})")
    return rows


# Command line ------------------------------------------------------------------------------


def parse_args(argv: Sequence[str] | None = None) -> argparse.Namespace:
    """Read the command line."""
    parser = argparse.ArgumentParser(
        prog="python3 -m tooling.shared.sync",
        description=(
            "Copy the shared helpers of tooling/shared/lua/ into the marked blocks of "
            "the Kits, or check the copies. See docs/TOOLING.md."
        ),
    )
    mode = parser.add_mutually_exclusive_group()
    mode.add_argument("--check", action="store_true", help="write nothing; fail on any difference")
    mode.add_argument(
        "--list", action="store_true", help="print the hand-written helpers still to convert"
    )
    parser.add_argument("paths", nargs="*", type=Path, help="only these Kit files")
    return parser.parse_args(argv)


def main(argv: Sequence[str] | None = None) -> int:
    """Run the command; return the process exit status."""
    arguments = parse_args(argv)
    try:
        if arguments.list:
            rows = migration_list()
            for row in rows:
                print(row)
            print(f"{len(rows)} hand-written helper(s) outside a shared block")
            return 0
        paths = [path.resolve() for path in arguments.paths]
        problems = run_check(write=not arguments.check, paths=paths)
    except SyncError as failure:
        print(f"tooling.shared.sync: {failure}", file=sys.stderr)
        return 1
    if problems:
        for problem in problems:
            print(problem, file=sys.stderr)
        return 1
    print("every shared helper block equals its source")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
