local Env = require("PoolKitTestEnv")

-- Revision 9 gives `Acquire` and `Release` a fast path for the common case
-- (a current, open, unguarded pool; no live limit or waiting request; a
-- retained object to hand out; a borrowed object to return) and reads the
-- pool by plain indexing. These specs pin that every guarantee the general
-- path documents still holds on and next to the fast path.

---Assert that `callback` raises an error whose message contains `expected`.
---@param expected string
---@param callback function
local function expectError(expected, callback)
  local ok, message = pcall(callback)
  assert.is_false(ok)
  assert.is_not_nil(
    string.find(tostring(message), expected, 1, true),
    "expected an error containing " .. expected .. ", got " .. tostring(message)
  )
end

describe("PoolKit fast paths", function()
  local PoolKit
  before_each(function()
    PoolKit = Env.NewPackage()
  end)
  after_each(Env.Reset)

  it("hands out the most recently retained object first", function()
    local pool = PoolKit:NewTablePool()
    local first, second = pool:Acquire(), pool:Acquire()
    pool:Release(first)
    pool:Release(second)

    assert.are.equal(second, pool:Acquire())
    assert.are.equal(first, pool:Acquire())
    assert.are.equal(2, pool:GetActiveCount())
    assert.are.equal(0, pool:GetAvailableCount())
    assert.are.equal(2, pool:GetCreatedCount())
  end)

  it("keeps ownership and counters exact through retained reuse", function()
    local pool = PoolKit:NewTablePool()
    local object = pool:Acquire()
    pool:Release(object)
    assert.is_true(pool:Owns(object))
    assert.is_false(pool:IsActive(object))

    assert.are.equal(object, pool:Acquire())
    assert.is_true(pool:IsActive(object))
    assert.are.equal(1, pool:GetActiveCount())
    assert.are.equal(0, pool:GetAvailableCount())
  end)

  it("refuses a second release of a retained object", function()
    local pool = PoolKit:NewTablePool()
    local object = pool:Acquire()
    assert.is_true(pool:Release(object))

    expectError("PoolKit.Pool:Release object has already been released", function()
      pool:Release(object)
    end)
    assert.are.equal(1, pool:GetAvailableCount())
  end)

  it("refuses a second release of a discarded object on a strict pool", function()
    local pool = PoolKit:NewTablePool({ maxRetained = 0 })
    local object = pool:Acquire()
    assert.is_true(pool:Release(object))
    assert.are.equal(1, pool:GetDiscardedCount())

    expectError("PoolKit.Pool:Release object has already been released", function()
      pool:Release(object)
    end)
  end)

  it("refuses an object another pool or nobody lent", function()
    local pool = PoolKit:NewTablePool()
    local other = PoolKit:NewTablePool()
    local foreign = other:Acquire()

    expectError("PoolKit.Pool:Release object was not acquired from this pool", function()
      pool:Release(foreign)
    end)
    expectError("PoolKit.Pool:Release object was not acquired from this pool", function()
      pool:Release({})
    end)
    expectError("PoolKit.Pool:Release object must be a table or userdata", function()
      pool:Release("text")
    end)
    assert.is_true(other:IsActive(foreign))
  end)

  it("refuses the wrong receiver on both methods", function()
    local pool = PoolKit:NewTablePool()
    local object = pool:Acquire()

    expectError("PoolKit.Pool:Acquire must be called on a PoolKit pool", function()
      pool.Acquire({})
    end)
    expectError("PoolKit.Pool:Release must be called on a PoolKit pool", function()
      pool.Release({}, object)
    end)
  end)

  it("refuses to reuse a closed pool and discards what it gets back", function()
    local destroyed = 0
    local pool = PoolKit:New({
      create = function()
        return {}
      end,
      destroy = function()
        destroyed = destroyed + 1
      end,
    })
    local object = pool:Acquire()
    pool:Release(pool:Acquire())
    pool:Close()

    expectError("PoolKit.Pool:Acquire cannot use a closed pool", function()
      pool:Acquire()
    end)
    assert.is_true(pool:Release(object))
    assert.are.equal(0, pool:GetAvailableCount())
    assert.is_true(destroyed >= 1)
    assert.is_false(pool:Owns(object))
  end)

  it("discards a released object once retention is full", function()
    local destroyed = {}
    local pool = PoolKit:New({
      create = function()
        return {}
      end,
      destroy = function(object)
        destroyed[#destroyed + 1] = object
      end,
      maxRetained = 1,
    })
    local first, second = pool:Acquire(), pool:Acquire()
    pool:Release(first)
    pool:Release(second)

    assert.are.equal(1, pool:GetAvailableCount())
    assert.are.same({ second }, destroyed)
  end)

  it("discards an object a newer generation superseded", function()
    local pool = PoolKit:NewTablePool()
    local object = pool:Acquire()
    pool:SetGeneration(2)
    pool:Release(object)

    assert.are.equal(0, pool:GetAvailableCount())
    assert.are.equal(1, pool:GetDiscardedCount())
    local fresh = pool:Acquire()
    assert.are_not.equal(object, fresh)
  end)

  it("still serves the waiting queue, and a newcomer never jumps it", function()
    local pool = PoolKit:New({
      create = function()
        return {}
      end,
      maxActive = 1,
      maxWaiting = 2,
    })
    local held = pool:Acquire()
    local delivered = {}
    local object, reason = pool:Acquire(function(waited)
      delivered[#delivered + 1] = waited
    end)
    assert.is_nil(object)
    assert.are.equal("waiting", reason)

    pool:Release(held)
    assert.are.same({ held }, delivered)
    assert.is_true(pool:IsActive(held))
    local refused, refusedReason = pool:Acquire()
    assert.is_nil(refused)
    assert.are.equal("exhausted", refusedReason)
  end)

  it("reports the leak threshold once on the fast path", function()
    Env.InstallHostErrorHandler()
    local pool = PoolKit:NewTablePool({ maxActiveWarning = 2 })
    local first = pool:Acquire()
    pool:Release(first)
    -- Both of these come from retention or the factory; the warning fires
    -- when the second is borrowed at the same time as the first.
    local a = pool:Acquire()
    local b = pool:Acquire()
    pool:Release(a)
    pool:Release(b)
    pool:Acquire()
    pool:Acquire()

    assert.are.equal(1, #Env.ReportedWarnings())
  end)

  it("refuses a release from inside the pool's own reset", function()
    local pool
    local refusal
    pool = PoolKit:New({
      create = function()
        return {}
      end,
      reset = function(object)
        local ok, message = pcall(pool.Release, pool, object)
        refusal = not ok and tostring(message) or nil
      end,
    })
    local object = pool:Acquire()
    assert.is_true(pool:Release(object))

    assert.is_not_nil(refusal)
    assert.is_not_nil(
      string.find(refusal, "cannot mutate this pool during its reset callback", 1, true)
    )
    assert.are.equal(1, pool:GetAvailableCount())
  end)

  it("rolls a failed reset back, restores the guard and reports the first error", function()
    local failing = true
    local pool = PoolKit:New({
      create = function()
        return {}
      end,
      reset = function()
        if failing then
          error("reset failed", 0)
        end
      end,
    })
    local object = pool:Acquire()

    local ok, message = pcall(pool.Release, pool, object)
    assert.is_false(ok)
    assert.are.equal("reset failed", message)
    assert.is_true(pool:IsActive(object))
    assert.are.equal(1, pool:GetActiveCount())
    assert.are.equal(0, rawget(pool, "_callbackDepth"))
    assert.are.equal(false, rawget(pool, "_callbackPhase"))

    failing = false
    assert.is_true(pool:Release(object))
    assert.are.equal(object, pool:Acquire())
  end)

  it("releases attached children before retaining the parent", function()
    local parents = PoolKit:NewTablePool()
    local children = PoolKit:NewTablePool()
    local parent, child = parents:Acquire(), children:Acquire()
    parents:AttachChild(parent, child, children)

    parents:Release(parent)
    assert.is_false(children:IsActive(child))
    assert.are.equal(1, children:GetAvailableCount())

    -- A child released on its own leaves its parent's list.
    local nextParent, nextChild = parents:Acquire(), children:Acquire()
    parents:AttachChild(nextParent, nextChild, children)
    children:Release(nextChild)
    assert.is_false(parents:DetachChild(nextChild))
    parents:Release(nextParent)
  end)
end)

describe("PoolKit table-pool reset", function()
  local PoolKit
  before_each(function()
    PoolKit = Env.NewPackage()
  end)
  after_each(Env.Reset)

  it("clears every field, array and hash, without consulting a metatable", function()
    local pool = PoolKit:NewTablePool()
    local object = pool:Acquire()
    local written = 0
    object[1], object[2], object.name, object[true] = "a", "b", "c", "d"
    setmetatable(object, {
      __newindex = function()
        written = written + 1
      end,
    })

    pool:Release(object)
    assert.is_nil(next(object))
    assert.are.equal(0, written)
    assert.are.equal(object, pool:Acquire())
  end)
end)
