--- Package-specific test environment for the EventKit suite.
---
--- The World of Warcraft stubs, the `package.loaded` bookkeeping and the error
--- capture live in the shared `FrameworkTestEnv` fixture at `tests/support/`.
--- What stays here is this package's own module load order, and a second
--- environment for the specs that need the Coalescing part and its timers.
---
--- `NewPackage` loads the core with the Units and CombatLog parts, which most
--- specs use; `NewCore` loads the core alone. SignalKit stays in the chain
--- because the Coalescing part needs it; the core does not, which
--- `NewPackageWithout("SignalKit")` shows.
---
--- `Coalesce` and `Derive` are EventKit's Coalescing part
--- (`EventKit-Coalescing`), timed by TimerKit; a `lane` uses SchedulerKit's
--- `Coalesce`. Both Kits are optional: the part finds them through
--- `Registry:Find` when it needs them. The manifest declares them under the
--- part's `optionalDependencies`, so the test runner puts them on `LUA_PATH`
--- for this suite while the release load order ignores them. `NewPackage`
--- loads the core alone; `LoadCoalescing` adds the part on top, and the
--- `Scheduled` environment loads TimerKit, SchedulerKit (with its own parts
--- when they exist) and the part.
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
local newCorePackage = EventKitTestEnv.NewPackage

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

-- Part modules no environment's chain lists, unloaded by every reset.
local PART_MODULES = {
  "EventKit-Units",
  "EventKit-CombatLog",
  "EventKit-Coalescing",
  "SchedulerKit-Coalescing",
  "SchedulerKit-Lanes",
  "SchedulerKit-Watch",
}

---Unload every part module, so the next load runs each part file again.
local function unloadParts()
  for index = 1, #PART_MODULES do
    package.loaded[PART_MODULES[index]] = nil
  end
end

---Load EventKit's Coalescing part on top of the core a spec loaded.
---@return table EventKit
function EventKitTestEnv.LoadCoalescing()
  return require("EventKit-Coalescing")
end

---Load EventKit's Units and CombatLog parts on top of the core a spec loaded.
---@return table EventKit
function EventKitTestEnv.LoadUnitsAndCombatLog()
  require("EventKit-Units")
  return require("EventKit-CombatLog")
end

---Load Registry, SignalKit and EventKit's core alone, without any part.
---@return table EventKit
---@return table Registry
---@return table SignalKit
function EventKitTestEnv.NewCore()
  return newCorePackage()
end

---Load Registry, SignalKit, EventKit and its Units and CombatLog parts.
---@return table EventKit
---@return table Registry
---@return table SignalKit
function EventKitTestEnv.NewPackage()
  local EventKit, Registry, SignalKit = newCorePackage()
  EventKitTestEnv.LoadUnitsAndCombatLog()
  return EventKit, Registry, SignalKit
end

---Load SchedulerKit's Coalescing and Lanes parts when this tree has them. A
---single-file SchedulerKit has both already, so their absence is no error.
function EventKitTestEnv.LoadSchedulerLaneParts()
  for _, moduleName in ipairs({ "SchedulerKit-Coalescing", "SchedulerKit-Lanes" }) do
    local found = false
    for template in string.gmatch(package.path, "[^;]+") do
      local file = io.open((string.gsub(template, "%?", moduleName)), "rb")
      if file ~= nil then
        file:close()
        found = true
        break
      end
    end
    if found then
      require(moduleName)
    end
  end
end

---Reset the shared fixture, unload LifecycleKit and the parts and forget the
---combat-log fake, including a `C_CombatLog` namespace a spec installed. The
---shared fixture does not own that global, because only EventKit reads it.
function EventKitTestEnv.Reset()
  resetFixture()
  unloadParts()
  package.loaded["LifecycleKit"] = nil
  -- selene: allow(global_usage)
  rawset(_G, "C_CombatLog", nil)
  combatLogValues = {}
  combatLogValueCount = 0
  combatLogReads = 0
  knownEvents = {}
  eventValidityChecks = 0
end

---Load Registry, SignalKit, EventKit and its Coalescing part on a client
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
  local EventKit = require("EventKit")
  EventKitTestEnv.LoadUnitsAndCombatLog()
  EventKitTestEnv.LoadCoalescing()
  return EventKit, Registry, SignalKit
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

---An environment that also loads TimerKit, SchedulerKit and the Coalescing
---part, for the coalescing specs. The chain is in dependency order; use
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

local resetScheduled = Scheduled.Reset

---Reset the chain and unload the parts loaded on top of it.
function Scheduled.Reset()
  resetScheduled()
  unloadParts()
end

---Load the full chain with SchedulerKit's lane parts and EventKit's
---Coalescing part, and return EventKit and SchedulerKit.
---@return table EventKit
---@return table SchedulerKit
function Scheduled.NewEventKit()
  local SchedulerKit, _, _, EventKit = Scheduled.NewPackage()
  unloadParts()
  EventKitTestEnv.LoadSchedulerLaneParts()
  EventKitTestEnv.LoadUnitsAndCombatLog()
  EventKitTestEnv.LoadCoalescing()
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
  local SchedulerKit = require("SchedulerKit")
  EventKitTestEnv.LoadSchedulerLaneParts()
  EventKitTestEnv.LoadUnitsAndCombatLog()
  EventKitTestEnv.LoadCoalescing()
  return EventKit, SchedulerKit
end

EventKitTestEnv.Scheduled = Scheduled

---An environment with TimerKit and no SchedulerKit, for the specs that show
---the Coalescing part times itself by TimerKit alone.
local Timed = FrameworkTestEnv.New({
  modules = { "Registry", "SignalKit", "EventKit", "TimerKit" },
})

local resetTimed = Timed.Reset

---Reset the chain and unload the parts loaded on top of it.
function Timed.Reset()
  resetTimed()
  unloadParts()
end

---Load the chain and the Coalescing part, and return EventKit and TimerKit.
---@return table EventKit
---@return table TimerKit
function Timed.NewEventKit()
  local TimerKit, _, _, EventKit = Timed.NewPackage()
  unloadParts()
  EventKitTestEnv.LoadUnitsAndCombatLog()
  EventKitTestEnv.LoadCoalescing()
  return EventKit, TimerKit
end

EventKitTestEnv.Timed = Timed

---Read a module's source from `package.path`.
---@param moduleName string
---@return string source
---@return string path
local function readModuleSource(moduleName)
  -- Lua 5.1 has no `package.searchpath`, so walk the templates by hand.
  for template in string.gmatch(package.path, "[^;]+") do
    local candidate = string.gsub(template, "%?", moduleName)
    local file = io.open(candidate, "rb")
    if file ~= nil then
      local source = file:read("*a")
      file:close()
      return source, candidate
    end
  end
  error("EventKitTestEnv cannot find " .. moduleName .. ".lua on package.path", 3)
end

---Run the EventKit source once more as a copy carrying `revision`, the way a
---second addon embedding a different copy would. The copy is the current
---source with only `IMPLEMENTATION_REVISION` changed, so it stands in for an
---older or newer revision whose `_state` schema matches this one. Only the
---core runs; the parts a spec needs it loads itself.
---@param revision integer
---@return table EventKit the facade the copy returned
function EventKitTestEnv.LoadSourceAtRevision(revision)
  local source, path = readModuleSource("EventKit")

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

-- Byte copies of the files revision 22 shipped: the core, with unit events
-- and the combat log in it, and the Coalescing part's revision 1. The upgrade
-- specs load them first, as an addon embedding that release would.
local SUPPORT_DIRECTORY = debug.getinfo(1, "S").source:match("^@(.*[/\\])") or "./"
local FIXTURES = {
  core = SUPPORT_DIRECTORY .. "../fixtures/EventKit-revision22.lua",
  coalescing = SUPPORT_DIRECTORY .. "../fixtures/EventKit-Coalescing-revision1.lua",
}

---Run one revision-22 fixture file.
---@param name string `"core"` or `"coalescing"`
---@return table EventKit the facade the file returned
function EventKitTestEnv.LoadRevision22(name)
  local path = FIXTURES[name]
  local file = assert(io.open(path, "rb"))
  local source = file:read("*a")
  file:close()
  return assert(loadstring(source, "@" .. path))()
end

return EventKitTestEnv
