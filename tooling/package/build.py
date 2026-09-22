"""Assemble a distributable MoltenCodes bundle from package sources.

The repository layout is optimised for development: sources, tests, package
documentation and tooling sit side by side. A consumer wants none of that. This
module produces the shape an addon author actually copies into their addon --
one directory per package, the package's runtime Lua at the top of it, the
package's own documentation beside it -- plus a ``manifest.json`` that records
what went in and a ``CHECKSUMS.txt`` that records exactly what came out.

Builds are deterministic: no timestamps are written into the artifact and the
zip entries use a fixed modification time, so building the same sources twice
produces byte-identical output and therefore identical checksums.

``--verify`` reads the produced ``CHECKSUMS.txt`` back and holds it against the
files on disk, so a release is never published with a checksum file that does
not describe the artifact beside it.
"""

from __future__ import annotations

import argparse
import hashlib
import json
import shutil
import sys
import zipfile
from pathlib import Path
from typing import Any, Iterable, Sequence

from tooling.validation.validate_manifests import (
    ROOT,
    load_manifests,
    validate_graph,
)


#: Name of the bundle that contains every package.
FRAMEWORK_BUNDLE_NAME = "MoltenCodes"

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


def dependency_closure(package_name: str, manifests: dict[str, dict[str, Any]]) -> list[str]:
    """Return ``package_name`` and its transitive dependencies, dependency-first."""
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


def facade_file_name(package_name: str) -> str:
    """Return the package's Lua facade file name, for the load-order listing."""
    for path in source_files(package_name):
        if path.suffix == ".lua" and path.parent.name == "src":
            return path.name
    raise BuildError(f"packages/{package_name}/src: no top-level Lua facade was found")


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
        published.append(str(destination.relative_to(bundle_dir)))

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
        "loadOrder": [f"{name}/{facade_file_name(name)}" for name in ordered_packages],
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
    artifact. Omitting it builds every package in the repository.
    """
    manifests, errors = load_manifests()
    errors.extend(validate_graph(manifests))
    if errors:
        raise BuildError("package metadata is invalid:\n  - " + "\n  - ".join(errors))

    for name, manifest in sorted(manifests.items()):
        if not isinstance(manifest.get("license"), str) or not manifest["license"].strip():
            raise BuildError(f'packages/{name}: manifest is missing a "license"')

    if package_name is None:
        subject = None
        bundle_name = FRAMEWORK_BUNDLE_NAME
        selected = sorted(manifests)
    else:
        if package_name not in manifests:
            raise BuildError(f'unknown package "{package_name}"')
        subject = package_name
        bundle_name = f"{FRAMEWORK_BUNDLE_NAME}-{package_name}"
        selected = [package_name]

    ordered = load_order(selected, manifests)

    bundle_dir = output_dir / bundle_name
    if bundle_dir.exists():
        shutil.rmtree(bundle_dir)
    bundle_dir.mkdir(parents=True)

    published_files = {name: copy_package(name, bundle_dir) for name in ordered}

    license_source = ROOT / "LICENSE"
    if not license_source.is_file():
        raise BuildError("LICENSE: required repository file is missing")
    shutil.copyfile(license_source, bundle_dir / "LICENSE")

    manifest = build_manifest(bundle_name, subject, ordered, manifests, published_files)
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
        description="Assemble a distributable MoltenCodes bundle from package sources."
    )
    selection = parser.add_mutually_exclusive_group(required=True)
    selection.add_argument(
        "--all", action="store_true", help="build a bundle containing every package"
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
        help="re-read CHECKSUMS.txt afterwards and check it against the build",
    )
    return parser.parse_args(argv)


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
            print(
                f"error: checksum verification failed with {len(problems)} problem(s):",
                file=sys.stderr,
            )
            for problem in problems:
                print(f"  - {problem}", file=sys.stderr)
            return 1

        verified = len(read_checksums(output_dir / "CHECKSUMS.txt"))
        print(f"  checksums verified: {verified} file(s)")

    return 0


if __name__ == "__main__":
    raise SystemExit(main())
