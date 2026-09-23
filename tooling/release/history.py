"""Read the release history in `docs/RELEASES.md`.

A bundle release is described by one section under the `## Release history`
heading:

    ### v1.2.0

    - `registry` 0.6.1
    - `signalKit` 0.3.0

    Free-form notes for the release.

The heading names the tag. Each list line of the form "`<packageId>` <version>"
records a package version the release ships; `check_tag` holds those lines
against the package manifests, and `notes` prints the whole section as the
release notes of the draft GitHub release.
"""

from __future__ import annotations

import re
from pathlib import Path
from typing import NamedTuple


ROOT = Path(__file__).resolve().parents[2]

#: The document holding the release history, relative to the repository root.
RELEASES_DOCUMENT = Path("docs/RELEASES.md")

#: The level-two heading the release sections live under.
HISTORY_HEADING = "## Release history"

#: `### v1.2.0` or `### v1.2.0 — 2026-10-01`: the first word is the tag.
SECTION_HEADING_RE = re.compile(r"^###[ \t]+(\S+)")

#: "- `registry` 0.6.1": a package ID in backticks followed by its version.
PACKAGE_LINE_RE = re.compile(r"^[ \t]*[-*][ \t]+`([a-z][A-Za-z0-9]*)`[ \t]+v?(\S+)")


class PackageVersion(NamedTuple):
    """One "`<packageId>` <version>" line of a release section."""

    package: str
    version: str
    line_number: int


def _is_fence(line: str) -> bool:
    return line.lstrip().startswith(("```", "~~~"))


def release_sections(text: str) -> dict[str, tuple[int, list[str]]]:
    """Map each tag under `## Release history` to its first line number and body lines.

    Fenced code blocks are skipped when looking for headings, so an example of
    the format inside a code block is never mistaken for a release.
    """
    sections: dict[str, tuple[int, list[str]]] = {}
    in_history = False
    in_fence = False
    current: list[str] | None = None

    for number, line in enumerate(text.splitlines(), start=1):
        if _is_fence(line):
            in_fence = not in_fence
        if not in_fence and line.startswith("## "):
            in_history = line.rstrip() == HISTORY_HEADING
            current = None
            continue
        if not in_history:
            continue
        heading = None if in_fence else SECTION_HEADING_RE.match(line)
        if heading is not None:
            current = []
            sections[heading.group(1)] = (number + 1, current)
            continue
        if current is not None:
            current.append(line)

    return sections


def release_section(text: str, tag: str) -> tuple[int, str] | None:
    """Return the first body line number and the body of `tag`'s section, or `None`."""
    found = release_sections(text).get(tag)
    if found is None:
        return None
    first_line, lines = found
    start, end = 0, len(lines)
    while start < end and not lines[start].strip():
        start += 1
    while end > start and not lines[end - 1].strip():
        end -= 1
    # Leading blank lines are dropped, so the line number moves with them and
    # `package_versions` can still point at the exact line in the document.
    return first_line + start, "\n".join(lines[start:end])


def package_versions(section: str, first_line: int = 1) -> list[PackageVersion]:
    """Return the "`<packageId>` <version>" lines of a section, in document order."""
    found: list[PackageVersion] = []
    for offset, line in enumerate(section.splitlines()):
        match = PACKAGE_LINE_RE.match(line)
        if match is not None:
            found.append(PackageVersion(match.group(1), match.group(2), first_line + offset))
    return found


def read_releases(root: Path | None = None) -> str:
    """Return the text of `docs/RELEASES.md` under `root` (the repository by default)."""
    return ((root or ROOT) / RELEASES_DOCUMENT).read_text(encoding="utf-8")
