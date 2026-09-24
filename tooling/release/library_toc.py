"""Print the `.toc` of the standalone MoltenCodes addon.

    python3 -m tooling.release.library_toc                      # MoltenCodes.toc
    python3 -m tooling.release.library_toc --package timerKit   # MoltenCodes-TimerKit.toc
    python3 -m tooling.release.library_toc --write .            # write it instead of printing

The framework installs two ways: its Kits are embedded in an addon, or the
framework is installed once as the addon "MoltenCodes" and addons depend on it.
This command prints that addon's `.toc`: the supported `## Interface` numbers
from `tooling/validation/supported_clients.json`, the title, notes, version
placeholder and site fields, then the runtime files of every release package in
the builder's load order: a package's facade `<packageId>\\<Facade>.lua` and,
after it, any further runtime files from subdirectories of its `src/`.
Development packages are never listed.

`--package <id>` prints the `.toc` of a single-Kit release instead: the addon
`MoltenCodes-<Facade>`, loading that Kit and its required dependencies in load
order, so a single-Kit bundle installs as an addon too.

The text is exactly what `python3 -m tooling.package.build` writes into the
bundle root, because both come from `tooling.package.build.bundle_toc`. There is
no separate layout for the packager: after `.pkgmeta`'s `move-folders`, the
packager's zip is `MoltenCodes/<packageId>/<Facade>.lua` plus any subdirectories
of the package's `src/`, the builder's layout.
The release workflow writes the file into its checkout just before the packager
runs; it is never committed.
"""

from __future__ import annotations

import argparse
import sys
from pathlib import Path
from typing import NamedTuple, Sequence

from tooling.package import build


class AddonToc(NamedTuple):
    """A generated `.toc`: the addon name (and so the file name) and its text."""

    name: str
    text: str

    @property
    def file_name(self) -> str:
        """The name the client requires: the addon folder's name plus `.toc`."""
        return f"{self.name}.toc"


def standalone_toc(package_name: str | None = None) -> AddonToc:
    """Return the `.toc` for every release package, or for one package's closure.

    Raises `tooling.package.build.BuildError` when the manifests are invalid or
    `package_name` is unknown or a development package, exactly as the builder
    would refuse the same build.
    """
    manifests = build.load_valid_manifests()
    selection = build.select_packages(manifests, package_name)
    return AddonToc(selection.bundle_name, build.bundle_toc(selection))


def main(argv: Sequence[str] | None = None) -> int:
    """Print (or write) the standalone addon's `.toc`."""
    parser = argparse.ArgumentParser(
        prog="python3 -m tooling.release.library_toc",
        description="Print the .toc of the standalone MoltenCodes addon, or of one Kit's addon.",
    )
    parser.add_argument(
        "--package",
        metavar="ID",
        help="the .toc of MoltenCodes-<Facade>: this release package and its dependencies",
    )
    parser.add_argument(
        "--write",
        metavar="DIR",
        type=Path,
        help="write <addon>.toc into DIR and print its path, instead of printing the text",
    )
    arguments = parser.parse_args(argv)

    try:
        addon = standalone_toc(arguments.package)
    except build.BuildError as failure:
        print(f"error: {failure}", file=sys.stderr)
        return 1

    if arguments.write is None:
        sys.stdout.write(addon.text)
        return 0

    target = arguments.write / addon.file_name
    target.write_text(addon.text, encoding="utf-8")
    print(target)
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
