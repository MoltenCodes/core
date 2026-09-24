local TestEnv = require("SignalKitTestEnv")

local expectErrorContaining = TestEnv.expectErrorContaining

describe("SignalKit errors", function()
    local SignalKit
    local signal

    before_each(function()
        SignalKit = TestEnv.NewPackage()
        signal = SignalKit:New()
    end)

    after_each(TestEnv.Reset)

    it("rejects non-function Connect callbacks", function()
        expectErrorContaining("callback must be a function", function()
            signal:Connect("not a function")
        end)
    end)

    it("rejects non-function Once callbacks", function()
        expectErrorContaining("SignalKit:Once callback must be a function", function()
            signal:Once({})
        end)
    end)

    it("names the misuse when a signal method is called without a receiver", function()
        expectErrorContaining("SignalKit:Connect must be called on a signal instance", function()
            SignalKit.Connect(function() end)
        end)

        expectErrorContaining("SignalKit:Once must be called on a signal instance", function()
            SignalKit.Once(function() end)
        end)

        expectErrorContaining("SignalKit:Fire must be called on a signal instance", function()
            SignalKit.Fire("payload")
        end)

        expectErrorContaining(
            "SignalKit:DisconnectAll must be called on a signal instance",
            function()
                SignalKit.DisconnectAll()
            end
        )
    end)

    it("names the misuse when a connection method is called without a receiver", function()
        expectErrorContaining(
            "SignalKit:Disconnect must be called on a connection handle",
            function()
                SignalKit.Connection.Disconnect()
            end
        )

        expectErrorContaining(
            "SignalKit:IsConnected must be called on a connection handle",
            function()
                SignalKit.Connection.IsConnected()
            end
        )
    end)

    it("rejects a receiver that is not a signal at all", function()
        expectErrorContaining("must be called on a signal instance", function()
            SignalKit.Fire({}, "payload")
        end)

        expectErrorContaining("must be called on a signal instance", function()
            SignalKit.Connect("not a signal", function() end)
        end)
    end)

    it("points receiver and argument errors at the calling line", function()
        local function callConnectWithoutReceiver()
            SignalKit.Connect(function() end)
        end

        local function callFireWithoutReceiver()
            SignalKit.Fire()
        end

        local function callConnectWithABadCallback()
            signal:Connect("not a function")
        end

        local calls = {
            callConnectWithoutReceiver,
            callFireWithoutReceiver,
            callConnectWithABadCallback,
        }

        for index = 1, #calls do
            local ok, message = pcall(calls[index])
            message = tostring(message)

            assert.is_false(ok)
            assert.is_not_nil(
                string.find(message, "packages/signalKit/tests/Errors_spec.lua:", 1, true)
            )
            assert.is_nil(string.find(message, "src/SignalKit.lua", 1, true))
        end
    end)

    it("propagates listener errors and aborts the current Fire", function()
        local laterCalls = 0

        signal:Connect(function()
            error("listener failure")
        end)
        signal:Connect(function()
            laterCalls = laterCalls + 1
        end)

        expectErrorContaining("listener failure", function()
            signal:Fire()
        end)

        assert.are.equal(0, laterCalls)
    end)

    it("remains usable after a listener error", function()
        local failing = signal:Connect(function()
            error("listener failure")
        end)
        local calls = 0

        pcall(function()
            signal:Fire()
        end)
        failing:Disconnect()
        signal:Connect(function()
            calls = calls + 1
        end)

        signal:Fire()

        assert.are.equal(1, calls)
    end)
end)
