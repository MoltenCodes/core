"""Record bridgeKit's AceSerializer-3.0 fixtures from the pinned Ace3.

    python3 -m tooling.fixtures.ace_serializer [--cache DIR] [--lua PATH] [--check]

The command fetches Ace3 at the commit the benchmark pins (`tooling.bench.ace3`,
which verifies a SHA-256 digest over the files it loads and keeps them in a
cache outside the repository), runs `lua/RecordAceSerializer.lua` under host
Lua 5.1 against that checkout, and writes what the library answered to
`packages/bridgeKit/tests/fixtures/AceSerializerFixtures.lua`. The inputs are
this project's own, listed in the Lua script; the module holds only Ace3's
output for them, with a provenance header, and no Ace3 source
(`docs/BRIDGE_KIT_DESIGN.md`, section 3.2).

The recording is formatted with StyLua before it is written, so the module
passes the formatting gate. `--check` records again and compares with the committed module instead of
writing it, keeping the committed recording date, so a changed recorder or a
changed Ace3 pin shows up as a difference. The command needs the network the
first time (to fill the cache) and is not part of CI.
"""

from __future__ import annotations

import argparse
import datetime
import re
import shutil
import subprocess
import sys
from pathlib import Path
from typing import Sequence

from tooling.bench import ace3
from tooling.bench.run import BenchError, lua_version, resolve_lua

ROOT = Path(__file__).resolve().parents[2]

#: The Lua script that calls AceSerializer-3.0 and prints the module.
RECORDER = Path(__file__).resolve().parent / "lua" / "RecordAceSerializer.lua"

#: The committed fixture module bridgeKit's specs load.
FIXTURE = ROOT / "packages" / "bridgeKit" / "tests" / "fixtures" / "AceSerializerFixtures.lua"

#: The provenance line that carries the recording date.
RECORDED_ON = re.compile(r'^\s*recordedOn = "(\d{4}-\d{2}-\d{2})",$', re.MULTILINE)


class FixtureError(Exception):
    """Recording failed; the message says why."""


def recorded_on(module_text: str) -> str | None:
    """The `recordedOn` date of a fixture module, or `None` when it has none."""
    match = RECORDED_ON.search(module_text)
    return match.group(1) if match else None


def record(lua: Path, ace_directory: Path, commit: str, date: str) -> str:
    """Run the recorder and return the module text it printed."""
    result = subprocess.run(
        [str(lua), str(RECORDER), str(ace_directory), commit, date],
        capture_output=True,
        text=True,
        check=False,
    )
    if result.returncode != 0:
        raise FixtureError(f"the recorder failed: {result.stderr.strip()}")
    return result.stdout


def format_lua(text: str) -> str:
    """`text` formatted by StyLua with the repository's `stylua.toml`.

    The committed module passes the formatting gate like every Lua file, so the
    recording is formatted before it is written or compared; StyLua is therefore
    required, as it is for every contributor (docs/DEVELOPMENT.md).
    """
    stylua = shutil.which("stylua")
    if stylua is None:
        raise FixtureError("StyLua is not on PATH; install it as docs/DEVELOPMENT.md describes")
    result = subprocess.run(
        [stylua, "--config-path", str(ROOT / "stylua.toml"), "-"],
        input=text,
        capture_output=True,
        text=True,
        check=False,
    )
    if result.returncode != 0:
        raise FixtureError(f"StyLua could not format the recording: {result.stderr.strip()}")
    return result.stdout


def parse_args(argv: Sequence[str] | None = None) -> argparse.Namespace:
    """Parse the command line."""
    parser = argparse.ArgumentParser(
        prog="python3 -m tooling.fixtures.ace_serializer",
        description=(
            "Record AceSerializer-3.0 output for bridgeKit's specs from Ace3 at the "
            "commit the benchmark pins, into packages/bridgeKit/tests/fixtures/."
        ),
    )
    parser.add_argument("--cache", type=Path, default=None, help="Ace3 cache root (as tooling.bench.ace3)")
    parser.add_argument("--lua", type=Path, default=None, help="the Lua 5.1 interpreter (as tooling.bench.run)")
    parser.add_argument(
        "--check",
        action="store_true",
        help="compare a fresh recording with the committed module instead of writing it",
    )
    return parser.parse_args(argv)


def main(argv: Sequence[str] | None = None) -> int:
    """Record the fixtures, or check the committed ones."""
    arguments = parse_args(argv)
    try:
        lua = resolve_lua(arguments.lua)
        version = lua_version(lua)
        source = ace3.fetch_ace3(arguments.cache)
        committed = FIXTURE.read_text(encoding="utf-8") if FIXTURE.is_file() else None
        date = datetime.date.today().isoformat()
        if arguments.check:
            if committed is None or recorded_on(committed) is None:
                raise FixtureError(f"{FIXTURE.relative_to(ROOT)} is missing or has no recordedOn date")
            date = recorded_on(committed)
        text = format_lua(record(lua, source.directory, source.commit, date))
    except (BenchError, ace3.FetchError, FixtureError) as problem:
        print(f"error: {problem}", file=sys.stderr)
        return 1

    relative = FIXTURE.relative_to(ROOT)
    if arguments.check:
        if text != committed:
            print(f"error: {relative} differs from a fresh recording; run without --check", file=sys.stderr)
            return 1
        print(f"{relative} matches a fresh recording ({version}, Ace3 {source.commit[:12]})")
        return 0
    FIXTURE.parent.mkdir(parents=True, exist_ok=True)
    FIXTURE.write_text(text, encoding="utf-8")
    print(f"wrote {relative} ({version}, Ace3 {source.commit[:12]})")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
