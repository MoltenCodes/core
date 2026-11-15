local TestEnv = require("LauncherKitTestEnv")

describe("LauncherKit secret values", function()
  local LauncherKit, BrokerKit, secret
  before_each(function()
    LauncherKit, BrokerKit = TestEnv.NewPackage()
    TestEnv.InstallSecretProbe()
    secret = TestEnv.NewSecret()
    BrokerKit:New("MyAddon")
  end)
  after_each(TestEnv.Reset)

  it("refuses a secret object name, storage, limits and receiver", function()
    TestEnv.expectErrorContaining(
      "LauncherKit:Register objectName must not be a secret value",
      function()
        LauncherKit:Register(secret, {})
      end
    )
    TestEnv.expectErrorContaining("LauncherKit:Register storage must be a table", function()
      LauncherKit:Register("MyAddon", secret)
    end)
    TestEnv.expectErrorContaining(
      "LauncherKit:Get objectName must not be a secret value",
      function()
        LauncherKit:Get(secret)
      end
    )
    TestEnv.expectErrorContaining(
      "LauncherKit:AddToCompartment objectName must not be a secret value",
      function()
        LauncherKit:AddToCompartment(secret)
      end
    )
    TestEnv.expectErrorContaining("LauncherKit:SetLimits limits must be a table", function()
      LauncherKit:SetLimits(secret)
    end)
    TestEnv.expectErrorContaining("limits holds an unknown field", function()
      LauncherKit:SetLimits({ [secret] = 1 })
    end)
    TestEnv.expectErrorContaining("limits.maxLaunchers must not be a secret value", function()
      LauncherKit:SetLimits({ maxLaunchers = secret })
    end)
    local launcher = LauncherKit:Register("MyAddon", {})
    TestEnv.expectErrorContaining("must be called on a LauncherKit launcher", function()
      launcher.Show(secret)
    end)
    TestEnv.expectErrorContaining("must be called on the LauncherKit facade", function()
      LauncherKit.GetLimits(secret)
    end)
  end)

  it(
    "reads a secret saved field as absent, and a storage function's secret answer as no table",
    function()
      TestEnv.InstallHostErrorHandler()
      local launcher = LauncherKit:Register("MyAddon", { minimapPos = secret, hide = secret })
      assert.is_true(launcher:IsShown())
      local x = TestEnv.Offset(launcher:GetButton())
      assert.is_true(x < 0)
      BrokerKit:New("Other")
      LauncherKit:Register("Other", function()
        return secret
      end)
      local reported = TestEnv.TakeReportedValues()
      assert.are.same({ "LauncherKit storage for Other must return a table" }, reported)
    end
  )

  it("ignores a secret cursor position while dragging", function()
    local storage = {}
    local button = LauncherKit:Register("MyAddon", storage):GetButton()
    TestEnv.SetGlobal("GetCursorPosition", function()
      return secret, secret
    end)
    TestEnv.Run(button, "OnDragStart")
    TestEnv.Run(button, "OnUpdate", 0.016)
    TestEnv.Run(button, "OnDragStop")
    assert.is_nil(storage.minimapPos)
  end)
end)
