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

    -- The working revision names a table option field by its type.
    local ran = false
    local key = setmetatable({}, {
      __tostring = function()
        ran = true
        return "custom"
      end,
    })
    local ok, message =
      pcall(timers.New, timers, { delay = 1, callback = function() end, [key] = true })
    assert.is_false(ok)
    local expected = 'options contains unknown field "<table>"'
    assert.is_truthy(string.find(message, expected, 1, true))
    assert.is_false(ran)
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

  it("refuses to upgrade a revision older than 14 in place, naming the floor", function()
    TestEnv.Reset()
    TestEnv.InstallWowApi()
    require("Registry")
    TestEnv.LoadRevision(13)
    package.loaded["TimerKit"] = nil

    local ok, message = pcall(require, "TimerKit")

    assert.is_false(ok)
    assert.is_truthy(
      tostring(message):find("upgrades in place from revision 14 or later only", 1, true)
    )
    assert.is_truthy(tostring(message):find("revision 13", 1, true))
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
