# Runtime Packages

Every visible directory directly under `packages/` is an independently publishable runtime package.

Package directories are discovered automatically from their `package.manifest.json`; do not maintain a separate package list in CI or tooling.

A package owns its source, tests, documentation, changelog, and runtime dependency declarations. See [`../docs/ARCHITECTURE.md`](../docs/ARCHITECTURE.md) for package boundaries and [`../docs/PACKAGE_MANIFEST.md`](../docs/PACKAGE_MANIFEST.md) for the required layout and manifest schema.

Current packages:

- [`registry`](registry/) — shared package registration and revision resolution.
- [`signalKit`](signalKit/) — deterministic pure-Lua callback dispatch and connection lifecycle.
- [`eventKit`](eventKit/) — lazy WoW Frame-event subscriptions and unit-event filtering built on SignalKit.
- [`lifecycleKit`](lifecycleKit/) — replay-aware per-addon loading, readiness, and shutdown coordination.
- [`moduleKit`](moduleKit/) — addon-scoped module lifecycle, dependency graphs, dependency injection, and dependency policies.
- [`timerKit`](timerKit/) — cancelable one-shot/repeating timers, ownership scopes, and lifecycle-driven cleanup.
- [`schedulerKit`](schedulerKit/) — cooperative frame-budgeted scheduling, priorities, cancellation scopes, and delayed work.
- [`poolKit`](poolKit/) — allocation-conscious bounded object pooling with deterministic ownership and cleanup.
- [`clientKit`](clientKit/) — client flavour, build floor, probed capability flags, secret-value and frame-access probes, shims with one shape per host call.
- [`cacheKit`](cacheKit/) — bounded LRU and TTL caches, memoisation, snapshots with diffs, clear-on-event.
- [`profileKit`](profileKit/) — zero-cost-when-off performance sections with count, total, spike and a report.
- [`readinessKit`](readinessKit/) — named readiness gates for late host data: polling, timeouts, negative caching, bounded waiters.
