"""Run Selene over every Lua file in the repository, runtime and test alike.

Runtime source and test code are linted with the same rules but against
different standard libraries. Busted injects `describe`, `it` and luassert's
`assert` into spec chunks as globals, so test code needs the `busted.yml`
standard library selected by `selene-tests.toml`; runtime source keeps the
stricter default in `selene.toml`, where a Busted global really is undefined.

Both passes run even when the first one fails, so one broken scope can never
hide the state of the other.
"""

from __future__ import annotations

import argparse
import shutil
import subprocess
import sys
from pathlib import Path
from typing import NamedTuple, Sequence


ROOT = Path(__file__).resolve().parents[1]
PACKAGES = ROOT / "packages"
EXAMPLES = ROOT / "examples"
SHARED_TEST_SUPPORT = ROOT / "tests" / "support"

#: Selene configuration for test code: the Lua 5.1 library plus Busted's globals.
TEST_CONFIG = "selene-tests.toml"


class LintScope(NamedTuple):
    """One Selene invocation: a set of files and the configuration to judge them by."""

    name: str
    files: list[Path]
    config: str | None

    def command_arguments(self) -> list[str]:
        """Selene arguments for this scope, repository-relative for readable output."""
        arguments: list[str] = []
        if self.config is not None:
            arguments.extend(["--config", self.config])
        arguments.extend(str(path.relative_to(ROOT)) for path in self.files)
        return arguments


def discover_runtime_lua_files() -> list[Path]:
    """Return every runtime Lua file in deterministic order.

    That is each package's `src/` tree, each package's `fidelity/` tree (a
    suite that runs in the game client) and the example addon's own source. The
    example is addon code rather than test code, so it is held to the runtime
    standard library: a Busted global there would be a real defect.
    """
    discovered = [path for path in PACKAGES.glob("*/src/**/*.lua") if path.is_file()]
    # A fidelity suite runs inside the game client, not under Busted, so it is
    # runtime code and is held to the runtime standard library.
    discovered.extend(path for path in PACKAGES.glob("*/fidelity/**/*.lua") if path.is_file())
    # The example addon's own source may be nested (`Locales/enUS.lua`); its
    # specs under `examples/tests/` are test code and belong to the other scope.
    example_tests = EXAMPLES / "tests"
    discovered.extend(
        path
        for path in EXAMPLES.rglob("*.lua")
        if path.is_file()
        and not path.name.endswith("_spec.lua")
        and not path.is_relative_to(example_tests)
    )
    return sorted(set(discovered))


def discover_test_lua_files() -> list[Path]:
    """Return every test Lua file in deterministic order.

    That is each package's own `tests/` tree, the example addon's specs, and the
    shared fixture the whole suite is built on.
    """
    discovered = [path for path in PACKAGES.glob("*/tests/**/*.lua") if path.is_file()]
    discovered.extend(path for path in (EXAMPLES / "tests").glob("**/*.lua") if path.is_file())
    discovered.extend(path for path in SHARED_TEST_SUPPORT.glob("**/*.lua") if path.is_file())
    return sorted(set(discovered))


def discover_scopes() -> tuple[list[LintScope], list[str]]:
    """Build both lint scopes, reporting any that discovered no files at all."""
    scopes = [
        LintScope("runtime Lua", discover_runtime_lua_files(), None),
        LintScope("test Lua", discover_test_lua_files(), TEST_CONFIG),
    ]
    errors = [f"no {scope.name} files were discovered" for scope in scopes if not scope.files]
    return scopes, errors


def run(extra_args: Sequence[str] = ()) -> int:
    """Lint every scope and return the first non-zero Selene exit status."""
    scopes, errors = discover_scopes()
    if errors:
        for message in errors:
            print(f"error: {message}", file=sys.stderr)
        return 2

    selene = shutil.which("selene")
    if selene is None:
        print(
            "error: Selene was not found on PATH; see docs/DEVELOPMENT.md for setup",
            file=sys.stderr,
        )
        return 127

    status = 0
    for scope in scopes:
        # Flushed so the heading lands above Selene's own output, which the
        # child process writes straight to this process's stdout.
        print(f"==> {scope.name}", flush=True)
        command = [selene, *extra_args, *scope.command_arguments()]
        returncode = subprocess.run(command, cwd=ROOT, check=False).returncode
        if returncode != 0 and status == 0:
            status = returncode
    return status


def parse_args(argv: Sequence[str] | None = None) -> argparse.Namespace:
    """Parse the command line; the linter takes no options beyond `--help`."""
    parser = argparse.ArgumentParser(
        prog="python3 -m tooling.lint",
        description=(
            "Run Selene over runtime Lua (selene.toml) and test Lua "
            "(selene-tests.toml); both scopes always run."
        ),
    )
    return parser.parse_args(argv)


def main(argv: Sequence[str] | None = None) -> int:
    """Lint both scopes and return the first non-zero Selene exit status."""
    parse_args(argv)
    return run()


if __name__ == "__main__":
    raise SystemExit(main())
