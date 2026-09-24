"""The apiKit metadata model: what one flavour's normalised API looks like.

`docs/API_KIT_DESIGN.md` (section 7.1) makes machine-readable metadata the
single source of truth for the runtime bindings, the LuaCATS definitions, the
reference and the change reports. This module is that model in Python
dataclasses, with the JSON form they are written in and read back from. The
field-by-field description a reader of the JSON needs is `SCHEMA.md` beside
this module; the two are kept in step by the tests.

Design choices worth knowing:

- Every entry keeps the Blizzard name and the wrapper name side by side, so a
  reader of the JSON never has to re-derive one from the other.
- Attributes the documentation tables carry that the model does not name are
  not dropped: a boolean attribute that is `true` lands in `flags`, any other
  value in `attributes`. The tables gain new markers with most builds
  (`SecretWhenUnitStatsRestricted`, `RequiresClubsInitialized`, ...); the
  model must not need a release to carry them.
- Documentation prose from the tables is kept as a list of paragraphs, with
  provenance in the flavour's `provenance.json` (decided 2026-09-23).
- JSON keys are camelCase, objects are written with sorted keys, lists are
  sorted by the normaliser, and empty or absent values are omitted, so two
  captures of the same build produce byte-identical files.
"""

from __future__ import annotations

import json
import re
from dataclasses import dataclass, field
from pathlib import Path
from typing import Any, Iterable, Sequence

from tooling.validation.validate_manifests import ROOT


#: Version of the JSON shape. Bumped when a field changes meaning or is
#: removed; adding an optional field does not bump it.
SCHEMA_VERSION = 1

#: The files one flavour's metadata directory holds, and the key each file's
#: list sits under.
METADATA_FILES = {
    "namespaces": "namespaces.json",
    "events": "events.json",
    "enums": "enums.json",
    "structures": "structures.json",
    "callbacks": "callbacks.json",
    "constants": "constants.json",
    "restrictions": "restrictions.json",
}

#: The provenance file of a flavour's metadata directory.
PROVENANCE_FILE = "provenance.json"

#: Files inside a metadata directory that other tools own and `write_metadata`
#: must leave alone: the generator's search index and the build history.
FILES_OWNED_ELSEWHERE = frozenset({"search.json", "history.json"})

#: Location of the host type table relative to the repository root.
HOST_TYPES_PATH = Path("tooling") / "api" / "types.json"

#: Default absolute location of the host type table.
DEFAULT_HOST_TYPES_FILE = ROOT / HOST_TYPES_PATH

#: The kinds a host type entry may have. `primitive` is a Lua type, `alias` a
#: named string, number or integer, `class` an object or mixin the client
#: provides, `opaque` a type the tables reference but never describe.
HOST_TYPE_KINDS = ("primitive", "alias", "class", "opaque")

#: The kinds a namespace may have: a `C_*` (or `string`/`table`) namespace, a
#: group of global functions, or a script object whose functions are methods.
NAMESPACE_KINDS = ("namespace", "global", "object")

#: The suffix the tables give an object system's name (`SimpleFrameAPI`); the
#: class parameters refer to is the name without it.
OBJECT_SYSTEM_SUFFIX = "API"

#: The kinds a restriction predicate may have.
RESTRICTION_KINDS = ("precondition", "secret")

#: A date written as YYYY-MM-DD.
ISO_DATE_RE = re.compile(r"^\d{4}-\d{2}-\d{2}$")


class MetadataError(ValueError):
    """Metadata on disk does not have the shape this module documents."""


def json_object(**pairs: Any) -> dict[str, Any]:
    """Build a JSON object, leaving out `None`, empty lists, tuples and dicts.

    `False` and `0` are kept: they are values, not absences.
    """
    result: dict[str, Any] = {}
    for key, value in pairs.items():
        if value is None:
            continue
        if isinstance(value, (list, tuple, dict)) and not value:
            continue
        result[key] = value
    return result


def dump_json(data: Any) -> str:
    """Serialise deterministically: sorted keys, two-space indent, readable text."""
    return json.dumps(data, indent=2, sort_keys=True, ensure_ascii=False) + "\n"


@dataclass(frozen=True)
class Parameter:
    """An argument, a return value, an event payload field or a structure field."""

    name: str
    type: str
    nilable: bool = False
    inner_type: str | None = None
    key_type: str | None = None
    mixin: str | None = None
    has_default: bool = False
    default: Any = None
    stride_index: int | None = None
    documentation: tuple[str, ...] = ()
    flags: tuple[str, ...] = ()
    attributes: dict[str, Any] = field(default_factory=dict)

    def to_json(self) -> dict[str, Any]:
        data = json_object(
            name=self.name,
            type=self.type,
            nilable=self.nilable,
            innerType=self.inner_type,
            keyType=self.key_type,
            mixin=self.mixin,
            strideIndex=self.stride_index,
            documentation=list(self.documentation),
            flags=list(self.flags),
            attributes=self.attributes,
        )
        if self.has_default:
            data["default"] = self.default
        return data

    @classmethod
    def from_json(cls, data: dict[str, Any]) -> "Parameter":
        return cls(
            name=data["name"],
            type=data["type"],
            nilable=data.get("nilable", False),
            inner_type=data.get("innerType"),
            key_type=data.get("keyType"),
            mixin=data.get("mixin"),
            has_default="default" in data,
            default=data.get("default"),
            stride_index=data.get("strideIndex"),
            documentation=tuple(data.get("documentation", ())),
            flags=tuple(data.get("flags", ())),
            attributes=dict(data.get("attributes", {})),
        )

    def referenced_types(self) -> list[str]:
        """The type names this parameter refers to, for resolution checks."""
        return [name for name in (self.type, self.inner_type, self.key_type) if name is not None]


@dataclass(frozen=True)
class Function:
    """One documented function and its binding."""

    name: str
    wrapper: str
    binding: str | None
    arguments: tuple[Parameter, ...] = ()
    returns: tuple[Parameter, ...] = ()
    documentation: tuple[str, ...] = ()
    secret_arguments: str | None = None
    may_return_nothing: bool = False
    has_restrictions: bool = False
    is_protected: bool = False
    flags: tuple[str, ...] = ()
    attributes: dict[str, Any] = field(default_factory=dict)
    source: str = ""

    def to_json(self) -> dict[str, Any]:
        return json_object(
            name=self.name,
            wrapper=self.wrapper,
            binding=self.binding,
            arguments=[parameter.to_json() for parameter in self.arguments],
            returns=[parameter.to_json() for parameter in self.returns],
            documentation=list(self.documentation),
            secretArguments=self.secret_arguments,
            mayReturnNothing=self.may_return_nothing or None,
            hasRestrictions=self.has_restrictions or None,
            isProtected=self.is_protected or None,
            flags=list(self.flags),
            attributes=self.attributes,
            source=self.source,
        )

    @classmethod
    def from_json(cls, data: dict[str, Any]) -> "Function":
        return cls(
            name=data["name"],
            wrapper=data["wrapper"],
            binding=data.get("binding"),
            arguments=tuple(Parameter.from_json(item) for item in data.get("arguments", ())),
            returns=tuple(Parameter.from_json(item) for item in data.get("returns", ())),
            documentation=tuple(data.get("documentation", ())),
            secret_arguments=data.get("secretArguments"),
            may_return_nothing=data.get("mayReturnNothing", False),
            has_restrictions=data.get("hasRestrictions", False),
            is_protected=data.get("isProtected", False),
            flags=tuple(data.get("flags", ())),
            attributes=dict(data.get("attributes", {})),
            source=data.get("source", ""),
        )


@dataclass(frozen=True)
class Namespace:
    """A group of functions: a `C_*` namespace, a global system or a script object."""

    wrapper: str
    kind: str
    system: str
    blizzard_namespace: str | None = None
    alias: str | None = None
    object_type: str | None = None
    environment: str | None = None
    documentation: tuple[str, ...] = ()
    functions: tuple[Function, ...] = ()
    sources: tuple[str, ...] = ()

    @property
    def object_class_name(self) -> str | None:
        """The type name parameters use for an object system, or `None` for other kinds.

        The tables name an object system `<Class>API` (`AbbreviateConfigAPI`)
        while parameters refer to the class itself (`AbbreviateConfig`).
        """
        if self.kind != "object":
            return None
        if self.system.endswith(OBJECT_SYSTEM_SUFFIX) and len(self.system) > len(OBJECT_SYSTEM_SUFFIX):
            return self.system[: -len(OBJECT_SYSTEM_SUFFIX)]
        return self.system

    def to_json(self) -> dict[str, Any]:
        return json_object(
            wrapper=self.wrapper,
            kind=self.kind,
            system=self.system,
            blizzardNamespace=self.blizzard_namespace,
            alias=self.alias,
            objectType=self.object_type,
            environment=self.environment,
            documentation=list(self.documentation),
            functions=[function.to_json() for function in self.functions],
            sources=list(self.sources),
        )

    @classmethod
    def from_json(cls, data: dict[str, Any]) -> "Namespace":
        return cls(
            wrapper=data["wrapper"],
            kind=data["kind"],
            system=data["system"],
            blizzard_namespace=data.get("blizzardNamespace"),
            alias=data.get("alias"),
            object_type=data.get("objectType"),
            environment=data.get("environment"),
            documentation=tuple(data.get("documentation", ())),
            functions=tuple(Function.from_json(item) for item in data.get("functions", ())),
            sources=tuple(data.get("sources", ())),
        )


@dataclass(frozen=True)
class Event:
    """One frame event, with the payload the tables document."""

    name: str
    wrapper: str
    literal_name: str
    system: str
    payload: tuple[Parameter, ...] = ()
    documentation: tuple[str, ...] = ()
    synchronous: bool = False
    unique: bool = False
    callback: bool = False
    has_restrictions: bool = False
    flags: tuple[str, ...] = ()
    attributes: dict[str, Any] = field(default_factory=dict)
    source: str = ""

    def to_json(self) -> dict[str, Any]:
        return json_object(
            name=self.name,
            wrapper=self.wrapper,
            literalName=self.literal_name,
            system=self.system,
            payload=[parameter.to_json() for parameter in self.payload],
            documentation=list(self.documentation),
            synchronous=self.synchronous or None,
            unique=self.unique or None,
            callback=self.callback or None,
            hasRestrictions=self.has_restrictions or None,
            flags=list(self.flags),
            attributes=self.attributes,
            source=self.source,
        )

    @classmethod
    def from_json(cls, data: dict[str, Any]) -> "Event":
        return cls(
            name=data["name"],
            wrapper=data["wrapper"],
            literal_name=data["literalName"],
            system=data["system"],
            payload=tuple(Parameter.from_json(item) for item in data.get("payload", ())),
            documentation=tuple(data.get("documentation", ())),
            synchronous=data.get("synchronous", False),
            unique=data.get("unique", False),
            callback=data.get("callback", False),
            has_restrictions=data.get("hasRestrictions", False),
            flags=tuple(data.get("flags", ())),
            attributes=dict(data.get("attributes", {})),
            source=data.get("source", ""),
        )


@dataclass(frozen=True)
class EnumField:
    """One value of an enumeration."""

    name: str
    value: int
    documentation: tuple[str, ...] = ()
    flags: tuple[str, ...] = ()
    attributes: dict[str, Any] = field(default_factory=dict)

    def to_json(self) -> dict[str, Any]:
        return json_object(
            name=self.name,
            value=self.value,
            documentation=list(self.documentation),
            flags=list(self.flags),
            attributes=self.attributes,
        )

    @classmethod
    def from_json(cls, data: dict[str, Any]) -> "EnumField":
        return cls(
            name=data["name"],
            value=data["value"],
            documentation=tuple(data.get("documentation", ())),
            flags=tuple(data.get("flags", ())),
            attributes=dict(data.get("attributes", {})),
        )


@dataclass(frozen=True)
class Enum:
    """An enumeration the client exposes as `Enum.<name>`."""

    name: str
    wrapper: str
    fields: tuple[EnumField, ...]
    num_values: int | None = None
    min_value: int | None = None
    max_value: int | None = None
    system: str | None = None
    documentation: tuple[str, ...] = ()
    flags: tuple[str, ...] = ()
    attributes: dict[str, Any] = field(default_factory=dict)
    source: str = ""

    def to_json(self) -> dict[str, Any]:
        return json_object(
            name=self.name,
            wrapper=self.wrapper,
            fields=[item.to_json() for item in self.fields],
            numValues=self.num_values,
            minValue=self.min_value,
            maxValue=self.max_value,
            system=self.system,
            documentation=list(self.documentation),
            flags=list(self.flags),
            attributes=self.attributes,
            source=self.source,
        )

    @classmethod
    def from_json(cls, data: dict[str, Any]) -> "Enum":
        return cls(
            name=data["name"],
            wrapper=data["wrapper"],
            fields=tuple(EnumField.from_json(item) for item in data.get("fields", ())),
            num_values=data.get("numValues"),
            min_value=data.get("minValue"),
            max_value=data.get("maxValue"),
            system=data.get("system"),
            documentation=tuple(data.get("documentation", ())),
            flags=tuple(data.get("flags", ())),
            attributes=dict(data.get("attributes", {})),
            source=data.get("source", ""),
        )


@dataclass(frozen=True)
class Structure:
    """A record type a function returns or takes; types only, no runtime."""

    name: str
    fields: tuple[Parameter, ...]
    system: str | None = None
    documentation: tuple[str, ...] = ()
    flags: tuple[str, ...] = ()
    attributes: dict[str, Any] = field(default_factory=dict)
    source: str = ""

    def to_json(self) -> dict[str, Any]:
        return json_object(
            name=self.name,
            fields=[item.to_json() for item in self.fields],
            system=self.system,
            documentation=list(self.documentation),
            flags=list(self.flags),
            attributes=self.attributes,
            source=self.source,
        )

    @classmethod
    def from_json(cls, data: dict[str, Any]) -> "Structure":
        return cls(
            name=data["name"],
            fields=tuple(Parameter.from_json(item) for item in data.get("fields", ())),
            system=data.get("system"),
            documentation=tuple(data.get("documentation", ())),
            flags=tuple(data.get("flags", ())),
            attributes=dict(data.get("attributes", {})),
            source=data.get("source", ""),
        )


@dataclass(frozen=True)
class Callback:
    """The signature of a callback a function takes."""

    name: str
    arguments: tuple[Parameter, ...] = ()
    returns: tuple[Parameter, ...] = ()
    system: str | None = None
    documentation: tuple[str, ...] = ()
    flags: tuple[str, ...] = ()
    attributes: dict[str, Any] = field(default_factory=dict)
    source: str = ""

    def to_json(self) -> dict[str, Any]:
        return json_object(
            name=self.name,
            arguments=[item.to_json() for item in self.arguments],
            returns=[item.to_json() for item in self.returns],
            system=self.system,
            documentation=list(self.documentation),
            flags=list(self.flags),
            attributes=self.attributes,
            source=self.source,
        )

    @classmethod
    def from_json(cls, data: dict[str, Any]) -> "Callback":
        return cls(
            name=data["name"],
            arguments=tuple(Parameter.from_json(item) for item in data.get("arguments", ())),
            returns=tuple(Parameter.from_json(item) for item in data.get("returns", ())),
            system=data.get("system"),
            documentation=tuple(data.get("documentation", ())),
            flags=tuple(data.get("flags", ())),
            attributes=dict(data.get("attributes", {})),
            source=data.get("source", ""),
        )


@dataclass(frozen=True)
class ConstantValue:
    """One named constant.

    Most constants are literals and land in `value`. A few are written in the
    tables as references or arithmetic over other constants and enum values
    (`Enum.CalendarGetEventType.Get`, `Constants.X.LAST - Constants.X.FIRST +
    1`); those are kept unevaluated in `expression`, exactly as written, and
    `value` is `None`. Evaluating them needs the whole flavour's tables and is
    the generator's concern.
    """

    name: str
    type: str
    value: Any = None
    expression: str | None = None
    documentation: tuple[str, ...] = ()
    flags: tuple[str, ...] = ()
    attributes: dict[str, Any] = field(default_factory=dict)

    def to_json(self) -> dict[str, Any]:
        data = json_object(
            name=self.name,
            type=self.type,
            documentation=list(self.documentation),
            flags=list(self.flags),
            attributes=self.attributes,
        )
        if self.expression is not None:
            data["expression"] = self.expression
        else:
            data["value"] = self.value
        return data

    @classmethod
    def from_json(cls, data: dict[str, Any]) -> "ConstantValue":
        if "expression" not in data and "value" not in data:
            raise KeyError("value")
        return cls(
            name=data["name"],
            type=data["type"],
            value=data.get("value"),
            expression=data.get("expression"),
            documentation=tuple(data.get("documentation", ())),
            flags=tuple(data.get("flags", ())),
            attributes=dict(data.get("attributes", {})),
        )


@dataclass(frozen=True)
class ConstantsTable:
    """A group of constants the client exposes as `Constants.<name>`."""

    name: str
    wrapper: str
    values: tuple[ConstantValue, ...]
    system: str | None = None
    documentation: tuple[str, ...] = ()
    flags: tuple[str, ...] = ()
    attributes: dict[str, Any] = field(default_factory=dict)
    source: str = ""

    def to_json(self) -> dict[str, Any]:
        return json_object(
            name=self.name,
            wrapper=self.wrapper,
            values=[item.to_json() for item in self.values],
            system=self.system,
            documentation=list(self.documentation),
            flags=list(self.flags),
            attributes=self.attributes,
            source=self.source,
        )

    @classmethod
    def from_json(cls, data: dict[str, Any]) -> "ConstantsTable":
        return cls(
            name=data["name"],
            wrapper=data["wrapper"],
            values=tuple(ConstantValue.from_json(item) for item in data.get("values", ())),
            system=data.get("system"),
            documentation=tuple(data.get("documentation", ())),
            flags=tuple(data.get("flags", ())),
            attributes=dict(data.get("attributes", {})),
            source=data.get("source", ""),
        )


@dataclass(frozen=True)
class Restriction:
    """A named predicate a system attaches to its functions (`HasRestrictions`, ...).

    The same predicate name may appear in several systems with a different
    failure mode, so a restriction is identified by its system and its name.
    """

    name: str
    kind: str
    failure_mode: str | None = None
    system: str | None = None
    documentation: tuple[str, ...] = ()
    flags: tuple[str, ...] = ()
    attributes: dict[str, Any] = field(default_factory=dict)
    source: str = ""

    def to_json(self) -> dict[str, Any]:
        return json_object(
            name=self.name,
            kind=self.kind,
            failureMode=self.failure_mode,
            system=self.system,
            documentation=list(self.documentation),
            flags=list(self.flags),
            attributes=self.attributes,
            source=self.source,
        )

    @classmethod
    def from_json(cls, data: dict[str, Any]) -> "Restriction":
        return cls(
            name=data["name"],
            kind=data["kind"],
            failure_mode=data.get("failureMode"),
            system=data.get("system"),
            documentation=tuple(data.get("documentation", ())),
            flags=tuple(data.get("flags", ())),
            attributes=dict(data.get("attributes", {})),
            source=data.get("source", ""),
        )


@dataclass(frozen=True)
class Provenance:
    """Where a flavour's metadata came from: the capture and the tools."""

    flavour: str
    repository: str
    branch: str
    commit: str
    committed_at: str
    subject: str
    version: str | None
    build: int | None
    documentation_path: str
    captured_on: str
    file_count: int

    def to_json(self) -> dict[str, Any]:
        data = json_object(
            schema=SCHEMA_VERSION,
            flavour=self.flavour,
            repository=self.repository,
            branch=self.branch,
            commit=self.commit,
            committedAt=self.committed_at,
            subject=self.subject,
            version=self.version,
            build=self.build,
            documentationPath=self.documentation_path,
            capturedOn=self.captured_on,
        )
        data["fileCount"] = self.file_count
        return data

    @classmethod
    def from_json(cls, data: dict[str, Any]) -> "Provenance":
        return cls(
            flavour=data["flavour"],
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


@dataclass(frozen=True)
class FlavourMetadata:
    """Everything the normaliser knows about one flavour at one build."""

    provenance: Provenance
    namespaces: tuple[Namespace, ...] = ()
    events: tuple[Event, ...] = ()
    enums: tuple[Enum, ...] = ()
    structures: tuple[Structure, ...] = ()
    callbacks: tuple[Callback, ...] = ()
    constants: tuple[ConstantsTable, ...] = ()
    restrictions: tuple[Restriction, ...] = ()

    def defined_type_names(self) -> set[str]:
        """Names a parameter type may refer to that this flavour itself defines."""
        names = {enum.name for enum in self.enums}
        names.update(structure.name for structure in self.structures)
        names.update(callback.name for callback in self.callbacks)
        for namespace in self.namespaces:
            class_name = namespace.object_class_name
            if class_name is not None:
                names.add(class_name)
        return names

    def to_files(self) -> dict[str, str]:
        """Render the metadata as `{file name: text}` for one flavour directory."""
        files = {PROVENANCE_FILE: dump_json(self.provenance.to_json())}
        for key, file_name in METADATA_FILES.items():
            entries = getattr(self, key)
            files[file_name] = dump_json(
                {
                    "schema": SCHEMA_VERSION,
                    "flavour": self.provenance.flavour,
                    key: [entry.to_json() for entry in entries],
                }
            )
        return files


#: The class that reads each metadata file's list.
_ENTRY_CLASSES = {
    "namespaces": Namespace,
    "events": Event,
    "enums": Enum,
    "structures": Structure,
    "callbacks": Callback,
    "constants": ConstantsTable,
    "restrictions": Restriction,
}


def write_metadata(metadata: FlavourMetadata, directory: Path) -> list[Path]:
    """Write a flavour's metadata files into `directory` and return their paths.

    Files the model no longer produces are removed, so a directory never
    carries a stale file from an older schema next to the current ones; the
    files other tools own (`FILES_OWNED_ELSEWHERE`) are kept.
    """
    directory.mkdir(parents=True, exist_ok=True)
    expected = metadata.to_files()
    for stale in directory.glob("*.json"):
        if stale.name not in expected and stale.name not in FILES_OWNED_ELSEWHERE:
            stale.unlink()
    written: list[Path] = []
    for file_name, text in sorted(expected.items()):
        path = directory / file_name
        path.write_text(text, encoding="utf-8")
        written.append(path)
    return written


def _read_json(path: Path) -> Any:
    try:
        return json.loads(path.read_text(encoding="utf-8"))
    except FileNotFoundError:
        raise MetadataError(f"{path}: missing") from None
    except json.JSONDecodeError as failure:
        raise MetadataError(f"{path}: not valid JSON ({failure})") from None


def _read_entries(directory: Path, key: str, flavour: str) -> tuple[Any, ...]:
    path = directory / METADATA_FILES[key]
    data = _read_json(path)
    if not isinstance(data, dict) or data.get("schema") != SCHEMA_VERSION:
        raise MetadataError(f"{path}: expected schema {SCHEMA_VERSION}")
    if data.get("flavour") != flavour:
        raise MetadataError(f"{path}: flavour {data.get('flavour')!r} is not {flavour!r}")
    entries = data.get(key)
    if not isinstance(entries, list):
        raise MetadataError(f"{path}: {key!r} must be a list")
    entry_class = _ENTRY_CLASSES[key]
    try:
        return tuple(entry_class.from_json(item) for item in entries)
    except (KeyError, TypeError) as failure:
        raise MetadataError(f"{path}: malformed entry ({failure!r})") from None


def read_metadata(directory: Path) -> FlavourMetadata:
    """Read a flavour's metadata directory back into the model.

    Raises `MetadataError` for a missing file, invalid JSON, a schema other
    than `SCHEMA_VERSION`, a flavour mismatch between files or a malformed entry.
    """
    provenance_data = _read_json(directory / PROVENANCE_FILE)
    if not isinstance(provenance_data, dict) or provenance_data.get("schema") != SCHEMA_VERSION:
        raise MetadataError(f"{directory / PROVENANCE_FILE}: expected schema {SCHEMA_VERSION}")
    try:
        provenance = Provenance.from_json(provenance_data)
    except KeyError as failure:
        raise MetadataError(f"{directory / PROVENANCE_FILE}: missing {failure}") from None

    entries = {key: _read_entries(directory, key, provenance.flavour) for key in METADATA_FILES}
    return FlavourMetadata(provenance=provenance, **entries)


@dataclass(frozen=True)
class HostType:
    """A type the tables reference but never define, and how LuaCATS spells it."""

    name: str
    kind: str
    lua: str


@dataclass(frozen=True)
class HostTypes:
    """The host type table: every such type, by name."""

    verified: str
    types: dict[str, HostType]

    def __contains__(self, name: object) -> bool:
        return name in self.types

    def names(self) -> list[str]:
        return sorted(self.types)


def parse_host_types(data: Any) -> HostTypes:
    """Validate the decoded host type table."""
    if not isinstance(data, dict) or set(data) != {"verified", "types"}:
        raise MetadataError("host types must be an object with exactly ['types', 'verified']")
    verified = data["verified"]
    if not isinstance(verified, str) or not ISO_DATE_RE.fullmatch(verified):
        raise MetadataError("host types: verified must be an ISO date (YYYY-MM-DD)")
    entries = data["types"]
    if not isinstance(entries, dict) or not entries:
        raise MetadataError("host types: types must be a non-empty object")

    types: dict[str, HostType] = {}
    for name, entry in entries.items():
        where = f"host types: {name}"
        if not isinstance(entry, dict) or set(entry) != {"kind", "lua"}:
            raise MetadataError(f"{where} must have exactly the keys ['kind', 'lua']")
        if entry["kind"] not in HOST_TYPE_KINDS:
            raise MetadataError(f"{where}.kind must be one of {list(HOST_TYPE_KINDS)}")
        if not isinstance(entry["lua"], str) or not entry["lua"]:
            raise MetadataError(f"{where}.lua must be a non-empty string")
        types[name] = HostType(name=name, kind=entry["kind"], lua=entry["lua"])
    if list(entries) != sorted(entries):
        raise MetadataError("host types: types must be sorted by name")
    return HostTypes(verified=verified, types=types)


def load_host_types(path: Path = DEFAULT_HOST_TYPES_FILE) -> HostTypes:
    """Read and validate the host type table at `path`."""
    return parse_host_types(json.loads(path.read_text(encoding="utf-8")))


def sorted_by_name(entries: Iterable[Any]) -> tuple[Any, ...]:
    """Sort model entries by their `name`, the order every metadata list uses."""
    return tuple(sorted(entries, key=lambda entry: entry.name))


def sorted_by_system_and_name(entries: Iterable[Any]) -> tuple[Any, ...]:
    """Sort entries identified by system and name, the order `restrictions.json` uses."""
    return tuple(sorted(entries, key=lambda entry: (entry.system or "", entry.name)))


def sorted_by_wrapper(entries: Sequence[Any]) -> tuple[Any, ...]:
    """Sort namespaces by their wrapper name, the order `namespaces.json` uses."""
    return tuple(sorted(entries, key=lambda entry: entry.wrapper))
