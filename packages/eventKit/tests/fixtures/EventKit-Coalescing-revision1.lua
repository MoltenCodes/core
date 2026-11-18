-- MoltenCodes EventKit part Coalescing
--
-- `Coalesce` and `Derive`, the event half of the framework's coalescing
-- family (docs/API.md, "Coalescing events"):
--
--   * `Coalesce(events, intervalSeconds, callback, options)` collects the
--     events' first payload arguments into a set; the first event starts the
--     interval and `callback(set)` runs once at its end, AceBucket's interval
--     semantics.
--   * `Derive(events, compute, options)` caches `compute()` and recomputes it,
--     after a quiet period, when one of its events fires.
--
-- Both time themselves on one TimerKit timer per handle, with the semantics
-- SchedulerKit documents for its own `Coalesce` and `Debounce`, which do no
-- more than that without a lane. A `Coalesce` given a SchedulerKit `lane`
-- still uses SchedulerKit's `Coalesce`, since lanes are SchedulerKit's. This
-- part therefore needs SchedulerKit only for a lane, and TimerKit for timing:
-- without TimerKit, `Coalesce` is refused at the caller and `Derive`
-- recomputes synchronously on every event.
--
-- The part needs EventKit's core loaded first (docs/decisions/
-- 0001-kit-core-and-parts.md). It keeps its state inside the core's
-- (`state.parts.Coalescing`, `state.compositeTimerScope`) and calls the core
-- through `state.helpers`, read at call time, so a core upgraded after this
-- part loaded serves it. Handles resolve their behaviour through
-- `state.composites`, so a higher revision of this part takes over live
-- handles and pending timers in place.
--
-- Contents
-- --------
--   Constants ........ identity, bounds, option fields
--   Dependencies ..... EventKit's core and its state, SignalKit
--   Lookups .......... TimerKit and SchedulerKit, found when first needed
--   Arguments ........ event lists, delays, options, unit sets
--   Timing ........... the TimerKit timer, delivery, the quiet period
--   Handles .......... building, routing events, recomputing
--   Handle methods ... the Coalesce and Derive handles
--   Entry points ..... facade and scope methods
--   Commit ........... members, composites entries and the part's revision

-- Constants ------------------------------------------------------------------

local PART_NAME = "Coalescing"
local PART_REVISION = 1
local REQUIRED_REGISTRY_API = 2
local CORE_PACKAGE, CORE_API = "eventKit", 1
local REQUIRED_SIGNAL_API = 1
-- The core interface this part reads (`state.helpers` entries, the
-- `state.composites` entries). EventKit's core publishes the number.
local REQUIRED_PART_INTERFACE = 1

-- TimerKit times every handle; SchedulerKit is asked only for a `lane`.
-- Neither is required: both are found through `Registry:Find` when needed.
local OPTIONAL_TIMER_API = 1
local OPTIONAL_SCHEDULER_API = 1

-- One Coalesce or Derive call listens to at most this many distinct events.
-- Per call, not per session: the handle holds one connection per event until
-- `Close`. Real composites merge a handful of related events, so a longer list
-- is refused at the caller as a generated or mistaken argument.
local MAXIMUM_COMPOSITE_EVENTS = 32

-- Distinct keys one interval may hold unless `maxKeys` says otherwise:
-- SchedulerKit's default for its `Coalesce`, kept so the two agree.
local DEFAULT_MAX_KEYS = 256

-- A timer that wakes within this many seconds of its due time counts as due,
-- as in SchedulerKit's family ("One clock").
local DUE_TOLERANCE_SECONDS = 0.001

-- The option fields each method accepts, built once rather than per call.
local COALESCE_OPTION_FIELDS = { byEvent = true, units = true, maxKeys = true, lane = true }
local DERIVE_OPTION_FIELDS = { delaySeconds = true, equals = true, units = true }

-- The SchedulerKit files a `lane` needs, named in the refusal without them.
local SCHEDULER_CORE_FILE = "schedulerKit\\SchedulerKit.lua"
local SCHEDULER_PART_FILES = {
  Coalescing = "schedulerKit\\parts\\SchedulerKit-Coalescing.lua",
  Lanes = "schedulerKit\\parts\\SchedulerKit-Lanes.lua",
}

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
  or type(rawget(state, "composites")) ~= "table"
  or type(rawget(state, "compositeMetatables")) ~= "table"
  or type(rawget(state, "compositePrototypes")) ~= "table"
then
  error("MoltenCodes EventKit part Coalescing requires EventKit API 1 to be loaded first", 2)
end

---@cast EventKit table

local parts = rawget(state, "parts")
local installed = rawget(parts, PART_NAME)
if
  type(installed) == "table"
  and type(installed.revision) == "number"
  and installed.revision >= PART_REVISION
then
  -- An equal or newer revision of this part already serves every addon.
  return EventKit
end

-- Read at call time, never copied: an upgraded core's helpers serve this part.
local helpers = rawget(state, "helpers")
local composites = rawget(state, "composites")
local Scope = rawget(EventKit, "Scope")
local COMPOSITE_PROTOTYPES = rawget(state, "compositePrototypes")
local COALESCE_METATABLE = rawget(rawget(state, "compositeMetatables"), "coalesce")
local DERIVE_METATABLE = rawget(rawget(state, "compositeMetatables"), "derive")

-- EventKit's core requires SignalKit, so it is loaded; `Derive` uses it for
-- `OnChange`.
local SignalKit = Registry:Get("signalKit", REQUIRED_SIGNAL_API)
if type(SignalKit) ~= "table" or type(rawget(SignalKit, "New")) ~= "function" then
  error("MoltenCodes EventKit part Coalescing requires SignalKit API 1 to be loaded first", 2)
end

-- Lookups --------------------------------------------------------------------

-- The facades once a lookup found them. Registry hands every compatible
-- revision the same facade table and a later revision only replaces the
-- methods on it, so a found facade stays the right one; a failed lookup is
-- not remembered, so a Kit loaded later is found.
---@type table|false
local foundTimerKit = false
---@type table|false
local foundSchedulerKit = false

---Silent optional lookup of TimerKit.
---@return table|nil TimerKit
---@return string|nil reason why it is unavailable
local function findTimerKit()
  if foundTimerKit ~= false then
    return foundTimerKit, nil
  end
  local find = rawget(Registry, "Find")
  if type(find) ~= "function" then
    return nil, "Registry:Find is unavailable"
  end
  local TimerKit, reason = find(Registry, "timerKit", OPTIONAL_TIMER_API)
  if type(TimerKit) ~= "table" then
    return nil, tostring(reason)
  end
  if type(rawget(TimerKit, "CreateScope")) ~= "function" then
    return nil, "the loaded TimerKit has no CreateScope"
  end
  foundTimerKit = TimerKit
  return TimerKit, nil
end

---Silent optional lookup of a SchedulerKit revision that has coalescing.
---@return table|nil SchedulerKit
---@return string|nil reason why it is unavailable
local function findSchedulerKit()
  if foundSchedulerKit ~= false then
    return foundSchedulerKit, nil
  end
  local find = rawget(Registry, "Find")
  if type(find) ~= "function" then
    return nil, "Registry:Find is unavailable"
  end
  local SchedulerKit, reason = find(Registry, "schedulerKit", OPTIONAL_SCHEDULER_API)
  if type(SchedulerKit) ~= "table" then
    return nil, tostring(reason)
  end
  local prototype = rawget(SchedulerKit, "Scope")
  if
    type(rawget(SchedulerKit, "CreateScope")) ~= "function"
    or type(prototype) ~= "table"
    or type(rawget(prototype, "Coalesce")) ~= "function"
    or type(rawget(prototype, "Debounce")) ~= "function"
  then
    return nil, "the loaded SchedulerKit predates coalescing, added in its revision 7"
  end
  foundSchedulerKit = SchedulerKit
  return SchedulerKit, nil
end

---SchedulerKit with the parts a `lane` needs, or a refusal at `level`.
---
---A SchedulerKit split into parts answers `HasPart`; a single-file revision
---has every part, which `findSchedulerKit`'s member test already confirmed.
---@param label string qualified public method name, used in the refusal
---@param level integer stack level the failure is reported at
---@return table SchedulerKit
local function requireLaneScheduler(label, level)
  local SchedulerKit, reason = findSchedulerKit()
  if SchedulerKit == nil then
    error(label .. " requires SchedulerKit API 1, which is not available (" .. reason .. ")", level)
  end
  local hasPart = rawget(SchedulerKit, "HasPart")
  if type(hasPart) == "function" then
    local missing = nil
    if hasPart(SchedulerKit, "Coalescing") ~= true then
      missing = "Coalescing"
    elseif hasPart(SchedulerKit, "Lanes") ~= true then
      missing = "Lanes"
    end
    if missing ~= nil then
      error(
        label
          .. " with a lane needs SchedulerKit's "
          .. missing
          .. " part, which is not loaded: add "
          .. SCHEDULER_PART_FILES[missing]
          .. " to embeds.xml after "
          .. SCHEDULER_CORE_FILE,
        level
      )
    end
  end
  return SchedulerKit
end

---Return the one SchedulerKit scope every lane handle's timing lives in,
---creating it on first use or when it was closed. It lives in shared state,
---so every EventKit revision uses the same one.
---@param SchedulerKit table
---@return table schedulerScope
local function sharedCoalesceScope(SchedulerKit)
  local scope = rawget(state, "coalesceSchedulerScope")
  if type(scope) ~= "table" or scope:IsClosed() then
    scope = SchedulerKit:CreateScope()
    rawset(state, "coalesceSchedulerScope", scope)
  end
  return scope
end

-- Arguments ------------------------------------------------------------------

---Drop a Lua error position prefix, so a SchedulerKit refusal can be raised
---again at EventKit's caller without naming a line inside either package.
---@param message any
---@return string
local function withoutPosition(message)
  local text = tostring(message)
  local stripped = string.gsub(text, "^[^:\n]+:%d+: ", "", 1)
  return stripped
end

---Validate `events` into a fresh array of distinct event names.
---@param events any a string or an array of strings
---@param label string qualified public method name, used in the argument errors
---@param level integer stack level the failures are reported at
---@return string[]
local function readEventList(events, label, level)
  if type(events) == "string" then
    helpers.validateEventName(events, label, level + 1)
    return { events }
  end
  if type(events) ~= "table" or type(events[1]) == "nil" then
    error(label .. " events must be an event name or a non-empty array of them", level)
  end

  -- Duplicates are dropped by a scan of the names already kept rather than
  -- a lookup set: a list is short (a longer one is refused just below), so
  -- the scan is cheaper than building and discarding a second table.
  local list, count = {}, 0
  for index = 1, #events do
    local eventName = events[index]
    if helpers.isSecret(eventName) then
      helpers.refuseSecret(eventName, label .. " events entry", level + 1)
    end
    if type(eventName) ~= "string" or eventName == "" then
      error(label .. " events must contain only non-empty strings", level)
    end
    local duplicate = false
    for kept = 1, count do
      if list[kept] == eventName then
        duplicate = true
        break
      end
    end
    -- Past the bound the list is refused below whatever follows, so the
    -- scan stops growing and every entry is still checked above.
    if not duplicate and count <= MAXIMUM_COMPOSITE_EVENTS then
      count = count + 1
      list[count] = eventName
    end
  end
  if count > MAXIMUM_COMPOSITE_EVENTS then
    error(label .. " accepts at most " .. MAXIMUM_COMPOSITE_EVENTS .. " distinct events", level)
  end
  -- The client is asked only once the list is known to be bounded, and once
  -- per distinct name.
  for index = 1, #list do
    helpers.refuseUnknownEvent(list[index], label .. " events entry", level + 1)
  end
  return list
end

---Reject an options value that is not a table or names an unknown field.
---@param options any
---@param allowed table<string, boolean>
---@param label string qualified public method name, used in the argument errors
---@param level integer stack level the failures are reported at
local function validateOptionTable(options, allowed, label, level)
  if type(options) == "nil" then
    return
  end
  if type(options) ~= "table" then
    error(label .. " options must be a table", level)
  end
  local unknown = nil
  for key in pairs(options) do
    if allowed[key] ~= true then
      local display = helpers.describeKey(key)
      if unknown == nil or display < unknown then
        unknown = display
      end
    end
  end
  if unknown ~= nil then
    error(label .. ' options contains unknown field "' .. unknown .. '"', level)
  end
end

---@param value any
---@param label string argument description, used in the argument error
---@param level integer stack level the failure is reported at
local function validateDelay(value, label, level)
  helpers.refuseSecret(value, label, level + 1)
  if type(value) ~= "number" or value ~= value or value == math.huge or value < 0 then
    error(label .. " must be a finite number greater than or equal to zero", level)
  end
end

---Validate `maxKeys` with the wording SchedulerKit gave it when it checked
---the option, so the message is the one revisions before 22 raised.
---@param value any
---@param label string argument description, used in the argument error
---@param level integer stack level the failure is reported at
local function validateMaxKeys(value, label, level)
  helpers.refuseSecret(value, label, level + 1)
  if
    type(value) ~= "number"
    or value ~= value
    or value == math.huge
    or value == -math.huge
    or value ~= math.floor(value)
    or value <= 0
  then
    error(label .. " must be a finite positive integer", level)
  end
end

---Read the optional `units` option into the normalized unit set.
---@param units any
---@param label string qualified public method name, used in the argument errors
---@param level integer stack level the failures are reported at
---@return string[]|nil units
---@return string|nil key
local function readUnits(units, label, level)
  if type(units) == "nil" then
    return nil, nil
  end
  if type(units) ~= "table" then
    error(label .. " units must be an array of one or two unit tokens", level)
  end
  return helpers.normalizeUnits(label, level + 1, unpackValues(units, 1, #units))
end

-- Timing ---------------------------------------------------------------------
--
-- A handle timed by TimerKit holds at most one timer at a time, `_timer`, in
-- one TimerKit scope this part owns (`state.compositeTimerScope`), created
-- with the first handle that arms one. Every timer runs the same callback,
-- which finds its handle through the timer's user data and resolves what to
-- do through `state.composites.wake`, so arming allocates no closure and a
-- higher revision of this part serves timers armed before it loaded.

---Current seconds on `GetTimePreciseSec`, the clock TimerKit's deadlines use,
---or `nil` on a host without it.
---@return number|nil seconds
local function nowSeconds()
  -- GetTimePreciseSec is a World of Warcraft client API reachable only through the global table.
  -- selene: allow(global_usage)
  local clock = rawget(_G, "GetTimePreciseSec")
  if type(clock) ~= "function" then
    return nil
  end
  return clock()
end

---The part's TimerKit scope, created on first use or when it was closed.
---@return table timerScope
local function ensureTimerScope()
  local scope = rawget(state, "compositeTimerScope")
  if type(scope) == "table" then
    local isClosed = scope.IsClosed
    if type(isClosed) ~= "function" or isClosed(scope) ~= true then
      return scope
    end
  end
  -- A handle is built only while TimerKit is found, but possibly by another
  -- revision of this part, so this copy may not have looked yet.
  local TimerKit, reason = findTimerKit()
  if TimerKit == nil then
    error("MoltenCodes EventKit part Coalescing lost TimerKit (" .. reason .. ")", 0)
  end
  scope = TimerKit:CreateScope()
  rawset(state, "compositeTimerScope", scope)
  return scope
end

---The one TimerKit callback every handle's timer runs.
---@param timerHandle table the TimerKit timer that fired
local function compositeTimerCallback(timerHandle)
  if type(timerHandle) ~= "table" then
    return
  end
  local handle = timerHandle:GetUserData()
  if type(handle) ~= "table" then
    return
  end
  timerHandle:SetUserData(nil)
  -- A cancelled or re-armed handle no longer points at this timer.
  if handle._timer ~= timerHandle then
    return
  end
  handle._timer = false
  -- A TimerKit callback has no caller to raise to, so a failure is reported.
  local ok, failure = pcall(composites.wake, handle)
  if not ok then
    helpers.reportListenerError(failure)
  end
end

---Arm `handle`'s timer for `seconds`. Raises when TimerKit refuses.
---@param handle table
---@param seconds number
local function armTimer(handle, seconds)
  local timer = ensureTimerScope():After(seconds, compositeTimerCallback)
  -- TimerKit never fires synchronously from `After`, so both halves of the
  -- link are in place before the timer can fire.
  handle._timer = timer
  timer:SetUserData(handle)
end

---Cancel `handle`'s timer if one is armed.
---@param handle table
local function cancelTimer(handle)
  local timer = handle._timer --[[@as table|false|nil]]
  if not timer then
    return
  end
  handle._timer = false
  timer:SetUserData(nil)
  timer:Cancel()
end

---Deliver what a Coalesce handle collected and swap in its other set.
---
---The set handed to the callback is one of the handle's two tables. Keys
---recorded while the callback runs go into the other one, and the delivered
---set is emptied as soon as the callback returns.
---@param handle table a Coalesce handle timed by TimerKit
local function deliverCoalesce(handle)
  local set = handle._set
  handle._set = handle._spare
  handle._spare = set
  handle._keyCount = 0
  handle._delivered = handle._delivered + 1

  handle._firing = true
  state.isolate(handle._callback, set)
  handle._firing = false
  for key in pairs(set) do
    set[key] = nil
  end
end

-- Handles --------------------------------------------------------------------

---Connect `listener` to every event of `list`, owned by `handle`.
---
---Called under `pcall` so a refused registration can release what was
---already connected; `level` already counts the protected call.
---@param handle table
---@param list string[]
---@param units string[]|nil
---@param key string|nil
---@param listener function
---@param label string qualified public method name, used in the argument errors
---@param level integer stack level the failures are reported at
local function connectHandleEvents(handle, list, units, key, listener, label, level)
  local connections = rawget(handle, "_connections")
  for index = 1, #list do
    local channel
    if units ~= nil then
      -- `readUnits` returns a key whenever it returns units.
      local unitKey = key --[[@as string]]
      channel = helpers.createUnitChannel(list[index], units, unitKey, label, level + 1)
    else
      channel = helpers.createRegularChannel(list[index], label, level + 1)
    end
    connections[#connections + 1] = helpers.connectToChannel(channel, listener, false, false)
  end
end

---Build the one listener a handle connects to each of its events.
---@param handle table
---@return function listener
local function newCompositeListener(handle)
  return function(eventName, first)
    return state.composites.onEvent(handle, eventName, first)
  end
end

---Finish building a handle: connect its events, then join `scope`. Releases
---the handle and raises when a registration is refused or `scope` closed
---while the handle was being built.
---@param handle table
---@param scope table|false
---@param list string[]
---@param units string[]|nil
---@param key string|nil
---@param label string qualified public method name, used in the argument errors
---@param level integer stack level the failures are reported at
local function attachCompositeHandle(handle, scope, list, units, key, label, level)
  -- The scope was open when the public method checked it, but `Derive` ran
  -- the caller's `compute` since then. A compute that closed the scope must
  -- not leave a live handle linked into it, where no sweep would reach it.
  if scope ~= false and rawget(scope, "_closed") == true then
    pcall(helpers.closeCompositeHandle, handle)
    error(label .. " cannot connect in a closed scope", level)
  end

  local listener = newCompositeListener(handle)
  -- Levels inside the protected call: connectHandleEvents, pcall, this
  -- function, and then `level` more to the caller.
  local ok, failure =
    pcall(connectHandleEvents, handle, list, units, key, listener, label, level + 2)
  if not ok then
    pcall(helpers.closeCompositeHandle, handle)
    error(failure, 0)
  end
  if scope ~= false then
    helpers.linkToScope(scope, handle)
  end
end

---Recompute a Derive handle's value and announce a change.
---@param handle table
local function recomputeDerived(handle)
  if rawget(handle, "_closed") == true then
    return
  end
  local ok, value = pcall(rawget(handle, "_compute"))
  if not ok then
    helpers.reportListenerError(value)
    return
  end

  local isSecret = helpers.isSecret
  local previous = rawget(handle, "_value")
  local changed
  local equals = rawget(handle, "_equals")
  if equals ~= false then
    local equalsOk, same = pcall(equals, previous, value)
    if not equalsOk then
      helpers.reportListenerError(same)
      changed = true
    elseif isSecret(same) then
      -- A secret answer cannot be tested as a boolean, so it is not
      -- "equal": the value counts as changed, as when either side is
      -- secret below.
      changed = true
    else
      changed = not same
    end
  else
    -- A secret on either side cannot be compared, so it counts as a change.
    changed = isSecret(previous) or isSecret(value) or previous ~= value
  end
  if not changed then
    return
  end

  rawset(handle, "_value", value)
  local signal = rawget(handle, "_signal")
  if signal ~= false then
    signal:Fire(value, previous)
  end
end

---Mark a Derive handle's value stale.
---
---A handle a revision before 22 built debounces through its SchedulerKit
---handle in `_timing`. Every other one waits out `_delay` on its TimerKit
---timer, or recomputes at once when it was built without TimerKit. Each call
---restarts the quiet period by recording the time; the timer is armed once
---per burst and re-armed for the rest when it wakes early.
---@param handle table
local function invalidateDerived(handle)
  if rawget(handle, "_closed") == true then
    return
  end
  local timing = rawget(handle, "_timing")
  if timing ~= nil and timing ~= false then
    -- A timing handle whose SchedulerKit scope was closed from outside
    -- refuses the call; recompute now rather than going stale.
    if timing() == true then
      return
    end
    recomputeDerived(handle)
    return
  end

  local delay = rawget(handle, "_delay")
  if delay == false or delay == nil then
    recomputeDerived(handle)
    return
  end
  handle._lastCall = nowSeconds() or false
  if handle._timer == false then
    -- The first call of a burst: a timer TimerKit cannot arm is raised to
    -- this caller, and nothing stays pending.
    local ok, failure = pcall(armTimer, handle, delay)
    if not ok then
      handle._lastCall = false
      error(failure, 0)
    end
  end
end

---A handle's timer fired: deliver a Coalesce handle's set, or recompute a
---Derive handle once its quiet period has passed.
---@param handle table
local function wakeComposite(handle)
  if handle._closed == true then
    return
  end
  if handle._kind == "coalesce" then
    if handle._keyCount > 0 then
      deliverCoalesce(handle)
    end
    return
  end

  local delay = handle._delay
  local lastCall = handle._lastCall
  local now = nowSeconds()
  if delay ~= false and lastCall ~= false and now ~= nil then
    local quiet = now - lastCall
    if quiet + DUE_TOLERANCE_SECONDS < delay then
      -- A call came during the window: wait out the rest, never longer than
      -- the delay itself, so a clock that steps back cannot stretch it.
      local remaining = delay - quiet
      if remaining > delay then
        remaining = delay
      end
      armTimer(handle, remaining)
      return
    end
  end
  handle._lastCall = false
  recomputeDerived(handle)
end

---Route an event to the handle kind that listens for it.
---@param handle table
---@param eventName string
---@param first any
local function onCompositeEvent(handle, eventName, first)
  if handle._closed == true then
    return
  end
  if handle._kind ~= "coalesce" then
    invalidateDerived(handle)
    return
  end

  -- Record the event, inline because this runs for every event a bucket
  -- hears. A secret payload cannot be compared or used as a key, so it
  -- coalesces under the event name, like a missing one.
  local key = first
  if handle._byEvent == true or type(key) == "nil" or helpers.isSecret(key) or key ~= key then
    key = eventName
  end
  local timing = handle._timing
  if timing ~= nil and timing ~= false then
    timing(key)
    return
  end

  local set = handle._set
  if set[key] == nil then
    local count = handle._keyCount
    if count >= handle._maxKeys then
      handle._refused = (handle._refused or 0) + 1
      return
    end
    handle._keyCount = count + 1
  end
  set[key] = true
  -- The key is collected before the timer is armed, so a timer TimerKit
  -- refuses leaves it collected; the next event arms again.
  if handle._timer == false then
    armTimer(handle, handle._interval)
  end
end

---Build a Coalesce handle.
---@param scope table|false owning scope, or `false` for none
---@param label string qualified public method name, used in the argument errors
---@param level integer stack level the failures are reported at
---@return EventKit.CoalesceHandle
local function createCoalesceHandle(scope, label, level, events, interval, callback, options)
  local list = readEventList(events, label, level + 1)
  validateDelay(interval, label .. " intervalSeconds", level + 1)
  helpers.validateCallback(callback, label, level + 1)
  validateOptionTable(options, COALESCE_OPTION_FIELDS, label, level + 1)

  local byEvent, units, key, maxKeys, lane = false, nil, nil, nil, nil
  if type(options) ~= "nil" then
    local byEventOption = rawget(options, "byEvent")
    helpers.refuseSecret(byEventOption, label .. " byEvent", level + 1)
    if type(byEventOption) ~= "nil" and type(byEventOption) ~= "boolean" then
      error(label .. " byEvent must be a boolean", level)
    end
    byEvent = byEventOption == true
    units, key = readUnits(rawget(options, "units"), label, level + 1)
    maxKeys = rawget(options, "maxKeys")
    lane = rawget(options, "lane")
  end

  local handle
  if type(lane) ~= "nil" then
    -- A lane is SchedulerKit's, so its `Coalesce` times this handle.
    local SchedulerKit = requireLaneScheduler(label, level + 1)
    local schedulerScope = sharedCoalesceScope(SchedulerKit)
    local ok, timing = pcall(
      schedulerScope.Coalesce,
      schedulerScope,
      callback,
      interval,
      { maxKeys = maxKeys, lane = lane }
    )
    if not ok then
      error(label .. ": " .. withoutPosition(timing), level)
    end
    handle = setmetatable({
      _kind = "coalesce",
      _closed = false,
      _byEvent = byEvent,
      _connections = {},
      _timing = timing,
      _scope = false,
      _scopePrevious = false,
      _scopeNext = false,
    }, COALESCE_METATABLE)
  else
    local TimerKit, reason = findTimerKit()
    if TimerKit == nil then
      error(label .. " requires TimerKit API 1, which is not available (" .. reason .. ")", level)
    end
    if type(maxKeys) == "nil" then
      maxKeys = DEFAULT_MAX_KEYS
    else
      validateMaxKeys(maxKeys, label .. ": SchedulerKit.Scope:Coalesce maxKeys", level + 1)
    end
    -- Sixteen fields, so the hash part is 16 slots. The rare `_refused`
    -- counter and the reused `GetStats` view are written when first needed.
    handle = setmetatable({
      _kind = "coalesce",
      _closed = false,
      _byEvent = byEvent,
      _connections = {},
      _scope = false,
      _scopePrevious = false,
      _scopeNext = false,
      _callback = callback,
      _interval = interval,
      _maxKeys = maxKeys,
      _set = {},
      _spare = {},
      _keyCount = 0,
      _timer = false,
      _delivered = 0,
      _firing = false,
    }, COALESCE_METATABLE)
  end
  attachCompositeHandle(handle, scope, list, units, key, label, level + 1)
  return handle
end

---Build a Derive handle.
---@param scope table|false owning scope, or `false` for none
---@param label string qualified public method name, used in the argument errors
---@param level integer stack level the failures are reported at
---@return EventKit.DeriveHandle
local function createDeriveHandle(scope, label, level, events, compute, options)
  local list = readEventList(events, label, level + 1)
  if type(compute) ~= "function" then
    error(label .. " compute must be a function", level)
  end
  validateOptionTable(options, DERIVE_OPTION_FIELDS, label, level + 1)

  ---@type number|false
  local delay = 0
  local equals, units, key = false, nil, nil
  if type(options) ~= "nil" then
    if type(rawget(options, "delaySeconds")) ~= "nil" then
      delay = rawget(options, "delaySeconds")
      validateDelay(delay, label .. " delaySeconds", level + 1)
    end
    if type(rawget(options, "equals")) ~= "nil" then
      equals = rawget(options, "equals")
      if type(equals) ~= "function" then
        error(label .. " equals must be a function", level)
      end
    end
    units, key = readUnits(rawget(options, "units"), label, level + 1)
  end

  -- The first value is computed before anything is registered, so a
  -- compute that raises leaves nothing behind.
  local initial = compute()

  -- Without TimerKit at creation the handle recomputes on every event.
  if findTimerKit() == nil then
    delay = false
  end
  local handle = setmetatable({
    _kind = "derive",
    _closed = false,
    _compute = compute,
    _equals = equals,
    _value = initial,
    _connections = {},
    _signal = false,
    _scope = false,
    _scopePrevious = false,
    _scopeNext = false,
    _delay = delay,
    _timer = false,
    _lastCall = false,
  }, DERIVE_METATABLE)
  attachCompositeHandle(handle, scope, list, units, key, label, level + 1)
  return handle
end

-- Handle methods -------------------------------------------------------------

---@param handle any receiver the public method was called on
---@param metatable table
---@param label string qualified public method name, used in the argument error
---@param noun string what the receiver should have been
local function validateCompositeReceiver(handle, metatable, label, noun)
  -- `getmetatable` answers the shared metatable for a handle only.
  if getmetatable(handle) ~= metatable then
    error(label .. " must be called on an EventKit " .. noun, 3)
  end
end

---Deliver what the handle collected now instead of at the end of the interval.
---@param self EventKit.CoalesceHandle
---@return boolean delivered `false` when nothing was collected, during the handle's own delivery, or when it is closed.
---@return string? reason `"deferred"` or `"dropped"` when a SchedulerKit lane did not take it
local function coalesceFlush(self)
  validateCompositeReceiver(
    self,
    COALESCE_METATABLE,
    "EventKit.CoalesceHandle:Flush",
    "coalesce handle"
  )
  local timing = rawget(self, "_timing")
  if timing ~= nil and timing ~= false then
    return timing:Flush()
  end
  if rawget(self, "_keyCount") == 0 or rawget(self, "_firing") == true then
    return false, nil
  end
  cancelTimer(self)
  deliverCoalesce(self)
  return true, nil
end

---Whether events were collected and wait for delivery.
---@param self EventKit.CoalesceHandle
---@return boolean pending
local function coalesceIsPending(self)
  validateCompositeReceiver(
    self,
    COALESCE_METATABLE,
    "EventKit.CoalesceHandle:IsPending",
    "coalesce handle"
  )
  local timing = rawget(self, "_timing")
  if timing ~= nil and timing ~= false then
    return timing:IsPending()
  end
  return rawget(self, "_keyCount") > 0
end

---Return the handle's counters, `{ keys, refused, delivered, deferred,
---dropped }`, in a table reused by every call.
---@param self EventKit.CoalesceHandle
---@return table<string, integer> stats
local function coalesceGetStats(self)
  validateCompositeReceiver(
    self,
    COALESCE_METATABLE,
    "EventKit.CoalesceHandle:GetStats",
    "coalesce handle"
  )
  local timing = rawget(self, "_timing")
  if timing ~= nil and timing ~= false then
    return timing:GetStats()
  end
  local view = rawget(self, "_statsView")
  if type(view) ~= "table" then
    view = {}
    rawset(self, "_statsView", view)
  end
  view.keys = rawget(self, "_keyCount")
  view.refused = rawget(self, "_refused") or 0
  view.delivered = rawget(self, "_delivered")
  -- Only a lane defers or drops a delivery.
  view.deferred = 0
  view.dropped = 0
  return view
end

---Release the handle: its events, its pending delivery, its scope membership.
---@param self EventKit.CoalesceHandle
---@return boolean closed `false` when it was already closed.
local function coalesceClose(self)
  validateCompositeReceiver(
    self,
    COALESCE_METATABLE,
    "EventKit.CoalesceHandle:Close",
    "coalesce handle"
  )
  return helpers.closeCompositeHandle(self)
end

---Whether the handle is closed.
---@param self EventKit.CoalesceHandle
---@return boolean closed
local function coalesceIsClosed(self)
  validateCompositeReceiver(
    self,
    COALESCE_METATABLE,
    "EventKit.CoalesceHandle:IsClosed",
    "coalesce handle"
  )
  return rawget(self, "_closed") == true
end

---Return the cached value.
---@param self EventKit.DeriveHandle
---@return any value
local function deriveGet(self)
  validateCompositeReceiver(self, DERIVE_METATABLE, "EventKit.DeriveHandle:Get", "derived value")
  return rawget(self, "_value")
end

---Subscribe to changes of the value. Listeners are isolated like event
---listeners: one that raises is reported and the rest still run.
---@param self EventKit.DeriveHandle
---@param callback fun(value: any, previous: any)
---@return table connection a SignalKit connection
local function deriveOnChange(self, callback)
  validateCompositeReceiver(
    self,
    DERIVE_METATABLE,
    "EventKit.DeriveHandle:OnChange",
    "derived value"
  )
  helpers.validateCallback(callback, "EventKit.DeriveHandle:OnChange", 3)
  if rawget(self, "_closed") == true then
    error("EventKit.DeriveHandle:OnChange cannot subscribe to a closed derived value", 2)
  end
  local signal = rawget(self, "_signal")
  if signal == false then
    signal = SignalKit:New()
    rawset(self, "_signal", signal)
  end
  local connection = signal:Connect(function(...)
    return state.isolate(callback, ...)
  end)
  return connection
end

---Mark the value stale, exactly as one of its events would.
---@param self EventKit.DeriveHandle
local function deriveInvalidate(self)
  validateCompositeReceiver(
    self,
    DERIVE_METATABLE,
    "EventKit.DeriveHandle:Invalidate",
    "derived value"
  )
  invalidateDerived(self)
end

---Release the handle: its events, its pending recompute, its listeners.
---@param self EventKit.DeriveHandle
---@return boolean closed `false` when it was already closed.
local function deriveClose(self)
  validateCompositeReceiver(self, DERIVE_METATABLE, "EventKit.DeriveHandle:Close", "derived value")
  return helpers.closeCompositeHandle(self)
end

---Whether the handle is closed.
---@param self EventKit.DeriveHandle
---@return boolean closed
local function deriveIsClosed(self)
  validateCompositeReceiver(
    self,
    DERIVE_METATABLE,
    "EventKit.DeriveHandle:IsClosed",
    "derived value"
  )
  return rawget(self, "_closed") == true
end

-- Entry points ---------------------------------------------------------------

---Coalesce `events` into at most one `callback(set)` per interval. Needs
---TimerKit, or SchedulerKit with its Coalescing and Lanes parts for a `lane`;
---see docs/API.md, "Coalescing events".
---@param _ EventKit
---@param events string|string[]
---@param intervalSeconds number Finite seconds greater than or equal to zero.
---@param callback fun(set: table<any, any>)
---@param options EventKit.CoalesceOptions?
---@return EventKit.CoalesceHandle handle
local function coalesceEvents(_, events, intervalSeconds, callback, options)
  local handle =
    createCoalesceHandle(false, "EventKit:Coalesce", 3, events, intervalSeconds, callback, options)
  return handle
end

---Derive a value from `compute`, recomputed when any of `events` fires.
---@param _ EventKit
---@param events string|string[]
---@param compute fun(): any
---@param options EventKit.DeriveOptions?
---@return EventKit.DeriveHandle handle
local function deriveValue(_, events, compute, options)
  local handle = createDeriveHandle(false, "EventKit:Derive", 3, events, compute, options)
  return handle
end

---Coalesce `events` inside this scope.
---@param self EventKit.Scope
---@param events string|string[]
---@param intervalSeconds number Finite seconds greater than or equal to zero.
---@param callback fun(set: table<any, any>)
---@param options EventKit.CoalesceOptions?
---@return EventKit.CoalesceHandle handle
local function scopeCoalesce(self, events, intervalSeconds, callback, options)
  helpers.validateScope(self, "EventKit.Scope:Coalesce", 3)
  helpers.ensureScopeOpen(self, "EventKit.Scope:Coalesce", 3)
  local handle = createCoalesceHandle(
    self,
    "EventKit.Scope:Coalesce",
    3,
    events,
    intervalSeconds,
    callback,
    options
  )
  return handle
end

---Derive a value inside this scope.
---@param self EventKit.Scope
---@param events string|string[]
---@param compute fun(): any
---@param options EventKit.DeriveOptions?
---@return EventKit.DeriveHandle handle
local function scopeDerive(self, events, compute, options)
  helpers.validateScope(self, "EventKit.Scope:Derive", 3)
  helpers.ensureScopeOpen(self, "EventKit.Scope:Derive", 3)
  local handle = createDeriveHandle(self, "EventKit.Scope:Derive", 3, events, compute, options)
  return handle
end

-- Commit ---------------------------------------------------------------------

rawset(Scope, "Coalesce", scopeCoalesce)
rawset(Scope, "Derive", scopeDerive)
rawset(EventKit, "Coalesce", coalesceEvents)
rawset(EventKit, "Derive", deriveValue)

local COALESCE_PROTOTYPE = rawget(COMPOSITE_PROTOTYPES, "coalesce")
rawset(COALESCE_PROTOTYPE, "Flush", coalesceFlush)
rawset(COALESCE_PROTOTYPE, "IsPending", coalesceIsPending)
rawset(COALESCE_PROTOTYPE, "GetStats", coalesceGetStats)
rawset(COALESCE_PROTOTYPE, "Close", coalesceClose)
rawset(COALESCE_PROTOTYPE, "IsClosed", coalesceIsClosed)

local DERIVE_PROTOTYPE = rawget(COMPOSITE_PROTOTYPES, "derive")
rawset(DERIVE_PROTOTYPE, "Get", deriveGet)
rawset(DERIVE_PROTOTYPE, "OnChange", deriveOnChange)
rawset(DERIVE_PROTOTYPE, "Invalidate", deriveInvalidate)
rawset(DERIVE_PROTOTYPE, "Close", deriveClose)
rawset(DERIVE_PROTOTYPE, "IsClosed", deriveIsClosed)

rawset(composites, "onEvent", onCompositeEvent)
rawset(composites, "recompute", recomputeDerived)
rawset(composites, "wake", wakeComposite)

rawset(parts, PART_NAME, { revision = PART_REVISION })

return EventKit
