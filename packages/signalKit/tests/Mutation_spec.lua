local TestEnv = require("SignalKitTestEnv")

describe("SignalKit mutation during dispatch", function()
    local SignalKit
    local signal

    before_each(function()
        SignalKit = TestEnv.NewPackage()
        signal = SignalKit:New()
    end)

    after_each(TestEnv.Reset)

    it("does not run listeners connected during the current Fire", function()
        local calls = {}
        local added = false

        signal:Connect(function()
            calls[#calls + 1] = "first"
            if not added then
                added = true
                signal:Connect(function()
                    calls[#calls + 1] = "late"
                end)
            end
        end)

        signal:Fire()
        assert.are.equal(1, #calls)
        assert.are.equal("first", calls[1])

        signal:Fire()
        assert.are.equal(3, #calls)
        assert.are.equal("first", calls[2])
        assert.are.equal("late", calls[3])
    end)

    it("skips a later listener disconnected before its turn", function()
        local calls = {}
        local second

        signal:Connect(function()
            calls[#calls + 1] = "first"
            second:Disconnect()
        end)
        second = signal:Connect(function()
            calls[#calls + 1] = "second"
        end)

        signal:Fire()

        assert.are.equal(1, #calls)
        assert.are.equal("first", calls[1])
    end)

    it("allows a listener to disconnect itself without disrupting later listeners", function()
        local calls = {}
        local first

        first = signal:Connect(function()
            calls[#calls + 1] = "first"
            first:Disconnect()
        end)
        signal:Connect(function()
            calls[#calls + 1] = "second"
        end)

        signal:Fire()
        signal:Fire()

        assert.are.equal("first", calls[1])
        assert.are.equal("second", calls[2])
        assert.are.equal("second", calls[3])
        assert.are.equal(3, #calls)
    end)

    it("DisconnectAll prevents remaining callbacks in the current Fire", function()
        local calls = {}

        signal:Connect(function()
            calls[#calls + 1] = "first"
            signal:DisconnectAll()
        end)
        signal:Connect(function()
            calls[#calls + 1] = "second"
        end)

        signal:Fire()

        assert.are.equal(1, #calls)
        assert.are.equal("first", calls[1])
    end)

    it("can connect again after DisconnectAll", function()
        local calls = 0

        signal:Connect(function()
            calls = calls + 100
        end)
        signal:DisconnectAll()
        signal:Connect(function()
            calls = calls + 1
        end)

        signal:Fire()

        assert.are.equal(1, calls)
    end)

    it("preserves order after removing a middle connection", function()
        local calls = {}

        signal:Connect(function()
            calls[#calls + 1] = "first"
        end)
        local middle = signal:Connect(function()
            calls[#calls + 1] = "middle"
        end)
        signal:Connect(function()
            calls[#calls + 1] = "last"
        end)

        middle:Disconnect()
        signal:Fire()

        assert.are.equal("first", calls[1])
        assert.are.equal("last", calls[2])
        assert.are.equal(2, #calls)
    end)
end)
