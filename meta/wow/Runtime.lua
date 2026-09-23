---@meta

-- Client runtime services used for budgeting, error reporting, taint isolation,
-- secret-value checks and combat-log payload access.

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

---Whether `value` is a secret value.
---
---Since patch 12.0.0 the Retail client hands tainted code secret values from
---some unit and aura APIs while restrictions apply. Tainted code may store a
---secret, pass it to functions, and concatenate or `string.format` it into a
---result that is itself secret. Comparing it, arithmetic, the length operator,
---indexing or calling it, a boolean test on a secret boolean, and using it as a
---table key raise. Clients without secret values do not publish this function;
---probe it and treat its absence as "never secret". See docs/EMBEDDING.md,
---"Secret values", and https://warcraft.wiki.gg/wiki/Secret_Values.
---
---@param value any
---@return boolean isSecret
function issecretvalue(value) end

---Whether a global variable, or a field of `table`, still holds a secure value.
---
---Probe this before repairing shared state: a secure value must be left alone.
---@param table table
---@param variable string
---@return boolean isSecure
---@return string? taintedBy The addon that tainted the variable, when it is not secure.
---@overload fun(variable: string): isSecure: boolean, taintedBy: string?
function issecurevariable(table, variable) end

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
