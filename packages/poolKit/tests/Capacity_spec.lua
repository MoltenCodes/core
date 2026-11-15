local Env = require("PoolKitTestEnv")

describe("PoolKit capacity", function()
  before_each(function()
    Env.Reset()
  end)
  after_each(function()
    Env.Reset()
  end)

  it("discards overflow and calls destroy", function()
    local PoolKit = Env.NewPackage()
    local destroyed = 0
    local pool = PoolKit:New({
      create = function()
        return {}
      end,
      destroy = function()
        destroyed = destroyed + 1
      end,
      maxRetained = 1,
    })
    local a, b = pool:Acquire(), pool:Acquire()
    pool:Release(a)
    pool:Release(b)
    assert.are.equal(1, pool:GetAvailableCount())
    assert.are.equal(1, pool:GetDiscardedCount())
    assert.are.equal(1, destroyed)
  end)

  it("supports an explicit unbounded retention escape hatch", function()
    local PoolKit = Env.NewPackage()
    local pool = PoolKit:New({
      create = function()
        return {}
      end,
      maxRetained = PoolKit.UNBOUNDED,
    })
    local values = {}
    for i = 1, 300 do
      values[i] = pool:Acquire()
    end
    for i = 1, 300 do
      pool:Release(values[i])
    end
    assert.are.equal(300, pool:GetAvailableCount())
    assert.are.equal(PoolKit.UNBOUNDED, pool:GetMaxRetained())
  end)

  it("prewarms to a target and is idempotent", function()
    local PoolKit = Env.NewPackage()
    local pool = PoolKit:New({
      create = function()
        return {}
      end,
      maxRetained = 8,
    })
    assert.are.equal(4, pool:Prewarm(4))
    assert.are.equal(0, pool:Prewarm(4))
    assert.are.equal(4, pool:GetAvailableCount())
    assert.are.equal(4, pool:GetCreatedCount())
    assert.has_error(function()
      pool:Prewarm(9)
    end)
  end)

  it("keeps the objects a Prewarm built before its factory raised", function()
    local PoolKit = Env.NewPackage()
    local calls = 0
    local built = {}
    local pool = PoolKit:New({
      create = function()
        calls = calls + 1
        if calls == 3 then
          error("factory failed", 0)
        end
        local object = { id = calls }
        built[#built + 1] = object
        return object
      end,
      maxCreated = 4,
    })
    assert.has_error(function()
      pool:Prewarm(4)
    end, "factory failed")
    assert.are.equal(2, pool:GetAvailableCount())
    assert.are.equal(2, pool:GetCreatedCount())
    -- The two objects built before the failure are handed out, not rebuilt.
    local first, second = pool:Acquire(), pool:Acquire()
    assert.are.equal(built[2], first)
    assert.are.equal(built[1], second)
  end)

  it("trims immediately when maxRetained is lowered", function()
    local PoolKit = Env.NewPackage()
    local pool = PoolKit:New({
      create = function()
        return {}
      end,
      prewarm = 5,
      maxRetained = 5,
    })
    pool:SetMaxRetained(2)
    assert.are.equal(2, pool:GetAvailableCount())
    assert.are.equal(3, pool:GetDiscardedCount())
    assert.are.equal(pool, pool:SetMaxRetained(PoolKit.UNBOUNDED))
  end)
end)
