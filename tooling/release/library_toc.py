"""Print the `.toc` the BigWigs packager needs to package the framework.

    python3 -m tooling.release.library_toc > MoltenCodes.toc

The framework deliberately has no `.toc` in the repository: it is embedded by
addons, not installed. The packager, however, refuses to run without a `.toc`
named after `package-as` in `.pkgmeta`, and reads the supported game versions
for the upload from its `## Interface` line. The release workflow therefore
writes this file into its own checkout just before running the packager, and
nothing ever commits it.

The file lists no Lua files, so an installed copy loads nothing and changes
nothing; it only makes the upload describable. Its Interface line comes from
`tooling/validation/supported_clients.json`, the one table every other
Interface number is checked against.
"""

from __future__ import annotations

import sys
from typing import Sequence

from tooling.validation.interface_numbers import load_supported_clients


#: The `package-as` name in `.pkgmeta`; the packager looks for `<name>.toc`.
PACKAGE_NAME = "MoltenCodes"


def library_toc() -> str:
    """Return the text of the packaging-only `.toc`."""
    lines = [
        load_supported_clients().toc_line(),
        f"## Title: {PACKAGE_NAME}",
        "## Notes: Embeddable World of Warcraft addon framework. Loads nothing on its own; "
        "addons embed the Kits they use.",
        "## Author: MoltenCodes",
        "## Version: @project-version@",
        "## X-License: MIT",
        "## X-Website: https://github.com/MoltenCodes/core",
        "",
        "# This file exists only so the packager can build and upload the bundle.",
        "# It deliberately lists no files; see docs/RELEASES.md.",
    ]
    return "\n".join(lines) + "\n"


def main(argv: Sequence[str] | None = None) -> int:
    """Write the packaging-only `.toc` to standard output."""
    del argv
    sys.stdout.write(library_toc())
    return 0


if __name__ == "__main__":
    raise SystemExit(main(sys.argv[1:]))
