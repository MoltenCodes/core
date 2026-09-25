local TestEnv = require("TimerKitTestEnv")

---Return the implementation revision the working source carries.
---@return integer
local function currentRevision()
  return TestEnv.NewPackage().REVISION
end

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
    local current = currentRevision()
    TestEnv.Reset()
    TestEnv.InstallWowApi()
    local Registry = require("Registry")

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
    assert.are.equal(current, upgraded.REVISION)
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

  it("upgrades a revision-5 copy and releases its shutdown subscriptions", function()
    local current = currentRevision()
    TestEnv.Reset()
    TestEnv.InstallWowApi()
    local Registry = require("Registry")

    -- Revision 5 required LifecycleKit and subscribed each addon scope to
    -- its addon's shutdown. The stand-in subscriptions below record
    -- whether the upgrade disconnected them; the second one fails, which
    -- must not stop the upgrade.
    local disconnects = 0
    local healthySubscription = {
      Disconnect = function()
        disconnects = disconnects + 1
        return true
      end,
    }
    local failingSubscription = {
      Disconnect = function()
        error("lifecycle gone", 0)
      end,
    }

    local old = Registry:Register("timerKit", 1, 5)
    local timerPrototype = {}
    local scopePrototype = {}
    local timerMetatable = { __index = timerPrototype }
    local scopeMetatable = { __index = scopePrototype }
    rawset(old, "API", 1)
    rawset(old, "REVISION", 5)
    rawset(old, "Timer", timerPrototype)
    rawset(old, "Scope", scopePrototype)

    local carried = setmetatable({
      _addonName = "Carried",
      _active = {},
      _activeCount = 0,
      _closed = false,
      _shutdownSubscription = healthySubscription,
    }, scopeMetatable)
    local failing = setmetatable({
      _addonName = "Failing",
      _active = {},
      _activeCount = 0,
      _closed = false,
      _shutdownSubscription = failingSubscription,
    }, scopeMetatable)
    local defaultScope = setmetatable({
      _active = {},
      _activeCount = 0,
      _closed = false,
    }, scopeMetatable)
    local carriedTimer = setmetatable({
      _id = 3,
      _scope = carried,
      _callback = function() end,
      _delay = 1,
      _repeating = false,
      _state = "idle",
      _generation = 0,
      _deadline = false,
    }, timerMetatable)
    rawset(old, "_state", {
      schema = 1,
      addonScopes = { Carried = carried, Failing = failing },
      defaultScope = defaultScope,
      dispatch = {},
      nextTimerId = 3,
      runtimeRevision = 5,
      timerMetatable = timerMetatable,
      scopeMetatable = scopeMetatable,
    })

    local upgraded = require("TimerKit")

    assert.are.equal(old, upgraded)
    assert.are.equal(current, upgraded.REVISION)
    assert.are.equal(1, disconnects)
    assert.is_nil(rawget(carried, "_shutdownSubscription"))
    assert.is_nil(rawget(failing, "_shutdownSubscription"))

    -- The carried scope stays canonical and open, and its timers work.
    assert.are.equal(carried, upgraded:ForAddon("Carried"))
    assert.is_false(carried:IsClosed())
    assert.is_true(carriedTimer:Start())
    assert.are.equal(1, carried:GetActiveCount())

    -- The two-step replaces the subscription.
    assert.is_true(upgraded:CloseAddonScopes("Carried"))
    assert.is_true(carriedTimer:IsCancelled())
    assert.is_true(carried:IsClosed())
    assert.is_true(upgraded:CloseAddonScopes("Failing"))

    -- A revision-5 wrapper that could not be disconnected still resolves
    -- `closeScope` through dispatch; closing again is a no-op.
    assert.is_false(upgraded._state.dispatch.closeScope(carried))
  end)

  it("upgrades a revision-7 copy with its timers, scopes and logout route", function()
    local current = currentRevision()
    TestEnv.Reset()
    TestEnv.InstallWowApi()
    require("Registry")
    TestEnv.LoadEventKit()
    local old = TestEnv.LoadRevision(7)
    local timers = old:ForAddon("MyAddon")
    local fired = 0
    local ticker = timers:Every(1, function()
      fired = fired + 1
    end)
    local oneShot = timers:After(5, function() end)
    local connection = rawget(old, "_state").logoutConnection

    local upgraded = require("TimerKit")

    assert.are.equal(old, upgraded)
    assert.are.equal(current, upgraded.REVISION)
    assert.are.equal(timers, upgraded:ForAddon("MyAddon"))
    assert.are.equal("playerLogout", rawget(timers, "_logoutRoute"))
    assert.are.equal(connection, rawget(upgraded, "_state").logoutConnection)

    -- A handle revision 7 started still fires and cancels under the current revision.
    TestEnv.FireNative(1)
    assert.are.equal(1, fired)
    assert.is_true(oneShot:Cancel())
    assert.are.equal(1, timers:GetActiveCount())

    TestEnv.Logout()
    assert.is_true(timers:IsClosed())
    assert.is_true(ticker:IsCancelled())
  end)

  it("upgrades the previous revision in place with its timers and scopes", function()
    local current = currentRevision()
    TestEnv.Reset()
    TestEnv.InstallWowApi()
    require("Registry")
    TestEnv.LoadEventKit()
    local old = TestEnv.LoadRevision(current - 1)
    local state = rawget(old, "_state")
    local timers = old:ForAddon("MyAddon")
    local fired = 0
    local ticker = timers:Every(1, function()
      fired = fired + 1
    end)
    ticker:SetUserData("payload")

    local upgraded = require("TimerKit")

    assert.are.equal(old, upgraded)
    assert.are.equal(state, rawget(upgraded, "_state"))
    assert.are.equal(current, upgraded.REVISION)
    assert.are.equal(timers, upgraded:ForAddon("MyAddon"))
    assert.are.equal("payload", ticker:GetUserData())
    TestEnv.FireNative(1)
    assert.are.equal(1, fired)
    assert.is_true(ticker:Cancel())
    assert.are.equal(0, timers:GetActiveCount())
  end)

  it("cancels and restarts a one-shot the previous revision started", function()
    local current = currentRevision()
    TestEnv.Reset()
    TestEnv.InstallWowApi()
    require("Registry")
    local old = TestEnv.LoadRevision(current - 1)
    local scope = old:CreateScope()
    local calls = 0
    local pending = scope:After(1, function()
      calls = calls + 1
    end)
    local firing = scope:After(1, function()
      calls = calls + 10
    end)

    local upgraded = require("TimerKit")
    assert.are.equal(current, upgraded.REVISION)

    -- The handle the previous revision stored is cancelled directly, and the
    -- callback it bound goes stale.
    assert.is_true(pending:Cancel())
    assert.is_true(TestEnv.NativeTimers()[1].cancelled)
    TestEnv.InvokeRaw(1)
    assert.are.equal(0, calls)

    TestEnv.FireNative(2)
    assert.are.equal(10, calls)
    assert.are.equal("completed", firing:GetState())

    assert.is_true(pending:Restart())
    TestEnv.FireNative(3)
    assert.are.equal(11, calls)
    assert.are.equal(0, scope:GetActiveCount())
  end)

  it(
    "keeps the generation-bound callbacks of revision 9 timers working after an upgrade",
    function()
      local current = currentRevision()
      TestEnv.Reset()
      TestEnv.InstallWowApi()
      require("Registry")
      local old = TestEnv.LoadRevision(9)
      local state = rawget(old, "_state")
      local scope = old:CreateScope()

      -- Timers exactly as revision 9 built and started them: every field
      -- present, a `_generation` counter, and a host callback that passes the
      -- generation of its start to `dispatch.fire`.
      local calls = {}
      local function legacyTimer(name, repeating)
        local timer = setmetatable({
          _id = #calls + 100,
          _scope = scope,
          _callback = function()
            calls[name] = (calls[name] or 0) + 1
          end,
          _delay = 1,
          _repeating = repeating,
          _state = "running",
          _native = nil,
          _generation = 1,
          _deadline = false,
        }, rawget(state, "timerMetatable"))
        local generation = 1
        -- The fixture's C_Timer is a global, as the client's is.
        -- selene: allow(global_usage)
        local hostTimers = rawget(_G, "C_Timer")
        local constructor = repeating and hostTimers.NewTicker or hostTimers.NewTimer
        timer._native = constructor(1, function()
          return rawget(rawget(state, "dispatch"), "fire")(timer, generation)
        end)
        rawset(scope._active, timer, true)
        scope._activeCount = scope._activeCount + 1
        return timer
      end
      local fires = legacyTimer("fires", false)
      local cancelled = legacyTimer("cancelled", false)
      local restarted = legacyTimer("restarted", false)
      local ticker = legacyTimer("ticker", true)

      local upgraded = require("TimerKit")
      assert.are.equal(old, upgraded)
      assert.are.equal(current, upgraded.REVISION)

      TestEnv.FireNative(1)
      assert.are.equal(1, calls.fires)
      assert.are.equal("completed", fires:GetState())

      assert.is_true(cancelled:Cancel())
      TestEnv.InvokeRaw(2)
      assert.is_nil(calls.cancelled)

      assert.is_true(restarted:Restart())
      TestEnv.InvokeRaw(3)
      assert.is_nil(calls.restarted)
      TestEnv.FireNative(5)
      assert.are.equal(1, calls.restarted)

      TestEnv.FireNative(4)
      TestEnv.FireNative(4)
      assert.are.equal(2, calls.ticker)
      assert.is_true(ticker:IsPending())
      assert.is_true(ticker:Cancel())
      assert.are.equal(0, scope:GetActiveCount())
    end
  )

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

  it("loads without GetTimePreciseSec and reports no remaining time", function()
    TestEnv.Reset()
    TestEnv.InstallWowApi()
    require("Registry")
    -- The package reads this host global at load time, so the spec has to remove it from the global table.
    -- selene: allow(global_usage)
    rawset(_G, "GetTimePreciseSec", nil)

    local TimerKit = require("TimerKit")
    local fired = 0
    local timer = TimerKit:After(2, function()
      fired = fired + 1
    end)
    local ticker = TimerKit:Every(1, function() end)

    assert.is_true(timer:IsPending())
    assert.is_nil(timer:GetRemaining())
    assert.is_nil(timer:GetDeadline())
    TestEnv.FireNative(2)
    assert.is_nil(ticker:GetRemaining())
    TestEnv.FireNative(1)
    assert.are.equal(1, fired)
  end)

  it("loads with Registry alone", function()
    TestEnv.Reset()
    TestEnv.InstallWowApi()
    local Registry = require("Registry")

    local TimerKit = require("TimerKit")

    assert.is_nil(Registry:Find("lifecycleKit", 1))
    assert.are.equal(TimerKit, Registry:Find("timerKit", 1))
    local timer = TimerKit:ForAddon("Alone"):After(1, function() end)
    assert.is_true(timer:IsPending())
    assert.is_true(TimerKit:CloseAddonScopes("Alone"))
    assert.is_true(timer:IsCancelled())
  end)

  it("requires Registry API 2", function()
    TestEnv.Reset()
    TestEnv.InstallWowApi()
    local ok, value = pcall(require, "TimerKit")
    assert.is_false(ok)
    assert.is_true(tostring(value):find("Registry API 2", 1, true) ~= nil)
  end)

  it("requires C_Timer NewTimer and NewTicker", function()
    TestEnv.Reset()
    TestEnv.InstallWowApi()
    require("Registry")
    -- The package reads this host global at load time, so the spec has to install it in the global table.
    -- selene: allow(global_usage)
    rawset(_G, "C_Timer", {})

    local ok, value = pcall(require, "TimerKit")
    assert.is_false(ok)
    assert.is_true(tostring(value):find("C_Timer.NewTimer", 1, true) ~= nil)
  end)
end)
