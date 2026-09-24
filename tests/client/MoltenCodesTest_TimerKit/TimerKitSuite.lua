-- MoltenCodes Test: TimerKitSuite.lua
--
-- Real-client suites for the `timerKit` package. The Busted specs under
-- packages/timerKit/tests/ prove TimerKit against a fake `C_Timer` whose
-- timers fire when a spec advances a fake clock; these prove, inside the game
-- client with the installed MoltenCodes addon, what that fixture can only
-- simulate:
--
--   * the installed facade and its committed revision;
--   * that a one-shot fires once, on the real `C_Timer`, close to the deadline
--     TimerKit recorded: the lateness is measured with `GetTimePreciseSec`,
--     logged in milliseconds and held to one frame plus a margin;
--   * that a zero delay runs on a later frame, never inside the call;
--   * that `Cancel` before the deadline keeps the callback from ever running;
--   * that `Every` repeats at its interval, moves its deadline one interval per
--     tick, and stops for good on `Cancel`, also from inside its own callback;
--   * `GetRemaining` and `GetDeadline` against the client's own clock;
--   * that `CancelAll`, `Close` and `CloseAddonScopes` stop real native timers,
--     and `ForAddon` with this addon's name;
--   * that a callback error reaches the client's error handler, and whether a
--     repeating ticker keeps ticking after its callback raised (an open owner
--     question: docs/API.md says it does; the test logs what the client did);
--   * that getters and `Cancel` allocate nothing and `Start` only its one
--     callback closure, measured against the client's own `C_Timer` cost;
--   * argument errors and secret refusals pointing at this file as the client
--     names it.
--
-- Run with `/mct run timerKit`; tests/client/MoltenCodesTest_TimerKit/EXPECTED.md
-- lists what the chat frame should show.
--
-- What a run leaves behind. Every timer, scope and native handle a test creates
-- is cancelled or closed by the After hook of its suite, whatever the test's
-- outcome, so no timer outlives its test. The client's error handler is
-- replaced only while one test waits for its deliberate callback failure, and
-- put back as soon as the wait ends (the After hook puts it back too). Two
-- kinds of TimerKit state stay in the session, because TimerKit keeps an addon
-- scope for good once `ForAddon` created it: this addon's own scope
-- (`TimerKit:ForAddon(addonName)`), empty, closed at logout; and one closed
-- scope per run for a probe addon name (`MoltenCodesTest_TimerKitProbe1`,
-- `...Probe2`, ...), each with the LifecycleKit instance TimerKit asked for
-- when it routed the probe's logout. Nothing is written to a global or a saved
-- variable.

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
local TIMER_KIT_API = 1
local LIFECYCLE_KIT_API = 1
local PACKAGE_ID = "timerKit"

--- The one-shot delay the timing tests measure. Long enough to span many
--- frames, short enough to keep a test well under three seconds.
local ONE_SHOT_DELAY_SECONDS = 0.25

--- The interval of every repeating timer a test starts.
local TICK_INTERVAL_SECONDS = 0.1

--- How many ticks the repeating test observes before it cancels.
local TICKS_TO_OBSERVE = 4

--- How long a test waits for a callback that must not run: several intervals
--- past every deadline the test set, so a native timer that was not cancelled
--- would have fired by then.
local QUIET_WAIT_SECONDS = 0.4

--- The longest any one wait for a callback may take before the test gives up.
local WAIT_TIMEOUT_SECONDS = 2

--- The documented timing tolerance on top of one frame. `C_Timer` delivers on
--- a frame, so a callback can arrive up to one frame after the deadline; the
--- margin absorbs the client's own work in that frame. The frame is the
--- longest one observed during the wait, never shorter than the client's
--- current frame rate says.
local TIMING_MARGIN_SECONDS = 0.02

--- How far inside a tick the deadline TimerKit moved forward may be from
--- `interval` after the tick: the time between TimerKit reading the clock and
--- the callback reading it, a few microseconds, with room to spare.
local TICK_DEADLINE_EPSILON_SECONDS = 0.005

--- Floating-point slack when comparing two readings of the same clock.
local CLOCK_EPSILON_SECONDS = 0.000001

--- A delay no test waits for: timers started with it exist only to be read
--- or cancelled.
local LONG_DELAY_SECONDS = 60

--- How many times each getter runs in the getter allocation guard.
local GETTER_CALLS = 10000

--- How many timers the Cancel guard cancels and how many start-cancel pairs
--- the Start guard runs. Small enough that the native handles alone cannot
--- reach the collector's next step.
local NATIVE_BATCH = 200

--- Kilobytes an allocation guard tolerates. The tolerance absorbs a stray
--- allocation by the client between the two readings, not a per-call one.
local ALLOCATION_TOLERANCE_KB = 1

--- What one `Start` may cost beyond the client's own `C_Timer.NewTimer`:
--- docs/API.md ("Cost") names one callback closure. A Lua 5.1 closure over two
--- upvalues is about 130 bytes on a 64-bit client; 256 leaves room for the
--- allocator's rounding, not for a second object.
local START_BUDGET_BYTES = 256

--- Text a deliberately failing callback raises, so a test can recognise it.
local CALLBACK_FAILURE = "mctTimerKit deliberate callback failure"

--- The prefix of the probe addon names the CloseAddonScopes test closes. A
--- closed addon scope stays closed for the session, so every run uses a
--- fresh name.
local PROBE_ADDON_PREFIX = "MoltenCodesTest_TimerKitProbe"

--- Every method docs/API.md of timerKit lists on the facade.
local FACADE_METHODS = { "New", "After", "Every", "CreateScope", "ForAddon", "CloseAddonScopes" }

--- Every method docs/API.md of timerKit lists on a timer handle.
local TIMER_METHODS = {
  "GetState",
  "GetDelay",
  "GetScope",
  "GetUserData",
  "SetUserData",
  "IsRepeating",
  "IsPending",
  "IsCancelled",
  "Start",
  "Cancel",
  "Restart",
  "GetRemaining",
  "GetDeadline",
}

--- Every method docs/API.md of timerKit lists on a scope.
local SCOPE_METHODS = {
  "New",
  "After",
  "Every",
  "CancelAll",
  "Close",
  "IsClosed",
  "GetAddonName",
  "GetActiveCount",
}

---Read a client global, or `nil`.
---@param name string
---@return any
local function readHost(name)
  -- The clock, the frame rate, C_Timer, error handling and secret-value
  -- functions are World of Warcraft client globals, reachable only through
  -- the global table.
  -- selene: allow(global_usage)
  return rawget(_G, name)
end

---@type Registry
local Registry = rawget(rawget(namespace, "Registries") or {}, REGISTRY_API)
if type(Registry) ~= "table" then
  error(addonName .. " requires the MoltenCodes addon (Registry API 2); reinstall it", 0)
end

---@type TimerKit|nil
local TimerKitOrNil = Registry:Get(PACKAGE_ID, TIMER_KIT_API)
if type(TimerKitOrNil) == "nil" then
  error(addonName .. " requires TimerKit API 1 in the MoltenCodes addon; reinstall it", 0)
end
---@cast TimerKitOrNil TimerKit
local TimerKit = TimerKitOrNil

--- Read once at load: the tests that measure time are registered as skipped
--- on a client without the clock TimerKit's deadlines use.
local getTimePreciseSec = readHost("GetTimePreciseSec")
local CLOCK_AVAILABLE = type(getTimePreciseSec) == "function"

--- Read once at load: the allocation guards measure against the client's own
--- `C_Timer` cost, and are registered as skipped without it.
local hostTimer = readHost("C_Timer")
---@type any
local newNativeTimer = type(hostTimer) == "table" and hostTimer.NewTimer or nil
local NATIVE_TIMER_AVAILABLE = type(newNativeTimer) == "function"

--- The two client functions the secrets suite needs, read once at load: the
--- suite registers its tests as skipped when either is missing.
local isSecretValue = readHost("issecretvalue")
local secretWrap = readHost("secretwrap")
local SECRETS_AVAILABLE = type(isSecretValue) == "function" and type(secretWrap) == "function"

-- Helpers ---------------------------------------------------------------------------

--- Release actions of the test that is running (cancel a timer, close a
--- scope, cancel native handles, put the error handler back), run newest first
--- by the After hook of every suite.
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

---Remember `timer` for the After hook, which cancels it, and hand it back.
---`Cancel` answers `false` for a timer that is not running.
---@param timer TimerKit.Timer
---@return TimerKit.Timer timer
local function trackTimer(timer)
  pendingReleases[#pendingReleases + 1] = function()
    timer:Cancel()
  end
  return timer
end

---Remember `scope` for the After hook, which closes it, and hand it back.
---`Close` answers `false` for a scope that is already closed.
---@param scope TimerKit.Scope
---@return TimerKit.Scope scope
local function trackScope(scope)
  pendingReleases[#pendingReleases + 1] = function()
    scope:Close()
  end
  return scope
end

---Register a suite of this package whose tests all end released.
---@param part string
---@return TestKit.Suite
local function newSuite(part)
  local suite = Harness:Suite(PACKAGE_ID, part, addonName)
  suite:After(cleanUp)
  return suite
end

---Register `body` as a test when the client has `GetTimePreciseSec`, and as
---a skipped test naming why otherwise.
---@param suite TestKit.Suite
---@param name string
---@param body fun(ctx: TestKit.Context)
local function clockTest(suite, name, body)
  if CLOCK_AVAILABLE then
    suite:Test(name, body)
  else
    suite:Skip(name, "the client has no GetTimePreciseSec; the timing was not measured")
  end
end

---The client's monotonic wall clock, in seconds. Only called by tests that
---`clockTest` registered, so the clock exists.
---@return number
local function preciseNow()
  return getTimePreciseSec()
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
---@class TimerKitSuite.Wait
---@field satisfied boolean whether the predicate became truthy in time
---@field frames integer how many rendered frames the wait resumed on
---@field longestFrameSeconds number the longest gap between two resumptions

---Wait like `waitUntil`, and measure the frames the wait spanned: TestKit
---resumes the test once per rendered frame, so the gap between two calls of
---the predicate is one frame as the client rendered it.
---@param ctx TestKit.Context
---@param predicate fun(): any
---@param timeoutSeconds number
---@return TimerKitSuite.Wait
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
---@return TimerKitSuite.Wait
local function waitUntilInstant(ctx, instant)
  return measuredWait(ctx, function()
    return preciseNow() >= instant
  end, WAIT_TIMEOUT_SECONDS)
end

---The timing tolerance of a wait: one frame, the longest the wait observed
---and never shorter than the client's current frame rate says, plus
---`TIMING_MARGIN_SECONDS`.
---@param wait TimerKitSuite.Wait
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
  return frame + TIMING_MARGIN_SECONDS
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
  ctx:Expect((file or ""):sub(-#"TimerKitSuite.lua")):ToBe("TimerKitSuite.lua")
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

--- A no-op timer callback; the timers that only exist to be cancelled use it.
local function ignore() end

---A callback that counts its calls into `record.count` and keeps the clock
---reading of each call in `record.times`.
---@param record { count: integer, times: number[] }
---@return fun(timer: TimerKit.Timer)
local function counter(record)
  return function()
    record.count = record.count + 1
    record.times[record.count] = preciseNow()
  end
end

---A fresh call record for `counter`.
---@return { count: integer, times: number[] }
local function newRecord()
  return { count = 0, times = {} }
end

---Send failures the client reports to its error handler to a collector until
---the returned `restore` is called; the After hook calls it too, so a test
---that fails or times out while waiting cannot keep the collector.
---
---A timer callback runs from `C_Timer`, outside any protected call of the
---addon, and TimerKit does not catch its errors (docs/API.md, "Repeating
---callback errors"): the client reports them to the handler `seterrorhandler`
---installed. The handler is therefore swapped with `seterrorhandler`; the
---global `geterrorhandler` is only its reader, and replacing it would neither
---catch the failure nor keep the error window closed. The swap spans the
---wait for the timer, so a failure of another addon in that window reaches
---the collector too; the tests count only their own marker.
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

---The reports that are this file's deliberate callback failure.
---@param reported any[]
---@return string[]
local function ownReports(reported)
  local own = {}
  for _, message in ipairs(reported) do
    if
      type(message) == "string"
      and not (SECRETS_AVAILABLE and isSecretValue(message))
      and message:sub(-#CALLBACK_FAILURE) == CALLBACK_FAILURE
    then
      own[#own + 1] = message
    end
  end
  return own
end

--- Why the error-handler tests fail rather than pass when the swap did not hold.
local HANDLER_KEPT_MESSAGE =
  "the client's error handler could not be replaced (an error-capturing addon such as BugGrabber keeps it); the failure went to that addon"

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

---Start `NATIVE_BATCH` native one-shots of `LONG_DELAY_SECONDS` straight on
---`C_Timer`, remembered for the After hook, which cancels every one again.
---@return any[] handles
local function startNativeBatch()
  local handles = {}
  for index = 1, NATIVE_BATCH do
    handles[index] = newNativeTimer(LONG_DELAY_SECONDS, ignore)
  end
  pendingReleases[#pendingReleases + 1] = function()
    for index = 1, #handles do
      pcall(handles[index].Cancel, handles[index])
    end
  end
  return handles
end

-- timerKit.facade -----------------------------------------------------------------------

local facade = newSuite("facade")

facade:Test(
  "Registry:Get('timerKit', 1) is the TimerKit facade with API 1, and its timers and scopes carry every documented method",
  function(ctx)
    ctx:Expect(type(TimerKit)):ToBe("table")
    ctx:Expect(rawget(TimerKit, "API")):ToBe(TIMER_KIT_API)
    for _, method in ipairs(FACADE_METHODS) do
      ctx:Expect(type(TimerKit[method])):ToBe("function")
    end

    local scope = trackScope(TimerKit:CreateScope())
    local timer = scope:New({ delay = LONG_DELAY_SECONDS, callback = ignore })
    for _, method in ipairs(TIMER_METHODS) do
      ctx:Expect(type(timer[method])):ToBe("function")
    end
    for _, method in ipairs(SCOPE_METHODS) do
      ctx:Expect(type(scope[method])):ToBe("function")
    end
    ctx:Expect(timer:GetState()):ToBe("idle")
  end
)

facade:Test("the installed TimerKit carries the revision of the committed manifest", function(ctx)
  local expectedPackages = Harness:GetExpectedPackages()
  if type(expectedPackages) == "nil" then
    ctx:Fail("Expected.lua is missing; install with python3 -m tooling.client.install")
    return
  end
  for _, expected in ipairs(expectedPackages) do
    if expected.id == PACKAGE_ID then
      local _, revision = Registry:Get(PACKAGE_ID, TIMER_KIT_API)
      ctx:Expect(revision):ToBe(expected.revision)
      ctx:Expect(rawget(TimerKit, "REVISION")):ToBe(expected.revision)
      return
    end
  end
  ctx:Fail("Expected.lua does not list timerKit")
end)

-- timerKit.oneShot ----------------------------------------------------------------------

local oneShot = newSuite("oneShot")

clockTest(
  oneShot,
  "After(0.25) fires once on the real C_Timer, within one frame plus 20 ms of the deadline it recorded (lateness logged)",
  function(ctx)
    local fired = newRecord()
    local stateInside = nil
    ---@type any
    local remainingInside = "not called"
    local startedAt = preciseNow()
    local timer = trackTimer(TimerKit:After(ONE_SHOT_DELAY_SECONDS, function(self)
      fired.count = fired.count + 1
      fired.times[fired.count] = preciseNow()
      stateInside = self:GetState()
      remainingInside = self:GetRemaining()
    end))
    local deadline = timer:GetDeadline()
    ctx:Expect(type(deadline)):ToBe("number")
    ---@cast deadline number

    local wait = measuredWait(ctx, function()
      return fired.count > 0
    end, WAIT_TIMEOUT_SECONDS)
    ctx:Expect(wait.satisfied):ToBe(true)

    local lateness = fired.times[1] - deadline
    local allowance = frameAllowance(wait)
    ctx:Log(
      ("lateness %s after the recorded deadline (negative: early); %s after the call; allowance %s; longest frame %s over %d frames"):format(
        milliseconds(lateness),
        milliseconds(fired.times[1] - startedAt),
        milliseconds(allowance),
        milliseconds(wait.longestFrameSeconds),
        wait.frames
      )
    )
    ctx:Expect(lateness <= allowance):ToBe(true)
    ctx:Expect(lateness >= -allowance):ToBe(true)

    -- A one-shot is completed, and reports no remaining time, inside its callback.
    ctx:Expect(stateInside):ToBe("completed")
    ctx:Expect(remainingInside):ToBeNil()

    -- Past several more frames, it has still fired only once.
    waitUntilInstant(ctx, preciseNow() + QUIET_WAIT_SECONDS)
    ctx:Expect(fired.count):ToBe(1)
    ctx:Expect(timer:GetState()):ToBe("completed")
    ctx:Expect(timer:GetRemaining()):ToBeNil()
    ctx:Expect(timer:GetDeadline()):ToBeNil()
  end
)

clockTest(
  oneShot,
  "After(0) does not run inside the call and runs within the next two rendered frames",
  function(ctx)
    local scope = trackScope(TimerKit:CreateScope())
    local fired = newRecord()
    local startedAt = preciseNow()
    scope:After(0, counter(fired))
    ctx:Expect(fired.count):ToBe(0)

    local wait = measuredWait(ctx, function()
      return fired.count > 0
    end, WAIT_TIMEOUT_SECONDS)
    ctx:Log(
      ("ran %s after the call, on rendered frame %d of the wait"):format(
        milliseconds((fired.times[1] or startedAt) - startedAt),
        wait.frames
      )
    )
    ctx:Expect(wait.satisfied):ToBe(true)
    ctx:Expect(wait.frames <= 2):ToBe(true)
    ctx:Expect(scope:GetActiveCount()):ToBe(0)
  end
)

clockTest(
  oneShot,
  "Cancel before the deadline keeps the callback from ever running, and the timer reads cancelled with no remaining time",
  function(ctx)
    local scope = trackScope(TimerKit:CreateScope())
    local fired = newRecord()
    local timer = scope:After(ONE_SHOT_DELAY_SECONDS, counter(fired))

    ctx:Expect(timer:Cancel()):ToBe(true)
    ctx:Expect(timer:Cancel()):ToBe(false)
    ctx:Expect(timer:GetState()):ToBe("cancelled")
    ctx:Expect(timer:IsCancelled()):ToBe(true)
    ctx:Expect(timer:IsPending()):ToBe(false)
    ctx:Expect(timer:GetRemaining()):ToBeNil()
    ctx:Expect(timer:GetDeadline()):ToBeNil()
    ctx:Expect(scope:GetActiveCount()):ToBe(0)

    waitUntilInstant(ctx, preciseNow() + ONE_SHOT_DELAY_SECONDS + QUIET_WAIT_SECONDS)
    ctx:Expect(fired.count):ToBe(0)
    ctx:Expect(timer:GetState()):ToBe("cancelled")
  end
)

-- timerKit.repeating --------------------------------------------------------------------

local repeating = newSuite("repeating")

clockTest(
  repeating,
  "Every(0.1) ticks at its interval with its own handle, moves its deadline one interval per tick, and stops for good on Cancel (intervals logged)",
  function(ctx)
    local scope = trackScope(TimerKit:CreateScope())
    local ticks = newRecord()
    local handles = {}
    local deadlineLeads = {}
    local timer = scope:Every(TICK_INTERVAL_SECONDS, function(self)
      local tickedAt = preciseNow()
      ticks.count = ticks.count + 1
      ticks.times[ticks.count] = tickedAt
      handles[ticks.count] = self
      deadlineLeads[ticks.count] = (self:GetDeadline() or tickedAt) - tickedAt
    end)

    local wait = measuredWait(ctx, function()
      return ticks.count >= TICKS_TO_OBSERVE
    end, WAIT_TIMEOUT_SECONDS)
    ctx:Expect(wait.satisfied):ToBe(true)
    ctx:Expect(timer:GetState()):ToBe("running")
    ctx:Expect(timer:Cancel()):ToBe(true)
    local ticksAtCancel = ticks.count

    local allowance = frameAllowance(wait)
    local intervals = {}
    for index = 2, ticksAtCancel do
      intervals[#intervals + 1] = milliseconds(ticks.times[index] - ticks.times[index - 1])
    end
    ctx:Log(
      ("intervals between ticks: %s; allowance %s around %s"):format(
        table.concat(intervals, ", "),
        milliseconds(allowance),
        milliseconds(TICK_INTERVAL_SECONDS)
      )
    )
    for index = 2, ticksAtCancel do
      local interval = ticks.times[index] - ticks.times[index - 1]
      ctx:Expect(math.abs(interval - TICK_INTERVAL_SECONDS) <= allowance):ToBe(true)
    end
    for index = 1, ticksAtCancel do
      ctx:Expect(handles[index]):ToBe(timer)
      -- Inside a tick the deadline is already one interval ahead.
      ctx:Expect(deadlineLeads[index] <= TICK_INTERVAL_SECONDS + CLOCK_EPSILON_SECONDS):ToBe(true)
      ctx
        :Expect(deadlineLeads[index] >= TICK_INTERVAL_SECONDS - TICK_DEADLINE_EPSILON_SECONDS)
        :ToBe(true)
    end

    waitUntilInstant(ctx, preciseNow() + QUIET_WAIT_SECONDS)
    ctx:Log(("ticks after Cancel: %d"):format(ticks.count - ticksAtCancel))
    ctx:Expect(ticks.count):ToBe(ticksAtCancel)
    ctx:Expect(timer:GetState()):ToBe("cancelled")
    ctx:Expect(scope:GetActiveCount()):ToBe(0)
  end
)

clockTest(
  repeating,
  "a ticker that cancels itself inside its second tick never ticks a third time",
  function(ctx)
    local scope = trackScope(TimerKit:CreateScope())
    local ticks = newRecord()
    local cancelAnswer = nil
    scope:Every(TICK_INTERVAL_SECONDS, function(self)
      ticks.count = ticks.count + 1
      if ticks.count == 2 then
        cancelAnswer = self:Cancel()
      end
    end)

    local reached = waitUntil(ctx, function()
      return ticks.count >= 2
    end, WAIT_TIMEOUT_SECONDS)
    ctx:Expect(reached):ToBe(true)
    waitUntilInstant(ctx, preciseNow() + QUIET_WAIT_SECONDS)
    ctx:Expect(cancelAnswer):ToBe(true)
    ctx:Expect(ticks.count):ToBe(2)
    ctx:Expect(scope:GetActiveCount()):ToBe(0)
  end
)

-- timerKit.remaining --------------------------------------------------------------------

local remaining = newSuite("remaining")

clockTest(
  remaining,
  "GetDeadline is GetTimePreciseSec at Start plus the delay, and GetRemaining counts down against that clock while running",
  function(ctx)
    local scope = trackScope(TimerKit:CreateScope())
    local timer = scope:New({ delay = 1, callback = ignore })
    ctx:Expect(timer:GetRemaining()):ToBeNil()
    ctx:Expect(timer:GetDeadline()):ToBeNil()

    local before = preciseNow()
    timer:Start()
    local after = preciseNow()
    local deadline = timer:GetDeadline()
    ctx:Expect(type(deadline)):ToBe("number")
    ---@cast deadline number
    ctx:Log(("deadline %s after the reading before Start"):format(milliseconds(deadline - before)))
    ctx:Expect(deadline >= before + 1 - CLOCK_EPSILON_SECONDS):ToBe(true)
    ctx:Expect(deadline <= after + 1 + CLOCK_EPSILON_SECONDS):ToBe(true)

    waitUntilInstant(ctx, before + 0.3)
    local readBefore = preciseNow()
    local left = timer:GetRemaining()
    local readAfter = preciseNow()
    ctx:Expect(type(left)):ToBe("number")
    ---@cast left number
    ctx:Log(("remaining after about 0.3 s: %s"):format(milliseconds(left)))
    ctx:Expect(left <= deadline - readBefore + CLOCK_EPSILON_SECONDS):ToBe(true)
    ctx:Expect(left >= deadline - readAfter - CLOCK_EPSILON_SECONDS):ToBe(true)
    ctx:Expect(left < 0.7 + CLOCK_EPSILON_SECONDS):ToBe(true)
    ctx:Expect(timer:GetDeadline()):ToBe(deadline)

    timer:Cancel()
    ctx:Expect(timer:GetRemaining()):ToBeNil()
    ctx:Expect(timer:GetDeadline()):ToBeNil()
  end
)

clockTest(
  remaining,
  "GetRemaining polled on every frame until the callback never goes negative, and is nil once the one-shot completed",
  function(ctx)
    local scope = trackScope(TimerKit:CreateScope())
    local fired = newRecord()
    local timer = scope:After(ONE_SHOT_DELAY_SECONDS, counter(fired))
    local smallest = math.huge
    local zeroReadings = 0

    local wait = measuredWait(ctx, function()
      if fired.count > 0 then
        return true
      end
      local left = timer:GetRemaining()
      if type(left) == "number" then
        smallest = math.min(smallest, left)
        if left == 0 then
          zeroReadings = zeroReadings + 1
        end
      end
      return false
    end, WAIT_TIMEOUT_SECONDS)

    ctx:Log(
      ("smallest reading %s over %d frames; %d reading(s) of 0 while the host was late"):format(
        milliseconds(smallest),
        wait.frames,
        zeroReadings
      )
    )
    ctx:Expect(wait.satisfied):ToBe(true)
    ctx:Expect(smallest >= 0):ToBe(true)
    ctx:Expect(timer:GetState()):ToBe("completed")
    ctx:Expect(timer:GetRemaining()):ToBeNil()
    ctx:Expect(timer:GetDeadline()):ToBeNil()
  end
)

-- timerKit.scopes -----------------------------------------------------------------------

local scopes = newSuite("scopes")

clockTest(
  scopes,
  "CancelAll stops a scope's running one-shot and ticker on the real C_Timer, and the scope still runs new timers",
  function(ctx)
    local scope = trackScope(TimerKit:CreateScope())
    local fired = newRecord()
    scope:After(ONE_SHOT_DELAY_SECONDS, counter(fired))
    scope:Every(TICK_INTERVAL_SECONDS, counter(fired))
    scope:New({ delay = TICK_INTERVAL_SECONDS, callback = counter(fired) })
    ctx:Expect(scope:GetActiveCount()):ToBe(2)

    ctx:Expect(scope:CancelAll()):ToBe(2)
    ctx:Expect(scope:GetActiveCount()):ToBe(0)
    ctx:Expect(scope:IsClosed()):ToBe(false)
    waitUntilInstant(ctx, preciseNow() + ONE_SHOT_DELAY_SECONDS + QUIET_WAIT_SECONDS)
    ctx:Expect(fired.count):ToBe(0)

    local again = newRecord()
    scope:After(TICK_INTERVAL_SECONDS, counter(again))
    local reached = waitUntil(ctx, function()
      return again.count > 0
    end, WAIT_TIMEOUT_SECONDS)
    ctx:Expect(reached):ToBe(true)
  end
)

clockTest(
  scopes,
  "Close cancels every running timer of the scope, none fires afterwards, and the closed scope refuses After at the calling line",
  function(ctx)
    local scope = trackScope(TimerKit:CreateScope())
    local fired = newRecord()
    scope:After(ONE_SHOT_DELAY_SECONDS, counter(fired))
    scope:Every(TICK_INTERVAL_SECONDS, counter(fired))

    ctx:Expect(scope:Close()):ToBe(true)
    ctx:Expect(scope:Close()):ToBe(false)
    ctx:Expect(scope:IsClosed()):ToBe(true)
    ctx:Expect(scope:GetActiveCount()):ToBe(0)
    waitUntilInstant(ctx, preciseNow() + ONE_SHOT_DELAY_SECONDS + QUIET_WAIT_SECONDS)
    ctx:Expect(fired.count):ToBe(0)

    local startLine = 0

    local line = expectErrorAtCallingLine(ctx, function()
      startLine = currentLine()
      scope:After(TICK_INTERVAL_SECONDS, ignore)
    end, "TimerKit.Scope:After cannot create a timer in a closed scope")
    ctx:Expect(line):ToBe(startLine + 1)
  end
)

clockTest(
  scopes,
  "ForAddon with this test addon's name returns one open scope naming the addon, and its timers fire",
  function(ctx)
    local scope = TimerKit:ForAddon(addonName)
    ctx:Expect(TimerKit:ForAddon(addonName)):ToBe(scope)
    ctx:Expect(scope:GetAddonName()):ToBe(addonName)
    ctx:Expect(scope:IsClosed()):ToBe(false)

    -- Which logout route TimerKit took; docs/API.md, "At logout".
    ---@type LifecycleKit|nil
    local LifecycleKit = Registry:Get("lifecycleKit", LIFECYCLE_KIT_API)
    local closesTimers = false
    if type(LifecycleKit) ~= "nil" then
      local capabilities = LifecycleKit.CLOSES_ADDON_SCOPES
      closesTimers = type(capabilities) == "table" and capabilities[PACKAGE_ID] == true
    end
    ctx:Log(
      "LifecycleKit loaded: "
        .. tostring(type(LifecycleKit) ~= "nil")
        .. "; it lists timerKit in CLOSES_ADDON_SCOPES: "
        .. tostring(closesTimers)
    )

    local fired = newRecord()
    trackTimer(scope:After(TICK_INTERVAL_SECONDS, counter(fired)))
    ctx:Expect(scope:GetActiveCount() >= 1):ToBe(true)
    local reached = waitUntil(ctx, function()
      return fired.count > 0
    end, WAIT_TIMEOUT_SECONDS)
    ctx:Expect(reached):ToBe(true)
    ctx:Expect(fired.count):ToBe(1)
  end
)

clockTest(
  scopes,
  "CloseAddonScopes stops a probe addon's ticker before its next tick, answers true then false, and ForAddon keeps the closed scope",
  function(ctx)
    probeSequence = probeSequence + 1
    local probeName = PROBE_ADDON_PREFIX .. probeSequence
    ctx:Expect(TimerKit:CloseAddonScopes(probeName)):ToBe(false)

    local scope = TimerKit:ForAddon(probeName)
    local ticks = newRecord()
    scope:Every(TICK_INTERVAL_SECONDS, counter(ticks))
    local reached = waitUntil(ctx, function()
      return ticks.count >= 1
    end, WAIT_TIMEOUT_SECONDS)
    ctx:Expect(reached):ToBe(true)

    ctx:Expect(TimerKit:CloseAddonScopes(probeName)):ToBe(true)
    local ticksAtClose = ticks.count
    ctx:Expect(TimerKit:CloseAddonScopes(probeName)):ToBe(false)
    ctx:Expect(scope:IsClosed()):ToBe(true)
    ctx:Expect(scope:GetActiveCount()):ToBe(0)
    ctx:Expect(TimerKit:ForAddon(probeName)):ToBe(scope)

    waitUntilInstant(ctx, preciseNow() + QUIET_WAIT_SECONDS)
    ctx:Log(("probe %s: ticks after the close: %d"):format(probeName, ticks.count - ticksAtClose))
    ctx:Expect(ticks.count):ToBe(ticksAtClose)
  end
)

scopes:Skip(
  "at logout this addon's scope is closed and its timers cancelled",
  "not observable in a run: PLAYER_LOGOUT ends the session before a result could be printed or saved; packages/timerKit/tests/LogoutCoverage_spec.lua proves it"
)

-- timerKit.callbackErrors ---------------------------------------------------------------

local callbackErrors = newSuite("callbackErrors")

clockTest(
  callbackErrors,
  "a one-shot callback error reaches the client's error handler once, naming TimerKitSuite.lua at the raising line",
  function(ctx)
    local scope = trackScope(TimerKit:CreateScope())
    local failingLine = 0
    local reported, observed, restoreHandler = collectReportedErrors()
    local timer = scope:After(TICK_INTERVAL_SECONDS, function()
      failingLine = currentLine()
      error(CALLBACK_FAILURE)
    end)
    waitUntil(ctx, function()
      return #ownReports(reported) > 0 or timer:GetState() ~= "running"
    end, WAIT_TIMEOUT_SECONDS)
    -- A few more frames, so a second report would have arrived.
    waitUntilInstant(ctx, preciseNow() + TICK_INTERVAL_SECONDS)
    restoreHandler()

    ctx:Expect(timer:GetState()):ToBe("completed")
    if not observed then
      ctx:Fail(HANDLER_KEPT_MESSAGE)
      return
    end
    local own = ownReports(reported)
    ctx:Log(("the collector received %d report(s), %d of them this test's"):format(#reported, #own))
    ctx:Expect(#own):ToBe(1)
    ctx:Log("reported: " .. tostring(own[1]))
    local line = expectThisFile(ctx, own[1])
    ctx:Expect(line):ToBe(failingLine + 1)
  end
)

clockTest(
  callbackErrors,
  "a repeating timer whose callback raised keeps ticking and stays running, as docs/API.md documents (ticks after the error logged)",
  function(ctx)
    local scope = trackScope(TimerKit:CreateScope())
    local ticks = newRecord()
    local reported, observed, restoreHandler = collectReportedErrors()
    local timer = scope:Every(TICK_INTERVAL_SECONDS, function()
      ticks.count = ticks.count + 1
      ticks.times[ticks.count] = preciseNow()
      if ticks.count == 1 then
        error(CALLBACK_FAILURE)
      end
    end)

    local raised = waitUntil(ctx, function()
      return ticks.count >= 1
    end, WAIT_TIMEOUT_SECONDS)
    -- Five intervals: a live ticker ticks about five more times.
    waitUntilInstant(ctx, preciseNow() + 5 * TICK_INTERVAL_SECONDS)
    local ticksAfterError = math.max(ticks.count - 1, 0)
    local stateAfter = timer:GetState()
    local remainingAfter = timer:GetRemaining()
    timer:Cancel()
    restoreHandler()

    ctx:Log(
      ("ticks within %s after the raising tick: %d; state %s; GetRemaining %s"):format(
        milliseconds(5 * TICK_INTERVAL_SECONDS),
        ticksAfterError,
        tostring(stateAfter),
        tostring(remainingAfter)
      )
    )
    if ticksAfterError == 0 then
      ctx:Log(
        "the client stopped the native ticker after its callback raised, while TimerKit still reports it running"
      )
    end
    ctx:Expect(raised):ToBe(true)
    if not observed then
      ctx:Fail(HANDLER_KEPT_MESSAGE)
      return
    end
    ctx:Expect(#ownReports(reported)):ToBe(1)
    ctx:Expect(stateAfter):ToBe("running")
    ctx:Expect(ticksAfterError >= 2):ToBe(true)
  end
)

-- timerKit.allocation -------------------------------------------------------------------

local allocation = newSuite("allocation")

allocation:Test(
  "getters, GetRemaining, GetDeadline and SetUserData on a running timer allocate nothing over 10000 calls each (allocation guard)",
  function(ctx)
    local scope = trackScope(TimerKit:CreateScope())
    local timer = scope:After(LONG_DELAY_SECONDS, ignore)
    local userData = {}
    collectBeforeMeasuring(ctx)

    local grownKilobytes = measureAllocation(function()
      for _ = 1, GETTER_CALLS do
        timer:GetState()
        timer:GetDelay()
        timer:GetScope()
        timer:SetUserData(userData)
        timer:GetUserData()
        timer:IsRepeating()
        timer:IsPending()
        timer:IsCancelled()
        timer:GetRemaining()
        timer:GetDeadline()
        scope:GetActiveCount()
      end
    end)

    ctx:Log(
      ("memory delta over %d rounds of 11 calls: %.3f KB"):format(GETTER_CALLS, grownKilobytes)
    )
    ctx:Expect(grownKilobytes <= ALLOCATION_TOLERANCE_KB):ToBe(true)
    ctx:Expect(timer:GetUserData()):ToBe(userData)
  end
)

if NATIVE_TIMER_AVAILABLE then
  allocation:Test(
    "Cancel of 200 running timers allocates nothing beyond the client's own C_Timer Cancel of 200 handles (allocation guard)",
    function(ctx)
      local scope = trackScope(TimerKit:CreateScope())
      local timers = {}
      for index = 1, NATIVE_BATCH do
        timers[index] = scope:After(LONG_DELAY_SECONDS, ignore)
      end
      local handles = startNativeBatch()

      collectBeforeMeasuring(ctx)
      local nativeKilobytes = measureAllocation(function()
        for index = 1, NATIVE_BATCH do
          handles[index]:Cancel()
        end
      end)
      collectBeforeMeasuring(ctx)
      local kitKilobytes = measureAllocation(function()
        for index = 1, NATIVE_BATCH do
          timers[index]:Cancel()
        end
      end)

      ctx:Log(
        ("C_Timer Cancel x%d: %.3f KB; TimerKit Cancel x%d: %.3f KB"):format(
          NATIVE_BATCH,
          nativeKilobytes,
          NATIVE_BATCH,
          kitKilobytes
        )
      )
      ctx:Expect(kitKilobytes <= nativeKilobytes + ALLOCATION_TOLERANCE_KB):ToBe(true)
      ctx:Expect(scope:GetActiveCount()):ToBe(0)
    end
  )

  allocation:Test(
    "Start allocates at most its one callback closure beyond the client's own C_Timer.NewTimer, over 200 start-cancel pairs (per-start cost logged)",
    function(ctx)
      local scope = trackScope(TimerKit:CreateScope())
      local timer = scope:New({ delay = LONG_DELAY_SECONDS, callback = ignore })
      -- Warm both paths once, so the measurements see steady state only.
      timer:Start()
      timer:Cancel()
      newNativeTimer(LONG_DELAY_SECONDS, ignore):Cancel()

      collectBeforeMeasuring(ctx)
      local nativeKilobytes = measureAllocation(function()
        for _ = 1, NATIVE_BATCH do
          newNativeTimer(LONG_DELAY_SECONDS, ignore):Cancel()
        end
      end)
      collectBeforeMeasuring(ctx)
      local kitKilobytes = measureAllocation(function()
        for _ = 1, NATIVE_BATCH do
          timer:Start()
          timer:Cancel()
        end
      end)

      local extraBytesPerStart = (kitKilobytes - nativeKilobytes) * 1024 / NATIVE_BATCH
      ctx:Log(
        ("C_Timer NewTimer+Cancel x%d: %.3f KB; TimerKit Start+Cancel x%d: %.3f KB; %.1f bytes per start beyond the client's (budget %d)"):format(
          NATIVE_BATCH,
          nativeKilobytes,
          NATIVE_BATCH,
          kitKilobytes,
          extraBytesPerStart,
          START_BUDGET_BYTES
        )
      )
      ctx:Expect(extraBytesPerStart <= START_BUDGET_BYTES):ToBe(true)
      ctx:Expect(timer:GetState()):ToBe("cancelled")
    end
  )
else
  local reason = "the client has no C_Timer.NewTimer to measure against"
  allocation:Skip(
    "Cancel of 200 running timers allocates nothing beyond the client's own C_Timer Cancel of 200 handles (allocation guard)",
    reason
  )
  allocation:Skip(
    "Start allocates at most its one callback closure beyond the client's own C_Timer.NewTimer, over 200 start-cancel pairs (per-start cost logged)",
    reason
  )
end

allocation:Skip(
  "a delivered tick allocates nothing (allocation guard)",
  "not measurable here: C_Timer delivers a tick between frames, where every other addon allocates too; packages/timerKit/tests/Allocation_spec.lua guards it"
)

-- timerKit.errors -----------------------------------------------------------------------

local errors = newSuite("errors")

--- The facade without its LuaCATS type, so a test can pass the wrong
--- arguments the documented refusals are about.
---@type any
local untypedTimerKit = TimerKit

errors:Test(
  "After with a callback that is not a function names TimerKitSuite.lua at the calling line",
  function(ctx)
    local startLine = 0
    local line = expectErrorAtCallingLine(ctx, function()
      startLine = currentLine()
      untypedTimerKit:After(1, "not a function")
    end, "TimerKit:After callback must be a function")
    ctx:Expect(line):ToBe(startLine + 1)
  end
)

errors:Test(
  "negative, NaN and infinite delays and a zero repeating interval are refused at the calling line with their documented messages",
  function(ctx)
    local scope = trackScope(TimerKit:CreateScope())
    local cases = {
      {
        method = "After",
        delay = -1,
        expected = "TimerKit.Scope:After delay must be zero or greater",
      },
      {
        method = "After",
        delay = 0 / 0,
        expected = "TimerKit.Scope:After delay must be a finite number",
      },
      {
        method = "Every",
        delay = math.huge,
        expected = "TimerKit.Scope:Every delay must be a finite number",
      },
      {
        method = "Every",
        delay = 0,
        expected = "TimerKit.Scope:Every delay must be greater than zero for repeating timers",
      },
    }
    for _, case in ipairs(cases) do
      local startLine = 0
      local line = expectErrorAtCallingLine(ctx, function()
        startLine = currentLine()
        scope[case.method](scope, case.delay, ignore)
      end, case.expected)
      ctx:Expect(line):ToBe(startLine + 1)
    end
    ctx:Expect(scope:GetActiveCount()):ToBe(0)
  end
)

errors:Test(
  "New with unknown option fields names the alphabetically first one at the calling line",
  function(ctx)
    local startLine = 0
    local line = expectErrorAtCallingLine(ctx, function()
      startLine = currentLine()
      untypedTimerKit:New({ delay = 1, callback = ignore, zeta = 1, alpha = 2 })
    end, 'TimerKit:New options contains unknown field "alpha"')
    ctx:Expect(line):ToBe(startLine + 1)
  end
)

errors:Test(
  "a timer method called on a scope and a scope method called on a timer are refused at the calling line",
  function(ctx)
    local scope = trackScope(TimerKit:CreateScope())
    ---@type any
    local timer = scope:New({ delay = 1, callback = ignore })
    ---@type any
    local untypedScope = scope

    local startLine = 0

    local line = expectErrorAtCallingLine(ctx, function()
      startLine = currentLine()
      timer.Cancel(untypedScope)
    end, "TimerKit.Timer:Cancel must be called on a TimerKit timer")
    ctx:Expect(line):ToBe(startLine + 1)

    line = expectErrorAtCallingLine(ctx, function()
      startLine = currentLine()
      untypedScope.CancelAll(timer)
    end, "TimerKit.Scope:CancelAll must be called on a TimerKit scope")
    ctx:Expect(line):ToBe(startLine + 1)
  end
)

errors:Test(
  "ForAddon with an empty name and CloseAddonScopes on another receiver are refused at the calling line",
  function(ctx)
    local startLine = 0
    local line = expectErrorAtCallingLine(ctx, function()
      startLine = currentLine()
      TimerKit:ForAddon("")
    end, "TimerKit:ForAddon addonName must be a non-empty string")
    ctx:Expect(line):ToBe(startLine + 1)

    line = expectErrorAtCallingLine(
      ctx,
      function()
        startLine = currentLine()
        untypedTimerKit.CloseAddonScopes({}, addonName)
      end,
      "TimerKit:CloseAddonScopes must be called on the TimerKit facade; use TimerKit:CloseAddonScopes(addonName)"
    )
    ctx:Expect(line):ToBe(startLine + 1)
    ctx:Expect(TimerKit:ForAddon(addonName):IsClosed()):ToBe(false)
  end
)

-- timerKit.secrets ----------------------------------------------------------------------

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
  "After and Every refuse a secret delay at the calling line before comparing it, and start nothing",
  function(ctx)
    local scope = trackScope(TimerKit:CreateScope())
    local secretDelay = makeSecret(ctx, 0.5)

    local startLine = 0

    local line = expectErrorAtCallingLine(ctx, function()
      startLine = currentLine()
      TimerKit:After(secretDelay, ignore)
    end, "TimerKit:After delay must not be a secret value")
    ctx:Expect(line):ToBe(startLine + 1)

    line = expectErrorAtCallingLine(ctx, function()
      startLine = currentLine()
      scope:Every(secretDelay, ignore)
    end, "TimerKit.Scope:Every delay must not be a secret value")
    ctx:Expect(line):ToBe(startLine + 1)
    ctx:Expect(scope:GetActiveCount()):ToBe(0)
  end
)

secretTest(
  "New refuses a secret delay and a secret repeating flag at the calling line",
  function(ctx)
    local secretDelay = makeSecret(ctx, 0.5)
    local secretFlag = makeSecret(ctx, true)

    local startLine = 0

    local line = expectErrorAtCallingLine(ctx, function()
      startLine = currentLine()
      TimerKit:New({ delay = secretDelay, callback = ignore })
    end, "TimerKit:New delay must not be a secret value")
    ctx:Expect(line):ToBe(startLine + 1)

    line = expectErrorAtCallingLine(ctx, function()
      startLine = currentLine()
      TimerKit:New({ delay = 1, callback = ignore, repeating = secretFlag })
    end, "TimerKit:New repeating must not be a secret value")
    ctx:Expect(line):ToBe(startLine + 1)
  end
)

secretTest(
  "ForAddon and CloseAddonScopes refuse a secret addon name at the calling line",
  function(ctx)
    local secretName = makeSecret(ctx, addonName)

    local startLine = 0

    local line = expectErrorAtCallingLine(ctx, function()
      startLine = currentLine()
      TimerKit:ForAddon(secretName)
    end, "TimerKit:ForAddon addonName must not be a secret value")
    ctx:Expect(line):ToBe(startLine + 1)

    line = expectErrorAtCallingLine(ctx, function()
      startLine = currentLine()
      TimerKit:CloseAddonScopes(secretName)
    end, "TimerKit:CloseAddonScopes addonName must not be a secret value")
    ctx:Expect(line):ToBe(startLine + 1)
    ctx:Expect(TimerKit:ForAddon(addonName):IsClosed()):ToBe(false)
  end
)

secretTest(
  "SetUserData stores a secret value and GetUserData hands it back still secret",
  function(ctx)
    local scope = trackScope(TimerKit:CreateScope())
    local timer = scope:New({ delay = 1, callback = ignore })
    local secret = makeSecret(ctx, 42)

    ctx:Expect(timer:SetUserData(secret)):ToBe(timer)
    ctx:Expect(isSecretValue(timer:GetUserData())):ToBe(true)
    timer:SetUserData(nil)
    ctx:Expect(timer:GetUserData()):ToBeNil()
  end
)
