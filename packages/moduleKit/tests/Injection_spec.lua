local TestEnv = require("ModuleKitTestEnv")

describe("ModuleKit dependency injection", function()
  local ModuleKit

  before_each(function()
    ModuleKit = TestEnv.NewPackage()
  end)

  after_each(TestEnv.Reset)

  it("injects values", function()
    local addon = ModuleKit:ForAddon("MyAddon")
    local config = { enabled = true }
    addon:ProvideValue("Config", config)
    local module = addon:CreateModule("UI")
    module:Inject("config", "Config")
    module:Initialize()

    assert.are.equal(config, module:GetInjections().config)
  end)

  it("resolves singleton factories once", function()
    local addon = ModuleKit:ForAddon("MyAddon")
    local calls = 0
    addon:ProvideSingleton("Database", function()
      calls = calls + 1
      return { id = calls }
    end)

    local first = addon:Resolve("Database")
    local second = addon:Resolve("Database")

    assert.are.equal(first, second)
    assert.are.equal(1, calls)
  end)

  it("caches module-scoped providers per module", function()
    local addon = ModuleKit:ForAddon("MyAddon")
    local calls = 0
    addon:ProvideModule("Logger", function(_, module)
      calls = calls + 1
      return { owner = module:GetName() }
    end)
    local a = addon:CreateModule("A")
    local b = addon:CreateModule("B")

    local aFirst = a:Resolve("Logger")
    local aSecond = a:Resolve("Logger")
    local bFirst = b:Resolve("Logger")

    assert.are.equal(aFirst, aSecond)
    assert.are_not.equal(aFirst, bFirst)
    assert.are.equal("A", aFirst.owner)
    assert.are.equal("B", bFirst.owner)
    assert.are.equal(2, calls)
  end)

  it("creates a new transient value for every resolution", function()
    local addon = ModuleKit:ForAddon("MyAddon")
    local calls = 0
    addon:ProvideTransient("Request", function()
      calls = calls + 1
      return { id = calls }
    end)
    local module = addon:CreateModule("UI")

    local first = module:Resolve("Request")
    local second = module:Resolve("Request")

    assert.are_not.equal(first, second)
    assert.are.equal(2, calls)
  end)

  it("can inject another module by name", function()
    local addon = ModuleKit:ForAddon("MyAddon")
    local database = addon:CreateModule("Database")
    local ui = addon:CreateModule("UI")
    ui:DependsOn("Database")
    ui:Inject("database", "Database")
    ui:Initialize()

    assert.are.equal(database, ui:GetInjections().database)
  end)

  it("keeps lifecycle dependency explicit from injection", function()
    local addon = ModuleKit:ForAddon("MyAddon")
    local database = addon:CreateModule("Database")
    local ui = addon:CreateModule("UI")
    ui:Inject("database", "Database")
    ui:Enable()

    assert.is_false(database:IsEnabled())
    assert.is_true(ui:IsEnabled())
  end)

  it("rejects provider and module name collisions", function()
    local addon = ModuleKit:ForAddon("MyAddon")
    addon:ProvideValue("Database", {})

    assert.has_error(function()
      addon:CreateModule("Database")
    end)
  end)

  it("detects provider resolution cycles", function()
    local addon = ModuleKit:ForAddon("MyAddon")
    addon:ProvideSingleton("A", function(container)
      return container:Resolve("B")
    end)
    addon:ProvideSingleton("B", function(container)
      return container:Resolve("A")
    end)

    assert.has_error(function()
      addon:Resolve("A")
    end)
  end)

  it("resolves injection aliases deterministically", function()
    local addon = ModuleKit:ForAddon("MyAddon")
    local calls = {}
    addon:ProvideTransient("First", function()
      calls[#calls + 1] = "First"
      return 1
    end)
    addon:ProvideTransient("Second", function()
      calls[#calls + 1] = "Second"
      return 2
    end)
    local module = addon:CreateModule("UI")
    module:Inject({ z = "Second", a = "First" })
    module:Initialize()

    assert.are.same({ "First", "Second" }, calls)
  end)
  it("rejects nil factory results", function()
    local addon = ModuleKit:ForAddon("MyAddon")
    addon:ProvideTransient("Broken", function()
      return nil
    end)

    assert.has_error(function()
      addon:Resolve("Broken")
    end)
  end)

  it(
    "allows the same module-scoped provider to resolve for a different module during a factory",
    function()
      local addon = ModuleKit:ForAddon("MyAddon")
      local a = addon:CreateModule("A")
      local b = addon:CreateModule("B")

      addon:ProvideModule("Logger", function(_, module)
        if module == a then
          return { peer = b:Resolve("Logger") }
        end
        return { owner = module:GetName() }
      end)

      local value = a:Resolve("Logger")
      assert.are.equal("B", value.peer.owner)
    end
  )

  it("rejects forged requestingModule values on addon-level resolution", function()
    local addon = ModuleKit:ForAddon("MyAddon")
    addon:ProvideModule("Logger", function(_, module)
      return module:GetName()
    end)

    assert.has_error(function()
      addon:Resolve("Logger", { _addon = addon, _name = "Fake" })
    end)
  end)

  it("returns injection table snapshots without replacing injected value identity", function()
    local addon = ModuleKit:ForAddon("MyAddon")
    local config = { enabled = true }
    addon:ProvideValue("Config", config)
    local module = addon:CreateModule("UI")
    module:Inject("config", "Config")
    module:Initialize()

    local first = module:GetInjections()
    local second = module:GetInjections()
    assert.are_not.equal(first, second)
    assert.are.equal(config, first.config)
    first.config = nil
    assert.are.equal(config, second.config)
    assert.are.equal(config, module:GetInjections().config)
  end)
end)
