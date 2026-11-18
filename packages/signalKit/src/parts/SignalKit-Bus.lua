-- MoltenCodes SignalKit part Bus
--
-- Named message buses, the counterpart of AceEvent-3.0's messages: a bus is a
-- named, package-wide map from topic to signal, so two modules or two addons
-- that share no reference can still talk. `SignalKit:Bus(name)`,
-- `SignalKit:ForAddon(addonName)` and `SignalKit:CloseAddonBus(addonName)`;
-- topics with argument policies (`DeclareTopic`), `Publish`, `Subscribe`,
-- `SubscribeOnce`, `Unsubscribe`, `Topics`; bus scopes (`CreateScope`); and
-- the close of an addon's bus at logout. Without this part `Bus` and
-- `ForAddon` raise at the caller with the file to embed and `CloseAddonBus`
-- answers `false` (docs/API.md, "Parts"; ADR 0001).
--
-- Because a bus is shared by every addon in the session, bus listeners are
-- isolated from each other and their errors are reported through the host
-- error handler instead. On a World of Warcraft client this part uses
-- `securecallfunction` and `geterrorhandler` when they exist.
--
-- SignalKit does not observe addon shutdown and depends on neither
-- LifecycleKit nor EventKit, yet an addon's bus is closed at logout whenever
-- the framework can observe logout at all (design constitution, principle
-- 4b). `ForAddon` arranges it through whichever of LifecycleKit API 1 and
-- EventKit API 1 is registered, both found through `Registry:Find`: see
-- "Logout close" below and "At logout" in `docs/API.md`.
--
-- The part needs SignalKit's core loaded first. The bus and bus-scope
-- prototypes and metatables are core state, so buses survive any revision;
-- the part fills the prototypes, and reads the core's listener storage from
-- `_state.helpers` at call time, so a core upgraded after this part loaded
-- serves it. It records itself in `_state.parts.Bus` with the hooks the core
-- calls: `fireIsolated` (a bus topic signal's `Fire`), `noteScopeDisconnect`
-- and `closeAddonBus`.
--
-- Contents
-- --------
--   Constants ............. identity, default limits, logout outcomes
--   Core .................. SignalKit's core, its state and its helpers
--   Shared helpers ........ the secret probe and error reporting
--   Listener isolation .... allocation-free protected delivery
--   Bus validation ........ receiver, topic and policy checks
--   Bus topics ............ topic records, declaration, subscription
--   Bus methods ........... DeclareTopic, Publish, Subscribe, Topics, ...
--   Bus scopes ............ owner scopes over one bus
--   Logout close .......... who closes an addon's bus at logout
--   Facade methods ........ Bus, ForAddon and the close of an addon bus
--   Commit ................ the part record, the methods and the dispatch

-- Constants ------------------------------------------------------------------

local PART_NAME = "Bus"
local PART_REVISION = 1
local REQUIRED_REGISTRY_API = 2
local PACKAGE_NAME, CORE_API = "signalKit", 1
-- The `_state.helpers` entries and part records this part relies on; the core
-- publishes the interface it offers as `_state.partInterface`.
local REQUIRED_PART_INTERFACE = 1

-- Who closes an addon's bus at logout, as the bus's `_logoutCloser` records it
-- (docs/API.md, "At logout"). A bus nobody asked for through `ForAddon`
-- records `false`: it is closed only by an explicit `CloseAddonBus`.
--
--   "lifecycleKit"   LifecycleKit names SignalKit in `CLOSES_ADDON_SCOPES` and
--                    closes the bus after the addon's shutdown callbacks.
--   "onShutdown"     an older LifecycleKit is registered: SignalKit subscribed
--                    to the addon's `OnShutdown`, kept in
--                    `_shutdownSubscription`.
--   "playerLogout"   no LifecycleKit, but EventKit: the package-level
--                    `PLAYER_LOGOUT` watcher closes the bus.
--   "none"           neither was registered; the next `ForAddon` asks again.
--
-- Only "none" and "playerLogout" are asked again: a LifecycleKit that loads
-- later still takes the bus over, so its shutdown callbacks run before the bus
-- closes. The API generations of the two Kits asked share the table.
local LOGOUT = {
  lifecycleKitApi = 1,
  eventKitApi = 1,
  byLifecycle = "lifecycleKit",
  byShutdownCallback = "onShutdown",
  byEvent = "playerLogout",
  byNobody = "none",
}

-- Distinct topics one bus may know, declared or merely subscribed to, unless
-- the bus was created with `options.maxTopics`. Beyond it `DeclareTopic` and a
-- subscription to a new topic answer `nil, "full"`.
local DEFAULT_MAX_TOPICS = 256

-- Live listeners one topic may hold, unless the bus was created with
-- `options.maxListeners`. Beyond it a subscription answers `nil, "full"`.
local DEFAULT_MAX_LISTENERS = 256

-- Values staged with one multiple assignment, both into the reusable `xpcall`
-- buffer and into a journal slot; wider payloads fall back to a `select` loop
-- for the remainder. Journal slots are sized in advance for this many values.
local MULTIPLE_ASSIGNMENT_SLOTS = 8

-- Lua 5.1 names it `unpack`; `table.unpack` is its later spelling.
local unpackValues = rawget(table, "unpack") or unpack

-- Core -----------------------------------------------------------------------

local type = type
local rawget = rawget
local rawset = rawset

-- The shared MoltenCodes namespace is the one documented global handoff point between independently embedded copies.
-- selene: allow(global_usage)
local namespace = rawget(_G, "MoltenCodes")
local generations = type(namespace) == "table" and rawget(namespace, "Registries") or nil
local Registry = type(generations) == "table" and rawget(generations, REQUIRED_REGISTRY_API) or nil
local SignalKit = nil
if type(Registry) == "table" and type(rawget(Registry, "Get")) == "function" then
  SignalKit = Registry:Get(PACKAGE_NAME, CORE_API)
end
local state = type(SignalKit) == "table" and rawget(SignalKit, "_state") or nil
local partInterface = type(state) == "table" and rawget(state, "partInterface") or nil
if
  type(state) ~= "table"
  or type(partInterface) ~= "number"
  or partInterface < REQUIRED_PART_INTERFACE
  or type(rawget(state, "parts")) ~= "table"
  or type(rawget(state, "helpers")) ~= "table"
then
  error("MoltenCodes SignalKit part Bus requires SignalKit API 1 to be loaded first", 2)
end

local parts = rawget(state, "parts")
local installed = rawget(parts, PART_NAME)
if
  type(installed) == "table"
  and type(rawget(installed, "revision")) == "number"
  and rawget(installed, "revision") >= PART_REVISION
then
  -- An equal or newer revision of this part already serves every copy.
  return SignalKit
end

-- The core's functions, refilled by every core revision; read through this
-- table at each call, never copied, so a newer core serves this part.
local helpers = rawget(state, "helpers")
local BUS_PROTOTYPE = rawget(state, "busPrototype")
local BUS_METATABLE = rawget(state, "busMetatable")
local SCOPE_PROTOTYPE = rawget(state, "scopePrototype")
local SCOPE_METATABLE = rawget(state, "scopeMetatable")
local UNBOUNDED = rawget(state, "unbounded")
local sharedLimits = rawget(state, "limits")

-- The package-level `PLAYER_LOGOUT` watcher (see "Logout close"): the EventKit
-- scope that owns it, the connection once made, the trampoline handed to
-- EventKit, and the function it calls, which a newer part revision replaces.
-- A state an older revision created already has it.
local logoutWatch = rawget(state, "logoutWatch")
if type(logoutWatch) ~= "table" then
  logoutWatch = { scope = false, connection = false, trampoline = false, close = false }
  rawset(state, "logoutWatch", logoutWatch)
end

-- Shared helpers ---------------------------------------------------------------

-- shared:begin isSecret 1
-- Copied from tooling/shared/lua/isSecret.lua by python3 -m tooling.shared.sync; edit that file, not this copy.
---Whether `value` is a secret value the host forbids comparing.
---@type fun(value: any): boolean
local isSecret
do
  -- issecretvalue is a client API reachable only through the global table.
  -- selene: allow(global_usage)
  local loadedProbe = rawget(_G, "issecretvalue")
  if type(loadedProbe) ~= "function" then
    loadedProbe = nil
  end

  isSecret = function(value)
    local probe = loadedProbe
    if probe == nil then
      -- selene: allow(global_usage)
      probe = rawget(_G, "issecretvalue")
      if type(probe) ~= "function" then
        return false
      end
    end
    return probe(value) == true
  end
end
-- shared:end isSecret

-- shared:begin reportError 1
-- Copied from tooling/shared/lua/reportError.lua by python3 -m tooling.shared.sync; edit that file, not this copy.
---Report `failure` through the host error handler, or print it.
---@param failure any
local function reportError(failure)
  -- geterrorhandler is a client API reachable only through the global table.
  -- selene: allow(global_usage)
  local getErrorHandler = rawget(_G, "geterrorhandler")
  if type(getErrorHandler) == "function" then
    local handler = getErrorHandler()
    if type(handler) == "function" and pcall(handler, failure) then
      return
    end
  end
  print(failure)
end
-- shared:end reportError

-- Listener isolation -----------------------------------------------------------
--
-- A raw signal belongs to whoever holds it, so its listener errors propagate to
-- the caller of `Fire`, who owns those listeners. A bus is shared by every
-- addon in the session: the publisher does not own its subscribers and must
-- not be aborted by one of them, nor may one subscriber stop delivery to the
-- ones behind it. Bus deliveries are therefore isolated and a failure is
-- reported through the host error handler.
--
-- Modern clients provide `securecallfunction`, which both isolates the call and
-- keeps one listener's taint out of the next. Elsewhere this falls back to
-- `xpcall`, which in Lua 5.1 accepts no extra arguments: the payload is staged
-- in one reusable buffer and a single reusable trampoline forwards it, so no
-- closure or argument table is allocated per publish. This is the same model
-- EventKit uses at its own multi-tenant boundary.
--
-- A bus topic's signal is flagged `_isolated`, and `Fire` calls the isolation
-- function around each subscriber's own callback. Revisions before 9 wrapped
-- every subscription in a delivery closure instead: one closure per
-- subscription, and one more call per delivery. Subscriptions those revisions
-- made keep their closure after an upgrade and are isolated twice, which still
-- reports an error once.

local stagedCallback = nil
local stagedCount = 0
local stagedPayload = {}

---Clear the staged payload slots and pass the values through unchanged.
---
---The values are already on the call stack by the time this runs, so a nested
---publish that restages the buffer cannot corrupt the delivery in progress,
---and the buffer does not keep the payload alive after it.
---@param count integer
---@param ... any
---@return any ...
local function releaseStagedPayload(count, ...)
  for index = 1, count do
    stagedPayload[index] = nil
  end
  return ...
end

---Reusable `xpcall` trampoline that forwards the staged payload.
---@return any ...
local function invokeStaged()
  -- Always set by `isolateWithXpcall` immediately before `xpcall` runs this.
  local callback = stagedCallback --[[@as function]]
  local count = stagedCount
  stagedCallback = nil
  return callback(releaseStagedPayload(count, unpackValues(stagedPayload, 1, count)))
end

---Stage `...` into the reusable buffer.
---
---One multiple assignment costs the same whatever the payload size, while
---assigning `select(index, ...)` per slot is quadratic in it; only slots past
---the multiple assignment take the loop. Slots past `count` are nil or stale
---and never read, because the trampoline unpacks with explicit bounds.
---@param count integer
---@param ... any
local function stagePayload(count, ...)
  local payload = stagedPayload
  payload[1], payload[2], payload[3], payload[4], payload[5], payload[6], payload[7], payload[8] =
    ...
  for index = MULTIPLE_ASSIGNMENT_SLOTS + 1, count do
    payload[index] = select(index, ...)
  end
end

---Call `callback` so a raised error is reported rather than propagated.
---@param callback function
---@param ... any published arguments
local function isolateWithXpcall(callback, ...)
  local count = select("#", ...)
  stagedCallback = callback
  stagedCount = count
  stagePayload(count, ...)
  xpcall(invokeStaged, reportError)
end

-- securecallfunction is a World of Warcraft client API reachable only through the global table.
-- selene: allow(global_usage)
local secureCallFunction = rawget(_G, "securecallfunction")
local isolate = isolateWithXpcall
if type(secureCallFunction) == "function" then
  -- Its signature is already `(callback, ...)`, so no adapter frame is needed.
  isolate = secureCallFunction
end

---Deliver `...` to every eligible listener of a bus topic's signal, each
---delivery isolated (see "Listener isolation"), with the generation and the
---dispatch depth kept exactly as `fire` keeps them.
---
---`Publish` calls this directly, because the bus has already validated
---everything `fire` would check; the core's `Fire` calls it, through this
---part's record, for an isolated signal.
---@param signal table a bus topic signal
---@param ... any
local function fireIsolated(signal, ...)
  local listeners = signal._listeners
  signal._generation = (signal._generation or 0) + 1
  local depth = signal._firing
  if depth ~= nil then
    signal._firing = depth + 1
  end

  -- The isolation function is read from shared state once per dispatch, so
  -- a newer revision replaces it for the signals that already exist.
  local isolateDelivery = state.isolate
  -- The layout is read once per dispatch; see "Listener storage".
  ---@type integer|string, integer|string, integer|string
  local callbackKey, connectedKey, onceKey = 1, 2, 3
  if signal._layout ~= 2 then
    callbackKey, connectedKey, onceKey = "_callback", "_connected", "_once"
  end
  for index = 1, #listeners do
    local connection = listeners[index]
    if connection[connectedKey] == true then
      local callback = connection[callbackKey]
      if connection[onceKey] == true then
        helpers.disconnectConnection(connection)
      end
      isolateDelivery(callback, ...)
    end
  end

  if depth ~= nil then
    signal._firing = depth
  end
end

-- Bus validation ---------------------------------------------------------------
--
-- Every public bus entry point validates at its own caller's line. Callers keep
-- results in a local before returning them: a Lua tail call would remove the
-- public frame the stack level is counted against.

---@param bus any receiver the public method was called on
---@param label string qualified public method name
---@param level integer stack level the failure is reported at
local function validateBus(bus, label, level)
  -- `getmetatable` answers the bus metatable for a bus only, and never raises.
  if getmetatable(bus) ~= BUS_METATABLE then
    error(label .. " must be called on a SignalKit bus with a colon call", level)
  end
end

---@param scope any receiver the public method was called on
---@param label string qualified public method name
---@param level integer stack level the failure is reported at
local function validateScope(scope, label, level)
  if getmetatable(scope) ~= SCOPE_METATABLE then
    error(label .. " must be called on a SignalKit bus scope", level)
  end
end

---@param bus SignalKit.Bus
---@param label string qualified public method name
---@param level integer stack level the failure is reported at
local function ensureBusOpen(bus, label, level)
  if rawget(bus, "_closed") == true then
    error(label .. ' cannot subscribe on the closed bus "' .. rawget(bus, "_name") .. '"', level)
  end
end

---Validate a `DeclareTopic` options table and return its two policies.
---@param options any
---@param level integer stack level the failures are reported at
---@return integer|function|false arguments
---@return string|false description
local function readTopicOptions(options, level)
  if type(options) == "nil" then
    return false, false
  end
  if type(options) ~= "table" then
    error("SignalKit.Bus:DeclareTopic options must be a table or nil", level)
  end

  local arguments = rawget(options, "arguments")
  if type(arguments) == "nil" then
    arguments = false
  elseif type(arguments) == "number" then
    helpers.refuseSecret(arguments, "SignalKit.Bus:DeclareTopic options.arguments", level + 1)
    -- `math.huge` passes the integer test and NaN fails every comparison,
    -- so both are named explicitly.
    if
      arguments ~= arguments
      or arguments == math.huge
      or arguments < 0
      or arguments ~= math.floor(arguments)
    then
      error(
        "SignalKit.Bus:DeclareTopic options.arguments count must be a finite non-negative integer",
        level
      )
    end
  elseif type(arguments) ~= "function" then
    error(
      "SignalKit.Bus:DeclareTopic options.arguments must be a count, a validator function or nil",
      level
    )
  end

  local description = rawget(options, "description")
  if type(description) == "nil" then
    description = false
  elseif type(description) ~= "string" then
    error("SignalKit.Bus:DeclareTopic options.description must be a string or nil", level)
  end

  return arguments, description
end

---Describe a validator's refusal reason or error without ever inspecting a
---secret. The text is the validator's own; SignalKit never adds the published
---argument values to it.
---@param reason any
---@param fallback string text used when `reason` is not a non-empty string
---@return string
local function describeRefusal(reason, fallback)
  if isSecret(reason) then
    return "the validator gave a secret reason"
  end
  if type(reason) == "string" and reason ~= "" then
    return reason
  end
  return fallback
end

-- Bus topics -------------------------------------------------------------------

---Return the record of `topic` on `bus`, creating an undeclared one on demand.
---@param bus SignalKit.Bus
---@param topic string
---@return SignalKit.TopicRecord|nil record `nil` when the bus already knows `maxTopics` topics.
local function obtainTopicRecord(bus, topic)
  local topics = rawget(bus, "_topics")
  local record = rawget(topics, topic)
  if record ~= nil then
    return record
  end

  local count = rawget(bus, "_topicCount")
  local maxTopics = rawget(bus, "_maxTopics")
  if maxTopics ~= UNBOUNDED and count >= maxTopics then
    return nil
  end

  record = { declared = false, arguments = false, description = false, signal = false }
  rawset(topics, topic, record)
  rawset(bus, "_topicCount", count + 1)
  return record
end

---Validate and attach one bus subscription.
---@param bus any
---@param label string qualified public method name
---@param level integer stack level, counted from this function, of the public caller
---@param topic any
---@param callback any a listener, or a receiver table
---@param once boolean
---@param scope table|nil the bus scope that will own the subscription
---@param methodName any the receiver's method name; the topic when `nil`
---@return SignalKit.Connection|nil connection
---@return "full"|nil reason
local function subscribe(bus, label, level, topic, callback, once, scope, methodName)
  -- The tests run inline and the validators, which raise at the public
  -- caller's line, only for a call that fails one; see `busPublish`.
  if isSecret(topic) then
    helpers.validateNonEmptyString(topic, label .. " topic", level + 1)
  end
  -- A topic record exists only under a validated non-empty string, so a hit
  -- proves the topic; reading a table with a `nil` or NaN key is allowed.
  local record = bus._topics[topic]
  if record == nil and (type(topic) ~= "string" or topic == "") then
    helpers.validateNonEmptyString(topic, label .. " topic", level + 1)
  end
  if type(callback) ~= "function" then
    if type(callback) ~= "table" then
      error(
        label .. " callback must be a function, or a receiver table followed by a method name",
        level
      )
    end
    -- AceEvent-3.0's default: a message's handler is the method named after it.
    if type(methodName) == "nil" then
      methodName = topic
    end
    callback = helpers.bindMethod(callback, methodName, label, level + 1)
  end
  if bus._closed == true then
    ensureBusOpen(bus, label, level + 1)
  end

  if record == nil then
    record = obtainTopicRecord(bus, topic)
    if record == nil then
      return nil, "full"
    end
  end

  local signal = record.signal
  if signal == false then
    -- A topic signal carries no hooks: the bus, not the topic, is what a
    -- consumer observes. It isolates every delivery itself, so the
    -- subscriber's own callback is what it holds.
    signal = setmetatable(helpers.newSignalTable(false, false, true), helpers.signalMetatable)
    record.signal = signal
  end

  local listeners = signal._listeners
  local maxListeners = bus._maxListeners
  if maxListeners ~= UNBOUNDED and #listeners - (signal._tombstones or 0) >= maxListeners then
    return nil, "full"
  end

  local connection = helpers.attach(signal, listeners, callback, once, scope)
  return connection, nil
end

-- Bus methods ------------------------------------------------------------------

---Declare `topic` and its argument policy on this bus.
---
---Declaring the same topic again with the same argument policy is accepted and
---changes nothing, so a publisher and a consumer may both declare it; a
---different policy is refused at the caller.
---@param self SignalKit.Bus
---@param topic string
---@param options SignalKit.TopicOptions?
---@return true|nil declared `nil` when the bus already knows `maxTopics` topics.
---@return "full"|nil reason
local function busDeclareTopic(self, topic, options)
  validateBus(self, "SignalKit.Bus:DeclareTopic", 3)
  helpers.validateNonEmptyString(topic, "SignalKit.Bus:DeclareTopic topic", 3)
  local arguments, description = readTopicOptions(options, 3)
  if rawget(self, "_closed") == true then
    error(
      'SignalKit.Bus:DeclareTopic cannot declare on the closed bus "'
        .. rawget(self, "_name")
        .. '"',
      2
    )
  end

  local record = obtainTopicRecord(self, topic)
  if record == nil then
    return nil, "full"
  end

  if rawget(record, "declared") == true then
    if rawget(record, "arguments") ~= arguments then
      error(
        'SignalKit.Bus:DeclareTopic topic "'
          .. topic
          .. '" is already declared on bus "'
          .. rawget(self, "_name")
          .. '" with a different arguments policy',
        2
      )
    end
    return true, nil
  end

  rawset(record, "declared", true)
  rawset(record, "arguments", arguments)
  rawset(record, "description", description)
  return true, nil
end

---Raise the refusal of an undeclared topic at the publisher's line.
---@param bus SignalKit.Bus
---@param topic string
local function refuseUndeclared(bus, topic)
  error(
    'SignalKit.Bus:Publish topic "'
      .. topic
      .. '" is not declared on bus "'
      .. rawget(bus, "_name")
      .. '"; declare it with bus:DeclareTopic(topic, options)'
      .. " or create the bus with options.openTopics = true",
    3
  )
end

---Raise the refusal of an argument list at the publisher's line.
---@param bus SignalKit.Bus
---@param topic string
---@param detail string
local function refuseArguments(bus, topic, detail)
  error(
    'SignalKit.Bus:Publish topic "'
      .. topic
      .. '" on bus "'
      .. rawget(bus, "_name")
      .. '" refused its arguments: '
      .. detail,
    3
  )
end

---Raise a validator's own failure as a refusal at the publisher's line.
---@param bus SignalKit.Bus
---@param topic string
---@param detail string
local function refuseFailedValidator(bus, topic, detail)
  error(
    'SignalKit.Bus:Publish validator for topic "'
      .. topic
      .. '" on bus "'
      .. rawget(bus, "_name")
      .. '" failed: '
      .. detail,
    3
  )
end

---Deliver `...` to every subscriber of `topic`, in subscription order.
---
---Refused at the caller when the topic is undeclared on a bus without
---`openTopics`, or when its arguments fail the declared policy. Subscriber
---errors are reported through the host error handler, never raised here.
---@param self SignalKit.Bus
---@param topic string
---@param ... any
local function busPublish(self, topic, ...)
  -- Publish is the bus's hot path, so the receiver and the topic are tested
  -- inline and the validators, which raise at the caller's line, run only
  -- for a call that fails a test. The secret test comes first, because
  -- comparing a secret with `""` would raise here instead of at the caller.
  if getmetatable(self) ~= BUS_METATABLE then
    validateBus(self, "SignalKit.Bus:Publish", 3)
  end
  if isSecret(topic) then
    helpers.validateNonEmptyString(topic, "SignalKit.Bus:Publish topic", 3)
  end
  -- Past the receiver check every table read here is one SignalKit created
  -- and fills completely, so plain indexing (a VM instruction) replaces
  -- `rawget` (a C call) on this per-publish path. A topic record exists only
  -- under a validated non-empty string, so a hit proves the topic and the
  -- type tests run only on a miss; reading with a `nil` or NaN key is allowed.
  local record = self._topics[topic]
  if record == nil and (type(topic) ~= "string" or topic == "") then
    helpers.validateNonEmptyString(topic, "SignalKit.Bus:Publish topic", 3)
  end
  if self._closed == true then
    -- A closed bus belongs to an addon that has shut down. Late publishes
    -- from other addons' shutdown paths are expected and deliver nothing,
    -- so the topic policy is not applied to them.
    return
  end

  if record == nil or record.declared ~= true then
    if self._openTopics ~= true then
      refuseUndeclared(self, topic)
    end
  else
    local arguments = record.arguments
    if type(arguments) == "number" then
      local count = select("#", ...)
      if count ~= arguments then
        refuseArguments(self, topic, "expected " .. arguments .. " arguments, got " .. count)
      end
    elseif arguments ~= false then
      -- The validator may belong to another addon, so its failure is
      -- turned into a refusal at the publisher's line. `pcall` with the
      -- arguments passed through allocates nothing.
      local ran, accepted, reason = pcall(arguments --[[@as SignalKit.TopicValidator]], ...)
      if not ran then
        refuseFailedValidator(self, topic, describeRefusal(accepted, "a non-string error"))
      elseif isSecret(accepted) or accepted ~= true then
        -- A secret verdict cannot be compared, so it is not an acceptance.
        refuseArguments(self, topic, describeRefusal(reason, "the validator gave no reason"))
      end
    end
  end

  if record ~= nil then
    local signal = record.signal
    if signal ~= false then
      fireIsolated(signal, ...)
    end
  end
end

---Subscribe `callback` to every future publish of `topic`.
---
---A topic does not have to be declared before it is subscribed to, so a
---subscriber may load before the publisher that declares it.
---@param self SignalKit.Bus
---@param topic string
---@param callback fun(...: any)|table a listener, or a receiver table
---@param methodName string? the receiver's method; defaults to `topic`
---@return SignalKit.Connection|nil connection
---@return "full"|nil reason
local function busSubscribe(self, topic, callback, methodName)
  if getmetatable(self) ~= BUS_METATABLE then
    validateBus(self, "SignalKit.Bus:Subscribe", 3)
  end
  local connection, reason =
    subscribe(self, "SignalKit.Bus:Subscribe", 3, topic, callback, false, nil, methodName)
  return connection, reason
end

---Subscribe `callback` to at most one future publish of `topic`.
---@param self SignalKit.Bus
---@param topic string
---@param callback fun(...: any)|table a listener, or a receiver table
---@param methodName string? the receiver's method; defaults to `topic`
---@return SignalKit.Connection|nil connection
---@return "full"|nil reason
local function busSubscribeOnce(self, topic, callback, methodName)
  validateBus(self, "SignalKit.Bus:SubscribeOnce", 3)
  local connection, reason =
    subscribe(self, "SignalKit.Bus:SubscribeOnce", 3, topic, callback, true, nil, methodName)
  return connection, reason
end

---Disconnect every subscription of `callback` to `topic`.
---@param self SignalKit.Bus
---@param topic string
---@param callback fun(...: any)
---@return integer disconnected
local function busUnsubscribe(self, topic, callback)
  validateBus(self, "SignalKit.Bus:Unsubscribe", 3)
  helpers.validateNonEmptyString(topic, "SignalKit.Bus:Unsubscribe topic", 3)
  if type(callback) ~= "function" then
    error("SignalKit.Bus:Unsubscribe callback must be a function", 2)
  end

  local record = rawget(rawget(self, "_topics"), topic)
  if record == nil or rawget(record, "signal") == false then
    return 0
  end

  -- The walk only marks: every matching connection is released in place,
  -- and the array is settled once afterwards, exactly as that many single
  -- disconnects would leave it. Settling inside the walk would move entries
  -- underneath it. A topic signal has no hooks, so nothing runs meanwhile.
  local signal = rawget(record, "signal")
  local listeners = rawget(signal, "_listeners")
  local total = #listeners
  local disconnected = 0
  local connectedKey = helpers.connectedKeyOf(signal)
  local callbackKey = connectedKey == 2 and 1 or "_callback"
  for index = 1, total do
    local connection = listeners[index]
    -- A subscription made before revision 9 holds a delivery closure in its
    -- callback field and the subscriber's function in `_busCallback`.
    local subscribed = connection._busCallback or connection[callbackKey]
    if subscribed == callback and connection[connectedKey] == true then
      helpers.releaseConnection(connection)
      disconnected = disconnected + 1
    end
  end
  if disconnected == 0 then
    return 0
  end

  local tombstones = helpers.tombstoneCount(signal) + disconnected
  if rawget(signal, "_firing") == 0 then
    rawset(signal, "_tombstones", helpers.settleInPlace(listeners, total, tombstones, connectedKey))
  elseif helpers.shouldCompact(tombstones, total) then
    helpers.compact(signal, listeners, connectedKey)
  else
    rawset(signal, "_tombstones", tombstones)
  end
  return disconnected
end

---Return the declared topic names of this bus, sorted. Allocates the array.
---@param self SignalKit.Bus
---@return string[] topics
local function busTopics(self)
  validateBus(self, "SignalKit.Bus:Topics", 3)

  local names = {}
  for topic, record in pairs(rawget(self, "_topics")) do
    if rawget(record, "declared") == true then
      names[#names + 1] = topic
    end
  end
  table.sort(names)
  return names
end

-- Bus scopes -------------------------------------------------------------------
--
-- A scope keeps the connections it created in an array. A connection that
-- disconnects by any path (its handle, `Unsubscribe`, a once-delivery, the bus
-- closing) reports it through `noteScopeDisconnect`, and the array is compacted
-- in place as soon as its dead entries outnumber its live ones. Each compaction
-- removes more than half of the entries it walks, so it is amortized O(1) per
-- disconnect, and the array never holds more than twice the live subscriptions
-- plus one.
--
-- Closing a scope disconnects at once, even inside a publish: a subscription
-- disconnected mid-dispatch is skipped, exactly as SignalKit's own disconnect
-- semantics say. (EventKit instead defers a scope sweep to the end of the
-- dispatch; buses keep SignalKit's rule so their semantics stay a signal's.)

---Build one open scope over `bus`.
---@param bus SignalKit.Bus
---@return SignalKit.BusScope
local function newScope(bus)
  return setmetatable({
    _bus = bus,
    _connections = {},
    _count = 0,
    _dead = 0,
    _closed = false,
  }, SCOPE_METATABLE)
end

---Drop the entries of connections that are no longer connected.
---@param scope SignalKit.BusScope
local function compactScope(scope)
  local connections = rawget(scope, "_connections")
  local count = rawget(scope, "_count")
  local live = 0
  for index = 1, count do
    local connection = connections[index]
    connections[index] = nil
    if helpers.isLiveHandle(connection) then
      live = live + 1
      connections[live] = connection
    end
  end
  rawset(scope, "_count", live)
  rawset(scope, "_dead", 0)
end

---Count one disconnected entry of `scope`, compacting once dead entries
---outnumber live ones.
---@param scope SignalKit.BusScope
local function noteScopeDisconnect(scope)
  local dead = rawget(scope, "_dead") + 1
  rawset(scope, "_dead", dead)
  if dead * 2 > rawget(scope, "_count") then
    compactScope(scope)
  end
end

---Validate, subscribe through the scope's bus, and remember the connection.
---@param scope any
---@param label string qualified public method name
---@param topic any
---@param callback any a listener, or a receiver table
---@param once boolean
---@param methodName any the receiver's method name; the topic when `nil`
---@return SignalKit.Connection|nil connection
---@return "full"|nil reason
local function scopeSubscribeShared(scope, label, topic, callback, once, methodName)
  validateScope(scope, label, 4)
  if rawget(scope, "_closed") == true then
    error(label .. " cannot subscribe in a closed scope", 3)
  end

  local connection, reason =
    subscribe(rawget(scope, "_bus"), label, 4, topic, callback, once, scope, methodName)
  if connection == nil then
    return nil, reason
  end

  local count = rawget(scope, "_count") + 1
  rawget(scope, "_connections")[count] = connection
  rawset(scope, "_count", count)
  return connection, nil
end

---Subscribe `callback` to `topic` inside this scope.
---@param self SignalKit.BusScope
---@param topic string
---@param callback fun(...: any)|table a listener, or a receiver table
---@param methodName string? the receiver's method; defaults to `topic`
---@return SignalKit.Connection|nil connection
---@return "full"|nil reason
local function scopeSubscribe(self, topic, callback, methodName)
  local connection, reason =
    scopeSubscribeShared(self, "SignalKit.BusScope:Subscribe", topic, callback, false, methodName)
  return connection, reason
end

---Subscribe `callback` to at most one publish of `topic` inside this scope.
---@param self SignalKit.BusScope
---@param topic string
---@param callback fun(...: any)|table a listener, or a receiver table
---@param methodName string? the receiver's method; defaults to `topic`
---@return SignalKit.Connection|nil connection
---@return "full"|nil reason
local function scopeSubscribeOnce(self, topic, callback, methodName)
  local connection, reason = scopeSubscribeShared(
    self,
    "SignalKit.BusScope:SubscribeOnce",
    topic,
    callback,
    true,
    methodName
  )
  return connection, reason
end

---Disconnect every subscription of `scope` in creation order.
---@param scope SignalKit.BusScope
---@return integer disconnected
local function disconnectScope(scope)
  local connections = rawget(scope, "_connections")
  local count = rawget(scope, "_count")
  local disconnected = 0
  for index = 1, count do
    local connection = connections[index]
    connections[index] = nil
    -- Detach first, so this walk is never compacted underneath itself. Only
    -- the field the handle's layout has is written (see "Listener storage").
    if connection[2] ~= nil then
      connection[5] = nil
    elseif rawget(connection, "_busScope") ~= nil then
      rawset(connection, "_busScope", nil)
    end
    if helpers.disconnectConnection(connection) then
      disconnected = disconnected + 1
    end
  end
  rawset(scope, "_count", 0)
  rawset(scope, "_dead", 0)
  return disconnected
end

---Disconnect every subscription while keeping the scope reusable.
---@param self SignalKit.BusScope
---@return integer disconnected
local function scopeDisconnectAll(self)
  validateScope(self, "SignalKit.BusScope:DisconnectAll", 3)
  return disconnectScope(self)
end

---Close the scope, disconnecting everything it owns. Later subscriptions
---raise until its owner calls `Reopen`.
---@param self SignalKit.BusScope
---@return boolean closed `false` when the scope was already closed.
local function scopeClose(self)
  validateScope(self, "SignalKit.BusScope:Close", 3)
  if rawget(self, "_closed") == true then
    return false
  end
  rawset(self, "_closed", true)
  disconnectScope(self)
  return true
end

---Return whether the scope is closed.
---@param self SignalKit.BusScope
---@return boolean closed
local function scopeIsClosed(self)
  validateScope(self, "SignalKit.BusScope:IsClosed", 3)
  return rawget(self, "_closed") == true
end

---Open a closed scope again, empty, so its owner can reuse the same object.
---
---Its subscriptions were disconnected by `Close` and stay disconnected. A
---scope whose bus is closed stays closed: an addon's bus closes at logout, and
---nothing may subscribe on it again.
---@param self SignalKit.BusScope
---@return boolean reopened `false` when the scope was open, or its bus is closed.
---@return "closed"|nil reason `"closed"` when the bus is closed.
local function scopeReopen(self)
  validateScope(self, "SignalKit.BusScope:Reopen", 3)
  if rawget(self, "_closed") ~= true then
    return false, nil
  end
  if rawget(rawget(self, "_bus"), "_closed") == true then
    return false, "closed"
  end
  rawset(self, "_closed", false)
  return true, nil
end

---Create an ownership scope for subscriptions on this bus.
---@param self SignalKit.Bus
---@return SignalKit.BusScope scope
local function busCreateScope(self)
  validateBus(self, "SignalKit.Bus:CreateScope", 3)
  if rawget(self, "_closed") == true then
    error(
      'SignalKit.Bus:CreateScope cannot create a scope on the closed bus "'
        .. rawget(self, "_name")
        .. '"',
      2
    )
  end
  return newScope(self)
end

-- Logout close -----------------------------------------------------------------
--
-- SignalKit never observes logout itself and depends on neither LifecycleKit
-- nor EventKit (design constitution, principle 4b). What it does instead is
-- make sure that somebody who does observe logout closes each addon's bus,
-- whichever revisions of the other Kits are loaded. `ForAddon` asks, in this
-- order:
--
--   (a) LifecycleKit is registered and its `CLOSES_ADDON_SCOPES` names
--       "signalKit": it closes the bus after the addon's shutdown callbacks.
--       SignalKit only makes sure the addon has a LifecycleKit instance,
--       because LifecycleKit closes the buses of the addons it tracks.
--   (b) LifecycleKit is registered without that field (an older revision):
--       SignalKit subscribes to the addon's `OnShutdown` and closes the bus
--       from there. The subscription is kept on the bus, so closing the bus
--       earlier disconnects it.
--   (c) no LifecycleKit, but EventKit: one package-level `PLAYER_LOGOUT`
--       watcher, in SignalKit's own EventKit scope, closes the addon buses
--       that nobody else closes.
--   (d) neither: nothing is arranged, and the consumer calls
--       `SignalKit:CloseAddonBus(addonName)` itself on `PLAYER_LOGOUT`.
--
-- Outcomes (c) and (d) are asked again by every later `ForAddon`, so a
-- LifecycleKit that loads after the first call still takes the bus over. A
-- bus obtained only through `SignalKit:Bus` is never closed at logout.
--
-- The functions are fields of one table, as in the other scope-owning Kits.

local LogoutClose = {}

---Find an optional package through `Registry:Find`, or `nil` when it is not
---registered (or the Registry revision has no `Find`).
---@param packageName string
---@param api integer
---@return table|nil
function LogoutClose.findOptional(packageName, api)
  local findPackage = rawget(Registry, "Find")
  if type(findPackage) ~= "function" then
    return nil
  end
  local found = findPackage(Registry, packageName, api)
  if type(found) == "table" then
    return found
  end
  return nil
end

---Whether `LifecycleKit` announces that it closes SignalKit's addon buses.
---
---The field is a read-only table, so it is indexed normally rather than with
---`rawget`: a proxy answers through `__index`. A revision without the field
---closes none.
---@param LifecycleKit table
---@return boolean
function LogoutClose.lifecycleClosesBuses(LifecycleKit)
  local closes = rawget(LifecycleKit, "CLOSES_ADDON_SCOPES")
  return type(closes) == "table" and closes[PACKAGE_NAME] == true
end

---Make the package-level `PLAYER_LOGOUT` watcher exist, once per session.
---
---The watcher lives in SignalKit's own EventKit scope and calls through a
---trampoline kept in state, which looks up `logoutWatch.close`, so a newer
---SignalKit revision replaces what an older revision's watcher does.
---@param EventKit table
function LogoutClose.ensureWatch(EventKit)
  if rawget(logoutWatch, "connection") ~= false then
    return
  end
  local trampoline = rawget(logoutWatch, "trampoline")
  if trampoline == false then
    trampoline = function()
      rawget(logoutWatch, "close")()
    end
    rawset(logoutWatch, "trampoline", trampoline)
  end
  local eventScope = rawget(logoutWatch, "scope")
  if eventScope == false or eventScope:IsClosed() then
    eventScope = EventKit:CreateScope()
    rawset(logoutWatch, "scope", eventScope)
  end
  rawset(logoutWatch, "connection", eventScope:Once("PLAYER_LOGOUT", trampoline))
end

---Subscribe to the addon's LifecycleKit shutdown and close its bus there.
---
---The callback calls the facade method, so the SignalKit revision loaded at
---logout does the closing.
---@param LifecycleKit table
---@param addonName string
---@return table subscription LifecycleKit subscription handle
function LogoutClose.subscribeShutdown(LifecycleKit, addonName)
  local instance = LifecycleKit:ForAddon(addonName)
  return instance:OnShutdown(function()
    SignalKit:CloseAddonBus(addonName)
  end)
end

---Arrange, once, who closes the addon bus `bus` at logout.
---
---Does nothing for a closed bus, and nothing once LifecycleKit has taken the
---bus over; see the section comment for the four outcomes.
---@param addonName string
---@param bus SignalKit.Bus
function LogoutClose.arrange(addonName, bus)
  local closer = rawget(bus, "_logoutCloser")
  if closer ~= LOGOUT.byNobody and closer ~= LOGOUT.byEvent then
    return
  end
  if rawget(bus, "_closed") == true then
    return
  end

  local LifecycleKit = LogoutClose.findOptional("lifecycleKit", LOGOUT.lifecycleKitApi)
  if LifecycleKit ~= nil then
    if LogoutClose.lifecycleClosesBuses(LifecycleKit) then
      LifecycleKit:ForAddon(addonName)
      rawset(bus, "_logoutCloser", LOGOUT.byLifecycle)
    else
      local subscription = LogoutClose.subscribeShutdown(LifecycleKit, addonName)
      rawset(bus, "_shutdownSubscription", subscription)
      rawset(bus, "_logoutCloser", LOGOUT.byShutdownCallback)
    end
    return
  end

  if closer == LOGOUT.byEvent then
    return
  end
  local EventKit = LogoutClose.findOptional("eventKit", LOGOUT.eventKitApi)
  if EventKit ~= nil then
    LogoutClose.ensureWatch(EventKit)
    rawset(bus, "_logoutCloser", LOGOUT.byEvent)
  end
end

---Take `bus` for the addon bus of `addonName` and arrange its logout close,
---without letting a failure in another Kit break the caller: the failure goes
---to the host error handler and the bus stays undecided, so the next
---`ForAddon` asks again.
---@param addonName string
---@param bus SignalKit.Bus
function LogoutClose.arrangeProtected(addonName, bus)
  local closer = rawget(bus, "_logoutCloser")
  if closer == false or closer == nil then
    rawset(bus, "_logoutCloser", LOGOUT.byNobody)
    rawset(bus, "_shutdownSubscription", false)
  end
  local ok, failure = pcall(LogoutClose.arrange, addonName, bus)
  if not ok then
    reportError(failure)
  end
end

---Disconnect the `OnShutdown` subscription of an addon bus, if it has one.
---
---Called when the bus closes: a bus closed before logout needs no shutdown
---callback, and one closing from inside that callback finds it already
---delivered.
---@param bus SignalKit.Bus
function LogoutClose.releaseSubscription(bus)
  local subscription = rawget(bus, "_shutdownSubscription")
  if subscription == nil or subscription == false then
    return
  end
  rawset(bus, "_shutdownSubscription", false)
  subscription:Disconnect()
end

---The `PLAYER_LOGOUT` watcher's work: close every addon bus nobody else
---closes, in name order so the outcome does not depend on hash order.
---
---A bus LifecycleKit took over (outcomes a and b) is left to it, so its
---shutdown callbacks still run first. Every close is attempted; each failure
---goes to the host error handler.
function LogoutClose.closeAtLogout()
  local names = {}
  for name, bus in pairs(rawget(state, "buses")) do
    local closer = rawget(bus, "_logoutCloser")
    if closer == LOGOUT.byEvent or closer == LOGOUT.byNobody then
      names[#names + 1] = name
    end
  end
  table.sort(names)
  for index = 1, #names do
    local ok, failure = pcall(SignalKit.CloseAddonBus, SignalKit, names[index])
    if not ok then
      reportError(failure)
    end
  end
end

---Arrange the logout close of every open addon bus an upgrade inherited, in
---name order, rather than waiting for a `ForAddon` call the addon may never
---make again. Buses a revision before 6 created are not known to be addon
---buses and wait for their `ForAddon`.
function LogoutClose.arrangeInherited()
  local names = {}
  for name, bus in pairs(rawget(state, "buses")) do
    local closer = rawget(bus, "_logoutCloser")
    if closer ~= false and closer ~= nil and rawget(bus, "_closed") ~= true then
      names[#names + 1] = name
    end
  end
  table.sort(names)
  for index = 1, #names do
    LogoutClose.arrangeProtected(names[index], rawget(rawget(state, "buses"), names[index]))
  end
end

-- Facade methods ---------------------------------------------------------------

---The options a `SignalKit:Bus` call stated. A field is `nil` when the caller
---did not state it.
---@class SignalKit.StatedBusOptions
---@field openTopics boolean|nil
---@field maxTopics integer|table|nil
---@field maxListeners integer|table|nil

---Validate one per-bus limit option: a positive integer or `UNBOUNDED`.
---@param value any
---@param name string option name, for the message
---@param level integer stack level the failure is reported at
local function validateBusLimit(value, name, level)
  if type(value) == "nil" then
    return
  end
  helpers.refuseSecret(value, "SignalKit:Bus options." .. name, level + 1)
  if value ~= UNBOUNDED and not helpers.isIntegerUpTo(value, math.huge) then
    error(
      "SignalKit:Bus options." .. name .. " must be a positive integer or SignalKit.UNBOUNDED",
      level
    )
  end
end

---Validate a `SignalKit:Bus` options table.
---@param options any
---@param level integer stack level the failures are reported at
---@return boolean|nil openTopics `nil` when the caller did not state one.
---@return integer|table|nil maxTopics `nil` when the caller did not state one.
---@return integer|table|nil maxListeners `nil` when the caller did not state one.
local function readBusOptions(options, level)
  if type(options) == "nil" then
    return nil, nil, nil
  end
  if type(options) ~= "table" then
    error("SignalKit:Bus options must be a table or nil", level)
  end
  local openTopics = rawget(options, "openTopics")
  helpers.refuseSecret(openTopics, "SignalKit:Bus options.openTopics", level + 1)
  if type(openTopics) ~= "nil" and type(openTopics) ~= "boolean" then
    error("SignalKit:Bus options.openTopics must be a boolean or nil", level)
  end
  local maxTopics = rawget(options, "maxTopics")
  validateBusLimit(maxTopics, "maxTopics", level + 1)
  local maxListeners = rawget(options, "maxListeners")
  validateBusLimit(maxListeners, "maxListeners", level + 1)
  return openTopics, maxTopics, maxListeners
end

---Whether a caller stating `value` for `limitName` disagrees with what an
---earlier caller stated for the existing `bus`.
---
---A bus created without stating a limit carries the default; the first caller
---that states it sets it, whichever order the addons load in. A second,
---different statement is refused at the caller, because two owners
---disagreeing about a shared bus is a mistake one of them has to see.
---@param bus SignalKit.Bus
---@param limitName "maxTopics"|"maxListeners"
---@param value integer|table|nil
---@return boolean
local function conflictsWithStatedLimit(bus, limitName, value)
  return type(value) ~= "nil"
    and rawget(bus, "_" .. limitName .. "Stated") == true
    and rawget(bus, "_" .. limitName) ~= value
end

---Record `value` as the stated `limitName` of `bus` when the caller stated one.
---@param bus SignalKit.Bus
---@param limitName "maxTopics"|"maxListeners"
---@param value integer|table|nil
local function applyStatedLimit(bus, limitName, value)
  if type(value) ~= "nil" then
    rawset(bus, "_" .. limitName, value)
    rawset(bus, "_" .. limitName .. "Stated", true)
  end
end

---Return the bus called `name`, creating it on the first request.
---@param name string
---@param openTopics boolean|nil
---@param maxTopics integer|table|nil
---@param maxListeners integer|table|nil
---@param label string qualified public method name
---@param level integer stack level the failures are reported at
---@return SignalKit.Bus|nil bus
---@return "full"|nil reason
local function obtainBus(name, openTopics, maxTopics, maxListeners, label, level)
  local buses = rawget(state, "buses")
  local bus = rawget(buses, name)
  if bus ~= nil then
    if type(openTopics) ~= "nil" and openTopics ~= rawget(bus, "_openTopics") then
      error(
        label .. ' bus "' .. name .. '" already exists with a different openTopics policy',
        level
      )
    end
    -- Both statements are checked before either is applied, so a refused
    -- call changes nothing.
    if conflictsWithStatedLimit(bus, "maxTopics", maxTopics) then
      error(label .. ' bus "' .. name .. '" already exists with a different maxTopics', level)
    end
    if conflictsWithStatedLimit(bus, "maxListeners", maxListeners) then
      error(label .. ' bus "' .. name .. '" already exists with a different maxListeners', level)
    end
    applyStatedLimit(bus, "maxTopics", maxTopics)
    applyStatedLimit(bus, "maxListeners", maxListeners)
    return bus, nil
  end

  local count = rawget(state, "busCount")
  if count >= rawget(sharedLimits, "maxBuses") then
    return nil, "full"
  end

  bus = setmetatable({
    _name = name,
    _openTopics = openTopics == true,
    _closed = false,
    _topics = {},
    _topicCount = 0,
    _maxTopics = maxTopics or DEFAULT_MAX_TOPICS,
    _maxTopicsStated = type(maxTopics) ~= "nil",
    _maxListeners = maxListeners or DEFAULT_MAX_LISTENERS,
    _maxListenersStated = type(maxListeners) ~= "nil",
    -- See "Logout close": `false` until `ForAddon` names this bus.
    _logoutCloser = false,
    _shutdownSubscription = false,
  }, BUS_METATABLE)
  rawset(buses, name, bus)
  rawset(state, "busCount", count + 1)
  return bus, nil
end

---Return the named bus shared by everything in the session that asks for
---`name`, creating it on the first request.
---@param self SignalKit
---@param name string
---@param options SignalKit.BusOptions?
---@return SignalKit.Bus|nil bus `nil` when `maxBuses` buses already exist.
---@return "full"|nil reason
local function facadeBus(self, name, options)
  helpers.validateFacade(self, "SignalKit:Bus", 3)
  helpers.validateNonEmptyString(name, "SignalKit:Bus name", 3)
  local openTopics, maxTopics, maxListeners = readBusOptions(options, 3)
  local bus, reason = obtainBus(name, openTopics, maxTopics, maxListeners, "SignalKit:Bus", 3)
  return bus, reason
end

---Return the default bus of an addon: the bus named after it.
---
---SignalKit does not observe addon shutdown, but every call makes sure
---somebody who does closes this bus through `SignalKit:CloseAddonBus(addonName)`:
---LifecycleKit, SignalKit's own `PLAYER_LOGOUT` watcher through EventKit, or,
---with neither loaded, the addon itself (docs/API.md, "At logout").
---@param self SignalKit
---@param addonName string addon folder name
---@return SignalKit.Bus|nil bus `nil` when `maxBuses` buses already exist.
---@return "full"|nil reason
local function facadeForAddon(self, addonName)
  helpers.validateFacade(self, "SignalKit:ForAddon", 3)
  helpers.validateNonEmptyString(addonName, "SignalKit:ForAddon addonName", 3)
  local bus, reason = obtainBus(addonName, nil, nil, nil, "SignalKit:ForAddon", 3)
  if bus ~= nil then
    LogoutClose.arrangeProtected(addonName, bus)
  end
  return bus, reason
end

---Close the bus named after an addon, disconnecting every subscription on it:
---the work behind `SignalKit:CloseAddonBus`, which has checked its arguments.
---
---Closing is terminal: the closed bus stays registered under its name, refuses
---new subscriptions and scopes, and publishes on it deliver nothing.
---@param addonName string addon folder name
---@return boolean closed `false` when there was no such bus or it was already closed.
local function closeAddonBus(addonName)
  local bus = rawget(rawget(state, "buses"), addonName)
  if bus == nil or rawget(bus, "_closed") == true then
    return false
  end

  rawset(bus, "_closed", true)
  LogoutClose.releaseSubscription(bus)
  for _, record in pairs(rawget(bus, "_topics")) do
    local signal = rawget(record, "signal")
    if signal ~= false then
      helpers.disconnectEveryListener(signal, rawget(signal, "_listeners"))
    end
  end
  return true
end

-- Commit -----------------------------------------------------------------------

local busMethods = {
  DeclareTopic = busDeclareTopic,
  Publish = busPublish,
  Subscribe = busSubscribe,
  SubscribeOnce = busSubscribeOnce,
  Unsubscribe = busUnsubscribe,
  Topics = busTopics,
  CreateScope = busCreateScope,
}
local scopeMethods = {
  Subscribe = scopeSubscribe,
  SubscribeOnce = scopeSubscribeOnce,
  DisconnectAll = scopeDisconnectAll,
  Close = scopeClose,
  IsClosed = scopeIsClosed,
  Reopen = scopeReopen,
}
local facadeMethods = { Bus = facadeBus, ForAddon = facadeForAddon }

rawset(parts, PART_NAME, {
  revision = PART_REVISION,
  facadeMethods = facadeMethods,
  busMethods = busMethods,
  scopeMethods = scopeMethods,
  fireIsolated = fireIsolated,
  noteScopeDisconnect = noteScopeDisconnect,
  closeAddonBus = closeAddonBus,
  arrangeInherited = LogoutClose.arrangeInherited,
})
for name, method in next, facadeMethods do
  rawset(SignalKit, name, method)
end
for name, method in next, busMethods do
  rawset(BUS_PROTOTYPE, name, method)
end
for name, method in next, scopeMethods do
  rawset(SCOPE_PROTOTYPE, name, method)
end

-- The dispatch of an isolated bus topic signal and the logout watcher read
-- these from the state, so this part's revision serves what already exists.
rawset(state, "isolate", isolate)
rawset(logoutWatch, "close", LogoutClose.closeAtLogout)

-- Buses an older revision left wait for this part (the core's "Parts"); the
-- first revision of the part to load arranges their logout close, as an
-- in-place upgrade always did.
if installed == nil and rawget(state, "inheritedBuses") == true then
  LogoutClose.arrangeInherited()
end

return SignalKit
