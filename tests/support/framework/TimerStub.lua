--- The fake `C_Timer`, and the handles a spec fires, cancels and breaks.
---
--- The host's timers are opaque objects with `Cancel`/`IsCancelled`, created by
--- `C_Timer.NewTimer` and `C_Timer.NewTicker`. This stub reproduces that shape
--- and adds the three host failures a package has to survive: a constructor
--- that raises, a `Cancel` that raises, and a constructor that returns
--- something other than a timer.

local TimerStub = {}

local assert = require("luassert")

---Build one native timer and record it in creation order.
---@param state table shared stub state
---@param seconds number
---@param callback fun(native: table)
---@param repeating boolean whether the host would re-arm it
---@return any native the stub timer, or whatever an override supplied
local function newNativeTimer(state, seconds, callback, repeating)
  if state.nextNativeOverride ~= nil then
    local value = state.nextNativeOverride
    state.nextNativeOverride = nil
    return value
  end

  if state.failNextTimerCreate ~= nil then
    local value = state.failNextTimerCreate
    state.failNextTimerCreate = nil
    error(value, 0)
  end

  local native = {
    seconds = seconds,
    callback = callback,
    repeating = repeating,
    cancelled = false,
    fired = false,
  }

  function native:Cancel()
    self.cancelled = true
    if state.failNextTimerCancel ~= nil then
      local value = state.failNextTimerCancel
      state.failNextTimerCancel = nil
      error(value, 0)
    end
  end

  function native:IsCancelled()
    return self.cancelled
  end

  state.nativeTimers[#state.nativeTimers + 1] = native
  return native
end

---Return this stub's state fields to their initial values.
---@param state table shared stub state
function TimerStub.Reset(state)
  state.nativeTimers = {}
  state.nextNativeOverride = nil
  state.failNextTimerCreate = nil
  state.failNextTimerCancel = nil
end

---Install the globals this stub owns.
---@param state table shared stub state
function TimerStub.InstallGlobals(state)
  -- The fixture stands in for the World of Warcraft client, whose API and shared namespace only exist in the global table.
  -- selene: allow(global_usage)
  rawset(_G, "C_Timer", {
    NewTimer = function(seconds, callback)
      return newNativeTimer(state, seconds, callback, false)
    end,
    NewTicker = function(seconds, callback)
      return newNativeTimer(state, seconds, callback, true)
    end,
  })
end

---Attach this stub's public helpers to `environment`.
---@param environment table the fixture facade specs call
---@param state table shared stub state
function TimerStub.Attach(environment, state)
  ---@return table[] timers Every native timer created, in creation order.
  function environment.NativeTimers()
    return state.nativeTimers
  end

  ---Fire native timer `index` the way the host would.
  ---@param index integer
  ---@return boolean fired `false` when the timer was cancelled or spent.
  function environment.FireNative(index)
    local native = state.nativeTimers[index]
    assert.is_not_nil(native)
    if native.cancelled then
      return false
    end
    if not native.repeating and native.fired then
      return false
    end
    if not native.repeating then
      native.fired = true
    end
    native.callback(native)
    return true
  end

  ---Invoke native timer `index`'s callback without the host's own guards, so
  ---a spec can prove the package rejects a stale callback on its own.
  ---@param index integer
  function environment.InvokeRaw(index)
    local native = state.nativeTimers[index]
    assert.is_not_nil(native)
    native.callback(native)
  end

  ---Make the next `C_Timer` constructor raise `value`.
  function environment.FailNextTimerCreate(value)
    state.failNextTimerCreate = value
  end

  ---Make the next native `Cancel` raise `value`.
  function environment.FailNextTimerCancel(value)
    state.failNextTimerCancel = value
  end

  ---Make the next `C_Timer` constructor return `value` instead of a stub.
  function environment.ReturnNextNative(value)
    state.nextNativeOverride = value
  end
end

return TimerStub
