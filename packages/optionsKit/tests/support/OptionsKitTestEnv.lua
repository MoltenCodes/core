--- Package-specific test environment for the OptionsKit suite.
---
--- The World of Warcraft stubs, the `package.loaded` bookkeeping and the error
--- capture live in the shared `FrameworkTestEnv` fixture at `tests/support/`.
--- What stays here is this package's own module load order and the helpers
--- only its specs describe: a SettingsKit stand-in for `bind` specs,
--- allocation measurement and an in-place upgrade.
---
--- SettingsKit is an optional dependency, declared under
--- `optionalDependencies`. Until its package lands, `InstallSettingsKitStub`
--- registers a stand-in under `settingsKit` API 1 so `Registry:Find` answers,
--- and `NewDatabase` builds a database with the documented shape: six scope
--- tables whose reads fall back to defaults through a metatable, and an
--- `OnChange` method.
local FrameworkTestEnv = require("FrameworkTestEnv")

local OptionsKitTestEnv = FrameworkTestEnv.New({
    modules = { "Registry", "SignalKit", "SchemaKit", "OptionsKit" },
})

--- The scopes a SettingsKit database exposes.
local SCOPES = { "global", "char", "realm", "class", "faction", "profile" }

---Register a SettingsKit API 1 stand-in with Registry, so that
---`Registry:Find("settingsKit", 1)` finds it.
---@param Registry table
---@return table SettingsKit the stand-in facade
function OptionsKitTestEnv.InstallSettingsKitStub(Registry)
    local SettingsKit = Registry:Register("settingsKit", 1, 1)
    rawset(SettingsKit, "API", 1)
    rawset(SettingsKit, "REVISION", 1)
    return SettingsKit
end

---Build a live table over `defaults`: reads of absent keys fall back to the
---default, writes land in the table itself, and nested default tables become
---nested live tables, as SettingsKit's scope tables behave.
---@param defaults table
---@return table live
local function newLiveTable(defaults)
    local live = {}
    for key, value in pairs(defaults) do
        if type(value) == "table" then
            live[key] = newLiveTable(value)
        end
    end
    return setmetatable(live, { __index = defaults })
end

---Build a SettingsKit-shaped database.
---@param defaults table? defaults per scope, such as `{ profile = { scale = 1 } }`
---@return table db
function OptionsKitTestEnv.NewDatabase(defaults)
    defaults = defaults or {}
    local db = {}
    for index = 1, #SCOPES do
        local scope = SCOPES[index]
        db[scope] = newLiveTable(defaults[scope] or {})
    end
    function db:OnChange(_, _)
        return nil
    end
    -- The stand-in's scopes declare no schema, so every write is accepted.
    function db:Validate(_, _, _)
        return true
    end
    return db
end

---Measure the allocation a workload causes, in kilobytes, with the collector
---stopped so that a collection cycle cannot hide or invent growth.
---@param workload fun()
---@return number kilobytes
function OptionsKitTestEnv.AllocatedKilobytes(workload)
    collectgarbage()
    collectgarbage("stop")
    local before = collectgarbage("count")
    workload()
    local after = collectgarbage("count")
    collectgarbage("restart")
    return after - before
end

---Load the OptionsKit source again as a copy carrying `revision`, the way a
---newer embedded copy loads over an older one in the client.
---@param revision integer
---@return table OptionsKit
function OptionsKitTestEnv.LoadRevision(revision)
    -- Lua 5.1 has no `package.searchpath`, so walk the path templates the way
    -- `require` does.
    local path = nil
    for template in package.path:gmatch("[^;]+") do
        local candidate = template:gsub("%?", "OptionsKit")
        local file = io.open(candidate, "r")
        if file ~= nil then
            file:close()
            path = candidate
            break
        end
    end
    if path == nil then
        error("OptionsKitTestEnv.LoadRevision could not find OptionsKit.lua on package.path", 2)
    end

    local file = assert(io.open(path, "r"))
    local text = file:read("*a")
    file:close()

    local patched, replacements = text:gsub(
        "local IMPLEMENTATION_REVISION = %d+",
        "local IMPLEMENTATION_REVISION = " .. revision
    )
    if replacements ~= 1 then
        error("OptionsKitTestEnv.LoadRevision could not find IMPLEMENTATION_REVISION", 2)
    end

    local chunk = assert(loadstring(patched, "@" .. path))
    return chunk()
end

return OptionsKitTestEnv
