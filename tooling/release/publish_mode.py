"""Decide how the release workflow's `publish` job may publish.

    python3 -m tooling.release.publish_mode --kind package --dry-run-input false \\
        --ref-type tag --ref-name timerKit-v0.6.0 --tag timerKit-v0.6.0 \\
        --github-output "$GITHUB_OUTPUT"

The rules live here rather than in YAML so they are unit-tested. See
`docs/RELEASES.md`, "Dry run":

- The packager runs with `-d` (package, upload nothing) when the run was
  started by hand with `dry_run` on, when any of the site variables
  `CURSEFORGE_PROJECT_ID`, `WAGO_ID`, `WOWI_ID` is unset, or when the tag is a
  package tag. A package tag never uploads in this version, because the addon
  sites carry one project, the bundle; whether each Kit gets a project of its
  own is decided later.
- A draft GitHub release is created only when the run's ref is a tag and it is
  the tag being released, so the assets attached to it were built from that
  tag's tree. That holds for a pushed tag and for a hand-started run from a tag
  ref, which lets a dry run be inspected end to end.

The site variables are read from the environment, where the workflow puts them.
"""

from __future__ import annotations

import argparse
import os
import sys
from typing import Mapping, NamedTuple, Sequence

from tooling.release.check_tag import BUNDLE, PACKAGE


#: The repository variables that name the addon-site projects, in the order of
#: the packager options they feed.
SITE_VARIABLES = (("CURSEFORGE_PROJECT_ID", "-p"), ("WAGO_ID", "-a"), ("WOWI_ID", "-w"))


class PublishMode(NamedTuple):
    """What `publish` may do: packager arguments, why, and whether to draft a release."""

    packager_args: str
    reason: str
    draft_release: bool

    @property
    def dry_run(self) -> bool:
        """Whether the packager uploads nothing."""
        return self.packager_args == "-d"


def packager_mode(
    kind: str, dry_run_input: str, variables: Mapping[str, str]
) -> tuple[str, str]:
    """Return the packager arguments and the reason for them.

    `dry_run_input` is the hand-started run's `dry_run` input as the workflow
    renders it: `"true"`, `"false"`, or empty for a pushed tag.
    """
    if kind not in (BUNDLE, PACKAGE):
        raise ValueError(f'unknown release kind "{kind}"')
    if dry_run_input == "true":
        return "-d", "dry_run input is on"
    if kind == PACKAGE:
        return "-d", "a package tag never uploads to the addon sites in this version"
    missing = [name for name, _ in SITE_VARIABLES if not variables.get(name)]
    if missing:
        return "-d", f"{', '.join(missing)} not set"
    args = " ".join(f"{option} {variables[name]}" for name, option in SITE_VARIABLES)
    return args, "uploading to CurseForge, Wago and WoWInterface"


def draft_release(ref_type: str, ref_name: str, tag: str) -> bool:
    """Whether to create or update the draft GitHub release for `tag`.

    Only when the run's ref is that very tag, so the attached assets were built
    from the tagged tree, whether the tag was pushed or the run started by hand.
    """
    return bool(tag) and ref_type == "tag" and ref_name == tag


def publish_mode(
    *,
    kind: str,
    dry_run_input: str,
    variables: Mapping[str, str],
    ref_type: str,
    ref_name: str,
    tag: str,
) -> PublishMode:
    """Combine `packager_mode` and `draft_release` into one decision."""
    args, reason = packager_mode(kind, dry_run_input, variables)
    return PublishMode(args, reason, draft_release(ref_type, ref_name, tag))


def github_outputs(mode: PublishMode) -> str:
    """Return the `key=value` lines the `publish` job reads."""
    return f"args={mode.packager_args}\ndraft={'true' if mode.draft_release else 'false'}\n"


def main(argv: Sequence[str] | None = None, environ: Mapping[str, str] | None = None) -> int:
    """Print the decision and optionally append it to the workflow's outputs."""
    parser = argparse.ArgumentParser(
        prog="python3 -m tooling.release.publish_mode",
        description="Decide between dry run and upload, and whether to draft a GitHub release.",
    )
    parser.add_argument("--kind", required=True, choices=[BUNDLE, PACKAGE])
    parser.add_argument("--dry-run-input", default="", help='"true", "false" or empty')
    parser.add_argument("--ref-type", default="", help="github.ref_type")
    parser.add_argument("--ref-name", default="", help="github.ref_name")
    parser.add_argument("--tag", default="", help="the tag being released, empty for none")
    parser.add_argument("--github-output", metavar="FILE", help="append args and draft to FILE")
    arguments = parser.parse_args(argv)

    mode = publish_mode(
        kind=arguments.kind,
        dry_run_input=arguments.dry_run_input,
        variables=os.environ if environ is None else environ,
        ref_type=arguments.ref_type,
        ref_name=arguments.ref_name,
        tag=arguments.tag,
    )
    if mode.dry_run:
        print(f"Dry run: {mode.reason}.")
    else:
        print(f"Upload: {mode.reason}.")
    if mode.draft_release:
        print("Draft GitHub release: yes.")
    else:
        print("Draft GitHub release: no, the run's ref is not the released tag.")

    if arguments.github_output:
        with open(arguments.github_output, "a", encoding="utf-8") as handle:
            handle.write(github_outputs(mode))
    return 0


if __name__ == "__main__":
    sys.exit(main())
