-- MoltenCodes SchedulerKit part Watch
--
-- `Watch(predicate, intervalSeconds, callback[, options])` on the facade and
-- on every scope: poll a predicate and call back when its result changes.
-- Watchers are grouped by interval; each group owns one TimerKit ticker in
-- the family's package-internal timer scope, created with its first watcher
-- and cancelled with its last. Watchers are members of their scope, released
-- by `CancelAll` and `Close` like jobs.
--
-- The part needs SchedulerKit's core and its Coalescing part loaded first.
--
-- Contents
-- --------
--   Constants ............. identity
--   Dependencies .......... SchedulerKit's core, its state, the Coalescing part
--   Watch ................. groups, ticks, sampling, creation, handle methods
--   Commit ................ the watch prototype, `Watch`, dispatch, the revision

-- Constants ------------------------------------------------------------------

local PART_NAME = "Watch"
local PART_REVISION = 1
local REQUIRED_PART_INTERFACE = 1
local REQUIRED_REGISTRY_API = 2
local CORE_PACKAGE, CORE_API = "schedulerKit", 1

-- Dependencies ---------------------------------------------------------------

-- The shared MoltenCodes namespace is the one documented global handoff point between independently embedded copies.
-- selene: allow(global_usage)
local namespace = rawget(_G, "MoltenCodes")
local generations = type(namespace) == "table" and rawget(namespace, "Registries") or nil
local Registry = type(generations) == "table" and rawget(generations, REQUIRED_REGISTRY_API) or nil
local SchedulerKit = nil
if type(Registry) == "table" then
  local find = rawget(Registry, "Find")
  if type(find) ~= "function" then
    find = rawget(Registry, "Get")
  end
  if type(find) == "function" then
    SchedulerKit = find(Registry, CORE_PACKAGE, CORE_API)
  end
end
local state = type(SchedulerKit) == "table" and rawget(SchedulerKit, "_state") or nil
if
  type(state) ~= "table"
  or type(rawget(state, "parts")) ~= "table"
  or type(rawget(state, "helpers")) ~= "table"
  or type(rawget(state, "familyHelpers")) ~= "table"
  or type(rawget(state, "dispatch")) ~= "table"
  or type(rawget(state, "partInterface")) ~= "number"
  or rawget(state, "partInterface") < REQUIRED_PART_INTERFACE
then
  error(
    "MoltenCodes SchedulerKit part "
      .. PART_NAME
      .. " requires SchedulerKit API 1 to be loaded first",
    2
  )
end

local parts = rawget(state, "parts")
if type(rawget(parts, "Coalescing")) ~= "table" then
  error(
    "MoltenCodes SchedulerKit part "
      .. PART_NAME
      .. " requires SchedulerKit part Coalescing to be loaded first",
    2
  )
end
local installed = rawget(parts, PART_NAME)
if
  type(installed) == "table"
  and type(installed.revision) == "number"
  and installed.revision >= PART_REVISION
then
  -- An equal or newer revision of this part already serves every watcher.
  return SchedulerKit
end

---@cast SchedulerKit table
-- Read at call time, never copied: an upgraded core or Coalescing part
-- serves this part.
local helpers = rawget(state, "helpers")
local family = rawget(state, "familyHelpers")
local sharedLimits = rawget(state, "limits")
local UNBOUNDED = rawget(state, "unbounded")
local WATCH_METATABLE = rawget(rawget(state, "familyMetatables"), "watch")
local Scope = rawget(SchedulerKit, "Scope")
local FAMILY_PROTOTYPES = rawget(state, "familyPrototypes")

-- Watch -------------------------------------------------------------------
--
-- Watchers are grouped by interval; each group owns one TimerKit ticker in
-- the package-internal timer scope, created with its first watcher and
-- cancelled with its last. A tick samples the group's watchers in creation
-- order. Watchers cancelled during a tick are compacted out after it, and
-- watchers added during a tick start with the next one.

---Shared TimerKit ticker callback for every watch group.
---@param timerHandle TimerKit.Timer
local function watchTickCallback(timerHandle)
  if type(timerHandle) ~= "table" then
    return
  end
  local group = timerHandle:GetUserData()
  if type(group) ~= "table" then
    return
  end
  local ok, value = pcall(family.dispatchEntry("watchTick"), group)
  if not ok then
    helpers.reportError(value)
  end
end

---Remove cancelled watchers from `group`, keeping creation order.
---@param group table
local function compactWatchGroup(group)
  local watchers = rawget(group, "watchers")
  local count = #watchers
  local write = 0
  for read = 1, count do
    local watcher = watchers[read]
    watchers[read] = nil
    if rawget(watcher, "_closed") ~= true then
      write = write + 1
      watchers[write] = watcher
    end
  end
  rawset(group, "dirty", false)
end

---Release `group` and its ticker once it has no live watcher.
---@param group table
local function releaseWatchGroupIfEmpty(group)
  if rawget(group, "live") > 0 or rawget(group, "released") == true then
    return
  end
  rawset(group, "released", true)
  local groups = rawget(state, "watchGroups")
  if rawget(groups, rawget(group, "interval")) == group then
    rawset(groups, rawget(group, "interval"), nil)
    rawset(state, "watchGroupCount", rawget(state, "watchGroupCount") - 1)
  end
  local ticker = rawget(group, "ticker")
  rawset(group, "ticker", false)
  if ticker ~= false then
    ticker:SetUserData(nil)
    ticker:Cancel()
  end
end

---Cancel one watcher. Terminal and idempotent.
---@param watcher SchedulerKit.WatchHandle
---@return boolean cancelled `false` when it was already cancelled.
local function cancelWatcher(watcher)
  if rawget(watcher, "_closed") == true then
    return false
  end
  rawset(watcher, "_closed", true)
  family.unlinkMember(watcher)
  rawset(watcher, "_value", nil)

  local group = rawget(watcher, "_group")
  rawset(group, "live", rawget(group, "live") - 1)
  if rawget(group, "ticking") == true then
    rawset(group, "dirty", true)
    return true
  end
  compactWatchGroup(group)
  releaseWatchGroupIfEmpty(group)
  return true
end

---Whether two predicate results differ. Its own function so the comparison
---can be protected without a closure: comparing a secret value, or two
---tables whose `__eq` raises, is an error.
---@param value any
---@param previous any
---@return boolean differs
local function resultsDiffer(value, previous)
  return value ~= previous
end

---Sample one watcher and call back on a change, or on every tick.
---@param watcher SchedulerKit.WatchHandle
local function sampleWatcher(watcher)
  local ok, value = xpcall(rawget(watcher, "_predicate"), family.captureFailure)
  if not ok then
    -- A predicate that raises would raise again on every tick; the
    -- watcher is cancelled after the failure is reported once.
    helpers.reportError(value)
    cancelWatcher(watcher)
    return
  end

  local previous = rawget(watcher, "_value")
  local changed = rawget(watcher, "_sampled") ~= true or rawget(watcher, "_everyTick") == true
  rawset(watcher, "_sampled", true)
  rawset(watcher, "_value", value)
  if not changed then
    local compared, differs = pcall(resultsDiffer, value, previous)
    if not compared then
      -- A result that cannot be compared would fail again on every
      -- tick, and escaping here would skip the rest of the group's
      -- tick; it is treated like a raising predicate.
      helpers.reportError(differs)
      cancelWatcher(watcher)
      return
    end
    changed = differs
  end
  if changed then
    -- Reported with a traceback, like the predicate.
    family.callProtected(rawget(watcher, "_callback"), 2, value, previous)
  end
end

---One tick of a watch group.
---@param group table
local function watchTick(group)
  if rawget(group, "released") == true then
    return
  end
  rawset(group, "ticking", true)
  local watchers = rawget(group, "watchers")
  local count = #watchers
  for index = 1, count do
    local watcher = watchers[index]
    if rawget(watcher, "_closed") ~= true then
      sampleWatcher(watcher)
    end
  end
  rawset(group, "ticking", false)
  if rawget(group, "dirty") == true then
    compactWatchGroup(group)
  end
  releaseWatchGroupIfEmpty(group)
end

---Return the watch group for `interval`, creating it and its ticker.
---@param interval number
---@param methodName string public method name, used in the argument errors
---@return table group
local function ensureWatchGroup(interval, methodName)
  local groups = rawget(state, "watchGroups")
  local group = rawget(groups, interval)
  if group ~= nil then
    local maxWatchers = rawget(sharedLimits, "maxWatchersPerInterval")
    if maxWatchers ~= UNBOUNDED and rawget(group, "live") >= maxWatchers then
      error(
        methodName
          .. " refuses more than "
          .. maxWatchers
          .. " watchers on one interval; cancel unused watchers or raise"
          .. " SchedulerKit:SetLimits{ maxWatchersPerInterval }",
        4
      )
    end
    return group
  end

  local maxIntervals = rawget(sharedLimits, "maxWatchIntervals")
  if rawget(state, "watchGroupCount") >= maxIntervals then
    error(
      methodName
        .. " refuses more than "
        .. maxIntervals
        .. " distinct watch intervals; reuse an interval or raise"
        .. " SchedulerKit:SetLimits{ maxWatchIntervals }",
      4
    )
  end

  group = {
    interval = interval,
    watchers = {},
    live = 0,
    ticker = false,
    ticking = false,
    dirty = false,
    released = false,
  }
  local ticker = family.ensureFamilyTimerScope():Every(interval, watchTickCallback)
  if type(ticker) ~= "table" then
    error("MoltenCodes SchedulerKit TimerKit returned an invalid timer handle", 0)
  end
  ticker:SetUserData(group)
  rawset(group, "ticker", ticker)
  rawset(groups, interval, group)
  rawset(state, "watchGroupCount", rawget(state, "watchGroupCount") + 1)
  return group
end

local WATCH_OPTION_KEYS = { everyTick = true }

---Build a watcher in `scope`, joining or creating its interval group.
---@param scope SchedulerKit.Scope
---@param predicate any
---@param interval any
---@param callback any
---@param options any
---@param methodName string public method name, used in the argument errors
---@return SchedulerKit.WatchHandle
local function createWatch(scope, predicate, interval, callback, options, methodName)
  family.ensureScopeOpen(scope, methodName)
  if type(predicate) ~= "function" then
    error(methodName .. " predicate must be a function", 3)
  end
  helpers.validateFinitePositive(interval, methodName .. " intervalSeconds", false, 4)
  if type(callback) ~= "function" then
    error(methodName .. " callback must be a function", 3)
  end
  family.validateOptionTable(options, WATCH_OPTION_KEYS, methodName, 4)
  local everyTick = false
  if type(options) ~= "nil" then
    family.validateOptionalBoolean(rawget(options, "everyTick"), methodName .. " everyTick", 4)
    everyTick = rawget(options, "everyTick") == true
  end

  local group = ensureWatchGroup(interval, methodName)
  local watcher = setmetatable({
    _kind = "watch",
    _scope = scope,
    _linked = false,
    _familyPrev = false,
    _familyNext = false,
    _closed = false,
    _predicate = predicate,
    _callback = callback,
    _everyTick = everyTick,
    _group = group,
    _sampled = false,
    _value = nil,
  }, WATCH_METATABLE)
  local watchers = rawget(group, "watchers")
  watchers[#watchers + 1] = watcher
  rawset(group, "live", rawget(group, "live") + 1)
  family.linkMember(scope, watcher)
  return watcher
end

---Stop polling. Terminal; releases the interval's ticker with its last watcher.
---@param self SchedulerKit.WatchHandle
---@return boolean cancelled `false` when it was already cancelled.
local function watchHandleCancel(self)
  family.validateMember(self, WATCH_METATABLE, "SchedulerKit.WatchHandle:Cancel", "watch handle")
  return cancelWatcher(self)
end

---Whether the watcher is still polling.
---@param self SchedulerKit.WatchHandle
---@return boolean active
local function watchHandleIsActive(self)
  family.validateMember(self, WATCH_METATABLE, "SchedulerKit.WatchHandle:IsActive", "watch handle")
  return rawget(self, "_closed") ~= true
end

---Poll `predicate` every `intervalSeconds` in this scope.
---@param self SchedulerKit.Scope
---@param predicate fun(): any
---@param intervalSeconds number Finite seconds greater than zero.
---@param callback SchedulerKit.WatchCallback
---@param options SchedulerKit.WatchOptions?
---@return SchedulerKit.WatchHandle handle
local function scopeWatch(self, predicate, intervalSeconds, callback, options)
  helpers.validateScope(self, "SchedulerKit.Scope:Watch")
  local handle =
    createWatch(self, predicate, intervalSeconds, callback, options, "SchedulerKit.Scope:Watch")
  return handle
end
---Poll `predicate` in SchedulerKit's package-level scope.
---@param _ SchedulerKit
---@param predicate fun(): any
---@param intervalSeconds number Finite seconds greater than zero.
---@param callback SchedulerKit.WatchCallback
---@param options SchedulerKit.WatchOptions?
---@return SchedulerKit.WatchHandle handle
local function packageWatch(_, predicate, intervalSeconds, callback, options)
  local handle = createWatch(
    helpers.getDefaultScope(),
    predicate,
    intervalSeconds,
    callback,
    options,
    "SchedulerKit:Watch"
  )
  return handle
end

-- Commit ---------------------------------------------------------------------

rawset(Scope, "Watch", scopeWatch)

local WATCH_PROTOTYPE = rawget(FAMILY_PROTOTYPES, "watch")
rawset(WATCH_PROTOTYPE, "Cancel", watchHandleCancel)
rawset(WATCH_PROTOTYPE, "IsActive", watchHandleIsActive)

rawset(SchedulerKit, "Watch", packageWatch)

-- What the Coalescing part calls when a scope closes or cancels its members.
rawset(family, "cancelWatcher", cancelWatcher)

rawset(rawget(state, "dispatch"), "watchTick", watchTick)

rawset(parts, PART_NAME, { revision = PART_REVISION })

return SchedulerKit
