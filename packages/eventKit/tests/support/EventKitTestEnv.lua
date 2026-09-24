--- Package-specific test environment for the EventKit suite.
---
--- The World of Warcraft stubs, the `package.loaded` bookkeeping and the error
--- capture live in the shared `FrameworkTestEnv` fixture at `tests/support/`.
--- What stays here is this package's own module load order, and a second
--- environment for the specs that need SchedulerKit.
---
--- SchedulerKit is an optional partner of EventKit: `Coalesce` and `Derive`
--- find it through `Registry:Find` when they are called. The manifest declares
--- it under `optionalDependencies`, so the test runner puts SchedulerKit and
--- the TimerKit it needs on `LUA_PATH` for this suite while the release load
--- order ignores them.
---
--- LifecycleKit is optional too: an addon scope asks it, through
--- `Registry:Find`, whether it closes the scope at logout. The manifest
--- declares it under `optionalDependencies`, so it is on `LUA_PATH` as well;
--- `LoadLifecycleKit` loads it on top of the chain and `Reset` unloads it.
---
--- The combat-log fake here replaces the shared fixture's: `ConnectCombatLog`
--- forwards every return of `CombatLogGetCurrentEventInfo()` with its count
--- intact, so the fake has to return exactly the values a spec set, holes and
--- trailing `nil`s included, and count how often it was read.
---
--- EventKit probes `C_EventUtils.IsEventValid` once, when it loads. The shared
--- fixture installs no `C_EventUtils` without a client profile, so by default
--- the suite runs the "absent" profile: an unknown event name reaches the
--- Frame stub's `RegisterEvent`, as on a client without the function.
--- `NewPackageKnowingEvents` and `Scheduled.NewEventKitKnowingEvents` run the
--- "present" profile: a `C_EventUtils.IsEventValid` fake that knows exactly the
--- names given and counts its calls, installed before EventKit loads.
local FrameworkTestEnv = require("FrameworkTestEnv")

local EventKitTestEnv = FrameworkTestEnv.New({
  modules = { "Registry", "SignalKit", "EventKit" },
})

local resetFixture = EventKitTestEnv.Reset
local installWowApi = EventKitTestEnv.InstallWowApi

-- Lua 5.1 publishes unpack as a global; newer interpreters move it onto table.
-- selene: allow(global_usage)
local unpackValues = rawget(table, "unpack") or rawget(_G, "unpack")

-- The values the fake returns, their exact count, and how often it was read.
local combatLogValues = {}
local combatLogValueCount = 0
local combatLogReads = 0

---Install a `CombatLogGetCurrentEventInfo` that returns exactly the values set
---through `SetCombatLogEventInfo` and counts its calls.
---
---EventKit resolves the API when its first combat-log listener connects, so
---the fake is installed with the other host globals, before the package loads.
function EventKitTestEnv.InstallCombatLogEventInfo()
  combatLogValues = {}
  combatLogValueCount = 0
  combatLogReads = 0
  -- The fixture stands in for the World of Warcraft client, whose API only exists in the global table.
  -- selene: allow(global_usage)
  rawset(_G, "CombatLogGetCurrentEventInfo", function()
    combatLogReads = combatLogReads + 1
    return unpackValues(combatLogValues, 1, combatLogValueCount)
  end)
end

-- The names the `C_EventUtils.IsEventValid` fake knows, and how often it was
-- asked since it was installed.
local knownEvents = {}
local eventValidityChecks = 0

---Install a `C_EventUtils` whose `IsEventValid` answers `true` for the names
---in `names` and `false` for every other string, counting its calls.
---
---EventKit probes the function once, when it loads, so a spec installs the
---fake before loading EventKit (`NewPackageKnowingEvents` does both) to run the
---"present" profile. Installed after EventKit loaded, it is never consulted.
---The shared fixture owns the `C_EventUtils` global and clears it on `Reset`.
---@param names string[] the event names the client knows
function EventKitTestEnv.InstallEventValidity(names)
  knownEvents = {}
  for index = 1, #names do
    knownEvents[names[index]] = true
  end
  eventValidityChecks = 0
  -- The fixture stands in for the World of Warcraft client, whose API only exists in the global table.
  -- selene: allow(global_usage)
  rawset(_G, "C_EventUtils", {
    IsEventValid = function(eventName)
      eventValidityChecks = eventValidityChecks + 1
      return knownEvents[eventName] == true
    end,
  })
end

---Make the installed `IsEventValid` fake know, or forget, one event name.
---@param eventName string
---@param known boolean
function EventKitTestEnv.SetEventKnown(eventName, known)
  knownEvents[eventName] = known == true or nil
end

---How many times the `IsEventValid` fake was called since it was installed.
---@return integer checks
function EventKitTestEnv.EventValidityChecks()
  return eventValidityChecks
end

---Install the shared host stubs, then this package's combat-log fake on top.
function EventKitTestEnv.InstallWowApi()
  installWowApi()
  EventKitTestEnv.InstallCombatLogEventInfo()
end

---Reset the shared fixture, unload LifecycleKit and forget the combat-log fake,
---including a `C_CombatLog` namespace a spec installed. The shared fixture does
---not own that global, because only EventKit reads it.
function EventKitTestEnv.Reset()
  resetFixture()
  package.loaded["LifecycleKit"] = nil
  -- selene: allow(global_usage)
  rawset(_G, "C_CombatLog", nil)
  combatLogValues = {}
  combatLogValueCount = 0
  combatLogReads = 0
  knownEvents = {}
  eventValidityChecks = 0
end

---Load Registry, SignalKit and EventKit, as `NewPackage` does, on a client
---whose `C_EventUtils.IsEventValid` knows exactly `names` (the "present"
---profile).
---@param names string[] the event names the client knows
---@return table EventKit
---@return table Registry
---@return table SignalKit
function EventKitTestEnv.NewPackageKnowingEvents(names)
  EventKitTestEnv.Reset()
  EventKitTestEnv.InstallWowApi()
  EventKitTestEnv.InstallEventValidity(names)
  local Registry = require("Registry")
  local SignalKit = require("SignalKit")
  return require("EventKit"), Registry, SignalKit
end

---Set what `CombatLogGetCurrentEventInfo()` returns next: exactly these
---values, `nil` holes and trailing `nil`s preserved.
---@param ... any `timestamp, subEvent, hideCaster, sourceGUID, ...`
function EventKitTestEnv.SetCombatLogEventInfo(...)
  combatLogValueCount = select("#", ...)
  combatLogValues = { ... }
end

---How many times `CombatLogGetCurrentEventInfo()` was called since the fake
---was installed or the environment reset.
---@return integer reads
function EventKitTestEnv.CombatLogEventInfoReads()
  return combatLogReads
end

---Deliver one combat-log event the way the client does: set what the API
---returns, then emit the payload-free `COMBAT_LOG_EVENT_UNFILTERED`.
---@param ... any `timestamp, subEvent, hideCaster, sourceGUID, ...`
function EventKitTestEnv.EmitCombatLogEvent(...)
  EventKitTestEnv.SetCombatLogEventInfo(...)
  EventKitTestEnv.Emit("COMBAT_LOG_EVENT_UNFILTERED")
end

---Load LifecycleKit after the chain `NewPackage` loaded.
---@return table LifecycleKit
function EventKitTestEnv.LoadLifecycleKit()
  return require("LifecycleKit")
end

---An environment that also loads SchedulerKit and its required dependencies,
---for the coalescing specs. The chain is in dependency order; use
---`NewEventKit` to get the two packages the specs use.
local Scheduled = FrameworkTestEnv.New({
  modules = {
    "Registry",
    "SignalKit",
    "EventKit",
    "TimerKit",
    "SchedulerKit",
  },
})

---Load the full chain and return EventKit and SchedulerKit.
---@return table EventKit
---@return table SchedulerKit
function Scheduled.NewEventKit()
  local SchedulerKit, _, _, EventKit = Scheduled.NewPackage()
  return EventKit, SchedulerKit
end

---Load the full chain, as `NewEventKit` does, on a client whose
---`C_EventUtils.IsEventValid` knows exactly `names`.
---@param names string[] the event names the client knows
---@return table EventKit
---@return table SchedulerKit
function Scheduled.NewEventKitKnowingEvents(names)
  Scheduled.Reset()
  Scheduled.InstallWowApi()
  EventKitTestEnv.InstallEventValidity(names)
  require("Registry")
  require("SignalKit")
  local EventKit = require("EventKit")
  require("TimerKit")
  return EventKit, require("SchedulerKit")
end

EventKitTestEnv.Scheduled = Scheduled

---Run the EventKit source once more as a copy carrying `revision`, the way a
---second addon embedding a different copy would. The copy is the current
---source with only `IMPLEMENTATION_REVISION` changed, so it stands in for an
---older or newer revision whose `_state` schema matches this one.
---@param revision integer
---@return table EventKit the facade the copy returned
function EventKitTestEnv.LoadSourceAtRevision(revision)
  -- Lua 5.1 has no `package.searchpath`, so walk the templates by hand.
  local path, file = nil, nil
  for template in string.gmatch(package.path, "[^;]+") do
    local candidate = string.gsub(template, "%?", "EventKit")
    file = io.open(candidate, "rb")
    if file ~= nil then
      path = candidate
      break
    end
  end
  if file == nil then
    error("EventKitTestEnv cannot find EventKit.lua on package.path", 2)
  end
  local source = file:read("*a")
  file:close()

  local patched, count = source:gsub(
    "local IMPLEMENTATION_REVISION = %d+",
    "local IMPLEMENTATION_REVISION = " .. revision,
    1
  )
  if count ~= 1 then
    error("EventKitTestEnv found no IMPLEMENTATION_REVISION in " .. path, 2)
  end
  local chunk = assert(loadstring(patched, "@" .. path))
  return chunk()
end

return EventKitTestEnv
