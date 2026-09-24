"""The apiKit flavours: one machine-readable table of what is wrapped and how.

`flavours.json` beside this module is the single source of truth for the five
client flavours `apiKit` exposes (`docs/API_KIT_DESIGN.md`, section 5). Each
entry records the flavour's id and namespace, the runtime file its generated
bindings live in, the mirror branches its documentation tables are fetched
from, and the facts the runtime facade reads to recognise that flavour. The
fetch, the generators and the facade's specs (roadmap steps H1 to H4) read this
table, so a flavour is added or renamed in one place.

    python3 -m tooling.api.flavours            # print the table

The mirror is the community `wow-ui-source` repository, which publishes the
client's interface code per flavour branch; only its
`Blizzard_APIDocumentationGenerated` tables are read, and only into a scratch
directory (design document, section 12). A flavour may name several branches
when the mirror keeps more than one test realm (`ptr` and `ptr2`); the fetch
(`tooling.api.fetch`) takes the branch whose head carries the newest build
unless told which branch to use.

Detection facts are the values a client of that flavour reports for the probes
named at the top of the table: `WOW_PROJECT_ID` (1 Retail and its test
builds, 2 Classic Era, 19 Mists of Pandaria Classic), `IsTestBuild()` (true on
the PTR and on Beta) and `IsBetaBuild()` (true on Beta only). Every flavour
states all three facts, so a client matches exactly one flavour or none; a
client matching none (a Burning Crusade Classic client, for example) gets no
surface. Both probes are documented functions of the Retail client (its
`System` tables at build 69933 list `IsTestBuild` and `IsBetaBuild`), the
only client whose project id needs them.
"""

from __future__ import annotations

import argparse
import datetime
import json
import re
import sys
from dataclasses import dataclass
from pathlib import Path
from typing import Any, Sequence

from tooling.validation.validate_manifests import ROOT


#: Location of the table relative to the repository root.
FLAVOURS_PATH = Path("tooling") / "api" / "flavours.json"

#: Default absolute location of the table, derived from the relative one so the
#: command line and the repository validator can never read different files.
DEFAULT_FLAVOURS_FILE = ROOT / FLAVOURS_PATH

#: `verified` must be a calendar date written as YYYY-MM-DD. `date.fromisoformat`
#: alone is not enough: Python 3.11 and later also accept `20260924` and week
#: dates, and the tooling runs on 3.10 and 3.13 alike.
ISO_DATE_RE = re.compile(r"^\d{4}-\d{2}-\d{2}$")

#: The keys the table itself carries, and nothing else.
TABLE_KEYS = {"verified", "mirror", "probes", "flavours"}

#: The keys of the `mirror` object.
MIRROR_KEYS = {"repository", "documentationPath"}

#: The keys of the `probes` object: the host globals the facade reads.
PROBE_KEYS = {"projectId", "testBuild", "betaBuild"}

#: The keys every flavour entry carries, and nothing else.
FLAVOUR_KEYS = {"id", "displayName", "namespace", "runtimeFile", "branches", "detection"}

#: The keys of a flavour's `detection` object.
DETECTION_KEYS = {"projectId", "testBuild", "betaBuild"}

#: A flavour id: lowercase words joined by hyphens (`classic-era`). It names
#: the metadata, types and reference directories of that flavour.
FLAVOUR_ID_RE = re.compile(r"^[a-z]+(-[a-z]+)*$")

#: A namespace path: `wow.` then lowercase segments, ending in `.api`.
NAMESPACE_RE = re.compile(r"^wow(\.[a-z]+)+\.api$")

#: A runtime file: a PascalCase Lua file inside `flavours/`, relative to the
#: package's `src/`, so `tooling.package.build.runtime_files` loads it after
#: the facade.
RUNTIME_FILE_RE = re.compile(r"^flavours/[A-Z][A-Za-z0-9]*\.lua$")

#: A mirror branch name as the mirror uses them (`classic_era`, `ptr2`).
BRANCH_RE = re.compile(r"^[a-z0-9_]+$")

#: A GitHub `owner/repository` slug.
REPOSITORY_RE = re.compile(r"^[A-Za-z0-9_.-]+/[A-Za-z0-9_.-]+$")


class FlavoursError(ValueError):
    """The table exists but does not have the shape this module documents."""


@dataclass(frozen=True)
class Detection:
    """What a client of one flavour reports for the probes in the table."""

    project_id: int
    test_build: bool
    beta_build: bool


@dataclass(frozen=True)
class Flavour:
    """One client flavour `apiKit` exposes."""

    id: str
    display_name: str
    namespace: str
    runtime_file: str
    branches: tuple[str, ...]
    detection: Detection


@dataclass(frozen=True)
class Mirror:
    """Where the documentation tables come from."""

    repository: str
    documentation_path: str


@dataclass(frozen=True)
class Probes:
    """The host globals the facade reads to recognise the running flavour."""

    project_id: str
    test_build: str
    beta_build: str


@dataclass(frozen=True)
class Flavours:
    """The whole table: when it was last checked, the mirror, the probes, the rows."""

    verified: str
    mirror: Mirror
    probes: Probes
    flavours: tuple[Flavour, ...]

    def ids(self) -> list[str]:
        """The flavour ids in table order."""
        return [flavour.id for flavour in self.flavours]

    def by_id(self, flavour_id: str) -> Flavour:
        """Return the flavour with `flavour_id`, or raise `KeyError` naming the known ids."""
        for flavour in self.flavours:
            if flavour.id == flavour_id:
                return flavour
        raise KeyError(f"unknown flavour {flavour_id!r}; known flavours: {', '.join(self.ids())}")

    def markdown_rows(self) -> list[str]:
        """Rows of the Markdown table the command line prints."""
        return [
            f"| `{flavour.id}` | {flavour.display_name} | `{flavour.namespace}` | "
            f"`{flavour.runtime_file}` | {', '.join(f'`{branch}`' for branch in flavour.branches)} |"
            for flavour in self.flavours
        ]


def _is_integer(value: Any) -> bool:
    return isinstance(value, int) and not isinstance(value, bool)


def _require_keys(where: str, entry: Any, keys: set[str]) -> dict[str, Any]:
    if not isinstance(entry, dict):
        raise FlavoursError(f"{where} must be an object")
    if set(entry) != keys:
        raise FlavoursError(f"{where} must have exactly the keys {sorted(keys)}")
    return entry


def _require_string(where: str, value: Any, pattern: re.Pattern[str] | None = None) -> str:
    if not isinstance(value, str) or not value:
        raise FlavoursError(f"{where} must be a non-empty string")
    if pattern is not None and not pattern.fullmatch(value):
        raise FlavoursError(f"{where} {value!r} does not match {pattern.pattern}")
    return value


def _parse_detection(where: str, entry: Any) -> Detection:
    fields = _require_keys(where, entry, DETECTION_KEYS)
    if not _is_integer(fields["projectId"]) or fields["projectId"] <= 0:
        raise FlavoursError(f"{where}.projectId must be a positive integer")
    for key in ("testBuild", "betaBuild"):
        if not isinstance(fields[key], bool):
            raise FlavoursError(f"{where}.{key} must be true or false")
    return Detection(
        project_id=fields["projectId"],
        test_build=fields["testBuild"],
        beta_build=fields["betaBuild"],
    )


def _parse_flavour(index: int, entry: Any) -> Flavour:
    """Validate and convert one entry of the `flavours` array."""
    where = f"flavours[{index}]"
    fields = _require_keys(where, entry, FLAVOUR_KEYS)

    branches = fields["branches"]
    if not isinstance(branches, list) or not branches:
        raise FlavoursError(f"{where}.branches must be a non-empty array")
    for position, branch in enumerate(branches):
        _require_string(f"{where}.branches[{position}]", branch, BRANCH_RE)
    if len(set(branches)) != len(branches):
        raise FlavoursError(f"{where}.branches lists the same branch twice")

    return Flavour(
        id=_require_string(f"{where}.id", fields["id"], FLAVOUR_ID_RE),
        display_name=_require_string(f"{where}.displayName", fields["displayName"]),
        namespace=_require_string(f"{where}.namespace", fields["namespace"], NAMESPACE_RE),
        runtime_file=_require_string(f"{where}.runtimeFile", fields["runtimeFile"], RUNTIME_FILE_RE),
        branches=tuple(branches),
        detection=_parse_detection(f"{where}.detection", fields["detection"]),
    )


def _reject_duplicates(flavours: Sequence[Flavour]) -> None:
    """Every id, namespace and runtime file names one flavour; detection facts too."""
    for label, values in (
        ("id", [flavour.id for flavour in flavours]),
        ("displayName", [flavour.display_name for flavour in flavours]),
        ("namespace", [flavour.namespace for flavour in flavours]),
        ("runtimeFile", [flavour.runtime_file for flavour in flavours]),
        ("detection", [flavour.detection for flavour in flavours]),
    ):
        if len(set(values)) != len(values):
            raise FlavoursError(f"flavours lists the same {label} twice")


def parse_flavours(data: Any) -> Flavours:
    """Validate the decoded JSON table and convert it to `Flavours`.

    The schema is strict for the same reason the supported-client table is: a
    typo in a key would otherwise be a silent omission in every generated file.
    """
    fields = _require_keys("table", data, TABLE_KEYS)

    verified = fields["verified"]
    if not isinstance(verified, str) or not ISO_DATE_RE.fullmatch(verified):
        raise FlavoursError("verified must be an ISO date (YYYY-MM-DD)")
    try:
        datetime.date.fromisoformat(verified)
    except ValueError:
        raise FlavoursError("verified must be a real calendar date (YYYY-MM-DD)") from None

    mirror_fields = _require_keys("mirror", fields["mirror"], MIRROR_KEYS)
    mirror = Mirror(
        repository=_require_string("mirror.repository", mirror_fields["repository"], REPOSITORY_RE),
        documentation_path=_require_string(
            "mirror.documentationPath", mirror_fields["documentationPath"]
        ),
    )

    probe_fields = _require_keys("probes", fields["probes"], PROBE_KEYS)
    probes = Probes(
        project_id=_require_string("probes.projectId", probe_fields["projectId"]),
        test_build=_require_string("probes.testBuild", probe_fields["testBuild"]),
        beta_build=_require_string("probes.betaBuild", probe_fields["betaBuild"]),
    )

    entries = fields["flavours"]
    if not isinstance(entries, list) or not entries:
        raise FlavoursError("flavours must be a non-empty array")
    flavours = tuple(_parse_flavour(index, entry) for index, entry in enumerate(entries))
    _reject_duplicates(flavours)

    return Flavours(verified=verified, mirror=mirror, probes=probes, flavours=flavours)


def load_flavours(path: Path = DEFAULT_FLAVOURS_FILE) -> Flavours:
    """Read and validate the table at `path`.

    Raises `OSError` when the file cannot be read, `json.JSONDecodeError` (a
    `ValueError`) when it is not JSON, and `FlavoursError` when its shape is
    wrong.
    """
    return parse_flavours(json.loads(path.read_text(encoding="utf-8")))


def main(argv: Sequence[str] | None = None) -> int:
    """Print the flavour table."""
    parser = argparse.ArgumentParser(
        prog="python3 -m tooling.api.flavours",
        description="Print the apiKit flavour table from tooling/api/flavours.json.",
    )
    parser.parse_args(argv)

    try:
        table = load_flavours()
    except (OSError, ValueError) as failure:
        print(f"error: {DEFAULT_FLAVOURS_FILE.name}: {failure}", file=sys.stderr)
        return 1

    print(f"Mirror: {table.mirror.repository} ({table.mirror.documentation_path})")
    print(f"Verified: {table.verified}")
    print("| Flavour | Client | Namespace | Runtime file | Mirror branches |")
    print("|---|---|---|---|---|")
    for row in table.markdown_rows():
        print(row)
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
