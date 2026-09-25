# Tooling

Repository tooling lives under `tooling/` and is never a runtime dependency.

## Current tooling

```text
tooling/
├── lint.py                         # discovers and lints runtime and test Lua
├── spell.py                        # runs the pinned cspell over the documentation
├── spell-words.txt                 # the project dictionary cspell reads
├── api/                            # apiKit metadata pipeline; see "API metadata tooling"
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
├── ci/
│   └── check_commits.py           # checks commit subjects and pull request titles
├── client/
│   ├── flavours.py                # the client flavours the real-client tests cover: folder, project ID
│   ├── install.py                 # installs the bundle and the real-client test addons into a game folder, or removes them
│   ├── report.py                  # merges the harness's saved results into the committed result matrix
│   └── saved_variables.py         # reads a saved-variables file as Lua literals, without running Lua
├── package/
│   ├── build.py                   # assembles a checksummed bundle that installs as an addon
│   ├── list.py                    # prints package IDs from the manifests
│   └── toc.py                     # renders and reads the generated addon .toc
├── release/
│   ├── check_tag.py               # checks a bundle or package tag against RELEASES.md and the manifests
│   ├── history.py                 # reads the release history in docs/RELEASES.md
│   ├── library_toc.py             # prints the .toc of the MoltenCodes addon (or of one Kit's addon)
│   ├── notes.py                   # prints one release's notes
│   ├── pkgmeta.py                 # narrows .pkgmeta to one Kit for a package release
│   └── publish_mode.py            # decides dry run or upload, and whether to draft a release
├── test/
│   ├── run.py                     # package-aware Busted orchestration
│   ├── coverage.py                # the same run under LuaCov, gated on per-package floors
│   └── coverage-floors.json       # each package's line-coverage floor, a whole percent
├── tests/                         # Python unit tests for repository tooling
└── validation/
    ├── flavour_api.py             # every client API a Kit uses exists on every promised flavour, or is guarded
    ├── flavour_api_allowlist.json # reviewed exceptions to flavour_api, each with its guard and reason
    ├── host_names.json            # Lua library, framework globals and undocumented client names, with evidence
    ├── interface_numbers.py       # reads the supported-client table, prints the .toc line
    ├── lua_references.py          # finds host references in Lua and decides whether each use is guarded
    ├── lua_syntax.py              # Lua 5.1 lexer and parser
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
asserted. There is no exemption: a job that could only run on the newer
interpreter would make the floor a claim instead of a supported version.

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
[`PACKAGE_MANIFEST.md`](PACKAGE_MANIFEST.md#optional-dependencies).

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
  `.toc` of every real-client test addon (see "Supported clients: one table")
  and the apiKit flavour table;
- `.pkgmeta`: every release package moved (`src` and `docs`) exactly once, no
  development or unknown package moved, every development package ignored,
  and every root entry except `LICENSE` and `packages/` ignored, so the
  addon-site zip carries only the Kits and the licence, like the builder's
  bundle (root entries `.gitignore` names are local output and skipped);
- the load order quoted in [`EMBEDDING.md`](EMBEDDING.md#load-order) equals the
  one the builder computes from the manifests, file by file, and the example
  `.toc` and `embeds.xml` it quotes equal the files in `examples/`;
- the indexes: [`README.md`](README.md) in `docs/` links every other document
  there and every package README, and
  [`../packages/README.md`](../packages/README.md) links every package;
- the GitHub metadata: a `kit: <packageId>` label in `.github/labels.yml`, a
  labeler rule for `packages/<packageId>/**` in `.github/labeler.yml`, and an
  option in the Kit dropdown of the bug report and feature request forms, for
  every package and for no package that does not exist;
- every repository-relative Markdown link names a file that exists (generated
  reference and change reports excepted).

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
| runtime Lua | `packages/*/src/**`, `packages/*/fidelity/**`, `examples/*.lua`, `tests/client/**` | [`selene.toml`](../selene.toml) |
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
python3 -m tooling.client.install --wow-dir DIR [--flavour-dir _retail_] --remove [--dry-run]
```

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
`MoltenCodes-<Facade>/MoltenCodes-<Facade>.toc` for `--package <id>`), writes a
`manifest.json` describing versions, revisions, licences, the load order and
the `.toc`, and writes SHA-256 checksums into `CHECKSUMS.txt`.
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
file in the bundle must be listed.

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

The run is a gate, in two parts.

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
| `test` | `python3 -m tooling.test.run`: every package suite and the example addon, under Lua 5.1.5 and Busted |
| `coverage` | `python3 -m tooling.test.coverage`: every spec but the `#allocation` ones passes under LuaCov and every package meets its floor; the per-package table with floors in the job summary, the LuaCov report as the `luacov-report` artefact |
| `types` | `lua-language-server --check` for every package source directory, `examples/` and `tests/client/` |
| `format` | `stylua --check .` |
| `lint` | `python3 -m tooling.lint`, both scopes |
| `package` | `tooling.package.build --all --verify`, then `sha256sum --check --strict`; on a push to `main`, the bundle is uploaded as the artefact `MoltenCodes-<commit>` |
| `spell` | `python3 -m tooling.spell --require` and the cspell integration tests |
| `repository` | repository validation, `tooling.api.generate --all --check`, `python3 -m tooling.validation.flavour_api`, the tooling unit tests, `compileall` |
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

## Future tooling

Tooling is added only when implemented. Empty placeholder directories are intentionally avoided because they imply capabilities that do not yet exist.

Likely future responsibilities include:

- dependency-aware build ordering;
- affected-package test selection.
