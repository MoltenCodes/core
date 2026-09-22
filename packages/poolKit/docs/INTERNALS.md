# PoolKit Internals

This document describes implementation invariants for maintainers. It is not an additional public API.

## Hot-path data structures

Each pool uses:

- a dense LIFO `_available` array plus `_availableCount`;
- an `_active` identity map with small numeric state markers;
- a `_retained` identity set for duplicate-release/ownership checks;
- an optional weak-key `_released` set when strict diagnostics are enabled.

`Acquire` and the normal retained `Release` path perform O(1) table operations and create no framework-owned temporary tables. User callbacks may allocate independently.

`Acquire` also compares `_maxActiveWarning` against the new active count. The field is `false` when leak warnings are not configured, so the default path is one `rawget` and one comparison, and the message-building work lives in a separate function that the hot path never enters.

`_active` is intentionally the one unbounded structure in a pool. It must hold strong references for ownership, duplicate-release, and foreign-object checks to stay correct, and PoolKit cannot reclaim an object the caller never returns. The bound therefore belongs to the caller; `GetActiveCount` and `maxActiveWarning` make it observable.

## Why discarded history is weak

Keeping a permanent “ever owned” set would defeat pooling by retaining every object ever created. Strict post-discard duplicate diagnostics instead use `__mode = "k"`, allowing garbage collection as soon as external references disappear.

## Release transaction

Release transitions the active marker from `ACTIVE` to `RELEASING` before invoking reset. This prevents a reset callback from recursively releasing the same object.

If reset fails, the marker returns to `ACTIVE` and counters do not change. If reset succeeds, active ownership is removed before retention/destruction. Destruction is therefore post-commit cleanup.

## Error levels

Every argument validator takes an explicit `level`, which is the value `error` needs *inside the function that receives it*; each further hop towards `error` adds one. Nothing relies on a default, so a method that gains or loses an internal hop cannot silently start reporting at the wrong frame.

Level `0` is reserved for "no position information" and is propagated unchanged by `nestedLevel`. The constructor-time `prewarm` path uses it: that failure is caught by a `pcall` and re-raised verbatim, so any position computed across the boundary would name a PoolKit frame rather than the caller.

## Bulk cleanup

Trim/Clear/Close remove every targeted object from retained structures even if one destroy callback fails. The first arbitrary Lua error object is captured in a record table (so `nil` and `false` remain representable) and is re-thrown after best-effort cleanup.

## Embedded revision model

PoolKit objects share a Registry-owned metatable whose `__index` points at the shared `Pool` prototype. Compatible revisions replace methods on that shared prototype rather than replacing existing pool objects. Older embedded copies seeing a newer accepted revision validate only the stable public surface and do not reinterpret future private state schema.

## Callback re-entrancy

A `_callbackDepth` counter, paired with a `_callbackPhase` name for the rejection message, protects ownership transactions from same-pool mutation inside `create`, `reset`, and `destroy`. Query methods remain valid, and callbacks may mutate other pools. Bulk cleanup detaches its complete snapshot before invoking destroy callbacks so query methods observe committed structural state.

The guard is a counter rather than a flag, and the previous phase name is restored rather than cleared, so a nested invocation cannot release a guard it did not take. Both halves are also restored when the callback returns by raising, which is what keeps a failed `reset` from locking its pool permanently.

Note for maintainers: with the current public surface, same-pool nesting is not reachable. Every method that can invoke a lifecycle callback passes through `ensureMutationAllowed` first, so the guard refuses the re-entry before a second invocation can begin. The counter exists so that the invariant does not quietly depend on that: any future path that invokes a callback without the mutation check — or any callback-invoking method added later — would otherwise hand the outer callback a pool that looks unguarded. Specs cover the reachable case (nested lifecycle callbacks across two pools) and guard restoration after a raise.

## Table-pool fast path

`NewTablePool` marks its built-in create/reset lifecycle as trusted. Those callbacks use only framework-owned `{}` allocation and `next/rawset` shallow clearing, so the hot path skips generic protected-callback and callback-phase bookkeeping. Generic pools never receive this optimization because user callbacks require rollback and re-entrancy enforcement.
