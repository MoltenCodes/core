--- Windows: a WidgetKit window against an AceGUI-3.0 Frame, on real frames.
---
--- The host's widget rows are indicative: a fake frame's `SetPoint` is a Lua
--- table write and nothing is drawn. Here both toolkits build the same window
--- on the client's frames: a 400 × 500 window titled like a dialog, holding a
--- heading, 20 full-width labels, a button, a check box, a slider and an edit
--- box, laid out as a list once (layout paused while filling, then one pass),
--- shown, and released with its children.
---
--- - `open-close` is the Lua side of that, timed as a batch: every native call
---   the toolkit makes is inside the time, the drawing is not (a window opened
---   and released in one frame is never drawn).
--- - `open-close-drawn` spreads the same cycle over frames: open, let the
---   client draw the window once, close, then two frames without it. The
---   frame after an open includes the first draw of the window; the idle
---   frames are the same session's baseline.
---
--- AceConfigDialog-3.0 is not compared: its files are not in the pinned,
--- checksummed set the benchmark installs (`tooling/bench/ace3.py`).

local Adapters = require("clientWorkloads.Adapters")
local FrameStats = require("clientWorkloads.FrameStats")

local Window = {}

--- Open-and-close cycles per timed batch.
local CYCLE_ITERATIONS = 100

--- Open-draw-close cycles of the frame case.
local DRAWN_CYCLES = 60

---Build the workload for one side.
---@param side string `"moltencodes"` or `"ace3"`
---@param host table the client host
---@return table suite `{ cases, checks, libraries }`
function Window.Build(side, host)
  local adapter = Adapters.New(side, host)
  local windows = adapter.Windows()
  local title = "MoltenCodes Bench window"

  local cases = {
    {
      name = "open-close",
      iterations = CYCLE_ITERATIONS,
      operation = "build, lay out and show a window of "
        .. Adapters.WINDOW_CHILDREN
        .. " widgets, then release it",
      prepare = function()
        return {
          run = function(iterations)
            for _ = 1, iterations do
              windows.close(windows.open(title))
            end
          end,
        }
      end,
    },
    {
      name = "open-close-drawn",
      kind = "frames",
      operation = "open the same window, let the client draw it once, close it; "
        .. DRAWN_CYCLES
        .. " cycles",
      prepare = function()
        local openLua = FrameStats.NewSeries()
        local closeLua = FrameStats.NewSeries()
        local drawnFrames = FrameStats.NewSeries()
        local idleFrames = FrameStats.NewSeries()
        local clock = host.Global("debugprofilestop")
        local cycle, step, handle = 0, 0, nil
        local previous = nil
        return {
          maximumSeconds = 120,
          frame = function(seconds)
            -- The first frame has no previous one; it only opens a window.
            local frameMilliseconds = (seconds - (previous or seconds)) * 1000
            previous = seconds
            step = step + 1
            if step == 1 then
              local started = clock()
              handle = windows.open(title)
              openLua.Add(clock() - started)
            elseif step == 2 then
              drawnFrames.Add(frameMilliseconds)
              local started = clock()
              windows.close(handle)
              closeLua.Add(clock() - started)
              handle = nil
            elseif step == 3 then
              -- The frame after the close: the window's last draw is gone.
              return false
            else
              idleFrames.Add(frameMilliseconds)
              step = 0
              cycle = cycle + 1
              return cycle >= DRAWN_CYCLES
            end
            return false
          end,
          finish = function()
            if handle ~= nil then
              windows.close(handle)
            end
            return {
              cycles = cycle,
              openLuaMillisecondsP50 = openLua.Percentile(50),
              closeLuaMillisecondsP50 = closeLua.Percentile(50),
              drawnFrameMillisecondsP50 = drawnFrames.Percentile(50),
              drawnFrameMillisecondsP95 = drawnFrames.Percentile(95),
              idleFrameMillisecondsP50 = idleFrames.Percentile(50),
              idleFrameMillisecondsP95 = idleFrames.Percentile(95),
            }
          end,
        }
      end,
    },
  }

  local function checks()
    local handle = windows.open(title)
    local children, shown = windows.childCount(handle), windows.isShown(handle)
    windows.close(handle)
    return {
      {
        name = "window-holds-every-child",
        passed = children == Adapters.WINDOW_CHILDREN and shown,
        detail = "children: " .. children .. ", shown: " .. tostring(shown),
        promised = true,
      },
    }
  end

  return { libraries = adapter.Libraries(), cases = cases, checks = checks }
end

return Window
