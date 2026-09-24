local Env = require("InteropKitTestEnv")

--- A stand-in for a secret value: `issecretvalue` reports this one table.
local SECRET = {}

describe("InteropKit secret values", function()
  local InteropKit

  before_each(function()
    InteropKit = Env.NewPackage()
    Env.InstallLibStub()
    Env.InstallSecretProbe(function(value)
      return rawequal(value, SECRET)
    end)
  end)
  after_each(function()
    Env.Reset()
  end)

  it("refuses a secret major at the caller", function()
    Env.expectErrorContaining(
      "InteropKit:ExposeToLibStub major must not be a secret value",
      function()
        InteropKit:ExposeToLibStub("interopKit", 1, SECRET)
      end
    )
    Env.expectErrorContaining(
      "InteropKit:AdoptFromLibStub major must not be a secret value",
      function()
        InteropKit:AdoptFromLibStub(SECRET)
      end
    )
    Env.expectErrorContaining("InteropKit:Find major must not be a secret value", function()
      InteropKit:Find(SECRET)
    end)
  end)

  it("refuses a secret package name at the caller", function()
    Env.expectErrorContaining(
      "InteropKit:ExposeToLibStub packageName must not be a secret value",
      function()
        InteropKit:ExposeToLibStub(SECRET, 1)
      end
    )
  end)

  it("refuses a secret api at the caller", function()
    Env.expectErrorContaining(
      "InteropKit:ExposeToLibStub api must not be a secret value",
      function()
        InteropKit:ExposeToLibStub("interopKit", SECRET)
      end
    )
  end)

  it("refuses a secret package name in options.except at the caller", function()
    Env.expectErrorContaining(
      "InteropKit:ExposeAll packageName must not be a secret value",
      function()
        InteropKit:ExposeAll({ except = { SECRET } })
      end
    )
  end)

  it("accepts ordinary names while the probe is installed", function()
    assert.is_true(InteropKit:ExposeToLibStub("interopKit", 1))
  end)
end)
