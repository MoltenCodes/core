local TestEnv = require("EventKitTestEnv")

local function expectErrorContaining(expected, callback)
    local ok, message = pcall(callback)
    assert.is_false(ok)
    assert.is_not_nil(string.find(tostring(message), expected, 1, true))
end

describe("EventKit errors", function()
    local EventKit
    before_each(function() EventKit = TestEnv.NewPackage() end)
    after_each(TestEnv.Reset)

    it("rejects invalid event names", function()
        expectErrorContaining("eventName must be a non-empty string", function() EventKit:Connect("", function() end) end)
        expectErrorContaining("eventName must be a non-empty string", function() EventKit:Connect(42, function() end) end)
    end)

    it("rejects non-function callbacks", function()
        expectErrorContaining("callback must be a function", function() EventKit:Connect("PLAYER_LOGIN", "nope") end)
    end)

    it("requires at least one unit token", function()
        expectErrorContaining("requires at least one unit token", function() EventKit:ConnectUnit("UNIT_HEALTH", function() end) end)
    end)

    it("rejects invalid unit tokens", function()
        expectErrorContaining("unit tokens must be non-empty strings", function()
            EventKit:ConnectUnit("UNIT_HEALTH", function() end, "player", nil)
        end)
    end)

    it("reports missing CreateFrame lazily", function()
        rawset(_G, "CreateFrame", nil)
        expectErrorContaining("requires the World of Warcraft CreateFrame API", function()
            EventKit:Connect("PLAYER_LOGIN", function() end)
        end)
    end)

    it("does not retain a channel after RegisterEvent rejects it", function()
        TestEnv.FailNextRegisterEvent()
        expectErrorContaining("could not register event", function() EventKit:Connect("PLAYER_LOGIN", function() end) end)
        local frame = TestEnv.Frames()[1]
        assert.is_nil(frame.registrations.PLAYER_LOGIN)
        local connection = EventKit:Connect("PLAYER_LOGIN", function() end)
        assert.is_true(connection:IsConnected())
        assert.are.equal(2, #frame.registerEventCalls)
    end)

    it("does not retain a channel after RegisterUnitEvent rejects it", function()
        TestEnv.FailNextRegisterUnitEvent()
        expectErrorContaining("could not register event", function()
            EventKit:ConnectUnit("UNIT_HEALTH", function() end, "player")
        end)
        local frame = TestEnv.Frames()[1]
        assert.is_nil(frame.registrations.UNIT_HEALTH)
        local connection = EventKit:ConnectUnit("UNIT_HEALTH", function() end, "player")
        assert.is_true(connection:IsConnected())
        assert.are.equal(2, #frame.registerUnitEventCalls)
    end)

    it("propagates listener errors and aborts later listeners", function()
        local laterCalls = 0
        EventKit:Connect("CUSTOM_EVENT", function() error("listener failure") end)
        EventKit:Connect("CUSTOM_EVENT", function() laterCalls = laterCalls + 1 end)
        expectErrorContaining("listener failure", function() TestEnv.Emit("CUSTOM_EVENT") end)
        assert.are.equal(0, laterCalls)
    end)
end)
