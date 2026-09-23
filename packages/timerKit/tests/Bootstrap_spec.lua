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
        require("SignalKit")
        require("EventKit")
        require("LifecycleKit")

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
        assert.are.equal(4, upgraded.REVISION)
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

    it("requires GetTimePreciseSec", function()
        TestEnv.Reset()
        TestEnv.InstallWowApi()
        require("Registry")
        require("SignalKit")
        require("EventKit")
        require("LifecycleKit")
        -- The package reads this host global at load time, so the spec has to remove it from the global table.
        -- selene: allow(global_usage)
        rawset(_G, "GetTimePreciseSec", nil)

        local ok, value = pcall(require, "TimerKit")
        assert.is_false(ok)
        assert.is_true(tostring(value):find("GetTimePreciseSec", 1, true) ~= nil)
    end)

    it("requires LifecycleKit", function()
        TestEnv.Reset()
        TestEnv.InstallWowApi()
        require("Registry")
        local ok, value = pcall(require, "TimerKit")
        assert.is_false(ok)
        assert.is_true(tostring(value):find("LifecycleKit API 1", 1, true) ~= nil)
    end)

    it("requires C_Timer NewTimer and NewTicker", function()
        TestEnv.Reset()
        TestEnv.InstallWowApi()
        require("Registry")
        require("SignalKit")
        require("EventKit")
        require("LifecycleKit")
        -- The package reads this host global at load time, so the spec has to install it in the global table.
        -- selene: allow(global_usage)
        rawset(_G, "C_Timer", {})

        local ok, value = pcall(require, "TimerKit")
        assert.is_false(ok)
        assert.is_true(tostring(value):find("C_Timer.NewTimer", 1, true) ~= nil)
    end)
end)
