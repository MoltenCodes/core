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

describe("SchedulerKit tick-path allocation", function()
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
end)
