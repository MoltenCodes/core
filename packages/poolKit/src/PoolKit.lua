-- MoltenCodes PoolKit
--
-- Allocation-conscious reusable object pools for World of Warcraft addons.
-- PoolKit is pure Lua: it owns object lifecycle and retention policy without
-- depending on Frames, timers, or other WoW APIs.

local PACKAGE_NAME = "poolKit"
local API_GENERATION = 1
local IMPLEMENTATION_REVISION = 1
local REQUIRED_REGISTRY_API = 2
local STATE_SCHEMA = 1
local DEFAULT_MAX_RETAINED = 128

-- Dependencies --------------------------------------------------------------

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

local function validatePublicSurface(implementation)
    if type(implementation) ~= "table"
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

local function validateState(currentState)
    return type(currentState) == "table"
        and rawget(currentState, "schema") == STATE_SCHEMA
        and type(rawget(currentState, "poolMetatable")) == "table"
        and type(rawget(currentState, "unbounded")) == "table"
end

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
        if facadeRevision ~= existingRevision
            or not validatePublicSurface(existing)
            or not validateCurrentState(existing)
        then
            error("MoltenCodes PoolKit package state is corrupted or incomplete", 2)
        end
        return existing
    end
end

local PoolKit, previousRevision = registerPackage(
    Registry,
    PACKAGE_NAME,
    API_GENERATION,
    IMPLEMENTATION_REVISION
)
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

local function isNonNegativeInteger(value)
    return type(value) == "number"
        and value == value
        and value ~= math.huge
        and value ~= -math.huge
        and value >= 0
        and value % 1 == 0
end

local function validatePool(self, methodName)
    if type(self) ~= "table" or getmetatable(self) ~= POOL_METATABLE then
        error(methodName .. " must be called on a PoolKit pool", 3)
    end
end

local function validatePoolObject(object, label, level)
    local objectType = type(object)
    if objectType ~= "table" and objectType ~= "userdata" then
        error(label .. " must be a table or userdata", level or 3)
    end
end

local function validateMaxRetained(value, label, level)
    if value == UNBOUNDED then
        return value
    end
    if not isNonNegativeInteger(value) then
        error(label .. " must be a non-negative integer or PoolKit.UNBOUNDED", level or 3)
    end
    return value
end

local function validateCount(value, label, level)
    if not isNonNegativeInteger(value) then
        error(label .. " must be a non-negative integer", level or 3)
    end
end

local function validateCallback(value, label, required, level)
    if value == nil and not required then
        return
    end
    if type(value) ~= "function" then
        error(label .. " must be a function", level or 3)
    end
end

local GENERIC_OPTION_KEYS = {
    create = true,
    reset = true,
    destroy = true,
    maxRetained = true,
    strict = true,
    prewarm = true,
}

local TABLE_OPTION_KEYS = {
    maxRetained = true,
    strict = true,
    prewarm = true,
}

local function validateKnownFields(options, allowed, methodName)
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
        error(methodName .. " options contains unknown field \"" .. firstUnknown .. "\"", 4)
    end
end

local function parseCommonOptions(options, allowed, methodName)
    if options == nil then
        options = {}
    elseif type(options) ~= "table" then
        error(methodName .. " options must be a table", 4)
    end

    validateKnownFields(options, allowed, methodName)

    local maxRetained = rawget(options, "maxRetained")
    if maxRetained == nil then
        maxRetained = DEFAULT_MAX_RETAINED
    else
        maxRetained = validateMaxRetained(maxRetained, methodName .. " maxRetained", 4)
    end

    local strict = rawget(options, "strict")
    if strict == nil then
        strict = true
    elseif type(strict) ~= "boolean" then
        error(methodName .. " strict must be a boolean", 4)
    end

    local prewarm = rawget(options, "prewarm")
    if prewarm == nil then
        prewarm = 0
    else
        validateCount(prewarm, methodName .. " prewarm", 4)
    end

    if maxRetained ~= UNBOUNDED and prewarm > maxRetained then
        error(methodName .. " prewarm cannot exceed maxRetained", 4)
    end

    return maxRetained, strict, prewarm
end

-- Error helpers --------------------------------------------------------------

local function captureFirstError(firstError, ok, value)
    if not ok and firstError == nil then
        return { value = value }
    end
    return firstError
end

local function raiseCaptured(firstError)
    if firstError ~= nil then
        error(firstError.value, 0)
    end
end

-- Internal lifecycle ---------------------------------------------------------

local function ensureMutationAllowed(pool, methodName)
    local phase = rawget(pool, "_callbackPhase")
    if phase ~= false then
        error(methodName .. " cannot mutate this pool during its " .. phase .. " callback", 3)
    end
end

local function invokeLifecycleCallback(pool, phase, callback, ...)
    rawset(pool, "_callbackPhase", phase)
    local ok, value = pcall(callback, ...)
    rawset(pool, "_callbackPhase", false)
    if not ok then
        error(value, 0)
    end
    return value
end

local function markDiscarded(pool, object)
    local released = rawget(pool, "_released")
    if released ~= false then
        rawset(released, object, true)
    end
    rawset(pool, "_discardedCount", rawget(pool, "_discardedCount") + 1)
end

local function destroyDiscarded(pool, object)
    markDiscarded(pool, object)
    local destroy = rawget(pool, "_destroy")
    if destroy ~= false then
        invokeLifecycleCallback(pool, "destroy", destroy, object, pool)
    end
end

local function validateFactoryObject(pool, object, methodName)
    validatePoolObject(object, methodName .. " factory result", 4)

    local active = rawget(pool, "_active")
    local retained = rawget(pool, "_retained")
    if rawget(active, object) ~= nil or rawget(retained, object) == true then
        error(methodName .. " factory returned an object already owned by this pool", 4)
    end

    local released = rawget(pool, "_released")
    if released ~= false then
        rawset(released, object, nil)
    end
end

local function createObject(pool, methodName)
    local create = rawget(pool, "_create")
    local object
    if rawget(pool, "_trustedCallbacks") == true then
        object = create(pool)
    else
        object = invokeLifecycleCallback(pool, "create", create, pool)
    end
    validateFactoryObject(pool, object, methodName)
    rawset(pool, "_createdCount", rawget(pool, "_createdCount") + 1)
    return object
end

local function canRetain(pool)
    local maxRetained = rawget(pool, "_maxRetained")
    return maxRetained == UNBOUNDED or rawget(pool, "_availableCount") < maxRetained
end

local function discardAvailableObject(pool, object)
    local retained = rawget(pool, "_retained")
    rawset(retained, object, nil)
    return pcall(destroyDiscarded, pool, object)
end

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

local function prewarmInternal(pool, targetCount)
    if rawget(pool, "_closed") == true then
        error("PoolKit.Pool:Prewarm cannot use a closed pool", 3)
    end

    local maxRetained = rawget(pool, "_maxRetained")
    if maxRetained ~= UNBOUNDED and targetCount > maxRetained then
        error("PoolKit.Pool:Prewarm target cannot exceed maxRetained", 3)
    end

    local available = rawget(pool, "_available")
    local retained = rawget(pool, "_retained")
    local count = rawget(pool, "_availableCount")
    local created = 0

    while count < targetCount do
        local object = createObject(pool, "PoolKit.Pool:Prewarm")
        count = count + 1
        created = created + 1
        rawset(available, count, object)
        rawset(retained, object, true)
    end

    rawset(pool, "_availableCount", count)
    return created
end

local function newPool(create, reset, destroy, maxRetained, strict, prewarm, trustedCallbacks)
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
        _retained = {},
        _released = released,
        _createdCount = 0,
        _discardedCount = 0,
        _closed = false,
        _callbackPhase = false,
        _trustedCallbacks = trustedCallbacks == true,
    }, POOL_METATABLE)

    if prewarm > 0 then
        local ok, value = pcall(prewarmInternal, pool, prewarm)
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

local function poolAcquire(self)
    validatePool(self, "PoolKit.Pool:Acquire")
    ensureMutationAllowed(self, "PoolKit.Pool:Acquire")
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
        object = createObject(self, "PoolKit.Pool:Acquire")
    end

    local released = rawget(self, "_released")
    if released ~= false then
        rawset(released, object, nil)
    end

    rawset(rawget(self, "_active"), object, ACTIVE)
    rawset(self, "_activeCount", rawget(self, "_activeCount") + 1)
    return object
end

local function poolRelease(self, object)
    validatePool(self, "PoolKit.Pool:Release")
    ensureMutationAllowed(self, "PoolKit.Pool:Release")
    validatePoolObject(object, "PoolKit.Pool:Release object", 2)

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

local function poolPrewarm(self, count)
    validatePool(self, "PoolKit.Pool:Prewarm")
    ensureMutationAllowed(self, "PoolKit.Pool:Prewarm")
    validateCount(count, "PoolKit.Pool:Prewarm count", 2)
    return prewarmInternal(self, count)
end

local function poolTrim(self, retainCount)
    validatePool(self, "PoolKit.Pool:Trim")
    ensureMutationAllowed(self, "PoolKit.Pool:Trim")
    if retainCount == nil then
        retainCount = 0
    else
        validateCount(retainCount, "PoolKit.Pool:Trim retainCount", 2)
    end
    return trimTo(self, retainCount)
end

local function poolClear(self)
    validatePool(self, "PoolKit.Pool:Clear")
    ensureMutationAllowed(self, "PoolKit.Pool:Clear")
    return trimTo(self, 0)
end

local function poolClose(self)
    validatePool(self, "PoolKit.Pool:Close")
    ensureMutationAllowed(self, "PoolKit.Pool:Close")
    if rawget(self, "_closed") == true then
        return false
    end
    rawset(self, "_closed", true)
    trimTo(self, 0)
    return true
end

local function poolIsClosed(self)
    validatePool(self, "PoolKit.Pool:IsClosed")
    return rawget(self, "_closed") == true
end

local function poolGetAvailableCount(self)
    validatePool(self, "PoolKit.Pool:GetAvailableCount")
    return rawget(self, "_availableCount")
end

local function poolGetActiveCount(self)
    validatePool(self, "PoolKit.Pool:GetActiveCount")
    return rawget(self, "_activeCount")
end

local function poolGetCreatedCount(self)
    validatePool(self, "PoolKit.Pool:GetCreatedCount")
    return rawget(self, "_createdCount")
end

local function poolGetDiscardedCount(self)
    validatePool(self, "PoolKit.Pool:GetDiscardedCount")
    return rawget(self, "_discardedCount")
end

local function poolGetMaxRetained(self)
    validatePool(self, "PoolKit.Pool:GetMaxRetained")
    return rawget(self, "_maxRetained")
end

local function poolSetMaxRetained(self, maxRetained)
    validatePool(self, "PoolKit.Pool:SetMaxRetained")
    ensureMutationAllowed(self, "PoolKit.Pool:SetMaxRetained")
    maxRetained = validateMaxRetained(
        maxRetained,
        "PoolKit.Pool:SetMaxRetained maxRetained",
        2
    )
    rawset(self, "_maxRetained", maxRetained)
    if maxRetained ~= UNBOUNDED then
        trimTo(self, maxRetained)
    end
    return self
end

local function poolOwns(self, object)
    validatePool(self, "PoolKit.Pool:Owns")
    local objectType = type(object)
    if objectType ~= "table" and objectType ~= "userdata" then
        return false
    end
    return rawget(rawget(self, "_active"), object) ~= nil
        or rawget(rawget(self, "_retained"), object) == true
end

local function poolIsActive(self, object)
    validatePool(self, "PoolKit.Pool:IsActive")
    local objectType = type(object)
    if objectType ~= "table" and objectType ~= "userdata" then
        return false
    end
    local status = rawget(rawget(self, "_active"), object)
    return status == ACTIVE or status == RELEASING
end

-- Package constructors -------------------------------------------------------

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

    local maxRetained, strict, prewarm = parseCommonOptions(
        options,
        GENERIC_OPTION_KEYS,
        "PoolKit:New"
    )
    return newPool(create, reset, destroy, maxRetained, strict, prewarm, false)
end

local function tableCreate()
    return {}
end

local function tableReset(object)
    for key in next, object do
        rawset(object, key, nil)
    end
end

local function packageNewTablePool(_, options)
    local maxRetained, strict, prewarm = parseCommonOptions(
        options,
        TABLE_OPTION_KEYS,
        "PoolKit:NewTablePool"
    )
    return newPool(tableCreate, tableReset, nil, maxRetained, strict, prewarm, true)
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
