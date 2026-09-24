-- MoltenCodes Test: ReadinessKitSuite.lua
--
-- Real-client suites for the `readinessKit` package. The Busted specs under
-- packages/readinessKit/tests/ prove ReadinessKit against a fake clock, a fake
-- `C_Timer` whose ticks a spec fires by hand and a scripted EventKit host;
-- these prove, inside the game client with the installed MoltenCodes addon,
-- what that fixture can only simulate:
--
--   * the installed facade and its committed revision, and the two optional
--     host facilities it uses: `GetTimePreciseSec` and EventKit API 1;
--   * gates over real host data that arrives after load: item information the
--     client has not cached (`C_Item.GetItemInfo`, made ready by the
--     GET_ITEM_INFO_RECEIVED the server's answer raises), spell data
--     (`C_Spell.IsSpellDataCached`, made ready by SPELL_DATA_LOAD_RESULT), and
--     spell information the client always has (ready at definition, never
--     probed again);
--   * polling on real TimerKit timers: a probe that turns true on a real
--     one-shot is seen on the next poll, polls arrive at the interval, `Close`
--     stops them and `Invalidate` resumes them;
--   * timeouts measured on the client's own clock, and a new round with a
--     fresh timeout after `Probe`;
--   * the negative cache on `GetTimePreciseSec`: a burst of `Probe` calls runs
--     the probe once, and the first call after the interval runs it again;
--   * `ReprobeOn` with a real event: CVAR_UPDATE, which the client raises
--     inside `C_CVar.SetCVar("chatBubbles", ...)`, makes a gate ready before
--     `SetCVar` returns, restarts a timed-out gate, is ignored by a ready gate
--     and stops reaching a closed one; an event the client does not know is
--     refused;
--   * bounded waiters and `WhenAll` over gates made ready by the host;
--   * a probe that raises, and a queued callback that raises, reported to the
--     handler `seterrorhandler` installed, naming this file at the raising line;
--   * that the documented allocation-free calls allocate nothing on the
--     client's own collector;
--   * argument errors and secret refusals pointing at this file as the client
--     names it, and what the client does with a probe that answers a secret.
--
-- Nothing here needs combat, a group or an instance. The only client state a
-- test changes is the `chatBubbles` CVar, put back by the After hook after
-- every gate of the test is closed; the item and spell tests only ask the
-- client to load data it shows in any tooltip. Every wait is short: a normal
-- run finishes within about ten seconds.
--
-- Run with `/mct run readinessKit`;
-- tests/client/MoltenCodesTest_ReadinessKit/EXPECTED.md lists what the chat
-- frame should show.
--
-- What a run leaves behind. Every gate a test defines is closed by the After
-- hook of its suite, whatever the test's outcome, which also cancels its poll
-- timer, calls its queued waiters with `"closed"` and closes its private
-- EventKit scope; every TimerKit timer and EventKit connection a test creates
-- is cancelled or disconnected, the client's error handler is put back, and
-- then the `chatBubbles` CVar is restored. Three things stay in the session
-- until `/reload`: ReadinessKit's own TimerKit scope (created with the first
-- poll timer, empty once every gate is closed), the Frames EventKit created
-- for the events the tests connected (the client never frees a Frame), and
-- the item and spell data the client loaded, which it keeps cached. Nothing is
-- written to a global or a saved variable.

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
local READINESS_KIT_API = 1
local TIMER_KIT_API = 1
local EVENT_KIT_API = 1
local PACKAGE_ID = "readinessKit"

--- Every gate a test defines is named with this prefix, a label and a
--- sequence number, so no test meets a gate of another test or another run.
local GATE_NAME_PREFIX = "MoltenCodesTest_ReadinessKit"

--- The polling interval of the tests that watch polls arrive.
local POLL_INTERVAL_SECONDS = 0.1

--- The timeout of the timeout tests: three polls long.
local SHORT_TIMEOUT_SECONDS = 0.3

--- The interval of a gate that only a host event may make ready. Longer than
--- any wait for that event, so readiness within the wait cannot be a poll.
local EVENT_GATE_INTERVAL_SECONDS = 5

--- The interval of a gate that must never poll while a test measures it.
local QUIET_INTERVAL_SECONDS = 60

--- The interval of the negative-cache test. The test spins on the clock for
--- one interval inside a single step, so it stays short.
local CACHE_INTERVAL_SECONDS = 0.05

--- When the real one-shot of the switch tests turns their probe true.
local SWITCH_DELAY_SECONDS = 0.3

--- How long a test waits for data the server sends (GET_ITEM_INFO_RECEIVED).
local SERVER_WAIT_SECONDS = 4

--- How long a test waits for something the client does locally, or for a poll.
local LOCAL_WAIT_SECONDS = 2

--- How long a test watches for something that must not happen: several
--- intervals, so a poll that was not stopped would have run by then.
local QUIET_WAIT_SECONDS = 0.35

--- The documented timing tolerance on top of one frame. `C_Timer` delivers on
--- a frame, so a poll can arrive up to one frame after its deadline; the
--- margin absorbs the client's own work in that frame.
local TIMING_MARGIN_SECONDS = 0.02

--- The most clock reads the negative-cache test spins through while it waits
--- one interval inside a step. A client reads its clock millions of times in
--- 50 ms; the bound only keeps a clock that stands still from hanging the game.
local MAX_CLOCK_SPINS = 50000000

--- How many Probe calls the negative-cache burst makes.
local PROBE_BURST = 100

--- How many rounds each allocation guard runs.
local ALLOCATION_ROUNDS = 10000

--- Kilobytes an allocation guard tolerates. The tolerance absorbs a stray
--- allocation by the client between the two readings, not a per-call one.
local ALLOCATION_TOLERANCE_KB = 1

--- The bound the waiter test gives its gate.
local SMALL_MAX_WAITERS = 3

--- Text a deliberately failing probe raises, so a test can recognise it.
local PROBE_FAILURE = "mctReadinessKit deliberate probe failure"

--- Text a deliberately failing callback raises, so a test can recognise it.
local CALLBACK_FAILURE = "mctReadinessKit deliberate callback failure"

--- The CVar the tests change so the client raises CVAR_UPDATE. It is cosmetic
--- (whether chat bubbles are drawn), always present on Retail, not read-only
--- and not secure, so `C_CVar.SetCVar` accepts it from addon code; every
--- change is put back by the After hook.
local PROBE_CVAR = "chatBubbles"

--- The event the client raises inside `C_CVar.SetCVar`: `(cvarName, value)`.
local CVAR_EVENT = "CVAR_UPDATE"

--- The event the server's item answer raises: `(itemID, success)`.
local ITEM_EVENT = "GET_ITEM_INFO_RECEIVED"

--- The event a spell data load raises: `(spellID, success)`.
local SPELL_EVENT = "SPELL_DATA_LOAD_RESULT"

--- An event name no client knows.
local UNKNOWN_EVENT = "MOLTENCODES_TEST_NO_SUCH_EVENT"

--- Auto Attack: a spell every character knows, whose information the client
--- always has.
local AUTO_ATTACK_SPELL_ID = 6603

--- Items every Retail client knows by ID but few characters have seen this
--- session: legendary weapons of past expansions. The item test uses the
--- first one the client has not cached, so it waits for the server; the item
--- stays cached afterwards, which is why there are several.
local ITEM_CANDIDATES = { 19019, 17182, 22691, 32837, 34334, 49623, 71086, 77949 }

--- Spells every Retail client knows by ID. The spell test uses the first one
--- whose data the client has not loaded this session.
local SPELL_CANDIDATES = { 118, 133, 116, 5176, 585, 172, 686, 403, 348, 1464, 2061, 19750 }

--- Every method docs/API.md of readinessKit lists on the facade.
local FACADE_METHODS = { "Gate", "Get", "WhenAll" }

--- Every method docs/API.md of readinessKit lists on a gate.
local GATE_METHODS = {
    "IsReady",
    "Await",
    "Probe",
    "Invalidate",
    "ReprobeOn",
    "Close",
    "IsClosed",
    "GetProbeErrorCount",
}

--- Every method docs/API.md of readinessKit lists on a waiter.
local WAITER_METHODS = { "Cancel", "IsPending" }

-- Resolving the client and the framework ---------------------------------------------

---Read a client global, or `nil`.
---@param name string
---@return any
local function readHost(name)
    -- The clock, the frame rate, CVars, item and spell data, error handling
    -- and the secret-value functions are World of Warcraft client globals,
    -- reachable only through the global table.
    -- selene: allow(global_usage)
    return rawget(_G, name)
end

---Read a function from a client namespace table such as `C_Item`, or `nil`.
---@param namespaceName string
---@param functionName string
---@return function|nil
local function readHostFunction(namespaceName, functionName)
    local hostNamespace = readHost(namespaceName)
    if type(hostNamespace) ~= "table" then
        return nil
    end
    local candidate = hostNamespace[functionName]
    if type(candidate) ~= "function" then
        return nil
    end
    return candidate
end

---@type Registry
local Registry = rawget(rawget(namespace, "Registries") or {}, REGISTRY_API)
if type(Registry) ~= "table" then
    error(addonName .. " requires the MoltenCodes addon (Registry API 2); reinstall it", 0)
end

-- ReadinessKit is not in the language-server workspace of tests/client (its
-- .luarc.json lists TestKit's dependency closure only), so its facade, gates
-- and waiters are typed `any` here.

---@type any
local ReadinessKit = Registry:Get(PACKAGE_ID, READINESS_KIT_API)
if type(ReadinessKit) == "nil" then
    error(addonName .. " requires ReadinessKit API 1 in the MoltenCodes addon; reinstall it", 0)
end

---@type TimerKit|nil
local TimerKitOrNil = Registry:Get("timerKit", TIMER_KIT_API)
if type(TimerKitOrNil) == "nil" then
    error(addonName .. " requires TimerKit API 1 in the MoltenCodes addon; reinstall it", 0)
end
---@cast TimerKitOrNil TimerKit
local TimerKit = TimerKitOrNil

--- EventKit is optional for ReadinessKit; the tests that re-probe on an event
--- are registered as skipped without it. Typed `any` like ReadinessKit, since
--- only `Connect` and a connection's `Disconnect` are used.
---@type any
local EventKit = Registry:Get("eventKit", EVENT_KIT_API)
local EVENT_KIT_AVAILABLE = type(EventKit) ~= "nil"

--- The clock ReadinessKit's timeouts and negative cache read. Every timing
--- test measures against the same one, so the addon refuses to load without it.
local getTimePreciseSec = readHost("GetTimePreciseSec")
if type(getTimePreciseSec) ~= "function" then
    error(addonName .. " requires the client's GetTimePreciseSec", 0)
end

--- Read once at load: the secrets suite registers its tests as skipped when
--- the client cannot make a secret value.
local isSecretValue = readHost("issecretvalue")
local secretWrap = readHost("secretwrap")
local SECRETS_AVAILABLE = type(isSecretValue) == "function" and type(secretWrap) == "function"

---Whether `value` is a secret. `false` on a client without `issecretvalue`.
---@param value any
---@return boolean
local function isSecret(value)
    return SECRETS_AVAILABLE and isSecretValue(value) == true
end

---The client's clock, in seconds.
---@return number
local function preciseNow()
    return getTimePreciseSec()
end

---Seconds as milliseconds with two decimals, for a log line.
---@param seconds number
---@return string
local function milliseconds(seconds)
    return ("%.2f ms"):format(seconds * 1000)
end

---Describe a value the client returned for a log line, without comparing it:
---a secret is named, not converted.
---@param value any
---@return string
local function describe(value)
    if isSecret(value) then
        return "<secret " .. type(value) .. ">"
    end
    return type(value) .. " " .. tostring(value)
end

-- Releasing what a test created -----------------------------------------------------------

--- Release actions of the test that is running (close a gate, cancel a timer,
--- disconnect a listener, put the error handler back), run newest first by
--- the After hook of every suite.
---@type (fun())[]
local pendingReleases = {}

--- Client settings to put back, run by the After hook after every release, so
--- no gate of the test is still open to re-probe when the setting changes.
---@type (fun())[]
local pendingRestores = {}

--- Sequence of the gate names the tests define.
local gateSequence = 0

---Run and empty `actions`, newest first. Every action runs even when an
---earlier one raised; the first problem is returned.
---@param actions (fun())[]
---@return any firstProblem
local function runAll(actions)
    local firstProblem = nil
    for index = #actions, 1, -1 do
        local action = actions[index]
        actions[index] = nil
        local succeeded, problem = pcall(action)
        if not succeeded and type(firstProblem) == "nil" then
            firstProblem = problem
        end
    end
    return firstProblem
end

---The After hook of every suite: releases first, then restores; the first
---error of either is raised again afterwards.
local function cleanUp()
    local releaseProblem = runAll(pendingReleases)
    local restoreProblem = runAll(pendingRestores)
    local firstProblem = releaseProblem
    if type(firstProblem) == "nil" then
        firstProblem = restoreProblem
    end
    if type(firstProblem) ~= "nil" then
        error(firstProblem, 0)
    end
end

---Register a suite of this package whose tests all end released.
---@param part string
---@return TestKit.Suite
local function newSuite(part)
    local suite = Harness:Suite(PACKAGE_ID, part, addonName)
    suite:After(cleanUp)
    return suite
end

---A gate name no other test and no earlier run used.
---@param label string
---@return string
local function nextGateName(label)
    gateSequence = gateSequence + 1
    return ("%s.%s.%d"):format(GATE_NAME_PREFIX, label, gateSequence)
end

---Remember `gate` for the After hook, which closes it, and hand it back.
---`Close` answers `false` for a gate that is already closed.
---@param gate any
---@return any gate
local function trackGate(gate)
    pendingReleases[#pendingReleases + 1] = function()
        gate:Close()
    end
    return gate
end

---Define a gate under a fresh name and remember it for the After hook.
---@param label string
---@param probe fun(): any
---@param options table?
---@return any gate
local function defineGate(label, probe, options)
    return trackGate(ReadinessKit:Gate(nextGateName(label), probe, options))
end

---Remember `timer` for the After hook, which cancels it, and hand it back.
---@param timer TimerKit.Timer
---@return TimerKit.Timer timer
local function trackTimer(timer)
    pendingReleases[#pendingReleases + 1] = function()
        timer:Cancel()
    end
    return timer
end

---Remember an EventKit connection for the After hook, which disconnects it.
---@param connection any
---@return any connection
local function trackConnection(connection)
    pendingReleases[#pendingReleases + 1] = function()
        connection:Disconnect()
    end
    return connection
end

-- Probes, callbacks and switches ----------------------------------------------------------

---What a recording probe saw: how often it ran and when.
---@class ReadinessKitSuite.ProbeRecord
---@field calls integer
---@field times number[]

---A probe that records every call, then answers what `answer()` answers.
---@param answer fun(): any
---@return fun(): any probe
---@return ReadinessKitSuite.ProbeRecord record
local function recordingProbe(answer)
    local record = { calls = 0, times = {} }
    local function probe()
        record.calls = record.calls + 1
        record.times[record.calls] = preciseNow()
        return answer()
    end
    return probe, record
end

---Answers "not yet", always.
---@return boolean
local function never()
    return false
end

---Answers "ready", always.
---@return boolean
local function always()
    return true
end

--- A callback that ignores its outcome.
local function ignore() end

---What an outcome callback saw: how often it ran, its last arguments and when.
---@class ReadinessKitSuite.Outcome
---@field calls integer
---@field ready any
---@field reason any
---@field at number

---A callback for `Await` or `WhenAll` that records the outcome it receives.
---@return fun(ready: boolean, reason: string?) callback
---@return ReadinessKitSuite.Outcome outcome
local function outcomeRecorder()
    local outcome = { calls = 0, ready = nil, reason = nil, at = 0 }
    local function callback(ready, reason)
        outcome.calls = outcome.calls + 1
        outcome.ready = ready
        outcome.reason = reason
        outcome.at = preciseNow()
    end
    return callback, outcome
end

---A switch a real TimerKit one-shot turns on after `delaySeconds`.
---@class ReadinessKitSuite.Switch
---@field on boolean
---@field at number the clock reading when it turned on, `0` before

---Start a real one-shot that turns a switch on, remembered for the After hook.
---@param delaySeconds number
---@return ReadinessKitSuite.Switch switch
local function switchOnAfter(delaySeconds)
    local switch = { on = false, at = 0 }
    trackTimer(TimerKit:After(delaySeconds, function()
        switch.on = true
        switch.at = preciseNow()
    end))
    return switch
end

-- Waiting on the client ---------------------------------------------------------------------

---`ctx:WaitUntil(predicate, timeoutSeconds)`, returning only whether the
---predicate became truthy in time.
---
---The call goes through an untyped alias because the LuaCATS field TestKit
---declares for `WaitUntil` reads to lua-language-server as a predicate
---returning two values, so a direct call is reported as passing one argument
---too many.
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
---@class ReadinessKitSuite.Wait
---@field satisfied boolean whether the predicate became truthy in time
---@field frames integer how many rendered frames the wait resumed on
---@field longestFrameSeconds number the longest gap between two resumptions

---Wait like `waitUntil`, and measure the frames the wait spanned: TestKit
---resumes the test once per rendered frame.
---@param ctx TestKit.Context
---@param predicate fun(): any
---@param timeoutSeconds number
---@return ReadinessKitSuite.Wait
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

---Let `seconds` pass on the client's clock, rendering frames meanwhile.
---@param ctx TestKit.Context
---@param seconds number
local function waitSeconds(ctx, seconds)
    local deadline = preciseNow() + seconds
    waitUntil(ctx, function()
        return preciseNow() >= deadline
    end, seconds + LOCAL_WAIT_SECONDS)
end

---The timing tolerance of a wait: one frame, the longest the wait observed
---and never shorter than the client's current frame rate says, plus
---`TIMING_MARGIN_SECONDS`.
---@param wait ReadinessKitSuite.Wait
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

-- The probe CVar ------------------------------------------------------------------------

---The probe CVar's value through `C_CVar.GetCVar`, or `nil` when the client
---has neither the function nor the CVar. Never raises, so a probe can call it.
---@return string|nil
local function currentProbeValue()
    local getCVar = readHostFunction("C_CVar", "GetCVar")
    if type(getCVar) == "nil" then
        return nil
    end
    local value = getCVar(PROBE_CVAR)
    if type(value) ~= "string" or isSecret(value) then
        return nil
    end
    return value
end

---Set the probe CVar through `C_CVar.SetCVar`.
---@param value string
local function writeProbeCVar(value)
    local setCVar = readHostFunction("C_CVar", "SetCVar")
    if type(setCVar) == "nil" then
        error("the client has no C_CVar.SetCVar", 2)
    end
    ---@cast setCVar function
    setCVar(PROBE_CVAR, value)
end

--- Whether the running test already scheduled the probe CVar's restore.
local probeRestoreScheduled = false

---The value the probe CVar does not have now: what the next flip writes. The
---first call of a test schedules the original value's restore. Fails the test
---when the CVar cannot be read.
---@param ctx TestKit.Context
---@return string
local function otherProbeValue(ctx)
    local current = currentProbeValue()
    if type(current) == "nil" then
        ctx:Fail("C_CVar.GetCVar is missing or does not know the CVar " .. PROBE_CVAR)
    end
    ---@cast current string
    if not probeRestoreScheduled then
        probeRestoreScheduled = true
        local original = current
        pendingRestores[#pendingRestores + 1] = function()
            probeRestoreScheduled = false
            if currentProbeValue() ~= original then
                writeProbeCVar(original)
            end
        end
    end
    if current == "1" then
        return "0"
    end
    return "1"
end

---Flip the probe CVar to the value it does not have, which makes the client
---raise CVAR_UPDATE inside the call. Returns the value written.
---@param ctx TestKit.Context
---@return string written
local function flipProbeCVar(ctx)
    local written = otherProbeValue(ctx)
    writeProbeCVar(written)
    return written
end

-- Error positions ----------------------------------------------------------------------

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
    ctx:Expect((file or ""):sub(-#"ReadinessKitSuite.lua")):ToBe("ReadinessKitSuite.lua")
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

-- The client's error handler ----------------------------------------------------------------

---Send failures reported to the client's error handler to a collector until
---the returned `restore` is called; the After hook calls it too, so a test
---that fails or times out while waiting cannot keep the collector.
---
---ReadinessKit hands a failing probe or queued callback to
---`geterrorhandler()`, which on the client reads the handler
---`seterrorhandler` installed. The handler is therefore swapped with
---`seterrorhandler`, never by replacing the global `geterrorhandler`, which
---Blizzard code calls too (tests/client/README.md, "Catching an error a Kit
---reports instead of raising"). A failure of another addon in the window
---reaches the collector too; the tests count only their own marker.
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

---The reports that end with `marker`, the deliberate failure of one test.
---@param reported any[]
---@param marker string
---@return string[]
local function ownReports(reported, marker)
    local own = {}
    for _, message in ipairs(reported) do
        if
            type(message) == "string"
            and not isSecret(message)
            and message:sub(-#marker) == marker
        then
            own[#own + 1] = message
        end
    end
    return own
end

--- Why the error-handler tests fail rather than pass when the swap did not hold.
local HANDLER_KEPT_MESSAGE =
    "the client's error handler could not be replaced (an error-capturing addon such as BugGrabber keeps it); the failure went to that addon"

-- Allocation ----------------------------------------------------------------------------

---Measure how many kilobytes `work` grows the Lua heap by.
---@param work fun()
---@return number grownKilobytes
local function measureAllocation(work)
    local before = collectgarbage("count")
    work()
    return collectgarbage("count") - before
end

---Run a full collection in a step of its own, so the measurement that follows
---starts far from the next collector cycle.
---@param ctx TestKit.Context
local function collectBeforeMeasuring(ctx)
    collectgarbage("collect")
    ctx:Yield()
end

-- Host data candidates ----------------------------------------------------------------------

---Pick the first candidate the client knows and has not cached; without one,
---the first it knows. `exists` may be `nil` (every candidate counts as
---known). Answers are read without comparing a secret.
---@param candidates integer[]
---@param exists function|nil
---@param isCached function
---@return integer|nil id
---@return boolean cachedAtStart
local function chooseCandidate(candidates, exists, isCached)
    local firstKnown = nil
    for _, id in ipairs(candidates) do
        local known = true
        if type(exists) ~= "nil" then
            local answer = exists(id)
            known = not isSecret(answer) and answer == true
        end
        if known then
            local cached = isCached(id)
            if not isSecret(cached) and cached == false then
                return id, false
            end
            if type(firstKnown) == "nil" then
                firstKnown = id
            end
        end
    end
    return firstKnown, true
end

---Whether an event payload names `expectedID`, without comparing a secret.
---@param receivedID any
---@param expectedID integer
---@return boolean
local function namesID(receivedID, expectedID)
    return type(receivedID) == "number" and not isSecret(receivedID) and receivedID == expectedID
end

-- readinessKit.facade -------------------------------------------------------------------

local facade = newSuite("facade")

facade:Test(
    "Registry:Get('readinessKit', 1) is the ReadinessKit facade with API 1, Gate, Get, WhenAll and UNBOUNDED, and its gates and waiters carry every documented method",
    function(ctx)
        ctx:Expect(type(ReadinessKit)):ToBe("table")
        ctx:Expect(rawget(ReadinessKit, "API")):ToBe(READINESS_KIT_API)
        for _, method in ipairs(FACADE_METHODS) do
            ctx:Expect(type(ReadinessKit[method])):ToBe("function")
        end
        ctx:Expect(type(ReadinessKit.UNBOUNDED)):ToBe("table")

        local name = nextGateName("facade")
        local gate = trackGate(ReadinessKit:Gate(name, never, {
            intervalSeconds = QUIET_INTERVAL_SECONDS,
            timeoutSeconds = false,
        }))
        ctx:Expect(ReadinessKit:Get(name)):ToBe(gate)
        ctx:Expect(ReadinessKit:Get(nextGateName("absent"))):ToBeNil()
        for _, method in ipairs(GATE_METHODS) do
            ctx:Expect(type(gate[method])):ToBe("function")
        end
        local waiter = gate:Await(ignore)
        for _, method in ipairs(WAITER_METHODS) do
            ctx:Expect(type(waiter[method])):ToBe("function")
        end
        ctx:Expect(waiter:IsPending()):ToBe(true)
    end
)

facade:Test(
    "the installed ReadinessKit carries the revision of the committed manifest",
    function(ctx)
        local expectedPackages = Harness:GetExpectedPackages()
        if type(expectedPackages) == "nil" then
            ctx:Fail("Expected.lua is missing; install with python3 -m tooling.client.install")
            return
        end
        for _, expected in ipairs(expectedPackages) do
            if expected.id == PACKAGE_ID then
                local _, revision = Registry:Get(PACKAGE_ID, READINESS_KIT_API)
                ctx:Expect(revision):ToBe(expected.revision)
                ctx:Expect(rawget(ReadinessKit, "REVISION")):ToBe(expected.revision)
                return
            end
        end
        ctx:Fail("Expected.lua does not list readinessKit")
    end
)

facade:Test(
    "the client offers both optional host facilities: GetTimePreciseSec, and EventKit API 1 through Registry:Find (logged)",
    function(ctx)
        ctx:Expect(type(getTimePreciseSec)):ToBe("function")
        local found, revisionOrReason = Registry:Find("eventKit", EVENT_KIT_API)
        ctx:Log(
            ("Registry:Find('eventKit', 1) answered %s, %s"):format(
                type(found),
                tostring(revisionOrReason)
            )
        )
        ctx:Expect(type(found)):ToBe("table")
        ctx:Expect(found):ToBe(EventKit)
    end
)

-- readinessKit.hostData -----------------------------------------------------------------

local hostData = newSuite("hostData")

hostData:Test(
    "an item gate over C_Item.GetItemInfo for an item the client had not cached becomes ready when GET_ITEM_INFO_RECEIVED re-probes it, before its first poll (cache state and arrival logged)",
    function(ctx)
        local getItemInfo = readHostFunction("C_Item", "GetItemInfo")
        local requestItemData = readHostFunction("C_Item", "RequestLoadItemDataByID")
        local isItemCached = readHostFunction("C_Item", "IsItemDataCachedByID")
        local itemExists = readHostFunction("C_Item", "DoesItemExistByID")
        if
            type(getItemInfo) == "nil"
            or type(requestItemData) == "nil"
            or type(isItemCached) == "nil"
        then
            Harness:SkipTest(
                ctx,
                "the client lacks C_Item.GetItemInfo, RequestLoadItemDataByID or IsItemDataCachedByID"
            )
            return
        end
        ---@cast getItemInfo function
        ---@cast requestItemData function
        ---@cast isItemCached function
        if not EVENT_KIT_AVAILABLE then
            Harness:SkipTest(ctx, "EventKit API 1 is not loaded, so the gate cannot re-probe")
            return
        end

        local itemID, cachedAtStart = chooseCandidate(ITEM_CANDIDATES, itemExists, isItemCached)
        if type(itemID) == "nil" then
            Harness:SkipTest(ctx, "the client knows none of the candidate items")
            return
        end
        ---@cast itemID integer
        ctx:Log(
            ("item %d; C_Item.IsItemDataCachedByID answered %s at the start"):format(
                itemID,
                tostring(cachedAtStart)
            )
        )

        local gate = nil
        local arrival = { count = 0, success = "none", at = 0, gateReadyBefore = "not seen" }
        -- Connected before the gate's own re-probe, so it sees the event first.
        trackConnection(EventKit:Connect(ITEM_EVENT, function(_, receivedID, success)
            if namesID(receivedID, itemID) then
                arrival.count = arrival.count + 1
                arrival.success = describe(success)
                arrival.at = preciseNow()
                arrival.gateReadyBefore = tostring(type(gate) ~= "nil" and gate:IsReady())
            end
        end))

        local probe, record = recordingProbe(function()
            return type(getItemInfo(itemID)) ~= "nil"
        end)
        local definedAt = preciseNow()
        gate = defineGate(
            "item",
            probe,
            { intervalSeconds = EVENT_GATE_INTERVAL_SECONDS, timeoutSeconds = false }
        )
        local callback, outcome = outcomeRecorder()

        if gate:IsReady() then
            -- The client had the item after all: the gate is ready at once.
            ctx:Log("the gate was ready at definition: the client already had the item")
            gate:Await(callback)
            ctx:Expect(outcome.calls):ToBe(1)
            ctx:Expect(outcome.ready):ToBe(true)
            ctx:Expect(record.calls):ToBe(1)
            return
        end

        ctx:Expect(gate:ReprobeOn(ITEM_EVENT)):ToBe(true)
        gate:Await(callback)
        requestItemData(itemID)
        local reached = waitUntil(ctx, function()
            return outcome.calls > 0
        end, SERVER_WAIT_SECONDS)

        ctx:Log(
            ("ready %s after the definition; %d %s for the item (success %s, gate ready before this listener: %s); probe ran %d times"):format(
                milliseconds((reached and outcome.at or preciseNow()) - definedAt),
                arrival.count,
                ITEM_EVENT,
                arrival.success,
                arrival.gateReadyBefore,
                record.calls
            )
        )
        ctx:Expect(reached):ToBe(true)
        ctx:Expect(outcome.ready):ToBe(true)
        ctx:Expect(outcome.at - definedAt < EVENT_GATE_INTERVAL_SECONDS):ToBe(true)
        ctx:Expect(arrival.count >= 1):ToBe(true)
        ctx:Expect(record.calls >= 2):ToBe(true)
    end
)

hostData:Test(
    "a spell gate over C_Spell.IsSpellDataCached becomes ready when SPELL_DATA_LOAD_RESULT re-probes it after C_Spell.RequestLoadSpellData, before its first poll (cache state logged)",
    function(ctx)
        local isSpellCached = readHostFunction("C_Spell", "IsSpellDataCached")
        local requestSpellData = readHostFunction("C_Spell", "RequestLoadSpellData")
        local spellExists = readHostFunction("C_Spell", "DoesSpellExist")
        if type(isSpellCached) == "nil" or type(requestSpellData) == "nil" then
            Harness:SkipTest(
                ctx,
                "the client lacks C_Spell.IsSpellDataCached or C_Spell.RequestLoadSpellData"
            )
            return
        end
        ---@cast isSpellCached function
        ---@cast requestSpellData function
        if not EVENT_KIT_AVAILABLE then
            Harness:SkipTest(ctx, "EventKit API 1 is not loaded, so the gate cannot re-probe")
            return
        end

        local spellID, cachedAtStart = chooseCandidate(SPELL_CANDIDATES, spellExists, isSpellCached)
        if type(spellID) == "nil" then
            Harness:SkipTest(ctx, "the client knows none of the candidate spells")
            return
        end
        ---@cast spellID integer
        ctx:Log(
            ("spell %d; C_Spell.IsSpellDataCached answered %s at the start"):format(
                spellID,
                tostring(cachedAtStart)
            )
        )

        local arrival = { count = 0, success = "none" }
        trackConnection(EventKit:Connect(SPELL_EVENT, function(_, receivedID, success)
            if namesID(receivedID, spellID) then
                arrival.count = arrival.count + 1
                arrival.success = describe(success)
            end
        end))

        local probe, record = recordingProbe(function()
            local cached = isSpellCached(spellID)
            return not isSecret(cached) and cached == true
        end)
        local definedAt = preciseNow()
        local gate = defineGate(
            "spellData",
            probe,
            { intervalSeconds = EVENT_GATE_INTERVAL_SECONDS, timeoutSeconds = false }
        )
        local callback, outcome = outcomeRecorder()

        if gate:IsReady() then
            ctx:Log("the gate was ready at definition: the client had the spell data already")
            gate:Await(callback)
            ctx:Expect(outcome.calls):ToBe(1)
            ctx:Expect(outcome.ready):ToBe(true)
            ctx:Expect(record.calls):ToBe(1)
            return
        end

        ctx:Expect(gate:ReprobeOn(SPELL_EVENT)):ToBe(true)
        gate:Await(callback)
        requestSpellData(spellID)
        local readyInsideRequest = outcome.calls > 0
        local reached = waitUntil(ctx, function()
            return outcome.calls > 0
        end, LOCAL_WAIT_SECONDS)

        ctx:Log(
            ("ready %s after the definition, inside RequestLoadSpellData: %s; %d %s for the spell (success %s); probe ran %d times"):format(
                milliseconds((reached and outcome.at or preciseNow()) - definedAt),
                tostring(readyInsideRequest),
                arrival.count,
                SPELL_EVENT,
                arrival.success,
                record.calls
            )
        )
        ctx:Expect(reached):ToBe(true)
        ctx:Expect(outcome.ready):ToBe(true)
        ctx:Expect(outcome.at - definedAt < EVENT_GATE_INTERVAL_SECONDS):ToBe(true)
        ctx:Expect(arrival.count >= 1):ToBe(true)
    end
)

hostData:Test(
    "a gate over C_Spell.GetSpellInfo for Auto Attack is ready at definition, calls Await at once, and never probes again",
    function(ctx)
        local getSpellInfo = readHostFunction("C_Spell", "GetSpellInfo")
        if type(getSpellInfo) == "nil" then
            Harness:SkipTest(ctx, "the client has no C_Spell.GetSpellInfo")
            return
        end
        ---@cast getSpellInfo function
        local probe, record = recordingProbe(function()
            return type(getSpellInfo(AUTO_ATTACK_SPELL_ID)) ~= "nil"
        end)
        local gate = defineGate("autoAttack", probe, { intervalSeconds = POLL_INTERVAL_SECONDS })
        ctx:Expect(gate:IsReady()):ToBe(true)

        local callback, outcome = outcomeRecorder()
        local waiter = gate:Await(callback)
        ctx:Expect(outcome.calls):ToBe(1)
        ctx:Expect(outcome.ready):ToBe(true)
        ctx:Expect(waiter:IsPending()):ToBe(false)
        ctx:Expect(gate:Probe()):ToBe(true)

        -- Several intervals: a poll timer, had one been started, would have run.
        waitSeconds(ctx, QUIET_WAIT_SECONDS)
        ctx:Expect(record.calls):ToBe(1)
        ctx:Expect(gate:IsReady()):ToBe(true)
    end
)

-- readinessKit.polling ------------------------------------------------------------------

local polling = newSuite("polling")

polling:Test(
    "a gate whose probe turns true on a real 0.3-second TimerKit one-shot is ready on the next poll, within one interval plus one frame and 20 ms (lateness logged)",
    function(ctx)
        local switch = switchOnAfter(SWITCH_DELAY_SECONDS)
        local probe, record = recordingProbe(function()
            return switch.on
        end)
        local gate = defineGate("switch", probe, { intervalSeconds = POLL_INTERVAL_SECONDS })
        local callback, outcome = outcomeRecorder()
        gate:Await(callback)
        ctx:Expect(gate:IsReady()):ToBe(false)

        local wait = measuredWait(ctx, function()
            return outcome.calls > 0
        end, LOCAL_WAIT_SECONDS)
        ctx:Expect(wait.satisfied):ToBe(true)
        ctx:Expect(switch.on):ToBe(true)

        local lateness = outcome.at - switch.at
        local allowance = POLL_INTERVAL_SECONDS + frameAllowance(wait)
        ctx:Log(
            ("ready %s after the switch turned on; allowance %s; probe ran %d times"):format(
                milliseconds(lateness),
                milliseconds(allowance),
                record.calls
            )
        )
        ctx:Expect(outcome.ready):ToBe(true)
        ctx:Expect(lateness >= 0):ToBe(true)
        ctx:Expect(lateness <= allowance):ToBe(true)
        ctx:Expect(record.calls >= 3):ToBe(true)
    end
)

polling:Test(
    "a pending gate polls on a real TimerKit timer every intervalSeconds, and Close stops the polling for good and frees the name (intervals logged)",
    function(ctx)
        local probe, record = recordingProbe(never)
        local name = nextGateName("polls")
        local gate = trackGate(ReadinessKit:Gate(name, probe, {
            intervalSeconds = POLL_INTERVAL_SECONDS,
            timeoutSeconds = false,
        }))
        ctx:Expect(record.calls):ToBe(1)

        local wait = measuredWait(ctx, function()
            return record.calls >= 5
        end, LOCAL_WAIT_SECONDS)
        ctx:Expect(wait.satisfied):ToBe(true)
        ctx:Expect(gate:Close()):ToBe(true)
        local callsAtClose = record.calls

        local allowance = frameAllowance(wait)
        local intervals = {}
        for index = 3, callsAtClose do
            intervals[#intervals + 1] = milliseconds(record.times[index] - record.times[index - 1])
        end
        ctx:Log(
            ("intervals between polls: %s; allowance %s around %s"):format(
                table.concat(intervals, ", "),
                milliseconds(allowance),
                milliseconds(POLL_INTERVAL_SECONDS)
            )
        )
        -- From the first poll on: the definition probe runs before the timer starts.
        for index = 3, callsAtClose do
            local interval = record.times[index] - record.times[index - 1]
            ctx:Expect(math.abs(interval - POLL_INTERVAL_SECONDS) <= allowance):ToBe(true)
        end
        ctx:Expect(gate:IsClosed()):ToBe(true)
        ctx:Expect(ReadinessKit:Get(name)):ToBeNil()

        waitSeconds(ctx, QUIET_WAIT_SECONDS)
        ctx:Log(("polls after Close: %d"):format(record.calls - callsAtClose))
        ctx:Expect(record.calls):ToBe(callsAtClose)
    end
)

polling:Test(
    "Invalidate on a ready gate resumes polling on the real timer, and the first poll that answers makes it ready again",
    function(ctx)
        local probe, record = recordingProbe(always)
        local gate = defineGate("invalidate", probe, { intervalSeconds = POLL_INTERVAL_SECONDS })
        ctx:Expect(gate:IsReady()):ToBe(true)

        local invalidatedAt = preciseNow()
        ctx:Expect(gate:Invalidate()):ToBe(true)
        ctx:Expect(gate:IsReady()):ToBe(false)
        ctx:Expect(record.calls):ToBe(1)
        local callback, outcome = outcomeRecorder()
        gate:Await(callback)

        local wait = measuredWait(ctx, function()
            return outcome.calls > 0
        end, LOCAL_WAIT_SECONDS)
        local elapsed = outcome.at - invalidatedAt
        local allowance = POLL_INTERVAL_SECONDS + frameAllowance(wait)
        ctx:Log(
            ("ready again %s after Invalidate; allowance %s"):format(
                milliseconds(elapsed),
                milliseconds(allowance)
            )
        )
        ctx:Expect(wait.satisfied):ToBe(true)
        ctx:Expect(outcome.ready):ToBe(true)
        ctx:Expect(record.calls):ToBe(2)
        ctx:Expect(elapsed <= allowance):ToBe(true)
    end
)

-- readinessKit.timeouts -----------------------------------------------------------------

local timeouts = newSuite("timeouts")

timeouts:Test(
    "a gate with timeoutSeconds 0.3 tells its waiter timeout on the first poll past 0.3 s of GetTimePreciseSec, then stops polling (elapsed logged)",
    function(ctx)
        local probe, record = recordingProbe(never)
        local definedAt = preciseNow()
        local gate = defineGate("timeout", probe, {
            intervalSeconds = POLL_INTERVAL_SECONDS,
            timeoutSeconds = SHORT_TIMEOUT_SECONDS,
        })
        local callback, outcome = outcomeRecorder()
        gate:Await(callback)

        local wait = measuredWait(ctx, function()
            return outcome.calls > 0
        end, LOCAL_WAIT_SECONDS)
        local elapsed = outcome.at - definedAt
        local allowance = POLL_INTERVAL_SECONDS + frameAllowance(wait)
        ctx:Log(
            ("timed out %s after the definition, after %d probes; allowance past 0.3 s %s"):format(
                milliseconds(elapsed),
                record.calls,
                milliseconds(allowance)
            )
        )
        ctx:Expect(wait.satisfied):ToBe(true)
        ctx:Expect(outcome.ready):ToBe(false)
        ctx:Expect(outcome.reason):ToBe("timeout")
        ctx:Expect(elapsed >= SHORT_TIMEOUT_SECONDS):ToBe(true)
        ctx:Expect(elapsed <= SHORT_TIMEOUT_SECONDS + allowance):ToBe(true)

        local callsAtTimeout = record.calls
        waitSeconds(ctx, QUIET_WAIT_SECONDS)
        ctx:Expect(record.calls):ToBe(callsAtTimeout)

        -- A timed-out gate answers a new waiter at once.
        local lateCallback, lateOutcome = outcomeRecorder()
        gate:Await(lateCallback)
        ctx:Expect(lateOutcome.calls):ToBe(1)
        ctx:Expect(lateOutcome.reason):ToBe("timeout")
    end
)

timeouts:Test(
    "Probe on a timed-out gate starts a new polling round whose timeout runs 0.3 s from that Probe on the real clock (elapsed logged)",
    function(ctx)
        local probe, record = recordingProbe(never)
        local gate = defineGate("reround", probe, {
            intervalSeconds = POLL_INTERVAL_SECONDS,
            timeoutSeconds = SHORT_TIMEOUT_SECONDS,
        })
        local firstCallback, firstOutcome = outcomeRecorder()
        gate:Await(firstCallback)
        ctx:Expect(waitUntil(ctx, function()
            return firstOutcome.calls > 0
        end, LOCAL_WAIT_SECONDS)):ToBe(true)
        ctx:Expect(firstOutcome.reason):ToBe("timeout")

        local callsBeforeProbe = record.calls
        local probedAt = preciseNow()
        ctx:Expect(gate:Probe()):ToBe(false)
        local callback, outcome = outcomeRecorder()
        gate:Await(callback)
        ctx:Expect(outcome.calls):ToBe(0)

        local wait = measuredWait(ctx, function()
            return outcome.calls > 0
        end, LOCAL_WAIT_SECONDS)
        local elapsed = outcome.at - probedAt
        local allowance = POLL_INTERVAL_SECONDS + frameAllowance(wait)
        ctx:Log(
            ("second round timed out %s after Probe, after %d more probes"):format(
                milliseconds(elapsed),
                record.calls - callsBeforeProbe
            )
        )
        ctx:Expect(wait.satisfied):ToBe(true)
        ctx:Expect(outcome.reason):ToBe("timeout")
        ctx:Expect(elapsed >= SHORT_TIMEOUT_SECONDS):ToBe(true)
        ctx:Expect(elapsed <= SHORT_TIMEOUT_SECONDS + allowance):ToBe(true)
        ctx:Expect(record.calls - callsBeforeProbe >= 2):ToBe(true)
    end
)

-- readinessKit.negativeCache ------------------------------------------------------------

local negativeCache = newSuite("negativeCache")

negativeCache:Test(
    "a burst of 100 Probe calls within intervalSeconds of GetTimePreciseSec runs the probe once, and the first Probe after the interval runs it again (spin logged)",
    function(ctx)
        local probe, record = recordingProbe(never)
        local gate = defineGate("cache", probe, {
            intervalSeconds = CACHE_INTERVAL_SECONDS,
            timeoutSeconds = false,
        })

        -- Everything below runs in one step, so no poll tick can run between
        -- the calls: the clock alone decides what the cache answers.
        ctx:Expect(gate:Invalidate()):ToBe(false) -- drops the cache, keeps the round
        local callsBefore = record.calls
        ctx:Expect(gate:Probe()):ToBe(false)
        local probeReturnedAt = preciseNow()
        ctx:Expect(record.calls):ToBe(callsBefore + 1)
        local probeRanAt = record.times[record.calls]

        for _ = 1, PROBE_BURST do
            gate:Probe()
        end
        local burstEndedAt = preciseNow()
        ctx:Expect(burstEndedAt - probeRanAt < CACHE_INTERVAL_SECONDS):ToBe(true)
        ctx:Expect(record.calls):ToBe(callsBefore + 1)

        -- Past the interval of the last negative answer, which ReadinessKit
        -- stamped before Probe returned.
        local expiry = probeReturnedAt + CACHE_INTERVAL_SECONDS
        local spins = 0
        while preciseNow() < expiry and spins < MAX_CLOCK_SPINS do
            spins = spins + 1
        end
        local spunUntil = preciseNow()
        if spunUntil < expiry then
            ctx:Fail(
                ("GetTimePreciseSec did not advance past the interval in %d reads"):format(spins)
            )
        end
        gate:Probe()
        ctx:Log(
            ("burst of %d took %s; spun %d times for %s until the interval passed; probe ran %d times in all"):format(
                PROBE_BURST,
                milliseconds(burstEndedAt - probeReturnedAt),
                spins,
                milliseconds(spunUntil - burstEndedAt),
                record.calls - callsBefore
            )
        )
        ctx:Expect(record.calls):ToBe(callsBefore + 2)
    end
)

-- readinessKit.reprobe ------------------------------------------------------------------

local reprobe = newSuite("reprobe")

--- Why the re-probe tests are skipped without EventKit.
local EVENT_KIT_SKIP_REASON = "EventKit API 1 is not loaded, so no gate can re-probe on an event"

---Register `body` as a test when EventKit is loaded, and as a skipped test
---naming why otherwise.
---@param suite TestKit.Suite
---@param name string
---@param body fun(ctx: TestKit.Context)
local function eventTest(suite, name, body)
    if EVENT_KIT_AVAILABLE then
        suite:Test(name, body)
    else
        suite:Skip(name, EVENT_KIT_SKIP_REASON)
    end
end

---A probe that answers whether the probe CVar has `target`, recording calls.
---@param target string
---@return fun(): any probe
---@return ReadinessKitSuite.ProbeRecord record
local function cvarProbe(target)
    return recordingProbe(function()
        return currentProbeValue() == target
    end)
end

eventTest(
    reprobe,
    "ReprobeOn('CVAR_UPDATE') makes a gate over the chatBubbles CVar ready inside C_CVar.SetCVar, long before its first poll, and answers false for the same event again",
    function(ctx)
        local target = otherProbeValue(ctx)
        local probe, record = cvarProbe(target)
        local gate = defineGate("cvar", probe, {
            intervalSeconds = EVENT_GATE_INTERVAL_SECONDS,
            timeoutSeconds = false,
        })
        ctx:Expect(gate:IsReady()):ToBe(false)
        ctx:Expect(gate:ReprobeOn(CVAR_EVENT)):ToBe(true)
        ctx:Expect(gate:ReprobeOn(CVAR_EVENT)):ToBe(false)
        local callback, outcome = outcomeRecorder()
        gate:Await(callback)

        flipProbeCVar(ctx)
        local readyInsideSetCVar = gate:IsReady()
        ctx:Log(
            ("ready when SetCVar returned: %s; probe ran %d times"):format(
                tostring(readyInsideSetCVar),
                record.calls
            )
        )
        ctx:Expect(readyInsideSetCVar):ToBe(true)
        ctx:Expect(outcome.calls):ToBe(1)
        ctx:Expect(outcome.ready):ToBe(true)
        ctx:Expect(record.calls):ToBe(2)
    end
)

eventTest(
    reprobe,
    "a timed-out gate re-probed by CVAR_UPDATE becomes ready at the event, without Probe or Invalidate",
    function(ctx)
        local target = otherProbeValue(ctx)
        local probe = cvarProbe(target)
        local gate = defineGate("cvarTimeout", probe, {
            intervalSeconds = POLL_INTERVAL_SECONDS,
            timeoutSeconds = SHORT_TIMEOUT_SECONDS,
        })
        ctx:Expect(gate:ReprobeOn(CVAR_EVENT)):ToBe(true)
        local callback, outcome = outcomeRecorder()
        gate:Await(callback)
        ctx:Expect(waitUntil(ctx, function()
            return outcome.calls > 0
        end, LOCAL_WAIT_SECONDS)):ToBe(true)
        ctx:Expect(outcome.reason):ToBe("timeout")

        flipProbeCVar(ctx)
        ctx:Expect(gate:IsReady()):ToBe(true)
        local lateCallback, lateOutcome = outcomeRecorder()
        gate:Await(lateCallback)
        ctx:Expect(lateOutcome.calls):ToBe(1)
        ctx:Expect(lateOutcome.ready):ToBe(true)
    end
)

eventTest(
    reprobe,
    "a ready gate ignores CVAR_UPDATE, and after Close a chatBubbles change runs a re-probing gate's probe no more",
    function(ctx)
        local readyProbe, readyRecord = recordingProbe(always)
        local readyGate = defineGate("cvarReady", readyProbe, {
            intervalSeconds = EVENT_GATE_INTERVAL_SECONDS,
        })
        ctx:Expect(readyGate:ReprobeOn(CVAR_EVENT)):ToBe(true)

        local pendingProbe, pendingRecord = recordingProbe(never)
        local pendingGate = defineGate("cvarClosed", pendingProbe, {
            intervalSeconds = EVENT_GATE_INTERVAL_SECONDS,
            timeoutSeconds = false,
        })
        ctx:Expect(pendingGate:ReprobeOn(CVAR_EVENT)):ToBe(true)

        flipProbeCVar(ctx)
        ctx:Expect(readyRecord.calls):ToBe(1)
        -- The event reached the pending gate: at least one re-probe.
        local callsAtClose = pendingRecord.calls
        ctx:Expect(callsAtClose >= 2):ToBe(true)

        ctx:Expect(pendingGate:Close()):ToBe(true)
        flipProbeCVar(ctx)
        ctx:Log(
            ("probe runs: ready gate %d; re-probing gate %d before Close, %d after the flip that followed it"):format(
                readyRecord.calls,
                callsAtClose,
                pendingRecord.calls
            )
        )
        ctx:Expect(readyRecord.calls):ToBe(1)
        ctx:Expect(pendingRecord.calls):ToBe(callsAtClose)
    end
)

eventTest(
    reprobe,
    "ReprobeOn with an event name the client does not know is refused at the calling line with EventKit's reason, every time, and the gate still re-probes on a real event",
    function(ctx)
        local gate = defineGate("unknownEvent", never, {
            intervalSeconds = EVENT_GATE_INTERVAL_SECONDS,
            timeoutSeconds = false,
        })
        local isEventValid = readHostFunction("C_EventUtils", "IsEventValid")
        ctx:Log(
            "the client has C_EventUtils.IsEventValid: " .. tostring(type(isEventValid) ~= "nil")
        )
        local expected = "ReadinessKit.Gate:ReprobeOn could not connect " .. UNKNOWN_EVENT .. ": "
        if type(isEventValid) ~= "nil" then
            expected = expected
                .. 'EventKit.Scope:Connect eventName "'
                .. UNKNOWN_EVENT
                .. '" is not an event this client knows'
        end

        for _ = 1, 2 do
            local startLine = 0
            local succeeded, message = pcall(function()
                startLine = currentLine()
                gate:ReprobeOn(UNKNOWN_EVENT)
            end)
            ctx:Expect(succeeded):ToBe(false)
            ctx:Log("client message: " .. tostring(message))
            ctx:Expect(expectThisFile(ctx, message)):ToBe(startLine + 1)
            local text = tostring(message)
            local _, afterPosition = text:find("^.-:%d+: ")
            ctx:Expect(text:sub((afterPosition or 0) + 1, (afterPosition or 0) + #expected))
                :ToBe(expected)
        end
        ctx:Expect(gate:ReprobeOn(CVAR_EVENT)):ToBe(true)
    end
)

-- readinessKit.waiters ------------------------------------------------------------------

local waiters = newSuite("waiters")

waiters:Test(
    "a gate with maxWaiters 3 refuses the fourth Await with nil, full, takes one again after a Cancel, and calls the queued callbacks in order when a real timer makes it ready",
    function(ctx)
        local switch = switchOnAfter(SWITCH_DELAY_SECONDS)
        local gate = defineGate("bounded", function()
            return switch.on
        end, { intervalSeconds = POLL_INTERVAL_SECONDS, maxWaiters = SMALL_MAX_WAITERS })

        local order = {}
        ---@param label integer
        ---@return fun(ready: boolean)
        local function inOrder(label)
            return function(ready)
                order[#order + 1] = label
                order[#order + 1] = ready
            end
        end
        local first = gate:Await(inOrder(1))
        local second = gate:Await(inOrder(2))
        gate:Await(inOrder(3))
        local refused, reason = gate:Await(inOrder(99))
        ctx:Expect(refused):ToBeNil()
        ctx:Expect(reason):ToBe("full")

        ctx:Expect(second:Cancel()):ToBe(true)
        ctx:Expect(second:Cancel()):ToBe(false)
        ctx:Expect(second:IsPending()):ToBe(false)
        local fourth = gate:Await(inOrder(4))
        ctx:Expect(type(fourth)):ToBe("table")

        ctx:Expect(waitUntil(ctx, function()
            return gate:IsReady()
        end, LOCAL_WAIT_SECONDS)):ToBe(true)
        ctx:Expect(order):ToEqual({ 1, true, 3, true, 4, true })
        ctx:Expect(first:IsPending()):ToBe(false)
        ctx:Expect(first:Cancel()):ToBe(false)
    end
)

eventTest(
    waiters,
    "WhenAll over a gate a real timer makes ready and a gate CVAR_UPDATE makes ready calls back once, with true, inside the SetCVar that completes it",
    function(ctx)
        local switch = switchOnAfter(SWITCH_DELAY_SECONDS)
        local timerGate = defineGate("allTimer", function()
            return switch.on
        end, { intervalSeconds = POLL_INTERVAL_SECONDS })
        local target = otherProbeValue(ctx)
        local cvarGate = defineGate("allCvar", cvarProbe(target), {
            intervalSeconds = EVENT_GATE_INTERVAL_SECONDS,
            timeoutSeconds = false,
        })
        ctx:Expect(cvarGate:ReprobeOn(CVAR_EVENT)):ToBe(true)

        local callback, outcome = outcomeRecorder()
        local group = ReadinessKit:WhenAll({ timerGate, cvarGate }, callback)
        ctx:Expect(group:IsPending()):ToBe(true)

        ctx:Expect(waitUntil(ctx, function()
            return timerGate:IsReady()
        end, LOCAL_WAIT_SECONDS)):ToBe(true)
        ctx:Expect(outcome.calls):ToBe(0)

        flipProbeCVar(ctx)
        ctx:Expect(outcome.calls):ToBe(1)
        ctx:Expect(outcome.ready):ToBe(true)
        ctx:Expect(group:IsPending()):ToBe(false)

        waitSeconds(ctx, QUIET_WAIT_SECONDS)
        ctx:Expect(outcome.calls):ToBe(1)
    end
)

-- readinessKit.failures -----------------------------------------------------------------

local failures = newSuite("failures")

failures:Test(
    "a probe that always raises is reported to the client's error handler once per polling round, naming ReadinessKitSuite.lua at the raising line, while GetProbeErrorCount counts every failure",
    function(ctx)
        local failingLine = 0
        local reported, observed, restoreHandler = collectReportedErrors()
        local gate = defineGate("raising", function()
            failingLine = currentLine()
            error(PROBE_FAILURE)
        end, {
            intervalSeconds = POLL_INTERVAL_SECONDS,
            timeoutSeconds = SHORT_TIMEOUT_SECONDS,
        })
        local callback, outcome = outcomeRecorder()
        gate:Await(callback)

        local timedOut = waitUntil(ctx, function()
            return outcome.calls > 0
        end, LOCAL_WAIT_SECONDS)
        local firstRoundReports = #ownReports(reported, PROBE_FAILURE)
        local firstRoundCount = gate:GetProbeErrorCount()

        -- A new round reports its first failure again.
        ctx:Expect(gate:Probe()):ToBe(false)
        local secondRoundFailed = waitUntil(ctx, function()
            return gate:GetProbeErrorCount() > firstRoundCount
        end, LOCAL_WAIT_SECONDS)
        waitSeconds(ctx, POLL_INTERVAL_SECONDS)
        ctx:Expect(gate:Close()):ToBe(true)
        restoreHandler()

        local own = ownReports(reported, PROBE_FAILURE)
        ctx:Log(
            ("first round: %d failures, %d reported; after the second round: %d failures, %d reported; the collector received %d reports in all"):format(
                firstRoundCount,
                firstRoundReports,
                gate:GetProbeErrorCount(),
                #own,
                #reported
            )
        )
        ctx:Expect(timedOut):ToBe(true)
        ctx:Expect(outcome.reason):ToBe("timeout")
        if not observed then
            ctx:Fail(HANDLER_KEPT_MESSAGE)
            return
        end
        ctx:Expect(firstRoundReports):ToBe(1)
        ctx:Expect(firstRoundCount >= 4):ToBe(true)
        ctx:Expect(secondRoundFailed):ToBe(true)
        ctx:Expect(#own):ToBe(2)
        ctx:Log("reported: " .. tostring(own[1]))
        ctx:Expect(expectThisFile(ctx, own[1])):ToBe(failingLine + 1)
    end
)

failures:Test(
    "a queued Await callback that raises is reported to the client's error handler, naming ReadinessKitSuite.lua at the raising line, and the next callback of the batch still runs",
    function(ctx)
        local switch = switchOnAfter(SWITCH_DELAY_SECONDS)
        local gate = defineGate("callbackRaises", function()
            return switch.on
        end, { intervalSeconds = POLL_INTERVAL_SECONDS })
        local reported, observed, restoreHandler = collectReportedErrors()

        local order = {}
        local failingLine = 0
        gate:Await(function()
            order[#order + 1] = "first"
        end)
        gate:Await(function()
            order[#order + 1] = "raising"
            failingLine = currentLine()
            error(CALLBACK_FAILURE)
        end)
        gate:Await(function()
            order[#order + 1] = "third"
        end)

        local ready = waitUntil(ctx, function()
            return gate:IsReady()
        end, LOCAL_WAIT_SECONDS)
        restoreHandler()

        ctx:Expect(ready):ToBe(true)
        ctx:Expect(order):ToEqual({ "first", "raising", "third" })
        if not observed then
            ctx:Fail(HANDLER_KEPT_MESSAGE)
            return
        end
        local own = ownReports(reported, CALLBACK_FAILURE)
        ctx:Expect(#own):ToBe(1)
        ctx:Log("reported: " .. tostring(own[1]))
        ctx:Expect(expectThisFile(ctx, own[1])):ToBe(failingLine + 1)
    end
)

-- readinessKit.allocation ---------------------------------------------------------------

local allocation = newSuite("allocation")

allocation:Test(
    "IsReady, a negatively cached Probe, IsClosed, GetProbeErrorCount and a waiter's IsPending allocate nothing over 10000 calls each (allocation guard)",
    function(ctx)
        local probe, record = recordingProbe(never)
        local gate = defineGate("allocation", probe, {
            intervalSeconds = QUIET_INTERVAL_SECONDS,
            timeoutSeconds = false,
        })
        local waiter = gate:Await(ignore)
        collectBeforeMeasuring(ctx)

        local grownKilobytes = measureAllocation(function()
            for _ = 1, ALLOCATION_ROUNDS do
                gate:IsReady()
                gate:Probe()
                gate:IsClosed()
                gate:GetProbeErrorCount()
                waiter:IsPending()
            end
        end)

        ctx:Log(
            ("memory delta over %d rounds of 5 calls: %.3f KB"):format(
                ALLOCATION_ROUNDS,
                grownKilobytes
            )
        )
        ctx:Expect(grownKilobytes <= ALLOCATION_TOLERANCE_KB):ToBe(true)
        ctx:Expect(record.calls):ToBe(1)
        ctx:Expect(waiter:IsPending()):ToBe(true)
    end
)

allocation:Skip(
    "a poll tick whose probe answers not yet allocates nothing (allocation guard)",
    "not measurable here: C_Timer delivers a tick between frames, where every other addon allocates too; packages/readinessKit/tests/Allocation_spec.lua guards it"
)

-- readinessKit.errors -------------------------------------------------------------------

local errors = newSuite("errors")

errors:Test(
    "Gate with an empty name, a probe that is not a function, or unknown option fields is refused at the calling line, naming the alphabetically first unknown field",
    function(ctx)
        local startLine = 0
        local line = expectErrorAtCallingLine(ctx, function()
            startLine = currentLine()
            ReadinessKit:Gate("", never)
        end, "ReadinessKit:Gate name must be a non-empty string")
        ctx:Expect(line):ToBe(startLine + 1)

        line = expectErrorAtCallingLine(ctx, function()
            startLine = currentLine()
            ReadinessKit:Gate(nextGateName("noProbe"), "not a function")
        end, "ReadinessKit:Gate probe must be a function")
        ctx:Expect(line):ToBe(startLine + 1)

        line = expectErrorAtCallingLine(ctx, function()
            startLine = currentLine()
            ReadinessKit:Gate(nextGateName("unknownOptions"), never, { zeta = 1, alpha = 2 })
        end, 'ReadinessKit:Gate options contains unknown field "alpha"')
        ctx:Expect(line):ToBe(startLine + 1)
    end
)

errors:Test(
    "Gate refuses a zero interval, a timeout of true and a fractional maxWaiters at the calling line with their documented messages, and defines no gate",
    function(ctx)
        local cases = {
            {
                options = { intervalSeconds = 0 },
                expected = "ReadinessKit:Gate intervalSeconds must be a finite number greater than zero",
            },
            {
                options = { timeoutSeconds = true },
                expected = "ReadinessKit:Gate timeoutSeconds must be false or a finite number greater than zero",
            },
            {
                options = { maxWaiters = 1.5 },
                expected = "ReadinessKit:Gate maxWaiters must be a positive integer or ReadinessKit.UNBOUNDED",
            },
        }
        for _, case in ipairs(cases) do
            local name = nextGateName("badOption")
            local startLine = 0
            local line = expectErrorAtCallingLine(ctx, function()
                startLine = currentLine()
                ReadinessKit:Gate(name, never, case.options)
            end, case.expected)
            ctx:Expect(line):ToBe(startLine + 1)
            ctx:Expect(ReadinessKit:Get(name)):ToBeNil()
        end
    end
)

errors:Test(
    "a gate method called on something that is not a gate, a waiter method called on a gate, and WhenAll with a non-table are refused at the calling line",
    function(ctx)
        local gate = defineGate("receiver", never, {
            intervalSeconds = QUIET_INTERVAL_SECONDS,
            timeoutSeconds = false,
        })
        local waiter = gate:Await(ignore)

        local startLine = 0
        local line = expectErrorAtCallingLine(ctx, function()
            startLine = currentLine()
            gate.IsReady({})
        end, "ReadinessKit.Gate:IsReady must be called on a ReadinessKit gate")
        ctx:Expect(line):ToBe(startLine + 1)

        line = expectErrorAtCallingLine(ctx, function()
            startLine = currentLine()
            waiter.Cancel(gate)
        end, "ReadinessKit.Waiter:Cancel must be called on a ReadinessKit waiter")
        ctx:Expect(line):ToBe(startLine + 1)

        line = expectErrorAtCallingLine(ctx, function()
            startLine = currentLine()
            ReadinessKit:WhenAll("not a list", ignore)
        end, "ReadinessKit:WhenAll gates must be an array of ReadinessKit gates")
        ctx:Expect(line):ToBe(startLine + 1)
        ctx:Expect(waiter:IsPending()):ToBe(true)
    end
)

errors:Test(
    "Await, Probe, Invalidate, ReprobeOn and WhenAll on a closed gate are refused at the calling line, and a second Close answers false",
    function(ctx)
        local gate = defineGate("closed", never, { intervalSeconds = QUIET_INTERVAL_SECONDS })
        ctx:Expect(gate:Close()):ToBe(true)
        ctx:Expect(gate:Close()):ToBe(false)
        ctx:Expect(gate:IsReady()):ToBe(false)

        local cases = {
            {
                call = function()
                    gate:Await(ignore)
                end,
                expected = "ReadinessKit.Gate:Await cannot wait on a closed gate",
            },
            {
                call = function()
                    gate:Probe()
                end,
                expected = "ReadinessKit.Gate:Probe cannot probe a closed gate",
            },
            {
                call = function()
                    gate:Invalidate()
                end,
                expected = "ReadinessKit.Gate:Invalidate cannot invalidate a closed gate",
            },
            {
                call = function()
                    gate:ReprobeOn(CVAR_EVENT)
                end,
                expected = "ReadinessKit.Gate:ReprobeOn cannot subscribe a closed gate",
            },
            {
                call = function()
                    ReadinessKit:WhenAll({ gate }, ignore)
                end,
                expected = "ReadinessKit:WhenAll cannot wait on a closed gate",
            },
        }
        for _, case in ipairs(cases) do
            local succeeded, message = pcall(case.call)
            ctx:Expect(succeeded):ToBe(false)
            ctx:Log("client message: " .. tostring(message))
            -- Each case raises from its own `call` line in this file.
            expectThisFile(ctx, message)
            ctx:Expect(tostring(message):sub(-#case.expected)):ToBe(case.expected)
        end
    end
)

-- readinessKit.secrets ------------------------------------------------------------------

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
---`secretwrap` wraps a plain value into a secret without touching any game
---state, so calling it has no side effect. A secret is checked only with
---`issecretvalue` and `type`: comparing it with a value of its own type raises.
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
    "Gate and Get refuse a secret name at the calling line, before comparing it",
    function(ctx)
        local secretName = makeSecret(ctx, nextGateName("secretName"))

        local startLine = 0
        local line = expectErrorAtCallingLine(ctx, function()
            startLine = currentLine()
            ReadinessKit:Gate(secretName, never)
        end, "ReadinessKit:Gate name must not be a secret value")
        ctx:Expect(line):ToBe(startLine + 1)

        line = expectErrorAtCallingLine(ctx, function()
            startLine = currentLine()
            ReadinessKit:Get(secretName)
        end, "ReadinessKit:Get name must not be a secret value")
        ctx:Expect(line):ToBe(startLine + 1)
    end
)

secretTest(
    "Gate refuses a secret intervalSeconds, timeoutSeconds and maxWaiters at the calling line, and defines no gate",
    function(ctx)
        local cases = {
            { field = "intervalSeconds", value = 0.5 },
            { field = "timeoutSeconds", value = 5 },
            { field = "maxWaiters", value = 4 },
        }
        for _, case in ipairs(cases) do
            local name = nextGateName("secretOption")
            local options = { [case.field] = makeSecret(ctx, case.value) }
            local startLine = 0
            local line = expectErrorAtCallingLine(ctx, function()
                startLine = currentLine()
                ReadinessKit:Gate(name, never, options)
            end, "ReadinessKit:Gate " .. case.field .. " must not be a secret value")
            ctx:Expect(line):ToBe(startLine + 1)
            ctx:Expect(ReadinessKit:Get(name)):ToBeNil()
        end
    end
)

secretTest("ReprobeOn refuses a secret event name at the calling line", function(ctx)
    local gate = defineGate("secretEvent", never, {
        intervalSeconds = QUIET_INTERVAL_SECONDS,
        timeoutSeconds = false,
    })
    local secretEvent = makeSecret(ctx, CVAR_EVENT)

    local startLine = 0
    local line = expectErrorAtCallingLine(ctx, function()
        startLine = currentLine()
        gate:ReprobeOn(secretEvent)
    end, "ReadinessKit.Gate:ReprobeOn eventName must not be a secret value")
    ctx:Expect(line):ToBe(startLine + 1)
end)

secretTest(
    "a probe that answers a secret true or false: what Gate and the polls do with it is logged (docs/API.md does not say), and every such gate closes and frees its name",
    function(ctx)
        local reported, _, restoreHandler = collectReportedErrors()
        for _, plain in ipairs({ true, false }) do
            local secretAnswer = makeSecret(ctx, plain)
            local name = nextGateName("secretAnswer")
            local succeeded, problem = pcall(
                ReadinessKit.Gate,
                ReadinessKit,
                name,
                function()
                    return secretAnswer
                end,
                { intervalSeconds = POLL_INTERVAL_SECONDS, timeoutSeconds = SHORT_TIMEOUT_SECONDS }
            )
            local gate = ReadinessKit:Get(name)
            local reportsBefore = #reported
            if type(gate) ~= "nil" then
                trackGate(gate)
                -- Two polls, had the gate started polling.
                waitSeconds(ctx, 2 * POLL_INTERVAL_SECONDS + TIMING_MARGIN_SECONDS)
            end
            local state = "not registered"
            local probeErrors = "n/a"
            if type(gate) ~= "nil" then
                state = "registered and not ready"
                if gate:IsReady() then
                    state = "registered and ready"
                end
                probeErrors = tostring(gate:GetProbeErrorCount())
            end
            local gateOutcome = "returned"
            if not succeeded then
                gateOutcome = "raised " .. tostring(problem)
            end
            ctx:Log(
                ("secretwrap(%s) answer: Gate %s; the gate is %s; reports during two intervals: %d; probe errors counted: %s"):format(
                    tostring(plain),
                    gateOutcome,
                    state,
                    #reported - reportsBefore,
                    probeErrors
                )
            )
            if type(gate) ~= "nil" then
                gate:Close()
            end
            ctx:Expect(ReadinessKit:Get(name)):ToBeNil()
        end
        restoreHandler()
    end
)

-- readinessKit.session ------------------------------------------------------------------

local session = newSuite("session")

session:Skip(
    "without GetTimePreciseSec a timeout is counted in polls and Probe never answers from the cache",
    "not observable here: every Retail client has GetTimePreciseSec; packages/readinessKit/tests/Timeout_spec.lua and NegativeCache_spec.lua prove the fallback"
)

session:Skip(
    "gates live in memory only and none survives /reload",
    "not observable in a run: /reload ends the session before a result could be printed; docs/API.md, Embedded copies and upgrades"
)
