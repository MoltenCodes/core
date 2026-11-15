"""Tests for `tooling.shared.sync`, the shared helper blocks and their gate.

The marker, rewrite and check tests use a temporary repository. The behaviour
of the canonical Lua itself runs under host Lua 5.1
(`tooling/tests/fixtures/shared/behaviour.lua`); it is skipped where `lua` is
not installed, and the CI `limits` job, which builds Lua 5.1, runs it.
"""

from __future__ import annotations

import contextlib
import io
import json
import shutil
import subprocess
import tempfile
import unittest
from pathlib import Path

from tooling.shared import sync
from tooling.validation.validate_manifests import ROOT

LUA = shutil.which("lua")

SOURCE = """-- Shared helper: greet
--
-- shared revision: {revision}
-- shared requires: {requires}
-- shared parameters: __FACADE__
local __FACADE__ = {{}}
-- shared:body
local function greet()
  return "__FACADE__ says hello"
end
-- shared:exports
return {{ greet = greet }}
"""

BASE = """-- shared revision: 1
-- shared requires:
-- shared parameters:
-- shared:body
local function base()
  return 1
end
-- shared:exports
return { base = base }
"""


class SyncTests(unittest.TestCase):
    def setUp(self):
        directory = tempfile.TemporaryDirectory()
        self.addCleanup(directory.cleanup)
        self.root = Path(directory.name)
        (self.root / sync.SOURCES_PATH).mkdir(parents=True)
        self.write_source(revision=2, requires="base")
        (self.root / sync.SOURCES_PATH / "base.lua").write_text(BASE, encoding="utf-8")
        self.kit = self.root / "packages" / "fooKit" / "src" / "FooKit.lua"
        self.kit.parent.mkdir(parents=True)
        (self.root / "packages" / "fooKit" / "package.manifest.json").write_text(
            json.dumps({"displayName": "FooKit"}), encoding="utf-8"
        )

    def write_source(self, revision: int = 2, requires: str = "") -> None:
        text = SOURCE.format(revision=revision, requires=requires)
        (self.root / sync.SOURCES_PATH / "greet.lua").write_text(text, encoding="utf-8")

    def write_kit(self, text: str) -> None:
        self.kit.write_text(text, encoding="utf-8")

    def blocks(self, greet_body: str = "", revision: int = 2, indent: str = "") -> str:
        notice = sync.Source("greet", Path("x"), 1, (), (), ()).notice()
        base_notice = sync.Source("base", Path("x"), 1, (), (), ()).notice()
        return (
            "local FooKit = {}\n"
            f"{indent}-- shared:begin base 1\n{indent}{base_notice}\n"
            f"{indent}local function base()\n{indent}  return 1\n{indent}end\n"
            f"{indent}-- shared:end base\n"
            f"{indent}-- shared:begin greet {revision} __FACADE__=FooKit\n"
            f"{indent}{notice}\n"
            + (
                greet_body
                or f'{indent}local function greet()\n{indent}  return "FooKit says hello"\n{indent}end\n'
            )
            + f"{indent}-- shared:end greet\n"
            "return FooKit\n"
        )

    def check(self) -> list[str]:
        return sync.run_check(self.root)

    def test_a_current_block_passes(self):
        self.write_kit(self.blocks())
        self.assertEqual([], self.check())

    def test_a_kit_without_blocks_passes(self):
        self.write_kit("local FooKit = {}\nlocal function isSecret() end\nreturn FooKit\n")
        self.assertEqual([], self.check())

    def test_an_indented_block_is_indented_like_its_marker(self):
        self.write_kit("do\n" + self.blocks(indent="  ") + "end\n")
        self.assertEqual([], self.check())

    def test_a_hand_edit_fails_and_names_the_source(self):
        self.write_kit(self.blocks('local function greet()\n  return "edited"\nend\n'))
        problems = self.check()
        self.assertEqual(1, len(problems))
        self.assertIn("differs from tooling/shared/lua/greet.lua", problems[0])
        self.assertIn('return "FooKit says hello"', problems[0])

    def test_writing_repairs_a_hand_edit_and_raises_the_revision(self):
        self.write_kit(self.blocks('local function greet()\n  return "edited"\nend\n', revision=1))
        self.assertEqual([], sync.run_check(self.root, write=True))
        self.assertEqual(self.blocks(), self.kit.read_text(encoding="utf-8"))
        self.assertEqual([], self.check())

    def test_an_older_revision_fails_unless_pinned(self):
        self.write_kit(self.blocks(revision=1))
        problems = self.check()
        self.assertEqual(1, len(problems))
        self.assertIn("is at revision 1 but tooling/shared/lua/greet.lua is at 2", problems[0])

        (self.root / sync.PINS_PATH).write_text(
            json.dumps(
                {"pins": [{"package": "fooKit", "helper": "greet", "revision": 1, "reason": "kept"}]}
            ),
            encoding="utf-8",
        )
        self.assertEqual([], self.check())
        sync.run_check(self.root, write=True)
        self.assertIn("-- shared:begin greet 1", self.kit.read_text(encoding="utf-8"))

    def test_a_pin_needs_a_reason(self):
        (self.root / sync.PINS_PATH).write_text(
            json.dumps({"pins": [{"package": "fooKit", "helper": "greet", "revision": 1}]}),
            encoding="utf-8",
        )
        with self.assertRaisesRegex(sync.SyncError, "every pin needs a reason"):
            sync.load_pins(self.root)

    def test_a_required_block_must_come_first(self):
        text = self.blocks()
        greet_start = text.index("-- shared:begin greet")
        base_block = text[text.index("-- shared:begin base") : greet_start]
        reordered = text.replace(base_block, "")
        reordered = reordered.replace("return FooKit\n", base_block + "return FooKit\n")
        self.write_kit(reordered)
        problems = self.check()
        self.assertTrue(any("needs the base block earlier" in item for item in problems))

    def test_a_missing_or_unknown_parameter_fails(self):
        self.write_kit(self.blocks().replace(" __FACADE__=FooKit", ""))
        self.assertIn("needs __FACADE__=<value>", self.check()[0])
        self.write_kit(self.blocks().replace("__FACADE__=FooKit", "__FACADE__=FooKit __OTHER__=x"))
        self.assertIn("takes no parameter __OTHER__", self.check()[0])

    def test_an_unknown_helper_fails(self):
        self.write_kit("-- shared:begin nothing 1\n-- shared:end nothing\n")
        self.assertIn("unknown shared helper 'nothing'", self.check()[0])

    def test_malformed_markers_fail(self):
        self.write_kit("-- shared:begin greet 2 __FACADE__=FooKit\nlocal x = 1\n")
        self.assertIn("is never closed", self.check()[0])
        self.write_kit("-- shared:end greet\n")
        self.assertIn("without its begin marker", self.check()[0])
        self.write_kit("-- shared:begin greet two\n-- shared:end greet\n")
        self.assertIn("a begin marker is", self.check()[0])

    def test_a_source_over_the_column_budget_is_refused(self):
        long_line = "  return '" + "x" * 90 + "'"
        text = SOURCE.format(revision=1, requires="").replace(
            '  return "__FACADE__ says hello"', long_line
        )
        (self.root / sync.SOURCES_PATH / "greet.lua").write_text(text, encoding="utf-8")
        with self.assertRaisesRegex(sync.SyncError, "body lines are at most 90"):
            sync.load_sources(self.root)

    def test_a_source_must_mark_its_body(self):
        (self.root / sync.SOURCES_PATH / "greet.lua").write_text(
            "-- shared revision: 1\n", encoding="utf-8"
        )
        with self.assertRaisesRegex(sync.SyncError, "shared:body"):
            sync.load_sources(self.root)

    def test_the_migration_list_names_hand_written_helpers(self):
        self.write_kit(
            self.blocks()
            + "local function validateFacade(receiver, label, level)\nend\n"
            + "local function isSecretValue(value)\nend\n"
        )
        rows = sync.migration_list(self.root)
        self.assertEqual(2, len(rows))
        self.assertTrue(rows[0].startswith("fooKit: packages/fooKit/src/FooKit.lua:"))
        self.assertIn("validateFacade (compare)", rows[0])
        self.assertIn("isSecret (compare)", rows[1])

    def test_an_opt_out_leaves_a_helper_off_the_list(self):
        self.write_kit("local function describeKey(key)\nend\n")
        (self.root / sync.PINS_PATH).write_text(
            json.dumps(
                {"optOuts": [{"package": "fooKit", "helpers": ["describeKey"], "reason": "own"}]}
            ),
            encoding="utf-8",
        )
        self.assertEqual([], sync.migration_list(self.root))


class RepositoryTests(unittest.TestCase):
    def test_the_repository_passes_the_gate(self):
        self.assertEqual([], sync.run_check())

    def test_every_source_is_well_formed(self):
        sources = sync.load_sources()
        self.assertEqual(
            {"isSecret", "reportError", "describeKey", "validateFacade", "limits"}, set(sources)
        )
        self.assertEqual(("isSecret", "describeKey"), sources["limits"].requires)
        self.assertEqual(("__FACADE__",), sources["validateFacade"].parameters)

    def test_an_identical_hand_written_copy_is_recognised(self):
        source = sync.load_sources()["reportError"]
        copy = ["-- a comment", *source.body]
        self.assertTrue(sync.matches_source(source, copy, "FooKit"))

    def test_the_list_command_prints_a_count(self):
        with contextlib.redirect_stdout(io.StringIO()) as printed:
            self.assertEqual(0, sync.main(["--list"]))
        self.assertIn("hand-written helper(s) outside a shared block", printed.getvalue())


@unittest.skipIf(LUA is None, "lua (5.1) is not installed")
class CanonicalLuaTests(unittest.TestCase):
    def test_the_helpers_behave_as_documented(self):
        script = ROOT / "tooling" / "tests" / "fixtures" / "shared" / "behaviour.lua"
        result = subprocess.run(
            [LUA, str(script), str(ROOT / sync.SOURCES_PATH)],
            capture_output=True,
            text=True,
            check=False,
        )
        self.assertEqual(0, result.returncode, result.stderr)
        self.assertEqual("ok", result.stdout.strip())


if __name__ == "__main__":
    unittest.main()
