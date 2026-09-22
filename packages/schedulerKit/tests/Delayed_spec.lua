local TestEnv = require("SchedulerKitTestEnv")

describe("SchedulerKit delayed and repeating work", function()
    after_each(TestEnv.Reset)

    it("uses TimerKit to wake delayed jobs", function()
        local SchedulerKit = TestEnv.NewPackage()
        local calls = 0
        local job = SchedulerKit:After(2, function()
            calls = calls + 1
        end)

        assert.are.equal("delayed", job:GetState())
        assert.are.equal(1, #TestEnv.NativeTimers())
        assert.are.equal(2, TestEnv.NativeTimers()[1].seconds)

        TestEnv.FireNative(1)
        assert.are.equal("pending", job:GetState())
        TestEnv.Tick()
        assert.are.equal(1, calls)
        assert.are.equal("completed", job:GetState())
    end)

    it("supports zero-delay one-shot scheduling", function()
        local SchedulerKit = TestEnv.NewPackage()
        local calls = 0
        SchedulerKit:After(0, function()
            calls = calls + 1
        end)
        TestEnv.FireNative(1)
        TestEnv.Tick()
        assert.are.equal(1, calls)
    end)

    it("re-arms repeating jobs after each completed iteration without overlap", function()
        local SchedulerKit = TestEnv.NewPackage()
        local calls = 0
        local job
        job = SchedulerKit:Every(3, function(context)
            calls = calls + 1
            assert.are.equal(job, context:GetJob())
        end)

        TestEnv.FireNative(1)
        TestEnv.Tick()
        assert.are.equal(1, calls)
        assert.are.equal("delayed", job:GetState())
        assert.are.equal(2, #TestEnv.NativeTimers())

        TestEnv.FireNative(2)
        TestEnv.Tick()
        assert.are.equal(2, calls)
        assert.are.equal("delayed", job:GetState())
    end)

    it("cancels delayed wakeups", function()
        local SchedulerKit = TestEnv.NewPackage()
        local calls = 0
        local job = SchedulerKit:After(1, function()
            calls = calls + 1
        end)
        assert.is_true(job:Cancel())
        assert.are.equal("cancelled", job:GetState())
        assert.is_true(TestEnv.NativeTimers()[1].cancelled)
        assert.is_false(TestEnv.FireNative(1))
        assert.are.equal(0, calls)
    end)

    it("isolates repeating re-arm failures from unrelated jobs", function()
        local SchedulerKit = TestEnv.NewPackage()
        local first = SchedulerKit:Every(1, function() end)
        local unrelatedCalls = 0
        SchedulerKit:Schedule(function()
            unrelatedCalls = unrelatedCalls + 1
        end)

        TestEnv.FireNative(1)
        TestEnv.FailNextTimerCreate("rearm failed")
        TestEnv.Tick()

        assert.are.equal("failed", first:GetState())
        assert.are.equal(1, unrelatedCalls)
    end)
end)
