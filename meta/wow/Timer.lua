---@meta

-- The `C_Timer` surface TimerKit wraps. TimerKit deliberately depends on
-- `NewTimer` and `NewTicker` only, because those two are stable across every
-- supported client flavour.

---The cancelable handle `C_Timer.NewTimer` and `C_Timer.NewTicker` return.
---@class WowTimerHandle
local WowTimerHandle = {}

---Cancel the timer. Cancelling an already-cancelled timer is harmless.
function WowTimerHandle:Cancel() end

---Whether the timer has been cancelled.
---@return boolean
function WowTimerHandle:IsCancelled() end

---@class C_Timer
C_Timer = {}

---Run `callback` once after `seconds`.
---@param seconds number
---@param callback fun()
---@return WowTimerHandle
function C_Timer.NewTimer(seconds, callback) end

---Run `callback` every `seconds`, at most `iterations` times when given.
---@param seconds number
---@param callback fun(ticker: WowTimerHandle)
---@param iterations integer?
---@return WowTimerHandle
function C_Timer.NewTicker(seconds, callback, iterations) end
