local TestEnv = require("SchedulerKitTestEnv")

---Run the installed OnUpdate driver `passes` times, straight through the
---frame's script so the fixture's own bookkeeping is not measured.
---@param passes integer
local function runDriverPasses(passes)
  local frames = TestEnv.Frames()
  local driver = frames[#frames]
  local onUpdate = driver.scripts.OnUpdate
  for _ = 1, passes do
    onUpdate(driver, 0.016)
  end
end

---Schedule a job that yields for ever, so every driver pass resumes it.
---@param SchedulerKit table
---@param priority integer?
local function scheduleEndlessJob(SchedulerKit, priority)
  SchedulerKit:Schedule(function(context)
    while true do
      context:Yield()
    end
  end, { priority = priority })
end

describe("SchedulerKit tick-path allocation #allocation", function()
  after_each(TestEnv.Reset)

  it("resumes a long-running yielding job without allocating", function()
    local SchedulerKit = TestEnv.NewPackage()
    SchedulerKit:SetMaxResumesPerFrame(100)
    scheduleEndlessJob(SchedulerKit)
    runDriverPasses(2)

    local allocated = TestEnv.AllocatedKilobytes(function()
      runDriverPasses(200)
    end)
    assert.is_true(allocated < 1, "20000 resumes allocated " .. allocated .. " KiB")
  end)

  it("serves every priority, IDLE included, without allocating", function()
    local SchedulerKit = TestEnv.NewPackage()
    SchedulerKit:SetMaxResumesPerFrame(100)
    local Priority = SchedulerKit.Priority
    scheduleEndlessJob(SchedulerKit, Priority.HIGH)
    scheduleEndlessJob(SchedulerKit, Priority.NORMAL)
    scheduleEndlessJob(SchedulerKit, Priority.LOW)
    scheduleEndlessJob(SchedulerKit, Priority.IDLE)
    -- The IDLE job first runs when the starvation guard trips after 256
    -- contending resumes; warm up past that so its coroutine exists.
    runDriverPasses(3)

    local allocated = TestEnv.AllocatedKilobytes(function()
      runDriverPasses(200)
    end)
    assert.is_true(allocated < 1, "20000 mixed resumes allocated " .. allocated .. " KiB")
  end)

  it("keeps a never-drained lane's queue indices at the front", function()
    local SchedulerKit = TestEnv.NewPackage()
    SchedulerKit:SetMaxResumesPerFrame(100)
    scheduleEndlessJob(SchedulerKit)
    runDriverPasses(10)

    local queue = SchedulerKit._state.queues[SchedulerKit.Priority.NORMAL]
    assert.are.equal(1, queue.head)
    assert.are.equal(1, queue.tail)
  end)

  it(
    "starts a one-shot job on a reused coroutine, allocating only the job and its context",
    function()
      local SchedulerKit = TestEnv.NewPackage()
      local scope = SchedulerKit:CreateScope()
      local function callback() end
      scope:Schedule(callback)
      TestEnv.Tick()

      local jobs = 100
      local allocated = TestEnv.AllocatedKilobytes(function()
        for _ = 1, jobs do
          scope:Schedule(callback)
          TestEnv.Tick()
        end
      end)
      -- A job record and its context stay under 1 KiB; a coroutine and its
      -- starting closure alone were over 1.2 KiB before revision 18.
      assert.is_true(allocated / jobs < 1, "one job allocated " .. allocated / jobs .. " KiB")
    end
  )

  it("allocates nothing to validate a reused option table", function()
    local SchedulerKit = TestEnv.NewPackage()
    local scope = SchedulerKit:CreateScope()
    local function callback() end
    local options = { name = "reused options", priority = SchedulerKit.Priority.LOW }
    scope:Schedule(callback):Cancel()
    scope:Schedule(callback, options):Cancel()

    local jobs = 100
    local plain = TestEnv.AllocatedKilobytes(function()
      for _ = 1, jobs do
        scope:Schedule(callback):Cancel()
      end
    end)
    local named = TestEnv.AllocatedKilobytes(function()
      for _ = 1, jobs do
        scope:Schedule(callback, options):Cancel()
      end
    end)
    assert.are.equal(plain, named)
  end)

  it("creates and closes a coalesce handle in under 1 KiB", function()
    local SchedulerKit = TestEnv.NewPackage()
    local scope = SchedulerKit:CreateScope()
    local function callback() end
    scope:Coalesce(callback, 0.5):Close()

    local handles = 100
    local allocated = TestEnv.AllocatedKilobytes(function()
      for _ = 1, handles do
        scope:Coalesce(callback, 0.5):Close()
      end
    end)
    assert.is_true(
      allocated / handles < 1,
      "one handle allocated " .. allocated / handles .. " KiB"
    )
  end)
end)
