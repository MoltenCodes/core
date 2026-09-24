local TestEnv = require("SchedulerKitTestEnv")

describe("SchedulerKit delayed and repeating work", function()
  after_each(TestEnv.Reset)

  it("uses TimerKit to wake delayed jobs", function()
    local SchedulerKit = TestEnv.NewPackage()
    local calls = 0
    local job = SchedulerKit:After(2, function()
      calls = calls + 1
    end)

    assert.are.equal("delayed", job:GetState())
    assert.are.equal(1, #TestEnv.NativeTimers())
    assert.are.equal(2, TestEnv.NativeTimers()[1].seconds)

    TestEnv.FireNative(1)
    assert.are.equal("pending", job:GetState())
    TestEnv.Tick()
    assert.are.equal(1, calls)
    assert.are.equal("completed", job:GetState())
  end)

  it("supports zero-delay one-shot scheduling", function()
    local SchedulerKit = TestEnv.NewPackage()
    local calls = 0
    SchedulerKit:After(0, function()
      calls = calls + 1
    end)
    TestEnv.FireNative(1)
    TestEnv.Tick()
    assert.are.equal(1, calls)
  end)

  it("re-arms repeating jobs after each completed iteration without overlap", function()
    local SchedulerKit = TestEnv.NewPackage()
    local calls = 0
    local job
    job = SchedulerKit:Every(3, function(context)
      calls = calls + 1
      assert.are.equal(job, context:GetJob())
    end)

    TestEnv.FireNative(1)
    TestEnv.Tick()
    assert.are.equal(1, calls)
    assert.are.equal("delayed", job:GetState())
    assert.are.equal(2, #TestEnv.NativeTimers())

    TestEnv.FireNative(2)
    TestEnv.Tick()
    assert.are.equal(2, calls)
    assert.are.equal("delayed", job:GetState())
  end)

  it("cancels delayed wakeups", function()
    local SchedulerKit = TestEnv.NewPackage()
    local calls = 0
    local job = SchedulerKit:After(1, function()
      calls = calls + 1
    end)
    assert.is_true(job:Cancel())
    assert.are.equal("cancelled", job:GetState())
    assert.is_true(TestEnv.NativeTimers()[1].cancelled)
    assert.is_false(TestEnv.FireNative(1))
    assert.are.equal(0, calls)
  end)

  it("carries the waking job through TimerKit's public user-data seam", function()
    local SchedulerKit, _, TimerKit = TestEnv.NewPackage()
    local scope = SchedulerKit:CreateScope()
    local seen = {}
    local seenCount = 0

    local originalSetUserData = TimerKit.Timer.SetUserData
    TimerKit.Timer.SetUserData = function(timer, value)
      seenCount = seenCount + 1
      seen[seenCount] = value
      return originalSetUserData(timer, value)
    end

    local job = scope:After(1, function() end)
    assert.are.equal(1, seenCount)
    assert.are.equal(job, seen[1])

    job:Cancel()
    -- Cancellation must release the scheduler's reference from the handle
    -- instead of leaving the job reachable from a live timer.
    assert.are.equal(2, seenCount)
    assert.is_nil(seen[2])

    TimerKit.Timer.SetUserData = originalSetUserData
  end)

  it("does not write private fields onto the TimerKit handle", function()
    local SchedulerKit = TestEnv.NewPackage()
    local scope = SchedulerKit:CreateScope()
    scope:After(1, function() end)

    local timerScope = rawget(scope, "_timerScope")
    local timers = rawget(timerScope, "_active")
    local inspected = 0
    for timer in next, timers do
      inspected = inspected + 1
      assert.is_nil(rawget(timer, "__schedulerKitJob"))
      assert.is_nil(rawget(timer, "__schedulerKitGeneration"))
    end
    assert.are.equal(1, inspected)
  end)

  it("ignores a delayed wakeup whose job has already been re-armed", function()
    local SchedulerKit = TestEnv.NewPackage()
    local calls = 0
    local job = SchedulerKit:Every(1, function()
      calls = calls + 1
    end)

    TestEnv.FireNative(1)
    TestEnv.Tick()
    assert.are.equal(1, calls)
    assert.are.equal("delayed", job:GetState())

    -- The first interval's handle is stale: it no longer belongs to the
    -- job, so replaying it must not queue a second iteration.
    local stale = TestEnv.NativeTimers()[1]
    stale.fired = false
    stale.callback(stale)
    TestEnv.Tick()
    assert.are.equal(1, calls)
    assert.are.equal("delayed", job:GetState())
  end)

  it("cancels a repeating job whose scope closes during its callback", function()
    local SchedulerKit = TestEnv.NewPackage()
    local scope = SchedulerKit:CreateScope()
    local calls = 0
    local job = scope:Every(1, function(context)
      calls = calls + 1
      context:GetJob():GetScope():Close()
    end)

    TestEnv.FireNative(1)
    TestEnv.Tick()

    assert.are.equal(1, calls)
    assert.is_true(scope:IsClosed())
    assert.are.equal("cancelled", job:GetState())
    assert.are.equal(0, scope:GetActiveCount())
    assert.are.equal(0, SchedulerKit:GetActiveCount())

    -- No replacement interval was armed, so the driver has nothing left.
    assert.are.equal(1, #TestEnv.NativeTimers())
    assert.are.equal(0, TestEnv.ActiveOnUpdateCount())
  end)

  it("isolates repeating re-arm failures from unrelated jobs", function()
    local SchedulerKit = TestEnv.NewPackage()
    local first = SchedulerKit:Every(1, function() end)
    local unrelatedCalls = 0
    SchedulerKit:Schedule(function()
      unrelatedCalls = unrelatedCalls + 1
    end)

    TestEnv.FireNative(1)
    TestEnv.FailNextTimerCreate("rearm failed")
    TestEnv.Tick()

    assert.are.equal("failed", first:GetState())
    assert.are.equal(1, unrelatedCalls)
  end)
end)
