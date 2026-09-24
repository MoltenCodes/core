local TestEnv = require("SignalKitTestEnv")

-- The listener array is private implementation detail. These specs read it
-- directly because the compaction contract is a retention guarantee, and a
-- retention guarantee that cannot be observed cannot be regression-tested.
local function listenerSlots(signal)
    return #rawget(signal, "_listeners")
end

local function tombstones(signal)
    return rawget(signal, "_tombstones")
end

describe("SignalKit listener compaction", function()
    local SignalKit
    local signal

    before_each(function()
        SignalKit = TestEnv.NewPackage()
        signal = SignalKit:New()
    end)

    after_each(TestEnv.Reset)

    it("leaves a tombstone instead of copying the array on disconnect", function()
        local connections = {}
        for index = 1, 10 do
            connections[index] = signal:Connect(function() end)
        end

        connections[1]:Disconnect()

        assert.are.equal(10, listenerSlots(signal))
        assert.are.equal(1, tombstones(signal))
    end)

    it("compacts once at least half of the array is tombstones", function()
        local connections = {}
        for index = 1, 10 do
            connections[index] = signal:Connect(function() end)
        end

        for index = 1, 4 do
            connections[index]:Disconnect()
        end

        assert.are.equal(10, listenerSlots(signal))
        assert.are.equal(4, tombstones(signal))

        connections[5]:Disconnect()

        assert.are.equal(5, listenerSlots(signal))
        assert.are.equal(0, tombstones(signal))
    end)

    it("never retains more than twice the live listener count", function()
        local connections = {}
        for index = 1, 64 do
            connections[index] = signal:Connect(function() end)
        end

        for index = 1, 64 do
            connections[index]:Disconnect()

            local live = 64 - index
            assert.is_true(listenerSlots(signal) <= math.max(2 * live, 1))
        end

        assert.are.equal(0, listenerSlots(signal))
    end)

    it("keeps connection order across compaction", function()
        local calls = {}
        local connections = {}
        for index = 1, 8 do
            connections[index] = signal:Connect(function()
                calls[#calls + 1] = index
            end)
        end

        for index = 1, 8, 2 do
            connections[index]:Disconnect()
        end

        signal:Fire()

        assert.are.equal(4, #calls)
        assert.are.equal(2, calls[1])
        assert.are.equal(4, calls[2])
        assert.are.equal(6, calls[3])
        assert.are.equal(8, calls[4])
    end)

    it("keeps a dispatch stable when compaction replaces the array underneath it", function()
        local calls = {}
        local connections = {}

        -- Eight listeners: the first disconnects enough of the others to push
        -- the array over the compaction threshold mid-dispatch.
        for index = 1, 8 do
            connections[index] = signal:Connect(function()
                calls[#calls + 1] = index
                if index == 1 then
                    for victim = 2, 5 do
                        connections[victim]:Disconnect()
                    end
                end
            end)
        end

        signal:Fire()

        assert.are.equal(4, #calls)
        assert.are.equal(1, calls[1])
        assert.are.equal(6, calls[2])
        assert.are.equal(7, calls[3])
        assert.are.equal(8, calls[4])
    end)

    it("migrates a signal created before the tombstone counter existed", function()
        -- Implementation revision 1 stored no counter. A revision-2 upgrade
        -- lands on live instances, so every counter read must tolerate its
        -- absence rather than fail on `nil + 1`.
        local first = signal:Connect(function() end)
        local calls = 0
        for _ = 1, 3 do
            signal:Connect(function()
                calls = calls + 1
            end)
        end
        rawset(signal, "_tombstones", nil)

        assert.is_true(first:Disconnect())
        assert.are.equal(1, tombstones(signal))
        assert.are.equal(4, listenerSlots(signal))

        signal:Fire()

        assert.are.equal(3, calls)
    end)
end)

describe("SignalKit allocation behaviour", function()
    local SignalKit
    local signal

    before_each(function()
        SignalKit = TestEnv.NewPackage()
        signal = SignalKit:New()
    end)

    after_each(TestEnv.Reset)

    it("allocates nothing per Fire", function()
        local sink = 0
        for _ = 1, 8 do
            signal:Connect(function(a, b)
                sink = sink + a + b
            end)
        end

        -- Tolerance covers interpreter bookkeeping that is unrelated to the
        -- dispatch path; a per-Fire allocation would be orders of magnitude
        -- larger than this over 20000 iterations.
        local allocated = TestEnv.AllocatedKilobytes(function()
            for _ = 1, 20000 do
                signal:Fire(1, 2)
            end
        end)

        assert.is_true(allocated < 4)
    end)

    it("allocates nothing per Disconnect below the compaction threshold", function()
        local connections = {}
        for index = 1, 4096 do
            connections[index] = signal:Connect(function() end)
        end

        local allocated = TestEnv.AllocatedKilobytes(function()
            for index = 1, 2047 do
                connections[index]:Disconnect()
            end
        end)

        assert.is_true(allocated < 4)
    end)
end)
