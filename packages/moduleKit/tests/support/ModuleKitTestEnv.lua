--- Package-specific test environment for the ModuleKit suite.
---
--- The World of Warcraft stubs, the `package.loaded` bookkeeping and the error
--- capture live in the shared `FrameworkTestEnv` fixture at `tests/support/`.
--- What stays here is this package's own module load order.
---
--- HookKit and CommandKit are optional dependencies: only `module.scope.Hooks`
--- and `module.scope.Commands` use them, found through `Registry:Find` at first
--- read. The manifest declares both under `optionalDependencies`, so the test
--- runner puts them (and SchemaKit, which CommandKit requires) on `LUA_PATH`,
--- and the module chain loads them as an addon that embeds them would.
--- `NewPackageWithoutHookKit` loads the chain without either.
local FrameworkTestEnv = require("FrameworkTestEnv")

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

---Load the module chain without HookKit and CommandKit, as an addon that
---embeds neither does.
---@return table ModuleKit
function ModuleKitTestEnv.NewPackageWithoutHookKit()
    ModuleKitTestEnv.Reset()
    ModuleKitTestEnv.InstallWowApi()
    require("Registry")
    require("SignalKit")
    require("EventKit")
    require("LifecycleKit")
    return require("ModuleKit")
end

return ModuleKitTestEnv
