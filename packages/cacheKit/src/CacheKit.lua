-- MoltenCodes CacheKit
--
-- Bounded caches for World of Warcraft addons, so "bounded by default" is a
-- structure a consumer reaches for instead of a rule it has to remember:
-- least-recently-used caches bounded by count, the same caches with an age
-- limit and negative entries, memoisation of a one-key function, snapshots
-- that report what changed between two reads, a namespace tree expanded on
-- demand, a bounded ring queue with an explicit overflow policy, and clearing
-- a cache when a host event fires.
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
--   Recency list .......... the intrusive recency list and the free list
--   Cache internals ....... lookup, store, clear, construction
--   Clear-on-event ........ optional EventKit resolution and the callback
--   Cache methods ......... the handle a cache owner receives
--   Memoisation ........... the memoised call path
--   Snapshot internals .... fill, refresh, the diff arrays
--   Snapshot methods ...... the handle a snapshot owner receives
--   Lazy tree internals ... path walking, expansion, eviction, invalidation
--   Lazy tree methods ..... the handle a lazy tree owner receives
--   Queue internals ....... the ring arithmetic
--   Queue methods ......... the handle a queue owner receives
--   Package public API .... the facade published through Registry
--   Commit ................ prototype/facade assignment and self-check
--
-- Layout and invariants are described in `docs/INTERNALS.md`.

-- Constants ------------------------------------------------------------------

local PACKAGE_NAME = "cacheKit"
local API_GENERATION = 1
local IMPLEMENTATION_REVISION = 2
local REQUIRED_REGISTRY_API = 2
local OPTIONAL_EVENTKIT_API = 1

-- Schema 1 (revision 1) kept the cache and snapshot metatables. Schema 2
-- (revision 2) adds the lazy tree and queue metatables, the negative-entry
-- marker and the package-wide limits; see the upgrade branch in *Bootstrap*.
local STATE_SCHEMA = 2

-- Every cache, snapshot, lazy tree and queue records the layout it was built
-- with, so a later revision that changes the layout can upgrade old objects
-- lazily, the way PoolKit upgrades pools, instead of guessing from which
-- fields exist.
local CACHE_SCHEMA = 1
local SNAPSHOT_SCHEMA = 1
local LAZY_SCHEMA = 1
local QUEUE_SCHEMA = 1

-- `Memoize` and `Lazy` are the constructors where a caller may omit the bound.
-- 128 is the same default PoolKit retains, so the bounds are memorable
-- together.
local DEFAULT_MEMOIZE_MAX_ENTRIES = 128
local DEFAULT_LAZY_MAX_ENTRIES = 128

-- A snapshot mirrors something the host already bounds (group members,
-- nameplates, frames); the default only has to stop a runaway `read`.
local DEFAULT_SNAPSHOT_MAX_ENTRIES = 1024

-- A bounded cache needs no separate bound on its free list, because live plus
-- free entries never exceed `maxEntries`. A cache opened with
-- `CacheKit.UNBOUNDED` has no such bound, so its free list keeps at most this
-- many blank entry tables and lets the collector have the rest: after a burst
-- the cache retains what it holds live, not its peak.
local UNBOUNDED_FREE_LIST_LIMIT = 1024

-- The complete set of fields each option table accepts. File-local constants
-- keep option validation allocation-free.
local LRU_OPTION_KEYS = { maxEntries = true }
local TTL_OPTION_KEYS = { maxEntries = true, ttlSeconds = true }
local MEMOIZE_OPTION_KEYS = { maxEntries = true, ttlSeconds = true, cacheable = true }
local SNAPSHOT_OPTION_KEYS = { maxEntries = true }
local LAZY_OPTION_KEYS = { maxEntries = true }

-- The overflow policies a queue accepts, and the text the refusal lists them
-- in, so the error and the set cannot drift apart.
local QUEUE_OVERFLOW_POLICIES = { dropOldest = true, dropNewest = true, reject = true }
local QUEUE_OVERFLOW_POLICY_TEXT = '"dropOldest", "dropNewest" or "reject"'

-- A queue allocates its whole ring when it is created, so its capacity must be
-- a size: `UNBOUNDED` is refused, and the ceiling keeps one `NewQueue` call
-- from allocating without bound. The capacity a call may ask for is bounded by
-- the package-wide `maxQueueCapacity`, the same shape SignalKit gives journals.
local DEFAULT_MAX_QUEUE_CAPACITY = 1024
local MAX_QUEUE_CAPACITY_CEILING = 65536

-- Names `SetLimits` recognises, in the order `GetLimits` reads them, with the
-- ceiling each accepts and why each refuses `UNBOUNDED`.
local LIMIT_NAMES = { "maxQueueCapacity" }
local LIMIT_CEILINGS = { maxQueueCapacity = MAX_QUEUE_CAPACITY_CEILING }
local LIMIT_UNBOUNDED_REFUSALS = {
    maxQueueCapacity = "the ring is allocated when the queue is created",
}

-- The published surface, listed once so the public-surface predicate reads as
-- a checklist instead of a long boolean expression.
local FACADE_METHODS = {
    "NewLru",
    "NewTtl",
    "Memoize",
    "NewSnapshot",
    "Lazy",
    "NewQueue",
    "SetLimits",
    "GetLimits",
}
local CACHE_METHODS = {
    "Get",
    "Set",
    "PutNegative",
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
local LAZY_METHODS = {
    "Get",
    "Peek",
    "Invalidate",
    "Clear",
    "GetCount",
    "GetStats",
    "Close",
    "IsClosed",
}
local QUEUE_METHODS = { "Push", "Pop", "Peek", "Iterate", "Clear", "GetCount", "GetCapacity" }

-- Public types ---------------------------------------------------------------
--
-- CacheKit publishes its methods by writing them onto Registry-owned prototype
-- tables, so the editor-facing contract is declared here as LuaCATS classes
-- rather than inferred from those assignments.

---Option table accepted by `CacheKit:NewLru`.
---@class CacheKit.LruOptions
---@field maxEntries integer|table Required. The most entries the cache holds, at least `1`, or `CacheKit.UNBOUNDED`.

---Option table accepted by `CacheKit:NewTtl`.
---@class CacheKit.TtlOptions
---@field maxEntries integer|table Required. The most entries the cache holds, at least `1`, or `CacheKit.UNBOUNDED`.
---@field ttlSeconds number Required. Seconds an entry stays valid after it was last set.

---Decides whether a memoised result is complete enough to remember. Called with
---`fn`'s first result (the one that would be stored) and the key; a result it
---does not accept is returned to the caller without being stored.
---@alias CacheKit.Cacheable fun(result: any, key: string|number): boolean

---Option table accepted by `CacheKit:Memoize`.
---@class CacheKit.MemoizeOptions
---@field maxEntries (integer|table)? Positive integer or `CacheKit.UNBOUNDED`; defaults to `128`.
---@field ttlSeconds number? When given, remembered results expire after this many seconds.
---@field cacheable CacheKit.Cacheable? When given, a result it returns `false` or `nil` for is returned without being remembered.

---Option table accepted by `CacheKit:NewSnapshot`.
---@class CacheKit.SnapshotOptions
---@field maxEntries (integer|table)? The most keys one read may fill: a positive integer or `CacheKit.UNBOUNDED`; defaults to `1024`.

---Option table accepted by `CacheKit:Lazy`.
---@class CacheKit.LazyOptions
---@field maxEntries (integer|table)? The most expanded nodes the tree keeps: a positive integer or `CacheKit.UNBOUNDED`; defaults to `128`.

---Counters of one cache or lazy tree. `GetStats` returns the same table on every call.
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

---The caller's resolver for a lazy tree: the path parts in, the expanded value
---out. Only the first result is kept, and `nil` is not kept at all.
---@alias CacheKit.Resolve fun(...: string|number): any

---What a full queue does with the next `Push`.
---@alias CacheKit.OverflowPolicy "dropOldest"|"dropNewest"|"reject"

---The package-wide limits. `SetLimits` accepts any subset; `GetLimits` returns
---a fresh copy of all of them.
---@class CacheKit.Limits
---@field maxQueueCapacity integer Largest `capacity` `NewQueue` accepts, from 1 to 65536; defaults to 1024.

---A bounded least-recently-used cache, optionally with an age limit.
---@class CacheKit.Cache
---@field Get fun(self: CacheKit.Cache, key: any): any, "negative"?
---@field Set fun(self: CacheKit.Cache, key: any, value: any)
---@field PutNegative fun(self: CacheKit.Cache, key: any, ttlSeconds: number)
---@field Peek fun(self: CacheKit.Cache, key: any): any, "negative"?
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

---A namespace tree whose nodes are expanded by the caller's resolver on first
---read and kept, bounded by a count of expanded nodes.
---@class CacheKit.LazyTree
---@field Get fun(self: CacheKit.LazyTree, ...: string|number): any
---@field Peek fun(self: CacheKit.LazyTree, ...: string|number): any
---@field Invalidate fun(self: CacheKit.LazyTree, ...: string|number): integer
---@field Clear fun(self: CacheKit.LazyTree): integer
---@field GetCount fun(self: CacheKit.LazyTree): integer
---@field GetStats fun(self: CacheKit.LazyTree): CacheKit.Stats
---@field Close fun(self: CacheKit.LazyTree): boolean
---@field IsClosed fun(self: CacheKit.LazyTree): boolean

---A bounded first-in, first-out ring queue with an explicit overflow policy.
---@class CacheKit.Queue
---@field Push fun(self: CacheKit.Queue, value: any): boolean, any
---@field Pop fun(self: CacheKit.Queue): any
---@field Peek fun(self: CacheKit.Queue): any
---@field Iterate fun(self: CacheKit.Queue): (fun(queue: CacheKit.Queue, position: integer): integer?, any), CacheKit.Queue, integer
---@field Clear fun(self: CacheKit.Queue): integer
---@field GetCount fun(self: CacheKit.Queue): integer
---@field GetCapacity fun(self: CacheKit.Queue): integer

---The CacheKit package facade published through Registry.
---@class CacheKit
---@field API integer Public API generation.
---@field REVISION integer Compatible implementation revision.
---@field Cache CacheKit.Cache Shared cache prototype.
---@field Snapshot CacheKit.Snapshot Shared snapshot prototype.
---@field LazyTree CacheKit.LazyTree Shared lazy tree prototype.
---@field Queue CacheKit.Queue Shared queue prototype.
---@field UNBOUNDED table Sentinel a `maxEntries` option accepts to lift the bound; one table shared by every revision.
---@field NewLru fun(self: CacheKit, options: CacheKit.LruOptions): CacheKit.Cache
---@field NewTtl fun(self: CacheKit, options: CacheKit.TtlOptions): CacheKit.Cache
---@field Memoize fun(self: CacheKit, fn: fun(key: string|number): any, options: CacheKit.MemoizeOptions?): CacheKit.Memoized, CacheKit.Cache
---@field NewSnapshot fun(self: CacheKit, read: CacheKit.Read, options: CacheKit.SnapshotOptions?): CacheKit.Snapshot
---@field Lazy fun(self: CacheKit, resolve: CacheKit.Resolve, options: CacheKit.LazyOptions?): CacheKit.LazyTree
---@field NewQueue fun(self: CacheKit, capacity: integer, overflow: CacheKit.OverflowPolicy): CacheKit.Queue
---@field SetLimits fun(self: CacheKit, limits: table)
---@field GetLimits fun(self: CacheKit): CacheKit.Limits

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
        or type(rawget(implementation, "LazyTree")) ~= "table"
        or type(rawget(implementation, "Queue")) ~= "table"
        or type(rawget(implementation, "UNBOUNDED")) ~= "table"
    then
        return false
    end

    return hasMethods(implementation, FACADE_METHODS)
        and hasMethods(rawget(implementation, "Cache"), CACHE_METHODS)
        and hasMethods(rawget(implementation, "Snapshot"), SNAPSHOT_METHODS)
        and hasMethods(rawget(implementation, "LazyTree"), LAZY_METHODS)
        and hasMethods(rawget(implementation, "Queue"), QUEUE_METHODS)
end

---Whether `currentState` has the fields every API 1 revision shares, whatever
---its schema. This is what an inherited state is held to before the upgrade
---branch brings it to the current schema.
---@param currentState any
---@return boolean
local function validateStateShared(currentState)
    return type(currentState) == "table"
        and type(rawget(currentState, "schema")) == "number"
        and type(rawget(currentState, "dispatch")) == "table"
        and type(rawget(currentState, "runtimeRevision")) == "number"
        and type(rawget(currentState, "cacheMetatable")) == "table"
        and type(rawget(currentState, "snapshotMetatable")) == "table"
        and type(rawget(currentState, "unbounded")) == "table"
end

---Whether `value` is a finite integer from 1 to `ceiling`. NaN fails every
---comparison and infinity is named because it passes the integer test.
---@param value any
---@param ceiling number
---@return boolean
local function isIntegerUpTo(value, ceiling)
    return type(value) == "number"
        and value ~= math.huge
        and value >= 1
        and value <= ceiling
        and value == math.floor(value)
end

---Whether `limits` holds every package-wide limit as an integer within its
---ceiling.
---@param limits any
---@return boolean
local function validateLimits(limits)
    if type(limits) ~= "table" then
        return false
    end
    for index = 1, #LIMIT_NAMES do
        local name = LIMIT_NAMES[index]
        if not isIntegerUpTo(rawget(limits, name), LIMIT_CEILINGS[name]) then
            return false
        end
    end
    return true
end

---Whether `currentState` is complete state of this revision's schema.
---@param currentState any
---@return boolean
local function validateStateBase(currentState)
    return validateStateShared(currentState)
        and rawget(currentState, "schema") == STATE_SCHEMA
        and type(rawget(currentState, "lazyMetatable")) == "table"
        and type(rawget(currentState, "queueMetatable")) == "table"
        and type(rawget(currentState, "negative")) == "table"
        and validateLimits(rawget(currentState, "limits"))
end

---Whether `implementation` carries package state of this revision's schema,
---and publishes the sentinel that state keeps.
---@param implementation table
---@return boolean
local function validateCurrentState(implementation)
    local currentState = rawget(implementation, "_state")
    return validateStateBase(currentState)
        and rawget(implementation, "UNBOUNDED") == rawget(currentState, "unbounded")
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
local LazyTree = rawget(CacheKit, "LazyTree")
local Queue = rawget(CacheKit, "Queue")
local state = rawget(CacheKit, "_state")

if previousRevision == nil then
    if Cache ~= nil or Snapshot ~= nil or LazyTree ~= nil or Queue ~= nil or state ~= nil then
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
        lazyMetatable = {},
        queueMetatable = {},
        -- `CacheKit.UNBOUNDED` lives here so every revision publishes the same
        -- table and a `maxEntries` option written against one copy keeps its
        -- meaning after an upgrade.
        unbounded = {},
        -- The value a negative entry stores. It lives in the state so a
        -- negative entry written by one revision reads as negative in the
        -- next; consumers never see it.
        negative = {},
        -- The package-wide limits `SetLimits` writes; a newer copy inherits
        -- what a consumer set rather than resetting it.
        limits = { maxQueueCapacity = DEFAULT_MAX_QUEUE_CAPACITY },
    }
    rawset(CacheKit, "Cache", Cache)
    rawset(CacheKit, "Snapshot", Snapshot)
    rawset(CacheKit, "_state", state)
elseif type(Cache) ~= "table" or type(Snapshot) ~= "table" or not validateStateShared(state) then
    error("MoltenCodes CacheKit package state is corrupted or incomplete", 2)
else
    if rawget(state, "schema") == 1 then
        -- Revision 1 kept no lazy trees, no queues, no negative entries and
        -- no package-wide limits. Its caches and snapshots keep their layout,
        -- so nothing is upgraded lazily: the state only gains what revision 2
        -- introduced.
        rawset(state, "lazyMetatable", {})
        rawset(state, "queueMetatable", {})
        rawset(state, "negative", {})
        rawset(state, "limits", { maxQueueCapacity = DEFAULT_MAX_QUEUE_CAPACITY })
        rawset(state, "schema", STATE_SCHEMA)
    end

    if not validateStateBase(state) then
        error("MoltenCodes CacheKit package state is corrupted or incomplete", 2)
    end
end

---Return the prototype table published under `fieldName`, creating it when
---the inherited facade has none (revision 1 published neither `LazyTree` nor
---`Queue`) and refusing anything that is not a table.
---@param fieldName string
---@return table prototype
local function inheritPrototype(fieldName)
    local prototype = rawget(CacheKit, fieldName)
    if prototype == nil then
        prototype = {}
        rawset(CacheKit, fieldName, prototype)
    elseif type(prototype) ~= "table" then
        error("MoltenCodes CacheKit package state is corrupted or incomplete", 2)
    end
    return prototype
end

LazyTree = inheritPrototype("LazyTree")
Queue = inheritPrototype("Queue")

-- The metatables and prototypes are kept across upgrades, so caches,
-- snapshots, lazy trees and queues built by an older copy keep their contents
-- and gain this copy's methods without being replaced.
local CACHE_METATABLE = rawget(state, "cacheMetatable")
local SNAPSHOT_METATABLE = rawget(state, "snapshotMetatable")
local LAZY_METATABLE = rawget(state, "lazyMetatable")
local QUEUE_METATABLE = rawget(state, "queueMetatable")
local dispatch = rawget(state, "dispatch")
local UNBOUNDED = rawget(state, "unbounded")
-- The one value stored under a negative key. Compared by identity on the read
-- paths, so a negative entry costs one comparison and no extra entry field.
local NEGATIVE = rawget(state, "negative")
-- The package-wide limits, shared by every consumer and every revision.
local sharedLimits = rawget(state, "limits")
rawset(CACHE_METATABLE, "__index", Cache)
rawset(SNAPSHOT_METATABLE, "__index", Snapshot)
rawset(LAZY_METATABLE, "__index", LazyTree)
rawset(QUEUE_METATABLE, "__index", Queue)

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

---@param lazy any receiver the public method was called on
---@param methodName string public method name, used in the argument error
---@param level integer stack level the failure is reported at
local function validateLazy(lazy, methodName, level)
    if type(lazy) ~= "table" or getmetatable(lazy) ~= LAZY_METATABLE then
        error(methodName .. " must be called on a CacheKit lazy tree", level)
    end
end

---@param queue any receiver the public method was called on
---@param methodName string public method name, used in the argument error
---@param level integer stack level the failure is reported at
local function validateQueue(queue, methodName, level)
    if type(queue) ~= "table" or getmetatable(queue) ~= QUEUE_METATABLE then
        error(methodName .. " must be called on a CacheKit queue", level)
    end
end

---The limit methods write shared state, so they insist on the facade as the
---receiver rather than guessing what a stray table meant.
---@param self any receiver the public method was called on
---@param methodName string public method name, used in the argument error
---@param level integer stack level the failure is reported at
local function validateFacade(self, methodName, level)
    if self ~= CacheKit then
        error(methodName .. " must be called on the CacheKit facade", level)
    end
end

---Refuse an empty path and any part that is not a string or a number, the
---same rule a memoised key follows. Reads the varargs in place, so a valid
---path costs no allocation.
---@param methodName string public method name, used in the argument error
---@param level integer stack level the failure is reported at
---@param ... any the path parts
---@return integer partCount
local function validatePath(methodName, level, ...)
    local partCount = select("#", ...)
    if partCount == 0 then
        error(methodName .. " needs at least one path part", level)
    end
    for index = 1, partCount do
        local part = (select(index, ...))
        local partType = type(part)
        if partType ~= "string" and partType ~= "number" then
            error(methodName .. " path part " .. index .. " must be a string or a number", level)
        end
        if part ~= part then
            error(methodName .. " path part " .. index .. " must not be NaN", level)
        end
    end
    return partCount
end

---Refuse a queue capacity that is not an integer from 1 to the package-wide
---`maxQueueCapacity`. `CacheKit.UNBOUNDED` is refused with its reason: the
---ring is allocated when the queue is created, so it has no unbounded form.
---@param value any
---@param methodName string public method name, used in the argument error
---@param level integer stack level the failure is reported at
local function validateCapacity(value, methodName, level)
    if value == UNBOUNDED then
        error(
            methodName
                .. " capacity cannot be CacheKit.UNBOUNDED: "
                .. LIMIT_UNBOUNDED_REFUSALS.maxQueueCapacity,
            level
        )
    end
    local maxCapacity = rawget(sharedLimits, "maxQueueCapacity")
    if not isIntegerUpTo(value, maxCapacity) then
        error(
            methodName
                .. " capacity must be an integer from 1 to "
                .. maxCapacity
                .. " (CacheKit:SetLimits maxQueueCapacity)",
            level
        )
    end
end

---Validate one `SetLimits` entry: a recognised name, an integer within the
---limit's ceiling, never `UNBOUNDED` (each limit names its reason).
---@param key any
---@param value any
---@param level integer stack level the failures are reported at
local function validateLimitEntry(key, value, level)
    local ceiling = LIMIT_CEILINGS[key]
    if ceiling == nil then
        error("CacheKit:SetLimits limits." .. tostring(key) .. " is not a recognised limit", level)
    end
    if value == UNBOUNDED then
        error(
            "CacheKit:SetLimits limits."
                .. key
                .. " cannot be CacheKit.UNBOUNDED: "
                .. LIMIT_UNBOUNDED_REFUSALS[key],
            level
        )
    end
    if not isIntegerUpTo(value, ceiling) then
        error(
            "CacheKit:SetLimits limits." .. key .. " must be an integer from 1 to " .. ceiling,
            level
        )
    end
end

---Validate a whole `SetLimits` table before any of it is applied, so one bad
---entry changes nothing.
---@param limits any
---@param level integer stack level the failures are reported at
local function validateLimitUpdate(limits, level)
    if type(limits) ~= "table" then
        error("CacheKit:SetLimits limits must be a table", level)
    end
    local key = next(limits)
    while key ~= nil do
        validateLimitEntry(key, rawget(limits, key), level + 1)
        key = next(limits, key)
    end
end

---@param value any
---@param methodName string public method name, used in the argument error
---@param level integer stack level the failure is reported at
local function validateOverflowPolicy(value, methodName, level)
    if type(value) ~= "string" or QUEUE_OVERFLOW_POLICIES[value] ~= true then
        error(methodName .. " overflow must be " .. QUEUE_OVERFLOW_POLICY_TEXT, level)
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

---Refuse a `maxEntries` that is neither a positive integer nor
---`CacheKit.UNBOUNDED`. The entries are the consumer's own data, so the
---consumer may lift the bound.
---@param value any
---@param methodName string public method name, used in the argument error
---@param level integer stack level the failure is reported at
local function validateMaxEntries(value, methodName, level)
    if value == nil then
        error(methodName .. " maxEntries is required", level)
    end
    if value == UNBOUNDED then
        return
    end
    if
        type(value) ~= "number"
        or value ~= value
        or value < 1
        or value == math.huge
        or math.floor(value) ~= value
    then
        error(methodName .. " maxEntries must be a positive integer or CacheKit.UNBOUNDED", level)
    end
end

---The bound a cache or snapshot compares against: the integer itself, or
---`math.huge` for `CacheKit.UNBOUNDED`, so the hot paths compare two numbers
---and never test for the sentinel.
---@param maxEntries integer|table a validated `maxEntries`
---@return number
local function capacityOf(maxEntries)
    -- Validation lets exactly one table through: `CacheKit.UNBOUNDED`.
    if type(maxEntries) == "number" then
        return maxEntries
    end
    return math.huge
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

-- Recency list ---------------------------------------------------------------
--
-- A cache is a hash from key to entry plus an intrusive doubly linked list of
-- those same entries ordered by recency: `_newest` is the entry used last,
-- `_oldest` the next one to evict. Entries are plain tables of fixed shape
-- (`key`, `value`, `newer`, `older`, `expiresAt`), created with every field so
-- relinking never rehashes them. `false` marks an absent link or no expiry.
--
-- A lazy tree keeps the same list over its expanded nodes, which carry the
-- same `newer` and `older` links, and the same free list of blank tables. The
-- list and free-list helpers therefore take the owner (`cache` or `lazy`) and
-- read only the fields both layouts share: `_newest`, `_oldest`, `_free`,
-- `_freeCount` and `_freeLimit`.

---What the recency list links: an entry or a lazy node.
---@class CacheKit.Linked
---@field newer CacheKit.Linked|false
---@field older CacheKit.Linked|false

---@class CacheKit.Entry: CacheKit.Linked
---@field key any
---@field value any
---@field expiresAt number|false

---@return CacheKit.Entry
local function newEntry()
    return { key = false, value = false, newer = false, older = false, expiresAt = false }
end

---Make `entry`, currently unlinked, the most recently used entry.
---@param cache table a cache or a lazy tree
---@param entry CacheKit.Linked an entry or a lazy node
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
---@param cache table a cache or a lazy tree
---@param entry CacheKit.Linked an entry or a lazy node
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
---@param cache table a cache or a lazy tree
---@param entry CacheKit.Linked an entry or a lazy node
local function touch(cache, entry)
    if rawget(cache, "_newest") ~= entry then
        unlink(cache, entry)
        linkNewest(cache, entry)
    end
end

---Keep a blanked table on the owner's free list for reuse, up to `_freeLimit`.
---
---A bounded cache never reaches `_freeLimit`: an entry is recycled only when
---the live count drops by one, and a new key takes from the free list before
---it allocates, so live entries plus free entries never exceed `maxEntries`.
---A lazy tree has no such invariant, because invalidation frees structural
---nodes in bulk: its free list is simply capped at `maxEntries` blank nodes,
---and re-expansion allocates a node only when none is free. An unbounded
---owner stops keeping blank tables at `UNBOUNDED_FREE_LIST_LIMIT` and leaves
---the rest to the collector.
---@param cache table a cache or a lazy tree
---@param blank table an entry or a lazy node the caller has already blanked
local function pushFree(cache, blank)
    local freeCount = rawget(cache, "_freeCount") + 1
    if freeCount > rawget(cache, "_freeLimit") then
        return
    end
    rawget(cache, "_free")[freeCount] = blank
    rawset(cache, "_freeCount", freeCount)
end

---Pop a blank table from the owner's free list, or return `nil` when it is
---empty and the caller has to allocate.
---@param cache table a cache or a lazy tree
---@return table|nil blank
local function popFree(cache)
    local freeCount = rawget(cache, "_freeCount")
    if freeCount == 0 then
        return nil
    end

    local free = rawget(cache, "_free")
    local blank = free[freeCount]
    free[freeCount] = nil
    rawset(cache, "_freeCount", freeCount - 1)
    return blank
end

---The free-list bound for an owner opened with `maxEntries`.
---@param maxEntries integer|table a validated `maxEntries`
---@return integer
local function freeLimitOf(maxEntries)
    if maxEntries == UNBOUNDED then
        return UNBOUNDED_FREE_LIST_LIMIT
    end
    return maxEntries --[[@as integer]]
end

---Drop what an unlinked entry references and keep its table for reuse.
---@param cache table
---@param entry CacheKit.Entry
local function recycle(cache, entry)
    entry.key = false
    entry.value = false
    entry.expiresAt = false
    pushFree(cache, entry)
end

---Return a blank entry, from the free list when it has one.
---@param cache table
---@return CacheKit.Entry
local function takeEntry(cache)
    return popFree(cache) or newEntry()
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

---The expiry instant `ttlSeconds` from now, or `false` on a host without a
---clock, where nothing expires.
---@param ttlSeconds number a validated age limit
---@return number|false
local function expiryAfter(ttlSeconds)
    if nativeGetTimePreciseSec == nil then
        return false
    end
    return nativeGetTimePreciseSec() + ttlSeconds
end

---The expiry instant for an entry set now with the cache's own age limit, or
---`false` for no age limit.
---@param cache table
---@return number|false
local function expiryForNow(cache)
    local ttlSeconds = rawget(cache, "_ttlSeconds")
    if ttlSeconds == false then
        return false
    end
    return expiryAfter(ttlSeconds)
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
---The caller has checked that the cache is open and chosen the expiry: the
---cache's own (`expiryForNow`) for an ordinary entry, the negative entry's own
---age limit for `PutNegative`.
---@param cache table
---@param key any
---@param value any
---@param expiresAt number|false
local function store(cache, key, value, expiresAt)
    local entries = rawget(cache, "_entries")

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
---@param maxEntries integer|table a positive integer or `CacheKit.UNBOUNDED`
---@param ttlSeconds number|false `false` for no age limit
---@return CacheKit.Cache
local function newCache(maxEntries, ttlSeconds)
    local cache = {
        _schema = CACHE_SCHEMA,
        _entries = {},
        _newest = false,
        _oldest = false,
        _count = 0,
        -- `math.huge` when the cache was opened with `CacheKit.UNBOUNDED`.
        _maxEntries = capacityOf(maxEntries),
        _ttlSeconds = ttlSeconds,
        _free = {},
        _freeCount = 0,
        _freeLimit = freeLimitOf(maxEntries),
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
---removed and counts as a miss. A live negative entry (see `PutNegative`)
---counts as a hit and returns `nil, "negative"`, so a caller that reads the
---second result can tell "known to be nothing" from "unknown". A closed cache
---returns `nil` and counts nothing.
---@param self CacheKit.Cache
---@param key any any value except `nil` and NaN
---@return any value
---@return "negative"? outcome `"negative"` when a live negative entry answered
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
    local value = entry.value
    if value == NEGATIVE then
        return nil, "negative"
    end
    return value
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

    store(self, key, value, expiryForNow(self))
end

---Record that `key` has no value, for `ttlSeconds` from now.
---
---A negative entry answers `Get` with `nil, "negative"` and counts as a hit,
---so a source that said "nothing" (a peer, a lookup that returned no row) is
---not asked again until the entry expires. It takes an ordinary slot: it
---counts towards `maxEntries`, is evicted by recency like any entry, and
---`Set`, `Delete` and `Clear` remove it. Its age limit is its own, independent
---of the cache's `ttlSeconds`, which is why only a cache with an age limit
---accepts it: on a plain LRU cache nothing would ever expire it, and the key
---would read as missing until something overwrote it. Without
---`GetTimePreciseSec` a negative entry, like every entry, never expires.
---@param self CacheKit.Cache a cache from `NewTtl`, or from `Memoize` with `ttlSeconds`
---@param key any any value except `nil` and NaN
---@param ttlSeconds number a finite number greater than zero
local function cachePutNegative(self, key, ttlSeconds)
    validateCache(self, "CacheKit.Cache:PutNegative", 3)
    validateKey(key, "CacheKit.Cache:PutNegative", 3)
    validateTtlSeconds(ttlSeconds, "CacheKit.Cache:PutNegative", 3)
    if rawget(self, "_ttlSeconds") == false then
        error(
            "CacheKit.Cache:PutNegative requires a cache with an age limit "
                .. "(CacheKit:NewTtl, or CacheKit:Memoize with ttlSeconds)",
            2
        )
    end
    if rawget(self, "_closed") == true then
        error("CacheKit.Cache:PutNegative cannot write to a closed cache", 2)
    end

    store(self, key, NEGATIVE, expiryAfter(ttlSeconds))
end

---Return the live value stored under `key` without marking it as used.
---
---`Peek` has no side effects: it neither changes recency nor counts a hit or a
---miss, and an expired entry reads as `nil` but stays stored until something
---else removes it. A live negative entry reads as `nil, "negative"`, as it
---does through `Get`.
---@param self CacheKit.Cache
---@param key any any value except `nil` and NaN
---@return any value
---@return "negative"? outcome `"negative"` when a live negative entry answered
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
    local value = entry.value
    if value == NEGATIVE then
        return nil, "negative"
    end
    return value
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

---Refresh and return the owner's statistics view, allocating it on the first
---call. Caches and lazy trees keep the same three counters under the same
---field names, so both `GetStats` methods share this.
---@param owner table a cache or a lazy tree
---@return CacheKit.Stats stats
local function statsView(owner)
    local view = rawget(owner, "_statsView")
    if view == false then
        view = { hits = 0, misses = 0, evictions = 0 }
        rawset(owner, "_statsView", view)
    end
    view.hits = rawget(owner, "_hits")
    view.misses = rawget(owner, "_misses")
    view.evictions = rawget(owner, "_evictions")
    return view
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
    return statsView(self)
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
---
---`cacheable` is the last parameter because closures created by revision 1
---call this with three arguments; they keep working and simply have no
---predicate.
---@param cache table
---@param compute fun(key: string|number): any
---@param key any
---@param cacheable CacheKit.Cacheable? decides whether a result is stored
---@return any value
local function memoizedCall(cache, compute, key, cacheable)
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
        local remembered = entry.value
        -- A negative entry the owner put on the cache stands in for "compute
        -- would find nothing": the caller sees `nil` and `compute` is spared.
        if remembered == NEGATIVE then
            return nil
        end
        return remembered
    end

    -- Only the first result is remembered, and `nil` is not remembered at all:
    -- a cache cannot store `nil`. A caller that wants a negative answer
    -- remembered returns `false`. The predicate sees exactly the result that
    -- would be stored, so an incomplete answer (item data not yet loaded)
    -- passes through and is computed again next time. `compute` and the
    -- predicate may close the cache they feed.
    local value = compute(key)
    if value == nil then
        return nil
    end
    if cacheable ~= nil and not cacheable(value, key) then
        return value
    end
    if rawget(cache, "_closed") ~= true then
        store(cache, key, value, expiryForNow(cache))
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
---@param maxEntries integer|table a positive integer or `CacheKit.UNBOUNDED`
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
        -- `math.huge` when the snapshot was opened with `CacheKit.UNBOUNDED`.
        _maxEntries = capacityOf(maxEntries),
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

-- Lazy tree internals --------------------------------------------------------
--
-- A lazy tree is a tree of nodes keyed by path part under an unkeyed `_root`.
-- A node is *expanded* when the resolver has answered for its path and the
-- answer is kept (`hasValue`); a node without a value exists only because a
-- descendant is expanded. Expanded nodes form the same intrusive recency list
-- caches use, so the bound evicts the least recently read expanded node, and
-- blank nodes go to the same kind of free list. Nodes are plain tables of
-- fixed shape, created with every field, so no later write rehashes them.

---@class CacheKit.LazyNode: CacheKit.Linked
---@field key string|number|false The path part this node answers to under its parent; `false` on the root.
---@field parent CacheKit.LazyNode|false
---@field children table<string|number, CacheKit.LazyNode>|false Created on the first child and kept, empty, when the node is recycled.
---@field childCount integer
---@field hasValue boolean Whether the node is expanded.
---@field value any The expanded value; `false` while not expanded.

---@return CacheKit.LazyNode
local function newNode()
    return {
        key = false,
        parent = false,
        children = false,
        childCount = 0,
        hasValue = false,
        value = false,
        newer = false,
        older = false,
    }
end

---Return a blank node, from the free list when it has one.
---@param lazy table
---@return CacheKit.LazyNode
local function takeNode(lazy)
    return popFree(lazy) or newNode()
end

---Follow `partCount` path parts from the root. Returns the node at the end of
---the path, expanded or not, or `nil` when the path leaves the tree.
---@param lazy table
---@param partCount integer
---@param ... string|number the path parts
---@return CacheKit.LazyNode|nil
local function findNode(lazy, partCount, ...)
    local node = rawget(lazy, "_root")
    for index = 1, partCount do
        local children = node.children
        if children == false then
            return nil
        end
        node = children[(select(index, ...))]
        if node == nil then
            return nil
        end
    end
    return node
end

---Follow `partCount` path parts from the root, creating every node the path
---is missing. Only structure is created here; the node returned is expanded
---by the caller.
---@param lazy table
---@param partCount integer
---@param ... string|number the path parts
---@return CacheKit.LazyNode
local function ensureNode(lazy, partCount, ...)
    local node = rawget(lazy, "_root")
    for index = 1, partCount do
        local part = (select(index, ...))
        local children = node.children
        if children == false then
            children = {}
            node.children = children
        end

        local child = children[part]
        if child == nil then
            child = takeNode(lazy)
            child.key = part
            child.parent = node
            children[part] = child
            node.childCount = node.childCount + 1
        end
        node = child
    end
    return node
end

---Forget an expanded node's value, leaving it in the tree as structure.
---@param lazy table
---@param node CacheKit.LazyNode an expanded node
local function dropValue(lazy, node)
    unlink(lazy, node)
    node.hasValue = false
    node.value = false
    rawset(lazy, "_count", rawget(lazy, "_count") - 1)
end

---Take a node with no value and no children out of its parent and recycle it.
---The node keeps its emptied `children` table (empty, so it retains no key),
---so a recycled node that gains a child again reuses it. Re-expanding an
---invalidated path reuses blank nodes and allocates one only when the free
---list is empty.
---@param lazy table
---@param node CacheKit.LazyNode
local function detachNode(lazy, node)
    local parent = node.parent --[[@as CacheKit.LazyNode]]
    parent.children[node.key] = nil
    parent.childCount = parent.childCount - 1

    node.key = false
    node.parent = false
    node.childCount = 0
    pushFree(lazy, node)
end

---Starting at `node`, remove every ancestor-or-self that no longer holds a
---value or a child, stopping at the first one that does and at the root. This
---is what keeps the count of unexpanded nodes bounded by the expanded ones:
---after it runs, every node without a value has an expanded descendant.
---@param lazy table
---@param node CacheKit.LazyNode
local function pruneUpwards(lazy, node)
    local root = rawget(lazy, "_root")
    while node ~= root and node.hasValue == false and node.childCount == 0 do
        local parent = node.parent --[[@as CacheKit.LazyNode]]
        detachNode(lazy, node)
        node = parent
    end
end

---Remove `node` and every descendant, forgetting their values. Returns how
---many expanded nodes were forgotten. Recursion depth is the path depth.
---@param lazy table
---@param node CacheKit.LazyNode a node other than the root
---@return integer dropped
local function removeSubtree(lazy, node)
    local dropped = 0
    local children = node.children
    if children ~= false then
        -- `detachNode` assigns `nil` to the key being visited, which `next`
        -- allows during a traversal.
        for _, child in next, children do
            dropped = dropped + removeSubtree(lazy, child)
        end
    end
    if node.hasValue then
        dropValue(lazy, node)
        dropped = dropped + 1
    end
    detachNode(lazy, node)
    return dropped
end

---Forget the least recently read expanded node to make room for another.
---@param lazy table
local function evictOldestNode(lazy)
    local node = rawget(lazy, "_oldest") --[[@as CacheKit.LazyNode]]
    rawset(lazy, "_evictions", rawget(lazy, "_evictions") + 1)
    dropValue(lazy, node)
    pruneUpwards(lazy, node)
end

---Keep `value` on `node`, evicting first when the tree is full. Eviction
---cannot touch `node` itself, which is not expanded, nor detach its ancestors,
---each of which has at least `node` beneath it.
---@param lazy table
---@param node CacheKit.LazyNode
---@param value any a non-nil value
local function expandNode(lazy, node, value)
    if node.hasValue then
        node.value = value
        touch(lazy, node)
        return
    end

    if rawget(lazy, "_count") >= rawget(lazy, "_maxEntries") then
        evictOldestNode(lazy)
    end
    node.hasValue = true
    node.value = value
    linkNewest(lazy, node)
    rawset(lazy, "_count", rawget(lazy, "_count") + 1)
end

---Invalidate a path: forget the value of every node on it, remove the node at
---its end with every descendant, and prune what is left empty. The path is
---followed as far as the tree goes; the ancestors it reaches lose their values
---even when the end of the path was never expanded, because a consumer saying
---"this changed" says nothing about how far its ancestors' values depended on
---it. Returns how many expanded nodes were forgotten.
---@param lazy table
---@param partCount integer
---@param ... string|number the path parts
---@return integer dropped
local function invalidatePath(lazy, partCount, ...)
    local node = rawget(lazy, "_root")
    local dropped = 0
    for index = 1, partCount do
        local children = node.children
        local child = nil
        if children ~= false then
            child = children[(select(index, ...))]
        end
        if child == nil then
            pruneUpwards(lazy, node)
            return dropped
        end

        if index == partCount then
            dropped = dropped + removeSubtree(lazy, child)
            pruneUpwards(lazy, node)
            return dropped
        end

        if child.hasValue then
            dropValue(lazy, child)
            dropped = dropped + 1
        end
        node = child
    end
    return dropped
end

---Remove every node under the root. Returns how many expanded nodes were
---forgotten.
---@param lazy table
---@return integer dropped
local function clearTree(lazy)
    local root = rawget(lazy, "_root")
    local children = root.children
    if children == false then
        return 0
    end

    local dropped = 0
    for _, child in next, children do
        dropped = dropped + removeSubtree(lazy, child)
    end
    return dropped
end

---Build an open, empty lazy tree. Every private field exists from the start,
---so no later write adds a key to the tree table.
---@param resolve CacheKit.Resolve
---@param maxEntries integer|table a positive integer or `CacheKit.UNBOUNDED`
---@return CacheKit.LazyTree
local function newLazyTree(resolve, maxEntries)
    local lazy = {
        _schema = LAZY_SCHEMA,
        _resolve = resolve,
        _root = newNode(),
        _newest = false,
        _oldest = false,
        -- Expanded nodes only; nodes kept as structure are not counted.
        _count = 0,
        -- `math.huge` when the tree was opened with `CacheKit.UNBOUNDED`.
        _maxEntries = capacityOf(maxEntries),
        _free = {},
        _freeCount = 0,
        _freeLimit = freeLimitOf(maxEntries),
        _hits = 0,
        _misses = 0,
        _evictions = 0,
        _statsView = false,
        _closed = false,
    }
    return setmetatable(lazy, LAZY_METATABLE)
end

-- Lazy tree methods ----------------------------------------------------------

---Return the value at the path, expanding it through `resolve` on first read.
---
---A path is one or more string or number parts. An expanded path is answered
---from the tree and becomes the most recently read; a path that is not
---expanded calls `resolve(parts...)`, keeps its first result unless that is
---`nil`, and returns it. When the tree already holds `maxEntries` expanded
---nodes, the least recently read one is forgotten first. `resolve` may read
---and invalidate other paths of the same tree.
---@param self CacheKit.LazyTree
---@param ... string|number the path parts
---@return any value
local function lazyGet(self, ...)
    validateLazy(self, "CacheKit.LazyTree:Get", 3)
    local partCount = validatePath("CacheKit.LazyTree:Get", 3, ...)
    if rawget(self, "_closed") == true then
        error("CacheKit.LazyTree:Get cannot expand a closed tree", 2)
    end

    local node = findNode(self, partCount, ...)
    if node ~= nil and node.hasValue then
        touch(self, node)
        rawset(self, "_hits", rawget(self, "_hits") + 1)
        return node.value
    end
    rawset(self, "_misses", rawget(self, "_misses") + 1)

    -- The tree is walked again after the resolver returns: it may have read,
    -- invalidated or closed parts of the tree, including this path's.
    local value = rawget(self, "_resolve")(...)
    if value == nil or rawget(self, "_closed") == true then
        return value
    end
    expandNode(self, ensureNode(self, partCount, ...), value)
    return value
end

---Return the value at the path without expanding it or marking it as read.
---@param self CacheKit.LazyTree
---@param ... string|number the path parts
---@return any value `nil` when the path is not expanded
local function lazyPeek(self, ...)
    validateLazy(self, "CacheKit.LazyTree:Peek", 3)
    local partCount = validatePath("CacheKit.LazyTree:Peek", 3, ...)
    if rawget(self, "_closed") == true then
        return nil
    end

    local node = findNode(self, partCount, ...)
    if node == nil or node.hasValue == false then
        return nil
    end
    return node.value
end

---Forget the path, everything under it and the values of everything above it.
---
---The node at the path and every descendant are removed, so their next read
---resolves again. Every ancestor on the path loses its value but keeps its
---other children, because a value an ancestor derived from its subtree is
---stale once part of that subtree changed. Siblings are untouched. Returns
---how many expanded nodes were forgotten; `0` when nothing on the path was
---expanded.
---@param self CacheKit.LazyTree
---@param ... string|number the path parts
---@return integer dropped
local function lazyInvalidate(self, ...)
    validateLazy(self, "CacheKit.LazyTree:Invalidate", 3)
    local partCount = validatePath("CacheKit.LazyTree:Invalidate", 3, ...)
    if rawget(self, "_closed") == true then
        return 0
    end
    return invalidatePath(self, partCount, ...)
end

---Forget every expanded node. Statistics are kept. Returns how many were
---expanded.
---@param self CacheKit.LazyTree
---@return integer dropped
local function lazyClear(self)
    validateLazy(self, "CacheKit.LazyTree:Clear", 3)
    if rawget(self, "_closed") == true then
        return 0
    end
    return clearTree(self)
end

---Return how many nodes are expanded.
---@param self CacheKit.LazyTree
---@return integer count
local function lazyGetCount(self)
    validateLazy(self, "CacheKit.LazyTree:GetCount", 3)
    return rawget(self, "_count")
end

---Return the tree's counters: `hits` and `misses` of `Get`, `evictions` made
---to stay within `maxEntries`. The same table is returned on every call.
---@param self CacheKit.LazyTree
---@return CacheKit.Stats stats
local function lazyGetStats(self)
    validateLazy(self, "CacheKit.LazyTree:GetStats", 3)
    return statsView(self)
end

---Close the tree: drop every node, value and blank node. Returns `false` when
---it was already closed. A closed tree answers `Peek` with `nil`,
---`Invalidate` and `Clear` with `0`, and refuses `Get`.
---@param self CacheKit.LazyTree
---@return boolean closed
local function lazyClose(self)
    validateLazy(self, "CacheKit.LazyTree:Close", 3)
    if rawget(self, "_closed") == true then
        return false
    end

    rawset(self, "_closed", true)
    rawset(self, "_root", false)
    rawset(self, "_newest", false)
    rawset(self, "_oldest", false)
    rawset(self, "_count", 0)
    rawset(self, "_free", false)
    rawset(self, "_freeCount", 0)
    return true
end

---Return whether the tree is closed.
---@param self CacheKit.LazyTree
---@return boolean
local function lazyIsClosed(self)
    validateLazy(self, "CacheKit.LazyTree:IsClosed", 3)
    return rawget(self, "_closed") == true
end

-- Queue internals ------------------------------------------------------------
--
-- A queue is an array of `capacity` slots allocated once, filled with `false`,
-- plus `_head`, the slot of the oldest value, and `_count`. Values live in
-- slots `_head`, `_head + 1`, ... wrapping at `capacity`. A popped slot is set
-- back to `false` so the queue retains nothing it no longer holds.

---The slot `offset` places after the oldest value, wrapping around the ring.
---@param queue table
---@param offset integer `0` for the oldest value
---@return integer slot
local function slotAfterHead(queue, offset)
    return (rawget(queue, "_head") - 1 + offset) % rawget(queue, "_capacity") + 1
end

---The `for` iterator behind `Iterate`: a module-level function with no
---upvalues, so starting an iteration allocates nothing.
---@param queue table
---@param position integer the position yielded last; `0` before the first
---@return integer? position
---@return any value
local function iterateQueue(queue, position)
    position = position + 1
    if position > rawget(queue, "_count") then
        return nil
    end
    return position, rawget(queue, "_slots")[slotAfterHead(queue, position - 1)]
end

---Build a queue with every slot preallocated.
---@param capacity integer
---@param overflow CacheKit.OverflowPolicy
---@return CacheKit.Queue
local function newQueue(capacity, overflow)
    local slots = {}
    for index = 1, capacity do
        slots[index] = false
    end

    local queue = {
        _schema = QUEUE_SCHEMA,
        _slots = slots,
        _capacity = capacity,
        _overflow = overflow,
        _head = 1,
        _count = 0,
    }
    return setmetatable(queue, QUEUE_METATABLE)
end

-- Queue methods --------------------------------------------------------------

---Add `value` behind the newest value.
---
---Returns `true` when the value was stored. On a full queue the overflow
---policy decides: `"dropOldest"` stores it, forgets the oldest value and
---returns `true, oldest`; `"dropNewest"` forgets the value pushed and returns
---`false, value`; `"reject"` stores nothing and returns `false`. `value`
---must not be `nil`; `false` is an ordinary value.
---@param self CacheKit.Queue
---@param value any anything except `nil`
---@return boolean stored
---@return any dropped the value forgotten, when one was
local function queuePush(self, value)
    validateQueue(self, "CacheKit.Queue:Push", 3)
    if value == nil then
        error("CacheKit.Queue:Push value must not be nil", 2)
    end

    local count = rawget(self, "_count")
    local slots = rawget(self, "_slots")
    if count < rawget(self, "_capacity") then
        slots[slotAfterHead(self, count)] = value
        rawset(self, "_count", count + 1)
        return true
    end

    local overflow = rawget(self, "_overflow")
    if overflow == "dropOldest" then
        -- Full, so the slot behind the newest value is the oldest one's:
        -- overwrite it and move the head past it.
        local head = rawget(self, "_head")
        local dropped = slots[head]
        slots[head] = value
        rawset(self, "_head", head % rawget(self, "_capacity") + 1)
        return true, dropped
    end
    if overflow == "dropNewest" then
        return false, value
    end
    return false
end

---Remove and return the oldest value, or `nil` when the queue is empty.
---@param self CacheKit.Queue
---@return any value
local function queuePop(self)
    validateQueue(self, "CacheKit.Queue:Pop", 3)
    local count = rawget(self, "_count")
    if count == 0 then
        return nil
    end

    local slots = rawget(self, "_slots")
    local head = rawget(self, "_head")
    local value = slots[head]
    slots[head] = false
    rawset(self, "_head", head % rawget(self, "_capacity") + 1)
    rawset(self, "_count", count - 1)
    return value
end

---Return the oldest value without removing it, or `nil` when the queue is
---empty.
---@param self CacheKit.Queue
---@return any value
local function queuePeek(self)
    validateQueue(self, "CacheKit.Queue:Peek", 3)
    if rawget(self, "_count") == 0 then
        return nil
    end
    return rawget(self, "_slots")[rawget(self, "_head")]
end

---Iterate the values from oldest to newest:
---`for position, value in queue:Iterate() do`. `position` counts from `1` at
---the oldest value. Allocates nothing. Do not push or pop during the loop.
---@param self CacheKit.Queue
---@return fun(queue: CacheKit.Queue, position: integer): integer?, any iterator
---@return CacheKit.Queue queue
---@return integer start
local function queueIterate(self)
    validateQueue(self, "CacheKit.Queue:Iterate", 3)
    return iterateQueue, self, 0
end

---Remove every value. Returns how many were held.
---@param self CacheKit.Queue
---@return integer removed
local function queueClear(self)
    validateQueue(self, "CacheKit.Queue:Clear", 3)
    local count = rawget(self, "_count")
    local slots = rawget(self, "_slots")
    for offset = 0, count - 1 do
        slots[slotAfterHead(self, offset)] = false
    end
    rawset(self, "_head", 1)
    rawset(self, "_count", 0)
    return count
end

---Return how many values the queue holds.
---@param self CacheKit.Queue
---@return integer count
local function queueGetCount(self)
    validateQueue(self, "CacheKit.Queue:GetCount", 3)
    return rawget(self, "_count")
end

---Return the capacity the queue was created with.
---@param self CacheKit.Queue
---@return integer capacity
local function queueGetCapacity(self)
    validateQueue(self, "CacheKit.Queue:GetCapacity", 3)
    return rawget(self, "_capacity")
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
---put a negative entry on it, or `Close` it. Only `fn`'s first result is
---remembered, and a `nil` result is not remembered at all. With
---`options.cacheable`, a result the predicate returns `false` or `nil` for is
---returned without being remembered.
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
    local cacheable = nil
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
        cacheable = rawget(options, "cacheable")
        if cacheable ~= nil and type(cacheable) ~= "function" then
            error("CacheKit:Memoize cacheable must be a function", 2)
        end
    end

    local cache = newCache(maxEntries, ttlSeconds)
    local function memoized(key)
        local call = rawget(dispatch, "memoizedCall")
        local value = call(cache, fn, key, cacheable)
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

---Create a lazy tree over `resolve`: a namespace whose paths are expanded by
---`resolve(parts...)` on first read and kept, bounded by `maxEntries`
---expanded nodes (128 by default) with the least recently read one evicted
---first. Nothing is resolved until the first `Get`.
---@param _ CacheKit
---@param resolve CacheKit.Resolve called with the path parts; its first result is kept unless `nil`
---@param options CacheKit.LazyOptions?
---@return CacheKit.LazyTree tree
local function packageLazy(_, resolve, options)
    if type(resolve) ~= "function" then
        error("CacheKit:Lazy resolve must be a function", 2)
    end

    local maxEntries = DEFAULT_LAZY_MAX_ENTRIES
    if options ~= nil then
        validateOptionKeys(options, LAZY_OPTION_KEYS, "CacheKit:Lazy", 3)
        if rawget(options, "maxEntries") ~= nil then
            maxEntries = rawget(options, "maxEntries")
            validateMaxEntries(maxEntries, "CacheKit:Lazy", 3)
        end
    end
    return newLazyTree(resolve, maxEntries)
end

---Create a ring queue of `capacity` slots, allocated now, whose behaviour
---when full is `overflow`: `"dropOldest"`, `"dropNewest"` or `"reject"`. Both
---arguments are required. `capacity` is an integer from 1 to the package-wide
---`maxQueueCapacity` (1024 by default; see `SetLimits`); `CacheKit.UNBOUNDED`
---is not accepted, because the ring is preallocated.
---@param _ CacheKit
---@param capacity integer a positive integer
---@param overflow CacheKit.OverflowPolicy
---@return CacheKit.Queue queue
local function packageNewQueue(_, capacity, overflow)
    validateCapacity(capacity, "CacheKit:NewQueue", 3)
    validateOverflowPolicy(overflow, "CacheKit:NewQueue", 3)
    return newQueue(capacity, overflow)
end

---Change any subset of the package-wide limits. The limits are shared by every
---consumer in the session. Lowering `maxQueueCapacity` never shrinks a queue;
---further `NewQueue` calls asking for more than the new value are refused
---until it allows them again. The whole table is validated first, so one
---invalid entry changes nothing.
---@param self CacheKit
---@param limits table any subset of `CacheKit.Limits`
local function packageSetLimits(self, limits)
    validateFacade(self, "CacheKit:SetLimits", 3)
    validateLimitUpdate(limits, 3)
    for index = 1, #LIMIT_NAMES do
        local name = LIMIT_NAMES[index]
        local value = rawget(limits, name)
        if value ~= nil then
            rawset(sharedLimits, name, value)
        end
    end
end

---Return a fresh copy of the package-wide limits. Allocates one table.
---@param self CacheKit
---@return CacheKit.Limits limits
local function packageGetLimits(self)
    validateFacade(self, "CacheKit:GetLimits", 3)
    local copy = {}
    for index = 1, #LIMIT_NAMES do
        local name = LIMIT_NAMES[index]
        copy[name] = rawget(sharedLimits, name)
    end
    return copy
end

-- Commit ---------------------------------------------------------------------

rawset(Cache, "Get", cacheGet)
rawset(Cache, "Set", cacheSet)
rawset(Cache, "PutNegative", cachePutNegative)
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

rawset(LazyTree, "Get", lazyGet)
rawset(LazyTree, "Peek", lazyPeek)
rawset(LazyTree, "Invalidate", lazyInvalidate)
rawset(LazyTree, "Clear", lazyClear)
rawset(LazyTree, "GetCount", lazyGetCount)
rawset(LazyTree, "GetStats", lazyGetStats)
rawset(LazyTree, "Close", lazyClose)
rawset(LazyTree, "IsClosed", lazyIsClosed)

rawset(Queue, "Push", queuePush)
rawset(Queue, "Pop", queuePop)
rawset(Queue, "Peek", queuePeek)
rawset(Queue, "Iterate", queueIterate)
rawset(Queue, "Clear", queueClear)
rawset(Queue, "GetCount", queueGetCount)
rawset(Queue, "GetCapacity", queueGetCapacity)

rawset(CacheKit, "API", API_GENERATION)
rawset(CacheKit, "REVISION", IMPLEMENTATION_REVISION)
rawset(CacheKit, "UNBOUNDED", UNBOUNDED)
rawset(CacheKit, "NewLru", packageNewLru)
rawset(CacheKit, "NewTtl", packageNewTtl)
rawset(CacheKit, "Memoize", packageMemoize)
rawset(CacheKit, "NewSnapshot", packageNewSnapshot)
rawset(CacheKit, "Lazy", packageLazy)
rawset(CacheKit, "NewQueue", packageNewQueue)
rawset(CacheKit, "SetLimits", packageSetLimits)
rawset(CacheKit, "GetLimits", packageGetLimits)

rawset(dispatch, "clearOnEvent", clearOnEvent)
rawset(dispatch, "memoizedCall", memoizedCall)
rawset(dispatch, "snapshotFill", snapshotFill)
rawset(state, "runtimeRevision", IMPLEMENTATION_REVISION)

if not validatePublicSurface(CacheKit) or not validateCurrentState(CacheKit) then
    error("MoltenCodes CacheKit package state is corrupted or incomplete", 2)
end

return CacheKit
