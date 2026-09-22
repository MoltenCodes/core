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
