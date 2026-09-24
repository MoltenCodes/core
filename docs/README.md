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
- [`ROADMAP.md`](ROADMAP.md) records what was decided and delivered in each phase, the nine-point record of every planned Kit, and the standing obligations.
- [`API_KIT_DESIGN.md`](API_KIT_DESIGN.md) is the design baseline of `apiKit`, the planned flavour-aware wrapper over the WoW addon API: namespaces, naming rules, metadata pipeline, outputs and definition of done.

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
- [`LifecycleKit`](../packages/lifecycleKit/README.md) — per-addon loading, readiness, and shutdown coordination, the combat gate, and the halted state.
- [`ModuleKit`](../packages/moduleKit/README.md) — addon-scoped module lifecycle, dependency graphs, and dependency injection.
- [`TimerKit`](../packages/timerKit/README.md) — cancelable, scope-aware timers; two files to embed; its addon scopes close at logout whenever LifecycleKit or EventKit is loaded, and otherwise by your own call.
- [`SchedulerKit`](../packages/schedulerKit/README.md) — cooperative, frame-budgeted priority scheduling with TimerKit delays.
- [`PoolKit`](../packages/poolKit/README.md) — allocation-conscious bounded object pooling with deterministic ownership and cleanup.
- [`ClientKit`](../packages/clientKit/README.md) — client flavour, capability flags, secret-value and frame-access probes, shims.
- [`CacheKit`](../packages/cacheKit/README.md) — bounded LRU and TTL caches, memoisation, snapshots with diffs.
- [`ProfileKit`](../packages/profileKit/README.md) — zero-cost-when-off performance sections and a sorted report.
- [`ReadinessKit`](../packages/readinessKit/README.md) — named readiness gates for late host data: polling, timeouts, negative caching, bounded waiters.
- [`SchemaKit`](../packages/schemaKit/README.md) — sealed value schemas with structured, secret-safe failures, defaults and descriptions.
- [`LocaleKit`](../packages/localeKit/README.md) — per-addon translations, missing-key reporting and coverage, indexed format specifiers.
- [`HookKit`](../packages/hookKit/README.md) — reversible, secure-first hooking in three named semantics.
- [`SettingsKit`](../packages/settingsKit/README.md) — saved-variable databases with scopes, validated writes, profiles and migrations.
- [`OptionsKit`](../packages/optionsKit/README.md) — typed, validated, introspectable options tree with no renderer.
- [`CommandKit`](../packages/commandKit/README.md) — slash commands with hyperlink-aware parsing, generated usage, sinks, completion and an OptionsKit command line.
- [`CodecKit`](../packages/codecKit/README.md) — serialise, compress and channel-encode values into addon-channel or printable strings; decoding never raises.
- [`InteropKit`](../packages/interopKit/README.md) — the LibStub bridge.
- [`MediaKit`](../packages/mediaKit/README.md) — typed media registry with font scripts, per-consumer defaults and LibSharedMedia mirroring.
- [`CommKit`](../packages/commKit/README.md) — addon messaging with bounded reassembly, refusing queues, a session bandwidth budget and sync sets.
- [`WidgetKit`](../packages/widgetKit/README.md) — pooled, versioned widgets, explicit layouts, anchors and an options renderer.
- [`ApiKit`](../packages/apiKit/README.md) — the flavour-aware, typed wrapper over the World of Warcraft API, generated from the client's own documentation tables: `local api = wow.retail.api`.
- [`TestKit`](../packages/testKit/README.md) — development-only in-client test suites with structured results.

Each package keeps its complete public contract under its own `docs/API.md`.

Repository-wide documents define shared rules. Package documents define package behavior. When the two appear to conflict, the design constitution and package manifest contract should be treated as the architectural source of truth and the inconsistency should be fixed.
