"""Read the in-client benchmark's saved results into a results file, and render it.

The harness (``MoltenCodesBench``, ``docs/BENCHMARKS.md``, "In-client runner")
saves one entry per session in the account-wide saved variable
``MoltenCodesBenchResults``. This command reads those entries without running
Lua (``tooling/client/saved_variables.py``) and writes one results file per
client flavour:

    tooling/bench/results/<date>-client-<flavour>.json

with ``kind = "client"``. It has the host results' shape where the two agree
(``workloads[].sides.<side>.cases`` with the host's timing fields, so the host
report's tables render it) and adds what only the client has: the frame
cases' measurements, the cases not run in the client with the reason, the
client build, the frame-rate settings, the addons loaded and the settle time.
Host and client results are separate files of separate kinds and are never
merged: ``tooling.bench.report`` refuses a client file and this command
refuses a host file.

Which entries are used, per flavour:

- the entries of the most recent installation (``installation.installedAt``),
  so a run of an older commit never mixes with a newer one; older entries are
  reported and left out;
- entries from a test build are left out, as the real-client matrix does;
- several rounds of one case and side are pooled as the host runner pools
  them (``run.merge_rounds``) for a batch case, and by the median of each
  measurement for a frame case.

    python3 -m tooling.bench.client_report --wow-dir DIR [--flavour-dir NAME ...]
                                            [--out FILE] [--markdown FILE] [--dry-run]
    python3 -m tooling.bench.client_report --saved-variables FILE [...] [--out FILE] [--dry-run]
    python3 -m tooling.bench.client_report --render FILE [--markdown FILE]
"""

from __future__ import annotations

import argparse
import datetime
import json
import statistics
import sys
from pathlib import Path
from typing import Any, Callable, Sequence

from tooling.bench import report as host_report
from tooling.bench.client_workloads import BY_NAME as CLIENT_WORKLOADS_BY_NAME
from tooling.bench.client_workloads import CLIENT_WORKLOADS, NOT_IN_CLIENT
from tooling.bench.run import merge_rounds
from tooling.bench.workloads import SIDES
from tooling.client.flavours import (
    CLIENT_FLAVOURS,
    ClientFlavour,
    flavour_by_directory,
    flavour_by_project_id,
)
from tooling.client.saved_variables import SavedVariablesError, as_list, parse_saved_variables

ROOT = Path(__file__).resolve().parents[2]

#: Where results files are committed.
RESULTS_DIRECTORY = ROOT / "tooling" / "bench" / "results"

#: Format version of a client results file; `--render` refuses any other.
CLIENT_RESULTS_SCHEMA = 1

#: The entry layout the harness writes (`RESULTS_SCHEMA` in Harness.lua).
ENTRY_SCHEMA = 1

#: The harness's saved variable and its file.
SAVED_VARIABLES_GLOBAL = "MoltenCodesBenchResults"
SAVED_VARIABLES_FILE_NAME = "MoltenCodesBench.lua"
SAVED_VARIABLES_PATTERN = "WTF/Account/*/SavedVariables/" + SAVED_VARIABLES_FILE_NAME

#: What the numbers were measured with, for the results file.
CLOCK = "debugprofilestop (the client's high-resolution timer), one batch per frame"
FRAME_CLOCK = "GetTimePreciseSec between successive frames"
ALLOCATION = "collectgarbage('count') delta over one batch with the collector stopped"


class ClientReportError(Exception):
    """The saved results cannot be read or the results file cannot be written."""


# Reading ------------------------------------------------------------------------------------


def find_saved_variables(wow_dir: Path, flavour_directories: Sequence[str]) -> list[Path]:
    """The harness's saved-variables files under each flavour folder, sorted.

    The variable is account-wide; ``.bak`` copies are never read.
    """
    files: list[Path] = []
    for directory in flavour_directories:
        flavour_dir = wow_dir / directory
        if flavour_dir.is_dir():
            files.extend(sorted(flavour_dir.glob(SAVED_VARIABLES_PATTERN)))
    return files


def read_saved_file(path: Path) -> dict[str, Any]:
    """The ``MoltenCodesBenchResults`` table of one file, parsed without running Lua."""
    try:
        variables = parse_saved_variables(path.read_bytes())
    except (OSError, SavedVariablesError) as failure:
        raise ClientReportError(f"{path}: {failure}") from failure
    results = variables.get(SAVED_VARIABLES_GLOBAL)
    if not isinstance(results, dict):
        raise ClientReportError(f"{path}: no {SAVED_VARIABLES_GLOBAL} table")
    return results


def entry_flavour(entry: dict[str, Any], folder: ClientFlavour | None) -> ClientFlavour | None:
    """The flavour of an entry: what the client said, else the install folder, else the file's."""
    client = entry.get("client") if isinstance(entry.get("client"), dict) else {}
    flavour = flavour_by_project_id(client.get("projectId"))
    if flavour is not None:
        return flavour
    installation = entry.get("installation")
    if isinstance(installation, dict) and isinstance(installation.get("flavourDirectory"), str):
        flavour = flavour_by_directory(installation["flavourDirectory"])
        if flavour is not None:
            return flavour
    return folder


def folder_flavour(path: Path) -> ClientFlavour | None:
    """The flavour of the folder a saved-variables file lies in, if any."""
    for parent in path.parents:
        flavour = flavour_by_directory(parent.name)
        if flavour is not None:
            return flavour
    return None


def usable_entries(
    path: Path, results: dict[str, Any], warn: Callable[[str], None]
) -> list[tuple[ClientFlavour, dict[str, Any]]]:
    """Every entry of one file with its flavour; unusable entries are warned about and dropped."""
    folder = folder_flavour(path)
    usable: list[tuple[ClientFlavour, dict[str, Any]]] = []
    for index, entry in enumerate(as_list(results.get("entries")), start=1):
        where = f"{path}: entry {index}"
        if not isinstance(entry, dict) or entry.get("schema") != ENTRY_SCHEMA:
            warn(f"{where} is not a schema {ENTRY_SCHEMA} entry; skipped")
            continue
        client = entry.get("client") if isinstance(entry.get("client"), dict) else {}
        if client.get("testBuild") is True:
            warn(f"{where} ran on a test build; skipped")
            continue
        flavour = entry_flavour(entry, folder)
        if flavour is None:
            warn(f"{where} names no known flavour; skipped")
            continue
        if entry.get("workload") not in CLIENT_WORKLOADS_BY_NAME or entry.get("side") not in SIDES:
            warn(f"{where} names an unknown workload or side; skipped")
            continue
        usable.append((flavour, entry))
    return usable


def installed_at(entry: dict[str, Any]) -> str:
    """The installation time of an entry, ``""`` when unknown."""
    installation = entry.get("installation")
    value = installation.get("installedAt") if isinstance(installation, dict) else None
    return value if isinstance(value, str) else ""


def latest_installation(
    entries: Sequence[dict[str, Any]], label: str, warn: Callable[[str], None]
) -> list[dict[str, Any]]:
    """The entries of the most recent installation; the others are warned about."""
    newest = max(installed_at(entry) for entry in entries)
    kept = [entry for entry in entries if installed_at(entry) == newest]
    dropped = len(entries) - len(kept)
    if dropped:
        warn(f"{label}: left out {dropped} entries of older installations than {newest}")
    return kept


# Assembling -----------------------------------------------------------------------------------


def median_metrics(results: Sequence[dict[str, Any]]) -> dict[str, Any]:
    """Each numeric measurement's median over the rounds; any other value from the first."""
    merged: dict[str, Any] = {}
    names: list[str] = []
    for result in results:
        for name in result.get("metrics") or {}:
            if name not in names:
                names.append(name)
    for name in names:
        values = [(result.get("metrics") or {}).get(name) for result in results]
        numbers = [
            value
            for value in values
            if isinstance(value, (int, float)) and not isinstance(value, bool)
        ]
        if numbers and len(numbers) == len([value for value in values if value is not None]):
            merged[name] = statistics.median(numbers)
        else:
            merged[name] = next((value for value in values if value is not None), None)
    return merged


def merge_case(results: Sequence[dict[str, Any]]) -> dict[str, Any]:
    """One case's rounds as one result: pooled batches, or median frame measurements."""
    first = dict(results[0])
    if first.get("kind") == "frames":
        first["rounds"] = len(results)
        first["metrics"] = median_metrics(results)
        return first
    for result in results:
        result["nanosecondsPerOperation"] = as_list(result.get("nanosecondsPerOperation"))
    merged = merge_rounds(results)
    merged["kind"] = "batch"
    return merged


def assemble_side(entries: Sequence[dict[str, Any]]) -> dict[str, Any]:
    """One side of one workload: its libraries, checks, measured cases and cases not run."""
    checks_entries = [entry for entry in entries if entry.get("step") == "checks"]
    case_entries = [entry for entry in entries if entry.get("step") == "case"]
    order: list[str] = []
    for entry in checks_entries:
        order.extend(name for name in as_list(entry.get("cases")) if name not in order)
    for entry in case_entries:
        if entry.get("case") not in order:
            order.append(entry.get("case"))

    libraries: list[Any] = []
    for entry in reversed(entries):
        if as_list(entry.get("libraries")):
            libraries = as_list(entry.get("libraries"))
            break

    cases: list[dict[str, Any]] = []
    not_run: list[dict[str, str]] = []
    for name in order:
        runs = [entry for entry in case_entries if entry.get("case") == name]
        measured = [entry["result"] for entry in runs if isinstance(entry.get("result"), dict)]
        if measured:
            cases.append(merge_case(measured))
            continue
        for entry in runs[-1:]:
            if entry.get("skipped"):
                not_run.append({"name": name, "status": "skipped", "reason": entry["skipped"]})
            elif entry.get("failed"):
                not_run.append({"name": name, "status": "failed", "reason": entry["failed"]})

    side: dict[str, Any] = {"libraries": libraries, "checks": [], "cases": cases}
    if checks_entries:
        latest = checks_entries[-1]
        side["checks"] = as_list(latest.get("checks"))
        if latest.get("failed"):
            not_run.append({"name": "checks", "status": "failed", "reason": latest["failed"]})
        elif latest.get("skipped"):
            not_run.append({"name": "checks", "status": "skipped", "reason": latest["skipped"]})
    if not_run:
        side["notRun"] = not_run
    return side


def distinct(values: Sequence[Any]) -> list[Any]:
    """The values in first-seen order, each once, ``None`` left out."""
    seen: list[Any] = []
    for value in values:
        if value is not None and value not in seen:
            seen.append(value)
    return seen


def assemble_document(
    flavour: ClientFlavour,
    entries: Sequence[dict[str, Any]],
    details: dict[str, Any],
    command_line: str,
) -> dict[str, Any]:
    """The client results document of one flavour."""
    clients = [entry.get("client") or {} for entry in entries]
    sessions = [entry.get("session") or {} for entry in entries]
    dates = sorted(client["date"] for client in clients if isinstance(client.get("date"), str))
    latest_client = clients[-1]
    installation = entries[-1].get("installation") or {}
    batch_results = [
        entry["result"]
        for entry in entries
        if isinstance(entry.get("result"), dict) and entry["result"].get("kind") == "batch"
    ]

    workloads: list[dict[str, Any]] = []
    for workload in CLIENT_WORKLOADS:
        mine = [entry for entry in entries if entry.get("workload") == workload.name]
        if not mine:
            continue
        workloads.append(
            {
                "name": workload.name,
                "title": workload.title,
                "compares": workload.compares,
                "origin": workload.origin,
                "sides": {
                    side: assemble_side([entry for entry in mine if entry.get("side") == side])
                    for side in SIDES
                },
            }
        )

    addons = sorted({name for session in sessions for name in as_list(session.get("addonsLoaded"))})
    settle = [
        session["secondsSinceEnteringWorld"]
        for session in sessions
        if isinstance(session.get("secondsSinceEnteringWorld"), (int, float))
    ]
    return {
        "schema": CLIENT_RESULTS_SCHEMA,
        "kind": "client",
        "flavour": flavour.flavour_id,
        "date": dates[-1][:10] if dates else datetime.date.today().isoformat(),
        "command": command_line,
        "client": {
            "version": latest_client.get("version"),
            "builds": distinct([client.get("build") for client in clients]),
            "interface": latest_client.get("interface"),
            "projectId": latest_client.get("projectId"),
            "os": latest_client.get("os"),
            "locale": latest_client.get("locale"),
            "firstSession": dates[0] if dates else None,
            "lastSession": dates[-1] if dates else None,
        },
        "settings": {
            "sessions": len(entries),
            "warmupBatches": distinct([result.get("warmup") for result in batch_results]),
            "timedBatches": distinct([result.get("repetitions") for result in batch_results]),
            "rounds": max((int(entry.get("round") or 1) for entry in entries), default=1),
            "clock": CLOCK,
            "frameClock": FRAME_CLOCK,
            "allocation": ALLOCATION,
            "secondsSinceEnteringWorld": [min(settle), max(settle)] if settle else None,
            "frameRateSettings": distinct(
                [session.get("frameRateSettings") for session in sessions]
            ),
            "errorsCaptured": all(
                session.get("errorsCaptured") is not False for session in sessions
            ),
        },
        "addonsLoaded": addons,
        "moltencodes": {
            "commit": installation.get("commit"),
            "dirty": installation.get("dirty"),
            "installedAt": installation.get("installedAt"),
            "flavourDirectory": installation.get("flavourDirectory"),
            "packageVersions": details.get("packageVersions") or {},
        },
        "ace3": details.get("ace3") or {},
        "notInClient": dict(NOT_IN_CLIENT),
        "workloads": workloads,
    }


def collect(
    files: Sequence[Path], command_line: str, warn: Callable[[str], None]
) -> list[dict[str, Any]]:
    """One document per flavour found in ``files``, in the flavour table's order."""
    by_flavour: dict[str, list[dict[str, Any]]] = {}
    details: dict[str, dict[str, Any]] = {}
    for path in files:
        results = read_saved_file(path)
        recorded = results.get("installationDetails")
        if isinstance(recorded, dict):
            details.update(
                {key: value for key, value in recorded.items() if isinstance(value, dict)}
            )
        for flavour, entry in usable_entries(path, results, warn):
            by_flavour.setdefault(flavour.flavour_id, []).append(entry)
    documents: list[dict[str, Any]] = []
    for flavour in CLIENT_FLAVOURS:
        entries = by_flavour.get(flavour.flavour_id)
        if not entries:
            continue
        kept = latest_installation(entries, flavour.flavour_id, warn)
        documents.append(
            assemble_document(flavour, kept, details.get(installed_at(kept[-1]), {}), command_line)
        )
    return documents


def results_path(document: dict[str, Any], directory: Path = RESULTS_DIRECTORY) -> Path:
    """``<date>-client-<flavour>.json`` in ``directory``, with ``-2``, ``-3``... when taken."""
    stem = f"{document['date']}-client-{document['flavour']}"
    candidate = directory / f"{stem}.json"
    suffix = 2
    while candidate.exists():
        candidate = directory / f"{stem}-{suffix}.json"
        suffix += 1
    return candidate


# Rendering ----------------------------------------------------------------------------------------


def batch_only(workload: dict[str, Any]) -> dict[str, Any]:
    """A copy of a workload whose sides hold only batch cases, for the timing table."""
    sides = {}
    for side, data in workload["sides"].items():
        cases = [case for case in data.get("cases", []) if case.get("kind") != "frames"]
        sides[side] = {**data, "cases": cases}
    return {**workload, "sides": sides}


def render_not_run(workload: dict[str, Any]) -> list[str]:
    """One line per case a side did not run, with the reason."""
    lines: list[str] = []
    for side in SIDES:
        for item in workload["sides"].get(side, {}).get("notRun", []):
            reason = " ".join(str(item.get("reason", "")).split())
            lines.append(
                f"- `{item.get('name')}` on {host_report.SIDE_TITLES[side]}: "
                f"{item.get('status')}: {reason}"
            )
    return lines


def format_settings(values: Any) -> str:
    """Frame-rate settings as `name value` pairs, one group per distinct set."""
    groups = []
    for settings in as_list(values):
        if isinstance(settings, dict) and settings:
            groups.append(", ".join(f"{key} {settings[key]}" for key in sorted(settings)))
    return "; ".join(groups) or "—"


def render_environment(document: dict[str, Any]) -> list[str]:
    """The table of what the numbers were measured on."""
    client = document.get("client", {})
    settings = document.get("settings", {})
    repository = document.get("moltencodes", {})
    ace = document.get("ace3", {})
    settle = settings.get("secondsSinceEnteringWorld")
    rows = [
        ("Kind", "client (inside the game; never mixed with host results)"),
        ("Flavour", document.get("flavour")),
        (
            "Client",
            f"{client.get('version')} build {', '.join(map(str, client.get('builds') or []))} "
            f"(interface {client.get('interface')}), {client.get('os')}, {client.get('locale')}",
        ),
        (
            "Sessions",
            f"{settings.get('sessions')}, from {client.get('firstSession')} "
            f"to {client.get('lastSession')}",
        ),
        (
            "Batches",
            f"{settings.get('rounds')} round(s) per case and side, each a fresh session with "
            f"{'/'.join(map(str, settings.get('warmupBatches') or []))} warm-up, "
            f"{'/'.join(map(str, settings.get('timedBatches') or []))} timed "
            "and 1 allocation batch",
        ),
        ("Clock", f"{settings.get('clock')}; frames: {settings.get('frameClock')}"),
        (
            "Settle",
            "—"
            if not settle
            else f"{settle[0]:.0f}–{settle[1]:.0f} s after entering the world",
        ),
        ("Frame-rate settings", format_settings(settings.get("frameRateSettings"))),
        ("Addons loaded", ", ".join(document.get("addonsLoaded") or []) or "—"),
        (
            "MoltenCodes",
            f"commit `{repository.get('commit')}`"
            + (", working tree had changes" if repository.get("dirty") else ""),
        ),
        ("Ace3", f"`{ace.get('repository')}` commit `{ace.get('commit')}`"),
    ]
    return ["| | |", "|---|---|", *(f"| {name} | {value} |" for name, value in rows)]


def render(document: dict[str, Any]) -> str:
    """The whole report of one client results file."""
    if document.get("kind") != "client":
        raise ClientReportError(
            f"this is a {document.get('kind')!r} results file; render host results with "
            "python3 -m tooling.bench.report"
        )
    if document.get("schema") != CLIENT_RESULTS_SCHEMA:
        raise ClientReportError(
            f"unsupported client results schema {document.get('schema')!r}; "
            f"expected {CLIENT_RESULTS_SCHEMA}"
        )
    lines = ["### Environment", "", *render_environment(document), "", "### Summary", ""]
    lines.extend(host_report.render_summary(document))
    for workload in document.get("workloads", []):
        lines.extend(["", f"### {workload['title']}", "", f"{workload['compares']}.", ""])
        lines.append(f"Libraries: {host_report.render_libraries(workload)}.")
        timed = batch_only(workload)
        if any(timed["sides"][side]["cases"] for side in timed["sides"]):
            lines.extend(["", *host_report.render_timing_table(timed)])
        metrics = host_report.render_metrics(workload)
        if metrics:
            lines.extend(["", "Measurements:", "", *metrics])
        checks = host_report.render_checks(workload)
        if checks:
            lines.extend(["", "Checks:", "", *checks])
        not_run = render_not_run(workload)
        if not_run:
            lines.extend(["", "Not run:", "", *not_run])
    excluded = document.get("notInClient") or {}
    if excluded:
        lines.extend(["", "### Host workloads not run in the client", ""])
        lines.extend(f"- `{name}`: {reason}." for name, reason in excluded.items())
    return "\n".join(lines) + "\n"


# Command line --------------------------------------------------------------------------------


def parse_args(argv: Sequence[str] | None = None) -> argparse.Namespace:
    """Parse the command line."""
    parser = argparse.ArgumentParser(
        prog="python3 -m tooling.bench.client_report",
        description=(
            "Read the in-client benchmark's saved results (MoltenCodesBench.lua) into "
            "tooling/bench/results/<date>-client-<flavour>.json and print them as Markdown, "
            "or render a client results file. The game folder is only read. See "
            'docs/BENCHMARKS.md, "In-client runner".'
        ),
    )
    source = parser.add_mutually_exclusive_group(required=True)
    source.add_argument(
        "--wow-dir",
        metavar="DIR",
        help='the game folder, for example "/Applications/World of Warcraft"',
    )
    source.add_argument(
        "--saved-variables",
        action="append",
        metavar="FILE",
        help="a MoltenCodesBench.lua saved-variables file to read directly (repeatable)",
    )
    source.add_argument("--render", type=Path, metavar="FILE", help="render a client results file")
    known = ", ".join(flavour.directory for flavour in CLIENT_FLAVOURS)
    parser.add_argument(
        "--flavour-dir",
        action="append",
        dest="flavour_dirs",
        metavar="NAME",
        help=f"a flavour folder inside --wow-dir (repeatable; default: every one of {known})",
    )
    parser.add_argument(
        "--out",
        type=Path,
        default=None,
        metavar="FILE",
        help="write the results here instead of tooling/bench/results/ (one flavour only)",
    )
    parser.add_argument(
        "--markdown", type=Path, default=None, metavar="FILE", help="write the Markdown here too"
    )
    parser.add_argument(
        "--dry-run", action="store_true", help="print the report and write no results file"
    )
    return parser.parse_args(argv)


def input_files(args: argparse.Namespace) -> list[Path]:
    """The saved-variables files the command line names."""
    if args.saved_variables:
        files = [Path(path).expanduser() for path in args.saved_variables]
        for path in files:
            if not path.is_file():
                raise ClientReportError(f"{path} does not exist")
        return files
    wow_dir = Path(args.wow_dir).expanduser()
    if not wow_dir.is_dir():
        raise ClientReportError(f"{wow_dir} does not exist; check --wow-dir")
    directories = args.flavour_dirs or [flavour.directory for flavour in CLIENT_FLAVOURS]
    files = find_saved_variables(wow_dir, directories)
    if not files:
        raise ClientReportError(
            f"no {SAVED_VARIABLES_FILE_NAME} under {wow_dir} in {', '.join(directories)}; "
            "run /mcb run and reload first"
        )
    return files


def main(argv: Sequence[str] | None = None) -> int:
    """Entry point for ``python3 -m tooling.bench.client_report``."""
    args = parse_args(argv)

    def warn(text: str) -> None:
        print(f"warning: {text}", file=sys.stderr)

    try:
        if args.render is not None:
            text = render(json.loads(args.render.read_text(encoding="utf-8")))
            sys.stdout.write(text)
            if args.markdown is not None:
                args.markdown.write_text(text, encoding="utf-8")
            return 0
        command_line = "python3 -m tooling.bench.client_report " + " ".join(
            sys.argv[1:] if argv is None else list(argv)
        )
        documents = collect(input_files(args), command_line.strip(), warn)
        if not documents:
            raise ClientReportError("no usable entries; nothing to write")
        if args.out is not None and len(documents) > 1:
            raise ClientReportError("--out takes one flavour; the inputs hold several")
        texts = []
        for document in documents:
            text = render(document)
            texts.append(text)
            sys.stdout.write(text)
            if args.dry_run:
                continue
            path = args.out if args.out is not None else results_path(document)
            path.parent.mkdir(parents=True, exist_ok=True)
            path.write_text(json.dumps(document, indent=2) + "\n", encoding="utf-8")
            print(f"wrote {path}", file=sys.stderr)
        if args.markdown is not None:
            args.markdown.write_text("\n".join(texts), encoding="utf-8")
    except (OSError, ValueError, KeyError, TypeError, ClientReportError) as problem:
        print(f"error: {problem}", file=sys.stderr)
        return 1
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
