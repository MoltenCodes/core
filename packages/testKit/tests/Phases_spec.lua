local TestEnv = require("TestKitTestEnv")

describe("TestKit phase gating", function()
    local TestKit, LifecycleKit
    local finished

    before_each(function()
        local loaded = { TestEnv.NewPackage() }
        TestKit = loaded[1]
        LifecycleKit = loaded[5]
        finished = {}
        TestKit:OnFinished(function(report)
            finished[#finished + 1] = report
        end)
    end)
    after_each(TestEnv.Reset)

    it("queues a ready suite until the player logs in", function()
        local ran = false
        TestKit:Suite("MyAddon"):Test("runs", function()
            ran = true
        end)
        TestEnv.LoadAddon("MyAddon")

        assert.are.equal(1, TestKit:Run())
        TestEnv.RenderFrames(5)
        assert.is_false(ran)
        assert.are.equal(0, #finished)
        assert.are.equal(0, TestKit:Report().totals.tests)

        TestEnv.Login()
        TestEnv.RenderFrames(2)
        assert.is_true(ran)
        assert.are.equal(1, #finished)
        assert.are.equal(1, finished[1].totals.passed)
    end)

    it("runs a loaded suite once its addon has loaded, before login", function()
        local ran = false
        TestKit:Suite("Early", { phase = "loaded", addonName = "MyAddon" }):Test("runs", function()
            ran = true
        end)
        TestKit:Run()
        TestEnv.RenderFrames(3)
        assert.is_false(ran)

        TestEnv.LoadAddon("MyAddon")
        TestEnv.RenderFrames(2)
        assert.is_true(ran)
        assert.are.equal("MyAddon", TestKit:Report().suites[1].addonName)
    end)

    it("waits on the suite's own name when no addonName is given", function()
        local ran = false
        TestKit:Suite("OtherAddon", { phase = "loaded" }):Test("runs", function()
            ran = true
        end)
        TestEnv.LoadAddon("MyAddon")
        TestKit:Run()
        TestEnv.RenderFrames(3)
        assert.is_false(ran)
        TestEnv.LoadAddon("OtherAddon")
        TestEnv.RenderFrames(2)
        assert.is_true(ran)
    end)

    it("runs ready suites while another waits, and finishes only when the last one ran", function()
        local order = {}
        TestKit:Suite("Late", { addonName = "LateAddon" }):Test("late", function()
            order[#order + 1] = "late"
        end)
        TestKit:Suite("MyAddon"):Test("early", function()
            order[#order + 1] = "early"
        end)
        TestEnv.LoadAddon("MyAddon")
        TestEnv.Login()

        assert.are.equal(2, TestKit:Run())
        TestEnv.RenderFrames(3)
        assert.are.same({ "early" }, order)
        assert.are.equal(0, #finished)

        TestEnv.LoadAddon("LateAddon")
        TestEnv.RenderFrames(2)
        assert.are.same({ "early", "late" }, order)
        assert.are.equal(1, #finished)
        assert.are.equal(2, finished[1].totals.tests)
    end)

    it("does not queue a suite twice while it is waiting or queued", function()
        TestKit:Suite("MyAddon"):Test("runs", function() end)
        assert.are.equal(1, TestKit:Run())
        assert.are.equal(0, TestKit:Run())
        assert.are.equal(0, TestKit:Run("MyAddon"))
        TestEnv.LoadAddon("MyAddon")
        TestEnv.Login()
        TestEnv.RenderFrames(2)
        assert.are.equal(1, #finished)
        assert.are.equal(1, finished[1].totals.tests)
    end)

    it("skips the tests of a suite whose phase can no longer be reached", function()
        TestKit:Suite("MyAddon"):Test("never", function() end)
        LifecycleKit:ForAddon("MyAddon"):Halt("broken saved variables")

        assert.are.equal(1, TestKit:Run())
        TestEnv.Frame()
        assert.are.equal(1, #finished)
        local result = finished[1].suites[1].tests[1]
        assert.are.equal("skipped", result.status)
        assert.are.equal('the ready phase of "MyAddon" can no longer be reached', result.message)
    end)
end)
