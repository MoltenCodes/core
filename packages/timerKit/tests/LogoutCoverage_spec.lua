local TestEnv = require("TimerKitTestEnv")

-- An addon scope closes at logout whenever the framework can observe logout,
-- whatever LifecycleKit and EventKit revisions are paired with TimerKit. The
-- first `ForAddon` decides who makes the `CloseAddonScopes` call (docs/API.md,
-- "At logout"):
--
--   1. a LifecycleKit that lists "timerKit" in CLOSES_ADDON_SCOPES;
--   3. without such a LifecycleKit, one EventKit PLAYER_LOGOUT connection;
--   4. with neither, the addon itself.
--
-- Route 2, an OnShutdown subscription for a LifecycleKit before revision 13,
-- went with the upgrade floor of revision 15: no such LifecycleKit was ever
-- published.

---The package-private logout fields of `TimerKit`, for assertions.
---@param TimerKit table
---@return table state
local function privateState(TimerKit)
  return rawget(TimerKit, "_state")
end

---Remove LifecycleKit's capability field, turning the real LifecycleKit into
---one that, like every revision before 13, does not say what it closes.
---@param LifecycleKit table
local function withoutCapability(LifecycleKit)
  rawset(LifecycleKit, "CLOSES_ADDON_SCOPES", nil)
end

---Log out with `TimerKit:CloseAddonScopes` hidden, as a LifecycleKit that
---does not know the call sees it, so only TimerKit's own route can close.
---@param TimerKit table
local function logoutWithoutLifecycleCall(TimerKit)
  local closeAddonScopes = rawget(TimerKit, "CloseAddonScopes")
  rawset(TimerKit, "CloseAddonScopes", nil)
  local ok, failure = pcall(TestEnv.Logout)
  rawset(TimerKit, "CloseAddonScopes", closeAddonScopes)
  assert(ok, failure)
end

describe("TimerKit at logout with a LifecycleKit that closes timer scopes", function()
  after_each(TestEnv.Reset)

  it("subscribes nothing and is closed by LifecycleKit after shutdown callbacks", function()
    local TimerKit = TestEnv.NewPackage()
    local LifecycleKit = TestEnv.LoadLifecycleKit()
    local life = LifecycleKit:ForAddon("MyAddon")
    local timers = TimerKit:ForAddon("MyAddon")
    local ticker = timers:Every(1, function() end)
    local closedDuringShutdown
    life:OnShutdown(function()
      closedDuringShutdown = timers:IsClosed()
    end)

    assert.are.equal("lifecycleKit", rawget(timers, "_logoutRoute"))
    assert.is_nil(rawget(timers, "_logoutSubscription"))
    assert.is_false(privateState(TimerKit).logoutConnection)

    TestEnv.Logout()

    assert.is_false(closedDuringShutdown)
    assert.is_true(timers:IsClosed())
    assert.is_true(ticker:IsCancelled())
  end)
  it("closes the scope of an addon that never called LifecycleKit:ForAddon", function()
    local TimerKit = TestEnv.NewPackage()
    TestEnv.LoadLifecycleKit()
    local timers = TimerKit:ForAddon("NeverAsked")
    local ticker = timers:Every(1, function() end)

    TestEnv.Logout()

    assert.is_true(timers:IsClosed())
    assert.is_true(ticker:IsCancelled())
  end)
end)

describe("TimerKit at logout with a LifecycleKit without the capability", function()
  after_each(TestEnv.Reset)

  it("subscribes nothing to LifecycleKit and closes through PLAYER_LOGOUT", function()
    local TimerKit = TestEnv.NewPackage()
    local LifecycleKit = TestEnv.LoadLifecycleKit()
    withoutCapability(LifecycleKit)
    local timers = TimerKit:ForAddon("MyAddon")
    local ticker = timers:Every(1, function() end)

    assert.are.equal("playerLogout", rawget(timers, "_logoutRoute"))
    assert.is_nil(rawget(timers, "_logoutSubscription"))
    assert.is_true(privateState(TimerKit).logoutConnection:IsConnected())

    logoutWithoutLifecycleCall(TimerKit)

    assert.is_true(timers:IsClosed())
    assert.is_true(ticker:IsCancelled())
  end)
end)

describe("TimerKit at logout with EventKit and no LifecycleKit", function()
  after_each(TestEnv.Reset)

  it("closes every addon scope from one PLAYER_LOGOUT connection", function()
    local TimerKit = TestEnv.NewPackage()
    TestEnv.LoadEventKit()
    local first = TimerKit:ForAddon("First")
    local firstTicker = first:Every(1, function() end)
    local connection = privateState(TimerKit).logoutConnection
    local second = TimerKit:ForAddon("Second")
    local manual = TimerKit:CreateScope()

    assert.are.equal("playerLogout", rawget(first, "_logoutRoute"))
    assert.are.equal("playerLogout", rawget(second, "_logoutRoute"))
    assert.is_true(connection:IsConnected())
    assert.are.equal(connection, privateState(TimerKit).logoutConnection)
    assert.are.equal(1, privateState(TimerKit).logoutEventScope:GetActiveCount())

    TestEnv.Logout()

    assert.is_true(first:IsClosed())
    assert.is_true(firstTicker:IsCancelled())
    assert.is_true(second:IsClosed())
    assert.is_false(manual:IsClosed())
    assert.is_false(connection:IsConnected())
    assert.is_false(privateState(TimerKit).logoutConnection)
  end)

  it("runs a scoped PLAYER_LOGOUT handler connected earlier while timers are live", function()
    local TimerKit = TestEnv.NewPackage()
    local EventKit = TestEnv.LoadEventKit()
    local timers
    local observed = {}
    EventKit:ForAddon("MyAddon"):Connect("PLAYER_LOGOUT", function()
      observed.before = timers:IsClosed()
    end)
    timers = TimerKit:ForAddon("MyAddon")
    EventKit:ForAddon("MyAddon"):Connect("PLAYER_LOGOUT", function()
      observed.after = timers:IsClosed()
    end)

    TestEnv.Logout()

    -- Handlers run in connection order: one connected before TimerKit's
    -- logout connection sees the scope open, one connected after sees
    -- it closed. LifecycleKit gives the stronger ordering.
    assert.are.same({ before = false, after = true }, observed)
  end)

  it("closes every other scope when one fails and reports the failure", function()
    local TimerKit = TestEnv.NewPackage()
    TestEnv.LoadEventKit()
    local first = TimerKit:ForAddon("First")
    first:Every(1, function() end)
    local second = TimerKit:ForAddon("Second")
    TestEnv.FailNextCancel("native cancel failed")

    TestEnv.Logout()

    assert.is_true(first:IsClosed())
    assert.is_true(second:IsClosed())
    local reported = TestEnv.TakeReportedErrors()
    assert.are.equal(1, #reported)
    assert.is_not_nil(tostring(reported[1].value):find("native cancel failed", 1, true))
  end)
end)

describe("TimerKit at logout with neither LifecycleKit nor EventKit", function()
  after_each(TestEnv.Reset)

  it("subscribes nothing and leaves the call to the addon", function()
    local TimerKit = TestEnv.NewPackage()
    local timers = TimerKit:ForAddon("MyAddon")
    local ticker = timers:Every(1, function() end)

    assert.are.equal("none", rawget(timers, "_logoutRoute"))
    assert.is_nil(rawget(timers, "_logoutSubscription"))
    assert.is_false(privateState(TimerKit).logoutConnection)

    TestEnv.Logout()

    assert.is_false(timers:IsClosed())
    assert.is_true(ticker:IsPending())
    assert.is_true(TimerKit:CloseAddonScopes("MyAddon"))
    assert.is_true(ticker:IsCancelled())
  end)

  it("looks again at the next ForAddon once EventKit has loaded", function()
    local TimerKit = TestEnv.NewPackage()
    local timers = TimerKit:ForAddon("MyAddon")
    TestEnv.LoadEventKit()

    assert.are.equal(timers, TimerKit:ForAddon("MyAddon"))
    assert.are.equal("playerLogout", rawget(timers, "_logoutRoute"))

    TestEnv.Logout()

    assert.is_true(timers:IsClosed())
  end)

  it("is closed by a LifecycleKit that loads later", function()
    local TimerKit = TestEnv.NewPackage()
    local timers = TimerKit:ForAddon("MyAddon")
    local LifecycleKit = TestEnv.LoadLifecycleKit()
    LifecycleKit:ForAddon("MyAddon")

    TestEnv.Logout()

    assert.is_true(timers:IsClosed())
    assert.are.equal(timers, TimerKit:ForAddon("MyAddon"))
  end)
end)

describe("TimerKit logout routes across an upgrade from revision 14", function()
  after_each(TestEnv.Reset)

  it("carries the PLAYER_LOGOUT connection revision 14 made", function()
    TestEnv.Reset()
    TestEnv.InstallWowApi()
    require("Registry")
    TestEnv.LoadEventKit()
    local old = TestEnv.LoadRevision14()
    local timers = old:ForAddon("MyAddon")
    local connection = privateState(old).logoutConnection

    local upgraded = require("TimerKit")
    local later = upgraded:ForAddon("Later")

    assert.are.equal(old, upgraded)
    assert.are.equal(connection, privateState(upgraded).logoutConnection)
    TestEnv.Logout()
    assert.is_true(timers:IsClosed())
    assert.is_true(later:IsClosed())
  end)

  it("lets go of a revision 14 OnShutdown subscription and routes the scope again", function()
    TestEnv.Reset()
    TestEnv.InstallWowApi()
    require("Registry")
    local LifecycleKit = TestEnv.LoadLifecycleKit()
    withoutCapability(LifecycleKit)
    local old = TestEnv.LoadRevision14()
    local timers = old:ForAddon("MyAddon")
    local ticker = timers:Every(1, function() end)
    local subscription = rawget(timers, "_logoutSubscription")
    assert.are.equal("onShutdown", rawget(timers, "_logoutRoute"))

    local upgraded = require("TimerKit")

    assert.is_false(subscription:IsConnected())
    assert.is_nil(rawget(timers, "_logoutSubscription"))
    assert.are.equal("playerLogout", rawget(timers, "_logoutRoute"))
    assert.is_nil(rawget(privateState(upgraded).dispatch, "closeOnShutdown"))
    logoutWithoutLifecycleCall(upgraded)
    assert.is_true(timers:IsClosed())
    assert.is_true(ticker:IsCancelled())
  end)
end)
