--- Package-specific test environment for the SettingsKit suite.
---
--- The World of Warcraft stubs, the `package.loaded` bookkeeping and the error
--- capture live in the shared `FrameworkTestEnv` fixture at `tests/support/`.
--- What stays here is this package's own module load order and the host
--- surface only SettingsKit touches, which the shared fixture does not model:
---
---   `UnitName`, `GetRealmName`, `UnitClass`, `UnitFactionGroup`
---                        the player identity `Open` resolves its scope keys
---                        from, set by `SetPlayer`;
---   `issecretvalue`      installed by `InstallSecretProbe`, reporting the
---                        tables `NewSecret` returns;
---   saved variables      globals a spec names, removed by `Reset`.
---
--- These globals are not among the ones the shared fixture owns, so `Reset`
--- removes them itself. `issecretvalue` is owned by the fixture and cleared by
--- its own `Reset`.
---
--- EventKit is an optional dependency of SettingsKit, declared under
--- `optionalDependencies`, so the test runner puts it on `LUA_PATH` for this
--- suite; `NewPackageWithoutEventKit` models an addon that embeds none.
local FrameworkTestEnv = require("FrameworkTestEnv")

local SettingsKitTestEnv = FrameworkTestEnv.New({
    modules = { "Registry", "SignalKit", "EventKit", "SchemaKit", "SettingsKit" },
})

--- The player identity host functions this environment installs and removes.
local IDENTITY_GLOBALS = { "UnitName", "GetRealmName", "UnitClass", "UnitFactionGroup" }

--- The identity a fresh environment reports.
local DEFAULT_PLAYER =
    { name = "Tester", realm = "Silvermoon", class = "MAGE", faction = "Alliance" }

--- Saved-variable globals specs created through `SavedVariable`.
local savedVariables = {}

--- Tables the `issecretvalue` stub reports as secret. Weak-keyed so a spec's
--- secrets never outlive it.
local secrets = setmetatable({}, { __mode = "k" })

---Write a host global. The fixture stands in for the World of Warcraft client,
---whose API only exists in the global table.
---@param name string
---@param value any
local function setGlobal(name, value)
    -- selene: allow(global_usage)
    rawset(_G, name, value)
end

---Write a host global from a spec, for a host function a case replaces.
---@param name string
---@param value any
function SettingsKitTestEnv.SetGlobal(name, value)
    setGlobal(name, value)
end

---Read a host global the same way.
---@param name string
---@return any
function SettingsKitTestEnv.GetGlobal(name)
    -- selene: allow(global_usage)
    return rawget(_G, name)
end

---Install the four identity functions for `player`. A field set to `false`
---leaves that function out, so the scope it feeds is unavailable.
---@param player table? `{ name, realm, class, faction }`; omitted fields take the defaults
function SettingsKitTestEnv.SetPlayer(player)
    player = player or {}
    local function pick(field)
        local value = player[field]
        if value == nil then
            return DEFAULT_PLAYER[field]
        end
        return value
    end

    local name, realm, class, faction = pick("name"), pick("realm"), pick("class"), pick("faction")
    setGlobal("UnitName", name ~= false and function(unit)
        if unit == "player" then
            return name, nil
        end
        return nil
    end or nil)
    setGlobal("GetRealmName", realm ~= false and function()
        return realm
    end or nil)
    setGlobal("UnitClass", class ~= false and function(unit)
        if unit == "player" then
            return "Localized " .. class, class, 8
        end
        return nil
    end or nil)
    setGlobal("UnitFactionGroup", faction ~= false and function(unit)
        if unit == "player" then
            return faction, "Localized " .. faction
        end
        return nil
    end or nil)
end

---Set a saved-variable global, as the client does before `ADDON_LOADED`.
---`Reset` removes it.
---@param name string
---@param value any
function SettingsKitTestEnv.SavedVariable(name, value)
    savedVariables[name] = true
    setGlobal(name, value)
end

---Install an `issecretvalue` that reports the tables `NewSecret` returns.
function SettingsKitTestEnv.InstallSecretProbe()
    setGlobal("issecretvalue", function(value)
        return secrets[value] == true
    end)
end

---Return a new value the `issecretvalue` stub reports as secret.
---@return table secret
function SettingsKitTestEnv.NewSecret()
    local secret = {}
    secrets[secret] = true
    return secret
end

local baseReset = SettingsKitTestEnv.Reset
local baseNewPackage = SettingsKitTestEnv.NewPackage

---Clear the fixture, then the globals only this environment installs.
---
---`SettingsKit:Open` creates a missing saved variable, so the names of every
---database the package opened are read from its package state before the
---module chain is unloaded, and those globals are removed too.
function SettingsKitTestEnv.Reset()
    local SettingsKit = package.loaded["SettingsKit"]
    local packageState = type(SettingsKit) == "table" and rawget(SettingsKit, "_state") or nil
    local databases = type(packageState) == "table" and rawget(packageState, "databases") or nil
    if type(databases) == "table" then
        for name in pairs(databases) do
            savedVariables[name] = true
        end
    end

    baseReset()
    for index = 1, #IDENTITY_GLOBALS do
        setGlobal(IDENTITY_GLOBALS[index], nil)
    end
    for name in pairs(savedVariables) do
        setGlobal(name, nil)
        savedVariables[name] = nil
    end
end

---Load the module chain and install the default player identity.
---@return table SettingsKit, table Registry, table SignalKit, table EventKit, table SchemaKit
function SettingsKitTestEnv.NewPackage()
    local SettingsKit, Registry, SignalKit, EventKit, SchemaKit = baseNewPackage()
    SettingsKitTestEnv.SetPlayer()
    return SettingsKit, Registry, SignalKit, EventKit, SchemaKit
end

---Load the module chain without EventKit, as an addon that embeds none does.
---@return table SettingsKit, table Registry, table SchemaKit
function SettingsKitTestEnv.NewPackageWithoutEventKit()
    SettingsKitTestEnv.Reset()
    SettingsKitTestEnv.InstallWowApi()
    local Registry = require("Registry")
    require("SignalKit")
    local SchemaKit = require("SchemaKit")
    local SettingsKit = require("SettingsKit")
    SettingsKitTestEnv.SetPlayer()
    return SettingsKit, Registry, SchemaKit
end

---Measure the allocation a workload causes, in kilobytes, with the collector
---stopped so that a collection cycle cannot hide or invent growth.
---@param workload fun()
---@return number kilobytes
function SettingsKitTestEnv.AllocatedKilobytes(workload)
    collectgarbage()
    collectgarbage("stop")
    local before = collectgarbage("count")
    workload()
    local after = collectgarbage("count")
    collectgarbage("restart")
    return after - before
end

---Load the SettingsKit source again as a copy carrying `revision`, the way a
---newer embedded copy loads over an older one in the client.
---@param revision integer
---@return table SettingsKit
function SettingsKitTestEnv.LoadRevision(revision)
    -- Lua 5.1 has no `package.searchpath`, so walk the path templates the way
    -- `require` does.
    local path = nil
    for template in package.path:gmatch("[^;]+") do
        local candidate = template:gsub("%?", "SettingsKit")
        local file = io.open(candidate, "r")
        if file ~= nil then
            file:close()
            path = candidate
            break
        end
    end
    if path == nil then
        error("SettingsKitTestEnv.LoadRevision could not find SettingsKit.lua on package.path", 2)
    end

    local file = assert(io.open(path, "r"))
    local text = file:read("*a")
    file:close()

    local patched, replacements = text:gsub(
        "local IMPLEMENTATION_REVISION = %d+",
        "local IMPLEMENTATION_REVISION = " .. revision
    )
    if replacements ~= 1 then
        error("SettingsKitTestEnv.LoadRevision could not find IMPLEMENTATION_REVISION", 2)
    end

    local chunk = assert(loadstring(patched, "@" .. path))
    return chunk()
end

return SettingsKitTestEnv
