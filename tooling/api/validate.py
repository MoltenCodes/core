"""Validate one flavour's apiKit metadata.

    python3 -m tooling.api.validate DIR

`DIR` is a metadata directory `tooling.api.normalize` wrote (or the committed
`packages/apiKit/metadata/<flavour>/`). The checks are the metadata-level
part of the design document's list (section 15): every wrapper name is
well-formed and unique where it must be, every binding is unique, every type
a parameter names resolves to something this flavour defines or to the host
type table, enumerations agree with their own counts, and the flavour named
in the provenance is one the flavour table knows. The normaliser runs the
same checks before it writes, so a committed directory that passes here is
one the generators can trust.

Checks that need the generated outputs (malformed Lua, malformed JSON,
wrapper-to-raw mapping in the runtime file) live with the generators.
"""

from __future__ import annotations

import argparse
import sys
from collections import Counter, defaultdict
from pathlib import Path
from typing import Iterable, Sequence

from tooling.api import flavours, model
from tooling.api.model import FlavourMetadata, HostTypes, Parameter
from tooling.api.naming import LUA_KEYWORDS, WRAPPER_NAME_RE

#: Wrapper names the flavour table itself uses; no namespace may take them.
RESERVED_WRAPPER_NAMES = frozenset({"events", "enums", "constants"})


def _duplicates(values: Iterable[str]) -> list[str]:
    counts = Counter(values)
    return sorted(value for value, count in counts.items() if count > 1)


def _wrapper_problem(wrapper: str) -> str | None:
    """Why `wrapper` cannot be a wrapper name, or `None` when it can."""
    if not WRAPPER_NAME_RE.fullmatch(wrapper):
        return "is not lowerCamelCase"
    if wrapper in LUA_KEYWORDS:
        return "is a Lua keyword; add an exception to naming.json"
    return None


def _check_wrapper_names(metadata: FlavourMetadata) -> list[str]:
    problems: list[str] = []
    for namespace in metadata.namespaces:
        reason = _wrapper_problem(namespace.wrapper)
        if reason:
            problems.append(f"namespace {namespace.system}: wrapper {namespace.wrapper!r} {reason}")
        alias_reason = _wrapper_problem(namespace.alias) if namespace.alias is not None else None
        if alias_reason:
            problems.append(f"namespace {namespace.wrapper}: alias {namespace.alias!r} {alias_reason}")
        for function in namespace.functions:
            reason = _wrapper_problem(function.wrapper)
            if reason:
                problems.append(f"{namespace.wrapper}.{function.name}: wrapper {function.wrapper!r} {reason}")
    for label, entries in (("event", metadata.events), ("enum", metadata.enums), ("constants table", metadata.constants)):
        for entry in entries:
            reason = _wrapper_problem(entry.wrapper)
            if reason:
                problems.append(f"{label} {entry.name}: wrapper {entry.wrapper!r} {reason}")
    return problems


def _check_uniqueness(metadata: FlavourMetadata) -> list[str]:
    problems: list[str] = []
    namespace_names = [namespace.wrapper for namespace in metadata.namespaces]
    for wrapper in _duplicates(namespace_names):
        problems.append(f"namespace wrapper {wrapper!r} is used twice")
    for namespace in metadata.namespaces:
        for candidate in (namespace.wrapper, namespace.alias):
            if candidate in RESERVED_WRAPPER_NAMES:
                problems.append(
                    f"namespace {namespace.system}: {candidate!r} is reserved for the flavour "
                    "table; add a namespaceExceptions entry to naming.json"
                )
    taken = set(namespace_names)
    for namespace in metadata.namespaces:
        if namespace.alias is not None and namespace.alias in taken:
            problems.append(f"alias {namespace.alias!r} of {namespace.wrapper} is also a namespace wrapper")
    for alias in _duplicates(namespace.alias for namespace in metadata.namespaces if namespace.alias):
        problems.append(f"alias {alias!r} is given to two namespaces")

    bindings: list[str] = []
    for namespace in metadata.namespaces:
        for wrapper in _duplicates(function.wrapper for function in namespace.functions):
            problems.append(f"{namespace.wrapper}.{wrapper} is used by two functions")
        for name in _duplicates(function.name for function in namespace.functions):
            problems.append(f"{namespace.wrapper}: function {name!r} is listed twice")
        bindings.extend(function.binding for function in namespace.functions if function.binding)
        if namespace.kind not in model.NAMESPACE_KINDS:
            problems.append(f"namespace {namespace.wrapper}: unknown kind {namespace.kind!r}")
        if namespace.kind == "namespace" and not namespace.blizzard_namespace:
            problems.append(f"namespace {namespace.wrapper}: kind namespace without a blizzardNamespace")
        if namespace.kind != "namespace" and namespace.blizzard_namespace:
            problems.append(f"namespace {namespace.wrapper}: kind {namespace.kind} with a blizzardNamespace")
        for function in namespace.functions:
            if (namespace.kind == "object") != (function.binding is None):
                problems.append(f"{namespace.wrapper}.{function.wrapper}: binding does not match kind {namespace.kind}")
    for binding in _duplicates(bindings):
        problems.append(f"binding {binding!r} is produced twice")

    for wrapper in _duplicates(event.wrapper for event in metadata.events):
        problems.append(f"event wrapper {wrapper!r} is used twice")
    for literal in _duplicates(event.literal_name for event in metadata.events):
        problems.append(f"event {literal!r} is documented twice")
    for label, entries in (
        ("enum", metadata.enums),
        ("structure", metadata.structures),
        ("callback", metadata.callbacks),
        ("constants table", metadata.constants),
    ):
        for name in _duplicates(entry.name for entry in entries):
            problems.append(f"{label} {name!r} is documented twice")
    for key in _duplicates(f"{restriction.system or ''}/{restriction.name}" for restriction in metadata.restrictions):
        problems.append(f"restriction {key!r} is documented twice")
    for wrapper in _duplicates(enum.wrapper for enum in metadata.enums):
        problems.append(f"enum wrapper {wrapper!r} is used twice")
    for wrapper in _duplicates(table.wrapper for table in metadata.constants):
        problems.append(f"constants wrapper {wrapper!r} is used twice")
    for restriction in metadata.restrictions:
        if restriction.kind not in model.RESTRICTION_KINDS:
            problems.append(f"restriction {restriction.name}: unknown kind {restriction.kind!r}")
    return problems


def _check_parameter_lists(metadata: FlavourMetadata) -> list[str]:
    """No argument, return, payload or field list names one parameter twice.

    The generators and the diff key parameters by name inside a list, so a
    duplicate would be silently collapsed downstream.
    """
    problems: list[str] = []
    seen: dict[str, list[str]] = defaultdict(list)
    for context, parameter in _parameters_with_context(metadata):
        owner = context.rsplit(" ", 1)[0]
        seen[owner].append(parameter.name)
    for owner, names in seen.items():
        for name in _duplicates(names):
            problems.append(f"{owner}: parameter {name!r} is listed twice")
    return problems


def _check_enums(metadata: FlavourMetadata) -> list[str]:
    problems: list[str] = []
    for enum in metadata.enums:
        values = [item.value for item in enum.fields]
        if enum.num_values is not None and enum.num_values != len(values):
            problems.append(f"enum {enum.name}: numValues is {enum.num_values} but {len(values)} fields are listed")
        if values:
            if enum.min_value is not None and enum.min_value != min(values):
                problems.append(f"enum {enum.name}: minValue is {enum.min_value} but the smallest field is {min(values)}")
            if enum.max_value is not None and enum.max_value != max(values):
                problems.append(f"enum {enum.name}: maxValue is {enum.max_value} but the largest field is {max(values)}")
        for name in _duplicates(item.name for item in enum.fields):
            problems.append(f"enum {enum.name}: field {name!r} is listed twice")
    return problems


def _parameters_with_context(metadata: FlavourMetadata) -> Iterable[tuple[str, Parameter]]:
    for namespace in metadata.namespaces:
        for function in namespace.functions:
            for parameter in function.arguments:
                yield f"{namespace.wrapper}.{function.wrapper} argument {parameter.name}", parameter
            for parameter in function.returns:
                yield f"{namespace.wrapper}.{function.wrapper} return {parameter.name}", parameter
    for event in metadata.events:
        for parameter in event.payload:
            yield f"event {event.literal_name} payload {parameter.name}", parameter
    for structure in metadata.structures:
        for parameter in structure.fields:
            yield f"structure {structure.name} field {parameter.name}", parameter
    for callback in metadata.callbacks:
        for parameter in callback.arguments:
            yield f"callback {callback.name} argument {parameter.name}", parameter
        for parameter in callback.returns:
            yield f"callback {callback.name} return {parameter.name}", parameter


def _check_type_references(metadata: FlavourMetadata, host_types: HostTypes) -> list[str]:
    """Every referenced type is defined by this flavour or listed as a host type.

    Each unresolved name is reported once with the places that use it, so the
    fix (a `types.json` entry or a look at a renamed table) is one line.
    """
    known = metadata.defined_type_names()
    unresolved: dict[str, list[str]] = defaultdict(list)
    for context, parameter in _parameters_with_context(metadata):
        for name in parameter.referenced_types():
            if name not in known and name not in host_types:
                unresolved[name].append(context)
        if parameter.mixin is not None and parameter.mixin not in known and parameter.mixin not in host_types:
            unresolved[parameter.mixin].append(f"{context} (mixin)")
    for table in metadata.constants:
        for value in table.values:
            if value.type not in known and value.type not in host_types:
                unresolved[value.type].append(f"constants {table.name} value {value.name}")
    problems = []
    for name, contexts in sorted(unresolved.items()):
        shown = ", ".join(contexts[:3])
        more = f" and {len(contexts) - 3} more" if len(contexts) > 3 else ""
        problems.append(f"type {name!r} is not defined by this flavour or listed in types.json (used by {shown}{more})")
    return problems


def _check_provenance(metadata: FlavourMetadata, known_flavours: Sequence[str] | None) -> list[str]:
    problems: list[str] = []
    provenance = metadata.provenance
    if known_flavours is not None and provenance.flavour not in known_flavours:
        problems.append(f"provenance: flavour {provenance.flavour!r} is not in the flavour table")
    if not model.ISO_DATE_RE.fullmatch(provenance.captured_on):
        problems.append(f"provenance: capturedOn {provenance.captured_on!r} is not YYYY-MM-DD")
    if len(provenance.commit) != 40 or any(character not in "0123456789abcdef" for character in provenance.commit):
        problems.append(f"provenance: commit {provenance.commit!r} is not a full lowercase sha")
    return problems


def validate_metadata(
    metadata: FlavourMetadata,
    host_types: HostTypes,
    known_flavours: Sequence[str] | None = None,
) -> list[str]:
    """Return every problem with `metadata`; an empty list means it is valid.

    `known_flavours` is the list of flavour ids the provenance may name; it
    defaults to the ids in `tooling/api/flavours.json`.
    """
    if known_flavours is None:
        known_flavours = flavours.load_flavours().ids()
    problems: list[str] = []
    problems.extend(_check_provenance(metadata, known_flavours))
    problems.extend(_check_wrapper_names(metadata))
    problems.extend(_check_uniqueness(metadata))
    problems.extend(_check_parameter_lists(metadata))
    problems.extend(_check_enums(metadata))
    problems.extend(_check_type_references(metadata, host_types))
    return problems


def main(argv: Sequence[str] | None = None) -> int:
    """Validate a metadata directory and print its problems."""
    parser = argparse.ArgumentParser(
        prog="python3 -m tooling.api.validate",
        description="Validate one flavour's apiKit metadata directory.",
    )
    parser.add_argument("directory", type=Path, help="a metadata directory written by tooling.api.normalize")
    arguments = parser.parse_args(argv)

    try:
        metadata = model.read_metadata(arguments.directory)
        host_types = model.load_host_types()
        problems = validate_metadata(metadata, host_types)
    except (OSError, ValueError) as failure:
        print(f"error: {failure}", file=sys.stderr)
        return 1

    if problems:
        print(f"error: {arguments.directory} has {len(problems)} problem(s):", file=sys.stderr)
        for problem in problems:
            print(f"  - {problem}", file=sys.stderr)
        return 1
    print(f"{arguments.directory}: valid ({metadata.provenance.flavour}, build {metadata.provenance.build})")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
