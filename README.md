# MoltenCodes WoW Framework

A modular Lua framework for professional World of Warcraft addon development.

This repository is a monorepo. Every publishable runtime package lives under `packages/` and owns its source, tests, documentation, changelog, and package manifest. Repository tooling discovers packages from that structure instead of maintaining a second hard-coded package list.

## Current packages

| Package | Status | Purpose |
|---|---|---|
| [`registry`](packages/registry/) | Implemented | Zero-dependency shared package registration, discovery, and in-place revision upgrades. |
| [`signalKit`](packages/signalKit/) | Implemented | Deterministic, re-entrant pure-Lua callback dispatch with explicit connection lifetimes, and named message buses with a declared topic policy. |
| [`eventKit`](packages/eventKit/) | Implemented | Lazy World of Warcraft event subscriptions backed by SignalKit, including unit-event filtering. |
| [`lifecycleKit`](packages/lifecycleKit/) | Implemented | Replay-aware per-addon loading, readiness, and shutdown coordination, a shared combat gate with a bounded out-of-combat queue, and a halted state announced to dependents. |
| [`moduleKit`](packages/moduleKit/) | Implemented | Addon-scoped module lifecycle, dependency graphs, dependency injection, and automatic/strict dependency policies. |
| [`timerKit`](packages/timerKit/) | Implemented | Cancelable one-shot/repeating timers, ownership scopes, and LifecycleKit-driven cleanup. |
| [`schedulerKit`](packages/schedulerKit/) | Implemented | Cooperative frame-budgeted scheduling with priorities, cancellation scopes, and TimerKit delays. |
| [`poolKit`](packages/poolKit/) | Implemented | Allocation-conscious bounded object pooling with deterministic ownership and cleanup. |
| [`clientKit`](packages/clientKit/) | Implemented | Client flavour, build floor, probed capability flags, secret-value and frame-access probes, and shims with one shape per host call. |
| [`cacheKit`](packages/cacheKit/) | Implemented | Bounded LRU and TTL caches, memoisation, snapshots with diffs and clear-on-event. |
| [`profileKit`](packages/profileKit/) | Implemented | Zero-cost-when-off performance sections with count, total, spike and a sorted report. |
| [`readinessKit`](packages/readinessKit/) | Implemented | Named readiness gates for host data that arrives after load: polling, timeouts, negative caching and bounded waiters. |
| [`schemaKit`](packages/schemaKit/) | Implemented | Sealed value schemas with structured, secret-safe failures: one validation core for arguments, saved variables, options and received messages. |
| [`localeKit`](packages/localeKit/) | Implemented | Per-addon translations at the cost of one table, missing-key reporting and coverage, indexed format specifiers. |
| [`hookKit`](packages/hookKit/) | Implemented | Reversible, secure-first hooking of functions, methods and frame scripts in three named semantics. |
| [`settingsKit`](packages/settingsKit/) | Implemented | Saved variables with scopes, schema-validated writes, defaults never written back, profiles and versioned migrations. |
| [`optionsKit`](packages/optionsKit/) | Implemented | Typed, validated, introspectable options tree bound to getters or a SettingsKit database, with no renderer. |

## Using the framework in an addon

The framework is embedded, not installed: you copy the Kits you need into your
addon and list them in your `.toc`. There is nothing for your users to download
separately, and several addons shipping different copies of the same Kit
reconcile to one shared instance at runtime.

- [`docs/EMBEDDING.md`](docs/EMBEDDING.md) is the guide: directory layout, load
  order, supported Interface numbers, coexistence with LibStub, taint rules, the
  combat-log constraint, `/reload` semantics, performance guidance, and the exact
  error message each load-order mistake produces.
- [`examples/`](examples/) is a complete, runnable example addon — `.toc`,
  `embeds.xml` and `Core.lua` — that a spec loads and the language server
  type-checks on every run, so it cannot drift from the framework.

Build the artifact you embed:

```bash
python3 -m tooling.package.build --all --out dist
```

This writes `dist/MoltenCodes/` in the layout an addon embeds, a `manifest.json`
recording every package's version, API generation, revision and the load order,
and SHA-256 checksums in `dist/CHECKSUMS.txt`. Published artifacts come from the
same layout through [`.pkgmeta`](.pkgmeta); see
[`docs/RELEASES.md`](docs/RELEASES.md).

## Quick start

Repository validation and Python tooling tests require Python 3.10 or newer:

```bash
python3 -m tooling.validation.validate_repository
python3 -m unittest discover -s tooling/tests -p "test_*.py"
```

Lua tests require the Lua/Busted toolchain documented in
[`docs/DEVELOPMENT.md`](docs/DEVELOPMENT.md). One command runs every package
suite and the example addon's specs:

```bash
python3 -m tooling.test.run
```

Lua linting is package-aware and recursive, and covers test code as well as
runtime code:

```bash
python3 -m tooling.lint
```

The documentation is spell-checked with a pinned cspell, which needs Node.js:

```bash
python3 -m tooling.spell
```

## Repository structure

```text
.
├── .github/                 # Continuous integration
├── .pkgmeta                 # Addon-site packager metadata
├── .vscode/                 # Editor integration only
├── busted.yml               # Selene standard library for Busted test code
├── cspell.json              # Spell-check configuration for the documentation
├── docs/                    # Repository-wide documentation
│   └── EMBEDDING.md         # How an addon embeds the framework
├── examples/                # A complete example addon, loaded by its own spec
├── meta/                    # Editor-only Lua metadata, including the WoW API
├── packages/                # Independently publishable runtime packages
│   ├── registry/
│   ├── signalKit/
│   ├── eventKit/
│   ├── lifecycleKit/
│   ├── moduleKit/
│   ├── timerKit/
│   ├── schedulerKit/
│   ├── poolKit/
│   ├── clientKit/
│   ├── cacheKit/
│   ├── profileKit/
│   ├── readinessKit/
│   ├── schemaKit/
│   ├── localeKit/
│   ├── hookKit/
│   ├── settingsKit/
│   └── optionsKit/
├── pyproject.toml           # Python tooling metadata and the supported floor
├── selene.toml              # Selene configuration for runtime Lua
├── selene-tests.toml        # Selene configuration for test Lua
├── tests/support/           # Shared test fixture: the fake WoW client
└── tooling/                 # Repository tooling; never a runtime dependency
```

## Documentation

Start with [`docs/README.md`](docs/README.md) for the documentation map.

- [`docs/EMBEDDING.md`](docs/EMBEDDING.md) — how an addon embeds and loads the framework.
- [`docs/ARCHITECTURE.md`](docs/ARCHITECTURE.md) — package boundaries and runtime architecture.
- [`docs/DESIGN_CONSTITUTION.md`](docs/DESIGN_CONSTITUTION.md) — non-negotiable design principles.
- [`docs/DEVELOPMENT.md`](docs/DEVELOPMENT.md) — local setup and canonical development commands.
- [`docs/TESTING.md`](docs/TESTING.md) — testing layers, conventions, and orchestration.
- [`docs/PACKAGE_MANIFEST.md`](docs/PACKAGE_MANIFEST.md) — package metadata and dependency contracts.
- [`docs/CONTRIBUTING.md`](docs/CONTRIBUTING.md) — contribution workflow and annotation rules.
- [`docs/RELEASES.md`](docs/RELEASES.md) — tags, build command, and release artifacts.

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
