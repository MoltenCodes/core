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

``--verify`` reads the produced ``CHECKSUMS.txt`` back and holds it against the
files on disk, and holds the bundle's ``.toc`` against the Lua files beside it,
so a release is never published with a checksum file or a ``.toc`` that does
not describe the artifact.
"""

from __future__ import annotations

import argparse
import hashlib
import json
import shutil
import sys
import zipfile
from pathlib import Path
from typing import Any, Iterable, NamedTuple, Sequence

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


class BuildError(Exception):
    """A build could not be produced from the current repository state."""


class Selection(NamedTuple):
    """What one build contains.

    ``bundle_name`` is the bundle directory and addon name, ``subject`` the
    package a single-package build is about (``None`` for every package),
    ``ordered`` the packages in load order and ``skipped`` the development
    packages an every-package build leaves out.
    """

    bundle_name: str
    subject: str | None
    ordered: list[str]
    skipped: list[str]


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

    The facade comes first; every other ``.lua`` file under ``src/`` follows in
    sorted path order. Those further files depend only on the facade, never on
    each other, so a sorted order is both deterministic and correct. Paths are
    POSIX-style (``flavours/Retail.lua``) whatever the builder's platform.
    """
    source_dir = source_directory(package_name)
    facade = facade_file_name(package_name)
    nested = sorted(
        path.relative_to(source_dir).as_posix()
        for path in source_files(package_name)
        if path.suffix == ".lua" and path.parent != source_dir
    )
    return [facade, *nested]


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
    """Decide what a build contains.

    ``None`` selects every release package under the name ``MoltenCodes``;
    development packages (``"distribution": "development"``) are skipped and
    reported. A package ID selects that package and its runtime dependency
    closure under ``MoltenCodes-<Facade>``, the name the bundle installs under
    as an addon. Naming an unknown or a development package raises
    ``BuildError``. Validation guarantees no release package depends on a
    development one, so skipping them never breaks a load order.
    """
    skipped = sorted(name for name, data in manifests.items() if is_development(data))

    if package_name is None:
        selected = sorted(name for name in manifests if name not in skipped)
        return Selection(FRAMEWORK_BUNDLE_NAME, None, load_order(selected, manifests), skipped)

    if package_name not in manifests:
        raise BuildError(f'unknown package "{package_name}"')
    if package_name in skipped:
        raise BuildError(
            f'package "{package_name}" has "distribution": "development"; development '
            "packages are tested but never bundled"
        )
    return Selection(
        toc.addon_name(facade_name(package_name)),
        package_name,
        load_order([package_name], manifests),
        [],
    )


def bundle_toc(selection: Selection) -> str:
    """Return the ``.toc`` that makes a bundle an installable addon.

    It lists the runtime files of every package in the bundle, in load order
    (each package's facade first, then its further runtime files), as paths
    relative to the bundle folder. The builder writes it into the bundle root,
    and ``python3 -m tooling.release.library_toc`` prints the same text for the
    packager.
    """
    try:
        interface_line = load_supported_clients().toc_line()
    except (OSError, ValueError) as failure:
        raise BuildError(f"supported_clients.json: {failure}") from failure

    subject_facade = None if selection.subject is None else facade_name(selection.subject)
    return toc.render_toc(
        name=selection.bundle_name,
        notes=toc.addon_notes(subject_facade),
        interface_line=interface_line,
        entries=[
            toc.toc_entry(name, relative)
            for name in selection.ordered
            for relative in runtime_files(name)
        ],
    )


def copy_package(package_name: str, bundle_dir: Path) -> list[str]:
    """Copy one package into the bundle and return its published file paths."""
    package_dir = ROOT / "packages" / package_name
    target_dir = bundle_dir / package_name
    target_dir.mkdir(parents=True, exist_ok=True)

    published: list[str] = []
    source_dir = package_dir / "src"
    for path in source_files(package_name):
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
) -> dict[str, Any]:
    """Describe the bundle: what it contains and how a consumer loads it."""
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
        if subject is not None:
            entry["role"] = "subject" if name == subject else "dependency"
        else:
            entry["role"] = "member"
        packages[name] = entry

    return {
        "schema": MANIFEST_SCHEMA,
        "bundle": bundle_name,
        "subject": subject,
        "packages": packages,
        "loadOrder": [
            f"{name}/{relative}" for name in ordered_packages for relative in runtime_files(name)
        ],
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
    """
    manifests = load_valid_manifests()
    selection = select_packages(manifests, package_name)

    bundle_dir = output_dir / selection.bundle_name
    if bundle_dir.exists():
        shutil.rmtree(bundle_dir)
    bundle_dir.mkdir(parents=True)

    published_files = {name: copy_package(name, bundle_dir) for name in selection.ordered}

    license_source = ROOT / "LICENSE"
    if not license_source.is_file():
        raise BuildError("LICENSE: required repository file is missing")
    shutil.copyfile(license_source, bundle_dir / "LICENSE")

    toc_name = f"{selection.bundle_name}.toc"
    (bundle_dir / toc_name).write_text(bundle_toc(selection), encoding="utf-8")

    manifest = build_manifest(
        selection.bundle_name, selection.subject, selection.ordered, manifests, published_files
    )
    manifest["skipped"] = selection.skipped
    manifest["toc"] = toc_name
    (bundle_dir / "manifest.json").write_text(
        json.dumps(manifest, indent=2, sort_keys=False) + "\n", encoding="utf-8"
    )

    artifacts = [path for path in bundle_dir.rglob("*") if path.is_file()]
    if create_zip:
        artifacts.append(write_zip(output_dir, bundle_dir))
    write_checksums(output_dir, artifacts)

    return manifest


def parse_args(argv: Sequence[str] | None = None) -> argparse.Namespace:
    """Parse the builder's command line."""
    parser = argparse.ArgumentParser(
        prog="python3 -m tooling.package.build",
        description="Assemble a distributable MoltenCodes bundle from package sources."
    )
    selection = parser.add_mutually_exclusive_group(required=True)
    selection.add_argument(
        "--all",
        action="store_true",
        help="build a bundle containing every release package (development packages are skipped)",
    )
    selection.add_argument(
        "--package",
        metavar="NAME",
        help="build one package together with its runtime dependencies",
    )
    parser.add_argument("--out", required=True, metavar="DIR", help="output directory")
    parser.add_argument(
        "--zip", action="store_true", dest="create_zip", help="also write a reproducible zip"
    )
    parser.add_argument(
        "--verify",
        action="store_true",
        help="re-read CHECKSUMS.txt and the .toc afterwards and check them against the build",
    )
    return parser.parse_args(argv)


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
        manifest = build(output_dir, package_name=args.package, create_zip=args.create_zip)
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

        verified = len(read_checksums(output_dir / "CHECKSUMS.txt"))
        print(f"  checksums verified: {verified} file(s)")
        print(f"  .toc verified: {len(manifest['loadOrder'])} file(s) in load order")

    return 0


if __name__ == "__main__":
    raise SystemExit(main())
