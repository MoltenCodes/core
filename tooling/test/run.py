from __future__ import annotations

"""Package-aware Busted orchestration for the monorepo."""

import argparse
import os
import shutil
import subprocess
import sys
from pathlib import Path
from typing import Any, Sequence

from tooling.validation.validate_manifests import load_manifests, validate_graph


ROOT = Path(__file__).resolve().parents[2]
PACKAGES = ROOT / "packages"
ManifestMap = dict[str, dict[str, Any]]


def load_valid_manifests() -> tuple[ManifestMap, list[str]]:
    """Load manifests and dependency-graph validation errors once per run."""
    manifests, errors = load_manifests()
    errors.extend(validate_graph(manifests))
    return manifests, errors


def select_test_packages(
    requested: Sequence[str], manifests: ManifestMap
) -> tuple[list[str], list[str]]:
    """Select package test targets, preserving explicit user order."""
    available = sorted(manifests)
    if not requested:
        return available, []

    unknown = sorted(set(requested) - set(manifests))
    if unknown:
        return [], [f'unknown package requested for testing: "{name}"' for name in unknown]

    selected: list[str] = []
    seen: set[str] = set()
    for name in requested:
        if name not in seen:
            selected.append(name)
            seen.add(name)
    return selected, []


def dependency_closure(package_name: str, manifests: ManifestMap) -> list[str]:
    """Return transitive runtime dependencies in dependency-first order, then the package."""
    resolved: list[str] = []
    seen: set[str] = set()

    def visit(name: str) -> None:
        if name in seen:
            return
        seen.add(name)
        dependencies = manifests[name].get("dependencies", {})
        if isinstance(dependencies, dict):
            for dependency in sorted(dependencies):
                if dependency in manifests:
                    visit(dependency)
        resolved.append(name)

    visit(package_name)
    return resolved


def build_lua_path(
    source_packages: Sequence[str],
    support_packages: Sequence[str],
    inherited: str | None = None,
) -> str:
    """Build Lua paths for runtime source and the current package's test support."""
    segments: list[str] = []

    for name in source_packages:
        package_dir = PACKAGES / name
        segments.extend(
            [
                str(package_dir / "src" / "?.lua"),
                str(package_dir / "src" / "?" / "init.lua"),
            ]
        )

    for name in support_packages:
        package_dir = PACKAGES / name
        segments.extend(
            [
                str(package_dir / "tests" / "support" / "?.lua"),
                str(package_dir / "tests" / "support" / "?" / "init.lua"),
            ]
        )

    if inherited:
        segments.append(inherited)
    else:
        # Lua expands a double separator to its compiled-in default path.
        segments.extend(["", ""])

    return ";".join(segments)


def package_test_target(package_name: str) -> tuple[str | None, str | None]:
    """Return the package test directory or an actionable structural error."""
    tests_dir = PACKAGES / package_name / "tests"
    specs = sorted(tests_dir.rglob("*_spec.lua")) if tests_dir.is_dir() else []
    if not specs:
        return None, f"packages/{package_name}/tests: no *_spec.lua tests were found"
    return str(tests_dir.relative_to(ROOT)), None


def run(package_names: Sequence[str], busted_args: Sequence[str] = ()) -> int:
    """Run each selected package suite in an isolated Busted process."""
    manifests, errors = load_valid_manifests()
    if errors:
        for message in errors:
            print(f"error: {message}", file=sys.stderr)
        return 2

    selected, selection_errors = select_test_packages(package_names, manifests)
    if selection_errors:
        for message in selection_errors:
            print(f"error: {message}", file=sys.stderr)
        return 2

    busted = shutil.which("busted")
    if busted is None:
        print(
            "error: Busted was not found on PATH; see docs/DEVELOPMENT.md for setup",
            file=sys.stderr,
        )
        return 127

    inherited_lua_path = os.environ.get("LUA_PATH")

    for package_name in selected:
        target, target_error = package_test_target(package_name)
        if target_error is not None:
            print(f"error: {target_error}", file=sys.stderr)
            return 2

        closure = dependency_closure(package_name, manifests)
        # Put the package under test first, then its dependencies. This makes
        # accidental module-name collisions deterministic in favor of the
        # package being tested while each package still runs in its own process.
        source_packages = [package_name, *(name for name in closure if name != package_name)]

        env = os.environ.copy()
        env["LUA_PATH"] = build_lua_path(
            source_packages,
            support_packages=[package_name],
            inherited=inherited_lua_path,
        )

        command = [busted, *busted_args, target]
        result = subprocess.run(command, cwd=ROOT, env=env, check=False)
        if result.returncode != 0:
            return result.returncode

    return 0


def parse_args(argv: Sequence[str] | None = None) -> argparse.Namespace:
    parser = argparse.ArgumentParser(
        description="Run Busted for all monorepo packages or a selected package subset."
    )
    parser.add_argument(
        "packages",
        nargs="*",
        help="package names to test; omitted means every discovered package",
    )
    parser.add_argument(
        "--busted-arg",
        action="append",
        default=[],
        help="extra argument forwarded to Busted; may be specified multiple times",
    )
    return parser.parse_args(argv)


def main(argv: Sequence[str] | None = None) -> int:
    args = parse_args(argv)
    return run(args.packages, args.busted_arg)


if __name__ == "__main__":
    raise SystemExit(main())
