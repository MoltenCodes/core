local TestEnv = require("ReadinessKitTestEnv")

describe("ReadinessKit timeouts", function()
  local ReadinessKit
  before_each(function()
    ReadinessKit = TestEnv.NewPackage()
  end)
  after_each(TestEnv.Reset)

  it("calls waiters once with timeout and stops polling", function()
    local calls = 0
    local gate = ReadinessKit:Gate("guild", function()
      calls = calls + 1
      return false
    end, { timeoutSeconds = 2 })
    local results = {}
    gate:Await(function(ready, reason)
      results[#results + 1] = { ready, reason }
    end)

    TestEnv.Poll(500)
    TestEnv.Poll(500)
    TestEnv.Poll(500)
    assert.are.same({}, results)

    TestEnv.Poll(500)
    assert.are.same({ { false, "timeout" } }, results)
    assert.are.equal(0, TestEnv.ArmedTimerCount())
    assert.are.equal(5, calls)

    TestEnv.Poll(500)
    assert.are.equal(5, calls)
    assert.are.equal(1, #results)
  end)

  it("answers Await on a timed-out gate at once with timeout", function()
    local gate = ReadinessKit:Gate("guild", function()
      return false
    end, { timeoutSeconds = 0.5 })
    TestEnv.Poll(500)

    local results = {}
    local waiter = gate:Await(function(ready, reason)
      results[#results + 1] = { ready, reason }
    end)
    assert.are.same({ { false, "timeout" } }, results)
    assert.is_false(waiter:IsPending())
    assert.are.equal(0, TestEnv.ArmedTimerCount())
  end)

  it("never times out with timeoutSeconds false", function()
    local gate = ReadinessKit:Gate("guild", function()
      return false
    end, { timeoutSeconds = false })
    local results = {}
    gate:Await(function(ready)
      results[#results + 1] = ready
    end)
    for _ = 1, 200 do
      TestEnv.Poll(500)
    end
    assert.are.same({}, results)
    assert.are.equal(1, TestEnv.ArmedTimerCount())
  end)

  it("measures the timeout from the start of the round on the wall clock", function()
    local gate = ReadinessKit:Gate("guild", function()
      return false
    end, { timeoutSeconds = 2 })
    local results = {}
    gate:Await(function(_, reason)
      results[#results + 1] = reason
    end)

    -- A loading screen: the timer is late, but two seconds have passed.
    TestEnv.Poll(2500)
    assert.are.same({ "timeout" }, results)
  end)

  it("resumes polling with a fresh timeout after Invalidate", function()
    local ready = false
    local gate = ReadinessKit:Gate("guild", function()
      return ready
    end, { timeoutSeconds = 1 })
    TestEnv.Poll(500)
    TestEnv.Poll(500)
    assert.are.equal(0, TestEnv.ArmedTimerCount())

    assert.is_false(gate:Invalidate())
    assert.are.equal(1, TestEnv.ArmedTimerCount())
    local results = {}
    gate:Await(function(isReady)
      results[#results + 1] = isReady
    end)

    TestEnv.Poll(500)
    assert.are.same({}, results)
    ready = true
    TestEnv.Poll(500)
    assert.are.same({ true }, results)
    assert.is_true(gate:IsReady())
  end)

  it("resumes polling after Probe on a timed-out gate", function()
    local ready = false
    local gate = ReadinessKit:Gate("guild", function()
      return ready
    end, { timeoutSeconds = 0.5 })
    TestEnv.Poll(500)
    assert.are.equal(0, TestEnv.ArmedTimerCount())

    TestEnv.AdvanceMs(500)
    assert.is_false(gate:Probe())
    assert.are.equal(1, TestEnv.ArmedTimerCount())

    local results = {}
    gate:Await(function(isReady, reason)
      results[#results + 1] = { isReady, reason }
    end)
    TestEnv.Poll(500)
    assert.are.same({ { false, "timeout" } }, results)

    ready = true
    TestEnv.AdvanceMs(500)
    assert.is_true(gate:Probe())
    assert.is_true(gate:IsReady())
    assert.are.equal(0, TestEnv.ArmedTimerCount())
  end)

  it("reuses one TimerKit timer across polling rounds", function()
    local gate = ReadinessKit:Gate("guild", function()
      return false
    end, { timeoutSeconds = 0.5 })
    TestEnv.Poll(500)
    gate:Invalidate()
    TestEnv.Poll(500)
    gate:Invalidate()

    -- One native per round, all behind the same logical timer.
    assert.are.equal(3, #TestEnv.NativeTimers())
    assert.are.equal(1, TestEnv.ArmedTimerCount())
  end)
end)

describe("ReadinessKit without GetTimePreciseSec", function()
  after_each(TestEnv.Reset)

  it("counts the timeout in polls", function()
    local ReadinessKit = TestEnv.NewPackageWithoutClock()
    local gate = ReadinessKit:Gate("guild", function()
      return false
    end, { intervalSeconds = 0.1, timeoutSeconds = 0.3 })
    local results = {}
    gate:Await(function(_, reason)
      results[#results + 1] = reason
    end)

    TestEnv.FireNative(1)
    TestEnv.FireNative(1)
    assert.are.same({}, results)
    TestEnv.FireNative(1)
    assert.are.same({ "timeout" }, results)
  end)

  it("disables the negative cache", function()
    local ReadinessKit = TestEnv.NewPackageWithoutClock()
    local calls = 0
    local gate = ReadinessKit:Gate("guild", function()
      calls = calls + 1
      return false
    end)
    gate:Probe()
    gate:Probe()
    assert.are.equal(3, calls)
  end)
end)
