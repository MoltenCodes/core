-- MoltenCodes CacheKit
--
-- Bounded caches for World of Warcraft addons, so "bounded by default" is a
-- structure a consumer reaches for instead of a rule it has to remember:
-- least-recently-used caches bounded by count, the same caches with an age
-- limit, memoisation of a one-key function, snapshots that report what changed
-- between two reads, and clearing a cache when a host event fires.
--
-- CacheKit is pure Lua apart from two optional host facilities: the
-- `GetTimePreciseSec` clock (without it, age limits are disabled) and EventKit,
-- found through `Registry:Find` only when `cache:ClearOn` is called.
--
-- Contents
-- --------
--   Constants ............. identity, defaults, option keys, method lists
--   Public types .......... LuaCATS declarations for the published surface
--   Dependencies .......... Registry, the monotonic clock
--   Validation ............ public-surface and shared-state predicates
--   Bootstrap ............. Registry registration and inherited state
--   Argument checks ....... receivers, keys, option tables, bounds
--   Entry list ............ the intrusive recency list and the free list
--   Cache internals ....... lookup, store, clear, construction
--   Clear-on-event ........ optional EventKit resolution and the callback
--   Cache methods ......... the handle a cache owner receives
--   Memoisation ........... the memoised call path
--   Snapshot internals .... fill, refresh, the diff arrays
--   Snapshot methods ...... the handle a snapshot owner receives
--   Package public API .... the facade published through Registry
--   Commit ................ prototype/facade assignment and self-check
--
-- Layout and invariants are described in `docs/INTERNALS.md`.

-- Constants ------------------------------------------------------------------

local PACKAGE_NAME = "cacheKit"
local API_GENERATION = 1
local IMPLEMENTATION_REVISION = 1
local REQUIRED_REGISTRY_API = 2
local OPTIONAL_EVENTKIT_API = 1
local STATE_SCHEMA = 1

-- Every cache and snapshot records the layout it was built with, so a later
-- revision that changes the layout can upgrade old objects lazily, the way
-- PoolKit upgrades pools, instead of guessing from which fields exist.
local CACHE_SCHEMA = 1
local SNAPSHOT_SCHEMA = 1

-- `Memoize` is the one constructor where a caller may omit the bound. 128 is
-- the same default PoolKit retains, so the two bounds are memorable together.
local DEFAULT_MEMOIZE_MAX_ENTRIES = 128

-- A snapshot mirrors something the host already bounds (group members,
-- nameplates, frames); the default only has to stop a runaway `read`.
local DEFAULT_SNAPSHOT_MAX_ENTRIES = 1024

-- The complete set of fields each option table accepts. File-local constants
-- keep option validation allocation-free.
local LRU_OPTION_KEYS = { maxEntries = true }
local TTL_OPTION_KEYS = { maxEntries = true, ttlSeconds = true }
local MEMOIZE_OPTION_KEYS = { maxEntries = true, ttlSeconds = true }
local SNAPSHOT_OPTION_KEYS = { maxEntries = true }

-- The published surface, listed once so the public-surface predicate reads as
-- a checklist instead of a long boolean expression.
local FACADE_METHODS = { "NewLru", "NewTtl", "Memoize", "NewSnapshot" }
local CACHE_METHODS = {
    "Get",
    "Set",
    "Peek",
    "Delete",
    "Clear",
    "GetCount",
    "GetStats",
    "ClearOn",
    "Close",
    "IsClosed",
}
local SNAPSHOT_METHODS = { "Refresh", "Get", "GetCount", "Pairs", "Close", "IsClosed" }

-- Public types ---------------------------------------------------------------
--
-- CacheKit publishes its methods by writing them onto Registry-owned prototype
-- tables, so the editor-facing contract is declared here as LuaCATS classes
-- rather than inferred from those assignments.

---Option table accepted by `CacheKit:NewLru`.
---@class CacheKit.LruOptions
---@field maxEntries integer Required. The most entries the cache holds; at least `1`.

---Option table accepted by `CacheKit:NewTtl`.
---@class CacheKit.TtlOptions
---@field maxEntries integer Required. The most entries the cache holds; at least `1`.
---@field ttlSeconds number Required. Seconds an entry stays valid after it was last set.

---Option table accepted by `CacheKit:Memoize`.
---@class CacheKit.MemoizeOptions
---@field maxEntries integer? Defaults to `128`.
---@field ttlSeconds number? When given, remembered results expire after this many seconds.

---Option table accepted by `CacheKit:NewSnapshot`.
---@class CacheKit.SnapshotOptions
---@field maxEntries integer? The most keys one read may fill. Defaults to `1024`.

---Counters of one cache. `GetStats` returns the same table on every call.
---@class CacheKit.Stats
---@field hits integer `Get` calls (and memoised calls) answered from the cache.
---@field misses integer `Get` calls (and memoised calls) that found nothing live.
---@field evictions integer Live entries removed to stay within `maxEntries`.

---A memoised function: one string or number key in, the remembered result out.
---@alias CacheKit.Memoized fun(key: string|number): any

---The function a snapshot calls to report one key and its current value.
---@alias CacheKit.Fill fun(key: any, value: any)

---The caller's reader: it calls `fill(key, value)` once per key it can see.
---@alias CacheKit.Read fun(fill: CacheKit.Fill)

---A bounded least-recently-used cache, optionally with an age limit.
---@class CacheKit.Cache
---@field Get fun(self: CacheKit.Cache, key: any): any
---@field Set fun(self: CacheKit.Cache, key: any, value: any)
---@field Peek fun(self: CacheKit.Cache, key: any): any
---@field Delete fun(self: CacheKit.Cache, key: any): boolean
---@field Clear fun(self: CacheKit.Cache): integer
---@field GetCount fun(self: CacheKit.Cache): integer
---@field GetStats fun(self: CacheKit.Cache): CacheKit.Stats
---@field ClearOn fun(self: CacheKit.Cache, eventName: string): boolean
---@field Close fun(self: CacheKit.Cache): boolean
---@field IsClosed fun(self: CacheKit.Cache): boolean

---A key-to-value map rebuilt by a caller's reader, reporting what changed.
---@class CacheKit.Snapshot
---@field Refresh fun(self: CacheKit.Snapshot): any[], any[], any[]
---@field Get fun(self: CacheKit.Snapshot, key: any): any
---@field GetCount fun(self: CacheKit.Snapshot): integer
---@field Pairs fun(self: CacheKit.Snapshot): (fun(table: table, key: any): any, any), table?, nil
---@field Close fun(self: CacheKit.Snapshot): boolean
---@field IsClosed fun(self: CacheKit.Snapshot): boolean

---The CacheKit package facade published through Registry.
---@class CacheKit
---@field API integer Public API generation.
---@field REVISION integer Compatible implementation revision.
---@field Cache CacheKit.Cache Shared cache prototype.
---@field Snapshot CacheKit.Snapshot Shared snapshot prototype.
---@field NewLru fun(self: CacheKit, options: CacheKit.LruOptions): CacheKit.Cache
---@field NewTtl fun(self: CacheKit, options: CacheKit.TtlOptions): CacheKit.Cache
---@field Memoize fun(self: CacheKit, fn: fun(key: string|number): any, options: CacheKit.MemoizeOptions?): CacheKit.Memoized, CacheKit.Cache
---@field NewSnapshot fun(self: CacheKit, read: CacheKit.Read, options: CacheKit.SnapshotOptions?): CacheKit.Snapshot

-- Dependencies ---------------------------------------------------------------

-- The shared MoltenCodes namespace is the one documented global handoff point between independently embedded copies.
-- selene: allow(global_usage)
local namespace = rawget(_G, "MoltenCodes")
local generations = type(namespace) == "table" and rawget(namespace, "Registries") or nil

-- Ask for Registry by generation and fall back to the alias. A future Registry
-- API generation takes over `MoltenCodes.Registry`, so reading the alias first
-- would hand this file a facade whose contract it was not written against.
local Registry = type(generations) == "table" and rawget(generations, REQUIRED_REGISTRY_API) or nil
if Registry == nil and type(namespace) == "table" then
    Registry = rawget(namespace, "Registry")
end
if type(Registry) ~= "table" or rawget(Registry, "API") ~= REQUIRED_REGISTRY_API then
    error("MoltenCodes CacheKit requires Registry API 2 to be loaded first", 2)
end

local bootstrapPackage = rawget(Registry, "Bootstrap")
if type(bootstrapPackage) ~= "function" then
    error("MoltenCodes CacheKit requires a valid Registry API 2 facade", 2)
end

-- Ages are measured on the same monotonic wall clock TimerKit reads.
-- `GetTime()` is frame-quantised and `debugprofilestop` is CPU time, so neither
-- measures how old an answer is. The clock is optional, as it is for TimerKit:
-- a host without it loads CacheKit normally and every age limit is disabled, so
-- a TTL cache behaves as a plain LRU cache. Requiring it would add a host
-- facility inside API generation 1.
-- GetTimePreciseSec is a World of Warcraft client API reachable only through the global table.
-- selene: allow(global_usage)
local nativeGetTimePreciseSec = rawget(_G, "GetTimePreciseSec")
if type(nativeGetTimePreciseSec) ~= "function" then
    nativeGetTimePreciseSec = nil
end

-- Retail 12.x hands tainted code secret values that raise when compared or used
-- as a table key. A snapshot does both with what its reader reports, so `fill`
-- asks this probe first and refuses a secret with a message naming CacheKit
-- instead of a host error inside it. Clients without secret values have no
-- probe, and nothing there is secret.
-- issecretvalue is a World of Warcraft client API reachable only through the global table.
-- selene: allow(global_usage)
local nativeIsSecretValue = rawget(_G, "issecretvalue")
if type(nativeIsSecretValue) ~= "function" then
    nativeIsSecretValue = nil
end

-- Validation -----------------------------------------------------------------

---Whether every name in `methodNames` is a function field of `prototype`.
---@param prototype table
---@param methodNames string[]
---@return boolean
local function hasMethods(prototype, methodNames)
    for index = 1, #methodNames do
        if type(rawget(prototype, methodNames[index])) ~= "function" then
            return false
        end
    end
    return true
end

---Whether `implementation` exposes the complete CacheKit API 1 surface.
---@param implementation any shared package table handed back by Registry
---@return boolean
local function validatePublicSurface(implementation)
    if
        type(implementation) ~= "table"
        or rawget(implementation, "API") ~= API_GENERATION
        or type(rawget(implementation, "REVISION")) ~= "number"
        or type(rawget(implementation, "Cache")) ~= "table"
        or type(rawget(implementation, "Snapshot")) ~= "table"
    then
        return false
    end

    return hasMethods(implementation, FACADE_METHODS)
        and hasMethods(rawget(implementation, "Cache"), CACHE_METHODS)
        and hasMethods(rawget(implementation, "Snapshot"), SNAPSHOT_METHODS)
end

---Whether `currentState` has the fields every API 1 revision shares.
---@param currentState any
---@return boolean
local function validateStateBase(currentState)
    return type(currentState) == "table"
        and rawget(currentState, "schema") == STATE_SCHEMA
        and type(rawget(currentState, "dispatch")) == "table"
        and type(rawget(currentState, "runtimeRevision")) == "number"
        and type(rawget(currentState, "cacheMetatable")) == "table"
        and type(rawget(currentState, "snapshotMetatable")) == "table"
end

---Whether `implementation` carries package state of this revision's schema.
---@param implementation table
---@return boolean
local function validateCurrentState(implementation)
    return validateStateBase(rawget(implementation, "_state"))
end

-- Bootstrap ------------------------------------------------------------------

-- `Registry:Bootstrap` owns the reconciliation every embedded package repeats:
-- look the package up, refuse to reinterpret state owned by a newer revision,
-- and register this one. What stays here is what only CacheKit can answer.
local CacheKit, previousRevision, selected = bootstrapPackage(Registry, {
    package = PACKAGE_NAME,
    api = API_GENERATION,
    revision = IMPLEMENTATION_REVISION,
    label = "MoltenCodes CacheKit",
    validatePublicSurface = validatePublicSurface,
    validateState = validateCurrentState,
})

if CacheKit == nil then
    -- An equal or newer compatible revision already owns the shared package table.
    return selected
end

local Cache = rawget(CacheKit, "Cache")
local Snapshot = rawget(CacheKit, "Snapshot")
local state = rawget(CacheKit, "_state")

if previousRevision == nil then
    if Cache ~= nil or Snapshot ~= nil or state ~= nil then
        error("MoltenCodes CacheKit package state is corrupted or incomplete", 2)
    end

    Cache = {}
    Snapshot = {}
    state = {
        schema = STATE_SCHEMA,
        -- Closures CacheKit hands out (memoised functions, snapshot fill
        -- functions, clear-on-event callbacks) call through this table, so a
        -- newer revision replaces the behaviour behind closures an older
        -- revision created.
        dispatch = {},
        runtimeRevision = 0,
        cacheMetatable = {},
        snapshotMetatable = {},
    }
    rawset(CacheKit, "Cache", Cache)
    rawset(CacheKit, "Snapshot", Snapshot)
    rawset(CacheKit, "_state", state)
elseif type(Cache) ~= "table" or type(Snapshot) ~= "table" or not validateStateBase(state) then
    error("MoltenCodes CacheKit package state is corrupted or incomplete", 2)
end

-- The metatables and prototypes are kept across upgrades, so caches and
-- snapshots built by an older copy keep their entries and gain this copy's
-- methods without being replaced.
local CACHE_METATABLE = rawget(state, "cacheMetatable")
local SNAPSHOT_METATABLE = rawget(state, "snapshotMetatable")
local dispatch = rawget(state, "dispatch")
rawset(CACHE_METATABLE, "__index", Cache)
rawset(SNAPSHOT_METATABLE, "__index", Snapshot)

-- Argument checks ------------------------------------------------------------
--
-- Argument validation raises with an explicit stack level so the reported
-- position is the line that called the public method, never a line inside
-- CacheKit. `level` is always the value `error` needs *inside the function that
-- receives it*, so every further hop towards `error` adds exactly one.

---@param cache any receiver the public method was called on
---@param methodName string public method name, used in the argument error
---@param level integer stack level the failure is reported at
local function validateCache(cache, methodName, level)
    if type(cache) ~= "table" or getmetatable(cache) ~= CACHE_METATABLE then
        error(methodName .. " must be called on a CacheKit cache", level)
    end
end

---@param snapshot any receiver the public method was called on
---@param methodName string public method name, used in the argument error
---@param level integer stack level the failure is reported at
local function validateSnapshot(snapshot, methodName, level)
    if type(snapshot) ~= "table" or getmetatable(snapshot) ~= SNAPSHOT_METATABLE then
        error(methodName .. " must be called on a CacheKit snapshot", level)
    end
end

---Refuse the two values Lua cannot use as a table key.
---@param key any
---@param label string what the key belongs to, used in the argument error
---@param level integer stack level the failure is reported at
local function validateKey(key, label, level)
    if key == nil then
        error(label .. " key must not be nil", level)
    end
    if key ~= key then
        error(label .. " key must not be NaN", level)
    end
end

---@param value any
---@param label string argument description, used in the argument error
---@param level integer stack level the failure is reported at
local function validateNonEmptyString(value, label, level)
    if type(value) ~= "string" or value == "" then
        error(label .. " must be a non-empty string", level)
    end
end

---Refuse a non-table option table and any field outside `allowedKeys`.
---@param options any
---@param allowedKeys table<string, true>
---@param methodName string public method name, used in the argument errors
---@param level integer stack level the failures are reported at
local function validateOptionKeys(options, allowedKeys, methodName, level)
    if type(options) ~= "table" then
        error(methodName .. " options must be a table", level)
    end

    -- Report the alphabetically first unknown field without allocating: track
    -- the smallest key seen instead of collecting and sorting every offender.
    local firstUnknown = nil
    for key in next, options do
        if allowedKeys[key] ~= true then
            local text = tostring(key)
            if firstUnknown == nil or text < firstUnknown then
                firstUnknown = text
            end
        end
    end
    if firstUnknown ~= nil then
        error(methodName .. ' options contains unknown field "' .. firstUnknown .. '"', level)
    end
end

---@param value any
---@param methodName string public method name, used in the argument error
---@param level integer stack level the failure is reported at
local function validateMaxEntries(value, methodName, level)
    if value == nil then
        error(methodName .. " maxEntries is required", level)
    end
    if
        type(value) ~= "number"
        or value ~= value
        or value < 1
        or value == math.huge
        or math.floor(value) ~= value
    then
        error(methodName .. " maxEntries must be a positive integer", level)
    end
end

---@param value any
---@param methodName string public method name, used in the argument error
---@param level integer stack level the failure is reported at
local function validateTtlSeconds(value, methodName, level)
    if value == nil then
        error(methodName .. " ttlSeconds is required", level)
    end
    if type(value) ~= "number" or value ~= value or value <= 0 or value == math.huge then
        error(methodName .. " ttlSeconds must be a finite number greater than zero", level)
    end
end

-- Entry list -----------------------------------------------------------------
--
-- A cache is a hash from key to entry plus an intrusive doubly linked list of
-- those same entries ordered by recency: `_newest` is the entry used last,
-- `_oldest` the next one to evict. Entries are plain tables of fixed shape
-- (`key`, `value`, `newer`, `older`, `expiresAt`), created with every field so
-- relinking never rehashes them. `false` marks an absent link or no expiry.

---@class CacheKit.Entry
---@field key any
---@field value any
---@field newer CacheKit.Entry|false
---@field older CacheKit.Entry|false
---@field expiresAt number|false

---@return CacheKit.Entry
local function newEntry()
    return { key = false, value = false, newer = false, older = false, expiresAt = false }
end

---Make `entry`, currently unlinked, the most recently used entry.
---@param cache table
---@param entry CacheKit.Entry
local function linkNewest(cache, entry)
    local newest = rawget(cache, "_newest")
    entry.newer = false
    entry.older = newest
    if newest == false then
        rawset(cache, "_oldest", entry)
    else
        newest.newer = entry
    end
    rawset(cache, "_newest", entry)
end

---Take `entry` out of the recency list, leaving the hash untouched.
---@param cache table
---@param entry CacheKit.Entry
local function unlink(cache, entry)
    local newer = entry.newer
    local older = entry.older
    if newer == false then
        rawset(cache, "_newest", older)
    else
        newer.older = older
    end
    if older == false then
        rawset(cache, "_oldest", newer)
    else
        older.newer = newer
    end
    entry.newer = false
    entry.older = false
end

---Mark `entry` as used now.
---@param cache table
---@param entry CacheKit.Entry
local function touch(cache, entry)
    if rawget(cache, "_newest") ~= entry then
        unlink(cache, entry)
        linkNewest(cache, entry)
    end
end

---Drop what an unlinked entry references and keep its table for reuse.
---
---No bound check is needed: an entry is recycled only when the live count
---drops by one, and a new key takes from the free list before it allocates, so
---live entries plus free entries never exceed `maxEntries`.
---@param cache table
---@param entry CacheKit.Entry
local function recycle(cache, entry)
    entry.key = false
    entry.value = false
    entry.expiresAt = false

    local freeCount = rawget(cache, "_freeCount") + 1
    rawget(cache, "_free")[freeCount] = entry
    rawset(cache, "_freeCount", freeCount)
end

---Return a blank entry, from the free list when it has one.
---@param cache table
---@return CacheKit.Entry
local function takeEntry(cache)
    local freeCount = rawget(cache, "_freeCount")
    if freeCount == 0 then
        return newEntry()
    end

    local free = rawget(cache, "_free")
    local entry = free[freeCount]
    free[freeCount] = nil
    rawset(cache, "_freeCount", freeCount - 1)
    return entry
end

-- Cache internals ------------------------------------------------------------

---Whether an entry's age limit has passed. Entries without a limit, and every
---entry on a host without a clock, never expire.
---@param entry CacheKit.Entry
---@return boolean
local function isExpired(entry)
    local expiresAt = entry.expiresAt
    return expiresAt ~= false
        and nativeGetTimePreciseSec ~= nil
        and nativeGetTimePreciseSec() >= expiresAt
end

---The expiry instant for an entry set now, or `false` for no age limit.
---@param cache table
---@return number|false
local function expiryForNow(cache)
    local ttlSeconds = rawget(cache, "_ttlSeconds")
    if ttlSeconds == false or nativeGetTimePreciseSec == nil then
        return false
    end
    return nativeGetTimePreciseSec() + ttlSeconds
end

---Remove a stored entry from the hash and the list and recycle it.
---@param cache table
---@param entry CacheKit.Entry
local function removeEntry(cache, entry)
    unlink(cache, entry)
    rawget(cache, "_entries")[entry.key] = nil
    rawset(cache, "_count", rawget(cache, "_count") - 1)
    recycle(cache, entry)
end

---Return the live entry for `key`, counting a hit or a miss. A hit becomes the
---most recently used entry; an expired entry is removed and counts as a miss.
---The caller has checked that the cache is open.
---@param cache table
---@param key any
---@return CacheKit.Entry|nil
local function lookup(cache, key)
    local entry = rawget(cache, "_entries")[key]
    if entry ~= nil and isExpired(entry) then
        removeEntry(cache, entry)
        entry = nil
    end

    if entry == nil then
        rawset(cache, "_misses", rawget(cache, "_misses") + 1)
        return nil
    end

    touch(cache, entry)
    rawset(cache, "_hits", rawget(cache, "_hits") + 1)
    return entry
end

---Store a non-nil `value` under `key`, evicting the least recently used entry
---when the cache is full. Allocates only when a new key finds no free entry.
---The caller has checked that the cache is open.
---@param cache table
---@param key any
---@param value any
local function store(cache, key, value)
    local entries = rawget(cache, "_entries")
    local expiresAt = expiryForNow(cache)

    local entry = entries[key]
    if entry ~= nil then
        entry.value = value
        entry.expiresAt = expiresAt
        touch(cache, entry)
        return
    end

    if rawget(cache, "_count") >= rawget(cache, "_maxEntries") then
        -- Reuse the evicted entry's table directly: the free list is empty
        -- whenever the cache is full, because live plus free never exceeds
        -- the bound.
        entry = rawget(cache, "_oldest")
        if not isExpired(entry) then
            rawset(cache, "_evictions", rawget(cache, "_evictions") + 1)
        end
        unlink(cache, entry)
        entries[entry.key] = nil
        rawset(cache, "_count", rawget(cache, "_count") - 1)
    else
        entry = takeEntry(cache)
    end

    entry.key = key
    entry.value = value
    entry.expiresAt = expiresAt
    linkNewest(cache, entry)
    entries[key] = entry
    rawset(cache, "_count", rawget(cache, "_count") + 1)
end

---Remove every entry, keeping the entry tables on the free list.
---@param cache table
---@return integer removed
local function clearEntries(cache)
    local entries = rawget(cache, "_entries")
    local entry = rawget(cache, "_newest")
    local removed = 0

    while entry ~= false do
        local older = entry.older
        entries[entry.key] = nil
        entry.newer = false
        entry.older = false
        recycle(cache, entry)
        removed = removed + 1
        entry = older
    end

    rawset(cache, "_newest", false)
    rawset(cache, "_oldest", false)
    rawset(cache, "_count", 0)
    return removed
end

---Build an open cache. Every private field exists from the start, so no later
---write adds a key to the cache table.
---@param maxEntries integer
---@param ttlSeconds number|false `false` for no age limit
---@return CacheKit.Cache
local function newCache(maxEntries, ttlSeconds)
    local cache = {
        _schema = CACHE_SCHEMA,
        _entries = {},
        _newest = false,
        _oldest = false,
        _count = 0,
        _maxEntries = maxEntries,
        _ttlSeconds = ttlSeconds,
        _free = {},
        _freeCount = 0,
        _hits = 0,
        _misses = 0,
        _evictions = 0,
        _statsView = false,
        _eventScope = false,
        _clearOnEvents = false,
        _clearCallback = false,
        _closed = false,
    }
    return setmetatable(cache, CACHE_METATABLE)
end

-- Clear-on-event -------------------------------------------------------------

---Resolve EventKit when a caller first asks for clear-on-event. Resolving at
---call time rather than at load keeps EventKit optional and lets it load after
---CacheKit.
---@param methodName string public method name, used in the failure
---@param level integer stack level the failure is reported at
---@return table EventKit
local function resolveEventKit(methodName, level)
    local findPackage = rawget(Registry, "Find")
    if type(findPackage) ~= "function" then
        error(methodName .. " requires Registry:Find (Registry API 2 revision 7 or newer)", level)
    end

    local EventKit, reason = findPackage(Registry, "eventKit", OPTIONAL_EVENTKIT_API)
    if EventKit == nil then
        error(
            methodName
                .. " requires EventKit API 1, which is not loaded ("
                .. tostring(reason)
                .. ")",
            level
        )
    end
    if type(rawget(EventKit, "CreateScope")) ~= "function" then
        error(methodName .. " requires a valid EventKit API 1 facade", level)
    end
    return EventKit
end

---Return an error value as text without the `file:line: ` prefix `error` adds,
---so a re-raised failure carries one position: the caller's.
---@param failure any
---@return string
local function withoutPosition(failure)
    local text = tostring(failure)
    local stripped = text:match("^[^\n]-:%d+: (.*)$")
    return stripped or text
end

---Build the one callback a cache connects to every event it clears on. It
---calls through the shared dispatch table so an upgrade replaces its behaviour.
---@param cache table
---@return fun()
local function newClearCallback(cache)
    return function()
        local clearOnEvent = rawget(dispatch, "clearOnEvent")
        clearOnEvent(cache)
    end
end

---Clear a cache because one of its events fired. EventKit may still deliver
---to a cache closed during the dispatch in flight, so a closed cache is left
---alone.
---@param cache table
local function clearOnEvent(cache)
    if rawget(cache, "_closed") ~= true then
        clearEntries(cache)
    end
end

-- Cache methods --------------------------------------------------------------

---Return the value stored under `key` and mark it as used, or `nil`.
---
---Counts a hit or a miss. On a TTL cache an entry older than `ttlSeconds` is
---removed and counts as a miss. A closed cache returns `nil` and counts nothing.
---@param self CacheKit.Cache
---@param key any any value except `nil` and NaN
---@return any value
local function cacheGet(self, key)
    validateCache(self, "CacheKit.Cache:Get", 3)
    validateKey(key, "CacheKit.Cache:Get", 3)
    if rawget(self, "_closed") == true then
        return nil
    end

    local entry = lookup(self, key)
    if entry == nil then
        return nil
    end
    return entry.value
end

---Store `value` under `key` as the most recently used entry.
---
---A new key in a full cache evicts the least recently used entry. Setting an
---existing key replaces its value and, on a TTL cache, restarts its age.
---`Set(key, nil)` deletes the key, because a table cannot store `nil`.
---@param self CacheKit.Cache
---@param key any any value except `nil` and NaN
---@param value any `nil` deletes the key
local function cacheSet(self, key, value)
    validateCache(self, "CacheKit.Cache:Set", 3)
    validateKey(key, "CacheKit.Cache:Set", 3)
    if rawget(self, "_closed") == true then
        error("CacheKit.Cache:Set cannot write to a closed cache", 2)
    end

    if value == nil then
        local entry = rawget(self, "_entries")[key]
        if entry ~= nil then
            removeEntry(self, entry)
        end
        return
    end

    store(self, key, value)
end

---Return the live value stored under `key` without marking it as used.
---
---`Peek` has no side effects: it neither changes recency nor counts a hit or a
---miss, and an expired entry reads as `nil` but stays stored until something
---else removes it.
---@param self CacheKit.Cache
---@param key any any value except `nil` and NaN
---@return any value
local function cachePeek(self, key)
    validateCache(self, "CacheKit.Cache:Peek", 3)
    validateKey(key, "CacheKit.Cache:Peek", 3)
    if rawget(self, "_closed") == true then
        return nil
    end

    local entry = rawget(self, "_entries")[key]
    if entry == nil or isExpired(entry) then
        return nil
    end
    return entry.value
end

---Remove `key`. Returns whether an entry was stored under it, expired or not.
---@param self CacheKit.Cache
---@param key any any value except `nil` and NaN
---@return boolean removed
local function cacheDelete(self, key)
    validateCache(self, "CacheKit.Cache:Delete", 3)
    validateKey(key, "CacheKit.Cache:Delete", 3)
    if rawget(self, "_closed") == true then
        return false
    end

    local entry = rawget(self, "_entries")[key]
    if entry == nil then
        return false
    end
    removeEntry(self, entry)
    return true
end

---Remove every entry. Statistics are kept. Returns how many entries were stored.
---@param self CacheKit.Cache
---@return integer removed
local function cacheClear(self)
    validateCache(self, "CacheKit.Cache:Clear", 3)
    if rawget(self, "_closed") == true then
        return 0
    end
    return clearEntries(self)
end

---Return how many entries are stored.
---
---On a TTL cache the count includes expired entries that nothing has touched
---since they expired; they are removed when read or when they are the least
---recently used entry at the next eviction.
---@param self CacheKit.Cache
---@return integer count
local function cacheGetCount(self)
    validateCache(self, "CacheKit.Cache:GetCount", 3)
    return rawget(self, "_count")
end

---Return the cache's counters.
---
---The same table is returned on every call for this cache and refreshed from
---the live counters each time; it is allocated once, on the first call. Copy
---the fields to keep a reading, and do not write to the table.
---@param self CacheKit.Cache
---@return CacheKit.Stats stats
local function cacheGetStats(self)
    validateCache(self, "CacheKit.Cache:GetStats", 3)

    local view = rawget(self, "_statsView")
    if view == false then
        view = { hits = 0, misses = 0, evictions = 0 }
        rawset(self, "_statsView", view)
    end
    view.hits = rawget(self, "_hits")
    view.misses = rawget(self, "_misses")
    view.evictions = rawget(self, "_evictions")
    return view
end

---Clear the cache whenever the host event `eventName` fires.
---
---Needs EventKit API 1, found through `Registry:Find` when this is called;
---raises at the caller when it is not loaded. Returns `false` when the cache
---already clears on that event. The connections are released by `Close`.
---@param self CacheKit.Cache
---@param eventName string a World of Warcraft event name
---@return boolean connected
local function cacheClearOn(self, eventName)
    validateCache(self, "CacheKit.Cache:ClearOn", 3)
    validateNonEmptyString(eventName, "CacheKit.Cache:ClearOn eventName", 3)
    if rawget(self, "_closed") == true then
        error("CacheKit.Cache:ClearOn cannot subscribe a closed cache", 2)
    end

    local events = rawget(self, "_clearOnEvents")
    if events ~= false and events[eventName] ~= nil then
        return false
    end

    local EventKit = resolveEventKit("CacheKit.Cache:ClearOn", 3)

    local scope = rawget(self, "_eventScope")
    if scope == false then
        scope = EventKit:CreateScope()
        rawset(self, "_eventScope", scope)
    end

    local callback = rawget(self, "_clearCallback")
    if callback == false then
        callback = newClearCallback(self)
        rawset(self, "_clearCallback", callback)
    end

    -- EventKit reports a refused host registration at its own caller, which is
    -- this line; re-raise it at the line that called `ClearOn` instead, keeping
    -- the host's reason.
    local connected, connection = pcall(scope.Connect, scope, eventName, callback)
    if not connected then
        error(
            "CacheKit.Cache:ClearOn could not connect "
                .. eventName
                .. ": "
                .. withoutPosition(connection),
            2
        )
    end
    if events == false then
        events = {}
        rawset(self, "_clearOnEvents", events)
    end
    events[eventName] = connection
    return true
end

---Close the cache: drop every entry and the free list, and release every
---clear-on-event connection. Returns `false` when it was already closed.
---
---A closed cache reads as empty; `Set` and `ClearOn` raise. A failure EventKit
---reports while releasing the connections is re-raised after the cache is
---fully closed.
---@param self CacheKit.Cache
---@return boolean closed
local function cacheClose(self)
    validateCache(self, "CacheKit.Cache:Close", 3)
    if rawget(self, "_closed") == true then
        return false
    end

    rawset(self, "_closed", true)
    rawset(self, "_entries", false)
    rawset(self, "_newest", false)
    rawset(self, "_oldest", false)
    rawset(self, "_count", 0)
    rawset(self, "_free", false)
    rawset(self, "_freeCount", 0)
    rawset(self, "_clearOnEvents", false)

    local scope = rawget(self, "_eventScope")
    if scope ~= false then
        rawset(self, "_eventScope", false)
        scope:Close()
    end
    return true
end

---Return whether the cache is closed.
---@param self CacheKit.Cache
---@return boolean
local function cacheIsClosed(self)
    validateCache(self, "CacheKit.Cache:IsClosed", 3)
    return rawget(self, "_closed") == true
end

-- Memoisation ----------------------------------------------------------------

---Answer one call of a memoised function. Reached through the shared dispatch
---table, so the failures below report at level 3: this function, the memoised
---closure, then the caller of the memoised function.
---@param cache table
---@param compute fun(key: string|number): any
---@param key any
---@return any value
local function memoizedCall(cache, compute, key)
    local keyType = type(key)
    if keyType ~= "string" and keyType ~= "number" then
        error("CacheKit memoized function key must be a string or a number", 3)
    end
    if key ~= key then
        error("CacheKit memoized function key must not be NaN", 3)
    end
    if rawget(cache, "_closed") == true then
        error("CacheKit memoized function cannot run after its cache was closed", 3)
    end

    local entry = lookup(cache, key)
    if entry ~= nil then
        return entry.value
    end

    -- Only the first result is remembered, and `nil` is not remembered at all:
    -- a cache cannot store `nil`. A caller that wants a negative answer
    -- remembered returns `false`. `compute` may close the cache it feeds.
    local value = compute(key)
    if value ~= nil and rawget(cache, "_closed") ~= true then
        store(cache, key, value)
    end
    return value
end

-- Snapshot internals ---------------------------------------------------------
--
-- A snapshot keeps `_values` (key to value) and `_seen` (key to the number of
-- the refresh that last filled it). A refresh increments `_stamp`, lets the
-- caller's reader report every key through `fill`, then removes each key whose
-- stamp is stale. An unchanged key costs two reads and one write to a field
-- that already exists, which is why a refresh with nothing new allocates
-- nothing. The three result arrays belong to the snapshot and are overwritten
-- by the next refresh.

---Append `key` to one of a snapshot's result arrays.
---@param snapshot table
---@param arrayField string
---@param countField string
---@param key any
local function appendResult(snapshot, arrayField, countField, key)
    local count = rawget(snapshot, countField) + 1
    rawget(snapshot, arrayField)[count] = key
    rawset(snapshot, countField, count)
end

---Clear the slots a previous refresh used beyond the current count.
---@param array any[]
---@param count integer entries the current refresh wrote
---@param previousCount integer entries the previous refresh wrote
local function truncateResult(array, count, previousCount)
    for index = count + 1, previousCount do
        array[index] = nil
    end
end

---Record one key the reader reported. Reached through the shared dispatch
---table, so the failures below report at level 3: this function, the fill
---closure, then the reader line that called `fill`.
---@param snapshot table
---@param key any
---@param value any
local function snapshotFill(snapshot, key, value)
    if rawget(snapshot, "_refreshing") ~= true then
        error("CacheKit.Snapshot fill can only be called while its Refresh is running", 3)
    end
    -- Before any comparison: comparing a secret is itself the host error.
    if nativeIsSecretValue ~= nil then
        if nativeIsSecretValue(key) then
            error("CacheKit.Snapshot fill key must not be a secret value", 3)
        end
        if nativeIsSecretValue(value) then
            error("CacheKit.Snapshot fill value must not be a secret value", 3)
        end
    end
    validateKey(key, "CacheKit.Snapshot fill", 4)
    if value == nil then
        error("CacheKit.Snapshot fill value must not be nil", 3)
    end

    local seen = rawget(snapshot, "_seen")
    local stamp = rawget(snapshot, "_stamp")
    if seen[key] == stamp then
        error(
            'CacheKit.Snapshot fill received key "' .. tostring(key) .. '" twice in one refresh',
            3
        )
    end

    local filledCount = rawget(snapshot, "_filledCount") + 1
    local maxEntries = rawget(snapshot, "_maxEntries")
    if filledCount > maxEntries then
        error("CacheKit.Snapshot fill exceeded maxEntries (" .. maxEntries .. ")", 3)
    end
    rawset(snapshot, "_filledCount", filledCount)
    seen[key] = stamp

    local values = rawget(snapshot, "_values")
    local previous = values[key]
    if previous == nil then
        values[key] = value
        appendResult(snapshot, "_added", "_addedCount", key)
    elseif not rawequal(previous, value) then
        values[key] = value
        appendResult(snapshot, "_changed", "_changedCount", key)
        -- Kept beside the key at the same index, so a failed read can put the
        -- value of the last successful refresh back.
        rawget(snapshot, "_changedPrevious")[rawget(snapshot, "_changedCount")] = previous
    end
end

---Build the fill function handed to a snapshot's reader. It calls through the
---shared dispatch table so an upgrade replaces its behaviour.
---@param snapshot table
---@return CacheKit.Fill
local function newFill(snapshot)
    return function(key, value)
        local fill = rawget(dispatch, "snapshotFill")
        fill(snapshot, key, value)
    end
end

---Remove every key the refresh in progress did not fill.
---@param snapshot table
local function removeUnfilled(snapshot)
    local values = rawget(snapshot, "_values")
    local seen = rawget(snapshot, "_seen")
    local stamp = rawget(snapshot, "_stamp")

    -- Assigning `nil` to the field being visited is allowed during `next`.
    for key in next, values do
        if seen[key] ~= stamp then
            values[key] = nil
            seen[key] = nil
            appendResult(snapshot, "_removed", "_removedCount", key)
        end
    end
end

---Undo a refresh whose reader raised: remove every key it added, put back the
---value every key it changed held before, and empty both result arrays (the
---slots are cleared here, because the counts the caller truncates by are
---reset to zero). The
---snapshot is then exactly the last successful refresh, so the next successful
---refresh reports those additions and changes itself.
---@param snapshot table
local function rollBackRefresh(snapshot)
    local values = rawget(snapshot, "_values")
    local seen = rawget(snapshot, "_seen")

    local added = rawget(snapshot, "_added")
    for index = 1, rawget(snapshot, "_addedCount") do
        local key = added[index]
        values[key] = nil
        seen[key] = nil
        added[index] = nil
    end
    rawset(snapshot, "_addedCount", 0)

    local changed = rawget(snapshot, "_changed")
    local changedPrevious = rawget(snapshot, "_changedPrevious")
    for index = 1, rawget(snapshot, "_changedCount") do
        values[changed[index]] = changedPrevious[index]
        changed[index] = nil
    end
    rawset(snapshot, "_changedCount", 0)
end

---Build an open, empty snapshot.
---@param read CacheKit.Read
---@param maxEntries integer
---@return CacheKit.Snapshot
local function newSnapshot(read, maxEntries)
    local snapshot = setmetatable({
        _schema = SNAPSHOT_SCHEMA,
        _read = read,
        _fill = false,
        _values = {},
        _seen = {},
        _stamp = 0,
        _count = 0,
        _filledCount = 0,
        _maxEntries = maxEntries,
        _added = {},
        _removed = {},
        _changed = {},
        -- Parallel to `_changed`: the value each changed key held before this
        -- refresh. Cleared when the refresh ends, so it retains nothing.
        _changedPrevious = {},
        _addedCount = 0,
        _removedCount = 0,
        _changedCount = 0,
        _refreshing = false,
        _closed = false,
    }, SNAPSHOT_METATABLE)
    rawset(snapshot, "_fill", newFill(snapshot))
    return snapshot
end

-- Snapshot methods -----------------------------------------------------------

---Call the reader and report what changed since the previous refresh.
---
---Returns three arrays of keys: added, removed, changed (the value is not
---`rawequal` to the previous one). The arrays belong to the snapshot and are
---overwritten by the next refresh; copy what you need to keep. A refresh in
---which nothing changed allocates nothing.
---
---When the reader raises, the keys it added are removed again, the keys it
---changed get their previous values back, nothing is removed, and the error is re-raised
---unchanged with `error(failure, 0)` (so the traceback ends at `Refresh`);
---the next refresh reports against that state.
---@param self CacheKit.Snapshot
---@return any[] added
---@return any[] removed
---@return any[] changed
local function snapshotRefresh(self)
    validateSnapshot(self, "CacheKit.Snapshot:Refresh", 3)
    if rawget(self, "_closed") == true then
        error("CacheKit.Snapshot:Refresh cannot refresh a closed snapshot", 2)
    end
    if rawget(self, "_refreshing") == true then
        error("CacheKit.Snapshot:Refresh cannot run inside its own read", 2)
    end

    local previousAdded = rawget(self, "_addedCount")
    local previousRemoved = rawget(self, "_removedCount")
    local previousChanged = rawget(self, "_changedCount")
    rawset(self, "_addedCount", 0)
    rawset(self, "_removedCount", 0)
    rawset(self, "_changedCount", 0)
    rawset(self, "_filledCount", 0)
    rawset(self, "_stamp", rawget(self, "_stamp") + 1)

    rawset(self, "_refreshing", true)
    local ok, failure = pcall(rawget(self, "_read"), rawget(self, "_fill"))
    rawset(self, "_refreshing", false)

    local added = rawget(self, "_added")
    local removed = rawget(self, "_removed")
    local changed = rawget(self, "_changed")

    local changedThisRefresh = rawget(self, "_changedCount")
    if ok then
        removeUnfilled(self)
        rawset(self, "_count", rawget(self, "_filledCount"))
    else
        -- A failed read proves nothing about the keys it did not reach, so
        -- none is removed; what it added and changed is rolled back, so the
        -- snapshot stays the last successful refresh, never exceeds
        -- `maxEntries` however many reads fail in a row, and the next
        -- successful refresh still reports every change.
        rollBackRefresh(self)
    end
    truncateResult(rawget(self, "_changedPrevious"), 0, changedThisRefresh)

    truncateResult(added, rawget(self, "_addedCount"), previousAdded)
    truncateResult(removed, rawget(self, "_removedCount"), previousRemoved)
    truncateResult(changed, rawget(self, "_changedCount"), previousChanged)

    if not ok then
        error(failure, 0)
    end
    return added, removed, changed
end

---Return the value the latest refresh recorded for `key`, or `nil`.
---@param self CacheKit.Snapshot
---@param key any
---@return any value
local function snapshotGet(self, key)
    validateSnapshot(self, "CacheKit.Snapshot:Get", 3)
    local values = rawget(self, "_values")
    if values == false or key == nil or key ~= key then
        return nil
    end
    return values[key]
end

---Return how many keys the latest refresh recorded.
---@param self CacheKit.Snapshot
---@return integer count
local function snapshotGetCount(self)
    validateSnapshot(self, "CacheKit.Snapshot:GetCount", 3)
    return rawget(self, "_count")
end

---Iterator that yields nothing, for a closed snapshot.
---@return nil
local function emptyIterator()
    return nil
end

---Iterate the recorded keys and values: `for key, value in snapshot:Pairs()`.
---Allocates nothing. Do not refresh the snapshot during the loop.
---@param self CacheKit.Snapshot
---@return fun(table: table, key: any): any, any iterator
---@return table? values
---@return nil
local function snapshotPairs(self)
    validateSnapshot(self, "CacheKit.Snapshot:Pairs", 3)
    local values = rawget(self, "_values")
    if values == false then
        return emptyIterator, nil, nil
    end
    return next, values, nil
end

---Close the snapshot and drop everything it recorded. Returns `false` when it
---was already closed. Refused from inside the snapshot's own reader.
---@param self CacheKit.Snapshot
---@return boolean closed
local function snapshotClose(self)
    validateSnapshot(self, "CacheKit.Snapshot:Close", 3)
    if rawget(self, "_closed") == true then
        return false
    end
    if rawget(self, "_refreshing") == true then
        error("CacheKit.Snapshot:Close cannot close a snapshot inside its own read", 2)
    end

    rawset(self, "_closed", true)
    rawset(self, "_values", false)
    rawset(self, "_seen", false)
    rawset(self, "_count", 0)
    truncateResult(rawget(self, "_added"), 0, rawget(self, "_addedCount"))
    truncateResult(rawget(self, "_removed"), 0, rawget(self, "_removedCount"))
    truncateResult(rawget(self, "_changed"), 0, rawget(self, "_changedCount"))
    rawset(self, "_addedCount", 0)
    rawset(self, "_removedCount", 0)
    rawset(self, "_changedCount", 0)
    return true
end

---Return whether the snapshot is closed.
---@param self CacheKit.Snapshot
---@return boolean
local function snapshotIsClosed(self)
    validateSnapshot(self, "CacheKit.Snapshot:IsClosed", 3)
    return rawget(self, "_closed") == true
end

-- Package public API ---------------------------------------------------------

---Create a least-recently-used cache holding at most `maxEntries` entries.
---@param _ CacheKit
---@param options CacheKit.LruOptions
---@return CacheKit.Cache cache
local function packageNewLru(_, options)
    validateOptionKeys(options, LRU_OPTION_KEYS, "CacheKit:NewLru", 3)
    local maxEntries = rawget(options, "maxEntries")
    validateMaxEntries(maxEntries, "CacheKit:NewLru", 3)
    return newCache(maxEntries, false)
end

---Create a least-recently-used cache whose entries also expire `ttlSeconds`
---after they were last set. Without `GetTimePreciseSec` entries never expire.
---@param _ CacheKit
---@param options CacheKit.TtlOptions
---@return CacheKit.Cache cache
local function packageNewTtl(_, options)
    validateOptionKeys(options, TTL_OPTION_KEYS, "CacheKit:NewTtl", 3)
    local maxEntries = rawget(options, "maxEntries")
    local ttlSeconds = rawget(options, "ttlSeconds")
    validateMaxEntries(maxEntries, "CacheKit:NewTtl", 3)
    validateTtlSeconds(ttlSeconds, "CacheKit:NewTtl", 3)
    return newCache(maxEntries, ttlSeconds)
end

---Wrap a one-key function so each result is computed once and remembered.
---
---Returns the memoised function and the cache behind it, which is the handle
---to clear it (`Clear`, `Delete`), read its statistics, clear it on an event,
---or `Close` it. Only `fn`'s first result is remembered, and a `nil` result is
---not remembered at all.
---@param _ CacheKit
---@param fn fun(key: string|number): any
---@param options CacheKit.MemoizeOptions?
---@return CacheKit.Memoized memoized
---@return CacheKit.Cache cache
local function packageMemoize(_, fn, options)
    if type(fn) ~= "function" then
        error("CacheKit:Memoize fn must be a function", 2)
    end

    local maxEntries = DEFAULT_MEMOIZE_MAX_ENTRIES
    local ttlSeconds = false
    if options ~= nil then
        validateOptionKeys(options, MEMOIZE_OPTION_KEYS, "CacheKit:Memoize", 3)
        if rawget(options, "maxEntries") ~= nil then
            maxEntries = rawget(options, "maxEntries")
            validateMaxEntries(maxEntries, "CacheKit:Memoize", 3)
        end
        if rawget(options, "ttlSeconds") ~= nil then
            ttlSeconds = rawget(options, "ttlSeconds")
            validateTtlSeconds(ttlSeconds, "CacheKit:Memoize", 3)
        end
    end

    local cache = newCache(maxEntries, ttlSeconds)
    local function memoized(key)
        local call = rawget(dispatch, "memoizedCall")
        local value = call(cache, fn, key)
        return value
    end
    return memoized, cache
end

---Create a snapshot over `read`. Nothing is read until the first `Refresh`,
---which reports every key as added.
---@param _ CacheKit
---@param read CacheKit.Read called with `fill`; calls `fill(key, value)` per key
---@param options CacheKit.SnapshotOptions?
---@return CacheKit.Snapshot snapshot
local function packageNewSnapshot(_, read, options)
    if type(read) ~= "function" then
        error("CacheKit:NewSnapshot read must be a function", 2)
    end

    local maxEntries = DEFAULT_SNAPSHOT_MAX_ENTRIES
    if options ~= nil then
        validateOptionKeys(options, SNAPSHOT_OPTION_KEYS, "CacheKit:NewSnapshot", 3)
        if rawget(options, "maxEntries") ~= nil then
            maxEntries = rawget(options, "maxEntries")
            validateMaxEntries(maxEntries, "CacheKit:NewSnapshot", 3)
        end
    end
    return newSnapshot(read, maxEntries)
end

-- Commit ---------------------------------------------------------------------

rawset(Cache, "Get", cacheGet)
rawset(Cache, "Set", cacheSet)
rawset(Cache, "Peek", cachePeek)
rawset(Cache, "Delete", cacheDelete)
rawset(Cache, "Clear", cacheClear)
rawset(Cache, "GetCount", cacheGetCount)
rawset(Cache, "GetStats", cacheGetStats)
rawset(Cache, "ClearOn", cacheClearOn)
rawset(Cache, "Close", cacheClose)
rawset(Cache, "IsClosed", cacheIsClosed)

rawset(Snapshot, "Refresh", snapshotRefresh)
rawset(Snapshot, "Get", snapshotGet)
rawset(Snapshot, "GetCount", snapshotGetCount)
rawset(Snapshot, "Pairs", snapshotPairs)
rawset(Snapshot, "Close", snapshotClose)
rawset(Snapshot, "IsClosed", snapshotIsClosed)

rawset(CacheKit, "API", API_GENERATION)
rawset(CacheKit, "REVISION", IMPLEMENTATION_REVISION)
rawset(CacheKit, "NewLru", packageNewLru)
rawset(CacheKit, "NewTtl", packageNewTtl)
rawset(CacheKit, "Memoize", packageMemoize)
rawset(CacheKit, "NewSnapshot", packageNewSnapshot)

rawset(dispatch, "clearOnEvent", clearOnEvent)
rawset(dispatch, "memoizedCall", memoizedCall)
rawset(dispatch, "snapshotFill", snapshotFill)
rawset(state, "runtimeRevision", IMPLEMENTATION_REVISION)

if not validatePublicSurface(CacheKit) or not validateCurrentState(CacheKit) then
    error("MoltenCodes CacheKit package state is corrupted or incomplete", 2)
end

return CacheKit
