# Repository Tooling

`tooling/` contains repository automation. Nothing in this directory is shipped as a World of Warcraft runtime dependency.

## Commands

Validate the repository:

```bash
python3 -m tooling.validation.validate_repository
```

Run all package tests:

```bash
python3 -m tooling.test.run
```

Run one package's tests:

```bash
python3 -m tooling.test.run registry
```

Lint runtime Lua:

```bash
python3 -m tooling.lint
```

Spell-check the documentation (needs Node 22.18 or newer; skips with a note
without it):

```bash
python3 -m tooling.spell
```

Print the supported `## Interface` line from `validation/supported_clients.json`:

```bash
python3 -m tooling.validation.interface_numbers
```

Run the `apiKit` metadata pipeline (see `docs/TOOLING.md`, "API metadata
tooling"): print the flavour table, list a flavour's mirror branches, capture
one flavour's API documentation tables outside the repository, normalise a
capture into metadata, validate a metadata directory:

```bash
python3 -m tooling.api.flavours
python3 -m tooling.api.fetch --heads --flavour retail
python3 -m tooling.api.fetch --flavour retail --out ~/wow-api
python3 -m tooling.api.normalize --capture ~/wow-api/retail/<sha> --out packages/apiKit/metadata/retail
python3 -m tooling.api.validate packages/apiKit/metadata/retail
```

Build a distributable bundle:

```bash
python3 -m tooling.package.build --all --out dist
python3 -m tooling.package.build --package signalKit --out dist --zip
```

List the package IDs (`--release` leaves out development packages):

```bash
python3 -m tooling.package.list --release
```

The release workflow also runs the commands in `release/`: `check_tag` checks a
bundle tag (`v<SemVer>`) or a package tag (`<packageId>-v<SemVer>`) against
`docs/RELEASES.md` and the manifests, `notes` prints a tag's release notes,
`library_toc` prints the `.toc` of the standalone `MoltenCodes` addon (or, with
`--package`, of one Kit's addon), `pkgmeta` narrows `.pkgmeta` to one Kit
for a package release, and `publish_mode` decides between dry run and upload
and whether to draft a GitHub release. See [`../docs/RELEASES.md`](../docs/RELEASES.md).

Run tooling unit tests:

```bash
python3 -m unittest discover -s tooling/tests -p "test_*.py"
```

`tooling/test/` (singular) is the Busted orchestration package behind
`python3 -m tooling.test.run`; `tooling/tests/` (plural) is this suite's own unit
tests. The names differ by one letter, so `tooling/tests/__init__.py` says which
is which for anyone who lands in the wrong one.

## Supported Python

`pyproject.toml` declares the floor as `requires-python = ">=3.10"`.
`python3 -m tooling.validation.validate_repository` refuses to run on anything
older and checks that the declaration and the tooling's own constant agree. CI
runs the tooling unit tests on both the floor and the current release.

See [`../docs/TOOLING.md`](../docs/TOOLING.md) for architecture and [`../docs/DEVELOPMENT.md`](../docs/DEVELOPMENT.md) for local setup.
