# Tooling

Repository tooling lives under `tooling/` and is never a runtime dependency.

## Current tooling

```text
tooling/
├── lint.py                         # discovers and lints runtime and test Lua
├── spell.py                        # runs the pinned cspell over the documentation
├── spell-words.txt                 # the project dictionary cspell reads
├── api/                            # apiKit metadata pipeline; see "API metadata tooling"
│   ├── flavours.py                # reads flavours.json
│   ├── flavours.json              # the apiKit flavours: namespaces, mirror branches, detection facts
│   ├── fetch.py                   # downloads one flavour's documentation tables at a pinned commit
│   ├── lua_tables.py              # parses the tables
│   ├── naming.py / naming.json    # wrapper naming rules and reviewed naming data
│   ├── model.py / SCHEMA.md       # the metadata model and its JSON form
│   ├── types.json                 # host types with their LuaCATS spelling
│   ├── normalize.py               # capture → metadata directory
│   ├── validate.py                # checks a metadata directory
│   ├── diff.py                    # compares two captures; change report and history
│   ├── render_runtime.py          # the generated Lua bindings file
│   ├── render_types.py            # the generated LuaCATS definitions
│   ├── render_reference.py        # the generated reference and search index
│   ├── generate.py                # writes every output of a flavour
│   └── heads.py                   # compares committed metadata builds with the mirror heads
├── bench/                          # Kits against Ace3: "Host benchmark" and "In-client benchmark"
│   ├── ace3.py                    # fetches the pinned Ace3 into a checksummed cache outside the repository
│   ├── workloads.py / run.py      # the host workload catalogue and its runner
│   ├── host.py / report.py        # the host Lua runner and the Markdown report
│   ├── client_install.py          # installs the in-client benchmark addons
│   ├── client_workloads.py / client_report.py # the in-client catalogue and its report
│   ├── lua/, client/              # the Lua workloads, hosts and the in-client harness
│   └── results/                   # committed results files
├── ci/
│   └── check_commits.py           # checks commit subjects and pull request titles
├── fixtures/                      # third-party output recorded for the specs; see "Recorded fixtures"
│   ├── ace_serializer.py          # records bridgeKit's AceSerializer-3.0 fixtures from the pinned Ace3
│   └── lua/RecordAceSerializer.lua # the host Lua script that calls AceSerializer-3.0 over our inputs
├── client/
│   ├── flavours.py                # the client flavours the real-client tests cover: folder, project ID
│   ├── install.py                 # installs the bundle and the real-client test addons into a game folder, or removes them
│   ├── session.py                 # one session per flavour: prepare (install everything, the sheet), collect, clean
│   ├── report.py                  # merges the harness's saved results into the committed result matrix
│   └── saved_variables.py         # reads a saved-variables file as Lua literals, without running Lua
├── docs/
│   ├── generate.py                # the package lists between generated markers, rendered from the manifests
│   └── split_roadmap.py           # moves ROADMAP's nine-point records into docs/records/, one file per package
├── package/
│   ├── build.py                   # assembles a checksummed bundle that installs as an addon
│   ├── embeds.py                  # writes an addon's embeds.xml (or .toc lines) for chosen Kits and parts
│   ├── list.py                    # prints package IDs from the manifests
│   ├── parts.py                   # the Kit parts model: nodes, contracts, the load-order walk
│   └── toc.py                     # renders and reads the generated addon .toc
├── release/
│   ├── check_tag.py               # checks a bundle or package tag against RELEASES.md and the manifests
│   ├── history.py                 # reads the release history in docs/RELEASES.md
│   ├── library_toc.py             # prints the .toc of the MoltenCodes addon (or of one Kit's addon)
│   ├── notes.py                   # prints one release's notes
│   ├── pkgmeta.py                 # narrows .pkgmeta to one Kit for a package release
│   └── publish_mode.py            # decides dry run or upload, and whether to draft a release
├── shared/
│   ├── lua/                       # the canonical shared helpers Kits copy: isSecret, reportError, describeKey, validateFacade, limits
│   ├── sync.py                    # copies them between a Kit's markers; --check is the gate, --list the migration list
│   └── pins.json                  # Kits that keep an older helper revision or opt out, each with a reason
├── test/
│   ├── run.py                     # package-aware Busted orchestration
│   ├── previous.py                # finds a Kit's committed previous revision for the conformance suite
│   ├── coverage.py                # the same run under LuaCov, gated on per-package floors
│   └── coverage-floors.json       # each package's line-coverage floor, a whole percent
├── tests/                         # Python unit tests for repository tooling
└── validation/
    ├── flavour_api.py             # every client API a Kit uses exists on every promised flavour, or is guarded
    ├── flavour_api_allowlist.json # reviewed exceptions to flavour_api, each with its guard and reason
    ├── host_names.json            # Lua library, framework globals and undocumented client names, with evidence
    ├── interface_numbers.py       # reads the supported-client table, prints the .toc line
    ├── lua_limits.py              # active locals and upvalues of every runtime function, against Lua 5.1's limits
    ├── lua_limits.json            # the ratchet: files allowed above a fail line, at their measured value
    ├── lua_references.py          # finds host references in Lua and decides whether each use is guarded
    ├── lua_syntax.py              # Lua 5.1 lexer and parser; `python3 -m tooling.validation.lua_syntax FILE...` checks files
    ├── supported_clients.json     # the supported `## Interface` numbers, by flavour
    ├── validate_manifests.py      # manifest schema and dependency graph checks
    └── validate_repository.py     # layout, indexes, packaging, editor configuration, Interface and link checks
```

Three configuration files the tooling reads live at the repository root,
because that is where their tools look for them:
[`../cspell.json`](../cspell.json) (the spell check),
[`../.luacov`](../.luacov) (coverage) and [`../lychee.toml`](../lychee.toml)
(the Markdown link check).

Every command answers `--help` with its usage and options;
`tooling/tests/test_entry_points.py` discovers the commands and holds each one to
that.

`tooling/test/` (singular) is the Busted orchestration package; `tooling/tests/`
(plural) is the tooling's own unit-test suite. The names differ by one letter, so
`tooling/tests/__init__.py` states which is which. Neither directory is renamed:
both names appear in this document, in `DEVELOPMENT.md`, in the editor tasks and
in the CI workflow.

## Supported Python

`pyproject.toml` declares `requires-python = ">=3.10"` and carries no build
backend, because nothing under `tooling/` is packaged or published. The file
exists so the floor is written down once, in a machine-readable place.

`python3 -m tooling.validation.validate_repository` refuses to certify the
repository from an older interpreter, and checks that the declaration and the
constant in the validator still agree, so the two cannot drift apart. Every CI
job that runs repository tooling — the Lua tests, the linter, the spell check,
the bundle build, repository validation, the commit-subject check and the
release workflow's verification — runs on both the floor (3.10) and the current
release (3.14), so the documented minimum is exercised rather than merely
asserted. The one job on 3.14 alone is coverage, which runs the same test
orchestration the test job already runs on both interpreters, under LuaCov; a
job that could only run on the newer interpreter would make the floor a claim
instead of a supported version.

The canonical commands are documented in [`DEVELOPMENT.md`](DEVELOPMENT.md).

## Design rules

- Tooling discovers packages from repository structure and manifests.
- Runtime code never imports or depends on tooling.
- CI and editor tasks call repository tooling instead of duplicating package lists.
- Tooling should be deterministic and produce actionable repository-relative errors.
- Prefer the Python standard library for repository tooling until a third-party dependency provides clear value.
- New tooling must have focused unit tests when its behavior is more than a trivial command wrapper.
- Tooling reports the whole picture before it fails. The test runner executes every selected target and prints one summary table rather than stopping at the first failing one, and the linter runs both of its scopes before reporting.
- Tooling runs on the Python floor `pyproject.toml` declares. New tooling must not use syntax or standard-library APIs newer than that.

## Required and optional dependencies

A manifest's `dependencies` and `optionalDependencies` have the same shape and
are read by the same code, but the tools use them differently:

| Tool | `dependencies` | `optionalDependencies` |
|---|---|---|
| `validation/validate_manifests.py` | shape, existence, API generation, no self-edge | the same, plus "not also a required dependency" |
| cycle detection | rejected | not followed: a cycle closed by an optional edge is allowed |
| `test/run.py` | closure on the suite's `LUA_PATH` | each one and its required closure on the suite's `LUA_PATH`, after the required closure (for a cycle closed by an optional edge, that closure includes the package's own dependants) |
| `package/build.py` | load order, `--package` closure | ignored; recorded under `optionalDependencies` in `manifest.json` for information |
| `validate_repository.py` (`src/.luarc.json`) | closure listed | ignored |

The semantics are defined in
[`PACKAGE_MANIFEST.md`](PACKAGE_MANIFEST.md#optional-dependencies). A part's
own `dependencies` and `optionalDependencies` (next section) are treated the
same way.

## Kit parts

A Kit is a core file plus optional part files
([ADR 0001](decisions/0001-kit-core-and-parts.md)); the manifest declares the
parts ([`PACKAGE_MANIFEST.md`](PACKAGE_MANIFEST.md#parts)) and a part's file is
`src/parts/<Facade>-<Part>.lua`. One module, `tooling/package/parts.py`, holds
the rules every tool shares, so none of them can disagree about which file a
part is or when it loads:

- a **node** is a Kit's core or one of its parts;
- a core needs the cores of its required dependencies, each followed by the
  parts its contract names (`{"api": 1, "parts": ["Renderer"]}`); a part
  needs its own core, then its required dependencies the same way, then the
  sibling parts its `parts` list names;
- the load order is a depth-first walk: the selected Kits in sorted order,
  each core followed by its selected parts in manifest order, every node after
  what it needs. Without parts this is exactly the walk the builder always
  made, so a repository of single-file Kits loads, builds and checksums as it
  did before parts existed.

What each tool does with parts:

| Tool | What changes |
|---|---|
| `validation/validate_manifests.py` | the `parts` object (names, `description`, `revision`, maps, sibling lists) after the top-level `api` and `revision`; every named part exists; a part names neither its own Kit nor itself; no required cycle over cores and parts |
| `validation/validate_repository.py` | `src/parts/` holds exactly the declared parts' files, each declaring `local PART_REVISION = <n>` equal to its manifest `revision`; `src/.luarc.json` covers the closure of the core and every part |
| `package/build.py` | `--package ID` selects a core, `--part ID/Part` or `--part 'ID/*'` adds parts, `--all` takes every part; a bundle carries only its selected part files |
| `package/embeds.py` | writes the `embeds.xml` or `.toc` lines for a selection |
| `test/run.py` | `src/parts/` of every source package is on the suite's `LUA_PATH`, so a spec loads a part with `require("EventKit-Coalescing")`; what a package's parts need is on its suite's path too |
| `test/coverage.py` | a part's lines count towards its package; the summary shows a row per part; a declared part that no spec loaded fails the run |
| `lint.py`, StyLua, lua-language-server, `flavour_api.py` | nothing: they already read every file under `src/` |

### Writing an addon's `embeds.xml`

```sh
python3 -m tooling.package.build --package moduleKit --package settingsKit \
  --part 'widgetKit/*' --out Libs --embeds
```

copies the selection, with every dependency, to `Libs/MoltenCodes-Custom/`
and writes `Libs/MoltenCodes-Custom/embeds.xml`, so the addon's `.toc` names
one file, `Libs\MoltenCodes-Custom\embeds.xml`. Without a bundle,
`python3 -m tooling.package.embeds` prints the same list for a folder of the
author's choosing:

```sh
python3 -m tooling.package.embeds moduleKit settingsKit eventKit/Coalescing
python3 -m tooling.package.embeds moduleKit --root 'Libs\MoltenCodes-Custom' --toc
python3 -m tooling.package.embeds moduleKit --out embeds.xml
```

A selector is a Kit ID (its core), `ID/Part` (one part with its core) or
`ID/*` (every part). Unknown Kits and parts are refused with the closest known
name: a Kit ID typed in the wrong case, for example, is answered with
`did you mean "timerKit"?`. Both commands
use the builder's selection and walk, so the generated file and a bundle
built from the same selection list the same files in the same order.
`--footprint` prints the two tables
[`EMBEDDING.md`](EMBEDDING.md#minimum-footprint-per-kit) carries between
`<!-- generated:footprint -->` and `<!-- generated:parts -->` markers;
repository validation holds those blocks to the manifests and prints the
replacement when they drift.

## apiKit flavour files in a `.toc`

Every `.toc` the tooling writes (the bundle's, `tooling.release.library_toc`'s
for the packager, the real-client installer's bundle, and
`tooling.package.embeds --toc`) ends each apiKit flavour file line with an
inline directive that loads it only on its own client:

```toc
apiKit\flavours\Retail.lua [AllowLoadGameType standard]
apiKit\flavours\ClassicMop.lua [AllowLoadGameType mists]
apiKit\flavours\ClassicEra.lua [AllowLoadGameType vanilla]
```

The game types come from `gameTypes` in `tooling/api/flavours.json` (Retail,
Ptr and Beta `standard`); `tooling.package.toc.toc_entry` adds the directive,
and `entry_to_bundle_path` drops it again, so `--verify` and the load order
compare paths. warcraft.wiki.gg, "TOC format" (read 2026-11-15), documents
inline directives on file lines since patch 11.1.5, included in Mists of
Pandaria Classic 5.5.4 and Classic Era 1.15.9, and says a list naming no
recognised game type still loads the file. On host Lua 5.1, compiling all
five files takes 11.4 ms and allocates 6.4 MB; one Classic file 1.8 ms and
1.6 MB; Retail with Ptr and Beta 7.8 ms and 4.3 MB. Held memory does not
change: ApiKit discarded the other flavours' installers already. `embeds.xml`
has no such directive; an embedder lists only the flavours it ships. Two
facts the page does not state are checked by the ApiKit client suite:
whether the client honours the directive, and which game type a Retail test
realm or beta client reports. Whether Burning Crusade Classic Anniversary
2.5.6 reads it is not known; that client has no ApiKit flavour, so no flavour
file applies there whichever way it reads the line.

## Shared helper blocks

Every Kit is embeddable on its own, so the small helpers each needs live in
its own file. Written by hand they drifted (28 copies of `isSecret` had 10
bodies, 18 of `describeKey` 5). Each helper now has one source under
`tooling/shared/lua/`, and a Kit carries a verbatim copy between markers:

```lua
-- shared:begin validateFacade 1 __FACADE__=GlowKit
-- Copied from tooling/shared/lua/validateFacade.lua by python3 -m tooling.shared.sync; edit that file, not this copy.
local function validateFacade(receiver, label, level)
  ...
end
-- shared:end validateFacade
```

```bash
python3 -m tooling.shared.sync              # rewrite every block from its source
python3 -m tooling.shared.sync --check      # the gate: fail when a block differs
python3 -m tooling.shared.sync --list       # every hand-written helper still to convert
```

- **Sources.** `isSecret.lua` (the probe rule: `issecretvalue` read once at
  load, read again per call only when it was absent then; a strict boolean),
  `reportError.lua` (the host error handler through `pcall`, `print` when it
  is missing or raises), `describeKey.lua` (`<secret>`, a string as written,
  a number or boolean through `tostring`, anything else `<type>`; never a
  caller's `__tostring`), `validateFacade.lua` and `limits.lua`
  (`validateLimitUpdate`, `applyLimitUpdate` and `copyLimits` over a
  `LIMIT_RULES` table the Kit declares; the source's header documents each
  rule field). Each source names `-- shared revision: N`,
  `-- shared requires:` (blocks that must come earlier in a Kit's file) and
  `-- shared parameters:`. The body runs from `-- shared:body` to
  `-- shared:exports`; the stand-ins before it (which let the source lint and
  compile alone) and the exports after it (which the behaviour tests load)
  are never copied.
- **One main-chunk local per helper.** A block declares exactly the names a
  Kit calls and keeps any state of its own inside a `do` block, so converting
  a Kit never raises its locals (the `lua_limits` ratchet only goes down).
- **Parameters** are identifiers that are valid Lua (`__FACADE__`), replaced
  in identifiers and strings alike. Body lines are at most 90 columns, with a
  parameter measured at 14 characters, so a copy indented into a `do` block
  never needs StyLua to rewrap it.
- **Revisions and pins.** A block names the revision it was copied at; one
  older than its source fails unless `tooling/shared/pins.json` pins that
  Kit's helper to it with a reason. `optOuts` there leaves a Kit's helper off
  the migration list, also with a reason (registry opts out of every helper:
  its 1000-line budget cannot take the markers).
- **What `--check` refuses**: a block that differs from its source (it
  prints the expected text and names the source), an unknown helper, a
  missing or unknown parameter, a required block that does not come earlier,
  an unpinned older revision, a malformed or unclosed marker, a source over
  the column budget. It never fails because a Kit has no blocks: converting a
  Kit is that Kit's own change (`CONTRIBUTING.md`, "Shared helper blocks").
- **`--list`** prints every `local function isSecret|isSecretValue|
  reportError|describeKey|validateFacade|validateLimitUpdate(` outside a
  block, as `package: file:line helper (identical|compare)`: "identical"
  when its code, comments aside, is already the source's body.
- **Where it runs**: the `repository` CI job and `python3 -m tooling.lint`.
  `tooling/tests/test_shared_sync.py` covers the markers, rewriting, every
  refusal and the pins in temporary repositories, and runs
  `tooling/tests/fixtures/shared/behaviour.lua` under host Lua 5.1 (skipped
  where `lua` is absent; the `limits` CI job runs it) to prove each helper
  behaves as its header says, error levels included.

## Lua limits

Lua 5.1 refuses to compile a function with more than 200 active locals or more
than 60 upvalues, so a file that crosses either limit does not load at all.
`python3 -m tooling.validation.lua_limits` measures every function of every
runtime file (`packages/*/src/**/*.lua`, parts included) from the compiler's
own listing, `luac -p -l -l`, and fails well before either limit:

| Measure | Warns | Fails |
|---|---|---|
| main-chunk active locals | above 180 | above 190 |
| any other function's active locals | | above 190 |
| upvalues of any function | | above 50 |

"Active" is the peak number alive at one instruction, which is what the
compiler counts, not the number declared: locals of a finished `do` block no
longer count. A file at exactly the limit reports exactly 200; the unit tests
hold that calibration against the real `luac`.

The margin of 10 below the limit leaves room for the fix that needs one more
local; the warning at 180 says a file should be split (into `do` blocks or, for
a Kit, into parts) before that happens.

Files that were already above a fail line when the gate arrived are held by
`tooling/validation/lua_limits.json` at their measured value, and the value
can only go down. A measurement above its entry fails; a measurement below its
entry fails too and asks for the entry to be lowered, so an entry always
equals the measurement and raising one can never pass unseen; an entry for a
file that is no longer above the line fails as stale. After making a file
smaller, run `python3 -m tooling.validation.lua_limits --update`, which
lowers or removes entries and refuses to raise any, and commit the file. The
output names the file, the function's first line, the value and how many are
left before Lua refuses the file.

The CI job `limits` runs the gate and its unit tests with the Lua toolchain;
the `repository` job has no Lua.

## Release and development packages

A manifest's `distribution` (see
[`PACKAGE_MANIFEST.md`](PACKAGE_MANIFEST.md#distribution)) changes what each tool
does with a package:

| Tool | `"release"` (default) | `"development"` |
|---|---|---|
| `validation/validate_manifests.py` | may not depend on a development package | may depend on anything |
| `validation/validate_repository.py` | layout checks, plus its `src` and `docs` entries under `.pkgmeta` `move-folders:`, once each | the same layout checks, plus a `- packages/<id>` line under `.pkgmeta` `ignore:` and no `move-folders:` entry |
| `test/run.py` | tested | tested the same way |
| `lint.py` | linted | linted the same way |
| `package/build.py --all` | bundled | skipped, printed as skipped, listed under `skipped` in `manifest.json` |
| `package/build.py --package <id>` | builds it with its closure | refused with an error |

A fidelity suite under `packages/<id>/fidelity/` runs inside the game client, so
the linter judges it as runtime Lua, not test Lua. So are the real-client test
addons under `tests/client/`.

## Repository validation

`python3 -m tooling.validation.validate_repository` is the check that holds the
repository to the layout and cross-references the documents describe. It runs
every check below, then reports every error it found, each naming the file and,
where there is one, the line to add:

- the Python floor (see "Supported Python") and every manifest, with the
  dependency graph (`validate_manifests.py`);
- the root files the documentation points readers to;
- every package's layout
  ([`PACKAGE_MANIFEST.md`](PACKAGE_MANIFEST.md#minimum-package-layout)): the
  manifest, README and changelog, `src/` with one facade named after
  `displayName`, `tests/` with at least one `*_spec.lua`, `tests/README.md`,
  `tests/support/<displayName>TestEnv.lua`, and `docs/API.md` when the manifest
  declares `api`;
- each `src/.luarc.json` and `examples/.luarc.json` against the dependency
  closure and the example's `embeds.xml`;
- every quoted `## Interface` line, the supported-client table and the
  `.toc` of every real-client test addon and of the in-client benchmark's
  harness (see "Supported clients: one table") and the apiKit flavour table;
- `.pkgmeta`: every release package moved (`src` and `docs`) exactly once, no
  development or unknown package moved, every development package ignored,
  and every root entry except `LICENSE` and `packages/` ignored, so the
  addon-site zip carries only the Kits and the licence, like the builder's
  bundle (root entries `.gitignore` names are local output and skipped);
- the load order quoted in [`EMBEDDING.md`](EMBEDDING.md#load-order) equals the
  one the builder computes from the manifests, file by file, parts included,
  and the example `.toc` and `embeds.xml` it quotes equal the files in
  `examples/`;
- the footprint and parts tables of
  [`EMBEDDING.md`](EMBEDDING.md#minimum-footprint-per-kit), between their
  `<!-- generated:... -->` markers, equal what `tooling.package.embeds`
  renders from the manifests (see "Kit parts");
- every package's part files against its manifest (see "Kit parts");
- every manifest `version` equals the version of the first
  `## <version> — <date>` heading of the package's `CHANGELOG.md`, and that
  date is not after today (UTC), so a version is never raised without its
  changelog entry or the reverse;
- the indexes: [`README.md`](README.md) in `docs/` links every other document
  there and every package README, and
  [`../packages/README.md`](../packages/README.md) links every package;
- the GitHub metadata: a `kit: <packageId>` label in `.github/labels.yml`, a
  labeler rule for `packages/<packageId>/**` in `.github/labeler.yml`, and an
  option in the Kit dropdown of the bug report and feature request forms, for
  every package and for no package that does not exist;
- every repository-relative Markdown link names a file that exists (generated
  reference and change reports excepted);
- the package lists between generated markers (see "Generated package
  lists"): a stale block fails with the block to put in its place;
- no package is called by a word `/mct` reads as a command (`all`, `guided`,
  `combat`, `next`, `skip`);
- once `docs/records/` exists, every record file is linked from ROADMAP and
  every record there has points 1 to 9 (see "ROADMAP records").

It also prints **warnings**, which do not fail it: every `docs/API.md` that
does not follow the required skeleton (see "The docs/API.md skeleton").

## Generated package lists

A new Kit used to be written by hand into fourteen lists in nine files, and
the three package indexes gave three different purposes for every package.
Each list is now a block between markers, rendered from the manifests:

```bash
python3 -m tooling.docs.generate                 # print every block
python3 -m tooling.docs.generate --check         # fail on a stale block, print its replacement
python3 -m tooling.docs.generate --write         # rewrite every marked block in place
python3 -m tooling.docs.generate --block kit-labels
```

| Block | File | Rendered from |
|---|---|---|
| `package-total` (inline), `package-count-sentence` (inline), `package-table` | `README.md` | the count, and each package's `name` and `summary` |
| `package-index` | `docs/README.md`, `packages/README.md` | `displayName` or `name`, and `summary` |
| `package-tree`, `package-ids` (inline), `facade-names` (inline) | `docs/ARCHITECTURE.md` | `name`, `displayName` (registry left out of the naming lists) |
| `move-folders` | `.pkgmeta` | every release package's `src` and `docs` |
| `kit-labels`, `kit-labeler` | `.github/labels.yml`, `.github/labeler.yml` | every package |
| `kit-options` | both issue forms | every package |

- **Markers.** Markdown: `<!-- generated:<name> -->` and
  `<!-- /generated:<name> -->` on their own lines, or around a value inside a
  line; YAML: `# generated:<name>` and `# /generated:<name>` comment lines,
  indented like the entries they hold. Only the text between markers is
  generated; `--write` never adds a marker.
- **Order.** `registry`, then the release packages by ID (case-insensitive),
  then the development packages, in every list.
- **Purpose text** is the manifest's optional `summary` (one sentence on one
  line, at most 240 characters, ending with a full stop, no `|`), or its
  `description` when there is none.
- **A missing marker fails** too (`MARKERS_REQUIRED` in
  `tooling/docs/generate.py`), so a list cannot fall back to being kept by
  hand. The older presence checks of `validate_repository` stay as a second
  line.
- `tooling/tests/test_docs_generate.py` covers every renderer, the order,
  the markers, `--write` and the summary rules.

## The docs/API.md skeleton

Every package's `docs/API.md` carries these `##` sections, in this order:
Loading, Public surface, Secret values, Limits, Error behaviour,
Performance, Embedded copies and upgrades. Other sections may stand anywhere
after Public surface; a required one may say "None." and why
(`CONTRIBUTING.md` has the copyable skeleton). Headings inside fenced code
are ignored. Repository validation reports each departure as a warning,
with the rename to make for the old spellings (`Errors`, `Cost`, `Upgrades`,
`Embedded identity and upgrades`); `API_SECTIONS_REQUIRED` in
`validate_repository.py` turns the warnings into errors once every document
conforms.

## ROADMAP records

```bash
python3 -m tooling.docs.split_roadmap            # print the plan, change nothing
python3 -m tooling.docs.split_roadmap --write    # move the records
```

Moves every nine-point record of `docs/ROADMAP.md`, byte for byte, into
`docs/records/<package>.md` (tooling records into `docs/records/tooling.md`),
each under a heading of its title, and leaves in ROADMAP, where each run of
records stood, a table of title, package, status (the first clause of point
9) and link. A record is its `**<title>** — <kind>` line and everything up
to the next record, heading or `---` line, so an appendix such as a data
table travels with it. It belongs to the package its kind's facade names,
else the package its title starts with, else `tooling` for a tooling, test
support, packaging or documentation record; any other stops the run, named.
It ran once, on 2026-11-16: the records now live in `docs/records/` and a new record is written there directly.
`tooling/tests/test_split_roadmap.py` holds the move to byte-for-byte on a
fixture and checks every committed record can be placed.

## Lint policy: deliberate `_G` access

Selene's `global_usage` lint is deliberately left at its default severity in
[`selene.toml`](../selene.toml) instead of being switched off for the whole
repository.

Runtime packages legitimately touch `_G` in exactly two situations: reading a
World of Warcraft client API that the client publishes only as a global
(`CreateFrame`, `C_Timer`, `C_AddOns`, `IsLoggedIn`, `GetTimePreciseSec`,
`geterrorhandler`, Lua 5.1's `unpack`), and reading or creating the shared
`MoltenCodes` namespace and Registry state key through which independently
embedded copies find each other.

Each of those sites carries a one-line reason followed by the narrowest possible
suppression:

```lua
-- C_Timer is a World of Warcraft client API reachable only through the global table.
-- selene: allow(global_usage)
local wowTimerApi = rawget(_G, "C_Timer")
```

A Selene filtering comment applies to the statement that immediately follows it,
so this silences one access and nothing else. Disabling the lint repository-wide
would have been one line, but it would also silence the next `_G` access nobody
intended, which is precisely the case Design Constitution principle 9 ("No
hidden global state") exists to catch. The annotation makes every crossing of
that boundary visible in review and in `git grep global_usage`.

Test code follows the same rule. A spec that installs a fake `CreateFrame`, or
the shared fixture that stands in for the client's whole global environment,
touches `_G` deliberately and says so per site. The lint is not switched off for
test code, because "this file is a test" is not by itself a reason for any
particular global write.

## Lint scopes: runtime Lua and test Lua

`python3 -m tooling.lint` runs Selene twice, over two file sets, with two
standard libraries:

| Scope | Files | Configuration |
|---|---|---|
| runtime Lua | `packages/*/src/**`, `packages/*/fidelity/**`, `examples/*.lua`, `tests/client/**`, `tooling/bench/lua/**`, `tooling/bench/client/**` | [`selene.toml`](../selene.toml) |
| test Lua | `packages/*/tests/**`, `examples/tests/**`, `tests/support/**` | [`selene-tests.toml`](../selene-tests.toml) |

Both scopes run even when the first fails, so one broken scope cannot hide the
other. The example addon's own source is runtime code and is held to the runtime
standard: a Busted global there would be a real defect.

The only difference between the two is the standard library.
[`busted.yml`](../busted.yml) takes `lua51` as its base and adds what Busted
injects into a spec chunk — `describe`, `it`, `before_each`, `finally`,
`pending`, and luassert's `assert`, `spy`, `stub`, `mock` and `match`. Without
it every matcher chain reads as either an undefined variable or as misuse of
Lua's own one-argument `assert`.

It also *corrects* one entry rather than adding it: Lua 5.1's `error` accepts any
value as the error object, not only a string, and specs that prove the framework
preserves a `nil` or `false` error object depend on that. The bundled `lua51`
description says `string`. Because a chained std (`lua51+busted`) can only add
entries, `busted.yml` declares `base: lua51` and redefines `error` outright. The
runtime `selene.toml` keeps the stricter default.

## Supported clients: one table

The `## Interface` numbers the framework supports are written by hand in exactly
one place, [`tooling/validation/supported_clients.json`](../tooling/validation/supported_clients.json):
one entry per flavour with its name, Interface number, patch, packager TOC
suffix and whether the framework promises to run on it, plus the date the
numbers were last verified and the page they were verified against.

Every other occurrence is checked against it by
`python3 -m tooling.validation.validate_repository`:

- every `## Interface` line in `examples/*.toc`;
- every `## Interface` line quoted in `docs/EMBEDDING.md`,
  `packages/registry/docs/API.md` and, if it ever quotes one, `README.md`;
- the supported-client table in `docs/EMBEDDING.md`, row by row, and the
  verification date stated above it;
- the `## Interface` line of every real-client test addon's `.toc` under
  `tests/client/`: exactly one, listing exactly the table's numbers. A
  single-number line, which a document may quote as a per-flavour example, is
  refused there, because a test addon is never per-flavour. The installer
  writes the table's line into every test `.toc` it installs as well
  (see "Real-client install"), so an installed test addon never drifts from
  the table even before validation runs.

A quoted line may list the numbers in any order, because the client and the
packager do; it may not add, drop or repeat one. A per-flavour field such as
`## Interface-Mists:` is a different field and is not checked.

To update the numbers after a patch:

1. Read the current numbers from `Template:LatestPatchInfo` on
   warcraft.wiki.gg, or from `/dump (select(4, GetBuildInfo()))` in each client.
2. Edit `supported_clients.json`: the numbers, the patches and `verified`.
3. Run `python3 -m tooling.validation.interface_numbers` and paste the line it
   prints into every place the validator names; run it with `--table` for the
   rows of the table in `docs/EMBEDDING.md`, and update the date above that
   table.
4. Run `python3 -m tooling.validation.validate_repository` until it passes.

The update is one commit. [`RELEASES.md`](RELEASES.md) makes it a release step.

## Client API availability per flavour

`python3 -m tooling.validation.flavour_api` is the standing evidence that the
Kits run on the clients the project promises but cannot play: for every runtime
package and every promised flavour in
[`supported_clients.json`](../tooling/validation/supported_clients.json), every
client (host) name a Kit reaches must exist in that flavour's captured
documentation under
[`packages/apiKit/metadata/<flavour>/`](../packages/apiKit/metadata), or be used
only behind a test that handles its absence. CI runs it in the `repository`
job; it reads committed files only.

```bash
python3 -m tooling.validation.flavour_api                      # every package
python3 -m tooling.validation.flavour_api --package clientKit  # one package
python3 -m tooling.validation.flavour_api --verbose            # also list guarded names
```

Flavours come from the supported-client table: Retail, Mists of Pandaria
Classic and Classic Era are promised and fail the gate; the captured PTR and
beta flavours are reported and never fail; the Anniversary client has no
captured metadata and is named as not checked. A promised client without
captured metadata is an error, and so is a supported client the gate's
`CLIENT_FLAVOURS` table does not map, so a new client cannot pass unchecked.

### How references are found

[`lua_syntax.py`](../tooling/validation/lua_syntax.py) parses each file of
`packages/*/src/` as Lua 5.1 (comments and strings never produce a reference),
and [`lua_references.py`](../tooling/validation/lua_references.py) finds every
way a Kit reaches the client:

- a free name (`pairs`, `string` in `string.format`);
- a read through the global table: `rawget(_G, "CreateFrame")`, `_G.X`,
  `_G["X"]` or a local alias of `_G`; a never-reassigned string constant counts
  as the literal (`rawget(_G, PROJECT_ID_GLOBAL)`);
- a call to a reader helper: any local function that performs such a read on
  one of its parameters, directly or through another helper (`readGlobal`,
  `readHostFunction`, `readNamespaceFunction`). Helpers are discovered by
  analysing their bodies, so a new Kit's helper needs no configuration;
- a field of such a value (`C_Timer.After`, `rawget(chatInfo, name)`,
  `Enum.SendAddonMessageResult`);
- a widget method: `x:Method()` or `x.Method` where `Method` is a script-object
  method in any captured flavour;
- an event: a string literal equal to a documented event, or any upper-case
  name passed to `Connect`, `Once`, `ConnectUnit`, `OnceUnit`, `RegisterEvent`,
  `RegisterUnitEvent`, `UnregisterEvent` or `IsEventRegistered`.

A name computed at run time (`readGlobal("SLASH_" .. key)`) is a *dynamic*
reference: it can never be looked up, so it passes only when guarded. The
generated apiKit flavour files are not scanned: each is generated from its own
flavour's metadata, loaded only on that flavour, and kept equal to the metadata
by `tooling.api.generate --check`.

### How a guard is recognised

A value read from the client is *used* when it is called, indexed, operated on,
or escapes (passed as an argument, returned, stored in a table). A use is
guarded when a test that proves the value present dominates it within the same
function:

- `if type(x) == "function" then x() end`, `if x then`, `if x ~= nil then`,
  and any `and` containing such a test; `x and x()`;
- an early exit: `if type(x) ~= "function" then return end` (or `error`,
  `break`, or an `or` containing such a test) guards what follows;
- a test stored in a local assigned once:
  `local setup = type(picker) == "table" and picker.Setup or nil` followed by
  `if not setup then return end`;
- assigning a certain value (`x = function() end`), and `pcall(x, ...)`;
- a read that only ever appears inside a test is a probe and needs nothing more;
- `a or b` makes `b` an alternative: the use is satisfied on a flavour that
  provides either (`table.unpack or unpack`).

Facts never cross into a nested function, die when their variable is
reassigned, and do not survive into a loop that could invalidate them. The
known limits: a table changed through a call is not seen to invalidate facts
about it; method receivers are not typed, so a Kit object with a method named
like a widget method is reported as that method; a guard in another function
(a value stored in a table and tested by its reader) is not followed; and events
built at run time are not seen. Each of those is resolved by an allow-list
entry, never by weakening the check.

### When a name is present

A name is present on a flavour when that flavour's metadata documents it (a
global function, a namespace table, a namespaced function, an `Enum` table or
field, a script-object method, an event), or when
[`host_names.json`](../tooling/validation/host_names.json) lists it for that
flavour. That table holds the Lua standard library the client ships (from the
Lua 5.1 manual and the client's documented library list, with the source
recorded), the globals the framework itself creates (`MoltenCodes`, the
Registry state key, `wow`; never reported), and client names the documentation
leaves out, each with the file and line of the client's own interface code, at
the commit the flavour's metadata was captured from, that proves it. An entry is
added only for a name a Kit uses unguarded, and only with that evidence per
flavour.

### The allow-list

[`flavour_api_allowlist.json`](../tooling/validation/flavour_api_allowlist.json)
records the reviewed exceptions: a use the code does handle, in a way the
analysis cannot prove. An entry names the package, the API exactly as the report
prints it, the flavours it applies to, the guarding `path:line` inside that
package's `src/`, and a one-line reason:

```json
{
  "package": "clientKit",
  "api": "GetSpellInfo",
  "flavours": ["retail", "classic-mop", "classic-era", "ptr", "beta"],
  "guard": "packages/clientKit/src/ClientKit.lua:831",
  "reason": "bindHostFunctions stores the legacy global (or false) in the host table; its only reader returns nil before calling it when the entry is false."
}
```

An entry is validated as strictly as the code: an unknown key, flavour or
package, a guard outside the package or past the end of the file, a duplicate,
an entry whose package no longer references the API, and an entry for a flavour
where the API is now present or provably guarded all fail the gate. An entry
can therefore only exist while it is needed.

### Reading the report

Each package lists, per flavour, how many host names are *present*, *guarded*
(absent there, every use protected), *fallback* (absent, but every unguarded use
has an `or` alternative the flavour provides), *allow-listed* and *missing*.
Missing names are listed with every unguarded use as `file:line (why)`, and
allow-listed ones with their guard and reason; `--verbose` adds the guarded and
fallback names. The command exits 1 when a name is missing on a promised
flavour or an input (a table, the metadata, a source file) is invalid.

To fix a missing name: guard the use (a type or nil test, a ClientKit
capability, a flavour branch); if the client does provide the name but its
documentation does not, add it to `host_names.json` with evidence; only when the
code handles the absence in a way this check cannot prove, add an allow-list
entry.

## API metadata tooling

`tooling/api/` is the development-time side of `apiKit`, the flavour-aware
wrapper over the World of Warcraft API designed in
[`API_KIT_DESIGN.md`](API_KIT_DESIGN.md) and delivered as package H of the
[roadmap](ROADMAP.md#package-h--apikit-the-wow-api-wrapper). Its input is the
client's own machine-readable API documentation, the Lua tables under
`Blizzard_APIDocumentationGenerated`, as the community `wow-ui-source`
mirror publishes them per flavour branch; its output is the metadata that
every generator reads. Nothing here is a runtime dependency of any Kit, and
nothing downloaded is ever written inside the repository.

```text
tooling/api/
├── flavours.json      # the five flavours: namespaces, runtime files, mirror branches, detection facts
├── flavours.py        # reads and prints that table
├── fetch.py           # downloads one flavour's tables at a pinned mirror commit (step 1)
├── lua_tables.py      # parses the tables, which are Lua table constructors
├── naming.json        # reviewed naming data: words, aliases, exceptions
├── naming.py          # the rules that turn a Blizzard name into a wrapper name
├── types.json         # host types the tables reference but never define, with their LuaCATS spelling
├── model.py           # the metadata model and its JSON form
├── SCHEMA.md          # that JSON form, field by field
├── normalize.py       # turns a capture into a flavour's metadata directory (step 2)
├── validate.py        # the checks a metadata directory must pass
├── diff.py            # compares two captures of a flavour; change report and history (step 3)
├── render_runtime.py  # the generated Lua bindings file the client loads
├── render_types.py    # the generated LuaCATS definitions
├── render_reference.py# the generated Markdown reference and the search index
├── generate.py        # writes every output of a flavour from its metadata (steps 4 and 5)
└── heads.py           # compares every flavour's committed build with the mirror heads
```

The pipeline, as the design document lists it (section 14):

```bash
python3 -m tooling.api.flavours                                   # the flavour table
python3 -m tooling.api.fetch --heads --flavour retail             # each branch's head and build
python3 -m tooling.api.fetch --flavour retail --out ~/wow-api     # step 1: capture, outside the repo
python3 -m tooling.api.normalize --capture ~/wow-api/retail/<sha> --out packages/apiKit/metadata/retail
python3 -m tooling.api.validate packages/apiKit/metadata/retail   # what normalize ran before writing
python3 -m tooling.api.diff <previous metadata> packages/apiKit/metadata/retail   # step 3: what changed
python3 -m tooling.api.generate --flavour retail --previous <previous metadata>    # steps 4 and 5
python3 -m tooling.api.generate --all --check                     # CI: outputs match the metadata
python3 -m tooling.api.generate --all --reference-out build/reference   # the reference, locally
python3 -m tooling.api.heads                                      # which flavours are behind the mirror
```

`fetch` records the branch, commit, date, client version and build of the
capture and never downloads a pinned commit twice; when a flavour names two
mirror branches (`ptr`, `ptr2`) it takes the one whose head carries the newer
build unless `--branch` names one. `normalize` parses every table, names every
entry by the rules in `naming.py`, merges the files that describe one
namespace, keeps every marker the tables carry (a `true` boolean as a flag,
anything else as an attribute), binds a function through its own `Namespace`
attribute when the tables give it one (`InCombatLockdown` of
`C_RestrictedActions` is a global) and writes the files `SCHEMA.md` describes, but
only after `validate` has accepted the result: a wrapper name two entries
would share, a type nothing defines or an enumeration that disagrees with its
own count is a refusal with the fix named, never a suffix or a guess. Against
the Retail tables of build 69933 (612 files) the run takes about a second and
yields 391 namespaces with 6,338 functions, 1,782 events, 844 enumerations,
752 structures, 20 callbacks, 60 constants tables and 57 restriction
predicates, about 6 MB of JSON.

`generate` reads one flavour's metadata and writes everything derived from
it into the package: the runtime bindings (`src/flavours/<Flavour>.lua`, one
direct alias per function, bound only when the running client has the
namespace, and read from where each function's binding says: a function the
tables give its own `Namespace` attribute is read from the global table or
that other table, while its wrapper stays under its system's name), the LuaCATS definitions (`types/<flavour>/`) and, when
`--previous` names the metadata of the build being replaced, the change
report (`docs/changes/<flavour>/<old build>-<new build>.md`) and an entry in
`metadata/<flavour>/history.json`. The Markdown reference and the search
index are rendered on every run (a link that does not resolve refuses the
run) but written only where `--reference-out DIR` says, as `DIR/<flavour>/`
and `DIR/<flavour>/search.json`; they are not committed, and the release
workflow attaches them to each release instead. The renderers write Lua already in
the shape StyLua produces for `stylua.toml` (two-space indentation, built from
one `INDENT` constant in each renderer, and the formatter's own wrapping at
100 columns), and generated Lua is checked with `luac -p`
and the repository's StyLua configuration before anything is written, a
directory of generated files is replaced as a whole, and `--check` compares
without writing so CI can refuse a metadata change that was committed without
its outputs (the `repository` job runs it). Against the
Retail metadata the runtime file is about 9,800 lines; the measured load cost
is the "Load cost" section of `packages/apiKit/docs/API.md`. A runtime file
under `src/flavours/` that no flavour of the table owns is removed as stale.

Four files are reviewed data rather than code. `flavours.json` is the one
place that says which flavours exist and how each is sourced and detected.
`naming.json` holds the mixed-case words the generic splitter cannot see
(`PvP`, `BNet`), the short aliases (`addOnProfiler` → `profiler`) and the
exception tables that resolve a collision by hand. `types.json` lists every
type the tables reference without defining (`number`, `WOWGUID`,
`ScriptRegion`, ...) with the LuaCATS type the generators write; a new client
type is a one-line addition there, and the validator names the type and
where it is used. `python3 -m tooling.api.lua_tables PATH... [--json]` parses
tables on their own, for a look at a file the normaliser refuses.
`SCHEMA.md` is documentation, but it is checked: the model's tests hold it to
the code. `python3 -m tooling.validation.validate_repository` reads the
flavour table with the same loader and fails on a malformed entry.

Two environment variables point the test suite at real data:
`MOLTENCODES_DOCUMENTATION_SAMPLES` names a directory of the client's
documentation tables for the parser's corpus test (skipped without it; the
tables never enter the repository), and `MOLTENCODES_API_METADATA` names a
normalised metadata directory for the generators' and the diff's corpus tests,
which otherwise run against the committed Retail metadata under
`packages/apiKit/metadata/retail`, so they run in CI too.

`heads` answers the question that starts an update. For every flavour it
looks up the head of each mirror branch the flavour names, picks the one
`fetch` would capture (the highest build) and compares that build with the
`build` in `packages/apiKit/metadata/<flavour>/provenance.json`; a head whose
commit subject carries no build is never reported as newer. It prints one line
per flavour, and with `--markdown FILE` and `--github-output FILE` writes the
report and `newer=true|false` for the scheduled workflow described under
"Continuous integration". It exits 0 whether or not a flavour is behind, and 1
only when a lookup or a provenance file fails.

The builder, the standalone-addon `.toc` and the validator support the layout
`apiKit` needs: a package's `src/` holds one top-level facade and may hold
further runtime files in subdirectories, which load after the facade
([`PACKAGE_MANIFEST.md`](PACKAGE_MANIFEST.md#minimum-package-layout)). Two
package documentation directories are generated from data rather than written:
`packages/<name>/docs/changes/` (committed change reports) and
`packages/<name>/docs/reference/` (where a maintainer may build the reference
locally; it is never committed). The spell check and the Markdown link check
leave both alone, because the generator validates its own output.

## Spell check

`python3 -m tooling.spell` runs [cspell](https://cspell.org) over the Markdown
the repository publishes: `README.md`, `docs/`, every package's README,
changelog and `docs/`, and the real-client test documents under
`tests/client/`. The globs are the `files` list in
[`../cspell.json`](../cspell.json), which the runner reads, so the command line
and an editor running the cspell extension check the same files.

- **Pinned.** The runner calls `npx --yes cspell@<version>` with the release in
  `CSPELL_VERSION` in `tooling/spell.py`; nothing is installed into the
  repository. That release needs Node 22.18 or newer. The pin covers cspell
  itself only: `npx --yes` resolves cspell's own dependencies within the version
  ranges that release declares, so two runs months apart can use different
  transitive versions. There is no lockfile, because the repository ships no
  Node project; if a dependency update ever changes the result, pin it here.
- **British and American English.** The language is `en,en-GB`, because the
  documentation is written with British spellings ("behaviour", "licence") and
  both are correct English.
- **Code blocks are skipped.** Fenced blocks hold Lua, shell and `.toc` text that
  other gates own. Inline code spans are checked, which is why the dictionary
  holds a few all-lowercase client functions.
- **Without Node** the command prints a note and exits 0, so a contributor
  without Node is not blocked. CI passes `--require`, which turns the same case
  into a failure, and additionally runs the integration tests in
  `tooling/tests/test_spell.py` against the real cspell; they are skipped
  unless the environment switch named at the top of that file is set, so the
  ordinary unit suite stays offline.

### Adding a word

The project dictionary is [`tooling/spell-words.txt`](../tooling/spell-words.txt).
A word belongs there only when it is spelled correctly and the documentation
uses it on purpose: a client API name, a Lua or tool term, a domain term. Put it
under the heading that says why it is there, in alphabetical order within that
group (a unit test checks the order). cspell already splits `camelCase` and
`PascalCase`, so names such as `SignalKit` or `GetTimePreciseSec` never need an
entry. A typo is fixed in the document, never added to the dictionary.

## Real-client install

`python3 -m tooling.client.install` puts the real-client tests
([`../tests/client/README.md`](../tests/client/README.md)) into a game folder
and takes them out again. It is the only tool that writes outside the
repository and a temporary directory, so it is deliberately narrow:

```bash
python3 -m tooling.client.install --wow-dir DIR [--flavour-dir _retail_] --package ID [--package ID ...] [--dry-run]
python3 -m tooling.client.install --wow-dir DIR [--flavour-dir _retail_] --all [--dry-run]
python3 -m tooling.client.install --wow-dir DIR [--flavour-dir _retail_] --remove [--dry-run]
```

`--all` installs the test addon of every package that has one under
`tests/client/` (41 today) and names the packages without one (testKit).

- **Flavours.** `--flavour-dir` names the client folder under the game folder:
  `_retail_` (the default), `_classic_era_` (Classic Era, which Hardcore and
  Season of Discovery share) or `_classic_` (Mists of Pandaria Classic), the
  promised flavours, or `_anniversary_` (Burning Crusade Classic Anniversary,
  listed but not promised), the names the Battle.net launcher creates.
  `tooling/client/flavours.py` holds that table with each flavour's ID,
  `WOW_PROJECT_ID` and row of `supported_clients.json`, and
  `tooling/tests/test_client_flavours.py` holds it to `tooling/api/flavours.json`
  and to that table's `promised` flags. Any other folder (a test realm's
  `_ptr_` folder, say) is accepted by the installer, but its runs never enter
  the result matrix.
- **Install** builds the bundle with `tooling.package.build` (`--all`) into a
  temporary directory and copies, under `<DIR>/<flavour>/Interface/AddOns`,
  `MoltenCodes/`, the harness `MoltenCodesTest/` with a fresh copy of
  `packages/testKit/src/TestKit.lua` and a generated `Expected.lua`, and
  `MoltenCodesTest_<Facade>/` for each `--package`.
  A package without a test addon under `tests/client/` is refused. Exactly
  these folders are replaced when they exist; only `.toc` and `.lua` files are
  copied from the repository's addon folders.
- **One `## Interface` line for every flavour.** Every `.toc` of the harness
  and the test addons is written with the line
  `python3 -m tooling.validation.interface_numbers` prints, taken from
  `supported_clients.json` at install time, the same line the bundle's
  generated `.toc` carries. The committed `.toc` files carry it too, and
  repository validation holds them to it; every other line is copied as
  committed.
- **`Expected.lua`** lists every bundled package plus TestKit with the API,
  revision and version of its committed manifest, and the installation: the
  commit `git rev-parse HEAD` names, `dirty = true` when `git status
  --porcelain` lists any change (untracked files included), the flavour folder
  and the UTC time. Outside a git checkout the commit and the flag are `nil`.
  The harness saves the installation with every result, which is how
  `tooling.client.report` ties a run to the commit that was installed. The
  install report and `--dry-run` print the commit.
- **Remove** deletes `MoltenCodes`, `MoltenCodesTest` and every
  `MoltenCodesTest_*` entry of `AddOns`, and every `MoltenCodesTest.lua`,
  `MoltenCodesTest_*.lua` and their `.bak` copies under `WTF/Account/*/SavedVariables/` and
  `WTF/Account/*/*/*/SavedVariables/`, so no saved results stay behind. It
  also drops the lines naming those addons from every `WTF/Account/*/AddOns.txt`
  and `WTF/Account/*/*/*/AddOns.txt`, the client's addon list, which keeps a
  line for an addon after its folder is gone; every other line, its order and
  its line ending stay as the client wrote them. Run `tooling.client.report`
  first: removing deletes the saved results.
- **Safety.** Both refuse, with exit status 1, when the `AddOns` folder does
  not exist. A symbolic link is removed as a link and never followed; a
  saved-variables folder or `AddOns.txt` reached through a link out of the
  game folder is reported as skipped. `--dry-run` prints every path it would install or
  remove, the `## Interface` line and the commit, and changes nothing.

`tooling/tests/test_client_install.py` runs both against a fake game folder in
a temporary directory, with a neighbouring addon and saved variables that must
survive.

## Real-client sessions

```bash
python3 -m tooling.client.session prepare --wow-dir DIR [--flavour-dir _retail_] [--packages ID,...] [--dry-run]
python3 -m tooling.client.session collect --wow-dir DIR [--flavour-dir _retail_]
python3 -m tooling.client.session clean   --wow-dir DIR [--flavour-dir _retail_] [--force] [--dry-run]
```

- **`prepare`** is `install --all` (or the named packages) plus a session
  sheet, printed and written to `<DIR>/<flavour>/MoltenCodesTest-session.txt`:
  the in-game lines in order (`/mct run all`, `/mct run guided`, `/mct run
  combat`, `/reload`, settingsKit's second run, `/reload`), the preconditions
  each `EXPECTED.md` names (its "Before the run" paragraph and the first
  paragraph of "Combat run", "The procedure" and "Per flavour"), the suites
  registered with `interactive = "..."`, and each package's expected totals
  from its `EXPECTED.md` totals line.
- **`collect`** runs `tooling.client.report` for the flavour, then prints per
  package "as expected", "differs" (both totals) or "not run", comparing the
  default run, or else the unattended and guided runs summed. A difference is
  reported, never fatal. It writes `MoltenCodesTest-collected.txt` with the
  collected installation's time.
- **`clean`** is `install --remove` plus the sheet and the marker, refused
  while the installed `Expected.lua`'s installation time is not the one
  `collect` recorded; `--force` overrides and says so.
- `tooling/tests/test_client_session.py` covers the sheet, the comparison and
  the clean gate; `tooling/tests/test_client_harness.py` runs
  `tooling/tests/fixtures/harness/Harness_spec.lua`, which drives the
  harness's `/mct run all`, `/mct run guided`, `/mct next` and `/mct skip`
  over the Kits in the fake client (CI's `test` job).

## Real-client results

`python3 -m tooling.client.report` turns what the harness saved into the
committed result matrix. It only reads the game folder:

```bash
python3 -m tooling.client.report --wow-dir DIR [--flavour-dir NAME ...] [--dry-run | --check]
python3 -m tooling.client.report --saved-variables FILE [--saved-variables FILE ...] [--dry-run | --check]
python3 -m tooling.client.report --unavailable FLAVOUR=REASON | --available FLAVOUR
python3 -m tooling.client.report --check
```

- **Inputs.** With `--wow-dir` it reads
  `<DIR>/<flavour>/WTF/Account/*/SavedVariables/MoltenCodesTest.lua` (the
  harness's variable is account-wide; `.bak` copies are never read) for each
  `--flavour-dir`, or for every one of `_retail_`, `_classic_era_`,
  `_classic_` and `_anniversary_` that exists. `--saved-variables` names a file directly, for
  example one the owner sent. A run is attributed to the flavour its client
  reported (`client.projectId`), then to the installer's flavour folder, then
  to the folder the file was found in. A run on a test build
  (`client.testBuild`) or installed into a folder that is not a known flavour
  is reported as a warning and left out: the matrix records live clients.
- **Parsing.** The file is read as bytes and decoded as UTF-8 with
  `errors="replace"`, because the client may write bytes that are not UTF-8.
  `tooling/client/saved_variables.py` parses the Lua literal subset the client
  writes (strings with every Lua 5.1 escape and long brackets, numbers
  including hexadecimal and the C runtime's spellings of infinity and NaN,
  booleans, `nil`, table constructors, comments) and never executes anything;
  a file that holds anything else is refused with its line and column.
- **The record.** `tests/client/results.json` is the one source of truth: a
  row per flavour, package and run mode (`default` or `combat`) with the
  totals, the skipped tests and their reasons, the failed and timed-out tests
  and their messages, the build, interface, locale, operating system, date
  and the installed commit with its dirty flag. A run replaces the row of its
  flavour, package and mode unless the recorded row is newer; every other row
  is kept with its own date and commit. The record also keeps, per flavour,
  why no session of it can run for now: `--unavailable FLAVOUR=REASON` sets
  it (refused for a flavour with recorded runs), `--available FLAVOUR` drops
  it, and a recorded run of the flavour drops it on its own. The rows moved from the README's
  first Retail table carry the ISO 8601 interval `2026-09-24/2026-09-25`, no
  commit and no skip reasons, and show them as such.
- **The matrix.** `tests/client/RESULTS.md` is rendered from the record and
  never edited: a status line per known flavour (packages recorded, or
  `not run` with the reason), one column group (tests, passed, failed,
  skipped, timeout) per promised flavour and per optional flavour that has a
  run, a runs table per flavour (build, interface, locale, OS, date,
  commit), every skipped test with its reason, every failure, and the gaps:
  Windows, group communication with a second character, conditions a solo
  session cannot create, flavours and packages without a run, and combat runs
  not recorded yet (packages whose suites use the `combat = true` option).
- **`--check`** writes nothing and exits 1 when either file differs from what
  the command would write for the given inputs; without inputs it checks that
  the matrix is what the record renders. **`--dry-run`** prints each row it
  would add or update and the files it would write.

`tooling/tests/test_client_report.py` and
`tooling/tests/test_client_saved_variables.py` run the command and the parser
against the fixtures in `tooling/tests/fixtures/client/`: a schema 2 file with
a combat run, escapes and a byte that is not UTF-8, and a schema 1 Classic Era
file with an entry the command must skip with a warning.

## Release tooling

`tooling/package/build.py` assembles the distributable bundle: it copies each
package's runtime sources and package-owned documentation into the layout an
addon embeds, writes the bundle's own `.toc` so the bundle also installs as an
addon (`MoltenCodes/MoltenCodes.toc` for `--all`,
`MoltenCodes-<Facade>/MoltenCodes-<Facade>.toc` for a selection within one Kit,
`MoltenCodes-Custom/MoltenCodes-Custom.toc` or the `--name` given for any other
selection), writes a `manifest.json` describing versions, revisions, licences,
parts, the load order and the `.toc`, with `--embeds` an `embeds.xml`, and
writes SHA-256 checksums into `CHECKSUMS.txt`. What a selection is and how it
loads is described under "Kit parts".
`tooling/package/toc.py` holds the `.toc` field conventions and renders the
text; which packages it lists, and in what order, comes from the builder.

It is deliberately deterministic — no timestamps in the artifact, fixed zip entry
times — so two builds of the same commit produce identical checksums. It fails
closed on invalid package metadata but does not run the test suite, the linter or
the formatter; those are separate commands and remain the caller's responsibility.

`--verify` reads the `CHECKSUMS.txt` it has just written back and holds it
against the files on disk. It reports a recorded file that is missing, a
recorded file whose contents no longer hash to what was written down, and a file
inside the bundle that nothing records at all, and it exits non-zero if it finds
any of them. Bundles from earlier builds that the checksum file does not
describe are left alone, so a single-package bundle sitting beside the full one
is not mistaken for an unrecorded file. It then checks the bundle's `.toc`: its
file lines must equal `manifest.json`'s `loadOrder`, in order, and every `.lua`
file in the bundle must be listed. A bundle built with `--embeds` has its
`embeds.xml` held to the same `loadOrder`.

CI builds the whole framework into a temporary directory on every run and checks
the result twice: once with `--verify`, and once with `sha256sum --check
--strict`, which is what somebody who downloads the artifact would use. The
first proves the file is correct, the second proves it is also readable by the
standard tool.

[`../docs/RELEASES.md`](../docs/RELEASES.md) documents the command line, the
artifact layout, and the relationship to [`../.pkgmeta`](../.pkgmeta), which is
what the addon-site packagers build from.

## Release tooling: tags and notes

`tooling/release/` supports the release workflow
([`.github/workflows/release.yml`](../.github/workflows/release.yml)); the
procedure is in [`RELEASES.md`](RELEASES.md#release-procedure).

- `python3 -m tooling.release.check_tag <tag>` checks one of the two tag kinds.
  A bundle tag `v1.2.0` needs a `### v1.2.0` section under `## Release history`
  whose "`<packageId>` <version>" lines name every release package once, at
  exactly its manifest version, and nothing else. A package tag
  `timerKit-v0.6.0` needs `timerKit` to be a release package whose manifest
  version is `0.6.0`, and a `### timerKit-v0.6.0` section. Errors carry the line
  number in `RELEASES.md`. `--github-output FILE` appends `tag`, `kind`,
  `package` and `version` to `FILE` on success, which is how the workflow's
  `resolve` job exports them; `check_tag.parse_tag` is the same split for
  Python callers.
- `python3 -m tooling.release.notes <tag>` prints that section, which becomes
  the draft GitHub release's text; it exits 1 when there is none.
- `python3 -m tooling.release.library_toc` prints the `.toc` of the standalone
  addon `MoltenCodes`: the `## Interface` line from the supported-client table,
  the title, notes, version placeholder and site fields, then every release
  Kit in load order. `--package <id>` prints the `.toc` of
  `MoltenCodes-<Facade>` instead, loading that Kit and the Kits it requires;
  `--write DIR` writes `<addon>.toc` into `DIR` instead of printing it. The text
  is the one the builder writes into its bundles. There is no `--layout`
  option, because the builder's bundle and the packager's zip share one
  layout.
- `python3 -m tooling.release.pkgmeta --package <id>` prints the repository's
  `.pkgmeta` narrowed to one Kit: `package-as: MoltenCodes-<Facade>`, only that
  Kit's closure in `move-folders`, every other package in `ignore`.
  `--output FILE` writes it and ignores `FILE` in it. The workflow hands the
  result to the packager with `-m` for a package tag.
- `python3 -m tooling.release.publish_mode --kind <bundle|package> ...` holds
  the `publish` job's rules: `-d` when `dry_run` is on, a site variable is
  missing or the tag is a package tag; a draft GitHub release only when the
  run's ref is the released tag. `--github-output FILE` appends `args` and
  `draft`.

The release notes live in `RELEASES.md` rather than in a generated release
manifest because the package manifests already are the machine-readable record
of every version; a second file would be a second list to keep in step.

## Coverage

`python3 -m tooling.test.coverage [target ...]` runs the same suites as
`python3 -m tooling.test.run`, each in its own Busted process, with Busted's
`--coverage` flag, then runs `luacov` and prints one row per package: lines hit,
lines missed and the percentage. [`../.luacov`](../.luacov) limits the
measurement to `packages/*/src/`, so specs, the shared fixture and the example
addon do not dilute a package's figure. It also excludes apiKit's generated
flavour files: a session loads only one of them, so which flavour a spec loads
moved apiKit's figure by whole points with no code change; the bindings specs
and `tooling.api.generate --check` prove those files, and coverage measures the
hand-written facade. LuaCov adds every process to one
statistics file; the command deletes the previous `luacov.stats.out` and
`luacov.report.out` first, and both are ignored by Git. `--summary FILE` appends
the table as Markdown, which is how CI fills its job summary.

It needs LuaCov in the same Lua 5.1 tree as Busted (`luarocks install luacov
0.17.0-1`, see [`DEVELOPMENT.md`](DEVELOPMENT.md)).

A Kit's part files are part of its package: their lines count towards the
package's figure, and the summary shows each measured part on a row of its
own under its package. LuaCov reports only the files a run executed, so a part
no spec loads would otherwise be invisible rather than at 0 %; a declared part
of a judged package that no spec loaded therefore fails the run, naming the
`require` that would load it.

The run is a gate, in two parts (three, for a Kit with parts).

- **Every spec passes.** LuaCov's line hook allocates on every line it counts,
  so the allocation specs, which prove that a hot path allocates nothing, would
  fail while it is active. Each of them carries the Busted tag `#allocation`
  ([`TESTING.md`](TESTING.md#allocation-guards-carry-the-allocation-tag)), and
  the command passes `--exclude-tags=allocation` through the test runner
  (`ALLOCATION_TAG` in `tooling/test/run.py`). Every other spec must pass;
  `python3 -m tooling.test.run` still runs the tagged ones, so the `test` job
  keeps judging them.
- **Every package meets its floor.**
  [`../tooling/test/coverage-floors.json`](../tooling/test/coverage-floors.json)
  holds one whole percentage per package, its line coverage when the floor was
  last set, rounded down. A package below its floor fails the run, and so does
  a measured package without a floor. On a run of every target, a floor whose
  package produced no measured line fails too. The printed table (and the job
  summary) has a floor column that marks a failing row `below` or `missing`.

Floors are a ratchet, not a target: they record what the specs already reach
so that coverage cannot silently fall, and they only move up.
`--update-floors` raises each judged package's floor to its measured value
rounded down, adds any package without one, and never lowers a floor; it
refuses to write after a run with failing specs. Run it after a change that
adds specs, and once for a new package, and commit the file with the change.
Lowering a floor is a deliberate hand edit that the pull request explains
(for example, code moved to another Kit).

A run of selected targets judges only those packages: `timerKit`'s suite also
executes part of `registry`, but not `registry`'s own specs, so that partial
figure is shown as `not judged`. The command exits 0 when every spec passed and
every judged package met its floor, 1 when a spec failed, a floor was missed or
missing, or `luacov` wrote no report, 2 when the floors file is missing or
malformed or a target is unknown, and 127 when Busted or `luacov` is missing.

## Continuous integration

[`.github/workflows/ci.yml`](../.github/workflows/ci.yml) runs on every push to
`main` and every pull request. Its jobs, each with read-only permissions and a
timeout:

| Job | What it checks |
|---|---|
| `test` | `python3 -m tooling.test.run`: every package suite and the example addon, under Lua 5.1.5 and Busted, with full history so an opted-in conformance suite upgrades from the committed previous revision; then the conformance suite's and the client harness's own Busted-driven tests |
| `coverage` | `python3 -m tooling.test.coverage`: every spec but the `#allocation` ones passes under LuaCov and every package meets its floor; the per-package table with floors in the job summary, the LuaCov report as the `luacov-report` artefact |
| `types` | `lua-language-server --check` for every package source directory, `examples/` and `tests/client/` |
| `format` | `stylua --check .` |
| `lint` | `python3 -m tooling.lint`, both scopes |
| `package` | `tooling.package.build --all --verify`, then `sha256sum --check --strict`; on a push to `main`, the bundle is uploaded as the artefact `MoltenCodes-<commit>` |
| `spell` | `python3 -m tooling.spell --require` and the cspell integration tests |
| `repository` | repository validation, `tooling.api.generate --all --check`, `python3 -m tooling.validation.flavour_api`, `tooling.shared.sync --check`, `tooling.docs.generate --check`, the tooling unit tests, `compileall` |
| `limits` | `python3 -m tooling.validation.lua_limits` and its unit tests, and the shared helpers' behaviour tests, with the Lua 5.1 toolchain (see "Lua limits") |
| `commits` | pull requests only: `python3 -m tooling.ci.check_commits` over the new commits and the title |
| `secrets` | gitleaks over the whole history, with found values redacted from the log |
| `workflows` | actionlint (and the shellcheck it runs) over every workflow |
| `ci` | needs every job above and fails if any failed or was cancelled |

Branch protection requires the one check `ci`, so adding a gate means adding
it to that job's `needs`, not editing the protection rule. The workflow has no
path filter: every file is judged by some gate, and a skipped workflow would
leave the required check waiting. Jobs that run repository tooling use both
supported Pythons, as described above; `coverage` runs once, on 3.14, because
it measures Lua, not Python.

Why some jobs do more than pass or fail:

- **`coverage`** is a gate (see "Coverage") and also shows, per Kit, which
  lines no spec reaches. It stays inside the repository (an artefact and a job
  summary, no external service or token). The summary and the artefact are
  written even when the gate fails, so a missed floor can be read from the run
  itself. Its 45-minute timeout leaves room for the instrumented suites, which
  run several times slower than the `test` job's.
- **The `package` artefact** makes every merged commit installable without a
  release: download `MoltenCodes-<commit>`, drop its `MoltenCodes/` folder into
  `Interface/AddOns`. It is uploaded from one matrix row (the builds are
  byte-identical) and kept for 30 days.
- **`commits`** holds every commit subject and the pull request title to
  `type(scope): subject` (`CONTRIBUTING.md`), because a squash merge turns the
  title into the commit on `main` and `RELEASES.md` is written from that
  history.

### The Lua toolchain

The `test` and `coverage` jobs and the release workflow's `verify` job share
the local composite action
[`.github/actions/setup-lua`](../.github/actions/setup-lua/action.yml). It
builds Lua 5.1.5, LuaRocks 3.13.0, Busted 2.3.0-1 and LuaCov 0.17.0-1 with
hererocks, the same way [`DEVELOPMENT.md`](DEVELOPMENT.md) builds them locally,
into `~/.local/lua51`, and caches that tree with `actions/cache`. The cache key
is every one of those versions plus the runner image, so a version bump or a
new image rebuilds the tree and anything else restores it in seconds instead of
compiling Lua and installing the rocks on every run. The versions are the
action's input defaults, in one place.

On a cache miss the action fetches `lua-5.1.5.tar.gz` itself before hererocks
runs: from lua.org and then two PUC-Rio mirrors, each with retries, accepted
only when it matches the `lua-sha256` input. The verified archive is handed to
hererocks through `--downloads`, so hererocks downloads no Lua source of its
own. hererocks alone tries each source once, and a slow lua.org handshake on
2026-11-11 failed the `test` job that way. A Lua version bump changes
`lua-version` and `lua-sha256` together.

### Pins

Every `uses:` is pinned to a full commit SHA with the release it came from in a
trailing comment. [`.github/dependabot.yml`](../.github/dependabot.yml) proposes
updates to those pins once a week, in the workflows and in the composite
action, grouped into one pull request with a `ci(deps):` subject. The
downloaded binaries (Selene, StyLua, lua-language-server, actionlint, gitleaks
and lychee) are pinned by version and SHA-256 in each workflow's `env` and are
bumped by hand, both values in the same change; so are the toolchain versions
of the composite action. gitleaks runs as the release binary rather than
through its action, because the action needs a licence key for repositories
that belong to an organisation, and lychee runs as the release binary so it is
checksum-verified like the others.

### Other workflows

These maintain the repository rather than judge a change:

| Workflow | What it does |
|---|---|
| [`links.yml`](../.github/workflows/links.yml) | lychee over every Markdown file with [`../lychee.toml`](../lychee.toml): external URLs and `#fragment` anchors; on pull requests and pushes that change Markdown, and weekly |
| [`api-heads.yml`](../.github/workflows/api-heads.yml) | daily, `python3 -m tooling.api.heads` for every flavour; keeps one issue, "apiKit: the mirror carries a newer client build", open while any flavour's committed metadata is behind the mirror and closes it once all are current |
| [`labels.yml`](../.github/workflows/labels.yml) | applies [`.github/labels.yml`](../.github/labels.yml), the source of truth for labels, on a push to `main` that changes it; a hand-started run from another branch is a dry run |
| [`pr-labeler.yml`](../.github/workflows/pr-labeler.yml) | labels a pull request `kit: <packageId>` and `area: ...` from the paths it changes, following [`.github/labeler.yml`](../.github/labeler.yml) |
| [`stale.yml`](../.github/workflows/stale.yml) | marks issues inactive for 60 days `stale` and closes them 30 days later; never touches pull requests or issues labelled `pinned`, `security` or `roadmap` |
| [`release.yml`](../.github/workflows/release.yml) | builds and drafts a release; see [`RELEASES.md`](RELEASES.md#the-release-workflow) |

The link check is its own workflow, not a `ci` job, on purpose: whether an
external page answers depends on that site, not on the change under review, so
as a required check it would fail pull requests at random. Repository-relative
links stay a gate through repository validation. lychee adds external pages and
heading anchors (which the validator does not follow), keeps a one-day cache of
confirmed pages between runs, treats `429 Too Many Requests` as success and
retries transient failures; links to this repository's own pages on github.com
are excluded, because from a pull request they name content that only exists
after the merge.

The mirror-heads workflow turns "a new client build shipped" from something a
maintainer has to notice into an issue. It is idempotent: one run at a time
(its concurrency group queues rather than cancels), the issue is found by its
exact title and label, its body is rewritten only when the report changes, and
the report depends only on builds and commits, never on the time of the run.
It uses the job token alone, to raise the GitHub API rate limit for the
mirror's public commit lookups and to write that one issue.

A new Kit needs a `kit: <packageId>` label in `labels.yml`, a matching rule in
`labeler.yml` and an option in the Kit lists of the bug report and feature
request forms under `.github/ISSUE_TEMPLATE/`; repository validation fails
until all four exist.

## Host benchmark

`tooling/bench/` compares Kits with the Ace3 libraries that do the same work,
on host Lua 5.1. [`BENCHMARKS.md`](BENCHMARKS.md) is the full account: the
principles, the methodology, each workload, what was stubbed for Ace3 and why
that is fair, the in-client runner and the measured results.

```text
tooling/bench/
├── ace3.py          # fetches Ace3 at the pinned commit into a cache outside the repository
├── host.py          # records the CPU, OS, memory, load and the commit a run measured
├── workloads.py     # the workload catalogue: name, Lua module, what it compares
├── run.py           # runs every case in its own Lua process and writes raw JSON
├── report.py        # renders a results file as Markdown
├── lua/             # the Lua side: main.lua, Bench.lua (measurement), BenchHost.lua and
│   └── workloads/   #   SimulatedTimers.lua (the shared host), one module per workload
└── results/         # committed raw results, one file per run: <date>-host.json
```

```bash
python3 -m tooling.bench.run [--workload NAME ...] [--rounds N] [--repeat N] [--warmup N] [--out FILE]
python3 -m tooling.bench.report tooling/bench/results/<date>-host.json [--out FILE]
python3 -m tooling.bench.ace3 [--cache DIR]   # fetch only; run does this itself
```

- **Ace3 is never in the repository.** `run` fetches the source archive of the
  pinned commit into `$MOLTENCODES_BENCH_CACHE`, `$XDG_CACHE_HOME/moltencodes-bench`
  or `~/.cache/moltencodes-bench`, refuses a cache inside the repository, and
  checks a SHA-256 over the files it loads against the digest pinned in
  `ace3.py`, so a changed upstream archive fails the run instead of changing
  what is measured.
- **One process per case and side.** The Lua side runs under the interpreter
  the toolchain installs (`~/.local/lua51/bin/lua`, or `--lua`,
  `$MOLTENCODES_BENCH_LUA`), with every Kit's `src/`, the shared fake client
  and `tooling/bench/lua/` on `LUA_PATH`. Each case runs in `--rounds` fresh
  processes per side, the two sides interleaved, so load changes during a run
  fall on both.
- **Not a gate.** Timing depends on the machine and on what else runs on it,
  so no CI job runs the benchmark and no threshold exists. CI runs only the
  unit tests (`tooling/tests/test_bench.py`, no network, no Lua), with the
  rest of the tooling tests. A smoke job was left out on purpose: it would
  have to download Ace3 on every run or cache a copy in CI, and the unit tests
  plus the correctness checks every local run prints cover what such a job
  would catch.
- **Lint.** The benchmark's Lua is plain Lua 5.1 run outside Busted, so
  `python3 -m tooling.lint` holds it to the runtime scope (`selene.toml`)
  alongside `tests/client/`.

## In-client benchmark

The in-client runner measures the same comparison inside the game client,
plus what only the client shows (native calls, real windows, timers on the
client's clock, a real throttled whisper, frame time and memory over a
session). [`BENCHMARKS.md`](BENCHMARKS.md#in-client-runner) is the full account:
the addons, the client host, the client-only workloads, the methodology and
how the owner runs it step by step.

```text
tooling/bench/
├── client_workloads.py   # which host workloads run in the client, why the others do not, the client-only ones
├── client_install.py     # installs the harness and the two side addons into a game folder, or removes them
├── client_report.py      # reads the harness's saved variables into results/<date>-client-<flavour>.json
└── client/
    ├── .luarc.json       # lua-language-server settings for the folder
    ├── MoltenCodesBench/ # the harness addon: .toc, Loader.lua (modules without require), Harness.lua (/mcb)
    └── lua/              # ClientBench.lua (measurement), ClientHost.lua (the host interface over the client)
        └── clientWorkloads/  # the client-only workloads, their adapters and frame statistics
```

```bash
python3 -m tooling.bench.client_install --wow-dir DIR --plan smoke|all [--rounds N] [--reload-seconds S]
python3 -m tooling.bench.client_install --wow-dir DIR [--flavour-dir _retail_] [--cache DIR] [--dry-run]
python3 -m tooling.bench.client_install --wow-dir DIR [--flavour-dir _retail_] --remove [--dry-run]
python3 -m tooling.bench.client_report --wow-dir DIR [--flavour-dir NAME ...] [--out FILE] [--markdown FILE] [--dry-run]
python3 -m tooling.bench.client_report --saved-variables FILE [--saved-variables FILE ...] [--out FILE] [--dry-run]
python3 -m tooling.bench.client_report --render FILE [--markdown FILE]
```

- **Install** builds the release bundle into a temporary directory, fetches
  (or reuses) the pinned Ace3 cache exactly as `tooling.bench.run` does and
  checks its digest again, then replaces `MoltenCodesBench`,
  `MoltenCodesBench_Kits` and `MoltenCodesBench_Ace3` under
  `<DIR>/<flavour>/Interface/AddOns`. The harness gets its committed `.lua`
  files, `modules/` (every Lua module under `tooling/bench/lua/` except the
  host's `main.lua`, `BenchHost.lua` and `SimulatedTimers.lua`, and every
  module under `tooling/bench/client/lua/`, each wrapped in one
  `DefineModule` call opened on its first line so line numbers survive), its
  `.toc` with the module list in place of the `# @modules@` line, and a
  generated `Installation.lua`. The Kits side gets the bundle's Lua files and
  licence and `LibStub/LibStub.lua`; the Ace3 side gets the files of
  `ace3.LOADED_FILES` verbatim, licence included. Both sides are
  `## LoadOnDemand: 1` with `## Dependencies: MoltenCodesBench`, and every
  `.toc` carries the supported-client `## Interface` line. No other addon is
  touched; `--dry-run` changes nothing and downloads nothing. Ace3 is never
  in the repository: copying it into the local game folder is use, not
  redistribution.
- **Sets.** Install also writes one load-on-demand side addon per set of
  `client_workloads.SIDE_SETS` and side, for the `login` and
  `savedVariables` workloads: `MoltenCodesBench_KitsMinimum` and
  `MoltenCodesBench_Ace3Minimum`, `..._KitsTypical` and `..._Ace3Typical`,
  `MoltenCodesBench_Ace3Full` (every pinned Ace3 file, AceConfigDialog-3.0
  included; the full Kits set is the Kits side itself), and
  `MoltenCodesBench_KitsSaved` and `MoltenCodesBench_Ace3Saved`, each with one
  `## SavedVariables`. A Kit set is a builder selection of its Kits' cores,
  so it follows the manifests and parts. `Installation.lua` names each side's
  sets and carries the profiles.
- **Profiles and the planner.** `smoke` is 13 cases (one headline case per
  shared workload, `window open-close-drawn`, `timersLive oneshot-fire-1000`,
  `session load-60s` and `memory-300s`), 26 sessions with both sides; `all`
  is every case (the shared cases from the newest host results file). `/mcb
  run smoke|all [rounds]` queues one; `--plan` prints the sessions, reloads
  and an estimate (case lengths plus `--reload-seconds`, 20 by default, an
  assumption it states) and installs nothing.
- **Remove** deletes `MoltenCodesBench` and every `MoltenCodesBench_*` entry
  of `AddOns`, every `MoltenCodesBench.lua` and `.lua.bak` under
  `WTF/Account/*/SavedVariables/` and `WTF/Account/*/*/*/SavedVariables/`
  (and the saved sets' `MoltenCodesBench_*.lua`),
  and the bench addons' lines in every `AddOns.txt`, with the same link and
  line-ending care as the test installer (whose removal helpers it shares,
  with its own notion of which addons it owns). The two installers never
  remove each other's addons.
- **Report** reads the account-wide `MoltenCodesBench.lua` of each flavour
  folder (or the files given) without running Lua, keeps the most recent
  installation's entries, leaves out test builds, and writes one
  `kind = "client"` file per flavour; `tooling.bench.report` refuses such a
  file and `--render` refuses a host file.
- **Tests.** `tooling/tests/test_bench_client.py` installs into and removes
  from a fake game folder with a neighbouring addon and saved variables that
  must survive, with a fake verified Ace3 cache; holds the catalogue to the
  host's and to the Lua files; and feeds the report saved variables written in
  the client's format. `tooling/tests/test_bench_profiles.py` holds the
  profiles to the cases the host results and the Lua modules declare, and
  checks the planner, the sets and the AceConfigDialog pin. No network, no
  Lua, no real game folder.
- **Lint and checks.** `tooling/bench/client/` is runtime Lua for
  `python3 -m tooling.lint`, StyLua formats it, and
  `lua-language-server --check tooling/bench/client --checklevel=Warning` reads
  its `.luarc.json`. Repository validation holds the harness `.toc` to the
  supported-client line.

## Recorded fixtures

Some specs hold a Kit to a third-party library's real behaviour, without that
library's source entering the repository: bridgeKit must write and read
AceSerializer-3.0 text exactly as Ace3 does, and Ace3's licence forbids
redistributing it (`docs/BRIDGE_KIT_DESIGN.md`, section 3.2). The library is
therefore run, outside the repository, over the project's own inputs, and only
its output is committed:

```bash
python3 -m tooling.fixtures.ace_serializer           # record packages/bridgeKit/tests/fixtures/AceSerializerFixtures.lua
python3 -m tooling.fixtures.ace_serializer --check   # compare a fresh recording with the committed module
```

The command fetches Ace3 at the commit the benchmark pins through
`tooling.bench.ace3` (same cache, same SHA-256 check), runs
`tooling/fixtures/lua/RecordAceSerializer.lua` under host Lua 5.1 against it,
and writes a generated Lua module with a provenance header: the Ace3 commit,
the library's `MINOR`, the date and the interpreter. Every encoding case keeps
the Lua source of the values it passed, every decoding case the text; error
messages lose the `file:line:` position, which names the local checkout. Every
byte outside printable ASCII is written as a decimal escape, so the module is
plain ASCII, and StyLua formats it with `stylua.toml` before it is written, so
it passes the formatting gate. `--check` keeps the committed date, so it reports only a changed
recorder or a changed Ace3 pin.

The recording is a deliberate step, like a benchmark run, not part of CI: it
needs the network the first time, and a changed Ace3 pin is a reviewed change.
Adding a case is an edit of the recorder's input lists followed by a new
recording.

## Future tooling

Tooling is added only when implemented. Empty placeholder directories are intentionally avoided because they imply capabilities that do not yet exist.

Likely future responsibilities include affected-package test selection.
