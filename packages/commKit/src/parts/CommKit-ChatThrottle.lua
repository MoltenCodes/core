-- MoltenCodes CommKit part ChatThrottle
--
-- The other senders ChatThrottleLib throttles beside addon messages, through
-- CommKit's one shared bandwidth budget, its priorities and its send states:
--
--   scope:SendChat(request)            a chat line (`C_ChatInfo.SendChatMessage`)
--   scope:SendBattleNet(request)       a message of any length to a Battle.net
--                                      game account (`C_BattleNet.SendGameData`),
--                                      framed and chunked as `scope:Send` frames it
--   scope:RegisterBattleNet(prefix, cb) whole Battle.net messages received
--                                      through `BN_CHAT_MSG_ADDON`
--
-- Facts this file relies on, and where they were read (2026-11-15):
--
--   * `C_ChatInfo.SendChatMessage(message, chatType?, languageID?, target?)`
--     returns nothing, has restrictions and the flag
--     `RestrictedForMacroChatMessages`, and on Retail its secret arguments are
--     `AllowedWhenUntainted` (Blizzard_APIDocumentationGenerated,
--     ChatInfoDocumentation.lua; Gethe/wow-ui-source live 297d7aa, classic
--     e5d9b3a, classic_era 4192ac6).
--   * SAY and YELL need a hardware event in the outdoor world, CHANNEL indoors
--     and outdoors; no other chat type does (warcraft.wiki.gg,
--     API_C_ChatInfo.SendChatMessage). CommKit cannot tell indoors from
--     outdoors, so it treats all three as needing one everywhere.
--   * The chat edit box holds at most 255 visible bytes (ChatFrameEditBox.xml,
--     `visibleBytes="255"`, on all three branches above). The API's own limit
--     is not documented; 255 is the bound used here.
--   * `C_BattleNet.SendGameData(gameAccountID, prefix, data)` returns an
--     `Enum.SendAddonMessageResult` (BattleNetDocumentation.lua, all three
--     branches); `BN_CHAT_MSG_ADDON(prefix, text, channel, senderID)`
--     (ChatInfoDocumentation.lua). The largest `data` it accepts is not
--     documented anywhere read: CommKit's 255-byte addon-message chunks are
--     used, with a client check in the client suite.
--
-- This part needs CommKit's core loaded first (revision 11 or later, part
-- interface 1). It reads everything it needs from the core through
-- `_state.helpers` at call time; its own state is `_state.parts.ChatThrottle`.
--
-- Contents
-- --------
--   Constants ........ identity, chat types, keys, option fields
--   Dependencies ..... CommKit's core, its state and helpers
--   Senders .......... the two client calls the driver makes for this part
--   Battle.net ....... registration keys, receiving, the outside hook
--   Requests ......... SendChat and SendBattleNet validation
--   Send paths ....... the queued path and the hardware-event path
--   Scope methods .... SendChat, SendBattleNet, RegisterBattleNet
--   Commit ........... members, senders, hooks and the part's revision

-- Constants ------------------------------------------------------------------

local PART_NAME = "ChatThrottle"
local PART_REVISION = 1
-- The generation of the core's `_state.helpers` this file is written against.
local REQUIRED_PART_INTERFACE = 1
local REQUIRED_REGISTRY_API = 2
local CORE_PACKAGE, CORE_API = "commKit", 1

-- Chat types that need a hardware event; a send of one is never queued.
local HARDWARE_EVENT_TYPES = { SAY = true, YELL = true, CHANNEL = true }

-- The most bytes one chat line carries (the chat edit box's `visibleBytes`).
local MAX_CHAT_BYTES = 255

-- CommKit's bound on a prefix, and the text one chunk carries: a message of
-- at most `SINGLE_PAYLOAD_BYTES` is one chunk, a longer one is cut into
-- `CHUNK_PAYLOAD_BYTES` pieces (CommKit's `WIRE`, "Wire protocol" in API.md).
local MAX_PREFIX_BYTES = 16
local SINGLE_PAYLOAD_BYTES = 254
local CHUNK_PAYLOAD_BYTES = 251

-- The distribution Battle.net messages are queued and reassembled under. The
-- event's own `channel` argument is not used for it: its values are not
-- documented, and a group distribution would let roster changes evict a
-- Battle.net stream.
local BATTLE_NET_DISTRIBUTION = "BATTLE_NET"

-- Registration and sender keys of Battle.net traffic. A realm prefix is at
-- most 16 bytes, so a key padded past that can never collide with one; the
-- sender key carries the game account as decimal digits after a NUL, which no
-- realm player name holds.
local BATTLE_NET_KEY_PAD = string.rep("\0", MAX_PREFIX_BYTES + 1) .. "battleNet"
local BATTLE_NET_SENDER_PREFIX = "\0battleNet\0"

local PRIORITY = { ALERT = "ALERT", NORMAL = "NORMAL", BULK = "BULK" }

local OPTION_KEYS = {
  sendChat = {
    text = true,
    chatType = true,
    languageID = true,
    target = true,
    priority = true,
    onComplete = true,
  },
  sendBattleNet = {
    prefix = true,
    text = true,
    gameAccountID = true,
    priority = true,
    onProgress = true,
    onComplete = true,
  },
}

-- Dependencies ---------------------------------------------------------------

local CommKit = nil
do
  -- The shared MoltenCodes namespace is the one documented global handoff point between independently embedded copies.
  -- selene: allow(global_usage)
  local namespace = rawget(_G, "MoltenCodes")
  local generations = type(namespace) == "table" and rawget(namespace, "Registries") or nil
  local Registry = type(generations) == "table" and rawget(generations, REQUIRED_REGISTRY_API)
    or nil
  local find = type(Registry) == "table" and rawget(Registry, "Find") or nil
  if type(find) == "function" then
    CommKit = find(Registry, CORE_PACKAGE, CORE_API)
  end
end
local state = type(CommKit) == "table" and rawget(CommKit, "_state") or nil
if
  type(state) ~= "table"
  or type(rawget(state, "parts")) ~= "table"
  or type(rawget(state, "helpers")) ~= "table"
  or type(rawget(state, "transports")) ~= "table"
  or type(rawget(state, "partInterface")) ~= "number"
  or rawget(state, "partInterface") < REQUIRED_PART_INTERFACE
then
  error("MoltenCodes CommKit part ChatThrottle requires CommKit API 1 to be loaded first", 2)
end
---@cast CommKit table

local parts = rawget(state, "parts")
local installed = rawget(parts, PART_NAME)
if
  type(installed) == "table"
  and type(installed.revision) == "number"
  and installed.revision >= PART_REVISION
then
  -- An equal or newer revision of this part already serves every scope.
  return CommKit
end

-- Read at call time, never copied: an upgraded core's helpers serve this part.
local helpers = rawget(state, "helpers")
local limits = rawget(state, "limits")
local dispatch = rawget(state, "dispatch")
local trampolines = rawget(state, "trampolines")
local metatables = rawget(state, "metatables")
local budget = rawget(state, "budget")
local statistics = rawget(state, "statistics")
local driver = rawget(state, "driver")

-- The part's own state, kept across an upgrade of the part.
local partState = type(installed) == "table" and installed or {}
if partState.battleNetConnection == nil then
  partState.battleNetConnection = false
end

---The client's Battle.net game-data sender, or `nil`.
---@return function|nil
local function readSendGameData()
  local battleNet = helpers.battleNetApi()
  if battleNet == nil then
    return nil
  end
  return battleNet.SendGameData
end

-- Senders --------------------------------------------------------------------
--
-- The driver calls these with the queue record and the chunk to send, inside
-- its own-traffic flag (`transmit`). Each reads the client function per call,
-- so one another addon replaces is used from the next chunk, and answers what
-- the client answered: nothing for a chat line (sent), a
-- `SendAddonMessageResult` for Battle.net, or `false` (failed) when the
-- function is gone.

---@param record table
---@param chunk string
---@return any result
local function sendChatChunk(record, chunk)
  local send = helpers.chatSender()
  if send == nil then
    return false
  end
  return send(chunk, record.distribution, record.language, record.target)
end

---@param record table
---@param chunk string
---@return any result
local function sendBattleNetChunk(record, chunk)
  local sendGameData = readSendGameData()
  if sendGameData == nil then
    return false
  end
  return sendGameData(record.target, record.prefix, chunk)
end

-- Battle.net -------------------------------------------------------------------

---The registration key of a Battle.net prefix: never a realm prefix.
---@param prefix string
---@return string
local function battleNetKey(prefix)
  return prefix .. BATTLE_NET_KEY_PAD
end

---`BN_CHAT_MSG_ADDON`: hand a chunk to the core's reassembly under the
---prefix's Battle.net key and a sender key of its own, on the logged channel's
---printable digit scheme `SendBattleNet` writes. Received data is untrusted:
---a wrong type is ignored and a secret is counted and dropped, as on the
---realm channels.
---@param prefix any
---@param text any
---@param senderID any
local function onBattleNetMessage(prefix, text, senderID)
  if type(prefix) ~= "string" or type(text) ~= "string" or type(senderID) ~= "number" then
    return
  end
  if helpers.isSecret(prefix) or helpers.isSecret(text) or helpers.isSecret(senderID) then
    helpers.count("secretsDropped")
    return
  end
  rawget(dispatch, "onAddonMessage")(
    battleNetKey(prefix),
    text,
    BATTLE_NET_DISTRIBUTION,
    BATTLE_NET_SENDER_PREFIX .. string.format("%d", senderID),
    true
  )
end

---Listen to `BN_CHAT_MSG_ADDON` from the first Battle.net registration on. The
---connection lives in CommKit's EventKit scope and is made again if that
---scope was replaced.
local function connectBattleNetEvent()
  local connection = partState.battleNetConnection
  if connection ~= false and connection:IsConnected() then
    return
  end
  partState.battleNetConnection =
    helpers.getEventScope():Connect("BN_CHAT_MSG_ADDON", rawget(trampolines, "battleNetMessage"))
end

---Secure-hook `C_BattleNet.SendGameData` in CommKit's outside-traffic HookKit
---scope, so another addon's Battle.net traffic is charged to the budget.
---@param hookScope table
local function installBattleNetHook(hookScope)
  local battleNet = helpers.battleNetApi()
  if battleNet == nil then
    return
  end
  pcall(
    hookScope.SecureHook,
    hookScope,
    battleNet,
    "SendGameData",
    rawget(trampolines, "outsideBattleNet")
  )
end

-- Requests -------------------------------------------------------------------

---Validate the `priority` of a request.
---@param priority any
---@param label string
---@param level integer
---@return string
local function readPriority(priority, label, level)
  if type(priority) == "nil" then
    return PRIORITY.NORMAL
  end
  if type(priority) ~= "string" or helpers.isSecret(priority) or PRIORITY[priority] ~= priority then
    error(label .. ".priority must be CommKit.Priority.ALERT, NORMAL or BULK", level)
  end
  return priority
end

---Refuse a field that holds a secret value, at the caller's line.
---@param value any
---@param label string
---@param level integer
local function refuseSecret(value, label, level)
  if helpers.isSecret(value) then
    error(label .. " must not be a secret value", level)
  end
end

---Validate a `scope:SendChat` request, raising at the caller for a
---programming error.
---@param request any
---@param level integer
---@return string text, string chatType, number|nil languageID, string|number|nil target, string priority, function|false onComplete
local function readChatRequest(request, level)
  local label = "CommKit.Scope:SendChat request"
  if type(request) ~= "table" then
    error(label .. " must be a table", level)
  end
  helpers.validateKeys(request, OPTION_KEYS.sendChat, label, level + 1)

  local text = rawget(request, "text")
  if type(text) ~= "string" then
    error(label .. ".text must be a string", level)
  end
  refuseSecret(text, label .. ".text", level + 1)

  local chatType = rawget(request, "chatType")
  if type(chatType) ~= "string" then
    error(label .. ".chatType must be a non-empty string", level)
  end
  refuseSecret(chatType, label .. ".chatType", level + 1)
  if chatType == "" then
    error(label .. ".chatType must be a non-empty string", level)
  end

  local languageID = rawget(request, "languageID")
  if type(languageID) ~= "nil" then
    if type(languageID) ~= "number" then
      error(label .. ".languageID must be a number or nil", level)
    end
    refuseSecret(languageID, label .. ".languageID", level + 1)
  end

  local target = rawget(request, "target")
  local targetType = type(target)
  if targetType ~= "nil" and targetType ~= "string" and targetType ~= "number" then
    error(label .. ".target must be a string, a number or nil", level)
  end
  if targetType ~= "nil" then
    refuseSecret(target, label .. ".target", level + 1)
  end

  local priority = readPriority(rawget(request, "priority"), label, level + 1)
  local onComplete = rawget(request, "onComplete")
  helpers.validateOptionalCallback(onComplete, label .. ".onComplete", level + 1)
  return text, chatType, languageID, target, priority, onComplete or false
end

---Validate a `scope:SendBattleNet` request, raising at the caller for a
---programming error.
---@param request any
---@param level integer
---@return string prefix, string text, integer gameAccountID, string priority, function|false onProgress, function|false onComplete
local function readBattleNetRequest(request, level)
  local label = "CommKit.Scope:SendBattleNet request"
  if type(request) ~= "table" then
    error(label .. " must be a table", level)
  end
  helpers.validateKeys(request, OPTION_KEYS.sendBattleNet, label, level + 1)

  local prefix = rawget(request, "prefix")
  helpers.validateBoundedString(prefix, label .. ".prefix", MAX_PREFIX_BYTES, level + 1)

  local text = rawget(request, "text")
  if type(text) ~= "string" then
    error(label .. ".text must be a string", level)
  end
  refuseSecret(text, label .. ".text", level + 1)

  local gameAccountID = rawget(request, "gameAccountID")
  if type(gameAccountID) ~= "number" then
    error(label .. ".gameAccountID must be a positive integer", level)
  end
  refuseSecret(gameAccountID, label .. ".gameAccountID", level + 1)
  if
    gameAccountID ~= gameAccountID
    or gameAccountID < 1
    or gameAccountID == math.huge
    or gameAccountID ~= math.floor(gameAccountID)
  then
    error(label .. ".gameAccountID must be a positive integer", level)
  end

  local priority = readPriority(rawget(request, "priority"), label, level + 1)
  local onProgress = rawget(request, "onProgress")
  local onComplete = rawget(request, "onComplete")
  helpers.validateOptionalCallback(onProgress, label .. ".onProgress", level + 1)
  helpers.validateOptionalCallback(onComplete, label .. ".onComplete", level + 1)
  return prefix, text, gameAccountID, priority, onProgress or false, onComplete or false
end

-- Send paths -----------------------------------------------------------------
--
-- Chat lines and Battle.net game data join the same queue, bucket, rotation
-- and send states as addon messages, through a sender of their own
-- (`state.transports`), built from the core's queue and budget primitives.

---Queue a message a part built, and send it at once when the driver is idle,
---as `enqueueSend` does. `spec` holds what the record needs: `kind`
---(`"message"`, framed and chunked as `scope:Send` frames it, or `"raw"`,
---one part per client call), `transport`, `prefix`, `text` or `parts`,
---`textLength`, `distribution`, `target`, `language`, `priority`, `logged`
---(the digit scheme), `pipeKey`, `onProgress`, `onComplete`. Returns the
---handle, or `nil` and `"closed"`, `"tooLarge"` or `"queueFull"`.
---@param scope CommKit.Scope
---@param spec table
---@return CommKit.SendHandle|nil handle
---@return string|nil reason
local function enqueueTransport(scope, spec)
  if rawget(scope, "_closed") then
    return helpers.refuse("closed")
  end
  local length = spec.textLength
  local totalChunks = 1
  if spec.kind == "raw" then
    totalChunks = #spec.parts
  elseif length > SINGLE_PAYLOAD_BYTES then
    totalChunks = math.ceil(length / CHUNK_PAYLOAD_BYTES)
  end
  local maxQueuedBytes = rawget(limits, "maxQueuedBytes")
  if
    length > maxQueuedBytes
    or (
      spec.kind == "message"
      and totalChunks > 1
      and helpers.declaredBytes(totalChunks) > rawget(limits, "maxReassemblyBytesPerSender")
    )
  then
    return helpers.refuse("tooLarge")
  end
  if
    state.queuedMessages >= rawget(limits, "maxQueuedMessages")
    or state.queuedBytes + length > maxQueuedBytes
  then
    return helpers.refuse("queueFull")
  end

  local handle = setmetatable({
    _state = "queued",
    _bytesSent = 0,
    _bytesTotal = length,
    _record = false,
  }, rawget(metatables, "handle"))
  local record = helpers.acquireRecord()
  record.kind = spec.kind
  record.inFlight = false
  record.handle = handle
  record.scope = scope
  record.prefix = spec.prefix
  record.text = spec.text or false
  record.parts = spec.parts or false
  record.textLength = length
  record.distribution = spec.distribution
  record.target = spec.target
  record.language = spec.language
  record.priority = spec.priority
  record.logged = spec.logged == true
  record.transport = spec.transport
  record.pipeKey = spec.pipeKey
  record.totalChunks = totalChunks
  record.nextIndex = 1
  record.bytesSent = 0
  record.streamId = false
  record.onProgress = spec.onProgress or false
  record.onComplete = spec.onComplete or false
  rawset(handle, "_record", record)

  helpers.enqueueRecord(record)
  local pending = rawget(scope, "_pending")
  pending[#pending + 1] = handle
  helpers.count("messagesQueued")
  if not helpers.runInline() then
    helpers.wakeDriver()
  end
  return handle, nil
end

---Send one message outside the queue, now or not at all: what a chat line
---that needs the caller's hardware event takes (revision 11), since a queued
---send runs later, without it. The bucket is refilled and must pay for the
---message now (the driver's rule), then `call()` makes the client call, with
---CommKit's own-traffic flag set so the hook does not charge it twice.
---Returns a terminal handle, or `nil` and `"closed"` or `"hardwareEvent"`.
---The completion callback is held for the next driver run, so none runs
---before the caller's call returns.
---@param scope CommKit.Scope
---@param cost integer what the message costs the bucket
---@param bytes integer the bytes the message carries
---@param call fun(): any the client call
---@param onComplete function|false
---@return CommKit.SendHandle|nil handle
---@return string|nil reason
local function sendOutsideQueue(scope, cost, bytes, call, onComplete)
  if rawget(scope, "_closed") then
    return helpers.refuse("closed")
  end
  local currentTime = helpers.sampleFrameRate(true)
  helpers.installOutsideHooks(currentTime)
  helpers.refill(currentTime)
  local _, capacity = helpers.currentMode(currentTime)
  if (cost < capacity and cost or capacity) - budget.tokens >= 1 then
    return nil, "hardwareEvent"
  end
  state.sendingOwnTraffic = true
  local ok, failure = pcall(call)
  state.sendingOwnTraffic = false
  helpers.count("messagesQueued")
  local terminalState, reason = "sent", nil
  if ok then
    budget.tokens = budget.tokens - cost
    statistics.chunksSent = statistics.chunksSent + 1
    statistics.bytesSent = statistics.bytesSent + bytes
  else
    helpers.reportError(failure)
    terminalState, reason = "failed", "error"
  end
  helpers.count(terminalState == "sent" and "messagesSent" or "messagesFailed")
  local handle = setmetatable({
    _state = terminalState,
    _bytesSent = ok and bytes or 0,
    _bytesTotal = bytes,
    _record = false,
  }, rawget(metatables, "handle"))
  if onComplete ~= false then
    local wasInline = driver.inline
    driver.inline = true
    helpers.deferCallback(onComplete, handle, terminalState, reason)
    driver.inline = wasInline
    if driver.job == false then
      driver.job = helpers.armDriverRun("ready", 0)
      driver.delayed = state.queuedMessages == 0 and "callbacks" or false
    end
  end
  return handle, nil
end

-- Scope methods --------------------------------------------------------------

local ScopeMethods = {}

---Send a chat line through the shared budget. SAY, YELL and CHANNEL need the
---caller's hardware event, so they leave inside this call when the budget can
---pay for them, or are refused with `"hardwareEvent"`; they are never queued.
---Every other chat type is queued like an addon message.
---@param self CommKit.Scope
---@param request table
---@return CommKit.SendHandle|nil handle
---@return string|nil reason
function ScopeMethods.SendChat(self, request)
  helpers.validateScope(self, "CommKit.Scope:SendChat", 3)
  local text, chatType, languageID, target, priority, onComplete = readChatRequest(request, 3)
  if rawget(self, "_closed") then
    return helpers.refuse("closed")
  end
  if not helpers.targetFits(chatType, target) then
    return helpers.refuse("badDistribution")
  end
  if chatType ~= "WHISPER" and chatType ~= "CHANNEL" then
    target = nil
  end
  if string.find(text, "\0", 1, true) ~= nil then
    return helpers.refuse("nulByte")
  end
  local length = #text
  if length > MAX_CHAT_BYTES then
    return helpers.refuse("tooLarge")
  end
  local send = helpers.chatSender()
  if send == nil then
    return helpers.refuse("unavailable")
  end

  if HARDWARE_EVENT_TYPES[string.upper(chatType)] then
    local cost = length + rawget(limits, "messageOverhead")
    local handle, reason = sendOutsideQueue(self, cost, length, function()
      send(text, chatType, languageID, target)
    end, onComplete)
    return handle, reason
  end

  local targetText = type(target) ~= "nil" and tostring(target) or ""
  local languageText = type(languageID) ~= "nil" and tostring(languageID) or ""
  local handle, reason = enqueueTransport(self, {
    kind = "raw",
    transport = "chat",
    prefix = "",
    parts = { text },
    textLength = length,
    distribution = chatType,
    target = target,
    language = languageID,
    priority = priority,
    logged = false,
    pipeKey = "chat\t" .. chatType .. "\t" .. targetText .. "\t" .. languageText,
    onComplete = onComplete,
  })
  return handle, reason
end

---Queue a message of any length to a Battle.net game account, framed and
---chunked as `scope:Send` frames a message, through the shared budget.
---@param self CommKit.Scope
---@param request table
---@return CommKit.SendHandle|nil handle
---@return string|nil reason
function ScopeMethods.SendBattleNet(self, request)
  helpers.validateScope(self, "CommKit.Scope:SendBattleNet", 3)
  local prefix, text, gameAccountID, priority, onProgress, onComplete =
    readBattleNetRequest(request, 3)
  if rawget(self, "_closed") then
    return helpers.refuse("closed")
  end
  -- The bytes `scope:Send` refuses: the client's addon channels cannot carry
  -- them, and nothing says Battle.net game data can.
  if
    string.find(text, "\0", 1, true) ~= nil
    or string.find(text, "\n", 1, true) ~= nil
    or string.find(text, "\r", 1, true) ~= nil
    or string.find(text, "|", 1, true) ~= nil
  then
    return helpers.refuse("forbiddenByte")
  end
  if readSendGameData() == nil then
    return helpers.refuse("unavailable")
  end
  local handle, reason = enqueueTransport(self, {
    kind = "message",
    transport = "battleNet",
    prefix = prefix,
    text = text,
    textLength = #text,
    distribution = BATTLE_NET_DISTRIBUTION,
    target = gameAccountID,
    priority = priority,
    -- The printable digit scheme: nothing says Battle.net carries bytes
    -- above 0x7F unchanged.
    logged = true,
    pipeKey = "battleNet\t" .. string.format("%d", gameAccountID),
    onProgress = onProgress,
    onComplete = onComplete,
  })
  return handle, reason
end

---Receive whole Battle.net messages on `prefix`: `callback(prefix, text,
---senderID)`, isolated like every receive callback. Counts toward the
---scope's `maxRegistrations` and is released with the scope.
---@param self CommKit.Scope
---@param prefix string
---@param callback fun(prefix: string, text: string, senderID: integer)
---@return CommKit.Connection|nil connection
---@return string|nil reason
function ScopeMethods.RegisterBattleNet(self, prefix, callback)
  helpers.validateScope(self, "CommKit.Scope:RegisterBattleNet", 3)
  helpers.validateBoundedString(
    prefix,
    "CommKit.Scope:RegisterBattleNet prefix",
    MAX_PREFIX_BYTES,
    3
  )
  helpers.validateCallback(callback, "CommKit.Scope:RegisterBattleNet callback", 3)
  local senderStart = #BATTLE_NET_SENDER_PREFIX + 1
  local connection, reason = helpers.registerInScope(
    self,
    battleNetKey(prefix),
    function(_, text, _, sender)
      callback(prefix, text, tonumber(string.sub(sender, senderStart)) --[[@as integer]])
    end,
    "framed",
    prefix
  )
  if connection == nil then
    return nil, reason
  end
  -- What `GetPrefix` answers: the prefix the caller registered, not the key.
  rawset(connection, "_publicPrefix", prefix)
  connectBattleNetEvent()
  return connection, nil
end

-- Commit ---------------------------------------------------------------------

local Scope = rawget(CommKit, "Scope")
for name, method in pairs(ScopeMethods) do
  rawset(Scope, name, method)
end

local transports = rawget(state, "transports")
rawset(transports, "chat", sendChatChunk)
rawset(transports, "battleNet", sendBattleNetChunk)

rawset(dispatch, "onBattleNetMessage", onBattleNetMessage)
rawset(dispatch, "chargeOutsideBattleNet", function(prefix, data)
  helpers.chargeOutsideAddon(prefix, data)
end)
rawset(dispatch, "installPartHooks", installBattleNetHook)
-- The trampolines are created once per session and only look up `dispatch`,
-- so a later revision of this part replaces what they call.
if rawget(trampolines, "battleNetMessage") == nil then
  rawset(trampolines, "battleNetMessage", function(_, prefix, text, _, senderID)
    rawget(dispatch, "onBattleNetMessage")(prefix, text, senderID)
  end)
end
if rawget(trampolines, "outsideBattleNet") == nil then
  rawset(trampolines, "outsideBattleNet", function(_, prefix, data)
    rawget(dispatch, "chargeOutsideBattleNet")(prefix, data)
  end)
end
-- The core installs its outside-traffic hooks on the first wake that finds
-- HookKit; when that already happened, this part's hook joins them now.
local hookScope = rawget(state, "outsideHooks")
if hookScope ~= false and type(hookScope) == "table" then
  installBattleNetHook(hookScope)
end

partState.revision = PART_REVISION
rawset(parts, PART_NAME, partState)

return CommKit
