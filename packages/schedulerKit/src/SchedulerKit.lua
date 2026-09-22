-- MoltenCodes SchedulerKit
--
-- Cooperative, frame-budgeted scheduling for World of Warcraft addons.
-- SchedulerKit combines deterministic priority queues, resumable coroutine
-- jobs, cancellation scopes, TimerKit-backed delays, and LifecycleKit cleanup
-- while keeping the WoW OnUpdate/profiling boundary narrow and testable.

local PACKAGE_NAME = "schedulerKit"
local API_GENERATION = 1
local IMPLEMENTATION_REVISION = 3
local REQUIRED_REGISTRY_API = 2
local REQUIRED_LIFECYCLE_API = 1
local REQUIRED_TIMER_API = 1
local STATE_SCHEMA = 1

local PRIORITY_HIGH = 1
local PRIORITY_NORMAL = 2
local PRIORITY_LOW = 3
local PRIORITY_IDLE = 4
local PRIORITY_COUNT = 4

-- Weighted fair sequence. The cursor is preserved between frames so a stream
-- of HIGH work cannot permanently starve lower-priority lanes.
local PRIORITY_SLOTS = {
    PRIORITY_HIGH,
    PRIORITY_HIGH,
    PRIORITY_HIGH,
    PRIORITY_HIGH,
    PRIORITY_NORMAL,
    PRIORITY_NORMAL,
    PRIORITY_LOW,
    PRIORITY_IDLE,
}

local DEFAULT_FRAME_BUDGET_MS = 2
local DEFAULT_RUNAWAY_THRESHOLD_MS = 8
local DEFAULT_MAX_RESUMES_PER_FRAME = 1000
local SCHEDULING_OPTION_KEYS = {
    priority = true,
    name = true,
}

-- Dependencies --------------------------------------------------------------

-- The shared MoltenCodes namespace is the one documented global handoff point between independently embedded copies.
-- selene: allow(global_usage)
local namespace = rawget(_G, "MoltenCodes")
if type(namespace) ~= "table" then
    error("MoltenCodes SchedulerKit requires Registry API 2 to be loaded first", 2)
end

local Registry = rawget(namespace, "Registry")
if type(Registry) ~= "table" or rawget(Registry, "API") ~= REQUIRED_REGISTRY_API then
    error("MoltenCodes SchedulerKit requires Registry API 2 to be loaded first", 2)
end

local registerPackage = rawget(Registry, "Register")
local getPackage = rawget(Registry, "Get")
if type(registerPackage) ~= "function" or type(getPackage) ~= "function" then
    error("MoltenCodes SchedulerKit requires a valid Registry API 2 facade", 2)
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
    error("MoltenCodes SchedulerKit requires a valid LifecycleKit API 1 facade", 2)
end

local TimerKit, timerRevision = getPackage(Registry, "timerKit", REQUIRED_TIMER_API)
local TimerScope = type(TimerKit) == "table" and rawget(TimerKit, "Scope") or nil
local Timer = type(TimerKit) == "table" and rawget(TimerKit, "Timer") or nil
if
    type(TimerKit) ~= "table"
    or type(timerRevision) ~= "number"
    or rawget(TimerKit, "API") ~= REQUIRED_TIMER_API
    or rawget(TimerKit, "REVISION") ~= timerRevision
    or type(rawget(TimerKit, "CreateScope")) ~= "function"
    or type(TimerScope) ~= "table"
    or type(rawget(TimerScope, "After")) ~= "function"
    or type(rawget(TimerScope, "Close")) ~= "function"
    or type(Timer) ~= "table"
    or type(rawget(Timer, "Cancel")) ~= "function"
then
    error("MoltenCodes SchedulerKit requires a valid TimerKit API 1 facade", 2)
end

-- CreateFrame is a World of Warcraft client API reachable only through the global table.
-- selene: allow(global_usage)
local nativeCreateFrame = rawget(_G, "CreateFrame")
-- GetTimePreciseSec is a World of Warcraft client API reachable only through the global table.
-- selene: allow(global_usage)
local nativeGetTimePreciseSec = rawget(_G, "GetTimePreciseSec")
if type(nativeCreateFrame) ~= "function" then
    error("MoltenCodes SchedulerKit requires CreateFrame", 2)
end
if type(nativeGetTimePreciseSec) ~= "function" then
    error("MoltenCodes SchedulerKit requires GetTimePreciseSec", 2)
end

-- Validation ---------------------------------------------------------------

local function validatePublicSurface(implementation)
    if
        type(implementation) ~= "table"
        or rawget(implementation, "API") ~= API_GENERATION
        or type(rawget(implementation, "REVISION")) ~= "number"
        or type(rawget(implementation, "Priority")) ~= "table"
        or type(rawget(implementation, "Job")) ~= "table"
        or type(rawget(implementation, "Scope")) ~= "table"
        or type(rawget(implementation, "Context")) ~= "table"
    then
        return false
    end

    local Job = rawget(implementation, "Job")
    local Scope = rawget(implementation, "Scope")
    local Context = rawget(implementation, "Context")

    return type(rawget(implementation, "Schedule")) == "function"
        and type(rawget(implementation, "NextFrame")) == "function"
        and type(rawget(implementation, "After")) == "function"
        and type(rawget(implementation, "Every")) == "function"
        and type(rawget(implementation, "CreateScope")) == "function"
        and type(rawget(implementation, "ForAddon")) == "function"
        and type(rawget(implementation, "SetFrameBudget")) == "function"
        and type(rawget(implementation, "GetFrameBudget")) == "function"
        and type(rawget(implementation, "SetRunawayThreshold")) == "function"
        and type(rawget(implementation, "GetRunawayThreshold")) == "function"
        and type(rawget(implementation, "SetMaxResumesPerFrame")) == "function"
        and type(rawget(implementation, "GetMaxResumesPerFrame")) == "function"
        and type(rawget(implementation, "GetActiveCount")) == "function"
        and type(rawget(Job, "GetState")) == "function"
        and type(rawget(Job, "GetPriority")) == "function"
        and type(rawget(Job, "GetScope")) == "function"
        and type(rawget(Job, "GetName")) == "function"
        and type(rawget(Job, "IsPending")) == "function"
        and type(rawget(Job, "IsCancelled")) == "function"
        and type(rawget(Job, "HasError")) == "function"
        and type(rawget(Job, "GetError")) == "function"
        and type(rawget(Job, "Cancel")) == "function"
        and type(rawget(Scope, "Schedule")) == "function"
        and type(rawget(Scope, "NextFrame")) == "function"
        and type(rawget(Scope, "After")) == "function"
        and type(rawget(Scope, "Every")) == "function"
        and type(rawget(Scope, "CancelAll")) == "function"
        and type(rawget(Scope, "Close")) == "function"
        and type(rawget(Scope, "IsClosed")) == "function"
        and type(rawget(Scope, "GetAddonName")) == "function"
        and type(rawget(Scope, "GetActiveCount")) == "function"
        and type(rawget(Context, "ShouldYield")) == "function"
        and type(rawget(Context, "Yield")) == "function"
        and type(rawget(Context, "GetJob")) == "function"
        and type(rawget(Context, "IsCancelled")) == "function"
end

local function validateStateBase(currentState)
    if
        type(currentState) ~= "table"
        or rawget(currentState, "schema") ~= STATE_SCHEMA
        or type(rawget(currentState, "addonScopes")) ~= "table"
        or type(rawget(currentState, "dispatch")) ~= "table"
        or type(rawget(currentState, "queues")) ~= "table"
        or type(rawget(currentState, "config")) ~= "table"
        or type(rawget(currentState, "jobMetatable")) ~= "table"
        or type(rawget(currentState, "scopeMetatable")) ~= "table"
        or type(rawget(currentState, "contextMetatable")) ~= "table"
        or type(rawget(currentState, "yieldToken")) ~= "table"
        or type(rawget(currentState, "priorityCursor")) ~= "number"
        or type(rawget(currentState, "activeCount")) ~= "number"
    then
        return false
    end

    local queues = rawget(currentState, "queues")
    for priority = 1, PRIORITY_COUNT do
        local queue = rawget(queues, priority)
        if
            type(queue) ~= "table"
            or type(rawget(queue, "items")) ~= "table"
            or type(rawget(queue, "head")) ~= "number"
            or type(rawget(queue, "tail")) ~= "number"
        then
            return false
        end
    end

    local config = rawget(currentState, "config")
    return type(rawget(config, "frameBudgetMs")) == "number"
        and type(rawget(config, "runawayThresholdMs")) == "number"
        and type(rawget(config, "maxResumesPerFrame")) == "number"
end

local function validateCurrentState(implementation)
    local currentState = rawget(implementation, "_state")
    if not validateStateBase(currentState) then
        return false
    end

    local defaultScope = rawget(currentState, "defaultScope")
    if defaultScope == false then
        return true
    end

    return type(defaultScope) == "table"
        and getmetatable(defaultScope) == rawget(currentState, "scopeMetatable")
end

local existing, existingRevision = getPackage(Registry, PACKAGE_NAME, API_GENERATION)
if existing ~= nil then
    if type(existing) ~= "table" or rawget(existing, "API") ~= API_GENERATION then
        error("MoltenCodes SchedulerKit package state is corrupted or incomplete", 2)
    end

    local facadeRevision = rawget(existing, "REVISION")
    if type(facadeRevision) ~= "number" or facadeRevision > existingRevision then
        error("MoltenCodes SchedulerKit package state is corrupted or incomplete", 2)
    end

    if existingRevision > IMPLEMENTATION_REVISION then
        if facadeRevision ~= existingRevision or not validatePublicSurface(existing) then
            error("MoltenCodes SchedulerKit package state is corrupted or incomplete", 2)
        end
        return existing
    elseif existingRevision == IMPLEMENTATION_REVISION then
        if
            facadeRevision ~= existingRevision
            or not validatePublicSurface(existing)
            or not validateCurrentState(existing)
        then
            error("MoltenCodes SchedulerKit package state is corrupted or incomplete", 2)
        end
        return existing
    end
end

local SchedulerKit, previousRevision =
    registerPackage(Registry, PACKAGE_NAME, API_GENERATION, IMPLEMENTATION_REVISION)
if SchedulerKit == nil then
    return existing
end

local Job = rawget(SchedulerKit, "Job")
local Scope = rawget(SchedulerKit, "Scope")
local Context = rawget(SchedulerKit, "Context")
local Priority = rawget(SchedulerKit, "Priority")
local state = rawget(SchedulerKit, "_state")

local function newQueue()
    return { items = {}, head = 1, tail = 0 }
end

if previousRevision == nil then
    if Job ~= nil or Scope ~= nil or Context ~= nil or Priority ~= nil or state ~= nil then
        error("MoltenCodes SchedulerKit package state is corrupted or incomplete", 2)
    end

    Job = {}
    Scope = {}
    Context = {}
    Priority = {
        HIGH = PRIORITY_HIGH,
        NORMAL = PRIORITY_NORMAL,
        LOW = PRIORITY_LOW,
        IDLE = PRIORITY_IDLE,
    }
    state = {
        schema = STATE_SCHEMA,
        addonScopes = {},
        defaultScope = false,
        dispatch = {},
        queues = {
            [PRIORITY_HIGH] = newQueue(),
            [PRIORITY_NORMAL] = newQueue(),
            [PRIORITY_LOW] = newQueue(),
            [PRIORITY_IDLE] = newQueue(),
        },
        config = {
            frameBudgetMs = DEFAULT_FRAME_BUDGET_MS,
            runawayThresholdMs = DEFAULT_RUNAWAY_THRESHOLD_MS,
            maxResumesPerFrame = DEFAULT_MAX_RESUMES_PER_FRAME,
        },
        jobMetatable = {},
        scopeMetatable = {},
        contextMetatable = {},
        yieldToken = {},
        priorityCursor = 1,
        activeCount = 0,
        frame = false,
        driverEnabled = false,
        driverTrampoline = false,
        currentJob = false,
        frameDeadline = false,
    }
    rawset(SchedulerKit, "Job", Job)
    rawset(SchedulerKit, "Scope", Scope)
    rawset(SchedulerKit, "Context", Context)
    rawset(SchedulerKit, "Priority", Priority)
    rawset(SchedulerKit, "_state", state)
elseif
    type(Job) ~= "table"
    or type(Scope) ~= "table"
    or type(Context) ~= "table"
    or type(Priority) ~= "table"
    or not validateStateBase(state)
then
    error("MoltenCodes SchedulerKit package state is corrupted or incomplete", 2)
end

-- Revision 3 removes two revision-2 bookkeeping fields that never
-- participated in scheduling behavior or diagnostics. Clear inherited values
-- during a compatible live upgrade so shared state does not retain dead data.
rawset(state, "nextJobId", nil)
rawset(state, "runtimeRevision", nil)

local JOB_METATABLE = rawget(state, "jobMetatable")
local SCOPE_METATABLE = rawget(state, "scopeMetatable")
local CONTEXT_METATABLE = rawget(state, "contextMetatable")
rawset(JOB_METATABLE, "__index", Job)
rawset(SCOPE_METATABLE, "__index", Scope)
rawset(CONTEXT_METATABLE, "__index", Context)

-- Generic helpers -----------------------------------------------------------

local function validateNonEmptyString(value, label, level)
    if type(value) ~= "string" or value == "" then
        error(label .. " must be a non-empty string", level or 3)
    end
end

local function validateFinitePositive(value, label, allowZero, level)
    if
        type(value) ~= "number"
        or value ~= value
        or value == math.huge
        or value == -math.huge
        or (allowZero and value < 0)
        or (not allowZero and value <= 0)
    then
        if allowZero then
            error(label .. " must be a finite number greater than or equal to zero", level or 3)
        else
            error(label .. " must be a finite number greater than zero", level or 3)
        end
    end
end

local function validatePositiveInteger(value, label, level)
    if
        type(value) ~= "number"
        or value ~= value
        or value == math.huge
        or value == -math.huge
        or value ~= math.floor(value)
        or value <= 0
    then
        error(label .. " must be a finite positive integer", level or 3)
    end
end

local function validatePriority(priority, label, level)
    if priority == nil then
        return PRIORITY_NORMAL
    end
    if
        type(priority) ~= "number"
        or priority ~= math.floor(priority)
        or priority < PRIORITY_HIGH
        or priority > PRIORITY_IDLE
    then
        error(label .. " must be one of SchedulerKit.Priority values", level or 3)
    end
    return priority
end

local function validateOptions(options, methodName)
    if options == nil then
        return PRIORITY_NORMAL, nil
    end
    if type(options) ~= "table" then
        error(methodName .. " options must be a table", 4)
    end

    local unknown = nil
    for key in pairs(options) do
        if SCHEDULING_OPTION_KEYS[key] ~= true then
            local display = tostring(key)
            if unknown == nil or display < unknown then
                unknown = display
            end
        end
    end
    if unknown ~= nil then
        error(methodName .. ' options contains unknown field "' .. unknown .. '"', 4)
    end

    local priority = validatePriority(rawget(options, "priority"), methodName .. " priority", 4)
    local name = rawget(options, "name")
    if name ~= nil then
        validateNonEmptyString(name, methodName .. " name", 4)
    end
    return priority, name
end

local function now()
    local value = nativeGetTimePreciseSec()
    if type(value) ~= "number" or value ~= value or value == math.huge or value == -math.huge then
        error("MoltenCodes SchedulerKit GetTimePreciseSec returned an invalid value", 0)
    end
    return value * 1000
end

local function reportError(value)
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

local function validateScope(scope, methodName)
    if type(scope) ~= "table" or getmetatable(scope) ~= SCOPE_METATABLE then
        error(methodName .. " must be called on a SchedulerKit scope", 3)
    end
end

local function validateJob(job, methodName)
    if type(job) ~= "table" or getmetatable(job) ~= JOB_METATABLE then
        error(methodName .. " must be called on a SchedulerKit job", 3)
    end
end

local function validateContext(context, methodName)
    if type(context) ~= "table" or getmetatable(context) ~= CONTEXT_METATABLE then
        error(methodName .. " must be called on a SchedulerKit context", 3)
    end
end

local function isTerminalJobState(jobState)
    return jobState == "completed" or jobState == "cancelled" or jobState == "failed"
end

-- Scope ownership -----------------------------------------------------------

local function linkActive(scope, job)
    local tail = rawget(scope, "_tail")
    rawset(job, "_scopePrev", tail)
    rawset(job, "_scopeNext", false)
    if tail ~= false then
        rawset(tail, "_scopeNext", job)
    else
        rawset(scope, "_head", job)
    end
    rawset(scope, "_tail", job)
    rawset(scope, "_activeCount", rawget(scope, "_activeCount") + 1)
    rawset(state, "activeCount", rawget(state, "activeCount") + 1)
end

local function unlinkActive(scope, job)
    if rawget(job, "_active") ~= true then
        return
    end

    local previous = rawget(job, "_scopePrev")
    local following = rawget(job, "_scopeNext")
    if previous ~= false then
        rawset(previous, "_scopeNext", following)
    else
        rawset(scope, "_head", following)
    end
    if following ~= false then
        rawset(following, "_scopePrev", previous)
    else
        rawset(scope, "_tail", previous)
    end

    rawset(job, "_scopePrev", false)
    rawset(job, "_scopeNext", false)
    rawset(job, "_active", false)
    rawset(scope, "_activeCount", rawget(scope, "_activeCount") - 1)
    rawset(state, "activeCount", rawget(state, "activeCount") - 1)
end

local function disconnectShutdownSubscription(scope)
    local subscription = rawget(scope, "_shutdownSubscription")
    if subscription == false then
        return nil
    end
    rawset(scope, "_shutdownSubscription", false)
    local ok, value = pcall(function()
        return subscription:Disconnect()
    end)
    if not ok then
        return { value = value }
    end
    return nil
end

-- Ready queues --------------------------------------------------------------

local function queuePush(job)
    if rawget(job, "_queued") == true then
        return
    end
    local priority = rawget(job, "_priority")
    local queue = rawget(rawget(state, "queues"), priority)
    local tail = rawget(queue, "tail") + 1
    rawset(queue, "tail", tail)
    rawget(queue, "items")[tail] = job
    rawset(job, "_queued", true)
end

local function queuePop(priority)
    local queue = rawget(rawget(state, "queues"), priority)
    local items = rawget(queue, "items")
    local head = rawget(queue, "head")
    local tail = rawget(queue, "tail")

    while head <= tail do
        local job = items[head]
        items[head] = nil
        head = head + 1
        rawset(queue, "head", head)

        if
            type(job) == "table"
            and rawget(job, "_queued") == true
            and rawget(job, "_state") == "pending"
        then
            rawset(job, "_queued", false)
            return job
        end
    end

    if head > tail then
        rawset(queue, "head", 1)
        rawset(queue, "tail", 0)
    end
    return nil
end

local function queueHasLive(priority)
    local queue = rawget(rawget(state, "queues"), priority)
    local items = rawget(queue, "items")
    local head = rawget(queue, "head")
    local tail = rawget(queue, "tail")

    while head <= tail do
        local job = items[head]
        if
            type(job) == "table"
            and rawget(job, "_queued") == true
            and rawget(job, "_state") == "pending"
        then
            return true
        end
        items[head] = nil
        head = head + 1
        rawset(queue, "head", head)
    end

    if head > tail then
        rawset(queue, "head", 1)
        rawset(queue, "tail", 0)
    end
    return false
end

local function hasReadyJobs()
    for priority = 1, PRIORITY_COUNT do
        if queueHasLive(priority) then
            return true
        end
    end
    return false
end

local function nextReadyJob()
    local slotCount = #PRIORITY_SLOTS
    local cursor = rawget(state, "priorityCursor")
    for _ = 1, slotCount do
        local priority = PRIORITY_SLOTS[cursor]
        cursor = cursor + 1
        if cursor > slotCount then
            cursor = 1
        end
        rawset(state, "priorityCursor", cursor)

        local job = queuePop(priority)
        if job ~= nil then
            return job
        end
    end
    return nil
end

-- Driver -------------------------------------------------------------------

local function ensureDriver()
    local frame = rawget(state, "frame")
    if frame ~= false then
        return frame
    end

    frame = nativeCreateFrame("Frame")
    if frame == nil or type(frame.SetScript) ~= "function" then
        error("MoltenCodes SchedulerKit CreateFrame returned an invalid Frame", 0)
    end

    local trampoline = rawget(state, "driverTrampoline")
    if trampoline == false then
        trampoline = function(_, elapsed)
            local dispatch = rawget(state, "dispatch")
            local runFrame = type(dispatch) == "table" and rawget(dispatch, "runFrame") or nil
            if type(runFrame) ~= "function" then
                error("MoltenCodes SchedulerKit runtime dispatch is corrupted", 0)
            end
            return runFrame(elapsed)
        end
        rawset(state, "driverTrampoline", trampoline)
    end

    rawset(state, "frame", frame)
    return frame
end

local function updateDriver()
    local needed = hasReadyJobs()
    local enabled = rawget(state, "driverEnabled") == true
    if needed == enabled then
        return
    end

    local frame = ensureDriver()
    if needed then
        frame:SetScript("OnUpdate", rawget(state, "driverTrampoline"))
        rawset(state, "driverEnabled", true)
    else
        frame:SetScript("OnUpdate", nil)
        rawset(state, "driverEnabled", false)
    end
end

-- Job terminal/error handling ---------------------------------------------

local function detachDelayTimer(job)
    local delayTimer = rawget(job, "_delayTimer")
    rawset(job, "_delayTimer", false)
    if type(delayTimer) == "table" then
        rawset(delayTimer, "__schedulerKitJob", nil)
        rawset(delayTimer, "__schedulerKitGeneration", nil)
    end
    return delayTimer
end

local function finishJob(job, terminalState)
    rawset(job, "_state", terminalState)
    rawset(job, "_queued", false)
    rawset(job, "_coroutine", false)
    rawset(job, "_callback", false)
    rawset(job, "_context", false)
    rawset(job, "_delayTimer", false)
    local scope = rawget(job, "_scope")
    unlinkActive(scope, job)
end

local function failJob(job, value)
    rawset(job, "_errorPresent", true)
    rawset(job, "_error", value)
    finishJob(job, "failed")
    reportError(value)
end

local function cancelJob(job)
    validateJob(job, "SchedulerKit.Job:Cancel")
    local jobState = rawget(job, "_state")
    if isTerminalJobState(jobState) then
        return false
    end

    rawset(job, "_generation", rawget(job, "_generation") + 1)
    rawset(job, "_queued", false)
    local delayTimer = detachDelayTimer(job)
    finishJob(job, "cancelled")

    local firstError = nil
    if delayTimer ~= false then
        local ok, value = pcall(function()
            return delayTimer:Cancel()
        end)
        if not ok then
            firstError = { value = value }
        end
    end

    local ok, value = pcall(updateDriver)
    if not ok and firstError == nil then
        firstError = { value = value }
    end

    if firstError ~= nil then
        error(firstError.value, 0)
    end
    return true
end

-- Job creation/delay --------------------------------------------------------

local function newScope(addonName)
    return setmetatable({
        _addonName = addonName,
        _closed = false,
        _activeCount = 0,
        _head = false,
        _tail = false,
        _timerScope = false,
        _shutdownSubscription = false,
    }, SCOPE_METATABLE)
end

local function ensureTimerScope(scope)
    local timerScope = rawget(scope, "_timerScope")
    if timerScope ~= false then
        return timerScope
    end

    timerScope = TimerKit:CreateScope()
    if type(timerScope) ~= "table" then
        error("MoltenCodes SchedulerKit TimerKit returned an invalid scope", 0)
    end

    rawset(scope, "_timerScope", timerScope)
    return timerScope
end

local function newJob(scope, callback, priority, name, interval)
    local job = setmetatable({
        _scope = scope,
        _callback = callback,
        _priority = priority,
        _name = name,
        _interval = interval,
        _state = "pending",
        _errorPresent = false,
        _error = nil,
        _generation = 1,
        _queued = false,
        _coroutine = false,
        _context = false,
        _delayTimer = false,
        _active = true,
        _scopePrev = false,
        _scopeNext = false,
    }, JOB_METATABLE)

    local context = setmetatable({ _job = job }, CONTEXT_METATABLE)
    rawset(job, "_context", context)
    linkActive(scope, job)
    return job
end

local function delayedWakeCallback(timerHandle)
    local job = type(timerHandle) == "table" and rawget(timerHandle, "__schedulerKitJob") or nil
    local generation = type(timerHandle) == "table"
            and rawget(timerHandle, "__schedulerKitGeneration")
        or nil
    if type(timerHandle) == "table" then
        rawset(timerHandle, "__schedulerKitJob", nil)
        rawset(timerHandle, "__schedulerKitGeneration", nil)
    end
    if type(job) ~= "table" or type(generation) ~= "number" then
        return false
    end

    local dispatch = rawget(state, "dispatch")
    local wake = type(dispatch) == "table" and rawget(dispatch, "wakeDelayed") or nil
    if type(wake) ~= "function" then
        error("MoltenCodes SchedulerKit runtime dispatch is corrupted", 0)
    end
    return wake(job, generation)
end

local function armDelay(job, delay)
    local scope = rawget(job, "_scope")
    if rawget(scope, "_closed") == true then
        finishJob(job, "cancelled")
        return false
    end

    local generation = rawget(job, "_generation")
    rawset(job, "_state", "delayed")
    local ok, timerOrError = pcall(function()
        return ensureTimerScope(scope):After(delay, delayedWakeCallback)
    end)

    if not ok then
        failJob(job, timerOrError)
        error(timerOrError, 0)
    end

    if type(timerOrError) ~= "table" then
        local value = "MoltenCodes SchedulerKit TimerKit returned an invalid timer handle"
        failJob(job, value)
        error(value, 0)
    end

    rawset(timerOrError, "__schedulerKitJob", job)
    rawset(timerOrError, "__schedulerKitGeneration", generation)
    rawset(job, "_delayTimer", timerOrError)
    return true
end

local function wakeDelayed(job, generation)
    if rawget(job, "_generation") ~= generation or rawget(job, "_state") ~= "delayed" then
        return false
    end

    rawset(job, "_delayTimer", false)
    rawset(job, "_state", "pending")
    queuePush(job)
    local ok, value = pcall(updateDriver)
    if not ok then
        failJob(job, value)
        return false
    end
    return true
end

local function scheduleInScope(scope, callback, options, methodName)
    validateScope(scope, methodName)
    if rawget(scope, "_closed") == true then
        error(methodName .. " cannot schedule work in a closed scope", 3)
    end
    if type(callback) ~= "function" then
        error(methodName .. " callback must be a function", 3)
    end

    local priority, name = validateOptions(options, methodName)
    local job = newJob(scope, callback, priority, name, false)
    queuePush(job)
    local ok, value = pcall(updateDriver)
    if not ok then
        finishJob(job, "cancelled")
        error(value, 0)
    end
    return job
end

local function scheduleAfterInScope(scope, delay, callback, options, repeating, methodName)
    validateScope(scope, methodName)
    if rawget(scope, "_closed") == true then
        error(methodName .. " cannot schedule work in a closed scope", 3)
    end
    validateFinitePositive(
        delay,
        methodName .. (repeating and " interval" or " delay"),
        not repeating,
        3
    )
    if type(callback) ~= "function" then
        error(methodName .. " callback must be a function", 3)
    end

    local priority, name = validateOptions(options, methodName)
    local interval = repeating and delay or false
    local job = newJob(scope, callback, priority, name, interval)
    armDelay(job, delay)
    return job
end

-- Execution ----------------------------------------------------------------

local function createCoroutine(job)
    local callback = rawget(job, "_callback")
    local context = rawget(job, "_context")
    return coroutine.create(function()
        return callback(context)
    end)
end

local function resumeJob(job)
    if rawget(job, "_state") ~= "pending" then
        return
    end

    rawset(job, "_state", "running")
    rawset(state, "currentJob", job)

    local thread = rawget(job, "_coroutine")
    if thread == false then
        thread = createCoroutine(job)
        rawset(job, "_coroutine", thread)
    end

    local startTime = now()
    local ok, yielded = coroutine.resume(thread)
    local elapsed = now() - startTime
    rawset(state, "currentJob", false)

    if not ok then
        failJob(job, yielded)
        return
    end

    if rawget(job, "_state") == "cancelled" then
        return
    end

    if coroutine.status(thread) == "dead" then
        rawset(job, "_coroutine", false)
        local interval = rawget(job, "_interval")
        if interval ~= false then
            rawset(job, "_generation", rawget(job, "_generation") + 1)
            -- A repeating job is re-armed through TimerKit after its callback
            -- finishes. Host/timer creation failures must not escape the
            -- OnUpdate driver and starve unrelated scheduler work.
            local rearmOk = pcall(armDelay, job, interval)
            if not rearmOk and rawget(job, "_state") ~= "failed" then
                failJob(job, "SchedulerKit failed to re-arm a repeating job")
            end
        else
            finishJob(job, "completed")
        end
        return
    end

    if yielded ~= rawget(state, "yieldToken") then
        failJob(job, "SchedulerKit jobs may yield only through Context:Yield()")
        return
    end

    local threshold = rawget(rawget(state, "config"), "runawayThresholdMs")
    if elapsed > threshold then
        failJob(
            job,
            "SchedulerKit job exceeded the cooperative slice threshold ("
                .. tostring(elapsed)
                .. "ms > "
                .. tostring(threshold)
                .. "ms)"
        )
        return
    end

    rawset(job, "_state", "pending")
    queuePush(job)
end

local function runFrame(_elapsed)
    local config = rawget(state, "config")
    local startTime = now()
    rawset(state, "frameDeadline", startTime + rawget(config, "frameBudgetMs"))

    local resumes = 0
    local maxResumes = rawget(config, "maxResumesPerFrame")
    while resumes < maxResumes do
        if resumes > 0 and now() >= rawget(state, "frameDeadline") then
            break
        end

        local job = nextReadyJob()
        if job == nil then
            break
        end
        resumes = resumes + 1
        resumeJob(job)
    end

    rawset(state, "currentJob", false)
    rawset(state, "frameDeadline", false)
    updateDriver()
end

-- Scope cleanup -------------------------------------------------------------

local function cancelAll(scope)
    validateScope(scope, "SchedulerKit.Scope:CancelAll")
    local firstError = nil
    local job = rawget(scope, "_head")
    while job ~= false do
        local following = rawget(job, "_scopeNext")
        local ok, value = pcall(cancelJob, job)
        if not ok and firstError == nil then
            firstError = { value = value }
        end
        job = following
    end

    if firstError ~= nil then
        error(firstError.value, 0)
    end
    return true
end

local function closeScope(scope)
    validateScope(scope, "SchedulerKit.Scope:Close")
    if rawget(scope, "_closed") == true then
        return false
    end
    rawset(scope, "_closed", true)

    local firstError = nil
    local ok, value = pcall(cancelAll, scope)
    if not ok then
        firstError = { value = value }
    end

    local subscriptionError = disconnectShutdownSubscription(scope)
    if firstError == nil and subscriptionError ~= nil then
        firstError = subscriptionError
    end

    local timerScope = rawget(scope, "_timerScope")
    if timerScope ~= false then
        local timerOk, timerError = pcall(function()
            return timerScope:Close()
        end)
        if not timerOk and firstError == nil then
            firstError = { value = timerError }
        end
    end

    if firstError ~= nil then
        error(firstError.value, 0)
    end
    return true
end

local function createAddonScope(addonName)
    local lifecycle = LifecycleKit:ForAddon(addonName)
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
                error("MoltenCodes SchedulerKit runtime dispatch is corrupted", 0)
            end
            return close(scope)
        end)
    end)
    if not ok then
        rawset(addonScopes, addonName, nil)
        local timerScope = rawget(scope, "_timerScope")
        if timerScope ~= false then
            pcall(function()
                return timerScope:Close()
            end)
        end
        error(subscription, 0)
    end

    rawset(scope, "_shutdownSubscription", subscription)
    return scope
end

-- Context public methods ----------------------------------------------------

local function contextGetJob(self)
    validateContext(self, "SchedulerKit.Context:GetJob")
    return rawget(self, "_job")
end

local function contextIsCancelled(self)
    validateContext(self, "SchedulerKit.Context:IsCancelled")
    return rawget(rawget(self, "_job"), "_state") == "cancelled"
end

local function contextShouldYield(self)
    validateContext(self, "SchedulerKit.Context:ShouldYield")
    local job = rawget(self, "_job")
    local jobState = rawget(job, "_state")
    if
        rawget(state, "currentJob") ~= job
        or (jobState ~= "running" and jobState ~= "cancelled")
    then
        error("SchedulerKit.Context:ShouldYield may only be called while its job is running", 3)
    end
    if jobState == "cancelled" then
        return true
    end

    local deadline = rawget(state, "frameDeadline")
    if type(deadline) ~= "number" then
        return false
    end
    return now() >= deadline
end

local function contextYield(self)
    validateContext(self, "SchedulerKit.Context:Yield")
    local job = rawget(self, "_job")
    local jobState = rawget(job, "_state")
    if
        rawget(state, "currentJob") ~= job
        or (jobState ~= "running" and jobState ~= "cancelled")
    then
        error("SchedulerKit.Context:Yield may only be called while its job is running", 3)
    end
    return coroutine.yield(rawget(state, "yieldToken"))
end

-- Job public methods --------------------------------------------------------

local function jobGetState(self)
    validateJob(self, "SchedulerKit.Job:GetState")
    return rawget(self, "_state")
end

local function jobGetPriority(self)
    validateJob(self, "SchedulerKit.Job:GetPriority")
    return rawget(self, "_priority")
end

local function jobGetScope(self)
    validateJob(self, "SchedulerKit.Job:GetScope")
    return rawget(self, "_scope")
end

local function jobGetName(self)
    validateJob(self, "SchedulerKit.Job:GetName")
    return rawget(self, "_name")
end

local function jobIsPending(self)
    validateJob(self, "SchedulerKit.Job:IsPending")
    local jobState = rawget(self, "_state")
    return jobState == "delayed" or jobState == "pending" or jobState == "running"
end

local function jobIsCancelled(self)
    validateJob(self, "SchedulerKit.Job:IsCancelled")
    return rawget(self, "_state") == "cancelled"
end

local function jobHasError(self)
    validateJob(self, "SchedulerKit.Job:HasError")
    return rawget(self, "_errorPresent") == true
end

local function jobGetError(self)
    validateJob(self, "SchedulerKit.Job:GetError")
    if rawget(self, "_errorPresent") ~= true then
        return nil
    end
    return rawget(self, "_error")
end

local function jobCancel(self)
    return cancelJob(self)
end

-- Scope public methods ------------------------------------------------------

local function scopeSchedule(self, callback, options)
    return scheduleInScope(self, callback, options, "SchedulerKit.Scope:Schedule")
end

local function scopeNextFrame(self, callback, options)
    return scheduleAfterInScope(self, 0, callback, options, false, "SchedulerKit.Scope:NextFrame")
end

local function scopeAfter(self, delay, callback, options)
    return scheduleAfterInScope(self, delay, callback, options, false, "SchedulerKit.Scope:After")
end

local function scopeEvery(self, interval, callback, options)
    return scheduleAfterInScope(self, interval, callback, options, true, "SchedulerKit.Scope:Every")
end

local function scopeCancelAll(self)
    return cancelAll(self)
end

local function scopeClose(self)
    return closeScope(self)
end

local function scopeIsClosed(self)
    validateScope(self, "SchedulerKit.Scope:IsClosed")
    return rawget(self, "_closed") == true
end

local function scopeGetAddonName(self)
    validateScope(self, "SchedulerKit.Scope:GetAddonName")
    return rawget(self, "_addonName")
end

local function scopeGetActiveCount(self)
    validateScope(self, "SchedulerKit.Scope:GetActiveCount")
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

local function packageSchedule(_, callback, options)
    return scheduleInScope(getDefaultScope(), callback, options, "SchedulerKit:Schedule")
end

local function packageNextFrame(_, callback, options)
    return scheduleAfterInScope(
        getDefaultScope(),
        0,
        callback,
        options,
        false,
        "SchedulerKit:NextFrame"
    )
end

local function packageAfter(_, delay, callback, options)
    return scheduleAfterInScope(
        getDefaultScope(),
        delay,
        callback,
        options,
        false,
        "SchedulerKit:After"
    )
end

local function packageEvery(_, interval, callback, options)
    return scheduleAfterInScope(
        getDefaultScope(),
        interval,
        callback,
        options,
        true,
        "SchedulerKit:Every"
    )
end

local function createScope()
    return newScope(nil)
end

local function forAddon(_, addonName)
    validateNonEmptyString(addonName, "SchedulerKit:ForAddon addonName", 3)
    local addonScopes = rawget(state, "addonScopes")
    local scope = rawget(addonScopes, addonName)
    if scope ~= nil then
        return scope
    end
    return createAddonScope(addonName)
end

local function setFrameBudget(_, milliseconds)
    validateFinitePositive(milliseconds, "SchedulerKit:SetFrameBudget milliseconds", false, 3)
    rawset(rawget(state, "config"), "frameBudgetMs", milliseconds)
    return SchedulerKit
end

local function getFrameBudget()
    return rawget(rawget(state, "config"), "frameBudgetMs")
end

local function setRunawayThreshold(_, milliseconds)
    validateFinitePositive(milliseconds, "SchedulerKit:SetRunawayThreshold milliseconds", false, 3)
    rawset(rawget(state, "config"), "runawayThresholdMs", milliseconds)
    return SchedulerKit
end

local function getRunawayThreshold()
    return rawget(rawget(state, "config"), "runawayThresholdMs")
end

local function setMaxResumesPerFrame(_, count)
    validatePositiveInteger(count, "SchedulerKit:SetMaxResumesPerFrame count", 3)
    rawset(rawget(state, "config"), "maxResumesPerFrame", count)
    return SchedulerKit
end

local function getMaxResumesPerFrame()
    return rawget(rawget(state, "config"), "maxResumesPerFrame")
end

local function getActiveCount()
    return rawget(state, "activeCount")
end

-- Commit -------------------------------------------------------------------

rawset(Context, "ShouldYield", contextShouldYield)
rawset(Context, "Yield", contextYield)
rawset(Context, "GetJob", contextGetJob)
rawset(Context, "IsCancelled", contextIsCancelled)

rawset(Job, "GetState", jobGetState)
rawset(Job, "GetPriority", jobGetPriority)
rawset(Job, "GetScope", jobGetScope)
rawset(Job, "GetName", jobGetName)
rawset(Job, "IsPending", jobIsPending)
rawset(Job, "IsCancelled", jobIsCancelled)
rawset(Job, "HasError", jobHasError)
rawset(Job, "GetError", jobGetError)
rawset(Job, "Cancel", jobCancel)

rawset(Scope, "Schedule", scopeSchedule)
rawset(Scope, "NextFrame", scopeNextFrame)
rawset(Scope, "After", scopeAfter)
rawset(Scope, "Every", scopeEvery)
rawset(Scope, "CancelAll", scopeCancelAll)
rawset(Scope, "Close", scopeClose)
rawset(Scope, "IsClosed", scopeIsClosed)
rawset(Scope, "GetAddonName", scopeGetAddonName)
rawset(Scope, "GetActiveCount", scopeGetActiveCount)

rawset(SchedulerKit, "API", API_GENERATION)
rawset(SchedulerKit, "REVISION", IMPLEMENTATION_REVISION)
rawset(SchedulerKit, "Schedule", packageSchedule)
rawset(SchedulerKit, "NextFrame", packageNextFrame)
rawset(SchedulerKit, "After", packageAfter)
rawset(SchedulerKit, "Every", packageEvery)
rawset(SchedulerKit, "CreateScope", createScope)
rawset(SchedulerKit, "ForAddon", forAddon)
rawset(SchedulerKit, "SetFrameBudget", setFrameBudget)
rawset(SchedulerKit, "GetFrameBudget", getFrameBudget)
rawset(SchedulerKit, "SetRunawayThreshold", setRunawayThreshold)
rawset(SchedulerKit, "GetRunawayThreshold", getRunawayThreshold)
rawset(SchedulerKit, "SetMaxResumesPerFrame", setMaxResumesPerFrame)
rawset(SchedulerKit, "GetMaxResumesPerFrame", getMaxResumesPerFrame)
rawset(SchedulerKit, "GetActiveCount", getActiveCount)

local defaultScope = rawget(state, "defaultScope")
if
    defaultScope ~= false
    and (type(defaultScope) ~= "table" or getmetatable(defaultScope) ~= SCOPE_METATABLE)
then
    error("MoltenCodes SchedulerKit package state is corrupted or incomplete", 2)
end

local dispatch = rawget(state, "dispatch")
rawset(dispatch, "runFrame", runFrame)
rawset(dispatch, "wakeDelayed", wakeDelayed)
rawset(dispatch, "closeScope", closeScope)

-- A compatible reload may inherit a frame whose OnUpdate trampoline is already
-- installed. The trampoline resolves dispatch dynamically, so updating the
-- shared dispatch table above is sufficient for live revision handoff.
if rawget(state, "driverEnabled") == true and not hasReadyJobs() then
    updateDriver()
end

if not validatePublicSurface(SchedulerKit) or not validateCurrentState(SchedulerKit) then
    error("MoltenCodes SchedulerKit package state is corrupted or incomplete", 2)
end

return SchedulerKit
