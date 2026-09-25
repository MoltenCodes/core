local TestEnv = require("SchedulerKitTestEnv")

-- Worker coroutines (revision 18): a job starts on a coroutine that a finished
-- one-shot run handed back, and only a callback that returned hands its
-- coroutine back. See "Worker coroutines" in src/SchedulerKit.lua and
-- docs/INTERNALS.md.

---Schedule one job that records the coroutine it runs on.
---@param SchedulerKit table
---@param threads thread[] receives the running coroutine
---@return table job
local function scheduleRecorder(SchedulerKit, threads)
  return SchedulerKit:Schedule(function()
    threads[#threads + 1] = coroutine.running()
  end)
end

describe("SchedulerKit worker coroutines", function()
  after_each(TestEnv.Reset)

  it("starts the next job on the coroutine a finished job handed back", function()
    local SchedulerKit = TestEnv.NewPackage()
    local threads = {}
    local first = scheduleRecorder(SchedulerKit, threads)
    TestEnv.Tick()
    local second = scheduleRecorder(SchedulerKit, threads)
    TestEnv.Tick()

    assert.are.equal("completed", first:GetState())
    assert.are.equal("completed", second:GetState())
    assert.are.equal(threads[1], threads[2])
    assert.are.equal(1, SchedulerKit._state.idleWorkerCount)
  end)

  it("runs every iteration of a repeating job on the same coroutine", function()
    local SchedulerKit = TestEnv.NewPackage()
    local threads = {}
    local job = SchedulerKit:Every(1, function()
      threads[#threads + 1] = coroutine.running()
    end)
    for _ = 1, 3 do
      local timers = TestEnv.NativeTimers()
      TestEnv.FireNative(#timers)
      TestEnv.Tick()
    end

    assert.are.equal(3, #threads)
    assert.are.equal(threads[1], threads[2])
    assert.are.equal(threads[2], threads[3])
    assert.are.equal("delayed", job:GetState())
  end)

  it("gives each job its own context and keeps the job handle current", function()
    local SchedulerKit = TestEnv.NewPackage()
    local seen = {}
    local jobs = {}
    for index = 1, 2 do
      jobs[index] = SchedulerKit:Schedule(function(context)
        seen[index] = context
        assert.are.equal(jobs[index], context:GetJob())
        assert.is_false(context:IsCancelled())
      end)
      TestEnv.Tick()
    end

    assert.are_not.equal(seen[1], seen[2])
    assert.are.equal(jobs[1], seen[1]:GetJob())
  end)

  it("does not hand back the coroutine of a callback that raised", function()
    local SchedulerKit = TestEnv.NewPackage()
    local threads = {}
    local failing = SchedulerKit:Schedule(function()
      threads[#threads + 1] = coroutine.running()
      error("boom", 0)
    end)
    TestEnv.Tick()
    TestEnv.TakeReportedErrors()
    scheduleRecorder(SchedulerKit, threads)
    TestEnv.Tick()

    assert.are.equal("failed", failing:GetState())
    assert.are.equal("boom", failing:GetError())
    assert.are.equal("dead", coroutine.status(threads[1]))
    assert.are_not.equal(threads[1], threads[2])
  end)

  it("does not hand back the coroutine of a job cancelled while it yielded", function()
    local SchedulerKit = TestEnv.NewPackage()
    -- One resume per pass, so the job is still suspended after the first.
    SchedulerKit:SetMaxResumesPerFrame(1)
    local threads = {}
    local yielding
    yielding = SchedulerKit:Schedule(function(context)
      threads[#threads + 1] = coroutine.running()
      context:Yield()
      error("a cancelled job must not be resumed", 0)
    end)
    TestEnv.Tick()
    assert.is_true(yielding:Cancel())
    scheduleRecorder(SchedulerKit, threads)
    TestEnv.Tick()

    assert.are.equal("cancelled", yielding:GetState())
    assert.are.equal("suspended", coroutine.status(threads[1]))
    assert.are_not.equal(threads[1], threads[2])
    assert.are.same({}, TestEnv.ReportedErrors())
  end)

  it("hands back the coroutine of a job that cancelled itself and returned", function()
    local SchedulerKit = TestEnv.NewPackage()
    local threads = {}
    local job
    job = SchedulerKit:Schedule(function()
      threads[#threads + 1] = coroutine.running()
      job:Cancel()
    end)
    TestEnv.Tick()
    scheduleRecorder(SchedulerKit, threads)
    TestEnv.Tick()

    assert.are.equal("cancelled", job:GetState())
    assert.are.equal(threads[1], threads[2])
  end)

  it("fails a raw coroutine.yield and does not hand its coroutine back", function()
    local SchedulerKit = TestEnv.NewPackage()
    local threads = {}
    local job = SchedulerKit:Schedule(function()
      threads[#threads + 1] = coroutine.running()
      coroutine.yield("not the token")
    end)
    TestEnv.Tick()
    TestEnv.TakeReportedErrors()
    scheduleRecorder(SchedulerKit, threads)
    TestEnv.Tick()

    assert.are.equal("failed", job:GetState())
    assert.are.equal("SchedulerKit jobs may yield only through Context:Yield()", job:GetError())
    assert.are_not.equal(threads[1], threads[2])
  end)

  it("keeps at most four idle coroutines", function()
    local SchedulerKit = TestEnv.NewPackage()
    local jobs = {}
    for index = 1, 6 do
      jobs[index] = SchedulerKit:Schedule(function(context)
        context:Yield()
      end)
    end
    -- Every job yields in the first pass, so six coroutines run at once.
    TestEnv.Tick()
    TestEnv.Tick()

    for index = 1, 6 do
      assert.are.equal("completed", jobs[index]:GetState())
    end
    assert.are.equal(4, SchedulerKit._state.idleWorkerCount)
    assert.are.equal(4, #SchedulerKit._state.idleWorkers)
  end)

  it("keeps neither the finished job nor its callback alive in an idle coroutine", function()
    local SchedulerKit = TestEnv.NewPackage()
    local weak = setmetatable({}, { __mode = "v" })
    do
      local callback = function() end
      weak.callback = callback
      weak.job = SchedulerKit:Schedule(callback)
    end
    TestEnv.Tick()
    assert.are.equal(1, SchedulerKit._state.idleWorkerCount)

    collectgarbage()
    collectgarbage()
    assert.is_nil(weak.job)
    assert.is_nil(weak.callback)
  end)

  it("still reports a swallowed Context:Yield() on a reused coroutine", function()
    local SchedulerKit = TestEnv.NewPackage()
    SchedulerKit:Schedule(function() end)
    TestEnv.Tick()
    local job = SchedulerKit:Schedule(function(context)
      pcall(context.Yield, context)
    end)
    TestEnv.Tick()

    assert.are.equal("completed", job:GetState())
    local reports = TestEnv.ReportedErrors()
    assert.are.equal(1, #reports)
    assert.is_truthy(tostring(reports[1]):find("suspension never reached the scheduler", 1, true))
  end)

  it("completes a job whose coroutine an older revision created", function()
    local SchedulerKit = TestEnv.NewPackage()
    local calls = 0
    local job = SchedulerKit:Schedule(function(context)
      calls = calls + 1
      context:Yield()
    end)
    -- Revisions before 18 gave each job a coroutine of its own that ends by
    -- returning; install one in that shape before the job first runs.
    local callback = rawget(job, "_callback")
    local context = rawget(job, "_context")
    rawset(
      job,
      "_coroutine",
      coroutine.create(function()
        return callback(context)
      end)
    )
    TestEnv.Tick()
    TestEnv.Tick()

    assert.are.equal(1, calls)
    assert.are.equal("completed", job:GetState())
    assert.is_false(rawget(job, "_coroutine"))
    -- A coroutine that died is not handed back.
    assert.are.equal(0, SchedulerKit._state.idleWorkerCount)
  end)
end)

describe("SchedulerKit job records", function()
  after_each(TestEnv.Reset)

  it("writes the failure fields only when a job fails", function()
    local SchedulerKit = TestEnv.NewPackage()
    local completed = SchedulerKit:Schedule(function() end)
    local failed = SchedulerKit:Schedule(function()
      error("broken", 0)
    end)
    TestEnv.Tick()
    TestEnv.TakeReportedErrors()

    assert.is_nil(rawget(completed, "_errorPresent"))
    assert.is_false(completed:HasError())
    assert.is_nil(completed:GetError())
    assert.is_nil(completed:GetErrorTraceback())
    assert.is_true(failed:HasError())
    assert.are.equal("broken", failed:GetError())
    assert.are.equal("string", type(failed:GetErrorTraceback()))
  end)

  it("validates a named option table without building its error labels", function()
    local SchedulerKit = TestEnv.NewPackage()
    local options = { name = "labelled", priority = SchedulerKit.Priority.HIGH }
    local job = SchedulerKit:Schedule(function() end, options)
    assert.are.equal("labelled", job:GetName())
    assert.are.equal(SchedulerKit.Priority.HIGH, job:GetPriority())

    -- The refusals still name the method and the field.
    TestEnv.expectErrorContaining(
      "SchedulerKit:Schedule name must be a non-empty string",
      function()
        SchedulerKit:Schedule(function() end, { name = "" })
      end
    )
    TestEnv.expectErrorContaining(
      "SchedulerKit:Schedule name must be a non-empty string",
      function()
        SchedulerKit:Schedule(function() end, { name = 7 })
      end
    )
    TestEnv.expectErrorContaining(
      "SchedulerKit:NextFrame priority must be one of SchedulerKit.Priority values",
      function()
        SchedulerKit:NextFrame(function() end, { priority = 9 })
      end
    )
    TestEnv.expectErrorContaining(
      "SchedulerKit.Scope:After delay must be a finite number greater than or equal to zero",
      function()
        SchedulerKit:CreateScope():After(-1, function() end)
      end
    )
    TestEnv.expectErrorContaining(
      "SchedulerKit:Every interval must be a finite number greater than zero",
      function()
        SchedulerKit:Every(0, function() end)
      end
    )
  end)
end)
