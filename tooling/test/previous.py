"""Find a Kit's previous revision in the git history, for the conformance suite.

`tests/support/KitConformance.lua` proves an in-place upgrade twice: with the
current source under `REVISION - 1`, which is always possible, and with the
runtime files the repository actually committed at revision `REVISION - 1`,
which only a checkout with history can provide. The test runner calls
`extract_previous_revision` for a package whose suite opts into the
conformance suite and names the directory in
`MOLTENCODES_PREVIOUS_REVISION_DIR`.

The previous revision is the newest commit whose `package.manifest.json`
declares `revision` one lower than the working tree's manifest. Its facade
(`src/<Facade>.lua`) and parts (`src/parts/*.lua`) are written to the
directory under their own file names. Nothing is found outside a git
checkout, in a shallow clone that lacks the commit, or for revision 1; the
case is then pending with the reason.
"""

from __future__ import annotations

import json
import subprocess
from pathlib import Path

from tooling.validation.validate_manifests import ROOT

#: The variable `tests/support/KitConformance.lua` reads.
ENVIRONMENT_VARIABLE = "MOLTENCODES_PREVIOUS_REVISION_DIR"

#: How far back the history is searched, in commits touching the manifest.
MAX_COMMITS = 200


def _git(arguments: list[str], root: Path) -> str | None:
    """Run a read-only git command; `None` when git fails or is absent."""
    try:
        result = subprocess.run(
            ["git", *arguments], cwd=root, capture_output=True, text=True, check=False
        )
    except OSError:
        return None
    return result.stdout if result.returncode == 0 else None


def find_previous_commit(package: str, root: Path = ROOT) -> str | None:
    """The newest commit whose manifest of `package` declares the revision before today's."""
    manifest_path = f"packages/{package}/package.manifest.json"
    current = json.loads((root / manifest_path).read_text(encoding="utf-8")).get("revision")
    if not isinstance(current, int) or current < 2:
        return None
    log = _git(["log", f"--max-count={MAX_COMMITS}", "--format=%H", "--", manifest_path], root)
    if log is None:
        return None
    for commit in log.split():
        text = _git(["show", f"{commit}:{manifest_path}"], root)
        if text is None:
            continue
        try:
            revision = json.loads(text).get("revision")
        except ValueError:
            continue
        if revision == current - 1:
            return commit
    return None


def extract_previous_revision(package: str, destination: Path, root: Path = ROOT) -> bool:
    """Write the previous revision's runtime files into `destination`; whether any were found."""
    commit = find_previous_commit(package, root)
    if commit is None:
        return False
    listing = _git(["ls-tree", "-r", "--name-only", commit, f"packages/{package}/src"], root)
    if listing is None:
        return False
    written = False
    for path in listing.split():
        relative = Path(path).relative_to(f"packages/{package}/src")
        is_facade = len(relative.parts) == 1 and relative.suffix == ".lua"
        is_part = relative.parts[0] == "parts" and relative.suffix == ".lua"
        if not (is_facade or is_part):
            continue
        text = _git(["show", f"{commit}:{path}"], root)
        if text is None:
            continue
        destination.mkdir(parents=True, exist_ok=True)
        (destination / relative.name).write_text(text, encoding="utf-8")
        written = True
    return written
