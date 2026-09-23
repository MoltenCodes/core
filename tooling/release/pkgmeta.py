"""Print the packager metadata for a single-Kit release.

    python3 -m tooling.release.pkgmeta --package timerKit
    python3 -m tooling.release.pkgmeta --package timerKit --output .pkgmeta-package

The repository's `.pkgmeta` packages every release package as the addon
"MoltenCodes". A package tag (`timerKit-v0.6.0`) releases one Kit instead, as
the addon "MoltenCodes-TimerKit", and the BigWigs packager builds whatever its
metadata describes. This command derives that metadata from `.pkgmeta`, so the
two never drift apart:

- `package-as` becomes `MoltenCodes-<Facade>`;
- `move-folders` keeps only the entries of the Kit and the packages it requires
  (its closure, in the builder's sense), renamed under the new addon folder;
- `ignore` gains `packages/<id>` for every other package, so nothing outside
  the closure reaches the zip;
- every other key is copied unchanged.

The release workflow writes the result into its own checkout and points the
packager at it with `-m`; it is never committed. `--output` also adds the
written file's own name to `ignore`, and `.pkgmeta` itself is always ignored,
so neither can ship inside the zip.

Only the YAML shapes `.pkgmeta` uses are read: top-level `key: value` scalars,
block lists (`  - entry`) and block maps (`  source: target`). Anything else
fails closed rather than being guessed at.
"""

from __future__ import annotations

import argparse
import re
import sys
from pathlib import Path
from typing import Sequence, Union

from tooling.package import build


#: The repository's packager metadata, relative to the repository root.
PKGMETA_PATH = Path(".pkgmeta")

#: One top-level value: a scalar, a block list or a block map.
Value = Union[str, list[str], list[tuple[str, str]]]

#: `# comment` at the end of a YAML line (after whitespace).
TRAILING_COMMENT_RE = re.compile(r"\s+#.*$")


class PkgmetaError(ValueError):
    """`.pkgmeta` uses a shape this reader does not understand, or a key is missing."""


def _strip(value: str) -> str:
    """Drop a trailing comment and surrounding quotes from a YAML scalar."""
    return TRAILING_COMMENT_RE.sub("", value).strip().strip("\"'")


def parse_pkgmeta(text: str) -> dict[str, Value]:
    """Parse the subset of YAML `.pkgmeta` uses into an ordered mapping.

    A top-level key either carries a scalar on its own line or introduces an
    indented block that is entirely `- entry` lines (a list) or entirely
    `source: target` lines (a map). Comments and blank lines are skipped.
    """
    parsed: dict[str, Value] = {}
    lists: dict[str, list[str]] = {}
    maps: dict[str, list[tuple[str, str]]] = {}
    current: str | None = None
    for number, line in enumerate(text.splitlines(), start=1):
        stripped = line.strip()
        if not stripped or stripped.startswith("#"):
            continue

        if not line[0].isspace():
            key, separator, rest = stripped.partition(":")
            if not separator:
                raise PkgmetaError(f"line {number}: expected a top-level `key:`")
            rest = _strip(rest)
            # An empty block stays an empty list until its first entry says
            # whether it is a list or a map.
            parsed[key] = rest if rest else []
            current = None if rest else key
            continue

        if current is None:
            raise PkgmetaError(f"line {number}: indented line outside a list or map")
        if stripped.startswith("- ") and current not in maps:
            entries = lists.setdefault(current, [])
            parsed[current] = entries
            entries.append(_strip(stripped[2:]))
            continue

        source, separator, target = stripped.partition(":")
        if not separator or current in lists:
            raise PkgmetaError(f"line {number}: cannot read this entry of `{current}`")
        pairs = maps.setdefault(current, [])
        parsed[current] = pairs
        pairs.append((_strip(source), _strip(target)))
    return parsed


def render_pkgmeta(data: dict[str, Value], header: Sequence[str] = ()) -> str:
    """Write a mapping from `parse_pkgmeta` back as `.pkgmeta` YAML."""
    lines = [f"# {line}" if line else "#" for line in header]
    for key, value in data.items():
        if lines:
            lines.append("")
        if isinstance(value, str):
            lines.append(f"{key}: {value}")
            continue
        lines.append(f"{key}:")
        for item in value:
            if isinstance(item, tuple):
                lines.append(f"  {item[0]}: {item[1]}")
            else:
                lines.append(f"  - {item}")
    return "\n".join(lines) + "\n"


def _package_of(path: str, addon: str) -> str | None:
    """Return the package ID in a `<addon>/packages/<id>/...` path, or `None`."""
    parts = path.split("/")
    if len(parts) >= 3 and parts[0] == addon and parts[1] == "packages":
        return parts[2]
    return None


def _rename(path: str, old_addon: str, new_addon: str) -> str:
    """Move a `move-folders` path from the old addon folder to the new one."""
    if path == old_addon or path.startswith(f"{old_addon}/"):
        return new_addon + path[len(old_addon) :]
    return path


def package_pkgmeta(
    data: dict[str, Value],
    *,
    addon: str,
    closure: Sequence[str],
    all_packages: Sequence[str],
    extra_ignores: Sequence[str] = (),
) -> dict[str, Value]:
    """Narrow parsed `.pkgmeta` data to one Kit's release.

    `addon` is the new `package-as` (`MoltenCodes-TimerKit`), `closure` the
    packages the release ships and `all_packages` every package in the
    repository. Raises `PkgmetaError` when `package-as`, `ignore` or
    `move-folders` is missing or has the wrong shape.
    """
    old_addon = data.get("package-as")
    ignore = data.get("ignore")
    moves = data.get("move-folders")
    if not isinstance(old_addon, str):
        raise PkgmetaError("`package-as` must be a scalar")
    if not isinstance(ignore, list) or not all(isinstance(item, str) for item in ignore):
        raise PkgmetaError("`ignore` must be a list")
    if not isinstance(moves, list) or not all(isinstance(item, tuple) for item in moves):
        raise PkgmetaError("`move-folders` must be a map")

    kept = set(closure)
    narrowed_ignore = [str(item) for item in ignore]
    for name in sorted(all_packages):
        entry = f"packages/{name}"
        if name not in kept and entry not in narrowed_ignore:
            narrowed_ignore.append(entry)
    for entry in extra_ignores:
        if entry not in narrowed_ignore:
            narrowed_ignore.append(entry)

    narrowed_moves: list[tuple[str, str]] = []
    for item in moves:
        if not isinstance(item, tuple):
            continue
        source, target = item
        package = _package_of(source, old_addon)
        if package is not None and package not in kept:
            continue
        narrowed_moves.append(
            (_rename(source, old_addon, addon), _rename(target, old_addon, addon))
        )

    result: dict[str, Value] = {}
    for key, value in data.items():
        if key == "package-as":
            result[key] = addon
        elif key == "ignore":
            result[key] = narrowed_ignore
        elif key == "move-folders":
            result[key] = narrowed_moves
        else:
            result[key] = value
    return result


def single_package_pkgmeta(package_name: str, output_name: str | None = None) -> str:
    """Return the `.pkgmeta` text that packages `package_name` and its closure alone.

    Raises `tooling.package.build.BuildError` for an unknown or development
    package (as the builder would) and `PkgmetaError` when `.pkgmeta` cannot
    be read. `.pkgmeta` and `output_name`, the file name the result is written
    under, are added to `ignore`.
    """
    manifests = build.load_valid_manifests()
    selection = build.select_packages(manifests, package_name)
    data = parse_pkgmeta((build.ROOT / PKGMETA_PATH).read_text(encoding="utf-8"))
    narrowed = package_pkgmeta(
        data,
        addon=selection.bundle_name,
        closure=selection.ordered,
        all_packages=sorted(manifests),
        # The repository's own `.pkgmeta` is not this release's metadata, and
        # the written file is not part of the addon.
        extra_ignores=[str(PKGMETA_PATH)] + ([output_name] if output_name else []),
    )
    header = [
        f"Generated by `python3 -m tooling.release.pkgmeta --package {package_name}` from",
        f".pkgmeta for the release of {selection.bundle_name}. Never committed;",
        "see docs/RELEASES.md.",
    ]
    return render_pkgmeta(narrowed, header)


def main(argv: Sequence[str] | None = None) -> int:
    """Print, or write, the packager metadata of one Kit's release."""
    parser = argparse.ArgumentParser(
        prog="python3 -m tooling.release.pkgmeta",
        description="Print the .pkgmeta that packages one release package and its dependencies.",
    )
    parser.add_argument("--package", metavar="ID", required=True, help="the package to release")
    parser.add_argument(
        "--output",
        metavar="FILE",
        type=Path,
        help="write the metadata to FILE (and ignore FILE in it) instead of printing it",
    )
    arguments = parser.parse_args(argv)

    output_name = None if arguments.output is None else arguments.output.name
    try:
        text = single_package_pkgmeta(arguments.package, output_name)
    except (build.BuildError, PkgmetaError, OSError) as failure:
        print(f"error: {failure}", file=sys.stderr)
        return 1

    if arguments.output is None:
        sys.stdout.write(text)
    else:
        arguments.output.write_text(text, encoding="utf-8")
        print(arguments.output)
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
