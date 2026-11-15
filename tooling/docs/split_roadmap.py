"""Move the nine-point records out of `docs/ROADMAP.md`, one file per package.

    python3 -m tooling.docs.split_roadmap            # print the plan, change nothing
    python3 -m tooling.docs.split_roadmap --write    # move the records

ROADMAP is the plan, the archive of every nine-point record and the status
at once, so every new Kit or capability writes into the same file and work
queues on it. This command moves each record, byte for byte, into
`docs/records/<package>.md` (records of repository tooling into
`docs/records/tooling.md`), and leaves in ROADMAP, where each run of records
stood, a table with one row per record: its title, package, status (the
first clause of its point 9) and a link. Every other line of ROADMAP stays
as it is.

A record is a line `**<title>** — <kind>` followed by its numbered points
and anything after them (an appendix such as a data table), up to the next
record, heading or `---` line. It belongs to the package whose facade its
kind names (`— a change to facade \\`SettingsKit\\``), else to the package its
title starts with (`**settingsKit read-through views**`), else to `tooling`
when its kind is tooling, test support, packaging or documentation. A record
that matches none stops the run and is named, so nothing is guessed.

The split runs once, when nobody else is editing ROADMAP. `check_records`
(in repository validation once `docs/records/` exists) then holds every
record file to being linked from ROADMAP and every record to having points 1
to 9.
"""

from __future__ import annotations

import argparse
import re
import sys
from dataclasses import dataclass, field
from pathlib import Path
from typing import Sequence

from tooling.validation.validate_manifests import ROOT, load_manifests

#: The documents, relative to the repository root.
ROADMAP_PATH = Path("docs") / "ROADMAP.md"
RECORDS_DIRECTORY = Path("docs") / "records"

#: The record file of everything that is not one package's.
TOOLING_RECORDS = "tooling"

#: The first line of a record.
RECORD_START_RE = re.compile(r"^\*\*(?P<title>.+?)\*\* — (?P<kind>.+)$")

#: A facade named in a record's kind.
KIND_FACADE_RE = re.compile(r"facade `(?P<facade>[A-Za-z]+)`")

#: Words in a record's kind that make it a tooling record.
TOOLING_KINDS = ("tooling", "test support", "packaging", "documentation")

#: A thematic break, which ends a record like a heading does.
SEPARATOR = "---"

#: A record's numbered point, `1.` to `9.`, at the start of a line.
POINT_RE = re.compile(r"^(?P<number>[1-9])\. ", re.M)

#: The status point.
STATUS_RE = re.compile(r"^9\. Status: (?P<status>.+?)(?:[;:]|\.(?:\s|$))", re.M | re.S)


class SplitError(ValueError):
    """A record cannot be placed, or the result would not reproduce ROADMAP."""


@dataclass
class Record:
    """One nine-point record and where it goes."""

    title: str
    kind: str
    lines: list[str]
    start: int  # index of its first line in ROADMAP
    package: str = ""
    section: str = ""

    @property
    def text(self) -> str:
        return "".join(self.lines)

    def status(self) -> str:
        """The first clause of point 9, on one line."""
        match = STATUS_RE.search(self.text)
        if match is None:
            return "no status"
        return " ".join(match.group("status").split())

    def anchor(self) -> str:
        """The GitHub anchor of the heading the record file gives the record."""
        slug = re.sub(r"[^\w\- ]", "", self.title.replace("`", "").lower())
        return slug.strip().replace(" ", "-")


@dataclass
class Split:
    """The result: the new ROADMAP text and each record file's text."""

    roadmap: str
    files: dict[str, str] = field(default_factory=dict)
    records: list[Record] = field(default_factory=list)


def find_records(lines: Sequence[str]) -> list[Record]:
    """Every record of ROADMAP, with the heading it stands under."""
    records: list[Record] = []
    section = ""
    current: Record | None = None
    for index, line in enumerate(lines):
        if line.startswith("#"):
            current = None
            section = line.lstrip("#").strip()
            continue
        if line.strip() == SEPARATOR:
            current = None
            continue
        match = RECORD_START_RE.match(line.rstrip("\n"))
        if match:
            current = Record(match.group("title"), match.group("kind"), [line], index, section=section)
            records.append(current)
            continue
        # Everything up to the next record, heading or separator is the
        # record's: an appendix after point 9 (rangeKit's spell table, say)
        # travels with it.
        if current is not None:
            current.lines.append(line)
    # Trailing blank lines belong to the text between records, not to a record.
    for record in records:
        while len(record.lines) > 1 and not record.lines[-1].strip():
            record.lines.pop()
    return records


def assign_package(record: Record, facades: dict[str, str], packages: set[str]) -> str:
    """The package a record belongs to, or raise naming the record."""
    facade = KIND_FACADE_RE.search(record.kind)
    if facade and facade.group("facade") in facades:
        return facades[facade.group("facade")]
    first = record.title.replace("`", "").split()[0] if record.title.strip() else ""
    if first in packages:
        return first
    if any(word in record.kind for word in TOOLING_KINDS):
        return TOOLING_RECORDS
    raise SplitError(f'cannot tell whose record "{record.title}" ({record.kind}) is')


def render_table(records: Sequence[Record]) -> list[str]:
    """The table that stands in ROADMAP where a run of records stood."""
    lines = ["| Record | Package | Status |\n", "|---|---|---|\n"]
    for record in records:
        title = record.title.replace("|", "\\|")
        link = f"records/{record.package}.md#{record.anchor()}"
        lines.append(f"| [{title}]({link}) | `{record.package}` | {record.status()} |\n")
    return lines


def split(text: str, facades: dict[str, str], packages: set[str]) -> Split:
    """Split ROADMAP's text into the new ROADMAP and the record files."""
    lines = text.splitlines(keepends=True)
    records = find_records(lines)
    for record in records:
        record.package = assign_package(record, facades, packages)

    covered: dict[int, Record] = {}
    for record in records:
        for offset in range(len(record.lines)):
            covered[record.start + offset] = record

    roadmap: list[str] = []
    index = 0
    while index < len(lines):
        if index not in covered:
            roadmap.append(lines[index])
            index += 1
            continue
        # A run of records: consecutive records separated only by blank lines.
        run: list[Record] = []
        while index < len(lines):
            if index in covered:
                record = covered[index]
                run.append(record)
                index = record.start + len(record.lines)
            elif not lines[index].strip() and any(
                position in covered for position in range(index, min(index + 3, len(lines)))
            ):
                index += 1
            else:
                break
        roadmap.extend(render_table(run))
        roadmap.append("\n")

    files: dict[str, list[str]] = {}
    for record in records:
        body = files.setdefault(record.package, [f"# {record.package} records\n", "\n"])
        body += [
            f"Moved from `docs/ROADMAP.md` ({record.section}).\n" if record.section else "",
            "\n",
            f"## {record.title.replace('`', '')}\n",
            "\n",
            *record.lines,
            "\n",
        ]
    return Split(
        roadmap="".join(roadmap),
        files={name: "".join(body) for name, body in files.items()},
        records=records,
    )


def check_records(root: Path = ROOT) -> list[str]:
    """Problems with `docs/records/`: unlinked files and records without points 1 to 9."""
    directory = root / RECORDS_DIRECTORY
    if not directory.is_dir():
        return []
    roadmap = (root / ROADMAP_PATH).read_text(encoding="utf-8")
    problems: list[str] = []
    for path in sorted(directory.glob("*.md")):
        if f"records/{path.name}" not in roadmap:
            problems.append(f"{ROADMAP_PATH}: does not link records/{path.name}")
        for record in find_records(path.read_text(encoding="utf-8").splitlines(keepends=True)):
            numbers = {int(number) for number in POINT_RE.findall(record.text)}
            missing = sorted(set(range(1, 10)) - numbers)
            if missing:
                problems.append(
                    f"{RECORDS_DIRECTORY / path.name}: record \"{record.title}\" lacks point(s) "
                    + ", ".join(str(number) for number in missing)
                )
    return problems


def package_facades() -> tuple[dict[str, str], set[str]]:
    """Each facade name's package ID, and the package IDs."""
    manifests, errors = load_manifests()
    if errors:
        raise SplitError("package manifests are invalid: " + "; ".join(errors))
    facades = {str(data["displayName"]): name for name, data in manifests.items()}
    return facades, set(manifests)


def parse_args(argv: Sequence[str] | None = None) -> argparse.Namespace:
    """Read the command line."""
    parser = argparse.ArgumentParser(
        prog="python3 -m tooling.docs.split_roadmap",
        description="Move ROADMAP's nine-point records into docs/records/. See docs/TOOLING.md.",
    )
    parser.add_argument("--write", action="store_true", help="write the files (default: print the plan)")
    return parser.parse_args(argv)


def main(argv: Sequence[str] | None = None) -> int:
    """Run the command; return the process exit status."""
    arguments = parse_args(argv)
    try:
        facades, packages = package_facades()
        result = split((ROOT / ROADMAP_PATH).read_text(encoding="utf-8"), facades, packages)
    except SplitError as failure:
        print(f"tooling.docs.split_roadmap: {failure}", file=sys.stderr)
        return 1
    for record in result.records:
        print(f"{record.start + 1:>5}  {record.package:<14} {record.title}")
    print(
        f"{len(result.records)} records into {len(result.files)} files; ROADMAP "
        f"{len(result.roadmap.splitlines())} lines"
    )
    if not arguments.write:
        print("nothing written; pass --write to move them")
        return 0
    directory = ROOT / RECORDS_DIRECTORY
    directory.mkdir(parents=True, exist_ok=True)
    for name, text in result.files.items():
        (directory / f"{name}.md").write_text(text, encoding="utf-8")
    (ROOT / ROADMAP_PATH).write_text(result.roadmap, encoding="utf-8")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
