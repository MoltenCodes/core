local Env = require("LogKitTestEnv")

-- Each workload repeats its operation many times, so a single allocation per
-- call would show up as tens of kilobytes. The threshold leaves room for the
-- few bytes the measurement itself can cost.
local ITERATIONS = 2000
local THRESHOLD_KILOBYTES = 1

describe("LogKit allocation #allocation", function()
    local LogKit, logger

    before_each(function()
        LogKit = Env.NewPackage()
        logger = LogKit:ForAddon("MyAddon")
    end)
    after_each(function()
        Env.Reset()
    end)

    it("allocates nothing for a disabled call with format arguments", function()
        local payload = {}
        local allocated = Env.AllocatedKilobytes(function()
            for index = 1, ITERATIONS do
                logger:Debug("value %s %d %s", payload, index, "text")
                logger:Trace("bare")
                logger:Log("info", "value %s", payload)
            end
        end)
        assert.is_true(
            allocated < THRESHOLD_KILOBYTES,
            "disabled calls allocated " .. allocated .. " KiB"
        )
    end)

    it(
        "allocates nothing for an enabled bare message delivered to a sink and the journal",
        function()
            local count = 0
            LogKit:AddSink(function(record)
                if record.message == "bare" then
                    count = count + 1
                end
            end)
            local allocated = Env.AllocatedKilobytes(function()
                for _ = 1, ITERATIONS do
                    logger:Warn("bare")
                end
            end)
            assert.are.equal(ITERATIONS * 2, count)
            assert.is_true(
                allocated < THRESHOLD_KILOBYTES,
                "bare messages allocated " .. allocated .. " KiB"
            )
        end
    )

    it("allocates only the formatted string for an enabled formatted message", function()
        -- A format whose result is the same string every time exercises the
        -- staging, `pcall`, `string.format`, truncation, journal and sink
        -- paths while the interned result is not a new allocation.
        local sink = { count = 0 }
        function sink:Write()
            self.count = self.count + 1
        end
        LogKit:AddSink(sink)
        local allocated = Env.AllocatedKilobytes(function()
            for _ = 1, ITERATIONS do
                logger:Error("%s has %d items", "bag", 12)
                logger:Error("%s %s", true, nil)
            end
        end)
        assert.are.equal(ITERATIONS * 4, sink.count)
        assert.is_true(
            allocated < THRESHOLD_KILOBYTES,
            "formatted messages allocated " .. allocated .. " KiB"
        )
    end)

    it("allocates nothing to check IsEnabled and GetLevel", function()
        local allocated = Env.AllocatedKilobytes(function()
            for _ = 1, ITERATIONS do
                logger:IsEnabled("debug")
                logger:IsEnabled(LogKit.LEVELS.error)
                logger:GetLevel()
            end
        end)
        assert.is_true(
            allocated < THRESHOLD_KILOBYTES,
            "IsEnabled allocated " .. allocated .. " KiB"
        )
    end)

    it("allocates nothing to walk the history, filtered or not", function()
        LogKit:ForAddon("Other"):Warn("other")
        for index = 1, 50 do
            logger:Warn("message " .. index)
        end
        local seen = 0
        local allocated = Env.AllocatedKilobytes(function()
            for _ = 1, 100 do
                for _ in LogKit:History() do
                    seen = seen + 1
                end
                for _ in LogKit:History("MyAddon", "warn") do
                    seen = seen + 1
                end
            end
        end)
        assert.are.equal(100 * (51 + 50) * 2, seen)
        assert.is_true(allocated < THRESHOLD_KILOBYTES, "History allocated " .. allocated .. " KiB")
    end)
end)
