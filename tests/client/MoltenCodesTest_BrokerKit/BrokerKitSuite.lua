-- MoltenCodes Test: BrokerKitSuite.lua
--
-- Real-client suites for the `brokerKit` package. The Busted specs under
-- packages/brokerKit/tests/ prove BrokerKit on a stock Lua 5.1 with a scripted
-- LibStub and LibDataBroker; these prove, inside the game client with the
-- installed MoltenCodes addon, what that fixture can only simulate:
--
--   * the installed facade and its committed revision; whether the client has
--     a real LibStub and LibDataBroker-1.1 (logged, never used); that the
--     session has room for this run's objects under `maxObjects`;
--   * data objects on the client's Lua: attributes read and written as plain
--     fields through the proxy, `Set` and `Get`, the empty proxy with its
--     hidden metatable, `nil` clearing;
--   * per-attribute and any-attribute change signals (their order, their
--     arguments, same-value writes firing nothing), `OnObjectAdded`, and a
--     listener error reaching the line that wrote;
--   * sorted enumeration in the client's byte order, `Objects` handing out a
--     fresh array, and an `Iterate` walk that an object created mid-walk does
--     not disturb;
--   * the display callbacks called the way a display calls them: `OnClick` with
--     `UIParent` and a mouse button, and `OnTooltipShow` with the client's own
--     `GameTooltip`, whose lines are read back and which is hidden again in the
--     same step, so nothing is ever drawn;
--   * the LibDataBroker-1.1 bridge in both directions against this addon's own
--     stand-in (LibDataBrokerStandIn.lua; nothing third-party is shipped):
--     `ExposeToLibDataBroker`, `AdoptFromLibDataBroker`, read-only foreign
--     objects, and no echo with both directions on;
--   * that attribute reads, attribute writes with listeners connected and an
--     unchanged `Iterate` allocate nothing on the client's own collector;
--   * argument errors, and secret values made by the client's `secretwrap`:
--     refused as names, attribute names, known attributes and limits, stored
--     untouched as custom attributes and never mirrored into LibDataBroker, all
--     pointing at this file as the client names it.
--
-- Nothing here needs combat, a group or an instance. Nothing is drawn: the one
-- tooltip the suite fills is hidden before the test step ends, and no frame is
-- created.
--
-- Run with `/mct run brokerKit`; tests/client/MoltenCodesTest_BrokerKit/EXPECTED.md
-- lists what the chat frame should show.
--
-- The LibDataBroker stand-in. When the client has no `LibStub` (the expected
-- set-up: only the MoltenCodes addon and its test addons enabled), each bridge
-- test installs a fresh LibStub stand-in as the global `LibStub`, holding the
-- session's one LibDataBroker-1.1 stand-in, and the After hook of its suite
-- removes the global again, pass or fail. When the client has a `LibStub` of
-- its own, the bridge tests are reported as skipped with the reason: exposing
-- is one-way for the session and would put the test objects into the player's
-- real display addons, and the global must not be replaced under them.
--
-- What a run leaves behind. BrokerKit objects live for the session: there is
-- no removal (docs/API.md, "BrokerKit:New"). Every object a run creates
-- therefore has a name of its own, `MoltenCodesTest_BrokerKit <serial> <label>`,
-- where the serial counts up from 1 for the session, so a second run never
-- meets a name the first one took. A full run creates OBJECTS_PER_RUN objects,
-- adopted ones included, all counted against the shared `maxObjects` (256 by
-- default); the facade suite says so before the room runs out, and `/reload`
-- starts over. Besides the objects:
--
--   * every SignalKit connection a test makes (`OnChange`, `OnObjectAdded`)
--     and every callback it registers with the stand-in is disconnected by the
--     After hook of its suite;
--   * once a bridge test ran, BrokerKit keeps the session's LibDataBroker
--     stand-in as the library it exposes into and adopts from, because the
--     bridge cannot be undone: every object created later in the session, by
--     any addon, is also written into that stand-in, which nobody else can
--     reach. The global `LibStub` is gone again after every test;
--   * BrokerKit's limits are never changed: the `SetLimits` calls are refusals.
--
-- Nothing is written to a saved variable, and no client setting changes.

local addonName, addonTable = ...

-- The harness is this addon's dependency and publishes one documented global.
-- selene: allow(global_usage)
local Harness = rawget(_G, "MoltenCodesTest")
-- The shared MoltenCodes namespace is the one documented global handoff point.
-- selene: allow(global_usage)
local namespace = rawget(_G, "MoltenCodes")
if type(Harness) ~= "table" or type(namespace) ~= "table" then
  error(addonName .. " requires the MoltenCodesTest harness and the MoltenCodes addon", 0)
end

---@type any
local StandIn = type(addonTable) == "table" and addonTable.LibDataBrokerStandIn or nil
if type(StandIn) ~= "table" then
  error(addonName .. " requires LibDataBrokerStandIn.lua, listed before this file in the .toc", 0)
end

local REGISTRY_API = 2
local BROKER_KIT_API = 1
local PACKAGE_ID = "brokerKit"

--- This file as the client names it in an error position.
local THIS_FILE = "BrokerKitSuite.lua"

--- Every method docs/API.md of brokerKit lists on the facade.
local FACADE_METHODS = {
  "New",
  "Get",
  "Objects",
  "Iterate",
  "OnObjectAdded",
  "IsForeign",
  "ExposeToLibDataBroker",
  "AdoptFromLibDataBroker",
  "SetLimits",
  "GetLimits",
}

--- The documented defaults of the two limits.
local MAX_OBJECTS = 256
local MAX_ATTRIBUTES = 32

--- How many objects a full run creates, adopted ones included. The facade
--- suite checks that the session still has room for them.
local OBJECTS_PER_RUN = 39

--- The prefix of every object name this addon creates.
local NAME_PREFIX = "MoltenCodesTest_BrokerKit "

--- The question-mark icon's FileDataID; only stored and compared, never loaded.
local QUESTION_MARK_ICON = 134400

--- The same icon as a texture path.
local QUESTION_MARK_PATH = [[Interface\Icons\INV_Misc_QuestionMark]]

--- The lines the tooltip tests add.
local TOOLTIP_TITLE = "MoltenCodes Test: BrokerKit"
local TOOLTIP_HINT = "Click to open nothing"
local FOREIGN_TOOLTIP_LINE = "MoltenCodes Test: a foreign data object"

--- The message a raising listener raises, at level 0 so it carries no position.
local LISTENER_FAILURE = "MoltenCodesTest_BrokerKit listener failure"

--- How many times each allocation guard runs its operation, and how many full
--- walks the Iterate guard measures.
local ALLOCATION_CALLS = 5000
local ITERATE_WALKS = 500

--- Kilobytes an allocation guard tolerates. The tolerance absorbs a stray
--- allocation by the client between the two readings, not a per-call one.
local ALLOCATION_TOLERANCE_KB = 1

--- The two strings the write guard alternates. Both are constants, so no
--- write builds a string.
local TEXT_A = "12 ms"
local TEXT_B = "13 ms"

-- Resolving the client and the framework ---------------------------------------------

---Read a client global, or `nil`.
---@param name string
---@return any
local function readHost(name)
  -- UIParent, GameTooltip and its line FontStrings, LibStub and the
  -- secret-value functions are World of Warcraft client globals, reachable
  -- only through the global table.
  -- selene: allow(global_usage)
  return rawget(_G, name)
end

---Write the global `LibStub`. Only the stand-in is ever written, and only
---while no other `LibStub` exists; `nil` removes it again.
---@param value table|nil
local function writeGlobalLibStub(value)
  -- The bridge reads `rawget(_G, "LibStub")` (packages/brokerKit/docs/API.md,
  -- "Host facilities"), so the stand-in has to be that global for a test.
  -- selene: allow(global_usage)
  rawset(_G, "LibStub", value)
end

---@type Registry
local Registry = rawget(rawget(namespace, "Registries") or {}, REGISTRY_API)
if type(Registry) ~= "table" then
  error(addonName .. " requires the MoltenCodes addon (Registry API 2); reinstall it", 0)
end

-- BrokerKit is not in the language-server workspace of tests/client (its
-- .luarc.json lists TestKit's dependency closure only), so its facade and its
-- objects are typed `any` here.

---@type any
local BrokerKit = Registry:Get(PACKAGE_ID, BROKER_KIT_API)
if type(BrokerKit) == "nil" then
  error(addonName .. " requires BrokerKit API 1 in the MoltenCodes addon; reinstall it", 0)
end

---@type any
local uiParent = readHost("UIParent")
---@type any
local gameTooltip = readHost("GameTooltip")
if type(uiParent) ~= "table" or type(gameTooltip) ~= "table" then
  error(addonName .. " requires the client's UIParent and GameTooltip", 0)
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

-- Object names ------------------------------------------------------------------------------

--- The last serial handed out; objects live for the session, and so does this.
local objectSerial = 0

---A name prefix no object of this session has used: `NAME_PREFIX`, the next
---serial and a space. Every name built on it sorts together.
---@return string
local function newPrefix()
  objectSerial = objectSerial + 1
  return ("%s%03d "):format(NAME_PREFIX, objectSerial)
end

---A name no object of this session has used, ending in `label`.
---@param label string
---@return string
local function uniqueName(label)
  return newPrefix() .. label
end

---The labels of the names in `names` that start with `prefix`, in order.
---@param names string[]
---@param prefix string
---@return string[]
local function labelsWithPrefix(names, prefix)
  local labels = {}
  for index = 1, #names do
    local name = names[index]
    if name:sub(1, #prefix) == prefix then
      labels[#labels + 1] = name:sub(#prefix + 1)
    end
  end
  return labels
end

---A limit for the log: its number, or `UNBOUNDED`.
---@param value any
---@return string
local function describeLimit(value)
  if rawequal(value, BrokerKit.UNBOUNDED) then
    return "UNBOUNDED"
  end
  return tostring(value)
end

-- What the running test holds ----------------------------------------------------------------

--- SignalKit connections the running test made; the After hook disconnects them.
---@type any[]
local trackedConnections = {}

--- Owners the running test registered with the stand-in library, and their events.
---@type { owner: table, eventName: string }[]
local trackedRegistrations = {}

--- The LibStub stand-in the running test installed as the global, or `nil`.
---@type table|nil
local installedLibStub = nil

--- Whether a bridge call of this session already exposed into, or adopted
--- from, the stand-in library. The first successful call answers `true`,
--- every later one `false, "already"` (docs/API.md, "LibDataBroker-1.1").
local bridgeSession = { exposed = false, adopted = false }

---Remember a SignalKit connection for the After hook and return it.
---@param connection any
---@return any connection
local function track(connection)
  trackedConnections[#trackedConnections + 1] = connection
  return connection
end

---Disconnect everything the running test connected, unregister its stand-in
---callbacks and remove the stand-in `LibStub` it installed. The After hook of
---every suite.
local function cleanUp()
  for index = #trackedConnections, 1, -1 do
    local connection = trackedConnections[index]
    trackedConnections[index] = nil
    pcall(connection.Disconnect, connection)
  end
  for index = #trackedRegistrations, 1, -1 do
    local registration = trackedRegistrations[index]
    trackedRegistrations[index] = nil
    pcall(StandIn.GetLibrary().UnregisterCallback, registration.owner, registration.eventName)
  end
  if type(installedLibStub) ~= "nil" then
    if rawequal(readHost("LibStub"), installedLibStub) then
      writeGlobalLibStub(nil)
    end
    installedLibStub = nil
  end
end

---Register a suite of this package whose tests all end with every connection
---disconnected and the global `LibStub` gone.
---@param part string
---@return TestKit.Suite
local function newSuite(part)
  local suite = Harness:Suite(PACKAGE_ID, part, addonName)
  suite:After(cleanUp)
  return suite
end

-- The LibDataBroker stand-in -------------------------------------------------------------------

--- Why a bridge test is skipped when the client has a LibStub of its own.
local REAL_LIBSTUB_SKIP_REASON =
  "another addon loaded a real LibStub; exposing is one-way for the session and would put test objects into the player's display addons, so the bridge was not exercised (disable every other addon to run it)"

---End the test as skipped when the client has a `LibStub` this test did not install.
---@param ctx TestKit.Context
local function requireNoLibStub(ctx)
  if type(readHost("LibStub")) ~= "nil" then
    Harness:SkipTest(ctx, REAL_LIBSTUB_SKIP_REASON)
  end
end

---Install a fresh LibStub stand-in as the global `LibStub` for this test.
---With `withLibrary`, it holds the session's LibDataBroker-1.1 stand-in,
---which is returned; without, it holds no library. Skips the test when the
---client has a `LibStub` of its own.
---@param ctx TestKit.Context
---@param withLibrary boolean
---@return table library the session's stand-in library
local function installStandIn(ctx, withLibrary)
  requireNoLibStub(ctx)
  local libStub = StandIn.NewLibStub(withLibrary)
  installedLibStub = libStub
  writeGlobalLibStub(libStub)
  return StandIn.GetLibrary()
end

---What a display addon registered on the stand-in saw.
---@class MoltenCodesTest.BrokerKit.DisplayLog
---@field created string[] the name of every `LibDataBroker_DataObjectCreated`
---@field changed string[] `<name>.<attribute>` of every `LibDataBroker_AttributeChanged`

---Register a display addon's two callbacks on the stand-in and return what it
---sees. The After hook unregisters them.
---@param library table
---@return MoltenCodesTest.BrokerKit.DisplayLog
local function watchLibrary(library)
  local log = { created = {}, changed = {} }
  local owner = {}
  library.RegisterCallback(owner, "LibDataBroker_DataObjectCreated", function(_, name)
    log.created[#log.created + 1] = name
  end)
  library.RegisterCallback(owner, "LibDataBroker_AttributeChanged", function(_, name, attribute)
    log.changed[#log.changed + 1] = name .. "." .. attribute
  end)
  trackedRegistrations[#trackedRegistrations + 1] =
    { owner = owner, eventName = "LibDataBroker_DataObjectCreated" }
  trackedRegistrations[#trackedRegistrations + 1] =
    { owner = owner, eventName = "LibDataBroker_AttributeChanged" }
  return log
end

---How many entries of `list` are `value`.
---@param list string[]
---@param value string
---@return integer
local function countOf(list, value)
  local count = 0
  for index = 1, #list do
    if list[index] == value then
      count = count + 1
    end
  end
  return count
end

---Call `ExposeToLibDataBroker` with the stand-in installed and check its
---answer: `true` the first time in the session, `false, "already"` after.
---@param ctx TestKit.Context
local function exposeIntoStandIn(ctx)
  local exposed, reason = BrokerKit:ExposeToLibDataBroker()
  ctx:Log(
    ("ExposeToLibDataBroker(): %s, %s (first in this session: %s)"):format(
      tostring(exposed),
      tostring(reason),
      tostring(not bridgeSession.exposed)
    )
  )
  if bridgeSession.exposed then
    ctx:Expect(exposed):ToBe(false)
    ctx:Expect(reason):ToBe("already")
  else
    ctx:Expect(exposed):ToBe(true)
    ctx:Expect(reason):ToBeNil()
  end
  bridgeSession.exposed = true
end

---Call `AdoptFromLibDataBroker` with the stand-in installed and check its
---answer: `true` the first time in the session, `false, "already"` after.
---@param ctx TestKit.Context
local function adoptFromStandIn(ctx)
  local adopted, reason = BrokerKit:AdoptFromLibDataBroker()
  ctx:Log(
    ("AdoptFromLibDataBroker(): %s, %s (first in this session: %s)"):format(
      tostring(adopted),
      tostring(reason),
      tostring(not bridgeSession.adopted)
    )
  )
  if bridgeSession.adopted then
    ctx:Expect(adopted):ToBe(false)
    ctx:Expect(reason):ToBe("already")
  else
    ctx:Expect(adopted):ToBe(true)
    ctx:Expect(reason):ToBeNil()
  end
  bridgeSession.adopted = true
end

-- The client's GameTooltip ----------------------------------------------------------------------

---What one `OnTooltipShow` call left in the client's `GameTooltip`.
---@class MoltenCodesTest.BrokerKit.TooltipReading
---@field succeeded boolean whether the callback returned without raising
---@field message any what it raised, when it did
---@field lineCount integer `GameTooltip:NumLines()` after the callback
---@field lines (string|false)[] the text of each left line, `false` when unreadable
---@field shownWhileFilled boolean `GameTooltip:IsShown()` after the callback, before `Hide`
---@field linesAfterHide integer `GameTooltip:NumLines()` after `Hide`

---Call `onTooltipShow` with the client's `GameTooltip` the way a display
---does, read the lines back and hide the tooltip again, all in this one step,
---so the tooltip is never drawn: `SetOwner(UIParent, "ANCHOR_NONE")` gives it
---an owner and no position, the callback adds lines, and nothing calls `Show`.
---The lines are read from the tooltip's own left-column FontStrings,
---`GameTooltipTextLeft<n>`, the regions every tooltip-scanning addon reads.
---`Hide` runs even when the callback raised.
---@param onTooltipShow function
---@return MoltenCodesTest.BrokerKit.TooltipReading
local function fillTooltipOnce(onTooltipShow)
  gameTooltip:SetOwner(uiParent, "ANCHOR_NONE")
  local succeeded, message = pcall(onTooltipShow, gameTooltip)
  local lineCount = gameTooltip:NumLines()
  local lines = {}
  local tooltipName = gameTooltip:GetName()
  for index = 1, lineCount do
    local fontString = readHost(tooltipName .. "TextLeft" .. index)
    ---@type string|false
    local text = false
    if type(fontString) == "table" then
      local lineText = fontString:GetText()
      if not isSecret(lineText) and type(lineText) == "string" then
        text = lineText
      end
    end
    lines[index] = text
  end
  local shownWhileFilled = gameTooltip:IsShown() == true
  gameTooltip:Hide()
  return {
    succeeded = succeeded,
    message = message,
    lineCount = lineCount,
    lines = lines,
    shownWhileFilled = shownWhileFilled,
    linesAfterHide = gameTooltip:NumLines(),
  }
end

---Log a tooltip reading.
---@param ctx TestKit.Context
---@param reading MoltenCodesTest.BrokerKit.TooltipReading
local function logTooltipReading(ctx, reading)
  local texts = {}
  for index = 1, #reading.lines do
    texts[index] = tostring(reading.lines[index])
  end
  ctx:Log(
    ("GameTooltip after OnTooltipShow: %d lines [%s], shown before Hide: %s, lines after Hide: %d"):format(
      reading.lineCount,
      table.concat(texts, " | "),
      tostring(reading.shownWhileFilled),
      reading.linesAfterHide
    )
  )
  if not reading.succeeded then
    ctx:Log("OnTooltipShow raised: " .. tostring(reading.message))
  end
end

-- Positions and errors ------------------------------------------------------------------------

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
  ctx:Expect((file or ""):sub(-#THIS_FILE)):ToBe(THIS_FILE)
  return line
end

---Call `raise`, which must record its start line with `currentLine()` and
---raise on the next line, and check that the message names this file at that
---next line and ends with `expected`.
---@param ctx TestKit.Context
---@param raise fun() Records its start line in `lineBox.start`, then raises on the next line.
---@param lineBox { start: integer }
---@param expected string The message after the position, compared literally.
local function expectErrorAtCallingLine(ctx, raise, lineBox, expected)
  local succeeded, message = pcall(raise)
  ctx:Expect(succeeded):ToBe(false)
  ctx:Log("client message: " .. tostring(message))

  local line = expectThisFile(ctx, message)
  ctx:Expect(tostring(message):sub(-#expected)):ToBe(expected)
  ctx:Expect(line):ToBe(lineBox.start + 1)
end

-- Allocation ----------------------------------------------------------------------------------

---Collect in a step of its own, run `operation` once unmeasured, then run it
---`calls` times, log how far the heap grew and hold it to the tolerance.
---
---The full collection runs in a step of its own so the measurement starts far
---from the next collector cycle, which would otherwise shrink the count
---mid-measurement and hide an allocation. The warm-up call comes after the
---collection on purpose: the first call after a full collection can regrow
---the coroutine stack or other bookkeeping once, which is not the per-call
---cost docs/API.md promises is zero.
---@param ctx TestKit.Context
---@param label string what `operation` does, for the log
---@param calls integer
---@param operation fun()
local function expectNoAllocation(ctx, label, calls, operation)
  collectgarbage("collect")
  ctx:Yield()
  operation()
  local before = collectgarbage("count")
  for _ = 1, calls do
    operation()
  end
  local grownKilobytes = collectgarbage("count") - before
  ctx:Log(("memory delta over %d calls of %s: %.3f KB"):format(calls, label, grownKilobytes))
  ctx:Expect(grownKilobytes <= ALLOCATION_TOLERANCE_KB):ToBe(true)
end

-- Secrets ---------------------------------------------------------------------------------------

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

---Check that `received` is still secret and of the secret's type. Identity
---cannot be checked: comparing a secret with a value of its own type raises,
---`rawequal(secret, secret)` included (docs/EMBEDDING.md, "Measured on the
---client").
---@param ctx TestKit.Context
---@param received any
---@param secret any
local function expectSameSecret(ctx, received, secret)
  ctx:Expect(isSecretValue(received)):ToBe(true)
  ctx:Expect(type(received)):ToBe(type(secret))
end

---Describe a pcall outcome for the log without formatting a secret.
---@param ok boolean
---@param value any
---@return string
local function describeOutcome(ok, value)
  if not ok then
    return "raised: " .. tostring(value)
  end
  if isSecret(value) then
    return "returned a secret " .. type(value)
  end
  return "returned " .. type(value) .. " " .. tostring(value)
end

-- brokerKit.facade ----------------------------------------------------------------------------

local facade = newSuite("facade")

facade:Test(
  "Registry:Get('brokerKit', 1) is the BrokerKit facade with API 1, its ten methods, MAX_OBJECTS 256, MAX_ATTRIBUTES 32 and UNBOUNDED",
  function(ctx)
    ctx:Expect(type(BrokerKit)):ToBe("table")
    ctx:Expect(rawget(BrokerKit, "API")):ToBe(BROKER_KIT_API)
    for _, methodName in ipairs(FACADE_METHODS) do
      ctx:Expect(type(BrokerKit[methodName])):ToBe("function")
    end
    ctx:Expect(BrokerKit.MAX_OBJECTS):ToBe(MAX_OBJECTS)
    ctx:Expect(BrokerKit.MAX_ATTRIBUTES):ToBe(MAX_ATTRIBUTES)
    ctx:Expect(type(BrokerKit.UNBOUNDED)):ToBe("table")
    local limits = BrokerKit:GetLimits()
    ctx:Log(
      ("limits in this session: maxObjects %s, maxAttributes %s"):format(
        describeLimit(limits.maxObjects),
        describeLimit(limits.maxAttributes)
      )
    )
  end
)

facade:Test("the installed BrokerKit carries the revision of the committed manifest", function(ctx)
  local expectedPackages = Harness:GetExpectedPackages()
  if type(expectedPackages) == "nil" then
    ctx:Fail("Expected.lua is missing; install with python3 -m tooling.client.install")
    return
  end
  for _, expected in ipairs(expectedPackages) do
    if expected.id == PACKAGE_ID then
      local _, revision = Registry:Get(PACKAGE_ID, BROKER_KIT_API)
      ctx:Expect(revision):ToBe(expected.revision)
      ctx:Expect(rawget(BrokerKit, "REVISION")):ToBe(expected.revision)
      return
    end
  end
  ctx:Fail("Expected.lua does not list brokerKit")
end)

facade:Test(
  "the client's LibStub and LibDataBroker-1.1 are logged, GameTooltip has the methods a display calls, and the session has room for this run's objects under maxObjects",
  function(ctx)
    local libStub = readHost("LibStub")
    if type(libStub) == "nil" then
      ctx:Log("LibStub: absent; the bridge tests use this addon's stand-in")
    else
      ctx:Log("LibStub: present (" .. type(libStub) .. "); the bridge tests will be skipped")
      local getLibrary = type(libStub) == "table" and libStub.GetLibrary or nil
      if type(getLibrary) == "function" then
        local ok, library, minor = pcall(getLibrary, libStub, StandIn.LIBDATABROKER_MAJOR, true)
        if ok and type(library) == "table" then
          local count = 0
          local iterated = pcall(function()
            for _ in library:DataObjectIterator() do
              count = count + 1
            end
          end)
          ctx:Log(
            ("LibDataBroker-1.1: minor %s, %s data objects"):format(
              tostring(minor),
              iterated and tostring(count) or "unreadable"
            )
          )
        else
          ctx:Log("LibDataBroker-1.1: absent from that LibStub")
        end
      end
    end

    for _, methodName in ipairs({ "SetOwner", "AddLine", "NumLines", "IsShown", "Hide", "GetName" }) do
      ctx:Expect(type(gameTooltip[methodName])):ToBe("function")
    end

    local objectCount = #BrokerKit:Objects()
    local maxObjects = BrokerKit:GetLimits().maxObjects
    if rawequal(maxObjects, BrokerKit.UNBOUNDED) then
      ctx:Log(("%d objects in the session; maxObjects is UNBOUNDED"):format(objectCount))
      return
    end
    local room = maxObjects - objectCount
    ctx:Log(
      ("%d objects in the session, room for %d more under maxObjects %d; a run creates %d"):format(
        objectCount,
        room,
        maxObjects,
        OBJECTS_PER_RUN
      )
    )
    if room < OBJECTS_PER_RUN then
      ctx:Fail(
        ("only %d more objects fit under maxObjects %d and a run creates %d; /reload to start over, because objects live for the session"):format(
          room,
          maxObjects,
          OBJECTS_PER_RUN
        )
      )
    end
  end
)

-- brokerKit.objects ---------------------------------------------------------------------------

local objectsSuite = newSuite("objects")

objectsSuite:Test(
  "New hands back an object whose attributes read as plain fields: text, a FileDataID icon, value, OnClick, a custom table, type 'data source' by default and the read-only name",
  function(ctx)
    local name = uniqueName("Status")
    local onClick = function() end
    local history = { 12, 13 }
    local definition = {
      text = "12 ms",
      icon = QUESTION_MARK_ICON,
      value = 12,
      suffix = "ms",
      OnClick = onClick,
      history = history,
    }
    local object = BrokerKit:New(name, definition)

    ctx:Expect(object.type):ToBe("data source")
    ctx:Expect(object.text):ToBe("12 ms")
    ctx:Expect(object.icon):ToBe(QUESTION_MARK_ICON)
    ctx:Expect(object.value):ToBe(12)
    ctx:Expect(object.suffix):ToBe("ms")
    ctx:Expect(object.OnClick):ToBe(onClick)
    ctx:Expect(object.history):ToBe(history)
    ctx:Expect(object.label):ToBeNil()
    ctx:Expect(object.name):ToBe(name)
    ctx:Expect(object:Get("text")):ToBe("12 ms")

    -- The definition was copied: changing it afterwards changes nothing, and
    -- New wrote nothing into it.
    definition.text = "changed"
    ctx:Expect(object.text):ToBe("12 ms")
    ctx:Expect(definition.type):ToBeNil()

    ctx:Expect(BrokerKit:Get(name)):ToBe(object)
    ctx:Expect(BrokerKit:IsForeign(object)):ToBe(false)
    ctx:Expect(BrokerKit:Get(uniqueName("Nobody"))):ToBeNil()
  end
)

objectsSuite:Test(
  "a launcher keeps its type, and the object is an empty proxy: rawget and next see nothing, getmetatable answers 'BrokerKit.Object' and setmetatable is refused",
  function(ctx)
    local launcher =
      BrokerKit:New(uniqueName("Launcher"), { type = "launcher", icon = QUESTION_MARK_PATH })
    ctx:Expect(launcher.type):ToBe("launcher")
    ctx:Expect(launcher.icon):ToBe(QUESTION_MARK_PATH)
    ctx:Expect(rawget(launcher, "type")):ToBeNil()
    ctx:Expect(rawget(launcher, "name")):ToBeNil()
    ctx:Expect(next(launcher)):ToBeNil()
    ctx:Expect(getmetatable(launcher)):ToBe("BrokerKit.Object")
    local replaced, message = pcall(setmetatable, launcher, {})
    ctx:Log("setmetatable(object, {}): " .. describeOutcome(replaced, message))
    ctx:Expect(replaced):ToBe(false)
  end
)

objectsSuite:Test(
  "a plain field write and Set store the same way: text, value, label, a custom table, and nil clearing any attribute but type",
  function(ctx)
    local object = BrokerKit:New(uniqueName("Writes"))
    object.text = "12 ms"
    ctx:Expect(object.text):ToBe("12 ms")
    ctx:Expect(object:Get("text")):ToBe("12 ms")

    object:Set("value", 12)
    ctx:Expect(object.value):ToBe(12)
    object.label = "Latency"
    ctx:Expect(object:Get("label")):ToBe("Latency")

    local custom = { samples = {} }
    object.samples = custom
    ctx:Expect(object.samples):ToBe(custom)

    object.text = nil
    object:Set("label", nil)
    object.samples = nil
    ctx:Expect(object.text):ToBeNil()
    ctx:Expect(object.label):ToBeNil()
    ctx:Expect(object.samples):ToBeNil()
    ctx:Expect(object.value):ToBe(12)

    object.type = "launcher"
    ctx:Expect(object.type):ToBe("launcher")
    ctx:Expect(next(object)):ToBeNil()
  end
)

-- brokerKit.signals ---------------------------------------------------------------------------

local signals = newSuite("signals")

signals:Test(
  "a per-attribute listener gets (object, 'text', value, previous) after the value is stored and before the any-attribute listener, for a field write and Set alike",
  function(ctx)
    local object = BrokerKit:New(uniqueName("Signals"), { text = "a" })
    local calls = {}

    ---@param kind string
    ---@return function
    local function recorder(kind)
      return function(changed, attribute, value, previous)
        calls[#calls + 1] = {
          kind = kind,
          sameObject = rawequal(changed, object),
          attribute = attribute,
          value = value,
          previous = previous,
          stored = changed.text,
        }
      end
    end
    track(object:OnChange("text", recorder("text")))
    track(object:OnChange(recorder("any")))

    object.text = "b"
    object:Set("text", "c")

    ctx:Expect(calls):ToEqual({
      {
        kind = "text",
        sameObject = true,
        attribute = "text",
        value = "b",
        previous = "a",
        stored = "b",
      },
      {
        kind = "any",
        sameObject = true,
        attribute = "text",
        value = "b",
        previous = "a",
        stored = "b",
      },
      {
        kind = "text",
        sameObject = true,
        attribute = "text",
        value = "c",
        previous = "b",
        stored = "c",
      },
      {
        kind = "any",
        sameObject = true,
        attribute = "text",
        value = "c",
        previous = "b",
        stored = "c",
      },
    })
  end
)

signals:Test(
  "writing the value an attribute holds fires nothing, a new attribute arrives with previous nil and a cleared one with value nil, and a disconnected listener hears nothing",
  function(ctx)
    local object = BrokerKit:New(uniqueName("Quiet"), { text = "a" })
    local calls = {}
    local connection = track(object:OnChange(nil, function(_, attribute, value, previous)
      calls[#calls + 1] = { attribute = attribute, value = value, previous = previous }
    end))

    object.text = "a"
    object:Set("text", "a")
    object.label = nil
    ctx:Expect(#calls):ToBe(0)

    object.label = "L"
    object.label = nil
    object.label = nil
    ctx:Expect(calls):ToEqual({
      { attribute = "label", value = "L" },
      { attribute = "label", previous = "L" },
    })

    connection:Disconnect()
    ctx:Expect(connection:IsConnected()):ToBe(false)
    object.text = "z"
    ctx:Expect(#calls):ToBe(2)
    ctx:Expect(object.text):ToBe("z")
  end
)

signals:Test(
  "OnObjectAdded fires once per New with the new object, which BrokerKit:Get already finds",
  function(ctx)
    local added = {}
    track(BrokerKit:OnObjectAdded(function(object)
      added[#added + 1] = { object = object, foundByGet = BrokerKit:Get(object.name) }
    end))

    local first = BrokerKit:New(uniqueName("AddedA"))
    local second = BrokerKit:New(uniqueName("AddedB"), { type = "launcher" })

    ctx:Expect(#added):ToBe(2)
    ctx:Expect(added[1].object):ToBe(first)
    ctx:Expect(added[1].foundByGet):ToBe(first)
    ctx:Expect(added[2].object):ToBe(second)
    ctx:Expect(added[2].foundByGet):ToBe(second)
  end
)

signals:Test(
  "a listener error propagates to the line that wrote, after the value was stored",
  function(ctx)
    local object = BrokerKit:New(uniqueName("Raising"), { text = "before" })
    track(object:OnChange("text", function()
      error(LISTENER_FAILURE, 0)
    end))

    local succeeded, message = pcall(function()
      object.text = "after"
    end)
    ctx:Log("writer's error: " .. tostring(message))
    ctx:Expect(succeeded):ToBe(false)
    ctx:Expect(type(tostring(message):find(LISTENER_FAILURE, 1, true))):ToBe("number")
    ctx:Expect(object.text):ToBe("after")
  end
)

-- brokerKit.enumeration -----------------------------------------------------------------------

local enumeration = newSuite("enumeration")

enumeration:Test(
  "Objects lists this test's names sorted with < in the client's byte order ('Bar 10' before 'Bar 2', upper case before lower case), in a fresh array every call",
  function(ctx)
    local prefix = newPrefix()
    for _, label in ipairs({ "alpha", "Zulu", "Bar 2", "Beta", "Bar 10" }) do
      BrokerKit:New(prefix .. label)
    end

    local first = BrokerKit:Objects()
    local second = BrokerKit:Objects()
    ctx:Log(("%d objects in the session"):format(#first))
    ctx
      :Expect(labelsWithPrefix(first, prefix))
      :ToEqual({ "Bar 10", "Bar 2", "Beta", "Zulu", "alpha" })
    ctx:Expect(first).Not:ToBe(second)
    ctx:Expect(first):ToEqual(second)

    local original = second[1]
    first[1] = "tampered"
    ctx:Expect(BrokerKit:Objects()[1]):ToBe(original)
  end
)

enumeration:Test(
  "Iterate walks the order of Objects, hands out each name's object, skips an object created during the walk yet visits every name present at its start, and the next walk has it",
  function(ctx)
    local prefix = newPrefix()
    for _, label in ipairs({ "a", "b", "c" }) do
      BrokerKit:New(prefix .. label)
    end
    local createdName = prefix .. "b2"
    local namesAtStart = BrokerKit:Objects()

    local visited = {}
    local mismatchedObjects = 0
    for name, object in BrokerKit:Iterate() do
      visited[#visited + 1] = name
      if not rawequal(BrokerKit:Get(name), object) then
        mismatchedObjects = mismatchedObjects + 1
      end
      if name == prefix .. "a" then
        BrokerKit:New(createdName)
      end
    end

    ctx:Expect(visited):ToEqual(namesAtStart)
    ctx:Expect(mismatchedObjects):ToBe(0)
    ctx:Expect(labelsWithPrefix(visited, prefix)):ToEqual({ "a", "b", "c" })

    local nextWalk = {}
    for name in BrokerKit:Iterate() do
      nextWalk[#nextWalk + 1] = name
    end
    ctx:Expect(labelsWithPrefix(nextWalk, prefix)):ToEqual({ "a", "b", "b2", "c" })
    ctx:Expect(#nextWalk):ToBe(#namesAtStart + 1)
  end
)

-- brokerKit.display ---------------------------------------------------------------------------

local display = newSuite("display")

display:Test(
  "OnTooltipShow called as a display calls it fills the client's GameTooltip: two lines read back through NumLines and GameTooltipTextLeft1 and 2, hidden again in the same step",
  function(ctx)
    local received = nil
    local object = BrokerKit:New(uniqueName("Tooltip"), {
      text = "12 ms",
      OnTooltipShow = function(tooltip)
        received = tooltip
        tooltip:AddLine(TOOLTIP_TITLE)
        tooltip:AddLine(TOOLTIP_HINT, 1, 1, 1)
      end,
    })

    local reading = fillTooltipOnce(object.OnTooltipShow)
    logTooltipReading(ctx, reading)
    ctx:Expect(reading.succeeded):ToBe(true)
    ctx:Expect(rawequal(received, gameTooltip)):ToBe(true)
    ctx:Expect(reading.lineCount):ToBe(2)
    ctx:Expect(reading.lines):ToEqual({ TOOLTIP_TITLE, TOOLTIP_HINT })
    ctx:Expect(gameTooltip:IsShown() == true):ToBe(false)
  end
)

display:Test(
  "OnClick is stored and never called by BrokerKit; a display's call with UIParent and a mouse button reaches it, and a replaced OnClick fires OnChange and is the one called next",
  function(ctx)
    local clicks = {}
    local function firstHandler(frame, button)
      clicks[#clicks + 1] =
        { handler = 1, frameIsUIParent = rawequal(frame, uiParent), button = button }
    end
    local function secondHandler(frame, button)
      clicks[#clicks + 1] =
        { handler = 2, frameIsUIParent = rawequal(frame, uiParent), button = button }
    end

    local object = BrokerKit:New(
      uniqueName("Clickable"),
      { type = "launcher", icon = QUESTION_MARK_ICON, OnClick = firstHandler }
    )
    object.label = "Clickable"
    ctx:Expect(#clicks):ToBe(0)

    object.OnClick(uiParent, "LeftButton")

    local changes = {}
    track(object:OnChange("OnClick", function(_, _, value, previous)
      changes[#changes + 1] = {
        valueIsSecond = rawequal(value, secondHandler),
        previousIsFirst = rawequal(previous, firstHandler),
      }
    end))
    object.OnClick = secondHandler
    object.OnClick(uiParent, "RightButton")

    ctx:Expect(clicks):ToEqual({
      { handler = 1, frameIsUIParent = true, button = "LeftButton" },
      { handler = 2, frameIsUIParent = true, button = "RightButton" },
    })
    ctx:Expect(changes):ToEqual({ { valueIsSecond = true, previousIsFirst = true } })
  end
)

-- brokerKit.libDataBroker ---------------------------------------------------------------------

local libDataBroker = newSuite("libDataBroker")

libDataBroker:Test(
  "without LibStub, ExposeToLibDataBroker and AdoptFromLibDataBroker return false, 'absent', and so they do with a LibStub that holds no LibDataBroker-1.1",
  function(ctx)
    requireNoLibStub(ctx)
    local exposed, exposeReason = BrokerKit:ExposeToLibDataBroker()
    local adopted, adoptReason = BrokerKit:AdoptFromLibDataBroker()
    ctx:Expect(exposed):ToBe(false)
    ctx:Expect(exposeReason):ToBe("absent")
    ctx:Expect(adopted):ToBe(false)
    ctx:Expect(adoptReason):ToBe("absent")

    installStandIn(ctx, false)
    exposed, exposeReason = BrokerKit:ExposeToLibDataBroker()
    adopted, adoptReason = BrokerKit:AdoptFromLibDataBroker()
    ctx:Expect(exposed):ToBe(false)
    ctx:Expect(exposeReason):ToBe("absent")
    ctx:Expect(adopted):ToBe(false)
    ctx:Expect(adoptReason):ToBe("absent")
  end
)

libDataBroker:Test(
  "ExposeToLibDataBroker registers objects into the stand-in LibDataBroker-1.1 with their attributes, follows later objects and each field write with one data-object write, and a second call returns false, 'already'",
  function(ctx)
    local library = installStandIn(ctx, true)
    local displayLog = watchLibrary(library)
    local counters = StandIn.counters

    local before = BrokerKit:New(
      uniqueName("ExposedBefore"),
      { text = "before", icon = QUESTION_MARK_ICON, rank = 7 }
    )
    exposeIntoStandIn(ctx)
    local again, againReason = BrokerKit:ExposeToLibDataBroker()
    ctx:Expect(again):ToBe(false)
    ctx:Expect(againReason):ToBe("already")

    local mirror = library:GetDataObjectByName(before.name)
    ctx:Expect(type(mirror)):ToBe("table")
    ctx:Expect(library:GetNameByDataObject(mirror)):ToBe(before.name)
    ctx:Expect(mirror.type):ToBe("data source")
    ctx:Expect(mirror.text):ToBe("before")
    ctx:Expect(mirror.icon):ToBe(QUESTION_MARK_ICON)
    ctx:Expect(mirror.rank):ToBe(7)
    ctx:Expect(BrokerKit:IsForeign(before)):ToBe(false)

    local after = BrokerKit:New(uniqueName("ExposedAfter"), { text = "after" })
    ctx:Expect(library:GetDataObjectByName(after.name).text):ToBe("after")
    ctx:Expect(countOf(displayLog.created, after.name)):ToBe(1)
    ctx:Expect(BrokerKit:Get(after.name)):ToBe(after)

    local fires = 0
    track(before:OnChange("text", function()
      fires = fires + 1
    end))
    local writesBefore = counters.changedWrites
    before.text = "changed"
    ctx:Expect(counters.changedWrites - writesBefore):ToBe(1)
    ctx:Expect(mirror.text):ToBe("changed")
    ctx:Expect(fires):ToBe(1)
    ctx:Expect(countOf(displayLog.changed, before.name .. ".text")):ToBe(1)

    before.text = "changed"
    ctx:Expect(counters.changedWrites - writesBefore):ToBe(1)
    ctx:Expect(fires):ToBe(1)
  end
)

libDataBroker:Test(
  "AdoptFromLibDataBroker wraps the stand-in's data objects as foreign objects holding copies of their attributes, follows objects created later, even one nobody wrote to yet, and a second call returns false, 'already'",
  function(ctx)
    local library = installStandIn(ctx, true)
    local added = {}
    track(BrokerKit:OnObjectAdded(function(object)
      added[#added + 1] = object.name
    end))

    local nameBefore = uniqueName("ForeignBefore")
    library:NewDataObject(nameBefore, {
      type = "launcher",
      icon = QUESTION_MARK_ICON,
      text = "foreign",
      origin = "another addon",
    })
    adoptFromStandIn(ctx)
    local again, againReason = BrokerKit:AdoptFromLibDataBroker()
    ctx:Expect(again):ToBe(false)
    ctx:Expect(againReason):ToBe("already")

    local foreignBefore = BrokerKit:Get(nameBefore)
    ctx:Expect(type(foreignBefore)):ToBe("table")
    ctx:Expect(BrokerKit:IsForeign(foreignBefore)):ToBe(true)
    ctx:Expect(foreignBefore.name):ToBe(nameBefore)
    ctx:Expect(foreignBefore.type):ToBe("launcher")
    ctx:Expect(foreignBefore.icon):ToBe(QUESTION_MARK_ICON)
    ctx:Expect(foreignBefore.text):ToBe("foreign")
    ctx:Expect(foreignBefore.origin):ToBe("another addon")

    local nameAfter = uniqueName("ForeignAfter")
    library:NewDataObject(nameAfter, { text = "later" })
    ctx:Expect(BrokerKit:Get(nameAfter).text):ToBe("later")

    -- A data object created with no attributes: the real library's `pairs`
    -- raises for it until its first write, and BrokerKit adopts it empty.
    local nameEmpty = uniqueName("ForeignEmpty")
    local emptyDataObject = library:NewDataObject(nameEmpty)
    local foreignEmpty = BrokerKit:Get(nameEmpty)
    ctx:Expect(type(foreignEmpty)):ToBe("table")
    ctx:Expect(foreignEmpty.text):ToBeNil()
    emptyDataObject.text = "first write"
    ctx:Expect(foreignEmpty.text):ToBe("first write")

    ctx:Expect(countOf(added, nameBefore)):ToBe(1)
    ctx:Expect(countOf(added, nameAfter)):ToBe(1)
    ctx:Expect(countOf(added, nameEmpty)):ToBe(1)
  end
)

libDataBroker:Test(
  "a foreign object is read-only: a field write and Set are refused at the calling line naming it foreign, New of its name is refused, and a write into its data object reaches BrokerKit and fires OnChange once",
  function(ctx)
    local library = installStandIn(ctx, true)
    adoptFromStandIn(ctx)
    local counters = StandIn.counters

    local name = uniqueName("ForeignWrites")
    local dataObject = library:NewDataObject(name, { text = "one" })
    local foreign = BrokerKit:Get(name)
    ctx:Expect(BrokerKit:IsForeign(foreign)):ToBe(true)

    local changes = {}
    track(foreign:OnChange("text", function(_, _, value, previous)
      changes[#changes + 1] = { value = value, previous = previous }
    end))
    local writesBefore = counters.changedWrites
    dataObject.text = "two"
    dataObject.text = "two"
    ctx:Expect(changes):ToEqual({ { value = "two", previous = "one" } })
    ctx:Expect(foreign.text):ToBe("two")
    ctx:Expect(counters.changedWrites - writesBefore):ToBe(1)

    local foreignMessage = ('BrokerKit.Object:Set object "%s" is foreign (adopted from LibDataBroker) and read-only'):format(
      name
    )
    local lines = { start = 0 }
    expectErrorAtCallingLine(ctx, function()
      lines.start = currentLine()
      foreign.text = "mine"
    end, lines, foreignMessage)
    expectErrorAtCallingLine(ctx, function()
      lines.start = currentLine()
      foreign:Set("text", "mine")
    end, lines, foreignMessage)
    expectErrorAtCallingLine(
      ctx,
      function()
        lines.start = currentLine()
        BrokerKit:New(name)
      end,
      lines,
      ('BrokerKit:New name "%s" is already taken by a foreign LibDataBroker object'):format(name)
    )
    ctx:Expect(foreign.text):ToBe("two")
    ctx:Expect(#changes):ToBe(1)
  end
)

libDataBroker:Test(
  "with both directions on nothing echoes: a new object is not adopted back and fires OnObjectAdded once, its write is one data-object write and one OnChange, and another addon's write into its data object is ignored",
  function(ctx)
    local library = installStandIn(ctx, true)
    exposeIntoStandIn(ctx)
    adoptFromStandIn(ctx)
    local counters = StandIn.counters

    local name = uniqueName("NoEcho")
    local addedCount = 0
    track(BrokerKit:OnObjectAdded(function(object)
      if object.name == name then
        addedCount = addedCount + 1
      end
    end))
    local object = BrokerKit:New(name, { text = "ours" })
    ctx:Expect(addedCount):ToBe(1)
    ctx:Expect(BrokerKit:Get(name)):ToBe(object)
    ctx:Expect(BrokerKit:IsForeign(object)):ToBe(false)

    local mirror = library:GetDataObjectByName(name)
    ctx:Expect(type(mirror)):ToBe("table")
    ctx:Expect(mirror.text):ToBe("ours")

    local fires = 0
    track(object:OnChange(function()
      fires = fires + 1
    end))
    local writesBefore = counters.changedWrites
    object.text = "ours 2"
    ctx:Expect(counters.changedWrites - writesBefore):ToBe(1)
    ctx:Expect(fires):ToBe(1)
    ctx:Expect(mirror.text):ToBe("ours 2")

    mirror.text = "intruder"
    ctx:Expect(object.text):ToBe("ours 2")
    ctx:Expect(fires):ToBe(1)
    ctx:Expect(counters.changedWrites - writesBefore):ToBe(2)
  end
)

libDataBroker:Test(
  "a display reading the stand-in calls our OnClick with UIParent through the data object, and a foreign OnTooltipShow read through BrokerKit fills GameTooltip, hidden again in the same step",
  function(ctx)
    local library = installStandIn(ctx, true)
    exposeIntoStandIn(ctx)
    adoptFromStandIn(ctx)

    local clicks = {}
    local ours = BrokerKit:New(uniqueName("DisplayOurs"), {
      type = "launcher",
      icon = QUESTION_MARK_ICON,
      OnClick = function(frame, button)
        clicks[#clicks + 1] = { frameIsUIParent = rawequal(frame, uiParent), button = button }
      end,
    })
    local mirror = library:GetDataObjectByName(ours.name)
    ctx:Expect(type(mirror)):ToBe("table")
    mirror.OnClick(uiParent, "LeftButton")
    ctx:Expect(clicks):ToEqual({ { frameIsUIParent = true, button = "LeftButton" } })

    local foreignName = uniqueName("DisplayForeign")
    library:NewDataObject(foreignName, {
      text = "foreign",
      OnTooltipShow = function(tooltip)
        tooltip:AddLine(FOREIGN_TOOLTIP_LINE)
      end,
    })
    local foreign = BrokerKit:Get(foreignName)
    ctx:Expect(type(foreign.OnTooltipShow)):ToBe("function")
    local reading = fillTooltipOnce(foreign.OnTooltipShow)
    logTooltipReading(ctx, reading)
    ctx:Expect(reading.succeeded):ToBe(true)
    ctx:Expect(reading.lines):ToEqual({ FOREIGN_TOOLTIP_LINE })
    ctx:Expect(gameTooltip:IsShown() == true):ToBe(false)
  end
)

-- brokerKit.allocation ------------------------------------------------------------------------

local allocation = newSuite("allocation")

allocation:Test(
  "reading attributes as plain fields, object.name, object:Get and BrokerKit:Get allocate nothing over 5000 rounds",
  function(ctx)
    local name = uniqueName("AllocationReads")
    local object = BrokerKit:New(name, { text = TEXT_A, value = 1 })
    local sink = nil
    expectNoAllocation(ctx, "five reads", ALLOCATION_CALLS, function()
      sink = object.text
      sink = object.value
      sink = object.name
      sink = object:Get("text")
      sink = BrokerKit:Get(name)
    end)
    ctx:Expect(sink):ToBe(object)
  end
)

allocation:Test(
  "field writes and Set of a new value with a per-attribute and an any-attribute listener connected, and writes of the value already held, allocate nothing over 5000 rounds",
  function(ctx)
    local name = uniqueName("AllocationWrites")
    local object = BrokerKit:New(name, { text = TEXT_A, value = 1 })
    local mirrored = bridgeSession.exposed
      and type(StandIn.GetLibrary():GetDataObjectByName(name)) == "table"
    ctx:Log("mirrored into the stand-in by an earlier bridge test: " .. tostring(mirrored))

    local perAttribute = 0
    local anyAttribute = 0
    track(object:OnChange("text", function()
      perAttribute = perAttribute + 1
    end))
    track(object:OnChange(function()
      anyAttribute = anyAttribute + 1
    end))

    expectNoAllocation(
      ctx,
      "four changing writes and two unchanged ones",
      ALLOCATION_CALLS,
      function()
        object.text = TEXT_B
        object.text = TEXT_A
        object:Set("value", 2)
        object:Set("value", 1)
        object.text = TEXT_A
        object:Set("value", 1)
      end
    )
    -- The warm-up call counts too.
    ctx:Expect(perAttribute):ToBe(2 * (ALLOCATION_CALLS + 1))
    ctx:Expect(anyAttribute):ToBe(4 * (ALLOCATION_CALLS + 1))
    ctx:Expect(object.text):ToBe(TEXT_A)
  end
)

allocation:Test(
  "500 full Iterate walks over every object of the session allocate nothing while no object is added",
  function(ctx)
    local objectCount = #BrokerKit:Objects()
    local steps = 0
    expectNoAllocation(ctx, "a full Iterate walk", ITERATE_WALKS, function()
      for _ in BrokerKit:Iterate() do
        steps = steps + 1
      end
    end)
    ctx:Log(("%d objects per walk"):format(objectCount))
    ctx:Expect(steps):ToBe(objectCount * (ITERATE_WALKS + 1))
  end
)

-- brokerKit.errors ----------------------------------------------------------------------------

local errors = newSuite("errors")

errors:Test(
  "a field write of the wrong type, clearing type, writing name and Set of a table icon are refused at the writing line in BrokerKitSuite.lua",
  function(ctx)
    local name = uniqueName("Refusals")
    local object = BrokerKit:New(name, { text = "kept" })
    local lines = { start = 0 }
    expectErrorAtCallingLine(ctx, function()
      lines.start = currentLine()
      object.text = 5
    end, lines, 'BrokerKit.Object:Set attribute "text" must be a string')
    expectErrorAtCallingLine(ctx, function()
      lines.start = currentLine()
      object.type = nil
    end, lines, 'BrokerKit.Object:Set attribute "type" must be "data source" or "launcher"')
    expectErrorAtCallingLine(ctx, function()
      lines.start = currentLine()
      object.name = "renamed"
    end, lines, 'BrokerKit.Object:Set attribute "name" is reserved')
    expectErrorAtCallingLine(ctx, function()
      lines.start = currentLine()
      object:Set("icon", {})
    end, lines, 'BrokerKit.Object:Set attribute "icon" must be a string or a number')
    ctx:Expect(object.text):ToBe("kept")
    ctx:Expect(object.type):ToBe("data source")
    ctx:Expect(object.name):ToBe(name)
    ctx:Expect(object.icon):ToBeNil()
  end
)

errors:Test(
  "New refuses a taken name, a definition that is not a table, a reserved or mistyped attribute and a call with a dot at the calling line, and a refused definition leaves no object behind",
  function(ctx)
    local takenName = uniqueName("Taken")
    BrokerKit:New(takenName)
    local refusedName = uniqueName("Refused")
    local newWithDot = BrokerKit.New
    local lines = { start = 0 }
    expectErrorAtCallingLine(ctx, function()
      lines.start = currentLine()
      BrokerKit:New(takenName)
    end, lines, ('BrokerKit:New name "%s" is already taken'):format(takenName))
    expectErrorAtCallingLine(ctx, function()
      lines.start = currentLine()
      BrokerKit:New(refusedName, "text")
    end, lines, "BrokerKit:New definition must be a table")
    expectErrorAtCallingLine(ctx, function()
      lines.start = currentLine()
      BrokerKit:New(refusedName, { Set = 1 })
    end, lines, 'BrokerKit:New attribute "Set" is reserved')
    expectErrorAtCallingLine(ctx, function()
      lines.start = currentLine()
      BrokerKit:New(refusedName, { text = "fine", OnClick = "not a function" })
    end, lines, 'BrokerKit:New attribute "OnClick" must be a function')
    expectErrorAtCallingLine(ctx, function()
      lines.start = currentLine()
      newWithDot(refusedName)
    end, lines, "BrokerKit:New must be called on the BrokerKit facade; use BrokerKit:New(...)")
    ctx:Expect(BrokerKit:Get(refusedName)):ToBeNil()
  end
)

errors:Test(
  "an object method called with a dot, a listener that is not a function, Get of 'name' and IsForeign of UIParent are refused at the calling line",
  function(ctx)
    local object = BrokerKit:New(uniqueName("Receivers"))
    local setWithDot = object.Set
    local lines = { start = 0 }
    expectErrorAtCallingLine(ctx, function()
      lines.start = currentLine()
      setWithDot(uiParent, "text", "x")
    end, lines, "BrokerKit.Object:Set must be called on a broker object; use object:Set(...)")
    expectErrorAtCallingLine(ctx, function()
      lines.start = currentLine()
      object:OnChange("text", "not a function")
    end, lines, "BrokerKit.Object:OnChange callback must be a function")
    expectErrorAtCallingLine(ctx, function()
      lines.start = currentLine()
      BrokerKit:OnObjectAdded(true)
    end, lines, "BrokerKit:OnObjectAdded callback must be a function")
    expectErrorAtCallingLine(ctx, function()
      lines.start = currentLine()
      object:Get("name")
    end, lines, 'BrokerKit.Object:Get attribute "name" is reserved')
    expectErrorAtCallingLine(ctx, function()
      lines.start = currentLine()
      BrokerKit:IsForeign(uiParent)
    end, lines, "BrokerKit:IsForeign object must be a broker object")
    ctx:Expect(object.text):ToBeNil()
  end
)

errors:Test(
  "SetLimits with an unknown limit, or with maxObjects 0 beside a valid maxAttributes, is refused at the calling line and the limits stay as they were",
  function(ctx)
    local limitsBefore = BrokerKit:GetLimits()
    local lines = { start = 0 }
    expectErrorAtCallingLine(ctx, function()
      lines.start = currentLine()
      BrokerKit:SetLimits({ maxWidgets = 1 })
    end, lines, "BrokerKit:SetLimits limits.maxWidgets is not a recognised limit")
    expectErrorAtCallingLine(
      ctx,
      function()
        lines.start = currentLine()
        BrokerKit:SetLimits({ maxAttributes = 64, maxObjects = 0 })
      end,
      lines,
      "BrokerKit:SetLimits limits.maxObjects must be a positive integer or BrokerKit.UNBOUNDED"
    )
    ctx:Expect(BrokerKit:GetLimits()):ToEqual(limitsBefore)
  end
)

-- brokerKit.secrets ---------------------------------------------------------------------------

local secrets = newSuite("secrets")

--- Why the secrets tests are skipped on a client without the two functions.
local SECRETS_SKIP_REASON =
  "the client has no issecretvalue and secretwrap; the secret path was not exercised"

---Register `body` as a test when the client can make a secret value, and as a
---skipped test naming why otherwise: the client lacks the two functions, or it
---has them but `issecretvalue` does not report what `secretwrap` returns as
---secret (`Harness:CanMakeSecrets`, measured once; Classic Era and Mists
---Classic document both functions, so their presence alone proves nothing).
---@param name string
---@param body fun(ctx: TestKit.Context)
local function secretTest(name, body)
  if not SECRETS_AVAILABLE then
    secrets:Skip(name, SECRETS_SKIP_REASON)
  elseif not Harness:CanMakeSecrets() then
    secrets:Skip(name, Harness.NO_SECRETS_REASON)
  else
    secrets:Test(name, body)
  end
end

secretTest(
  "the client's handling of a secret key on a broker object is logged: reading and writing object[secret] both raise, and the object is unchanged",
  function(ctx)
    local object = BrokerKit:New(uniqueName("SecretKeys"))
    local secretKey = makeSecret(ctx, "text")
    local readOk, readResult = pcall(function()
      return object[secretKey]
    end)
    local writeOk, writeResult = pcall(function()
      object[secretKey] = "x"
    end)
    ctx:Log("object[secret] read: " .. describeOutcome(readOk, readResult))
    ctx:Log("object[secret] = 'x': " .. describeOutcome(writeOk, writeResult))
    ctx:Expect(readOk):ToBe(false)
    ctx:Expect(writeOk):ToBe(false)
    ctx:Expect(object.text):ToBeNil()
  end
)

secretTest(
  "a secret text is refused at the calling line by a field write, by Set and in a New definition; the object keeps its text, no listener runs and no object is created",
  function(ctx)
    local object = BrokerKit:New(uniqueName("SecretText"), { text = "visible" })
    local fires = 0
    track(object:OnChange(function()
      fires = fires + 1
    end))
    local secretText = makeSecret(ctx, "hidden")
    local refusedName = uniqueName("SecretDefinition")
    local lines = { start = 0 }
    expectErrorAtCallingLine(ctx, function()
      lines.start = currentLine()
      object.text = secretText
    end, lines, 'BrokerKit.Object:Set attribute "text" must not be a secret value')
    expectErrorAtCallingLine(ctx, function()
      lines.start = currentLine()
      object:Set("text", secretText)
    end, lines, 'BrokerKit.Object:Set attribute "text" must not be a secret value')
    expectErrorAtCallingLine(ctx, function()
      lines.start = currentLine()
      BrokerKit:New(refusedName, { text = secretText })
    end, lines, 'BrokerKit:New attribute "text" must not be a secret value')
    ctx:Expect(object.text):ToBe("visible")
    ctx:Expect(fires):ToBe(0)
    ctx:Expect(BrokerKit:Get(refusedName)):ToBeNil()
  end
)

secretTest(
  "a secret custom attribute is stored without comparison: read back secret by field and Get, every write of it fires, listeners get it still secret, and clearing it fires with the secret as previous",
  function(ctx)
    local object = BrokerKit:New(uniqueName("SecretCustom"))
    local received = {}
    track(object:OnChange("health", function(_, _, value, previous)
      received[#received + 1] = {
        valueSecret = isSecretValue(value) == true,
        valueType = type(value),
        previousSecret = isSecretValue(previous) == true,
        previousType = type(previous),
      }
    end))
    local secret = makeSecret(ctx, 42)

    object.health = secret
    object.health = secret
    object:Set("health", secret)
    expectSameSecret(ctx, object.health, secret)
    expectSameSecret(ctx, object:Get("health"), secret)
    object.health = nil

    ctx:Expect(received):ToEqual({
      { valueSecret = true, valueType = "number", previousSecret = false, previousType = "nil" },
      { valueSecret = true, valueType = "number", previousSecret = true, previousType = "number" },
      { valueSecret = true, valueType = "number", previousSecret = true, previousType = "number" },
      { valueSecret = false, valueType = "nil", previousSecret = true, previousType = "number" },
    })
    ctx:Expect(type(object.health)):ToBe("nil")
  end
)

secretTest(
  "secret names are refused before any comparison at the calling line: New and Get of a secret name, Set, Get and OnChange of a secret attribute name, a secret receiver and a secret SetLimits value; the limits stay as they were",
  function(ctx)
    local object = BrokerKit:New(uniqueName("SecretNames"))
    local secretName = makeSecret(ctx, "SecretName")
    local getWithDot = BrokerKit.Get
    local limitsBefore = BrokerKit:GetLimits()
    local secretLimit = makeSecret(ctx, 512)
    local lines = { start = 0 }
    expectErrorAtCallingLine(ctx, function()
      lines.start = currentLine()
      BrokerKit:New(secretName)
    end, lines, "BrokerKit:New name must not be a secret value")
    expectErrorAtCallingLine(ctx, function()
      lines.start = currentLine()
      BrokerKit:Get(secretName)
    end, lines, "BrokerKit:Get name must not be a secret value")
    expectErrorAtCallingLine(ctx, function()
      lines.start = currentLine()
      object:Set(secretName, "x")
    end, lines, "BrokerKit.Object:Set attribute name must not be a secret value")
    expectErrorAtCallingLine(ctx, function()
      lines.start = currentLine()
      object:Get(secretName)
    end, lines, "BrokerKit.Object:Get attribute name must not be a secret value")
    expectErrorAtCallingLine(ctx, function()
      lines.start = currentLine()
      object:OnChange(secretName, function() end)
    end, lines, "BrokerKit.Object:OnChange attribute name must not be a secret value")
    expectErrorAtCallingLine(ctx, function()
      lines.start = currentLine()
      getWithDot(secretName, "x")
    end, lines, "BrokerKit:Get must be called on the BrokerKit facade; use BrokerKit:Get(...)")
    expectErrorAtCallingLine(ctx, function()
      lines.start = currentLine()
      BrokerKit:SetLimits({ maxObjects = secretLimit })
    end, lines, "BrokerKit:SetLimits limits.maxObjects must not be a secret value")
    ctx:Expect(BrokerKit:GetLimits()):ToEqual(limitsBefore)
  end
)

secretTest(
  "a secret custom attribute of an exposed object is never written into the stand-in LibDataBroker-1.1, and a secret another addon writes into a foreign data object reaches BrokerKit still secret",
  function(ctx)
    local library = installStandIn(ctx, true)
    exposeIntoStandIn(ctx)
    adoptFromStandIn(ctx)
    local counters = StandIn.counters

    local object = BrokerKit:New(uniqueName("SecretExposed"), { text = "plain" })
    local mirror = library:GetDataObjectByName(object.name)
    ctx:Expect(type(mirror)):ToBe("table")
    local secretsBefore = counters.secretsReceived
    local writesBefore = counters.changedWrites
    local hidden = makeSecret(ctx, 7)
    object.hidden = hidden
    expectSameSecret(ctx, object.hidden, hidden)
    ctx:Expect(type(mirror.hidden)):ToBe("nil")
    ctx:Expect(counters.secretsReceived - secretsBefore):ToBe(0)
    ctx:Expect(counters.changedWrites - writesBefore):ToBe(0)

    local foreignName = uniqueName("SecretForeign")
    local dataObject = library:NewDataObject(foreignName, { text = "plain" })
    local foreign = BrokerKit:Get(foreignName)
    local deliveries = {}
    track(foreign:OnChange("level", function(_, _, value)
      deliveries[#deliveries + 1] = isSecretValue(value) == true
    end))
    local level = makeSecret(ctx, 60)
    dataObject.level = level
    ctx:Expect(counters.secretsReceived - secretsBefore):ToBe(1)
    ctx:Expect(deliveries):ToEqual({ true })
    expectSameSecret(ctx, foreign.level, level)
  end
)
