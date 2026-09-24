local TestEnv = require("ModuleKitTestEnv")

describe("ModuleKit dependency graph", function()
  local ModuleKit

  before_each(function()
    ModuleKit = TestEnv.NewPackage()
  end)

  after_each(TestEnv.Reset)

  it("orders hard dependencies before dependents", function()
    local addon = ModuleKit:ForAddon("MyAddon")
    local ui = addon:CreateModule("UI")
    addon:CreateModule("Database")
    ui:DependsOn("Database")

    assert.are.same({ "Database", "UI" }, addon:GetActivationOrder())
  end)

  it("uses creation order for unrelated modules", function()
    local addon = ModuleKit:ForAddon("MyAddon")
    addon:CreateModule("SecondNameFirst")
    addon:CreateModule("Alpha")

    assert.are.same({ "SecondNameFirst", "Alpha" }, addon:GetActivationOrder())
  end)

  it("honors Before and After ordering constraints", function()
    local addon = ModuleKit:ForAddon("MyAddon")
    local ui = addon:CreateModule("UI")
    local database = addon:CreateModule("Database")
    addon:CreateModule("Profiles")

    database:Before("UI")
    ui:After("Profiles")

    assert.are.same({ "Database", "Profiles", "UI" }, addon:GetActivationOrder())
  end)

  it("ignores missing optional dependencies", function()
    local addon = ModuleKit:ForAddon("MyAddon")
    local ui = addon:CreateModule("UI")
    ui:OptionalDependency("Analytics")

    assert.is_true(addon:ValidateGraph())
    assert.are.same({ "UI" }, addon:GetActivationOrder())
  end)

  it("orders an optional dependency when it exists", function()
    local addon = ModuleKit:ForAddon("MyAddon")
    local ui = addon:CreateModule("UI")
    ui:OptionalDependency("Analytics")
    addon:CreateModule("Analytics")

    assert.are.same({ "Analytics", "UI" }, addon:GetActivationOrder())
  end)

  it("rejects missing hard dependencies", function()
    local addon = ModuleKit:ForAddon("MyAddon")
    addon:CreateModule("UI"):DependsOn("Database")

    assert.has_error(function()
      addon:ValidateGraph()
    end)
  end)

  it("detects hard dependency cycles", function()
    local addon = ModuleKit:ForAddon("MyAddon")
    local a = addon:CreateModule("A")
    local b = addon:CreateModule("B")
    local c = addon:CreateModule("C")
    a:DependsOn("B")
    b:DependsOn("C")
    c:DependsOn("A")

    assert.has_error(function()
      addon:ValidateGraph()
    end)
  end)

  it("detects cycles introduced by ordering-only constraints", function()
    local addon = ModuleKit:ForAddon("MyAddon")
    local a = addon:CreateModule("A")
    local b = addon:CreateModule("B")
    a:Before("B")
    b:Before("A")

    assert.has_error(function()
      addon:ValidateGraph()
    end)
  end)

  it("disables all modules in reverse topological order", function()
    local addon = ModuleKit:ForAddon("MyAddon")
    local calls = {}
    local database = addon:CreateModule("Database")
    local ui = addon:CreateModule("UI")
    ui:DependsOn("Database")

    database.OnDisable = function()
      calls[#calls + 1] = "Database"
    end
    ui.OnDisable = function()
      calls[#calls + 1] = "UI"
    end

    addon:EnableAll()
    addon:DisableAll()

    assert.are.same({ "UI", "Database" }, calls)
  end)

  it(
    "rejects a late module that would retroactively precede an initialized optional dependent",
    function()
      local addon = ModuleKit:ForAddon("MyAddon")
      local ui = addon:CreateModule("UI")
      ui:OptionalDependency("Analytics")
      ui:Initialize()

      assert.has_error(function()
        addon:CreateModule("Analytics")
      end)
      assert.is_false(addon:HasModule("Analytics"))
    end
  )

  it("rejects a late module definition that must run before an initialized module", function()
    local addon = ModuleKit:ForAddon("MyAddon")
    local ui = addon:CreateModule("UI")
    ui:Initialize()

    assert.has_error(function()
      addon:CreateModule("Bootstrap", {
        before = { "UI" },
      })
    end)
    assert.is_false(addon:HasModule("Bootstrap"))
  end)

  it("allows a late module whose ordering only places it after initialized modules", function()
    local addon = ModuleKit:ForAddon("MyAddon")
    local core = addon:CreateModule("Core")
    core:Initialize()

    local late = addon:CreateModule("Late", {
      after = { "Core" },
    })

    assert.is_not_nil(late)
    assert.are.same({ "Core", "Late" }, addon:GetActivationOrder())
  end)

  it(
    "does not let an unrelated invalid module block targeted hard-dependency operations",
    function()
      local addon = ModuleKit:ForAddon("MyAddon")
      addon:CreateModule("Broken"):DependsOn("Missing")
      local healthy = addon:CreateModule("Healthy")

      healthy:Enable()

      assert.is_true(healthy:IsEnabled())
    end
  )

  it("rejects mutable late Before constraints against initialized modules", function()
    local addon = ModuleKit:ForAddon("MyAddon")
    local ui = addon:CreateModule("UI")
    ui:Initialize()
    local late = addon:CreateModule("Late")

    assert.has_error(function()
      late:Before("UI")
    end)
  end)
end)

-- The topological sort keeps its ready set sorted by creation order instead of
-- re-sorting after every insertion. These specs pin the emitted order so that
-- optimisation cannot quietly change it.
describe("ModuleKit deterministic activation order", function()
  local ModuleKit

  before_each(function()
    ModuleKit = TestEnv.NewPackage()
  end)

  after_each(TestEnv.Reset)

  --- Twelve modules created in name order, with dependency edges that force
  --- the ready set to hold several candidates at once and to be refilled out
  --- of creation order. The expected order is the one Kahn's algorithm
  --- produces when the smallest creation order always wins.
  local function buildLayeredFixture(addon)
    for index = 1, 12 do
      addon:CreateModule(string.format("M%02d", index))
    end

    addon:GetModule("M04"):DependsOn("M07")
    addon:GetModule("M05"):DependsOn("M07")
    addon:GetModule("M09"):DependsOn("M01")
    addon:GetModule("M12"):DependsOn("M11")
    addon:GetModule("M11"):DependsOn("M10")
    addon:GetModule("M03"):DependsOn("M12")
    addon:GetModule("M06"):DependsOn("M02")
  end

  local LAYERED_ORDER = {
    "M01",
    "M02",
    "M06",
    "M07",
    "M04",
    "M05",
    "M08",
    "M09",
    "M10",
    "M11",
    "M12",
    "M03",
  }

  it("orders a larger layered graph deterministically", function()
    local addon = ModuleKit:ForAddon("MyAddon")
    buildLayeredFixture(addon)

    assert.are.same(LAYERED_ORDER, addon:GetActivationOrder())
  end)

  it("returns the same order on every call", function()
    local addon = ModuleKit:ForAddon("MyAddon")
    buildLayeredFixture(addon)

    assert.are.same(addon:GetActivationOrder(), addon:GetActivationOrder())
    assert.are.same(LAYERED_ORDER, addon:GetActivationOrder())
  end)

  it("activates the larger graph in the order it reports", function()
    local addon = ModuleKit:ForAddon("MyAddon")
    buildLayeredFixture(addon)

    local calls = {}
    local modules = addon:GetModules()
    for index = 1, #modules do
      local module = modules[index]
      module.OnInitialize = function(self)
        calls[#calls + 1] = self:GetName()
      end
    end

    addon:InitializeAll()

    assert.are.same(LAYERED_ORDER, calls)
  end)
end)
