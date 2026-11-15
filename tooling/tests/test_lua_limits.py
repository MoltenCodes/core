"""Tests for the Lua limits gate (`tooling.validation.lua_limits`).

The calibration tests compile generated files with the real `luac`, so they
are skipped where Lua 5.1 is not installed; the CI `limits` job runs them
with the toolchain present.
"""

from __future__ import annotations

import contextlib
import io
import json
import shutil
import tempfile
import unittest
from pathlib import Path
from unittest import mock

from tooling.validation import lua_limits as module


LUAC = shutil.which("luac")


def file_limits(**measures) -> module.FileLimits:
    """A measured file with the given measures and harmless defaults."""
    values = {
        "path": "packages/aKit/src/AKit.lua",
        "main_locals": 10,
        "function_locals": 5,
        "function_locals_line": 12,
        "function_upvalues": 3,
        "function_upvalues_line": 20,
        "constants": 4,
    }
    values.update(measures)
    return module.FileLimits(**values)


def chunk_with_locals(count: int, with_for_loop: bool) -> str:
    """Lua source whose main chunk declares ``count`` locals, then optionally a numeric `for`."""
    lines = [f"local v{index} = {index}" for index in range(count)]
    if with_for_loop:
        # A numeric `for` adds three hidden control locals and the loop variable.
        lines.append("for index = 1, 2 do v0 = index end")
    lines.append("return v0")
    return "\n".join(lines) + "\n"


class PeakTests(unittest.TestCase):
    def test_overlapping_intervals(self):
        self.assertEqual(2, module.peak_active([(0, 10), (5, 15), (10, 20)]))

    def test_a_local_never_seen_alive_counts_once(self):
        self.assertEqual(2, module.peak_active([(3, 3), (0, 10)]))

    def test_an_ending_local_frees_its_slot_first(self):
        self.assertEqual(1, module.peak_active([(0, 5), (5, 9)]))


class ListingTests(unittest.TestCase):
    LISTING = """\
main <a.lua:0,0> (4 instructions, 16 bytes at 0x1)
0+ params, 3 slots, 0 upvalues, 2 locals, 1 constant, 1 function
constants (1) for 0x1:
\t1\t"x"
locals (2) for 0x1:
\t0\ta\t2\t5
\t1\tb\t3\t5
upvalues (0) for 0x1:

function <a.lua:3,6> (3 instructions, 12 bytes at 0x2)
0 params, 2 slots, 2 upvalues, 1 local, 0 constants, 0 functions
constants (0) for 0x2:
locals (1) for 0x2:
\t0\tc\t1\t3
upvalues (2) for 0x2:
\t0\ta
\t1\tb
"""

    def test_parses_every_function(self):
        functions = module.parse_listing(self.LISTING)

        self.assertEqual(
            [
                module.FunctionLimits(line=0, is_main=True, locals=2, upvalues=0, constants=1),
                module.FunctionLimits(line=3, is_main=False, locals=1, upvalues=2, constants=0),
            ],
            functions,
        )


class JudgeTests(unittest.TestCase):
    def test_a_small_file_passes(self):
        self.assertEqual([], module.judge(file_limits(), None))

    def test_warns_above_180_main_locals(self):
        findings = module.judge(file_limits(main_locals=185), None)

        self.assertEqual(["warning"], [finding.level for finding in findings])
        self.assertIn("5 left before the gate fails", findings[0].message)

    def test_fails_above_each_line(self):
        for measures in (
            {"main_locals": 191},
            {"function_locals": 191},
            {"function_upvalues": 51},
        ):
            with self.subTest(measures=measures):
                findings = module.judge(file_limits(**measures), None)
                self.assertEqual(["error"], [finding.level for finding in findings])

    def test_a_ratchet_entry_holds_the_value(self):
        self.assertEqual([], module.judge(file_limits(main_locals=198), {"mainLocals": 198}))

    def test_the_ratchet_refuses_growth(self):
        findings = module.judge(file_limits(main_locals=199), {"mainLocals": 198})

        self.assertIn("the ratchet only goes down (1 left", findings[0].message)

    def test_the_ratchet_asks_to_be_lowered(self):
        findings = module.judge(file_limits(main_locals=196), {"mainLocals": 198})

        self.assertIn("lower the entry", findings[0].message)

    def test_an_entry_under_the_line_is_stale(self):
        findings = module.judge(file_limits(main_locals=150), {"mainLocals": 198})

        self.assertIn("remove its mainLocals entry", findings[0].message)

    def test_names_the_function_line(self):
        findings = module.judge(file_limits(function_upvalues=55, function_upvalues_line=77), None)

        self.assertIn("packages/aKit/src/AKit.lua:77: function has 55 upvalues", findings[0].message)


class UpdateTests(unittest.TestCase):
    def test_lowers_and_drops_but_never_raises(self):
        ratchet = {
            "a.lua": {"mainLocals": 198},
            "b.lua": {"mainLocals": 196},
            "c.lua": {"mainLocals": 194},
        }
        measured = [
            file_limits(path="a.lua", main_locals=195),
            file_limits(path="b.lua", main_locals=150),
            file_limits(path="c.lua", main_locals=197),
        ]

        lowered, refusals = module.updated_ratchet(ratchet, measured)

        self.assertEqual({"a.lua": {"mainLocals": 195}, "c.lua": {"mainLocals": 194}}, lowered)
        self.assertEqual(["c.lua mainLocals: 197 is above the entry 194"], refusals)

    def test_ratchet_file_round_trip_and_shape(self):
        with tempfile.TemporaryDirectory() as directory:
            path = Path(directory) / "limits.json"
            module.write_ratchet(path, {"b": {"mainLocals": 191}, "a": {"functionUpvalues": 52}})

            self.assertEqual(["a", "b"], list(json.loads(path.read_text())["files"]))
            self.assertEqual({"a": {"functionUpvalues": 52}, "b": {"mainLocals": 191}}, module.load_ratchet(path))

            path.write_text('{"files": {"a": {"other": 1}}}', encoding="utf-8")
            with self.assertRaises(ValueError):
                module.load_ratchet(path)

    def test_the_committed_ratchet_is_valid_and_sorted(self):
        ratchet = module.load_ratchet(module.RATCHET_FILE)

        self.assertEqual(sorted(ratchet), list(ratchet))
        for entry in ratchet.values():
            for measure, value in entry.items():
                self.assertGreater(value, module.RATCHET_MEASURES[measure])
                self.assertLessEqual(value, module.COMPILER_LOCALS_LIMIT)


@unittest.skipIf(LUAC is None, "luac (Lua 5.1) is not installed")
class CompilerCalibrationTests(unittest.TestCase):
    """The measure agrees with the compiler: a file at the limit reports exactly 200."""

    def setUp(self):
        self.tempdir = tempfile.TemporaryDirectory()
        self.directory = Path(self.tempdir.name)

    def tearDown(self):
        self.tempdir.cleanup()

    def write(self, name: str, text: str) -> Path:
        path = self.directory / name
        path.write_text(text, encoding="utf-8")
        return path

    def test_a_file_at_the_limit_reports_200(self):
        path = self.write("at_limit.lua", chunk_with_locals(196, with_for_loop=True))

        self.assertEqual(200, module.measure_file(path, LUAC).main_locals)

    def test_one_more_local_does_not_compile(self):
        path = self.write("over_limit.lua", chunk_with_locals(197, with_for_loop=True))

        with self.assertRaises(RuntimeError):
            module.measure_file(path, LUAC)

    def test_upvalues_are_counted(self):
        names = [f"u{index}" for index in range(12)]
        source = (
            "\n".join(f"local {name} = 1" for name in names)
            + "\nlocal function sum() return "
            + " + ".join(names)
            + " end\nreturn sum\n"
        )

        limits = module.measure_file(self.write("upvalues.lua", source), LUAC)

        self.assertEqual(12, limits.function_upvalues)
        self.assertEqual(13, limits.main_locals)

    def test_the_repository_is_green(self):
        with contextlib.redirect_stdout(io.StringIO()), contextlib.redirect_stderr(io.StringIO()) as errors:
            status = module.main([])

        self.assertEqual(0, status, errors.getvalue())

    def test_a_named_file_over_the_line_fails(self):
        path = self.write("full.lua", chunk_with_locals(192, with_for_loop=False))

        with contextlib.redirect_stdout(io.StringIO()), contextlib.redirect_stderr(io.StringIO()) as errors:
            status = module.main([str(path)])

        self.assertEqual(1, status)
        self.assertIn("192 active locals, above the gate's 190", errors.getvalue())

    def test_missing_compiler(self):
        with mock.patch.object(module.shutil, "which", return_value=None):
            with contextlib.redirect_stderr(io.StringIO()) as errors:
                self.assertEqual(127, module.main([]))
        self.assertIn("luac was not found", errors.getvalue())


if __name__ == "__main__":
    unittest.main()
