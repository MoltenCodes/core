local TestEnv = require("SignalKitTestEnv")

local function expectErrorContaining(expected, callback)
    local ok, message = pcall(callback)

    assert.is_false(ok)
    assert.is_not_nil(string.find(tostring(message), expected, 1, true))
end

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
