"""Every `python3 -m tooling.*` command answers `--help` without doing its work.

`docs/TOOLING.md` documents each command by the line a contributor types. A
command that ignored `--help` would run instead of explaining itself, and
one whose usage line named the interpreter binary (`python3.14 -m ...`) would print a command that does not
exist on another machine. Commands are discovered, not listed, so a new one is
covered without editing this file.
"""

from __future__ import annotations

import subprocess
import sys
import unittest
from pathlib import Path


TOOLING = Path(__file__).resolve().parents[1]
ROOT = TOOLING.parent

#: The line that makes a module runnable with `python -m`.
MAIN_GUARD = 'if __name__ == "__main__":'


def command_modules() -> list[str]:
    """The dotted names of every tooling module with a `__main__` guard, tests excluded."""
    modules: list[str] = []
    for path in sorted(TOOLING.rglob("*.py")):
        relative = path.relative_to(ROOT)
        if "tests" in relative.parts:
            continue
        if MAIN_GUARD in path.read_text(encoding="utf-8"):
            modules.append(".".join(relative.with_suffix("").parts))
    return modules


class EntryPointTests(unittest.TestCase):
    def test_commands_are_discovered(self):
        modules = command_modules()

        self.assertIn("tooling.validation.validate_repository", modules)
        self.assertIn("tooling.lint", modules)

    def test_every_command_prints_its_usage_for_help(self):
        for module in command_modules():
            with self.subTest(module=module):
                result = subprocess.run(
                    [sys.executable, "-m", module, "--help"],
                    cwd=ROOT,
                    capture_output=True,
                    text=True,
                    check=False,
                    timeout=60,
                )
                self.assertEqual(0, result.returncode, result.stderr)
                self.assertTrue(
                    result.stdout.startswith(f"usage: python3 -m {module}"),
                    result.stdout[:200],
                )


if __name__ == "__main__":
    unittest.main()
