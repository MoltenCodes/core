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
            SchedulerKit:Schedule(function() calls = calls + 1 end)
        end

        TestEnv.Tick()
        assert.are.equal(3, calls)
        TestEnv.Tick()
        assert.are.equal(6, calls)
        TestEnv.Tick()
        assert.are.equal(7, calls)
    end)

    it("fails suspended jobs that exceed the cooperative slice threshold", function()
        local SchedulerKit = TestEnv.NewPackage()
        SchedulerKit:SetRunawayThreshold(4)

        local job = SchedulerKit:Schedule(function(context)
            TestEnv.AdvanceMs(5)
            context:Yield()
        end)

        TestEnv.Tick()
        assert.are.equal("failed", job:GetState())
        assert.is_true(job:HasError())
        assert.are.equal(1, #TestEnv.ReportedErrors())
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
