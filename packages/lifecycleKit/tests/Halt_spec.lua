local TestEnv = require("LifecycleKitTestEnv")

-- The halted state: an addon declares itself non-functional, every phase it
-- has not reached becomes unreachable, and the addons that declared it with
-- `DependsOn` are told. Halted is terminal for the session.

describe("LifecycleKit Halt", function()
    local LifecycleKit
    before_each(function()
        LifecycleKit = TestEnv.NewPackage()
    end)
    after_each(TestEnv.Reset)

    it("moves the addon to the halted state and keeps the reason", function()
        local life = LifecycleKit:ForAddon("MyAddon")
        assert.is_false(life:IsHalted())
        assert.is_nil(life:GetHaltReason())

        assert.is_true(life:Halt("saved variables are corrupted"))

        assert.are.equal("halted", life:GetState())
        assert.is_true(life:IsHalted())
        assert.are.equal("saved variables are corrupted", life:GetHaltReason())
        assert.is_false(life:Halt("a second reason"))
        assert.are.equal("saved variables are corrupted", life:GetHaltReason())
    end)

    it("stays halted through the phases the host still sends", function()
        local life = LifecycleKit:ForAddon("MyAddon")
        life:Halt("incompatible client")

        TestEnv.LoadAddon("MyAddon")
        TestEnv.Login()
        TestEnv.Logout()

        assert.are.equal("halted", life:GetState())
        assert.is_false(life:IsLoaded())
        assert.is_false(life:IsReady())
        assert.is_false(life:IsShutdown())
    end)

    it("disconnects every pending phase subscription without invoking it", function()
        local life = LifecycleKit:ForAddon("MyAddon")
        local calls = 0
        local function count()
            calls = calls + 1
        end
        local loaded = life:OnLoaded(count)
        local ready = life:OnReady(count)
        local shutdown = life:OnShutdown(count)

        life:Halt("dependency missing")

        assert.is_false(loaded:IsConnected())
        assert.is_false(ready:IsConnected())
        assert.is_false(shutdown:IsConnected())
        TestEnv.LoadAddon("MyAddon")
        TestEnv.Login()
        TestEnv.Logout()
        assert.are.equal(0, calls)
    end)

    it("still replays phases reached before the halt and refuses the rest", function()
        local life = LifecycleKit:ForAddon("MyAddon")
        TestEnv.LoadAddon("MyAddon")
        life:Halt("broken")

        local loadedCalls = 0
        local replayed = life:OnLoaded(function()
            loadedCalls = loadedCalls + 1
        end)
        local ready = life:OnReady(function() end)

        assert.are.equal(1, loadedCalls)
        assert.is_false(replayed:IsConnected())
        assert.is_false(ready:IsConnected())
    end)

    it("halts from inside a phase callback without reaching ready", function()
        TestEnv.SetLoggedIn(true)
        local life = LifecycleKit:ForAddon("MyAddon")
        local readyCalls = 0
        life:OnLoaded(function(instance)
            instance:Halt("saved variables are corrupted")
        end)
        life:OnReady(function()
            readyCalls = readyCalls + 1
        end)

        TestEnv.LoadAddon("MyAddon")

        assert.are.equal("halted", life:GetState())
        assert.is_false(life:IsReady())
        assert.are.equal(0, readyCalls)
    end)

    it("delivers OnHalted with the reason and replays it afterwards", function()
        local life = LifecycleKit:ForAddon("MyAddon")
        local received = {}
        local pending = life:OnHalted(function(instance, reason)
            received[#received + 1] = { instance = instance, reason = reason }
        end)
        assert.is_true(pending:IsConnected())

        life:Halt("broken")

        assert.is_false(pending:IsConnected())
        local replayed = life:OnHalted(function(instance, reason)
            received[#received + 1] = { instance = instance, reason = reason }
        end)
        assert.is_false(replayed:IsConnected())
        assert.are.same({
            { instance = life, reason = "broken" },
            { instance = life, reason = "broken" },
        }, received)
    end)

    it("delivers every OnHalted subscriber and re-raises the first error", function()
        local life = LifecycleKit:ForAddon("MyAddon")
        local errorObject = { reason = "halted callback failure" }
        local delivered = 0
        life:OnHalted(function()
            delivered = delivered + 1
            error(errorObject)
        end)
        life:OnHalted(function()
            delivered = delivered + 1
            error("second failure")
        end)

        local ok, message = pcall(function()
            life:Halt("broken")
        end)

        assert.is_false(ok)
        assert.are.equal(errorObject, message)
        assert.are.equal(2, delivered)
        assert.is_true(life:IsHalted())
    end)

    it("cannot halt after shutdown, and OnHalted is then unreachable", function()
        local life = LifecycleKit:ForAddon("MyAddon")
        local calls = 0
        local pending = life:OnHalted(function()
            calls = calls + 1
        end)
        TestEnv.Logout()

        assert.is_false(pending:IsConnected())
        assert.is_false(life:Halt("too late"))
        assert.are.equal("shutdown", life:GetState())
        assert.is_false(life:OnHalted(function()
            calls = calls + 1
        end):IsConnected())
        assert.are.equal(0, calls)
    end)

    it("closes the combat queue with false and 'halted'", function()
        local life = LifecycleKit:ForAddon("MyAddon")
        TestEnv.EnterCombat()
        local received
        local handle = life:WhenOutOfCombat(function(instance, ran, reason)
            received = { instance = instance, ran = ran, reason = reason }
        end)

        life:Halt("broken")

        assert.are.same({ instance = life, ran = false, reason = "halted" }, received)
        assert.is_false(handle:IsPending())
        local refused, reason = life:WhenOutOfCombat(function() end)
        assert.is_nil(refused)
        assert.are.equal("halted", reason)
    end)

    it("disconnects combat subscriptions", function()
        local life = LifecycleKit:ForAddon("MyAddon")
        TestEnv.LoadAddon("MyAddon")
        local starts = 0
        local subscription = life:OnCombatStart(function()
            starts = starts + 1
        end)

        life:Halt("broken")
        TestEnv.EnterCombat()

        assert.is_false(subscription:IsConnected())
        assert.are.equal(0, starts)
        assert.is_false(life:OnCombatEnd(function() end):IsConnected())
    end)

    it("still closes the addon's EventKit scope at logout", function()
        local life = LifecycleKit:ForAddon("MyAddon")
        local EventKit = require("EventKit")
        local scope = EventKit:ForAddon("MyAddon")
        scope:Connect("CHAT_MSG_SAY", function() end)
        life:Halt("broken")
        assert.is_false(scope:IsClosed())

        TestEnv.Logout()

        assert.is_true(scope:IsClosed())
        assert.are.equal("halted", life:GetState())
    end)
end)

describe("LifecycleKit dependencies", function()
    local LifecycleKit
    before_each(function()
        LifecycleKit = TestEnv.NewPackage()
    end)
    after_each(TestEnv.Reset)

    it("tells a dependent when its dependency halts later", function()
        local library = LifecycleKit:ForAddon("MyLibrary")
        local consumer = LifecycleKit:ForAddon("MyConsumer")
        local received = {}
        consumer:OnDependencyHalted(function(instance, dependencyName, reason)
            received[#received + 1] = { instance, dependencyName, reason }
        end)

        assert.is_true(consumer:DependsOn("MyLibrary"))
        library:Halt("invariant violated")

        assert.are.same({ { consumer, "MyLibrary", "invariant violated" } }, received)
    end)

    it("records a dependency on an addon that has no lifecycle instance yet", function()
        local consumer = LifecycleKit:ForAddon("MyConsumer")
        local received = {}
        consumer:OnDependencyHalted(function(_, dependencyName)
            received[#received + 1] = dependencyName
        end)
        consumer:DependsOn("MyLibrary")

        LifecycleKit:ForAddon("MyLibrary"):Halt("broken")

        assert.are.same({ "MyLibrary" }, received)
    end)

    it("fires at once for a dependency that has already halted", function()
        LifecycleKit:ForAddon("MyLibrary"):Halt("broken")
        local consumer = LifecycleKit:ForAddon("MyConsumer")
        local received = {}
        consumer:OnDependencyHalted(function(_, dependencyName, reason)
            received[#received + 1] = dependencyName .. ":" .. reason
        end)

        assert.is_true(consumer:DependsOn("MyLibrary"))

        assert.are.same({ "MyLibrary:broken" }, received)
    end)

    it("replays halted dependencies to a later subscriber exactly once", function()
        LifecycleKit:ForAddon("MyLibrary"):Halt("broken")
        local consumer = LifecycleKit:ForAddon("MyConsumer")
        consumer:DependsOn("MyLibrary")
        local received = 0

        local subscription = consumer:OnDependencyHalted(function()
            received = received + 1
        end)

        assert.are.equal(1, received)
        assert.is_true(subscription:IsConnected())
        LifecycleKit:ForAddon("OtherLibrary"):Halt("unrelated")
        assert.are.equal(1, received)
    end)

    it("does not tell addons that did not declare the dependency", function()
        local library = LifecycleKit:ForAddon("MyLibrary")
        local bystander = LifecycleKit:ForAddon("Bystander")
        local received = 0
        bystander:OnDependencyHalted(function()
            received = received + 1
        end)

        library:Halt("broken")

        assert.are.equal(0, received)
    end)

    it("cascades when a dependent halts in response", function()
        local base = LifecycleKit:ForAddon("Base")
        local middle = LifecycleKit:ForAddon("Middle")
        local top = LifecycleKit:ForAddon("Top")
        middle:DependsOn("Base")
        top:DependsOn("Middle")
        middle:OnDependencyHalted(function(instance, dependencyName)
            instance:Halt("dependency " .. dependencyName .. " halted")
        end)
        local topReason
        top:OnDependencyHalted(function(_, _, reason)
            topReason = reason
        end)

        base:Halt("broken")

        assert.is_true(middle:IsHalted())
        assert.are.equal("dependency Base halted", topReason)
    end)

    it("does not tell a dependent that is itself halted or shut down", function()
        local library = LifecycleKit:ForAddon("MyLibrary")
        local consumer = LifecycleKit:ForAddon("MyConsumer")
        consumer:DependsOn("MyLibrary")
        local received = 0
        local subscription = consumer:OnDependencyHalted(function()
            received = received + 1
        end)

        consumer:Halt("own reason")
        library:Halt("broken")

        assert.are.equal(0, received)
        assert.is_false(subscription:IsConnected())
    end)

    it("isolates failing dependents and re-raises the first error from Halt", function()
        local library = LifecycleKit:ForAddon("MyLibrary")
        local first = LifecycleKit:ForAddon("FirstConsumer")
        local second = LifecycleKit:ForAddon("SecondConsumer")
        first:DependsOn("MyLibrary")
        second:DependsOn("MyLibrary")
        local secondCalls = 0
        first:OnDependencyHalted(function()
            error("first consumer failure", 0)
        end)
        second:OnDependencyHalted(function()
            secondCalls = secondCalls + 1
        end)

        local ok, message = pcall(function()
            library:Halt("broken")
        end)

        assert.is_false(ok)
        assert.are.equal("first consumer failure", message)
        assert.are.equal(1, secondCalls)
        assert.is_true(library:IsHalted())
    end)

    it("records each dependency once", function()
        local consumer = LifecycleKit:ForAddon("MyConsumer")
        assert.is_true(consumer:DependsOn("MyLibrary"))
        assert.is_false(consumer:DependsOn("MyLibrary"))
    end)

    it("refuses more than 16 dependencies", function()
        local consumer = LifecycleKit:ForAddon("MyConsumer")
        for index = 1, 16 do
            assert.is_true(consumer:DependsOn("Library" .. index))
        end

        local recorded, reason = consumer:DependsOn("Library17")

        assert.is_nil(recorded)
        assert.are.equal("full", reason)
        assert.is_false(consumer:DependsOn("Library1"))
    end)

    it("refuses new dependencies once halted or shut down", function()
        local halted = LifecycleKit:ForAddon("HaltedAddon")
        halted:Halt("broken")
        local recorded, reason = halted:DependsOn("MyLibrary")
        assert.is_nil(recorded)
        assert.are.equal("halted", reason)

        local closed = LifecycleKit:ForAddon("ClosedAddon")
        TestEnv.Logout()
        recorded, reason = closed:DependsOn("MyLibrary")
        assert.is_nil(recorded)
        assert.are.equal("shutdown", reason)
    end)

    it("disconnects dependency subscriptions at shutdown", function()
        local consumer = LifecycleKit:ForAddon("MyConsumer")
        local subscription = consumer:OnDependencyHalted(function() end)
        TestEnv.Logout()
        assert.is_false(subscription:IsConnected())
    end)
end)
