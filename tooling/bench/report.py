"""Render a raw benchmark results file as Markdown.

    python3 -m tooling.bench.report RESULTS.json [--out FILE]

The report never interprets beyond the numbers: for every case it prints both
sides' median time per operation with the range of the timed batches, the
allocation per operation, and the time ratio MoltenCodes / Ace3. A ratio is
printed only for a case both sides implement with the same behaviour
(`equivalent`); a case where the work differs says so instead, with the
workload's note. A difference is called *faster* or *slower* only when the two
sides' interquartile ranges of batch times do not overlap; otherwise the
report says *within noise*. The extra measurements (wire bytes, retained memory, pending
host timers) and the correctness checks follow each workload's table.
"""

from __future__ import annotations

import argparse
import json
import statistics
import sys
from pathlib import Path
from typing import Any, Sequence

from tooling.bench.run import RESULTS_SCHEMA
from tooling.bench.workloads import SIDES

SIDE_TITLES = {"moltencodes": "MoltenCodes", "ace3": "Ace3"}


class ReportError(Exception):
    """The results file cannot be rendered."""


def format_number(value: float | None, digits: int = 0) -> str:
    """A number with thousands separators, or an em dash for a missing one."""
    if value is None:
        return "—"
    if digits == 0:
        return f"{value:,.0f}"
    return f"{value:,.{digits}f}"


def format_time(case: dict[str, Any] | None) -> str:
    """`median [min–max]` in nanoseconds per operation."""
    if case is None:
        return "—"
    samples = [value for value in case.get("nanosecondsPerOperation", []) if value is not None]
    median = case.get("medianNanoseconds")
    if not samples or median is None:
        return "—"
    precision = 1 if median < 100 else 0
    low, high = min(samples), max(samples)
    return (
        f"{format_number(median, precision)} "
        f"[{format_number(low, precision)}–{format_number(high, precision)}]"
    )


def format_bytes(case: dict[str, Any] | None) -> str:
    """Allocated bytes per operation."""
    if case is None:
        return "—"
    value = case.get("allocatedBytesPerOperation")
    if value is None:
        return "—"
    return format_number(value, 1 if abs(value) < 10 else 0)


def quartiles(samples: Sequence[float]) -> tuple[float, float]:
    """The first and third quartiles (inclusive method) of at least one sample."""
    if len(samples) == 1:
        return samples[0], samples[0]
    first, _, third = statistics.quantiles(samples, n=4, method="inclusive")
    return first, third


def compare(kit: dict[str, Any] | None, ace: dict[str, Any] | None) -> str:
    """The time ratio MoltenCodes / Ace3 and its verdict, or why there is none.

    The ratio is of the medians, with the ratio of the minimums beside it (the
    least disturbed batch of each side). The verdict is `faster` or `slower`
    only when the two sides' interquartile ranges of batch times do not
    overlap, and `within noise` otherwise, so one disturbed batch can neither
    make nor unmake a verdict.
    """
    if kit is None or ace is None:
        return "one side only"
    if not (kit.get("equivalent", True) and ace.get("equivalent", True)):
        return "different work"
    kit_samples = [v for v in kit.get("nanosecondsPerOperation", []) if v is not None]
    ace_samples = [v for v in ace.get("nanosecondsPerOperation", []) if v is not None]
    kit_median, ace_median = kit.get("medianNanoseconds"), ace.get("medianNanoseconds")
    if not kit_samples or not ace_samples or not kit_median or not ace_median:
        return "no data"
    ratio = kit_median / ace_median
    minimum_ratio = min(kit_samples) / min(ace_samples)
    kit_low, kit_high = quartiles(kit_samples)
    ace_low, ace_high = quartiles(ace_samples)
    if kit_high < ace_low:
        verdict = "faster"
    elif kit_low > ace_high:
        verdict = "slower"
    else:
        verdict = "within noise"
    return f"{ratio:.2f}× (min {minimum_ratio:.2f}×, {verdict})"


def verdict_of(kit: dict[str, Any] | None, ace: dict[str, Any] | None) -> str | None:
    """`faster`, `slower`, `within noise`, or `None` when the case is not compared."""
    text = compare(kit, ace)
    if "(" not in text:
        return None
    return text[text.index(", ") + 2 : -1]


def case_index(side: dict[str, Any]) -> dict[str, dict[str, Any]]:
    """A side's cases by name."""
    return {case["name"]: case for case in side.get("cases", [])}


def ordered_case_names(workload: dict[str, Any]) -> list[str]:
    """Case names in first-seen order across both sides."""
    names: list[str] = []
    for side in SIDES:
        for case in workload["sides"].get(side, {}).get("cases", []):
            if case["name"] not in names:
                names.append(case["name"])
    return names


def render_libraries(workload: dict[str, Any]) -> str:
    """One line naming the measured libraries and their revisions."""
    parts = []
    for side in SIDES:
        libraries = workload["sides"].get(side, {}).get("libraries", [])
        described = ", ".join(
            f"{library['name']} "
            + (
                f"revision {library['revision']}"
                if "revision" in library
                else f"minor {library.get('minor')}"
            )
            for library in libraries
        )
        parts.append(f"{SIDE_TITLES[side]}: {described or '—'}")
    return "; ".join(parts)


def render_timing_table(workload: dict[str, Any]) -> list[str]:
    """The main table: time, allocation and ratio per case."""
    kit_cases = case_index(workload["sides"].get("moltencodes", {}))
    ace_cases = case_index(workload["sides"].get("ace3", {}))
    lines = [
        "| Case | One operation | MoltenCodes ns/op | Ace3 ns/op | MoltenCodes ÷ Ace3 | MoltenCodes B/op | Ace3 B/op |",
        "|---|---|---:|---:|---|---:|---:|",
    ]
    notes: list[str] = []
    for name in ordered_case_names(workload):
        kit, ace = kit_cases.get(name), ace_cases.get(name)
        either = kit or ace or {}
        lines.append(
            f"| `{name}` | {either.get('operation', '')} | {format_time(kit)} | {format_time(ace)} | "
            f"{compare(kit, ace)} | {format_bytes(kit)} | {format_bytes(ace)} |"
        )
        for case in (kit, ace):
            note = case.get("note") if case else None
            if note and f"`{name}`: {note}" not in notes:
                notes.append(f"`{name}`: {note}")
    if notes:
        lines.append("")
        lines.extend(f"- {note}" for note in notes)
    return lines


def render_metrics(workload: dict[str, Any]) -> list[str]:
    """The extra measurements, one row per case and metric."""
    kit_cases = case_index(workload["sides"].get("moltencodes", {}))
    ace_cases = case_index(workload["sides"].get("ace3", {}))
    rows: list[str] = []
    for name in ordered_case_names(workload):
        kit_metrics = (kit_cases.get(name) or {}).get("metrics") or {}
        ace_metrics = (ace_cases.get(name) or {}).get("metrics") or {}
        for metric in sorted(set(kit_metrics) | set(ace_metrics)):
            rows.append(
                f"| `{name}` | {metric} | {render_metric(kit_metrics.get(metric))} | "
                f"{render_metric(ace_metrics.get(metric))} |"
            )
    if not rows:
        return []
    return ["| Case | Measurement | MoltenCodes | Ace3 |", "|---|---|---:|---:|", *rows]


def render_metric(value: Any) -> str:
    """One metric value."""
    if value is None:
        return "—"
    if isinstance(value, bool):
        return "yes" if value else "no"
    if isinstance(value, (int, float)):
        return format_number(value, 0 if float(value).is_integer() else 2)
    return str(value)


def render_checks(workload: dict[str, Any]) -> list[str]:
    """The correctness checks, side by side."""
    by_side = {
        side: {check["name"]: check for check in workload["sides"].get(side, {}).get("checks", [])}
        for side in SIDES
    }
    names: list[str] = []
    for side in SIDES:
        for name in by_side[side]:
            if name not in names:
                names.append(name)
    if not names:
        return []
    lines = ["| Check | MoltenCodes | Ace3 |", "|---|---|---|"]
    for name in names:
        cells = []
        for side in SIDES:
            check = by_side[side].get(name)
            if check is None:
                cells.append("—")
                continue
            status = "pass" if check.get("passed") else "fail"
            if not check.get("promised", True):
                status += " (not promised)"
            cells.append(f"{status}: {check.get('detail', '')}")
        lines.append(f"| `{name}` | {cells[0]} | {cells[1]} |")
    return lines


def render_summary(document: dict[str, Any]) -> list[str]:
    """Counts of faster, slower and within-noise cases, and failed promised checks."""
    counts = {"faster": 0, "slower": 0, "within noise": 0}
    failures: list[str] = []
    for workload in document["workloads"]:
        kit_cases = case_index(workload["sides"].get("moltencodes", {}))
        ace_cases = case_index(workload["sides"].get("ace3", {}))
        for name in ordered_case_names(workload):
            verdict = verdict_of(kit_cases.get(name), ace_cases.get(name))
            if verdict is not None:
                counts[verdict] += 1
        for side in SIDES:
            for check in workload["sides"].get(side, {}).get("checks", []):
                if check.get("promised", True) and not check.get("passed"):
                    failures.append(f"{workload['name']} / {SIDE_TITLES[side]} / `{check['name']}`")
    lines = [
        f"Comparable cases: MoltenCodes faster in {counts['faster']}, slower in "
        f"{counts['slower']}, within noise in {counts['within noise']}.",
    ]
    if failures:
        lines.append("Failed checks of promised behaviour: " + ", ".join(failures) + ".")
    else:
        lines.append("Every check of promised behaviour passed on both sides.")
    return lines


def format_load(values: Any) -> str:
    """Load averages as `1.00 / 2.00 / 3.00`, or an em dash."""
    if not isinstance(values, list) or not values:
        return "—"
    return " / ".join(f"{value:.2f}" for value in values)


def render_environment(document: dict[str, Any]) -> list[str]:
    """The table of what the numbers were measured on."""
    machine = document.get("host", {})
    settings = document.get("settings", {})
    repository = document.get("moltencodes", {})
    ace = document.get("ace3", {})
    memory = machine.get("memoryBytes")
    modified = repository.get("packagesModified")
    rows = [
        ("Kind", f"{document.get('kind')} (host Lua; never mixed with in-client results)"),
        ("Date", document.get("date")),
        ("CPU", f"{machine.get('cpu')} ({machine.get('logicalCpus')} logical CPUs)"),
        ("Memory", f"{memory / 2**30:.0f} GiB" if isinstance(memory, (int, float)) else "—"),
        ("OS", f"{machine.get('os')}, {machine.get('architecture')}"),
        ("Lua", document.get("lua", {}).get("version")),
        (
            "Batches",
            f"{settings.get('rounds', 1)} round(s) per case and side, each a fresh process with "
            f"{settings.get('warmupBatches')} warm-up, {settings.get('timedBatches')} timed "
            f"and 1 allocation batch",
        ),
        ("Clock", settings.get("clock")),
        (
            "Load average (1, 5, 15 min)",
            f"{format_load(settings.get('loadAverageAtStart'))} at the start, "
            f"{format_load(settings.get('loadAverageAtEnd'))} at the end",
        ),
        (
            "Empty loop iteration",
            f"{settings.get('loopOverheadNanoseconds')} ns (included in every ns/op)",
        ),
        (
            "MoltenCodes",
            f"commit `{repository.get('commit')}`"
            + (
                ""
                if modified is None
                else (", packages/ modified" if modified else ", packages/ unmodified")
            ),
        ),
        ("Ace3", f"`{ace.get('repository')}` commit `{ace.get('commit')}`"),
        ("Command", f"`{document.get('command')}`"),
    ]
    return ["| | |", "|---|---|", *(f"| {name} | {value} |" for name, value in rows)]


def render(document: dict[str, Any]) -> str:
    """The whole report."""
    if document.get("kind", "host") != "host":
        raise ReportError(
            f"this is a {document.get('kind')!r} results file; host and client results are never "
            "rendered together: render it with python3 -m tooling.bench.client_report --render"
        )
    if document.get("schema") != RESULTS_SCHEMA:
        raise ReportError(
            f"unsupported results schema {document.get('schema')!r}; expected {RESULTS_SCHEMA}"
        )
    if not isinstance(document.get("workloads"), list):
        raise ReportError("the results file has no workloads")
    lines = ["### Environment", "", *render_environment(document), "", "### Summary", ""]
    lines.extend(render_summary(document))
    for workload in document["workloads"]:
        lines.extend(["", f"### {workload['title']}", "", f"{workload['compares']}.", ""])
        lines.append(f"Libraries: {render_libraries(workload)}.")
        lines.extend(["", *render_timing_table(workload)])
        metrics = render_metrics(workload)
        if metrics:
            lines.extend(["", "Other measurements:", "", *metrics])
        checks = render_checks(workload)
        if checks:
            lines.extend(["", "Checks:", "", *checks])
    return "\n".join(lines) + "\n"


def parse_args(argv: Sequence[str] | None = None) -> argparse.Namespace:
    """Parse the command line."""
    parser = argparse.ArgumentParser(
        prog="python3 -m tooling.bench.report",
        description="Render a raw benchmark results file (from tooling.bench.run) as Markdown.",
    )
    parser.add_argument("results", type=Path, help="the results JSON file")
    parser.add_argument(
        "--out", type=Path, default=None, help="write the Markdown here (default: standard output)"
    )
    return parser.parse_args(argv)


def main(argv: Sequence[str] | None = None) -> int:
    """Render the report."""
    arguments = parse_args(argv)
    try:
        document = json.loads(arguments.results.read_text(encoding="utf-8"))
        text = render(document)
    except (OSError, ValueError, KeyError, TypeError, ReportError) as problem:
        print(f"error: {arguments.results}: {problem}", file=sys.stderr)
        return 1
    if arguments.out is None:
        sys.stdout.write(text)
    else:
        arguments.out.write_text(text, encoding="utf-8")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
