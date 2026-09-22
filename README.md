# MoltenCodes WoW Framework

A modular Lua framework for professional World of Warcraft addon development.

This repository is a monorepo. Every publishable runtime package lives under `packages/` and owns its source, tests, documentation, changelog, and package manifest. Repository tooling discovers packages from that structure instead of maintaining a second hard-coded package list.

## Current packages

| Package | Status | Purpose |
|---|---|---|
| [`registry`](packages/registry/) | Implemented | Zero-dependency shared package registration, discovery, and in-place revision upgrades. |
| [`signalKit`](packages/signalKit/) | Implemented | Deterministic, re-entrant pure-Lua callback dispatch with explicit connection lifetimes. |
| [`eventKit`](packages/eventKit/) | Implemented | Lazy World of Warcraft event subscriptions backed by SignalKit, including unit-event filtering. |
| [`lifecycleKit`](packages/lifecycleKit/) | Implemented | Replay-aware per-addon loading, readiness, and shutdown coordination. |
| [`moduleKit`](packages/moduleKit/) | Implemented | Addon-scoped module lifecycle, dependency graphs, dependency injection, and automatic/strict dependency policies. |
| [`timerKit`](packages/timerKit/) | Implemented | Cancelable one-shot/repeating timers, ownership scopes, and LifecycleKit-driven cleanup. |
| [`schedulerKit`](packages/schedulerKit/) | Implemented | Cooperative frame-budgeted scheduling with priorities, cancellation scopes, and TimerKit delays. |
| [`poolKit`](packages/poolKit/) | Implemented | Allocation-conscious bounded object pooling with deterministic ownership and cleanup. |

## Quick start

Repository validation and Python tooling tests require Python 3.10 or newer:

```bash
python3 -m tooling.validation.validate_repository
python3 -m unittest discover -s tooling/tests -p "test_*.py"
```

Lua package tests require the Lua/Busted toolchain documented in [`docs/DEVELOPMENT.md`](docs/DEVELOPMENT.md):

```bash
python3 -m tooling.test.run
```

Runtime Lua linting is package-aware and recursive:

```bash
python3 -m tooling.lint
```

## Repository structure

```text
.
├── .github/                 # Continuous integration
├── .vscode/                 # Editor integration only
├── docs/                    # Repository-wide documentation
├── meta/                    # Editor-only Lua metadata
├── packages/                # Independently publishable runtime packages
│   ├── registry/
│   ├── signalKit/
│   ├── eventKit/
│   ├── lifecycleKit/
│   ├── moduleKit/
│   ├── timerKit/
│   ├── schedulerKit/
│   └── poolKit/
└── tooling/                 # Repository tooling; never a runtime dependency
```

## Documentation

Start with [`docs/README.md`](docs/README.md) for the documentation map.

- [`docs/ARCHITECTURE.md`](docs/ARCHITECTURE.md) — package boundaries and runtime architecture.
- [`docs/DESIGN_CONSTITUTION.md`](docs/DESIGN_CONSTITUTION.md) — non-negotiable design principles.
- [`docs/DEVELOPMENT.md`](docs/DEVELOPMENT.md) — local setup and canonical development commands.
- [`docs/TESTING.md`](docs/TESTING.md) — testing layers, conventions, and orchestration.
- [`docs/PACKAGE_MANIFEST.md`](docs/PACKAGE_MANIFEST.md) — package metadata and dependency contracts.
- [`docs/CONTRIBUTING.md`](docs/CONTRIBUTING.md) — contribution workflow.

## Principles

- Small, composable runtime packages.
- Explicit API generations and implementation revisions.
- Independent package publication.
- Lua 5.1-compatible runtime code.
- Minimal allocation, indirection, and global state.
- Stable package identity across independently embedded addon copies.
- Testable pure-Lua core behavior.
- English technical documentation.
- Repository automation that discovers packages rather than hard-coding them.

## Project roadmap

See [`docs/ROADMAP.md`](docs/ROADMAP.md) for the canonical framework development roadmap.
