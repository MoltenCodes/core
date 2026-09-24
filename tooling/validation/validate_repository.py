"""Validate repository structure, documentation navigation, and package layout."""

from __future__ import annotations

import json
import re
import sys
from pathlib import Path
from urllib.parse import unquote

from tooling.api import flavours
from tooling.package.build import top_level_lua_files
from tooling.validation.interface_numbers import (
    SupportedClients,
    load_supported_clients,
)
from tooling.validation.validate_manifests import (
    ROOT,
    error,
    is_development,
    load_manifests,
    package_directories,
    validate_graph,
)


REQUIRED_ROOT_FILES = (
    Path(".pkgmeta"),
    Path("README.md"),
    Path("LICENSE"),
    Path("docs/README.md"),
    Path("docs/ARCHITECTURE.md"),
    Path("docs/CONTRIBUTING.md"),
    Path("docs/DESIGN_CONSTITUTION.md"),
    Path("docs/DEVELOPMENT.md"),
    Path("docs/EMBEDDING.md"),
    Path("docs/PACKAGE_MANIFEST.md"),
    Path("docs/RELEASES.md"),
    Path("docs/TESTING.md"),
    Path("docs/TOOLING.md"),
    Path("examples/Core.lua"),
    Path("examples/ExampleAddon.toc"),
    Path("examples/embeds.xml"),
)

#: Name of the lua-language-server configuration each package source directory
#: owns. `lua-language-server --check <dir>` treats `<dir>` as its workspace
#: root and does not look in parent directories, so the configuration that makes
#: the shared `meta/` definitions and the package's dependencies resolvable has
#: to live next to the sources it applies to.
LANGUAGE_SERVER_CONFIG_NAME = ".luarc.json"

#: Path from a package source directory to the shared editor metadata.
SHARED_META_LIBRARY = "../../../meta"

#: Path from `examples/` to the shared editor metadata. The example addon is
#: type-checked with `examples/` as the workspace root, so it owns a
#: configuration of its own and reaches `meta/` one level up instead of three.
EXAMPLE_SHARED_META_LIBRARY = "../meta"

#: The example addon's load list, which is also what a consuming addon copies.
EXAMPLE_EMBEDS = Path("examples/embeds.xml")

#: A `<Script file="Libs\MoltenCodes\signalKit\SignalKit.lua" />` entry in
#: `examples/embeds.xml`. The example ships the Windows-style separators the
#: client expects, so the file name is taken from either separator.
EMBEDDED_SCRIPT_RE = re.compile(r'<Script\s+file="([^"]+)"\s*/>')

PACKAGE_REQUIRED_FILES = (
    Path("README.md"),
    Path("CHANGELOG.md"),
    Path("package.manifest.json"),
)

#: Oldest Python the repository tooling supports. Keep this in step with
#: `requires-python` in `pyproject.toml`; `validate_python_version` compares the
#: two so the declaration and the check can never drift apart.
PYTHON_FLOOR = (3, 10)

#: `requires-python` in `pyproject.toml`, which the floor above must match.
REQUIRES_PYTHON_RE = re.compile(r'^\s*requires-python\s*=\s*"\s*>=\s*([0-9]+)\.([0-9]+)', re.M)

#: The supported-client table, relative to the repository root. It is the one
#: place the supported `## Interface` numbers are written by hand; see
#: `tooling/validation/interface_numbers.py`.
SUPPORTED_CLIENTS = Path("tooling/validation/supported_clients.json")

#: Documents that must quote the supported `## Interface` line at least once,
#: each occurrence equal to the table. `examples/*.toc` is checked as well, by
#: glob, so a second example addon is covered without editing this list.
REQUIRED_INTERFACE_DOCUMENTS = (
    Path("docs/EMBEDDING.md"),
    Path("packages/registry/docs/API.md"),
)

#: Documents that need not quote an `## Interface` line, but whose every
#: occurrence must equal the table when they do.
OPTIONAL_INTERFACE_DOCUMENTS = (Path("README.md"),)

#: The document whose supported-client table is checked row by row.
SUPPORTED_CLIENTS_DOCUMENT = Path("docs/EMBEDDING.md")

#: The heading of the section in `SUPPORTED_CLIENTS_DOCUMENT` holding that table.
SUPPORTED_CLIENTS_HEADING = "## Supported client versions"

#: An `## Interface: 120100, 50504` line, in a `.toc` or quoted in a document.
#: The name must be followed directly by a colon, so a per-flavour field such as
#: `## Interface-Mists:` is not mistaken for it.
INTERFACE_LINE_RE = re.compile(r"^[ \t]*##[ \t]*Interface[ \t]*:[ \t]*(.*?)[ \t]*$", re.M)

#: A row of the supported-client table: a cell holding a backticked number.
SUPPORTED_CLIENT_ROW_RE = re.compile(r"^\|.*\|[ \t]*`[0-9]+`[ \t]*\|.*\|[ \t]*$", re.M)

#: The packager metadata whose `ignore:` list must hold every development package.
PKGMETA = Path(".pkgmeta")

#: A YAML comment after a value: a `#` preceded by whitespace, to the line end.
TRAILING_YAML_COMMENT_RE = re.compile(r"\s+#.*$")

MARKDOWN_LINK_RE = re.compile(r"!?\[[^\]]*\]\(([^)]+)\)")

#: Package documentation directories whose Markdown is generated from data
#: rather than written: the API reference and the build-to-build change reports
#: of `apiKit` (`docs/API_KIT_DESIGN.md`, section 13). The generator that will
#: write them (roadmap step H2) validates its own output, so the link check
#: (and, through `cspell.json`, the spell check) leaves them alone. Each entry
#: is the two path segments under `packages/<name>/`.
GENERATED_DOCUMENT_DIRECTORIES = {
    ("docs", "reference"),
    ("docs", "changes"),
}

#: Directories whose contents are never source documentation.
IGNORED_DIRECTORY_NAMES = {
    ".git",
    ".luarocks",
    ".mypy_cache",
    ".pytest_cache",
    ".ruff_cache",
    ".venv",
    "__pycache__",
    "build",
    "coverage",
    "dist",
    "htmlcov",
    "reports",
    "venv",
}


def format_version(version: tuple[int, int]) -> str:
    """Render a (major, minor) version the way a person writes it."""
    return f"{version[0]}.{version[1]}"


def validate_python_version(running: tuple[int, int] | None = None) -> list[str]:
    """Refuse to certify the repository from a Python older than the declared floor.

    The tooling is written against `PYTHON_FLOOR`, so an older interpreter can
    fail later with a syntax error or a missing standard-library method rather
    than with something a reader can act on. Failing here says which version is
    running, which one is required, and where that requirement is written down.
    """
    errors: list[str] = []

    if running is None:
        running = sys.version_info[:2]

    pyproject = ROOT / "pyproject.toml"
    if not pyproject.is_file():
        errors.append(error(Path("pyproject.toml"), "missing; it declares requires-python"))
    else:
        declared = REQUIRES_PYTHON_RE.search(pyproject.read_text(encoding="utf-8"))
        if declared is None:
            errors.append(
                error(Path("pyproject.toml"), 'no `requires-python = ">=X.Y"` declaration')
            )
        elif (int(declared.group(1)), int(declared.group(2))) != PYTHON_FLOOR:
            errors.append(
                error(
                    Path("pyproject.toml"),
                    f"requires-python is >={declared.group(1)}.{declared.group(2)} but "
                    f"tooling declares a {format_version(PYTHON_FLOOR)} floor",
                )
            )

    if running < PYTHON_FLOOR:
        errors.append(
            f"python {format_version(running)} is older than the supported floor "
            f"{format_version(PYTHON_FLOOR)}; see requires-python in pyproject.toml"
        )

    return errors


def validate_required_root_files() -> list[str]:
    """Check that the repository's documented navigation surface exists."""
    errors: list[str] = []
    for relative in REQUIRED_ROOT_FILES:
        path = ROOT / relative
        if not path.is_file():
            errors.append(error(path, "required repository file is missing"))
    return errors


def _dependency_closure(package_name: str, manifests: dict[str, dict[str, object]]) -> list[str]:
    """Return the transitive runtime dependencies of one package, dependency-first."""
    resolved: list[str] = []
    seen: set[str] = set()

    def visit(name: str) -> None:
        dependencies = manifests[name].get("dependencies", {})
        if not isinstance(dependencies, dict):
            return
        for dependency in sorted(dependencies):
            if dependency in manifests and dependency not in seen:
                seen.add(dependency)
                visit(dependency)
                resolved.append(dependency)

    visit(package_name)
    return resolved


def validate_workspace_library(path: Path, expected: list[str]) -> list[str]:
    """Check one lua-language-server configuration's `workspace.library` list.

    Every `.luarc.json` in the repository is generated knowledge: the list is
    derived from what the directory actually depends on, so the check reports
    the whole expected list rather than the first entry that differs. That is
    the text a contributor pastes to fix the file.
    """
    if not path.is_file():
        return [error(path, "required lua-language-server configuration is missing")]

    try:
        config = json.loads(path.read_text(encoding="utf-8"))
    except (OSError, json.JSONDecodeError) as exc:
        return [error(path, f"unable to read configuration: {exc}")]

    workspace = config.get("workspace") if isinstance(config, dict) else None
    library = workspace.get("library") if isinstance(workspace, dict) else None
    if library != expected:
        return [error(path, f"workspace.library must be {json.dumps(expected)}")]

    return []


def embedded_script_names(embeds: Path) -> list[str]:
    """Return the Lua file names an `embeds.xml` loads, in the order it loads them.

    A reference is written the way the client reads it, as a path under the
    consuming addon (`Libs\\MoltenCodes\\signalKit\\SignalKit.lua`); only the
    file name at its end identifies the package.
    """
    references = EMBEDDED_SCRIPT_RE.findall(embeds.read_text(encoding="utf-8"))
    return [reference.replace("\\", "/").rsplit("/", 1)[-1] for reference in references]


def package_id_for(script_name: str) -> str:
    """Map a Lua facade file name (`SignalKit.lua`) to its package ID (`signalKit`).

    The two spellings of one package are a convention `docs/PACKAGE_MANIFEST.md`
    requires: lowerCamelCase for the package and its directory, PascalCase for
    the Lua facade it publishes.
    """
    facade = script_name[: -len(".lua")] if script_name.endswith(".lua") else script_name
    return facade[:1].lower() + facade[1:]


def embedded_package_names(embeds: Path) -> list[str]:
    """Return the package IDs an `embeds.xml` loads, in the order it loads them."""
    return [package_id_for(script) for script in embedded_script_names(embeds)]


def validate_example_language_server_config() -> list[str]:
    """Check that the example addon is type-checked against exactly what it embeds.

    `examples/.luarc.json` is a workspace root like a package source directory,
    so it is validated the same way, against the same shared `meta/` entry. The
    difference is where its expected list comes from: not the manifests, but
    `examples/embeds.xml`, which is the file the example actually loads at run
    time. Listing a package the example does not embed would let the example
    type-check against code a reader copying it would never ship, which is the
    one mistake this file can make that nothing else would catch.
    """
    embeds = ROOT / EXAMPLE_EMBEDS
    if not embeds.is_file():
        # `validate_required_root_files` already reports the missing file; there
        # is nothing to derive an expected library list from.
        return []

    expected = [EXAMPLE_SHARED_META_LIBRARY]
    expected.extend(f"../packages/{name}/src" for name in embedded_package_names(embeds))

    return validate_workspace_library(
        ROOT / "examples" / LANGUAGE_SERVER_CONFIG_NAME, expected
    )


def validate_language_server_configs(manifests: dict[str, dict[str, object]]) -> list[str]:
    """Check that every package source directory can be type-checked on its own.

    The expected library list is derived from the manifests rather than stored
    twice, so adding a dependency and forgetting the editor configuration is a
    validation error instead of a warning that only appears in an editor.
    """
    errors: list[str] = []

    for name in sorted(manifests):
        expected = [SHARED_META_LIBRARY]
        expected.extend(
            f"../../{dependency}/src" for dependency in _dependency_closure(name, manifests)
        )
        path = ROOT / "packages" / name / "src" / LANGUAGE_SERVER_CONFIG_NAME
        errors.extend(validate_workspace_library(path, expected))

    return errors


def is_generated_documentation(path: Path) -> bool:
    """Whether `path` lies in a package's generated documentation directory.

    A path outside the repository is never generated documentation.
    """
    try:
        relative = path.resolve().relative_to(ROOT.resolve())
    except ValueError:
        return False
    parts = relative.parts
    inside_a_package = len(parts) >= 4 and parts[0] == "packages"
    if not inside_a_package:
        return False
    documentation_directory = (parts[2], parts[3])
    return documentation_directory in GENERATED_DOCUMENT_DIRECTORIES


def read_display_name(package_dir: Path) -> str | None:
    """Return the manifest's `displayName`, or `None` when it cannot be read.

    The manifest checks report a missing or malformed manifest themselves; this
    helper only feeds the facade check, which is skipped without a name.
    """
    manifest_path = package_dir / "package.manifest.json"
    try:
        manifest = json.loads(manifest_path.read_text(encoding="utf-8"))
    except (OSError, json.JSONDecodeError):
        return None
    display_name = manifest.get("displayName") if isinstance(manifest, dict) else None
    return display_name if isinstance(display_name, str) and display_name.strip() else None


def validate_facade_file(package_dir: Path) -> list[str]:
    """Check that `src/` holds exactly one top-level Lua file, named after the facade.

    The facade (`src/<displayName>.lua`) is the first file of the package the
    client loads and the file every consumer's `.toc` or `embeds.xml` names.
    Further runtime files live in subdirectories of `src/` and load after it
    (`tooling.package.build.runtime_files`); a second top-level Lua file would
    leave that order ambiguous.
    """
    source_dir = package_dir / "src"
    top_level = top_level_lua_files(source_dir)
    if not top_level:
        return [error(source_dir, "no top-level Lua facade was found")]
    if len(top_level) > 1:
        names = ", ".join(path.name for path in top_level)
        return [error(source_dir, f"expected one top-level Lua facade, found {names}")]

    display_name = read_display_name(package_dir)
    if display_name is not None and top_level[0].name != f"{display_name}.lua":
        return [
            error(
                top_level[0],
                f'facade file must be named after the manifest displayName: "{display_name}.lua"',
            )
        ]
    return []


def validate_package_layout() -> list[str]:
    """Check the minimum self-contained layout of every publishable package."""
    errors: list[str] = []

    for package_dir in package_directories():
        for relative in PACKAGE_REQUIRED_FILES:
            path = package_dir / relative
            if not path.is_file():
                errors.append(error(path, "required package file is missing"))

        source_dir = package_dir / "src"
        if not source_dir.is_dir():
            errors.append(error(source_dir, "required package source directory is missing"))
        elif not any(source_dir.rglob("*.lua")):
            errors.append(error(source_dir, "no Lua source files were found"))
        else:
            errors.extend(validate_facade_file(package_dir))

        tests_dir = package_dir / "tests"
        if not tests_dir.is_dir():
            errors.append(error(tests_dir, "required package tests directory is missing"))
        elif not any(tests_dir.rglob("*_spec.lua")):
            errors.append(error(tests_dir, "no Busted *_spec.lua tests were found"))

        manifest_path = package_dir / "package.manifest.json"
        if manifest_path.is_file():
            try:
                manifest = json.loads(manifest_path.read_text(encoding="utf-8"))
            except (OSError, json.JSONDecodeError):
                manifest = None

            if isinstance(manifest, dict) and "api" in manifest:
                api_doc = package_dir / "docs" / "API.md"
                if not api_doc.is_file():
                    errors.append(error(api_doc, "API package is missing docs/API.md"))

    return errors


def parse_interface_numbers(value: str) -> list[int] | None:
    """Parse the value of an `## Interface` line, or return `None` if it is malformed."""
    numbers: list[int] = []
    for item in value.split(","):
        item = item.strip()
        if not item.isdigit():
            return None
        numbers.append(int(item))
    return numbers


def validate_interface_lines(
    path: Path, expected: SupportedClients, *, required: bool
) -> list[str]:
    """Check every `## Interface` line in one file against the supported-client table.

    A line listing several numbers claims to support every client, so it must
    list exactly the table's numbers. The comparison is by set: the client reads
    them in any order, and an addon's `.toc` is not wrong for listing them in a
    different one. A line listing a single number is a per-flavour example (a
    `_Mainline.toc`, say), so that number need only be one of the table's. A
    missing, extra or malformed number is an error, and the message carries the
    line to paste, which is what `python3 -m tooling.validation.interface_numbers`
    prints.
    """
    if not path.is_file():
        # A missing required document is `validate_required_root_files`' error.
        return []

    lines = INTERFACE_LINE_RE.findall(path.read_text(encoding="utf-8"))
    if not lines:
        if required:
            return [error(path, f'no "## Interface" line; expected "{expected.toc_line()}"')]
        return []

    wanted = set(expected.interface_numbers())
    errors: list[str] = []
    for value in lines:
        numbers = parse_interface_numbers(value)
        if numbers is not None and len(numbers) == 1:
            if numbers[0] not in wanted:
                errors.append(
                    error(
                        path,
                        f'"## Interface: {value}" is not a supported client in '
                        f"{SUPPORTED_CLIENTS}; supported: {expected.toc_line()[len('## Interface: '):]}",
                    )
                )
            continue
        if numbers is None or set(numbers) != wanted or len(numbers) != len(wanted):
            errors.append(
                error(
                    path,
                    f'"## Interface: {value}" does not match {SUPPORTED_CLIENTS}; '
                    f'expected "{expected.toc_line()}"',
                )
            )
    return errors


def markdown_section(text: str, heading: str) -> str | None:
    """Return the text under a level-two `heading`, up to the next level-two heading.

    Lines inside fenced code blocks are never headings, which matters here: the
    `## Interface` line of a quoted `.toc` looks exactly like one.
    """
    collected: list[str] | None = None
    fence: str | None = None
    for line in text.splitlines():
        stripped = line.lstrip()
        marker = stripped[:3] if stripped.startswith(("```", "~~~")) else None
        if marker is not None and fence is None:
            fence = marker
        elif marker is not None and marker == fence:
            # A fence closes only with the character that opened it, so a
            # `~~~` inside a backtick block is content, not a closing fence.
            fence = None
        elif fence is None and line.startswith("## "):
            if collected is not None:
                break
            if line.rstrip() == heading:
                collected = []
                continue
        if collected is not None:
            collected.append(line)
    return None if collected is None else "\n".join(collected)


def validate_supported_client_table(path: Path, expected: SupportedClients) -> list[str]:
    """Check the supported-client table in `docs/EMBEDDING.md` row by row.

    The rows must be exactly what `interface_numbers --table` prints, in the
    same order, and the section must state the table's verification date, so a
    bump that forgets the prose is caught as well as one that forgets a number.
    """
    if not path.is_file():
        return []

    section = markdown_section(path.read_text(encoding="utf-8"), SUPPORTED_CLIENTS_HEADING)
    if section is None:
        return [error(path, f'no "{SUPPORTED_CLIENTS_HEADING}" section')]

    errors: list[str] = []
    rows = [row.rstrip() for row in SUPPORTED_CLIENT_ROW_RE.findall(section)]
    if rows != expected.markdown_rows():
        errors.append(
            error(
                path,
                f"supported-client table does not match {SUPPORTED_CLIENTS}; expected rows:\n"
                + "\n".join(f"      {row}" for row in expected.markdown_rows()),
            )
        )
    if expected.verified not in section:
        errors.append(
            error(
                path,
                f'"{SUPPORTED_CLIENTS_HEADING}" does not state the verification date '
                f"{expected.verified} recorded in {SUPPORTED_CLIENTS}",
            )
        )
    return errors


def validate_interface_numbers(expected: SupportedClients | None = None) -> list[str]:
    """Check that every quoted `## Interface` number agrees with the one table.

    `expected` defaults to the table in the repository; tests pass their own.
    """
    if expected is None:
        table_path = ROOT / SUPPORTED_CLIENTS
        try:
            expected = load_supported_clients(table_path)
        except (OSError, ValueError) as exc:
            return [error(table_path, f"unable to read the supported-client table: {exc}")]

    errors: list[str] = []

    tables = sorted((ROOT / "examples").glob("*.toc"))
    if not tables:
        errors.append(error(ROOT / "examples", "no .toc file to check Interface numbers in"))
    for toc in tables:
        errors.extend(validate_interface_lines(toc, expected, required=True))

    for relative in REQUIRED_INTERFACE_DOCUMENTS:
        errors.extend(validate_interface_lines(ROOT / relative, expected, required=True))
    for relative in OPTIONAL_INTERFACE_DOCUMENTS:
        errors.extend(validate_interface_lines(ROOT / relative, expected, required=False))

    errors.extend(validate_supported_client_table(ROOT / SUPPORTED_CLIENTS_DOCUMENT, expected))
    return errors


def pkgmeta_ignore_entries(text: str) -> list[str]:
    """Return the entries of the top-level `ignore:` list in a `.pkgmeta` file.

    `.pkgmeta` is YAML, but only this one block-list shape is read, so the
    standard library suffices: the `ignore:` key at column 0, followed by
    indented `- entry` lines, ending at the next line that starts at column 0.
    Comments and blank lines inside the list are skipped, and so is a trailing
    ` # comment` after an entry, as YAML reads it.
    """
    entries: list[str] = []
    in_ignore = False
    for line in text.splitlines():
        stripped = line.strip()
        if not stripped or stripped.startswith("#"):
            continue
        if not line[0].isspace():
            in_ignore = stripped == "ignore:"
            continue
        if in_ignore and stripped.startswith("- "):
            entry = TRAILING_YAML_COMMENT_RE.sub("", stripped[2:]).strip()
            entries.append(entry.strip("\"'").rstrip("/"))
    return entries


def validate_development_packages_ignored(manifests: dict[str, dict[str, object]]) -> list[str]:
    """Check that the packager ignores every development package.

    The local builder skips development packages on its own, but the BigWigs
    packager copies whatever `.pkgmeta` does not ignore. A development package
    missing from `ignore:` would therefore ship to the addon sites.
    """
    development = sorted(name for name, data in manifests.items() if is_development(data))
    if not development:
        return []

    path = ROOT / PKGMETA
    if not path.is_file():
        # `validate_required_root_files` already reports the missing file.
        return []

    ignored = set(pkgmeta_ignore_entries(path.read_text(encoding="utf-8")))
    return [
        error(
            path,
            f'development package "{name}" is not ignored; add "  - packages/{name}" '
            'under "ignore:"',
        )
        for name in development
        if f"packages/{name}" not in ignored
    ]


def validate_api_flavours() -> list[str]:
    """Check the apiKit flavour table, `tooling/api/flavours.json`.

    The table is read by the API metadata tooling; a malformed entry would
    surface late, inside a fetch or a generation, so the validator reads it
    with the same loader and reports its problems here.
    """
    try:
        flavours.load_flavours(ROOT / flavours.FLAVOURS_PATH)
    except (OSError, ValueError) as failure:
        return [error(ROOT / flavours.FLAVOURS_PATH, str(failure))]
    return []


def _is_external_link(target: str) -> bool:
    lowered = target.lower()
    return (
        "://" in target
        or lowered.startswith("mailto:")
        or lowered.startswith("tel:")
        or target.startswith("#")
    )


def validate_markdown_links() -> list[str]:
    """Validate repository-relative file targets in Markdown links and images."""
    errors: list[str] = []

    for markdown in sorted(ROOT.rglob("*.md")):
        # Generated and local-environment trees are not source documentation.
        if any(part in IGNORED_DIRECTORY_NAMES for part in markdown.parts):
            continue
        if is_generated_documentation(markdown):
            continue

        try:
            text = markdown.read_text(encoding="utf-8")
        except OSError as exc:
            errors.append(error(markdown, f"unable to read Markdown: {exc}"))
            continue

        for match in MARKDOWN_LINK_RE.finditer(text):
            raw_target = match.group(1).strip()
            if not raw_target or _is_external_link(raw_target):
                continue

            # Markdown titles after a URL are intentionally not supported in
            # repository-relative links; keeping links simple improves tooling.
            target = unquote(raw_target.split("#", 1)[0])
            target_path = (markdown.parent / target).resolve()
            if not target_path.is_relative_to(ROOT.resolve()):
                errors.append(error(markdown, f'relative link escapes repository "{raw_target}"'))
            elif not target_path.exists():
                errors.append(error(markdown, f'broken relative link target "{raw_target}"'))

    return errors


def validate_repository() -> tuple[dict[str, dict[str, object]], list[str]]:
    """Run all repository checks and return loaded package manifests plus errors."""
    errors = validate_python_version()
    manifests, manifest_errors = load_manifests()
    errors.extend(manifest_errors)
    errors.extend(validate_graph(manifests))
    errors.extend(validate_required_root_files())
    errors.extend(validate_language_server_configs(manifests))
    errors.extend(validate_example_language_server_config())
    errors.extend(validate_package_layout())
    errors.extend(validate_interface_numbers())
    errors.extend(validate_api_flavours())
    errors.extend(validate_development_packages_ignored(manifests))
    errors.extend(validate_markdown_links())
    return manifests, errors


def main() -> int:
    manifests, errors = validate_repository()

    if errors:
        print(f"Repository validation failed with {len(errors)} error(s):", file=sys.stderr)
        for item in errors:
            print(f"  - {item}", file=sys.stderr)
        return 1

    print(f"Repository validation passed for {len(manifests)} package(s).")
    for name in sorted(manifests):
        print(f"  - {name}")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
