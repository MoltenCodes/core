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
commit means several tags on that commit.

### Bundle release tags

The framework bundle the addon sites carry is released under a second kind of
tag:

```text
v<major>.<minor>.<patch>
```

for example `v0.1.0`. A bundle tag is a release of the *bundle*, not a version
of any package: its section in [Release history](#release-history) lists the
package versions it ships, and those stay the versions consumers depend on.
Pushing a bundle tag starts the release workflow; a package tag does not.

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

## Release procedure

Every step up to pushing the tag is done by a maintainer on their machine; the
workflow takes over from there and stops at a draft.

1. **Bump the package versions** that changed, in each
   `packages/<name>/package.manifest.json`, with their changelogs. Bump `api`
   or `revision` only under the rules in
   [`PACKAGE_MANIFEST.md`](PACKAGE_MANIFEST.md).
2. **Check the supported clients** as described
   [above](#before-tagging-the-supported-clients).
3. **Write the release section.** Add `### v<version>` under
   [Release history](#release-history), newest first, listing every package
   version the bundle ships as "`<packageId>` <version>" lines, followed by the
   notes. This section becomes the text of the GitHub release.
4. **Check the tag before creating it:**

   ```bash
   python3 -m tooling.release.check_tag v<version>
   ```

   It fails when the section is missing, lists nothing, names a package that
   does not exist or records a version the manifest does not have.
5. **Run the gates** listed under [Failing closed](#failing-closed), commit, and
   create a signed, annotated tag on that commit:

   ```bash
   git tag -s v<version> -m "v<version>"
   ```

6. **Push the tag** (`git push origin v<version>`). This is the step that starts
   the release workflow, so it is taken only when the maintainer decides to
   release.
7. **The workflow** re-runs every gate on the tagged tree, builds the framework
   bundle and one bundle per package, runs the packager (a dry run unless the
   rules below allow an upload), and creates or updates a **draft** GitHub
   release with the zips, a `SHA256SUMS.txt` over them, and the notes from
   step 3.
8. **Publish by hand.** Review the draft on GitHub and publish it. The workflow
   never publishes a release, never pushes and never creates a tag.

## The release workflow

[`.github/workflows/release.yml`](../.github/workflows/release.yml) runs on a
pushed `v*.*.*` tag, or by hand from the Actions tab with a `dry_run` input
that defaults to on. It has three jobs:

| Job | What it does |
|---|---|
| `verify` | `check_tag` for the tag, then every CI gate: repository validation, tooling unit tests, Lua tests, Selene, StyLua, lua-language-server and the spell check, on both supported Pythons. |
| `build` | `tooling.package.build --all --zip --verify` for the framework, and `--package <id> --zip --verify` for every package the manifests list; each checked again with `sha256sum --check --strict` and uploaded as workflow artifacts. |
| `publish` | Needs both. Writes the packaging-only `.toc`, runs the BigWigs packager, then attaches the zips and `SHA256SUMS.txt` to a draft GitHub release (tag runs only). |

### Dry run

The packager runs with `-d` — it packages but uploads nothing — whenever
**either** of these is true:

- the run was started by hand with `dry_run` on (the default);
- any of the repository variables `CURSEFORGE_PROJECT_ID`, `WAGO_ID`,
  `WOWI_ID` is unset.

So until the site projects exist and their IDs are entered as variables,
every run is a dry run, including tag pushes. A hand-started run from a branch
packages and builds but never creates a GitHub release.

### Variables and secrets

None of these exist yet. They are created in the repository settings, under
*Secrets and variables → Actions*, when the addon-site projects exist.

| Name | Kind | Holds | Used by |
|---|---|---|---|
| `CURSEFORGE_PROJECT_ID` | variable | the CurseForge project ID | packager `-p` |
| `WAGO_ID` | variable | the Wago Addons project ID | packager `-a` |
| `WOWI_ID` | variable | the WoWInterface addon ID | packager `-w` |
| `CF_API_KEY` | secret | a CurseForge API token | packager upload |
| `WAGO_API_TOKEN` | secret | a Wago Addons API token | packager upload |
| `WOWI_API_TOKEN` | secret | a WoWInterface API token | packager upload |

The draft GitHub release uses the workflow's own `GITHUB_TOKEN`; no personal
token is needed. `GITHUB_OAUTH` is deliberately not given to the packager,
because with it the packager would create a published GitHub release of its
own.

### The packaging-only `.toc`

The framework has no `.toc` in the repository, and the packager cannot run
without one named after `package-as`. The `publish` job therefore writes
`MoltenCodes.toc` into its own checkout with
`python3 -m tooling.release.library_toc` just before packaging. It carries the
supported `## Interface` line from the supported-client table, a title and
`## Version: @project-version@`, and lists **no files**: an installed copy
loads nothing. It is never committed.

## Publishing to CurseForge, Wago and WoWInterface

[`.pkgmeta`](../.pkgmeta) at the repository root is the metadata the BigWigs
packager reads. It describes the same embeddable layout the local builder
produces: development directories are ignored, and each package's `src/` is
moved to `MoltenCodes/<packageId>/`.

The framework is packaged as a library bundle, not as an addon: it has no `.toc`
of its own, so TOC generation and "nolib" variants are both disabled. A consumer
lists the framework's files in *their* addon's `.toc`. The release workflow
supplies the packaging-only `.toc` described above.

`tooling/tests/test_package_build.py` checks that `.pkgmeta` moves every package
discovered from the manifests, so adding a package and forgetting the packager
metadata fails the tooling tests.

## What is not automated

Bumping versions, writing the release section, creating and pushing the tag,
and publishing the draft GitHub release are manual, by design: the workflow
prepares a release and never makes one public. Generated artifacts are never
committed back into the repository; `dist/` and `build/` are ignored.

## Release history

Bundle releases, newest first, in the format
[step 3](#release-procedure) describes. `python3 -m tooling.release.check_tag`
reads this section; `python3 -m tooling.release.notes` prints one entry as the
release notes.

No bundle release has been tagged yet.
