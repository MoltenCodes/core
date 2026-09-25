"""Fetch Ace3 at the pinned commit into a cache outside the repository.

The benchmark compares Kits with the Ace3 libraries, so it needs Ace3's source
on disk. Ace3 is never vendored or committed: its licence forbids
redistributing a stand-alone copy without written permission (see
`docs/BENCHMARKS.md`, "Ace3 licence"), and a pinned download is reproducible
anyway. The module therefore:

- downloads the source archive of exactly `ACE3_COMMIT` from GitHub;
- extracts it into `<cache>/ace3/<commit>/`, where `<cache>` is
  `$MOLTENCODES_BENCH_CACHE`, else `$XDG_CACHE_HOME/moltencodes-bench`, else
  `~/.cache/moltencodes-bench`, and refuses a cache inside the repository;
- checks a SHA-256 digest over the files the benchmark loads
  (`LOADED_FILES`) against `EXPECTED_CONTENT_DIGEST`, so a changed upstream
  archive can never change what is measured without failing loudly;
- records where the files came from in `fetch.json` beside them, and trusts a
  directory that already holds a matching `fetch.json` instead of downloading
  again.

Network access goes through one `Transport` function, so the unit tests
substitute an in-memory archive and never touch the network.

    python3 -m tooling.bench.ace3 [--cache DIR]
"""

from __future__ import annotations

import argparse
import datetime
import hashlib
import io
import json
import os
import shutil
import sys
import tarfile
import urllib.request
from dataclasses import dataclass
from pathlib import Path
from typing import Callable, Sequence

ROOT = Path(__file__).resolve().parents[2]

#: The upstream repository the benchmark compares against.
ACE3_REPOSITORY = "WoWUIDev/Ace3"

#: The pinned commit. Changing it is a deliberate edit, together with
#: `EXPECTED_CONTENT_DIGEST` and a new results file.
ACE3_COMMIT = "5e2e0d3b3fd125ef1518744c6a9dd21f68f6e773"

#: The files the Lua side loads, plus the licence, relative to the Ace3 root.
#: Only these are hashed; the rest of the archive is extracted but unused.
LOADED_FILES: tuple[str, ...] = (
    "LICENSE.txt",
    "LibStub/LibStub.lua",
    "CallbackHandler-1.0/CallbackHandler-1.0.lua",
    "AceEvent-3.0/AceEvent-3.0.lua",
    "AceTimer-3.0/AceTimer-3.0.lua",
    "AceDB-3.0/AceDB-3.0.lua",
    "AceSerializer-3.0/AceSerializer-3.0.lua",
    "AceComm-3.0/ChatThrottleLib.lua",
    "AceComm-3.0/AceComm-3.0.lua",
)

#: SHA-256 over `LOADED_FILES` at `ACE3_COMMIT`, as `content_digest` computes it.
EXPECTED_CONTENT_DIGEST = "a967f70be11d2996ed841ad6fe9466364f91f9f431cb3c2587d65b17659e29c7"

#: The provenance file written beside an extracted copy.
PROVENANCE_NAME = "fetch.json"

#: A function that GETs a URL and returns the response body.
Transport = Callable[[str], bytes]


class FetchError(Exception):
    """The pinned Ace3 source could not be fetched, placed or verified."""


@dataclass(frozen=True)
class Ace3Source:
    """An extracted, verified Ace3 checkout and where it came from."""

    directory: Path
    commit: str
    archive_url: str
    archive_sha256: str
    content_digest: str
    fetched: str

    def as_json(self) -> dict[str, str]:
        """The provenance as a JSON object; `directory` is left out on purpose.

        The cache path is machine-specific and says nothing about what was
        measured, so it never enters a committed results file.
        """
        return {
            "repository": ACE3_REPOSITORY,
            "commit": self.commit,
            "archiveUrl": self.archive_url,
            "archiveSha256": self.archive_sha256,
            "contentDigest": self.content_digest,
            "fetched": self.fetched,
        }


def archive_url(commit: str = ACE3_COMMIT) -> str:
    """The GitHub source-archive URL of `commit`."""
    return f"https://codeload.github.com/{ACE3_REPOSITORY}/tar.gz/{commit}"


def default_cache_root(environment: dict[str, str] | None = None) -> Path:
    """The cache root: `$MOLTENCODES_BENCH_CACHE`, then the XDG cache, then `~/.cache`."""
    environment = dict(os.environ) if environment is None else environment
    explicit = environment.get("MOLTENCODES_BENCH_CACHE")
    if explicit:
        return Path(explicit).expanduser()
    xdg = environment.get("XDG_CACHE_HOME")
    if xdg:
        return Path(xdg).expanduser() / "moltencodes-bench"
    return Path.home() / ".cache" / "moltencodes-bench"


def ensure_outside_repository(path: Path, repository: Path = ROOT) -> None:
    """Refuse a cache location inside the repository, where it could be committed."""
    resolved = path.resolve()
    if resolved == repository.resolve() or repository.resolve() in resolved.parents:
        raise FetchError(
            f"the Ace3 cache must live outside the repository, not in {resolved}; "
            "set MOLTENCODES_BENCH_CACHE or pass --cache"
        )


def content_digest(directory: Path, files: Sequence[str] = LOADED_FILES) -> str:
    """SHA-256 over each listed file's relative path and bytes, in the given order.

    The path is hashed with its length, so moving bytes from one file to the
    next can never produce the same digest.
    """
    digest = hashlib.sha256()
    for relative in files:
        path = directory / relative
        if not path.is_file():
            raise FetchError(f"Ace3 checkout at {directory} lacks {relative}")
        data = path.read_bytes()
        encoded = relative.encode("utf-8")
        digest.update(len(encoded).to_bytes(4, "big"))
        digest.update(encoded)
        digest.update(len(data).to_bytes(8, "big"))
        digest.update(data)
    return digest.hexdigest()


def default_transport(url: str) -> bytes:
    """GET `url` with the standard library and return the body."""
    request = urllib.request.Request(url, headers={"User-Agent": "moltencodes-bench"})
    with urllib.request.urlopen(request, timeout=60) as response:  # noqa: S310 - fixed https URL
        return response.read()


def safe_members(archive: tarfile.TarFile) -> tuple[str, list[tarfile.TarInfo]]:
    """Return the archive's single top directory and its regular files and directories.

    Links, devices and any member that would land outside the top directory
    are refused rather than skipped: a pinned archive has none, so seeing one
    means the bytes are not what was pinned.
    """
    members = archive.getmembers()
    if not members:
        raise FetchError("the Ace3 archive is empty")
    top = members[0].name.split("/", 1)[0]
    accepted: list[tarfile.TarInfo] = []
    for member in members:
        name = member.name
        parts = Path(name).parts
        if name.startswith("/") or ".." in parts or not parts or parts[0] != top:
            raise FetchError(f"the Ace3 archive holds an unsafe path: {name!r}")
        if member.isdir() or member.isfile():
            accepted.append(member)
        elif member.type == tarfile.XGLTYPE or member.type == tarfile.XHDTYPE:
            continue
        else:
            raise FetchError(f"the Ace3 archive holds a link or special file: {name!r}")
    return top, accepted


def extract_archive(data: bytes, destination: Path) -> None:
    """Extract a `.tar.gz` source archive's top directory into `destination`."""
    try:
        archive = tarfile.open(fileobj=io.BytesIO(data), mode="r:gz")
    except (tarfile.TarError, OSError) as problem:
        raise FetchError(f"the Ace3 archive could not be read: {problem}") from problem
    with archive:
        top, members = safe_members(archive)
        for member in members:
            relative = Path(member.name).relative_to(top)
            target = destination / relative
            if member.isdir():
                target.mkdir(parents=True, exist_ok=True)
                continue
            target.parent.mkdir(parents=True, exist_ok=True)
            source = archive.extractfile(member)
            if source is None:
                raise FetchError(f"the Ace3 archive member {member.name!r} has no data")
            with source:
                target.write_bytes(source.read())


def read_provenance(directory: Path) -> Ace3Source | None:
    """Return the recorded source of a cached checkout, or `None` when unusable."""
    path = directory / PROVENANCE_NAME
    if not path.is_file():
        return None
    try:
        recorded = json.loads(path.read_text(encoding="utf-8"))
        return Ace3Source(
            directory=directory,
            commit=recorded["commit"],
            archive_url=recorded["archiveUrl"],
            archive_sha256=recorded["archiveSha256"],
            content_digest=recorded["contentDigest"],
            fetched=recorded["fetched"],
        )
    except (OSError, ValueError, KeyError, TypeError):
        return None


def fetch_ace3(
    cache_root: Path | None = None,
    transport: Transport = default_transport,
    expected_digest: str = EXPECTED_CONTENT_DIGEST,
    today: datetime.date | None = None,
) -> Ace3Source:
    """Return the pinned Ace3 checkout, downloading and verifying it when needed.

    A cached checkout is reused only when its `fetch.json` names the pinned
    commit and the files on disk still hash to `expected_digest`. A fresh
    download is extracted into a staging directory and renamed into place only
    after it verified, so an interrupted run never leaves a half checkout that
    the reuse rule would trust.
    """
    root = default_cache_root() if cache_root is None else cache_root
    ensure_outside_repository(root)
    directory = root / "ace3" / ACE3_COMMIT

    cached = read_provenance(directory)
    if cached is not None and cached.commit == ACE3_COMMIT:
        if content_digest(directory) == expected_digest:
            return cached

    url = archive_url()
    try:
        data = transport(url)
    except OSError as problem:
        raise FetchError(f"downloading {url} failed: {problem}") from problem

    staging = directory.with_name(directory.name + ".partial")
    shutil.rmtree(staging, ignore_errors=True)
    staging.mkdir(parents=True)
    try:
        extract_archive(data, staging)
        digest = content_digest(staging)
        if digest != expected_digest:
            raise FetchError(
                f"Ace3 at {ACE3_COMMIT} hashed to {digest}, expected {expected_digest}; "
                "the archive is not the pinned source"
            )
        source = Ace3Source(
            directory=directory,
            commit=ACE3_COMMIT,
            archive_url=url,
            archive_sha256=hashlib.sha256(data).hexdigest(),
            content_digest=digest,
            fetched=(today or datetime.date.today()).isoformat(),
        )
        (staging / PROVENANCE_NAME).write_text(
            json.dumps(source.as_json(), indent=2) + "\n", encoding="utf-8"
        )
        shutil.rmtree(directory, ignore_errors=True)
        staging.rename(directory)
    except BaseException:
        shutil.rmtree(staging, ignore_errors=True)
        raise
    return source


def parse_args(argv: Sequence[str] | None = None) -> argparse.Namespace:
    """Parse the command line."""
    parser = argparse.ArgumentParser(
        prog="python3 -m tooling.bench.ace3",
        description=(
            f"Fetch {ACE3_REPOSITORY} at {ACE3_COMMIT[:12]} into the benchmark cache "
            "(outside the repository) and print its directory."
        ),
    )
    parser.add_argument(
        "--cache",
        type=Path,
        default=None,
        help="cache root (default: $MOLTENCODES_BENCH_CACHE, $XDG_CACHE_HOME or ~/.cache)",
    )
    return parser.parse_args(argv)


def main(argv: Sequence[str] | None = None) -> int:
    """Fetch the pinned Ace3 and print where it is."""
    arguments = parse_args(argv)
    try:
        source = fetch_ace3(arguments.cache)
    except FetchError as problem:
        print(f"error: {problem}", file=sys.stderr)
        return 1
    print(source.directory)
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
