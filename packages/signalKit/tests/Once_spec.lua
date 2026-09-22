local TestEnv = require("SignalKitTestEnv")

describe("SignalKit Once", function()
    local SignalKit
    local signal

    before_each(function()
        SignalKit = TestEnv.NewPackage()
        signal = SignalKit:New()
    end)

    after_each(TestEnv.Reset)

    it("runs exactly once across sequential fires", function()
        local calls = 0
        local connection = signal:Once(function()
            calls = calls + 1
        end)

        signal:Fire()
        signal:Fire()

        assert.are.equal(1, calls)
        assert.is_false(connection:IsConnected())
    end)

    it("disconnects before invoking the callback", function()
        local connectedDuringCallback
        local connection

        connection = signal:Once(function()
            connectedDuringCallback = connection:IsConnected()
        end)

        signal:Fire()

        assert.is_false(connectedDuringCallback)
    end)

    it("does not run a second time during recursive Fire", function()
        local calls = 0

        signal:Once(function()
            calls = calls + 1
            signal:Fire()
        end)

        signal:Fire()

        assert.are.equal(1, calls)
    end)

    it("does not run a Once connected during the current dispatch", function()
        local calls = {}
        local connected = false
        local once

        signal:Connect(function()
            calls[#calls + 1] = "existing"
            if not connected then
                connected = true
                once = signal:Once(function()
                    calls[#calls + 1] = "once"
                end)
            end
        end)

        signal:Fire()

        assert.are.equal(1, #calls)
        assert.are.equal("existing", calls[1])
        assert.is_true(once:IsConnected())

        signal:Fire()

        assert.are.equal(3, #calls)
        assert.are.equal("existing", calls[2])
        assert.are.equal("once", calls[3])
        assert.is_false(once:IsConnected())

        signal:Fire()

        assert.are.equal(4, #calls)
        assert.are.equal("existing", calls[4])
    end)

    it("runs a Once connected during a dispatch when a nested Fire follows it", function()
        -- A nested Fire captures the then-current array, so unlike the outer
        -- dispatch it does observe the listener the outer callback just added.
        local calls = {}
        local nested = false

        signal:Connect(function()
            calls[#calls + 1] = "existing"
            if not nested then
                nested = true
                signal:Once(function()
                    calls[#calls + 1] = "once"
                end)
                signal:Fire()
            end
        end)

        signal:Fire()

        assert.are.equal(3, #calls)
        assert.are.equal("existing", calls[1])
        assert.are.equal("existing", calls[2])
        assert.are.equal("once", calls[3])

        signal:Fire()

        assert.are.equal(4, #calls)
        assert.are.equal("existing", calls[4])
    end)

    it("remains disconnected when its callback errors", function()
        local connection = signal:Once(function()
            error("once failure")
        end)

        local ok = pcall(function()
            signal:Fire()
        end)

        assert.is_false(ok)
        assert.is_false(connection:IsConnected())
    end)
end)
