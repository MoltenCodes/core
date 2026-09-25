--- Frame time and memory over a session, with the same synthetic load on each side.
---
--- What a player notices is not the cost of one call but hitches and a
--- growing heap. This workload runs a load shaped like a busy addon, the same
--- work on both sides through `Adapters`, and records what the frame loop and
--- the heap do meanwhile:
---
--- - listeners: 10 on each of 10 events that fire often in any session
---   (auras, power, health, cooldowns, the cursor, the mouse-over unit, UI
---   widgets), 100 in all;
--- - messages: a message bus with 20 subscribers, published 10 times every
---   frame with two payload values;
--- - timers: 50 repeating timers of 0.1 s;
--- - a settings panel: an open window of 25 widgets whose label text changes
---   every frame;
--- - a comm stream: a 200-byte whisper to the player every 2 s.
---
--- The cases, each in its own session like every case:
---
--- - `idle-30s`: the side loaded, nothing running: the session's baseline.
--- - `load-60s`: the load for 60 s. Frame times (p50, p95, p99) against
---   `idle-30s` show what the load costs a player; the Lua time the per-frame
---   work took is reported apart.
--- - `memory-300s`: the load for five minutes, sampling the Lua heap every
---   second and the side addon's memory every 10 s (`UpdateAddOnMemoryUsage`,
---   which walks the whole heap and so disturbs the frame it runs in; this
---   case's frame times are not comparable with `load-60s`). It reports
---   growth per minute, collection cycles, and what stayed after a full
---   collection at the end against one at the start.

local Adapters = require("clientWorkloads.Adapters")
local ClientBench = require("ClientBench")
local FrameStats = require("clientWorkloads.FrameStats")

local Session = {}

--- Events that fire often in any session, on every promised flavour.
local EVENTS = {
  "UNIT_AURA",
  "UNIT_POWER_FREQUENT",
  "UNIT_HEALTH",
  "SPELL_UPDATE_COOLDOWN",
  "ACTIONBAR_UPDATE_COOLDOWN",
  "BAG_UPDATE_COOLDOWN",
  "CURSOR_CHANGED",
  "MODIFIER_STATE_CHANGED",
  "UPDATE_MOUSEOVER_UNIT",
  "UPDATE_UI_WIDGET",
}
local LISTENERS_PER_EVENT = 10
local SUBSCRIBERS = 20
local PUBLISHES_PER_FRAME = 10
local REPEATING_TIMERS, TIMER_INTERVAL = 50, 0.1
local WHISPER_BYTES, WHISPER_INTERVAL = 200, 2

--- Seconds each case runs, and the memory case's sampling intervals.
local IDLE_SECONDS, LOAD_SECONDS, MEMORY_SECONDS = 30, 60, 300
local HEAP_SAMPLE_SECONDS, ADDON_SAMPLE_SECONDS = 1, 10

---Build the load; `Start` sets it up, `Frame` does the per-frame work,
---`Stop` tears it down and returns its counters.
---@param adapter table the side's adapter
---@param host table the client host
---@return table load
local function newLoad(adapter, host)
  local events, messages = adapter.Events(), adapter.Messages()
  local timers, comm, windows = adapter.Timers(), adapter.Comm(), adapter.Windows()
  local unitName = host.Global("UnitName")
  local counters = { events = 0, messages = 0, timerTicks = 0, whispersSent = 0, received = 0 }
  local connections, subscriptions, running = {}, {}, {}
  local window, frameNumber, nextWhisper = nil, 0, 0
  local whisperText = string.rep("W", WHISPER_BYTES - 8)

  local function onEvent()
    counters.events = counters.events + 1
  end
  local function onMessage()
    counters.messages = counters.messages + 1
  end
  local function onTick()
    counters.timerTicks = counters.timerTicks + 1
  end
  comm.register(function()
    counters.received = counters.received + 1
  end)

  local load = {}

  function load.Start()
    for _, eventName in ipairs(EVENTS) do
      for _ = 1, LISTENERS_PER_EVENT do
        connections[#connections + 1] = events.connect(eventName, onEvent)
      end
    end
    for index = 1, SUBSCRIBERS do
      subscriptions[index] = messages.subscribe(onMessage)
    end
    for index = 1, REPEATING_TIMERS do
      running[index] = timers.every(TIMER_INTERVAL, onTick)
    end
    window = windows.open("MoltenCodes Bench settings")
  end

  ---@param seconds number since the case started
  function load.Frame(seconds)
    frameNumber = frameNumber + 1
    for index = 1, PUBLISHES_PER_FRAME do
      messages.publish(frameNumber, index)
    end
    windows.setLabel(
      window,
      frameNumber % Adapters.WINDOW_LABELS + 1,
      "Updated in frame " .. frameNumber
    )
    if seconds >= nextWhisper then
      nextWhisper = seconds + WHISPER_INTERVAL
      counters.whispersSent = counters.whispersSent + 1
      -- The number keeps every whisper a different string, as real traffic is.
      comm.whisper(string.format("%07d:", counters.whispersSent) .. whisperText, unitName("player"))
    end
  end

  ---@return table counters
  function load.Stop()
    for index = 1, #connections do
      events.disconnect(connections[index])
    end
    for index = 1, #running do
      timers.cancel(running[index])
    end
    windows.close(window)
    return {
      listeners = #connections,
      subscribers = #subscriptions,
      eventsDelivered = counters.events,
      messagesDelivered = counters.messages,
      timerTicks = counters.timerTicks,
      whispersSent = counters.whispersSent,
      whispersReceived = counters.received,
    }
  end

  return load
end

---The side addon's and the harness's memory in kilobytes, or `nil`s on a
---client without the calls.
---@param host table
---@return number|nil side, number|nil harness
local function addonMemory(host)
  local update = host.Global("UpdateAddOnMemoryUsage")
  local read = host.Global("GetAddOnMemoryUsage")
  if type(update) ~= "function" or type(read) ~= "function" then
    return nil, nil
  end
  update()
  return read(host.client.sideAddon), read(host.client.harnessAddon)
end

---Collect twice and return the heap in kilobytes.
---@return number
local function collectedHeap()
  collectgarbage("collect")
  collectgarbage("collect")
  return collectgarbage("count")
end

---Build the workload for one side.
---@param side string `"moltencodes"` or `"ace3"`
---@param host table the client host
---@return table suite `{ cases, checks, libraries }`
function Session.Build(side, host)
  local adapter = Adapters.New(side, host)
  if type(host.Global("UnitName")) ~= "function" then
    ClientBench.Unsupported("UnitName, the whisper target")
  end

  local cases = {
    {
      name = "idle-30s",
      kind = "frames",
      operation = "the side loaded and nothing running, " .. IDLE_SECONDS .. " s",
      prepare = function()
        return {
          maximumSeconds = IDLE_SECONDS,
          frame = function()
            return false
          end,
        }
      end,
    },
    {
      name = "load-60s",
      kind = "frames",
      operation = "the synthetic load for " .. LOAD_SECONDS .. " s",
      prepare = function()
        local load = newLoad(adapter, host)
        return {
          maximumSeconds = LOAD_SECONDS,
          start = load.Start,
          frame = function(seconds)
            load.Frame(seconds)
            return false
          end,
          finish = load.Stop,
        }
      end,
    },
    {
      name = "memory-300s",
      kind = "frames",
      operation = "the synthetic load for " .. MEMORY_SECONDS .. " s, sampling memory",
      note = "the side addon's memory is sampled every 10 s with UpdateAddOnMemoryUsage, "
        .. "which disturbs the frame it runs in",
      prepare = function()
        local load = newLoad(adapter, host)
        local heapTimes, heapKilobytes = {}, {}
        local addonTimes, sideKilobytes = {}, {}
        local nextHeapSample, nextAddonSample = 0, 0
        local heapStart, sideStart, harnessStart
        return {
          maximumSeconds = MEMORY_SECONDS,
          start = function()
            heapStart = collectedHeap()
            sideStart, harnessStart = addonMemory(host)
            load.Start()
          end,
          frame = function(seconds)
            load.Frame(seconds)
            if seconds >= nextHeapSample then
              nextHeapSample = nextHeapSample + HEAP_SAMPLE_SECONDS
              heapTimes[#heapTimes + 1] = seconds / 60
              heapKilobytes[#heapKilobytes + 1] = collectgarbage("count")
            end
            if seconds >= nextAddonSample then
              nextAddonSample = nextAddonSample + ADDON_SAMPLE_SECONDS
              local sideNow = addonMemory(host)
              if sideNow ~= nil then
                addonTimes[#addonTimes + 1] = seconds / 60
                sideKilobytes[#sideKilobytes + 1] = sideNow
              end
            end
            return false
          end,
          finish = function()
            local counters = load.Stop()
            local heapEnd = collectedHeap()
            local sideEnd, harnessEnd = addonMemory(host)
            counters.heapGrowthKilobytesPerMinute = FrameStats.Slope(heapTimes, heapKilobytes)
            counters.heapRetainedKilobytesAfterCollect = heapEnd - heapStart
            counters.sideAddonGrowthKilobytesPerMinute = FrameStats.Slope(addonTimes, sideKilobytes)
            counters.sideAddonKilobytesStart = sideStart
            counters.sideAddonKilobytesEnd = sideEnd
            counters.harnessKilobytesStart = harnessStart
            counters.harnessKilobytesEnd = harnessEnd
            counters.heapSamples = #heapKilobytes
            return counters
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

return Session
