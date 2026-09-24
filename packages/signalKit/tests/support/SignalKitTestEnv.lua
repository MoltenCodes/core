--- Package-specific test environment for the SignalKit suite.
---
--- The World of Warcraft stubs, the `package.loaded` bookkeeping and the error
--- capture live in the shared `FrameworkTestEnv` fixture at `tests/support/`.
--- What stays here is this package's own module load order and the helpers
--- only its specs describe: the refusal-at-the-caller assertion, a host with
--- `securecallfunction`, allocation measurement, loading the source as another
--- revision, and loading the two optional Kits that decide who closes an
--- addon's bus at logout.
---
--- EventKit and LifecycleKit are declared under `optionalDependencies`, so the
--- test runner puts them on `LUA_PATH`. `LoadEventKit` and `LoadLifecycleKit`
--- install the World of Warcraft stubs they need and load them on top of the
--- chain, after SignalKit, as an addon that embeds them would; `Reset` unloads
--- them again.
local FrameworkTestEnv = require("FrameworkTestEnv")
-- Busted injects `assert` into spec chunks only; this module is loaded through
-- plain `require`, so the refusal helper names luassert itself.
local assert = require("luassert")

local SignalKitTestEnv = FrameworkTestEnv.New({
    modules = { "Registry", "SignalKit" },
    -- SignalKit is pure Lua: outside its bus boundary it never touches a World
    -- of Warcraft API, so specs opt into the host error sink explicitly.
    wowApi = false,
    legacyRegistryState = true,
})

--- Modules a spec may load on top of the chain, in the order `Reset` unloads
--- them. They are not in the chain, so the shared `Reset` would leave them in
--- `package.loaded` bound to a Registry that no longer exists.
local OPTIONAL_MODULES = { "LifecycleKit", "EventKit" }

--- What LifecycleKit 0.6.0 publishes as `CLOSES_ADDON_SCOPES`: the package ids
--- whose addon scopes (or bus) it closes at shutdown.
local CLOSES_ADDON_SCOPES = {
    timerKit = true,
    schedulerKit = true,
    eventKit = true,
    hookKit = true,
    commandKit = true,
    commKit = true,
    signalKit = true,
}

local sharedReset = SignalKitTestEnv.Reset

---Clear every module, global and stub this environment owns, including the
---optional Kits a spec loaded.
function SignalKitTestEnv.Reset()
    for index = 1, #OPTIONAL_MODULES do
        package.loaded[OPTIONAL_MODULES[index]] = nil
    end
    sharedReset()
end

---Install the World of Warcraft stubs EventKit needs, then load it.
---@return table EventKit
function SignalKitTestEnv.LoadEventKit()
    SignalKitTestEnv.InstallWowApi()
    return require("EventKit")
end

---Load LifecycleKit (and EventKit, which it requires) on top of the chain,
---then make it announce `CLOSES_ADDON_SCOPES` or not.
---
---`closesAddonScopes` `true` models LifecycleKit 0.6.0 and later, `false` an
---older revision without the field. The field is written onto the loaded
---facade with `rawset`, whatever the revision on `LUA_PATH` publishes.
---@param closesAddonScopes boolean|table
---@return table LifecycleKit
---@return table EventKit
function SignalKitTestEnv.LoadLifecycleKit(closesAddonScopes)
    local EventKit = SignalKitTestEnv.LoadEventKit()
    local LifecycleKit = require("LifecycleKit")
    SignalKitTestEnv.SetClosesAddonScopes(LifecycleKit, closesAddonScopes)
    return LifecycleKit, EventKit
end

---Make `LifecycleKit` announce, or stop announcing, `CLOSES_ADDON_SCOPES`.
---@param LifecycleKit table
---@param closesAddonScopes boolean|table `true` for the full list, `false` for none, or a list of its own
function SignalKitTestEnv.SetClosesAddonScopes(LifecycleKit, closesAddonScopes)
    local value = nil
    if closesAddonScopes == true then
        value = CLOSES_ADDON_SCOPES
    elseif type(closesAddonScopes) == "table" then
        value = closesAddonScopes
    end
    rawset(LifecycleKit, "CLOSES_ADDON_SCOPES", value)
end

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

---Assert that `callback` raises a message naming `expected` at a line of
---`specFile` rather than somewhere inside the package, which is what "raised
---at the caller" means for every SignalKit refusal.
---@param specFile string the spec's repository-relative path followed by `:`
---@param expected string
---@param callback fun()
function SignalKitTestEnv.ExpectRefusalAtCaller(specFile, expected, callback)
    local ok, message = pcall(callback)
    message = tostring(message)

    assert.is_false(ok)
    assert.is_not_nil(string.find(message, expected, 1, true), message)
    assert.is_not_nil(string.find(message, specFile, 1, true), message)
    assert.is_nil(string.find(message, "src/SignalKit.lua", 1, true), message)
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
