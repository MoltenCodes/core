local TestEnv = require("HookKitTestEnv")

-- An addon scope closes at logout whenever the framework can observe logout,
-- whichever revisions are paired (docs/API.md, "At logout"). `ForAddon`
-- decides who closes it:
--
--   (a) a LifecycleKit whose `CLOSES_ADDON_SCOPES` names "hookKit" closes it
--       after the addon's shutdown callbacks;
--   (b) an older LifecycleKit: HookKit's own `OnShutdown` subscription does;
--   (c) no LifecycleKit, but EventKit: HookKit's `PLAYER_LOGOUT` watcher does;
--   (d) neither: the consumer calls `CloseAddonScopes` itself.
--
-- The LifecycleKit on `LUA_PATH` is made to announce the field, or not, with
-- `TestEnv.SetClosesAddonScopes`. An `OnShutdown` callback subscribed after
-- `ForAddon` tells (a) from (b): under (a) it still sees the scope open, under
-- (b) HookKit's earlier subscription has already closed it.

---Hook a fresh target in `scope` and return it.
---@param scope table
---@return table target
local function hookTarget(scope)
    local target = {
        Refresh = function() end,
    }
    assert.is_true((scope:Hook(target, "Refresh", function() end)))
    return target
end

---Subscribe to the addon's shutdown after HookKit did, and report whether the
---scope was still open when the callback ran.
---@param LifecycleKit table
---@param scope table
---@return table seen `seen.open` is `true` or `false` once shutdown ran
local function watchShutdown(LifecycleKit, scope)
    local seen = {}
    LifecycleKit:ForAddon("MyAddon"):OnShutdown(function()
        seen.open = not scope:IsClosed()
    end)
    return seen
end

describe("HookKit logout close", function()
    after_each(TestEnv.Reset)

    describe("(a) LifecycleKit names hookKit in CLOSES_ADDON_SCOPES", function()
        it("leaves the scope to LifecycleKit, open during the shutdown callbacks", function()
            local HookKit = TestEnv.NewPackage()
            local LifecycleKit = TestEnv.LoadLifecycleKit(true)
            local scope = HookKit:ForAddon("MyAddon")
            local target = hookTarget(scope)
            local seen = watchShutdown(LifecycleKit, scope)

            assert.is_false(rawget(scope, "_shutdownSubscription"))
            TestEnv.Logout()

            assert.is_true(seen.open)
            assert.is_true(scope:IsClosed())
            assert.is_false((scope:IsHooked(target, "Refresh")))
            assert.are.same({}, TestEnv.TakeReportedErrors())
        end)

        it("closes the scope of an addon without its own LifecycleKit instance", function()
            local HookKit = TestEnv.NewPackage()
            local LifecycleKit = TestEnv.LoadLifecycleKit(true)
            local scope = HookKit:ForAddon("MyAddon")

            TestEnv.Logout()

            assert.is_true(LifecycleKit:ForAddon("MyAddon"):IsShutdown())
            assert.is_true(scope:IsClosed())
        end)
    end)

    describe("(b) an older LifecycleKit", function()
        it("subscribes to the addon's OnShutdown and closes the scope there", function()
            local HookKit = TestEnv.NewPackage()
            local LifecycleKit = TestEnv.LoadLifecycleKit(false)
            local scope = HookKit:ForAddon("MyAddon")
            local target = hookTarget(scope)
            local subscription = rawget(scope, "_shutdownSubscription")
            local seen = watchShutdown(LifecycleKit, scope)

            assert.is_true(subscription:IsConnected())
            TestEnv.Logout()

            assert.is_false(seen.open)
            assert.is_true(scope:IsClosed())
            assert.is_false((scope:IsHooked(target, "Refresh")))
            assert.is_false(subscription:IsConnected())
            assert.are.same({}, TestEnv.TakeReportedErrors())
        end)

        it("treats a list that does not name hookKit as an older LifecycleKit", function()
            local HookKit = TestEnv.NewPackage()
            local LifecycleKit = TestEnv.LoadLifecycleKit({ timerKit = true })
            local scope = HookKit:ForAddon("MyAddon")
            local seen = watchShutdown(LifecycleKit, scope)

            TestEnv.Logout()

            assert.is_false(seen.open)
            assert.is_true(scope:IsClosed())
        end)

        it("subscribes once per addon however often ForAddon is called", function()
            local HookKit = TestEnv.NewPackage()
            TestEnv.LoadLifecycleKit(false)
            local scope = HookKit:ForAddon("MyAddon")
            local subscription = rawget(scope, "_shutdownSubscription")

            HookKit:ForAddon("MyAddon")
            HookKit:ForAddon("MyAddon")

            assert.are.equal(subscription, rawget(scope, "_shutdownSubscription"))
        end)

        it("disconnects the subscription when CloseAddonScopes closes the scope first", function()
            local HookKit = TestEnv.NewPackage()
            TestEnv.LoadLifecycleKit(false)
            local scope = HookKit:ForAddon("MyAddon")
            local subscription = rawget(scope, "_shutdownSubscription")

            assert.is_true(HookKit:CloseAddonScopes("MyAddon"))

            assert.is_false(subscription:IsConnected())
            assert.is_false(rawget(scope, "_shutdownSubscription"))
            TestEnv.Logout()
            assert.are.same({}, TestEnv.TakeReportedErrors())
        end)

        it("disconnects the subscription when the scope's own Close runs first", function()
            local HookKit = TestEnv.NewPackage()
            TestEnv.LoadLifecycleKit(false)
            local scope = HookKit:ForAddon("MyAddon")
            local subscription = rawget(scope, "_shutdownSubscription")

            assert.is_true(scope:Close())

            assert.is_false(subscription:IsConnected())
        end)
    end)

    describe("(c) EventKit without LifecycleKit", function()
        it("closes every addon scope on PLAYER_LOGOUT through one watcher", function()
            local HookKit = TestEnv.NewPackage()
            TestEnv.LoadEventKit()
            local first = HookKit:ForAddon("MyAddon")
            local second = HookKit:ForAddon("OtherAddon")
            local manual = HookKit:CreateScope()
            local target = hookTarget(first)
            hookTarget(manual)

            local watch = rawget(rawget(HookKit, "_state"), "logoutWatch")
            assert.are.equal(1, rawget(watch, "scope"):GetActiveCount())

            TestEnv.Logout()

            assert.is_true(first:IsClosed())
            assert.is_true(second:IsClosed())
            assert.is_false((first:IsHooked(target, "Refresh")))
            assert.is_false(manual:IsClosed())
            assert.are.equal(1, manual:GetActiveCount())
            assert.are.same({}, TestEnv.TakeReportedErrors())
        end)

        it("leaves an addon scope that is already closed alone", function()
            local HookKit = TestEnv.NewPackage()
            TestEnv.LoadEventKit()
            local scope = HookKit:ForAddon("MyAddon")
            assert.is_true(HookKit:CloseAddonScopes("MyAddon"))

            TestEnv.Logout()

            assert.is_true(scope:IsClosed())
            assert.are.same({}, TestEnv.TakeReportedErrors())
        end)
    end)

    describe("(d) neither LifecycleKit nor EventKit", function()
        it("arranges nothing, and the consumer's own CloseAddonScopes closes the scope", function()
            local HookKit, Registry = TestEnv.NewPackage()
            local scope = HookKit:ForAddon("MyAddon")
            hookTarget(scope)

            assert.is_nil(Registry:Find("eventKit", 1))
            assert.are.equal("none", rawget(scope, "_logoutCloser"))
            assert.is_false(rawget(rawget(rawget(HookKit, "_state"), "logoutWatch"), "connection"))
            TestEnv.Logout()
            assert.is_false(scope:IsClosed())

            assert.is_true(HookKit:CloseAddonScopes("MyAddon"))
            assert.are.equal(0, scope:GetActiveCount())
        end)
    end)

    describe("re-evaluation", function()
        it("hands the scope to a LifecycleKit that loads after the first ForAddon", function()
            local HookKit = TestEnv.NewPackage()
            local scope = HookKit:ForAddon("MyAddon")
            assert.are.equal("none", rawget(scope, "_logoutCloser"))

            local LifecycleKit = TestEnv.LoadLifecycleKit(false)
            assert.are.equal(scope, HookKit:ForAddon("MyAddon"))
            local seen = watchShutdown(LifecycleKit, scope)
            TestEnv.Logout()

            assert.is_false(seen.open)
            assert.is_true(scope:IsClosed())
        end)

        it(
            "moves a scope from the PLAYER_LOGOUT watcher to a LifecycleKit that loads later",
            function()
                local HookKit = TestEnv.NewPackage()
                TestEnv.LoadEventKit()
                local scope = HookKit:ForAddon("MyAddon")
                assert.are.equal("playerLogout", rawget(scope, "_logoutCloser"))

                local LifecycleKit = require("LifecycleKit")
                TestEnv.SetClosesAddonScopes(LifecycleKit, true)
                HookKit:ForAddon("MyAddon")
                local seen = watchShutdown(LifecycleKit, scope)
                TestEnv.Logout()

                -- The watcher connected first and runs first, but leaves the scope
                -- to LifecycleKit, whose shutdown callbacks still see it open.
                assert.is_true(seen.open)
                assert.is_true(scope:IsClosed())
                assert.are.same({}, TestEnv.TakeReportedErrors())
            end
        )

        it("reports a failure in another Kit and asks again on the next ForAddon", function()
            local HookKit = TestEnv.NewPackage()
            local LifecycleKit = TestEnv.LoadLifecycleKit(false)
            local forAddon = rawget(LifecycleKit, "ForAddon")
            rawset(LifecycleKit, "ForAddon", function()
                error("lifecycle failure", 0)
            end)

            local scope = HookKit:ForAddon("MyAddon")
            assert.are.same({ { value = "lifecycle failure" } }, TestEnv.TakeReportedErrors())
            assert.are.equal("none", rawget(scope, "_logoutCloser"))

            rawset(LifecycleKit, "ForAddon", forAddon)
            HookKit:ForAddon("MyAddon")
            assert.are.equal("onShutdown", rawget(scope, "_logoutCloser"))
        end)
    end)

    describe("upgrades", function()
        it("arranges the logout close of addon scopes a revision 1 layout carried", function()
            TestEnv.Reset()
            TestEnv.InstallWowApi()
            TestEnv.InstallHookApi()
            require("Registry")
            require("ClientKit")
            local HookKit = TestEnv.LoadRevision(1)
            local scope = HookKit:ForAddon("MyAddon")
            local target = hookTarget(scope)
            -- Strip what revision 1 never had: the scope's logout fields and
            -- the package-level watcher.
            rawset(scope, "_schema", 1)
            rawset(scope, "_logoutCloser", nil)
            rawset(scope, "_shutdownSubscription", nil)
            rawset(rawget(HookKit, "_state"), "logoutWatch", nil)

            local LifecycleKit = TestEnv.LoadLifecycleKit(false)
            -- The working file loads over the revision 1 layout.
            local upgraded = require("HookKit")
            assert.are.equal(HookKit, upgraded)
            assert.are.equal(2, rawget(scope, "_schema"))
            assert.are.equal("onShutdown", rawget(scope, "_logoutCloser"))

            local seen = watchShutdown(LifecycleKit, scope)
            TestEnv.Logout()
            assert.is_false(seen.open)
            assert.is_true(scope:IsClosed())
            assert.is_false((scope:IsHooked(target, "Refresh")))
        end)

        it(
            "keeps the PLAYER_LOGOUT watcher across an upgrade without connecting another",
            function()
                local HookKit = TestEnv.NewPackage()
                TestEnv.LoadEventKit()
                local scope = HookKit:ForAddon("MyAddon")
                local watch = rawget(rawget(HookKit, "_state"), "logoutWatch")
                local connection = rawget(watch, "connection")

                TestEnv.LoadRevision(HookKit.REVISION + 1)
                HookKit:ForAddon("MyAddon")
                HookKit:ForAddon("OtherAddon")

                assert.are.equal(connection, rawget(watch, "connection"))
                assert.are.equal(1, rawget(watch, "scope"):GetActiveCount())
                TestEnv.Logout()
                assert.is_true(scope:IsClosed())
                assert.is_true(HookKit:ForAddon("OtherAddon"):IsClosed())
                assert.are.same({}, TestEnv.TakeReportedErrors())
            end
        )

        it(
            "keeps the OnShutdown subscription across an upgrade without subscribing again",
            function()
                local HookKit = TestEnv.NewPackage()
                local LifecycleKit = TestEnv.LoadLifecycleKit(false)
                local scope = HookKit:ForAddon("MyAddon")
                local subscription = rawget(scope, "_shutdownSubscription")

                TestEnv.LoadRevision(HookKit.REVISION + 1)
                HookKit:ForAddon("MyAddon")

                assert.are.equal(subscription, rawget(scope, "_shutdownSubscription"))
                assert.is_true(subscription:IsConnected())
                local seen = watchShutdown(LifecycleKit, scope)
                TestEnv.Logout()
                assert.is_false(seen.open)
                assert.is_true(scope:IsClosed())
                assert.are.same({}, TestEnv.TakeReportedErrors())
            end
        )
    end)
end)
