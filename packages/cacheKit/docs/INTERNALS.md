# CacheKit Internals

This document describes implementation invariants for maintainers. It is not an additional public API.

## Cache layout

A cache is one table with a fixed set of private fields, all created by `newCache`, so no later write adds a key to it:

| Field | Meaning |
|---|---|
| `_entries` | Hash from key to entry. `false` once closed. |
| `_newest`, `_oldest` | Ends of the recency list, or `false` when empty. |
| `_count`, `_maxEntries` | Stored entries and the bound; `math.huge` for a cache opened with `CacheKit.UNBOUNDED`, so the hot path compares two numbers. |
| `_ttlSeconds` | Age limit in seconds, or `false` for an LRU cache. |
| `_free`, `_freeCount`, `_freeLimit` | The free list: an array of blank entry tables, and the most it keeps (`maxEntries`, or 1024 when unbounded). |
| `_hits`, `_misses`, `_evictions` | Counters. |
| `_statsView` | The table `GetStats` returns, `false` until the first call. |
| `_eventScope`, `_clearOnEvents`, `_clearCallback` | Clear-on-event state, `false` until the first `ClearOn`. |
| `_closed` | Whether `Close` ran. |
| `_schema` | The cache layout version, `1`. Revisions 2, 3 and 4 changed nothing in the cache layout. |

## The recency list

Entries are plain tables with exactly five fields: `key`, `value`, `newer`, `older` and `expiresAt`. Every field exists from construction and `false` stands for "no link" and "no expiry", so relinking an entry only overwrites existing fields and never rehashes it.

```text
_newest                                                     _oldest
   │                                                           │
   ▼                                                           ▼
 entry ──older──▶ entry ──older──▶ entry ──older──▶ ... ──▶ entry
       ◀──newer──       ◀──newer──       ◀──newer──
```

The list is intrusive: the links live on the entries the hash already points at, so there is no separate node per entry. Each operation is a constant number of field writes:

- `touch` (a `Get` hit, a `Set` of an existing key) unlinks the entry and links it at `_newest`, and does nothing when it already is the newest;
- a new key in a full cache takes `_oldest`, unlinks it, removes its key from the hash and reuses the same table for the new key;
- `Delete`, an expired entry found by `Get`, and `Clear` unlink the entry and recycle it.

## The free list

`recycle` blanks an entry's `key`, `value` and `expiresAt` (so the cache no longer holds what they referenced) and pushes it onto `_free`. `takeEntry` pops from `_free` before allocating.

The invariant is that live entries plus free entries never exceed `maxEntries`: an entry reaches the free list only when the live count drops by one, and a new key takes from the free list before it allocates. That is what bounds a bounded cache's free list, so its `_freeLimit` check never fires; an unbounded cache has no such invariant and `recycle` drops blank entries past 1024 instead; `Property_spec.lua` checks the invariant after every step. It also follows that a full cache has an empty free list, which is why eviction reuses the evicted entry directly instead of passing it through the list.

`Close` drops `_entries` and `_free` together, so a closed cache retains no entry, key or value.

The list and free-list helpers (`linkNewest`, `unlink`, `touch`, `pushFree`, `popFree`) take the owner rather than a cache, and read only `_newest`, `_oldest`, `_free`, `_freeCount` and `_freeLimit`. A lazy tree has the same five fields and its nodes carry the same `newer` and `older` links, so both structures share one recency list and one free list implementation.

## Negative entries

A negative entry is an ordinary entry whose `value` is `state.negative`, a private table created once per package state. `Get`, `Peek` and `memoizedCall` compare the value against it by raw identity (a raw-equality call, never `==`). The stored value is the caller's and may be a secret; a secret is a string, number or boolean, and the client answers a comparison between a secret and a value of another type, such as this table, without raising (measured on Retail 12.1.0 b69933), whereas `rawequal` of a secret and a value of its own type raises: one call on the hit path, no extra entry field, and revision 1 entries keep their five-field layout. The marker lives in the state rather than in a file-local table so that an entry written by one revision reads as negative in the next.

`PutNegative` stores through the same `store` as `Set`, which now takes the expiry as an argument: `Set` passes the cache's own (`expiryForNow`), `PutNegative` passes `expiryAfter(ttlSeconds)`. That is the whole of "its own age limit": nothing else in expiry or eviction knows the entry is negative. It is refused on a cache whose `_ttlSeconds` is `false`, because nothing on that cache would ever expire it.

## Allocation

After a cache has reached its steady state:

- `Get` (hit or miss), `Peek`, `Delete`, `GetCount` and `Set` of an existing key allocate nothing;
- `Set` of a new key allocates an entry table only when the free list is empty and the cache is not full;
- inserting a new key into `_entries` may make Lua grow or rehash that hash table, which is the one allocation a stream of distinct keys can cause even when every entry table is reused;
- `GetStats` allocates its result table once per cache;
- `ClearOn` allocates the EventKit scope, the callback and the event map once per cache, and one connection per event.

The allocation specs measure these paths with `collectgarbage("count")` and the collector stopped.

## Age limits

`expiresAt` is `GetTimePreciseSec() + ttlSeconds` at the last `Set`. An entry is expired when the clock reads at or past that instant. The clock is looked up once at load; when it is absent `_ttlSeconds` still records the configured value, but `expiryForNow` stores `false` and `isExpired` answers `false`, so nothing expires.

Expired entries are removed lazily: by `Get` (which counts a miss), or when they reach `_oldest` and a new key needs the room (which does not count an eviction). `Peek` reports them as absent without removing them, because `Peek` promises no side effects. `GetCount` therefore counts expired entries nobody has touched yet.

## Snapshots

A snapshot keeps `_values` (key to value) and `_seen` (key to the number of the refresh that last filled it), plus `_stamp`, the number of the current refresh.

A refresh increments `_stamp` and calls the reader with the snapshot's `fill` function. `fill` refuses a key whose `_seen` stamp is already current (a duplicate) and a fill past `maxEntries`, records the stamp, and then:

- a key not in `_values` is stored and appended to `_added`;
- a key whose value differs from the stored one by raw equality (no `__eq` metamethod) is overwritten and appended to `_changed`;
- a key with the same value costs two reads and one write to a field that already exists, and nothing else.

After the reader returns, one pass over `_values` removes every key whose stamp is stale and appends it to `_removed`. The three result arrays belong to the snapshot: each refresh writes from index 1 and clears the slots the previous refresh used beyond its new count, so `#array` is always right and the arrays stop growing once they reach their largest size.

The design passes a function to the reader rather than a table for it to fill. A scratch table that is emptied and refilled on every refresh would leave dead keys behind after a garbage-collection cycle, and refilling it would eventually make Lua rehash it, which is an allocation on a refresh in which nothing changed.

`maxEntries` counts the keys filled in one refresh, not the keys stored while it runs, so replacing every key of a full snapshot works; during that refresh `_values` briefly holds up to twice `maxEntries` keys.

When the reader raises, the removal pass is skipped, because a failed read says nothing about the keys it did not reach. `rollBackRefresh` then removes every key listed in `_added` from `_values` and `_seen`, and writes back the value every key in `_changed` held before, so the snapshot is exactly the last successful refresh and `_count` is unchanged. The previous values come from `_changedPrevious`, an array parallel to `_changed` that `fill` writes only on a change, so the unchanged path is untouched; it is cleared when every refresh ends, so it retains nothing. Without restoring them, the caller would never see the change: `Refresh` raised instead of returning `changed`, and the next successful refresh would compare against the new value and report nothing. Without the rollback, each failing read would keep every old key and add up to `maxEntries` new ones, and the snapshot would grow without limit. The error is re-raised with `error(failure, 0)`: the value is unchanged, and the traceback ends at `Refresh`. `_refreshing` guards against a reader that refreshes or closes its own snapshot.

`fill` asks `issecretvalue` (looked up once at load, absent outside Retail 12.x) about the key and the value before its first comparison, because comparing a secret with a value of its own type, or using it as a key, is itself the client error. The cache paths do not probe; see *Secret values* in `API.md`.

## Lazy trees

A lazy tree is a tree of nodes under an unkeyed `_root`. A node has a fixed shape: `key`, `parent`, `children` (`false` until the first child), `childCount`, `hasValue`, `value`, `newer` and `older`. A node is **expanded** when `hasValue` is true; a node without a value exists only because a descendant is expanded.

| Field | Meaning |
|---|---|
| `_root` | The unkeyed root node. `false` once closed. |
| `_newest`, `_oldest` | Ends of the recency list over expanded nodes. |
| `_count`, `_maxEntries` | Expanded nodes and the bound; structure is not counted. |
| `_free`, `_freeCount`, `_freeLimit` | The free list of blank nodes, bounded as a cache's. |
| `_hits`, `_misses`, `_evictions`, `_statsView` | As for a cache. |
| `_resolve` | The caller's resolver. |
| `_closed`, `_schema` | Whether `Close` ran; the layout version, `1`. |

`Get` reads its variable arguments in place (`select("#", ...)`, `select(index, ...)`) and walks `_root.children[part]` per part, so a hit allocates nothing. On a miss it calls `resolve(...)` first and walks the path **again** to create the nodes: the resolver may have read, invalidated or closed parts of the tree, including this path's, and a `nil` result must leave no structure behind. `expandNode` links the node as the newest expanded node first and evicts `_oldest` only then, when the count exceeds `maxEntries`. The order matters: evicting first would let `pruneUpwards` detach the node being expanded when the evicted node was its only expanded descendant, leaving a value linked in the recency list but no longer in the tree. Expanded first, the node holds a value, so pruning stops at it and at every ancestor above it, and eviction never picks it, because it is the newest and the tree holds at least two expanded nodes whenever it evicts.

Invalidation and eviction share two helpers. `dropValue` unlinks a node and forgets its value, leaving it in the tree. `pruneUpwards` walks from a node towards the root detaching every node that has neither a value nor a child, and stops at the first that has one. `invalidatePath` walks the path, dropping the value of each ancestor it passes; at the end of the path it removes the subtree (`removeSubtree`, recursive over `children`, depth bounded by the path depth) and prunes upwards from the last ancestor; when the path leaves the tree early it prunes upwards from the deepest node reached, so ancestors that lost their values and have no other children disappear too. The invariant after every operation is that **every node without a value has an expanded descendant**, which bounds structure by `maxEntries` times the path depth; `Lazy_spec.lua` checks it after every step of a mixed workload, run once with six expanded nodes and once with two, where almost every miss evicts, together with every listed node being attached under the root.

`detachNode` blanks a node's `key`, `parent` and `childCount` and pushes it onto the free list (capped at `_freeLimit`), but keeps its emptied `children` table, which retains no key and is reused when the node gains a child again. Unlike a cache, a lazy tree has no "live plus free never exceed the bound" invariant: an invalidation frees a whole subtree of structural nodes at once, so a re-expansion reuses blank nodes and allocates a node only when none is free (with `maxEntries = 1`, re-expanding a depth-3 path after invalidating it allocates the two structural nodes each cycle). `Close` drops `_root` and `_free` together.

## Queues

A queue is `_slots`, an array of `_capacity` entries created with `false` at construction, plus `_head`, the slot of the oldest value, and `_count`. Value `offset` from the oldest lives at `(_head - 1 + offset) % _capacity + 1`. `Push` on a queue with room writes at offset `_count`; when full, `"dropOldest"` overwrites `_head` (the slot behind the newest is the oldest's) and advances `_head`, the other two policies write nothing. `Pop` reads `_head`, blanks it to `false` and advances. `Iterate` returns a module-level iterator function with the queue and `0` as its state, so starting an iteration allocates nothing; the iterator reads `position - 1` as the offset. Nothing in a queue is compared, so secret values pass through it. The capacity is bounded by the package-wide `maxQueueCapacity` (default 1024, ceiling 65536) rather than accepting `UNBOUNDED`, because the whole ring is allocated in `newQueue`: the same decision SignalKit takes for journals.

## Closures and upgrades

CacheKit hands out three kinds of closure: the memoised function, the snapshot's `fill`, and the clear-on-event callback. Each one captures only the object it serves and the shared `state.dispatch` table, and calls `dispatch.memoizedCall`, `dispatch.snapshotFill` or `dispatch.clearOnEvent` at call time. A newer revision rewrites those three fields, so closures created by an older revision run the newer behaviour. Because of that, a dispatch function's parameter list may only **grow at the end**: revision 1 closures call `memoizedCall(cache, fn, key)`, so revision 2 added `cacheable` as the fourth parameter and treats `nil` as "no predicate". A lazy tree hands out no closure; its resolver is the caller's.

Caches, snapshots, lazy trees and queues use the metatables stored in `state.cacheMetatable`, `state.snapshotMetatable`, `state.lazyMetatable` and `state.queueMetatable`, whose `__index` points at the shared `Cache`, `Snapshot`, `LazyTree` and `Queue` prototypes on the facade. An upgrade keeps the metatables and rewrites the prototype methods in place, so existing objects keep their contents and gain the new methods. Each object carries `_schema`, so a revision that changes the layout can upgrade old objects lazily, the way PoolKit upgrades pools.

### State schema 2

Revision 3 writes the same schema 2 as revision 2 and changes no object layout: it only corrects the order of expansion and eviction in `expandNode`, so an upgrade over revision 2 replaces the prototype methods and keeps the state and every object as they are. Revision 4 likewise changes no state or object layout: it asks `issecretvalue` before a limit value meets `UNBOUNDED`, and compares a stored value with the negative marker by raw identity instead of `==`. Revision 5 changes no state or object layout either: it asks `issecretvalue` about a `cacheable` answer before testing it for truth.

Revision 1 wrote state schema 1: `dispatch`, `runtimeRevision`, `cacheMetatable`, `snapshotMetatable`, `unbounded`. Revision 2 writes schema 2, which adds `lazyMetatable`, `queueMetatable`, `negative` and `limits` (`{ maxQueueCapacity = 1024 }`, the table `SetLimits` writes and `validateCapacity` reads). Bootstrap holds an inherited state to `validateStateShared` (the schema 1 fields), then, when its schema is `1`, adds the four tables and sets the schema to `2`, and only then requires `validateStateBase` (the full schema 2 shape, including every limit within its ceiling). The `LazyTree` and `Queue` prototypes are created when the inherited facade has none (`inheritPrototype`). Nothing in a cache or snapshot changed, so no object is upgraded lazily.

The bootstrap specs load the same source with `IMPLEMENTATION_REVISION` set to 1, strip the state and facade back to the revision 1 shape, reload the real revision and check the upgrade; they load the source labelled revision 2, and labelled revision 3, and check that the real revision keeps its state, limits, lazy trees, queues and negative entries; and they load the next revision over the current one and check that caches, memoised functions, subscriptions, snapshots, lazy trees, queues and negative entries all survive.

## Error levels

`ClearOn` calls `scope:Connect` through `pcall`: EventKit raises a refused host registration at its own caller, which is a CacheKit line. The failure is re-raised at level 2 under `CacheKit.Cache:ClearOn`, with EventKit's `file:line: ` prefix stripped and its reason kept, and the event is not recorded, so a later `ClearOn` can try again.

Every argument validator takes an explicit `level`, which is the value `error` needs *inside the function that receives it*; each further hop towards `error` adds one. Failures raised through a closure count the closure as a level: `memoizedCall` and `snapshotFill` raise at level 3 (themselves, the closure, then the caller of the closure), and `snapshotFill` passes 4 to `validateKey`. `validatePath` receives the variable arguments and the level from the lazy tree method that called it, so a bad path part is reported at the line that called `Get`, `Peek` or `Invalidate`, and the part's index is built into the message only on failure.
