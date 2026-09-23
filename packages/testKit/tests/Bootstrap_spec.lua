local TestEnv = require("TestKitTestEnv")

describe("TestKit bootstrap", function()
    after_each(TestEnv.Reset)

    it("returns the same facade and keeps suites on duplicate embedded load", function()
        local TestKit = TestEnv.NewPackage()
        local suite = TestKit:Suite("MyAddon")

        local reloaded = TestEnv.ReloadPackage()
        assert.are.equal(TestKit, reloaded)
        local again, reason = reloaded:Suite("MyAddon")
        assert.is_nil(again)
        assert.are.equal("taken", reason)
        assert.are.equal("MyAddon", suite:GetName())
    end)

    it("publishes through Registry", function()
        local TestKit, Registry = TestEnv.NewPackage()
        local registered, revision = Registry:Get("testKit", 1)
        assert.are.equal(TestKit, registered)
        assert.are.equal(TestKit.REVISION, revision)
    end)

    it("does not reinterpret private state owned by a newer compatible revision", function()
        local TestKit, Registry = TestEnv.NewPackage()
        local shippedRevision = TestKit.REVISION
        local upgraded, previous = Registry:Register("testKit", 1, 99)
        assert.are.equal(TestKit, upgraded)
        assert.are.equal(shippedRevision, previous)

        rawset(TestKit, "REVISION", 99)
        rawset(TestKit, "_state", { schema = 999 })
        package.loaded["TestKit"] = nil

        local reloaded = require("TestKit")
        assert.are.equal(TestKit, reloaded)
        assert.are.equal(99, reloaded.REVISION)
    end)

    it("upgrades in place and keeps suites, results, a waiting test and a queued suite", function()
        local TestKit = TestEnv.NewReadyPackage("MyAddon")
        local reports = {}
        TestKit:OnFinished(function(report)
            reports[#reports + 1] = report
        end)
        local received = nil
        local target = { value = 1 }
        local suite = TestKit:Suite("MyAddon")
        suite:Test("done before", function() end)
        suite:Test("waits across the upgrade", function(ctx)
            ctx:Replace(target, "value", 2)
            local _, payload = ctx:WaitFor("UPGRADE_EVENT", 5)
            received = payload
            ctx:Expect(payload):ToBe("after")
        end)
        TestKit:Suite("Late", { addonName = "LateAddon" })
            :Test("queued across the upgrade", function() end)
        TestKit:Run()
        TestEnv.RenderFrames(2)

        local upgraded = TestEnv.LoadRevision(2)
        assert.are.equal(TestKit, upgraded)
        assert.are.equal(2, upgraded.REVISION)

        TestEnv.Emit("UPGRADE_EVENT", "after")
        TestEnv.RenderFrames(2)
        assert.are.equal("after", received)
        assert.are.equal(1, target.value)

        TestEnv.LoadAddon("LateAddon")
        TestEnv.RenderFrames(2)
        assert.are.equal(1, #reports)
        assert.are.same(
            { suites = 2, tests = 3, passed = 3, failed = 0, skipped = 0, timeout = 0 },
            reports[1].totals
        )
        assert.are.same({ nil, "taken" }, { upgraded:Suite("MyAddon") })
    end)

    it("requires Registry", function()
        TestEnv.Reset()
        TestEnv.InstallWowApi()
        local ok, value = pcall(require, "TestKit")
        assert.is_false(ok)
        assert.is_truthy(tostring(value):find("requires Registry API 2", 1, true))
    end)

    it("requires LifecycleKit", function()
        TestEnv.Reset()
        TestEnv.InstallWowApi()
        require("Registry")
        local ok, value = pcall(require, "TestKit")
        assert.is_false(ok)
        assert.is_truthy(tostring(value):find("requires LifecycleKit API 1", 1, true))
    end)

    it("requires SchedulerKit", function()
        TestEnv.Reset()
        TestEnv.InstallWowApi()
        require("Registry")
        require("SignalKit")
        require("EventKit")
        require("LifecycleKit")
        local ok, value = pcall(require, "TestKit")
        assert.is_false(ok)
        assert.is_truthy(tostring(value):find("requires SchedulerKit API 1", 1, true))
    end)

    it("refuses an incomplete facade left by an earlier failed load", function()
        TestEnv.Reset()
        TestEnv.InstallWowApi()
        local Registry = require("Registry")
        require("SignalKit")
        require("EventKit")
        require("LifecycleKit")
        require("TimerKit")
        require("SchedulerKit")
        Registry:Register("testKit", 1, 1)

        local ok, value = pcall(TestEnv.requireAfterFailedLoad, "TestKit")
        assert.is_false(ok)
        assert.is_truthy(tostring(value):find("MoltenCodes TestKit", 1, true))
    end)
end)
