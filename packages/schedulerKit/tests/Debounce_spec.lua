local TestEnv = require("SchedulerKitTestEnv")

---Fire the most recently created native timer.
---@return boolean fired
local function fireLatest()
    return TestEnv.FireNative(#TestEnv.NativeTimers())
end

---The delay the most recently created native timer was armed with.
---@return number seconds
local function latestSeconds()
    local timers = TestEnv.NativeTimers()
    return timers[#timers].seconds
end

---Assert that `callback` fails with `expected` at a line of this spec file.
local function expectErrorAtThisSpec(expected, callback)
    local ok, message = pcall(callback)
    message = tostring(message)
    assert.is_false(ok)
    assert.is_not_nil(string.find(message, expected, 1, true), message)
    assert.is_not_nil(
        string.find(message, "packages/schedulerKit/tests/Debounce_spec.lua:", 1, true),
        message
    )
end

---Measure the allocation a workload causes, in kilobytes, with the collector
---stopped so that a collection cycle cannot hide or invent growth.
local function allocatedKilobytes(workload)
    collectgarbage()
    collectgarbage("stop")
    local before = collectgarbage("count")
    workload()
    local after = collectgarbage("count")
    collectgarbage("restart")
    return after - before
end

describe("SchedulerKit Debounce", function()
    after_each(TestEnv.Reset)

    it("restarts the delay on every call and arms one timer per quiet window", function()
        local SchedulerKit = TestEnv.NewPackage()
        local calls = 0
        local debounced = SchedulerKit:Debounce(function()
            calls = calls + 1
        end, 1)

        assert.is_true(debounced("a"))
        TestEnv.AdvanceMs(500)
        assert.is_true(debounced("b"))
        -- A call inside the window records a clock reading; it does not re-arm.
        assert.are.equal(1, #TestEnv.NativeTimers())

        TestEnv.AdvanceMs(500)
        fireLatest()
        assert.are.equal(0, calls)
        assert.are.equal(2, #TestEnv.NativeTimers())
        assert.is_true(math.abs(latestSeconds() - 0.5) < 1e-9)

        TestEnv.AdvanceMs(500)
        fireLatest()
        assert.are.equal(1, calls)
        assert.is_false(debounced:IsPending())
    end)

    it("fires once with the arguments of the last call, nils included", function()
        local SchedulerKit = TestEnv.NewPackage()
        local seen = nil
        local debounced = SchedulerKit:Debounce(function(...)
            seen = { count = select("#", ...), values = { ... } }
        end, 0)

        debounced("first")
        debounced(1, nil, 3)
        fireLatest()

        assert.are.equal(3, seen.count)
        assert.are.equal(1, seen.values[1])
        assert.is_nil(seen.values[2])
        assert.are.equal(3, seen.values[3])
    end)

    it("accepts eight arguments and refuses a ninth at the caller's line", function()
        local SchedulerKit = TestEnv.NewPackage()
        local count = nil
        local debounced = SchedulerKit:Debounce(function(...)
            count = select("#", ...)
        end, 0)

        debounced(1, 2, 3, 4, 5, 6, 7, 8)
        fireLatest()
        assert.are.equal(8, count)

        expectErrorAtThisSpec("accepts at most 8 arguments; received 9", function()
            debounced(1, 2, 3, 4, 5, 6, 7, 8, 9)
        end)
    end)

    it("fires on the leading edge and once more on the trailing edge", function()
        local SchedulerKit = TestEnv.NewPackage()
        local received = {}
        local debounced = SchedulerKit:Debounce(function(value)
            received[#received + 1] = value
        end, 1, { leading = true })

        debounced("a")
        assert.are.same({ "a" }, received)
        assert.is_false(debounced:IsPending())

        TestEnv.AdvanceMs(300)
        debounced("b")
        debounced("c")
        assert.is_true(debounced:IsPending())

        TestEnv.AdvanceMs(1000)
        fireLatest()
        assert.are.same({ "a", "c" }, received)

        -- The next burst leads again.
        debounced("d")
        assert.are.same({ "a", "c", "d" }, received)
    end)

    it("does not fire a trailing edge for a single leading call", function()
        local SchedulerKit = TestEnv.NewPackage()
        local calls = 0
        local debounced = SchedulerKit:Debounce(function()
            calls = calls + 1
        end, 1, { leading = true })

        debounced()
        TestEnv.AdvanceMs(1000)
        fireLatest()
        assert.are.equal(1, calls)
    end)

    it("fires at maxWaitSeconds during a continuous burst", function()
        local SchedulerKit = TestEnv.NewPackage()
        local calls = 0
        local debounced = SchedulerKit:Debounce(function()
            calls = calls + 1
        end, 1, { maxWaitSeconds = 2 })

        debounced()
        TestEnv.AdvanceMs(900)
        debounced()
        TestEnv.AdvanceMs(100)
        fireLatest()
        assert.are.equal(0, calls)

        TestEnv.AdvanceMs(800)
        debounced()
        TestEnv.AdvanceMs(100)
        fireLatest()
        -- 1.9 s after the first call the burst is still active, and quiet
        -- would only come at 2.8 s; maxWait caps it at 2 s.
        assert.are.equal(0, calls)
        assert.is_true(math.abs(latestSeconds() - 0.1) < 1e-9)

        TestEnv.AdvanceMs(100)
        fireLatest()
        assert.are.equal(1, calls)
    end)

    it("cancels the owed fire and stays usable", function()
        local SchedulerKit = TestEnv.NewPackage()
        local calls = 0
        local debounced = SchedulerKit:Debounce(function()
            calls = calls + 1
        end, 1)

        debounced()
        assert.is_true(debounced:Cancel())
        assert.is_false(debounced:IsPending())
        assert.is_true(TestEnv.NativeTimers()[1].cancelled)
        assert.is_false(debounced:Cancel())

        debounced()
        TestEnv.AdvanceMs(1000)
        fireLatest()
        assert.are.equal(1, calls)
    end)

    it("flushes the owed fire now", function()
        local SchedulerKit = TestEnv.NewPackage()
        local received = nil
        local debounced = SchedulerKit:Debounce(function(value)
            received = value
        end, 5)

        assert.is_false(debounced:Flush())
        debounced("now")
        assert.is_true(debounced:Flush())
        assert.are.equal("now", received)
        assert.is_false(debounced:IsPending())
        assert.is_true(TestEnv.NativeTimers()[1].cancelled)
    end)

    it("reports a raising callback and keeps the handle working", function()
        local SchedulerKit = TestEnv.NewPackage()
        local calls = 0
        local debounced = SchedulerKit:Debounce(function()
            calls = calls + 1
            if calls == 1 then
                error("debounced failure")
            end
        end, 0)

        debounced()
        fireLatest()
        local reported = TestEnv.TakeReportedErrors()
        assert.are.equal(1, #reported)
        assert.is_not_nil(string.find(tostring(reported[1].value), "debounced failure", 1, true))

        debounced()
        fireLatest()
        assert.are.equal(2, calls)
        assert.are.equal(0, #TestEnv.TakeReportedErrors())
    end)

    it("starts a new burst when the callback calls its own handle", function()
        local SchedulerKit = TestEnv.NewPackage()
        local received = {}
        local debounced
        debounced = SchedulerKit:Debounce(function(value)
            received[#received + 1] = value
            if value == "first" then
                debounced("second")
            end
        end, 0)

        debounced("first")
        fireLatest()
        assert.are.same({ "first" }, received)
        assert.is_true(debounced:IsPending())
        fireLatest()
        assert.are.same({ "first", "second" }, received)
    end)

    it("is released by its scope: CancelAll keeps it, Close ends it", function()
        local SchedulerKit = TestEnv.NewPackage()
        local scope = SchedulerKit:CreateScope()
        local calls = 0
        local debounced = scope:Debounce(function()
            calls = calls + 1
        end, 1)

        debounced()
        scope:CancelAll()
        assert.is_false(debounced:IsPending())
        assert.is_false(debounced:IsClosed())

        debounced()
        assert.is_true(scope:Close())
        assert.is_true(debounced:IsClosed())
        assert.is_false(debounced())
        TestEnv.AdvanceMs(1000)
        assert.is_false(fireLatest())
        assert.are.equal(0, calls)
        assert.is_false(debounced:Close())
    end)

    it("closes on its own and leaves its scope", function()
        local SchedulerKit = TestEnv.NewPackage()
        local scope = SchedulerKit:CreateScope()
        local debounced = scope:Debounce(function() end, 1)
        debounced()

        assert.is_true(debounced:Close())
        assert.is_false(rawget(scope, "_familyHead"))
        assert.is_false(debounced())
    end)

    it("refuses bad arguments at the caller's line", function()
        local SchedulerKit = TestEnv.NewPackage()
        local scope = SchedulerKit:CreateScope()

        expectErrorAtThisSpec("SchedulerKit:Debounce callback must be a function", function()
            SchedulerKit:Debounce(nil, 1)
        end)
        expectErrorAtThisSpec(
            "SchedulerKit:Debounce delaySeconds must be a finite number",
            function()
                SchedulerKit:Debounce(function() end, -1)
            end
        )
        expectErrorAtThisSpec("maxWaitSeconds must be at least delaySeconds", function()
            SchedulerKit:Debounce(function() end, 2, { maxWaitSeconds = 1 })
        end)
        expectErrorAtThisSpec('options contains unknown field "trailing"', function()
            SchedulerKit:Debounce(function() end, 1, { trailing = true })
        end)
        expectErrorAtThisSpec("SchedulerKit.Scope:Debounce leading must be a boolean", function()
            scope:Debounce(function() end, 1, { leading = 1 })
        end)
        expectErrorAtThisSpec("lane must be a SchedulerKit lane", function()
            scope:Debounce(function() end, 1, { lane = {} })
        end)
        scope:Close()
        expectErrorAtThisSpec("cannot schedule work in a closed scope", function()
            scope:Debounce(function() end, 1)
        end)
        expectErrorAtThisSpec("must be called on a SchedulerKit debounce handle", function()
            local debounced = SchedulerKit:Debounce(function() end, 1)
            debounced.Flush({})
        end)
    end)

    it("allocates nothing to record calls inside an open window", function()
        local SchedulerKit = TestEnv.NewPackage()
        local debounced = SchedulerKit:Debounce(function() end, 1)
        debounced("warm", 1, 2)

        local allocated = allocatedKilobytes(function()
            for index = 1, 20000 do
                debounced("value", index, true)
            end
        end)

        assert.is_true(allocated < 1, "debounce calls allocated " .. allocated .. " KiB")
        assert.are.equal(1, #TestEnv.NativeTimers())
    end)
end)
