"""Validate package manifests and the runtime dependency graph.

The package manifest is the canonical machine-readable metadata for every
publishable directory under ``packages/``. This validator intentionally keeps
its schema small and strict so typos and undeclared conventions fail early.
"""

from __future__ import annotations

import json
import re
import sys
from pathlib import Path
from typing import Any


ROOT = Path(__file__).resolve().parents[2]
PACKAGES = ROOT / "packages"
NAME_RE = re.compile(r"^[a-z][A-Za-z0-9]*$")
INFRASTRUCTURE_PACKAGE_NAMES = {"registry"}
PUBLIC_PACKAGE_SUFFIX = "Kit"
SEMVER_RE = re.compile(
    r"^(0|[1-9]\d*)\.(0|[1-9]\d*)\.(0|[1-9]\d*)"
    r"(?:-((?:0|[1-9]\d*|\d*[A-Za-z-][0-9A-Za-z-]*)"
    r"(?:\.(?:0|[1-9]\d*|\d*[A-Za-z-][0-9A-Za-z-]*))*))?"
    r"(?:\+([0-9A-Za-z-]+(?:\.[0-9A-Za-z-]+)*))?$"
)

REQUIRED = {"name", "displayName", "description", "version", "license", "dependencies"}
OPTIONAL = {"api", "revision"}
ALLOWED = REQUIRED | OPTIONAL

#: The repository ships under one licence, so a package declaring a different
#: one would contradict the LICENSE file that is packaged beside it.
REPOSITORY_LICENSE = "MIT"


def error(path: Path, message: str) -> str:
    """Format a repository-relative validation error when possible."""
    try:
        display_path = path.relative_to(ROOT)
    except ValueError:
        display_path = path
    return f"{display_path}: {message}"


def positive_integer(value: Any) -> bool:
    """Return whether ``value`` is a positive integer, excluding booleans."""
    return isinstance(value, int) and not isinstance(value, bool) and value > 0


def valid_dependency_contract(contract: Any) -> bool:
    """Return whether a dependency contract has the canonical ``{api}`` shape."""
    return (
        isinstance(contract, dict)
        and set(contract) == {"api"}
        and positive_integer(contract.get("api"))
    )


def package_directories() -> list[Path]:
    """Return visible package directories in deterministic order."""
    if not PACKAGES.is_dir():
        return []
    return sorted(
        path
        for path in PACKAGES.iterdir()
        if path.is_dir() and not path.name.startswith(".")
    )


def load_manifests() -> tuple[dict[str, dict[str, Any]], list[str]]:
    """Load and validate package manifest shapes.

    Every visible package directory must own ``package.manifest.json``. Valid
    manifests are returned even when unrelated manifests contain errors so the
    caller can report as many repository problems as possible in one run.
    """
    manifests: dict[str, dict[str, Any]] = {}
    errors: list[str] = []

    if not PACKAGES.is_dir():
        return {}, ["packages/: directory does not exist"]

    directories = package_directories()
    if not directories:
        return {}, ["packages/: no package directories were discovered"]

    paths: list[Path] = []
    for package_dir in directories:
        path = package_dir / "package.manifest.json"
        if not path.is_file():
            errors.append(error(package_dir, 'missing required file "package.manifest.json"'))
            continue
        paths.append(path)

    if not paths:
        return {}, errors or ["packages/: no package manifests were discovered"]

    for path in paths:
        try:
            data = json.loads(path.read_text(encoding="utf-8"))
        except OSError as exc:
            errors.append(error(path, f"unable to read manifest: {exc}"))
            continue
        except json.JSONDecodeError as exc:
            errors.append(error(path, f"invalid JSON: {exc.msg}"))
            continue

        if not isinstance(data, dict):
            errors.append(error(path, "top-level value must be an object"))
            continue

        missing = REQUIRED - data.keys()
        for field in sorted(missing):
            errors.append(error(path, f'missing required field "{field}"'))

        unknown = set(data) - ALLOWED
        for field in sorted(unknown):
            errors.append(error(path, f'unknown field "{field}"'))

        name = data.get("name")
        if not isinstance(name, str) or not NAME_RE.fullmatch(name):
            errors.append(error(path, '"name" must match ^[a-z][A-Za-z0-9]*$'))
        elif name != path.parent.name:
            errors.append(
                error(path, f'package name "{name}" does not match directory "{path.parent.name}"')
            )
        elif name not in INFRASTRUCTURE_PACKAGE_NAMES and not name.endswith(PUBLIC_PACKAGE_SUFFIX):
            errors.append(
                error(
                    path,
                    f'public package name "{name}" must end with "{PUBLIC_PACKAGE_SUFFIX}"',
                )
            )
        else:
            manifests[name] = data

        for field in ("displayName", "description"):
            value = data.get(field)
            if not isinstance(value, str) or not value.strip():
                errors.append(error(path, f'"{field}" must be a non-empty string'))

        version = data.get("version")
        if not isinstance(version, str) or not SEMVER_RE.fullmatch(version):
            errors.append(error(path, '"version" must be valid Semantic Versioning'))

        license_name = data.get("license")
        if not isinstance(license_name, str) or not license_name.strip():
            errors.append(error(path, '"license" must be a non-empty string'))
        elif license_name != REPOSITORY_LICENSE:
            errors.append(
                error(
                    path,
                    f'"license" must be "{REPOSITORY_LICENSE}" to match the repository LICENSE',
                )
            )

        api_present = "api" in data
        revision_present = "revision" in data
        if api_present != revision_present:
            errors.append(error(path, '"api" and "revision" must appear together'))
        if api_present and not positive_integer(data.get("api")):
            errors.append(error(path, '"api" must be a positive integer'))
        if revision_present and not positive_integer(data.get("revision")):
            errors.append(error(path, '"revision" must be a positive integer'))

        dependencies = data.get("dependencies")
        if not isinstance(dependencies, dict):
            errors.append(error(path, '"dependencies" must be an object'))
            continue

        for dep, contract in sorted(dependencies.items()):
            if not isinstance(dep, str) or not NAME_RE.fullmatch(dep):
                errors.append(error(path, f'invalid dependency name "{dep}"'))
                continue
            if not isinstance(contract, dict) or set(contract) != {"api"}:
                errors.append(error(path, f'dependency "{dep}" must contain exactly "api"'))
                continue
            if not positive_integer(contract.get("api")):
                errors.append(error(path, f"dependencies.{dep}.api must be positive"))

    return manifests, errors


def validate_graph(manifests: dict[str, dict[str, Any]]) -> list[str]:
    """Validate dependency existence, API contracts, self-edges, and cycles."""
    errors: list[str] = []

    for name, data in manifests.items():
        deps = data.get("dependencies", {})
        if not isinstance(deps, dict):
            continue

        for dep, contract in deps.items():
            path = PACKAGES / name / "package.manifest.json"

            # Shape/value errors are already reported by load_manifests(). Skip
            # them here so graph validation never crashes on malformed input.
            if not isinstance(dep, str) or not NAME_RE.fullmatch(dep):
                continue
            if not valid_dependency_contract(contract):
                continue

            if dep == name:
                errors.append(error(path, f'package "{name}" must not depend on itself'))
                continue

            dependency = manifests.get(dep)
            if dependency is None:
                errors.append(error(path, f'dependency "{dep}" does not exist'))
                continue

            required_api = contract["api"]
            exposed_api = dependency.get("api")
            if not positive_integer(exposed_api):
                errors.append(error(path, f'dependency "{dep}" does not expose an API generation'))
                continue

            if required_api != exposed_api:
                errors.append(
                    error(
                        path,
                        f'dependency "{dep}" requires API {required_api}, '
                        f"but exposes API {exposed_api}",
                    )
                )

    visiting: set[str] = set()
    visited: set[str] = set()
    stack: list[str] = []

    def visit(name: str) -> None:
        if name in visited:
            return
        if name in visiting:
            start = stack.index(name)
            cycle = stack[start:] + [name]
            errors.append(
                error(
                    PACKAGES / name / "package.manifest.json",
                    "dependency cycle detected: " + " -> ".join(cycle),
                )
            )
            return

        visiting.add(name)
        stack.append(name)
        deps = manifests[name].get("dependencies", {})
        if isinstance(deps, dict):
            for dep, contract in sorted(deps.items()):
                if dep != name and dep in manifests and valid_dependency_contract(contract):
                    visit(dep)
        stack.pop()
        visiting.remove(name)
        visited.add(name)

    for name in sorted(manifests):
        visit(name)

    return errors


def main() -> int:
    """Validate manifests and print a concise package summary."""
    manifests, errors = load_manifests()
    errors.extend(validate_graph(manifests))

    if errors:
        print(f"Manifest validation failed with {len(errors)} error(s):", file=sys.stderr)
        for item in errors:
            print(f"  - {item}", file=sys.stderr)
        return 1

    print(f"Manifest validation passed for {len(manifests)} package(s).")
    for name in sorted(manifests):
        data = manifests[name]
        runtime = ""
        if "api" in data:
            runtime = f" [API {data['api']}, Revision {data['revision']}]"
        print(f"  - {name} {data['version']} ({data['license']}){runtime}")

    return 0


if __name__ == "__main__":
    raise SystemExit(main())
