-- MoltenCodes TimerKit
--
-- Cancelable, scope-aware World of Warcraft timers. TimerKit keeps the C_Timer
-- boundary narrow, adds deterministic logical state, guards stale native
-- callbacks across restart/cancel operations, and integrates addon-owned timer
-- scopes with LifecycleKit shutdown.

local PACKAGE_NAME = "timerKit"
local API_GENERATION = 1
local IMPLEMENTATION_REVISION = 1
local REQUIRED_REGISTRY_API = 2
local REQUIRED_LIFECYCLE_API = 1
local STATE_SCHEMA = 1

-- Dependencies --------------------------------------------------------------

local namespace = rawget(_G, "MoltenCodes")
if type(namespace) ~= "table" then
    error("MoltenCodes TimerKit requires Registry API 2 to be loaded first", 2)
end

local Registry = rawget(namespace, "Registry")
if type(Registry) ~= "table" or rawget(Registry, "API") ~= REQUIRED_REGISTRY_API then
    error("MoltenCodes TimerKit requires Registry API 2 to be loaded first", 2)
end

local registerPackage = rawget(Registry, "Register")
local getPackage = rawget(Registry, "Get")
if type(registerPackage) ~= "function" or type(getPackage) ~= "function" then
    error("MoltenCodes TimerKit requires a valid Registry API 2 facade", 2)
end

local LifecycleKit, lifecycleRevision = getPackage(Registry, "lifecycleKit", REQUIRED_LIFECYCLE_API)
local LifecycleInstance = type(LifecycleKit) == "table" and rawget(LifecycleKit, "Instance") or nil
local LifecycleSubscription = type(LifecycleKit) == "table"
    and rawget(LifecycleKit, "Subscription")
    or nil
if type(LifecycleKit) ~= "table"
    or type(lifecycleRevision) ~= "number"
    or rawget(LifecycleKit, "API") ~= REQUIRED_LIFECYCLE_API
    or rawget(LifecycleKit, "REVISION") ~= lifecycleRevision
    or type(rawget(LifecycleKit, "ForAddon")) ~= "function"
    or type(LifecycleInstance) ~= "table"
    or type(rawget(LifecycleInstance, "IsShutdown")) ~= "function"
    or type(rawget(LifecycleInstance, "OnShutdown")) ~= "function"
    or type(LifecycleSubscription) ~= "table"
    or type(rawget(LifecycleSubscription, "Disconnect")) ~= "function"
then
    error("MoltenCodes TimerKit requires a valid LifecycleKit API 1 facade", 2)
end

local wowTimerApi = rawget(_G, "C_Timer")
local nativeNewTimer = type(wowTimerApi) == "table" and rawget(wowTimerApi, "NewTimer") or nil
local nativeNewTicker = type(wowTimerApi) == "table" and rawget(wowTimerApi, "NewTicker") or nil
if type(nativeNewTimer) ~= "function" or type(nativeNewTicker) ~= "function" then
    error("MoltenCodes TimerKit requires C_Timer.NewTimer and C_Timer.NewTicker", 2)
end

-- Validation ----------------------------------------------------------------

local function validatePublicSurface(implementation)
    if type(implementation) ~= "table"
        or rawget(implementation, "API") ~= API_GENERATION
        or type(rawget(implementation, "REVISION")) ~= "number"
        or type(rawget(implementation, "Timer")) ~= "table"
        or type(rawget(implementation, "Scope")) ~= "table"
    then
        return false
    end

    local Timer = rawget(implementation, "Timer")
    local Scope = rawget(implementation, "Scope")

    return type(rawget(implementation, "New")) == "function"
        and type(rawget(implementation, "After")) == "function"
        and type(rawget(implementation, "Every")) == "function"
        and type(rawget(implementation, "CreateScope")) == "function"
        and type(rawget(implementation, "ForAddon")) == "function"
        and type(rawget(Timer, "GetState")) == "function"
        and type(rawget(Timer, "GetDelay")) == "function"
        and type(rawget(Timer, "GetScope")) == "function"
        and type(rawget(Timer, "IsRepeating")) == "function"
        and type(rawget(Timer, "IsPending")) == "function"
        and type(rawget(Timer, "IsCancelled")) == "function"
        and type(rawget(Timer, "Start")) == "function"
        and type(rawget(Timer, "Cancel")) == "function"
        and type(rawget(Timer, "Restart")) == "function"
        and type(rawget(Scope, "New")) == "function"
        and type(rawget(Scope, "After")) == "function"
        and type(rawget(Scope, "Every")) == "function"
        and type(rawget(Scope, "CancelAll")) == "function"
        and type(rawget(Scope, "Close")) == "function"
        and type(rawget(Scope, "IsClosed")) == "function"
        and type(rawget(Scope, "GetAddonName")) == "function"
        and type(rawget(Scope, "GetActiveCount")) == "function"
end

local function validateStateBase(currentState)
    return type(currentState) == "table"
        and rawget(currentState, "schema") == STATE_SCHEMA
        and type(rawget(currentState, "addonScopes")) == "table"
        and type(rawget(currentState, "dispatch")) == "table"
        and type(rawget(currentState, "nextTimerId")) == "number"
        and type(rawget(currentState, "runtimeRevision")) == "number"
        and type(rawget(currentState, "timerMetatable")) == "table"
        and type(rawget(currentState, "scopeMetatable")) == "table"
end

local function validateCurrentState(implementation)
    local currentState = rawget(implementation, "_state")
    return validateStateBase(currentState) and type(rawget(currentState, "defaultScope")) == "table"
end

local existing, existingRevision = getPackage(Registry, PACKAGE_NAME, API_GENERATION)
if existing ~= nil then
    if type(existing) ~= "table" or rawget(existing, "API") ~= API_GENERATION then
        error("MoltenCodes TimerKit package state is corrupted or incomplete", 2)
    end

    local facadeRevision = rawget(existing, "REVISION")
    if type(facadeRevision) ~= "number" or facadeRevision > existingRevision then
        error("MoltenCodes TimerKit package state is corrupted or incomplete", 2)
    end

    if existingRevision > IMPLEMENTATION_REVISION then
        -- A newer compatible embedded revision owns its private state schema.
        -- Older copies validate only the stable API surface and must not
        -- reinterpret future private state.
        if facadeRevision ~= existingRevision or not validatePublicSurface(existing) then
            error("MoltenCodes TimerKit package state is corrupted or incomplete", 2)
        end
        return existing
    elseif existingRevision == IMPLEMENTATION_REVISION then
        if facadeRevision ~= existingRevision
            or not validatePublicSurface(existing)
            or not validateCurrentState(existing)
        then
            error("MoltenCodes TimerKit package state is corrupted or incomplete", 2)
        end
        return existing
    end
end

local TimerKit, previousRevision = registerPackage(
    Registry,
    PACKAGE_NAME,
    API_GENERATION,
    IMPLEMENTATION_REVISION
)
if TimerKit == nil then
    return existing
end

local Timer = rawget(TimerKit, "Timer")
local Scope = rawget(TimerKit, "Scope")
local state = rawget(TimerKit, "_state")

if previousRevision == nil then
    if Timer ~= nil or Scope ~= nil or state ~= nil then
        error("MoltenCodes TimerKit package state is corrupted or incomplete", 2)
    end

    Timer = {}
    Scope = {}
    state = {
        schema = STATE_SCHEMA,
        addonScopes = {},
        defaultScope = false,
        dispatch = {},
        nextTimerId = 0,
        runtimeRevision = 0,
        timerMetatable = {},
        scopeMetatable = {},
    }
    rawset(TimerKit, "Timer", Timer)
    rawset(TimerKit, "Scope", Scope)
    rawset(TimerKit, "_state", state)
elseif type(Timer) ~= "table" or type(Scope) ~= "table" or not validateStateBase(state) then
    error("MoltenCodes TimerKit package state is corrupted or incomplete", 2)
end

local TIMER_METATABLE = rawget(state, "timerMetatable")
local SCOPE_METATABLE = rawget(state, "scopeMetatable")
rawset(TIMER_METATABLE, "__index", Timer)
rawset(SCOPE_METATABLE, "__index", Scope)

local function newErrorRecord(value)
    return { value = value }
end

local function captureFirstError(firstError, ok, value)
    if not ok and firstError == nil then
        return newErrorRecord(value)
    end
    return firstError
end

local function raiseCaptured(firstError)
    if firstError ~= nil then
        error(firstError.value, 0)
    end
end

local function validateNonEmptyString(value, label, level)
    if type(value) ~= "string" or value == "" then
        error(label .. " must be a non-empty string", level or 3)
    end
end

local function validateDelay(delay, repeating, label, level)
    if type(delay) ~= "number"
        or delay ~= delay
        or delay == math.huge
        or delay == -math.huge
    then
        error(label .. " must be a finite number", level or 3)
    end

    if repeating then
        if delay <= 0 then
            error(label .. " must be greater than zero for repeating timers", level or 3)
        end
    elseif delay < 0 then
        error(label .. " must be zero or greater", level or 3)
    end
end

local function validateOptions(options, methodName)
    if type(options) ~= "table" then
        error(methodName .. " options must be a table", 4)
    end

    local allowed = {
        delay = true,
        callback = true,
        repeating = true,
    }
    local unknown = {}
    for key in pairs(options) do
        if allowed[key] ~= true then
            unknown[#unknown + 1] = tostring(key)
        end
    end
    table.sort(unknown)
    if #unknown > 0 then
        error(methodName .. " options contains unknown field \"" .. unknown[1] .. "\"", 4)
    end

    local callback = rawget(options, "callback")
    if type(callback) ~= "function" then
        error(methodName .. " callback must be a function", 4)
    end

    local repeating = rawget(options, "repeating")
    if repeating == nil then
        repeating = false
    elseif type(repeating) ~= "boolean" then
        error(methodName .. " repeating must be a boolean", 4)
    end

    local delay = rawget(options, "delay")
    validateDelay(delay, repeating, methodName .. " delay", 4)
    return delay, callback, repeating
end

local function validateScope(scope, methodName)
    if type(scope) ~= "table" or getmetatable(scope) ~= SCOPE_METATABLE then
        error(methodName .. " must be called on a TimerKit scope", 4)
    end
end

local function validateTimer(timer, methodName)
    if type(timer) ~= "table" or getmetatable(timer) ~= TIMER_METATABLE then
        error(methodName .. " must be called on a TimerKit timer", 4)
    end
end

local function getNativeCancel(native)
    local nativeType = type(native)
    if nativeType ~= "table" and nativeType ~= "userdata" then
        return nil
    end

    local ok, cancel = pcall(function()
        return native.Cancel
    end)
    if not ok or type(cancel) ~= "function" then
        return nil
    end
    return cancel
end

local function attachActive(scope, timer)
    local active = rawget(scope, "_active")
    if rawget(active, timer) ~= true then
        rawset(active, timer, true)
        rawset(scope, "_activeCount", rawget(scope, "_activeCount") + 1)
    end
end

local function detachActive(scope, timer)
    local active = rawget(scope, "_active")
    if rawget(active, timer) == true then
        rawset(active, timer, nil)
        rawset(scope, "_activeCount", rawget(scope, "_activeCount") - 1)
    end
end

local function cancelNative(native)
    if native == nil then
        return
    end
    local cancel = getNativeCancel(native)
    if cancel == nil then
        error("MoltenCodes TimerKit native timer handle is invalid", 0)
    end
    cancel(native)
end

local function cancelTimer(timer)
    if rawget(timer, "_state") ~= "running" then
        return false
    end

    local native = rawget(timer, "_native")
    local scope = rawget(timer, "_scope")

    -- Invalidate native callbacks before asking the host to cancel. Even if the
    -- host cancellation itself errors, stale callbacks cannot re-enter the
    -- logical timer after this point.
    rawset(timer, "_generation", rawget(timer, "_generation") + 1)
    rawset(timer, "_native", nil)
    rawset(timer, "_state", "cancelled")
    detachActive(scope, timer)

    cancelNative(native)
    return true
end

local function fireTimer(timer, generation)
    if rawget(timer, "_generation") ~= generation or rawget(timer, "_state") ~= "running" then
        return false
    end

    local repeating = rawget(timer, "_repeating") == true
    if not repeating then
        rawset(timer, "_native", nil)
        rawset(timer, "_state", "completed")
        detachActive(rawget(timer, "_scope"), timer)
    end

    rawget(timer, "_callback")(timer)
    return true
end

local function rollbackStart(timer, previousState)
    rawset(timer, "_native", nil)
    rawset(timer, "_state", previousState)
    detachActive(rawget(timer, "_scope"), timer)
end

local function startTimer(timer)
    validateTimer(timer, "TimerKit.Timer:Start")

    if rawget(timer, "_state") == "running" then
        return false
    end

    local scope = rawget(timer, "_scope")
    if rawget(scope, "_closed") == true then
        error("TimerKit.Timer:Start cannot start a timer in a closed scope", 3)
    end

    local previousState = rawget(timer, "_state")
    local generation = rawget(timer, "_generation") + 1
    rawset(timer, "_generation", generation)
    rawset(timer, "_state", "running")
    attachActive(scope, timer)

    local callback = function()
        local dispatch = rawget(state, "dispatch")
        local fire = type(dispatch) == "table" and rawget(dispatch, "fire") or nil
        if type(fire) ~= "function" then
            error("MoltenCodes TimerKit runtime dispatch is corrupted", 0)
        end
        return fire(timer, generation)
    end

    local constructor = rawget(timer, "_repeating") == true and nativeNewTicker or nativeNewTimer
    local ok, native = pcall(constructor, rawget(timer, "_delay"), callback)
    if not ok then
        rollbackStart(timer, previousState)
        error(native, 0)
    end

    if native == nil or getNativeCancel(native) == nil then
        rollbackStart(timer, previousState)
        error("MoltenCodes TimerKit host returned an invalid native timer handle", 2)
    end

    rawset(timer, "_native", native)
    return true
end

local function restartTimer(timer)
    validateTimer(timer, "TimerKit.Timer:Restart")
    local scope = rawget(timer, "_scope")
    if rawget(scope, "_closed") == true then
        error("TimerKit.Timer:Restart cannot restart a timer in a closed scope", 3)
    end

    if rawget(timer, "_state") == "running" then
        cancelTimer(timer)
    end
    return startTimer(timer)
end

local function nextTimerId()
    local id = rawget(state, "nextTimerId") + 1
    rawset(state, "nextTimerId", id)
    return id
end

local function constructTimer(scope, delay, callback, repeating)
    return setmetatable({
        _id = nextTimerId(),
        _scope = scope,
        _callback = callback,
        _delay = delay,
        _repeating = repeating,
        _state = "idle",
        _native = nil,
        _generation = 0,
    }, TIMER_METATABLE)
end

local function createTimer(scope, delay, callback, repeating, methodName)
    validateScope(scope, methodName)
    if rawget(scope, "_closed") == true then
        error(methodName .. " cannot create a timer in a closed scope", 3)
    end
    if type(callback) ~= "function" then
        error(methodName .. " callback must be a function", 4)
    end
    validateDelay(delay, repeating, methodName .. " delay", 4)
    return constructTimer(scope, delay, callback, repeating)
end

local function newTimerInScope(scope, options, methodName)
    validateScope(scope, methodName)
    if rawget(scope, "_closed") == true then
        error(methodName .. " cannot create a timer in a closed scope", 3)
    end
    local delay, callback, repeating = validateOptions(options, methodName)
    return constructTimer(scope, delay, callback, repeating)
end

local function scopeNew(self, options)
    return newTimerInScope(self, options, "TimerKit.Scope:New")
end

local function scopeAfter(self, delay, callback)
    local timer = createTimer(self, delay, callback, false, "TimerKit.Scope:After")
    startTimer(timer)
    return timer
end

local function scopeEvery(self, interval, callback)
    local timer = createTimer(self, interval, callback, true, "TimerKit.Scope:Every")
    startTimer(timer)
    return timer
end

local function snapshotActive(scope)
    local timers = {}
    local active = rawget(scope, "_active")
    for timer in pairs(active) do
        timers[#timers + 1] = timer
    end
    table.sort(timers, function(left, right)
        return rawget(left, "_id") < rawget(right, "_id")
    end)
    return timers
end

local function cancelAll(scope)
    validateScope(scope, "TimerKit.Scope:CancelAll")
    local timers = snapshotActive(scope)
    local cancelled = 0
    local firstError

    for index = 1, #timers do
        local ok, result = pcall(cancelTimer, timers[index])
        if ok then
            if result == true then
                cancelled = cancelled + 1
            end
        else
            cancelled = cancelled + 1
            firstError = captureFirstError(firstError, false, result)
        end
    end

    raiseCaptured(firstError)
    return cancelled
end

local function disconnectShutdownSubscription(scope)
    local subscription = rawget(scope, "_shutdownSubscription")
    rawset(scope, "_shutdownSubscription", nil)
    if subscription == nil then
        return
    end

    local disconnect = subscription.Disconnect
    if type(disconnect) ~= "function" then
        error("MoltenCodes TimerKit lifecycle subscription state is corrupted", 0)
    end
    disconnect(subscription)
end

local function closeScope(scope)
    validateScope(scope, "TimerKit.Scope:Close")
    if rawget(scope, "_closed") == true then
        return false
    end

    -- Make the scope terminal before cleanup begins. Callback re-entry cannot
    -- schedule replacement timers while shutdown/Close is in progress.
    rawset(scope, "_closed", true)

    local firstError
    local okCancel, cancelError = pcall(cancelAll, scope)
    firstError = captureFirstError(firstError, okCancel, cancelError)

    local okDisconnect, disconnectError = pcall(disconnectShutdownSubscription, scope)
    firstError = captureFirstError(firstError, okDisconnect, disconnectError)

    raiseCaptured(firstError)
    return true
end

local function newScope(addonName)
    return setmetatable({
        _addonName = addonName,
        _active = {},
        _activeCount = 0,
        _closed = false,
        _shutdownSubscription = nil,
    }, SCOPE_METATABLE)
end

local function createAddonScope(addonName)
    local lifecycle = LifecycleKit:ForAddon(addonName)
    if type(lifecycle) ~= "table"
        or type(lifecycle.IsShutdown) ~= "function"
        or type(lifecycle.OnShutdown) ~= "function"
    then
        error("MoltenCodes TimerKit received an invalid LifecycleKit instance", 2)
    end

    local scope = newScope(addonName)
    local addonScopes = rawget(state, "addonScopes")
    rawset(addonScopes, addonName, scope)

    if lifecycle:IsShutdown() then
        rawset(scope, "_closed", true)
        return scope
    end

    local ok, subscription = pcall(function()
        return lifecycle:OnShutdown(function()
            local dispatch = rawget(state, "dispatch")
            local close = type(dispatch) == "table" and rawget(dispatch, "closeScope") or nil
            if type(close) ~= "function" then
                error("MoltenCodes TimerKit runtime dispatch is corrupted", 0)
            end
            return close(scope)
        end)
    end)

    if not ok then
        rawset(addonScopes, addonName, nil)
        error(subscription, 0)
    end

    rawset(scope, "_shutdownSubscription", subscription)
    return scope
end

-- Timer public methods ------------------------------------------------------

local function timerGetState(self)
    validateTimer(self, "TimerKit.Timer:GetState")
    return rawget(self, "_state")
end

local function timerGetDelay(self)
    validateTimer(self, "TimerKit.Timer:GetDelay")
    return rawget(self, "_delay")
end

local function timerGetScope(self)
    validateTimer(self, "TimerKit.Timer:GetScope")
    return rawget(self, "_scope")
end

local function timerIsRepeating(self)
    validateTimer(self, "TimerKit.Timer:IsRepeating")
    return rawget(self, "_repeating") == true
end

local function timerIsPending(self)
    validateTimer(self, "TimerKit.Timer:IsPending")
    return rawget(self, "_state") == "running"
end

local function timerIsCancelled(self)
    validateTimer(self, "TimerKit.Timer:IsCancelled")
    return rawget(self, "_state") == "cancelled"
end

local function timerStart(self)
    return startTimer(self)
end

local function timerCancel(self)
    validateTimer(self, "TimerKit.Timer:Cancel")
    return cancelTimer(self)
end

local function timerRestart(self)
    return restartTimer(self)
end

-- Scope public methods ------------------------------------------------------

local function scopeCancelAll(self)
    return cancelAll(self)
end

local function scopeClose(self)
    return closeScope(self)
end

local function scopeIsClosed(self)
    validateScope(self, "TimerKit.Scope:IsClosed")
    return rawget(self, "_closed") == true
end

local function scopeGetAddonName(self)
    validateScope(self, "TimerKit.Scope:GetAddonName")
    return rawget(self, "_addonName")
end

local function scopeGetActiveCount(self)
    validateScope(self, "TimerKit.Scope:GetActiveCount")
    return rawget(self, "_activeCount")
end

-- Package public API --------------------------------------------------------

local function getDefaultScope()
    local scope = rawget(state, "defaultScope")
    if scope == false or rawget(scope, "_closed") == true then
        scope = newScope(nil)
        rawset(state, "defaultScope", scope)
    end
    return scope
end

local function packageNew(_, options)
    return newTimerInScope(getDefaultScope(), options, "TimerKit:New")
end

local function packageAfter(_, delay, callback)
    return scopeAfter(getDefaultScope(), delay, callback)
end

local function packageEvery(_, interval, callback)
    return scopeEvery(getDefaultScope(), interval, callback)
end

local function createScope()
    return newScope(nil)
end

local function forAddon(_, addonName)
    validateNonEmptyString(addonName, "TimerKit:ForAddon addonName", 3)

    local addonScopes = rawget(state, "addonScopes")
    local existingScope = rawget(addonScopes, addonName)
    if existingScope ~= nil then
        return existingScope
    end
    return createAddonScope(addonName)
end

-- Commit -------------------------------------------------------------------

rawset(Timer, "GetState", timerGetState)
rawset(Timer, "GetDelay", timerGetDelay)
rawset(Timer, "GetScope", timerGetScope)
rawset(Timer, "IsRepeating", timerIsRepeating)
rawset(Timer, "IsPending", timerIsPending)
rawset(Timer, "IsCancelled", timerIsCancelled)
rawset(Timer, "Start", timerStart)
rawset(Timer, "Cancel", timerCancel)
rawset(Timer, "Restart", timerRestart)

rawset(Scope, "New", scopeNew)
rawset(Scope, "After", scopeAfter)
rawset(Scope, "Every", scopeEvery)
rawset(Scope, "CancelAll", scopeCancelAll)
rawset(Scope, "Close", scopeClose)
rawset(Scope, "IsClosed", scopeIsClosed)
rawset(Scope, "GetAddonName", scopeGetAddonName)
rawset(Scope, "GetActiveCount", scopeGetActiveCount)

rawset(TimerKit, "API", API_GENERATION)
rawset(TimerKit, "REVISION", IMPLEMENTATION_REVISION)
rawset(TimerKit, "New", packageNew)
rawset(TimerKit, "After", packageAfter)
rawset(TimerKit, "Every", packageEvery)
rawset(TimerKit, "CreateScope", createScope)
rawset(TimerKit, "ForAddon", forAddon)

local defaultScope = rawget(state, "defaultScope")
if defaultScope == false then
    rawset(state, "defaultScope", newScope(nil))
elseif type(defaultScope) ~= "table" or getmetatable(defaultScope) ~= SCOPE_METATABLE then
    error("MoltenCodes TimerKit package state is corrupted or incomplete", 2)
end

local dispatch = rawget(state, "dispatch")
rawset(dispatch, "fire", fireTimer)
rawset(dispatch, "closeScope", closeScope)
rawset(state, "runtimeRevision", IMPLEMENTATION_REVISION)

if not validatePublicSurface(TimerKit) or not validateCurrentState(TimerKit) then
    error("MoltenCodes TimerKit package state is corrupted or incomplete", 2)
end

return TimerKit
