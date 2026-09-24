local TestEnv = require("ReadinessKitTestEnv")

describe("ReadinessKit bootstrap", function()
    after_each(TestEnv.Reset)

    it("returns the same facade and keeps gates on duplicate embedded load", function()
        local ReadinessKit = TestEnv.NewPackage()
        local gate = ReadinessKit:Gate("spellbook", function()
            return true
        end)

        local reloaded = TestEnv.ReloadPackage()
        assert.are.equal(ReadinessKit, reloaded)
        assert.are.equal(gate, reloaded:Get("spellbook"))
    end)

    it("publishes through Registry", function()
        local ReadinessKit, Registry = TestEnv.NewPackage()
        local registered, revision = Registry:Get("readinessKit", 1)
        assert.are.equal(ReadinessKit, registered)
        assert.are.equal(ReadinessKit.REVISION, revision)
    end)

    it("does not reinterpret private state owned by a newer compatible revision", function()
        local ReadinessKit, Registry = TestEnv.NewPackage()
        local shippedRevision = ReadinessKit.REVISION
        local upgraded, previous = Registry:Register("readinessKit", 1, 99)
        assert.are.equal(ReadinessKit, upgraded)
        assert.are.equal(shippedRevision, previous)

        rawset(ReadinessKit, "REVISION", 99)
        rawset(ReadinessKit, "_state", { schema = 999 })
        package.loaded["ReadinessKit"] = nil

        local reloaded = require("ReadinessKit")
        assert.are.equal(ReadinessKit, reloaded)
        assert.are.equal(99, reloaded.REVISION)
    end)

    it("upgrades in place and keeps every gate, waiter, timer and subscription", function()
        TestEnv.Reset()
        TestEnv.InstallWowApi()
        require("Registry")
        require("SignalKit")
        require("EventKit")
        require("TimerKit")
        local ReadinessKit = TestEnv.LoadRevision(1)
        -- Revision 1 kept no UNBOUNDED sentinel.
        rawset(ReadinessKit._state, "unbounded", nil)
        rawset(ReadinessKit, "UNBOUNDED", nil)
        local spellsReady, itemsReady = false, false
        local spells = ReadinessKit:Gate("spells", function()
            return spellsReady
        end)
        local items = ReadinessKit:Gate("items", function()
            return itemsReady
        end)
        items:ReprobeOn("GET_ITEM_INFO_RECEIVED")
        local results = {}
        local waiter = spells:Await(function(ready)
            results[#results + 1] = { "spells", ready }
        end)
        ReadinessKit:WhenAll({ spells, items }, function(ready)
            results[#results + 1] = { "all", ready }
        end)

        package.loaded["ReadinessKit"] = nil
        local upgraded = require("ReadinessKit")
        assert.are.equal(ReadinessKit, upgraded)
        assert.is_true(upgraded.REVISION > 1)
        assert.are.equal("table", type(upgraded.UNBOUNDED))
        assert.are.equal(spells, upgraded:Get("spells"))
        assert.is_true(waiter:IsPending())

        -- The poll timer armed by revision 1 is served by revision 2.
        spellsReady = true
        TestEnv.Poll(500)
        assert.are.same({ { "spells", true } }, results)

        -- So is the re-probe connection.
        itemsReady = true
        TestEnv.Emit("GET_ITEM_INFO_RECEIVED")
        assert.are.same({ { "spells", true }, { "all", true } }, results)
        assert.are.equal(0, TestEnv.ArmedTimerCount())
    end)

    it("upgrades the previous revision in place and keeps its gates and waiters", function()
        local current = TestEnv.NewPackage().REVISION
        TestEnv.Reset()
        TestEnv.InstallWowApi()
        require("Registry")
        require("SignalKit")
        require("EventKit")
        require("TimerKit")
        local ReadinessKit = TestEnv.LoadRevision(current - 1)
        local state = ReadinessKit._state
        local ready = false
        local gate = ReadinessKit:Gate("talents", function()
            return ready
        end)
        local results = {}
        local waiter = gate:Await(function(isReady)
            results[#results + 1] = isReady
        end)

        package.loaded["ReadinessKit"] = nil
        local upgraded = require("ReadinessKit")
        assert.are.equal(ReadinessKit, upgraded)
        assert.are.equal(state, upgraded._state)
        assert.are.equal(current, upgraded.REVISION)
        assert.are.equal(gate, upgraded:Get("talents"))
        assert.is_true(waiter:IsPending())

        ready = true
        TestEnv.Poll(500)
        assert.are.same({ true }, results)
    end)

    it("requires Registry", function()
        TestEnv.Reset()
        TestEnv.InstallWowApi()
        local ok, value = pcall(require, "ReadinessKit")
        assert.is_false(ok)
        assert.is_true(tostring(value):find("Registry API 2", 1, true) ~= nil)
    end)

    it("loads with its three-file minimum footprint", function()
        local ReadinessKit, Registry = TestEnv.NewPackageWithoutEventKit()

        assert.is_nil(Registry:Find("lifecycleKit", 1))
        assert.is_nil(Registry:Find("eventKit", 1))
        local ready = false
        local gate = ReadinessKit:Gate("footprint", function()
            return ready
        end)
        assert.is_false(gate:IsReady())

        -- The poll runs on TimerKit, which is part of the footprint.
        ready = true
        TestEnv.Poll(1000)
        assert.is_true(gate:IsReady())
    end)

    it("requires TimerKit", function()
        TestEnv.Reset()
        TestEnv.InstallWowApi()
        require("Registry")
        local ok, value = pcall(require, "ReadinessKit")
        assert.is_false(ok)
        assert.is_true(tostring(value):find("requires TimerKit API 1", 1, true) ~= nil)
    end)

    it("refuses an incomplete facade left by an earlier failed load", function()
        TestEnv.Reset()
        TestEnv.InstallWowApi()
        local Registry = require("Registry")
        require("TimerKit")
        Registry:Register("readinessKit", 1, 1)

        local ok, value = pcall(TestEnv.requireAfterFailedLoad, "ReadinessKit")
        assert.is_false(ok)
        assert.is_true(tostring(value):find("MoltenCodes ReadinessKit", 1, true) ~= nil)
    end)
end)
