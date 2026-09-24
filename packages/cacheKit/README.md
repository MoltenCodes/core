# CacheKit

CacheKit provides bounded caches for World of Warcraft addons, so "bounded by default" is a structure you reach for instead of a rule you remember: LRU and TTL caches with negative entries, memoisation, snapshots that report what changed, a namespace tree expanded on demand, and a ring queue with an explicit overflow policy. Every cache and tree has a `maxEntries` bound; `CacheKit.UNBOUNDED` lifts it on purpose when the data is yours to bound (see *Limits* in the API). A queue's `capacity` is preallocated, so it has no unbounded form and runs up to the package-wide `maxQueueCapacity` instead.

```lua
local CacheKit = MoltenCodes.Registries[2]:Get("cacheKit", 1)

-- Least recently used, by count.
local names = CacheKit:NewLru({ maxEntries = 256 })
names:Set(guid, name)
local name = names:Get(guid)

-- The same, with an age limit. A peer that answered "nothing" is remembered
-- as a negative entry with its own age limit, so it is not asked again.
local versions = CacheKit:NewTtl({ maxEntries = 64, ttlSeconds = 300 })
versions:PutNegative(peerName, 60)
local version, outcome = versions:Get(peerName) -- nil, "negative"

-- A one-key function computed once per key. `cacheable` keeps an answer the
-- client has not finished loading out of the cache, so it is asked again.
local itemInfo, itemInfos = CacheKit:Memoize(function(itemId)
    return { name = C_Item.GetItemNameByID(itemId) }
end, {
    maxEntries = 512,
    cacheable = function(info)
        return info.name ~= nil
    end,
})
itemInfos:ClearOn("GET_ITEM_INFO_RECEIVED")

-- A namespace expanded on demand: `resolve` runs once per path, and
-- invalidating a path forgets it, everything under it and the values above it.
local settings = CacheKit:Lazy(function(profileName, section, key)
    return LoadSetting(profileName, section, key)
end, { maxEntries = 256 })
local value = settings:Get("Default", "unitFrames", "scale")
settings:Invalidate("Default", "unitFrames")

-- A bounded ring with an explicit overflow policy.
local recentMessages = CacheKit:NewQueue(50, "dropOldest")
recentMessages:Push(message)
for position, kept in recentMessages:Iterate() do
    print(position, kept)
end

-- A key-to-value map rebuilt on demand, reporting what changed.
local isSecret = issecretvalue or function()
    return false
end
local roster = CacheKit:NewSnapshot(function(fill)
    for index = 1, math.max(GetNumGroupMembers(), 1) do
        local unit = IsInRaid() and "raid" .. index
            or (index == 1 and "player" or "party" .. (index - 1))
        local guid = UnitGUID(unit)
        if guid and not isSecret(guid) then
            fill(guid, unit)
        end
    end
end, { maxEntries = 40 })
local added, removed, changed = roster:Refresh()
```

What each piece promises:

- **LRU and TTL caches.** `Get` and `Set` are O(1). `Get` hits, misses and `Set` of an existing key allocate nothing; a new key allocates one entry table only when no evicted or deleted entry is waiting on the cache's free list. `Peek` reads without marking the entry as used and without counting a hit or a miss. `Set(key, nil)` deletes the key. `nil` and NaN keys are refused at the caller's line.
- **Age limits** are measured with `GetTimePreciseSec`, the clock TimerKit uses. It is optional: on a host without it CacheKit still loads and every age limit is disabled, so a TTL cache behaves as a plain LRU cache.
- **Negative entries.** `cache:PutNegative(key, ttlSeconds)` on a cache with an age limit records that a key has no value, for `ttlSeconds` of its own. `Get` and `Peek` answer `nil, "negative"` and count a hit, so a source that said "nothing" is not asked again until the entry expires. A plain LRU cache refuses it, because nothing there would ever expire it.
- **`Memoize`** remembers `fn`'s first result per string or number key, bounded by 128 entries unless you say otherwise. A `nil` result is not remembered; return `false` to remember a negative answer. With `cacheable`, a result the predicate returns `false` or `nil` for is returned but not remembered, so an incomplete answer is computed again next time. The second return value is the cache behind the function: clear it, read its statistics, put a negative entry on it, or close it through that handle.
- **Lazy trees.** `CacheKit:Lazy(resolve, options)` is a namespace expanded on demand: `tree:Get("a", "b", "c")` calls `resolve("a", "b", "c")` once and keeps the answer; `tree:Invalidate("a", "b")` forgets that node, everything under it and the values of the nodes above it (a value derived from a subtree is stale once part of it changed), leaving siblings alone. Bounded by `maxEntries` expanded nodes, 128 by default, evicting the least recently read one.
- **Queues.** `CacheKit:NewQueue(capacity, overflow)` is a ring of `capacity` slots allocated once, with the overflow policy stated where the queue is made: `"dropOldest"`, `"dropNewest"` or `"reject"`. `Push` says whether the value was stored and which value was dropped; `Pop`, `Peek`, `Iterate`, `Clear`, `GetCount` and `GetCapacity` are O(1) per step and allocate nothing. `capacity` runs up to the package-wide `maxQueueCapacity` (1024 by default, up to 65536 through `CacheKit:SetLimits`), and refuses `UNBOUNDED` because the ring is allocated up front.
- **Limits.** Per-object bounds are options on what you create; the one package-wide limit, `maxQueueCapacity`, is changed with `CacheKit:SetLimits({ maxQueueCapacity = n })` and read back with `CacheKit:GetLimits()` (see *Limits* in the API).
- **Snapshots** hand your reader a `fill(key, value)` function and diff what it reports against the previous refresh. The three result arrays are reused, and a refresh in which nothing changed allocates nothing. A failed read rolls back the keys it added, so a snapshot never exceeds its `maxEntries`.
- **Secret values** (Retail 12.x) cannot be compared or used as table keys. Check `ClientKit:IsSecret` or `issecretvalue` before handing client values to a cache; a snapshot's `fill` refuses secrets itself.
- **`cache:ClearOn(eventName)`** clears a cache whenever a host event fires. It needs EventKit, which CacheKit finds through `Registry:Find` when you call it, and raises a clear error when EventKit is not loaded. `Close()` releases those subscriptions.
- **Statistics.** `GetStats()` returns `{ hits, misses, evictions }` as the same table on every call.

See [`docs/API.md`](docs/API.md) for the complete contract and [`docs/INTERNALS.md`](docs/INTERNALS.md) for the list, tree, ring and free-list layouts.

## Embedding

[`../../docs/EMBEDDING.md`](../../docs/EMBEDDING.md) is the addon author's guide:
directory layout, supported Interface numbers, taint, `/reload` semantics and
troubleshooting. This package's load order inside a consuming addon is:

```toc
Libs\MoltenCodes\registry\Registry.lua
Libs\MoltenCodes\cacheKit\CacheKit.lua
```

Minimum footprint: embed 2 files: `registry/Registry.lua`, `cacheKit/CacheKit.lua`.

Direct runtime dependencies: Registry API 2.
Every file above is required; omitting one makes this package raise at
load.

Optional: EventKit API 1, used only by `cache:ClearOn`. To use it, also embed
SignalKit and EventKit (see their own load order); they may load before or
after CacheKit, because CacheKit looks EventKit up when `ClearOn` is called,
not at load. The manifest names EventKit under `optionalDependencies`, which the
release load order ignores.
