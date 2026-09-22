local TestEnv = require("EventKitTestEnv")

describe("EventKit unit subscriptions", function()
    local EventKit
    before_each(function()
        EventKit = TestEnv.NewPackage()
    end)
    after_each(TestEnv.Reset)

    it("uses RegisterUnitEvent", function()
        EventKit:ConnectUnit("UNIT_HEALTH", function() end, "player")
        local frame = TestEnv.Frames()[1]
        assert.are.equal(1, #frame.registerUnitEventCalls)
        assert.are.equal("UNIT_HEALTH", frame.registerUnitEventCalls[1].eventName)
        assert.are.equal("player", frame.registerUnitEventCalls[1].units[1])
    end)

    it("normalizes equivalent unit sets onto one registration", function()
        EventKit:ConnectUnit("UNIT_HEALTH", function() end, "target", "player", "player")
        EventKit:ConnectUnit("UNIT_HEALTH", function() end, "player", "target")
        local frame = TestEnv.Frames()[1]
        assert.are.equal(1, #TestEnv.Frames())
        assert.are.equal(1, #frame.registerUnitEventCalls)
        assert.are.equal("player", frame.registerUnitEventCalls[1].units[1])
        assert.are.equal("target", frame.registerUnitEventCalls[1].units[2])
    end)

    it("shares one unit-filter Frame across different event names", function()
        EventKit:ConnectUnit("UNIT_HEALTH", function() end, "player")
        EventKit:ConnectUnit("UNIT_POWER_UPDATE", function() end, "player")
        assert.are.equal(1, #TestEnv.Frames())
        assert.are.equal(2, #TestEnv.Frames()[1].registerUnitEventCalls)
    end)

    it("uses separate Frames for different unit filters", function()
        EventKit:ConnectUnit("UNIT_HEALTH", function() end, "player")
        EventKit:ConnectUnit("UNIT_HEALTH", function() end, "target")
        assert.are.equal(2, #TestEnv.Frames())
    end)

    it("delivers only matching unit payloads", function()
        local playerCalls, targetCalls = 0, 0
        EventKit:ConnectUnit("UNIT_HEALTH", function(_, unit)
            assert.are.equal("player", unit)
            playerCalls = playerCalls + 1
        end, "player")
        EventKit:ConnectUnit("UNIT_HEALTH", function(_, unit)
            assert.are.equal("target", unit)
            targetCalls = targetCalls + 1
        end, "target")
        TestEnv.Emit("UNIT_HEALTH", "player")
        TestEnv.Emit("UNIT_HEALTH", "target")
        TestEnv.Emit("UNIT_HEALTH", "focus")
        assert.are.equal(1, playerCalls)
        assert.are.equal(1, targetCalls)
    end)

    it("keeps regular and unit registrations independent", function()
        local regularCalls, unitCalls = 0, 0
        EventKit:Connect("UNIT_HEALTH", function()
            regularCalls = regularCalls + 1
        end)
        EventKit:ConnectUnit("UNIT_HEALTH", function()
            unitCalls = unitCalls + 1
        end, "player")
        TestEnv.Emit("UNIT_HEALTH", "target")
        TestEnv.Emit("UNIT_HEALTH", "player")
        assert.are.equal(2, regularCalls)
        assert.are.equal(1, unitCalls)
    end)

    it("unregisters and reuses the cached unit-filter Frame", function()
        local first = EventKit:ConnectUnit("UNIT_HEALTH", function() end, "player")
        local frame = TestEnv.Frames()[1]
        first:Disconnect()
        assert.is_nil(frame.registrations.UNIT_HEALTH)
        EventKit:ConnectUnit("UNIT_HEALTH", function() end, "player")
        assert.are.equal(1, #TestEnv.Frames())
        assert.are.equal(frame, TestEnv.Frames()[1])
        assert.are.equal(2, #frame.registerUnitEventCalls)
    end)

    it("supports OnceUnit", function()
        local calls = 0
        local connection = EventKit:OnceUnit("UNIT_HEALTH", function(eventName, unit)
            assert.are.equal("UNIT_HEALTH", eventName)
            assert.are.equal("player", unit)
            calls = calls + 1
        end, "player")
        TestEnv.Emit("UNIT_HEALTH", "player")
        TestEnv.Emit("UNIT_HEALTH", "player")
        assert.are.equal(1, calls)
        assert.is_false(connection:IsConnected())
    end)
end)
