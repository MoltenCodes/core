local TestEnv = require("TimerKitTestEnv")

-- TimerKit keeps one canonical scope per addon but does not observe addon
-- shutdown: whoever does closes the scope through `CloseAddonScopes`.
-- LifecycleKit makes that call at logout, and its own suite covers that
-- integration; here the call is made by hand, as an addon without LifecycleKit
-- makes it from its `PLAYER_LOGOUT` handler.
describe("TimerKit addon scopes", function()
    after_each(TestEnv.Reset)

    it("returns one scope per addon", function()
        local TimerKit = TestEnv.NewPackage()
        local first = TimerKit:ForAddon("Example")
        local second = TimerKit:ForAddon("Example")
        local other = TimerKit:ForAddon("Other")

        assert.are.equal(first, second)
        assert.are_not.equal(first, other)
        assert.are.equal("Example", first:GetAddonName())
    end)

    it("keeps an addon scope open until CloseAddonScopes is called", function()
        local TimerKit = TestEnv.NewPackage()
        local scope = TimerKit:ForAddon("Example")
        local timer = scope:Every(1, function() end)

        TestEnv.Logout()

        assert.is_false(scope:IsClosed())
        assert.is_true(timer:IsPending())
    end)

    it("closes the addon scope and cancels its timers through CloseAddonScopes", function()
        local TimerKit = TestEnv.NewPackage()
        local scope = TimerKit:ForAddon("Example")
        local ticker = scope:Every(1, function() end)
        local oneShot = scope:After(5, function() end)

        assert.is_true(TimerKit:CloseAddonScopes("Example"))

        assert.is_true(scope:IsClosed())
        assert.is_true(ticker:IsCancelled())
        assert.is_true(oneShot:IsCancelled())
        assert.are.equal(0, scope:GetActiveCount())
        assert.is_true(TestEnv.NativeTimers()[1].cancelled)
        assert.is_true(TestEnv.NativeTimers()[2].cancelled)
    end)

    it("keeps the closed scope canonical and terminal", function()
        local TimerKit = TestEnv.NewPackage()
        local scope = TimerKit:ForAddon("Example")
        TimerKit:CloseAddonScopes("Example")

        assert.are.equal(scope, TimerKit:ForAddon("Example"))
        assert.is_false(TimerKit:CloseAddonScopes("Example"))
        assert.has_error(function()
            scope:After(1, function() end)
        end)
    end)

    it("returns false and records nothing for an addon that never had a scope", function()
        local TimerKit = TestEnv.NewPackage()

        assert.is_false(TimerKit:CloseAddonScopes("Unknown"))

        -- Nothing was recorded: asking now creates an open scope.
        local scope = TimerKit:ForAddon("Unknown")
        assert.is_false(scope:IsClosed())
        assert.is_not_nil(scope:After(1, function() end))
    end)

    it("lets a timer callback close its own addon scope", function()
        local TimerKit = TestEnv.NewPackage()
        local scope = TimerKit:ForAddon("Example")
        local ticks = 0
        local ticker = scope:Every(1, function()
            ticks = ticks + 1
            TimerKit:CloseAddonScopes("Example")
        end)
        local other = scope:After(5, function() end)

        TestEnv.FireNative(1)
        TestEnv.FireNative(1)

        assert.are.equal(1, ticks)
        assert.is_true(scope:IsClosed())
        assert.is_true(ticker:IsCancelled())
        assert.is_true(other:IsCancelled())
    end)

    it("re-raises the first native cancellation failure after cancelling every timer", function()
        local TimerKit = TestEnv.NewPackage()
        local scope = TimerKit:ForAddon("Example")
        local first = scope:After(1, function() end)
        local second = scope:After(2, function() end)
        TestEnv.FailNextCancel("cancel failed")

        local ok, value = pcall(TimerKit.CloseAddonScopes, TimerKit, "Example")

        assert.is_false(ok)
        assert.are.equal("cancel failed", value)
        assert.is_true(scope:IsClosed())
        assert.is_true(first:IsCancelled())
        assert.is_true(second:IsCancelled())
        assert.are.equal(0, scope:GetActiveCount())
    end)

    it("must be called on the TimerKit facade", function()
        local TimerKit = TestEnv.NewPackage()
        TimerKit:ForAddon("Example")

        TestEnv.expectErrorContaining("must be called on the TimerKit facade", function()
            TimerKit.CloseAddonScopes({}, "Example")
        end)
        TestEnv.expectErrorContaining("must be called on the TimerKit facade", function()
            TimerKit.CloseAddonScopes("Example")
        end)
        assert.is_false(TimerKit:ForAddon("Example"):IsClosed())
    end)

    it("keeps manual scopes independent from addon scope closure", function()
        local TimerKit = TestEnv.NewPackage()
        local manual = TimerKit:CreateScope()
        local timer = manual:Every(1, function() end)
        TimerKit:ForAddon("Example")

        TimerKit:CloseAddonScopes("Example")

        assert.is_false(manual:IsClosed())
        assert.is_true(timer:IsPending())
    end)

    it("isolates addon-owned scopes", function()
        local TimerKit = TestEnv.NewPackage()
        local first = TimerKit:ForAddon("First")
        local second = TimerKit:ForAddon("Second")
        first:After(1, function() end)
        local secondTimer = second:After(1, function() end)

        TimerKit:CloseAddonScopes("First")
        assert.is_true(first:IsClosed())
        assert.is_false(second:IsClosed())
        assert.is_true(secondTimer:IsPending())

        first = TimerKit:ForAddon("First")
        assert.is_true(first:IsClosed())
    end)
end)
