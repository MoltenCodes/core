"""Check that every client API a Kit uses exists on every promised flavour.

The framework promises three clients (`supported_clients.json`): Retail, Mists
of Pandaria Classic and Classic Era. Only Retail can be run by the maintainer,
so this gate is the standing evidence that the Kits also work on the others: for
every runtime package and every promised flavour, every host name a Kit reaches
must either exist in that flavour's captured client documentation
(`packages/apiKit/metadata/<flavour>/`) or be used only behind a test that
handles its absence.

    python3 -m tooling.validation.flavour_api [--package ID ...] [--verbose]

How a verdict is reached, per package, host name and flavour:

1. `tooling.validation.lua_references` finds every host reference in the
   package's `src/` and decides, per use, whether a test protects it.
2. The name is *present* when the flavour's metadata documents it (a global
   function, a namespace table, a namespaced function, an `Enum` table or
   field, a script-object method, an event), or when `host_names.json` lists
   it for that flavour: the Lua standard library the client ships, and client
   names the documentation leaves out, each with the evidence it was verified
   against.
3. A name that is not present passes when every use of it is protected
   (*guarded*), when every unprotected use has an `or` alternative the flavour
   provides (*fallback*), or when `flavour_api_allowlist.json` records a
   reviewed reason for exactly that package, name and flavour (*allow-listed*).
   Anything else is *missing*.

A missing reference fails the gate on a promised flavour. The captured test
flavours (PTR, beta) are reported and never fail, and a supported client with
no captured metadata (the Anniversary client) is named as not checked. A
promised client without captured metadata is itself a failure: the gate would
otherwise pass for want of evidence.

The allow-list is validated as strictly as the code: an entry whose package no
longer references the name, or whose name is now present or provably guarded
on a flavour it lists, is stale and fails the gate, so an entry can only exist
while it is needed.
"""

from __future__ import annotations

import argparse
import json
import sys
from dataclasses import dataclass, field
from pathlib import Path
from typing import Any, Iterable, Sequence

from tooling.api import flavours as api_flavours
from tooling.api.model import MetadataError, read_metadata
from tooling.validation import lua_references, lua_syntax
from tooling.validation.interface_numbers import (
    SupportedClientsError,
    load_supported_clients,
)
from tooling.validation.validate_manifests import ROOT, package_directories


#: Where the captured metadata of each flavour lives.
METADATA_DIRECTORY = ROOT / "packages" / "apiKit" / "metadata"

#: Names the documentation does not describe: see the module docstring.
HOST_NAMES_PATH = Path(__file__).resolve().parent / "host_names.json"

#: Reviewed exceptions: see the module docstring.
ALLOWLIST_PATH = Path(__file__).resolve().parent / "flavour_api_allowlist.json"

#: The apiKit flavour whose metadata describes each supported client, keyed by
#: the client's packager TOC suffix in `supported_clients.json`. `None` means
#: no metadata is captured for that client. A supported client missing from
#: this table is an error, so a newly added client cannot go unchecked.
CLIENT_FLAVOURS: dict[str, str | None] = {
    "_Mainline": "retail",
    "_Mists": "classic-mop",
    "_Vanilla": "classic-era",
    "_TBC": None,
}

#: The flavour ids the gate reports on without ever failing.
REPORT_ONLY_FLAVOURS = ("ptr", "beta")

#: Verdicts, from best to worst.
PRESENT = "present"
GUARDED = "guarded"
FALLBACK = "fallback"
ALLOWED = "allow-listed"
MISSING = "missing"
VERDICT_ORDER = (PRESENT, GUARDED, FALLBACK, ALLOWED, MISSING)


class GateError(ValueError):
    """The inputs of the gate (tables, metadata, sources) cannot be read."""


# Flavour surfaces ---------------------------------------------------------------


@dataclass(frozen=True)
class FlavourSurface:
    """Every name one flavour provides, as the gate looks them up."""

    flavour: str
    names: frozenset[str]
    widget_methods: frozenset[str]
    events: frozenset[str]

    def provides(self, kind: str, name: str) -> bool:
        """Whether the flavour provides the reference `name` of `kind`."""
        if kind == lua_references.KIND_METHOD:
            return name in self.widget_methods
        if kind == lua_references.KIND_EVENT:
            return name in self.events
        if kind == lua_references.KIND_DYNAMIC:
            return False
        return name in self.names


def metadata_surface(flavour: str, directory: Path = METADATA_DIRECTORY) -> FlavourSurface:
    """Read one flavour's documented names from its captured metadata.

    Global functions and namespaces come from the systems, `Enum.<Name>.<Field>`
    from the enumerations and `Constants.<Table>.<Value>` from the constants
    tables; script-object methods and events are kept apart because they are
    looked up by bare name.
    """
    try:
        metadata = read_metadata(directory / flavour)
    except MetadataError as failure:
        raise GateError(str(failure)) from None
    names: set[str] = set()
    methods: set[str] = set()
    for namespace in metadata.namespaces:
        if namespace.kind == "object":
            methods.update(function.name for function in namespace.functions)
            continue
        if namespace.kind == "namespace" and namespace.blizzard_namespace:
            names.add(namespace.blizzard_namespace)
        for function in namespace.functions:
            if not function.binding:
                continue
            names.add(function.binding)
            table, separator, _ = function.binding.rpartition(".")
            if separator:
                names.add(table)
    if metadata.enums:
        names.add("Enum")
    for enum in metadata.enums:
        names.add(f"Enum.{enum.name}")
        names.update(f"Enum.{enum.name}.{member.name}" for member in enum.fields)
    if metadata.constants:
        names.add("Constants")
    for table in metadata.constants:
        names.add(f"Constants.{table.name}")
        names.update(f"Constants.{table.name}.{value.name}" for value in table.values)
    events = frozenset(event.literal_name for event in metadata.events)
    return FlavourSurface(flavour, frozenset(names), frozenset(methods), events)


# The curated names table ------------------------------------------------------------


@dataclass(frozen=True)
class HostNames:
    """`host_names.json`: framework globals and names the metadata omits."""

    framework: frozenset[str]
    lua: frozenset[str]
    client: dict[str, frozenset[str]]

    def provided_on(self, flavour: str) -> frozenset[str]:
        """The names this table asserts exist on `flavour`."""
        extra = {name for name, flavours in self.client.items() if flavour in flavours}
        return self.lua | frozenset(extra)


def _require(condition: bool, where: str, message: str) -> None:
    if not condition:
        raise GateError(f"{where}: {message}")


def parse_host_names(data: Any, known_flavours: Iterable[str], where: str = "host_names.json") -> HostNames:
    """Validate and read the curated names table."""
    known = set(known_flavours)
    _require(isinstance(data, dict), where, "expected an object")
    for key in ("verified", "framework", "lua", "client"):
        _require(key in data, where, f"missing key {key!r}")
    framework = data["framework"]
    _require(
        isinstance(framework, dict) and _non_empty(framework.get("reason")),
        where,
        "framework needs a non-empty reason",
    )
    lua = data["lua"]
    _require(isinstance(lua, dict) and _non_empty(lua.get("source")), where, "lua needs a non-empty source")
    framework_names = _string_list(framework.get("names"), f"{where}: framework.names")
    lua_names = _string_list(lua.get("names"), f"{where}: lua.names")
    client: dict[str, frozenset[str]] = {}
    _require(isinstance(data["client"], list), where, "client must be a list")
    for index, entry in enumerate(data["client"]):
        entry_where = f"{where}: client[{index}]"
        _require(isinstance(entry, dict), entry_where, "expected an object")
        name = entry.get("name")
        _require(isinstance(name, str) and bool(name), entry_where, "needs a name")
        _require(name not in client and name not in lua_names, entry_where, f"{name} is listed twice")
        _require(_non_empty(entry.get("source")), entry_where, "needs a non-empty source")
        evidence = entry.get("evidence")
        _require(isinstance(evidence, dict) and bool(evidence), entry_where, "needs evidence per flavour")
        for flavour, location in evidence.items():
            _require(flavour in known, entry_where, f"unknown flavour {flavour!r}")
            _require(_non_empty(location), entry_where, "empty evidence")
        client[name] = frozenset(evidence)
    return HostNames(frozenset(framework_names), frozenset(lua_names), client)


def _non_empty(value: Any) -> bool:
    """Whether `value` is a string with something other than whitespace in it."""
    return isinstance(value, str) and bool(value.strip())


def _string_list(value: Any, where: str) -> list[str]:
    _require(
        isinstance(value, list) and all(_non_empty(item) for item in value), where, "expected a list of names"
    )
    _require(len(set(value)) == len(value), where, "a name is listed twice")
    return list(value)


def load_host_names(known_flavours: Iterable[str], path: Path = HOST_NAMES_PATH) -> HostNames:
    """Read `host_names.json`."""
    return parse_host_names(_read_json(path), known_flavours, path.name)


# The allow-list ------------------------------------------------------------------------


@dataclass(frozen=True)
class AllowEntry:
    """One reviewed exception: a package may use `api` unguarded on `flavours`."""

    package: str
    api: str
    flavours: tuple[str, ...]
    guard: str
    reason: str
    index: int

    @property
    def label(self) -> str:
        return f"allow-list entry {self.index + 1} ({self.package}: {self.api})"


def parse_allowlist(
    data: Any, known_flavours: Iterable[str], where: str = "flavour_api_allowlist.json"
) -> list[AllowEntry]:
    """Validate the shape of the allow-list; staleness is checked after the analysis."""
    known = set(known_flavours)
    _require(
        isinstance(data, dict) and isinstance(data.get("entries"), list), where, 'expected {"entries": [...]}'
    )
    entries: list[AllowEntry] = []
    seen: set[tuple[str, str]] = set()
    for index, entry in enumerate(data["entries"]):
        entry_where = f"{where}: entry {index + 1}"
        _require(isinstance(entry, dict), entry_where, "expected an object")
        unknown_keys = set(entry) - {"package", "api", "flavours", "guard", "reason"}
        _require(not unknown_keys, entry_where, f"unknown key(s) {', '.join(sorted(unknown_keys))}")
        for key in ("package", "api", "guard", "reason"):
            _require(_non_empty(entry.get(key)), entry_where, f"{key} must be a non-empty string")
        listed = entry.get("flavours")
        _require(
            isinstance(listed, list) and bool(listed) and all(isinstance(item, str) for item in listed),
            entry_where,
            "flavours must be a non-empty list",
        )
        for flavour in listed:
            _require(flavour in known, entry_where, f"unknown flavour {flavour!r}")
        _require(len(set(listed)) == len(listed), entry_where, "a flavour is listed twice")
        key = (entry["package"], entry["api"])
        _require(key not in seen, entry_where, f"duplicate entry for {entry['package']}: {entry['api']}")
        seen.add(key)
        entries.append(
            AllowEntry(entry["package"], entry["api"], tuple(listed), entry["guard"], entry["reason"], index)
        )
    return entries


def load_allowlist(known_flavours: Iterable[str], path: Path = ALLOWLIST_PATH) -> list[AllowEntry]:
    """Read `flavour_api_allowlist.json`."""
    return parse_allowlist(_read_json(path), known_flavours, path.name)


def _read_json(path: Path) -> Any:
    try:
        return json.loads(path.read_text(encoding="utf-8"))
    except OSError as failure:
        raise GateError(f"{path}: cannot be read ({failure.strerror})") from None
    except json.JSONDecodeError as failure:
        raise GateError(f"{path}: invalid JSON ({failure})") from None


# Scanning packages -----------------------------------------------------------------------


def excluded_sources(root: Path = ROOT) -> dict[Path, str]:
    """Runtime files the gate does not scan, each with the reason.

    The apiKit flavour files are generated from each flavour's own metadata,
    loaded only on that flavour, and only alias host functions (a missing one
    binds `nil`); `python3 -m tooling.api.generate --check` keeps them equal to
    the metadata.
    """
    table = api_flavours.load_flavours()
    source = root / "packages" / "apiKit" / "src"
    reason = "generated apiKit bindings for one flavour, checked by tooling.api.generate --check"
    return {source / flavour.runtime_file: reason for flavour in table.flavours}


def package_sources(package_dir: Path, excluded: dict[Path, str]) -> list[Path]:
    """The runtime Lua files of one package, excluded files left out."""
    return sorted(path for path in (package_dir / "src").rglob("*.lua") if path not in excluded)


def scan_package(
    package_dir: Path,
    excluded: dict[Path, str],
    widget_methods: frozenset[str],
    events: frozenset[str],
    root: Path = ROOT,
) -> list[lua_references.Reference]:
    """Every host reference in one package's runtime sources."""
    references: list[lua_references.Reference] = []
    for path in package_sources(package_dir, excluded):
        relative = path.relative_to(root).as_posix()
        try:
            chunk = lua_syntax.parse_file(path, relative)
        except lua_syntax.LuaSyntaxError as failure:
            raise GateError(str(failure)) from None
        references.extend(lua_references.analyse(chunk, relative, widget_methods, events))
    return references


def root_name(name: str) -> str:
    """The global a dotted or indexed name starts from: `MoltenCodes.Registry` -> `MoltenCodes`."""
    for separator in (".", "[", "("):
        name = name.split(separator, 1)[0]
    return name


# Verdicts ------------------------------------------------------------------------------------


@dataclass
class Finding:
    """Everything the gate knows about one host name in one package."""

    package: str
    kind: str
    name: str
    references: list[lua_references.Reference] = field(default_factory=list)
    #: Verdict per flavour id.
    verdicts: dict[str, str] = field(default_factory=dict)
    #: The allow-list entry used, when one is.
    allowed_by: AllowEntry | None = None

    @property
    def first_location(self) -> str:
        return self.references[0].location

    def unguarded_locations(self) -> list[str]:
        """`file:line` of every unprotected use, for the report."""
        locations: list[str] = []
        for reference in self.references:
            for use in reference.unguarded_uses:
                location = f"{reference.file}:{use.line} ({use.reason})"
                if location not in locations:
                    locations.append(location)
        return locations


def judge(
    finding: Finding,
    flavour: str,
    provided: set[str] | frozenset[str],
    surface: FlavourSurface,
) -> str:
    """The verdict for one finding on one flavour, before the allow-list."""

    def available(kind: str, name: str) -> bool:
        return name in provided or surface.provides(kind, name)

    if finding.kind != lua_references.KIND_DYNAMIC and available(finding.kind, finding.name):
        return PRESENT
    unprotected = [use for reference in finding.references for use in reference.unguarded_uses]
    if not unprotected:
        return GUARDED
    for use in unprotected:
        alternatives = [name for name in use.alternatives if name != finding.name]
        if not any(available(_kind_of(name, finding.kind), name) for name in alternatives):
            return MISSING
    return FALLBACK


def _kind_of(name: str, default: str) -> str:
    """The kind an `or` alternative is looked up as: dotted names are members."""
    if default in (lua_references.KIND_EVENT, lua_references.KIND_METHOD):
        return default
    return lua_references.KIND_MEMBER if "." in name else lua_references.KIND_GLOBAL


@dataclass
class Report:
    """The result of one run."""

    promised: list[tuple[str, str]]
    report_only: list[tuple[str, str]]
    not_captured: list[str]
    findings: dict[str, list[Finding]]
    errors: list[str]

    def failures(self) -> list[tuple[Finding, str]]:
        """Every (finding, flavour) that is missing on a promised flavour."""
        promised = {flavour for flavour, _ in self.promised}
        return [
            (finding, flavour)
            for package in sorted(self.findings)
            for finding in self.findings[package]
            for flavour, verdict in sorted(finding.verdicts.items())
            if verdict == MISSING and flavour in promised
        ]

    @property
    def passed(self) -> bool:
        return not self.errors and not self.failures()


def resolve_flavours(
    known: Sequence[str],
) -> tuple[list[tuple[str, str]], list[tuple[str, str]], list[str], list[str]]:
    """Split the supported clients into promised, report-only and uncaptured flavours.

    Returns `(promised, report_only, not_captured, errors)`, the first two as
    `(flavour id, display name)`.
    """
    errors: list[str] = []
    try:
        clients = load_supported_clients()
    except (OSError, json.JSONDecodeError, SupportedClientsError) as failure:
        raise GateError(f"supported_clients.json: {failure}") from None
    promised: list[tuple[str, str]] = []
    not_captured: list[str] = []
    for client in clients.clients:
        if client.toc_suffix not in CLIENT_FLAVOURS:
            errors.append(
                f"supported client {client.flavour} ({client.toc_suffix}) has no entry in "
                "CLIENT_FLAVOURS in tooling/validation/flavour_api.py"
            )
            continue
        flavour = CLIENT_FLAVOURS[client.toc_suffix]
        if flavour is None or flavour not in known:
            if client.promised:
                errors.append(
                    f"promised client {client.flavour} has no captured apiKit metadata to check against"
                )
            else:
                not_captured.append(client.flavour)
            continue
        if client.promised:
            promised.append((flavour, client.flavour))
        else:
            not_captured.append(client.flavour)
    display = {flavour.id: flavour.display_name for flavour in api_flavours.load_flavours().flavours}
    report_only = [
        (flavour, display.get(flavour, flavour)) for flavour in REPORT_ONLY_FLAVOURS if flavour in known
    ]
    return promised, report_only, not_captured, errors


def run_gate(packages: Sequence[str] | None = None) -> Report:
    """Scan the packages, judge every reference on every flavour, apply the allow-list."""
    table = api_flavours.load_flavours()
    known = [flavour for flavour in table.ids() if (METADATA_DIRECTORY / flavour).is_dir()]
    promised, report_only, not_captured, errors = resolve_flavours(known)
    checked = [flavour for flavour, _ in promised] + [flavour for flavour, _ in report_only]
    host_names = load_host_names(table.ids())
    allowlist = load_allowlist(table.ids())

    surfaces = {flavour: metadata_surface(flavour) for flavour in checked}
    widget_methods = frozenset().union(*(surface.widget_methods for surface in surfaces.values()))
    events = frozenset().union(*(surface.events for surface in surfaces.values()))
    excluded = excluded_sources()

    directories = {path.name: path for path in package_directories()}
    selected = sorted(directories) if not packages else list(packages)
    for package in selected:
        if package not in directories:
            errors.append(f"unknown package {package!r}")
    findings: dict[str, list[Finding]] = {}
    for package in selected:
        if package not in directories:
            continue
        references = scan_package(directories[package], excluded, widget_methods, events)
        findings[package] = _group(package, references, host_names.framework)

    for package, package_findings in findings.items():
        for finding in package_findings:
            for flavour in checked:
                provided = host_names.provided_on(flavour)
                finding.verdicts[flavour] = judge(finding, flavour, provided, surfaces[flavour])

    errors.extend(apply_allowlist(allowlist, findings, selected if packages else None))
    return Report(promised, report_only, not_captured, findings, errors)


def _group(
    package: str, references: list[lua_references.Reference], framework: frozenset[str]
) -> list[Finding]:
    """One `Finding` per host name, framework globals left out."""
    grouped: dict[tuple[str, str], Finding] = {}
    for reference in references:
        if root_name(reference.name) in framework:
            continue
        key = (reference.kind, reference.name)
        finding = grouped.get(key)
        if finding is None:
            finding = grouped[key] = Finding(package, reference.kind, reference.name)
        finding.references.append(reference)
    return sorted(grouped.values(), key=lambda finding: (finding.name, finding.kind))


def apply_allowlist(
    entries: list[AllowEntry],
    findings: dict[str, list[Finding]],
    selected: Sequence[str] | None,
    root: Path = ROOT,
) -> list[str]:
    """Turn allow-listed misses into `ALLOWED`; return every stale or invalid entry.

    With `selected` (a `--package` run) entries of other packages are not
    judged, since their packages were not scanned.
    """
    errors: list[str] = []
    for entry in entries:
        if selected is not None and entry.package not in selected:
            continue
        errors.extend(_check_guard_location(entry, root))
        if entry.package not in findings:
            errors.append(f"{entry.label}: no package {entry.package!r}")
            continue
        matching = [finding for finding in findings[entry.package] if finding.name == entry.api]
        if not matching:
            errors.append(f"{entry.label}: stale, {entry.package} no longer references {entry.api}")
            continue
        for flavour in entry.flavours:
            used = False
            for finding in matching:
                if finding.verdicts.get(flavour) == MISSING:
                    finding.verdicts[flavour] = ALLOWED
                    finding.allowed_by = entry
                    used = True
            if not used:
                verdicts = sorted({finding.verdicts.get(flavour, "not checked") for finding in matching})
                errors.append(
                    f"{entry.label}: stale for {flavour}, where {entry.api} is now {', '.join(verdicts)}"
                )
    return errors


def _check_guard_location(entry: AllowEntry, root: Path) -> list[str]:
    """The guard must name a line of a runtime file of the entry's own package."""
    file, separator, line = entry.guard.rpartition(":")
    if not separator or not line.isdigit():
        return [f"{entry.label}: guard must be 'path:line', not {entry.guard!r}"]
    prefix = f"packages/{entry.package}/src/"
    if not file.startswith(prefix):
        return [f"{entry.label}: guard {entry.guard} is not in {prefix}"]
    path = root / file
    if not path.is_file():
        return [f"{entry.label}: guard file {file} does not exist"]
    line_count = len(path.read_text(encoding="utf-8").splitlines())
    if not 1 <= int(line) <= line_count:
        return [f"{entry.label}: guard line {line} is outside {file} ({line_count} lines)"]
    return []


# Output ------------------------------------------------------------------------------------------


def format_report(report: Report, verbose: bool = False) -> list[str]:
    """The human-readable report, one string per line."""
    flavours = report.promised + report.report_only
    width = max((len(flavour) for flavour, _ in flavours), default=0)
    lines = [
        "Client API availability per flavour",
        "  promised:     " + _flavour_list(report.promised),
        "  report only:  " + _flavour_list(report.report_only),
        "  not captured: " + (", ".join(report.not_captured) or "none"),
        "",
    ]
    promised = {flavour for flavour, _ in report.promised}
    for package in sorted(report.findings):
        findings = report.findings[package]
        lines.append(f"{package} ({len(findings)} host name(s))")
        for flavour, _ in flavours:
            counts = {verdict: 0 for verdict in VERDICT_ORDER}
            for finding in findings:
                counts[finding.verdicts[flavour]] += 1
            summary = ", ".join(f"{verdict} {counts[verdict]}" for verdict in VERDICT_ORDER)
            marker = "" if flavour in promised else "  (report only)"
            lines.append(f"  {flavour.ljust(width)}  {summary}{marker}")
            for finding in findings:
                lines.extend(_detail_lines(finding, flavour, verbose))
        lines.append("")
    failures = report.failures()
    for error in report.errors:
        lines.append(f"error: {error}")
    if report.passed:
        lines.append("Result: passed. Every host reference is present or handled on every promised flavour.")
    else:
        lines.append(
            f"Result: FAILED. {len(failures)} missing reference(s) on promised flavours, "
            f"{len(report.errors)} error(s)."
        )
        if failures:
            lines.append(
                "Guard each missing use (a type or nil test, a ClientKit capability, a flavour branch), "
                "or, when the code handles the absence in a way this check cannot prove, add a reviewed "
                "entry to tooling/validation/flavour_api_allowlist.json (see docs/TOOLING.md)."
            )
    return lines


def _flavour_list(flavours: list[tuple[str, str]]) -> str:
    return ", ".join(f"{name} ({flavour})" for flavour, name in flavours) or "none"


def _detail_lines(finding: Finding, flavour: str, verbose: bool) -> list[str]:
    verdict = finding.verdicts[flavour]
    if verdict == PRESENT or (verdict in (GUARDED, FALLBACK) and not verbose):
        return []
    label = f"{finding.kind} {finding.name}"
    if verdict == MISSING:
        lines = [f"    MISSING       {label}"]
        indent = " " * 18
        lines.extend(f"{indent}unguarded use at {location}" for location in finding.unguarded_locations())
        return lines
    if verdict == ALLOWED and finding.allowed_by is not None:
        return [f"    allow-listed  {label} (guard {finding.allowed_by.guard}: {finding.allowed_by.reason})"]
    return [f"    {verdict.ljust(13)} {label} ({finding.first_location})"]


def parse_args(argv: Sequence[str] | None = None) -> argparse.Namespace:
    parser = argparse.ArgumentParser(
        prog="python3 -m tooling.validation.flavour_api",
        description=(
            "Check that every client API each runtime package uses exists on every promised client "
            "flavour, or is guarded against its absence."
        ),
    )
    parser.add_argument(
        "--package",
        action="append",
        metavar="ID",
        help="check only this package (repeatable); allow-list entries of other packages are not judged",
    )
    parser.add_argument(
        "--verbose",
        action="store_true",
        help="also list guarded and fallback references, not only missing and allow-listed ones",
    )
    return parser.parse_args(argv)


def main(argv: Sequence[str] | None = None) -> int:
    """Run the gate and print the report; exit 1 on a missing reference or an invalid input."""
    arguments = parse_args(argv)
    try:
        report = run_gate(arguments.package)
    except GateError as failure:
        print(f"error: {failure}", file=sys.stderr)
        return 1
    stream = sys.stdout if report.passed else sys.stderr
    for line in format_report(report, arguments.verbose):
        print(line, file=stream)
    return 0 if report.passed else 1


if __name__ == "__main__":
    raise SystemExit(main())
