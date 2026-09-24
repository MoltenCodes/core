# CacheKit API

CacheKit API generation **1** provides bounded caches: least-recently-used caches bounded by count, the same caches with an age limit and negative entries, memoisation of a one-key function, snapshots that report what changed between two reads, a namespace tree expanded on demand, a ring queue with an explicit overflow policy, and clearing a cache when a host event fires.

Implementation revision: **4**.

## Loading

Runtime files must be loaded in dependency order:

```text
Registry.lua
CacheKit.lua
```

Portable WoW code resolves the package through Registry:

```lua
local CacheKit = MoltenCodes.Registries[2]:Get("cacheKit", 1)
```

CacheKit does not rely on `require()` at runtime.

### Optional host facilities

| Facility | Used by | Without it |
|---|---|---|
| `GetTimePreciseSec` | age limits (`NewTtl`, `Memoize` with `ttlSeconds`, `PutNegative`) | CacheKit loads normally and every age limit is disabled: entries, negative ones included, never expire, and a TTL cache behaves as a plain LRU cache. |
| EventKit API 1 | `cache:ClearOn` | `ClearOn` raises at the caller: `CacheKit.Cache:ClearOn requires EventKit API 1, which is not loaded (absent)`. Everything else works. |

EventKit is looked up with `Registry:Find("eventKit", 1)` when `ClearOn` is called, not at load, so EventKit may be embedded before or after CacheKit. The manifest names it under `optionalDependencies`, which the release load order ignores; `dependencies` names Registry alone.

## Public surface

Package facade:

| Method | Purpose |
|---|---|
| `NewLru(options)` | Create a least-recently-used cache. |
| `NewTtl(options)` | Create a least-recently-used cache whose entries also expire by age. |
| `Memoize(fn, options?)` | Wrap a one-key function; returns the memoised function and its cache. |
| `NewSnapshot(read, options?)` | Create a snapshot that diffs what `read` reports. |
| `Lazy(resolve, options?)` | Create a namespace tree whose paths `resolve` expands on first read. |
| `NewQueue(capacity, overflow)` | Create a ring queue of `capacity` slots with an explicit overflow policy. |
| `SetLimits(limits)` | Change any subset of the package-wide limits (see [Limits](#limits)). |
| `GetLimits()` | Return a fresh copy of the package-wide limits. |
| `UNBOUNDED` | Sentinel a `maxEntries` option accepts to lift the bound (see [Limits](#limits)). |

Cache handles (both constructors return the same kind of handle):

| Method | Purpose |
|---|---|
| `Get(key)` | Return the live value and mark it as used; counts a hit or a miss. A live negative entry answers `nil, "negative"`. |
| `Set(key, value)` | Store `value` as the most recently used entry; `nil` deletes. |
| `PutNegative(key, ttlSeconds)` | Record that `key` has no value for `ttlSeconds`; caches with an age limit only. |
| `Peek(key)` | Return the live value without marking it or counting anything; `nil, "negative"` for a live negative entry. |
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

Lazy tree handles:

| Method | Purpose |
|---|---|
| `Get(parts...)` | Return the value at the path, calling `resolve(parts...)` on first read; counts a hit or a miss. |
| `Peek(parts...)` | Return the value at the path without resolving, marking or counting. |
| `Invalidate(parts...)` | Forget the node, its descendants and the values of its ancestors; return how many expanded nodes were forgotten. |
| `Clear()` | Forget every expanded node; return how many there were. Statistics are kept. |
| `GetCount()` | Return how many nodes are expanded. |
| `GetStats()` | Return `{ hits, misses, evictions }` (the same table every call). |
| `Close()` | Drop every node; `false` if already closed. |
| `IsClosed()` | Whether the tree is closed. |

Queue handles:

| Method | Purpose |
|---|---|
| `Push(value)` | Add `value` behind the newest; return whether it was stored, and the value dropped if one was. |
| `Pop()` | Remove and return the oldest value, or `nil`. |
| `Peek()` | Return the oldest value without removing it, or `nil`. |
| `Iterate()` | Iterate `position, value` from oldest to newest without allocating. |
| `Clear()` | Remove every value; return how many were held. |
| `GetCount()` | Return how many values are held. |
| `GetCapacity()` | Return the capacity the queue was created with. |

`CacheKit.Cache`, `CacheKit.Snapshot`, `CacheKit.LazyTree` and `CacheKit.Queue` are the shared method prototypes.

## Limits

Every cache, snapshot, lazy tree and queue is bounded by default. Per-object bounds are an option or argument on the object you create; the one package-wide limit, the largest queue a call may allocate, is set through `SetLimits` and read back through `GetLimits`.

| Limit | Default | How to open | `UNBOUNDED` allowed? | Ceiling and reason |
|---|---|---|---|---|
| `NewLru`, `NewTtl` `maxEntries` | none: required | `{ maxEntries = n }` | yes | none: the entries are your own data |
| `Memoize` `maxEntries` | `128` | `{ maxEntries = n }` | yes | none: the results are your own data |
| `NewSnapshot` `maxEntries` | `1024` | `{ maxEntries = n }` | yes | none: the keys are your own data |
| `Lazy` `maxEntries` (expanded nodes) | `128` | `{ maxEntries = n }` | yes | none: the values are your own data |
| `NewQueue` `capacity` | none: required | `NewQueue(n, overflow)`, `n` up to `maxQueueCapacity` | no: the ring is allocated when the queue is created, so a capacity has to be a size | `maxQueueCapacity` |
| `maxQueueCapacity` — largest `capacity` `NewQueue` accepts | `1024` | `CacheKit:SetLimits({ maxQueueCapacity = n })`, `n` from 1 to 65536 | no: same reason | 65536: keeps one `NewQueue` call from allocating without bound |
| free list of an unbounded cache or lazy tree | `1024` blank tables | not configurable | no | keeps an unbounded cache or tree from retaining its peak size after a `Clear` |

`maxEntries` must be an integer of at least `1` or `CacheKit.UNBOUNDED`; anything else is refused at the caller's line with `maxEntries must be a positive integer or CacheKit.UNBOUNDED`. `capacity` must be an integer from 1 to `maxQueueCapacity` and is refused with `CacheKit:NewQueue capacity must be an integer from 1 to 1024 (CacheKit:SetLimits maxQueueCapacity)`; `CacheKit.UNBOUNDED` is refused with its reason, `capacity cannot be CacheKit.UNBOUNDED: the ring is allocated when the queue is created`. A secret `maxEntries` or `capacity` (Retail 12.x) is refused with the same messages as any other invalid value, before it is compared with anything. Option tables refuse unknown fields.

```lua
local byGuid = CacheKit:NewLru({ maxEntries = CacheKit.UNBOUNDED })

-- Package-wide limits: read them back as a fresh table.
CacheKit:SetLimits({ maxQueueCapacity = 4096 })
local limits = CacheKit:GetLimits() -- { maxQueueCapacity = 4096 }
```

An unbounded cache never evicts, so it grows with every distinct key you store and only `Delete`, `Clear`, expiry and `Close` shrink it: use it only when the key set is one you bound yourself. Its free list keeps at most 1024 blank entry tables; a bounded cache needs no separate bound, because its live plus free entries never exceed `maxEntries`. An unbounded lazy tree keeps every expanded node the same way. An unbounded snapshot accepts any number of keys per refresh.

`CacheKit.UNBOUNDED` is one table kept in the package state, so every embedded copy and every revision publishes the same sentinel, and caches and trees opened with it stay unbounded across an in-place upgrade.

### `CacheKit:SetLimits(limits)`

Changes any subset of the package-wide limits; today that is `maxQueueCapacity`. The whole table is validated first, so one invalid entry changes nothing: an unrecognised name raises `CacheKit:SetLimits limits.<name> is not a recognised limit`, a value outside 1 to the ceiling raises `limits.maxQueueCapacity must be an integer from 1 to 65536`, and `CacheKit.UNBOUNDED` raises `limits.maxQueueCapacity cannot be CacheKit.UNBOUNDED: the ring is allocated when the queue is created`; a non-table raises `limits must be a table`. A secret value is refused with the out-of-range message before it is compared with anything. All at the caller's line. An empty table is accepted and changes nothing.

**The limits are shared by every consumer in the session**: every embedded copy publishes one facade and one state, so a limit one addon raises is raised for all of them, and a newer revision loaded later inherits the value set rather than resetting it. Lowering `maxQueueCapacity` never shrinks an existing queue; further `NewQueue` calls asking for more than the new value are refused until it allows them again.

`SetLimits` and `GetLimits` must be called on the facade (`CacheKit:SetLimits(...)`); another receiver raises `must be called on the CacheKit facade`.

### `CacheKit:GetLimits()`

Returns a fresh table with every package-wide limit (`{ maxQueueCapacity = 1024 }` by default). It is yours to keep or change; the next call returns another.

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

## `cache:PutNegative(key, ttlSeconds)`

Records that `key` has **no** value, for `ttlSeconds` from now. The use is a source that answered "nothing": a peer that has no version to report, a lookup that returned no row. Without a negative entry every read would ask again; with one, the cache answers for `ttlSeconds` and the source is left alone.

```lua
local versions = CacheKit:NewTtl({ maxEntries = 64, ttlSeconds = 300 })

local function versionOf(peerName)
    local version, outcome = versions:Get(peerName)
    if version ~= nil or outcome == "negative" then
        return version              -- known, or known to be nothing
    end
    version = AskPeer(peerName)     -- an ordinary miss
    if version == nil then
        versions:PutNegative(peerName, 60)
    else
        versions:Set(peerName, version)
    end
    return version
end
```

A live negative entry:

- answers `Get` with `nil, "negative"` and counts a **hit**; `Peek` answers the same and counts nothing. An ordinary miss and an ordinary hit both leave the second result `nil`, so existing callers that read one result are unaffected;
- makes a memoised function whose cache holds it return `nil` without calling `fn`;
- takes an ordinary slot: it counts towards `maxEntries` and `GetCount`, is evicted by recency like any entry, and `Set(key, value)` replaces it, `Delete` and `Clear` remove it, `PutNegative` again restarts its age;
- expires by **its own** `ttlSeconds`, independent of the cache's: shorter or longer. Expiry is lazy, as for every entry.

`ttlSeconds` is required and must be a finite number greater than zero. Only a cache with an age limit accepts negative entries: one from `NewTtl`, or from `Memoize` with `ttlSeconds`. A plain LRU cache (or a `Memoize` cache without `ttlSeconds`) refuses at the caller's line with `CacheKit.Cache:PutNegative requires a cache with an age limit (CacheKit:NewTtl, or CacheKit:Memoize with ttlSeconds)`, because nothing on such a cache would ever expire the entry and the key would read as missing until something overwrote it. A closed cache refuses with `cannot write to a closed cache`. Without `GetTimePreciseSec` a negative entry, like every entry, never expires.

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
| `hits` | `Get` calls and memoised calls answered from the cache, negative entries included. |
| `misses` | `Get` calls and memoised calls that found no live entry, including expired ones. |
| `evictions` | Live entries removed to stay within `maxEntries`. `Delete`, `Clear`, `ClearOn` and expiry are not evictions. |

`Peek` counts nothing. `Clear` keeps the counters. The same table is returned on every call for one cache, refreshed from the live counters each time; it is allocated on the first call. Copy the fields if you need to keep a reading, and do not write to the table.

## `cache:ClearOn(eventName)`

Clears the cache whenever the host event `eventName` fires, through a private EventKit scope the cache owns. Returns `true` when it connected, `false` when the cache already clears on that event. The subscriptions are bounded by the number of distinct event names.

`eventName` must be a non-empty string. When the host refuses the registration, the failure is raised at the caller's line with the host reason kept: `CacheKit.Cache:ClearOn could not connect SPELLS_CHANGED: EventKit.Scope:Connect could not register event SPELLS_CHANGED`, and a later `ClearOn` for the same event may try again. A closed cache refuses: `CacheKit.Cache:ClearOn cannot subscribe a closed cache`. When EventKit is not loaded, or its entry is retired, the error names the `Registry:Find` reason (`absent`, `generation_mismatch` or `retired`). An embedded Registry older than API 2 revision 7 has no `Find`, and `ClearOn` then raises `CacheKit.Cache:ClearOn requires Registry:Find (Registry API 2 revision 7 or newer)`.

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

Returns two values: the memoised function, and the cache behind it. The cache is an ordinary CacheKit cache and is the handle to clear the memo (`Clear`, `Delete`), read its statistics, clear it on an event, put a negative entry on it (with `ttlSeconds`), or `Close` it.

| Option | Default | Meaning |
|---|---|---|
| `maxEntries` | `128` | Most results remembered. |
| `ttlSeconds` | none | When given, a result expires this many seconds after it was computed. |
| `cacheable` | none | When given, `cacheable(result, key)` decides whether a result is remembered. |

The memoised function takes exactly one argument, a string or a number (not NaN), and refuses anything else at its caller's line. Only `fn`'s first result is remembered and returned. A `nil` result is returned but **not remembered**, so `fn` runs again for that key next time; return `false` for a negative answer you want remembered. An error from `fn` propagates unchanged and remembers nothing. `fn` may call the memoised function for other keys. A negative entry put on the cache makes the memoised function return `nil` for that key, without calling `fn`, until it expires.

### `cacheable`

Some answers are complete only later: `C_Item.GetItemInfo` returns `nil` fields until the client has loaded the item, and a "not yet" answer remembered for 128 entries is a bug that lasts the session. `cacheable` is a predicate over the result `fn` produced:

```lua
local itemInfo, cache = CacheKit:Memoize(function(itemId)
    local name, link = C_Item.GetItemInfo(itemId)
    return { name = name, link = link }
end, {
    cacheable = function(info, itemId)
        return info.name ~= nil
    end,
})
```

It is called with two arguments, `fn`'s **first** result (the one that would be stored; the memoised function returns no other) and the key, and only when that result is not `nil`, since `nil` is never remembered anyway. When it returns `false` or `nil`, the result is returned to the caller **without being remembered**, so the next call for that key runs `fn` again; when it returns anything else, the result is remembered as usual. It must be a function (`CacheKit:Memoize cacheable must be a function`); an error it raises propagates unchanged and remembers nothing; it may close the cache, in which case the result is returned without being remembered. A pass-through allocates nothing.

## `CacheKit:NewSnapshot(read, options?)`

A snapshot is a key-to-value map that `read` rebuilds on every `Refresh`, reporting what changed since the previous one.

```lua
local isSecret = issecretvalue or function()
    return false
end

-- In a raid every member is "raidN"; in a party the player is "player" and the
-- others are "party1" to "party4".
local function groupUnit(index)
    if IsInRaid() then
        return "raid" .. index
    end
    return index == 1 and "player" or "party" .. (index - 1)
end

local roster = CacheKit:NewSnapshot(function(fill)
    for index = 1, math.max(GetNumGroupMembers(), 1) do
        local unit = groupUnit(index)
        local guid = UnitGUID(unit)
        -- A GUID can be a secret value on Retail 12.x; fill refuses secrets.
        if guid and not isSecret(guid) then
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
- a secret key or value (see *Secret values*);
- the same key twice in one refresh;
- more than `maxEntries` keys in one refresh (`fill exceeded maxEntries (40)`);
- being called when its snapshot is not refreshing.

When `read` raises (including through one of those refusals):

- the keys it **added** in that refresh are removed again, so the snapshot never holds more than `maxEntries`, however many reads fail in a row;
- the keys it **changed** get back the values they had before, so the next successful refresh still reports them as changed;
- nothing is removed, because a failed read says nothing about the keys it did not reach;
- the error propagates out of `Refresh` unchanged: the same error value, re-raised with `error(failure, 0)`, so it gains no position and the traceback ends at `Refresh` rather than inside `read`. Wrap the body of `read` in `xpcall` if you need the original traceback.

The snapshot is then exactly what the last successful refresh recorded, and the next successful refresh reports every addition and change the failed one made.

`Refresh` and `Close` refuse to run from inside the snapshot's own `read`. After `Close`, `Refresh` raises, `Get` returns `nil`, `GetCount` returns `0` and `Pairs` iterates nothing. Do not refresh a snapshot while iterating `Pairs()`.

## `CacheKit:Lazy(resolve, options?)`

A lazy tree is a namespace whose values exist compactly (a saved-variables table, a data file, a remote source) and are expanded into their working form only when a path is first read. It is the structure behind "derive this on demand and forget it when its inputs change".

```lua
local settings = CacheKit:Lazy(function(profileName, section, key)
    -- Called once per distinct path; the first result is kept unless nil.
    return ExpandSetting(SavedProfiles[profileName], section, key)
end, { maxEntries = 256 })

local scale = settings:Get("Default", "unitFrames", "scale")   -- resolved
scale = settings:Get("Default", "unitFrames", "scale")         -- from the tree
settings:Invalidate("Default", "unitFrames")                   -- the section changed
```

| Option | Default | Meaning |
|---|---|---|
| `maxEntries` | `128` | Most **expanded** nodes kept; a positive integer or `CacheKit.UNBOUNDED`. |

`resolve` must be a function. A **path** is one or more parts, each a string or a number (not NaN); `1` and `"1"` are different parts. Every path method refuses an empty path (`needs at least one path part`) and a bad part (`path part 2 must be a string or a number`) at the caller's line.

### Reading

`Get(parts...)` returns the value kept for the path, marking it as the most recently read and counting a hit. When the path is not expanded it counts a miss, calls `resolve(parts...)` with the parts unchanged, keeps the **first** result and returns it; a `nil` result is returned but not kept, so the path is resolved again next time (return `false` to keep a negative answer). An error from `resolve` propagates unchanged and keeps nothing. `resolve` may call `Get` and `Invalidate` on the same tree, which is how a parent derives its value from its children; it may also close the tree, in which case its result is returned unkept.

`Peek(parts...)` returns the kept value, or `nil` when the path is not expanded, without resolving, marking or counting.

Every path is independent: expanding `("a", "b", "c")` does not expand `("a", "b")` or `("a")`, and each of those is resolved on its own first read. Nodes on the way to an expanded node exist as structure only and are not counted.

### Invalidation

`Invalidate(parts...)` says "what is at this path changed". It:

- removes the node at the path and **every descendant**, so their next read resolves again;
- forgets the value of **every ancestor** on the path, keeping the ancestor and its other children: a value an ancestor derived from its subtree is stale once part of that subtree changed, and the tree cannot know which ancestors derived and which did not, so it assumes all of them did (this is the "recursive parent invalidation" of the roadmap);
- leaves **siblings** and everything outside the path untouched;
- follows the path as far as the tree goes. When the end of the path was never expanded, the ancestors reached still lose their values, because a change below them is still a change below them;
- returns how many expanded nodes were forgotten, `0` when nothing on the path was expanded.

```lua
tree:Get("a")               -- expanded: a
tree:Get("a", "b", "c")     -- expanded: a/b/c
tree:Get("a", "x")          -- expanded: a/x
tree:Invalidate("a", "b")   -- returns 2: forgets a/b/c and the value of a; a/x survives
```

`Clear()` forgets every expanded node and returns how many there were, keeping the statistics.

### Bound and eviction

`maxEntries` counts expanded nodes. When a read would expand one more, the **least recently read** expanded node is forgotten first and counted in `evictions`; its structure stays while a descendant is expanded and is pruned otherwise. Structure is bounded by construction: after every operation, each node without a value has an expanded descendant, so the tree never holds more than `maxEntries` times the deepest path in nodes. An unbounded tree never evicts.

### Closing

`Close()` drops every node and blank node and returns `false` when the tree was already closed. A closed tree answers `Peek` with `nil`, `Invalidate` and `Clear` with `0`, `GetCount` with `0`, and refuses `Get` at the caller's line (`cannot expand a closed tree`), because `Get` would call `resolve`.

## `CacheKit:NewQueue(capacity, overflow)`

A bounded first-in, first-out queue over a ring of `capacity` slots allocated once, at construction. The overflow policy is stated where the queue is created, so what happens when it is full is a decision in the consumer's code rather than a default it has to remember.

```lua
local recent = CacheKit:NewQueue(50, "dropOldest")
recent:Push(message)                -- true, or true plus the message dropped
for position, kept in recent:Iterate() do
    print(position, kept)           -- oldest first
end
local oldest = recent:Pop()
```

| Argument | Meaning |
|---|---|
| `capacity` | Slots allocated, an integer from `1` to the package-wide `maxQueueCapacity` (1024 by default, up to 65536; see [Limits](#limits)). `CacheKit.UNBOUNDED` is refused, because the ring is allocated when the queue is created; a queue with no bound is not a ring. |
| `overflow` | What a full queue does on `Push`: `"dropOldest"`, `"dropNewest"` or `"reject"`. Required. |

Both are validated at the caller's line: `CacheKit:NewQueue capacity must be an integer from 1 to 1024 (CacheKit:SetLimits maxQueueCapacity)`, `CacheKit:NewQueue capacity cannot be CacheKit.UNBOUNDED: the ring is allocated when the queue is created`, `CacheKit:NewQueue overflow must be "dropOldest", "dropNewest" or "reject"`.

`Push(value)` returns whether the value was stored, and the value dropped when one was:

| Policy | On a full queue | Returns |
|---|---|---|
| `"dropOldest"` | Stores `value`; the oldest value is forgotten. | `true, oldest` |
| `"dropNewest"` | Stores nothing; `value` is the one forgotten. | `false, value` |
| `"reject"` | Stores nothing; the caller still holds `value`. | `false` |

On a queue with room every policy stores the value and returns `true`. `value` must not be `nil` (`CacheKit.Queue:Push value must not be nil`); `false` is an ordinary value.

`Pop()` removes and returns the oldest value, `Peek()` returns it without removing it; both return `nil` on an empty queue, so a queue that may hold `false` distinguishes "empty" through `GetCount()`. `Iterate()` yields `position, value` from the oldest (`position` `1`) to the newest, allocates nothing, and must not be interleaved with `Push` or `Pop`. `Clear()` empties the queue and returns how many values it held; `GetCount()` and `GetCapacity()` report the count and the capacity.

Every operation is O(1) per step and allocates nothing after construction. A popped or cleared slot is blanked, so the queue retains nothing it no longer holds.

## Secret values

On Retail 12.x the client hands tainted code **secret values** in combat and instanced content: unit names, GUIDs, health and aura data among them. A secret raises a Lua error when it is compared with a value of its own type (`==`, `~=`, `<`, `<=` and `rawequal` alike) or used as a table key, to read as well as to store, and a cache or snapshot does both with every key (a snapshot also compares every value). Comparing a secret with `nil` or with a value of another type answers without raising, and storing one as a table value is fine (measured on Retail 12.1.0 b69933). The rule from [`docs/EMBEDDING.md`](../../../docs/EMBEDDING.md#secret-values-retail-12x) applies: ask `ClientKit:IsSecret(value)`, or `issecretvalue(value)` where it exists, before handing a value from the client to CacheKit, and skip or defer the secret ones.

```lua
local isSecret = issecretvalue or function()
    return false
end
```

`fill` checks for you when the client has `issecretvalue`: it refuses a secret key or value at the reader's line (`CacheKit.Snapshot fill key must not be a secret value`) before any comparison, and that refusal fails the refresh like any other. Cache methods (`Get`, `Set`, `PutNegative`, `Peek`, `Delete`), memoised functions, lazy tree paths, queue values and `snapshot:Get` do not probe, to keep their hot paths free of an extra call; a secret key or path part reaching them raises the client's own error, `attempted to index a table that cannot be indexed with secret keys` (measured on Retail 12.1.0 b69933; a queue only stores its values and never compares them, so a secret value survives `Push` and `Pop` unchanged). Cache values are handled the same way: a secret value, as opposed to a secret key, survives `Set`, `Get`, `Peek` and a memoised call unchanged and still secret. The negative-entry check compares the stored value by identity with CacheKit's own marker table, and the client allows that for a secret number or string, because the two differ in type; it would not allow comparing a secret with a number or string. A secret `maxEntries`, `capacity` or `SetLimits` value is refused at the caller's line.

## Error behaviour

Argument failures report the line that called the public method, never a line inside CacheKit. Messages name the method (`CacheKit:NewLru`, `CacheKit.Cache:Set`, `CacheKit.Snapshot:Refresh`, `CacheKit.LazyTree:Get`, `CacheKit.Queue:Push`, `CacheKit memoized function`, `CacheKit.Snapshot fill`). Calling a method without a receiver raises `CacheKit.Cache:Get must be called on a CacheKit cache`, `... on a CacheKit snapshot`, `... on a CacheKit lazy tree` or `... on a CacheKit queue`.

## Performance

| Operation | Cost |
|---|---|
| `Get`, `Peek`, `Delete` | O(1), no allocation. |
| `Set`, existing key | O(1), no allocation. |
| `Set`, new key | O(1); reuses an evicted or freed entry table, allocates one only when neither exists. |
| `Clear` | O(entries); entry tables are kept for reuse, up to `maxEntries` (1024 for an unbounded cache). |
| Memoised hit | O(1), no allocation. A result `cacheable` lets through allocates nothing of CacheKit's own. |
| `PutNegative` | As `Set`: O(1), reuses a freed entry, allocates one only when none exists. A negative hit allocates nothing. |
| Lazy `Get` hit, `Peek` | O(path depth), no allocation. |
| Lazy `Get` miss | O(path depth) plus `resolve`; reuses blank nodes, allocates a node only when none is free (invalidation frees structural nodes in bulk, so re-expanding a deep path may allocate), and a `children` table once per node that gains its first child. |
| Lazy `Invalidate` | O(nodes removed + path depth); allocates nothing. |
| Queue `Push`, `Pop`, `Peek`, each `Iterate` step | O(1), no allocation. |
| Queue `Clear` | O(count), no allocation. |
| `Refresh` | O(keys reported + keys stored); no allocation for unchanged keys. |

The layout behind these numbers is in [`INTERNALS.md`](INTERNALS.md).

## Embedded copies and upgrades

Several addons may embed CacheKit; Registry selects the newest compatible revision and every copy shares one facade. An upgrade happens in place: caches, snapshots, lazy trees and queues created by an older copy keep their contents, statistics and subscriptions, and memoised functions, fill functions and clear-on-event callbacks an older copy created run the newer implementation. Revision 2 upgrades revision 1 state by adding the lazy tree and queue metatables, the negative-entry marker and the default package-wide limits; revision 1 caches gain `PutNegative` without being touched. Revision 3 keeps the revision 2 state as it is and replaces the methods only.

Nothing survives `/reload`: CacheKit caches live in memory only.
