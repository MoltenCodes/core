local TestEnv = require("LifecycleKitTestEnv")

local SPEC_FILE = "packages/lifecycleKit/tests/SecretValues_spec.lua:"

---Assert that `callback` fails with `expected` at a line of this spec file,
---never inside LifecycleKit.
---@param expected string
---@param callback fun()
local function expectRefusalAtCaller(expected, callback)
  local ok, message = pcall(callback)
  message = tostring(message)
  assert.is_false(ok)
  assert.is_not_nil(string.find(message, expected, 1, true), message)
  assert.is_not_nil(string.find(message, SPEC_FILE, 1, true), message)
end

---Install an `issecretvalue` probe that reports exactly `secret` as secret.
---`TestEnv.Reset` clears the global again.
---@param secret any
local function installSecretProbe(secret)
  -- The package reads this host global at call time, so the spec installs it in the global table.
  -- selene: allow(global_usage)
  rawset(_G, "issecretvalue", function(value)
    return rawequal(value, secret)
  end)
end

describe("LifecycleKit secret values", function()
  local LifecycleKit
  before_each(function()
    LifecycleKit = TestEnv.NewPackage()
  end)
  after_each(TestEnv.Reset)

  it("names a secret CLOSES_ADDON_SCOPES key with a placeholder, never converting it", function()
    local secret = setmetatable({}, {
      __tostring = function()
        error("a secret was converted", 0)
      end,
    })
    installSecretProbe(secret)
    expectRefusalAtCaller(
      'LifecycleKit.CLOSES_ADDON_SCOPES is read-only; field "<secret>" cannot be written',
      function()
        LifecycleKit.CLOSES_ADDON_SCOPES[secret] = true
      end
    )
  end)

  it("refuses secret addon names and halt reasons before comparing them", function()
    local life = LifecycleKit:ForAddon("MyAddon")
    installSecretProbe("Secret")

    expectRefusalAtCaller("LifecycleKit:ForAddon addonName must not be a secret value", function()
      LifecycleKit:ForAddon("Secret")
    end)
    expectRefusalAtCaller(
      "LifecycleKit.Instance:DependsOn addonName must not be a secret value",
      function()
        life:DependsOn("Secret")
      end
    )
    expectRefusalAtCaller("LifecycleKit.Instance:Halt reason must not be a secret value", function()
      life:Halt("Secret")
    end)
    assert.is_false(life:IsHalted())
  end)

  it("refuses secret limits before comparing them", function()
    local life = LifecycleKit:ForAddon("MyAddon")
    local secret = {}
    installSecretProbe(secret)

    expectRefusalAtCaller(
      "LifecycleKit.Instance:SetCombatQueueLimit limit must not be a secret value",
      function()
        life:SetCombatQueueLimit(secret)
      end
    )
    expectRefusalAtCaller(
      "LifecycleKit:SetLimits limits.maxDependencies must not be a secret value",
      function()
        LifecycleKit:SetLimits({ maxDependencies = secret })
      end
    )
    assert.are_not.equal(secret, LifecycleKit:GetLimits().maxDependencies)
  end)

  it("refuses a secret receiver handed to a facade method with a dot call", function()
    installSecretProbe("MyAddon")

    expectRefusalAtCaller("must be called on the LifecycleKit facade", function()
      LifecycleKit.SetLimits("MyAddon")
    end)
    expectRefusalAtCaller("must be called on the LifecycleKit facade", function()
      LifecycleKit.GetLimits("MyAddon")
    end)
  end)

  it("accepts ordinary names and limits while the probe is installed", function()
    installSecretProbe({})

    local life = LifecycleKit:ForAddon("MyAddon")
    assert.is_true(life:DependsOn("OtherAddon"))
    life:SetCombatQueueLimit(8)
    assert.are.equal(8, life:GetCombatQueueLimit())
  end)

  it("uses the probe present at load without reading the global again", function()
    -- The module chain is loaded by hand so the probe exists before
    -- LifecycleKit's file runs, as it does in every client.
    TestEnv.Reset()
    TestEnv.InstallWowApi()
    local secret = {}
    -- selene: allow(global_usage)
    rawset(_G, "issecretvalue", function(value)
      return rawequal(value, secret)
    end)
    require("Registry")
    require("SignalKit")
    require("EventKit")
    LifecycleKit = require("LifecycleKit")
    -- A replacement installed after load is never consulted: the probe the
    -- client defined before any addon ran is the one LifecycleKit keeps.
    local consulted = false
    -- selene: allow(global_usage)
    rawset(_G, "issecretvalue", function()
      consulted = true
      return false
    end)

    expectRefusalAtCaller("LifecycleKit:ForAddon addonName must not be a secret value", function()
      LifecycleKit:ForAddon(secret)
    end)
    assert.is_false(consulted)
  end)

  it("ignores an issecretvalue global that is not a function", function()
    -- selene: allow(global_usage)
    rawset(_G, "issecretvalue", true)

    local life = LifecycleKit:ForAddon("MyAddon")
    assert.is_true(life:DependsOn("OtherAddon"))
  end)
end)
