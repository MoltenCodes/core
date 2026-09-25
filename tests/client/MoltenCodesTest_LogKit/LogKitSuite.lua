-- MoltenCodes Test: LogKitSuite.lua
--
-- Real-client suites for the `logKit` package. The Busted specs under
-- packages/logKit/tests/ prove LogKit on a stock Lua 5.1 with a scripted clock,
-- a scripted error handler, a fake chat frame and stand-ins for CommandKit and
-- SettingsKit; these prove, inside the game client with the installed
-- MoltenCodes addon, what that fixture can only simulate:
--
--   * the installed facade and its committed revision, and the host
--     facilities docs/API.md names (`GetTimePreciseSec`, `geterrorhandler`,
--     `SlashCmdList`, `DEFAULT_CHAT_FRAME`, CommandKit and SettingsKit found
--     through `Registry:Find`);
--   * level gating and lazy formatting on the client's own `string.format`,
--     positional specifiers (`%2$s`) included: a disabled call reads neither
--     its message nor its arguments, an enabled one formats once;
--   * the journal on a real SignalKit journal, stamped with the client's
--     `GetTimePreciseSec`, and its filters;
--   * table sinks, a `ChatSink` bound to a hidden `ScrollingMessageFrame`, and
--     one `ChatSink()` line in the real chat frame (the one visible effect);
--   * `/log` registered through `RegisterCommand` in the client's
--     `SlashCmdList` and dispatched without typing, by calling the function the
--     client keeps there, as the CommandKit suite does, with the client's
--     `C_AddOns.DoesAddOnExist` deciding which typed names get a level;
--   * `BindLevels` over an in-memory SettingsKit database;
--   * `secretwrap` values as format arguments, replaced by the placeholder,
--     with no client compare or concatenation error escaping;
--   * a raising sink and a bad format string reported through the error
--     handler `seterrorhandler` installed for the one call;
--   * that a disabled call, and an enabled call with a table sink, allocate
--     nothing on the client's own collector;
--   * argument errors pointing at this file as the client names it.
--
-- Nothing here needs combat, a group or an instance. The one visible effect is
-- a single line in the default chat frame, written by the `ChatSink()` test on
-- purpose. No client setting changes and no request goes to the server.
--
-- Run with `/mct run logKit`; tests/client/MoltenCodesTest_LogKit/EXPECTED.md
-- lists what the chat frame should show.
--
-- What a run leaves behind. Every test starts from the session's global
-- level, limits and SettingsKit binding, and its After hook puts all three
-- back, whatever the outcome: sinks the test added are removed, the levels of
-- this file's two loggers and of the harness's addon name are put back, a
-- binding another addon held is unbound for the test and bound again
-- afterwards, and the scratch globals of the BindLevels tests are removed. What
-- LogKit keeps for the session, because it never removes them: this file's
-- two loggers (`MoltenCodesTest_LogKit` and `MoltenCodesTest_LogKit.Other`,
-- two of the 256 `maxLoggers`), the `/log` command (registered once per
-- session; its output goes back to the chat frame), the journal entries the
-- tests logged (the allocation tests log 4000 messages, so the 1024-entry
-- journal then holds this suite's lines), one hidden `ScrollingMessageFrame`
-- (the client never frees a Frame) and, in SettingsKit's package state, the
-- small database of each BindLevels test. Nothing is written to a saved
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
local LOG_KIT_API = 1
local SIGNAL_KIT_API = 1
local COMMAND_KIT_API = 1
local SETTINGS_KIT_API = 1
local SCHEMA_KIT_API = 1
local PACKAGE_ID = "logKit"

--- The second logger's name. The first is this addon's own name.
local OTHER_LOGGER_NAME = addonName .. ".Other"

--- A name the `/log` test types that no code passes to `ForAddon` and no
--- installed addon has, as a typo would be: `/log` refuses a level for it.
local TYPED_ADDON_NAME = addonName .. ".Typed"

--- The harness addon this addon depends on: installed and loaded, and no code
--- passes it to `ForAddon`, so `/log` accepts a level for it without a logger.
local INSTALLED_ADDON_NAME = "MoltenCodesTest"

--- An addon name the `maxLoggers` test is refused a logger for.
local CAPPED_ADDON_NAME = addonName .. ".Capped"

--- The slash name `RegisterCommand` registers.
local LOG_SLASH_NAME = "/log"

--- The `SlashCmdList` key CommandKit writes for `/log` in LogKit's manual
--- scope (CommandKit docs/API.md: `MOLTENCODES_<NAME>`). Another owner that
--- registered `log` first may have given it another key; the tests then look
--- the key up by its `SLASH_<key>1` global.
local LOG_COMMAND_KEY = "MOLTENCODES_LOG"

--- The colour escapes docs/API.md lists for warn and error.
local WARN_COLOUR = "|cffffa500"
local ERROR_COLOUR = "|cffff4040"

--- The line the `ChatSink()` test writes to the real chat frame on purpose.
local VISIBLE_MESSAGE = "LogKit test: this line reached the chat frame through ChatSink()"

--- What the failing sinks raise.
local SINK_FAILURE = "the probe sink failed on purpose"

--- Prefix of the scratch globals the BindLevels tests open databases over.
--- They are not saved variables, so nothing reaches the disk.
local SCRATCH_GLOBAL_PREFIX = "MoltenCodesTest_LogKitScratch"

--- How many calls the disabled-call allocation guard makes of each method.
local DISABLED_ALLOCATION_CYCLES = 5000

--- How many messages each enabled-call allocation guard delivers. Every one is
--- journaled, so the count stays close to the journal's capacity.
local ENABLED_ALLOCATION_CYCLES = 2000

--- Kilobytes an allocation guard tolerates: a stray allocation by the client
--- between the two readings, not a per-call one.
local ALLOCATION_TOLERANCE_KB = 1

-- Resolving the client and the framework ---------------------------------------------

---Read a client global, or `nil`.
---@param name string
---@return any
local function readHost(name)
  -- The clock, the error handler functions, the slash table, the chat frames,
  -- CreateFrame, UIParent and the secret-value functions are World of
  -- Warcraft client globals, reachable only through the global table.
  -- selene: allow(global_usage)
  return rawget(_G, name)
end

---Set or remove a scratch global this file owns: the table a BindLevels
---test opens a SettingsKit database over.
---@param name string
---@param value any
local function writeOwnGlobal(name, value)
  -- The scratch globals are created and removed by this file only.
  -- selene: allow(global_usage)
  rawset(_G, name, value)
end

---@type Registry
local Registry = rawget(rawget(namespace, "Registries") or {}, REGISTRY_API)
if type(Registry) ~= "table" then
  error(addonName .. " requires the MoltenCodes addon (Registry API 2); reinstall it", 0)
end

-- LogKit, CommandKit, SettingsKit and SchemaKit are not in the language-server
-- workspace of tests/client (its .luarc.json lists TestKit's dependency
-- closure only), so their facades and objects are typed `any` here.

---@type any
local LogKit = Registry:Get(PACKAGE_ID, LOG_KIT_API)
---@type SignalKit|nil
local SignalKit = Registry:Get("signalKit", SIGNAL_KIT_API)
if type(LogKit) == "nil" or type(SignalKit) == "nil" then
  error(addonName .. " requires LogKit API 1 and SignalKit API 1 in the MoltenCodes addon", 0)
end
---@cast SignalKit SignalKit

--- The clock LogKit stamps records with. The tests measure against the same
--- one, so the addon refuses to load on a client without it.
local getTimePreciseSec = readHost("GetTimePreciseSec")
local createFrame = readHost("CreateFrame")
local uiParent = readHost("UIParent")
if
  type(getTimePreciseSec) ~= "function"
  or type(createFrame) ~= "function"
  or type(uiParent) ~= "table"
then
  error(addonName .. " requires the client's GetTimePreciseSec, CreateFrame and UIParent", 0)
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
local function now()
  return getTimePreciseSec()
end

--- The two loggers every suite uses, created once at load as docs/API.md
--- recommends. They count against `maxLoggers` for the session.
local mainLogger, mainRefusal = LogKit:ForAddon(addonName)
local otherLogger, otherRefusal = LogKit:ForAddon(OTHER_LOGGER_NAME)
if type(mainLogger) == "nil" or type(otherLogger) == "nil" then
  error(
    addonName
      .. " could not create its loggers ("
      .. tostring(mainRefusal or otherRefusal)
      .. "); another addon filled maxLoggers",
    0
  )
end

--- Every logger this file owns, for the level snapshot.
local OWN_LOGGERS = { mainLogger, otherLogger }

-- LogKit's package state ------------------------------------------------------------------
--
-- Three things only the package state reaches (docs/INTERNALS.md, "Package
-- state"): the SignalKit journal behind `History`, the CommandKit scope `/log`
-- writes through, and the SettingsKit binding another addon may hold. The
-- tests read them; the only write is the command scope's sink, through
-- CommandKit's own `SetSink`, put back by the After hook.

---LogKit's package state.
---@return table
local function logKitState()
  return rawget(LogKit, "_state")
end

---The SignalKit journal LogKit records into now. `SetLimits` with a new
---`journalCapacity` replaces it, so it is read at every use.
---@return SignalKit.Journal
local function currentJournal()
  return rawget(logKitState(), "journal")
end

---The CommandKit scope `/log` is registered in, or `false` before
---`RegisterCommand` created it.
---@return any
local function commandScope()
  return rawget(rawget(logKitState(), "command"), "scope")
end

---How many sinks are registered, this file's included.
---@return integer
local function registeredSinkCount()
  local state = logKitState()
  return #rawget(state, "sinks") - rawget(state, "pendingRemovals")
end

-- The session snapshot and the After hook -------------------------------------------------

--- What the running test found when it started, put back by the After hook.
local snapshot = {
  ---@type string|nil
  globalLevel = nil,
  ---@type table|nil
  limits = nil,
  --- Logger to its override level name, or `false` when it had none.
  ---@type table<table, string|false>
  loggerLevels = {},
  --- The database another addon had bound, unbound for the test.
  ---@type table|false
  previousDatabase = false,
}

--- Sink handles the running test added; the After hook removes them.
---@type table[]
local trackedSinks = {}

--- Scratch globals the running test created; the After hook removes them.
---@type string[]
local scratchGlobals = {}

--- Serial of the next scratch global name.
local scratchSerial = 0

--- Per-test restores that must run before the session state is put back
--- (the harness addon's level, the command scope's sink), newest last.
---@type fun()[]
local pendingRestores = {}

---Record the session's global level, limits, this file's logger levels and
---any SettingsKit binding, and unbind that binding for the test so nothing
---the test sets is written to another addon's saved variables. The Before
---hook of every suite.
local function captureSession()
  snapshot.globalLevel = LogKit:GetGlobalLevel()
  snapshot.limits = LogKit:GetLimits()
  for _, logger in ipairs(OWN_LOGGERS) do
    local level, source = logger:GetLevel()
    snapshot.loggerLevels[logger] = source == "addon" and level or false
  end
  local binding = rawget(logKitState(), "binding")
  snapshot.previousDatabase = false
  if binding then
    snapshot.previousDatabase = binding.db
    LogKit:BindLevels(nil)
  end
end

---Add `sink` through `LogKit:AddSink` and remember its handle for the After
---hook.
---@param ctx TestKit.Context
---@param sink any
---@return table handle
local function addTrackedSink(ctx, sink)
  local handle, reason = LogKit:AddSink(sink)
  if type(handle) == "nil" then
    ctx:Fail("LogKit:AddSink refused the probe sink (" .. tostring(reason) .. ")")
  end
  ---@cast handle table
  trackedSinks[#trackedSinks + 1] = handle
  return handle
end

---A scratch global name no global uses yet, removed by the After hook.
---@return string
local function newScratchGlobal()
  scratchSerial = scratchSerial + 1
  local name = SCRATCH_GLOBAL_PREFIX .. "_" .. scratchSerial
  while type(readHost(name)) ~= "nil" do
    scratchSerial = scratchSerial + 1
    name = SCRATCH_GLOBAL_PREFIX .. "_" .. scratchSerial
  end
  scratchGlobals[#scratchGlobals + 1] = name
  return name
end

---Put back everything the running test changed, in dependency order: the
---per-test restores, the sinks, the binding (so restoring a level writes
---nothing), the logger levels, the global level, the limits, the scratch
---globals, and last the binding another addon held. Every step runs under
---`pcall` so one failure cannot keep the others from running. The After hook
---of every suite.
local function restoreSession()
  for index = #pendingRestores, 1, -1 do
    local restore = pendingRestores[index]
    pendingRestores[index] = nil
    pcall(restore)
  end
  for index = #trackedSinks, 1, -1 do
    pcall(LogKit.RemoveSink, LogKit, trackedSinks[index])
    trackedSinks[index] = nil
  end
  pcall(LogKit.BindLevels, LogKit, nil)
  for _, logger in ipairs(OWN_LOGGERS) do
    pcall(logger.SetLevel, logger, snapshot.loggerLevels[logger] or nil)
  end
  pcall(LogKit.SetGlobalLevel, LogKit, snapshot.globalLevel)
  if type(snapshot.limits) == "table" then
    pcall(LogKit.SetLimits, LogKit, snapshot.limits)
  end
  for index = #scratchGlobals, 1, -1 do
    writeOwnGlobal(scratchGlobals[index], nil)
    scratchGlobals[index] = nil
  end
  if snapshot.previousDatabase then
    pcall(LogKit.BindLevels, LogKit, snapshot.previousDatabase)
    snapshot.previousDatabase = false
  end
end

---Register a suite of this package whose tests start from a recorded session
---state and end with it put back.
---@param part string
---@return TestKit.Suite
local function newSuite(part)
  local suite = Harness:Suite(PACKAGE_ID, part, addonName)
  suite:Before(captureSession)
  suite:After(restoreSession)
  return suite
end

-- Capturing sinks -------------------------------------------------------------------------

---A copy of one record, as a capturing sink keeps it.
---@class MoltenCodesTest.LogKit.CapturedRecord
---@field addon string
---@field level integer
---@field levelName string
---@field message string
---@field time number|false

---A table sink that copies every record it receives, since the record LogKit
---hands over is reused for the next message.
---@class MoltenCodesTest.LogKit.Capture
---@field records MoltenCodesTest.LogKit.CapturedRecord[]
---@field Write fun(self: MoltenCodesTest.LogKit.Capture, record: table)

---Build a capturing table sink; it is not added yet.
---@return MoltenCodesTest.LogKit.Capture
local function newCapture()
  local capture = { records = {} }
  function capture:Write(record)
    self.records[#self.records + 1] = {
      addon = record.addon,
      level = record.level,
      levelName = record.levelName,
      message = record.message,
      time = record.time,
    }
  end
  return capture
end

---Build a capturing sink, add it, and return it.
---@param ctx TestKit.Context
---@return MoltenCodesTest.LogKit.Capture capture
---@return table handle
local function addCapture(ctx)
  local capture = newCapture()
  local handle = addTrackedSink(ctx, capture)
  return capture, handle
end

---The messages a capture kept, in order.
---@param capture MoltenCodesTest.LogKit.Capture
---@return string[]
local function capturedMessages(capture)
  local messages = {}
  for index, captured in ipairs(capture.records) do
    messages[index] = captured.message
  end
  return messages
end

-- Journal reads ---------------------------------------------------------------------------

---One journal entry as `History` yields it.
---@class MoltenCodesTest.LogKit.HistoryEntry
---@field position integer
---@field addon string
---@field levelName string
---@field message string
---@field time number|false

---Walk `LogKit:History(addonFilter, minimumLevel)` and keep every entry.
---@param addonFilter string|nil
---@param minimumLevel string|nil
---@return MoltenCodesTest.LogKit.HistoryEntry[]
local function readHistory(addonFilter, minimumLevel)
  local entries = {}
  for position, addon, levelName, message, time in LogKit:History(addonFilter, minimumLevel) do
    entries[#entries + 1] = {
      position = position,
      addon = addon,
      levelName = levelName,
      message = message,
      time = time,
    }
  end
  return entries
end

---The last `count` entries of `entries`, oldest first.
---@param entries MoltenCodesTest.LogKit.HistoryEntry[]
---@param count integer
---@return MoltenCodesTest.LogKit.HistoryEntry[]
local function lastEntries(entries, count)
  local tail = {}
  for index = math.max(1, #entries - count + 1), #entries do
    tail[#tail + 1] = entries[index]
  end
  return tail
end

-- Chat frames -----------------------------------------------------------------------------

--- The hidden frame the ChatSink tests write to, created on first use and
--- reused for the session, because the client never frees a Frame.
---@type table|nil
local hiddenChatFrame = nil

---Call `frame:<methodName>(...)` when the frame has that method.
---@param frame table
---@param methodName string
---@param ... any
local function callIfPresent(frame, methodName, ...)
  local method = frame[methodName]
  if type(method) == "function" then
    method(frame, ...)
  end
end

---The hidden `ScrollingMessageFrame` of the ChatSink tests, emptied, or a
---failed test when the client cannot create one.
---@param ctx TestKit.Context
---@return table
local function requireHiddenChatFrame(ctx)
  if type(hiddenChatFrame) == "nil" then
    local created, frame = pcall(createFrame, "ScrollingMessageFrame", nil, uiParent)
    if not created or type(frame) ~= "table" then
      ctx:Fail("CreateFrame('ScrollingMessageFrame') failed: " .. tostring(frame))
    end
    frame:Hide()
    callIfPresent(frame, "SetSize", 400, 200)
    local fontObject = readHost("ChatFontNormal")
    if type(fontObject) == "table" then
      callIfPresent(frame, "SetFontObject", fontObject)
    end
    callIfPresent(frame, "SetFading", false)
    callIfPresent(frame, "SetMaxLines", 32)
    hiddenChatFrame = frame
  end
  ---@cast hiddenChatFrame table
  if
    type(hiddenChatFrame.GetNumMessages) ~= "function"
    or type(hiddenChatFrame.GetMessageInfo) ~= "function"
  then
    ctx:Fail("the client's ScrollingMessageFrame has no GetNumMessages and GetMessageInfo")
  end
  callIfPresent(hiddenChatFrame, "Clear")
  return hiddenChatFrame
end

---Every line a message frame holds, in its index order; a secret line reads
---as `"(secret)"`. `nil` when the frame cannot be read.
---@param frame any
---@return string[]|nil
local function readFrameLines(frame)
  if
    type(frame) ~= "table"
    or type(frame.GetNumMessages) ~= "function"
    or type(frame.GetMessageInfo) ~= "function"
  then
    return nil
  end
  local count = frame:GetNumMessages()
  if type(count) ~= "number" or isSecret(count) then
    return nil
  end
  local lines = {}
  for index = 1, count do
    local text = frame:GetMessageInfo(index)
    if isSecret(text) then
      lines[index] = "(secret)"
    else
      lines[index] = tostring(text)
    end
  end
  return lines
end

---How many of `lines` end with `suffix`. Compared from the end: a chat frame
---that shows timestamps may put one in front of the text an addon adds.
---@param lines string[]
---@param suffix string
---@return integer
local function countLinesEndingWith(lines, suffix)
  local found = 0
  for _, line in ipairs(lines) do
    if line:sub(-#suffix) == suffix then
      found = found + 1
    end
  end
  return found
end

---Whether `lines` holds `expected` exactly.
---@param lines string[]
---@param expected string
---@return boolean
local function holdsLine(lines, expected)
  for _, line in ipairs(lines) do
    if line == expected then
      return true
    end
  end
  return false
end

-- The slash command ------------------------------------------------------------------------

---The slash name a `SlashCmdList` key is registered under (`SLASH_<key>1`),
---or `nil`.
---@param key string
---@return string|nil
local function slashNameOf(key)
  local name = readHost("SLASH_" .. key .. "1")
  if type(name) ~= "string" or isSecret(name) then
    return nil
  end
  return name
end

---The `SlashCmdList` key whose `SLASH_<key>1` is `/log`, or `nil`.
---@return string|nil
local function findLogCommandKey()
  local slashList = readHost("SlashCmdList")
  if type(slashList) ~= "table" then
    return nil
  end
  if
    type(rawget(slashList, LOG_COMMAND_KEY)) == "function"
    and slashNameOf(LOG_COMMAND_KEY) == LOG_SLASH_NAME
  then
    return LOG_COMMAND_KEY
  end
  for key, entry in pairs(slashList) do
    if
      type(key) == "string"
      and type(entry) == "function"
      and slashNameOf(key) == LOG_SLASH_NAME
    then
      return key
    end
  end
  return nil
end

---The default chat frame's edit box, which the client hands a slash function
---as its second argument, or `nil`.
---@return table|nil
local function chatEditBox()
  local chatFrame = readHost("DEFAULT_CHAT_FRAME")
  local editBox = nil
  if type(chatFrame) == "table" then
    editBox = rawget(chatFrame, "editBox")
  end
  if type(editBox) ~= "table" then
    editBox = readHost("ChatFrame1EditBox")
  end
  if type(editBox) ~= "table" then
    return nil
  end
  return editBox
end

---What the `/log` tests need: the key the client dispatches `/log` through
---and the capture its output goes to.
---@class MoltenCodesTest.LogKit.LogCommand
---@field key string
---@field output any a CommandKit capture sink

---Register `/log`, point LogKit's command scope at a CommandKit capture sink
---for this test, and return the key. A refusal CommandKit makes for the
---client's reasons (`taken`, `emote`, `full`) skips the test; `absent` or
---`unavailable` fails it, because the bundle ships CommandKit and the client
---has `SlashCmdList`.
---@param ctx TestKit.Context
---@return MoltenCodesTest.LogKit.LogCommand
local function prepareLogCommand(ctx)
  local registered, reason = LogKit:RegisterCommand()
  if not registered then
    if reason == "absent" or reason == "unavailable" then
      ctx:Fail("LogKit:RegisterCommand answered " .. tostring(reason))
    end
    Harness:SkipTest(
      ctx,
      "CommandKit refused /log (" .. tostring(reason) .. "): another addon or the client holds it"
    )
  end
  local key = findLogCommandKey()
  if type(key) == "nil" then
    ctx:Fail("no SlashCmdList entry has SLASH_<key>1 = /log after RegisterCommand")
  end
  ---@cast key string
  ---@type any
  local CommandKit = Registry:Get("commandKit", COMMAND_KIT_API)
  local output = CommandKit:CaptureSink()
  local scope = commandScope()
  scope:SetSink(output)
  pendingRestores[#pendingRestores + 1] = function()
    scope:SetSink(nil)
  end
  return { key = key, output = output }
end

---Run `/log <text>` without typing it: call the function the client keeps in
---`SlashCmdList[key]` with `text` and the default chat frame's edit box,
---exactly as the chat box does after it matched the slash name. Returns the
---lines the command printed.
---@param command MoltenCodesTest.LogKit.LogCommand
---@param text string what the player would type after `/log `
---@return string[]
local function runLog(command, text)
  local entry = rawget(readHost("SlashCmdList"), command.key)
  if type(entry) ~= "function" then
    error("SlashCmdList." .. command.key .. " is not a function", 2)
  end
  command.output:Clear()
  entry(text, chatEditBox())
  return command.output:Messages()
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
  ctx:Expect((file or ""):sub(-#"LogKitSuite.lua")):ToBe("LogKitSuite.lua")
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

---Run `action` with the client's error handler swapped for a collector, and
---return what the collector received.
---
---LogKit hands a failing sink, a bad format string and a refused persisted
---write to `geterrorhandler()` at call time. On the Retail client that global
---only reads the handler `seterrorhandler` installed, so the handler is
---swapped for the one call and put back at once (tests/client/README.md,
---"Catching an error a Kit reports instead of raising"). Without
---`seterrorhandler` the global is replaced for this test only. `action` must
---not yield: it runs under `pcall`.
---@param ctx TestKit.Context
---@param action fun()
---@return any[] reported every value the collector received, in order
---@return boolean observed whether the collector was the handler LogKit reported to
local function collectReportedErrors(ctx, action)
  local reported = {}
  ---@param message any
  local function collector(message)
    reported[#reported + 1] = message
  end

  local restore = nil
  local observed = false
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

---Fail the test when the collector could not replace the client's handler.
---@param ctx TestKit.Context
---@param observed boolean
local function requireObservedHandler(ctx, observed)
  if not observed then
    ctx:Fail(
      "the client's error handler could not be replaced (an error-capturing addon such as BugGrabber keeps it); the failure went to that addon"
    )
  end
end

-- Allocation ----------------------------------------------------------------------------------

---Measure how many kilobytes `work` grows the Lua heap by.
---@param work fun()
---@return number grownKilobytes
local function measureAllocation(work)
  local before = collectgarbage("count")
  work()
  return collectgarbage("count") - before
end

---Call `cycle` `count` times.
---@param cycle fun(index: integer)
---@param count integer
local function runCycles(cycle, count)
  for index = 1, count do
    cycle(index)
  end
end

---Collect in a step of its own, run one unmeasured cycle, measure `count`
---calls of `cycle`, log the delta and hold it to the tolerance.
---
---The full collection runs in its own step (`ctx:Yield()` after it), so the
---measurement starts far from the next collector cycle. The unmeasured cycle
---lets the test's coroutine grow its Lua stack back once and interns the
---formatted text again, neither of which is an allocation of the call under
---test.
---@param ctx TestKit.Context
---@param label string what `cycle` does, for the log
---@param count integer
---@param cycle fun(index: integer)
local function expectNoAllocation(ctx, label, count, cycle)
  collectgarbage("collect")
  ctx:Yield()
  measureAllocation(function()
    runCycles(cycle, 1)
  end)
  local grownKilobytes = measureAllocation(function()
    runCycles(cycle, count)
  end)
  ctx:Log(("memory delta over %s: %.3f KB"):format(label, grownKilobytes))
  ctx:Expect(grownKilobytes <= ALLOCATION_TOLERANCE_KB):ToBe(true)
end

-- A value whose conversion is observed -----------------------------------------------------

---A table whose `__tostring` counts its calls, to see whether LogKit read an
---argument.
---@class MoltenCodesTest.LogKit.CountedValue
---@field conversions integer

---Build a counted value that converts to `text`.
---@param text string
---@return MoltenCodesTest.LogKit.CountedValue
local function newCountedValue(text)
  local value = { conversions = 0 }
  return setmetatable(value, {
    __tostring = function(self)
      self.conversions = self.conversions + 1
      return text
    end,
  })
end

-- logKit.facade ----------------------------------------------------------------------------

local facade = newSuite("facade")

facade:Test(
  "Registry:Get('logKit', 1) is the LogKit facade with API 1, its eleven methods, the read-only LEVELS trace 1 to off 6, DEFAULT_LEVEL 'warn', MAX_FORMAT_ARGUMENTS 16, SECRET_PLACEHOLDER '<secret>' and UNBOUNDED",
  function(ctx)
    ctx:Expect(type(LogKit)):ToBe("table")
    ctx:Expect(rawget(LogKit, "API")):ToBe(LOG_KIT_API)
    for _, methodName in ipairs({
      "ForAddon",
      "SetGlobalLevel",
      "GetGlobalLevel",
      "AddSink",
      "RemoveSink",
      "ChatSink",
      "History",
      "RegisterCommand",
      "BindLevels",
      "SetLimits",
      "GetLimits",
    }) do
      ctx:Expect(type(rawget(LogKit, methodName))):ToBe("function")
    end
    local levelTable = LogKit.LEVELS
    for value, name in ipairs({ "trace", "debug", "info", "warn", "error", "off" }) do
      ctx:Expect(levelTable[name]):ToBe(value)
    end
    ctx:Expect(getmetatable(levelTable)):ToBe("LogKit.Levels")
    ctx:Expect(LogKit.DEFAULT_LEVEL):ToBe("warn")
    ctx:Expect(LogKit.MAX_FORMAT_ARGUMENTS):ToBe(16)
    ctx:Expect(LogKit.SECRET_PLACEHOLDER):ToBe("<secret>")
    ctx:Expect(type(LogKit.UNBOUNDED)):ToBe("table")
    ctx:Expect(mainLogger:GetAddonName()):ToBe(addonName)
    local limits = LogKit:GetLimits()
    ctx:Log(
      ("session limits: journalCapacity %s, maxSinks %s, maxMessageLength %s, maxLoggers %s"):format(
        tostring(limits.journalCapacity),
        tostring(limits.maxSinks),
        tostring(limits.maxMessageLength),
        tostring(limits.maxLoggers)
      )
    )
    ctx:Log(
      ("global level: %s; registered sinks: %d"):format(
        tostring(snapshot.globalLevel),
        registeredSinkCount()
      )
    )
  end
)

facade:Test("the installed LogKit carries the revision of the committed manifest", function(ctx)
  local expectedPackages = Harness:GetExpectedPackages()
  if type(expectedPackages) == "nil" then
    ctx:Fail("Expected.lua is missing; install with python3 -m tooling.client.install")
    return
  end
  for _, expected in ipairs(expectedPackages) do
    if expected.id == PACKAGE_ID then
      local _, revision = Registry:Get(PACKAGE_ID, LOG_KIT_API)
      ctx:Expect(revision):ToBe(expected.revision)
      ctx:Expect(rawget(LogKit, "REVISION")):ToBe(expected.revision)
      return
    end
  end
  ctx:Fail("Expected.lua does not list logKit")
end)

facade:Test(
  "the client has GetTimePreciseSec, geterrorhandler, SlashCmdList and a default chat frame with AddMessage, and Registry finds CommandKit API 1 and SettingsKit API 1 for the optional integrations",
  function(ctx)
    local first = now()
    local second = now()
    ctx:Expect(type(first)):ToBe("number")
    ctx:Expect(second >= first):ToBe(true)
    ctx:Expect(type(readHost("geterrorhandler"))):ToBe("function")
    ctx:Expect(type(readHost("SlashCmdList"))):ToBe("table")
    local chatFrame = readHost("DEFAULT_CHAT_FRAME")
    ctx:Expect(type(chatFrame)):ToBe("table")
    ctx:Expect(type(chatFrame.AddMessage)):ToBe("function")
    ctx:Log("seterrorhandler: " .. type(readHost("seterrorhandler")))
    ctx:Log("issecretvalue: " .. type(isSecretValue) .. ", secretwrap: " .. type(secretWrap))
    for _, optional in ipairs({
      { id = "commandKit", api = COMMAND_KIT_API },
      { id = "settingsKit", api = SETTINGS_KIT_API },
    }) do
      local found, revisionOrReason = Registry:Find(optional.id, optional.api)
      ctx:Log(
        ("Registry:Find('%s', %d) revision or reason: %s"):format(
          optional.id,
          optional.api,
          tostring(revisionOrReason)
        )
      )
      ctx:Expect(type(found)):ToBe("table")
    end
    local signalLimits = SignalKit:GetLimits()
    ctx:Log(
      ("SignalKit maxJournalCapacity %s, maxJournalArguments %s"):format(
        tostring(signalLimits.maxJournalCapacity),
        tostring(signalLimits.maxJournalArguments)
      )
    )
  end
)

-- logKit.levels ----------------------------------------------------------------------------

local levels = newSuite("levels")

levels:Test(
  "an addon override beats the global level, which beats the default warn, and GetLevel names the source of each",
  function(ctx)
    LogKit:SetGlobalLevel(nil)
    mainLogger:SetLevel(nil)
    ctx:Expect({ mainLogger:GetLevel() }):ToEqual({ "warn", "default" })
    ctx:Expect(LogKit:GetGlobalLevel()):ToBeNil()

    LogKit:SetGlobalLevel("info")
    ctx:Expect(LogKit:GetGlobalLevel()):ToBe("info")
    ctx:Expect({ mainLogger:GetLevel() }):ToEqual({ "info", "global" })
    ctx:Expect({ otherLogger:GetLevel() }):ToEqual({ "info", "global" })

    mainLogger:SetLevel("error")
    ctx:Expect({ mainLogger:GetLevel() }):ToEqual({ "error", "addon" })
    ctx:Expect({ otherLogger:GetLevel() }):ToEqual({ "info", "global" })
    mainLogger:SetLevel(LogKit.LEVELS.debug)
    ctx:Expect({ mainLogger:GetLevel() }):ToEqual({ "debug", "addon" })

    LogKit:SetGlobalLevel(nil)
    ctx:Expect({ otherLogger:GetLevel() }):ToEqual({ "warn", "default" })
    mainLogger:SetLevel(nil)
    ctx:Expect({ mainLogger:GetLevel() }):ToEqual({ "warn", "default" })
  end
)

levels:Test(
  "a Debug call below warn reads neither its message nor its arguments: a non-string message does not raise, a __tostring argument never runs, and the SignalKit journal's generation does not move",
  function(ctx)
    mainLogger:SetLevel("warn")
    local capture = addCapture(ctx)
    local counted = newCountedValue("counted")
    local generation = currentJournal():GetGeneration()

    mainLogger:Debug("rebuilding %s", counted)
    mainLogger:Debug(uiParent, counted)
    mainLogger:Trace(42)
    mainLogger:Info("never %d", "formatted")

    ctx:Expect(counted.conversions):ToBe(0)
    ctx:Expect(#capture.records):ToBe(0)
    ctx:Expect(currentJournal():GetGeneration()):ToBe(generation)
    ctx:Expect(mainLogger:IsEnabled("debug")):ToBe(false)
    ctx:Expect(mainLogger:IsEnabled("warn")):ToBe(true)
  end
)

levels:Test(
  "once debug is on, the same Debug call formats once through the client's string.format, runs __tostring once and reaches a table sink and the journal",
  function(ctx)
    mainLogger:SetLevel("debug")
    local capture = addCapture(ctx)
    local counted = newCountedValue("counted")
    local generation = currentJournal():GetGeneration()

    mainLogger:Debug("rebuilding %s in %.1f ms", counted, 2.5)

    ctx:Expect(counted.conversions):ToBe(1)
    ctx:Expect(#capture.records):ToBe(1)
    local record = capture.records[1]
    ctx:Expect(record.addon):ToBe(addonName)
    ctx:Expect(record.level):ToBe(LogKit.LEVELS.debug)
    ctx:Expect(record.levelName):ToBe("debug")
    ctx:Expect(record.message):ToBe("rebuilding counted in 2.5 ms")
    ctx:Expect(currentJournal():GetGeneration()):ToBe(generation + 1)
  end
)

levels:Test(
  "the client's string.format gives positional %2$s before %1$s, %5.1f, %x and %q, nil and booleans format as in Lua 5.2, and a bare '100% of the bars' is delivered unformatted",
  function(ctx)
    mainLogger:SetLevel("trace")
    local capture = addCapture(ctx)

    -- A client without positional specifiers would drop the first message
    -- and report the format failure; the collector keeps that report out of
    -- the error window and in this test's log.
    local reported, observed = collectReportedErrors(ctx, function()
      mainLogger:Info("%2$s before %1$s", "first", "second")
      mainLogger:Info("[%5.1f] [%x] [%q]", 3.14159, 255, 'say "hi"')
      mainLogger:Info("%s %s %s", nil, true, false)
      mainLogger:Error("100% of the bars are missing")
    end)
    requireObservedHandler(ctx, observed)
    for _, report in ipairs(reported) do
      ctx:Log("reported: " .. tostring(report))
    end
    ctx:Expect(#reported):ToBe(0)

    local messages = capturedMessages(capture)
    for index, message in ipairs(messages) do
      ctx:Log(("message %d: %s"):format(index, message))
    end
    ctx:Expect(messages):ToEqual({
      "second before first",
      '[  3.1] [ff] ["say \\"hi\\""]',
      "nil true false",
      "100% of the bars are missing",
    })
  end
)

levels:Test(
  "Log takes a level name or a LEVELS value, IsEnabled answers what the level methods do, and SetLevel('off') silences error",
  function(ctx)
    mainLogger:SetLevel("info")
    local capture = addCapture(ctx)

    mainLogger:Log("info", "by name")
    mainLogger:Log(LogKit.LEVELS.warn, "by value %d", 4)
    mainLogger:Log("debug", "below the level")
    ctx:Expect(mainLogger:IsEnabled(LogKit.LEVELS.info)):ToBe(true)
    ctx:Expect(mainLogger:IsEnabled("debug")):ToBe(false)

    mainLogger:SetLevel("off")
    ctx:Expect(mainLogger:IsEnabled("error")):ToBe(false)
    mainLogger:Error("silenced")
    ctx:Expect({ mainLogger:GetLevel() }):ToEqual({ "off", "addon" })

    ctx:Expect(capturedMessages(capture)):ToEqual({ "by name", "by value 4" })
    ctx:Expect(capture.records[2].levelName):ToBe("warn")
  end
)

-- logKit.journal ---------------------------------------------------------------------------

local journal = newSuite("journal")

journal:Test(
  "History walks this addon's entries oldest to newest with GetTimePreciseSec times taken between the calls, filters by addon and minimum level, and skips a disabled call",
  function(ctx)
    mainLogger:SetLevel("info")
    otherLogger:SetLevel("info")
    local before = now()
    mainLogger:Info("journal entry %d", 1)
    mainLogger:Debug("journal entry %d", 99)
    otherLogger:Error("other entry")
    mainLogger:Warn("journal entry %d", 2)
    local after = now()

    local own = lastEntries(readHistory(addonName), 2)
    ctx:Expect(#own):ToBe(2)
    ctx:Expect(own[1].message):ToBe("journal entry 1")
    ctx:Expect(own[1].levelName):ToBe("info")
    ctx:Expect(own[2].message):ToBe("journal entry 2")
    ctx:Expect(own[2].levelName):ToBe("warn")
    ctx:Expect(own[2].position > own[1].position):ToBe(true)
    for _, entry in ipairs(own) do
      ctx:Expect(entry.addon):ToBe(addonName)
      ctx:Expect(type(entry.time)):ToBe("number")
      ctx:Expect(entry.time >= before and entry.time <= after):ToBe(true)
    end
    ctx:Expect(own[2].time >= own[1].time):ToBe(true)
    ctx:Log(
      ("the two entries were stamped %.3f ms apart, within a %.3f ms window"):format(
        (own[2].time - own[1].time) * 1000,
        (after - before) * 1000
      )
    )

    -- The whole journal's newest three: the disabled Debug is not among them.
    local newest = lastEntries(readHistory(), 3)
    ctx:Expect(newest[1].message):ToBe("journal entry 1")
    ctx:Expect(newest[2].addon):ToBe(OTHER_LOGGER_NAME)
    ctx:Expect(newest[2].message):ToBe("other entry")
    ctx:Expect(newest[3].message):ToBe("journal entry 2")
    -- Positions without a filter follow one another.
    ctx:Expect(newest[3].position - newest[1].position):ToBe(2)

    local warnings = lastEntries(readHistory(addonName, "warn"), 1)
    ctx:Expect(warnings[1].message):ToBe("journal entry 2")
    for _, entry in ipairs(readHistory(addonName, "warn")) do
      ctx:Expect(entry.levelName == "warn" or entry.levelName == "error"):ToBe(true)
    end
    ctx:Expect(#readHistory(nil, "off")):ToBe(0)
  end
)

journal:Test(
  "LogKit's journal is a SignalKit journal: its newest entry holds the addon, the level number, the message and the same time History yields, and each delivered message moves its generation by one",
  function(ctx)
    mainLogger:SetLevel("warn")
    local ring = currentJournal()
    local generation = ring:GetGeneration()
    mainLogger:Warn("signal entry %s", "one")
    mainLogger:Error("signal entry two")
    mainLogger:Info("below the level")
    ctx:Expect(ring:GetGeneration()):ToBe(generation + 2)

    local newestRaw = nil
    for _, entry in ring:History() do
      newestRaw = entry
    end
    ctx:Expect(type(newestRaw)).Not:ToBe("nil")
    ---@cast newestRaw SignalKit.HistoryEntry
    ctx:Expect(newestRaw.count):ToBe(4)
    ctx:Expect(newestRaw[1]):ToBe(addonName)
    ctx:Expect(newestRaw[2]):ToBe(LogKit.LEVELS.error)
    ctx:Expect(newestRaw[3]):ToBe("signal entry two")

    local newest = lastEntries(readHistory(), 1)[1]
    ctx:Expect(newest.message):ToBe("signal entry two")
    ctx:Expect(newest.time):ToBe(newestRaw[4])
    ctx:Log(
      ("journal capacity %d, generation %d"):format(
        LogKit:GetLimits().journalCapacity,
        ring:GetGeneration()
      )
    )
  end
)

-- logKit.sinks -----------------------------------------------------------------------------

local sinks = newSuite("sinks")

sinks:Test(
  "a ChatSink bound to a hidden ScrollingMessageFrame receives '[addon] warn: message' with the orange warn escape and a red error line, nothing below the level, and the real chat frame's lines are unchanged",
  function(ctx)
    local frame = requireHiddenChatFrame(ctx)
    local realLinesBefore = readFrameLines(readHost("DEFAULT_CHAT_FRAME"))
    mainLogger:SetLevel("warn")
    addTrackedSink(ctx, LogKit:ChatSink(frame))

    mainLogger:Warn("profile %q not found, using default", "x")
    mainLogger:Info("below the level")
    mainLogger:Error("100% of the bars are missing")

    local lines = readFrameLines(frame) or {}
    for index, line in ipairs(lines) do
      ctx:Log(("hidden frame line %d: %s"):format(index, line))
    end
    ctx:Expect(#lines):ToBe(2)
    local warnLine = "["
      .. addonName
      .. "] "
      .. WARN_COLOUR
      .. 'warn|r: profile "x" not found, using default'
    local errorLine = "["
      .. addonName
      .. "] "
      .. ERROR_COLOUR
      .. "error|r: 100% of the bars are missing"
    ctx:Expect(holdsLine(lines, warnLine)):ToBe(true)
    ctx:Expect(holdsLine(lines, errorLine)):ToBe(true)
    ctx:Expect(frame:IsVisible()):ToBe(false)
    local realLinesAfter = readFrameLines(readHost("DEFAULT_CHAT_FRAME"))
    if type(realLinesBefore) ~= "nil" and type(realLinesAfter) ~= "nil" then
      ctx:Expect(realLinesAfter):ToEqual(realLinesBefore)
    end
  end
)

sinks:Test(
  "ChatSink() without a frame reads DEFAULT_CHAT_FRAME when it writes, so its line lands in the real chat frame (one visible line)",
  function(ctx)
    local chatFrame = readHost("DEFAULT_CHAT_FRAME")
    local linesBefore = readFrameLines(chatFrame)
    if type(linesBefore) == "nil" then
      Harness:SkipTest(
        ctx,
        "the default chat frame has no GetNumMessages and GetMessageInfo to read the line back"
      )
    end
    ---@cast linesBefore string[]
    mainLogger:SetLevel("warn")
    addTrackedSink(ctx, LogKit:ChatSink())

    mainLogger:Warn(VISIBLE_MESSAGE)

    local linesAfter = readFrameLines(chatFrame) or {}
    local expected = "[" .. addonName .. "] " .. WARN_COLOUR .. "warn|r: " .. VISIBLE_MESSAGE
    local found = countLinesEndingWith(linesAfter, expected)
      - countLinesEndingWith(linesBefore, expected)
    ctx:Log(
      ("chat frame lines before %d, after %d; the LogKit line appears %d more time(s)"):format(
        #linesBefore,
        #linesAfter,
        found
      )
    )
    ctx:Expect(found):ToBe(1)
  end
)

sinks:Test(
  "sinks run in registration order with one shared record, a table sink's Write is looked up at every message, and RemoveSink stops delivery at once and answers false for an unknown handle",
  function(ctx)
    mainLogger:SetLevel("warn")
    local order = {}
    local records = {}
    addTrackedSink(ctx, function(record)
      order[#order + 1] = "function"
      records[#records + 1] = record
    end)
    local tableSink = {
      Write = function(_, record)
        order[#order + 1] = "table"
        records[#records + 1] = record
      end,
    }
    local tableHandle = addTrackedSink(ctx, tableSink)

    mainLogger:Warn("first")
    ctx:Expect(order):ToEqual({ "function", "table" })
    ctx:Expect(records[1]):ToBe(records[2])

    -- Replaced after AddSink: LogKit looks Write up at the next message.
    tableSink.Write = function()
      order[#order + 1] = "replaced"
    end
    mainLogger:Warn("second")
    ctx:Expect(order):ToEqual({ "function", "table", "function", "replaced" })

    ctx:Expect(LogKit:RemoveSink(tableHandle)):ToBe(true)
    ctx:Expect(LogKit:RemoveSink(tableHandle)):ToBe(false)
    ctx:Expect(LogKit:RemoveSink({})):ToBe(false)
    ctx:Expect(LogKit:RemoveSink(nil)):ToBe(false)
    mainLogger:Warn("third")
    ctx:Expect(order):ToEqual({ "function", "table", "function", "replaced", "function" })
  end
)

-- logKit.reported --------------------------------------------------------------------------

local reportedSuite = newSuite("reported")

reportedSuite:Test(
  "a sink that raises is reported once through the client's error handler naming LogKitSuite.lua at the raising line, the next sink still runs and the logging caller continues",
  function(ctx)
    mainLogger:SetLevel("warn")
    local failingLine = 0
    addTrackedSink(ctx, function()
      failingLine = currentLine()
      error(SINK_FAILURE)
    end)
    local capture = addCapture(ctx)
    local steps = {}

    local reported, observed = collectReportedErrors(ctx, function()
      mainLogger:Warn("after a failing sink")
      steps[#steps + 1] = "caller continued"
    end)
    requireObservedHandler(ctx, observed)
    ctx:Expect(steps):ToEqual({ "caller continued" })
    ctx:Expect(capturedMessages(capture)):ToEqual({ "after a failing sink" })
    ctx:Expect(#reported):ToBe(1)
    ctx:Log("reported: " .. tostring(reported[1]))
    local line = expectThisFile(ctx, reported[1])
    ctx:Expect(line):ToBe(failingLine + 1)
    ctx:Expect(tostring(reported[1]):sub(-#SINK_FAILURE)):ToBe(SINK_FAILURE)
    ctx:Expect(lastEntries(readHistory(addonName), 1)[1].message):ToBe("after a failing sink")
  end
)

reportedSuite:Test(
  "a table a sink raises reaches the client's error handler as that same table",
  function(ctx)
    mainLogger:SetLevel("warn")
    local failure = { code = 7 }
    addTrackedSink(ctx, function()
      error(failure)
    end)

    local reported, observed = collectReportedErrors(ctx, function()
      mainLogger:Error("a sink raises a table")
    end)
    requireObservedHandler(ctx, observed)
    ctx:Expect(#reported):ToBe(1)
    ctx:Expect(reported[1]):ToBe(failure)
  end
)

--- The start of every format failure LogKit reports for this addon's Warn.
local FORMAT_FAILURE_START = "LogKit.Logger:Warn could not format a message for addon "
  .. addonName
  .. ": "

---What the client's own `string.format` does with `template` and `argument`,
---the only authority on what counts as a format failure: LogKit hands the
---staged arguments to it inside `pcall` and reports whatever it refuses.
---@param template string
---@param argument any
---@return boolean refused
---@return any result the formatted text, or the client's message
---@return string description for the log
local function clientFormat(template, argument)
  local formatted, result = pcall(string.format, template, argument)
  local description
  if isSecret(result) then
    description = (formatted and "accepted, a secret " or "refused, a secret ") .. type(result)
  elseif formatted then
    description = "accepted: " .. tostring(result)
  else
    description = "refused: " .. tostring(result)
  end
  return not formatted, result, description
end

---Expect what LogKit did with a Warn to match what the client's
---`string.format` did with the same staged arguments: a refusal is reported
---once as this addon's format failure (a string that is not secret) and
---nothing is delivered; an accepted format is delivered as the client's text
---and nothing is reported.
---@param ctx TestKit.Context
---@param outcome { reported: any[], capture: MoltenCodesTest.LogKit.Capture, generation: integer }
---@param clientRefused boolean
---@param clientResult any
local function expectFormatOutcome(ctx, outcome, clientRefused, clientResult)
  local reported = outcome.reported
  if clientRefused then
    ctx:Expect(#reported):ToBe(1)
    ctx:Expect(isSecret(reported[1])):ToBe(false)
    ctx:Expect(type(reported[1])):ToBe("string")
    ctx:Log("reported: " .. tostring(reported[1]))
    ctx:Expect(tostring(reported[1]):sub(1, #FORMAT_FAILURE_START)):ToBe(FORMAT_FAILURE_START)
    ctx:Expect(#outcome.capture.records):ToBe(0)
    ctx:Expect(currentJournal():GetGeneration()):ToBe(outcome.generation)
  else
    ctx:Expect(#reported):ToBe(0)
    ctx:Expect(#outcome.capture.records):ToBe(1)
    local message = outcome.capture.records[1] and outcome.capture.records[1].message
    ctx:Expect(isSecret(message)):ToBe(false)
    ctx:Log("delivered: " .. tostring(message))
    ctx:Expect(message):ToBe(clientResult)
  end
end

---Call `mainLogger:Warn(template, argument)` at warn with a capture sink and
---the error handler swapped for a collector, and return what happened.
---@param ctx TestKit.Context
---@param template string
---@param argument any
---@return { reported: any[], capture: MoltenCodesTest.LogKit.Capture, generation: integer, called: boolean }
local function warnWithOneArgument(ctx, template, argument)
  mainLogger:SetLevel("warn")
  local capture = addCapture(ctx)
  local generation = currentJournal():GetGeneration()
  local called = false
  local reported, observed = collectReportedErrors(ctx, function()
    called = pcall(mainLogger.Warn, mainLogger, template, argument)
  end)
  requireObservedHandler(ctx, observed)
  return { reported = reported, capture = capture, generation = generation, called = called }
end

reportedSuite:Test(
  "a format the client's string.format refuses ('%100s', a width over two digits) is reported through the client's error handler as a format failure for this addon, and the message reaches neither the journal nor any sink",
  function(ctx)
    local clientRefused, clientResult, clientDescription = clientFormat("%100s", "bars")
    ctx:Log("client string.format('%100s', 'bars'): " .. clientDescription)
    if not clientRefused then
      ctx:Fail("the client's string.format accepted '%100s', so it is no format failure here")
      return
    end
    local outcome = warnWithOneArgument(ctx, "%100s", "bars")
    ctx:Expect(outcome.called):ToBe(true)
    expectFormatOutcome(ctx, outcome, true, clientResult)
    ctx:Expect(outcome.reported[1]):ToBe(FORMAT_FAILURE_START .. tostring(clientResult))
  end
)

reportedSuite:Test(
  "a %d given the string 'many' ends as the client's own string.format decides: reported once through the error handler when it refuses, delivered as its text when it accepts; the client's answer is logged",
  function(ctx)
    local clientRefused, clientResult, clientDescription = clientFormat("%d frames", "many")
    ctx:Log("client string.format('%d frames', 'many'): " .. clientDescription)
    local outcome = warnWithOneArgument(ctx, "%d frames", "many")
    ctx:Expect(outcome.called):ToBe(true)
    expectFormatOutcome(ctx, outcome, clientRefused, clientResult)
  end
)

-- logKit.command ---------------------------------------------------------------------------

local command = newSuite("command")

---The addon name at the start of a `/log show` line `<addon>: <level> (<source>)`.
---@param line string
---@return string
local function loggerNameOfLine(line)
  return line:match("^(.*): %a+ %(%a+%)$") or line
end

command:Test(
  "RegisterCommand registers /log through CommandKit in the client's SlashCmdList, and a second call answers true without registering again",
  function(ctx)
    local logCommand = prepareLogCommand(ctx)
    ctx:Log("SlashCmdList key of /log: " .. logCommand.key)
    local entry = rawget(readHost("SlashCmdList"), logCommand.key)
    ctx:Expect(type(entry)):ToBe("function")
    ctx:Expect(slashNameOf(logCommand.key)):ToBe(LOG_SLASH_NAME)
    ctx:Expect(LogKit:RegisterCommand()):ToBe(true)
    ctx:Expect(rawget(readHost("SlashCmdList"), logCommand.key)):ToBe(entry)
    ctx:Expect(commandScope():IsRegistered("log")):ToBe(true)
  end
)

command:Test(
  "SlashCmdList /log '<addon> Debug' and '<addon> default' set and clear this addon's override, the level read without case, and print the level to LogKit's command sink",
  function(ctx)
    local logCommand = prepareLogCommand(ctx)
    LogKit:SetGlobalLevel(nil)
    mainLogger:SetLevel(nil)

    ctx
      :Expect(runLog(logCommand, addonName .. " Debug"))
      :ToEqual({ addonName .. ": debug (addon)" })
    ctx:Expect({ mainLogger:GetLevel() }):ToEqual({ "debug", "addon" })
    ctx:Expect(runLog(logCommand, addonName .. " error trailing tokens")):ToEqual({
      addonName .. ": error (addon)",
    })
    ctx:Expect({ mainLogger:GetLevel() }):ToEqual({ "error", "addon" })
    ctx:Expect(runLog(logCommand, addonName .. " default")):ToEqual({
      addonName .. ": warn (default)",
    })
    ctx:Expect({ mainLogger:GetLevel() }):ToEqual({ "warn", "default" })
  end
)

command:Test(
  "/log * info and /log * DEFAULT set and clear the global level; an unknown level, a missing level and an empty /log print their refusal or the usage and change nothing",
  function(ctx)
    local logCommand = prepareLogCommand(ctx)
    LogKit:SetGlobalLevel(nil)
    mainLogger:SetLevel(nil)

    ctx:Expect(runLog(logCommand, "* info")):ToEqual({ "global: info" })
    ctx:Expect(LogKit:GetGlobalLevel()):ToBe("info")
    ctx:Expect({ mainLogger:GetLevel() }):ToEqual({ "info", "global" })
    ctx:Expect(runLog(logCommand, "* DEFAULT")):ToEqual({ "global: not set" })
    ctx:Expect(LogKit:GetGlobalLevel()):ToBeNil()

    ctx:Expect(runLog(logCommand, addonName .. " loud")):ToEqual({
      '/log: unknown level "loud"; use one of trace, debug, info, warn, error, off, or default to clear',
    })
    ctx:Expect({ mainLogger:GetLevel() }):ToEqual({ "warn", "default" })

    for _, text in ipairs({ addonName, "" }) do
      local lines = runLog(logCommand, text)
      ctx:Log(
        ("/log %s printed %d line(s), the first: %s"):format(text, #lines, tostring(lines[1]))
      )
      ctx:Expect(lines[1]):ToBe("Usage: /log <addon|*> <level|default>")
    end
    ctx:Expect({ mainLogger:GetLevel() }):ToEqual({ "warn", "default" })
    ctx:Expect(LogKit:GetGlobalLevel()):ToBeNil()
  end
)

command:Test(
  "/log refuses a level for a name the client's C_AddOns.DoesAddOnExist does not know and that has no logger, sets one for an installed addon without creating its logger, /log show lists the global level, every logger sorted by name and then that addon as having no logger, /log show * the global level, and /log clear <addon> clears it",
  function(ctx)
    local logCommand = prepareLogCommand(ctx)
    pendingRestores[#pendingRestores + 1] = function()
      runLog(logCommand, "clear " .. INSTALLED_ADDON_NAME)
    end
    LogKit:SetGlobalLevel("error")
    mainLogger:SetLevel("debug")

    local addOns = readHost("C_AddOns")
    local doesAddOnExist = type(addOns) == "table" and addOns.DoesAddOnExist or nil
    ctx:Expect(type(doesAddOnExist)):ToBe("function")
    if type(doesAddOnExist) == "function" then
      ctx:Log(
        ("C_AddOns.DoesAddOnExist: %s -> %s, %s -> %s"):format(
          TYPED_ADDON_NAME,
          tostring(doesAddOnExist(TYPED_ADDON_NAME)),
          INSTALLED_ADDON_NAME,
          tostring(doesAddOnExist(INSTALLED_ADDON_NAME))
        )
      )
    end

    ctx:Expect(runLog(logCommand, TYPED_ADDON_NAME .. " trace")):ToEqual({
      '/log: no logger or installed addon is named "' .. TYPED_ADDON_NAME .. '"; nothing was set',
    })
    ctx:Expect(runLog(logCommand, "show " .. TYPED_ADDON_NAME)):ToEqual({
      TYPED_ADDON_NAME .. ": error (global)",
    })

    ctx:Expect(runLog(logCommand, INSTALLED_ADDON_NAME .. " trace")):ToEqual({
      INSTALLED_ADDON_NAME .. ": trace (addon)",
    })
    ctx:Expect(runLog(logCommand, "show " .. INSTALLED_ADDON_NAME)):ToEqual({
      INSTALLED_ADDON_NAME .. ": trace (addon)",
    })

    local lines = runLog(logCommand, "show")
    ctx:Log(("/log show printed %d line(s)"):format(#lines))
    ctx:Expect(lines[1]):ToBe("global: error")
    ctx:Expect(holdsLine(lines, addonName .. ": debug (addon)")):ToBe(true)
    ctx:Expect(holdsLine(lines, OTHER_LOGGER_NAME .. ": error (global)")):ToBe(true)
    ctx:Expect(lines[#lines]):ToBe(INSTALLED_ADDON_NAME .. ": trace (addon, no logger)")
    ctx:Expect(holdsLine(lines, INSTALLED_ADDON_NAME .. ": trace (addon)")):ToBe(false)
    -- The logger lines are sorted by addon name, which is not the order of
    -- the whole lines: "A.B: ..." sorts before "A: ..." as text, while the
    -- name "A" sorts before "A.B". The last line is the one without a logger.
    for index = 3, #lines - 1 do
      ctx:Expect(loggerNameOfLine(lines[index - 1]) < loggerNameOfLine(lines[index])):ToBe(true)
    end
    ctx:Expect(runLog(logCommand, "show *")):ToEqual({ "global: error" })

    ctx:Expect(runLog(logCommand, "clear " .. INSTALLED_ADDON_NAME)):ToEqual({
      INSTALLED_ADDON_NAME .. ": error (global)",
    })
    ctx
      :Expect(
        holdsLine(runLog(logCommand, "show"), INSTALLED_ADDON_NAME .. ": trace (addon, no logger)")
      )
      :ToBe(false)
  end
)

-- logKit.bindLevels ------------------------------------------------------------------------

local bindLevels = newSuite("bindLevels")

---SettingsKit and SchemaKit, or a failed test: the bundle ships both.
---@param ctx TestKit.Context
---@return any SettingsKit
---@return any SchemaKit
local function requireSettingsKit(ctx)
  local SettingsKit = Registry:Find("settingsKit", SETTINGS_KIT_API)
  local SchemaKit = Registry:Find("schemaKit", SCHEMA_KIT_API)
  if type(SettingsKit) == "nil" or type(SchemaKit) == "nil" then
    ctx:Fail("SettingsKit API 1 and SchemaKit API 1 must be loaded for BindLevels")
  end
  return SettingsKit, SchemaKit
end

---Open a SettingsKit database over a new scratch global that already holds
---`savedLevels` as its `global.logLevels`, with the section declared as
---docs/API.md says: an optional map of string to string with a default.
---@param ctx TestKit.Context
---@param savedLevels table<string, string>
---@param maxEntries integer the map's `max`
---@return any db
---@return string globalName
local function openLevelsDatabase(ctx, savedLevels, maxEntries)
  local SettingsKit, S = requireSettingsKit(ctx)
  local name = newScratchGlobal()
  writeOwnGlobal(name, { global = { logLevels = savedLevels } })
  local db = SettingsKit:Open(name, {
    global = S.table({
      fields = {
        logLevels = S.optional(
          S.map({ keys = S.string(), values = S.string(), max = maxEntries }),
          {}
        ),
      },
    }),
  })
  return db, name
end

---The raw `global.logLevels` table of a scratch global, as it would be saved.
---@param globalName string
---@return table
local function rawSavedLevels(globalName)
  return rawget(rawget(readHost(globalName), "global"), "logLevels")
end

bindLevels:Test(
  "BindLevels over an in-memory SettingsKit database restores this addon's saved level and the '*' global level, ignores an unknown level, and writes every change to the saved table until BindLevels(nil)",
  function(ctx)
    LogKit:SetGlobalLevel(nil)
    mainLogger:SetLevel(nil)
    otherLogger:SetLevel(nil)
    local db, globalName = openLevelsDatabase(ctx, {
      [addonName] = "debug",
      ["*"] = "error",
      [OTHER_LOGGER_NAME] = "loud",
    }, 64)

    ctx:Expect(LogKit:BindLevels(db)):ToBe(true)
    ctx:Expect({ mainLogger:GetLevel() }):ToEqual({ "debug", "addon" })
    ctx:Expect(LogKit:GetGlobalLevel()):ToBe("error")
    ctx:Expect({ otherLogger:GetLevel() }):ToEqual({ "error", "global" })

    mainLogger:SetLevel("trace")
    ctx:Expect(rawget(rawSavedLevels(globalName), addonName)):ToBe("trace")
    ctx:Expect(db.global.logLevels[addonName]):ToBe("trace")
    LogKit:SetGlobalLevel("info")
    ctx:Expect(rawget(rawSavedLevels(globalName), "*")):ToBe("info")
    otherLogger:SetLevel("warn")
    ctx:Expect(rawget(rawSavedLevels(globalName), OTHER_LOGGER_NAME)):ToBe("warn")
    mainLogger:SetLevel(nil)
    ctx:Expect(rawget(rawSavedLevels(globalName), addonName)):ToBeNil()

    ctx:Expect(LogKit:BindLevels(nil)):ToBe(false)
    mainLogger:SetLevel("error")
    LogKit:SetGlobalLevel(nil)
    ctx:Expect(rawget(rawSavedLevels(globalName), addonName)):ToBeNil()
    ctx:Expect(rawget(rawSavedLevels(globalName), "*")):ToBe("info")
    ctx:Expect({ mainLogger:GetLevel() }):ToEqual({ "error", "addon" })
  end
)

bindLevels:Test(
  "a write the database refuses (a logLevels map of max 2 already full) is reported through the client's error handler and the level still applies for the session",
  function(ctx)
    mainLogger:SetLevel(nil)
    otherLogger:SetLevel(nil)
    -- BindLevels checks that "*" can be written, so the full map holds it.
    local db, globalName =
      openLevelsDatabase(ctx, { [OTHER_LOGGER_NAME] = "warn", ["*"] = "info" }, 2)
    ctx:Expect(LogKit:BindLevels(db)):ToBe(true)
    ctx:Expect({ otherLogger:GetLevel() }):ToEqual({ "warn", "addon" })
    ctx:Expect(LogKit:GetGlobalLevel()):ToBe("info")

    local reported, observed = collectReportedErrors(ctx, function()
      mainLogger:SetLevel("debug")
    end)
    requireObservedHandler(ctx, observed)
    ctx:Expect(#reported):ToBe(1)
    ctx:Log("reported: " .. tostring(reported[1]))
    ctx:Expect(type(reported[1])):ToBe("string")
    ctx
      :Expect(tostring(reported[1]):find("global.logLevels: expected at most 2", 1, true) ~= nil)
      :ToBe(true)
    ctx:Expect({ mainLogger:GetLevel() }):ToEqual({ "debug", "addon" })
    ctx:Expect(rawget(rawSavedLevels(globalName), addonName)):ToBeNil()
  end
)

bindLevels:Test(
  "BindLevels refuses a plain table and a database without global.logLevels at the calling line",
  function(ctx)
    local SettingsKit, S = requireSettingsKit(ctx)
    local name = newScratchGlobal()
    local undeclared = SettingsKit:Open(name, {
      global = S.table({ fields = { note = S.optional(S.string()) } }),
    })
    local lines = { start = 0 }
    expectErrorAtCallingLine(ctx, function()
      lines.start = currentLine()
      LogKit:BindLevels({})
    end, lines, "LogKit:BindLevels db must be a SettingsKit database")
    expectErrorAtCallingLine(
      ctx,
      function()
        lines.start = currentLine()
        LogKit:BindLevels(undeclared)
      end,
      lines,
      "LogKit:BindLevels db must declare global.logLevels as an optional map of addon name to level name; see LogKit docs/API.md"
    )
    ctx:Expect(rawget(logKitState(), "binding")):ToBe(false)
  end
)

-- logKit.limits ----------------------------------------------------------------------------

local limitsSuite = newSuite("limits")

limitsSuite:Test(
  "maxMessageLength 16 cuts a message of two-byte characters to 12 bytes plus '...' on a character boundary, and the limit is put back afterwards",
  function(ctx)
    mainLogger:SetLevel("warn")
    local capture = addCapture(ctx)
    LogKit:SetLimits({ maxMessageLength = 16 })
    ctx:Expect(LogKit:GetLimits().maxMessageLength):ToBe(16)

    -- Eleven "é" (C3 A9): 22 bytes, cut after the sixth character.
    local accented = ("\195\169"):rep(11)
    mainLogger:Warn("%s", accented)
    mainLogger:Warn("exactly sixteen!")

    local messages = capturedMessages(capture)
    ctx:Expect(messages[1]):ToBe(("\195\169"):rep(6) .. "...")
    ctx:Expect(#messages[1]):ToBe(15)
    ctx:Expect(messages[2]):ToBe("exactly sixteen!")
  end
)

limitsSuite:Test(
  "maxLoggers and maxSinks lowered to 1 refuse a new logger with 'capped' and a new sink with 'full', while existing loggers are still returned",
  function(ctx)
    addTrackedSink(ctx, function() end)
    LogKit:SetLimits({ maxLoggers = 1, maxSinks = 1 })

    local refused, reason = LogKit:ForAddon(CAPPED_ADDON_NAME)
    ctx:Expect(refused):ToBeNil()
    ctx:Expect(reason):ToBe("capped")
    ctx:Expect(LogKit:ForAddon(addonName)):ToBe(mainLogger)

    local handle, sinkReason = LogKit:AddSink(function() end)
    ctx:Expect(handle):ToBeNil()
    ctx:Expect(sinkReason):ToBe("full")
    ctx:Expect(LogKit:GetLimits().maxLoggers):ToBe(1)
  end
)

-- logKit.allocation ------------------------------------------------------------------------

local allocation = newSuite("allocation")

---Skip the test when a sink this file did not add is registered: thousands
---of enabled messages would reach it, and a chat sink would flood the chat.
---@param ctx TestKit.Context
---@param ownSinks integer how many sinks this test added
local function requireOnlyOwnSinks(ctx, ownSinks)
  local foreign = registeredSinkCount() - ownSinks
  if foreign > 0 then
    Harness:SkipTest(
      ctx,
      ("%d sink(s) of another addon are registered; the enabled messages would reach them"):format(
        foreign
      )
    )
  end
end

---A table sink that only counts, so the measurement sees LogKit alone.
---@return { count: integer, Write: fun(self: table, record: table) }
local function newCountingSink()
  local counter = { count = 0 }
  function counter:Write()
    self.count = self.count + 1
  end
  return counter
end

allocation:Test(
  "Trace, Debug and Info below warn with three format arguments, and Log with a LEVELS value, allocate nothing over 5000 calls each",
  function(ctx)
    mainLogger:SetLevel("warn")
    local debugLevel = LogKit.LEVELS.debug
    local counted = newCountedValue("counted")
    local generation = currentJournal():GetGeneration()

    expectNoAllocation(
      ctx,
      "5000 rounds of four disabled calls",
      DISABLED_ALLOCATION_CYCLES,
      function(index)
        mainLogger:Trace("frame %d of %s (%s)", index, "bars", counted)
        mainLogger:Debug("frame %d of %s (%s)", index, "bars", counted)
        mainLogger:Info("frame %d of %s (%s)", index, "bars", counted)
        mainLogger:Log(debugLevel, "frame %d of %s (%s)", index, "bars", counted)
      end
    )
    ctx:Expect(counted.conversions):ToBe(0)
    ctx:Expect(currentJournal():GetGeneration()):ToBe(generation)
  end
)

allocation:Test(
  "an enabled bare Warn delivered to a table sink and the journal allocates nothing over 2000 calls",
  function(ctx)
    mainLogger:SetLevel("warn")
    local counter = newCountingSink()
    addTrackedSink(ctx, counter)
    requireOnlyOwnSinks(ctx, 1)

    expectNoAllocation(ctx, "2000 enabled bare messages", ENABLED_ALLOCATION_CYCLES, function()
      mainLogger:Warn("LogKit allocation probe")
    end)
    ctx:Expect(counter.count):ToBe(ENABLED_ALLOCATION_CYCLES + 1)
  end
)

allocation:Test(
  "an enabled Warn formatting '%d of %s' to text the client already interned allocates nothing over 2000 calls with a table sink",
  function(ctx)
    mainLogger:SetLevel("warn")
    local counter = newCountingSink()
    addTrackedSink(ctx, counter)
    requireOnlyOwnSinks(ctx, 1)

    expectNoAllocation(ctx, "2000 enabled formatted messages", ENABLED_ALLOCATION_CYCLES, function()
      mainLogger:Warn("%d of %s", 7, "bars")
    end)
    ctx:Expect(counter.count):ToBe(ENABLED_ALLOCATION_CYCLES + 1)
    ctx:Expect(lastEntries(readHistory(addonName), 1)[1].message):ToBe("7 of bars")
  end
)

-- logKit.errors ----------------------------------------------------------------------------

local errors = newSuite("errors")

errors:Test(
  "ForAddon with an empty name and GetLimits called with a dot name LogKitSuite.lua at the calling line",
  function(ctx)
    local lines = { start = 0 }
    expectErrorAtCallingLine(ctx, function()
      lines.start = currentLine()
      LogKit:ForAddon("")
    end, lines, "LogKit:ForAddon addonName must be a non-empty string")
    expectErrorAtCallingLine(ctx, function()
      lines.start = currentLine()
      LogKit.GetLimits()
    end, lines, "LogKit:GetLimits must be called on the LogKit facade; use LogKit:GetLimits(...)")
  end
)

errors:Test(
  "an enabled Warn with a number as message, 17 format arguments, Log at off and SetLevel('loud') are each refused at the calling line",
  function(ctx)
    mainLogger:SetLevel("warn")
    local lines = { start = 0 }
    expectErrorAtCallingLine(ctx, function()
      lines.start = currentLine()
      mainLogger:Warn(42)
    end, lines, "LogKit.Logger:Warn message must be a string")
    expectErrorAtCallingLine(ctx, function()
      lines.start = currentLine()
      mainLogger:Warn("%s", 1, 2, 3, 4, 5, 6, 7, 8, 9, 10, 11, 12, 13, 14, 15, 16, 17)
    end, lines, "LogKit.Logger:Warn accepts at most 16 format arguments; received 17")
    expectErrorAtCallingLine(ctx, function()
      lines.start = currentLine()
      mainLogger:Log("off", "never")
    end, lines, "LogKit.Logger:Log level cannot be off")
    expectErrorAtCallingLine(
      ctx,
      function()
        lines.start = currentLine()
        mainLogger:SetLevel("loud")
      end,
      lines,
      "LogKit.Logger:SetLevel level must be a level name (trace, debug, info, warn, error, off) or a LogKit.LEVELS value"
    )
    ctx:Expect({ mainLogger:GetLevel() }):ToEqual({ "warn", "addon" })
  end
)

errors:Test(
  "a logger method called on UIParent, AddSink and ChatSink given UIParent, and a write to LEVELS are each refused at the calling line",
  function(ctx)
    local warn = mainLogger.Warn
    local lines = { start = 0 }
    expectErrorAtCallingLine(ctx, function()
      lines.start = currentLine()
      warn(uiParent, "not a logger")
    end, lines, "LogKit.Logger:Warn must be called on a LogKit logger")
    expectErrorAtCallingLine(ctx, function()
      lines.start = currentLine()
      LogKit:AddSink(uiParent)
    end, lines, "LogKit:AddSink sink must be a function or a table with a Write method")
    expectErrorAtCallingLine(ctx, function()
      lines.start = currentLine()
      LogKit:ChatSink(uiParent)
    end, lines, "LogKit:ChatSink chatFrame must be a table with an AddMessage method")
    expectErrorAtCallingLine(ctx, function()
      lines.start = currentLine()
      LogKit.LEVELS.debug = 9
    end, lines, "LogKit.LEVELS is read-only")
    ctx:Expect(LogKit.LEVELS.debug):ToBe(2)
  end
)

errors:Test(
  "SetLimits with UNBOUNDED for journalCapacity, a capacity above SignalKit's maxJournalCapacity and maxMessageLength 8 is refused at the calling line and the limits stay as they were",
  function(ctx)
    local before = LogKit:GetLimits()
    local lines = { start = 0 }
    expectErrorAtCallingLine(
      ctx,
      function()
        lines.start = currentLine()
        LogKit:SetLimits({ journalCapacity = LogKit.UNBOUNDED })
      end,
      lines,
      "LogKit:SetLimits limits.journalCapacity cannot be LogKit.UNBOUNDED: the ring is allocated when the journal is created"
    )
    local signalMaximum = SignalKit:GetLimits().maxJournalCapacity
    ctx:Log("SignalKit maxJournalCapacity: " .. tostring(signalMaximum))
    if type(signalMaximum) == "number" and signalMaximum < 65536 then
      expectErrorAtCallingLine(
        ctx,
        function()
          lines.start = currentLine()
          LogKit:SetLimits({ journalCapacity = signalMaximum + 1 })
        end,
        lines,
        ("LogKit:SetLimits limits.journalCapacity exceeds SignalKit maxJournalCapacity (%d); raise it with SignalKit:SetLimits first"):format(
          signalMaximum
        )
      )
    end
    expectErrorAtCallingLine(
      ctx,
      function()
        lines.start = currentLine()
        LogKit:SetLimits({ maxSinks = 4, maxMessageLength = 8 })
      end,
      lines,
      "LogKit:SetLimits limits.maxMessageLength must be an integer of at least 16 or LogKit.UNBOUNDED"
    )
    ctx:Expect(LogKit:GetLimits()):ToEqual(before)
  end
)

-- logKit.secrets ---------------------------------------------------------------------------

local secrets = newSuite("secrets")

--- Why the secrets tests are skipped on a client without the two functions.
local SECRETS_SKIP_REASON =
  "the client has no issecretvalue and secretwrap; the secret path was not exercised"

---Register `body` as a test when the client can make a secret value, and as a
---skipped test naming why otherwise: the client lacks `issecretvalue` and
---`secretwrap`, or it has both (Classic Era and Mists Classic document them)
---but `issecretvalue` does not report what `secretwrap` returns as secret,
---which `Harness:CanMakeSecrets` measures once.
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

---Describe a pcall outcome for the log without formatting a secret.
---@param ok boolean
---@param value any
---@return string
local function describeOutcome(ok, value)
  if isSecretValue(value) == true then
    if ok then
      return "returned a secret " .. type(value)
    end
    return "raised a secret " .. type(value)
  end
  if not ok then
    return "raised: " .. tostring(value)
  end
  return "returned " .. type(value) .. " " .. tostring(value)
end

secretTest(
  "a secret number and a secret string as %s arguments reach a table sink, the journal and a hidden ChatSink as '<secret>', and neither the call nor the error handler sees a client error",
  function(ctx)
    local secretNumber = makeSecret(ctx, 42)
    local secretString = makeSecret(ctx, "Thrall")
    -- What the client itself does with the operations LogKit avoids.
    ctx:Log(
      "string.format('%s', secret number): "
        .. describeOutcome(pcall(string.format, "%s", secretNumber))
    )
    ctx:Log(
      "string.format('%d', secret number): "
        .. describeOutcome(pcall(string.format, "%d", secretNumber))
    )
    ctx:Log("tostring(secret string): " .. describeOutcome(pcall(tostring, secretString)))
    ctx:Log("'name ' .. secret string: " .. describeOutcome(pcall(function()
      return "name " .. secretString
    end)))

    local frame = requireHiddenChatFrame(ctx)
    mainLogger:SetLevel("warn")
    local capture = addCapture(ctx)
    addTrackedSink(ctx, LogKit:ChatSink(frame))

    local expected = "health <secret>, name <secret>"
    local called, callProblem = nil, nil
    local reported, observed = collectReportedErrors(ctx, function()
      called, callProblem =
        pcall(mainLogger.Warn, mainLogger, "health %s, name %s", secretNumber, secretString)
    end)
    requireObservedHandler(ctx, observed)
    ctx:Log("the Warn call: " .. describeOutcome(called == true, callProblem))
    ctx:Expect(called):ToBe(true)
    ctx:Expect(#reported):ToBe(0)
    ctx:Expect(#capture.records):ToBe(1)
    local message = capture.records[1].message
    ctx:Expect(isSecretValue(message)):ToBe(false)
    ctx:Expect(message):ToBe(expected)
    ctx:Expect(lastEntries(readHistory(addonName), 1)[1].message):ToBe(expected)
    local lines = readFrameLines(frame) or {}
    ctx:Expect(lines):ToEqual({ "[" .. addonName .. "] " .. WARN_COLOUR .. "warn|r: " .. expected })
  end
)

secretTest(
  "a secret number given to %d is replaced by '<secret>' before string.format, so no secret reaches it and the call raises nothing: LogKit reports or delivers exactly as the client's string.format decides for '<secret>'",
  function(ctx)
    local secretNumber = makeSecret(ctx, 42)
    local clientRefused, clientResult, clientDescription =
      clientFormat("health %d", LogKit.SECRET_PLACEHOLDER)
    ctx:Log("client string.format('health %d', '<secret>'): " .. clientDescription)
    local outcome = warnWithOneArgument(ctx, "health %d", secretNumber)
    ctx:Expect(outcome.called):ToBe(true)
    expectFormatOutcome(ctx, outcome, clientRefused, clientResult)
  end
)

secretTest(
  "a secret message raises at the calling line when the level is enabled and is not read at all when it is disabled",
  function(ctx)
    local secretString = makeSecret(ctx, "hidden %s")
    mainLogger:SetLevel("warn")
    local capture = addCapture(ctx)
    local generation = currentJournal():GetGeneration()

    local disabled = pcall(mainLogger.Debug, mainLogger, secretString, "argument")
    ctx:Expect(disabled):ToBe(true)
    local lines = { start = 0 }
    expectErrorAtCallingLine(ctx, function()
      lines.start = currentLine()
      mainLogger:Warn(secretString)
    end, lines, "LogKit.Logger:Warn message must not be a secret value")
    expectErrorAtCallingLine(ctx, function()
      lines.start = currentLine()
      mainLogger:Log("error", secretString, 1)
    end, lines, "LogKit.Logger:Log message must not be a secret value")
    ctx:Expect(#capture.records):ToBe(0)
    ctx:Expect(currentJournal():GetGeneration()):ToBe(generation)
  end
)

secretTest(
  "a secret level, addon name, History filter, sink, chat frame and SetLimits value are refused at the calling line, RemoveSink answers false for a secret, and nothing changes",
  function(ctx)
    local secretString = makeSecret(ctx, "debug")
    local secretNumber = makeSecret(ctx, 4)
    mainLogger:SetLevel("warn")
    local limitsBefore = LogKit:GetLimits()
    local sinksBefore = registeredSinkCount()
    local lines = { start = 0 }
    expectErrorAtCallingLine(ctx, function()
      lines.start = currentLine()
      mainLogger:SetLevel(secretString)
    end, lines, "LogKit.Logger:SetLevel level must not be a secret value")
    expectErrorAtCallingLine(ctx, function()
      lines.start = currentLine()
      LogKit:SetGlobalLevel(secretNumber)
    end, lines, "LogKit:SetGlobalLevel level must not be a secret value")
    expectErrorAtCallingLine(ctx, function()
      lines.start = currentLine()
      LogKit:ForAddon(secretString)
    end, lines, "LogKit:ForAddon addonName must not be a secret value")
    expectErrorAtCallingLine(ctx, function()
      lines.start = currentLine()
      LogKit:History(secretString)
    end, lines, "LogKit:History addonName must not be a secret value")
    expectErrorAtCallingLine(ctx, function()
      lines.start = currentLine()
      LogKit:AddSink(secretString)
    end, lines, "LogKit:AddSink sink must not be a secret value")
    expectErrorAtCallingLine(ctx, function()
      lines.start = currentLine()
      LogKit:ChatSink(secretString)
    end, lines, "LogKit:ChatSink chatFrame must not be a secret value")
    expectErrorAtCallingLine(ctx, function()
      lines.start = currentLine()
      LogKit:SetLimits({ maxSinks = secretNumber })
    end, lines, "LogKit:SetLimits limits.maxSinks must not be a secret value")
    ctx:Expect(LogKit:RemoveSink(secretString)):ToBe(false)

    ctx:Expect({ mainLogger:GetLevel() }):ToEqual({ "warn", "addon" })
    ctx:Expect(LogKit:GetGlobalLevel()):ToBe(snapshot.globalLevel)
    ctx:Expect(LogKit:GetLimits()):ToEqual(limitsBefore)
    ctx:Expect(registeredSinkCount()):ToBe(sinksBefore)
  end
)

secretTest(
  "a secret string a sink raises reaches the client's error handler still secret, and the next sink still runs",
  function(ctx)
    local secretString = makeSecret(ctx, "secret failure")
    mainLogger:SetLevel("warn")
    addTrackedSink(ctx, function()
      error(secretString, 0)
    end)
    local capture = addCapture(ctx)

    local reported, observed = collectReportedErrors(ctx, function()
      mainLogger:Warn("a sink raises a secret")
    end)
    requireObservedHandler(ctx, observed)
    ctx:Expect(#reported):ToBe(1)
    ctx:Expect(isSecretValue(reported[1])):ToBe(true)
    ctx:Expect(type(reported[1])):ToBe("string")
    ctx:Expect(capturedMessages(capture)):ToEqual({ "a sink raises a secret" })
  end
)
