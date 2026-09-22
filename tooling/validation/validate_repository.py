from __future__ import annotations

"""Validate repository structure, documentation navigation, and package layout."""

import json
import re
import sys
from pathlib import Path
from urllib.parse import unquote

from tooling.validation.validate_manifests import (
    ROOT,
    error,
    load_manifests,
    package_directories,
    validate_graph,
)


REQUIRED_ROOT_FILES = (
    Path("README.md"),
    Path("LICENSE"),
    Path("docs/README.md"),
    Path("docs/ARCHITECTURE.md"),
    Path("docs/CONTRIBUTING.md"),
    Path("docs/DESIGN_CONSTITUTION.md"),
    Path("docs/DEVELOPMENT.md"),
    Path("docs/PACKAGE_MANIFEST.md"),
    Path("docs/RELEASES.md"),
    Path("docs/TESTING.md"),
    Path("docs/TOOLING.md"),
)

PACKAGE_REQUIRED_FILES = (
    Path("README.md"),
    Path("CHANGELOG.md"),
    Path("package.manifest.json"),
)

MARKDOWN_LINK_RE = re.compile(r"!?\[[^\]]*\]\(([^)]+)\)")
IGNORED_DIRECTORY_NAMES = {
    ".git",
    ".luarocks",
    ".mypy_cache",
    ".pytest_cache",
    ".ruff_cache",
    ".venv",
    "__pycache__",
    "build",
    "coverage",
    "dist",
    "htmlcov",
    "reports",
    "venv",
}


def validate_required_root_files() -> list[str]:
    """Check that the repository's documented navigation surface exists."""
    errors: list[str] = []
    for relative in REQUIRED_ROOT_FILES:
        path = ROOT / relative
        if not path.is_file():
            errors.append(error(path, "required repository file is missing"))
    return errors


def validate_package_layout() -> list[str]:
    """Check the minimum self-contained layout of every publishable package."""
    errors: list[str] = []

    for package_dir in package_directories():
        for relative in PACKAGE_REQUIRED_FILES:
            path = package_dir / relative
            if not path.is_file():
                errors.append(error(path, "required package file is missing"))

        source_dir = package_dir / "src"
        if not source_dir.is_dir():
            errors.append(error(source_dir, "required package source directory is missing"))
        elif not any(source_dir.rglob("*.lua")):
            errors.append(error(source_dir, "no Lua source files were found"))

        tests_dir = package_dir / "tests"
        if not tests_dir.is_dir():
            errors.append(error(tests_dir, "required package tests directory is missing"))
        elif not any(tests_dir.rglob("*_spec.lua")):
            errors.append(error(tests_dir, "no Busted *_spec.lua tests were found"))

        manifest_path = package_dir / "package.manifest.json"
        if manifest_path.is_file():
            try:
                manifest = json.loads(manifest_path.read_text(encoding="utf-8"))
            except (OSError, json.JSONDecodeError):
                manifest = None

            if isinstance(manifest, dict) and "api" in manifest:
                api_doc = package_dir / "docs" / "API.md"
                if not api_doc.is_file():
                    errors.append(error(api_doc, "API package is missing docs/API.md"))

    return errors


def _is_external_link(target: str) -> bool:
    lowered = target.lower()
    return (
        "://" in target
        or lowered.startswith("mailto:")
        or lowered.startswith("tel:")
        or target.startswith("#")
    )


def validate_markdown_links() -> list[str]:
    """Validate repository-relative file targets in Markdown links and images."""
    errors: list[str] = []

    for markdown in sorted(ROOT.rglob("*.md")):
        # Generated and local-environment trees are not source documentation.
        if any(part in IGNORED_DIRECTORY_NAMES for part in markdown.parts):
            continue

        try:
            text = markdown.read_text(encoding="utf-8")
        except OSError as exc:
            errors.append(error(markdown, f"unable to read Markdown: {exc}"))
            continue

        for match in MARKDOWN_LINK_RE.finditer(text):
            raw_target = match.group(1).strip()
            if not raw_target or _is_external_link(raw_target):
                continue

            # Markdown titles after a URL are intentionally not supported in
            # repository-relative links; keeping links simple improves tooling.
            target = unquote(raw_target.split("#", 1)[0])
            target_path = (markdown.parent / target).resolve()
            if not target_path.is_relative_to(ROOT.resolve()):
                errors.append(error(markdown, f'relative link escapes repository "{raw_target}"'))
            elif not target_path.exists():
                errors.append(error(markdown, f'broken relative link target "{raw_target}"'))

    return errors


def validate_repository() -> tuple[dict[str, dict[str, object]], list[str]]:
    """Run all repository checks and return loaded package manifests plus errors."""
    manifests, errors = load_manifests()
    errors.extend(validate_graph(manifests))
    errors.extend(validate_required_root_files())
    errors.extend(validate_package_layout())
    errors.extend(validate_markdown_links())
    return manifests, errors


def main() -> int:
    manifests, errors = validate_repository()

    if errors:
        print(f"Repository validation failed with {len(errors)} error(s):", file=sys.stderr)
        for item in errors:
            print(f"  - {item}", file=sys.stderr)
        return 1

    print(f"Repository validation passed for {len(manifests)} package(s).")
    for name in sorted(manifests):
        print(f"  - {name}")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
