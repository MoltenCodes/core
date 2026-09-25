"""Turn the harness's saved results into the committed real-client result matrix.

The harness (``tests/client/MoltenCodesTest/Harness.lua``) saves each package's
latest run in ``MoltenCodesTestResults``, which the client writes to
``<wow>/<flavour>/WTF/Account/<account>/SavedVariables/MoltenCodesTest.lua``.
This command reads those files, read-only, from one or more flavour folders,
merges their runs into the committed record ``tests/client/results.json`` and
renders ``tests/client/RESULTS.md`` from it:

    python3 -m tooling.client.report --wow-dir "/Applications/World of Warcraft"
    python3 -m tooling.client.report --wow-dir DIR --flavour-dir _classic_era_
    python3 -m tooling.client.report --saved-variables path/to/MoltenCodesTest.lua
    python3 -m tooling.client.report --wow-dir DIR --dry-run
    python3 -m tooling.client.report --check
    python3 -m tooling.client.report --unavailable "classic-era=no active game time"
    python3 -m tooling.client.report --available classic-era

``results.json`` is the one source of truth: one row per flavour, package and
run mode (the default run, or a combat run), each with its totals, the client
it ran on, the date and the commit the installer recorded. A run from the
files replaces the recorded row of the same flavour, package and mode unless
the recorded row is newer; every other row is kept with its own date and
commit, so a session that ran four packages updates four rows and leaves the
rest as they were. ``results.json`` also records, per flavour, why no
session of it can run for now (``--unavailable``), so the matrix says "not
run" with the reason instead of leaving the flavour blank; a recorded run of
that flavour, or ``--available``, clears it. ``RESULTS.md`` is generated from
it and never edited by hand. ``--check`` changes nothing and fails when either
file differs from what the command would write, which is what CI can run;
``--dry-run`` prints what would change and writes nothing.

The flavour of a run is what the client reported (``WOW_PROJECT_ID``), not
the folder the file was found in. A run on a test build (``client.testBuild``)
or installed into a folder that is not a known flavour (a ``_ptr_`` folder) is
reported and left out: the matrix is about live clients. See
``tests/client/README.md``, "Result matrix", and ``docs/TOOLING.md``,
"Real-client results".
"""

from __future__ import annotations

import argparse
import json
import re
import sys
from dataclasses import dataclass, field
from pathlib import Path
from typing import Any, Callable, Sequence

from tooling.client.flavours import (
    CLIENT_FLAVOURS,
    PROMISED_FLAVOURS,
    ClientFlavour,
    flavour_by_directory,
    flavour_by_id,
    flavour_by_project_id,
)
from tooling.client.saved_variables import SavedVariablesError, as_list, parse_saved_variables
from tooling.validation.validate_manifests import ROOT


#: The committed record every matrix is rendered from.
DEFAULT_RESULTS_PATH = ROOT / "tests" / "client" / "results.json"

#: The rendered matrix.
DEFAULT_MATRIX_PATH = ROOT / "tests" / "client" / "RESULTS.md"

#: Where the test addons live, for the combat-suite scan and the links.
CLIENT_TESTS = ROOT / "tests" / "client"

#: The harness's saved-variables file and the global it assigns.
SAVED_VARIABLES_FILE_NAME = "MoltenCodesTest.lua"
SAVED_VARIABLES_GLOBAL = "MoltenCodesTestResults"

#: The account-wide saved-variables folders under a flavour folder. The
#: harness's variable is account-wide (``## SavedVariables``), so the
#: per-character folders never hold it.
SAVED_VARIABLES_PATTERN = "WTF/Account/*/SavedVariables/" + SAVED_VARIABLES_FILE_NAME

#: The layout version of ``results.json``.
RESULTS_SCHEMA = 1

#: Longest reason ``--unavailable`` accepts; the matrix prints it in a cell.
MAX_UNAVAILABLE_REASON = 200

#: The harness entry schemas this command reads.
SUPPORTED_ENTRY_SCHEMAS = (1, 2)

#: The run modes, in the order rows of one package are listed.
RUN_MODES = ("default", "combat")

#: The suffix of a combat run's key in ``MoltenCodesTestResults``.
COMBAT_KEY_SUFFIX = ":combat"

#: The totals every row carries, in matrix column order.
TOTAL_FIELDS = ("tests", "passed", "failed", "skipped", "timeout")

#: The suite option that makes a combat suite, as a suite file spells it in
#: the options it hands ``Harness:Suite`` (directly or through its
#: ``newSuite`` helper).
COMBAT_OPTION_RE = re.compile(r"\bcombat\s*=\s*true\b")

#: The package ID a test addon's suites use, read from its ``PACKAGE_ID``.
PACKAGE_ID_RE = re.compile(r'^local PACKAGE_ID = "([A-Za-z0-9]+)"', re.M)

#: Conditions no session of the owner can create, so their tests are never
#: exercised whatever the matrix says. Edit this list when a condition becomes
#: available (for example a second account for group runs).
STANDING_GAPS = (
    (
        "Windows client",
        "no run on a Windows client is recorded (the owner's clients run on macOS), so "
        "behaviour only a Windows client shows is unproven",
    ),
    (
        "Group communication with a second character",
        "no second character is available: addon messages between two clients over "
        "party, raid or whisper, and anything that needs a group, are not exercised; "
        "CommKit's round trips whisper to the player's own character instead",
    ),
    (
        "Conditions a solo session cannot create",
        "the skipped tests listed above are not exercised on that flavour; besides a "
        "missing client capability, their reasons name what one session cannot set up: "
        "a logout or /reload in the middle of a run, a line typed or a key pressed by the "
        "player, another addon's LibStub, LibSharedMedia or copy of a Kit, a restricted "
        "encounter, or a forbidden frame",
    ),
)


class ReportError(Exception):
    """The command cannot proceed; the message says why and what to do."""


# Rows ------------------------------------------------------------------------------------


@dataclass
class Row:
    """One package's latest recorded run on one flavour in one mode."""

    flavour: str
    package: str
    mode: str
    tests: int
    passed: int
    failed: int
    skipped: int
    timeout: int
    version: str | None = None
    build: str | None = None
    interface: int | None = None
    locale: str | None = None
    os: str | None = None
    date: str | None = None
    commit: str | None = None
    dirty: bool | None = None
    #: Every skipped test with its reason; ``None`` when the run was recorded
    #: without them (the rows moved from the README before this command).
    skips: list[dict[str, str]] | None = field(default_factory=list)
    #: Every failed or timed-out test with its message.
    problems: list[dict[str, str]] = field(default_factory=list)

    @property
    def key(self) -> tuple[str, str, str]:
        """What identifies the row: flavour, package, mode."""
        return (self.flavour, self.package, self.mode)

    def to_json(self) -> dict[str, Any]:
        """The row as ``results.json`` stores it."""
        return {
            "flavour": self.flavour,
            "package": self.package,
            "mode": self.mode,
            "tests": self.tests,
            "passed": self.passed,
            "failed": self.failed,
            "skipped": self.skipped,
            "timeout": self.timeout,
            "version": self.version,
            "build": self.build,
            "interface": self.interface,
            "locale": self.locale,
            "os": self.os,
            "date": self.date,
            "commit": self.commit,
            "dirty": self.dirty,
            "skips": self.skips,
            "problems": self.problems,
        }


@dataclass
class Record:
    """What ``results.json`` holds: the rows, and why a flavour cannot run for now."""

    rows: list[Row] = field(default_factory=list)
    #: Flavour ID to the reason no session of it can run at the moment.
    unavailable: dict[str, str] = field(default_factory=dict)


def _optional(value: Any, kind: type) -> Any:
    """``value`` when it has type ``kind`` (never a bool for ``int``), else ``None``."""
    if kind is int and isinstance(value, bool):
        return None
    return value if isinstance(value, kind) else None


def _count(value: Any, where: str) -> int:
    """A non-negative integer count, refusing anything else."""
    if not isinstance(value, int) or isinstance(value, bool) or value < 0:
        raise ReportError(f"{where} must be a non-negative integer")
    return value


def _entries(value: Any, where: str) -> list[dict[str, str]]:
    """A list of ``{suite, test, reason|status, message}`` objects of strings."""
    if not isinstance(value, list):
        raise ReportError(f"{where} must be a list")
    entries: list[dict[str, str]] = []
    for index, entry in enumerate(value):
        if not isinstance(entry, dict) or not all(
            isinstance(key, str) and isinstance(text, str) for key, text in entry.items()
        ):
            raise ReportError(f"{where}[{index}] must be an object of strings")
        entries.append(dict(entry))
    return entries


def row_from_json(data: Any, index: int) -> Row:
    """One row of ``results.json``, validated."""
    where = f"rows[{index}]"
    if not isinstance(data, dict):
        raise ReportError(f"{where} must be an object")
    flavour = data.get("flavour")
    if not isinstance(flavour, str) or flavour_by_id(flavour) is None:
        known = ", ".join(item.flavour_id for item in CLIENT_FLAVOURS)
        raise ReportError(f"{where}.flavour must be one of {known}")
    package = data.get("package")
    if not isinstance(package, str) or not package:
        raise ReportError(f"{where}.package must be a package ID")
    mode = data.get("mode")
    if mode not in RUN_MODES:
        raise ReportError(f"{where}.mode must be one of {', '.join(RUN_MODES)}")
    counts = {name: _count(data.get(name), f"{where}.{name}") for name in TOTAL_FIELDS}
    skips = data.get("skips")
    return Row(
        flavour=flavour,
        package=package,
        mode=mode,
        **counts,
        version=_optional(data.get("version"), str),
        build=_optional(data.get("build"), str),
        interface=_optional(data.get("interface"), int),
        locale=_optional(data.get("locale"), str),
        os=_optional(data.get("os"), str),
        date=_optional(data.get("date"), str),
        commit=_optional(data.get("commit"), str),
        dirty=_optional(data.get("dirty"), bool),
        skips=None if skips is None else _entries(skips, f"{where}.skips"),
        problems=_entries(data.get("problems", []), f"{where}.problems"),
    )


def load_results(path: Path) -> Record:
    """What ``results.json`` records; an empty record when the file does not exist yet."""
    if not path.is_file():
        return Record()
    try:
        data = json.loads(path.read_text(encoding="utf-8"))
    except (OSError, json.JSONDecodeError) as failure:
        raise ReportError(f"{path}: {failure}") from failure
    if not isinstance(data, dict) or data.get("schema") != RESULTS_SCHEMA:
        raise ReportError(f"{path}: expected an object with schema {RESULTS_SCHEMA}")
    rows = data.get("rows")
    if not isinstance(rows, list):
        raise ReportError(f"{path}: rows must be a list")
    unavailable = data.get("unavailable", {})
    if not isinstance(unavailable, dict) or not all(
        isinstance(reason, str) and flavour_by_id(str(flavour)) is not None
        for flavour, reason in unavailable.items()
    ):
        raise ReportError(f"{path}: unavailable must map known flavour IDs to reasons")
    try:
        parsed = sort_rows([row_from_json(row, index) for index, row in enumerate(rows)])
    except ReportError as failure:
        raise ReportError(f"{path}: {failure}") from failure
    return Record(parsed, dict(unavailable))


def sort_rows(rows: Sequence[Row]) -> list[Row]:
    """Rows in matrix order: flavour, then package, then default before combat."""
    flavour_order = {flavour.flavour_id: index for index, flavour in enumerate(CLIENT_FLAVOURS)}
    return sorted(
        rows,
        key=lambda row: (
            flavour_order.get(row.flavour, len(flavour_order)),
            row.package.lower(),
            RUN_MODES.index(row.mode),
        ),
    )


def render_results_json(record: Record) -> str:
    """The text of ``results.json``: stable key order, two-space indent, final newline."""
    order = [flavour.flavour_id for flavour in CLIENT_FLAVOURS]
    document = {
        "schema": RESULTS_SCHEMA,
        "unavailable": {
            flavour: record.unavailable[flavour]
            for flavour in order
            if flavour in record.unavailable
        },
        "rows": [row.to_json() for row in sort_rows(record.rows)],
    }
    return json.dumps(document, indent=2, ensure_ascii=False) + "\n"


# Reading saved variables -------------------------------------------------------------------


@dataclass
class SavedRun:
    """A row read from a saved-variables file, and where it came from."""

    row: Row
    source: Path


def find_saved_variables(wow_dir: Path, flavour_directories: Sequence[str]) -> list[Path]:
    """The harness's saved-variables files under each flavour folder, sorted.

    A folder that does not exist is skipped; the caller decides whether that
    is an error. ``.bak`` copies are never read: they hold the run before.
    """
    files: list[Path] = []
    for directory in flavour_directories:
        flavour_dir = wow_dir / directory
        if not flavour_dir.is_dir():
            continue
        files.extend(sorted(flavour_dir.glob(SAVED_VARIABLES_PATTERN)))
    return files


def _test_entries(report: dict[str, Any]) -> tuple[list[dict[str, str]], list[dict[str, str]]]:
    """The skipped tests and the failed or timed-out tests of one package report."""
    skips: list[dict[str, str]] = []
    problems: list[dict[str, str]] = []
    for suite in as_list(report.get("suites")):
        if not isinstance(suite, dict):
            continue
        suite_name = str(suite.get("name", "?"))
        for test in as_list(suite.get("tests")):
            if not isinstance(test, dict):
                continue
            status = test.get("status")
            name = str(test.get("name", "?"))
            message = test.get("message")
            text = message if isinstance(message, str) else ""
            if status == "skipped":
                skips.append({"suite": suite_name, "test": name, "reason": text})
            elif status in ("failed", "timeout"):
                problems.append(
                    {"suite": suite_name, "test": name, "status": str(status), "message": text}
                )
    return skips, problems


def _entry_flavour(entry: dict[str, Any], folder_flavour: ClientFlavour | None) -> ClientFlavour:
    """The flavour of one saved entry: what the client said, else the install folder.

    Schema 1 entries carry ``client.projectId`` only; schema 2 entries also
    carry the installer's flavour folder. The folder the file was found in is
    the last resort.
    """
    client = entry.get("client")
    client = client if isinstance(client, dict) else {}
    flavour = flavour_by_project_id(client.get("projectId"))
    if flavour is not None:
        return flavour
    installation = entry.get("installation")
    if isinstance(installation, dict):
        directory = installation.get("flavourDirectory")
        if isinstance(directory, str) and flavour_by_directory(directory) is not None:
            return flavour_by_directory(directory)  # type: ignore[return-value]
    if folder_flavour is not None:
        return folder_flavour
    raise ReportError(
        f"cannot tell the flavour: projectId {client.get('projectId')!r} is not a covered client"
    )


def row_from_entry(key: Any, entry: Any, folder_flavour: ClientFlavour | None) -> Row:
    """One harness entry of ``MoltenCodesTestResults`` as a row."""
    if not isinstance(entry, dict):
        raise ReportError(f"entry {key!r} is not a table")
    schema = entry.get("schema")
    if schema not in SUPPORTED_ENTRY_SCHEMAS:
        raise ReportError(f"entry {key!r} has schema {schema!r}; this command reads 1 and 2")
    package = entry.get("package")
    if not isinstance(package, str) or not package:
        raise ReportError(f"entry {key!r} names no package")
    mode = entry.get("mode")
    if mode is None:
        mode = "combat" if isinstance(key, str) and key.endswith(COMBAT_KEY_SUFFIX) else "default"
    if mode not in RUN_MODES:
        raise ReportError(f"entry {key!r} has the unknown mode {mode!r}")
    report = entry.get("report")
    totals = report.get("totals") if isinstance(report, dict) else None
    if not isinstance(totals, dict):
        raise ReportError(f"entry {key!r} has no report totals")
    counts = {
        name: _count(totals.get(name), f"entry {key!r} totals.{name}") for name in TOTAL_FIELDS
    }
    skips, problems = _test_entries(report)  # type: ignore[arg-type]

    client = entry.get("client")
    client = client if isinstance(client, dict) else {}
    installation = entry.get("installation")
    installation = installation if isinstance(installation, dict) else {}
    if client.get("testBuild") is True:
        raise ReportError(f"entry {key!r} ran on a test build; the matrix records live clients")
    directory = installation.get("flavourDirectory")
    if isinstance(directory, str) and flavour_by_directory(directory) is None:
        raise ReportError(
            f"entry {key!r} was installed into {directory!r}, which is not a known flavour folder"
        )
    build = client.get("build")
    return Row(
        flavour=_entry_flavour(entry, folder_flavour).flavour_id,
        package=package,
        mode=mode,
        **counts,
        version=_optional(client.get("version"), str),
        build=str(build) if isinstance(build, (str, int)) and not isinstance(build, bool) else None,
        interface=_optional(client.get("interface"), int),
        locale=_optional(client.get("locale"), str),
        os=_optional(client.get("os"), str),
        date=_optional(client.get("date"), str),
        commit=_optional(installation.get("commit"), str),
        dirty=_optional(installation.get("dirty"), bool),
        skips=skips,
        problems=problems,
    )


def read_saved_runs(path: Path, warn: Callable[[str], None]) -> list[SavedRun]:
    """Every run one saved-variables file holds.

    The file is read as bytes, because the client may write bytes that are not
    UTF-8, and parsed without running Lua. An entry that cannot be read is
    reported through ``warn`` and skipped; a file that cannot be parsed at all
    is an error.
    """
    try:
        variables = parse_saved_variables(path.read_bytes())
    except (OSError, SavedVariablesError) as failure:
        raise ReportError(f"{path}: {failure}") from failure
    results = variables.get(SAVED_VARIABLES_GLOBAL)
    if results is None:
        warn(f"{path}: no {SAVED_VARIABLES_GLOBAL}; nothing to read")
        return []
    if isinstance(results, list) and not results:
        return []
    if not isinstance(results, dict):
        raise ReportError(f"{path}: {SAVED_VARIABLES_GLOBAL} is not a table keyed by package")

    folder_flavour = None
    for parent in path.parents:
        folder_flavour = flavour_by_directory(parent.name)
        if folder_flavour is not None:
            break

    runs: list[SavedRun] = []
    for key in sorted(results, key=str):
        try:
            runs.append(SavedRun(row_from_entry(key, results[key], folder_flavour), path))
        except ReportError as failure:
            warn(f"{path}: skipped {failure}")
    return runs


# Merging ------------------------------------------------------------------------------------


def date_order_key(date: str | None) -> str:
    """A sortable form of a row's date: the end of an interval, ``""`` when unknown.

    Rows moved from the README carry an ISO 8601 interval
    (``2026-09-24/2026-09-25``); the client writes ``YYYY-MM-DD HH:MM:SS``.
    """
    if not date:
        return ""
    return date.split("/")[-1]


@dataclass
class MergeOutcome:
    """The merged rows, and one line per row the inputs touched."""

    rows: list[Row]
    lines: list[str]


def describe_row(row: Row) -> str:
    """``retail optionsKit (default): 29 tests, 29 passed, ...`` for the command's output."""
    counts = ", ".join(f"{getattr(row, name)} {name}" for name in TOTAL_FIELDS[1:])
    return f"{row.flavour} {row.package} ({row.mode}): {row.tests} tests, {counts}"


def merge_rows(recorded: Sequence[Row], runs: Sequence[SavedRun]) -> MergeOutcome:
    """Merge the runs into the recorded rows, keeping every row the runs do not replace.

    For one flavour, package and mode the newest run wins: a run replaces the
    recorded row unless that row's date is later, and of two runs in the
    inputs (two accounts, say) the later one is taken.
    """
    merged = {row.key: row for row in recorded}
    lines: list[str] = []
    newest: dict[tuple[str, str, str], SavedRun] = {}
    for run in runs:
        current = newest.get(run.row.key)
        if current is None or date_order_key(run.row.date) >= date_order_key(current.row.date):
            newest[run.row.key] = run
    for key in sorted(newest):
        run = newest[key]
        existing = merged.get(key)
        if existing is not None and date_order_key(existing.date) > date_order_key(run.row.date):
            lines.append(
                f"kept {describe_row(existing)}; the run in {run.source} ({run.row.date}) is older"
            )
            continue
        if existing is not None and existing.to_json() == run.row.to_json():
            lines.append(f"unchanged {describe_row(run.row)}")
            continue
        merged[key] = run.row
        verb = "updated" if existing is not None else "added"
        lines.append(f"{verb} {describe_row(run.row)} from {run.source}")
    return MergeOutcome(sort_rows(merged.values()), lines)


# Rendering ------------------------------------------------------------------------------------


def combat_suite_packages(client_tests: Path = CLIENT_TESTS) -> list[str]:
    """Packages whose test addon registers at least one combat suite, sorted.

    Found by reading each ``MoltenCodesTest_<Facade>/*.lua`` for the suite
    option ``combat = true`` and naming the package by the file's
    ``local PACKAGE_ID``. Only the gaps section uses it, to name the packages
    whose combat run is not recorded yet.
    """
    packages: set[str] = set()
    for path in sorted(client_tests.glob("MoltenCodesTest_*/*.lua")):
        text = path.read_text(encoding="utf-8", errors="replace")
        package_match = PACKAGE_ID_RE.search(text)
        if package_match is None:
            continue
        if COMBAT_OPTION_RE.search(text):
            packages.add(package_match.group(1))
    return sorted(packages)


def cell(text: str) -> str:
    """Text made safe for one Markdown table cell."""
    return " ".join(text.replace("\\", "\\\\").replace("|", "\\|").split())


def describe_commit(row: Row) -> str:
    """The commit cell: short hash, ``(changes)`` for a dirty tree, or ``unknown``."""
    if not row.commit:
        return "unknown"
    suffix = " (changes)" if row.dirty else ""
    if row.dirty is None:
        suffix = " (state unknown)"
    return f"`{row.commit[:12]}`{suffix}"


def describe_build(row: Row) -> str:
    """``12.1.0 (69933)``, or what is known of it."""
    if row.version and row.build:
        return f"{row.version} ({row.build})"
    return row.version or row.build or "unknown"


def package_label(row: Row) -> str:
    """The package column: ``hookKit``, or ``hookKit (combat)`` for a combat run."""
    label = f"`{row.package}`"
    return label if row.mode == "default" else f"{label} (combat)"


def shown_flavours(rows: Sequence[Row]) -> list[ClientFlavour]:
    """The flavours the matrix shows: every promised one, and an optional one with a run."""
    with_rows = {row.flavour for row in rows}
    return [
        flavour
        for flavour in CLIENT_FLAVOURS
        if flavour.promised or flavour.flavour_id in with_rows
    ]


def flavour_status(flavour: ClientFlavour, rows: Sequence[Row], unavailable: dict[str, str]) -> str:
    """One flavour's line in the status table: what is recorded, or why nothing is."""
    flavour_rows = [row for row in rows if row.flavour == flavour.flavour_id]
    promise = "" if flavour.promised else "optional (not promised); "
    if flavour_rows:
        packages = {row.package for row in flavour_rows}
        latest = max((row.date or "" for row in flavour_rows), key=date_order_key)
        noun = "package" if len(packages) == 1 else "packages"
        return f"{promise}{len(packages)} {noun} recorded, latest {latest or 'unknown'}"
    reason = unavailable.get(flavour.flavour_id)
    if reason:
        return f"{promise}not run ({cell(reason)})"
    return f"{promise}not run yet"


def render_status_table(rows: Sequence[Row], unavailable: dict[str, str]) -> list[str]:
    """Every known flavour, its folder and whether anything is recorded for it."""
    lines = ["| Flavour | Folder | Status |", "|---|---|---|"]
    for flavour in CLIENT_FLAVOURS:
        lines.append(
            f"| {flavour.display_name} | `{flavour.directory}` | "
            f"{flavour_status(flavour, rows, unavailable)} |"
        )
    return lines


def render_matrix_table(rows: Sequence[Row]) -> list[str]:
    """The matrix: one line per package and mode, one column group per shown flavour."""
    flavours = shown_flavours(rows)
    header = ["Package"]
    divider = ["---"]
    for flavour in flavours:
        header += [f"{flavour.display_name} tests", "passed", "failed", "skipped", "timeout"]
        divider += ["---:"] * len(TOTAL_FIELDS)
    lines = ["| " + " | ".join(header) + " |", "|" + "|".join(divider) + "|"]

    by_key = {row.key: row for row in rows}
    flavours_with_rows = {row.flavour for row in rows}
    labels = sorted(
        {(row.package, row.mode) for row in rows},
        key=lambda item: (item[0].lower(), RUN_MODES.index(item[1])),
    )
    totals = {flavour.flavour_id: [0] * len(TOTAL_FIELDS) for flavour in flavours}
    for package, mode in labels:
        cells = [f"`{package}`" if mode == "default" else f"`{package}` (combat)"]
        for flavour in flavours:
            row = by_key.get((flavour.flavour_id, package, mode))
            if row is None:
                first = "-" if flavour.flavour_id in flavours_with_rows else "not run"
                cells += [first] + ["-"] * (len(TOTAL_FIELDS) - 1)
                continue
            values = [getattr(row, name) for name in TOTAL_FIELDS]
            if mode == "default":
                totals[flavour.flavour_id] = [
                    total + value for total, value in zip(totals[flavour.flavour_id], values)
                ]
            cells += [str(value) for value in values]
        lines.append("| " + " | ".join(cells) + " |")

    total_cells = ["**total (default runs)**"]
    for flavour in flavours:
        if flavour.flavour_id not in flavours_with_rows:
            total_cells += ["not run"] + ["-"] * (len(TOTAL_FIELDS) - 1)
            continue
        total_cells += [f"**{value}**" for value in totals[flavour.flavour_id]]
    lines.append("| " + " | ".join(total_cells) + " |")
    return lines


def render_runs(rows: Sequence[Row], unavailable: dict[str, str]) -> list[str]:
    """Per flavour: which client, locale, OS, date and commit each row comes from."""
    lines: list[str] = []
    for flavour in shown_flavours(rows):
        flavour_rows = [row for row in rows if row.flavour == flavour.flavour_id]
        lines += ["", f"### {flavour.display_name}", ""]
        if not flavour_rows:
            reason = unavailable.get(flavour.flavour_id)
            if reason:
                lines.append(f"Not run: {cell(reason)}.")
            else:
                lines.append(f"No run recorded yet (install into `{flavour.directory}`).")
            continue
        lines += [
            "| Package | Build | Interface | Locale | OS | Date | Commit |",
            "|---|---|---:|---|---|---|---|",
        ]
        for row in flavour_rows:
            interface = str(row.interface) if row.interface is not None else "unknown"
            lines.append(
                f"| {package_label(row)} | {describe_build(row)} | {interface} | "
                f"{row.locale or 'unknown'} | {row.os or 'unknown'} | "
                f"{row.date or 'unknown'} | {describe_commit(row)} |"
            )
    return lines


def render_skips(rows: Sequence[Row]) -> list[str]:
    """Every skipped test with its reason, per flavour; skips never count as passes."""
    lines: list[str] = []
    for flavour in CLIENT_FLAVOURS:
        flavour_rows = [row for row in rows if row.flavour == flavour.flavour_id and row.skipped]
        if not flavour_rows:
            continue
        lines += ["", f"### {flavour.display_name}", ""]
        unrecorded = [row for row in flavour_rows if row.skips is None]
        recorded = [row for row in flavour_rows if row.skips]
        if recorded:
            lines += ["| Package | Test | Reason |", "|---|---|---|"]
            for row in recorded:
                for skip in row.skips or []:
                    test = f"{skip.get('suite', '?')}: {skip.get('test', '?')}"
                    lines.append(
                        f"| {package_label(row)} | {cell(test)} | {cell(skip.get('reason', ''))} |"
                    )
        if unrecorded:
            if recorded:
                lines.append("")
            lines.append(
                "Recorded before this command existed, without the tests' names and reasons "
                "(each is a skip the package's `EXPECTED.md` announces):"
            )
            lines.append("")
            for row in unrecorded:
                lines.append(f"- {package_label(row)}: {row.skipped} skipped")
    if not lines:
        lines = ["", "No skipped test recorded."]
    return lines


def render_problems(rows: Sequence[Row]) -> list[str]:
    """Every failed or timed-out test with its message."""
    problem_rows = [row for row in rows if row.problems]
    if not problem_rows:
        return ["", "No failed or timed-out test recorded."]
    lines = ["", "| Flavour | Package | Status | Test | Message |", "|---|---|---|---|---|"]
    for row in problem_rows:
        display = flavour_by_id(row.flavour)
        name = display.display_name if display else row.flavour
        for problem in row.problems:
            test = f"{problem.get('suite', '?')}: {problem.get('test', '?')}"
            lines.append(
                f"| {name} | {package_label(row)} | {problem.get('status', '?')} | "
                f"{cell(test)} | {cell(problem.get('message', ''))} |"
            )
    return lines


def render_gaps(
    rows: Sequence[Row], combat_packages: Sequence[str], unavailable: dict[str, str]
) -> list[str]:
    """What the matrix does not prove: standing gaps, flavours, packages and combat runs."""
    lines = [""]
    for title, text in STANDING_GAPS:
        if title == "Windows client" and any(row.os == "Windows" for row in rows):
            continue
        lines.append(f"- **{title}**: {text}.")

    packages = sorted({row.package for row in rows if row.mode == "default"}, key=str.lower)
    run_flavours: list[ClientFlavour] = []
    for flavour in CLIENT_FLAVOURS:
        present = {row.package for row in rows if row.flavour == flavour.flavour_id}
        if not present:
            promise = "" if flavour.promised else " (optional, not promised)"
            reason = unavailable.get(flavour.flavour_id)
            detail = f"not run: {cell(reason)}" if reason else "no run recorded yet"
            lines.append(f"- **{flavour.display_name}**{promise}: {detail}.")
            continue
        run_flavours.append(flavour)
        missing = [package for package in packages if package not in present]
        if missing:
            names = ", ".join(f"`{package}`" for package in missing)
            lines.append(f"- **{flavour.display_name}**: no run recorded for {names}.")

    recorded_keys = {row.key for row in rows}
    for flavour in run_flavours:
        missing_combat = [
            package
            for package in combat_packages
            if (flavour.flavour_id, package, "combat") not in recorded_keys
        ]
        if missing_combat:
            names = ", ".join(f"`{package}`" for package in missing_combat)
            lines.append(
                f"- **{flavour.display_name} combat runs**: no `/mct run <package> combat` "
                f"recorded for {names}; their combat tests are skips in the default run."
            )

    unrecorded = [row for row in rows if row.skipped and row.skips is None]
    if unrecorded:
        lines.append(
            f"- **Skip reasons**: {len(unrecorded)} rows were recorded without the names "
            "and reasons of their skipped tests; the next run of each package records them."
        )
    return lines


def render_matrix(record: Record, combat_packages: Sequence[str]) -> str:
    """The whole text of ``RESULTS.md``."""
    ordered = sort_rows(record.rows)
    unavailable = record.unavailable
    lines = [
        "# Real-client results",
        "",
        "<!-- Rendered by `python3 -m tooling.client.report` from `results.json`; "
        "do not edit. -->",
        "",
        "What the real-client test addons ([`README.md`](README.md)) proved in the game, per",
        "client flavour. Each row is a package's latest recorded run on that flavour: the",
        "default run (`/mct run <package>`) or a combat run (`/mct run <package> combat`).",
        "Rows keep their own client, date and commit, so a session that runs a few",
        "packages updates only their rows. `not run` marks a flavour without any recorded",
        "run and `-` a package without one. A skip is never a pass: every skipped test is",
        "listed below with its reason, and every gap in coverage under [Gaps](#gaps).",
        "Compare a new run with the package's `EXPECTED.md`, not with this table.",
        "",
        "## Flavours",
        "",
        *render_status_table(ordered, unavailable),
        "",
        "## Matrix",
        "",
        *render_matrix_table(ordered),
        "",
        "## Runs",
        *render_runs(ordered, unavailable),
        "",
        "## Skipped tests",
        *render_skips(ordered),
        "",
        "## Failed and timed-out tests",
        *render_problems(ordered),
        "",
        "## Gaps",
        *render_gaps(ordered, combat_packages, unavailable),
    ]
    return "\n".join(lines) + "\n"


# Command line -----------------------------------------------------------------------------------


def parse_args(argv: Sequence[str] | None = None) -> argparse.Namespace:
    """Parse the report command's line."""
    parser = argparse.ArgumentParser(
        prog="python3 -m tooling.client.report",
        description=(
            "Merge the MoltenCodesTest harness's saved results from one or more client "
            "flavours into tests/client/results.json and render tests/client/RESULTS.md. "
            "The game folder is only read. See tests/client/README.md."
        ),
    )
    parser.add_argument(
        "--wow-dir",
        metavar="DIR",
        help='the game folder, for example "/Applications/World of Warcraft"',
    )
    known = ", ".join(flavour.directory for flavour in CLIENT_FLAVOURS)
    parser.add_argument(
        "--flavour-dir",
        action="append",
        dest="flavour_dirs",
        metavar="NAME",
        help=f"a flavour folder inside --wow-dir (repeatable; default: every one of {known} "
        "that exists)",
    )
    parser.add_argument(
        "--saved-variables",
        action="append",
        dest="saved_variables",
        metavar="FILE",
        help="a MoltenCodesTest.lua saved-variables file to read directly (repeatable)",
    )
    parser.add_argument(
        "--results",
        default=str(DEFAULT_RESULTS_PATH),
        metavar="FILE",
        help="the record to merge into (default: tests/client/results.json)",
    )
    parser.add_argument(
        "--matrix",
        default=str(DEFAULT_MATRIX_PATH),
        metavar="FILE",
        help="the Markdown matrix to render (default: tests/client/RESULTS.md)",
    )
    flavour_ids = ", ".join(flavour.flavour_id for flavour in CLIENT_FLAVOURS)
    parser.add_argument(
        "--unavailable",
        action="append",
        default=[],
        metavar="FLAVOUR=REASON",
        help=f"record why no session of a flavour can run for now ({flavour_ids}); the "
        "matrix shows it as not run with the reason (repeatable)",
    )
    parser.add_argument(
        "--available",
        action="append",
        default=[],
        metavar="FLAVOUR",
        help="drop the --unavailable reason of a flavour (repeatable); a recorded run of "
        "the flavour drops it too",
    )
    mode = parser.add_mutually_exclusive_group()
    mode.add_argument(
        "--check",
        action="store_true",
        help="write nothing; fail when either file differs from what would be written",
    )
    mode.add_argument(
        "--dry-run",
        action="store_true",
        help="print what would change and write nothing",
    )
    return parser.parse_args(argv)


def input_files(args: argparse.Namespace) -> list[Path]:
    """The saved-variables files the command line names, refusing a wrong game folder."""
    files = [Path(path).expanduser() for path in args.saved_variables or []]
    for path in files:
        if not path.is_file():
            raise ReportError(f"{path} does not exist")
    if args.flavour_dirs and not args.wow_dir:
        raise ReportError("--flavour-dir needs --wow-dir")
    if args.wow_dir:
        wow_dir = Path(args.wow_dir).expanduser()
        if not wow_dir.is_dir():
            raise ReportError(f"{wow_dir} does not exist; check --wow-dir")
        directories = args.flavour_dirs or [flavour.directory for flavour in CLIENT_FLAVOURS]
        for directory in args.flavour_dirs or []:
            if not (wow_dir / directory).is_dir():
                raise ReportError(f"{wow_dir / directory} does not exist; check --flavour-dir")
        found = find_saved_variables(wow_dir, directories)
        if not found:
            raise ReportError(
                f"no {SAVED_VARIABLES_FILE_NAME} under {wow_dir} in "
                f"{', '.join(directories)}; run /mct run and /reload first"
            )
        files.extend(found)
    return files


def known_flavour_id(flavour_id: str) -> str:
    """``flavour_id`` when it names a known flavour, refusing anything else."""
    if flavour_by_id(flavour_id) is None:
        known = ", ".join(flavour.flavour_id for flavour in CLIENT_FLAVOURS)
        raise ReportError(f'unknown flavour "{flavour_id}"; known: {known}')
    return flavour_id


def updated_unavailable(
    current: dict[str, str],
    runs: Sequence[SavedRun],
    rows: Sequence[Row],
    marked: Sequence[str],
    cleared: Sequence[str],
) -> tuple[dict[str, str], list[str]]:
    """The unavailable reasons after this command, and one line per change.

    A flavour with a recorded run from the inputs is available by the fact
    itself; ``--available`` drops a reason by hand; ``--unavailable`` sets one.
    """
    unavailable = dict(current)
    lines: list[str] = []
    merged = {row.key: row for row in rows}
    for run in runs:
        flavour = run.row.flavour
        if flavour in unavailable and merged.get(run.row.key) is run.row:
            del unavailable[flavour]
            lines.append(f"cleared the unavailable reason of {flavour}: a run is recorded")
    for flavour in cleared:
        if unavailable.pop(known_flavour_id(flavour), None) is not None:
            lines.append(f"cleared the unavailable reason of {flavour}")
    for entry in marked:
        flavour, separator, reason = entry.partition("=")
        reason = " ".join(reason.split())
        if not separator or not reason:
            raise ReportError(f'--unavailable needs FLAVOUR=REASON, got "{entry}"')
        if len(reason) > MAX_UNAVAILABLE_REASON:
            raise ReportError(f"--unavailable reason is longer than {MAX_UNAVAILABLE_REASON}")
        if any(row.flavour == known_flavour_id(flavour) for row in rows):
            raise ReportError(f"{flavour} has recorded runs, so it cannot be marked unavailable")
        if unavailable.get(flavour) != reason:
            unavailable[flavour] = reason
            lines.append(f"recorded {flavour} as unavailable: {reason}")
    return unavailable, lines


def read_file(path: Path) -> str | None:
    """A text file's content, or ``None`` when it does not exist."""
    return path.read_text(encoding="utf-8") if path.is_file() else None


def main(argv: Sequence[str] | None = None) -> int:
    """Entry point for ``python3 -m tooling.client.report``."""
    args = parse_args(argv)
    results_path = Path(args.results)
    matrix_path = Path(args.matrix)

    def warn(text: str) -> None:
        print(f"warning: {text}", file=sys.stderr)

    try:
        files = input_files(args)
        recorded = load_results(results_path)
        runs: list[SavedRun] = []
        for path in files:
            runs.extend(read_saved_runs(path, warn))
        outcome = merge_rows(recorded.rows, runs)
        unavailable, unavailable_lines = updated_unavailable(
            recorded.unavailable, runs, outcome.rows, args.unavailable, args.available
        )
    except ReportError as failure:
        print(f"error: {failure}", file=sys.stderr)
        return 1
    outcome.lines.extend(unavailable_lines)

    record = Record(outcome.rows, unavailable)
    results_text = render_results_json(record)
    matrix_text = render_matrix(record, combat_suite_packages())
    stale = [
        path
        for path, text in ((results_path, results_text), (matrix_path, matrix_text))
        if read_file(path) != text
    ]

    if args.check:
        for line in outcome.lines:
            if not line.startswith(("unchanged", "kept")):
                print(f"differs: {line}", file=sys.stderr)
        for path in stale:
            print(
                f"error: {path} is not what python3 -m tooling.client.report writes",
                file=sys.stderr,
            )
        if stale:
            print("run the command without --check to update it", file=sys.stderr)
            return 1
        print(f"{results_path.name} and {matrix_path.name} are up to date")
        return 0

    prefix = "dry run: " if args.dry_run else ""
    for line in outcome.lines:
        print(prefix + line)
    if args.dry_run:
        for path in stale:
            print(f"would write {path}")
        if not stale:
            print("nothing would change")
        return 0

    for path, text in ((results_path, results_text), (matrix_path, matrix_text)):
        if path in stale:
            path.parent.mkdir(parents=True, exist_ok=True)
            path.write_text(text, encoding="utf-8")
            print(f"wrote {path}")
    if not stale:
        print("nothing changed")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
