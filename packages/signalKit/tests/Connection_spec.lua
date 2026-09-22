local TestEnv = require("SignalKitTestEnv")

describe("SignalKit connections", function()
    local SignalKit
    local signal

    before_each(function()
        SignalKit = TestEnv.NewPackage()
        signal = SignalKit:New()
    end)

    after_each(TestEnv.Reset)

    it("returns a connected handle from Connect", function()
        local connection = signal:Connect(function() end)

        assert.is_true(connection:IsConnected())
    end)

    it("disconnects a listener", function()
        local calls = 0
        local connection = signal:Connect(function()
            calls = calls + 1
        end)

        assert.is_true(connection:Disconnect())
        signal:Fire()

        assert.is_false(connection:IsConnected())
        assert.are.equal(0, calls)
    end)

    it("makes Disconnect idempotent", function()
        local connection = signal:Connect(function() end)

        assert.is_true(connection:Disconnect())
        assert.is_false(connection:Disconnect())
        assert.is_false(connection:IsConnected())
    end)

    it("disconnects only the selected connection", function()
        local firstCalls = 0
        local secondCalls = 0
        local first = signal:Connect(function()
            firstCalls = firstCalls + 1
        end)
        signal:Connect(function()
            secondCalls = secondCalls + 1
        end)

        first:Disconnect()
        signal:Fire()

        assert.are.equal(0, firstCalls)
        assert.are.equal(1, secondCalls)
    end)

    it("disconnects all current listeners and returns their count", function()
        local first = signal:Connect(function() end)
        local second = signal:Connect(function() end)
        local third = signal:Once(function() end)

        assert.are.equal(3, signal:DisconnectAll())
        assert.is_false(first:IsConnected())
        assert.is_false(second:IsConnected())
        assert.is_false(third:IsConnected())
        assert.are.equal(0, signal:DisconnectAll())
    end)

    it("allows a disconnected connection to be garbage-collectable from the signal", function()
        local connection = signal:Connect(function() end)
        connection:Disconnect()

        assert.is_false(connection:IsConnected())
        signal:Fire()
        assert.is_false(connection:IsConnected())
    end)
end)
