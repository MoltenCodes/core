local TestEnv = require("EventKitTestEnv")

describe("EventKit registration lifecycle", function()
    local EventKit
    before_each(function() EventKit = TestEnv.NewPackage() end)
    after_each(TestEnv.Reset)

    it("creates no Frame before the first subscription", function()
        assert.are.equal(0, #TestEnv.Frames())
    end)

    it("registers normal events lazily", function()
        EventKit:Connect("PLAYER_LOGIN", function() end)
        local frame = TestEnv.Frames()[1]
        assert.are.equal(1, #TestEnv.Frames())
        assert.are.equal("PLAYER_LOGIN", frame.registerEventCalls[1])
    end)

    it("shares one registration for listeners of the same event", function()
        EventKit:Connect("PLAYER_LOGIN", function() end)
        EventKit:Connect("PLAYER_LOGIN", function() end)
        assert.are.equal(1, #TestEnv.Frames()[1].registerEventCalls)
    end)

    it("shares one regular Frame across different event names", function()
        EventKit:Connect("PLAYER_LOGIN", function() end)
        EventKit:Connect("PLAYER_LOGOUT", function() end)
        assert.are.equal(1, #TestEnv.Frames())
        assert.are.equal(2, #TestEnv.Frames()[1].registerEventCalls)
    end)

    it("unregisters only after the final listener disconnects", function()
        local first = EventKit:Connect("PLAYER_LOGIN", function() end)
        local second = EventKit:Connect("PLAYER_LOGIN", function() end)
        local frame = TestEnv.Frames()[1]
        first:Disconnect()
        assert.are.equal(0, #frame.unregisterEventCalls)
        second:Disconnect()
        assert.are.equal(1, #frame.unregisterEventCalls)
        assert.are.equal("PLAYER_LOGIN", frame.unregisterEventCalls[1])
    end)

    it("re-registers after all listeners have disconnected", function()
        local first = EventKit:Connect("PLAYER_LOGIN", function() end)
        local frame = TestEnv.Frames()[1]
        first:Disconnect()
        EventKit:Connect("PLAYER_LOGIN", function() end)
        assert.are.equal(2, #frame.registerEventCalls)
    end)
end)
