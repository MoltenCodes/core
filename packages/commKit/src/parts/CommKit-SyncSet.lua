-- MoltenCodes CommKit part SyncSet
--
-- `scope:SyncSet(prefix, options)`: named fields synchronised with peers over
-- one prefix. Each field's version is a content hash; a request carries the
-- hashes the requester holds, and the answer carries only the fields whose
-- hash differs, or an ack. The protocol and its bounds are in CommKit's
-- `docs/API.md`, "SyncSet".
--
-- This part needs CommKit's core loaded first (revision 11 or later, part
-- interface 1) and CodecKit API 1 when a SyncSet is created; SchemaKit API 1
-- when a SyncSet declares `schema`. Everything it needs from the core it reads
-- through the core's `_state.helpers` at call time, so a newer core loaded
-- after this file serves it. Its state lives in the core's state: the SyncSet
-- prototype and metatable, the reply allowance (`syncReplyBytes`), the
-- `maxSyncPeers` and `maxSyncReplyBytes` limits and the `sync*` statistics
-- are the core's, whichever parts are loaded.
--
-- Contents
-- --------
--   Constants ........ identity, verbs, bounds, the hash constants
--   Dependencies ..... CommKit's core, its state and helpers
--   Content hashes ... FNV-1a over a canonical encoding
--   SyncSet .......... fields, request, ack, deliver
--   SyncSet methods .. the handle a SyncSet owner receives
--   Scope method ..... scope:SyncSet
--   Commit ........... members, the receive hook and the part's revision

-- Constants ------------------------------------------------------------------

local PART_NAME = "SyncSet"
local PART_REVISION = 1
-- The generation of the core's `_state.helpers` this file is written against.
local REQUIRED_PART_INTERFACE = 1
local REQUIRED_REGISTRY_API = 2
local CORE_PACKAGE, CORE_API = "commKit", 1

local DEPENDENCY_API = { codecKit = 1, schemaKit = 1 }
local LAYOUT = { connection = 1, syncSet = 1 }
local REASON = { closed = "closed", schema = "schema", unavailable = "unavailable", full = "full" }
local SEND_STATE = { queued = "queued", sending = "sending" }
local PRIORITY = { NORMAL = "NORMAL" }
-- CommKit's bound on a prefix (its `MAX_PREFIX_BYTES`).
local MAX_PREFIX_BYTES = 16
local OPTION_KEYS = { syncSet = { fields = true, schema = true, maxListeners = true } }

-- SyncSet verbs (the first element of every SyncSet message) and bounds.
local SYNC = {
  request = 1,
  ack = 2,
  deliver = 3,
  -- Hard ceilings: a SyncSet's field list is a static declaration every
  -- peer running the addon shares, and a request carries one hash per
  -- field, so the list stays short enough for a request and a full delivery
  -- to fit the shared reply allowance.
  maxFields = 32,
  maxFieldNameBytes = 64,
  -- `OnChanged` listeners per SyncSet unless `maxListeners` says otherwise.
  defaultMaxListeners = 16,
  replyIntervalSeconds = 1,
  -- CodecKit options for SyncSet frames.
  codecOptions = { channel = "addon" },
}

-- FNV-1a, 32 bits. The prime 16777619 is 2^24 + 403, which is what lets the
-- multiplication modulo 2^32 stay exact in double arithmetic.
local FNV = {
  offsetBasis = 2166136261,
  primeLow = 403,
  twoPow24 = 16777216,
  twoPow32 = 4294967296,
  -- The canonical encoding brackets a table with two bytes CodecKit's
  -- serialiser never uses as type bytes.
  canonicalOpen = string.char(0x0C),
  canonicalClose = string.char(0x0D),
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
  or type(rawget(state, "partInterface")) ~= "number"
  or rawget(state, "partInterface") < REQUIRED_PART_INTERFACE
then
  error("MoltenCodes CommKit part SyncSet requires CommKit API 1 to be loaded first", 2)
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
local metatables = rawget(state, "metatables")
local SYNC_SET_METATABLE = rawget(metatables, "syncSet")
local CONNECTION_METATABLE = rawget(metatables, "connection")

local SyncSetMethods = {}
local ScopeMethods = {}

-- Content hashes -------------------------------------------------------------
--
-- A SyncSet field's version is the 32-bit FNV-1a hash of a canonical encoding
-- of its value: a scalar is CodecKit's serialisation of it (the writer is
-- canonical for scalars), and a table is the byte 0x0C, then every key and
-- value in sorted key order, each encoded the same way, then 0x0D. Keys sort
-- by type (booleans, then numbers, then strings), then by value, strings
-- byte by byte. Tables as keys are refused. `docs/API.md` has test vectors.
--
-- Lua 5.1 has no bit operations, so the hash is arithmetic on doubles: the
-- exclusive or touches only the low byte, and the multiplication by
-- 16777619 = 2^24 + 403 is split so every intermediate stays below 2^53.

-- Only `hashValue` is used outside this block.
local hashValue

do
  ---The exclusive or of two bytes.
  ---@param left integer
  ---@param right integer
  ---@return integer
  local function xorByte(left, right)
    local result = 0
    local bitValue = 1
    for _ = 1, 8 do
      local leftBit = left % 2
      local rightBit = right % 2
      if leftBit ~= rightBit then
        result = result + bitValue
      end
      left = (left - leftBit) / 2
      right = (right - rightBit) / 2
      bitValue = bitValue * 2
    end
    return result
  end

  ---Feed `bytes` into an FNV-1a hash.
  ---@param hash integer
  ---@param bytes string
  ---@return integer
  local function fnvUpdate(hash, bytes)
    for index = 1, #bytes do
      local low = hash % 256
      hash = hash - low + xorByte(low, string.byte(bytes, index))
      hash = ((hash % 256) * FNV.twoPow24 + hash * FNV.primeLow) % FNV.twoPow32
    end
    return hash
  end

  -- Sort rank of each key type in the canonical encoding.
  local KEY_TYPE_RANK = { boolean = 1, number = 2, string = 3 }

  ---Whether string `left` sorts before `right`, byte by byte. `<` on strings
  ---follows the C library's collation, which is not the same on every client.
  ---@param left string
  ---@param right string
  ---@return boolean
  local function stringBefore(left, right)
    local leftLength, rightLength = #left, #right
    for index = 1, math.min(leftLength, rightLength) do
      local leftByte, rightByte = string.byte(left, index), string.byte(right, index)
      if leftByte ~= rightByte then
        return leftByte < rightByte
      end
    end
    return leftLength < rightLength
  end

  ---The canonical order of two table keys.
  ---@param left any
  ---@param right any
  ---@return boolean
  local function keyBefore(left, right)
    local leftRank, rightRank = KEY_TYPE_RANK[type(left)], KEY_TYPE_RANK[type(right)]
    if leftRank ~= rightRank then
      return leftRank < rightRank
    end
    if leftRank == 1 then
      return left == false and right == true
    end
    if leftRank == 2 then
      return left < right
    end
    return stringBefore(left, right)
  end

  ---Hash the canonical encoding of `value` into `hash`.
  ---@param codec table CodecKit
  ---@param value any a value CodecKit already serialised successfully
  ---@param hash integer
  ---@return integer|nil hash
  ---@return string|nil reason
  local function hashCanonical(codec, value, hash)
    if type(value) ~= "table" then
      local _, bytes = codec:Serialize(value)
      return fnvUpdate(hash, bytes), nil
    end

    local keys = {}
    for key in pairs(value) do
      if KEY_TYPE_RANK[type(key)] == nil then
        return nil, "tableKey"
      end
      keys[#keys + 1] = key
    end
    table.sort(keys, keyBefore)

    hash = fnvUpdate(hash, FNV.canonicalOpen)
    for index = 1, #keys do
      local key = keys[index]
      local keyHash, keyReason = hashCanonical(codec, key, hash)
      if keyHash == nil then
        return nil, keyReason
      end
      local valueHash, valueReason = hashCanonical(codec, value[key], keyHash)
      if valueHash == nil then
        return nil, valueReason
      end
      hash = valueHash
    end
    return fnvUpdate(hash, FNV.canonicalClose), nil
  end

  ---The content hash of `value`, or `nil` and CodecKit's reason when it cannot
  ---be serialised (a cycle, a function, a limit), or `"tableKey"`.
  ---@param codec table CodecKit
  ---@param value any
  ---@return integer|nil hash
  ---@return string|nil reason
  function hashValue(codec, value)
    local ok, bytesOrReason = codec:Serialize(value)
    if not ok then
      return nil, bytesOrReason
    end
    local hash, reason = hashCanonical(codec, value, FNV.offsetBasis)
    return hash, reason
  end
end

-- SyncSet --------------------------------------------------------------------
--
-- A SyncSet holds this client's values for a fixed list of fields and a
-- bounded cache of the values peers delivered. The three verbs travel as
-- CodecKit frames for the addon channel, sent and received through the
-- SyncSet's own registration:
--
--   request   { 1, hashes }             the requester's hashes of our fields
--   ack       { 2 }                     every hash matched
--   deliver   { 3, values, removed }    only the fields whose hash differs

-- Only `encodeSyncMessage` and `receiveSync` are used outside this block.
local encodeSyncMessage, receiveSync

do
  ---Whether a reply to `peer` is still in the queue.
  ---@param peer table
  ---@return boolean
  local function replyPending(peer)
    local reply = rawget(peer, "reply")
    if reply == false then
      return false
    end
    local replyState = rawget(reply, "_state")
    return replyState == SEND_STATE.queued or replyState == SEND_STATE.sending
  end

  ---Return the peer record for `sender`, creating it when `create` is true.
  ---When the cache is full, the least recently seen peer that was not
  ---answered within the reply interval and has no reply in the queue is
  ---evicted; when every peer was, `nil` is returned, so an eviction can never
  ---lift a peer's reply interval or let it queue a second reply.
  ---@param syncSet CommKit.SyncSet
  ---@param sender string
  ---@param create boolean
  ---@return table|nil
  local function obtainPeer(syncSet, sender, create)
    local peers = rawget(syncSet, "_peers")
    local touch = rawget(syncSet, "_touch") + 1
    rawset(syncSet, "_touch", touch)
    local peer = rawget(peers, sender)
    if peer ~= nil then
      rawset(peer, "touched", touch)
      return peer
    end
    if not create then
      return nil
    end

    -- A loop rather than one eviction, so a cache above a bound `SetLimits`
    -- lowered shrinks back to it.
    while rawget(syncSet, "_peerCount") >= rawget(limits, "maxSyncPeers") do
      local currentTime = helpers.now()
      local oldestName, oldestTouch = nil, nil
      for name, candidate in pairs(peers) do
        local touched = rawget(candidate, "touched")
        local repliedAt = rawget(candidate, "repliedAt")
        local throttled = repliedAt ~= false and currentTime - repliedAt < SYNC.replyIntervalSeconds
        if
          not throttled
          and not replyPending(candidate)
          and (oldestTouch == nil or touched < oldestTouch)
        then
          oldestName, oldestTouch = name, touched
        end
      end
      if oldestName == nil then
        return nil
      end
      rawset(peers, oldestName, nil)
      rawset(syncSet, "_peerCount", rawget(syncSet, "_peerCount") - 1)
    end
    peer = { values = {}, hashes = {}, touched = touch, repliedAt = false, reply = false }
    rawset(peers, sender, peer)
    rawset(syncSet, "_peerCount", rawget(syncSet, "_peerCount") + 1)
    return peer
  end

  ---Encode a SyncSet message, or `nil` when CodecKit is gone or refuses it.
  ---@param message table
  ---@return string|nil
  function encodeSyncMessage(message)
    local codec = helpers.findOptional("codecKit", DEPENDENCY_API.codecKit)
    if codec == nil then
      return nil
    end
    local ok, text = codec:Encode(message, SYNC.codecOptions)
    if not ok then
      return nil
    end
    return text
  end

  ---Queue a reply to `sender`, counting its bytes against the shared reply
  ---allowance until it is terminal.
  ---@param syncSet CommKit.SyncSet
  ---@param peer table
  ---@param sender string
  ---@param text string
  local function queueReply(syncSet, peer, sender, text)
    local length = #text
    if rawget(state, "syncReplyBytes") + length > rawget(limits, "maxSyncReplyBytes") then
      helpers.count("syncReplyDropped")
      return
    end
    local handle
    handle = helpers.enqueueSend(
      rawget(syncSet, "_scope"),
      rawget(syncSet, "_prefix"),
      text,
      "WHISPER",
      sender,
      PRIORITY.NORMAL,
      false,
      false,
      function()
        rawset(state, "syncReplyBytes", rawget(state, "syncReplyBytes") - length)
        if rawget(peer, "reply") == handle then
          rawset(peer, "reply", false)
        end
      end
    )
    if handle == nil then
      helpers.count("syncReplyDropped")
      return
    end
    rawset(state, "syncReplyBytes", rawget(state, "syncReplyBytes") + length)
    rawset(peer, "reply", handle)
  end

  ---Answer a request with an ack or a delta. Requests are answered only when
  ---whispered, at most once a second per peer, with at most one reply per
  ---peer in the queue and at most 8 KB of replies queued in all.
  ---@param syncSet CommKit.SyncSet
  ---@param claimed any the requester's hashes
  ---@param sender string
  ---@param distribution string
  local function answerRequest(syncSet, claimed, sender, distribution)
    if type(claimed) ~= "table" or distribution ~= "WHISPER" then
      helpers.count("syncRejected")
      return
    end
    helpers.count("syncRequests")
    local peer = obtainPeer(syncSet, sender, true)
    if peer == nil then
      helpers.count("syncReplyDropped")
      return
    end
    local currentTime = helpers.now()
    local repliedAt = rawget(peer, "repliedAt")
    if repliedAt ~= false and currentTime - repliedAt < SYNC.replyIntervalSeconds then
      helpers.count("syncRejected")
      return
    end
    if replyPending(peer) then
      helpers.count("syncReplyDropped")
      return
    end
    rawset(peer, "repliedAt", currentTime)

    local ownValues = rawget(syncSet, "_values")
    local ownHashes = rawget(syncSet, "_hashes")
    local fieldList = rawget(syncSet, "_fieldList")
    local values, removed = {}, {}
    local differs = false
    for index = 1, #fieldList do
      local field = fieldList[index]
      local mine = rawget(ownHashes, field)
      local theirs = rawget(claimed, field)
      if mine ~= nil and mine ~= theirs then
        values[field] = rawget(ownValues, field)
        differs = true
      elseif mine == nil and type(theirs) ~= "nil" then
        removed[#removed + 1] = field
        differs = true
      end
    end

    local text
    if differs then
      text = encodeSyncMessage({ SYNC.deliver, values, removed })
    else
      text = encodeSyncMessage({ SYNC.ack })
    end
    if text ~= nil then
      queueReply(syncSet, peer, sender, text)
    end
  end

  ---Store a delivered value when it passes the field's schema and differs.
  ---@param syncSet CommKit.SyncSet
  ---@param codec table CodecKit
  ---@param peer table
  ---@param sender string
  ---@param field string
  ---@param value any
  local function acceptDelivered(syncSet, codec, peer, sender, field, value)
    local schemas = rawget(syncSet, "_schemas")
    local schema = schemas ~= false and rawget(schemas, field) or nil
    if schema ~= nil then
      -- The verdict is SchemaKit's return: a secret one is asked about
      -- before the comparison with `true`, and is not an acceptance.
      local verdict = schema:Check(value)
      if helpers.isSecret(verdict) or verdict ~= true then
        helpers.count("syncRejected")
        return
      end
    end
    local hash = hashValue(codec, value)
    if hash == nil then
      helpers.count("syncRejected")
      return
    end
    local peerHashes = rawget(peer, "hashes")
    if rawget(peerHashes, field) == hash then
      return
    end
    rawset(rawget(peer, "values"), field, value)
    rawset(peerHashes, field, hash)
    rawget(syncSet, "_signal"):Fire(sender, field, value)
  end

  ---Apply a delivery: removed fields, then changed values. A field named in
  ---both is removed, once.
  ---@param syncSet CommKit.SyncSet
  ---@param codec table CodecKit
  ---@param values any
  ---@param removed any
  ---@param sender string
  local function applyDelivery(syncSet, codec, values, removed, sender)
    if type(values) ~= "table" or type(removed) ~= "table" then
      helpers.count("syncRejected")
      return
    end
    local peer = obtainPeer(syncSet, sender, true)
    if peer == nil then
      helpers.count("syncRejected")
      return
    end
    helpers.count("syncDeliveries")
    local fields = rawget(syncSet, "_fields")
    local fieldList = rawget(syncSet, "_fieldList")
    local peerValues = rawget(peer, "values")
    local peerHashes = rawget(peer, "hashes")
    local removedSet = {}
    for index = 1, #fieldList do
      local field = rawget(removed, index)
      if type(field) == "nil" then
        break
      end
      if type(field) == "string" and rawget(fields, field) then
        removedSet[field] = true
        if rawget(peerHashes, field) ~= nil then
          rawset(peerValues, field, nil)
          rawset(peerHashes, field, nil)
          rawget(syncSet, "_signal"):Fire(sender, field, nil)
        end
      end
    end

    for index = 1, #fieldList do
      local field = fieldList[index]
      local value = rawget(values, field)
      if type(value) ~= "nil" and not removedSet[field] then
        acceptDelivered(syncSet, codec, peer, sender, field, value)
      end
    end
  end

  ---A SyncSet frame arrived on the SyncSet's prefix. Received data is
  ---untrusted: every shape is checked before use and a bad frame is counted.
  ---@param syncSet CommKit.SyncSet
  ---@param text string
  ---@param sender string
  ---@param distribution string
  function receiveSync(syncSet, text, sender, distribution)
    if rawget(syncSet, "_closed") then
      return
    end
    local codec = helpers.findOptional("codecKit", DEPENDENCY_API.codecKit)
    if codec == nil then
      return
    end
    local ok, message = codec:Decode(text, SYNC.codecOptions)
    if not ok or type(message) ~= "table" then
      helpers.count("syncRejected")
      return
    end
    local verb = rawget(message, 1)
    if verb == SYNC.request then
      answerRequest(syncSet, rawget(message, 2), sender, distribution)
    elseif verb == SYNC.ack then
      helpers.count("syncAcknowledgements")
      obtainPeer(syncSet, sender, false)
    elseif verb == SYNC.deliver then
      applyDelivery(syncSet, codec, rawget(message, 2), rawget(message, 3), sender)
    else
      helpers.count("syncRejected")
    end
  end
end

-- SyncSet methods ------------------------------------------------------------

---@param receiver any
---@param label string
---@param level integer
local function validateSyncSet(receiver, label, level)
  helpers.validateReceiver(receiver, SYNC_SET_METATABLE, label, "CommKit SyncSet", level + 1)
end

---Refuse a field the SyncSet was not declared with.
---@param syncSet CommKit.SyncSet
---@param field any
---@param label string
---@param level integer
local function validateField(syncSet, field, label, level)
  helpers.validateBoundedString(field, label .. " field", SYNC.maxFieldNameBytes, level + 1)
  if not rawget(rawget(syncSet, "_fields"), field) then
    error(label .. " field is not declared in this SyncSet", level)
  end
end

---Set this client's value of a field. `nil` clears it. The value is kept as
---given: change a table and call `Set` again to publish the change.
---@param self CommKit.SyncSet
---@param field string
---@param value any
---@return boolean|nil ok
---@return boolean|string|nil changedOrReason `true` when the hash changed, or the refusal
function SyncSetMethods.Set(self, field, value)
  validateSyncSet(self, "CommKit.SyncSet:Set", 3)
  validateField(self, field, "CommKit.SyncSet:Set", 3)
  if rawget(self, "_closed") then
    return nil, REASON.closed
  end
  if helpers.isSecret(value) then
    error("CommKit.SyncSet:Set value must not be a secret value", 2)
  end
  local values = rawget(self, "_values")
  local hashes = rawget(self, "_hashes")
  if type(value) == "nil" then
    local changed = rawget(hashes, field) ~= nil
    rawset(values, field, nil)
    rawset(hashes, field, nil)
    return true, changed
  end

  local schemas = rawget(self, "_schemas")
  local schema = schemas ~= false and rawget(schemas, field) or nil
  if schema ~= nil then
    -- As on receipt: a secret verdict is not an acceptance.
    local verdict = schema:Check(value)
    if helpers.isSecret(verdict) or verdict ~= true then
      return nil, REASON.schema
    end
  end
  local codec =
    helpers.requireFound("codecKit", "CodecKit", DEPENDENCY_API.codecKit, "CommKit.SyncSet:Set", 3)
  local hashed, hash, reason = pcall(hashValue, codec, value)
  if not hashed then
    error("CommKit.SyncSet:Set value must not contain a secret value", 2)
  end
  if hash == nil then
    return nil, reason
  end
  if rawget(hashes, field) == hash then
    return true, false
  end
  rawset(values, field, value)
  rawset(hashes, field, hash)
  return true, true
end

---This client's value of a field, or `nil`.
---@param self CommKit.SyncSet
---@param field string
---@return any
function SyncSetMethods.Get(self, field)
  validateSyncSet(self, "CommKit.SyncSet:Get", 3)
  validateField(self, field, "CommKit.SyncSet:Get", 3)
  return rawget(rawget(self, "_values"), field)
end

---The content hash of this client's value of a field, or `nil` when unset.
---@param self CommKit.SyncSet
---@param field string
---@return integer|nil
function SyncSetMethods.GetHash(self, field)
  validateSyncSet(self, "CommKit.SyncSet:GetHash", 3)
  validateField(self, field, "CommKit.SyncSet:GetHash", 3)
  return rawget(rawget(self, "_hashes"), field)
end

---The last value `sender` delivered for a field, or `nil`.
---@param self CommKit.SyncSet
---@param sender string
---@param field string
---@return any
function SyncSetMethods.GetRemote(self, sender, field)
  validateSyncSet(self, "CommKit.SyncSet:GetRemote", 3)
  helpers.validateBoundedString(sender, "CommKit.SyncSet:GetRemote sender", 255, 3)
  validateField(self, field, "CommKit.SyncSet:GetRemote", 3)
  local peer = rawget(rawget(self, "_peers"), sender)
  if peer == nil then
    return nil
  end
  return rawget(rawget(peer, "values"), field)
end

---Ask `target` for the fields whose hash differs from the ones this client
---holds for it. The answer arrives as `OnChanged` calls, or as an ack.
---@param self CommKit.SyncSet
---@param target string
---@return CommKit.SendHandle|nil handle
---@return string|nil reason
function SyncSetMethods.Request(self, target)
  validateSyncSet(self, "CommKit.SyncSet:Request", 3)
  helpers.validateBoundedString(target, "CommKit.SyncSet:Request target", 255, 3)
  if rawget(self, "_closed") then
    return nil, REASON.closed
  end
  local peer = rawget(rawget(self, "_peers"), target)
  local hashes = peer ~= nil and rawget(peer, "hashes") or {}
  local text = encodeSyncMessage({ SYNC.request, hashes })
  if text == nil then
    return nil, REASON.unavailable
  end
  local handle, reason = helpers.enqueueSend(
    rawget(self, "_scope"),
    rawget(self, "_prefix"),
    text,
    "WHISPER",
    target,
    PRIORITY.NORMAL,
    false,
    false,
    false
  )
  return handle, reason
end

---Call `callback(sender, field, value)` when a peer's field changes; `value`
---is `nil` when the peer cleared it. Returns `nil, "full"` past the
---SyncSet's `maxListeners` (16 unless the options said otherwise).
---@param self CommKit.SyncSet
---@param callback CommKit.ChangedCallback
---@return CommKit.Connection|nil connection
---@return string|nil reason
function SyncSetMethods.OnChanged(self, callback)
  validateSyncSet(self, "CommKit.SyncSet:OnChanged", 3)
  helpers.validateCallback(callback, "CommKit.SyncSet:OnChanged callback", 3)
  if rawget(self, "_closed") then
    return nil, REASON.closed
  end
  local listeners = rawget(self, "_listeners")
  if helpers.reachedLimit(#listeners, rawget(self, "_maxListeners")) then
    return nil, REASON.full
  end
  local signalConnection = rawget(self, "_signal"):Connect(function(...)
    rawget(dispatch, "isolatedCall")(callback, ...)
  end)
  local connection = setmetatable({
    _schema = LAYOUT.connection,
    _kind = "changed",
    _owner = self,
    _prefix = rawget(self, "_prefix"),
    _signalConnection = signalConnection,
    _connected = true,
  }, CONNECTION_METATABLE)
  listeners[#listeners + 1] = connection
  return connection, nil
end

---Close the SyncSet: its registration and listeners are disconnected and the
---peer cache is dropped. Terminal.
---@param self CommKit.SyncSet
---@return boolean closed `false` when it was already closed
function SyncSetMethods.Close(self)
  validateSyncSet(self, "CommKit.SyncSet:Close", 3)
  return helpers.closeSyncSet(self)
end

---@param self CommKit.SyncSet
---@return boolean
function SyncSetMethods.IsClosed(self)
  validateSyncSet(self, "CommKit.SyncSet:IsClosed", 3)
  return rawget(self, "_closed") == true
end

-- Scope method ---------------------------------------------------------------

---Validate the `fields` option: 1 to 32 distinct names of 1 to 64 bytes.
---@param fields any
---@param level integer
---@return table<string, true> fieldSet
---@return string[] fieldList
local function readSyncFields(fields, level)
  local label = "CommKit.Scope:SyncSet options.fields"
  if type(fields) ~= "table" or #fields == 0 or #fields > SYNC.maxFields then
    error(label .. " must be an array of 1 to " .. SYNC.maxFields .. " field names", level)
  end
  local fieldSet, fieldList = {}, {}
  for index = 1, #fields do
    local field = fields[index]
    helpers.validateBoundedString(field, label .. " entry", SYNC.maxFieldNameBytes, level + 1)
    if fieldSet[field] then
      error(label .. " must not name a field twice", level)
    end
    fieldSet[field] = true
    fieldList[index] = field
  end
  return fieldSet, fieldList
end

---Validate the `schema` option: a sealed SchemaKit schema per declared field.
---@param schema any
---@param fieldSet table<string, true>
---@param level integer
---@return table|false
local function readSyncSchemas(schema, fieldSet, level)
  if type(schema) == "nil" then
    return false
  end
  local label = "CommKit.Scope:SyncSet options.schema"
  if type(schema) ~= "table" then
    error(label .. " must be a table of sealed SchemaKit schemas or nil", level)
  end
  local SchemaKit = helpers.requireFound(
    "schemaKit",
    "SchemaKit",
    DEPENDENCY_API.schemaKit,
    "CommKit.Scope:SyncSet options.schema",
    level + 1
  )
  local describe = rawget(rawget(SchemaKit, "Schema") or {}, "Describe")
  local schemas = {}
  for field, fieldSchema in pairs(schema) do
    if type(field) ~= "string" or not fieldSet[field] then
      error(label .. " names a field that is not declared", level)
    end
    if type(describe) ~= "function" or not pcall(describe, fieldSchema) then
      error(label .. "." .. field .. " must be a sealed SchemaKit schema", level)
    end
    schemas[field] = fieldSchema
  end
  return schemas
end

---Create a SyncSet on `prefix`. Requires CodecKit; `options.schema` requires
---SchemaKit. Returns `nil` and a reason when the prefix cannot be registered.
---@param self CommKit.Scope
---@param prefix string
---@param options CommKit.SyncSetOptions
---@return CommKit.SyncSet|nil syncSet
---@return string|nil reason
function ScopeMethods.SyncSet(self, prefix, options)
  helpers.validateScope(self, "CommKit.Scope:SyncSet", 3)
  helpers.validateBoundedString(prefix, "CommKit.Scope:SyncSet prefix", MAX_PREFIX_BYTES, 3)
  if type(options) ~= "table" then
    error("CommKit.Scope:SyncSet options must be a table", 2)
  end
  helpers.validateKeys(options, OPTION_KEYS.syncSet, "CommKit.Scope:SyncSet options", 3)
  local fieldSet, fieldList = readSyncFields(rawget(options, "fields"), 3)
  local schemas = readSyncSchemas(rawget(options, "schema"), fieldSet, 3)
  local maxListeners = rawget(options, "maxListeners")
  if type(maxListeners) == "nil" then
    maxListeners = SYNC.defaultMaxListeners
  else
    helpers.validateObjectLimit(maxListeners, "CommKit.Scope:SyncSet options.maxListeners", 3)
  end
  helpers.requireFound("codecKit", "CodecKit", DEPENDENCY_API.codecKit, "CommKit.Scope:SyncSet", 3)

  local syncSet = setmetatable({
    _schema = LAYOUT.syncSet,
    _scope = self,
    _prefix = prefix,
    _fields = fieldSet,
    _fieldList = fieldList,
    _schemas = schemas,
    _values = {},
    _hashes = {},
    _peers = {},
    _peerCount = 0,
    _touch = 0,
    _signal = helpers.newSignal(),
    _listeners = {},
    _maxListeners = maxListeners,
    _registration = false,
    _closed = false,
  }, SYNC_SET_METATABLE)

  local registration, reason = helpers.registerInScope(
    self,
    prefix,
    function(_, text, distribution, sender)
      rawget(dispatch, "receiveSync")(syncSet, text, sender, distribution)
    end,
    "framed"
  )
  if registration == nil then
    return nil, reason
  end
  rawset(syncSet, "_registration", registration)
  local syncSets = rawget(self, "_syncSets")
  syncSets[#syncSets + 1] = syncSet
  return syncSet, nil
end

-- Commit ---------------------------------------------------------------------

local SyncSetPrototype = rawget(CommKit, "SyncSet")
for name, method in pairs(SyncSetMethods) do
  rawset(SyncSetPrototype, name, method)
end
rawset(rawget(CommKit, "Scope"), "SyncSet", ScopeMethods.SyncSet)
rawset(dispatch, "receiveSync", receiveSync)
rawset(parts, PART_NAME, { revision = PART_REVISION })

return CommKit
