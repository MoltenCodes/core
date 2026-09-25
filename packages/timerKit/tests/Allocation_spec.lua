local TestEnv = require("TimerKitTestEnv")

-- Each workload repeats its operation many times, so a single allocation per
-- call would show up as tens of kilobytes. The threshold leaves room for the
-- few bytes the measurement itself can cost.
local ITERATIONS = 2000
local THRESHOLD_KILOBYTES = 1

local function noop() end

describe("TimerKit allocation #allocation", function()
  local TimerKit
  before_each(function()
    TimerKit = TestEnv.NewPackage()
  end)
  after_each(TestEnv.Reset)

  it("allocates nothing to deliver a repeating tick", function()
    local ticker = TimerKit:Every(1, noop)

    -- Call the native ticker's callback the way the host does. The
    -- fixture's `FireNative` checks its argument with luassert, which
    -- allocates on every call and would drown the measurement.
    local native = TestEnv.NativeTimers()[1]
    local tick = native.callback
    tick(native)

    local allocated = TestEnv.AllocatedKilobytes(function()
      for _ = 1, ITERATIONS do
        tick(native)
      end
    end)
    assert.is_true(allocated < THRESHOLD_KILOBYTES, "tick allocated " .. allocated .. " KiB")
    assert.is_true(ticker:IsPending())
  end)

  it("allocates nothing to cancel a running timer", function()
    -- Starting a timer allocates the host handle and its callback, so the
    -- timers are started before the measurement and only cancelled in it.
    local timers = {}
    for index = 1, ITERATIONS do
      timers[index] = TimerKit:After(1, noop)
    end

    local allocated = TestEnv.AllocatedKilobytes(function()
      for index = 1, ITERATIONS do
        timers[index]:Cancel()
      end
    end)
    assert.is_true(allocated < THRESHOLD_KILOBYTES, "Cancel allocated " .. allocated .. " KiB")
    assert.is_true(timers[ITERATIONS]:IsCancelled())
  end)

  it("allocates nothing to attach user data to one-shot and repeating timers", function()
    -- A one-shot timer is built with eight fields and a repeating one with
    -- nine; both leave room for `_userData`, so attaching it never rehashes.
    local oneShots, tickers = {}, {}
    for index = 1, ITERATIONS do
      oneShots[index] = TimerKit:New({ delay = 1, callback = noop })
      tickers[index] = TimerKit:New({ delay = 1, callback = noop, repeating = true })
    end
    local payload = {}

    local allocated = TestEnv.AllocatedKilobytes(function()
      for index = 1, ITERATIONS do
        oneShots[index]:SetUserData(payload)
        tickers[index]:SetUserData(payload)
      end
    end)
    assert.is_true(allocated < THRESHOLD_KILOBYTES, "SetUserData allocated " .. allocated .. " KiB")
    assert.are.equal(payload, oneShots[ITERATIONS]:GetUserData())
  end)

  it("allocates only the timer and its callback to start a one-shot", function()
    -- What the host's own handle costs is measured apart and taken off, so
    -- the figure is TimerKit's: the eight-field timer table (384 bytes on a
    -- 64-bit Lua 5.1) and one callback closure with two upvalues.
    -- selene: allow(global_usage)
    local newTimer = rawget(_G, "C_Timer").NewTimer
    local function hostOnly()
      for _ = 1, ITERATIONS do
        newTimer(1, noop):Cancel()
      end
    end
    local function withTimerKit()
      for _ = 1, ITERATIONS do
        TimerKit:After(1, noop):Cancel()
      end
    end
    -- The fixture records every native it creates. Emptying the record
    -- before each run keeps its array at the size the warm-up gave it, so
    -- neither measurement pays for growing it.
    local natives = TestEnv.NativeTimers()
    local function forgetNatives()
      for index = #natives, 1, -1 do
        natives[index] = nil
      end
    end
    hostOnly()
    withTimerKit()

    forgetNatives()
    local host = TestEnv.AllocatedKilobytes(hostOnly)
    forgetNatives()
    local total = TestEnv.AllocatedKilobytes(withTimerKit)
    local bytesPerTimer = (total - host) * 1024 / ITERATIONS
    assert.is_true(bytesPerTimer > 0, "After allocated nothing, so the measurement is broken")
    assert.is_true(bytesPerTimer <= 560, "After allocated " .. bytesPerTimer .. " bytes per timer")
  end)
end)
