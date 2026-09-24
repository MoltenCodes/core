local TestEnv = require("SchedulerKitTestEnv")

-- An addon scope closes at logout whenever the framework can observe logout,
-- whatever LifecycleKit and EventKit revisions are paired with SchedulerKit.
-- The first `ForAddon` decides who makes the `CloseAddonScopes` call
-- (docs/API.md, "At logout"):
--
--   a. a LifecycleKit that lists "schedulerKit" in CLOSES_ADDON_SCOPES;
--   b. an older LifecycleKit, through an OnShutdown subscription;
--   c. without LifecycleKit, one EventKit PLAYER_LOGOUT connection;
--   d. with neither, the addon itself.

---The package-private state of `SchedulerKit`, for assertions.
---@param SchedulerKit table
---@return table state
local function privateState(SchedulerKit)
    return rawget(SchedulerKit, "_state")
end

---Remove LifecycleKit's capability field, turning the real LifecycleKit into
---one that, like every revision before 13, does not say what it closes.
---@param LifecycleKit table
local function withoutCapability(LifecycleKit)
    rawset(LifecycleKit, "CLOSES_ADDON_SCOPES", nil)
end

---Log out with `SchedulerKit:CloseAddonScopes` hidden, as a LifecycleKit that
---does not know the call sees it, so only SchedulerKit's own route can close.
---@param SchedulerKit table
local function logoutWithoutLifecycleCall(SchedulerKit)
    local closeAddonScopes = rawget(SchedulerKit, "CloseAddonScopes")
    rawset(SchedulerKit, "CloseAddonScopes", nil)
    local ok, failure = pcall(TestEnv.Logout)
    rawset(SchedulerKit, "CloseAddonScopes", closeAddonScopes)
    assert(ok, failure)
end

describe("SchedulerKit at logout with a LifecycleKit that closes scheduler scopes", function()
    after_each(TestEnv.Reset)

    it("subscribes nothing and is closed by LifecycleKit after shutdown callbacks", function()
        local SchedulerKit = TestEnv.NewPackage()
        local LifecycleKit = TestEnv.LoadLifecycleKit()
        local life = LifecycleKit:ForAddon("MyAddon")
        local jobs = SchedulerKit:ForAddon("MyAddon")
        local delayed = jobs:After(5, function() end)
        local closedDuringShutdown
        life:OnShutdown(function()
            closedDuringShutdown = jobs:IsClosed()
        end)

        assert.are.equal("lifecycleKit", rawget(jobs, "_logoutRoute"))
        assert.is_false(rawget(jobs, "_logoutSubscription"))
        assert.is_false(privateState(SchedulerKit).logoutConnection)

        TestEnv.Logout()

        assert.is_false(closedDuringShutdown)
        assert.is_true(jobs:IsClosed())
        assert.are.equal("cancelled", delayed:GetState())
    end)
    it("closes the scope of an addon that never called LifecycleKit:ForAddon", function()
        local SchedulerKit = TestEnv.NewPackage()
        TestEnv.LoadLifecycleKit()
        local jobs = SchedulerKit:ForAddon("NeverAsked")
        local job = jobs:Schedule(function() end)

        TestEnv.Logout()

        assert.is_true(jobs:IsClosed())
        assert.is_true(job:GetState() == "cancelled")
    end)
end)

describe("SchedulerKit at logout with a LifecycleKit without the capability", function()
    after_each(TestEnv.Reset)

    it("closes the scope from an OnShutdown subscription", function()
        local SchedulerKit = TestEnv.NewPackage()
        local LifecycleKit = TestEnv.LoadLifecycleKit()
        withoutCapability(LifecycleKit)
        local jobs = SchedulerKit:ForAddon("MyAddon")
        local job = jobs:Schedule(function() end)
        local subscription = rawget(jobs, "_logoutSubscription")

        assert.are.equal("onShutdown", rawget(jobs, "_logoutRoute"))
        assert.is_true(subscription:IsConnected())
        assert.is_false(privateState(SchedulerKit).logoutConnection)

        logoutWithoutLifecycleCall(SchedulerKit)

        assert.is_true(jobs:IsClosed())
        assert.are.equal("cancelled", job:GetState())
        assert.is_false(rawget(jobs, "_logoutSubscription"))
    end)

    it("subscribes once per addon", function()
        local SchedulerKit = TestEnv.NewPackage()
        local LifecycleKit = TestEnv.LoadLifecycleKit()
        withoutCapability(LifecycleKit)
        local jobs = SchedulerKit:ForAddon("MyAddon")
        local subscription = rawget(jobs, "_logoutSubscription")

        assert.are.equal(jobs, SchedulerKit:ForAddon("MyAddon"))
        assert.are.equal(subscription, rawget(jobs, "_logoutSubscription"))
    end)

    it("disconnects the subscription when CloseAddonScopes closes the scope", function()
        local SchedulerKit = TestEnv.NewPackage()
        local LifecycleKit = TestEnv.LoadLifecycleKit()
        withoutCapability(LifecycleKit)
        local jobs = SchedulerKit:ForAddon("MyAddon")
        local subscription = rawget(jobs, "_logoutSubscription")

        assert.is_true(SchedulerKit:CloseAddonScopes("MyAddon"))

        assert.is_false(subscription:IsConnected())
        assert.is_false(rawget(jobs, "_logoutSubscription"))
    end)

    it("disconnects the subscription when the scope is closed by hand", function()
        local SchedulerKit = TestEnv.NewPackage()
        local LifecycleKit = TestEnv.LoadLifecycleKit()
        withoutCapability(LifecycleKit)
        local jobs = SchedulerKit:ForAddon("MyAddon")
        local subscription = rawget(jobs, "_logoutSubscription")

        assert.is_true(jobs:Close())

        assert.is_false(subscription:IsConnected())
    end)

    it("steps aside when a LifecycleKit that closes scheduler scopes replaced it", function()
        local SchedulerKit = TestEnv.NewPackage()
        local LifecycleKit = TestEnv.LoadLifecycleKit()
        local capabilities = rawget(LifecycleKit, "CLOSES_ADDON_SCOPES")
        withoutCapability(LifecycleKit)
        local jobs = SchedulerKit:ForAddon("MyAddon")
        local closedDuringShutdown
        LifecycleKit:ForAddon("MyAddon"):OnShutdown(function()
            closedDuringShutdown = jobs:IsClosed()
        end)

        rawset(LifecycleKit, "CLOSES_ADDON_SCOPES", capabilities)
        TestEnv.Logout()

        assert.is_false(closedDuringShutdown)
        assert.is_true(jobs:IsClosed())
    end)
end)

describe("SchedulerKit at logout with EventKit and no LifecycleKit", function()
    after_each(TestEnv.Reset)

    it("closes every addon scope from one PLAYER_LOGOUT connection", function()
        local SchedulerKit = TestEnv.NewPackage()
        TestEnv.LoadEventKit()
        local first = SchedulerKit:ForAddon("First")
        local firstJob = first:After(5, function() end)
        local connection = privateState(SchedulerKit).logoutConnection
        local second = SchedulerKit:ForAddon("Second")
        local manual = SchedulerKit:CreateScope()

        assert.are.equal("playerLogout", rawget(first, "_logoutRoute"))
        assert.are.equal("playerLogout", rawget(second, "_logoutRoute"))
        assert.is_true(connection:IsConnected())
        assert.are.equal(connection, privateState(SchedulerKit).logoutConnection)
        assert.are.equal(1, privateState(SchedulerKit).logoutEventScope:GetActiveCount())

        TestEnv.Logout()

        assert.is_true(first:IsClosed())
        assert.are.equal("cancelled", firstJob:GetState())
        assert.is_true(second:IsClosed())
        assert.is_false(manual:IsClosed())
        assert.is_false(connection:IsConnected())
        assert.is_false(privateState(SchedulerKit).logoutConnection)
    end)

    it("runs a scoped PLAYER_LOGOUT handler connected earlier while jobs are live", function()
        local SchedulerKit = TestEnv.NewPackage()
        local EventKit = TestEnv.LoadEventKit()
        local jobs
        local observed = {}
        EventKit:ForAddon("MyAddon"):Connect("PLAYER_LOGOUT", function()
            observed.before = jobs:IsClosed()
        end)
        jobs = SchedulerKit:ForAddon("MyAddon")
        EventKit:ForAddon("MyAddon"):Connect("PLAYER_LOGOUT", function()
            observed.after = jobs:IsClosed()
        end)

        TestEnv.Logout()

        assert.are.same({ before = false, after = true }, observed)
    end)

    it("closes every other scope when one fails and reports the failure", function()
        local SchedulerKit = TestEnv.NewPackage()
        TestEnv.LoadEventKit()
        local first = SchedulerKit:ForAddon("First")
        first:After(5, function() end)
        local second = SchedulerKit:ForAddon("Second")
        TestEnv.FailNextTimerCancel("native cancel failed")

        TestEnv.Logout()

        assert.is_true(first:IsClosed())
        assert.is_true(second:IsClosed())
        local reported = TestEnv.TakeReportedErrors()
        assert.are.equal(1, #reported)
        assert.is_not_nil(tostring(reported[1].value):find("native cancel failed", 1, true))
    end)
end)

describe("SchedulerKit at logout with neither LifecycleKit nor EventKit", function()
    after_each(TestEnv.Reset)

    it("subscribes nothing and leaves the call to the addon", function()
        local SchedulerKit = TestEnv.NewPackage()
        local jobs = SchedulerKit:ForAddon("MyAddon")
        local job = jobs:Schedule(function() end)

        assert.are.equal("none", rawget(jobs, "_logoutRoute"))
        assert.is_false(rawget(jobs, "_logoutSubscription"))
        assert.is_false(privateState(SchedulerKit).logoutConnection)

        TestEnv.Logout()

        assert.is_false(jobs:IsClosed())
        assert.is_true(job:IsPending())
        assert.is_true(SchedulerKit:CloseAddonScopes("MyAddon"))
        assert.are.equal("cancelled", job:GetState())
    end)

    it("looks again at the next ForAddon once EventKit has loaded", function()
        local SchedulerKit = TestEnv.NewPackage()
        local jobs = SchedulerKit:ForAddon("MyAddon")
        TestEnv.LoadEventKit()

        assert.are.equal(jobs, SchedulerKit:ForAddon("MyAddon"))
        assert.are.equal("playerLogout", rawget(jobs, "_logoutRoute"))

        TestEnv.Logout()

        assert.is_true(jobs:IsClosed())
    end)

    it("is closed by a LifecycleKit that loads later", function()
        local SchedulerKit = TestEnv.NewPackage()
        local jobs = SchedulerKit:ForAddon("MyAddon")
        local LifecycleKit = TestEnv.LoadLifecycleKit()
        LifecycleKit:ForAddon("MyAddon")

        TestEnv.Logout()

        assert.is_true(jobs:IsClosed())
    end)
end)

describe("SchedulerKit logout routes across an upgrade", function()
    after_each(TestEnv.Reset)

    ---Load Registry and TimerKit with the WoW stubs, as `NewPackage` does,
    ---without SchedulerKit.
    local function loadChainWithoutSchedulerKit()
        TestEnv.Reset()
        TestEnv.InstallWowApi()
        require("Registry")
        require("TimerKit")
    end

    it("gives the scopes of a revision without routes one when it upgrades them", function()
        loadChainWithoutSchedulerKit()
        TestEnv.LoadEventKit()
        local old = TestEnv.LoadRevision(11)
        local jobs = old:ForAddon("MyAddon")
        local job = jobs:Schedule(function() end)
        -- Revision 11 decided no route and kept no logout fields.
        rawset(jobs, "_logoutRoute", nil)
        rawset(jobs, "_logoutSubscription", nil)
        local oldState = privateState(old)
        oldState.logoutConnection:Disconnect()
        rawset(oldState, "logoutConnection", nil)
        rawset(oldState, "logoutEventScope", nil)

        local upgraded = require("SchedulerKit")

        assert.are.equal(old, upgraded)
        assert.are.equal(13, upgraded.REVISION)
        assert.are.equal("playerLogout", rawget(jobs, "_logoutRoute"))
        TestEnv.Logout()
        assert.is_true(jobs:IsClosed())
        assert.are.equal("cancelled", job:GetState())
    end)

    it("carries an OnShutdown subscription an older copy made", function()
        loadChainWithoutSchedulerKit()
        local LifecycleKit = TestEnv.LoadLifecycleKit()
        withoutCapability(LifecycleKit)
        local old = TestEnv.LoadRevision(11)
        local jobs = old:ForAddon("MyAddon")
        local subscription = rawget(jobs, "_logoutSubscription")

        local upgraded = require("SchedulerKit")

        assert.are.equal(subscription, rawget(jobs, "_logoutSubscription"))
        assert.is_true(subscription:IsConnected())
        logoutWithoutLifecycleCall(upgraded)
        assert.is_true(jobs:IsClosed())
    end)

    it("carries the PLAYER_LOGOUT connection an older copy made", function()
        loadChainWithoutSchedulerKit()
        TestEnv.LoadEventKit()
        local old = TestEnv.LoadRevision(11)
        local jobs = old:ForAddon("MyAddon")
        local connection = privateState(old).logoutConnection

        local upgraded = require("SchedulerKit")
        local later = upgraded:ForAddon("Later")

        assert.are.equal(connection, privateState(upgraded).logoutConnection)
        TestEnv.Logout()
        assert.is_true(jobs:IsClosed())
        assert.is_true(later:IsClosed())
    end)
end)
