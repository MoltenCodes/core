local TestEnv = require("LifecycleKitTestEnv")

describe("LifecycleKit phase subscriptions", function()
    local LifecycleKit
    before_each(function()
        LifecycleKit = TestEnv.NewPackage()
    end)
    after_each(TestEnv.Reset)

    it("delivers loaded, ready, and shutdown once in order", function()
        local life = LifecycleKit:ForAddon("MyAddon")
        local seen = {}
        life:OnLoaded(function()
            seen[#seen + 1] = "loaded"
        end)
        life:OnReady(function()
            seen[#seen + 1] = "ready"
        end)
        life:OnShutdown(function()
            seen[#seen + 1] = "shutdown"
        end)
        TestEnv.LoadAddon("MyAddon")
        TestEnv.Login()
        TestEnv.Logout()
        assert.are.same({ "loaded", "ready", "shutdown" }, seen)
    end)

    it("replays already reached phases synchronously", function()
        local life = LifecycleKit:ForAddon("MyAddon")
        TestEnv.LoadAddon("MyAddon")
        TestEnv.Login()
        local calls = 0
        local subscription = life:OnReady(function(instance)
            calls = calls + 1
            assert.are.equal(life, instance)
        end)
        assert.are.equal(1, calls)
        assert.is_false(subscription:IsConnected())
        assert.is_false(subscription:Disconnect())
    end)

    it("allows pending subscriptions to disconnect", function()
        local life = LifecycleKit:ForAddon("MyAddon")
        local calls = 0
        local subscription = life:OnLoaded(function()
            calls = calls + 1
        end)
        assert.is_true(subscription:IsConnected())
        assert.is_true(subscription:Disconnect())
        assert.is_false(subscription:Disconnect())
        TestEnv.LoadAddon("MyAddon")
        assert.are.equal(0, calls)
    end)

    it("marks a subscription disconnected before invoking its callback", function()
        local life = LifecycleKit:ForAddon("MyAddon")
        local subscription
        subscription = life:OnLoaded(function()
            assert.is_false(subscription:IsConnected())
        end)
        TestEnv.LoadAddon("MyAddon")
    end)

    it("does not let a loaded callback error prevent known ready progression", function()
        TestEnv.SetLoggedIn(true)
        local life = LifecycleKit:ForAddon("MyAddon")
        local readyCalls = 0
        life:OnLoaded(function()
            error("loaded failure")
        end)
        life:OnReady(function()
            readyCalls = readyCalls + 1
        end)
        TestEnv.LoadAddon("MyAddon")

        -- EventKit reports the re-raised callback error through the host error
        -- handler; the known ready progression still happened before it.
        local reported = TestEnv.TakeReportedErrors()
        assert.are.equal(1, #reported)
        assert.is_not_nil(string.find(tostring(reported[1].value), "loaded failure", 1, true))
        assert.is_true(life:IsReady())
        assert.are.equal(1, readyCalls)
    end)

    it("disconnects impossible loaded and ready subscriptions at shutdown", function()
        local life = LifecycleKit:ForAddon("LazyAddon")
        local loadedCalls = 0
        local readyCalls = 0
        local loaded = life:OnLoaded(function()
            loadedCalls = loadedCalls + 1
        end)
        local ready = life:OnReady(function()
            readyCalls = readyCalls + 1
        end)

        TestEnv.Logout()

        assert.is_true(life:IsShutdown())
        assert.is_false(loaded:IsConnected())
        assert.is_false(ready:IsConnected())
        assert.is_false(loaded:Disconnect())
        assert.is_false(ready:Disconnect())
        assert.are.equal(0, loadedCalls)
        assert.are.equal(0, readyCalls)
    end)

    it("returns disconnected subscriptions for impossible phases after shutdown", function()
        local life = LifecycleKit:ForAddon("LazyAddon")
        TestEnv.Logout()

        local loadedCalls = 0
        local readyCalls = 0
        local loaded = life:OnLoaded(function()
            loadedCalls = loadedCalls + 1
        end)
        local ready = life:OnReady(function()
            readyCalls = readyCalls + 1
        end)

        assert.is_false(loaded:IsConnected())
        assert.is_false(ready:IsConnected())
        assert.are.equal(0, loadedCalls)
        assert.are.equal(0, readyCalls)
    end)
end)
