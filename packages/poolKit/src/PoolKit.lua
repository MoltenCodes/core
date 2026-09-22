-- MoltenCodes PoolKit
--
-- Allocation-conscious reusable object pools for World of Warcraft addons.
-- PoolKit is pure Lua: it owns object lifecycle and retention policy without
-- depending on Frames, timers, or other WoW APIs.

local PACKAGE_NAME = "poolKit"
local API_GENERATION = 1
local IMPLEMENTATION_REVISION = 2
local REQUIRED_REGISTRY_API = 2
local STATE_SCHEMA = 1
local DEFAULT_MAX_RETAINED = 128

-- Public types --------------------------------------------------------------
--
-- PoolKit publishes its methods by writing them onto a Registry-owned prototype
-- table, so the editor-facing contract is declared here as LuaCATS classes
-- rather than inferred from those assignments.

---Options shared by every pool constructor.
---@class PoolKit.CommonOptions
---@field maxRetained (integer|table)? Non-negative integer or `PoolKit.UNBOUNDED`; default `128`.
---@field strict boolean? Keep weak discarded-object history for richer duplicate-release diagnostics; default `true`.
---@field prewarm integer? Objects to create up front; default `0`.
---@field maxActiveWarning integer? Report once through `geterrorhandler` when this many objects are borrowed at the same time.

---Options accepted by `PoolKit:New`.
---@class PoolKit.NewOptions : PoolKit.CommonOptions
---@field create PoolKit.Factory Required factory.
---@field reset PoolKit.ObjectCallback? Called before retention or discard.
---@field destroy PoolKit.ObjectCallback? Called when an object leaves pool ownership.
---@field strictReset boolean? Refuse to construct a pool that has no `reset`; default `false`.

---The factory a pool calls when it has no retained object to hand out.
---@alias PoolKit.Factory fun(pool: PoolKit.Pool): table|userdata

---A per-object lifecycle callback: `reset` before retention, `destroy` on exit.
---@alias PoolKit.ObjectCallback fun(object: table|userdata, pool: PoolKit.Pool)

---A reusable object pool.
---@class PoolKit.Pool
---@field Acquire fun(self: PoolKit.Pool): table|userdata
---@field Release fun(self: PoolKit.Pool, object: table|userdata): boolean
---@field Prewarm fun(self: PoolKit.Pool, count: integer): integer
---@field Trim fun(self: PoolKit.Pool, retainCount: integer?): integer
---@field Clear fun(self: PoolKit.Pool): integer
---@field Close fun(self: PoolKit.Pool): boolean
---@field IsClosed fun(self: PoolKit.Pool): boolean
---@field GetAvailableCount fun(self: PoolKit.Pool): integer
---@field GetActiveCount fun(self: PoolKit.Pool): integer
---@field GetCreatedCount fun(self: PoolKit.Pool): integer
---@field GetDiscardedCount fun(self: PoolKit.Pool): integer
---@field GetMaxRetained fun(self: PoolKit.Pool): integer|table
---@field SetMaxRetained fun(self: PoolKit.Pool, maxRetained: integer|table): PoolKit.Pool
---@field Owns fun(self: PoolKit.Pool, object: any): boolean
---@field IsActive fun(self: PoolKit.Pool, object: any): boolean

---The PoolKit package facade published through Registry.
---@class PoolKit
---@field API integer Public API generation.
---@field REVISION integer Compatible implementation revision.
---@field Pool PoolKit.Pool Shared pool prototype.
---@field UNBOUNDED table Sentinel selecting caller-owned unbounded retention.
---@field DEFAULT_MAX_RETAINED integer
---@field New fun(self: PoolKit, options: PoolKit.NewOptions): PoolKit.Pool
---@field NewTablePool fun(self: PoolKit, options: PoolKit.CommonOptions?): PoolKit.Pool

-- Dependencies --------------------------------------------------------------

-- The shared MoltenCodes namespace is the one documented global handoff point between independently embedded copies.
-- selene: allow(global_usage)
local namespace = rawget(_G, "MoltenCodes")
if type(namespace) ~= "table" then
    error("MoltenCodes PoolKit requires Registry API 2 to be loaded first", 2)
end

local Registry = rawget(namespace, "Registry")
if type(Registry) ~= "table" or rawget(Registry, "API") ~= REQUIRED_REGISTRY_API then
    error("MoltenCodes PoolKit requires Registry API 2 to be loaded first", 2)
end

local registerPackage = rawget(Registry, "Register")
local getPackage = rawget(Registry, "Get")
if type(registerPackage) ~= "function" or type(getPackage) ~= "function" then
    error("MoltenCodes PoolKit requires a valid Registry API 2 facade", 2)
end

-- Bootstrap -----------------------------------------------------------------

---Whether `implementation` exposes the complete PoolKit API 1 surface.
---@param implementation any shared package table handed back by Registry
---@return boolean
local function validatePublicSurface(implementation)
    if
        type(implementation) ~= "table"
        or rawget(implementation, "API") ~= API_GENERATION
        or type(rawget(implementation, "REVISION")) ~= "number"
        or type(rawget(implementation, "Pool")) ~= "table"
        or type(rawget(implementation, "UNBOUNDED")) ~= "table"
        or rawget(implementation, "DEFAULT_MAX_RETAINED") ~= DEFAULT_MAX_RETAINED
    then
        return false
    end

    local Pool = rawget(implementation, "Pool")
    return type(rawget(implementation, "New")) == "function"
        and type(rawget(implementation, "NewTablePool")) == "function"
        and type(rawget(Pool, "Acquire")) == "function"
        and type(rawget(Pool, "Release")) == "function"
        and type(rawget(Pool, "Prewarm")) == "function"
        and type(rawget(Pool, "Trim")) == "function"
        and type(rawget(Pool, "Clear")) == "function"
        and type(rawget(Pool, "Close")) == "function"
        and type(rawget(Pool, "IsClosed")) == "function"
        and type(rawget(Pool, "GetAvailableCount")) == "function"
        and type(rawget(Pool, "GetActiveCount")) == "function"
        and type(rawget(Pool, "GetCreatedCount")) == "function"
        and type(rawget(Pool, "GetDiscardedCount")) == "function"
        and type(rawget(Pool, "GetMaxRetained")) == "function"
        and type(rawget(Pool, "SetMaxRetained")) == "function"
        and type(rawget(Pool, "Owns")) == "function"
        and type(rawget(Pool, "IsActive")) == "function"
end

---Whether `currentState` has the shape this revision's schema requires.
---@param currentState any
---@return boolean
local function validateState(currentState)
    return type(currentState) == "table"
        and rawget(currentState, "schema") == STATE_SCHEMA
        and type(rawget(currentState, "poolMetatable")) == "table"
        and type(rawget(currentState, "unbounded")) == "table"
end

---Whether `implementation` and its package state still agree with each other.
---@param implementation table
---@return boolean
local function validateCurrentState(implementation)
    local currentState = rawget(implementation, "_state")
    if not validateState(currentState) then
        return false
    end

    return rawget(implementation, "UNBOUNDED") == rawget(currentState, "unbounded")
        and rawget(implementation, "DEFAULT_MAX_RETAINED") == DEFAULT_MAX_RETAINED
        and rawget(rawget(currentState, "poolMetatable"), "__index")
            == rawget(implementation, "Pool")
end

local existing, existingRevision = getPackage(Registry, PACKAGE_NAME, API_GENERATION)
if existing ~= nil then
    if type(existing) ~= "table" or rawget(existing, "API") ~= API_GENERATION then
        error("MoltenCodes PoolKit package state is corrupted or incomplete", 2)
    end

    local facadeRevision = rawget(existing, "REVISION")
    if type(facadeRevision) ~= "number" or facadeRevision > existingRevision then
        error("MoltenCodes PoolKit package state is corrupted or incomplete", 2)
    end

    if existingRevision > IMPLEMENTATION_REVISION then
        if facadeRevision ~= existingRevision or not validatePublicSurface(existing) then
            error("MoltenCodes PoolKit package state is corrupted or incomplete", 2)
        end
        return existing
    elseif existingRevision == IMPLEMENTATION_REVISION then
        if
            facadeRevision ~= existingRevision
            or not validatePublicSurface(existing)
            or not validateCurrentState(existing)
        then
            error("MoltenCodes PoolKit package state is corrupted or incomplete", 2)
        end
        return existing
    end
end

local PoolKit, previousRevision =
    registerPackage(Registry, PACKAGE_NAME, API_GENERATION, IMPLEMENTATION_REVISION)
if PoolKit == nil then
    return existing
end

local Pool = rawget(PoolKit, "Pool")
local state = rawget(PoolKit, "_state")

if previousRevision == nil then
    if Pool ~= nil or state ~= nil then
        error("MoltenCodes PoolKit package state is corrupted or incomplete", 2)
    end

    Pool = {}
    state = {
        schema = STATE_SCHEMA,
        poolMetatable = {},
        unbounded = {},
    }
    rawset(PoolKit, "Pool", Pool)
    rawset(PoolKit, "_state", state)
elseif type(Pool) ~= "table" or not validateState(state) then
    error("MoltenCodes PoolKit package state is corrupted or incomplete", 2)
end

local POOL_METATABLE = rawget(state, "poolMetatable")
local UNBOUNDED = rawget(state, "unbounded")
rawset(POOL_METATABLE, "__index", Pool)

local ACTIVE = 1
local RELEASING = 2

-- Validation ----------------------------------------------------------------

---Whether `value` is an exact integer of zero or more. `nan` and both
---infinities are rejected before the integer test can accept them.
---@param value any
---@return boolean
local function isNonNegativeInteger(value)
    return type(value) == "number"
        and value == value
        and value ~= math.huge
        and value ~= -math.huge
        and value >= 0
        and value % 1 == 0
end

-- Argument validation raises with an explicit stack level so the reported
-- position is the line that called the public method, never a line inside
-- PoolKit. `level` is always the value `error` needs *inside the function that
-- receives it*, so every further hop towards `error` adds exactly one.
--
-- Level `0` means "no position information" and must stay `0` through every
-- hop. The constructor-time prewarm path needs it: that failure is caught and
-- re-raised verbatim, so a position computed across the `pcall` boundary would
-- be meaningless.
---Return the stack level one hop further from `error`, preserving level `0`.
---@param level integer
---@return integer
local function nestedLevel(level)
    if level == 0 then
        return 0
    end
    return level + 1
end

---@param self any receiver the public method was called on
---@param methodName string public method name, used in the argument error
---@param level integer stack level the failure is reported at
local function validatePool(self, methodName, level)
    if type(self) ~= "table" or getmetatable(self) ~= POOL_METATABLE then
        error(methodName .. " must be called on a PoolKit pool", level)
    end
end

---@param object any
---@param label string argument description, used in the argument error
---@param level integer stack level the failure is reported at
local function validatePoolObject(object, label, level)
    local objectType = type(object)
    if objectType ~= "table" and objectType ~= "userdata" then
        error(label .. " must be a table or userdata", level)
    end
end

---@param value any non-negative integer or `PoolKit.UNBOUNDED`
---@param label string argument description, used in the argument error
---@param level integer stack level the failure is reported at
---@return integer|table maxRetained
local function validateMaxRetained(value, label, level)
    if value == UNBOUNDED then
        return value
    end
    if not isNonNegativeInteger(value) then
        error(label .. " must be a non-negative integer or PoolKit.UNBOUNDED", level)
    end
    return value
end

---@param value any
---@param label string argument description, used in the argument error
---@param level integer stack level the failure is reported at
local function validateCount(value, label, level)
    if not isNonNegativeInteger(value) then
        error(label .. " must be a non-negative integer", level)
    end
end

---@param value any
---@param label string argument description, used in the argument error
---@param required boolean whether `nil` is rejected
---@param level integer stack level the failure is reported at
local function validateCallback(value, label, required, level)
    if value == nil and not required then
        return
    end
    if type(value) ~= "function" then
        error(label .. " must be a function", level)
    end
end

local GENERIC_OPTION_KEYS = {
    create = true,
    reset = true,
    destroy = true,
    maxRetained = true,
    strict = true,
    strictReset = true,
    prewarm = true,
    maxActiveWarning = true,
}

local TABLE_OPTION_KEYS = {
    maxRetained = true,
    strict = true,
    prewarm = true,
    maxActiveWarning = true,
}

---Reject the alphabetically first unrecognised option field, if any.
---@param options table
---@param allowed table<string, boolean>
---@param methodName string public method name, used in the argument error
---@param level integer stack level the failure is reported at
local function validateKnownFields(options, allowed, methodName, level)
    local firstUnknown = nil
    for key in next, options do
        if allowed[key] ~= true then
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

---Validate the options every constructor shares and apply their defaults.
---@param options PoolKit.CommonOptions|nil
---@param allowed table<string, boolean> option keys this constructor accepts
---@param methodName string public method name, used in the argument errors
---@param level integer stack level the failures are reported at
---@return integer|table maxRetained
---@return boolean strict
---@return integer prewarm
---@return integer|false maxActiveWarning `false` when leak warnings are disabled
local function parseCommonOptions(options, allowed, methodName, level)
    if options == nil then
        options = {}
    elseif type(options) ~= "table" then
        error(methodName .. " options must be a table", level)
    end

    validateKnownFields(options, allowed, methodName, level + 1)

    local maxRetained = rawget(options, "maxRetained")
    if maxRetained == nil then
        maxRetained = DEFAULT_MAX_RETAINED
    else
        maxRetained = validateMaxRetained(maxRetained, methodName .. " maxRetained", level + 1)
    end

    local strict = rawget(options, "strict")
    if strict == nil then
        strict = true
    elseif type(strict) ~= "boolean" then
        error(methodName .. " strict must be a boolean", level)
    end

    local prewarm = rawget(options, "prewarm")
    if prewarm == nil then
        prewarm = 0
    else
        validateCount(prewarm, methodName .. " prewarm", level + 1)
    end

    if maxRetained ~= UNBOUNDED and prewarm > maxRetained then
        error(methodName .. " prewarm cannot exceed maxRetained", level)
    end

    -- Leak diagnostics are opt-in. `false` means "never warn" and is the value
    -- the acquire hot path compares against, so the default costs one
    -- comparison per `Acquire`.
    local maxActiveWarning = rawget(options, "maxActiveWarning")
    if maxActiveWarning == nil then
        maxActiveWarning = false
    else
        validateCount(maxActiveWarning, methodName .. " maxActiveWarning", level + 1)
    end

    return maxRetained, strict, prewarm, maxActiveWarning
end

-- Error helpers --------------------------------------------------------------

---Keep the first failure of a best-effort loop, wrapped so `nil` survives.
---@param firstError table|nil
---@param ok boolean
---@param value any
---@return table|nil firstError
local function captureFirstError(firstError, ok, value)
    if not ok and firstError == nil then
        return { value = value }
    end
    return firstError
end

---Re-raise a captured failure unchanged, or return when there was none.
---@param firstError table|nil
local function raiseCaptured(firstError)
    if firstError ~= nil then
        error(firstError.value, 0)
    end
end

-- Diagnostics ----------------------------------------------------------------

---Report a non-fatal diagnostic through the host error handler, best-effort.
---PoolKit is pure Lua, so a host without `geterrorhandler` simply stays silent.
---@param value any
local function reportWarning(value)
    -- geterrorhandler is the World of Warcraft client error sink, published as a global.
    -- selene: allow(global_usage)
    local getErrorHandler = rawget(_G, "geterrorhandler")
    if type(getErrorHandler) ~= "function" then
        return
    end

    local ok, handler = pcall(getErrorHandler)
    if not ok or type(handler) ~= "function" then
        return
    end
    pcall(handler, value)
end

-- Internal lifecycle ---------------------------------------------------------

---Refuse a mutation attempted from inside one of this pool's own callbacks.
---@param pool PoolKit.Pool
---@param methodName string public method name, used in the argument error
---@param level integer stack level the failure is reported at
local function ensureMutationAllowed(pool, methodName, level)
    if rawget(pool, "_callbackDepth") > 0 then
        error(
            methodName
                .. " cannot mutate this pool during its "
                .. rawget(pool, "_callbackPhase")
                .. " callback",
            level
        )
    end
end

-- The guard is a depth counter rather than a flag, and the previous phase name
-- is restored rather than cleared. A nested lifecycle callback on the same pool
-- therefore cannot hand the outer callback a pool that looks unguarded, and the
-- rejection message keeps naming the phase the caller is actually inside.
---Run one user lifecycle callback with the re-entrancy guard raised.
---@param pool PoolKit.Pool
---@param phase "create"|"reset"|"destroy"
---@param callback function
---@param ... any arguments forwarded to `callback`
---@return any result
local function invokeLifecycleCallback(pool, phase, callback, ...)
    local depth = rawget(pool, "_callbackDepth") + 1
    local previousPhase = rawget(pool, "_callbackPhase")
    rawset(pool, "_callbackDepth", depth)
    rawset(pool, "_callbackPhase", phase)

    local ok, value = pcall(callback, ...)

    rawset(pool, "_callbackDepth", depth - 1)
    rawset(pool, "_callbackPhase", previousPhase)
    if not ok then
        error(value, 0)
    end
    return value
end

---Record that `object` has left this pool's ownership.
---@param pool PoolKit.Pool
---@param object table|userdata
local function markDiscarded(pool, object)
    local released = rawget(pool, "_released")
    if released ~= false then
        rawset(released, object, true)
    end
    rawset(pool, "_discardedCount", rawget(pool, "_discardedCount") + 1)
end

---Mark `object` discarded and run the pool's `destroy` callback for it.
---@param pool PoolKit.Pool
---@param object table|userdata
local function destroyDiscarded(pool, object)
    markDiscarded(pool, object)
    local destroy = rawget(pool, "_destroy")
    if destroy ~= false then
        invokeLifecycleCallback(pool, "destroy", destroy, object, pool)
    end
end

---Reject a factory result this pool already owns or cannot pool at all.
---@param pool PoolKit.Pool
---@param object any
---@param methodName string public method name, used in the argument error
---@param level integer stack level the failure is reported at
local function validateFactoryObject(pool, object, methodName, level)
    validatePoolObject(object, methodName .. " factory result", nestedLevel(level))

    local active = rawget(pool, "_active")
    local retained = rawget(pool, "_retained")
    if rawget(active, object) ~= nil or rawget(retained, object) == true then
        error(methodName .. " factory returned an object already owned by this pool", level)
    end

    local released = rawget(pool, "_released")
    if released ~= false then
        rawset(released, object, nil)
    end
end

---Build one new object through the pool's factory and count it.
---@param pool PoolKit.Pool
---@param methodName string public method name, used in the argument error
---@param level integer stack level the failure is reported at
---@return table|userdata object
local function createObject(pool, methodName, level)
    local create = rawget(pool, "_create")
    local object
    if rawget(pool, "_trustedCallbacks") == true then
        object = create(pool)
    else
        object = invokeLifecycleCallback(pool, "create", create, pool)
    end
    validateFactoryObject(pool, object, methodName, nestedLevel(level))
    rawset(pool, "_createdCount", rawget(pool, "_createdCount") + 1)
    return object
end

---Whether the pool has room to retain one more released object.
---@param pool PoolKit.Pool
---@return boolean
local function canRetain(pool)
    local maxRetained = rawget(pool, "_maxRetained")
    return maxRetained == UNBOUNDED or rawget(pool, "_availableCount") < maxRetained
end

---Drop one retained object, reporting a failing `destroy` to the caller.
---@param pool PoolKit.Pool
---@param object table|userdata
---@return boolean ok
---@return any errorValue
local function discardAvailableObject(pool, object)
    local retained = rawget(pool, "_retained")
    rawset(retained, object, nil)
    return pcall(destroyDiscarded, pool, object)
end

---Reduce retention to `retainCount` objects, destroying the rest.
---@param pool PoolKit.Pool
---@param retainCount integer
---@return integer removed
local function trimTo(pool, retainCount)
    local available = rawget(pool, "_available")
    local count = rawget(pool, "_availableCount")
    if retainCount >= count then
        return 0
    end

    -- Detach the complete trim snapshot before invoking user destroy callbacks.
    -- A destroy callback may legally interact with the pool again; publishing
    -- the final available count first prevents re-entrant operations from
    -- observing a half-mutated stack or being overwritten by this trim pass.
    local removed = count - retainCount
    local discarded = {}
    local discardedIndex = 0
    while count > retainCount do
        discardedIndex = discardedIndex + 1
        discarded[discardedIndex] = rawget(available, count)
        rawset(available, count, nil)
        count = count - 1
    end
    rawset(pool, "_availableCount", count)

    local firstError = nil
    for index = 1, discardedIndex do
        local ok, value = discardAvailableObject(pool, discarded[index])
        firstError = captureFirstError(firstError, ok, value)
    end

    raiseCaptured(firstError)
    return removed
end

---Create objects until `targetCount` of them are immediately available.
---@param pool PoolKit.Pool
---@param targetCount integer
---@param level integer stack level failures are reported at; `0` for construction
---@return integer created
local function prewarmInternal(pool, targetCount, level)
    if rawget(pool, "_closed") == true then
        error("PoolKit.Pool:Prewarm cannot use a closed pool", level)
    end

    local maxRetained = rawget(pool, "_maxRetained")
    if maxRetained ~= UNBOUNDED and targetCount > maxRetained then
        error("PoolKit.Pool:Prewarm target cannot exceed maxRetained", level)
    end

    local available = rawget(pool, "_available")
    local retained = rawget(pool, "_retained")
    local count = rawget(pool, "_availableCount")
    local created = 0

    while count < targetCount do
        local object = createObject(pool, "PoolKit.Pool:Prewarm", nestedLevel(level))
        count = count + 1
        created = created + 1
        rawset(available, count, object)
        rawset(retained, object, true)
    end

    rawset(pool, "_availableCount", count)
    return created
end

---Construct one pool and, when asked, prewarm it before it escapes.
---@param create PoolKit.Factory
---@param reset PoolKit.ObjectCallback|nil
---@param destroy PoolKit.ObjectCallback|nil
---@param maxRetained integer|table
---@param strict boolean
---@param prewarm integer
---@param maxActiveWarning integer|false
---@param trustedCallbacks boolean whether PoolKit itself owns the callbacks
---@return PoolKit.Pool
local function newPool(
    create,
    reset,
    destroy,
    maxRetained,
    strict,
    prewarm,
    maxActiveWarning,
    trustedCallbacks
)
    -- `false` rather than `nil` so the hot path can test the field with one
    -- comparison instead of distinguishing "absent" from "empty".
    ---@type table|false
    local released = false
    if strict then
        released = setmetatable({}, { __mode = "k" })
    end

    local pool = setmetatable({
        _create = create,
        _reset = reset or false,
        _destroy = destroy or false,
        _maxRetained = maxRetained,
        _strict = strict,
        _available = {},
        _availableCount = 0,
        _active = {},
        _activeCount = 0,
        _maxActiveWarning = maxActiveWarning,
        _activeWarned = false,
        _retained = {},
        _released = released,
        _createdCount = 0,
        _discardedCount = 0,
        _closed = false,
        _callbackPhase = false,
        _callbackDepth = 0,
        _trustedCallbacks = trustedCallbacks == true,
    }, POOL_METATABLE)

    if prewarm > 0 then
        -- The failure is re-raised verbatim below, so level 0 keeps a
        -- meaningless position computed across this `pcall` out of the message.
        local ok, value = pcall(prewarmInternal, pool, prewarm, 0)
        if not ok then
            -- Construction failed and the pool will not escape. Drop any
            -- successfully prewarmed objects best-effort before rethrowing the
            -- original construction failure.
            pcall(trimTo, pool, 0)
            error(value, 0)
        end
    end

    return pool
end

-- Pool methods ---------------------------------------------------------------

---Report a leak threshold once. Kept out of `poolAcquire` so the disabled
---default costs one comparison and no extra frame on the hot path.
---@param pool PoolKit.Pool
---@param activeCount integer
local function warnActiveThreshold(pool, activeCount)
    rawset(pool, "_activeWarned", true)
    reportWarning(
        "PoolKit pool has "
            .. tostring(activeCount)
            .. " objects borrowed at once, at or above its maxActiveWarning threshold of "
            .. tostring(rawget(pool, "_maxActiveWarning"))
            .. ". Active objects are caller-owned and unbounded: PoolKit cannot"
            .. " reclaim one that is never released. This is reported once per pool."
    )
end

---Borrow one object, reusing the most recently retained object when available.
---@param self PoolKit.Pool
---@return table|userdata object
local function poolAcquire(self)
    validatePool(self, "PoolKit.Pool:Acquire", 3)
    ensureMutationAllowed(self, "PoolKit.Pool:Acquire", 3)
    if rawget(self, "_closed") == true then
        error("PoolKit.Pool:Acquire cannot use a closed pool", 2)
    end

    local available = rawget(self, "_available")
    local count = rawget(self, "_availableCount")
    local object

    if count > 0 then
        object = rawget(available, count)
        rawset(available, count, nil)
        rawset(self, "_availableCount", count - 1)
        rawset(rawget(self, "_retained"), object, nil)
    else
        object = createObject(self, "PoolKit.Pool:Acquire", 3)
    end

    local released = rawget(self, "_released")
    if released ~= false then
        rawset(released, object, nil)
    end

    rawset(rawget(self, "_active"), object, ACTIVE)
    local activeCount = rawget(self, "_activeCount") + 1
    rawset(self, "_activeCount", activeCount)

    local warnAt = rawget(self, "_maxActiveWarning")
    if warnAt ~= false and activeCount >= warnAt and rawget(self, "_activeWarned") ~= true then
        warnActiveThreshold(self, activeCount)
    end
    return object
end

---Reset and return an active object; discard it when retention is full or the
---pool is closed.
---@param self PoolKit.Pool
---@param object table|userdata
---@return boolean released
local function poolRelease(self, object)
    validatePool(self, "PoolKit.Pool:Release", 3)
    ensureMutationAllowed(self, "PoolKit.Pool:Release", 3)
    validatePoolObject(object, "PoolKit.Pool:Release object", 3)

    local active = rawget(self, "_active")
    local status = rawget(active, object)
    if status ~= ACTIVE then
        if status == RELEASING then
            error("PoolKit.Pool:Release release is already in progress for this object", 2)
        end
        if rawget(rawget(self, "_retained"), object) == true then
            error("PoolKit.Pool:Release object has already been released", 2)
        end
        local released = rawget(self, "_released")
        if released ~= false and rawget(released, object) == true then
            error("PoolKit.Pool:Release object has already been released", 2)
        end
        error("PoolKit.Pool:Release object was not acquired from this pool", 2)
    end

    rawset(active, object, RELEASING)
    local reset = rawget(self, "_reset")
    if reset ~= false then
        if rawget(self, "_trustedCallbacks") == true then
            reset(object, self)
        else
            local ok, value = pcall(invokeLifecycleCallback, self, "reset", reset, object, self)
            if not ok then
                rawset(active, object, ACTIVE)
                error(value, 0)
            end
        end
    end

    rawset(active, object, nil)
    rawset(self, "_activeCount", rawget(self, "_activeCount") - 1)

    if rawget(self, "_closed") ~= true and canRetain(self) then
        local count = rawget(self, "_availableCount") + 1
        rawset(rawget(self, "_available"), count, object)
        rawset(rawget(self, "_retained"), object, true)
        rawset(self, "_availableCount", count)
        return true
    end

    destroyDiscarded(self, object)
    return true
end

---Ensure at least `count` objects are immediately available.
---@param self PoolKit.Pool
---@param count integer
---@return integer created
local function poolPrewarm(self, count)
    validatePool(self, "PoolKit.Pool:Prewarm", 3)
    ensureMutationAllowed(self, "PoolKit.Pool:Prewarm", 3)
    validateCount(count, "PoolKit.Pool:Prewarm count", 3)
    return prewarmInternal(self, count, 3)
end

---Reduce retention to `retainCount` objects, or to none by default.
---@param self PoolKit.Pool
---@param retainCount integer? defaults to `0`
---@return integer removed
local function poolTrim(self, retainCount)
    validatePool(self, "PoolKit.Pool:Trim", 3)
    ensureMutationAllowed(self, "PoolKit.Pool:Trim", 3)
    if retainCount == nil then
        retainCount = 0
    else
        validateCount(retainCount, "PoolKit.Pool:Trim retainCount", 3)
    end
    return trimTo(self, retainCount)
end

---Destroy every retained object while keeping the pool usable.
---@param self PoolKit.Pool
---@return integer removed
local function poolClear(self)
    validatePool(self, "PoolKit.Pool:Clear", 3)
    ensureMutationAllowed(self, "PoolKit.Pool:Clear", 3)
    return trimTo(self, 0)
end

---Terminally close the pool after destroying everything it retains.
---@param self PoolKit.Pool
---@return boolean closed `false` when the pool was already closed.
local function poolClose(self)
    validatePool(self, "PoolKit.Pool:Close", 3)
    ensureMutationAllowed(self, "PoolKit.Pool:Close", 3)
    if rawget(self, "_closed") == true then
        return false
    end
    rawset(self, "_closed", true)
    trimTo(self, 0)
    return true
end

---Whether the pool is terminally closed.
---@param self PoolKit.Pool
---@return boolean closed
local function poolIsClosed(self)
    validatePool(self, "PoolKit.Pool:IsClosed", 3)
    return rawget(self, "_closed") == true
end

---Number of objects retained and ready to hand out.
---@param self PoolKit.Pool
---@return integer availableCount
local function poolGetAvailableCount(self)
    validatePool(self, "PoolKit.Pool:GetAvailableCount", 3)
    return rawget(self, "_availableCount")
end

---Number of objects currently borrowed. These are caller-owned and unbounded.
---@param self PoolKit.Pool
---@return integer activeCount
local function poolGetActiveCount(self)
    validatePool(self, "PoolKit.Pool:GetActiveCount", 3)
    return rawget(self, "_activeCount")
end

---Number of objects this pool has ever built through its factory.
---@param self PoolKit.Pool
---@return integer createdCount
local function poolGetCreatedCount(self)
    validatePool(self, "PoolKit.Pool:GetCreatedCount", 3)
    return rawget(self, "_createdCount")
end

---Number of objects this pool has released from its ownership.
---@param self PoolKit.Pool
---@return integer discardedCount
local function poolGetDiscardedCount(self)
    validatePool(self, "PoolKit.Pool:GetDiscardedCount", 3)
    return rawget(self, "_discardedCount")
end

---Current retention bound, or `PoolKit.UNBOUNDED`.
---@param self PoolKit.Pool
---@return integer|table maxRetained
local function poolGetMaxRetained(self)
    validatePool(self, "PoolKit.Pool:GetMaxRetained", 3)
    return rawget(self, "_maxRetained")
end

---Change the retention bound, trimming immediately when it shrinks.
---@param self PoolKit.Pool
---@param maxRetained integer|table non-negative integer or `PoolKit.UNBOUNDED`
---@return PoolKit.Pool self
local function poolSetMaxRetained(self, maxRetained)
    validatePool(self, "PoolKit.Pool:SetMaxRetained", 3)
    ensureMutationAllowed(self, "PoolKit.Pool:SetMaxRetained", 3)
    maxRetained = validateMaxRetained(maxRetained, "PoolKit.Pool:SetMaxRetained maxRetained", 3)
    rawset(self, "_maxRetained", maxRetained)
    if maxRetained ~= UNBOUNDED then
        -- `UNBOUNDED` is the only non-integer `validateMaxRetained` accepts.
        ---@cast maxRetained integer
        trimTo(self, maxRetained)
    end
    return self
end

---Whether `object` is borrowed from or retained by this pool.
---@param self PoolKit.Pool
---@param object any
---@return boolean owned
local function poolOwns(self, object)
    validatePool(self, "PoolKit.Pool:Owns", 3)
    local objectType = type(object)
    if objectType ~= "table" and objectType ~= "userdata" then
        return false
    end
    return rawget(rawget(self, "_active"), object) ~= nil
        or rawget(rawget(self, "_retained"), object) == true
end

---Whether `object` is currently borrowed from this pool.
---@param self PoolKit.Pool
---@param object any
---@return boolean active
local function poolIsActive(self, object)
    validatePool(self, "PoolKit.Pool:IsActive", 3)
    local objectType = type(object)
    if objectType ~= "table" and objectType ~= "userdata" then
        return false
    end
    local status = rawget(rawget(self, "_active"), object)
    return status == ACTIVE or status == RELEASING
end

-- Package constructors -------------------------------------------------------

---Create a generic object pool.
---@param _ PoolKit
---@param options PoolKit.NewOptions
---@return PoolKit.Pool pool
local function packageNew(_, options)
    if type(options) ~= "table" then
        error("PoolKit:New options must be a table", 2)
    end
    local create = rawget(options, "create")
    local reset = rawget(options, "reset")
    local destroy = rawget(options, "destroy")
    validateCallback(create, "PoolKit:New create", true, 3)
    validateCallback(reset, "PoolKit:New reset", false, 3)
    validateCallback(destroy, "PoolKit:New destroy", false, 3)

    -- A construction-time check only: `strictReset` never reaches the pool, so
    -- opting into it costs the acquire/release hot paths nothing.
    local strictReset = rawget(options, "strictReset")
    if strictReset ~= nil and type(strictReset) ~= "boolean" then
        error("PoolKit:New strictReset must be a boolean", 2)
    end
    if strictReset == true and reset == nil then
        error("PoolKit:New strictReset requires a reset callback", 2)
    end

    local maxRetained, strict, prewarm, maxActiveWarning =
        parseCommonOptions(options, GENERIC_OPTION_KEYS, "PoolKit:New", 3)
    return newPool(create, reset, destroy, maxRetained, strict, prewarm, maxActiveWarning, false)
end

---Factory for `PoolKit:NewTablePool`.
---@return table
local function tableCreate()
    return {}
end

---Shallow-clearing reset for `PoolKit:NewTablePool`.
---@param object table
local function tableReset(object)
    for key in next, object do
        rawset(object, key, nil)
    end
end

---Create a shallow-clearing Lua table pool.
---@param _ PoolKit
---@param options PoolKit.CommonOptions?
---@return PoolKit.Pool pool
local function packageNewTablePool(_, options)
    local maxRetained, strict, prewarm, maxActiveWarning =
        parseCommonOptions(options, TABLE_OPTION_KEYS, "PoolKit:NewTablePool", 3)
    return newPool(
        tableCreate,
        tableReset,
        nil,
        maxRetained,
        strict,
        prewarm,
        maxActiveWarning,
        true
    )
end

-- Commit --------------------------------------------------------------------

rawset(Pool, "Acquire", poolAcquire)
rawset(Pool, "Release", poolRelease)
rawset(Pool, "Prewarm", poolPrewarm)
rawset(Pool, "Trim", poolTrim)
rawset(Pool, "Clear", poolClear)
rawset(Pool, "Close", poolClose)
rawset(Pool, "IsClosed", poolIsClosed)
rawset(Pool, "GetAvailableCount", poolGetAvailableCount)
rawset(Pool, "GetActiveCount", poolGetActiveCount)
rawset(Pool, "GetCreatedCount", poolGetCreatedCount)
rawset(Pool, "GetDiscardedCount", poolGetDiscardedCount)
rawset(Pool, "GetMaxRetained", poolGetMaxRetained)
rawset(Pool, "SetMaxRetained", poolSetMaxRetained)
rawset(Pool, "Owns", poolOwns)
rawset(Pool, "IsActive", poolIsActive)

rawset(PoolKit, "API", API_GENERATION)
rawset(PoolKit, "REVISION", IMPLEMENTATION_REVISION)
rawset(PoolKit, "Pool", Pool)
rawset(PoolKit, "UNBOUNDED", UNBOUNDED)
rawset(PoolKit, "DEFAULT_MAX_RETAINED", DEFAULT_MAX_RETAINED)
rawset(PoolKit, "New", packageNew)
rawset(PoolKit, "NewTablePool", packageNewTablePool)

if not validatePublicSurface(PoolKit) or not validateCurrentState(PoolKit) then
    error("MoltenCodes PoolKit package state is corrupted or incomplete", 2)
end

return PoolKit
