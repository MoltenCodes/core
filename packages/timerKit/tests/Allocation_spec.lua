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
end)
