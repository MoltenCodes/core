-- MoltenCodes SchedulerKit
--
-- Cooperative, frame-budgeted scheduling for World of Warcraft addons.
-- SchedulerKit combines deterministic priority queues, resumable coroutine
-- jobs, cancellation scopes and TimerKit-backed delays while keeping the WoW
-- OnUpdate/profiling boundary narrow and testable.
--
-- SchedulerKit requires Registry and TimerKit and nothing else. It keeps one
-- canonical scope per addon (`ForAddon`) that is closed through
-- `CloseAddonScopes` at logout (design constitution, principle 4b). Who makes
-- that call is decided at the addon's first `ForAddon`, from the optional Kits
-- found through `Registry:Find`: a LifecycleKit that lists SchedulerKit in
-- `CLOSES_ADDON_SCOPES` makes it itself; an older LifecycleKit is asked for an
-- `OnShutdown` subscription; without LifecycleKit one package-level EventKit
-- `PLAYER_LOGOUT` connection makes it; with neither, the addon makes it from
-- its own logout handler.
--
-- Contents
-- --------
--   Constants ............. package identity, priorities, defaults
--   Public types .......... LuaCATS declarations for the published surface
--   Dependencies .......... Registry, TimerKit, WoW globals; LifecycleKit
--                           and EventKit (optional)
--   Validation ............ public-surface and shared-state validation
--   Bootstrap ............. Registry registration and revision migration,
--                           including the release of revision-9 shutdown
--                           subscriptions
--   Generic helpers ....... argument validation, clocks, error reporting
--   Scope ownership ....... intrusive active-job links
--   Ready queues .......... per-priority FIFOs and lane occupancy
--   Driver ................ lazy OnUpdate frame installation
--   Job terminal handling . failure, traceback capture, cancellation
--   Job creation/delay .... scopes, jobs, TimerKit-backed delays
--   Execution ............. worker coroutines, cooperative resume and the
--                           frame pass
--   Coalescing family ..... Debounce, Coalesce, Watch and lanes (one design)
--   Scope cleanup ......... bulk cancellation and terminal close
--   Logout coverage ....... who closes an addon scope at logout, decided at
--                           the first ForAddon (LifecycleKit, EventKit, none)
--   Context methods ....... the handle a running callback receives
--   Job methods ........... the handle a scheduling caller receives
--   Scope methods ......... the handle a scope owner receives
--   Package public API .... the facade published through Registry
--   Commit ................ prototype/facade assignment and self-check

local PACKAGE_NAME = "schedulerKit"
local API_GENERATION = 1
local IMPLEMENTATION_REVISION = 22
local REQUIRED_REGISTRY_API = 2
local REQUIRED_TIMER_API = 1
local STATE_SCHEMA = 1
-- The interface SchedulerKit's parts are written against
-- (docs/decisions/0001-kit-core-and-parts.md). Entries of `_state.helpers`
-- are only ever added; a core that must change one adds a new entry and
-- raises this number.
local PART_INTERFACE = 1
-- The last revision that was one whole file, the coalescing family included.
local LAST_WHOLE_REVISION = 21

-- LifecycleKit and EventKit are optional. Each is found through
-- `Registry:Find` when an addon asks for its scope, only to arrange that the
-- scope is closed at logout; SchedulerKit never depends on either.
local OPTIONAL_LIFECYCLE_KIT_API = 1
local OPTIONAL_EVENT_KIT_API = 1
local LOGOUT_EVENT = "PLAYER_LOGOUT"

-- How an addon scope is closed at logout, recorded on the scope as
-- `_logoutRoute`. `false` means "not decided yet" (a scope an older revision
-- created); `LOGOUT_ROUTE_NONE` is re-examined at the next `ForAddon`, because
-- a Kit loaded later may make logout observable.
local LOGOUT_ROUTE_LIFECYCLE = "lifecycleKit"
local LOGOUT_ROUTE_SHUTDOWN_SUBSCRIPTION = "onShutdown"
local LOGOUT_ROUTE_EVENT = "playerLogout"
local LOGOUT_ROUTE_NONE = "none"

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

-- The coalescing family (Debounce, Coalesce, Watch, lanes) lives in the parts;
-- its limits stay here so `SetLimits` and `GetLimits` keep one shape whichever
-- parts are loaded. Every bound below is documented in docs/API.md under
-- "Coalescing and lanes".

-- The package-wide limits below are defaults: `SchedulerKit:SetLimits` changes
-- them (design constitution, principle 4a) and `GetLimits` reads them back.
--
-- A debounce handle keeps the arguments of its last call in a reused slot, so
-- recording a call never allocates. Eight values are staged without a table
-- (the Coalescing part); a wider limit is allowed up to its ceiling, because
-- the slot grows once per handle and is then reused. `UNBOUNDED` is refused.
local DEFAULT_MAX_DEBOUNCE_ARGUMENTS = 8
local MAX_DEBOUNCE_ARGUMENTS_CEILING = 64
-- Watchers sharing one interval share one ticker. The number of distinct
-- intervals is one TimerKit ticker each, so it has a ceiling and refuses
-- `UNBOUNDED`; the watchers on one interval are the consumer's own and may be
-- `UNBOUNDED`.
local DEFAULT_MAX_WATCHERS_PER_INTERVAL = 128
local DEFAULT_MAX_WATCH_INTERVALS = 32
local MAX_WATCH_INTERVALS_CEILING = 256
-- Open lanes are the consumer's own registrations; `UNBOUNDED` is accepted.
local DEFAULT_MAX_LANES = 32

-- Names `SetLimits` recognises, in the order `GetLimits` reads them, with the
-- ceiling each accepts (`false`: none) and whether `UNBOUNDED` is accepted.
local LIMIT_NAMES =
  { "maxLanes", "maxWatchIntervals", "maxWatchersPerInterval", "maxDebounceArguments" }
local LIMIT_CEILINGS = {
  maxLanes = false,
  maxWatchIntervals = MAX_WATCH_INTERVALS_CEILING,
  maxWatchersPerInterval = false,
  maxDebounceArguments = MAX_DEBOUNCE_ARGUMENTS_CEILING,
}
local LIMIT_UNBOUNDED_REFUSALS = {
  maxWatchIntervals = "each interval is one TimerKit ticker",
  maxDebounceArguments = "the argument slot is reused per handle",
}

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
---@field package _scope SchedulerKit.Scope owning scope
---@field package _callback SchedulerKit.Callback|false `false` once terminal
---@field package _priority integer current priority lane
---@field package _name string? diagnostic name
---@field package _interval number|false repeat interval, `false` for a one-shot job
---@field package _state SchedulerKit.JobState
---@field package _generation integer staleness token for delay wake-ups
---@field package _queued boolean whether a live queue node points at the job
---@field package _coroutine thread|false the coroutine its slices run in
---@field package _context SchedulerKit.Context|false `false` once terminal
---@field package _delayTimer TimerKit.Timer|false armed delay, if any
---@field package _active boolean whether the job is linked into its scope
---@field package _scopePrev SchedulerKit.Job|false
---@field package _scopeNext SchedulerKit.Job|false
---@field package _yieldRequested boolean? `Context:Yield()` was called this slice
---@field package _errorPresent boolean? written when the job fails
---@field package _error any written when the job fails
---@field package _errorTraceback (string|false)? written when the job fails
---@field package _lane table|false|nil the lane a submission belongs to
---@field package _laneAdmitted boolean? whether its lane admitted it

---An ownership scope for jobs, closed by its owner or, for an addon scope,
---through `SchedulerKit:CloseAddonScopes`.
---@class SchedulerKit.Scope
---@field Schedule fun(self: SchedulerKit.Scope, callback: SchedulerKit.Callback, options: SchedulerKit.ScheduleOptions?): SchedulerKit.Job
---@field NextFrame fun(self: SchedulerKit.Scope, callback: SchedulerKit.Callback, options: SchedulerKit.ScheduleOptions?): SchedulerKit.Job
---@field After fun(self: SchedulerKit.Scope, delay: number, callback: SchedulerKit.Callback, options: SchedulerKit.ScheduleOptions?): SchedulerKit.Job
---@field Every fun(self: SchedulerKit.Scope, interval: number, callback: SchedulerKit.Callback, options: SchedulerKit.ScheduleOptions?): SchedulerKit.Job
---@field CancelAll fun(self: SchedulerKit.Scope): boolean
---@field Close fun(self: SchedulerKit.Scope): boolean
---@field IsClosed fun(self: SchedulerKit.Scope): boolean
---@field Reopen fun(self: SchedulerKit.Scope): boolean
---@field GetAddonName fun(self: SchedulerKit.Scope): string?
---@field GetActiveCount fun(self: SchedulerKit.Scope): integer
---@field Debounce fun(self: SchedulerKit.Scope, callback: function, delaySeconds: number, options: SchedulerKit.DebounceOptions?): SchedulerKit.DebounceHandle
---@field Coalesce fun(self: SchedulerKit.Scope, callback: SchedulerKit.CoalesceCallback, intervalSeconds: number, options: SchedulerKit.CoalesceOptions?): SchedulerKit.CoalesceHandle
---@field Watch fun(self: SchedulerKit.Scope, predicate: (fun(): any), intervalSeconds: number, callback: SchedulerKit.WatchCallback, options: SchedulerKit.WatchOptions?): SchedulerKit.WatchHandle
---@field package _addonName string? owning addon, `nil` for a manual scope
---@field package _closed boolean
---@field package _activeCount integer
---@field package _head SchedulerKit.Job|false first active job
---@field package _tail SchedulerKit.Job|false last active job
---@field package _timerScope TimerKit.Scope|false created on the first delay
---@field package _familyHead table|false first Debounce, Coalesce or Watch member
---@field package _familyTail table|false last member

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
---@field package _kind "coalesce"
---@field package _scope SchedulerKit.Scope owning scope
---@field package _linked boolean whether the handle is on its scope's member list
---@field package _familyPrev table|false
---@field package _familyNext table|false
---@field package _closed boolean
---@field package _callback SchedulerKit.CoalesceCallback
---@field package _interval number
---@field package _maxKeys integer
---@field package _lane SchedulerKit.Lane|false
---@field package _set table the set collecting keys
---@field package _spare table|false the other set, reused at the next delivery
---@field package _keyCount integer
---@field package _firing boolean whether the callback is running
---@field package _timer TimerKit.Timer|false
---@field package _delivered integer
---@field package _refused integer? absent until a key is refused
---@field package _deferred integer? absent until a delivery is deferred
---@field package _dropped integer? absent until a set is dropped
---@field package _statsView SchedulerKit.CoalesceStats|false|nil the reused `GetStats` table
---@field package _deliverySet table|false|nil the set a lane job delivers
---@field package _deliveryJob SchedulerKit.Job|false|nil the lane job delivering it
---@field package _laneCallback function|false|nil the lane job's callback

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
---@field CloseAddonScopes fun(self: SchedulerKit, addonName: string): boolean
---@field SetFrameBudget fun(self: SchedulerKit, milliseconds: number): SchedulerKit
---@field GetFrameBudget fun(self: SchedulerKit): number
---@field SetRunawayThreshold fun(self: SchedulerKit, milliseconds: number): SchedulerKit
---@field GetRunawayThreshold fun(self: SchedulerKit): number
---@field SetMaxResumesPerFrame fun(self: SchedulerKit, count: integer): SchedulerKit
---@field GetMaxResumesPerFrame fun(self: SchedulerKit): integer
---@field GetActiveCount fun(self: SchedulerKit): integer
---@field Debounce fun(self: SchedulerKit, callback: function, delaySeconds: number, options: SchedulerKit.DebounceOptions?): SchedulerKit.DebounceHandle
---@field Coalesce fun(self: SchedulerKit, callback: SchedulerKit.CoalesceCallback, intervalSeconds: number, options: SchedulerKit.CoalesceOptions?): SchedulerKit.CoalesceHandle
---@field Watch fun(self: SchedulerKit, predicate: (fun(): any), intervalSeconds: number, callback: SchedulerKit.WatchCallback, options: SchedulerKit.WatchOptions?): SchedulerKit.WatchHandle
---@field Lane fun(self: SchedulerKit, name: string, options: SchedulerKit.LaneOptions?): SchedulerKit.Lane
---@field UNBOUNDED table Sentinel a limit takes to be lifted, where that is allowed.
---@field SetLimits fun(self: SchedulerKit, limits: table)
---@field GetLimits fun(self: SchedulerKit): SchedulerKit.Limits
---@field HasPart fun(self: SchedulerKit, name: string): boolean `true` when the named part ("Coalescing", "Lanes" or "Watch") is loaded

---The package-wide limits. `SetLimits` accepts any subset; `GetLimits` returns
---a fresh copy of all of them.
---@class SchedulerKit.Limits
---@field maxLanes integer|table Open lanes; default `32`; `UNBOUNDED` accepted.
---@field maxWatchIntervals integer Distinct watch intervals, one ticker each; default `32`, at most `256`.
---@field maxWatchersPerInterval integer|table Live watchers on one interval; default `128`; `UNBOUNDED` accepted.
---@field maxDebounceArguments integer Arguments one debounce call may carry; default `8`, at most `64`.

-- Dependencies --------------------------------------------------------------

-- The shared MoltenCodes namespace is the one documented global handoff point between independently embedded copies.
-- selene: allow(global_usage)
local namespace = rawget(_G, "MoltenCodes")
local generations = type(namespace) == "table" and rawget(namespace, "Registries") or nil

-- Ask for Registry by generation and fall back to the alias. A future Registry
-- API generation takes over `MoltenCodes.Registry`, so reading the alias first
-- would hand this file a facade whose contract it was not written against.
local Registry = type(generations) == "table" and rawget(generations, REQUIRED_REGISTRY_API) or nil
if type(Registry) == "nil" and type(namespace) == "table" then
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

---Silent lookup of an optional package.
---
---Registry revision 7 added `Find`; an older Registry's `Get` also returns
---`nil` for a missing package, so it is a correct fallback. The method is read
---on every call because an embedded Registry upgrade replaces it in place.
---@param packageName string
---@param api integer
---@return table|nil implementation `nil` when the package is not loaded
local function findOptionalPackage(packageName, api)
  local find = rawget(Registry, "Find")
  if type(find) ~= "function" then
    find = getPackage
  end
  local implementation = find(Registry, packageName, api)
  if type(implementation) ~= "table" then
    return nil
  end
  return implementation
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
-- inspectable. The Retail client publishes no `debug` global, so
-- `captureTraceback` falls back to the client's `debugstack`, resolved beside
-- it; a host with neither simply reports the bare error value instead.
--
-- The main chunk is close to Lua 5.1's limit of 200 locals, so a value needed
-- only while another is resolved lives in a `do` block.
local nativeTraceback
do
  -- selene: allow(global_usage)
  local debugLibrary = rawget(_G, "debug")
  nativeTraceback = type(debugLibrary) == "table" and rawget(debugLibrary, "traceback") or nil
end
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

-- Secret values (Retail 12.0.0 and later) raise when compared, so an argument
-- a check would compare is refused first, at the caller's line. The probe is
-- resolved once, when this file loads: every client defines it before any
-- addon runs. Only when it was absent at load does a check read the global
-- again, accepting it only as a function, so a probe a test host or shim
-- installs later is still honoured. A host without one has no secret values.

-- issecretvalue is a World of Warcraft client API reachable only through the global table.
-- selene: allow(global_usage)
local loadedIsSecretValue = rawget(_G, "issecretvalue")
if type(loadedIsSecretValue) ~= "function" then
  loadedIsSecretValue = nil
end

-- The helpers below are assigned in one `do` block, so the per-call fallback
-- costs the main chunk no local of its own.
local refuseSecretValue
-- The bare probe, for hot paths that build their error label only on refusal.
---@type fun(value: any): boolean
local isSecretValue
do
  ---The probe a check should call: the one resolved at load, else the global
  ---as it stands now, else `nil`.
  ---@return (fun(value: any): boolean)|nil
  local function currentSecretProbe()
    local probe = loadedIsSecretValue
    if probe ~= nil then
      return probe
    end
    -- selene: allow(global_usage)
    probe = rawget(_G, "issecretvalue")
    if type(probe) ~= "function" then
      return nil
    end
    return probe
  end

  ---Raise `<label> must not be a secret value` when `value` is secret.
  ---@param value any
  ---@param label string argument description, used in the argument error
  ---@param level integer stack level the failure is reported at
  function refuseSecretValue(value, label, level)
    local probe = currentSecretProbe()
    if probe ~= nil and probe(value) then
      error(label .. " must not be a secret value", level)
    end
  end

  ---Whether `value` is a secret value; always `false` on a host without them.
  ---@param value any
  ---@return boolean
  function isSecretValue(value)
    local probe = currentSecretProbe()
    return probe ~= nil and probe(value) == true
  end
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
    and type(rawget(implementation, "CloseAddonScopes")) == "function"
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
    and type(rawget(implementation, "UNBOUNDED")) == "table"
    and type(rawget(implementation, "SetLimits")) == "function"
    and type(rawget(implementation, "GetLimits")) == "function"
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

---Whether `value` is an integer from 1 to `ceiling` (`false`: no ceiling), or
---`sentinel` when `acceptsUnbounded`.
---@param value any
---@param ceiling integer|false
---@param sentinel table|nil
---@param acceptsUnbounded boolean
---@return boolean
local function isLimitValue(value, ceiling, sentinel, acceptsUnbounded)
  if sentinel ~= nil and value == sentinel then
    return acceptsUnbounded
  end
  return type(value) == "number"
    and value >= 1
    and value ~= math.huge
    and math.floor(value) == value
    and (ceiling == false or value <= ceiling)
end

---Whether `currentState` carries the `UNBOUNDED` sentinel and a valid set of
---package-wide limits (revision 11).
---@param currentState table
---@return boolean
local function validateLimitState(currentState)
  local sentinel = rawget(currentState, "unbounded")
  local limits = rawget(currentState, "limits")
  if type(sentinel) ~= "table" or type(limits) ~= "table" then
    return false
  end
  for index = 1, #LIMIT_NAMES do
    local name = LIMIT_NAMES[index]
    local acceptsUnbounded = LIMIT_UNBOUNDED_REFUSALS[name] == nil
    if not isLimitValue(rawget(limits, name), LIMIT_CEILINGS[name], sentinel, acceptsUnbounded) then
      return false
    end
  end
  return true
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

  -- Revision 11 limits, checked here for the same reason.
  if not validateLimitState(currentState) then
    return false
  end

  -- Revision 22 parts, seeded into older state below.
  if
    type(rawget(currentState, "parts")) ~= "table"
    or type(rawget(currentState, "helpers")) ~= "table"
    or type(rawget(currentState, "familyHelpers")) ~= "table"
    or type(rawget(currentState, "partInterface")) ~= "number"
  then
    return false
  end

  -- Revision 12 logout fallback, seeded into older state below.
  if
    rawget(currentState, "logoutConnection") == nil
    or rawget(currentState, "logoutEventScope") == nil
  then
    return false
  end

  -- Revision 18 worker coroutines, seeded into older state below.
  if
    type(rawget(currentState, "workerFinished")) ~= "table"
    or type(rawget(currentState, "idleWorkers")) ~= "table"
    or type(rawget(currentState, "idleWorkerCount")) ~= "number"
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

if type(SchedulerKit) == "nil" then
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

if type(previousRevision) == "nil" then
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
    -- `SchedulerKit.UNBOUNDED`, kept in state so every revision publishes
    -- the same table.
    unbounded = {},
    -- The package-wide limits `SetLimits` writes; a newer copy inherits
    -- what a consumer set.
    limits = false,
    -- The one EventKit `PLAYER_LOGOUT` connection that closes addon scopes
    -- when no LifecycleKit does, and the EventKit scope that owns it;
    -- `false` until an addon needs them.
    logoutConnection = false,
    logoutEventScope = false,
    -- Worker coroutines (revision 18): the token a worker yields when its
    -- job's callback returned, and the idle workers waiting for a job.
    workerFinished = {},
    idleWorkers = {},
    idleWorkerCount = 0,
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

-- Revision 22 moves the coalescing family into parts. A state without
-- `parts` was written by a whole-file revision, which carried every part; what
-- it made is settled on the next frame, once the parts loaded with this core
-- have had their turn (see "Parts").
local inheritedWholeRevision = nil
if type(previousRevision) ~= "nil" and type(rawget(state, "parts")) ~= "table" then
  inheritedWholeRevision = previousRevision
end
if type(rawget(state, "parts")) ~= "table" then
  rawset(state, "parts", {})
end
if type(rawget(state, "helpers")) ~= "table" then
  rawset(state, "helpers", {})
end
if type(rawget(state, "familyHelpers")) ~= "table" then
  rawset(state, "familyHelpers", {})
end
if
  type(rawget(state, "partInterface")) ~= "number"
  or rawget(state, "partInterface") < PART_INTERFACE
then
  rawset(state, "partInterface", PART_INTERFACE)
end

-- Revision 10 no longer requires LifecycleKit. Revisions 9 and older
-- subscribed every addon scope to its addon's shutdown; this revision leaves
-- the scope open until whoever observes the shutdown calls `CloseAddonScopes`
-- (LifecycleKit does so at logout). An inherited subscription is disconnected
-- here so the scope is not closed from two places. The release is
-- best-effort: a subscription that cannot be disconnected is dropped all the
-- same, because its wrapper resolves `dispatch.closeScope` at call time and
-- closing a closed scope is a no-op.
if type(previousRevision) ~= "nil" and previousRevision < IMPLEMENTATION_REVISION then
  for _, addonScope in pairs(rawget(state, "addonScopes")) do
    if type(addonScope) == "table" then
      local subscription = rawget(addonScope, "_shutdownSubscription")
      rawset(addonScope, "_shutdownSubscription", nil)
      if type(subscription) == "table" and type(subscription.Disconnect) == "function" then
        pcall(subscription.Disconnect, subscription)
      end
    end
  end
end

-- Revision 11 adds the `UNBOUNDED` sentinel and the package-wide limits. Older
-- state is seeded with the constants those revisions enforced, so behaviour
-- carries over until a consumer calls `SetLimits`.
if type(rawget(state, "unbounded")) ~= "table" then
  rawset(state, "unbounded", {})
end
if type(rawget(state, "limits")) ~= "table" then
  rawset(state, "limits", {
    maxLanes = DEFAULT_MAX_LANES,
    maxWatchIntervals = DEFAULT_MAX_WATCH_INTERVALS,
    maxWatchersPerInterval = DEFAULT_MAX_WATCHERS_PER_INTERVAL,
    maxDebounceArguments = DEFAULT_MAX_DEBOUNCE_ARGUMENTS,
  })
end
local UNBOUNDED = rawget(state, "unbounded")
local sharedLimits = rawget(state, "limits")

-- Revision 12 adds the logout fallback without a schema change. Older state
-- has neither field; its addon scopes are given a logout route at the end of
-- the bootstrap, once the functions that decide one exist.
if rawget(state, "logoutConnection") == nil then
  rawset(state, "logoutConnection", false)
end
if rawget(state, "logoutEventScope") == nil then
  rawset(state, "logoutEventScope", false)
end

-- Revision 18 adds worker coroutines (see "Worker coroutines"). Older state
-- has none; the jobs an older copy started keep their own coroutines, which
-- still end by returning, and the driver recognises both endings. The idle
-- workers are dropped at every upgrade, so a newer copy never resumes a
-- worker body it did not write.
if type(rawget(state, "workerFinished")) ~= "table" then
  rawset(state, "workerFinished", {})
end
if type(previousRevision) ~= "nil" and previousRevision < IMPLEMENTATION_REVISION then
  rawset(state, "idleWorkers", nil)
end
if type(rawget(state, "idleWorkers")) ~= "table" then
  rawset(state, "idleWorkers", {})
  rawset(state, "idleWorkerCount", 0)
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
  refuseSecretValue(value, label, (level or 3) + 1)
  if type(value) ~= "string" or value == "" then
    error(label .. " must be a non-empty string", level or 3)
  end
end

---@param value any
---@param label string argument description, used in the argument error
---@param allowZero boolean whether zero is accepted
---@param level integer? stack level the failure is reported at; defaults to `3`
local function validateFinitePositive(value, label, allowZero, level)
  refuseSecretValue(value, label, (level or 3) + 1)
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
  refuseSecretValue(value, label, (level or 3) + 1)
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
  refuseSecretValue(priority, label, (level or 3) + 1)
  if type(priority) == "nil" then
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

---Name a caller's table key in a refusal without running its `__tostring`.
---A string is shown as written and a number or boolean through `tostring`,
---which runs no foreign code for those types; anything else is named by its
---type, `<table>`, because a table's or userdata's `__tostring` is the
---caller's code, which could raise or answer a secret and so lose the real
---refusal. Callers refuse a secret key before naming it.
---@param key any a table key, which can never be `nil`
---@return string
local function describeKey(key)
  local kind = type(key)
  if kind == "string" then
    return key
  end
  if kind == "number" or kind == "boolean" then
    return tostring(key)
  end
  return "<" .. kind .. ">"
end

---Validate one scheduling option table and apply its defaults.
---
---Every argument error names the public method's caller. `error` counts
---levels from the function that calls it, so this function raises its own
---errors at level 4 (itself, the scheduling helper, the public method, the
---caller) and hands level 5 to the validators it calls. That holds only while
---the public method calls the helper without a tail call; see "Argument errors
---and tail calls" below.
---@param options any
---@param methodName string public method name, used in the argument errors
---@return integer priority
---@return string|nil name
local function validateOptions(options, methodName)
  if type(options) == "nil" then
    return PRIORITY_NORMAL, nil
  end
  if type(options) ~= "table" then
    error(methodName .. " options must be a table", 4)
  end

  -- Every job creation passes through here, so the error labels are built
  -- only once a check has failed: the checks themselves are the same, in the
  -- same order, as the validators that raise.
  local unknown = nil
  for key in pairs(options) do
    -- A secret key would raise at the table read below with no useful line;
    -- it is refused first, at the caller's.
    if isSecretValue(key) then
      refuseSecretValue(key, methodName .. " options field name", 5)
    end
    if SCHEDULING_OPTION_KEYS[key] ~= true then
      local display = describeKey(key)
      if unknown == nil or display < unknown then
        unknown = display
      end
    end
  end
  if unknown ~= nil then
    error(methodName .. ' options contains unknown field "' .. unknown .. '"', 4)
  end

  local priority = rawget(options, "priority")
  if type(priority) == "nil" then
    priority = PRIORITY_NORMAL
  else
    priority = validatePriority(priority, methodName .. " priority", 5)
  end
  local name = rawget(options, "name")
  if type(name) ~= "nil" and (type(name) ~= "string" or isSecretValue(name) or name == "") then
    validateNonEmptyString(name, methodName .. " name", 5)
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
  local deadline = state.frameDeadline
  if type(deadline) ~= "number" then
    return false
  end

  local reading = now()
  local previous = state.frameReading
  if type(previous) ~= "number" then
    -- No reference point: state inherited from a revision that did not keep
    -- one. Adopt this reading and charge the frame from here.
    state.frameReading = reading
    return false
  end

  if reading < previous then
    -- `deadline - previous` is the budget left at the previous reading.
    -- Carry that remainder across the reset instead of the absolute value.
    deadline = reading + (deadline - previous)
    state.frameDeadline = deadline
  end

  state.frameReading = reading
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
  -- `getmetatable` never raises and answers SchedulerKit's private metatable
  -- only for a value that carries it, which only a table can, so a `type`
  -- test first would prove nothing more. The same holds for every receiver
  -- check below.
  if getmetatable(scope) ~= SCOPE_METATABLE then
    error(methodName .. " must be called on a SchedulerKit scope", 3)
  end
end

---@param job any receiver the public method was called on
---@param methodName string public method name, used in the argument error
local function validateJob(job, methodName)
  if getmetatable(job) ~= JOB_METATABLE then
    error(methodName .. " must be called on a SchedulerKit job", 3)
  end
end

---@param context any receiver the public method was called on
---@param methodName string public method name, used in the argument error
local function validateContext(context, methodName)
  if getmetatable(context) ~= CONTEXT_METATABLE then
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
  local tail = scope._tail
  job._scopePrev = tail
  job._scopeNext = false
  if tail ~= false then
    tail._scopeNext = job
  else
    scope._head = job
  end
  scope._tail = job
  scope._activeCount = scope._activeCount + 1
  state.activeCount = state.activeCount + 1
end

---Remove `job` from its scope's intrusive active list, once.
---@param scope SchedulerKit.Scope
---@param job SchedulerKit.Job
local function unlinkActive(scope, job)
  if job._active ~= true then
    return
  end

  local previous = job._scopePrev
  local following = job._scopeNext
  if previous ~= false then
    previous._scopeNext = following
  else
    scope._head = following
  end
  if following ~= false then
    following._scopePrev = previous
  else
    scope._tail = previous
  end

  job._scopePrev = false
  job._scopeNext = false
  job._active = false
  scope._activeCount = scope._activeCount - 1
  state.activeCount = state.activeCount - 1
end

-- Ready queues --------------------------------------------------------------

-- Lane occupancy is a conservative "this lane's backing array is non-empty"
-- hint: a lane holding only stale cancelled nodes still counts as occupied, and
-- the flag is cleared the moment a drain resets the lane's indices. A cleared
-- flag therefore always means "definitely nothing here", which is what lets
-- ready selection skip a lane without paying for a queue probe.
---@param priority integer
local function markLaneOccupied(priority)
  local laneOccupied = state.laneOccupied --[[@as table<integer, boolean>]]
  if laneOccupied[priority] ~= true then
    laneOccupied[priority] = true
    state.occupiedLaneCount = state.occupiedLaneCount + 1
  end
end

---@param priority integer
local function markLaneEmpty(priority)
  local laneOccupied = state.laneOccupied --[[@as table<integer, boolean>]]
  if laneOccupied[priority] == true then
    laneOccupied[priority] = false
    state.occupiedLaneCount = state.occupiedLaneCount - 1
  end
end

---Enqueue `job` in its own priority lane, at most once.
---@param job SchedulerKit.Job
local function queuePush(job)
  if job._queued == true then
    return
  end
  local priority = job._priority
  local queue = state.queues[priority]
  local tail = queue.tail + 1
  queue.tail = tail
  queue.items[tail] = job
  job._queued = true
  markLaneOccupied(priority)
end

---Restart a drained lane at the front and clear its occupancy flag, so the
---indices of a lane that is never left empty for long (one job yielding slice
---after slice) keep reusing slot 1 instead of climbing.
---@param queue SchedulerKit.Queue
---@param priority integer
local function resetDrainedQueue(queue, priority)
  queue.head = 1
  queue.tail = 0
  markLaneEmpty(priority)
end

---Take the next live job from one lane, discarding stale entries.
---@param priority integer
---@return SchedulerKit.Job|nil
local function queuePop(priority)
  local queue = state.queues[priority]
  local items = queue.items
  local head = queue.head
  local tail = queue.tail

  while head <= tail do
    local job = items[head]
    items[head] = nil
    head = head + 1

    if type(job) == "table" and job._queued == true and job._state == "pending" then
      job._queued = false
      if head > tail then
        resetDrainedQueue(queue, priority)
      else
        queue.head = head
      end
      return job
    end
  end

  resetDrainedQueue(queue, priority)
  return nil
end

---Whether one lane still holds a job that can run, trimming stale entries.
---@param priority integer
---@return boolean
local function queueHasLive(priority)
  local queue = state.queues[priority]
  local items = queue.items
  local head = queue.head
  local tail = queue.tail

  while head <= tail do
    local job = items[head]
    if type(job) == "table" and job._queued == true and job._state == "pending" then
      return true
    end
    items[head] = nil
    head = head + 1
    queue.head = head
  end

  resetDrainedQueue(queue, priority)
  return false
end

---Whether any lane holds work, which is what decides if the driver runs.
---@return boolean
local function hasReadyJobs()
  if state.occupiedLaneCount == 0 then
    return false
  end

  local laneOccupied = state.laneOccupied --[[@as table<integer, boolean>]]
  for priority = 1, PRIORITY_COUNT do
    if laneOccupied[priority] == true and queueHasLive(priority) then
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
  if state.occupiedLaneCount == 0 then
    return nil
  end

  local laneOccupied = state.laneOccupied --[[@as table<integer, boolean>]]
  -- Only a live IDLE job is starved: a lane holding nothing but cancelled
  -- entries must not earn credit for the next IDLE job to spend at once.
  local idleWaiting = laneOccupied[PRIORITY_IDLE] == true and queueHasLive(PRIORITY_IDLE)
  if not idleWaiting then
    -- Nothing is being starved, so the guard must not accumulate credit
    -- that a later IDLE job could spend immediately.
    state.idleGuard = 0
  elseif state.idleGuard >= IDLE_STARVATION_RESUMES then
    local promoted = queuePop(PRIORITY_IDLE)
    if promoted ~= nil then
      state.idleGuard = 0
      return promoted
    end
    idleWaiting = false
  end

  local slotCount = #PRIORITY_SLOTS
  local cursor = state.priorityCursor
  for _ = 1, slotCount do
    local priority = PRIORITY_SLOTS[cursor]
    cursor = cursor + 1
    if cursor > slotCount then
      cursor = 1
    end
    state.priorityCursor = cursor

    if laneOccupied[priority] == true then
      local job = queuePop(priority)
      if job ~= nil then
        if idleWaiting then
          state.idleGuard = state.idleGuard + 1
        end
        return job
      end
    end
  end

  -- No contending lane is ready, so IDLE work is free to run.
  local job = queuePop(PRIORITY_IDLE)
  if job ~= nil then
    state.idleGuard = 0
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
  if type(frame) == "nil" or type(frame.SetScript) ~= "function" then
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
  local enabled = state.driverEnabled == true
  if needed == enabled then
    return
  end

  local frame = ensureDriver()
  if needed then
    frame:SetScript("OnUpdate", state.driverTrampoline)
    state.driverEnabled = true
  else
    frame:SetScript("OnUpdate", nil)
    state.driverEnabled = false
  end
end

-- Job terminal/error handling ---------------------------------------------

-- The coalescing family's parts build on the job machinery below, and the job
-- machinery tells them when a lane job ends or raises, and when a scope
-- cancels or closes its members, through the dispatch entries
-- `laneJobFinished`, `retryLaneJob`, `cancelFamilyMembers` and
-- `closeFamilyMembers` (see "Parts").

---Release the TimerKit handle a delayed job is holding, if any.
---@param job SchedulerKit.Job
---@return TimerKit.Timer|false delayTimer
local function detachDelayTimer(job)
  local delayTimer = job._delayTimer
  job._delayTimer = false
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
  job._state = terminalState
  job._queued = false
  job._coroutine = false
  job._callback = false
  job._context = false
  job._delayTimer = false
  local scope = job._scope
  unlinkActive(scope, job)
  -- Only a lane submission carries a lane; ordinary jobs pay one read.
  local lane = job._lane
  if lane ~= nil and lane ~= false then
    state.dispatch.laneJobFinished(job, lane, terminalState)
  end
end

---Capture a failing coroutine's stack while the thread is still inspectable.
---Lua 5.1 leaves an errored coroutine's stack in place, so this must run before
---the job's thread reference is dropped.
---
---Two sources, tried in order: `debug.traceback(thread, message)`, which
---standard Lua and Busted publish, and the client's `debugstack(thread)`. The
---Retail client publishes no `debug` global at all (measured on 12.1.0 build
---69933, 2026-09-24), so `debugstack` is the only source there. Its result is
---the bare stack, so the message and a `stack traceback:` header are prefixed
---to give both sources the same "message, then stack traceback:" shape.
---@type fun(thread: thread, value: any): string|false
local captureTraceback
do
  -- `debugstack` is resolved once at load, like `debug.traceback`, inside a
  -- `do` block: the main chunk is close to Lua 5.1's limit of 200 locals and
  -- only `captureTraceback` itself needs it.
  -- selene: allow(global_usage)
  local nativeDebugStack = rawget(_G, "debugstack")
  if type(nativeDebugStack) ~= "function" then
    nativeDebugStack = false
  end

  ---@param thread thread
  ---@param value any Original Lua error object.
  ---@return string|false traceback `false` when the host has neither
  ---`debug.traceback` nor `debugstack`, or the call failed.
  captureTraceback = function(thread, value)
    -- Both sources want a string message: `debug.traceback` returns a
    -- non-string message unchanged, and `debugstack` takes none, so the
    -- error object is rendered with `tostring` to keep the report a
    -- readable string.
    if type(nativeTraceback) == "function" then
      local ok, traceback = pcall(nativeTraceback, thread, tostring(value))
      if not ok or type(traceback) ~= "string" then
        return false
      end
      return traceback
    end
    if nativeDebugStack == false then
      return false
    end
    local ok, stack = pcall(nativeDebugStack, thread)
    if not ok or type(stack) ~= "string" then
      return false
    end
    return tostring(value) .. "\nstack traceback:\n" .. stack
  end
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
---
---`job` is already validated: `Job:Cancel` checks its receiver itself, so the
---wrong-receiver error names the caller's line.
---@param job SchedulerKit.Job
---@return boolean cancelled `false` when the job was already terminal.
local function cancelJob(job)
  local jobState = job._state
  if isTerminalJobState(jobState) then
    return false
  end

  job._generation = job._generation + 1
  job._queued = false
  local delayTimer = detachDelayTimer(job)
  finishJob(job, "cancelled")

  local firstError = nil
  if delayTimer ~= false then
    local ok, value = pcall(delayTimer.Cancel, delayTimer)
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
    _familyHead = false,
    _familyTail = false,
  }, SCOPE_METATABLE)
end

---Return the TimerKit scope backing this scope's delays, creating it lazily.
---@param scope SchedulerKit.Scope
---@return TimerKit.Scope
local function ensureTimerScope(scope)
  local timerScope = scope._timerScope
  if timerScope ~= false then
    return timerScope
  end

  timerScope = TimerKit:CreateScope()
  if type(timerScope) ~= "table" then
    error("MoltenCodes SchedulerKit TimerKit returned an invalid scope", 0)
  end

  scope._timerScope = timerScope
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
  -- At most 15 fields, so the table's hash part is 16 slots rather than 32.
  -- `_errorPresent`, `_error` and `_errorTraceback` are written only when the
  -- job fails and `_yieldRequested` at every slice; an absent one reads as
  -- "no" wherever it is read (`== true`, or `nil` returned as `nil`).
  local job = setmetatable({
    _scope = scope,
    _callback = callback,
    _priority = priority,
    _name = name,
    _interval = interval,
    _state = "pending",
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

---Arm the TimerKit delay behind `job`'s scope. A named function rather than a
---closure, so re-arming a repeating job does not allocate one per iteration.
---@param scope SchedulerKit.Scope
---@param delay number
---@return TimerKit.Timer
local function armScopeTimer(scope, delay)
  return ensureTimerScope(scope):After(delay, delayedWakeCallback)
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
  local scope = job._scope
  if scope._closed == true then
    finishJob(job, "cancelled")
    return false
  end

  job._state = "delayed"
  local ok, timerOrError = pcall(armScopeTimer, scope, delay)

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
  job._delayTimer = timerOrError
  timerOrError:SetUserData(job)
  return true
end

---Return a delayed job to the ready queues, ignoring stale generations.
---@param job SchedulerKit.Job
---@param generation integer|false generation the expired handle was armed for
---@return boolean woken
local function wakeDelayed(job, generation)
  if job._generation ~= generation or job._state ~= "delayed" then
    return false
  end

  job._delayTimer = false
  job._state = "pending"
  -- An admitted lane job waking from its retry backoff starts again, so the
  -- lane's minimum interval is measured from here.
  local lane = job._lane
  if lane ~= nil and lane ~= false and job._laneAdmitted == true then
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

-- Argument errors and tail calls -------------------------------------------
--
-- The scheduling helpers below raise their argument errors at the level of the
-- public method's caller: level 3 for their own `error` calls (helper, public
-- method, caller) and level 4 for the validators they call. That level names
-- the caller only while the public method is still on the stack. A public
-- method ending in `return helper(...)` makes a tail call: its frame is
-- replaced, the level names a vanished frame, and the message carries no
-- position at all (standard Lua 5.1 and the Retail client alike).
-- Every public method therefore keeps the result in a local first
-- (`local job = helper(...)` then `return job`), and a method whose helper
-- validates the receiver validates it itself, before the call.

---Validate and queue one immediately eligible job.
---
---`scope` is already validated by the public method. Argument errors name the
---public method's caller; see "Argument errors and tail calls" above.
---@param scope SchedulerKit.Scope
---@param callback any
---@param options SchedulerKit.ScheduleOptions|nil
---@param methodName string public method name, used in the argument errors
---@return SchedulerKit.Job
local function scheduleInScope(scope, callback, options, methodName)
  if scope._closed == true then
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
---
---`scope` is already validated by the public method. Argument errors name the
---public method's caller; see "Argument errors and tail calls" above.
---@param scope SchedulerKit.Scope
---@param delay any seconds to wait; the repeat interval when `repeating`
---@param callback any
---@param options SchedulerKit.ScheduleOptions|nil
---@param repeating boolean
---@param methodName string public method name, used in the argument errors
---@return SchedulerKit.Job
local function scheduleAfterInScope(scope, delay, callback, options, repeating, methodName)
  if rawget(scope, "_closed") == true then
    error(methodName .. " cannot schedule work in a closed scope", 3)
  end
  -- The label is built only for a value the validator will refuse; the
  -- test below accepts exactly what it accepts.
  if
    type(delay) ~= "number"
    or isSecretValue(delay)
    or delay ~= delay
    or delay == math.huge
    or delay < 0
    or (repeating and delay == 0)
  then
    validateFinitePositive(
      delay,
      methodName .. (repeating and " interval" or " delay"),
      not repeating,
      4
    )
  end
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
  local scope = state.defaultScope
  if scope == false or scope._closed == true then
    scope = newScope(nil)
    state.defaultScope = scope
  end
  return scope
end

-- Execution ----------------------------------------------------------------

-- Worker coroutines -----------------------------------------------------------
--
-- A job's slices run in a coroutine. Rather than one fresh coroutine and
-- closure per job, a job starts on a worker: a coroutine whose body runs one
-- job's callback, yields `state.workerFinished`, and waits there to be resumed
-- with the next job. The driver keeps up to `MAX_IDLE_WORKERS` finished ones.
-- A worker is reused only after its callback returned; one that raised, that
-- yielded anything but the scheduler's tokens, or whose job was cancelled
-- while it was suspended in `Context:Yield()` is simply dropped.

-- Only `acquireWorker` and `retainWorker` escape this block: the main chunk is
-- close to Lua 5.1's limit of 200 locals (see docs/INTERNALS.md).
local acquireWorker, retainWorker
do
  -- Idle workers kept for the next job. A Lua 5.1 coroutine is about 1.2 KB,
  -- so the bound caps what an idle scheduler holds.
  local MAX_IDLE_WORKERS = 4

  ---The body of every worker coroutine. The first resume passes the first job;
  ---each later one resumes the `yield` below with the next job.
  ---
  ---The locals are cleared before the yield, so an idle worker keeps neither the
  ---finished job nor its callback alive.
  ---@param job any the first job; each later one arrives through the `yield`
  local function runWorker(job)
    while true do
      local callback = job._callback
      local context = job._context
      job = nil
      callback(context)
      callback, context = nil, nil
      job = coroutine.yield(state.workerFinished)
    end
  end

  ---Take an idle worker, or create one.
  ---@return thread worker
  function acquireWorker()
    local count = state.idleWorkerCount
    if count > 0 then
      local workers = state.idleWorkers
      local worker = workers[count]
      workers[count] = nil
      state.idleWorkerCount = count - 1
      return worker
    end
    return coroutine.create(runWorker)
  end

  ---Keep a worker whose job's callback returned, unless enough are idle.
  ---@param worker thread suspended at its `yield` of `state.workerFinished`
  function retainWorker(worker)
    local count = state.idleWorkerCount
    if count < MAX_IDLE_WORKERS then
      count = count + 1
      state.idleWorkers[count] = worker
      state.idleWorkerCount = count
    end
  end
end

---Render a job for a diagnostic message. Only reached on failure/overrun
---paths, so the concatenation never touches the normal resume path.
---@param job SchedulerKit.Job
---@return string label
local function describeJob(job)
  local name = job._name
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
  if job._state ~= "pending" then
    return
  end

  job._state = "running"
  job._yieldRequested = false
  state.currentJob = job

  local thread = job._coroutine
  local startTime, ok, yielded
  if thread == false then
    thread = acquireWorker()
    job._coroutine = thread
    startTime = now()
    ok, yielded = coroutine.resume(thread, job)
  else
    startTime = now()
    ok, yielded = coroutine.resume(thread)
  end
  local elapsed = elapsedSince(startTime)
  state.currentJob = false

  if not ok then
    -- A job that cancelled itself and then raised stays cancelled: the
    -- cancellation already finished it, so the raise is neither retried nor
    -- reported as a failure.
    if job._state == "cancelled" then
      return
    end
    -- A lane submission with attempts left is re-armed after its backoff
    -- instead of failing; see the Lanes part.
    local lane = job._lane
    if lane ~= nil and lane ~= false and state.dispatch.retryLaneJob(job, lane) then
      return
    end
    -- Capture the stack before the thread reference is dropped: Lua 5.1
    -- leaves an errored coroutine's frames in place, and after the stack is
    -- gone the report can only name the error value.
    failJob(job, yielded, captureTraceback(thread, yielded))
    return
  end

  -- The callback returned: a worker yields the finished token, and a
  -- coroutine an older revision created for this job has died. The yielded
  -- value comes from the callback only through a raw `coroutine.yield`, so the
  -- type test comes first and a secret value is never compared.
  local finished = type(yielded) == "table" and yielded == state.workerFinished
  if finished then
    retainWorker(thread)
  elseif coroutine.status(thread) == "dead" then
    finished = true
  end

  if job._state == "cancelled" then
    return
  end

  if finished then
    job._coroutine = false
    if job._yieldRequested == true and handleSwallowedYield(job, elapsed) then
      return
    end

    local interval = job._interval
    if interval ~= false then
      job._generation = job._generation + 1
      -- A repeating job is re-armed through TimerKit after its callback
      -- finishes. Host/timer creation failures must not escape the
      -- OnUpdate driver and starve unrelated scheduler work, so the raise
      -- `armDelay` owes its caller becomes a host error report here.
      local rearmOk, rearmError = pcall(armDelay, job, interval)
      if not rearmOk then
        if job._state ~= "failed" then
          markJobFailed(job, "SchedulerKit failed to re-arm a repeating job", false)
        end
        reportError(rearmError)
      end
    else
      finishJob(job, "completed")
    end
    return
  end

  if type(yielded) ~= "table" or yielded ~= state.yieldToken then
    failJob(job, "SchedulerKit jobs may yield only through Context:Yield()", false)
    return
  end

  local threshold = state.config.runawayThresholdMs
  if elapsed > threshold then
    demoteOverrunningJob(job, elapsed, threshold)
  end

  job._state = "pending"
  queuePush(job)
end

---One driver pass: resume ready jobs until the budget or the resume cap ends it.
---The OnUpdate driver passes the frame's elapsed seconds; the pass measures its
---own CPU time instead, so the argument is ignored.
local function runFrame()
  local config = state.config
  local startTime = now()
  state.frameReading = startTime
  state.frameDeadline = startTime + config.frameBudgetMs

  local resumes = 0
  local maxResumes = config.maxResumesPerFrame
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

  state.currentJob = false
  state.frameDeadline = false
  state.frameReading = false
  updateDriver()
end

-- Parts -------------------------------------------------------------------------
--
-- The coalescing family lives in three part files (docs/decisions/
-- 0001-kit-core-and-parts.md): `SchedulerKit-Coalescing` (Debounce,
-- Coalesce and the family's shared machinery), `SchedulerKit-Lanes` and
-- `SchedulerKit-Watch`, which both need Coalescing. An addon embeds the core
-- and only the parts it uses.
--
-- What the core keeps for them, so a part loaded by any addon finds it: the
-- family's shared state (lanes, watch groups, metatables, method tables and
-- limits, seeded in the bootstrap), `_state.parts` (part name to its
-- revision), `_state.helpers` (the core functions a part calls, read at call
-- time), `_state.familyHelpers` (what the parts share with each other) and
-- `_state.partInterface`. The core reaches a part only through dispatch
-- entries; the defaults below stand in while a part is not loaded, and are
-- exact then, because no member of an absent part can exist.
--
-- Every member a part provides stays on the facade, on the scope prototype
-- and on the handle prototypes even without its part: a stub that raises at
-- the caller's line with the file to embed. Other copies test for these
-- members with `type(...) == "function"`, so their public-surface checks keep
-- accepting the facade; Kits that use a part optionally ask `HasPart`.
--
-- A core that takes over from a whole-file revision (21 or older) whose part
-- is not loaded cannot run that part's code. It stubs the members at once
-- (the part, loaded right after the core in the same addon, replaces them
-- before anything runs), and on the next frame closes the live objects of
-- every part still missing and reports once which files to embed.

-- Assigned in the block below; `installPartStubs` runs at commit.
local retireMember
local installPartStubs
local settleWholeRevision
local hasReachableFamilyObjects

do
  -- The members of each part, by the table they sit on. `after` is the file a
  -- part's line follows in embeds.xml.
  local PART_LAYOUT = {
    {
      name = "Coalescing",
      after = "schedulerKit\\SchedulerKit.lua",
      facade = { "Debounce", "Coalesce" },
      scope = { "Debounce", "Coalesce" },
      handles = {
        debounce = { "Cancel", "Flush", "IsPending", "Close", "IsClosed" },
        coalesce = { "Cancel", "Flush", "IsPending", "GetStats", "Close", "IsClosed" },
      },
      hooks = { "cancelFamilyMembers", "closeFamilyMembers", "familyWake", "runDelivery" },
    },
    {
      name = "Lanes",
      after = "schedulerKit\\parts\\SchedulerKit-Coalescing.lua",
      facade = { "Lane" },
      scope = {},
      handles = { lane = { "Submit", "GetStats", "GetName", "Close", "IsClosed" } },
      hooks = { "laneJobFinished", "retryLaneJob" },
    },
    {
      name = "Watch",
      after = "schedulerKit\\parts\\SchedulerKit-Coalescing.lua",
      facade = { "Watch" },
      scope = { "Watch" },
      handles = { watch = { "Cancel", "IsActive" } },
      hooks = { "watchTick" },
    },
  }

  -- The handle labels the stubs name, as the parts' own errors do.
  local HANDLE_LABELS = {
    debounce = "SchedulerKit.DebounceHandle",
    coalesce = "SchedulerKit.CoalesceHandle",
    lane = "SchedulerKit.Lane",
    watch = "SchedulerKit.WatchHandle",
  }

  ---A member that raises, at its caller's line, that `part` is not loaded.
  ---@param label string the member as its caller wrote it
  ---@param part table one entry of `PART_LAYOUT`
  ---@return function
  local function newPartStub(label, part)
    -- The message is built only when the stub raises, so an addon that never
    -- calls a missing part holds no message text for it.
    return function()
      error(
        label
          .. " is in SchedulerKit's "
          .. part.name
          .. " part, which is not loaded: add schedulerKit\\parts\\SchedulerKit-"
          .. part.name
          .. ".lua to embeds.xml after "
          .. part.after,
        2
      )
    end
  end

  ---Close one member of the coalescing family without its part's code: mark
  ---it closed, leave its scope, cancel its timer and a lane delivery still
  ---waiting for admission, and leave its watch group. Terminal, never raises.
  ---@param member table
  ---@return boolean closed `false` when it was already closed
  function retireMember(member)
    if rawget(member, "_closed") == true then
      return false
    end
    rawset(member, "_closed", true)

    local scope = rawget(member, "_scope")
    if rawget(member, "_linked") == true and type(scope) == "table" then
      local previous = rawget(member, "_familyPrev")
      local following = rawget(member, "_familyNext")
      if type(previous) == "table" then
        rawset(previous, "_familyNext", following)
      else
        rawset(scope, "_familyHead", following)
      end
      if type(following) == "table" then
        rawset(following, "_familyPrev", previous)
      else
        rawset(scope, "_familyTail", previous)
      end
      rawset(member, "_familyPrev", false)
      rawset(member, "_familyNext", false)
      rawset(member, "_linked", false)
    end

    local timerHandle = rawget(member, "_timer")
    if type(timerHandle) == "table" then
      rawset(member, "_timer", false)
      pcall(timerHandle.SetUserData, timerHandle, nil)
      pcall(timerHandle.Cancel, timerHandle)
    end

    local deliveryJob = rawget(member, "_deliveryJob")
    if type(deliveryJob) == "table" and rawget(deliveryJob, "_laneAdmitted") ~= true then
      pcall(cancelJob, deliveryJob)
    end

    local group = rawget(member, "_group")
    if type(group) == "table" and type(rawget(group, "live")) == "number" then
      rawset(group, "live", rawget(group, "live") - 1)
    end
    return true
  end

  ---Retire every member on `scope`'s family list; the default of both scope
  ---hooks while the Coalescing part is not loaded.
  ---@param scope SchedulerKit.Scope
  ---@return nil firstError retiring never fails
  local function retireScopeMembers(scope)
    local member = rawget(scope, "_familyHead") or false
    while type(member) == "table" do
      local following = rawget(member, "_familyNext") or false
      retireMember(member)
      member = following
    end
    return nil
  end

  local NO_HANDLES = {}

  ---What every hook does while its part is not loaded and no older whole
  ---revision left members behind: nothing, because nothing can call for it.
  ---A retry answers `nil`, which refuses it.
  local function doNothing() end

  -- What each hook does after a hand-over from a whole-file revision while its
  -- part is not loaded: serve what that revision left behind. Only then are
  -- these closures kept.
  local HOOK_DEFAULTS = {
    cancelFamilyMembers = retireScopeMembers,
    closeFamilyMembers = retireScopeMembers,
    -- A timer an older revision armed wakes a member nobody can serve.
    familyWake = function(owner)
      if type(owner) == "table" and rawget(owner, "_kind") ~= "lane" then
        retireMember(owner)
      end
    end,
    runDelivery = function() end,
    -- A lane job outlives its lane's part: the job finishes as an ordinary one.
    laneJobFinished = function(job)
      rawset(job, "_lane", false)
    end,
    retryLaneJob = function()
      return false
    end,
    -- A ticker an older revision started stops at its next tick.
    watchTick = function(group)
      local ticker = type(group) == "table" and rawget(group, "ticker") or nil
      if type(ticker) == "table" then
        rawset(group, "ticker", false)
        pcall(ticker.Cancel, ticker)
      end
    end,
  }

  ---Install the stubs and hook defaults of every part that is not loaded.
  ---A loaded part, perhaps an older revision another addon embedded, keeps
  ---its members: an upgraded core serves it.
  ---@param handOver boolean whether this core takes over from a whole-file
  ---revision: then the handle methods are stubbed too and the hooks retire
  ---what that revision left. Otherwise no handle of an absent part can exist,
  ---and nothing is spent on them.
  function installPartStubs(handOver)
    local parts = rawget(state, "parts")
    local prototypes = rawget(state, "familyPrototypes")
    local metatables = rawget(state, "familyMetatables")
    local dispatch = rawget(state, "dispatch")
    for index = 1, #PART_LAYOUT do
      local part = PART_LAYOUT[index]
      if type(rawget(parts, part.name)) ~= "table" then
        for _, name in ipairs(part.facade) do
          rawset(SchedulerKit, name, newPartStub("SchedulerKit:" .. name, part))
        end
        for _, name in ipairs(part.scope) do
          rawset(Scope, name, newPartStub("SchedulerKit.Scope:" .. name, part))
        end
        for kind, methods in pairs(handOver and part.handles or NO_HANDLES) do
          local prototype = rawget(prototypes, kind)
          for _, name in ipairs(methods) do
            rawset(prototype, name, newPartStub(HANDLE_LABELS[kind] .. ":" .. name, part))
          end
          if kind == "debounce" or kind == "coalesce" then
            rawset(
              rawget(metatables, kind),
              "__call",
              newPartStub("SchedulerKit " .. kind .. " handle", part)
            )
          end
        end
        for _, hook in ipairs(part.hooks) do
          rawset(dispatch, hook, handOver and HOOK_DEFAULTS[hook] or doNothing)
        end
      end
    end
  end

  ---Close every lane without the Lanes part: refuse new work, cancel what
  ---waits, and let admitted jobs finish as ordinary jobs.
  ---@return integer closed
  local function retireLanes()
    local closed = 0
    for name, lane in pairs(rawget(state, "lanes")) do
      rawset(rawget(state, "lanes"), name, nil)
      if type(lane) == "table" and rawget(lane, "_closed") ~= true then
        rawset(lane, "_closed", true)
        closed = closed + 1
        local timerHandle = rawget(lane, "_timer")
        if type(timerHandle) == "table" then
          rawset(lane, "_timer", false)
          pcall(timerHandle.Cancel, timerHandle)
        end
        local items = rawget(lane, "_items")
        if type(items) == "table" then
          for _, job in pairs(items) do
            if type(job) == "table" and rawget(job, "_state") == "delayed" then
              pcall(cancelJob, job)
            end
          end
        end
        local admitted = rawget(lane, "_admitted")
        if type(admitted) == "table" then
          for job in pairs(admitted) do
            if rawget(job, "_state") == "delayed" then
              pcall(cancelJob, job)
            end
          end
        end
      end
    end
    rawset(state, "laneCount", 0)
    return closed
  end

  ---Stop every watch ticker and close every watcher without the Watch part.
  ---@return integer closed
  local function retireWatchers()
    local closed = 0
    for interval, group in pairs(rawget(state, "watchGroups")) do
      rawset(rawget(state, "watchGroups"), interval, nil)
      local ticker = rawget(group, "ticker")
      if type(ticker) == "table" then
        rawset(group, "ticker", false)
        pcall(ticker.Cancel, ticker)
      end
      rawset(group, "released", true)
      for _, watcher in ipairs(rawget(group, "watchers")) do
        if retireMember(watcher) then
          closed = closed + 1
        end
      end
    end
    rawset(state, "watchGroupCount", 0)
    return closed
  end

  ---Close the Debounce and Coalesce handles in every scope the state can
  ---reach: the addon scopes and the package-level scope. A handle in a
  ---manual scope is reached when it is called (the stub raises) or wakes.
  ---@return integer closed
  local function retireTimedMembers()
    local closed = 0
    local scopes = {}
    for _, scope in pairs(rawget(state, "addonScopes")) do
      scopes[#scopes + 1] = scope
    end
    if type(rawget(state, "defaultScope")) == "table" then
      scopes[#scopes + 1] = rawget(state, "defaultScope")
    end
    for _, scope in ipairs(scopes) do
      local member = type(scope) == "table" and rawget(scope, "_familyHead") or false
      while type(member) == "table" do
        local following = rawget(member, "_familyNext") or false
        local kind = rawget(member, "_kind")
        if (kind == "debounce" or kind == "coalesce") and retireMember(member) then
          closed = closed + 1
        end
        member = following
      end
    end
    return closed
  end

  ---Whether the state holds a lane, a watch group, or a member in an addon
  ---scope or the package-level scope: what a hand-over would have to settle.
  ---@return boolean
  function hasReachableFamilyObjects()
    if next(rawget(state, "lanes")) ~= nil or next(rawget(state, "watchGroups")) ~= nil then
      return true
    end
    for _, scope in pairs(rawget(state, "addonScopes")) do
      if type(scope) == "table" and type(rawget(scope, "_familyHead")) == "table" then
        return true
      end
    end
    local defaultScope = rawget(state, "defaultScope")
    return type(defaultScope) == "table" and type(rawget(defaultScope, "_familyHead")) == "table"
  end

  ---After a hand-over from a whole-file revision: close the live objects of
  ---every part that is still not loaded, and say once which files to embed.
  ---@param inheritedRevision integer the whole-file revision taken over
  function settleWholeRevision(inheritedRevision)
    local parts = rawget(state, "parts")
    local missing, closed = {}, 0
    if type(rawget(parts, "Coalescing")) ~= "table" then
      missing[#missing + 1] = "Coalescing"
      closed = closed + retireTimedMembers()
    end
    if type(rawget(parts, "Lanes")) ~= "table" then
      missing[#missing + 1] = "Lanes"
      closed = closed + retireLanes()
    end
    if type(rawget(parts, "Watch")) ~= "table" then
      missing[#missing + 1] = "Watch"
      closed = closed + retireWatchers()
    end
    if closed == 0 then
      return
    end
    local files = {}
    for index = 1, #missing do
      files[index] = "schedulerKit\\parts\\SchedulerKit-" .. missing[index] .. ".lua"
    end
    reportError(
      "MoltenCodes SchedulerKit revision "
        .. IMPLEMENTATION_REVISION
        .. " took over from revision "
        .. inheritedRevision
        .. ", which carried the coalescing family in one file, and closed "
        .. closed
        .. " live handles and lanes whose part is not loaded. Embed "
        .. table.concat(files, ", ")
        .. " after schedulerKit\\SchedulerKit.lua to keep them"
    )
  end
end

---Whether the named part of SchedulerKit is loaded.
---@param self SchedulerKit
---@param name string `"Coalescing"`, `"Lanes"` or `"Watch"`
---@return boolean loaded
local function hasPart(self, name)
  if type(self) ~= "table" or self ~= SchedulerKit then
    error(
      "SchedulerKit:HasPart must be called on the SchedulerKit facade; "
        .. "use SchedulerKit:HasPart(name)",
      2
    )
  end
  refuseSecretValue(name, "SchedulerKit:HasPart name", 3)
  if type(name) ~= "string" then
    error("SchedulerKit:HasPart name must be a string", 2)
  end
  return type(rawget(rawget(state, "parts"), name)) == "table"
end

-- Scope cleanup -------------------------------------------------------------

---Cancel every job of `scope`, keeping the scope itself usable.
---
---`scope` is already validated: `Scope:CancelAll` checks its receiver itself,
---so the wrong-receiver error names the caller's line.
---@param scope SchedulerKit.Scope
---@return boolean cancelled
local function cancelAll(scope)
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

  local familyError = state.dispatch.cancelFamilyMembers(scope)
  if firstError == nil then
    firstError = familyError
  end

  if firstError ~= nil then
    error(firstError.value, 0)
  end
  return true
end

---Disconnect the LifecycleKit `OnShutdown` subscription an addon scope holds,
---if any. Best-effort: the subscription only closes a scope, and closing a
---closed scope is a no-op, so one that cannot be disconnected is harmless.
---@param scope SchedulerKit.Scope
local function releaseLogoutSubscription(scope)
  local subscription = rawget(scope, "_logoutSubscription")
  if type(subscription) ~= "table" then
    return
  end
  rawset(scope, "_logoutSubscription", false)
  local disconnectSubscription = subscription.Disconnect
  if type(disconnectSubscription) == "function" then
    pcall(disconnectSubscription, subscription)
  end
end

---Terminally close `scope`, its jobs, its coalescing handles and its timer
---scope. An addon scope also lets go of its LifecycleKit shutdown
---subscription, which has nothing left to do.
---
---`scope` is already validated: `Scope:Close` checks its receiver itself, so
---the wrong-receiver error names the caller's line.
---@param scope SchedulerKit.Scope
---@return boolean closed `false` when the scope was already closed.
local function closeScope(scope)
  if rawget(scope, "_closed") == true then
    return false
  end
  rawset(scope, "_closed", true)
  releaseLogoutSubscription(scope)

  local firstError = nil
  local ok, value = pcall(cancelAll, scope)
  if not ok then
    firstError = { value = value }
  end

  local familyError = state.dispatch.closeFamilyMembers(scope)
  if firstError == nil then
    firstError = familyError
  end

  local timerScope = rawget(scope, "_timerScope")
  if timerScope ~= false then
    local timerOk, timerError = pcall(timerScope.Close, timerScope)
    if not timerOk and firstError == nil then
      firstError = { value = timerError }
    end
  end

  if firstError ~= nil then
    error(firstError.value, 0)
  end
  return true
end

-- Logout coverage -----------------------------------------------------------
--
-- An addon scope must close at logout whenever the framework can observe
-- logout at all, whatever revisions an addon's libraries pair. The first
-- `ForAddon` for an addon picks the first of these that applies and records
-- it on the scope as `_logoutRoute`:
--
--   1. LifecycleKit lists "schedulerKit" in `CLOSES_ADDON_SCOPES`: it calls
--      `CloseAddonScopes` at shutdown, after the addon's shutdown callbacks.
--      Nothing is subscribed; `LifecycleKit:ForAddon` is called once so the
--      addon has an instance and its shutdown pass reaches this scope.
--   2. An older LifecycleKit, without that capability: one `OnShutdown`
--      subscription per addon closes the scope among the shutdown callbacks,
--      as revisions 9 and older did. The handle is kept on the scope, so
--      closing the scope disconnects it.
--   3. No LifecycleKit, but EventKit: one package-level `PLAYER_LOGOUT`
--      connection, in an EventKit scope of SchedulerKit's own, closes every
--      addon scope that neither LifecycleKit route covers.
--   4. Neither: nothing is subscribed, and the addon calls
--      `CloseAddonScopes` itself. This outcome is examined again at the next
--      `ForAddon`, since a Kit loaded later can change it.
--
-- Callbacks handed to other Kits resolve SchedulerKit's behaviour through
-- `state.dispatch` when they run, so a newer revision upgrades them in place.

---Whether `LifecycleKit` closes SchedulerKit's addon scopes at shutdown itself.
---
---`CLOSES_ADDON_SCOPES` is a read-only view, so it is read by ordinary
---indexing; a revision without the field closes none.
---@param LifecycleKit table
---@return boolean
local function lifecycleClosesAddonScopes(LifecycleKit)
  local capabilities = rawget(LifecycleKit, "CLOSES_ADDON_SCOPES")
  return type(capabilities) == "table" and capabilities[PACKAGE_NAME] == true
end

---The LifecycleKit that closes SchedulerKit's addon scopes itself, or `nil`.
---@return table|nil
local function findClosingLifecycleKit()
  local LifecycleKit = findOptionalPackage("lifecycleKit", OPTIONAL_LIFECYCLE_KIT_API)
  if type(LifecycleKit) ~= "nil" and lifecycleClosesAddonScopes(LifecycleKit) then
    return LifecycleKit
  end
  return nil
end

---Close an addon scope from a LifecycleKit `OnShutdown` callback (route 2).
---
---When a LifecycleKit that closes SchedulerKit's scopes itself has replaced
---the older one in the meantime, it makes the call after the shutdown
---callbacks, so this one steps aside and keeps that ordering.
---@param addonName string
---@return boolean closed
local function closeOnShutdown(addonName)
  local scope = rawget(rawget(state, "addonScopes"), addonName)
  if scope == nil then
    return false
  end
  -- The subscription is one-shot and has fired; nothing is left to release.
  rawset(scope, "_logoutSubscription", false)
  if findClosingLifecycleKit() ~= nil then
    return false
  end
  return closeScope(scope)
end

---Close, at `PLAYER_LOGOUT`, every addon scope no LifecycleKit route covers
---(route 3), in addon-name order. Every scope is attempted; the first failure
---is re-raised afterwards, and EventKit reports it through the host error
---handler.
local function closeOnLogout()
  rawset(state, "logoutConnection", false)

  local addonScopes = rawget(state, "addonScopes")
  local names = {}
  for addonName in pairs(addonScopes) do
    names[#names + 1] = addonName
  end
  table.sort(names)

  local firstError = nil
  for index = 1, #names do
    local scope = rawget(addonScopes, names[index])
    local route = rawget(scope, "_logoutRoute")
    if route ~= LOGOUT_ROUTE_LIFECYCLE and route ~= LOGOUT_ROUTE_SHUTDOWN_SUBSCRIPTION then
      local ok, closeError = pcall(closeScope, scope)
      if not ok and firstError == nil then
        firstError = { value = closeError }
      end
    end
  end
  if firstError ~= nil then
    error(firstError.value, 0)
  end
end

---Subscribe the addon scope to an older LifecycleKit's shutdown (route 2).
---@param LifecycleKit table
---@param addonName string
---@return table|nil subscription `nil` when LifecycleKit refused
local function subscribeToShutdown(LifecycleKit, addonName)
  local ok, subscription = pcall(function()
    return LifecycleKit:ForAddon(addonName):OnShutdown(function()
      local closeForShutdown = rawget(rawget(state, "dispatch"), "closeOnShutdown")
      if type(closeForShutdown) == "function" then
        closeForShutdown(addonName)
      end
    end)
  end)
  if not ok or type(subscription) ~= "table" then
    return nil
  end
  return subscription
end

---Whether the package-level `PLAYER_LOGOUT` connection is live.
---@return boolean
local function hasLogoutConnection()
  local connection = rawget(state, "logoutConnection")
  if type(connection) ~= "table" then
    return false
  end
  local ok, connected = pcall(connection.IsConnected, connection)
  return ok and connected == true
end

---Make sure one EventKit `PLAYER_LOGOUT` connection closes the addon scopes
---no LifecycleKit covers (route 3), creating it on first need.
---@return boolean covered `false` when EventKit is absent or refused
local function ensureLogoutConnection()
  if hasLogoutConnection() then
    return true
  end
  local EventKit = findOptionalPackage("eventKit", OPTIONAL_EVENT_KIT_API)
  if type(EventKit) == "nil" then
    return false
  end

  local ok, eventScope, connection = pcall(function()
    local ownScope = rawget(state, "logoutEventScope")
    if type(ownScope) ~= "table" or ownScope:IsClosed() then
      ownScope = EventKit:CreateScope()
    end
    local logoutConnection = ownScope:Once(LOGOUT_EVENT, function()
      local handler = rawget(rawget(state, "dispatch"), "closeOnLogout")
      if type(handler) == "function" then
        handler()
      end
    end)
    return ownScope, logoutConnection
  end)
  if not ok or type(connection) ~= "table" then
    return false
  end
  rawset(state, "logoutEventScope", eventScope)
  rawset(state, "logoutConnection", connection)
  return true
end

---Decide who closes `scope` at logout, unless that is already decided.
---
---Called by `ForAddon` for every scope it returns, so the common case costs one
---field read. Only an undecided scope, or one nobody could close before, looks
---for LifecycleKit and EventKit.
---@param scope SchedulerKit.Scope an addon scope
local function ensureLogoutRoute(scope)
  local route = rawget(scope, "_logoutRoute")
  if (route ~= false and route ~= LOGOUT_ROUTE_NONE) or rawget(scope, "_closed") == true then
    return
  end

  local LifecycleKit = findOptionalPackage("lifecycleKit", OPTIONAL_LIFECYCLE_KIT_API)
  if type(LifecycleKit) ~= "nil" then
    if lifecycleClosesAddonScopes(LifecycleKit) then
      -- LifecycleKit closes the scopes of the addons it has an
      -- instance for, so make sure this addon has one. Nothing is
      -- subscribed; a refusal only leaves the addon unknown to it.
      pcall(function()
        LifecycleKit:ForAddon(rawget(scope, "_addonName"))
      end)
      rawset(scope, "_logoutRoute", LOGOUT_ROUTE_LIFECYCLE)
      return
    end
    local subscription = subscribeToShutdown(LifecycleKit, rawget(scope, "_addonName"))
    if subscription ~= nil then
      rawset(scope, "_logoutSubscription", subscription)
      rawset(scope, "_logoutRoute", LOGOUT_ROUTE_SHUTDOWN_SUBSCRIPTION)
      return
    end
  end

  if ensureLogoutConnection() then
    rawset(scope, "_logoutRoute", LOGOUT_ROUTE_EVENT)
    return
  end
  rawset(scope, "_logoutRoute", LOGOUT_ROUTE_NONE)
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
  if rawget(state, "currentJob") ~= job or (jobState ~= "running" and jobState ~= "cancelled") then
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
  if rawget(state, "currentJob") ~= job or (jobState ~= "running" and jobState ~= "cancelled") then
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
---when the job did not fail through a callback error or the host publishes
---neither `debug.traceback` nor the client's `debugstack`.
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
  validateJob(self, "SchedulerKit.Job:Cancel")
  local cancelled = cancelJob(self)
  return cancelled
end

-- Scope public methods ------------------------------------------------------

---Schedule immediately eligible cooperative work in this scope.
---@param self SchedulerKit.Scope
---@param callback SchedulerKit.Callback
---@param options SchedulerKit.ScheduleOptions?
---@return SchedulerKit.Job job
local function scopeSchedule(self, callback, options)
  validateScope(self, "SchedulerKit.Scope:Schedule")
  local job = scheduleInScope(self, callback, options, "SchedulerKit.Scope:Schedule")
  return job
end

---Schedule work that must not run during the current pass.
---@param self SchedulerKit.Scope
---@param callback SchedulerKit.Callback
---@param options SchedulerKit.ScheduleOptions?
---@return SchedulerKit.Job job
local function scopeNextFrame(self, callback, options)
  validateScope(self, "SchedulerKit.Scope:NextFrame")
  local job =
    scheduleAfterInScope(self, 0, callback, options, false, "SchedulerKit.Scope:NextFrame")
  return job
end

---Schedule work to become eligible after `delay` seconds.
---@param self SchedulerKit.Scope
---@param delay number Finite seconds greater than or equal to zero.
---@param callback SchedulerKit.Callback
---@param options SchedulerKit.ScheduleOptions?
---@return SchedulerKit.Job job
local function scopeAfter(self, delay, callback, options)
  validateScope(self, "SchedulerKit.Scope:After")
  local job =
    scheduleAfterInScope(self, delay, callback, options, false, "SchedulerKit.Scope:After")
  return job
end

---Schedule work that re-arms `interval` seconds after each run completes.
---@param self SchedulerKit.Scope
---@param interval number Finite seconds greater than zero.
---@param callback SchedulerKit.Callback
---@param options SchedulerKit.ScheduleOptions?
---@return SchedulerKit.Job job
local function scopeEvery(self, interval, callback, options)
  validateScope(self, "SchedulerKit.Scope:Every")
  local job =
    scheduleAfterInScope(self, interval, callback, options, true, "SchedulerKit.Scope:Every")
  return job
end

---Cancel every job in this scope while keeping the scope reusable.
---@param self SchedulerKit.Scope
---@return boolean cancelled
local function scopeCancelAll(self)
  validateScope(self, "SchedulerKit.Scope:CancelAll")
  local cancelled = cancelAll(self)
  return cancelled
end

---Terminally close this scope after cancelling everything it owns.
---@param self SchedulerKit.Scope
---@return boolean closed `false` when the scope was already closed.
local function scopeClose(self)
  validateScope(self, "SchedulerKit.Scope:Close")
  local closed = closeScope(self)
  return closed
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
  local job = scheduleInScope(getDefaultScope(), callback, options, "SchedulerKit:Schedule")
  return job
end

---Schedule next-pass work in SchedulerKit's internal manual scope.
---@param _ SchedulerKit
---@param callback SchedulerKit.Callback
---@param options SchedulerKit.ScheduleOptions?
---@return SchedulerKit.Job job
local function packageNextFrame(_, callback, options)
  local job =
    scheduleAfterInScope(getDefaultScope(), 0, callback, options, false, "SchedulerKit:NextFrame")
  return job
end

---Schedule delayed work in SchedulerKit's internal manual scope.
---@param _ SchedulerKit
---@param delay number Finite seconds greater than or equal to zero.
---@param callback SchedulerKit.Callback
---@param options SchedulerKit.ScheduleOptions?
---@return SchedulerKit.Job job
local function packageAfter(_, delay, callback, options)
  local job =
    scheduleAfterInScope(getDefaultScope(), delay, callback, options, false, "SchedulerKit:After")
  return job
end

---Schedule repeating work in SchedulerKit's internal manual scope.
---@param _ SchedulerKit
---@param interval number Finite seconds greater than zero.
---@param callback SchedulerKit.Callback
---@param options SchedulerKit.ScheduleOptions?
---@return SchedulerKit.Job job
local function packageEvery(_, interval, callback, options)
  local job =
    scheduleAfterInScope(getDefaultScope(), interval, callback, options, true, "SchedulerKit:Every")
  return job
end

---Create a manually owned scope, closed only by its owner.
---@return SchedulerKit.Scope scope
local function createScope()
  return newScope(nil)
end

---Return the canonical scheduler scope for an addon, creating it on demand.
---
---The scope is closed at logout through
---`SchedulerKit:CloseAddonScopes(addonName)` by LifecycleKit, or by
---SchedulerKit's own EventKit `PLAYER_LOGOUT` connection when LifecycleKit is
---absent; with neither loaded, the addon makes the call itself. See "Logout
---coverage" above and docs/API.md, "At logout".
---@param _ SchedulerKit
---@param addonName string addon folder name
---@return SchedulerKit.Scope scope
local function forAddon(_, addonName)
  validateNonEmptyString(addonName, "SchedulerKit:ForAddon addonName", 3)
  local addonScopes = rawget(state, "addonScopes")
  local scope = rawget(addonScopes, addonName)
  if scope == nil then
    scope = newScope(addonName)
    rawset(scope, "_logoutRoute", false)
    rawset(scope, "_logoutSubscription", false)
    rawset(addonScopes, addonName, scope)
  end
  ensureLogoutRoute(scope)
  return scope
end

---Close the canonical scope of an addon: cancel its jobs, close its coalescing
---handles and its TimerKit delay scope.
---
---Closing is terminal, exactly like `Scope:Close()`: the closed scope stays
---the canonical scope, so a later `ForAddon(addonName)` returns it and refuses
---new work. An addon that never asked for a scope has nothing to close:
---nothing is recorded, so the addon-scope map grows only with `ForAddon`
---calls. A job may close its own addon scope while it runs; it is cancelled
---with the rest and is not resumed again. The first cleanup failure is
---re-raised after every step has run, as for `Scope:Close()`.
---@param self SchedulerKit
---@param addonName string addon folder name
---@return boolean closed `false` when the addon has no scope or it was already closed.
local function closeAddonScopes(self, addonName)
  if type(self) ~= "table" or self ~= SchedulerKit then
    error(
      "SchedulerKit:CloseAddonScopes must be called on the SchedulerKit facade; "
        .. "use SchedulerKit:CloseAddonScopes(addonName)",
      2
    )
  end
  validateNonEmptyString(addonName, "SchedulerKit:CloseAddonScopes addonName", 3)

  local scope = rawget(rawget(state, "addonScopes"), addonName)
  if scope == nil then
    return false
  end
  return closeScope(scope)
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

---Validate a whole `SetLimits` table before any of it is applied, so a refused
---call changes nothing.
---@param limits any
---@param level integer stack level the failures are reported at
local function validateLimitUpdate(limits, level)
  if type(limits) ~= "table" then
    error("SchedulerKit:SetLimits limits must be a table", level)
  end
  local key = next(limits)
  while type(key) ~= "nil" do
    if LIMIT_CEILINGS[key] == nil then
      error(
        "SchedulerKit:SetLimits limits." .. describeKey(key) .. " is not a recognised limit",
        level
      )
    end
    local value = rawget(limits, key)
    refuseSecretValue(value, "SchedulerKit:SetLimits limits." .. key, level + 1)
    local refusal = LIMIT_UNBOUNDED_REFUSALS[key]
    local ceiling = LIMIT_CEILINGS[key]
    if value == UNBOUNDED then
      if refusal ~= nil then
        error(
          "SchedulerKit:SetLimits limits."
            .. key
            .. " cannot be SchedulerKit.UNBOUNDED: "
            .. refusal,
          level
        )
      end
    elseif not isLimitValue(value, ceiling, nil, false) then
      if ceiling ~= false then
        error(
          "SchedulerKit:SetLimits limits." .. key .. " must be an integer from 1 to " .. ceiling,
          level
        )
      end
      error(
        "SchedulerKit:SetLimits limits."
          .. key
          .. " must be a positive integer or SchedulerKit.UNBOUNDED",
        level
      )
    end
    key = next(limits, key)
  end
end

---Change any subset of the package-wide limits, shared by every addon in the
---session. The whole table is validated first. Lowering a limit releases
---nothing that already exists; further lanes, intervals, watchers or wide
---debounce calls are refused until the count is below it again.
---@param self SchedulerKit
---@param limits table any subset of `SchedulerKit.Limits`
local function setLimits(self, limits)
  if type(self) ~= "table" or self ~= SchedulerKit then
    error(
      "SchedulerKit:SetLimits must be called on the SchedulerKit facade; "
        .. "use SchedulerKit:SetLimits(limits)",
      2
    )
  end
  validateLimitUpdate(limits, 3)
  for index = 1, #LIMIT_NAMES do
    local name = LIMIT_NAMES[index]
    local value = rawget(limits, name)
    if type(value) ~= "nil" then
      rawset(sharedLimits, name, value)
    end
  end
end

---Return a fresh copy of the package-wide limits. Allocates one table.
---@param self SchedulerKit
---@return SchedulerKit.Limits
local function getLimits(self)
  if type(self) ~= "table" or self ~= SchedulerKit then
    error(
      "SchedulerKit:GetLimits must be called on the SchedulerKit facade; "
        .. "use SchedulerKit:GetLimits()",
      2
    )
  end
  return {
    maxLanes = rawget(sharedLimits, "maxLanes"),
    maxWatchIntervals = rawget(sharedLimits, "maxWatchIntervals"),
    maxWatchersPerInterval = rawget(sharedLimits, "maxWatchersPerInterval"),
    maxDebounceArguments = rawget(sharedLimits, "maxDebounceArguments"),
  }
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
do
  ---Reopen a closed manual scope, empty and usable like a new one.
  ---
  ---Closing cancelled every job, closed every `Debounce`, `Coalesce`, `Watch`
  ---and lane handle, and closed the TimerKit scope behind the delays; none of
  ---that comes back. The next delayed job creates a fresh TimerKit scope. This
  ---is how a ModuleKit module keeps the same `scope.Jobs` object across its
  ---enable cycles. An addon scope belongs to its addon's teardown, so closing it
  ---stays terminal.
  ---@param self SchedulerKit.Scope
  ---@return boolean reopened `false` when the scope was open.
  local function scopeReopen(self)
    validateScope(self, "SchedulerKit.Scope:Reopen")
    if type(rawget(self, "_addonName")) ~= "nil" then
      error("SchedulerKit.Scope:Reopen cannot reopen an addon scope", 2)
    end
    if rawget(self, "_closed") ~= true then
      return false
    end
    rawset(self, "_timerScope", false)
    rawset(self, "_closed", false)
    return true
  end
  rawset(Scope, "Reopen", scopeReopen)
end
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
rawset(SchedulerKit, "CloseAddonScopes", closeAddonScopes)
rawset(SchedulerKit, "SetFrameBudget", setFrameBudget)
rawset(SchedulerKit, "GetFrameBudget", getFrameBudget)
rawset(SchedulerKit, "SetRunawayThreshold", setRunawayThreshold)
rawset(SchedulerKit, "GetRunawayThreshold", getRunawayThreshold)
rawset(SchedulerKit, "SetMaxResumesPerFrame", setMaxResumesPerFrame)
rawset(SchedulerKit, "GetMaxResumesPerFrame", getMaxResumesPerFrame)
rawset(SchedulerKit, "GetActiveCount", getActiveCount)
rawset(SchedulerKit, "UNBOUNDED", UNBOUNDED)
rawset(SchedulerKit, "SetLimits", setLimits)
rawset(SchedulerKit, "GetLimits", getLimits)
rawset(SchedulerKit, "HasPart", hasPart)

-- The core functions the parts call, read through this table at every call.
-- Only ever added to (see `PART_INTERFACE`).
do
  local helpers = rawget(state, "helpers")
  rawset(helpers, "nowFromPreciseClock", nowFromPreciseClock)
  rawset(helpers, "refuseSecretValue", refuseSecretValue)
  rawset(helpers, "isSecretValue", isSecretValue)
  rawset(helpers, "loadedIsSecretValue", loadedIsSecretValue or false)
  -- `debug.traceback`, which the Retail client does not publish: `false` there.
  if type(nativeTraceback) == "function" then
    rawset(helpers, "nativeTraceback", nativeTraceback)
  else
    rawset(helpers, "nativeTraceback", false)
  end
  rawset(helpers, "describeKey", describeKey)
  rawset(helpers, "reportError", reportError)
  rawset(helpers, "ensureTimerScope", ensureTimerScope)
  rawset(helpers, "queuePush", queuePush)
  rawset(helpers, "newJob", newJob)
  rawset(helpers, "updateDriver", updateDriver)
  rawset(helpers, "armDelay", armDelay)
  rawset(helpers, "markJobFailed", markJobFailed)
  rawset(helpers, "cancelJob", cancelJob)
  rawset(helpers, "getDefaultScope", getDefaultScope)
  rawset(helpers, "validateScope", validateScope)
  rawset(helpers, "validatePriority", validatePriority)
  rawset(helpers, "validatePositiveInteger", validatePositiveInteger)
  rawset(helpers, "validateFinitePositive", validateFinitePositive)
  rawset(helpers, "validateNonEmptyString", validateNonEmptyString)
  -- Only a hand-over from a whole-file revision can leave a member whose part
  -- is not loaded; otherwise the retiring code is not kept.
  if inheritedWholeRevision ~= nil then
    rawset(helpers, "retireMember", retireMember)
  end
end
installPartStubs(inheritedWholeRevision ~= nil)

local defaultScope = rawget(state, "defaultScope")
if defaultScope ~= false and getmetatable(defaultScope) ~= SCOPE_METATABLE then
  error("MoltenCodes SchedulerKit package state is corrupted or incomplete", 2)
end

local dispatch = rawget(state, "dispatch")
rawset(dispatch, "runFrame", runFrame)
rawset(dispatch, "wakeDelayed", wakeDelayed)
-- No revision from 10 on calls `closeScope` through dispatch. It stays
-- published for the shutdown wrappers of revision 9 and older, in case one
-- could not be disconnected during the upgrade (see the revision-10 migration).
rawset(dispatch, "closeScope", closeScope)
-- The logout routes' callbacks resolve these at call time (see "Logout
-- coverage"), so connections an older revision 12+ copy made run this code.
rawset(dispatch, "closeOnShutdown", closeOnShutdown)
rawset(dispatch, "closeOnLogout", closeOnLogout)

-- A compatible reload may inherit a frame whose OnUpdate trampoline is already
-- installed. The trampoline resolves dispatch dynamically, so updating the
-- shared dispatch table above is sufficient for live revision handoff.
if rawget(state, "driverEnabled") == true and not hasReadyJobs() then
  updateDriver()
end

if not validatePublicSurface(SchedulerKit) or not validateCurrentState(SchedulerKit) then
  error("MoltenCodes SchedulerKit package state is corrupted or incomplete", 2)
end

-- Addon scopes an older revision created have no logout route yet. They are
-- given one now, in addon-name order, exactly as a first `ForAddon` would;
-- scopes whose route a revision 12+ copy already decided keep it, with any
-- subscription or connection it made.
local function routeInheritedAddonScopes()
  local addonScopes = rawget(state, "addonScopes")
  local names = {}
  for addonName, scope in pairs(addonScopes) do
    if type(scope) == "table" and rawget(scope, "_logoutRoute") == nil then
      names[#names + 1] = addonName
    end
  end
  table.sort(names)
  for index = 1, #names do
    local scope = rawget(addonScopes, names[index])
    rawset(scope, "_logoutRoute", false)
    rawset(scope, "_logoutSubscription", false)
    ensureLogoutRoute(scope)
  end
end

if type(previousRevision) ~= "nil" and previousRevision < IMPLEMENTATION_REVISION then
  routeInheritedAddonScopes()
end

-- A hand-over from a whole-file revision that left lanes, watchers or handles
-- is settled on the next frame: the parts this addon embeds load right after
-- this file and replace the stubs, and only what is still missing then is
-- closed. A handle in a manual scope is not reachable from the state; its
-- stubbed methods raise when called, and a timer it armed retires it.
if
  inheritedWholeRevision ~= nil
  and inheritedWholeRevision <= LAST_WHOLE_REVISION
  and hasReachableFamilyObjects()
then
  rawset(rawget(state, "dispatch"), "settleWholeRevision", settleWholeRevision)
  local revision = inheritedWholeRevision
  local ok, failure = pcall(TimerKit.After, TimerKit, 0, function()
    local settle = rawget(rawget(state, "dispatch"), "settleWholeRevision")
    if type(settle) == "function" then
      settle(revision)
    end
  end)
  if not ok then
    reportError(failure)
  end
end

return SchedulerKit
