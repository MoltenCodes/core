local TestEnv = require("TimerKitTestEnv")

describe("TimerKit bootstrap", function()
    after_each(TestEnv.Reset)

    it("returns the same facade on duplicate embedded load", function()
        local TimerKit = TestEnv.NewPackage()
        local reloaded = TestEnv.ReloadPackage()
        assert.are.equal(TimerKit, reloaded)
    end)

    it("publishes through Registry", function()
        local TimerKit, Registry = TestEnv.NewPackage()
        local registered, revision = Registry:Get("timerKit", 1)
        assert.are.equal(TimerKit, registered)
        assert.are.equal(TimerKit.REVISION, revision)
    end)

    it("does not reinterpret private state owned by a newer compatible revision", function()
        local TimerKit, Registry = TestEnv.NewPackage()
        local shippedRevision = TimerKit.REVISION
        local upgraded, previous = Registry:Register("timerKit", 1, 99)
        assert.are.equal(TimerKit, upgraded)
        assert.are.equal(shippedRevision, previous)

        rawset(TimerKit, "REVISION", 99)
        rawset(TimerKit, "_state", { schema = 999 })
        package.loaded["TimerKit"] = nil

        local reloaded = require("TimerKit")
        assert.are.equal(TimerKit, reloaded)
        assert.are.equal(99, reloaded.REVISION)
    end)

    it("upgrades a revision-1 embedded copy in place", function()
        TestEnv.Reset()
        TestEnv.InstallWowApi()
        local Registry = require("Registry")

        local old = Registry:Register("timerKit", 1, 1)
        local timerPrototype = {}
        local scopePrototype = {}
        local timerMetatable = { __index = timerPrototype }
        local scopeMetatable = { __index = scopePrototype }
        rawset(old, "API", 1)
        rawset(old, "REVISION", 1)
        rawset(old, "Timer", timerPrototype)
        rawset(old, "Scope", scopePrototype)
        rawset(old, "_state", {
            schema = 1,
            addonScopes = {},
            defaultScope = false,
            dispatch = {},
            nextTimerId = 7,
            runtimeRevision = 1,
            timerMetatable = timerMetatable,
            scopeMetatable = scopeMetatable,
        })

        local legacyScope = setmetatable({
            _active = {},
            _activeCount = 0,
            _closed = false,
        }, scopeMetatable)
        local legacyTimer = setmetatable({
            _id = 1,
            _scope = legacyScope,
            _callback = function() end,
            _delay = 1,
            _repeating = false,
            _state = "idle",
            _generation = 0,
        }, timerMetatable)

        local upgraded = require("TimerKit")
        assert.are.equal(old, upgraded)
        assert.are.equal(6, upgraded.REVISION)
        assert.are.equal(timerPrototype, upgraded.Timer)

        -- A timer object created by revision 1 gains the revision-2 user-data
        -- seam without being replaced, because methods live on the shared
        -- prototype rather than on the object.
        assert.is_nil(legacyTimer:GetUserData())
        legacyTimer:SetUserData("owner state")
        assert.are.equal("owner state", legacyTimer:GetUserData())
        assert.is_true(legacyTimer:Start())
        assert.are.equal(1, legacyScope:GetActiveCount())
    end)

    it("upgrades a revision-5 copy and releases its shutdown subscriptions", function()
        TestEnv.Reset()
        TestEnv.InstallWowApi()
        local Registry = require("Registry")

        -- Revision 5 required LifecycleKit and subscribed each addon scope to
        -- its addon's shutdown. The stand-in subscriptions below record
        -- whether the upgrade disconnected them; the second one fails, which
        -- must not stop the upgrade.
        local disconnects = 0
        local healthySubscription = {
            Disconnect = function()
                disconnects = disconnects + 1
                return true
            end,
        }
        local failingSubscription = {
            Disconnect = function()
                error("lifecycle gone", 0)
            end,
        }

        local old = Registry:Register("timerKit", 1, 5)
        local timerPrototype = {}
        local scopePrototype = {}
        local timerMetatable = { __index = timerPrototype }
        local scopeMetatable = { __index = scopePrototype }
        rawset(old, "API", 1)
        rawset(old, "REVISION", 5)
        rawset(old, "Timer", timerPrototype)
        rawset(old, "Scope", scopePrototype)

        local carried = setmetatable({
            _addonName = "Carried",
            _active = {},
            _activeCount = 0,
            _closed = false,
            _shutdownSubscription = healthySubscription,
        }, scopeMetatable)
        local failing = setmetatable({
            _addonName = "Failing",
            _active = {},
            _activeCount = 0,
            _closed = false,
            _shutdownSubscription = failingSubscription,
        }, scopeMetatable)
        local defaultScope = setmetatable({
            _active = {},
            _activeCount = 0,
            _closed = false,
        }, scopeMetatable)
        local carriedTimer = setmetatable({
            _id = 3,
            _scope = carried,
            _callback = function() end,
            _delay = 1,
            _repeating = false,
            _state = "idle",
            _generation = 0,
            _deadline = false,
        }, timerMetatable)
        rawset(old, "_state", {
            schema = 1,
            addonScopes = { Carried = carried, Failing = failing },
            defaultScope = defaultScope,
            dispatch = {},
            nextTimerId = 3,
            runtimeRevision = 5,
            timerMetatable = timerMetatable,
            scopeMetatable = scopeMetatable,
        })

        local upgraded = require("TimerKit")

        assert.are.equal(old, upgraded)
        assert.are.equal(6, upgraded.REVISION)
        assert.are.equal(1, disconnects)
        assert.is_nil(rawget(carried, "_shutdownSubscription"))
        assert.is_nil(rawget(failing, "_shutdownSubscription"))

        -- The carried scope stays canonical and open, and its timers work.
        assert.are.equal(carried, upgraded:ForAddon("Carried"))
        assert.is_false(carried:IsClosed())
        assert.is_true(carriedTimer:Start())
        assert.are.equal(1, carried:GetActiveCount())

        -- The two-step replaces the subscription.
        assert.is_true(upgraded:CloseAddonScopes("Carried"))
        assert.is_true(carriedTimer:IsCancelled())
        assert.is_true(carried:IsClosed())
        assert.is_true(upgraded:CloseAddonScopes("Failing"))

        -- A revision-5 wrapper that could not be disconnected still resolves
        -- `closeScope` through dispatch; closing again is a no-op.
        assert.is_false(upgraded._state.dispatch.closeScope(carried))
    end)

    it("reports no remaining time for a timer an older revision started", function()
        local TimerKit = TestEnv.NewPackage()
        local timer = TimerKit:After(2, function() end)

        -- Revisions before 4 kept no deadline. A timer they started is still
        -- running after the upgrade, but TimerKit cannot know when it fires, so
        -- it says nothing rather than inventing an answer.
        rawset(timer, "_deadline", nil)
        assert.is_true(timer:IsPending())
        assert.is_nil(timer:GetRemaining())
        assert.is_nil(timer:GetDeadline())

        timer:Restart()
        assert.are.equal(2, timer:GetRemaining())
    end)

    it("learns the deadline of an older revision's ticker at its next tick", function()
        local TimerKit = TestEnv.NewPackage()
        local ticker = TimerKit:Every(1, function() end)
        rawset(ticker, "_deadline", nil)

        TestEnv.AdvanceMs(1000)
        TestEnv.FireNative(1)

        assert.are.equal(2, ticker:GetDeadline())
    end)

    it("loads without GetTimePreciseSec and reports no remaining time", function()
        TestEnv.Reset()
        TestEnv.InstallWowApi()
        require("Registry")
        -- The package reads this host global at load time, so the spec has to remove it from the global table.
        -- selene: allow(global_usage)
        rawset(_G, "GetTimePreciseSec", nil)

        local TimerKit = require("TimerKit")
        local fired = 0
        local timer = TimerKit:After(2, function()
            fired = fired + 1
        end)
        local ticker = TimerKit:Every(1, function() end)

        assert.is_true(timer:IsPending())
        assert.is_nil(timer:GetRemaining())
        assert.is_nil(timer:GetDeadline())
        TestEnv.FireNative(2)
        assert.is_nil(ticker:GetRemaining())
        TestEnv.FireNative(1)
        assert.are.equal(1, fired)
    end)

    it("loads with Registry alone", function()
        TestEnv.Reset()
        TestEnv.InstallWowApi()
        local Registry = require("Registry")

        local TimerKit = require("TimerKit")

        assert.is_nil(Registry:Find("lifecycleKit", 1))
        assert.are.equal(TimerKit, Registry:Find("timerKit", 1))
        local timer = TimerKit:ForAddon("Alone"):After(1, function() end)
        assert.is_true(timer:IsPending())
        assert.is_true(TimerKit:CloseAddonScopes("Alone"))
        assert.is_true(timer:IsCancelled())
    end)

    it("requires Registry API 2", function()
        TestEnv.Reset()
        TestEnv.InstallWowApi()
        local ok, value = pcall(require, "TimerKit")
        assert.is_false(ok)
        assert.is_true(tostring(value):find("Registry API 2", 1, true) ~= nil)
    end)

    it("requires C_Timer NewTimer and NewTicker", function()
        TestEnv.Reset()
        TestEnv.InstallWowApi()
        require("Registry")
        -- The package reads this host global at load time, so the spec has to install it in the global table.
        -- selene: allow(global_usage)
        rawset(_G, "C_Timer", {})

        local ok, value = pcall(require, "TimerKit")
        assert.is_false(ok)
        assert.is_true(tostring(value):find("C_Timer.NewTimer", 1, true) ~= nil)
    end)
end)
