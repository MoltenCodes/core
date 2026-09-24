"""Measure line coverage of the runtime packages with LuaCov.

    python3 -m tooling.test.coverage
    python3 -m tooling.test.coverage timerKit logKit
    python3 -m tooling.test.coverage --summary "$GITHUB_STEP_SUMMARY"

This runs `python3 -m tooling.test.run` with Busted's `--coverage` flag, so
every suite keeps its own process and `LUA_PATH`, merges the statistics a
source file collected under its relative and its absolute spelling, then runs
`luacov` to turn them into `luacov.report.out`. The root `.luacov` limits
the report to `packages/*/src/`: specs and test support are not measured.
Both output files are written at the repository root and ignored by Git.

The figure is a report, not a gate. LuaCov's line hook allocates on every
line, so the allocation specs, which assert that a hot path allocates
nothing, fail while it is active; the suite's result is therefore printed
but does not decide the exit status. `python3 -m tooling.test.run` without
coverage is the test gate.

Exit status: 0 when a report was produced, 1 when `luacov` failed or wrote no
summary, 127 when Busted or `luacov` is not installed.
"""

from __future__ import annotations

import argparse
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


def render_markdown(rows: Sequence[PackageCoverage], tests_passed: bool) -> str:
    """The job summary: one row per package and the total."""
    lines = [
        "## Line coverage of `packages/*/src`",
        "",
        "| Package | Lines hit | Lines missed | Coverage |",
        "|---|---:|---:|---:|",
    ]
    for row in rows:
        lines.append(f"| `{row.package}` | {row.hits} | {row.missed} | {row.percent:.1f}% |")
    total = PackageCoverage(
        "total", sum(row.hits for row in rows), sum(row.missed for row in rows)
    )
    lines.append(f"| **total** | {total.hits} | {total.missed} | {total.percent:.1f}% |")
    lines.append("")
    if tests_passed:
        lines.append("Every suite passed under coverage.")
    else:
        lines.append(
            "Some specs failed under coverage. The allocation specs do by design, because "
            "LuaCov's line hook allocates; the `test` job is the gate for the suite itself."
        )
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


def run(package_names: Sequence[str], summary_path: str | None) -> int:
    """Run the suites under LuaCov, write the report and print the per-package table."""
    luacov = shutil.which("luacov")
    if luacov is None:
        print(MISSING_LUACOV_MESSAGE, file=sys.stderr)
        return 127

    remove_previous_output()
    suite_status = test_run.run(package_names, ["--coverage"])
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

    markdown = render_markdown(rows, tests_passed=suite_status == 0)
    print()
    print(markdown, end="")
    if summary_path:
        with open(summary_path, "a", encoding="utf-8") as handle:
            handle.write(markdown)
    return 0


def parse_args(argv: Sequence[str] | None = None) -> argparse.Namespace:
    """Parse the command line."""
    parser = argparse.ArgumentParser(
        prog="python3 -m tooling.test.coverage",
        description=(
            "Run the test suites under LuaCov and report line coverage of each "
            "package's runtime source."
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
    return parser.parse_args(argv)


def main(argv: Sequence[str] | None = None) -> int:
    """Entry point for `python3 -m tooling.test.coverage`."""
    arguments = parse_args(argv)
    return run(arguments.packages, arguments.summary)


if __name__ == "__main__":
    raise SystemExit(main())
