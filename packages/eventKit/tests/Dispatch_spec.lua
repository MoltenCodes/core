local TestEnv = require("EventKitTestEnv")

---Measures the allocation a workload causes, in kilobytes, with the collector
---stopped so that a collection cycle cannot hide or invent growth.
local function allocatedKilobytes(workload)
    collectgarbage()
    collectgarbage("stop")
    local before = collectgarbage("count")
    workload()
    local after = collectgarbage("count")
    collectgarbage("restart")
    return after - before
end

describe("EventKit dispatch", function()
    local EventKit
    before_each(function()
        EventKit = TestEnv.NewPackage()
    end)
    after_each(TestEnv.Reset)

    it("forwards event name and preserves nil payload positions", function()
        local count, eventName, first, second, third
        EventKit:Connect("CUSTOM_EVENT", function(...)
            count = select("#", ...)
            eventName, first, second, third = ...
        end)
        TestEnv.Emit("CUSTOM_EVENT", "player", nil, 42)
        assert.are.equal(4, count)
        assert.are.equal("CUSTOM_EVENT", eventName)
        assert.are.equal("player", first)
        assert.is_nil(second)
        assert.are.equal(42, third)
    end)

    it("runs listeners in connection order", function()
        local calls = {}
        EventKit:Connect("CUSTOM_EVENT", function()
            calls[#calls + 1] = "first"
        end)
        EventKit:Connect("CUSTOM_EVENT", function()
            calls[#calls + 1] = "second"
        end)
        TestEnv.Emit("CUSTOM_EVENT")
        assert.are.equal("first", calls[1])
        assert.are.equal("second", calls[2])
    end)

    it("does not deliver unrelated events", function()
        local calls = 0
        EventKit:Connect("PLAYER_LOGIN", function()
            calls = calls + 1
        end)
        TestEnv.Emit("PLAYER_LOGOUT")
        assert.are.equal(0, calls)
    end)

    it("does not run a listener added during the current dispatch", function()
        local calls = 0
        local added = false
        EventKit:Connect("CUSTOM_EVENT", function()
            calls = calls + 1
            if not added then
                added = true
                EventKit:Connect("CUSTOM_EVENT", function()
                    calls = calls + 10
                end)
            end
        end)
        TestEnv.Emit("CUSTOM_EVENT")
        assert.are.equal(1, calls)
        TestEnv.Emit("CUSTOM_EVENT")
        assert.are.equal(12, calls)
    end)

    it("allows an earlier listener to disconnect a later listener", function()
        local calls = {}
        local second
        EventKit:Connect("CUSTOM_EVENT", function()
            calls[#calls + 1] = "first"
            second:Disconnect()
        end)
        second = EventKit:Connect("CUSTOM_EVENT", function()
            calls[#calls + 1] = "second"
        end)
        TestEnv.Emit("CUSTOM_EVENT")
        assert.are.equal(1, #calls)
        assert.are.equal("first", calls[1])
    end)

    it("lets a listener disconnect a connection on a different event mid-dispatch", function()
        local otherCalls = 0
        local other = EventKit:Connect("OTHER_EVENT", function()
            otherCalls = otherCalls + 1
        end)
        local frame = TestEnv.Frames()[1]

        EventKit:Connect("CUSTOM_EVENT", function()
            other:Disconnect()
        end)

        TestEnv.Emit("CUSTOM_EVENT")

        assert.is_false(other:IsConnected())
        assert.is_nil(frame.registrations.OTHER_EVENT)

        TestEnv.Emit("OTHER_EVENT")

        assert.are.equal(0, otherCalls)
    end)

    it("lets a listener release a unit group mid-dispatch", function()
        local unitConnection = EventKit:ConnectUnit("UNIT_HEALTH", function() end, "player")

        EventKit:Connect("CUSTOM_EVENT", function()
            unitConnection:Disconnect()
        end)

        TestEnv.Emit("CUSTOM_EVENT")

        assert.is_false(unitConnection:IsConnected())
        assert.is_nil(next(EventKit._state.unitGroups))
        assert.are.equal(1, #EventKit._state.unitFrames)
    end)

    it("resolves the dispatcher through shared state on every event", function()
        -- Frames created by implementation revision 1 resolve dispatch through
        -- the reserved facade fields instead. Both must keep pointing at the
        -- current dispatchers so an in-place upgrade keeps existing Frames alive.
        assert.are.equal("function", type(EventKit._state.dispatchRegular))
        assert.are.equal("function", type(EventKit._state.dispatchUnit))
        assert.are.equal(EventKit._state.dispatchRegular, EventKit._DispatchRegular)
        assert.are.equal(EventKit._state.dispatchUnit, EventKit._DispatchUnit)

        local calls = 0
        EventKit:Connect("CUSTOM_EVENT", function()
            calls = calls + 1
        end)

        EventKit._DispatchRegular(EventKit, "CUSTOM_EVENT")

        assert.are.equal(1, calls)
    end)

    it("allocates nothing per event, isolation included #allocation", function()
        local sink = 0
        for _ = 1, 8 do
            EventKit:Connect("CUSTOM_EVENT", function(_, first, second)
                sink = sink + first + second
            end)
        end

        -- Tolerance covers interpreter bookkeeping unrelated to dispatch. A
        -- per-event closure or argument table would be orders of magnitude
        -- larger than this across 20000 events.
        local allocated = allocatedKilobytes(function()
            for _ = 1, 20000 do
                TestEnv.Emit("CUSTOM_EVENT", 1, 2)
            end
        end)

        assert.is_true(allocated < 4)
    end)

    it(
        "allocates nothing per event for payloads wider than the inline slots #allocation",
        function()
            local sink = 0
            for _ = 1, 8 do
                EventKit:Connect("WIDE_EVENT", function(...)
                    sink = sink + select("#", ...)
                end)
            end

            local allocated = allocatedKilobytes(function()
                for _ = 1, 20000 do
                    TestEnv.Emit("WIDE_EVENT", 1, 2, 3, 4, 5, 6, 7, 8, 9, 10)
                end
            end)

            assert.is_true(allocated < 4)
        end
    )

    it("supports nested dispatch with mutations visible to the nested call", function()
        local calls = {}
        local nested = false
        EventKit:Connect("CUSTOM_EVENT", function(_, value)
            calls[#calls + 1] = "first:" .. value
            if not nested then
                nested = true
                EventKit:Connect("CUSTOM_EVENT", function(_, inner)
                    calls[#calls + 1] = "new:" .. inner
                end)
                TestEnv.Emit("CUSTOM_EVENT", "nested")
            end
        end)
        TestEnv.Emit("CUSTOM_EVENT", "outer")
        assert.are.equal("first:outer", calls[1])
        assert.are.equal("first:nested", calls[2])
        assert.are.equal("new:nested", calls[3])
        assert.are.equal(3, #calls)
    end)
end)
