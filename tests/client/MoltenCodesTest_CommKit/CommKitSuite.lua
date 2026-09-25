-- MoltenCodes Test: CommKitSuite.lua
--
-- Real-client suites for the `commKit` package. The Busted specs under
-- packages/commKit/tests/ prove CommKit against a fake chat API that hands
-- every sent chunk straight back as a `CHAT_MSG_ADDON` call; these prove,
-- inside the game client with the installed MoltenCodes addon, what that
-- fixture can only simulate:
--
--   * the installed facade and its committed revision, and that the client's
--     `C_ChatInfo` functions and its two result enums are what CommKit's
--     fallbacks assume (both enums logged);
--   * that `Register` asks the real client to register a prefix, and what the
--     client answers when the prefix is registered a second time (the answer
--     and the number of registered prefixes are logged);
--   * real round trips: addon messages whispered to the player's OWN character
--     with `C_ChatInfo.SendAddonMessage`, which the server hands back as
--     `CHAT_MSG_ADDON`. A short message, an empty one, a single chunk holding
--     every byte value `Send` accepts, a 2048-byte message in nine chunks
--     (per-chunk timing, the budget and throttles logged), a message cancelled
--     after its first chunk (the abort chunk on the wire), a raw
--     `SendAddonMessage` call (its `Enum.SendAddonMessageResult` logged and
--     charged to the budget as outside traffic), and a send cancelled before
--     it left;
--   * a SyncSet that requests its own fields from the player's own character
--     and answers itself: a delivery, then an ack a second later;
--   * `ForAddon` and `CloseAddonScopes`, and the documented allocation guards
--     that a synchronous call can measure;
--   * argument errors and secret refusals pointing at this file as the client
--     names it.
--
-- What leaves the client. Every message a run sends is a WHISPER addon message
-- to the player's own character; nothing is ever sent to GUILD, PARTY, RAID,
-- INSTANCE_CHAT, SAY, YELL or a channel, and no other player can receive it. A
-- run sends at most 20 addon messages in all, over a few seconds, far below
-- any server limit. When the client refuses the whisper to self, or never
-- delivers it back, the round-trip tests are reported as skipped with the
-- reason instead of passing or failing.
--
-- Run with `/mct run commKit`; tests/client/MoltenCodesTest_CommKit/EXPECTED.md
-- lists what the chat frame should show.
--
-- What a run leaves behind. Every CommKit scope, SyncSet and EventKit
-- connection a test creates is closed by the After hook of its suite, whatever
-- the test's outcome, which cancels any send still queued. What stays in the
-- session:
--
--   * the six test prefixes (`MCTCommKitReg`, `...Short`, `...Long`,
--     `...Abort`, `...Raw`, `...Sync`), registered with the client by the
--     first run: the client has no way to unregister a prefix, and later runs
--     reuse the same six;
--   * this addon's own CommKit scope (`CommKit:ForAddon(addonName)`), empty,
--     closed at logout, and one closed scope per run for a probe addon name
--     (`MoltenCodesTest_CommKitProbe1`, `...Probe2`, ...), because CommKit
--     keeps an addon scope for good once `ForAddon` created it;
--   * CommKit's counters (`GetStatistics`), which count since load, and, when
--     HookKit is loaded, the secure hooks CommKit installs on the client's
--     send functions the first time it sends (documented as session-long).
--
-- Nothing is written to a global or a saved variable, and no setting changes.

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
local COMM_KIT_API = 1
local EVENT_KIT_API = 1
local LIFECYCLE_KIT_API = 1
local CODEC_KIT_API = 1
local SCHEMA_KIT_API = 1
local HOOK_KIT_API = 1
local PACKAGE_ID = "commKit"

--- The test prefixes, one per kind of traffic, so the client's per-prefix
--- throttle of one test never slows another. Each is at most 16 bytes, and
--- the same six are reused by every run: a registered prefix stays
--- registered for the session.
local PREFIX = {
  registration = "MCTCommKitReg",
  short = "MCTCommKitShort",
  long = "MCTCommKitLong",
  abort = "MCTCommKitAbort",
  raw = "MCTCommKitRaw",
  sync = "MCTCommKitSync",
}

--- How long a test waits for the client to accept a send (the handle to
--- reach a terminal state), and separately for the whisper to come back.
local SEND_TIMEOUT_SECONDS = 8
local DELIVERY_TIMEOUT_SECONDS = 5

--- How long a test watches the wire for traffic that must not arrive.
local QUIET_WAIT_SECONDS = 1

--- The round-trip suites wait for the server twice per test; TestKit's
--- default of 10 seconds per test is too short for a throttled worst case.
local ROUND_TRIP_SUITE_TIMEOUT_SECONDS = 30

--- The multi-chunk message: 2048 bytes are ceil(2048 / 251) = 9 chunks.
local LONG_MESSAGE_BYTES = 2048
local LONG_MESSAGE_CHUNKS = 9

--- The message the abort test cancels after its first chunk: 3 chunks.
local ABORTED_MESSAGE_BYTES = 600
local ABORTED_MESSAGE_CHUNKS = 3

--- The wire format of API generation 1 (packages/commKit/docs/API.md, "Wire
--- protocol").
local CONTROL = { single = 1, first = 2, middle = 3, last = 4, abort = 5 }
local CHUNK_BYTES = 255
local CHUNK_PAYLOAD_BYTES = 251
local ORDINARY_DIGIT_BASE = 0x80
local ORDINARY_RADIX = 128

--- How long the SyncSet test waits after a reply before it asks again: the
--- documented reply interval is one second per peer.
local SYNC_REPLY_INTERVAL_WAIT_SECONDS = 1.3

--- The documented FNV-1a test vectors (packages/commKit/docs/API.md,
--- "Content hashes"), computed with arithmetic on the client's own numbers.
local HASH_OF_STRING_A = 3539962124
local HASH_OF_NUMBER_ONE = 2020387990
local HASH_OF_TABLE_B2_A1 = 1171038798

--- The 12.x values CommKit falls back to when the client lacks an enum
--- (packages/commKit/docs/API.md, "The client API CommKit calls").
local SEND_RESULT_FALLBACKS = { Success = 0, AddonMessageThrottle = 3, ChannelThrottle = 8 }
local REGISTER_RESULT_FALLBACKS =
  { Success = 0, DuplicatePrefix = 1, InvalidPrefix = 2, MaxPrefixes = 3 }

--- How many times each query runs in the query allocation guard, and how many
--- refused sends the refusal guard makes.
local QUERY_CALLS = 10000
local REFUSAL_CALLS = 2000

--- Kilobytes an allocation guard tolerates. The tolerance absorbs a stray
--- allocation by the client between the two readings, not a per-call one.
local ALLOCATION_TOLERANCE_KB = 1

--- The prefix of the probe addon names the CloseAddonScopes test closes. A
--- closed addon scope stays closed for the session, so every run uses a
--- fresh name.
local PROBE_ADDON_PREFIX = "MoltenCodesTest_CommKitProbe"

--- Every method docs/API.md of commKit lists on the facade.
local FACADE_METHODS = {
  "CreateScope",
  "ForAddon",
  "CloseAddonScopes",
  "GetQueueDepth",
  "GetBudget",
  "SetLimits",
  "GetLimits",
  "GetStatistics",
}

--- Every method docs/API.md of commKit lists on a scope.
local SCOPE_METHODS = {
  "Register",
  "Send",
  "SyncSet",
  "UnregisterAll",
  "CancelAll",
  "Close",
  "IsClosed",
  "GetAddonName",
  "GetRegistrationCount",
  "GetPendingCount",
  "GetMaxRegistrations",
}

--- Every method docs/API.md of commKit lists on a send handle.
local HANDLE_METHODS = { "Cancel", "GetState", "GetBytesSent", "GetBytesTotal" }

--- Every client function docs/API.md says CommKit calls, all on `C_ChatInfo`.
local CHAT_FUNCTIONS = {
  "IsAddonMessagePrefixRegistered",
  "RegisterAddonMessagePrefix",
  "SendAddonMessage",
  "SendAddonMessageLogged",
}

---Read a client global, or `nil`.
---@param name string
---@return any
local function readHost(name)
  -- The chat API, its enums, the unit and realm functions, the clock, error
  -- handling and secret-value functions are World of Warcraft client
  -- globals, reachable only through the global table.
  -- selene: allow(global_usage)
  return rawget(_G, name)
end

---@type Registry
local Registry = rawget(rawget(namespace, "Registries") or {}, REGISTRY_API)
if type(Registry) ~= "table" then
  error(addonName .. " requires the MoltenCodes addon (Registry API 2); reinstall it", 0)
end

-- CommKit is not in the language-server workspace of tests/client (its
-- .luarc.json lists TestKit's dependency closure only), so its facade and its
-- objects are typed `any` here.

---@type any
local CommKit = Registry:Get(PACKAGE_ID, COMM_KIT_API)
if type(CommKit) == "nil" then
  error(addonName .. " requires CommKit API 1 in the MoltenCodes addon; reinstall it", 0)
end

---@type EventKit|nil
local EventKitOrNil = Registry:Get("eventKit", EVENT_KIT_API)
if type(EventKitOrNil) == "nil" then
  error(addonName .. " requires EventKit API 1 in the MoltenCodes addon; reinstall it", 0)
end
---@cast EventKitOrNil EventKit
local EventKit = EventKitOrNil

--- The clock the tests time sends and deliveries with; CommKit requires it
--- too, so it is always there when CommKit loaded.
local getTimePreciseSec = readHost("GetTimePreciseSec")
if type(getTimePreciseSec) ~= "function" then
  error(addonName .. " requires the client's GetTimePreciseSec", 0)
end

--- Read once at load: the SyncSet tests are registered as skipped when the
--- bundle does not carry CodecKit, which a SyncSet requires.
local CODEC_KIT_AVAILABLE = type(Registry:Find("codecKit", CODEC_KIT_API)) ~= "nil"

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

---Seconds as milliseconds, for the log.
---@param seconds number
---@return string
local function milliseconds(seconds)
  return ("%.1f ms"):format(seconds * 1000)
end

-- Helpers ---------------------------------------------------------------------------

--- Release actions of the running test (close a CommKit scope, an EventKit
--- scope, a SyncSet), run newest first by the After hook of every suite.
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

---Remember an object with a `Close` method for the After hook, which closes
---it, and hand it back. Closing a CommKit scope cancels its queued sends,
---closes its SyncSets and disconnects its registrations.
---@param object any
---@return any object
local function track(object)
  pendingReleases[#pendingReleases + 1] = function()
    object:Close()
  end
  return object
end

---A fresh manual CommKit scope, closed by the After hook.
---@return any scope
local function newCommScope()
  return track(CommKit:CreateScope())
end

---Register a suite of this package whose tests all end released.
---@param part string
---@param options MoltenCodesTest.SuiteOptions|nil
---@return TestKit.Suite
local function newSuite(part, options)
  local suite = Harness:Suite(PACKAGE_ID, part, addonName, options)
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

---Wait `seconds` of wall-clock time, one rendered frame at a time.
---@param ctx TestKit.Context
---@param seconds number
local function pause(ctx, seconds)
  local deadline = now() + seconds
  waitUntil(ctx, function()
    return now() >= deadline
  end, seconds + 5)
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

---Call `raise`, which must store its start line in `lines.start` with
---`currentLine()` and raise on the next line, and check the message names this
---file at that line and contains `expected` (compared literally).
---@param ctx TestKit.Context
---@param raise fun(lines: { start: integer }) Records its start line, then raises on the next line.
---@param expected string
local function expectErrorAtNextLine(ctx, raise, expected)
  local lines = { start = 0 }
  local succeeded, message = pcall(raise, lines)
  ctx:Expect(succeeded):ToBe(false)
  ctx:Log("client message: " .. tostring(message))
  ctx:Expect(type(message)):ToBe("string")
  if type(message) ~= "string" then
    return
  end
  local file, line = splitPosition(message)
  ctx:Expect((file or ""):sub(-#"CommKitSuite.lua")):ToBe("CommKitSuite.lua")
  ctx:Expect(message:find(expected, 1, true) ~= nil):ToBe(true)
  ctx:Expect(line):ToBe(lines.start + 1)
end

---The bytes of `text` in hexadecimal, at most `limit` of them.
---@param text string
---@param limit integer
---@return string
local function hex(text, limit)
  local parts = {}
  for index = 1, math.min(#text, limit) do
    parts[index] = ("%02X"):format(text:byte(index))
  end
  if #text > limit then
    parts[#parts + 1] = "..."
  end
  return table.concat(parts, " ")
end

---The first byte position where two strings differ, or `nil` when equal.
---@param expected string
---@param actual string
---@return integer|nil
local function firstDifference(expected, actual)
  local length = math.max(#expected, #actual)
  for index = 1, length do
    if expected:byte(index) ~= actual:byte(index) then
      return index
    end
  end
  return nil
end

---Every byte value `Send` accepts, in ascending order: 0x01 to 0xFF except
---line feed (0x0A), carriage return (0x0D) and the pipe (0x7C). 252 bytes.
---@return string
local function everyAcceptedByte()
  local characters = {}
  for byte = 1, 255 do
    if byte ~= 10 and byte ~= 13 and byte ~= 124 then
      characters[#characters + 1] = string.char(byte)
    end
  end
  return table.concat(characters)
end

--- The 252 byte values `Send` accepts.
local ACCEPTED_BYTES = everyAcceptedByte()

---`length` bytes cycling through every byte value `Send` accepts, so every
---chunk boundary lands on a different value.
---@param length integer
---@return string
local function cyclingPayload(length)
  local characters = {}
  for index = 1, length do
    local position = (index - 1) % #ACCEPTED_BYTES + 1
    characters[index] = ACCEPTED_BYTES:sub(position, position)
  end
  return table.concat(characters)
end

---Counter changes between two `GetStatistics` tables for the named counters.
---@param before table<string, integer>
---@param after table<string, integer>
---@param names string[]
---@return table<string, integer>
local function statisticsDelta(before, after, names)
  local delta = {}
  for _, name in ipairs(names) do
    delta[name] = (after[name] or 0) - (before[name] or 0)
  end
  return delta
end

---A delta table as `name +n` pairs for the log, in the order of `names`.
---@param delta table<string, integer>
---@param names string[]
---@return string
local function describeDelta(delta, names)
  local parts = {}
  for _, name in ipairs(names) do
    parts[#parts + 1] = ("%s %+d"):format(name, delta[name])
  end
  return table.concat(parts, ", ")
end

---The budget now, for the log.
---@return string
local function describeBudget()
  local available, bytesPerSecond, capacity, mode = CommKit:GetBudget()
  return ("%.0f of %d bytes available, refilling %.0f bytes/s, mode %s"):format(
    available,
    capacity,
    bytesPerSecond,
    tostring(mode)
  )
end

-- The player's own character --------------------------------------------------------

---The name the tests whisper to: the player's own character as
---`Name-Realm`, or `nil` when the client does not give a plain name.
---
---Every addon message a round-trip test sends goes to this one name, so no
---other player can receive it. The full form is used because the server
---reports the sender of a whisper that way, and a SyncSet keys its peers by
---the reported sender.
---@return string|nil fullName
---@return string|nil shortName
local function playerNames()
  local unitName = readHost("UnitName")
  if type(unitName) ~= "function" then
    return nil, nil
  end
  local name = unitName("player")
  if type(name) ~= "string" or isSecret(name) or name == "" then
    return nil, nil
  end
  local normalizedRealmName = readHost("GetNormalizedRealmName")
  if type(normalizedRealmName) ~= "function" then
    return name, name
  end
  local realm = normalizedRealmName()
  if type(realm) ~= "string" or isSecret(realm) or realm == "" then
    return name, name
  end
  return name .. "-" .. realm, name
end

---The player's own `Name-Realm`, or a skipped test naming why.
---@param ctx TestKit.Context
---@return string fullName
---@return string shortName
local function requirePlayerNames(ctx)
  local fullName, shortName = playerNames()
  if type(fullName) == "nil" or type(shortName) == "nil" then
    Harness:SkipTest(
      ctx,
      "the client gave no plain player name, so there was nobody safe to whisper"
    )
  end
  ---@cast fullName string
  ---@cast shortName string
  return fullName, shortName
end

---Whether `sender`, as `CHAT_MSG_ADDON` reported it, is the player's own
---character.
---@param sender any
---@param fullName string
---@param shortName string
---@return boolean
local function isPlayer(sender, fullName, shortName)
  if type(sender) ~= "string" or isSecret(sender) then
    return false
  end
  return sender == fullName or sender == shortName
end

-- Receiving -------------------------------------------------------------------------

---One whole message a CommKit registration delivered.
---@class CommKitSuite.Delivery
---@field prefix string
---@field text string
---@field distribution string
---@field sender string
---@field at number clock reading when the callback ran
---@field wireSeen integer|nil how many wire messages the observer had recorded when the callback ran, when `countWire` was given

---Register `prefix` in `scope` and collect every whole message delivered on
---it, or fail the test with the refusal.
---@param ctx TestKit.Context
---@param scope any
---@param prefix string
---@param countWire (fun(): integer)|nil answers how many wire messages the test's observer has recorded so far, so a delivery can be placed among the chunk events
---@return CommKitSuite.Delivery[] deliveries
local function collectDeliveries(ctx, scope, prefix, countWire)
  local deliveries = {}
  local connection, reason = scope:Register(
    prefix,
    function(deliveredPrefix, text, distribution, sender)
      deliveries[#deliveries + 1] = {
        prefix = deliveredPrefix,
        text = text,
        distribution = distribution,
        sender = sender,
        at = now(),
        wireSeen = countWire and countWire() or nil,
      }
    end
  )
  if type(connection) == "nil" then
    ctx:Fail("Register(" .. prefix .. ") was refused: " .. tostring(reason))
  end
  return deliveries
end

---One addon message the wire observer saw, exactly as the client delivered it.
---@class CommKitSuite.WireMessage
---@field text string
---@field channel string
---@field sender string
---@field at number clock reading when the event arrived
---@field deliveredBefore integer|nil how many whole messages the test's collector had received when the observer saw this one, when `deliveries` was given

---Watch `CHAT_MSG_ADDON` for `prefix` from the player's own character with an
---EventKit connection of the test's own, next to CommKit's, so a test can
---read the chunks exactly as the client delivered them. The client delivers
---the event only for registered prefixes, so the test registers the prefix
---with CommKit first.
---
---Both CommKit's listener and this one run on the same `CHAT_MSG_ADDON` event,
---in an order EventKit does not promise, so a delivery made while the last
---chunk's event is dispatched may be recorded before or after that chunk.
---`deliveries`, when given, is snapshotted per message to place deliveries
---among the chunk events without comparing clock readings.
---@param prefix string
---@param fullName string
---@param shortName string
---@param deliveries CommKitSuite.Delivery[]|nil
---@return CommKitSuite.WireMessage[] messages
local function observeWire(prefix, fullName, shortName, deliveries)
  local messages = {}
  local scope = track(EventKit:CreateScope())
  scope:Connect("CHAT_MSG_ADDON", function(_, eventPrefix, text, channel, sender)
    -- Secret payloads are dropped before anything compares them.
    if
      type(eventPrefix) ~= "string"
      or isSecret(eventPrefix)
      or type(text) ~= "string"
      or isSecret(text)
      or type(channel) ~= "string"
      or isSecret(channel)
    then
      return
    end
    if eventPrefix == prefix and isPlayer(sender, fullName, shortName) then
      messages[#messages + 1] = {
        text = text,
        channel = channel,
        sender = sender,
        at = now(),
        deliveredBefore = deliveries and #deliveries or nil,
      }
    end
  end)
  return messages
end

-- Sending ---------------------------------------------------------------------------

---What became of one send.
---@class CommKitSuite.SendRecord
---@field handle any the send handle
---@field startedAt number clock reading just before `Send`
---@field progress { bytesSent: integer, bytesTotal: integer, at: number, state: string }[]
---@field completions { state: string, reason: string|nil, at: number }[]

---Queue `request` in `scope` with callbacks that record its progress and its
---completion, or fail the test with the refusal.
---@param ctx TestKit.Context
---@param scope any
---@param request table The `Send` request; `onProgress` and `onComplete` are added.
---@param onFirstProgress fun(handle: any)|nil Called once, inside the first progress callback.
---@return CommKitSuite.SendRecord record
local function send(ctx, scope, request, onFirstProgress)
  ---@type CommKitSuite.SendRecord
  local record = { handle = nil, startedAt = now(), progress = {}, completions = {} }
  request.onProgress = function(handle, bytesSent, bytesTotal)
    record.progress[#record.progress + 1] = {
      bytesSent = bytesSent,
      bytesTotal = bytesTotal,
      at = now(),
      state = handle:GetState(),
    }
    if #record.progress == 1 and type(onFirstProgress) ~= "nil" then
      onFirstProgress(handle)
    end
  end
  request.onComplete = function(_, state, reason)
    record.completions[#record.completions + 1] = { state = state, reason = reason, at = now() }
  end
  local handle, reason = scope:Send(request)
  if type(handle) == "nil" then
    ctx:Fail("Send was refused: " .. tostring(reason))
  end
  record.handle = handle
  return record
end

---Wait until the send is terminal. A send the client refused (`failed`) or
---never accepted within `SEND_TIMEOUT_SECONDS` ends the test as skipped with
---the reason: the whisper to self is what did not work, not CommKit.
---@param ctx TestKit.Context
---@param record CommKitSuite.SendRecord
local function awaitSent(ctx, record)
  local terminal = waitUntil(ctx, function()
    return #record.completions > 0
  end, SEND_TIMEOUT_SECONDS)
  if not terminal then
    local state = record.handle:GetState()
    record.handle:Cancel()
    Harness:SkipTest(
      ctx,
      ("the client did not accept the whisper to self within %d s (state %s); cancelled"):format(
        SEND_TIMEOUT_SECONDS,
        tostring(state)
      )
    )
  end
  local completion = record.completions[1]
  if completion.state == "failed" then
    Harness:SkipTest(
      ctx,
      "the client refused the whisper to self: SendAddonMessage answered "
        .. tostring(completion.reason)
    )
  end
end

---Wait until `count` whole messages arrived. When none arrived at all, the
---client did not deliver the whisper to self, and the test ends as skipped;
---fewer than `count` is a failure the caller's expectations report.
---@param ctx TestKit.Context
---@param deliveries any[]
---@param count integer
local function awaitDeliveries(ctx, deliveries, count)
  waitUntil(ctx, function()
    return #deliveries >= count
  end, DELIVERY_TIMEOUT_SECONDS)
  if #deliveries == 0 then
    Harness:SkipTest(
      ctx,
      ("the client accepted the whisper to self but delivered no CHAT_MSG_ADDON within %d s"):format(
        DELIVERY_TIMEOUT_SECONDS
      )
    )
  end
end

---The whisper request of a test: `text` on `prefix` to the player's own
---character. The only destination any test in this file sends to.
---@param prefix string
---@param text string
---@param fullName string
---@return table request
local function whisperToSelf(prefix, text, fullName)
  return { prefix = prefix, text = text, distribution = "WHISPER", target = fullName }
end

-- Client enums ----------------------------------------------------------------------

---The client's `Enum[enumName]` table, or `nil`.
---@param enumName string
---@return table|nil
local function readEnum(enumName)
  local enums = readHost("Enum")
  if type(enums) ~= "table" then
    return nil
  end
  local values = rawget(enums, enumName)
  if type(values) ~= "table" then
    return nil
  end
  return values
end

---The key `Enum[enumTableName]` gives `value`, or `nil`. `value` must not
---be secret.
---@param enumTableName string
---@param value any
---@return string|nil
local function enumName(enumTableName, value)
  local values = readEnum(enumTableName)
  if type(values) == "nil" then
    return nil
  end
  for key, candidate in pairs(values) do
    if type(key) == "string" and not isSecret(candidate) and candidate == value then
      return key
    end
  end
  return nil
end

---Every entry of `Enum[enumTableName]` as `Key=value`, sorted by value, for
---the log.
---@param enumTableName string
---@return string
local function describeEnum(enumTableName)
  local values = readEnum(enumTableName)
  if type(values) == "nil" then
    return "absent"
  end
  local entries = {}
  for key, value in pairs(values) do
    if type(key) == "string" and type(value) == "number" and not isSecret(value) then
      entries[#entries + 1] = { key = key, value = value }
    end
  end
  table.sort(entries, function(left, right)
    return left.value < right.value
  end)
  local parts = {}
  for index, entry in ipairs(entries) do
    parts[index] = entry.key .. "=" .. entry.value
  end
  return table.concat(parts, ", ")
end

---`C_ChatInfo`, or `nil`.
---@return table|nil
local function chatInfo()
  local chat = readHost("C_ChatInfo")
  if type(chat) ~= "table" then
    return nil
  end
  return chat
end

---The number of prefixes the client reports registered, or `nil`.
---@return integer|nil
local function registeredPrefixCount()
  local chat = chatInfo()
  if type(chat) == "nil" or type(chat.GetRegisteredAddonMessagePrefixes) ~= "function" then
    return nil
  end
  local prefixes = chat.GetRegisteredAddonMessagePrefixes()
  if type(prefixes) ~= "table" then
    return nil
  end
  return #prefixes
end

---What `C_ChatInfo.IsAddonMessagePrefixRegistered(prefix)` answers, as text.
---@param prefix string
---@return string
local function describeRegistered(prefix)
  local chat = chatInfo()
  if type(chat) == "nil" or type(chat.IsAddonMessagePrefixRegistered) ~= "function" then
    return "unavailable"
  end
  local answer = chat.IsAddonMessagePrefixRegistered(prefix)
  if isSecret(answer) then
    return "secret"
  end
  return tostring(answer)
end

-- commKit.facade --------------------------------------------------------------------

local facade = newSuite("facade")

facade:Test(
  "Registry:Get('commKit', 1) is the CommKit facade with API 1, every documented method, MAX_MESSAGE_BYTES 255, MAX_REGISTRATIONS 32, the three priorities and UNBOUNDED",
  function(ctx)
    ctx:Expect(type(CommKit)):ToBe("table")
    ctx:Expect(rawget(CommKit, "API")):ToBe(COMM_KIT_API)
    for _, method in ipairs(FACADE_METHODS) do
      ctx:Expect(type(CommKit[method])):ToBe("function")
    end
    ctx:Expect(CommKit.MAX_MESSAGE_BYTES):ToBe(255)
    ctx:Expect(CommKit.MAX_REGISTRATIONS):ToBe(32)
    ctx:Expect(CommKit.Priority.ALERT):ToBe("ALERT")
    ctx:Expect(CommKit.Priority.NORMAL):ToBe("NORMAL")
    ctx:Expect(CommKit.Priority.BULK):ToBe("BULK")
    ctx:Expect(type(CommKit.UNBOUNDED)):ToBe("table")

    local scope = newCommScope()
    for _, method in ipairs(SCOPE_METHODS) do
      ctx:Expect(type(scope[method])):ToBe("function")
    end
    ctx:Expect(scope:GetMaxRegistrations()):ToBe(32)
    ctx:Expect(scope:GetAddonName()):ToBeNil()

    -- A handle of a send cancelled before CommKit's driver ran, so nothing
    -- leaves; it is addressed to the player's own character all the same.
    local fullName = playerNames()
    if type(fullName) ~= "nil" then
      local handle = scope:Send(whisperToSelf(PREFIX.short, "facade probe", fullName))
      for _, method in ipairs(HANDLE_METHODS) do
        ctx:Expect(type(handle[method])):ToBe("function")
      end
      ctx:Expect(handle:Cancel()):ToBe(true)
      ctx:Expect(handle:GetState()):ToBe("cancelled")
    end
  end
)

facade:Test("the installed CommKit carries the revision of the committed manifest", function(ctx)
  local expectedPackages = Harness:GetExpectedPackages()
  if type(expectedPackages) == "nil" then
    ctx:Fail("Expected.lua is missing; install with python3 -m tooling.client.install")
    return
  end
  for _, expected in ipairs(expectedPackages) do
    if expected.id == PACKAGE_ID then
      local _, revision = Registry:Get(PACKAGE_ID, COMM_KIT_API)
      ctx:Expect(revision):ToBe(expected.revision)
      ctx:Expect(rawget(CommKit, "REVISION")):ToBe(expected.revision)
      return
    end
  end
  ctx:Fail("Expected.lua does not list commKit")
end)

facade:Test(
  "C_ChatInfo has every function CommKit calls, and the client's SendAddonMessageResult and RegisterAddonMessagePrefixResult give the values CommKit falls back to (both enums logged)",
  function(ctx)
    local chat = chatInfo()
    ctx:Expect(type(chat)):ToBe("table")
    if type(chat) == "nil" then
      return
    end
    for _, name in ipairs(CHAT_FUNCTIONS) do
      ctx:Log(("C_ChatInfo.%s: %s"):format(name, type(chat[name])))
      ctx:Expect(type(chat[name])):ToBe("function")
    end
    ctx:Log("Enum.SendAddonMessageResult: " .. describeEnum("SendAddonMessageResult"))
    ctx:Log(
      "Enum.RegisterAddonMessagePrefixResult: " .. describeEnum("RegisterAddonMessagePrefixResult")
    )

    local sendResults = readEnum("SendAddonMessageResult")
    local registerResults = readEnum("RegisterAddonMessagePrefixResult")
    ctx:Expect(type(sendResults)):ToBe("table")
    ctx:Expect(type(registerResults)):ToBe("table")
    if type(sendResults) == "nil" or type(registerResults) == "nil" then
      return
    end
    for key, fallback in pairs(SEND_RESULT_FALLBACKS) do
      local value = sendResults[key]
      ctx:Expect(isSecret(value)):ToBe(false)
      ctx:Expect(value):ToBe(fallback)
    end
    for key, fallback in pairs(REGISTER_RESULT_FALLBACKS) do
      local value = registerResults[key]
      ctx:Expect(isSecret(value)):ToBe(false)
      ctx:Expect(value):ToBe(fallback)
    end
  end
)

-- commKit.prefixes ------------------------------------------------------------------

local prefixes = newSuite("prefixes")

prefixes:Test(
  "Register has the real client register the prefix, IsAddonMessagePrefixRegistered then answers true, and registering it again answers DuplicatePrefix (answers and prefix count logged)",
  function(ctx)
    local chat = chatInfo()
    if type(chat) == "nil" then
      ctx:Fail("the client has no C_ChatInfo")
      return
    end
    local prefix = PREFIX.registration
    local countBefore = registeredPrefixCount()
    local registeredBefore = describeRegistered(prefix)

    local scope = newCommScope()
    local connection, reason = scope:Register(prefix, function() end)
    ctx:Expect(reason):ToBeNil()
    ctx:Expect(type(connection)):ToBe("table")
    ctx:Expect(scope:GetRegistrationCount()):ToBe(1)
    local registeredAfter = describeRegistered(prefix)
    local countAfter = registeredPrefixCount()

    -- Registering a registered prefix again changes nothing in the client.
    local answer = chat.RegisterAddonMessagePrefix(prefix)
    local answerText = "secret"
    if not isSecret(answer) then
      answerText = ("%s (%s)"):format(
        tostring(answer),
        tostring(enumName("RegisterAddonMessagePrefixResult", answer))
      )
    end

    ctx:Log(
      ("before Register: registered %s (true only when an earlier run registered it this session); after: %s"):format(
        registeredBefore,
        registeredAfter
      )
    )
    ctx:Log(
      ("registered prefixes: %s before, %s after; a second RegisterAddonMessagePrefix answered %s"):format(
        tostring(countBefore),
        tostring(countAfter),
        answerText
      )
    )
    ctx:Expect(registeredAfter):ToBe("true")
    ctx:Expect(isSecret(answer)):ToBe(false)
    if not isSecret(answer) then
      ctx:Expect(enumName("RegisterAddonMessagePrefixResult", answer)):ToBe("DuplicatePrefix")
    end
    ctx:Expect(connection:Disconnect()):ToBe(true)
    ctx:Expect(scope:GetRegistrationCount()):ToBe(0)
  end
)

prefixes:Skip(
  "Register returns nil and 'maxPrefixes' when the client's prefix limit is reached",
  "not probed: reaching the limit would register many prefixes the client cannot unregister; packages/commKit/tests/Lifecycle_spec.lua covers the refusal"
)

-- commKit.roundTrip -----------------------------------------------------------------

local roundTrip = newSuite("roundTrip", { timeoutSeconds = ROUND_TRIP_SUITE_TIMEOUT_SECONDS })

roundTrip:Test(
  "a short message whispered to the player's own character arrives once through CHAT_MSG_ADDON with its prefix, its text, WHISPER and the player as sender, and completes as sent (round trip logged)",
  function(ctx)
    local fullName, shortName = requirePlayerNames(ctx)
    local scope = newCommScope()
    local deliveries = collectDeliveries(ctx, scope, PREFIX.short)
    local text = "hello from MoltenCodes CommKit"

    local record = send(ctx, scope, whisperToSelf(PREFIX.short, text, fullName))
    ctx:Expect(record.handle:GetBytesTotal()):ToBe(#text)
    awaitSent(ctx, record)
    awaitDeliveries(ctx, deliveries, 1)
    -- A few more frames, so a second copy would have arrived.
    pause(ctx, 0.3)

    local delivery = deliveries[1]
    ctx:Log(
      ("sent after %s, delivered after %s; sender %q, distribution %q"):format(
        milliseconds(record.completions[1].at - record.startedAt),
        milliseconds(delivery.at - record.startedAt),
        tostring(delivery.sender),
        tostring(delivery.distribution)
      )
    )
    ctx:Expect(#deliveries):ToBe(1)
    ctx:Expect(delivery.prefix):ToBe(PREFIX.short)
    ctx:Expect(delivery.text):ToBe(text)
    ctx:Expect(delivery.distribution):ToBe("WHISPER")
    ctx:Expect(isPlayer(delivery.sender, fullName, shortName)):ToBe(true)
    ctx:Expect(#record.completions):ToBe(1)
    ctx:Expect(record.completions[1].state):ToBe("sent")
    ctx:Expect(record.completions[1].reason):ToBeNil()
    ctx:Expect(record.handle:GetState()):ToBe("sent")
    ctx:Expect(record.handle:GetBytesSent()):ToBe(#text)
    ctx:Expect(scope:GetPendingCount()):ToBe(0)
  end
)

roundTrip:Test(
  "an empty message travels as the lone control byte 01 and is delivered as an empty string",
  function(ctx)
    local fullName, shortName = requirePlayerNames(ctx)
    local scope = newCommScope()
    local deliveries = collectDeliveries(ctx, scope, PREFIX.short)
    local wire = observeWire(PREFIX.short, fullName, shortName)

    local record = send(ctx, scope, whisperToSelf(PREFIX.short, "", fullName))
    awaitSent(ctx, record)
    awaitDeliveries(ctx, deliveries, 1)
    waitUntil(ctx, function()
      return #wire >= 1
    end, DELIVERY_TIMEOUT_SECONDS)

    ctx:Log(
      ("on the wire: %d message(s), first %s"):format(#wire, hex((wire[1] or {}).text or "", 8))
    )
    ctx:Expect(#deliveries):ToBe(1)
    ctx:Expect(deliveries[1].text):ToBe("")
    ctx:Expect(#wire):ToBe(1)
    ctx:Expect((wire[1] or {}).text):ToBe(string.char(CONTROL.single))
  end
)

roundTrip:Test(
  "a 252-byte single chunk holding every byte value Send accepts (01-FF but 0A, 0D and 7C) arrives byte-identical, carried on the wire as 01 plus the payload",
  function(ctx)
    local fullName, shortName = requirePlayerNames(ctx)
    local scope = newCommScope()
    local deliveries = collectDeliveries(ctx, scope, PREFIX.short)
    local wire = observeWire(PREFIX.short, fullName, shortName)
    ctx:Expect(#ACCEPTED_BYTES):ToBe(252)

    local record = send(ctx, scope, whisperToSelf(PREFIX.short, ACCEPTED_BYTES, fullName))
    awaitSent(ctx, record)
    awaitDeliveries(ctx, deliveries, 1)
    waitUntil(ctx, function()
      return #wire >= 1
    end, DELIVERY_TIMEOUT_SECONDS)

    local received = deliveries[1].text
    local difference = firstDifference(ACCEPTED_BYTES, received)
    if type(difference) ~= "nil" then
      ctx:Log(
        ("first difference at byte %d: sent %s, received %s; received %d bytes"):format(
          difference,
          hex(ACCEPTED_BYTES:sub(difference, difference), 1),
          hex(received:sub(difference, difference), 1),
          #received
        )
      )
    end
    ctx:Log(
      ("delivered %d bytes; wire message %d bytes"):format(#received, #((wire[1] or {}).text or ""))
    )
    ctx:Expect(difference):ToBeNil()
    ctx:Expect(received):ToBe(ACCEPTED_BYTES)
    ctx:Expect((wire[1] or {}).text):ToBe(string.char(CONTROL.single) .. ACCEPTED_BYTES)
  end
)

---Check the chunks of one multi-chunk stream as the wire observer saw them:
---each is 255 bytes but the last, carries the control byte its index calls
---for and header digits in 80-FF, and all name one stream id and `total`.
---Returns the payload reassembled in index order.
---@param ctx TestKit.Context
---@param wire CommKitSuite.WireMessage[]
---@param total integer
---@return string payload
local function checkChunks(ctx, wire, total)
  local byIndex = {}
  local streamByte = nil
  for _, message in ipairs(wire) do
    local text = message.text
    local control, stream, high, low = text:byte(1, 4)
    ctx:Expect(#text >= 5):ToBe(true)
    ctx
      :Expect(
        stream >= ORDINARY_DIGIT_BASE and high >= ORDINARY_DIGIT_BASE and low >= ORDINARY_DIGIT_BASE
      )
      :ToBe(true)
    streamByte = streamByte or stream
    ctx:Expect(stream):ToBe(streamByte)
    local number = (high - ORDINARY_DIGIT_BASE) * ORDINARY_RADIX + (low - ORDINARY_DIGIT_BASE)
    local index = number
    if control == CONTROL.first then
      index = 1
      ctx:Expect(number):ToBe(total)
    elseif control == CONTROL.last then
      ctx:Expect(number):ToBe(total)
    else
      ctx:Expect(control):ToBe(CONTROL.middle)
    end
    if index < total then
      ctx:Expect(#text):ToBe(CHUNK_BYTES)
    end
    ctx:Expect(byIndex[index]):ToBeNil()
    byIndex[index] = text:sub(5)
  end
  local parts = {}
  for index = 1, total do
    parts[index] = byIndex[index] or ""
  end
  return table.concat(parts)
end

roundTrip:Test(
  "a 2048-byte message leaves as nine chunks with onProgress after each, 251 bytes apiece, and is delivered once and byte-identical (per-chunk timing, budget and throttles logged)",
  function(ctx)
    local fullName, shortName = requirePlayerNames(ctx)
    local scope = newCommScope()
    local wire = nil
    local deliveries = collectDeliveries(ctx, scope, PREFIX.long, function()
      return wire and #wire or 0
    end)
    wire = observeWire(PREFIX.long, fullName, shortName, deliveries)
    local payload = cyclingPayload(LONG_MESSAGE_BYTES)
    local counters = {
      "chunksSent",
      "throttled",
      "chunksReceived",
      "streamsOpened",
      "streamsCompleted",
      "messagesReceived",
      "bytesReceived",
    }
    local statisticsBefore = CommKit:GetStatistics()
    local budgetBefore = describeBudget()

    local record = send(ctx, scope, whisperToSelf(PREFIX.long, payload, fullName))
    ctx:Expect(record.handle:GetBytesTotal()):ToBe(LONG_MESSAGE_BYTES)
    awaitSent(ctx, record)
    local budgetAfter = describeBudget()
    awaitDeliveries(ctx, deliveries, 1)
    waitUntil(ctx, function()
      return #wire >= LONG_MESSAGE_CHUNKS
    end, DELIVERY_TIMEOUT_SECONDS)
    pause(ctx, 0.3)
    local delta = statisticsDelta(statisticsBefore, CommKit:GetStatistics(), counters)

    ctx:Log("budget before: " .. budgetBefore .. "; after the last chunk: " .. budgetAfter)
    for index, progress in ipairs(record.progress) do
      ctx:Log(
        ("chunk %d left at +%s: %d of %d bytes, state %s"):format(
          index,
          milliseconds(progress.at - record.startedAt),
          progress.bytesSent,
          progress.bytesTotal,
          progress.state
        )
      )
    end
    for index, message in ipairs(wire) do
      ctx:Log(
        ("wire message %d arrived at +%s: %d bytes, header %s"):format(
          index,
          milliseconds(message.at - record.startedAt),
          #message.text,
          hex(message.text, 4)
        )
      )
    end
    ctx:Log(
      ("delivered at +%s; %s"):format(
        milliseconds(deliveries[1].at - record.startedAt),
        describeDelta(delta, counters)
      )
    )

    ctx:Expect(#record.progress):ToBe(LONG_MESSAGE_CHUNKS)
    for index, progress in ipairs(record.progress) do
      ctx:Expect(progress.bytesSent):ToBe(math.min(index * CHUNK_PAYLOAD_BYTES, LONG_MESSAGE_BYTES))
      ctx:Expect(progress.bytesTotal):ToBe(LONG_MESSAGE_BYTES)
    end
    ctx:Expect(record.completions[1].state):ToBe("sent")
    ctx:Expect(record.handle:GetBytesSent()):ToBe(LONG_MESSAGE_BYTES)
    ctx:Expect(#deliveries):ToBe(1)
    ctx:Expect(deliveries[1].distribution):ToBe("WHISPER")
    ctx:Expect(firstDifference(payload, deliveries[1].text)):ToBeNil()
    ctx:Expect(deliveries[1].text == payload):ToBe(true)
    -- The message is whole only once the last chunk arrived. CommKit's
    -- listener and the observer share each CHAT_MSG_ADDON event, in either
    -- order (on Retail 12.1.0 b69933, 2026-09-25, CommKit's ran first), so
    -- the delivery is placed by the two listeners' counts, not by the clock:
    -- no chunk before the last saw a delivery, and the delivery came right
    -- next to the observer's record of the last chunk, just before it (CommKit
    -- first) or just after it (observer first). The clock readings are
    -- logged, not compared.
    ctx:Expect(#wire):ToBe(LONG_MESSAGE_CHUNKS)
    for index = 1, LONG_MESSAGE_CHUNKS - 1 do
      ctx:Expect(wire[index].deliveredBefore):ToBe(0)
    end
    local lastChunk = wire[LONG_MESSAGE_CHUNKS]
    local deliveredFirst = lastChunk.deliveredBefore == 1
    ctx:Log(
      ("the delivery ran %s the observer's record of the last chunk (observer had %s chunks at delivery; %s deliveries at the last chunk)"):format(
        deliveredFirst and "before" or "after",
        tostring(deliveries[1].wireSeen),
        tostring(lastChunk.deliveredBefore)
      )
    )
    if deliveredFirst then
      ctx:Expect(deliveries[1].wireSeen):ToBe(LONG_MESSAGE_CHUNKS - 1)
    else
      ctx:Expect(lastChunk.deliveredBefore):ToBe(0)
      ctx:Expect(deliveries[1].wireSeen):ToBe(LONG_MESSAGE_CHUNKS)
    end
    ctx:Expect(checkChunks(ctx, wire, LONG_MESSAGE_CHUNKS) == payload):ToBe(true)
    ctx:Expect(delta.chunksSent):ToBe(LONG_MESSAGE_CHUNKS)
    ctx:Expect(delta.streamsOpened):ToBe(1)
    ctx:Expect(delta.streamsCompleted):ToBe(1)
    ctx:Expect(delta.messagesReceived):ToBe(1)
    ctx:Expect(delta.bytesReceived):ToBe(LONG_MESSAGE_BYTES)
    ctx:Expect(CommKit:GetQueueDepth()):ToBe(0)
  end
)

roundTrip:Test(
  "a message cancelled from onProgress after its first chunk sends one abort chunk (05, its stream id, its count) and the receiver drops the stream silently",
  function(ctx)
    local fullName, shortName = requirePlayerNames(ctx)
    local scope = newCommScope()
    local deliveries = collectDeliveries(ctx, scope, PREFIX.abort)
    local wire = observeWire(PREFIX.abort, fullName, shortName)
    local counters =
      { "chunksSent", "streamsOpened", "streamsAborted", "streamsCompleted", "messagesCancelled" }
    local statisticsBefore = CommKit:GetStatistics()
    local openStreamsBefore = statisticsBefore.openStreams
    local cancelAnswer = nil

    local record = send(
      ctx,
      scope,
      whisperToSelf(PREFIX.abort, cyclingPayload(ABORTED_MESSAGE_BYTES), fullName),
      function(handle)
        cancelAnswer = handle:Cancel()
      end
    )
    awaitSent(ctx, record)
    waitUntil(ctx, function()
      return #wire >= 2
    end, DELIVERY_TIMEOUT_SECONDS)
    if #wire == 0 then
      Harness:SkipTest(
        ctx,
        ("the client accepted the whisper to self but delivered no CHAT_MSG_ADDON within %d s"):format(
          DELIVERY_TIMEOUT_SECONDS
        )
      )
    end
    pause(ctx, QUIET_WAIT_SECONDS)
    local statisticsAfter = CommKit:GetStatistics()
    local delta = statisticsDelta(statisticsBefore, statisticsAfter, counters)

    for index, message in ipairs(wire) do
      ctx:Log(
        ("wire message %d: %d bytes, header %s"):format(index, #message.text, hex(message.text, 4))
      )
    end
    ctx:Log(describeDelta(delta, counters))

    ctx:Expect(cancelAnswer):ToBe(true)
    ctx:Expect(#record.completions):ToBe(1)
    ctx:Expect(record.completions[1].state):ToBe("cancelled")
    ctx:Expect(record.completions[1].reason):ToBe("cancelled")
    ctx:Expect(record.handle:GetBytesSent()):ToBe(CHUNK_PAYLOAD_BYTES)
    ctx:Expect(#record.progress):ToBe(1)
    ctx:Expect(#wire):ToBe(2)
    local first = (wire[1] or {}).text or ""
    local abort = (wire[2] or {}).text or ""
    ctx:Expect(first:byte(1)):ToBe(CONTROL.first)
    ctx:Expect(#abort):ToBe(4)
    ctx:Expect(abort:byte(1)):ToBe(CONTROL.abort)
    -- The abort names the stream and the count its first chunk declared.
    ctx:Expect(abort:sub(2, 4)):ToBe(first:sub(2, 4))
    ctx:Expect(abort:byte(4)):ToBe(ORDINARY_DIGIT_BASE + ABORTED_MESSAGE_CHUNKS)
    ctx:Expect(#deliveries):ToBe(0)
    ctx:Expect(delta.chunksSent):ToBe(2)
    ctx:Expect(delta.streamsOpened):ToBe(1)
    ctx:Expect(delta.streamsAborted):ToBe(1)
    ctx:Expect(delta.streamsCompleted):ToBe(0)
    ctx:Expect(statisticsAfter.openStreams):ToBe(openStreamsBefore)
  end
)

roundTrip:Test(
  "a raw C_ChatInfo.SendAddonMessage of a CommKit single chunk answers Success (result logged), reaches CommKit's registration, and is charged as outside traffic when HookKit is loaded",
  function(ctx)
    local fullName = requirePlayerNames(ctx)
    local chat = chatInfo()
    if type(chat) == "nil" or type(chat.SendAddonMessage) ~= "function" then
      ctx:Fail("the client has no C_ChatInfo.SendAddonMessage")
      return
    end
    local scope = newCommScope()
    local deliveries = collectDeliveries(ctx, scope, PREFIX.raw)

    -- One CommKit send first: CommKit installs its outside-traffic hooks the
    -- first time its driver wakes with HookKit loaded.
    local warm = send(ctx, scope, whisperToSelf(PREFIX.raw, "warm", fullName))
    awaitSent(ctx, warm)

    local counters = { "outsideMessages", "outsideBytes", "chunksSent" }
    local statisticsBefore = CommKit:GetStatistics()
    local text = string.char(CONTROL.single) .. "raw direct send"
    local result = chat.SendAddonMessage(PREFIX.raw, text, "WHISPER", fullName)
    local delta = statisticsDelta(statisticsBefore, CommKit:GetStatistics(), counters)

    local resultText = "secret"
    if not isSecret(result) then
      resultText = ("%s %s (%s)"):format(
        type(result),
        tostring(result),
        tostring(enumName("SendAddonMessageResult", result))
      )
    end
    ctx:Log("SendAddonMessage answered " .. resultText)
    ctx:Expect(isSecret(result)):ToBe(false)
    local resultName = nil
    if not isSecret(result) then
      resultName = enumName("SendAddonMessageResult", result)
    end
    if resultName == "AddonMessageThrottle" or resultName == "ChannelThrottle" then
      Harness:SkipTest(
        ctx,
        "the client throttled the raw send (" .. resultName .. "); run it again in a few seconds"
      )
    end
    if type(result) ~= "nil" then
      ctx:Expect(resultName):ToBe("Success")
    end

    local hookKitLoaded = type(Registry:Find("hookKit", HOOK_KIT_API)) ~= "nil"
    local overhead = CommKit:GetLimits().messageOverhead
    ctx:Log(
      ("HookKit loaded: %s; %s"):format(tostring(hookKitLoaded), describeDelta(delta, counters))
    )
    ctx:Expect(delta.chunksSent):ToBe(0)
    if hookKitLoaded then
      ctx:Expect(delta.outsideMessages):ToBe(1)
      ctx:Expect(delta.outsideBytes):ToBe(#PREFIX.raw + #text + overhead)
    else
      ctx:Expect(delta.outsideMessages):ToBe(0)
    end

    awaitDeliveries(ctx, deliveries, 2)
    ctx:Expect(#deliveries):ToBe(2)
    local texts = {}
    for _, delivery in ipairs(deliveries) do
      texts[delivery.text] = true
    end
    ctx:Expect(texts.warm):ToBe(true)
    ctx:Expect(texts["raw direct send"]):ToBe(true)
  end
)

roundTrip:Test(
  "a send cancelled before CommKit's driver ran never reaches the client, and completes once as cancelled",
  function(ctx)
    local fullName, shortName = requirePlayerNames(ctx)
    local scope = newCommScope()
    local deliveries = collectDeliveries(ctx, scope, PREFIX.short)
    local wire = observeWire(PREFIX.short, fullName, shortName)
    local statisticsBefore = CommKit:GetStatistics()
    local messagesBefore = CommKit:GetQueueDepth()

    local record = send(ctx, scope, whisperToSelf(PREFIX.short, "never leaves", fullName))
    ctx:Expect(record.handle:GetState()):ToBe("queued")
    ctx:Expect(scope:GetPendingCount()):ToBe(1)
    ctx:Expect((CommKit:GetQueueDepth())):ToBe(messagesBefore + 1)
    ctx:Expect(record.handle:Cancel()):ToBe(true)
    ctx:Expect(record.handle:Cancel()):ToBe(false)

    ctx:Expect(#record.completions):ToBe(1)
    ctx:Expect(record.completions[1].state):ToBe("cancelled")
    ctx:Expect(record.completions[1].reason):ToBe("cancelled")
    ctx:Expect(scope:GetPendingCount()):ToBe(0)
    ctx:Expect((CommKit:GetQueueDepth())):ToBe(messagesBefore)

    pause(ctx, QUIET_WAIT_SECONDS)
    local delta = statisticsDelta(statisticsBefore, CommKit:GetStatistics(), { "chunksSent" })
    ctx:Log(
      ("after %s: %d wire message(s), chunksSent %+d"):format(
        milliseconds(QUIET_WAIT_SECONDS),
        #wire,
        delta.chunksSent
      )
    )
    ctx:Expect(#wire):ToBe(0)
    ctx:Expect(#deliveries):ToBe(0)
    ctx:Expect(delta.chunksSent):ToBe(0)
    ctx:Expect(#record.progress):ToBe(0)
    ctx:Expect(#record.completions):ToBe(1)
  end
)

-- commKit.syncSet -------------------------------------------------------------------

local syncSet = newSuite("syncSet", { timeoutSeconds = ROUND_TRIP_SUITE_TIMEOUT_SECONDS })

local SYNC_SET_TEST_NAME =
  "a SyncSet that whispers a request to the player's own character answers itself with a delivery of all three fields, and a second request a second later with an ack (hashes checked against the documented vectors)"

if CODEC_KIT_AVAILABLE then
  syncSet:Test(SYNC_SET_TEST_NAME, function(ctx)
    local fullName, shortName = requirePlayerNames(ctx)
    local scope = newCommScope()
    ---@type any
    local SchemaKit = Registry:Find("schemaKit", SCHEMA_KIT_API)
    local options = { fields = { "name", "level", "talents" } }
    if type(SchemaKit) ~= "nil" then
      options.schema = {
        level = SchemaKit:Seal(SchemaKit.number({ integer = true, min = 1, max = 80 })),
      }
    end
    local sync, reason = scope:SyncSet(PREFIX.sync, options)
    ctx:Expect(reason):ToBeNil()
    if type(sync) == "nil" then
      ctx:Fail("SyncSet was refused: " .. tostring(reason))
      return
    end
    local wire = observeWire(PREFIX.sync, fullName, shortName)

    -- The documented FNV-1a vectors, on the client's own arithmetic.
    ctx:Expect(sync:Set("name", "a")):ToBe(true)
    ctx:Expect(sync:Set("level", 1)):ToBe(true)
    ctx:Expect(sync:Set("talents", { b = 2, a = 1 })):ToBe(true)
    ctx:Log(
      ("hashes: name %s, level %s, talents %s"):format(
        tostring(sync:GetHash("name")),
        tostring(sync:GetHash("level")),
        tostring(sync:GetHash("talents"))
      )
    )
    ctx:Expect(sync:GetHash("name")):ToBe(HASH_OF_STRING_A)
    ctx:Expect(sync:GetHash("level")):ToBe(HASH_OF_NUMBER_ONE)
    ctx:Expect(sync:GetHash("talents")):ToBe(HASH_OF_TABLE_B2_A1)
    ctx:Log("SchemaKit loaded, schema on level: " .. tostring(type(SchemaKit) ~= "nil"))

    local changes = {}
    sync:OnChanged(function(sender, field, value)
      changes[#changes + 1] = { sender = sender, field = field, value = value, at = now() }
    end)
    local counters = { "syncRequests", "syncDeliveries", "syncAcknowledgements", "syncRejected" }
    local statisticsBefore = CommKit:GetStatistics()

    local firstRequest = sync:Request(fullName)
    ctx:Expect(type(firstRequest)):ToBe("table")
    -- A request the client refused ends the wait at once.
    waitUntil(ctx, function()
      return #changes >= 3 or (firstRequest and firstRequest:GetState() == "failed")
    end, DELIVERY_TIMEOUT_SECONDS + SEND_TIMEOUT_SECONDS)
    if #wire == 0 then
      Harness:SkipTest(
        ctx,
        "no CHAT_MSG_ADDON came back for the SyncSet request whispered to self (request state "
          .. tostring(firstRequest and firstRequest:GetState())
          .. "; failed means the client refused it)"
      )
    end
    ctx:Expect(#changes):ToBe(3)
    local sender = (changes[1] or {}).sender
    ctx:Log(("OnChanged from %q: %d change(s)"):format(tostring(sender), #changes))
    ctx:Expect(isPlayer(sender, fullName, shortName)):ToBe(true)
    local changedFields = {}
    for _, change in ipairs(changes) do
      changedFields[change.field] = true
    end
    ctx:Expect(changedFields.name and changedFields.level and changedFields.talents):ToBe(true)
    if type(sender) == "string" then
      ctx:Expect(sync:GetRemote(sender, "name")):ToBe("a")
      ctx:Expect(sync:GetRemote(sender, "level")):ToBe(1)
      ctx:Expect(sync:GetRemote(sender, "talents")):ToEqual({ b = 2, a = 1 })
    end

    -- Past the one-second reply interval, the same request is acknowledged.
    pause(ctx, SYNC_REPLY_INTERVAL_WAIT_SECONDS)
    local acknowledgementsBefore = CommKit:GetStatistics().syncAcknowledgements
    local secondRequest = sync:Request(type(sender) == "string" and sender or fullName)
    ctx:Expect(type(secondRequest)):ToBe("table")
    waitUntil(ctx, function()
      return CommKit:GetStatistics().syncAcknowledgements > acknowledgementsBefore
    end, DELIVERY_TIMEOUT_SECONDS + SEND_TIMEOUT_SECONDS)
    pause(ctx, 0.3)
    local delta = statisticsDelta(statisticsBefore, CommKit:GetStatistics(), counters)
    ctx:Log(("%d wire message(s); %s"):format(#wire, describeDelta(delta, counters)))

    ctx:Expect(delta.syncRequests):ToBe(2)
    ctx:Expect(delta.syncDeliveries):ToBe(1)
    ctx:Expect(delta.syncAcknowledgements):ToBe(1)
    ctx:Expect(delta.syncRejected):ToBe(0)
    ctx:Expect(#changes):ToBe(3)
    ctx:Expect(#wire):ToBe(4)
  end)
else
  syncSet:Skip(
    SYNC_SET_TEST_NAME,
    "the MoltenCodes addon carries no CodecKit API 1, which a SyncSet requires"
  )
end

-- commKit.scopes --------------------------------------------------------------------

local scopes = newSuite("scopes")

scopes:Test(
  "ForAddon with this test addon's name returns one open scope naming the addon, with the default 32 registrations (logout route logged)",
  function(ctx)
    local scope = CommKit:ForAddon(addonName)
    ctx:Expect(CommKit:ForAddon(addonName)):ToBe(scope)
    ctx:Expect(scope:GetAddonName()):ToBe(addonName)
    ctx:Expect(scope:IsClosed()):ToBe(false)
    ctx:Expect(scope:GetMaxRegistrations()):ToBe(CommKit.MAX_REGISTRATIONS)

    -- Which logout route CommKit took; docs/API.md, "At logout".
    ---@type LifecycleKit|nil
    local LifecycleKit = Registry:Get("lifecycleKit", LIFECYCLE_KIT_API)
    local closesScopes = false
    if type(LifecycleKit) ~= "nil" then
      local capabilities = LifecycleKit.CLOSES_ADDON_SCOPES
      closesScopes = type(capabilities) == "table" and capabilities[PACKAGE_ID] == true
    end
    ctx:Log(
      "LifecycleKit loaded: "
        .. tostring(type(LifecycleKit) ~= "nil")
        .. "; it lists commKit in CLOSES_ADDON_SCOPES: "
        .. tostring(closesScopes)
    )
  end
)

scopes:Test(
  "CloseAddonScopes on a probe addon cancels its queued send with reason shutdown before any chunk leaves, answers true then false, and the closed scope refuses Send and Register with closed",
  function(ctx)
    local fullName = requirePlayerNames(ctx)
    probeSequence = probeSequence + 1
    local probeName = PROBE_ADDON_PREFIX .. probeSequence
    ctx:Expect(CommKit:CloseAddonScopes(probeName)):ToBe(false)

    local scope = CommKit:ForAddon(probeName)
    local statisticsBefore = CommKit:GetStatistics()
    local record = send(ctx, scope, whisperToSelf(PREFIX.short, "closed before it left", fullName))
    ctx:Expect(CommKit:CloseAddonScopes(probeName)):ToBe(true)
    ctx:Expect(CommKit:CloseAddonScopes(probeName)):ToBe(false)

    ctx:Expect(#record.completions):ToBe(1)
    ctx:Expect(record.completions[1].state):ToBe("cancelled")
    ctx:Expect(record.completions[1].reason):ToBe("shutdown")
    ctx:Expect(scope:IsClosed()):ToBe(true)
    ctx:Expect(CommKit:ForAddon(probeName)):ToBe(scope)

    local handle, reason = scope:Send(whisperToSelf(PREFIX.short, "refused", fullName))
    ctx:Expect(handle):ToBeNil()
    ctx:Expect(reason):ToBe("closed")
    local connection, registerReason = scope:Register(PREFIX.short, function() end)
    ctx:Expect(connection):ToBeNil()
    ctx:Expect(registerReason):ToBe("closed")

    pause(ctx, 0.2)
    local delta = statisticsDelta(statisticsBefore, CommKit:GetStatistics(), { "chunksSent" })
    ctx:Log(("probe %s: chunksSent %+d"):format(probeName, delta.chunksSent))
    ctx:Expect(delta.chunksSent):ToBe(0)
  end
)

scopes:Skip(
  "at logout this addon's scope is closed and its queued sends are cancelled with reason shutdown",
  "not observable in a run: PLAYER_LOGOUT ends the session before a result could be printed or saved; packages/commKit/tests/LogoutClose_spec.lua proves it"
)

-- commKit.allocation ----------------------------------------------------------------

local allocation = newSuite("allocation")

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

allocation:Test(
  "handle and queue queries (GetState, GetBytesSent, GetBytesTotal, GetQueueDepth, GetBudget, scope getters) allocate nothing over 10000 rounds (allocation guard)",
  function(ctx)
    local fullName = requirePlayerNames(ctx)
    local scope = newCommScope()
    local handle = scope:Send(whisperToSelf(PREFIX.short, "never leaves", fullName))
    ctx:Expect(handle:Cancel()):ToBe(true)
    local bulk = CommKit.Priority.BULK
    collectBeforeMeasuring(ctx)

    local grownKilobytes = measureAllocation(function()
      for _ = 1, QUERY_CALLS do
        handle:GetState()
        handle:GetBytesSent()
        handle:GetBytesTotal()
        CommKit:GetQueueDepth()
        CommKit:GetQueueDepth(bulk)
        CommKit:GetBudget()
        scope:GetPendingCount()
        scope:GetRegistrationCount()
        scope:IsClosed()
      end
    end)

    ctx:Log(("memory delta over %d rounds of 9 calls: %.3f KB"):format(QUERY_CALLS, grownKilobytes))
    ctx:Expect(grownKilobytes <= ALLOCATION_TOLERANCE_KB):ToBe(true)
  end
)

allocation:Test(
  "2000 refused sends (a forbidden byte, WHISPER without a target) allocate nothing, queue nothing and are counted (allocation guard)",
  function(ctx)
    local fullName = requirePlayerNames(ctx)
    local scope = newCommScope()
    local forbidden =
      { prefix = PREFIX.short, text = "a|b", distribution = "WHISPER", target = fullName }
    local untargeted = { prefix = PREFIX.short, text = "hello", distribution = "WHISPER" }
    local counters =
      { "refusedForbiddenByte", "refusedBadDistribution", "messagesQueued", "chunksSent" }
    local messagesBefore = CommKit:GetQueueDepth()
    local statisticsBefore = CommKit:GetStatistics()
    ---@type string|nil
    local lastForbiddenReason, lastUntargetedReason = nil, nil
    collectBeforeMeasuring(ctx)

    local grownKilobytes = measureAllocation(function()
      for _ = 1, REFUSAL_CALLS / 2 do
        local _, forbiddenReason = scope:Send(forbidden)
        local _, untargetedReason = scope:Send(untargeted)
        lastForbiddenReason, lastUntargetedReason = forbiddenReason, untargetedReason
      end
    end)
    local delta = statisticsDelta(statisticsBefore, CommKit:GetStatistics(), counters)

    ctx:Log(
      ("memory delta over %d refused sends: %.3f KB; %s"):format(
        REFUSAL_CALLS,
        grownKilobytes,
        describeDelta(delta, counters)
      )
    )
    ctx:Expect(lastForbiddenReason):ToBe("forbiddenByte")
    ctx:Expect(lastUntargetedReason):ToBe("badDistribution")
    ctx:Expect(grownKilobytes <= ALLOCATION_TOLERANCE_KB):ToBe(true)
    ctx:Expect(delta.refusedForbiddenByte):ToBe(REFUSAL_CALLS / 2)
    ctx:Expect(delta.refusedBadDistribution):ToBe(REFUSAL_CALLS / 2)
    ctx:Expect(delta.messagesQueued):ToBe(0)
    ctx:Expect(delta.chunksSent):ToBe(0)
    ctx:Expect((CommKit:GetQueueDepth())):ToBe(messagesBefore)
    ctx:Expect(scope:GetPendingCount()):ToBe(0)
  end
)

allocation:Skip(
  "receiving and delivering a single chunk allocates no table (allocation guard)",
  "not measurable here: the client delivers CHAT_MSG_ADDON between frames, where every other listener allocates too; packages/commKit/tests/Allocation_spec.lua guards it"
)

-- commKit.errors --------------------------------------------------------------------

local errors = newSuite("errors")

errors:Test("Send with an unknown request field names it at the calling line", function(ctx)
  local fullName = requirePlayerNames(ctx)
  local scope = newCommScope()
  expectErrorAtNextLine(ctx, function(lines)
    lines.start = currentLine()
    scope:Send({
      prefix = PREFIX.short,
      text = "x",
      distribution = "WHISPER",
      target = fullName,
      colour = 1,
    })
  end, 'CommKit.Scope:Send request contains unknown field "colour"')
  ctx:Expect(scope:GetPendingCount()):ToBe(0)
end)

errors:Test(
  "Send with an unknown priority, and Register with a 17-byte prefix or a callback that is not a function, are refused at the calling line",
  function(ctx)
    local fullName = requirePlayerNames(ctx)
    local scope = newCommScope()
    ---@type any
    local notAFunction = "not a function"
    expectErrorAtNextLine(ctx, function(lines)
      lines.start = currentLine()
      scope:Send({
        prefix = PREFIX.short,
        text = "x",
        distribution = "WHISPER",
        target = fullName,
        priority = "URGENT",
      })
    end, "CommKit.Scope:Send request.priority must be CommKit.Priority.ALERT, NORMAL or BULK")
    expectErrorAtNextLine(ctx, function(lines)
      lines.start = currentLine()
      scope:Register("MCTCommKitTooLong", function() end)
    end, "CommKit.Scope:Register prefix must be a string of 1 to 16 bytes")
    expectErrorAtNextLine(ctx, function(lines)
      lines.start = currentLine()
      scope:Register(PREFIX.short, notAFunction)
    end, "CommKit.Scope:Register callback must be a function")
    ctx:Expect(scope:GetRegistrationCount()):ToBe(0)
    ctx:Expect(scope:GetPendingCount()):ToBe(0)
  end
)

errors:Test(
  "a facade method called with a dot and a scope method called on another table are refused at the calling line",
  function(ctx)
    ---@type any
    local untypedCommKit = CommKit
    local scope = newCommScope()
    expectErrorAtNextLine(
      ctx,
      function(lines)
        lines.start = currentLine()
        untypedCommKit.GetQueueDepth({})
      end,
      "CommKit:GetQueueDepth must be called on the CommKit facade; use CommKit:GetQueueDepth(...)"
    )
    expectErrorAtNextLine(ctx, function(lines)
      lines.start = currentLine()
      scope.GetPendingCount({})
    end, "CommKit.Scope:GetPendingCount must be called on a CommKit scope")
  end
)

errors:Test(
  "SetLimits refuses CommKit.UNBOUNDED and an out-of-range value at the calling line and changes nothing",
  function(ctx)
    local limitsBefore = CommKit:GetLimits()
    expectErrorAtNextLine(ctx, function(lines)
      lines.start = currentLine()
      CommKit:SetLimits({ maxQueuedBytes = CommKit.UNBOUNDED })
    end, "CommKit:SetLimits limits.maxQueuedBytes does not accept CommKit.UNBOUNDED")
    expectErrorAtNextLine(ctx, function(lines)
      lines.start = currentLine()
      CommKit:SetLimits({ maxQueuedBytes = 0 })
    end, "CommKit:SetLimits limits.maxQueuedBytes must be an integer from 1 to 1048576")
    ctx:Expect(CommKit:GetLimits()):ToEqual(limitsBefore)
  end
)

errors:Test(
  "Send answers nil and the documented reason for NUL, LF, CR and | in the text, WHISPER without a target, and a text past maxReassemblyBytesPerSender, queueing nothing",
  function(ctx)
    local fullName = requirePlayerNames(ctx)
    local scope = newCommScope()
    local cases = {
      { text = "a\0b", target = fullName, expected = "forbiddenByte" },
      { text = "a\nb", target = fullName, expected = "forbiddenByte" },
      { text = "a\rb", target = fullName, expected = "forbiddenByte" },
      { text = "a|b", target = fullName, expected = "forbiddenByte" },
      { text = "hello", target = nil, expected = "badDistribution" },
      { text = "hello", target = "", expected = "badDistribution" },
      {
        text = string.rep(
          "a",
          CommKit:GetLimits().maxReassemblyBytesPerSender + CHUNK_PAYLOAD_BYTES
        ),
        target = fullName,
        expected = "tooLarge",
      },
    }
    for index, case in ipairs(cases) do
      local handle, reason = scope:Send({
        prefix = PREFIX.short,
        text = case.text,
        distribution = "WHISPER",
        target = case.target,
      })
      ctx:Log(("case %d: %s"):format(index, tostring(reason)))
      ctx:Expect(handle):ToBeNil()
      ctx:Expect(reason):ToBe(case.expected)
    end
    ctx:Expect(scope:GetPendingCount()):ToBe(0)
  end
)

errors:Test(
  "ForAddon with an empty name and a SyncSet without fields are refused at the calling line",
  function(ctx)
    local scope = newCommScope()
    expectErrorAtNextLine(ctx, function(lines)
      lines.start = currentLine()
      CommKit:ForAddon("")
    end, "CommKit:ForAddon addonName must be a non-empty string")
    expectErrorAtNextLine(ctx, function(lines)
      lines.start = currentLine()
      scope:SyncSet(PREFIX.sync, { fields = {} })
    end, "CommKit.Scope:SyncSet options.fields must be an array of 1 to 32 field names")
    ctx:Expect(scope:GetRegistrationCount()):ToBe(0)
  end
)

-- commKit.secrets -------------------------------------------------------------------

local secrets = newSuite("secrets")

--- Why the secrets tests are skipped on a client without the two functions.
local SECRETS_SKIP_REASON =
  "the client has no issecretvalue and secretwrap; the secret path was not exercised"

---Register `body` as a test when the client can make a secret value (and,
---with `needsCodecKit`, the bundle carries CodecKit), and as a skipped test
---naming why otherwise.
---@param name string
---@param body fun(ctx: TestKit.Context)
---@param needsCodecKit boolean|nil
local function secretTest(name, body, needsCodecKit)
  if not SECRETS_AVAILABLE then
    secrets:Skip(name, SECRETS_SKIP_REASON)
  elseif needsCodecKit and not CODEC_KIT_AVAILABLE then
    secrets:Skip(name, "the MoltenCodes addon carries no CodecKit API 1, which a SyncSet requires")
  else
    secrets:Test(name, body)
  end
end

---A genuine secret value made by the client's `secretwrap`, or a failed test.
---
---`secretwrap` is documented in the client's own API documentation
---(`Blizzard_APIDocumentationGenerated`); it wraps a plain value into a secret
---without touching any game state, so calling it has no side effect. A secret
---is only ever checked with `issecretvalue` and `type`: comparing it with a
---value of its own type raises.
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
  "Send refuses a secret prefix, text, distribution, target and priority at the calling line, before comparing them, and queues nothing",
  function(ctx)
    local fullName = requirePlayerNames(ctx)
    local scope = newCommScope()
    local messagesBefore = CommKit:GetQueueDepth()
    local base = { prefix = PREFIX.short, text = "x", distribution = "WHISPER", target = fullName }
    local cases = {
      {
        field = "prefix",
        value = PREFIX.short,
        expected = "CommKit.Scope:Send request.prefix must not be a secret value",
      },
      {
        field = "text",
        value = "x",
        expected = "CommKit.Scope:Send request.text must not be a secret value",
      },
      {
        field = "distribution",
        value = "WHISPER",
        expected = "CommKit.Scope:Send request.distribution must not be a secret value",
      },
      {
        field = "target",
        value = fullName,
        expected = "CommKit.Scope:Send request.target must not be a secret value",
      },
      {
        field = "priority",
        value = "BULK",
        expected = "CommKit.Scope:Send request.priority must be CommKit.Priority.ALERT, NORMAL or BULK",
      },
    }
    for _, case in ipairs(cases) do
      local request = {}
      for key, value in pairs(base) do
        request[key] = value
      end
      request[case.field] = makeSecret(ctx, case.value)
      expectErrorAtNextLine(ctx, function(lines)
        lines.start = currentLine()
        scope:Send(request)
      end, case.expected)
    end
    ctx:Expect(scope:GetPendingCount()):ToBe(0)
    ctx:Expect((CommKit:GetQueueDepth())):ToBe(messagesBefore)
  end
)

secretTest(
  "Register refuses a secret prefix and SetLimits a secret limit at the calling line, changing nothing",
  function(ctx)
    local scope = newCommScope()
    local limitsBefore = CommKit:GetLimits()
    local secretPrefix = makeSecret(ctx, PREFIX.short)
    local secretLimit = makeSecret(ctx, 900)
    expectErrorAtNextLine(ctx, function(lines)
      lines.start = currentLine()
      scope:Register(secretPrefix, function() end)
    end, "CommKit.Scope:Register prefix must not be a secret value")
    expectErrorAtNextLine(ctx, function(lines)
      lines.start = currentLine()
      CommKit:SetLimits({ maxCps = secretLimit })
    end, "CommKit:SetLimits limits.maxCps must not be a secret value")
    ctx:Expect(scope:GetRegistrationCount()):ToBe(0)
    ctx:Expect(CommKit:GetLimits()):ToEqual(limitsBefore)
  end
)

secretTest(
  "a secret facade receiver, a secret ForAddon name and a secret maxRegistrations are refused at the calling line",
  function(ctx)
    ---@type any
    local untypedCommKit = CommKit
    local secretReceiver = makeSecret(ctx, 1)
    local secretName = makeSecret(ctx, addonName)
    local secretBound = makeSecret(ctx, 4)
    expectErrorAtNextLine(
      ctx,
      function(lines)
        lines.start = currentLine()
        untypedCommKit.GetQueueDepth(secretReceiver)
      end,
      "CommKit:GetQueueDepth must be called on the CommKit facade; use CommKit:GetQueueDepth(...)"
    )
    expectErrorAtNextLine(ctx, function(lines)
      lines.start = currentLine()
      CommKit:ForAddon(secretName)
    end, "CommKit:ForAddon addonName must be a non-empty string")
    expectErrorAtNextLine(ctx, function(lines)
      lines.start = currentLine()
      CommKit:CreateScope({ maxRegistrations = secretBound })
    end, "CommKit:CreateScope options.maxRegistrations must not be a secret value")
    ctx:Expect(CommKit:ForAddon(addonName):IsClosed()):ToBe(false)
  end
)

secretTest(
  "SyncSet:Set refuses a secret value and a table holding one at the calling line",
  function(ctx)
    local scope = newCommScope()
    local sync = scope:SyncSet(PREFIX.sync, { fields = { "name", "talents" } })
    if type(sync) == "nil" then
      ctx:Fail("SyncSet was refused")
      return
    end
    local secretValue = makeSecret(ctx, "secret name")
    local holding = { makeSecret(ctx, 5) }
    expectErrorAtNextLine(ctx, function(lines)
      lines.start = currentLine()
      sync:Set("name", secretValue)
    end, "CommKit.SyncSet:Set value must not be a secret value")
    expectErrorAtNextLine(ctx, function(lines)
      lines.start = currentLine()
      sync:Set("talents", holding)
    end, "CommKit.SyncSet:Set value must not contain a secret value")
    ctx:Expect(sync:Get("name")):ToBeNil()
    ctx:Expect(sync:Get("talents")):ToBeNil()
  end,
  true
)

secrets:Skip(
  "a received message whose prefix, text, channel or sender is secret is dropped and counted in secretsDropped",
  "not producible solo: the client hands addon messages over as secrets only in restricted contexts such as encounters; packages/commKit/tests/Reassembly_spec.lua covers the drop"
)
