"""Measure line coverage of the runtime packages with LuaCov and hold it to floors.

    python3 -m tooling.test.coverage
    python3 -m tooling.test.coverage timerKit logKit
    python3 -m tooling.test.coverage --summary "$GITHUB_STEP_SUMMARY"
    python3 -m tooling.test.coverage --update-floors

This runs `python3 -m tooling.test.run` with Busted's `--coverage` flag, so
every suite keeps its own process and `LUA_PATH`, merges the statistics a
source file collected under its relative and its absolute spelling, then runs
`luacov` to turn them into `luacov.report.out`. The root `.luacov` limits
the report to `packages/*/src/`: specs and test support are not measured.
Both output files are written at the repository root and ignored by Git.

The run is a gate. LuaCov's line hook allocates on every line, so the
allocation specs, which assert that a hot path allocates nothing, would fail
while it is active; they carry the Busted tag `#allocation` and are left out
here with `--exclude-tags=allocation`. Every other spec must pass.

Each package's line coverage is then held to its floor in
`tooling/test/coverage-floors.json`, a whole percentage. A package below its
floor fails the run, and so does a measured package without a floor.
`--update-floors` is the ratchet: it raises each judged package's floor to its
measured coverage rounded down, adds the missing ones and never lowers one.

Only the packages the run was asked for are judged: a run of `timerKit` also
executes some of `registry`, but not `registry`'s own specs, so `registry`'s
partial figure is shown without a floor verdict. A run of every target also
fails when a floor names a package that was not measured at all.

Exit status: 0 when every spec passed and every judged package met its floor;
1 when a spec failed, a package is below or without a floor, or `luacov` wrote
no report; 2 when the floors file is unreadable or a target is unknown; 127
when Busted or `luacov` is not installed.
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

from tooling.test import run as test_run


ROOT = test_run.ROOT

#: What LuaCov writes, named in the root `.luacov`.
STATS_FILE = ROOT / "luacov.stats.out"
REPORT_FILE = ROOT / "luacov.report.out"

#: The committed per-package floors: `{"<package>": <whole percent>, ...}`.
FLOORS_FILE = Path(__file__).resolve().with_name("coverage-floors.json")

#: Busted arguments of the coverage run: LuaCov on, allocation specs out.
COVERAGE_BUSTED_ARGS = ("--coverage", f"--exclude-tags={test_run.ALLOCATION_TAG}")

#: One row of the report's summary: `<path> <hits> <missed> <percent>%`.
SUMMARY_ROW_RE = re.compile(r"^(?P<path>\S+)\s+(?P<hits>\d+)\s+(?P<missed>\d+)\s+[0-9.]+%$")

#: The package a measured file belongs to.
PACKAGE_SOURCE_RE = re.compile(r"(?:^|/)packages/(?P<package>[^/]+)/src/")

MISSING_LUACOV_MESSAGE = """\
error: luacov was not found on PATH.

Install it into the same Lua 5.1 tree as Busted:

    luarocks install luacov 0.17.0-1

See docs/DEVELOPMENT.md for the full toolchain.\
"""


class PackageCoverage(NamedTuple):
    """The measured lines of one package's runtime source."""

    package: str
    hits: int
    missed: int

    @property
    def percent(self) -> float:
        """Covered lines as a percentage of measured lines; 0 when nothing was measured."""
        total = self.hits + self.missed
        return 100.0 * self.hits / total if total else 0.0

    @property
    def whole_percent(self) -> int:
        """The percentage rounded down to a whole number, in integer arithmetic.

        This is the value a floor is set to. Integer division keeps a figure
        such as 57 of 57 lines at exactly 100 instead of trusting a float.
        """
        total = self.hits + self.missed
        return 100 * self.hits // total if total else 0

    def meets(self, floor: int) -> bool:
        """Whether the coverage is at or above a whole-percent floor."""
        return 100 * self.hits >= floor * (self.hits + self.missed)


class FloorsError(Exception):
    """The floors file is missing, is not JSON, or holds something other than floors."""


class FloorVerdict(NamedTuple):
    """One judged package's floor check."""

    package: str
    floor: int | None
    passed: bool
    message: str


def load_floors(path: Path) -> dict[str, int]:
    """Read the floors file: a JSON object from package name to a whole percent, 0 to 100.

    A missing file is an error rather than an empty table, so a deleted or
    misnamed file cannot silently turn every package into "no floor".
    """
    try:
        data = json.loads(path.read_text(encoding="utf-8"))
    except FileNotFoundError as error:
        raise FloorsError(f"{path}: the floors file does not exist") from error
    except (OSError, ValueError) as error:
        raise FloorsError(f"{path}: {error}") from error
    if not isinstance(data, dict):
        raise FloorsError(f"{path}: expected a JSON object from package name to percent")
    floors: dict[str, int] = {}
    for package, floor in data.items():
        # `bool` is an `int` in Python; `true` is not a percentage.
        if isinstance(floor, bool) or not isinstance(floor, int) or not 0 <= floor <= 100:
            raise FloorsError(f'{path}: the floor of "{package}" must be a whole number from 0 to 100')
        floors[package] = floor
    return floors


def write_floors(path: Path, floors: dict[str, int]) -> None:
    """Write the floors sorted by package, one per line, as the committed file is."""
    ordered = {package: floors[package] for package in sorted(floors)}
    path.write_text(json.dumps(ordered, indent=2) + "\n", encoding="utf-8")


def judged_packages(rows: Sequence[PackageCoverage], requested: Sequence[str]) -> list[PackageCoverage]:
    """The rows whose floor the run decides: every row on a full run, else the requested packages."""
    if not requested:
        return list(rows)
    wanted = set(requested)
    return [row for row in rows if row.package in wanted]


def check_floors(
    rows: Sequence[PackageCoverage], floors: dict[str, int], full_run: bool
) -> list[FloorVerdict]:
    """Compare each judged row with its floor.

    A row without a floor fails: a new package has to be given one, with
    `--update-floors`, before it can merge. On a full run, a floor whose
    package produced no row fails too, because it would otherwise never be
    checked again.
    """
    verdicts: list[FloorVerdict] = []
    for row in rows:
        floor = floors.get(row.package)
        if floor is None:
            verdicts.append(
                FloorVerdict(row.package, None, False, f"{row.package}: no coverage floor")
            )
        elif not row.meets(floor):
            verdicts.append(
                FloorVerdict(
                    row.package,
                    floor,
                    False,
                    f"{row.package}: {row.percent:.1f}% is below its floor of {floor}%",
                )
            )
        else:
            verdicts.append(FloorVerdict(row.package, floor, True, ""))
    if full_run:
        measured = {row.package for row in rows}
        for package in sorted(set(floors) - measured):
            verdicts.append(
                FloorVerdict(
                    package,
                    floors[package],
                    False,
                    f"{package}: has a floor but no line of it was measured",
                )
            )
    return verdicts


def ratchet_floors(floors: dict[str, int], rows: Sequence[PackageCoverage]) -> dict[str, int]:
    """Return the floors raised to each row's whole percentage; none is lowered.

    A package without a floor gets its measured value. Packages without a row
    keep their floor unchanged.
    """
    raised = dict(floors)
    for row in rows:
        raised[row.package] = max(raised.get(row.package, 0), row.whole_percent)
    return raised


def parse_report(text: str) -> list[PackageCoverage]:
    """Sum the report's per-file summary rows into one row per package, sorted by package.

    Only rows under the final `Summary` heading are read, and only files under
    `packages/<id>/src/`; the total row and anything else are skipped.
    """
    _, separator, summary = text.rpartition("\nSummary\n")
    if not separator:
        return []
    totals: dict[str, list[int]] = {}
    for line in summary.splitlines():
        row = SUMMARY_ROW_RE.match(line.strip())
        if row is None:
            continue
        source = PACKAGE_SOURCE_RE.search(row.group("path").replace("\\", "/"))
        if source is None:
            continue
        counts = totals.setdefault(source.group("package"), [0, 0])
        counts[0] += int(row.group("hits"))
        counts[1] += int(row.group("missed"))
    return [PackageCoverage(name, hits, missed) for name, (hits, missed) in sorted(totals.items())]


def floor_cell(row: PackageCoverage, floors: dict[str, int], judged: set[str]) -> str:
    """The floor column of one row: the floor and, when it failed, why.

    A row the run does not judge shows its floor with "not judged", so a
    partial figure is never read as a verdict.
    """
    floor = floors.get(row.package)
    if row.package not in judged:
        return "not judged" if floor is None else f"{floor}% (not judged)"
    if floor is None:
        return "**missing**"
    if not row.meets(floor):
        return f"{floor}% **below**"
    return f"{floor}%"


def render_markdown(
    rows: Sequence[PackageCoverage],
    tests_passed: bool,
    floors: dict[str, int] | None = None,
    judged: set[str] | None = None,
    failures: Sequence[str] = (),
) -> str:
    """The job summary: one row per package with its floor, the total and the verdict."""
    floors = floors or {}
    judged = {row.package for row in rows} if judged is None else judged
    lines = [
        "## Line coverage of `packages/*/src`",
        "",
        "| Package | Lines hit | Lines missed | Coverage | Floor |",
        "|---|---:|---:|---:|---:|",
    ]
    for row in rows:
        lines.append(
            f"| `{row.package}` | {row.hits} | {row.missed} | {row.percent:.1f}% "
            f"| {floor_cell(row, floors, judged)} |"
        )
    total = PackageCoverage(
        "total", sum(row.hits for row in rows), sum(row.missed for row in rows)
    )
    lines.append(f"| **total** | {total.hits} | {total.missed} | {total.percent:.1f}% | |")
    lines.append("")
    if tests_passed:
        lines.append("Every spec passed under coverage (allocation specs excluded).")
    else:
        lines.append(
            "Some specs failed under coverage. Allocation specs are excluded by their "
            "`#allocation` tag, so every failure here is a real one."
        )
    if failures:
        lines.append("")
        lines.append("Coverage floors not met:")
        lines.append("")
        lines.extend(f"- {message}" for message in failures)
    elif tests_passed:
        lines.append("")
        lines.append("Every judged package meets its coverage floor.")
    return "\n".join(lines) + "\n"


def merge_statistics(text: str, root: Path) -> str:
    """Merge the statistics of one source file recorded under two spellings.

    A suite reaches a package source both through `require`, which records the
    relative `LUA_PATH` spelling (`packages/registry/src/Registry.lua`), and
    through its test environment's reload, which records the absolute path.
    LuaCov keeps the two apart and would report each half on its own, so the
    hit counts are summed line by line under the absolute path before the
    report is written. Every path is resolved, so the merged file names each
    source once, by its real absolute path.

    The file holds, per source file, a `<line count>:<path>` line followed by
    one line of space-separated hit counts.
    """
    merged: dict[str, list[int]] = {}
    lines = text.splitlines()
    for header, counts in zip(lines[0::2], lines[1::2]):
        _, _, name = header.partition(":")
        # Joining an absolute path to the root keeps it as it is; resolving
        # both spellings removes any symbolic link, so they meet on one key.
        key = str((root / name).resolve())
        hits = [int(value) for value in counts.split()]
        total = merged.setdefault(key, [])
        if len(total) < len(hits):
            total.extend([0] * (len(hits) - len(total)))
        for index, value in enumerate(hits):
            total[index] += value
    return "".join(
        f"{len(hits)}:{name}\n{' '.join(str(value) for value in hits)}\n"
        for name, hits in merged.items()
    )


def remove_previous_output() -> None:
    """Delete the statistics and report of an earlier run.

    LuaCov adds to an existing statistics file, which is how the separate
    Busted process of every suite ends up in one report; a file left from an
    earlier run would be added in too.
    """
    for path in (STATS_FILE, REPORT_FILE):
        path.unlink(missing_ok=True)


def run(
    package_names: Sequence[str],
    summary_path: str | None,
    update_floors: bool = False,
    floors_path: Path | None = None,
) -> int:
    """Run the suites under LuaCov, print the per-package table and judge the floors."""
    floors_path = FLOORS_FILE if floors_path is None else floors_path
    try:
        floors = load_floors(floors_path)
    except FloorsError as error:
        print(f"error: {error}", file=sys.stderr)
        return 2

    luacov = shutil.which("luacov")
    if luacov is None:
        print(MISSING_LUACOV_MESSAGE, file=sys.stderr)
        return 127

    remove_previous_output()
    suite_status = test_run.run(package_names, list(COVERAGE_BUSTED_ARGS))
    if suite_status in (2, 127):
        return suite_status

    if STATS_FILE.is_file():
        STATS_FILE.write_text(
            merge_statistics(STATS_FILE.read_text(encoding="utf-8"), ROOT), encoding="utf-8"
        )
    if subprocess.run([luacov], cwd=ROOT, check=False).returncode != 0 or not REPORT_FILE.is_file():
        print("error: luacov did not write luacov.report.out", file=sys.stderr)
        return 1

    rows = parse_report(REPORT_FILE.read_text(encoding="utf-8"))
    if not rows:
        print("error: luacov.report.out has no package rows in its summary", file=sys.stderr)
        return 1

    tests_passed = suite_status == 0
    judged = judged_packages(rows, package_names)
    if update_floors:
        if not tests_passed:
            print("error: floors are not updated from a run with failing specs", file=sys.stderr)
        else:
            raised = ratchet_floors(floors, judged)
            if raised != floors:
                write_floors(floors_path, raised)
                print(f"updated {floors_path.name}")
            floors = raised

    verdicts = check_floors(judged, floors, full_run=not package_names)
    failures = [verdict.message for verdict in verdicts if not verdict.passed]
    markdown = render_markdown(
        rows, tests_passed, floors, {row.package for row in judged}, failures
    )
    print()
    print(markdown, end="")
    if summary_path:
        with open(summary_path, "a", encoding="utf-8") as handle:
            handle.write(markdown)

    for message in failures:
        print(f"error: {message}", file=sys.stderr)
    if failures and not update_floors:
        print(
            "Add a spec that exercises the missed lines, or, for a new package, "
            "run with --update-floors and commit the floors file.",
            file=sys.stderr,
        )
    return 0 if tests_passed and not failures else 1


def parse_args(argv: Sequence[str] | None = None) -> argparse.Namespace:
    """Parse the command line."""
    parser = argparse.ArgumentParser(
        prog="python3 -m tooling.test.coverage",
        description=(
            "Run the test suites under LuaCov, allocation specs excluded, report line "
            "coverage of each package's runtime source and fail below a package's floor."
        ),
    )
    parser.add_argument(
        "packages",
        nargs="*",
        help='test targets, as for tooling.test.run; omitted means every package and "examples"',
    )
    parser.add_argument(
        "--summary",
        metavar="FILE",
        help="also append the Markdown table to FILE (the CI job summary)",
    )
    parser.add_argument(
        "--update-floors",
        action="store_true",
        help=(
            "raise each judged package's floor in tooling/test/coverage-floors.json to its "
            "measured coverage rounded down, add missing packages; never lowers a floor"
        ),
    )
    return parser.parse_args(argv)


def main(argv: Sequence[str] | None = None) -> int:
    """Entry point for `python3 -m tooling.test.coverage`."""
    arguments = parse_args(argv)
    return run(arguments.packages, arguments.summary, arguments.update_floors)


if __name__ == "__main__":
    raise SystemExit(main())
