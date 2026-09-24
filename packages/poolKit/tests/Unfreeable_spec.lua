local Env = require("PoolKitTestEnv")

---Measures the allocation a workload causes, in kilobytes, with the collector
---stopped so that a collection cycle cannot hide or invent growth.
local function allocatedKilobytes(workload)
  collectgarbage()
  collectgarbage("stop")
  local before = collectgarbage("count")
  workload()
  local after = collectgarbage("count")
  collectgarbage("restart")
  return after - before
end

---Assert that `callback` fails with `expected` at a line of this spec file.
local function expectErrorAtThisSpec(expected, callback)
  local ok, message = pcall(callback)
  message = tostring(message)
  assert.is_false(ok)
  assert.is_not_nil(string.find(message, expected, 1, true))
  assert.is_not_nil(string.find(message, "packages/poolKit/tests/Unfreeable_spec.lua:", 1, true))
end

---A pool of stand-in "Frames": objects the host could never free.
local function newFramePool(PoolKit, options)
  options.create = function()
    return { kind = "frame" }
  end
  local pool = PoolKit:New(options)
  return pool
end

describe("PoolKit pools for objects that can never be freed", function()
  local PoolKit
  before_each(function()
    PoolKit = Env.NewPackage()
  end)
  after_each(Env.Reset)

  describe("creation cap", function()
    it("never builds more than maxCreated objects and refuses with a reason", function()
      local pool = newFramePool(PoolKit, { maxCreated = 2 })
      local first = pool:Acquire()
      local second = pool:Acquire()

      local third, reason = pool:Acquire()

      assert.is_nil(third)
      assert.are.equal("exhausted", reason)
      assert.are.equal(2, pool:GetCreatedCount())

      pool:Release(first)
      assert.are.equal(first, pool:Acquire())
      assert.are.equal(2, pool:GetCreatedCount())
      assert.is_not_nil(second)
    end)

    it("retains everything it may create unless told otherwise", function()
      local pool = newFramePool(PoolKit, { maxCreated = 300 })

      assert.are.equal(300, pool:GetMaxRetained())
    end)

    it("bounds prewarming by the cap at the caller's line", function()
      -- The default retention bound equals the cap, so it refuses first.
      expectErrorAtThisSpec("PoolKit:New prewarm cannot exceed maxRetained", function()
        newFramePool(PoolKit, { maxCreated = 2, prewarm = 3 })
      end)
      expectErrorAtThisSpec("PoolKit:New prewarm cannot exceed maxCreated", function()
        newFramePool(PoolKit, { maxCreated = 2, maxRetained = PoolKit.UNBOUNDED, prewarm = 3 })
      end)

      local pool = newFramePool(PoolKit, { maxCreated = 2 })
      pool:Acquire()
      expectErrorAtThisSpec("PoolKit.Pool:Prewarm target cannot exceed maxCreated", function()
        pool:Prewarm(2)
      end)
      assert.are.equal(1, pool:Prewarm(1))
      assert.are.equal(2, pool:GetCreatedCount())
    end)

    it("rejects invalid capacity options at the caller's line", function()
      expectErrorAtThisSpec("PoolKit:New maxCreated must be a positive integer", function()
        newFramePool(PoolKit, { maxCreated = 0 })
      end)
      expectErrorAtThisSpec("PoolKit:New maxActive must be a positive integer", function()
        newFramePool(PoolKit, { maxActive = -1 })
      end)
      expectErrorAtThisSpec("PoolKit:New maxWaiting must be a non-negative integer", function()
        newFramePool(PoolKit, { maxActive = 1, maxWaiting = 0.5 })
      end)
      expectErrorAtThisSpec("PoolKit:New maxWaiting requires maxCreated or maxActive", function()
        newFramePool(PoolKit, { maxWaiting = 4 })
      end)
      expectErrorAtThisSpec("PoolKit.Pool:Acquire onAvailable must be a function", function()
        newFramePool(PoolKit, { maxActive = 1 }):Acquire("later")
      end)
    end)
  end)

  describe("raising the creation cap", function()
    it("recovers a capped pool that a generation raise exhausted", function()
      local pool = newFramePool(PoolKit, { maxCreated = 2 })
      local first, second = pool:Acquire(), pool:Acquire()
      pool:Release(first)
      pool:Release(second)

      -- Retired stale objects still count: the host still holds them.
      assert.are.equal(2, pool:SetGeneration(2))
      assert.are.same({ nil, "exhausted" }, { pool:Acquire() })

      assert.are.equal(pool, pool:SetMaxCreated(4))
      assert.are.equal(4, pool:GetMaxCreated())
      assert.are.equal(4, pool:GetMaxRetained())
      assert.is_table(pool:Acquire())
      assert.is_table(pool:Acquire())
      assert.are.same({ nil, "exhausted" }, { pool:Acquire() })
    end)

    it("serves waiting requests from the new room at once", function()
      local pool = newFramePool(PoolKit, { maxCreated = 1, maxWaiting = 1 })
      pool:Acquire()
      local delivered = nil
      pool:Acquire(function(object)
        delivered = object
      end)

      pool:SetMaxCreated(2)

      assert.is_table(delivered)
      assert.are.equal(0, pool:GetWaitingCount())
    end)

    it("keeps an explicit retention bound that differs from the cap", function()
      local pool = newFramePool(PoolKit, { maxCreated = 2, maxRetained = 1 })
      pool:SetMaxCreated(5)

      assert.are.equal(1, pool:GetMaxRetained())
    end)

    it("only raises the cap, at the caller's line otherwise", function()
      local capped = newFramePool(PoolKit, { maxCreated = 3 })
      local uncapped = newFramePool(PoolKit, {})

      expectErrorAtThisSpec("cannot lower the cap from 3 to 2", function()
        capped:SetMaxCreated(2)
      end)
      expectErrorAtThisSpec("cannot cap a pool that was built without maxCreated", function()
        uncapped:SetMaxCreated(10)
      end)
      expectErrorAtThisSpec(
        "PoolKit.Pool:SetMaxCreated maxCreated must be a positive integer",
        function()
          capped:SetMaxCreated(0)
        end
      )
      assert.is_false(uncapped:GetMaxCreated())
      assert.are.equal(capped, capped:SetMaxCreated(3))
    end)
  end)

  describe("live limit", function()
    it("limits how many objects are borrowed at once", function()
      local pool = newFramePool(PoolKit, { maxActive = 1 })
      local first = pool:Acquire()

      local refused, reason = pool:Acquire()
      assert.is_nil(refused)
      assert.are.equal("exhausted", reason)

      pool:Release(first)
      assert.are.equal(first, pool:Acquire())
    end)

    it("hands a freed object to the oldest waiting request first", function()
      local pool = newFramePool(PoolKit, { maxActive = 1, maxWaiting = 2 })
      local holder = pool:Acquire()
      local deliveries = {}

      local function firstWaiter(object, owner)
        deliveries[#deliveries + 1] = { "first", object, owner }
      end
      local function secondWaiter(object, owner)
        deliveries[#deliveries + 1] = { "second", object, owner }
      end

      assert.are.same({ nil, "waiting" }, { pool:Acquire(firstWaiter) })
      assert.are.same({ nil, "waiting" }, { pool:Acquire(secondWaiter) })
      assert.are.equal(2, pool:GetWaitingCount())

      pool:Release(holder)
      assert.are.equal(1, #deliveries)
      assert.are.equal("first", deliveries[1][1])
      assert.are.equal(holder, deliveries[1][2])
      assert.are.equal(pool, deliveries[1][3])
      assert.is_true(pool:IsActive(holder))
      assert.are.equal(1, pool:GetWaitingCount())

      pool:Release(holder)
      assert.are.equal("second", deliveries[2][1])
      assert.are.equal(0, pool:GetWaitingCount())
    end)

    it("returns an object at once when there is capacity, ignoring the callback", function()
      local pool = newFramePool(PoolKit, { maxActive = 2, maxWaiting = 1 })
      local called = false

      local object, reason = pool:Acquire(function()
        called = true
      end)

      assert.is_table(object)
      assert.is_nil(reason)
      assert.is_false(called)
    end)

    it("refuses with queueFull instead of growing the queue", function()
      local pool = newFramePool(PoolKit, { maxActive = 1, maxWaiting = 1 })
      pool:Acquire()
      local function waiter() end

      assert.are.same({ nil, "waiting" }, { pool:Acquire(waiter) })
      assert.are.same({ nil, "queueFull" }, { pool:Acquire(waiter) })
      assert.are.equal(1, pool:GetWaitingCount())
    end)

    it("refuses a callback with queueFull when the pool has no queue", function()
      local pool = newFramePool(PoolKit, { maxActive = 1 })
      pool:Acquire()

      assert.are.same({ nil, "queueFull" }, { pool:Acquire(function() end) })
      assert.are.equal(0, pool:GetWaitingCount())
    end)

    it("withdraws a waiting request and keeps the others in order", function()
      local pool = newFramePool(PoolKit, { maxActive = 1, maxWaiting = 3 })
      local holder = pool:Acquire()
      local order = {}
      local function waiterA()
        order[#order + 1] = "A"
      end
      local function waiterB()
        order[#order + 1] = "B"
      end
      local function waiterC()
        order[#order + 1] = "C"
      end
      pool:Acquire(waiterA)
      pool:Acquire(waiterB)
      pool:Acquire(waiterC)

      assert.is_true(pool:CancelWaiting(waiterB))
      assert.is_false(pool:CancelWaiting(waiterB))
      assert.are.equal(2, pool:GetWaitingCount())

      pool:Release(holder)
      pool:Release(holder)
      assert.are.same({ "A", "C" }, order)
    end)

    it("keeps FIFO order after the ring wraps around", function()
      local pool = newFramePool(PoolKit, { maxActive = 1, maxWaiting = 2 })
      local holder = pool:Acquire()
      local order = {}
      local function waiter(label)
        return function(object)
          order[#order + 1] = label
          holder = object
        end
      end

      for round = 1, 5 do
        pool:Acquire(waiter("round" .. round))
        pool:Release(holder)
      end

      assert.are.same({ "round1", "round2", "round3", "round4", "round5" }, order)
    end)

    it("fails waiting requests with a reason when the pool closes", function()
      local pool = newFramePool(PoolKit, { maxActive = 1, maxWaiting = 2 })
      pool:Acquire()
      local received = {}
      pool:Acquire(function(object, owner, reason)
        received[#received + 1] = { object == nil, owner, reason }
      end)

      pool:Close()

      assert.are.equal(1, #received)
      assert.is_true(received[1][1])
      assert.are.equal(pool, received[1][2])
      assert.are.equal("closed", received[1][3])
      assert.are.equal(0, pool:GetWaitingCount())
    end)

    it("reports a waiting callback that raises and leaves it the object", function()
      Env.InstallHostErrorHandler()
      local pool = newFramePool(PoolKit, { maxActive = 1, maxWaiting = 1 })
      local holder = pool:Acquire()
      pool:Acquire(function()
        error("waiter failed")
      end)

      assert.is_true(pool:Release(holder))

      local reported = Env.ReportedWarnings()
      assert.are.equal(1, #reported)
      assert.is_not_nil(string.find(tostring(reported[1]), "waiter failed", 1, true))
      assert.is_true(pool:IsActive(holder))
    end)

    it("keeps a request queued when the factory fails during hand-off", function()
      Env.InstallHostErrorHandler()
      local builds = 0
      local pool = PoolKit:New({
        create = function()
          builds = builds + 1
          if builds == 2 then
            error("factory failed")
          end
          return {}
        end,
        maxActive = 1,
        maxRetained = 0,
        maxWaiting = 1,
      })
      local holder = pool:Acquire()
      local delivered = nil
      pool:Acquire(function(object)
        delivered = object
      end)

      pool:Release(holder)
      assert.is_nil(delivered)
      assert.are.equal(1, pool:GetWaitingCount())
      assert.are.equal(1, #Env.ReportedWarnings())

      -- The next acquire attempt serves the queue before anyone else.
      local refused, reason = pool:Acquire()
      assert.is_nil(refused)
      assert.are.equal("exhausted", reason)
      assert.is_table(delivered)
      assert.are.equal(0, pool:GetWaitingCount())
    end)

    it("allocates nothing per acquire while requests wait and are served #allocation", function()
      local pool = newFramePool(PoolKit, { maxActive = 1, maxWaiting = 1 })
      local holder = pool:Acquire()
      local function waiter(object)
        holder = object
      end

      local allocated = allocatedKilobytes(function()
        for _ = 1, 20000 do
          pool:Acquire(waiter)
          pool:Release(holder)
        end
      end)

      assert.are.equal(1, pool:GetCreatedCount())
      assert.is_true(allocated < 4, "queue traffic allocated " .. allocated .. " KiB")
    end)
  end)
end)
