local TestEnv = require("SchedulerKitTestEnv")

describe("SchedulerKit error isolation", function()
  after_each(TestEnv.Reset)

  it("marks callback failures without starving later jobs", function()
    local SchedulerKit = TestEnv.NewPackage()
    local failed = SchedulerKit:Schedule(function()
      error("boom", 0)
    end)
    local calls = 0
    SchedulerKit:Schedule(function()
      calls = calls + 1
    end)

    TestEnv.Tick()
    assert.are.equal("failed", failed:GetState())
    assert.is_true(failed:HasError())
    assert.are.equal("boom", failed:GetError())
    assert.are.equal(1, calls)

    -- The host error handler receives the traceback captured at the point
    -- of failure; the original error object stays on the job.
    local report = TestEnv.ReportedErrors()[1]
    assert.is_true(report:find("boom", 1, true) ~= nil)
    assert.is_true(report:find("stack traceback:", 1, true) ~= nil)
  end)

  it("preserves nil and false Lua error objects", function()
    local SchedulerKit = TestEnv.NewPackage()
    local nilJob = SchedulerKit:Schedule(function()
      error(nil, 0)
    end)
    local falseJob = SchedulerKit:Schedule(function()
      error(false, 0)
    end)
    TestEnv.Tick()

    assert.is_true(nilJob:HasError())
    assert.is_nil(nilJob:GetError())
    assert.is_true(falseJob:HasError())
    assert.is_false(falseJob:GetError())
  end)

  it("logically cancels even when native timer cancellation raises", function()
    local SchedulerKit = TestEnv.NewPackage()
    local job = SchedulerKit:After(2, function() end)
    TestEnv.FailNextTimerCancel("native cancel failed")

    local ok, value = pcall(function()
      job:Cancel()
    end)
    assert.is_false(ok)
    assert.are.equal("native cancel failed", value)
    assert.are.equal("cancelled", job:GetState())
    assert.is_false(job:IsPending())
  end)

  it("captures a traceback at the point of failure", function()
    local SchedulerKit = TestEnv.NewPackage()

    local function inner()
      error("deep failure")
    end
    local job = SchedulerKit:Schedule(function()
      inner()
    end)

    TestEnv.Tick()
    assert.are.equal("failed", job:GetState())

    local traceback = job:GetErrorTraceback()
    assert.is_not_nil(traceback)
    assert.is_true(traceback:find("stack traceback:", 1, true) ~= nil)
    -- The frame that raised must still be named, which is only possible
    -- while the failing coroutine is available.
    assert.is_true(traceback:find("inner", 1, true) ~= nil)
    assert.are.equal(traceback, TestEnv.ReportedErrors()[1])
  end)

  it("keeps the original error object alongside the traceback", function()
    local SchedulerKit = TestEnv.NewPackage()
    local marker = {}
    local job = SchedulerKit:Schedule(function()
      error(marker, 0)
    end)

    TestEnv.Tick()
    assert.are.equal(marker, job:GetError())
    assert.is_true(job:GetErrorTraceback():find("stack traceback:", 1, true) ~= nil)
  end)

  it("has no traceback for jobs that did not fail through a callback error", function()
    local SchedulerKit = TestEnv.NewPackage()
    local completed = SchedulerKit:Schedule(function() end)
    TestEnv.Tick()
    assert.is_nil(completed:GetErrorTraceback())

    TestEnv.FailNextTimerCreate("arm failed")
    local ok = pcall(function()
      SchedulerKit:After(1, function() end)
    end)
    assert.is_false(ok)
  end)

  it("raises an arming failure to its caller without also reporting it", function()
    local SchedulerKit = TestEnv.NewPackage()
    TestEnv.FailNextTimerCreate("arm failed")

    local ok, value = pcall(function()
      SchedulerKit:After(1, function() end)
    end)
    assert.is_false(ok)
    assert.are.equal("arm failed", value)
    -- The caller already has the failure; reporting it again would surface
    -- one problem twice.
    assert.are.equal(0, #TestEnv.ReportedErrors())
  end)

  it("reports a re-arm failure exactly once because nothing can catch it", function()
    local SchedulerKit = TestEnv.NewPackage()
    local job = SchedulerKit:Every(1, function() end)

    TestEnv.FireNative(1)
    TestEnv.FailNextTimerCreate("rearm failed")
    TestEnv.Tick()

    assert.are.equal("failed", job:GetState())
    assert.are.equal(1, #TestEnv.ReportedErrors())
    assert.are.equal("rearm failed", TestEnv.ReportedErrors()[1])
  end)

  it("rolls back work if the OnUpdate driver cannot be installed", function()
    local SchedulerKit = TestEnv.NewPackage()
    TestEnv.FailNextSetScript("driver failed")
    local ok = pcall(function()
      SchedulerKit:Schedule(function() end)
    end)
    assert.is_false(ok)
    assert.are.equal(0, SchedulerKit:GetActiveCount())
  end)
end)
