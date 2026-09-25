# ModuleKit Internals

This document explains ModuleKit's implementation invariants for maintainers. It is not a public API contract; [`API.md`](API.md) is authoritative for consumer-visible behavior.

## Why one runtime source file?

ModuleKit keeps its bootstrap and implementation in `src/ModuleKit.lua`, like every other MoltenCodes package. WoW clients load addon files from a `.toc` list and offer no general-purpose module loader, so splitting the runtime would mean either inventing a loader or making consumers list several files in a required order. The file is organised into explicit sections instead, and its header block lists them.

## Section map

| Section | Responsibility |
|---|---|
| Dependencies | Reads `MoltenCodes.Registry`, validates Registry API 2 and the LifecycleKit API 1 facade. Nothing below runs if this fails. |
| Bootstrap | Reconciles embedded revisions, decides whether this copy owns the package, and installs or adopts the shared `Addon` / `Module` prototypes and `_state`. |
| Validation helpers | Argument checks, definition-mutability rules (`created` state only), post-shutdown rejection, and the late-module ordering guard. |
| Graph | Edge construction from the four constraint kinds, cycle reporting, the topological sort, and the graph cache with its invalidation. |
| Optional packages | The silent `Registry:Find` lookup (with `Get` as the fallback on an older Registry) that the `implements` schema form and the module scopes share. |
| Dependency injection | Provider registration, `implements` contracts, the four provider scopes, cycle-checked resolution, and injection-table assembly. |
| Module scopes | The per-module scope object, its lazy fields resolved through `findOptionalPackage`, and closing them. |
| Lifecycle operations | Single-module transitions, the two dependency policies, intent versus fact and recovery of blocked dependents, halted addons, whole-container passes, deferred catch-up, the two halt passes, shared runtime dispatch (`invokeDispatch`) and the on-demand `OnDependencyHalted` subscription. |
| Module public API | The functions installed on the shared `Module` prototype. |
| Addon public API | The functions installed on the shared `Addon` prototype. |
| Addon creation | Container identity, the dispatched-phase set, and LifecycleKit subscriptions, including the addon's own halted notice. |
| Package-wide limits | `SetLimits` / `GetLimits` and the call-time coupling to LifecycleKit's `maxDependencies`. |
| Commit | Publishes the public surface, installs shared runtime dispatch, and runs the in-place upgrade. |

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
    ├── dispatch     -- initializeAll / enableAll / shutdown / halted / dependencyHalted
    ├── scopeMetatable -- shared by every module scope; each revision installs its __index
    ├── unbounded    -- the UNBOUNDED sentinel, created once so every revision shares its identity
    └── limits       -- { maxRequiredAddons }, written in place by SetLimits
```

`unbounded` and `limits` were added by revision 14. They are additive, so the
schema stays 1: an upgrade from an earlier revision creates them with the
default that revision enforced as a constant, and refuses a `limits` table it
cannot trust. `SetLimits` asks `LifecycleKit:GetLimits()` at call time, not at
load, because LifecycleKit can be upgraded in place and its limit changed after
ModuleKit loaded.

Existing containers and modules therefore survive an in-place upgrade: their metatables point at the shared prototypes, and the newer copy replaces methods on those prototypes rather than replacing objects.

## Module scopes

Every module carries one scope table (`_scope`, published as `scope`) whose
metatable is `_state.scopeMetatable`. Keeping that metatable in shared state and
re-installing `__index` at every commit is what moves scopes created by an older
copy onto the newer lookup, exactly as the prototypes do for methods.

`__index` runs only for a missing field. It checks `_scopeOpen`, resolves the
Kit through `Registry:Find` (read from the facade on every call, because an
embedded Registry upgrade replaces the method), creates the scope and stores
the result with `rawset`, so every later read is a plain table hit. Every field
but `Messages` calls the Kit's `CreateScope()`. `Messages` calls
`SignalKit:ForAddon(addonName)` and then the bus's `CreateScope()`: a SignalKit
without `Bus` and `ForAddon` predates buses, `ForAddon` may answer
`nil, "full"`, and a closed bus raises from `CreateScope` without offering a
public query to ask first, so that one call runs under `pcall`. A missing Kit,
one without `CreateScope`, or a bus that cannot be had yields `nil` and stores
nothing, so a later read tries again.

`_scopeOpen` is set immediately before `OnEnable` is invoked and cleared by
`closeModuleScope`, which runs after a successful `OnDisable`, after a failed
`OnEnable`, and at shutdown or halt whatever `OnDisable` did; a module that
never enabled has none, which reads as closed. A scope whose only key is
`_module` holds nothing to close, and `closeModuleScope` returns after one or
two `next` calls in that usual case. Otherwise closing walks the
fields in a fixed, alphabetical order (comm, commands, events, hooks, jobs, messages, timers;
they are independent, so any fixed order would do), closes each one even when an earlier
`Close` raised, and hands back the first failure; `disableOne` re-raises it only
after the module has become `disabled`, so a scope failure never leaves a module
half-transitioned.

## Intent versus fact

Two per-module fields sit beside `_state`:

- `_wantedEnabled` — intent. Starts `true`. Written only by the public
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

`ensureModuleRuntimeFields` backfills `_wantedEnabled`, marks the scope of an
enabled module from before revision 6 open, and creates a missing scope, on
modules an older revision created; it leaves present fields alone, so an
upgrade carries intent and blocking across unchanged. Absent optional fields
need no backfill, because they read as empty (see *Allocation policy*).

## Halted addons

`_requiredAddons` holds a module's `requiresAddons`, deduplicated, in
declaration order. A module that declares none has no such field;
`moduleRequiredAddons` reads it as the shared empty array `NO_REQUIRED_ADDONS`,
which is never written and which modules of revisions 8 to 18 may still carry.

`haltBlocker(module)` is the single question every enable path asks: `"halted"`
when the container's own lifecycle reports `IsHalted()`, else the first
required addon whose `LifecycleKit:ForAddon(name):GetHaltReason()` is set, else
`nil`. It is asked, not cached, because halted is terminal and LifecycleKit is
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

`addonCreateModule` also calls `DependsOn` on the container's lifecycle for
every required addon, before publishing, so a `"full"` refusal leaves the
container without the module.

Two notices drive the transitions, through shared dispatch like the phases.
`halted` is subscribed when the container is created. `dependencyHalted` is
subscribed by `subscribeToDependencyHalts` only once a module declares
`requiresAddons` (from `declareRequiredAddons`, before the first `DependsOn`,
which is when LifecycleKit could first announce a halt that concerns it), or
by an upgrade for a carried-over container that already has such a module.
Its handler acts only on modules that require the halted addon, so a
container without one would receive every notice for nothing, at the cost of
a LifecycleKit handle and a SignalKit listener for the session:

- `halted` (`OnHalted`) runs `haltAllInternal`: it marks every wanted module
  `"halted"` and runs `runDisableAllPass` in terminal mode, because
  LifecycleKit never delivers `shutdown` to a halted addon. It does not set
  `_shutdown`, so the container stays usable for inspection.
- `dependencyHalted` (`OnDependencyHalted`) runs `dependencyHaltedInternal`:
  newest module first, every module that requires the halted addon is taken
  down by `blockForHaltedAddon`, which disables enabled hard dependents first
  (recursively, whatever the policy). The module is marked blocked by the
  halted addon, and each dependent by its own direct dependency: a dependent
  of the module names the module, and a dependent of that dependent names the
  dependent, not the module that required the halted addon.

Both subscriptions replay synchronously, and the replay hazard applies.
`OnHalted` replays only for an addon that already halted: a new container has
no modules, so the replay just records it; during an upgrade the halt is
recorded in `_dispatched.halted` without running, and the enable paths refuse
every module anyway. `OnDependencyHalted` replays every halted declared
dependency; its listener ignores deliveries while the subscription call is
still running, because the module being created is not published yet (it is
blocked by `haltBlocker` once it is) and an upgrade must not run `OnDisable`
from package bootstrap. `disconnectAddonSubscriptions` releases
both handles with the phase handles.

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

The cache is container state that no older revision knows, so an in-place upgrade drops it (`ensureContainerRuntimeFields` calls `invalidateGraph`) and the new copy rebuilds it on first use.

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
reads the `issecretvalue` captured at load and answers `false` on a host
without it, and a secret is refused at the caller's line before the first
comparison or key use. A secret key of a dense list is refused with the list's
density message, since it cannot be an index. `Resolve` decides ownership of
`requestingModule` by identity with the module the container keeps under its
`_name`, so it never compares a field read from the caller's table. Two reads
do not refuse: `scopeIndex` answers `nil` for a secret key, and `isSchemaLike`
answers `false` when `getmetatable` returns a secret. `SetLimits` and
`GetLimits` check the receiver's type before comparing it with the facade.

## Hooks run under `pcall`

`invokeHook` calls every user hook through `pcall`. That is what turns a hook failure into a recorded module failure instead of an aborted pass — and it is also why a hook cannot yield. In Lua 5.1 a coroutine cannot suspend across a C function, and `pcall` is one; the attempt fails with "attempt to yield across metamethod/C-call boundary", which ModuleKit then records as an ordinary hook failure. `docs/API.md` states this as a consumer-visible rule.

## The lifecycle replay hazard

LifecycleKit replays a phase it has already reached to every new subscriber. That is exactly what a newly created container needs: it catches up to `loaded` and `ready` without racing host events.

It is also a hazard. An in-place upgrade re-installs subscriptions on containers that already exist, and subscribing to an already-reached phase would replay it:

- module hooks would run out of package bootstrap, where the addon has no way to handle their failure;
- the replayed `ready` phase calls `EnableAll`, which would re-enable a module the addon had deliberately disabled.

Two things prevent it.

**The dispatched-phase set.** Every container carries `_dispatched`, recorded by the subscription callback *before* it dispatches — the phase has happened even if the dispatch raises. `installAddonSubscriptions` subscribes only to phases that are not in the set. A container created by an earlier revision has no set; `ensureContainerRuntimeFields` rebuilds it from LifecycleKit, because every revision subscribed to all three phases at creation, so for such a container "phase reached" and "phase already dispatched" mean the same thing.

**The upgrade probe.** During migration the lifecycle is also asked directly, and an already-reached phase is never subscribed to even if the set were wrong. This is what makes "an upgrade can never run a module hook out of package bootstrap" a property of the code rather than of the bookkeeping.

Phases that have *not* been reached are still subscribed to during an upgrade, so a container that has not shut down yet keeps its cleanup.

**A replay is synchronous, inside `subscribe()`.** The callback runs before the handle exists, so anything the install loop read before that call may be stale by the time it returns. A hook running in the replay can reach container shutdown, and the loop must not then keep going: it re-tests `_shutdown` after every subscription, disconnects the handle the shutdown happened inside rather than storing it, and abandons the phases behind it. It also re-reads `_subscriptions` for each phase rather than holding the table it captured, so a handle can never be filed in a table the container has since replaced — where nothing would ever disconnect it.

## Re-entrant module creation

A hook may create a module while a whole-container pass is walking the graph. Catching that module up immediately would happen outside the running pass's blocking set, so it could be activated even though the pass had already decided that one of its hard dependencies failed.

`_passDepth` counts the whole-container passes a container is inside. While it is non-zero, definition-table catch-up is queued on `_pendingCatchUp` and flushed once the outermost pass finishes — with the same effect as creating the module immediately after the pass returned. `_flushingCatchUp` keeps a nested pass that ends during the flush from starting a second one; its modules stay on the queue for the running loop.

The queue is drained with an index cursor and cleared once, not by removing the head each time: shifting every remaining entry down a slot per module made a flush quadratic in the number of modules waiting. Entries appended while the loop runs are picked up by the same pass, so the order is the one creation established.

`module:Activate()` is not deferred. It is an explicit request from addon code, not implicit catch-up, so it keeps its synchronous contract.

Pass bodies report their first error by *returning* it rather than raising, so `runContainerPass` always restores the depth counter and always flushes the queue, whichever way the pass ends.

## Provider resolution

Providers are container-local; two containers never share registration or caches.

| Scope | Cached by |
|---|---|
| `value` | nothing to cache |
| `singleton` | the container |
| `module` | the requesting module |
| `transient` | not cached |

Cycle detection tracks `(provider name, requesting module)` rather than provider name alone. That is what lets the same module-scoped provider legitimately resolve for a *different* requesting module while its factory is running, without reporting a false cycle. The resolution stack is a container field, so a nested resolution sees the frames above it.

Injection aliases are resolved in sorted alias order, so factories with side effects run in the same order on every Lua implementation.

**Implements contracts.** A provider record carries `implements`, `nil` or the record `compileImplements` built at registration: `{ names = string[] }` for the list form (a copy of the caller's list) or `{ schema = <sealed SchemaKit schema> }` for the schema form. `resolveProvider` runs `checkImplements` on a factory's result after the `nil` check and before caching, so a refused value is produced again next time; `ProvideValue` and `CreateModule` run it at registration. The list check is one `value[name]` lookup per declared name and allocates nothing when the value conforms; the schema check is SchemaKit's `Check`, which also allocates nothing for a valid value. The contract lives on the provider record rather than in `_state`, so revision 15 added nothing to the state schema: a record an older revision registered has no `implements` and resolves unchecked, and a record this revision registered keeps its contract under a newer copy. SchemaKit is looked up through `findOptionalPackage` at registration only; the sealed schema's `Check` is a method on SchemaKit's shared prototype, so an in-place SchemaKit upgrade is observed.

## Allocation policy

The per-module steady state is one module table, its resolved injection table and its scope table. Everything a module may not need is absent until something writes it, and reads as empty or `false`:

| Field | Created by | Absent reads as |
|---|---|---|
| `_hardDependencies`, `_optionalDependencies`, `_before`, `_after` | the first constraint of that kind | the shared `EMPTY_NAME_SET` (`moduleNameSet`) |
| `_injectSpec` | the first `Inject` | the shared `EMPTY_NAME_SET` |
| `_requiredAddons` | the first `requiresAddons` entry | the shared `NO_REQUIRED_ADDONS` (`moduleRequiredAddons`) |
| `_lastError`, `_hasLastError`, `_blockedBy`, `_enableBlockedBy` | a recorded failure or block | no failure, no block |
| `_scopeOpen` | the first enable | closed |

The shared tables are never written; a writer gives the module its own table first. `clearFailure` and the other clears remove a field only when it is set, because Lua 5.1 stores a key even when `nil` is assigned to it while absent. The module constructor lists the fields almost every module receives next (its scope, its three hooks, `_injections`, `_scopeOpen`) as `nil` entries: Lua 5.1 sizes a table's hash part from its constructor, so the module is built with the sixteen slots it keeps instead of being rehashed into them. Before revision 19 every module carried five empty tables and a thirty-two-slot hash part; the `addonModules` host benchmark's ten-module addon went from 28.7 KB to 16.8 KB retained, container and LifecycleKit instance included.

A provider that declares `implements` keeps one contract record and, for the list form, one copy of its names; a module's `implements` is checked at creation and keeps nothing. The scope's Kit scopes are created only when read, so a module that never uses them allocates nothing more; `GetEnableState()` allocates its snapshot. Building the graph allocates the adjacency and indegree maps, the ready set, the result array and the dependent lists, once per change of the graph (see *Graph cache*). With the graph cached, a whole-container pass, `ValidateGraph` and a targeted `Enable` or `Disable` allocate nothing when every hook succeeds: the passes create their failed-module set on the first failure, and the `automatic` policy creates its recursion guard only for a module with hard dependencies. `Allocation_spec` pins these. All of these are lifecycle-scale operations rather than per-frame work.

## Field access

ModuleKit reads and writes its own fields on containers and modules with plain indexing on the lifecycle paths (`module._state`, `addon._moduleOrder`). Their metatables only point `__index` at the method prototypes, so a present field is a plain table read and an absent one costs one more read of the prototype, which is cheaper than a call to `rawget`; a whole-container pass makes several hundred of these reads. The fields are declared `package` in the LuaCATS classes, so the language server checks them without offering them to consumers. `rawget` stays where it matters: on module scopes, whose `__index` creates Kit scopes, and on tables the caller owns (definitions, options, alias maps, `implements` values).

`GetModules()` and `GetInjections()` return fresh snapshots, so a consumer mutating the returned table cannot corrupt ModuleKit's own collection.
