--- Package-specific test environment for the LifecycleKit suite.
---
--- The World of Warcraft stubs, the `package.loaded` bookkeeping and the error
--- capture live in the shared `FrameworkTestEnv` fixture at `tests/support/`.
--- What stays here is this package's own module load order, and the combat
--- lockdown host surface only the combat gate reads.
---
--- HookKit is an optional dependency: shutdown closes the addon's HookKit
--- scope when HookKit is loaded, found through `Registry:Find`. The manifest
--- declares it under `optionalDependencies`, so the test runner puts it on
--- `LUA_PATH`, and the module chain loads it before LifecycleKit, as an addon
--- that embeds it would. `NewPackageWithoutHookKit` loads the chain without it.
---
--- The shared fixture does not model `InCombatLockdown` yet, so this file adds
--- it on top of the fixture's own install and reset: `InstallWowApi` installs
--- the global and `Reset` removes it again, so no spec leaks combat state into
--- the next one.
local FrameworkTestEnv = require("FrameworkTestEnv")

local LifecycleKitTestEnv = FrameworkTestEnv.New({
    modules = { "Registry", "SignalKit", "EventKit", "HookKit", "LifecycleKit" },
})

--- The host's combat lockdown, as `InCombatLockdown()` reports it.
local combat = { lockdown = false }

local installFixtureWowApi = LifecycleKitTestEnv.InstallWowApi
local resetFixture = LifecycleKitTestEnv.Reset

---Install the shared fixture's WoW API plus `InCombatLockdown`.
function LifecycleKitTestEnv.InstallWowApi()
    installFixtureWowApi()
    -- The fixture stands in for the World of Warcraft client, whose API only exists in the global table.
    -- selene: allow(global_usage)
    rawset(_G, "InCombatLockdown", function()
        return combat.lockdown
    end)
end

---Reset the shared fixture and remove the combat lockdown stub.
function LifecycleKitTestEnv.Reset()
    resetFixture()
    combat.lockdown = false
    -- The fixture stands in for the World of Warcraft client, whose API only exists in the global table.
    -- selene: allow(global_usage)
    rawset(_G, "InCombatLockdown", nil)
end

---Load the module chain without HookKit, as an addon that embeds none does.
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
