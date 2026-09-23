# CacheKit Internals

This document describes implementation invariants for maintainers. It is not an additional public API.

## Cache layout

A cache is one table with a fixed set of private fields, all created by `newCache`, so no later write adds a key to it:

| Field | Meaning |
|---|---|
| `_entries` | Hash from key to entry. `false` once closed. |
| `_newest`, `_oldest` | Ends of the recency list, or `false` when empty. |
| `_count`, `_maxEntries` | Stored entries and the bound. |
| `_ttlSeconds` | Age limit in seconds, or `false` for an LRU cache. |
| `_free`, `_freeCount` | The free list: an array of blank entry tables. |
| `_hits`, `_misses`, `_evictions` | Counters. |
| `_statsView` | The table `GetStats` returns, `false` until the first call. |
| `_eventScope`, `_clearOnEvents`, `_clearCallback` | Clear-on-event state, `false` until the first `ClearOn`. |
| `_closed` | Whether `Close` ran. |
| `_schema` | The cache layout version, `1`. |

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

`recycle` blanks an entry's `key`, `value` and `expiresAt` (so the cache no longer holds what they referenced) and pushes it onto `_free` while `_freeCount < _maxEntries`. `takeEntry` pops from `_free` before allocating.

The invariant is that live entries plus free entries never exceed `maxEntries`: an entry reaches the free list only when the live count drops by one, and a new key takes from the free list before it allocates. The bound check in `recycle` is therefore a guard rather than a policy. It also follows that a full cache has an empty free list, which is why eviction reuses the evicted entry directly instead of passing it through the list.

`Close` drops `_entries` and `_free` together, so a closed cache retains nothing.

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

`fill` asks `issecretvalue` (looked up once at load, absent outside Retail 12.x) about the key and the value before its first comparison, because comparing a secret or using it as a key is itself the client error. The cache paths do not probe; see *Secret values* in `API.md`.

## Closures and upgrades

CacheKit hands out three kinds of closure: the memoised function, the snapshot's `fill`, and the clear-on-event callback. Each one captures only the object it serves and the shared `state.dispatch` table, and calls `dispatch.memoizedCall`, `dispatch.snapshotFill` or `dispatch.clearOnEvent` at call time. A newer revision rewrites those three fields, so closures created by an older revision run the newer behaviour.

Caches and snapshots use the metatables stored in `state.cacheMetatable` and `state.snapshotMetatable`, whose `__index` points at the shared `Cache` and `Snapshot` prototypes on the facade. An upgrade keeps both metatables and rewrites the prototype methods in place, so existing objects keep their entries and gain the new methods. Each object carries `_schema`, so a revision that changes the layout can upgrade old objects lazily, the way PoolKit upgrades pools.

The upgrade spec loads the same source a second time with `IMPLEMENTATION_REVISION` raised to 2 and checks that entries, recency, statistics, memoised functions, subscriptions and snapshots all survive.

## Error levels

`ClearOn` calls `scope:Connect` through `pcall`: EventKit raises a refused host registration at its own caller, which is a CacheKit line. The failure is re-raised at level 2 under `CacheKit.Cache:ClearOn`, with EventKit's `file:line: ` prefix stripped and its reason kept, and the event is not recorded, so a later `ClearOn` can try again.


Every argument validator takes an explicit `level`, which is the value `error` needs *inside the function that receives it*; each further hop towards `error` adds one. Failures raised through a closure count the closure as a level: `memoizedCall` and `snapshotFill` raise at level 3 (themselves, the closure, then the caller of the closure), and `snapshotFill` passes 4 to `validateKey`.
