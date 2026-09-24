-- ExampleAddon: Core.lua
--
-- Shows: resolving the framework by API generation, the per-addon LifecycleKit
-- and ModuleKit handles, and one module whose `module.scope` owns everything it
-- registers (events, a coalesced event burst, a timer, a secure hook and two
-- slash commands), plus a ReadinessKit gate for spell data and a ClientKit
-- capability check.
--
-- This file loads first, right after `embeds.xml`, so it resolves every Kit the
-- addon uses once and shares them with the other files through the addon's
-- private table. Nothing here runs addon logic at load time: the module's hooks
-- run in LifecycleKit phases, by which time every file in the `.toc` has loaded
-- and registered what the module injects (`Settings.lua`, `Options.lua`,
-- `Window.lua`, `Commands.lua`).
--
-- The rules behind the load order are in docs/EMBEDDING.md.

-- WoW passes every addon file its addon name and a private shared table.
-- `ADDON_NAME` is the folder name, which is exactly what LifecycleKit,
-- ModuleKit and LocaleKit key their per-addon state by.
local ADDON_NAME, ADDON_TABLE = ...

local REGISTRY_API = 2

--- Every Kit this addon calls directly, by package ID, with the API generation
--- it was written against. SignalKit, TimerKit, SchedulerKit, PoolKit and
--- HookKit are embedded too but reached only through other Kits: ModuleKit's
--- module scopes, EventKit's `Coalesce`, WidgetKit's pools.
local REQUIRED_APIS = {
  clientKit = 1,
  commandKit = 1,
  eventKit = 1,
  lifecycleKit = 1,
  localeKit = 1,
  moduleKit = 1,
  optionsKit = 1,
  readinessKit = 1,
  schemaKit = 1,
  settingsKit = 1,
  widgetKit = 1,
}

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
---A missing package always means the same thing: its file is absent from
---`embeds.xml`, or it is listed after the file that asks for it.
---@param packageName string
---@return table
local function requirePackage(packageName)
  local api = REQUIRED_APIS[packageName]
  local implementation = Registry:Get(packageName, api)
  if type(implementation) == "nil" then
    error(
      ADDON_NAME
        .. " requires MoltenCodes "
        .. packageName
        .. " API "
        .. api
        .. "; add it to embeds.xml",
      0
    )
  end
  return implementation
end

---The Kits the addon's files share, resolved once.
---@class ExampleAddon.Kits
---@field ClientKit ClientKit
---@field CommandKit CommandKit
---@field EventKit EventKit
---@field LifecycleKit LifecycleKit
---@field LocaleKit LocaleKit
---@field ModuleKit ModuleKit
---@field OptionsKit OptionsKit
---@field ReadinessKit ReadinessKit
---@field SchemaKit SchemaKit
---@field SettingsKit SettingsKit
---@field WidgetKit WidgetKit
local Kits = {
  ClientKit = requirePackage("clientKit"),
  CommandKit = requirePackage("commandKit"),
  EventKit = requirePackage("eventKit"),
  LifecycleKit = requirePackage("lifecycleKit"),
  LocaleKit = requirePackage("localeKit"),
  ModuleKit = requirePackage("moduleKit"),
  OptionsKit = requirePackage("optionsKit"),
  ReadinessKit = requirePackage("readinessKit"),
  SchemaKit = requirePackage("schemaKit"),
  SettingsKit = requirePackage("settingsKit"),
  WidgetKit = requirePackage("widgetKit"),
}

-- Per-addon handles ---------------------------------------------------------
--
-- Both are keyed by the addon name, created once, and shared by every file of
-- this addon that asks for them. ModuleKit binds the container to the same
-- LifecycleKit instance, so modules are initialized on `loaded`, enabled on
-- `ready`, and disabled on `shutdown` without this file arranging it.

local lifecycle = Kits.LifecycleKit:ForAddon(ADDON_NAME)
local modules = Kits.ModuleKit:ForAddon(ADDON_NAME)

---The addon's private table, as every file of the addon sees it.
---@class ExampleAddon.Private
---@field Kits ExampleAddon.Kits
---@field Lifecycle LifecycleKit.Instance
---@field Modules ModuleKit.Addon
---@field Main ExampleAddon.Main
local private = ADDON_TABLE
private.Kits = Kits
private.Lifecycle = lifecycle
private.Modules = modules

-- The main module -----------------------------------------------------------

--- Hearthstone: a spell every character on every supported client knows, so
--- the example can wait for its data without depending on the class played.
local SPELL_ID = 8690

--- How long one burst of health events is collected before it is reported.
local HEALTH_INTERVAL_SECONDS = 0.5

--- How often the module reminds the player that it is running.
local REMINDER_INTERVAL_SECONDS = 60

---This addon's main module.
---
---ModuleKit hands each hook the module itself as `self`. Declaring the fields
---this addon stores on it is what makes them autocomplete and what lets the
---language server catch a typo in one of them.
---@class ExampleAddon.Main : ModuleKit.Module
---@field database SettingsKit.Database
---@field options OptionsKit.Tree
---@field window ExampleAddon.Window
---@field registerCommands ExampleAddon.RegisterCommands
---@field spellGate ReadinessKit.Gate|nil

---Print one line of the addon's chat output, formatted through LocaleKit so
---that a translation may reorder the arguments.
---@param template string a key of the addon's locale table
---@param ... string|number
local function say(template, ...)
  local L = Kits.LocaleKit:GetLocale(ADDON_NAME)
  print(Kits.LocaleKit:Format(L[template], ...))
end

---Greet the player once the module is enabled, counting greetings across
---sessions in the database's `global` scope.
---@param self ExampleAddon.Main
local function greet(self)
  self.database.global.greetings = self.database.global.greetings + 1
  if not self.database.profile.greet then
    return
  end

  -- ClientKit probes what the running client can do. Test a capability like
  -- this one rather than a version number: the answer stays right when a
  -- patch moves a feature between flavours. Secret values exist on Retail
  -- 12.x only; see docs/EMBEDDING.md.
  local L = Kits.LocaleKit:GetLocale(ADDON_NAME)
  local secretValues = Kits.ClientKit:Has("secretValues") and L["yes"] or L["no"]
  say(
    "%1$s is ready on the %2$s client (secret values: %3$s); greeting #%4$d.",
    ADDON_NAME,
    Kits.ClientKit:GetFlavor(),
    secretValues,
    self.database.global.greetings
  )
end

---Wait for spell data that the client loads after login.
---
---A ReadinessKit gate is shared by name across the session and is not owned by
---a module scope, so the module closes it itself in `onDisable`.
---@param self ExampleAddon.Main
local function waitForSpellData(self)
  local gate = Kits.ReadinessKit:Gate(ADDON_NAME .. ".spellData", function()
    -- Absence of a value the addon did not create is tested with `type`, the
    -- repository rule: it never compares anything, and on Retail 12.x a client
    -- value may be secret (docs/EMBEDDING.md, "Secret values").
    return type(Kits.ClientKit:GetSpellInfo(SPELL_ID)) ~= "nil"
  end, { intervalSeconds = 1, timeoutSeconds = 30 })
  self.spellGate = gate

  gate:Await(function(ready, reason)
    if ready then
      local spell = Kits.ClientKit:GetSpellInfo(SPELL_ID)
      say("Spell data is ready: %s.", spell and spell.name or tostring(SPELL_ID))
    else
      say("Spell data did not arrive (%s).", reason)
    end
  end)
end

---Connect the module's events, timer, hook and commands through its scope.
---
---Everything registered through `self.scope` is released when the module is
---disabled, including at logout, so none of it needs undoing in `onDisable`.
---The scope fields are typed optional because each reads `nil` when its Kit is
---not embedded; this addon embeds all of them, so they are cast.
---@param self ExampleAddon.Main
local function connectScope(self)
  local events = self.scope.Events --[[@as EventKit.Scope]]
  local timers = self.scope.Timers --[[@as TimerKit.Scope]]
  local hooks = self.scope.Hooks --[[@as HookKit.Scope]]
  local commands = self.scope.Commands --[[@as CommandKit.Scope]]

  -- One shared event bus serves every addon in the session. Keep a handler
  -- short and never call a protected function from it.
  events:Connect("PLAYER_ENTERING_WORLD", function(_, isInitialLogin, isReloadingUi)
    say(
      "Entered the world (login: %s, reload: %s).",
      tostring(isInitialLogin),
      tostring(isReloadingUi)
    )
  end)

  -- `EventKit:Coalesce`, owned by the scope: a burst of health events becomes
  -- one callback per interval, with the set of units that changed. It needs
  -- SchedulerKit embedded. The set is reused: read it, never keep it.
  events:Coalesce({ "UNIT_HEALTH", "UNIT_MAXHEALTH" }, HEALTH_INTERVAL_SECONDS, function(units)
    if not self.database.profile.announceHealth then
      return
    end
    for unit in pairs(units) do
      say("Health changed: %s.", unit)
    end
  end, { units = { "player" } })

  timers:Every(REMINDER_INTERVAL_SECONDS, function()
    say("%s is still running.", ADDON_NAME)
  end)

  -- A secure post-hook reacts without tainting the hooked function. Opening
  -- the game menu closes the settings window.
  hooks:SecureHook("ToggleGameMenu", function()
    self.window:Hide()
  end)

  self.registerCommands(commands, self.options, self.window)
end

local main = modules:CreateModule("Main", {
  -- Injection names what the module needs; the files that provide it load
  -- after this one, which is fine: names are resolved when the module
  -- initializes, in the `loaded` phase.
  inject = {
    database = "Database",
    options = "Options",
    window = "Window",
    registerCommands = "RegisterCommands",
  },

  ---@param self ExampleAddon.Main
  ---@param injections table<string, any>
  onInitialize = function(self, injections)
    self.database = injections.database
    self.options = injections.options
    self.window = injections.window
    self.registerCommands = injections.registerCommands
  end,

  ---@param self ExampleAddon.Main
  onEnable = function(self)
    greet(self)
    connectScope(self)
    waitForSpellData(self)
  end,

  ---@param self ExampleAddon.Main
  onDisable = function(self)
    -- Widgets and gates are not scope-owned: release them here.
    self.window:Hide()
    if self.spellGate ~= nil then
      self.spellGate:Close()
      self.spellGate = nil
    end
  end,
}) --[[@as ExampleAddon.Main]]

private.Main = main

-- LifecycleKit phases -------------------------------------------------------
--
-- A module covers what an addon does between `ready` and `shutdown`; the
-- phases are still there for the addon itself. This callback runs once, after
-- the module was enabled, because ModuleKit subscribed to `ready` first. Phases
-- are replay-aware: a subscription made after its phase still runs, at once.

lifecycle:OnReady(function()
  if main.database.profile.greet then
    say("Type /exampleaddon list for the settings, /exampleaddonwindow to edit them.")
  end
end)
