"""Normalise one fetched capture of the client's API documentation into metadata.

    python3 -m tooling.api.normalize --capture DIR --out DIR

`DIR` under `--capture` is what `tooling.api.fetch` wrote: `capture.json` and
`documentation/*.lua`, the client's own API documentation tables at one
pinned mirror commit. This step (design document, section 14, step 2) parses
every table, names every entry by the naming rules, merges the tables into
one model per flavour and writes the metadata files `tooling.api.model`
describes into `--out`, after `tooling.api.validate` has accepted the result.
Nothing is written when validation fails: an incomplete or ambiguous metadata
directory is worse than none (design document, section 15).

What the tables contain, and where it goes:

- a file whose top-level `Type` is `System` describes a namespace (`Namespace
  = "C_AddOns"`) or, without a `Namespace`, a group of global functions named
  after the system (`Unit`); a file whose `Type` is `ScriptObject` describes
  the methods of an object type (`ObjectType = "Userdata"`), which are typed
  but never bound; a file with neither describes only `Tables`;
- `Functions` become `Function` entries with a binding (`C_AddOns.DisableAddOn`
  or `UnitName`); a function's own `Namespace` attribute overrides its
  system's for the binding only (`Namespace = ""` makes `InCombatLockdown` of
  `C_RestrictedActions` a global, `Namespace = "table"` makes `count` of
  `C_TableUtil` `table.count`), while its wrapper stays under the system's
  wrapper namespace; `Events` become flat `Event` entries, and the `Tables` array
  holds enumerations, structures, callback types, constants tables and
  restriction predicates, each sorted into its own file;
- two files that describe the same namespace (the client splits a few, and
  may name the system differently in each) are merged; the same function
  documented twice is an error; the `Predicates` of a system are its
  restriction predicates, kept per system because the same name can carry a
  different failure mode elsewhere;
- attributes the model does not name are kept as flags (booleans that are
  `true`) or attributes (anything else), never dropped.

Wrapper names come from `tooling.api.naming`; the reviewed exception tables
in `naming.json` are applied on top, and a name two entries would share is an
error here rather than a suffix in the output.
"""

from __future__ import annotations

import argparse
import dataclasses
import json
import sys
from collections import Counter, defaultdict
from pathlib import Path
from typing import Any, Sequence

from tooling.api import lua_tables, model, naming, validate
from tooling.api.lua_tables import DocumentationFile, LuaExpression, LuaName, LuaTableError
from tooling.api.model import (
    Callback,
    ConstantsTable,
    ConstantValue,
    Enum,
    EnumField,
    Event,
    FlavourMetadata,
    Function,
    Namespace,
    Parameter,
    Provenance,
    Restriction,
    Structure,
)
from tooling.api.naming import NamingRules


#: The keys of a system table the model names; every other key is an extra.
SYSTEM_KEYS = {
    "Name",
    "Type",
    "Namespace",
    "Environment",
    "ObjectType",
    "Documentation",
    "Functions",
    "Events",
    "Tables",
    "Predicates",
}

#: The keys of a function entry the model names.
FUNCTION_KEYS = {
    "Name",
    "Type",
    "Arguments",
    "Returns",
    "Documentation",
    "SecretArguments",
    "MayReturnNothing",
    "HasRestrictions",
    "IsProtectedFunction",
}

#: The keys of an argument, return, payload or structure field the model names.
PARAMETER_KEYS = {
    "Name",
    "Type",
    "Nilable",
    "InnerType",
    "KeyType",
    "Mixin",
    "Default",
    "StrideIndex",
    "Documentation",
}

#: The keys of an event entry the model names.
EVENT_KEYS = {
    "Name",
    "Type",
    "LiteralName",
    "Payload",
    "Documentation",
    "SynchronousEvent",
    "UniqueEvent",
    "CallbackEvent",
    "HasRestrictions",
}

#: The keys the model names on the other table entries; anything else is an
#: extra, kept as a flag or an attribute like everywhere else.
ENUM_KEYS = {"Name", "Type", "NumValues", "MinValue", "MaxValue", "Fields", "Documentation"}
ENUM_FIELD_KEYS = {"Name", "Type", "EnumValue", "Documentation"}
STRUCTURE_KEYS = {"Name", "Type", "Fields", "Documentation"}
CALLBACK_KEYS = {"Name", "Type", "Arguments", "Returns", "Documentation"}
CONSTANTS_KEYS = {"Name", "Type", "Values", "Documentation"}
CONSTANT_VALUE_KEYS = {"Name", "Type", "Value", "Documentation"}
RESTRICTION_KEYS = {"Name", "Type", "FailureMode", "Documentation"}

#: The `Type` values a `Tables` entry may have, and the model list each feeds.
TABLE_ENTRY_KINDS = {
    "Enumeration": "enums",
    "Structure": "structures",
    "CallbackType": "callbacks",
    "Constants": "constants",
    "Precondition": "restrictions",
    "Secret": "restrictions",
}

#: The sub-directory of a capture holding the documentation tables.
CAPTURE_DOCUMENTATION_DIRECTORY = "documentation"

#: The provenance file `tooling.api.fetch` writes into a capture.
CAPTURE_FILE = "capture.json"


class NormalizeError(Exception):
    """The capture cannot be turned into metadata; the message lists every problem."""


def _where(source: str, *path: str) -> str:
    return source + "".join(f" > {part}" for part in path)


def _require_string(entry: dict[str, Any], key: str, where: str) -> str:
    value = entry.get(key)
    if not isinstance(value, str) or not value:
        raise NormalizeError(f"{where}: {key} must be a non-empty string")
    return value


def _optional_string(entry: dict[str, Any], key: str, where: str) -> str | None:
    value = entry.get(key)
    if value is None:
        return None
    if not isinstance(value, str):
        raise NormalizeError(f"{where}: {key} must be a string")
    return value


def _optional_bool(entry: dict[str, Any], key: str, where: str) -> bool:
    value = entry.get(key, False)
    if not isinstance(value, bool):
        raise NormalizeError(f"{where}: {key} must be true or false")
    return value


def _optional_integer(entry: dict[str, Any], key: str, where: str) -> int | None:
    value = entry.get(key)
    if value is None:
        return None
    if isinstance(value, bool) or not isinstance(value, int):
        raise NormalizeError(f"{where}: {key} must be an integer")
    return value


def _entries(entry: dict[str, Any], key: str, where: str) -> list[dict[str, Any]]:
    """Return the list under `key`, which the parser gives as `[]` when empty."""
    value = entry.get(key, [])
    if not isinstance(value, list):
        raise NormalizeError(f"{where}: {key} must be a list")
    for index, item in enumerate(value):
        if not isinstance(item, dict):
            raise NormalizeError(f"{where}: {key}[{index}] must be a table with named fields")
    return value


def _documentation(entry: dict[str, Any], where: str) -> tuple[str, ...]:
    value = entry.get("Documentation", [])
    if not isinstance(value, list) or not all(isinstance(item, str) for item in value):
        raise NormalizeError(f"{where}: Documentation must be a list of strings")
    return tuple(value)


def _json_ready(value: Any, where: str) -> Any:
    """Turn a parsed Lua value into what JSON can carry.

    A reference to another table (`Enum.SecretAspect.Cooldown`) becomes
    `{"ref": "Enum.SecretAspect.Cooldown"}` and an additive expression
    `{"expression": "..."}`, so neither can be mistaken for a string literal
    with the same text; the generators resolve them with the whole flavour at
    hand. Lists and keyed tables are converted element by element.
    """
    if isinstance(value, LuaName):
        return {"ref": value.path}
    if isinstance(value, LuaExpression):
        return {"expression": value.text}
    if isinstance(value, list):
        return [_json_ready(item, where) for item in value]
    if isinstance(value, dict):
        return {str(key): _json_ready(item, where) for key, item in value.items()}
    if value is None or isinstance(value, (bool, int, float, str)):
        return value
    raise NormalizeError(f"{where}: a value of type {type(value).__name__} cannot be carried")


def _extras(entry: dict[str, Any], known: set[str], where: str) -> tuple[tuple[str, ...], dict[str, Any]]:
    """Split the keys the model does not name into flags and attributes.

    A `true` boolean is a flag; a `false` one is the absence of that flag and
    is dropped; anything else is kept under its name.
    """
    flags: list[str] = []
    attributes: dict[str, Any] = {}
    for key in sorted(entry):
        if key in known:
            continue
        value = entry[key]
        if value is True:
            flags.append(key)
        elif value is False:
            continue
        else:
            attributes[key] = _json_ready(value, _where(where, key))
    return tuple(flags), attributes


def _parameter(entry: dict[str, Any], where: str) -> Parameter:
    name = _require_string(entry, "Name", where)
    where = _where(where, name)
    flags, attributes = _extras(entry, PARAMETER_KEYS, where)
    return Parameter(
        name=name,
        type=_require_string(entry, "Type", where),
        nilable=_optional_bool(entry, "Nilable", where),
        inner_type=_optional_string(entry, "InnerType", where),
        key_type=_optional_string(entry, "KeyType", where),
        mixin=_optional_string(entry, "Mixin", where),
        has_default="Default" in entry,
        default=_json_ready(entry.get("Default"), _where(where, "Default")),
        stride_index=_optional_integer(entry, "StrideIndex", where),
        documentation=_documentation(entry, where),
        flags=flags,
        attributes=attributes,
    )


def _parameters(entry: dict[str, Any], key: str, where: str) -> tuple[Parameter, ...]:
    return tuple(_parameter(item, _where(where, key)) for item in _entries(entry, key, where))


def _function(
    entry: dict[str, Any], *, wrapper: str, builder: "_NamespaceBuilder", source: str, where: str
) -> Function:
    """Build one function; its binding comes from its namespace and its own attributes."""
    flags, attributes = _extras(entry, FUNCTION_KEYS, where)
    try:
        binding = builder.binding_for(entry["Name"], attributes)
    except model.MetadataError as failure:
        raise NormalizeError(f"{where}: {failure}") from failure
    return Function(
        name=entry["Name"],
        wrapper=wrapper,
        binding=binding,
        arguments=_parameters(entry, "Arguments", where),
        returns=_parameters(entry, "Returns", where),
        documentation=_documentation(entry, where),
        secret_arguments=_optional_string(entry, "SecretArguments", where),
        may_return_nothing=_optional_bool(entry, "MayReturnNothing", where),
        has_restrictions=_optional_bool(entry, "HasRestrictions", where),
        is_protected=_optional_bool(entry, "IsProtectedFunction", where),
        flags=flags,
        attributes=attributes,
        source=source,
    )


def _event(entry: dict[str, Any], *, rules: NamingRules, system: str, source: str, where: str) -> Event:
    name = _require_string(entry, "Name", where)
    where = _where(where, name)
    flags, attributes = _extras(entry, EVENT_KEYS, where)
    return Event(
        name=name,
        wrapper=naming.member_wrapper_name(name, rules),
        literal_name=_require_string(entry, "LiteralName", where),
        system=system,
        payload=_parameters(entry, "Payload", where),
        documentation=_documentation(entry, where),
        synchronous=_optional_bool(entry, "SynchronousEvent", where),
        unique=_optional_bool(entry, "UniqueEvent", where),
        callback=_optional_bool(entry, "CallbackEvent", where),
        has_restrictions=_optional_bool(entry, "HasRestrictions", where),
        flags=flags,
        attributes=attributes,
        source=source,
    )


def _enum_field(entry: dict[str, Any], where: str) -> EnumField:
    name = _require_string(entry, "Name", where)
    where = _where(where, name)
    value = entry.get("EnumValue")
    if isinstance(value, bool) or not isinstance(value, int):
        raise NormalizeError(f"{where}: EnumValue must be an integer")
    flags, attributes = _extras(entry, ENUM_FIELD_KEYS, where)
    return EnumField(
        name=name,
        value=value,
        documentation=_documentation(entry, where),
        flags=flags,
        attributes=attributes,
    )


def _enum(entry: dict[str, Any], *, rules: NamingRules, system: str | None, source: str, where: str) -> Enum:
    name = entry["Name"]
    flags, attributes = _extras(entry, ENUM_KEYS, where)
    return Enum(
        name=name,
        wrapper=naming.member_wrapper_name(name, rules),
        fields=tuple(_enum_field(item, _where(where, "Fields")) for item in _entries(entry, "Fields", where)),
        num_values=_optional_integer(entry, "NumValues", where),
        min_value=_optional_integer(entry, "MinValue", where),
        max_value=_optional_integer(entry, "MaxValue", where),
        system=system,
        documentation=_documentation(entry, where),
        flags=flags,
        attributes=attributes,
        source=source,
    )


def _structure(entry: dict[str, Any], *, system: str | None, source: str, where: str) -> Structure:
    flags, attributes = _extras(entry, STRUCTURE_KEYS, where)
    return Structure(
        name=entry["Name"],
        fields=_parameters(entry, "Fields", where),
        system=system,
        documentation=_documentation(entry, where),
        flags=flags,
        attributes=attributes,
        source=source,
    )


def _callback(entry: dict[str, Any], *, system: str | None, source: str, where: str) -> Callback:
    flags, attributes = _extras(entry, CALLBACK_KEYS, where)
    return Callback(
        name=entry["Name"],
        arguments=_parameters(entry, "Arguments", where),
        returns=_parameters(entry, "Returns", where),
        system=system,
        documentation=_documentation(entry, where),
        flags=flags,
        attributes=attributes,
        source=source,
    )


def _constant_value(entry: dict[str, Any], where: str) -> ConstantValue:
    name = _require_string(entry, "Name", where)
    where = _where(where, name)
    if "Value" not in entry:
        raise NormalizeError(f"{where}: Value is missing")
    flags, attributes = _extras(entry, CONSTANT_VALUE_KEYS, where)
    value = entry["Value"]
    if isinstance(value, (LuaName, LuaExpression)):
        return ConstantValue(
            name=name,
            type=_require_string(entry, "Type", where),
            expression=value.path if isinstance(value, LuaName) else value.text,
            documentation=_documentation(entry, where),
            flags=flags,
            attributes=attributes,
        )
    return ConstantValue(
        name=name,
        type=_require_string(entry, "Type", where),
        value=_json_ready(value, where),
        documentation=_documentation(entry, where),
        flags=flags,
        attributes=attributes,
    )


def _constants(
    entry: dict[str, Any], *, rules: NamingRules, system: str | None, source: str, where: str
) -> ConstantsTable:
    name = entry["Name"]
    flags, attributes = _extras(entry, CONSTANTS_KEYS, where)
    return ConstantsTable(
        name=name,
        wrapper=naming.member_wrapper_name(name, rules),
        values=tuple(_constant_value(item, _where(where, "Values")) for item in _entries(entry, "Values", where)),
        system=system,
        documentation=_documentation(entry, where),
        flags=flags,
        attributes=attributes,
        source=source,
    )


def _restriction(entry: dict[str, Any], *, system: str | None, source: str, where: str) -> Restriction:
    kind = "precondition" if entry["Type"] == "Precondition" else "secret"
    flags, attributes = _extras(entry, RESTRICTION_KEYS, where)
    return Restriction(
        name=entry["Name"],
        kind=kind,
        failure_mode=_optional_string(entry, "FailureMode", where),
        system=system,
        documentation=_documentation(entry, where),
        flags=flags,
        attributes=attributes,
        source=source,
    )


def _preferred_system_name(current: str, candidate: str, blizzard_namespace: str | None) -> str:
    """Pick the system name of a namespace that several files document differently.

    `C_PlayerInfo` is documented under `PlayerInfo` in one file and
    `PlayerLocationInfo` in another. The name that equals the namespace without
    its prefix is the one the client's own documentation treats as primary;
    failing that, the alphabetically first name keeps the choice deterministic.
    """
    if blizzard_namespace is not None:
        bare = blizzard_namespace[len(naming.NAMESPACE_PREFIX) :] if blizzard_namespace.startswith(naming.NAMESPACE_PREFIX) else blizzard_namespace
        if candidate == bare:
            return candidate
        if current == bare:
            return current
    return min(current, candidate)


class _NamespaceBuilder:
    """Accumulates one namespace across the files that describe it."""

    def __init__(self, *, kind: str, system: str, blizzard_namespace: str | None, object_type: str | None):
        self.kind = kind
        self.system = system
        self.blizzard_namespace = blizzard_namespace
        self.object_type = object_type
        self.environment: str | None = None
        self.documentation: list[str] = []
        self.functions: dict[str, Function] = {}
        self.sources: list[str] = []

    @property
    def key(self) -> str:
        """What functions are bound through, or the system name for objects."""
        return self.blizzard_namespace if self.blizzard_namespace is not None else self.system

    def binding_for(self, function_name: str, attributes: dict[str, Any]) -> str | None:
        """The expression a function of this namespace binds to.

        The function's own `Namespace` attribute wins over the system's
        (`model.function_binding`); raises `MetadataError` when it cannot.
        """
        return model.function_binding(self.kind, self.blizzard_namespace, function_name, attributes)


class Normalizer:
    """Collects parsed documentation files and builds one flavour's metadata."""

    def __init__(self, rules: NamingRules):
        self.rules = rules
        self.namespaces: dict[str, _NamespaceBuilder] = {}
        self.events: list[Event] = []
        self.event_builders: list[_NamespaceBuilder] = []
        self.enums: list[Enum] = []
        self.structures: list[Structure] = []
        self.callbacks: list[Callback] = []
        self.constants: list[ConstantsTable] = []
        self.restrictions: list[Restriction] = []
        self.problems: list[str] = []

    # -- reading files -------------------------------------------------------

    def add_file(self, source: str, document: DocumentationFile) -> None:
        """Take one parsed documentation file into the model."""
        table = document.table
        where = source
        unknown = sorted(set(table) - SYSTEM_KEYS)
        if unknown:
            self.problems.append(f"{where}: unknown top-level keys {unknown}")

        top_type = table.get("Type")
        system_name = table.get("Name")
        if top_type is None and system_name is None:
            self._add_tables(table, system=None, source=source, where=where)
            return
        if not isinstance(system_name, str) or not system_name:
            self.problems.append(f"{where}: Name must be a non-empty string")
            return
        if top_type not in ("System", "ScriptObject"):
            self.problems.append(f"{where}: unknown top-level Type {top_type!r}")
            return

        builder = self._namespace_builder(table, system_name, top_type, where)
        if builder is None:
            return
        builder.sources.append(source)
        environment = table.get("Environment")
        if environment is not None:
            if builder.environment not in (None, environment):
                self.problems.append(
                    f"{where}: Environment {environment!r} disagrees with {builder.environment!r}"
                )
            builder.environment = environment
        builder.documentation.extend(_documentation(table, where))

        for entry in _entries(table, "Functions", where):
            self._add_function(builder, entry, source, _where(where, "Functions"))
        for entry in _entries(table, "Events", where):
            self._add_event(entry, builder, source, _where(where, "Events"))
        self._add_tables(table, system=system_name, source=source, where=where)

    def _namespace_builder(
        self, table: dict[str, Any], system_name: str, top_type: str, where: str
    ) -> _NamespaceBuilder | None:
        blizzard_namespace = table.get("Namespace")
        if top_type == "ScriptObject":
            kind, key = "object", f"object:{system_name}"
            blizzard_namespace = None
        elif isinstance(blizzard_namespace, str) and blizzard_namespace:
            kind, key = "namespace", f"namespace:{blizzard_namespace}"
        else:
            kind, key = "global", f"global:{system_name}"
            blizzard_namespace = None

        builder = self.namespaces.get(key)
        if builder is None:
            builder = _NamespaceBuilder(
                kind=kind,
                system=system_name,
                blizzard_namespace=blizzard_namespace,
                object_type=table.get("ObjectType"),
            )
            self.namespaces[key] = builder
        elif builder.system != system_name:
            builder.system = _preferred_system_name(builder.system, system_name, blizzard_namespace)
        return builder

    def _add_function(self, builder: _NamespaceBuilder, entry: dict[str, Any], source: str, where: str) -> None:
        name = entry.get("Name")
        if not isinstance(name, str) or not name:
            self.problems.append(f"{where}: a function has no Name")
            return
        where = _where(where, name)
        if entry.get("Type") != "Function":
            self.problems.append(f"{where}: Type must be \"Function\"")
            return
        if name in builder.functions:
            self.problems.append(f"{where}: documented twice in {builder.key}")
            return
        wrapper = self._function_wrapper(builder, name)
        try:
            builder.functions[name] = _function(
                entry, wrapper=wrapper, builder=builder, source=source, where=where
            )
        except NormalizeError as failure:
            self.problems.append(str(failure))

    def _function_wrapper(self, builder: _NamespaceBuilder, name: str) -> str:
        exception = self.rules.function_exceptions.get(f"{builder.key}.{name}")
        if exception is not None:
            return exception
        global_system = builder.system if builder.kind == "global" else None
        return naming.function_wrapper_name(name, self.rules, global_system=global_system)

    def _add_event(self, entry: dict[str, Any], builder: _NamespaceBuilder, source: str, where: str) -> None:
        try:
            if entry.get("Type") != "Event":
                raise NormalizeError(f"{_where(where, str(entry.get('Name')))}: Type must be \"Event\"")
            event = _event(entry, rules=self.rules, system=builder.system, source=source, where=where)
        except NormalizeError as failure:
            self.problems.append(str(failure))
            return
        self.events.append(event)
        self.event_builders.append(builder)

    def _events_with_merged_systems(self) -> list[Event]:
        """Events carry the system name their namespace settled on, not their file's.

        A namespace documented in two files may be named differently in each;
        `_preferred_system_name` decides once the files are all read, so the
        events are relabelled at build time.
        """
        return [
            dataclasses.replace(event, system=builder.system)
            for event, builder in zip(self.events, self.event_builders)
        ]

    def _add_tables(self, table: dict[str, Any], *, system: str | None, source: str, where: str) -> None:
        for entry in _entries(table, "Tables", where):
            name = entry.get("Name")
            if not isinstance(name, str) or not name:
                self.problems.append(f"{_where(where, 'Tables')}: an entry has no Name")
                continue
            entry_where = _where(where, "Tables", name)
            kind = entry.get("Type")
            target = TABLE_ENTRY_KINDS.get(kind)
            if target is None:
                self.problems.append(f"{entry_where}: unknown table Type {kind!r}")
                continue
            try:
                self._add_table_entry(target, entry, system=system, source=source, where=entry_where)
            except NormalizeError as failure:
                self.problems.append(str(failure))
        for entry in _entries(table, "Predicates", where):
            name = entry.get("Name")
            if not isinstance(name, str) or not name:
                self.problems.append(f"{_where(where, 'Predicates')}: an entry has no Name")
                continue
            entry_where = _where(where, "Predicates", name)
            if TABLE_ENTRY_KINDS.get(entry.get("Type")) != "restrictions":
                self.problems.append(f"{entry_where}: a predicate must be a Precondition or a Secret")
                continue
            try:
                self.restrictions.append(_restriction(entry, system=system, source=source, where=entry_where))
            except NormalizeError as failure:
                self.problems.append(str(failure))

    def _add_table_entry(self, target: str, entry: dict[str, Any], *, system: str | None, source: str, where: str) -> None:
        if target == "enums":
            self.enums.append(_enum(entry, rules=self.rules, system=system, source=source, where=where))
        elif target == "structures":
            self.structures.append(_structure(entry, system=system, source=source, where=where))
        elif target == "callbacks":
            self.callbacks.append(_callback(entry, system=system, source=source, where=where))
        elif target == "constants":
            self.constants.append(_constants(entry, rules=self.rules, system=system, source=source, where=where))
        else:
            self.restrictions.append(_restriction(entry, system=system, source=source, where=where))

    # -- building ------------------------------------------------------------

    def _namespace_wrapper(self, builder: _NamespaceBuilder) -> str:
        exception = self.rules.namespace_exceptions.get(builder.key)
        if exception is not None:
            return exception
        if builder.kind == "namespace":
            return naming.namespace_wrapper_name(builder.blizzard_namespace or "", self.rules)
        return naming.global_system_wrapper_name(builder.system, self.rules)

    def _build_namespaces(self) -> tuple[Namespace, ...]:
        by_wrapper: dict[str, list[str]] = defaultdict(list)
        namespaces: list[Namespace] = []
        for builder in self.namespaces.values():
            wrapper = self._namespace_wrapper(builder)
            by_wrapper[wrapper].append(builder.key)
            namespaces.append(
                Namespace(
                    wrapper=wrapper,
                    kind=builder.kind,
                    system=builder.system,
                    blizzard_namespace=builder.blizzard_namespace,
                    alias=self.rules.alias_for(wrapper),
                    object_type=builder.object_type,
                    environment=builder.environment,
                    documentation=tuple(builder.documentation),
                    functions=model.sorted_by_name(builder.functions.values()),
                    sources=tuple(sorted(builder.sources)),
                )
            )
        for wrapper, keys in sorted(by_wrapper.items()):
            if len(keys) > 1:
                self.problems.append(
                    f"wrapper namespace {wrapper!r} would be shared by {sorted(keys)}; "
                    "add a namespaceExceptions entry to naming.json"
                )
        self._report_function_collisions(namespaces)
        return model.sorted_by_wrapper(namespaces)

    def _report_function_collisions(self, namespaces: Sequence[Namespace]) -> None:
        for namespace in namespaces:
            by_wrapper: dict[str, list[str]] = defaultdict(list)
            for function in namespace.functions:
                by_wrapper[function.wrapper].append(function.name)
            for wrapper, names in sorted(by_wrapper.items()):
                if len(names) > 1:
                    self.problems.append(
                        f"{namespace.wrapper}.{wrapper} would be shared by {sorted(names)}; "
                        "add a functionExceptions entry to naming.json"
                    )

    def _report_member_collisions(self) -> None:
        for label, entries in (
            ("event", self.events),
            ("enum", self.enums),
            ("constants table", self.constants),
        ):
            by_wrapper: dict[str, set[str]] = defaultdict(set)
            for entry in entries:
                by_wrapper[entry.wrapper].add(entry.name)
            for wrapper, names in sorted(by_wrapper.items()):
                if len(names) > 1:
                    self.problems.append(f"{label} wrapper {wrapper!r} would be shared by {sorted(names)}")
        for label, entries in (
            ("event", self.events),
            ("enum", self.enums),
            ("structure", self.structures),
            ("callback", self.callbacks),
            ("constants table", self.constants),
        ):
            counts = Counter(entry.name for entry in entries)
            for name in sorted(name for name, count in counts.items() if count > 1):
                self.problems.append(f"{label} {name!r} is documented more than once")
        restriction_counts = Counter(
            (restriction.system or "", restriction.name) for restriction in self.restrictions
        )
        for system, name in sorted(key for key, count in restriction_counts.items() if count > 1):
            self.problems.append(f"restriction {name!r} of {system or 'no system'} is documented more than once")

    def build(self, provenance: Provenance) -> FlavourMetadata:
        """Assemble the metadata, or raise `NormalizeError` listing every problem."""
        namespaces = self._build_namespaces()
        self._report_member_collisions()
        if self.problems:
            raise NormalizeError("\n".join(f"- {problem}" for problem in sorted(set(self.problems))))
        return FlavourMetadata(
            provenance=provenance,
            namespaces=namespaces,
            events=model.sorted_by_name(self._events_with_merged_systems()),
            enums=model.sorted_by_name(self.enums),
            structures=model.sorted_by_name(self.structures),
            callbacks=model.sorted_by_name(self.callbacks),
            constants=model.sorted_by_name(self.constants),
            restrictions=model.sorted_by_system_and_name(self.restrictions),
        )


def read_capture_provenance(capture_dir: Path) -> Provenance:
    """Turn a capture's `capture.json` into the metadata's provenance."""
    path = capture_dir / CAPTURE_FILE
    try:
        data = json.loads(path.read_text(encoding="utf-8"))
    except FileNotFoundError:
        raise NormalizeError(f"{path}: missing; is this a directory tooling.api.fetch wrote?") from None
    except json.JSONDecodeError as failure:
        raise NormalizeError(f"{path}: not valid JSON ({failure})") from None
    try:
        return Provenance(
            flavour=data["flavourId"],
            repository=data["repository"],
            branch=data["branch"],
            commit=data["commit"],
            committed_at=data["committedAt"],
            subject=data["subject"],
            version=data.get("version"),
            build=data.get("build"),
            documentation_path=data["documentationPath"],
            captured_on=data["capturedOn"],
            file_count=data["fileCount"],
        )
    except (KeyError, TypeError) as failure:
        raise NormalizeError(f"{path}: malformed capture ({failure!r})") from None


def normalize_capture(capture_dir: Path, rules: NamingRules) -> FlavourMetadata:
    """Parse every documentation table of a capture and build the metadata.

    Raises `NormalizeError` with every problem found: parse errors, unknown
    shapes, duplicated entries and naming collisions.
    """
    provenance = read_capture_provenance(capture_dir)
    documentation_dir = capture_dir / CAPTURE_DOCUMENTATION_DIRECTORY
    files = sorted(documentation_dir.glob("*.lua"))
    if not files:
        raise NormalizeError(f"{documentation_dir}: no documentation tables were found")

    normalizer = Normalizer(rules)
    for path in files:
        try:
            document = lua_tables.parse_documentation_file(
                path.read_text(encoding="utf-8"), where=path.name
            )
        except LuaTableError as failure:
            normalizer.problems.append(str(failure))
            continue
        if not document.registered:
            normalizer.problems.append(f"{path.name}: the table is never registered")
            continue
        normalizer.add_file(path.name, document)
    return normalizer.build(provenance)


def main(argv: Sequence[str] | None = None) -> int:
    """Normalise a capture into a metadata directory, refusing on any problem."""
    parser = argparse.ArgumentParser(
        prog="python3 -m tooling.api.normalize",
        description="Normalise a fetched capture of the API documentation into apiKit metadata.",
    )
    parser.add_argument("--capture", required=True, type=Path, metavar="DIR", help="a capture directory written by tooling.api.fetch")
    parser.add_argument("--out", required=True, type=Path, metavar="DIR", help="the metadata directory to write (created or replaced)")
    arguments = parser.parse_args(argv)

    try:
        rules = naming.load_naming_rules()
        host_types = model.load_host_types()
        metadata = normalize_capture(arguments.capture, rules)
    except (OSError, ValueError, NormalizeError) as failure:
        print(f"error: {failure}", file=sys.stderr)
        return 1

    problems = validate.validate_metadata(metadata, host_types)
    if problems:
        print(f"error: the metadata for {metadata.provenance.flavour} is not valid:", file=sys.stderr)
        for problem in problems:
            print(f"  - {problem}", file=sys.stderr)
        return 1

    written = model.write_metadata(metadata, arguments.out)
    print(f"Normalised {metadata.provenance.flavour} at build {metadata.provenance.build} into {arguments.out}")
    print(f"  namespaces: {len(metadata.namespaces)}  functions: {sum(len(n.functions) for n in metadata.namespaces)}")
    print(f"  events: {len(metadata.events)}  enums: {len(metadata.enums)}  structures: {len(metadata.structures)}")
    print(f"  callbacks: {len(metadata.callbacks)}  constants: {len(metadata.constants)}  restrictions: {len(metadata.restrictions)}")
    print(f"  files: {len(written)}")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
