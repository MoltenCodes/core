from __future__ import annotations

import shutil
import subprocess
import sys
from pathlib import Path
from typing import Sequence


ROOT = Path(__file__).resolve().parents[1]
PACKAGES = ROOT / "packages"


def discover_runtime_lua_files() -> list[Path]:
    """Return every runtime Lua source file in deterministic order."""
    return sorted(path for path in PACKAGES.glob("*/src/**/*.lua") if path.is_file())


def run(extra_args: Sequence[str] = ()) -> int:
    """Run Selene against all runtime Lua source files."""
    files = discover_runtime_lua_files()
    if not files:
        print("error: no runtime Lua source files were discovered", file=sys.stderr)
        return 2

    selene = shutil.which("selene")
    if selene is None:
        print(
            "error: Selene was not found on PATH; see docs/DEVELOPMENT.md for setup",
            file=sys.stderr,
        )
        return 127

    command = [selene, *extra_args, *(str(path.relative_to(ROOT)) for path in files)]
    return subprocess.run(command, cwd=ROOT, check=False).returncode


def main() -> int:
    return run()


if __name__ == "__main__":
    raise SystemExit(main())
