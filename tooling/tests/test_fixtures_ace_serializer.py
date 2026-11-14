"""Tests for the AceSerializer fixture recorder (`tooling/fixtures/ace_serializer.py`).

Nothing here downloads Ace3 or runs it: the recording itself is exercised by
running the command, which needs the pinned Ace3 source. These tests cover what
the command decides on its own: where the module goes, how the committed
recording date is read for `--check`, and that the committed module is the
generated one the specs load.
"""

from __future__ import annotations

import unittest

from tooling.fixtures import ace_serializer


class RecordedOnTests(unittest.TestCase):
    def test_reads_the_provenance_date(self):
        text = 'return {\n  provenance = {\n    recordedOn = "2026-11-15",\n  },\n}\n'
        self.assertEqual("2026-11-15", ace_serializer.recorded_on(text))

    def test_answers_none_without_a_date(self):
        self.assertIsNone(ace_serializer.recorded_on("return {}\n"))
        self.assertIsNone(ace_serializer.recorded_on('    recordedOn = "15 Nov",\n'))


class CommittedModuleTests(unittest.TestCase):
    def test_the_module_lives_where_the_specs_load_it(self):
        relative = ace_serializer.FIXTURE.relative_to(ace_serializer.ROOT).as_posix()
        self.assertEqual("packages/bridgeKit/tests/fixtures/AceSerializerFixtures.lua", relative)
        self.assertTrue(ace_serializer.RECORDER.is_file())

    def test_the_committed_module_is_generated_ascii_with_a_date(self):
        text = ace_serializer.FIXTURE.read_text(encoding="utf-8")
        self.assertTrue(text.startswith("-- AceSerializer-3.0 fixtures for bridgeKit. GENERATED FILE"))
        self.assertIsNotNone(ace_serializer.recorded_on(text))
        self.assertTrue(text.isascii())
        # The checkout path on the recording machine must never leak in.
        self.assertNotIn(".cache", text)
        self.assertNotIn(".lua:", text)


if __name__ == "__main__":
    unittest.main()
