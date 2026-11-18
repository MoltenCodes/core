# ModuleKit Internals

This document explains ModuleKit's implementation invariants for maintainers. It is not a public API contract; [`API.md`](API.md) is authoritative for consumer-visible behavior.

## The core and its parts

ModuleKit's core is `src/ModuleKit.lua`; injection, `implements` contracts and required addons live in three part files under `src/parts/` (ADR 0001), which an addon lists after the core only when it uses them. Each file is organised into explicit sections, and its header block lists them.

The core reaches a part only through entries of `_state.dispatch` that the part fills: `resolveForHook` and `addInjections` (Injection), `compileImplements` and `checkImplements` (Implements), `addRequiredAddon`, `declareRequiredAddons`, `requiredAddonBlocker` and `dependencyHalted` (RequiredAddons). While a part is not installed, `installPartStubs` puts a default in each of its entries and a stub on each of its members (`PART_LAYOUT`). The defaults are exact: the core refuses a part's definition fields first, so no module of this revision holds what an absent part would serve. Only state an older revision made can reach a default, which leaves it in place and reports it once (`reportUnserved`, `_state.unservedReported`). A part already installed by any addon keeps its members and entries when a newer core loads.

A part calls the core through `_state.helpers`, which every core revision refills at commit, and reads it at call time, so a core upgraded after the part loaded serves it. Parts record themselves last, `_state.parts[name] = { revision }`, so a part whose file failed is never reported installed, and an equal or older part revision that loads later returns at once.

## Section map

| Section | Responsibility |
|---|---|
| Dependencies | Reads `MoltenCodes.Registry`, validates Registry API 2 and the LifecycleKit API 1 facade. Nothing below runs if this fails. |
| Bootstrap | Reconciles embedded revisions, decides whether this copy owns the package, refuses state older than revision 23 (the upgrade floor), and installs or adopts the shared `Addon` / `Module` prototypes and `_state`. |
| Shared helpers | `isSecret`, `describeKey`, `reportError`, `validateFacade` and the `limits` loop, copied verbatim from `tooling/shared/lua/` between markers. |
| Validation helpers | Argument checks, definition-mutability rules (`created` state only), post-shutdown rejection, and the late-module ordering guard. |
| Graph | Edge construction from the four constraint kinds, cycle reporting, the topological sort, and the graph cache with its invalidation. |
| Optional packages | The silent `Registry:Find` lookup (with `Get` as the fallback on an older Registry) that the module scopes and the Implements part's schema form share. |
| Module scopes | The per-module scope object, its lazy fields resolved through `findOptionalPackage`, and closing them. |
| Lifecycle operations | Single-module transitions, the two dependency policies, intent versus fact and recovery of blocked dependents, the container's own halt, whole-container passes, deferred catch-up, the halt pass and shared runtime dispatch (`invokeDispatch`). |
| Module public API | The functions installed on the shared `Module` prototype. |
| Addon public API | The functions installed on the shared `Addon` prototype. |
| Addon creation | Container identity, the dispatched-phase set, and LifecycleKit subscriptions, including the addon's own halted notice. |
| Package-wide limits | `SetLimits` / `GetLimits` over the shared `limits` block and the call-time coupling to LifecycleKit's `maxDependencies`. |
| Parts | `PART_LAYOUT`, the stubs, the dispatch defaults, `reportUnserved` and `HasPart`. |
| Commit | Publishes the public surface, installs the part stubs and shared runtime dispatch, refills `_state.helpers`, and drops cached graphs on an upgrade. |

The parts: `ModuleKit-Injection.lua` (provider registration and resolution with its cycle stack, `Inject`, the `inject` field and the injection table of a module's hooks), `ModuleKit-Implements.lua` (compiling and checking contracts) and `ModuleKit-RequiredAddons.lua` (the `requiresAddons` entries, their `DependsOn` edges and `OnDependencyHalted` subscription, what blocks an enable on another addon's halt, and the cascade when one halts).

## Shared embedded state

Registry owns one implementation table for `(moduleKit, API 1)`. ModuleKit stores everything a compatible upgrade must preserve on that table:

```text
ModuleKit facade
├── Addon            -- shared method prototype
├── Module           -- shared method prototype
├── UNBOUNDED        -- the sentinel, the same table as _state.unbounded
└── _state
    ├── schema
    ├── runtimeRevision
    ├── addons[name] -- containers
    ├── dispatch     -- initializeAll / enableAll / shutdown / halted, and the parts' entries
    ├── parts[name]  -- { revision } of each installed part (revision 24)
    ├── helpers      -- the core functions the parts call, refilled by every core revision
    ├── partInterface -- the interface number the parts check (1)
    ├── unservedReported[part] -- older state found without its part, reported once
    ├── scopeMetatable -- shared by every module scope; each revision installs its __index
    ├── unbounded    -- the UNBOUNDED sentinel, created once so every revision shares its identity
    ├── limits       -- { maxRequiredAddons }, written in place by SetLimits
    └── prototypeLayers -- module prototype to its metatable (revision 23)
```

**The upgrade floor.** No revision was ever published, so the bootstrap takes
over only the state revision 23 left (every field above but the part fields,
which it adds) and refuses an older revision's outright rather than filling in
what it lacked. Containers and modules revision 23 made are complete and their
subscriptions already reach `_state.dispatch`, so nothing is migrated: the
commit only drops each container's cached graph. `SetLimits` asks `LifecycleKit:GetLimits()` at call time, not at
load, because LifecycleKit can be upgraded in place and its limit changed after
ModuleKit loaded.

Existing containers and modules therefore survive an in-place upgrade: their metatables point at the shared prototypes, and the newer copy replaces methods on those prototypes rather than replacing objects.

## Module scopes

Every module carries one scope table (`_scope`, published as `scope`) whose
metatable is `_state.scopeMetatable`. Keeping that metatable in shared state and
re-installing `__index` at every commit is what moves scopes created by an older
copy onto the newer lookup, exactly as the prototypes do for methods.

`__index` runs only for a missing field. It checks `_scopeOpen`, then looks in
`_keptScopes` for the scope the module's last disable closed: when the Kit
has `Reopen` and it answers `true`, that object is stored and returned, and the
lookup and construction below are skipped; a `Reopen` that raises or refuses
gives the kept scope up. Otherwise it resolves the
Kit through `Registry:Find` (read from the facade on every call, because an
embedded Registry upgrade replaces the method), creates the scope and stores
the result with `rawset`, so every later read is a plain table hit. Every field
but `Messages` calls the Kit's `CreateScope()`. `Messages` calls
`SignalKit:ForAddon(addonName)` and then the bus's `CreateScope()`: a SignalKit
without `Bus` and `ForAddon` predates buses, `ForAddon` may answer
`nil, "full"`, and a closed bus raises from `CreateScope` without offering a
public query to ask first, so that one call runs under `pcall`. A missing Kit,
one without `CreateScope`, or a bus that cannot be had yields `nil` and stores
nothing, so a later read tries again; under the container's `"raise"` missing-
scope policy (`_missingScopePolicy`, absent by default) the first two raise
instead, at level 3 from `missingScopeKit`, which is the reading line, and the
call is deliberately not a tail call so the level holds. `__index` does not
check the key for a secret: the client raises on `scope[secret]` before any
`__index` runs (`docs/EMBEDDING.md`). The helpers sit in a `do` block with
`scopeIndex` to keep the main chunk under Lua 5.1's 200-local limit.

`_scopeOpen` is set immediately before `OnEnable` is invoked and cleared by
`closeModuleScope`, which runs after a successful `OnDisable`, after a failed
`OnEnable`, and at shutdown or halt whatever `OnDisable` did; a module that
never enabled has none, which reads as closed. A scope whose only key is
`_module` holds nothing to close, and `closeModuleScope` returns after one or
two `next` calls in that usual case. Otherwise closing walks the
fields in a fixed, alphabetical order (comm, commands, events, hooks, jobs, messages, timers;
they are independent, so any fixed order would do), closes each one even when an earlier
`Close` raised, and hands back the first failure; a scope that closed cleanly
and whose Kit has `Reopen` is kept in `_keptScopes[field]` (created on first
use) for the next enable; `disableOne` re-raises it only
after the module has become `disabled`, so a scope failure never leaves a module
half-transitioned.

## The blocked-module flag

Every targeted `Enable` ends in `recoverBlockedDependents`, which used to scan
every module for `_enableBlockedBy` and nearly always found nothing. Every
write of a blocker goes through `markBlocked`, which also sets the container's
`_mayHaveBlocked = true`; a scan that finds no blocked module sets it to
`false`, and `false` skips the scan. A new container starts at `false`. A
container an older revision created has no field, reads `nil`, and is scanned
as before, so an in-place upgrade needs no migration.

## Intent versus fact

Two per-module fields sit beside `_state`:

- `_wantedEnabled` — intent. Starts as the container's `_defaultModuleState`
  (absent reads as `true`) or the definition's `enabledState`; `SetEnabledState`
  writes it directly (revision 23). Written only by the public
  `Enable` / `Disable` on the module itself, by the addon's own `EnableAll` /
  `DisableAll` before their pass (the LifecycleKit-driven `enableAll` dispatch
  writes nothing and skips modules whose intent is `false`), and set by every successful `enableOne`, since an enabled
  module is by definition wanted. The `automatic` disable cascade never touches
  it.
- `_enableBlockedBy` — the dependency a wanted module is waiting for. Set where
  an enable is refused or aborted by a dependency: the `EnableAll` pass's blocked
  branch, the `strict` targeted check, and the `automatic` recursion, which sets
  it before recursing into a dependency that is not enabled and clears it once
  every dependency succeeded — so it survives exactly when a dependency raised.
  The `automatic` disable cascade also sets it on each dependent it takes down,
  naming that dependent's direct dependency, the module whose recursive
  `disableWithPolicy` call took it down, not the module the public `Disable`
  was called on: in a chain `Top -> Middle -> Base`, `Base:Disable()` blocks
  `Middle` by `Base` and `Top` by `Middle`. Recovery walks the graph in order,
  so the whole chain still comes back, in graph order, when `Base` is enabled
  again.

`recoverBlockedDependents` runs after the public `Enable` and `Activate`. It
first scans `_moduleOrder` for any `_enableBlockedBy` and returns without
building the graph when there is none, which is the usual case; otherwise it
walks the full graph order once and enables every wanted, blocked module whose
hard dependencies are all enabled; because dependencies precede dependents, one
walk recovers a whole chain. It clears `_enableBlockedBy` before each attempt,
so a module that then fails on its own is not retried by the next recovery. It
is skipped inside a whole-container pass (the pass owns blocking), after
shutdown, and when the graph is invalid, which targeted operations tolerate but
a graph-ordered walk cannot.

Every module of revision 23 or later carries `_wantedEnabled` and its scope,
so an upgrade carries intent and blocking across unchanged. Absent optional
fields need no backfill, because they read as empty (see *Allocation policy*).

## Revision 23 conveniences

The new functions share one main-chunk local, `addonConveniences`, together
with the two policy method pairs that moved into it (main chunk 195 → 193
active locals). Container fields, each absent until set:

| Field | Meaning |
|---|---|
| `_defaultModuleState` | `false` when modules start unwanted; `SetDefaultModuleState(true)` removes it. |
| `_defaultModulePrototype` | The default prototype. |
| `_moduleCreatedBus` | The addon's SignalKit bus, once `OnModuleCreated` subscribed; `CreateModule` publishes only when it is set. |

A module created with a prototype carries `_prototype` and the metatable
`prototypeMetatable(prototype)` returns: `{ __index = layer }`, where `layer`
holds a copy of the `Module` methods and has `{ __index = prototype }`. The map
`state.prototypeLayers` (prototype to metatable) keeps one per prototype for the
session; Lua 5.1 has no ephemeron tables, so a weak key would not free a
prototype its layer references anyway. The commit section refills every layer
(`refreshLayers`) after writing the `Module` methods, so an in-place upgrade
reaches prototyped modules. `invokeHook` reads a hook with `rawget` and, only
when that is `nil` and the module has `_prototype`, through the module, so a
plain module's transitions cost one extra `rawget` for a hook it does not have.
`catchUpModule` enables only a wanted module.

## Halted addons

`_requiredAddons` holds a module's `requiresAddons`, deduplicated, in
declaration order; the RequiredAddons part writes it, and a module that
declares none has no such field.

`haltBlocker(module)` is the single question every enable path asks: `"halted"`
when the container's own LifecycleKit instance has `_halted == true` (read with
`rawget`; LifecycleKit documents the field as stable for API 1 and sets it
before it notifies anyone, and an instance of a revision older than halts has
no field and never halts), else, for a module with `_requiredAddons`, what the RequiredAddons part's
`requiredAddonBlocker` answers: the first required addon whose
`LifecycleKit:ForAddon(name):GetHaltReason()` is set; else `nil`. It is asked, not cached, because halted is terminal and LifecycleKit is
the authority. Where it is asked:

- `enableWithPolicy`, before the policy logic, for a module that is not
  enabled: records the refusal and raises at the caller's line (the
  `automatic` recursion adds its depth to the error level, so a refusal deep
  in a dependency chain still points at the caller);
- `enableOne`, once `OnEnable` has returned: a hook that halted the addon or a
  required addon found the module not yet enabled, so the halt pass skipped
  it; it is disabled here instead, and on its own addon's halt its scope is
  closed even when `OnDisable` fails. The `automatic` recursion checks each
  dependency's state after enabling it and leaves the dependent off, blocked
  by `haltBlocker(dependent)` when the halt stops the dependent too and by
  the dependency otherwise;
- `runEnableAllPass`: the module counts as failed, so its hard dependents are
  blocked behind it, exactly as for a failed dependency;
- `catchUpModule`: records the refusal without raising, because definition
  catch-up is implicit;
- `recoverBlockedDependents`: returns at once for a halted container, and
  keeps a module whose required addon halted blocked instead of enabling it;
- `addonCreateModule`, after publishing: sets `_enableBlockedBy` so the enable
  state shows the block before anything tries to enable the module.

`addonCreateModule` also has the part call `DependsOn` on the container's
lifecycle for every required addon (`declareRequiredAddons`), before
publishing, so a `"full"` refusal leaves the container without the module.

Two notices drive the transitions, through shared dispatch like the phases.
`halted` is subscribed when the container is created. `dependencyHalted` is
subscribed by the RequiredAddons part's `subscribeToDependencyHalts` only once
a module declares `requiresAddons` (from `declareRequiredAddons`, before the
first `DependsOn`, which is when LifecycleKit could first announce a halt that
concerns it).
Its handler acts only on modules that require the halted addon, so a
container without one would receive every notice for nothing, at the cost of
a LifecycleKit handle and a SignalKit listener for the session:

- `halted` (`OnHalted`) runs `haltAllInternal`: it marks every wanted module
  `"halted"` and runs `runDisableAllPass` in terminal mode, because
  LifecycleKit never delivers `shutdown` to a halted addon. It does not set
  `_shutdown`, so the container stays usable for inspection.
- `dependencyHalted` (`OnDependencyHalted`) runs the part's `dependencyHalted`:
  newest module first, every module that requires the halted addon is taken
  down by `blockForHaltedAddon`, which disables enabled hard dependents first
  (recursively, whatever the policy). The module is marked blocked by the
  halted addon, and each dependent by its own direct dependency: a dependent
  of the module names the module, and a dependent of that dependent names the
  dependent, not the module that required the halted addon.

Both subscriptions replay synchronously, and the replay hazard applies.
`OnHalted` replays only for an addon that already halted: a new container has
no modules, so the replay just records it. `OnDependencyHalted` replays every
halted declared dependency; its listener ignores deliveries while the
subscription call is still running, because the module being created is not
published yet (it is blocked by `haltBlocker` once it is).

## The dependency graph

Four constraint kinds produce edges between modules of one container:

| Declaration | Edge | Requires the target to exist |
|---|---|---|
| `DependsOn(name)` | target → module | yes |
| `OptionalDependency(name)` | target → module, when the target exists | no |
| `After(name)` | target → module, when the target exists | no |
| `Before(name)` | module → target, when the target exists | no |

Only `DependsOn` is an activation requirement. The other three are ordering constraints for whole-container operations; they never cause an implicit initialize or enable.

### Ordering algorithm

`topologicalSort` is Kahn's algorithm with module **creation order** as the tie-break between modules that become ready at the same time. Creation order is unique inside a container, so the tie-break is a total order and the result is fully deterministic: the same declarations always produce the same activation order, regardless of load order or `pairs` iteration order.

The ready set is kept sorted by *descending* creation order and consumed from its end. Both callers pass the modules in creation order, so the initial set is filled by walking them backwards and needs no sort:

- emitting a module is `ready[#ready] = nil`, which is O(1);
- a module that becomes ready is placed by binary search, which is O(log n) comparisons plus one array shift.

Neither step removes from the front of an array or re-sorts the ready set, and the emitted order is identical to a full re-sort after every insertion; `Graph_spec` pins it on a twelve-module fixture as well as on the small ones.

Successors of an emitted module are visited in ascending creation order, so `pairs` iteration over the adjacency set cannot leak into the result.

When the sort cannot emit every module, `findCycle` walks the graph again to produce a readable `A -> B -> C -> A` diagnostic. That second walk only runs on the failure path.

`buildEnabledHardOrder` is the degraded variant used by terminal shutdown: it orders only enabled modules, using only their hard-dependency edges, so cleanup has a safe order even when an inactive late definition has made the full graph invalid. It is never cached.

### Graph cache

Every whole-container pass needs the validated order, and before revision 19 each one rebuilt it: `InitializeAll` and `EnableAll` at load, and both halves of every `DisableAll` / `EnableAll` cycle. The graph only changes in two ways, because modules are never removed and a constraint can only be declared while its module is still `created`:

- `CreateModule` publishes a module (a missing dependency may now resolve, and an ordering constraint may now have a target);
- `addNameConstraint` records a `DependsOn`, `OptionalDependency`, `Before` or `After` edge, from a method or a definition list.

Both call `invalidateGraph`, which drops the container's `_graphOrder` and `_graphDependents`. `buildGraph` returns `_graphOrder` when it is present; otherwise it builds, validates and sorts the graph, and on success stores the order and, beside it, `_graphDependents`: for each module that something hard-depends on, the dependents in descending creation order. An invalid graph raises before anything is stored, so its diagnostic is raised, at the caller's level, on every call.

The cached arrays are shared and never written. A rebuild replaces them, so a pass still walking an older array, while one of its hooks created a module, keeps a consistent order; the new module is caught up after the pass, as before (`GraphCache_spec` pins it).

Per module, `hardDependencies` keeps the resolved, creation-ordered list of its `DependsOn` modules in `_hardDependencyList`, the shared `NO_MODULES` when it has none. Once every name resolves the list cannot go stale, since modules are never removed; `addNameConstraint` clears it when the module declares another dependency. A missing dependency raises and stores nothing. The passes read `_hardDependencyList` directly and call `hardDependencies` only when it is absent.

`firstEnabledHardDependent` and `enabledHardDependents` read `_graphDependents` when it is present. Without it (never built, invalidated, or invalid, which targeted operations tolerate) they scan the container, which allocates only when a dependent exists.

An in-place upgrade drops every container's cache in the commit, and the new copy rebuilds it on first use.

## Failure model

A module never enters a permanent failed state. A failure records three things and leaves the module at its previous stable state:

- `_lastError` — the original Lua error object, which may itself be `nil` or `false`;
- `_hasLastError` — the flag that distinguishes "no error" from "an error object of `nil`";
- `_blockedBy` — the related module name, when the operation was refused rather than attempted.

Because an error object may be `nil` or `false`, errors are carried between layers inside a record table (`{ value = ... }`) and re-raised with `error(value, 0)`. `captureFirstError` keeps the first such record; `raiseCaptured` re-raises it unchanged.

A whole-container pass therefore behaves like this:

1. take the graph order, cached or built (which fails loudly if the declarations are invalid);
2. walk it in order, attempting each module whose hard dependencies are satisfied;
3. record a module as blocked, without attempting it, when a hard dependency failed or is not in the required state;
4. after the walk, re-raise the first real callback or provider error.

Terminal shutdown differs deliberately: it is best-effort cleanup, so it attempts every enabled module even after earlier failures, and it keeps going when the full graph is invalid.

## Error levels

Every helper that raises takes the level it raises at, counted from its own
frame, and every public method passes the level that reaches its caller.
Lua 5.1 counts a frame replaced by a tail call as one level (its position is
lost, not skipped), so a public method may tail-call its helper and the count
stays the same. The paths that are several frames deep pass the depth on:

- the `automatic` policy recursion adds its depth, so a refusal deep in a
  dependency chain points at the line that called `Enable`, `Initialize` or
  `Activate`;
- definition catch-up calls `initializeWithPolicy` / `enableWithPolicy` with a
  depth of two (`catchUpModule`, `scheduleCatchUp`), so a missing dependency
  or a `strict` refusal points at the `CreateModule` line;
- a definition's list entries reach `addNameConstraint` at level 5 and its
  `inject` reaches `addInjections` at level 4, which is the `CreateModule`
  caller in both cases; the messages are those of the `Module` methods they
  stand for.

`ErrorLevels_spec.lua` pins one refusal per path at the calling line.

## Absent and secret values

On clients with secret values, comparing a secret with a value of its own
type raises (`==`, `~=`, `<`, `<=` and `rawequal` alike; the dependency policy
check once raised `attempt to compare local 'policy' (a secret string value
...)` on Retail 12.1.0 b69933), and so does using it as a table key. A
comparison with `nil` or with a value of another type happens not to raise. A
value that did not originate in ModuleKit (an argument, a definition or option
field, an `implements` entry or member, a factory's result, a hook field, a
Registry or optional-Kit lookup, a LifecycleKit answer) is still tested for
absence with `type(value) == "nil"`, the repository rule, which never compares
anything; ModuleKit's own state keeps plain `== nil`. A value ModuleKit does compare, format or use as a
key (a name, a list entry, the dependency policy, a limit, a key of the
caller's definition, options, alias-map, limits or `implements` table, the
`requestingModule` of `Resolve`) is first passed to `isSecretValue`, which
reads the `issecretvalue` captured at load (or, when there was none at
load, the global at each call, so a probe installed later is honoured) and
answers `false` on a host without it, and a secret is refused at the caller's line before the first
comparison or key use. A secret key of a dense list is refused with the list's
density message, since it cannot be an index. `Resolve` decides ownership of
`requestingModule` by identity with the module the container keeps under its
`_name`, so it never compares a field read from the caller's table. `scopeIndex`
never sees a secret key (the client refuses `scope[secret]` before `__index`
runs), and `isSchemaLike` answers `false`, without refusing, when
`getmetatable` returns a secret. `SetLimits` and
`GetLimits` check the receiver's type before comparing it with the facade.

## Hooks run under `pcall`

`invokeHook` calls every user hook through `pcall`. That is what turns a hook failure into a recorded module failure instead of an aborted pass — and it is also why a hook cannot yield. In Lua 5.1 a coroutine cannot suspend across a C function, and `pcall` is one; the attempt fails with "attempt to yield across metamethod/C-call boundary", which ModuleKit then records as an ordinary hook failure. `docs/API.md` states this as a consumer-visible rule.

## The lifecycle replay hazard

LifecycleKit replays a phase it has already reached to every new subscriber. That is exactly what a newly created container needs: it catches up to `loaded` and `ready` without racing host events.

It is also a hazard. Subscribing an existing container again would replay every reached phase:

- module hooks would run out of package bootstrap, where the addon has no way to handle their failure;
- the replayed `ready` phase calls `EnableAll`, which would re-enable a module the addon had deliberately disabled.

So only a new container subscribes. Every container carries `_dispatched`, recorded by the subscription callback *before* it dispatches — the phase has happened even if the dispatch raises — and its callbacks reach `_state.dispatch` through `invokeDispatch`, so an in-place upgrade serves them by replacing the dispatch entries and never subscribes again. Revisions before 23 re-subscribed carried-over containers and needed an upgrade probe for that; the upgrade floor removed both.

A new container's replay runs passes over a container that holds no module yet, so nothing in it can shut the container down while the install loop runs.

## Re-entrant module creation

A hook may create a module while a whole-container pass is walking the graph. Catching that module up immediately would happen outside the running pass's blocking set, so it could be activated even though the pass had already decided that one of its hard dependencies failed.

`_passDepth` counts the whole-container passes a container is inside. While it is non-zero, definition-table catch-up is queued on `_pendingCatchUp`, created on the first deferral, and flushed once the outermost pass finishes — with the same effect as creating the module immediately after the pass returned. `_flushingCatchUp` keeps a nested pass that ends during the flush from starting a second one; its modules stay on the queue for the running loop.

The queue is drained with an index cursor and cleared once, not by removing the head each time: shifting every remaining entry down a slot per module made a flush quadratic in the number of modules waiting. Entries appended while the loop runs are picked up by the same pass, so the order is the one creation established.

`module:Activate()` is not deferred. It is an explicit request from addon code, not implicit catch-up, so it keeps its synchronous contract.

Pass bodies report their first error by *returning* it rather than raising, so `runContainerPass` always restores the depth counter and always flushes the queue, whichever way the pass ends.

## Provider resolution

This is the Injection part's. Providers are container-local; two containers never share registration or caches. `_providers` and `_resolutionStack` are created on the container by the first provider and the first factory run.

| Scope | Cached by |
|---|---|
| `value` | nothing to cache |
| `singleton` | the container |
| `module` | the requesting module |
| `transient` | not cached |

Cycle detection tracks `(provider name, requesting module)` rather than provider name alone. That is what lets the same module-scoped provider legitimately resolve for a *different* requesting module while its factory is running, without reporting a false cycle. The resolution stack is a container field, so a nested resolution sees the frames above it.

Injection aliases are resolved in sorted alias order, so factories with side effects run in the same order on every Lua implementation.

**Implements contracts.** These are the Implements part's; the Injection part reaches them through `dispatch.compileImplements` and `dispatch.checkImplements`. A provider record carries `implements`, `nil` or the record `compileImplements` built at registration: `{ names = string[] }` for the list form (a copy of the caller's list) or `{ schema = <sealed SchemaKit schema> }` for the schema form. `resolveProvider` runs `checkImplements` on a factory's result after the `nil` check and before caching, so a refused value is produced again next time; `ProvideValue` and `CreateModule` run it at registration. The list check is one `value[name]` lookup per declared name and allocates nothing when the value conforms; the schema check is SchemaKit's `Check`, which also allocates nothing for a valid value. The contract lives on the provider record rather than in `_state`, so a record keeps its contract under a newer copy; a contract found while the Implements part is absent is reported once and the value is served unchecked. SchemaKit is looked up through `findOptionalPackage` at registration only; the sealed schema's `Check` is a method on SchemaKit's shared prototype, so an in-place SchemaKit upgrade is observed.

## Allocation policy

The per-module steady state is one module table, its resolved injection table and its scope table. Everything a module may not need is absent until something writes it, and reads as empty or `false`:

| Field | Created by | Absent reads as |
|---|---|---|
| `_hardDependencies`, `_optionalDependencies`, `_before`, `_after` | the first constraint of that kind | the shared `EMPTY_NAME_SET` (`moduleNameSet`) |
| `_injectSpec` | the first `Inject` that stores an alias (a refused one creates nothing) | the shared `EMPTY_NAME_SET` |
| `_requiredAddons` | the first `requiresAddons` entry | the shared `NO_REQUIRED_ADDONS` (`moduleRequiredAddons`) |
| `_lastError`, `_hasLastError`, `_blockedBy`, `_enableBlockedBy` | a recorded failure or block | no failure, no block |
| `_scopeOpen` | the first enable | closed |
| `_keptScopes` | the first disable that closes a Kit scope that can be reopened | nothing kept |

The shared tables are never written; a writer gives the module its own table first. `clearFailure` and the other clears remove a field only when it is set, because Lua 5.1 stores a key even when `nil` is assigned to it while absent. The module constructor lists the fields almost every module receives next (its scope, its three hooks, `_injections`, `_scopeOpen`) as `nil` entries: Lua 5.1 sizes a table's hash part from its constructor, so the module is built with the sixteen slots it keeps instead of being rehashed into them. Before revision 19 every module carried five empty tables and a thirty-two-slot hash part; the `addonModules` host benchmark's ten-module addon went from 28.7 KB to 16.8 KB retained, container and LifecycleKit instance included.

A provider that declares `implements` keeps one contract record and, for the list form, one copy of its names; a module's `implements` is checked at creation and keeps nothing. The scope's Kit scopes are created only when read, so a module that never uses them allocates nothing more; `GetEnableState()` allocates its snapshot. Building the graph allocates the adjacency and indegree maps, the ready set, the result array and the dependent lists, once per change of the graph (see *Graph cache*). With the graph cached, a whole-container pass, `ValidateGraph` and a targeted `Enable` or `Disable` allocate nothing when every hook succeeds: the passes create their failed-module set on the first failure, and the `automatic` policy creates its recursion guard only for a module with hard dependencies. `Allocation_spec` pins these. All of these are lifecycle-scale operations rather than per-frame work.

## Field access

ModuleKit reads and writes its own fields on `_state`, containers and modules with plain indexing (`module._state`, `addon._moduleOrder`, `state.addons`); revision 24 converted the remaining literal-key `rawget` / `rawset` calls on them. Their metatables only point `__index` at the method prototypes, so a present field is a plain table read and an absent one costs one more read of the prototype, which is cheaper than a call to `rawget`; a whole-container pass makes several hundred of these reads. The fields are declared `package` in the LuaCATS classes, so the language server checks them without offering them to consumers. `rawget` stays where it matters: on module scopes, whose `__index` creates Kit scopes, on the receiver of a public method, on other Kits' facades and instances, on state the bootstrap has not validated yet, and on tables the caller owns (definitions, options, alias maps, `implements` values, the `SetLimits` table).

`GetModules()` and `GetInjections()` return fresh snapshots, so a consumer mutating the returned table cannot corrupt ModuleKit's own collection.
