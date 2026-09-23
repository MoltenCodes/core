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
| Graph | Edge construction from the four constraint kinds, cycle reporting, and the topological sort. |
| Dependency injection | Provider registration, the four provider scopes, cycle-checked resolution, and injection-table assembly. |
| Module scopes | The per-module scope object, its lazy fields resolved through `Registry:Find`, and closing them. |
| Lifecycle operations | Single-module transitions, the two dependency policies, intent versus fact and recovery of blocked dependents, halted addons, whole-container passes, deferred catch-up, and the two halt passes. |
| Module public API | The functions installed on the shared `Module` prototype. |
| Addon public API | The functions installed on the shared `Addon` prototype. |
| Addon creation | Container identity, the dispatched-phase set, and LifecycleKit subscriptions, including the halted notices. |
| Commit | Publishes the public surface, installs shared runtime dispatch, and runs the in-place upgrade. |

## Shared embedded state

Registry owns one implementation table for `(moduleKit, API 1)`. ModuleKit stores everything a compatible upgrade must preserve on that table:

```text
ModuleKit facade
├── Addon            -- shared method prototype
├── Module           -- shared method prototype
└── _state
    ├── schema
    ├── runtimeRevision
    ├── addons[name] -- containers
    ├── dispatch     -- initializeAll / enableAll / shutdown / halted / dependencyHalted
    └── scopeMetatable -- shared by every module scope; each revision installs its __index
```

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
`OnEnable`, and at shutdown or halt whatever `OnDisable` did. Closing walks the
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
  naming the module whose `Disable` caused the cascade, so a chain taken down by
  one `Disable` comes back, in graph order, when that module is enabled again.

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

`ensureModuleRuntimeFields` backfills these fields, and `_requiredAddons`, on
modules an older revision created and leaves present ones alone, so an upgrade
carries intent and blocking across unchanged.

## Halted addons

`_requiredAddons` holds a module's `requiresAddons`, deduplicated, in
declaration order. Modules that declare none share one empty array that is
never written (`NO_REQUIRED_ADDONS`), so the field costs nothing for them.

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

Two notices drive the transitions, through shared dispatch like the phases:

- `halted` (`OnHalted`) runs `haltAllInternal`: it marks every wanted module
  `"halted"` and runs `runDisableAllPass` in terminal mode, because
  LifecycleKit never delivers `shutdown` to a halted addon. It does not set
  `_shutdown`, so the container stays usable for inspection.
- `dependencyHalted` (`OnDependencyHalted`) runs `dependencyHaltedInternal`:
  newest module first, every module that requires the halted addon is taken
  down by `blockForHaltedAddon`, which disables enabled hard dependents first
  (recursively, whatever the policy) and marks them blocked by the module.

Both subscriptions replay synchronously, and the replay hazard applies.
`OnHalted` replays only for an addon that already halted: a new container has
no modules, so the replay just records it; during an upgrade the halt is
recorded in `_dispatched.halted` without running, and the enable paths refuse
every module anyway. `OnDependencyHalted` replays every halted declared
dependency; its listener ignores deliveries while the subscription call is
still running, because a new container has no modules and an upgrade must not
run `OnDisable` from package bootstrap. `disconnectAddonSubscriptions` releases
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

The ready set is kept sorted by *descending* creation order and consumed from its end:

- emitting a module is `ready[#ready] = nil`, which is O(1);
- a module that becomes ready is placed by binary search, which is O(log n) comparisons plus one array shift.

The previous implementation removed from the front of an ascending array and re-sorted the whole ready set after every insertion. Both are eliminated; the emitted order is unchanged, and `Graph_spec` pins it on a twelve-module fixture as well as on the small ones.

Successors of an emitted module are visited in ascending creation order, so `pairs` iteration over the adjacency set cannot leak into the result.

When the sort cannot emit every module, `findCycle` walks the graph again to produce a readable `A -> B -> C -> A` diagnostic. That second walk only runs on the failure path.

`buildEnabledHardOrder` is the degraded variant used by terminal shutdown: it orders only enabled modules, using only their hard-dependency edges, so cleanup has a safe order even when an inactive late definition has made the full graph invalid.

## Failure model

A module never enters a permanent failed state. A failure records three things and leaves the module at its previous stable state:

- `_lastError` — the original Lua error object, which may itself be `nil` or `false`;
- `_hasLastError` — the flag that distinguishes "no error" from "an error object of `nil`";
- `_blockedBy` — the related module name, when the operation was refused rather than attempted.

Because an error object may be `nil` or `false`, errors are carried between layers inside a record table (`{ value = ... }`) and re-raised with `error(value, 0)`. `captureFirstError` keeps the first such record; `raiseCaptured` re-raises it unchanged.

A whole-container pass therefore behaves like this:

1. build the graph, which fails loudly if the declarations are invalid;
2. walk it in order, attempting each module whose hard dependencies are satisfied;
3. record a module as blocked, without attempting it, when a hard dependency failed or is not in the required state;
4. after the walk, re-raise the first real callback or provider error.

Terminal shutdown differs deliberately: it is best-effort cleanup, so it attempts every enabled module even after earlier failures, and it keeps going when the full graph is invalid.

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

## Allocation policy

The per-module steady state is one module table, its four constraint sets, its injection specification, its resolved injection table and its scope table, plus a `requiresAddons` array only for a module that declares one. The scope's Kit scopes are created only when read, so a module that never uses them allocates nothing more; `GetEnableState()` allocates its snapshot. Graph operations allocate per call: the adjacency and indegree maps, the ready set, and the result array. That cost is paid by `ValidateGraph`, `GetActivationOrder`, the whole-container passes, and a targeted `Enable` or `Activate` while some module is blocked by a dependency (recovery walks the graph); a targeted `Enable` with nothing blocked pays only a linear scan. All of these are lifecycle-scale operations rather than per-frame work.

`GetModules()` and `GetInjections()` return fresh snapshots, so a consumer mutating the returned table cannot corrupt ModuleKit's own collection.
