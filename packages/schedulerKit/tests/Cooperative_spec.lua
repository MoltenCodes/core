local TestEnv = require("SchedulerKitTestEnv")

describe("SchedulerKit cooperative jobs", function()
    after_each(TestEnv.Reset)

    it("resumes explicit yields on later scheduling turns", function()
        local SchedulerKit = TestEnv.NewPackage()
        SchedulerKit:SetMaxResumesPerFrame(1)
        local steps = {}

        local job = SchedulerKit:Schedule(function(context)
            steps[#steps + 1] = 1
            context:Yield()
            steps[#steps + 1] = 2
            context:Yield()
            steps[#steps + 1] = 3
        end)

        TestEnv.Tick()
        assert.are.same({ 1 }, steps)
        assert.are.equal("pending", job:GetState())

        TestEnv.Tick()
        assert.are.same({ 1, 2 }, steps)
        TestEnv.Tick()
        assert.are.same({ 1, 2, 3 }, steps)
        assert.are.equal("completed", job:GetState())
    end)

    it("reports frame budget exhaustion through ShouldYield", function()
        local SchedulerKit = TestEnv.NewPackage()
        SchedulerKit:SetFrameBudget(2)
        local before, after

        SchedulerKit:Schedule(function(context)
            before = context:ShouldYield()
            TestEnv.AdvanceMs(3)
            after = context:ShouldYield()
        end)

        TestEnv.Tick()
        assert.is_false(before)
        assert.is_true(after)
    end)

    it("stops starting new jobs after the frame budget is consumed", function()
        local SchedulerKit = TestEnv.NewPackage()
        SchedulerKit:SetFrameBudget(2)
        local order = {}

        SchedulerKit:Schedule(function()
            order[#order + 1] = 1
            TestEnv.AdvanceMs(3)
        end)
        SchedulerKit:Schedule(function()
            order[#order + 1] = 2
        end)

        TestEnv.Tick()
        assert.are.same({ 1 }, order)
        TestEnv.Tick()
        assert.are.same({ 1, 2 }, order)
    end)

    it("honors the resume-count ceiling even when profiling time does not advance", function()
        local SchedulerKit = TestEnv.NewPackage()
        SchedulerKit:SetFrameBudget(100)
        SchedulerKit:SetMaxResumesPerFrame(3)
        local calls = 0
        for _ = 1, 7 do
            SchedulerKit:Schedule(function()
                calls = calls + 1
            end)
        end

        TestEnv.Tick()
        assert.are.equal(3, calls)
        TestEnv.Tick()
        assert.are.equal(6, calls)
        TestEnv.Tick()
        assert.are.equal(7, calls)
    end)

    it("demotes rather than kills a job that yields after an over-long slice", function()
        local SchedulerKit = TestEnv.NewPackage()
        SchedulerKit:SetRunawayThreshold(4)
        SchedulerKit:SetMaxResumesPerFrame(1)
        local completed = false

        local job = SchedulerKit:Schedule(function(context)
            TestEnv.AdvanceMs(5)
            context:Yield()
            completed = true
        end, { priority = SchedulerKit.Priority.HIGH, name = "slow pass" })

        TestEnv.Tick()
        assert.are.equal("pending", job:GetState())
        assert.is_false(job:HasError())
        assert.are.equal(SchedulerKit.Priority.NORMAL, job:GetPriority())
        assert.are.equal(1, #TestEnv.ReportedErrors())
        assert.is_true(TestEnv.ReportedErrors()[1]:find("slow pass", 1, true) ~= nil)

        TestEnv.Tick()
        assert.is_true(completed)
        assert.are.equal("completed", job:GetState())
    end)

    it("demotes at most to IDLE and keeps reporting each overrun", function()
        local SchedulerKit = TestEnv.NewPackage()
        SchedulerKit:SetRunawayThreshold(4)
        SchedulerKit:SetMaxResumesPerFrame(1)

        local job = SchedulerKit:Schedule(function(context)
            for _ = 1, 5 do
                TestEnv.AdvanceMs(5)
                context:Yield()
            end
        end, { priority = SchedulerKit.Priority.LOW })

        for _ = 1, 5 do
            TestEnv.Tick()
        end
        assert.are.equal(SchedulerKit.Priority.IDLE, job:GetPriority())
        assert.are.equal(5, #TestEnv.ReportedErrors())
    end)

    it("charges CPU time rather than wall time to a cooperating job", function()
        local SchedulerKit = TestEnv.NewPackage()
        SchedulerKit:SetRunawayThreshold(4)
        SchedulerKit:SetMaxResumesPerFrame(1)

        -- A garbage-collection pause or client hitch inflates wall time while
        -- the job itself consumed almost none of the frame.
        local job = SchedulerKit:Schedule(function(context)
            TestEnv.AdvanceProfileMs(1)
            TestEnv.AdvanceWallMs(500)
            context:Yield()
        end, { priority = SchedulerKit.Priority.NORMAL })

        TestEnv.Tick()
        assert.are.equal("pending", job:GetState())
        assert.are.equal(SchedulerKit.Priority.NORMAL, job:GetPriority())
        assert.are.equal(0, #TestEnv.ReportedErrors())
    end)

    it("measures the frame budget in CPU time", function()
        local SchedulerKit = TestEnv.NewPackage()
        SchedulerKit:SetFrameBudget(2)
        local afterHitch, afterWork

        SchedulerKit:Schedule(function(context)
            TestEnv.AdvanceWallMs(50)
            afterHitch = context:ShouldYield()
            TestEnv.AdvanceProfileMs(3)
            afterWork = context:ShouldYield()
        end)

        TestEnv.Tick()
        assert.is_false(afterHitch)
        assert.is_true(afterWork)
    end)

    it("falls back to the precise wall clock when the host has no CPU clock", function()
        TestEnv.Reset()
        TestEnv.WithoutProfilingClock()
        TestEnv.InstallWowApi()
        require("Registry")
        require("SignalKit")
        require("EventKit")
        require("LifecycleKit")
        require("TimerKit")
        local SchedulerKit = require("SchedulerKit")

        SchedulerKit:SetFrameBudget(2)
        local before, after
        SchedulerKit:Schedule(function(context)
            before = context:ShouldYield()
            TestEnv.AdvanceWallMs(3)
            after = context:ShouldYield()
        end)

        TestEnv.Tick()
        assert.is_false(before)
        assert.is_true(after)
    end)

    it("reports a Context:Yield() that never reached the scheduler", function()
        local SchedulerKit = TestEnv.NewPackage()

        -- Lua 5.1 refuses to yield across a pcall boundary. A callback that
        -- swallows that error runs to completion without ever surrendering the
        -- frame, which used to be entirely silent.
        local swallowed
        local job = SchedulerKit:Schedule(function(context)
            local ok, value = pcall(function()
                context:Yield()
            end)
            swallowed = not ok and tostring(value) or nil
        end, { name = "yield inside pcall" })

        TestEnv.Tick()
        assert.is_true(swallowed:find("yield across", 1, true) ~= nil)
        assert.are.equal("completed", job:GetState())
        assert.are.equal(1, #TestEnv.ReportedErrors())

        local report = TestEnv.ReportedErrors()[1]
        assert.is_true(report:find("yield inside pcall", 1, true) ~= nil)
        assert.is_true(report:find("never reached the scheduler", 1, true) ~= nil)
    end)

    it("fails a swallowed yield that also outran the runaway threshold", function()
        local SchedulerKit = TestEnv.NewPackage()
        SchedulerKit:SetRunawayThreshold(4)

        local job = SchedulerKit:Schedule(function(context)
            pcall(function()
                context:Yield()
            end)
            TestEnv.AdvanceMs(5)
        end)

        TestEnv.Tick()
        assert.are.equal("failed", job:GetState())
        assert.is_true(job:HasError())
        assert.is_true(tostring(job:GetError()):find("never reached the scheduler", 1, true) ~= nil)
        assert.are.equal(1, #TestEnv.ReportedErrors())
    end)

    it("does not report a job that yielded for real before completing", function()
        local SchedulerKit = TestEnv.NewPackage()
        SchedulerKit:SetMaxResumesPerFrame(4)

        local job = SchedulerKit:Schedule(function(context)
            context:Yield()
        end)

        TestEnv.Tick()
        assert.are.equal("completed", job:GetState())
        assert.are.equal(0, #TestEnv.ReportedErrors())
    end)

    it("supports cooperative self-cancellation without requeueing", function()
        local SchedulerKit = TestEnv.NewPackage()
        local observedCancelled = false
        local job
        job = SchedulerKit:Schedule(function(context)
            job:Cancel()
            observedCancelled = context:IsCancelled()
        end)

        TestEnv.Tick()
        assert.is_true(observedCancelled)
        assert.are.equal("cancelled", job:GetState())
        assert.are.equal(0, SchedulerKit:GetActiveCount())
        TestEnv.Tick()
        assert.are.equal("cancelled", job:GetState())
    end)

    it("keeps self-cancelled jobs cancelled when they yield control", function()
        local SchedulerKit = TestEnv.NewPackage()
        local job
        job = SchedulerKit:Schedule(function(context)
            job:Cancel()
            assert.is_true(context:IsCancelled())
            assert.is_true(context:ShouldYield())
            context:Yield()
        end)

        TestEnv.Tick()
        assert.are.equal("cancelled", job:GetState())
        assert.is_false(job:HasError())
        assert.are.equal(0, SchedulerKit:GetActiveCount())
    end)

    it("rejects raw coroutine yields", function()
        local SchedulerKit = TestEnv.NewPackage()
        local job = SchedulerKit:Schedule(function()
            coroutine.yield("not-scheduler-yield")
        end)

        TestEnv.Tick()
        assert.are.equal("failed", job:GetState())
        assert.is_true(job:HasError())
    end)
end)
