"""Fetch one flavour's API documentation tables at a pinned mirror commit.

This is step 1 of the apiKit update pipeline (`docs/API_KIT_DESIGN.md`,
section 14). The client's machine-readable API documentation lives as Lua
tables under `Blizzard_APIDocumentationGenerated` in the interface code, which
the community `wow-ui-source` mirror publishes with one branch per client
flavour. The fetch downloads those tables for one flavour at one commit and
records where they came from, so that `normalize` (step 2) works on an input
that can be named, checked and reproduced.

    python3 -m tooling.api.fetch --flavour retail --out DIR [--branch NAME] [--commit SHA]
    python3 -m tooling.api.fetch --heads --flavour retail

Two rules from the design document (section 12) shape this module:

- **Nothing downloaded is written inside the repository.** The caller passes
  the destination; the module never derives a path from its own location.
  The capture lands in `<destination>/<flavour id>/<commit>/`, with the Lua
  files under `documentation/` and the provenance in `capture.json`.
- **A capture is pinned and reproducible.** The commit is always recorded in
  full; re-fetching the same commit can never yield different bytes, so a
  directory that already holds a `capture.json` is trusted and not downloaded
  again. Files are written into a staging directory and renamed into place at
  the end, so an interrupted fetch never leaves a half capture that this
  shortcut would trust.

The mirror is read through the GitHub REST API (two calls: the commit and the
directory listing) and raw downloads (one per file). Unauthenticated API use
is limited to 60 requests per hour, which comfortably covers a fetch; setting
`GITHUB_TOKEN` raises that limit for repeated runs. Raw downloads do not count
against the API limit. The flavour table, the mirror repository and the
documentation path all come from `tooling.api.flavours`; nothing about the
mirror is repeated here.

Network access goes through one `Transport` function so tests, and any caller
that already has the bytes, can substitute an in-memory source.
"""

from __future__ import annotations

import argparse
import datetime
import json
import os
import re
import shutil
import sys
import urllib.error
import urllib.request
from dataclasses import dataclass, replace
from pathlib import Path
from typing import Any, Callable, Sequence

from tooling.api.flavours import Flavour, Flavours, load_flavours


#: A function that GETs a URL and returns the response body.
Transport = Callable[[str], bytes]

#: Root of the GitHub REST API.
API_ROOT = "https://api.github.com"

#: Sent with every request so the mirror's operators can see who is asking.
USER_AGENT = "MoltenCodes-apiKit-fetch"

#: Environment variable holding an optional GitHub token for a higher API limit.
TOKEN_VARIABLE = "GITHUB_TOKEN"

#: Name of the provenance file inside a capture directory.
CAPTURE_FILE = "capture.json"

#: Directory inside a capture that holds the downloaded Lua tables.
DOCUMENTATION_DIRECTORY = "documentation"

#: How long one request may take before it is a failure rather than a wait; a
#: stalled connection must never hang a fetch forever.
REQUEST_TIMEOUT_SECONDS = 30

#: The contents API returns at most this many entries for a directory, silently.
#: The documentation directory holds a few hundred files today; reaching the cap
#: would mean files were dropped, so it is refused rather than trusted.
CONTENTS_LISTING_CAP = 1000

#: Suffix of the staging directory a fetch writes into before it is complete.
STAGING_SUFFIX = ".incomplete"

#: The mirror's commit subjects for a client build: `12.1.0 (69933)`.
SUBJECT_RE = re.compile(r"^(\d+(?:\.\d+)*) \((\d+)\)$")

#: The keys `capture.json` carries, in the order they are documented.
CAPTURE_KEYS = (
    "flavourId",
    "repository",
    "branch",
    "commit",
    "committedAt",
    "subject",
    "version",
    "build",
    "documentationPath",
    "capturedOn",
    "fileCount",
    "files",
)


class FetchError(Exception):
    """The fetch could not complete: a transport failure, an unexpected response or a bad request."""


@dataclass(frozen=True)
class BranchHead:
    """The commit a mirror branch points at, with the build parsed from its subject."""

    branch: str
    commit: str
    committed_at: str
    subject: str
    version: str | None
    build: int | None


@dataclass(frozen=True)
class Capture:
    """The provenance of one fetched capture; `directory` is where it lies on disk."""

    flavour_id: str
    repository: str
    branch: str
    commit: str
    committed_at: str
    subject: str
    version: str | None
    build: int | None
    documentation_path: str
    captured_on: str
    file_count: int
    directory: Path


@dataclass(frozen=True)
class _RemoteFile:
    """One documentation file as the directory listing describes it."""

    name: str
    download_url: str


def _request_headers() -> dict[str, str]:
    """Headers for every request: the agent name, and the token when the environment has one."""
    headers = {"User-Agent": USER_AGENT, "Accept": "application/vnd.github+json"}
    token = os.environ.get(TOKEN_VARIABLE)
    if token:
        headers["Authorization"] = f"Bearer {token}"
    return headers


def default_transport(url: str) -> bytes:
    """GET `url` with urllib and return the body.

    HTTP and connection failures become `FetchError` naming the URL and the
    status, so a caller sees one exception type whatever the transport is.
    """
    request = urllib.request.Request(url, headers=_request_headers())
    try:
        with urllib.request.urlopen(request, timeout=REQUEST_TIMEOUT_SECONDS) as response:
            return response.read()
    except urllib.error.HTTPError as failure:
        raise FetchError(f"GET {url} failed: HTTP {failure.code} {failure.reason}") from None
    except urllib.error.URLError as failure:
        raise FetchError(f"GET {url} failed: {failure.reason}") from None


def _get_json(url: str, transport: Transport) -> Any:
    """Fetch `url` and decode it as JSON, reporting a malformed body as a fetch failure."""
    body = transport(url)
    try:
        return json.loads(body)
    except ValueError:
        raise FetchError(f"GET {url} did not return JSON") from None


def _commit_url(repository: str, ref: str) -> str:
    return f"{API_ROOT}/repos/{repository}/commits/{ref}"


def _contents_url(repository: str, documentation_path: str, commit: str) -> str:
    return f"{API_ROOT}/repos/{repository}/contents/{documentation_path}?ref={commit}"


def parse_subject(subject: str) -> tuple[str | None, int | None]:
    """Split a mirror commit subject of the shape `<version> (<build>)`.

    The mirror's export commits are titled with the client version and build,
    `12.1.0 (69933)`; those two facts are the provenance the metadata records.
    Any other subject (the mirror also carries maintenance commits such as
    `Disable cron-based export`) yields `(None, None)` rather than a guess.
    """
    match = SUBJECT_RE.match(subject.strip())
    if match is None:
        return None, None
    return match.group(1), int(match.group(2))


def _first_line(message: str) -> str:
    """The commit subject: the first line of the message, or empty for an empty message."""
    lines = message.strip().splitlines()
    if not lines:
        return ""
    return lines[0]


def branch_head(repository: str, ref: str, transport: Transport) -> BranchHead:
    """Look up the commit `ref` (a branch name or a commit sha) resolves to on the mirror.

    The `branch` of the result is `ref` as given; when `ref` is a sha the
    caller decides which branch name to record.
    """
    data = _get_json(_commit_url(repository, ref), transport)
    try:
        subject = _first_line(data["commit"]["message"])
        version, build = parse_subject(subject)
        return BranchHead(
            branch=ref,
            commit=data["sha"],
            committed_at=data["commit"]["committer"]["date"],
            subject=subject,
            version=version,
            build=build,
        )
    except (KeyError, TypeError):
        raise FetchError(f"commit {ref!r} of {repository}: unexpected response shape") from None


def choose_branch(heads: Sequence[BranchHead]) -> BranchHead:
    """Pick the head to fetch when a flavour names several branches.

    The head with the highest build wins, because the newest client build is
    the one the wrapper should describe. A head whose subject carries no build
    never wins over one that does: its subject says nothing about a client
    build. With equal builds the earlier head in the sequence wins, so the
    order of the flavour's `branches` list breaks ties. When no head carries a
    build the first is taken, for the same reason.
    """
    if not heads:
        raise FetchError("no branch heads to choose from")
    chosen = heads[0]
    for candidate in heads[1:]:
        if candidate.build is None:
            continue
        if chosen.build is None or candidate.build > chosen.build:
            chosen = candidate
    return chosen


def _resolve_head(
    flavour: Flavour,
    repository: str,
    branch: str | None,
    commit: str | None,
    transport: Transport,
) -> BranchHead:
    """Decide which commit to capture from the caller's `branch` and `commit` choices."""
    if branch is not None and branch not in flavour.branches:
        raise FetchError(
            f"branch {branch!r} is not one of flavour {flavour.id!r}: {', '.join(flavour.branches)}"
        )
    if commit is not None:
        recorded_branch = branch if branch is not None else flavour.branches[0]
        return replace(branch_head(repository, commit, transport), branch=recorded_branch)
    if branch is not None:
        return branch_head(repository, branch, transport)
    heads = [branch_head(repository, name, transport) for name in flavour.branches]
    return choose_branch(heads)


def _list_documentation_files(
    repository: str, documentation_path: str, commit: str, transport: Transport
) -> list[_RemoteFile]:
    """The Lua files of the documentation directory at `commit`, sorted by name.

    The directory also holds the addon's `.toc`, which only lists the same
    files for the client and is not needed; directories and anything that is
    not a plain file are skipped as well.
    """
    entries = _get_json(_contents_url(repository, documentation_path, commit), transport)
    if not isinstance(entries, list):
        raise FetchError(f"{documentation_path} at {commit} is not a directory listing")
    if len(entries) >= CONTENTS_LISTING_CAP:
        raise FetchError(
            f"{documentation_path} at {commit} lists {len(entries)} entries, the contents API's "
            "cap; the listing may be incomplete and the fetch must move to the git trees API"
        )
    files = []
    for entry in entries:
        if entry.get("type") != "file" or not str(entry.get("name", "")).endswith(".lua"):
            continue
        files.append(_RemoteFile(name=entry["name"], download_url=entry["download_url"]))
    files.sort(key=lambda remote_file: remote_file.name)
    if not files:
        raise FetchError(f"{documentation_path} at {commit} holds no Lua documentation files")
    return files


def _capture_directory(destination: Path, flavour_id: str, commit: str) -> Path:
    return destination / flavour_id / commit


def _capture_to_json(capture: Capture, file_names: Sequence[str]) -> dict[str, Any]:
    """The `capture.json` document: every Capture field except `directory`, plus the file names."""
    return {
        "flavourId": capture.flavour_id,
        "repository": capture.repository,
        "branch": capture.branch,
        "commit": capture.commit,
        "committedAt": capture.committed_at,
        "subject": capture.subject,
        "version": capture.version,
        "build": capture.build,
        "documentationPath": capture.documentation_path,
        "capturedOn": capture.captured_on,
        "fileCount": capture.file_count,
        "files": sorted(file_names),
    }


def _capture_from_json(data: Any, directory: Path) -> Capture:
    if not isinstance(data, dict) or set(data) != set(CAPTURE_KEYS):
        raise FetchError(
            f"{directory / CAPTURE_FILE} does not have the expected keys; "
            "delete the directory to fetch again"
        )
    return Capture(
        flavour_id=data["flavourId"],
        repository=data["repository"],
        branch=data["branch"],
        commit=data["commit"],
        committed_at=data["committedAt"],
        subject=data["subject"],
        version=data["version"],
        build=data["build"],
        documentation_path=data["documentationPath"],
        captured_on=data["capturedOn"],
        file_count=data["fileCount"],
        directory=directory,
    )


def _cached_capture(directory: Path) -> Capture | None:
    """The capture already recorded in `directory`, or None when nothing complete is there."""
    capture_file = directory / CAPTURE_FILE
    if not capture_file.is_file():
        return None
    try:
        data = json.loads(capture_file.read_text(encoding="utf-8"))
    except ValueError:
        raise FetchError(f"{capture_file} is not JSON; delete the directory to fetch again") from None
    return _capture_from_json(data, directory)


def _write_capture_file(directory: Path, capture: Capture, file_names: Sequence[str]) -> None:
    """Write `capture.json` deterministically: sorted keys, two-space indent, trailing newline."""
    document = json.dumps(_capture_to_json(capture, file_names), indent=2, sort_keys=True)
    (directory / CAPTURE_FILE).write_text(document + "\n", encoding="utf-8")


def _download_documentation(staging: Path, files: Sequence[_RemoteFile], transport: Transport) -> None:
    """Store every file's raw bytes under `staging/documentation/`, untouched."""
    documentation = staging / DOCUMENTATION_DIRECTORY
    documentation.mkdir(parents=True)
    for remote_file in files:
        (documentation / remote_file.name).write_bytes(transport(remote_file.download_url))


def _replace_directory(staging: Path, final: Path) -> None:
    """Move the finished staging directory into place, displacing any incomplete remains."""
    if final.exists():
        shutil.rmtree(final)
    staging.rename(final)


def _capture_date(today: datetime.date | None) -> str:
    if today is None:
        today = datetime.datetime.now(datetime.timezone.utc).date()
    return today.isoformat()


def fetch(
    flavour_id: str,
    destination: Path,
    *,
    branch: str | None = None,
    commit: str | None = None,
    transport: Transport = default_transport,
    today: datetime.date | None = None,
    flavours_table: Flavours | None = None,
) -> Capture:
    """Fetch one flavour's documentation tables into `destination` and record provenance.

    Without `branch` and `commit`, every branch the flavour names is looked up
    and `choose_branch` picks the newest build. With `branch`, that branch's
    head is taken; it must be one of the flavour's branches. With `commit`,
    that commit is pinned and `branch` is recorded as given or, when omitted,
    as the flavour's first branch.

    The capture is written to `<destination>/<flavour_id>/<commit>/`:
    `documentation/<name>.lua` for every Lua file and `capture.json` with the
    provenance. A directory that already holds a `capture.json` is returned as
    recorded without any download, because a pinned commit never changes; a
    pinned `commit` given as the full sha therefore needs no network at all.

    `today` fixes the recorded capture date (UTC today by default) and
    `flavours_table` substitutes the committed flavour table; both exist for
    tests and for callers that already hold those values.
    """
    table = flavours_table if flavours_table is not None else load_flavours()
    try:
        flavour = table.by_id(flavour_id)
    except KeyError as failure:
        raise FetchError(str(failure.args[0])) from None
    repository = table.mirror.repository
    documentation_path = table.mirror.documentation_path

    if commit is not None:
        cached = _cached_capture(_capture_directory(destination, flavour.id, commit))
        if cached is not None:
            return cached

    head = _resolve_head(flavour, repository, branch, commit, transport)
    final_directory = _capture_directory(destination, flavour.id, head.commit)
    cached = _cached_capture(final_directory)
    if cached is not None:
        return cached

    files = _list_documentation_files(repository, documentation_path, head.commit, transport)
    capture = Capture(
        flavour_id=flavour.id,
        repository=repository,
        branch=head.branch,
        commit=head.commit,
        committed_at=head.committed_at,
        subject=head.subject,
        version=head.version,
        build=head.build,
        documentation_path=documentation_path,
        captured_on=_capture_date(today),
        file_count=len(files),
        directory=final_directory,
    )
    file_names = [remote_file.name for remote_file in files]

    staging = final_directory.with_name(head.commit + STAGING_SUFFIX)
    if staging.exists():
        shutil.rmtree(staging)
    staging.mkdir(parents=True)
    try:
        _download_documentation(staging, files, transport)
        _write_capture_file(staging, capture, file_names)
    except BaseException:
        shutil.rmtree(staging, ignore_errors=True)
        raise
    _replace_directory(staging, final_directory)
    return capture


def _format_head(head: BranchHead) -> str:
    version = head.version if head.version is not None else "-"
    build = str(head.build) if head.build is not None else "-"
    return f"{head.branch}  {head.commit}  {head.committed_at}  version={version}  build={build}"


def _format_provenance(capture: Capture) -> str:
    version = capture.version if capture.version is not None else "unknown version"
    build = f"build {capture.build}" if capture.build is not None else "unknown build"
    return (
        f"{capture.flavour_id}: {capture.repository}@{capture.commit} "
        f"({capture.branch}, {version}, {build}, committed {capture.committed_at}, "
        f"{capture.file_count} files, captured {capture.captured_on})"
    )


def _print_heads(flavour_id: str, table: Flavours, transport: Transport) -> None:
    """List every branch of the flavour with its head, without downloading anything."""
    flavour = table.by_id(flavour_id)
    for name in flavour.branches:
        print(_format_head(branch_head(table.mirror.repository, name, transport)))


def _build_parser() -> argparse.ArgumentParser:
    parser = argparse.ArgumentParser(
        prog="python3 -m tooling.api.fetch",
        description=(
            "Fetch one apiKit flavour's API documentation tables from the mirror "
            "at a pinned commit into a directory outside the repository."
        ),
    )
    parser.add_argument("--flavour", required=True, help="flavour id from tooling/api/flavours.json")
    parser.add_argument("--out", type=Path, help="destination directory (required unless --heads)")
    parser.add_argument("--branch", help="one of the flavour's mirror branches")
    parser.add_argument("--commit", help="pin this mirror commit instead of a branch head")
    parser.add_argument(
        "--heads",
        action="store_true",
        help="list the flavour's branch heads (commit, date, version, build) and exit",
    )
    return parser


def main(
    argv: Sequence[str] | None = None,
    *,
    transport: Transport = default_transport,
    flavours_table: Flavours | None = None,
) -> int:
    """Command line entry point; see the module docstring for the usage lines.

    `transport` and `flavours_table` are keyword-only substitutes for tests.
    Every failure is printed as `error: ...` on stderr with exit status 1.
    """
    parser = _build_parser()
    arguments = parser.parse_args(argv)
    if not arguments.heads and arguments.out is None:
        parser.error("--out is required unless --heads is given")

    try:
        table = flavours_table if flavours_table is not None else load_flavours()
        if arguments.heads:
            _print_heads(arguments.flavour, table, transport)
            return 0
        capture = fetch(
            arguments.flavour,
            arguments.out,
            branch=arguments.branch,
            commit=arguments.commit,
            transport=transport,
            flavours_table=table,
        )
    except (FetchError, KeyError, OSError, ValueError) as failure:
        message = failure.args[0] if failure.args else failure
        print(f"error: {message}", file=sys.stderr)
        return 1

    print(capture.directory)
    print(_format_provenance(capture))
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
