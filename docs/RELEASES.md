# Releases

Packages are versioned independently. Each Kit can be released on its own, and
the whole framework is released as one bundle that seals a set of Kit versions
tested together. Every release is also an installable addon: the bundle
installs as the addon `MoltenCodes`, a single Kit as `MoltenCodes-<Facade>`.

## Versioning

Package versions use Semantic Versioning and live in
`packages/<name>/package.manifest.json`.

A release artifact carries the `version` from the manifest it was built from.
Runtime `api` and `revision` mean different things, described in
[`PACKAGE_MANIFEST.md`](PACKAGE_MANIFEST.md), and must not be inferred from the
SemVer number.

## Tags

Two kinds of tag release something. Pushing either starts the release workflow.

| Tag | Example | Releases | Installs as |
|---|---|---|---|
| `v<major>.<minor>.<patch>` (bundle tag) | `v0.1.0` | every release package, at the versions its history section lists | the addon `MoltenCodes` |
| `<packageId>-v<major>.<minor>.<patch>` (package tag) | `timerKit-v0.6.0` | one Kit, with the packages it requires | the addon `MoltenCodes-<Facade>`, for example `MoltenCodes-TimerKit` |

A **package tag** is a release of one Kit. The version in the tag is that Kit's
manifest `version`, so the tag names exactly what changed. Tagging several
Kits in one commit means several tags on that commit. Development packages
(`"distribution": "development"`) are never tagged.

A **bundle tag** is a release of the *bundle*, not a version of any package,
the way Ace3 versions each library and ships them as one. Its section in
[Release history](#release-history) lists **every** release package and the
version the bundle ships; those stay the versions consumers depend on. A Kit
does not have to change for a bundle to be tagged, and a Kit released under its
own tag reaches the bundle only when the next bundle tag lists its new version.

Both kinds of tag accept a SemVer pre-release part (`v0.2.0-beta.1`,
`timerKit-v0.7.0-rc.1`). A package ID never contains a hyphen, so the first
`-v` always ends it.

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

builds every release package into one bundle. To build one package:

```bash
python3 -m tooling.package.build --package signalKit --out dist
```

Other options:

| Option | Effect |
|---|---|
| `--all` | include every release package (packages marked `distribution: development` are skipped and listed in `manifest.json`) |
| `--package NAME` | include `NAME` and its runtime dependencies |
| `--out DIR` | output directory; created if missing |
| `--zip` | additionally write `<bundle>.zip` |
| `--verify` | re-read `CHECKSUMS.txt` and the `.toc` afterwards and check them against the build |

`--all` and `--package` are mutually exclusive and one of them is required.

A single-package build includes that package's runtime dependency closure. A
bundle that cannot load is not a release artifact, so `--package schedulerKit`
also ships Registry and TimerKit. The
`manifest.json` records which package the build is *about* and which are only
there to make it load. The bundle is named after the package's facade,
`MoltenCodes-SchedulerKit`, because it is also an addon and the client requires
an addon's folder and its `.toc` to carry the same name.

### What gets built

`--all` produces:

```text
dist/
├── CHECKSUMS.txt
└── MoltenCodes/
    ├── LICENSE
    ├── MoltenCodes.toc
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

`--package NAME` produces the same shape under `MoltenCodes-<Facade>/`, with
`MoltenCodes-<Facade>.toc` in its root; `--package timerKit` writes
`MoltenCodes-TimerKit/`.

Per package, the builder copies:

- every file under `src/`, except `.luarc.json`, which configures
  lua-language-server for that directory and has no meaning in a client;
- `README.md` and `CHANGELOG.md` from the package root;
- `docs/API.md` as `API.md`, and `docs/INTERNALS.md` as `INTERNALS.md`, when
  they exist.

The repository `LICENSE` is copied to the bundle root, and the generated `.toc`
described in [The standalone addon](#the-standalone-addon) is written there.
Package tests, package manifests, repository tooling, editor metadata and the
examples are not shipped.

The packager zip the publish job uploads to the addon sites follows the same
layout for every Lua file and every `docs/` directory, but leaves out each
package's `README.md` and `CHANGELOG.md`: the BigWigs packager moves
directories, not files. Those two land only in the builder bundle attached to
the GitHub release; `.pkgmeta` says so in its header.

The directory layout inside the bundle is the layout an addon embeds, so
installing an update into `Libs/MoltenCodes/` is a directory copy, and it is
also the layout of the installed addon, so copying the bundle folder into
`Interface/AddOns/` installs it. See [`EMBEDDING.md`](EMBEDDING.md).

### `manifest.json`

Written at the bundle root. It records, for every package in the bundle: display
name, description, `version`, `license`, `api`, `revision`, its declared runtime
dependencies, the files it published, and its `role` in this bundle (`subject`,
`dependency`, or `member` for an `--all` build).

It also records `loadOrder`: the bundle-relative Lua files in a valid
dependency-first order. That list is exactly what a consuming addon puts in its
`.toc`, which is why it is generated rather than written by hand. `toc` names
the bundle's own `.toc` (`"MoltenCodes.toc"`), whose file lines are the same
list with the client's backslashes.

### `CHECKSUMS.txt`

Written at the output root, in `sha256sum` format — a SHA-256 digest, two
spaces, and the path relative to the output directory — sorted by path:

```text
5af754d2702c1f9bc43c0677d66c77ce5adcf5eba79faf22ae7f203d76c9799f  MoltenCodes/LICENSE
```

It covers every file in the bundle, including `manifest.json` and the `.toc`,
and the zip when `--zip` was passed. It does not cover itself. Verify a
downloaded artifact with:

```bash
cd dist && sha256sum --check CHECKSUMS.txt
```

`--verify` makes the builder check its own output before you ever publish it: it
re-reads the file it has just written and reports, together, a recorded file that
is missing, a recorded file whose digest no longer matches, and a file inside a
described tree that nothing records. The last of those is the case
`sha256sum --check` cannot see, because that tool only walks the lines it is
given and a file left out of them passes silently.

`--verify` also holds the bundle's `.toc` against the bundle: its file lines
must be `manifest.json`'s `loadOrder`, in that order, and every `.lua` file in
the bundle must be listed. A file the `.toc` misses would never load in an
installed copy; a listed file that is missing would stop the addon's load.

The two checksum checks answer different questions and CI runs both:
`--verify` proves the checksum file describes the bundle beside it exactly, and
`sha256sum --check --strict CHECKSUMS.txt` proves the file is usable by the
tool a downloader will actually reach for.

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
workflow takes over from there and stops at a draft. The two kinds of tag
differ only in the release section and the tag name.

1. **Bump the package versions** that changed, in each
   `packages/<name>/package.manifest.json`, with their changelogs. Bump `api`
   or `revision` only under the rules in
   [`PACKAGE_MANIFEST.md`](PACKAGE_MANIFEST.md).
2. **Check the supported clients** as described
   [above](#before-tagging-the-supported-clients).
3. **Write the release section** under [Release history](#release-history),
   newest first. It becomes the text of the GitHub release.
   - Bundle tag: `### v<version>`, listing **every** release package as
     "`<packageId>` <version>" lines, each at its manifest version, then the
     notes.
   - Package tag: `### <packageId>-v<version>`, then the notes. Version lines
     are optional here; any you write are checked the same way.
4. **Check the tag before creating it:**

   ```bash
   python3 -m tooling.release.check_tag v<version>
   python3 -m tooling.release.check_tag <packageId>-v<version>
   ```

   For a bundle tag it fails when the section is missing, lists nothing, leaves
   out a release package, names a package that does not exist or is a
   development package, lists one twice, or records a version the manifest does
   not have. For a package tag it fails when the package does not exist, is a
   development package or has another manifest version, or the section is
   missing. Every error names the line of this document to fix.
5. **Run the gates** listed under [Failing closed](#failing-closed), commit, and
   create a signed, annotated tag on that commit:

   ```bash
   git tag -s v<version> -m "v<version>"
   git tag -s <packageId>-v<version> -m "<packageId>-v<version>"
   ```

6. **Push the tag** (`git push origin <tag>`). This is the step that starts the
   release workflow, so it is taken only when the maintainer decides to
   release.
7. **The workflow** checks the tag again, re-runs every gate on the tagged
   tree, builds the release (for a bundle tag the framework bundle and one
   bundle per package; for a package tag that package's bundle), runs the
   packager (a dry run unless the rules below allow an upload; always a dry run
   for a package tag), and creates or updates a **draft** GitHub release named
   after the tag, with the zips, a
   `SHA256SUMS.txt` over them, and the notes from step 3.
8. **Publish by hand.** Review the draft on GitHub and publish it. The workflow
   never publishes a release, never pushes and never creates a tag.

## The release workflow

[`.github/workflows/release.yml`](../.github/workflows/release.yml) runs on a
pushed `v*.*.*` or `*-v*.*.*` tag, or by hand from the Actions tab. A
hand-started run takes a `dry_run` input that defaults to on, and a `tag` input:
the name of a tag to rehearse on the chosen branch (for example
`timerKit-v0.6.0`, before creating it), or empty to build every release package
without a tag check. It has four jobs:

| Job | What it does |
|---|---|
| `resolve` | `check_tag` for the tag, and exports what it releases: `tag`, `kind` (`bundle` or `package`), `package` and `version`. |
| `verify` | Needs `resolve`. Every CI gate that judges the tagged tree: repository validation, tooling unit tests, Lua tests, Selene, StyLua, lua-language-server and the spell check, on both supported Pythons. The commit-subject check, the secret scan and actionlint judge changes and run in CI before anything reaches `main`; they are not repeated here. |
| `build` | Needs `resolve`. Bundle tag: `tooling.package.build --all --zip --verify` for the framework, and `--package <id> --zip --verify` for every package `tooling.package.list --release` prints. Package tag: `--package <id> --zip --verify` for that package. Each checked again with `sha256sum --check --strict` and uploaded as workflow artifacts. |
| `publish` | Needs all three. Writes the addon's `.toc` (and, for a package tag, the narrowed packager metadata) into its checkout, runs the BigWigs packager, then attaches the zips and `SHA256SUMS.txt` to a draft GitHub release (only when the run's ref is the released tag). |

The workflow grants no permissions by default. `resolve`, `verify` and `build`
read the checkout only; `publish` alone may write repository contents, which it
needs to create or update the draft release. Two runs for the same tag queue
rather than cancel each other, so a release is never stopped half-way through
an upload.

### Dry run

The packager runs with `-d` — it packages but uploads nothing — whenever
**any** of these is true:

- the run was started by hand with `dry_run` on (the default);
- any of the repository variables `CURSEFORGE_PROJECT_ID`, `WAGO_ID`,
  `WOWI_ID` is unset;
- the tag is a package tag.

So until the site projects exist and their IDs are entered as variables,
every run is a dry run, including tag pushes.

**Package tags never upload to the addon sites in this version.** The site
projects carry one addon, the bundle, and uploading `MoltenCodes-TimerKit` to
them would replace the file players download. A package release still gets its
draft GitHub release with the `MoltenCodes-<Facade>` zip. Whether each Kit later
gets a site project of its own, or the sites carry the bundle only, is an open
decision; until it is taken, the rule stays.

A draft GitHub release is created only when the run's ref is the tag being
released: a pushed tag, or a hand-started run started *from that tag* (with the
`tag` input empty or naming the same tag), so a dry run can be inspected end to
end, draft included. A run started from a branch, with or without a `tag`
input, packages and builds but never creates a GitHub release.

Both rules live in `python3 -m tooling.release.publish_mode`, which the
`publish` job calls, so they are unit-tested rather than written only in YAML.

### The first real run

The packager's `-m <file>` option, which a package tag uses to hand it the
narrowed `.pkgmeta-package`, has not been exercised by a run yet. On the first
package-tag run, check the packager log: it must name `.pkgmeta-package` and
package `MoltenCodes-<Facade>` with only that Kit and its dependencies. If the
packager does not accept `-m`, the job instead writes the generated file over
`.pkgmeta` in its own checkout (never committed) and runs the packager without
`-m`.

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

## The standalone addon

The framework installs two ways. An addon may embed the Kits it uses in its own
`Libs/`, as [`EMBEDDING.md`](EMBEDDING.md) describes, or a player installs the
framework once as an addon and addons depend on it. Every release supports the
second way: the bundle installs as the addon `MoltenCodes`, which loads every
release Kit, and a single-Kit release installs as `MoltenCodes-<Facade>`
(`MoltenCodes-TimerKit`), which loads that Kit and the Kits it requires.

An addon that uses the installed framework declares it with
`## OptionalDeps: MoltenCodes`, so the client loads the framework first when it
is installed. Embedded copies and the installed addon coexist: Registry keeps
one copy of each Kit, the newest, whichever arrived first. The consumer side is
in [`EMBEDDING.md`, "Embed or depend"](EMBEDDING.md#embed-or-depend).

### The generated `.toc`

No `.toc` is committed. `python3 -m tooling.release.library_toc` generates it,
the builder writes the same text into every bundle root, and the `publish` job
writes it into its checkout just before the packager runs. It carries:

| Line | Value |
|---|---|
| `## Interface` | every number in the supported-client table, comma-separated, exactly as [`EMBEDDING.md`](EMBEDDING.md#supported-client-versions) documents |
| `## Title` | the addon name: `MoltenCodes`, or `MoltenCodes-<Facade>` |
| `## Notes` | one sentence: the MoltenCodes framework (or that Kit of it), installed once so addons can depend on it instead of embedding it |
| `## Author` | `MoltenCodes` |
| `## Version` | `@project-version@`, which the packager replaces with the tag |
| `## IconTexture` | `Interface\Icons\INV_Misc_Gear_01` |
| `## X-Category` | `Libraries` |
| `## X-License` | `MIT` |
| `## X-Website` | `https://github.com/MoltenCodes/core` |

followed by one `<packageId>\<Facade>.lua` line per package, in the builder's
load order, relative to the addon folder: `registry\Registry.lua` first, then
every Kit after the Kits it requires. Development packages are never listed.
`--package <id>` prints the single-Kit `.toc` instead.

There is one layout, not two: the builder's bundle is
`MoltenCodes/<packageId>/<Facade>.lua`, and so is the packager's zip after
`.pkgmeta`'s `move-folders`. The same `.toc` therefore serves both.

## Publishing to CurseForge, Wago and WoWInterface

[`.pkgmeta`](../.pkgmeta) at the repository root is the metadata the BigWigs
packager reads. It describes the same layout the local builder produces:
development directories are ignored, and each package's `src/` is moved to
`MoltenCodes/<packageId>/`. `package-as: MoltenCodes` names the addon, and the
generated `MoltenCodes.toc` at the top of the checkout is the `.toc` the
packager requires under that name. TOC generation per flavour is off because
one `## Interface` line lists every supported client, and there is no "nolib"
variant because there are no externals to strip.

A **bundle tag** packages the repository with `.pkgmeta` as it is.

A **package tag** must package one Kit only. The `publish` job derives its
metadata from `.pkgmeta` with

```bash
python3 -m tooling.release.pkgmeta --package timerKit --output .pkgmeta-package
```

which sets `package-as: MoltenCodes-TimerKit`, keeps only the `move-folders`
entries of TimerKit and the packages it requires (renamed under the new addon
folder), adds every other package to `ignore`, and ignores `.pkgmeta` and the
written file themselves. The job writes `MoltenCodes-TimerKit.toc` beside it and
hands the file to the packager with `-m .pkgmeta-package`. Neither file is ever
committed, so `.pkgmeta` stays the only packager metadata maintained by hand.

`tooling/tests/test_package_build.py` checks that `.pkgmeta` moves every package
discovered from the manifests, and `tooling/tests/test_release.py` that every
release package narrows to exactly its dependency closure, so adding a package
and forgetting the packager metadata fails the tooling tests.

## What is not automated

Bumping versions, writing the release section, creating and pushing the tag,
and publishing the draft GitHub release are manual, by design: the workflow
prepares a release and never makes one public. Generated artifacts are never
committed back into the repository; `dist/` and `build/` are ignored.

## Release history

Releases, newest first, in the format [step 3](#release-procedure) describes:
`### v<version>` for a bundle, listing every release package, and
`### <packageId>-v<version>` for one Kit. For example:

```markdown
### v0.1.0

- `registry` 0.6.3
- `signalKit` 0.4.0
- ... one line for every release package ...

The first bundle release.

### timerKit-v0.6.0

Adds the addon-scope close at logout.
```

`python3 -m tooling.release.check_tag` reads this section;
`python3 -m tooling.release.notes` prints one entry as the release notes.

No release has been tagged yet.
