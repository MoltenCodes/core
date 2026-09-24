local Env = require("CompatKitTestEnv")

---Install one global, as a spec that replaces the published namespace does.
---@param name string
---@param value any
local function setGlobal(name, value)
  -- selene: allow(global_usage)
  rawset(_G, name, value)
end

describe("CompatKit bootstrap", function()
  after_each(Env.Reset)

  it("publishes the facade through Registry", function()
    local CompatKit, Registry = Env.NewPackage()
    local registered, revision = Registry:Get("compatKit", 1)
    assert.are.equal(CompatKit, registered)
    assert.are.equal(1, CompatKit.API)
    assert.are.equal(2, CompatKit.REVISION)
    assert.are.equal(CompatKit.REVISION, revision)
  end)

  it("reuses the shared facade and state on a duplicate load", function()
    local CompatKit = Env.NewPackage()
    CompatKit:Shim("fix", 1, function() end)
    local state = CompatKit._state

    local reloaded = Env.ReloadPackage()
    assert.are.equal(CompatKit, reloaded)
    assert.are.equal(state, reloaded._state)
    assert.are.equal(1, #reloaded:GetShims())
  end)

  it("does not downgrade a newer compatible embedded revision", function()
    local CompatKit, Registry = Env.NewPackage()
    local shared = Registry:Register("compatKit", 1, 99)
    assert.are.equal(CompatKit, shared)
    rawset(shared, "REVISION", 99)
    rawset(shared, "_state", { schema = 999 })

    local reloaded = Env.ReloadPackage()
    assert.are.equal(shared, reloaded)
    assert.are.equal(99, reloaded.REVISION)
  end)

  it("upgrades in place and keeps shims, skips, providers, limits and the sentinel", function()
    local CompatKit = Env.NewPackage()
    local unbounded = CompatKit.UNBOUNDED
    local ran = {}
    CompatKit:Shim("applied", 1, function()
      ran[#ran + 1] = "applied"
    end)
    CompatKit:Shim("pending", 1, function()
      ran[#ran + 1] = "pending"
    end)
    CompatKit:SkipShim("pending")
    CompatKit:SkipShim("later")
    CompatKit:Apply()
    local registry = CompatKit:Providers("output")
    assert.is_true(registry:Register("chat", "chat-sink", nil, 5))
    CompatKit:SetLimits({ maxShims = 3, maxProviders = unbounded })
    local state = CompatKit._state
    local Shim = CompatKit.Shim
    local Resolve = registry.Resolve

    local nextRevision = CompatKit.REVISION + 1
    local upgraded = Env.LoadSourceAtRevision(nextRevision)
    assert.are.equal(CompatKit, upgraded)
    assert.are.equal(nextRevision, upgraded.REVISION)
    assert.are.equal(state, upgraded._state)
    assert.are.equal(unbounded, upgraded.UNBOUNDED)
    assert.are_not.equal(Shim, upgraded.Shim)
    -- The registry object is the same one and runs the new methods.
    assert.are.equal(registry, upgraded:Providers("output"))
    assert.are_not.equal(Resolve, registry.Resolve)
    assert.are.same({ "chat-sink", "chat" }, { registry:Resolve() })

    -- The applied shim does not run again; the skipped one stays skipped;
    -- a skip recorded before registration is honoured after the upgrade.
    upgraded:Shim("later", 1, function()
      ran[#ran + 1] = "later"
    end)
    assert.are.same({ 0, 2, 0 }, { upgraded:Apply() })
    assert.are.same({ "applied" }, ran)

    assert.are.same(
      { maxShims = 3, maxProviders = unbounded, maxProviderKinds = 32 },
      upgraded:GetLimits()
    )
    assert.are.equal(3, #upgraded:GetShims())
  end)

  it("takes over the previous revision's state in place", function()
    local shippedRevision = Env.NewPackage().REVISION
    Env.Reset()
    Env.InstallWowApi()
    require("Registry")
    local previous = Env.LoadSourceAtRevision(shippedRevision - 1)
    assert.are.equal(shippedRevision - 1, previous.REVISION)
    local state = previous._state
    local ran = {}
    previous:Shim("applied", 1, function()
      ran[#ran + 1] = "applied"
    end)
    previous:SkipShim("later")
    previous:Apply()
    local registry = previous:Providers("output")
    local answer = true
    assert.is_true(registry:Register("chat", "chat-sink", function()
      return answer
    end, 5))
    assert.is_true(registry:Register("print", "print-sink"))
    previous:SetLimits({ maxShims = 3 })

    local CompatKit = Env.ReloadPackage()
    assert.are.equal(previous, CompatKit)
    assert.are.equal(shippedRevision, CompatKit.REVISION)
    assert.are.equal(state, CompatKit._state)
    assert.are.equal(registry, CompatKit:Providers("output"))
    assert.are.same({ "chat-sink", "chat" }, { registry:Resolve() })
    assert.are.equal(3, CompatKit:GetLimits().maxShims)
    CompatKit:Shim("later", 1, function()
      ran[#ran + 1] = "later"
    end)
    assert.are.same({ 0, 1, 0 }, { CompatKit:Apply() })
    assert.are.same({ "applied" }, ran)

    -- The fix the shipped revision carries: a probe answering a secret
    -- counts as dead before the answer is compared.
    answer = {}
    Env.InstallSecretProbe(answer)
    assert.are.same({ "print-sink", "print" }, { registry:Resolve() })
  end)

  it("keeps the newest copy when an older one loads after an upgrade", function()
    local CompatKit = Env.NewPackage()
    local nextRevision = CompatKit.REVISION + 1
    Env.LoadSourceAtRevision(nextRevision)
    local selected = Env.ReloadPackage()
    assert.are.equal(CompatKit, selected)
    assert.are.equal(nextRevision, selected.REVISION)
  end)

  it("refuses to load before Registry", function()
    Env.Reset()
    Env.InstallWowApi()
    Env.expectErrorContaining(
      "MoltenCodes CompatKit requires Registry API 2 to be loaded first",
      function()
        Env.requireAfterFailedLoad("CompatKit")
      end
    )
  end)

  it("refuses a Registry facade without Bootstrap or Find", function()
    Env.Reset()
    setGlobal(Env.NAMESPACE_KEY, { Registries = { [2] = { API = 2 } } })
    Env.expectErrorContaining(
      "MoltenCodes CompatKit requires a valid Registry API 2 facade",
      function()
        Env.requireAfterFailedLoad("CompatKit")
      end
    )
  end)

  it("rejects same-revision state that lost its shim table", function()
    local CompatKit = Env.NewPackage()
    rawset(CompatKit._state, "shims", nil)
    assert.has_error(function()
      Env.ReloadPackage()
    end)
  end)

  it("rejects an upgrade over state with an unknown schema", function()
    local CompatKit = Env.NewPackage()
    rawset(CompatKit._state, "schema", 99)
    Env.expectErrorContaining(
      "MoltenCodes CompatKit package state is corrupted or incomplete",
      function()
        Env.LoadSourceAtRevision(2)
      end
    )
  end)

  it("rejects shared state whose limits hold an invalid value", function()
    local CompatKit = Env.NewPackage()
    rawset(CompatKit._state.limits, "maxShims", 0)
    Env.expectErrorContaining("package state is corrupted or incomplete", function()
      Env.ReloadPackage()
    end)
  end)

  it("finds Registry through the MoltenCodes.Registry alias alone", function()
    Env.Reset()
    Env.InstallWowApi()
    local Registry = require("Registry")
    -- The shared namespace is the one documented global handoff point.
    -- selene: allow(global_usage)
    rawset(rawget(_G, Env.NAMESPACE_KEY), "Registries", nil)
    local CompatKit = require("CompatKit")
    assert.are.equal(CompatKit, Registry:Get("compatKit", 1))
  end)

  it("rejects a shared table that lost a facade method", function()
    local CompatKit = Env.NewPackage()
    rawset(CompatKit, "GetLimits", nil)
    Env.expectErrorContaining(
      "MoltenCodes CompatKit package state is corrupted or incomplete",
      function()
        Env.ReloadPackage()
      end
    )
  end)

  it("rejects a shared table that lost its catalogue", function()
    local CompatKit = Env.NewPackage()
    rawset(CompatKit, "CATALOGUE", nil)
    Env.expectErrorContaining(
      "MoltenCodes CompatKit package state is corrupted or incomplete",
      function()
        Env.ReloadPackage()
      end
    )
  end)

  it("rejects shared state whose limits are not a table", function()
    local CompatKit = Env.NewPackage()
    rawset(CompatKit._state, "limits", nil)
    Env.expectErrorContaining("package state is corrupted or incomplete", function()
      Env.ReloadPackage()
    end)
  end)

  it("rejects an upgrade from a newer revision over state with an unknown schema", function()
    local CompatKit = Env.NewPackage()
    rawset(CompatKit._state, "schema", 99)
    Env.expectErrorContaining(
      "MoltenCodes CompatKit package state is corrupted or incomplete",
      function()
        Env.LoadSourceAtRevision(CompatKit.REVISION + 1)
      end
    )
  end)
end)
