local Env = require("PoolKitTestEnv")

describe("PoolKit", function()
  before_each(function()
    Env.Reset()
  end)
  after_each(function()
    Env.Reset()
  end)

  it("reuses released objects and resets before retention", function()
    local PoolKit = Env.NewPackage()
    local resetCount = 0
    local pool = PoolKit:New({
      create = function()
        return {}
      end,
      reset = function(object)
        resetCount = resetCount + 1
        object.value = nil
      end,
    })
    local first = pool:Acquire()
    first.value = 42
    assert.is_true(pool:Release(first))
    assert.are.equal(1, resetCount)
    local second = pool:Acquire()
    assert.are.equal(first, second)
    assert.is_nil(second.value)
    assert.are.equal(1, pool:GetCreatedCount())
  end)

  it("provides a shallow-clearing table pool", function()
    local PoolKit = Env.NewPackage()
    local pool = PoolKit:NewTablePool()
    local value = pool:Acquire()
    local mt = {}
    setmetatable(value, mt)
    value.a = 1
    value.nested = { keep = true }
    local nested = value.nested
    pool:Release(value)
    local reused = pool:Acquire()
    assert.are.equal(value, reused)
    assert.is_nil(next(reused))
    assert.are.equal(mt, getmetatable(reused))
    assert.is_true(nested.keep)
  end)

  it("rejects unknown options and invalid factory results", function()
    local PoolKit = Env.NewPackage()
    assert.has_error(function()
      PoolKit:New({
        create = function()
          return {}
        end,
        typo = true,
      })
    end)
    local pool = PoolKit:New({
      create = function()
        return 7
      end,
    })
    assert.has_error(function()
      pool:Acquire()
    end)
    assert.are.equal(0, pool:GetCreatedCount())
    assert.are.equal(0, pool:GetActiveCount())
  end)

  it("uses bounded retention by default", function()
    local PoolKit = Env.NewPackage()
    local pool = PoolKit:New({
      create = function()
        return {}
      end,
    })
    assert.are.equal(128, PoolKit.DEFAULT_MAX_RETAINED)
    assert.are.equal(PoolKit.DEFAULT_MAX_RETAINED, pool:GetMaxRetained())
  end)
end)
