local TestEnv = require("TimerKitTestEnv")

-- The fixture's `GetTimePreciseSec` reads the wall clock `AdvanceMs` moves, so
-- every expectation below is exact rather than approximate.
local function noop() end

describe("TimerKit remaining time", function()
    local TimerKit
    before_each(function()
        TimerKit = TestEnv.NewPackage()
    end)
    after_each(TestEnv.Reset)

    it("reports the remaining seconds and the deadline of a running one-shot", function()
        TestEnv.AdvanceMs(10000)
        local timer = TimerKit:After(2, noop)

        assert.are.equal(12, timer:GetDeadline())
        assert.are.equal(2, timer:GetRemaining())

        TestEnv.AdvanceMs(500)
        assert.are.equal(12, timer:GetDeadline())
        assert.are.equal(1.5, timer:GetRemaining())
    end)

    it("reports the next tick of a repeating timer after two ticks", function()
        local ticker = TimerKit:Every(1, noop)
        assert.are.equal(1, ticker:GetDeadline())

        TestEnv.AdvanceMs(1000)
        TestEnv.FireNative(1)
        TestEnv.AdvanceMs(1000)
        TestEnv.FireNative(1)

        assert.are.equal(3, ticker:GetDeadline())
        TestEnv.AdvanceMs(250)
        assert.are.equal(0.75, ticker:GetRemaining())
    end)

    it("reports nil, never zero, for a cancelled timer", function()
        local timer = TimerKit:After(2, noop)
        timer:Cancel()

        assert.is_nil(timer:GetRemaining())
        assert.is_nil(timer:GetDeadline())
    end)

    it("reports nil for a completed one-shot, including inside its own callback", function()
        local remainingDuringCallback = "not called"
        local timer = TimerKit:After(1, function(self)
            remainingDuringCallback = self:GetRemaining()
        end)

        TestEnv.AdvanceMs(1000)
        TestEnv.FireNative(1)

        assert.is_nil(remainingDuringCallback)
        assert.is_nil(timer:GetRemaining())
        assert.is_nil(timer:GetDeadline())
    end)

    it("reports nil for an idle timer that was never started", function()
        local timer = TimerKit:New({ delay = 3, callback = noop })

        assert.is_nil(timer:GetRemaining())
        assert.is_nil(timer:GetDeadline())
    end)

    it("resets the deadline on restart", function()
        local timer = TimerKit:After(2, noop)
        TestEnv.AdvanceMs(1500)
        assert.are.equal(0.5, timer:GetRemaining())

        timer:Restart()

        assert.are.equal(3.5, timer:GetDeadline())
        assert.are.equal(2, timer:GetRemaining())
    end)

    it("reports zero rather than a negative value while the host is late", function()
        local timer = TimerKit:After(1, noop)
        TestEnv.AdvanceMs(1200)

        assert.is_true(timer:IsPending())
        assert.are.equal(0, timer:GetRemaining())
        assert.are.equal(1, timer:GetDeadline())
    end)

    it("clears the deadline when a host failure rolls a start back", function()
        local timer = TimerKit:New({ delay = 1, callback = noop })
        TestEnv.FailNextCreate("host refused")

        assert.has_error(function()
            timer:Start()
        end)
        assert.is_nil(timer:GetRemaining())
        assert.is_nil(timer:GetDeadline())
    end)

    it("points receiver errors at the calling line", function()
        local function callWithoutReceiver()
            TimerKit.Timer.GetRemaining({})
        end

        local function callDeadlineWithoutReceiver()
            TimerKit.Timer.GetDeadline(nil)
        end

        local calls = { callWithoutReceiver, callDeadlineWithoutReceiver }
        for index = 1, #calls do
            local ok, message = pcall(calls[index])
            message = tostring(message)
            assert.is_false(ok)
            assert.is_not_nil(string.find(message, "must be called on a TimerKit timer", 1, true))
            assert.is_not_nil(
                string.find(message, "packages/timerKit/tests/Remaining_spec.lua:", 1, true)
            )
        end
    end)
end)
