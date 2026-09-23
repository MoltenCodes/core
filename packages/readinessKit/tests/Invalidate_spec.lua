local TestEnv = require("ReadinessKitTestEnv")

describe("ReadinessKit Invalidate", function()
    local ReadinessKit
    before_each(function()
        ReadinessKit = TestEnv.NewPackage()
    end)
    after_each(TestEnv.Reset)

    it("turns a ready gate back to pending and resumes polling", function()
        local ready = true
        local gate = ReadinessKit:Gate("spellbook", function()
            return ready
        end)
        assert.are.equal(0, #TestEnv.NativeTimers())

        ready = false
        assert.is_true(gate:Invalidate())
        assert.is_false(gate:IsReady())
        assert.are.equal(1, TestEnv.ArmedTimerCount())

        local results = {}
        gate:Await(function(isReady)
            results[#results + 1] = isReady
        end)
        TestEnv.Poll(500)
        assert.are.same({}, results)

        ready = true
        TestEnv.Poll(500)
        assert.are.same({ true }, results)
        assert.is_true(gate:IsReady())
        assert.are.equal(0, TestEnv.ArmedTimerCount())
    end)

    it("does not probe synchronously", function()
        local calls = 0
        local gate = ReadinessKit:Gate("spellbook", function()
            calls = calls + 1
            return true
        end)
        gate:Invalidate()
        assert.are.equal(1, calls)
        assert.is_false(gate:IsReady())
    end)

    it("keeps the timeout window of a gate that is already polling", function()
        local gate = ReadinessKit:Gate("spellbook", function()
            return false
        end, { timeoutSeconds = 1 })
        local results = {}
        gate:Await(function(_, reason)
            results[#results + 1] = reason
        end)
        TestEnv.Poll(500)
        assert.is_false(gate:Invalidate())
        TestEnv.Poll(500)
        assert.are.same({ "timeout" }, results)
    end)

    it("queues a waiter added by a callback during the flush for the next round", function()
        local ready = false
        local gate = ReadinessKit:Gate("spellbook", function()
            return ready
        end)
        local results = {}
        gate:Await(function()
            results[#results + 1] = "first"
            gate:Invalidate()
            gate:Await(function(isReady)
                results[#results + 1] = { "second", isReady }
            end)
        end)

        ready = true
        TestEnv.Poll(500)
        assert.are.same({ "first" }, results)
        TestEnv.Poll(500)
        assert.are.same({ "first", { "second", true } }, results)
    end)
end)
