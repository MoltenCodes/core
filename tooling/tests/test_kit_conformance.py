"""Tests for `tests/support/KitConformance.lua`, the shared Kit conformance suite.

A fixture Kit that keeps every convention (`tooling/tests/fixtures/conformance/`)
must pass the suite. Copies of it with one convention broken at a time must
fail exactly the case that names that convention, which proves each group
catches what it claims to. The suite runs under Busted, so these tests are
skipped where `busted` is not installed; CI's `test` job has it.
"""

from __future__ import annotations

import re
import os
import shutil
import subprocess
import tempfile
import unittest
from pathlib import Path

from tooling.validation.validate_manifests import ROOT

BUSTED = shutil.which("busted")
FIXTURE = ROOT / "tooling" / "tests" / "fixtures" / "conformance"
KIT = Path("packages") / "demoKit"

#: Each variant: (what is broken, file in the fixture, text, replacement, the
#: failing case's name begins with).
VARIANTS = (
    (
        "an unknown limit is accepted",
        KIT / "src" / "DemoKit.lua",
        "  validateLimitUpdate(limits, 3)\n",
        "",
        "limits: SetLimits refuses a non-table",
    ),
    (
        "a key is described with tostring",
        KIT / "src" / "DemoKit.lua",
        'local named = "DemoKit:SetLimits limits." .. describeKey(key)',
        'local named = "DemoKit:SetLimits limits." .. tostring(key)',
        "limits: SetLimits refuses a non-table",
    ),
    (
        "an argument error names a line inside the Kit",
        KIT / "src" / "DemoKit.lua",
        'error("DemoKit:Add name must not be a secret value", 2)',
        'error("DemoKit:Add name must not be a secret value", 1)',
        "arguments: Add name refuses a secret value",
    ),
    (
        "REVISION disagrees with the manifest",
        KIT / "package.manifest.json",
        '"revision": 2',
        '"revision": 3',
        "manifest: API and REVISION equal",
    ),
    (
        "the upgrade drops the older revision's state",
        KIT / "src" / "DemoKit.lua",
        "if previousRevision == nil or state == nil then",
        "if true then",
        "upgrade: an older revision's state survives",
    ),
    (
        "a limit is missing from docs/API.md",
        KIT / "docs" / "API.md",
        "| `maxItems` | 8 | 64 |",
        "| max items | 8 | 64 |",
        "limits: every limit is named in the Limits section",
    ),
    (
        "a method does not check its receiver",
        KIT / "src" / "DemoKit.lua",
        '  validateFacade(self, "DemoKit:Count", 3)\n',
        "",
        "receivers: every facade method",
    ),
    (
        "a missing dependency is not named",
        KIT / "src" / "DemoKit.lua",
        'error("MoltenCodes DemoKit requires Registry API 2 to be loaded first", 2)',
        'error("MoltenCodes DemoKit cannot load", 2)',
        "manifest: refuses to load without its dependency registry",
    ),
)


#: A TAP result line: `ok 3 - name`, `not ok 4 - name`, `ok 5 - # SKIP name` (pending).
TAP_LINE = re.compile(r"^(?P<outcome>ok|not ok) \d+ - (?P<skip># SKIP )?(?P<name>.*)$")

#: The `describe` block every case of the fixture's suite is named under.
SUITE_PREFIX = "DemoKit conformance "


def busted_results(root: Path, extra_environment: dict[str, str]) -> tuple[int, list[str], list[str], list[str]]:
    """Run the fixture's spec; return the status, failed, passed and pending case names.

    Busted's TAP output is read because its JSON output cannot encode a
    failure whose error value holds a function.
    """
    lua_path = ";".join(
        [
            str(root / KIT / "src" / "?.lua"),
            str(root / KIT / "tests" / "support" / "?.lua"),
            str(ROOT / "packages" / "registry" / "src" / "?.lua"),
            str(ROOT / "tests" / "support" / "?.lua"),
            "",
            "",
        ]
    )
    environment = dict(os.environ, LUA_PATH=lua_path, CONFORMANCE_FIXTURE_ROOT=str(root))
    environment.pop("MOLTENCODES_PREVIOUS_REVISION_DIR", None)
    environment.update(extra_environment)
    result = subprocess.run(
        [BUSTED, "--output=TAP", str(root / KIT / "tests")],
        cwd=ROOT,
        env=environment,
        capture_output=True,
        text=True,
        check=False,
    )
    failed: list[str] = []
    passed: list[str] = []
    pending: list[str] = []
    for line in result.stdout.splitlines():
        match = TAP_LINE.match(line)
        if match is None:
            continue
        name = match.group("name").removeprefix(SUITE_PREFIX)
        if match.group("skip"):
            pending.append(name)
        elif match.group("outcome") == "ok":
            passed.append(name)
        else:
            failed.append(name)
    return result.returncode, failed, passed, pending


def run_suite(root: Path) -> tuple[int, list[str], list[str]]:
    """Run the fixture's conformance spec under `root`; return status, failures and passes."""
    status, failed, passed, _ = busted_results(root, {})
    return status, failed, passed


@unittest.skipIf(BUSTED is None, "busted is not installed")
class KitConformanceTests(unittest.TestCase):
    def copy_fixture(self) -> Path:
        directory = tempfile.TemporaryDirectory()
        self.addCleanup(directory.cleanup)
        root = Path(directory.name) / "fixture"
        shutil.copytree(FIXTURE, root)
        return root

    def test_a_conforming_kit_passes_every_case(self):
        status, failed, passed = run_suite(self.copy_fixture())
        self.assertEqual([], failed)
        self.assertEqual(0, status)
        groups = {name.split(":", 1)[0] for name in passed}
        self.assertEqual({"manifest", "limits", "receivers", "arguments", "upgrade"}, groups)

    def test_each_broken_convention_fails_its_own_case(self):
        for description, relative, text, replacement, failing in VARIANTS:
            with self.subTest(description):
                root = self.copy_fixture()
                path = root / relative
                original = path.read_text(encoding="utf-8")
                self.assertIn(text, original, "the variant's text is in the fixture")
                path.write_text(original.replace(text, replacement, 1), encoding="utf-8")

                status, failed, _ = run_suite(root)

                self.assertNotEqual(0, status)
                self.assertTrue(
                    any(name.startswith(failing) for name in failed),
                    f"expected a failure starting {failing!r}; failed: {failed}",
                )

    def test_the_true_previous_revision_runs_when_provided(self):
        root = self.copy_fixture()
        previous = Path(tempfile.mkdtemp())
        self.addCleanup(shutil.rmtree, previous)
        source = (root / KIT / "src" / "DemoKit.lua").read_text(encoding="utf-8")
        (previous / "DemoKit.lua").write_text(
            source.replace("local IMPLEMENTATION_REVISION = 2", "local IMPLEMENTATION_REVISION = 1"),
            encoding="utf-8",
        )

        status, failed, passed, pending = busted_results(
            root, {"MOLTENCODES_PREVIOUS_REVISION_DIR": str(previous)}
        )

        self.assertEqual(0, status, failed)
        self.assertIn("upgrade: the committed revision 1's state survives the upgrade", passed)
        self.assertEqual([], pending)

    def test_without_a_previous_revision_its_case_is_pending_with_the_reason(self):
        _, _, _, pending = busted_results(self.copy_fixture(), {})
        self.assertEqual(1, len(pending))
        self.assertIn("checkout with history", pending[0])

if __name__ == "__main__":
    unittest.main()
