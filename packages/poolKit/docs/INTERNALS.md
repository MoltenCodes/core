# PoolKit Internals

This document describes implementation invariants for maintainers. It is not an additional public API.

## Hot-path data structures

Each pool uses:

- a dense LIFO `_available` array plus `_availableCount`;
- an `_active` identity map with small numeric state markers;
- a `_retained` identity set for duplicate-release/ownership checks;
- an optional weak-key `_released` set when strict diagnostics are enabled.

`Acquire` and the normal retained `Release` path perform O(1) table operations and create no framework-owned temporary tables. User callbacks may allocate independently.

## Why discarded history is weak

Keeping a permanent “ever owned” set would defeat pooling by retaining every object ever created. Strict post-discard duplicate diagnostics instead use `__mode = "k"`, allowing garbage collection as soon as external references disappear.

## Release transaction

Release transitions the active marker from `ACTIVE` to `RELEASING` before invoking reset. This prevents a reset callback from recursively releasing the same object.

If reset fails, the marker returns to `ACTIVE` and counters do not change. If reset succeeds, active ownership is removed before retention/destruction. Destruction is therefore post-commit cleanup.

## Bulk cleanup

Trim/Clear/Close remove every targeted object from retained structures even if one destroy callback fails. The first arbitrary Lua error object is captured in a record table (so `nil` and `false` remain representable) and is re-thrown after best-effort cleanup.

## Embedded revision model

PoolKit objects share a Registry-owned metatable whose `__index` points at the shared `Pool` prototype. Compatible revisions replace methods on that shared prototype rather than replacing existing pool objects. Older embedded copies seeing a newer accepted revision validate only the stable public surface and do not reinterpret future private state schema.

## Callback re-entrancy

A small `_callbackPhase` marker protects ownership transactions from same-pool mutation inside `create`, `reset`, and `destroy`. Query methods remain valid, and callbacks may mutate other pools. Bulk cleanup detaches its complete snapshot before invoking destroy callbacks so query methods observe committed structural state.

## Table-pool fast path

`NewTablePool` marks its built-in create/reset lifecycle as trusted. Those callbacks use only framework-owned `{}` allocation and `next/rawset` shallow clearing, so the hot path skips generic protected-callback and callback-phase bookkeeping. Generic pools never receive this optimization because user callbacks require rollback and re-entrancy enforcement.
