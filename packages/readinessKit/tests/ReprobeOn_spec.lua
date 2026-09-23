local TestEnv = require("ReadinessKitTestEnv")

---Whether any stub frame still has `eventName` registered.
---@param eventName string
---@return boolean
local function isRegistered(eventName)
    local frames = TestEnv.Frames()
    for index = 1, #frames do
        if frames[index].registrations[eventName] ~= nil then
            return true
        end
    end
    return false
end

describe("ReadinessKit ReprobeOn", function()
    after_each(TestEnv.Reset)

    it("re-runs the probe when the event fires, ignoring the negative cache", function()
        local ReadinessKit = TestEnv.NewPackage()
        local ready = false
        local calls = 0
        local gate = ReadinessKit:Gate("spellbook", function()
            calls = calls + 1
            return ready
        end)
        assert.is_true(gate:ReprobeOn("SPELLS_CHANGED"))
        assert.is_false(gate:ReprobeOn("SPELLS_CHANGED"))
        local results = {}
        gate:Await(function(isReady)
            results[#results + 1] = isReady
        end)

        TestEnv.Emit("SPELLS_CHANGED")
        assert.are.equal(2, calls)
        assert.are.same({}, results)

        ready = true
        TestEnv.Emit("SPELLS_CHANGED")
        assert.are.same({ true }, results)
        assert.are.equal(0, TestEnv.ArmedTimerCount())
    end)

    it("leaves a ready gate alone", function()
        local ReadinessKit = TestEnv.NewPackage()
        local calls = 0
        local gate = ReadinessKit:Gate("spellbook", function()
            calls = calls + 1
            return true
        end)
        gate:ReprobeOn("SPELLS_CHANGED")
        TestEnv.Emit("SPELLS_CHANGED")
        assert.are.equal(1, calls)
    end)

    it("restarts polling on a timed-out gate that is still not ready", function()
        local ReadinessKit = TestEnv.NewPackage()
        local gate = ReadinessKit:Gate("spellbook", function()
            return false
        end, { timeoutSeconds = 0.5 })
        gate:ReprobeOn("SPELLS_CHANGED")
        TestEnv.Poll(500)
        assert.are.equal(0, TestEnv.ArmedTimerCount())

        TestEnv.Emit("SPELLS_CHANGED")
        assert.are.equal(1, TestEnv.ArmedTimerCount())
    end)

    it("releases its connections on Close", function()
        local ReadinessKit = TestEnv.NewPackage()
        local calls = 0
        local gate = ReadinessKit:Gate("spellbook", function()
            calls = calls + 1
            return false
        end)
        gate:ReprobeOn("SPELLS_CHANGED")
        gate:ReprobeOn("LEARNED_SPELL_IN_TAB")
        assert.is_true(isRegistered("SPELLS_CHANGED"))

        gate:Close()
        assert.is_false(isRegistered("SPELLS_CHANGED"))
        assert.is_false(isRegistered("LEARNED_SPELL_IN_TAB"))
        TestEnv.Emit("SPELLS_CHANGED")
        assert.are.equal(1, calls)
    end)

    it("leaves a gate closed during the dispatch in flight alone", function()
        local ReadinessKit, _, _, EventKit = TestEnv.NewPackage()
        local calls = 0
        local gate = ReadinessKit:Gate("spellbook", function()
            calls = calls + 1
            return false
        end)
        EventKit:Connect("SPELLS_CHANGED", function()
            gate:Close()
        end)
        gate:ReprobeOn("SPELLS_CHANGED")

        TestEnv.Emit("SPELLS_CHANGED")
        assert.is_true(gate:IsClosed())
        assert.are.equal(1, calls)
        assert.are.same({}, TestEnv.ReportedErrors())
    end)

    it("raises at the caller when EventKit is not available", function()
        local ReadinessKit = TestEnv.NewPackageWithoutEventKit()
        local gate = ReadinessKit:Gate("spellbook", function()
            return false
        end)
        TestEnv.expectErrorContaining(
            "ReadinessKit.Gate:ReprobeOn requires EventKit API 1, which is not loaded (absent)",
            function()
                gate:ReprobeOn("SPELLS_CHANGED")
            end
        )
        assert.is_false(gate:IsClosed())
        assert.is_true(gate:Close())
    end)
end)
