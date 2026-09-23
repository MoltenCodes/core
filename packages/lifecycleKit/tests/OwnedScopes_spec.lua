local TestEnv = require("LifecycleKitTestEnv")

-- Shutdown closes what the addon owns through the lower Kits' addon scopes:
-- its EventKit scope, its HookKit scope, its CommandKit scope, its CommKit
-- scope and its SignalKit bus, in that order. Apart from CommKit, which also
-- closes its addon scopes from its own shutdown subscription, none of those
-- Kits observes shutdown itself, so LifecycleKit performs the second half of
-- the two-step each of them documents. HookKit, CommandKit and CommKit are
-- optional and found through `Registry:Find`; SignalKit is a required
-- dependency.

---A table with one method, hooked by the specs below.
---@return table target
---@return table calls how often the original ran
local function newTarget()
    local calls = { original = 0 }
    local target = {}
    function target.Refresh()
        calls.original = calls.original + 1
    end
    return target, calls
end

describe("LifecycleKit shutdown of addon-owned scopes", function()
    local LifecycleKit, SignalKit, EventKit, HookKit, CommandKit, CommKit
    before_each(function()
        LifecycleKit, _, SignalKit, EventKit, HookKit, _, CommandKit = TestEnv.NewPackage()
        CommKit = TestEnv.LoadCommKit()
    end)
    after_each(TestEnv.Reset)

    it("undoes the addon's scoped hooks and closes its bus at logout", function()
        local life = LifecycleKit:ForAddon("MyAddon")
        local target, calls = newTarget()
        local hooked = 0
        HookKit:ForAddon("MyAddon"):Hook(target, "Refresh", function()
            hooked = hooked + 1
        end)
        local bus = SignalKit:ForAddon("MyAddon")
        bus:DeclareTopic("Changed", { arguments = 0 })
        local delivered = 0
        local subscription = bus:Subscribe("Changed", function()
            delivered = delivered + 1
        end)
        target.Refresh()
        bus:Publish("Changed")

        TestEnv.Logout()

        assert.is_true(life:IsShutdown())
        assert.is_true(HookKit:ForAddon("MyAddon"):IsClosed())
        assert.is_false(subscription:IsConnected())
        target.Refresh()
        bus:Publish("Changed")
        assert.are.equal(1, hooked)
        assert.are.equal(1, delivered)
        assert.are.equal(2, calls.original)
    end)

    it("runs shutdown callbacks while hooks and the bus still work", function()
        local life = LifecycleKit:ForAddon("MyAddon")
        local target = newTarget()
        local hooked = 0
        HookKit:ForAddon("MyAddon"):Hook(target, "Refresh", function()
            hooked = hooked + 1
        end)
        local bus = SignalKit:ForAddon("MyAddon")
        bus:DeclareTopic("Saving", { arguments = 0 })
        local delivered = 0
        bus:Subscribe("Saving", function()
            delivered = delivered + 1
        end)
        life:OnShutdown(function()
            target.Refresh()
            bus:Publish("Saving")
        end)

        TestEnv.Logout()

        assert.are.equal(1, hooked)
        assert.are.equal(1, delivered)
    end)

    it("closes the scopes of a halted addon at logout too", function()
        local life = LifecycleKit:ForAddon("MyAddon")
        local subscription = SignalKit:ForAddon("MyAddon"):Subscribe("Anything", function() end)
        local hooks = HookKit:ForAddon("MyAddon")
        life:Halt("broken")

        -- A halt closes nothing by itself: the addon may still report its
        -- failure through what it owns until the session ends.
        assert.is_false(hooks:IsClosed())
        assert.is_true(subscription:IsConnected())

        TestEnv.Logout()

        assert.are.equal("halted", life:GetState())
        assert.is_true(hooks:IsClosed())
        assert.is_false(subscription:IsConnected())
        assert.is_true(EventKit:ForAddon("MyAddon"):IsClosed())
    end)

    it("shuts down an addon that never asked for hooks or a bus without error", function()
        local life = LifecycleKit:ForAddon("MyAddon")

        TestEnv.Logout()

        assert.is_true(life:IsShutdown())
        assert.are.same({}, TestEnv.TakeReportedErrors())
        -- `CloseAddonBus` answered `false`, which records nothing; asking now
        -- creates an open bus.
        assert.is_not_nil(SignalKit:ForAddon("MyAddon"):Subscribe("Late", function() end))
    end)

    it("leaves the addon's scoped slash commands inert after logout", function()
        local life = LifecycleKit:ForAddon("MyAddon")
        local runs = 0
        assert.is_true(CommandKit:ForAddon("MyAddon"):Register("mycmd", {
            handler = function()
                runs = runs + 1
            end,
        }))
        assert.is_true(TestEnv.RunSlash("/mycmd"))
        assert.are.equal(1, runs)

        TestEnv.Logout()

        assert.is_true(life:IsShutdown())
        -- The client keeps the slash name; typing it now does nothing.
        assert.is_true(TestEnv.RunSlash("/mycmd"))
        assert.are.equal(1, runs)
        assert.is_false(CommandKit:ForAddon("MyAddon"):IsRegistered("mycmd"))
    end)

    it("disconnects the addon's scoped prefix registrations at logout", function()
        local life = LifecycleKit:ForAddon("MyAddon")
        local comm = CommKit:ForAddon("MyAddon")
        assert.is_not_nil(comm:Register("MyPrefix", function() end))
        assert.are.equal(1, comm:GetRegistrationCount())

        TestEnv.Logout()

        assert.is_true(life:IsShutdown())
        assert.is_true(comm:IsClosed())
        assert.are.equal(0, comm:GetRegistrationCount())
        assert.are.same({}, TestEnv.TakeReportedErrors())
    end)

    it("shuts down unchanged against a CommKit without CloseAddonScopes", function()
        local life = LifecycleKit:ForAddon("MyAddon")
        local comm = CommKit:ForAddon("MyAddon")
        comm:Register("MyPrefix", function() end)
        local original = rawget(CommKit, "CloseAddonScopes")
        rawset(CommKit, "CloseAddonScopes", nil)

        TestEnv.Logout()

        rawset(CommKit, "CloseAddonScopes", original)
        assert.is_true(life:IsShutdown())
        assert.is_true(EventKit:ForAddon("MyAddon"):IsClosed())
        assert.are.same({}, TestEnv.TakeReportedErrors())
    end)

    it("shuts down unchanged against a CommandKit without CloseAddonScopes", function()
        local life = LifecycleKit:ForAddon("MyAddon")
        local runs = 0
        CommandKit:ForAddon("MyAddon"):Register("mycmd", {
            handler = function()
                runs = runs + 1
            end,
        })
        local original = rawget(CommandKit, "CloseAddonScopes")
        rawset(CommandKit, "CloseAddonScopes", nil)

        TestEnv.Logout()

        rawset(CommandKit, "CloseAddonScopes", original)
        assert.is_true(life:IsShutdown())
        TestEnv.RunSlash("/mycmd")
        assert.are.equal(1, runs)
        assert.are.same({}, TestEnv.TakeReportedErrors())
    end)

    it("shuts down unchanged against a HookKit without CloseAddonScopes", function()
        local life = LifecycleKit:ForAddon("MyAddon")
        local hooks = HookKit:ForAddon("MyAddon")
        local original = rawget(HookKit, "CloseAddonScopes")
        rawset(HookKit, "CloseAddonScopes", nil)

        TestEnv.Logout()

        rawset(HookKit, "CloseAddonScopes", original)
        assert.is_true(life:IsShutdown())
        assert.is_false(hooks:IsClosed())
        assert.is_true(EventKit:ForAddon("MyAddon"):IsClosed())
        assert.are.same({}, TestEnv.TakeReportedErrors())
    end)

    it("reports the first failure in event, hook, command, comm, bus order", function()
        local first = LifecycleKit:ForAddon("FirstAddon")
        local second = LifecycleKit:ForAddon("SecondAddon")
        local attempted = {}
        local closeEvents = rawget(EventKit, "CloseAddonScopes")
        local closeHooks = rawget(HookKit, "CloseAddonScopes")
        local closeBus = rawget(SignalKit, "CloseAddonBus")
        local closeCommands = rawget(CommandKit, "CloseAddonScopes")
        rawset(CommandKit, "CloseAddonScopes", function(_, addonName)
            attempted[#attempted + 1] = "commands " .. addonName
            error("command teardown failed", 0)
        end)
        local closeComm = rawget(CommKit, "CloseAddonScopes")
        rawset(CommKit, "CloseAddonScopes", function(_, addonName)
            attempted[#attempted + 1] = "comm " .. addonName
            error("comm teardown failed", 0)
        end)
        rawset(EventKit, "CloseAddonScopes", function(_, addonName)
            attempted[#attempted + 1] = "events " .. addonName
            if addonName == "SecondAddon" then
                error("event teardown failed", 0)
            end
            return closeEvents(EventKit, addonName)
        end)
        rawset(HookKit, "CloseAddonScopes", function(_, addonName)
            attempted[#attempted + 1] = "hooks " .. addonName
            error("hook teardown failed", 0)
        end)
        rawset(SignalKit, "CloseAddonBus", function(_, addonName)
            attempted[#attempted + 1] = "bus " .. addonName
            error("bus teardown failed", 0)
        end)

        TestEnv.Logout()

        rawset(EventKit, "CloseAddonScopes", closeEvents)
        rawset(HookKit, "CloseAddonScopes", closeHooks)
        rawset(SignalKit, "CloseAddonBus", closeBus)
        rawset(CommandKit, "CloseAddonScopes", closeCommands)
        rawset(CommKit, "CloseAddonScopes", closeComm)
        -- Every step ran for every addon, even after earlier failures.
        assert.are.same({
            "events FirstAddon",
            "hooks FirstAddon",
            "commands FirstAddon",
            "comm FirstAddon",
            "bus FirstAddon",
            "events SecondAddon",
            "hooks SecondAddon",
            "commands SecondAddon",
            "comm SecondAddon",
            "bus SecondAddon",
        }, attempted)
        -- Addons advance by name; FirstAddon's first failure is its hook
        -- scope, which wins over SecondAddon's event-scope failure.
        local reported = TestEnv.TakeReportedErrors()
        assert.are.equal(1, #reported)
        assert.are.equal("hook teardown failed", reported[1].value)
        assert.is_true(first:IsShutdown())
        assert.is_true(second:IsShutdown())
    end)

    it("prefers a comm-scope failure over a bus failure of one addon", function()
        LifecycleKit:ForAddon("MyAddon")
        local closeComm = rawget(CommKit, "CloseAddonScopes")
        local closeBus = rawget(SignalKit, "CloseAddonBus")
        rawset(CommKit, "CloseAddonScopes", function()
            error("comm teardown failed", 0)
        end)
        rawset(SignalKit, "CloseAddonBus", function()
            error("bus teardown failed", 0)
        end)

        TestEnv.Logout()

        rawset(CommKit, "CloseAddonScopes", closeComm)
        rawset(SignalKit, "CloseAddonBus", closeBus)
        local reported = TestEnv.TakeReportedErrors()
        assert.are.equal(1, #reported)
        assert.are.equal("comm teardown failed", reported[1].value)
    end)

    it("prefers a command-scope failure over a bus failure of one addon", function()
        LifecycleKit:ForAddon("MyAddon")
        local closeCommands = rawget(CommandKit, "CloseAddonScopes")
        local closeBus = rawget(SignalKit, "CloseAddonBus")
        rawset(CommandKit, "CloseAddonScopes", function()
            error("command teardown failed", 0)
        end)
        rawset(SignalKit, "CloseAddonBus", function()
            error("bus teardown failed", 0)
        end)

        TestEnv.Logout()

        rawset(CommandKit, "CloseAddonScopes", closeCommands)
        rawset(SignalKit, "CloseAddonBus", closeBus)
        local reported = TestEnv.TakeReportedErrors()
        assert.are.equal(1, #reported)
        assert.are.equal("command teardown failed", reported[1].value)
    end)

    it("prefers an event-scope failure over the hook and bus failures of one addon", function()
        LifecycleKit:ForAddon("MyAddon")
        local closeEvents = rawget(EventKit, "CloseAddonScopes")
        local closeHooks = rawget(HookKit, "CloseAddonScopes")
        rawset(EventKit, "CloseAddonScopes", function()
            error("event teardown failed", 0)
        end)
        rawset(HookKit, "CloseAddonScopes", function()
            error("hook teardown failed", 0)
        end)
        local subscription = SignalKit:ForAddon("MyAddon"):Subscribe("Anything", function() end)

        TestEnv.Logout()

        rawset(EventKit, "CloseAddonScopes", closeEvents)
        rawset(HookKit, "CloseAddonScopes", closeHooks)
        local reported = TestEnv.TakeReportedErrors()
        assert.are.equal(1, #reported)
        assert.are.equal("event teardown failed", reported[1].value)
        -- The bus is still closed after both earlier steps failed.
        assert.is_false(subscription:IsConnected())
    end)
end)

describe("LifecycleKit shutdown without HookKit", function()
    after_each(TestEnv.Reset)

    it("closes the event scope and the bus when HookKit is not loaded", function()
        local LifecycleKit, _, SignalKit, EventKit = TestEnv.NewPackageWithoutHookKit()
        local life = LifecycleKit:ForAddon("MyAddon")
        local subscription = SignalKit:ForAddon("MyAddon"):Subscribe("Anything", function() end)

        TestEnv.Logout()

        assert.is_true(life:IsShutdown())
        assert.is_false(subscription:IsConnected())
        assert.is_true(EventKit:ForAddon("MyAddon"):IsClosed())
        assert.are.same({}, TestEnv.TakeReportedErrors())
    end)
end)

describe("LifecycleKit upgrade from an older schema-3 revision", function()
    after_each(TestEnv.Reset)

    -- Revisions 7 to 9 already wrote schema 3, but each one's logout watcher
    -- calls its own handler, which misses the scopes later revisions close.
    -- The upgrade must replace that watcher, or logout would keep running the
    -- older code.
    for oldRevision = 7, 9 do
        it(
            "replaces revision " .. oldRevision .. "'s host watchers so logout closes what it owns",
            function()
                TestEnv.Reset()
                TestEnv.InstallWowApi()
                local Registry = require("Registry")
                local SignalKit = require("SignalKit")
                local EventKit = require("EventKit")
                local HookKit = require("HookKit")

                local old = Registry:Register("lifecycleKit", 1, oldRevision)
                local noop = function() end
                old.API = 1
                old.REVISION = oldRevision
                old.Instance = {}
                old.Subscription = { Disconnect = noop, IsConnected = noop }
                old.DeferredCall = { Cancel = noop, IsPending = noop }
                old.ForAddon = noop
                old.IsInCombat = noop
                local instance = setmetatable({
                    _addonName = "CarriedOver",
                    _loaded = false,
                    _ready = false,
                    _shutdown = false,
                    _halted = false,
                    _dependencies = {},
                    _combatQueue = {},
                    _combatQueueLength = 0,
                    _combatPending = 0,
                    _combatQueueLimit = 64,
                    _draining = false,
                    _combatCaptures = {
                        combatStart = { active = false, failed = false },
                        combatEnd = { active = false, failed = false },
                    },
                    _signals = {
                        loaded = SignalKit:New(),
                        ready = SignalKit:New(),
                        shutdown = SignalKit:New(),
                        halted = SignalKit:New(),
                        dependencyHalted = SignalKit:New(),
                        combatStart = SignalKit:New(),
                        combatEnd = SignalKit:New(),
                    },
                    _phaseCaptures = {},
                }, { __index = old.Instance })

                local oldLogoutCalls = 0
                local oldLogoutWatcher = EventKit:Once("PLAYER_LOGOUT", function()
                    oldLogoutCalls = oldLogoutCalls + 1
                end)
                old._state = {
                    schema = 3,
                    addons = { CarriedOver = instance },
                    instances = { instance },
                    globalWatchers = { playerLogout = oldLogoutWatcher },
                    loginSeen = false,
                    shutdownSeen = false,
                    inCombat = false,
                }

                local upgraded = require("LifecycleKit")
                local hooks = HookKit:ForAddon("CarriedOver")
                local subscription = SignalKit:ForAddon("CarriedOver"):Subscribe("Anything", noop)

                assert.are.equal(old, upgraded)
                assert.are.equal(10, upgraded.REVISION)
                assert.is_false(oldLogoutWatcher:IsConnected())

                TestEnv.Logout()

                assert.are.equal(0, oldLogoutCalls)
                assert.are.equal("shutdown", instance:GetState())
                assert.is_true(hooks:IsClosed())
                assert.is_false(subscription:IsConnected())
            end
        )
    end
end)
