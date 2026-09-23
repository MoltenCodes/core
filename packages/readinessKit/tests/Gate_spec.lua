local TestEnv = require("ReadinessKitTestEnv")

describe("ReadinessKit gates", function()
    local ReadinessKit
    before_each(function()
        ReadinessKit = TestEnv.NewPackage()
    end)
    after_each(TestEnv.Reset)

    it("is ready at once when the first probe answers, and arms no timer", function()
        local calls = 0
        local gate = ReadinessKit:Gate("spellbook", function()
            calls = calls + 1
            return true
        end)

        assert.is_true(gate:IsReady())
        assert.are.equal(1, calls)
        assert.are.equal(0, #TestEnv.NativeTimers())

        local results = {}
        local waiter = gate:Await(function(ready, reason)
            results[#results + 1] = { ready, reason }
        end)
        assert.are.same({ { true } }, results)
        assert.is_false(waiter:IsPending())
        assert.is_false(waiter:Cancel())
    end)

    it("treats any truthy probe result as ready", function()
        local gate = ReadinessKit:Gate("item", function()
            return "Hearthstone"
        end)
        assert.is_true(gate:IsReady())
    end)

    it("becomes ready after N polls on one repeating timer, then stops polling", function()
        local calls = 0
        local gate = ReadinessKit:Gate("talents", function()
            calls = calls + 1
            return calls >= 4
        end)
        local results = {}
        gate:Await(function(ready)
            results[#results + 1] = ready
        end)

        assert.is_false(gate:IsReady())
        assert.are.equal(1, #TestEnv.NativeTimers())
        assert.are.equal(0.5, TestEnv.NativeTimers()[1].seconds)
        assert.is_true(TestEnv.NativeTimers()[1].repeating)

        TestEnv.Poll(500)
        TestEnv.Poll(500)
        assert.is_false(gate:IsReady())
        assert.are.same({}, results)

        TestEnv.Poll(500)
        assert.is_true(gate:IsReady())
        assert.are.equal(4, calls)
        assert.are.same({ true }, results)
        assert.are.equal(0, TestEnv.ArmedTimerCount())
        assert.are.equal(1, #TestEnv.NativeTimers())

        assert.are.equal(0, TestEnv.Poll(500))
        assert.are.equal(4, calls)
    end)

    it("honours intervalSeconds", function()
        ReadinessKit:Gate("roster", function()
            return false
        end, { intervalSeconds = 2 })
        assert.are.equal(2, TestEnv.NativeTimers()[1].seconds)
    end)

    it(
        "returns the existing gate for the same name and ignores the new probe and options",
        function()
            local first = ReadinessKit:Gate("spellbook", function()
                return false
            end, { maxWaiters = 1 })
            local secondProbeCalls = 0
            local second = ReadinessKit:Gate("spellbook", function()
                secondProbeCalls = secondProbeCalls + 1
                return true
            end, { maxWaiters = 10 })

            assert.are.equal(first, second)
            assert.are.equal(0, secondProbeCalls)
            assert.is_false(second:IsReady())
            assert.are.equal(1, #TestEnv.NativeTimers())

            assert.is_not_nil(second:Await(function() end))
            local refused, reason = second:Await(function() end)
            assert.is_nil(refused)
            assert.are.equal("full", reason)
        end
    )

    it("still validates the arguments of a repeated definition", function()
        ReadinessKit:Gate("spellbook", function()
            return true
        end)
        TestEnv.expectErrorContaining("ReadinessKit:Gate probe must be a function", function()
            ReadinessKit:Gate("spellbook", "nope")
        end)
    end)

    it("finds gates by name with Get", function()
        assert.is_nil(ReadinessKit:Get("spellbook"))
        local gate = ReadinessKit:Gate("spellbook", function()
            return true
        end)
        assert.are.equal(gate, ReadinessKit:Get("spellbook"))
    end)

    it("lets a probe look up its own gate while it is being defined", function()
        local seen
        local gate = ReadinessKit:Gate("self", function()
            seen = ReadinessKit:Get("self")
            return true
        end)
        assert.are.equal(gate, seen)
    end)

    it("refuses unknown and malformed options", function()
        local probe = function()
            return true
        end
        TestEnv.expectErrorContaining('options contains unknown field "interval"', function()
            ReadinessKit:Gate("a", probe, { interval = 1 })
        end)
        TestEnv.expectErrorContaining("intervalSeconds must be a finite number", function()
            ReadinessKit:Gate("a", probe, { intervalSeconds = 0 })
        end)
        TestEnv.expectErrorContaining("timeoutSeconds must be false or a finite number", function()
            ReadinessKit:Gate("a", probe, { timeoutSeconds = true })
        end)
        TestEnv.expectErrorContaining("maxWaiters must be a positive integer", function()
            ReadinessKit:Gate("a", probe, { maxWaiters = 1.5 })
        end)
        TestEnv.expectErrorContaining("options must be a table", function()
            ReadinessKit:Gate("a", probe, 5)
        end)
        assert.is_nil(ReadinessKit:Get("a"))
    end)

    it("leaves no gate behind when the host refuses the poll timer", function()
        TestEnv.FailNextTimerCreate("host timer failure")
        local ok, message = pcall(ReadinessKit.Gate, ReadinessKit, "broken", function()
            return false
        end)
        assert.is_false(ok)
        assert.are.equal("host timer failure", message)
        assert.is_nil(ReadinessKit:Get("broken"))
    end)
end)

describe("ReadinessKit gate Close", function()
    local ReadinessKit
    before_each(function()
        ReadinessKit = TestEnv.NewPackage()
    end)
    after_each(TestEnv.Reset)

    it("stops polling, frees the name and calls queued waiters with closed", function()
        local gate = ReadinessKit:Gate("spellbook", function()
            return false
        end)
        local results = {}
        gate:Await(function(ready, reason)
            results[#results + 1] = { ready, reason }
        end)

        assert.is_true(gate:Close())
        assert.is_true(gate:IsClosed())
        assert.is_false(gate:IsReady())
        assert.are.same({ { false, "closed" } }, results)
        assert.are.equal(0, TestEnv.ArmedTimerCount())
        assert.is_nil(ReadinessKit:Get("spellbook"))
        assert.is_false(gate:Close())

        local replacement = ReadinessKit:Gate("spellbook", function()
            return true
        end)
        assert.are_not.equal(gate, replacement)
        assert.is_true(replacement:IsReady())
    end)

    it("refuses to be used after Close", function()
        local gate = ReadinessKit:Gate("spellbook", function()
            return true
        end)
        gate:Close()
        TestEnv.expectErrorContaining("cannot wait on a closed gate", function()
            gate:Await(function() end)
        end)
        TestEnv.expectErrorContaining("cannot probe a closed gate", function()
            gate:Probe()
        end)
        TestEnv.expectErrorContaining("cannot invalidate a closed gate", function()
            gate:Invalidate()
        end)
        TestEnv.expectErrorContaining("cannot subscribe a closed gate", function()
            gate:ReprobeOn("SPELLS_CHANGED")
        end)
    end)

    it("ignores a stale tick from the timer of a closed gate", function()
        local calls = 0
        local gate = ReadinessKit:Gate("spellbook", function()
            calls = calls + 1
            return false
        end)
        gate:Close()
        TestEnv.InvokeRaw(1)
        assert.are.equal(1, calls)
        assert.are.same({}, TestEnv.ReportedErrors())
    end)

    it("can be closed from inside a waiter callback", function()
        local ready = false
        local gate = ReadinessKit:Gate("spellbook", function()
            return ready
        end)
        local results = {}
        gate:Await(function()
            results[#results + 1] = "first"
            gate:Close()
        end)
        gate:Await(function(isReady)
            results[#results + 1] = isReady
        end)

        ready = true
        TestEnv.Poll(500)
        assert.are.same({ "first", true }, results)
        assert.is_true(gate:IsClosed())
        assert.are.same({}, TestEnv.ReportedErrors())
    end)
end)
