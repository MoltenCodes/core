"""Package-aware Busted orchestration for the monorepo.

Every selected package runs in its own Busted process with its own ``LUA_PATH``
so that packages cannot see each other's package-owned test support. The shared
fixture under ``tests/support/`` is on every target's path, because it is
repository test scaffolding rather than any one package's.

``examples`` is a target beside the packages: the example addon is the
documented embedding instructions, so it is exercised by the same command
rather than by a second one that CI could forget.

The runner always executes every selected target, then prints one summary table,
so a single failing target can never hide the state of the targets behind it.
"""

from __future__ import annotations

import argparse
import os
import re
import shutil
import subprocess
import sys
from pathlib import Path
from typing import Any, NamedTuple, Sequence

from tooling.validation.validate_manifests import load_manifests, validate_graph


ROOT = Path(__file__).resolve().parents[2]
PACKAGES = ROOT / "packages"

#: Test support shared by every package suite. It carries the World of Warcraft
#: stubs, the ``package.loaded`` bookkeeping and the error capture that used to
#: be copied into each ``packages/*/tests/support`` directory. It is repository
#: test scaffolding rather than package-owned code, so it is never published
#: with a package and never reachable from runtime source.
SHARED_SUPPORT = ROOT / "tests" / "support"

#: Example-addon specs run from the repository root, outside any package. They
#: are a test target rather than a package: the example loads framework sources
#: with ``loadfile`` the way a World of Warcraft ``.toc`` does, so it needs every
#: package's source on its Lua path and has no manifest of its own.
EXAMPLES_TARGET = "examples"
EXAMPLES_TESTS = ROOT / "examples" / "tests"

ManifestMap = dict[str, dict[str, Any]]

#: Busted's final line, for example ``48 successes / 0 failures / 0 errors / 0 pending``.
#: Busted uses singular nouns when a count is one, so every noun is optional-plural.
SUMMARY_PATTERN = re.compile(
    r"(\d+)\s+success(?:es)?\s*/\s*"
    r"(\d+)\s+failure(?:s)?\s*/\s*"
    r"(\d+)\s+error(?:s)?\s*/\s*"
    r"(\d+)\s+pending",
    re.IGNORECASE,
)

#: Busted colours its terminal output even when stdout is a pipe.
ANSI_PATTERN = re.compile(r"\x1b\[[0-9;]*m")

MISSING_BUSTED_MESSAGE = """\
error: Busted was not found on PATH.

Busted runs on Lua 5.1 because that is the World of Warcraft client runtime.
Homebrew does not package Lua 5.1, so install a private interpreter, for example:

    pipx install hererocks
    hererocks ~/.local/lua51 --lua 5.1.5 --luarocks latest
    export PATH="$HOME/.local/lua51/bin:$PATH"
    luarocks install busted 2.3.0-1

See docs/DEVELOPMENT.md for the full toolchain, including the versions CI pins.\
"""


class PackageOutcome(NamedTuple):
    """One package's Busted result, with counts when its summary line was parsed."""

    package_name: str
    return_code: int
    successes: int | None
    failures: int | None
    errors: int | None
    pending: int | None

    @property
    def passed(self) -> bool:
        """Whether Busted reported success for this package."""
        return self.return_code == 0


def load_valid_manifests() -> tuple[ManifestMap, list[str]]:
    """Load manifests and dependency-graph validation errors once per run."""
    manifests, errors = load_manifests()
    errors.extend(validate_graph(manifests))
    return manifests, errors


def select_test_packages(
    requested: Sequence[str], manifests: ManifestMap
) -> tuple[list[str], list[str]]:
    """Select test targets, preserving explicit user order.

    ``examples`` is a valid target alongside the manifest-discovered packages,
    so the local command and CI run exactly the same set.
    """
    available = [*sorted(manifests), EXAMPLES_TARGET]
    if not requested:
        return available, []

    unknown = sorted(set(requested) - set(manifests) - {EXAMPLES_TARGET})
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
    """Build Lua paths for runtime source, shared and per-package test support."""
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

    # The shared fixture comes last of the support entries, so a package that
    # needs to shadow one of its modules can do so from its own support
    # directory without editing the runner.
    segments.extend(
        [
            str(SHARED_SUPPORT / "?.lua"),
            str(SHARED_SUPPORT / "?" / "init.lua"),
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


def parse_busted_summary(output: str) -> tuple[int, int, int, int] | None:
    """Return Busted's success/failure/error/pending counts, or None when absent.

    Parsing is best-effort by design: a missing or reformatted summary line must
    never turn a passing suite into a runner failure, so callers fall back to the
    process exit status.
    """
    matches = SUMMARY_PATTERN.findall(ANSI_PATTERN.sub("", output))
    if not matches:
        return None
    successes, failures, errors, pending = matches[-1]
    return int(successes), int(failures), int(errors), int(pending)


def run_package_suite(
    package_name: str,
    manifests: ManifestMap,
    busted: str,
    busted_args: Sequence[str],
    inherited_lua_path: str | None,
) -> PackageOutcome:
    """Run one package's specs in an isolated Busted process and echo its output."""
    target, target_error = package_test_target(package_name)
    if target_error is not None:
        print(f"error: {target_error}", file=sys.stderr)
        return PackageOutcome(package_name, 2, None, None, None, None)

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
    # Output is captured rather than streamed so the summary line can be parsed.
    # Package suites are short, and the captured text is echoed immediately.
    result = subprocess.run(
        command, cwd=ROOT, env=env, check=False, capture_output=True, text=True
    )

    print(f"==> {package_name}")
    stdout = getattr(result, "stdout", "") or ""
    stderr = getattr(result, "stderr", "") or ""
    if stdout:
        sys.stdout.write(stdout if stdout.endswith("\n") else stdout + "\n")
    if stderr:
        sys.stderr.write(stderr if stderr.endswith("\n") else stderr + "\n")

    counts = parse_busted_summary(stdout + stderr)
    if counts is None:
        return PackageOutcome(package_name, result.returncode, None, None, None, None)
    return PackageOutcome(package_name, result.returncode, *counts)


def run_examples_suite(
    manifests: ManifestMap,
    busted: str,
    busted_args: Sequence[str],
    inherited_lua_path: str | None,
) -> PackageOutcome:
    """Run the example-addon specs with every package's source on the Lua path."""
    specs = sorted(EXAMPLES_TESTS.rglob("*_spec.lua")) if EXAMPLES_TESTS.is_dir() else []
    if not specs:
        print(f"error: {EXAMPLES_TARGET}/tests: no *_spec.lua tests were found", file=sys.stderr)
        return PackageOutcome(EXAMPLES_TARGET, 2, None, None, None, None)

    env = os.environ.copy()
    env["LUA_PATH"] = build_lua_path(
        sorted(manifests),
        support_packages=(),
        inherited=inherited_lua_path,
    )

    command = [busted, *busted_args, str(EXAMPLES_TESTS.relative_to(ROOT))]
    result = subprocess.run(
        command, cwd=ROOT, env=env, check=False, capture_output=True, text=True
    )

    print(f"==> {EXAMPLES_TARGET}")
    stdout = getattr(result, "stdout", "") or ""
    stderr = getattr(result, "stderr", "") or ""
    if stdout:
        sys.stdout.write(stdout if stdout.endswith("\n") else stdout + "\n")
    if stderr:
        sys.stderr.write(stderr if stderr.endswith("\n") else stderr + "\n")

    counts = parse_busted_summary(stdout + stderr)
    if counts is None:
        return PackageOutcome(EXAMPLES_TARGET, result.returncode, None, None, None, None)
    return PackageOutcome(EXAMPLES_TARGET, result.returncode, *counts)


def format_summary_table(outcomes: Sequence[PackageOutcome]) -> str:
    """Render the per-package result table, including a totals row."""
    headers = ("package", "successes", "failures", "errors", "pending", "status")

    def cell(value: int | None) -> str:
        return "-" if value is None else str(value)

    rows = [
        (
            outcome.package_name,
            cell(outcome.successes),
            cell(outcome.failures),
            cell(outcome.errors),
            cell(outcome.pending),
            "ok" if outcome.passed else "FAILED",
        )
        for outcome in outcomes
    ]

    def total(attribute: str) -> str:
        values = [getattr(outcome, attribute) for outcome in outcomes]
        known = [value for value in values if value is not None]
        if not known:
            return "-"
        suffix = "+" if len(known) != len(values) else ""
        return f"{sum(known)}{suffix}"

    rows.append(
        (
            "total",
            total("successes"),
            total("failures"),
            total("errors"),
            total("pending"),
            "ok" if all(outcome.passed for outcome in outcomes) else "FAILED",
        )
    )

    widths = [
        max(len(header), *(len(row[index]) for row in rows))
        for index, header in enumerate(headers)
    ]

    def render(values: Sequence[str]) -> str:
        left = values[0].ljust(widths[0])
        middle = "  ".join(
            values[index].rjust(widths[index]) for index in range(1, len(widths) - 1)
        )
        right = values[-1].ljust(widths[-1])
        return f"{left}  {middle}  {right}".rstrip()

    separator = "  ".join("-" * width for width in widths)
    lines = [render(headers), separator]
    lines.extend(render(row) for row in rows[:-1])
    lines.append(separator)
    lines.append(render(rows[-1]))
    return "\n".join(lines)


def run(package_names: Sequence[str], busted_args: Sequence[str] = ()) -> int:
    """Run every selected suite, then report the aggregate result."""
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
        print(MISSING_BUSTED_MESSAGE, file=sys.stderr)
        return 127

    inherited_lua_path = os.environ.get("LUA_PATH")

    outcomes = [
        (
            run_examples_suite(manifests, busted, busted_args, inherited_lua_path)
            if name == EXAMPLES_TARGET
            else run_package_suite(name, manifests, busted, busted_args, inherited_lua_path)
        )
        for name in selected
    ]

    print()
    print(format_summary_table(outcomes))

    failed = [outcome.package_name for outcome in outcomes if not outcome.passed]
    if failed:
        print(f"\nfailed targets: {', '.join(failed)}", file=sys.stderr)
        return 1
    return 0


def parse_args(argv: Sequence[str] | None = None) -> argparse.Namespace:
    """Parse the runner's command line."""
    parser = argparse.ArgumentParser(
        description="Run Busted for every monorepo test target or a selected subset."
    )
    parser.add_argument(
        "packages",
        nargs="*",
        help=(
            'test targets; a package name or "examples". '
            "Omitted means every discovered package and the examples"
        ),
    )
    parser.add_argument(
        "--busted-arg",
        action="append",
        default=[],
        help="extra argument forwarded to Busted; may be specified multiple times",
    )
    return parser.parse_args(argv)


def main(argv: Sequence[str] | None = None) -> int:
    """Entry point for ``python3 -m tooling.test.run``."""
    args = parse_args(argv)
    return run(args.packages, args.busted_arg)


if __name__ == "__main__":
    raise SystemExit(main())
