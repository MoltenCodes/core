local TestEnv = require("SignalKitTestEnv")

local SPEC_FILE = "packages/signalKit/tests/Generation_spec.lua:"

---Assert that `callback` raises a message naming `expected` at this spec file's
---line rather than somewhere inside the package.
---@param expected string
---@param callback fun()
local function expectRefusalAtCaller(expected, callback)
    local ok, message = pcall(callback)
    message = tostring(message)

    assert.is_false(ok)
    assert.is_not_nil(string.find(message, expected, 1, true), message)
    assert.is_not_nil(string.find(message, SPEC_FILE, 1, true), message)
    assert.is_nil(string.find(message, "src/SignalKit.lua", 1, true), message)
end

describe("SignalKit GetGeneration", function()
    local SignalKit

    before_each(function()
        SignalKit = TestEnv.NewPackage()
    end)

    after_each(TestEnv.Reset)

    it("starts at 0 and increments on every Fire, listeners or not", function()
        local signal = SignalKit:New()
        assert.are.equal(0, signal:GetGeneration())

        signal:Fire()
        assert.are.equal(1, signal:GetGeneration())

        signal:Connect(function() end)
        signal:Fire("payload")
        signal:Fire()
        assert.are.equal(3, signal:GetGeneration())
    end)

    it("is per signal", function()
        local first = SignalKit:New()
        local second = SignalKit:New()
        first:Fire()
        first:Fire()

        assert.are.equal(2, first:GetGeneration())
        assert.are.equal(0, second:GetGeneration())
    end)

    it("moves before listeners run, so a nested Fire is a later generation", function()
        local signal = SignalKit:New()
        local seen = {}
        local nested = false
        signal:Connect(function()
            seen[#seen + 1] = signal:GetGeneration()
            if not nested then
                nested = true
                signal:Fire()
            end
        end)

        signal:Fire()

        assert.are.same({ 1, 2 }, seen)
        assert.are.equal(2, signal:GetGeneration())
    end)

    it("moves even when a listener raises", function()
        local signal = SignalKit:New()
        signal:Connect(function()
            error("listener failure")
        end)

        pcall(function()
            signal:Fire()
        end)

        assert.are.equal(1, signal:GetGeneration())
    end)

    it("is not moved by connects, disconnects or DisconnectAll", function()
        local signal = SignalKit:New()
        local connection = signal:Connect(function() end)
        connection:Disconnect()
        signal:Connect(function() end)
        signal:DisconnectAll()

        assert.are.equal(0, signal:GetGeneration())
    end)

    it("supports the changed-since-I-looked pattern", function()
        local signal = SignalKit:New()
        local lastSeen = signal:GetGeneration()

        assert.is_false(signal:GetGeneration() ~= lastSeen)
        signal:Fire()
        assert.is_true(signal:GetGeneration() ~= lastSeen)
        lastSeen = signal:GetGeneration()
        assert.is_false(signal:GetGeneration() ~= lastSeen)
    end)

    it("reports 0 for a signal created before the counter existed", function()
        -- Revision 6 signals carry no `_generation`; a revision-7 upgrade lands
        -- on live instances, so the first read and the first Fire must tolerate
        -- its absence.
        local signal = SignalKit:New()
        rawset(signal, "_generation", nil)

        assert.are.equal(0, signal:GetGeneration())
        signal:Fire()
        assert.are.equal(1, signal:GetGeneration())
    end)

    it("refuses a call without a signal receiver at the caller", function()
        expectRefusalAtCaller(
            "SignalKit:GetGeneration must be called on a signal instance; use signal:GetGeneration()",
            function()
                SignalKit.GetGeneration()
            end
        )
        expectRefusalAtCaller(
            "SignalKit:GetGeneration must be called on a signal instance",
            function()
                SignalKit.GetGeneration({})
            end
        )
    end)
end)
