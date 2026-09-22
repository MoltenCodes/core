local TestEnv = require("SchedulerKitTestEnv")

describe("SchedulerKit", function()
    after_each(TestEnv.Reset)

    it("schedules work for the next scheduler frame", function()
        local SchedulerKit = TestEnv.NewPackage()
        local calls = 0
        local job
        job = SchedulerKit:Schedule(function(context)
            calls = calls + 1
            assert.are.equal(job, context:GetJob())
        end)

        assert.are.equal("pending", job:GetState())
        assert.is_true(job:IsPending())
        assert.are.equal(1, SchedulerKit:GetActiveCount())
        assert.are.equal(1, TestEnv.ActiveOnUpdateCount())

        TestEnv.Tick()
        assert.are.equal(1, calls)
        assert.are.equal("completed", job:GetState())
        assert.is_false(job:IsPending())
        assert.are.equal(0, SchedulerKit:GetActiveCount())
        assert.are.equal(0, TestEnv.ActiveOnUpdateCount())
    end)

    it("distinguishes nested Schedule from explicit NextFrame", function()
        local SchedulerKit = TestEnv.NewPackage()
        local order = {}

        SchedulerKit:Schedule(function()
            order[#order + 1] = "outer"
            SchedulerKit:Schedule(function() order[#order + 1] = "nested" end)
            SchedulerKit:NextFrame(function() order[#order + 1] = "next" end)
        end)

        TestEnv.Tick()
        assert.are.same({ "outer", "nested" }, order)
        assert.are.equal(1, #TestEnv.NativeTimers())

        TestEnv.FireNative(1)
        TestEnv.Tick()
        assert.are.same({ "outer", "nested", "next" }, order)
    end)

    it("uses normal priority by default and preserves names", function()
        local SchedulerKit = TestEnv.NewPackage()
        local job = SchedulerKit:Schedule(function() end, { name = "cache rebuild" })

        assert.are.equal(SchedulerKit.Priority.NORMAL, job:GetPriority())
        assert.are.equal("cache rebuild", job:GetName())
    end)

    it("validates configuration", function()
        local SchedulerKit = TestEnv.NewPackage()

        SchedulerKit:SetFrameBudget(3.5)
        SchedulerKit:SetRunawayThreshold(12)
        SchedulerKit:SetMaxResumesPerFrame(77)

        assert.are.equal(3.5, SchedulerKit:GetFrameBudget())
        assert.are.equal(12, SchedulerKit:GetRunawayThreshold())
        assert.are.equal(77, SchedulerKit:GetMaxResumesPerFrame())

        assert.has_error(function() SchedulerKit:SetFrameBudget(0) end)
        assert.has_error(function() SchedulerKit:SetRunawayThreshold(-1) end)
        assert.has_error(function() SchedulerKit:SetMaxResumesPerFrame(1.5) end)
        assert.has_error(function() SchedulerKit:SetMaxResumesPerFrame(math.huge) end)
    end)

    it("rejects unknown scheduling options", function()
        local SchedulerKit = TestEnv.NewPackage()
        assert.has_error(function()
            SchedulerKit:Schedule(function() end, { priorty = SchedulerKit.Priority.HIGH })
        end)
    end)
end)
