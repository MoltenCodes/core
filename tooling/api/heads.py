"""Compare each flavour's committed metadata with the newest build on the mirror.

    python3 -m tooling.api.heads
    python3 -m tooling.api.heads --flavour retail --flavour ptr
    python3 -m tooling.api.heads --markdown report.md --github-output "$GITHUB_OUTPUT"

`python3 -m tooling.api.fetch --heads --flavour <id>` lists one flavour's branch
heads. This command asks the same question of every flavour at once and holds
the answer against `packages/apiKit/metadata/<id>/provenance.json`: for each
flavour it looks up the head of every mirror branch the flavour names, picks
the one `fetch` would capture (`fetch.choose_branch`: the highest build), and
reports the flavour as *newer* when that build is higher than the committed
one. A head whose commit subject carries no build is never reported as newer,
because nothing says which client it describes.

The scheduled workflow `.github/workflows/api-heads.yml` runs it and keeps one
issue open while any flavour is behind; the update itself is the pipeline in
`docs/TOOLING.md` ("API metadata tooling"), run by a maintainer. Nothing is
downloaded beyond one commit lookup per branch, and nothing is written except
the files named on the command line.

Exit status: 0 when every flavour was compared (whether or not one is behind),
1 when a lookup or a provenance file failed.
"""

from __future__ import annotations

import argparse
import json
import sys
from dataclasses import dataclass
from pathlib import Path
from typing import Sequence

from tooling.api import fetch, model
from tooling.api.flavours import Flavour, Flavours, load_flavours


#: The apiKit package, whose `metadata/<flavour id>/` directories hold the
#: committed provenance.
DEFAULT_PACKAGE_DIRECTORY = Path(__file__).resolve().parents[2] / "packages" / "apiKit"


@dataclass(frozen=True)
class FlavourStatus:
    """One flavour's committed capture and the mirror head `fetch` would capture now."""

    flavour: str
    committed_branch: str
    committed_build: int | None
    head: fetch.BranchHead

    @property
    def newer(self) -> bool:
        """Whether the mirror carries a build newer than the committed one."""
        if self.head.build is None:
            return False
        return self.committed_build is None or self.head.build > self.committed_build


def read_provenance(metadata_directory: Path) -> model.Provenance:
    """Read `provenance.json` from one flavour's committed metadata directory.

    Only the provenance is read, not the whole metadata, because the build is
    all this comparison needs. Raises `model.MetadataError` naming the file.
    """
    path = metadata_directory / model.PROVENANCE_FILE
    try:
        data = json.loads(path.read_text(encoding="utf-8"))
    except (OSError, ValueError) as failure:
        raise model.MetadataError(f"{path}: cannot be read ({failure})") from None
    if not isinstance(data, dict) or data.get("schema") != model.SCHEMA_VERSION:
        raise model.MetadataError(f"{path}: expected schema {model.SCHEMA_VERSION}")
    try:
        return model.Provenance.from_json(data)
    except KeyError as failure:
        raise model.MetadataError(f"{path}: missing {failure}") from None


def flavour_status(
    flavour: Flavour,
    repository: str,
    package_directory: Path,
    transport: fetch.Transport,
) -> FlavourStatus:
    """Compare one flavour's committed provenance with the head `fetch` would choose."""
    provenance = read_provenance(package_directory / "metadata" / flavour.id)
    heads = [fetch.branch_head(repository, branch, transport) for branch in flavour.branches]
    return FlavourStatus(
        flavour=flavour.id,
        committed_branch=provenance.branch,
        committed_build=provenance.build,
        head=fetch.choose_branch(heads),
    )


def _build_text(build: int | None) -> str:
    return str(build) if build is not None else "-"


def format_line(status: FlavourStatus) -> str:
    """One line of the terminal report."""
    verdict = "newer" if status.newer else "current"
    return (
        f"{status.flavour}  committed {status.committed_branch} "
        f"{_build_text(status.committed_build)}  mirror {status.head.branch} "
        f"{_build_text(status.head.build)}  {verdict}"
    )


def render_markdown(statuses: Sequence[FlavourStatus]) -> str:
    """The issue body: one table row per flavour and the update steps.

    The text depends only on the builds and commits, never on the time of the
    run, so a scheduled run that finds nothing new produces the same body and
    the workflow leaves the issue untouched.
    """
    lines = [
        "The community mirror carries a newer client build than the metadata "
        "committed under `packages/apiKit/metadata/` for at least one flavour.",
        "",
        "| Flavour | Committed | Mirror head | Status |",
        "|---|---|---|---|",
    ]
    for status in statuses:
        verdict = "**newer**" if status.newer else "current"
        lines.append(
            f"| `{status.flavour}` | `{status.committed_branch}` "
            f"{_build_text(status.committed_build)} | `{status.head.branch}` "
            f"{_build_text(status.head.build)} (`{status.head.commit[:12]}`) | {verdict} |"
        )
    lines.extend(
        [
            "",
            "Update each newer flavour with the pipeline in "
            "[`docs/TOOLING.md`](../blob/main/docs/TOOLING.md#api-metadata-tooling):",
            "",
            "```bash",
            "python3 -m tooling.api.fetch --flavour <id> --out ~/wow-api",
            "python3 -m tooling.api.normalize --capture ~/wow-api/<id>/<sha> "
            "--out packages/apiKit/metadata/<id>",
            "python3 -m tooling.api.generate --flavour <id> --previous <previous metadata>",
            "```",
            "",
            "This issue is kept up to date by `.github/workflows/api-heads.yml` and "
            "closed by it once every flavour is current.",
        ]
    )
    return "\n".join(lines) + "\n"


def github_outputs(statuses: Sequence[FlavourStatus]) -> str:
    """The `key=value` lines the workflow reads: whether any flavour is behind, and which."""
    newer = [status.flavour for status in statuses if status.newer]
    return f"newer={'true' if newer else 'false'}\nflavours={','.join(newer)}\n"


def compare(
    flavour_ids: Sequence[str],
    table: Flavours,
    package_directory: Path,
    transport: fetch.Transport,
) -> list[FlavourStatus]:
    """Compare the named flavours, or every flavour in table order when none is named."""
    selected = flavour_ids or table.ids()
    return [
        flavour_status(table.by_id(flavour_id), table.mirror.repository, package_directory, transport)
        for flavour_id in selected
    ]


def _build_parser() -> argparse.ArgumentParser:
    parser = argparse.ArgumentParser(
        prog="python3 -m tooling.api.heads",
        description=(
            "Compare each apiKit flavour's committed metadata build with the newest "
            "build on the mirror branches it names."
        ),
    )
    parser.add_argument(
        "--flavour",
        action="append",
        default=[],
        metavar="ID",
        help="compare only this flavour; may be repeated (default: every flavour)",
    )
    parser.add_argument("--markdown", metavar="FILE", help="write the Markdown report to FILE")
    parser.add_argument(
        "--github-output", metavar="FILE", help="append newer=<true|false> and flavours=<ids> to FILE"
    )
    return parser


def main(
    argv: Sequence[str] | None = None,
    *,
    transport: fetch.Transport = fetch.default_transport,
    flavours_table: Flavours | None = None,
    package_directory: Path = DEFAULT_PACKAGE_DIRECTORY,
) -> int:
    """Command line entry point; the keyword-only arguments are substitutes for tests."""
    arguments = _build_parser().parse_args(argv)
    try:
        table = flavours_table if flavours_table is not None else load_flavours()
        statuses = compare(arguments.flavour, table, package_directory, transport)
    except (fetch.FetchError, model.MetadataError, KeyError, OSError, ValueError) as failure:
        message = failure.args[0] if failure.args else failure
        print(f"error: {message}", file=sys.stderr)
        return 1

    for status in statuses:
        print(format_line(status))
    if arguments.markdown:
        Path(arguments.markdown).write_text(render_markdown(statuses), encoding="utf-8")
    if arguments.github_output:
        with open(arguments.github_output, "a", encoding="utf-8") as handle:
            handle.write(github_outputs(statuses))
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
