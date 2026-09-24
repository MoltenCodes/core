"""Render one flavour's Markdown reference and its search index.

`docs/API_KIT_DESIGN.md` (section 13) lists a generated Markdown reference
under `packages/apiKit/docs/reference/<flavour>/` and a search index beside
the flavour's metadata. This module writes both from the flavour's metadata
model (`tooling.api.model`), never from the raw JSON, so a field the model
gains or loses is a change here and nowhere else.

The reference directory is exempt from the repository's spell check and
Markdown link check (`docs/TOOLING.md`), because a generated document has to
be correct by construction rather than by review. That exemption is the reason
this module validates its own links: every relative link it writes points at a
file it also writes, and every anchor at a heading it also writes. The
generator (`tooling.api.generate`) runs `check_links` over the rendered files
and refuses to write an inconsistent reference.

Layout of one reference directory:

    README.md                 provenance, usage, counts, namespace table, links
    namespaces/<wrapper>.md   one page per `C_*` namespace or global system
    events.md                 one section per frame event
    enums.md                  one section per enumeration
    structures.md             one section per record type
    callbacks.md              one section per callback signature
    constants.md              one section per constants table
    objects.md                one section per script object type (methods)
    restrictions.md           one table of restriction predicates

Anchors follow GitHub's rendering of headings (`heading_anchor`), including
the `-1`, `-2` suffixes GitHub gives repeated headings inside one file, so a
link this module writes is a link GitHub resolves. Type names that this
flavour defines (enumerations, structures, callbacks, object types) become
links to their section; host types render as plain code.

Every file starts with a one-line HTML comment naming the generator, the
flavour, the source commit and the build, as section 13 requires of every
generated file.
"""

from __future__ import annotations

import json
import posixpath
import re
from dataclasses import dataclass
from typing import Any, Iterable, Sequence

from tooling.api import flavours, model


#: The reference's entry page.
INDEX_FILE = "README.md"

#: The directory of per-namespace pages, relative to the reference directory.
NAMESPACES_DIRECTORY = "namespaces"

#: The catalogue files beside the entry page.
EVENTS_FILE = "events.md"
ENUMS_FILE = "enums.md"
STRUCTURES_FILE = "structures.md"
CALLBACKS_FILE = "callbacks.md"
CONSTANTS_FILE = "constants.md"
OBJECTS_FILE = "objects.md"
RESTRICTIONS_FILE = "restrictions.md"

#: The catalogue files in the order the entry page lists them.
CATALOGUE_FILES = (
    EVENTS_FILE,
    ENUMS_FILE,
    STRUCTURES_FILE,
    CALLBACKS_FILE,
    CONSTANTS_FILE,
    OBJECTS_FILE,
    RESTRICTIONS_FILE,
)

#: Version of the search index shape (`render_search_index`).
SEARCH_INDEX_SCHEMA = 1

#: Longest summary a search index entry carries, in characters.
SUMMARY_LENGTH = 160

#: Marks a summary that was cut; counted inside `SUMMARY_LENGTH`.
SUMMARY_ELLIPSIS = "..."

#: How many characters of the commit sha the generated-file comment shows.
SHORT_COMMIT_LENGTH = 12

#: A Markdown link `[text](target)`, with an optional `"title"` after the
#: target; images (`![alt](src)`) match too, which is intended.
LINK_RE = re.compile(r"\[[^\]]*\]\(\s*([^)\s]+)(?:\s+\"[^\"]*\")?\s*\)")

#: An ATX heading: one to six `#`, a space, the text, optional closing `#`s.
HEADING_RE = re.compile(r"^(#{1,6})\s+(.*?)(?:\s+#+)?\s*$")

#: A fenced code block boundary; headings and links inside fences are text.
FENCE_RE = re.compile(r"^\s*(```|~~~)")

#: Characters `heading_anchor` keeps: word characters (letters, digits and the
#: underscore, in any script), spaces and hyphens. Everything else is dropped,
#: which is what GitHub does.
ANCHOR_DROPPED_RE = re.compile(r"[^\w\- ]")


class ReferenceRenderError(ValueError):
    """The metadata cannot be rendered as a reference."""


# --------------------------------------------------------------------------
# Anchors and links
# --------------------------------------------------------------------------


def heading_anchor(text: str) -> str:
    """GitHub-style anchor for a heading: lowercase, spaces to hyphens, most punctuation gone.

    Hyphens and underscores survive, everything else that is not a letter,
    digit or space is removed, and spaces become hyphens. The suffixes GitHub
    adds to repeated headings (`-1`, `-2`) are the caller's concern, because
    only the caller knows which headings share a file; `_AnchorRegistry` does
    that for the renderer and `check_links` does it for the checker.
    """
    lowered = text.strip().lower()
    kept = ANCHOR_DROPPED_RE.sub("", lowered)
    return kept.replace(" ", "-")


class _AnchorRegistry:
    """The anchors of one file's headings, in order, with GitHub's duplicate suffixes."""

    def __init__(self) -> None:
        self._used: set[str] = set()

    def claim(self, heading_text: str) -> str:
        """Return the anchor GitHub gives `heading_text` at this point in the file."""
        base = heading_anchor(heading_text)
        candidate = base
        suffix = 0
        while candidate in self._used:
            suffix += 1
            candidate = f"{base}-{suffix}"
        self._used.add(candidate)
        return candidate


def _planned_anchors(heading_texts: Sequence[str]) -> list[str]:
    """The anchors a file with exactly these headings, in this order, will have."""
    registry = _AnchorRegistry()
    return [registry.claim(text) for text in heading_texts]


def _lines_outside_fences(text: str) -> Iterable[str]:
    """Yield the lines of `text` that are not inside a fenced code block."""
    inside_fence = False
    for line in text.splitlines():
        if FENCE_RE.match(line):
            inside_fence = not inside_fence
            continue
        if not inside_fence:
            yield line


def _heading_anchors_of(text: str) -> set[str]:
    """Every anchor a Markdown file offers, computed the way GitHub does."""
    registry = _AnchorRegistry()
    anchors: set[str] = set()
    for line in _lines_outside_fences(text):
        match = HEADING_RE.match(line)
        if match:
            anchors.add(registry.claim(match.group(2)))
    return anchors


def _link_targets_of(text: str) -> list[str]:
    """Every link target in a Markdown file, outside fenced code."""
    targets: list[str] = []
    for line in _lines_outside_fences(text):
        targets.extend(LINK_RE.findall(line))
    return targets


def _is_external(target: str) -> bool:
    return "://" in target or target.startswith("mailto:")


def _resolve(source_file: str, target_path: str) -> str:
    """The reference-relative path `target_path` names when written in `source_file`."""
    if not target_path:
        return source_file
    joined = posixpath.join(posixpath.dirname(source_file), target_path)
    return posixpath.normpath(joined)


def check_links(files: dict[str, str]) -> list[str]:
    """Return every relative link in `files` whose file or anchor does not exist.

    `files` maps reference-relative paths (`namespaces/unit.md`) to Markdown
    text. A target is `path`, `path#anchor` or `#anchor`; the path is resolved
    against the linking file's directory and must be a key of `files`, the
    anchor must be a heading of that file as GitHub would anchor it. Links
    with a scheme (`https://`, `mailto:`) are not checked. An empty list means
    the reference is self-consistent.
    """
    anchors_by_file = {name: _heading_anchors_of(text) for name, text in files.items()}
    problems: list[str] = []
    for source_file in sorted(files):
        for target in _link_targets_of(files[source_file]):
            if _is_external(target):
                continue
            target_path, _, anchor = target.partition("#")
            resolved = _resolve(source_file, target_path)
            if resolved not in anchors_by_file:
                problems.append(f"{source_file}: link to {target!r}: no such file {resolved!r}")
            elif anchor and anchor not in anchors_by_file[resolved]:
                problems.append(f"{source_file}: link to {target!r}: no heading with anchor {anchor!r}")
    return problems


# --------------------------------------------------------------------------
# Markdown building blocks
# --------------------------------------------------------------------------


def _cell(text: str) -> str:
    """Make `text` safe inside a one-line table cell: no newlines, pipes escaped."""
    one_line = " ".join(text.split())
    return one_line.replace("|", "\\|")


def _code(text: str) -> str:
    return f"`{text}`"


def _code_list(items: Iterable[str]) -> str:
    return ", ".join(_code(item) for item in items)


def _prose(paragraphs: Iterable[str]) -> str:
    """Documentation paragraphs as one line of prose, for cells and summaries."""
    return " ".join(" ".join(paragraph.split()) for paragraph in paragraphs)


def _lua_literal(value: Any) -> str:
    """Write a documented default or constant value the way Lua source would."""
    if value is None:
        return "nil"
    if isinstance(value, bool):
        return "true" if value else "false"
    if isinstance(value, str):
        return json.dumps(value, ensure_ascii=False)
    return str(value)


def _compact_value(value: Any) -> str:
    """A non-boolean attribute value on one line: strings bare, the rest as JSON."""
    if isinstance(value, str):
        return value
    return json.dumps(value, ensure_ascii=False, sort_keys=True, separators=(",", ":"))


def _attributes_text(attributes: dict[str, Any]) -> str:
    return ", ".join(_code(f"{key}={_compact_value(attributes[key])}") for key in sorted(attributes))


def _yes_no(flag: bool) -> str:
    return "yes" if flag else "no"


class _Page:
    """One Markdown file under construction.

    Headings pass through an `_AnchorRegistry`, so the anchor of any heading
    is known while the page is built and can be handed to the search index
    without re-parsing the text.
    """

    def __init__(self, generated_comment: str) -> None:
        self._lines: list[str] = [generated_comment, ""]
        self._registry = _AnchorRegistry()
        #: Anchors of the headings registered under a key, for the search index.
        self.anchors: dict[str, str] = {}

    def heading(self, level: int, text: str, key: str | None = None) -> str:
        anchor = self._registry.claim(text)
        if key is not None:
            self.anchors[key] = anchor
        self._lines.extend([f"{'#' * level} {text}", ""])
        return anchor

    def paragraph(self, text: str) -> None:
        self._lines.extend([text, ""])

    def paragraphs(self, texts: Iterable[str]) -> None:
        """Documentation paragraphs, each on one line so a table never breaks."""
        for text in texts:
            self.paragraph(" ".join(text.split()))

    def code_block(self, language: str, code: str) -> None:
        self._lines.extend([f"```{language}", code, "```", ""])

    def bullet_list(self, items: Iterable[str]) -> None:
        self._lines.extend(f"- {item}" for item in items)
        self._lines.append("")

    def table(self, headers: Sequence[str], rows: Iterable[Sequence[str]]) -> None:
        self._lines.append("| " + " | ".join(_cell(header) for header in headers) + " |")
        self._lines.append("|" + "---|" * len(headers))
        for row in rows:
            self._lines.append("| " + " | ".join(_cell(cell) for cell in row) + " |")
        self._lines.append("")

    def text(self) -> str:
        return "\n".join(self._lines).rstrip("\n") + "\n"


# --------------------------------------------------------------------------
# Provenance and type links
# --------------------------------------------------------------------------


def _version_text(provenance: model.Provenance) -> str:
    version = provenance.version or "unknown version"
    build = provenance.build if provenance.build is not None else "unknown"
    return f"{version} build {build}"


def _generated_comment(metadata: model.FlavourMetadata, flavour: flavours.Flavour) -> str:
    provenance = metadata.provenance
    short_commit = provenance.commit[:SHORT_COMMIT_LENGTH]
    return (
        f"<!-- Generated by tooling.api.generate from the {flavour.id} metadata "
        f"({provenance.repository}@{short_commit}, {_version_text(provenance)}). Do not edit. -->"
    )


@dataclass(frozen=True)
class _TypeTarget:
    """Where a type this flavour defines is documented: file and anchor."""

    file: str
    anchor: str


def _catalogue_titles(flavour: flavours.Flavour) -> dict[str, str]:
    """The h1 title of every catalogue file; the anchor plan depends on them."""
    name = flavour.display_name
    return {
        EVENTS_FILE: f"{name} events",
        ENUMS_FILE: f"{name} enumerations",
        STRUCTURES_FILE: f"{name} structures",
        CALLBACKS_FILE: f"{name} callbacks",
        CONSTANTS_FILE: f"{name} constants",
        OBJECTS_FILE: f"{name} objects",
        RESTRICTIONS_FILE: f"{name} restriction predicates",
    }


def _object_namespaces(metadata: model.FlavourMetadata) -> tuple[model.Namespace, ...]:
    return model.sorted_by_wrapper([space for space in metadata.namespaces if space.kind == "object"])


def _bound_namespaces(metadata: model.FlavourMetadata) -> tuple[model.Namespace, ...]:
    """Namespaces that get a page of their own: `C_*` namespaces and global systems."""
    return model.sorted_by_wrapper([space for space in metadata.namespaces if space.kind != "object"])


def _type_targets(metadata: model.FlavourMetadata, titles: dict[str, str]) -> dict[str, _TypeTarget]:
    """Map every type this flavour defines to the section that documents it.

    A catalogue file's headings are its title followed by one `###` per entry
    in metadata order; the anchors are planned from that same sequence, so the
    links written here agree with the headings written later. When a name is
    defined twice across kinds (the validator refuses it) the first kind wins.
    """
    catalogues = (
        (ENUMS_FILE, [enum.name for enum in model.sorted_by_name(metadata.enums)]),
        (STRUCTURES_FILE, [structure.name for structure in model.sorted_by_name(metadata.structures)]),
        (CALLBACKS_FILE, [callback.name for callback in model.sorted_by_name(metadata.callbacks)]),
        (OBJECTS_FILE, [space.system for space in _object_namespaces(metadata)]),
    )
    targets: dict[str, _TypeTarget] = {}
    for file_name, names in catalogues:
        anchors = _planned_anchors([titles[file_name], *names])[1:]
        for name, anchor in zip(names, anchors):
            targets.setdefault(name, _TypeTarget(file_name, anchor))
    return targets


class _Linker:
    """Writes type names as links from one file's point of view."""

    def __init__(self, targets: dict[str, _TypeTarget], prefix: str) -> None:
        self._targets = targets
        #: `../` for a file inside `namespaces/`, empty at the top level.
        self._prefix = prefix

    def type(self, type_name: str) -> str:
        target = self._targets.get(type_name)
        if target is None:
            return _code(type_name)
        return f"[{_code(type_name)}]({self._prefix}{target.file}#{target.anchor})"


# --------------------------------------------------------------------------
# Parameters and signatures
# --------------------------------------------------------------------------


def _signature_type(parameter: model.Parameter) -> str:
    """The type as a signature spells it: `Point[]`, `table<string, Point>`, `number?`."""
    if parameter.inner_type and parameter.key_type:
        text = f"table<{parameter.key_type}, {parameter.inner_type}>"
    elif parameter.inner_type:
        text = f"{parameter.inner_type}[]"
    else:
        text = parameter.type
    return f"{text}?" if parameter.nilable else text


def _signature_argument(parameter: model.Parameter) -> str:
    """`name`, `name?` when it may be left out, `name? = default` when documented."""
    optional = parameter.nilable or parameter.has_default
    text = f"{parameter.name}?" if optional else parameter.name
    if parameter.has_default:
        text += f" = {_lua_literal(parameter.default)}"
    return text


def _signature(callee: str, arguments: Sequence[model.Parameter], returns: Sequence[model.Parameter]) -> str:
    """One Lua-like line: `callee(arg1, arg2?) -> ret1: type, ret2: type?`."""
    text = f"{callee}({', '.join(_signature_argument(argument) for argument in arguments)})"
    if returns:
        text += " -> " + ", ".join(f"{value.name}: {_signature_type(value)}" for value in returns)
    return text


def _parameter_notes(parameter: model.Parameter, linker: _Linker) -> str:
    """The Notes cell: documentation first, then every marker the model carries."""
    notes: list[str] = []
    if parameter.documentation:
        notes.append(_prose(parameter.documentation))
    if parameter.inner_type:
        notes.append(f"element type {linker.type(parameter.inner_type)}")
    if parameter.key_type:
        notes.append(f"key type {linker.type(parameter.key_type)}")
    if parameter.mixin:
        notes.append(f"mixin {_code(parameter.mixin)}")
    if parameter.stride_index is not None:
        notes.append(f"stride index {parameter.stride_index}")
    if parameter.flags:
        notes.append(f"flags {_code_list(parameter.flags)}")
    if parameter.attributes:
        notes.append(f"attributes {_attributes_text(parameter.attributes)}")
    return "; ".join(notes)


ARGUMENT_HEADERS = ("Name", "Type", "Nilable", "Default", "Notes")
RETURN_HEADERS = ("Name", "Type", "Nilable", "Notes")


def _argument_row(parameter: model.Parameter, linker: _Linker) -> list[str]:
    default = _code(_lua_literal(parameter.default)) if parameter.has_default else ""
    return [
        _code(parameter.name),
        linker.type(parameter.type),
        _yes_no(parameter.nilable),
        default,
        _parameter_notes(parameter, linker),
    ]


def _return_row(parameter: model.Parameter, linker: _Linker) -> list[str]:
    return [
        _code(parameter.name),
        linker.type(parameter.type),
        _yes_no(parameter.nilable),
        _parameter_notes(parameter, linker),
    ]


def _parameter_tables(
    page: _Page,
    linker: _Linker,
    arguments: Sequence[model.Parameter],
    returns: Sequence[model.Parameter],
) -> None:
    """The `Arguments` and `Returns` tables of a function or callback, when it has them."""
    if arguments:
        page.paragraph("**Arguments**")
        page.table(ARGUMENT_HEADERS, [_argument_row(argument, linker) for argument in arguments])
    if returns:
        page.paragraph("**Returns**")
        page.table(RETURN_HEADERS, [_return_row(value, linker) for value in returns])


def _restriction_notes(function: model.Function) -> list[str]:
    notes: list[str] = []
    if function.secret_arguments:
        notes.append(f"secret arguments {_code(function.secret_arguments)}")
    if function.may_return_nothing:
        notes.append("may return nothing")
    if function.has_restrictions:
        notes.append("has restrictions")
    if function.is_protected:
        notes.append("protected")
    if function.flags:
        notes.append(f"flags {_code_list(function.flags)}")
    if function.attributes:
        notes.append(f"attributes {_attributes_text(function.attributes)}")
    return notes


# --------------------------------------------------------------------------
# Namespace pages
# --------------------------------------------------------------------------


def namespace_file(namespace: model.Namespace) -> str:
    """The reference-relative path of a namespace's page."""
    return f"{NAMESPACES_DIRECTORY}/{namespace.wrapper}.md"


def _namespace_origin(namespace: model.Namespace) -> str:
    if namespace.kind == "namespace":
        return f"Raw namespace: {_code(namespace.blizzard_namespace or namespace.system)}."
    return f"Global functions of the {_code(namespace.system)} system."


def _render_function(page: _Page, namespace: model.Namespace, function: model.Function, linker: _Linker) -> None:
    page.heading(3, function.wrapper, key=function.wrapper)
    callee = f"api.{namespace.wrapper}.{function.wrapper}"
    page.code_block("lua", _signature(callee, function.arguments, function.returns))
    if function.binding:
        page.paragraph(f"Binds to: {_code(function.binding)}.")
    page.paragraphs(function.documentation)
    _parameter_tables(page, linker, function.arguments, function.returns)
    notes = _restriction_notes(function)
    if notes:
        page.paragraph("Restrictions: " + "; ".join(notes) + ".")


def _render_namespace_page(
    namespace: model.Namespace,
    linker: _Linker,
    generated_comment: str,
) -> _Page:
    page = _Page(generated_comment)
    page.heading(1, f"api.{namespace.wrapper}", key=namespace.wrapper)
    if namespace.alias:
        page.paragraph(f"Also {_code(f'api.{namespace.alias}')}: the alias names the same table.")
    page.paragraph(_namespace_origin(namespace))
    if namespace.environment:
        page.paragraph(f"Environment: {_code(namespace.environment)}.")
    page.paragraphs(namespace.documentation)
    if namespace.sources:
        page.paragraph(f"Sources: {_code_list(namespace.sources)}.")
    page.paragraph(f"[Back to the reference index](../{INDEX_FILE})")

    page.heading(2, "Functions")
    functions = model.sorted_by_name(namespace.functions)
    if not functions:
        page.paragraph("The documentation tables list no functions for this namespace at this build.")
    for function in functions:
        _render_function(page, namespace, function, linker)
    return page


# --------------------------------------------------------------------------
# Catalogue pages
# --------------------------------------------------------------------------


def _start_catalogue(generated_comment: str, title: str, intro: str, count: int, noun: str) -> _Page:
    """A catalogue page's head: title, back link, one sentence of orientation."""
    page = _Page(generated_comment)
    page.heading(1, title)
    page.paragraph(f"[Back to the reference index]({INDEX_FILE})")
    page.paragraph(intro)
    if count == 0:
        page.paragraph(f"The documentation tables define no {noun} for this flavour at this build.")
    return page


def _event_flags(event: model.Event) -> list[str]:
    """The typed event markers that are set, in the order the tables document them."""
    markers = (("synchronous", event.synchronous), ("unique", event.unique), ("callback", event.callback))
    return [name for name, is_set in markers if is_set]


def _render_event(page: _Page, event: model.Event, linker: _Linker) -> None:
    page.heading(3, event.literal_name, key=event.literal_name)
    wrapper = _code(f"api.events.{event.wrapper}")
    page.paragraph(f"Wrapper: {wrapper} ({_code(event.name)} in the tables). System: {_code(event.system)}.")
    notes = _event_flags(event)
    if event.flags:
        notes.append(f"flags {_code_list(event.flags)}")
    if event.attributes:
        notes.append(f"attributes {_attributes_text(event.attributes)}")
    if notes:
        page.paragraph("Flags: " + "; ".join(notes) + ".")
    page.paragraphs(event.documentation)
    if event.payload:
        page.paragraph("**Payload**")
        page.table(RETURN_HEADERS, [_return_row(value, linker) for value in event.payload])


def _render_events(metadata: model.FlavourMetadata, linker: _Linker, title: str, comment: str) -> _Page:
    events = model.sorted_by_name(metadata.events)
    page = _start_catalogue(
        comment,
        title,
        "Each `api.events.<wrapper>` constant holds the event string the client fires; "
        "payloads are documented as types and have no runtime part.",
        len(events),
        "events",
    )
    for event in events:
        _render_event(page, event, linker)
    return page


def _render_enum(page: _Page, enum: model.Enum) -> None:
    page.heading(3, enum.name, key=enum.name)
    page.paragraph(f"{_code(f'Enum.{enum.name}')}, exposed as {_code(f'api.enums.{enum.wrapper}')}.")
    facts: list[str] = []
    if enum.num_values is not None:
        facts.append(f"{enum.num_values} values")
    if enum.min_value is not None:
        facts.append(f"minimum {enum.min_value}")
    if enum.max_value is not None:
        facts.append(f"maximum {enum.max_value}")
    if enum.system:
        facts.append(f"system {_code(enum.system)}")
    if facts:
        sentence = ", ".join(facts)
        page.paragraph(sentence[0].upper() + sentence[1:] + ".")
    page.paragraphs(enum.documentation)
    page.table(
        ("Field", "Value", "Notes"),
        [[_code(item.name), str(item.value), _prose(item.documentation)] for item in enum.fields],
    )


def _render_enums(metadata: model.FlavourMetadata, title: str, comment: str) -> _Page:
    enums = model.sorted_by_name(metadata.enums)
    page = _start_catalogue(
        comment,
        title,
        "Each `api.enums.<wrapper>` table is the client's own `Enum.<Name>` table, not a copy.",
        len(enums),
        "enumerations",
    )
    for enum in enums:
        _render_enum(page, enum)
    return page


def _system_and_documentation(page: _Page, system: str | None, documentation: Sequence[str]) -> None:
    if system:
        page.paragraph(f"System: {_code(system)}.")
    page.paragraphs(documentation)


def _render_structure(page: _Page, structure: model.Structure, linker: _Linker) -> None:
    page.heading(3, structure.name, key=structure.name)
    _system_and_documentation(page, structure.system, structure.documentation)
    if not structure.fields:
        page.paragraph("No fields are documented.")
        return
    page.table(
        ("Field", "Type", "Nilable", "Default", "Notes"),
        [_argument_row(item, linker) for item in structure.fields],
    )


def _render_structures(metadata: model.FlavourMetadata, linker: _Linker, title: str, comment: str) -> _Page:
    structures = model.sorted_by_name(metadata.structures)
    page = _start_catalogue(
        comment,
        title,
        "Record types functions take and return. They are types for the editor; nothing is created at runtime.",
        len(structures),
        "structures",
    )
    for structure in structures:
        _render_structure(page, structure, linker)
    return page


def _render_callback(page: _Page, callback: model.Callback, linker: _Linker) -> None:
    page.heading(3, callback.name, key=callback.name)
    page.code_block("lua", _signature("callback", callback.arguments, callback.returns))
    _system_and_documentation(page, callback.system, callback.documentation)
    _parameter_tables(page, linker, callback.arguments, callback.returns)


def _render_callbacks(metadata: model.FlavourMetadata, linker: _Linker, title: str, comment: str) -> _Page:
    callbacks = model.sorted_by_name(metadata.callbacks)
    page = _start_catalogue(
        comment,
        title,
        "Signatures of the functions the client calls back into addon code.",
        len(callbacks),
        "callbacks",
    )
    for callback in callbacks:
        _render_callback(page, callback, linker)
    return page


def _constant_row(value: model.ConstantValue, linker: _Linker) -> list[str]:
    notes: list[str] = []
    if value.expression is not None:
        shown = _code(value.expression)
        notes.append("expression")
    else:
        shown = _code(_lua_literal(value.value))
    if value.documentation:
        notes.append(_prose(value.documentation))
    return [_code(value.name), linker.type(value.type), shown, "; ".join(notes)]


def _render_constants_table(page: _Page, table: model.ConstantsTable, linker: _Linker) -> None:
    page.heading(3, table.name, key=table.name)
    page.paragraph(f"{_code(f'Constants.{table.name}')}, exposed as {_code(f'api.constants.{table.wrapper}')}.")
    _system_and_documentation(page, table.system, table.documentation)
    page.table(("Name", "Type", "Value", "Notes"), [_constant_row(value, linker) for value in table.values])


def _render_constants(metadata: model.FlavourMetadata, linker: _Linker, title: str, comment: str) -> _Page:
    tables = model.sorted_by_name(metadata.constants)
    page = _start_catalogue(
        comment,
        title,
        "Each `api.constants.<wrapper>` table is the client's own `Constants.<Name>` table. "
        "A value written as an expression is carried as the tables spell it, unevaluated.",
        len(tables),
        "constants tables",
    )
    for table in tables:
        _render_constants_table(page, table, linker)
    return page


def _render_object(page: _Page, namespace: model.Namespace) -> None:
    page.heading(3, namespace.system, key=namespace.system)
    facts: list[str] = []
    if namespace.object_type:
        facts.append(f"Object type: {_code(namespace.object_type)}.")
    if namespace.environment:
        facts.append(f"Environment: {_code(namespace.environment)}.")
    if facts:
        page.paragraph(" ".join(facts))
    page.paragraphs(namespace.documentation)
    if namespace.sources:
        page.paragraph(f"Sources: {_code_list(namespace.sources)}.")
    functions = model.sorted_by_name(namespace.functions)
    if not functions:
        page.paragraph("No methods are documented.")
        return
    page.table(
        ("Method", "Signature"),
        [
            [_code(function.name), _code(_signature(f"object:{function.name}", function.arguments, function.returns))]
            for function in functions
        ],
    )


def _render_objects(metadata: model.FlavourMetadata, title: str, comment: str) -> _Page:
    objects = _object_namespaces(metadata)
    page = _start_catalogue(
        comment,
        title,
        "Methods of script object types the client hands to addon code. They are typed for the "
        "editor and never bound: call them on the object as `object:Method(...)`.",
        len(objects),
        "object types",
    )
    for namespace in objects:
        _render_object(page, namespace)
    return page


def _render_restrictions(metadata: model.FlavourMetadata, title: str, comment: str) -> _Page:
    restrictions = model.sorted_by_system_and_name(metadata.restrictions)
    page = _start_catalogue(
        comment,
        title,
        "The predicates a function's `Restrictions` line refers to. A `precondition` must hold for the "
        "call to succeed, with the failure mode saying what happens otherwise; a `secret` predicate "
        "says when a value becomes secret.",
        len(restrictions),
        "restriction predicates",
    )
    if restrictions:
        page.table(
            ("System", "Predicate", "Kind", "Failure mode", "Notes"),
            [
                [
                    _code(item.system) if item.system else "",
                    _code(item.name),
                    item.kind,
                    _code(item.failure_mode) if item.failure_mode else "",
                    _prose(item.documentation),
                ]
                for item in restrictions
            ],
        )
    return page


# --------------------------------------------------------------------------
# The entry page
# --------------------------------------------------------------------------


@dataclass(frozen=True)
class _Counts:
    """The numbers the entry page's counts table shows."""

    namespaces: int
    objects: int
    functions: int
    events: int
    enums: int
    structures: int
    callbacks: int
    constants: int
    restrictions: int

    def rows(self) -> list[list[str]]:
        return [
            ["Namespaces (`C_*` namespaces and global systems)", str(self.namespaces)],
            ["Object types", str(self.objects)],
            ["Functions (including object methods)", str(self.functions)],
            ["Events", str(self.events)],
            ["Enumerations", str(self.enums)],
            ["Structures", str(self.structures)],
            ["Callbacks", str(self.callbacks)],
            ["Constants tables", str(self.constants)],
            ["Restriction predicates", str(self.restrictions)],
        ]


def reference_counts(metadata: model.FlavourMetadata) -> dict[str, int]:
    """The counts the entry page shows, by row key, for tests and the change report."""
    counts = _counts(metadata)
    return {
        "namespaces": counts.namespaces,
        "objects": counts.objects,
        "functions": counts.functions,
        "events": counts.events,
        "enums": counts.enums,
        "structures": counts.structures,
        "callbacks": counts.callbacks,
        "constants": counts.constants,
        "restrictions": counts.restrictions,
    }


def _counts(metadata: model.FlavourMetadata) -> _Counts:
    return _Counts(
        namespaces=len(_bound_namespaces(metadata)),
        objects=len(_object_namespaces(metadata)),
        functions=sum(len(space.functions) for space in metadata.namespaces),
        events=len(metadata.events),
        enums=len(metadata.enums),
        structures=len(metadata.structures),
        callbacks=len(metadata.callbacks),
        constants=len(metadata.constants),
        restrictions=len(metadata.restrictions),
    )


def _provenance_paragraph(provenance: model.Provenance) -> str:
    return (
        f"Generated from the client's own API documentation tables as published by "
        f"{_code(provenance.repository)}, branch {_code(provenance.branch)}, commit "
        f"{_code(provenance.commit)} ({_code(provenance.subject)}, committed {provenance.committed_at}): "
        f"client version {_code(provenance.version or 'unknown')}, build "
        f"{_code(str(provenance.build) if provenance.build is not None else 'unknown')}, "
        f"captured on {provenance.captured_on} from {_code(provenance.documentation_path)} "
        f"({provenance.file_count} documentation files). Everything below describes that build."
    )


def _usage_section(page: _Page, flavour: flavours.Flavour) -> None:
    page.heading(2, "How to use")
    page.paragraph("Take a file-local alias of the flavour's namespace and call wrappers through it:")
    page.code_block("lua", f"local api = {flavour.namespace}")
    page.paragraph(
        f"When another addon owns the short `wow` global, the same table is `MoltenCodes.{flavour.namespace}`. "
        "Every wrapper is a direct alias of the Blizzard function, so raw Blizzard calls stay valid: "
        "the `Binds to` line of each function names the raw expression, and calling it directly is "
        "always allowed."
    )


def _namespace_row(namespace: model.Namespace) -> list[str]:
    raw = _code(namespace.blizzard_namespace) if namespace.kind == "namespace" else f"{_code(namespace.system)} system"
    return [
        f"[{_code(f'api.{namespace.wrapper}')}]({namespace_file(namespace)})",
        raw,
        namespace.kind,
        str(len(namespace.functions)),
        _code(f"api.{namespace.alias}") if namespace.alias else "",
    ]


def _render_index(
    metadata: model.FlavourMetadata,
    flavour: flavours.Flavour,
    titles: dict[str, str],
    comment: str,
) -> _Page:
    page = _Page(comment)
    page.heading(1, f"{flavour.display_name} API reference ({flavour.namespace})")
    page.paragraph(_provenance_paragraph(metadata.provenance))
    _usage_section(page, flavour)

    page.heading(2, "What this build documents")
    page.table(("Kind", "Count"), _counts(metadata).rows())

    page.heading(2, "Namespaces")
    page.paragraph("Each wrapper table has a page of its own; `Raw` is what it aliases.")
    page.table(
        ("Wrapper", "Raw", "Kind", "Functions", "Alias"),
        [_namespace_row(namespace) for namespace in _bound_namespaces(metadata)],
    )

    page.heading(2, "Other files")
    page.bullet_list(f"[{titles[file_name]}]({file_name})" for file_name in CATALOGUE_FILES)
    return page


# --------------------------------------------------------------------------
# Rendering everything
# --------------------------------------------------------------------------


@dataclass(frozen=True)
class _Rendered:
    """The rendered pages and, per file, the anchors of the keyed headings."""

    files: dict[str, str]
    anchors: dict[str, dict[str, str]]


def _reject_file_name_collisions(file_names: Iterable[str]) -> None:
    """Two wrappers differing only by case would be one file on macOS and Windows."""
    seen: dict[str, str] = {}
    for name in file_names:
        folded = name.casefold()
        if folded in seen and seen[folded] != name:
            raise ReferenceRenderError(f"reference files {seen[folded]!r} and {name!r} differ only by case")
        seen[folded] = name


def _render(metadata: model.FlavourMetadata, flavour: flavours.Flavour) -> _Rendered:
    comment = _generated_comment(metadata, flavour)
    titles = _catalogue_titles(flavour)
    targets = _type_targets(metadata, titles)
    top_linker = _Linker(targets, "")
    nested_linker = _Linker(targets, "../")

    pages: dict[str, _Page] = {
        INDEX_FILE: _render_index(metadata, flavour, titles, comment),
        EVENTS_FILE: _render_events(metadata, top_linker, titles[EVENTS_FILE], comment),
        ENUMS_FILE: _render_enums(metadata, titles[ENUMS_FILE], comment),
        STRUCTURES_FILE: _render_structures(metadata, top_linker, titles[STRUCTURES_FILE], comment),
        CALLBACKS_FILE: _render_callbacks(metadata, top_linker, titles[CALLBACKS_FILE], comment),
        CONSTANTS_FILE: _render_constants(metadata, top_linker, titles[CONSTANTS_FILE], comment),
        OBJECTS_FILE: _render_objects(metadata, titles[OBJECTS_FILE], comment),
        RESTRICTIONS_FILE: _render_restrictions(metadata, titles[RESTRICTIONS_FILE], comment),
    }
    for namespace in _bound_namespaces(metadata):
        pages[namespace_file(namespace)] = _render_namespace_page(namespace, nested_linker, comment)
    _reject_file_name_collisions(pages)

    ordered = sorted(pages)
    return _Rendered(
        files={name: pages[name].text() for name in ordered},
        anchors={name: dict(pages[name].anchors) for name in ordered},
    )


def render_reference(metadata: model.FlavourMetadata, flavour: flavours.Flavour) -> dict[str, str]:
    """Render the flavour's reference as `{reference-relative path: Markdown text}`.

    The result is deterministic for equal metadata. It is not link-checked
    here; the generator runs `check_links` over it and refuses to write a
    reference with a broken link, so the check stays a separate, testable step.
    Raises `ReferenceRenderError` when two pages would share a file name on a
    case-insensitive file system.
    """
    return _render(metadata, flavour).files


# --------------------------------------------------------------------------
# Search index
# --------------------------------------------------------------------------


def summarise(documentation: Sequence[str], limit: int = SUMMARY_LENGTH) -> str:
    """The first documentation paragraph, cut at a word boundary to fit `limit` characters.

    A cut summary ends in `SUMMARY_ELLIPSIS`, counted inside the limit, so an
    index entry never exceeds `limit` characters and never ends mid-word.
    Returns "" when there is no documentation.
    """
    if not documentation:
        return ""
    text = " ".join(documentation[0].split())
    if len(text) <= limit:
        return text
    room = limit - len(SUMMARY_ELLIPSIS)
    cut = text.rfind(" ", 0, room + 1)
    head = text[:cut] if cut > 0 else text[:room]
    return head.rstrip() + SUMMARY_ELLIPSIS


def _entry(kind: str, name: str, wrapper: str, path: str, documentation: Sequence[str]) -> dict[str, str]:
    return {"kind": kind, "name": name, "wrapper": wrapper, "path": path, "summary": summarise(documentation)}


def _namespace_entries(namespace: model.Namespace, anchors: dict[str, str]) -> list[dict[str, str]]:
    file_name = namespace_file(namespace)
    raw_name = namespace.blizzard_namespace if namespace.kind == "namespace" else namespace.system
    entries = [
        _entry(
            "namespace",
            raw_name or namespace.system,
            f"api.{namespace.wrapper}",
            f"{file_name}#{anchors[namespace.wrapper]}",
            namespace.documentation,
        )
    ]
    for function in namespace.functions:
        entries.append(
            _entry(
                "function",
                function.binding or function.name,
                f"api.{namespace.wrapper}.{function.wrapper}",
                f"{file_name}#{anchors[function.wrapper]}",
                function.documentation,
            )
        )
    return entries


def _object_entries(namespace: model.Namespace, anchors: dict[str, str]) -> list[dict[str, str]]:
    """An object type and its methods all point at the object's section: methods have no heading."""
    path = f"{OBJECTS_FILE}#{anchors[namespace.system]}"
    entries = [_entry("object", namespace.system, "", path, namespace.documentation)]
    for function in namespace.functions:
        entries.append(_entry("method", f"{namespace.system}:{function.name}", "", path, function.documentation))
    return entries


def _catalogue_entries(metadata: model.FlavourMetadata, anchors: dict[str, dict[str, str]]) -> list[dict[str, str]]:
    entries: list[dict[str, str]] = []
    for event in metadata.events:
        path = f"{EVENTS_FILE}#{anchors[EVENTS_FILE][event.literal_name]}"
        entries.append(_entry("event", event.literal_name, f"api.events.{event.wrapper}", path, event.documentation))
    for enum in metadata.enums:
        path = f"{ENUMS_FILE}#{anchors[ENUMS_FILE][enum.name]}"
        entries.append(_entry("enum", f"Enum.{enum.name}", f"api.enums.{enum.wrapper}", path, enum.documentation))
    for structure in metadata.structures:
        path = f"{STRUCTURES_FILE}#{anchors[STRUCTURES_FILE][structure.name]}"
        entries.append(_entry("structure", structure.name, "", path, structure.documentation))
    for callback in metadata.callbacks:
        path = f"{CALLBACKS_FILE}#{anchors[CALLBACKS_FILE][callback.name]}"
        entries.append(_entry("callback", callback.name, "", path, callback.documentation))
    for table in metadata.constants:
        path = f"{CONSTANTS_FILE}#{anchors[CONSTANTS_FILE][table.name]}"
        wrapper = f"api.constants.{table.wrapper}"
        entries.append(_entry("constants", f"Constants.{table.name}", wrapper, path, table.documentation))
    for restriction in metadata.restrictions:
        # Predicates share one table, so the entry points at the file itself.
        name = f"{restriction.system}.{restriction.name}" if restriction.system else restriction.name
        entries.append(_entry("restriction", name, "", RESTRICTIONS_FILE, restriction.documentation))
    return entries


def render_search_index(metadata: model.FlavourMetadata, flavour: flavours.Flavour) -> dict[str, Any]:
    """Render the JSON-able search index of the flavour's reference.

    The shape is `{"schema": 1, "flavour": id, "build": build or None,
    "entries": [...]}`, every entry `{kind, name, wrapper, path, summary}`:
    `name` is the raw name a reader knows (`C_AddOns.DisableAddOn`,
    `ADDON_LOADED`, `Enum.ItemQuality`), `wrapper` the MoltenCodes spelling or
    "" for entries with no runtime part, `path` the reference file plus the
    `#anchor` of the entry's section, `summary` the first documentation
    paragraph cut to `SUMMARY_LENGTH` characters at a word boundary. Entries
    are sorted by kind, then name, then wrapper and path so the file is
    byte-stable. Rendering the reference is how the anchors are known, so this
    costs one render of the pages.
    """
    rendered = _render(metadata, flavour)
    entries: list[dict[str, str]] = []
    for namespace in metadata.namespaces:
        if namespace.kind == "object":
            entries.extend(_object_entries(namespace, rendered.anchors[OBJECTS_FILE]))
        else:
            entries.extend(_namespace_entries(namespace, rendered.anchors[namespace_file(namespace)]))
    entries.extend(_catalogue_entries(metadata, rendered.anchors))
    entries.sort(key=lambda entry: (entry["kind"], entry["name"], entry["wrapper"], entry["path"]))
    return {
        "schema": SEARCH_INDEX_SCHEMA,
        "flavour": flavour.id,
        "build": metadata.provenance.build,
        "entries": entries,
    }
