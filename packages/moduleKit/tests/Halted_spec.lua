local TestEnv = require("ModuleKitTestEnv")

-- LifecycleKit lets an addon halt (declare itself non-functional for the
-- session) and tells the addons that declared it with `DependsOn`. ModuleKit
-- maps both onto the enable state: the module keeps its intent, is taken
-- down, and records what blocks it. Halted is terminal, so nothing recovers.

---Create a module whose hooks append to `log`.
---@param addon table
---@param name string
---@param log string[]
---@param definition table?
---@return table module
local function createLoggedModule(addon, name, log, definition)
  definition = definition or {}
  definition.onEnable = function()
    log[#log + 1] = "enable " .. name
  end
  definition.onDisable = function()
    log[#log + 1] = "disable " .. name
  end
  return addon:CreateModule(name, definition)
end

describe("ModuleKit when its own addon halts", function()
  local ModuleKit, LifecycleKit
  before_each(function()
    local packageUnderTest, _, _, _, lifecycleKit = TestEnv.NewPackage()
    ModuleKit = packageUnderTest
    LifecycleKit = lifecycleKit
  end)
  after_each(TestEnv.Reset)

  it("disables every module, keeps intent and reports halted as the block", function()
    local addon = ModuleKit:ForAddon("MyAddon")
    local log = {}
    local database = createLoggedModule(addon, "Database", log)
    local ui = createLoggedModule(addon, "UI", log, { dependsOn = { "Database" } })
    local released
    ui.OnEnable = function(self)
      released = self.scope.Events
    end
    TestEnv.LoadAddon("MyAddon")
    TestEnv.Login()

    LifecycleKit:ForAddon("MyAddon"):Halt("saved variables are unreadable")

    assert.are.same({ "enable Database", "disable UI", "disable Database" }, log)
    assert.is_false(ui:IsEnabled())
    assert.is_true(released:IsClosed())
    assert.are.same(
      { wanted = true, actual = false, blockedBy = "halted" },
      database:GetEnableState()
    )
    assert.are.same({ wanted = true, actual = false, blockedBy = "halted" }, ui:GetEnableState())
  end)

  it("refuses a targeted Enable and blocks EnableAll for good", function()
    local addon = ModuleKit:ForAddon("MyAddon")
    local log = {}
    local module = createLoggedModule(addon, "Tracker", log)
    TestEnv.LoadAddon("MyAddon")
    TestEnv.Login()
    LifecycleKit:ForAddon("MyAddon"):Halt("broken")

    local source = debug.getinfo(1, "S").short_src
    local line
    local ok, message = pcall(function()
      line = debug.getinfo(1, "l").currentline + 1
      module:Enable()
    end)
    addon:EnableAll()

    assert.is_false(ok)
    assert.are.equal(
      source
        .. ":"
        .. line
        .. ': ModuleKit module "Tracker" cannot be enabled because its addon "MyAddon" has halted',
      message
    )
    assert.are.equal("halted", module:GetBlockedBy())
    assert.are.same({ "enable Tracker", "disable Tracker" }, log)
    assert.are.same(
      { wanted = true, actual = false, blockedBy = "halted" },
      module:GetEnableState()
    )
  end)

  it("blocks a module created after the halt without raising", function()
    local addon = ModuleKit:ForAddon("MyAddon")
    TestEnv.LoadAddon("MyAddon")
    TestEnv.Login()
    LifecycleKit:ForAddon("MyAddon"):Halt("broken")

    local log = {}
    local late = createLoggedModule(addon, "Late", log)

    assert.are.same({}, log)
    assert.are.equal("initialized", late:GetState())
    assert.are.same({ wanted = true, actual = false, blockedBy = "halted" }, late:GetEnableState())
  end)

  it("leaves an explicitly disabled module unwanted", function()
    local addon = ModuleKit:ForAddon("MyAddon")
    local module = addon:CreateModule("Optional")
    TestEnv.LoadAddon("MyAddon")
    TestEnv.Login()
    module:Disable()

    LifecycleKit:ForAddon("MyAddon"):Halt("broken")

    assert.are.same({ wanted = false, actual = false }, module:GetEnableState())
  end)
end)

describe("ModuleKit when a required addon halts", function()
  local ModuleKit, LifecycleKit
  before_each(function()
    local packageUnderTest, _, _, _, lifecycleKit = TestEnv.NewPackage()
    ModuleKit = packageUnderTest
    LifecycleKit = lifecycleKit
  end)
  after_each(TestEnv.Reset)

  it("disables only the modules that require it, and their dependents", function()
    local addon = ModuleKit:ForAddon("MyAddon")
    local log = {}
    local bridge = createLoggedModule(addon, "Bridge", log, { requiresAddons = { "Other" } })
    local panel = createLoggedModule(addon, "Panel", log, { dependsOn = { "Bridge" } })
    local core = createLoggedModule(addon, "Core", log)
    TestEnv.LoadAddon("MyAddon")
    TestEnv.Login()
    log = {}
    bridge.OnDisable = function()
      log[#log + 1] = "disable Bridge"
    end
    panel.OnDisable = function()
      log[#log + 1] = "disable Panel"
    end

    LifecycleKit:ForAddon("Other"):Halt("Other's saved variables are unreadable")

    assert.are.same({ "disable Panel", "disable Bridge" }, log)
    assert.are.same({ wanted = true, actual = false, blockedBy = "Other" }, bridge:GetEnableState())
    assert.are.same({ wanted = true, actual = false, blockedBy = "Bridge" }, panel:GetEnableState())
    assert.are.same({ wanted = true, actual = true }, core:GetEnableState())
  end)

  it("declares the required addon on the owning lifecycle instance", function()
    local addon = ModuleKit:ForAddon("MyAddon")
    addon:CreateModule("Bridge", { requiresAddons = { "Other" } })
    local notices = {}
    LifecycleKit:ForAddon("MyAddon"):OnDependencyHalted(function(_, dependencyName, reason)
      notices[#notices + 1] = dependencyName .. ": " .. reason
    end)

    LifecycleKit:ForAddon("Other"):Halt("broken")

    assert.are.same({ "Other: broken" }, notices)
  end)

  it("refuses Enable and blocks EnableAll while the required addon is halted", function()
    local addon = ModuleKit:ForAddon("MyAddon")
    local log = {}
    LifecycleKit:ForAddon("Other"):Halt("broken")
    local bridge = createLoggedModule(addon, "Bridge", log, { requiresAddons = { "Other" } })
    local panel = createLoggedModule(addon, "Panel", log, { dependsOn = { "Bridge" } })
    assert.are.equal("Other", bridge:GetEnableState().blockedBy)

    TestEnv.LoadAddon("MyAddon")
    TestEnv.Login()
    assert.are.same({}, log)
    assert.are.same({ wanted = true, actual = false, blockedBy = "Bridge" }, panel:GetEnableState())

    local ok, message = pcall(function()
      bridge:Enable()
    end)
    addon:EnableAll()

    assert.is_false(ok)
    assert.is_not_nil(
      string.find(
        message,
        'ModuleKit module "Bridge" cannot be enabled because required addon "Other" has halted',
        1,
        true
      )
    )
    assert.are.same({}, log)
    assert.are.same({ wanted = true, actual = false, blockedBy = "Other" }, bridge:GetEnableState())
  end)

  it("keeps a module blocked when its other dependencies recover", function()
    local addon = ModuleKit:ForAddon("MyAddon")
    local log = {}
    createLoggedModule(addon, "Database", log)
    local bridge = createLoggedModule(addon, "Bridge", log, {
      dependsOn = { "Database" },
      requiresAddons = { "Other" },
    })
    TestEnv.LoadAddon("MyAddon")
    TestEnv.Login()
    addon:GetModule("Database"):Disable()
    LifecycleKit:ForAddon("Other"):Halt("broken")

    addon:GetModule("Database"):Enable()

    assert.is_false(bridge:IsEnabled())
    assert.are.equal("Other", bridge:GetEnableState().blockedBy)
  end)

  it("leaves a module without requiresAddons untouched", function()
    local addon = ModuleKit:ForAddon("MyAddon")
    local log = {}
    local core = createLoggedModule(addon, "Core", log)
    LifecycleKit:ForAddon("MyAddon"):DependsOn("Other")
    TestEnv.LoadAddon("MyAddon")
    TestEnv.Login()

    LifecycleKit:ForAddon("Other"):Halt("broken")

    assert.are.same({ "enable Core" }, log)
    assert.are.same({ wanted = true, actual = true }, core:GetEnableState())
    core:Disable()
    core:Enable()
    assert.is_true(core:IsEnabled())
  end)

  it("re-raises a failing OnDisable after the other modules were taken down", function()
    local addon = ModuleKit:ForAddon("MyAddon")
    local first = addon:CreateModule("First", { requiresAddons = { "Other" } })
    local second = addon:CreateModule("Second", {
      requiresAddons = { "Other" },
      onDisable = function()
        error("cannot let go", 0)
      end,
    })
    TestEnv.LoadAddon("MyAddon")
    TestEnv.Login()

    local ok, message = pcall(function()
      LifecycleKit:ForAddon("Other"):Halt("broken")
    end)

    assert.is_false(ok)
    assert.are.equal("cannot let go", message)
    assert.is_false(first:IsEnabled())
    assert.is_true(second:IsEnabled())
    assert.are.equal("Other", second:GetEnableState().blockedBy)
  end)
end)

describe("ModuleKit when OnEnable itself halts", function()
  local ModuleKit, LifecycleKit
  before_each(function()
    local packageUnderTest, _, _, _, lifecycleKit = TestEnv.NewPackage()
    ModuleKit = packageUnderTest
    LifecycleKit = lifecycleKit
  end)
  after_each(TestEnv.Reset)

  it("takes the module down when its OnEnable halts its own addon", function()
    local addon = ModuleKit:ForAddon("MyAddon")
    local log = {}
    local released
    local loader = createLoggedModule(addon, "Loader", log)
    loader.OnEnable = function(self)
      log[#log + 1] = "enable Loader"
      released = self.scope.Events
      LifecycleKit:ForAddon("MyAddon"):Halt("saved variables are unreadable")
    end
    local later = createLoggedModule(addon, "Later", log)

    TestEnv.LoadAddon("MyAddon")
    TestEnv.Login()

    assert.are.same({ "enable Loader", "disable Loader" }, log)
    assert.is_true(released:IsClosed())
    assert.are.same(
      { wanted = true, actual = false, blockedBy = "halted" },
      loader:GetEnableState()
    )
    assert.are.same({ wanted = true, actual = false, blockedBy = "halted" }, later:GetEnableState())
  end)

  it("releases the scope of a module whose OnDisable fails after its OnEnable halted", function()
    local addon = ModuleKit:ForAddon("MyAddon")
    local released
    local loader = addon:CreateModule("Loader")
    loader.OnEnable = function(self)
      released = self.scope.Events
      LifecycleKit:ForAddon("MyAddon"):Halt("broken")
    end
    loader.OnDisable = function()
      error("cannot let go", 0)
    end
    addon:InitializeAll()

    local ok, message = pcall(function()
      loader:Enable()
    end)

    assert.is_false(ok)
    assert.are.equal("cannot let go", message)
    assert.is_true(released:IsClosed())
    assert.are.equal("halted", loader:GetEnableState().blockedBy)
  end)

  it("keeps dependents off when a dependency's OnEnable halts a required addon", function()
    local addon = ModuleKit:ForAddon("MyAddon")
    local log = {}
    local bridge = createLoggedModule(addon, "Bridge", log, { requiresAddons = { "Other" } })
    bridge.OnEnable = function()
      log[#log + 1] = "enable Bridge"
      LifecycleKit:ForAddon("Other"):Halt("incompatible")
    end
    local panel = createLoggedModule(addon, "Panel", log, { dependsOn = { "Bridge" } })
    addon:InitializeAll()

    panel:Enable()

    assert.are.same({ "enable Bridge", "disable Bridge" }, log)
    assert.are.same({ wanted = true, actual = false, blockedBy = "Other" }, bridge:GetEnableState())
    assert.are.same({ wanted = true, actual = false, blockedBy = "Bridge" }, panel:GetEnableState())
    assert.are.equal("Bridge", panel:GetBlockedBy())
  end)

  it("blocks a dependent on its own addon's halt raised by a dependency", function()
    local addon = ModuleKit:ForAddon("MyAddon")
    local log = {}
    local loader = createLoggedModule(addon, "Loader", log)
    loader.OnEnable = function()
      log[#log + 1] = "enable Loader"
      LifecycleKit:ForAddon("MyAddon"):Halt("saved variables are unreadable")
    end
    local panel = createLoggedModule(addon, "Panel", log, { dependsOn = { "Loader" } })
    addon:InitializeAll()

    panel:Enable()

    assert.are.same({ "enable Loader", "disable Loader" }, log)
    assert.are.same({ wanted = true, actual = false, blockedBy = "halted" }, panel:GetEnableState())
    assert.are.equal("halted", panel:GetBlockedBy())
    -- The same block a direct Enable of the halted addon's module records.
    assert.has_error(function()
      panel:Enable()
    end)
    assert.are.equal("halted", panel:GetEnableState().blockedBy)
  end)

  it("reports a halted dependency deep in an automatic chain at the caller's line", function()
    local addon = ModuleKit:ForAddon("MyAddon")
    LifecycleKit:ForAddon("Other"):Halt("broken")
    addon:CreateModule("Bridge", { requiresAddons = { "Other" } })
    addon:CreateModule("Middle", { dependsOn = { "Bridge" } })
    local panel = addon:CreateModule("Panel", { dependsOn = { "Middle" } })
    addon:InitializeAll()

    local source = debug.getinfo(1, "S").short_src
    local line
    local ok, message = pcall(function()
      line = debug.getinfo(1, "l").currentline + 1
      panel:Enable()
    end)

    assert.is_false(ok)
    assert.are.equal(
      source
        .. ":"
        .. line
        .. ': ModuleKit module "Bridge" cannot be enabled because required addon "Other" has halted',
      message
    )
    assert.are.equal("Middle", panel:GetEnableState().blockedBy)
  end)
end)

describe("ModuleKit requiresAddons definitions", function()
  local ModuleKit, LifecycleKit
  before_each(function()
    local packageUnderTest, _, _, _, lifecycleKit = TestEnv.NewPackage()
    ModuleKit = packageUnderTest
    LifecycleKit = lifecycleKit
  end)
  after_each(TestEnv.Reset)

  it("refuses malformed entries at the caller's line", function()
    local addon = ModuleKit:ForAddon("MyAddon")
    local names = {}
    for index = 1, 17 do
      names[index] = "Addon" .. index
    end
    local cases = {
      { { requiresAddons = "Other" }, "requiresAddons must be a dense array" },
      { { requiresAddons = { [2] = "Other" } }, "requiresAddons must be a dense array" },
      { { requiresAddons = { "" } }, "requiresAddons entries must be non-empty strings" },
      { { requiresAddons = { "MyAddon" } }, 'must name other addons, not "MyAddon" itself' },
      { { requiresAddons = names }, "requiresAddons must list at most 16 addons" },
    }
    local source = debug.getinfo(1, "S").short_src

    for index = 1, #cases do
      local line
      local ok, message = pcall(function()
        line = debug.getinfo(1, "l").currentline + 1
        addon:CreateModule("Broken" .. index, cases[index][1])
      end)
      assert.is_false(ok)
      assert.is_not_nil(string.find(message, source .. ":" .. line .. ":", 1, true))
      assert.is_not_nil(string.find(message, cases[index][2], 1, true))
      assert.is_false(addon:HasModule("Broken" .. index))
    end
  end)

  it("ignores a repeated entry", function()
    local addon = ModuleKit:ForAddon("MyAddon")
    local module = addon:CreateModule("Bridge", { requiresAddons = { "Other", "Other" } })
    LifecycleKit:ForAddon("Other"):Halt("broken")

    assert.are.equal("Other", module:GetEnableState().blockedBy)
  end)

  it("refuses a module once the addon has declared the most dependencies", function()
    local addon = ModuleKit:ForAddon("MyAddon")
    local lifecycle = LifecycleKit:ForAddon("MyAddon")
    for index = 1, 16 do
      lifecycle:DependsOn("Declared" .. index)
    end

    TestEnv.expectErrorContaining(
      "already declares the most addon dependencies LifecycleKit accepts",
      function()
        addon:CreateModule("Bridge", { requiresAddons = { "Other" } })
      end
    )
    assert.is_false(addon:HasModule("Bridge"))
    -- An addon it already declared costs nothing more.
    assert.is_not_nil(addon:CreateModule("Known", { requiresAddons = { "Declared1" } }))
  end)
end)

describe("ModuleKit halted state across an in-place upgrade", function()
  after_each(TestEnv.Reset)

  it("gives modules of an older revision an empty requiresAddons", function()
    local ModuleKit = TestEnv.NewPackage()
    local addon = ModuleKit:ForAddon("MyAddon")
    local module = addon:CreateModule("Old")
    rawset(module, "_requiredAddons", nil)
    rawset(rawget(ModuleKit, "_state"), "runtimeRevision", ModuleKit.REVISION - 1)

    TestEnv.ReloadPackage()
    TestEnv.LoadAddon("MyAddon")
    TestEnv.Login()

    assert.are.same({}, rawget(module, "_requiredAddons"))
    assert.is_true(module:IsEnabled())
  end)

  it("runs no module hook when the addon halted before the upgrade", function()
    local ModuleKit, _, _, _, LifecycleKit = TestEnv.NewPackage()
    local addon = ModuleKit:ForAddon("MyAddon")
    local log = {}
    local first = createLoggedModule(addon, "First", log)
    createLoggedModule(addon, "Second", log)
    TestEnv.LoadAddon("MyAddon")
    TestEnv.Login()
    first:Disable()

    -- Model a container of a revision that did not watch the halt.
    local subscriptions = rawget(addon, "_subscriptions")
    subscriptions.halted:Disconnect()
    subscriptions.halted = nil
    rawget(addon, "_dispatched").halted = nil
    LifecycleKit:ForAddon("MyAddon"):Halt("broken")
    rawset(rawget(ModuleKit, "_state"), "runtimeRevision", ModuleKit.REVISION - 1)
    log = {}

    TestEnv.ReloadPackage()

    assert.are.same({}, log)
    assert.is_true(rawget(addon, "_dispatched").halted)
    assert.has_error(function()
      first:Enable()
    end)
    assert.are.same({}, log)
  end)

  it("takes down a module whose OnEnable halts after an upgrade", function()
    local ModuleKit, _, _, _, LifecycleKit = TestEnv.NewPackage()
    local addon = ModuleKit:ForAddon("MyAddon")
    local log = {}
    local loader = createLoggedModule(addon, "Loader", log)
    TestEnv.LoadAddon("MyAddon")
    rawset(rawget(ModuleKit, "_state"), "runtimeRevision", ModuleKit.REVISION - 1)
    TestEnv.ReloadPackage()

    loader.OnEnable = function()
      log[#log + 1] = "enable Loader"
      LifecycleKit:ForAddon("MyAddon"):Halt("broken")
    end
    TestEnv.Login()

    assert.are.same({ "enable Loader", "disable Loader" }, log)
    assert.are.same(
      { wanted = true, actual = false, blockedBy = "halted" },
      loader:GetEnableState()
    )
  end)
end)
