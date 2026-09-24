"""Render one flavour's runtime bindings: the generated Lua file the client loads.

`docs/API_KIT_DESIGN.md` (section 7.2) asks for the thinnest possible facade:
every wrapper entry is a direct alias of the Blizzard function, never a
forwarding function, so a call through `api` costs one table index more than
a raw call and cannot drift from the host's semantics. This module writes
that file for one flavour from the flavour's metadata.

The file is `packages/apiKit/src/flavours/<Flavour>.lua`. It resolves the
`ApiKit` facade the same way every Kit resolves a dependency (through the
`MoltenCodes` namespace and Registry API 2), then hands the facade an
installer:

    ApiKit:RegisterFlavor("retail", function(api, host)
      do
        local source = host.C_AddOnProfiler
        if source then
          local target = {}
          api.addOnProfiler = target
          api.profiler = target
          target.measureCall = source.MeasureCall
        end
      end
      ...
    end)

The facade runs the installer only when the running client is that flavour
(design section 5.2); on any other client the file costs its parse and the
registration call, after which the facade drops the installer so its
prototype can be collected. The contract between this file and the facade is
design section 7.2, "Contract with generated flavour files". Inside the
installer:

- a `C_*` namespace is bound only when the host has it, and each function is
  copied by name: a function the tables document but the running build lacks
  is simply absent from the wrapper, which is the truth about that client;
- global functions are read from `host` by name for the same reason;
- `api.events` maps wrapper names to event strings, `api.enums` and
  `api.constants` alias the host's `Enum` and `Constants` tables entry by
  entry;
- object types (methods on host objects) produce nothing: they are types.

The output is deterministic and already in the shape StyLua 2.5 produces for
the repository's configuration (two-space indentation, double quotes), so
the formatter is a check rather than a step. Every nesting level is built from
`INDENT`, and the wrapping decisions measure the indented line against
`STYLUA_COLUMN_WIDTH`, so both follow `stylua.toml` from one place each.
"""

from __future__ import annotations

import re
from typing import Iterable

from tooling.api import flavours, model, naming


#: The Registry API generation the facade is published under, as every Kit
#: written so far requires.
REQUIRED_REGISTRY_API = 2

#: The apiKit API generation the runtime file was generated for.
REQUIRED_API_KIT_API = 1

#: Wrapper names the flavour table reserves for itself; a Blizzard namespace
#: that would take one of them must be given an exception in `naming.json`.
RESERVED_WRAPPER_NAMES = frozenset({"events", "enums", "constants"})

#: `column_width` from `stylua.toml`; lines longer than this are wrapped as
#: StyLua would wrap them.
STYLUA_COLUMN_WIDTH = 100

#: One level of indentation: `indent_type = "Spaces"` with `indent_width = 2`
#: from `stylua.toml`. Every nesting level of the generated file is a multiple
#: of it, so a change to the formatter's width is a change to this one value.
INDENT = "  "

#: A Lua identifier, which is what a `target.<name>` field access needs.
LUA_IDENTIFIER_RE = re.compile(r"^[A-Za-z_][A-Za-z0-9_]*$")

#: Words Lua reserves; a Blizzard name that is one of them must be indexed
#: with brackets instead of a dot (a wrapper never is: the validator refuses it).
LUA_KEYWORDS = naming.LUA_KEYWORDS


class RuntimeRenderError(ValueError):
    """The metadata cannot be rendered as a runtime file."""


def _field_access(table: str, name: str) -> str:
    """`table.name`, or `table["name"]` when `name` is not a plain Lua identifier."""
    if LUA_IDENTIFIER_RE.fullmatch(name) and name not in LUA_KEYWORDS:
        return f"{table}.{name}"
    escaped = name.replace("\\", "\\\\").replace('"', '\\"')
    return f'{table}["{escaped}"]'


def _table_key(name: str) -> str:
    """`name` as a table-constructor key: bare when it is a plain identifier, else bracketed."""
    if LUA_IDENTIFIER_RE.fullmatch(name) and name not in LUA_KEYWORDS:
        return name
    return f"[{_lua_string(name)}]"


def _indent(depth: int) -> str:
    """The leading whitespace of a line `depth` nesting levels deep."""
    return INDENT * depth


def _assignment(depth: int, left: str, right: str) -> list[str]:
    """`left = right` on one line, or wrapped after `=` the way StyLua wraps a long one.

    The column width is the repository's (`stylua.toml`), so the generated file
    is already what the formatter would produce and the format gate stays a
    check. The wrapped right-hand side hangs one level deeper than the
    statement.
    """
    line = f"{_indent(depth)}{left} = {right}"
    if len(line) <= STYLUA_COLUMN_WIDTH:
        return [line]
    return [f"{_indent(depth)}{left} =", f"{_indent(depth + 1)}{right}"]


def _error_call(depth: int, message: str, level: int) -> list[str]:
    """`error("...", level)` on one line, or spread over lines the way StyLua spreads a long call.

    A spread call puts each argument one level deeper than the call and the
    closing parenthesis back at the call's own level.
    """
    line = f"{_indent(depth)}error({message}, {level})"
    if len(line) <= STYLUA_COLUMN_WIDTH:
        return [line]
    argument = _indent(depth + 1)
    return [
        f"{_indent(depth)}error(",
        f"{argument}{message},",
        f"{argument}{level}",
        f"{_indent(depth)})",
    ]


def _lua_string(text: str) -> str:
    """A double-quoted Lua string literal for `text`."""
    escaped = text.replace("\\", "\\\\").replace('"', '\\"').replace("\n", "\\n")
    return f'"{escaped}"'


def _header(metadata: model.FlavourMetadata, flavour: flavours.Flavour) -> list[str]:
    provenance = metadata.provenance
    version = provenance.version or "unknown version"
    build = f"build {provenance.build}" if provenance.build is not None else "unknown build"
    return [
        f"-- MoltenCodes ApiKit: {flavour.display_name} bindings ({flavour.namespace})",
        "--",
        "-- GENERATED FILE. Do not edit. Regenerate with `python3 -m tooling.api.generate`.",
        f"-- Source: {provenance.repository}@{provenance.commit} ({provenance.branch}),",
        f"-- client {version}, {build}, captured {provenance.captured_on}.",
        "--",
        "-- Every entry is a direct alias of the host function, bound only when the",
        "-- running client has it. See docs/API_KIT_DESIGN.md, section 7.2.",
        "",
    ]


def _dependency_block(flavour: flavours.Flavour) -> list[str]:
    """Resolve ApiKit through Registry, the way every Kit resolves a dependency."""
    facade_missing = _lua_string(
        f"MoltenCodes ApiKit ({flavour.display_name} bindings) requires ApiKit API "
        f"{REQUIRED_API_KIT_API} to be loaded first"
    )
    registry_missing = _lua_string(
        f"MoltenCodes ApiKit ({flavour.display_name} bindings) requires Registry API "
        f"{REQUIRED_REGISTRY_API} to be loaded first"
    )
    registry_invalid = _lua_string(
        f"MoltenCodes ApiKit ({flavour.display_name} bindings) requires a valid Registry API "
        f"{REQUIRED_REGISTRY_API} facade"
    )
    return [
        "-- selene: allow(global_usage)",
        'local namespace = rawget(_G, "MoltenCodes")',
        'local generations = type(namespace) == "table" and rawget(namespace, "Registries") or nil',
        f'local Registry = type(generations) == "table" and rawget(generations, {REQUIRED_REGISTRY_API}) or nil',
        'if Registry == nil and type(namespace) == "table" then',
        f'{_indent(1)}Registry = rawget(namespace, "Registry")',
        "end",
        f'if type(Registry) ~= "table" or rawget(Registry, "API") ~= {REQUIRED_REGISTRY_API} then',
        *_error_call(1, registry_missing, 2),
        "end",
        "",
        'local getPackage = rawget(Registry, "Get")',
        'if type(getPackage) ~= "function" then',
        *_error_call(1, registry_invalid, 2),
        "end",
        f'local ApiKit = getPackage(Registry, "apiKit", {REQUIRED_API_KIT_API})',
        *_facade_condition(),
        *_error_call(1, facade_missing, 2),
        "end",
        "",
        f"ApiKit:RegisterFlavor({_lua_string(flavour.id)}, function(api, host)",
    ]


def _facade_condition() -> list[str]:
    """The `if ... then` that refuses a missing or foreign ApiKit facade.

    StyLua keeps a condition on the `if` line while the whole line fits in
    `STYLUA_COLUMN_WIDTH` and otherwise puts `if` and `then` on lines of their
    own with one operand per line, one level deeper; the same decision is made
    here so the format gate stays a check.
    """
    operands = [
        'type(ApiKit) ~= "table"',
        f'rawget(ApiKit, "API") ~= {REQUIRED_API_KIT_API}',
        'type(rawget(ApiKit, "RegisterFlavor")) ~= "function"',
    ]
    line = f"if {' or '.join(operands)} then"
    if len(line) <= STYLUA_COLUMN_WIDTH:
        return [line]
    first, *rest = operands
    return ["if", f"{_indent(1)}{first}", *(f"{_indent(1)}or {operand}" for operand in rest), "then"]


def _registration_close(metadata: model.FlavourMetadata) -> list[str]:
    """Close the installer and pass the metadata's version and build to the facade.

    `ApiKit:GetMetadataBuild` reports them, so an addon can compare the
    bindings' build with `GetBuildInfo()`.
    """
    provenance = metadata.provenance
    fields = []
    if provenance.version is not None:
        fields.append(f"version = {_lua_string(provenance.version)}")
    if provenance.build is not None:
        fields.append(f"build = {provenance.build}")
    if not fields:
        return ["end)"]
    return ["end, { " + ", ".join(fields) + " })"]


def _namespace_block(namespace: model.Namespace) -> list[str]:
    """Bind one `C_*`-style namespace: only when the host has it, function by function."""
    assert namespace.blizzard_namespace is not None
    lines = [
        f"{_indent(1)}do",
        f"{_indent(2)}local source = {_field_access('host', namespace.blizzard_namespace)}",
        f"{_indent(2)}if source then",
        f"{_indent(3)}local target = {{}}",
        f"{_indent(3)}{_field_access('api', namespace.wrapper)} = target",
    ]
    if namespace.alias is not None:
        lines.append(f"{_indent(3)}{_field_access('api', namespace.alias)} = target")
    for function in namespace.functions:
        lines.extend(
            _assignment(
                3,
                _field_access("target", function.wrapper),
                _field_access("source", function.name),
            )
        )
    lines.extend([f"{_indent(2)}end", f"{_indent(1)}end"])
    return lines


def _global_block(namespace: model.Namespace) -> list[str]:
    """Bind a group of global functions: each read from the host by name."""
    lines = [
        f"{_indent(1)}do",
        f"{_indent(2)}local target = {{}}",
        f"{_indent(2)}{_field_access('api', namespace.wrapper)} = target",
    ]
    if namespace.alias is not None:
        lines.append(f"{_indent(2)}{_field_access('api', namespace.alias)} = target")
    for function in namespace.functions:
        lines.extend(
            _assignment(
                2, _field_access("target", function.wrapper), _field_access("host", function.name)
            )
        )
    lines.append(f"{_indent(1)}end")
    return lines


def _events_block(events: Iterable[model.Event]) -> list[str]:
    events = list(events)
    if not events:
        return [f"{_indent(1)}api.events = {{}}"]
    lines = [f"{_indent(1)}api.events = {{"]
    for event in sorted(events, key=lambda item: item.wrapper):
        lines.append(f"{_indent(2)}{_table_key(event.wrapper)} = {_lua_string(event.literal_name)},")
    lines.append(f"{_indent(1)}}}")
    return lines


def _host_table_block(
    label: str, host_table: str, entries: Iterable[tuple[str, str]]
) -> list[str]:
    """Alias entries of a host table (`Enum`, `Constants`) into `api.<label>`.

    The host table itself may be missing on an old client; reading from an
    empty table instead makes each alias `nil` rather than the whole block
    raising.
    """
    lines = [
        f"{_indent(1)}do",
        f"{_indent(2)}local source = {_field_access('host', host_table)} or {{}}",
        f"{_indent(2)}local target = {{}}",
        f"{_indent(2)}{_field_access('api', label)} = target",
    ]
    for wrapper, name in sorted(entries):
        lines.extend(
            _assignment(2, _field_access("target", wrapper), _field_access("source", name))
        )
    lines.append(f"{_indent(1)}end")
    return lines


def _check_reserved_names(metadata: model.FlavourMetadata) -> None:
    for namespace in metadata.namespaces:
        for candidate in (namespace.wrapper, namespace.alias):
            if candidate in RESERVED_WRAPPER_NAMES:
                raise RuntimeRenderError(
                    f"namespace {namespace.system}: wrapper {candidate!r} is reserved for the "
                    "flavour table; add a namespaceExceptions entry to naming.json"
                )


def render_runtime(metadata: model.FlavourMetadata, flavour: flavours.Flavour) -> str:
    """Return the text of the flavour's runtime file.

    Raises `RuntimeRenderError` when a namespace would take a reserved name.
    Namespaces of kind `object` are skipped: their functions are methods on
    host objects and have no binding.
    """
    _check_reserved_names(metadata)
    lines = _header(metadata, flavour)
    lines.extend(_dependency_block(flavour))
    for namespace in metadata.namespaces:
        if namespace.kind == "namespace":
            lines.extend(_namespace_block(namespace))
        elif namespace.kind == "global":
            lines.extend(_global_block(namespace))
    lines.extend(_events_block(metadata.events))
    lines.extend(
        _host_table_block("enums", "Enum", ((enum.wrapper, enum.name) for enum in metadata.enums))
    )
    lines.extend(
        _host_table_block(
            "constants",
            "Constants",
            ((table.wrapper, table.name) for table in metadata.constants),
        )
    )
    lines.extend(_registration_close(metadata))
    return "\n".join(lines) + "\n"


def runtime_file_name(flavour: flavours.Flavour) -> str:
    """The file's path relative to the package's `src/`, from the flavour table."""
    return flavour.runtime_file
