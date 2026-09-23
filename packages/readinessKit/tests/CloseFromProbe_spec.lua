local TestEnv = require("ReadinessKitTestEnv")

-- A probe (or something it calls) may close its own gate. Whatever the probe
-- answers, the gate must stay closed afterwards: not ready, no timer, and not
-- revived under its name.

---Assert that `gate` is closed, dormant and no longer registered.
---@param ReadinessKit table
---@param gate table
---@param name string
local function assertStaysClosed(ReadinessKit, gate, name)
    assert.is_true(gate:IsClosed())
    assert.is_false(gate:IsReady())
    assert.is_nil(ReadinessKit:Get(name))
    assert.are.equal(0, TestEnv.ArmedTimerCount())
end

describe("ReadinessKit probe that closes its own gate", function()
    local ReadinessKit
    before_each(function()
        ReadinessKit = TestEnv.NewPackage()
    end)
    after_each(TestEnv.Reset)

    it("stays closed when the defining probe closes it and answers true", function()
        local gate = ReadinessKit:Gate("self", function()
            ReadinessKit:Get("self"):Close()
            return true
        end)
        assertStaysClosed(ReadinessKit, gate, "self")
        assert.are.equal(0, #TestEnv.NativeTimers())
    end)

    it("stays closed when the defining probe closes it and answers false", function()
        local gate = ReadinessKit:Gate("self", function()
            ReadinessKit:Get("self"):Close()
            return false
        end)
        assertStaysClosed(ReadinessKit, gate, "self")
        assert.are.equal(0, #TestEnv.NativeTimers())
    end)

    it("stays closed when a poll's probe closes it and answers true", function()
        local closing = false
        local gate
        gate = ReadinessKit:Gate("poll", function()
            if closing then
                gate:Close()
                return true
            end
            return false
        end)
        local results = {}
        gate:Await(function(ready, reason)
            results[#results + 1] = { ready, reason }
        end)

        closing = true
        TestEnv.Poll(500)
        assertStaysClosed(ReadinessKit, gate, "poll")
        assert.are.same({ { false, "closed" } }, results)
    end)

    it("stays closed when a timing-out poll's probe closes it", function()
        local gate
        gate = ReadinessKit:Gate("poll", function()
            if gate ~= nil then
                gate:Close()
            end
            return false
        end, { timeoutSeconds = 0.5 })
        TestEnv.Poll(500)
        assertStaysClosed(ReadinessKit, gate, "poll")
    end)

    it("returns false from Probe and stays closed", function()
        local closing = false
        local gate
        gate = ReadinessKit:Gate("probe", function()
            if closing then
                gate:Close()
                return true
            end
            return false
        end)
        closing = true
        TestEnv.AdvanceMs(500)
        assert.is_false(gate:Probe())
        assertStaysClosed(ReadinessKit, gate, "probe")
    end)

    it("stays closed when a re-probe event's probe closes it", function()
        local closing = false
        local gate
        gate = ReadinessKit:Gate("event", function()
            if closing then
                gate:Close()
                return true
            end
            return false
        end, { timeoutSeconds = 0.5 })
        gate:ReprobeOn("SPELLS_CHANGED")
        TestEnv.Poll(500)

        closing = true
        TestEnv.Emit("SPELLS_CHANGED")
        assertStaysClosed(ReadinessKit, gate, "event")
    end)
end)
