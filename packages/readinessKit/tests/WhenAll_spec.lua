local TestEnv = require("ReadinessKitTestEnv")

describe("ReadinessKit WhenAll", function()
    local ReadinessKit
    before_each(function()
        ReadinessKit = TestEnv.NewPackage()
    end)
    after_each(TestEnv.Reset)

    it("calls back with true once every gate is ready", function()
        local spellsReady, itemsReady = false, false
        local spells = ReadinessKit:Gate("spells", function()
            return spellsReady
        end)
        local items = ReadinessKit:Gate("items", function()
            return itemsReady
        end)
        local results = {}
        local waiter = ReadinessKit:WhenAll({ spells, items }, function(ready, reason)
            results[#results + 1] = { ready, reason }
        end)
        assert.is_true(waiter:IsPending())

        spellsReady = true
        TestEnv.Poll(500)
        assert.are.same({}, results)

        itemsReady = true
        TestEnv.Poll(500)
        assert.are.same({ { true } }, results)
        assert.is_false(waiter:IsPending())
    end)

    it("calls back at once when every gate is already ready, and for an empty list", function()
        local gate = ReadinessKit:Gate("ready", function()
            return true
        end)
        local results = {}
        ReadinessKit:WhenAll({ gate, gate }, function(ready)
            results[#results + 1] = ready
        end)
        ReadinessKit:WhenAll({}, function(ready)
            results[#results + 1] = ready
        end)
        assert.are.same({ true, true }, results)
    end)

    it("reports the first timeout once and stops waiting on the rest", function()
        local fast = ReadinessKit:Gate("fast", function()
            return false
        end, { timeoutSeconds = 0.5 })
        local slow = ReadinessKit:Gate("slow", function()
            return false
        end, { timeoutSeconds = 1 })
        local results = {}
        ReadinessKit:WhenAll({ slow, fast }, function(ready, reason)
            results[#results + 1] = { ready, reason }
        end)

        TestEnv.Poll(500)
        assert.are.same({ { false, "timeout" } }, results)
        assert.are.equal(0, rawget(slow, "_waiterCount"))

        TestEnv.Poll(500)
        assert.are.equal(1, #results)
    end)

    it("reports a gate that has already timed out at once", function()
        local failed = ReadinessKit:Gate("failed", function()
            return false
        end, { timeoutSeconds = 0.5 })
        TestEnv.Poll(500)
        local pending = ReadinessKit:Gate("pending", function()
            return false
        end)

        local results = {}
        ReadinessKit:WhenAll({ failed, pending }, function(ready, reason)
            results[#results + 1] = { ready, reason }
        end)
        assert.are.same({ { false, "timeout" } }, results)
        assert.are.equal(0, rawget(pending, "_waiterCount"))
    end)

    it("reports a gate closed while waiting", function()
        local gate = ReadinessKit:Gate("pending", function()
            return false
        end)
        local results = {}
        ReadinessKit:WhenAll({ gate }, function(ready, reason)
            results[#results + 1] = { ready, reason }
        end)
        gate:Close()
        assert.are.same({ { false, "closed" } }, results)
    end)

    it("is bounded by the gates' own caps and leaves nothing queued when refused", function()
        local roomy = ReadinessKit:Gate("roomy", function()
            return false
        end)
        local tight = ReadinessKit:Gate("tight", function()
            return false
        end, { maxWaiters = 1 })
        tight:Await(function() end)

        local waiter, reason = ReadinessKit:WhenAll({ roomy, tight }, function() end)
        assert.is_nil(waiter)
        assert.are.equal("full", reason)
        assert.are.equal(0, rawget(roomy, "_waiterCount"))
    end)

    it("cancels every per-gate waiter", function()
        local ready = false
        local first = ReadinessKit:Gate("first", function()
            return ready
        end)
        local second = ReadinessKit:Gate("second", function()
            return ready
        end)
        local calls = 0
        local waiter = ReadinessKit:WhenAll({ first, second }, function()
            calls = calls + 1
        end)
        assert.is_true(waiter:Cancel())
        assert.are.equal(0, rawget(first, "_waiterCount"))
        assert.are.equal(0, rawget(second, "_waiterCount"))

        ready = true
        TestEnv.Poll(500)
        assert.are.equal(0, calls)
    end)

    it("refuses a closed gate and anything that is not a gate", function()
        local gate = ReadinessKit:Gate("closed", function()
            return true
        end)
        gate:Close()
        TestEnv.expectErrorContaining(
            "ReadinessKit:WhenAll cannot wait on a closed gate",
            function()
                ReadinessKit:WhenAll({ gate }, function() end)
            end
        )
        TestEnv.expectErrorContaining("gates must be an array of ReadinessKit gates", function()
            ReadinessKit:WhenAll({ {} }, function() end)
        end)
    end)
end)
