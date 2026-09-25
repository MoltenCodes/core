--- Addons and modules: ModuleKit with LifecycleKit against AceAddon-3.0.
---
--- Both sides give an addon a set of named modules with `OnInitialize`,
--- `OnEnable` and `OnDisable` hooks, initialise and enable them when the
--- client says the addon has loaded and the player is logged in, and disable
--- and enable them on request:
---
---   create     `ModuleKit:ForAddon(name)` and `addon:CreateModule(name)`
---              against `AceAddon:NewAddon(name)` and `addon:NewModule(name)`
---   load       the client's `ADDON_LOADED` for that addon, after login, to
---              LifecycleKit through EventKit's frame, or to AceAddon's own
---              frame; both then initialise and enable every module
---   cycle      `container:DisableAll()` / `EnableAll()` against
---              `addon:Disable()` / `addon:Enable()`, which on AceAddon also
---              disables and enables every module; and one module's
---              `Disable()` / `Enable()` on both sides
---   listener   the same cycle with each module holding one game-event
---              listener while enabled: `module.scope.Events` (EventKit),
---              closed by ModuleKit on disable, against AceEvent-3.0
---              embedded in each module (`NewModule(name, "AceEvent-3.0")`),
---              whose `OnEmbedDisable` AceAddon calls on disable
---
--- The login state is set on the shared fake client before anything is built
--- (`IsLoggedIn()` answers `true`), so both sides go from loaded to enabled in
--- the one `ADDON_LOADED` delivery, the way a load-on-demand addon does.
---
--- What differs, and stays in the numbers because it is each library's own
--- work for the same request: ModuleKit validates and orders the module graph
--- on every whole-container pass (there are no dependencies here, so the order
--- is creation order), records intent apart from state, and runs every hook
--- under `pcall`; AceAddon walks its list in creation order and runs every
--- hook under `xpcall`. Dependencies, injection and `requiresAddons` have no
--- AceAddon counterpart and are not measured; the checks show the ordering
--- difference instead. AceAddon's library embedding at creation has no
--- ModuleKit counterpart (a module's `scope` fields are created on first
--- read), so only the listener cycle, where both give a module an event
--- registration that disable releases, compares the two mechanisms.

local Bench = require("Bench")

local AddonModules = {}

--- Modules per addon.
local MODULES = 10

--- Module names, the same strings on both sides.
local MODULE_NAMES = {}
for index = 1, MODULES do
  MODULE_NAMES[index] = "Module" .. index
end

--- Addons created per timed batch in the create and load cases. Neither side
--- can delete an addon, so every batch adds to the registries; the count is
--- kept low enough that a process holds a few thousand addons at most.
local CREATE_ITERATIONS = 300

--- Whole-addon enable and disable cycles per timed batch.
local CYCLE_ITERATIONS = 2000

--- One-module enable and disable cycles per timed batch.
local MODULE_CYCLE_ITERATIONS = 20000

--- Addons created for the retained-memory measurement.
local RETAINED_PROBE = 50

--- The game event each module listens to in the listener cycle.
local LISTENED_EVENT = "BAG_UPDATE"

local function noop() end

---@param host table
---@return table adapter, table[] libraries
local function kitAdapter(host)
  local loaded = host.RequireAll({
    "Registry",
    "SignalKit",
    "EventKit",
    "LifecycleKit",
    "ModuleKit",
  })
  local SignalKit, EventKit, LifecycleKit, ModuleKit = loaded[2], loaded[3], loaded[4], loaded[5]
  local adapter = {}

  ---Create an addon with the given module hooks; nothing is loaded yet.
  ---@param name string
  ---@param hooks table `{ onInitialize?, onEnable?, onDisable?, listener? }`
  ---@param moduleNames string[]? defaults to `MODULE_NAMES`
  ---@return table addon
  function adapter.create(name, hooks, moduleNames)
    moduleNames = moduleNames or MODULE_NAMES
    local container = ModuleKit:ForAddon(name)
    local modules = {}
    for index = 1, #moduleNames do
      local module = container:CreateModule(moduleNames[index])
      module.OnInitialize = hooks.onInitialize
      if hooks.listener ~= nil then
        local listener = hooks.listener
        local onEnable = hooks.onEnable
        module.OnEnable = function(self)
          self.scope.Events:Connect(LISTENED_EVENT, listener)
          if onEnable ~= nil then
            onEnable(self)
          end
        end
      else
        module.OnEnable = hooks.onEnable
      end
      module.OnDisable = hooks.onDisable
      modules[index] = module
    end
    return { container = container, modules = modules }
  end

  ---Declare that module number `first` depends on the module named `second`.
  function adapter.dependsOn(addon, first, second)
    addon.modules[first]:DependsOn(second)
  end

  function adapter.disableAll(addon)
    addon.container:DisableAll()
  end

  function adapter.enableAll(addon)
    addon.container:EnableAll()
  end

  function adapter.disableModule(addon, index)
    addon.modules[index]:Disable()
  end

  function adapter.enableModule(addon, index)
    addon.modules[index]:Enable()
  end

  function adapter.isModuleEnabled(addon, index)
    return addon.modules[index]:IsEnabled()
  end

  return adapter,
    {
      { name = "ModuleKit", revision = ModuleKit.REVISION },
      { name = "LifecycleKit", revision = LifecycleKit.REVISION },
      { name = "EventKit", revision = EventKit.REVISION },
      { name = "SignalKit", revision = SignalKit.REVISION },
    }
end

---@param host table
---@param directory string the Ace3 checkout
---@return table adapter, table[] libraries
local function aceAdapter(host, directory)
  host.LoadFiles(directory, {
    "LibStub/LibStub.lua",
    "CallbackHandler-1.0/CallbackHandler-1.0.lua",
    "AceEvent-3.0/AceEvent-3.0.lua",
    "AceAddon-3.0/AceAddon-3.0.lua",
  })
  local LibStub = host.Global("LibStub")
  local AceAddon, addonMinor = LibStub:GetLibrary("AceAddon-3.0")
  local _, eventMinor = LibStub:GetLibrary("AceEvent-3.0")
  local _, callbackMinor = LibStub:GetLibrary("CallbackHandler-1.0")
  local adapter = {}

  function adapter.create(name, hooks, moduleNames)
    moduleNames = moduleNames or MODULE_NAMES
    local object = AceAddon:NewAddon(name)
    local modules = {}
    for index = 1, #moduleNames do
      local module
      if hooks.listener ~= nil then
        module = object:NewModule(moduleNames[index], "AceEvent-3.0")
        local listener = hooks.listener
        local onEnable = hooks.onEnable
        module.OnEnable = function(self)
          self:RegisterEvent(LISTENED_EVENT, listener)
          if onEnable ~= nil then
            onEnable(self)
          end
        end
      else
        module = object:NewModule(moduleNames[index])
        module.OnEnable = hooks.onEnable
      end
      module.OnInitialize = hooks.onInitialize
      module.OnDisable = hooks.onDisable
      modules[index] = module
    end
    return { object = object, modules = modules }
  end

  ---AceAddon has no dependency declaration between modules.
  function adapter.dependsOn() end

  function adapter.disableAll(addon)
    addon.object:Disable()
  end

  function adapter.enableAll(addon)
    addon.object:Enable()
  end

  function adapter.disableModule(addon, index)
    addon.modules[index]:Disable()
  end

  function adapter.enableModule(addon, index)
    addon.modules[index]:Enable()
  end

  function adapter.isModuleEnabled(addon, index)
    return addon.modules[index]:IsEnabled() == true
  end

  return adapter,
    {
      { name = "AceAddon-3.0", minor = addonMinor },
      { name = "AceEvent-3.0", minor = eventMinor },
      { name = "CallbackHandler-1.0", minor = callbackMinor },
    }
end

---The side's `ADDON_LOADED` handler: EventKit's frame or AceAddon's.
---
---Called only after something registered the event (LifecycleKit registers
---it with its first instance, AceAddon at load).
---@param host table
---@return fun(name: string)
local function addonLoadedDispatcher(host)
  local frame, onEvent = host.EventHandler("ADDON_LOADED")
  return function(name)
    host.environment.MarkAddonLoaded(name)
    onEvent(frame, "ADDON_LOADED", name)
  end
end

---A factory of addon names never used before in this process.
---@param prefix string
---@return fun(): string
local function nameSource(prefix)
  local count = 0
  return function()
    count = count + 1
    return prefix .. count
  end
end

---@param adapter table
---@param host table
---@return Bench.Case[]
local function cases(adapter, host)
  local initialized, enabled, disabled = 0, 0, 0
  local hooks = {
    onInitialize = function()
      initialized = initialized + 1
    end,
    onEnable = function()
      enabled = enabled + 1
    end,
    onDisable = function()
      disabled = disabled + 1
    end,
  }

  ---Fresh names for one batch, built outside the timed region, so neither
  ---side is timed building strings the other does not.
  local function batchNames(source)
    local names = {}
    return names,
      function(iterations)
        for index = 1, iterations do
          names[index] = source()
        end
      end
  end

  ---An addon created and loaded outside any measurement.
  local function loadedAddon(name, addonHooks)
    local addon = adapter.create(name, addonHooks)
    addonLoadedDispatcher(host)(name)
    return addon
  end

  ---A cycle case over one loaded addon.
  local function cycleCase(name, operation, cycle, addonHooks, batchSize)
    return {
      name = name,
      iterations = batchSize or CYCLE_ITERATIONS,
      operation = operation,
      prepare = function()
        local addon = loadedAddon("BenchCycle", addonHooks)
        local enabledBefore = enabled
        local operations = 0
        return {
          run = function(iterations)
            for _ = 1, iterations do
              cycle(addon)
            end
            operations = operations + iterations
          end,
          metrics = function()
            return { onEnableCallsPerCycle = (enabled - enabledBefore) / operations }
          end,
        }
      end,
    }
  end

  local listenerHooks = {
    onInitialize = hooks.onInitialize,
    onEnable = hooks.onEnable,
    onDisable = hooks.onDisable,
    listener = noop,
  }

  return {
    {
      name = "create-addon",
      iterations = CREATE_ITERATIONS,
      operation = "create an addon with 10 modules (not loaded yet)",
      prepare = function()
        local names, fill = batchNames(nameSource("BenchCreate"))
        return {
          beforeBatch = fill,
          run = function(iterations)
            for index = 1, iterations do
              adapter.create(names[index], hooks)
            end
          end,
          metrics = function()
            local probeNames = {}
            local source = nameSource("BenchCreateProbe")
            for index = 1, RETAINED_PROBE do
              probeNames[index] = source()
            end
            local baseline = Bench.RetainedBytes()
            for index = 1, RETAINED_PROBE do
              adapter.create(probeNames[index], hooks)
            end
            return { retainedBytesPerAddon = (Bench.RetainedBytes() - baseline) / RETAINED_PROBE }
          end,
        }
      end,
    },
    {
      name = "load-addon",
      iterations = CREATE_ITERATIONS,
      operation = "create an addon with 10 modules, then its ADDON_LOADED after login "
        .. "(initialise and enable all)",
      prepare = function()
        -- One addon first, so the side has registered ADDON_LOADED.
        loadedAddon("BenchLoadFirst", hooks)
        local dispatch = addonLoadedDispatcher(host)
        local names, fill = batchNames(nameSource("BenchLoad"))
        local enabledBefore, created = enabled, 0
        return {
          beforeBatch = fill,
          run = function(iterations)
            for index = 1, iterations do
              local name = names[index]
              adapter.create(name, hooks)
              dispatch(name)
            end
            created = created + iterations
          end,
          metrics = function()
            local probeNames = {}
            local source = nameSource("BenchLoadProbe")
            for index = 1, RETAINED_PROBE do
              probeNames[index] = source()
            end
            local enabledPerAddon = (enabled - enabledBefore) / created
            local baseline = Bench.RetainedBytes()
            for index = 1, RETAINED_PROBE do
              adapter.create(probeNames[index], hooks)
              dispatch(probeNames[index])
            end
            return {
              onEnableCallsPerAddon = enabledPerAddon,
              retainedBytesPerLoadedAddon = (Bench.RetainedBytes() - baseline) / RETAINED_PROBE,
            }
          end,
        }
      end,
    },
    cycleCase("disable-enable-all", "disable and enable an addon's 10 modules", function(addon)
      adapter.disableAll(addon)
      adapter.enableAll(addon)
    end, hooks),
    cycleCase("disable-enable-module", "disable and enable one module", function(addon)
      adapter.disableModule(addon, 1)
      adapter.enableModule(addon, 1)
    end, hooks, MODULE_CYCLE_ITERATIONS),
    cycleCase(
      "disable-enable-all-listening",
      "disable and enable 10 modules that each hold one game-event listener while enabled",
      function(addon)
        adapter.disableAll(addon)
        adapter.enableAll(addon)
      end,
      listenerHooks
    ),
  }
end

---@param adapter table
---@param host table
---@return table[] checks
local function runChecks(adapter, host)
  local results = {}
  local isKit = adapter.side == "moltencodes"
  local function record(name, passed, detail, promised)
    results[#results + 1] = { name = name, passed = passed, detail = detail, promised = promised }
  end

  ---Hooks that record `event:index` in `log`.
  local function loggingHooks(log, names)
    local function indexOf(module)
      local moduleName = module.GetName and module:GetName() or module.moduleName
      for index = 1, #names do
        if names[index] == moduleName then
          return index
        end
      end
      return 0
    end
    return {
      onEnable = function(self)
        log[#log + 1] = "enable:" .. indexOf(self)
      end,
      onDisable = function(self)
        log[#log + 1] = "disable:" .. indexOf(self)
      end,
    }
  end

  -- Enable follows creation order; disable, the reverse.
  do
    local names = { "Alpha", "Beta", "Gamma", "Delta" }
    local log = {}
    local addon = adapter.create("CheckOrder", loggingHooks(log, names), names)
    addonLoadedDispatcher(host)("CheckOrder")
    local enableOrder = table.concat(log, " ")
    for index = #log, 1, -1 do
      log[index] = nil
    end
    adapter.disableAll(addon)
    local disableOrder = table.concat(log, " ")
    record(
      "enable-in-creation-order",
      enableOrder == "enable:1 enable:2 enable:3 enable:4",
      "enable order: " .. enableOrder,
      true
    )
    record(
      "disable-in-reverse-order",
      disableOrder == "disable:4 disable:3 disable:2 disable:1",
      "disable order: " .. disableOrder,
      isKit
    )
  end

  -- A module created first that depends on one created later.
  do
    local names = { "Consumer", "Provider" }
    local log = {}
    local addon = adapter.create("CheckDependency", loggingHooks(log, names), names)
    adapter.dependsOn(addon, 1, "Provider")
    addonLoadedDispatcher(host)("CheckDependency")
    local order = table.concat(log, " ")
    record(
      "dependency-enabled-first",
      order == "enable:2 enable:1",
      "enable order (1 depends on 2): " .. order,
      isKit
    )
  end

  -- One module's OnEnable fails: the others still enable, the failure is
  -- reported, and the failed module is not counted as enabled.
  do
    local enabledCount = 0
    local names = { "First", "Failing", "Third" }
    local addon = adapter.create("CheckFailure", {
      onEnable = function(self)
        local moduleName = self.GetName and self:GetName() or self.moduleName
        if moduleName == "Failing" then
          error("enable failure", 0)
        end
        enabledCount = enabledCount + 1
      end,
    }, names)
    host.TakeReportedErrors()
    pcall(addonLoadedDispatcher(host), "CheckFailure")
    local reported = #host.TakeReportedErrors()
    record(
      "failing-module-does-not-stop-others",
      enabledCount == 2 and reported >= 1,
      "other modules enabled: " .. enabledCount .. " of 2, errors reported: " .. reported,
      true
    )
    local failedEnabled = adapter.isModuleEnabled(addon, 2)
    record(
      "failed-module-not-enabled",
      not failedEnabled,
      "module whose OnEnable raised reports enabled: " .. tostring(failedEnabled),
      isKit
    )
  end

  -- Enabling an enabled module runs nothing.
  do
    local calls = 0
    local addon = adapter.create("CheckIdempotent", {
      onEnable = function()
        calls = calls + 1
      end,
    }, { "Only" })
    addonLoadedDispatcher(host)("CheckIdempotent")
    adapter.enableModule(addon, 1)
    record(
      "enable-is-idempotent",
      calls == 1,
      "OnEnable calls after load and a second Enable: " .. calls,
      true
    )
  end

  -- A module's event listener is released when it is disabled.
  do
    local addon = adapter.create("CheckListener", { listener = noop }, { "Listening" })
    addonLoadedDispatcher(host)("CheckListener")
    local function registered()
      local frames = host.environment.Frames()
      for index = 1, #frames do
        if frames[index].registrations[LISTENED_EVENT] ~= nil then
          return true
        end
      end
      return false
    end
    local whileEnabled = registered()
    adapter.disableModule(addon, 1)
    local afterDisable = registered()
    record(
      "disable-releases-event-listener",
      whileEnabled and not afterDisable,
      "event registered while enabled: "
        .. tostring(whileEnabled)
        .. ", after disable: "
        .. tostring(afterDisable),
      true
    )
  end

  return results
end

---Build the workload for one side.
---@param side string `"moltencodes"` or `"ace3"`
---@param host table
---@param settings table
---@return table suite `{ cases, checks, libraries }`
function AddonModules.Build(side, host, settings)
  host.environment.SetLoggedIn(true)
  local adapter, libraries
  if side == "moltencodes" then
    adapter, libraries = kitAdapter(host)
  else
    adapter, libraries = aceAdapter(host, settings.ace3)
  end
  adapter.side = side

  return {
    libraries = libraries,
    cases = cases(adapter, host),
    checks = function()
      return runChecks(adapter, host)
    end,
  }
end

return AddonModules
