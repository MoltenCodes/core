---@meta

-- Client runtime services used for budgeting, error reporting, taint isolation
-- and combat-log payload access.

---Addon CPU milliseconds since the profiler was last reset.
---
---This is the clock SchedulerKit's frame budget is defined against: a client
---hitch is not charged to a cooperating job.
---@return number milliseconds
function debugprofilestop() end

---A high-resolution wall clock in seconds, monotonic within a session.
---@return number seconds
function GetTimePreciseSec() end

---The current global error handler.
---@return fun(message: any)
function geterrorhandler() end

---Call `callback` with `...` without propagating the caller's taint into it.
---
---Present on modern clients only. EventKit falls back to `xpcall` elsewhere.
---@param callback function
---@param ... any
---@return any ...
function securecallfunction(callback, ...) end

---The payload of the combat-log event currently being dispatched.
---
---`COMBAT_LOG_EVENT_UNFILTERED` itself carries no arguments; a handler reads
---them from this function instead, and only while that handler is running.
---@return number timestamp
---@return string subEvent
---@return boolean hideCaster
---@return string sourceGUID
---@return string sourceName
---@return integer sourceFlags
---@return integer sourceRaidFlags
---@return string destGUID
---@return string destName
---@return integer destFlags
---@return integer destRaidFlags
---@return any ...
function CombatLogGetCurrentEventInfo() end
