"""Compare two captures of one flavour's apiKit metadata.

    python3 -m tooling.api.diff OLD_DIR NEW_DIR [--report PATH]

`docs/API_KIT_DESIGN.md` (section 11) makes API availability versioned data:
the pipeline (section 14, step 3) compares each new capture with the
committed one and records what appeared, what disappeared and what changed
its signature. This module is that comparison, the Markdown change report
written to `packages/apiKit/docs/changes/<flavour>/<from>-<to>.md`, and the
per-flavour history file the pipeline appends to.

Rules the comparison follows, so that a report reads the way a consumer of
the wrapper experiences the change:

- Entries are matched by the identity a consumer types: namespaces by
  wrapper, functions by `namespace.function` wrapper, events by their literal
  name, enums, structures, callbacks and constants tables by their Blizzard
  name, enum fields and constants by the parent name plus their own,
  restrictions by system and name. A renamed wrapper is therefore a removal
  plus an addition, because code that used the old name stops working.
- Children are compared on their own, across the whole flavour: a new
  namespace lists every function it brings, a removed enum lists every field
  that went with it. Counts then tell the whole story, not only the parents.
- Every field of an entry except its documentation and its source file is a
  code-level fact; when only documentation differs the entry is reported as
  changed with the single detail "documentation changed", because hover text
  matters to a reader but not to a program. Provenance differences are never
  changes.
- The change list is totally ordered (kind, change, name), the report is
  rendered from it without any other input, and the history file is written
  with `model.dump_json`, so the same two captures always yield the same
  bytes.
"""

from __future__ import annotations

import argparse
import dataclasses
import json
import sys
from dataclasses import dataclass
from pathlib import Path
from typing import Any, Sequence

from tooling.api import model
from tooling.api.model import FlavourMetadata, Parameter, Provenance


#: The kinds of entry a change can concern, in the order the report lists them.
KINDS = (
    "namespace",
    "function",
    "event",
    "enum",
    "enumField",
    "structure",
    "callback",
    "constantsTable",
    "constant",
    "restriction",
)

#: The three things that can happen to an entry, in report order.
CHANGE_ORDER = ("added", "removed", "changed")

#: How each kind is titled in the report.
KIND_TITLES = {
    "namespace": "Namespaces",
    "function": "Functions",
    "event": "Events",
    "enum": "Enums",
    "enumField": "Enum fields",
    "structure": "Structures",
    "callback": "Callbacks",
    "constantsTable": "Constants tables",
    "constant": "Constants",
    "restriction": "Restrictions",
}

#: The per-flavour history file, kept beside the flavour's metadata.
HISTORY_FILE = "history.json"

#: Version of the history file's shape; bumped with the same rule as the metadata schema.
HISTORY_SCHEMA_VERSION = 1

#: The detail an entry carries when only its documentation differs.
DOCUMENTATION_ONLY = "documentation changed"

#: How many characters of a commit identify a capture when its build is unknown.
SHORT_COMMIT_LENGTH = 12

#: The arrow between an old and a new value in a detail sentence.
ARROW = "→"


@dataclass(frozen=True)
class Change:
    """One difference between two captures.

    `kind` is one of `KINDS`, `change` one of `CHANGE_ORDER`, `name` the fully
    qualified identity a consumer would type (`addOnProfiler.measureCall`,
    `ADDON_LOADED`, `Enum.PhaseReason.Sharding`, `Constants.Auction.DEFAULT`,
    `AddOns/HasRestrictions`). `details` is one sentence per difference and
    is only filled for a changed entry.
    """

    kind: str
    change: str
    name: str
    details: tuple[str, ...] = ()

    def sort_key(self) -> tuple[int, int, str]:
        return (KINDS.index(self.kind), CHANGE_ORDER.index(self.change), self.name)


@dataclass(frozen=True)
class Diff:
    """The differences between two captures of one flavour, in report order."""

    old: Provenance
    new: Provenance
    changes: tuple[Change, ...]

    def is_empty(self) -> bool:
        return not self.changes

    def counts(self) -> dict[str, dict[str, int]]:
        """Count changes per kind, `{kind: {"added": n, "removed": n, "changed": n}}`.

        Kinds without any change are left out so the history stays short; a
        kind that appears carries all three numbers, zeros included, so a
        reader never has to guess at a missing key.
        """
        result: dict[str, dict[str, int]] = {}
        for change in self.changes:
            row = result.setdefault(change.kind, {name: 0 for name in CHANGE_ORDER})
            row[change.change] += 1
        return result


# --- Detail sentences -------------------------------------------------------


def _format(value: Any) -> str:
    """Write a value the way a Lua reader expects it inside a sentence."""
    if value is None:
        return "none"
    if isinstance(value, bool):
        return "true" if value else "false"
    if isinstance(value, str):
        return value
    return json.dumps(value, ensure_ascii=False)


def _differences(label: str, old_value: Any, new_value: Any) -> list[str]:
    """One sentence when two scalar values differ, none otherwise.

    An optional value that appears or disappears reads as "added"/"removed"
    rather than as a transition from "none", because that is how a reader
    thinks of a default or an alias.
    """
    if old_value == new_value:
        return []
    if old_value is None:
        return [f"{label} added: {_format(new_value)}"]
    if new_value is None:
        return [f"{label} removed: {_format(old_value)}"]
    return [f"{label} {_format(old_value)} {ARROW} {_format(new_value)}"]


def _flag_differences(label: str, old_flags: Sequence[str], new_flags: Sequence[str]) -> list[str]:
    """One sentence listing the flags that appeared (`+X`) and disappeared (`-Y`)."""
    added = sorted(set(new_flags) - set(old_flags))
    removed = sorted(set(old_flags) - set(new_flags))
    if not added and not removed:
        return []
    markers = [f"+{flag}" for flag in added] + [f"-{flag}" for flag in removed]
    return [f"{label}: {' '.join(markers)}"]


def _attribute_differences(label: str, old: dict[str, Any], new: dict[str, Any]) -> list[str]:
    """One sentence per attribute whose value appeared, disappeared or changed."""
    sentences: list[str] = []
    for key in sorted(set(old) | set(new)):
        sentences.extend(_differences(f"{label} {key}", old.get(key), new.get(key)))
    return sentences


def _default_differences(old: Parameter, new: Parameter) -> list[str]:
    """Describe a documented default appearing, disappearing or changing.

    `has_default` is tracked separately from `default` because `nil`, `false`
    and `0` are legitimate documented defaults; comparing the values alone
    would miss a default of `nil` appearing.
    """
    if old.has_default == new.has_default and old.default == new.default:
        return []
    if not old.has_default:
        return [f"default added: {_format(new.default)}"]
    if not new.has_default:
        return [f"default removed: {_format(old.default)}"]
    return [f"default {_format(old.default)} {ARROW} {_format(new.default)}"]


def _parameter_differences(old: Parameter, new: Parameter) -> list[str]:
    """The code-level differences of one parameter, without a label."""
    sentences: list[str] = []
    sentences.extend(_differences("type", old.type, new.type))
    sentences.extend(_differences("nilable", old.nilable, new.nilable))
    sentences.extend(_differences("innerType", old.inner_type, new.inner_type))
    sentences.extend(_differences("keyType", old.key_type, new.key_type))
    sentences.extend(_differences("mixin", old.mixin, new.mixin))
    sentences.extend(_differences("strideIndex", old.stride_index, new.stride_index))
    sentences.extend(_default_differences(old, new))
    sentences.extend(_flag_differences("flags", old.flags, new.flags))
    sentences.extend(_attribute_differences("attribute", old.attributes, new.attributes))
    return sentences


def _parameter_list_differences(
    label: str, old_list: Sequence[Parameter], new_list: Sequence[Parameter]
) -> list[str]:
    """Compare arguments, returns, payload or fields by parameter name.

    `label` is the singular noun ("argument", "return", "field"). Position
    matters for arguments and returns, so a reordering of the parameters both
    sides share is reported even when every parameter is otherwise the same.
    """
    old_by_name = {parameter.name: parameter for parameter in old_list}
    new_by_name = {parameter.name: parameter for parameter in new_list}
    sentences: list[str] = []
    for name in sorted(set(new_by_name) - set(old_by_name)):
        sentences.append(f"{label} {name} added: {new_by_name[name].type}")
    for name in sorted(set(old_by_name) - set(new_by_name)):
        sentences.append(f"{label} {name} removed: {old_by_name[name].type}")
    shared = set(old_by_name) & set(new_by_name)
    for name in sorted(shared):
        for sentence in _parameter_differences(old_by_name[name], new_by_name[name]):
            sentences.append(f"{label} {name}: {sentence}")
    old_order = [parameter.name for parameter in old_list if parameter.name in shared]
    new_order = [parameter.name for parameter in new_list if parameter.name in shared]
    if old_order != new_order:
        sentences.append(f"{label} order: {', '.join(old_order)} {ARROW} {', '.join(new_order)}")
    return sentences


# --- Comparing one kind -----------------------------------------------------


def _documentation_only(details: list[str], old: Any, new: Any) -> tuple[str, ...]:
    """Finish an entry's details: code differences win, else documentation.

    Two entries with the same code-level details are equal except for their
    documentation and their source file; dataclass equality catches a
    documentation change anywhere inside (a parameter's paragraph included)
    without listing every documentation field by hand.
    """
    if details:
        return tuple(details)
    old_without_source = _without_source(old)
    new_without_source = _without_source(new)
    if old_without_source != new_without_source:
        return (DOCUMENTATION_ONLY,)
    return ()


def _without_source(entry: Any) -> Any:
    """The entry with its source file blanked and its flags sorted.

    A table moving between files is not a change, and neither is the order of
    its flags: `_flag_differences` compares them as sets, so the equality
    fallback must not see an order the set comparison ignored. Parameters and
    fields are normalised the same way, recursively.
    """
    if not dataclasses.is_dataclass(entry):
        return entry
    changes: dict[str, Any] = {}
    for field in dataclasses.fields(entry):
        value = getattr(entry, field.name)
        if field.name == "source":
            changes[field.name] = ""
        elif field.name == "flags":
            changes[field.name] = tuple(sorted(value))
        elif isinstance(value, tuple) and value and dataclasses.is_dataclass(value[0]):
            changes[field.name] = tuple(_without_source(item) for item in value)
    return _replace(entry, **changes) if changes else entry


def _replace(entry: Any, **changes: Any) -> Any:
    """`dataclasses.replace` for entries whose children are compared separately."""
    return dataclasses.replace(entry, **changes)


def _compare_keyed(
    kind: str,
    old_entries: dict[str, Any],
    new_entries: dict[str, Any],
    describe: Any,
) -> list[Change]:
    """Turn two dictionaries keyed by identity into added, removed and changed entries.

    `describe(old, new)` returns the detail sentences of a shared entry; an
    empty result means the entry did not change.
    """
    changes: list[Change] = []
    for name in set(new_entries) - set(old_entries):
        changes.append(Change(kind, "added", name))
    for name in set(old_entries) - set(new_entries):
        changes.append(Change(kind, "removed", name))
    for name in set(old_entries) & set(new_entries):
        details = describe(old_entries[name], new_entries[name])
        if details:
            changes.append(Change(kind, "changed", name, tuple(details)))
    return changes


def _describe_namespace(old: model.Namespace, new: model.Namespace) -> tuple[str, ...]:
    details: list[str] = []
    details.extend(_differences("alias", old.alias, new.alias))
    details.extend(_differences("kind", old.kind, new.kind))
    details.extend(_differences("blizzardNamespace", old.blizzard_namespace, new.blizzard_namespace))
    details.extend(_differences("system", old.system, new.system))
    details.extend(_differences("objectType", old.object_type, new.object_type))
    details.extend(_differences("environment", old.environment, new.environment))
    # Functions are compared as their own entries; the namespace itself is
    # documentation-only when nothing above differs but its own paragraphs do.
    return _documentation_only(
        details, _replace(old, functions=(), sources=()), _replace(new, functions=(), sources=())
    )


def _describe_function(old: model.Function, new: model.Function) -> tuple[str, ...]:
    details: list[str] = []
    details.extend(_differences("name", old.name, new.name))
    details.extend(_differences("binding", old.binding, new.binding))
    details.extend(_parameter_list_differences("argument", old.arguments, new.arguments))
    details.extend(_parameter_list_differences("return", old.returns, new.returns))
    details.extend(_differences("secretArguments", old.secret_arguments, new.secret_arguments))
    details.extend(_differences("mayReturnNothing", old.may_return_nothing, new.may_return_nothing))
    details.extend(_differences("hasRestrictions", old.has_restrictions, new.has_restrictions))
    details.extend(_differences("isProtected", old.is_protected, new.is_protected))
    details.extend(_flag_differences("flags", old.flags, new.flags))
    details.extend(_attribute_differences("attribute", old.attributes, new.attributes))
    return _documentation_only(details, old, new)


def _describe_event(old: model.Event, new: model.Event) -> tuple[str, ...]:
    details: list[str] = []
    details.extend(_differences("name", old.name, new.name))
    details.extend(_differences("wrapper", old.wrapper, new.wrapper))
    details.extend(_differences("system", old.system, new.system))
    details.extend(_parameter_list_differences("payload", old.payload, new.payload))
    details.extend(_differences("synchronous", old.synchronous, new.synchronous))
    details.extend(_differences("unique", old.unique, new.unique))
    details.extend(_differences("callback", old.callback, new.callback))
    details.extend(_flag_differences("flags", old.flags, new.flags))
    details.extend(_attribute_differences("attribute", old.attributes, new.attributes))
    return _documentation_only(details, old, new)


def _describe_enum(old: model.Enum, new: model.Enum) -> tuple[str, ...]:
    details: list[str] = []
    details.extend(_differences("wrapper", old.wrapper, new.wrapper))
    details.extend(_differences("numValues", old.num_values, new.num_values))
    details.extend(_differences("minValue", old.min_value, new.min_value))
    details.extend(_differences("maxValue", old.max_value, new.max_value))
    details.extend(_differences("system", old.system, new.system))
    return _documentation_only(details, _replace(old, fields=()), _replace(new, fields=()))


def _describe_enum_field(old: model.EnumField, new: model.EnumField) -> tuple[str, ...]:
    return _documentation_only(_differences("value", old.value, new.value), old, new)


def _describe_structure(old: model.Structure, new: model.Structure) -> tuple[str, ...]:
    details: list[str] = []
    details.extend(_parameter_list_differences("field", old.fields, new.fields))
    details.extend(_differences("system", old.system, new.system))
    return _documentation_only(details, old, new)


def _describe_callback(old: model.Callback, new: model.Callback) -> tuple[str, ...]:
    details: list[str] = []
    details.extend(_parameter_list_differences("argument", old.arguments, new.arguments))
    details.extend(_parameter_list_differences("return", old.returns, new.returns))
    details.extend(_differences("system", old.system, new.system))
    return _documentation_only(details, old, new)


def _describe_constants_table(old: model.ConstantsTable, new: model.ConstantsTable) -> tuple[str, ...]:
    details: list[str] = []
    details.extend(_differences("wrapper", old.wrapper, new.wrapper))
    details.extend(_differences("system", old.system, new.system))
    return _documentation_only(details, _replace(old, values=()), _replace(new, values=()))


def _constant_text(constant: model.ConstantValue) -> str:
    if constant.expression is not None:
        return f"expression {constant.expression}"
    return f"value {_format(constant.value)}"


def _describe_constant(old: model.ConstantValue, new: model.ConstantValue) -> tuple[str, ...]:
    details: list[str] = []
    details.extend(_differences("type", old.type, new.type))
    both_literal = old.expression is None and new.expression is None
    both_expression = old.expression is not None and new.expression is not None
    if both_literal:
        details.extend(_differences("value", old.value, new.value))
    elif both_expression:
        details.extend(_differences("expression", old.expression, new.expression))
    else:
        details.append(f"{_constant_text(old)} {ARROW} {_constant_text(new)}")
    return _documentation_only(details, old, new)


def _describe_restriction(old: model.Restriction, new: model.Restriction) -> tuple[str, ...]:
    details: list[str] = []
    details.extend(_differences("kind", old.kind, new.kind))
    details.extend(_differences("failureMode", old.failure_mode, new.failure_mode))
    return _documentation_only(details, old, new)


# --- Identity keys ----------------------------------------------------------


def _namespaces_by_key(metadata: FlavourMetadata) -> dict[str, model.Namespace]:
    return {namespace.wrapper: namespace for namespace in metadata.namespaces}


def _functions_by_key(metadata: FlavourMetadata) -> dict[str, model.Function]:
    return {
        f"{namespace.wrapper}.{function.wrapper}": function
        for namespace in metadata.namespaces
        for function in namespace.functions
    }


def _events_by_key(metadata: FlavourMetadata) -> dict[str, model.Event]:
    return {event.literal_name: event for event in metadata.events}


def _enums_by_key(metadata: FlavourMetadata) -> dict[str, model.Enum]:
    return {f"Enum.{enum.name}": enum for enum in metadata.enums}


def _enum_fields_by_key(metadata: FlavourMetadata) -> dict[str, model.EnumField]:
    return {f"Enum.{enum.name}.{field.name}": field for enum in metadata.enums for field in enum.fields}


def _structures_by_key(metadata: FlavourMetadata) -> dict[str, model.Structure]:
    return {structure.name: structure for structure in metadata.structures}


def _callbacks_by_key(metadata: FlavourMetadata) -> dict[str, model.Callback]:
    return {callback.name: callback for callback in metadata.callbacks}


def _constants_tables_by_key(metadata: FlavourMetadata) -> dict[str, model.ConstantsTable]:
    return {f"Constants.{table.name}": table for table in metadata.constants}


def _constants_by_key(metadata: FlavourMetadata) -> dict[str, model.ConstantValue]:
    return {
        f"Constants.{table.name}.{constant.name}": constant
        for table in metadata.constants
        for constant in table.values
    }


def _restriction_key(restriction: model.Restriction) -> str:
    if restriction.system is None:
        return restriction.name
    return f"{restriction.system}/{restriction.name}"


def _restrictions_by_key(metadata: FlavourMetadata) -> dict[str, model.Restriction]:
    return {_restriction_key(restriction): restriction for restriction in metadata.restrictions}


#: For each kind: how to index a flavour's entries and how to describe a shared pair.
_COMPARISONS = (
    ("namespace", _namespaces_by_key, _describe_namespace),
    ("function", _functions_by_key, _describe_function),
    ("event", _events_by_key, _describe_event),
    ("enum", _enums_by_key, _describe_enum),
    ("enumField", _enum_fields_by_key, _describe_enum_field),
    ("structure", _structures_by_key, _describe_structure),
    ("callback", _callbacks_by_key, _describe_callback),
    ("constantsTable", _constants_tables_by_key, _describe_constants_table),
    ("constant", _constants_by_key, _describe_constant),
    ("restriction", _restrictions_by_key, _describe_restriction),
)


def diff_metadata(old: FlavourMetadata, new: FlavourMetadata) -> Diff:
    """Compare two captures of one flavour by the identity keys the module documents.

    Namespaces are matched by wrapper (a wrapper rename appears as removed
    plus added, which is the truth for a consumer), functions by namespace
    wrapper plus function wrapper, events by literal name, enums by name and
    their fields by field name, structures and callbacks by name (a field,
    argument or return change is a "changed" on the parent with details),
    constants tables by name and their values by value name, restrictions by
    system plus name. Every field except documentation and source counts as a
    code-level difference; a documentation-only difference is one detail,
    "documentation changed". Provenance differences are not changes.
    """
    changes: list[Change] = []
    for kind, index, describe in _COMPARISONS:
        changes.extend(_compare_keyed(kind, index(old), index(new), describe))
    changes.sort(key=Change.sort_key)
    return Diff(old=old.provenance, new=new.provenance, changes=tuple(changes))


# --- Report -----------------------------------------------------------------


def _build_label(provenance: Provenance) -> str:
    """The build number, or the short commit when the subject carried no build."""
    if provenance.build is not None:
        return str(provenance.build)
    return provenance.commit[:SHORT_COMMIT_LENGTH]


def _capture_label(provenance: Provenance) -> str:
    """`12.1.0 (69933)`, degrading to `unknown version (abcdef123456)`."""
    version = provenance.version if provenance.version is not None else "unknown version"
    return f"{version} ({_build_label(provenance)})"


def _render_title(diff: Diff) -> str:
    return f"# {diff.new.flavour}: {_capture_label(diff.old)} {ARROW} {_capture_label(diff.new)}"


def _render_provenance_table(diff: Diff) -> list[str]:
    rows = (
        ("Repository", diff.old.repository, diff.new.repository),
        ("Commit", diff.old.commit, diff.new.commit),
        ("Branch", diff.old.branch, diff.new.branch),
        ("Captured on", diff.old.captured_on, diff.new.captured_on),
    )
    lines = ["| | Old | New |", "|---|---|---|"]
    for label, old_value, new_value in rows:
        lines.append(f"| {label} | {old_value} | {new_value} |")
    return lines


def render_summary_table(diff: Diff) -> str:
    """The counts by kind as a Markdown table; the CLI prints the same text."""
    counts = diff.counts()
    lines = ["| Kind | Added | Removed | Changed |", "|---|---|---|---|"]
    for kind in KINDS:
        if kind not in counts:
            continue
        row = counts[kind]
        lines.append(f"| {KIND_TITLES[kind]} | {row['added']} | {row['removed']} | {row['changed']} |")
    return "\n".join(lines)


def _render_kind_section(kind: str, changes: Sequence[Change]) -> list[str]:
    lines = [f"## {KIND_TITLES[kind]}", ""]
    for change_name in CHANGE_ORDER:
        entries = [change for change in changes if change.change == change_name]
        if not entries:
            continue
        lines.append(f"### {change_name.capitalize()}")
        lines.append("")
        for entry in entries:
            lines.append(f"- `{entry.name}`")
            for detail in entry.details:
                lines.append(f"  - {detail}")
        lines.append("")
    return lines


def render_change_report(diff: Diff) -> str:
    """Render the Markdown change report; the same diff always gives the same text.

    The report opens with the title and the provenance of both sides so that
    a reader knows exactly which captures were compared, then the summary
    counts, then one section per kind with its added, removed and changed
    entries (details as sub-bullets). An empty diff keeps the title and the
    provenance and says in one paragraph that there are no differences.
    """
    lines = [_render_title(diff), ""]
    lines.extend(_render_provenance_table(diff))
    lines.append("")
    if diff.is_empty():
        lines.append("No API differences between the two captures.")
        return "\n".join(lines) + "\n"
    lines.append("## Summary")
    lines.append("")
    lines.append(render_summary_table(diff))
    lines.append("")
    for kind in KINDS:
        kind_changes = [change for change in diff.changes if change.kind == kind]
        if kind_changes:
            lines.extend(_render_kind_section(kind, kind_changes))
    return "\n".join(lines).rstrip("\n") + "\n"


def diff_file_name(diff: Diff) -> str:
    """`<old build>-<new build>.md`, with the short commit standing in for an unknown build."""
    return f"{_build_label(diff.old)}-{_build_label(diff.new)}.md"


# --- History ----------------------------------------------------------------


@dataclass(frozen=True)
class HistoryEntry:
    """One capture in a flavour's history, with the counts against the previous one.

    The first capture carries empty `counts` and no `report`: the history
    starts where this repository starts and earlier builds are not
    reconstructed (design document, section 11).
    """

    build: int | None
    version: str | None
    commit: str
    committed_at: str
    captured_on: str
    counts: dict[str, dict[str, int]]
    report: str | None

    @classmethod
    def from_provenance(
        cls, provenance: Provenance, counts: dict[str, dict[str, int]], report: str | None
    ) -> "HistoryEntry":
        """Build the entry for a capture; `report` is the relative path of its change report."""
        return cls(
            build=provenance.build,
            version=provenance.version,
            commit=provenance.commit,
            committed_at=provenance.committed_at,
            captured_on=provenance.captured_on,
            counts=counts,
            report=report,
        )

    def to_json(self) -> dict[str, Any]:
        return model.json_object(
            build=self.build,
            version=self.version,
            commit=self.commit,
            committedAt=self.committed_at,
            capturedOn=self.captured_on,
            counts=self.counts,
            report=self.report,
        )

    @classmethod
    def from_json(cls, data: dict[str, Any]) -> "HistoryEntry":
        return cls(
            build=data.get("build"),
            version=data.get("version"),
            commit=data["commit"],
            committed_at=data["committedAt"],
            captured_on=data["capturedOn"],
            counts=dict(data.get("counts", {})),
            report=data.get("report"),
        )


def history_to_json(entries: Sequence[HistoryEntry]) -> dict[str, Any]:
    """The history file's shape: `{"schema": 1, "entries": [...]}`, oldest first."""
    return {"schema": HISTORY_SCHEMA_VERSION, "entries": [entry.to_json() for entry in entries]}


def history_from_json(data: Any) -> list[HistoryEntry]:
    """Read the history file's shape back, refusing anything else with `MetadataError`."""
    if not isinstance(data, dict) or data.get("schema") != HISTORY_SCHEMA_VERSION:
        raise model.MetadataError(f"history: expected schema {HISTORY_SCHEMA_VERSION}")
    entries = data.get("entries")
    if not isinstance(entries, list):
        raise model.MetadataError("history: 'entries' must be a list")
    result: list[HistoryEntry] = []
    for position, item in enumerate(entries):
        if not isinstance(item, dict):
            raise model.MetadataError(f"history: entry {position} must be an object")
        try:
            result.append(HistoryEntry.from_json(item))
        except (KeyError, TypeError) as failure:
            raise model.MetadataError(f"history: entry {position} is malformed ({failure!r})") from None
    return result


def read_history(path: Path) -> list[HistoryEntry]:
    """Read a history file; a missing file is an empty history, a malformed one an error."""
    try:
        text = path.read_text(encoding="utf-8")
    except FileNotFoundError:
        return []
    try:
        data = json.loads(text)
    except json.JSONDecodeError as failure:
        raise model.MetadataError(f"{path}: not valid JSON ({failure})") from None
    return history_from_json(data)


# --- Command line -----------------------------------------------------------


def main(argv: Sequence[str] | None = None) -> int:
    """Diff two metadata directories, print the summary and optionally write the report.

    Exit status: 0 when both directories were read (even when they differ),
    1 when a directory cannot be read, 2 when the two provenances name
    different flavours, because comparing Retail with Classic would produce
    a report that is long, true and useless.
    """
    parser = argparse.ArgumentParser(
        prog="python3 -m tooling.api.diff",
        description="Compare two captures of one flavour's apiKit metadata.",
    )
    parser.add_argument("old_directory", type=Path, help="the metadata directory of the earlier capture")
    parser.add_argument("new_directory", type=Path, help="the metadata directory of the later capture")
    parser.add_argument("--report", type=Path, help="write the Markdown change report to this path")
    arguments = parser.parse_args(argv)

    try:
        old = model.read_metadata(arguments.old_directory)
        new = model.read_metadata(arguments.new_directory)
    except (OSError, ValueError) as failure:
        print(f"error: {failure}", file=sys.stderr)
        return 1
    if old.provenance.flavour != new.provenance.flavour:
        print(
            f"error: cannot compare flavour {old.provenance.flavour!r} with {new.provenance.flavour!r}",
            file=sys.stderr,
        )
        return 2

    diff = diff_metadata(old, new)
    print(_render_title(diff).lstrip("# "))
    if diff.is_empty():
        print("No API differences")
    else:
        print(render_summary_table(diff))
    if arguments.report is not None:
        arguments.report.parent.mkdir(parents=True, exist_ok=True)
        arguments.report.write_text(render_change_report(diff), encoding="utf-8")
        print(f"report: {arguments.report}")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
