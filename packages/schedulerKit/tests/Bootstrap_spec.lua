local TestEnv = require("SchedulerKitTestEnv")

describe("SchedulerKit bootstrap", function()
    after_each(TestEnv.Reset)

    it("returns the same facade on duplicate embedded load", function()
        local SchedulerKit = TestEnv.NewPackage()
        local reloaded = TestEnv.ReloadPackage()
        assert.are.equal(SchedulerKit, reloaded)
    end)

    it("preserves live job identity across compatible reload", function()
        local SchedulerKit = TestEnv.NewPackage()
        SchedulerKit:SetMaxResumesPerFrame(1)
        local steps = 0
        local job = SchedulerKit:Schedule(function(context)
            steps = steps + 1
            context:Yield()
            steps = steps + 1
        end)
        TestEnv.Tick()
        assert.are.equal(1, steps)

        local reloaded = TestEnv.ReloadPackage()
        assert.are.equal(SchedulerKit, reloaded)
        TestEnv.Tick()
        assert.are.equal(2, steps)
        assert.are.equal("completed", job:GetState())
    end)

    it("keeps the default TimerKit scope lazy during package bootstrap", function()
        TestEnv.Reset()
        TestEnv.InstallWowApi()
        require("Registry")
        require("SignalKit")
        require("EventKit")
        require("LifecycleKit")
        local TimerKit = require("TimerKit")

        local originalCreateScope = TimerKit.CreateScope
        TimerKit.CreateScope = function()
            error("scope creation unavailable", 0)
        end

        package.loaded["SchedulerKit"] = nil
        local ok, SchedulerKit = pcall(function()
            return require("SchedulerKit")
        end)
        assert.is_true(ok)
        assert.are.equal(6, SchedulerKit.REVISION)

        local scope = SchedulerKit:CreateScope()
        assert.is_false(scope:IsClosed())
        local delayedOk = pcall(function()
            scope:After(1, function() end)
        end)
        assert.is_false(delayedOk)
        assert.are.equal(0, scope:GetActiveCount())

        TimerKit.CreateScope = originalCreateScope
        local delayed = scope:After(1, function() end)
        assert.are.equal("delayed", delayed:GetState())
    end)

    it("adopts queues left behind by a revision-3 embedded copy", function()
        TestEnv.Reset()
        TestEnv.InstallWowApi()
        local Registry = require("Registry")
        require("SignalKit")
        require("EventKit")
        require("LifecycleKit")
        require("TimerKit")

        local old = Registry:Register("schedulerKit", 1, 3)
        local jobPrototype = {}
        local scopePrototype = {}
        local contextPrototype = {}
        local jobMetatable = { __index = jobPrototype }
        local scopeMetatable = { __index = scopePrototype }
        local contextMetatable = { __index = contextPrototype }
        local lowQueue = { items = {}, head = 1, tail = 0 }
        rawset(old, "API", 1)
        rawset(old, "REVISION", 3)
        rawset(old, "Job", jobPrototype)
        rawset(old, "Scope", scopePrototype)
        rawset(old, "Context", contextPrototype)
        rawset(old, "Priority", { HIGH = 1, NORMAL = 2, LOW = 3, IDLE = 4 })
        rawset(old, "_state", {
            schema = 1,
            addonScopes = {},
            defaultScope = false,
            dispatch = {},
            queues = {
                { items = {}, head = 1, tail = 0 },
                { items = {}, head = 1, tail = 0 },
                lowQueue,
                { items = {}, head = 1, tail = 0 },
            },
            config = {
                frameBudgetMs = 2,
                runawayThresholdMs = 8,
                maxResumesPerFrame = 1000,
            },
            jobMetatable = jobMetatable,
            scopeMetatable = scopeMetatable,
            contextMetatable = contextMetatable,
            yieldToken = {},
            priorityCursor = 1,
            activeCount = 1,
            frame = false,
            driverEnabled = false,
            driverTrampoline = false,
            currentJob = false,
            frameDeadline = false,
        })

        local legacyScope = setmetatable({
            _addonName = nil,
            _closed = false,
            _activeCount = 1,
            _head = false,
            _tail = false,
            _timerScope = false,
            _shutdownSubscription = false,
        }, scopeMetatable)
        local ran = false
        local legacyJob = setmetatable({
            _scope = legacyScope,
            _callback = function()
                ran = true
            end,
            _priority = 3,
            _name = nil,
            _interval = false,
            _state = "pending",
            _errorPresent = false,
            _generation = 1,
            _queued = true,
            _coroutine = false,
            _context = false,
            _delayTimer = false,
            _active = true,
            _scopePrev = false,
            _scopeNext = false,
        }, jobMetatable)
        rawset(legacyJob, "_context", setmetatable({ _job = legacyJob }, contextMetatable))
        rawset(legacyScope, "_head", legacyJob)
        rawset(legacyScope, "_tail", legacyJob)
        lowQueue.items[1] = legacyJob
        lowQueue.tail = 1

        local upgraded = require("SchedulerKit")
        assert.are.equal(old, upgraded)
        assert.are.equal(6, upgraded.REVISION)

        -- Revision 4's lane bookkeeping is derived from the inherited queues
        -- rather than assumed empty, so work an older copy had already queued
        -- still runs.
        local state = rawget(upgraded, "_state")
        assert.are.equal(1, rawget(state, "occupiedLaneCount"))
        assert.are.equal(0, rawget(state, "idleGuard"))

        legacyScope:Schedule(function() end)
        TestEnv.Tick()
        assert.is_true(ran)
        assert.are.equal("completed", legacyJob:GetState())
    end)

    it("releases terminal execution-only references", function()
        local SchedulerKit = TestEnv.NewPackage()
        local job = SchedulerKit:Schedule(function() end)
        TestEnv.Tick()

        assert.are.equal("completed", job:GetState())
        assert.is_false(rawget(job, "_callback"))
        assert.is_false(rawget(job, "_context"))
        assert.is_false(rawget(job, "_coroutine"))
    end)
end)
