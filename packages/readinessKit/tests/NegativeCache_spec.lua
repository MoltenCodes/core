local TestEnv = require("ReadinessKitTestEnv")

describe("ReadinessKit negative caching", function()
  local ReadinessKit
  before_each(function()
    ReadinessKit = TestEnv.NewPackage()
  end)
  after_each(TestEnv.Reset)

  it("does not re-run the probe within the interval of a negative answer", function()
    local calls = 0
    local gate = ReadinessKit:Gate("item", function()
      calls = calls + 1
      return false
    end)
    assert.are.equal(1, calls)

    assert.is_false(gate:Probe())
    assert.is_false(gate:Probe())
    TestEnv.AdvanceMs(499)
    assert.is_false(gate:Probe())
    assert.are.equal(1, calls)

    TestEnv.AdvanceMs(1)
    assert.is_false(gate:Probe())
    assert.are.equal(2, calls)
    assert.is_false(gate:Probe())
    assert.are.equal(2, calls)
  end)

  it("restarts the cache window from a negative poll", function()
    local calls = 0
    local gate = ReadinessKit:Gate("item", function()
      calls = calls + 1
      return false
    end)
    TestEnv.Poll(500)
    assert.are.equal(2, calls)
    TestEnv.AdvanceMs(250)
    gate:Probe()
    assert.are.equal(2, calls)
  end)

  it("becomes ready through Probe once the window has passed", function()
    local ready = false
    local gate = ReadinessKit:Gate("item", function()
      return ready
    end)
    local results = {}
    gate:Await(function(isReady)
      results[#results + 1] = isReady
    end)

    ready = true
    assert.is_false(gate:Probe())
    TestEnv.AdvanceMs(500)
    assert.is_true(gate:Probe())
    assert.are.same({ true }, results)
    assert.are.equal(0, TestEnv.ArmedTimerCount())
  end)

  it("does not probe a ready gate again", function()
    local calls = 0
    local gate = ReadinessKit:Gate("item", function()
      calls = calls + 1
      return true
    end)
    TestEnv.AdvanceMs(5000)
    assert.is_true(gate:Probe())
    assert.are.equal(1, calls)
  end)

  it("is dropped by Invalidate", function()
    local calls = 0
    local gate = ReadinessKit:Gate("item", function()
      calls = calls + 1
      return false
    end)
    assert.is_false(gate:Invalidate())
    gate:Probe()
    assert.are.equal(2, calls)
  end)
end)
