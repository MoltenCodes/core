local TestEnv = require("ModuleKitTestEnv")

-- The AceAddon-3.0 conveniences of revision 23: intended state without hooks,
-- module defaults, module prototypes, finding addons and the module-created
-- notice. See docs/API.md, "Intent versus fact", "Module prototypes",
-- "Finding addons" and "The module-created notice".

describe("ModuleKit SetEnabledState", function()
  local ModuleKit

  before_each(function()
    ModuleKit = TestEnv.NewPackage()
  end)

  after_each(TestEnv.Reset)

  it("keeps a module out of the ready pass and blocks its dependents", function()
    local addon = ModuleKit:ForAddon("MyAddon")
    local bags = addon:CreateModule("Bags")
    local bank = addon:CreateModule("Bank", { dependsOn = { "Bags" } })
    local enables = 0
    bags.OnEnable = function()
      enables = enables + 1
    end

    assert.is_true(bags:SetEnabledState(false))
    TestEnv.LoadAddon("MyAddon")
    TestEnv.Login()

    assert.are.equal(0, enables)
    assert.are.equal("initialized", bags:GetState())
    assert.are.same({ wanted = false, actual = false }, bags:GetEnableState())
    assert.are.same({ wanted = true, actual = false, blockedBy = "Bags" }, bank:GetEnableState())
  end)

  it("changes the intent only, never the fact, after ready", function()
    local addon = ModuleKit:ForAddon("MyAddon")
    local module = addon:CreateModule("UI")
    local disables = 0
    module.OnDisable = function()
      disables = disables + 1
    end
    TestEnv.LoadAddon("MyAddon")
    TestEnv.Login()

    assert.is_true(module:SetEnabledState(false))
    assert.is_true(module:IsEnabled())
    assert.are.equal(0, disables)
    assert.are.same({ wanted = false, actual = true }, module:GetEnableState())
    assert.is_false(module:SetEnabledState(true))
    assert.are.same({ wanted = true, actual = true }, module:GetEnableState())
  end)

  it("clears a block with the intent, as Disable does", function()
    local addon = ModuleKit:ForAddon("MyAddon")
    addon:CreateModule("Base").OnEnable = function()
      error("offline")
    end
    local dependent = addon:CreateModule("Dependent", { dependsOn = { "Base" } })
    assert.has_error(function()
      addon:EnableAll()
    end)
    assert.are.equal("Base", dependent:GetEnableState().blockedBy)

    dependent:SetEnabledState(false)

    assert.are.same({ wanted = false, actual = false }, dependent:GetEnableState())
  end)

  it("refuses after shutdown and checks its argument at the caller", function()
    local module = ModuleKit:ForAddon("MyAddon"):CreateModule("UI")

    TestEnv.expectCallerError("SetEnabledState enabled must be a boolean", function()
      module:SetEnabledState("no")
    end)
    TestEnv.LoadAddon("MyAddon")
    TestEnv.Login()
    TestEnv.Logout()
    TestEnv.expectCallerError("SetEnabledState cannot run after addon shutdown", function()
      module:SetEnabledState(true)
    end)
  end)
end)

describe("ModuleKit default module state", function()
  local ModuleKit

  before_each(function()
    ModuleKit = TestEnv.NewPackage()
  end)

  after_each(TestEnv.Reset)

  it("applies to modules created afterwards, and a definition overrides it", function()
    local addon = ModuleKit:ForAddon("MyAddon")
    local before = addon:CreateModule("Before")

    assert.is_true(addon:SetDefaultModuleState(false))
    assert.is_false(addon:GetDefaultModuleState())
    local after = addon:CreateModule("After")
    local chosen = addon:CreateModule("Chosen", { enabledState = true })
    TestEnv.LoadAddon("MyAddon")
    TestEnv.Login()

    assert.is_true(before:IsEnabled())
    assert.is_false(after:IsEnabled())
    assert.is_true(chosen:IsEnabled())
    assert.is_false(addon:SetDefaultModuleState(true))
    assert.is_nil(rawget(addon, "_defaultModuleState"))
  end)

  it("initializes a late definition module that is not wanted without enabling it", function()
    local addon = ModuleKit:ForAddon("MyAddon")
    TestEnv.LoadAddon("MyAddon")
    TestEnv.Login()

    local late = addon:CreateModule("Late", { enabledState = false })
    local mutable = addon:CreateModule("Mutable")
    mutable:SetEnabledState(false)
    mutable:Activate()

    assert.are.equal("initialized", late:GetState())
    assert.is_true(mutable:IsEnabled())
  end)

  it("checks its arguments at the caller", function()
    local addon = ModuleKit:ForAddon("MyAddon")

    TestEnv.expectCallerError("SetDefaultModuleState enabled must be a boolean", function()
      addon:SetDefaultModuleState(nil)
    end)
    TestEnv.expectCallerError("definition enabledState must be a boolean", function()
      addon:CreateModule("Bad", { enabledState = 1 })
    end)
    assert.is_false(addon:HasModule("Bad"))
  end)
end)

describe("ModuleKit module prototypes", function()
  local ModuleKit

  before_each(function()
    ModuleKit = TestEnv.NewPackage()
  end)

  after_each(TestEnv.Reset)

  it("looks up own fields, then ModuleKit's methods, then the prototype", function()
    local prototype = {
      Describe = function(self)
        return "module " .. self:GetName()
      end,
      label = "shared",
    }
    local addon = ModuleKit:ForAddon("MyAddon")
    addon:SetDefaultModulePrototype(prototype)
    local module = addon:CreateModule("Bags")
    module.label = "own"

    assert.are.equal("module Bags", module:Describe())
    assert.are.equal("own", module.label)
    assert.are.equal(ModuleKit.Module.GetName, module.GetName)
    assert.are.equal(prototype, addon:GetDefaultModulePrototype())
  end)

  it("runs hooks the prototype carries in every phase and honours them in implements", function()
    local calls = {}
    local prototype = {
      OnInitialize = function(self)
        calls[#calls + 1] = "initialize " .. self:GetName()
      end,
      OnEnable = function(self)
        calls[#calls + 1] = "enable " .. self:GetName()
      end,
      OnDisable = function(self)
        calls[#calls + 1] = "disable " .. self:GetName()
      end,
    }
    local addon = ModuleKit:ForAddon("MyAddon")
    local module = addon:CreateModule("Bags", {
      prototype = prototype,
      implements = { "OnEnable", "OnDisable" },
    })
    TestEnv.LoadAddon("MyAddon")
    TestEnv.Login()
    module:Disable()

    assert.are.same({ "initialize Bags", "enable Bags", "disable Bags" }, calls)
  end)

  it("keeps the prototype a module was created with, and false opts out of the default", function()
    local first, second = { kind = "first" }, { kind = "second" }
    local addon = ModuleKit:ForAddon("MyAddon")
    addon:SetDefaultModulePrototype(first)
    local early = addon:CreateModule("Early")
    local none = addon:CreateModule("None", { prototype = false })
    assert.are.equal(first, addon:SetDefaultModulePrototype(second))
    local late = addon:CreateModule("Late")
    local own = addon:CreateModule("Own", { prototype = first })
    addon:SetDefaultModulePrototype(nil)

    assert.are.equal("first", early.kind)
    assert.is_nil(none.kind)
    assert.are.equal("second", late.kind)
    assert.are.equal("first", own.kind)
    assert.are.equal(getmetatable(early), getmetatable(own))
    assert.is_nil(addon:GetDefaultModulePrototype())
  end)

  it("follows a prototype that has its own metatable", function()
    local base = {
      Greet = function()
        return "hello"
      end,
    }
    local prototype = setmetatable({}, { __index = base })
    local module = ModuleKit:ForAddon("MyAddon"):CreateModule("Bags", { prototype = prototype })

    assert.are.equal("hello", module:Greet())
  end)

  it("refuses prototypes it cannot honour at the caller, leaving no module", function()
    local addon = ModuleKit:ForAddon("MyAddon")

    TestEnv.expectCallerError("prototype must be a table", function()
      addon:SetDefaultModulePrototype("Base")
    end)
    TestEnv.expectCallerError([[key "Enable" shadows ModuleKit's Module:Enable]], function()
      addon:SetDefaultModulePrototype({ Enable = function() end })
    end)
    TestEnv.expectCallerError([[key "scope" is reserved for ModuleKit]], function()
      addon:CreateModule("Scoped", { prototype = { scope = {} } })
    end)
    TestEnv.expectCallerError([[key "_state" is reserved for ModuleKit]], function()
      addon:CreateModule("Private", { prototype = { _state = "enabled" } })
    end)
    assert.is_false(addon:HasModule("Scoped"))
    assert.is_false(addon:HasModule("Private"))
    assert.is_nil(addon:GetDefaultModulePrototype())
  end)

  it("gives a prototyped module the methods of a newer revision", function()
    local addon = ModuleKit:ForAddon("MyAddon")
    local module = addon:CreateModule("Bags", { prototype = {} })
    local upgraded = TestEnv.LoadRevision(ModuleKit.REVISION + 1)

    assert.are.equal(ModuleKit, upgraded)
    assert.are.equal(rawget(upgraded.Module, "GetName"), module.GetName)
    assert.are.equal("Bags", module:GetName())
  end)
end)

describe("ModuleKit finding addons", function()
  local ModuleKit

  before_each(function()
    ModuleKit = TestEnv.NewPackage()
  end)

  after_each(TestEnv.Reset)

  it("finds a container without creating one, and lists every container sorted", function()
    assert.is_nil(ModuleKit:FindAddon("Zeta"))
    assert.are.same({}, ModuleKit:GetAddons())

    local zeta = ModuleKit:ForAddon("Zeta")
    ModuleKit:ForAddon("Alpha")
    local names = ModuleKit:GetAddons()
    names[1] = "changed"

    assert.are.equal(zeta, ModuleKit:FindAddon("Zeta"))
    assert.are.same({ "Alpha", "Zeta" }, ModuleKit:GetAddons())
    TestEnv.expectCallerError("ModuleKit:FindAddon addonName", function()
      ModuleKit:FindAddon("")
    end)
  end)
end)

describe("ModuleKit module-created notice", function()
  local ModuleKit

  before_each(function()
    ModuleKit = TestEnv.NewPackage()
    TestEnv.InstallHostErrorHandler()
  end)

  after_each(TestEnv.Reset)

  it("publishes each new module after it is in the container and before its catch-up", function()
    local addon = ModuleKit:ForAddon("MyAddon")
    TestEnv.LoadAddon("MyAddon")
    TestEnv.Login()
    local seen = {}
    local connection = addon:OnModuleCreated(function(module)
      seen[#seen + 1] = { module:GetName(), addon:HasModule(module:GetName()), module:GetState() }
    end)

    local late = addon:CreateModule("Late", {})

    assert.are.same({ { "Late", true, "created" } }, seen)
    assert.is_true(late:IsEnabled())
    connection:Disconnect()
    addon:CreateModule("Quiet")
    assert.are.equal(1, #seen)
  end)

  it("calls a receiver's method, named or by default", function()
    local addon = ModuleKit:ForAddon("MyAddon")
    local receiver = { names = {} }
    function receiver:OnModuleCreated(module)
      self.names[#self.names + 1] = module:GetName()
    end
    function receiver:Track(module)
      self.names[#self.names + 1] = "tracked " .. module:GetName()
    end
    addon:OnModuleCreated(receiver)
    addon:OnModuleCreated(receiver, "Track")

    addon:CreateModule("Bags")

    assert.are.same({ "Bags", "tracked Bags" }, receiver.names)
  end)

  it("reports a raising listener and still returns the module", function()
    local addon = ModuleKit:ForAddon("MyAddon")
    addon:OnModuleCreated(function()
      error("listener broke")
    end)

    local module = addon:CreateModule("Bags")

    assert.is_true(addon:HasModule("Bags"))
    assert.are.equal("Bags", module:GetName())
    local reported = TestEnv.ReportedErrors()
    assert.are.equal(1, #reported)
    assert.is_not_nil(tostring(reported[1]):find("listener broke", 1, true))
  end)

  it("touches no bus until someone subscribes", function()
    local addon = ModuleKit:ForAddon("MyAddon")
    addon:CreateModule("Bags")

    assert.is_nil(rawget(addon, "_moduleCreatedBus"))
    assert.are.same({}, require("SignalKit"):Bus("MyAddon"):Topics())
  end)

  it("answers full at the bus limits", function()
    local bus = require("SignalKit"):Bus("MyAddon", { maxTopics = 1 })
    bus:DeclareTopic("Other")

    local connection, reason = ModuleKit:ForAddon("MyAddon"):OnModuleCreated(function() end)

    assert.is_nil(connection)
    assert.are.equal("full", reason)
  end)

  it("checks its arguments at registration, at the caller", function()
    local addon = ModuleKit:ForAddon("MyAddon")

    TestEnv.expectCallerError([[receiver has no method "OnModuleCreated"]], function()
      addon:OnModuleCreated({})
    end)
    TestEnv.expectCallerError("methodName must be a non-empty string", function()
      addon:OnModuleCreated({}, "")
    end)
    TestEnv.expectCallerError("callback must be a function, or a receiver table", function()
      addon:OnModuleCreated("OnModuleCreated")
    end)
  end)

  it("raises at the caller when SignalKit cannot be found", function()
    local addon = ModuleKit:ForAddon("MyAddon")
    local Registry = require("Registry")
    local find = rawget(Registry, "Find")
    rawset(Registry, "Find", function(self, name, api)
      if name == "signalKit" then
        return nil, "missing"
      end
      return find(self, name, api)
    end)

    local ok, message = pcall(addon.OnModuleCreated, addon, function() end)
    rawset(Registry, "Find", find)

    assert.is_false(ok)
    assert.is_not_nil(tostring(message):find("needs SignalKit API 1, which is not loaded", 1, true))
  end)
end)

describe("ModuleKit conveniences and secret values", function()
  local ModuleKit, addon, secret

  before_each(function()
    TestEnv.Reset()
    TestEnv.SetWowProfile("mainline")
    TestEnv.InstallWowApi()
    require("Registry")
    require("SignalKit")
    require("EventKit")
    require("LifecycleKit")
    ModuleKit = require("ModuleKit")
    addon = ModuleKit:ForAddon("MyAddon")
    secret = TestEnv.NewSecretValue()
  end)

  after_each(TestEnv.Reset)

  it("refuses secret arguments at the caller before comparing them", function()
    local module = addon:CreateModule("UI")

    TestEnv.expectCallerError("SetEnabledState enabled must not be a secret value", function()
      module:SetEnabledState(secret)
    end)
    TestEnv.expectCallerError("SetDefaultModuleState enabled must not be a secret value", function()
      addon:SetDefaultModuleState(secret)
    end)
    TestEnv.expectCallerError("definition enabledState must not be a secret value", function()
      addon:CreateModule("Hidden", { enabledState = secret })
    end)
    TestEnv.expectCallerError("prototype must not be a secret value", function()
      addon:SetDefaultModulePrototype(secret)
    end)
    TestEnv.expectCallerError("prototype keys must not be secret values", function()
      addon:SetDefaultModulePrototype({ [secret] = true })
    end)
    TestEnv.expectCallerError("callback must not be a secret value", function()
      addon:OnModuleCreated(secret)
    end)
    TestEnv.expectCallerError("methodName must not be a secret value", function()
      addon:OnModuleCreated({}, secret)
    end)
    assert.is_false(addon:HasModule("Hidden"))
  end)
end)
