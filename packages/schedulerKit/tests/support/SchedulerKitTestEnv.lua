--- Package-specific test environment for the SchedulerKit suite.
---
--- The World of Warcraft stubs, the `package.loaded` bookkeeping and the error
--- capture live in the shared `FrameworkTestEnv` fixture at `tests/support/`.
--- What stays here is this package's own module load order.
---
--- SchedulerKit requires Registry and TimerKit and nothing else, so the chain
--- is the three files an addon embeds to use SchedulerKit alone. LifecycleKit
--- and EventKit are optional dependencies that only decide who closes an addon
--- scope at logout. The manifest declares both under `optionalDependencies`,
--- so the test runner puts them and their required closures on `LUA_PATH`;
--- `LoadEventKit` and `LoadLifecycleKit` load them on top of the chain the way
--- an addon that also embeds them would, and `Reset` unloads them again.
local FrameworkTestEnv = require("FrameworkTestEnv")

local SchedulerKitTestEnv = FrameworkTestEnv.New({
    modules = {
        "Registry",
        "TimerKit",
        "SchedulerKit",
    },
})

--- The optional modules the helpers below may load, in load order.
local OPTIONAL_MODULES = { "SignalKit", "EventKit", "LifecycleKit" }

local resetFixture = SchedulerKitTestEnv.Reset

---Reset the shared fixture and unload the optional modules.
function SchedulerKitTestEnv.Reset()
    resetFixture()
    for index = #OPTIONAL_MODULES, 1, -1 do
        package.loaded[OPTIONAL_MODULES[index]] = nil
    end
end

---Load SignalKit and EventKit after the chain `NewPackage` loaded.
---@return table EventKit
function SchedulerKitTestEnv.LoadEventKit()
    require("SignalKit")
    return require("EventKit")
end

---Load SignalKit, EventKit and LifecycleKit after the chain `NewPackage`
---loaded.
---@return table LifecycleKit
---@return table EventKit
function SchedulerKitTestEnv.LoadLifecycleKit()
    local EventKit = SchedulerKitTestEnv.LoadEventKit()
    return require("LifecycleKit"), EventKit
end

---Measure the allocation a workload causes, in kilobytes, with the collector
---stopped so that a collection cycle cannot hide or invent growth.
---@param workload fun()
---@return number kilobytes
function SchedulerKitTestEnv.AllocatedKilobytes(workload)
    collectgarbage()
    collectgarbage("stop")
    local before = collectgarbage("count")
    workload()
    local after = collectgarbage("count")
    collectgarbage("restart")
    return after - before
end

---Run this package's own source as if it were implementation revision
---`revision`, to stand in for an older embedded copy in upgrade specs.
---
---The file is read from `package.path` and loaded with its
---`IMPLEMENTATION_REVISION` rewritten, so `require("SchedulerKit")` afterwards
---upgrades that copy in place.
---@param revision integer
---@return table SchedulerKit
function SchedulerKitTestEnv.LoadRevision(revision)
    -- Lua 5.1 has no `package.searchpath`, so walk the path templates the way
    -- `require` does.
    local path = nil
    for template in package.path:gmatch("[^;]+") do
        local candidate = template:gsub("%?", "SchedulerKit")
        local file = io.open(candidate, "r")
        if file ~= nil then
            file:close()
            path = candidate
            break
        end
    end
    if path == nil then
        error("SchedulerKitTestEnv.LoadRevision could not find SchedulerKit.lua on package.path", 2)
    end

    local file = assert(io.open(path, "r"))
    local text = file:read("*a")
    file:close()

    local patched, replacements = text:gsub(
        "local IMPLEMENTATION_REVISION = %d+",
        "local IMPLEMENTATION_REVISION = " .. revision
    )
    if replacements ~= 1 then
        error("SchedulerKitTestEnv.LoadRevision could not find IMPLEMENTATION_REVISION", 2)
    end

    local chunk = assert(loadstring(patched, "@" .. path))
    return chunk()
end

return SchedulerKitTestEnv
