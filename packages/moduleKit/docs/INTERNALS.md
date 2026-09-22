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
| Lifecycle operations | Single-module transitions, the two dependency policies, whole-container passes, and deferred catch-up. |
| Module public API | The functions installed on the shared `Module` prototype. |
| Addon public API | The functions installed on the shared `Addon` prototype. |
| Addon creation | Container identity, the dispatched-phase set, and LifecycleKit subscriptions. |
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
    └── dispatch     -- initializeAll / enableAll / shutdown
```

Existing containers and modules therefore survive an in-place upgrade: their metatables point at the shared prototypes, and the newer copy replaces methods on those prototypes rather than replacing objects.

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

## Re-entrant module creation

A hook may create a module while a whole-container pass is walking the graph. Catching that module up immediately would happen outside the running pass's blocking set, so it could be activated even though the pass had already decided that one of its hard dependencies failed.

`_passDepth` counts the whole-container passes a container is inside. While it is non-zero, definition-table catch-up is queued on `_pendingCatchUp` and flushed once the outermost pass finishes — with the same effect as creating the module immediately after the pass returned. `_flushingCatchUp` keeps a nested pass that ends during the flush from starting a second one; its modules stay on the queue for the running loop.

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

The per-module steady state is one module table, its four constraint sets, its injection specification and its resolved injection table. Graph operations allocate per call: the adjacency and indegree maps, the ready set, and the result array. That cost is paid by `ValidateGraph`, `GetActivationOrder` and the whole-container passes, which are lifecycle-scale operations rather than per-frame work.

`GetModules()` and `GetInjections()` return fresh snapshots, so a consumer mutating the returned table cannot corrupt ModuleKit's own collection.
