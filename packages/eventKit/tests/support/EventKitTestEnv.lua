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
