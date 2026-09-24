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
├── schemaKit/
├── localeKit/
├── hookKit/
├── settingsKit/
├── optionsKit/
├── commandKit/
├── codecKit/
├── interopKit/
├── mediaKit/
├── brokerKit/
├── logKit/
├── compatKit/
├── testKit/
├── commKit/
├── widgetKit/
├── apiKit/
├── <future-package>/
└── ...
```

Every visible directory directly under `packages/` is considered a publishable package and must contain a valid `package.manifest.json`. Repository tooling deliberately rejects "ghost" package directories that are not represented by a manifest.

## Package naming

Public framework capability packages use an Apple-style `Kit` suffix. The canonical machine-readable package ID is lowerCamelCase (`signalKit`, `eventKit`, `lifecycleKit`, `moduleKit`, `timerKit`, `schedulerKit`, `poolKit`, `clientKit`, `cacheKit`, `profileKit`, `readinessKit`, `schemaKit`, `localeKit`, `hookKit`, `settingsKit`, `optionsKit`, `commandKit`, `codecKit`, `interopKit`, `mediaKit`, `testKit`, `commKit`, `widgetKit`, `apiKit`, `brokerKit`, `logKit`, `compatKit`), while the Lua facade/module name is PascalCase (`SignalKit`, `EventKit`, `LifecycleKit`, `ModuleKit`, `TimerKit`, `SchedulerKit`, `PoolKit`, `ClientKit`, `CacheKit`, `ProfileKit`, `ReadinessKit`, `SchemaKit`, `LocaleKit`, `HookKit`, `SettingsKit`, `OptionsKit`, `CommandKit`, `CodecKit`, `InteropKit`, `MediaKit`, `TestKit`, `CommKit`, `WidgetKit`, `ApiKit`, `BrokerKit`, `LogKit`, `CompatKit`).

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
│   ├── <Facade>.lua        # the one top-level runtime file, loaded first
│   ├── .luarc.json         # lua-language-server workspace for this directory
│   └── <subdirectory>/     # optional further runtime files, loaded after it
└── tests/
    ├── README.md
    ├── *_spec.lua
    └── support/<Facade>TestEnv.lua
```

[`PACKAGE_MANIFEST.md`](PACKAGE_MANIFEST.md#minimum-package-layout) gives the
full rules; repository validation enforces them.

Cross-package behavior must use public APIs. Consumers must not reach into another package's internal source or private runtime state.

## Dependency direction

The current runtime dependency graph is:

```text
registry
├──→ apiKit
├──→ clientKit
├──→ compatKit
├──→ cacheKit
├──→ profileKit
├──→ schemaKit
│       ├──→ commandKit
│       ├──→ settingsKit   (also needs signalKit)
│       └──→ optionsKit    (also needs signalKit)
├──→ localeKit
├──→ hookKit
├──→ interopKit
├──→ poolKit
│       ├──→ codecKit
│       └──→ widgetKit   (also needs signalKit)
├──→ timerKit
│       ├──→ readinessKit
│       └──→ schedulerKit
│               ├──→ commKit   (also signalKit, eventKit, poolKit)
│               └──→ testKit   (also lifecycleKit; development only, never bundled)
└──→ signalKit
       ├──→ mediaKit
       ├──→ brokerKit
       ├──→ logKit
       ↓
     eventKit
       ↓
   lifecycleKit
    └──→ moduleKit
```

`timerKit` sits on Registry alone and `schedulerKit` on TimerKit; neither depends on LifecycleKit, and each finds it and EventKit only through `Registry:Find` to arrange that its addon scopes close at logout. LifecycleKit calls `CloseAddonScopes` on both at an addon's shutdown when they are present, the same two-step it uses for EventKit. `moduleKit` is the one capability that depends on LifecycleKit by design, because modules follow addon phases.

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

The dependency layer directly above Registry holds the Kits that need nothing else: `signalKit`, `poolKit`, `clientKit`, `cacheKit`, `profileKit`, `schemaKit`, `localeKit`, `hookKit` and `interopKit`. Of these, `signalKit` is the one the event and lifecycle branch is built on. SignalKit uses Registry only for embedded-package identity; its dispatch algorithm is pure Lua and does not depend on WoW Frames or event APIs.

`eventKit` is the first WoW-specific package in the dependency chain (ClientKit is WoW-specific too but stands alone). It depends on Registry API 2 and SignalKit API 1, finds SchedulerKit through `Registry:Find` for `Coalesce` and `Derive`, keeps the `CreateFrame`/Frame registration boundary narrow, routes the payload-less combat log event through one `CombatLogGetCurrentEventInfo` read per event fanned out by sub-event (`ConnectCombatLog`), and delegates listener ordering and mutation semantics to SignalKit instead of duplicating callback machinery. Regular events share one lazy Frame; unit-filtered events are grouped by normalized unit-token sets so `RegisterUnitEvent` registrations do not overwrite incompatible filters on the same Frame.


`lifecycleKit` depends on Registry API 2, SignalKit API 1, and EventKit API 1. It owns per-addon phase state, converts `ADDON_LOADED`, `PLAYER_LOGIN`, and `PLAYER_LOGOUT` into replay-aware lifecycle phases, keeps one shared combat-lockdown state from `PLAYER_REGEN_DISABLED` / `PLAYER_REGEN_ENABLED` with a bounded per-addon "run when out of combat" queue, lets an addon declare itself halted for the session and announces that to the addons that depend on it, owns addon-shutdown teardown for TimerKit scopes, SchedulerKit scopes, EventKit scopes, HookKit scopes, CommandKit scopes, CommKit scopes and the SignalKit bus in that order (every step runs, the first failure wins), and leaves all WoW Frame registration inside EventKit.

`moduleKit` depends directly on Registry API 2 and LifecycleKit API 1. It owns addon-local module lifecycle, topological dependency graphs, explicit `automatic`/`strict` dependency policies, and addon-scoped dependency injection whose providers and module definitions can declare an `implements` contract (a list of method names, or a SchemaKit schema when SchemaKit is loaded) checked once per value handed out. Hard `DependsOn` edges define activation requirements, while optional/`Before`/`After` edges remain ordering constraints for whole-container graph operations. Each module owns `module.scope` with `Timers`, `Events`, `Jobs`, `Hooks`, `Messages`, `Commands` and `Comm`, created on first use through `Registry:Find` and closed when the module is disabled, so a module writes no teardown; a module may declare `requiresAddons`, and a halted addon among them blocks the module until the session ends. Compatible ModuleKit revisions preserve existing addon/container identity and route lifecycle subscriptions through shared runtime dispatch so embedded upgrades can move live containers onto the newest accepted implementation. It deliberately does not depend directly on EventKit or SignalKit; those remain transitive implementation concerns of LifecycleKit.

`timerKit` depends only on Registry API 2; LifecycleKit, when present, closes its addon scopes at shutdown through `TimerKit:CloseAddonScopes`. It wraps only the stable `C_Timer.NewTimer` / `C_Timer.NewTicker` boundary, provides deterministic logical timer state and ownership scopes; an addon scope closes at logout through LifecycleKit when present, otherwise through one EventKit `PLAYER_LOGOUT` connection, otherwise by the addon's own `CloseAddonScopes` call. Running native callbacks dispatch through shared package state so future compatible revisions can update logical behavior without replacing Timer/Scope identity. TimerKit does not depend on ModuleKit; module code may opt into addon-owned or manually owned timer scopes without creating a package cycle.

`schedulerKit` depends on Registry API 2 and TimerKit API 1; LifecycleKit, when present, closes its addon scopes at shutdown through `SchedulerKit:CloseAddonScopes`, and without LifecycleKit SchedulerKit's own EventKit `PLAYER_LOGOUT` connection does when EventKit is loaded. It owns cooperative coroutine execution, weighted priority queues, frame-budget observation, delayed/repeating scheduled work, and cancellation scopes. SchedulerKit installs an OnUpdate driver only while ready work exists and uses TimerKit for delay waiting, so delayed-only workloads do not keep a per-frame handler active. It does not depend on ModuleKit; modules may opt into addon-owned SchedulerKit scopes without coupling the two packages.


`poolKit` depends only on Registry API 2. Its pooling algorithm is pure Lua and intentionally sits outside the lifecycle/event/scheduling branch: consumers can reuse objects without pulling in Frames, timers, coroutines, or addon lifecycle state. Retention is bounded by default, with `PoolKit.UNBOUNDED` as an explicit caller-owned escape hatch.

`clientKit` depends only on Registry API 2. It answers which client flavour is running and what the host exposes, through a capability table probed once at bootstrap, offers shims that give the few flavour-dependent host calls one shape, and reads an addon's `.toc` fields once into a read-only manifest snapshot with locale fallback (`GetManifest`). Every flag is `false` when the host lacks the feature, and an absent `WOW_PROJECT_ID` yields the most conservative flavour, never "everything true".

`compatKit` depends only on Registry API 2. It keeps one entry per shim name and applies each pending shim once, in name order, under `pcall` with failures reported through the host error handler; the highest version registered before `Apply` wins across embedded copies, a later higher version is recorded but not run, and `SkipShim` is the host's opt-out. Provider registries keep an array ordered by priority and name so `Resolve` walks it without allocating, memoise the cascade's answer and re-validate it with the provider's probe on every call. ClientKit (the flavour shims are filtered on) and ApiKit (whose installed surface `context.hasApi` checks by function identity, since generated bindings are direct aliases) are found at call time through `Registry:Find`, adding no load-order edge. The catalogue of taint-hostile subsystems is published as a read-only table mirroring EMBEDDING.md, and a tooling test holds both against the apiKit metadata.

`cacheKit` depends only on Registry API 2. It gives consumers bounded caches (LRU by count, TTL by age with negative entries, memoisation with a `cacheable` predicate, snapshots with diffs, lazily expanded trees and bounded queues) so that "bounded by default" is a structure rather than a rule to remember. Clearing on a host event is resolved at call time through `Registry:Find("eventKit", 1)`, so EventKit is optional and never an edge in the load order.

`profileKit` depends only on Registry API 2. It measures named sections with count, total, spike and last time from `debugprofilestop`, costs a table read and a call while disabled, and refuses sections beyond a fixed cap instead of growing.

`readinessKit` depends directly on Registry API 2 and TimerKit API 1. It owns named gates for host data that arrives after load: one probe per gate, polling on one TimerKit repeating timer per pending gate in a Kit-owned scope, timeouts, negative caching and bounded FIFO waiters. It sits above TimerKit because a timeout needs a timer, and LifecycleKit's phases stay one-shot. Re-probing on a host event resolves EventKit at call time through `Registry:Find("eventKit", 1)`, so it adds no edge to the load order.

`schemaKit` depends only on Registry API 2. It is the shared validation core for values from outside a Kit (arguments, saved variables, options, received messages): immutable builder nodes compile into a flat checker, sealed schemas report `{ path, rule, expected, found }` failures that never contain the value, a valid check allocates nothing, depth (the `maxDepth` limit, 16 by default) and collection sizes are bounded, and secret values are refused before any comparison through `issecretvalue` looked up per check.

`localeKit` depends only on Registry API 2. It keeps one read table per addon. Translation files write through per-call proxies: the client-locale proxy overwrites, the default proxy does not. Files for locales the client does not need get `nil` and allocate nothing. Missing keys are stored as themselves and reported once through the host error handler, and `Format` supports indexed specifiers so translators can reorder arguments.

`hookKit` depends only on Registry API 2. It owns reversible hooks in three named semantics (secure post-hook over `hooksecurefunc` / `HookScript`, safe pre-hook, raw replacement), refuses non-secure hooks of secure targets and of protected scripts, and keeps records per scope in weak-keyed tables. ClientKit is found at call time through `Registry:Find` for `IsSecret`, so it adds no edge to the load order.

`signalKit` also lets a signal observe its own use: `onFirst`/`onLast` hooks fire on the 0→1 and 1→0 listener transitions so a source can be active only while observed, `GetGeneration` counts firings, and a journal (`NewJournal`) keeps the last firings in a preallocated ring for explicit pull through `History()`.

`signalKit` also carries the named message bus: a bus is a name-to-signal map with a declared topic policy, so two modules or two addons that share no reference can talk while dispatch, ordering and re-entrancy stay SignalKit's own; listener errors on a bus are isolated and reported because a bus is a cross-addon boundary.

`settingsKit` depends on Registry API 2, SchemaKit API 1 and SignalKit API 1. It opens one database per saved-variable name over empty proxy views that resolve the saved table on every access, fall back to defaults compiled once from the schema's description, and validate each write with one probe check at the writer's line. Secret values are refused. EventKit is found through `Registry:Find` to compact on `PLAYER_LOGOUT`.

`optionsKit` depends on Registry API 2, SchemaKit API 1 and SignalKit API 1. It owns one sealed options tree per addon: every value option carries a SchemaKit schema built at `Define`, paths are pre-indexed and siblings pre-sorted so `Get`, `Set` and `Walk` allocate nothing, and changes fire a SignalKit signal. SettingsKit is found at call time through `Registry:Find` when `Define` receives `options.db` or `ProfileOptions` builds the ready-made profile management group over a database, so it adds no edge to the load order.

`commandKit` depends on Registry API 2 and SchemaKit API 1. It owns slash registrations per scope with a permanent per-key dispatcher that turns inert once unregistered, a stateless hyperlink-aware parser, schema-checked sub-commands with generated usage, output sinks and opt-in tab completion; OptionsKit, LocaleKit and ClientKit are found at call time through `Registry:Find`, and LifecycleKit or EventKit, found the same way, decide who closes an addon scope at logout.

`codecKit` depends on Registry API 2 and PoolKit API 1. It serialises values (varint integers, exact binary64 doubles, raw strings, array, map and mixed tables; cycles refused), compresses with pure-Lua raw DEFLATE, and escapes for the addon channel or base-85 encodes for print, behind a version byte and a stage-flags byte; decoding returns `false, reason` for any string, bounded by shared limits. SchedulerKit is found at call time through `Registry:Find` for the asynchronous variants, so it adds no edge to the load order.

`interopKit` depends only on Registry API 2. It exposes Kit facades to LibStub under `MoltenCodes-<Facade>-<api>` with the revision as minor, refuses majors other libraries hold, and records LibStub libraries it adopts in its own state (`InteropKit:Find`), because Registry's line budget leaves no room for foreign entries. LibStub is found at call time through `rawget(_G, "LibStub")` and adds no edge to the load order.

`mediaKit` depends on Registry API 2 and SignalKit API 1. It keeps one registry of seven fixed media types; entries are a path or a FileDataID, fonts carry a script mask checked against `GetLocale`, `List` returns a cached sorted array rebuilt only after a registration of its type (for fonts, also when the client's script changes), defaults are per consumer over the client's built-in media, and LibSharedMedia-3.0 is reached through `rawget(_G, "LibStub")` at call time for read-only adoption and explicit mirroring without echo.

`brokerKit` depends on Registry API 2 and SignalKit API 1. It keeps one registry of named data objects in the LibDataBroker-1.1 idiom: each object is an empty proxy whose reads fall through to an attribute table and whose writes run one validated path that fires per-attribute and any-attribute SignalKit signals; the fifteen LibDataBroker attributes are typed, custom ones hold anything, `Iterate` walks a cached sorted array rebuilt only after an object was added, and LibDataBroker-1.1 is reached through `rawget(_G, "LibStub")` at call time for explicit exposure and read-only adoption without echo. It sits beside `mediaKit` in the layer above SignalKit and adds no other load-order edge.

`logKit` depends on Registry API 2 and SignalKit API 1. It gives every addon one logger whose disabled calls cost a receiver check and one comparison and never read their arguments; enabled messages are formatted once with secret arguments replaced by a placeholder, cut to `maxMessageLength`, recorded in a preallocated ring built on `SignalKit:NewJournal` and handed to sinks through one reused record table. Levels resolve addon override, then global, then the default, cached per logger. CommandKit (`/log`) and SettingsKit (persisted levels) are found at call time through `Registry:Find`, adding no load-order edge; it sits beside MediaKit as a SignalKit consumer with no user-interface dependency, and its sink contract is what a later viewer window or ProfileKit report can share.

`testKit` depends on Registry API 2, LifecycleKit API 1 and SchedulerKit API 1 and is development-only, never bundled (`"distribution": "development"` in its manifest, ignored by `.pkgmeta`). Suites wait for a LifecycleKit phase; tests run one at a time in a SchedulerKit job, one coroutine per step; EventKit and TimerKit are found through `Registry:Find`, adding no load-order edge.

`commKit` depends on Registry API 2 and on SignalKit, EventKit, TimerKit, SchedulerKit and PoolKit API 1; LifecycleKit closes its addon scopes at shutdown through `CommKit:CloseAddonScopes` when both are present. It owns addon messaging: a control-byte chunk protocol, reassembly bounded in streams, bytes per sender and time (the sender keeps the same in-flight and byte bounds so a well-behaved peer never trips them, and an abort chunk tells receivers a cancelled stream is gone), three bounded priority queues with per-destination round-robin, one token bucket shared by the session and charged for outside traffic through HookKit when present, and content-hash sync sets. The send driver is a SchedulerKit job that exists only while something is queued. TimerKit is found through `Registry:Find`; CodecKit, HookKit and SchemaKit are optional.

`apiKit` depends on Registry API 2 and nothing else. It is the flavour-aware wrapper over the public World of Warcraft API: a handwritten facade (`ApiKit.lua`) that publishes the namespace tables (`MoltenCodes.wow.<flavour>.api`, and the `wow` global when free), detects the running client's flavour once at load and runs the matching installer; and one generated file per flavour (`flavours/<Flavour>.lua`) that binds every documented Blizzard function to a readable name by direct alias. The generated files, the LuaCATS definitions under `types/<flavour>/` and the change reports are produced from the metadata under `metadata/<flavour>/` by `tooling/api/`, never edited by hand; the design is [`API_KIT_DESIGN.md`](API_KIT_DESIGN.md). The flavour files depend on the facade only, so the builder lists them after it in load order; this is the one package whose `src/` holds more than the facade.

`widgetKit` depends on Registry API 2, PoolKit API 1 and SignalKit API 1. It owns a versioned registry of widget types, each drawn from one capped, generation-stamped PoolKit pool; containers laid out by registered layout functions only when asked, never from `OnSizeChanged`; a plain anchor value type with position bindings; and a renderer for OptionsKit trees. OptionsKit, SchedulerKit and MediaKit are found at call time through `Registry:Find`, adding no load-order edge; a SettingsKit scope view is accepted as the position storage table without WidgetKit depending on SettingsKit.
