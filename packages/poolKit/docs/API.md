# PoolKit API

PoolKit API generation **1** provides bounded, ownership-safe reusable object pools. The implementation is pure Lua and intentionally independent from WoW-specific APIs.

## Public surface

Package facade:

| Member | Purpose |
|---|---|
| `New(options)` | Create a generic object pool. |
| `NewTablePool(options?)` | Create a shallow-clearing Lua table pool. |
| `UNBOUNDED` | Explicit sentinel for unbounded retention. |
| `DEFAULT_MAX_RETAINED` | Default retained-object limit (`128`). |

Pool handles:

| Method | Purpose |
|---|---|
| `Acquire()` | Borrow one object, reusing the newest retained object when available. |
| `Release(object)` | Reset and return an active object; discard it when retention is full/closed. |
| `Prewarm(count)` | Ensure at least `count` objects are immediately available. |
| `Trim(retainCount?)` | Discard retained objects until at most `retainCount` remain; default `0`. |
| `Clear()` | Equivalent to `Trim(0)` without closing the pool. |
| `Close()` | Terminally reject new acquisition/prewarm and discard all retained objects. |
| `IsClosed()` | Return whether the pool has been closed. |
| `GetAvailableCount()` | Return retained objects available for acquisition. |
| `GetActiveCount()` | Return objects currently borrowed from the pool. |
| `GetCreatedCount()` | Return the number of successful factory results accepted by the pool. |
| `GetDiscardedCount()` | Return the cumulative number of discard operations completed by the pool. |
| `GetMaxRetained()` | Return the numeric retention limit or `PoolKit.UNBOUNDED`. |
| `SetMaxRetained(limit)` | Change the retention limit; lowering it trims immediately. |
| `Owns(object)` | Return whether an object is currently active or retained by this pool. |
| `IsActive(object)` | Return whether an object is currently borrowed/releasing. |

## Generic pools

`PoolKit:New(options)` accepts exactly:

- `create` — required function, called as `create(pool)`; must return a table or userdata;
- `reset` — optional function, called as `reset(object, pool)` before retention/discard;
- `destroy` — optional function, called as `destroy(object, pool)` when an object leaves pool ownership;
- `maxRetained` — non-negative integer or `PoolKit.UNBOUNDED`; default `128`;
- `strict` — boolean, default `true`; retains weak history for better duplicate-release diagnostics after discard;
- `prewarm` — non-negative integer, default `0`; may not exceed a finite `maxRetained`.

Unknown fields are rejected so configuration typos cannot silently alter retention behavior.

## Bounded retention

The default is intentionally bounded:

```lua
local pool = PoolKit:New({ create = factory })
assert(pool:GetMaxRetained() == PoolKit.DEFAULT_MAX_RETAINED)
```

When a release occurs at capacity, the object is reset, removed from active ownership, and discarded instead of growing the retained set. If a `destroy` callback exists it is invoked after logical ownership has already been finalized. A destroy error is re-thrown but cannot resurrect the object into the pool.

Unbounded retention is an explicit escape hatch:

```lua
local pool = PoolKit:New({
    create = factory,
    maxRetained = PoolKit.UNBOUNDED,
})
```

Use this only when the caller deliberately owns the memory-growth policy.

A `maxRetained` value of `0` is the explicit zero-retention mode: acquired objects are still ownership-checked/reset, but every release is discarded. This is useful when a caller wants the same lifecycle contract while temporarily disabling reuse.

## Acquire / release invariants

`Acquire()` is LIFO over retained objects, which favors recently used objects and uses O(1) array operations. If none are retained, the factory is invoked. A factory result that is not a table/userdata, or that is already active/retained by the same pool, is rejected.

`Release()` accepts only objects actively borrowed from that exact pool. Foreign objects, retained objects released twice, and re-entrant release of the same object are rejected before pool counters can drift.

If `reset` raises, release is rolled back to the active state and the original error object is re-thrown. The caller may repair/retry the object or keep using it.

If reset succeeds, release is logically committed before optional destruction. Therefore a later destroy error does not make the object active again.

Lifecycle callbacks may inspect the same pool through scalar/query methods, but they may not mutate that pool (`Acquire`, `Release`, `Prewarm`, `Trim`, `Clear`, `Close`, or `SetMaxRetained`) while `create`, `reset`, or `destroy` is executing. PoolKit rejects such same-pool re-entrancy explicitly. Callbacks may freely interact with other pools. This rule keeps callback behavior expressive without making ownership transactions recursively mutable.

Callbacks are synchronous lifecycle hooks; they must not yield. PoolKit uses protected calls where rollback or best-effort cleanup requires observing callback failure.

## Strict diagnostics

With `strict = true` (the default), PoolKit stores discarded-object history in a **weak-key** table. This lets a second release of an overflow/trimmed object report “already released” while the caller still references that object, without PoolKit keeping discarded objects alive.

`strict = false` removes this weak history. Active/retained ownership checks remain mandatory; only the richer post-discard duplicate diagnostic is disabled.

## Prewarming

`Prewarm(count)` means “ensure `count` retained objects are available”, not “always create `count` more”. Repeating the same prewarm target is therefore idempotent.

For a finite pool the target may not exceed `maxRetained`. Factory failure may leave successfully created earlier prewarm objects retained; all counters remain internally consistent. Constructor-level `prewarm` is different: if construction fails, already-prewarmed objects are dropped best-effort before the original construction error is re-thrown.

## Trimming and clearing

`Trim(n)` discards retained objects until at most `n` remain. `Clear()` trims to zero. Active borrowed objects are unaffected.

Bulk discard is best-effort: if `destroy` fails for one object, PoolKit continues discarding the rest and re-throws the first error afterwards. Every affected object has already left pool ownership.

## Closing

`Close()` is terminal for new acquisition and prewarming. It immediately clears all retained objects. Already-borrowed objects may still be released after close; they are reset and then discarded instead of retained. This lets owners perform deterministic shutdown without invalidating handles that are temporarily still checked out.

Repeated `Close()` returns `false`; the first close returns `true` unless a destroy callback error is re-thrown after cleanup.

## Table pools

```lua
local tables = PoolKit:NewTablePool({ maxRetained = 64 })
local value = tables:Acquire()
value.name = "temporary"
tables:Release(value)

local reused = tables:Acquire()
assert(next(reused) == nil)
```

The built-in reset is **shallow**: all direct keys are removed, while referenced nested objects are not recursively modified. Table metatables are preserved because clearing keys does not replace the table.

Because the built-in table create/reset callbacks are framework-owned and cannot execute arbitrary consumer code, `NewTablePool` uses a trusted internal fast path that avoids the protected-callback/re-entrancy machinery required by generic pools.

## Embedded copies

PoolKit is registered as `poolKit`, API generation `1`, through Registry API 2. The facade, `Pool` prototype, metatable, and `UNBOUNDED` sentinel live in Registry-owned shared state, so compatible future revisions can preserve existing pool identity while replacing methods in place.
