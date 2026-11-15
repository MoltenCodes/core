local TestEnv = require("BindingKitTestEnv")

describe("BindingKit bootstrap", function()
  after_each(TestEnv.Reset)

  it("publishes through Registry", function()
    local BindingKit, Registry = TestEnv.NewPackage()
    local registered, revision = Registry:Get("bindingKit", 1)
    assert.are.equal(BindingKit, registered)
    assert.are.equal(BindingKit.REVISION, revision)
  end)

  it("returns the same facade on a duplicate embedded load and keeps its scopes", function()
    local BindingKit = TestEnv.NewPackage()
    local scope = BindingKit:CreateScope("MyAddon")
    local reloaded = TestEnv.ReloadPackage()
    assert.are.equal(BindingKit, reloaded)
    assert.are.equal(scope, reloaded:GetScope("MyAddon"))
  end)

  it("does not reinterpret private state owned by a newer compatible revision", function()
    local BindingKit, Registry = TestEnv.NewPackage()
    local shippedRevision = BindingKit.REVISION
    local upgraded, previous = Registry:Register("bindingKit", 1, 99)
    assert.are.equal(BindingKit, upgraded)
    assert.are.equal(shippedRevision, previous)

    rawset(BindingKit, "REVISION", 99)
    rawset(BindingKit, "_state", { schema = 999 })
    package.loaded["BindingKit"] = nil
    local reloaded = require("BindingKit")
    assert.are.equal(BindingKit, reloaded)
    assert.are.equal(99, reloaded.REVISION)
  end)

  it(
    "upgrades in place: scopes, function keys, waiting changes and the limits run the new code",
    function()
      local BindingKit = TestEnv.NewPackage()
      local pressed = 0
      local scope = BindingKit:CreateScope("MyAddon")
      scope:BindFunction("F1", function()
        pressed = pressed + 1
      end)
      BindingKit:SetLimits({ maxScopes = 100 })
      TestEnv.SetCombat()
      scope:BindCommand("F2", "B")

      local upgraded = TestEnv.LoadRevision(BindingKit.REVISION + 1)
      assert.are.equal(BindingKit, upgraded)
      assert.are.equal(100, upgraded:GetLimits().maxScopes)
      TestEnv.EndCombat()
      assert.is_false(scope:IsPending())
      local owner = upgraded._state.records[scope].owner
      local button = TestEnv.GetGlobal(TestEnv.Bindings(owner)["F1"].click)
      button:GetScript("OnClick")(button, "LeftButton")
      assert.are.equal(1, pressed)
      assert.are.equal("B", TestEnv.Bindings(owner)["F2"].command)
    end
  )

  it("upgrades revision 1 in place: its scopes retire buttons unbound in combat", function()
    -- Install the host stand-ins, then start over with a copy carrying
    -- revision 1, the way an older addon's embedded copy loads first.
    TestEnv.NewPackage()
    TestEnv.SetGlobal("MoltenCodes", nil)
    package.loaded.Registry = nil
    package.loaded.BindingKit = nil
    require("Registry")
    local old = TestEnv.LoadRevision(1)
    local scope = old:CreateScope("MyAddon")
    scope:BindFunction("F5", function() end)
    -- A revision 1 record has no list of retired buttons.
    local record = old._state.records[scope]
    record.retiredButtons = nil

    local upgraded = TestEnv.ReloadPackage()
    assert.are.equal(old, upgraded)
    assert.is_true(upgraded.REVISION > 1)
    local first = TestEnv.Bindings(record.owner)["F5"].click
    TestEnv.SetCombat()
    scope:Unbind("F5")
    scope:BindFunction("F6", function() end)
    TestEnv.EndCombat()
    assert.are_not.equal(first, TestEnv.Bindings(record.owner)["F6"].click)
    scope:BindFunction("F7", function() end)
    assert.are.equal(first, TestEnv.Bindings(record.owner)["F7"].click)
  end)

  it("refuses shared state whose limits hold an invalid value", function()
    local BindingKit = TestEnv.NewPackage()
    rawset(BindingKit._state.limits, "maxFunctionKeys", 513)
    TestEnv.expectErrorContaining("package state is corrupted or incomplete", function()
      TestEnv.ReloadPackage()
    end)
  end)

  it("requires Registry", function()
    TestEnv.Reset()
    TestEnv.InstallWowApi()
    local ok, value = pcall(require, "BindingKit")
    assert.is_false(ok)
    assert.is_truthy(tostring(value):find("Registry API 2", 1, true))
  end)

  it("refuses an incomplete facade left by an earlier failed load", function()
    TestEnv.Reset()
    TestEnv.InstallWowApi()
    local Registry = require("Registry")
    Registry:Register("bindingKit", 1, 1)
    local ok, value = pcall(TestEnv.requireAfterFailedLoad, "BindingKit")
    assert.is_false(ok)
    assert.is_truthy(tostring(value):find("MoltenCodes BindingKit", 1, true))
  end)
end)
