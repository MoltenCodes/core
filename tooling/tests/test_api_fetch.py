"""Tests for the apiKit fetch step.

Every test talks to a fake mirror held in memory: a dictionary from URL to
response bytes wrapped in `FakeTransport`, which also records the URLs it was
asked for. Nothing here touches the network or the committed flavour table;
the small table below is written to a temporary file, loaded through
`flavours.load_flavours` and handed to the module through its `flavours_table`
keyword argument.
"""

from __future__ import annotations

import datetime
import io
import json
import tempfile
import unittest
import urllib.error
from contextlib import redirect_stderr, redirect_stdout
from pathlib import Path
from unittest import mock

from tooling.api import fetch as module
from tooling.api import flavours


REPOSITORY = "Example/wow-ui-source"
DOCUMENTATION_PATH = "Interface/AddOns/Blizzard_APIDocumentationGenerated"

FLAVOUR_TABLE = {
    "verified": "2026-09-24",
    "mirror": {"repository": REPOSITORY, "documentationPath": DOCUMENTATION_PATH},
    "probes": {"projectId": "WOW_PROJECT_ID", "testBuild": "IsTestBuild", "betaBuild": "IsBetaBuild"},
    "flavours": [
        {
            "id": "retail",
            "displayName": "Retail",
            "namespace": "wow.retail.api",
            "runtimeFile": "flavours/Retail.lua",
            "branches": ["live"],
            "detection": {"projectId": 1, "testBuild": False, "betaBuild": False},
        },
        {
            "id": "ptr",
            "displayName": "Public Test Realm",
            "namespace": "wow.ptr.api",
            "runtimeFile": "flavours/Ptr.lua",
            "branches": ["ptr", "ptr2"],
            "detection": {"projectId": 1, "testBuild": True, "betaBuild": False},
        },
    ],
}

LIVE_COMMIT = "a" * 40
PTR_COMMIT = "b" * 40
PTR2_COMMIT = "c" * 40
COMMITTED_AT = "2026-09-20T12:00:00Z"


def commit_url(ref: str) -> str:
    return f"https://api.github.com/repos/{REPOSITORY}/commits/{ref}"


def contents_url(commit: str) -> str:
    return f"https://api.github.com/repos/{REPOSITORY}/contents/{DOCUMENTATION_PATH}?ref={commit}"


def download_url(commit: str, name: str) -> str:
    return f"https://raw.example.test/{commit}/{name}"


def commit_response(sha: str, subject: str, committed_at: str = COMMITTED_AT) -> bytes:
    """The part of GitHub's commit document the module reads, plus a second message line."""
    document = {
        "sha": sha,
        "commit": {"message": subject + "\n\nExported by the mirror.", "committer": {"date": committed_at}},
    }
    return json.dumps(document).encode("utf-8")


def listing_entry(name: str, commit: str, entry_type: str = "file") -> dict:
    return {
        "name": name,
        "type": entry_type,
        "size": 10,
        "sha": "0" * 40,
        "download_url": download_url(commit, name),
    }


class FakeTransport:
    """An in-memory GET: known URLs return their bytes, unknown ones raise `FetchError`."""

    def __init__(self, responses: dict[str, bytes] | None = None):
        self.responses = dict(responses or {})
        self.calls: list[str] = []

    def __call__(self, url: str) -> bytes:
        self.calls.append(url)
        if url not in self.responses:
            raise module.FetchError(f"GET {url} failed: HTTP 404 Not Found")
        return self.responses[url]


class ParseSubjectTests(unittest.TestCase):
    def test_version_and_build_are_split(self):
        self.assertEqual(("12.1.0", 69933), module.parse_subject("12.1.0 (69933)"))

    def test_two_part_versions_are_accepted(self):
        self.assertEqual(("1.15", 12345), module.parse_subject("1.15 (12345)"))

    def test_surrounding_whitespace_is_ignored(self):
        self.assertEqual(("5.5.0", 61000), module.parse_subject("  5.5.0 (61000)\n"))

    def test_other_subjects_give_no_version_and_no_build(self):
        self.assertEqual((None, None), module.parse_subject("Disable cron-based export"))
        self.assertEqual((None, None), module.parse_subject("12.1.0"))
        self.assertEqual((None, None), module.parse_subject("(69933)"))
        self.assertEqual((None, None), module.parse_subject(""))


class BranchHeadTests(unittest.TestCase):
    def test_commit_document_is_mapped_to_a_head(self):
        transport = FakeTransport({commit_url("live"): commit_response(LIVE_COMMIT, "12.1.0 (69933)")})

        head = module.branch_head(REPOSITORY, "live", transport)

        self.assertEqual(
            module.BranchHead(
                branch="live",
                commit=LIVE_COMMIT,
                committed_at=COMMITTED_AT,
                subject="12.1.0 (69933)",
                version="12.1.0",
                build=69933,
            ),
            head,
        )
        self.assertEqual([commit_url("live")], transport.calls)

    def test_subject_is_the_first_message_line_only(self):
        transport = FakeTransport({commit_url("ptr"): commit_response(PTR_COMMIT, "Disable cron-based export")})

        head = module.branch_head(REPOSITORY, "ptr", transport)

        self.assertEqual("Disable cron-based export", head.subject)
        self.assertIsNone(head.version)
        self.assertIsNone(head.build)

    def test_unexpected_document_shape_is_a_fetch_error(self):
        transport = FakeTransport({commit_url("live"): b'{"sha": "abc"}'})

        with self.assertRaisesRegex(module.FetchError, "unexpected response shape"):
            module.branch_head(REPOSITORY, "live", transport)

    def test_non_json_body_is_a_fetch_error(self):
        transport = FakeTransport({commit_url("live"): b"<html>rate limited</html>"})

        with self.assertRaisesRegex(module.FetchError, "did not return JSON"):
            module.branch_head(REPOSITORY, "live", transport)

    def test_transport_failure_propagates(self):
        with self.assertRaisesRegex(module.FetchError, "HTTP 404"):
            module.branch_head(REPOSITORY, "live", FakeTransport())


def head(branch: str, build: int | None, commit: str = "d" * 40) -> module.BranchHead:
    subject = f"12.0.0 ({build})" if build is not None else "Maintenance"
    version = "12.0.0" if build is not None else None
    return module.BranchHead(
        branch=branch, commit=commit, committed_at=COMMITTED_AT, subject=subject, version=version, build=build
    )


class ChooseBranchTests(unittest.TestCase):
    def test_highest_build_wins(self):
        chosen = module.choose_branch([head("ptr", 69000), head("ptr2", 69933)])

        self.assertEqual("ptr2", chosen.branch)

    def test_head_without_build_never_wins_over_one_with_build(self):
        self.assertEqual("ptr2", module.choose_branch([head("ptr", None), head("ptr2", 1)]).branch)
        self.assertEqual("ptr", module.choose_branch([head("ptr", 1), head("ptr2", None)]).branch)

    def test_equal_builds_keep_the_sequence_order(self):
        chosen = module.choose_branch([head("ptr", 69933), head("ptr2", 69933)])

        self.assertEqual("ptr", chosen.branch)

    def test_all_without_builds_gives_the_first(self):
        chosen = module.choose_branch([head("ptr", None), head("ptr2", None)])

        self.assertEqual("ptr", chosen.branch)

    def test_empty_sequence_is_a_fetch_error(self):
        with self.assertRaisesRegex(module.FetchError, "no branch heads"):
            module.choose_branch([])


class FakeMirrorTests(unittest.TestCase):
    """Fixture: a temporary destination, the small flavour table and a populated fake mirror."""

    def setUp(self):
        self.tempdir = tempfile.TemporaryDirectory()
        root = Path(self.tempdir.name)
        table_path = root / "flavours.json"
        table_path.write_text(json.dumps(FLAVOUR_TABLE), encoding="utf-8")
        self.table = flavours.load_flavours(table_path)
        self.destination = root / "captures"
        self.today = datetime.date(2026, 9, 24)

        self.transport = FakeTransport()
        self.add_branch("live", LIVE_COMMIT, "12.1.0 (69933)", ["Alpha.lua", "Beta.lua"])
        self.add_branch("ptr", PTR_COMMIT, "12.1.5 (70001)", ["Gamma.lua"])
        self.add_branch("ptr2", PTR2_COMMIT, "12.2.0 (70100)", ["Delta.lua"])

    def tearDown(self):
        self.tempdir.cleanup()

    def add_branch(self, branch: str, commit: str, subject: str, lua_names: list[str]) -> None:
        """Make the fake mirror answer for one branch: its head, its listing and its files."""
        self.transport.responses[commit_url(branch)] = commit_response(commit, subject)
        self.transport.responses[commit_url(commit)] = commit_response(commit, subject)
        entries = [listing_entry(name, commit) for name in lua_names]
        entries.append(listing_entry("Blizzard_APIDocumentationGenerated.toc", commit))
        entries.append(listing_entry("Subdirectory", commit, entry_type="dir"))
        self.transport.responses[contents_url(commit)] = json.dumps(entries).encode("utf-8")
        for name in lua_names:
            self.transport.responses[download_url(commit, name)] = f"-- {name} at {commit}\n".encode("utf-8")

    def fetch(self, flavour_id: str, **options) -> module.Capture:
        return module.fetch(
            flavour_id,
            self.destination,
            transport=self.transport,
            today=self.today,
            flavours_table=self.table,
            **options,
        )

    def read_capture_file(self, capture: module.Capture) -> dict:
        return json.loads((capture.directory / "capture.json").read_text(encoding="utf-8"))


class FetchTests(FakeMirrorTests):
    def test_capture_lands_under_destination_flavour_and_commit(self):
        capture = self.fetch("retail")

        self.assertEqual(self.destination / "retail" / LIVE_COMMIT, capture.directory)
        self.assertEqual(
            module.Capture(
                flavour_id="retail",
                repository=REPOSITORY,
                branch="live",
                commit=LIVE_COMMIT,
                committed_at=COMMITTED_AT,
                subject="12.1.0 (69933)",
                version="12.1.0",
                build=69933,
                documentation_path=DOCUMENTATION_PATH,
                captured_on="2026-09-24",
                file_count=2,
                directory=self.destination / "retail" / LIVE_COMMIT,
            ),
            capture,
        )

    def test_lua_files_are_written_with_their_raw_bytes(self):
        capture = self.fetch("retail")

        documentation = capture.directory / "documentation"
        self.assertEqual(["Alpha.lua", "Beta.lua"], sorted(path.name for path in documentation.iterdir()))
        self.assertEqual(
            f"-- Alpha.lua at {LIVE_COMMIT}\n".encode("utf-8"), (documentation / "Alpha.lua").read_bytes()
        )

    def test_toc_and_non_file_entries_are_skipped(self):
        capture = self.fetch("retail")

        names = sorted(path.name for path in (capture.directory / "documentation").iterdir())
        self.assertNotIn("Blizzard_APIDocumentationGenerated.toc", names)
        self.assertNotIn("Subdirectory", names)
        self.assertEqual(2, capture.file_count)
        self.assertNotIn(download_url(LIVE_COMMIT, "Blizzard_APIDocumentationGenerated.toc"), self.transport.calls)

    def test_capture_file_records_provenance_with_camel_case_keys(self):
        capture = self.fetch("retail")

        self.assertEqual(
            {
                "flavourId": "retail",
                "repository": REPOSITORY,
                "branch": "live",
                "commit": LIVE_COMMIT,
                "committedAt": COMMITTED_AT,
                "subject": "12.1.0 (69933)",
                "version": "12.1.0",
                "build": 69933,
                "documentationPath": DOCUMENTATION_PATH,
                "capturedOn": "2026-09-24",
                "fileCount": 2,
                "files": ["Alpha.lua", "Beta.lua"],
            },
            self.read_capture_file(capture),
        )

    def test_capture_file_bytes_are_deterministic(self):
        capture = self.fetch("retail")

        text = (capture.directory / "capture.json").read_text(encoding="utf-8")
        expected = json.dumps(self.read_capture_file(capture), indent=2, sort_keys=True) + "\n"
        self.assertEqual(expected, text)

    def test_flavour_with_several_branches_takes_the_newest_build(self):
        capture = self.fetch("ptr")

        self.assertEqual("ptr2", capture.branch)
        self.assertEqual(PTR2_COMMIT, capture.commit)
        self.assertEqual(70100, capture.build)
        self.assertIn(commit_url("ptr"), self.transport.calls)
        self.assertIn(commit_url("ptr2"), self.transport.calls)

    def test_explicit_branch_is_used_instead_of_choosing(self):
        capture = self.fetch("ptr", branch="ptr")

        self.assertEqual("ptr", capture.branch)
        self.assertEqual(PTR_COMMIT, capture.commit)
        self.assertNotIn(commit_url("ptr2"), self.transport.calls)

    def test_branch_the_flavour_does_not_list_is_refused(self):
        with self.assertRaisesRegex(module.FetchError, "'live' is not one of flavour 'ptr': ptr, ptr2"):
            self.fetch("ptr", branch="live")
        self.assertEqual([], self.transport.calls)

    def test_pinned_commit_records_the_first_branch_when_none_is_given(self):
        capture = self.fetch("ptr", commit=PTR2_COMMIT)

        self.assertEqual("ptr", capture.branch)
        self.assertEqual(PTR2_COMMIT, capture.commit)
        self.assertEqual("12.2.0", capture.version)
        self.assertNotIn(commit_url("ptr"), self.transport.calls)
        self.assertNotIn(commit_url("ptr2"), self.transport.calls)

    def test_pinned_commit_records_the_branch_when_given(self):
        capture = self.fetch("ptr", commit=PTR2_COMMIT, branch="ptr2")

        self.assertEqual("ptr2", capture.branch)
        self.assertEqual(PTR2_COMMIT, capture.commit)

    def test_unknown_flavour_is_a_fetch_error(self):
        with self.assertRaisesRegex(module.FetchError, "unknown flavour 'wrath'; known flavours: retail, ptr"):
            self.fetch("wrath")

    def test_listing_without_lua_files_is_a_fetch_error(self):
        entries = [listing_entry("Blizzard_APIDocumentationGenerated.toc", LIVE_COMMIT)]
        self.transport.responses[contents_url(LIVE_COMMIT)] = json.dumps(entries).encode("utf-8")

        with self.assertRaisesRegex(module.FetchError, "no Lua documentation files"):
            self.fetch("retail")

    def test_existing_capture_is_returned_without_any_request(self):
        first = self.fetch("retail", commit=LIVE_COMMIT)
        self.transport.calls.clear()

        second = self.fetch("retail", commit=LIVE_COMMIT)

        self.assertEqual(first, second)
        self.assertEqual([], self.transport.calls)

    def test_existing_capture_is_reused_after_the_branch_lookup(self):
        first = self.fetch("retail")
        self.transport.calls.clear()

        second = self.fetch("retail")

        self.assertEqual(first, second)
        self.assertEqual([commit_url("live")], self.transport.calls)

    def test_malformed_capture_file_asks_for_the_directory_to_be_deleted(self):
        directory = self.destination / "retail" / LIVE_COMMIT
        directory.mkdir(parents=True)
        (directory / "capture.json").write_text("{}", encoding="utf-8")

        with self.assertRaisesRegex(module.FetchError, "delete the directory"):
            self.fetch("retail", commit=LIVE_COMMIT)

    def test_failure_mid_way_leaves_nothing_behind(self):
        del self.transport.responses[download_url(LIVE_COMMIT, "Beta.lua")]

        with self.assertRaisesRegex(module.FetchError, "Beta.lua"):
            self.fetch("retail")

        flavour_directory = self.destination / "retail"
        self.assertEqual([], list(flavour_directory.iterdir()) if flavour_directory.exists() else [])
        self.assertFalse((flavour_directory / LIVE_COMMIT).exists())

    def test_incomplete_directory_from_an_earlier_run_is_replaced(self):
        leftover = self.destination / "retail" / LIVE_COMMIT
        (leftover / "documentation").mkdir(parents=True)
        (leftover / "documentation" / "Stale.lua").write_text("stale", encoding="utf-8")

        capture = self.fetch("retail")

        names = sorted(path.name for path in (capture.directory / "documentation").iterdir())
        self.assertEqual(["Alpha.lua", "Beta.lua"], names)
        self.assertFalse((self.destination / "retail" / (LIVE_COMMIT + ".incomplete")).exists())


class DefaultTransportTests(unittest.TestCase):
    """The urllib transport is exercised with a patched `urlopen`; no request leaves the process."""

    def test_sends_user_agent_and_no_authorization_without_token(self):
        with mock.patch.dict("os.environ", {}, clear=True), mock.patch(
            "urllib.request.urlopen"
        ) as urlopen:
            urlopen.return_value.__enter__.return_value.read.return_value = b"body"

            self.assertEqual(b"body", module.default_transport("https://example.test/file"))

        request = urlopen.call_args.args[0]
        self.assertEqual("MoltenCodes-apiKit-fetch", request.get_header("User-agent"))
        self.assertFalse(request.has_header("Authorization"))

    def test_sends_bearer_token_when_environment_has_one(self):
        with mock.patch.dict("os.environ", {"GITHUB_TOKEN": "secret"}), mock.patch(
            "urllib.request.urlopen"
        ) as urlopen:
            urlopen.return_value.__enter__.return_value.read.return_value = b""
            module.default_transport("https://example.test/file")

        request = urlopen.call_args.args[0]
        self.assertEqual("Bearer secret", request.get_header("Authorization"))

    def test_http_error_becomes_fetch_error_with_url_and_status(self):
        failure = urllib.error.HTTPError("https://example.test/missing", 404, "Not Found", {}, None)
        with mock.patch("urllib.request.urlopen", side_effect=failure):
            with self.assertRaisesRegex(module.FetchError, "GET https://example.test/missing failed: HTTP 404"):
                module.default_transport("https://example.test/missing")

    def test_connection_error_becomes_fetch_error(self):
        failure = urllib.error.URLError("no route to host")
        with mock.patch("urllib.request.urlopen", side_effect=failure):
            with self.assertRaisesRegex(module.FetchError, "no route to host"):
                module.default_transport("https://example.test/file")


class MainTests(FakeMirrorTests):
    def run_main(self, argv: list[str]) -> tuple[int, str, str]:
        output = io.StringIO()
        errors = io.StringIO()
        with redirect_stdout(output), redirect_stderr(errors):
            status = module.main(argv, transport=self.transport, flavours_table=self.table)
        return status, output.getvalue(), errors.getvalue()

    def test_heads_lists_every_branch_without_downloading(self):
        status, output, _ = self.run_main(["--heads", "--flavour", "ptr"])

        self.assertEqual(0, status)
        self.assertEqual(
            [
                f"ptr  {PTR_COMMIT}  {COMMITTED_AT}  version=12.1.5  build=70001",
                f"ptr2  {PTR2_COMMIT}  {COMMITTED_AT}  version=12.2.0  build=70100",
            ],
            output.splitlines(),
        )
        self.assertEqual([commit_url("ptr"), commit_url("ptr2")], self.transport.calls)
        self.assertFalse(self.destination.exists())

    def test_heads_shows_a_dash_for_unparsed_subjects(self):
        self.transport.responses[commit_url("live")] = commit_response(LIVE_COMMIT, "Disable cron-based export")

        status, output, _ = self.run_main(["--heads", "--flavour", "retail"])

        self.assertEqual(0, status)
        self.assertEqual(f"live  {LIVE_COMMIT}  {COMMITTED_AT}  version=-  build=-", output.strip())

    def test_fetch_prints_directory_and_provenance(self):
        status, output, errors = self.run_main(["--flavour", "retail", "--out", str(self.destination)])

        self.assertEqual(0, status)
        self.assertEqual("", errors)
        lines = output.splitlines()
        self.assertEqual(str(self.destination / "retail" / LIVE_COMMIT), lines[0])
        self.assertIn(f"retail: {REPOSITORY}@{LIVE_COMMIT} (live, 12.1.0, build 69933", lines[1])
        self.assertTrue((self.destination / "retail" / LIVE_COMMIT / "capture.json").is_file())

    def test_branch_and_commit_options_are_passed_through(self):
        status, output, _ = self.run_main(
            ["--flavour", "ptr", "--out", str(self.destination), "--branch", "ptr2", "--commit", PTR2_COMMIT]
        )

        self.assertEqual(0, status)
        self.assertEqual(str(self.destination / "ptr" / PTR2_COMMIT), output.splitlines()[0])
        self.assertIn("(ptr2, 12.2.0, build 70100", output)

    def test_unknown_flavour_is_reported_on_stderr(self):
        status, output, errors = self.run_main(["--flavour", "wrath", "--out", str(self.destination)])

        self.assertEqual(1, status)
        self.assertEqual("", output)
        self.assertTrue(errors.startswith("error: unknown flavour 'wrath'"), errors)

    def test_transport_failure_is_reported_on_stderr(self):
        del self.transport.responses[commit_url("live")]

        status, _, errors = self.run_main(["--flavour", "retail", "--out", str(self.destination)])

        self.assertEqual(1, status)
        self.assertIn("error: GET", errors)
        self.assertIn("HTTP 404", errors)

    def test_out_is_required_without_heads(self):
        with redirect_stderr(io.StringIO()):
            with self.assertRaises(SystemExit) as exit_context:
                module.main(["--flavour", "retail"], transport=self.transport, flavours_table=self.table)

        self.assertEqual(2, exit_context.exception.code)


if __name__ == "__main__":
    unittest.main()
