local TestEnv = require("ReadinessKitTestEnv")

-- Each workload repeats its operation many times, so a single allocation per
-- call would show up as tens of kilobytes. The threshold leaves room for the
-- few bytes the measurement itself can cost.
local ITERATIONS = 2000
local THRESHOLD_KILOBYTES = 1

describe("ReadinessKit allocation #allocation", function()
    local ReadinessKit
    before_each(function()
        ReadinessKit = TestEnv.NewPackage()
    end)
    after_each(TestEnv.Reset)

    it("allocates nothing on a poll tick while the gate is not ready", function()
        local gate = ReadinessKit:Gate("spellbook", function()
            return false
        end, { timeoutSeconds = false })
        gate:Await(function() end)

        -- Call the native ticker's callback the way the host does. The
        -- fixture's `FireNative` checks its argument with luassert, which
        -- allocates on every call and would drown the measurement.
        local native = TestEnv.NativeTimers()[1]
        local tick = native.callback
        tick(native)

        local allocated = TestEnv.AllocatedKilobytes(function()
            for _ = 1, ITERATIONS do
                TestEnv.AdvanceMs(500)
                tick(native)
            end
        end)
        assert.is_true(
            allocated < THRESHOLD_KILOBYTES,
            "poll tick allocated " .. allocated .. " KiB"
        )
        assert.is_false(gate:IsReady())
    end)

    it("allocates nothing for IsReady and a negatively cached Probe", function()
        local gate = ReadinessKit:Gate("spellbook", function()
            return false
        end)

        local allocated = TestEnv.AllocatedKilobytes(function()
            for _ = 1, ITERATIONS do
                gate:IsReady()
                gate:Probe()
            end
        end)
        assert.is_true(allocated < THRESHOLD_KILOBYTES, "IsReady allocated " .. allocated .. " KiB")
    end)
end)
