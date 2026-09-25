--- A simulated clock and `C_Timer` that both benchmark sides schedule on.
---
--- The shared fake client's `C_Timer` (`tests/support/framework/TimerStub.lua`)
--- records timers for a spec to fire by hand and has no `After`, which
--- AceTimer-3.0 needs. The benchmark therefore installs this replacement on
--- top of the fake client, for both sides alike:
---
---   `GetTime`, `GetTimePreciseSec`   the simulated clock, in seconds
---   `C_Timer.After(delay, callback)` a one-shot entry without a handle
---   `C_Timer.NewTimer(delay, cb)`    a one-shot entry with a cancellable handle
---   `C_Timer.NewTicker(interval, cb)` a repeating entry with a handle
---
--- Time moves only when a workload calls `Advance`, which fires every entry
--- that fell due, in insertion order. A repeating entry fires at most once
--- per `Advance` and is re-armed one interval later, like the client's ticker.
---
--- Fairness: in the client these calls are native code whose bookkeeping is
--- not on the Lua heap. Here they are Lua, so each side also pays for this
--- stub. The stub is kept as cheap as it can be and equally cheap for both
--- kinds of use: the queue is three parallel arrays (no table per entry), a
--- handle is one table (the client also creates an object per `NewTimer`), and
--- `Advance` is one linear pass. `docs/BENCHMARKS.md` reports the stub's own
--- cost per call so a reader can see how much of a timer row it is.

local SimulatedTimers = {}

---@class SimulatedTimers.Handle
---@field cancelled boolean
---@field repeating boolean
---@field interval number

--- Methods every handle shares, as the client's timer objects do.
local HandleMethods = {}
local HandleMetatable = { __index = HandleMethods }

---Cancel the timer; the queue drops it on its next pass.
function HandleMethods:Cancel()
  self.cancelled = true
end

---@return boolean
function HandleMethods:IsCancelled()
  return self.cancelled
end

---Build a simulated clock and timer queue.
---@return table timers
function SimulatedTimers.New()
  local timers = { now = 0 }

  -- The queue: parallel arrays, `count` entries long. `handles[i]` is the
  -- entry's handle, or `false` for an `After` entry, which has none.
  local dues, callbacks, handles = {}, {}, {}
  local count = 0

  -- The entries one `Advance` fires, collected before any callback runs so a
  -- callback that schedules or cancels cannot disturb the pass. Reused.
  local firingCallbacks, firingHandles = {}, {}

  ---@param due number
  ---@param callback function
  ---@param handle SimulatedTimers.Handle|false
  local function append(due, callback, handle)
    count = count + 1
    dues[count] = due
    callbacks[count] = callback
    handles[count] = handle
  end

  ---@param delay number
  ---@param callback function
  ---@param repeating boolean
  ---@return SimulatedTimers.Handle
  local function newHandle(delay, callback, repeating)
    local handle = setmetatable({
      cancelled = false,
      repeating = repeating,
      interval = delay,
    }, HandleMetatable)
    append(timers.now + delay, callback, handle)
    return handle
  end

  ---The simulated clock.
  ---@return number seconds
  function timers.Now()
    return timers.now
  end

  ---Entries still waiting to fire, cancelled ones excluded.
  ---@return integer
  function timers.PendingCount()
    local pending = 0
    for index = 1, count do
      local handle = handles[index]
      if handle == false or not handle.cancelled then
        pending = pending + 1
      end
    end
    return pending
  end

  ---Move the clock forward by `seconds` and fire every entry that fell due.
  ---@param seconds number
  function timers.Advance(seconds)
    timers.now = timers.now + seconds
    local now = timers.now

    local kept, firing = 0, 0
    for index = 1, count do
      local due, callback, handle = dues[index], callbacks[index], handles[index]
      local cancelled = handle ~= false and handle.cancelled
      if not cancelled and due <= now then
        firing = firing + 1
        firingCallbacks[firing] = callback
        firingHandles[firing] = handle
      end
      if not cancelled and (due > now or (handle ~= false and handle.repeating)) then
        kept = kept + 1
        dues[kept] = due > now and due or due + handle.interval
        callbacks[kept] = callback
        handles[kept] = handle
      end
    end
    for index = kept + 1, count do
      dues[index], callbacks[index], handles[index] = nil, nil, nil
    end
    count = kept

    for index = 1, firing do
      local callback, handle = firingCallbacks[index], firingHandles[index]
      firingCallbacks[index], firingHandles[index] = nil, nil
      -- An earlier callback of this pass may have cancelled this one.
      if handle == false then
        callback()
      elseif not handle.cancelled then
        callback(handle)
      end
    end
  end

  ---Install the clock and `C_Timer` as host globals.
  function timers.Install()
    local function now()
      return timers.now
    end
    -- The benchmark stands in for the World of Warcraft client, whose API only exists in the global table.
    -- selene: allow(global_usage)
    rawset(_G, "GetTime", now)
    -- The benchmark stands in for the World of Warcraft client, whose API only exists in the global table.
    -- selene: allow(global_usage)
    rawset(_G, "GetTimePreciseSec", now)
    -- The benchmark stands in for the World of Warcraft client, whose API only exists in the global table.
    -- selene: allow(global_usage)
    rawset(_G, "C_Timer", {
      After = function(delay, callback)
        append(timers.now + (delay > 0 and delay or 0), callback, false)
      end,
      NewTimer = function(delay, callback)
        return newHandle(delay, callback, false)
      end,
      NewTicker = function(interval, callback)
        return newHandle(interval, callback, true)
      end,
    })
  end

  return timers
end

return SimulatedTimers
