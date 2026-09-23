--- Package-specific test environment for the CacheKit suite.
---
--- The World of Warcraft stubs, the `package.loaded` bookkeeping and the error
--- capture live in the shared `FrameworkTestEnv` fixture at `tests/support/`.
--- What stays here is this package's own module load order, and the one path
--- entry that order needs.
---
--- EventKit is an optional dependency of CacheKit: only `cache:ClearOn` uses
--- it, found through `Registry:Find` at call time. The manifest schema has no
--- field for an optional dependency, so the test runner, which builds
--- `LUA_PATH` from the manifest dependency closure, does not put EventKit (or
--- the SignalKit it needs) on the path. This file adds their source
--- directories, located relative to this file rather than to the working
--- directory, so the clear-on-event specs run against the real EventKit.
local FrameworkTestEnv = require("FrameworkTestEnv")

---Append the `src` directory of each named sibling package to `package.path`.
---@param packageNames string[]
local function addSiblingSources(packageNames)
    local source = debug.getinfo(1, "S").source
    local packagesDirectory = source:match("^@(.*)[/\\]cacheKit[/\\]tests[/\\]support[/\\][^/\\]+$")
    if packagesDirectory == nil then
        packagesDirectory = "packages"
    end

    for index = 1, #packageNames do
        local entry = packagesDirectory .. "/" .. packageNames[index] .. "/src/?.lua"
        if not package.path:find(entry, 1, true) then
            package.path = package.path .. ";" .. entry
        end
    end
end

addSiblingSources({ "signalKit", "eventKit" })

local CacheKitTestEnv = FrameworkTestEnv.New({
    modules = { "Registry", "SignalKit", "EventKit", "CacheKit" },
})

---Load Registry and CacheKit only, as a consumer that embeds no EventKit does.
---@return table CacheKit
---@return table Registry
function CacheKitTestEnv.NewPackageWithoutEventKit()
    CacheKitTestEnv.Reset()
    CacheKitTestEnv.InstallWowApi()
    local Registry = require("Registry")
    local CacheKit = require("CacheKit")
    return CacheKit, Registry
end

---Load the module chain on a host that has no `GetTimePreciseSec`.
---@return table CacheKit
function CacheKitTestEnv.NewPackageWithoutClock()
    CacheKitTestEnv.Reset()
    CacheKitTestEnv.InstallWowApi()
    -- The package reads this host global at load time, so the helper has to remove it from the global table.
    -- selene: allow(global_usage)
    rawset(_G, "GetTimePreciseSec", nil)
    require("Registry")
    require("SignalKit")
    require("EventKit")
    return require("CacheKit")
end

---Measure the allocation a workload causes, in kilobytes, with the collector
---stopped so that a collection cycle cannot hide or invent growth.
---@param workload fun()
---@return number kilobytes
function CacheKitTestEnv.AllocatedKilobytes(workload)
    collectgarbage()
    collectgarbage("stop")
    local before = collectgarbage("count")
    workload()
    local after = collectgarbage("count")
    collectgarbage("restart")
    return after - before
end

---Load the CacheKit source again as a copy carrying `revision`, the way a
---newer embedded copy loads over an older one in the client.
---@param revision integer
---@return table CacheKit
function CacheKitTestEnv.LoadRevision(revision)
    -- Lua 5.1 has no `package.searchpath`, so walk the path templates the way
    -- `require` does.
    local path = nil
    for template in package.path:gmatch("[^;]+") do
        local candidate = template:gsub("%?", "CacheKit")
        local file = io.open(candidate, "r")
        if file ~= nil then
            file:close()
            path = candidate
            break
        end
    end
    if path == nil then
        error("CacheKitTestEnv.LoadRevision could not find CacheKit.lua on package.path", 2)
    end

    local file = assert(io.open(path, "r"))
    local text = file:read("*a")
    file:close()

    local patched, replacements = text:gsub(
        "local IMPLEMENTATION_REVISION = %d+",
        "local IMPLEMENTATION_REVISION = " .. revision
    )
    if replacements ~= 1 then
        error("CacheKitTestEnv.LoadRevision could not find IMPLEMENTATION_REVISION", 2)
    end

    local chunk = assert(loadstring(patched, "@" .. path))
    return chunk()
end

return CacheKitTestEnv
