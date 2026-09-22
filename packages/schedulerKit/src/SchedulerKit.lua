-- MoltenCodes SchedulerKit
--
-- Cooperative, frame-budgeted scheduling for World of Warcraft addons.
-- SchedulerKit combines deterministic priority queues, resumable coroutine
-- jobs, cancellation scopes, TimerKit-backed delays, and LifecycleKit cleanup
-- while keeping the WoW OnUpdate/profiling boundary narrow and testable.
--
-- Contents
-- --------
--   Constants ............. package identity, priorities, defaults
--   Public types .......... LuaCATS declarations for the published surface
--   Dependencies .......... Registry, LifecycleKit, TimerKit, WoW globals
--   Validation ............ public-surface and shared-state validation
--   Bootstrap ............. Registry registration and revision migration
--   Generic helpers ....... argument validation, clocks, error reporting
--   Scope ownership ....... intrusive active-job links
--   Ready queues .......... per-priority FIFOs and lane occupancy
--   Driver ................ lazy OnUpdate frame installation
--   Job terminal handling . failure, traceback capture, cancellation
--   Job creation/delay .... scopes, jobs, TimerKit-backed delays
--   Execution ............. cooperative resume and the frame pass
--   Scope cleanup ......... bulk cancellation and terminal close
--   Context methods ....... the handle a running callback receives
--   Job methods ........... the handle a scheduling caller receives
--   Scope methods ......... the handle a scope owner receives
--   Package public API .... the facade published through Registry
--   Commit ................ prototype/facade assignment and self-check

local PACKAGE_NAME = "schedulerKit"
local API_GENERATION = 1
local IMPLEMENTATION_REVISION = 4
local REQUIRED_REGISTRY_API = 2
local REQUIRED_LIFECYCLE_API = 1
local REQUIRED_TIMER_API = 1
local STATE_SCHEMA = 1

local PRIORITY_HIGH = 1
local PRIORITY_NORMAL = 2
local PRIORITY_LOW = 3
local PRIORITY_IDLE = 4
local PRIORITY_COUNT = 4

-- Weighted fair sequence over the three contending lanes. The cursor is
-- preserved between frames so a stream of HIGH work cannot permanently starve
-- NORMAL or LOW. IDLE is deliberately absent: it is background service that
-- runs only when no other lane is ready (see IDLE_STARVATION_RESUMES).
local PRIORITY_SLOTS = {
    PRIORITY_HIGH,
    PRIORITY_HIGH,
    PRIORITY_HIGH,
    PRIORITY_HIGH,
    PRIORITY_NORMAL,
    PRIORITY_NORMAL,
    PRIORITY_LOW,
}

-- Starvation guard for IDLE. After this many consecutive resumes of contending
-- work while IDLE work waits, one IDLE job is promoted ahead of the weighted
-- lanes. The bound keeps "runs only when nothing else is ready" from becoming
-- "never runs" on a permanently busy client, while leaving IDLE well under one
-- percent of service under sustained load.
local IDLE_STARVATION_RESUMES = 256

local DEFAULT_FRAME_BUDGET_MS = 2
local DEFAULT_RUNAWAY_THRESHOLD_MS = 8
local DEFAULT_MAX_RESUMES_PER_FRAME = 1000
local SCHEDULING_OPTION_KEYS = {
    priority = true,
    name = true,
}

-- Public types --------------------------------------------------------------
--
-- SchedulerKit publishes its methods by writing them onto Registry-owned
-- prototype tables, so the editor-facing contract is declared here as LuaCATS
-- classes rather than inferred from those assignments.

---Logical state of a SchedulerKit job.
---@alias SchedulerKitJobState "delayed"|"pending"|"running"|"completed"|"cancelled"|"failed"

---Option table accepted by every scheduling method.
---@class SchedulerKitScheduleOptions
---@field priority integer? One of `SchedulerKit.Priority`; defaults to `NORMAL`.
---@field name string? Optional non-empty diagnostic name.

---The handle a scheduled callback receives while it runs.
---@class SchedulerKitContext
---@field ShouldYield fun(self: SchedulerKitContext): boolean
---@field Yield fun(self: SchedulerKitContext)
---@field GetJob fun(self: SchedulerKitContext): SchedulerKitJob
---@field IsCancelled fun(self: SchedulerKitContext): boolean

---A unit of scheduled work.
---@class SchedulerKitJob
---@field GetState fun(self: SchedulerKitJob): SchedulerKitJobState
---@field GetPriority fun(self: SchedulerKitJob): integer
---@field GetScope fun(self: SchedulerKitJob): SchedulerKitScope
---@field GetName fun(self: SchedulerKitJob): string?
---@field IsPending fun(self: SchedulerKitJob): boolean
---@field IsCancelled fun(self: SchedulerKitJob): boolean
---@field HasError fun(self: SchedulerKitJob): boolean
---@field GetError fun(self: SchedulerKitJob): any
---@field GetErrorTraceback fun(self: SchedulerKitJob): string?
---@field Cancel fun(self: SchedulerKitJob): boolean

---An ownership scope for jobs, closed manually or by addon shutdown.
---@class SchedulerKitScope
---@field Schedule fun(self: SchedulerKitScope, callback: fun(context: SchedulerKitContext), options: SchedulerKitScheduleOptions?): SchedulerKitJob
---@field NextFrame fun(self: SchedulerKitScope, callback: fun(context: SchedulerKitContext), options: SchedulerKitScheduleOptions?): SchedulerKitJob
---@field After fun(self: SchedulerKitScope, delay: number, callback: fun(context: SchedulerKitContext), options: SchedulerKitScheduleOptions?): SchedulerKitJob
---@field Every fun(self: SchedulerKitScope, interval: number, callback: fun(context: SchedulerKitContext), options: SchedulerKitScheduleOptions?): SchedulerKitJob
---@field CancelAll fun(self: SchedulerKitScope): boolean
---@field Close fun(self: SchedulerKitScope): boolean
---@field IsClosed fun(self: SchedulerKitScope): boolean
---@field GetAddonName fun(self: SchedulerKitScope): string?
---@field GetActiveCount fun(self: SchedulerKitScope): integer

---Service-preference lanes.
---@class SchedulerKitPriority
---@field HIGH integer
---@field NORMAL integer
---@field LOW integer
---@field IDLE integer

---The SchedulerKit package facade published through Registry.
---@class SchedulerKitFacade
---@field API integer Public API generation.
---@field REVISION integer Compatible implementation revision.
---@field Priority SchedulerKitPriority
---@field Job SchedulerKitJob Shared job prototype.
---@field Scope SchedulerKitScope Shared scope prototype.
---@field Context SchedulerKitContext Shared context prototype.
---@field Schedule fun(self: SchedulerKitFacade, callback: fun(context: SchedulerKitContext), options: SchedulerKitScheduleOptions?): SchedulerKitJob
---@field NextFrame fun(self: SchedulerKitFacade, callback: fun(context: SchedulerKitContext), options: SchedulerKitScheduleOptions?): SchedulerKitJob
---@field After fun(self: SchedulerKitFacade, delay: number, callback: fun(context: SchedulerKitContext), options: SchedulerKitScheduleOptions?): SchedulerKitJob
---@field Every fun(self: SchedulerKitFacade, interval: number, callback: fun(context: SchedulerKitContext), options: SchedulerKitScheduleOptions?): SchedulerKitJob
---@field CreateScope fun(self: SchedulerKitFacade): SchedulerKitScope
---@field ForAddon fun(self: SchedulerKitFacade, addonName: string): SchedulerKitScope
---@field SetFrameBudget fun(self: SchedulerKitFacade, milliseconds: number): SchedulerKitFacade
---@field GetFrameBudget fun(self: SchedulerKitFacade): number
---@field SetRunawayThreshold fun(self: SchedulerKitFacade, milliseconds: number): SchedulerKitFacade
---@field GetRunawayThreshold fun(self: SchedulerKitFacade): number
---@field SetMaxResumesPerFrame fun(self: SchedulerKitFacade, count: integer): SchedulerKitFacade
---@field GetMaxResumesPerFrame fun(self: SchedulerKitFacade): integer
---@field GetActiveCount fun(self: SchedulerKitFacade): integer

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
-- debugprofilestop reports addon CPU milliseconds and is the clock the frame
-- budget is actually defined against. Every supported client publishes it, but
-- it is resolved defensively so an unusual host falls back to the wall clock
-- instead of failing to load.
-- selene: allow(global_usage)
local nativeDebugProfileStop = rawget(_G, "debugprofilestop")
-- debug.traceback captures a failing job's stack while its coroutine is still
-- inspectable. A host that does not publish the debug library simply reports
-- the bare error value instead.
-- selene: allow(global_usage)
local debugLibrary = rawget(_G, "debug")
local nativeTraceback = type(debugLibrary) == "table" and rawget(debugLibrary, "traceback") or nil
if type(nativeCreateFrame) ~= "function" then
    error("MoltenCodes SchedulerKit requires CreateFrame", 2)
end
if type(nativeGetTimePreciseSec) ~= "function" then
    error("MoltenCodes SchedulerKit requires GetTimePreciseSec", 2)
end
if type(nativeDebugProfileStop) ~= "function" then
    nativeDebugProfileStop = nil
end
if type(nativeTraceback) ~= "function" then
    nativeTraceback = nil
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
        and type(rawget(Job, "GetErrorTraceback")) == "function"
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

    -- Revision 4 bookkeeping. It is checked here rather than in
    -- `validateStateBase` so that inheriting state written by revision 3 during
    -- a live upgrade is still accepted and migrated below.
    if
        type(rawget(currentState, "laneOccupied")) ~= "table"
        or type(rawget(currentState, "occupiedLaneCount")) ~= "number"
        or type(rawget(currentState, "idleGuard")) ~= "number"
    then
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
        laneOccupied = false,
        occupiedLaneCount = 0,
        idleGuard = 0,
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

-- Revision 4 adds lane-occupancy bookkeeping so ready selection can skip empty
-- priority lanes, plus the IDLE starvation guard. Both are derived from the
-- inherited queues rather than assumed, so a live upgrade keeps serving jobs an
-- older revision already queued. Deriving them unconditionally also covers the
-- fresh-state case with one code path.
local inheritedLaneOccupied = rawget(state, "laneOccupied")
if type(inheritedLaneOccupied) ~= "table" then
    inheritedLaneOccupied = {}
    rawset(state, "laneOccupied", inheritedLaneOccupied)
end

local inheritedQueues = rawget(state, "queues")
local inheritedOccupiedLanes = 0
for priority = 1, PRIORITY_COUNT do
    local queue = rawget(inheritedQueues, priority)
    local hasItems = rawget(queue, "tail") >= rawget(queue, "head")
    rawset(inheritedLaneOccupied, priority, hasItems)
    if hasItems then
        inheritedOccupiedLanes = inheritedOccupiedLanes + 1
    end
end
rawset(state, "occupiedLaneCount", inheritedOccupiedLanes)

if type(rawget(state, "idleGuard")) ~= "number" then
    rawset(state, "idleGuard", 0)
end

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

-- Budget and runaway accounting measure **addon CPU milliseconds**, not
-- wall-clock time. A garbage-collection pause, a client hitch, or a stall in
-- unrelated code inflates wall time while the cooperating job consumed none of
-- the frame; charging that to the job made well-behaved work look like a
-- runaway. `debugprofilestop` already reports milliseconds.
local function nowFromProfilingClock()
    local value = nativeDebugProfileStop()
    if type(value) ~= "number" or value ~= value or value == math.huge or value == -math.huge then
        error("MoltenCodes SchedulerKit debugprofilestop returned an invalid value", 0)
    end
    return value
end

-- Documented fallback for a host without the CPU clock: the monotonic precise
-- wall clock, converted to milliseconds.
local function nowFromPreciseClock()
    local value = nativeGetTimePreciseSec()
    if type(value) ~= "number" or value ~= value or value == math.huge or value == -math.huge then
        error("MoltenCodes SchedulerKit GetTimePreciseSec returned an invalid value", 0)
    end
    return value * 1000
end

-- Bound once at load so the hot path does not branch on clock availability.
local now = nativeDebugProfileStop ~= nil and nowFromProfilingClock or nowFromPreciseClock

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

-- Lane occupancy is a conservative "this lane's backing array is non-empty"
-- hint: a lane holding only stale cancelled nodes still counts as occupied, and
-- the flag is cleared the moment a drain resets the lane's indices. A cleared
-- flag therefore always means "definitely nothing here", which is what lets
-- ready selection skip a lane without paying for a queue probe.
local function markLaneOccupied(priority)
    local laneOccupied = rawget(state, "laneOccupied")
    if rawget(laneOccupied, priority) ~= true then
        rawset(laneOccupied, priority, true)
        rawset(state, "occupiedLaneCount", rawget(state, "occupiedLaneCount") + 1)
    end
end

local function markLaneEmpty(priority)
    local laneOccupied = rawget(state, "laneOccupied")
    if rawget(laneOccupied, priority) == true then
        rawset(laneOccupied, priority, false)
        rawset(state, "occupiedLaneCount", rawget(state, "occupiedLaneCount") - 1)
    end
end

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
    markLaneOccupied(priority)
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
        markLaneEmpty(priority)
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
        markLaneEmpty(priority)
    end
    return false
end

local function hasReadyJobs()
    if rawget(state, "occupiedLaneCount") == 0 then
        return false
    end

    local laneOccupied = rawget(state, "laneOccupied")
    for priority = 1, PRIORITY_COUNT do
        if rawget(laneOccupied, priority) == true and queueHasLive(priority) then
            return true
        end
    end
    return false
end

local function nextReadyJob()
    if rawget(state, "occupiedLaneCount") == 0 then
        return nil
    end

    local laneOccupied = rawget(state, "laneOccupied")
    local idleWaiting = rawget(laneOccupied, PRIORITY_IDLE) == true
    if not idleWaiting then
        -- Nothing is being starved, so the guard must not accumulate credit
        -- that a later IDLE job could spend immediately.
        rawset(state, "idleGuard", 0)
    elseif rawget(state, "idleGuard") >= IDLE_STARVATION_RESUMES then
        local promoted = queuePop(PRIORITY_IDLE)
        if promoted ~= nil then
            rawset(state, "idleGuard", 0)
            return promoted
        end
        idleWaiting = false
    end

    local slotCount = #PRIORITY_SLOTS
    local cursor = rawget(state, "priorityCursor")
    for _ = 1, slotCount do
        local priority = PRIORITY_SLOTS[cursor]
        cursor = cursor + 1
        if cursor > slotCount then
            cursor = 1
        end
        rawset(state, "priorityCursor", cursor)

        if rawget(laneOccupied, priority) == true then
            local job = queuePop(priority)
            if job ~= nil then
                if idleWaiting then
                    rawset(state, "idleGuard", rawget(state, "idleGuard") + 1)
                end
                return job
            end
        end
    end

    -- No contending lane is ready, so IDLE work is free to run.
    local job = queuePop(PRIORITY_IDLE)
    if job ~= nil then
        rawset(state, "idleGuard", 0)
    end
    return job
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
        -- Release the scheduler's reference through TimerKit's public user-data
        -- seam. SchedulerKit never writes private fields onto a timer handle.
        delayTimer:SetUserData(nil)
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

---Capture a failing coroutine's stack while the thread is still inspectable.
---Lua 5.1 leaves an errored coroutine's stack in place, so this must run before
---the job's thread reference is dropped.
---@param thread thread
---@param value any Original Lua error object.
---@return string|false traceback `false` when the host has no `debug.traceback`.
local function captureTraceback(thread, value)
    if nativeTraceback == nil then
        return false
    end
    -- `debug.traceback` returns a non-string message unchanged, so a non-string
    -- error object is rendered first to keep the report a readable string.
    local ok, traceback = pcall(nativeTraceback, thread, tostring(value))
    if not ok or type(traceback) ~= "string" then
        return false
    end
    return traceback
end

---Record a failure on the job without reporting it. The caller decides whether
---the failure is re-raised to a direct caller or handed to the host error
---handler, so one failure is never signalled twice.
---@param job SchedulerKitJob
---@param value any
---@param traceback string|false
local function markJobFailed(job, value, traceback)
    rawset(job, "_errorPresent", true)
    rawset(job, "_error", value)
    rawset(job, "_errorTraceback", traceback)
    finishJob(job, "failed")
end

---Record a failure and report it through the host error handler. Used on the
---driver path, where nothing above SchedulerKit can observe a raise.
---@param job SchedulerKitJob
---@param value any
---@param traceback string|false
local function failJob(job, value, traceback)
    markJobFailed(job, value, traceback)
    if traceback ~= false then
        reportError(traceback)
        return
    end
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
        _errorTraceback = false,
        _generation = 1,
        _queued = false,
        _yieldRequested = false,
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

-- One shared wake callback serves every delay, so arming a repeat interval
-- allocates no closure. The job it belongs to travels on the TimerKit handle as
-- public user data.
local function delayedWakeCallback(timerHandle)
    if type(timerHandle) ~= "table" then
        return false
    end

    local job = timerHandle:GetUserData()
    if type(job) ~= "table" then
        return false
    end
    timerHandle:SetUserData(nil)

    -- The armed handle is the job's staleness token: a cancelled or re-armed
    -- job no longer points at this timer, so resolve a generation that cannot
    -- match rather than waking work that has already moved on. Passing the
    -- generation keeps the dispatch contract identical to revision 3, so a
    -- delay armed before a live upgrade still wakes correctly.
    local generation = rawget(job, "_delayTimer") == timerHandle and rawget(job, "_generation")
        or false

    local dispatch = rawget(state, "dispatch")
    local wake = type(dispatch) == "table" and rawget(dispatch, "wakeDelayed") or nil
    if type(wake) ~= "function" then
        error("MoltenCodes SchedulerKit runtime dispatch is corrupted", 0)
    end
    return wake(job, generation)
end

-- `armDelay` is reached both from a direct caller (`SchedulerKit:After`) and
-- from the driver's repeat re-arm. It records the failure on the job and
-- raises; whoever called it decides whether that raise reaches a caller or is
-- converted into a host error report, so one failure is never signalled twice.
local function armDelay(job, delay)
    local scope = rawget(job, "_scope")
    if rawget(scope, "_closed") == true then
        finishJob(job, "cancelled")
        return false
    end

    rawset(job, "_state", "delayed")
    local ok, timerOrError = pcall(function()
        return ensureTimerScope(scope):After(delay, delayedWakeCallback)
    end)

    if not ok then
        markJobFailed(job, timerOrError, false)
        error(timerOrError, 0)
    end

    if type(timerOrError) ~= "table" then
        local value = "MoltenCodes SchedulerKit TimerKit returned an invalid timer handle"
        markJobFailed(job, value, false)
        error(value, 0)
    end

    -- TimerKit never dispatches a timer callback synchronously from `After`, so
    -- the handle cannot fire before both halves of this link are in place.
    rawset(job, "_delayTimer", timerOrError)
    timerOrError:SetUserData(job)
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
        failJob(job, value, false)
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

---Render a job for a diagnostic message. Only reached on failure/overrun
---paths, so the concatenation never touches the normal resume path.
---@param job SchedulerKitJob
---@return string label
local function describeJob(job)
    local name = rawget(job, "_name")
    if type(name) == "string" then
        return '"' .. name .. '"'
    end
    return "(unnamed)"
end

---A job that yielded honoured the cooperative contract, so an over-long slice
---is a scheduling problem rather than a reason to kill it. SchedulerKit lowers
---its priority one lane, so it stops competing with well-behaved work, and
---reports the overrun through the host error handler.
---@param job SchedulerKitJob
---@param elapsed number
---@param threshold number
local function demoteOverrunningJob(job, elapsed, threshold)
    local priority = rawget(job, "_priority")
    if priority < PRIORITY_IDLE then
        priority = priority + 1
        rawset(job, "_priority", priority)
    end

    reportError(
        "SchedulerKit job "
            .. describeJob(job)
            .. " exceeded the cooperative slice threshold ("
            .. tostring(elapsed)
            .. "ms > "
            .. tostring(threshold)
            .. "ms) and now runs at priority "
            .. tostring(priority)
    )
end

---Handle a slice that ended with the callback returning although
---`Context:Yield()` was called and the suspension never reached the scheduler.
---@param job SchedulerKitJob
---@param elapsed number
---@return boolean failed Whether the job was failed and must not continue.
local function handleSwallowedYield(job, elapsed)
    local threshold = rawget(rawget(state, "config"), "runawayThresholdMs")
    local message = "SchedulerKit job "
        .. describeJob(job)
        .. " called Context:Yield() but the suspension never reached the scheduler."
        .. " In Lua 5.1 a coroutine cannot yield across a pcall, xpcall, metamethod,"
        .. " table.sort comparator, or string.gsub callback; the resulting error was"
        .. " swallowed and the callback ran on without surrendering the frame"

    if elapsed > threshold then
        -- The slice both escaped the cooperative contract and outran the
        -- threshold, so it is a real budget violation rather than a mistake
        -- that only needs diagnosing.
        markJobFailed(
            job,
            message .. " (" .. tostring(elapsed) .. "ms > " .. tostring(threshold) .. "ms)",
            false
        )
        reportError(rawget(job, "_error"))
        return true
    end

    reportError(message)
    return false
end

local function resumeJob(job)
    if rawget(job, "_state") ~= "pending" then
        return
    end

    rawset(job, "_state", "running")
    rawset(job, "_yieldRequested", false)
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
        -- Capture the stack before the thread reference is dropped: Lua 5.1
        -- leaves an errored coroutine's frames in place, and after the stack is
        -- gone the report can only name the error value.
        failJob(job, yielded, captureTraceback(thread, yielded))
        return
    end

    if rawget(job, "_state") == "cancelled" then
        return
    end

    if coroutine.status(thread) == "dead" then
        rawset(job, "_coroutine", false)
        if rawget(job, "_yieldRequested") == true and handleSwallowedYield(job, elapsed) then
            return
        end

        local interval = rawget(job, "_interval")
        if interval ~= false then
            rawset(job, "_generation", rawget(job, "_generation") + 1)
            -- A repeating job is re-armed through TimerKit after its callback
            -- finishes. Host/timer creation failures must not escape the
            -- OnUpdate driver and starve unrelated scheduler work, so the raise
            -- `armDelay` owes its caller becomes a host error report here.
            local rearmOk, rearmError = pcall(armDelay, job, interval)
            if not rearmOk then
                if rawget(job, "_state") ~= "failed" then
                    markJobFailed(job, "SchedulerKit failed to re-arm a repeating job", false)
                end
                reportError(rearmError)
            end
        else
            finishJob(job, "completed")
        end
        return
    end

    if yielded ~= rawget(state, "yieldToken") then
        failJob(job, "SchedulerKit jobs may yield only through Context:Yield()", false)
        return
    end

    local threshold = rawget(rawget(state, "config"), "runawayThresholdMs")
    if elapsed > threshold then
        demoteOverrunningJob(job, elapsed, threshold)
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

    -- Record the intent before suspending. Lua 5.1 refuses to yield across a
    -- pcall, metamethod, or other C-call boundary; if the callback swallows
    -- that error and runs on, the driver sees a slice that ended without the
    -- yield it was promised and reports the silent budget violation.
    rawset(job, "_yieldRequested", true)
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

---Return the stack captured at the point a callback error was raised, or `nil`
---when the job did not fail through a callback error or the host publishes no
---`debug.traceback`.
---@param self SchedulerKitJob
---@return string? traceback
local function jobGetErrorTraceback(self)
    validateJob(self, "SchedulerKit.Job:GetErrorTraceback")
    local traceback = rawget(self, "_errorTraceback")
    if traceback == false then
        return nil
    end
    return traceback
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
rawset(Job, "GetErrorTraceback", jobGetErrorTraceback)
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
