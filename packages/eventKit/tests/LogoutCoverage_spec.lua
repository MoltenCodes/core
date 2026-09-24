local TestEnv = require("EventKitTestEnv")

-- An addon scope closes at logout whatever LifecycleKit revision is paired
-- with EventKit. The first `ForAddon` decides who makes the `CloseAddonScopes`
-- call (docs/API.md, "At logout"):
--
--   a. a LifecycleKit that lists "eventKit" in CLOSES_ADDON_SCOPES;
--   b. an older LifecycleKit, through an OnShutdown subscription;
--   c. without LifecycleKit, EventKit's own PLAYER_LOGOUT one-shot;
--   d. only when the host refuses that registration, the addon itself.
--
-- Every route closes inside the PLAYER_LOGOUT dispatch, so the scope's own
-- PLAYER_LOGOUT listeners still run.

---The package-private state of `EventKit`, for assertions.
---@param EventKit table
---@return table state
local function privateState(EventKit)
    return rawget(EventKit, "_state")
end

---Remove LifecycleKit's capability field, turning the real LifecycleKit into
---one that, like every revision before 13, does not say what it closes.
---@param LifecycleKit table
local function withoutCapability(LifecycleKit)
    rawset(LifecycleKit, "CLOSES_ADDON_SCOPES", nil)
end

---Log out with `EventKit:CloseAddonScopes` hidden, as a LifecycleKit that does
---not know the call sees it, so only EventKit's own route can close.
---@param EventKit table
local function logoutWithoutLifecycleCall(EventKit)
    local closeAddonScopes = rawget(EventKit, "CloseAddonScopes")
    rawset(EventKit, "CloseAddonScopes", nil)
    local ok, failure = pcall(TestEnv.Logout)
    rawset(EventKit, "CloseAddonScopes", closeAddonScopes)
    assert(ok, failure)
end

---Connect a scoped `PLAYER_LOGOUT` listener that counts its calls.
---@param scope table
---@return table calls `{ count = n }`
local function countLogouts(scope)
    local calls = { count = 0 }
    scope:Connect("PLAYER_LOGOUT", function()
        calls.count = calls.count + 1
    end)
    return calls
end

describe("EventKit at logout with a LifecycleKit that closes event scopes", function()
    after_each(TestEnv.Reset)

    it("connects nothing of its own and is closed by LifecycleKit", function()
        local EventKit = TestEnv.NewPackage()
        local LifecycleKit = TestEnv.LoadLifecycleKit()
        LifecycleKit:ForAddon("MyAddon")
        local events = EventKit:ForAddon("MyAddon")
        local logouts = countLogouts(events)

        assert.are.equal("lifecycleKit", rawget(events, "_logoutRoute"))
        assert.is_false(rawget(events, "_logoutSubscription"))
        assert.is_false(privateState(EventKit).logoutConnection)

        TestEnv.Logout()

        assert.are.equal(1, logouts.count)
        assert.is_true(events:IsClosed())
        assert.are.equal(0, events:GetActiveCount())
    end)
    it("closes the scope of an addon that never called LifecycleKit:ForAddon", function()
        local EventKit = TestEnv.NewPackage()
        TestEnv.LoadLifecycleKit()
        local events = EventKit:ForAddon("NeverAsked")
        local logouts = countLogouts(events)

        TestEnv.Logout()

        assert.are.equal(1, logouts.count)
        assert.is_true(events:IsClosed())
        assert.are.equal(0, events:GetActiveCount())
    end)
end)

describe("EventKit at logout with a LifecycleKit without the capability", function()
    after_each(TestEnv.Reset)

    it("closes the scope from an OnShutdown subscription after the dispatch", function()
        local EventKit = TestEnv.NewPackage()
        local LifecycleKit = TestEnv.LoadLifecycleKit()
        withoutCapability(LifecycleKit)
        local events = EventKit:ForAddon("MyAddon")
        local logouts = countLogouts(events)
        local subscription = rawget(events, "_logoutSubscription")

        assert.are.equal("onShutdown", rawget(events, "_logoutRoute"))
        assert.is_true(subscription:IsConnected())
        assert.is_false(privateState(EventKit).logoutConnection)

        logoutWithoutLifecycleCall(EventKit)

        assert.are.equal(1, logouts.count)
        assert.is_true(events:IsClosed())
        assert.are.equal(0, events:GetActiveCount())
        assert.is_false(rawget(events, "_logoutSubscription"))
    end)

    it("disconnects the subscription when CloseAddonScopes closes the scope", function()
        local EventKit = TestEnv.NewPackage()
        local LifecycleKit = TestEnv.LoadLifecycleKit()
        withoutCapability(LifecycleKit)
        local events = EventKit:ForAddon("MyAddon")
        local subscription = rawget(events, "_logoutSubscription")

        assert.is_true(EventKit:CloseAddonScopes("MyAddon"))

        assert.is_false(subscription:IsConnected())
        assert.is_false(rawget(events, "_logoutSubscription"))
    end)

    it("steps aside when a LifecycleKit that closes event scopes replaced it", function()
        local EventKit = TestEnv.NewPackage()
        local LifecycleKit = TestEnv.LoadLifecycleKit()
        local capabilities = rawget(LifecycleKit, "CLOSES_ADDON_SCOPES")
        withoutCapability(LifecycleKit)
        local events = EventKit:ForAddon("MyAddon")
        local closedDuringShutdown
        LifecycleKit:ForAddon("MyAddon"):OnShutdown(function()
            closedDuringShutdown = events:IsClosed()
        end)

        rawset(LifecycleKit, "CLOSES_ADDON_SCOPES", capabilities)
        TestEnv.Logout()

        assert.is_false(closedDuringShutdown)
        assert.is_true(events:IsClosed())
    end)
end)

describe("EventKit at logout without LifecycleKit", function()
    after_each(TestEnv.Reset)

    it("closes every addon scope from one PLAYER_LOGOUT one-shot", function()
        local EventKit = TestEnv.NewPackage()
        local first = EventKit:ForAddon("First")
        local connection = privateState(EventKit).logoutConnection
        local second = EventKit:ForAddon("Second")
        local manual = EventKit:CreateScope()
        manual:Connect("PLAYER_LOGOUT", function() end)

        assert.are.equal("playerLogout", rawget(first, "_logoutRoute"))
        assert.are.equal("playerLogout", rawget(second, "_logoutRoute"))
        assert.is_true(connection:IsConnected())
        assert.are.equal(connection, privateState(EventKit).logoutConnection)

        TestEnv.Logout()

        assert.is_true(first:IsClosed())
        assert.is_true(second:IsClosed())
        assert.is_false(manual:IsClosed())
        assert.is_false(connection:IsConnected())
        assert.is_false(privateState(EventKit).logoutConnection)
    end)

    it("still runs scoped PLAYER_LOGOUT listeners connected before and after it", function()
        local EventKit = TestEnv.NewPackage()
        local earlier = EventKit:CreateScope()
        local observed = {}
        -- Connected before the addon scope exists, so before EventKit's own
        -- logout one-shot.
        local events
        earlier:Connect("PLAYER_LOGOUT", function()
            observed.earlierSawClosed = events:IsClosed()
        end)
        events = EventKit:ForAddon("MyAddon")
        events:Connect("PLAYER_LOGOUT", function()
            observed.scopedRan = true
            observed.scopedSawClosed = events:IsClosed()
        end)

        TestEnv.Logout()

        assert.are.same({
            earlierSawClosed = false,
            scopedRan = true,
            scopedSawClosed = true,
        }, observed)
        assert.are.equal(0, events:GetActiveCount())

        -- The sweep ran after the dispatch: nothing is delivered any more.
        observed = {}
        TestEnv.Emit("PLAYER_LOGOUT")
        assert.is_nil(observed.scopedRan)
    end)

    it("leaves the call to the addon when the host refuses the registration", function()
        local EventKit = TestEnv.NewPackage()
        TestEnv.FailNextRegisterEvent()
        local events = EventKit:ForAddon("MyAddon")

        assert.are.equal("none", rawget(events, "_logoutRoute"))
        assert.is_false(privateState(EventKit).logoutConnection)

        -- The next ForAddon looks again, and this time the host accepts.
        assert.are.equal(events, EventKit:ForAddon("MyAddon"))
        assert.are.equal("playerLogout", rawget(events, "_logoutRoute"))
        TestEnv.Logout()
        assert.is_true(events:IsClosed())
    end)

    it("still closes a scope routed before LifecycleKit loaded", function()
        local EventKit = TestEnv.NewPackage()
        local events = EventKit:ForAddon("MyAddon")
        local LifecycleKit = TestEnv.LoadLifecycleKit()
        LifecycleKit:ForAddon("MyAddon")
        local logouts = countLogouts(events)

        assert.are.equal("playerLogout", rawget(events, "_logoutRoute"))
        TestEnv.Logout()

        assert.are.equal(1, logouts.count)
        assert.is_true(events:IsClosed())
        assert.are.same({}, TestEnv.TakeReportedErrors())
    end)
end)

describe("EventKit logout routes across an upgrade", function()
    after_each(TestEnv.Reset)

    ---Load Registry and SignalKit with the WoW stubs, without EventKit.
    local function loadChainWithoutEventKit()
        TestEnv.Reset()
        TestEnv.InstallWowApi()
        require("Registry")
        require("SignalKit")
    end

    it("gives the scopes of a revision without routes one when it upgrades them", function()
        loadChainWithoutEventKit()
        local legacy = TestEnv.LoadSourceAtRevision(10)
        local events = legacy:ForAddon("MyAddon")
        local logouts = countLogouts(events)
        -- Revision 10 decided no route and kept no logout connection.
        local legacyState = privateState(legacy)
        legacyState.logoutConnection:Disconnect()
        rawset(legacyState, "logoutConnection", nil)
        rawset(legacyState, "schema", 6)
        rawset(events, "_logoutRoute", nil)
        rawset(events, "_logoutSubscription", nil)

        local EventKit = require("EventKit")

        -- The loading copy is the current source, whatever its revision.
        local _, revision = require("Registry"):Get("eventKit", 1)
        assert.are.equal(legacy, EventKit)
        assert.are.equal(revision, EventKit.REVISION)
        assert.is_true(EventKit.REVISION > 10)
        assert.are.equal(8, privateState(EventKit).schema)
        assert.are.equal("playerLogout", rawget(events, "_logoutRoute"))
        TestEnv.Logout()
        assert.are.equal(1, logouts.count)
        assert.is_true(events:IsClosed())
    end)

    it("carries the PLAYER_LOGOUT one-shot an older copy made", function()
        loadChainWithoutEventKit()
        local legacy = TestEnv.LoadSourceAtRevision(10)
        local events = legacy:ForAddon("MyAddon")
        local connection = privateState(legacy).logoutConnection

        local EventKit = require("EventKit")
        local later = EventKit:ForAddon("Later")

        assert.are.equal(connection, privateState(EventKit).logoutConnection)
        TestEnv.Logout()
        assert.is_true(events:IsClosed())
        assert.is_true(later:IsClosed())
    end)

    it("carries an OnShutdown subscription an older copy made", function()
        loadChainWithoutEventKit()
        local legacy = TestEnv.LoadSourceAtRevision(10)
        local LifecycleKit = TestEnv.LoadLifecycleKit()
        withoutCapability(LifecycleKit)
        local events = legacy:ForAddon("MyAddon")
        local subscription = rawget(events, "_logoutSubscription")

        local EventKit = require("EventKit")

        assert.are.equal(subscription, rawget(events, "_logoutSubscription"))
        assert.is_true(subscription:IsConnected())
        logoutWithoutLifecycleCall(EventKit)
        assert.is_true(events:IsClosed())
    end)
end)
