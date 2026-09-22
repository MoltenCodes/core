local TestEnv = require("SchedulerKitTestEnv")

describe("SchedulerKit scopes", function()
    after_each(TestEnv.Reset)


    it("allocates TimerKit scope only when delayed work is first used", function()
        local SchedulerKit, _, _, _, _, TimerKit = TestEnv.NewPackage()
        local originalCreateScope = TimerKit.CreateScope
        local createCalls = 0
        TimerKit.CreateScope = function(...)
            createCalls = createCalls + 1
            return originalCreateScope(...)
        end

        local scope = SchedulerKit:CreateScope()
        assert.are.equal(0, createCalls)

        scope:Schedule(function() end)
        TestEnv.Tick()
        assert.are.equal(0, createCalls)

        scope:After(1, function() end)
        assert.are.equal(1, createCalls)

        scope:After(2, function() end)
        assert.are.equal(1, createCalls)

        TimerKit.CreateScope = originalCreateScope
    end)

    it("tracks and cancels active jobs", function()
        local SchedulerKit = TestEnv.NewPackage()
        local scope = SchedulerKit:CreateScope()
        local pending = scope:Schedule(function() end)
        local delayed = scope:After(5, function() end)

        assert.are.equal(2, scope:GetActiveCount())
        scope:CancelAll()
        assert.are.equal(0, scope:GetActiveCount())
        assert.are.equal("cancelled", pending:GetState())
        assert.are.equal("cancelled", delayed:GetState())
        assert.is_false(scope:IsClosed())
    end)

    it("continues bulk cancellation after one native cancellation error", function()
        local SchedulerKit = TestEnv.NewPackage()
        local scope = SchedulerKit:CreateScope()
        local first = scope:After(5, function() end)
        local second = scope:After(5, function() end)
        TestEnv.FailNextTimerCancel("first cancel failed")

        local ok, value = pcall(function() scope:CancelAll() end)
        assert.is_false(ok)
        assert.are.equal("first cancel failed", value)
        assert.are.equal("cancelled", first:GetState())
        assert.are.equal("cancelled", second:GetState())
        assert.are.equal(0, scope:GetActiveCount())
    end)

    it("closes terminally", function()
        local SchedulerKit = TestEnv.NewPackage()
        local scope = SchedulerKit:CreateScope()
        scope:Schedule(function() end)

        assert.is_true(scope:Close())
        assert.is_true(scope:IsClosed())
        assert.is_false(scope:Close())
        assert.has_error(function() scope:Schedule(function() end) end)
    end)

    it("uses canonical addon scopes and closes them at shutdown", function()
        local SchedulerKit = TestEnv.NewPackage()
        TestEnv.MarkAddonLoaded("Example")
        TestEnv.Login()

        local first = SchedulerKit:ForAddon("Example")
        local second = SchedulerKit:ForAddon("Example")
        local job = first:Schedule(function() end)
        assert.are.equal(first, second)
        assert.are.equal("Example", first:GetAddonName())

        TestEnv.Logout()
        assert.is_true(first:IsClosed())
        assert.are.equal("cancelled", job:GetState())
    end)

    it("returns a closed scope if addon lifecycle is already shutdown", function()
        local SchedulerKit, _, _, _, LifecycleKit = TestEnv.NewPackage()
        TestEnv.MarkAddonLoaded("Late")
        TestEnv.Login()
        local lifecycle = LifecycleKit:ForAddon("Late")
        TestEnv.Logout()
        assert.is_true(lifecycle:IsShutdown())

        local scope = SchedulerKit:ForAddon("Late")
        assert.is_true(scope:IsClosed())
    end)
end)
