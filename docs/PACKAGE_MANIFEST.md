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
| `dependencies` | object | Runtime package dependency contracts. |

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
comments, lint annotations, formatting, or renaming a local. Those change the
shipped file and so belong in the changelog and in a `version` bump, but a copy
carrying them is not a newer implementation, and claiming otherwise makes it
displace an equivalent copy for no reason.

The in-source `IMPLEMENTATION_REVISION`, the runtime `REVISION` field, and the
manifest `revision` must always agree; each package's `Manifest_spec` enforces
that. A `revision` bump additionally needs an in-place upgrade path from the
previous revision and a spec that covers it.

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
├── tests/                   # contains at least one *_spec.lua
└── docs/API.md              # required when api/revision are declared
```

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
