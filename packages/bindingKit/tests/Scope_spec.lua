local TestEnv = require("BindingKitTestEnv")

describe("BindingKit scopes", function()
  local BindingKit
  before_each(function()
    BindingKit = TestEnv.NewPackage()
    TestEnv.InstallHostErrorHandler()
  end)
  after_each(TestEnv.Reset)

  local function ownerOf(scope)
    return BindingKit._state.records[scope].owner
  end

  it("sets each kind of binding on the scope's owner", function()
    local scope = BindingKit:CreateScope("MyAddon")
    scope:BindCommand("CTRL-M", "TOGGLEWORLDMAP")
    scope:BindClick("CTRL-B", "MyAddonButton")
    scope:BindClick("CTRL-R", "MyAddonButton", "RightButton")
    local bound = TestEnv.Bindings(ownerOf(scope))
    assert.are.same({ priority = false, command = "TOGGLEWORLDMAP" }, bound["CTRL-M"])
    assert.are.same(
      { priority = false, click = "MyAddonButton", mouseButton = "LeftButton" },
      bound["CTRL-B"]
    )
    assert.are.equal("RightButton", bound["CTRL-R"].mouseButton)
    assert.are.same({ "command", "TOGGLEWORLDMAP" }, { scope:GetBinding("CTRL-M") })
    assert.are.same({ "click", "MyAddonButton" }, { scope:GetBinding("CTRL-B") })
    assert.are.same({}, { scope:GetBinding("CTRL-X") })
    assert.are.equal("MyAddon", scope:GetName())
    assert.are.equal("BindingKit.Scope", getmetatable(scope))
  end)

  it("returns the scope of a name, and keeps its first priority", function()
    local scope = BindingKit:CreateScope("MyAddon", { priority = true })
    assert.are.equal(scope, BindingKit:CreateScope("MyAddon"))
    assert.are.equal(scope, BindingKit:GetScope("MyAddon"))
    assert.is_nil(BindingKit:GetScope("Other"))
    scope:BindCommand("F1", "TOGGLEBAG1")
    assert.is_true(TestEnv.Bindings(ownerOf(scope))["F1"].priority)
  end)

  it("keeps scopes apart: each owner holds only its own bindings", function()
    local mine = BindingKit:CreateScope("Mine")
    local theirs = BindingKit:CreateScope("Theirs")
    mine:BindCommand("F1", "A")
    theirs:BindCommand("F1", "B")
    mine:ClearAll()
    assert.are.same({}, TestEnv.Bindings(ownerOf(mine)))
    assert.are.equal("B", TestEnv.Bindings(ownerOf(theirs))["F1"].command)
  end)

  it(
    "calls a function key's function through its hidden named button, and reports one that raises",
    function()
      local scope = BindingKit:CreateScope("MyAddon")
      local pressed = {}
      scope:BindFunction("CTRL-SHIFT-T", function(key)
        pressed[#pressed + 1] = key
      end)
      local entry = TestEnv.Bindings(ownerOf(scope))["CTRL-SHIFT-T"]
      assert.are.equal("MoltenCodesBindingKitButton1", entry.click)
      local button = TestEnv.GetGlobal(entry.click)
      assert.is_false(button:IsShown())
      button:GetScript("OnClick")(button, "LeftButton")
      assert.are.same({ "CTRL-SHIFT-T" }, pressed)
      assert.are.equal("function", (scope:GetBinding("CTRL-SHIFT-T")))
      scope:BindFunction("CTRL-SHIFT-T", function()
        error("key failed", 0)
      end)
      button = TestEnv.GetGlobal(TestEnv.Bindings(ownerOf(scope))["CTRL-SHIFT-T"].click)
      button:GetScript("OnClick")(button, "LeftButton")
      assert.are.same({ "key failed" }, TestEnv.TakeReportedValues())
    end
  )

  it("frees a function key's button on Unbind and reuses it", function()
    local scope = BindingKit:CreateScope("MyAddon")
    scope:BindFunction("F5", function() end)
    local first = TestEnv.Bindings(ownerOf(scope))["F5"].click
    assert.is_true(scope:Unbind("F5"))
    assert.is_false(scope:Unbind("F5"))
    assert.is_nil(TestEnv.Bindings(ownerOf(scope))["F5"])
    local button = TestEnv.GetGlobal(first)
    button:GetScript("OnClick")(button, "LeftButton")
    scope:BindFunction("F6", function() end)
    assert.are.equal(first, TestEnv.Bindings(ownerOf(scope))["F6"].click)
    assert.are.equal(1, BindingKit._state.buttonCount)
    scope:BindCommand("F6", "TOGGLEBAG1")
    assert.are.equal(0, BindingKit._state.functionKeyCount)
  end)

  it("keeps changes made in combat and applies them when combat ends", function()
    local scope = BindingKit:CreateScope("MyAddon")
    scope:BindCommand("F1", "A")
    TestEnv.SetCombat()
    scope:BindCommand("F2", "B")
    assert.is_true(scope:IsPending())
    assert.is_nil(TestEnv.Bindings(ownerOf(scope))["F2"])
    assert.are.equal("B", select(2, scope:GetBinding("F2")))
    TestEnv.Emit("PLAYER_REGEN_ENABLED")
    assert.is_true(scope:IsPending())
    TestEnv.EndCombat()
    assert.is_false(scope:IsPending())
    assert.are.equal("B", TestEnv.Bindings(ownerOf(scope))["F2"].command)
    assert.are.equal("A", TestEnv.Bindings(ownerOf(scope))["F1"].command)
    assert.is_nil(BindingKit._state.eventFrame.registrations.PLAYER_REGEN_ENABLED)
  end)

  it("keeps a button unbound in combat out of reuse until the client lets it go", function()
    local scope = BindingKit:CreateScope("MyAddon")
    local pressed = {}
    scope:BindFunction("F5", function()
      pressed[#pressed + 1] = "F5"
    end)
    local first = TestEnv.Bindings(ownerOf(scope))["F5"].click
    TestEnv.SetCombat()
    scope:Unbind("F5")
    scope:BindFunction("F6", function()
      pressed[#pressed + 1] = "F6"
    end)
    -- In combat the client still clicks the first button on F5: the change
    -- waits. That press must not run the function F6 was given.
    local button = TestEnv.GetGlobal(first)
    button:GetScript("OnClick")(button, "LeftButton")
    assert.are.same({}, pressed)
    TestEnv.EndCombat()
    local second = TestEnv.Bindings(ownerOf(scope))["F6"].click
    assert.are_not.equal(first, second)
    assert.is_nil(TestEnv.Bindings(ownerOf(scope))["F5"])
    -- Once the client has let go of it, the button is reused.
    scope:BindFunction("F7", function() end)
    assert.are.equal(first, TestEnv.Bindings(ownerOf(scope))["F7"].click)
  end)

  it("clears every binding with ClearAll and counts them", function()
    local scope = BindingKit:CreateScope("MyAddon")
    scope:BindCommand("F1", "A")
    scope:BindFunction("F2", function() end)
    assert.are.equal(2, scope:ClearAll())
    assert.are.same({}, TestEnv.Bindings(ownerOf(scope)))
    assert.are.equal(0, BindingKit._state.functionKeyCount)
  end)

  it("holds at most maxScopes scopes and maxFunctionKeys function keys", function()
    assert.are.same({ maxScopes = 32, maxFunctionKeys = 64 }, BindingKit:GetLimits())
    BindingKit:SetLimits({ maxScopes = 1, maxFunctionKeys = 1 })
    local scope = BindingKit:CreateScope("One")
    TestEnv.expectErrorContaining(
      "BindingKit:CreateScope holds at most 1 scopes; raise maxScopes with BindingKit:SetLimits",
      function()
        BindingKit:CreateScope("Two")
      end
    )
    scope:BindFunction("F1", function() end)
    scope:BindFunction("F1", function() end)
    TestEnv.expectErrorContaining(
      "BindingKit.Scope:BindFunction holds at most 1 function keys; raise maxFunctionKeys with BindingKit:SetLimits",
      function()
        scope:BindFunction("F2", function() end)
      end
    )
    BindingKit:SetLimits({ maxScopes = 256, maxFunctionKeys = 512 })
    BindingKit:CreateScope("Two")
  end)

  it("refuses to make a scope without the client's override binding functions", function()
    TestEnv.SetGlobal("SetOverrideBindingClick", nil)
    TestEnv.expectErrorContaining("needs the client's override binding functions", function()
      BindingKit:CreateScope("MyAddon")
    end)
  end)
end)
