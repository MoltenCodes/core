"""Install, or remove, the MoltenCodes real-client test setup in a game folder.

The real-client tests (``tests/client/README.md``) run inside World of
Warcraft, so something has to put the framework and the test addons where the
client loads them. This command does that and nothing else:

* ``--package ID`` (repeatable) builds the release bundle with
  ``tooling.package.build`` into a temporary directory and installs, under
  ``<wow>/<flavour>/Interface/AddOns``:

  - ``MoltenCodes/``, the bundle, exactly as a player would install it;
  - ``MoltenCodesTest/``, the harness, with a fresh copy of
    ``packages/testKit/src/TestKit.lua`` (TestKit is a development package, so
    the bundle never carries it) and a generated ``Expected.lua`` listing every
    package's ID, API and revision from the committed manifests;
  - ``MoltenCodesTest_<Facade>/`` for each requested package.

  Exactly these folders are replaced when they already exist; no other addon
  is touched.

* ``--remove`` deletes ``MoltenCodes``, ``MoltenCodesTest`` and every
  ``MoltenCodesTest_*`` folder from ``AddOns``, and every
  ``MoltenCodesTest.lua`` / ``MoltenCodesTest.lua.bak`` saved-variables file
  under ``WTF/Account/*/SavedVariables/`` and
  ``WTF/Account/*/*/*/SavedVariables/``, so the client is left as it was.

Both refuse when the ``AddOns`` folder does not exist, which is the sign of a
wrong ``--wow-dir``. Neither follows a symbolic link out of the game folder: a
link is removed as a link, and a directory reached only through a link that
leaves the folder is skipped. ``--dry-run`` prints what would change and
changes nothing.
"""

from __future__ import annotations

import argparse
import shutil
import sys
import tempfile
from pathlib import Path
from typing import Any, Callable, NamedTuple, Sequence

from tooling.package import build as bundle_builder
from tooling.validation.validate_manifests import ROOT, load_manifests


#: The flavour folder under the game folder, as the Retail client names it.
DEFAULT_FLAVOUR_DIRECTORY = "_retail_"

#: The installed framework addon; the bundle's own name.
FRAMEWORK_ADDON = bundle_builder.FRAMEWORK_BUNDLE_NAME

#: The harness addon, and the prefix of every package test addon.
HARNESS_ADDON = "MoltenCodesTest"
TEST_ADDON_PREFIX = HARNESS_ADDON + "_"

#: Where the test addons live in the repository.
CLIENT_TESTS = ROOT / "tests" / "client"

#: The TestKit source the harness loads; never committed inside the harness.
TEST_KIT_SOURCE = ROOT / "packages" / "testKit" / "src" / "TestKit.lua"
TEST_KIT_PACKAGE = "testKit"

#: The generated file listing what the harness should find loaded.
EXPECTED_FILE_NAME = "Expected.lua"

#: File kinds copied from an addon folder in the repository. Documentation
#: next to a test addon (EXPECTED.md) is for the owner, not for the client.
ADDON_FILE_SUFFIXES = (".toc", ".lua")

#: The saved-variables files the harness writes, per account or per character.
SAVED_VARIABLES_NAMES = (f"{HARNESS_ADDON}.lua", f"{HARNESS_ADDON}.lua.bak")

#: Where the client keeps saved variables, relative to the flavour folder:
#: account-wide, then per character (``<account>/<realm>/<character>``).
SAVED_VARIABLES_PATTERNS = (
    "WTF/Account/*/SavedVariables",
    "WTF/Account/*/*/*/SavedVariables",
)


class InstallError(Exception):
    """The command cannot proceed; the message says why and what to do."""


class ClientLayout(NamedTuple):
    """The folders of one client flavour inside a game folder."""

    wow_dir: Path
    flavour_dir: Path
    addons_dir: Path


# Paths and safety -------------------------------------------------------------


def resolve_layout(wow_dir: Path, flavour_directory: str) -> ClientLayout:
    """Locate the flavour's AddOns folder, refusing when it does not exist.

    The AddOns folder is required even for ``--remove``: its absence means the
    game folder or the flavour is wrong, and guessing would risk deleting from
    the wrong place.
    """
    root = wow_dir.expanduser().resolve()
    flavour_dir = root / flavour_directory
    addons_dir = flavour_dir / "Interface" / "AddOns"
    if not addons_dir.is_dir():
        raise InstallError(
            f"{addons_dir} does not exist; check --wow-dir and --flavour-dir "
            "(the client creates Interface/AddOns the first time it starts)"
        )
    if not is_inside(addons_dir, root):
        raise InstallError(f"{addons_dir} leaves {root} through a symbolic link; refusing")
    return ClientLayout(root, flavour_dir, addons_dir)


def is_inside(path: Path, root: Path) -> bool:
    """Whether ``path``, with every link resolved, lies inside ``root``."""
    return path.resolve().is_relative_to(root.resolve())


def delete_entry(path: Path) -> None:
    """Delete one file, folder or link; a link is removed without following it."""
    if path.is_symlink() or path.is_file():
        path.unlink()
    else:
        shutil.rmtree(path)


# Selecting what to install ----------------------------------------------------------


def test_addon_name(package_id: str, manifests: dict[str, dict[str, Any]]) -> str:
    """The test addon folder of a package: ``MoltenCodesTest_<displayName>``."""
    return TEST_ADDON_PREFIX + str(manifests[package_id]["displayName"])


def available_test_packages(manifests: dict[str, dict[str, Any]]) -> list[str]:
    """Package IDs that have a test addon under ``tests/client/``, sorted."""
    return sorted(
        package_id
        for package_id in manifests
        if (CLIENT_TESTS / test_addon_name(package_id, manifests)).is_dir()
    )


def select_test_addons(
    package_ids: Sequence[str], manifests: dict[str, dict[str, Any]]
) -> list[str]:
    """The test addon folders for ``package_ids``, refusing unknown packages."""
    available = available_test_packages(manifests)
    addons: list[str] = []
    for package_id in package_ids:
        if package_id not in manifests:
            raise InstallError(f'unknown package "{package_id}"; see python3 -m tooling.package.list')
        if package_id not in available:
            raise InstallError(
                f'package "{package_id}" has no test addon under tests/client/; '
                f"available: {', '.join(available) or 'none'}"
            )
        name = test_addon_name(package_id, manifests)
        if name not in addons:
            addons.append(name)
    return addons


# Expected.lua -----------------------------------------------------------------------


def expected_packages(
    bundle_manifest: dict[str, Any], manifests: dict[str, dict[str, Any]]
) -> list[dict[str, Any]]:
    """Every package the client will load, with its committed API and revision.

    The bundle's packages come from the ``manifest.json`` the builder wrote,
    which it derived from the committed package manifests; TestKit comes from
    its own manifest, because the harness loads it and the bundle never does.
    """
    rows: list[dict[str, Any]] = []
    for package_id, entry in bundle_manifest["packages"].items():
        rows.append(
            {
                "id": package_id,
                "api": entry["api"],
                "revision": entry["revision"],
                "version": entry["version"],
                "bundled": True,
            }
        )
    test_kit = manifests[TEST_KIT_PACKAGE]
    rows.append(
        {
            "id": TEST_KIT_PACKAGE,
            "api": test_kit["api"],
            "revision": test_kit["revision"],
            "version": test_kit["version"],
            "bundled": False,
        }
    )
    return rows


def lua_string(value: str) -> str:
    """A double-quoted Lua string literal; manifest values are plain ASCII."""
    escaped = value.replace("\\", "\\\\").replace('"', '\\"')
    return f'"{escaped}"'


def render_expected(rows: Sequence[dict[str, Any]]) -> str:
    """The text of ``Expected.lua``: the rows, handed to the harness's private table."""
    lines = [
        "-- MoltenCodes Test: Expected.lua",
        "--",
        "-- Generated by python3 -m tooling.client.install; do not edit. Every",
        "-- package the client loads for the tests, with the API and revision its",
        "-- committed manifest declares. The harness reads it from the addon's",
        "-- private table; see tests/client/README.md.",
        "",
        "local _, private = ...",
        "",
        "private.expectedPackages = {",
    ]
    for row in rows:
        lines.append(
            "    { "
            f"id = {lua_string(row['id'])}, "
            f"api = {int(row['api'])}, "
            f"revision = {int(row['revision'])}, "
            f"version = {lua_string(row['version'])}, "
            f"bundled = {'true' if row['bundled'] else 'false'}"
            " },"
        )
    lines.append("}")
    return "\n".join(lines) + "\n"


# Installing ---------------------------------------------------------------------------


def copy_addon_files(source: Path, destination: Path) -> list[str]:
    """Copy an addon folder's ``.toc`` and ``.lua`` files; return their names."""
    destination.mkdir(parents=True)
    copied: list[str] = []
    for path in sorted(source.iterdir()):
        if path.is_file() and path.suffix in ADDON_FILE_SUFFIXES:
            shutil.copyfile(path, destination / path.name)
            copied.append(path.name)
    return copied


def replace_addon(addons_dir: Path, name: str, fill: Callable[[Path], None]) -> str:
    """Replace ``AddOns/<name>`` with what ``fill`` writes; return a verb for the report."""
    destination = addons_dir / name
    verb = "installed"
    if destination.exists() or destination.is_symlink():
        delete_entry(destination)
        verb = "replaced"
    fill(destination)
    return verb


def install(
    layout: ClientLayout,
    package_ids: Sequence[str],
    dry_run: bool = False,
    report: Callable[[str], None] = print,
) -> None:
    """Build the bundle and install it, the harness and the requested test addons."""
    manifests, errors = load_manifests()
    if errors:
        raise InstallError("package manifests are invalid: " + "; ".join(errors))
    test_addons = select_test_addons(package_ids, manifests)

    planned = [FRAMEWORK_ADDON, HARNESS_ADDON, *test_addons]
    if dry_run:
        for name in planned:
            report(f"would install {layout.addons_dir / name}")
        return

    with tempfile.TemporaryDirectory(prefix="moltencodes-client-") as temporary:
        try:
            bundle_manifest = bundle_builder.build(Path(temporary))
        except bundle_builder.BuildError as failure:
            raise InstallError(f"the bundle could not be built: {failure}") from failure
        bundle_dir = Path(temporary) / FRAMEWORK_ADDON

        verb = replace_addon(
            layout.addons_dir,
            FRAMEWORK_ADDON,
            lambda destination: shutil.copytree(bundle_dir, destination),
        )
        report(
            f"{verb} {layout.addons_dir / FRAMEWORK_ADDON} "
            f"({len(bundle_manifest['packages'])} packages)"
        )

    rows = expected_packages(bundle_manifest, manifests)

    def fill_harness(destination: Path) -> None:
        copy_addon_files(CLIENT_TESTS / HARNESS_ADDON, destination)
        shutil.copyfile(TEST_KIT_SOURCE, destination / TEST_KIT_SOURCE.name)
        (destination / EXPECTED_FILE_NAME).write_text(render_expected(rows), encoding="utf-8")

    verb = replace_addon(layout.addons_dir, HARNESS_ADDON, fill_harness)
    test_kit = manifests[TEST_KIT_PACKAGE]
    report(
        f"{verb} {layout.addons_dir / HARNESS_ADDON} "
        f"(TestKit revision {test_kit['revision']}, {EXPECTED_FILE_NAME} lists {len(rows)} packages)"
    )

    for name in test_addons:
        verb = replace_addon(
            layout.addons_dir,
            name,
            lambda destination, name=name: copy_addon_files(CLIENT_TESTS / name, destination),
        )
        report(f"{verb} {layout.addons_dir / name}")


# Removing -------------------------------------------------------------------------------


def addons_to_remove(layout: ClientLayout) -> list[Path]:
    """Every installed folder or link this command owns in ``AddOns``."""
    found: list[Path] = []
    for path in sorted(layout.addons_dir.iterdir()):
        owned = path.name in (FRAMEWORK_ADDON, HARNESS_ADDON) or path.name.startswith(
            TEST_ADDON_PREFIX
        )
        if owned:
            found.append(path)
    return found


def saved_variables_to_remove(layout: ClientLayout) -> tuple[list[Path], list[Path]]:
    """The harness's saved-variables files, and the folders skipped as links out.

    ``glob`` would walk through a linked account or character folder; a folder
    that resolves outside the game folder is reported instead of searched.
    """
    files: list[Path] = []
    skipped: list[Path] = []
    for pattern in SAVED_VARIABLES_PATTERNS:
        for folder in sorted(layout.flavour_dir.glob(pattern)):
            if not is_inside(folder, layout.wow_dir):
                skipped.append(folder)
                continue
            for name in SAVED_VARIABLES_NAMES:
                candidate = folder / name
                if candidate.is_file() or candidate.is_symlink():
                    files.append(candidate)
    return files, skipped


def remove(
    layout: ClientLayout,
    dry_run: bool = False,
    report: Callable[[str], None] = print,
) -> None:
    """Delete the installed addons and the harness's saved variables."""
    addons = addons_to_remove(layout)
    saved_files, skipped = saved_variables_to_remove(layout)
    verb = "would remove" if dry_run else "removed"

    for folder in skipped:
        report(f"skipped {folder}: it leaves {layout.wow_dir} through a symbolic link")
    for path in [*addons, *saved_files]:
        if not dry_run:
            delete_entry(path)
        report(f"{verb} {path}")
    if not addons and not saved_files:
        report("nothing to remove")


# Command line -----------------------------------------------------------------------------


def parse_args(argv: Sequence[str] | None = None) -> argparse.Namespace:
    """Parse the installer's command line."""
    parser = argparse.ArgumentParser(
        prog="python3 -m tooling.client.install",
        description=(
            "Install the MoltenCodes bundle, the MoltenCodesTest harness and package "
            "test addons into a World of Warcraft folder, or remove them and the "
            "harness's saved variables. See tests/client/README.md."
        ),
    )
    parser.add_argument(
        "--wow-dir",
        required=True,
        metavar="DIR",
        help='the game folder, for example "/Applications/World of Warcraft"',
    )
    parser.add_argument(
        "--flavour-dir",
        default=DEFAULT_FLAVOUR_DIRECTORY,
        metavar="NAME",
        help=f"the flavour folder inside it (default: {DEFAULT_FLAVOUR_DIRECTORY})",
    )
    action = parser.add_mutually_exclusive_group(required=True)
    action.add_argument(
        "--package",
        action="append",
        metavar="ID",
        dest="packages",
        help="install the test addon of this package (repeatable), with the bundle and harness",
    )
    action.add_argument(
        "--remove",
        action="store_true",
        help="remove every installed addon of this command and the harness's saved variables",
    )
    parser.add_argument(
        "--dry-run",
        action="store_true",
        help="print what would be installed or removed, and change nothing",
    )
    return parser.parse_args(argv)


def main(argv: Sequence[str] | None = None) -> int:
    """Entry point for ``python3 -m tooling.client.install``."""
    args = parse_args(argv)
    try:
        layout = resolve_layout(Path(args.wow_dir), args.flavour_dir)
        if args.remove:
            remove(layout, dry_run=args.dry_run)
        else:
            install(layout, args.packages, dry_run=args.dry_run)
    except InstallError as failure:
        print(f"error: {failure}", file=sys.stderr)
        return 1
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
