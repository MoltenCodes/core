--- Package-specific test environment for the SignalKit suite.
---
--- The World of Warcraft stubs, the `package.loaded` bookkeeping and the error
--- capture live in the shared `FrameworkTestEnv` fixture at `tests/support/`.
--- What stays here is this package's own module load order and the helpers
--- only its specs describe: a host with `securecallfunction`, allocation
--- measurement and loading the source as another revision.
local FrameworkTestEnv = require("FrameworkTestEnv")

local SignalKitTestEnv = FrameworkTestEnv.New({
    modules = { "Registry", "SignalKit" },
    -- SignalKit is pure Lua: outside its bus boundary it never touches a World
    -- of Warcraft API, so specs opt into the host error sink explicitly.
    wowApi = false,
    legacyRegistryState = true,
})

---Load the module chain on a host that has `geterrorhandler` and
---`securecallfunction`, so bus deliveries take the modern-client path.
---
---SignalKit chooses its isolation function when it loads, so the stubs have to
---be installed before the package is required.
---@return table SignalKit
---@return table Registry
function SignalKitTestEnv.NewPackageWithSecureCall()
    SignalKitTestEnv.Reset()
    SignalKitTestEnv.InstallHostErrorHandler()
    SignalKitTestEnv.InstallSecureCallFunction()
    local Registry = require("Registry")
    local SignalKit = require("SignalKit")
    return SignalKit, Registry
end

---Measure the allocation a workload causes, in kilobytes, with the collector
---stopped so that a collection cycle cannot hide or invent growth.
---@param workload fun()
---@return number kilobytes
function SignalKitTestEnv.AllocatedKilobytes(workload)
    collectgarbage()
    collectgarbage("stop")
    local before = collectgarbage("count")
    workload()
    local after = collectgarbage("count")
    collectgarbage("restart")
    return after - before
end

---Load the SignalKit source again as a copy carrying `revision`, the way
---another embedded copy loads beside an earlier one in the client.
---@param revision integer
---@return table SignalKit
function SignalKitTestEnv.LoadRevision(revision)
    -- Lua 5.1 has no `package.searchpath`, so walk the path templates the way
    -- `require` does.
    local path = nil
    for template in package.path:gmatch("[^;]+") do
        local candidate = template:gsub("%?", "SignalKit")
        local file = io.open(candidate, "r")
        if file ~= nil then
            file:close()
            path = candidate
            break
        end
    end
    if path == nil then
        error("SignalKitTestEnv.LoadRevision could not find SignalKit.lua on package.path", 2)
    end

    local file = io.open(path, "r")
    if file == nil then
        error("SignalKitTestEnv.LoadRevision could not open " .. path, 2)
    end
    local text = file:read("*a")
    file:close()

    local patched, replacements = text:gsub(
        "local IMPLEMENTATION_REVISION = %d+",
        "local IMPLEMENTATION_REVISION = " .. revision
    )
    if replacements ~= 1 then
        error("SignalKitTestEnv.LoadRevision could not find IMPLEMENTATION_REVISION", 2)
    end

    local chunk, failure = loadstring(patched, "@" .. path)
    if chunk == nil then
        error(
            "SignalKitTestEnv.LoadRevision could not compile " .. path .. ": " .. tostring(failure),
            2
        )
    end
    return chunk()
end

return SignalKitTestEnv
