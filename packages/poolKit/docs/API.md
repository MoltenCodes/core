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
| `Acquire(onAvailable?)` | Borrow one object, reusing the newest retained object when available; at capacity return `nil` and a reason. |
| `Release(object)` | Release children, reset and return an active object; discard it when retention is full, the pool is closed, or its generation is stale. Completes a parked release early. |
| `Prewarm(count)` | Ensure at least `count` objects are immediately available. |
| `Trim(retainCount?)` | Discard retained objects until at most `retainCount` remain; default `0`. |
| `Clear()` | Equivalent to `Trim(0)` without closing the pool. |
| `Close()` | Terminally reject new acquisition/prewarm, fail waiting requests, complete parked releases and discard all retained objects. |
| `IsClosed()` | Return whether the pool has been closed. |
| `GetAvailableCount()` | Return retained objects available for acquisition. |
| `GetActiveCount()` | Return objects currently borrowed from the pool. |
| `GetCreatedCount()` | Return the number of successful factory results accepted by the pool. |
| `GetDiscardedCount()` | Return the cumulative number of discard operations completed by the pool. |
| `GetMaxRetained()` | Return the numeric retention limit or `PoolKit.UNBOUNDED`. |
| `SetMaxRetained(limit)` | Change the retention limit; lowering it trims immediately. |
| `Owns(object)` | Return whether an object is currently borrowed from, parked in or retained by this pool. |
| `IsActive(object)` | Return whether an object is currently borrowed/releasing; a parked object is not. |
| `GetGeneration()` | Return the generation stamped on newly built objects. |
| `SetGeneration(n)` | Raise the generation; destroy retained objects of older generations; return how many. |
| `GetWaitingCount()` | Return the number of queued `Acquire(onAvailable)` requests. |
| `CancelWaiting(callback)` | Withdraw the oldest queued request made with `callback`. |
| `GetParkedCount()` | Return the number of objects waiting for an animation before release. |
| `GetMaxCreated()` | Return the creation cap, or `false` when the pool has none. |
| `SetMaxCreated(n)` | Raise the creation cap; never lowers it. |
| `AttachChild(parent, child, childPool)` | Release `child` (from `childPool`) whenever `parent` is released. |
| `DetachChild(child)` | Undo `AttachChild` without releasing anything. |
| `ReleaseAfter(object, animationGroup)` | Release `object` when `animationGroup` finishes playing. |

## Method reference

Every method validates its receiver first and raises
`<method> must be called on a PoolKit pool` at the caller's line when it is
called on anything else; `<method>` is the qualified name, for example
`PoolKit.Pool:Acquire`. Methods marked *mutating* also raise
`<method> cannot mutate this pool during its <phase> callback` when called from
inside that pool's own `create`, `reset` or `destroy` (see
[Acquire / release invariants](#acquire--release-invariants)). Unless a row says
otherwise, argument errors are reported at the caller's line and errors raised by
a consumer callback are re-raised unchanged. "Allocates nothing" means PoolKit
creates no table or string of its own; consumer callbacks may allocate.

### `PoolKit:New(options)` and `PoolKit:NewTablePool(options?)`

Return a new pool. Options are described in [Generic pools](#generic-pools).
Cost: O(`maxWaiting` + `prewarm`); the pool, its bookkeeping tables and the
waiting ring are allocated here, once.

Errors of `New`; `NewTablePool` raises the ones for the options it accepts, named
`PoolKit:NewTablePool` instead:

- `PoolKit:New options must be a table`
- `PoolKit:New create must be a function`, `PoolKit:New reset must be a function`, `PoolKit:New destroy must be a function`
- `PoolKit:New options contains unknown field "<name>"`
- `PoolKit:New maxRetained must be a non-negative integer or PoolKit.UNBOUNDED`
- `PoolKit:New strict must be a boolean`, `PoolKit:New strictReset must be a boolean`
- `PoolKit:New strictReset requires a reset callback`
- `PoolKit:New prewarm must be a non-negative integer`, `PoolKit:New maxActiveWarning must be a non-negative integer`, `PoolKit:New maxWaiting must be a non-negative integer`
- `PoolKit:New generation must be a positive integer`, `PoolKit:New maxCreated must be a positive integer`, `PoolKit:New maxActive must be a positive integer`
- `PoolKit:New prewarm cannot exceed maxRetained`, `PoolKit:New prewarm cannot exceed maxCreated`
- `PoolKit:New maxWaiting requires maxCreated or maxActive`
- a failure of the constructor-time prewarm, re-raised verbatim after the
  objects already built are dropped.

### `pool:Acquire(onAvailable?)` — mutating

Returns `object` or `nil, reason` (`"exhausted"`, `"waiting"`, `"queueFull"`;
see [When the pool is at capacity](#when-the-pool-is-at-capacity)). Cost: O(1)
and allocates nothing when an object is retained; otherwise one factory call.
When requests are waiting, they are served first.

Errors: `PoolKit.Pool:Acquire cannot use a closed pool`,
`PoolKit.Pool:Acquire onAvailable must be a function`,
`PoolKit.Pool:Acquire factory result must be a table or userdata`,
`PoolKit.Pool:Acquire factory returned an object already owned by this pool`,
and a raising `create`, unchanged.

### `pool:Release(object)` — mutating

Returns `true`. Cost: O(1) and allocates nothing, plus one release per attached
child and the service of any waiting requests.

Errors: `PoolKit.Pool:Release object must be a table or userdata`,
`PoolKit.Pool:Release object was not acquired from this pool`,
`PoolKit.Pool:Release object has already been released`,
`PoolKit.Pool:Release release is already in progress for this object` (the
object's own release is running, for example when a child's `reset` releases
its parent), and a raising `reset` or `destroy`, unchanged, with the first
error winning (see [Cascading release](#cascading-release)).

### `pool:Prewarm(count)` — mutating

Returns the number of objects built. Cost: one factory call per object built.

Errors: `PoolKit.Pool:Prewarm count must be a non-negative integer`,
`PoolKit.Pool:Prewarm cannot use a closed pool`,
`PoolKit.Pool:Prewarm target cannot exceed maxRetained`,
`PoolKit.Pool:Prewarm target cannot exceed maxCreated`, the two factory-result
errors with `PoolKit.Pool:Prewarm` in place of `PoolKit.Pool:Acquire`, and a
raising `create`, unchanged.

### `pool:Trim(retainCount?)`, `pool:Clear()` — mutating

Return the number of objects removed. Cost: O(removed), one scratch list when
anything is removed. `Trim` raises
`PoolKit.Pool:Trim retainCount must be a non-negative integer`; both re-raise
the first `destroy` failure after the whole trim.

### `pool:Close()` — mutating

Returns `true`, or `false` when the pool was already closed. Cost:
O(waiting + parked + retained). Re-raises the first failure of a parked release
or a `destroy` after finishing the close; failures of waiting callbacks are
reported through the host error handler.

### `pool:SetMaxRetained(maxRetained)` — mutating

Returns the pool. Cost: O(removed) when the bound shrinks. Errors:
`PoolKit.Pool:SetMaxRetained maxRetained must be a non-negative integer or PoolKit.UNBOUNDED`,
and the first `destroy` failure of the resulting trim.

### `pool:SetGeneration(generation)` — mutating

Returns the number of retained objects destroyed. Cost: O(retained), one scratch
list per raise, and the weak stamp table on the first raise. Errors:
`PoolKit.Pool:SetGeneration generation must be a positive integer`,
`PoolKit.Pool:SetGeneration cannot lower the generation from <current> to <requested>`,
and the first `destroy` failure.

### `pool:SetMaxCreated(maxCreated)` — mutating

Returns the pool. Cost: O(1), plus the service of waiting requests. Errors:
`PoolKit.Pool:SetMaxCreated maxCreated must be a positive integer`,
`PoolKit.Pool:SetMaxCreated cannot cap a pool that was built without maxCreated`,
`PoolKit.Pool:SetMaxCreated cannot lower the cap from <current> to <requested>`.

### `pool:CancelWaiting(callback)` — mutating

Returns whether a request was withdrawn. Cost: O(`maxWaiting`), allocates
nothing. Error: `PoolKit.Pool:CancelWaiting callback must be a function`.

### `pool:AttachChild(parent, child, childPool)` — mutating

Returns the pool. Cost: O(1); a pool's first `AttachChild` allocates its five
link maps, and a child pool's first attachment its attachment map. Errors:
`PoolKit.Pool:AttachChild parent must be a table or userdata`,
`PoolKit.Pool:AttachChild child must be a table or userdata`,
`PoolKit.Pool:AttachChild childPool must be a PoolKit pool`,
`PoolKit.Pool:AttachChild parent must be borrowed from this pool`,
`PoolKit.Pool:AttachChild child must be borrowed from childPool`,
`PoolKit.Pool:AttachChild cannot attach an object to itself`,
`PoolKit.Pool:AttachChild child is already attached to a parent`.

### `pool:DetachChild(child)` — mutating

Returns whether `child` had a parent in this pool. Cost: O(1). Error:
`PoolKit.Pool:DetachChild child must be a table or userdata`.

### `pool:ReleaseAfter(object, animationGroup)` — mutating

Returns `true` when the release was deferred, `false` when it happened at once.
Cost: O(1); a pool's first `ReleaseAfter` allocates its parked map, and a
group's first one installs the hook. Errors:
`PoolKit.Pool:ReleaseAfter object must be a table or userdata`,
`PoolKit.Pool:ReleaseAfter animationGroup must be an animation group`,
`PoolKit.Pool:ReleaseAfter animationGroup already has a pending release`, the
`Release` ownership errors with `PoolKit.Pool:ReleaseAfter` in their place,
`PoolKit.Pool:ReleaseAfter release is already pending for this object` for a
parked object, and the errors of an immediate release.

### Queries

`IsClosed()`, `GetAvailableCount()`, `GetActiveCount()`, `GetCreatedCount()`,
`GetDiscardedCount()`, `GetMaxRetained()`, `GetGeneration()`,
`GetWaitingCount()`, `GetParkedCount()`, `GetMaxCreated()`, `Owns(object)` and
`IsActive(object)` return the values listed in [Public surface](#public-surface),
never raise except for the receiver check, are O(1) and allocate nothing. They
may be called from inside the pool's own callbacks. `Owns` and `IsActive` return
`false` for a value that is not a table or userdata.

## Generic pools

`PoolKit:New(options)` accepts exactly:

- `create` — required function, called as `create(pool)`; must return a table or userdata;
- `reset` — optional function, called as `reset(object, pool)` before retention/discard;
- `destroy` — optional function, called as `destroy(object, pool)` when an object leaves pool ownership;
- `maxRetained` — non-negative integer or `PoolKit.UNBOUNDED`; default `128`;
- `strict` — boolean, default `true`; retains weak history for better duplicate-release diagnostics after discard;
- `strictReset` — boolean, default `false`; refuses to construct a pool that has no `reset` (see *Acquire does not clean*);
- `prewarm` — non-negative integer, default `0`; may not exceed a finite `maxRetained`;
- `maxActiveWarning` — non-negative integer; report once when this many objects are borrowed simultaneously (see *Active objects are caller-owned*);
- `generation` — positive integer stamped on the objects the factory builds; default `1` (see *Generations*);
- `maxCreated` — positive integer; the most objects the factory will ever build (see *Objects the host can never free*);
- `maxActive` — positive integer; the most objects borrowed or parked at the same time;
- `maxWaiting` — non-negative integer, default `0`; the size of the bounded waiting queue. Requires `maxCreated` or `maxActive`.

`NewTablePool(options)` accepts `maxRetained`, `strict`, `prewarm`, `maxActiveWarning` and `generation`. Lua tables can be freed, so the capacity options are for `New` only.

Unknown fields are rejected so configuration typos cannot silently alter retention behavior. When several unknown fields are present the message names the alphabetically first one.

## Acquire does not clean

`Acquire()` returns the object exactly as it was when it was released. PoolKit runs `reset` at **release** time and does nothing at acquire time, so a pool constructed **without** a `reset` callback hands back objects still carrying every field the previous borrower left on them:

```lua
local pool = PoolKit:New({ create = function() return {} end })

local first = pool:Acquire()
first.name = "stale"
pool:Release(first)

local second = pool:Acquire()
assert(second == first)
assert(second.name == "stale")   -- not cleaned: there is no reset callback
```

This is deliberate. A pool with no `reset` is a pure identity cache: PoolKit cannot know which fields are meaningful, and clearing them speculatively would both cost time on the hot path and destroy state some callers pool precisely in order to keep. Cleaning is the caller's decision, expressed as a `reset` callback.

Two consequences are worth stating plainly:

- **Never rely on a freshly acquired object being empty** unless the pool has a `reset` (or is a `NewTablePool`, whose built-in reset shallow-clears every key).
- **Treat leftover state as a leak surface.** A resetless pool keeps the previous borrower's references alive for as long as the object is retained, which can hold objects that should have been collected.

If a pool is supposed to have a `reset` and the callback was simply forgotten, `strictReset` turns that into a loud construction failure instead of a silent data leak:

```lua
PoolKit:New({ create = factory, strictReset = true })
-- error: PoolKit:New strictReset requires a reset callback
```

`strictReset` is validated at construction and is not retained on the pool, so opting into it costs `Acquire` and `Release` nothing.

## Active objects are caller-owned

`GetAvailableCount()` is bounded by `maxRetained`. `GetActiveCount()` is **not bounded at all**.

A borrowed object stays in the pool's active set until the caller releases it. PoolKit has no way to reclaim one — it holds a strong reference so that ownership, duplicate-release, and foreign-object checks stay correct — so an acquire loop that never releases grows the active set without limit. This is caller-owned retention, not a PoolKit retention policy, and it is the one place where a PoolKit pool is unbounded by construction.

Use `GetActiveCount()` to observe it, and `maxActiveWarning` to be told about it:

```lua
local pool = PoolKit:New({
    create = factory,
    maxActiveWarning = 500,
})
```

When the active count first reaches the threshold, PoolKit reports one diagnostic through WoW's `geterrorhandler()`. It reports **once per pool**: a leaking caller would otherwise be told on every subsequent acquire, drowning the signal it needs to see. The threshold changes nothing else — no acquire is refused and no object is reclaimed.

Outside the WoW client, or on any host that publishes no `geterrorhandler`, the warning is silently skipped; PoolKit is pure Lua and never requires the client to work.

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

Lifecycle callbacks may inspect the same pool through scalar/query methods, but they may not mutate that pool (`Acquire`, `Release`, `Prewarm`, `Trim`, `Clear`, `Close`, `SetMaxRetained`, `SetGeneration`, `SetMaxCreated`, `CancelWaiting`, `AttachChild`, `DetachChild` or `ReleaseAfter`) while `create`, `reset`, or `destroy` is executing. PoolKit rejects such same-pool re-entrancy explicitly. Callbacks may freely interact with other pools, and a pool driven from inside another pool's callback does not weaken the outer pool's guard: the guard is released only when the callback that took it returns, including when it returns by raising. This rule keeps callback behavior expressive without making ownership transactions recursively mutable.

Callbacks are synchronous lifecycle hooks; they must not yield. PoolKit uses protected calls where rollback or best-effort cleanup requires observing callback failure.

## Argument errors point at the caller

Every argument-validation failure is raised so that its `file:line` prefix is the line that called the public method:

```lua
pool:Prewarm(-1)
-- MyAddon/Main.lua:42: PoolKit.Pool:Prewarm count must be a non-negative integer
```

This holds for constructor options, pool-method arguments, closed-pool rejections, factory results rejected by the pool, methods called on something that is not a PoolKit pool, and mutation attempted from inside a lifecycle callback.

Errors that are re-raised after best-effort cleanup keep the original error object unchanged and therefore carry no added position. Constructor-time `prewarm` failures are re-raised the same way.

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

`Close()` is terminal for new acquisition and prewarming. It fails every waiting request (see *The waiting queue*), completes every parked release (see *Deferred release*) and then clears all retained objects. Already-borrowed objects may still be released after close; they are reset and then discarded instead of retained. This lets owners perform deterministic shutdown without invalidating handles that are temporarily still checked out.

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

## Generations

Every pool has a generation, a positive integer. Objects are stamped with the
generation in force when the factory built them. Raising the generation with
`SetGeneration(n)` says "objects built before this point have the wrong
shape":

- retained objects of an older generation are destroyed at once (`destroy` runs
  for each), and the call returns how many;
- a borrowed object of an older generation is still accepted by `Release` —
  ownership is ownership — and is reset, then destroyed instead of retained;
- `Acquire` therefore never hands out a stale object.

The generation only moves forward. `SetGeneration` with a lower value raises at
the caller's line; with the same value it does nothing and returns `0`.

The default generation is `1`, whichever embedded PoolKit copy built the pool,
so a pool that never uses generations never destroys an object for being stale
and never depends on which copy won. A consumer that versions
its own factory should pass its own `generation` and raise it when it replaces
`create`, typically from the in-place upgrade of its own embedded copy:

```lua
-- revision 1 of an addon library
local pool = PoolKit:New({ create = buildRowV1, generation = 1 })

-- revision 2 of the same library, upgrading the live pool in place
pool:SetGeneration(2)   -- rows built by buildRowV1 are retired, never reused
```

> **Generations and `maxCreated`.** Retiring a stale object destroys it, but a
> destroyed object still counts against `maxCreated`: the host still holds a
> Frame PoolKit has let go of. Raising the generation of a capped pool can
> therefore use up its cap for good, and `Acquire` then answers `"exhausted"`
> for ever. A consumer that raises the generation of a capped pool raises the cap
> with it, by the number of objects it retired or by its own budget:
>
> ```lua
> local retired = rows:SetGeneration(2)
> rows:SetMaxCreated(rows:GetMaxCreated() + retired + rows:GetActiveCount())
> ```
>
> `SetMaxCreated(n)` only raises the cap; a lower value, or a pool built without
> `maxCreated`, raises at the caller's line. A `maxRetained` that equalled the old
> cap — the default for a capped pool — follows the cap up, and waiting requests
> are served from the new room at once.

PoolKit's own in-place upgrades never change a pool's generation: a new PoolKit
revision does not change the objects a consumer's factory builds. Pools created
by a PoolKit revision older than generations take the default generation, `1`;
a pool keeps whatever generation it already carries.

Stamps live in a weak-keyed side table owned by the pool. PoolKit never writes a
field onto the object, and a stamp never keeps an object alive. A pool whose
generation never changed writes no stamps at all; after a raise, stamping costs
one table write per object built.

## Objects the host can never free

World of Warcraft can create Frames, Textures and FontStrings but never destroy
them. Pooling them needs bounds the host will not provide.

```lua
local rows = PoolKit:New({
    create = function() return CreateFrame("Frame", nil, parent) end,
    reset = function(frame) frame:Hide(); frame:ClearAllPoints() end,
    maxCreated = 40,   -- never more than 40 Frames, ever
    maxActive = 20,    -- never more than 20 on screen at once
    maxWaiting = 8,    -- up to 8 requests may wait for a free row
})
```

### Creation cap

`maxCreated` bounds how many objects the factory builds over the pool's whole
life. Objects PoolKit later destroys — through `Trim`, `Clear`, `Close`, a
retention overflow or a stale generation — still count, because the host still
holds them. When `maxCreated` is set and `maxRetained` is not, the retention
bound defaults to `maxCreated`, so a released object is never discarded for
lack of room. `prewarm` and `Prewarm` may not ask for more than the cap allows.

### Live limit

`maxActive` bounds how many objects are borrowed or parked (see *Deferred
release*) at the same time.

### When the pool is at capacity

Without `maxCreated` or `maxActive`, `Acquire` always returns an object. With them, a pool at capacity returns `nil` and a reason instead:

| Call | Result at capacity |
|---|---|
| `Acquire()` | `nil, "exhausted"` |
| `Acquire(onAvailable)`, queue has room | `nil, "waiting"`; the request is queued |
| `Acquire(onAvailable)`, queue full | `nil, "queueFull"`; the request is refused |

When capacity is free, `Acquire(onAvailable)` returns the object directly and
never calls `onAvailable`.

### The waiting queue

A queued request is a callback. When a release frees capacity, PoolKit borrows
the object on behalf of the oldest request and calls
`onAvailable(object, pool)`; from then on the callback's owner owns the object
exactly as if `Acquire` had returned it. Requests are served strictly first in,
first out, and a new `Acquire` never jumps a non-empty queue.

The queue is **bounded and never grows**. It is a ring of `maxWaiting` slots
allocated once when the pool is built; queueing and serving requests only
overwrite those slots, so the design allocates nothing per acquire. A request
that finds the ring full is refused with `"queueFull"`. `maxWaiting = 0`, the
default, means every callback request at capacity is refused that way.

The callback itself is the ticket: `CancelWaiting(callback)` withdraws the oldest
request made with that function and returns whether one was found. A closure
created per request therefore cannot be cancelled by anyone who does not hold
it; pass a stable function when cancellation matters.

Failures on the serving path cannot be raised to anybody useful — the `Release`
that freed capacity did nothing wrong — so they are reported through the host
error handler:

- a callback that raises keeps the object it was given;
- a factory that raises while serving leaves the request at the front of the
  queue, to be served by the next release or `Acquire`.

`Close()` fails every queued request by calling `onAvailable(nil, pool, "closed")`.

## Cascading release

```lua
frames:AttachChild(frame, background, textures)
frames:AttachChild(frame, border, textures)

frames:Release(frame)   -- releases border, then background, then frame
```

`AttachChild(parent, child, childPool)` makes `child`, borrowed from
`childPool`, follow `parent`, borrowed from this pool. Releasing the parent
releases its children first — most recently attached first, each through its
own pool, and their own children before them — then resets the parent.
`childPool` may be the parent's own pool.

- A child released on its own is detached from its parent on the spot, so the
  parent's later release never touches an object someone else has borrowed
  since.
- `DetachChild(child)`, called on the parent's pool, undoes an attachment
  without releasing anything.
- A child can have one parent at a time; attaching it again raises.
- A cycle of attachments terminates: an object already being released is
  skipped.
- A child whose release fails does not stop the parent's release. The parent is
  released, and the first child error is re-raised afterwards. A child whose
  `reset` raised is rolled back to borrowed from its own pool, as a direct
  `Release` would be, but it is no longer attached: whoever handles the error
  owns it.
- A parent whose own `reset` raises is rolled back to borrowed and stays
  borrowed; its children have already been released and detached by then. When
  a child failed as well, the child's error is the one re-raised.

The links are an intrusive doubly linked list kept in side tables of the
parent's pool, created on that pool's first `AttachChild`. Attaching and
detaching are constant time.

## Deferred release

```lua
fadeOut:Play()
pool:ReleaseAfter(frame, fadeOut)   -- released when the fade-out finishes
```

`ReleaseAfter(object, animationGroup)` parks a borrowed object until
`animationGroup` finishes playing, then releases it — children, reset,
retention — exactly as `Release` would. It returns `true` when the release was
deferred.

- A parked object is still owned by the pool (`Owns` is `true`) but no longer
  borrowed (`IsActive` is `false`, and `GetActiveCount` does not count it).
  `GetParkedCount` does. It still counts against `maxActive`, because it is
  still on screen.
- PoolKit hooks the group's `OnFinished` script **once per group, ever**.
  `HookScript` cannot be undone, and a pooled Frame reuses its animation, so
  hooking per release would stack a permanent hook on every reuse.
- **Play first, then `ReleaseAfter`.** The group's state is read when
  `ReleaseAfter` is called. A group that is not playing then (`IsPlaying()`
  returns `false`) would never finish, so the object is released immediately
  and the call returns `false` — `ReleaseAfter(frame, fadeOut); fadeOut:Play()`
  releases the Frame before the fade-out starts.
- Some animations never fire `OnFinished`, and each of them leaves the object
  parked until `Release(object)` completes the release early or the pool
  closes:
  - an animation stopped with `Stop()` rather than finished;
  - a looping group (`SetLooping("REPEAT")` or `"BOUNCE"`), which never
    finishes;
  - a paused group (`Pause()`), until it resumes and finishes.
- **Do not replace the group's `OnFinished` script afterwards.** PoolKit's hook
  is installed with `HookScript` once per group. A later
  `group:SetScript("OnFinished", handler)` replaces the script and PoolKit's
  hook with it, and PoolKit cannot detect that through the host API, so it does
  not re-arm: every later `ReleaseAfter` on that group parks its object until
  `Release` or `Close`. Set the group's own `OnFinished` script before the first
  `ReleaseAfter`, or use `HookScript` for it as well.
- One animation group can hold one pending release at a time.
- A failure while completing a release from the host's `OnFinished` is
  reported through the host error handler.
- `Close()` completes every parked release immediately.

PoolKit stays free of any WoW dependency: it calls only the two methods of the
group it is handed.

## Limits

PoolKit follows the framework rule "bounded by default, opened on purpose".
Every limit is an option on the pool the consumer creates; PoolKit has no
package-wide limit, so it has no `SetLimits`. A pool at a limit answers with a
named reason or discards on release, as each row says; nothing grows silently.

| Limit | Default | How to open | UNBOUNDED allowed? |
|---|---|---|---|
| `maxRetained`: released objects kept for reuse | `128` (`PoolKit.DEFAULT_MAX_RETAINED`); `maxCreated` when that is set and this is not | `New` / `NewTablePool` option, or `pool:SetMaxRetained(n)`; a non-negative integer (`0` retains nothing) | Yes: `PoolKit.UNBOUNDED`. The retained objects are the pool owner's own memory. A release beyond the limit is discarded. |
| `maxCreated`: objects the factory builds over the pool's life | none | `New` option, a positive integer; `pool:SetMaxCreated(n)` raises it and never lowers it | Not needed: omitting it is unbounded. It exists for objects the host never frees (Frames, Textures). At the cap, `Acquire` returns `nil, "exhausted"` or queues. |
| `maxActive`: objects borrowed or parked at once | none | `New` option, a positive integer | Not needed: omitting it is unbounded. At the cap, `Acquire` returns `nil, "exhausted"` or queues. |
| `maxWaiting`: queued `Acquire(onAvailable)` requests | `0` | `New` option, a non-negative integer; requires `maxCreated` or `maxActive` | No: the queue is a ring of `maxWaiting` slots allocated once when the pool is built, so it needs a size. A request that finds it full gets `nil, "queueFull"`. |

`maxActiveWarning` is a diagnostic, not a limit: it reports once when that many
objects are borrowed and refuses nothing. Borrowed objects are caller-owned and
unbounded unless `maxActive` is set (see
[Active objects are caller-owned](#active-objects-are-caller-owned)).

`PoolKit.UNBOUNDED` is one sentinel table kept in the package state, so every
embedded copy and every revision publishes the same table and a pool created
with it stays unbounded after an upgrade.

## Embedded copies

PoolKit is registered as `poolKit`, API generation `1`, through Registry API 2. The facade, `Pool` prototype, metatable, and `UNBOUNDED` sentinel live in Registry-owned shared state, so compatible future revisions can preserve existing pool identity while replacing methods in place.

The shared state carries schema `2`; loading over schema-`1` state left by
revisions 1 to 3 adds the deferred-release tables in place. Pools are not
registered anywhere, so a bootstrap cannot reach them; instead every pool method
upgrades a pool built by revisions 1 to 3 the first time it touches it. The
upgraded pool keeps every object and counter, gains no caps, no queue and no
children, and takes the default generation, `1`. A pool built by revision 1 also
gains the re-entrancy counter and the disabled leak warning it predates. The
`OnFinished` hook calls
through shared state, so a hook installed by one revision runs the newest
accepted revision's code.
