"""Assemble a distributable MoltenCodes bundle from package sources.

The repository layout is optimised for development: sources, tests, package
documentation and tooling sit side by side. A consumer wants none of that. This
module produces the shape an addon author actually copies into their addon --
one directory per package, the package's facade at the top of it and any further
runtime files in their subdirectories, the package's own documentation beside
them -- plus a ``manifest.json`` that records what went in and a
``CHECKSUMS.txt`` that records exactly what came out.

Every bundle is also an installable addon. Its root holds a generated ``.toc``
named after the bundle (``MoltenCodes/MoltenCodes.toc`` for every release
package, ``MoltenCodes-<Facade>/MoltenCodes-<Facade>.toc`` for one package and
its dependencies) that loads the bundle's Lua files in load order. The same
text is what ``python3 -m tooling.release.library_toc`` hands the packager.

Builds are deterministic: no timestamps are written into the artifact and the
zip entries use a fixed modification time, so building the same sources twice
produces byte-identical output and therefore identical checksums.

A Kit is a core file plus optional part files (ADR 0001,
``docs/decisions/0001-kit-core-and-parts.md``). What a build contains is a
*selection* of cores and parts: ``--package ID`` (repeatable) selects a Kit's
core, ``--part ID/Part`` or ``--part 'ID/*'`` (repeatable) adds parts, and
``--all`` selects every release Kit with every part. Dependencies and the parts
they name come in by themselves, in the load order `tooling.package.parts`
defines. ``--embeds`` also writes an ``embeds.xml`` for the selection into the
bundle root (`tooling.package.embeds`).

``--verify`` reads the produced ``CHECKSUMS.txt`` back and holds it against the
files on disk, and holds the bundle's ``.toc`` (and ``embeds.xml``, when there
is one) against the Lua files beside it, so a release is never published with
a checksum file, a ``.toc`` or an ``embeds.xml`` that does not describe the
artifact.
"""

from __future__ import annotations

import argparse
import difflib
import hashlib
import re
import json
import shutil
import sys
import zipfile
from pathlib import Path
from typing import Any, Iterable, NamedTuple, Sequence

from tooling.package import parts as kit_parts
from tooling.package import toc
from tooling.validation.interface_numbers import load_supported_clients
from tooling.validation.validate_manifests import (
    ROOT,
    is_development,
    load_manifests,
    validate_graph,
)


#: Name of the bundle that contains every package. It is also the name of the
#: standalone addon the bundle installs as, so it comes from `toc`.
FRAMEWORK_BUNDLE_NAME = toc.FRAMEWORK_ADDON_NAME

#: Schema version of the generated ``manifest.json``.
MANIFEST_SCHEMA = 1

#: Package-owned documentation copied next to a package's runtime Lua.
#: Each entry maps a repository-relative path inside the package directory to
#: the name it is published under.
PACKAGE_DOCUMENTS = {
    Path("README.md"): "README.md",
    Path("CHANGELOG.md"): "CHANGELOG.md",
    Path("docs/API.md"): "API.md",
    Path("docs/INTERNALS.md"): "INTERNALS.md",
}

#: Files under ``src/`` that are development metadata rather than runtime code.
#: ``.luarc.json`` configures lua-language-server for that source directory and
#: has no meaning inside an addon.
EXCLUDED_SOURCE_NAMES = frozenset({".luarc.json"})

#: Fixed zip entry timestamp, so an artifact is reproducible.
ZIP_TIMESTAMP = (1980, 1, 1, 0, 0, 0)

#: The bundle name of a selection that is neither every package nor one Kit.
CUSTOM_BUNDLE_NAME = f"{FRAMEWORK_BUNDLE_NAME}-Custom"

#: What ``--name`` accepts: the framework's name, optionally with a suffix.
BUNDLE_NAME_RE = re.compile(r"^MoltenCodes(-[A-Za-z0-9]+)?$")

#: The loader file ``--embeds`` writes into the bundle root.
EMBEDS_FILE_NAME = "embeds.xml"


class BuildError(Exception):
    """A build could not be produced from the current repository state."""


class Selection(NamedTuple):
    """What one build contains.

    ``bundle_name`` is the bundle directory and addon name, ``subject`` the
    package a single-package build is about (``None`` otherwise),
    ``ordered`` the packages in load order (each once, where its first file
    loads), ``skipped`` the development packages an every-package build leaves
    out, and ``nodes`` the cores and parts in load order. ``nodes`` may be
    left empty by a caller that builds a selection of cores by hand; it then
    means the cores of ``ordered``. ``selected`` names the packages the
    person asked for, as opposed to the ones brought in as dependencies.
    """

    bundle_name: str
    subject: str | None
    ordered: list[str]
    skipped: list[str]
    nodes: tuple[kit_parts.Node, ...] = ()
    selected: tuple[str, ...] = ()

    def load_nodes(self) -> list[kit_parts.Node]:
        """Return the cores and parts of this selection, in load order."""
        if self.nodes:
            return list(self.nodes)
        return [kit_parts.Node(name) for name in self.ordered]

    def selected_parts(self, package_name: str) -> list[str]:
        """Return the parts of ``package_name`` this selection contains, in load order."""
        return [
            node.part
            for node in self.load_nodes()
            if node.package == package_name and node.part is not None
        ]


def dependency_closure(package_name: str, manifests: dict[str, dict[str, Any]]) -> list[str]:
    """Return ``package_name`` and its transitive dependencies, dependency-first.

    Only ``dependencies`` are followed. ``optionalDependencies`` are resolved at
    call time through ``Registry:Find``, so they never enter the load order and
    a bundle never ships a package merely because something optionally uses it.
    """
    resolved: list[str] = []
    seen: set[str] = set()

    def visit(name: str) -> None:
        if name in seen:
            return
        seen.add(name)
        dependencies = manifests[name].get("dependencies", {})
        if isinstance(dependencies, dict):
            for dependency in sorted(dependencies):
                if dependency in manifests:
                    visit(dependency)
        resolved.append(name)

    visit(package_name)
    return resolved


def load_order(package_names: Iterable[str], manifests: dict[str, dict[str, Any]]) -> list[str]:
    """Return the selected packages in a valid dependency-first load order.

    This is the order the packages must appear in inside a consuming addon's
    ``.toc``: every package resolves its dependencies while it is being loaded.
    """
    ordered: list[str] = []
    seen: set[str] = set()
    for name in sorted(package_names):
        for dependency in dependency_closure(name, manifests):
            if dependency not in seen:
                seen.add(dependency)
                ordered.append(dependency)
    return ordered


def source_files(package_name: str) -> list[Path]:
    """Return a package's runtime Lua files in deterministic order."""
    source_dir = ROOT / "packages" / package_name / "src"
    files = sorted(
        path
        for path in source_dir.rglob("*")
        if path.is_file() and path.name not in EXCLUDED_SOURCE_NAMES
    )
    if not files:
        raise BuildError(f"packages/{package_name}/src: no runtime files were found")
    return files


def source_directory(package_name: str) -> Path:
    """Return the package's ``src/`` directory."""
    return ROOT / "packages" / package_name / "src"


def top_level_lua_files(source_dir: Path) -> list[Path]:
    """Return the ``.lua`` files directly inside ``source_dir``, sorted.

    "Directly inside" is decided by the parent directory, never by its name, so
    a subdirectory that happens to be called ``src`` is still a subdirectory.
    Repository validation applies the same rule.
    """
    return sorted(path for path in source_dir.glob("*.lua") if path.is_file())


def facade_file_name(package_name: str) -> str:
    """Return the package's Lua facade file name, the first file the client loads.

    The facade is the one ``.lua`` file directly under ``src/``. A package may
    carry further runtime files in subdirectories of ``src/`` (see
    ``runtime_files``); two top-level Lua files would leave the load order
    ambiguous, so that is an error here as it is in repository validation.
    """
    top_level = top_level_lua_files(source_directory(package_name))
    if not top_level:
        raise BuildError(f"packages/{package_name}/src: no top-level Lua facade was found")
    if len(top_level) > 1:
        names = ", ".join(path.name for path in top_level)
        raise BuildError(
            f"packages/{package_name}/src: expected one top-level Lua facade, found {names}"
        )
    return top_level[0].name


def facade_name(package_name: str) -> str:
    """Return the package's PascalCase facade (``TimerKit``), from its facade file."""
    return Path(facade_file_name(package_name)).stem


def runtime_files(package_name: str) -> list[str]:
    """Return a package's runtime Lua files in load order, relative to ``src/``.

    These are the files of the Kit's *core*: the facade first, then every
    other ``.lua`` file under ``src/`` in sorted path order, except the part
    files under ``src/parts/``, which load only when selected (see
    `part_runtime_file`). Those further core files depend only on the facade,
    never on each other, so a sorted order is both deterministic and correct.
    Paths are POSIX-style (``flavours/Retail.lua``) whatever the builder's
    platform.
    """
    source_dir = source_directory(package_name)
    facade = facade_file_name(package_name)
    nested = sorted(
        path.relative_to(source_dir).as_posix()
        for path in source_files(package_name)
        if path.suffix == ".lua" and path.parent != source_dir and not is_part_file(path, source_dir)
    )
    return [facade, *nested]


def is_part_file(path: Path, source_dir: Path) -> bool:
    """Whether ``path`` lies in the ``src/parts/`` directory of ``source_dir``."""
    relative = path.relative_to(source_dir)
    return len(relative.parts) > 1 and relative.parts[0] == kit_parts.PARTS_DIRECTORY


def part_runtime_file(package_name: str, part: str) -> str:
    """Return a part's file relative to ``src/``: ``parts/EventKit-Coalescing.lua``."""
    return kit_parts.part_file_name(facade_name(package_name), part)


def node_files(node: kit_parts.Node) -> list[str]:
    """Return the files one core or part loads, relative to its package's ``src/``."""
    if node.part is None:
        return runtime_files(node.package)
    return [part_runtime_file(node.package, node.part)]


def load_order_paths(selection: Selection) -> list[str]:
    """Return every file of a selection in load order, as ``<package>/<path>``."""
    return [
        f"{node.package}/{relative}"
        for node in selection.load_nodes()
        for relative in node_files(node)
    ]


def load_valid_manifests() -> dict[str, dict[str, Any]]:
    """Load the manifests, or raise ``BuildError`` when the metadata does not hold up.

    Runs the manifest schema and dependency-graph checks and requires every
    package to declare a ``license``, so nothing is built or described from a
    tree whose metadata is broken.
    """
    manifests, errors = load_manifests()
    errors.extend(validate_graph(manifests))
    if errors:
        raise BuildError("package metadata is invalid:\n  - " + "\n  - ".join(errors))

    for name, manifest in sorted(manifests.items()):
        if not isinstance(manifest.get("license"), str) or not manifest["license"].strip():
            raise BuildError(f'packages/{name}: manifest is missing a "license"')
    return manifests


def select_packages(
    manifests: dict[str, dict[str, Any]], package_name: str | None = None
) -> Selection:
    """Decide what a release build contains: every release package, or one whole Kit.

    ``None`` selects every release package, with every part, under the name
    ``MoltenCodes``; development packages (``"distribution": "development"``)
    are skipped and reported. A package ID selects that package with every one
    of its parts, and its runtime dependency closure, under
    ``MoltenCodes-<Facade>``, the name the bundle installs under as an addon:
    a single-Kit release is the whole Kit, as the packager ships it. Naming an
    unknown or a development package raises ``BuildError``. Validation
    guarantees no release package depends on a development one, so skipping
    them never breaks a load order.
    """
    if package_name is None:
        return select(manifests, every_package=True)
    return select(
        manifests,
        packages=[package_name],
        part_selectors=[f"{package_name}/{kit_parts.EVERY_PART}"],
    )


def select(
    manifests: dict[str, dict[str, Any]],
    packages: Sequence[str] = (),
    part_selectors: Sequence[str] = (),
    every_package: bool = False,
    name: str | None = None,
) -> Selection:
    """Decide what a build contains from the builder's command-line selection.

    ``packages`` are Kit IDs whose cores are selected; ``part_selectors`` are
    ``ID/Part`` or ``ID/*`` and add parts (and their Kit's core).
    ``every_package`` selects every release Kit with every part instead. The
    dependencies of every selected core and part, and the parts their
    contracts name, come in by themselves.

    The bundle is named ``MoltenCodes`` for every package,
    ``MoltenCodes-<Facade>`` when everything asked for belongs to one Kit, and
    ``MoltenCodes-Custom`` otherwise; ``name`` overrides the last two.
    """
    skipped = sorted(package for package, data in manifests.items() if is_development(data))
    if name is not None and not BUNDLE_NAME_RE.fullmatch(name):
        raise BuildError(f'bundle name "{name}" must match {BUNDLE_NAME_RE.pattern}')
    if name == FRAMEWORK_BUNDLE_NAME:
        # A partial bundle under the framework's own name would install as the
        # standalone framework addon while missing Kits addons rely on.
        raise BuildError(
            f'"{FRAMEWORK_BUNDLE_NAME}" is the name of the complete framework (--all); '
            f"name a partial bundle {FRAMEWORK_BUNDLE_NAME}-<Suffix>"
        )

    if every_package:
        if name is not None:
            raise BuildError("--all always builds the bundle MoltenCodes; do not combine it with --name")
        if packages or part_selectors:
            raise BuildError("--all selects every package; do not combine it with --package or --part")
        selected = sorted(package for package in manifests if package not in skipped)
        nodes = kit_parts.all_nodes(manifests, selected)
        return Selection(
            FRAMEWORK_BUNDLE_NAME,
            None,
            packages_in_order(nodes),
            skipped,
            tuple(nodes),
            tuple(selected),
        )

    wanted_cores, wanted_parts = resolve_selectors(manifests, packages, part_selectors)
    if not wanted_cores and not wanted_parts:
        raise BuildError("nothing selected: name at least one --package or --part")

    nodes = kit_parts.walk(kit_parts.roots_for(wanted_cores, wanted_parts, manifests), manifests)
    asked_for = tuple(sorted(set(wanted_cores) | set(wanted_parts)))
    subject = asked_for[0] if len(asked_for) == 1 else None
    if name is not None:
        bundle_name = name
    elif subject is not None:
        bundle_name = toc.addon_name(facade_name(subject))
    else:
        bundle_name = CUSTOM_BUNDLE_NAME
    return Selection(bundle_name, subject, packages_in_order(nodes), [], tuple(nodes), asked_for)


def packages_in_order(nodes: Sequence[kit_parts.Node]) -> list[str]:
    """Return each package of ``nodes`` once, where its first node loads."""
    ordered: list[str] = []
    for node in nodes:
        if node.package not in ordered:
            ordered.append(node.package)
    return ordered


def resolve_selectors(
    manifests: dict[str, dict[str, Any]],
    packages: Sequence[str],
    part_selectors: Sequence[str],
) -> tuple[list[str], dict[str, list[str]]]:
    """Check every requested package and part, and return the cores and parts asked for.

    Raises ``BuildError`` with a message naming the fix for an unknown Kit
    (with the closest known ID), a development Kit, a malformed selector or a
    part the Kit does not declare.
    """
    cores: list[str] = []
    for package in packages:
        require_release_package(manifests, package)
        if package not in cores:
            cores.append(package)

    wanted_parts: dict[str, list[str]] = {}
    for text in part_selectors:
        selector = kit_parts.parse_selector(text)
        if selector is None or selector.part is None:
            raise BuildError(
                f'part "{text}" must be written <packageId>/<Part> or <packageId>/*, '
                "for example eventKit/Coalescing"
            )
        require_release_package(manifests, selector.package)
        declared = kit_parts.part_names(manifests[selector.package])
        chosen = wanted_parts.setdefault(selector.package, [])
        if selector.part == kit_parts.EVERY_PART:
            names = declared
        elif selector.part in declared:
            names = [selector.part]
        else:
            raise BuildError(unknown_part_message(selector.package, selector.part, declared))
        chosen.extend(part for part in names if part not in chosen)
    return cores, wanted_parts


def require_release_package(manifests: dict[str, dict[str, Any]], package: str) -> None:
    """Raise ``BuildError`` unless ``package`` is a known release package."""
    if package not in manifests:
        raise BuildError(unknown_package_message(package, sorted(manifests)))
    if is_development(manifests[package]):
        raise BuildError(
            f'package "{package}" has "distribution": "development"; development '
            "packages are tested but never bundled"
        )


def unknown_package_message(package: str, known: Sequence[str]) -> str:
    """Return the message for an unknown package, with the closest known ID when one is close."""
    by_lower = {name.lower(): name for name in known}
    if package.lower() in by_lower:
        return f'unknown package "{package}"; did you mean "{by_lower[package.lower()]}"?'
    close = difflib.get_close_matches(package, known, n=1)
    if close:
        return f'unknown package "{package}"; did you mean "{close[0]}"?'
    return f'unknown package "{package}"'


def unknown_part_message(package: str, part: str, declared: Sequence[str]) -> str:
    """Return the message for a part the package does not declare."""
    if not declared:
        return f'package "{package}" has no parts; select it with --package {package}'
    close = difflib.get_close_matches(part, declared, n=1)
    hint = f'; did you mean "{package}/{close[0]}"?' if close else ""
    return (
        f'package "{package}" has no part "{part}" (its parts: {", ".join(declared)}){hint}'
    )


def bundle_toc(selection: Selection) -> str:
    """Return the ``.toc`` that makes a bundle an installable addon.

    It lists every file of every core and part in the bundle, in load order
    (each package's facade first, then its further core files; a part after
    everything it needs), as paths relative to the bundle folder. The builder writes it into the bundle root,
    and ``python3 -m tooling.release.library_toc`` prints the same text for the
    packager.
    """
    try:
        interface_line = load_supported_clients().toc_line()
    except (OSError, ValueError) as failure:
        raise BuildError(f"supported_clients.json: {failure}") from failure

    if selection.subject is not None:
        notes = toc.addon_notes(facade_name(selection.subject))
    elif selection.bundle_name == FRAMEWORK_BUNDLE_NAME:
        notes = toc.addon_notes(None)
    else:
        notes = toc.CUSTOM_NOTES
    return toc.render_toc(
        name=selection.bundle_name,
        notes=notes,
        interface_line=interface_line,
        entries=[
            toc.toc_entry(node.package, relative)
            for node in selection.load_nodes()
            for relative in node_files(node)
        ],
    )


def copy_package(
    package_name: str, bundle_dir: Path, selected_parts: Sequence[str] = ()
) -> list[str]:
    """Copy one package into the bundle and return its published file paths.

    Everything under ``src/`` is copied except part files, of which only
    ``selected_parts`` are: a part file in the bundle that nothing loads would
    be dead weight, and `verify_toc` requires every Lua file to be loaded.
    """
    package_dir = ROOT / "packages" / package_name
    target_dir = bundle_dir / package_name
    target_dir.mkdir(parents=True, exist_ok=True)

    published: list[str] = []
    source_dir = package_dir / "src"
    wanted_parts = {part_runtime_file(package_name, part) for part in selected_parts}
    for path in source_files(package_name):
        relative = path.relative_to(source_dir).as_posix()
        if is_part_file(path, source_dir) and relative not in wanted_parts:
            continue
        destination = target_dir / path.relative_to(source_dir)
        destination.parent.mkdir(parents=True, exist_ok=True)
        shutil.copyfile(path, destination)
        # A bundle path is always POSIX-style, whatever the builder's platform,
        # so `manifest.json` is identical wherever the bundle was built.
        published.append(destination.relative_to(bundle_dir).as_posix())

    for relative, published_name in PACKAGE_DOCUMENTS.items():
        source = package_dir / relative
        if source.is_file():
            shutil.copyfile(source, target_dir / published_name)
            published.append(f"{package_name}/{published_name}")

    return sorted(published)


def build_manifest(
    bundle_name: str,
    subject: str | None,
    ordered_packages: Sequence[str],
    manifests: dict[str, dict[str, Any]],
    published_files: dict[str, list[str]],
    selection: Selection | None = None,
) -> dict[str, Any]:
    """Describe the bundle: what it contains and how a consumer loads it.

    The description is schema 1. A package that declares parts additionally
    carries ``parts``: each part the bundle contains, with its file, revision
    and contracts; a package without parts carries no such key, so the
    manifest of a bundle without parts is exactly what it was before parts
    existed. ``loadOrder`` lists every file in load order, and since a part
    may load after another Kit's core, one package's files need not be
    adjacent. ``selection`` defaults to the cores of ``ordered_packages``.
    """
    if selection is None:
        selection = Selection(bundle_name, subject, list(ordered_packages), [])
    packages: dict[str, Any] = {}
    for name in ordered_packages:
        manifest = manifests[name]
        entry: dict[str, Any] = {
            "displayName": manifest["displayName"],
            "description": manifest["description"],
            "version": manifest["version"],
            "license": manifest["license"],
            "dependencies": manifest.get("dependencies", {}),
            # Informational only: an optional dependency is found at call time
            # through `Registry:Find`, so it is neither in `loadOrder` nor
            # shipped because of this entry. A consumer reads it to learn what
            # else a package can use when the addon embeds it.
            "optionalDependencies": manifest.get("optionalDependencies", {}),
            "files": published_files[name],
        }
        if "api" in manifest:
            entry["api"] = manifest["api"]
            entry["revision"] = manifest["revision"]
        declared = kit_parts.part_entries(manifest)
        if declared:
            entry["parts"] = {
                part: part_description(name, part, declared[part])
                for part in selection.selected_parts(name)
            }
        entry["role"] = package_role(name, selection)
        packages[name] = entry

    return {
        "schema": MANIFEST_SCHEMA,
        "bundle": bundle_name,
        "subject": subject,
        "packages": packages,
        "loadOrder": load_order_paths(selection),
    }


def package_role(name: str, selection: Selection) -> str:
    """Return why a package is in the bundle: ``subject``, ``dependency``, ``selected`` or ``member``.

    ``member`` is every package of the complete framework, ``subject`` the one
    Kit a single-Kit bundle is about, ``selected`` a Kit asked for in a custom
    selection, and ``dependency`` a Kit that is only there so the rest loads.
    """
    if selection.subject is not None:
        return "subject" if name == selection.subject else "dependency"
    if selection.bundle_name == FRAMEWORK_BUNDLE_NAME:
        return "member"
    return "selected" if name in selection.selected else "dependency"


def part_description(package_name: str, part: str, entry: dict[str, Any]) -> dict[str, Any]:
    """Describe one bundled part for ``manifest.json``."""
    return {
        "description": entry.get("description", ""),
        "revision": entry.get("revision"),
        "file": f"{package_name}/{part_runtime_file(package_name, part)}",
        "dependencies": entry.get("dependencies", {}),
        "optionalDependencies": entry.get("optionalDependencies", {}),
        "parts": entry.get("parts", []),
    }


def sha256_of(path: Path) -> str:
    """Return the SHA-256 digest of one file."""
    digest = hashlib.sha256()
    with path.open("rb") as handle:
        for block in iter(lambda: handle.read(65536), b""):
            digest.update(block)
    return digest.hexdigest()


def write_checksums(output_dir: Path, paths: Sequence[Path]) -> Path:
    """Write ``CHECKSUMS.txt`` in the ``sha256sum`` format, sorted by path."""
    lines = []
    for path in sorted(paths, key=lambda item: item.relative_to(output_dir).as_posix()):
        relative = path.relative_to(output_dir).as_posix()
        lines.append(f"{sha256_of(path)}  {relative}")

    checksums = output_dir / "CHECKSUMS.txt"
    checksums.write_text("\n".join(lines) + "\n", encoding="utf-8")
    return checksums


def read_checksums(checksums: Path) -> dict[str, str]:
    """Parse a ``CHECKSUMS.txt`` into a mapping of relative path to digest.

    The format is the one ``sha256sum`` writes and reads: a hex digest, two
    spaces, then the path relative to the directory the file sits in.
    """
    recorded: dict[str, str] = {}
    for number, line in enumerate(checksums.read_text(encoding="utf-8").splitlines(), start=1):
        if not line.strip():
            continue
        digest, separator, relative = line.partition("  ")
        if not separator or not relative.strip():
            raise BuildError(f"{checksums.name}: line {number} is not in the sha256sum format")
        recorded[relative.strip()] = digest.strip()
    return recorded


def verify_checksums(output_dir: Path) -> list[str]:
    """Check ``CHECKSUMS.txt`` in ``output_dir`` against the files beside it.

    Three things can be wrong and all three are reported together, because a
    caller fixing one wants to see the rest in the same run: a recorded file is
    gone, a recorded file's contents no longer hash to what was written down,
    or a file sits inside the artifact without being recorded at all.

    Only the trees ``CHECKSUMS.txt`` itself names are inspected for unrecorded
    files. An output directory may hold bundles from earlier builds -- a
    single-package bundle beside the full one, say -- and those are not what
    this checksum file claims to describe.
    """
    checksums = output_dir / "CHECKSUMS.txt"
    if not checksums.is_file():
        return [f"{checksums.name}: missing; nothing to verify"]

    recorded = read_checksums(checksums)
    if not recorded:
        return [f"{checksums.name}: records no files"]

    problems: list[str] = []
    for relative in sorted(recorded):
        path = output_dir / relative
        if not path.is_file():
            problems.append(
                f"{relative}: recorded in {checksums.name} but missing from the build"
            )
        elif sha256_of(path) != recorded[relative]:
            problems.append(
                f"{relative}: contents do not match the digest in {checksums.name}"
            )

    described_trees = {relative.split("/", 1)[0] for relative in recorded}
    for path in sorted(output_dir.rglob("*")):
        if not path.is_file() or path == checksums:
            continue
        relative = path.relative_to(output_dir).as_posix()
        if relative.split("/", 1)[0] in described_trees and relative not in recorded:
            problems.append(
                f"{relative}: present in the build but not recorded in {checksums.name}"
            )

    return problems


def verify_toc(bundle_dir: Path) -> list[str]:
    """Check that a bundle's ``.toc`` loads exactly its Lua files, in load order.

    The ``.toc`` named by ``manifest.json`` must list the manifest's
    ``loadOrder`` line for line, and every ``.lua`` file inside the bundle must
    be listed: a file the ``.toc`` misses is never loaded by an installed copy,
    and a listed file that is missing stops the addon's load.
    """
    manifest_path = bundle_dir / "manifest.json"
    if not manifest_path.is_file():
        return [f"{bundle_dir.name}/manifest.json: missing; cannot find the .toc"]
    manifest = json.loads(manifest_path.read_text(encoding="utf-8"))

    toc_name = manifest.get("toc")
    expected_name = f"{bundle_dir.name}.toc"
    if toc_name != expected_name:
        return [
            f'{bundle_dir.name}/manifest.json: "toc" is {toc_name!r}; the client only '
            f"loads {expected_name}"
        ]
    toc_path = bundle_dir / toc_name
    if not toc_path.is_file():
        return [f"{bundle_dir.name}/{toc_name}: missing from the bundle"]

    listed = [
        toc.entry_to_bundle_path(entry)
        for entry in toc.listed_files(toc_path.read_text(encoding="utf-8"))
    ]
    where = f"{bundle_dir.name}/{toc_name}"
    problems: list[str] = []
    if listed != manifest.get("loadOrder"):
        problems.append(
            f"{where}: lists {listed} but the load order is {manifest.get('loadOrder')}"
        )

    present = {path.relative_to(bundle_dir).as_posix() for path in bundle_dir.rglob("*.lua")}
    for relative in sorted(present - set(listed)):
        problems.append(f"{where}: does not load {relative}, which the bundle contains")
    for relative in sorted(set(listed) - present):
        problems.append(f"{where}: loads {relative}, which the bundle does not contain")
    return problems


def verify_embeds(bundle_dir: Path) -> list[str]:
    """Check that a bundle's ``embeds.xml``, when it has one, loads its load order exactly.

    A bundle without ``embeds`` in its ``manifest.json`` has nothing to check.
    """
    manifest_path = bundle_dir / "manifest.json"
    if not manifest_path.is_file():
        return [f"{bundle_dir.name}/manifest.json: missing; cannot find embeds.xml"]
    manifest = json.loads(manifest_path.read_text(encoding="utf-8"))
    embeds_name = manifest.get("embeds")
    if embeds_name is None:
        return []
    where = f"{bundle_dir.name}/{embeds_name}"
    embeds_path = bundle_dir / embeds_name
    if not embeds_path.is_file():
        return [f"{where}: named in manifest.json but missing from the bundle"]

    from tooling.package import embeds

    listed = embeds.listed_scripts(embeds_path.read_text(encoding="utf-8"))
    expected = manifest.get("loadOrder")
    if listed != expected:
        return [f"{where}: loads {listed} but the load order is {expected}"]
    return []


def write_zip(output_dir: Path, bundle_dir: Path) -> Path:
    """Archive the bundle directory reproducibly."""
    archive = output_dir / f"{bundle_dir.name}.zip"
    files = sorted(path for path in bundle_dir.rglob("*") if path.is_file())
    with zipfile.ZipFile(archive, "w", compression=zipfile.ZIP_DEFLATED) as handle:
        for path in files:
            name = f"{bundle_dir.name}/{path.relative_to(bundle_dir).as_posix()}"
            info = zipfile.ZipInfo(name, date_time=ZIP_TIMESTAMP)
            info.compress_type = zipfile.ZIP_DEFLATED
            info.external_attr = 0o644 << 16
            handle.writestr(info, path.read_bytes())
    return archive


def build(
    output_dir: Path,
    package_name: str | None = None,
    create_zip: bool = False,
    selection: Selection | None = None,
    write_embeds: bool = False,
) -> dict[str, Any]:
    """Build one bundle into ``output_dir`` and return its manifest.

    ``package_name`` selects a single package; its runtime dependencies are
    included as well, because a bundle that cannot load is not a release
    artifact, and the bundle is named ``MoltenCodes-<Facade>``. Omitting it
    builds every release package in the repository as ``MoltenCodes``.

    Development packages (``"distribution": "development"``) are never bundled:
    an ``--all`` build skips them and lists them under ``skipped`` in the
    bundle's ``manifest.json``, and naming one as ``package_name`` is an error.

    Every bundle is an installable addon: its root holds ``<bundle>.toc``
    listing the bundle's Lua files in load order, ``manifest.json`` names it
    under ``toc``, and ``CHECKSUMS.txt`` covers it like every other file.

    ``selection`` (from `select`) replaces ``package_name`` for a build of
    several Kits or of chosen parts. ``write_embeds`` also writes
    ``embeds.xml`` into the bundle root, loading the same files in the same
    order, and names it under ``embeds`` in ``manifest.json``.
    """
    manifests = load_valid_manifests()
    if selection is None:
        selection = select_packages(manifests, package_name)

    bundle_dir = output_dir / selection.bundle_name
    if bundle_dir.exists():
        shutil.rmtree(bundle_dir)
    bundle_dir.mkdir(parents=True)

    published_files = {
        name: copy_package(name, bundle_dir, selection.selected_parts(name))
        for name in selection.ordered
    }

    license_source = ROOT / "LICENSE"
    if not license_source.is_file():
        raise BuildError("LICENSE: required repository file is missing")
    shutil.copyfile(license_source, bundle_dir / "LICENSE")

    toc_name = f"{selection.bundle_name}.toc"
    (bundle_dir / toc_name).write_text(bundle_toc(selection), encoding="utf-8")

    manifest = build_manifest(
        selection.bundle_name,
        selection.subject,
        selection.ordered,
        manifests,
        published_files,
        selection,
    )
    manifest["skipped"] = selection.skipped
    manifest["toc"] = toc_name
    if write_embeds:
        # Imported here: `embeds` imports this module for the selection model.
        from tooling.package import embeds

        (bundle_dir / EMBEDS_FILE_NAME).write_text(
            embeds.render_embeds_xml(manifest["loadOrder"], describe_selection(selection)),
            encoding="utf-8",
        )
        manifest["embeds"] = EMBEDS_FILE_NAME
    (bundle_dir / "manifest.json").write_text(
        json.dumps(manifest, indent=2, sort_keys=False) + "\n", encoding="utf-8"
    )

    artifacts = [path for path in bundle_dir.rglob("*") if path.is_file()]
    if create_zip:
        artifacts.append(write_zip(output_dir, bundle_dir))
    write_checksums(output_dir, artifacts)

    return manifest


def describe_selection(selection: Selection) -> str:
    """Return what a selection was asked for, for a generated file's comment."""
    if selection.bundle_name == FRAMEWORK_BUNDLE_NAME and selection.subject is None:
        return "every release Kit and every part"
    asked: list[str] = []
    for name in selection.selected:
        parts = selection.selected_parts(name)
        asked.append(name if not parts else f"{name} ({', '.join(parts)})")
    return ", ".join(asked)


def parse_args(argv: Sequence[str] | None = None) -> argparse.Namespace:
    """Parse the builder's command line."""
    parser = argparse.ArgumentParser(
        prog="python3 -m tooling.package.build",
        description="Assemble a distributable MoltenCodes bundle from package sources."
    )
    parser.add_argument(
        "--all",
        action="store_true",
        help="build every release package with every part (development packages are skipped)",
    )
    parser.add_argument(
        "--package",
        metavar="NAME",
        action="append",
        default=[],
        help="select a Kit's core, with its dependencies; repeat for several Kits",
    )
    parser.add_argument(
        "--part",
        metavar="NAME/PART",
        action="append",
        default=[],
        help="select one part of a Kit (NAME/Part) or every part (NAME/*), with its core; repeatable",
    )
    parser.add_argument(
        "--name",
        metavar="BUNDLE",
        help="name a selection of several Kits (default MoltenCodes-Custom): MoltenCodes-<Suffix>",
    )
    parser.add_argument(
        "--embeds",
        action="store_true",
        help="also write embeds.xml, loading the bundle's files in load order, into the bundle root",
    )
    parser.add_argument("--out", required=True, metavar="DIR", help="output directory")
    parser.add_argument(
        "--zip", action="store_true", dest="create_zip", help="also write a reproducible zip"
    )
    parser.add_argument(
        "--verify",
        action="store_true",
        help="re-read CHECKSUMS.txt, the .toc and embeds.xml afterwards and check them against the build",
    )
    arguments = parser.parse_args(argv)
    if not arguments.all and not arguments.package and not arguments.part:
        parser.error("select what to build: --all, or at least one --package or --part")
    return arguments


def report_problems(label: str, problems: Sequence[str]) -> None:
    """Print a verification failure and its problems to standard error."""
    print(f"error: {label} failed with {len(problems)} problem(s):", file=sys.stderr)
    for problem in problems:
        print(f"  - {problem}", file=sys.stderr)


def main(argv: Sequence[str] | None = None) -> int:
    """Entry point for ``python3 -m tooling.package.build``."""
    args = parse_args(argv)
    output_dir = Path(args.out).expanduser().resolve()
    output_dir.mkdir(parents=True, exist_ok=True)

    try:
        manifests = load_valid_manifests()
        selection = select(
            manifests,
            packages=args.package,
            part_selectors=args.part,
            every_package=args.all,
            name=args.name,
        )
        manifest = build(
            output_dir,
            create_zip=args.create_zip,
            selection=selection,
            write_embeds=args.embeds,
        )
    except BuildError as failure:
        print(f"error: {failure}", file=sys.stderr)
        return 1

    print(f"Built {manifest['bundle']} in {output_dir}")
    for name, entry in manifest["packages"].items():
        runtime = ""
        if "api" in entry:
            runtime = f" [API {entry['api']}, Revision {entry['revision']}]"
        print(f"  - {name} {entry['version']}{runtime} ({entry['role']})")
    for name in manifest["skipped"]:
        print(f"  - {name} skipped (development package, never bundled)")
    print(f"  addon: {manifest['bundle']}/{manifest['toc']}")
    if "embeds" in manifest:
        print(f"  embeds: {manifest['bundle']}/{manifest['embeds']}")
    print("  load order:")
    for relative in manifest["loadOrder"]:
        print(f"    {relative}")

    if args.verify:
        try:
            problems = verify_checksums(output_dir)
        except BuildError as failure:
            print(f"error: {failure}", file=sys.stderr)
            return 1

        if problems:
            report_problems("checksum verification", problems)
            return 1

        toc_problems = verify_toc(output_dir / manifest["bundle"])
        if toc_problems:
            report_problems(".toc verification", toc_problems)
            return 1

        embeds_problems = verify_embeds(output_dir / manifest["bundle"])
        if embeds_problems:
            report_problems("embeds.xml verification", embeds_problems)
            return 1

        verified = len(read_checksums(output_dir / "CHECKSUMS.txt"))
        print(f"  checksums verified: {verified} file(s)")
        print(f"  .toc verified: {len(manifest['loadOrder'])} file(s) in load order")

    return 0


if __name__ == "__main__":
    raise SystemExit(main())
