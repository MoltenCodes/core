"""List package IDs from the manifests, one per line.

    python3 -m tooling.package.list             # every package
    python3 -m tooling.package.list --release   # only packages that are bundled

The release workflow loops over `--release` to build one bundle per package, so
the package list is discovered from the manifests in one place and development
packages (`"distribution": "development"`) are never handed to
`tooling.package.build --package`, which refuses them.
"""

from __future__ import annotations

import argparse
import sys
from typing import Any, Sequence

from tooling.validation.validate_manifests import is_development, load_manifests


def package_ids(manifests: dict[str, dict[str, Any]], *, release_only: bool) -> list[str]:
    """Return the package IDs in `manifests`, sorted, optionally only release packages."""
    return sorted(
        name for name, data in manifests.items() if not (release_only and is_development(data))
    )


def main(argv: Sequence[str] | None = None) -> int:
    """Print the selected package IDs, or the manifest errors that prevent it."""
    parser = argparse.ArgumentParser(
        prog="python3 -m tooling.package.list",
        description="Print package IDs discovered from the manifests, one per line.",
    )
    parser.add_argument(
        "--release",
        action="store_true",
        help="print only release packages (skip distribution: development)",
    )
    arguments = parser.parse_args(argv)

    manifests, errors = load_manifests()
    if errors:
        for item in errors:
            print(f"error: {item}", file=sys.stderr)
        return 1

    for name in package_ids(manifests, release_only=arguments.release):
        print(name)
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
