--- Timers on a simulated clock: TimerKit against AceTimer-3.0.
---
--- Both libraries schedule on the same simulated `C_Timer`
--- (`SimulatedTimers.lua`) and the clock moves only when a case advances it,
--- so a timer fires exactly when the case says and no case waits in real time.
---
--- The two libraries use the host differently, and that difference is part of
--- what is measured: TimerKit starts one `C_Timer.NewTimer` / `NewTicker` per
--- timer and cancels the native timer with it, while AceTimer schedules every
--- one-shot and every repeat with `C_Timer.After`, which cannot be cancelled,
--- so a cancelled AceTimer timer stays queued on the host until it falls due
--- and is then ignored. The `pending` metrics make that visible.
---
--- The `host-stub-*` cases measure the simulated `C_Timer` alone, driven in
--- each library's style with an empty callback, so a reader can see how much
--- of the matching library case is the stub rather than the library.

local Bench = require("Bench")

local Timers = {}

--- One-shot operations per timed batch.
local ONE_SHOT_ITERATIONS = 20000

--- Repeating timers alive during `repeat-tick`, and clock advances per batch.
local REPEATING_TIMERS = 100
local TICK_ADVANCES = 500

--- Timers created before measuring what a cancelled timer leaves behind.
local PENDING_PROBE = 1000

local function noop() end

---@param host table
---@return table adapter, table[] libraries
local function kitAdapter(host)
  local loaded = host.RequireAll({ "Registry", "TimerKit" })
  local TimerKit = loaded[2]
  local scope = TimerKit:CreateScope()
  local adapter = {}

  function adapter.after(delay, callback)
    return scope:After(delay, callback)
  end

  function adapter.every(interval, callback)
    return scope:Every(interval, callback)
  end

  function adapter.cancel(timer)
    timer:Cancel()
  end

  function adapter.activeCount()
    return scope:GetActiveCount()
  end

  ---Drive the stub the way TimerKit starts and cancels a one-shot.
  function adapter.stubOneShot(delay)
    host.Global("C_Timer").NewTimer(delay, noop):Cancel()
  end

  ---Drive the stub the way TimerKit does: one native ticker per timer.
  function adapter.stubRepeat(interval)
    host.Global("C_Timer").NewTicker(interval, noop)
  end

  return adapter, { { name = "TimerKit", revision = TimerKit.REVISION } }
end

---@param host table
---@param directory string the Ace3 checkout
---@return table adapter, table[] libraries
local function aceAdapter(host, directory)
  host.LoadFiles(directory, { "LibStub/LibStub.lua", "AceTimer-3.0/AceTimer-3.0.lua" })
  local LibStub = host.Global("LibStub")
  local AceTimer, minor = LibStub:GetLibrary("AceTimer-3.0")
  local owner = AceTimer:Embed({})
  local adapter = {}

  function adapter.after(delay, callback)
    return owner:ScheduleTimer(callback, delay)
  end

  function adapter.every(interval, callback)
    return owner:ScheduleRepeatingTimer(callback, interval)
  end

  function adapter.cancel(timer)
    owner:CancelTimer(timer)
  end

  function adapter.activeCount()
    local count = 0
    for _ in pairs(AceTimer.activeTimers) do
      count = count + 1
    end
    return count
  end

  ---Drive the stub the way AceTimer starts a one-shot; it cannot cancel it.
  function adapter.stubOneShot(delay)
    host.Global("C_Timer").After(delay, noop)
  end

  ---Drive the stub the way AceTimer does: `C_Timer.After`, re-armed from the
  ---callback on every tick.
  function adapter.stubRepeat(interval)
    local after = host.Global("C_Timer").After
    local function tick()
      after(interval, tick)
    end
    after(interval, tick)
  end

  return adapter, { { name = "AceTimer-3.0", minor = minor } }
end

---@param adapter table
---@param host table
---@return Bench.Case[]
local function cases(adapter, host)
  local timers = host.timers

  ---Let every outstanding one-shot fall due, outside any measurement.
  local function drain()
    timers.Advance(3600)
  end

  return {
    {
      name = "oneshot-create-cancel",
      iterations = ONE_SHOT_ITERATIONS,
      operation = "start a 10 s one-shot timer and cancel it",
      prepare = function()
        return {
          run = function(iterations)
            for _ = 1, iterations do
              adapter.cancel(adapter.after(10, noop))
            end
          end,
          afterBatch = drain,
          -- What cancelled timers leave behind until they would have fired.
          metrics = function()
            drain()
            local baseline = Bench.RetainedBytes()
            local started = {}
            for index = 1, PENDING_PROBE do
              started[index] = adapter.after(10, noop)
            end
            for index = 1, PENDING_PROBE do
              adapter.cancel(started[index])
            end
            started = nil
            timers.Advance(0)
            local retained = Bench.RetainedBytes() - baseline
            local pendingHostTimers = timers.PendingCount()
            local libraryActive = adapter.activeCount()
            drain()
            return {
              cancelledTimers = PENDING_PROBE,
              pendingHostTimersAfterCancel = pendingHostTimers,
              libraryActiveAfterCancel = libraryActive,
              retainedBytesPerCancelledTimer = retained / PENDING_PROBE,
            }
          end,
        }
      end,
    },
    {
      name = "oneshot-create-fire",
      iterations = ONE_SHOT_ITERATIONS,
      operation = "start a 1 s one-shot timer and let it fire",
      prepare = function()
        local fired, started = 0, 0
        local function callback()
          fired = fired + 1
        end
        return {
          run = function(iterations)
            for _ = 1, iterations do
              adapter.after(1, callback)
            end
            timers.Advance(1)
            started = started + iterations
          end,
          metrics = function()
            return { pendingHostTimers = timers.PendingCount(), firedPerStarted = fired / started }
          end,
        }
      end,
    },
    {
      name = "repeat-tick",
      iterations = REPEATING_TIMERS * TICK_ADVANCES,
      operation = "deliver one tick of a 1 s repeating timer (100 running)",
      prepare = function()
        local ticks = 0
        local function callback()
          ticks = ticks + 1
        end
        for _ = 1, REPEATING_TIMERS do
          adapter.every(1, callback)
        end
        local delivered = 0
        return {
          run = function(iterations)
            for _ = 1, iterations / REPEATING_TIMERS do
              timers.Advance(1)
            end
            delivered = delivered + iterations
          end,
          metrics = function()
            return { ticksPerExpectedTick = ticks / delivered }
          end,
        }
      end,
    },
    {
      name = "host-stub-oneshot-create-cancel",
      iterations = ONE_SHOT_ITERATIONS,
      operation = "the simulated C_Timer alone, one one-shot start and cancel in this library's style",
      equivalent = false,
      note = "host stub cost, not a library cost: NewTimer and Cancel (TimerKit) or After (AceTimer)",
      prepare = function()
        return {
          run = function(iterations)
            for _ = 1, iterations do
              adapter.stubOneShot(10)
            end
          end,
          afterBatch = drain,
        }
      end,
    },
    {
      name = "host-stub-repeat-tick",
      iterations = REPEATING_TIMERS * TICK_ADVANCES,
      operation = "the simulated C_Timer alone, one tick in this library's style",
      equivalent = false,
      note = "host stub cost, not a library cost: After re-armed per tick (AceTimer) or one ticker (TimerKit)",
      prepare = function()
        for _ = 1, REPEATING_TIMERS do
          adapter.stubRepeat(1)
        end
        return {
          run = function(iterations)
            for _ = 1, iterations / REPEATING_TIMERS do
              timers.Advance(1)
            end
          end,
        }
      end,
    },
  }
end

---Build the workload for one side.
---@param side string `"moltencodes"` or `"ace3"`
---@param host table
---@param settings table
---@return table suite `{ cases, checks, libraries }`
function Timers.Build(side, host, settings)
  local adapter, libraries
  if side == "moltencodes" then
    adapter, libraries = kitAdapter(host)
  else
    adapter, libraries = aceAdapter(host, settings.ace3)
  end

  local function checks()
    local timers = host.timers
    local results = {}

    local fired = 0
    local cancelled = adapter.after(5, function()
      fired = fired + 1
    end)
    adapter.cancel(cancelled)
    timers.Advance(10)
    results[#results + 1] = {
      name = "cancelled-oneshot-never-fires",
      passed = fired == 0,
      detail = "calls after cancel and 10 s: " .. fired,
      promised = true,
    }

    local ticks = 0
    local repeating
    repeating = adapter.every(1, function()
      ticks = ticks + 1
      if ticks == 3 then
        adapter.cancel(repeating)
      end
    end)
    for _ = 1, 6 do
      timers.Advance(1)
    end
    results[#results + 1] = {
      name = "repeat-cancel-from-callback",
      passed = ticks == 3,
      detail = "ticks of a repeating timer cancelled in its third tick, after 6 s: " .. ticks,
      promised = true,
    }

    local order = {}
    adapter.after(2, function()
      order[#order + 1] = "two"
    end)
    adapter.after(1, function()
      order[#order + 1] = "one"
    end)
    timers.Advance(1)
    timers.Advance(1)
    results[#results + 1] = {
      name = "fires-in-deadline-order",
      passed = order[1] == "one" and order[2] == "two",
      detail = "order: " .. table.concat(order, ", "),
      promised = true,
    }

    timers.Advance(3600)
    results[#results + 1] = {
      name = "nothing-pending-when-idle",
      passed = timers.PendingCount() == 0 and adapter.activeCount() == 0,
      detail = "host timers pending: "
        .. timers.PendingCount()
        .. ", library active: "
        .. adapter.activeCount(),
      promised = true,
    }
    return results
  end

  return { libraries = libraries, cases = cases(adapter, host), checks = checks }
end

return Timers
