--- Package-specific test environment for the ModuleKit suite.
---
--- The World of Warcraft stubs, the `package.loaded` bookkeeping and the error
--- capture live in the shared `FrameworkTestEnv` fixture at `tests/support/`.
--- What stays here is this package's own module load order.
---
--- HookKit, CommandKit and SchemaKit are optional dependencies: `module.scope.Hooks`
--- and `module.scope.Commands` find the first two through `Registry:Find` at
--- first read, and the schema form of `implements` finds SchemaKit at
--- registration. The manifest declares them under `optionalDependencies`, so
--- the test runner puts them on `LUA_PATH`, and the module chain loads them as
--- an addon that embeds them would. `NewPackageWithoutOptionalKits` loads the
--- chain without them.
local FrameworkTestEnv = require("FrameworkTestEnv")
local assert = require("luassert")

local ModuleKitTestEnv = FrameworkTestEnv.New({
    modules = {
        "Registry",
        "SignalKit",
        "EventKit",
        "LifecycleKit",
        "HookKit",
        "SchemaKit",
        "CommandKit",
        "ModuleKit",
    },
})

local installFixtureWowApi = ModuleKitTestEnv.InstallWowApi
local resetFixture = ModuleKitTestEnv.Reset

-- The slash-command host surface -------------------------------------------
--
-- CommandKit writes `SlashCmdList[key]` and the `SLASH_<key><n>` globals, which
-- the shared fixture does not own. `InstallWowApi` installs an empty
-- `SlashCmdList`, `RunSlash` does what the client does with a typed line, and
-- `Reset` removes the table and every `SLASH_*` global a spec's
-- registrations wrote, so none leaks into the next spec.

---Read a host global. The fixture stands in for the World of Warcraft client,
---whose API only exists in the global table.
---@param name string
---@return any
local function getGlobal(name)
    -- selene: allow(global_usage)
    return rawget(_G, name)
end

---Write a host global, for the same reason.
---@param name string
---@param value any
local function setGlobal(name, value)
    -- selene: allow(global_usage)
    rawset(_G, name, value)
end

---Remove `SlashCmdList`, `SecureCmdList` and every `SLASH_*` global.
local function removeSlashApi()
    local names = {}
    -- selene: allow(global_usage)
    for name in pairs(_G) do
        if type(name) == "string" and name:sub(1, 6) == "SLASH_" then
            names[#names + 1] = name
        end
    end
    for index = 1, #names do
        setGlobal(names[index], nil)
    end
    setGlobal("SlashCmdList", nil)
    setGlobal("SecureCmdList", nil)
end

---Run a typed slash line the way the client does: find the key whose
---`SLASH_<key><n>` global matches the command, without case, and call its
---`SlashCmdList` function with the rest of the line.
---@param line string for example `"/myaddon status"`
---@return boolean found whether any registered key answered to the command
local function runSlash(line)
    local command, rest = line:match("^(/%S+)%s*(.*)$")
    local slashCommands = getGlobal("SlashCmdList")
    if command == nil or type(slashCommands) ~= "table" then
        return false
    end
    for key, handler in pairs(slashCommands) do
        local index = 1
        local alias = getGlobal("SLASH_" .. key .. index)
        while alias ~= nil do
            if alias:lower() == command:lower() then
                handler(rest, nil)
                return true
            end
            index = index + 1
            alias = getGlobal("SLASH_" .. key .. index)
        end
    end
    return false
end

ModuleKitTestEnv.RunSlash = runSlash

-- CommKit ------------------------------------------------------------------
--
-- CommKit is an optional dependency, and it requires LifecycleKit, TimerKit,
-- SchedulerKit and PoolKit. It cannot sit in the module chain above: it must
-- load after LifecycleKit, and TimerKit and SchedulerKit in the chain would
-- replace the stand-ins other specs register. `LoadCommKit` loads the four on
-- top of a chain `NewPackage` already loaded; the runner puts them on
-- `LUA_PATH` as CommKit's required closure, and `Reset` clears them.

--- The modules `LoadCommKit` adds, in load order.
local COMM_KIT_MODULES = { "TimerKit", "SchedulerKit", "PoolKit", "CommKit" }

---Clear the modules `LoadCommKit` added from `package.loaded`.
local function unloadCommKit()
    for index = #COMM_KIT_MODULES, 1, -1 do
        package.loaded[COMM_KIT_MODULES[index]] = nil
    end
end

---Load CommKit and its remaining dependencies after `NewPackage`.
---@return table CommKit
function ModuleKitTestEnv.LoadCommKit()
    local loaded
    for index = 1, #COMM_KIT_MODULES do
        loaded = require(COMM_KIT_MODULES[index])
    end
    return loaded
end

---Install the shared fixture's WoW API plus an empty `SlashCmdList`.
function ModuleKitTestEnv.InstallWowApi()
    installFixtureWowApi()
    setGlobal("SlashCmdList", {})
end

---Reset the shared fixture and remove the slash-command globals.
function ModuleKitTestEnv.Reset()
    resetFixture()
    unloadCommKit()
    removeSlashApi()
end

---Load the module chain without HookKit, SchemaKit and CommandKit, as an
---addon that embeds none of them does.
---@return table ModuleKit
function ModuleKitTestEnv.NewPackageWithoutOptionalKits()
    ModuleKitTestEnv.Reset()
    ModuleKitTestEnv.InstallWowApi()
    require("Registry")
    require("SignalKit")
    require("EventKit")
    require("LifecycleKit")
    return require("ModuleKit")
end

---Load every module of the chain except ModuleKit, as `NewPackage` does, so a
---spec can then load a ModuleKit copy of its choosing.
function ModuleKitTestEnv.LoadDependencies()
    ModuleKitTestEnv.Reset()
    ModuleKitTestEnv.InstallWowApi()
    require("Registry")
    require("SignalKit")
    require("EventKit")
    local LifecycleKit = require("LifecycleKit")
    require("HookKit")
    require("SchemaKit")
    require("CommandKit")
    return LifecycleKit
end

---Run ModuleKit's source as if it declared implementation revision `revision`.
---
---This is how an upgrade spec models an embedded copy older or newer than the
---one under test without keeping a second copy of the source. It bypasses
---`require`, so `package.loaded.ModuleKit` is left alone.
---@param revision integer
---@return table ModuleKit the facade that copy returned
function ModuleKitTestEnv.LoadRevision(revision)
    local path = nil
    for template in package.path:gmatch("[^;]+") do
        local candidate = template:gsub("%?", "ModuleKit")
        local file = io.open(candidate, "r")
        if file ~= nil then
            file:close()
            path = candidate
            break
        end
    end
    if path == nil then
        error("ModuleKitTestEnv.LoadRevision could not find ModuleKit.lua on package.path", 2)
    end

    local file = assert(io.open(path, "r"))
    local text = file:read("*a")
    file:close()

    local patched, replacements = text:gsub(
        "local IMPLEMENTATION_REVISION = %d+",
        "local IMPLEMENTATION_REVISION = " .. revision
    )
    if replacements ~= 1 then
        error("ModuleKitTestEnv.LoadRevision could not find IMPLEMENTATION_REVISION", 2)
    end

    local chunk, failure = loadstring(patched, "@" .. path)
    if chunk == nil then
        error(
            "ModuleKitTestEnv.LoadRevision could not compile " .. path .. ": " .. tostring(failure),
            2
        )
    end
    return chunk()
end

---Assert that `callback` raises `expected` at the line that calls into
---ModuleKit, which is the first line of `callback`'s body, the line after its
---`function()`. The source compared is the spec file that called this helper.
---@param expected string substring the message must contain
---@param callback fun()
function ModuleKitTestEnv.expectCallerError(expected, callback)
    local source = debug.getinfo(2, "S").short_src
    local line = debug.getinfo(callback, "S").linedefined + 1
    local ok, message = pcall(callback)

    assert.is_false(ok)
    assert.is_not_nil(string.find(tostring(message), expected, 1, true), tostring(message))
    assert.is_not_nil(
        string.find(tostring(message), source .. ":" .. line .. ":", 1, true),
        tostring(message)
    )
end

return ModuleKitTestEnv
