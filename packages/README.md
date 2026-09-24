# Runtime Packages

Every visible directory directly under `packages/` is an independently publishable runtime package.

Package directories are discovered automatically from their `package.manifest.json`; do not maintain a separate package list in CI or tooling.

A package owns its source, tests, documentation, changelog, and runtime dependency declarations. See [`../docs/ARCHITECTURE.md`](../docs/ARCHITECTURE.md) for package boundaries and [`../docs/PACKAGE_MANIFEST.md`](../docs/PACKAGE_MANIFEST.md) for the required layout and manifest schema.

Current packages:

- [`registry`](registry/) — shared package registration and revision resolution.
- [`signalKit`](signalKit/) — deterministic pure-Lua callback dispatch and connection lifecycle.
- [`eventKit`](eventKit/) — lazy WoW Frame-event subscriptions and unit-event filtering built on SignalKit.
- [`lifecycleKit`](lifecycleKit/) — replay-aware per-addon loading, readiness, and shutdown coordination, a shared combat gate with a bounded out-of-combat queue, and a halted state announced to dependents.
- [`moduleKit`](moduleKit/) — addon-scoped module lifecycle, dependency graphs, dependency injection, and dependency policies.
- [`timerKit`](timerKit/) — cancelable one-shot/repeating timers, ownership scopes, and lifecycle-driven cleanup.
- [`schedulerKit`](schedulerKit/) — cooperative frame-budgeted scheduling, priorities, cancellation scopes, and delayed work.
- [`poolKit`](poolKit/) — allocation-conscious bounded object pooling with deterministic ownership and cleanup.
- [`clientKit`](clientKit/) — client flavour, build floor, probed capability flags, secret-value and frame-access probes, shims with one shape per host call.
- [`cacheKit`](cacheKit/) — bounded LRU and TTL caches, memoisation, snapshots with diffs, clear-on-event.
- [`profileKit`](profileKit/) — zero-cost-when-off performance sections with count, total, spike and a report.
- [`readinessKit`](readinessKit/) — named readiness gates for late host data: polling, timeouts, negative caching, bounded waiters.
- [`schemaKit`](schemaKit/) — sealed value schemas with structured, secret-safe failures; the validation core for arguments, saved variables, options and messages.
- [`localeKit`](localeKit/) — per-addon translations, missing-key reporting and coverage, indexed format specifiers.
- [`hookKit`](hookKit/) — reversible, secure-first hooking of functions, methods and frame scripts.
- [`settingsKit`](settingsKit/) — saved-variable databases: scopes, validated writes, wildcard defaults, profiles, migrations.
- [`optionsKit`](optionsKit/) — typed, validated, introspectable options tree with no renderer.
- [`commandKit`](commandKit/) — slash commands: hyperlink-aware parsing, generated usage, schema-checked arguments, sinks, completion, OptionsKit command line.
- [`codecKit`](codecKit/) — serialise, compress and channel-encode values; decoding never raises.
- [`interopKit`](interopKit/) — the LibStub bridge.
- [`mediaKit`](mediaKit/) — typed media registry, font scripts, sorted lists, per-consumer defaults, LibSharedMedia bridge.
- [`brokerKit`](brokerKit/) — LibDataBroker-compatible data objects for display addons: typed attributes as plain fields, per-attribute change signals, sorted enumeration, two-way LibDataBroker-1.1 bridge.
- [`logKit`](logKit/) — levelled, structured logging: per-addon loggers with lazy secret-safe formatting, a tri-state level, a bounded journal, chat, callback and table sinks.
- [`commKit`](commKit/) — addon messaging: chunk protocol, bounded reassembly, refusing priority queues, session bandwidth budget, sync sets.
- [`widgetKit`](widgetKit/) — pooled versioned widgets, List/Fill/Flow layouts, anchors, position bindings, OptionsKit renderer.
- [`apiKit`](apiKit/) — the flavour-aware, typed wrapper over the World of Warcraft API (`wow.retail.api`, ...): direct aliases generated from the client's own documentation tables, LuaCATS types per flavour, the raw API always valid.
- [`testKit`](testKit/) — development-only in-client test suites: phase-gated, SchedulerKit-driven, secret-safe expectations, structured results.
