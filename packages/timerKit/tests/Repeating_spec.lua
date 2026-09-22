local TestEnv = require("TimerKitTestEnv")

describe("TimerKit repeating timers", function()
    after_each(TestEnv.Reset)

    it("fires repeatedly until cancelled", function()
        local TimerKit = TestEnv.NewPackage()
        local calls = 0
        local timer = TimerKit:Every(0.5, function()
            calls = calls + 1
        end)

        assert.is_true(timer:IsRepeating())
        TestEnv.FireNative(1)
        TestEnv.FireNative(1)
        assert.are.equal(2, calls)
        assert.are.equal("running", timer:GetState())

        timer:Cancel()
        assert.is_false(TestEnv.FireNative(1))
        assert.are.equal(2, calls)
    end)

    it("can cancel itself inside its callback", function()
        local TimerKit = TestEnv.NewPackage()
        local calls = 0
        local timer
        timer = TimerKit:Every(1, function(self)
            calls = calls + 1
            assert.are.equal(timer, self)
            self:Cancel()
        end)

        TestEnv.FireNative(1)
        assert.are.equal(1, calls)
        assert.are.equal("cancelled", timer:GetState())
        assert.is_false(TestEnv.FireNative(1))
    end)

    it("can restart itself without accepting stale callbacks", function()
        local TimerKit = TestEnv.NewPackage()
        local calls = 0
        local timer
        timer = TimerKit:Every(1, function(self)
            calls = calls + 1
            if calls == 1 then
                self:Restart()
            end
        end)

        TestEnv.FireNative(1)
        assert.are.equal(2, #TestEnv.NativeTimers())
        TestEnv.InvokeRaw(1)
        assert.are.equal(1, calls)
        TestEnv.FireNative(2)
        assert.are.equal(2, calls)
        assert.is_true(timer:IsPending())
    end)

    it("preserves running state when a repeating callback errors", function()
        local TimerKit = TestEnv.NewPackage()
        local timer = TimerKit:Every(1, function()
            error("tick failed")
        end)

        local ok = pcall(TestEnv.FireNative, 1)
        assert.is_false(ok)
        assert.are.equal("running", timer:GetState())
        assert.is_true(timer:IsPending())
    end)
end)
