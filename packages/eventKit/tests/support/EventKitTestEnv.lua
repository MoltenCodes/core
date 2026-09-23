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
local FrameworkTestEnv = require("FrameworkTestEnv")

local EventKitTestEnv = FrameworkTestEnv.New({
    modules = { "Registry", "SignalKit", "EventKit" },
})

local resetFixture = EventKitTestEnv.Reset

---Reset the shared fixture and unload LifecycleKit.
function EventKitTestEnv.Reset()
    resetFixture()
    package.loaded["LifecycleKit"] = nil
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
