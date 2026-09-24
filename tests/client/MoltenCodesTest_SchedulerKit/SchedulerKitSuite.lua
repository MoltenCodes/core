-- MoltenCodes Test: SchedulerKitSuite.lua
--
-- Real-client suites for the `schedulerKit` package. The Busted specs under
-- packages/schedulerKit/tests/ prove SchedulerKit against a fake client whose
-- frames, clocks and timers advance only when a spec says so; these prove,
-- inside the game client with the installed MoltenCodes addon, what that
-- fixture can only simulate:
--
--   * the installed facade, its committed revision and its package defaults;
--   * the three clocks SchedulerKit relies on: `GetTime` fixed for a frame,
--     `debugprofilestop` (the budget clock) and `GetTimePreciseSec`, with the
--     readings logged;
--   * that a cooperative job is spread across rendered frames under the frame
--     budget, with the milliseconds spent in each frame logged;
--   * that HIGH is served before NORMAL before LOW, and IDLE only when nothing
--     else is ready, in real driver passes;
--   * that `NextFrame`, `After` and `Every` wait on the real `C_Timer`, with the
--     lateness and the fixed-delay intervals logged;
--   * that a slice over the default 8 ms runaway threshold demotes its job one
--     lane and is reported once through the client's error handler, and that a
--     `Yield` inside `pcall` cannot cross the client's C-call boundary;
--   * that a job error is captured with a traceback naming this file, from
--     `debug.traceback` or, on a client without `debug`, `debugstack`;
--   * that `CancelAll`, `Close` and `CloseAddonScopes` stop real work, and
--     `ForAddon` with this addon's name;
--   * `Debounce`, `Coalesce` and `Watch` against real frames and timers;
--   * the allocation guards docs/API.md promises (20000 resumes, debounce
--     calls in an open window, coalesce calls of a known key);
--   * argument errors and secret refusals as the client reports them.
--
-- Run with `/mct run schedulerKit`;
-- tests/client/MoltenCodesTest_SchedulerKit/EXPECTED.md lists what the chat
-- frame should show.
--
-- What a run leaves behind. Every scope a test creates is closed by the After
-- hook of its suite, whatever the test's outcome, which cancels its jobs and
-- closes its Debounce, Coalesce and Watch handles. Every package-wide setting
-- a test changes (the runaway threshold, the frame budget, the resume ceiling)
-- is read first and put back as soon as the test stops needing it, and again
-- by the After hook. The client's error handler is replaced only while a test
-- waits for a report it provokes, and put back at once. Two kinds of
-- SchedulerKit state stay in the session, because SchedulerKit keeps an addon
-- scope for good once `ForAddon` created it: this addon's own scope
-- (`SchedulerKit:ForAddon(addonName)`), empty, closed at logout; and one
-- closed scope per run for a probe addon name
-- (`MoltenCodesTest_SchedulerKitProbe1`, `...Probe2`, ...), each with the
-- LifecycleKit instance SchedulerKit asked for when it routed the probe's
-- logout. SchedulerKit's package-level convenience scope may also exist after
-- a run (docs/API.md, "Package-level convenience scope"), with no job in it.
-- Nothing is written to a global or a saved variable.

local addonName = ...

-- The harness is this addon's dependency and publishes one documented global.
-- selene: allow(global_usage)
local Harness = rawget(_G, "MoltenCodesTest")
-- The shared MoltenCodes namespace is the one documented global handoff point.
-- selene: allow(global_usage)
local namespace = rawget(_G, "MoltenCodes")
if type(Harness) ~= "table" or type(namespace) ~= "table" then
  error(addonName .. " requires the MoltenCodesTest harness and the MoltenCodes addon", 0)
end

local REGISTRY_API = 2
local SCHEDULER_KIT_API = 1
local LIFECYCLE_KIT_API = 1
local PACKAGE_ID = "schedulerKit"

--- The file name every argument error must name, as the client shortens it.
local SUITE_FILE = "SchedulerKitSuite.lua"

--- The package defaults docs/API.md documents.
local DEFAULT_FRAME_BUDGET_MS = 2
local DEFAULT_RUNAWAY_THRESHOLD_MS = 8
local DEFAULT_MAX_RESUMES_PER_FRAME = 1000

--- The runaway threshold the harness sets for the length of `/mct run`
--- (tests/client/README.md, "Why a run raises SchedulerKit's runaway threshold").
local HARNESS_RUNAWAY_THRESHOLD_MS = 500

--- One unit of work of the budget test, in `debugprofilestop` milliseconds,
--- and how many units the job does: 20 ms of work against a 2 ms budget.
local WORK_UNIT_MS = 0.5
local WORK_UNITS = 40

--- What a frame may spend on the budget test's job beyond the budget and the
--- one unit that can start just before the budget runs out: the time between
--- the budget check and the clock reading around each unit.
local BUDGET_MARGIN_MS = 0.5

--- How long the clock test works, in `debugprofilestop` milliseconds.
local CLOCK_WORK_MS = 5

--- How far `GetTimePreciseSec` may trail `debugprofilestop` over the same
--- work: one thread cannot spend more processor time than wall time passes,
--- so this only absorbs the two readings not being taken at the same instant.
local CLOCK_AGREEMENT_MS = 0.5

--- A busy loop stops at this multiple of its target on the wall clock, plus
--- the slack below, so a clock that does not advance can never hang the client.
local BUSY_WALL_LIMIT_FACTOR = 4
local BUSY_WALL_SLACK_SECONDS = 0.05

--- How many jobs of each contending priority the ordering test schedules.
local JOBS_PER_PRIORITY = 8

--- The LOW backlog of the preemption test: jobs of 1 ms each, 12 ms of work
--- against a 2 ms budget.
local LOW_BACKLOG_JOBS = 12
local LOW_BACKLOG_UNIT_MS = 1

--- The delay the one-shot timing test measures.
local ONE_SHOT_DELAY_SECONDS = 0.25

--- The interval of every repeating job, debounce, coalesce and watch a test starts.
local TICK_INTERVAL_SECONDS = 0.1

--- How many iterations the repeating test observes before it cancels.
local ITERATIONS_TO_OBSERVE = 4

--- How long a test waits for something that must not happen: several
--- intervals past every deadline the test set.
local QUIET_WAIT_SECONDS = 0.35

--- The longest any one wait for a job or callback may take before the test
--- gives up.
local WAIT_TIMEOUT_SECONDS = 3

--- The timing tolerance on top of two frames. A SchedulerKit timer is a
--- `C_Timer` timer, which delivers on a frame; the job it wakes is queued and
--- runs in that driver pass or the next frame's. The frame is the longest one
--- observed during the wait, never shorter than the client's frame rate says.
local TIMING_MARGIN_SECONDS = 0.02

--- How early a timer may fire and still count as due: TimerKit and the
--- coalescing family treat a wake within one millisecond of the due time as
--- due (docs/API.md, "One clock").
local EARLY_WAKE_SECONDS = 0.001

--- The runaway test's overrunning slice, in `debugprofilestop` milliseconds:
--- well over the 8 ms default threshold.
local RUNAWAY_SLICE_MS = 15

--- The resume allocation guard: 20 chunks of 1000 resumes each, measured
--- only where a chunk stayed inside one driver pass with no other job resumed
--- in between, and at most 60 chunks tried.
local RESUME_CHUNKS = 20
local RESUMES_PER_CHUNK = 1000
local MAX_RESUME_CHUNK_ATTEMPTS = 60

--- The settings the resume guard runs under, so a whole chunk fits in one
--- pass: a budget of 20 ms and a ceiling of 5000 resumes per frame.
local RESUME_GUARD_BUDGET_MS = 20
local RESUME_GUARD_MAX_RESUMES = 5000

--- How many calls the debounce and coalesce allocation guards make.
local FAMILY_CALLS = 10000

--- Kilobytes an allocation guard tolerates. The tolerance absorbs a stray
--- allocation by the client between the two readings, not a per-call one.
local ALLOCATION_TOLERANCE_KB = 1

--- A delay no test waits for: debounce windows opened with it stay open for
--- the whole test.
local LONG_DELAY_SECONDS = 60

--- Text a deliberately failing job raises, so a test can recognise it.
local CALLBACK_FAILURE = "mctSchedulerKit deliberate job failure"

--- Names of the jobs whose reports the error-handler tests count.
local RUNAWAY_JOB_NAME = "mctSchedulerKit runaway probe"
local SWALLOWED_YIELD_JOB_NAME = "mctSchedulerKit swallowed yield probe"

--- The prefix of the probe addon names the CloseAddonScopes test closes. A
--- closed addon scope stays closed for the session, so every run uses a
--- fresh name.
local PROBE_ADDON_PREFIX = "MoltenCodesTest_SchedulerKitProbe"

--- Every method docs/API.md of schedulerKit lists on the facade.
local FACADE_METHODS = {
  "Schedule",
  "NextFrame",
  "After",
  "Every",
  "CreateScope",
  "ForAddon",
  "CloseAddonScopes",
  "SetFrameBudget",
  "GetFrameBudget",
  "SetRunawayThreshold",
  "GetRunawayThreshold",
  "SetMaxResumesPerFrame",
  "GetMaxResumesPerFrame",
  "GetActiveCount",
  "Debounce",
  "Coalesce",
  "Watch",
  "Lane",
  "SetLimits",
  "GetLimits",
}

--- Every method docs/API.md of schedulerKit lists on a job handle.
local JOB_METHODS = {
  "GetState",
  "GetPriority",
  "GetScope",
  "GetName",
  "IsPending",
  "IsCancelled",
  "HasError",
  "GetError",
  "GetErrorTraceback",
  "Cancel",
}

--- Every method docs/API.md of schedulerKit lists on a scope.
local SCOPE_METHODS = {
  "Schedule",
  "NextFrame",
  "After",
  "Every",
  "CancelAll",
  "Close",
  "IsClosed",
  "GetAddonName",
  "GetActiveCount",
  "Debounce",
  "Coalesce",
  "Watch",
}

--- Every method docs/API.md of schedulerKit lists on an execution context.
local CONTEXT_METHODS = { "ShouldYield", "Yield", "GetJob", "IsCancelled" }

---Read a client global, or `nil`.
---@param name string
---@return any
local function readHost(name)
  -- The clocks, the frame rate, error handling and secret-value functions
  -- are World of Warcraft client globals, reachable only through the global
  -- table.
  -- selene: allow(global_usage)
  return rawget(_G, name)
end

---@type Registry
local Registry = rawget(rawget(namespace, "Registries") or {}, REGISTRY_API)
if type(Registry) ~= "table" then
  error(addonName .. " requires the MoltenCodes addon (Registry API 2); reinstall it", 0)
end

---@type SchedulerKit|nil
local SchedulerKitOrNil = Registry:Get(PACKAGE_ID, SCHEDULER_KIT_API)
if type(SchedulerKitOrNil) == "nil" then
  error(addonName .. " requires SchedulerKit API 1 in the MoltenCodes addon; reinstall it", 0)
end
---@cast SchedulerKitOrNil SchedulerKit
local SchedulerKit = SchedulerKitOrNil

local Priority = SchedulerKit.Priority

--- The three clocks, read once at load: the tests that measure time or frames
--- are registered as skipped on a client without any of them.
local getTimePreciseSec = readHost("GetTimePreciseSec")
local getTime = readHost("GetTime")
local debugProfileStop = readHost("debugprofilestop")
local CLOCKS_AVAILABLE = type(getTimePreciseSec) == "function"
  and type(getTime) == "function"
  and type(debugProfileStop) == "function"

--- The two client functions the secrets suite needs, read once at load: the
--- suite registers its tests as skipped when either is missing.
local isSecretValue = readHost("issecretvalue")
local secretWrap = readHost("secretwrap")
local SECRETS_AVAILABLE = type(isSecretValue) == "function" and type(secretWrap) == "function"

-- Helpers ---------------------------------------------------------------------------

--- Release actions of the test that is running (close a scope, put a setting
--- or the error handler back), run newest first by the After hook of every
--- suite.
---@type (fun())[]
local pendingReleases = {}

--- Sequence of the probe addon names the CloseAddonScopes test uses.
local probeSequence = 0

---Run and empty the release list, newest first. Every action runs even when
---an earlier one raised; the first error is raised again afterwards.
local function cleanUp()
  local firstProblem = nil
  for index = #pendingReleases, 1, -1 do
    local action = pendingReleases[index]
    pendingReleases[index] = nil
    local succeeded, problem = pcall(action)
    if not succeeded and type(firstProblem) == "nil" then
      firstProblem = problem
    end
  end
  if type(firstProblem) ~= "nil" then
    error(firstProblem, 0)
  end
end

---Remember `scope` for the After hook, which closes it, and hand it back.
---Closing cancels every job of the scope and closes its Debounce, Coalesce
---and Watch handles; `Close` answers `false` for a scope already closed.
---@param scope SchedulerKit.Scope
---@return SchedulerKit.Scope scope
local function trackScope(scope)
  pendingReleases[#pendingReleases + 1] = function()
    scope:Close()
  end
  return scope
end

---Change a package-wide SchedulerKit setting for the running test, and return
---the function that puts the previous value back. The After hook calls it too;
---calling it twice is harmless.
---@param read fun(): number the setting's getter
---@param write fun(value: number) the setting's setter
---@param value number the value the test needs
---@return fun() restore
---@return number previous the value the test replaced
local function overrideSetting(read, write, value)
  local previous = read()
  local restored = false
  local function restore()
    if not restored then
      restored = true
      write(previous)
    end
  end
  pendingReleases[#pendingReleases + 1] = restore
  write(value)
  return restore, previous
end

---Set the runaway threshold for the running test; see `overrideSetting`.
---@param milliseconds number
---@return fun() restore
---@return number previous
local function overrideRunawayThreshold(milliseconds)
  return overrideSetting(function()
    return SchedulerKit:GetRunawayThreshold()
  end, function(value)
    SchedulerKit:SetRunawayThreshold(value)
  end, milliseconds)
end

---Set the frame budget for the running test; see `overrideSetting`.
---@param milliseconds number
---@return fun() restore
---@return number previous
local function overrideFrameBudget(milliseconds)
  return overrideSetting(function()
    return SchedulerKit:GetFrameBudget()
  end, function(value)
    SchedulerKit:SetFrameBudget(value)
  end, milliseconds)
end

---Set the resume ceiling for the running test; see `overrideSetting`.
---@param count integer
---@return fun() restore
---@return number previous
local function overrideMaxResumes(count)
  return overrideSetting(function()
    return SchedulerKit:GetMaxResumesPerFrame()
  end, function(value)
    SchedulerKit:SetMaxResumesPerFrame(value)
  end, count)
end

---Register a suite of this package whose tests all end released.
---@param part string
---@return TestKit.Suite
local function newSuite(part)
  local suite = Harness:Suite(PACKAGE_ID, part, addonName)
  suite:After(cleanUp)
  return suite
end

--- Why a clock test is skipped on a client without the three clocks.
local CLOCKS_SKIP_REASON =
  "the client lacks GetTime, GetTimePreciseSec or debugprofilestop; frames and time were not measured"

---Register `body` as a test when the client has the three clocks, and as a
---skipped test naming why otherwise.
---@param suite TestKit.Suite
---@param name string
---@param body fun(ctx: TestKit.Context)
local function clockTest(suite, name, body)
  if CLOCKS_AVAILABLE then
    suite:Test(name, body)
  else
    suite:Skip(name, CLOCKS_SKIP_REASON)
  end
end

---The client's monotonic wall clock, in seconds. Only called by tests that
---`clockTest` registered, so the clock exists.
---@return number
local function preciseNow()
  return getTimePreciseSec()
end

---The profiling clock SchedulerKit's budget reads, in milliseconds.
---@return number
local function cpuNow()
  return debugProfileStop()
end

---A key for the rendered frame the code runs in: `GetTime` answers the time
---the client took when the frame started, the same for the whole frame (the
---clock test checks that on this client).
---@return number
local function frameKey()
  return getTime()
end

---Spin until `debugprofilestop` advanced `targetMs`, and return how far it
---did. The wall clock bounds the loop, so a clock that stands still or is
---restarted by another addon cannot hang the client.
---@param targetMs number
---@return number spentMs
local function busyFor(targetMs)
  local cpuStart = cpuNow()
  local wallLimit = preciseNow()
    + targetMs * BUSY_WALL_LIMIT_FACTOR / 1000
    + BUSY_WALL_SLACK_SECONDS
  local spent = 0
  repeat
    spent = cpuNow() - cpuStart
  until spent >= targetMs or preciseNow() >= wallLimit
  return spent
end

---`ctx:WaitUntil(predicate, timeoutSeconds)`, returning only whether the
---predicate became truthy in time.
---
---The call goes through an untyped alias because the LuaCATS field TestKit
---declares for `WaitUntil` (`predicate: fun(): any, timeoutSeconds: number`)
---reads to lua-language-server as a predicate returning two values, so a
---direct call is reported as passing one argument too many.
---@param ctx TestKit.Context
---@param predicate fun(): any
---@param timeoutSeconds number
---@return boolean satisfied
local function waitUntil(ctx, predicate, timeoutSeconds)
  ---@type any
  local context = ctx
  local satisfied = context:WaitUntil(predicate, timeoutSeconds)
  return satisfied == true
end

---What one measured wait saw of the client's frames.
---@class SchedulerKitSuite.Wait
---@field satisfied boolean whether the predicate became truthy in time
---@field frames integer how many rendered frames the wait resumed on
---@field longestFrameSeconds number the longest gap between two resumptions

---Wait like `waitUntil`, and measure the frames the wait spanned: TestKit
---resumes the test once per rendered frame, so the gap between two calls of
---the predicate is one frame as the client rendered it.
---@param ctx TestKit.Context
---@param predicate fun(): any
---@param timeoutSeconds number
---@return SchedulerKitSuite.Wait
local function measuredWait(ctx, predicate, timeoutSeconds)
  local wait = { satisfied = false, frames = -1, longestFrameSeconds = 0 }
  local previous = preciseNow()
  wait.satisfied = waitUntil(ctx, function()
    local current = preciseNow()
    if current - previous > wait.longestFrameSeconds then
      wait.longestFrameSeconds = current - previous
    end
    previous = current
    wait.frames = wait.frames + 1
    return predicate()
  end, timeoutSeconds)
  return wait
end

---Wait until the clock passes `instant`, measuring the frames on the way.
---@param ctx TestKit.Context
---@param instant number a `GetTimePreciseSec` reading
---@return SchedulerKitSuite.Wait
local function waitUntilInstant(ctx, instant)
  return measuredWait(ctx, function()
    return preciseNow() >= instant
  end, WAIT_TIMEOUT_SECONDS)
end

---The timing tolerance of a wait: two frames, each the longest the wait
---observed and never shorter than the client's current frame rate says, plus
---`TIMING_MARGIN_SECONDS`.
---@param wait SchedulerKitSuite.Wait
---@return number seconds
local function frameAllowance(wait)
  local frame = wait.longestFrameSeconds
  local getFramerate = readHost("GetFramerate")
  if type(getFramerate) == "function" then
    local framesPerSecond = getFramerate()
    if type(framesPerSecond) == "number" and framesPerSecond > 0 then
      frame = math.max(frame, 1 / framesPerSecond)
    end
  end
  return 2 * frame + TIMING_MARGIN_SECONDS
end

---Seconds as whole-and-fraction milliseconds for a log line.
---@param seconds number
---@return string
local function milliseconds(seconds)
  return ("%.2f ms"):format(seconds * 1000)
end

---Split a `file:line: ` prefix into the file as the client names it and the line.
---@param position string
---@return string|nil file
---@return integer|nil line
local function splitPosition(position)
  local file, line = position:match("^(.-):(%d+): ")
  return file, tonumber(line)
end

---The line of the caller of this function, as the client numbers it.
---
---`error` with level 3, raised under `pcall`, names the caller of this
---function: level 1 is `pcall` itself, 2 is this function, 3 its caller.
---@return integer
local function currentLine()
  local _, position = pcall(error, "", 3)
  local _, line = splitPosition(position or "")
  return line or 0
end

---Check that `message` is a string naming this file, and return its line.
---@param ctx TestKit.Context
---@param message any
---@return integer|nil line
local function expectThisFile(ctx, message)
  ctx:Expect(type(message)):ToBe("string")
  if type(message) ~= "string" then
    return nil
  end
  local file, line = splitPosition(message)
  ctx:Expect(type(file)):ToBe("string")
  ctx:Expect((file or ""):sub(-#SUITE_FILE)):ToBe(SUITE_FILE)
  return line
end

---Call `raise`, which must record its start line and raise on the next line,
---and check the message names this file at that line and ends with `expected`.
---@param ctx TestKit.Context
---@param raise fun() Records its start line with `currentLine()`, then raises on the next line.
---@param expected string The message after the position, compared literally.
---@return integer|nil line The line the message names.
local function expectErrorAtCallingLine(ctx, raise, expected)
  local succeeded, message = pcall(raise)
  ctx:Expect(succeeded):ToBe(false)
  ctx:Log("client message: " .. tostring(message))

  local line = expectThisFile(ctx, message)
  ctx:Expect(tostring(message):sub(-#expected)):ToBe(expected)
  return line
end

---One refused call: `receiver[method](receiver, ...arguments)` must raise
---`expected`.
---@class SchedulerKitSuite.RefusalCase
---@field receiver any the facade, a scope or another object the method is read from
---@field callAs any|nil the value passed as the receiver instead, to test a wrong-receiver refusal
---@field method string
---@field arguments any[] the arguments after the receiver, without holes
---@field expected string the message after the position

---Make each case's call on the line after `currentLine()` and check the
---message names this file at the calling line.
---
---docs/API.md ("Argument errors") promises the caller's line for every
---argument and wrong-receiver error. Before SchedulerKit 0.8.4 the scheduling
---methods, `Scope:CancelAll`, `Scope:Close` and `Job:Cancel` reached their
---checks through a tail call, and this client (Retail 12.1.0 build 69933,
---2026-09-24) gave their messages no position at all.
---@param ctx TestKit.Context
---@param cases SchedulerKitSuite.RefusalCase[]
local function expectRefusals(ctx, cases)
  for _, case in ipairs(cases) do
    local startLine = 0
    local function raise()
      startLine = currentLine()
      case.receiver[case.method](case.callAs or case.receiver, unpack(case.arguments))
    end
    local line = expectErrorAtCallingLine(ctx, raise, case.expected)
    ctx:Expect(line):ToBe(startLine + 1)
  end
end

--- A job that does nothing; jobs that only exist to be counted or cancelled use it.
local function ignore() end

---Send failures and diagnostics the client's error handler receives to a
---collector until the returned `restore` is called; the After hook calls it
---too, so a test that fails or times out while waiting cannot keep the
---collector.
---
---SchedulerKit reports through `geterrorhandler()` from its driver, outside
---any protected call of the test (docs/API.md, "Error isolation"). The
---handler is therefore swapped with `seterrorhandler`; the global
---`geterrorhandler` is only its reader, and replacing it would neither catch
---the report nor keep the error window closed. The swap spans the wait for
---the job, so a failure of another addon in that window reaches the collector
---too; the tests count only their own reports.
---@return any[] reported every value the collector receives, in order
---@return boolean observed whether the collector is the client's handler
---@return fun() restore puts the previous handler back; safe to call twice
local function collectReportedErrors()
  local reported = {}
  ---@param message any
  local function collector(message)
    reported[#reported + 1] = message
  end

  local restore = function() end
  local observed = false
  local setErrorHandler = readHost("seterrorhandler")
  local getErrorHandler = readHost("geterrorhandler")
  if type(setErrorHandler) == "function" and type(getErrorHandler) == "function" then
    local previous = getErrorHandler()
    setErrorHandler(collector)
    -- An error-capturing addon (BugGrabber) may refuse the swap.
    observed = getErrorHandler() == collector
    local restored = false
    restore = function()
      if not restored then
        restored = true
        setErrorHandler(previous)
      end
    end
  end
  pendingReleases[#pendingReleases + 1] = restore
  return reported, observed, restore
end

---The reports that are plain strings containing `text`.
---@param reported any[]
---@param text string
---@return string[]
local function reportsContaining(reported, text)
  local matching = {}
  for _, message in ipairs(reported) do
    if
      type(message) == "string"
      and not (SECRETS_AVAILABLE and isSecretValue(message))
      and message:find(text, 1, true) ~= nil
    then
      matching[#matching + 1] = message
    end
  end
  return matching
end

---How many reports are exactly `expected`.
---@param reported any[]
---@param expected any
---@return integer
local function countReports(reported, expected)
  local count = 0
  for _, message in ipairs(reported) do
    if rawequal(message, expected) then
      count = count + 1
    end
  end
  return count
end

--- Why the error-handler tests fail rather than pass when the swap did not hold.
local HANDLER_KEPT_MESSAGE =
  "the client's error handler could not be replaced (an error-capturing addon such as BugGrabber keeps it); the report went to that addon"

---Measure how many kilobytes `work` grows the Lua heap by.
---@param work fun()
---@return number grownKilobytes
local function measureAllocation(work)
  local before = collectgarbage("count")
  work()
  return collectgarbage("count") - before
end

---Run a full collection in a step of its own, so the measurement that follows
---starts far from the next collector cycle, which would otherwise shrink the
---count mid-measurement and hide an allocation.
---@param ctx TestKit.Context
local function collectBeforeMeasuring(ctx)
  collectgarbage("collect")
  ctx:Yield()
end

---The position of the first and the last `letter` in `order`, or 0.
---@param order string[]
---@param letter string
---@return integer first
---@return integer last
local function firstAndLast(order, letter)
  local first, last = 0, 0
  for index, value in ipairs(order) do
    if value == letter then
      if first == 0 then
        first = index
      end
      last = index
    end
  end
  return first, last
end

---How many of the first `count` entries of `order` are `letter`.
---@param order string[]
---@param letter string
---@param count integer
---@return integer
local function countAmongFirst(order, letter, count)
  local found = 0
  for index = 1, math.min(count, #order) do
    if order[index] == letter then
      found = found + 1
    end
  end
  return found
end

---The ordinal of every distinct frame key in `keys`, in the order first seen.
---@param keys number[]
---@return table<number, integer> ordinals
---@return integer frames how many distinct frames there were
local function frameOrdinals(keys)
  local ordinals = {}
  local frames = 0
  for _, key in ipairs(keys) do
    if ordinals[key] == nil then
      frames = frames + 1
      ordinals[key] = frames
    end
  end
  return ordinals, frames
end

-- schedulerKit.facade --------------------------------------------------------------------

local facade = newSuite("facade")

facade:Test(
  "Registry:Get('schedulerKit', 1) is the SchedulerKit facade with API 1 and four priorities, and its jobs, scopes and contexts carry every documented method",
  function(ctx)
    ctx:Expect(type(SchedulerKit)):ToBe("table")
    ctx:Expect(rawget(SchedulerKit, "API")):ToBe(SCHEDULER_KIT_API)
    for _, method in ipairs(FACADE_METHODS) do
      ctx:Expect(type(SchedulerKit[method])):ToBe("function")
    end
    ctx:Expect(Priority.HIGH < Priority.NORMAL):ToBe(true)
    ctx:Expect(Priority.NORMAL < Priority.LOW):ToBe(true)
    ctx:Expect(Priority.LOW < Priority.IDLE):ToBe(true)
    ctx:Expect(type(SchedulerKit.UNBOUNDED)):ToBe("table")

    local scope = trackScope(SchedulerKit:CreateScope())
    for _, method in ipairs(SCOPE_METHODS) do
      ctx:Expect(type(scope[method])):ToBe("function")
    end

    local seen = { methods = {}, job = nil, cancelled = nil }
    local job = scope:Schedule(function(context)
      for _, method in ipairs(CONTEXT_METHODS) do
        seen.methods[method] = type(context[method])
      end
      seen.job = context:GetJob()
      seen.cancelled = context:IsCancelled()
    end, { name = "mctSchedulerKit facade probe" })
    for _, method in ipairs(JOB_METHODS) do
      ctx:Expect(type(job[method])):ToBe("function")
    end
    ctx:Expect(job:GetScope()):ToBe(scope)
    ctx:Expect(job:GetName()):ToBe("mctSchedulerKit facade probe")
    ctx:Expect(job:GetPriority()):ToBe(Priority.NORMAL)

    local ran = waitUntil(ctx, function()
      return not job:IsPending()
    end, WAIT_TIMEOUT_SECONDS)
    ctx:Expect(ran):ToBe(true)
    ctx:Expect(job:GetState()):ToBe("completed")
    for _, method in ipairs(CONTEXT_METHODS) do
      ctx:Expect(seen.methods[method]):ToBe("function")
    end
    ctx:Expect(seen.job):ToBe(job)
    ctx:Expect(seen.cancelled):ToBe(false)
  end
)

facade:Test(
  "the installed SchedulerKit carries the revision of the committed manifest",
  function(ctx)
    local expectedPackages = Harness:GetExpectedPackages()
    if type(expectedPackages) == "nil" then
      ctx:Fail("Expected.lua is missing; install with python3 -m tooling.client.install")
      return
    end
    for _, expected in ipairs(expectedPackages) do
      if expected.id == PACKAGE_ID then
        local _, revision = Registry:Get(PACKAGE_ID, SCHEDULER_KIT_API)
        ctx:Expect(revision):ToBe(expected.revision)
        ctx:Expect(rawget(SchedulerKit, "REVISION")):ToBe(expected.revision)
        return
      end
    end
    ctx:Fail("Expected.lua does not list schedulerKit")
  end
)

facade:Test(
  "the frame budget is the 2 ms default, the resume ceiling the 1000 default, and the runaway threshold the 500 ms the harness sets for a run",
  function(ctx)
    local budget = SchedulerKit:GetFrameBudget()
    local ceiling = SchedulerKit:GetMaxResumesPerFrame()
    local threshold = SchedulerKit:GetRunawayThreshold()
    ctx:Log(
      ("frame budget %s ms; resume ceiling %s; runaway threshold %s ms (default %d ms outside a run)"):format(
        tostring(budget),
        tostring(ceiling),
        tostring(threshold),
        DEFAULT_RUNAWAY_THRESHOLD_MS
      )
    )
    ctx:Expect(budget):ToBe(DEFAULT_FRAME_BUDGET_MS)
    ctx:Expect(ceiling):ToBe(DEFAULT_MAX_RESUMES_PER_FRAME)
    ctx:Expect(threshold):ToBe(HARNESS_RUNAWAY_THRESHOLD_MS)
  end
)

-- schedulerKit.clocks --------------------------------------------------------------------

local clocks = newSuite("clocks")

clockTest(
  clocks,
  "GetTime stays fixed within a frame while debugprofilestop and GetTimePreciseSec advance together over 5 ms of work, and all three move across a rendered frame (readings logged)",
  function(ctx)
    local frameBefore, cpuBefore, wallBefore = frameKey(), cpuNow(), preciseNow()
    busyFor(CLOCK_WORK_MS)
    local frameAfter, cpuAfter, wallAfter = frameKey(), cpuNow(), preciseNow()
    local cpuWork = cpuAfter - cpuBefore
    local wallWork = (wallAfter - wallBefore) * 1000
    ctx:Log(
      ("within one frame: GetTime +%.3f ms, debugprofilestop +%.3f ms, GetTimePreciseSec +%.3f ms"):format(
        (frameAfter - frameBefore) * 1000,
        cpuWork,
        wallWork
      )
    )
    ctx:Expect(frameAfter):ToBe(frameBefore)
    ctx:Expect(cpuWork >= CLOCK_WORK_MS):ToBe(true)
    ctx:Expect(wallWork >= cpuWork - CLOCK_AGREEMENT_MS):ToBe(true)

    local frameStart, cpuStart, wallStart = frameKey(), cpuNow(), preciseNow()
    local moved = waitUntil(ctx, function()
      return frameKey() ~= frameStart
    end, WAIT_TIMEOUT_SECONDS)
    local frameEnd, cpuEnd, wallEnd = frameKey(), cpuNow(), preciseNow()
    ctx:Log(
      ("across the next rendered frame: GetTime +%.3f ms, debugprofilestop +%.3f ms, GetTimePreciseSec +%.3f ms"):format(
        (frameEnd - frameStart) * 1000,
        cpuEnd - cpuStart,
        (wallEnd - wallStart) * 1000
      )
    )
    ctx:Expect(moved):ToBe(true)
    ctx:Expect(cpuEnd > cpuStart):ToBe(true)
    ctx:Expect(wallEnd > wallStart):ToBe(true)
  end
)

-- schedulerKit.budget --------------------------------------------------------------------

local budget = newSuite("budget")

clockTest(
  budget,
  "a job of forty 0.5 ms units that yields when ShouldYield says so is spread over rendered frames, spending at most the budget plus one unit in each (ms per frame logged)",
  function(ctx)
    local scope = trackScope(SchedulerKit:CreateScope())
    local budgetMs = SchedulerKit:GetFrameBudget()
    local frameKeys = {}
    local spentByFrame = {}
    local yields = 0
    local job = scope:Schedule(function(context)
      for _ = 1, WORK_UNITS do
        local key = frameKey()
        if spentByFrame[key] == nil then
          spentByFrame[key] = 0
          frameKeys[#frameKeys + 1] = key
        end
        spentByFrame[key] = spentByFrame[key] + busyFor(WORK_UNIT_MS)
        if context:ShouldYield() then
          yields = yields + 1
          context:Yield()
        end
      end
    end, { name = "mctSchedulerKit budget probe" })

    local finished = waitUntil(ctx, function()
      return not job:IsPending()
    end, WAIT_TIMEOUT_SECONDS)
    ctx:Expect(finished):ToBe(true)
    ctx:Expect(job:GetState()):ToBe("completed")

    local perFrame = {}
    local largest = 0
    local total = 0
    for index, key in ipairs(frameKeys) do
      perFrame[index] = ("%.2f"):format(spentByFrame[key])
      largest = math.max(largest, spentByFrame[key])
      total = total + spentByFrame[key]
    end
    local ceilingPerFrame = budgetMs + WORK_UNIT_MS + BUDGET_MARGIN_MS
    local fewestFrames = math.ceil(WORK_UNITS * WORK_UNIT_MS / ceilingPerFrame)
    ctx:Log(
      ("budget %s ms; %.2f ms of work in %d frames (at least %d expected) with %d yields; ms per frame: %s"):format(
        tostring(budgetMs),
        total,
        #frameKeys,
        fewestFrames,
        yields,
        table.concat(perFrame, ", ")
      )
    )
    ctx:Expect(#frameKeys >= fewestFrames):ToBe(true)
    ctx:Expect(largest <= ceilingPerFrame):ToBe(true)
  end
)

-- schedulerKit.priority ------------------------------------------------------------------

local priority = newSuite("priority")

clockTest(
  priority,
  "eight HIGH, NORMAL and LOW jobs and one IDLE job scheduled lowest first are served HIGH before NORMAL before LOW, with IDLE last (order logged)",
  function(ctx)
    local scope = trackScope(SchedulerKit:CreateScope())
    local order = {}
    local frames = {}
    ---@param letter string
    ---@return SchedulerKit.Callback
    local function recorder(letter)
      return function()
        order[#order + 1] = letter
        frames[#frames + 1] = frameKey()
      end
    end

    -- Scheduled against their priority, so FIFO alone would give the
    -- opposite order.
    scope:Schedule(recorder("I"), { priority = Priority.IDLE })
    for _ = 1, JOBS_PER_PRIORITY do
      scope:Schedule(recorder("L"), { priority = Priority.LOW })
    end
    for _ = 1, JOBS_PER_PRIORITY do
      scope:Schedule(recorder("N"), { priority = Priority.NORMAL })
    end
    for _ = 1, JOBS_PER_PRIORITY do
      scope:Schedule(recorder("H"), { priority = Priority.HIGH })
    end
    local total = 3 * JOBS_PER_PRIORITY + 1

    local finished = waitUntil(ctx, function()
      return #order >= total
    end, WAIT_TIMEOUT_SECONDS)
    local _, frameCount = frameOrdinals(frames)
    ctx:Log(
      ("service order: %s, over %d rendered frame(s)"):format(table.concat(order), frameCount)
    )
    ctx:Expect(finished):ToBe(true)
    ctx:Expect(#order):ToBe(total)

    local _, lastHigh = firstAndLast(order, "H")
    local _, lastNormal = firstAndLast(order, "N")
    local _, lastLow = firstAndLast(order, "L")
    local firstIdle = firstAndLast(order, "I")
    ctx:Expect(firstIdle):ToBe(total)
    ctx:Expect(lastHigh < lastNormal):ToBe(true)
    ctx:Expect(lastNormal < lastLow):ToBe(true)
    -- Any seven consecutive slots of the weighted sequence hold four HIGH.
    ctx:Expect(countAmongFirst(order, "H", 7) >= 4):ToBe(true)
    ctx:Expect(scope:GetActiveCount()):ToBe(0)
  end
)

clockTest(
  priority,
  "a HIGH job scheduled by the first job of a LOW backlog spread over rendered frames runs next, ahead of the eleven LOW jobs still waiting (order and frames logged)",
  function(ctx)
    local scope = trackScope(SchedulerKit:CreateScope())
    local order = {}
    local frames = {}
    local highJob = nil
    for index = 1, LOW_BACKLOG_JOBS do
      scope:Schedule(function()
        busyFor(LOW_BACKLOG_UNIT_MS)
        order[#order + 1] = "L"
        frames[#frames + 1] = frameKey()
        if index == 1 then
          highJob = scope:Schedule(function()
            order[#order + 1] = "H"
            frames[#frames + 1] = frameKey()
          end, { priority = Priority.HIGH })
        end
      end, { priority = Priority.LOW })
    end

    local finished = waitUntil(ctx, function()
      return #order >= LOW_BACKLOG_JOBS + 1
    end, WAIT_TIMEOUT_SECONDS)
    local ordinals, frameCount = frameOrdinals(frames)
    local highIndex = firstAndLast(order, "H")
    local frameOfEach = {}
    for index = 1, #frames do
      frameOfEach[index] = order[index] .. ordinals[frames[index]]
    end
    ctx:Log(
      ("order with frame ordinals: %s; %d rendered frames"):format(
        table.concat(frameOfEach, " "),
        frameCount
      )
    )
    ctx:Expect(finished):ToBe(true)
    ctx:Expect(type(highJob)):ToBe("table")
    ctx:Expect(highIndex >= 2):ToBe(true)
    ctx:Expect(highIndex <= 3):ToBe(true)
    if highIndex >= 2 then
      ctx:Expect(ordinals[frames[highIndex]] <= ordinals[frames[1]] + 1):ToBe(true)
    end
    ctx:Expect(frameCount >= 4):ToBe(true)
  end
)

-- schedulerKit.timers --------------------------------------------------------------------

local timers = newSuite("timers")

clockTest(
  timers,
  "NextFrame is delayed on return, never runs in the frame it was scheduled in, and runs within the next two rendered frames (frame logged)",
  function(ctx)
    local scope = trackScope(SchedulerKit:CreateScope())
    local scheduledFrame = frameKey()
    local ranFrame = nil
    local immediateFrame = nil
    local job = scope:NextFrame(function()
      ranFrame = frameKey()
    end)
    local stateOnReturn = job:GetState()
    -- Schedule, by contrast, may run in the current pass; logged only.
    scope:Schedule(function()
      immediateFrame = frameKey()
    end)

    local wait = measuredWait(ctx, function()
      return ranFrame ~= nil
    end, WAIT_TIMEOUT_SECONDS)
    ctx:Log(
      ("NextFrame ran on rendered frame %d of the wait, %s after the frame it was scheduled in; a Schedule job from the same line ran in %s"):format(
        wait.frames,
        milliseconds((ranFrame or scheduledFrame) - scheduledFrame),
        immediateFrame == scheduledFrame and "the same frame" or "a later frame"
      )
    )
    ctx:Expect(stateOnReturn):ToBe("delayed")
    ctx:Expect(wait.satisfied):ToBe(true)
    ctx:Expect(ranFrame ~= scheduledFrame):ToBe(true)
    ctx:Expect(wait.frames <= 2):ToBe(true)
    ctx:Expect(job:GetState()):ToBe("completed")
  end
)

clockTest(
  timers,
  "After(0.25) keeps its job delayed, then runs it within two frames plus 20 ms of the deadline on the real C_Timer (lateness logged)",
  function(ctx)
    local scope = trackScope(SchedulerKit:CreateScope())
    local ranAt = nil
    local startedAt = preciseNow()
    local job = scope:After(ONE_SHOT_DELAY_SECONDS, function()
      ranAt = preciseNow()
    end)
    ctx:Expect(job:GetState()):ToBe("delayed")
    ctx:Expect(job:IsPending()):ToBe(true)
    ctx:Expect(scope:GetActiveCount()):ToBe(1)

    local stateMidway = nil
    local wait = measuredWait(ctx, function()
      if stateMidway == nil and preciseNow() - startedAt >= ONE_SHOT_DELAY_SECONDS / 2 then
        stateMidway = job:GetState()
      end
      return ranAt ~= nil
    end, WAIT_TIMEOUT_SECONDS)
    ctx:Expect(wait.satisfied):ToBe(true)

    local lateness = (ranAt or startedAt) - (startedAt + ONE_SHOT_DELAY_SECONDS)
    local allowance = frameAllowance(wait)
    ctx:Log(
      ("lateness %s after the deadline (negative: early); allowance %s; longest frame %s over %d frames; state halfway: %s"):format(
        milliseconds(lateness),
        milliseconds(allowance),
        milliseconds(wait.longestFrameSeconds),
        wait.frames,
        tostring(stateMidway)
      )
    )
    ctx:Expect(stateMidway):ToBe("delayed")
    ctx:Expect(lateness >= -EARLY_WAKE_SECONDS - TIMING_MARGIN_SECONDS):ToBe(true)
    ctx:Expect(lateness <= allowance):ToBe(true)
    ctx:Expect(job:GetState()):ToBe("completed")
    ctx:Expect(scope:GetActiveCount()):ToBe(0)
  end
)

clockTest(
  timers,
  "Every(0.1) is fixed-delay on the real C_Timer: each iteration of a job that yields once starts one interval after the previous one finished, never overlapping, and Cancel stops it (gaps logged)",
  function(ctx)
    local scope = trackScope(SchedulerKit:CreateScope())
    local starts, finishes = {}, {}
    local job = scope:Every(TICK_INTERVAL_SECONDS, function(context)
      starts[#starts + 1] = preciseNow()
      context:Yield()
      finishes[#finishes + 1] = preciseNow()
    end, { name = "mctSchedulerKit repeating probe" })

    local sawDelayed = false
    local wait = measuredWait(ctx, function()
      if job:GetState() == "delayed" and #starts > 0 then
        sawDelayed = true
      end
      return #finishes >= ITERATIONS_TO_OBSERVE
    end, WAIT_TIMEOUT_SECONDS)
    ctx:Expect(wait.satisfied):ToBe(true)
    ctx:Expect(job:Cancel()):ToBe(true)
    local startsAtCancel = #starts

    local allowance = frameAllowance(wait)
    local gaps = {}
    for index = 2, math.min(#starts, #finishes + 1) do
      gaps[#gaps + 1] = milliseconds(starts[index] - finishes[index - 1])
    end
    ctx:Log(
      ("gaps from one iteration's end to the next one's start: %s; allowance %s around %s"):format(
        table.concat(gaps, ", "),
        milliseconds(allowance),
        milliseconds(TICK_INTERVAL_SECONDS)
      )
    )
    for index = 2, math.min(#starts, #finishes + 1) do
      local gap = starts[index] - finishes[index - 1]
      ctx
        :Expect(gap >= TICK_INTERVAL_SECONDS - EARLY_WAKE_SECONDS - TIMING_MARGIN_SECONDS)
        :ToBe(true)
      ctx:Expect(gap <= TICK_INTERVAL_SECONDS + allowance):ToBe(true)
    end
    ctx:Expect(sawDelayed):ToBe(true)

    waitUntilInstant(ctx, preciseNow() + QUIET_WAIT_SECONDS)
    ctx:Log(("iterations started after Cancel: %d"):format(#starts - startsAtCancel))
    ctx:Expect(#starts):ToBe(startsAtCancel)
    ctx:Expect(job:GetState()):ToBe("cancelled")
    ctx:Expect(scope:GetActiveCount()):ToBe(0)
  end
)

-- schedulerKit.runaway -------------------------------------------------------------------

local runaway = newSuite("runaway")

clockTest(
  runaway,
  "under the 8 ms default threshold, a 15 ms slice demotes a HIGH job to NORMAL, is reported once through the client's error handler, and the job runs on to completion (slice logged)",
  function(ctx)
    local scope = trackScope(SchedulerKit:CreateScope())
    local restoreThreshold, harnessThreshold =
      overrideRunawayThreshold(DEFAULT_RUNAWAY_THRESHOLD_MS)
    local reported, observed, restoreHandler = collectReportedErrors()

    local slice = { cpu = 0, wall = 0, secondSliceRan = false, priorityInside = nil }
    local job = scope:Schedule(function(context)
      local wallStart = preciseNow()
      slice.cpu = busyFor(RUNAWAY_SLICE_MS)
      slice.wall = (preciseNow() - wallStart) * 1000
      context:Yield()
      slice.priorityInside = context:GetJob():GetPriority()
      slice.secondSliceRan = true
    end, { priority = Priority.HIGH, name = RUNAWAY_JOB_NAME })

    waitUntil(ctx, function()
      return not job:IsPending()
    end, WAIT_TIMEOUT_SECONDS)
    restoreThreshold()
    restoreHandler()

    local own = reportsContaining(reported, RUNAWAY_JOB_NAME)
    ctx:Log(
      ("slice: debugprofilestop %.2f ms, GetTimePreciseSec %.2f ms; threshold during the test %d ms, harness value %s ms put back"):format(
        slice.cpu,
        slice.wall,
        DEFAULT_RUNAWAY_THRESHOLD_MS,
        tostring(harnessThreshold)
      )
    )
    ctx:Log(("the collector received %d report(s), %d naming the job"):format(#reported, #own))
    ctx:Expect(SchedulerKit:GetRunawayThreshold()):ToBe(harnessThreshold)
    ctx:Expect(slice.cpu >= RUNAWAY_SLICE_MS):ToBe(true)
    ctx:Expect(job:GetState()):ToBe("completed")
    ctx:Expect(slice.secondSliceRan):ToBe(true)
    ctx:Expect(slice.priorityInside):ToBe(Priority.NORMAL)
    ctx:Expect(job:GetPriority()):ToBe(Priority.NORMAL)
    if not observed then
      ctx:Fail(HANDLER_KEPT_MESSAGE)
      return
    end
    ctx:Expect(#own):ToBe(1)
    ctx:Log("reported: " .. tostring(own[1]))
    local report = own[1] or ""
    ctx:Expect(report:find("exceeded the cooperative slice threshold", 1, true) ~= nil):ToBe(true)
    ctx:Expect(report:find("> " .. DEFAULT_RUNAWAY_THRESHOLD_MS .. "ms", 1, true) ~= nil):ToBe(true)
  end
)

runaway:Test(
  "Context:Yield inside pcall cannot cross the client's C-call boundary: the job runs on, completes, and the swallowed yield is reported once (client message logged)",
  function(ctx)
    local scope = trackScope(SchedulerKit:CreateScope())
    local reported, observed, restoreHandler = collectReportedErrors()
    local outcome = { yielded = nil, message = nil, ranOn = false }
    local job = scope:Schedule(function(context)
      outcome.yielded, outcome.message = pcall(context.Yield, context)
      outcome.ranOn = true
    end, { name = SWALLOWED_YIELD_JOB_NAME })

    waitUntil(ctx, function()
      return not job:IsPending()
    end, WAIT_TIMEOUT_SECONDS)
    restoreHandler()

    local own = reportsContaining(reported, SWALLOWED_YIELD_JOB_NAME)
    ctx:Log("pcall around Yield answered: " .. tostring(outcome.message))
    ctx:Expect(outcome.yielded):ToBe(false)
    ctx:Expect(tostring(outcome.message):find("yield across", 1, true) ~= nil):ToBe(true)
    ctx:Expect(outcome.ranOn):ToBe(true)
    ctx:Expect(job:GetState()):ToBe("completed")
    ctx:Expect(job:HasError()):ToBe(false)
    if not observed then
      ctx:Fail(HANDLER_KEPT_MESSAGE)
      return
    end
    ctx:Expect(#own):ToBe(1)
    ctx:Log("reported: " .. tostring(own[1]))
    ctx:Expect((own[1] or ""):find("never reached the scheduler", 1, true) ~= nil):ToBe(true)
  end
)

-- schedulerKit.jobErrors -----------------------------------------------------------------

local jobErrors = newSuite("jobErrors")

---Describe one probe result for the log without formatting a secret or a table.
---@param ok boolean
---@param value any
---@return string
local function describeProbe(ok, value)
  if not ok then
    return "raised " .. tostring(value)
  end
  if type(value) == "string" then
    return "string of " .. #value .. " bytes: " .. value:gsub("\n", " | "):sub(1, 300)
  end
  return type(value)
end

jobErrors:Test(
  "the client's debug library is logged: what debug.traceback and debugstack return for a failed coroutine",
  function(ctx)
    -- selene: allow(global_usage)
    local debugLibrary = rawget(_G, "debug")
    ctx:Log("type(debug): " .. type(debugLibrary))
    local traceback = type(debugLibrary) == "table" and rawget(debugLibrary, "traceback") or nil
    ctx:Log("type(debug.traceback): " .. type(traceback))
    -- selene: allow(global_usage)
    local debugstack = rawget(_G, "debugstack")
    ctx:Log("type(debugstack): " .. type(debugstack))

    local thread = coroutine.create(function()
      error("mctSchedulerKit traceback probe")
    end)
    local resumed, failure = coroutine.resume(thread)
    ctx:Log("coroutine failed: " .. tostring(not resumed) .. "; error: " .. tostring(failure))

    if type(traceback) == "function" then
      ctx:Log(
        "debug.traceback(thread, message): "
          .. describeProbe(pcall(traceback, thread, tostring(failure)))
      )
      ctx:Log("debug.traceback(message): " .. describeProbe(pcall(traceback, tostring(failure))))
    end
    if type(debugstack) == "function" then
      ctx:Log("debugstack(thread): " .. describeProbe(pcall(debugstack, thread)))
      ctx:Log(
        "debugstack(thread, 1, 12, 12): " .. describeProbe(pcall(debugstack, thread, 1, 12, 12))
      )
      ctx:Log("debugstack(): " .. describeProbe(pcall(debugstack)))
      -- SchedulerKit's xpcall handler reads the failing frames with
      -- `pcall(debugstack, 3)`: level 1 is pcall, 2 the handler, so 3
      -- should be the first failing frame. This logs what the client shows.
      local _, handlerStack = xpcall(function()
        error("mctSchedulerKit handler probe")
      end, function()
        local stackOk, stack = pcall(debugstack, 3)
        return describeProbe(stackOk, stack)
      end)
      ctx:Log("debugstack(3) inside an xpcall handler: " .. tostring(handlerStack))
    end
    ctx:Expect(resumed):ToBe(false)
  end
)

jobErrors:Test(
  "a job that raises is failed with its original error object and a traceback naming SchedulerKitSuite.lua at the raising line, is reported once, and does not stop an unrelated job",
  function(ctx)
    local scope = trackScope(SchedulerKit:CreateScope())
    local reported, observed, restoreHandler = collectReportedErrors()
    local failingLine = 0
    local errorObject = { reason = CALLBACK_FAILURE }

    local stringJob = scope:Schedule(function()
      failingLine = currentLine()
      error(CALLBACK_FAILURE)
    end)
    local objectJob = scope:Schedule(function()
      error(errorObject)
    end)
    local unrelatedRan = false
    local unrelatedJob = scope:Schedule(function()
      unrelatedRan = true
    end)

    waitUntil(ctx, function()
      return not stringJob:IsPending()
        and not objectJob:IsPending()
        and not unrelatedJob:IsPending()
    end, WAIT_TIMEOUT_SECONDS)
    restoreHandler()

    ctx:Expect(stringJob:GetState()):ToBe("failed")
    ctx:Expect(stringJob:HasError()):ToBe(true)
    local message = stringJob:GetError()
    ctx:Log("GetError: " .. tostring(message))
    local line = expectThisFile(ctx, message)
    ctx:Expect(line):ToBe(failingLine + 1)
    ctx:Expect(tostring(message):sub(-#CALLBACK_FAILURE)):ToBe(CALLBACK_FAILURE)

    local traceback = stringJob:GetErrorTraceback()
    ctx:Expect(type(traceback)):ToBe("string")
    local tracebackText = tostring(traceback)
    ctx:Log("GetErrorTraceback: " .. tracebackText:gsub("\n", " | "):sub(1, 400))
    local stackStart = tracebackText:find("stack traceback:", 1, true)
    ctx:Expect(type(stackStart)):ToBe("number")
    -- `debug.traceback` writes the raising frame as `SchedulerKitSuite.lua:<line>:`;
    -- the client's `debugstack`, SchedulerKit's source when the client has
    -- no `debug` global, brackets the path: `SchedulerKitSuite.lua]:<line>:`.
    local raisingLine = ":" .. (failingLine + 1) .. ":"
    local namedByTraceback = tracebackText:find(SUITE_FILE .. raisingLine, stackStart or 1, true)
    local namedByDebugStack =
      tracebackText:find(SUITE_FILE .. "]" .. raisingLine, stackStart or 1, true)
    ctx:Expect(namedByTraceback ~= nil or namedByDebugStack ~= nil):ToBe(true)

    ctx:Expect(objectJob:GetState()):ToBe("failed")
    ctx:Expect(objectJob:HasError()):ToBe(true)
    ctx:Expect(objectJob:GetError()):ToBe(errorObject)
    ctx:Expect(type(objectJob:GetErrorTraceback())):ToBe("string")

    ctx:Expect(unrelatedRan):ToBe(true)
    ctx:Expect(unrelatedJob:GetState()):ToBe("completed")
    ctx:Expect(unrelatedJob:HasError()):ToBe(false)
    ctx:Expect(unrelatedJob:GetErrorTraceback()):ToBeNil()
    ctx:Expect(scope:GetActiveCount()):ToBe(0)

    if not observed then
      ctx:Fail(HANDLER_KEPT_MESSAGE)
      return
    end
    ctx:Log(("the collector received %d report(s)"):format(#reported))
    ctx:Expect(countReports(reported, traceback)):ToBe(1)
    ctx:Expect(countReports(reported, objectJob:GetErrorTraceback())):ToBe(1)
  end
)

-- schedulerKit.scopes --------------------------------------------------------------------

local scopes = newSuite("scopes")

clockTest(
  scopes,
  "CancelAll stops a yielding job between slices and cancels a delayed and a repeating job before the real C_Timer fires, and the scope still runs new work",
  function(ctx)
    local scope = trackScope(SchedulerKit:CreateScope())
    local counts = { slices = 0, delayed = 0, repeating = 0 }
    local looping = scope:Schedule(function(context)
      while true do
        counts.slices = counts.slices + 1
        context:Yield()
      end
    end, { name = "mctSchedulerKit endless probe" })
    local delayed = scope:After(ONE_SHOT_DELAY_SECONDS, function()
      counts.delayed = counts.delayed + 1
    end)
    local repeating = scope:Every(ONE_SHOT_DELAY_SECONDS, function()
      counts.repeating = counts.repeating + 1
    end)

    local reached = waitUntil(ctx, function()
      return counts.slices >= 3
    end, WAIT_TIMEOUT_SECONDS)
    ctx:Expect(reached):ToBe(true)
    ctx:Expect(scope:GetActiveCount()):ToBe(3)
    ctx:Expect(scope:CancelAll()):ToBe(true)
    local slicesAtCancel = counts.slices
    ctx:Expect(scope:GetActiveCount()):ToBe(0)
    ctx:Expect(scope:IsClosed()):ToBe(false)

    waitUntilInstant(ctx, preciseNow() + ONE_SHOT_DELAY_SECONDS + QUIET_WAIT_SECONDS)
    ctx:Log(
      ("slices after CancelAll: %d; delayed runs: %d; repeating runs: %d"):format(
        counts.slices - slicesAtCancel,
        counts.delayed,
        counts.repeating
      )
    )
    ctx:Expect(counts.slices):ToBe(slicesAtCancel)
    ctx:Expect(counts.delayed):ToBe(0)
    ctx:Expect(counts.repeating):ToBe(0)
    ctx:Expect(looping:GetState()):ToBe("cancelled")
    ctx:Expect(delayed:GetState()):ToBe("cancelled")
    ctx:Expect(repeating:GetState()):ToBe("cancelled")

    local again = scope:Schedule(ignore)
    local ran = waitUntil(ctx, function()
      return not again:IsPending()
    end, WAIT_TIMEOUT_SECONDS)
    ctx:Expect(ran):ToBe(true)
    ctx:Expect(again:GetState()):ToBe("completed")
  end
)

clockTest(
  scopes,
  "Close cancels a delayed job before the real C_Timer fires, answers true then false, and the closed scope refuses Schedule at the calling line",
  function(ctx)
    local scope = trackScope(SchedulerKit:CreateScope())
    local ran = 0
    local delayed = scope:After(TICK_INTERVAL_SECONDS, function()
      ran = ran + 1
    end)

    ctx:Expect(scope:Close()):ToBe(true)
    ctx:Expect(scope:Close()):ToBe(false)
    ctx:Expect(scope:IsClosed()):ToBe(true)
    ctx:Expect(scope:GetActiveCount()):ToBe(0)
    ctx:Expect(delayed:GetState()):ToBe("cancelled")
    waitUntilInstant(ctx, preciseNow() + TICK_INTERVAL_SECONDS + QUIET_WAIT_SECONDS)
    ctx:Expect(ran):ToBe(0)

    local startLine = 0

    local line = expectErrorAtCallingLine(ctx, function()
      startLine = currentLine()
      scope:Schedule(ignore)
    end, "SchedulerKit.Scope:Schedule cannot schedule work in a closed scope")
    ctx:Expect(line):ToBe(startLine + 1)
  end
)

scopes:Test(
  "ForAddon with this test addon's name returns one open scope naming the addon, and its jobs run",
  function(ctx)
    local scope = SchedulerKit:ForAddon(addonName)
    ctx:Expect(SchedulerKit:ForAddon(addonName)):ToBe(scope)
    ctx:Expect(scope:GetAddonName()):ToBe(addonName)
    ctx:Expect(scope:IsClosed()):ToBe(false)

    -- Which logout route SchedulerKit took; docs/API.md, "At logout".
    ---@type LifecycleKit|nil
    local LifecycleKit = Registry:Get("lifecycleKit", LIFECYCLE_KIT_API)
    local closesSchedulers = false
    if type(LifecycleKit) ~= "nil" then
      local capabilities = LifecycleKit.CLOSES_ADDON_SCOPES
      closesSchedulers = type(capabilities) == "table" and capabilities[PACKAGE_ID] == true
    end
    ctx:Log(
      "LifecycleKit loaded: "
        .. tostring(type(LifecycleKit) ~= "nil")
        .. "; it lists schedulerKit in CLOSES_ADDON_SCOPES: "
        .. tostring(closesSchedulers)
    )

    local job = scope:Schedule(ignore, { name = "mctSchedulerKit addon scope probe" })
    pendingReleases[#pendingReleases + 1] = function()
      job:Cancel()
    end
    local ran = waitUntil(ctx, function()
      return not job:IsPending()
    end, WAIT_TIMEOUT_SECONDS)
    ctx:Expect(ran):ToBe(true)
    ctx:Expect(job:GetState()):ToBe("completed")
    ctx:Expect(job:GetScope()):ToBe(scope)
  end
)

clockTest(
  scopes,
  "CloseAddonScopes stops a probe addon's yielding job and delayed job, answers true then false, and ForAddon keeps the closed scope",
  function(ctx)
    probeSequence = probeSequence + 1
    local probeName = PROBE_ADDON_PREFIX .. probeSequence
    ctx:Expect(SchedulerKit:CloseAddonScopes(probeName)):ToBe(false)

    local scope = SchedulerKit:ForAddon(probeName)
    local counts = { slices = 0, delayed = 0 }
    local looping = scope:Schedule(function(context)
      while true do
        counts.slices = counts.slices + 1
        context:Yield()
      end
    end)
    local delayed = scope:After(ONE_SHOT_DELAY_SECONDS, function()
      counts.delayed = counts.delayed + 1
    end)
    local reached = waitUntil(ctx, function()
      return counts.slices >= 2
    end, WAIT_TIMEOUT_SECONDS)
    ctx:Expect(reached):ToBe(true)

    ctx:Expect(SchedulerKit:CloseAddonScopes(probeName)):ToBe(true)
    local slicesAtClose = counts.slices
    ctx:Expect(SchedulerKit:CloseAddonScopes(probeName)):ToBe(false)
    ctx:Expect(scope:IsClosed()):ToBe(true)
    ctx:Expect(scope:GetActiveCount()):ToBe(0)
    ctx:Expect(SchedulerKit:ForAddon(probeName)):ToBe(scope)

    waitUntilInstant(ctx, preciseNow() + ONE_SHOT_DELAY_SECONDS + QUIET_WAIT_SECONDS)
    ctx:Log(
      ("probe %s: slices after the close: %d; delayed runs: %d"):format(
        probeName,
        counts.slices - slicesAtClose,
        counts.delayed
      )
    )
    ctx:Expect(counts.slices):ToBe(slicesAtClose)
    ctx:Expect(counts.delayed):ToBe(0)
    ctx:Expect(looping:GetState()):ToBe("cancelled")
    ctx:Expect(delayed:GetState()):ToBe("cancelled")
  end
)

scopes:Skip(
  "at logout this addon's scope is closed and its jobs cancelled",
  "not observable in a run: PLAYER_LOGOUT ends the session before a result could be printed or saved; packages/schedulerKit/tests/LogoutCoverage_spec.lua proves it"
)

-- schedulerKit.coalescing ----------------------------------------------------------------

local coalescing = newSuite("coalescing")

clockTest(
  coalescing,
  "Debounce(0.1) called on five consecutive frames runs once, with the last call's argument, one delay after the last call (delay logged)",
  function(ctx)
    local scope = trackScope(SchedulerKit:CreateScope())
    local fires = {}
    local handle = scope:Debounce(function(value)
      fires[#fires + 1] = { value = value, at = preciseNow() }
    end, TICK_INTERVAL_SECONDS)

    local calls = 0
    local lastCallAt = preciseNow()
    local callFrames = {}
    waitUntil(ctx, function()
      calls = calls + 1
      callFrames[#callFrames + 1] = frameKey()
      lastCallAt = preciseNow()
      handle(calls)
      return calls >= 5
    end, WAIT_TIMEOUT_SECONDS)
    ctx:Expect(handle:IsPending()):ToBe(true)
    local firesDuringBurst = #fires

    local wait = measuredWait(ctx, function()
      return #fires > 0
    end, WAIT_TIMEOUT_SECONDS)
    waitUntilInstant(ctx, preciseNow() + QUIET_WAIT_SECONDS)

    local _, burstFrames = frameOrdinals(callFrames)
    local delay = ((fires[1] and fires[1].at) or lastCallAt) - lastCallAt
    local allowance = frameAllowance(wait)
    ctx:Log(
      ("%d calls over %d rendered frames; fired %d time(s), %s after the last call; allowance %s"):format(
        calls,
        burstFrames,
        #fires,
        milliseconds(delay),
        milliseconds(allowance)
      )
    )
    ctx:Expect(burstFrames):ToBe(5)
    ctx:Expect(firesDuringBurst):ToBe(0)
    ctx:Expect(#fires):ToBe(1)
    ctx:Expect(fires[1] and fires[1].value):ToBe(5)
    ctx:Expect(delay >= TICK_INTERVAL_SECONDS - EARLY_WAKE_SECONDS):ToBe(true)
    ctx:Expect(delay <= TICK_INTERVAL_SECONDS + allowance):ToBe(true)
    ctx:Expect(handle:IsPending()):ToBe(false)
  end
)

clockTest(
  coalescing,
  "Debounce with leading runs inside the first call of a three-call burst and once more after it goes quiet, with the last call's argument",
  function(ctx)
    local scope = trackScope(SchedulerKit:CreateScope())
    local fires = {}
    local handle = scope:Debounce(function(value)
      fires[#fires + 1] = value
    end, TICK_INTERVAL_SECONDS, { leading = true })

    ctx:Expect(handle("first")):ToBe(true)
    ctx:Expect(#fires):ToBe(1)
    local calls = 1
    waitUntil(ctx, function()
      calls = calls + 1
      handle(calls == 3 and "last" or "middle")
      return calls >= 3
    end, WAIT_TIMEOUT_SECONDS)
    local fired = waitUntil(ctx, function()
      return #fires >= 2
    end, WAIT_TIMEOUT_SECONDS)
    waitUntilInstant(ctx, preciseNow() + QUIET_WAIT_SECONDS)
    ctx:Log("fires: " .. table.concat(fires, ", "))
    ctx:Expect(fired):ToBe(true)
    ctx:Expect(#fires):ToBe(2)
    ctx:Expect(fires[1]):ToBe("first")
    ctx:Expect(fires[2]):ToBe("last")
  end
)

clockTest(
  coalescing,
  "Coalesce(0.1) delivers the keys recorded over three frames as one set, once, one interval after the first key (set and delay logged)",
  function(ctx)
    local scope = trackScope(SchedulerKit:CreateScope())
    local deliveries = {}
    local handle = scope:Coalesce(function(set)
      -- The set is reused after the callback returns; copy it.
      local copy = {}
      for key, value in pairs(set) do
        copy[key] = value
      end
      deliveries[#deliveries + 1] = { set = copy, at = preciseNow() }
    end, TICK_INTERVAL_SECONDS)

    -- WaitUntil asks its predicate at once, then once per rendered frame,
    -- so the three keys arrive on three consecutive frames.
    local keys = { "player", "target", "player" }
    local recorded = 0
    local firstKeyAt = preciseNow()
    local keyFrames = {}
    waitUntil(ctx, function()
      recorded = recorded + 1
      if recorded == 1 then
        firstKeyAt = preciseNow()
      end
      keyFrames[recorded] = frameKey()
      handle(keys[recorded], recorded)
      return recorded >= #keys
    end, WAIT_TIMEOUT_SECONDS)
    local _, keyFrameCount = frameOrdinals(keyFrames)
    ctx:Expect(handle:IsPending()):ToBe(true)

    local wait = measuredWait(ctx, function()
      return #deliveries > 0
    end, WAIT_TIMEOUT_SECONDS)
    waitUntilInstant(ctx, preciseNow() + QUIET_WAIT_SECONDS)

    local delivered = deliveries[1] and deliveries[1].set or {}
    local delay = ((deliveries[1] and deliveries[1].at) or firstKeyAt) - firstKeyAt
    local allowance = frameAllowance(wait)
    ctx:Log(
      ("keys over %d rendered frames; %d delivery(ies); player=%s target=%s; %s after the first key; allowance %s"):format(
        keyFrameCount,
        #deliveries,
        tostring(delivered.player),
        tostring(delivered.target),
        milliseconds(delay),
        milliseconds(allowance)
      )
    )
    ctx:Expect(keyFrameCount):ToBe(3)
    ctx:Expect(#deliveries):ToBe(1)
    ctx:Expect(delivered.player):ToBe(3)
    ctx:Expect(delivered.target):ToBe(2)
    ctx:Expect(delay >= TICK_INTERVAL_SECONDS - EARLY_WAKE_SECONDS):ToBe(true)
    ctx:Expect(delay <= TICK_INTERVAL_SECONDS + allowance):ToBe(true)
    ctx:Expect(handle:GetStats().delivered):ToBe(1)
    ctx:Expect(handle:IsPending()):ToBe(false)
  end
)

clockTest(
  coalescing,
  "two Watch(0.1) of one interval share the real ticker: first tick with previous nil in one frame, then a call only on change, and Cancel stops one watch while the other keeps ticking (calls logged)",
  function(ctx)
    local scope = trackScope(SchedulerKit:CreateScope())
    -- Called through an untyped alias: the LuaCATS field SchedulerKit
    -- declares for `Watch` begins with `predicate: fun(): any`, which
    -- lua-language-server reads as a predicate returning every later
    -- parameter, so a direct call is reported as passing too many arguments.
    ---@type any
    local untypedScope = scope
    local watched = { value = 1 }
    local calls = {}
    local companionFrames = {}
    local watch = untypedScope:Watch(
      function()
        return watched.value
      end,
      TICK_INTERVAL_SECONDS,
      function(value, previous)
        calls[#calls + 1] = { value = value, previous = previous, frame = frameKey() }
      end
    )
    local companion = untypedScope:Watch(
      function()
        return true
      end,
      TICK_INTERVAL_SECONDS,
      function()
        companionFrames[#companionFrames + 1] = frameKey()
      end,
      { everyTick = true }
    )

    local first = waitUntil(ctx, function()
      return #calls >= 1 and #companionFrames >= 1
    end, WAIT_TIMEOUT_SECONDS)
    ctx:Expect(first):ToBe(true)
    ctx:Expect(calls[1] and calls[1].value):ToBe(1)
    ctx:Expect(calls[1] and calls[1].previous):ToBeNil()
    ctx:Expect(calls[1] and calls[1].frame):ToBe(companionFrames[1])

    waitUntilInstant(ctx, preciseNow() + 2 * TICK_INTERVAL_SECONDS)
    local callsWhileUnchanged = #calls - 1
    watched.value = 2
    local changed = waitUntil(ctx, function()
      return #calls >= 2
    end, WAIT_TIMEOUT_SECONDS)
    ctx:Expect(changed):ToBe(true)
    ctx:Expect(calls[2] and calls[2].value):ToBe(2)
    ctx:Expect(calls[2] and calls[2].previous):ToBe(1)

    waitUntilInstant(ctx, preciseNow() + QUIET_WAIT_SECONDS)
    local callsAfterChange = #calls - 2
    ctx:Expect(watch:Cancel()):ToBe(true)
    ctx:Expect(watch:Cancel()):ToBe(false)
    ctx:Expect(watch:IsActive()):ToBe(false)
    watched.value = 3
    local companionBefore = #companionFrames
    waitUntilInstant(ctx, preciseNow() + QUIET_WAIT_SECONDS)
    ctx:Log(
      ("calls while unchanged: %d; after the change settled: %d; after Cancel: %d; the everyTick companion was called %d time(s) meanwhile"):format(
        callsWhileUnchanged,
        callsAfterChange,
        #calls - 2 - callsAfterChange,
        #companionFrames - companionBefore
      )
    )
    ctx:Expect(callsWhileUnchanged):ToBe(0)
    ctx:Expect(callsAfterChange):ToBe(0)
    ctx:Expect(#calls):ToBe(2)
    -- The shared ticker outlives the cancelled watch while one remains.
    ctx:Expect(#companionFrames > companionBefore):ToBe(true)
    ctx:Expect(companion:IsActive()):ToBe(true)
  end
)

-- schedulerKit.allocation ----------------------------------------------------------------

local allocation = newSuite("allocation")

clockTest(
  allocation,
  "20000 resumes of one yielding job allocate nothing, counted in chunks of 1000 that stayed inside one driver pass (allocation guard; chunks logged)",
  function(ctx)
    local scope = trackScope(SchedulerKit:CreateScope())
    -- The predicate below is the TestKit runner's only work per frame, so
    -- a change of this counter inside a chunk means another job ran.
    local runnerChecks = { count = 0 }
    local result = nil
    collectBeforeMeasuring(ctx)

    local restoreBudget = overrideFrameBudget(RESUME_GUARD_BUDGET_MS)
    local restoreCeiling = overrideMaxResumes(RESUME_GUARD_MAX_RESUMES)
    local job = scope:Schedule(function(context)
      local measured = { valid = 0, discarded = 0, grownKilobytes = 0 }
      local attempts = 0
      while measured.valid < RESUME_CHUNKS and attempts < MAX_RESUME_CHUNK_ATTEMPTS do
        attempts = attempts + 1
        local startFrame = frameKey()
        local startChecks = runnerChecks.count
        local before = collectgarbage("count")
        for _ = 1, RESUMES_PER_CHUNK do
          context:Yield()
        end
        local after = collectgarbage("count")
        if frameKey() == startFrame and runnerChecks.count == startChecks then
          measured.valid = measured.valid + 1
          measured.grownKilobytes = measured.grownKilobytes + (after - before)
        else
          measured.discarded = measured.discarded + 1
        end
      end
      result = measured
    end, { priority = Priority.HIGH, name = "mctSchedulerKit resume guard" })

    local finished = waitUntil(ctx, function()
      runnerChecks.count = runnerChecks.count + 1
      return not job:IsPending()
    end, WAIT_TIMEOUT_SECONDS)
    restoreCeiling()
    restoreBudget()

    ctx:Expect(finished):ToBe(true)
    ctx:Expect(job:GetState()):ToBe("completed")
    ctx:Expect(type(result)):ToBe("table")
    if type(result) ~= "table" then
      return
    end
    ctx:Log(
      ("%d chunks of %d resumes measured, %d discarded (a frame ended or another job ran inside them); memory delta %.3f KB"):format(
        result.valid,
        RESUMES_PER_CHUNK,
        result.discarded,
        result.grownKilobytes
      )
    )
    ctx:Expect(result.valid):ToBe(RESUME_CHUNKS)
    ctx:Expect(result.grownKilobytes <= ALLOCATION_TOLERANCE_KB):ToBe(true)
    ctx:Expect(SchedulerKit:GetFrameBudget()):ToBe(DEFAULT_FRAME_BUDGET_MS)
    ctx:Expect(SchedulerKit:GetMaxResumesPerFrame()):ToBe(DEFAULT_MAX_RESUMES_PER_FRAME)
  end
)

allocation:Test(
  "10000 Debounce calls inside an open window and 10000 Coalesce calls of a known key allocate nothing (allocation guard)",
  function(ctx)
    local scope = trackScope(SchedulerKit:CreateScope())
    local debounce = scope:Debounce(ignore, LONG_DELAY_SECONDS)
    local coalesce = scope:Coalesce(ignore, LONG_DELAY_SECONDS)
    -- Open the window and record the key once, outside the measurement.
    debounce(1, 2)
    coalesce("known", true)
    collectBeforeMeasuring(ctx)

    local debounceKilobytes = measureAllocation(function()
      for index = 1, FAMILY_CALLS do
        debounce(index, index)
      end
    end)
    collectBeforeMeasuring(ctx)
    local coalesceKilobytes = measureAllocation(function()
      for index = 1, FAMILY_CALLS do
        coalesce("known", index)
      end
    end)

    ctx:Log(
      ("memory delta over %d calls: Debounce %.3f KB; Coalesce %.3f KB"):format(
        FAMILY_CALLS,
        debounceKilobytes,
        coalesceKilobytes
      )
    )
    ctx:Expect(debounceKilobytes <= ALLOCATION_TOLERANCE_KB):ToBe(true)
    ctx:Expect(coalesceKilobytes <= ALLOCATION_TOLERANCE_KB):ToBe(true)
    ctx:Expect(debounce:IsPending()):ToBe(true)
    ctx:Expect(coalesce:GetStats().keys):ToBe(1)
  end
)

allocation:Skip(
  "a Watch tick whose value did not change allocates nothing (allocation guard)",
  "not measurable here: C_Timer delivers a tick between frames, where every other addon allocates too; packages/schedulerKit/tests/Watch_spec.lua guards it"
)

-- schedulerKit.errors --------------------------------------------------------------------

local errors = newSuite("errors")

--- The facade without its LuaCATS type, so a test can pass the wrong
--- arguments the documented refusals are about.
---@type any
local untypedSchedulerKit = SchedulerKit

errors:Test(
  "package-level and scope Schedule, NextFrame, After and Every refuse bad arguments, and a scope's methods and Job:Cancel a wrong receiver, at the calling line (messages logged)",
  function(ctx)
    local scope = trackScope(SchedulerKit:CreateScope())
    local untypedScope = scope --[[@as any]]
    local job = scope:After(60, ignore)
    local activeBefore = SchedulerKit:GetActiveCount()
    expectRefusals(ctx, {
      {
        receiver = untypedSchedulerKit,
        method = "Schedule",
        arguments = { "not a function" },
        expected = "SchedulerKit:Schedule callback must be a function",
      },
      {
        receiver = untypedSchedulerKit,
        method = "Schedule",
        arguments = { ignore, { priority = 99 } },
        expected = "SchedulerKit:Schedule priority must be one of SchedulerKit.Priority values",
      },
      {
        receiver = untypedSchedulerKit,
        method = "NextFrame",
        arguments = { 42 },
        expected = "SchedulerKit:NextFrame callback must be a function",
      },
      {
        receiver = untypedSchedulerKit,
        method = "After",
        arguments = { -1, ignore },
        expected = "SchedulerKit:After delay must be a finite number greater than or equal to zero",
      },
      {
        receiver = untypedSchedulerKit,
        method = "Every",
        arguments = { 0, ignore },
        expected = "SchedulerKit:Every interval must be a finite number greater than zero",
      },
      {
        receiver = untypedScope,
        method = "Schedule",
        arguments = { ignore, { name = "" } },
        expected = "SchedulerKit.Scope:Schedule name must be a non-empty string",
      },
      {
        receiver = untypedScope,
        method = "NextFrame",
        arguments = { ignore, { priority = 0 } },
        expected = "SchedulerKit.Scope:NextFrame priority must be one of SchedulerKit.Priority values",
      },
      {
        receiver = untypedScope,
        method = "After",
        arguments = { -1, ignore },
        expected = "SchedulerKit.Scope:After delay must be a finite number greater than or equal to zero",
      },
      {
        receiver = untypedScope,
        method = "Every",
        arguments = { 0, ignore },
        expected = "SchedulerKit.Scope:Every interval must be a finite number greater than zero",
      },
      {
        receiver = untypedScope,
        callAs = {},
        method = "Schedule",
        arguments = { ignore },
        expected = "SchedulerKit.Scope:Schedule must be called on a SchedulerKit scope",
      },
      {
        receiver = untypedScope,
        callAs = {},
        method = "After",
        arguments = { 1, ignore },
        expected = "SchedulerKit.Scope:After must be called on a SchedulerKit scope",
      },
      {
        receiver = untypedScope,
        callAs = {},
        method = "CancelAll",
        arguments = {},
        expected = "SchedulerKit.Scope:CancelAll must be called on a SchedulerKit scope",
      },
      {
        receiver = untypedScope,
        callAs = {},
        method = "Close",
        arguments = {},
        expected = "SchedulerKit.Scope:Close must be called on a SchedulerKit scope",
      },
      {
        receiver = job,
        callAs = {},
        method = "Cancel",
        arguments = {},
        expected = "SchedulerKit.Job:Cancel must be called on a SchedulerKit job",
      },
    })
    ctx:Expect(SchedulerKit:GetActiveCount()):ToBe(activeBefore)
    ctx:Expect(scope:GetActiveCount()):ToBe(1)
    ctx:Expect(scope:IsClosed()):ToBe(false)
    ctx:Expect(job:GetState()):ToBe("delayed")
  end
)

errors:Test(
  "ForAddon with an empty name and CloseAddonScopes on another receiver are refused at the calling line",
  function(ctx)
    expectRefusals(ctx, {
      {
        receiver = untypedSchedulerKit,
        method = "ForAddon",
        arguments = { "" },
        expected = "SchedulerKit:ForAddon addonName must be a non-empty string",
      },
      {
        receiver = untypedSchedulerKit,
        callAs = {},
        method = "CloseAddonScopes",
        arguments = { addonName },
        expected = "SchedulerKit:CloseAddonScopes must be called on the SchedulerKit facade; use SchedulerKit:CloseAddonScopes(addonName)",
      },
    })
  end
)

errors:Test(
  "SetFrameBudget(0), SetRunawayThreshold(-1) and SetMaxResumesPerFrame(1.5) are refused at the calling line and change nothing",
  function(ctx)
    local budgetBefore = SchedulerKit:GetFrameBudget()
    local thresholdBefore = SchedulerKit:GetRunawayThreshold()
    local ceilingBefore = SchedulerKit:GetMaxResumesPerFrame()
    expectRefusals(ctx, {
      {
        receiver = untypedSchedulerKit,
        method = "SetFrameBudget",
        arguments = { 0 },
        expected = "SchedulerKit:SetFrameBudget milliseconds must be a finite number greater than zero",
      },
      {
        receiver = untypedSchedulerKit,
        method = "SetRunawayThreshold",
        arguments = { -1 },
        expected = "SchedulerKit:SetRunawayThreshold milliseconds must be a finite number greater than zero",
      },
      {
        receiver = untypedSchedulerKit,
        method = "SetMaxResumesPerFrame",
        arguments = { 1.5 },
        expected = "SchedulerKit:SetMaxResumesPerFrame count must be a finite positive integer",
      },
    })
    ctx:Expect(SchedulerKit:GetFrameBudget()):ToBe(budgetBefore)
    ctx:Expect(SchedulerKit:GetRunawayThreshold()):ToBe(thresholdBefore)
    ctx:Expect(SchedulerKit:GetMaxResumesPerFrame()):ToBe(ceilingBefore)
  end
)

errors:Test(
  "Schedule on a scope with unknown option fields names the alphabetically first one at the calling line, and schedules nothing",
  function(ctx)
    local scope = trackScope(SchedulerKit:CreateScope())
    expectRefusals(ctx, {
      {
        receiver = scope,
        method = "Schedule",
        arguments = { ignore, { zeta = 1, alpha = 2 } },
        expected = 'SchedulerKit.Scope:Schedule options contains unknown field "alpha"',
      },
    })
    ctx:Expect(scope:GetActiveCount()):ToBe(0)
  end
)

errors:Test(
  "Context:ShouldYield and Context:Yield after their job finished are refused at the calling line",
  function(ctx)
    local scope = trackScope(SchedulerKit:CreateScope())
    ---@type SchedulerKit.Context|false
    local captured = false
    local job = scope:Schedule(function(context)
      captured = context
    end)
    waitUntil(ctx, function()
      return not job:IsPending()
    end, WAIT_TIMEOUT_SECONDS)
    ctx:Expect(type(captured)):ToBe("table")
    if captured == false then
      return
    end
    expectRefusals(ctx, {
      {
        receiver = captured,
        method = "ShouldYield",
        arguments = {},
        expected = "SchedulerKit.Context:ShouldYield may only be called while its job is running",
      },
      {
        receiver = captured,
        method = "Yield",
        arguments = {},
        expected = "SchedulerKit.Context:Yield may only be called while its job is running",
      },
    })
  end
)

errors:Test(
  "Debounce with maxWaitSeconds below its delay, Watch with a zero interval and Lane with an empty name are refused at the calling line",
  function(ctx)
    local scope = trackScope(SchedulerKit:CreateScope())
    expectRefusals(ctx, {
      {
        receiver = scope,
        method = "Debounce",
        arguments = { ignore, 1, { maxWaitSeconds = 0.5 } },
        expected = "SchedulerKit.Scope:Debounce maxWaitSeconds must be at least delaySeconds",
      },
      {
        receiver = untypedSchedulerKit,
        method = "Watch",
        arguments = { ignore, 0, ignore },
        expected = "SchedulerKit:Watch intervalSeconds must be a finite number greater than zero",
      },
      {
        receiver = untypedSchedulerKit,
        method = "Lane",
        arguments = { "" },
        expected = "SchedulerKit:Lane name must be a non-empty string",
      },
    })
    ctx:Expect(scope:GetActiveCount()):ToBe(0)
  end
)

-- schedulerKit.secrets -------------------------------------------------------------------

local secrets = newSuite("secrets")

--- Why the secrets tests are skipped on a client without the two functions.
local SECRETS_SKIP_REASON =
  "the client has no issecretvalue and secretwrap; the secret path was not exercised"

---Register `body` as a test when the client can make a secret value, and as a
---skipped test naming why otherwise.
---@param name string
---@param body fun(ctx: TestKit.Context)
local function secretTest(name, body)
  if SECRETS_AVAILABLE then
    secrets:Test(name, body)
  else
    secrets:Skip(name, SECRETS_SKIP_REASON)
  end
end

---A genuine secret value made by the client's `secretwrap`, or a failed test.
---
---`secretwrap` is documented in the client's own API documentation
---(`Blizzard_APIDocumentationGenerated`); it wraps a plain value into a secret
---without touching any game state, so calling it has no side effect.
---@param ctx TestKit.Context
---@param value any
---@return any secret
local function makeSecret(ctx, value)
  local succeeded, secret = pcall(secretWrap, value)
  if not succeeded then
    ctx:Fail("secretwrap raised, so the secret path was not exercised: " .. tostring(secret))
  end
  if isSecretValue(secret) ~= true then
    ctx:Fail("secretwrap returned a value issecretvalue does not report as secret")
  end
  return secret
end

secretTest(
  "ForAddon, CloseAddonScopes and Lane refuse a secret name at the calling line before comparing it",
  function(ctx)
    local secretName = makeSecret(ctx, addonName)
    expectRefusals(ctx, {
      {
        receiver = SchedulerKit,
        method = "ForAddon",
        arguments = { secretName },
        expected = "SchedulerKit:ForAddon addonName must not be a secret value",
      },
      {
        receiver = SchedulerKit,
        method = "CloseAddonScopes",
        arguments = { secretName },
        expected = "SchedulerKit:CloseAddonScopes addonName must not be a secret value",
      },
      {
        receiver = SchedulerKit,
        method = "Lane",
        arguments = { secretName },
        expected = "SchedulerKit:Lane name must not be a secret value",
      },
    })
  end
)

secretTest(
  "SetFrameBudget, SetRunawayThreshold and SetMaxResumesPerFrame refuse a secret at the calling line and change nothing",
  function(ctx)
    local secretNumber = makeSecret(ctx, 4)
    local budgetBefore = SchedulerKit:GetFrameBudget()
    local thresholdBefore = SchedulerKit:GetRunawayThreshold()
    local ceilingBefore = SchedulerKit:GetMaxResumesPerFrame()
    expectRefusals(ctx, {
      {
        receiver = SchedulerKit,
        method = "SetFrameBudget",
        arguments = { secretNumber },
        expected = "SchedulerKit:SetFrameBudget milliseconds must not be a secret value",
      },
      {
        receiver = SchedulerKit,
        method = "SetRunawayThreshold",
        arguments = { secretNumber },
        expected = "SchedulerKit:SetRunawayThreshold milliseconds must not be a secret value",
      },
      {
        receiver = SchedulerKit,
        method = "SetMaxResumesPerFrame",
        arguments = { secretNumber },
        expected = "SchedulerKit:SetMaxResumesPerFrame count must not be a secret value",
      },
    })
    ctx:Expect(SchedulerKit:GetFrameBudget()):ToBe(budgetBefore)
    ctx:Expect(SchedulerKit:GetRunawayThreshold()):ToBe(thresholdBefore)
    ctx:Expect(SchedulerKit:GetMaxResumesPerFrame()):ToBe(ceilingBefore)
  end
)

secretTest(
  "Debounce leading, Coalesce maxKeys, Watch intervalSeconds and SetLimits maxLanes refuse a secret at the calling line and change no limit",
  function(ctx)
    local secretFlag = makeSecret(ctx, true)
    local secretNumber = makeSecret(ctx, 4)
    local limitsBefore = SchedulerKit:GetLimits()
    expectRefusals(ctx, {
      {
        receiver = SchedulerKit,
        method = "Debounce",
        arguments = { ignore, 1, { leading = secretFlag } },
        expected = "SchedulerKit:Debounce leading must not be a secret value",
      },
      {
        receiver = SchedulerKit,
        method = "Coalesce",
        arguments = { ignore, 1, { maxKeys = secretNumber } },
        expected = "SchedulerKit:Coalesce maxKeys must not be a secret value",
      },
      {
        receiver = SchedulerKit,
        method = "Watch",
        arguments = { ignore, secretNumber, ignore },
        expected = "SchedulerKit:Watch intervalSeconds must not be a secret value",
      },
      {
        receiver = SchedulerKit,
        method = "SetLimits",
        arguments = { { maxLanes = secretNumber } },
        expected = "SchedulerKit:SetLimits limits.maxLanes must not be a secret value",
      },
    })
    ctx:Expect(SchedulerKit:GetLimits()):ToEqual(limitsBefore)
  end
)

secretTest(
  "package-level Schedule priority and name, After delay and a scope's Every interval refuse a secret at the calling line and schedule nothing (messages logged)",
  function(ctx)
    local scope = trackScope(SchedulerKit:CreateScope())
    local secretNumber = makeSecret(ctx, 1)
    local secretName = makeSecret(ctx, "secret job name")
    local activeBefore = SchedulerKit:GetActiveCount()
    expectRefusals(ctx, {
      {
        receiver = SchedulerKit,
        method = "Schedule",
        arguments = { ignore, { priority = secretNumber } },
        expected = "SchedulerKit:Schedule priority must not be a secret value",
      },
      {
        receiver = SchedulerKit,
        method = "Schedule",
        arguments = { ignore, { name = secretName } },
        expected = "SchedulerKit:Schedule name must not be a secret value",
      },
      {
        receiver = SchedulerKit,
        method = "After",
        arguments = { secretNumber, ignore },
        expected = "SchedulerKit:After delay must not be a secret value",
      },
      {
        receiver = scope,
        method = "Every",
        arguments = { secretNumber, ignore },
        expected = "SchedulerKit.Scope:Every interval must not be a secret value",
      },
    })
    ctx:Expect(SchedulerKit:GetActiveCount()):ToBe(activeBefore)
    ctx:Expect(scope:GetActiveCount()):ToBe(0)
  end
)

secretTest(
  "a coalesce handle refuses a secret key at the calling line and delivers a secret value still secret",
  function(ctx)
    local scope = trackScope(SchedulerKit:CreateScope())
    local delivered = { value = nil, count = 0 }
    local handle = scope:Coalesce(function(set)
      delivered.count = delivered.count + 1
      delivered.value = set.stored
    end, LONG_DELAY_SECONDS)
    local secretKey = makeSecret(ctx, "key")
    local secretValue = makeSecret(ctx, 42)

    local startLine = 0
    local line = expectErrorAtCallingLine(ctx, function()
      startLine = currentLine()
      handle(secretKey)
    end, "SchedulerKit coalesce handle key must not be a secret value")
    ctx:Expect(line):ToBe(startLine + 1)

    ctx:Expect(handle("stored", secretValue)):ToBe(true)
    ctx:Expect(handle:Flush()):ToBe(true)
    ctx:Expect(delivered.count):ToBe(1)
    ctx:Expect(isSecretValue(delivered.value)):ToBe(true)
  end
)
