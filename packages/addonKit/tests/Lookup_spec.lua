local TestEnv = require("AddonKitTestEnv")

describe("AddonKit lookup", function()
  after_each(TestEnv.Reset)

  ---A fresh package with SignalKit loaded and a facade for MyAddon.
  ---@return MoltenCodesFacade
  ---@return table AddonKit
  local function newFacade()
    local AddonKit = TestEnv.NewPackage()
    TestEnv.LoadKits({ "SignalKit" })
    return TestEnv.Namespace():For("MyAddon"), AddonKit
  end

  it("answers one facade per addon, shared by every file", function()
    local MC = newFacade()
    assert.are.equal(MC, TestEnv.Namespace():For("MyAddon", {}))
    assert.are_not.equal(MC, TestEnv.Namespace():For("OtherAddon"))
    assert.are.equal("MyAddon", MC.addonName)
    assert.are.equal("AddonKit.Facade", getmetatable(MC))
  end)

  it("resolves a Kit on the first read and caches it on the facade", function()
    local MC = newFacade()
    assert.is_nil(rawget(MC, "SignalKit"))
    local SignalKit = MC.SignalKit
    assert.are.equal(TestEnv.Namespace().Registries[2]:Get("signalKit", 1), SignalKit)
    assert.are.equal(SignalKit, rawget(MC, "SignalKit"))
  end)

  it("answers MC.S as SchemaKit and MC.Registry as Registry API 2", function()
    local MC = newFacade()
    TestEnv.LoadKits({ "SchemaKit" })
    assert.are.equal(MC.SchemaKit, MC.S)
    assert.are.equal(TestEnv.Namespace().Registries[2], MC.Registry)
  end)

  it("names the file to embed when a Kit is not loaded", function()
    local MC = newFacade()
    local message = TestEnv.ErrorOf(function()
      return MC.TimerKit
    end)
    assert.is_truthy(
      string.find(
        message,
        "MyAddon uses MoltenCodes TimerKit (API 1), which is not loaded",
        1,
        true
      )
    )
    assert.is_truthy(string.find(message, "Add timerKit\\TimerKit.lua to embeds.xml", 1, true))
    assert.is_nil(rawget(MC, "TimerKit"))
  end)

  it("explains a generation that is not loaded", function()
    local MC = newFacade()
    MC:Use("SignalKit", 2)
    local message = TestEnv.ErrorOf(function()
      return MC.SignalKit
    end)
    assert.is_truthy(
      string.find(message, "MyAddon uses MoltenCodes SignalKit API 2, but only another", 1, true)
    )
  end)

  it("suggests the closest name for a misspelt Kit or helper", function()
    local MC = newFacade()
    local cases = {
      { "Timerkit", "did you mean MC.TimerKit?" },
      { "Signal", "did you mean MC.SignalKit?" },
      { "timerKit", "did you mean MC.TimerKit?" },
      { "NewAdon", "did you mean MC:NewAddon?" },
      { "Databse", "did you mean MC:Database?" },
      { "LAUNCHER_DEFAULT", "did you mean MC.LAUNCHER_DEFAULTS?" },
    }
    for _, case in ipairs(cases) do
      local message = TestEnv.ErrorOf(function()
        return MC[case[1]]
      end)
      assert.is_truthy(
        string.find(message, "MoltenCodes has no Kit or helper named " .. case[1], 1, true)
      )
      assert.is_truthy(string.find(message, case[2], 1, true), message)
    end
    local message = TestEnv.ErrorOf(function()
      return MC.Zzzzzzzz
    end)
    assert.is_nil(string.find(message, "did you mean", 1, true))
  end)

  it("names the part to embed for a part member", function()
    local MC = newFacade()
    local message = TestEnv.ErrorOf(function()
      return MC.Database
    end)
    assert.is_truthy(
      string.find(
        message,
        "MC:Database is in AddonKit's Database part, which is not loaded",
        1,
        true
      )
    )
    assert.is_truthy(string.find(message, "addonKit\\parts\\AddonKit-Database.lua", 1, true))
    message = TestEnv.ErrorOf(function()
      return MC.LAUNCHER_DEFAULTS
    end)
    assert.is_truthy(
      string.find(message, "MC.LAUNCHER_DEFAULTS is in AddonKit's Composition part", 1, true)
    )
  end)

  it("pins a generation with Use before the first read only", function()
    local MC = newFacade()
    MC:Use("SignalKit", 1)
    local SignalKit = MC.SignalKit
    MC:Use("SignalKit", 1)
    assert.are.equal(SignalKit, MC.SignalKit)
    local message = TestEnv.ErrorOf(function()
      MC:Use("SignalKit", 2)
    end)
    assert.is_truthy(string.find(message, "MC:Use SignalKit was already read at API 1", 1, true))
    TestEnv.LoadKits({ "SchemaKit" })
    local _ = MC.S
    message = TestEnv.ErrorOf(function()
      MC:Use("SchemaKit", 3)
    end)
    assert.is_truthy(string.find(message, "call MC:Use before the first read of MC.S", 1, true))
  end)

  it("holds facades to maxFacades", function()
    local _, AddonKit = newFacade()
    assert.are.same({ maxFacades = 256 }, AddonKit:GetLimits())
    AddonKit:SetLimits({})
    AddonKit:SetLimits({ maxFacades = 2 })
    TestEnv.Namespace():For("Second")
    local message = TestEnv.ErrorOf(function()
      TestEnv.Namespace():For("Third")
    end)
    assert.is_truthy(
      string.find(message, "holds at most 2 addon facades; raise maxFacades", 1, true)
    )
    assert.is_table(TestEnv.Namespace():For("MyAddon"))
  end)
end)
