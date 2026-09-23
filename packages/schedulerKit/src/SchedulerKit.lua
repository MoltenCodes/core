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
--   Coalescing family ..... Debounce, Coalesce, Watch and lanes (one design)
--   Scope cleanup ......... bulk cancellation and terminal close
--   Context methods ....... the handle a running callback receives
--   Job methods ........... the handle a scheduling caller receives
--   Scope methods ......... the handle a scope owner receives
--   Package public API .... the facade published through Registry
--   Commit ................ prototype/facade assignment and self-check

local PACKAGE_NAME = "schedulerKit"
local API_GENERATION = 1
local IMPLEMENTATION_REVISION = 8
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

-- The coalescing family (Debounce, Coalesce, Watch, lanes). Every bound below
-- is documented in docs/API.md under "Coalescing and lanes".

-- A debounce handle keeps the arguments of its last call in a reused slot of
-- this many values, so recording a call never allocates.
local MAX_DEBOUNCE_ARGUMENTS = 8
local DEFAULT_COALESCE_MAX_KEYS = 256
-- Watchers sharing one interval share one ticker; both the watchers per
-- interval and the number of distinct intervals are bounded.
local MAX_WATCHERS_PER_INTERVAL = 128
local MAX_WATCH_INTERVALS = 32
local MAX_LANES = 32
local DEFAULT_LANE_MAX_IN_FLIGHT = 1
local DEFAULT_LANE_MAX_QUEUED = 64
local DEFAULT_RETRY_MULTIPLIER = 2
-- A timer that wakes this close to its due time counts as due, so host timer
-- rounding cannot turn one wake into a chain of near-zero re-arms.
local DUE_TOLERANCE_SECONDS = 0.001

local DEBOUNCE_OPTION_KEYS = { leading = true, maxWaitSeconds = true, lane = true }
local COALESCE_OPTION_KEYS = { maxKeys = true, lane = true }
local WATCH_OPTION_KEYS = { everyTick = true }
local LANE_OPTION_KEYS = {
    maxInFlight = true,
    minIntervalSeconds = true,
    retry = true,
    maxQueued = true,
}
local RETRY_OPTION_KEYS = {
    attempts = true,
    backoffSeconds = true,
    multiplier = true,
    maxBackoffSeconds = true,
}
local SUBMIT_OPTION_KEYS = { priority = true, name = true, scope = true }

-- Public types --------------------------------------------------------------
--
-- SchedulerKit publishes its methods by writing them onto Registry-owned
-- prototype tables, so the editor-facing contract is declared here as LuaCATS
-- classes rather than inferred from those assignments.

---Logical state of a SchedulerKit job.
---@alias SchedulerKit.JobState "delayed"|"pending"|"running"|"completed"|"cancelled"|"failed"

---A scheduled callback. It receives the context handle for its own job.
---@alias SchedulerKit.Callback fun(context: SchedulerKit.Context)

---An error object wrapped so that `nil` and `false` stay representable.
---@class SchedulerKit.ErrorRecord
---@field value any the original Lua error object

---One priority lane's FIFO. `head > tail` means the lane is drained.
---@class SchedulerKit.Queue
---@field items table<integer, SchedulerKit.Job>
---@field head integer
---@field tail integer

---Option table accepted by every scheduling method.
---@class SchedulerKit.ScheduleOptions
---@field priority integer? One of `SchedulerKit.Priority`; defaults to `NORMAL`.
---@field name string? Optional non-empty diagnostic name.

---The handle a scheduled callback receives while it runs.
---@class SchedulerKit.Context
---@field ShouldYield fun(self: SchedulerKit.Context): boolean
---@field Yield fun(self: SchedulerKit.Context)
---@field GetJob fun(self: SchedulerKit.Context): SchedulerKit.Job
---@field IsCancelled fun(self: SchedulerKit.Context): boolean

---A unit of scheduled work.
---@class SchedulerKit.Job
---@field GetState fun(self: SchedulerKit.Job): SchedulerKit.JobState
---@field GetPriority fun(self: SchedulerKit.Job): integer
---@field GetScope fun(self: SchedulerKit.Job): SchedulerKit.Scope
---@field GetName fun(self: SchedulerKit.Job): string?
---@field IsPending fun(self: SchedulerKit.Job): boolean
---@field IsCancelled fun(self: SchedulerKit.Job): boolean
---@field HasError fun(self: SchedulerKit.Job): boolean
---@field GetError fun(self: SchedulerKit.Job): any
---@field GetErrorTraceback fun(self: SchedulerKit.Job): string?
---@field Cancel fun(self: SchedulerKit.Job): boolean

---An ownership scope for jobs, closed manually or by addon shutdown.
---@class SchedulerKit.Scope
---@field Schedule fun(self: SchedulerKit.Scope, callback: SchedulerKit.Callback, options: SchedulerKit.ScheduleOptions?): SchedulerKit.Job
---@field NextFrame fun(self: SchedulerKit.Scope, callback: SchedulerKit.Callback, options: SchedulerKit.ScheduleOptions?): SchedulerKit.Job
---@field After fun(self: SchedulerKit.Scope, delay: number, callback: SchedulerKit.Callback, options: SchedulerKit.ScheduleOptions?): SchedulerKit.Job
---@field Every fun(self: SchedulerKit.Scope, interval: number, callback: SchedulerKit.Callback, options: SchedulerKit.ScheduleOptions?): SchedulerKit.Job
---@field CancelAll fun(self: SchedulerKit.Scope): boolean
---@field Close fun(self: SchedulerKit.Scope): boolean
---@field IsClosed fun(self: SchedulerKit.Scope): boolean
---@field GetAddonName fun(self: SchedulerKit.Scope): string?
---@field GetActiveCount fun(self: SchedulerKit.Scope): integer
---@field Debounce fun(self: SchedulerKit.Scope, callback: function, delaySeconds: number, options: SchedulerKit.DebounceOptions?): SchedulerKit.DebounceHandle
---@field Coalesce fun(self: SchedulerKit.Scope, callback: SchedulerKit.CoalesceCallback, intervalSeconds: number, options: SchedulerKit.CoalesceOptions?): SchedulerKit.CoalesceHandle
---@field Watch fun(self: SchedulerKit.Scope, predicate: fun(): any, intervalSeconds: number, callback: SchedulerKit.WatchCallback, options: SchedulerKit.WatchOptions?): SchedulerKit.WatchHandle

---Options accepted by `Debounce`.
---@class SchedulerKit.DebounceOptions
---@field leading boolean? Also fire on the first call of a burst.
---@field maxWaitSeconds number? Fire at most this long after the first call of a burst; at least `delaySeconds`.
---@field lane SchedulerKit.Lane? Run every fire as a job in this lane instead of synchronously.

---Options accepted by `Coalesce`.
---@class SchedulerKit.CoalesceOptions
---@field maxKeys integer? Distinct keys one interval may collect; defaults to 256.
---@field lane SchedulerKit.Lane? Run every delivery as a job in this lane instead of synchronously.

---Options accepted by `Watch`.
---@class SchedulerKit.WatchOptions
---@field everyTick boolean? Call back on every tick, not only when the result changes.

---Retry policy of a lane.
---@class SchedulerKit.RetryOptions
---@field attempts integer? Retries after the first attempt; defaults to `0`.
---@field backoffSeconds number? Delay before the first retry; defaults to `0`.
---@field multiplier number? Growth factor of each later delay, at least `1`; defaults to `2`.
---@field maxBackoffSeconds number? Ceiling on one delay; unbounded when omitted.

---Options accepted by `Lane`.
---@class SchedulerKit.LaneOptions
---@field maxInFlight integer? Submissions admitted and not yet finished, including those waiting out a retry backoff; defaults to `1`.
---@field minIntervalSeconds number? Minimum time between two starts; defaults to `0`.
---@field retry SchedulerKit.RetryOptions?
---@field maxQueued integer? Submissions waiting at once; defaults to `64`.

---Options accepted by `Lane:Submit`.
---@class SchedulerKit.SubmitOptions
---@field priority integer? One of `SchedulerKit.Priority`; defaults to `NORMAL`.
---@field name string? Optional non-empty diagnostic name.
---@field scope SchedulerKit.Scope? Owning scope; defaults to the package-level scope.

---Receives the keys a coalesce handle collected. The table is reused and must
---not be retained: it is cleared as soon as the callback returns, or, for a
---delivery through a lane, once the lane job reaches a terminal state.
---@alias SchedulerKit.CoalesceCallback fun(set: table<any, any>)

---Receives a watched predicate's result and the result of the previous tick.
---@alias SchedulerKit.WatchCallback fun(value: any, previous: any)

---A callable handle that runs its callback once a burst of calls goes quiet.
---Calling it records the arguments and returns `true`, or `false` once closed.
---@class SchedulerKit.DebounceHandle
---@overload fun(...: any): boolean
---@field Cancel fun(self: SchedulerKit.DebounceHandle): boolean
---@field Flush fun(self: SchedulerKit.DebounceHandle): boolean, ("deferred"|"dropped")?
---@field IsPending fun(self: SchedulerKit.DebounceHandle): boolean
---@field Close fun(self: SchedulerKit.DebounceHandle): boolean
---@field IsClosed fun(self: SchedulerKit.DebounceHandle): boolean

---Counters of one coalesce handle. The table is reused by every call.
---@class SchedulerKit.CoalesceStats
---@field keys integer Keys collected and not yet delivered.
---@field refused integer New keys refused because `maxKeys` was reached.
---@field delivered integer Sets handed to the callback or to the lane.
---@field deferred integer Deliveries postponed one interval because the lane was busy or full.
---@field dropped integer Sets discarded because the lane was closed.

---A callable handle that collects keys and delivers them at most once per
---interval. Calling it with `(key, value)` returns whether the key was kept.
---@class SchedulerKit.CoalesceHandle
---@overload fun(key: any, value: any?): boolean
---@field Cancel fun(self: SchedulerKit.CoalesceHandle): boolean
---@field Flush fun(self: SchedulerKit.CoalesceHandle): boolean, ("deferred"|"dropped")?
---@field IsPending fun(self: SchedulerKit.CoalesceHandle): boolean
---@field GetStats fun(self: SchedulerKit.CoalesceHandle): SchedulerKit.CoalesceStats
---@field Close fun(self: SchedulerKit.CoalesceHandle): boolean
---@field IsClosed fun(self: SchedulerKit.CoalesceHandle): boolean

---One predicate polled on a ticker shared by every watch of its interval.
---@class SchedulerKit.WatchHandle
---@field Cancel fun(self: SchedulerKit.WatchHandle): boolean
---@field IsActive fun(self: SchedulerKit.WatchHandle): boolean

---Counters of one lane. The table is reused by every call.
---@class SchedulerKit.LaneStats
---@field queued integer Submissions waiting for the lane.
---@field inFlight integer Submissions admitted and not yet finished.
---@field completed integer
---@field failed integer
---@field retried integer Attempts that raised and were scheduled again.
---@field cancelled integer
---@field refused integer Submissions refused because the lane was full or closed.

---A named, shared ration of one scarce resource.
---@class SchedulerKit.Lane
---@field Submit fun(self: SchedulerKit.Lane, callback: SchedulerKit.Callback, options: SchedulerKit.SubmitOptions?): SchedulerKit.Job?, string?
---@field GetStats fun(self: SchedulerKit.Lane): SchedulerKit.LaneStats
---@field GetName fun(self: SchedulerKit.Lane): string
---@field Close fun(self: SchedulerKit.Lane): boolean
---@field IsClosed fun(self: SchedulerKit.Lane): boolean

---Service-preference lanes.
---@class SchedulerKit.Priority
---@field HIGH integer
---@field NORMAL integer
---@field LOW integer
---@field IDLE integer

---The SchedulerKit package facade published through Registry.
---@class SchedulerKit
---@field API integer Public API generation.
---@field REVISION integer Compatible implementation revision.
---@field Priority SchedulerKit.Priority
---@field Job SchedulerKit.Job Shared job prototype.
---@field Scope SchedulerKit.Scope Shared scope prototype.
---@field Context SchedulerKit.Context Shared context prototype.
---@field Schedule fun(self: SchedulerKit, callback: SchedulerKit.Callback, options: SchedulerKit.ScheduleOptions?): SchedulerKit.Job
---@field NextFrame fun(self: SchedulerKit, callback: SchedulerKit.Callback, options: SchedulerKit.ScheduleOptions?): SchedulerKit.Job
---@field After fun(self: SchedulerKit, delay: number, callback: SchedulerKit.Callback, options: SchedulerKit.ScheduleOptions?): SchedulerKit.Job
---@field Every fun(self: SchedulerKit, interval: number, callback: SchedulerKit.Callback, options: SchedulerKit.ScheduleOptions?): SchedulerKit.Job
---@field CreateScope fun(self: SchedulerKit): SchedulerKit.Scope
---@field ForAddon fun(self: SchedulerKit, addonName: string): SchedulerKit.Scope
---@field SetFrameBudget fun(self: SchedulerKit, milliseconds: number): SchedulerKit
---@field GetFrameBudget fun(self: SchedulerKit): number
---@field SetRunawayThreshold fun(self: SchedulerKit, milliseconds: number): SchedulerKit
---@field GetRunawayThreshold fun(self: SchedulerKit): number
---@field SetMaxResumesPerFrame fun(self: SchedulerKit, count: integer): SchedulerKit
---@field GetMaxResumesPerFrame fun(self: SchedulerKit): integer
---@field GetActiveCount fun(self: SchedulerKit): integer
---@field Debounce fun(self: SchedulerKit, callback: function, delaySeconds: number, options: SchedulerKit.DebounceOptions?): SchedulerKit.DebounceHandle
---@field Coalesce fun(self: SchedulerKit, callback: SchedulerKit.CoalesceCallback, intervalSeconds: number, options: SchedulerKit.CoalesceOptions?): SchedulerKit.CoalesceHandle
---@field Watch fun(self: SchedulerKit, predicate: fun(): any, intervalSeconds: number, callback: SchedulerKit.WatchCallback, options: SchedulerKit.WatchOptions?): SchedulerKit.WatchHandle
---@field Lane fun(self: SchedulerKit, name: string, options: SchedulerKit.LaneOptions?): SchedulerKit.Lane

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
    error("MoltenCodes SchedulerKit requires Registry API 2 to be loaded first", 2)
end

local bootstrapPackage = rawget(Registry, "Bootstrap")
local getPackage = rawget(Registry, "Get")
if type(bootstrapPackage) ~= "function" or type(getPackage) ~= "function" then
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

---Whether `implementation` exposes the complete SchedulerKit API 1 surface.
---@param implementation any shared package table handed back by Registry
---@return boolean
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
        and type(rawget(implementation, "Debounce")) == "function"
        and type(rawget(implementation, "Coalesce")) == "function"
        and type(rawget(implementation, "Watch")) == "function"
        and type(rawget(implementation, "Lane")) == "function"
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
        and type(rawget(Scope, "Debounce")) == "function"
        and type(rawget(Scope, "Coalesce")) == "function"
        and type(rawget(Scope, "Watch")) == "function"
        and type(rawget(Context, "ShouldYield")) == "function"
        and type(rawget(Context, "Yield")) == "function"
        and type(rawget(Context, "GetJob")) == "function"
        and type(rawget(Context, "IsCancelled")) == "function"
end

---Whether `currentState` has the fields every API 1 revision shares.
---@param currentState any
---@return boolean
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

---Whether `implementation` carries package state of this revision's schema.
---@param implementation table
---@return boolean
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

    -- Revision 7 bookkeeping for the coalescing family, checked here for the
    -- same reason: a revision-6 state is migrated rather than refused.
    if
        type(rawget(currentState, "lanes")) ~= "table"
        or type(rawget(currentState, "laneCount")) ~= "number"
        or type(rawget(currentState, "watchGroups")) ~= "table"
        or type(rawget(currentState, "watchGroupCount")) ~= "number"
        or type(rawget(currentState, "familyMetatables")) ~= "table"
        or type(rawget(currentState, "familyPrototypes")) ~= "table"
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

-- `Registry:Bootstrap` owns the reconciliation every embedded package repeats:
-- look the package up, refuse to reinterpret state owned by a newer revision,
-- and register this one. What stays here is what only SchedulerKit can answer.
local SchedulerKit, previousRevision, selected = bootstrapPackage(Registry, {
    package = PACKAGE_NAME,
    api = API_GENERATION,
    revision = IMPLEMENTATION_REVISION,
    label = "MoltenCodes SchedulerKit",
    validatePublicSurface = validatePublicSurface,
    validateState = validateCurrentState,
})

if SchedulerKit == nil then
    -- Equal or newer compatible revision already owns the shared package table.
    return selected
end

local Job = rawget(SchedulerKit, "Job")
local Scope = rawget(SchedulerKit, "Scope")
local Context = rawget(SchedulerKit, "Context")
local Priority = rawget(SchedulerKit, "Priority")
local state = rawget(SchedulerKit, "_state")

---Build one empty priority lane.
---@return SchedulerKit.Queue
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
        frameReading = false,
        familyTimerScope = false,
        lanes = {},
        laneCount = 0,
        watchGroups = {},
        watchGroupCount = 0,
        familyMetatables = {},
        familyPrototypes = {},
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

-- Revision 6 makes frame accounting monotonic, which needs the previous clock
-- reading beside the deadline. State written by an older revision carries no
-- such field. It is seeded rather than derived, and `frameDeadline` is left
-- exactly as inherited: a copy loading while the older one drives a frame must
-- not have that frame's deadline pulled out from under it.
if type(rawget(state, "frameReading")) ~= "number" then
    rawset(state, "frameReading", false)
end

-- Revision 7 adds the coalescing family: the shared lane registry, the watch
-- interval groups, the package-internal TimerKit scope their tickers and lane
-- timers live in, and one metatable plus one method table per handle kind.
-- Handle receivers are validated by metatable identity, so the metatables
-- live in shared state and survive later in-place upgrades. An older state
-- has none of this; every field is seeded independently so a partially
-- written state is completed rather than refused.
local FAMILY_KINDS = { "debounce", "coalesce", "watch", "lane" }
if type(rawget(state, "lanes")) ~= "table" then
    rawset(state, "lanes", {})
end
if type(rawget(state, "laneCount")) ~= "number" then
    rawset(state, "laneCount", 0)
end
if type(rawget(state, "watchGroups")) ~= "table" then
    rawset(state, "watchGroups", {})
end
if type(rawget(state, "watchGroupCount")) ~= "number" then
    rawset(state, "watchGroupCount", 0)
end
if rawget(state, "familyTimerScope") == nil then
    rawset(state, "familyTimerScope", false)
end
if type(rawget(state, "familyMetatables")) ~= "table" then
    rawset(state, "familyMetatables", {})
end
if type(rawget(state, "familyPrototypes")) ~= "table" then
    rawset(state, "familyPrototypes", {})
end
for index = 1, #FAMILY_KINDS do
    local kind = FAMILY_KINDS[index]
    local metatables = rawget(state, "familyMetatables")
    local prototypes = rawget(state, "familyPrototypes")
    if type(rawget(metatables, kind)) ~= "table" then
        rawset(metatables, kind, {})
    end
    if type(rawget(prototypes, kind)) ~= "table" then
        rawset(prototypes, kind, {})
    end
    rawset(rawget(metatables, kind), "__index", rawget(prototypes, kind))
end

local JOB_METATABLE = rawget(state, "jobMetatable")
local SCOPE_METATABLE = rawget(state, "scopeMetatable")
local CONTEXT_METATABLE = rawget(state, "contextMetatable")
rawset(JOB_METATABLE, "__index", Job)
rawset(SCOPE_METATABLE, "__index", Scope)
rawset(CONTEXT_METATABLE, "__index", Context)

-- Generic helpers -----------------------------------------------------------

---@param value any
---@param label string argument description, used in the argument error
---@param level integer? stack level the failure is reported at; defaults to `3`
local function validateNonEmptyString(value, label, level)
    if type(value) ~= "string" or value == "" then
        error(label .. " must be a non-empty string", level or 3)
    end
end

---@param value any
---@param label string argument description, used in the argument error
---@param allowZero boolean whether zero is accepted
---@param level integer? stack level the failure is reported at; defaults to `3`
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

---@param value any
---@param label string argument description, used in the argument error
---@param level integer? stack level the failure is reported at; defaults to `3`
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

---@param priority any one of `SchedulerKit.Priority`, or `nil` for `NORMAL`
---@param label string argument description, used in the argument error
---@param level integer? stack level the failure is reported at; defaults to `3`
---@return integer priority
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

---Validate one scheduling option table and apply its defaults.
---@param options any
---@param methodName string public method name, used in the argument errors
---@return integer priority
---@return string|nil name
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
---Current addon CPU milliseconds.
---@return number milliseconds
local function nowFromProfilingClock()
    local value = nativeDebugProfileStop()
    if type(value) ~= "number" or value ~= value or value == math.huge or value == -math.huge then
        error("MoltenCodes SchedulerKit debugprofilestop returned an invalid value", 0)
    end
    return value
end

-- Documented fallback for a host without the CPU clock: the monotonic precise
-- wall clock, converted to milliseconds.
---Current monotonic wall-clock milliseconds.
---@return number milliseconds
local function nowFromPreciseClock()
    local value = nativeGetTimePreciseSec()
    if type(value) ~= "number" or value ~= value or value == math.huge or value == -math.huge then
        error("MoltenCodes SchedulerKit GetTimePreciseSec returned an invalid value", 0)
    end
    return value * 1000
end

-- Bound once at load so the hot path does not branch on clock availability.
local now = nativeDebugProfileStop ~= nil and nowFromProfilingClock or nowFromPreciseClock

-- `debugprofilestop` reports one process-wide timer, and `debugprofilestart()`
-- zeroes it for everybody. Any addon in the session can therefore make the
-- clock this scheduler is measuring against jump backwards in the middle of a
-- frame. A deadline computed once from the frame's start does not survive that:
-- after a reset every later reading is smaller than the deadline, the budget
-- check never fires, and the frame runs to the resume cap instead of to the
-- budget — a thousand resumes against a two-millisecond budget.
--
-- Accounting is therefore kept monotonic. Only forward movement since the
-- previous reading is spent, and a backwards jump re-anchors the deadline to
-- the new reading while keeping the budget the frame has left. The frame is
-- shortened rather than extended, nothing already spent is refunded, and a
-- resetting neighbour can cost this scheduler at most the readings it
-- straddles. A large forward jump is charged as ordinary spending and simply
-- ends the frame early, which is the safe direction: the budget exists to stop
-- the scheduler from overrunning a frame, not to guarantee it a share of one.

---Re-anchor the frame deadline against a clock that may have been reset, and
---report whether the frame's CPU budget is spent.
---@return boolean exhausted `false` whenever no frame is being driven.
local function frameBudgetExhausted()
    local deadline = rawget(state, "frameDeadline")
    if type(deadline) ~= "number" then
        return false
    end

    local reading = now()
    local previous = rawget(state, "frameReading")
    if type(previous) ~= "number" then
        -- No reference point: state inherited from a revision that did not keep
        -- one. Adopt this reading and charge the frame from here.
        rawset(state, "frameReading", reading)
        return false
    end

    if reading < previous then
        -- `deadline - previous` is the budget left at the previous reading.
        -- Carry that remainder across the reset instead of the absolute value.
        deadline = reading + (deadline - previous)
        rawset(state, "frameDeadline", deadline)
    end

    rawset(state, "frameReading", reading)
    return reading >= deadline
end

---Milliseconds of addon CPU time between `startTime` and now.
---
---When the clock was restarted while the slice ran, the finishing reading is
---smaller than the starting one and the raw subtraction is negative — a slice
---that took a hundred milliseconds would be measured as free and could never be
---recognised as a runaway, while the nonsense figure still reached the
---diagnostic that names it.
---
---The finishing reading is itself the answer in that case: the clock counts up
---from wherever it was restarted, so it already holds the part of the slice
---that followed the restart. That is a lower bound on the slice — the part
---before the restart is unknowable — and a lower bound is the right side to err
---on, because it can only make this measurement miss a runaway, never invent
---one. The frame budget needs no such correction: its next reading continues
---from the restart on its own, so only the sliver either side of the jump goes
---uncharged there.
---@param startTime number reading taken before the slice ran
---@return number milliseconds
local function elapsedSince(startTime)
    local finishTime = now()
    if finishTime < startTime then
        return finishTime > 0 and finishTime or 0
    end
    return finishTime - startTime
end

---Hand a diagnostic to the host error handler, best-effort.
---@param value any
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

---@param scope any receiver the public method was called on
---@param methodName string public method name, used in the argument error
local function validateScope(scope, methodName)
    if type(scope) ~= "table" or getmetatable(scope) ~= SCOPE_METATABLE then
        error(methodName .. " must be called on a SchedulerKit scope", 3)
    end
end

---@param job any receiver the public method was called on
---@param methodName string public method name, used in the argument error
local function validateJob(job, methodName)
    if type(job) ~= "table" or getmetatable(job) ~= JOB_METATABLE then
        error(methodName .. " must be called on a SchedulerKit job", 3)
    end
end

---@param context any receiver the public method was called on
---@param methodName string public method name, used in the argument error
local function validateContext(context, methodName)
    if type(context) ~= "table" or getmetatable(context) ~= CONTEXT_METATABLE then
        error(methodName .. " must be called on a SchedulerKit context", 3)
    end
end

---Whether a job in this state can never be scheduled again.
---@param jobState SchedulerKit.JobState
---@return boolean
local function isTerminalJobState(jobState)
    return jobState == "completed" or jobState == "cancelled" or jobState == "failed"
end

-- Scope ownership -----------------------------------------------------------

---Append `job` to its scope's intrusive active list.
---@param scope SchedulerKit.Scope
---@param job SchedulerKit.Job
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

---Remove `job` from its scope's intrusive active list, once.
---@param scope SchedulerKit.Scope
---@param job SchedulerKit.Job
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

---Drop the LifecycleKit shutdown subscription an addon scope holds.
---@param scope SchedulerKit.Scope
---@return SchedulerKit.ErrorRecord|nil errorRecord
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
---@param priority integer
local function markLaneOccupied(priority)
    local laneOccupied = rawget(state, "laneOccupied")
    if rawget(laneOccupied, priority) ~= true then
        rawset(laneOccupied, priority, true)
        rawset(state, "occupiedLaneCount", rawget(state, "occupiedLaneCount") + 1)
    end
end

---@param priority integer
local function markLaneEmpty(priority)
    local laneOccupied = rawget(state, "laneOccupied")
    if rawget(laneOccupied, priority) == true then
        rawset(laneOccupied, priority, false)
        rawset(state, "occupiedLaneCount", rawget(state, "occupiedLaneCount") - 1)
    end
end

---Enqueue `job` in its own priority lane, at most once.
---@param job SchedulerKit.Job
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

---Take the next live job from one lane, discarding stale entries.
---@param priority integer
---@return SchedulerKit.Job|nil
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

---Whether one lane still holds a job that can run, trimming stale entries.
---@param priority integer
---@return boolean
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

---Whether any lane holds work, which is what decides if the driver runs.
---@return boolean
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

---Select the next job to resume under the weighted lane sequence.
---
---`IDLE` is served only when no contending lane is ready, except that the
---starvation guard promotes one `IDLE` job after enough contending resumes.
---@return SchedulerKit.Job|nil
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

---Return the driver Frame, creating it and its trampoline on demand.
---@return WowFrame
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

---Install or remove the `OnUpdate` handler to match whether work is ready.
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

-- The coalescing family builds on the job machinery below, and the job
-- machinery has to tell the family when a lane job ends or raises. These are
-- assigned in the "Coalescing family" section.
local laneJobFinished
local retryLaneJob
local cancelFamilyMembers
local closeFamilyMembers

---Release the TimerKit handle a delayed job is holding, if any.
---@param job SchedulerKit.Job
---@return TimerKit.Timer|false delayTimer
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

---Move `job` into a terminal state and release everything it retained.
---@param job SchedulerKit.Job
---@param terminalState "completed"|"cancelled"|"failed"
local function finishJob(job, terminalState)
    rawset(job, "_state", terminalState)
    rawset(job, "_queued", false)
    rawset(job, "_coroutine", false)
    rawset(job, "_callback", false)
    rawset(job, "_context", false)
    rawset(job, "_delayTimer", false)
    local scope = rawget(job, "_scope")
    unlinkActive(scope, job)
    -- Only a lane submission carries a lane; ordinary jobs pay one read.
    local lane = rawget(job, "_lane")
    if lane ~= nil and lane ~= false then
        laneJobFinished(job, lane, terminalState)
    end
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
---@param job SchedulerKit.Job
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
---@param job SchedulerKit.Job
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

---Cancel `job`, cancelling its pending delay and updating the driver.
---@param job SchedulerKit.Job
---@return boolean cancelled `false` when the job was already terminal.
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

---Build one open scope. `addonName` is `nil` for a manually owned scope.
---@param addonName string|nil
---@return SchedulerKit.Scope
local function newScope(addonName)
    return setmetatable({
        _addonName = addonName,
        _closed = false,
        _activeCount = 0,
        _head = false,
        _tail = false,
        _timerScope = false,
        _shutdownSubscription = false,
        _familyHead = false,
        _familyTail = false,
    }, SCOPE_METATABLE)
end

---Return the TimerKit scope backing this scope's delays, creating it lazily.
---@param scope SchedulerKit.Scope
---@return TimerKit.Scope
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

---Build one job and its context handle, and link it into `scope`.
---@param scope SchedulerKit.Scope
---@param callback SchedulerKit.Callback
---@param priority integer
---@param name string|nil
---@param interval number|false repeat interval, or `false` for a one-shot job
---@return SchedulerKit.Job
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
---Shared TimerKit callback that wakes whichever job armed the handle.
---@param timerHandle TimerKit.Timer
---@return boolean woken
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
---Put `job` to sleep for `delay` seconds through TimerKit.
---@param job SchedulerKit.Job
---@param delay number
---@return boolean armed `false` when the owning scope had already closed.
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

---Return a delayed job to the ready queues, ignoring stale generations.
---@param job SchedulerKit.Job
---@param generation integer|false generation the expired handle was armed for
---@return boolean woken
local function wakeDelayed(job, generation)
    if rawget(job, "_generation") ~= generation or rawget(job, "_state") ~= "delayed" then
        return false
    end

    rawset(job, "_delayTimer", false)
    rawset(job, "_state", "pending")
    -- An admitted lane job waking from its retry backoff starts again, so the
    -- lane's minimum interval is measured from here.
    local lane = rawget(job, "_lane")
    if lane ~= nil and lane ~= false and rawget(job, "_laneAdmitted") == true then
        rawset(lane, "_lastStart", nowFromPreciseClock() / 1000)
    end
    queuePush(job)
    local ok, value = pcall(updateDriver)
    if not ok then
        failJob(job, value, false)
        return false
    end
    return true
end

---Validate and queue one immediately eligible job.
---@param scope SchedulerKit.Scope
---@param callback any
---@param options SchedulerKit.ScheduleOptions|nil
---@param methodName string public method name, used in the argument errors
---@return SchedulerKit.Job
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

---Validate and arm one delayed or repeating job.
---@param scope SchedulerKit.Scope
---@param delay any seconds to wait; the repeat interval when `repeating`
---@param callback any
---@param options SchedulerKit.ScheduleOptions|nil
---@param repeating boolean
---@param methodName string public method name, used in the argument errors
---@return SchedulerKit.Job
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

---Return SchedulerKit's internal manual scope, replacing it once it is closed.
---@return SchedulerKit.Scope
local function getDefaultScope()
    local scope = rawget(state, "defaultScope")
    if scope == false or rawget(scope, "_closed") == true then
        scope = newScope(nil)
        rawset(state, "defaultScope", scope)
    end
    return scope
end

-- Execution ----------------------------------------------------------------

---Wrap a job's callback in the coroutine its slices are resumed through.
---@param job SchedulerKit.Job
---@return thread
local function createCoroutine(job)
    local callback = rawget(job, "_callback")
    local context = rawget(job, "_context")
    return coroutine.create(function()
        return callback(context)
    end)
end

---Render a job for a diagnostic message. Only reached on failure/overrun
---paths, so the concatenation never touches the normal resume path.
---@param job SchedulerKit.Job
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
---@param job SchedulerKit.Job
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
---@param job SchedulerKit.Job
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

---Run one slice of `job`, then requeue, re-arm, finish or fail it.
---@param job SchedulerKit.Job
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
    local elapsed = elapsedSince(startTime)
    rawset(state, "currentJob", false)

    if not ok then
        -- A lane submission with attempts left is re-armed after its backoff
        -- instead of failing; see "Coalescing family".
        local lane = rawget(job, "_lane")
        if lane ~= nil and lane ~= false and retryLaneJob(job, lane) then
            return
        end
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

---One driver pass: resume ready jobs until the budget or the resume cap ends it.
---@param _elapsed number seconds since the previous frame, unused
local function runFrame(_elapsed)
    local config = rawget(state, "config")
    local startTime = now()
    rawset(state, "frameReading", startTime)
    rawset(state, "frameDeadline", startTime + rawget(config, "frameBudgetMs"))

    local resumes = 0
    local maxResumes = rawget(config, "maxResumesPerFrame")
    while resumes < maxResumes do
        if resumes > 0 and frameBudgetExhausted() then
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
    rawset(state, "frameReading", false)
    updateDriver()
end

-- Coalescing family ---------------------------------------------------------
--
-- Debounce, Coalesce, Watch and lanes are one design, documented together in
-- docs/API.md under "Coalescing and lanes":
--
--   * Debounce and Coalesce are callable handles that decide *when* a burst of
--     calls is over. Their timers are TimerKit timers in the owning scope's
--     TimerKit scope, and every due time is computed on one clock,
--     `GetTimePreciseSec`, the clock TimerKit's deadlines use.
--   * Watch shares one TimerKit ticker between every predicate polled at the
--     same interval.
--   * A lane decides *how much* of a scarce resource is used at once. Its
--     submissions are ordinary scheduler jobs, held in the "delayed" state
--     until the lane admits them. Debounce and Coalesce fire into a lane when
--     one is given, so the whole family shares one throttling vocabulary.
--
-- Debounce, Coalesce and Watch handles are "members" of a SchedulerKit scope:
-- they sit on a second intrusive list beside the scope's jobs, so `CancelAll`
-- and `Close` release them exactly like jobs. Lanes are shared by name in
-- package state and are not owned by a scope; each submission's job is.
--
-- Handles and lanes are validated by metatable identity. Their metatables and
-- method tables live in shared state (`familyMetatables`, `familyPrototypes`),
-- and TimerKit callbacks and lane-job callbacks resolve behaviour through
-- `_state.dispatch`, so a later compatible revision upgrades live handles.

-- The section is one installer function: Lua 5.1 allows at most 200 locals
-- in one function, and the main chunk of this file is close to that. The
-- installer commits its own public methods; only the hooks forward-declared
-- above the job machinery escape it.
---Install the coalescing family onto the shared prototypes and facade.
local function installCoalescingFamily()
    local FAMILY_METATABLES = rawget(state, "familyMetatables")
    local FAMILY_PROTOTYPES = rawget(state, "familyPrototypes")
    local DEBOUNCE_METATABLE = rawget(FAMILY_METATABLES, "debounce")
    local COALESCE_METATABLE = rawget(FAMILY_METATABLES, "coalesce")
    local WATCH_METATABLE = rawget(FAMILY_METATABLES, "watch")
    local LANE_METATABLE = rawget(FAMILY_METATABLES, "lane")

    ---Current monotonic wall-clock seconds, the one clock every due time of the
    ---family is computed on.
    ---@return number seconds
    local function nowSeconds()
        return nowFromPreciseClock() / 1000
    end

    ---Resolve one entry of the shared dispatch table, failing loudly when the
    ---shared state was damaged.
    ---@param key string
    ---@return function
    local function dispatchEntry(key)
        local entry = rawget(rawget(state, "dispatch"), key)
        if type(entry) ~= "function" then
            error("MoltenCodes SchedulerKit runtime dispatch is corrupted", 0)
        end
        return entry
    end

    ---Reject an option table that is not a table or names an unknown field. The
    ---alphabetically first unknown field is named, as for scheduling options.
    ---@param options any
    ---@param allowed table<string, boolean>
    ---@param methodName string public method name, used in the argument errors
    ---@param level integer stack level the failure is reported at
    local function validateOptionTable(options, allowed, methodName, level)
        if options == nil then
            return
        end
        if type(options) ~= "table" then
            error(methodName .. " options must be a table", level)
        end

        local unknown = nil
        for key in pairs(options) do
            if allowed[key] ~= true then
                local display = tostring(key)
                if unknown == nil or display < unknown then
                    unknown = display
                end
            end
        end
        if unknown ~= nil then
            error(methodName .. ' options contains unknown field "' .. unknown .. '"', level)
        end
    end

    ---@param value any
    ---@param label string argument description, used in the argument error
    ---@param level integer stack level the failure is reported at
    local function validateOptionalBoolean(value, label, level)
        if value ~= nil and type(value) ~= "boolean" then
            error(label .. " must be a boolean", level)
        end
    end

    ---@param value any
    ---@param label string argument description, used in the argument error
    ---@param level integer stack level the failure is reported at
    local function validateCount(value, label, level)
        if
            type(value) ~= "number"
            or value ~= value
            or value == math.huge
            or value ~= math.floor(value)
            or value < 0
        then
            error(label .. " must be a finite integer greater than or equal to zero", level)
        end
    end

    ---@param member any receiver the public method was called on
    ---@param metatable table the metatable every handle of the expected kind carries
    ---@param methodName string public method name, used in the argument error
    ---@param noun string what the receiver should have been, for the message
    local function validateMember(member, metatable, methodName, noun)
        if type(member) ~= "table" or getmetatable(member) ~= metatable then
            error(methodName .. " must be called on a SchedulerKit " .. noun, 3)
        end
    end

    ---@param lane any
    ---@param label string argument description, used in the argument error
    ---@param level integer stack level the failure is reported at
    local function validateOptionalLane(lane, label, level)
        if lane ~= nil and (type(lane) ~= "table" or getmetatable(lane) ~= LANE_METATABLE) then
            error(label .. " must be a SchedulerKit lane", level)
        end
    end

    ---Empty a reused table in place, keeping its allocated slots for next time.
    ---Assigning `nil` to a field already visited is legal during `next` traversal.
    ---@param set table
    local function wipe(set)
        for key in next, set do
            set[key] = nil
        end
    end

    -- Scope membership ----------------------------------------------------------

    ---Append `member` to `scope`'s intrusive member list. Scopes created by a
    ---revision before 7 carry no member links; `nil` reads as an empty list.
    ---@param scope SchedulerKit.Scope
    ---@param member table
    local function linkMember(scope, member)
        local tail = rawget(scope, "_familyTail") or false
        rawset(member, "_familyPrev", tail)
        rawset(member, "_familyNext", false)
        if tail ~= false then
            rawset(tail, "_familyNext", member)
        else
            rawset(scope, "_familyHead", member)
        end
        rawset(scope, "_familyTail", member)
        rawset(member, "_linked", true)
    end

    ---Remove `member` from its scope's member list, once. Never raises.
    ---@param member table
    local function unlinkMember(member)
        if rawget(member, "_linked") ~= true then
            return
        end
        local scope = rawget(member, "_scope")
        local previous = rawget(member, "_familyPrev")
        local following = rawget(member, "_familyNext")
        if previous ~= false then
            rawset(previous, "_familyNext", following)
        else
            rawset(scope, "_familyHead", following)
        end
        if following ~= false then
            rawset(following, "_familyPrev", previous)
        else
            rawset(scope, "_familyTail", previous)
        end
        rawset(member, "_familyPrev", false)
        rawset(member, "_familyNext", false)
        rawset(member, "_linked", false)
    end

    -- Timers ----------------------------------------------------------------------

    ---Return the package-internal TimerKit scope behind watch tickers and lane
    ---timers, creating it on first use. It is never closed: what it holds is
    ---released when its watch group or lane goes away.
    ---@return TimerKit.Scope
    local function ensureFamilyTimerScope()
        local timerScope = rawget(state, "familyTimerScope")
        if timerScope ~= false then
            return timerScope
        end
        timerScope = TimerKit:CreateScope()
        if type(timerScope) ~= "table" then
            error("MoltenCodes SchedulerKit TimerKit returned an invalid scope", 0)
        end
        rawset(state, "familyTimerScope", timerScope)
        return timerScope
    end

    -- One shared wake callback serves every Debounce, Coalesce and lane timer, so
    -- arming allocates no closure. The owner travels on the TimerKit handle as
    -- public user data, exactly as a delayed job does.
    ---Shared TimerKit callback that wakes whichever member or lane armed it.
    ---@param timerHandle TimerKit.Timer
    ---@return boolean woken
    local function familyWakeCallback(timerHandle)
        if type(timerHandle) ~= "table" then
            return false
        end
        local owner = timerHandle:GetUserData()
        if type(owner) ~= "table" then
            return false
        end
        timerHandle:SetUserData(nil)
        -- A cancelled or re-armed owner no longer points at this handle.
        if rawget(owner, "_timer") ~= timerHandle then
            return false
        end
        rawset(owner, "_timer", false)

        -- A TimerKit callback has no caller to raise to, so a failure inside the
        -- wake is reported rather than escaping into the host timer.
        local ok, value = pcall(dispatchEntry("familyWake"), owner)
        if not ok then
            reportError(value)
            return false
        end
        return true
    end

    ---Arm `owner`'s one timer for `seconds` in `timerScope`.
    ---@param owner table a member or a lane
    ---@param timerScope TimerKit.Scope
    ---@param seconds number
    local function armOwnerTimer(owner, timerScope, seconds)
        local timerHandle = timerScope:After(seconds, familyWakeCallback)
        if type(timerHandle) ~= "table" then
            error("MoltenCodes SchedulerKit TimerKit returned an invalid timer handle", 0)
        end
        -- TimerKit never fires synchronously from `After`, so both halves of the
        -- link are in place before the handle can wake.
        rawset(owner, "_timer", timerHandle)
        timerHandle:SetUserData(owner)
    end

    ---Arm a member's timer in its owning scope's TimerKit scope.
    ---@param member table
    ---@param seconds number
    local function armMemberTimer(member, seconds)
        armOwnerTimer(member, ensureTimerScope(rawget(member, "_scope")), seconds)
    end

    ---Cancel `owner`'s timer if one is armed. May re-raise a host failure after
    ---the owner has already let go of the handle.
    ---@param owner table a member or a lane
    local function cancelOwnerTimer(owner)
        local timerHandle = rawget(owner, "_timer")
        if timerHandle == false or timerHandle == nil then
            return
        end
        rawset(owner, "_timer", false)
        timerHandle:SetUserData(nil)
        timerHandle:Cancel()
    end

    -- Protected invocation ----------------------------------------------------
    --
    -- A Debounce or Coalesce fire without a lane runs its callback synchronously
    -- inside the TimerKit callback. It is protected with `xpcall`, which in Lua 5.1
    -- takes no arguments, so the callback and up to eight arguments are staged in
    -- reusable upvalues and forwarded by one trampoline: a fire allocates nothing.
    -- The trampoline copies the staged values into locals before calling, so a
    -- callback that fires another handle cannot corrupt its own arguments.

    ---@type function|false
    local stagedCallback = false
    local stagedCount = 0
    local staged1, staged2, staged3, staged4, staged5, staged6, staged7, staged8

    ---Call `callback` with exactly `count` of the eight values.
    ---@param callback function
    ---@param count integer
    ---@return any ...
    local function callWithCount(callback, count, a1, a2, a3, a4, a5, a6, a7, a8)
        if count == 0 then
            return callback()
        elseif count == 1 then
            return callback(a1)
        elseif count == 2 then
            return callback(a1, a2)
        elseif count == 3 then
            return callback(a1, a2, a3)
        elseif count == 4 then
            return callback(a1, a2, a3, a4)
        elseif count == 5 then
            return callback(a1, a2, a3, a4, a5)
        elseif count == 6 then
            return callback(a1, a2, a3, a4, a5, a6)
        elseif count == 7 then
            return callback(a1, a2, a3, a4, a5, a6, a7)
        end
        return callback(a1, a2, a3, a4, a5, a6, a7, a8)
    end

    ---Reusable `xpcall` trampoline for the staged callback.
    ---@return any ...
    local function invokeStaged()
        -- Only ever invoked right after `callProtected` staged a function.
        local callback = stagedCallback --[[@as function]]
        local count = stagedCount
        local a1, a2, a3, a4 = staged1, staged2, staged3, staged4
        local a5, a6, a7, a8 = staged5, staged6, staged7, staged8
        stagedCallback, stagedCount = false, 0
        staged1, staged2, staged3, staged4 = nil, nil, nil, nil
        staged5, staged6, staged7, staged8 = nil, nil, nil, nil
        return callWithCount(callback, count, a1, a2, a3, a4, a5, a6, a7, a8)
    end

    ---`xpcall` handler: capture the stack while the failing frame still exists.
    ---@param message any
    ---@return any report
    local function captureFailure(message)
        if nativeTraceback ~= nil then
            local ok, traceback = pcall(nativeTraceback, tostring(message), 2)
            if ok and type(traceback) == "string" then
                return traceback
            end
        end
        return message
    end

    ---Run `callback` with `count` arguments, reporting a raise to the host error
    ---handler instead of propagating it.
    ---@param callback function
    ---@param count integer
    local function callProtected(callback, count, a1, a2, a3, a4, a5, a6, a7, a8)
        stagedCallback, stagedCount = callback, count
        staged1, staged2, staged3, staged4 = a1, a2, a3, a4
        staged5, staged6, staged7, staged8 = a5, a6, a7, a8
        local ok, failure = xpcall(invokeStaged, captureFailure)
        if not ok then
            reportError(failure)
        end
    end

    -- Lanes -------------------------------------------------------------------
    --
    -- A lane rations one scarce resource: at most `maxInFlight` submissions run
    -- at once, two starts are at least `minIntervalSeconds` apart, a submission
    -- that raises is retried with exponential backoff, and at most `maxQueued`
    -- submissions wait. A submission is an ordinary scheduler job created in the
    -- "delayed" state and parked in the lane's FIFO; admission moves it to the
    -- ready queues exactly as a delay expiring would. The job stays owned by its
    -- scope, so closing the scope cancels it wherever it is, and `finishJob`
    -- reports every terminal state back to the lane.

    local admittedJobs

    ---Whether `job` is still waiting for admission and should be served.
    ---@param job any
    ---@return boolean
    local function isWaitingLaneJob(job)
        return type(job) == "table"
            and rawget(job, "_laneAdmitted") == false
            and rawget(job, "_state") == "delayed"
    end

    ---Drop stale entries from the lane FIFO so its backing array holds at most
    ---the live waiting submissions. Only runs when the array is full of entries
    ---some of which were cancelled in place, so it is bounded by `maxQueued`.
    ---@param lane SchedulerKit.Lane
    local function compactLaneQueue(lane)
        local items = rawget(lane, "_items")
        local head = rawget(lane, "_head")
        local tail = rawget(lane, "_tail")
        local write = 0
        for read = head, tail do
            local job = items[read]
            items[read] = nil
            if isWaitingLaneJob(job) then
                write = write + 1
                items[write] = job
            end
        end
        rawset(lane, "_head", 1)
        rawset(lane, "_tail", write)
    end

    ---Take the next waiting submission, discarding stale entries.
    ---@param lane SchedulerKit.Lane
    ---@return SchedulerKit.Job|nil
    local function popLaneJob(lane)
        local items = rawget(lane, "_items")
        local head = rawget(lane, "_head")
        local tail = rawget(lane, "_tail")
        while head <= tail do
            local job = items[head]
            items[head] = nil
            head = head + 1
            if isWaitingLaneJob(job) then
                if head > tail then
                    -- Drained: restart at the front so the indices do not
                    -- climb for the lane's whole life.
                    head, tail = 1, 0
                    rawset(lane, "_tail", 0)
                end
                rawset(lane, "_head", head)
                return job
            end
        end
        rawset(lane, "_head", 1)
        rawset(lane, "_tail", 0)
        return nil
    end

    ---Arm a lane's interval timer in the package-internal timer scope.
    ---@param lane SchedulerKit.Lane
    ---@param seconds number
    local function armLaneTimer(lane, seconds)
        armOwnerTimer(lane, ensureFamilyTimerScope(), seconds)
    end

    ---Return the set of the lane's admitted, unfinished jobs. A lane created by
    ---revision 7 has none; it is created on first use.
    ---@param lane SchedulerKit.Lane
    ---@return table<SchedulerKit.Job, boolean>
    function admittedJobs(lane)
        local admitted = rawget(lane, "_admitted")
        if type(admitted) ~= "table" then
            admitted = {}
            rawset(lane, "_admitted", admitted)
        end
        return admitted
    end

    ---Admit waiting submissions while the lane has room and its interval allows.
    ---
    ---Never raises: it is reached from `finishJob` and from a TimerKit callback,
    ---where nobody can observe a raise. A failure to arm the interval timer is
    ---reported, and the queue resumes on the next submission or completion.
    ---@param lane SchedulerKit.Lane
    ---@return boolean admitted whether a submission entered the ready queues
    local function pumpLane(lane)
        local admitted = false
        while
            rawget(lane, "_closed") ~= true
            and rawget(lane, "_timer") == false
            and rawget(lane, "_inFlight") < rawget(lane, "_maxInFlight")
            and rawget(lane, "_queued") > 0
        do
            local minInterval = rawget(lane, "_minInterval")
            local lastStart = rawget(lane, "_lastStart")
            if minInterval > 0 and lastStart ~= false then
                local wait = lastStart + minInterval - nowSeconds()
                -- A clock that stepped backwards cannot stretch the wait
                -- past one interval.
                if wait > minInterval then
                    wait = minInterval
                end
                if wait > DUE_TOLERANCE_SECONDS then
                    local ok, value = pcall(armLaneTimer, lane, wait)
                    if not ok then
                        reportError(value)
                    end
                    return admitted
                end
            end

            local job = popLaneJob(lane)
            if job == nil then
                -- The count and the FIFO disagree; trust the FIFO.
                rawset(lane, "_queued", 0)
                return admitted
            end

            rawset(lane, "_queued", rawget(lane, "_queued") - 1)
            rawset(lane, "_inFlight", rawget(lane, "_inFlight") + 1)
            rawset(lane, "_lastStart", nowSeconds())
            rawset(job, "_laneAdmitted", true)
            rawset(job, "_state", "pending")
            admittedJobs(lane)[job] = true
            queuePush(job)
            admitted = true
        end
        return admitted
    end

    ---Create one lane submission, or refuse it without allocating.
    ---@param lane SchedulerKit.Lane
    ---@param scope SchedulerKit.Scope open scope that owns the job
    ---@param callback SchedulerKit.Callback
    ---@param priority integer
    ---@param name string|nil
    ---@param owner table|false the Debounce or Coalesce member delivering through it
    ---@return SchedulerKit.Job|nil job
    ---@return string|nil reason `"full"` or `"closed"` when refused
    local function submitToLane(lane, scope, callback, priority, name, owner)
        if rawget(lane, "_closed") == true then
            rawset(lane, "_refused", rawget(lane, "_refused") + 1)
            return nil, "closed"
        end
        local maxQueued = rawget(lane, "_maxQueued")
        if rawget(lane, "_queued") >= maxQueued then
            rawset(lane, "_refused", rawget(lane, "_refused") + 1)
            return nil, "full"
        end
        if rawget(lane, "_tail") - rawget(lane, "_head") + 1 >= maxQueued then
            compactLaneQueue(lane)
        end

        local job = newJob(scope, callback, priority, name, false)
        rawset(job, "_state", "delayed")
        rawset(job, "_lane", lane)
        rawset(job, "_laneAdmitted", false)
        rawset(job, "_attempt", 0)
        rawset(job, "_laneOwner", owner)

        local tail = rawget(lane, "_tail") + 1
        rawset(lane, "_tail", tail)
        rawget(lane, "_items")[tail] = job
        rawset(lane, "_queued", rawget(lane, "_queued") + 1)

        if pumpLane(lane) then
            local ok, value = pcall(updateDriver)
            if not ok then
                reportError(value)
            end
        end
        return job, nil
    end

    -- Assigned below, once Debounce and Coalesce delivery exist.
    local memberDeliveryFinished

    ---Account for a lane job reaching a terminal state. Called from `finishJob`
    ---for every lane job, exactly once.
    ---@param job SchedulerKit.Job
    ---@param lane SchedulerKit.Lane
    ---@param terminalState "completed"|"cancelled"|"failed"
    function laneJobFinished(job, lane, terminalState)
        rawset(job, "_lane", false)
        if rawget(job, "_laneAdmitted") == true then
            admittedJobs(lane)[job] = nil
            rawset(lane, "_inFlight", rawget(lane, "_inFlight") - 1)
        else
            rawset(lane, "_queued", rawget(lane, "_queued") - 1)
        end

        if terminalState == "completed" then
            rawset(lane, "_completed", rawget(lane, "_completed") + 1)
        elseif terminalState == "failed" then
            rawset(lane, "_failed", rawget(lane, "_failed") + 1)
        else
            rawset(lane, "_cancelled", rawget(lane, "_cancelled") + 1)
        end

        local owner = rawget(job, "_laneOwner")
        if type(owner) == "table" then
            rawset(job, "_laneOwner", false)
            -- `finishJob` runs inside cancellation and the frame pass; a failing
            -- follow-up delivery must not escape into either.
            local ok, value = pcall(memberDeliveryFinished, owner, job, terminalState)
            if not ok then
                reportError(value)
            end
        end

        -- Whoever finished the job updates the driver afterwards: cancellation
        -- does, and so does the frame pass.
        pumpLane(lane)
    end

    ---Re-arm a lane job whose attempt raised, if its lane still allows a retry.
    ---
    ---A retried attempt is not reported to the host error handler: the retry is
    ---the expected outcome. Only the attempt that exhausts the policy fails the
    ---job and is reported, with its traceback, like any other job failure. The job
    ---keeps its in-flight slot during the backoff, which is what backing off a
    ---resource means.
    ---@param job SchedulerKit.Job
    ---@param lane SchedulerKit.Lane
    ---@return boolean retried
    function retryLaneJob(job, lane)
        local attempt = rawget(job, "_attempt")
        if
            type(attempt) ~= "number"
            or attempt >= rawget(lane, "_attempts")
            or rawget(lane, "_closed") == true
        then
            -- A closed lane retries nothing: the attempt that raised fails.
            return false
        end

        rawset(job, "_attempt", attempt + 1)
        rawset(lane, "_retried", rawget(lane, "_retried") + 1)
        rawset(job, "_coroutine", false)
        rawset(job, "_generation", rawget(job, "_generation") + 1)

        local backoff = rawget(lane, "_backoff") * rawget(lane, "_multiplier") ^ attempt
        local maxBackoff = rawget(lane, "_maxBackoff")
        if maxBackoff ~= false and backoff > maxBackoff then
            backoff = maxBackoff
        end

        -- A retry is a start: it waits at least until the lane's minimum
        -- interval has passed since the last start. The start itself is
        -- recorded when the backoff expires (see `wakeDelayed`).
        local minInterval = rawget(lane, "_minInterval")
        local lastStart = rawget(lane, "_lastStart")
        if minInterval > 0 and lastStart ~= false then
            local wait = lastStart + minInterval - nowSeconds()
            if wait > minInterval then
                wait = minInterval
            end
            if wait > backoff then
                backoff = wait
            end
        end

        local ok, value = pcall(armDelay, job, backoff)
        if not ok then
            if rawget(job, "_state") ~= "failed" then
                markJobFailed(job, "SchedulerKit failed to arm a lane retry", false)
            end
            reportError(value)
        end
        return true
    end

    ---Read and validate one lane's options into plain values.
    ---@param options any
    ---@param methodName string public method name, used in the argument errors
    ---@param level integer stack level the failures are reported at
    ---@return integer maxInFlight, number minInterval, integer attempts, number backoff, number multiplier, number|false maxBackoff, integer maxQueued
    local function readLaneOptions(options, methodName, level)
        validateOptionTable(options, LANE_OPTION_KEYS, methodName, level + 1)
        local maxInFlight = DEFAULT_LANE_MAX_IN_FLIGHT
        local minInterval = 0
        local maxQueued = DEFAULT_LANE_MAX_QUEUED
        local attempts, backoff, multiplier, maxBackoff = 0, 0, DEFAULT_RETRY_MULTIPLIER, false
        if options == nil then
            return maxInFlight, minInterval, attempts, backoff, multiplier, maxBackoff, maxQueued
        end

        if rawget(options, "maxInFlight") ~= nil then
            maxInFlight = rawget(options, "maxInFlight")
            validatePositiveInteger(maxInFlight, methodName .. " maxInFlight", level + 1)
        end
        if rawget(options, "minIntervalSeconds") ~= nil then
            minInterval = rawget(options, "minIntervalSeconds")
            validateFinitePositive(
                minInterval,
                methodName .. " minIntervalSeconds",
                true,
                level + 1
            )
        end
        if rawget(options, "maxQueued") ~= nil then
            maxQueued = rawget(options, "maxQueued")
            validatePositiveInteger(maxQueued, methodName .. " maxQueued", level + 1)
        end

        local retry = rawget(options, "retry")
        if retry ~= nil then
            validateOptionTable(retry, RETRY_OPTION_KEYS, methodName .. " retry", level + 1)
            if rawget(retry, "attempts") ~= nil then
                attempts = rawget(retry, "attempts")
                validateCount(attempts, methodName .. " retry.attempts", level + 1)
            end
            if rawget(retry, "backoffSeconds") ~= nil then
                backoff = rawget(retry, "backoffSeconds")
                validateFinitePositive(
                    backoff,
                    methodName .. " retry.backoffSeconds",
                    true,
                    level + 1
                )
            end
            if rawget(retry, "multiplier") ~= nil then
                multiplier = rawget(retry, "multiplier")
                validateFinitePositive(
                    multiplier,
                    methodName .. " retry.multiplier",
                    false,
                    level + 1
                )
                if multiplier < 1 then
                    error(methodName .. " retry.multiplier must be at least 1", level)
                end
            end
            if rawget(retry, "maxBackoffSeconds") ~= nil then
                maxBackoff = rawget(retry, "maxBackoffSeconds")
                validateFinitePositive(
                    maxBackoff,
                    methodName .. " retry.maxBackoffSeconds",
                    true,
                    level + 1
                )
            end
        end
        return maxInFlight, minInterval, attempts, backoff, multiplier, maxBackoff, maxQueued
    end

    ---Return the shared lane called `name`, creating it on first request.
    ---@param name any
    ---@param options any
    ---@param methodName string public method name, used in the argument errors
    ---@return SchedulerKit.Lane
    local function getOrCreateLane(name, options, methodName)
        validateNonEmptyString(name, methodName .. " name", 4)
        local maxInFlight, minInterval, attempts, backoff, multiplier, maxBackoff, maxQueued =
            readLaneOptions(options, methodName, 4)

        local lanes = rawget(state, "lanes")
        local existing = rawget(lanes, name)
        if existing ~= nil then
            if
                options ~= nil
                and (
                    rawget(existing, "_maxInFlight") ~= maxInFlight
                    or rawget(existing, "_minInterval") ~= minInterval
                    or rawget(existing, "_attempts") ~= attempts
                    or rawget(existing, "_backoff") ~= backoff
                    or rawget(existing, "_multiplier") ~= multiplier
                    or rawget(existing, "_maxBackoff") ~= maxBackoff
                    or rawget(existing, "_maxQueued") ~= maxQueued
                )
            then
                error(
                    methodName .. ' lane "' .. name .. '" already exists with different options',
                    3
                )
            end
            return existing
        end

        if rawget(state, "laneCount") >= MAX_LANES then
            error(
                methodName
                    .. " refuses to create more than "
                    .. MAX_LANES
                    .. " open lanes; close unused lanes or share one by name",
                3
            )
        end

        local lane = setmetatable({
            _kind = "lane",
            _name = name,
            _maxInFlight = maxInFlight,
            _minInterval = minInterval,
            _attempts = attempts,
            _backoff = backoff,
            _multiplier = multiplier,
            _maxBackoff = maxBackoff,
            _maxQueued = maxQueued,
            _items = {},
            _head = 1,
            _tail = 0,
            _queued = 0,
            _inFlight = 0,
            _completed = 0,
            _failed = 0,
            _retried = 0,
            _cancelled = 0,
            _refused = 0,
            _lastStart = false,
            _timer = false,
            _closed = false,
            _statsView = false,
        }, LANE_METATABLE)
        rawset(lanes, name, lane)
        rawset(state, "laneCount", rawget(state, "laneCount") + 1)
        return lane
    end

    ---Submit `callback` to run as a job under this lane's limits.
    ---@param self SchedulerKit.Lane
    ---@param callback SchedulerKit.Callback
    ---@param options SchedulerKit.SubmitOptions?
    ---@return SchedulerKit.Job|nil job
    ---@return string|nil reason `"full"` or `"closed"` when refused
    local function laneSubmit(self, callback, options)
        validateMember(self, LANE_METATABLE, "SchedulerKit.Lane:Submit", "lane")
        if type(callback) ~= "function" then
            error("SchedulerKit.Lane:Submit callback must be a function", 2)
        end
        validateOptionTable(options, SUBMIT_OPTION_KEYS, "SchedulerKit.Lane:Submit", 3)

        local priority, name, scope = PRIORITY_NORMAL, nil, nil
        if options ~= nil then
            priority = validatePriority(
                rawget(options, "priority"),
                "SchedulerKit.Lane:Submit priority",
                3
            )
            name = rawget(options, "name")
            if name ~= nil then
                validateNonEmptyString(name, "SchedulerKit.Lane:Submit name", 3)
            end
            scope = rawget(options, "scope")
            if
                scope ~= nil and (type(scope) ~= "table" or getmetatable(scope) ~= SCOPE_METATABLE)
            then
                error("SchedulerKit.Lane:Submit scope must be a SchedulerKit scope", 2)
            end
        end
        if scope == nil then
            scope = getDefaultScope()
        elseif rawget(scope, "_closed") == true then
            error("SchedulerKit.Lane:Submit cannot schedule work in a closed scope", 2)
        end

        local job, reason = submitToLane(self, scope, callback, priority, name, false)
        return job, reason
    end

    ---Return this lane's counters in a table reused by every call.
    ---@param self SchedulerKit.Lane
    ---@return SchedulerKit.LaneStats stats
    local function laneGetStats(self)
        validateMember(self, LANE_METATABLE, "SchedulerKit.Lane:GetStats", "lane")
        local view = rawget(self, "_statsView")
        if view == false then
            view = {}
            rawset(self, "_statsView", view)
        end
        view.queued = rawget(self, "_queued")
        view.inFlight = rawget(self, "_inFlight")
        view.completed = rawget(self, "_completed")
        view.failed = rawget(self, "_failed")
        view.retried = rawget(self, "_retried")
        view.cancelled = rawget(self, "_cancelled")
        view.refused = rawget(self, "_refused")
        return view
    end

    ---Return the name this lane is shared under.
    ---@param self SchedulerKit.Lane
    ---@return string name
    local function laneGetName(self)
        validateMember(self, LANE_METATABLE, "SchedulerKit.Lane:GetName", "lane")
        return rawget(self, "_name")
    end

    ---Whether this lane is closed.
    ---@param self SchedulerKit.Lane
    ---@return boolean closed
    local function laneIsClosed(self)
        validateMember(self, LANE_METATABLE, "SchedulerKit.Lane:IsClosed", "lane")
        return rawget(self, "_closed") == true
    end

    ---Close the lane: refuse new submissions, cancel every waiting submission,
    ---and let the admitted ones run to completion. The name is released at once,
    ---so a later `Lane(name)` creates a fresh lane.
    ---@param self SchedulerKit.Lane
    ---@return boolean closed `false` when the lane was already closed.
    local function laneClose(self)
        validateMember(self, LANE_METATABLE, "SchedulerKit.Lane:Close", "lane")
        if rawget(self, "_closed") == true then
            return false
        end
        rawset(self, "_closed", true)

        local lanes = rawget(state, "lanes")
        if rawget(lanes, rawget(self, "_name")) == self then
            rawset(lanes, rawget(self, "_name"), nil)
            rawset(state, "laneCount", rawget(state, "laneCount") - 1)
        end

        local firstError = nil
        local ok, value = pcall(cancelOwnerTimer, self)
        if not ok then
            firstError = { value = value }
        end

        local items = rawget(self, "_items")
        for index = rawget(self, "_head"), rawget(self, "_tail") do
            local job = items[index]
            items[index] = nil
            if isWaitingLaneJob(job) then
                local cancelOk, cancelError = pcall(cancelJob, job)
                if not cancelOk and firstError == nil then
                    firstError = { value = cancelError }
                end
            end
        end
        rawset(self, "_head", 1)
        rawset(self, "_tail", 0)

        -- An admitted job waiting out a retry backoff has not started its next
        -- attempt yet; it is cancelled. Running attempts finish, and one that
        -- raises now fails instead of retrying (see `retryLaneJob`).
        for job in next, admittedJobs(self) do
            if rawget(job, "_state") == "delayed" then
                local cancelOk, cancelError = pcall(cancelJob, job)
                if not cancelOk and firstError == nil then
                    firstError = { value = cancelError }
                end
            end
        end

        if firstError ~= nil then
            error(firstError.value, 0)
        end
        return true
    end

    ---A lane's interval timer expired: admit what the interval was holding back.
    ---@param lane SchedulerKit.Lane
    local function laneWake(lane)
        if pumpLane(lane) then
            updateDriver()
        end
    end

    -- Debounce ----------------------------------------------------------------
    --
    -- State machine, per handle:
    --
    --   idle ──call──> waiting (timer armed for `delay`; leading fires now)
    --   waiting ──call──> waiting (arguments replaced, trailing fire owed)
    --   waiting ──timer──> quiet long enough, or `maxWait` reached?
    --                        yes: idle, and the owed trailing fire runs
    --                        no:  re-arm for the remainder
    --
    -- A call inside the window only records its arguments and a clock reading:
    -- the timer is not re-armed per call, it re-arms once when it wakes early.

    ---Build the job callback a member hands to its lane. One closure per member,
    ---made once; it resolves the delivery through shared dispatch.
    ---@param member table
    ---@return SchedulerKit.Callback
    local function newDeliveryCallback(member)
        return function()
            return dispatchEntry("runDelivery")(member)
        end
    end

    ---Clear the argument slot `args`.
    ---@param args table
    local function clearArguments(args)
        for index = 1, MAX_DEBOUNCE_ARGUMENTS do
            args[index] = nil
        end
    end

    ---Build the reused argument slot, pre-sized so recording never grows it.
    ---@return table
    local function newArgumentSlot()
        return { false, false, false, false, false, false, false, false }
    end

    ---Fire a debounce handle synchronously with its recorded arguments.
    ---@param member SchedulerKit.DebounceHandle
    local function fireDebounceDirect(member)
        local args = rawget(member, "_args")
        local count = rawget(member, "_argCount")
        local a1, a2, a3, a4 = args[1], args[2], args[3], args[4]
        local a5, a6, a7, a8 = args[5], args[6], args[7], args[8]
        clearArguments(args)
        rawset(member, "_argCount", 0)
        rawset(member, "_trailing", false)

        rawset(member, "_firing", true)
        callProtected(rawget(member, "_callback"), count, a1, a2, a3, a4, a5, a6, a7, a8)
        rawset(member, "_firing", false)
    end

    ---Arm a member's timer, or report the failure and leave the member idle
    ---with its owed fire intact, so the next call or `Flush` recovers it.
    ---@param member table
    ---@param seconds number
    ---@return boolean armed
    local function armMemberTimerOrReport(member, seconds)
        local ok, value = pcall(armMemberTimer, member, seconds)
        if not ok then
            rawset(member, "_waiting", false)
            reportError(value)
            return false
        end
        return true
    end

    ---Hand the delivery slot to the lane as one job.
    ---@param member SchedulerKit.DebounceHandle
    ---@return "delivered"|"deferred"|"dropped" status
    local function submitDebounceDelivery(member)
        local lane = rawget(member, "_lane")
        local job, reason = submitToLane(
            lane,
            rawget(member, "_scope"),
            rawget(member, "_laneCallback"),
            PRIORITY_NORMAL,
            nil,
            member
        )
        if job ~= nil then
            rawset(member, "_deliveryJob", job)
            return "delivered"
        end

        if reason == "full" and rawget(member, "_closed") ~= true then
            -- A full lane defers a debounce fire; it never drops it.
            if rawget(member, "_trailing") == true then
                -- A newer burst is already owed. Its arguments supersede the
                -- ones the lane refused, which are discarded.
                clearArguments(rawget(member, "_deliveryArgs"))
                rawset(member, "_deliveryCount", 0)
            else
                -- Take the arguments back as the owed call.
                local args = rawget(member, "_args")
                rawset(member, "_args", rawget(member, "_deliveryArgs"))
                rawset(member, "_deliveryArgs", args)
                rawset(member, "_argCount", rawget(member, "_deliveryCount"))
                rawset(member, "_deliveryCount", 0)
                rawset(member, "_trailing", true)
                rawset(member, "_lastCall", nowSeconds())
                rawset(member, "_burstStart", rawget(member, "_lastCall"))
            end
            -- Try again one delay later.
            rawset(member, "_waiting", true)
            if rawget(member, "_timer") == false then
                armMemberTimerOrReport(member, rawget(member, "_delay"))
            end
            return "deferred"
        end

        clearArguments(rawget(member, "_deliveryArgs"))
        rawset(member, "_deliveryCount", 0)
        reportError(
            'SchedulerKit debounce fire dropped: lane "' .. rawget(lane, "_name") .. '" is closed'
        )
        return "dropped"
    end

    ---Deliver the owed call: synchronously, or through the lane.
    ---@param member SchedulerKit.DebounceHandle
    ---@return "delivered"|"deferred"|"dropped" status
    local function deliverDebounce(member)
        if rawget(member, "_lane") == false then
            fireDebounceDirect(member)
            return "delivered"
        end

        -- Swap the owed arguments into the delivery slot. Arguments a delivery
        -- still waiting in the lane carried are superseded: the last call wins.
        local args = rawget(member, "_args")
        local delivery = rawget(member, "_deliveryArgs")
        clearArguments(delivery)
        rawset(member, "_args", delivery)
        rawset(member, "_deliveryArgs", args)
        rawset(member, "_deliveryCount", rawget(member, "_argCount"))
        rawset(member, "_argCount", 0)
        rawset(member, "_trailing", false)

        if rawget(member, "_deliveryJob") ~= false then
            -- The job reads the delivery slot when it starts; if it has already
            -- started, `_deliveryDirty` makes it deliver once more afterwards.
            rawset(member, "_deliveryDirty", true)
            return "delivered"
        end
        local status = submitDebounceDelivery(member)
        return status
    end

    ---The debounce timer woke: fire if the burst is over, else re-arm.
    ---@param member SchedulerKit.DebounceHandle
    local function debounceWake(member)
        if rawget(member, "_closed") == true or rawget(member, "_waiting") ~= true then
            return
        end

        local due = rawget(member, "_lastCall") + rawget(member, "_delay")
        local maxWait = rawget(member, "_maxWait")
        if maxWait ~= false and rawget(member, "_trailing") == true then
            local cap = rawget(member, "_burstStart") + maxWait
            if cap < due then
                due = cap
            end
        end

        local remaining = due - nowSeconds()
        -- A clock that stepped backwards cannot stretch the wait past one delay.
        if remaining > rawget(member, "_delay") then
            remaining = rawget(member, "_delay")
        end
        if remaining > DUE_TOLERANCE_SECONDS then
            armMemberTimerOrReport(member, remaining)
            return
        end

        rawset(member, "_waiting", false)
        if rawget(member, "_trailing") == true then
            deliverDebounce(member)
        end
    end

    ---Record one call on a debounce handle. This is the handle's `__call`.
    ---@param member SchedulerKit.DebounceHandle
    ---@param ... any at most eight arguments
    ---@return boolean accepted `false` once the handle is closed.
    local function debounceCall(member, ...)
        if rawget(member, "_closed") == true then
            return false
        end
        local count = select("#", ...)
        if count > MAX_DEBOUNCE_ARGUMENTS then
            error(
                "SchedulerKit debounce handle accepts at most "
                    .. MAX_DEBOUNCE_ARGUMENTS
                    .. " arguments; received "
                    .. count,
                2
            )
        end

        local args = rawget(member, "_args")
        args[1], args[2], args[3], args[4], args[5], args[6], args[7], args[8] = ...
        rawset(member, "_argCount", count)
        local reading = nowSeconds()
        rawset(member, "_lastCall", reading)

        if rawget(member, "_waiting") == true and rawget(member, "_timer") ~= false then
            rawset(member, "_trailing", true)
            return true
        end

        -- First call of a burst: open the window before any fire, so a callback
        -- that calls the handle again finds it waiting.
        rawset(member, "_waiting", true)
        rawset(member, "_burstStart", reading)
        local leading = rawget(member, "_leading") == true and rawget(member, "_firing") ~= true
        rawset(member, "_trailing", not leading)

        local ok, value = pcall(armMemberTimer, member, rawget(member, "_delay"))
        if not ok then
            rawset(member, "_waiting", false)
            rawset(member, "_trailing", false)
            clearArguments(args)
            rawset(member, "_argCount", 0)
            error(value, 0)
        end

        if leading then
            deliverDebounce(member)
        end
        return true
    end

    ---Run a lane delivery of a debounce handle. Raises propagate to the job, so
    ---the lane's retry policy applies to the callback.
    ---@param member SchedulerKit.DebounceHandle
    ---@return any ...
    local function runDebounceDelivery(member)
        rawset(member, "_deliveryDirty", false)
        local args = rawget(member, "_deliveryArgs")
        local count = rawget(member, "_deliveryCount")
        return callWithCount(
            rawget(member, "_callback"),
            count,
            args[1],
            args[2],
            args[3],
            args[4],
            args[5],
            args[6],
            args[7],
            args[8]
        )
    end

    ---Drop the owed call and any open window; the handle stays usable.
    ---@param member SchedulerKit.DebounceHandle
    ---@return boolean dropped whether a fire was owed
    local function cancelDebounce(member)
        local owed = rawget(member, "_trailing") == true
        rawset(member, "_waiting", false)
        rawset(member, "_trailing", false)
        clearArguments(rawget(member, "_args"))
        rawset(member, "_argCount", 0)
        cancelOwnerTimer(member)
        return owed
    end

    -- Coalesce ----------------------------------------------------------------
    --
    -- The first key of a burst arms one timer for the interval; every key
    -- recorded before it expires lands in the same set, and the callback runs
    -- once at the end of the interval with everything collected. The set is one
    -- of two reused tables: the pair is swapped at delivery, so keys recorded by
    -- the callback itself go into the other table and nothing is allocated.

    ---Deliver the collected set synchronously, then wipe it for reuse.
    ---@param member SchedulerKit.CoalesceHandle
    local function fireCoalesceDirect(member)
        local set = rawget(member, "_set")
        rawset(member, "_set", rawget(member, "_spare"))
        rawset(member, "_spare", set)
        rawset(member, "_keyCount", 0)
        rawset(member, "_delivered", rawget(member, "_delivered") + 1)

        rawset(member, "_firing", true)
        callProtected(rawget(member, "_callback"), 1, set)
        rawset(member, "_firing", false)
        wipe(set)
    end

    ---Deliver the collected set: synchronously, or through the lane.
    ---@param member SchedulerKit.CoalesceHandle
    ---@return "delivered"|"deferred"|"dropped" status
    local function deliverCoalesce(member)
        local lane = rawget(member, "_lane")
        if lane == false then
            fireCoalesceDirect(member)
            return "delivered"
        end

        if rawget(member, "_deliveryJob") ~= false then
            -- The previous set is still in the lane. Keep collecting into the
            -- current one and try again one interval later.
            rawset(member, "_deferred", rawget(member, "_deferred") + 1)
            if rawget(member, "_timer") == false then
                armMemberTimer(member, rawget(member, "_interval"))
            end
            return "deferred"
        end

        local set = rawget(member, "_set")
        local count = rawget(member, "_keyCount")
        rawset(member, "_deliverySet", set)
        rawset(member, "_set", rawget(member, "_spare"))
        rawset(member, "_spare", false)
        rawset(member, "_keyCount", 0)

        local job, reason = submitToLane(
            lane,
            rawget(member, "_scope"),
            rawget(member, "_laneCallback"),
            PRIORITY_NORMAL,
            nil,
            member
        )
        if job ~= nil then
            rawset(member, "_deliveryJob", job)
            rawset(member, "_delivered", rawget(member, "_delivered") + 1)
            return "delivered"
        end

        -- Refused: the set goes back to collecting.
        rawset(member, "_spare", rawget(member, "_set"))
        rawset(member, "_set", set)
        rawset(member, "_deliverySet", false)
        rawset(member, "_keyCount", count)
        if reason == "full" then
            rawset(member, "_deferred", rawget(member, "_deferred") + 1)
            if rawget(member, "_timer") == false then
                armMemberTimer(member, rawget(member, "_interval"))
            end
            return "deferred"
        end

        wipe(set)
        rawset(member, "_keyCount", 0)
        rawset(member, "_dropped", rawget(member, "_dropped") + 1)
        reportError(
            'SchedulerKit coalesce delivery dropped: lane "'
                .. rawget(lane, "_name")
                .. '" is closed'
        )
        return "dropped"
    end

    ---The coalesce timer woke: deliver whatever the interval collected.
    ---@param member SchedulerKit.CoalesceHandle
    local function coalesceWake(member)
        if rawget(member, "_closed") == true or rawget(member, "_keyCount") == 0 then
            return
        end
        deliverCoalesce(member)
    end

    ---Record one key on a coalesce handle. This is the handle's `__call`.
    ---@param member SchedulerKit.CoalesceHandle
    ---@param key any any value but `nil` or NaN
    ---@param value any stored for `key`; `true` when omitted
    ---@return boolean accepted `false` when the key was refused or the handle is closed.
    local function coalesceCall(member, key, value)
        if key == nil or key ~= key then
            error("SchedulerKit coalesce handle key must not be nil or NaN", 2)
        end
        if rawget(member, "_closed") == true then
            return false
        end
        if value == nil then
            value = true
        end

        local set = rawget(member, "_set")
        if set[key] == nil then
            local count = rawget(member, "_keyCount")
            if count >= rawget(member, "_maxKeys") then
                rawset(member, "_refused", rawget(member, "_refused") + 1)
                return false
            end
            rawset(member, "_keyCount", count + 1)
        end
        set[key] = value

        if rawget(member, "_timer") == false then
            armMemberTimer(member, rawget(member, "_interval"))
        end
        return true
    end

    ---Run a lane delivery of a coalesce handle. Raises propagate to the job.
    ---@param member SchedulerKit.CoalesceHandle
    ---@return any ...
    local function runCoalesceDelivery(member)
        return rawget(member, "_callback")(rawget(member, "_deliverySet"))
    end

    ---Drop the collected keys; the handle stays usable.
    ---@param member SchedulerKit.CoalesceHandle
    ---@return boolean dropped whether any key was collected
    local function cancelCoalesce(member)
        local had = rawget(member, "_keyCount") > 0
        wipe(rawget(member, "_set"))
        rawset(member, "_keyCount", 0)
        cancelOwnerTimer(member)
        return had
    end

    ---A member's lane delivery reached a terminal state.
    ---@param member table
    ---@param job SchedulerKit.Job
    ---@param terminalState "completed"|"cancelled"|"failed"
    function memberDeliveryFinished(member, job, terminalState)
        if rawget(member, "_deliveryJob") ~= job then
            return
        end
        rawset(member, "_deliveryJob", false)

        if rawget(member, "_kind") == "debounce" then
            if
                rawget(member, "_deliveryDirty") == true
                and terminalState ~= "cancelled"
                and rawget(member, "_closed") ~= true
            then
                -- A newer call arrived after the job had read its arguments.
                rawset(member, "_deliveryDirty", false)
                submitDebounceDelivery(member)
                return
            end
            rawset(member, "_deliveryDirty", false)
            clearArguments(rawget(member, "_deliveryArgs"))
            rawset(member, "_deliveryCount", 0)
            return
        end

        local set = rawget(member, "_deliverySet")
        rawset(member, "_deliverySet", false)
        if type(set) == "table" then
            wipe(set)
            rawset(member, "_spare", set)
        end
    end

    -- Watch -------------------------------------------------------------------
    --
    -- Watchers are grouped by interval; each group owns one TimerKit ticker in
    -- the package-internal timer scope, created with its first watcher and
    -- cancelled with its last. A tick samples the group's watchers in creation
    -- order. Watchers cancelled during a tick are compacted out after it, and
    -- watchers added during a tick start with the next one.

    ---Shared TimerKit ticker callback for every watch group.
    ---@param timerHandle TimerKit.Timer
    local function watchTickCallback(timerHandle)
        if type(timerHandle) ~= "table" then
            return
        end
        local group = timerHandle:GetUserData()
        if type(group) ~= "table" then
            return
        end
        local ok, value = pcall(dispatchEntry("watchTick"), group)
        if not ok then
            reportError(value)
        end
    end

    ---Remove cancelled watchers from `group`, keeping creation order.
    ---@param group table
    local function compactWatchGroup(group)
        local watchers = rawget(group, "watchers")
        local count = #watchers
        local write = 0
        for read = 1, count do
            local watcher = watchers[read]
            watchers[read] = nil
            if rawget(watcher, "_closed") ~= true then
                write = write + 1
                watchers[write] = watcher
            end
        end
        rawset(group, "dirty", false)
    end

    ---Release `group` and its ticker once it has no live watcher.
    ---@param group table
    local function releaseWatchGroupIfEmpty(group)
        if rawget(group, "live") > 0 or rawget(group, "released") == true then
            return
        end
        rawset(group, "released", true)
        local groups = rawget(state, "watchGroups")
        if rawget(groups, rawget(group, "interval")) == group then
            rawset(groups, rawget(group, "interval"), nil)
            rawset(state, "watchGroupCount", rawget(state, "watchGroupCount") - 1)
        end
        local ticker = rawget(group, "ticker")
        rawset(group, "ticker", false)
        if ticker ~= false then
            ticker:SetUserData(nil)
            ticker:Cancel()
        end
    end

    ---Cancel one watcher. Terminal and idempotent.
    ---@param watcher SchedulerKit.WatchHandle
    ---@return boolean cancelled `false` when it was already cancelled.
    local function cancelWatcher(watcher)
        if rawget(watcher, "_closed") == true then
            return false
        end
        rawset(watcher, "_closed", true)
        unlinkMember(watcher)
        rawset(watcher, "_value", nil)

        local group = rawget(watcher, "_group")
        rawset(group, "live", rawget(group, "live") - 1)
        if rawget(group, "ticking") == true then
            rawset(group, "dirty", true)
            return true
        end
        compactWatchGroup(group)
        releaseWatchGroupIfEmpty(group)
        return true
    end

    ---Sample one watcher and call back on a change, or on every tick.
    ---@param watcher SchedulerKit.WatchHandle
    local function sampleWatcher(watcher)
        local ok, value = xpcall(rawget(watcher, "_predicate"), captureFailure)
        if not ok then
            -- A predicate that raises would raise again on every tick; the
            -- watcher is cancelled after the failure is reported once.
            reportError(value)
            cancelWatcher(watcher)
            return
        end

        local previous = rawget(watcher, "_value")
        local first = rawget(watcher, "_sampled") ~= true
        rawset(watcher, "_sampled", true)
        rawset(watcher, "_value", value)
        if first or value ~= previous or rawget(watcher, "_everyTick") == true then
            -- Reported with a traceback, like the predicate.
            callProtected(rawget(watcher, "_callback"), 2, value, previous)
        end
    end

    ---One tick of a watch group.
    ---@param group table
    local function watchTick(group)
        if rawget(group, "released") == true then
            return
        end
        rawset(group, "ticking", true)
        local watchers = rawget(group, "watchers")
        local count = #watchers
        for index = 1, count do
            local watcher = watchers[index]
            if rawget(watcher, "_closed") ~= true then
                sampleWatcher(watcher)
            end
        end
        rawset(group, "ticking", false)
        if rawget(group, "dirty") == true then
            compactWatchGroup(group)
        end
        releaseWatchGroupIfEmpty(group)
    end

    ---Return the watch group for `interval`, creating it and its ticker.
    ---@param interval number
    ---@param methodName string public method name, used in the argument errors
    ---@return table group
    local function ensureWatchGroup(interval, methodName)
        local groups = rawget(state, "watchGroups")
        local group = rawget(groups, interval)
        if group ~= nil then
            if rawget(group, "live") >= MAX_WATCHERS_PER_INTERVAL then
                error(
                    methodName
                        .. " refuses more than "
                        .. MAX_WATCHERS_PER_INTERVAL
                        .. " watchers on one interval; cancel unused watchers",
                    4
                )
            end
            return group
        end

        if rawget(state, "watchGroupCount") >= MAX_WATCH_INTERVALS then
            error(
                methodName
                    .. " refuses more than "
                    .. MAX_WATCH_INTERVALS
                    .. " distinct watch intervals; reuse an interval",
                4
            )
        end

        group = {
            interval = interval,
            watchers = {},
            live = 0,
            ticker = false,
            ticking = false,
            dirty = false,
            released = false,
        }
        local ticker = ensureFamilyTimerScope():Every(interval, watchTickCallback)
        if type(ticker) ~= "table" then
            error("MoltenCodes SchedulerKit TimerKit returned an invalid timer handle", 0)
        end
        ticker:SetUserData(group)
        rawset(group, "ticker", ticker)
        rawset(groups, interval, group)
        rawset(state, "watchGroupCount", rawget(state, "watchGroupCount") + 1)
        return group
    end

    -- Creation ----------------------------------------------------------------
    --
    -- Public methods call these without a tail call, so each one's frame stays on
    -- the stack: `level` 4 inside a validator called from here is the line that
    -- called the public method.

    ---@param scope SchedulerKit.Scope
    ---@param methodName string public method name, used in the argument errors
    local function ensureScopeOpen(scope, methodName)
        if rawget(scope, "_closed") == true then
            error(methodName .. " cannot schedule work in a closed scope", 4)
        end
    end

    ---Build a debounce handle in `scope`.
    ---@param scope SchedulerKit.Scope
    ---@param callback any
    ---@param delay any
    ---@param options any
    ---@param methodName string public method name, used in the argument errors
    ---@return SchedulerKit.DebounceHandle
    local function createDebounce(scope, callback, delay, options, methodName)
        ensureScopeOpen(scope, methodName)
        if type(callback) ~= "function" then
            error(methodName .. " callback must be a function", 3)
        end
        validateFinitePositive(delay, methodName .. " delaySeconds", true, 4)
        validateOptionTable(options, DEBOUNCE_OPTION_KEYS, methodName, 4)

        local leading, maxWait, lane = false, false, false
        if options ~= nil then
            validateOptionalBoolean(rawget(options, "leading"), methodName .. " leading", 4)
            leading = rawget(options, "leading") == true
            if rawget(options, "maxWaitSeconds") ~= nil then
                maxWait = rawget(options, "maxWaitSeconds")
                validateFinitePositive(maxWait, methodName .. " maxWaitSeconds", false, 4)
                if maxWait < delay then
                    error(methodName .. " maxWaitSeconds must be at least delaySeconds", 3)
                end
            end
            validateOptionalLane(rawget(options, "lane"), methodName .. " lane", 4)
            lane = rawget(options, "lane") or false
        end

        local member = setmetatable({
            _kind = "debounce",
            _scope = scope,
            _linked = false,
            _familyPrev = false,
            _familyNext = false,
            _closed = false,
            _callback = callback,
            _delay = delay,
            _maxWait = maxWait,
            _leading = leading,
            _lane = lane,
            _args = newArgumentSlot(),
            _argCount = 0,
            _waiting = false,
            _trailing = false,
            _firing = false,
            _timer = false,
            _lastCall = 0,
            _burstStart = 0,
            _deliveryArgs = false,
            _deliveryCount = 0,
            _deliveryJob = false,
            _deliveryDirty = false,
            _laneCallback = false,
        }, DEBOUNCE_METATABLE)
        clearArguments(rawget(member, "_args"))
        if lane ~= false then
            local deliveryArgs = newArgumentSlot()
            clearArguments(deliveryArgs)
            rawset(member, "_deliveryArgs", deliveryArgs)
            rawset(member, "_laneCallback", newDeliveryCallback(member))
        end
        linkMember(scope, member)
        return member
    end

    ---Build a coalesce handle in `scope`.
    ---@param scope SchedulerKit.Scope
    ---@param callback any
    ---@param interval any
    ---@param options any
    ---@param methodName string public method name, used in the argument errors
    ---@return SchedulerKit.CoalesceHandle
    local function createCoalesce(scope, callback, interval, options, methodName)
        ensureScopeOpen(scope, methodName)
        if type(callback) ~= "function" then
            error(methodName .. " callback must be a function", 3)
        end
        validateFinitePositive(interval, methodName .. " intervalSeconds", true, 4)
        validateOptionTable(options, COALESCE_OPTION_KEYS, methodName, 4)

        local maxKeys, lane = DEFAULT_COALESCE_MAX_KEYS, false
        if options ~= nil then
            if rawget(options, "maxKeys") ~= nil then
                maxKeys = rawget(options, "maxKeys")
                validatePositiveInteger(maxKeys, methodName .. " maxKeys", 4)
            end
            validateOptionalLane(rawget(options, "lane"), methodName .. " lane", 4)
            lane = rawget(options, "lane") or false
        end

        local member = setmetatable({
            _kind = "coalesce",
            _scope = scope,
            _linked = false,
            _familyPrev = false,
            _familyNext = false,
            _closed = false,
            _callback = callback,
            _interval = interval,
            _maxKeys = maxKeys,
            _lane = lane,
            _set = {},
            _spare = {},
            _keyCount = 0,
            _firing = false,
            _timer = false,
            _refused = 0,
            _delivered = 0,
            _deferred = 0,
            _dropped = 0,
            _statsView = false,
            _deliverySet = false,
            _deliveryJob = false,
            _laneCallback = false,
        }, COALESCE_METATABLE)
        if lane ~= false then
            rawset(member, "_laneCallback", newDeliveryCallback(member))
        end
        linkMember(scope, member)
        return member
    end

    ---Build a watcher in `scope`, joining or creating its interval group.
    ---@param scope SchedulerKit.Scope
    ---@param predicate any
    ---@param interval any
    ---@param callback any
    ---@param options any
    ---@param methodName string public method name, used in the argument errors
    ---@return SchedulerKit.WatchHandle
    local function createWatch(scope, predicate, interval, callback, options, methodName)
        ensureScopeOpen(scope, methodName)
        if type(predicate) ~= "function" then
            error(methodName .. " predicate must be a function", 3)
        end
        validateFinitePositive(interval, methodName .. " intervalSeconds", false, 4)
        if type(callback) ~= "function" then
            error(methodName .. " callback must be a function", 3)
        end
        validateOptionTable(options, WATCH_OPTION_KEYS, methodName, 4)
        local everyTick = false
        if options ~= nil then
            validateOptionalBoolean(rawget(options, "everyTick"), methodName .. " everyTick", 4)
            everyTick = rawget(options, "everyTick") == true
        end

        local group = ensureWatchGroup(interval, methodName)
        local watcher = setmetatable({
            _kind = "watch",
            _scope = scope,
            _linked = false,
            _familyPrev = false,
            _familyNext = false,
            _closed = false,
            _predicate = predicate,
            _callback = callback,
            _everyTick = everyTick,
            _group = group,
            _sampled = false,
            _value = nil,
        }, WATCH_METATABLE)
        local watchers = rawget(group, "watchers")
        watchers[#watchers + 1] = watcher
        rawset(group, "live", rawget(group, "live") + 1)
        linkMember(scope, watcher)
        return watcher
    end

    -- Member release ----------------------------------------------------------

    ---Close one Debounce or Coalesce member: drop what it owes, cancel a lane
    ---delivery still waiting for admission, and leave its scope. A delivery the
    ---lane already admitted finishes, as the lane's own `Close` lets admitted
    ---work drain. Terminal and idempotent.
    ---@param member table
    ---@return boolean closed `false` when it was already closed.
    local function closeTimedMember(member)
        if rawget(member, "_closed") == true then
            return false
        end
        rawset(member, "_closed", true)
        unlinkMember(member)

        local firstError = nil
        local cancel = rawget(member, "_kind") == "debounce" and cancelDebounce or cancelCoalesce
        local ok, value = pcall(cancel, member)
        if not ok then
            firstError = { value = value }
        end

        local deliveryJob = rawget(member, "_deliveryJob")
        if deliveryJob ~= false and rawget(deliveryJob, "_laneAdmitted") ~= true then
            local cancelOk, cancelError = pcall(cancelJob, deliveryJob)
            if not cancelOk and firstError == nil then
                firstError = { value = cancelError }
            end
        end

        if firstError ~= nil then
            error(firstError.value, 0)
        end
        return true
    end

    ---Cancel what every member of `scope` owes, keeping Debounce and Coalesce
    ---handles usable. A watcher has nothing owed but its polling, so it is
    ---cancelled. Best effort; the first failure is returned, not raised.
    ---@param scope SchedulerKit.Scope
    ---@return SchedulerKit.ErrorRecord|nil firstError
    function cancelFamilyMembers(scope)
        local firstError = nil
        local member = rawget(scope, "_familyHead") or false
        while member ~= false do
            local following = rawget(member, "_familyNext")
            local kind = rawget(member, "_kind")
            local ok, value
            if kind == "debounce" then
                ok, value = pcall(cancelDebounce, member)
            elseif kind == "coalesce" then
                ok, value = pcall(cancelCoalesce, member)
            else
                ok, value = pcall(cancelWatcher, member)
            end
            if not ok and firstError == nil then
                firstError = { value = value }
            end
            member = following
        end
        return firstError
    end

    ---Close every member of `scope`. Best effort; the first failure is returned.
    ---@param scope SchedulerKit.Scope
    ---@return SchedulerKit.ErrorRecord|nil firstError
    function closeFamilyMembers(scope)
        local firstError = nil
        local member = rawget(scope, "_familyHead") or false
        while member ~= false do
            local close = rawget(member, "_kind") == "watch" and cancelWatcher or closeTimedMember
            local ok, value = pcall(close, member)
            if not ok and firstError == nil then
                firstError = { value = value }
            end
            -- Every close unlinks before anything that can raise; a member that
            -- somehow stayed linked is unlinked here so the loop terminates.
            if rawget(member, "_linked") == true then
                unlinkMember(member)
            end
            member = rawget(scope, "_familyHead") or false
        end
        return firstError
    end

    ---Route a TimerKit wake to the member or lane that armed the timer.
    ---@param owner table
    local function familyWake(owner)
        local kind = rawget(owner, "_kind")
        if kind == "debounce" then
            debounceWake(owner)
        elseif kind == "coalesce" then
            coalesceWake(owner)
        elseif kind == "lane" then
            laneWake(owner)
        end
    end

    ---Route a lane delivery job to its member.
    ---@param member table
    ---@return any ...
    local function runDelivery(member)
        if rawget(member, "_kind") == "debounce" then
            return runDebounceDelivery(member)
        end
        return runCoalesceDelivery(member)
    end

    -- Member public methods ----------------------------------------------------

    ---Drop the owed fire, if any; the handle stays usable.
    ---@param self SchedulerKit.DebounceHandle
    ---@return boolean dropped whether a fire was owed
    local function debounceHandleCancel(self)
        validateMember(
            self,
            DEBOUNCE_METATABLE,
            "SchedulerKit.DebounceHandle:Cancel",
            "debounce handle"
        )
        return cancelDebounce(self)
    end

    ---Fire now if a fire is owed, ending the burst.
    ---@param self SchedulerKit.DebounceHandle
    ---@return boolean fired `false` when nothing was owed, during the handle's own fire, or when the lane deferred or dropped it.
    ---@return "deferred"|"dropped"|nil reason why a lane did not take the fire
    local function debounceHandleFlush(self)
        validateMember(
            self,
            DEBOUNCE_METATABLE,
            "SchedulerKit.DebounceHandle:Flush",
            "debounce handle"
        )
        if rawget(self, "_firing") == true then
            return false, nil
        end
        if rawget(self, "_waiting") == true then
            cancelOwnerTimer(self)
            rawset(self, "_waiting", false)
        end
        -- An owed fire is flushed even when no window is open, which is how a
        -- handle whose timer could not be armed is recovered by hand.
        if rawget(self, "_trailing") ~= true then
            return false, nil
        end
        local status = deliverDebounce(self)
        if status ~= "delivered" then
            -- Narrowed by the test above.
            return false, status --[[@as "deferred"|"dropped"]]
        end
        return true, nil
    end

    ---Whether a fire is owed and has not been handed off yet.
    ---@param self SchedulerKit.DebounceHandle
    ---@return boolean pending
    local function debounceHandleIsPending(self)
        validateMember(
            self,
            DEBOUNCE_METATABLE,
            "SchedulerKit.DebounceHandle:IsPending",
            "debounce handle"
        )
        return rawget(self, "_trailing") == true
    end

    ---Close the handle: drop what it owes and release it from its scope.
    ---@param self SchedulerKit.DebounceHandle
    ---@return boolean closed `false` when it was already closed.
    local function debounceHandleClose(self)
        validateMember(
            self,
            DEBOUNCE_METATABLE,
            "SchedulerKit.DebounceHandle:Close",
            "debounce handle"
        )
        return closeTimedMember(self)
    end

    ---Whether the handle is closed.
    ---@param self SchedulerKit.DebounceHandle
    ---@return boolean closed
    local function debounceHandleIsClosed(self)
        validateMember(
            self,
            DEBOUNCE_METATABLE,
            "SchedulerKit.DebounceHandle:IsClosed",
            "debounce handle"
        )
        return rawget(self, "_closed") == true
    end

    ---Drop the collected keys; the handle stays usable.
    ---@param self SchedulerKit.CoalesceHandle
    ---@return boolean dropped whether any key was collected
    local function coalesceHandleCancel(self)
        validateMember(
            self,
            COALESCE_METATABLE,
            "SchedulerKit.CoalesceHandle:Cancel",
            "coalesce handle"
        )
        return cancelCoalesce(self)
    end

    ---Deliver the collected keys now instead of at the end of the interval.
    ---@param self SchedulerKit.CoalesceHandle
    ---@return boolean delivered `false` when nothing was collected, during the handle's own delivery, or when the lane deferred or dropped it.
    ---@return "deferred"|"dropped"|nil reason why a lane did not take the delivery
    local function coalesceHandleFlush(self)
        validateMember(
            self,
            COALESCE_METATABLE,
            "SchedulerKit.CoalesceHandle:Flush",
            "coalesce handle"
        )
        if rawget(self, "_keyCount") == 0 or rawget(self, "_firing") == true then
            return false, nil
        end
        if rawget(self, "_deliveryJob") ~= false then
            -- The previous set is still in the lane; the interval timer keeps
            -- running and delivers once that set is done.
            return false, "deferred"
        end
        cancelOwnerTimer(self)
        local status = deliverCoalesce(self)
        if status ~= "delivered" then
            -- Narrowed by the test above.
            return false, status --[[@as "deferred"|"dropped"]]
        end
        return true, nil
    end

    ---Whether keys are collected and waiting for delivery.
    ---@param self SchedulerKit.CoalesceHandle
    ---@return boolean pending
    local function coalesceHandleIsPending(self)
        validateMember(
            self,
            COALESCE_METATABLE,
            "SchedulerKit.CoalesceHandle:IsPending",
            "coalesce handle"
        )
        return rawget(self, "_keyCount") > 0
    end

    ---Return this handle's counters in a table reused by every call.
    ---@param self SchedulerKit.CoalesceHandle
    ---@return SchedulerKit.CoalesceStats stats
    local function coalesceHandleGetStats(self)
        validateMember(
            self,
            COALESCE_METATABLE,
            "SchedulerKit.CoalesceHandle:GetStats",
            "coalesce handle"
        )
        local view = rawget(self, "_statsView")
        if view == false then
            view = {}
            rawset(self, "_statsView", view)
        end
        view.keys = rawget(self, "_keyCount")
        view.refused = rawget(self, "_refused")
        view.delivered = rawget(self, "_delivered")
        view.deferred = rawget(self, "_deferred")
        view.dropped = rawget(self, "_dropped")
        return view
    end

    ---Close the handle: drop the collected keys and release it from its scope.
    ---@param self SchedulerKit.CoalesceHandle
    ---@return boolean closed `false` when it was already closed.
    local function coalesceHandleClose(self)
        validateMember(
            self,
            COALESCE_METATABLE,
            "SchedulerKit.CoalesceHandle:Close",
            "coalesce handle"
        )
        return closeTimedMember(self)
    end

    ---Whether the handle is closed.
    ---@param self SchedulerKit.CoalesceHandle
    ---@return boolean closed
    local function coalesceHandleIsClosed(self)
        validateMember(
            self,
            COALESCE_METATABLE,
            "SchedulerKit.CoalesceHandle:IsClosed",
            "coalesce handle"
        )
        return rawget(self, "_closed") == true
    end

    ---Stop polling. Terminal; releases the interval's ticker with its last watcher.
    ---@param self SchedulerKit.WatchHandle
    ---@return boolean cancelled `false` when it was already cancelled.
    local function watchHandleCancel(self)
        validateMember(self, WATCH_METATABLE, "SchedulerKit.WatchHandle:Cancel", "watch handle")
        return cancelWatcher(self)
    end

    ---Whether the watcher is still polling.
    ---@param self SchedulerKit.WatchHandle
    ---@return boolean active
    local function watchHandleIsActive(self)
        validateMember(self, WATCH_METATABLE, "SchedulerKit.WatchHandle:IsActive", "watch handle")
        return rawget(self, "_closed") ~= true
    end

    -- Family public methods ------------------------------------------------------

    ---Debounce `callback` in this scope.
    ---@param self SchedulerKit.Scope
    ---@param callback function
    ---@param delaySeconds number Finite seconds greater than or equal to zero.
    ---@param options SchedulerKit.DebounceOptions?
    ---@return SchedulerKit.DebounceHandle handle
    local function scopeDebounce(self, callback, delaySeconds, options)
        validateScope(self, "SchedulerKit.Scope:Debounce")
        local handle =
            createDebounce(self, callback, delaySeconds, options, "SchedulerKit.Scope:Debounce")
        return handle
    end

    ---Coalesce keys for `callback` in this scope.
    ---@param self SchedulerKit.Scope
    ---@param callback SchedulerKit.CoalesceCallback
    ---@param intervalSeconds number Finite seconds greater than or equal to zero.
    ---@param options SchedulerKit.CoalesceOptions?
    ---@return SchedulerKit.CoalesceHandle handle
    local function scopeCoalesce(self, callback, intervalSeconds, options)
        validateScope(self, "SchedulerKit.Scope:Coalesce")
        local handle =
            createCoalesce(self, callback, intervalSeconds, options, "SchedulerKit.Scope:Coalesce")
        return handle
    end

    ---Poll `predicate` every `intervalSeconds` in this scope.
    ---@param self SchedulerKit.Scope
    ---@param predicate fun(): any
    ---@param intervalSeconds number Finite seconds greater than zero.
    ---@param callback SchedulerKit.WatchCallback
    ---@param options SchedulerKit.WatchOptions?
    ---@return SchedulerKit.WatchHandle handle
    local function scopeWatch(self, predicate, intervalSeconds, callback, options)
        validateScope(self, "SchedulerKit.Scope:Watch")
        local handle = createWatch(
            self,
            predicate,
            intervalSeconds,
            callback,
            options,
            "SchedulerKit.Scope:Watch"
        )
        return handle
    end

    ---Debounce `callback` in SchedulerKit's package-level scope.
    ---@param _ SchedulerKit
    ---@param callback function
    ---@param delaySeconds number Finite seconds greater than or equal to zero.
    ---@param options SchedulerKit.DebounceOptions?
    ---@return SchedulerKit.DebounceHandle handle
    local function packageDebounce(_, callback, delaySeconds, options)
        local handle = createDebounce(
            getDefaultScope(),
            callback,
            delaySeconds,
            options,
            "SchedulerKit:Debounce"
        )
        return handle
    end

    ---Coalesce keys for `callback` in SchedulerKit's package-level scope.
    ---@param _ SchedulerKit
    ---@param callback SchedulerKit.CoalesceCallback
    ---@param intervalSeconds number Finite seconds greater than or equal to zero.
    ---@param options SchedulerKit.CoalesceOptions?
    ---@return SchedulerKit.CoalesceHandle handle
    local function packageCoalesce(_, callback, intervalSeconds, options)
        local handle = createCoalesce(
            getDefaultScope(),
            callback,
            intervalSeconds,
            options,
            "SchedulerKit:Coalesce"
        )
        return handle
    end

    ---Poll `predicate` in SchedulerKit's package-level scope.
    ---@param _ SchedulerKit
    ---@param predicate fun(): any
    ---@param intervalSeconds number Finite seconds greater than zero.
    ---@param callback SchedulerKit.WatchCallback
    ---@param options SchedulerKit.WatchOptions?
    ---@return SchedulerKit.WatchHandle handle
    local function packageWatch(_, predicate, intervalSeconds, callback, options)
        local handle = createWatch(
            getDefaultScope(),
            predicate,
            intervalSeconds,
            callback,
            options,
            "SchedulerKit:Watch"
        )
        return handle
    end

    ---Return the shared lane called `name`, creating it with `options` first.
    ---@param _ SchedulerKit
    ---@param name string
    ---@param options SchedulerKit.LaneOptions?
    ---@return SchedulerKit.Lane lane
    local function packageLane(_, name, options)
        local lane = getOrCreateLane(name, options, "SchedulerKit:Lane")
        return lane
    end

    -- Family commit ---------------------------------------------------------------

    rawset(Scope, "Debounce", scopeDebounce)
    rawset(Scope, "Coalesce", scopeCoalesce)
    rawset(Scope, "Watch", scopeWatch)

    local DEBOUNCE_PROTOTYPE = rawget(FAMILY_PROTOTYPES, "debounce")
    rawset(DEBOUNCE_PROTOTYPE, "Cancel", debounceHandleCancel)
    rawset(DEBOUNCE_PROTOTYPE, "Flush", debounceHandleFlush)
    rawset(DEBOUNCE_PROTOTYPE, "IsPending", debounceHandleIsPending)
    rawset(DEBOUNCE_PROTOTYPE, "Close", debounceHandleClose)
    rawset(DEBOUNCE_PROTOTYPE, "IsClosed", debounceHandleIsClosed)
    rawset(DEBOUNCE_METATABLE, "__call", debounceCall)

    local COALESCE_PROTOTYPE = rawget(FAMILY_PROTOTYPES, "coalesce")
    rawset(COALESCE_PROTOTYPE, "Cancel", coalesceHandleCancel)
    rawset(COALESCE_PROTOTYPE, "Flush", coalesceHandleFlush)
    rawset(COALESCE_PROTOTYPE, "IsPending", coalesceHandleIsPending)
    rawset(COALESCE_PROTOTYPE, "GetStats", coalesceHandleGetStats)
    rawset(COALESCE_PROTOTYPE, "Close", coalesceHandleClose)
    rawset(COALESCE_PROTOTYPE, "IsClosed", coalesceHandleIsClosed)
    rawset(COALESCE_METATABLE, "__call", coalesceCall)

    local WATCH_PROTOTYPE = rawget(FAMILY_PROTOTYPES, "watch")
    rawset(WATCH_PROTOTYPE, "Cancel", watchHandleCancel)
    rawset(WATCH_PROTOTYPE, "IsActive", watchHandleIsActive)

    local LANE_PROTOTYPE = rawget(FAMILY_PROTOTYPES, "lane")
    rawset(LANE_PROTOTYPE, "Submit", laneSubmit)
    rawset(LANE_PROTOTYPE, "GetStats", laneGetStats)
    rawset(LANE_PROTOTYPE, "GetName", laneGetName)
    rawset(LANE_PROTOTYPE, "Close", laneClose)
    rawset(LANE_PROTOTYPE, "IsClosed", laneIsClosed)

    rawset(SchedulerKit, "Debounce", packageDebounce)
    rawset(SchedulerKit, "Coalesce", packageCoalesce)
    rawset(SchedulerKit, "Watch", packageWatch)
    rawset(SchedulerKit, "Lane", packageLane)

    local familyDispatch = rawget(state, "dispatch")
    rawset(familyDispatch, "familyWake", familyWake)
    rawset(familyDispatch, "watchTick", watchTick)
    rawset(familyDispatch, "runDelivery", runDelivery)
end

installCoalescingFamily()

-- Scope cleanup -------------------------------------------------------------

---Cancel every job of `scope`, keeping the scope itself usable.
---@param scope SchedulerKit.Scope
---@return boolean cancelled
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

    local familyError = cancelFamilyMembers(scope)
    if firstError == nil then
        firstError = familyError
    end

    if firstError ~= nil then
        error(firstError.value, 0)
    end
    return true
end

---Terminally close `scope`, its jobs, its subscription and its timer scope.
---@param scope SchedulerKit.Scope
---@return boolean closed `false` when the scope was already closed.
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

    local familyError = closeFamilyMembers(scope)
    if firstError == nil then
        firstError = familyError
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

---Build the addon-owned scope for `addonName` and bind it to addon shutdown.
---@param addonName string
---@return SchedulerKit.Scope
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

---Return the job this context belongs to.
---@param self SchedulerKit.Context
---@return SchedulerKit.Job job
local function contextGetJob(self)
    validateContext(self, "SchedulerKit.Context:GetJob")
    return rawget(self, "_job")
end

---Whether the running job has been cancelled and should return early.
---@param self SchedulerKit.Context
---@return boolean cancelled
local function contextIsCancelled(self)
    validateContext(self, "SchedulerKit.Context:IsCancelled")
    return rawget(rawget(self, "_job"), "_state") == "cancelled"
end

---Whether this slice has used its share of the frame budget.
---
---Callable only while the owning job is the one currently running.
---@param self SchedulerKit.Context
---@return boolean shouldYield
local function contextShouldYield(self)
    validateContext(self, "SchedulerKit.Context:ShouldYield")
    local job = rawget(self, "_job")
    local jobState = rawget(job, "_state")
    if
        rawget(state, "currentJob") ~= job
        or (jobState ~= "running" and jobState ~= "cancelled")
    then
        error("SchedulerKit.Context:ShouldYield may only be called while its job is running", 2)
    end
    if jobState == "cancelled" then
        return true
    end

    return frameBudgetExhausted()
end

---Suspend the running job until the scheduler resumes it again.
---
---Lua 5.1 cannot yield across a `pcall`, a metamethod or any other C-call
---boundary, so this must be called directly from the job's own callback.
---@param self SchedulerKit.Context
local function contextYield(self)
    validateContext(self, "SchedulerKit.Context:Yield")
    local job = rawget(self, "_job")
    local jobState = rawget(job, "_state")
    if
        rawget(state, "currentJob") ~= job
        or (jobState ~= "running" and jobState ~= "cancelled")
    then
        error("SchedulerKit.Context:Yield may only be called while its job is running", 2)
    end

    -- Record the intent before suspending. Lua 5.1 refuses to yield across a
    -- pcall, metamethod, or other C-call boundary; if the callback swallows
    -- that error and runs on, the driver sees a slice that ended without the
    -- yield it was promised and reports the silent budget violation.
    rawset(job, "_yieldRequested", true)
    return coroutine.yield(rawget(state, "yieldToken"))
end

-- Job public methods --------------------------------------------------------

---Return the job's logical state.
---@param self SchedulerKit.Job
---@return SchedulerKit.JobState state
local function jobGetState(self)
    validateJob(self, "SchedulerKit.Job:GetState")
    return rawget(self, "_state")
end

---Return the job's current priority lane, which an overrun may have lowered.
---@param self SchedulerKit.Job
---@return integer priority
local function jobGetPriority(self)
    validateJob(self, "SchedulerKit.Job:GetPriority")
    return rawget(self, "_priority")
end

---Return the scope that owns this job.
---@param self SchedulerKit.Job
---@return SchedulerKit.Scope scope
local function jobGetScope(self)
    validateJob(self, "SchedulerKit.Job:GetScope")
    return rawget(self, "_scope")
end

---Return the diagnostic name this job was scheduled with, if any.
---@param self SchedulerKit.Job
---@return string? name
local function jobGetName(self)
    validateJob(self, "SchedulerKit.Job:GetName")
    return rawget(self, "_name")
end

---Whether the job may still run: delayed, queued or currently running.
---@param self SchedulerKit.Job
---@return boolean pending
local function jobIsPending(self)
    validateJob(self, "SchedulerKit.Job:IsPending")
    local jobState = rawget(self, "_state")
    return jobState == "delayed" or jobState == "pending" or jobState == "running"
end

---Whether the job was cancelled.
---@param self SchedulerKit.Job
---@return boolean cancelled
local function jobIsCancelled(self)
    validateJob(self, "SchedulerKit.Job:IsCancelled")
    return rawget(self, "_state") == "cancelled"
end

---Whether the job failed. Pair with `GetError`, whose value may be `nil`.
---@param self SchedulerKit.Job
---@return boolean hasError
local function jobHasError(self)
    validateJob(self, "SchedulerKit.Job:HasError")
    return rawget(self, "_errorPresent") == true
end

---Return the recorded error object, which may itself legitimately be `nil`.
---@param self SchedulerKit.Job
---@return any errorValue
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
---@param self SchedulerKit.Job
---@return string? traceback
local function jobGetErrorTraceback(self)
    validateJob(self, "SchedulerKit.Job:GetErrorTraceback")
    local traceback = rawget(self, "_errorTraceback")
    if traceback == false then
        return nil
    end
    return traceback
end

---Cancel this job.
---@param self SchedulerKit.Job
---@return boolean cancelled `false` when the job was already terminal.
local function jobCancel(self)
    return cancelJob(self)
end

-- Scope public methods ------------------------------------------------------

---Schedule immediately eligible cooperative work in this scope.
---@param self SchedulerKit.Scope
---@param callback SchedulerKit.Callback
---@param options SchedulerKit.ScheduleOptions?
---@return SchedulerKit.Job job
local function scopeSchedule(self, callback, options)
    return scheduleInScope(self, callback, options, "SchedulerKit.Scope:Schedule")
end

---Schedule work that must not run during the current pass.
---@param self SchedulerKit.Scope
---@param callback SchedulerKit.Callback
---@param options SchedulerKit.ScheduleOptions?
---@return SchedulerKit.Job job
local function scopeNextFrame(self, callback, options)
    return scheduleAfterInScope(self, 0, callback, options, false, "SchedulerKit.Scope:NextFrame")
end

---Schedule work to become eligible after `delay` seconds.
---@param self SchedulerKit.Scope
---@param delay number Finite seconds greater than or equal to zero.
---@param callback SchedulerKit.Callback
---@param options SchedulerKit.ScheduleOptions?
---@return SchedulerKit.Job job
local function scopeAfter(self, delay, callback, options)
    return scheduleAfterInScope(self, delay, callback, options, false, "SchedulerKit.Scope:After")
end

---Schedule work that re-arms `interval` seconds after each run completes.
---@param self SchedulerKit.Scope
---@param interval number Finite seconds greater than zero.
---@param callback SchedulerKit.Callback
---@param options SchedulerKit.ScheduleOptions?
---@return SchedulerKit.Job job
local function scopeEvery(self, interval, callback, options)
    return scheduleAfterInScope(self, interval, callback, options, true, "SchedulerKit.Scope:Every")
end

---Cancel every job in this scope while keeping the scope reusable.
---@param self SchedulerKit.Scope
---@return boolean cancelled
local function scopeCancelAll(self)
    return cancelAll(self)
end

---Terminally close this scope after cancelling everything it owns.
---@param self SchedulerKit.Scope
---@return boolean closed `false` when the scope was already closed.
local function scopeClose(self)
    return closeScope(self)
end

---Whether this scope is terminally closed.
---@param self SchedulerKit.Scope
---@return boolean closed
local function scopeIsClosed(self)
    validateScope(self, "SchedulerKit.Scope:IsClosed")
    return rawget(self, "_closed") == true
end

---Return the owning addon name, or `nil` for a manual scope.
---@param self SchedulerKit.Scope
---@return string? addonName
local function scopeGetAddonName(self)
    validateScope(self, "SchedulerKit.Scope:GetAddonName")
    return rawget(self, "_addonName")
end

---Number of jobs of this scope that have not reached a terminal state.
---@param self SchedulerKit.Scope
---@return integer activeCount
local function scopeGetActiveCount(self)
    validateScope(self, "SchedulerKit.Scope:GetActiveCount")
    return rawget(self, "_activeCount")
end

-- Package public API --------------------------------------------------------

---Schedule work in SchedulerKit's internal manual scope.
---@param _ SchedulerKit
---@param callback SchedulerKit.Callback
---@param options SchedulerKit.ScheduleOptions?
---@return SchedulerKit.Job job
local function packageSchedule(_, callback, options)
    return scheduleInScope(getDefaultScope(), callback, options, "SchedulerKit:Schedule")
end

---Schedule next-pass work in SchedulerKit's internal manual scope.
---@param _ SchedulerKit
---@param callback SchedulerKit.Callback
---@param options SchedulerKit.ScheduleOptions?
---@return SchedulerKit.Job job
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

---Schedule delayed work in SchedulerKit's internal manual scope.
---@param _ SchedulerKit
---@param delay number Finite seconds greater than or equal to zero.
---@param callback SchedulerKit.Callback
---@param options SchedulerKit.ScheduleOptions?
---@return SchedulerKit.Job job
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

---Schedule repeating work in SchedulerKit's internal manual scope.
---@param _ SchedulerKit
---@param interval number Finite seconds greater than zero.
---@param callback SchedulerKit.Callback
---@param options SchedulerKit.ScheduleOptions?
---@return SchedulerKit.Job job
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

---Create a manually owned scope, closed only by its owner.
---@return SchedulerKit.Scope scope
local function createScope()
    return newScope(nil)
end

---Return the shared LifecycleKit-owned scheduler scope for an addon.
---@param _ SchedulerKit
---@param addonName string addon folder name, as LifecycleKit matches it
---@return SchedulerKit.Scope scope
local function forAddon(_, addonName)
    validateNonEmptyString(addonName, "SchedulerKit:ForAddon addonName", 3)
    local addonScopes = rawget(state, "addonScopes")
    local scope = rawget(addonScopes, addonName)
    if scope ~= nil then
        return scope
    end
    return createAddonScope(addonName)
end

---Set the addon CPU milliseconds one driver pass may spend.
---@param _ SchedulerKit
---@param milliseconds number Finite and greater than zero.
---@return SchedulerKit self
local function setFrameBudget(_, milliseconds)
    validateFinitePositive(milliseconds, "SchedulerKit:SetFrameBudget milliseconds", false, 3)
    rawset(rawget(state, "config"), "frameBudgetMs", milliseconds)
    return SchedulerKit
end

---Current frame budget in addon CPU milliseconds.
---@return number milliseconds
local function getFrameBudget()
    return rawget(rawget(state, "config"), "frameBudgetMs")
end

---Set the slice length past which a cooperating job is demoted one lane.
---@param _ SchedulerKit
---@param milliseconds number Finite and greater than zero.
---@return SchedulerKit self
local function setRunawayThreshold(_, milliseconds)
    validateFinitePositive(milliseconds, "SchedulerKit:SetRunawayThreshold milliseconds", false, 3)
    rawset(rawget(state, "config"), "runawayThresholdMs", milliseconds)
    return SchedulerKit
end

---Current runaway threshold in addon CPU milliseconds.
---@return number milliseconds
local function getRunawayThreshold()
    return rawget(rawget(state, "config"), "runawayThresholdMs")
end

---Set the hard cap on job resumes in one driver pass.
---@param _ SchedulerKit
---@param count integer Finite and greater than zero.
---@return SchedulerKit self
local function setMaxResumesPerFrame(_, count)
    validatePositiveInteger(count, "SchedulerKit:SetMaxResumesPerFrame count", 3)
    rawset(rawget(state, "config"), "maxResumesPerFrame", count)
    return SchedulerKit
end

---Current per-pass resume cap.
---@return integer count
local function getMaxResumesPerFrame()
    return rawget(rawget(state, "config"), "maxResumesPerFrame")
end

---Number of jobs across every scope that have not reached a terminal state.
---@return integer activeCount
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
