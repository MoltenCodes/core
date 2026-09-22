local TestEnv = require("TimerKitTestEnv")

describe("TimerKit", function()
    after_each(TestEnv.Reset)

    it("creates idle one-shot timers", function()
        local TimerKit = TestEnv.NewPackage()
        local timer = TimerKit:New({ delay = 1.5, callback = function() end })

        assert.are.equal("idle", timer:GetState())
        assert.are.equal(1.5, timer:GetDelay())
        assert.is_false(timer:IsRepeating())
        assert.is_false(timer:IsPending())
        assert.is_false(timer:IsCancelled())
    end)

    it("starts and completes a one-shot timer", function()
        local TimerKit = TestEnv.NewPackage()
        local observed
        local timer = TimerKit:New({
            delay = 2,
            callback = function(self)
                observed = self
            end,
        })

        assert.is_true(timer:Start())
        assert.are.equal("running", timer:GetState())
        assert.is_true(timer:IsPending())
        assert.is_false(timer:Start())

        TestEnv.FireNative(1)
        assert.are.equal(timer, observed)
        assert.are.equal("completed", timer:GetState())
        assert.is_false(timer:IsPending())
    end)

    it("After starts immediately and permits zero delay", function()
        local TimerKit = TestEnv.NewPackage()
        local calls = 0
        local timer = TimerKit:After(0, function()
            calls = calls + 1
        end)

        assert.are.equal("running", timer:GetState())
        TestEnv.FireNative(1)
        assert.are.equal(1, calls)
        assert.are.equal("completed", timer:GetState())
    end)

    it("cancels idempotently", function()
        local TimerKit = TestEnv.NewPackage()
        local timer = TimerKit:After(1, function() end)

        assert.is_true(timer:Cancel())
        assert.is_true(timer:IsCancelled())
        assert.is_false(timer:Cancel())
        assert.is_true(TestEnv.NativeTimers()[1].cancelled)
    end)

    it("restarts completed and cancelled timers", function()
        local TimerKit = TestEnv.NewPackage()
        local calls = 0
        local timer = TimerKit:After(1, function()
            calls = calls + 1
        end)

        TestEnv.FireNative(1)
        assert.are.equal("completed", timer:GetState())
        assert.is_true(timer:Restart())
        TestEnv.FireNative(2)
        assert.are.equal(2, calls)

        assert.is_true(timer:Restart())
        assert.is_true(timer:Cancel())
        assert.is_true(timer:Restart())
        TestEnv.FireNative(4)
        assert.are.equal(3, calls)
    end)
end)
