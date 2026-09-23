local TestEnv = require("ReadinessKitTestEnv")

describe("ReadinessKit probes that raise", function()
    local ReadinessKit
    before_each(function()
        ReadinessKit = TestEnv.NewPackage()
    end)
    after_each(TestEnv.Reset)

    it("reports the error, counts as not ready and keeps polling", function()
        local calls = 0
        local gate = ReadinessKit:Gate("broken", function()
            calls = calls + 1
            if calls < 3 then
                error("probe failure " .. calls, 0)
            end
            return true
        end)
        assert.is_false(gate:IsReady())
        assert.are.same({ "probe failure 1" }, TestEnv.ReportedErrors())
        assert.are.equal(1, TestEnv.ArmedTimerCount())

        TestEnv.Poll(500)
        assert.is_false(gate:IsReady())
        assert.are.same({ "probe failure 1", "probe failure 2" }, TestEnv.ReportedErrors())

        TestEnv.Poll(500)
        assert.is_true(gate:IsReady())
        assert.are.equal(0, TestEnv.ArmedTimerCount())
    end)

    it("returns false from Probe and caches the failure like a negative answer", function()
        local calls = 0
        local gate = ReadinessKit:Gate("broken", function()
            calls = calls + 1
            error("probe failure", 0)
        end)
        TestEnv.AdvanceMs(500)
        assert.is_false(gate:Probe())
        assert.is_false(gate:Probe())
        assert.are.equal(2, calls)
        assert.are.equal(2, #TestEnv.ReportedErrors())
    end)

    it("prints the error when the host has no error handler", function()
        -- The fixture removes this global between specs; a host without it is what is being modelled.
        -- selene: allow(global_usage)
        rawset(_G, "geterrorhandler", nil)
        local printed = {}
        local originalPrint = print
        -- Replacing print is the only way to observe the documented fallback.
        -- selene: allow(global_usage)
        rawset(_G, "print", function(value)
            printed[#printed + 1] = value
        end)
        local ok = pcall(ReadinessKit.Gate, ReadinessKit, "broken", function()
            error("probe failure", 0)
        end)
        -- selene: allow(global_usage)
        rawset(_G, "print", originalPrint)
        assert.is_true(ok)
        assert.are.same({ "probe failure" }, printed)
    end)
end)
