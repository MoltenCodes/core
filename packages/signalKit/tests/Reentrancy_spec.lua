local TestEnv = require("SignalKitTestEnv")

describe("SignalKit re-entrancy", function()
    local SignalKit
    local signal

    before_each(function()
        SignalKit = TestEnv.NewPackage()
        signal = SignalKit:New()
    end)

    after_each(TestEnv.Reset)

    it("supports recursive Fire with deterministic order", function()
        local calls = {}
        local nested = false

        signal:Connect(function(value)
            calls[#calls + 1] = "first:" .. value
            if not nested then
                nested = true
                signal:Fire("nested")
            end
        end)
        signal:Connect(function(value)
            calls[#calls + 1] = "second:" .. value
        end)

        signal:Fire("outer")

        assert.are.equal("first:outer", calls[1])
        assert.are.equal("first:nested", calls[2])
        assert.are.equal("second:nested", calls[3])
        assert.are.equal("second:outer", calls[4])
        assert.are.equal(4, #calls)
    end)

    it("lets nested Fire observe listeners connected by the outer callback", function()
        local calls = {}
        local nested = false

        signal:Connect(function(value)
            calls[#calls + 1] = "existing:" .. value
            if not nested then
                nested = true
                signal:Connect(function(innerValue)
                    calls[#calls + 1] = "new:" .. innerValue
                end)
                signal:Fire("nested")
            end
        end)

        signal:Fire("outer")

        assert.are.equal("existing:outer", calls[1])
        assert.are.equal("existing:nested", calls[2])
        assert.are.equal("new:nested", calls[3])
        assert.are.equal(3, #calls)
    end)

    it("stops the outer dispatch when a nested Fire calls DisconnectAll", function()
        local calls = {}
        local nested = false

        signal:Connect(function(value)
            calls[#calls + 1] = "first:" .. value
            if not nested then
                nested = true
                signal:Fire("nested")
            end
        end)
        signal:Connect(function(value)
            calls[#calls + 1] = "second:" .. value
            if value == "nested" then
                signal:DisconnectAll()
            end
        end)
        signal:Connect(function(value)
            calls[#calls + 1] = "third:" .. value
        end)

        signal:Fire("outer")

        -- The nested dispatch tears the signal down while the outer dispatch is
        -- still walking its own array. Connection handles are shared between
        -- both arrays, so the outer dispatch sees the teardown immediately and
        -- runs no further listener.
        assert.are.equal(3, #calls)
        assert.are.equal("first:outer", calls[1])
        assert.are.equal("first:nested", calls[2])
        assert.are.equal("second:nested", calls[3])
    end)

    it("leaves a signal reusable after DisconnectAll inside a nested Fire", function()
        local nested = false

        signal:Connect(function()
            if not nested then
                nested = true
                signal:Fire()
            end
        end)
        signal:Connect(function()
            signal:DisconnectAll()
        end)

        signal:Fire()

        local calls = 0
        signal:Connect(function()
            calls = calls + 1
        end)
        signal:Fire()

        assert.are.equal(1, calls)
    end)

    it("lets nested Fire observe a disconnect made by the outer callback", function()
        local calls = {}
        local nested = false
        local second

        signal:Connect(function(value)
            calls[#calls + 1] = "first:" .. value
            if not nested then
                nested = true
                second:Disconnect()
                signal:Fire("nested")
            end
        end)
        second = signal:Connect(function(value)
            calls[#calls + 1] = "second:" .. value
        end)

        signal:Fire("outer")

        assert.are.equal("first:outer", calls[1])
        assert.are.equal("first:nested", calls[2])
        assert.are.equal(2, #calls)
    end)
end)
