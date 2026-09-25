-- MoltenCodes Test: SignalKitSuite.lua
--
-- Real-client suites for the `signalKit` package. The Busted specs under
-- packages/signalKit/tests/ prove SignalKit on a stock Lua 5.1 with a fake
-- client; these prove, inside the game client with the installed MoltenCodes
-- addon, what that fixture can only simulate:
--
--   * the installed facade and its committed revision;
--   * listener order and re-entrancy (connect, disconnect, DisconnectAll and a
--     nested Fire during dispatch, Once) on the client's own Lua;
--   * the `onFirst` / `onLast` hooks, `GetGeneration` and journals;
--   * that `Fire`, a journal's `Fire` and a `History()` walk allocate nothing,
--     measured with the client's own garbage collector;
--   * named buses: declared topics, argument-count and validator refusals at
--     the publishing line, a scope's teardown, `ForAddon` with this addon's
--     name, and listener error isolation through the client's real
--     `securecallfunction` and error handler;
--   * argument errors pointing at this file as the client names it;
--   * secret values, when the client can make one without side effects.
--
-- Run with `/mct run signalKit`; tests/client/MoltenCodesTest_SignalKit/EXPECTED.md
-- lists what the chat frame should show.
--
-- What a run leaves behind. Every connection a test makes is tracked and
-- disconnected by the After hook of its suite, whatever the test's outcome, so
-- nothing stays subscribed. Two named buses stay in the session, because
-- SignalKit never frees a bus: `mctSignalKitProbe` and this addon's own bus
-- (`SignalKit:ForAddon(addonName)`), which LifecycleKit closes at logout. Their
-- declared topics stay declared; re-declaring them on a later run in the same
-- session is accepted because the policy is the same (the validators below are
-- created once, at load). The one test that needs a topic declared after its
-- subscription uses a fresh topic name per run (`Early1`, `Early2`, ...). The
-- client's error handler is replaced only for the length of one `Publish` and
-- put back at once. Nothing is written to a global or a saved variable.

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
local SIGNAL_KIT_API = 1
local PACKAGE_ID = "signalKit"

--- The shared bus every probe topic lives on. It is created with declared
--- topics, the default, so an undeclared publish is refused.
local PROBE_BUS_NAME = "mctSignalKitProbe"

--- How many times each allocation guard fires or walks. One table or closure
--- per call would cost well over a hundred kilobytes at these counts.
local FIRE_CALLS = 10000
local HISTORY_WALKS = 2000

--- Slots of the journal the allocation guards use; every walk visits all of them.
local GUARD_JOURNAL_CAPACITY = 16

--- Kilobytes an allocation guard tolerates. The tolerance absorbs a stray
--- allocation by the client between the two readings, not a per-call one.
local ALLOCATION_TOLERANCE_KB = 1

--- Text a deliberately failing listener raises, so a test can recognise it.
local LISTENER_FAILURE = "mctSignalKit deliberate listener failure"

--- Text a deliberately failing validator raises.
local VALIDATOR_FAILURE = "mctSignalKit deliberate validator failure"

--- Every method docs/API.md of signalKit lists on the facade.
local FACADE_METHODS = {
  "New",
  "NewJournal",
  "Bus",
  "ForAddon",
  "CloseAddonBus",
  "SetLimits",
  "GetLimits",
}

---Read a client global, or `nil`.
---@param name string
---@return any
local function readHost(name)
  -- Error handling and secret-value functions are World of Warcraft client
  -- globals, reachable only through the global table.
  -- selene: allow(global_usage)
  return rawget(_G, name)
end

---@type Registry
local Registry = rawget(rawget(namespace, "Registries") or {}, REGISTRY_API)
if type(Registry) ~= "table" then
  error(addonName .. " requires the MoltenCodes addon (Registry API 2); reinstall it", 0)
end

---@type SignalKit|nil
local SignalKitOrNil = Registry:Get(PACKAGE_ID, SIGNAL_KIT_API)
if type(SignalKitOrNil) == "nil" then
  error(addonName .. " requires SignalKit API 1 in the MoltenCodes addon; reinstall it", 0)
end
---@cast SignalKitOrNil SignalKit
local SignalKit = SignalKitOrNil

--- The two client functions the secrets suite needs, read once at load: the
--- suite registers its tests as skipped when either is missing.
local isSecretValue = readHost("issecretvalue")
local secretWrap = readHost("secretwrap")
local SECRETS_AVAILABLE = type(isSecretValue) == "function" and type(secretWrap) == "function"

--- Whether the client also makes secrets with them: the Classic Era and Mists
--- Classic clients document both functions, so only the harness's measurement
--- (`issecretvalue(secretwrap(true))`) tells whether secrets are applied there.
local SECRETS_MADE = SECRETS_AVAILABLE and Harness:CanMakeSecrets()

-- Validators are created once, at load, so a later run in the same session
-- re-declares their topics with the same policy, which SignalKit accepts.

---Accept exactly one number; the refusal names the rule, never the value.
---@param ... any
---@return boolean accepted
---@return string|nil reason
local function acceptOneNumber(...)
  if select("#", ...) == 1 and type((...)) == "number" then
    return true
  end
  return false, "level must be a number"
end

---Raise, as a validator from another addon with a bug would.
---@return boolean
local function raiseInValidator()
  error(VALIDATOR_FAILURE)
end

---Answer with a secret verdict instead of `true`. Only reached when the
---client has `secretwrap`, because only the secrets suite declares it.
---@return any
local function answerWithSecretVerdict()
  return secretWrap(true)
end

-- Helpers ---------------------------------------------------------------------------

--- Connections made by the test that is running; the After hook of every suite
--- disconnects them, so a test that fails half-way leaves nothing connected.
---@type SignalKit.Connection[]
local trackedConnections = {}

--- Sequence of the fresh topic names the declare-after-subscribe test uses.
local earlyTopicSequence = 0

---Remember `connection` for the After hook and hand it back.
---@param connection SignalKit.Connection|nil
---@return SignalKit.Connection connection
local function track(connection)
  if type(connection) == "nil" then
    error("a SignalKit subscription was refused; is a bound full?", 2)
  end
  ---@cast connection SignalKit.Connection
  trackedConnections[#trackedConnections + 1] = connection
  return connection
end

---Disconnect every tracked connection. Registered as an After hook on every
---suite; `Disconnect` is idempotent, so a test may disconnect its own first.
local function disconnectTracked()
  for index = #trackedConnections, 1, -1 do
    trackedConnections[index]:Disconnect()
    trackedConnections[index] = nil
  end
end

---Register a suite of this package whose tests all end disconnected.
---@param part string
---@return TestKit.Suite
local function newSuite(part)
  local suite = Harness:Suite(PACKAGE_ID, part, addonName)
  suite:After(disconnectTracked)
  return suite
end

---The probe bus, created on first use with the default declared topics.
---@return SignalKit.Bus
local function probeBus()
  local bus, reason = SignalKit:Bus(PROBE_BUS_NAME)
  if type(bus) == "nil" then
    error("SignalKit:Bus refused the probe bus: " .. tostring(reason), 2)
  end
  ---@cast bus SignalKit.Bus
  return bus
end

---A callback that appends `label` to `calls` each time it runs.
---@param calls string[]
---@param label string
---@return fun()
local function recorder(calls, label)
  return function()
    calls[#calls + 1] = label
  end
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
  ctx:Expect((file or ""):sub(-#"SignalKitSuite.lua")):ToBe("SignalKitSuite.lua")
  return line
end

---Call `raise`, which must record its start line and raise on the next line,
---and check the message names this file and ends with `expected`.
---@param ctx TestKit.Context
---@param raise fun() Records its start line with `currentLine()`, then raises on the next line.
---@param expected string The message after the position, compared literally.
---@return integer|nil line The line the message names.
---@return string message The whole message, as the client raised it.
local function expectErrorAtCallingLine(ctx, raise, expected)
  local succeeded, message = pcall(raise)
  ctx:Expect(succeeded):ToBe(false)
  ctx:Log("client message: " .. tostring(message))

  local line = expectThisFile(ctx, message)
  ctx:Expect(tostring(message):sub(-#expected)):ToBe(expected)
  return line, tostring(message)
end

---Run `action`, which must not yield, with SignalKit's bus failures reported
---to a collector instead of the client's error handler, and put the handler
---back before returning.
---
---On a client with `securecallfunction`, SignalKit isolates each bus delivery
---through it, and the client reports the failure to the handler
---`seterrorhandler` installed; the global `geterrorhandler` is only its reader
---there, so replacing that global would neither catch the failure nor keep
---the error window closed, and would taint a global Blizzard code calls. The
---handler is therefore swapped with `seterrorhandler` for the call. Without
---`securecallfunction`, SignalKit's `xpcall` path asks `geterrorhandler()` on
---every failure, so replacing that global for the test is enough.
---@param ctx TestKit.Context
---@param action fun()
---@return any[] reported every value the collector received, in order
---@return boolean observed whether the collector was the handler SignalKit reported to
local function collectReportedErrors(ctx, action)
  local reported = {}
  ---@param message any
  local function collector(message)
    reported[#reported + 1] = message
  end

  local restore = nil
  local observed = false
  if type(readHost("securecallfunction")) == "function" then
    local setErrorHandler = readHost("seterrorhandler")
    local getErrorHandler = readHost("geterrorhandler")
    if type(setErrorHandler) == "function" and type(getErrorHandler) == "function" then
      local previous = getErrorHandler()
      setErrorHandler(collector)
      -- An error-capturing addon (BugGrabber) may refuse the swap.
      observed = getErrorHandler() == collector
      restore = function()
        setErrorHandler(previous)
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

  local succeeded, problem = pcall(action)
  if restore ~= nil then
    restore()
  end
  if not succeeded then
    error(problem, 0)
  end
  return reported, observed
end

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

---A no-op listener; the allocation guards connect several.
local function ignore() end

-- signalKit.facade ----------------------------------------------------------------------

local facade = newSuite("facade")

facade:Test(
  "Registry:Get('signalKit', 1) is the SignalKit facade with API 1, every documented method and UNBOUNDED",
  function(ctx)
    ctx:Expect(type(SignalKit)):ToBe("table")
    ctx:Expect(rawget(SignalKit, "API")):ToBe(SIGNAL_KIT_API)
    for _, method in ipairs(FACADE_METHODS) do
      ctx:Expect(type(SignalKit[method])):ToBe("function")
    end
    ctx:Expect(type(SignalKit.UNBOUNDED)):ToBe("table")
  end
)

facade:Test("the installed SignalKit carries the revision of the committed manifest", function(ctx)
  local expectedPackages = Harness:GetExpectedPackages()
  if type(expectedPackages) == "nil" then
    ctx:Fail("Expected.lua is missing; install with python3 -m tooling.client.install")
    return
  end
  for _, expected in ipairs(expectedPackages) do
    if expected.id == PACKAGE_ID then
      local _, revision = Registry:Get(PACKAGE_ID, SIGNAL_KIT_API)
      ctx:Expect(revision):ToBe(expected.revision)
      ctx:Expect(rawget(SignalKit, "REVISION")):ToBe(expected.revision)
      return
    end
  end
  ctx:Fail("Expected.lua does not list signalKit")
end)

-- signalKit.dispatch ----------------------------------------------------------------------

local dispatch = newSuite("dispatch")

dispatch:Test(
  "listeners run in connection order, and one function connected twice runs twice",
  function(ctx)
    local signal = SignalKit:New()
    local calls = {}
    local shared = recorder(calls, "shared")
    track(signal:Connect(recorder(calls, "first")))
    track(signal:Connect(shared))
    track(signal:Connect(recorder(calls, "third")))
    track(signal:Connect(shared))

    signal:Fire()
    ctx:Expect(calls):ToEqual({ "first", "shared", "third", "shared" })
  end
)

dispatch:Test("Fire forwards every argument, explicit nils included", function(ctx)
  local signal = SignalKit:New()
  local receivedCount = 0
  local receivedValues = {}
  track(signal:Connect(function(...)
    receivedCount = select("#", ...)
    receivedValues = { ... }
  end))

  signal:Fire(1, nil, "x", nil)
  ctx:Expect(receivedCount):ToBe(4)
  ctx:Expect(receivedValues[1]):ToBe(1)
  ctx:Expect(receivedValues[2]):ToBeNil()
  ctx:Expect(receivedValues[3]):ToBe("x")
  ctx:Expect(receivedValues[4]):ToBeNil()
end)

dispatch:Test(
  "a listener connected during Fire is not called by that Fire, only by the next",
  function(ctx)
    local signal = SignalKit:New()
    local calls = {}
    local late = recorder(calls, "late")
    local connectedLate = false
    track(signal:Connect(function()
      calls[#calls + 1] = "early"
      if not connectedLate then
        connectedLate = true
        track(signal:Connect(late))
      end
    end))

    signal:Fire()
    ctx:Expect(calls):ToEqual({ "early" })
    signal:Fire()
    ctx:Expect(calls):ToEqual({ "early", "early", "late" })
  end
)

dispatch:Test("a listener disconnected by an earlier listener during Fire is skipped", function(ctx)
  local signal = SignalKit:New()
  local calls = {}
  ---@type SignalKit.Connection
  local victim
  track(signal:Connect(function()
    calls[#calls + 1] = "first"
    victim:Disconnect()
  end))
  victim = track(signal:Connect(recorder(calls, "victim")))
  track(signal:Connect(recorder(calls, "last")))

  signal:Fire()
  ctx:Expect(calls):ToEqual({ "first", "last" })
  ctx:Expect(victim:IsConnected()):ToBe(false)
end)

dispatch:Test(
  "a nested Fire sees the listener set as it is when the nested call begins",
  function(ctx)
    local signal = SignalKit:New()
    local calls = {}
    local depth = 0
    ---@type SignalKit.Connection
    local middle
    track(signal:Connect(function()
      calls[#calls + 1] = "outer" .. depth
      if depth == 0 then
        depth = 1
        track(signal:Connect(recorder(calls, "added")))
        middle:Disconnect()
        signal:Fire()
      end
    end))
    middle = track(signal:Connect(recorder(calls, "middle")))

    signal:Fire()
    -- The nested Fire runs the first listener again and the one added just
    -- before it; the outer Fire skips the disconnected one and never
    -- reaches the one added during it.
    ctx:Expect(calls):ToEqual({ "outer0", "outer1", "added" })
  end
)

dispatch:Test(
  "DisconnectAll during Fire stops every listener that has not run and returns the count",
  function(ctx)
    local signal = SignalKit:New()
    local calls = {}
    local removed = nil
    track(signal:Connect(function()
      calls[#calls + 1] = "first"
      removed = signal:DisconnectAll()
    end))
    track(signal:Connect(recorder(calls, "second")))
    track(signal:Connect(recorder(calls, "third")))

    signal:Fire()
    ctx:Expect(calls):ToEqual({ "first" })
    ctx:Expect(removed):ToBe(3)
    signal:Fire()
    ctx:Expect(calls):ToEqual({ "first" })
  end
)

dispatch:Test(
  "Once disconnects before its callback, so a nested Fire from it does not run it again",
  function(ctx)
    local signal = SignalKit:New()
    local calls = {}
    ---@type SignalKit.Connection
    local onceConnection
    local connectedDuringCallback = nil
    onceConnection = track(signal:Once(function()
      calls[#calls + 1] = "once"
      connectedDuringCallback = onceConnection:IsConnected()
      signal:Fire()
    end))
    track(signal:Connect(recorder(calls, "always")))

    signal:Fire()
    ctx:Expect(calls):ToEqual({ "once", "always", "always" })
    ctx:Expect(connectedDuringCallback):ToBe(false)
    signal:Fire()
    ctx:Expect(calls):ToEqual({ "once", "always", "always", "always" })
  end
)

dispatch:Test(
  "a listener error reaches the Fire caller, stops that dispatch, and the signal stays usable",
  function(ctx)
    local signal = SignalKit:New()
    local calls = {}
    track(signal:Connect(recorder(calls, "before")))
    local failing = track(signal:Connect(function()
      error(LISTENER_FAILURE)
    end))
    track(signal:Connect(recorder(calls, "after")))

    local succeeded, message = pcall(signal.Fire, signal)
    ctx:Expect(succeeded):ToBe(false)
    ctx:Log("client message: " .. tostring(message))
    expectThisFile(ctx, message)
    ctx:Expect(tostring(message):sub(-#LISTENER_FAILURE)):ToBe(LISTENER_FAILURE)
    ctx:Expect(calls):ToEqual({ "before" })

    failing:Disconnect()
    signal:Fire()
    ctx:Expect(calls):ToEqual({ "before", "before", "after" })
  end
)

dispatch:Test(
  "Disconnect answers true once and false after, and IsConnected follows it",
  function(ctx)
    local signal = SignalKit:New()
    local connection = track(signal:Connect(ignore))
    ctx:Expect(connection:IsConnected()):ToBe(true)
    ctx:Expect(connection:Disconnect()):ToBe(true)
    ctx:Expect(connection:IsConnected()):ToBe(false)
    ctx:Expect(connection:Disconnect()):ToBe(false)
  end
)

-- signalKit.hooks ---------------------------------------------------------------------------

local hooks = newSuite("hooks")

---A signal whose hooks append to `calls` and remember the signal they received.
---@param calls string[]
---@return SignalKit.Signal signal
---@return table seen `seen.first` and `seen.last`: the signal each hook received last
local function hookedSignal(calls)
  local seen = {}
  local signal = SignalKit:New({
    onFirst = function(received)
      calls[#calls + 1] = "onFirst"
      seen.first = received
    end,
    onLast = function(received)
      calls[#calls + 1] = "onLast"
      seen.last = received
    end,
  })
  return signal, seen
end

hooks:Test(
  "onFirst runs when the live listener count goes from 0 to 1 and onLast when it goes back to 0",
  function(ctx)
    local calls = {}
    local signal, seen = hookedSignal(calls)

    local first = track(signal:Connect(ignore))
    ctx:Expect(calls):ToEqual({ "onFirst" })
    local second = track(signal:Connect(ignore))
    first:Disconnect()
    ctx:Expect(calls):ToEqual({ "onFirst" })
    second:Disconnect()
    ctx:Expect(calls):ToEqual({ "onFirst", "onLast" })
    track(signal:Connect(ignore))
    ctx:Expect(calls):ToEqual({ "onFirst", "onLast", "onFirst" })

    ctx:Expect(seen.first):ToBe(signal)
    ctx:Expect(seen.last):ToBe(signal)
    ctx:Expect(signal:GetGeneration()):ToBe(0)
  end
)

hooks:Test(
  "DisconnectAll runs onLast once however many listeners go, and not at all when none is connected",
  function(ctx)
    local calls = {}
    local signal = hookedSignal(calls)
    track(signal:Connect(ignore))
    track(signal:Connect(ignore))
    track(signal:Connect(ignore))

    ctx:Expect(signal:DisconnectAll()):ToBe(3)
    ctx:Expect(calls):ToEqual({ "onFirst", "onLast" })
    ctx:Expect(signal:DisconnectAll()):ToBe(0)
    ctx:Expect(calls):ToEqual({ "onFirst", "onLast" })
  end
)

hooks:Test(
  "a Once listener that is the last one runs onLast during Fire, before its own callback",
  function(ctx)
    local calls = {}
    local signal = hookedSignal(calls)
    track(signal:Once(recorder(calls, "once")))

    signal:Fire()
    ctx:Expect(calls):ToEqual({ "onFirst", "onLast", "once" })
  end
)

-- signalKit.journal -------------------------------------------------------------------------

local journal = newSuite("journal")

journal:Test(
  "GetGeneration counts every Fire, moves before listeners run, and ignores connects",
  function(ctx)
    local signal = SignalKit:New()
    ctx:Expect(signal:GetGeneration()):ToBe(0)

    local seenByListener = {}
    local connection = track(signal:Connect(function()
      seenByListener[#seenByListener + 1] = signal:GetGeneration()
    end))
    ctx:Expect(signal:GetGeneration()):ToBe(0)

    signal:Fire()
    signal:Fire()
    ctx:Expect(seenByListener):ToEqual({ 1, 2 })

    connection:Disconnect()
    track(signal:Connect(function()
      error(LISTENER_FAILURE)
    end))
    ctx:Expect(pcall(signal.Fire, signal)):ToBe(false)
    -- A firing whose listener raised still counts.
    ctx:Expect(signal:GetGeneration()):ToBe(3)
  end
)

journal:Test(
  "a journal keeps its last capacity firings, oldest to newest, with generations and explicit nils",
  function(ctx)
    local recent = SignalKit:NewJournal(3)
    recent:Fire("a")
    recent:Fire("b", nil)
    recent:Fire("c", nil, nil)
    recent:Fire("d")

    local walked = {}
    for position, entry in recent:History() do
      walked[#walked + 1] = {
        position = position,
        generation = entry.generation,
        count = entry.count,
        first = entry[1],
      }
    end
    ctx:Expect(walked):ToEqual({
      { position = 1, generation = 2, count = 2, first = "b" },
      { position = 2, generation = 3, count = 3, first = "c" },
      { position = 3, generation = 4, count = 1, first = "d" },
    })
    ctx:Expect(recent:GetGeneration()):ToBe(4)
  end
)

journal:Test(
  "a journal firing one argument over maxJournalArguments is refused at the calling line and records nothing",
  function(ctx)
    local recent = SignalKit:NewJournal(4)
    local calls = {}
    track(recent:Connect(recorder(calls, "listener")))
    recent:Fire("kept")

    local limit = SignalKit:GetLimits().maxJournalArguments
    local values = {}
    for index = 1, limit + 1 do
      values[index] = index
    end

    local startLine = 0
    local line = expectErrorAtCallingLine(
      ctx,
      function()
        startLine = currentLine()
        recent:Fire(unpack(values, 1, limit + 1))
      end,
      ("SignalKit.Journal:Fire records at most %d arguments per firing; received %d"):format(
        limit,
        limit + 1
      )
    )
    ctx:Expect(line):ToBe(startLine + 1)

    ctx:Expect(recent:GetGeneration()):ToBe(1)
    ctx:Expect(calls):ToEqual({ "listener" })
    local entries = 0
    for _ in recent:History() do
      entries = entries + 1
    end
    ctx:Expect(entries):ToBe(1)
  end
)

-- signalKit.allocation ----------------------------------------------------------------------

local allocation = newSuite("allocation")

allocation:Test(
  "Fire with three listeners connected allocates nothing over 10000 firings (allocation guard)",
  function(ctx)
    local signal = SignalKit:New()
    track(signal:Connect(ignore))
    track(signal:Connect(ignore))
    track(signal:Connect(ignore))
    collectBeforeMeasuring(ctx)

    -- Warm the path once, so the measurement sees steady state only.
    signal:Fire(1, "payload", true)
    local grownKilobytes = measureAllocation(function()
      for _ = 1, FIRE_CALLS do
        signal:Fire(1, "payload", true)
      end
    end)

    ctx:Log(("memory delta over %d firings: %.3f KB"):format(FIRE_CALLS, grownKilobytes))
    ctx:Expect(grownKilobytes <= ALLOCATION_TOLERANCE_KB):ToBe(true)
    ctx:Expect(signal:GetGeneration()):ToBe(FIRE_CALLS + 1)
  end
)

allocation:Test(
  "a journal Fire into a ring every slot of which has been used allocates nothing over 10000 firings",
  function(ctx)
    local recent = SignalKit:NewJournal(GUARD_JOURNAL_CAPACITY)
    track(recent:Connect(ignore))
    for _ = 1, GUARD_JOURNAL_CAPACITY do
      recent:Fire(1, "payload", true)
    end
    collectBeforeMeasuring(ctx)

    local grownKilobytes = measureAllocation(function()
      for _ = 1, FIRE_CALLS do
        recent:Fire(1, "payload", true)
      end
    end)

    ctx:Log(("memory delta over %d journal firings: %.3f KB"):format(FIRE_CALLS, grownKilobytes))
    ctx:Expect(grownKilobytes <= ALLOCATION_TOLERANCE_KB):ToBe(true)
  end
)

allocation:Test(
  "History walks over a full 16-entry journal allocate nothing over 2000 walks",
  function(ctx)
    local recent = SignalKit:NewJournal(GUARD_JOURNAL_CAPACITY)
    for _ = 1, GUARD_JOURNAL_CAPACITY do
      recent:Fire(1, "payload", true)
    end
    collectBeforeMeasuring(ctx)

    local visited = 0
    local grownKilobytes = measureAllocation(function()
      for _ = 1, HISTORY_WALKS do
        for _, entry in recent:History() do
          visited = visited + entry.count
        end
      end
    end)

    ctx:Log(("memory delta over %d walks: %.3f KB"):format(HISTORY_WALKS, grownKilobytes))
    ctx:Expect(grownKilobytes <= ALLOCATION_TOLERANCE_KB):ToBe(true)
    ctx:Expect(visited):ToBe(HISTORY_WALKS * GUARD_JOURNAL_CAPACITY * 3)
  end
)

-- signalKit.bus -----------------------------------------------------------------------------

local busSuite = newSuite("bus")

busSuite:Test(
  "a subscriber that subscribes before its topic is declared receives publishes once it is",
  function(ctx)
    local bus = probeBus()
    earlyTopicSequence = earlyTopicSequence + 1
    local topic = "Early" .. earlyTopicSequence
    local received = {}
    track(bus:Subscribe(topic, function(value)
      received[#received + 1] = value
    end))

    ctx:Expect(bus:DeclareTopic(topic, { arguments = 1 })):ToBe(true)
    bus:Publish(topic, "hello")
    ctx:Expect(received):ToEqual({ "hello" })
  end
)

busSuite:Test(
  "Publish of an undeclared topic is refused at the calling line and delivers nothing",
  function(ctx)
    local bus = probeBus()
    local calls = {}
    track(bus:Subscribe("NeverDeclared", recorder(calls, "subscriber")))

    local startLine = 0
    local line = expectErrorAtCallingLine(
      ctx,
      function()
        startLine = currentLine()
        bus:Publish("NeverDeclared", 1)
      end,
      'SignalKit.Bus:Publish topic "NeverDeclared" is not declared on bus "'
        .. PROBE_BUS_NAME
        .. '"; declare it with bus:DeclareTopic(topic, options) or create the bus with options.openTopics = true'
    )
    ctx:Expect(line):ToBe(startLine + 1)
    ctx:Expect(calls):ToEqual({})
  end
)

busSuite:Test(
  "Publish with the wrong argument count is refused at the calling line; the right count with a nil is delivered",
  function(ctx)
    local bus = probeBus()
    bus:DeclareTopic("Counted", { arguments = 2 })
    local counts = {}
    track(bus:Subscribe("Counted", function(...)
      counts[#counts + 1] = select("#", ...)
    end))

    local startLine = 0
    local line = expectErrorAtCallingLine(
      ctx,
      function()
        startLine = currentLine()
        bus:Publish("Counted", 1)
      end,
      'SignalKit.Bus:Publish topic "Counted" on bus "'
        .. PROBE_BUS_NAME
        .. '" refused its arguments: expected 2 arguments, got 1'
    )
    ctx:Expect(line):ToBe(startLine + 1)
    ctx:Expect(counts):ToEqual({})

    bus:Publish("Counted", 1, nil)
    ctx:Expect(counts):ToEqual({ 2 })
  end
)

busSuite:Test(
  "a validator's refusal reason is raised at the calling line and nothing is delivered",
  function(ctx)
    local bus = probeBus()
    bus:DeclareTopic("Validated", { arguments = acceptOneNumber })
    local received = {}
    track(bus:Subscribe("Validated", function(value)
      received[#received + 1] = value
    end))

    local startLine = 0
    local line = expectErrorAtCallingLine(
      ctx,
      function()
        startLine = currentLine()
        bus:Publish("Validated", "not a number")
      end,
      'SignalKit.Bus:Publish topic "Validated" on bus "'
        .. PROBE_BUS_NAME
        .. '" refused its arguments: level must be a number'
    )
    ctx:Expect(line):ToBe(startLine + 1)
    ctx:Expect(received):ToEqual({})

    bus:Publish("Validated", 60)
    ctx:Expect(received):ToEqual({ 60 })
  end
)

busSuite:Test(
  "a validator that raises becomes a refusal at the publishing line and nothing is delivered",
  function(ctx)
    local bus = probeBus()
    bus:DeclareTopic("RaisingValidator", { arguments = raiseInValidator })
    local calls = {}
    track(bus:Subscribe("RaisingValidator", recorder(calls, "subscriber")))

    local startLine = 0
    local line, message = expectErrorAtCallingLine(ctx, function()
      startLine = currentLine()
      bus:Publish("RaisingValidator", 1)
    end, VALIDATOR_FAILURE)
    ctx:Expect(line):ToBe(startLine + 1)
    local refusal = 'SignalKit.Bus:Publish validator for topic "RaisingValidator" on bus "'
      .. PROBE_BUS_NAME
      .. '" failed: '
    ctx:Expect(message:find(refusal, 1, true)).Not:ToBeNil()
    ctx:Expect(calls):ToEqual({})
  end
)

busSuite:Test(
  "a failing bus listener neither aborts the publisher nor stops the listeners behind it",
  function(ctx)
    local bus = probeBus()
    bus:DeclareTopic("Isolated", { arguments = 1 })
    local calls = {}
    track(bus:Subscribe("Isolated", recorder(calls, "before")))
    track(bus:Subscribe("Isolated", function()
      calls[#calls + 1] = "failing"
      error(LISTENER_FAILURE)
    end))
    track(bus:Subscribe("Isolated", recorder(calls, "after")))

    local reported = collectReportedErrors(ctx, function()
      bus:Publish("Isolated", 1)
      calls[#calls + 1] = "publisher continued"
    end)
    ctx:Log(("the collector received %d report(s)"):format(#reported))
    ctx:Expect(calls):ToEqual({ "before", "failing", "after", "publisher continued" })
  end
)

busSuite:Test(
  "a failing bus listener's error reaches the client's error handler once, naming SignalKitSuite.lua",
  function(ctx)
    local bus = probeBus()
    bus:DeclareTopic("Reported", { arguments = 0 })
    local failingLine = 0
    track(bus:Subscribe("Reported", function()
      failingLine = currentLine()
      error(LISTENER_FAILURE)
    end))
    track(bus:Subscribe("Reported", ignore))

    local reported, observed = collectReportedErrors(ctx, function()
      bus:Publish("Reported")
    end)
    ctx:Log(
      "securecallfunction present: " .. tostring(type(readHost("securecallfunction")) == "function")
    )
    if not observed then
      ctx:Fail(
        "the client's error handler could not be replaced (an error-capturing addon such as BugGrabber keeps it); the failure went to that addon"
      )
      return
    end
    ctx:Expect(#reported):ToBe(1)
    local message = reported[1]
    ctx:Log("reported: " .. tostring(message))
    local line = expectThisFile(ctx, message)
    ctx:Expect(line):ToBe(failingLine + 1)
    ctx:Expect(tostring(message):sub(-#LISTENER_FAILURE)):ToBe(LISTENER_FAILURE)
  end
)

busSuite:Test(
  "ForAddon with this test addon's name is the bus Bus returns for that name, on every call",
  function(ctx)
    local addonBus = SignalKit:ForAddon(addonName)
    ctx:Expect(type(addonBus)).Not:ToBe("nil")
    ctx:Expect(SignalKit:ForAddon(addonName)):ToBe(addonBus)
    ctx:Expect(SignalKit:Bus(addonName)):ToBe(addonBus)
    ---@cast addonBus SignalKit.Bus

    addonBus:DeclareTopic("ForAddonProbe", { arguments = 1 })
    local received = {}
    track(SignalKit:Bus(addonName):Subscribe("ForAddonProbe", function(value)
      received[#received + 1] = value
    end))
    addonBus:Publish("ForAddonProbe", "through ForAddon")
    ctx:Expect(received):ToEqual({ "through ForAddon" })
  end
)

busSuite:Test(
  "a bus scope's DisconnectAll ends every subscription it owns, and Close is terminal",
  function(ctx)
    local bus = probeBus()
    bus:DeclareTopic("Scoped", { arguments = 0 })
    local calls = {}
    local scope = bus:CreateScope()
    track(scope:Subscribe("Scoped", recorder(calls, "first")))
    track(scope:SubscribeOnce("Scoped", recorder(calls, "once")))

    ctx:Expect(scope:DisconnectAll()):ToBe(2)
    bus:Publish("Scoped")
    ctx:Expect(calls):ToEqual({})

    ctx:Expect(scope:Close()):ToBe(true)
    ctx:Expect(scope:Close()):ToBe(false)
    ctx:Expect(scope:IsClosed()):ToBe(true)
  end
)

-- signalKit.errors --------------------------------------------------------------------------

local errors = newSuite("errors")

errors:Test(
  "SignalKit.Connect called without a signal names SignalKitSuite.lua at the calling line",
  function(ctx)
    -- The missing receiver is the point of the test.
    ---@type any
    local connectWithoutReceiver = SignalKit.Connect
    local startLine = 0
    local line = expectErrorAtCallingLine(ctx, function()
      startLine = currentLine()
      connectWithoutReceiver(ignore)
    end, "SignalKit:Connect must be called on a signal instance; use signal:Connect(callback)")
    ctx:Expect(line):ToBe(startLine + 1)
  end
)

errors:Test(
  "Connect with a callback that is not a function names SignalKitSuite.lua at the calling line",
  function(ctx)
    local signal = SignalKit:New()
    -- The wrong argument type is the point of the test.
    ---@type any
    local notAFunction = "not a function"
    local startLine = 0
    local line = expectErrorAtCallingLine(ctx, function()
      startLine = currentLine()
      signal:Connect(notAFunction)
    end, "SignalKit:Connect callback must be a function")
    ctx:Expect(line):ToBe(startLine + 1)
  end
)

-- signalKit.secrets -------------------------------------------------------------------------

local secrets = newSuite("secrets")

--- Why the secrets tests are skipped on a client without the two functions.
local SECRETS_SKIP_REASON =
  "the client has no issecretvalue and secretwrap; the secret path was not exercised"

---Register `body` as a test when the client can make a secret value, and as a
---skipped test naming why otherwise: the functions are missing, or the client
---has them but `issecretvalue` does not report what `secretwrap` returns as
---secret (`Harness.NO_SECRETS_REASON`).
---@param name string
---@param body fun(ctx: TestKit.Context)
local function secretTest(name, body)
  if SECRETS_MADE then
    secrets:Test(name, body)
  elseif SECRETS_AVAILABLE then
    secrets:Skip(name, Harness.NO_SECRETS_REASON)
  else
    secrets:Skip(name, SECRETS_SKIP_REASON)
  end
end

---A genuine secret value made by the client's `secretwrap`, or a failed test.
---
---`secretwrap` is documented in the client's own API documentation
---(FrameScriptDocumentation, packages/apiKit/metadata/retail/namespaces.json)
---with no restriction and no side effect: it converts the values given to it.
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
  "a secret value published on a counted bus topic reaches the subscriber still secret",
  function(ctx)
    local bus = probeBus()
    bus:DeclareTopic("SecretPayload", { arguments = 1 })
    local secret = makeSecret(ctx, 42)
    local deliveries = 0
    local receivedCount = 0
    local receivedSecret = false
    track(bus:Subscribe("SecretPayload", function(...)
      deliveries = deliveries + 1
      receivedCount = select("#", ...)
      receivedSecret = isSecretValue((...)) == true
    end))

    bus:Publish("SecretPayload", secret)
    ctx:Expect(deliveries):ToBe(1)
    ctx:Expect(receivedCount):ToBe(1)
    ctx:Expect(receivedSecret):ToBe(true)
  end
)

secretTest(
  "a secret topic name is refused at the calling line before SignalKit compares it",
  function(ctx)
    local bus = probeBus()
    local secretTopic = makeSecret(ctx, "SecretTopic")
    local startLine = 0
    local line = expectErrorAtCallingLine(ctx, function()
      startLine = currentLine()
      bus:Subscribe(secretTopic, ignore)
    end, "SignalKit.Bus:Subscribe topic must not be a secret value")
    ctx:Expect(line):ToBe(startLine + 1)
  end
)

secretTest(
  "a journal records a secret argument and History hands it back still secret",
  function(ctx)
    local recent = SignalKit:NewJournal(2)
    recent:Fire("plain", makeSecret(ctx, 7))

    local walked = 0
    for _, entry in recent:History() do
      walked = walked + 1
      ctx:Expect(entry.count):ToBe(2)
      ctx:Expect(entry[1]):ToBe("plain")
      ctx:Expect(isSecretValue(entry[2])):ToBe(true)
    end
    ctx:Expect(walked):ToBe(1)
  end
)

secretTest(
  "a validator that answers with a secret instead of true refuses the publish",
  function(ctx)
    local bus = probeBus()
    bus:DeclareTopic("SecretVerdict", { arguments = answerWithSecretVerdict })
    local calls = {}
    track(bus:Subscribe("SecretVerdict", recorder(calls, "subscriber")))

    local startLine = 0
    local line = expectErrorAtCallingLine(
      ctx,
      function()
        startLine = currentLine()
        bus:Publish("SecretVerdict", 1)
      end,
      'SignalKit.Bus:Publish topic "SecretVerdict" on bus "'
        .. PROBE_BUS_NAME
        .. '" refused its arguments: the validator gave no reason'
    )
    ctx:Expect(line):ToBe(startLine + 1)
    ctx:Expect(calls):ToEqual({})
  end
)
