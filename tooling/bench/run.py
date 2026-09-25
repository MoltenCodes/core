"""Run the host benchmark and collect raw JSON results.

    python3 -m tooling.bench.run [--workload NAME ...] [--repeat N] [--warmup N] [--rounds N]
                                 [--out FILE] [--lua PATH] [--cache DIR]

For every selected workload and both sides (MoltenCodes, then Ace3) the runner
starts host Lua 5.1 processes running `tooling/bench/lua/main.lua`: one to list
the cases, one for the correctness checks, and **one per case and round**, so
no case inherits heap, frames or registrations from another and the two sides
never share a process. The sides' runs are interleaved (`Session.run_workload`). Each process prints one JSON document; the runner adds what a
reader needs to judge the numbers (machine, interpreter, commits, settings)
and writes the whole run as one JSON file, or to standard output.

Timing is noisy by nature, which is why nothing here is a CI gate; the
methodology and how to read a result are in `docs/BENCHMARKS.md`. Ace3 is
fetched at the pinned commit into a cache outside the repository first
(`tooling.bench.ace3`).
"""

from __future__ import annotations

import argparse
import datetime
import json
import os
import shutil
import statistics
import subprocess
import sys
from pathlib import Path
from typing import Any, Callable, Sequence

from tooling.bench import ace3, host
from tooling.bench.workloads import BY_NAME, LUA_ROOT, SIDES, WORKLOADS, Workload
from tooling.test.run import build_lua_path

ROOT = Path(__file__).resolve().parents[2]
PACKAGES = ROOT / "packages"

#: Format version of the results file; `report` refuses any other.
RESULTS_SCHEMA = 1

#: Defaults: per case and side, three rounds (fresh processes), each with two
#: untimed warm-up batches and five timed ones: fifteen timed batches in all.
DEFAULT_WARMUP = 2
DEFAULT_REPEAT = 5
DEFAULT_ROUNDS = 3

#: The interpreter the repository's toolchain installs (docs/DEVELOPMENT.md).
DEFAULT_LUA = Path.home() / ".local" / "lua51" / "bin" / "lua"

#: Seconds one Lua process may take before the run is abandoned.
PROCESS_TIMEOUT = 900

#: Measures the cost of one empty `for` iteration, which every timed loop pays.
LOOP_OVERHEAD_SCRIPT = """
local iterations = 20000000
local best = math.huge
for _ = 1, 5 do
  local started = os.clock()
  for _ = 1, iterations do end
  local elapsed = (os.clock() - started) * 1e9 / iterations
  if elapsed < best then best = elapsed end
end
io.write(string.format("%.4f", best))
"""

#: Runs a Lua process: arguments in, (exit status, stdout, stderr) out.
LuaRunner = Callable[[Sequence[str], dict[str, str]], "tuple[int, str, str]"]


class BenchError(Exception):
    """The benchmark could not run; the message says why."""


def run_lua_process(command: Sequence[str], environment: dict[str, str]) -> tuple[int, str, str]:
    """Run one Lua process from the Lua workload directory and capture its output."""
    result = subprocess.run(
        list(command),
        cwd=LUA_ROOT,
        env=environment,
        capture_output=True,
        text=True,
        check=False,
        timeout=PROCESS_TIMEOUT,
    )
    return result.returncode, result.stdout, result.stderr


def resolve_lua(requested: Path | None) -> Path:
    """The Lua 5.1 interpreter: `--lua`, `$MOLTENCODES_BENCH_LUA`, the toolchain one, or `lua`."""
    candidates: list[Path] = []
    if requested is not None:
        candidates.append(requested)
    else:
        explicit = os.environ.get("MOLTENCODES_BENCH_LUA")
        if explicit:
            candidates.append(Path(explicit))
        candidates.append(DEFAULT_LUA)
        found = shutil.which("lua")
        if found:
            candidates.append(Path(found))
    for candidate in candidates:
        if candidate.is_file() and os.access(candidate, os.X_OK):
            return candidate
    raise BenchError(
        "no Lua 5.1 interpreter was found; install it as docs/DEVELOPMENT.md describes "
        "or pass --lua PATH"
    )


def lua_version(lua: Path) -> str:
    """The interpreter's version line, which must name Lua 5.1."""
    result = subprocess.run([str(lua), "-v"], capture_output=True, text=True, check=False)
    line = (result.stdout + result.stderr).strip().splitlines()
    version = line[0] if line else ""
    if not version.startswith("Lua 5.1"):
        raise BenchError(f"{lua} is not Lua 5.1 ({version or 'no version line'})")
    return version


def lua_environment(inherited: dict[str, str] | None = None) -> dict[str, str]:
    """The process environment: `LUA_PATH` with the bench modules, every Kit and the fake client."""
    environment = dict(os.environ if inherited is None else inherited)
    packages = sorted(path.name for path in PACKAGES.iterdir() if (path / "src").is_dir())
    kit_path = build_lua_path(packages, support_packages=(), inherited=environment.get("LUA_PATH"))
    environment["LUA_PATH"] = str(LUA_ROOT / "?.lua") + ";" + kit_path
    return environment


def parse_document(stdout: str, context: str) -> dict[str, Any]:
    """The single JSON document a Lua process printed."""
    lines = [line for line in stdout.splitlines() if line.strip()]
    if len(lines) != 1:
        raise BenchError(
            f"{context}: expected one JSON line on standard output, found {len(lines)}"
        )
    try:
        document = json.loads(lines[0])
    except ValueError as problem:
        raise BenchError(f"{context}: output is not JSON: {problem}") from problem
    if not isinstance(document, dict):
        raise BenchError(f"{context}: output is not a JSON object")
    return document


class Session:
    """One benchmark run: the interpreter, the environment and the settings."""

    def __init__(
        self,
        lua: Path,
        ace3_directory: Path,
        warmup: int,
        repetitions: int,
        rounds: int = 1,
        runner: LuaRunner = run_lua_process,
        environment: dict[str, str] | None = None,
        progress: Callable[[str], None] | None = None,
    ) -> None:
        self.lua = lua
        self.ace3_directory = ace3_directory
        self.warmup = warmup
        self.repetitions = repetitions
        self.rounds = rounds
        self.runner = runner
        self.environment = lua_environment() if environment is None else environment
        self.progress = progress or (lambda message: print(message, file=sys.stderr, flush=True))

    def invoke(
        self, workload: Workload, side: str, mode: str, case: str | None = None
    ) -> dict[str, Any]:
        """Run one Lua process and return its document."""
        command = [
            str(self.lua),
            "main.lua",
            "--workload",
            workload.name,
            "--side",
            side,
            "--mode",
            mode,
            "--ace3",
            str(self.ace3_directory),
            "--warmup",
            str(self.warmup),
            "--repetitions",
            str(self.repetitions),
        ]
        if case is not None:
            command.extend(["--case", case])
        context = f"{workload.name}/{side}/{case or mode}"
        status, stdout, stderr = self.runner(command, self.environment)
        if status != 0:
            detail = stderr.strip() or stdout.strip() or f"exit status {status}"
            raise BenchError(f"{context} failed: {detail}")
        return parse_document(stdout, context)

    def run_workload(self, workload: Workload) -> dict[str, Any]:
        """Both sides of one workload, their cases interleaved over several rounds.

        Each round runs every case once per side, in a fresh process each
        time. The two sides' runs of one case follow each other, and which
        side goes first alternates from case to case and from round to round,
        so a change in machine load during the run (another process starting,
        the scheduler moving the process to a slower core) falls on both sides
        alike instead of on whichever side happened to run later. The rounds'
        timed batches are then pooled (`merge_rounds`).
        """
        self.progress(f"==> {workload.name}: {workload.compares}")
        sides: dict[str, dict[str, Any]] = {}
        listed: dict[str, set[str]] = {}
        names: list[str] = []
        for side in SIDES:
            listing = self.invoke(workload, side, "list")
            checks = self.invoke(workload, side, "checks")
            sides[side] = {
                "libraries": listing.get("libraries", []),
                "checks": checks.get("checks", []),
                "cases": [],
            }
            listed[side] = set(listing.get("cases", []))
            names.extend(name for name in listing.get("cases", []) if name not in names)

        results: dict[tuple[str, str], list[dict[str, Any]]] = {}
        for round_index in range(self.rounds):
            for index, name in enumerate(names):
                order = SIDES if (index + round_index) % 2 == 0 else tuple(reversed(SIDES))
                for side in order:
                    if name not in listed[side]:
                        continue
                    self.progress(
                        f"  {workload.name} / {side} / {name} (round {round_index + 1})"
                    )
                    result = self.invoke(workload, side, "case", name)
                    result.pop("libraries", None)
                    results.setdefault((side, name), []).append(result)

        for side in SIDES:
            sides[side]["cases"] = [
                merge_rounds(results[(side, name)]) for name in names if name in listed[side]
            ]
        return {
            "name": workload.name,
            "title": workload.title,
            "compares": workload.compares,
            "sides": sides,
        }

    def loop_overhead(self) -> float | None:
        """Nanoseconds of one empty `for` iteration on this interpreter, or `None`."""
        status, stdout, _ = self.runner(
            [str(self.lua), "-e", LOOP_OVERHEAD_SCRIPT], self.environment
        )
        try:
            return float(stdout.strip()) if status == 0 else None
        except ValueError:
            return None


def merge_rounds(rounds: Sequence[dict[str, Any]]) -> dict[str, Any]:
    """Pool one case's results from several rounds into one result.

    The timed batches of every round are kept, in run order, and the median
    and minimum are taken over all of them. Allocation per operation is the
    median of the rounds' values (it is the same in every round unless the
    case allocates nondeterministically). The extra measurements are the
    first round's; they do not depend on timing.
    """
    first = dict(rounds[0])
    samples = [
        value
        for result in rounds
        for value in result.get("nanosecondsPerOperation", [])
        if value is not None
    ]
    allocations = [
        result["allocatedBytesPerOperation"]
        for result in rounds
        if result.get("allocatedBytesPerOperation") is not None
    ]
    first["rounds"] = len(rounds)
    first["nanosecondsPerOperation"] = samples
    first["medianNanoseconds"] = statistics.median(samples) if samples else None
    first["minimumNanoseconds"] = min(samples) if samples else None
    first["allocatedBytesPerOperation"] = statistics.median(allocations) if allocations else None
    return first


def select_workloads(names: Sequence[str]) -> list[Workload]:
    """The requested workloads in catalogue order, or all of them."""
    if not names:
        return list(WORKLOADS)
    unknown = sorted(set(names) - set(BY_NAME))
    if unknown:
        known = ", ".join(BY_NAME)
        raise BenchError(f"unknown workload {', '.join(unknown)}; known: {known}")
    return [workload for workload in WORKLOADS if workload.name in names]


def run(
    workloads: Sequence[Workload],
    session: Session,
    ace3_source: ace3.Ace3Source,
    lua_version_line: str,
    command_line: str,
    today: datetime.date | None = None,
) -> dict[str, Any]:
    """Run the selected workloads and assemble the results document."""
    packages = sorted({name for workload in workloads for name in workload.packages})
    document: dict[str, Any] = {
        "schema": RESULTS_SCHEMA,
        "kind": "host",
        "date": (today or datetime.date.today()).isoformat(),
        "command": command_line,
        "host": host.describe_host(),
        "lua": {"version": lua_version_line, "interpreter": "PUC Lua (host), not the game client"},
        "settings": {
            "warmupBatches": session.warmup,
            "timedBatches": session.repetitions,
            "rounds": session.rounds,
            "clock": "os.clock (process CPU time)",
            "allocation": "collectgarbage('count') delta over one batch with the collector stopped",
            "loopOverheadNanoseconds": session.loop_overhead(),
            "loadAverageAtStart": host.load_average(),
        },
        "moltencodes": host.describe_repository(packages),
        "ace3": ace3_source.as_json(),
    }
    document["workloads"] = [session.run_workload(workload) for workload in workloads]
    document["settings"]["loadAverageAtEnd"] = host.load_average()
    return document


def parse_args(argv: Sequence[str] | None = None) -> argparse.Namespace:
    """Parse the command line."""
    parser = argparse.ArgumentParser(
        prog="python3 -m tooling.bench.run",
        description=(
            "Run the host benchmark (MoltenCodes Kits against Ace3) on Lua 5.1 and write "
            "raw JSON results. Fetches Ace3 at the pinned commit into a cache outside the "
            "repository first. See docs/BENCHMARKS.md."
        ),
    )
    parser.add_argument(
        "--workload",
        action="append",
        default=[],
        metavar="NAME",
        help="run only this workload (repeatable); one of: " + ", ".join(BY_NAME),
    )
    parser.add_argument(
        "--repeat",
        type=int,
        default=DEFAULT_REPEAT,
        metavar="N",
        help=f"timed batches per case and round (default {DEFAULT_REPEAT})",
    )
    parser.add_argument(
        "--warmup",
        type=int,
        default=DEFAULT_WARMUP,
        metavar="N",
        help=f"untimed warm-up batches per case and round (default {DEFAULT_WARMUP})",
    )
    parser.add_argument(
        "--rounds",
        type=int,
        default=DEFAULT_ROUNDS,
        metavar="N",
        help=f"fresh processes per case and side, interleaved (default {DEFAULT_ROUNDS})",
    )
    parser.add_argument(
        "--out", type=Path, default=None, help="write the results here (default: standard output)"
    )
    parser.add_argument("--lua", type=Path, default=None, help="the Lua 5.1 interpreter")
    parser.add_argument(
        "--cache", type=Path, default=None, help="the Ace3 cache root (see tooling.bench.ace3)"
    )
    arguments = parser.parse_args(argv)
    if arguments.repeat < 1:
        parser.error("--repeat must be at least 1")
    if arguments.warmup < 0:
        parser.error("--warmup must not be negative")
    if arguments.rounds < 1:
        parser.error("--rounds must be at least 1")
    return arguments


def main(argv: Sequence[str] | None = None) -> int:
    """Fetch Ace3, run the benchmark, write the results."""
    arguments = parse_args(argv)
    try:
        workloads = select_workloads(arguments.workload)
        lua = resolve_lua(arguments.lua)
        version = lua_version(lua)
        source = ace3.fetch_ace3(arguments.cache)
        session = Session(
            lua, source.directory, arguments.warmup, arguments.repeat, arguments.rounds
        )
        command_line = "python3 -m tooling.bench.run " + " ".join(
            sys.argv[1:] if argv is None else list(argv)
        )
        document = run(workloads, session, source, version, command_line.strip())
    except (BenchError, ace3.FetchError, subprocess.TimeoutExpired) as problem:
        print(f"error: {problem}", file=sys.stderr)
        return 1

    text = json.dumps(document, indent=2, sort_keys=False) + "\n"
    if arguments.out is None:
        sys.stdout.write(text)
    else:
        arguments.out.parent.mkdir(parents=True, exist_ok=True)
        arguments.out.write_text(text, encoding="utf-8")
        print(f"wrote {arguments.out}", file=sys.stderr)
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
