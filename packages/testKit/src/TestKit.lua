-- MoltenCodes TestKit
--
-- Test suites that run inside the World of Warcraft client. Busted proves the
-- framework's logic against a fake client; only the real client can prove real
-- event order and payload shapes, combat lockdown, taint (`issecurevariable`
-- after our code ran) and the fidelity of the fake client itself. TestKit is
-- the small harness for that, and it is a development-only package: it is never
-- part of a release bundle and costs nothing unless a development addon loads
-- it.
--
-- A suite is registered against a LifecycleKit phase of one addon (`loaded` or
-- `ready`). `TestKit:Run` queues the suites it selects; a suite whose phase has
-- not been reached waits for it. Tests run one at a time inside one SchedulerKit
-- job, each step in its own coroutine, so a test may yield a frame, wait for an
-- event or poll a condition without holding the frame. Every `ctx:Replace` is
-- undone after its test, in reverse order, also when the test failed.
--
-- TestKit requires Registry API 2, LifecycleKit API 1 and SchedulerKit API 1.
-- EventKit API 1 and TimerKit API 1 are already in their dependency closures and
-- are found through `Registry:Find` when first needed: EventKit by
-- `ctx:WaitFor`, TimerKit by `TestKit:Run` for the per-test time limit and the
-- wait timeouts.
--
-- Contents
-- --------
--   Constants ............. identity, bounds, statuses, method lists
--   Public types .......... LuaCATS declarations for the published surface
--   Dependencies .......... Registry, LifecycleKit, SchedulerKit, host probes
--   Validation ............ public-surface and shared-state predicates
--   Bootstrap ............. Registry registration and inherited state
--   Found packages ........ EventKit and TimerKit through Registry:Find
--   Argument checks ....... receivers, names, numbers, option tables
--   Safe descriptions ..... describing values without printing secrets
--   Deep equality ......... the bounded comparison behind ToEqual
--   Matcher methods ....... ToBe, ToEqual, ToBeTruthy, ToBeNil, ToRaise, ToBeSecure
--   Context methods ....... Replace, Yield, WaitFor, WaitUntil, Expect, Fail, Log
--   Suite methods ......... Test, Before, After, Skip, GetName
--   Results ............... result records and the report
--   Runner ................ the job, test steps, phase gating, wake-ups
--   Package public API .... the facade published through Registry
--   Commit ................ prototype/facade assignment and self-check
--
-- The runner state machine and the package state are described in
-- `docs/INTERNALS.md`.

-- Constants ------------------------------------------------------------------

local PACKAGE_NAME = "testKit"
local API_GENERATION = 1
local IMPLEMENTATION_REVISION = 1
local REQUIRED_REGISTRY_API = 2
local REQUIRED_LIFECYCLEKIT_API = 1
local REQUIRED_SCHEDULERKIT_API = 1
local FOUND_EVENTKIT_API = 1
local FOUND_TIMERKIT_API = 1
local STATE_SCHEMA = 1

-- Every suite records the layout it was built with, so a later revision that
-- changes the layout can upgrade old suites lazily.
local SUITE_SCHEMA = 1

-- Bounds recorded in the package plan, and the smaller ones this file adds so
-- that nothing a suite registers can grow without limit.
local MAX_SUITES = 64
local MAX_TESTS = 256
local MAX_HOOKS = 16
local MAX_LOG_LINES = 64
local MAX_FINISHED_CALLBACKS = 16
local MAX_EQUAL_DEPTH = 16
local MAX_REPLACEMENTS = 256

-- A failure message quotes at most this many bytes of any string value, so a
-- report never carries a long string a test happened to compare.
local MAX_VALUE_BYTES = 64

-- A failure message or log line is cut at this many bytes.
local MAX_MESSAGE_BYTES = 256

-- The time one test may take, and separately its After hooks, before the
-- runner abandons it. Ten seconds is long for a test and short for a human
-- waiting on a `/run`.
local DEFAULT_TIMEOUT_SECONDS = 10

-- What a secret value is described as. The text is fixed: a message built from
-- a secret would itself be secret.
local SECRET_PLACEHOLDER = "<secret value>"

-- The two LifecycleKit phases a suite can wait for.
local PHASE_LOADED = "loaded"
local PHASE_READY = "ready"

-- Test statuses as `Report` publishes them.
local STATUS_PASSED = "passed"
local STATUS_FAILED = "failed"
local STATUS_SKIPPED = "skipped"
local STATUS_TIMEOUT = "timeout"

-- The reasons a method refuses with `nil, reason`, and the one `WaitFor` and
-- `WaitUntil` return.
local REASON_FULL = "full"
local REASON_TAKEN = "taken"
local REASON_UNKNOWN = "unknown"
local REASON_TIMEOUT = "timeout"

-- The states of a run entry: one queued run of one suite.
local ENTRY_WAITING = "waiting"
local ENTRY_QUEUED = "queued"
local ENTRY_RUNNING = "running"
local ENTRY_DONE = "done"

-- What one resume of a test step asks the runner to do next.
local OUTCOME_CONTINUE = "continue"
local OUTCOME_YIELD = "yield"
local OUTCOME_WAIT = "wait"
local OUTCOME_NEXT_FRAME = "nextFrame"
local OUTCOME_DONE = "done"

-- The separator between a suite name and a test name in a `Run` filter.
local FILTER_SEPARATOR = "/"

-- The complete set of fields `Suite` options accept. A file-local constant
-- keeps option validation allocation-free.
local SUITE_OPTION_KEYS = { phase = true, addonName = true, timeoutSeconds = true }

-- The options every runner job is scheduled with.
local RUNNER_JOB_OPTIONS = { name = "TestKit runner" }

-- The published surface, listed once so the public-surface predicate reads as
-- a checklist.
local FACADE_METHODS = { "Suite", "Run", "Report", "OnFinished", "Reset" }
local SUITE_METHODS = { "Test", "Before", "After", "Skip", "GetName" }
local CONTEXT_METHODS = { "Replace", "Yield", "WaitFor", "WaitUntil", "Expect", "Fail", "Log" }
local MATCHER_METHODS = { "ToBe", "ToEqual", "ToBeTruthy", "ToBeNil", "ToRaise", "ToBeSecure" }

-- Public types ---------------------------------------------------------------
--
-- TestKit publishes its methods by writing them onto shared prototype tables
-- kept in package state, so the editor-facing contract is declared here as
-- LuaCATS classes rather than inferred from those assignments.

---Option table accepted by `TestKit:Suite`.
---@class TestKit.SuiteOptions
---@field phase "loaded"|"ready"? The LifecycleKit phase the suite waits for. Defaults to `"ready"`.
---@field addonName string? The addon whose LifecycleKit instance the suite waits on. Defaults to the suite name.
---@field timeoutSeconds number? Seconds one test may take before it is abandoned as `"timeout"`, and separately its After hooks. Defaults to `10`.

---A test body, a Before hook or an After hook.
---@alias TestKit.TestFunction fun(ctx: TestKit.Context)

---Called once a run has nothing left to do.
---@alias TestKit.FinishedCallback fun(report: TestKit.Report)

---One registered suite.
---@class TestKit.Suite
---@field Test fun(self: TestKit.Suite, name: string, fn: TestKit.TestFunction): true?, string?
---@field Before fun(self: TestKit.Suite, fn: TestKit.TestFunction): true?, string?
---@field After fun(self: TestKit.Suite, fn: TestKit.TestFunction): true?, string?
---@field Skip fun(self: TestKit.Suite, name: string, reason: string?): true?, string?
---@field GetName fun(self: TestKit.Suite): string

---What a test, and its hooks, receive.
---@class TestKit.Context
---@field Replace fun(self: TestKit.Context, target: table, key: any, value: any): any, string?
---@field Yield fun(self: TestKit.Context)
---@field WaitFor fun(self: TestKit.Context, eventName: string, timeoutSeconds: number): boolean, ...
---@field WaitUntil fun(self: TestKit.Context, predicate: fun(): any, timeoutSeconds: number): boolean, string?
---@field Expect fun(self: TestKit.Context, actual: any): TestKit.Matcher
---@field Fail fun(self: TestKit.Context, message: string?)
---@field Log fun(self: TestKit.Context, message: any): boolean

---An expectation about one value. `Not` is the same expectation negated.
---@class TestKit.Matcher
---@field Not TestKit.Matcher
---@field ToBe fun(self: TestKit.Matcher, expected: any): true
---@field ToEqual fun(self: TestKit.Matcher, expected: any): true
---@field ToBeTruthy fun(self: TestKit.Matcher): true
---@field ToBeNil fun(self: TestKit.Matcher): true
---@field ToRaise fun(self: TestKit.Matcher, pattern: string?): true
---@field ToBeSecure fun(self: TestKit.Matcher, target: table?, key: string): true

---One test's outcome.
---@class TestKit.TestResult
---@field name string
---@field status "passed"|"failed"|"skipped"|"timeout"
---@field message string? Why it did not pass, or the skip reason.
---@field durationMs number Wall-clock milliseconds, `0` without `GetTimePreciseSec`.
---@field logs string[] What the test logged, at most 64 lines.

---One suite's outcomes.
---@class TestKit.SuiteReport
---@field name string
---@field phase "loaded"|"ready"
---@field addonName string
---@field tests TestKit.TestResult[]

---Counts across every suite in a report.
---@class TestKit.Totals
---@field suites integer
---@field tests integer
---@field passed integer
---@field failed integer
---@field skipped integer
---@field timeout integer

---The structured results `TestKit:Report` returns.
---@class TestKit.Report
---@field suites TestKit.SuiteReport[]
---@field totals TestKit.Totals

---The TestKit package facade published through Registry.
---@class TestKit
---@field API integer Public API generation.
---@field REVISION integer Compatible implementation revision.
---@field Suite fun(self: TestKit, name: string, options: TestKit.SuiteOptions?): TestKit.Suite?, string?
---@field Run fun(self: TestKit, filter: string?): integer?, string?
---@field Report fun(self: TestKit): TestKit.Report
---@field OnFinished fun(self: TestKit, callback: TestKit.FinishedCallback): true?, string?
---@field Reset fun(self: TestKit): true

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
    error("MoltenCodes TestKit requires Registry API 2 to be loaded first", 2)
end

local bootstrapPackage = rawget(Registry, "Bootstrap")
local getPackage = rawget(Registry, "Get")
if type(bootstrapPackage) ~= "function" or type(getPackage) ~= "function" then
    error("MoltenCodes TestKit requires a valid Registry API 2 facade", 2)
end

-- LifecycleKit supplies the phases suites wait for.
local LifecycleKit = getPackage(Registry, "lifecycleKit", REQUIRED_LIFECYCLEKIT_API)
if
    type(LifecycleKit) ~= "table"
    or rawget(LifecycleKit, "API") ~= REQUIRED_LIFECYCLEKIT_API
    or type(rawget(LifecycleKit, "ForAddon")) ~= "function"
then
    error("MoltenCodes TestKit requires LifecycleKit API 1 to be loaded first", 2)
end

-- SchedulerKit runs the tests: one job at a time, under its frame budget.
local SchedulerKit = getPackage(Registry, "schedulerKit", REQUIRED_SCHEDULERKIT_API)
local SchedulerScope = type(SchedulerKit) == "table" and rawget(SchedulerKit, "Scope") or nil
if
    type(SchedulerKit) ~= "table"
    or rawget(SchedulerKit, "API") ~= REQUIRED_SCHEDULERKIT_API
    or type(rawget(SchedulerKit, "CreateScope")) ~= "function"
    or type(SchedulerScope) ~= "table"
    or type(rawget(SchedulerScope, "Schedule")) ~= "function"
    or type(rawget(SchedulerScope, "NextFrame")) ~= "function"
    or type(rawget(SchedulerScope, "IsClosed")) ~= "function"
then
    error("MoltenCodes TestKit requires SchedulerKit API 1 to be loaded first", 2)
end

---Read a host function from the global table at call time, or `nil`.
---
---The host probes (`issecretvalue`, `issecurevariable`, `GetTimePreciseSec`)
---are read when they are used rather than once at load: TestKit is a test
---harness, and reading them late lets a test replace one with `ctx:Replace`.
---@param name string
---@return function|nil
local function readHostFunction(name)
    -- Host APIs are World of Warcraft client functions reachable only through the global table.
    -- selene: allow(global_usage)
    local value = rawget(_G, name)
    if type(value) == "function" then
        return value
    end
    return nil
end

---Whether `value` is a secret value. Clients without secret values have no
---`issecretvalue`, and nothing is secret there.
---@param value any
---@return boolean
local function isSecret(value)
    local probe = readHostFunction("issecretvalue")
    if probe == nil then
        return false
    end
    return probe(value) == true
end

---Return the wall clock in milliseconds, or `false` on a host without it.
---@return number|false
local function nowMilliseconds()
    local clock = readHostFunction("GetTimePreciseSec")
    if clock == nil then
        return false
    end
    return clock() * 1000
end

---Hand a failure nobody called for (an `OnFinished` callback) to the host
---error handler.
---@param message any
local function reportError(message)
    local getErrorHandler = readHostFunction("geterrorhandler")
    if getErrorHandler ~= nil then
        local handler = getErrorHandler()
        if type(handler) == "function" then
            handler(message)
            return
        end
    end

    -- Outside a WoW client there is no error handler to report through.
    -- Printing is what the client's own default handler does.
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

---Whether `implementation` exposes the complete TestKit API 1 surface.
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
        and type(rawget(currentState, "suitePrototype")) == "table"
        and type(rawget(currentState, "contextPrototype")) == "table"
        and type(rawget(currentState, "matcherPrototype")) == "table"
        and type(rawget(currentState, "suiteMetatable")) == "table"
        and type(rawget(currentState, "contextMetatable")) == "table"
        and type(rawget(currentState, "matcherMetatable")) == "table"
        and type(rawget(currentState, "yieldTokens")) == "table"
        and type(rawget(currentState, "suites")) == "table"
        and type(rawget(currentState, "suitesByName")) == "table"
        and type(rawget(currentState, "finishedCallbacks")) == "table"
        and type(rawget(currentState, "queue")) == "table"
        and type(rawget(currentState, "waiting")) == "table"
        and type(rawget(currentState, "runnerCallback")) == "function"
        and type(rawget(currentState, "deadlineCallback")) == "function"
end

---Whether `implementation` carries package state of this revision's schema,
---with every suite, context and matcher method committed.
---@param implementation table
---@return boolean
local function validateCurrentState(implementation)
    local currentState = rawget(implementation, "_state")
    return validateStateBase(currentState)
        and hasMethods(rawget(currentState, "suitePrototype"), SUITE_METHODS)
        and hasMethods(rawget(currentState, "contextPrototype"), CONTEXT_METHODS)
        and hasMethods(rawget(currentState, "matcherPrototype"), MATCHER_METHODS)
end

-- Bootstrap ------------------------------------------------------------------

-- `Registry:Bootstrap` owns the reconciliation every embedded package repeats:
-- look the package up, refuse to reinterpret state owned by a newer revision,
-- and register this one. What stays here is what only TestKit can answer.
local TestKit, previousRevision, selected = bootstrapPackage(Registry, {
    package = PACKAGE_NAME,
    api = API_GENERATION,
    revision = IMPLEMENTATION_REVISION,
    label = "MoltenCodes TestKit",
    validatePublicSurface = validatePublicSurface,
    validateState = validateCurrentState,
})

if TestKit == nil then
    -- An equal or newer compatible revision already owns the shared package table.
    return selected
end

local state = rawget(TestKit, "_state")

if previousRevision == nil then
    if state ~= nil then
        error("MoltenCodes TestKit package state is corrupted or incomplete", 2)
    end

    local dispatch = {}
    state = {
        schema = STATE_SCHEMA,
        -- Closures TestKit hands out (the runner job, phase subscriptions, wait
        -- callbacks, the deadline timer) call through this table, so a newer
        -- revision replaces the behaviour behind closures an older one created.
        dispatch = dispatch,
        runtimeRevision = 0,
        -- Method tables and metatables. They live in package state so objects
        -- built by an older copy gain a newer copy's methods in place.
        suitePrototype = {},
        contextPrototype = {},
        matcherPrototype = {},
        suiteMetatable = {},
        contextMetatable = {},
        matcherMetatable = {},
        -- The values a test step yields to the runner. Kept in state so that a
        -- step suspended under one revision is understood by the next.
        yieldTokens = { frame = {}, wait = {}, nextFrame = {} },
        -- Suites in registration order, and by name.
        suites = {},
        suitesByName = {},
        finishedCallbacks = {},
        -- The run: entries whose phase has been reached, in order; entries
        -- still waiting for their phase; the entry and test being executed.
        queue = {},
        waiting = {},
        activeEntry = false,
        activeTest = false,
        -- Whether a run has started and not yet finished.
        runActive = false,
        -- Whether a test step is on the stack (Reset refuses then).
        executing = false,
        -- The scheduled or running runner job, or `false`.
        runnerJob = false,
        -- Kit-owned scopes, created on first use.
        schedulerScope = false,
        timerScope = false,
        eventScope = false,
        -- The one SchedulerKit callback every runner job shares.
        runnerCallback = function(context)
            local runnerBody = rawget(dispatch, "runnerBody")
            runnerBody(context)
        end,
        -- The one TimerKit callback every test deadline shares; the test
        -- record travels on the timer as TimerKit user data.
        deadlineCallback = function(timer)
            local deadlineReached = rawget(dispatch, "deadlineReached")
            deadlineReached(timer:GetUserData())
        end,
    }
    rawset(TestKit, "_state", state)
elseif not validateStateBase(state) then
    error("MoltenCodes TestKit package state is corrupted or incomplete", 2)
end

local Suite = rawget(state, "suitePrototype")
local Context = rawget(state, "contextPrototype")
local Matcher = rawget(state, "matcherPrototype")
local SUITE_METATABLE = rawget(state, "suiteMetatable")
local CONTEXT_METATABLE = rawget(state, "contextMetatable")
local MATCHER_METATABLE = rawget(state, "matcherMetatable")
local YIELD_TOKENS = rawget(state, "yieldTokens")
local dispatch = rawget(state, "dispatch")
local suites = rawget(state, "suites")
local suitesByName = rawget(state, "suitesByName")
local finishedCallbacks = rawget(state, "finishedCallbacks")
local queue = rawget(state, "queue")
local waiting = rawget(state, "waiting")
rawset(SUITE_METATABLE, "__index", Suite)
rawset(CONTEXT_METATABLE, "__index", Context)
rawset(MATCHER_METATABLE, "__index", Matcher)

-- Found packages -------------------------------------------------------------
--
-- EventKit and TimerKit are in the dependency closures of LifecycleKit and
-- SchedulerKit, so they are always loaded before TestKit. They are not direct
-- dependencies, so they are found with `Registry:Find` when first needed and
-- each gets one Kit-owned scope.

---Find a package TestKit uses without declaring it.
---@param packageName string
---@param displayName string
---@param api integer
---@param methodName string public method name, used in the failure
---@param level integer stack level the failure is reported at
---@return table
local function findPackage(packageName, displayName, api, methodName, level)
    local find = rawget(Registry, "Find")
    if type(find) ~= "function" then
        error(methodName .. " requires Registry:Find (Registry API 2 revision 7 or newer)", level)
    end
    local found, reason = find(Registry, packageName, api)
    if type(found) ~= "table" or type(rawget(found, "CreateScope")) ~= "function" then
        error(
            methodName
                .. " requires "
                .. displayName
                .. " API "
                .. api
                .. ", which is not loaded ("
                .. tostring(reason)
                .. ")",
            level
        )
    end
    return found
end

---Return the Kit-owned TimerKit scope, creating it on first use or after it
---was closed from outside.
---@param methodName string
---@param level integer
---@return TimerKit.Scope
local function getTimerScope(methodName, level)
    local scope = rawget(state, "timerScope")
    if scope == false or scope:IsClosed() then
        local TimerKit =
            findPackage("timerKit", "TimerKit", FOUND_TIMERKIT_API, methodName, level + 1)
        scope = TimerKit:CreateScope()
        rawset(state, "timerScope", scope)
    end
    return scope
end

---Return the Kit-owned EventKit scope, creating it on first use or after it
---was closed from outside.
---@param methodName string
---@param level integer
---@return EventKit.Scope
local function getEventScope(methodName, level)
    local scope = rawget(state, "eventScope")
    if scope == false or scope:IsClosed() then
        local EventKit =
            findPackage("eventKit", "EventKit", FOUND_EVENTKIT_API, methodName, level + 1)
        scope = EventKit:CreateScope()
        rawset(state, "eventScope", scope)
    end
    return scope
end

---Return the Kit-owned SchedulerKit scope the runner jobs live in.
---@return SchedulerKit.Scope
local function getSchedulerScope()
    local scope = rawget(state, "schedulerScope")
    if scope == false or scope:IsClosed() then
        scope = SchedulerKit:CreateScope()
        rawset(state, "schedulerScope", scope)
    end
    return scope
end

-- Argument checks ------------------------------------------------------------
--
-- Argument validation raises with an explicit stack level so the reported
-- position is the line that called the public method, never a line inside
-- TestKit. `level` is always the value `error` needs *inside the function that
-- receives it*, so every further hop towards `error` adds exactly one.

---@param value any
---@param methodName string
---@param level integer
local function validateSuite(value, methodName, level)
    if type(value) ~= "table" or getmetatable(value) ~= SUITE_METATABLE then
        error(methodName .. " must be called on a TestKit suite", level)
    end
end

---@param value any
---@param methodName string
---@param level integer
local function validateMatcher(value, methodName, level)
    if type(value) ~= "table" or getmetatable(value) ~= MATCHER_METATABLE then
        error(methodName .. " must be called on a TestKit matcher", level)
    end
end

---Refuse anything but a context whose test is still running, and return the
---test record.
---@param value any
---@param methodName string
---@param level integer
---@return table record
local function validateContext(value, methodName, level)
    if type(value) ~= "table" or getmetatable(value) ~= CONTEXT_METATABLE then
        error(methodName .. " must be called on a TestKit context", level)
    end
    local record = rawget(value, "_record")
    if record == false then
        error(methodName .. " was called after its test finished", level)
    end
    return record
end

---Refuse anything but a non-empty, non-secret string. The secret check comes
---before the emptiness comparison, which would raise on a secret.
---@param value any
---@param label string
---@param level integer
local function validateName(value, label, level)
    if type(value) ~= "string" then
        error(label .. " must be a non-empty string", level)
    end
    if isSecret(value) then
        error(label .. " must not be a secret value", level)
    end
    if value == "" then
        error(label .. " must be a non-empty string", level)
    end
end

---@param value any
---@param label string
---@param level integer
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

---@param value any
---@param label string
---@param level integer
local function validateTimeout(value, label, level)
    if isSecret(value) or not isPositiveFiniteNumber(value) then
        error(label .. " must be a finite number greater than zero", level)
    end
end

---Refuse any option field outside `SUITE_OPTION_KEYS`, naming the
---alphabetically first unknown field.
---@param options table
---@param level integer
local function validateSuiteOptionKeys(options, level)
    local firstUnknown = nil
    for key in next, options do
        if SUITE_OPTION_KEYS[key] ~= true then
            local text = type(key) == "string" and key or ("<" .. type(key) .. ">")
            if firstUnknown == nil or text < firstUnknown then
                firstUnknown = text
            end
        end
    end
    if firstUnknown ~= nil then
        error('TestKit:Suite options contains unknown field "' .. firstUnknown .. '"', level)
    end
end

---Validate `Suite` options and return them with their defaults applied.
---@param name string the suite name, the default addon name
---@param options any
---@param level integer
---@return string phase
---@return string addonName
---@return number timeoutSeconds
local function readSuiteOptions(name, options, level)
    if options == nil then
        return PHASE_READY, name, DEFAULT_TIMEOUT_SECONDS
    end
    if type(options) ~= "table" then
        error("TestKit:Suite options must be a table", level)
    end
    validateSuiteOptionKeys(options, level + 1)

    local phase = rawget(options, "phase")
    if phase == nil then
        phase = PHASE_READY
    elseif phase ~= PHASE_LOADED and phase ~= PHASE_READY then
        error('TestKit:Suite phase must be "loaded" or "ready"', level)
    end

    local addonName = rawget(options, "addonName")
    if addonName == nil then
        addonName = name
    else
        validateName(addonName, "TestKit:Suite addonName", level + 1)
    end

    local timeoutSeconds = rawget(options, "timeoutSeconds")
    if timeoutSeconds == nil then
        timeoutSeconds = DEFAULT_TIMEOUT_SECONDS
    else
        validateTimeout(timeoutSeconds, "TestKit:Suite timeoutSeconds", level + 1)
    end

    return phase, addonName, timeoutSeconds
end

---Split a `Run` filter into a suite name and a test name.
---@param filter any
---@param level integer
---@return string|false suiteName `false` for every suite
---@return string|false testName `false` for every test of the suite
local function readFilter(filter, level)
    if filter == nil then
        return false, false
    end
    validateName(filter, "TestKit:Run filter", level + 1)
    local separator = string.find(filter, FILTER_SEPARATOR, 1, true)
    if separator == nil then
        return filter, false
    end
    local suiteName = string.sub(filter, 1, separator - 1)
    local testName = string.sub(filter, separator + 1)
    if suiteName == "" or testName == "" then
        error('TestKit:Run filter must be "suite" or "suite/test"', level)
    end
    return suiteName, testName
end

-- Safe descriptions ----------------------------------------------------------
--
-- A failure message must explain a mismatch without becoming a problem of its
-- own: a secret value is described by a fixed placeholder, a string by at most
-- `MAX_VALUE_BYTES` quoted bytes, and a table or function by its type alone
-- (`tostring` could run a `__tostring` metamethod).

---Quote a string, cut to `MAX_VALUE_BYTES`, on one line.
---@param text string a string that is known not to be secret
---@return string
local function quoteString(text)
    local length = #text
    local shown = text
    if length > MAX_VALUE_BYTES then
        shown = string.sub(text, 1, MAX_VALUE_BYTES)
    end
    local quoted = string.gsub(string.format("%q", shown), "\\\n", "\\n")
    if length > MAX_VALUE_BYTES then
        return quoted .. "... (" .. length .. " bytes)"
    end
    return quoted
end

---Describe `value` by its type and a short, safe representation.
---@param value any
---@return string
local function describeValue(value)
    if isSecret(value) then
        return SECRET_PLACEHOLDER
    end
    local kind = type(value)
    if kind == "nil" then
        return "nil"
    elseif kind == "boolean" then
        return value and "boolean true" or "boolean false"
    elseif kind == "number" then
        return "number " .. tostring(value)
    elseif kind == "string" then
        return "string " .. quoteString(value)
    end
    return kind
end

---Cut a message to `MAX_MESSAGE_BYTES`.
---@param text string
---@return string
local function limitMessage(text)
    if #text <= MAX_MESSAGE_BYTES then
        return text
    end
    return string.sub(text, 1, MAX_MESSAGE_BYTES) .. "... (" .. #text .. " bytes)"
end

---Turn anything a test raised or passed to `Fail`/`Log` into a safe message.
---@param value any
---@return string
local function describeMessage(value)
    if isSecret(value) then
        return SECRET_PLACEHOLDER
    end
    if type(value) == "string" then
        return limitMessage(value)
    end
    return "error object: " .. describeValue(value)
end

---Describe one step of a key path: `.name` for an identifier, `[...]` else.
---@param key any a table key, which can never be a secret
---@return string
local function describeKey(key)
    if type(key) == "string" and string.find(key, "^[%a_][%w_]*$") and #key <= MAX_VALUE_BYTES then
        return "." .. key
    elseif type(key) == "string" then
        return "[" .. quoteString(key) .. "]"
    elseif type(key) == "number" or type(key) == "boolean" then
        return "[" .. tostring(key) .. "]"
    end
    return "[" .. type(key) .. "]"
end

---Join a key trail into a path such as `.items[3].name`.
---@param trail any[]
---@return string
local function describePath(trail)
    local parts = {}
    for index = 1, #trail do
        parts[index] = describeKey(trail[index])
    end
    return table.concat(parts)
end

-- Deep equality --------------------------------------------------------------

---Compare two values structurally, at most `MAX_EQUAL_DEPTH` tables deep.
---
---Tables are compared key by key with raw access, so metatables play no part.
---On a mismatch `trail` is left holding the keys that lead to it.
---@param actual any
---@param expected any
---@param depth integer tables already entered
---@param trail any[] the key path, pushed and popped on the way
---@return boolean equal
---@return string? reason why not
---@return boolean? secret whether a secret value made the comparison impossible
local function compareValues(actual, expected, depth, trail)
    if isSecret(actual) or isSecret(expected) then
        return false, "a secret value cannot be compared", true
    end
    if rawequal(actual, expected) then
        return true
    end
    if type(actual) ~= "table" or type(expected) ~= "table" then
        return false,
            describeValue(actual) .. " where " .. describeValue(expected) .. " was expected"
    end
    if depth >= MAX_EQUAL_DEPTH then
        return false, "tables nested deeper than " .. MAX_EQUAL_DEPTH .. " levels"
    end

    for key, value in next, actual do
        trail[#trail + 1] = key
        local equal, reason, secret = compareValues(value, rawget(expected, key), depth + 1, trail)
        if not equal then
            return false, reason, secret
        end
        trail[#trail] = nil
    end
    for key, value in next, expected do
        if rawget(actual, key) == nil then
            trail[#trail + 1] = key
            if isSecret(value) then
                return false, "a secret value cannot be compared", true
            end
            return false, "nil where " .. describeValue(value) .. " was expected"
        end
    end
    return true
end

-- Matcher methods ------------------------------------------------------------
--
-- Each matcher method ends in `conclude`, which raises at the test's own line:
-- `conclude` is level 1, the matcher method level 2 and the test level 3. The
-- call is a statement, never `return conclude(...)`: a Lua 5.1 tail call
-- would remove the matcher's frame and the message would lose its position.

---Pass, or raise the failure message at the line that called the matcher.
---@param matcher table
---@param passed boolean the outcome before negation
---@param subject string what the expectation is about, already described
---@param phrase string e.g. `"to be number 2"`
---@param detail string? what was observed, appended in parentheses
local function conclude(matcher, passed, subject, phrase, detail)
    local negated = rawget(matcher, "_negated")
    if negated then
        passed = not passed
    end
    if passed then
        return
    end
    local text = "expected " .. subject .. (negated and " not " or " ") .. phrase
    if detail ~= nil then
        text = text .. " (" .. detail .. ")"
    end
    error(limitMessage(text), 3)
end

---Raise a failure that negation cannot turn into a pass: a comparison that
---could not be made at all.
---@param subject string
---@param reason string
---@param level integer
local function refuse(subject, reason, level)
    error("expected " .. subject .. ": " .. reason, level)
end

---Expect the value to be `expected` itself (`rawequal`, no metamethods).
---@param self TestKit.Matcher
---@param expected any
---@return true
local function matcherToBe(self, expected)
    validateMatcher(self, "TestKit.Matcher:ToBe", 3)
    local actual = rawget(self, "_actual")
    if isSecret(actual) or isSecret(expected) then
        refuse(describeValue(actual), "a secret value cannot be compared", 3)
    end
    conclude(
        self,
        rawequal(actual, expected),
        describeValue(actual),
        "to be " .. describeValue(expected)
    )
    return true
end

---Expect the value to equal `expected` structurally, tables compared key by
---key at most 16 levels deep.
---@param self TestKit.Matcher
---@param expected any
---@return true
local function matcherToEqual(self, expected)
    validateMatcher(self, "TestKit.Matcher:ToEqual", 3)
    local actual = rawget(self, "_actual")
    local trail = {}
    local equal, reason, secret = compareValues(actual, expected, 0, trail)
    local path = describePath(trail)
    if secret then
        refuse(describeValue(actual), reason .. (path ~= "" and (" at " .. path) or ""), 3)
    end
    local detail = nil
    if not equal then
        detail = (path ~= "" and ("at " .. path .. ": ") or "") .. reason
    end
    conclude(self, equal, describeValue(actual), "to equal " .. describeValue(expected), detail)
    return true
end

---Expect the value to be neither `nil` nor `false`.
---@param self TestKit.Matcher
---@return true
local function matcherToBeTruthy(self)
    validateMatcher(self, "TestKit.Matcher:ToBeTruthy", 3)
    local actual = rawget(self, "_actual")
    local kind = type(actual)
    if kind == "boolean" and isSecret(actual) then
        refuse(SECRET_PLACEHOLDER, "a secret boolean cannot be tested", 3)
    end
    -- A secret of another type is truthy: its type is not secret, and the
    -- comparison with `false` is only reached for a plain boolean.
    local truthy = kind ~= "nil" and not (kind == "boolean" and actual == false)
    conclude(self, truthy, describeValue(actual), "to be truthy")
    return true
end

---Expect the value to be `nil`.
---@param self TestKit.Matcher
---@return true
local function matcherToBeNil(self)
    validateMatcher(self, "TestKit.Matcher:ToBeNil", 3)
    local actual = rawget(self, "_actual")
    conclude(self, type(actual) == "nil", describeValue(actual), "to be nil")
    return true
end

---Expect the value, a function, to raise when called with no arguments; with
---`pattern`, to raise a string that matches the Lua pattern.
---@param self TestKit.Matcher
---@param pattern string?
---@return true
local function matcherToRaise(self, pattern)
    validateMatcher(self, "TestKit.Matcher:ToRaise", 3)
    if pattern ~= nil then
        validateName(pattern, "TestKit.Matcher:ToRaise pattern", 3)
    end
    local actual = rawget(self, "_actual")
    if type(actual) ~= "function" then
        refuse(describeValue(actual), "ToRaise needs a function", 3)
    end

    local phrase = "to raise"
    if pattern ~= nil then
        phrase = "to raise an error matching " .. quoteString(pattern)
    end

    local ok, raised = pcall(actual)
    if ok then
        conclude(self, false, "function", phrase, "it returned normally")
        return true
    end
    if pattern == nil then
        conclude(self, true, "function", phrase, "it raised " .. describeValue(raised))
        return true
    end
    if isSecret(raised) then
        refuse("function", "it raised a secret value, which cannot be matched", 3)
    end
    local matched = type(raised) == "string" and string.find(raised, pattern) ~= nil
    conclude(self, matched, "function", phrase, "it raised " .. describeValue(raised))
    return true
end

---Expect `target[key]`, or the global `key` when `target` is `nil`, to be
---secure according to `issecurevariable`. The value given to `Expect` is not
---used.
---@param self TestKit.Matcher
---@param target table?
---@param key string
---@return true
local function matcherToBeSecure(self, target, key)
    validateMatcher(self, "TestKit.Matcher:ToBeSecure", 3)
    if target ~= nil and type(target) ~= "table" then
        error("TestKit.Matcher:ToBeSecure target must be a table or nil", 2)
    end
    validateName(key, "TestKit.Matcher:ToBeSecure key", 3)

    local subject = (target == nil and "global " or "field ") .. quoteString(key)
    local probe = readHostFunction("issecurevariable")
    if probe == nil then
        refuse(subject, "issecurevariable is not available on this host", 3)
    end

    local secure, taintedBy = false, nil
    if probe ~= nil and target == nil then
        secure, taintedBy = probe(key)
    elseif probe ~= nil then
        secure, taintedBy = probe(target, key)
    end
    local detail = nil
    if not secure then
        detail = "tainted by " .. describeValue(taintedBy)
    end
    conclude(self, secure and true or false, subject, "to be secure", detail)
    return true
end

-- Context methods ------------------------------------------------------------

---Refuse a call that would have to suspend the test from anywhere but the
---test step's own coroutine.
---@param record table
---@param methodName string
---@param level integer
local function validateRunningStep(record, methodName, level)
    if record.coroutine == false or coroutine.running() ~= record.coroutine then
        error(methodName .. " must be called from the running test or hook", level)
    end
end

---Replace `target[key]` with `value` for the rest of the test.
---
---The write is raw, and so is the read of the previous value, so a key that
---was only reachable through `__index` comes back as it was. Replacements are
---undone after the test's After hooks, in reverse order, whatever the outcome.
---A secret value is refused. Returns the previous value. A test holds at most
---256 replacements: past that nothing is written and the call returns
---`nil, "full"`, so a caller that cares checks the second value.
---@param self TestKit.Context
---@param target table
---@param key any
---@param value any
---@return any previous
---@return string? reason `"full"` when the test already holds 256 replacements
local function contextReplace(self, target, key, value)
    local record = validateContext(self, "TestKit.Context:Replace", 3)
    if type(target) ~= "table" then
        error("TestKit.Context:Replace target must be a table", 2)
    end
    if type(key) == "nil" then
        error("TestKit.Context:Replace key must not be nil", 2)
    end
    if isSecret(key) then
        error("TestKit.Context:Replace key must not be a secret value", 2)
    end
    if type(key) == "number" and key ~= key then
        error("TestKit.Context:Replace key must not be NaN", 2)
    end
    if isSecret(value) then
        error("TestKit.Context:Replace value must not be a secret value", 2)
    end

    if record.replacementCount >= MAX_REPLACEMENTS then
        return nil, REASON_FULL
    end

    local previous = rawget(target, key)
    local replacements = record.replacements
    local base = record.replacementCount * 3
    replacements[base + 1] = target
    replacements[base + 2] = key
    replacements[base + 3] = previous
    record.replacementCount = record.replacementCount + 1
    rawset(target, key, value)
    return previous
end

---Suspend the test until the scheduler resumes its job, which is on a later
---pass under the frame budget.
---@param self TestKit.Context
local function contextYield(self)
    local record = validateContext(self, "TestKit.Context:Yield", 3)
    validateRunningStep(record, "TestKit.Context:Yield", 3)
    coroutine.yield(YIELD_TOKENS.frame)
end

---Build the callback a `WaitFor` connects: it records the payload and wakes
---the runner through the dispatch table.
---@param waiter table
---@return fun(eventName: string, ...)
local function newEventCallback(waiter)
    return function(_, ...)
        local eventArrived = rawget(dispatch, "eventArrived")
        eventArrived(waiter, ...)
    end
end

---Build the timer callback that ends a wait.
---@param waiter table
---@return fun()
local function newWaitTimeoutCallback(waiter)
    return function()
        local waitTimedOut = rawget(dispatch, "waitTimedOut")
        waitTimedOut(waiter)
    end
end

---Wait until the host event `eventName` fires or `timeoutSeconds` pass.
---
---Returns `true` and the event's payload (without the event name), or
---`false, "timeout"`. The test is suspended meanwhile, and the runner job ends
---until the event or the timer wakes it.
---@param self TestKit.Context
---@param eventName string
---@param timeoutSeconds number
---@return boolean fired
---@return any ... the payload, or `"timeout"`
local function contextWaitFor(self, eventName, timeoutSeconds)
    local record = validateContext(self, "TestKit.Context:WaitFor", 3)
    validateName(eventName, "TestKit.Context:WaitFor eventName", 3)
    validateTimeout(timeoutSeconds, "TestKit.Context:WaitFor timeoutSeconds", 3)
    validateRunningStep(record, "TestKit.Context:WaitFor", 3)

    local eventScope = getEventScope("TestKit.Context:WaitFor", 3)
    local timerScope = getTimerScope("TestKit.Context:WaitFor", 3)
    local waiter = { record = record, fired = false, timedOut = false, payload = false, count = 0 }
    local connection = eventScope:Once(eventName, newEventCallback(waiter))
    local timer = timerScope:After(timeoutSeconds, newWaitTimeoutCallback(waiter))

    while not waiter.fired and not waiter.timedOut do
        coroutine.yield(YIELD_TOKENS.wait)
    end

    connection:Disconnect()
    if timer:IsPending() then
        timer:Cancel()
    end
    if waiter.fired then
        return true, unpack(waiter.payload, 1, waiter.count)
    end
    return false, REASON_TIMEOUT
end

---Poll `predicate` once per frame until it returns a truthy value or
---`timeoutSeconds` pass. Returns `true`, or `false, "timeout"`. A predicate
---that is already true returns at once without suspending the test.
---@param self TestKit.Context
---@param predicate fun(): any
---@param timeoutSeconds number
---@return boolean satisfied
---@return string? reason
local function contextWaitUntil(self, predicate, timeoutSeconds)
    local record = validateContext(self, "TestKit.Context:WaitUntil", 3)
    validateFunction(predicate, "TestKit.Context:WaitUntil predicate", 3)
    validateTimeout(timeoutSeconds, "TestKit.Context:WaitUntil timeoutSeconds", 3)
    validateRunningStep(record, "TestKit.Context:WaitUntil", 3)

    if predicate() then
        return true
    end

    local timerScope = getTimerScope("TestKit.Context:WaitUntil", 3)
    local waiter = { record = record, fired = false, timedOut = false, payload = false, count = 0 }
    local timer = timerScope:After(timeoutSeconds, newWaitTimeoutCallback(waiter))
    while true do
        coroutine.yield(YIELD_TOKENS.nextFrame)
        if predicate() then
            if timer:IsPending() then
                timer:Cancel()
            end
            return true
        end
        if waiter.timedOut then
            return false, REASON_TIMEOUT
        end
    end
end

---Start an expectation about `actual`.
---@param self TestKit.Context
---@param actual any
---@return TestKit.Matcher
local function contextExpect(self, actual)
    validateContext(self, "TestKit.Context:Expect", 3)
    local matcher = setmetatable({ _actual = actual, _negated = false }, MATCHER_METATABLE)
    rawset(matcher, "Not", setmetatable({ _actual = actual, _negated = true }, MATCHER_METATABLE))
    return matcher
end

---Fail the test with `message` (a string, cut to 256 bytes; anything else is
---described safely).
---@param self TestKit.Context
---@param message any
local function contextFail(self, message)
    validateContext(self, "TestKit.Context:Fail", 3)
    if message == nil then
        message = "failed"
    end
    error(describeMessage(message), 2)
end

---Keep one line with the test's result. Returns `false`, keeping nothing,
---once the test has 64 lines.
---@param self TestKit.Context
---@param message any
---@return boolean kept
local function contextLog(self, message)
    local record = validateContext(self, "TestKit.Context:Log", 3)
    local logs = record.result.logs
    if #logs >= MAX_LOG_LINES then
        return false
    end
    logs[#logs + 1] = describeMessage(message)
    return true
end

-- Suite methods --------------------------------------------------------------

---Refuse a test name the suite already has.
---@param suite table
---@param name string
---@param methodName string
---@param level integer
local function validateNewTestName(suite, name, methodName, level)
    if rawget(suite, "_testIndex")[name] ~= nil then
        error(methodName .. " suite already has a test named " .. quoteString(name), level)
    end
end

---Append a test record, or refuse with `"full"`.
---@param suite table
---@param name string
---@param fn TestKit.TestFunction|false
---@param skipReason string|false
---@return true?
---@return string?
local function addTest(suite, name, fn, skipReason)
    local tests = rawget(suite, "_tests")
    if #tests >= MAX_TESTS then
        return nil, REASON_FULL
    end
    tests[#tests + 1] = { name = name, fn = fn, skipReason = skipReason }
    rawget(suite, "_testIndex")[name] = #tests
    return true
end

---Register a test. Returns `true`, or `nil, "full"` past 256 tests.
---@param self TestKit.Suite
---@param name string
---@param fn TestKit.TestFunction
---@return true?
---@return string?
local function suiteTest(self, name, fn)
    validateSuite(self, "TestKit.Suite:Test", 3)
    validateName(name, "TestKit.Suite:Test name", 3)
    validateFunction(fn, "TestKit.Suite:Test fn", 3)
    validateNewTestName(self, name, "TestKit.Suite:Test", 3)
    return addTest(self, name, fn, false)
end

---Register a test that is reported as skipped with `reason`. Returns `true`,
---or `nil, "full"` past 256 tests.
---@param self TestKit.Suite
---@param name string
---@param reason string?
---@return true?
---@return string?
local function suiteSkip(self, name, reason)
    validateSuite(self, "TestKit.Suite:Skip", 3)
    validateName(name, "TestKit.Suite:Skip name", 3)
    if reason == nil then
        reason = "skipped"
    else
        validateName(reason, "TestKit.Suite:Skip reason", 3)
    end
    validateNewTestName(self, name, "TestKit.Suite:Skip", 3)
    return addTest(self, name, false, limitMessage(reason))
end

---Append a hook, or refuse with `"full"`.
---@param suite table
---@param field string `"_before"` or `"_after"`
---@param fn TestKit.TestFunction
---@return true?
---@return string?
local function addHook(suite, field, fn)
    local hooks = rawget(suite, field)
    if #hooks >= MAX_HOOKS then
        return nil, REASON_FULL
    end
    hooks[#hooks + 1] = fn
    return true
end

---Run `fn(ctx)` before every test of the suite. Returns `true`, or
---`nil, "full"` past 16 hooks.
---@param self TestKit.Suite
---@param fn TestKit.TestFunction
---@return true?
---@return string?
local function suiteBefore(self, fn)
    validateSuite(self, "TestKit.Suite:Before", 3)
    validateFunction(fn, "TestKit.Suite:Before fn", 3)
    return addHook(self, "_before", fn)
end

---Run `fn(ctx)` after every test of the suite, also after a failure or a
---timeout. Returns `true`, or `nil, "full"` past 16 hooks.
---@param self TestKit.Suite
---@param fn TestKit.TestFunction
---@return true?
---@return string?
local function suiteAfter(self, fn)
    validateSuite(self, "TestKit.Suite:After", 3)
    validateFunction(fn, "TestKit.Suite:After fn", 3)
    return addHook(self, "_after", fn)
end

---Return the suite's name.
---@param self TestKit.Suite
---@return string
local function suiteGetName(self)
    validateSuite(self, "TestKit.Suite:GetName", 3)
    return rawget(self, "_name")
end

-- Results --------------------------------------------------------------------

---Build one result record.
---@param name string
---@param status string
---@param message string?
---@return table
local function newResult(name, status, message)
    return { name = name, status = status, message = message, durationMs = 0, logs = {} }
end

---Store a result in its suite, replacing an earlier result of the same test
---in place so the report keeps registration order across re-runs.
---@param suite table
---@param result table
local function storeResult(suite, result)
    local results = rawget(suite, "_results")
    local index = rawget(suite, "_resultIndex")
    local position = index[result.name]
    if position == nil then
        position = #results + 1
        index[result.name] = position
    end
    results[position] = result
end

---Copy one result for the report.
---@param result table
---@return TestKit.TestResult
local function copyResult(result)
    local logs = {}
    for index = 1, #result.logs do
        logs[index] = result.logs[index]
    end
    return {
        name = result.name,
        status = result.status,
        message = result.message,
        durationMs = result.durationMs,
        logs = logs,
    }
end

---Build the report: every suite with at least one result, in registration
---order, and the totals. Everything in it is a fresh table.
---@return TestKit.Report
local function buildReport()
    local totals = { suites = 0, tests = 0, passed = 0, failed = 0, skipped = 0, timeout = 0 }
    local suiteReports = {}
    for suiteIndex = 1, #suites do
        local suite = suites[suiteIndex]
        local results = rawget(suite, "_results")
        if #results > 0 then
            local tests = {}
            for resultIndex = 1, #results do
                local result = results[resultIndex]
                tests[resultIndex] = copyResult(result)
                totals.tests = totals.tests + 1
                totals[result.status] = totals[result.status] + 1
            end
            totals.suites = totals.suites + 1
            suiteReports[totals.suites] = {
                name = rawget(suite, "_name"),
                phase = rawget(suite, "_phase"),
                addonName = rawget(suite, "_addonName"),
                tests = tests,
            }
        end
    end
    return { suites = suiteReports, totals = totals }
end

-- Runner ---------------------------------------------------------------------
--
-- See `docs/INTERNALS.md` for the state machine. In short: `Run` creates one
-- entry per selected suite and subscribes it to its LifecycleKit phase; the
-- phase moves it into `queue`; one SchedulerKit job at a time takes entries
-- off the queue and runs their tests, one step (hook or body) per coroutine.
-- A step that waits ends the job; its event, timer or the next frame schedules
-- a new one.

---Schedule the runner job unless one is already pending.
---@param nextFrame boolean whether the job must not run in the current frame
local function scheduleRunner(nextFrame)
    local job = rawget(state, "runnerJob")
    if job ~= false and job:IsPending() then
        return
    end
    local scope = getSchedulerScope()
    local callback = rawget(state, "runnerCallback")
    if nextFrame then
        job = scope:NextFrame(callback, RUNNER_JOB_OPTIONS)
    else
        job = scope:Schedule(callback, RUNNER_JOB_OPTIONS)
    end
    rawset(state, "runnerJob", job)
end

---Resume the runner for a suspended test whose wait is over. Wake-ups for a
---test that is no longer active, or not suspended, are ignored.
---@param record table
local function wake(record)
    if rawget(state, "activeTest") ~= record or not record.waiting then
        return
    end
    record.waiting = false
    scheduleRunner(false)
end

---A `WaitFor` event fired.
---@param waiter table
local function eventArrived(waiter, ...)
    if waiter.fired or waiter.timedOut then
        return
    end
    waiter.fired = true
    waiter.count = select("#", ...)
    waiter.payload = { ... }
    wake(waiter.record)
end

---A `WaitFor` or `WaitUntil` timeout passed.
---@param waiter table
local function waitTimedOut(waiter)
    if waiter.fired then
        return
    end
    waiter.timedOut = true
    wake(waiter.record)
end

---A test's time limit passed.
---@param record any the test record carried as timer user data
local function deadlineReached(record)
    if type(record) ~= "table" or rawget(state, "activeTest") ~= record then
        return
    end
    record.timedOut = true
    wake(record)
end

---Start, or restart, the test's time limit.
---@param record table
local function armDeadline(record)
    local timer = record.deadline
    if timer == false or timer:GetScope():IsClosed() then
        timer = getTimerScope("TestKit:Run", 3):New({
            delay = record.entry.suite._timeoutSeconds,
            callback = rawget(state, "deadlineCallback"),
        })
        timer:SetUserData(record)
        record.deadline = timer
    elseif timer:IsPending() then
        timer:Cancel()
    end
    record.timedOut = false
    timer:Start()
end

---Record a failure. The first one wins: a failing After hook does not hide
---why the test itself failed.
---@param record table
---@param status string
---@param message string
local function recordFailure(record, status, message)
    local result = record.result
    if result.status == STATUS_PASSED then
        result.status = status
        result.message = message
    end
end

---Move past the step that just ended. A failed step before the After hooks
---skips straight to them; entering them restarts the time limit.
---@param record table
---@param failed boolean
local function finishStep(record, failed)
    record.coroutine = false
    local previous = record.stepIndex
    if failed and previous < record.afterStart then
        record.stepIndex = record.afterStart
    else
        record.stepIndex = previous + 1
    end
    if previous < record.afterStart and record.stepIndex >= record.afterStart then
        armDeadline(record)
    end
end

---Give up on the step that ran out of time. Its coroutine is dropped; the
---waits it left behind are released when the test finishes.
---@param record table
local function abandonStep(record)
    local limit = tostring(record.entry.suite._timeoutSeconds)
    if record.stepIndex < record.afterStart then
        recordFailure(
            record,
            STATUS_TIMEOUT,
            "the test did not finish within " .. limit .. " seconds"
        )
    else
        recordFailure(
            record,
            STATUS_FAILED,
            "an After hook did not finish within " .. limit .. " seconds"
        )
    end
    finishStep(record, true)
end

---Resume the current step once, starting it first when needed, and say what
---the runner should do next.
---@param record table
---@return string outcome
local function stepTest(record)
    if record.timedOut and record.coroutine ~= false then
        abandonStep(record)
        return OUTCOME_CONTINUE
    end
    if record.stepIndex > record.stepCount then
        return OUTCOME_DONE
    end

    local routine = record.coroutine
    if routine == false then
        if record.timedOut then
            -- The After hooks' own window ran out between two hooks.
            abandonStep(record)
            return OUTCOME_CONTINUE
        end
        routine = coroutine.create(record.steps[record.stepIndex])
        record.coroutine = routine
    end

    rawset(state, "executing", true)
    local ok, token = coroutine.resume(routine, record.context)
    rawset(state, "executing", false)

    if not ok then
        recordFailure(record, STATUS_FAILED, describeMessage(token))
        finishStep(record, true)
        return OUTCOME_CONTINUE
    end
    if coroutine.status(routine) == "dead" then
        finishStep(record, false)
        return OUTCOME_CONTINUE
    end
    if token == YIELD_TOKENS.frame then
        return OUTCOME_YIELD
    elseif token == YIELD_TOKENS.wait then
        record.waiting = true
        return OUTCOME_WAIT
    elseif token == YIELD_TOKENS.nextFrame then
        record.waiting = true
        return OUTCOME_NEXT_FRAME
    end
    recordFailure(record, STATUS_FAILED, "the test called coroutine.yield; use ctx:Yield()")
    finishStep(record, true)
    return OUTCOME_CONTINUE
end

---Undo every replacement of the test, newest first.
---@param record table
local function restoreReplacements(record)
    local replacements = record.replacements
    for index = record.replacementCount, 1, -1 do
        local base = (index - 1) * 3
        rawset(replacements[base + 1], replacements[base + 2], replacements[base + 3])
        replacements[base + 1] = nil
        replacements[base + 2] = nil
        replacements[base + 3] = nil
    end
    record.replacementCount = 0
end

---Release every event connection and timer a test left behind, the time
---limit included.
local function releaseWaits()
    local eventScope = rawget(state, "eventScope")
    if eventScope ~= false and not eventScope:IsClosed() then
        eventScope:DisconnectAll()
    end
    local timerScope = rawget(state, "timerScope")
    if timerScope ~= false and not timerScope:IsClosed() then
        timerScope:CancelAll()
    end
end

---End the active test: restore, release, deactivate its context, measure it
---and store its result.
---@param record table
local function finishTest(record)
    restoreReplacements(record)
    local deadline = record.deadline
    if deadline ~= false then
        deadline:SetUserData(nil)
    end
    releaseWaits()
    rawset(record.context, "_record", false)

    local startedAt = record.startedAt
    local finishedAt = nowMilliseconds()
    if startedAt ~= false and finishedAt ~= false then
        record.result.durationMs = finishedAt - startedAt
    end
    storeResult(record.entry.suite, record.result)
    rawset(state, "activeTest", false)
end

---Build the steps of one test: its suite's Before hooks, the body, then its
---suite's After hooks.
---@param suite table
---@param test table
---@return function[] steps
---@return integer afterStart index of the first After hook, or one past the end
local function collectSteps(suite, test)
    local steps = {}
    local before = rawget(suite, "_before")
    for index = 1, #before do
        steps[#steps + 1] = before[index]
    end
    steps[#steps + 1] = test.fn
    local afterStart = #steps + 1
    local after = rawget(suite, "_after")
    for index = 1, #after do
        steps[#steps + 1] = after[index]
    end
    return steps, afterStart
end

---Make `test` the active test and start its time limit.
---@param entry table
---@param test table
local function beginTest(entry, test)
    local steps, afterStart = collectSteps(entry.suite, test)
    local record = {
        entry = entry,
        result = newResult(test.name, STATUS_PASSED, nil),
        context = false,
        steps = steps,
        stepCount = #steps,
        afterStart = afterStart,
        stepIndex = 1,
        coroutine = false,
        waiting = false,
        timedOut = false,
        deadline = false,
        startedAt = nowMilliseconds(),
        replacements = {},
        replacementCount = 0,
    }
    record.context = setmetatable({ _record = record }, CONTEXT_METATABLE)
    rawset(state, "activeTest", record)
    armDeadline(record)
end

---Record every selected test of `entry` as skipped with `message`, and end
---the entry.
---@param entry table
---@param message string
local function skipEntry(entry, message)
    local tests = rawget(entry.suite, "_tests")
    for index = 1, #tests do
        local test = tests[index]
        if entry.testName == false or entry.testName == test.name then
            storeResult(entry.suite, newResult(test.name, STATUS_SKIPPED, message))
        end
    end
    entry.status = ENTRY_DONE
    rawset(entry.suite, "_entry", false)
end

---Start the next test, or the next queued suite. Returns `false` when there
---is nothing left that can run now.
---@return boolean progressed
local function advance()
    local entry = rawget(state, "activeEntry")
    if entry == false then
        entry = table.remove(queue, 1)
        if entry == nil then
            return false
        end
        entry.status = ENTRY_RUNNING
        rawset(state, "activeEntry", entry)
    end

    local tests = rawget(entry.suite, "_tests")
    while entry.nextIndex <= #tests do
        local test = tests[entry.nextIndex]
        entry.nextIndex = entry.nextIndex + 1
        if entry.testName == false or entry.testName == test.name then
            if test.skipReason ~= false then
                storeResult(entry.suite, newResult(test.name, STATUS_SKIPPED, test.skipReason))
            else
                beginTest(entry, test)
                return true
            end
        end
    end

    entry.status = ENTRY_DONE
    rawset(entry.suite, "_entry", false)
    rawset(state, "activeEntry", false)
    return true
end

---Tell every `OnFinished` callback, each protected.
local function notifyFinished()
    local report = buildReport()
    for index = 1, #finishedCallbacks do
        local ok, message = pcall(finishedCallbacks[index], report)
        if not ok then
            reportError(message)
        end
    end
end

---End the run when nothing is executing, queued or waiting for a phase.
local function finishRunIfSettled()
    if
        not rawget(state, "runActive")
        or rawget(state, "activeTest") ~= false
        or rawget(state, "activeEntry") ~= false
        or #queue > 0
        or #waiting > 0
    then
        return
    end
    rawset(state, "runActive", false)
    notifyFinished()
end

---The runner job: run test steps until the queue is empty, a step waits, or
---the frame budget says to yield.
---@param schedulerContext SchedulerKit.Context
local function runnerBody(schedulerContext)
    local record = rawget(state, "activeTest")
    if record ~= false then
        record.waiting = false
    end

    while true do
        record = rawget(state, "activeTest")
        if record ~= false then
            local outcome = stepTest(record)
            if outcome == OUTCOME_YIELD then
                schedulerContext:Yield()
            elseif outcome == OUTCOME_WAIT then
                rawset(state, "runnerJob", false)
                return
            elseif outcome == OUTCOME_NEXT_FRAME then
                rawset(state, "runnerJob", false)
                scheduleRunner(true)
                return
            elseif outcome == OUTCOME_DONE then
                finishTest(record)
                if schedulerContext:ShouldYield() then
                    schedulerContext:Yield()
                end
            end
        elseif not advance() then
            rawset(state, "runnerJob", false)
            finishRunIfSettled()
            return
        end
    end
end

---Remove `entry` from the waiting list, keeping the order of the rest.
---@param entry table
local function removeWaiting(entry)
    for index = 1, #waiting do
        if waiting[index] == entry then
            table.remove(waiting, index)
            return
        end
    end
end

---Disconnect the halt and shutdown watches of an entry, if it has any. An
---entry queued by an older revision has none.
---@param entry table
local function releaseLostWatches(entry)
    local watches = entry.lostWatches
    if type(watches) ~= "table" then
        return
    end
    entry.lostWatches = false
    for index = 1, #watches do
        watches[index]:Disconnect()
    end
end

---An entry's LifecycleKit phase was reached: queue it and start the runner.
---@param entry table
local function phaseReached(entry)
    if entry.status ~= ENTRY_WAITING then
        return
    end
    removeWaiting(entry)
    releaseLostWatches(entry)
    entry.status = ENTRY_QUEUED
    queue[#queue + 1] = entry
    scheduleRunner(false)
end

---Build the message a skipped entry records when its phase became
---unreachable.
---@param suite table
---@param cause string `"halted"` or `"shutdown"`
---@return string
local function unreachableMessage(suite, cause)
    return "the "
        .. rawget(suite, "_phase")
        .. " phase of "
        .. quoteString(rawget(suite, "_addonName"))
        .. " can no longer be reached ("
        .. cause
        .. ")"
end

---A waiting entry's addon halted or shut down: LifecycleKit disconnects the
---phase subscription without calling it, so the entry is skipped here and the
---runner woken to finish the run.
---@param entry table
---@param cause string `"halted"` or `"shutdown"`
local function phaseLost(entry, cause)
    if entry.status ~= ENTRY_WAITING then
        return
    end
    removeWaiting(entry)
    releaseLostWatches(entry)
    skipEntry(entry, unreachableMessage(entry.suite, cause))
    scheduleRunner(false)
end

---Build the halt or shutdown watch callback of one entry.
---@param entry table
---@param cause string
---@return fun()
local function newLostCallback(entry, cause)
    return function()
        local lost = rawget(dispatch, "phaseLost")
        lost(entry, cause)
    end
end

---Build the phase subscription callback of one entry.
---@param entry table
---@return fun()
local function newPhaseCallback(entry)
    return function()
        local reached = rawget(dispatch, "phaseReached")
        reached(entry)
    end
end

---Queue one run of `suite` behind its phase. A phase already reached queues
---it at once (LifecycleKit replays). A phase that can no longer be reached —
---the addon halted or shut down, now or later while the entry waits — records
---its tests as skipped: LifecycleKit disconnects a pending phase subscription
---without calling it, so the entry also watches `OnHalted` and `OnShutdown`.
---@param suite table
---@param testName string|false
local function startEntry(suite, testName)
    local entry = {
        suite = suite,
        testName = testName,
        status = ENTRY_WAITING,
        nextIndex = 1,
        subscription = false,
        lostWatches = false,
    }
    rawset(suite, "_entry", entry)
    rawset(state, "runActive", true)
    waiting[#waiting + 1] = entry

    local instance = LifecycleKit:ForAddon(rawget(suite, "_addonName"))
    local subscription
    if rawget(suite, "_phase") == PHASE_LOADED then
        subscription = instance:OnLoaded(newPhaseCallback(entry))
    else
        subscription = instance:OnReady(newPhaseCallback(entry))
    end
    entry.subscription = subscription

    if entry.status ~= ENTRY_WAITING then
        return
    end
    if not subscription:IsConnected() then
        local cause = instance:GetState() == "halted" and "halted" or "shutdown"
        removeWaiting(entry)
        skipEntry(entry, unreachableMessage(suite, cause))
        return
    end
    entry.lostWatches = {
        instance:OnHalted(newLostCallback(entry, "halted")),
        instance:OnShutdown(newLostCallback(entry, "shutdown")),
    }
end

---Abandon the run in progress: disconnect waiting entries, empty the queue,
---restore the active test's replacements and cancel the runner job. No
---`OnFinished` callback is called.
local function abortRun()
    for index = #waiting, 1, -1 do
        local entry = waiting[index]
        waiting[index] = nil
        entry.status = ENTRY_DONE
        rawset(entry.suite, "_entry", false)
        if entry.subscription ~= false then
            entry.subscription:Disconnect()
        end
        releaseLostWatches(entry)
    end
    for index = #queue, 1, -1 do
        local entry = queue[index]
        queue[index] = nil
        entry.status = ENTRY_DONE
        rawset(entry.suite, "_entry", false)
    end

    local record = rawget(state, "activeTest")
    if record ~= false then
        restoreReplacements(record)
        rawset(record.context, "_record", false)
        rawset(state, "activeTest", false)
    end
    releaseWaits()

    local entry = rawget(state, "activeEntry")
    if entry ~= false then
        entry.status = ENTRY_DONE
        rawset(entry.suite, "_entry", false)
        rawset(state, "activeEntry", false)
    end

    local job = rawget(state, "runnerJob")
    if job ~= false and job:IsPending() then
        job:Cancel()
    end
    rawset(state, "runnerJob", false)
    rawset(state, "runActive", false)
end

-- Package public API ---------------------------------------------------------

---Register a suite. Returns the suite, `nil, "taken"` when a suite of that
---name exists, or `nil, "full"` past 64 suites.
---@param name string non-empty, without `/`
---@param options TestKit.SuiteOptions?
---@return TestKit.Suite?
---@return string?
local function packageSuite(_, name, options)
    validateName(name, "TestKit:Suite name", 3)
    if string.find(name, FILTER_SEPARATOR, 1, true) ~= nil then
        error('TestKit:Suite name must not contain "/"', 2)
    end
    local phase, addonName, timeoutSeconds = readSuiteOptions(name, options, 3)

    if suitesByName[name] ~= nil then
        return nil, REASON_TAKEN
    end
    if #suites >= MAX_SUITES then
        return nil, REASON_FULL
    end

    local suite = setmetatable({
        _schema = SUITE_SCHEMA,
        _name = name,
        _phase = phase,
        _addonName = addonName,
        _timeoutSeconds = timeoutSeconds,
        _tests = {},
        _testIndex = {},
        _before = {},
        _after = {},
        _results = {},
        _resultIndex = {},
        _entry = false,
    }, SUITE_METATABLE)
    suites[#suites + 1] = suite
    suitesByName[name] = suite
    return suite
end

---Queue the suites `filter` selects: every suite (`nil`), one suite
---(`"suite"`) or one test (`"suite/test"`). Returns how many suites were
---queued (a suite already queued or running is left as it is), or
---`nil, "unknown"` when the filter names no suite or test.
---@param filter string?
---@return integer? queued
---@return string? reason
local function packageRun(_, filter)
    local suiteName, testName = readFilter(filter, 3)
    getTimerScope("TestKit:Run", 3)

    local selection
    if suiteName == false then
        selection = suites
    else
        local suite = suitesByName[suiteName]
        if suite == nil then
            return nil, REASON_UNKNOWN
        end
        if testName ~= false and rawget(suite, "_testIndex")[testName] == nil then
            return nil, REASON_UNKNOWN
        end
        selection = { suite }
    end

    local queued = 0
    for index = 1, #selection do
        local suite = selection[index]
        if rawget(suite, "_entry") == false then
            queued = queued + 1
            startEntry(suite, testName)
        end
    end
    if queued > 0 then
        scheduleRunner(false)
    end
    return queued
end

---Return the structured results of every test that has run since the last
---`Reset`. Allocates a fresh report on every call.
---@return TestKit.Report
local function packageReport(_)
    return buildReport()
end

---Call `callback(report)` whenever a run has nothing left to do. Returns
---`true`, or `nil, "full"` past 16 callbacks.
---@param callback TestKit.FinishedCallback
---@return true?
---@return string?
local function packageOnFinished(_, callback)
    validateFunction(callback, "TestKit:OnFinished callback", 3)
    if #finishedCallbacks >= MAX_FINISHED_CALLBACKS then
        return nil, REASON_FULL
    end
    finishedCallbacks[#finishedCallbacks + 1] = callback
    return true
end

---Clear every result. A run in progress is abandoned first: its active test's
---replacements are restored and no `OnFinished` callback is called. Suites
---and `OnFinished` callbacks stay registered.
---@return true
local function packageReset(_)
    if rawget(state, "executing") then
        error("TestKit:Reset cannot be called from inside a running test", 2)
    end
    abortRun()
    for index = 1, #suites do
        local suite = suites[index]
        rawset(suite, "_results", {})
        rawset(suite, "_resultIndex", {})
    end
    return true
end

-- Commit ---------------------------------------------------------------------

rawset(Suite, "Test", suiteTest)
rawset(Suite, "Before", suiteBefore)
rawset(Suite, "After", suiteAfter)
rawset(Suite, "Skip", suiteSkip)
rawset(Suite, "GetName", suiteGetName)

rawset(Context, "Replace", contextReplace)
rawset(Context, "Yield", contextYield)
rawset(Context, "WaitFor", contextWaitFor)
rawset(Context, "WaitUntil", contextWaitUntil)
rawset(Context, "Expect", contextExpect)
rawset(Context, "Fail", contextFail)
rawset(Context, "Log", contextLog)

rawset(Matcher, "ToBe", matcherToBe)
rawset(Matcher, "ToEqual", matcherToEqual)
rawset(Matcher, "ToBeTruthy", matcherToBeTruthy)
rawset(Matcher, "ToBeNil", matcherToBeNil)
rawset(Matcher, "ToRaise", matcherToRaise)
rawset(Matcher, "ToBeSecure", matcherToBeSecure)

rawset(TestKit, "API", API_GENERATION)
rawset(TestKit, "REVISION", IMPLEMENTATION_REVISION)
rawset(TestKit, "Suite", packageSuite)
rawset(TestKit, "Run", packageRun)
rawset(TestKit, "Report", packageReport)
rawset(TestKit, "OnFinished", packageOnFinished)
rawset(TestKit, "Reset", packageReset)

rawset(dispatch, "runnerBody", runnerBody)
rawset(dispatch, "phaseReached", phaseReached)
rawset(dispatch, "phaseLost", phaseLost)
rawset(dispatch, "deadlineReached", deadlineReached)
rawset(dispatch, "eventArrived", eventArrived)
rawset(dispatch, "waitTimedOut", waitTimedOut)
rawset(state, "runtimeRevision", IMPLEMENTATION_REVISION)

if not validatePublicSurface(TestKit) or not validateCurrentState(TestKit) then
    error("MoltenCodes TestKit package state is corrupted or incomplete", 2)
end

return TestKit
