local TestEnv = require("SignalKitTestEnv")

-- An addon's bus closes at logout whenever the framework can observe logout,
-- whichever revisions are paired (docs/API.md, "At logout"). `ForAddon`
-- decides who closes it:
--
--   (a) a LifecycleKit whose `CLOSES_ADDON_SCOPES` names "signalKit" closes it
--       after the addon's shutdown callbacks;
--   (b) an older LifecycleKit: SignalKit's own `OnShutdown` subscription does;
--   (c) no LifecycleKit, but EventKit: SignalKit's `PLAYER_LOGOUT` watcher does;
--   (d) neither: the consumer calls `CloseAddonBus` itself.
--
-- The LifecycleKit on `LUA_PATH` is made to announce the field, or not, with
-- `TestEnv.SetClosesAddonScopes`. An `OnShutdown` callback subscribed after
-- `ForAddon` tells (a) from (b): under (a) it still sees the bus open, under
-- (b) SignalKit's earlier subscription has already closed it.

---Subscribe to a topic of `bus` and return the connection.
---@param bus table
---@return table connection
local function subscribe(bus)
    return assert(bus:Subscribe("Changed", function() end))
end

---Whether `bus` is closed. A bus has no `IsClosed`; its closed flag is read.
---@param bus table
---@return boolean
local function isClosed(bus)
    return rawget(bus, "_closed") == true
end

---Subscribe to the addon's shutdown after SignalKit did, and report whether
---the bus was still open when the callback ran.
---@param LifecycleKit table
---@param bus table
---@return table seen `seen.open` is `true` or `false` once shutdown ran
local function watchShutdown(LifecycleKit, bus)
    local seen = {}
    LifecycleKit:ForAddon("MyAddon"):OnShutdown(function()
        seen.open = not isClosed(bus)
    end)
    return seen
end

describe("SignalKit logout close", function()
    after_each(TestEnv.Reset)

    describe("(a) LifecycleKit names signalKit in CLOSES_ADDON_SCOPES", function()
        it("leaves the bus to LifecycleKit, open during the shutdown callbacks", function()
            local SignalKit = TestEnv.NewPackage()
            local LifecycleKit = TestEnv.LoadLifecycleKit(true)
            local bus = SignalKit:ForAddon("MyAddon")
            local connection = subscribe(bus)
            local seen = watchShutdown(LifecycleKit, bus)

            assert.is_false(rawget(bus, "_shutdownSubscription"))
            TestEnv.Logout()

            assert.is_true(seen.open)
            assert.is_true(isClosed(bus))
            assert.is_false(connection:IsConnected())
            assert.are.same({}, TestEnv.TakeReportedErrors())
        end)

        it("closes the bus of an addon without its own LifecycleKit instance", function()
            local SignalKit = TestEnv.NewPackage()
            local LifecycleKit = TestEnv.LoadLifecycleKit(true)
            local bus = SignalKit:ForAddon("MyAddon")

            TestEnv.Logout()

            assert.is_true(LifecycleKit:ForAddon("MyAddon"):IsShutdown())
            assert.is_true(isClosed(bus))
        end)
    end)

    describe("(b) an older LifecycleKit", function()
        it("subscribes to the addon's OnShutdown and closes the bus there", function()
            local SignalKit = TestEnv.NewPackage()
            local LifecycleKit = TestEnv.LoadLifecycleKit(false)
            local bus = SignalKit:ForAddon("MyAddon")
            local connection = subscribe(bus)
            local subscription = rawget(bus, "_shutdownSubscription")
            local seen = watchShutdown(LifecycleKit, bus)

            assert.is_true(subscription:IsConnected())
            TestEnv.Logout()

            assert.is_false(seen.open)
            assert.is_true(isClosed(bus))
            assert.is_false(connection:IsConnected())
            assert.is_false(subscription:IsConnected())
            assert.are.same({}, TestEnv.TakeReportedErrors())
        end)

        it("treats a list that does not name signalKit as an older LifecycleKit", function()
            local SignalKit = TestEnv.NewPackage()
            local LifecycleKit = TestEnv.LoadLifecycleKit({ timerKit = true })
            local bus = SignalKit:ForAddon("MyAddon")
            local seen = watchShutdown(LifecycleKit, bus)

            TestEnv.Logout()

            assert.is_false(seen.open)
            assert.is_true(isClosed(bus))
        end)

        it("subscribes once per addon however often ForAddon is called", function()
            local SignalKit = TestEnv.NewPackage()
            TestEnv.LoadLifecycleKit(false)
            local bus = SignalKit:ForAddon("MyAddon")
            local subscription = rawget(bus, "_shutdownSubscription")

            SignalKit:ForAddon("MyAddon")
            SignalKit:ForAddon("MyAddon")

            assert.are.equal(subscription, rawget(bus, "_shutdownSubscription"))
        end)

        it("disconnects the subscription when CloseAddonBus closes the bus first", function()
            local SignalKit = TestEnv.NewPackage()
            TestEnv.LoadLifecycleKit(false)
            local bus = SignalKit:ForAddon("MyAddon")
            local subscription = rawget(bus, "_shutdownSubscription")

            assert.is_true(SignalKit:CloseAddonBus("MyAddon"))

            assert.is_false(subscription:IsConnected())
            assert.is_false(rawget(bus, "_shutdownSubscription"))
            TestEnv.Logout()
            assert.are.same({}, TestEnv.TakeReportedErrors())
        end)
    end)

    describe("(c) EventKit without LifecycleKit", function()
        it("closes every addon bus, and no other, through one watcher", function()
            local SignalKit = TestEnv.NewPackage()
            TestEnv.LoadEventKit()
            local first = SignalKit:ForAddon("MyAddon")
            local second = SignalKit:ForAddon("OtherAddon")
            local shared = SignalKit:Bus("SharedBus")
            local connection = subscribe(first)
            local sharedConnection = subscribe(shared)

            local watch = rawget(rawget(SignalKit, "_state"), "logoutWatch")
            assert.are.equal(1, rawget(watch, "scope"):GetActiveCount())

            TestEnv.Logout()

            assert.is_true(isClosed(first))
            assert.is_true(isClosed(second))
            assert.is_false(connection:IsConnected())
            assert.is_false(isClosed(shared))
            assert.is_true(sharedConnection:IsConnected())
            assert.are.same({}, TestEnv.TakeReportedErrors())
        end)

        it("takes a bus first obtained through Bus once ForAddon names it", function()
            local SignalKit = TestEnv.NewPackage()
            TestEnv.LoadEventKit()
            local bus = SignalKit:Bus("MyAddon")
            assert.is_false(rawget(bus, "_logoutCloser"))

            assert.are.equal(bus, SignalKit:ForAddon("MyAddon"))
            TestEnv.Logout()

            assert.is_true(isClosed(bus))
        end)
    end)

    describe("(d) neither LifecycleKit nor EventKit", function()
        it("arranges nothing, and the consumer's own CloseAddonBus closes the bus", function()
            local SignalKit, Registry = TestEnv.NewPackage()
            local bus = SignalKit:ForAddon("MyAddon")
            local connection = subscribe(bus)

            assert.is_nil(Registry:Find("eventKit", 1))
            assert.are.equal("none", rawget(bus, "_logoutCloser"))
            assert.is_false(
                rawget(rawget(rawget(SignalKit, "_state"), "logoutWatch"), "connection")
            )

            assert.is_true(SignalKit:CloseAddonBus("MyAddon"))
            assert.is_false(connection:IsConnected())
        end)
    end)

    describe("re-evaluation", function()
        it("hands the bus to a LifecycleKit that loads after the first ForAddon", function()
            local SignalKit = TestEnv.NewPackage()
            local bus = SignalKit:ForAddon("MyAddon")
            assert.are.equal("none", rawget(bus, "_logoutCloser"))

            local LifecycleKit = TestEnv.LoadLifecycleKit(false)
            assert.are.equal(bus, SignalKit:ForAddon("MyAddon"))
            local seen = watchShutdown(LifecycleKit, bus)
            TestEnv.Logout()

            assert.is_false(seen.open)
            assert.is_true(isClosed(bus))
        end)

        it(
            "moves a bus from the PLAYER_LOGOUT watcher to a LifecycleKit that loads later",
            function()
                local SignalKit = TestEnv.NewPackage()
                TestEnv.LoadEventKit()
                local bus = SignalKit:ForAddon("MyAddon")
                assert.are.equal("playerLogout", rawget(bus, "_logoutCloser"))

                local LifecycleKit = require("LifecycleKit")
                TestEnv.SetClosesAddonScopes(LifecycleKit, true)
                SignalKit:ForAddon("MyAddon")
                local seen = watchShutdown(LifecycleKit, bus)
                TestEnv.Logout()

                -- The watcher connected first and runs first, but leaves the bus
                -- to LifecycleKit, whose shutdown callbacks still see it open.
                assert.is_true(seen.open)
                assert.is_true(isClosed(bus))
                assert.are.same({}, TestEnv.TakeReportedErrors())
            end
        )

        it("reports a failure in another Kit and asks again on the next ForAddon", function()
            local SignalKit = TestEnv.NewPackage()
            local LifecycleKit = TestEnv.LoadLifecycleKit(false)
            local forAddon = rawget(LifecycleKit, "ForAddon")
            rawset(LifecycleKit, "ForAddon", function()
                error("lifecycle failure", 0)
            end)

            local bus = SignalKit:ForAddon("MyAddon")
            assert.are.same({ { value = "lifecycle failure" } }, TestEnv.TakeReportedErrors())
            assert.are.equal("none", rawget(bus, "_logoutCloser"))

            rawset(LifecycleKit, "ForAddon", forAddon)
            SignalKit:ForAddon("MyAddon")
            assert.are.equal("onShutdown", rawget(bus, "_logoutCloser"))
        end)
    end)

    describe("upgrades", function()
        it("upgrades revision-5 state and takes a bus over at its next ForAddon", function()
            TestEnv.Reset()
            require("Registry")
            local SignalKit = TestEnv.LoadRevision(5)
            local bus = SignalKit:ForAddon("MyAddon")
            local connection = subscribe(bus)
            -- Reduce the state and the bus to the shape revision 5 left behind.
            local state = rawget(SignalKit, "_state")
            rawset(state, "schema", 2)
            rawset(state, "logoutWatch", nil)
            rawset(bus, "_logoutCloser", nil)
            rawset(bus, "_shutdownSubscription", nil)

            local LifecycleKit = TestEnv.LoadLifecycleKit(false)
            local upgraded = TestEnv.ReloadPackage()

            assert.are.equal(SignalKit, upgraded)
            assert.are.equal(4, rawget(state, "schema"))
            -- Revision 5 did not record which buses are addon buses.
            assert.is_false(rawget(bus, "_logoutCloser"))
            assert.are.equal(bus, upgraded:ForAddon("MyAddon"))
            assert.are.equal("onShutdown", rawget(bus, "_logoutCloser"))

            local seen = watchShutdown(LifecycleKit, bus)
            TestEnv.Logout()
            assert.is_false(seen.open)
            assert.is_true(isClosed(bus))
            assert.is_false(connection:IsConnected())
        end)

        it("arranges an inherited undecided addon bus at the upgrade itself", function()
            local SignalKit = TestEnv.NewPackage()
            local bus = SignalKit:ForAddon("MyAddon")
            assert.are.equal("none", rawget(bus, "_logoutCloser"))

            TestEnv.LoadLifecycleKit(false)
            TestEnv.LoadRevision(SignalKit.REVISION + 1)

            assert.are.equal("onShutdown", rawget(bus, "_logoutCloser"))
            TestEnv.Logout()
            assert.is_true(isClosed(bus))
        end)

        it(
            "keeps the PLAYER_LOGOUT watcher across an upgrade without connecting another",
            function()
                local SignalKit = TestEnv.NewPackage()
                TestEnv.LoadEventKit()
                local bus = SignalKit:ForAddon("MyAddon")
                local watch = rawget(rawget(SignalKit, "_state"), "logoutWatch")
                local connection = rawget(watch, "connection")

                TestEnv.LoadRevision(SignalKit.REVISION + 1)
                SignalKit:ForAddon("MyAddon")
                local other = SignalKit:ForAddon("OtherAddon")

                assert.are.equal(connection, rawget(watch, "connection"))
                assert.are.equal(1, rawget(watch, "scope"):GetActiveCount())
                TestEnv.Logout()
                assert.is_true(isClosed(bus))
                assert.is_true(isClosed(other))
                assert.are.same({}, TestEnv.TakeReportedErrors())
            end
        )

        it(
            "keeps the OnShutdown subscription across an upgrade without subscribing again",
            function()
                local SignalKit = TestEnv.NewPackage()
                local LifecycleKit = TestEnv.LoadLifecycleKit(false)
                local bus = SignalKit:ForAddon("MyAddon")
                local subscription = rawget(bus, "_shutdownSubscription")

                TestEnv.LoadRevision(SignalKit.REVISION + 1)
                SignalKit:ForAddon("MyAddon")

                assert.are.equal(subscription, rawget(bus, "_shutdownSubscription"))
                assert.is_true(subscription:IsConnected())
                local seen = watchShutdown(LifecycleKit, bus)
                TestEnv.Logout()
                assert.is_false(seen.open)
                assert.is_true(isClosed(bus))
                assert.are.same({}, TestEnv.TakeReportedErrors())
            end
        )
    end)
end)
