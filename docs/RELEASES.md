# Releases

Packages are versioned independently and published as one embeddable bundle.

## Versioning

Package versions use Semantic Versioning and live in
`packages/<name>/package.manifest.json`.

A release artifact carries the `version` from the manifest it was built from.
Runtime `api` and `revision` mean different things, described in
[`PACKAGE_MANIFEST.md`](PACKAGE_MANIFEST.md), and must not be inferred from the
SemVer number.

## Tags

One tag per package release:

```text
<package>-v<version>
```

for example:

```text
registry-v1.0.0
signalKit-v0.2.0
```

A tag names the package whose `version` changed. Tagging several packages in one
commit means several tags on that commit; there is no combined framework tag,
because there is no combined framework version.

## Before tagging: the supported clients

Every release states which clients it was checked against, so bumping the
`## Interface` numbers is a release step, not a chore for later:

1. Compare [`../tooling/validation/supported_clients.json`](../tooling/validation/supported_clients.json)
   with the current patch table (`Template:LatestPatchInfo` on warcraft.wiki.gg,
   or `/dump (select(4, GetBuildInfo()))` in each client).
2. If anything changed, follow the update procedure in
   [`TOOLING.md`](TOOLING.md#supported-clients-one-table): edit the table and its
   `verified` date, paste what `python3 -m tooling.validation.interface_numbers`
   prints, and commit the bump on its own.
3. If nothing changed, still move `verified` to today's date and update the date
   in `EMBEDDING.md`, so the documentation says when the numbers were last true.

Repository validation fails until every quoted number agrees with the table,
so a half-done bump cannot be tagged from a green tree.

## Building an artifact

```bash
python3 -m tooling.package.build --all --out dist
```

builds every package into one bundle. To build one package:

```bash
python3 -m tooling.package.build --package signalKit --out dist
```

Other options:

| Option | Effect |
|---|---|
| `--all` | include every package in the repository |
| `--package NAME` | include `NAME` and its runtime dependencies |
| `--out DIR` | output directory; created if missing |
| `--zip` | additionally write `<bundle>.zip` |
| `--verify` | re-read `CHECKSUMS.txt` afterwards and check it against the build |

`--all` and `--package` are mutually exclusive and one of them is required.

A single-package build includes that package's runtime dependency closure. A
bundle that cannot load is not a release artifact, so `--package schedulerKit`
also ships Registry, SignalKit, EventKit, LifecycleKit and TimerKit. The
`manifest.json` records which package the build is *about* and which are only
there to make it load.

### What gets built

`--all` produces:

```text
dist/
├── CHECKSUMS.txt
└── MoltenCodes/
    ├── LICENSE
    ├── manifest.json
    ├── registry/
    │   ├── Registry.lua
    │   ├── README.md
    │   ├── CHANGELOG.md
    │   └── API.md
    ├── signalKit/
    │   └── ...
    └── ...
```

`--package NAME` produces the same shape under `MoltenCodes-NAME/`.

Per package, the builder copies:

- every file under `src/`, except `.luarc.json`, which configures
  lua-language-server for that directory and has no meaning in a client;
- `README.md` and `CHANGELOG.md` from the package root;
- `docs/API.md` as `API.md`, and `docs/INTERNALS.md` as `INTERNALS.md`, when
  they exist.

The repository `LICENSE` is copied to the bundle root. Package tests, package
manifests, repository tooling, editor metadata and the examples are not shipped.

The directory layout inside the bundle is the layout an addon embeds, so
installing an update into `Libs/MoltenCodes/` is a directory copy. See
[`EMBEDDING.md`](EMBEDDING.md).

### `manifest.json`

Written at the bundle root. It records, for every package in the bundle: display
name, description, `version`, `license`, `api`, `revision`, its declared runtime
dependencies, the files it published, and its `role` in this bundle (`subject`,
`dependency`, or `member` for an `--all` build).

It also records `loadOrder`: the bundle-relative Lua files in a valid
dependency-first order. That list is exactly what a consuming addon puts in its
`.toc`, which is why it is generated rather than written by hand.

### `CHECKSUMS.txt`

Written at the output root, in `sha256sum` format — a SHA-256 digest, two
spaces, and the path relative to the output directory — sorted by path:

```text
5af754d2702c1f9bc43c0677d66c77ce5adcf5eba79faf22ae7f203d76c9799f  MoltenCodes/LICENSE
```

It covers every file in the bundle, including `manifest.json`, and the zip when
`--zip` was passed. It does not cover itself. Verify a downloaded artifact with:

```bash
cd dist && sha256sum --check CHECKSUMS.txt
```

`--verify` makes the builder check its own output before you ever publish it: it
re-reads the file it has just written and reports, together, a recorded file that
is missing, a recorded file whose digest no longer matches, and a file inside a
described tree that nothing records. The last of those is the case
`sha256sum --check` cannot see, because that tool only walks the lines it is
given and a file left out of them passes silently.

The two checks answer different questions and CI runs both: `--verify` proves the
checksum file describes the bundle beside it exactly, and `sha256sum --check
--strict CHECKSUMS.txt` proves the file is usable by the tool a downloader will
actually reach for.

### Reproducibility

Builds are deterministic. No timestamp is written into the artifact and zip
entries use a fixed modification time, so building the same sources twice
produces byte-identical output and therefore identical checksums. A checksum
that differs between two builds of the same commit is a bug in the builder.

### Failing closed

The builder refuses to produce anything when the repository's own metadata does
not hold up: it runs the manifest schema and dependency-graph checks first, and
additionally requires every package to declare a `license` and the repository to
have a `LICENSE` file. It does **not** run the test suite, the linter or the
formatter — run those first:

```bash
python3 -m tooling.validation.validate_repository
python3 -m unittest discover -s tooling/tests -p "test_*.py"
python3 -m tooling.test.run
python3 -m tooling.lint
python3 -m tooling.spell
stylua --check .
```

## Publishing to CurseForge, Wago and WoWInterface

[`.pkgmeta`](../.pkgmeta) at the repository root is the metadata the BigWigs
packager reads. It describes the same embeddable layout the local builder
produces: development directories are ignored, and each package's `src/` is
moved to `MoltenCodes/<packageId>/`.

The framework is packaged as a library bundle, not as an addon: it has no `.toc`
of its own, so TOC generation and "nolib" variants are both disabled. A consumer
lists the framework's files in *their* addon's `.toc`.

`tooling/tests/test_package_build.py` checks that `.pkgmeta` moves every package
discovered from the manifests, so adding a package and forgetting the packager
metadata fails the tooling tests.

## What is not automated

There is no publication step. Tagging, uploading and release notes are manual.
Generated artifacts are never committed back into the repository; `dist/` and
`build/` are ignored.
