local TestEnv = require("CodecKitTestEnv")

-- Each workload repeats its operation many times, so a single allocation per
-- call would show up as tens of kilobytes. The threshold leaves room for the
-- few bytes the measurement itself can cost.
local ITERATIONS = 2000
local THRESHOLD_KILOBYTES = 1

describe("CodecKit allocation", function()
    local CodecKit
    before_each(function()
        CodecKit = TestEnv.NewPackage()
    end)
    after_each(TestEnv.Reset)

    local small = { id = 7, name = "bar", flags = { true, false }, scale = 1.5, [2 ^ 60] = -0.25 }

    ---Run `operation` twice to warm the pool and intern its strings, then
    ---measure `ITERATIONS` more calls.
    local function measure(operation)
        operation()
        operation()
        return TestEnv.AllocatedKilobytes(function()
            for _ = 1, ITERATIONS do
                operation()
            end
        end)
    end

    it("allocates nothing to encode a small table again, on every channel", function()
        for _, channel in ipairs({ "none", "addon", "print" }) do
            local options = { channel = channel }
            local allocated = measure(function()
                CodecKit:Encode(small, options)
            end)
            assert.is_true(
                allocated < THRESHOLD_KILOBYTES,
                channel .. " allocated " .. allocated .. " KiB"
            )
        end
    end)

    it("allocates nothing to decode a scalar frame again", function()
        local frames = {}
        for _, value in ipairs({ true, 42, -1.5, "name" }) do
            frames[#frames + 1] = select(2, CodecKit:Encode(value, { channel = "addon" }))
        end
        local allocated = measure(function()
            for index = 1, #frames do
                CodecKit:Decode(frames[index])
            end
        end)
        assert.is_true(allocated < THRESHOLD_KILOBYTES, "Decode allocated " .. allocated .. " KiB")
    end)

    it("allocates only the decoded tables on a small round trip", function()
        local options = { channel = "addon" }
        local allocated = measure(function()
            local _, text = CodecKit:Encode(small, options)
            CodecKit:Decode(text)
        end)
        -- Two tables per round trip, a few hundred bytes at most.
        assert.is_true(allocated / ITERATIONS < 0.5, "round trip allocated " .. allocated .. " KiB")
    end)

    it("allocates nothing to compress a short message again", function()
        local message = string.rep("sync:42;", 4) -- 32 bytes
        local allocated = measure(function()
            CodecKit:Compress(message)
        end)
        assert.is_true(
            allocated < THRESHOLD_KILOBYTES,
            "Compress allocated " .. allocated .. " KiB"
        )
    end)

    it("returns every leased table and retains a bounded number", function()
        local pool = CodecKit._state.pool
        local big = {}
        for index = 1, 5000 do
            big[index] = { index, tostring(index) }
        end
        for _ = 1, 3 do
            local _, text = CodecKit:Encode(big, { compress = "deflate", channel = "print" })
            assert.is_true((CodecKit:Decode(text)))
            CodecKit:Decode("\1\1\8\5")
            CodecKit:Encode({ print })
        end
        assert.are.equal(0, pool:GetActiveCount())
        assert.is_true(pool:GetAvailableCount() <= 16)
    end)
end)
