"""Hold every runtime Lua file to Lua 5.1's per-function limits, with headroom.

    python3 -m tooling.validation.lua_limits
    python3 -m tooling.validation.lua_limits packages/commKit/src/CommKit.lua
    python3 -m tooling.validation.lua_limits --update

Lua 5.1 refuses to compile a function with more than 200 active local
variables (``LUAI_MAXVARS``) or more than 60 upvalues (``LUAI_MAXUPVALUES``).
A file that reaches either limit does not load at all, and nothing showed how
close a file was: CommKit and CommandKit had 2 locals of headroom in their
main chunks before anyone counted. This gate measures every function of every
runtime file (``packages/*/src/**/*.lua``, parts included) from the compiler's
own listing, ``luac -p -l -l``, and fails well before the limit:

==========================  ======  =======
measure                     warns   fails
==========================  ======  =======
main-chunk active locals    > 180   > 190
any other function's locals         > 190
upvalues of any function            > 50
==========================  ======  =======

Constants per function are measured and printed for the largest file, not
judged: Lua 5.1 allows 262,143 per function, far beyond any Kit.

"Active locals" is the peak number of locals alive at one instruction, which
is what the compiler limits, not the number a function declares: a local
whose block has ended no longer counts. A local the compiler declared but no
instruction saw alive (the control variable of an empty loop) still counted
while it was declared, so it is treated as alive for one instruction. Measured
this way a file at the limit reports exactly 200 (`tooling/tests/test_lua_limits.py`
holds that calibration against the real compiler).

**The ratchet.** A file already above a fail line when the gate arrived is
held at its measured value by an entry in `lua_limits.json`, and the value
may only go down:

- a measured value above its entry fails;
- a measured value below its entry fails too, asking for the entry to be
  lowered, so an entry always equals the measurement and raising one can
  never pass unnoticed;
- an entry for a file no longer above the fail line fails as stale;
- ``--update`` rewrites the entries to the measured values and refuses to
  raise any.

See docs/TOOLING.md ("Lua limits").
"""

from __future__ import annotations

import argparse
import json
import re
import shutil
import subprocess
import sys
from pathlib import Path
from typing import NamedTuple, Sequence


ROOT = Path(__file__).resolve().parents[2]

#: The ratchet: files allowed above a fail line, at their measured value.
RATCHET_FILE = Path(__file__).resolve().with_name("lua_limits.json")

#: Lua 5.1's own limits, for the headroom figures.
COMPILER_LOCALS_LIMIT = 200
COMPILER_UPVALUES_LIMIT = 60

#: Where the gate warns and where it fails.
MAIN_LOCALS_WARN = 180
MAIN_LOCALS_FAIL = 190
FUNCTION_LOCALS_FAIL = 190
UPVALUES_FAIL = 50

#: The measures a ratchet entry may hold, each with its fail line.
RATCHET_MEASURES = {
    "mainLocals": MAIN_LOCALS_FAIL,
    "functionLocals": FUNCTION_LOCALS_FAIL,
    "functionUpvalues": UPVALUES_FAIL,
}

#: The header of one function in a `luac -l -l` listing.
FUNCTION_HEADER_RE = re.compile(r"^(?P<kind>main|function) <(?P<source>.+):(?P<line>\d+),\d+> ")

#: The header of one of a function's tables in a `luac -l -l` listing.
SECTION_HEADER_RE = re.compile(r"^(?P<section>constants|locals|upvalues) \((?P<count>\d+)\) for ")

MISSING_LUAC_MESSAGE = """\
error: luac was not found on PATH.

luac comes with the Lua 5.1 interpreter the test suites use:

    hererocks ~/.local/lua51 --lua 5.1.5 --luarocks 3.13.0
    export PATH="$HOME/.local/lua51/bin:$PATH"

See docs/DEVELOPMENT.md for the full toolchain.\
"""


class FunctionLimits(NamedTuple):
    """What one function of a listing uses: its first line, and its three measures."""

    line: int
    is_main: bool
    locals: int
    upvalues: int
    constants: int


class FileLimits(NamedTuple):
    """The judged measures of one file: its main chunk and its largest other functions."""

    path: str
    main_locals: int
    function_locals: int
    function_locals_line: int
    function_upvalues: int
    function_upvalues_line: int
    constants: int

    def measure(self, name: str) -> int:
        """Return one ratchet measure (`mainLocals`, `functionLocals`, `functionUpvalues`)."""
        return {
            "mainLocals": self.main_locals,
            "functionLocals": self.function_locals,
            "functionUpvalues": self.function_upvalues,
        }[name]


class Finding(NamedTuple):
    """One verdict line: ``level`` is ``"error"`` or ``"warning"``."""

    level: str
    message: str


def peak_active(intervals: Sequence[tuple[int, int]]) -> int:
    """Return the most intervals alive at one instruction.

    Each interval is ``(start, end)`` in instruction numbers, alive from
    ``start`` up to but not including ``end``; an interval with ``end <=
    start`` is alive for one instruction. Where one interval ends and another
    starts at the same instruction, the ending one is counted out first.
    """
    events: list[tuple[int, int]] = []
    for start, end in intervals:
        events.append((start, 1))
        events.append((max(end, start + 1), -1))
    events.sort(key=lambda event: (event[0], event[1]))
    active = peak = 0
    for _, delta in events:
        active += delta
        peak = max(peak, active)
    return peak


def parse_listing(listing: str) -> list[FunctionLimits]:
    """Read every function of a `luac -p -l -l` listing, main chunk first."""
    functions: list[FunctionLimits] = []
    current: dict[str, int] | None = None
    section: str | None = None
    local_intervals: list[tuple[int, int]] = []

    def finish() -> None:
        if current is not None:
            functions.append(
                FunctionLimits(
                    line=current["line"],
                    is_main=bool(current["main"]),
                    locals=peak_active(local_intervals),
                    upvalues=current["upvalues"],
                    constants=current["constants"],
                )
            )

    for line in listing.splitlines():
        header = FUNCTION_HEADER_RE.match(line)
        if header is not None:
            finish()
            current = {
                "line": int(header.group("line")),
                "main": header.group("kind") == "main",
                "upvalues": 0,
                "constants": 0,
            }
            section = None
            local_intervals = []
            continue
        table = SECTION_HEADER_RE.match(line)
        if table is not None and current is not None:
            section = table.group("section")
            if section in ("upvalues", "constants"):
                current[section] = int(table.group("count"))
            continue
        if section == "locals":
            # `<index> <name> <startpc> <endpc>`, tab-separated.
            fields = line.split()
            if len(fields) >= 4 and fields[-1].isdigit() and fields[-2].isdigit():
                local_intervals.append((int(fields[-2]), int(fields[-1])))
    finish()
    return functions


def measure_file(path: Path, luac: str) -> FileLimits:
    """Compile one file with `luac -p -l -l` and summarise its functions.

    Raises ``RuntimeError`` with the compiler's message when the file does not
    compile, which is what a file over a limit does.
    """
    completed = subprocess.run(
        [luac, "-p", "-l", "-l", str(path)], capture_output=True, text=True, check=False
    )
    if completed.returncode != 0:
        raise RuntimeError(completed.stderr.strip() or f"luac failed on {path}")
    functions = parse_listing(completed.stdout)
    main = next(function for function in functions if function.is_main)
    others = [function for function in functions if not function.is_main]
    most_locals = max(others, key=lambda function: function.locals, default=None)
    most_upvalues = max(others, key=lambda function: function.upvalues, default=None)
    return FileLimits(
        path=display_path(path),
        main_locals=main.locals,
        function_locals=most_locals.locals if most_locals else 0,
        function_locals_line=most_locals.line if most_locals else 0,
        function_upvalues=most_upvalues.upvalues if most_upvalues else 0,
        function_upvalues_line=most_upvalues.line if most_upvalues else 0,
        constants=max(function.constants for function in functions),
    )


def display_path(path: Path) -> str:
    """Return ``path`` relative to the repository when it is inside it, POSIX-style."""
    try:
        return path.resolve().relative_to(ROOT.resolve()).as_posix()
    except ValueError:
        return path.as_posix()


def runtime_files(root: Path) -> list[Path]:
    """Return every runtime Lua file under ``root/packages/*/src``, sorted."""
    return sorted((root / "packages").glob("*/src/**/*.lua"))


def load_ratchet(path: Path) -> dict[str, dict[str, int]]:
    """Read the ratchet file: ``{"files": {"<path>": {"<measure>": <n>}}}``."""
    data = json.loads(path.read_text(encoding="utf-8"))
    files = data.get("files") if isinstance(data, dict) else None
    if not isinstance(files, dict):
        raise ValueError(f'{path.name}: expected an object with a "files" object')
    ratchet: dict[str, dict[str, int]] = {}
    for file_path, entry in files.items():
        if not isinstance(entry, dict) or not entry:
            raise ValueError(f'{path.name}: "{file_path}" must map measures to numbers')
        for measure, value in entry.items():
            if measure not in RATCHET_MEASURES:
                raise ValueError(f'{path.name}: "{file_path}" has unknown measure "{measure}"')
            if isinstance(value, bool) or not isinstance(value, int):
                raise ValueError(f'{path.name}: "{file_path}" {measure} must be a whole number')
        ratchet[file_path] = dict(entry)
    return ratchet


def write_ratchet(path: Path, ratchet: dict[str, dict[str, int]]) -> None:
    """Write the ratchet sorted by file and measure, as the committed file is."""
    files = {
        file_path: {measure: ratchet[file_path][measure] for measure in sorted(ratchet[file_path])}
        for file_path in sorted(ratchet)
    }
    path.write_text(json.dumps({"files": files}, indent=2) + "\n", encoding="utf-8")


def where(limits: FileLimits, measure: str) -> str:
    """Name the function a measure belongs to: the main chunk, or a line."""
    if measure == "mainLocals":
        return f"{limits.path}: main chunk"
    line = limits.function_locals_line if measure == "functionLocals" else limits.function_upvalues_line
    return f"{limits.path}:{line}: function"


def describe(measure: str) -> str:
    """Name a measure in a message."""
    return "upvalues" if measure == "functionUpvalues" else "active locals"


def compiler_limit(measure: str) -> int:
    """Return Lua 5.1's own limit for a measure."""
    return COMPILER_UPVALUES_LIMIT if measure == "functionUpvalues" else COMPILER_LOCALS_LIMIT


def judge(limits: FileLimits, entry: dict[str, int] | None) -> list[Finding]:
    """Hold one file's measures to the fail lines and to its ratchet entry."""
    findings: list[Finding] = []
    entry = entry or {}
    for measure, fail_line in RATCHET_MEASURES.items():
        value = limits.measure(measure)
        held = entry.get(measure)
        headroom = compiler_limit(measure) - value
        label = f"{where(limits, measure)} has {value} {describe(measure)}"
        if held is None:
            if value > fail_line:
                findings.append(
                    Finding(
                        "error",
                        f"{label}, above the gate's {fail_line} ({headroom} left before Lua "
                        "5.1 refuses the file); move code into a `do` block, a part or a "
                        "function of its own",
                    )
                )
            elif measure == "mainLocals" and value > MAIN_LOCALS_WARN:
                findings.append(
                    Finding(
                        "warning",
                        f"{label}, above {MAIN_LOCALS_WARN}; {fail_line - value} left before "
                        f"the gate fails",
                    )
                )
            continue
        if value > held:
            findings.append(
                Finding(
                    "error",
                    f"{label}, more than the {held} {RATCHET_FILE.name} allows; the ratchet "
                    f"only goes down ({headroom} left before Lua 5.1 refuses the file)",
                )
            )
        elif value <= fail_line:
            findings.append(
                Finding(
                    "error",
                    f"{label}, no longer above {fail_line}: remove its {measure} entry from "
                    f"{RATCHET_FILE.name} (python3 -m tooling.validation.lua_limits --update)",
                )
            )
        elif value < held:
            findings.append(
                Finding(
                    "error",
                    f"{label}, fewer than the {held} {RATCHET_FILE.name} records: lower the "
                    "entry (python3 -m tooling.validation.lua_limits --update)",
                )
            )
    return findings


def stale_entries(ratchet: dict[str, dict[str, int]], measured: set[str]) -> list[Finding]:
    """Report ratchet entries naming a file the run measured no longer exists."""
    return [
        Finding("error", f"{RATCHET_FILE.name}: \"{path}\" is not a runtime Lua file any more")
        for path in sorted(set(ratchet) - measured)
    ]


def updated_ratchet(
    ratchet: dict[str, dict[str, int]], measured: Sequence[FileLimits]
) -> tuple[dict[str, dict[str, int]], list[str]]:
    """Return the ratchet lowered to the measurements, and what refused to rise.

    An entry is kept only while its file is above the fail line, at the
    measured value. A value above its entry is never written: it is returned
    as a refusal, and the old entry stays. A file over a fail line without
    an entry is not added either; that file has to shrink.
    """
    lowered: dict[str, dict[str, int]] = {}
    refusals: list[str] = []
    for limits in measured:
        entry = ratchet.get(limits.path, {})
        kept: dict[str, int] = {}
        for measure, held in entry.items():
            value = limits.measure(measure)
            if value > held:
                refusals.append(f"{limits.path} {measure}: {value} is above the entry {held}")
                kept[measure] = held
            elif value > RATCHET_MEASURES[measure]:
                kept[measure] = value
        if kept:
            lowered[limits.path] = kept
    return lowered, refusals


def parse_args(argv: Sequence[str] | None = None) -> argparse.Namespace:
    """Parse the command line."""
    parser = argparse.ArgumentParser(
        prog="python3 -m tooling.validation.lua_limits",
        description=(
            "Measure active locals and upvalues of every runtime Lua function with luac "
            "and hold them below Lua 5.1's limits, with a ratchet for files already close."
        ),
    )
    parser.add_argument(
        "paths",
        nargs="*",
        type=Path,
        help="files to judge (default: every packages/*/src/**/*.lua)",
    )
    parser.add_argument(
        "--update",
        action="store_true",
        help=f"lower the entries of {RATCHET_FILE.name} to the measured values; never raises one",
    )
    parser.add_argument("--luac", default="luac", help="the Lua 5.1 compiler (default: luac on PATH)")
    return parser.parse_args(argv)


def main(argv: Sequence[str] | None = None) -> int:
    """Entry point for ``python3 -m tooling.validation.lua_limits``."""
    arguments = parse_args(argv)
    luac = shutil.which(arguments.luac)
    if luac is None:
        print(MISSING_LUAC_MESSAGE, file=sys.stderr)
        return 127
    try:
        ratchet = load_ratchet(RATCHET_FILE)
    except (OSError, ValueError) as failure:
        print(f"error: {failure}", file=sys.stderr)
        return 2

    paths = arguments.paths or runtime_files(ROOT)
    measured: list[FileLimits] = []
    findings: list[Finding] = []
    for path in paths:
        try:
            measured.append(measure_file(path, luac))
        except RuntimeError as failure:
            findings.append(Finding("error", f"{display_path(path)}: does not compile: {failure}"))

    if arguments.update:
        if arguments.paths:
            print("error: --update measures every runtime file; do not name paths", file=sys.stderr)
            return 2
        lowered, refusals = updated_ratchet(ratchet, measured)
        if lowered != ratchet:
            write_ratchet(RATCHET_FILE, lowered)
            print(f"updated {RATCHET_FILE.name}")
        ratchet = lowered
        findings.extend(Finding("error", f"not raised: {refusal}") for refusal in refusals)

    for limits in measured:
        findings.extend(judge(limits, ratchet.get(limits.path)))
    if not arguments.paths:
        findings.extend(stale_entries(ratchet, {limits.path for limits in measured}))

    errors = [finding for finding in findings if finding.level == "error"]
    for finding in findings:
        print(f"{finding.level}: {finding.message}", file=sys.stderr)
    fullest = sorted(measured, key=lambda limits: limits.main_locals, reverse=True)[:5]
    print(f"Lua limits checked for {len(measured)} file(s); fullest main chunks:")
    for limits in fullest:
        print(
            f"  {limits.main_locals:4d} of {COMPILER_LOCALS_LIMIT} locals "
            f"({COMPILER_LOCALS_LIMIT - limits.main_locals} left)  {limits.path}"
        )
    if errors:
        print(f"Lua limits failed with {len(errors)} error(s).", file=sys.stderr)
        return 1
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
