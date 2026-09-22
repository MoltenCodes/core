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
