--- Timers on the client's own clock: TimerKit against AceTimer-3.0.
---
--- The host's timer rows advance a simulated clock inside one batch. In the
--- client time passes only between frames, so the cases that need time become
--- frame-driven and report what a player's session pays:
---
--- - `oneshot-create-cancel` (a batch, as on the host): start a one-shot and
---   cancel it. The delay is ten minutes, so no cancelled timer's native
---   callback can come due before the harness reloads.
--- - `oneshot-fire-1000`: start 1,000 one-shots of 0.2 s in one frame, then
---   wait until every one fired. It reports the Lua time of the starting frame,
---   how late each callback ran against its due time, and the frames the
---   firing took; the frame times include the client running the callbacks.
--- - `repeat-200`: 200 repeating timers of 0.1 s for 10 s: the ticks delivered
---   against the ticks due, and the frame times while they run.
---
--- Both libraries sit on `C_Timer`: TimerKit on one native ticker or timer per
--- timer, AceTimer on `C_Timer.After` re-armed on every tick. The host's
--- correctness checks need the simulated clock, so this workload has none.

local Adapters = require("clientWorkloads.Adapters")
local FrameStats = require("clientWorkloads.FrameStats")

local TimersLive = {}

--- Start-and-cancel pairs per timed batch.
local CANCEL_ITERATIONS = 20000

--- A delay no cancelled timer reaches within one benchmark session.
local NEVER_DUE_SECONDS = 600

--- The one-shot burst: how many, and their delay.
local BURST_TIMERS, BURST_DELAY = 1000, 0.2

--- The repeating timers: how many, their interval and how long they run.
local REPEATING_TIMERS, REPEAT_INTERVAL, REPEAT_SECONDS = 200, 0.1, 10

local function noop() end

---Build the workload for one side.
---@param side string `"moltencodes"` or `"ace3"`
---@param host table the client host
---@return table suite `{ cases, checks, libraries }`
function TimersLive.Build(side, host)
  local adapter = Adapters.New(side, host)
  local timers = adapter.Timers()
  local clock = host.Global("debugprofilestop")
  local preciseTime = host.Global("GetTimePreciseSec")

  local cases = {
    {
      name = "oneshot-create-cancel",
      iterations = CANCEL_ITERATIONS,
      operation = "start a 10 min one-shot timer and cancel it",
      prepare = function()
        return {
          run = function(iterations)
            for _ = 1, iterations do
              timers.cancel(timers.after(NEVER_DUE_SECONDS, noop))
            end
          end,
        }
      end,
    },
    {
      name = "oneshot-fire-1000",
      kind = "frames",
      operation = "start "
        .. BURST_TIMERS
        .. " one-shot timers of "
        .. BURST_DELAY
        .. " s in one frame and let them fire",
      prepare = function()
        local lateness = FrameStats.NewSeries()
        local fired, dueAt, startMilliseconds = 0, 0, 0
        local function callback()
          fired = fired + 1
          lateness.Add((preciseTime() - dueAt) * 1000)
        end
        return {
          maximumSeconds = 30,
          start = function()
            local started = clock()
            dueAt = preciseTime() + BURST_DELAY
            for _ = 1, BURST_TIMERS do
              timers.after(BURST_DELAY, callback)
            end
            startMilliseconds = clock() - started
          end,
          frame = function()
            return fired >= BURST_TIMERS
          end,
          finish = function()
            return {
              started = BURST_TIMERS,
              fired = fired,
              startFrameLuaMilliseconds = startMilliseconds,
              latenessMillisecondsP50 = lateness.Percentile(50),
              latenessMillisecondsP95 = lateness.Percentile(95),
              latenessMillisecondsMax = lateness.Maximum(),
            }
          end,
        }
      end,
    },
    {
      name = "repeat-200",
      kind = "frames",
      operation = REPEATING_TIMERS
        .. " repeating timers of "
        .. REPEAT_INTERVAL
        .. " s running for "
        .. REPEAT_SECONDS
        .. " s",
      prepare = function()
        local ticks, running = 0, {}
        local function callback()
          ticks = ticks + 1
        end
        return {
          maximumSeconds = REPEAT_SECONDS,
          start = function()
            for index = 1, REPEATING_TIMERS do
              running[index] = timers.every(REPEAT_INTERVAL, callback)
            end
          end,
          frame = function()
            return false
          end,
          finish = function()
            local started = clock()
            for index = 1, #running do
              timers.cancel(running[index])
            end
            local cancelMilliseconds = clock() - started
            local due = REPEATING_TIMERS * math.floor(REPEAT_SECONDS / REPEAT_INTERVAL)
            return {
              ticks = ticks,
              ticksDue = due,
              ticksDeliveredShare = ticks / due,
              cancelAllLuaMilliseconds = cancelMilliseconds,
            }
          end,
        }
      end,
    },
  }

  return {
    libraries = adapter.Libraries(),
    cases = cases,
    checks = function()
      return {}
    end,
  }
end

return TimersLive
