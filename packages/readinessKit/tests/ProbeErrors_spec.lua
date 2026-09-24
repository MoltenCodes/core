local TestEnv = require("ReadinessKitTestEnv")

describe("ReadinessKit probes that raise", function()
  local ReadinessKit
  before_each(function()
    ReadinessKit = TestEnv.NewPackage()
  end)
  after_each(TestEnv.Reset)

  it("reports the error, counts as not ready and keeps polling", function()
    local calls = 0
    local gate = ReadinessKit:Gate("broken", function()
      calls = calls + 1
      if calls < 3 then
        error("probe failure " .. calls, 0)
      end
      return true
    end)
    assert.is_false(gate:IsReady())
    assert.are.same({ "probe failure 1" }, TestEnv.ReportedErrors())
    assert.are.equal(1, gate:GetProbeErrorCount())
    assert.are.equal(1, TestEnv.ArmedTimerCount())

    TestEnv.Poll(500)
    assert.is_false(gate:IsReady())
    assert.are.equal(2, gate:GetProbeErrorCount())

    TestEnv.Poll(500)
    assert.is_true(gate:IsReady())
    assert.are.equal(0, TestEnv.ArmedTimerCount())
  end)

  it("returns false from Probe and caches the failure like a negative answer", function()
    local calls = 0
    local gate = ReadinessKit:Gate("broken", function()
      calls = calls + 1
      error("probe failure", 0)
    end)
    TestEnv.AdvanceMs(500)
    assert.is_false(gate:Probe())
    assert.is_false(gate:Probe())
    assert.are.equal(2, calls)
    assert.are.equal(2, gate:GetProbeErrorCount())
  end)

  it("reports a probe that always raises once per round and counts the rest", function()
    local gate = ReadinessKit:Gate("broken", function()
      error("probe failure", 0)
    end, { timeoutSeconds = false })
    for _ = 1, 100 do
      TestEnv.Poll(500)
    end
    assert.are.same({ "probe failure" }, TestEnv.ReportedErrors())
    assert.are.equal(101, gate:GetProbeErrorCount())
    assert.are.equal(1, TestEnv.ArmedTimerCount())
  end)

  it("reports again in the round a timeout or Invalidate starts", function()
    local gate = ReadinessKit:Gate("broken", function()
      error("probe failure", 0)
    end, { timeoutSeconds = 1 })
    TestEnv.Poll(500)
    TestEnv.Poll(500)
    assert.are.equal(1, #TestEnv.ReportedErrors())

    gate:Invalidate()
    TestEnv.Poll(500)
    TestEnv.Poll(500)
    assert.are.equal(2, #TestEnv.ReportedErrors())
    assert.are.equal(5, gate:GetProbeErrorCount())
  end)

  it("prints the error when the host has no error handler", function()
    -- The fixture removes this global between specs; a host without it is what is being modelled.
    -- selene: allow(global_usage)
    rawset(_G, "geterrorhandler", nil)
    local printed = {}
    local originalPrint = print
    -- Replacing print is the only way to observe the documented fallback.
    -- selene: allow(global_usage)
    rawset(_G, "print", function(value)
      printed[#printed + 1] = value
    end)
    local ok = pcall(ReadinessKit.Gate, ReadinessKit, "broken", function()
      error("probe failure", 0)
    end)
    -- selene: allow(global_usage)
    rawset(_G, "print", originalPrint)
    assert.is_true(ok)
    assert.are.same({ "probe failure" }, printed)
  end)
end)
