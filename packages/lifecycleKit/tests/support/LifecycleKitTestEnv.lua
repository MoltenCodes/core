--- Package-specific test environment for the LifecycleKit suite.
---
--- The World of Warcraft stubs, the `package.loaded` bookkeeping and the error
--- capture live in the shared `FrameworkTestEnv` fixture at `tests/support/`.
--- What stays here is this package's own module load order, and the combat
--- lockdown host surface only the combat gate reads.
---
--- TimerKit, SchedulerKit, HookKit, CommandKit and CommKit are optional
--- dependencies: shutdown closes the addon's scope in each when it is loaded,
--- found through `Registry:Find`. The manifest declares all five under
--- `optionalDependencies`, so the test runner puts them and their required
--- closures on `LUA_PATH`. The module
--- chain loads HookKit and CommandKit (and SchemaKit, which CommandKit
--- requires) before LifecycleKit, as an addon that embeds them would;
--- `NewPackageWithoutHookKit` loads the chain without either. CommKit requires
--- LifecycleKit, so `LoadCommKit` adds it afterwards. The slash-command section
--- below models the host surface CommandKit writes to.
---
--- The shared fixture does not model `InCombatLockdown` yet, so this file adds
--- it on top of the fixture's own install and reset: `InstallWowApi` installs
--- the global and `Reset` removes it again, so no spec leaks combat state into
--- the next one.
local FrameworkTestEnv = require("FrameworkTestEnv")

local LifecycleKitTestEnv = FrameworkTestEnv.New({
    modules = {
        "Registry",
        "SignalKit",
        "EventKit",
        "HookKit",
        "SchemaKit",
        "CommandKit",
        "LifecycleKit",
    },
})

--- The host's combat lockdown, as `InCombatLockdown()` reports it.
local combat = { lockdown = false }

local installFixtureWowApi = LifecycleKitTestEnv.InstallWowApi
local resetFixture = LifecycleKitTestEnv.Reset

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

LifecycleKitTestEnv.RunSlash = runSlash

-- CommKit ------------------------------------------------------------------
--
-- CommKit is an optional dependency; it requires SignalKit, EventKit, TimerKit,
-- SchedulerKit and PoolKit, not LifecycleKit. It is kept out of the module
-- chain above so the plain suites load without it. `LoadCommKit` loads the four on top of a chain
-- `NewPackage` already loaded, which is also how the shutdown specs reach
-- TimerKit and SchedulerKit; the runner puts them on `LUA_PATH` as optional
-- dependencies and as CommKit's required closure, and `Reset` clears them.

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
function LifecycleKitTestEnv.LoadCommKit()
    local loaded
    for index = 1, #COMM_KIT_MODULES do
        loaded = require(COMM_KIT_MODULES[index])
    end
    return loaded
end

---Install the shared fixture's WoW API plus an empty `SlashCmdList` and
---`InCombatLockdown`.
function LifecycleKitTestEnv.InstallWowApi()
    installFixtureWowApi()
    setGlobal("SlashCmdList", {})
    -- The fixture stands in for the World of Warcraft client, whose API only exists in the global table.
    -- selene: allow(global_usage)
    rawset(_G, "InCombatLockdown", function()
        return combat.lockdown
    end)
end

---Reset the shared fixture, unload what `LoadCommKit` added, and remove the
---slash-command globals and the combat lockdown stub.
function LifecycleKitTestEnv.Reset()
    resetFixture()
    unloadCommKit()
    removeSlashApi()
    combat.lockdown = false
    -- The fixture stands in for the World of Warcraft client, whose API only exists in the global table.
    -- selene: allow(global_usage)
    rawset(_G, "InCombatLockdown", nil)
end

---Load the module chain without HookKit and CommandKit, as an addon that
---embeds neither does.
---@return table LifecycleKit
---@return table Registry
---@return table SignalKit
---@return table EventKit
function LifecycleKitTestEnv.NewPackageWithoutHookKit()
    LifecycleKitTestEnv.Reset()
    LifecycleKitTestEnv.InstallWowApi()
    local Registry = require("Registry")
    local SignalKit = require("SignalKit")
    local EventKit = require("EventKit")
    local LifecycleKit = require("LifecycleKit")
    return LifecycleKit, Registry, SignalKit, EventKit
end

---Set what `InCombatLockdown()` answers, without sending any event.
---@param value boolean
function LifecycleKitTestEnv.SetCombatLockdown(value)
    combat.lockdown = value == true
end

---Enter combat the way the client does.
---
---`PLAYER_REGEN_DISABLED` is sent just before lockdown begins, so handlers of
---the event still see `InCombatLockdown()` answer `false`.
function LifecycleKitTestEnv.EnterCombat()
    LifecycleKitTestEnv.Emit("PLAYER_REGEN_DISABLED")
    combat.lockdown = true
end

---Leave combat the way the client does: lockdown lifts, then
---`PLAYER_REGEN_ENABLED` is sent.
function LifecycleKitTestEnv.LeaveCombat()
    combat.lockdown = false
    LifecycleKitTestEnv.Emit("PLAYER_REGEN_ENABLED")
end

return LifecycleKitTestEnv
