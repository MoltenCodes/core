local TestEnv = require("SchedulerKitTestEnv")

---Fire the most recently created native timer.
---@return boolean fired
local function fireLatest()
    return TestEnv.FireNative(#TestEnv.NativeTimers())
end

---Copy a delivered set, which the handle wipes as soon as the callback returns.
local function copy(set)
    local result = {}
    for key, value in pairs(set) do
        result[key] = value
    end
    return result
end

---Assert that `callback` fails with `expected` at a line of this spec file.
local function expectErrorAtThisSpec(expected, callback)
    local ok, message = pcall(callback)
    message = tostring(message)
    assert.is_false(ok)
    assert.is_not_nil(string.find(message, expected, 1, true), message)
    assert.is_not_nil(
        string.find(message, "packages/schedulerKit/tests/Coalesce_spec.lua:", 1, true),
        message
    )
end

describe("SchedulerKit Coalesce", function()
    after_each(TestEnv.Reset)

    it("collects keys for one interval and delivers them once", function()
        local SchedulerKit = TestEnv.NewPackage()
        local deliveries = {}
        local coalesced = SchedulerKit:Coalesce(function(set)
            deliveries[#deliveries + 1] = copy(set)
        end, 0.5)

        assert.is_true(coalesced("player"))
        assert.is_true(coalesced("target", "health"))
        assert.is_true(coalesced("player"))
        assert.is_true(coalesced:IsPending())
        -- The first key started the interval; later keys joined it.
        assert.are.equal(1, #TestEnv.NativeTimers())
        assert.are.equal(0.5, TestEnv.NativeTimers()[1].seconds)

        fireLatest()
        assert.are.same({ { player = true, target = "health" } }, deliveries)
        assert.is_false(coalesced:IsPending())

        -- Idle again: nothing is armed until the next key.
        assert.are.equal(1, #TestEnv.NativeTimers())
        coalesced("focus")
        assert.are.equal(2, #TestEnv.NativeTimers())
        fireLatest()
        assert.are.same({ player = true, target = "health" }, deliveries[1])
        assert.are.same({ focus = true }, deliveries[2])
    end)

    it("refuses new keys past maxKeys, counts them, and still updates known keys", function()
        local SchedulerKit = TestEnv.NewPackage()
        local delivered = nil
        local coalesced = SchedulerKit:Coalesce(function(set)
            delivered = copy(set)
        end, 1, { maxKeys = 2 })

        assert.is_true(coalesced("a", 1))
        assert.is_true(coalesced("b", 1))
        assert.is_false(coalesced("c", 1))
        assert.is_true(coalesced("a", 2))

        local stats = coalesced:GetStats()
        assert.are.equal(2, stats.keys)
        assert.are.equal(1, stats.refused)
        assert.are.equal(0, stats.delivered)

        fireLatest()
        assert.are.same({ a = 2, b = 1 }, delivered)
        stats = coalesced:GetStats()
        assert.are.equal(0, stats.keys)
        assert.are.equal(1, stats.delivered)
        -- The stats table is reused, not rebuilt per call.
        assert.are.equal(stats, coalesced:GetStats())
    end)

    it("reuses two set tables and empties each after its callback", function()
        local SchedulerKit = TestEnv.NewPackage()
        local seen = {}
        local coalesced = SchedulerKit:Coalesce(function(set)
            seen[#seen + 1] = set
        end, 0)

        for round = 1, 4 do
            coalesced(round)
            fireLatest()
        end

        assert.are.equal(seen[1], seen[3])
        assert.are.equal(seen[2], seen[4])
        assert.are_not.equal(seen[1], seen[2])
        assert.is_nil(next(seen[1]))
        assert.is_nil(next(seen[2]))
    end)

    it("delivers keys recorded by its own callback with the next interval", function()
        local SchedulerKit = TestEnv.NewPackage()
        local deliveries = {}
        local coalesced
        coalesced = SchedulerKit:Coalesce(function(set)
            deliveries[#deliveries + 1] = copy(set)
            if set.first then
                coalesced("second")
            end
        end, 1)

        coalesced("first")
        fireLatest()
        assert.are.same({ { first = true } }, deliveries)
        assert.is_true(coalesced:IsPending())
        fireLatest()
        assert.are.same({ second = true }, deliveries[2])
    end)

    it("flushes now, cancels, and reports whether anything was collected", function()
        local SchedulerKit = TestEnv.NewPackage()
        local deliveries = 0
        local coalesced = SchedulerKit:Coalesce(function()
            deliveries = deliveries + 1
        end, 10)

        assert.is_false(coalesced:Flush())
        coalesced("a")
        assert.is_true(coalesced:Flush())
        assert.are.equal(1, deliveries)
        assert.is_true(TestEnv.NativeTimers()[1].cancelled)

        coalesced("b")
        assert.is_true(coalesced:Cancel())
        assert.is_false(coalesced:Cancel())
        assert.is_false(coalesced:IsPending())
        assert.is_false(fireLatest())
        assert.are.equal(1, deliveries)
    end)

    it("reports a raising callback and keeps collecting", function()
        local SchedulerKit = TestEnv.NewPackage()
        local deliveries = 0
        local coalesced = SchedulerKit:Coalesce(function()
            deliveries = deliveries + 1
            error("coalesced failure")
        end, 0)

        coalesced("a")
        fireLatest()
        coalesced("b")
        fireLatest()
        assert.are.equal(2, deliveries)
        assert.are.equal(2, #TestEnv.TakeReportedErrors())
    end)

    it("is released by its scope", function()
        local SchedulerKit = TestEnv.NewPackage()
        local scope = SchedulerKit:CreateScope()
        local deliveries = 0
        local coalesced = scope:Coalesce(function()
            deliveries = deliveries + 1
        end, 1)

        coalesced("a")
        scope:CancelAll()
        assert.is_false(coalesced:IsPending())
        assert.is_false(coalesced:IsClosed())

        coalesced("b")
        scope:Close()
        assert.is_true(coalesced:IsClosed())
        assert.is_false(coalesced("c"))
        assert.is_false(fireLatest())
        assert.are.equal(0, deliveries)
    end)

    it("refuses bad arguments at the caller's line", function()
        local SchedulerKit = TestEnv.NewPackage()
        local coalesced = SchedulerKit:Coalesce(function() end, 1)

        expectErrorAtThisSpec("key must not be nil or NaN", function()
            coalesced(nil)
        end)
        expectErrorAtThisSpec("key must not be nil or NaN", function()
            coalesced(0 / 0)
        end)
        expectErrorAtThisSpec(
            "SchedulerKit:Coalesce maxKeys must be a finite positive integer",
            function()
                SchedulerKit:Coalesce(function() end, 1, { maxKeys = 0 })
            end
        )
        expectErrorAtThisSpec(
            "SchedulerKit:Coalesce intervalSeconds must be a finite number",
            function()
                SchedulerKit:Coalesce(function() end, math.huge)
            end
        )
        expectErrorAtThisSpec("must be called on a SchedulerKit coalesce handle", function()
            coalesced.GetStats(nil)
        end)
    end)

    it("allocates nothing to record known keys in steady state", function()
        local SchedulerKit = TestEnv.NewPackage()
        local coalesced = SchedulerKit:Coalesce(function() end, 1)
        local units = { "player", "target", "focus", "party1", "party2" }
        for index = 1, #units do
            coalesced(units[index])
        end
        fireLatest()
        for index = 1, #units do
            coalesced(units[index])
        end

        local allocated = TestEnv.AllocatedKilobytes(function()
            for round = 1, 4000 do
                for index = 1, #units do
                    coalesced(units[index], round)
                end
            end
        end)

        assert.is_true(allocated < 1, "coalesce calls allocated " .. allocated .. " KiB")
    end)
end)

describe("SchedulerKit Coalesce Flush with a lane", function()
    after_each(TestEnv.Reset)

    it('returns false and "deferred" while the previous set is still in the lane', function()
        local SchedulerKit = TestEnv.NewPackage()
        local lane = SchedulerKit:Lane("flush")
        local deliveries = 0
        local coalesced = SchedulerKit:Coalesce(function()
            deliveries = deliveries + 1
        end, 1, { lane = lane })

        coalesced("a")
        assert.is_true(coalesced:Flush())
        coalesced("b")
        local flushed, reason = coalesced:Flush()
        assert.is_false(flushed)
        assert.are.equal("deferred", reason)
        assert.is_true(coalesced:IsPending())

        TestEnv.Tick()
        fireLatest()
        TestEnv.Tick()
        assert.are.equal(2, deliveries)
    end)
end)
