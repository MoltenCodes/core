"""One client session per flavour: prepare the game folder, collect the results, clean up.

    python3 -m tooling.client.session prepare --wow-dir DIR [--flavour-dir NAME] [--packages ID,...]
    python3 -m tooling.client.session collect --wow-dir DIR [--flavour-dir NAME]
    python3 -m tooling.client.session clean   --wow-dir DIR [--flavour-dir NAME] [--force]

The real-client suites (`tests/client/`) prove what the fake client can only
model, and a session is the evening it takes to run them on one flavour.
This command is a thin layer over `tooling.client.install` and
`tooling.client.report`:

* `prepare` installs the bundle, the harness and every package's test addon
  (`install --all`, or the named packages), then prints and writes a session
  sheet to `<wow-dir>/<flavour-dir>/MoltenCodesTest-session.txt`: the lines to
  type in the game in order, the preconditions each `EXPECTED.md` names (its
  "Combat run", "The procedure" and "Per flavour" sections, and any "Before
  the run" paragraph), the interactive suites the guided pass will show, and
  the totals each package expects, read from each `EXPECTED.md`'s totals line.
* `collect` merges the flavour's saved results into `tests/client/results.json`
  (`tooling.client.report`), then prints, per package, the expected totals
  against the recorded ones: "as expected", "differs" or "not run". A
  difference is reported, never fatal: the expected totals are Retail's, and
  the "Per flavour" notes are prose. It also writes a marker naming the
  installation it collected, which `clean` requires.
* `clean` removes the installation (`install --remove`), the sheet and the
  marker. It refuses while the installed `Expected.lua` names an installation
  `collect` has not recorded, so results are never deleted before they are
  saved; `--force` overrides and says what is lost.

tests/client/README.md, "A session per flavour", is the walk-through.
"""

from __future__ import annotations

import argparse
import re
import sys
from dataclasses import dataclass
from pathlib import Path
from typing import Callable, Sequence

from tooling.client import install, report
from tooling.client.flavours import CLIENT_FLAVOURS, DEFAULT_FLAVOUR_DIRECTORY
from tooling.validation.validate_manifests import load_manifests

#: The session sheet, written into the flavour folder.
SHEET_NAME = "MoltenCodesTest-session.txt"

#: The marker `collect` writes and `clean` reads, in the flavour folder.
COLLECTED_NAME = "MoltenCodesTest-collected.txt"

#: The harness's totals line, as each `EXPECTED.md` quotes it.
TOTALS_RE = re.compile(
    r"MoltenCodes Test: (?P<package>[A-Za-z0-9]+): (?P<passed>\d+) passed, (?P<failed>\d+) failed, "
    r"(?P<skipped>\d+) skipped, (?P<timeout>\d+) timed out \((?P<tests>\d+) tests\)"
)

#: The `EXPECTED.md` sections whose first paragraph the sheet copies.
PRECONDITION_HEADINGS = ("Combat run", "The procedure", "Per flavour")

#: A suite registered with an instruction for the guided pass, directly
#: (`Harness:Suite(PACKAGE_ID, "part", addonName, {...})`) or through a suite
#: file's own `newSuite("part", {...})` wrapper.
INTERACTIVE_RE = re.compile(
    r'(?:Suite\(\s*PACKAGE_ID,\s*|newSuite\(\s*)"(?P<part>[a-z][A-Za-z0-9]*)"'
    r'[^)]*?interactive\s*=\s*"(?P<text>[^"]+)"',
    re.DOTALL,
)

#: `installedAt = "..."` in the installed `Expected.lua`.
INSTALLED_AT_RE = re.compile(r'installedAt\s*=\s*"(?P<value>[^"]+)"')

#: The lines a session types, in order, with what each does.
SESSION_STEPS = (
    ("/mct run all", "every suite that needs neither you nor combat; wait for 'session pass done'"),
    ("/mct run guided", "each interactive suite: read the instruction, act, then /mct next"),
    ("/mct run combat", "stand at a training dummy first (a low-level creature on Classic Era)"),
    ("/reload", "writes the results; settingsKit's second run follows"),
    ("/mct run settingsKit", "run 2 of settingsKit's persistence procedure"),
    ("/reload", "writes the results again; then run collect"),
)


class SessionError(Exception):
    """The command cannot proceed; the message says why and what to do."""


@dataclass(frozen=True)
class Expected:
    """What one package's `EXPECTED.md` says a run shows."""

    package: str
    tests: int
    passed: int
    failed: int
    skipped: int
    timeout: int
    preconditions: tuple[str, ...]
    interactive: tuple[str, ...]

    def totals(self) -> tuple[int, int, int, int, int]:
        """Tests, passed, failed, skipped, timed out."""
        return (self.tests, self.passed, self.failed, self.skipped, self.timeout)


# Reading the suites ------------------------------------------------------------------


def first_paragraph(text: str, heading: str) -> str | None:
    """The first paragraph of a `## <heading...>` section, joined on one line."""
    match = re.search(rf"^## {re.escape(heading)}[^\n]*\n+(?P<body>.*?)(?:\n\n|\Z)", text, re.M | re.S)
    if match is None:
        return None
    return " ".join(line.strip() for line in match.group("body").splitlines())


def read_expected(package: str, suite_dir: Path) -> Expected | None:
    """Read one suite's `EXPECTED.md` and its interactive registrations, or `None`."""
    expected_path = suite_dir / "EXPECTED.md"
    if not expected_path.is_file():
        return None
    text = expected_path.read_text(encoding="utf-8")
    totals = TOTALS_RE.search(text)
    if totals is None:
        return None
    preconditions: list[str] = []
    before = re.search(r"\*\*Before the run\.\*\*(?P<body>.*?)(?:\n\n|\Z)", text, re.S)
    if before is not None:
        preconditions.append(
            "Before the run: " + " ".join(line.strip() for line in before.group("body").splitlines()).strip()
        )
    for heading in PRECONDITION_HEADINGS:
        paragraph = first_paragraph(text, heading)
        if paragraph:
            preconditions.append(f"{heading}: {paragraph}")
    interactive: list[str] = []
    for suite_file in sorted(suite_dir.glob("*.lua")):
        for match in INTERACTIVE_RE.finditer(suite_file.read_text(encoding="utf-8")):
            interactive.append(f"{package}.{match.group('part')}: {match.group('text')}")
    return Expected(
        package=package,
        tests=int(totals.group("tests")),
        passed=int(totals.group("passed")),
        failed=int(totals.group("failed")),
        skipped=int(totals.group("skipped")),
        timeout=int(totals.group("timeout")),
        preconditions=tuple(preconditions),
        interactive=tuple(interactive),
    )


def expected_by_package(
    packages: Sequence[str] | None = None, client_tests: Path = install.CLIENT_TESTS
) -> dict[str, Expected]:
    """Every installed package's expectations, by package ID."""
    manifests, errors = load_manifests()
    if errors:
        raise SessionError("package manifests are invalid: " + "; ".join(errors))
    chosen = packages if packages is not None else install.available_test_packages(manifests)
    found: dict[str, Expected] = {}
    for package in chosen:
        expected = read_expected(package, client_tests / install.test_addon_name(package, manifests))
        if expected is not None:
            found[package] = expected
    return found


# The sheet ------------------------------------------------------------------------------


def render_sheet(expectations: dict[str, Expected], flavour_directory: str) -> str:
    """The session sheet: steps, preconditions, interactive suites and expected totals."""
    lines = [
        f"MoltenCodes client session for {flavour_directory}",
        "",
        "Type these lines in the game, in this order:",
    ]
    for number, (line, note) in enumerate(SESSION_STEPS, start=1):
        lines.append(f"  {number}. {line:<22} {note}")
    lines += ["", "Preconditions named by the suites:"]
    preconditions = [
        (package, text) for package, expected in expectations.items() for text in expected.preconditions
    ]
    lines += [f"  - {package}: {text}" for package, text in preconditions] or ["  - none"]
    lines += ["", "Interactive suites the guided pass shows:"]
    interactive = [item for expected in expectations.values() for item in expected.interactive]
    lines += [f"  - {item}" for item in interactive] or [
        "  - none tagged yet; their suites run in /mct run all and wait for their timeout"
    ]
    lines += ["", "Expected totals (Retail; see each EXPECTED.md's Per flavour notes elsewhere):"]
    for package, expected in expectations.items():
        lines.append(
            f"  {package}: {expected.passed} passed, {expected.failed} failed, {expected.skipped} "
            f"skipped, {expected.timeout} timed out ({expected.tests} tests)"
        )
    lines += [
        "",
        "Afterwards: python3 -m tooling.client.session collect, then clean.",
        "",
    ]
    return "\n".join(lines)


# Comparing --------------------------------------------------------------------------------


def flavour_id(flavour_directory: str) -> str:
    """The flavour ID a flavour folder holds, `_retail_` -> `retail`."""
    for flavour in CLIENT_FLAVOURS:
        if flavour.directory == flavour_directory:
            return flavour.flavour_id
    raise SessionError(f"unknown flavour folder {flavour_directory!r}")


def recorded_totals(rows: Sequence[report.Row], flavour: str, package: str) -> tuple[int, ...] | None:
    """A package's recorded totals: its default run, else its unattended and guided runs summed."""
    by_mode = {row.mode: row for row in rows if row.flavour == flavour and row.package == package}
    if "default" in by_mode:
        chosen = [by_mode["default"]]
    else:
        chosen = [by_mode[mode] for mode in ("unattended", "guided") if mode in by_mode]
    if not chosen:
        return None
    fields = ("tests", "passed", "failed", "skipped", "timeout")
    return tuple(sum(getattr(row, field) for row in chosen) for field in fields)


def compare(expectations: dict[str, Expected], rows: Sequence[report.Row], flavour: str) -> list[str]:
    """One line per package: as expected, differs (with both totals) or not run."""
    lines: list[str] = []
    for package, expected in expectations.items():
        recorded = recorded_totals(rows, flavour, package)
        if recorded is None:
            lines.append(f"{package}: not run")
        elif recorded == expected.totals():
            lines.append(f"{package}: as expected ({expected.tests} tests)")
        else:
            lines.append(
                f"{package}: differs: expected {format_totals(expected.totals())}, "
                f"recorded {format_totals(recorded)}"
            )
    return lines


def format_totals(totals: Sequence[int]) -> str:
    """`5 tests: 4 passed, 0 failed, 1 skipped, 0 timed out`."""
    tests, passed, failed, skipped, timeout = totals
    return f"{tests} tests: {passed} passed, {failed} failed, {skipped} skipped, {timeout} timed out"


# Commands -----------------------------------------------------------------------------------


def installed_at(layout: install.ClientLayout) -> str | None:
    """The installation time the installed `Expected.lua` records, or `None`."""
    path = layout.addons_dir / install.HARNESS_ADDON / install.EXPECTED_FILE_NAME
    if not path.is_file():
        return None
    match = INSTALLED_AT_RE.search(path.read_text(encoding="utf-8"))
    return match.group("value") if match else None


def prepare(
    layout: install.ClientLayout,
    packages: Sequence[str] | None,
    dry_run: bool = False,
    say: Callable[[str], None] = print,
) -> str:
    """Install everything for a session and write the sheet; return the sheet."""
    try:
        install.install(layout, packages, dry_run=dry_run, report=say)
    except install.InstallError as failure:
        raise SessionError(str(failure)) from failure
    sheet = render_sheet(expected_by_package(packages), layout.flavour_dir.name)
    if dry_run:
        say(f"would write {layout.flavour_dir / SHEET_NAME}")
    else:
        (layout.flavour_dir / SHEET_NAME).write_text(sheet, encoding="utf-8")
        say(f"wrote {layout.flavour_dir / SHEET_NAME}")
    say("")
    say(sheet)
    return sheet


def collect(
    layout: install.ClientLayout,
    results: Path = report.DEFAULT_RESULTS_PATH,
    say: Callable[[str], None] = print,
) -> list[str]:
    """Record the flavour's saved results and compare them with the expectations."""
    status = report.main(
        [
            "--wow-dir",
            str(layout.wow_dir),
            "--flavour-dir",
            layout.flavour_dir.name,
            "--results",
            str(results),
            "--matrix",
            str(results.with_name("RESULTS.md")),
        ]
    )
    if status != 0:
        raise SessionError("tooling.client.report could not record the results; see its message")
    rows = report.load_results(results).rows
    lines = compare(expected_by_package(), rows, flavour_id(layout.flavour_dir.name))
    for line in lines:
        say(line)
    stamp = installed_at(layout)
    if stamp is not None:
        (layout.flavour_dir / COLLECTED_NAME).write_text(stamp + "\n", encoding="utf-8")
    return lines


def clean(
    layout: install.ClientLayout,
    force: bool = False,
    dry_run: bool = False,
    say: Callable[[str], None] = print,
) -> None:
    """Remove the installation, refusing while its results are not collected."""
    stamp = installed_at(layout)
    marker = layout.flavour_dir / COLLECTED_NAME
    collected = marker.read_text(encoding="utf-8").strip() if marker.is_file() else None
    if stamp is not None and stamp != collected:
        if not force:
            raise SessionError(
                f"the installation of {stamp} has not been collected; run "
                "python3 -m tooling.client.session collect first, or pass --force to delete "
                "its saved results unrecorded"
            )
        say(f"--force: the results of the installation of {stamp} are deleted unrecorded")
    try:
        install.remove(layout, dry_run=dry_run, report=say)
    except install.InstallError as failure:
        raise SessionError(str(failure)) from failure
    for path in (layout.flavour_dir / SHEET_NAME, marker):
        if path.exists():
            if dry_run:
                say(f"would remove {path}")
            else:
                path.unlink()
                say(f"removed {path}")


def parse_args(argv: Sequence[str] | None = None) -> argparse.Namespace:
    """Read the command line."""
    parser = argparse.ArgumentParser(
        prog="python3 -m tooling.client.session",
        description=(
            "Prepare a real-client session, collect its results and clean up. "
            "See tests/client/README.md."
        ),
    )
    parser.add_argument("action", choices=("prepare", "collect", "clean"))
    parser.add_argument("--wow-dir", required=True, metavar="DIR", help="the game folder")
    parser.add_argument(
        "--flavour-dir",
        default=DEFAULT_FLAVOUR_DIRECTORY,
        metavar="NAME",
        help=f"the flavour folder inside it (default: {DEFAULT_FLAVOUR_DIRECTORY})",
    )
    parser.add_argument(
        "--packages",
        metavar="ID,...",
        help="prepare: only these packages' test addons (default: every package with one)",
    )
    parser.add_argument("--force", action="store_true", help="clean: even when nothing was collected")
    parser.add_argument("--dry-run", action="store_true", help="prepare, clean: change nothing")
    return parser.parse_args(argv)


def main(argv: Sequence[str] | None = None) -> int:
    """Run the command; return the process exit status."""
    arguments = parse_args(argv)
    try:
        layout = install.resolve_layout(Path(arguments.wow_dir), arguments.flavour_dir)
        if arguments.action == "prepare":
            packages = (
                [item.strip() for item in arguments.packages.split(",") if item.strip()]
                if arguments.packages
                else None
            )
            prepare(layout, packages, dry_run=arguments.dry_run)
        elif arguments.action == "collect":
            collect(layout)
        else:
            clean(layout, force=arguments.force, dry_run=arguments.dry_run)
    except (SessionError, install.InstallError) as failure:
        print(f"error: {failure}", file=sys.stderr)
        return 1
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
