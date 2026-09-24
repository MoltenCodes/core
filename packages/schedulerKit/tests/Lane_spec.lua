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
        string.find(message, "packages/schedulerKit/tests/Lane_spec.lua:", 1, true),
        message
    )
end

---A lane job that holds its slot until `gate[index]` is set.
local function gatedJob(gate, index, started)
    return function(context)
        started[#started + 1] = index
        while not gate[index] do
            context:Yield()
        end
    end
end

describe("SchedulerKit lanes", function()
    after_each(TestEnv.Reset)

    it("is shared by name and bounded in number", function()
        local SchedulerKit = TestEnv.NewPackage()
        local lane = SchedulerKit:Lane("inspect", { maxInFlight = 2 })
        assert.are.equal(lane, SchedulerKit:Lane("inspect"))
        assert.are.equal(lane, SchedulerKit:Lane("inspect", { maxInFlight = 2 }))
        assert.are.equal("inspect", lane:GetName())

        expectErrorAtThisSpec('lane "inspect" already exists with different options', function()
            SchedulerKit:Lane("inspect", { maxInFlight = 3 })
        end)

        for index = 2, 32 do
            SchedulerKit:Lane("lane" .. index)
        end
        expectErrorAtThisSpec("refuses to create more than 32 open lanes", function()
            SchedulerKit:Lane("one too many")
        end)
    end)

    it("runs at most maxInFlight submissions at once, in FIFO order", function()
        local SchedulerKit = TestEnv.NewPackage()
        local lane = SchedulerKit:Lane("server", { maxInFlight = 1 })
        local gate, started = {}, {}
        local first = lane:Submit(gatedJob(gate, 1, started))
        local second = lane:Submit(gatedJob(gate, 2, started))
        local third = lane:Submit(gatedJob(gate, 3, started))

        assert.are.equal("pending", first:GetState())
        assert.are.equal("delayed", second:GetState())
        assert.is_true(third:IsPending())

        TestEnv.Tick()
        assert.are.same({ 1 }, started)
        local stats = lane:GetStats()
        assert.are.equal(1, stats.inFlight)
        assert.are.equal(2, stats.queued)

        gate[1] = true
        TestEnv.Tick()
        assert.are.same({ 1, 2 }, started)
        assert.are.equal("completed", first:GetState())

        gate[2], gate[3] = true, true
        TestEnv.Tick()
        TestEnv.Tick()
        assert.are.same({ 1, 2, 3 }, started)
        stats = lane:GetStats()
        assert.are.equal(0, stats.inFlight)
        assert.are.equal(0, stats.queued)
        assert.are.equal(3, stats.completed)
        assert.are.equal(0, TestEnv.ActiveOnUpdateCount())
    end)

    it("keeps starts at least minIntervalSeconds apart", function()
        local SchedulerKit = TestEnv.NewPackage()
        local lane = SchedulerKit:Lane("who", { maxInFlight = 4, minIntervalSeconds = 1 })
        local runs = 0
        local function job()
            runs = runs + 1
        end

        lane:Submit(job)
        lane:Submit(job)
        TestEnv.Tick()
        assert.are.equal(1, runs)
        assert.are.equal(1, lane:GetStats().queued)
        assert.are.equal(1, latestSeconds())

        TestEnv.AdvanceMs(400)
        fireLatest()
        -- Woken early: the remainder is re-armed rather than admitted.
        assert.is_true(math.abs(latestSeconds() - 0.6) < 1e-9)
        TestEnv.Tick()
        assert.are.equal(1, runs)

        TestEnv.AdvanceMs(600)
        fireLatest()
        TestEnv.Tick()
        assert.are.equal(2, runs)
    end)

    it("retries a raising submission with exponential backoff, capped", function()
        local SchedulerKit = TestEnv.NewPackage()
        local lane = SchedulerKit:Lane("flaky", {
            retry = { attempts = 3, backoffSeconds = 1, multiplier = 2, maxBackoffSeconds = 3 },
        })
        local attempts = 0
        local job = lane:Submit(function()
            attempts = attempts + 1
            error("throttled " .. attempts)
        end)

        TestEnv.Tick()
        assert.are.equal(1, attempts)
        assert.are.equal("delayed", job:GetState())
        assert.are.equal(1, latestSeconds())
        -- A retried attempt keeps the lane's slot and is not reported.
        assert.are.equal(1, lane:GetStats().inFlight)
        assert.are.equal(0, #TestEnv.TakeReportedErrors())

        fireLatest()
        TestEnv.Tick()
        assert.are.equal(2, latestSeconds())
        fireLatest()
        TestEnv.Tick()
        assert.are.equal(3, latestSeconds())
        fireLatest()
        TestEnv.Tick()

        assert.are.equal(4, attempts)
        assert.are.equal("failed", job:GetState())
        assert.is_not_nil(string.find(tostring(job:GetError()), "throttled 4", 1, true))
        local stats = lane:GetStats()
        assert.are.equal(3, stats.retried)
        assert.are.equal(1, stats.failed)
        assert.are.equal(0, stats.inFlight)
        assert.are.equal(1, #TestEnv.TakeReportedErrors())
    end)

    it("succeeds on a retry and counts the submission completed", function()
        local SchedulerKit = TestEnv.NewPackage()
        local lane = SchedulerKit:Lane("recovering", { retry = { attempts = 1 } })
        local attempts = 0
        local job = lane:Submit(function()
            attempts = attempts + 1
            if attempts == 1 then
                error("transient")
            end
        end)

        TestEnv.Tick()
        -- A zero backoff is the next frame, exactly like NextFrame.
        assert.are.equal(0, latestSeconds())
        fireLatest()
        TestEnv.Tick()
        assert.are.equal("completed", job:GetState())
        assert.are.equal(1, lane:GetStats().completed)
        assert.are.equal(0, lane:GetStats().failed)
    end)

    it('refuses a submission past maxQueued with nil and "full"', function()
        local SchedulerKit = TestEnv.NewPackage()
        local lane = SchedulerKit:Lane("bounded", { maxQueued = 2 })
        local activeBefore = SchedulerKit:GetActiveCount()

        assert.is_not_nil(lane:Submit(function() end))
        assert.is_not_nil(lane:Submit(function() end))
        assert.is_not_nil(lane:Submit(function() end))
        local job, reason = lane:Submit(function() end)

        assert.is_nil(job)
        assert.are.equal("full", reason)
        local stats = lane:GetStats()
        assert.are.equal(1, stats.inFlight)
        assert.are.equal(2, stats.queued)
        assert.are.equal(1, stats.refused)
        -- A refusal creates no job.
        assert.are.equal(activeBefore + 3, SchedulerKit:GetActiveCount())
    end)

    it("keeps its queue bounded when waiting submissions are cancelled", function()
        local SchedulerKit = TestEnv.NewPackage()
        local lane = SchedulerKit:Lane("churn", { maxQueued = 3 })
        local gate, started = {}, {}
        lane:Submit(gatedJob(gate, 1, started))

        for _ = 1, 50 do
            local job = lane:Submit(function() end)
            job:Cancel()
        end
        assert.are.equal(0, lane:GetStats().queued)
        assert.are.equal(50, lane:GetStats().cancelled)
        assert.is_true(rawget(lane, "_tail") - rawget(lane, "_head") + 1 <= 3)
    end)

    it("closes: refuses new work, cancels the queue, drains what is in flight", function()
        local SchedulerKit = TestEnv.NewPackage()
        local lane = SchedulerKit:Lane("closing")
        local gate, started = {}, {}
        local running = lane:Submit(gatedJob(gate, 1, started))
        local waiting = lane:Submit(gatedJob(gate, 2, started))
        TestEnv.Tick()

        assert.is_true(lane:Close())
        assert.is_false(lane:Close())
        assert.is_true(lane:IsClosed())
        assert.are.equal("cancelled", waiting:GetState())
        local job, reason = lane:Submit(function() end)
        assert.is_nil(job)
        assert.are.equal("closed", reason)

        gate[1] = true
        TestEnv.Tick()
        assert.are.equal("completed", running:GetState())
        assert.are.same({ 1 }, started)

        -- The name is free again.
        local fresh = SchedulerKit:Lane("closing")
        assert.are_not.equal(lane, fresh)
        assert.is_false(fresh:IsClosed())
    end)

    it("is released by the submitting scope", function()
        local SchedulerKit = TestEnv.NewPackage()
        local lane = SchedulerKit:Lane("scoped")
        local scope = SchedulerKit:CreateScope()
        local gate, started = {}, {}
        local running = lane:Submit(gatedJob(gate, 1, started), { scope = scope })
        local waiting = lane:Submit(gatedJob(gate, 2, started), { scope = scope })
        local other = lane:Submit(gatedJob(gate, 3, started))
        TestEnv.Tick()

        scope:Close()
        assert.are.equal("cancelled", running:GetState())
        assert.are.equal("cancelled", waiting:GetState())
        assert.are.equal(2, lane:GetStats().cancelled)

        -- The slot the scope held went to the next submission in line.
        gate[3] = true
        TestEnv.Tick()
        assert.are.equal("completed", other:GetState())
        assert.are.same({ 1, 3 }, started)

        expectErrorAtThisSpec("cannot schedule work in a closed scope", function()
            lane:Submit(function() end, { scope = scope })
        end)
    end)

    it("refuses bad arguments at the caller's line", function()
        local SchedulerKit = TestEnv.NewPackage()
        local lane = SchedulerKit:Lane("args")
        expectErrorAtThisSpec("SchedulerKit:Lane name must be a non-empty string", function()
            SchedulerKit:Lane("")
        end)
        expectErrorAtThisSpec(
            "SchedulerKit:Lane maxInFlight must be a finite positive integer",
            function()
                SchedulerKit:Lane("bad", { maxInFlight = 0 })
            end
        )
        expectErrorAtThisSpec(
            "SchedulerKit:Lane retry.attempts must be a finite integer",
            function()
                SchedulerKit:Lane("bad", { retry = { attempts = -1 } })
            end
        )
        expectErrorAtThisSpec("SchedulerKit:Lane retry.multiplier must be at least 1", function()
            SchedulerKit:Lane("bad", { retry = { multiplier = 0.5 } })
        end)
        expectErrorAtThisSpec(
            'SchedulerKit:Lane retry options contains unknown field "tries"',
            function()
                SchedulerKit:Lane("bad", { retry = { tries = 1 } })
            end
        )
        expectErrorAtThisSpec("SchedulerKit.Lane:Submit callback must be a function", function()
            lane:Submit(nil)
        end)
        expectErrorAtThisSpec(
            "SchedulerKit.Lane:Submit scope must be a SchedulerKit scope",
            function()
                lane:Submit(function() end, { scope = {} })
            end
        )
        expectErrorAtThisSpec("SchedulerKit.Lane:Submit priority must be one of", function()
            lane:Submit(function() end, { priority = 9 })
        end)
        expectErrorAtThisSpec("must be called on a SchedulerKit lane", function()
            lane.GetStats({})
        end)
    end)
end)

describe("SchedulerKit Debounce and Coalesce into a lane", function()
    after_each(TestEnv.Reset)

    it("runs a debounce fire as a lane job", function()
        local SchedulerKit = TestEnv.NewPackage()
        local lane = SchedulerKit:Lane("debounced")
        local received = {}
        local debounced = SchedulerKit:Debounce(function(value)
            received[#received + 1] = value
        end, 1, { lane = lane })

        debounced("a")
        debounced("b")
        TestEnv.AdvanceMs(1000)
        fireLatest()
        assert.are.same({}, received)
        assert.are.equal(1, lane:GetStats().inFlight)

        TestEnv.Tick()
        assert.are.same({ "b" }, received)
        assert.are.equal(1, lane:GetStats().completed)
    end)

    it("hands a waiting debounce delivery the newest arguments", function()
        local SchedulerKit = TestEnv.NewPackage()
        local lane = SchedulerKit:Lane("busy")
        local gate, started = {}, {}
        lane:Submit(gatedJob(gate, 1, started))
        local received = {}
        local debounced = SchedulerKit:Debounce(function(value)
            received[#received + 1] = value
        end, 0, { lane = lane })

        debounced("old")
        fireLatest()
        debounced("new")
        fireLatest()
        -- One delivery waits in the lane; the second fire updated it.
        assert.are.equal(1, lane:GetStats().queued)

        gate[1] = true
        TestEnv.Tick()
        TestEnv.Tick()
        assert.are.same({ "new" }, received)
    end)

    it("defers a coalesce delivery while the previous set is still in the lane", function()
        local SchedulerKit = TestEnv.NewPackage()
        local lane = SchedulerKit:Lane("sets")
        local gate, started = {}, {}
        lane:Submit(gatedJob(gate, 1, started))
        local deliveries = {}
        local coalesced = SchedulerKit:Coalesce(function(set)
            local keys = {}
            for key in pairs(set) do
                keys[#keys + 1] = key
            end
            table.sort(keys)
            deliveries[#deliveries + 1] = table.concat(keys, ",")
        end, 1, { lane = lane })

        coalesced("a")
        fireLatest()
        coalesced("b")
        coalesced("c")
        fireLatest()
        local stats = coalesced:GetStats()
        assert.are.equal(1, stats.delivered)
        assert.are.equal(1, stats.deferred)
        assert.are.equal(2, stats.keys)

        gate[1] = true
        TestEnv.Tick()
        TestEnv.Tick()
        assert.are.same({ "a" }, deliveries)

        fireLatest()
        TestEnv.Tick()
        assert.are.same({ "a", "b,c" }, deliveries)
    end)

    it("drops and reports a coalesce delivery into a closed lane", function()
        local SchedulerKit = TestEnv.NewPackage()
        local lane = SchedulerKit:Lane("gone")
        local coalesced = SchedulerKit:Coalesce(function() end, 1, { lane = lane })
        lane:Close()

        coalesced("a")
        fireLatest()
        assert.are.equal(1, coalesced:GetStats().dropped)
        assert.is_false(coalesced:IsPending())
        assert.are.equal(1, #TestEnv.TakeReportedErrors())
    end)

    it("lets an admitted delivery finish when the member closes", function()
        local SchedulerKit = TestEnv.NewPackage()
        local lane = SchedulerKit:Lane("released")
        local calls = 0
        local debounced = SchedulerKit:Debounce(function()
            calls = calls + 1
        end, 0, { lane = lane })

        debounced()
        fireLatest()
        assert.are.equal(1, lane:GetStats().inFlight)
        debounced:Close()
        assert.are.equal(0, lane:GetStats().cancelled)
        TestEnv.Tick()
        assert.are.equal(1, calls)
        assert.are.equal(1, lane:GetStats().completed)
    end)

    it("cancels a delivery still waiting for the lane when the member closes", function()
        local SchedulerKit = TestEnv.NewPackage()
        local lane = SchedulerKit:Lane("waiting")
        local gate, started = {}, {}
        lane:Submit(gatedJob(gate, 1, started))
        local calls = 0
        local coalesced = SchedulerKit:Coalesce(function()
            calls = calls + 1
        end, 0, { lane = lane })

        coalesced("a")
        fireLatest()
        assert.are.equal(1, lane:GetStats().queued)
        coalesced:Close()
        assert.are.equal(0, lane:GetStats().queued)
        assert.are.equal(1, lane:GetStats().cancelled)
        gate[1] = true
        TestEnv.Tick()
        assert.are.equal(0, calls)
    end)
end)

describe("SchedulerKit lanes after the acceptance review", function()
    after_each(TestEnv.Reset)

    it("keeps the newest debounce arguments when a re-delivery meets a full lane", function()
        local SchedulerKit = TestEnv.NewPackage()
        local lane = SchedulerKit:Lane("full", { maxInFlight = 1, maxQueued = 1 })
        local received = {}
        local debounced
        debounced = SchedulerKit:Debounce(function(value)
            received[#received + 1] = value
            if value == "X" then
                -- Occupy the only queue slot, then start two newer bursts.
                lane:Submit(function() end)
                debounced("Y")
                debounced:Flush()
                debounced("Z")
            end
        end, 0, { lane = lane })

        debounced("X")
        fireLatest()
        for _ = 1, 4 do
            TestEnv.Tick()
            fireLatest()
        end
        TestEnv.Tick()

        -- Y was superseded by the newer burst Z; Z must not be lost.
        assert.are.same({ "X", "Z" }, received)
        assert.is_false(debounced:IsPending())
    end)

    it("makes a retry wait out the lane's minimum interval", function()
        local SchedulerKit = TestEnv.NewPackage()
        local lane = SchedulerKit:Lane("spaced", {
            minIntervalSeconds = 5,
            retry = { attempts = 1, backoffSeconds = 1 },
        })
        local attempts = 0
        lane:Submit(function()
            attempts = attempts + 1
            error("again")
        end)
        TestEnv.Tick()
        assert.are.equal(1, attempts)
        assert.are.equal(5, latestSeconds())
    end)

    it("cancels a retry waiting out its backoff when the lane closes", function()
        local SchedulerKit = TestEnv.NewPackage()
        local lane =
            SchedulerKit:Lane("closing retries", { retry = { attempts = 3, backoffSeconds = 1 } })
        local attempts = 0
        local job = lane:Submit(function()
            attempts = attempts + 1
            error("again")
        end)
        TestEnv.Tick()
        assert.are.equal("delayed", job:GetState())

        lane:Close()
        assert.are.equal("cancelled", job:GetState())
        assert.is_false(fireLatest())
        assert.are.equal(1, attempts)
        assert.are.equal(0, lane:GetStats().inFlight)
    end)

    it("does not retry an attempt that raises after the lane closed", function()
        local SchedulerKit = TestEnv.NewPackage()
        SchedulerKit:SetMaxResumesPerFrame(1)
        local lane = SchedulerKit:Lane("closing run", { retry = { attempts = 3 } })
        local job = lane:Submit(function(context)
            context:Yield()
            error("after close")
        end)
        TestEnv.Tick()
        lane:Close()
        TestEnv.Tick()
        assert.are.equal("failed", job:GetState())
        assert.are.equal(0, lane:GetStats().retried)
        assert.are.equal(1, #TestEnv.TakeReportedErrors())
    end)

    it("clamps the interval wait when the clock steps backwards", function()
        local SchedulerKit = TestEnv.NewPackage()
        local lane = SchedulerKit:Lane("stepped", { maxInFlight = 2, minIntervalSeconds = 1 })
        lane:Submit(function() end)
        lane:Submit(function() end)
        assert.are.equal(1, latestSeconds())
        TestEnv.AdvanceMs(-5000)
        fireLatest()
        assert.are.equal(1, latestSeconds())
    end)

    it("restarts its queue indices once drained", function()
        local SchedulerKit = TestEnv.NewPackage()
        local lane = SchedulerKit:Lane("indices")
        for _ = 1, 20 do
            lane:Submit(function() end)
            TestEnv.Tick()
        end
        assert.are.equal(20, lane:GetStats().completed)
        assert.are.equal(0, rawget(lane, "_tail"))
        assert.are.equal(1, rawget(lane, "_head"))
    end)

    it("refuses a full or closed lane without allocating", function()
        local SchedulerKit = TestEnv.NewPackage()
        local lane = SchedulerKit:Lane("refusing", { maxQueued = 1 })
        local callback = function() end
        lane:Submit(callback)
        lane:Submit(callback)

        local fullKilobytes = TestEnv.AllocatedKilobytes(function()
            for _ = 1, 200 do
                lane:Submit(callback)
            end
        end)
        lane:Close()
        local closedKilobytes = TestEnv.AllocatedKilobytes(function()
            for _ = 1, 200 do
                lane:Submit(callback)
            end
        end)

        assert.are.equal(0, fullKilobytes)
        assert.are.equal(0, closedKilobytes)
        assert.are.equal(400, lane:GetStats().refused)
    end)
end)
