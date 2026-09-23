--- Package-specific test environment for the ReadinessKit suite.
---
--- The World of Warcraft stubs, the `package.loaded` bookkeeping and the error
--- capture live in the shared `FrameworkTestEnv` fixture at `tests/support/`.
--- What stays here is this package's own module load order and the helpers
--- only its specs describe: driving poll timers, a host without EventKit, a
--- host without the clock, allocation measurement and an in-place upgrade.
---
--- TimerKit depends on LifecycleKit, which depends on EventKit and SignalKit,
--- so every module below is already in the manifest dependency closure the
--- test runner puts on `LUA_PATH`; no path entry has to be added here.
local FrameworkTestEnv = require("FrameworkTestEnv")

local ReadinessKitTestEnv = FrameworkTestEnv.New({
    modules = { "Registry", "SignalKit", "EventKit", "LifecycleKit", "TimerKit", "ReadinessKit" },
})

---Return how many native timers are still armed (neither cancelled nor spent).
---@return integer
function ReadinessKitTestEnv.ArmedTimerCount()
    local count = 0
    local natives = ReadinessKitTestEnv.NativeTimers()
    for index = 1, #natives do
        if not natives[index].cancelled then
            count = count + 1
        end
    end
    return count
end

---Advance the clock by `milliseconds` and fire every armed native timer once,
---which is what one poll interval looks like to every polling gate.
---@param milliseconds integer
---@return integer fired how many timers fired
function ReadinessKitTestEnv.Poll(milliseconds)
    ReadinessKitTestEnv.AdvanceMs(milliseconds)
    local fired = 0
    local natives = ReadinessKitTestEnv.NativeTimers()
    -- Snapshot the count: a tick that restarts a timer appends a new native,
    -- and that one belongs to the next interval.
    local count = #natives
    for index = 1, count do
        if ReadinessKitTestEnv.FireNative(index) then
            fired = fired + 1
        end
    end
    return fired
end

---Load the module chain, then make `Registry:Find` report EventKit as absent.
---
---EventKit cannot really be missing: TimerKit's own dependency chain loads it.
---What ReadinessKit has to survive is `Registry:Find` refusing it (absent, a
---generation mismatch, a retired copy), so the helper replaces `Find` on the
---Registry facade with one that refuses EventKit and answers everything else.
---@return table ReadinessKit
---@return table Registry
function ReadinessKitTestEnv.NewPackageWithoutEventKit()
    local ReadinessKit, Registry = ReadinessKitTestEnv.NewPackage()
    local find = rawget(Registry, "Find")
    rawset(Registry, "Find", function(self, packageName, api)
        if packageName == "eventKit" then
            return nil, "absent"
        end
        return find(self, packageName, api)
    end)
    return ReadinessKit, Registry
end

---Load the module chain on a host that has no `GetTimePreciseSec`.
---@return table ReadinessKit
function ReadinessKitTestEnv.NewPackageWithoutClock()
    ReadinessKitTestEnv.Reset()
    ReadinessKitTestEnv.InstallWowApi()
    -- The package reads this host global at load time, so the helper has to remove it from the global table.
    -- selene: allow(global_usage)
    rawset(_G, "GetTimePreciseSec", nil)
    require("Registry")
    require("SignalKit")
    require("EventKit")
    require("LifecycleKit")
    require("TimerKit")
    return require("ReadinessKit")
end

---Measure the allocation a workload causes, in kilobytes, with the collector
---stopped so that a collection cycle cannot hide or invent growth.
---@param workload fun()
---@return number kilobytes
function ReadinessKitTestEnv.AllocatedKilobytes(workload)
    collectgarbage()
    collectgarbage("stop")
    local before = collectgarbage("count")
    workload()
    local after = collectgarbage("count")
    collectgarbage("restart")
    return after - before
end

---Load the ReadinessKit source again as a copy carrying `revision`, the way a
---newer embedded copy loads over an older one in the client.
---@param revision integer
---@return table ReadinessKit
function ReadinessKitTestEnv.LoadRevision(revision)
    -- Lua 5.1 has no `package.searchpath`, so walk the path templates the way
    -- `require` does.
    local path = nil
    for template in package.path:gmatch("[^;]+") do
        local candidate = template:gsub("%?", "ReadinessKit")
        local file = io.open(candidate, "r")
        if file ~= nil then
            file:close()
            path = candidate
            break
        end
    end
    if path == nil then
        error("ReadinessKitTestEnv.LoadRevision could not find ReadinessKit.lua on package.path", 2)
    end

    local file = assert(io.open(path, "r"))
    local text = file:read("*a")
    file:close()

    local patched, replacements = text:gsub(
        "local IMPLEMENTATION_REVISION = %d+",
        "local IMPLEMENTATION_REVISION = " .. revision
    )
    if replacements ~= 1 then
        error("ReadinessKitTestEnv.LoadRevision could not find IMPLEMENTATION_REVISION", 2)
    end

    local chunk = assert(loadstring(patched, "@" .. path))
    return chunk()
end

return ReadinessKitTestEnv
