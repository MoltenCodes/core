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

Runtime package dependency cycles are invalid.

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
├── src/                     # contains runtime Lua
│   └── .luarc.json          # lua-language-server workspace for this directory
├── tests/                   # contains at least one *_spec.lua
└── docs/API.md              # required when api/revision are declared
```

`src/.luarc.json` must list exactly the shared `meta/` directory followed by the
source directory of every package in this package's runtime dependency closure,
dependency-first. `lua-language-server --check` uses the directory it is pointed
at as its workspace root and ignores parent configuration, so this file is what
makes a package type-checkable on its own. Repository validation derives the
expected list from the manifests and fails when the two disagree.

A package's `tests/support/` directory is package-owned and published with it,
but the World of Warcraft stubs it used to hold now live in the repository-wide
fixture at `tests/support/FrameworkTestEnv.lua`. That directory is test
scaffolding rather than a package: it has no manifest, is not discovered as one,
and is never included in a release artifact. See [`TESTING.md`](TESTING.md).

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
