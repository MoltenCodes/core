-- MoltenCodes EventKit part CombatLog
--
-- `ConnectCombatLog`: the combat log read once per event and routed by
-- sub-event (docs/API.md, "EventKit:ConnectCombatLog").
--
-- `COMBAT_LOG_EVENT_UNFILTERED` is the highest-frequency event in the client
-- and carries no payload: every listener would otherwise call
-- `CombatLogGetCurrentEventInfo()` itself and test the sub-event it wants. The
-- router is one listener on that event's ordinary channel, so it shares the
-- host registration with plain `Connect` listeners and holds it only while a
-- combat-log listener exists. Per event it reads the client once, looks up the
-- sub-event's route and fires it with the returns unchanged, then the wildcard
-- route. A sub-event nobody listens for costs the read and one lookup.
--
-- The router's listener runs through the same isolation as any listener, so a
-- client read that raises is reported and the plain `Connect` listeners behind
-- the router on the channel still receive the event. Each route listener is
-- then isolated individually, exactly as a `Connect` listener is. The extra
-- isolated call stages no arguments and allocates nothing per event. A route
-- keeps its connections exactly as a channel does, and is delivered by the
-- core's walk.
--
-- Whether the client has a reader at all stays in the core
-- (`IsCombatLogAvailable`): Retail 12 gives addon code none, and an addon
-- there should not have to embed this part to learn that.
--
-- The part needs EventKit's core loaded first (docs/decisions/
-- 0001-kit-core-and-parts.md). The router and its routes live in the core's
-- state (`state.combatLog`); the router's listener resolves
-- `state.dispatchCombatLog` and a route connection's release
-- `state.dispatch.releaseRoute`, both filled here, so a higher revision of the
-- part takes over a live router in place, and the one an EventKit revision 22
-- attached (when the combat log was in its core) as well.
--
-- Contents
-- --------
--   Constants ........ identity, the event, the wildcard
--   Dependencies ..... EventKit's core and its state
--   Routing .......... the router, routes and delivery
--   Entry points ..... facade and scope methods
--   Commit ........... members, dispatch entries and the part's revision

-- Constants ------------------------------------------------------------------

local PART_NAME = "CombatLog"
local PART_REVISION = 1
local REQUIRED_REGISTRY_API = 2
local CORE_PACKAGE, CORE_API = "eventKit", 1
-- The core interface this part reads (`state.helpers` entries, the
-- `state.dispatch` entries). EventKit's core publishes the number.
local REQUIRED_PART_INTERFACE = 2

-- The combat-log event and the sub-event name `ConnectCombatLog` accepts for
-- "every sub-event". `*` cannot be a client sub-event name, which are upper-case
-- words joined by underscores, so the wildcard never shadows a real one.
local COMBAT_LOG_EVENT = "COMBAT_LOG_EVENT_UNFILTERED"
local ANY_COMBAT_LOG_SUB_EVENT = "*"

-- Dependencies ---------------------------------------------------------------

-- The shared MoltenCodes namespace is the one documented global handoff point between independently embedded copies.
-- selene: allow(global_usage)
local namespace = rawget(_G, "MoltenCodes")
local generations = type(namespace) == "table" and rawget(namespace, "Registries") or nil
local Registry = type(generations) == "table" and rawget(generations, REQUIRED_REGISTRY_API) or nil
local EventKit = nil
if type(Registry) == "table" and type(rawget(Registry, "Get")) == "function" then
  EventKit = Registry:Get(CORE_PACKAGE, CORE_API)
end
local state = type(EventKit) == "table" and rawget(EventKit, "_state") or nil
local partInterface = type(state) == "table" and rawget(state, "partInterface") or nil
if
  type(state) ~= "table"
  or type(partInterface) ~= "number"
  or partInterface < REQUIRED_PART_INTERFACE
  or type(rawget(state, "parts")) ~= "table"
  or type(rawget(state, "helpers")) ~= "table"
  or type(rawget(state, "dispatch")) ~= "table"
  or type(rawget(state, "combatLog")) ~= "table"
then
  error("MoltenCodes EventKit part CombatLog requires EventKit API 1 to be loaded first", 2)
end

---@cast EventKit table

local parts = state.parts
local installed = parts[PART_NAME]
if
  type(installed) == "table"
  and type(installed.revision) == "number"
  and installed.revision >= PART_REVISION
then
  -- An equal or newer revision of this part already serves every addon.
  return EventKit
end

-- Read at call time, never copied: an upgraded core's helpers serve this part.
local helpers = state.helpers
local Scope = rawget(EventKit, "Scope")

-- Routing --------------------------------------------------------------------

---The one listener the router connects to the combat-log channel. It resolves
---the dispatcher through shared state so a newer revision replaces it while
---the connection an older copy made stays in place.
local function onCombatLogEvent()
  return state.dispatchCombatLog()
end

---Fan one combat-log event out by its sub-event, then to the wildcard route.
---@param combatLog EventKit.CombatLogRouter
---@param ... any every return of `CombatLogGetCurrentEventInfo()`
local function routeCombatLogEvent(combatLog, ...)
  -- The sub-event is the second return. A multiple assignment reads it
  -- without copying the rest of the payload, which `select` would.
  local _, subEvent = ...
  -- The combat-log reader is documented to return secret values. A secret
  -- sub-event cannot index the route table (that raises), so it reaches
  -- the wildcard route only, which receives every event unchanged.
  local route = nil
  if not helpers.isSecret(subEvent) then
    route = combatLog.routes[subEvent]
  end
  -- Both routes are read before either is delivered: a wildcard listener
  -- connected by a sub-event listener must not receive the event being
  -- dispatched, as a listener connected during a `Connect` dispatch does
  -- not. A wildcard route dropped during the first delivery is harmless,
  -- because its connections are already marked disconnected.
  local anyRoute = combatLog.anyRoute
  local deliverListeners = helpers.deliverListeners
  if route ~= nil then
    deliverListeners(route, ...)
  end
  if anyRoute ~= false then
    deliverListeners(anyRoute, ...)
  end
end

---Read the client's current combat-log event once and route it.
local function dispatchCombatLog()
  local combatLog = state.combatLog
  return routeCombatLogEvent(combatLog, combatLog.readEventInfo())
end

---Take the router's share of the combat-log registration.
---
---Called for the first combat-log listener. The reader is resolved here (see
---the core's `findCombatLogReader`) and checked before anything is
---registered, so a client without one refuses at the caller's line and leaves
---nothing behind. The registration itself is refused at the caller too, like
---`Connect`.
---@param combatLog EventKit.CombatLogRouter
---@param label string qualified public method name, used in the argument error
---@param level integer stack level a refusal is reported at
local function attachCombatLogRouter(combatLog, label, level)
  local readEventInfo = helpers.findCombatLogReader()
  if type(readEventInfo) == "nil" then
    error(
      label
        .. " the combat log is not available to addons on this client"
        .. " (no CombatLogGetCurrentEventInfo reader);"
        .. " check EventKit:IsCombatLogAvailable() first",
      level
    )
  end

  local channel = helpers.createRegularChannel(COMBAT_LOG_EVENT, label, level + 1)
  local inner = helpers.connectToChannel(channel, onCombatLogEvent, false, false)

  combatLog.channel = channel
  combatLog.inner = inner
  combatLog.readEventInfo = readEventInfo
end

---Give the router's share of the registration back; the channel unregisters
---the event only when no plain `Connect` listener holds it.
---@param combatLog EventKit.CombatLogRouter
local function detachCombatLogRouter(combatLog)
  local inner = combatLog.inner
  combatLog.channel = false
  combatLog.inner = false
  combatLog.readEventInfo = false
  helpers.disconnectEventConnection(inner)
end

---Return the route for `subEvent`, attaching the router and creating the route
---on demand.
---@param subEvent string a client sub-event name, or `"*"`
---@param label string qualified public method name, used in the argument error
---@param level integer stack level a refused registration is reported at
---@return EventKit.CombatLogRoute
local function acquireCombatLogRoute(subEvent, label, level)
  local combatLog = state.combatLog
  if combatLog.channel == false then
    attachCombatLogRouter(combatLog, label, level + 1)
  end

  local isWildcard = subEvent == ANY_COMBAT_LOG_SUB_EVENT
  local route
  if isWildcard then
    route = combatLog.anyRoute
    if route == false then
      route = nil
    end
  else
    route = combatLog.routes[subEvent]
  end
  if route ~= nil then
    return route
  end

  route = {
    subEvent = subEvent,
    listeners = {},
    tombstones = 0,
    count = 0,
  }
  if isWildcard then
    combatLog.anyRoute = route
  else
    combatLog.routes[subEvent] = route
  end
  return route
end

---Drop one connection from `route`, dropping the route with its last listener
---and detaching the router with the last listener of any route. The core
---calls it, through `state.dispatch.releaseRoute`, when a route connection
---disconnects.
---@param route EventKit.CombatLogRoute
local function releaseCombatLogRoute(route)
  local combatLog = state.combatLog
  local count = route.count - 1
  route.count = count
  local listenerCount = combatLog.listenerCount - 1
  combatLog.listenerCount = listenerCount

  -- Any non-positive count is "empty", so a bookkeeping slip cannot pin a
  -- route or the registration for the session.
  if count <= 0 then
    local subEvent = route.subEvent
    if subEvent == ANY_COMBAT_LOG_SUB_EVENT then
      combatLog.anyRoute = false
    else
      combatLog.routes[subEvent] = nil
    end
  end

  if listenerCount <= 0 and combatLog.channel ~= false then
    detachCombatLogRouter(combatLog)
  end
end

---Sub-event names are the client's (`SPELL_DAMAGE`), plus the `*` wildcard.
---They are not checked against the client, which has no function that knows
---them; a sub-event that never occurs simply never delivers.
---@param subEvent any
---@param label string qualified public method name, used in the argument error
---@param level integer stack level the failure is reported at
local function validateSubEvent(subEvent, label, level)
  helpers.refuseSecret(subEvent, label .. " subEvent", level + 1)
  if type(subEvent) ~= "string" or subEvent == "" then
    error(label .. " subEvent must be a non-empty string", level)
  end
end

---Validate and attach one combat-log subscription. Callers keep the result in
---a local before returning it: a Lua tail call would remove the public frame
---the stack level is counted against.
---@param scope EventKit.Scope|false owning scope, or `false` for none
---@param label string qualified public method name, used in the argument errors
---@param level integer stack level the failures are reported at
---@param subEvent any
---@param callback any
---@return EventKit.Connection
local function subscribeCombatLog(scope, label, level, subEvent, callback)
  validateSubEvent(subEvent, label, level + 1)
  helpers.validateCallback(callback, label, level + 1)
  local route = acquireCombatLogRoute(subEvent, label, level + 1)
  local connection = helpers.connectToChannel(route, callback, false, scope)
  local combatLog = state.combatLog
  combatLog.listenerCount = combatLog.listenerCount + 1
  return connection
end

-- Entry points ---------------------------------------------------------------

---Subscribe to one combat-log sub-event, or to every one with `"*"`. The
---callback receives every return of `CombatLogGetCurrentEventInfo()`, read
---once per event for all combat-log listeners. See docs/API.md,
---"EventKit:ConnectCombatLog".
---@param _ EventKit
---@param subEvent string a client sub-event name such as `"SPELL_DAMAGE"`, or `"*"`
---@param callback EventKit.CombatLogListener
---@return EventKit.Connection connection
local function connectCombatLog(_, subEvent, callback)
  local connection = subscribeCombatLog(false, "EventKit:ConnectCombatLog", 3, subEvent, callback)
  return connection
end

---Subscribe to a combat-log sub-event inside this scope.
---@param self EventKit.Scope
---@param subEvent string a client sub-event name such as `"SPELL_DAMAGE"`, or `"*"`
---@param callback EventKit.CombatLogListener
---@return EventKit.Connection connection
local function scopeConnectCombatLog(self, subEvent, callback)
  helpers.validateScope(self, "EventKit.Scope:ConnectCombatLog", 3)
  helpers.ensureScopeOpen(self, "EventKit.Scope:ConnectCombatLog", 3)
  local connection =
    subscribeCombatLog(self, "EventKit.Scope:ConnectCombatLog", 3, subEvent, callback)
  return connection
end

-- Commit ---------------------------------------------------------------------

rawset(Scope, "ConnectCombatLog", scopeConnectCombatLog)
rawset(EventKit, "ConnectCombatLog", connectCombatLog)

state.dispatchCombatLog = dispatchCombatLog
state.dispatch.releaseRoute = releaseCombatLogRoute

parts[PART_NAME] = { revision = PART_REVISION }

return EventKit
