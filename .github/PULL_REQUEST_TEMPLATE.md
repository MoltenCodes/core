<!--
Thank you for contributing. Fill in each section; delete a checklist line only
when it cannot apply, and say why under "Notes for the reviewer".
The pull request title becomes the commit subject on a squash merge, so it
follows the same form: `type(scope): subject`.
-->

## What and why

<!-- What changes, and the problem it solves. Link the issue: "Closes #123". -->

## Kit(s) touched

<!-- One Kit per pull request (see CONTRIBUTING.md). List the package IDs, or
"none" for tooling or documentation only. If more than one, say why they cannot
land separately. -->

-

## Checklist

### Gates run locally

- [ ] `python3 -m tooling.validation.validate_repository`
- [ ] `python3 -m unittest discover -s tooling/tests -p "test_*.py"`
- [ ] `python3 -m tooling.test.run`
- [ ] `python3 -m tooling.lint` (zero errors and zero warnings in both scopes)
- [ ] `stylua --check .`
- [ ] `python3 -m tooling.spell`
- [ ] `python3 -m tooling.test.coverage` (every package at or above its floor in `tooling/test/coverage-floors.json`)
- [ ] `lua-language-server --check packages/<name>/src --checklevel=Warning` for every Kit touched, and `lua-language-server --check examples --checklevel=Warning` when the public surface changed
- [ ] `actionlint`, when `.github/workflows/` or `.github/actions/` changed
- [ ] `python3 -m tooling.ci.check_commits origin/main..HEAD`

### Package contract ([`docs/PACKAGE_MANIFEST.md`](https://github.com/MoltenCodes/core/blob/main/docs/PACKAGE_MANIFEST.md))

- [ ] A regression spec covers the bug fixed or the behaviour added.
- [ ] The Kit's `CHANGELOG.md` has a dated entry (`## <version> — YYYY-MM-DD`).
- [ ] `version` is bumped in `package.manifest.json`.
- [ ] `revision` is bumped only because executed code changed (not for comments, annotations or formatting), and `IMPLEMENTATION_REVISION`, the runtime `REVISION` and the manifest agree, with an upgrade path and a spec from the previous revision.
- [ ] `api` is bumped for a breaking public contract, and the pull request carries the `breaking change` label.
- [ ] `docs/API.md` and the LuaCATS annotations describe the public surface as it now is.
- [ ] The "Minimum footprint" line in the Kit's README is still true.
- [ ] Runtime Lua follows the taint and secret-value checklist in [`docs/CONTRIBUTING.md`](https://github.com/MoltenCodes/core/blob/main/docs/CONTRIBUTING.md#taint-and-secret-values).

### Repository

- [ ] Every commit subject, and this title, follow `type(scope): subject`.
- [ ] No secrets, API tokens, account names or client credentials in code, specs, logs or screenshots.
- [ ] No assistant or personal tool configuration files added to the repository.

## Notes for the reviewer

<!-- Anything that needs a closer look, decisions taken, follow-ups. -->
