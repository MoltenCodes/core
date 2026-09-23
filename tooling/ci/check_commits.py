"""Check that commit subjects follow the repository's conventional-commit form.

    python3 -m tooling.ci.check_commits <base>..<head>
    python3 -m tooling.ci.check_commits --subject "feat(timerKit): add GetRemaining"

Every subject must read `type(scope): subject`, as `docs/CONTRIBUTING.md`
("Commit subjects") describes:

- `type` is one of `ALLOWED_TYPES`;
- `scope` is required and names what changed: a package ID (`timerKit`), or an
  area such as `repo`, `tooling`, `docs`, `ci`, `fixture` or `examples`;
- an optional `!` after the scope marks a breaking change;
- one space follows the colon, and the subject is not empty and does not end
  with a full stop.

There is no length limit. The history holds deliberate subjects well over 100
characters, and a limit nobody has agreed on would fail them for no reason.

The pull-request job of `.github/workflows/ci.yml` runs this over the commits a
pull request adds, and over the pull request's title, because a squash merge
uses the title as the commit subject. Merge commits are skipped: they are made
by `git` or by GitHub, not written by hand. A `fixup!`, `squash!` or `amend!`
commit is refused with its own message, because it is meant to be folded into
its target before the pull request merges.

Exit status: 0 when every subject passes, 1 when any fails, 2 when the range
cannot be read.
"""

from __future__ import annotations

import argparse
import re
import subprocess
import sys
from pathlib import Path
from typing import NamedTuple, Sequence


ROOT = Path(__file__).resolve().parents[2]

#: Commit types, in the order `docs/CONTRIBUTING.md` lists them.
ALLOWED_TYPES = (
    "feat",
    "fix",
    "docs",
    "chore",
    "refactor",
    "test",
    "build",
    "ci",
    "perf",
    "style",
)

#: `type(scope)!: subject`. The pieces are captured loosely so that a wrong
#: subject can be told apart from an unknown type or a malformed scope, and
#: each gets a message that says what to fix.
SUBJECT_RE = re.compile(
    r"^(?P<type>[A-Za-z]+)"
    r"(?:\((?P<scope>[^()]*)\))?"
    r"(?P<breaking>!)?"
    r":(?P<space>[ \t]*)"
    r"(?P<subject>.*)$"
)

#: A scope starts with a letter or digit and may then use letters, digits and
#: `-`, `_`, `.`, `/` or `,` (`docs(kits,repo)` is one scope naming two areas).
SCOPE_RE = re.compile(r"^[A-Za-z0-9][A-Za-z0-9._/,-]*$")

#: Prefixes `git commit --fixup` and friends write; see the module docstring.
AUTOSQUASH_PREFIXES = ("fixup!", "squash!", "amend!")


class Commit(NamedTuple):
    """A commit to check: an identifier for the report, and its subject line."""

    ref: str
    subject: str


def subject_problems(subject: str) -> list[str]:
    """Return every rule `subject` breaks, or an empty list when it passes."""
    if subject != subject.strip():
        return ["has leading or trailing whitespace"]
    if not subject:
        return ["is empty"]

    for prefix in AUTOSQUASH_PREFIXES:
        if subject.startswith(prefix):
            return [f"is a `{prefix}` commit; squash it into its target before merging"]

    match = SUBJECT_RE.match(subject)
    if match is None:
        return ["does not start with `type(scope): `"]

    problems: list[str] = []
    commit_type = match.group("type")
    if commit_type not in ALLOWED_TYPES:
        problems.append(
            f"has type `{commit_type}`; allowed types are {', '.join(ALLOWED_TYPES)}"
        )

    scope = match.group("scope")
    if scope is None:
        problems.append("has no scope; write `type(scope): subject`")
    elif not SCOPE_RE.match(scope):
        problems.append(f"has scope `({scope})`, which is empty or uses characters a scope may not")

    if match.group("space") != " ":
        problems.append("needs exactly one space after the colon")

    text = match.group("subject")
    if not text.strip():
        problems.append("has no text after `type(scope): `")
    elif text.endswith("."):
        problems.append("ends with a full stop")

    return problems


def read_commits(revision_range: str, cwd: Path = ROOT) -> list[Commit]:
    """Read the non-merge commits in `revision_range`, oldest first.

    Raises `RuntimeError` with git's message when the range cannot be read,
    which in CI usually means the checkout is too shallow to contain the base.
    """
    result = subprocess.run(
        [
            "git",
            "log",
            "--no-merges",
            "--reverse",
            "--format=%h%x00%s",
            revision_range,
            "--",
        ],
        cwd=cwd,
        capture_output=True,
        text=True,
        check=False,
    )
    if result.returncode != 0:
        raise RuntimeError(result.stderr.strip() or f"git log {revision_range} failed")

    commits: list[Commit] = []
    for line in result.stdout.splitlines():
        ref, _, subject = line.partition("\x00")
        commits.append(Commit(ref, subject))
    return commits


def check(commits: Sequence[Commit]) -> list[str]:
    """Return one report line per rule broken, across every commit."""
    report: list[str] = []
    for commit in commits:
        for problem in subject_problems(commit.subject):
            report.append(f"{commit.ref}: {commit.subject!r} {problem}")
    return report


def parse_arguments(argv: Sequence[str] | None) -> argparse.Namespace:
    """Parse the command line; a range, `--subject` or both must be given."""
    parser = argparse.ArgumentParser(
        prog="python3 -m tooling.ci.check_commits",
        description="Check commit subjects against the conventional-commit form.",
    )
    parser.add_argument(
        "range",
        nargs="?",
        help="a git revision range such as origin/main..HEAD; merge commits are skipped",
    )
    parser.add_argument(
        "--subject",
        action="append",
        default=[],
        metavar="TEXT",
        help="check TEXT as a subject as well (repeatable), for example a pull request title",
    )
    arguments = parser.parse_args(argv)
    if arguments.range is None and not arguments.subject:
        parser.error("give a revision range, --subject, or both")
    return arguments


def main(argv: Sequence[str] | None = None) -> int:
    """Check the range and the given subjects, print the report, return the exit status."""
    arguments = parse_arguments(argv)

    commits: list[Commit] = []
    if arguments.range is not None:
        try:
            commits.extend(read_commits(arguments.range))
        except RuntimeError as exc:
            print(f"error: cannot read {arguments.range}: {exc}", file=sys.stderr)
            return 2
    commits.extend(Commit("subject", text) for text in arguments.subject)

    report = check(commits)
    for line in report:
        print(f"error: {line}", file=sys.stderr)
    if report:
        print(
            f"{len(report)} problem(s) in {len(commits)} subject(s). "
            "See docs/CONTRIBUTING.md, \"Commit subjects\".",
            file=sys.stderr,
        )
        return 1

    print(f"{len(commits)} subject(s) follow type(scope): subject.")
    return 0


if __name__ == "__main__":
    sys.exit(main())
