-- MoltenCodes ReadinessKit
--
-- Named gates for World of Warcraft host data that arrives after load and is
-- `nil` or wrong until then: spell and item information, the spellbook,
-- talents, the guild roster. A consumer describes the fact it needs as a probe
-- function and waits for the gate instead of guessing with a timer.
--
-- A gate probes once when it is created. While the probe answers "not yet" the
-- gate polls it on one TimerKit repeating timer, gives up after a timeout, and
-- remembers a negative answer for one interval so a burst of callers does not
-- re-run an expensive probe. Waiters queue in a bounded array and are called
-- once, in order, when the gate becomes ready or times out.
--
-- ReadinessKit requires Registry API 2 and TimerKit API 1. EventKit API 1 is
-- optional and found through `Registry:Find` only when `gate:ReprobeOn` is
-- called. The `GetTimePreciseSec` clock is optional too: without it negative
-- caching is disabled and timeouts are counted in polls.
--
-- Contents
-- --------
--   Constants ............. identity, defaults, statuses, method lists
--   Public types .......... LuaCATS declarations for the published surface
--   Dependencies .......... Registry, TimerKit, the clock, the error sink
--   Validation ............ public-surface and shared-state predicates
--   Bootstrap ............. Registry registration and inherited state
--   Argument checks ....... receivers, names, option tables
--   Waiter internals ...... protected calls, the waiter array, flushing
--   Probing ............... running the probe, negative cache, timeout
--   Polling ............... the Kit-owned timer scope and the poll tick
--   Transitions ........... ready, timed out, polling resumed
--   Re-probe on events .... optional EventKit resolution and the callback
--   Gate methods .......... the handle a gate owner receives
--   Waiter methods ........ the handle `Await` and `WhenAll` return
--   Package public API .... the facade published through Registry
--   Commit ................ prototype/facade assignment and self-check
--
-- Layout and invariants are described in `docs/INTERNALS.md`.

-- Constants ------------------------------------------------------------------

local PACKAGE_NAME = "readinessKit"
local API_GENERATION = 1
local IMPLEMENTATION_REVISION = 1
local REQUIRED_REGISTRY_API = 2
local REQUIRED_TIMERKIT_API = 1
local OPTIONAL_EVENTKIT_API = 1
local STATE_SCHEMA = 1

-- Every gate records the layout it was built with, so a later revision that
-- changes the layout can upgrade old gates lazily instead of guessing from
-- which fields exist.
local GATE_SCHEMA = 1

-- Defaults recorded in the package plan. Half a second is the interval
-- LibRangeCheck settled on for the same warm-up problem; thirty seconds covers
-- a slow login without letting a gate for data that never arrives poll forever.
local DEFAULT_INTERVAL_SECONDS = 0.5
local DEFAULT_TIMEOUT_SECONDS = 30
local DEFAULT_MAX_WAITERS = 64

-- Poll counting multiplies the interval, so a timeout that is an exact multiple
-- of it must not miss by one ulp.
local POLL_COUNT_TOLERANCE = 1e-9

-- The complete set of fields `Gate` options accept. A file-local constant keeps
-- option validation allocation-free.
local GATE_OPTION_KEYS = { intervalSeconds = true, timeoutSeconds = true, maxWaiters = true }

-- Gate statuses. `IsReady` compares against one of them, so it stays a field
-- read.
local STATUS_PENDING = "pending"
local STATUS_READY = "ready"
local STATUS_TIMED_OUT = "timedOut"
local STATUS_CLOSED = "closed"

-- Waiter statuses.
local WAITER_QUEUED = "queued"
local WAITER_CALLED = "called"
local WAITER_CANCELLED = "cancelled"

-- The reasons a waiter is called with `false`, and the reason `Await` refuses.
local REASON_TIMEOUT = "timeout"
local REASON_CLOSED = "closed"
local REASON_FULL = "full"

-- The published surface, listed once so the public-surface predicate reads as
-- a checklist instead of a long boolean expression.
local FACADE_METHODS = { "Gate", "Get", "WhenAll" }
local GATE_METHODS = { "IsReady", "Await", "Probe", "Invalidate", "ReprobeOn", "Close", "IsClosed" }
local WAITER_METHODS = { "Cancel", "IsPending" }

-- Public types ---------------------------------------------------------------
--
-- ReadinessKit publishes its methods by writing them onto shared prototype
-- tables kept in package state, so the editor-facing contract is declared here
-- as LuaCATS classes rather than inferred from those assignments.

---Option table accepted by `ReadinessKit:Gate`.
---@class ReadinessKit.GateOptions
---@field intervalSeconds number? Seconds between polls, and how long a negative answer is remembered. Defaults to `0.5`.
---@field timeoutSeconds number|false? Seconds of polling before waiters are told `"timeout"`, or `false` for no timeout. Defaults to `30`.
---@field maxWaiters integer? The most callbacks queued at once. Defaults to `64`.

---The consumer's probe: a truthy result means the data is usable.
---@alias ReadinessKit.Probe fun(): any

---A waiter's callback: `true` when the gate became ready, otherwise `false`
---and `"timeout"` or `"closed"`.
---@alias ReadinessKit.Callback fun(ready: boolean, reason: string?)

---One named readiness gate.
---@class ReadinessKit.Gate
---@field IsReady fun(self: ReadinessKit.Gate): boolean
---@field Await fun(self: ReadinessKit.Gate, callback: ReadinessKit.Callback): ReadinessKit.Waiter?, string?
---@field Probe fun(self: ReadinessKit.Gate): boolean
---@field Invalidate fun(self: ReadinessKit.Gate): boolean
---@field ReprobeOn fun(self: ReadinessKit.Gate, eventName: string): boolean
---@field Close fun(self: ReadinessKit.Gate): boolean
---@field IsClosed fun(self: ReadinessKit.Gate): boolean

---The handle `Await` and `WhenAll` return.
---@class ReadinessKit.Waiter
---@field Cancel fun(self: ReadinessKit.Waiter): boolean
---@field IsPending fun(self: ReadinessKit.Waiter): boolean

---The ReadinessKit package facade published through Registry.
---@class ReadinessKit
---@field API integer Public API generation.
---@field REVISION integer Compatible implementation revision.
---@field Gate fun(self: ReadinessKit, name: string, probe: ReadinessKit.Probe, options: ReadinessKit.GateOptions?): ReadinessKit.Gate
---@field Get fun(self: ReadinessKit, name: string): ReadinessKit.Gate?
---@field WhenAll fun(self: ReadinessKit, gates: ReadinessKit.Gate[], callback: ReadinessKit.Callback): ReadinessKit.Waiter?, string?

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
    error("MoltenCodes ReadinessKit requires Registry API 2 to be loaded first", 2)
end

local bootstrapPackage = rawget(Registry, "Bootstrap")
local getPackage = rawget(Registry, "Get")
if type(bootstrapPackage) ~= "function" or type(getPackage) ~= "function" then
    error("MoltenCodes ReadinessKit requires a valid Registry API 2 facade", 2)
end

-- TimerKit is a required dependency: it owns the polling timers. It is checked
-- at load, the way SchedulerKit checks it, so a missing TimerKit fails loudly
-- at the file that needs it instead of at the first gate.
local TimerKit, timerRevision = getPackage(Registry, "timerKit", REQUIRED_TIMERKIT_API)
local TimerScope = type(TimerKit) == "table" and rawget(TimerKit, "Scope") or nil
local Timer = type(TimerKit) == "table" and rawget(TimerKit, "Timer") or nil
if
    type(TimerKit) ~= "table"
    or type(timerRevision) ~= "number"
    or rawget(TimerKit, "API") ~= REQUIRED_TIMERKIT_API
    or type(rawget(TimerKit, "CreateScope")) ~= "function"
    or type(TimerScope) ~= "table"
    or type(rawget(TimerScope, "New")) ~= "function"
    or type(rawget(TimerScope, "IsClosed")) ~= "function"
    or type(Timer) ~= "table"
    or type(rawget(Timer, "Start")) ~= "function"
    or type(rawget(Timer, "Cancel")) ~= "function"
    or type(rawget(Timer, "IsPending")) ~= "function"
    or type(rawget(Timer, "GetScope")) ~= "function"
    or type(rawget(Timer, "GetUserData")) ~= "function"
    or type(rawget(Timer, "SetUserData")) ~= "function"
then
    error("MoltenCodes ReadinessKit requires TimerKit API 1 to be loaded first", 2)
end

-- Negative answers and timeouts are measured on the monotonic wall clock
-- TimerKit reads. It is optional, as it is for TimerKit and CacheKit: without
-- it negative caching is disabled and a timeout is counted in polls.
-- GetTimePreciseSec is a World of Warcraft client API reachable only through the global table.
-- selene: allow(global_usage)
local nativeGetTimePreciseSec = rawget(_G, "GetTimePreciseSec")
if type(nativeGetTimePreciseSec) ~= "function" then
    nativeGetTimePreciseSec = nil
end

---Return the clock reading in seconds, or `false` on a host without the clock.
---@return number|false
local function now()
    if nativeGetTimePreciseSec == nil then
        return false
    end
    return nativeGetTimePreciseSec()
end

---Hand a failure nobody called for (a probe, a queued callback) to the host
---error handler.
---@param message any
local function reportError(message)
    -- geterrorhandler is a World of Warcraft client API reachable only through the global table.
    -- selene: allow(global_usage)
    local getErrorHandler = rawget(_G, "geterrorhandler")
    if type(getErrorHandler) == "function" then
        local handler = getErrorHandler()
        if type(handler) == "function" then
            handler(message)
            return
        end
    end

    -- Outside a WoW client there is no error handler to report through.
    -- Printing is what the client's own default handler does, and staying
    -- silent would turn a probe bug into an invisible one.
    print(message)
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

---Whether `implementation` exposes the complete ReadinessKit API 1 surface.
---@param implementation any shared package table handed back by Registry
---@return boolean
local function validatePublicSurface(implementation)
    if
        type(implementation) ~= "table"
        or rawget(implementation, "API") ~= API_GENERATION
        or type(rawget(implementation, "REVISION")) ~= "number"
    then
        return false
    end

    return hasMethods(implementation, FACADE_METHODS)
end

---Whether `currentState` has the fields every API 1 revision shares.
---@param currentState any
---@return boolean
local function validateStateBase(currentState)
    return type(currentState) == "table"
        and rawget(currentState, "schema") == STATE_SCHEMA
        and type(rawget(currentState, "dispatch")) == "table"
        and type(rawget(currentState, "runtimeRevision")) == "number"
        and type(rawget(currentState, "gatePrototype")) == "table"
        and type(rawget(currentState, "waiterPrototype")) == "table"
        and type(rawget(currentState, "gateMetatable")) == "table"
        and type(rawget(currentState, "waiterMetatable")) == "table"
        and type(rawget(currentState, "gates")) == "table"
        and type(rawget(currentState, "pollCallback")) == "function"
end

---Whether `implementation` carries package state of this revision's schema,
---with every gate and waiter method committed.
---@param implementation table
---@return boolean
local function validateCurrentState(implementation)
    local currentState = rawget(implementation, "_state")
    return validateStateBase(currentState)
        and hasMethods(rawget(currentState, "gatePrototype"), GATE_METHODS)
        and hasMethods(rawget(currentState, "waiterPrototype"), WAITER_METHODS)
end

-- Bootstrap ------------------------------------------------------------------

-- `Registry:Bootstrap` owns the reconciliation every embedded package repeats:
-- look the package up, refuse to reinterpret state owned by a newer revision,
-- and register this one. What stays here is what only ReadinessKit can answer.
local ReadinessKit, previousRevision, selected = bootstrapPackage(Registry, {
    package = PACKAGE_NAME,
    api = API_GENERATION,
    revision = IMPLEMENTATION_REVISION,
    label = "MoltenCodes ReadinessKit",
    validatePublicSurface = validatePublicSurface,
    validateState = validateCurrentState,
})

if ReadinessKit == nil then
    -- An equal or newer compatible revision already owns the shared package table.
    return selected
end

local state = rawget(ReadinessKit, "_state")

if previousRevision == nil then
    if state ~= nil then
        error("MoltenCodes ReadinessKit package state is corrupted or incomplete", 2)
    end

    local dispatch = {}
    state = {
        schema = STATE_SCHEMA,
        -- Closures ReadinessKit hands out (the poll callback, re-probe
        -- callbacks, `WhenAll` callbacks) call through this table, so a newer
        -- revision replaces the behaviour behind closures an older revision
        -- created.
        dispatch = dispatch,
        runtimeRevision = 0,
        -- The gate and waiter method tables. They live in package state rather
        -- than on the facade because the facade's `Gate` is the constructor.
        gatePrototype = {},
        waiterPrototype = {},
        gateMetatable = {},
        waiterMetatable = {},
        -- Gate name to gate. One gate per name for the whole client session.
        gates = {},
        -- The Kit-owned TimerKit scope every polling timer lives in, created
        -- on the first gate that has to poll.
        timerScope = false,
        -- One TimerKit callback serves every gate: the gate travels on the
        -- timer as TimerKit user data, so arming a poll allocates no closure.
        pollCallback = function(timer)
            local pollTick = rawget(dispatch, "pollTick")
            pollTick(timer)
        end,
    }
    rawset(ReadinessKit, "_state", state)
elseif not validateStateBase(state) then
    error("MoltenCodes ReadinessKit package state is corrupted or incomplete", 2)
end

-- The metatables and prototypes are kept across upgrades, so gates and waiters
-- built by an older copy keep their state and gain this copy's methods without
-- being replaced.
local Gate = rawget(state, "gatePrototype")
local Waiter = rawget(state, "waiterPrototype")
local GATE_METATABLE = rawget(state, "gateMetatable")
local WAITER_METATABLE = rawget(state, "waiterMetatable")
local dispatch = rawget(state, "dispatch")
local gates = rawget(state, "gates")
rawset(GATE_METATABLE, "__index", Gate)
rawset(WAITER_METATABLE, "__index", Waiter)

-- Argument checks ------------------------------------------------------------
--
-- Argument validation raises with an explicit stack level so the reported
-- position is the line that called the public method, never a line inside
-- ReadinessKit. `level` is always the value `error` needs *inside the function
-- that receives it*, so every further hop towards `error` adds exactly one.

---@param gate any receiver the public method was called on
---@param methodName string public method name, used in the argument error
---@param level integer stack level the failure is reported at
local function validateGate(gate, methodName, level)
    if type(gate) ~= "table" or getmetatable(gate) ~= GATE_METATABLE then
        error(methodName .. " must be called on a ReadinessKit gate", level)
    end
end

---@param waiter any receiver the public method was called on
---@param methodName string public method name, used in the argument error
---@param level integer stack level the failure is reported at
local function validateWaiter(waiter, methodName, level)
    if type(waiter) ~= "table" or getmetatable(waiter) ~= WAITER_METATABLE then
        error(methodName .. " must be called on a ReadinessKit waiter", level)
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

---@param value any
---@param label string argument description, used in the argument error
---@param level integer stack level the failure is reported at
local function validateFunction(value, label, level)
    if type(value) ~= "function" then
        error(label .. " must be a function", level)
    end
end

---Whether `value` is a finite number greater than zero.
---@param value any
---@return boolean
local function isPositiveFiniteNumber(value)
    return type(value) == "number" and value == value and value > 0 and value ~= math.huge
end

---Refuse a non-table option table and any field outside `GATE_OPTION_KEYS`.
---@param options table
---@param level integer stack level the failures are reported at
local function validateOptionKeys(options, level)
    -- Report the alphabetically first unknown field without allocating: track
    -- the smallest key seen instead of collecting and sorting every offender.
    local firstUnknown = nil
    for key in next, options do
        if GATE_OPTION_KEYS[key] ~= true then
            local text = tostring(key)
            if firstUnknown == nil or text < firstUnknown then
                firstUnknown = text
            end
        end
    end
    if firstUnknown ~= nil then
        error('ReadinessKit:Gate options contains unknown field "' .. firstUnknown .. '"', level)
    end
end

---Validate `Gate` options and return them with their defaults applied.
---@param options any
---@param level integer stack level the failures are reported at
---@return number intervalSeconds
---@return number|false timeoutSeconds
---@return integer maxWaiters
local function readGateOptions(options, level)
    if options == nil then
        return DEFAULT_INTERVAL_SECONDS, DEFAULT_TIMEOUT_SECONDS, DEFAULT_MAX_WAITERS
    end
    if type(options) ~= "table" then
        error("ReadinessKit:Gate options must be a table", level)
    end
    validateOptionKeys(options, level + 1)

    local intervalSeconds = options.intervalSeconds
    if intervalSeconds == nil then
        intervalSeconds = DEFAULT_INTERVAL_SECONDS
    elseif not isPositiveFiniteNumber(intervalSeconds) then
        error("ReadinessKit:Gate intervalSeconds must be a finite number greater than zero", level)
    end

    local timeoutSeconds = options.timeoutSeconds
    if timeoutSeconds == nil then
        timeoutSeconds = DEFAULT_TIMEOUT_SECONDS
    elseif timeoutSeconds ~= false and not isPositiveFiniteNumber(timeoutSeconds) then
        error(
            "ReadinessKit:Gate timeoutSeconds must be false or a finite number greater than zero",
            level
        )
    end

    local maxWaiters = options.maxWaiters
    if maxWaiters == nil then
        maxWaiters = DEFAULT_MAX_WAITERS
    elseif not isPositiveFiniteNumber(maxWaiters) or math.floor(maxWaiters) ~= maxWaiters then
        error("ReadinessKit:Gate maxWaiters must be a positive integer", level)
    end

    return intervalSeconds, timeoutSeconds, maxWaiters
end

-- Waiter internals -----------------------------------------------------------
--
-- A queued callback runs from a TimerKit tick, an EventKit dispatch or another
-- caller's `Probe`, none of which is the code that queued it. Its failure is
-- therefore handed to the host error handler and the batch continues, instead
-- of being raised into whoever happened to make the gate ready. The callback
-- and its two arguments are staged in upvalues and one reusable trampoline
-- forwards them, so a protected call allocates no closure.

local stagedCallback = nil
local stagedReady = false
local stagedReason = nil

---Call the staged callback. Clearing the stage first keeps a callback that
---makes another gate ready from seeing stale arguments.
local function invokeStaged()
    local callback = stagedCallback
    local ready = stagedReady
    local reason = stagedReason
    stagedCallback = nil
    stagedReady = false
    stagedReason = nil
    if callback ~= nil then
        callback(ready, reason)
    end
end

---Call one queued callback, reporting its failure instead of raising it.
---@param callback ReadinessKit.Callback
---@param ready boolean
---@param reason string?
local function callQueued(callback, ready, reason)
    stagedCallback = callback
    stagedReady = ready
    stagedReason = reason
    local ok, message = pcall(invokeStaged)
    if not ok then
        reportError(message)
    end
end

---Build one waiter handle.
---@param gate ReadinessKit.Gate|false `false` for a `WhenAll` group
---@param callback ReadinessKit.Callback
---@param status string
---@return ReadinessKit.Waiter
local function newWaiter(gate, callback, status)
    return setmetatable({
        _gate = gate,
        _callback = callback,
        _status = status,
        -- `WhenAll` only: the per-gate waiters and how many gates are not yet
        -- ready. `false` and `0` for an ordinary waiter.
        _children = false,
        _remaining = 0,
    }, WAITER_METATABLE)
end

---Remove `waiter` from its gate's live waiter array, keeping the order of the
---rest. A waiter in a batch that is being flushed is not in the live array;
---its `cancelled` status is what makes the flush skip it.
---@param gate table
---@param waiter table
local function removeQueued(gate, waiter)
    local waiters = rawget(gate, "_waiters")
    local count = rawget(gate, "_waiterCount")
    for index = 1, count do
        if waiters[index] == waiter then
            for shift = index, count - 1 do
                waiters[shift] = waiters[shift + 1]
            end
            waiters[count] = nil
            rawset(gate, "_waiterCount", count - 1)
            return
        end
    end
end

---Call every queued waiter once, in the order they were queued.
---
---The live array is swapped for the spare one before any callback runs, so a
---callback that queues a new waiter (after invalidating the gate, say) queues
---it for the next round rather than into the batch being delivered. After the
---batch the delivered array, now empty, becomes the spare. The two arrays are
---reused for the life of the gate; only a flush nested inside another flush of
---the same gate finds no spare and allocates one.
---@param gate table
---@param ready boolean
---@param reason string?
local function flushWaiters(gate, ready, reason)
    local count = rawget(gate, "_waiterCount")
    if count == 0 then
        return
    end

    local batch = rawget(gate, "_waiters")
    local spare = rawget(gate, "_spareWaiters")
    if spare == false then
        spare = {}
    end
    rawset(gate, "_waiters", spare)
    rawset(gate, "_spareWaiters", false)
    rawset(gate, "_waiterCount", 0)

    for index = 1, count do
        local waiter = batch[index]
        batch[index] = nil
        if rawget(waiter, "_status") == WAITER_QUEUED then
            local callback = rawget(waiter, "_callback")
            rawset(waiter, "_status", WAITER_CALLED)
            rawset(waiter, "_callback", false)
            callQueued(callback, ready, reason)
        end
    end

    if rawget(gate, "_spareWaiters") == false then
        rawset(gate, "_spareWaiters", batch)
    end
end

-- Probing --------------------------------------------------------------------

---Run the consumer's probe. A probe that raises is reported to the host error
---handler and counts as "not ready". A negative answer is timestamped for the
---negative cache.
---@param gate table
---@return boolean ready
local function runProbe(gate)
    local ok, result = pcall(rawget(gate, "_probe"))
    if not ok then
        reportError(result)
    elseif result then
        return true
    end

    rawset(gate, "_negativeAt", now())
    return false
end

---Whether the gate's last negative answer is younger than its interval.
---Always `false` on a host without the clock.
---@param gate table
---@return boolean
local function isNegativeCached(gate)
    local negativeAt = rawget(gate, "_negativeAt")
    if negativeAt == false then
        return false
    end
    local current = now()
    if current == false then
        return false
    end
    return current - negativeAt < rawget(gate, "_intervalSeconds")
end

---Whether the current polling round has lasted `timeoutSeconds`. Measured on
---the clock when there is one, otherwise as polls times the interval.
---@param gate table
---@return boolean
local function hasTimedOut(gate)
    local timeoutSeconds = rawget(gate, "_timeoutSeconds")
    if timeoutSeconds == false then
        return false
    end

    local startedAt = rawget(gate, "_waitStartedAt")
    local current = now()
    if startedAt ~= false and current ~= false then
        return current - startedAt >= timeoutSeconds
    end

    local polled = rawget(gate, "_polls") * rawget(gate, "_intervalSeconds")
    return polled >= timeoutSeconds - POLL_COUNT_TOLERANCE
end

-- Polling --------------------------------------------------------------------

---Return the Kit-owned TimerKit scope, creating it on first use. A scope that
---somebody closed through `timer:GetScope()` is replaced rather than left to
---disable polling for good.
---@return TimerKit.Scope
local function getTimerScope()
    local scope = rawget(state, "timerScope")
    if scope == false or scope:IsClosed() then
        scope = TimerKit:CreateScope()
        rawset(state, "timerScope", scope)
    end
    return scope
end

---Start the gate's repeating poll timer, creating the timer on first use.
---
---Each gate owns at most one TimerKit timer for its whole life. It is started
---and cancelled, never replaced, unless its scope was closed from outside.
---@param gate table
local function startTimer(gate)
    local timer = rawget(gate, "_timer")
    if timer ~= false and timer:GetScope():IsClosed() then
        timer:SetUserData(nil)
        timer = false
    end
    if timer == false then
        timer = getTimerScope():New({
            delay = rawget(gate, "_intervalSeconds"),
            callback = rawget(state, "pollCallback"),
            repeating = true,
        })
        timer:SetUserData(gate)
        rawset(gate, "_timer", timer)
    end
    if not timer:IsPending() then
        timer:Start()
    end
end

---Cancel the gate's poll timer if it is running. A host failure while
---cancelling is reported, not raised: the gate has already changed status and
---its waiters still have to be told.
---@param gate table
local function stopTimer(gate)
    local timer = rawget(gate, "_timer")
    if timer ~= false and timer:IsPending() then
        local ok, message = pcall(timer.Cancel, timer)
        if not ok then
            reportError(message)
        end
    end
end

-- Transitions ----------------------------------------------------------------

---The probe answered: stop polling and release every waiter with `true`.
---@param gate table
local function becomeReady(gate)
    rawset(gate, "_status", STATUS_READY)
    rawset(gate, "_negativeAt", false)
    stopTimer(gate)
    flushWaiters(gate, true, nil)
end

---The polling round ran out: stop polling and release every waiter with
---`false, "timeout"`. Polling stays off until `Probe`, `Invalidate` or a
---re-probe event starts a new round.
---@param gate table
local function timeOut(gate)
    rawset(gate, "_status", STATUS_TIMED_OUT)
    stopTimer(gate)
    flushWaiters(gate, false, REASON_TIMEOUT)
end

---Begin a new polling round: status pending, a fresh timeout window, and the
---poll timer running.
---@param gate table
local function startPolling(gate)
    rawset(gate, "_status", STATUS_PENDING)
    rawset(gate, "_waitStartedAt", now())
    rawset(gate, "_polls", 0)
    startTimer(gate)
end

---One poll. Reached through the shared poll callback and the dispatch table,
---with the gate carried on the timer. Allocates nothing while the probe keeps
---answering "not yet".
---@param timer TimerKit.Timer
local function pollTick(timer)
    local gate = timer:GetUserData()
    if
        type(gate) ~= "table"
        or getmetatable(gate) ~= GATE_METATABLE
        or rawget(gate, "_timer") ~= timer
        or rawget(gate, "_status") ~= STATUS_PENDING
    then
        -- A tick for a gate that stopped polling: make sure it is the last.
        local ok, message = pcall(timer.Cancel, timer)
        if not ok then
            reportError(message)
        end
        return
    end

    rawset(gate, "_polls", rawget(gate, "_polls") + 1)
    if runProbe(gate) then
        becomeReady(gate)
    elseif hasTimedOut(gate) then
        timeOut(gate)
    end
end

-- Re-probe on events ---------------------------------------------------------

---Resolve EventKit when a caller first asks for re-probing. Resolving at call
---time rather than at load keeps EventKit an optional dependency.
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

---Build the one callback a gate connects to every event it re-probes on. It
---calls through the shared dispatch table so an upgrade replaces its behaviour.
---@param gate table
---@return fun()
local function newReprobeCallback(gate)
    return function()
        local reprobe = rawget(dispatch, "reprobe")
        reprobe(gate)
    end
end

---An event the gate re-probes on fired. The event is fresh information, so the
---negative cache is ignored. A ready gate is left alone (readiness only ends
---with `Invalidate`), and so is a gate closed during the dispatch in flight.
---@param gate table
local function reprobe(gate)
    local status = rawget(gate, "_status")
    if status == STATUS_READY or status == STATUS_CLOSED then
        return
    end

    if runProbe(gate) then
        becomeReady(gate)
    elseif status == STATUS_TIMED_OUT then
        startPolling(gate)
    end
end

-- Gate methods ---------------------------------------------------------------

---Return whether the gate is ready. A field read; allocates nothing.
---@param self ReadinessKit.Gate
---@return boolean
local function gateIsReady(self)
    validateGate(self, "ReadinessKit.Gate:IsReady", 3)
    return rawget(self, "_status") == STATUS_READY
end

---Queue `callback` for the gate's outcome, or call it at once when the gate
---already has one. Shared by `Await` and `WhenAll`; the caller owns
---validation.
---@param gate table an open gate
---@param callback ReadinessKit.Callback
---@return ReadinessKit.Waiter? waiter
---@return string? reason `"full"` when the queue is at `maxWaiters`
local function awaitGate(gate, callback)
    local status = rawget(gate, "_status")
    if status == STATUS_READY then
        local waiter = newWaiter(gate, callback, WAITER_CALLED)
        callback(true, nil)
        return waiter
    end
    if status == STATUS_TIMED_OUT then
        local waiter = newWaiter(gate, callback, WAITER_CALLED)
        callback(false, REASON_TIMEOUT)
        return waiter
    end

    local count = rawget(gate, "_waiterCount")
    if count >= rawget(gate, "_maxWaiters") then
        return nil, REASON_FULL
    end

    local waiter = newWaiter(gate, callback, WAITER_QUEUED)
    rawget(gate, "_waiters")[count + 1] = waiter
    rawset(gate, "_waiterCount", count + 1)
    return waiter
end

---Wait for the gate.
---
---On a ready gate `callback(true)` runs at once, as does
---`callback(false, "timeout")` on a gate whose polling timed out. Otherwise the
---callback is queued, in order, and runs once with `true` when the gate becomes
---ready, `false, "timeout"` when it times out or `false, "closed"` when it is
---closed. A queue already holding `maxWaiters` callbacks refuses with
---`nil, "full"`. A callback run at once raises into this caller; a queued one
---that raises is reported to the host error handler.
---@param self ReadinessKit.Gate
---@param callback ReadinessKit.Callback
---@return ReadinessKit.Waiter? waiter
---@return string? reason
local function gateAwait(self, callback)
    validateGate(self, "ReadinessKit.Gate:Await", 3)
    validateFunction(callback, "ReadinessKit.Gate:Await callback", 3)
    if rawget(self, "_status") == STATUS_CLOSED then
        error("ReadinessKit.Gate:Await cannot wait on a closed gate", 2)
    end
    return awaitGate(self, callback)
end

---Run the probe now and return whether the gate is ready.
---
---A ready gate returns `true` without probing. A negative answer younger than
---`intervalSeconds` is returned without running the probe again. On a gate
---whose polling timed out, a negative answer starts a new polling round.
---@param self ReadinessKit.Gate
---@return boolean ready
local function gateProbe(self)
    validateGate(self, "ReadinessKit.Gate:Probe", 3)
    local status = rawget(self, "_status")
    if status == STATUS_CLOSED then
        error("ReadinessKit.Gate:Probe cannot probe a closed gate", 2)
    end
    if status == STATUS_READY then
        return true
    end

    if not isNegativeCached(self) and runProbe(self) then
        becomeReady(self)
        return true
    end
    if status == STATUS_TIMED_OUT then
        startPolling(self)
    end
    return false
end

---Declare that the data the gate guards is no longer usable.
---
---A ready or timed-out gate goes back to pending and starts a new polling
---round with a fresh timeout. On a gate that is already polling, only the
---negative cache is dropped. Returns whether the gate was ready.
---@param self ReadinessKit.Gate
---@return boolean wasReady
local function gateInvalidate(self)
    validateGate(self, "ReadinessKit.Gate:Invalidate", 3)
    local status = rawget(self, "_status")
    if status == STATUS_CLOSED then
        error("ReadinessKit.Gate:Invalidate cannot invalidate a closed gate", 2)
    end

    rawset(self, "_negativeAt", false)
    if status ~= STATUS_PENDING then
        startPolling(self)
    end
    return status == STATUS_READY
end

---Re-run the probe whenever the host event `eventName` fires, ignoring the
---negative cache. A timed-out gate that is still not ready starts a new
---polling round.
---
---Needs EventKit API 1, found through `Registry:Find` when this is called;
---raises at the caller when it is not loaded. Returns `false` when the gate
---already re-probes on that event. The connections are released by `Close`.
---@param self ReadinessKit.Gate
---@param eventName string a World of Warcraft event name
---@return boolean connected
local function gateReprobeOn(self, eventName)
    validateGate(self, "ReadinessKit.Gate:ReprobeOn", 3)
    validateNonEmptyString(eventName, "ReadinessKit.Gate:ReprobeOn eventName", 3)
    if rawget(self, "_status") == STATUS_CLOSED then
        error("ReadinessKit.Gate:ReprobeOn cannot subscribe a closed gate", 2)
    end

    local events = rawget(self, "_reprobeEvents")
    if events ~= false and events[eventName] ~= nil then
        return false
    end

    local EventKit = resolveEventKit("ReadinessKit.Gate:ReprobeOn", 3)

    local scope = rawget(self, "_eventScope")
    if scope == false then
        scope = EventKit:CreateScope()
        rawset(self, "_eventScope", scope)
    end

    local callback = rawget(self, "_reprobeCallback")
    if callback == false then
        callback = newReprobeCallback(self)
        rawset(self, "_reprobeCallback", callback)
    end

    local connection = scope:Connect(eventName, callback)
    if events == false then
        events = {}
        rawset(self, "_reprobeEvents", events)
    end
    events[eventName] = connection
    return true
end

---Close the gate: stop polling, release the event connections, free its name
---and call every queued waiter with `false, "closed"`. Returns `false` when it
---was already closed.
---
---A failure EventKit re-raises while releasing the connections is raised after
---the gate is fully closed and its waiters have been called.
---@param self ReadinessKit.Gate
---@return boolean closed
local function gateClose(self)
    validateGate(self, "ReadinessKit.Gate:Close", 3)
    if rawget(self, "_status") == STATUS_CLOSED then
        return false
    end

    rawset(self, "_status", STATUS_CLOSED)
    local name = rawget(self, "_name")
    if gates[name] == self then
        gates[name] = nil
    end

    stopTimer(self)
    local timer = rawget(self, "_timer")
    if timer ~= false then
        timer:SetUserData(nil)
        rawset(self, "_timer", false)
    end

    local scope = rawget(self, "_eventScope")
    rawset(self, "_eventScope", false)
    rawset(self, "_reprobeEvents", false)

    flushWaiters(self, false, REASON_CLOSED)

    if scope ~= false then
        scope:Close()
    end
    return true
end

---Return whether the gate is closed.
---@param self ReadinessKit.Gate
---@return boolean
local function gateIsClosed(self)
    validateGate(self, "ReadinessKit.Gate:IsClosed", 3)
    return rawget(self, "_status") == STATUS_CLOSED
end

-- Waiter methods -------------------------------------------------------------

---Stop waiting. Returns `false` when the callback already ran or the waiter
---was already cancelled. Cancelling a `WhenAll` waiter cancels its per-gate
---waiters too.
---@param self ReadinessKit.Waiter
---@return boolean cancelled
local function waiterCancel(self)
    validateWaiter(self, "ReadinessKit.Waiter:Cancel", 3)
    if rawget(self, "_status") ~= WAITER_QUEUED then
        return false
    end

    rawset(self, "_status", WAITER_CANCELLED)
    rawset(self, "_callback", false)

    local gate = rawget(self, "_gate")
    if gate ~= false then
        removeQueued(gate, self)
    end

    local children = rawget(self, "_children")
    if children ~= false then
        for index = 1, #children do
            waiterCancel(children[index])
        end
    end
    return true
end

---Return whether the callback is still due.
---@param self ReadinessKit.Waiter
---@return boolean
local function waiterIsPending(self)
    validateWaiter(self, "ReadinessKit.Waiter:IsPending", 3)
    return rawget(self, "_status") == WAITER_QUEUED
end

-- Package public API ---------------------------------------------------------

---Build one open gate. Every private field exists from the start, so no later
---write adds a key to the gate table.
---@param name string
---@param probe ReadinessKit.Probe
---@param intervalSeconds number
---@param timeoutSeconds number|false
---@param maxWaiters integer
---@return ReadinessKit.Gate
local function newGate(name, probe, intervalSeconds, timeoutSeconds, maxWaiters)
    return setmetatable({
        _schema = GATE_SCHEMA,
        _name = name,
        _probe = probe,
        _intervalSeconds = intervalSeconds,
        _timeoutSeconds = timeoutSeconds,
        _maxWaiters = maxWaiters,
        _status = STATUS_PENDING,
        _waiters = {},
        _spareWaiters = {},
        _waiterCount = 0,
        _timer = false,
        _waitStartedAt = false,
        _polls = 0,
        _negativeAt = false,
        _eventScope = false,
        _reprobeEvents = false,
        _reprobeCallback = false,
    }, GATE_METATABLE)
end

---Return the gate called `name`, creating it when there is none.
---
---A new gate runs `probe` once at once; when that answers "not yet" it polls
---every `intervalSeconds` until the probe answers or `timeoutSeconds` pass.
---When a gate with this name already exists it is returned unchanged and
---`probe` and `options` are ignored: the first definition wins, so every
---addon sharing a name shares one gate. The arguments are still validated.
---@param name string
---@param probe ReadinessKit.Probe
---@param options ReadinessKit.GateOptions?
---@return ReadinessKit.Gate
local function packageGate(_, name, probe, options)
    validateNonEmptyString(name, "ReadinessKit:Gate name", 3)
    validateFunction(probe, "ReadinessKit:Gate probe", 3)
    local intervalSeconds, timeoutSeconds, maxWaiters = readGateOptions(options, 3)

    local existing = gates[name]
    if existing ~= nil then
        return existing
    end

    local gate = newGate(name, probe, intervalSeconds, timeoutSeconds, maxWaiters)
    -- Registered before the first probe, so a probe that looks its own gate
    -- up finds it instead of defining a second one.
    gates[name] = gate

    if runProbe(gate) then
        rawset(gate, "_status", STATUS_READY)
        rawset(gate, "_negativeAt", false)
        return gate
    end

    local ok, message = pcall(startPolling, gate)
    if not ok then
        rawset(gate, "_status", STATUS_CLOSED)
        gates[name] = nil
        error(message, 0)
    end
    return gate
end

---Return the open gate called `name`, or `nil`.
---@param name string
---@return ReadinessKit.Gate?
local function packageGet(_, name)
    validateNonEmptyString(name, "ReadinessKit:Get name", 3)
    return gates[name]
end

---Build the one callback a `WhenAll` group queues on every gate. It calls
---through the shared dispatch table so an upgrade replaces its behaviour.
---@param group table
---@return ReadinessKit.Callback
local function newGroupCallback(group)
    return function(ready, reason)
        local settleGroup = rawget(dispatch, "settleGroup")
        settleGroup(group, ready, reason)
    end
end

---One gate of a `WhenAll` group reported. The group's callback runs once: with
---`true` after the last gate is ready, or with the first failure, after which
---the group stops waiting on the rest.
---@param group table
---@param ready boolean
---@param reason string?
local function settleGroup(group, ready, reason)
    if rawget(group, "_status") ~= WAITER_QUEUED then
        return
    end

    if ready then
        local remaining = rawget(group, "_remaining") - 1
        rawset(group, "_remaining", remaining)
        if remaining > 0 then
            return
        end
    end

    local callback = rawget(group, "_callback")
    rawset(group, "_status", WAITER_CALLED)
    rawset(group, "_callback", false)

    if not ready then
        local children = rawget(group, "_children")
        for index = 1, #children do
            waiterCancel(children[index])
        end
    end
    callback(ready, reason)
end

---Wait for every gate in `gates`.
---
---`callback(true)` runs once every gate is ready, at once when they already
---are. The first gate that times out or closes ends the wait with
---`callback(false, reason)` and cancels the rest. Each gate queues one waiter,
---so the group is bounded by the gates' own `maxWaiters`: when any gate's
---queue is full nothing stays queued and this returns `nil, "full"`.
---@param gateList ReadinessKit.Gate[]
---@param callback ReadinessKit.Callback
---@return ReadinessKit.Waiter? waiter
---@return string? reason
local function packageWhenAll(_, gateList, callback)
    if type(gateList) ~= "table" then
        error("ReadinessKit:WhenAll gates must be an array of ReadinessKit gates", 2)
    end
    validateFunction(callback, "ReadinessKit:WhenAll callback", 3)
    local count = #gateList
    for index = 1, count do
        local gate = gateList[index]
        if type(gate) ~= "table" or getmetatable(gate) ~= GATE_METATABLE then
            error("ReadinessKit:WhenAll gates must be an array of ReadinessKit gates", 2)
        end
        if rawget(gate, "_status") == STATUS_CLOSED then
            error("ReadinessKit:WhenAll cannot wait on a closed gate", 2)
        end
    end

    local group = newWaiter(false, callback, WAITER_QUEUED)
    local children = {}
    rawset(group, "_children", children)
    rawset(group, "_remaining", count)
    if count == 0 then
        rawset(group, "_status", WAITER_CALLED)
        rawset(group, "_callback", false)
        callback(true, nil)
        return group
    end

    local groupCallback = newGroupCallback(group)
    for index = 1, count do
        local child, reason = awaitGate(gateList[index], groupCallback)
        if child == nil then
            waiterCancel(group)
            return nil, reason
        end
        children[index] = child
        if rawget(group, "_status") ~= WAITER_QUEUED then
            -- A gate that had already timed out settled the group at once.
            break
        end
    end
    return group
end

-- Commit ---------------------------------------------------------------------

rawset(Gate, "IsReady", gateIsReady)
rawset(Gate, "Await", gateAwait)
rawset(Gate, "Probe", gateProbe)
rawset(Gate, "Invalidate", gateInvalidate)
rawset(Gate, "ReprobeOn", gateReprobeOn)
rawset(Gate, "Close", gateClose)
rawset(Gate, "IsClosed", gateIsClosed)

rawset(Waiter, "Cancel", waiterCancel)
rawset(Waiter, "IsPending", waiterIsPending)

rawset(ReadinessKit, "API", API_GENERATION)
rawset(ReadinessKit, "REVISION", IMPLEMENTATION_REVISION)
rawset(ReadinessKit, "Gate", packageGate)
rawset(ReadinessKit, "Get", packageGet)
rawset(ReadinessKit, "WhenAll", packageWhenAll)

rawset(dispatch, "pollTick", pollTick)
rawset(dispatch, "reprobe", reprobe)
rawset(dispatch, "settleGroup", settleGroup)
rawset(state, "runtimeRevision", IMPLEMENTATION_REVISION)

if not validatePublicSurface(ReadinessKit) or not validateCurrentState(ReadinessKit) then
    error("MoltenCodes ReadinessKit package state is corrupted or incomplete", 2)
end

return ReadinessKit
