"""Spell-check the repository's Markdown documentation with cspell.

cspell is a Node program, so this runner is a thin, deterministic wrapper: it
pins the cspell release, reads the file globs from `cspell.json` (the one place
they are written, and the file an editor extension reads too), and runs cspell
through `npx`. The project dictionary is `tooling/spell-words.txt`; the rule for
adding a word is at the top of that file and in `docs/TOOLING.md`.

Without a usable Node the check cannot run. Locally that is a note and exit
status 0, so a contributor without Node is not blocked by a gate CI runs anyway;
`--require` turns the same situation into a failure, which is what the CI job
passes so the gate can never be skipped silently there.
"""

from __future__ import annotations

import argparse
import json
import re
import shutil
import subprocess
import sys
from pathlib import Path
from typing import Sequence


ROOT = Path(__file__).resolve().parents[1]

#: The cspell configuration, relative to the repository root.
CONFIG_NAME = "cspell.json"

#: The pinned cspell release. Bump it deliberately, in its own change, and
#: check `MINIMUM_NODE` against the release's `engines.node` at the same time.
CSPELL_VERSION = "10.3.3"

#: The oldest Node the pinned cspell release supports (`engines.node`).
MINIMUM_NODE = (22, 18)

NODE_VERSION_RE = re.compile(r"^v?(\d+)\.(\d+)")


def configured_globs(root: Path | None = None) -> list[str]:
    """Return the file globs `cspell.json` declares under `files`."""
    config = json.loads(((root or ROOT) / CONFIG_NAME).read_text(encoding="utf-8"))
    globs = config.get("files") if isinstance(config, dict) else None
    if not isinstance(globs, list) or not all(isinstance(item, str) for item in globs):
        raise ValueError(f"{CONFIG_NAME}: `files` must be a list of glob strings")
    return globs


def parse_node_version(text: str) -> tuple[int, int] | None:
    """Parse `node --version` output (`v26.9.0`) into `(major, minor)`."""
    match = NODE_VERSION_RE.match(text.strip())
    if match is None:
        return None
    return int(match.group(1)), int(match.group(2))


def node_problem() -> str | None:
    """Explain why Node cannot run the pinned cspell, or return `None` if it can."""
    node = shutil.which("node")
    if node is None or shutil.which("npx") is None:
        return "Node.js (node and npx) was not found on PATH"

    result = subprocess.run([node, "--version"], capture_output=True, text=True, check=False)
    version = parse_node_version(result.stdout)
    if version is None:
        return f"could not read the Node.js version from {result.stdout.strip()!r}"
    if version < MINIMUM_NODE:
        return (
            f"Node.js {version[0]}.{version[1]} is older than {MINIMUM_NODE[0]}.{MINIMUM_NODE[1]}, "
            f"which cspell {CSPELL_VERSION} requires"
        )
    return None


def cspell_command(globs: Sequence[str]) -> list[str]:
    """The full command line that runs the pinned cspell over `globs`."""
    npx = shutil.which("npx") or "npx"
    return [
        npx,
        "--yes",
        f"cspell@{CSPELL_VERSION}",
        "lint",
        "--config",
        CONFIG_NAME,
        "--no-progress",
        "--show-suggestions",
        *globs,
    ]


def run(*, require: bool = False, root: Path | None = None) -> int:
    """Spell-check the configured files and return the process exit status."""
    root = root or ROOT
    try:
        globs = configured_globs(root)
    except (OSError, ValueError) as exc:
        print(f"error: {exc}", file=sys.stderr)
        return 2

    problem = node_problem()
    if problem is not None:
        if require:
            print(f"error: {problem}; the spell check cannot run", file=sys.stderr)
            return 127
        print(
            f"note: {problem}; skipping the spell check. CI runs it; see docs/TOOLING.md.",
            file=sys.stderr,
        )
        return 0

    return subprocess.run(cspell_command(globs), cwd=root, check=False).returncode


def main(argv: Sequence[str] | None = None) -> int:
    """Parse the command line and run the spell check; return the exit status."""
    parser = argparse.ArgumentParser(
        prog="python3 -m tooling.spell",
        description=f"Spell-check the documentation with cspell {CSPELL_VERSION}.",
    )
    parser.add_argument(
        "--require",
        action="store_true",
        help="fail instead of skipping when Node.js is missing or too old (used by CI)",
    )
    arguments = parser.parse_args(argv)
    return run(require=arguments.require)


if __name__ == "__main__":
    raise SystemExit(main())
