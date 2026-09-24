local Env = require("PoolKitTestEnv")

describe("PoolKit error semantics", function()
  before_each(function()
    Env.Reset()
  end)
  after_each(function()
    Env.Reset()
  end)

  it("preserves arbitrary reset error objects", function()
    local PoolKit = Env.NewPackage()
    local marker = {}
    local pool = PoolKit:New({
      create = function()
        return {}
      end,
      reset = function()
        error(marker, 0)
      end,
    })
    local object = pool:Acquire()
    local ok, value = pcall(function()
      pool:Release(object)
    end)
    assert.is_false(ok)
    assert.are.equal(marker, value)
    assert.is_true(pool:IsActive(object))
  end)

  it("finalizes discard state before propagating destroy errors", function()
    local PoolKit = Env.NewPackage()
    local marker = {}
    local pool = PoolKit:New({
      create = function()
        return {}
      end,
      maxRetained = 0,
      destroy = function()
        error(marker, 0)
      end,
    })
    local object = pool:Acquire()
    local ok, value = pcall(function()
      pool:Release(object)
    end)
    assert.is_false(ok)
    assert.are.equal(marker, value)
    assert.are.equal(0, pool:GetActiveCount())
    assert.are.equal(1, pool:GetDiscardedCount())
    assert.is_false(pool:Owns(object))
  end)
  it("keeps the outer guard intact across nested lifecycle callbacks", function()
    local PoolKit = Env.NewPackage()
    local inner
    local outer
    local observed = {}

    inner = PoolKit:New({
      create = function()
        return {}
      end,
      maxRetained = 0,
      destroy = function()
        -- Runs while the outer pool is inside its own destroy
        -- callback. When the guard is restored rather than cleared,
        -- the outer pool still refuses mutation and still names the
        -- phase the caller is actually inside.
        local ok, value = pcall(function()
          outer:Acquire()
        end)
        observed.duringInner = ok
        observed.messageDuringInner = tostring(value)
      end,
    })

    outer = PoolKit:New({
      create = function()
        return {}
      end,
      maxRetained = 0,
      destroy = function()
        inner:Release(inner:Acquire())

        local ok, value = pcall(function()
          outer:Clear()
        end)
        observed.afterInner = ok
        observed.messageAfterInner = tostring(value)
      end,
    })

    outer:Release(outer:Acquire())

    assert.is_false(observed.duringInner)
    assert.is_true(observed.messageDuringInner:find("during its destroy callback", 1, true) ~= nil)
    assert.is_false(observed.afterInner)
    assert.is_true(observed.messageAfterInner:find("during its destroy callback", 1, true) ~= nil)

    -- Both guards are released once their callbacks return.
    assert.is_not_nil(outer:Acquire())
    assert.is_not_nil(inner:Acquire())
  end)

  it("restores the guard after a lifecycle callback raises", function()
    local PoolKit = Env.NewPackage()
    local pool = PoolKit:New({
      create = function()
        return {}
      end,
      reset = function()
        error("reset failed", 0)
      end,
    })

    local object = pool:Acquire()
    assert.has_error(function()
      pool:Release(object)
    end)

    -- A failed callback must not leave the pool permanently locked.
    assert.is_not_nil(pool:Acquire())
    assert.are.equal(2, pool:GetActiveCount())
  end)

  it("rejects same-pool mutation from lifecycle callbacks without corrupting state", function()
    local PoolKit = Env.NewPackage()
    local pool
    pool = PoolKit:New({
      create = function(owner)
        assert.are.equal(pool, owner)
        assert.has_error(function()
          owner:Prewarm(1)
        end)
        return {}
      end,
      reset = function(_, owner)
        assert.has_error(function()
          owner:Clear()
        end)
      end,
    })
    local object = pool:Acquire()
    pool:Release(object)
    assert.are.equal(0, pool:GetActiveCount())
    assert.are.equal(1, pool:GetAvailableCount())
  end)
end)
