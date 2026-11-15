local TestEnv = require("PanelKitTestEnv")

describe("PanelKit secret values", function()
  local PanelKit, settings, secret
  before_each(function()
    PanelKit, settings = TestEnv.NewPackage()
    TestEnv.InstallSecretProbe()
    secret = TestEnv.NewSecret()
  end)
  after_each(TestEnv.Reset)

  it("refuses a secret tree name, title, options table, option key or parent", function()
    local parent = PanelKit:Register("Parent")
    local cases = {
      { "treeName must not be a secret value", secret },
      { "options must be a table or nil", "MyAddon", secret },
      { "options.name must not be a secret value", "MyAddon", { name = secret } },
      { "options holds an unknown field", "MyAddon", { [secret] = true } },
      { "options.parent must be a PanelKit panel", "MyAddon", { parent = secret } },
    }
    for _, case in ipairs(cases) do
      TestEnv.expectErrorContaining("PanelKit:Register " .. case[1], function()
        PanelKit:Register(case[2], case[3])
      end)
    end
    assert.are.equal(1, #settings.categories)
    assert.are.equal(parent, PanelKit:Get("Parent"))
  end)

  it("refuses a secret name or parent in Get", function()
    TestEnv.expectErrorContaining("PanelKit:Get name must not be a secret value", function()
      PanelKit:Get(secret)
    end)
    TestEnv.expectErrorContaining("PanelKit:Get parent must be a PanelKit panel or nil", function()
      PanelKit:Get("Parent", secret)
    end)
  end)

  it("refuses secret limits, keys and values", function()
    TestEnv.expectErrorContaining("PanelKit:SetLimits limits must be a table", function()
      PanelKit:SetLimits(secret)
    end)
    TestEnv.expectErrorContaining("limits holds an unknown field", function()
      PanelKit:SetLimits({ [secret] = 8 })
    end)
    TestEnv.expectErrorContaining("limits.maxPanels must not be a secret value", function()
      PanelKit:SetLimits({ maxPanels = secret })
    end)
    assert.are.equal(64, PanelKit:GetLimits().maxPanels)
  end)

  it("treats a secret receiver as a call without a panel or the facade", function()
    local panel = PanelKit:Register("MyAddon")
    TestEnv.expectErrorContaining(
      "PanelKit.Panel:GetName must be called on a PanelKit panel",
      function()
        panel.GetName(secret)
      end
    )
    TestEnv.expectErrorContaining("must be called on the PanelKit facade", function()
      PanelKit.GetLimits(secret)
    end)
  end)
end)
