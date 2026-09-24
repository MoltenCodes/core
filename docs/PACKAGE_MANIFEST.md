# Package Manifest

Every publishable package has exactly one canonical manifest:

```text
packages/<name>/package.manifest.json
```

Every visible directory directly under `packages/` is treated as a package. A package directory without a manifest is a repository validation error rather than being silently ignored.

## Required fields

| Field | Type | Description |
|---|---|---|
| `name` | string | Stable package identifier. |
| `displayName` | string | Human-readable package name. |
| `description` | string | Concise package purpose. |
| `version` | string | Semantic Versioning release version. |
| `license` | string | SPDX identifier of the package licence. |
| `dependencies` | object | Runtime package dependency contracts. |

`license` must be `MIT`, matching the repository [`LICENSE`](../LICENSE) that the
release builder copies into every artifact. A package declaring a different
licence would contradict the licence file shipped beside it, so the validator
rejects it rather than trusting whichever of the two a consumer happens to read.
If the framework ever ships a package under another licence, that is a
deliberate repository-level decision and both this rule and the builder change
with it.

## Optional fields

| Field | Type | Description |
|---|---|---|
| `optionalDependencies` | object | Packages this package uses when they are present, found at call time. Same shape as `dependencies`. See [Optional dependencies](#optional-dependencies). |
| `distribution` | string | `"release"` (the default when absent) or `"development"`. See [Distribution](#distribution). |

## Distribution

`distribution` says whether a package ships to addon authors:

| Value | Tested and linted | Bundled by `tooling.package.build` | Published through `.pkgmeta` |
|---|---|---|---|
| `"release"` (default) | yes | yes | yes, moved into the embeddable layout |
| `"development"` | yes | no: `--all` skips it and lists it under `skipped` in `manifest.json`; `--package` refuses it | no: it must appear in the `ignore:` list as `packages/<id>` |

A development package is test and diagnostic tooling that runs against the
framework, for example a fidelity suite under `packages/<id>/fidelity/` that is
executed inside the game client. Rules:

- only the two values are accepted;
- a **release** package may not list a development package in `dependencies` or
  `optionalDependencies`, because no shipped bundle ever contains one;
- a **development** package may depend on anything;
- repository validation fails until `.pkgmeta` ignores every development
  package with a `- packages/<id>` line under `ignore:`, because the packager
  otherwise copies whatever is not ignored.

## Runtime API fields

Packages exposing a formal runtime API define both fields together:

| Field | Type | Description |
|---|---|---|
| `api` | positive integer | Public API generation. |
| `revision` | positive integer | Compatible implementation revision within that API generation. |

`api` and `revision` must either both be present or both be omitted.

The three version-like values serve different purposes:

- `version` tracks published package releases using Semantic Versioning;
- `api` changes when the public runtime contract breaks;
- `revision` orders compatible embedded implementations inside one API generation.

### When to bump `revision`

`revision` is the tiebreaker the Registry uses to decide which of several
embedded copies of a package wins at runtime. Raise it when the implementation
an addon would actually execute changes: a bug fix, a behaviour change, a state
migration, a performance change that a consumer could observe.

Do not raise it for edits that leave the executed implementation identical —
comments, LuaCATS annotations, lint annotations, formatting, or renaming a local.
Those change the shipped file and so belong in the changelog and in a `version`
bump, but a copy carrying them is not a newer implementation, and claiming
otherwise makes it displace an equivalent copy for no reason.

"Identical" is checkable rather than a matter of opinion. Compile the file before
and after with `luac -s -l`, normalise away the source line column and the
prototype addresses, and compare: if the instruction listing is unchanged, the
executed implementation is unchanged and `revision` must not move.

The in-source `IMPLEMENTATION_REVISION`, the runtime `REVISION` field, and the
manifest `revision` must always agree; each package's `Manifest_spec` enforces
that. A `revision` bump additionally needs an in-place upgrade path from the
previous revision and a spec that covers it.

A Kit's bootstrap is where that upgrade path is implemented. It is described in
[`ARCHITECTURE.md`](ARCHITECTURE.md) under "How a Kit bootstraps" and carried out
by `Registry:Bootstrap`, which reports the revision whose state the loading copy
inherits.

## Dependency contracts

A dependency names the exact API generation required by the consumer:

```json
{
  "dependencies": {
    "signalKit": {
      "api": 1
    }
  }
}
```

The dependency package must exist, expose an API generation, and expose the same API generation requested by the consumer.

Cycles among required dependencies are invalid; see
[Optional dependencies](#optional-dependencies) for the one kind of cycle that
is allowed.

## Optional dependencies

A package that can use another one *when an addon happens to embed it*, and
works without it, declares it under `optionalDependencies`. The shape is the
same as `dependencies`:

```json
{
  "name": "cacheKit",
  "displayName": "CacheKit",
  "description": "Bounded LRU and TTL caches, memoisation, diffed snapshots and clear-on-event for World of Warcraft addons.",
  "version": "0.1.0",
  "license": "MIT",
  "api": 1,
  "revision": 1,
  "dependencies": {
    "registry": {
      "api": 2
    }
  },
  "optionalDependencies": {
    "eventKit": {
      "api": 1
    }
  }
}
```

What the field means, and what it deliberately does not:

- **At runtime** the package finds an optional dependency at call time through
  `Registry:Find(packageId, api)` and degrades when it is absent. It never
  resolves one at file scope, because nothing guarantees it has loaded.
- **Load order and the bundle ignore it.** `manifest.json`'s `loadOrder`, a
  `--package` build's dependency closure and a package's `src/.luarc.json` are
  derived from `dependencies` only. A bundle never ships a package merely
  because something optionally uses it. The release `manifest.json` records the
  field under `optionalDependencies` for each package, for information only.
- **Tests see it.** `python3 -m tooling.test.run` puts each optional dependency,
  and its own required closure, on the package suite's `LUA_PATH`, so a spec can
  load it to exercise the "present" path without its test environment adding
  source directories by hand. See [`TESTING.md`](TESTING.md).

Validation rules:

- every optional dependency must exist, expose an API generation, and expose
  the generation requested, exactly as for `dependencies`;
- a package may not list the same package in both `dependencies` and
  `optionalDependencies`;
- a package may not optionally depend on itself;
- the graph of **required** dependencies must have no cycles. A cycle that
  passes through at least one optional edge is allowed: the optional edge is
  resolved at call time, after every file has loaded, which is what
  `Registry:Find` is for. LifecycleKit, for example, optionally calls into
  CommKit at shutdown while CommKit optionally finds LifecycleKit to learn
  who closes its scopes;
- `optionalDependencies` must come **after** the top-level `api` field in the
  file. Every `tests/Manifest_spec.lua` reads the package's API generation with
  the first `"api"` in the file, so an optional-dependency object written above
  it would hand those specs the wrong number. Writing the field last, after
  `dependencies`, satisfies the rule.

Omit the field when there is nothing to declare; an empty object is accepted.

## Naming

Package names must match:

```text
^[a-z][A-Za-z0-9]*$
```

Canonical public framework package IDs use lowerCamelCase and end in `Kit` (for example `signalKit`, `eventKit`, `lifecycleKit`, `moduleKit`, and `timerKit`). `registry` is the infrastructure exception. The package directory name must exactly match the manifest `name`. Runtime/module facade names use the PascalCase form (`SignalKit`, `EventKit`, `LifecycleKit`, `ModuleKit`, `TimerKit`).

## Minimum package layout

Repository validation requires:

```text
packages/<name>/
├── CHANGELOG.md
├── README.md
├── package.manifest.json
├── src/
│   ├── <DisplayName>.lua    # the facade: the one top-level Lua file, loaded first
│   ├── .luarc.json          # lua-language-server workspace for this directory
│   └── <subdirectory>/      # optional further runtime files, loaded after the facade
├── tests/
│   ├── README.md            # what the suite covers and how it is organised
│   ├── <name>_spec.lua ...  # at least one Busted spec
│   └── support/
│       └── <DisplayName>TestEnv.lua   # the suite's environment on the shared fixture
└── docs/API.md              # required when api/revision are declared
```

`src/` holds exactly one top-level Lua file, named after the manifest's
`displayName` (`src/TimerKit.lua` for `TimerKit`). That file is the facade:
the first file of the package the client loads and the one every consumer's
`.toc` or `embeds.xml` names. Further runtime files, when a package has them,
live in subdirectories of `src/` and are loaded after the facade in sorted
path order (`tooling.package.build.runtime_files`); they may depend on the
facade, never on each other. Repository validation rejects a second top-level
Lua file because it would leave the load order ambiguous.

`src/.luarc.json` must list exactly the shared `meta/` directory followed by the
source directory of every package in this package's runtime dependency closure,
dependency-first. `lua-language-server --check` uses the directory it is pointed
at as its workspace root and ignores parent configuration, so this file is what
makes a package type-checkable on its own. Repository validation derives the
expected list from the manifests and fails when the two disagree.

A package's `tests/support/` directory is package-owned: it holds
`<DisplayName>TestEnv.lua`, the suite's environment (the load order of the
package's module chain and the helpers only its specs use), and any further
helper the suite needs. The World of Warcraft stubs themselves live once, in
the repository-wide fixture at `tests/support/FrameworkTestEnv.lua`, which is
test scaffolding rather than a package: it has no manifest, is not discovered
as one, and is never included in a release artifact. Neither directory ships in
a release. See [`TESTING.md`](TESTING.md).

Outside its own directory, a package must be named in `.pkgmeta`, in
[`README.md`](README.md) here and in `packages/README.md`, and in the Kit lists
of `.github/`; repository validation checks each of them
([`TOOLING.md`](TOOLING.md#repository-validation)).

Additional package-owned documentation and internal source directories may be added without changing the manifest contract.

## Validation

Run:

```bash
python3 -m tooling.validation.validate_repository
```

The focused manifest-only validator remains available for tooling development:

```bash
python3 -m tooling.validation.validate_manifests
```
