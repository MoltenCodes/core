-- MoltenCodes TimerKit
--
-- Cancelable, scope-aware World of Warcraft timers. TimerKit keeps the C_Timer
-- boundary narrow, adds deterministic logical state, guards stale native
-- callbacks across restart/cancel operations, and integrates addon-owned timer
-- scopes with LifecycleKit shutdown.
--
-- Contents
-- --------
--   Constants ............. package identity and option keys
--   Public types .......... LuaCATS declarations for the published surface
--   Dependencies .......... Registry, LifecycleKit, C_Timer, the monotonic clock
--   Validation ............ public-surface and shared-state validation
--   Bootstrap ............. Registry registration and inherited state
--   Generic helpers ....... error capture and argument validation
--   Timer internals ....... start, cancel, fire, restart, deadlines
--   Scope internals ....... active-set bookkeeping, bulk cancel, close
--   Timer public methods .. the handle a timer owner receives
--   Scope public methods .. the handle a scope owner receives
--   Package public API .... the facade published through Registry
--   Commit ................ prototype/facade assignment and self-check

local PACKAGE_NAME = "timerKit"
local API_GENERATION = 1
local IMPLEMENTATION_REVISION = 5
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
---@alias TimerKit.TimerState "idle"|"running"|"completed"|"cancelled"

---A timer callback, invoked with the logical timer handle that fired.
---@alias TimerKit.Callback fun(timer: TimerKit.Timer)

---Option table accepted by `TimerKit:New` and `TimerKit.Scope:New`.
---@class TimerKit.TimerOptions
---@field delay number Finite seconds; must be greater than zero when repeating.
---@field callback TimerKit.Callback Receives the logical timer handle.
---@field repeating boolean? Defaults to `false`.

---A cancelable logical timer owned by exactly one scope.
---@class TimerKit.Timer
---@field GetState fun(self: TimerKit.Timer): TimerKit.TimerState
---@field GetDelay fun(self: TimerKit.Timer): number
---@field GetScope fun(self: TimerKit.Timer): TimerKit.Scope
---@field GetUserData fun(self: TimerKit.Timer): any
---@field SetUserData fun(self: TimerKit.Timer, value: any): TimerKit.Timer
---@field IsRepeating fun(self: TimerKit.Timer): boolean
---@field IsPending fun(self: TimerKit.Timer): boolean
---@field IsCancelled fun(self: TimerKit.Timer): boolean
---@field Start fun(self: TimerKit.Timer): boolean
---@field Cancel fun(self: TimerKit.Timer): boolean
---@field Restart fun(self: TimerKit.Timer): boolean
---@field GetRemaining fun(self: TimerKit.Timer): number?
---@field GetDeadline fun(self: TimerKit.Timer): number?

---An ownership scope for timers, closed manually or by addon shutdown.
---@class TimerKit.Scope
---@field New fun(self: TimerKit.Scope, options: TimerKit.TimerOptions): TimerKit.Timer
---@field After fun(self: TimerKit.Scope, delay: number, callback: TimerKit.Callback): TimerKit.Timer
---@field Every fun(self: TimerKit.Scope, interval: number, callback: TimerKit.Callback): TimerKit.Timer
---@field CancelAll fun(self: TimerKit.Scope): integer
---@field Close fun(self: TimerKit.Scope): boolean
---@field IsClosed fun(self: TimerKit.Scope): boolean
---@field GetAddonName fun(self: TimerKit.Scope): string?
---@field GetActiveCount fun(self: TimerKit.Scope): integer

---The TimerKit package facade published through Registry.
---@class TimerKit
---@field API integer Public API generation.
---@field REVISION integer Compatible implementation revision.
---@field Timer TimerKit.Timer Shared timer prototype.
---@field Scope TimerKit.Scope Shared scope prototype.
---@field New fun(self: TimerKit, options: TimerKit.TimerOptions): TimerKit.Timer
---@field After fun(self: TimerKit, delay: number, callback: TimerKit.Callback): TimerKit.Timer
---@field Every fun(self: TimerKit, interval: number, callback: TimerKit.Callback): TimerKit.Timer
---@field CreateScope fun(self: TimerKit): TimerKit.Scope
---@field ForAddon fun(self: TimerKit, addonName: string): TimerKit.Scope

-- Dependencies --------------------------------------------------------------

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
    error("MoltenCodes TimerKit requires Registry API 2 to be loaded first", 2)
end

local bootstrapPackage = rawget(Registry, "Bootstrap")
local getPackage = rawget(Registry, "Get")
if type(bootstrapPackage) ~= "function" or type(getPackage) ~= "function" then
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

-- Deadlines are read from the same monotonic wall clock SchedulerKit falls back
-- to. `C_Timer` fires on wall time, so the CPU clock (`debugprofilestop`) would
-- be the wrong reference, and `GetTime()` is frame-quantised. The value is only
-- ever used for introspection; TimerKit never schedules from it, so it is
-- optional: a host without it loads TimerKit normally and records no deadlines.
-- Requiring it would add a host facility inside API generation 1.
-- GetTimePreciseSec is a World of Warcraft client API reachable only through the global table.
-- selene: allow(global_usage)
local nativeGetTimePreciseSec = rawget(_G, "GetTimePreciseSec")
if type(nativeGetTimePreciseSec) ~= "function" then
    nativeGetTimePreciseSec = nil
end

-- Validation ----------------------------------------------------------------

---Whether `implementation` exposes the complete TimerKit API 1 surface.
---@param implementation any shared package table handed back by Registry
---@return boolean
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
        and type(rawget(Timer, "GetRemaining")) == "function"
        and type(rawget(Timer, "GetDeadline")) == "function"
        and type(rawget(Scope, "New")) == "function"
        and type(rawget(Scope, "After")) == "function"
        and type(rawget(Scope, "Every")) == "function"
        and type(rawget(Scope, "CancelAll")) == "function"
        and type(rawget(Scope, "Close")) == "function"
        and type(rawget(Scope, "IsClosed")) == "function"
        and type(rawget(Scope, "GetAddonName")) == "function"
        and type(rawget(Scope, "GetActiveCount")) == "function"
end

---Whether `currentState` has the fields every API 1 revision shares.
---@param currentState any
---@return boolean
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

---Whether `implementation` carries package state of this revision's schema.
---@param implementation table
---@return boolean
local function validateCurrentState(implementation)
    local currentState = rawget(implementation, "_state")
    return validateStateBase(currentState) and type(rawget(currentState, "defaultScope")) == "table"
end

-- Bootstrap -----------------------------------------------------------------

-- `Registry:Bootstrap` owns the reconciliation every embedded package repeats:
-- look the package up, refuse to reinterpret state owned by a newer revision,
-- and register this one. What stays here is what only TimerKit can answer.
local TimerKit, previousRevision, selected = bootstrapPackage(Registry, {
    package = PACKAGE_NAME,
    api = API_GENERATION,
    revision = IMPLEMENTATION_REVISION,
    label = "MoltenCodes TimerKit",
    validatePublicSurface = validatePublicSurface,
    validateState = validateCurrentState,
})

if TimerKit == nil then
    -- Equal or newer compatible revision already owns the shared package table.
    return selected
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

-- Generic helpers -----------------------------------------------------------

---Wrap an error object so that `nil` and `false` stay representable.
---@param value any
---@return { value: any }
local function newErrorRecord(value)
    return { value = value }
end

---Keep the first failure of a best-effort loop.
---@param firstError { value: any }|nil
---@param ok boolean
---@param value any
---@return { value: any }|nil firstError
local function captureFirstError(firstError, ok, value)
    if not ok and firstError == nil then
        return newErrorRecord(value)
    end
    return firstError
end

---Re-raise a captured failure unchanged, or return when there was none.
---@param firstError { value: any }|nil
local function raiseCaptured(firstError)
    if firstError ~= nil then
        error(firstError.value, 0)
    end
end

-- Argument validation raises with an explicit stack level so the reported
-- position is the line that called the public method, never a line inside
-- TimerKit. `level` is always the value `error` needs *inside the function that
-- receives it*, so every further hop towards `error` adds exactly one.

---@param value any
---@param label string argument description, used in the argument error
---@param level integer stack level the failure is reported at
local function validateNonEmptyString(value, label, level)
    if type(value) ~= "string" or value == "" then
        error(label .. " must be a non-empty string", level)
    end
end

---@param delay any finite seconds; strictly positive for a repeating timer
---@param repeating boolean
---@param label string argument description, used in the argument error
---@param level integer stack level the failure is reported at
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

---Validate one `New`-style option table and unpack the values it carries.
---@param options any
---@param methodName string public method name, used in the argument errors
---@param level integer stack level the failures are reported at
---@return number delay
---@return TimerKit.Callback callback
---@return boolean repeating
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

---@param scope any receiver the public method was called on
---@param methodName string public method name, used in the argument error
---@param level integer stack level the failure is reported at
local function validateScope(scope, methodName, level)
    if type(scope) ~= "table" or getmetatable(scope) ~= SCOPE_METATABLE then
        error(methodName .. " must be called on a TimerKit scope", level)
    end
end

---@param timer any receiver the public method was called on
---@param methodName string public method name, used in the argument error
---@param level integer stack level the failure is reported at
local function validateTimer(timer, methodName, level)
    if type(timer) ~= "table" or getmetatable(timer) ~= TIMER_METATABLE then
        error(methodName .. " must be called on a TimerKit timer", level)
    end
end

-- Timer internals -----------------------------------------------------------

---Current monotonic wall-clock seconds, the reference every deadline uses.
---Only called once a deadline exists, which implies the clock does.
---@return number seconds
local function now()
    return nativeGetTimePreciseSec()
end

---The deadline for a fire `delay` seconds from now, or `false` without a clock.
---@param delay number
---@return number|false deadline
local function deadlineAfter(delay)
    if nativeGetTimePreciseSec == nil then
        return false
    end
    return nativeGetTimePreciseSec() + delay
end

---Return the host handle's `Cancel` method, or `nil` when it has none.
---@param native any handle returned by `C_Timer.NewTimer`/`NewTicker`
---@return fun(native: any)|nil
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

---Record `timer` as running inside `scope`.
---@param scope TimerKit.Scope
---@param timer TimerKit.Timer
local function attachActive(scope, timer)
    local active = rawget(scope, "_active")
    if rawget(active, timer) ~= true then
        rawset(active, timer, true)
        rawset(scope, "_activeCount", rawget(scope, "_activeCount") + 1)
    end
end

---Record `timer` as no longer running inside `scope`.
---@param scope TimerKit.Scope
---@param timer TimerKit.Timer
local function detachActive(scope, timer)
    local active = rawget(scope, "_active")
    if rawget(active, timer) == true then
        rawset(active, timer, nil)
        rawset(scope, "_activeCount", rawget(scope, "_activeCount") - 1)
    end
end

---Cancel one host timer handle, failing loudly when it is unusable.
---@param native any|nil
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

---Cancel `timer` logically, then ask the host to cancel its native handle.
---@param timer TimerKit.Timer
---@return boolean cancelled `false` when the timer was not running.
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
    rawset(timer, "_deadline", false)
    detachActive(scope, timer)

    cancelNative(native)
    return true
end

---Deliver one native callback, ignoring generations a restart superseded.
---@param timer TimerKit.Timer
---@param generation integer generation the native handle was created for
---@return boolean fired
local function fireTimer(timer, generation)
    if rawget(timer, "_generation") ~= generation or rawget(timer, "_state") ~= "running" then
        return false
    end

    local repeating = rawget(timer, "_repeating") == true
    if repeating then
        -- The host re-arms a ticker relative to the tick it just delivered, so
        -- the next deadline is one interval from now, not from the first start.
        rawset(timer, "_deadline", deadlineAfter(rawget(timer, "_delay")))
    else
        rawset(timer, "_native", nil)
        rawset(timer, "_state", "completed")
        rawset(timer, "_deadline", false)
        detachActive(rawget(timer, "_scope"), timer)
    end

    rawget(timer, "_callback")(timer)
    return true
end

---Undo the bookkeeping of a start whose host call failed.
---@param timer TimerKit.Timer
---@param previousState TimerKit.TimerState
local function rollbackStart(timer, previousState)
    rawset(timer, "_native", nil)
    rawset(timer, "_state", previousState)
    rawset(timer, "_deadline", false)
    detachActive(rawget(timer, "_scope"), timer)
end

-- The caller has already validated `timer`; `level` identifies that caller so a
-- closed-scope or invalid-host-handle failure still reports at its line.
---Start `timer` and bind a fresh generation to its new native handle.
---@param timer TimerKit.Timer
---@param methodName string public method name, used in the argument error
---@param level integer stack level the failure is reported at
---@return boolean started `false` when the timer was already running.
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
    rawset(timer, "_deadline", deadlineAfter(rawget(timer, "_delay")))
    return true
end

---Cancel `timer` when it is running, then start it again.
---@param timer TimerKit.Timer
---@param methodName string public method name, used in the argument error
---@param level integer stack level the failure is reported at
---@return boolean started
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

---Return the next per-session timer identifier, used for stable ordering.
---@return integer
local function nextTimerId()
    local id = rawget(state, "nextTimerId") + 1
    rawset(state, "nextTimerId", id)
    return id
end

---Build one idle timer. The caller owns all validation.
---@param scope TimerKit.Scope
---@param delay number
---@param callback TimerKit.Callback
---@param repeating boolean
---@return TimerKit.Timer
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
        -- `false` rather than `nil` keeps the slot in the table from creation,
        -- so the first start does not rehash the timer.
        _deadline = false,
    }, TIMER_METATABLE)
end

---Validate the `After`/`Every` arguments and build the idle timer.
---@param scope TimerKit.Scope
---@param delay any
---@param callback any
---@param repeating boolean
---@param methodName string public method name, used in the argument errors
---@param level integer stack level the failures are reported at
---@return TimerKit.Timer
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

---Validate a `New` option table and build the idle timer it describes.
---@param scope TimerKit.Scope
---@param options any
---@param methodName string public method name, used in the argument errors
---@param level integer stack level the failures are reported at
---@return TimerKit.Timer
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
---@param scope TimerKit.Scope
---@param delay any
---@param callback any
---@param repeating boolean
---@param methodName string public method name, used in the argument errors
---@param level integer stack level the failures are reported at
---@return TimerKit.Timer
local function startTimerInScope(scope, delay, callback, repeating, methodName, level)
    local timer = createTimer(scope, delay, callback, repeating, methodName, level + 1)
    startTimer(timer, methodName, level + 1)
    return timer
end

-- Scope internals -----------------------------------------------------------

---Return every running timer of `scope`, ordered by creation, as a snapshot.
---@param scope TimerKit.Scope
---@return TimerKit.Timer[]
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
---@param scope TimerKit.Scope
---@return integer cancelled
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

---Drop the LifecycleKit shutdown subscription an addon scope holds.
---@param scope TimerKit.Scope
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

---Terminally close `scope` after best-effort cancellation and unsubscription.
---@param scope TimerKit.Scope
---@return boolean closed `false` when the scope was already closed.
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

---Build one open scope. `addonName` is `nil` for a manually owned scope.
---@param addonName string|nil
---@return TimerKit.Scope
local function newScope(addonName)
    return setmetatable({
        _addonName = addonName,
        _active = {},
        _activeCount = 0,
        _closed = false,
        _shutdownSubscription = nil,
    }, SCOPE_METATABLE)
end

---Build the addon-owned scope for `addonName` and bind it to addon shutdown.
---@param addonName string
---@return TimerKit.Scope
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
---@param self TimerKit.Timer
---@return TimerKit.TimerState state
local function timerGetState(self)
    validateTimer(self, "TimerKit.Timer:GetState", 3)
    return rawget(self, "_state")
end

---Return the configured delay or repeat interval in seconds.
---@param self TimerKit.Timer
---@return number seconds
local function timerGetDelay(self)
    validateTimer(self, "TimerKit.Timer:GetDelay", 3)
    return rawget(self, "_delay")
end

---Return the scope that owns this timer.
---@param self TimerKit.Timer
---@return TimerKit.Scope scope
local function timerGetScope(self)
    validateTimer(self, "TimerKit.Timer:GetScope", 3)
    return rawget(self, "_scope")
end

---Return the opaque value attached to this timer, or `nil` when none is set.
---@param self TimerKit.Timer
---@return any userData
local function timerGetUserData(self)
    validateTimer(self, "TimerKit.Timer:GetUserData", 3)
    return rawget(self, "_userData")
end

---Attach one opaque value to this timer. TimerKit stores the reference and
---never reads, copies, or clears it; passing `nil` detaches it again.
---@param self TimerKit.Timer
---@param value any
---@return TimerKit.Timer self
local function timerSetUserData(self, value)
    validateTimer(self, "TimerKit.Timer:SetUserData", 3)
    rawset(self, "_userData", value)
    return self
end

---Return whether the timer repeats instead of firing once.
---@param self TimerKit.Timer
---@return boolean repeating
local function timerIsRepeating(self)
    validateTimer(self, "TimerKit.Timer:IsRepeating", 3)
    return rawget(self, "_repeating") == true
end

---Return whether the logical timer is currently running.
---@param self TimerKit.Timer
---@return boolean pending
local function timerIsPending(self)
    validateTimer(self, "TimerKit.Timer:IsPending", 3)
    return rawget(self, "_state") == "running"
end

---Return whether the timer was logically cancelled.
---@param self TimerKit.Timer
---@return boolean cancelled
local function timerIsCancelled(self)
    validateTimer(self, "TimerKit.Timer:IsCancelled", 3)
    return rawget(self, "_state") == "cancelled"
end

---Start an idle, completed, or cancelled timer.
---@param self TimerKit.Timer
---@return boolean started `false` when the timer was already running.
local function timerStart(self)
    validateTimer(self, "TimerKit.Timer:Start", 3)
    return startTimer(self, "TimerKit.Timer:Start", 3)
end

---Cancel a running timer.
---@param self TimerKit.Timer
---@return boolean cancelled `false` when the timer was not running.
local function timerCancel(self)
    validateTimer(self, "TimerKit.Timer:Cancel", 3)
    return cancelTimer(self)
end

---Cancel the timer when needed and start a fresh logical generation.
---@param self TimerKit.Timer
---@return boolean started
local function timerRestart(self)
    validateTimer(self, "TimerKit.Timer:Restart", 3)
    return restartTimer(self, "TimerKit.Timer:Restart", 3)
end

---Return the monotonic instant this timer fires next, or `nil` when it is not
---running.
---
---The instant is on the `GetTimePreciseSec()` clock. It is TimerKit's own
---accounting of when it asked the host to fire, not a promise from the host:
---`C_Timer` delivers on the first frame at or after that instant.
---@param self TimerKit.Timer
---@return number? deadline seconds on the `GetTimePreciseSec()` clock
local function timerGetDeadline(self)
    validateTimer(self, "TimerKit.Timer:GetDeadline", 3)
    if rawget(self, "_state") ~= "running" then
        return nil
    end
    local deadline = rawget(self, "_deadline")
    if type(deadline) ~= "number" then
        -- Started by a revision that kept no deadline; see API.md.
        return nil
    end
    return deadline
end

---Return the seconds left until this timer fires next, or `nil` when it is not
---running. Never negative: a timer the host has not delivered yet although its
---deadline passed reports `0`.
---@param self TimerKit.Timer
---@return number? remaining seconds, an estimate; see `GetDeadline`
local function timerGetRemaining(self)
    validateTimer(self, "TimerKit.Timer:GetRemaining", 3)
    if rawget(self, "_state") ~= "running" then
        return nil
    end
    local deadline = rawget(self, "_deadline")
    if type(deadline) ~= "number" then
        return nil
    end
    local remaining = deadline - now()
    if remaining < 0 then
        return 0
    end
    return remaining
end

-- Scope public methods ------------------------------------------------------

---Create an idle timer owned by this scope.
---@param self TimerKit.Scope
---@param options TimerKit.TimerOptions
---@return TimerKit.Timer timer
local function scopeNew(self, options)
    return newTimerInScope(self, options, "TimerKit.Scope:New", 3)
end

---Create and immediately start a one-shot timer in this scope.
---@param self TimerKit.Scope
---@param delay number Finite seconds greater than or equal to zero.
---@param callback TimerKit.Callback
---@return TimerKit.Timer timer
local function scopeAfter(self, delay, callback)
    return startTimerInScope(self, delay, callback, false, "TimerKit.Scope:After", 3)
end

---Create and immediately start a repeating timer in this scope.
---@param self TimerKit.Scope
---@param interval number Finite seconds greater than zero.
---@param callback TimerKit.Callback
---@return TimerKit.Timer timer
local function scopeEvery(self, interval, callback)
    return startTimerInScope(self, interval, callback, true, "TimerKit.Scope:Every", 3)
end

---Cancel every active timer while keeping the scope reusable.
---@param self TimerKit.Scope
---@return integer cancelled
local function scopeCancelAll(self)
    validateScope(self, "TimerKit.Scope:CancelAll", 3)
    return cancelAllInScope(self)
end

---Terminally close the scope after best-effort cancellation.
---@param self TimerKit.Scope
---@return boolean closed `false` when the scope was already closed.
local function scopeClose(self)
    validateScope(self, "TimerKit.Scope:Close", 3)
    return closeScope(self)
end

---Return whether the scope is terminally closed.
---@param self TimerKit.Scope
---@return boolean closed
local function scopeIsClosed(self)
    validateScope(self, "TimerKit.Scope:IsClosed", 3)
    return rawget(self, "_closed") == true
end

---Return the owning addon name, or `nil` for a manual scope.
---@param self TimerKit.Scope
---@return string? addonName
local function scopeGetAddonName(self)
    validateScope(self, "TimerKit.Scope:GetAddonName", 3)
    return rawget(self, "_addonName")
end

---Return the number of logically running timers owned by this scope.
---@param self TimerKit.Scope
---@return integer activeCount
local function scopeGetActiveCount(self)
    validateScope(self, "TimerKit.Scope:GetActiveCount", 3)
    return rawget(self, "_activeCount")
end

-- Package public API --------------------------------------------------------

---Return TimerKit's internal manual scope, replacing it once it is closed.
---@return TimerKit.Scope
local function getDefaultScope()
    local scope = rawget(state, "defaultScope")
    if scope == false or rawget(scope, "_closed") == true then
        scope = newScope(nil)
        rawset(state, "defaultScope", scope)
    end
    return scope
end

---Create an idle timer in TimerKit's internal manual scope.
---@param _ TimerKit
---@param options TimerKit.TimerOptions
---@return TimerKit.Timer timer
local function packageNew(_, options)
    return newTimerInScope(getDefaultScope(), options, "TimerKit:New", 3)
end

---Create and immediately start a one-shot timer in the internal manual scope.
---@param _ TimerKit
---@param delay number Finite seconds greater than or equal to zero.
---@param callback TimerKit.Callback
---@return TimerKit.Timer timer
local function packageAfter(_, delay, callback)
    return startTimerInScope(getDefaultScope(), delay, callback, false, "TimerKit:After", 3)
end

---Create and immediately start a repeating timer in the internal manual scope.
---@param _ TimerKit
---@param interval number Finite seconds greater than zero.
---@param callback TimerKit.Callback
---@return TimerKit.Timer timer
local function packageEvery(_, interval, callback)
    return startTimerInScope(getDefaultScope(), interval, callback, true, "TimerKit:Every", 3)
end

---Create a manually owned timer scope, closed only by its owner.
---@return TimerKit.Scope scope
local function createScope()
    return newScope(nil)
end

---Return the shared LifecycleKit-owned timer scope for an addon.
---@param _ TimerKit
---@param addonName string addon folder name, as LifecycleKit matches it
---@return TimerKit.Scope scope
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
rawset(Timer, "GetRemaining", timerGetRemaining)
rawset(Timer, "GetDeadline", timerGetDeadline)

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
