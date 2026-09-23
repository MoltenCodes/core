"""Check that a bundle release tag is ready to be released.

    python3 -m tooling.release.check_tag v1.2.0

A bundle release tag is `v<SemVer>`. For it to pass:

1. the tag is `v` followed by a valid Semantic Versioning number;
2. `docs/RELEASES.md` has a `### <tag>` section under `## Release history`;
3. that section lists at least one "`<packageId>` <version>" line;
4. every listed package exists, is listed once, and its manifest `version` is
   exactly the version the section records.

The release workflow runs this before anything is built, so a tag whose notes
describe versions the tree does not contain never reaches the addon sites.
Per-package tags (`<package>-v<version>`) are not bundle tags and are rejected.
"""

from __future__ import annotations

import argparse
import sys
from typing import Sequence

from tooling.release import history
from tooling.validation import validate_manifests


def validate_tag_format(tag: str) -> list[str]:
    """Check that `tag` is `v` followed by a Semantic Versioning number."""
    if not tag.startswith("v") or not validate_manifests.SEMVER_RE.fullmatch(tag[1:]):
        return [f'tag "{tag}" is not a bundle release tag of the form v<major>.<minor>.<patch>']
    return []


def check_tag(tag: str) -> list[str]:
    """Return every reason `tag` cannot be released from the repository tree.

    The release notes are read from `history.ROOT` and the manifests from
    `validate_manifests.PACKAGES`; tests point both at a throwaway tree.
    """
    errors = validate_tag_format(tag)
    if errors:
        return errors

    document = history.RELEASES_DOCUMENT
    try:
        text = history.read_releases()
    except OSError as exc:
        return [f"{document}: unable to read: {exc}"]

    section = history.release_section(text, tag)
    if section is None:
        return [
            f'{document}: no "### {tag}" section under "{history.HISTORY_HEADING}"; '
            "write the release notes before tagging"
        ]
    first_line, body = section

    listed = history.package_versions(body, first_line)
    if not listed:
        return [f'{document}: section "{tag}" lists no "`<packageId>` <version>" lines']

    manifests, manifest_errors = validate_manifests.load_manifests()
    if manifest_errors:
        return [f"package manifests are invalid: {item}" for item in manifest_errors]

    seen: set[str] = set()
    for entry in listed:
        where = f"{document}:{entry.line_number}"
        if entry.package in seen:
            errors.append(f'{where}: "{entry.package}" is listed more than once')
            continue
        seen.add(entry.package)

        manifest = manifests.get(entry.package)
        if manifest is None:
            errors.append(f'{where}: package "{entry.package}" does not exist')
        elif manifest.get("version") != entry.version:
            errors.append(
                f'{where}: "{entry.package}" is listed at {entry.version}, '
                f"but its manifest says {manifest.get('version')}"
            )

    return errors


def main(argv: Sequence[str] | None = None) -> int:
    """Check the tag given on the command line and report the result."""
    parser = argparse.ArgumentParser(
        prog="python3 -m tooling.release.check_tag",
        description="Check that a v<SemVer> bundle tag matches docs/RELEASES.md and the manifests.",
    )
    parser.add_argument("tag", help="the tag to check, for example v1.2.0")
    arguments = parser.parse_args(argv)

    errors = check_tag(arguments.tag)
    if errors:
        print(f"Tag {arguments.tag} is not releasable ({len(errors)} error(s)):", file=sys.stderr)
        for item in errors:
            print(f"  - {item}", file=sys.stderr)
        return 1

    print(f"Tag {arguments.tag} is releasable.")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
