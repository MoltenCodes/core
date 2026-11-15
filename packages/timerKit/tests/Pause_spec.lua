local TestEnv = require("TimerKitTestEnv")

-- The fixture's `GetTimePreciseSec` reads the wall clock `AdvanceMs` moves, so
-- every remainder below is exact.
local function noop() end

describe("TimerKit pausing", function()
  local TimerKit
  before_each(function()
    TimerKit = TestEnv.NewPackage()
  end)
  after_each(TestEnv.Reset)

  it("pauses a one-shot, keeps its remainder, and resumes it for that remainder", function()
    local fired = 0
    local timer = TimerKit:After(2, function()
      fired = fired + 1
    end)
    TestEnv.AdvanceMs(500)

    assert.is_true(timer:Pause())
    assert.is_true(TestEnv.NativeTimers()[1].cancelled)
    assert.are.equal("paused", timer:GetState())
    assert.is_true(timer:IsPaused())
    assert.is_false(timer:IsPending())
    assert.are.equal(1.5, timer:GetRemaining())
    assert.is_nil(timer:GetDeadline())

    TestEnv.AdvanceMs(10000)
    assert.are.equal(1.5, timer:GetRemaining())
    assert.is_true(timer:Resume())
    assert.are.equal(1.5, TestEnv.NativeTimers()[2].seconds)
    assert.is_false(TestEnv.NativeTimers()[2].repeating)
    assert.are.equal("running", timer:GetState())
    assert.are.equal(12, timer:GetDeadline())

    TestEnv.AdvanceMs(1500)
    TestEnv.FireNative(2)
    assert.are.equal(1, fired)
    assert.are.equal("completed", timer:GetState())
    assert.are.equal(0, timer:GetScope():GetActiveCount())
  end)

  it("resumes a repeating timer for its remainder, then on its interval", function()
    local fired = 0
    local ticker = TimerKit:Every(2, function()
      fired = fired + 1
    end)
    TestEnv.AdvanceMs(1500)
    ticker:Pause()
    assert.are.equal(0.5, ticker:GetRemaining())
    ticker:Resume()
    assert.is_false(TestEnv.NativeTimers()[2].repeating)

    TestEnv.AdvanceMs(500)
    TestEnv.FireNative(2)
    assert.are.equal(1, fired)
    local tickerNative = TestEnv.NativeTimers()[3]
    assert.is_true(tickerNative.repeating)
    assert.are.equal(2, tickerNative.seconds)
    assert.are.equal(2, ticker:GetRemaining())
    assert.is_true(ticker:IsPending())

    TestEnv.FireNative(3)
    TestEnv.FireNative(3)
    assert.are.equal(3, fired)
    assert.are.equal(1, ticker:GetScope():GetActiveCount())
  end)

  it("cancels the new ticker when the first callback after a resume cancels its timer", function()
    local ticker
    ticker = TimerKit:Every(1, function()
      ticker:Cancel()
    end)
    ticker:Pause()
    ticker:Resume()
    TestEnv.FireNative(2)
    assert.is_true(ticker:IsCancelled())
    assert.is_true(TestEnv.NativeTimers()[3].cancelled)
  end)

  it(
    "leaves a repeating timer cancelled when the host refuses the ticker after a resume",
    function()
      local ticker = TimerKit:Every(1, noop)
      ticker:Pause()
      ticker:Resume()
      TestEnv.FailNextTimerCreate("no ticker")
      local ok, value = pcall(TestEnv.FireNative, 2)
      assert.is_false(ok)
      assert.are.equal("no ticker", value)
      assert.is_true(ticker:IsCancelled())
      assert.are.equal(0, ticker:GetScope():GetActiveCount())
    end
  )

  it("ignores a stale callback of the paused handle and of a pause before a resume", function()
    local fired = 0
    local timer = TimerKit:After(1, function()
      fired = fired + 1
    end)
    timer:Pause()
    TestEnv.InvokeRaw(1)
    assert.are.equal(0, fired)
    timer:Resume()
    timer:Pause()
    TestEnv.InvokeRaw(2)
    assert.are.equal(0, fired)
    assert.is_true(timer:IsPaused())
  end)

  it(
    "keeps a paused timer counted, and lets Cancel, Restart, CancelAll and Close end it",
    function()
      local scope = TimerKit:CreateScope()
      local first = scope:After(1, noop)
      local second = scope:After(1, noop)
      local third = scope:After(1, noop)
      first:Pause()
      second:Pause()
      third:Pause()
      assert.are.equal(3, scope:GetActiveCount())

      assert.is_true(first:Cancel())
      assert.is_true(first:IsCancelled())
      assert.is_nil(first:GetRemaining())

      TestEnv.AdvanceMs(500)
      assert.is_true(second:Restart())
      assert.are.equal(1, second:GetRemaining())
      assert.are.equal("running", second:GetState())

      assert.are.equal(2, scope:CancelAll())
      assert.is_true(third:IsCancelled())

      local fourth = scope:After(1, noop)
      fourth:Pause()
      assert.is_true(scope:Close())
      assert.is_true(fourth:IsCancelled())
      assert.is_false(fourth:Resume())
    end
  )

  it("answers false where there is nothing to pause, resume or start", function()
    local timer = TimerKit:New({ delay = 1, callback = noop })
    assert.is_false(timer:Pause())
    assert.is_false(timer:Resume())
    assert.is_false(timer:IsPaused())
    timer:Start()
    assert.is_false(timer:Resume())
    timer:Pause()
    assert.is_false(timer:Pause())
    assert.is_false(timer:Start())
    assert.are.equal(1, #TestEnv.NativeTimers())
  end)

  it("keeps a remainder of zero for a timer the host is late to deliver", function()
    local timer = TimerKit:After(1, noop)
    TestEnv.AdvanceMs(1500)
    timer:Pause()
    assert.are.equal(0, timer:GetRemaining())
  end)

  it("leaves a paused timer paused when the host refuses the resume", function()
    local timer = TimerKit:After(1, noop)
    timer:Pause()
    TestEnv.FailNextTimerCreate("no timer")
    local ok, value = pcall(timer.Resume, timer)
    assert.is_false(ok)
    assert.are.equal("no timer", value)
    assert.is_true(timer:IsPaused())
    TestEnv.ReturnNextNative(false)
    TestEnv.expectErrorContaining("host returned an invalid native timer handle", function()
      timer:Resume()
    end)
    assert.is_true(timer:IsPaused())
  end)

  it("points receiver errors at the caller", function()
    local timer = TimerKit:After(1, noop)
    for _, method in ipairs({ "Pause", "Resume", "IsPaused" }) do
      local ok, value = pcall(timer[method], {})
      assert.is_false(ok)
      assert.is_truthy(
        tostring(value):find(
          "TimerKit.Timer:" .. method .. " must be called on a TimerKit timer",
          1,
          true
        )
      )
    end
  end)

  it("keeps the full delay without a clock", function()
    TestEnv.Reset()
    TestEnv.InstallWowApi()
    require("Registry")
    -- The package reads this host global at load time, so the spec has to remove it from the global table.
    -- selene: allow(global_usage)
    rawset(_G, "GetTimePreciseSec", nil)
    local clockless = require("TimerKit")
    local timer = clockless:After(3, noop)
    timer:Pause()
    assert.are.equal(3, timer:GetRemaining())
    timer:Resume()
    assert.are.equal(3, TestEnv.NativeTimers()[2].seconds)
    assert.is_nil(timer:GetDeadline())
  end)

  it(
    "upgrades in place from revision 11: timers keep running and pause under the new code",
    function()
      TestEnv.Reset()
      TestEnv.InstallWowApi()
      require("Registry")
      local old = TestEnv.LoadRevision(11)
      local fired = 0
      local timer = old:After(2, function()
        fired = fired + 1
      end)
      local upgraded = require("TimerKit")
      assert.are.equal(old, upgraded)
      assert.is_true(upgraded.REVISION > 11)
      TestEnv.AdvanceMs(1000)
      assert.is_true(timer:Pause())
      assert.is_true(timer:Resume())
      TestEnv.FireNative(2)
      assert.are.equal(1, fired)
    end
  )
end)
