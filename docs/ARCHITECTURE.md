# Architecture

The repository is organized into independently publishable runtime packages.

```text
packages/
├── registry/
├── signalKit/
├── eventKit/
├── lifecycleKit/
├── moduleKit/
├── timerKit/
├── schedulerKit/
├── poolKit/
├── clientKit/
├── cacheKit/
├── profileKit/
├── readinessKit/
├── <future-package>/
└── ...
```

Every visible directory directly under `packages/` is considered a publishable package and must contain a valid `package.manifest.json`. Repository tooling deliberately rejects "ghost" package directories that are not represented by a manifest.

## Package naming

Public framework capability packages use an Apple-style `Kit` suffix. The canonical machine-readable package ID is lowerCamelCase (`signalKit`, `eventKit`, `lifecycleKit`, `moduleKit`, `timerKit`, `schedulerKit`, `poolKit`, `clientKit`, `cacheKit`, `profileKit`, `readinessKit`), while the Lua facade/module name is PascalCase (`SignalKit`, `EventKit`, `LifecycleKit`, `ModuleKit`, `TimerKit`, `SchedulerKit`, `PoolKit`, `ClientKit`, `CacheKit`, `ProfileKit`, `ReadinessKit`).

`registry` / `Registry` is an infrastructure exception because it provides package identity and revision reconciliation rather than a framework capability surface.

Package directory names, manifest `name`, Registry keys, runtime module filenames, `require` names, dependency declarations, tests, and documentation must use the same canonical identity. Compatibility aliases for pre-Kit names are intentionally not kept.

## Package ownership

A package owns:

- its public API;
- implementation source;
- tests and package-specific test support;
- package documentation;
- changelog;
- release metadata.

The minimum repository shape is:

```text
packages/<name>/
├── CHANGELOG.md
├── README.md
├── package.manifest.json
├── docs/
│   └── API.md              # required for packages declaring an API generation
├── src/
└── tests/
```

Cross-package behavior must use public APIs. Consumers must not reach into another package's internal source or private runtime state.

## Dependency direction

The current runtime dependency graph is:

```text
registry
├──→ clientKit
├──→ cacheKit
├──→ profileKit
├──→ poolKit
└──→ signalKit
       ↓
     eventKit
       ↓
   lifecycleKit
    ├──→ moduleKit
    └──→ timerKit
            ├──→ readinessKit
            ↓
       schedulerKit
```

`moduleKit` and `timerKit` are sibling capabilities above LifecycleKit. `schedulerKit` builds on TimerKit for delayed eligibility while remaining independent from ModuleKit.

Runtime packages depend only on other runtime packages declared in their manifests.

Repository tooling is outside the runtime dependency graph:

```text
tooling
    ↓
package metadata / source
```

Runtime code must never depend on `tooling/`, editor metadata, CI configuration, or local development dependencies.

## Sources of truth

- `package.manifest.json` is the machine-readable source of truth for package identity, semantic version, API generation, implementation revision, and runtime package dependencies.
- Package API documentation defines stable public behavior.
- Package changelogs describe user-visible evolution.
- Root documentation defines repository-wide conventions.

Do not maintain a second manual list of packages in tooling. Package discovery starts from `packages/*/package.manifest.json` and validates the corresponding directory structure.

## API generations

Packages that expose a formal runtime API declare an `api` generation and a `revision`.

The API generation identifies the contract family. A breaking public contract change requires a new API generation.

The revision identifies implementation ordering inside that API generation. Compatible revisions may improve behavior without changing the public contract.

The package `version` is Semantic Versioning for distribution and release history. It is intentionally separate from runtime API generation and implementation revision.

## Embedded package identity

Framework packages can be embedded by multiple addons. Registry assigns one stable shared table to each `(package, API generation)` pair. Accepted higher revisions update that table in place rather than replacing it, so consumers do not split across old and new package identities.

Portable WoW runtime access to Registry is provided through `MoltenCodes.Registry`; packages must not depend on optional or newer module-loading facilities for their fundamental bootstrap path.

## How a Kit bootstraps

Every Kit's file scope answers the same four questions in the same order, and
gets three of them from Registry rather than from its own code.

1. **Find Registry.** The Kit reads the shared `MoltenCodes` namespace, asks for
   its own Registry generation by number (`Registries[2]`), and falls back to the
   `MoltenCodes.Registry` alias. Asking by number first is what keeps an API-2
   Kit working once a future API 3 takes the alias over.
2. **Check its dependencies.** Each Kit validates the facades it needs — the
   exact API generation, the revision the facade claims, and the methods it is
   about to call. This stays in the Kit: only the Kit knows what it uses.
3. **Reconcile with `Registry:Bootstrap`.** The Kit hands Registry its identity
   (`package`, `api`, `revision`), the label its failures should carry, and two
   or three predicates: which fields make its public surface complete, whether a
   copy carrying this same revision already finished, and optionally how to
   resume one that did not. Registry decides whether this copy registers, yields
   to a newer one, or adopts an existing one, and reports the revision whose
   state this copy inherits. `packages/registry/docs/API.md` documents the
   decision table.
4. **Build or inherit its state.** With `previousRevision == nil` the Kit creates
   its prototypes and private state; otherwise it validates and migrates what it
   inherited, in place, so objects created by the older copy keep working.
   Since Registry revision 7 the hand-over can be explicit on both sides: the
   outgoing copy's `retire` hook (registered through `request.retire` or
   `Registry:OnRetire`) is called once, before the incoming copy registers, to
   release what only it can reach — host watchers, private closures — and return
   the state it wants carried forward; the incoming copy's
   `request.migrations[n]` steps then run in ascending order from the inherited
   revision + 1 to its own, each exactly once per shared table, and `Bootstrap`
   returns the migrated state. A Kit that passes neither keeps migrating by hand
   from `previousRevision`, exactly as before.

Registry itself is the exception: it publishes the facade `Bootstrap` lives on,
so its own bootstrap runs before any facade method exists and is written out by
hand.

This is why a Kit's prototype tables and `_state` are never replaced on an
upgrade. Registry keeps the shared package table's identity stable, and the Kit
keeps the identity of everything hanging off it, so a consumer holding a
reference from an older embedded copy observes the newer implementation instead
of splitting across two.
The old copy's entry points need no separate retirement for the same reason:
its facade *is* the new facade, and its instances' metatables point at
prototypes the new copy has already rewritten.

A Kit may also pass `sealFacade = true`, which makes the shared facade refuse
new fields written from outside the package. The Kit itself writes its facade
exclusively through `rawset`, which every Kit in this repository already does,
so sealing never interferes with bootstrap or upgrade.

The first dependency layer above Registry is `signalKit`. SignalKit uses Registry only for embedded-package identity; its dispatch algorithm is pure Lua and does not depend on WoW Frames or event APIs.

`eventKit` is the first WoW-specific package. It depends on Registry API 2 and SignalKit API 1, keeps the `CreateFrame`/Frame registration boundary narrow, and delegates listener ordering and mutation semantics to SignalKit instead of duplicating callback machinery. Regular events share one lazy Frame; unit-filtered events are grouped by normalized unit-token sets so `RegisterUnitEvent` registrations do not overwrite incompatible filters on the same Frame.


`lifecycleKit` depends on Registry API 2, SignalKit API 1, and EventKit API 1. It owns per-addon phase state, converts `ADDON_LOADED`, `PLAYER_LOGIN`, and `PLAYER_LOGOUT` into replay-aware lifecycle phases, and leaves all WoW Frame registration inside EventKit.

`moduleKit` depends directly on Registry API 2 and LifecycleKit API 1. It owns addon-local module lifecycle, topological dependency graphs, explicit `automatic`/`strict` dependency policies, and addon-scoped dependency injection. Hard `DependsOn` edges define activation requirements, while optional/`Before`/`After` edges remain ordering constraints for whole-container graph operations. Compatible ModuleKit revisions preserve existing addon/container identity and route lifecycle subscriptions through shared runtime dispatch so embedded upgrades can move live containers onto the newest accepted implementation. It deliberately does not depend directly on EventKit or SignalKit; those remain transitive implementation concerns of LifecycleKit.

`timerKit` depends directly on Registry API 2 and LifecycleKit API 1. It wraps only the stable `C_Timer.NewTimer` / `C_Timer.NewTicker` boundary, provides deterministic logical timer state and ownership scopes, and closes addon-owned scopes through LifecycleKit shutdown. Running native callbacks dispatch through shared package state so future compatible revisions can update logical behavior without replacing Timer/Scope identity. TimerKit does not depend on ModuleKit; module code may opt into addon-owned or manually owned timer scopes without creating a package cycle.

`schedulerKit` depends directly on Registry API 2, LifecycleKit API 1, and TimerKit API 1. It owns cooperative coroutine execution, weighted priority queues, frame-budget observation, delayed/repeating scheduled work, and cancellation scopes. SchedulerKit installs an OnUpdate driver only while ready work exists and uses TimerKit for delay waiting, so delayed-only workloads do not keep a per-frame handler active. It does not depend on ModuleKit; modules may opt into addon-owned SchedulerKit scopes without coupling the two packages.


`poolKit` depends only on Registry API 2. Its pooling algorithm is pure Lua and intentionally sits outside the lifecycle/event/scheduling branch: consumers can reuse objects without pulling in Frames, timers, coroutines, or addon lifecycle state. Retention is bounded by default, with `PoolKit.UNBOUNDED` as an explicit caller-owned escape hatch.

`clientKit` depends only on Registry API 2. It answers which client flavour is running and what the host exposes, through a capability table probed once at bootstrap, and offers shims that give the few flavour-dependent host calls one shape. Every flag is `false` when the host lacks the feature, and an absent `WOW_PROJECT_ID` yields the most conservative flavour, never "everything true".

`cacheKit` depends only on Registry API 2. It gives consumers bounded caches (LRU by count, TTL by age, memoisation, snapshots with diffs) so that "bounded by default" is a structure rather than a rule to remember. Clearing on a host event is resolved at call time through `Registry:Find("eventKit", 1)`, so EventKit is optional and never an edge in the load order.

`profileKit` depends only on Registry API 2. It measures named sections with count, total, spike and last time from `debugprofilestop`, costs a table read and a call while disabled, and refuses sections beyond a fixed cap instead of growing.

`readinessKit` depends directly on Registry API 2 and TimerKit API 1. It owns named gates for host data that arrives after load: one probe per gate, polling on one TimerKit repeating timer per pending gate in a Kit-owned scope, timeouts, negative caching and bounded FIFO waiters. It sits above TimerKit because a timeout needs a timer, and LifecycleKit's phases stay one-shot. Re-probing on a host event resolves EventKit at call time through `Registry:Find("eventKit", 1)`, so it adds no edge to the load order.
