"""Check that a release tag is ready to be released.

    python3 -m tooling.release.check_tag v0.1.0
    python3 -m tooling.release.check_tag timerKit-v0.6.0
    python3 -m tooling.release.check_tag timerKit-v0.6.0 --github-output "$GITHUB_OUTPUT"

Two kinds of tag release something (see `docs/RELEASES.md`):

- a **bundle tag** `v<SemVer>` releases every release package together as the
  addon "MoltenCodes". It passes when `docs/RELEASES.md` has a `### v<SemVer>`
  section under `## Release history` whose "`<packageId>` <version>" lines name
  every release package exactly once, each at exactly its manifest `version`,
  and name nothing else;
- a **package tag** `<packageId>-v<SemVer>` releases one Kit (with the packages
  it requires) as the addon "MoltenCodes-<Facade>". It passes when the package
  exists, is a release package, its manifest `version` is the tag's version,
  and `docs/RELEASES.md` has a `### <packageId>-v<SemVer>` section. Package
  lines in that section are optional; any that are there are held against the
  manifests the same way.

Errors cite the line of `docs/RELEASES.md` to fix. The release workflow runs
this first and reads `kind`, `package` and `version` from `--github-output`.
"""

from __future__ import annotations

import argparse
import re
import sys
from typing import Any, NamedTuple, Sequence

from tooling.release import history
from tooling.validation import validate_manifests


#: `ParsedTag.kind` of a `v<SemVer>` tag: every release package.
BUNDLE = "bundle"

#: `ParsedTag.kind` of a `<packageId>-v<SemVer>` tag: one package.
PACKAGE = "package"

#: A package ID is lowerCamelCase and never contains a hyphen, so the first
#: `-v` ends it even when the version's pre-release part has hyphens.
PACKAGE_TAG_RE = re.compile(r"^([a-z][A-Za-z0-9]*)-v(.+)$")


class TagError(ValueError):
    """The tag is neither `v<SemVer>` nor `<packageId>-v<SemVer>`."""


class ParsedTag(NamedTuple):
    """What a tag releases: its kind, the package of a package tag, the version."""

    kind: str
    package: str | None
    version: str


def parse_tag(tag: str) -> ParsedTag:
    """Split `tag` into `(kind, package, version)`.

    `v0.1.0` is `("bundle", None, "0.1.0")` and `timerKit-v0.6.0` is
    `("package", "timerKit", "0.6.0")`. Anything else raises `TagError`. This
    checks the form only; `check_tag` checks the tag against the repository.
    """
    if tag.startswith("v") and validate_manifests.SEMVER_RE.fullmatch(tag[1:]):
        return ParsedTag(BUNDLE, None, tag[1:])

    match = PACKAGE_TAG_RE.fullmatch(tag)
    if match is not None and validate_manifests.SEMVER_RE.fullmatch(match.group(2)):
        return ParsedTag(PACKAGE, match.group(1), match.group(2))

    raise TagError(
        f'tag "{tag}" is neither a bundle tag v<major>.<minor>.<patch> nor a package tag '
        "<packageId>-v<major>.<minor>.<patch>"
    )


def validate_tag_format(tag: str) -> list[str]:
    """Return the reason `tag` has neither release-tag form, or nothing."""
    try:
        parse_tag(tag)
    except TagError as failure:
        return [str(failure)]
    return []


def _check_listed_versions(
    entries: Sequence[history.PackageVersion],
    manifests: dict[str, dict[str, Any]],
) -> tuple[list[str], set[str]]:
    """Hold "`<packageId>` <version>" lines against the manifests.

    Returns the errors and the set of package IDs the lines name. A line must
    name an existing release package, once, at exactly its manifest version.
    """
    document = history.RELEASES_DOCUMENT
    errors: list[str] = []
    seen: set[str] = set()
    for entry in entries:
        where = f"{document}:{entry.line_number}"
        if entry.package in seen:
            errors.append(f'{where}: "{entry.package}" is listed more than once')
            continue
        seen.add(entry.package)

        manifest = manifests.get(entry.package)
        if manifest is None:
            errors.append(f'{where}: package "{entry.package}" does not exist')
        elif validate_manifests.is_development(manifest):
            errors.append(
                f'{where}: "{entry.package}" is a development package; it is never released'
            )
        elif manifest.get("version") != entry.version:
            errors.append(
                f'{where}: "{entry.package}" is listed at {entry.version}, '
                f"but its manifest says {manifest.get('version')}"
            )
    return errors, seen


def _check_bundle_section(
    tag: str,
    text: str,
    section: tuple[int, str],
    manifests: dict[str, dict[str, Any]],
) -> list[str]:
    """Check a bundle tag's section: every release package, each at its version."""
    document = history.RELEASES_DOCUMENT
    first_line, body = section
    heading = f"{document}:{history.section_heading_line(text, tag)}"

    listed = history.package_versions(body, first_line)
    if not listed:
        return [
            f'{heading}: section "{tag}" lists no "`<packageId>` <version>" lines; '
            "a bundle section lists every release package it ships"
        ]

    errors, seen = _check_listed_versions(listed, manifests)
    for name in sorted(manifests):
        manifest = manifests[name]
        if name in seen or validate_manifests.is_development(manifest):
            continue
        errors.append(
            f'{heading}: section "{tag}" does not list release package "{name}" '
            f"(manifest version {manifest.get('version')}); a bundle section lists every "
            "release package it ships"
        )
    return errors


def _check_package(parsed: ParsedTag, manifests: dict[str, dict[str, Any]]) -> list[str]:
    """Check that a package tag names a release package at its manifest version."""
    name = parsed.package
    manifest = manifests.get(name or "")
    where = f"packages/{name}/package.manifest.json"
    if manifest is None:
        return [f'package "{name}" does not exist; a package tag names an existing package']
    if validate_manifests.is_development(manifest):
        return [f'{where}: "{name}" is a development package; it is never released']
    if manifest.get("version") != parsed.version:
        return [
            f'{where}: version is {manifest.get("version")}, but the tag says {parsed.version}; '
            "bump the manifest or fix the tag"
        ]
    return []


def check_tag(tag: str) -> list[str]:
    """Return every reason `tag` cannot be released from the repository tree.

    The release notes are read from `history.ROOT` and the manifests from
    `validate_manifests.PACKAGES`; tests point both at a throwaway tree.
    """
    try:
        parsed = parse_tag(tag)
    except TagError as failure:
        return [str(failure)]

    document = history.RELEASES_DOCUMENT
    try:
        text = history.read_releases()
    except OSError as exc:
        return [f"{document}: unable to read: {exc}"]

    manifests, manifest_errors = validate_manifests.load_manifests()
    if manifest_errors:
        return [f"package manifests are invalid: {item}" for item in manifest_errors]

    errors: list[str] = []
    if parsed.kind == PACKAGE:
        errors.extend(_check_package(parsed, manifests))

    section = history.release_section(text, tag)
    if section is None:
        heading_line = history.history_heading_line(text)
        if heading_line is None:
            errors.append(f'{document}: no "{history.HISTORY_HEADING}" heading')
        else:
            errors.append(
                f'{document}:{heading_line}: no "### {tag}" section under '
                f'"{history.HISTORY_HEADING}"; write the release notes before tagging'
            )
        return errors

    if parsed.kind == BUNDLE:
        errors.extend(_check_bundle_section(tag, text, section, manifests))
    else:
        first_line, body = section
        listed_errors, _ = _check_listed_versions(
            history.package_versions(body, first_line), manifests
        )
        errors.extend(listed_errors)
    return errors


def github_outputs(tag: str, parsed: ParsedTag) -> str:
    """Return the `key=value` lines the release workflow's `resolve` job exports."""
    return (
        f"tag={tag}\n"
        f"kind={parsed.kind}\n"
        f"package={parsed.package or ''}\n"
        f"version={parsed.version}\n"
    )


def main(argv: Sequence[str] | None = None) -> int:
    """Check the tag given on the command line and report the result."""
    parser = argparse.ArgumentParser(
        prog="python3 -m tooling.release.check_tag",
        description=(
            "Check a v<SemVer> bundle tag or a <packageId>-v<SemVer> package tag against "
            "docs/RELEASES.md and the manifests."
        ),
    )
    parser.add_argument("tag", help="the tag to check, for example v0.1.0 or timerKit-v0.6.0")
    parser.add_argument(
        "--github-output",
        metavar="FILE",
        help="on success, append tag, kind, package and version as key=value lines to FILE",
    )
    arguments = parser.parse_args(argv)

    errors = check_tag(arguments.tag)
    if errors:
        print(f"Tag {arguments.tag} is not releasable ({len(errors)} error(s)):", file=sys.stderr)
        for item in errors:
            print(f"  - {item}", file=sys.stderr)
        return 1

    parsed = parse_tag(arguments.tag)
    if arguments.github_output:
        with open(arguments.github_output, "a", encoding="utf-8") as handle:
            handle.write(github_outputs(arguments.tag, parsed))

    subject = "every release package" if parsed.kind == BUNDLE else f"package {parsed.package}"
    print(f"Tag {arguments.tag} is releasable ({parsed.kind} release of {subject}).")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
