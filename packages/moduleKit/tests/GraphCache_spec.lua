local TestEnv = require("ModuleKitTestEnv")

-- The validated graph order, each module's resolved hard dependencies and each
-- module's hard dependents are cached (revision 19) and dropped whenever the
-- graph can change: a module is created, or a module still in `created` state
-- declares a constraint. These specs pin that every such change is seen by the
-- next graph operation, and that an invalid graph is never cached.
describe("ModuleKit graph cache", function()
  local ModuleKit

  before_each(function()
    ModuleKit = TestEnv.NewPackage()
  end)

  after_each(TestEnv.Reset)

  it("sees an ordering constraint declared after the order was cached", function()
    local addon = ModuleKit:ForAddon("MyAddon")
    local first = addon:CreateModule("First")
    addon:CreateModule("Second")
    assert.are.same({ "First", "Second" }, addon:GetActivationOrder())

    first:After("Second")

    assert.are.same({ "Second", "First" }, addon:GetActivationOrder())
  end)

  it("sees a module created after the order was cached", function()
    local addon = ModuleKit:ForAddon("MyAddon")
    local consumer = addon:CreateModule("Consumer")
    consumer:OptionalDependency("Provider")
    assert.are.same({ "Consumer" }, addon:GetActivationOrder())

    -- The optional edge had no target when the order was cached.
    addon:CreateModule("Provider")

    assert.are.same({ "Provider", "Consumer" }, addon:GetActivationOrder())
  end)

  it("reports a missing dependency on every call and caches only a valid graph", function()
    local addon = ModuleKit:ForAddon("MyAddon")
    addon:CreateModule("Consumer"):DependsOn("Provider")

    for _ = 1, 2 do
      TestEnv.expectErrorContaining('requires missing dependency "Provider"', function()
        addon:ValidateGraph()
      end)
    end

    addon:CreateModule("Provider")
    assert.are.same({ "Provider", "Consumer" }, addon:GetActivationOrder())
  end)

  it("reports a cycle on every call", function()
    local addon = ModuleKit:ForAddon("MyAddon")
    addon:CreateModule("A"):DependsOn("B")
    addon:CreateModule("B"):DependsOn("A")

    for _ = 1, 2 do
      TestEnv.expectErrorContaining("dependency cycle detected", function()
        addon:GetActivationOrder()
      end)
    end
  end)

  it("uses a dependency declared after the module's list was resolved", function()
    local addon = ModuleKit:ForAddon("MyAddon")
    addon:SetDependencyPolicy("strict")
    local consumer = addon:CreateModule("Consumer")
    addon:CreateModule("Database"):Enable()
    addon:CreateModule("Cache")
    consumer:DependsOn("Database")
    addon:ValidateGraph()

    consumer:DependsOn("Cache")

    TestEnv.expectErrorContaining('requires enabled dependency "Cache"', function()
      consumer:Enable()
    end)
  end)

  it("names a dependent created after the dependents were cached", function()
    local addon = ModuleKit:ForAddon("MyAddon")
    addon:SetDependencyPolicy("strict")
    local database = addon:CreateModule("Database")
    addon:CreateModule("Early", { dependsOn = { "Database" } })
    addon:EnableAll()

    addon:CreateModule("Late", { dependsOn = { "Database" } }):Activate()
    addon:CreateModule("Other"):Activate()
    addon:DisableAll()
    addon:EnableAll()

    -- Newest enabled dependent first.
    TestEnv.expectErrorContaining('while dependent "Late" is enabled', function()
      database:Disable()
    end)
  end)

  it("keeps a whole-container pass on its order when a hook creates a module", function()
    local addon = ModuleKit:ForAddon("MyAddon")
    local log = {}
    local function record(self)
      log[#log + 1] = self:GetName()
    end
    addon:CreateModule("First").OnEnable = function(self)
      record(self)
      if addon:HasModule("Created") == false then
        addon:CreateModule("Created", { onEnable = record, after = { "Second" } })
      end
    end
    addon:CreateModule("Second").OnEnable = record

    -- The `ready` pass is walking the cached order when `Created` appears;
    -- its catch-up waits for the pass to finish.
    TestEnv.LoadAddon("MyAddon")
    TestEnv.Login()

    assert.are.same({ "First", "Second", "Created" }, log)
    assert.are.same({ "First", "Second", "Created" }, addon:GetActivationOrder())
  end)

  it("disables in reverse order through the cached dependents", function()
    local addon = ModuleKit:ForAddon("MyAddon")
    local log = {}
    local function record(self)
      log[#log + 1] = self:GetName()
    end
    addon:CreateModule("Consumer", { dependsOn = { "Base" }, onDisable = record })
    addon:CreateModule("Base", { onDisable = record })
    addon:CreateModule("Solo", { onDisable = record })
    addon:EnableAll()

    addon:DisableAll()

    assert.are.same({ "Solo", "Consumer", "Base" }, log)
  end)

  it("stores no constraint tables for a module that declares none", function()
    local addon = ModuleKit:ForAddon("MyAddon")
    local module = addon:CreateModule("Plain")
    TestEnv.LoadAddon("MyAddon")
    TestEnv.Login()

    assert.is_true(module:IsEnabled())
    for _, field in ipairs({
      "_hardDependencies",
      "_optionalDependencies",
      "_before",
      "_after",
      "_injectSpec",
      "_requiredAddons",
      "_lastError",
      "_hasLastError",
      "_blockedBy",
      "_enableBlockedBy",
    }) do
      assert.is_nil(rawget(module, field), field)
    end
    assert.is_false(module:HasLastError())
    assert.are.same({}, module:GetInjections())
  end)
end)
