-- MoltenCodes SignalKit part Coalescing
--
-- Bucketed bus messages, AceBucket-3.0's `RegisterBucketMessage`:
--
--   bus:Coalesce(topics, intervalSeconds, callback[, options])
--   bus:Coalesce(topics, intervalSeconds, receiver, methodName[, options])
--   scope:Coalesce(...)          the same on a bus scope, released with it
--
-- The first message of a burst starts the interval; at its end
-- `callback(set)` runs once with everything collected, keyed by each
-- message's first argument (or its topic). These are the semantics of
-- EventKit's `Coalesce` over game events; the family is documented once, in
-- SchedulerKit's docs/API.md under "Coalescing and lanes". SignalKit supplies
-- the subscriptions and SchedulerKit the timing: each handle is a SchedulerKit
-- `Coalesce` handle fed by one bus subscription per topic.
--
-- SchedulerKit is found through `Registry:Find` when a handle is created; the
-- manifest names it as this part's dependency, so a generated embeds.xml
-- brings it along. The part needs SignalKit's Bus part (revision 2 and later):
-- it subscribes through the bus methods that part provides, and refuses to
-- load without it.
--
-- Contents
-- --------
--   Public types ..... LuaCATS declarations for Coalesce and its handle
--   Constants ........ identity, bounds, option fields
--   Dependencies ..... SignalKit's core and state, SchedulerKit, host readers
--   Arguments ........ receivers, topics, interval, callback, options
--   Handles .......... the handle methods and the delivery
--   Creating ......... Coalesce on a bus and on a bus scope
--   Commit ........... the part's record and methods

-- Public types ---------------------------------------------------------------

---Options accepted by `Coalesce`.
---@class SignalKit.CoalesceOptions
---@field byTopic boolean? Key the set by topic instead of the first argument.
---@field maxKeys integer? Distinct keys one interval may collect; SchedulerKit's default is 256.
---@field lane table? A SchedulerKit lane (`SchedulerKit:Lane`) to deliver through.

---What `Coalesce` returns.
---@class SignalKit.CoalesceHandle
---@field Flush fun(self: SignalKit.CoalesceHandle): boolean, string?
---@field IsPending fun(self: SignalKit.CoalesceHandle): boolean
---@field GetStats fun(self: SignalKit.CoalesceHandle): table<string, integer>
---@field Close fun(self: SignalKit.CoalesceHandle): boolean
---@field IsClosed fun(self: SignalKit.CoalesceHandle): boolean

---@class SignalKit.Bus
---@field Coalesce fun(self: SignalKit.Bus, topics: string|string[], intervalSeconds: number, callback: (fun(set: table<any, true>))|table, methodNameOrOptions: string|SignalKit.CoalesceOptions|nil, options: SignalKit.CoalesceOptions?): SignalKit.CoalesceHandle|nil, "full"?

---@class SignalKit.BusScope
---@field Coalesce fun(self: SignalKit.BusScope, topics: string|string[], intervalSeconds: number, callback: (fun(set: table<any, true>))|table, methodNameOrOptions: string|SignalKit.CoalesceOptions|nil, options: SignalKit.CoalesceOptions?): SignalKit.CoalesceHandle|nil, "full"?

-- Constants ------------------------------------------------------------------

local PART_NAME = "Coalescing"
local PART_REVISION = 2
local REQUIRED_REGISTRY_API = 2
local CORE_PACKAGE, CORE_API = "signalKit", 1
local SCHEDULERKIT_API = 1

-- One Coalesce call listens to at most this many distinct topics, as
-- EventKit's does to events: every topic costs a subscription.
local MAX_TOPICS = 32

-- The option fields `Coalesce` accepts.
local OPTION_FIELDS = { byTopic = true, maxKeys = true, lane = true }

-- Dependencies ---------------------------------------------------------------

-- The shared MoltenCodes namespace is the one documented global handoff point between independently embedded copies.
-- selene: allow(global_usage)
local namespace = rawget(_G, "MoltenCodes")
local generations = type(namespace) == "table" and rawget(namespace, "Registries") or nil
local Registry = type(generations) == "table" and rawget(generations, REQUIRED_REGISTRY_API) or nil
local SignalKit = nil
if type(Registry) == "table" and type(rawget(Registry, "Get")) == "function" then
  SignalKit = Registry:Get(CORE_PACKAGE, CORE_API)
end
local state = type(SignalKit) == "table" and rawget(SignalKit, "_state") or nil
if
  type(state) ~= "table"
  or type(rawget(state, "parts")) ~= "table"
  or type(rawget(state, "busPrototype")) ~= "table"
  or type(rawget(state, "scopePrototype")) ~= "table"
then
  error("MoltenCodes SignalKit part Coalescing requires SignalKit API 1 to be loaded first", 2)
end
if type(rawget(rawget(state, "parts"), "Bus")) ~= "table" then
  error(
    "MoltenCodes SignalKit part Coalescing requires SignalKit's Bus part to be loaded first: add "
      .. "signalKit\\parts\\SignalKit-Bus.lua to embeds.xml before this part",
    2
  )
end

local parts = rawget(state, "parts")
local installed = rawget(parts, PART_NAME)
if
  type(installed) == "table"
  and type(installed.revision) == "number"
  and installed.revision >= PART_REVISION
then
  -- An equal or newer revision of this part already serves every bus.
  return SignalKit
end

-- Buses and scopes are recognised by the metatables SignalKit keeps in its
-- state for every revision.
local BUS_METATABLE = rawget(state, "busMetatable")
local SCOPE_METATABLE = rawget(state, "scopeMetatable")

-- What the part keeps across its own revisions: the handle metatable (handles
-- are recognised by it), the SchedulerKit facade once found, and the one
-- SchedulerKit scope every handle's timing lives in.
local partState = type(installed) == "table" and installed or {}
if type(partState.handleMetatable) ~= "table" then
  partState.handleMetatable = {}
end
local HANDLE_METATABLE = partState.handleMetatable
local handleMethods = {}

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

---The SchedulerKit facade, when one with coalescing is registered. A found
---facade is kept (Registry hands every compatible revision the same table); a
---miss is not, so a SchedulerKit loaded later is found.
---@return table|nil SchedulerKit
local function findSchedulerKit()
  local found = partState.schedulerKit
  if type(found) == "table" then
    return found
  end
  local find = rawget(Registry, "Find")
  if type(find) ~= "function" then
    return nil
  end
  local SchedulerKit = find(Registry, "schedulerKit", SCHEDULERKIT_API)
  if type(SchedulerKit) ~= "table" or type(rawget(SchedulerKit, "CreateScope")) ~= "function" then
    return nil
  end
  local prototype = rawget(SchedulerKit, "Scope")
  if type(prototype) ~= "table" or type(rawget(prototype, "Coalesce")) ~= "function" then
    return nil
  end
  partState.schedulerKit = SchedulerKit
  return SchedulerKit
end

-- Arguments ------------------------------------------------------------------

---Name a caller's table key in a refusal without running its `__tostring`: the
---core's shared `describeKey`, read from `_state.helpers` at call time.
---@param key any
---@return string
local function describeOptionKey(key)
  return rawget(state, "helpers").describeKey(key)
end

---Check one topic, raising at the caller of `Coalesce`.
---@param topic any
---@param label string
local function checkTopic(topic, label)
  if isSecret(topic) then
    error(label .. " topics must not be secret values", 5)
  end
  if type(topic) ~= "string" or topic == "" then
    error(label .. " topics must be non-empty strings", 5)
  end
end

---The distinct topics of `topics` (a topic or an array of them), in order.
---@param topics any
---@param label string
---@return string[]
local function readTopics(topics, label)
  if type(topics) == "string" or isSecret(topics) then
    checkTopic(topics, label)
    return { topics }
  end
  if type(topics) ~= "table" then
    error(label .. " topics must be a topic or an array of topics", 4)
  end
  local list, seen = {}, {}
  for index = 1, #topics do
    local topic = topics[index]
    checkTopic(topic, label)
    if not seen[topic] then
      seen[topic] = true
      list[#list + 1] = topic
    end
  end
  if #list == 0 then
    error(label .. " topics must name at least one topic", 4)
  end
  if #list > MAX_TOPICS then
    error(label .. " topics must name at most " .. MAX_TOPICS .. " distinct topics", 4)
  end
  return list
end

---Check the interval, raising at the caller of `Coalesce`.
---@param interval any
---@param label string
local function checkInterval(interval, label)
  if
    isSecret(interval)
    or type(interval) ~= "number"
    or interval ~= interval
    or interval < 0
    or interval == math.huge
  then
    error(label .. " intervalSeconds must be a finite number of zero or more", 4)
  end
end

---Read the callback forms: a function and options, or a receiver, a method
---name and options. The method must exist now (ADR 0003).
---@param callback any
---@param second any the method name, or the options
---@param third any the options of the receiver form
---@param label string
---@return function|table callback
---@return string|nil methodName
---@return any options
local function readCallback(callback, second, third, label)
  if isSecret(callback) then
    error(label .. " callback must not be a secret value", 4)
  end
  if type(callback) == "function" then
    return callback, nil, second
  end
  if type(callback) ~= "table" then
    error(label .. " callback must be a function, or a receiver table followed by a method name", 4)
  end
  if isSecret(second) then
    error(label .. " methodName must not be a secret value", 4)
  end
  if type(second) ~= "string" or second == "" then
    error(label .. " methodName must be a non-empty string", 4)
  end
  if type(callback[second]) ~= "function" then
    error(label .. ' receiver has no method "' .. second .. '"', 4)
  end
  return callback, second, third
end

---Check the options table and return the SchedulerKit options and `byTopic`.
---@param options any
---@param label string
---@return table|nil schedulerOptions
---@return boolean byTopic
local function readOptions(options, label)
  if options == nil then
    return nil, false
  end
  if type(options) ~= "table" or getmetatable(options) ~= nil then
    error(label .. " options must be a table", 4)
  end
  for key in next, options do
    if isSecret(key) or type(key) ~= "string" or not OPTION_FIELDS[key] then
      local name = isSecret(key) and "<secret>" or describeOptionKey(key)
      error(label .. ' options contains unknown field "' .. name .. '"', 4)
    end
  end
  local byTopic = rawget(options, "byTopic")
  if byTopic ~= nil and type(byTopic) ~= "boolean" then
    error(label .. " options.byTopic must be a boolean", 4)
  end
  local maxKeys = rawget(options, "maxKeys")
  local lane = rawget(options, "lane")
  if maxKeys == nil and lane == nil then
    return nil, byTopic == true
  end
  return { maxKeys = maxKeys, lane = lane }, byTopic == true
end

-- Handles --------------------------------------------------------------------

---Disconnect a handle's subscriptions and close its timing.
---@param handle table
local function releaseHandle(handle)
  handle._closed = true
  local connections = handle._connections
  for index = 1, #connections do
    connections[index]:Disconnect()
  end
  handle._coalesce:Close()
end

---Whether the owner let the handle go: its bus or scope disconnected the
---subscriptions. A handle found so is released, lazily, here.
---@param handle table
---@return boolean released
local function releaseIfAbandoned(handle)
  if handle._closed then
    return true
  end
  if handle._connections[1]:IsConnected() then
    return false
  end
  releaseHandle(handle)
  return true
end

---The delivery SchedulerKit calls at the end of an interval.
---@param handle table
---@param set table
local function deliver(handle, set)
  if releaseIfAbandoned(handle) then
    return
  end
  local ok, failure
  local methodName = handle._methodName
  if methodName ~= nil then
    local receiver = handle._callback
    ok, failure = pcall(receiver[methodName], receiver, set)
  else
    ok, failure = pcall(handle._callback, set)
  end
  if not ok then
    reportError(failure)
  end
end

---Deliver now. `false` when nothing was collected or the handle is closed;
---SchedulerKit's `false, "deferred"` or `false, "dropped"` with a lane.
---@param self table
---@return boolean delivered
---@return string|nil reason
function handleMethods.Flush(self)
  if releaseIfAbandoned(self) then
    return false
  end
  local delivered, reason = self._coalesce:Flush()
  return delivered, reason
end

---Whether messages wait for delivery.
---@param self table
---@return boolean
function handleMethods.IsPending(self)
  if self._closed then
    return false
  end
  return self._coalesce:IsPending()
end

---SchedulerKit's `{ keys, refused, delivered, deferred, dropped }`, in a
---table reused by every call.
---@param self table
---@return table<string, integer>
function handleMethods.GetStats(self)
  return self._coalesce:GetStats()
end

---Unsubscribe, drop what was collected and stop. Terminal; `false` when the
---handle was already closed.
---@param self table
---@return boolean closed
function handleMethods.Close(self)
  if self._closed then
    return false
  end
  releaseHandle(self)
  return true
end

---Whether the handle is closed.
---@param self table
---@return boolean
function handleMethods.IsClosed(self)
  return self._closed == true
end

-- Creating -------------------------------------------------------------------

---The listener of one topic: key the message and hand it to the timing.
---@param coalesce table SchedulerKit's coalesce handle
---@param topic string
---@param byTopic boolean
---@return function listener
local function newListener(coalesce, topic, byTopic)
  return function(first)
    local key = first
    -- A secret cannot be a table key (ADR 0002), a `nil` or NaN cannot
    -- either; each is keyed by its topic, as EventKit keys by event name.
    if
      byTopic
      or type(first) == "nil"
      or isSecret(first)
      or (type(first) == "number" and first ~= first)
    then
      key = topic
    end
    coalesce(key)
  end
end

---Build a handle subscribing through `subscriber`, a bus or a scope of one.
---@param subscriber table
---@param label string
---@param topics any
---@param interval any
---@param callback any
---@param second any
---@param third any
---@return table|nil handle
---@return "full"|nil reason
local function createHandle(subscriber, label, topics, interval, callback, second, third)
  local topicList = readTopics(topics, label)
  checkInterval(interval, label)
  local target, methodName, options = readCallback(callback, second, third, label)
  local schedulerOptions, byTopic = readOptions(options, label)
  local SchedulerKit = findSchedulerKit()
  if SchedulerKit == nil then
    error(label .. " needs SchedulerKit API 1 with Coalesce, which is not loaded", 3)
  end
  local schedulerScope = partState.schedulerScope
  if type(schedulerScope) ~= "table" or schedulerScope:IsClosed() then
    schedulerScope = SchedulerKit:CreateScope()
    partState.schedulerScope = schedulerScope
  end

  local handle = setmetatable({
    _callback = target,
    _methodName = methodName,
    _connections = {},
    _closed = false,
    _coalesce = false,
  }, HANDLE_METATABLE)
  local made, coalesce = pcall(schedulerScope.Coalesce, schedulerScope, function(set)
    deliver(handle, set)
  end, interval, schedulerOptions)
  if not made then
    -- SchedulerKit refused an option; report it at the caller's line.
    local message = tostring(coalesce):gsub("^[^:]+:%d+: ", "")
    error(label .. ": " .. message, 3)
  end
  handle._coalesce = coalesce

  local connections = handle._connections
  for index = 1, #topicList do
    local topic = topicList[index]
    local connection, reason = subscriber:Subscribe(topic, newListener(coalesce, topic, byTopic))
    if connection == nil then
      releaseHandle(handle)
      return nil, reason
    end
    connections[index] = connection
  end
  return handle
end

---Collect a burst of `topics` published on this bus and deliver it once per
---interval.
---@param self table a SignalKit bus
---@return table|nil handle
---@return "full"|nil reason
local function busCoalesce(self, topics, interval, callback, second, third)
  local label = "SignalKit.Bus:Coalesce"
  if getmetatable(self) ~= BUS_METATABLE then
    error(label .. " must be called on a SignalKit bus with a colon call", 2)
  end
  if rawget(self, "_closed") == true then
    error(label .. ' cannot subscribe on the closed bus "' .. rawget(self, "_name") .. '"', 2)
  end
  local handle, reason = createHandle(self, label, topics, interval, callback, second, third)
  return handle, reason
end

---As `bus:Coalesce`, with the subscriptions owned by this scope, so its
---`Close` or `DisconnectAll` stops the handle.
---@param self table a SignalKit bus scope
---@return table|nil handle
---@return "full"|nil reason
local function scopeCoalesce(self, topics, interval, callback, second, third)
  local label = "SignalKit.BusScope:Coalesce"
  if getmetatable(self) ~= SCOPE_METATABLE then
    error(label .. " must be called on a SignalKit bus scope", 2)
  end
  if rawget(self, "_closed") == true then
    error(label .. " cannot subscribe in a closed scope", 2)
  end
  local handle, reason = createHandle(self, label, topics, interval, callback, second, third)
  return handle, reason
end

-- Commit ---------------------------------------------------------------------

rawset(HANDLE_METATABLE, "__index", handleMethods)
partState.revision = PART_REVISION
partState.methods = { BusCoalesce = busCoalesce, ScopeCoalesce = scopeCoalesce }
rawset(parts, PART_NAME, partState)
rawset(rawget(state, "busPrototype"), "Coalesce", busCoalesce)
rawset(rawget(state, "scopePrototype"), "Coalesce", scopeCoalesce)

return SignalKit
