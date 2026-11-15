"""Install, or remove, the in-client benchmark addons in a game folder.

The in-client runner (``docs/BENCHMARKS.md``, "In-client runner") measures
inside World of Warcraft, so something has to put its addons where the client
loads them. This command does that and nothing else, the way
``tooling.client.install`` does it for the real-client tests:

* installing writes three addons under ``<wow>/<flavour>/Interface/AddOns``:

  - ``MoltenCodesBench/``, the harness (``/mcb``): its committed files from
    ``tooling/bench/client/MoltenCodesBench/``, a generated
    ``Installation.lua`` (the commit, the flavour folder, the time, what each
    side carries and the workload catalogue of ``client_workloads.py``), and
    ``modules/``, every benchmark Lua module wrapped so the client can define
    it without ``require`` (see ``Loader.lua``);
  - ``MoltenCodesBench_Kits/``, load on demand: the release bundle
    ``tooling.package.build`` builds (its Lua files and licence) plus
    ``LibStub/LibStub.lua``, which the InteropKit rows reach through;
  - ``MoltenCodesBench_Ace3/``, load on demand: exactly the Ace3 files the
    benchmark loads (``tooling.bench.ace3.LOADED_FILES``) and Ace3's licence,
    copied from the pinned, checksummed cache outside the repository. The
    cache is checked against its digest again right before copying. Ace3 is
    never committed or bundled; copying it into the local game folder is use,
    not redistribution (``docs/BENCHMARKS.md``, "Ace3 licence").

  Every ``.toc`` carries the ``## Interface`` line of
  ``supported_clients.json``. Exactly these folders are replaced when they
  exist; no other addon is touched.

* ``--remove`` deletes ``MoltenCodesBench`` and every ``MoltenCodesBench_*``
  folder from ``AddOns``, the harness's saved variables
  (``MoltenCodesBench.lua`` and its ``.bak``) under every account and
  character, and their lines in every ``AddOns.txt``. Nothing else is removed.

Both refuse when the ``AddOns`` folder does not exist, and ``--dry-run``
prints what would happen and changes nothing (and downloads nothing).

    python3 -m tooling.bench.client_install --wow-dir DIR [--flavour-dir NAME] [--cache DIR]
                                             [--dry-run]
    python3 -m tooling.bench.client_install --wow-dir DIR [--flavour-dir NAME] --remove [--dry-run]
"""

from __future__ import annotations

import argparse
import json
import re
import shutil
import sys
import tempfile
from pathlib import Path
from typing import Any, Callable, Sequence

from tooling.bench import ace3
from tooling.bench.client_workloads import (
    CLIENT_LUA_ROOT,
    CLIENT_WORKLOADS,
    DEFAULT_RELOAD_SECONDS,
    HARNESS_SOURCE,
    NOT_IN_CLIENT,
    SIDE_SETS,
    SMOKE_PROFILE,
    SideSet,
    all_profile,
    plan,
)
from tooling.bench.workloads import LUA_ROOT as HOST_LUA_ROOT
from tooling.client import install as client_install
from tooling.client.flavours import CLIENT_FLAVOURS, DEFAULT_FLAVOUR_DIRECTORY
from tooling.package import build as bundle_builder
from tooling.package import toc as toc_tools

#: The harness addon, and the prefix of each side addon.
HARNESS_ADDON = "MoltenCodesBench"
SIDE_ADDON_PREFIX = HARNESS_ADDON + "_"

#: The side addons, by the side name the workloads use.
KITS_ADDON = SIDE_ADDON_PREFIX + "Kits"
ACE3_ADDON = SIDE_ADDON_PREFIX + "Ace3"

#: The harness's saved-variables files.
SAVED_VARIABLES_NAMES = (f"{HARNESS_ADDON}.lua", f"{HARNESS_ADDON}.lua.bak")

#: The saved-variables files of the side addons that declare one (the `saved`
#: set's), which `--remove` deletes with the harness's.
SIDE_SAVED_VARIABLES_PATTERNS = (f"{SIDE_ADDON_PREFIX}*.lua", f"{SIDE_ADDON_PREFIX}*.lua.bak")

#: The newest host results file names every shared workload's cases, which
#: the `all` profile queues.
HOST_RESULTS = Path(__file__).resolve().parent / "results"

#: The generated files of the harness.
INSTALLATION_FILE_NAME = "Installation.lua"
MODULES_DIRECTORY = "modules"

#: The line of the harness's committed ``.toc`` the module list replaces.
MODULES_MARKER = "# @modules@"

#: Host modules the client never loads: the host entry point and the fake
#: client's host. Everything else under ``tooling/bench/lua`` is installed.
HOST_ONLY_MODULES = ("main", "BenchHost", "SimulatedTimers")

#: The Ace3 file the Kits side also loads, for the InteropKit rows.
LIBSTUB_FILE = "LibStub/LibStub.lua"

#: Ace3's licence, copied beside its files; never listed in a ``.toc``.
ACE3_LICENSE = "LICENSE.txt"


#: A Lua name, and the reserved words that look like one.
LUA_NAME_RE = re.compile(r"[A-Za-z_][A-Za-z0-9_]*")
LUA_KEYWORDS = frozenset(
    "and break do else elseif end false for function if in local nil not or repeat "
    "return then true until while".split()
)


class BenchInstallError(Exception):
    """The command cannot proceed; the message says why and what to do."""


# Ownership --------------------------------------------------------------------------


def is_owned_addon(name: str) -> bool:
    """Whether an addon of this name is one this command installs."""
    return name == HARNESS_ADDON or name.startswith(SIDE_ADDON_PREFIX)


# Modules --------------------------------------------------------------------------------


def module_sources() -> list[tuple[str, Path]]:
    """Every Lua module the harness defines, as ``(name, source)``, sorted by name.

    The host's measurement core and every host workload module (the shared
    workloads and the helpers they require), and every client module. A
    module's name is its path under its root with dots, as ``require`` spells
    it: ``workloads/Dispatch.lua`` is ``workloads.Dispatch``.
    """
    modules: dict[str, Path] = {}
    for root in (HOST_LUA_ROOT, CLIENT_LUA_ROOT):
        for path in sorted(root.rglob("*.lua")):
            name = ".".join(path.relative_to(root).with_suffix("").parts)
            if root == HOST_LUA_ROOT and name in HOST_ONLY_MODULES:
                continue
            if name in modules:
                raise BenchInstallError(f"module {name} exists in both Lua trees")
            modules[name] = path
    return sorted(modules.items())


def wrap_module(name: str, source: str) -> str:
    """A module's source wrapped in one ``DefineModule`` call for the harness.

    The call opens on the source's first line, so every line keeps its
    number and an error in the client names the line of the committed file.
    The module receives the harness's ``Require`` as ``require``.
    """
    if not source.endswith("\n"):
        source += "\n"
    opening = (
        f'local _, private = ...; private.DefineModule("{name}", function(require, ...) '
    )
    return opening + source + "end)\n"


def module_file(name: str) -> str:
    """The installed path of a module inside the harness, POSIX style."""
    return "/".join([MODULES_DIRECTORY, *name.split(".")]) + ".lua"


def toc_path(posix_path: str) -> str:
    """A POSIX relative path as a ``.toc`` line, with the client's backslashes."""
    return posix_path.replace("/", toc_tools.TOC_SEPARATOR)


# Installation.lua ------------------------------------------------------------------


def lua_key(key: str) -> str:
    """A table key as Lua writes it: a bare name when it is one, else a bracketed string."""
    if LUA_NAME_RE.fullmatch(key) and key not in LUA_KEYWORDS:
        return key
    return f"[{client_install.lua_string(key)}]"


def lua_literal(value: Any, indent: str = "") -> str:
    """A Lua literal for plain data: strings, numbers, booleans, ``None``, lists, dicts."""
    if value is None:
        return "nil"
    if isinstance(value, bool):
        return "true" if value else "false"
    if isinstance(value, (int, float)):
        return repr(value)
    if isinstance(value, str):
        return client_install.lua_string(value)
    inner = indent + "  "
    if isinstance(value, (list, tuple)):
        if not value:
            return "{}"
        items = [f"{inner}{lua_literal(item, inner)}," for item in value]
        return "{\n" + "\n".join(items) + f"\n{indent}}}"
    if isinstance(value, dict):
        if not value:
            return "{}"
        items = [
            f"{inner}{lua_key(str(key))} = {lua_literal(item, inner)},"
            for key, item in value.items()
        ]
        return "{\n" + "\n".join(items) + f"\n{indent}}}"
    raise TypeError(f"no Lua literal for {type(value).__name__}")


def side_facts(
    bundle_manifest: dict[str, Any], source: ace3.Ace3Source
) -> dict[str, dict[str, Any]]:
    """What each side addon carries, for ``Installation.lua``."""
    packages = [
        {
            "id": package_id,
            "facade": bundle_builder.facade_name(package_id),
            "api": int(entry["api"]),
            "revision": int(entry["revision"]),
            "version": str(entry["version"]),
        }
        for package_id, entry in bundle_manifest["packages"].items()
    ]
    return {
        "moltencodes": {"addon": KITS_ADDON, "files": [LIBSTUB_FILE], "packages": packages},
        "ace3": {
            "addon": ACE3_ADDON,
            "files": [path for path in ace3.LOADED_FILES if path != ACE3_LICENSE],
            "packages": [],
            "source": source.as_json(),
        },
    }


def set_addon(side: str, side_set: SideSet) -> str:
    """The folder of one set's side addon: the full Kits set is the Kits side itself."""
    if side == "moltencodes":
        return KITS_ADDON if side_set.kits is None else f"{KITS_ADDON}{side_set.name.title()}"
    return f"{ACE3_ADDON}{side_set.name.title()}"


def set_ace3_files(side_set: SideSet) -> list[str]:
    """The Ace3 files a set's Ace3 addon loads: the full set is every pinned file."""
    if side_set.ace3:
        return list(side_set.ace3)
    return [path for path in ace3.PINNED_FILES if path != ACE3_LICENSE]


def host_case_lists(results: Path = HOST_RESULTS) -> dict[str, tuple[str, ...]]:
    """Every shared workload's case names, from the newest host results file."""
    files = sorted(results.glob("*-host*.json"))
    if not files:
        return {}
    data = json.loads(files[-1].read_text(encoding="utf-8"))
    lists: dict[str, tuple[str, ...]] = {}
    for workload in data.get("workloads", []):
        side = workload.get("sides", {}).get("moltencodes", {})
        lists[workload["name"]] = tuple(case["name"] for case in side.get("cases", []))
    return lists


def profiles() -> dict[str, list[dict[str, str]]]:
    """The profiles `/mcb run smoke|all` queue, as the harness reads them."""
    return {
        "smoke": [{"workload": name, "case": case} for name, case in SMOKE_PROFILE],
        "all": [{"workload": name, "case": case} for name, case in all_profile(host_case_lists())],
    }


def installation_details(sides: dict[str, dict[str, Any]]) -> dict[str, Any]:
    """The facts saved once per installation: every Kit's version and the Ace3 source."""
    versions = {
        package["id"]: package["version"] for package in sides["moltencodes"]["packages"]
    }
    return {"packageVersions": versions, "ace3": sides["ace3"]["source"]}


def render_installation(
    installation: client_install.Installation, sides: dict[str, dict[str, Any]]
) -> str:
    """The text of ``Installation.lua``: the facts the harness saves with every result."""
    workloads = [
        {
            "name": workload.name,
            "module": workload.module,
            "title": workload.title,
            "origin": workload.origin,
            "loadsSide": workload.loads_side,
        }
        for workload in CLIENT_WORKLOADS
    ]
    not_in_client = [{"name": name, "reason": reason} for name, reason in NOT_IN_CLIENT.items()]
    facts = {
        "commit": installation.commit,
        "dirty": installation.dirty,
        "flavourDirectory": installation.flavour_directory,
        "installedAt": installation.installed_at,
    }
    lines = [
        "-- MoltenCodes Bench: Installation.lua",
        "--",
        "-- Generated by python3 -m tooling.bench.client_install; do not edit. What was",
        "-- installed from where, what each side addon carries, and the workloads the",
        "-- harness offers. The harness saves the installation with every result.",
        "",
        "local _, private = ...",
        "",
        f"private.installation = {lua_literal(facts)}",
        "",
        f"private.sides = {lua_literal(sides)}",
        "",
        f"private.workloads = {lua_literal(workloads)}",
        "",
        f"private.notInClient = {lua_literal(not_in_client)}",
        "",
        f"private.profiles = {lua_literal(profiles())}",
        "",
        f"private.installationDetails = {lua_literal(installation_details(sides))}",
    ]
    return "\n".join(lines) + "\n"


# .toc files --------------------------------------------------------------------------


def harness_toc(template: str, interface_line: str, module_files: Sequence[str]) -> str:
    """The harness ``.toc``: the committed one with the module list in place of the marker."""
    lines = template.splitlines()
    if lines.count(MODULES_MARKER) != 1:
        raise BenchInstallError(
            f"{HARNESS_ADDON}.toc must hold the line {MODULES_MARKER!r} exactly once"
        )
    index = lines.index(MODULES_MARKER)
    lines[index : index + 1] = [toc_path(path) for path in module_files]
    return client_install.with_interface_line("\n".join(lines) + "\n", interface_line)


def side_toc(
    name: str,
    notes: str,
    interface_line: str,
    files: Sequence[str],
    saved_variable: str | None = None,
) -> str:
    """The ``.toc`` of a side addon: load on demand, after the harness, these files."""
    lines = [
        interface_line,
        f"## Title: {name.replace('_', ' ')}",
        f"## Notes: {notes}",
        "## Author: MoltenCodes",
        "## Version: 1.0.0",
        "## LoadOnDemand: 1",
        f"## Dependencies: {HARNESS_ADDON}",
        *([f"## SavedVariables: {saved_variable}"] if saved_variable else []),
        "## X-Category: Development Tools",
        "",
        "# Generated by python3 -m tooling.bench.client_install; development only.",
        "# The harness loads this addon for one benchmark session at a time.",
        *(toc_path(path) for path in files),
    ]
    return "\n".join(lines) + "\n"


# Installing ------------------------------------------------------------------------------


def verified_ace3(source: ace3.Ace3Source) -> ace3.Ace3Source:
    """``source``, after checking its files still hash to the digest it was verified with.

    The cache lives outside the repository and could change between the fetch
    and the copy; what is copied must be exactly what was pinned.
    """
    try:
        digest = ace3.content_digest(source.directory)
    except ace3.FetchError as failure:
        raise BenchInstallError(str(failure)) from failure
    if digest != source.content_digest:
        raise BenchInstallError(
            f"the Ace3 cache at {source.directory} changed since it was verified "
            f"(digest {digest}); delete it and run the command again"
        )
    return source


def fill_harness(
    destination: Path,
    interface_line: str,
    installation: client_install.Installation,
    sides: dict[str, dict[str, Any]],
) -> int:
    """Write the harness addon into ``destination``; return the number of modules."""
    destination.mkdir(parents=True)
    for path in sorted(HARNESS_SOURCE.iterdir()):
        if path.is_file() and path.suffix == ".lua":
            shutil.copyfile(path, destination / path.name)
    modules = module_sources()
    files: list[str] = []
    for name, source in modules:
        relative = module_file(name)
        target = destination / relative
        target.parent.mkdir(parents=True, exist_ok=True)
        target.write_text(wrap_module(name, source.read_text(encoding="utf-8")), encoding="utf-8")
        files.append(relative)
    template = (HARNESS_SOURCE / f"{HARNESS_ADDON}.toc").read_text(encoding="utf-8")
    (destination / f"{HARNESS_ADDON}.toc").write_text(
        harness_toc(template, interface_line, files), encoding="utf-8"
    )
    (destination / INSTALLATION_FILE_NAME).write_text(
        render_installation(installation, sides), encoding="utf-8"
    )
    return len(modules)


def fill_kits(
    destination: Path, bundle_dir: Path, source: ace3.Ace3Source, interface_line: str
) -> list[str]:
    """Write the Kits side addon; return the Lua files its ``.toc`` loads, in order."""
    destination.mkdir(parents=True)
    bundle_toc = (bundle_dir / f"{bundle_dir.name}.toc").read_text(encoding="utf-8")
    bundle_files = [
        toc_tools.entry_to_bundle_path(entry) for entry in toc_tools.listed_files(bundle_toc)
    ]
    files = [LIBSTUB_FILE, *bundle_files]
    for relative in bundle_files:
        target = destination / relative
        target.parent.mkdir(parents=True, exist_ok=True)
        shutil.copyfile(bundle_dir / relative, target)
    (destination / "LibStub").mkdir()
    shutil.copyfile(source.directory / LIBSTUB_FILE, destination / LIBSTUB_FILE)
    shutil.copyfile(bundle_dir / "LICENSE", destination / "LICENSE")
    (destination / f"{KITS_ADDON}.toc").write_text(
        side_toc(
            KITS_ADDON,
            "The MoltenCodes Kits for the in-client benchmark; loaded by /mcb run.",
            interface_line,
            files,
        ),
        encoding="utf-8",
    )
    return files


def fill_ace3(destination: Path, source: ace3.Ace3Source, interface_line: str) -> list[str]:
    """Write the Ace3 side addon from the verified cache; return the files its ``.toc`` loads."""
    destination.mkdir(parents=True)
    for relative in ace3.LOADED_FILES:
        target = destination / relative
        target.parent.mkdir(parents=True, exist_ok=True)
        shutil.copyfile(source.directory / relative, target)
    files = [path for path in ace3.LOADED_FILES if path != ACE3_LICENSE]
    (destination / f"{ACE3_ADDON}.toc").write_text(
        side_toc(
            ACE3_ADDON,
            f"Ace3 at {source.commit[:12]} for the in-client benchmark; copied from the "
            "local cache at install time, never redistributed.",
            interface_line,
            files,
        ),
        encoding="utf-8",
    )
    return files


def fill_kits_set(
    destination: Path, set_bundle: Path, side_set: SideSet, interface_line: str
) -> list[str]:
    """Write one Kit set's side addon from its bundle; return the files its ``.toc`` loads."""
    destination.mkdir(parents=True)
    bundle_toc = (set_bundle / f"{set_bundle.name}.toc").read_text(encoding="utf-8")
    files = [toc_tools.entry_to_bundle_path(entry) for entry in toc_tools.listed_files(bundle_toc)]
    for relative in files:
        target = destination / relative
        target.parent.mkdir(parents=True, exist_ok=True)
        shutil.copyfile(set_bundle / relative, target)
    shutil.copyfile(set_bundle / "LICENSE", destination / "LICENSE")
    name = destination.name
    (destination / f"{name}.toc").write_text(
        side_toc(
            name,
            f"The {side_set.name} set of MoltenCodes Kits for the in-client benchmark.",
            interface_line,
            files,
            dict(side_set.saved_variables).get("moltencodes"),
        ),
        encoding="utf-8",
    )
    return files


def fill_ace3_set(
    destination: Path, source: ace3.Ace3Source, side_set: SideSet, interface_line: str
) -> list[str]:
    """Write one Ace3 set's side addon from the verified cache; return its files."""
    destination.mkdir(parents=True)
    files = set_ace3_files(side_set)
    for relative in [*files, ACE3_LICENSE]:
        target = destination / relative
        target.parent.mkdir(parents=True, exist_ok=True)
        shutil.copyfile(source.directory / relative, target)
    name = destination.name
    (destination / f"{name}.toc").write_text(
        side_toc(
            name,
            f"The {side_set.name} set of Ace3 {source.commit[:12]} for the in-client benchmark.",
            interface_line,
            files,
            dict(side_set.saved_variables).get("ace3"),
        ),
        encoding="utf-8",
    )
    return files


def install_sets(
    layout: client_install.ClientLayout,
    source: ace3.Ace3Source,
    interface_line: str,
    sides: dict[str, dict[str, Any]],
    report: Callable[[str], None],
) -> None:
    """Install every set's side addons and record them in ``sides``."""
    manifests = bundle_builder.load_valid_manifests()
    for side in ("moltencodes", "ace3"):
        sides[side]["sets"] = {}
    for side_set in SIDE_SETS:
        for side in ("moltencodes", "ace3"):
            sides[side]["sets"][side_set.name] = set_addon(side, side_set)
        if side_set.kits is not None:
            selection = bundle_builder.select(manifests, packages=list(side_set.kits))
            with tempfile.TemporaryDirectory(prefix="moltencodes-bench-set-") as temporary:
                bundle_builder.build(Path(temporary), selection=selection)
                set_bundle = next(path for path in Path(temporary).iterdir() if path.is_dir())
                name = set_addon("moltencodes", side_set)
                client_install.replace_addon(
                    layout.addons_dir,
                    name,
                    lambda destination: fill_kits_set(
                        destination, set_bundle, side_set, interface_line
                    ),
                )
            report(f"installed {layout.addons_dir / name} (the {side_set.name} Kit set)")
        name = set_addon("ace3", side_set)
        client_install.replace_addon(
            layout.addons_dir,
            name,
            lambda destination: fill_ace3_set(destination, source, side_set, interface_line),
        )
        report(f"installed {layout.addons_dir / name} (the {side_set.name} Ace3 set)")


def install(
    layout: client_install.ClientLayout,
    ace3_source: Callable[[], ace3.Ace3Source],
    dry_run: bool = False,
    report: Callable[[str], None] = print,
) -> None:
    """Build the bundle and install the harness and both side addons.

    ``ace3_source`` returns the verified Ace3 checkout; it is not called on a
    dry run, which downloads nothing.
    """
    interface_line = client_install.supported_interface_line()
    installation = client_install.current_installation(layout.flavour_dir.name)
    if dry_run:
        for name in (HARNESS_ADDON, KITS_ADDON, ACE3_ADDON):
            report(f"would install {layout.addons_dir / name}")
        report(
            f"would copy Ace3 {ace3.ACE3_COMMIT[:12]} ({len(ace3.LOADED_FILES)} files) from "
            "the benchmark cache, fetching it first when it is missing"
        )
        report(f'would write "{interface_line}" into every installed .toc')
        report(
            f"would record {client_install.describe_installation(installation)} "
            f"in {INSTALLATION_FILE_NAME}"
        )
        return

    source = verified_ace3(ace3_source())
    with tempfile.TemporaryDirectory(prefix="moltencodes-bench-") as temporary:
        try:
            bundle_manifest = bundle_builder.build(Path(temporary))
        except bundle_builder.BuildError as failure:
            raise BenchInstallError(f"the bundle could not be built: {failure}") from failure
        bundle_dir = Path(temporary) / bundle_builder.FRAMEWORK_BUNDLE_NAME
        sides = side_facts(bundle_manifest, source)

        kits_files: list[str] = []

        def fill_kits_side(destination: Path) -> None:
            kits_files.extend(fill_kits(destination, bundle_dir, source, interface_line))

        verb = client_install.replace_addon(layout.addons_dir, KITS_ADDON, fill_kits_side)
        report(
            f"{verb} {layout.addons_dir / KITS_ADDON} "
            f"({len(bundle_manifest['packages'])} packages, {len(kits_files)} files)"
        )

    verb = client_install.replace_addon(
        layout.addons_dir,
        ACE3_ADDON,
        lambda destination: fill_ace3(destination, source, interface_line),
    )
    report(f"{verb} {layout.addons_dir / ACE3_ADDON} (Ace3 {source.commit[:12]}, verified)")

    try:
        install_sets(layout, source, interface_line, sides, report)
    except bundle_builder.BuildError as failure:
        raise BenchInstallError(f"a set bundle could not be built: {failure}") from failure

    module_count: list[int] = []
    verb = client_install.replace_addon(
        layout.addons_dir,
        HARNESS_ADDON,
        lambda destination: module_count.append(
            fill_harness(destination, interface_line, installation, sides)
        ),
    )
    report(
        f"{verb} {layout.addons_dir / HARNESS_ADDON} ({module_count[0]} modules, "
        f"{client_install.describe_installation(installation)})"
    )
    report(f'every installed .toc carries "{interface_line}"')


# Removing -------------------------------------------------------------------------------


def remove(
    layout: client_install.ClientLayout,
    dry_run: bool = False,
    report: Callable[[str], None] = print,
) -> None:
    """Delete the bench addons, the harness's saved variables and their ``AddOns.txt`` lines."""
    addons = client_install.addons_to_remove(layout, is_owned_addon)
    saved_files, skipped_folders = client_install.saved_variables_to_remove(
        layout, SAVED_VARIABLES_NAMES, SIDE_SAVED_VARIABLES_PATTERNS
    )
    state_files, skipped_state_files = client_install.addon_state_files_to_clean(
        layout, is_owned_addon
    )
    verb = "would remove" if dry_run else "removed"

    for path in [*skipped_folders, *skipped_state_files]:
        report(f"skipped {path}: it leaves {layout.wow_dir} through a symbolic link")
    for path in [*addons, *saved_files]:
        if not dry_run:
            client_install.delete_entry(path)
        report(f"{verb} {path}")
    for path in state_files:
        if not dry_run:
            client_install.drop_owned_addon_state_lines(path, is_owned_addon)
        report(f"{verb} the MoltenCodes Bench lines from {path}")
    if not addons and not saved_files and not state_files:
        report("nothing to remove")


# Command line -----------------------------------------------------------------------------


def parse_args(argv: Sequence[str] | None = None) -> argparse.Namespace:
    """Parse the command line."""
    parser = argparse.ArgumentParser(
        prog="python3 -m tooling.bench.client_install",
        description=(
            "Install the in-client benchmark (the MoltenCodesBench harness and its Kits "
            "and Ace3 side addons) into a World of Warcraft folder, or remove it and the "
            "harness's saved variables. See docs/BENCHMARKS.md, \"In-client runner\"."
        ),
    )
    parser.add_argument(
        "--wow-dir",
        required=True,
        metavar="DIR",
        help='the game folder, for example "/Applications/World of Warcraft"',
    )
    known = ", ".join(flavour.directory for flavour in CLIENT_FLAVOURS)
    parser.add_argument(
        "--flavour-dir",
        default=DEFAULT_FLAVOUR_DIRECTORY,
        metavar="NAME",
        help=(
            f"the flavour folder inside it (default: {DEFAULT_FLAVOUR_DIRECTORY}; known: {known})"
        ),
    )
    parser.add_argument(
        "--cache", type=Path, default=None, help="the Ace3 cache root (see tooling.bench.ace3)"
    )
    parser.add_argument(
        "--remove",
        action="store_true",
        help="remove the bench addons, the harness's saved variables and their AddOns.txt lines",
    )
    parser.add_argument(
        "--plan",
        choices=("smoke", "all"),
        help="print what a profile run costs (sessions, reloads, minutes) and install nothing",
    )
    parser.add_argument(
        "--rounds", type=int, default=1, help="with --plan: rounds of the profile (default 1)"
    )
    parser.add_argument(
        "--reload-seconds",
        type=int,
        default=DEFAULT_RELOAD_SECONDS,
        help=f"with --plan: the assumed length of one reload (default {DEFAULT_RELOAD_SECONDS})",
    )
    parser.add_argument(
        "--dry-run",
        action="store_true",
        help="print what would be installed or removed, and change or download nothing",
    )
    return parser.parse_args(argv)


def main(argv: Sequence[str] | None = None) -> int:
    """Entry point for ``python3 -m tooling.bench.client_install``."""
    args = parse_args(argv)
    if args.plan is not None:
        entries = SMOKE_PROFILE if args.plan == "smoke" else all_profile(host_case_lists())
        print(plan(args.plan, entries, args.rounds, args.reload_seconds).describe())
        print(f"the estimate assumes {args.reload_seconds} s per reload; nothing was installed")
        return 0
    try:
        layout = client_install.resolve_layout(Path(args.wow_dir), args.flavour_dir)
        if args.remove:
            remove(layout, dry_run=args.dry_run)
        else:
            install(layout, lambda: ace3.fetch_ace3(args.cache), dry_run=args.dry_run)
    except (client_install.InstallError, BenchInstallError, ace3.FetchError) as failure:
        print(f"error: {failure}", file=sys.stderr)
        return 1
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
