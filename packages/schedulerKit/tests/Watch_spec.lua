local TestEnv = require("SchedulerKitTestEnv")

---Assert that `callback` fails with `expected` at a line of this spec file.
local function expectErrorAtThisSpec(expected, callback)
    local ok, message = pcall(callback)
    message = tostring(message)
    assert.is_false(ok)
    assert.is_not_nil(string.find(message, expected, 1, true), message)
    assert.is_not_nil(
        string.find(message, "packages/schedulerKit/tests/Watch_spec.lua:", 1, true),
        message
    )
end

---Count the native tickers that are still live.
local function liveTickers()
    local count = 0
    local timers = TestEnv.NativeTimers()
    for index = 1, #timers do
        if timers[index].repeating and not timers[index].cancelled then
            count = count + 1
        end
    end
    return count
end

describe("SchedulerKit Watch", function()
    after_each(TestEnv.Reset)

    it("calls back on the first tick and then only when the result changes", function()
        local SchedulerKit = TestEnv.NewPackage()
        local value = false
        local seen = {}
        SchedulerKit:Watch(
            function()
                return value
            end,
            0.2,
            function(current, previous)
                seen[#seen + 1] = { current, previous }
            end
        )

        TestEnv.FireNative(1)
        TestEnv.FireNative(1)
        value = true
        TestEnv.FireNative(1)
        TestEnv.FireNative(1)

        assert.are.equal(2, #seen)
        assert.are.same({ false, nil }, { seen[1][1], seen[1][2] })
        assert.are.same({ true, false }, seen[2])
    end)

    it("calls back on every tick with everyTick", function()
        local SchedulerKit = TestEnv.NewPackage()
        local calls = 0
        SchedulerKit:Watch(
            function()
                return 1
            end,
            1,
            function()
                calls = calls + 1
            end,
            { everyTick = true }
        )

        TestEnv.FireNative(1)
        TestEnv.FireNative(1)
        TestEnv.FireNative(1)
        assert.are.equal(3, calls)
    end)

    it("shares one ticker per interval and releases it with the last watcher", function()
        local SchedulerKit = TestEnv.NewPackage()
        local first = SchedulerKit:Watch(function() end, 0.5, function() end)
        local second = SchedulerKit:Watch(function() end, 0.5, function() end)
        assert.are.equal(1, liveTickers())

        local other = SchedulerKit:Watch(function() end, 2, function() end)
        assert.are.equal(2, liveTickers())

        assert.is_true(first:Cancel())
        assert.is_false(first:Cancel())
        assert.are.equal(2, liveTickers())
        second:Cancel()
        assert.are.equal(1, liveTickers())
        other:Cancel()
        assert.are.equal(0, liveTickers())
        assert.is_false(other:IsActive())
    end)

    it("samples watchers of one interval in creation order", function()
        local SchedulerKit = TestEnv.NewPackage()
        local order = {}
        for index = 1, 3 do
            SchedulerKit:Watch(function()
                order[#order + 1] = index
                return true
            end, 1, function() end)
        end
        TestEnv.FireNative(1)
        assert.are.same({ 1, 2, 3 }, order)
    end)

    it("refuses a watcher past the per-interval cap at the caller's line", function()
        local SchedulerKit = TestEnv.NewPackage()
        for _ = 1, 128 do
            SchedulerKit:Watch(function() end, 1, function() end)
        end
        expectErrorAtThisSpec("refuses more than 128 watchers on one interval", function()
            SchedulerKit:Watch(function() end, 1, function() end)
        end)
        -- Another interval is another group.
        SchedulerKit:Watch(function() end, 3, function() end)
    end)

    it("refuses more distinct intervals than the cap", function()
        local SchedulerKit = TestEnv.NewPackage()
        for index = 1, 32 do
            SchedulerKit:Watch(function() end, index, function() end)
        end
        expectErrorAtThisSpec("refuses more than 32 distinct watch intervals", function()
            SchedulerKit:Watch(function() end, 33, function() end)
        end)
    end)

    it("reports a raising predicate once and cancels only that watcher", function()
        local SchedulerKit = TestEnv.NewPackage()
        local healthy = 0
        local broken = SchedulerKit:Watch(function()
            error("predicate failure")
        end, 1, function() end)
        SchedulerKit:Watch(function()
            healthy = healthy + 1
            return healthy
        end, 1, function() end)

        TestEnv.FireNative(1)
        TestEnv.FireNative(1)

        local reported = TestEnv.TakeReportedErrors()
        assert.are.equal(1, #reported)
        assert.is_not_nil(string.find(tostring(reported[1].value), "predicate failure", 1, true))
        assert.is_false(broken:IsActive())
        assert.are.equal(2, healthy)
        assert.are.equal(1, liveTickers())
    end)

    it("reports a result it cannot compare once and cancels only that watcher", function()
        local SchedulerKit = TestEnv.NewPackage()
        -- Comparing two such tables raises, as comparing a secret value does.
        local incomparable = {
            __eq = function()
                error("results cannot be compared")
            end,
        }
        local healthy = 0
        local broken = SchedulerKit:Watch(function()
            return setmetatable({}, incomparable)
        end, 1, function() end)
        SchedulerKit:Watch(function()
            healthy = healthy + 1
            return healthy
        end, 1, function() end)

        TestEnv.FireNative(1)
        assert.are.same({}, TestEnv.TakeReportedErrors())
        TestEnv.FireNative(1)
        TestEnv.FireNative(1)

        local reported = TestEnv.TakeReportedErrors()
        assert.are.equal(1, #reported)
        assert.is_not_nil(
            string.find(tostring(reported[1].value), "results cannot be compared", 1, true)
        )
        assert.is_false(broken:IsActive())
        assert.are.equal(3, healthy)
        assert.are.equal(1, liveTickers())
    end)

    it("reports a raising callback and keeps watching", function()
        local SchedulerKit = TestEnv.NewPackage()
        local value = 1
        local watcher = SchedulerKit:Watch(
            function()
                return value
            end,
            1,
            function()
                error("callback failure")
            end
        )

        TestEnv.FireNative(1)
        value = 2
        TestEnv.FireNative(1)
        assert.are.equal(2, #TestEnv.TakeReportedErrors())
        assert.is_true(watcher:IsActive())
    end)

    it("lets a callback cancel watchers during a tick", function()
        local SchedulerKit = TestEnv.NewPackage()
        local calls = { 0, 0 }
        local second
        SchedulerKit:Watch(
            function()
                return true
            end,
            1,
            function()
                calls[1] = calls[1] + 1
                second:Cancel()
            end
        )
        second = SchedulerKit:Watch(
            function()
                return true
            end,
            1,
            function()
                calls[2] = calls[2] + 1
            end
        )

        TestEnv.FireNative(1)
        TestEnv.FireNative(1)
        assert.are.same({ 1, 0 }, calls)
        assert.are.equal(1, liveTickers())
    end)

    it("is cancelled by its scope", function()
        local SchedulerKit = TestEnv.NewPackage()
        local scope = SchedulerKit:CreateScope()
        local kept = scope:Watch(function() end, 1, function() end)
        scope:CancelAll()
        assert.is_false(kept:IsActive())
        assert.are.equal(0, liveTickers())

        local closed = scope:Watch(function() end, 1, function() end)
        scope:Close()
        assert.is_false(closed:IsActive())
        assert.are.equal(0, liveTickers())
        expectErrorAtThisSpec("cannot schedule work in a closed scope", function()
            scope:Watch(function() end, 1, function() end)
        end)
    end)

    it("refuses bad arguments at the caller's line", function()
        local SchedulerKit = TestEnv.NewPackage()
        expectErrorAtThisSpec("SchedulerKit:Watch predicate must be a function", function()
            SchedulerKit:Watch(nil, 1, function() end)
        end)
        expectErrorAtThisSpec(
            "SchedulerKit:Watch intervalSeconds must be a finite number greater than zero",
            function()
                SchedulerKit:Watch(function() end, 0, function() end)
            end
        )
        expectErrorAtThisSpec("SchedulerKit:Watch callback must be a function", function()
            SchedulerKit:Watch(function() end, 1, nil)
        end)
        expectErrorAtThisSpec("SchedulerKit:Watch everyTick must be a boolean", function()
            SchedulerKit:Watch(function() end, 1, function() end, { everyTick = "yes" })
        end)
    end)

    it("allocates nothing on a steady tick", function()
        local SchedulerKit = TestEnv.NewPackage()
        for _ = 1, 16 do
            SchedulerKit:Watch(function()
                return true
            end, 1, function() end)
        end
        TestEnv.FireNative(1)

        -- Call the host ticker's callback directly: the fixture's `FireNative`
        -- asserts through luassert, which allocates on its own.
        local ticker = TestEnv.NativeTimers()[1]
        local allocated = TestEnv.AllocatedKilobytes(function()
            for _ = 1, 2000 do
                ticker.callback(ticker)
            end
        end)
        assert.is_true(allocated < 1, "watch ticks allocated " .. allocated .. " KiB")
    end)
end)

describe("SchedulerKit Watch callback reports", function()
    after_each(TestEnv.Reset)

    it("reports a raising callback with a traceback", function()
        local SchedulerKit = TestEnv.NewPackage()
        SchedulerKit:Watch(
            function()
                return 1
            end,
            1,
            function()
                error("callback failure")
            end
        )
        TestEnv.FireNative(1)
        local reported = TestEnv.TakeReportedErrors()
        assert.are.equal(1, #reported)
        assert.is_not_nil(string.find(tostring(reported[1].value), "stack traceback", 1, true))
    end)
end)
