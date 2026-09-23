"""Print the release notes for a tag from `docs/RELEASES.md`.

    python3 -m tooling.release.notes v1.2.0 > notes.md

Prints the body of the tag's `### <tag>` section and exits 0, or exits 1 with a
message on standard error when there is no such section. The release workflow
falls back to the annotated tag's message in that case.
"""

from __future__ import annotations

import argparse
import sys
from typing import Sequence

from tooling.release import history


def main(argv: Sequence[str] | None = None) -> int:
    """Print the release notes for the tag given on the command line."""
    parser = argparse.ArgumentParser(
        prog="python3 -m tooling.release.notes",
        description="Print a tag's section of docs/RELEASES.md.",
    )
    parser.add_argument("tag", help="the tag whose notes to print, for example v1.2.0")
    arguments = parser.parse_args(argv)

    try:
        text = history.read_releases()
    except OSError as exc:
        print(f"{history.RELEASES_DOCUMENT}: unable to read: {exc}", file=sys.stderr)
        return 1

    section = history.release_section(text, arguments.tag)
    if section is None:
        print(f'{history.RELEASES_DOCUMENT}: no "### {arguments.tag}" section', file=sys.stderr)
        return 1

    print(section[1])
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
