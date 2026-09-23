local TestEnv = require("TestKitTestEnv")

describe("TestKit asynchronous tests", function()
    local TestKit
    before_each(function()
        TestKit = TestEnv.NewReadyPackage("MyAddon")
    end)
    after_each(TestEnv.Reset)

    it("runs every test inside a SchedulerKit job, never synchronously in Run", function()
        local ran = false
        TestKit:Suite("MyAddon"):Test("marks", function()
            ran = true
        end)
        TestKit:Run()
        assert.is_false(ran)
        TestEnv.Frame()
        assert.is_true(ran)
    end)

    it("resumes a test after ctx:Yield on a later scheduler pass", function()
        local steps = {}
        TestKit:Suite("MyAddon"):Test("yields", function(ctx)
            steps[#steps + 1] = "before"
            ctx:Yield()
            steps[#steps + 1] = "after"
        end)

        local report = TestEnv.RunToEnd(TestKit)
        assert.are.same({ "before", "after" }, steps)
        assert.are.equal("passed", report.suites[1].tests[1].status)
    end)

    it("returns true and the payload when the event fires in time", function()
        local received = nil
        TestKit:Suite("MyAddon"):Test("waits", function(ctx)
            received = { ctx:WaitFor("UNIT_AURA", 2) }
        end)
        TestKit:Run()
        TestEnv.RenderFrames(3)
        assert.is_nil(received)
        -- The runner job ended while the test waits: nothing keeps OnUpdate alive.
        assert.are.equal(0, TestEnv.ActiveOnUpdateCount())

        TestEnv.Emit("UNIT_AURA", "player", false)
        TestEnv.Frame()
        assert.are.same({ true, "player", false }, received)
    end)

    it("returns false and timeout when the event does not fire", function()
        local received = nil
        TestKit:Suite("MyAddon"):Test("waits", function(ctx)
            received = { ctx:WaitFor("UNIT_AURA", 0.5) }
        end)
        TestKit:Run()
        TestEnv.Frame()
        TestEnv.Frame(500)
        TestEnv.Frame()
        assert.are.same({ false, "timeout" }, received)

        -- A later event is not delivered to the finished wait.
        TestEnv.Emit("UNIT_AURA", "player")
        TestEnv.Frame()
        assert.are.same({ false, "timeout" }, received)
    end)

    it("settles WaitFor by whichever of the timeout and the event came first", function()
        -- Both arrive before the runner resumes the waiting test, in either
        -- order; the first one decides and the second is ignored.
        local results = {}
        local suite = TestKit:Suite("MyAddon")
        suite:Test("timeout first", function(ctx)
            results[#results + 1] = { ctx:WaitFor("UNIT_AURA", 0.5) }
        end)
        suite:Test("event first", function(ctx)
            results[#results + 1] = { ctx:WaitFor("UNIT_AURA", 0.5) }
        end)

        ---Fire the native timer that carries this test's 0.5-second wait.
        local function fireWaitTimer()
            local timers = TestEnv.NativeTimers()
            for index = #timers, 1, -1 do
                if timers[index].seconds == 0.5 then
                    assert.is_true(TestEnv.FireNative(index))
                    return
                end
            end
            error("no 0.5-second native timer")
        end

        TestKit:Run()
        TestEnv.Frame()
        fireWaitTimer()
        TestEnv.Emit("UNIT_AURA", "player")
        TestEnv.Frame()
        assert.are.same({ { false, "timeout" } }, results)

        TestEnv.Frame()
        TestEnv.Emit("UNIT_AURA", "target")
        fireWaitTimer()
        TestEnv.Frame()
        assert.are.same({ { false, "timeout" }, { true, "target" } }, results)
    end)

    it("polls WaitUntil once per frame until the predicate holds", function()
        local polls = 0
        local ready = false
        local outcome = nil
        TestKit:Suite("MyAddon"):Test("waits until", function(ctx)
            outcome = {
                ctx:WaitUntil(function()
                    polls = polls + 1
                    return ready
                end, 5),
            }
        end)
        TestKit:Run()
        TestEnv.RenderFrames(4)
        local pollsBefore = polls
        assert.is_nil(outcome)
        assert.is_true(pollsBefore >= 2 and pollsBefore <= 5)

        ready = true
        TestEnv.RenderFrames(3)
        assert.are.same({ true }, outcome)
    end)

    it("returns at once from WaitUntil when the predicate already holds", function()
        local outcome = nil
        TestKit:Suite("MyAddon"):Test("already true", function(ctx)
            outcome = { ctx:WaitUntil(function()
                return true
            end, 1) }
        end)
        TestEnv.RunToEnd(TestKit)
        assert.are.same({ true }, outcome)
    end)

    it("returns false and timeout from WaitUntil when the predicate never holds", function()
        local outcome = nil
        TestKit:Suite("MyAddon"):Test("never true", function(ctx)
            outcome = { ctx:WaitUntil(function()
                return false
            end, 0.1) }
        end)
        local report = TestEnv.RunToEnd(TestKit)
        assert.are.same({ false, "timeout" }, outcome)
        assert.are.equal("passed", report.suites[1].tests[1].status)
    end)

    it(
        "abandons a test that outlives its time limit, then runs its After hooks and restores",
        function()
            local target = { value = 1 }
            local afterRan = false
            local suite = TestKit:Suite("MyAddon", { timeoutSeconds = 1 })
            suite:After(function()
                afterRan = true
            end)
            suite:Test("hangs", function(ctx)
                ctx:Replace(target, "value", 2)
                ctx:WaitFor("NEVER_FIRES", 60)
            end)
            suite:Test("next", function() end)

            local report = TestEnv.RunToEnd(TestKit, nil, 400)
            assert.is_not_nil(report)
            assert.are.equal("timeout", report.suites[1].tests[1].status)
            assert.are.equal("passed", report.suites[1].tests[2].status)
            assert.is_true(afterRan)
            assert.are.equal(1, target.value)
        end
    )

    it("abandons After hooks that outlive their own window", function()
        local suite = TestKit:Suite("MyAddon", { timeoutSeconds = 1 })
        suite:After(function(ctx)
            ctx:WaitFor("NEVER_FIRES", 60)
        end)
        suite:Test("body", function() end)

        local report = TestEnv.RunToEnd(TestKit, nil, 400)
        local result = report.suites[1].tests[1]
        assert.are.equal("failed", result.status)
        assert.is_truthy(result.message:find("After hook did not finish", 1, true))
    end)

    it("fails a test that yields with coroutine.yield", function()
        TestKit:Suite("MyAddon"):Test("raw yield", function()
            coroutine.yield("mine")
        end)
        local report = TestEnv.RunToEnd(TestKit)
        local result = report.suites[1].tests[1]
        assert.are.equal("failed", result.status)
        assert.is_truthy(result.message:find("use ctx:Yield()", 1, true))
    end)

    it("refuses ctx:Yield from anywhere but the test's own coroutine", function()
        local message = nil
        TestKit:Suite("MyAddon"):Test("yields elsewhere", function(ctx)
            local helper = coroutine.create(function()
                ctx:Yield()
            end)
            local _, value = coroutine.resume(helper)
            message = value
        end)
        TestEnv.RunToEnd(TestKit)
        assert.is_truthy(message:find("must be called from the running test or hook", 1, true))
    end)

    it("honours the frame budget between tests", function()
        local suite = TestKit:Suite("MyAddon")
        local ran = 0
        for index = 1, 5 do
            suite:Test("test " .. index, function()
                ran = ran + 1
                TestEnv.AdvanceProfileMs(5)
            end)
        end
        TestKit:Run()
        TestEnv.Frame()
        assert.is_true(ran >= 1 and ran < 5)
        TestEnv.RenderFrames(10)
        assert.are.equal(5, ran)
    end)
end)
