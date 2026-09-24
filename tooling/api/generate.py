"""Generate every apiKit output of one flavour from its metadata.

    python3 -m tooling.api.generate --flavour retail [--package-dir packages/apiKit]
        [--metadata DIR] [--previous DIR] [--check]
    python3 -m tooling.api.generate --all [--check]

This is steps 3 to 5 of the update pipeline (`docs/API_KIT_DESIGN.md`,
section 14). From one flavour's metadata directory it writes:

- the runtime bindings, `<package>/src/flavours/<Flavour>.lua`
  (`render_runtime`);
- the LuaCATS definitions, `<package>/types/<flavour>/*.lua` (`render_types`);
- the Markdown reference, `<package>/docs/reference/<flavour>/`
  (`render_reference`), refused when a link it wrote does not resolve;
- the search index, `<metadata>/search.json`;
- with `--previous DIR` (the metadata of the build being replaced), the
  change report `<package>/docs/changes/<flavour>/<old>-<new>.md` and an
  entry in `<metadata>/history.json` (`diff`).

Everything is validated before anything is written: the metadata itself
(`validate`), the generated Lua with `luac -p` and the repository's StyLua
configuration when those tools are on the path, the reference's links. A
directory of generated files is replaced as a whole, so a file the metadata
no longer produces disappears with it. `--check` renders everything and
compares it with what is on disk without writing; CI runs it so a metadata
change can never be committed without its outputs.
"""

from __future__ import annotations

import argparse
import shutil
import subprocess
import sys
from dataclasses import dataclass, field
from pathlib import Path
from typing import Sequence

from tooling.api import (
    diff,
    flavours,
    model,
    render_reference,
    render_runtime,
    render_types,
    validate,
)
from tooling.validation.validate_manifests import ROOT


#: The package directory the outputs belong to, relative to the repository.
DEFAULT_PACKAGE_DIR = Path("packages") / "apiKit"

#: The search index file inside a flavour's metadata directory.
SEARCH_INDEX_FILE = "search.json"


class GenerateError(Exception):
    """Generation was refused; the message says why and what to fix."""


@dataclass(frozen=True)
class GeneratedTree:
    """One output location and the files that belong in it, relative to it."""

    directory: Path
    files: dict[str, str]
    replace_directory: bool


@dataclass
class GenerateResult:
    """What one flavour's generation produced or would produce."""

    flavour_id: str
    trees: list[GeneratedTree] = field(default_factory=list)
    changed: list[Path] = field(default_factory=list)
    removed: list[Path] = field(default_factory=list)
    notes: list[str] = field(default_factory=list)

    @property
    def up_to_date(self) -> bool:
        return not self.changed and not self.removed


def _metadata_directory(package_dir: Path, flavour: flavours.Flavour) -> Path:
    return package_dir / "metadata" / flavour.id


def _lua_check_tool() -> str | None:
    return shutil.which("luac") or shutil.which("luac5.1")


def _check_lua_syntax(files: dict[Path, str], notes: list[str]) -> None:
    """Run `luac -p` over generated Lua when a Lua compiler is available."""
    tool = _lua_check_tool()
    if tool is None:
        notes.append("luac not found; generated Lua was not syntax-checked")
        return
    for path, text in sorted(files.items()):
        completed = subprocess.run(
            [tool, "-p", "-"], input=text, capture_output=True, text=True, check=False
        )
        if completed.returncode != 0:
            raise GenerateError(f"{path}: not valid Lua:\n{completed.stderr.strip()}")


def _check_lua_format(files: dict[Path, str], notes: list[str]) -> None:
    """Run StyLua in check mode over generated Lua when it is available.

    The renderers write the shape StyLua produces; this confirms it, so the
    repository's format gate cannot fail on a generated file.
    """
    tool = shutil.which("stylua")
    if tool is None:
        notes.append("stylua not found; generated Lua was not format-checked")
        return
    for path, text in sorted(files.items()):
        completed = subprocess.run(
            [tool, "--check", "--config-path", str(ROOT / "stylua.toml"), "-"],
            input=text,
            capture_output=True,
            text=True,
            check=False,
        )
        if completed.returncode != 0:
            raise GenerateError(f"{path}: StyLua would reformat this file:\n{completed.stdout.strip()}")


def _plan_directory(directory: Path, files: dict[str, str], replace_directory: bool, result: GenerateResult) -> None:
    """Record which files of one output location differ from disk."""
    result.trees.append(GeneratedTree(directory, files, replace_directory))
    for relative, text in files.items():
        path = directory / relative
        try:
            current = path.read_text(encoding="utf-8")
        except (FileNotFoundError, UnicodeDecodeError):
            current = None
        if current != text:
            result.changed.append(path)
    if replace_directory and directory.is_dir():
        for path in sorted(directory.rglob("*")):
            if path.is_file() and path.relative_to(directory).as_posix() not in files:
                result.removed.append(path)


def _write_trees(result: GenerateResult) -> None:
    planned = {tree.directory / relative for tree in result.trees for relative in tree.files}
    for tree in result.trees:
        if tree.replace_directory and tree.directory.is_dir():
            shutil.rmtree(tree.directory)
        for relative, text in sorted(tree.files.items()):
            path = tree.directory / relative
            path.parent.mkdir(parents=True, exist_ok=True)
            path.write_text(text, encoding="utf-8")
    # Stale files outside the replaced directories (a flavour file nobody owns).
    for path in result.removed:
        if path.exists() and path not in planned and not any(
            tree.replace_directory and tree.directory in path.parents for tree in result.trees
        ):
            path.unlink()


def _history_entry(metadata: model.FlavourMetadata, comparison: diff.Diff | None, report: str | None) -> diff.HistoryEntry:
    provenance = metadata.provenance
    return diff.HistoryEntry(
        build=provenance.build,
        version=provenance.version,
        commit=provenance.commit,
        committed_at=provenance.committed_at,
        captured_on=provenance.captured_on,
        counts=comparison.counts() if comparison is not None else {},
        report=report,
    )


def plan_flavour(
    flavour: flavours.Flavour,
    *,
    package_dir: Path,
    metadata_dir: Path | None = None,
    previous_dir: Path | None = None,
    host_types: model.HostTypes | None = None,
    flavours_table: flavours.Flavours | None = None,
) -> GenerateResult:
    """Render every output of `flavour` and compare it with the package on disk.

    Nothing is written; `write_result` does that. Raises `GenerateError` when
    the metadata is invalid, a generated Lua file does not compile or is not
    formatted, or the reference's links do not resolve.
    """
    metadata_dir = metadata_dir or _metadata_directory(package_dir, flavour)
    host_types = host_types or model.load_host_types()
    result = GenerateResult(flavour_id=flavour.id)

    try:
        metadata = model.read_metadata(metadata_dir)
    except model.MetadataError as failure:
        raise GenerateError(str(failure)) from None
    if metadata.provenance.flavour != flavour.id:
        raise GenerateError(
            f"{metadata_dir}: metadata is for {metadata.provenance.flavour!r}, not {flavour.id!r}"
        )
    problems = validate.validate_metadata(metadata, host_types)
    if problems:
        listed = "\n".join(f"  - {problem}" for problem in problems)
        raise GenerateError(f"{metadata_dir}: the metadata is not valid:\n{listed}")

    try:
        runtime_text = render_runtime.render_runtime(metadata, flavour)
    except render_runtime.RuntimeRenderError as failure:
        raise GenerateError(str(failure)) from None
    runtime_path = package_dir / "src" / render_runtime.runtime_file_name(flavour)
    type_files = render_types.render_types(metadata, flavour, host_types)
    reference_files = render_reference.render_reference(metadata, flavour)
    link_problems = render_reference.check_links(reference_files)
    if link_problems:
        listed = "\n".join(f"  - {problem}" for problem in link_problems)
        raise GenerateError(f"the generated reference has unresolved links:\n{listed}")
    search_index = model.dump_json(render_reference.render_search_index(metadata, flavour))

    lua_files = {runtime_path: runtime_text}
    types_dir = package_dir / "types" / flavour.id
    lua_files.update({types_dir / name: text for name, text in type_files.items()})
    _check_lua_syntax(lua_files, result.notes)
    _check_lua_format(lua_files, result.notes)

    _plan_directory(runtime_path.parent, {runtime_path.name: runtime_text}, False, result)
    _plan_directory(types_dir, type_files, True, result)
    _plan_directory(package_dir / "docs" / "reference" / flavour.id, reference_files, True, result)
    _plan_directory(metadata_dir, {SEARCH_INDEX_FILE: search_index}, False, result)

    _plan_history(metadata, metadata_dir, previous_dir, package_dir, flavour, result)
    _plan_stale_runtime_files(package_dir, flavours_table or flavours.load_flavours(), result)
    return result


def _plan_history(
    metadata: model.FlavourMetadata,
    metadata_dir: Path,
    previous_dir: Path | None,
    package_dir: Path,
    flavour: flavours.Flavour,
    result: GenerateResult,
) -> None:
    """Plan the change report and the history entry.

    With a previous metadata directory the report and the entry describe the
    differences; without one, a history that does not know this commit yet
    gains an entry with no comparison. Re-running generation is idempotent: an
    entry the history already ends with is kept, except that a later run with
    `--previous` fills in the comparison a first run without it left empty,
    which is the order a maintainer usually works in (generate, look, then
    diff against the build being replaced).
    """
    history_path = metadata_dir / diff.HISTORY_FILE
    history = diff.read_history(history_path)
    last_is_this_commit = bool(history) and history[-1].commit == metadata.provenance.commit
    if last_is_this_commit and (previous_dir is None or history[-1].report is not None):
        return

    comparison = None
    report_relative = None
    if previous_dir is not None:
        comparison = _compare_with_previous(metadata, previous_dir, flavour)
        report_name = diff.diff_file_name(comparison)
        changes_dir = package_dir / "docs" / "changes" / flavour.id
        report_relative = (Path("docs") / "changes" / flavour.id / report_name).as_posix()
        _plan_directory(changes_dir, {report_name: diff.render_change_report(comparison)}, False, result)

    entry = _history_entry(metadata, comparison, report_relative)
    kept = history[:-1] if last_is_this_commit else history
    updated = diff.history_to_json([*kept, entry])
    _plan_directory(metadata_dir, {diff.HISTORY_FILE: model.dump_json(updated)}, False, result)


def _compare_with_previous(
    metadata: model.FlavourMetadata, previous_dir: Path, flavour: flavours.Flavour
) -> diff.Diff:
    """Read the metadata of the build being replaced and diff it against `metadata`."""
    try:
        previous = model.read_metadata(previous_dir)
    except model.MetadataError as failure:
        raise GenerateError(str(failure)) from None
    if previous.provenance.flavour != flavour.id:
        raise GenerateError(f"{previous_dir}: previous metadata is for {previous.provenance.flavour!r}")
    return diff.diff_metadata(previous, metadata)


def _plan_stale_runtime_files(package_dir: Path, table: flavours.Flavours, result: GenerateResult) -> None:
    """A runtime file under `src/flavours/` that no flavour owns is stale and is removed.

    The builder ships every Lua file under `src/`, so a file left behind by a
    renamed or removed flavour would reach the addon; a single-flavour run must
    still leave the other flavours' files alone, so the directory is not
    replaced as a whole.
    """
    flavours_dir = package_dir / "src" / "flavours"
    if not flavours_dir.is_dir():
        return
    owned = {(package_dir / "src" / flavour.runtime_file).resolve() for flavour in table.flavours}
    for path in sorted(flavours_dir.glob("*.lua")):
        if path.resolve() not in owned:
            result.removed.append(path)


def write_result(result: GenerateResult) -> None:
    """Write every planned tree to disk."""
    _write_trees(result)


def _print_result(result: GenerateResult, check: bool) -> None:
    verb = "would change" if check else "wrote"
    print(f"{result.flavour_id}: {verb} {len(result.changed)} file(s), removed {len(result.removed)}")
    for path in result.changed:
        print(f"  ~ {path}")
    for path in result.removed:
        print(f"  - {path}")
    for note in result.notes:
        print(f"  note: {note}")


def _selected_flavours(arguments: argparse.Namespace, table: flavours.Flavours, package_dir: Path) -> list[flavours.Flavour]:
    if arguments.all:
        return [
            flavour
            for flavour in table.flavours
            if (_metadata_directory(package_dir, flavour) / model.PROVENANCE_FILE).is_file()
        ]
    try:
        return [table.by_id(arguments.flavour)]
    except KeyError as failure:
        raise GenerateError(str(failure.args[0])) from None


def main(argv: Sequence[str] | None = None) -> int:
    """Generate (or check) the outputs of one flavour or of every flavour with metadata."""
    parser = argparse.ArgumentParser(
        prog="python3 -m tooling.api.generate",
        description="Generate apiKit's runtime bindings, types, reference, search index and history.",
    )
    selection = parser.add_mutually_exclusive_group(required=True)
    selection.add_argument("--flavour", metavar="ID", help="the flavour to generate")
    selection.add_argument("--all", action="store_true", help="every flavour whose metadata directory exists")
    parser.add_argument("--package-dir", type=Path, default=ROOT / DEFAULT_PACKAGE_DIR, metavar="DIR", help="the apiKit package directory (default: packages/apiKit)")
    parser.add_argument("--metadata", type=Path, metavar="DIR", help="the metadata directory (default: <package>/metadata/<flavour>); with --flavour only")
    parser.add_argument("--previous", type=Path, metavar="DIR", help="the metadata of the build being replaced, for the change report and the history; with --flavour only")
    parser.add_argument("--check", action="store_true", help="compare with the files on disk and change nothing; exit 1 when they differ")
    arguments = parser.parse_args(argv)
    if arguments.all and (arguments.metadata or arguments.previous):
        parser.error("--metadata and --previous need --flavour")

    try:
        table = flavours.load_flavours()
        host_types = model.load_host_types()
        selected = _selected_flavours(arguments, table, arguments.package_dir)
        if not selected:
            # `--all` before any capture is committed: nothing to generate, and
            # nothing to be out of date, so the CI gate passes with a note.
            print("no flavour has a metadata directory yet; nothing to generate")
            return 0
        results = [
            plan_flavour(
                flavour,
                package_dir=arguments.package_dir,
                metadata_dir=arguments.metadata,
                previous_dir=arguments.previous,
                host_types=host_types,
                flavours_table=table,
            )
            for flavour in selected
        ]
    except (OSError, ValueError, GenerateError) as failure:
        print(f"error: {failure}", file=sys.stderr)
        return 1

    for result in results:
        if not arguments.check:
            write_result(result)
        _print_result(result, arguments.check)

    if arguments.check and any(not result.up_to_date for result in results):
        print("error: generated files are out of date; run tooling.api.generate", file=sys.stderr)
        return 1
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
