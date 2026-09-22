-- ExampleAddon
--
-- The smallest addon that embeds the MoltenCodes framework and uses it for
-- something real: a lifecycle-bound module that greets the player once the
-- session is ready, reacts to a World of Warcraft event, and schedules a timer
-- that is cancelled automatically when the addon shuts down.
--
-- Every file this addon loads, and the order it loads them in, is in
-- ExampleAddon.toc and embeds.xml. See docs/EMBEDDING.md for the rules behind
-- that order.

-- WoW passes every addon file its addon name and a private shared table.
-- `ADDON_NAME` is the folder name, which is exactly what LifecycleKit,
-- ModuleKit and TimerKit key their per-addon state by.
local ADDON_NAME, ADDON_TABLE = ...

local REGISTRY_API = 2
local EVENT_KIT_API = 1
local LIFECYCLE_KIT_API = 1
local MODULE_KIT_API = 1
local TIMER_KIT_API = 1

-- Resolving the framework ---------------------------------------------------
--
-- Ask for the Registry API generation this addon was written against rather
-- than for `MoltenCodes.Registry`, which is an alias for the newest generation
-- loaded in the session. Another addon may embed a newer generation; asking by
-- number means this addon is never handed a contract it does not understand.

---Return the Registry facade for the API generation this addon targets.
---@return Registry
local function resolveRegistry()
    -- `MoltenCodes` is the documented global the framework publishes itself
    -- under; reaching it is the whole point of this example.
    -- selene: allow(undefined_variable)
    local namespace = MoltenCodes
    if type(namespace) ~= "table" then
        error(ADDON_NAME .. " requires MoltenCodes Registry API " .. REGISTRY_API, 0)
    end

    local generations = namespace.Registries
    local registry = generations and generations[REGISTRY_API] or namespace.Registry
    if type(registry) ~= "table" or registry.API ~= REGISTRY_API then
        error(ADDON_NAME .. " requires MoltenCodes Registry API " .. REGISTRY_API, 0)
    end

    return registry
end

local Registry = resolveRegistry()

---Return one package, failing with an actionable message when it is missing.
---
---A missing package always means the same thing: its file is absent from the
---`.toc`, or it is listed after the file that asks for it.
---@param packageName string
---@param api integer
---@return table
local function requirePackage(packageName, api)
    local implementation = Registry:Get(packageName, api)
    if implementation == nil then
        error(
            ADDON_NAME
                .. " requires MoltenCodes "
                .. packageName
                .. " API "
                .. api
                .. "; add it to the .toc before Core.lua",
            0
        )
    end
    return implementation
end

---@type EventKit
local EventKit = requirePackage("eventKit", EVENT_KIT_API)
---@type LifecycleKit
local LifecycleKit = requirePackage("lifecycleKit", LIFECYCLE_KIT_API)
---@type ModuleKit
local ModuleKit = requirePackage("moduleKit", MODULE_KIT_API)
---@type TimerKit
local TimerKit = requirePackage("timerKit", TIMER_KIT_API)

-- Per-addon handles ---------------------------------------------------------
--
-- All three are keyed by the addon name, are created once, and are shared by
-- every file of this addon that asks for them. ModuleKit binds the container to
-- the same LifecycleKit instance, so modules are initialized on `loaded`,
-- enabled on `ready`, and disabled on `shutdown` without this file arranging it.

local lifecycle = LifecycleKit:ForAddon(ADDON_NAME)
local modules = ModuleKit:ForAddon(ADDON_NAME)
local timers = TimerKit:ForAddon(ADDON_NAME)

ADDON_TABLE.Lifecycle = lifecycle
ADDON_TABLE.Modules = modules
ADDON_TABLE.Timers = timers

-- Saved variables -----------------------------------------------------------
--
-- SavedVariables belong to the addon, not to the framework: no MoltenCodes Kit
-- persists anything across `/reload`. The table declared in the `.toc` exists
-- from this addon's `ADDON_LOADED` onwards, which is the `loaded` phase.

---@class ExampleAddonDatabase
---@field greetings integer how many times the addon has greeted this character

---@type ExampleAddonDatabase
-- `ExampleAddonDB` is a World of Warcraft saved variable. The client declares
-- it in the `.toc`, restores it as a global before the addon's files run, and
-- persists it by that global name, so it cannot be a local.
-- selene: allow(unscoped_variables)
ExampleAddonDB = ExampleAddonDB or { greetings = 0 }

lifecycle:OnLoaded(function()
    ExampleAddonDB = ExampleAddonDB or {}
    if type(ExampleAddonDB.greetings) ~= "number" then
        ExampleAddonDB.greetings = 0
    end
end)

-- Modules -------------------------------------------------------------------
--
-- Providers are addon-scoped values or factories. Modules declare what they
-- want by name, and ModuleKit resolves those names when the module initializes.

---This addon's own module type.
---
---ModuleKit hands each hook the module itself as `self`. Declaring the fields
---this addon stores on it is what makes them autocomplete and what lets the
---language server catch a typo in one of them.
---@class ExampleAddon.Greeter : ModuleKit.Module
---@field addonName string
---@field database ExampleAddonDatabase
---@field connections EventKit.Connection[]
---@field tick TimerKit.Timer|nil

modules:ProvideValue("AddonName", ADDON_NAME)
modules:ProvideSingleton("Database", function()
    return ExampleAddonDB
end)

local greeter = modules:CreateModule("Greeter", {
    inject = { addonName = "AddonName", database = "Database" },

    ---@param self ExampleAddon.Greeter
    ---@param injections table<string, any>
    onInitialize = function(self, injections)
        self.addonName = injections.addonName
        self.database = injections.database
        self.connections = {}
    end,

    ---@param self ExampleAddon.Greeter
    onEnable = function(self)
        self.database.greetings = self.database.greetings + 1
        print(self.addonName .. " ready; greeting #" .. self.database.greetings)

        -- One shared event bus serves every addon in the session. Keep the
        -- handler short, never call a protected function from it, and hold on
        -- to the connection so it can be disconnected again.
        self.connections[#self.connections + 1] = EventKit:Connect(
            "PLAYER_ENTERING_WORLD",
            function(_, isInitialLogin, isReloadingUi)
                print(self.addonName .. " entered the world", isInitialLogin, isReloadingUi)
            end
        )

        -- Unit-filtered events take at most two unit tokens, because
        -- Frame:RegisterUnitEvent has exactly two filter slots.
        self.connections[#self.connections + 1] = EventKit:ConnectUnit(
            "UNIT_HEALTH",
            function(_, unit)
                print(self.addonName .. " saw a health change on", unit)
            end,
            "player"
        )

        -- Addon-owned timers are cancelled by LifecycleKit shutdown, so nothing
        -- here has to be undone on logout.
        self.tick = timers:Every(60, function()
            print(self.addonName .. " is still running")
        end)
    end,

    ---@param self ExampleAddon.Greeter
    onDisable = function(self)
        for index = 1, #self.connections do
            self.connections[index]:Disconnect()
            self.connections[index] = nil
        end
        if self.tick ~= nil then
            self.tick:Cancel()
            self.tick = nil
        end
    end,
})

ADDON_TABLE.Greeter = greeter
