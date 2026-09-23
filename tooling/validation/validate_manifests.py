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
OPTIONAL = {"api", "revision", "optionalDependencies"}
ALLOWED = REQUIRED | OPTIONAL

#: The two dependency maps a manifest can carry. Both have the same shape,
#: ``{"<packageId>": {"api": <n>}}``. A required dependency is loaded before the
#: package and resolved at file scope; an optional one is found at call time
#: through ``Registry:Find`` and is never part of the load order or the bundle.
#: See docs/PACKAGE_MANIFEST.md.
DEPENDENCY_FIELDS = ("dependencies", "optionalDependencies")

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

        errors.extend(validate_optional_dependency_position(path, data))

        for field in DEPENDENCY_FIELDS:
            if field == "optionalDependencies" and field not in data:
                continue
            errors.extend(validate_dependency_map(path, field, data.get(field)))

    return manifests, errors


def validate_dependency_map(path: Path, field: str, value: Any) -> list[str]:
    """Validate the shape of one dependency map (`dependencies` or `optionalDependencies`).

    Both fields map a package ID to a contract of exactly ``{"api": <n>}``.
    Whether the named packages exist, and whether the graph they form is
    acyclic, is `validate_graph`'s job.
    """
    if not isinstance(value, dict):
        return [error(path, f'"{field}" must be an object')]

    label = dependency_label(field)
    errors: list[str] = []
    for dep, contract in sorted(value.items()):
        if not isinstance(dep, str) or not NAME_RE.fullmatch(dep):
            errors.append(error(path, f'invalid {label} name "{dep}"'))
            continue
        if not isinstance(contract, dict) or set(contract) != {"api"}:
            errors.append(error(path, f'{label} "{dep}" must contain exactly "api"'))
            continue
        if not positive_integer(contract.get("api")):
            errors.append(error(path, f"{field}.{dep}.api must be positive"))
    return errors


def dependency_label(field: str) -> str:
    """How error messages name one entry of a dependency map."""
    return "dependency" if field == "dependencies" else "optional dependency"


def validate_optional_dependency_position(path: Path, data: dict[str, Any]) -> list[str]:
    """Require `optionalDependencies` to come after the top-level `api` field.

    Every package's `tests/Manifest_spec.lua` reads its own API generation with
    the Lua pattern ``"api"%s*:%s*(%d+)``, which takes the *first* `"api"` in
    the file. An `optionalDependencies` object written above the top-level field
    would hand those specs a dependency's generation instead, so the order is a
    contract here rather than a style preference.
    """
    keys = list(data)
    if "optionalDependencies" in keys and "api" in keys:
        if keys.index("optionalDependencies") < keys.index("api"):
            return [
                error(
                    path,
                    '"optionalDependencies" must come after the top-level "api" field '
                    "(Manifest specs read the first \"api\" in the file)",
                )
            ]
    return []


def dependency_names(data: dict[str, Any], field: str) -> list[str]:
    """Return the well-formed package IDs one dependency map names, sorted.

    Malformed names and contracts are skipped: `load_manifests` has already
    reported them, and graph code must never crash on malformed input.
    """
    value = data.get(field, {})
    if not isinstance(value, dict):
        return []
    return sorted(
        dep
        for dep, contract in value.items()
        if isinstance(dep, str) and NAME_RE.fullmatch(dep) and valid_dependency_contract(contract)
    )


def validate_graph(manifests: dict[str, dict[str, Any]]) -> list[str]:
    """Validate dependency existence, API contracts, self-edges, and cycles.

    Required and optional dependencies are checked the same way: each must name
    an existing package that exposes the requested API generation, and neither
    may name the package itself. A package may not list the same dependency in
    both maps. Cycles are searched for in the combined graph, because an
    optional edge still means "this package calls into that one", and a cycle
    through it makes the two impossible to reason about or test in isolation.
    """
    errors: list[str] = []

    for name, data in manifests.items():
        path = PACKAGES / name / "package.manifest.json"
        required = set(dependency_names(data, "dependencies"))

        for field in DEPENDENCY_FIELDS:
            label = dependency_label(field)
            contracts = data.get(field, {})
            for dep in dependency_names(data, field):
                if dep == name:
                    errors.append(error(path, f'package "{name}" must not {_depend_verb(field)} itself'))
                    continue

                if field == "optionalDependencies" and dep in required:
                    errors.append(
                        error(
                            path,
                            f'"{dep}" is listed in both "dependencies" and '
                            '"optionalDependencies"; keep only one',
                        )
                    )
                    continue

                dependency = manifests.get(dep)
                if dependency is None:
                    errors.append(error(path, f'{label} "{dep}" does not exist'))
                    continue

                required_api = contracts[dep]["api"]
                exposed_api = dependency.get("api")
                if not positive_integer(exposed_api):
                    errors.append(error(path, f'{label} "{dep}" does not expose an API generation'))
                    continue

                if required_api != exposed_api:
                    errors.append(
                        error(
                            path,
                            f'{label} "{dep}" requires API {required_api}, '
                            f"but exposes API {exposed_api}",
                        )
                    )

    errors.extend(_find_cycles(manifests))
    return errors


def _depend_verb(field: str) -> str:
    """The verb a self-dependency error uses for one dependency map."""
    return "depend on" if field == "dependencies" else "optionally depend on"


def _find_cycles(manifests: dict[str, dict[str, Any]]) -> list[str]:
    """Report every cycle in the graph of required and optional dependencies."""
    errors: list[str] = []
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
        edges = sorted(
            {dep for field in DEPENDENCY_FIELDS for dep in dependency_names(manifests[name], field)}
        )
        for dep in edges:
            if dep != name and dep in manifests:
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
