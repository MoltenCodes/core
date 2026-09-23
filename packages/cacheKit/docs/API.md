# CacheKit API

CacheKit API generation **1** provides bounded caches: least-recently-used caches bounded by count, the same caches with an age limit, memoisation of a one-key function, snapshots that report what changed between two reads, and clearing a cache when a host event fires.

Implementation revision: **1**.

## Loading

Runtime files must be loaded in dependency order:

```text
Registry.lua
CacheKit.lua
```

Portable WoW code resolves the package through Registry:

```lua
local CacheKit = MoltenCodes.Registry:Get("cacheKit", 1)
```

CacheKit does not rely on `require()` at runtime.

### Optional host facilities

| Facility | Used by | Without it |
|---|---|---|
| `GetTimePreciseSec` | age limits (`NewTtl`, `Memoize` with `ttlSeconds`) | CacheKit loads normally and every age limit is disabled: entries never expire, and a TTL cache behaves as a plain LRU cache. |
| EventKit API 1 | `cache:ClearOn` | `ClearOn` raises at the caller: `CacheKit.Cache:ClearOn requires EventKit API 1, which is not loaded (absent)`. Everything else works. |

EventKit is looked up with `Registry:Find("eventKit", 1)` when `ClearOn` is called, not at load, so EventKit may be embedded before or after CacheKit. The package manifest lists only required dependencies, so it names Registry alone.

## Public surface

Package facade:

| Method | Purpose |
|---|---|
| `NewLru(options)` | Create a least-recently-used cache. |
| `NewTtl(options)` | Create a least-recently-used cache whose entries also expire by age. |
| `Memoize(fn, options?)` | Wrap a one-key function; returns the memoised function and its cache. |
| `NewSnapshot(read, options?)` | Create a snapshot that diffs what `read` reports. |

Cache handles (both constructors return the same kind of handle):

| Method | Purpose |
|---|---|
| `Get(key)` | Return the live value and mark it as used; counts a hit or a miss. |
| `Set(key, value)` | Store `value` as the most recently used entry; `nil` deletes. |
| `Peek(key)` | Return the live value without marking it or counting anything. |
| `Delete(key)` | Remove the key; return whether an entry was stored under it. |
| `Clear()` | Remove every entry; return how many were stored. Statistics are kept. |
| `GetCount()` | Return how many entries are stored. |
| `GetStats()` | Return `{ hits, misses, evictions }` (the same table every call). |
| `ClearOn(eventName)` | Clear the cache whenever the event fires; needs EventKit. |
| `Close()` | Drop every entry and release every subscription; `false` if already closed. |
| `IsClosed()` | Whether the cache is closed. |

Snapshot handles:

| Method | Purpose |
|---|---|
| `Refresh()` | Call `read`; return the `added`, `removed` and `changed` key arrays. |
| `Get(key)` | Return the value the latest refresh recorded, or `nil`. |
| `GetCount()` | Return how many keys the latest refresh recorded. |
| `Pairs()` | Iterate the recorded keys and values without allocating. |
| `Close()` | Drop everything recorded; `false` if already closed. |
| `IsClosed()` | Whether the snapshot is closed. |

`CacheKit.Cache` and `CacheKit.Snapshot` are the shared method prototypes.

## Bounds

Every cache is bounded, and there is no unbounded mode:

| Constructor | `maxEntries` |
|---|---|
| `NewLru`, `NewTtl` | Required. |
| `Memoize` | Optional, default `128`. |
| `NewSnapshot` | Optional, default `1024`; the most keys one refresh may report. |

`maxEntries` must be an integer of at least `1`. Option tables refuse unknown fields.

## `CacheKit:NewLru({ maxEntries })`

Creates a cache holding at most `maxEntries` entries. Adding a new key to a full cache evicts the least recently used entry. Both `Get` (on a hit) and `Set` count as a use; `Peek` does not.

```lua
local cache = CacheKit:NewLru({ maxEntries = 3 })
cache:Set("a", 1)
cache:Set("b", 2)
cache:Set("c", 3)
cache:Get("a")      -- "b" is now the least recently used
cache:Set("d", 4)   -- evicts "b"
```

## `CacheKit:NewTtl({ maxEntries, ttlSeconds })`

Creates the same cache with an age limit. An entry expires `ttlSeconds` after it was last **set**: reading it does not extend its life, setting it again restarts it. `ttlSeconds` must be a finite number greater than zero. An entry whose age equals `ttlSeconds` is expired.

The cache stays bounded by `maxEntries` and evicts by recency, not by age. Expired entries are removed lazily:

- `Get` removes an expired entry and counts a miss;
- when a new key needs room and the least recently used entry has expired, it is dropped without counting an eviction;
- `Peek` reports an expired entry as absent but leaves it stored, because `Peek` has no side effects;
- `GetCount` counts stored entries, including expired ones nothing has touched yet.

Without `GetTimePreciseSec` nothing expires (see *Optional host facilities*).

## Keys and values

A key may be any Lua value except `nil` and NaN, which Lua cannot use as a table key; both are refused at the caller's line:

```text
MyAddon/Core.lua:42: CacheKit.Cache:Get key must not be nil
```

Keys are compared the way a Lua table compares them: by value for strings, numbers and booleans, by identity for tables and functions.

A value may be anything except `nil`. `Set(key, nil)` deletes the key, because a table cannot store `nil`; it is not an error. `false` is an ordinary value.

## `cache:GetStats()`

Returns a table with three counters:

| Field | Counts |
|---|---|
| `hits` | `Get` calls and memoised calls answered from the cache. |
| `misses` | `Get` calls and memoised calls that found no live entry, including expired ones. |
| `evictions` | Live entries removed to stay within `maxEntries`. `Delete`, `Clear`, `ClearOn` and expiry are not evictions. |

`Peek` counts nothing. `Clear` keeps the counters. The same table is returned on every call for one cache, refreshed from the live counters each time; it is allocated on the first call. Copy the fields if you need to keep a reading, and do not write to the table.

## `cache:ClearOn(eventName)`

Clears the cache whenever the host event `eventName` fires, through a private EventKit scope the cache owns. Returns `true` when it connected, `false` when the cache already clears on that event. The subscriptions are bounded by the number of distinct event names.

`eventName` must be a non-empty string. A closed cache refuses: `CacheKit.Cache:ClearOn cannot subscribe a closed cache`. When EventKit is not loaded, or its entry is retired, the error names the `Registry:Find` reason (`absent`, `generation_mismatch` or `retired`).

A cache closed from inside a listener of the same event is not cleared again by a delivery EventKit still owes it; see EventKit's *Closing during a dispatch*.

## `cache:Close()`

Marks the cache closed, drops every entry and the free list, and closes the EventKit scope that holds its subscriptions. Returns `false` when the cache was already closed.

A closed cache reads as empty: `Get` and `Peek` return `nil` and count nothing, `Delete` returns `false`, `Clear` and `GetCount` return `0`. `Set` and `ClearOn` raise at the caller, and so does a memoised function whose cache is closed. A failure EventKit re-raises while releasing the subscriptions is raised after the cache is fully closed.

## `CacheKit:Memoize(fn, options?)`

```lua
local spellName, cache = CacheKit:Memoize(function(spellId)
    return C_Spell.GetSpellName(spellId) or false
end, { maxEntries = 512, ttlSeconds = 60 })

spellName(133)                 -- computed
spellName(133)                 -- remembered
cache:ClearOn("SPELLS_CHANGED")
cache:Clear()
```

Returns two values: the memoised function, and the cache behind it. The cache is an ordinary CacheKit cache and is the handle to clear the memo (`Clear`, `Delete`), read its statistics, clear it on an event, or `Close` it.

| Option | Default | Meaning |
|---|---|---|
| `maxEntries` | `128` | Most results remembered. |
| `ttlSeconds` | none | When given, a result expires this many seconds after it was computed. |

The memoised function takes exactly one argument, a string or a number (not NaN), and refuses anything else at its caller's line. Only `fn`'s first result is remembered and returned. A `nil` result is returned but **not remembered**, so `fn` runs again for that key next time; return `false` for a negative answer you want remembered. An error from `fn` propagates unchanged and remembers nothing. `fn` may call the memoised function for other keys.

## `CacheKit:NewSnapshot(read, options?)`

A snapshot is a key-to-value map that `read` rebuilds on every `Refresh`, reporting what changed since the previous one.

```lua
local roster = CacheKit:NewSnapshot(function(fill)
    for index = 1, GetNumGroupMembers() do
        local unit = "raid" .. index
        local guid = UnitGUID(unit)
        if guid then
            fill(guid, unit)
        end
    end
end, { maxEntries = 40 })

local added, removed, changed = roster:Refresh()
for index = 1, #added do
    print("joined", added[index], roster:Get(added[index]))
end
```

`read` receives a `fill(key, value)` function and calls it once for every key it can see. Nothing is read until the first `Refresh`, which reports every key as added.

`Refresh` returns three arrays of keys:

| Array | Contains |
|---|---|
| `added` | Keys reported now and not by the previous refresh. |
| `removed` | Keys reported by the previous refresh and not now. |
| `changed` | Keys whose value differs from the previous one by raw equality: no `__eq` metamethod is consulted. A new table with the same contents is a change; NaN is always a change. |

The three arrays belong to the snapshot and are **overwritten by the next refresh**: copy what you need to keep. Their order is unspecified. A refresh in which nothing changed allocates nothing, and an unchanged key costs nothing beyond the `fill` call.

`fill` refuses, at the reader's line:

- a `nil` or NaN key, or a `nil` value;
- the same key twice in one refresh;
- more than `maxEntries` keys in one refresh (`fill exceeded maxEntries (40)`);
- being called when its snapshot is not refreshing.

When `read` raises (including through one of those refusals), the keys it filled before the failure keep their new values, nothing is removed, and the error propagates unchanged out of `Refresh`. The next refresh reports against that state.

`Refresh` and `Close` refuse to run from inside the snapshot's own `read`. After `Close`, `Refresh` raises, `Get` returns `nil`, `GetCount` returns `0` and `Pairs` iterates nothing. Do not refresh a snapshot while iterating `Pairs()`.

## Error behaviour

Argument failures report the line that called the public method, never a line inside CacheKit. Messages name the method (`CacheKit:NewLru`, `CacheKit.Cache:Set`, `CacheKit.Snapshot:Refresh`, `CacheKit memoized function`, `CacheKit.Snapshot fill`). Calling a method without a receiver raises `CacheKit.Cache:Get must be called on a CacheKit cache`.

## Performance

| Operation | Cost |
|---|---|
| `Get`, `Peek`, `Delete` | O(1), no allocation. |
| `Set`, existing key | O(1), no allocation. |
| `Set`, new key | O(1); reuses an evicted or freed entry table, allocates one only when neither exists. |
| `Clear` | O(entries); entry tables are kept for reuse, up to `maxEntries`. |
| Memoised hit | O(1), no allocation. |
| `Refresh` | O(keys reported + keys stored); no allocation for unchanged keys. |

The layout behind these numbers is in [`INTERNALS.md`](INTERNALS.md).

## Embedded copies and upgrades

Several addons may embed CacheKit; Registry selects the newest compatible revision and every copy shares one facade. An upgrade happens in place: caches and snapshots created by an older copy keep their entries, statistics and subscriptions, and memoised functions, fill functions and clear-on-event callbacks an older copy created run the newer implementation.

Nothing survives `/reload`: CacheKit caches live in memory only.
