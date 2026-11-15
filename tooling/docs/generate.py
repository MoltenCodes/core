"""Render the package lists the repository repeats from the package manifests.

    python3 -m tooling.docs.generate                 # print every block
    python3 -m tooling.docs.generate --check         # fail on a stale block
    python3 -m tooling.docs.generate --write         # rewrite every marked block
    python3 -m tooling.docs.generate --block kit-labels

A new Kit used to be written by hand into fourteen lists in nine files (the
package tables and indexes, the ARCHITECTURE tree and naming lists, the
packager's `move-folders`, the GitHub labels, the labeler and the two issue
forms), and the lists disagreed with each other. Each list is now a block
between markers, rendered from the manifests, so a new Kit writes its
manifest and runs `--write`.

Markers. In Markdown, a block stands on its own lines between
`<!-- generated:<name> -->` and `<!-- /generated:<name> -->`, or inline,
around a value inside a paragraph, on one line. In YAML (`.github/*.yml`,
`.pkgmeta`) it stands between `# generated:<name>` and `# /generated:<name>`
comment lines, indented like the entries they enclose. Only the text between
the markers is generated; everything around it stays hand-written, and
`--write` never adds a marker to a file.

Order. Every list uses one rule: `registry` first, then the release packages
by package ID (case-insensitive), then the development packages, so a reader
finds a Kit by name.

Purpose text. A package's line in an index is its manifest `summary` (one
sentence, `tooling.validation.validate_manifests.summary_problems`), or its
`description` when it has none.

Repository validation runs the same comparison (`stale_block_errors`) and
prints the block to put in place of a stale or missing one
(`MARKERS_REQUIRED`).
"""

from __future__ import annotations

import argparse
import re
import sys
from dataclasses import dataclass
from pathlib import Path
from typing import Any, Callable, Sequence

from tooling.validation.validate_manifests import ROOT, is_development, load_manifests

#: When true, a file without the markers of one of its blocks fails the check,
#: so a removed marker cannot go unnoticed. Every listed file carries its
#: markers; a fixture that tests the unmarked case sets it to false.
MARKERS_REQUIRED = True

#: The infrastructure package listed first everywhere.
REGISTRY = "registry"

#: The packager's addon folder, the prefix of every `move-folders` entry.
PKGMETA_ADDON = "MoltenCodes"

#: The colour of every `kit: <id>` label (`.github/labels.yml`, "Colours group the labels").
KIT_LABEL_COLOUR = "5319e7"

#: English words for the counts a README sentence spells out.
_UNITS = (
    "zero one two three four five six seven eight nine ten eleven twelve thirteen "
    "fourteen fifteen sixteen seventeen eighteen nineteen"
).split()
_TENS = "_ _ twenty thirty forty fifty sixty seventy eighty ninety".split()


class GenerateError(ValueError):
    """The manifests cannot be loaded, or a marker in a file is malformed."""


@dataclass(frozen=True)
class Package:
    """What a generated list needs to know about one package."""

    name: str
    display_name: str
    purpose: str
    development: bool


@dataclass(frozen=True)
class Block:
    """One generated block: which file carries it, its marker style and how to render it."""

    name: str
    path: Path
    style: str  # "markdown" (own lines), "inline" (inside one Markdown line) or "yaml"
    render: Callable[[Sequence[Package]], str]


# Numbers and order -----------------------------------------------------------------


def number_in_words(number: int) -> str:
    """Spell `number` (0 to 99) in English words, `41` as `forty-one`."""
    if not 0 <= number < 100:
        raise GenerateError(f"cannot spell {number} in words")
    if number < 20:
        return _UNITS[number]
    tens, units = divmod(number, 10)
    return _TENS[tens] + (f"-{_UNITS[units]}" if units else "")


def ordered_packages(manifests: dict[str, dict[str, Any]]) -> list[Package]:
    """Return every package in the one order all lists use."""
    packages = [
        Package(
            name=name,
            display_name=str(data["displayName"]),
            purpose=str(data.get("summary") or data["description"]),
            development=is_development(data),
        )
        for name, data in manifests.items()
    ]

    def key(package: Package) -> tuple[int, str]:
        if package.name == REGISTRY:
            return (0, "")
        return (2 if package.development else 1, package.name.lower())

    return sorted(packages, key=key)


def release_packages(packages: Sequence[Package]) -> list[Package]:
    """The packages that ship in a release, in list order."""
    return [package for package in packages if not package.development]


# Renderers ----------------------------------------------------------------------------


def render_package_table(packages: Sequence[Package]) -> str:
    """The root README's package table."""
    lines = ["| Package | Purpose |", "|---|---|"]
    lines.extend(
        f"| [`{package.name}`](packages/{package.name}/) | {package.purpose} |"
        for package in packages
    )
    return "\n".join(lines) + "\n"


def render_package_total(packages: Sequence[Package]) -> str:
    """The number of packages, in figures, for an inline count."""
    return str(len(packages))


def render_package_count_sentence(packages: Sequence[Package]) -> str:
    """`Forty-one release packages and one development package.`"""
    release = len(release_packages(packages))
    development = len(packages) - release

    def phrase(count: int, kind: str) -> str:
        noun = "package" if count == 1 else "packages"
        return f"{number_in_words(count)} {kind} {noun}"

    sentence = phrase(release, "release")
    if development:
        sentence += " and " + phrase(development, "development")
    return sentence[0].upper() + sentence[1:] + "."


def render_documentation_index(packages: Sequence[Package]) -> str:
    """The package entry points of `docs/README.md`."""
    return "".join(
        f"- [`{package.display_name}`](../packages/{package.name}/README.md) — {package.purpose}\n"
        for package in packages
    )


def render_package_index(packages: Sequence[Package]) -> str:
    """The package list of `packages/README.md`."""
    return "".join(
        f"- [`{package.name}`]({package.name}/) — {package.purpose}\n" for package in packages
    )


def render_package_tree(packages: Sequence[Package]) -> str:
    """The `packages/` tree at the top of `docs/ARCHITECTURE.md`, fence included."""
    lines = ["```text", "packages/"]
    lines.extend(f"├── {package.name}/" for package in packages)
    lines.extend(["├── <future-package>/", "└── ...", "```"])
    return "\n".join(lines) + "\n"


def _kits(packages: Sequence[Package]) -> list[Package]:
    """Every package except the infrastructure exception, for the naming lists."""
    return [package for package in packages if package.name != REGISTRY]


def render_package_ids(packages: Sequence[Package]) -> str:
    """The inline list of Kit IDs in ARCHITECTURE's "Package naming"."""
    return ", ".join(f"`{package.name}`" for package in _kits(packages))


def render_facade_names(packages: Sequence[Package]) -> str:
    """The inline list of facade names in ARCHITECTURE's "Package naming"."""
    return ", ".join(f"`{package.display_name}`" for package in _kits(packages))


def render_move_folders(packages: Sequence[Package]) -> str:
    """The `.pkgmeta` `move-folders` entries: every release package's `src` and `docs`."""
    lines: list[str] = []
    for package in release_packages(packages):
        lines.append(
            f"  {PKGMETA_ADDON}/packages/{package.name}/src: {PKGMETA_ADDON}/{package.name}"
        )
        lines.append(
            f"  {PKGMETA_ADDON}/packages/{package.name}/docs: "
            f"{PKGMETA_ADDON}/{package.name}/docs"
        )
    return "\n".join(lines) + "\n"


def render_kit_labels(packages: Sequence[Package]) -> str:
    """The `kit: <id>` labels of `.github/labels.yml`."""
    lines: list[str] = []
    for package in packages:
        lines.extend(
            [
                f'- name: "kit: {package.name}"',
                f'  color: "{KIT_LABEL_COLOUR}"',
                f'  description: "The {package.name} package."',
            ]
        )
    return "\n".join(lines) + "\n"


def render_kit_labeler(packages: Sequence[Package]) -> str:
    """The per-package rules of `.github/labeler.yml`, one blank line after each."""
    lines: list[str] = []
    for package in packages:
        lines.extend(
            [
                f'"kit: {package.name}":',
                "  - changed-files:",
                f'      - any-glob-to-any-file: "packages/{package.name}/**"',
                "",
            ]
        )
    return "\n".join(lines) + "\n"


def render_kit_options(packages: Sequence[Package]) -> str:
    """The package options of an issue form's Kit dropdown."""
    return "".join(f"        - {package.name}\n" for package in packages)


#: Every generated block, by file. A name may appear in several files.
BLOCKS: tuple[Block, ...] = (
    Block("package-total", Path("README.md"), "inline", render_package_total),
    Block("package-count-sentence", Path("README.md"), "inline", render_package_count_sentence),
    Block("package-table", Path("README.md"), "markdown", render_package_table),
    Block("package-index", Path("docs/README.md"), "markdown", render_documentation_index),
    Block("package-index", Path("packages/README.md"), "markdown", render_package_index),
    Block("package-tree", Path("docs/ARCHITECTURE.md"), "markdown", render_package_tree),
    Block("package-ids", Path("docs/ARCHITECTURE.md"), "inline", render_package_ids),
    Block("facade-names", Path("docs/ARCHITECTURE.md"), "inline", render_facade_names),
    Block("move-folders", Path(".pkgmeta"), "yaml", render_move_folders),
    Block("kit-labels", Path(".github/labels.yml"), "yaml", render_kit_labels),
    Block("kit-labeler", Path(".github/labeler.yml"), "yaml", render_kit_labeler),
    Block("kit-options", Path(".github/ISSUE_TEMPLATE/bug_report.yml"), "yaml", render_kit_options),
    Block(
        "kit-options",
        Path(".github/ISSUE_TEMPLATE/feature_request.yml"),
        "yaml",
        render_kit_options,
    ),
)


# Markers --------------------------------------------------------------------------------


def _marker_patterns(block: Block) -> re.Pattern[str]:
    """The pattern that finds every occurrence of a block in its file's text."""
    name = re.escape(block.name)
    if block.style == "inline":
        return re.compile(rf"(<!-- generated:{name} -->)(.*?)(<!-- /generated:{name} -->)")
    if block.style == "markdown":
        return re.compile(
            rf"(^<!-- generated:{name} -->\n)(.*?)(^<!-- /generated:{name} -->$)",
            re.MULTILINE | re.DOTALL,
        )
    return re.compile(
        rf"(^[ \t]*# generated:{name}[ \t]*\n)(.*?)(^[ \t]*# /generated:{name}[ \t]*$)",
        re.MULTILINE | re.DOTALL,
    )


def marked(block: Block, body: str) -> str:
    """Return `body` between the block's markers, as it should stand in the file.

    YAML markers are indented like the entries the block holds.
    """
    if block.style == "inline":
        return f"<!-- generated:{block.name} -->{body}<!-- /generated:{block.name} -->"
    if block.style == "markdown":
        return f"<!-- generated:{block.name} -->\n{body}<!-- /generated:{block.name} -->\n"
    first = next((line for line in body.splitlines() if line.strip()), "")
    indent = first[: len(first) - len(first.lstrip())]
    return f"{indent}# generated:{block.name}\n{body}{indent}# /generated:{block.name}\n"


def read_bodies(block: Block, text: str) -> list[str]:
    """Return the text between each pair of the block's markers in `text`."""
    if block.style != "inline":
        begin = f"generated:{block.name}"
        opened = len(re.findall(rf"(?:<!--|#) {re.escape(begin)}\b", text))
        closed = len(re.findall(rf"(?:<!--|#) /{re.escape(begin)}\b", text))
        if opened != closed:
            raise GenerateError(f'unbalanced "{block.name}" markers')
    return [match.group(2) for match in _marker_patterns(block).finditer(text)]


def replace_bodies(block: Block, text: str, body: str) -> str:
    """Return `text` with every occurrence of the block holding `body`."""
    pattern = _marker_patterns(block)
    return pattern.sub(lambda match: match.group(1) + body + match.group(3), text)


# Checking and writing --------------------------------------------------------------------


@dataclass(frozen=True)
class Finding:
    """One block that is stale or not marked yet in its file."""

    block: Block
    expected: str
    marked: bool  # False when the file has no markers for the block

    def message(self) -> str:
        """The problem and the exact text to put in place."""
        where = self.block.path.as_posix()
        if not self.marked:
            return (
                f'{where}: has no generated "{self.block.name}" block; put this in place of the '
                f"hand-written list:\n{marked(self.block, self.expected)}"
            )
        return (
            f'{where}: has a stale generated "{self.block.name}" block; put this in its '
            f"place:\n{marked(self.block, self.expected)}"
        )


def load_packages() -> list[Package]:
    """Load the manifests, or raise `GenerateError` naming what is wrong."""
    manifests, errors = load_manifests()
    if errors:
        raise GenerateError("package manifests are invalid:\n  - " + "\n  - ".join(errors))
    return ordered_packages(manifests)


def findings(packages: Sequence[Package], root: Path = ROOT) -> list[Finding]:
    """Compare every block of every file with what the manifests render."""
    found: list[Finding] = []
    for block in BLOCKS:
        path = root / block.path
        if not path.is_file():
            continue
        expected = block.render(packages)
        bodies = read_bodies(block, path.read_text(encoding="utf-8"))
        if not bodies:
            found.append(Finding(block, expected, marked=False))
        elif any(body != expected for body in bodies):
            found.append(Finding(block, expected, marked=True))
    return found


def stale_block_errors(packages: Sequence[Package], root: Path = ROOT) -> list[str]:
    """The messages repository validation fails on: stale blocks, and unmarked ones when required."""
    return [
        finding.message()
        for finding in findings(packages, root)
        if finding.marked or MARKERS_REQUIRED
    ]


def write_blocks(packages: Sequence[Package], root: Path = ROOT) -> list[Path]:
    """Rewrite every marked block in place; return the files that changed."""
    changed: list[Path] = []
    for block in BLOCKS:
        path = root / block.path
        if not path.is_file():
            continue
        text = path.read_text(encoding="utf-8")
        if not read_bodies(block, text):
            continue
        updated = replace_bodies(block, text, block.render(packages))
        if updated != text:
            path.write_text(updated, encoding="utf-8")
            if path not in changed:
                changed.append(path)
    return changed


# Command line ------------------------------------------------------------------------------


def parse_args(argv: Sequence[str] | None = None) -> argparse.Namespace:
    """Read the command line."""
    parser = argparse.ArgumentParser(
        prog="python3 -m tooling.docs.generate",
        description=(
            "Render the package lists between generated markers from the package "
            "manifests. See docs/TOOLING.md."
        ),
    )
    mode = parser.add_mutually_exclusive_group()
    mode.add_argument(
        "--check", action="store_true", help="write nothing; fail when a marked block is stale"
    )
    mode.add_argument(
        "--write", action="store_true", help="rewrite every marked block from the manifests"
    )
    parser.add_argument(
        "--block",
        action="append",
        default=[],
        metavar="NAME",
        help="print only this block (repeatable): "
        + ", ".join(sorted({block.name for block in BLOCKS})),
    )
    return parser.parse_args(argv)


def main(argv: Sequence[str] | None = None) -> int:
    """Run the command; return the process exit status."""
    arguments = parse_args(argv)
    try:
        packages = load_packages()
        if arguments.write:
            for path in write_blocks(packages):
                print(f"updated {path.relative_to(ROOT).as_posix()}")
            return 0
        if arguments.check:
            problems = findings(packages)
            failed = False
            for finding in problems:
                print(finding.message(), file=sys.stderr)
                failed = failed or finding.marked or MARKERS_REQUIRED
            if not problems:
                print("every generated package list is current")
            return 1 if failed else 0
    except GenerateError as failure:
        print(f"tooling.docs.generate: {failure}", file=sys.stderr)
        return 1

    wanted = set(arguments.block)
    unknown = wanted - {block.name for block in BLOCKS}
    if unknown:
        print(f"unknown block {', '.join(sorted(unknown))}", file=sys.stderr)
        return 2
    for block in BLOCKS:
        if wanted and block.name not in wanted:
            continue
        print(f"# {block.path.as_posix()}")
        print(marked(block, block.render(packages)))
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
