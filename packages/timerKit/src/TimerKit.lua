-- MoltenCodes TimerKit
--
-- Cancelable, scope-aware World of Warcraft timers. TimerKit keeps the C_Timer
-- boundary narrow, adds deterministic logical state, guards stale native
-- callbacks across restart/cancel operations, and integrates addon-owned timer
-- scopes with LifecycleKit shutdown.

local PACKAGE_NAME = "timerKit"
local API_GENERATION = 1
local IMPLEMENTATION_REVISION = 2
local REQUIRED_REGISTRY_API = 2
local REQUIRED_LIFECYCLE_API = 1
local STATE_SCHEMA = 1

-- The complete set of fields `New`-style option tables accept. Hoisting it to a
-- file-local constant keeps option validation allocation-free: every `New()`
-- reuses this table instead of building a fresh allowed-key set per call.
local TIMER_OPTION_KEYS = {
    delay = true,
    callback = true,
    repeating = true,
}

-- Public types --------------------------------------------------------------
--
-- TimerKit publishes its methods by writing them onto Registry-owned prototype
-- tables, so the editor-facing contract is declared here as LuaCATS classes
-- rather than inferred from those assignments.

---Logical state of a TimerKit timer.
---@alias TimerKitTimerState "idle"|"running"|"completed"|"cancelled"

---Option table accepted by `TimerKit:New` and `TimerKit.Scope:New`.
---@class TimerKitTimerOptions
---@field delay number Finite seconds; must be greater than zero when repeating.
---@field callback fun(timer: TimerKitTimer) Receives the logical timer handle.
---@field repeating boolean? Defaults to `false`.

---A cancelable logical timer owned by exactly one scope.
---@class TimerKitTimer
---@field GetState fun(self: TimerKitTimer): TimerKitTimerState
---@field GetDelay fun(self: TimerKitTimer): number
---@field GetScope fun(self: TimerKitTimer): TimerKitScope
---@field GetUserData fun(self: TimerKitTimer): any
---@field SetUserData fun(self: TimerKitTimer, value: any): TimerKitTimer
---@field IsRepeating fun(self: TimerKitTimer): boolean
---@field IsPending fun(self: TimerKitTimer): boolean
---@field IsCancelled fun(self: TimerKitTimer): boolean
---@field Start fun(self: TimerKitTimer): boolean
---@field Cancel fun(self: TimerKitTimer): boolean
---@field Restart fun(self: TimerKitTimer): boolean

---An ownership scope for timers, closed manually or by addon shutdown.
---@class TimerKitScope
---@field New fun(self: TimerKitScope, options: TimerKitTimerOptions): TimerKitTimer
---@field After fun(self: TimerKitScope, delay: number, callback: fun(timer: TimerKitTimer)): TimerKitTimer
---@field Every fun(self: TimerKitScope, interval: number, callback: fun(timer: TimerKitTimer)): TimerKitTimer
---@field CancelAll fun(self: TimerKitScope): integer
---@field Close fun(self: TimerKitScope): boolean
---@field IsClosed fun(self: TimerKitScope): boolean
---@field GetAddonName fun(self: TimerKitScope): string?
---@field GetActiveCount fun(self: TimerKitScope): integer

---The TimerKit package facade published through Registry.
---@class TimerKitFacade
---@field API integer Public API generation.
---@field REVISION integer Compatible implementation revision.
---@field Timer TimerKitTimer Shared timer prototype.
---@field Scope TimerKitScope Shared scope prototype.
---@field New fun(self: TimerKitFacade, options: TimerKitTimerOptions): TimerKitTimer
---@field After fun(self: TimerKitFacade, delay: number, callback: fun(timer: TimerKitTimer)): TimerKitTimer
---@field Every fun(self: TimerKitFacade, interval: number, callback: fun(timer: TimerKitTimer)): TimerKitTimer
---@field CreateScope fun(self: TimerKitFacade): TimerKitScope
---@field ForAddon fun(self: TimerKitFacade, addonName: string): TimerKitScope

-- Dependencies --------------------------------------------------------------

-- The shared MoltenCodes namespace is the one documented global handoff point between independently embedded copies.
-- selene: allow(global_usage)
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
local LifecycleSubscription = type(LifecycleKit) == "table" and rawget(LifecycleKit, "Subscription")
    or nil
if
    type(LifecycleKit) ~= "table"
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

-- C_Timer is a World of Warcraft client API reachable only through the global table.
-- selene: allow(global_usage)
local wowTimerApi = rawget(_G, "C_Timer")
local nativeNewTimer = type(wowTimerApi) == "table" and rawget(wowTimerApi, "NewTimer") or nil
local nativeNewTicker = type(wowTimerApi) == "table" and rawget(wowTimerApi, "NewTicker") or nil
if type(nativeNewTimer) ~= "function" or type(nativeNewTicker) ~= "function" then
    error("MoltenCodes TimerKit requires C_Timer.NewTimer and C_Timer.NewTicker", 2)
end

-- Validation ----------------------------------------------------------------

local function validatePublicSurface(implementation)
    if
        type(implementation) ~= "table"
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
        and type(rawget(Timer, "GetUserData")) == "function"
        and type(rawget(Timer, "SetUserData")) == "function"
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
        if
            facadeRevision ~= existingRevision
            or not validatePublicSurface(existing)
            or not validateCurrentState(existing)
        then
            error("MoltenCodes TimerKit package state is corrupted or incomplete", 2)
        end
        return existing
    end
end

local TimerKit, previousRevision =
    registerPackage(Registry, PACKAGE_NAME, API_GENERATION, IMPLEMENTATION_REVISION)
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

-- Argument validation raises with an explicit stack level so the reported
-- position is the line that called the public method, never a line inside
-- TimerKit. `level` is always the value `error` needs *inside the function that
-- receives it*, so every further hop towards `error` adds exactly one.

local function validateNonEmptyString(value, label, level)
    if type(value) ~= "string" or value == "" then
        error(label .. " must be a non-empty string", level)
    end
end

local function validateDelay(delay, repeating, label, level)
    if type(delay) ~= "number" or delay ~= delay or delay == math.huge or delay == -math.huge then
        error(label .. " must be a finite number", level)
    end

    if repeating then
        if delay <= 0 then
            error(label .. " must be greater than zero for repeating timers", level)
        end
    elseif delay < 0 then
        error(label .. " must be zero or greater", level)
    end
end

local function validateOptions(options, methodName, level)
    if type(options) ~= "table" then
        error(methodName .. " options must be a table", level)
    end

    -- Report the alphabetically first unknown field without allocating: track
    -- the smallest key seen instead of collecting and sorting every offender.
    local firstUnknown = nil
    for key in next, options do
        if TIMER_OPTION_KEYS[key] ~= true then
            local text = tostring(key)
            if firstUnknown == nil or text < firstUnknown then
                firstUnknown = text
            end
        end
    end
    if firstUnknown ~= nil then
        error(methodName .. ' options contains unknown field "' .. firstUnknown .. '"', level)
    end

    local callback = rawget(options, "callback")
    if type(callback) ~= "function" then
        error(methodName .. " callback must be a function", level)
    end

    local repeating = rawget(options, "repeating")
    if repeating == nil then
        repeating = false
    elseif type(repeating) ~= "boolean" then
        error(methodName .. " repeating must be a boolean", level)
    end

    local delay = rawget(options, "delay")
    validateDelay(delay, repeating, methodName .. " delay", level + 1)
    return delay, callback, repeating
end

local function validateScope(scope, methodName, level)
    if type(scope) ~= "table" or getmetatable(scope) ~= SCOPE_METATABLE then
        error(methodName .. " must be called on a TimerKit scope", level)
    end
end

local function validateTimer(timer, methodName, level)
    if type(timer) ~= "table" or getmetatable(timer) ~= TIMER_METATABLE then
        error(methodName .. " must be called on a TimerKit timer", level)
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

-- The caller has already validated `timer`; `level` identifies that caller so a
-- closed-scope or invalid-host-handle failure still reports at its line.
local function startTimer(timer, methodName, level)
    if rawget(timer, "_state") == "running" then
        return false
    end

    local scope = rawget(timer, "_scope")
    if rawget(scope, "_closed") == true then
        error(methodName .. " cannot start a timer in a closed scope", level)
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
        error("MoltenCodes TimerKit host returned an invalid native timer handle", level)
    end

    rawset(timer, "_native", native)
    return true
end

local function restartTimer(timer, methodName, level)
    local scope = rawget(timer, "_scope")
    if rawget(scope, "_closed") == true then
        error(methodName .. " cannot restart a timer in a closed scope", level)
    end

    if rawget(timer, "_state") == "running" then
        cancelTimer(timer)
    end
    return startTimer(timer, methodName, level + 1)
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

local function createTimer(scope, delay, callback, repeating, methodName, level)
    validateScope(scope, methodName, level + 1)
    if rawget(scope, "_closed") == true then
        error(methodName .. " cannot create a timer in a closed scope", level)
    end
    if type(callback) ~= "function" then
        error(methodName .. " callback must be a function", level)
    end
    validateDelay(delay, repeating, methodName .. " delay", level + 1)
    return constructTimer(scope, delay, callback, repeating)
end

local function newTimerInScope(scope, options, methodName, level)
    validateScope(scope, methodName, level + 1)
    if rawget(scope, "_closed") == true then
        error(methodName .. " cannot create a timer in a closed scope", level)
    end
    local delay, callback, repeating = validateOptions(options, methodName, level + 1)
    return constructTimer(scope, delay, callback, repeating)
end

-- Shared by `Scope:After`/`Scope:Every` and their package-level counterparts, so
-- both entry points sit at the same distance from the validators and report
-- argument errors at their own caller's line.
local function startTimerInScope(scope, delay, callback, repeating, methodName, level)
    local timer = createTimer(scope, delay, callback, repeating, methodName, level + 1)
    startTimer(timer, methodName, level + 1)
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

-- Internal bulk cancellation. The caller owns validation, so scope cleanup
-- driven by LifecycleKit shutdown does not have to fake a public call site.
local function cancelAllInScope(scope)
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
            -- A timer whose native cancellation raised is still logically
            -- cancelled, but the count never reaches a caller: the captured
            -- error is re-raised below instead of returning a total.
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
    if rawget(scope, "_closed") == true then
        return false
    end

    -- Make the scope terminal before cleanup begins. Callback re-entry cannot
    -- schedule replacement timers while shutdown/Close is in progress.
    rawset(scope, "_closed", true)

    local firstError
    local okCancel, cancelError = pcall(cancelAllInScope, scope)
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
    if
        type(lifecycle) ~= "table"
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

---Return the logical timer state.
---@param self TimerKitTimer
---@return TimerKitTimerState state
local function timerGetState(self)
    validateTimer(self, "TimerKit.Timer:GetState", 3)
    return rawget(self, "_state")
end

---Return the configured delay or repeat interval in seconds.
---@param self TimerKitTimer
---@return number seconds
local function timerGetDelay(self)
    validateTimer(self, "TimerKit.Timer:GetDelay", 3)
    return rawget(self, "_delay")
end

---Return the scope that owns this timer.
---@param self TimerKitTimer
---@return TimerKitScope scope
local function timerGetScope(self)
    validateTimer(self, "TimerKit.Timer:GetScope", 3)
    return rawget(self, "_scope")
end

---Return the opaque value attached to this timer, or `nil` when none is set.
---@param self TimerKitTimer
---@return any userData
local function timerGetUserData(self)
    validateTimer(self, "TimerKit.Timer:GetUserData", 3)
    return rawget(self, "_userData")
end

---Attach one opaque value to this timer. TimerKit stores the reference and
---never reads, copies, or clears it; passing `nil` detaches it again.
---@param self TimerKitTimer
---@param value any
---@return TimerKitTimer self
local function timerSetUserData(self, value)
    validateTimer(self, "TimerKit.Timer:SetUserData", 3)
    rawset(self, "_userData", value)
    return self
end

---Return whether the timer repeats instead of firing once.
---@param self TimerKitTimer
---@return boolean repeating
local function timerIsRepeating(self)
    validateTimer(self, "TimerKit.Timer:IsRepeating", 3)
    return rawget(self, "_repeating") == true
end

---Return whether the logical timer is currently running.
---@param self TimerKitTimer
---@return boolean pending
local function timerIsPending(self)
    validateTimer(self, "TimerKit.Timer:IsPending", 3)
    return rawget(self, "_state") == "running"
end

---Return whether the timer was logically cancelled.
---@param self TimerKitTimer
---@return boolean cancelled
local function timerIsCancelled(self)
    validateTimer(self, "TimerKit.Timer:IsCancelled", 3)
    return rawget(self, "_state") == "cancelled"
end

---Start an idle, completed, or cancelled timer.
---@param self TimerKitTimer
---@return boolean started `false` when the timer was already running.
local function timerStart(self)
    validateTimer(self, "TimerKit.Timer:Start", 3)
    return startTimer(self, "TimerKit.Timer:Start", 3)
end

---Cancel a running timer.
---@param self TimerKitTimer
---@return boolean cancelled `false` when the timer was not running.
local function timerCancel(self)
    validateTimer(self, "TimerKit.Timer:Cancel", 3)
    return cancelTimer(self)
end

---Cancel the timer when needed and start a fresh logical generation.
---@param self TimerKitTimer
---@return boolean started
local function timerRestart(self)
    validateTimer(self, "TimerKit.Timer:Restart", 3)
    return restartTimer(self, "TimerKit.Timer:Restart", 3)
end

-- Scope public methods ------------------------------------------------------

---Create an idle timer owned by this scope.
---@param self TimerKitScope
---@param options TimerKitTimerOptions
---@return TimerKitTimer timer
local function scopeNew(self, options)
    return newTimerInScope(self, options, "TimerKit.Scope:New", 3)
end

---Create and immediately start a one-shot timer in this scope.
---@param self TimerKitScope
---@param delay number Finite seconds greater than or equal to zero.
---@param callback fun(timer: TimerKitTimer)
---@return TimerKitTimer timer
local function scopeAfter(self, delay, callback)
    return startTimerInScope(self, delay, callback, false, "TimerKit.Scope:After", 3)
end

---Create and immediately start a repeating timer in this scope.
---@param self TimerKitScope
---@param interval number Finite seconds greater than zero.
---@param callback fun(timer: TimerKitTimer)
---@return TimerKitTimer timer
local function scopeEvery(self, interval, callback)
    return startTimerInScope(self, interval, callback, true, "TimerKit.Scope:Every", 3)
end

---Cancel every active timer while keeping the scope reusable.
---@param self TimerKitScope
---@return integer cancelled
local function scopeCancelAll(self)
    validateScope(self, "TimerKit.Scope:CancelAll", 3)
    return cancelAllInScope(self)
end

---Terminally close the scope after best-effort cancellation.
---@param self TimerKitScope
---@return boolean closed `false` when the scope was already closed.
local function scopeClose(self)
    validateScope(self, "TimerKit.Scope:Close", 3)
    return closeScope(self)
end

---Return whether the scope is terminally closed.
---@param self TimerKitScope
---@return boolean closed
local function scopeIsClosed(self)
    validateScope(self, "TimerKit.Scope:IsClosed", 3)
    return rawget(self, "_closed") == true
end

---Return the owning addon name, or `nil` for a manual scope.
---@param self TimerKitScope
---@return string? addonName
local function scopeGetAddonName(self)
    validateScope(self, "TimerKit.Scope:GetAddonName", 3)
    return rawget(self, "_addonName")
end

---Return the number of logically running timers owned by this scope.
---@param self TimerKitScope
---@return integer activeCount
local function scopeGetActiveCount(self)
    validateScope(self, "TimerKit.Scope:GetActiveCount", 3)
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

---Create an idle timer in TimerKit's internal manual scope.
---@param options TimerKitTimerOptions
---@return TimerKitTimer timer
local function packageNew(_, options)
    return newTimerInScope(getDefaultScope(), options, "TimerKit:New", 3)
end

---Create and immediately start a one-shot timer in the internal manual scope.
---@param delay number Finite seconds greater than or equal to zero.
---@param callback fun(timer: TimerKitTimer)
---@return TimerKitTimer timer
local function packageAfter(_, delay, callback)
    return startTimerInScope(getDefaultScope(), delay, callback, false, "TimerKit:After", 3)
end

---Create and immediately start a repeating timer in the internal manual scope.
---@param interval number Finite seconds greater than zero.
---@param callback fun(timer: TimerKitTimer)
---@return TimerKitTimer timer
local function packageEvery(_, interval, callback)
    return startTimerInScope(getDefaultScope(), interval, callback, true, "TimerKit:Every", 3)
end

---Create a manually owned timer scope.
---@return TimerKitScope scope
local function createScope()
    return newScope(nil)
end

---Return the shared LifecycleKit-owned timer scope for an addon.
---@param addonName string
---@return TimerKitScope scope
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
rawset(Timer, "GetUserData", timerGetUserData)
rawset(Timer, "SetUserData", timerSetUserData)
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
