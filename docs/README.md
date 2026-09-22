# Documentation

This directory is the entry point for repository-wide documentation.

## Using the framework

- [`EMBEDDING.md`](EMBEDDING.md) is the addon author's guide: `.toc` entries, load
  order, supported Interface numbers, LibStub coexistence, taint, the combat log,
  `/reload` semantics, performance guidance, and the error messages a wrong load
  order produces.
- [`../examples/`](../examples/) contains a complete example addon that is loaded
  and type-checked on every test run.

## Architecture and contracts

- [`DESIGN_CONSTITUTION.md`](DESIGN_CONSTITUTION.md) defines the principles that package and tooling changes must preserve.
- [`ARCHITECTURE.md`](ARCHITECTURE.md) explains package boundaries, dependency direction, API generations, and embedded package identity.
- [`PACKAGE_MANIFEST.md`](PACKAGE_MANIFEST.md) defines the canonical machine-readable package metadata contract.

## Development workflow

- [`DEVELOPMENT.md`](DEVELOPMENT.md) contains local prerequisites and canonical repository commands.
- [`TESTING.md`](TESTING.md) describes test layers, Busted conventions, and package-aware test orchestration.
- [`TOOLING.md`](TOOLING.md) explains repository tooling and its separation from runtime code.
- [`CONTRIBUTING.md`](CONTRIBUTING.md) defines contribution expectations, including the LuaCATS annotation rules.
- [`RELEASES.md`](RELEASES.md) describes independent package versioning, the build command, and release artifacts.

## Package documentation

Every publishable package owns its package-specific documentation under `packages/<name>/`.

Current package entry points:

- [`Registry`](../packages/registry/README.md) — shared package identity and revision resolution.
- [`SignalKit`](../packages/signalKit/README.md) — deterministic pure-Lua callback dispatch.
- [`EventKit`](../packages/eventKit/README.md) — lazy WoW Frame-event subscriptions and unit-event filtering built on SignalKit.
- [`LifecycleKit`](../packages/lifecycleKit/README.md) — per-addon loading, readiness, and shutdown coordination.
- [`ModuleKit`](../packages/moduleKit/README.md) — addon-scoped module lifecycle, dependency graphs, and dependency injection.
- [`TimerKit`](../packages/timerKit/README.md) — cancelable, scope-aware timers with LifecycleKit shutdown cleanup.
- [`SchedulerKit`](../packages/schedulerKit/README.md) — cooperative, frame-budgeted priority scheduling with TimerKit delays.
- [`PoolKit`](../packages/poolKit/README.md) — allocation-conscious bounded object pooling with deterministic ownership and cleanup.

Each package keeps its complete public contract under its own `docs/API.md`.

Repository-wide documents define shared rules. Package documents define package behavior. When the two appear to conflict, the design constitution and package manifest contract should be treated as the architectural source of truth and the inconsistency should be fixed.
