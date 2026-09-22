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
        assert.are.equal(3, SchedulerKit.REVISION)

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
