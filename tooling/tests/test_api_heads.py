"""Tests for the mirror-head comparison, `tooling.api.heads`.

The mirror is the in-memory `FakeTransport` from the fetch tests and the
committed metadata is a temporary `metadata/<flavour>/provenance.json`, so
nothing here touches the network or the committed apiKit package.
"""

from __future__ import annotations

import io
import json
import tempfile
import unittest
from contextlib import redirect_stderr, redirect_stdout
from pathlib import Path

from tooling.api import flavours, model
from tooling.api import heads as module
from tooling.tests.test_api_fetch import (
    FLAVOUR_TABLE,
    LIVE_COMMIT,
    PTR2_COMMIT,
    PTR_COMMIT,
    REPOSITORY,
    FakeTransport,
    commit_response,
    commit_url,
)


def provenance(flavour: str, branch: str, build: int | None) -> dict:
    """A committed provenance document with only the fields that matter here varied."""
    return {
        "branch": branch,
        "build": build,
        "capturedOn": "2026-09-24",
        "commit": "d" * 40,
        "committedAt": "2026-09-20T12:00:00Z",
        "documentationPath": "Interface/AddOns/Blizzard_APIDocumentationGenerated",
        "fileCount": 612,
        "flavour": flavour,
        "repository": REPOSITORY,
        "schema": model.SCHEMA_VERSION,
        "subject": f"12.1.0 ({build})",
        "version": "12.1.0",
    }


class HeadsTests(unittest.TestCase):
    def setUp(self):
        self.tempdir = tempfile.TemporaryDirectory()
        self.package = Path(self.tempdir.name) / "apiKit"
        self.table = flavours.parse_flavours(FLAVOUR_TABLE)
        self.write_provenance("retail", "live", 69933)
        self.write_provenance("ptr", "ptr2", 69952)
        self.transport = FakeTransport(
            {
                commit_url("live"): commit_response(LIVE_COMMIT, "12.1.0 (69933)"),
                commit_url("ptr"): commit_response(PTR_COMMIT, "12.1.0 (69587)"),
                commit_url("ptr2"): commit_response(PTR2_COMMIT, "12.1.5 (69952)"),
            }
        )

    def tearDown(self):
        self.tempdir.cleanup()

    def write_provenance(self, flavour: str, branch: str, build: int | None) -> None:
        directory = self.package / "metadata" / flavour
        directory.mkdir(parents=True, exist_ok=True)
        (directory / model.PROVENANCE_FILE).write_text(
            json.dumps(provenance(flavour, branch, build)), encoding="utf-8"
        )

    def run_main(self, *arguments: str) -> tuple[int, str, str]:
        stdout, stderr = io.StringIO(), io.StringIO()
        with redirect_stdout(stdout), redirect_stderr(stderr):
            status = module.main(
                list(arguments),
                transport=self.transport,
                flavours_table=self.table,
                package_directory=self.package,
            )
        return status, stdout.getvalue(), stderr.getvalue()

    def test_every_flavour_current_is_reported_as_current(self):
        statuses = module.compare([], self.table, self.package, self.transport)

        self.assertEqual(["retail", "ptr"], [status.flavour for status in statuses])
        self.assertFalse(any(status.newer for status in statuses))

    def test_a_higher_mirror_build_is_newer(self):
        self.transport.responses[commit_url("live")] = commit_response(LIVE_COMMIT, "12.1.0 (70001)")

        statuses = module.compare(["retail"], self.table, self.package, self.transport)

        self.assertTrue(statuses[0].newer)
        self.assertEqual(70001, statuses[0].head.build)

    def test_the_head_fetch_would_capture_is_compared(self):
        """Of `ptr` and `ptr2` the higher build wins, as it does for `fetch`."""
        self.write_provenance("ptr", "ptr", 69587)

        status = module.compare(["ptr"], self.table, self.package, self.transport)[0]

        self.assertEqual("ptr2", status.head.branch)
        self.assertTrue(status.newer)

    def test_a_head_without_a_build_is_never_newer(self):
        self.transport.responses[commit_url("live")] = commit_response(LIVE_COMMIT, "Disable export")

        status = module.compare(["retail"], self.table, self.package, self.transport)[0]

        self.assertFalse(status.newer)

    def test_a_committed_capture_without_a_build_is_behind_any_build(self):
        self.write_provenance("retail", "live", None)

        status = module.compare(["retail"], self.table, self.package, self.transport)[0]

        self.assertTrue(status.newer)

    def test_main_prints_one_line_per_flavour(self):
        status, stdout, _ = self.run_main()

        self.assertEqual(0, status)
        self.assertEqual(
            [
                "retail  committed live 69933  mirror live 69933  current",
                "ptr  committed ptr2 69952  mirror ptr2 69952  current",
            ],
            stdout.splitlines(),
        )

    def test_main_writes_the_report_and_the_outputs(self):
        self.transport.responses[commit_url("live")] = commit_response(LIVE_COMMIT, "12.1.0 (70001)")
        report = self.package / "report.md"
        outputs = self.package / "outputs.txt"

        status, _, _ = self.run_main("--markdown", str(report), "--github-output", str(outputs))

        self.assertEqual(0, status)
        self.assertEqual("newer=true\nflavours=retail\n", outputs.read_text(encoding="utf-8"))
        body = report.read_text(encoding="utf-8")
        self.assertIn("| `retail` | `live` 69933 | `live` 70001 (`aaaaaaaaaaaa`) | **newer** |", body)
        self.assertIn("| `ptr` | `ptr2` 69952 | `ptr2` 69952 (`cccccccccccc`) | current |", body)

    def test_the_report_is_the_same_for_the_same_builds(self):
        """The workflow edits the issue only when the body changes, so it must be stable."""
        first = module.render_markdown(module.compare([], self.table, self.package, self.transport))
        second = module.render_markdown(module.compare([], self.table, self.package, self.transport))

        self.assertEqual(first, second)

    def test_outputs_when_nothing_is_newer(self):
        statuses = module.compare([], self.table, self.package, self.transport)

        self.assertEqual("newer=false\nflavours=\n", module.github_outputs(statuses))

    def test_a_missing_provenance_is_an_error(self):
        (self.package / "metadata" / "ptr" / model.PROVENANCE_FILE).unlink()

        status, _, stderr = self.run_main()

        self.assertEqual(1, status)
        self.assertIn("provenance.json: cannot be read", stderr)

    def test_a_provenance_of_another_schema_is_an_error(self):
        path = self.package / "metadata" / "retail" / model.PROVENANCE_FILE
        path.write_text(json.dumps({"schema": 99}), encoding="utf-8")

        status, _, stderr = self.run_main("--flavour", "retail")

        self.assertEqual(1, status)
        self.assertIn("expected schema", stderr)

    def test_a_mirror_failure_is_an_error(self):
        del self.transport.responses[commit_url("ptr2")]

        status, _, stderr = self.run_main("--flavour", "ptr")

        self.assertEqual(1, status)
        self.assertIn("HTTP 404", stderr)

    def test_an_unknown_flavour_is_an_error(self):
        status, _, stderr = self.run_main("--flavour", "wrath")

        self.assertEqual(1, status)
        self.assertIn("unknown flavour", stderr)


class CommittedMetadataTests(unittest.TestCase):
    """Every flavour in the committed table has a provenance this command can read."""

    def test_every_committed_flavour_has_a_readable_provenance(self):
        for flavour in flavours.load_flavours().flavours:
            with self.subTest(flavour=flavour.id):
                read = module.read_provenance(module.DEFAULT_PACKAGE_DIRECTORY / "metadata" / flavour.id)
                self.assertEqual(flavour.id, read.flavour)
                self.assertIn(read.branch, flavour.branches)


if __name__ == "__main__":
    unittest.main()
