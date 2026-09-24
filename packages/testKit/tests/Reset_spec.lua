local TestEnv = require("TestKitTestEnv")

describe("TestKit:Reset and OnFinished", function()
  local TestKit
  before_each(function()
    TestKit = TestEnv.NewReadyPackage("MyAddon")
  end)
  after_each(TestEnv.Reset)

  it("clears results and keeps suites and callbacks", function()
    local calls = 0
    TestKit:OnFinished(function()
      calls = calls + 1
    end)
    TestKit:Suite("MyAddon"):Test("passes", function() end)
    TestEnv.RunToEnd(TestKit)
    assert.are.equal(1, TestKit:Report().totals.tests)

    assert.is_true(TestKit:Reset())
    assert.are.equal(0, TestKit:Report().totals.tests)

    TestEnv.RunToEnd(TestKit)
    assert.are.equal(1, TestKit:Report().totals.tests)
    assert.are.equal(2, calls)
  end)

  it("abandons a run in progress, restores its replacements and does not report it", function()
    local target = { value = 1 }
    local calls = 0
    TestKit:OnFinished(function()
      calls = calls + 1
    end)
    TestKit:Suite("MyAddon"):Test("waits", function(ctx)
      ctx:Replace(target, "value", 2)
      ctx:WaitFor("NEVER_FIRES", 30)
    end)
    TestKit:Suite("Waiting", { addonName = "LateAddon" })
      :Test("waits for its addon", function() end)
    TestKit:Run()
    TestEnv.RenderFrames(2)
    assert.are.equal(2, target.value)

    TestKit:Reset()
    assert.are.equal(1, target.value)
    TestEnv.LoadAddon("LateAddon")
    TestEnv.Emit("NEVER_FIRES")
    TestEnv.RenderFrames(3)
    assert.are.equal(0, calls)
    assert.are.equal(0, TestKit:Report().totals.tests)

    -- The suites can run again.
    local report = TestEnv.RunToEnd(TestKit, "Waiting")
    assert.are.equal("passed", report.suites[1].tests[1].status)
  end)

  it("refuses Reset from inside a running test", function()
    local result = TestEnv.RunOne(TestKit, function()
      TestKit:Reset()
    end)
    assert.are.equal("failed", result.status)
    assert.is_truthy(
      result.message:find("TestKit:Reset cannot be called from inside a running test", 1, true)
    )
  end)

  it("hands every OnFinished callback the report, reporting one that raises", function()
    local received = {}
    TestKit:OnFinished(function()
      error("callback bug")
    end)
    TestKit:OnFinished(function(report)
      received[#received + 1] = report
    end)
    TestKit:Suite("MyAddon"):Test("passes", function() end)
    TestKit:Run()
    TestEnv.RenderFrames(2)

    assert.are.equal(1, #received)
    assert.are.equal(1, received[1].totals.passed)
    local errors = TestEnv.ReportedErrors()
    assert.are.equal(1, #errors)
    assert.is_truthy(tostring(errors[1]):find("callback bug", 1, true))
  end)
end)
