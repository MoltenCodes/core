-- MoltenCodes EventKit part Units
--
-- `ConnectUnit` and `OnceUnit`: events filtered to one or two unit tokens,
-- registered with `Frame:RegisterUnitEvent` (docs/API.md, "Unit events").
--
-- `RegisterUnitEvent` replaces a same-event registration on the same Frame, so
-- each normalized unit-token set gets a Frame of its own (a unit group). WoW
-- Frames are never destroyed, so the Frames this part ever creates are bounded
-- by the shared `maxUnitFrames` limit, and a group whose last channel goes
-- returns its Frame to a free list the next group reuses.
--
-- The part needs EventKit's core loaded first (docs/decisions/
-- 0001-kit-core-and-parts.md). Its groups, Frames and free list live in the
-- core's state (`unitGroups`, `unitFrames`, `unitFrameCount`), its limit in the
-- core's limits table; it calls the core through `state.helpers`, read at call
-- time, so a core upgraded after this part loaded serves it. A group's Frame
-- dispatches through `state.dispatchUnit`, which this part fills, so a higher
-- revision of the part takes over live groups in place, and the groups an
-- EventKit revision 22 built (when unit events were in its core) as well.
--
-- Contents
-- --------
--   Constants ........ identity, the unit-token bound
--   Dependencies ..... EventKit's core and its state
--   Arguments ........ unit-token normalisation
--   Unit groups ...... Frames, groups and their channels
--   Subscription ..... validation and the connect path, the method form
--   Entry points ..... facade and scope methods
--   Commit ........... members, dispatch entries and the part's revision

-- Constants ------------------------------------------------------------------

local PART_NAME = "Units"
local PART_REVISION = 1
local REQUIRED_REGISTRY_API = 2
local CORE_PACKAGE, CORE_API = "eventKit", 1
-- The core interface this part reads (`state.helpers` entries, the
-- `state.dispatch` entries). EventKit's core publishes the number.
local REQUIRED_PART_INTERFACE = 2

-- `Frame:RegisterUnitEvent(event, unit1, unit2)` has exactly two filter slots.
local MAXIMUM_UNIT_TOKENS = 2

-- Lua 5.1 publishes unpack as a global; newer clients move it onto table.
-- selene: allow(global_usage)
local unpackValues = rawget(table, "unpack") or rawget(_G, "unpack")

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
  or type(rawget(state, "unitGroups")) ~= "table"
then
  error("MoltenCodes EventKit part Units requires EventKit API 1 to be loaded first", 2)
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

-- Arguments ------------------------------------------------------------------

---Sort and de-duplicate unit tokens into a group key.
---
---The key is order-independent, so `"player", "target"` and `"target", "player"`
---share one group and therefore one Frame.
---@param label string qualified public method name, used in the argument errors
---@param level integer stack level the failures are reported at
---@param ... string one or two unit tokens
---@return string[] units sorted, de-duplicated tokens
---@return string key normalized group key
local function normalizeUnits(label, level, ...)
  local count = select("#", ...)
  if count == 0 then
    error(label .. " requires at least one unit token", level)
  end

  local units = {}
  local seen = {}

  for index = 1, count do
    local unit = select(index, ...)
    helpers.refuseSecret(unit, label .. " unit token", level + 1)
    if type(unit) ~= "string" or unit == "" then
      error(label .. " unit tokens must be non-empty strings", level)
    end

    if not seen[unit] then
      seen[unit] = true
      units[#units + 1] = unit
    end
  end

  -- Frame:RegisterUnitEvent has two filter slots. A third distinct token
  -- would be dropped by the client while the group key still claimed it, so
  -- the caller would silently receive a filter they never asked for.
  if #units > MAXIMUM_UNIT_TOKENS then
    error(
      label
        .. " accepts at most "
        .. MAXIMUM_UNIT_TOKENS
        .. " distinct unit tokens because Frame:RegisterUnitEvent has "
        .. MAXIMUM_UNIT_TOKENS
        .. " filter slots; received "
        .. #units,
      level
    )
  end

  table.sort(units)

  local keyParts = {}
  for index = 1, #units do
    local unit = units[index]
    keyParts[index] = tostring(#unit) .. ":" .. unit
  end

  return units, table.concat(keyParts, "|")
end

-- Unit groups ----------------------------------------------------------------

---Take a Frame for `group`, reusing a released one before creating another.
---@param group EventKit.UnitGroup
---@return WowFrame
local function acquireUnitFrame(group)
  -- Resolved through `state` when an event arrives, so a newer revision of
  -- this part serves Frames an older one made.
  local function onUnitFrameEvent(_, eventName, ...)
    return state.dispatchUnit(EventKit, group, eventName, ...)
  end

  local freeFrames = state.unitFrames
  local freeCount = #freeFrames
  if freeCount > 0 then
    local frame = freeFrames[freeCount]
    freeFrames[freeCount] = nil

    -- Re-purpose the Frame for this unit set. Its events were already
    -- unregistered when the previous group released it.
    local setScript = helpers.requireFrameMethod(frame, "SetScript")
    setScript(frame, "OnEvent", onUnitFrameEvent)
    return frame
  end

  local created = state.unitFrameCount
  local maxUnitFrames = state.limits.maxUnitFrames
  if created >= maxUnitFrames then
    error(
      "EventKit: refusing to create more than "
        .. maxUnitFrames
        .. " unit-filter Frames; disconnect unused unit subscriptions, "
        .. "reuse unit sets or raise EventKit:SetLimits{ maxUnitFrames }",
      0
    )
  end

  local frame = helpers.createEventFrame(onUnitFrameEvent)
  state.unitFrameCount = created + 1
  return frame
end

---Drop `group` and return its Frame to the free list. The core calls it,
---through `state.dispatch.releaseUnitGroup`, when the group's last channel
---goes.
---@param group EventKit.UnitGroup
local function releaseUnitGroup(group)
  state.unitGroups[group.key] = nil

  local frame = group.frame
  group.frame = nil

  -- Detach the handler before pooling the Frame: an event the host already
  -- queued must not reach a group that no longer exists.
  local setScript = helpers.requireFrameMethod(frame, "SetScript")
  setScript(frame, "OnEvent", nil)

  local freeFrames = state.unitFrames
  freeFrames[#freeFrames + 1] = frame
end

---Return the group owning `key`, creating it and its Frame on demand.
---@param key string
---@return EventKit.UnitGroup
local function ensureUnitGroup(key)
  local groups = state.unitGroups
  local group = groups[key]
  if group ~= nil then
    return group
  end

  group = {
    key = key,
    channels = {},
    frame = nil,
  }

  group.frame = acquireUnitFrame(group)
  groups[key] = group
  return group
end

---Return the unit-filtered channel for `eventName`, registering it on demand.
---@param eventName string
---@param units string[]
---@param key string normalized group key produced by `normalizeUnits`
---@param label string qualified public method name, used in the argument error
---@param level integer stack level the failure is reported at
---@return EventKit.Channel
local function createUnitChannel(eventName, units, key, label, level)
  local group = ensureUnitGroup(key)
  local channels = group.channels
  local existingChannel = channels[eventName]
  if existingChannel ~= nil then
    return existingChannel
  end

  local frame = group.frame
  local registerUnitEvent = helpers.requireFrameMethod(frame, "RegisterUnitEvent")
  -- Protected so that a host that raises, like one that answers `false`,
  -- releases a group created only for this registration; otherwise its
  -- Frame would count against `maxUnitFrames` for the rest of the session.
  local ok, registered = pcall(registerUnitEvent, frame, eventName, unpackValues(units, 1, #units))
  if not ok or registered == false then
    if next(channels) == nil then
      -- The group exists only because this registration was attempted.
      releaseUnitGroup(group)
    end
    if not ok then
      error(registered, 0)
    end
    error(label .. " could not register event " .. eventName, level)
  end

  local channel = helpers.newChannel(eventName, frame, channels, group)
  channels[eventName] = channel
  return channel
end

---Fan one unit-filtered event out to its channel inside `group`.
---@param _ EventKit
---@param group EventKit.UnitGroup
---@param eventName string
---@param ... any client payload
local function dispatchUnit(_, group, eventName, ...)
  local channel = group.channels[eventName]
  if channel ~= nil then
    helpers.fireChannel(channel, eventName, ...)
  end
end

-- Subscription ---------------------------------------------------------------
--
-- Package-level and scope-level entry points share these paths, so both sit at
-- the same distance from the validators and report at their caller's line.
-- Callers keep the result in a local before returning it: a Lua tail call would
-- remove the public frame the stack level is counted against.

---The method form of `subscribeUnit`; `eventName` is already validated.
---@param scope EventKit.Scope|false owning scope, or `false` for none
---@param label string qualified public method name, used in the argument errors
---@param level integer stack level the failures are reported at
---@param eventName string
---@param receiver any
---@param once boolean
---@param methodName any
---@param ... any one or two unit tokens
---@return EventKit.Connection
local function subscribeUnitMethod(scope, label, level, eventName, receiver, once, methodName, ...)
  local listener = helpers.bindMethod(receiver, methodName, nil, label, level + 1)
  local units, key = normalizeUnits(label, level + 1, ...)
  local channel = createUnitChannel(eventName, units, key, label, level + 1)
  local connection = helpers.connectToChannel(channel, listener, once, scope)
  return connection
end

---Validate and attach one unit-filtered subscription.
---
---In the method form (`callback` a receiver table) the method name is the
---first value after it and is required, because a unit token in its place
---would be ambiguous; the unit tokens follow it.
---@param scope EventKit.Scope|false owning scope, or `false` for none
---@param label string qualified public method name, used in the argument errors
---@param level integer stack level the failures are reported at
---@param eventName any
---@param callback any a function, or a receiver table for the method form
---@param once boolean
---@param ... any one or two unit tokens, after the method name in the method form
---@return EventKit.Connection
local function subscribeUnit(scope, label, level, eventName, callback, once, ...)
  helpers.validateEventName(eventName, label, level + 1)
  if type(callback) ~= "function" then
    local connection = subscribeUnitMethod(scope, label, level + 1, eventName, callback, once, ...)
    return connection
  end
  local units, key = normalizeUnits(label, level + 1, ...)
  local channel = createUnitChannel(eventName, units, key, label, level + 1)
  local connection = helpers.connectToChannel(channel, callback, once, scope)
  return connection
end

-- Entry points ---------------------------------------------------------------

---Subscribe to `eventName` filtered to one or two unit tokens.
---@param _ EventKit
---@param eventName string
---@param callback EventKit.Listener|table a listener, or a receiver table followed by a method name
---@param ... string one or two unit tokens; `Frame:RegisterUnitEvent` has two slots
---@return EventKit.Connection connection
local function connectUnitEvent(_, eventName, callback, ...)
  local connection =
    subscribeUnit(false, "EventKit:ConnectUnit", 3, eventName, callback, false, ...)
  return connection
end

---Subscribe once to `eventName` filtered to one or two unit tokens.
---@param _ EventKit
---@param eventName string
---@param callback EventKit.Listener|table a listener, or a receiver table followed by a method name
---@param ... string one or two unit tokens; `Frame:RegisterUnitEvent` has two slots
---@return EventKit.Connection connection
local function onceUnitEvent(_, eventName, callback, ...)
  local connection = subscribeUnit(false, "EventKit:OnceUnit", 3, eventName, callback, true, ...)
  return connection
end

---Subscribe to a unit-filtered event inside this scope.
---@param self EventKit.Scope
---@param eventName string
---@param callback EventKit.Listener|table a listener, or a receiver table followed by a method name
---@param ... string one or two unit tokens; `Frame:RegisterUnitEvent` has two slots
---@return EventKit.Connection connection
local function scopeConnectUnit(self, eventName, callback, ...)
  helpers.validateScope(self, "EventKit.Scope:ConnectUnit", 3)
  helpers.ensureScopeOpen(self, "EventKit.Scope:ConnectUnit", 3)
  local connection =
    subscribeUnit(self, "EventKit.Scope:ConnectUnit", 3, eventName, callback, false, ...)
  return connection
end

---Subscribe once to a unit-filtered event inside this scope.
---@param self EventKit.Scope
---@param eventName string
---@param callback EventKit.Listener|table a listener, or a receiver table followed by a method name
---@param ... string one or two unit tokens; `Frame:RegisterUnitEvent` has two slots
---@return EventKit.Connection connection
local function scopeOnceUnit(self, eventName, callback, ...)
  helpers.validateScope(self, "EventKit.Scope:OnceUnit", 3)
  helpers.ensureScopeOpen(self, "EventKit.Scope:OnceUnit", 3)
  local connection =
    subscribeUnit(self, "EventKit.Scope:OnceUnit", 3, eventName, callback, true, ...)
  return connection
end

-- Commit ---------------------------------------------------------------------

rawset(Scope, "ConnectUnit", scopeConnectUnit)
rawset(Scope, "OnceUnit", scopeOnceUnit)
rawset(EventKit, "ConnectUnit", connectUnitEvent)
rawset(EventKit, "OnceUnit", onceUnitEvent)

state.dispatchUnit = dispatchUnit
state.dispatch.releaseUnitGroup = releaseUnitGroup
-- The Coalescing part's `units` option builds its channels through these.
helpers.normalizeUnits = normalizeUnits
helpers.createUnitChannel = createUnitChannel

parts[PART_NAME] = { revision = PART_REVISION }

return EventKit
