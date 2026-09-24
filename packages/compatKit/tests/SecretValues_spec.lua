local Env = require("CompatKitTestEnv")

--- A stand-in for a secret value: `issecretvalue` reports this one table.
local SECRET = {}

describe("CompatKit secret values", function()
  local CompatKit

  before_each(function()
    CompatKit = Env.NewPackage()
    Env.InstallSecretProbe(SECRET)
  end)
  after_each(Env.Reset)

  it("refuses a secret shim name, version or option at the caller", function()
    local noop = function() end
    Env.expectErrorContaining("CompatKit:Shim name must not be a secret value", function()
      CompatKit:Shim(SECRET, 1, noop)
    end)
    Env.expectErrorContaining("CompatKit:Shim version must not be a secret value", function()
      CompatKit:Shim("fix", SECRET, noop)
    end)
    Env.expectErrorContaining("CompatKit:SkipShim name must not be a secret value", function()
      CompatKit:SkipShim(SECRET)
    end)
    Env.expectErrorContaining(
      "CompatKit:Shim options.description must not be a secret value",
      function()
        CompatKit:Shim("fix", 1, noop, { description = SECRET })
      end
    )
    Env.expectErrorContaining(
      "CompatKit:Shim options.flavours must not contain a secret value",
      function()
        CompatKit:Shim("fix", 1, noop, { flavours = { SECRET } })
      end
    )
    Env.expectErrorContaining(
      "CompatKit:Shim options.covers must not contain a secret value",
      function()
        CompatKit:Shim("fix", 1, noop, { covers = { SECRET } })
      end
    )
    Env.expectErrorContaining("CompatKit:Shim options must not have a secret key", function()
      CompatKit:Shim("fix", 1, noop, { [SECRET] = true })
    end)
    Env.expectErrorContaining("CompatKit:Shim options must not be a secret value", function()
      CompatKit:Shim("fix", 1, noop, SECRET)
    end)
    Env.expectErrorContaining(
      "CompatKit:Shim options.flavours must not be a secret value",
      function()
        CompatKit:Shim("fix", 1, noop, { flavours = SECRET })
      end
    )
    Env.expectErrorContaining("CompatKit:Shim options.covers must not be a secret value", function()
      CompatKit:Shim("fix", 1, noop, { covers = SECRET })
    end)
    assert.are.same({}, CompatKit:GetShims())
  end)

  it("refuses a secret provider kind, name, implementation or priority", function()
    Env.expectErrorContaining("CompatKit:Providers kind must not be a secret value", function()
      CompatKit:Providers(SECRET)
    end)
    local registry = CompatKit:Providers("output")
    Env.expectErrorContaining(
      "CompatKit.ProviderRegistry:Register name must not be a secret value",
      function()
        registry:Register(SECRET, "sink")
      end
    )
    Env.expectErrorContaining(
      "CompatKit.ProviderRegistry:Register implementation must not be a secret value",
      function()
        registry:Register("chat", SECRET)
      end
    )
    Env.expectErrorContaining(
      "CompatKit.ProviderRegistry:Register probe must not be a secret value",
      function()
        registry:Register("chat", "sink", SECRET)
      end
    )
    Env.expectErrorContaining(
      "CompatKit.ProviderRegistry:Register priority must not be a secret value",
      function()
        registry:Register("chat", "sink", nil, SECRET)
      end
    )
    Env.expectErrorContaining(
      "CompatKit.ProviderRegistry:Resolve preferred must not be a secret value",
      function()
        registry:Resolve(SECRET)
      end
    )
    Env.expectErrorContaining(
      "CompatKit.ProviderRegistry:Unregister name must not be a secret value",
      function()
        registry:Unregister(SECRET)
      end
    )
    assert.are.same({}, registry:List())
  end)

  it("refuses a secret name in the shim context helpers", function()
    local failures = {}
    CompatKit:Shim("probe", 1, function(context)
      local ok, message = pcall(context.hasGlobal, SECRET)
      failures[#failures + 1] = not ok and message or false
      ok, message = pcall(context.hasApi, SECRET)
      failures[#failures + 1] = not ok and message or false
    end)
    CompatKit:Apply()
    assert.is_truthy(
      failures[1]:find("CompatKit.ShimContext.hasGlobal name must not be a secret value", 1, true)
    )
    assert.is_truthy(
      failures[2]:find("CompatKit.ShimContext.hasApi name must not be a secret value", 1, true)
    )
  end)

  it("refuses a secret limit value or key at the caller", function()
    Env.expectErrorContaining(
      "CompatKit:SetLimits limits.maxShims must not be a secret value",
      function()
        CompatKit:SetLimits({ maxShims = SECRET })
      end
    )
    Env.expectErrorContaining("CompatKit:SetLimits limits must not have a secret key", function()
      CompatKit:SetLimits({ [SECRET] = 1 })
    end)
    assert.are.same(
      { maxShims = 64, maxProviders = 32, maxProviderKinds = 32 },
      CompatKit:GetLimits()
    )
  end)

  it("counts a probe answering a secret as dead, without comparing it", function()
    local registry = CompatKit:Providers("output")
    assert.is_true(registry:Register("secretive", "first", function()
      return SECRET
    end, 10))
    assert.is_true(registry:Register("plain", "second", function()
      return true
    end, 1))
    assert.are.same({ "second", "plain" }, { registry:Resolve() })
    assert.are.same({ "second", "plain" }, { registry:Resolve("secretive") })
  end)

  it("reports a secret global as present to hasGlobal, without comparing it", function()
    -- selene: allow(global_usage)
    rawset(_G, "CompatKitSpecSecretGlobal", SECRET)
    local present
    CompatKit:Shim("inspect", 1, function(context)
      present = context.hasGlobal("CompatKitSpecSecretGlobal")
    end)
    CompatKit:Apply()
    -- selene: allow(global_usage)
    rawset(_G, "CompatKitSpecSecretGlobal", nil)
    assert.is_true(present)
  end)

  it("reports a secret receiver as a facade misuse at the caller's line", function()
    local action = function()
      CompatKit.Apply(SECRET)
    end
    local ok, value = pcall(action)
    assert.is_false(ok)
    assert.are.equal(
      debug.getinfo(1, "S").short_src
        .. ":"
        .. debug.getinfo(action, "S").linedefined + 1
        .. ": CompatKit:Apply must be called on the CompatKit facade; use CompatKit:Apply(...)",
      value
    )
  end)

  it("accepts ordinary values while the probe is installed", function()
    assert.is_true(CompatKit:Shim("fix", 1, function() end, { description = "plain" }))
    assert.is_true(CompatKit:Providers("output"):Register("chat", "sink", nil, 1))
  end)
end)
