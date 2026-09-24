-- MoltenCodes Test: EventKitSuite.lua
--
-- Real-client suites for the `eventKit` package. The Busted specs under
-- packages/eventKit/tests/ prove EventKit against a fake client that delivers
-- events when a spec calls `Emit`; these prove, inside the game client with the
-- installed MoltenCodes addon, what that fixture can only simulate:
--
--   * the installed facade and its committed revision;
--   * delivery of events the client itself raises: CVAR_UPDATE after
--     `C_CVar.SetCVar`, TIME_PLAYED_MSG after `RequestTimePlayed`, and the unit
--     event PLAYER_FLAGS_CHANGED after a Do Not Disturb toggle, filtered by the
--     client's own `RegisterUnitEvent`;
--   * the lazy host registration, read back through the client's
--     `GetFramesRegisteredForEvent` and `Frame:IsEventRegistered`;
--   * listener error isolation through the client's real `securecallfunction`
--     and error handler;
--   * scopes, `Coalesce` and `Derive` (SchedulerKit is in the bundle);
--   * argument errors pointing at this file as the client names it, including
--     EventKit's refusal of an event name the client does not know (checked
--     with `C_EventUtils.IsEventValid`, or left to the client's `RegisterEvent`
--     where that function is absent);
--   * what `IsCombatLogAvailable` answers and `ConnectCombatLog` does on this
--     client, with every fact about the client's combat-log reader logged
--     (docs/API.md of eventKit, "The combat log: no payload, two ways to
--     listen").
--
-- Every test uses only events that the test raises itself through a harmless
-- call, or that the server sends in reply to one, so a run needs no combat, no
-- group and no instance. Every wait is at most five seconds.
--
-- Run with `/mct run eventKit`; tests/client/MoltenCodesTest_EventKit/EXPECTED.md
-- lists what the chat frame should show and the visible side effects.
--
-- What a run leaves behind. Every connection, scope and Coalesce or Derive
-- handle a test creates is released by the After hook of its suite, whatever
-- the test's outcome, and only then are the client settings a test changed put
-- back: the `chatBubbles` CVar and the Do Not Disturb flag. The client's error
-- handler is replaced only while one test waits for its deliberate listener
-- failure, and put back at once. One EventKit scope stays in the session: this
-- addon's own (`EventKit:ForAddon(addonName)`), emptied by its test and closed
-- at logout. EventKit keeps the Frames it created for reuse, because the client
-- never frees a Frame. Nothing is written to a global or a saved variable.

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
local EVENT_KIT_API = 1
local SCHEDULER_KIT_API = 1
local PACKAGE_ID = "eventKit"

--- The CVar the tests change to make the client raise CVAR_UPDATE. It is
--- cosmetic (whether chat bubbles are drawn), always present on Retail, not
--- read-only and not secure, so `C_CVar.SetCVar` accepts it from addon code;
--- every change is put back by the After hook.
local PROBE_CVAR = "chatBubbles"

--- The event the client raises when a CVar changes: `(cvarName, value)`.
local CVAR_EVENT = "CVAR_UPDATE"

--- The server's reply to `RequestTimePlayed`: `(totalTimePlayed, timePlayedThisLevel)`.
local TIME_PLAYED_EVENT = "TIME_PLAYED_MSG"

--- A unit event the client raises for "player" when the Do Not Disturb flag
--- changes; its payload is the unit token.
local UNIT_EVENT = "PLAYER_FLAGS_CHANGED"

--- The payload-free combat-log event `ConnectCombatLog` shares with `Connect`.
local COMBAT_LOG_EVENT = "COMBAT_LOG_EVENT_UNFILTERED"

--- An event name no client defines.
local UNKNOWN_EVENT = "MOLTENCODES_TEST_NO_SUCH_EVENT"

--- The refusal `Connect` raises for `UNKNOWN_EVENT` on a client with
--- `C_EventUtils.IsEventValid`, after the `file:line: ` position.
local UNKNOWN_EVENT_MESSAGE = 'EventKit:Connect eventName "'
    .. UNKNOWN_EVENT
    .. '" is not an event this client knows'

--- Seconds a test waits for an event the client raises locally.
local LOCAL_EVENT_TIMEOUT_SECONDS = 3

--- Seconds a test waits for an event that needs a round trip to the server.
--- Two such waits in one test must stay inside TestKit's 10-second limit.
local SERVER_EVENT_TIMEOUT_SECONDS = 4

--- Seconds after a Coalesce delivery during which a second one would be wrong.
local COALESCE_QUIET_SECONDS = 0.5

--- The Coalesce interval; both CVar changes land inside it.
local COALESCE_INTERVAL_SECONDS = 0.25

--- The refusal `ConnectCombatLog` raises when the client has no event reader,
--- after the `file:line: ` position.
local MISSING_READER_MESSAGE = "EventKit:ConnectCombatLog the combat log is not available"
    .. " to addons on this client (no CombatLogGetCurrentEventInfo reader);"
    .. " check EventKit:IsCombatLogAvailable() first"

--- Text a deliberately failing listener raises, so a test can recognise it.
local LISTENER_FAILURE = "mctEventKit deliberate listener failure"

--- Every method docs/API.md of eventKit lists on the facade.
local FACADE_METHODS = {
    "Connect",
    "Once",
    "ConnectUnit",
    "OnceUnit",
    "ConnectCombatLog",
    "IsCombatLogAvailable",
    "CreateScope",
    "ForAddon",
    "CloseAddonScopes",
    "Coalesce",
    "Derive",
    "SetLimits",
    "GetLimits",
}

---Read a client global, or `nil`.
---@param name string
---@return any
local function readHost(name)
    -- CVars, unit state, chat, frame registrations, error handling and
    -- secret-value functions are World of Warcraft client globals, reachable
    -- only through the global table.
    -- selene: allow(global_usage)
    return rawget(_G, name)
end

---Read a function from a client namespace table such as `C_CVar`, or `nil`.
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

---@type EventKit|nil
local EventKitOrNil = Registry:Get(PACKAGE_ID, EVENT_KIT_API)
if type(EventKitOrNil) == "nil" then
    error(addonName .. " requires EventKit API 1 in the MoltenCodes addon; reinstall it", 0)
end
---@cast EventKitOrNil EventKit
local EventKit = EventKitOrNil

--- Read once at load: the registration suite registers its tests as skipped
--- when the client does not list the frames registered for an event.
local getFramesRegisteredForEvent = readHost("GetFramesRegisteredForEvent")
local REGISTRATIONS_READABLE = type(getFramesRegisteredForEvent) == "function"

--- Read once at load: `Coalesce` and `Derive` find SchedulerKit when they are
--- called, and the coalesce suite registers its tests as skipped without it.
local SCHEDULER_KIT_LOADED = type(Registry:Get("schedulerKit", SCHEDULER_KIT_API)) ~= "nil"

-- Helpers ---------------------------------------------------------------------------

--- Release actions of the test that is running (disconnect a connection,
--- close a scope or a handle), run first by the After hook.
---@type (fun())[]
local pendingReleases = {}

--- Restore actions of the test that is running (a CVar, the Do Not Disturb
--- flag, the error handler), run by the After hook after every release, so no
--- listener of the test sees the event a restore raises.
---@type (fun())[]
local pendingRestores = {}

---Run and empty one action list, newest first. Every action runs even when an
---earlier one raised; the first error is raised again afterwards.
---@param actions (fun())[]
local function runActions(actions)
    local firstProblem = nil
    for index = #actions, 1, -1 do
        local action = actions[index]
        actions[index] = nil
        local succeeded, problem = pcall(action)
        if not succeeded and type(firstProblem) == "nil" then
            firstProblem = problem
        end
    end
    if type(firstProblem) ~= "nil" then
        error(firstProblem, 0)
    end
end

---Release everything the test created, then restore what it changed.
---Registered as the After hook of every suite.
local function cleanUp()
    local releasedCleanly, releaseProblem = pcall(runActions, pendingReleases)
    runActions(pendingRestores)
    if not releasedCleanly then
        error(releaseProblem, 0)
    end
end

---Remember `connection` for the After hook and hand it back.
---@param connection EventKit.Connection
---@return EventKit.Connection connection
local function track(connection)
    pendingReleases[#pendingReleases + 1] = function()
        connection:Disconnect()
    end
    return connection
end

---Remember a scope or a Coalesce / Derive handle for the After hook, which
---closes it. `Close` answers `false` when it is already closed.
---@param closable EventKit.Scope|EventKit.CoalesceHandle|EventKit.DeriveHandle
local function trackClosable(closable)
    pendingReleases[#pendingReleases + 1] = function()
        closable:Close()
    end
end

---Register a suite of this package whose tests all end released and restored.
---@param part string
---@return TestKit.Suite
local function newSuite(part)
    local suite = Harness:Suite(PACKAGE_ID, part, addonName)
    suite:After(cleanUp)
    return suite
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

---Whether `value` is a secret value, which cannot be compared.
---@param value any
---@return boolean
local function isSecret(value)
    local isSecretValue = readHost("issecretvalue")
    return type(isSecretValue) == "function" and isSecretValue(value) == true
end

---Describe a client fact for a log line without comparing or indexing it.
---@param value any
---@return string
local function describeFact(value)
    if isSecret(value) then
        return "<secret value>"
    end
    return type(value) .. " " .. tostring(value)
end

---A no-op listener.
local function ignore() end

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
    ctx:Expect((file or ""):sub(-#"EventKitSuite.lua")):ToBe("EventKitSuite.lua")
    return line
end

---Call `raise`, which must record its start line and raise on the next line,
---and check the message names this file and ends with `expected`.
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

-- The probe CVar ------------------------------------------------------------------------

---The probe CVar's value through `C_CVar.GetCVar`, or `nil` when the client
---has neither the function nor the CVar. Never raises, so a `Derive` compute
---can call it.
---@return string|nil
local function currentProbeValue()
    local getCVar = readHostFunction("C_CVar", "GetCVar")
    if type(getCVar) == "nil" then
        return nil
    end
    local value = getCVar(PROBE_CVAR)
    if type(value) ~= "string" then
        return nil
    end
    return value
end

---The probe CVar's value, failing the test when it cannot be read.
---@param ctx TestKit.Context
---@return string
local function readProbeCVar(ctx)
    local value = currentProbeValue()
    if type(value) == "nil" then
        ctx:Fail("C_CVar.GetCVar is missing or does not know the CVar " .. PROBE_CVAR)
    end
    ---@cast value string
    return value
end

---Set the probe CVar through `C_CVar.SetCVar` and return what it answered.
---@param value string
---@return any success
local function writeProbeCVar(value)
    local setCVar = readHostFunction("C_CVar", "SetCVar")
    if type(setCVar) == "nil" then
        error("the client has no C_CVar.SetCVar", 2)
    end
    ---@cast setCVar function
    return setCVar(PROBE_CVAR, value)
end

--- Whether the running test already scheduled the probe CVar's restore.
local probeRestoreScheduled = false

---Flip the probe CVar between "1" and "0" and return the value written. The
---first flip of a test schedules the original value's restore.
---@param ctx TestKit.Context
---@return string written
local function flipProbeCVar(ctx)
    local current = readProbeCVar(ctx)
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
    local written = current == "1" and "0" or "1"
    local accepted = writeProbeCVar(written)
    ctx:Log(
        ("C_CVar.SetCVar(%q, %q) answered %s"):format(PROBE_CVAR, written, describeFact(accepted))
    )
    return written
end

---Whether a CVAR_UPDATE payload names the probe CVar. The client's own
---documentation calls the first value `eventName`; Retail passes the CVar
---name there, compared here without regard to case.
---@param cvarName any
---@return boolean
local function namesProbeCVar(cvarName)
    if type(cvarName) ~= "string" or isSecret(cvarName) then
        return false
    end
    return cvarName:lower() == PROBE_CVAR:lower()
end

---A CVAR_UPDATE listener that calls `onProbe(value)` for the probe CVar only
---and counts the other CVAR_UPDATE events it saw, for the log.
---@param onProbe fun(value: any)
---@return EventKit.Listener listener
---@return fun(): integer otherCount
local function probeListener(onProbe)
    local otherCount = 0
    local function listener(_, cvarName, value)
        if namesProbeCVar(cvarName) then
            onProbe(value)
        else
            otherCount = otherCount + 1
        end
    end
    return listener, function()
        return otherCount
    end
end

-- Frame registrations -------------------------------------------------------------------

---The set of frames the client lists as registered for `eventName`.
---@param eventName string
---@return table<any, boolean>
local function registeredFrameSet(eventName)
    local set = {}
    local frames = { getFramesRegisteredForEvent(eventName) }
    for index = 1, #frames do
        set[frames[index]] = true
    end
    return set
end

---The frames registered for `eventName` now that were not in `before`.
---@param eventName string
---@param before table<any, boolean>
---@return any[]
local function framesAddedSince(eventName, before)
    local added = {}
    for frame in pairs(registeredFrameSet(eventName)) do
        if not before[frame] then
            added[#added + 1] = frame
        end
    end
    return added
end

-- The client's error handler -----------------------------------------------------------

---Send failures reported through the client's error handler to a collector
---until the returned `restore` is called; the After hook calls it too, so a
---test that fails or times out while waiting cannot keep the collector.
---
---On a client with `securecallfunction`, EventKit isolates each listener
---through it, and the client reports the failure to the handler
---`seterrorhandler` installed; the global `geterrorhandler` is only its reader
---there, so replacing that global would neither catch the failure nor keep the
---error window closed, and would taint a global Blizzard code calls. The
---handler is therefore swapped with `seterrorhandler`. Without
---`securecallfunction`, EventKit's `xpcall` path asks `geterrorhandler()` on
---every failure, so replacing that global for the test is enough. The swap
---spans the wait for the event, so a failure of another addon in that window
---reaches the collector too; the test counts only its own marker.
---@param ctx TestKit.Context
---@return any[] reported every value the collector receives, in order
---@return boolean observed whether the collector is the handler EventKit reports to
---@return fun() restore puts the previous handler back; safe to call twice
local function collectReportedErrors(ctx)
    local reported = {}
    ---@param message any
    local function collector(message)
        reported[#reported + 1] = message
    end

    local restore = function() end
    local observed = false
    if type(readHost("securecallfunction")) == "function" then
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
    else
        -- The global is replaced for this test only; TestKit puts it back.
        -- selene: allow(global_usage)
        ctx:Replace(_G, "geterrorhandler", function()
            return collector
        end)
        observed = true
    end
    pendingRestores[#pendingRestores + 1] = restore
    return reported, observed, restore
end

-- eventKit.facade ---------------------------------------------------------------------------

local facade = newSuite("facade")

facade:Test(
    "Registry:Get('eventKit', 1) is the EventKit facade with API 1, every documented method and UNBOUNDED",
    function(ctx)
        ctx:Expect(type(EventKit)):ToBe("table")
        ctx:Expect(rawget(EventKit, "API")):ToBe(EVENT_KIT_API)
        for _, method in ipairs(FACADE_METHODS) do
            ctx:Expect(type(EventKit[method])):ToBe("function")
        end
        ctx:Expect(type(EventKit.UNBOUNDED)):ToBe("table")
    end
)

facade:Test("the installed EventKit carries the revision of the committed manifest", function(ctx)
    local expectedPackages = Harness:GetExpectedPackages()
    if type(expectedPackages) == "nil" then
        ctx:Fail("Expected.lua is missing; install with python3 -m tooling.client.install")
        return
    end
    for _, expected in ipairs(expectedPackages) do
        if expected.id == PACKAGE_ID then
            local _, revision = Registry:Get(PACKAGE_ID, EVENT_KIT_API)
            ctx:Expect(revision):ToBe(expected.revision)
            ctx:Expect(rawget(EventKit, "REVISION")):ToBe(expected.revision)
            return
        end
    end
    ctx:Fail("Expected.lua does not list eventKit")
end)

-- eventKit.dispatch -------------------------------------------------------------------------

local dispatch = newSuite("dispatch")

dispatch:Test(
    "a C_CVar.SetCVar change reaches two Connect listeners in connection order with the CVar name and the new value",
    function(ctx)
        local deliveries = {}
        ---@param label string
        ---@return EventKit.Listener
        local function recordAs(label)
            return function(eventName, cvarName, value)
                if namesProbeCVar(cvarName) then
                    deliveries[#deliveries + 1] = {
                        label = label,
                        eventName = eventName,
                        cvarName = cvarName,
                        value = value,
                    }
                end
            end
        end
        track(EventKit:Connect(CVAR_EVENT, recordAs("first")))
        track(EventKit:Connect(CVAR_EVENT, recordAs("second")))

        local written = flipProbeCVar(ctx)
        ctx:Log("delivered before SetCVar returned: " .. tostring(#deliveries > 0))
        local arrived = waitUntil(ctx, function()
            return #deliveries >= 2
        end, LOCAL_EVENT_TIMEOUT_SECONDS)
        if not arrived then
            ctx:Fail(
                ("no CVAR_UPDATE naming %s reached both listeners within %d seconds"):format(
                    PROBE_CVAR,
                    LOCAL_EVENT_TIMEOUT_SECONDS
                )
            )
        end

        ctx:Log(
            ("payload: %s, %s"):format(
                describeFact(deliveries[1].cvarName),
                describeFact(deliveries[1].value)
            )
        )
        ctx:Expect(#deliveries):ToBe(2)
        ctx:Expect(deliveries[1].label):ToBe("first")
        ctx:Expect(deliveries[2].label):ToBe("second")
        ctx:Expect(deliveries[1].eventName):ToBe(CVAR_EVENT)
        ctx:Expect(deliveries[1].value):ToBe(written)
        ctx:Expect(deliveries[2].value):ToBe(written)
    end
)

dispatch:Test(
    "a Once listener runs for the first CVAR_UPDATE only and is already disconnected inside its callback",
    function(ctx)
        local onceCalls = 0
        local connectedInsideCallback = nil
        local onceConnection = nil
        local onceListener = probeListener(function()
            onceCalls = onceCalls + 1
            connectedInsideCallback = onceConnection and onceConnection:IsConnected()
        end)
        onceConnection = track(EventKit:Once(CVAR_EVENT, onceListener))

        local controlCalls = 0
        local controlListener, otherCount = probeListener(function()
            controlCalls = controlCalls + 1
        end)
        track(EventKit:Connect(CVAR_EVENT, controlListener))

        flipProbeCVar(ctx)
        ctx:Expect(waitUntil(ctx, function()
            return controlCalls >= 1
        end, LOCAL_EVENT_TIMEOUT_SECONDS)):ToBe(true)
        flipProbeCVar(ctx)
        ctx:Expect(waitUntil(ctx, function()
            return controlCalls >= 2
        end, LOCAL_EVENT_TIMEOUT_SECONDS)):ToBe(true)

        ctx:Log(("other CVAR_UPDATE events seen meanwhile: %d"):format(otherCount()))
        ctx:Expect(onceCalls):ToBe(1)
        ctx:Expect(connectedInsideCallback):ToBe(false)
        ctx:Expect(onceConnection:IsConnected()):ToBe(false)
    end
)

dispatch:Test(
    "TIME_PLAYED_MSG, the server's reply to RequestTimePlayed, reaches a Once listener with two numbers",
    function(ctx)
        local requestTimePlayed = readHost("RequestTimePlayed")
        if type(requestTimePlayed) ~= "function" then
            ctx:Fail("the client has no RequestTimePlayed")
            return
        end

        local received = nil
        track(EventKit:Once(TIME_PLAYED_EVENT, function(eventName, total, thisLevel)
            received = { eventName = eventName, total = total, thisLevel = thisLevel }
        end))
        requestTimePlayed()
        local arrived = waitUntil(ctx, function()
            return type(received) ~= "nil"
        end, SERVER_EVENT_TIMEOUT_SECONDS)
        if not arrived or type(received) == "nil" then
            ctx:Fail(
                ("no TIME_PLAYED_MSG within %d seconds of RequestTimePlayed"):format(
                    SERVER_EVENT_TIMEOUT_SECONDS
                )
            )
            return
        end

        ctx:Log(
            ("payload: %s, %s"):format(
                describeFact(received.total),
                describeFact(received.thisLevel)
            )
        )
        ctx:Expect(received.eventName):ToBe(TIME_PLAYED_EVENT)
        ctx:Expect(type(received.total)):ToBe("number")
        ctx:Expect(type(received.thisLevel)):ToBe("number")
        ctx:Expect(received.total >= received.thisLevel):ToBe(true)
    end
)

-- eventKit.isolation ------------------------------------------------------------------------

local isolation = newSuite("isolation")

isolation:Test(
    "a raising listener is reported once to the client's error handler, naming EventKitSuite.lua, and the next listener still runs",
    function(ctx)
        local calls = {}
        local failingLine = 0
        track(EventKit:Connect(CVAR_EVENT, (probeListener(function()
            calls[#calls + 1] = "before"
        end))))
        track(EventKit:Connect(CVAR_EVENT, (probeListener(function()
            calls[#calls + 1] = "failing"
            failingLine = currentLine()
            error(LISTENER_FAILURE)
        end))))
        track(EventKit:Connect(CVAR_EVENT, (probeListener(function()
            calls[#calls + 1] = "after"
        end))))

        local reported, observed, restoreHandler = collectReportedErrors(ctx)
        flipProbeCVar(ctx)
        local arrived = waitUntil(ctx, function()
            return #calls >= 3
        end, LOCAL_EVENT_TIMEOUT_SECONDS)
        restoreHandler()

        ctx:Log(
            "securecallfunction present: "
                .. tostring(type(readHost("securecallfunction")) == "function")
        )
        ctx:Expect(arrived):ToBe(true)
        ctx:Expect(calls):ToEqual({ "before", "failing", "after" })
        if not observed then
            ctx:Fail(
                "the client's error handler could not be replaced (an error-capturing addon such as BugGrabber keeps it); the failure went to that addon"
            )
            return
        end

        local ownReports = {}
        for _, message in ipairs(reported) do
            if
                type(message) == "string"
                and not isSecret(message)
                and message:sub(-#LISTENER_FAILURE) == LISTENER_FAILURE
            then
                ownReports[#ownReports + 1] = message
            end
        end
        ctx:Log(
            ("the collector received %d report(s), %d of them this test's"):format(
                #reported,
                #ownReports
            )
        )
        ctx:Expect(#ownReports):ToBe(1)
        ctx:Log("reported: " .. tostring(ownReports[1]))
        local line = expectThisFile(ctx, ownReports[1])
        ctx:Expect(line):ToBe(failingLine + 1)
    end
)

-- eventKit.registration ---------------------------------------------------------------------

local registration = newSuite("registration")

--- Why the registration tests are skipped on a client without the function.
local REGISTRATIONS_SKIP_REASON =
    "the client has no GetFramesRegisteredForEvent; the host registration was not read back"

---Register `body` as a test when the client lists registered frames, and as a
---skipped test naming why otherwise.
---@param name string
---@param body fun(ctx: TestKit.Context)
local function registrationTest(name, body)
    if REGISTRATIONS_READABLE then
        registration:Test(name, body)
    else
        registration:Skip(name, REGISTRATIONS_SKIP_REASON)
    end
end

registrationTest(
    "the first Connect registers CVAR_UPDATE on one frame, a second listener shares it, and the last Disconnect unregisters it",
    function(ctx)
        local before = registeredFrameSet(CVAR_EVENT)

        local first = track(EventKit:Connect(CVAR_EVENT, ignore))
        local added = framesAddedSince(CVAR_EVENT, before)
        ctx:Log(("frames added by the first Connect: %d"):format(#added))
        ctx:Expect(#added):ToBe(1)
        local frame = added[1]
        ctx:Expect((frame:IsEventRegistered(CVAR_EVENT))):ToBe(true)

        local second = track(EventKit:Connect(CVAR_EVENT, ignore))
        local addedAfterSecond = framesAddedSince(CVAR_EVENT, before)
        ctx:Expect(#addedAfterSecond):ToBe(1)
        ctx:Expect(addedAfterSecond[1] == frame):ToBe(true)

        ctx:Expect(first:Disconnect()):ToBe(true)
        ctx:Expect((frame:IsEventRegistered(CVAR_EVENT))):ToBe(true)

        ctx:Expect(second:Disconnect()):ToBe(true)
        ctx:Expect((frame:IsEventRegistered(CVAR_EVENT))):ToBe(false)
        ctx:Expect(#framesAddedSince(CVAR_EVENT, before)):ToBe(0)
    end
)

registrationTest(
    "ConnectUnit with player registers PLAYER_FLAGS_CHANGED filtered to player, and Disconnect unregisters it",
    function(ctx)
        local before = registeredFrameSet(UNIT_EVENT)

        local connection = track(EventKit:ConnectUnit(UNIT_EVENT, ignore, "player"))
        local added = framesAddedSince(UNIT_EVENT, before)
        ctx:Log(("frames added by ConnectUnit: %d"):format(#added))
        ctx:Expect(#added):ToBe(1)
        local frame = added[1]
        local registered, firstUnit, secondUnit = frame:IsEventRegistered(UNIT_EVENT)
        ctx:Log(
            ("IsEventRegistered answered %s, %s, %s"):format(
                describeFact(registered),
                describeFact(firstUnit),
                describeFact(secondUnit)
            )
        )
        ctx:Expect(registered):ToBe(true)
        ctx:Expect(firstUnit):ToBe("player")
        ctx:Expect(secondUnit):ToBeNil()

        ctx:Expect(connection:Disconnect()):ToBe(true)
        ctx:Expect((frame:IsEventRegistered(UNIT_EVENT))):ToBe(false)
        ctx:Expect(#framesAddedSince(UNIT_EVENT, before)):ToBe(0)
    end
)

-- eventKit.units ----------------------------------------------------------------------------

local units = newSuite("units")

units:Test(
    "toggling Do Not Disturb delivers PLAYER_FLAGS_CHANGED to a player ConnectUnit listener and not to a party1 one",
    function(ctx)
        local unitIsDoNotDisturb = readHost("UnitIsDND")
        local unitIsAway = readHost("UnitIsAFK")
        local sendChatMessage = readHostFunction("C_ChatInfo", "SendChatMessage")
            or readHost("SendChatMessage")
        if
            type(unitIsDoNotDisturb) ~= "function"
            or type(unitIsAway) ~= "function"
            or type(sendChatMessage) ~= "function"
        then
            ctx:Fail("the client lacks UnitIsDND, UnitIsAFK or C_ChatInfo.SendChatMessage")
            return
        end
        if unitIsAway("player") == true then
            ctx:Fail("the character is away (AFK); clear it and run again")
            return
        end

        ---Toggle the Do Not Disturb flag, exactly as typing /dnd does.
        local function toggleDoNotDisturb()
            sendChatMessage("", "DND")
        end
        local original = unitIsDoNotDisturb("player") == true
        ctx:Log("Do Not Disturb at the start: " .. tostring(original))
        pendingRestores[#pendingRestores + 1] = function()
            if (unitIsDoNotDisturb("player") == true) ~= original then
                toggleDoNotDisturb()
            end
        end

        local playerUnits = {}
        track(EventKit:ConnectUnit(UNIT_EVENT, function(_, unit)
            playerUnits[#playerUnits + 1] = unit
        end, "player"))
        local partyCalls = 0
        track(EventKit:ConnectUnit(UNIT_EVENT, function()
            partyCalls = partyCalls + 1
        end, "party1"))

        toggleDoNotDisturb()
        ctx:Expect(waitUntil(ctx, function()
            return #playerUnits >= 1
        end, SERVER_EVENT_TIMEOUT_SECONDS)):ToBe(true)

        toggleDoNotDisturb()
        ctx:Expect(waitUntil(ctx, function()
            return #playerUnits >= 2 and (unitIsDoNotDisturb("player") == true) == original
        end, SERVER_EVENT_TIMEOUT_SECONDS)):ToBe(true)

        ctx:Log(("player deliveries: %d, party1 deliveries: %d"):format(#playerUnits, partyCalls))
        ctx:Expect(playerUnits[1]):ToBe("player")
        ctx:Expect(partyCalls):ToBe(0)
    end
)

-- eventKit.scopes ---------------------------------------------------------------------------

local scopes = newSuite("scopes")

scopes:Test(
    "a scope's DisconnectAll ends its connections before the next event, and Close is terminal",
    function(ctx)
        local scope = EventKit:CreateScope()
        trackClosable(scope)
        local scopedCalls = 0
        local function countScoped()
            scopedCalls = scopedCalls + 1
        end
        scope:Connect(CVAR_EVENT, countScoped)
        scope:ConnectUnit(UNIT_EVENT, countScoped, "player")
        ctx:Expect(scope:GetActiveCount()):ToBe(2)
        ctx:Expect(scope:DisconnectAll()):ToBe(2)
        ctx:Expect(scope:GetActiveCount()):ToBe(0)

        local controlCalls = 0
        track(EventKit:Connect(CVAR_EVENT, (probeListener(function()
            controlCalls = controlCalls + 1
        end))))
        flipProbeCVar(ctx)
        ctx:Expect(waitUntil(ctx, function()
            return controlCalls >= 1
        end, LOCAL_EVENT_TIMEOUT_SECONDS)):ToBe(true)
        ctx:Expect(scopedCalls):ToBe(0)

        ctx:Expect(scope:Close()):ToBe(true)
        ctx:Expect(scope:Close()):ToBe(false)
        ctx:Expect(scope:IsClosed()):ToBe(true)
    end
)

scopes:Test("a closed scope refuses Connect at the calling line", function(ctx)
    local scope = EventKit:CreateScope()
    ctx:Expect(scope:Close()):ToBe(true)
    local startLine = 0
    local line = expectErrorAtCallingLine(ctx, function()
        startLine = currentLine()
        scope:Connect(CVAR_EVENT, ignore)
    end, "EventKit.Scope:Connect cannot connect in a closed scope")
    ctx:Expect(line):ToBe(startLine + 1)
    ctx:Expect(scope:GetActiveCount()):ToBe(0)
end)

scopes:Test(
    "ForAddon with this test addon's name returns one open scope that names the addon",
    function(ctx)
        local addonScope = EventKit:ForAddon(addonName)
        ctx:Expect(EventKit:ForAddon(addonName)):ToBe(addonScope)
        ctx:Expect(addonScope:GetAddonName()):ToBe(addonName)
        ctx:Expect(addonScope:IsClosed()):ToBe(false)
        -- The addon scope stays open for the session (LifecycleKit closes it at
        -- logout), so the After hook empties it rather than closing it.
        pendingReleases[#pendingReleases + 1] = function()
            addonScope:DisconnectAll()
        end

        local before = addonScope:GetActiveCount()
        addonScope:Connect(CVAR_EVENT, ignore)
        ctx:Expect(addonScope:GetActiveCount()):ToBe(before + 1)
        ctx:Expect(addonScope:DisconnectAll()):ToBe(before + 1)
        ctx:Expect(addonScope:GetActiveCount()):ToBe(0)
    end
)

-- eventKit.coalesce -------------------------------------------------------------------------

local coalesce = newSuite("coalesce")

--- Why the coalesce tests are skipped without SchedulerKit.
local COALESCE_SKIP_REASON =
    "SchedulerKit API 1 is not loaded; Coalesce and Derive were not exercised"

---Register `body` as a test when SchedulerKit is loaded, and as a skipped test
---naming why otherwise.
---@param name string
---@param body fun(ctx: TestKit.Context)
local function coalesceTest(name, body)
    if SCHEDULER_KIT_LOADED then
        coalesce:Test(name, body)
    else
        coalesce:Skip(name, COALESCE_SKIP_REASON)
    end
end

coalesceTest(
    "Coalesce delivers two CVar changes inside one 0.25-second interval as one callback keyed by event name",
    function(ctx)
        local deliveries = {}
        trackClosable(EventKit:Coalesce(CVAR_EVENT, COALESCE_INTERVAL_SECONDS, function(set)
            -- The set is reused after the callback returns, so it is copied.
            local keys = {}
            for key in pairs(set) do
                keys[#keys + 1] = key
            end
            deliveries[#deliveries + 1] = keys
        end, { byEvent = true }))

        flipProbeCVar(ctx)
        flipProbeCVar(ctx)
        ctx:Expect(waitUntil(ctx, function()
            return #deliveries >= 1
        end, LOCAL_EVENT_TIMEOUT_SECONDS)):ToBe(true)
        local second = waitUntil(ctx, function()
            return #deliveries >= 2
        end, COALESCE_QUIET_SECONDS)

        ctx:Log(("deliveries: %d"):format(#deliveries))
        ctx:Expect(second):ToBe(false)
        ctx:Expect(deliveries[1]):ToEqual({ CVAR_EVENT })
    end
)

coalesceTest(
    "Derive recomputes after a CVar change and OnChange reports the new and the previous value",
    function(ctx)
        local original = readProbeCVar(ctx)
        local derived = EventKit:Derive(CVAR_EVENT, currentProbeValue)
        trackClosable(derived)
        ctx:Expect(derived:Get()):ToBe(original)

        local changes = {}
        derived:OnChange(function(value, previous)
            changes[#changes + 1] = { value = value, previous = previous }
        end)

        local written = flipProbeCVar(ctx)
        ctx:Expect(waitUntil(ctx, function()
            return derived:Get() == written
        end, LOCAL_EVENT_TIMEOUT_SECONDS)):ToBe(true)
        ctx:Expect(changes):ToEqual({ { value = written, previous = original } })

        ctx:Expect(derived:Close()):ToBe(true)
        ctx:Expect(derived:IsClosed()):ToBe(true)
    end
)

-- eventKit.errors ---------------------------------------------------------------------------

local errors = newSuite("errors")

errors:Test(
    "Connect with an event name that is not a string names EventKitSuite.lua at the calling line",
    function(ctx)
        -- The wrong argument type is the point of the test.
        ---@type any
        local notAnEventName = 42
        local startLine = 0
        local line = expectErrorAtCallingLine(ctx, function()
            startLine = currentLine()
            EventKit:Connect(notAnEventName, ignore)
        end, "EventKit:Connect eventName must be a non-empty string")
        ctx:Expect(line):ToBe(startLine + 1)
    end
)

errors:Test(
    "ConnectUnit with three distinct unit tokens is refused at the calling line",
    function(ctx)
        -- The third token is the point of the test.
        ---@type any
        local connectUnit = EventKit.ConnectUnit
        local startLine = 0
        local line = expectErrorAtCallingLine(
            ctx,
            function()
                startLine = currentLine()
                connectUnit(EventKit, UNIT_EVENT, ignore, "player", "target", "focus")
            end,
            "EventKit:ConnectUnit accepts at most 2 distinct unit tokens because Frame:RegisterUnitEvent has 2 filter slots; received 3"
        )
        ctx:Expect(line):ToBe(startLine + 1)
    end
)

errors:Test(
    "Connect to an event name the client does not know is refused on every attempt, at the calling line where the client can tell, and caches nothing",
    function(ctx)
        local isEventValid = readHostFunction("C_EventUtils", "IsEventValid")
        if type(isEventValid) == "function" then
            ctx:Log(
                "C_EventUtils.IsEventValid("
                    .. UNKNOWN_EVENT
                    .. ") answered "
                    .. describeFact(isEventValid(UNKNOWN_EVENT))
            )
        else
            ctx:Log("the client has no C_EventUtils.IsEventValid")
        end

        -- A second attempt refused again proves no channel was kept from the
        -- first.
        for attempt = 1, 2 do
            if type(isEventValid) == "function" then
                -- Documented: EventKit asks the client and refuses the name
                -- itself, at the calling line, before registering anything.
                local startLine = 0
                local line = expectErrorAtCallingLine(ctx, function()
                    startLine = currentLine()
                    track(EventKit:Connect(UNKNOWN_EVENT, ignore))
                end, UNKNOWN_EVENT_MESSAGE)
                ctx:Expect(line):ToBe(startLine + 1)
            else
                -- Documented: without the function the client's RegisterEvent
                -- is the authority, and its refusal reaches the caller.
                local succeeded, problem = pcall(EventKit.Connect, EventKit, UNKNOWN_EVENT, ignore)
                if succeeded then
                    track(problem)
                end
                ctx:Log(("attempt %d: %s"):format(attempt, describeFact(problem)))
                ctx:Expect(succeeded):ToBe(false)
            end
        end

        local connection = track(EventKit:Connect(CVAR_EVENT, ignore))
        ctx:Expect(connection:IsConnected()):ToBe(true)
        ctx:Expect(connection:Disconnect()):ToBe(true)
    end
)

-- eventKit.combatLog ------------------------------------------------------------------------

local combatLog = newSuite("combatLog")

---Log whether one client function exists, and return it.
---@param ctx TestKit.Context
---@param label string how the log names the function
---@param candidate any
---@return function|nil
local function logFunctionFact(ctx, label, candidate)
    if type(candidate) == "function" then
        ctx:Log(label .. ": present")
        return candidate
    end
    ctx:Log(label .. ": absent")
    return nil
end

---Call a client function under `pcall` and log what happened, without
---comparing or printing any value it returned.
---@param ctx TestKit.Context
---@param label string
---@param candidate function
local function logCallFact(ctx, label, candidate)
    local outcome = { pcall(candidate) }
    if outcome[1] then
        ctx:Log(("%s returned %d value(s)"):format(label, #outcome - 1))
    else
        ctx:Log(label .. " raised: " .. describeFact(outcome[2]))
    end
end

combatLog:Test(
    "ConnectCombatLog does what docs/API.md documents for the combat-log reader this client has (every fact is logged)",
    function(ctx)
        local globalReader = logFunctionFact(
            ctx,
            "CombatLogGetCurrentEventInfo",
            readHost("CombatLogGetCurrentEventInfo")
        )
        local namespacedReader = logFunctionFact(
            ctx,
            "C_CombatLog.GetCurrentEventInfo",
            readHostFunction("C_CombatLog", "GetCurrentEventInfo")
        )
        local internalReader = logFunctionFact(
            ctx,
            "C_CombatLogInternal.GetCurrentEventInfo",
            readHostFunction("C_CombatLogInternal", "GetCurrentEventInfo")
        )
        logFunctionFact(
            ctx,
            "C_CombatLogSecure.GetCurrentEventInfo",
            readHostFunction("C_CombatLogSecure", "GetCurrentEventInfo")
        )
        if type(internalReader) ~= "nil" then
            ---@cast internalReader function
            logCallFact(ctx, "C_CombatLogInternal.GetCurrentEventInfo()", internalReader)
        end
        local isRestricted = readHostFunction("C_CombatLog", "IsCombatLogRestricted")
        if type(isRestricted) ~= "nil" then
            ---@cast isRestricted function
            local succeeded, restricted = pcall(isRestricted)
            ctx:Log(
                "C_CombatLog.IsCombatLogRestricted() "
                    .. (succeeded and "answered " or "raised: ")
                    .. describeFact(restricted)
            )
        else
            ctx:Log("C_CombatLog.IsCombatLogRestricted: absent")
        end

        local readerAvailable = type(globalReader) ~= "nil" or type(namespacedReader) ~= "nil"
        ctx:Log("EventKit finds a reader: " .. tostring(readerAvailable))
        -- Documented: IsCombatLogAvailable answers exactly whether a reader exists.
        local reported = EventKit:IsCombatLogAvailable()
        ctx:Log("EventKit:IsCombatLogAvailable() answered " .. describeFact(reported))
        ctx:Expect(reported):ToBe(readerAvailable)

        local before = nil
        if REGISTRATIONS_READABLE then
            local listed, frames = pcall(registeredFrameSet, COMBAT_LOG_EVENT)
            if listed then
                before = frames
            else
                ctx:Log(
                    "GetFramesRegisteredForEvent(COMBAT_LOG_EVENT_UNFILTERED) raised: "
                        .. tostring(frames)
                )
            end
        end

        for attempt = 1, 2 do
            if readerAvailable then
                local succeeded, result = pcall(EventKit.ConnectCombatLog, EventKit, "*", ignore)
                ctx:Log(
                    ("ConnectCombatLog attempt %d: %s"):format(
                        attempt,
                        succeeded and "connected" or ("raised " .. describeFact(result))
                    )
                )
                if succeeded then
                    local connection = track(result)
                    -- Documented: with a reader, the listener connects like any other.
                    ctx:Expect(connection:IsConnected()):ToBe(true)
                    ctx:Expect(connection:Disconnect()):ToBe(true)
                else
                    -- Documented: the running client is authoritative, and a
                    -- registration it refuses is raised to the caller.
                    ctx:Expect(type(result)):ToBe("string")
                end
            else
                -- Documented: without a reader the call is refused at the
                -- calling line, on every attempt, and registers nothing.
                local startLine = 0
                local line = expectErrorAtCallingLine(ctx, function()
                    startLine = currentLine()
                    track(EventKit:ConnectCombatLog("*", ignore))
                end, MISSING_READER_MESSAGE)
                ctx:Expect(line):ToBe(startLine + 1)
            end
        end

        if type(before) ~= "nil" then
            ---@cast before table<any, boolean>
            ctx:Expect(#framesAddedSince(COMBAT_LOG_EVENT, before)):ToBe(0)
        end
    end
)

-- eventKit.allocation -----------------------------------------------------------------------

local allocation = newSuite("allocation")

allocation:Skip(
    "dispatch allocates nothing per event (allocation guard)",
    "not measurable here without side effects: EventKit has no public dispatch entry point, and no harmless event can be raised thousands of times without the client's own handlers allocating; packages/eventKit/tests guards it"
)
