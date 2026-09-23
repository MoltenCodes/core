# CacheKit

CacheKit provides bounded caches for World of Warcraft addons, so "bounded by default" is a structure you reach for instead of a rule you remember. Every cache has a `maxEntries` bound; `CacheKit.UNBOUNDED` lifts it on purpose when the data is yours to bound (see *Limits* in the API).

```lua
local CacheKit = MoltenCodes.Registries[2]:Get("cacheKit", 1)

-- Least recently used, by count.
local names = CacheKit:NewLru({ maxEntries = 256 })
names:Set(guid, name)
local name = names:Get(guid)

-- The same, with an age limit.
local ranges = CacheKit:NewTtl({ maxEntries = 64, ttlSeconds = 0.5 })

-- A one-key function computed once per key.
local spellName, spellNames = CacheKit:Memoize(function(spellId)
    return C_Spell.GetSpellName(spellId) or false
end, { maxEntries = 512 })
spellNames:ClearOn("SPELLS_CHANGED")

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
- **`Memoize`** remembers `fn`'s first result per string or number key, bounded by 128 entries unless you say otherwise. A `nil` result is not remembered; return `false` to remember a negative answer. The second return value is the cache behind the function: clear it, read its statistics, or close it through that handle.
- **Snapshots** hand your reader a `fill(key, value)` function and diff what it reports against the previous refresh. The three result arrays are reused, and a refresh in which nothing changed allocates nothing. A failed read rolls back the keys it added, so a snapshot never exceeds its `maxEntries`.
- **Secret values** (Retail 12.x) cannot be compared or used as table keys. Check `ClientKit:IsSecret` or `issecretvalue` before handing client values to a cache; a snapshot's `fill` refuses secrets itself.
- **`cache:ClearOn(eventName)`** clears a cache whenever a host event fires. It needs EventKit, which CacheKit finds through `Registry:Find` when you call it, and raises a clear error when EventKit is not loaded. `Close()` releases those subscriptions.
- **Statistics.** `GetStats()` returns `{ hits, misses, evictions }` as the same table on every call.

See [`docs/API.md`](docs/API.md) for the complete contract and [`docs/INTERNALS.md`](docs/INTERNALS.md) for the list and free-list layout.

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
