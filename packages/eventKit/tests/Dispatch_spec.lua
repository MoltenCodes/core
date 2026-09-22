local TestEnv = require("EventKitTestEnv")

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
