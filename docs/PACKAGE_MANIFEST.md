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
