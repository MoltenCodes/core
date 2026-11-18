-- MoltenCodes TimerKit part Pausing
--
-- `Timer:Pause`, `Timer:Resume` and `Timer:IsPaused` (docs/API.md, "Pausing"):
-- pause a running timer and resume it later with what was left of its delay.
--
-- A pause cancels the host handle and keeps what is left of the delay in the
-- timer's deadline slot, which holds an instant only while the timer runs; the
-- state says which. Resuming asks the host for a one-shot of that remainder
-- whose callback goes through `state.dispatch.fireResumed`: a one-shot timer
-- completes as usual, and a repeating one is armed again as a ticker of its
-- interval before its callback runs, so a `Cancel` inside the callback cancels
-- that ticker. docs/records/timerKit.md, "timerKit pausable timers (W15)",
-- records why this is built on `C_Timer` handles rather than an animation host.
--
-- The core keeps the `"paused"` state wherever it already handles it
-- (`Cancel`, `Restart`, `CancelAll`, `Close`, `GetState`, `GetRemaining`,
-- `GetDeadline`, `IsPending`, `Start`), so a paused timer stays in its scope's
-- active set and is cancelled with it. This part adds only the transitions.
--
-- The part needs TimerKit's core loaded first (docs/decisions/
-- 0001-kit-core-and-parts.md). It keeps nothing of its own outside the timer
-- slots the core defines and calls the core through `state.helpers`, read at
-- call time, so a core upgraded after this part loaded serves it. Host
-- callbacks resolve `state.dispatch.fireResumed` when they fire, so a higher
-- revision of this part takes over the resumes already pending.
--
-- Contents
-- --------
--   Constants ........ identity and the core interface this part reads
--   Dependencies ..... TimerKit's core and its state
--   Transitions ...... pause, the resume one-shot and its delivery
--   Public methods ... Pause, Resume, IsPaused
--   Commit ........... members, dispatch entries and the part's revision

-- Constants ------------------------------------------------------------------

local PART_NAME = "Pausing"
local PART_REVISION = 1
local REQUIRED_REGISTRY_API = 2
local CORE_PACKAGE, CORE_API = "timerKit", 1
-- The core interface this part reads (`state.helpers` entries, the
-- `state.dispatch` entries it fills). TimerKit's core publishes the number.
local REQUIRED_PART_INTERFACE = 1

-- Dependencies ---------------------------------------------------------------

local type = type
local rawequal = rawequal

-- The shared MoltenCodes namespace is the one documented global handoff point between independently embedded copies.
-- selene: allow(global_usage)
local namespace = rawget(_G, "MoltenCodes")
local generations = type(namespace) == "table" and rawget(namespace, "Registries") or nil
local Registry = type(generations) == "table" and rawget(generations, REQUIRED_REGISTRY_API) or nil
local TimerKit = nil
if type(Registry) == "table" and type(rawget(Registry, "Get")) == "function" then
  TimerKit = Registry:Get(CORE_PACKAGE, CORE_API)
end
local state = type(TimerKit) == "table" and rawget(TimerKit, "_state") or nil
local partInterface = type(state) == "table" and rawget(state, "partInterface") or nil
if
  type(state) ~= "table"
  or type(partInterface) ~= "number"
  or partInterface < REQUIRED_PART_INTERFACE
  or type(rawget(state, "parts")) ~= "table"
  or type(rawget(state, "helpers")) ~= "table"
  or type(rawget(state, "dispatch")) ~= "table"
then
  error("MoltenCodes TimerKit part Pausing requires TimerKit API 1 to be loaded first", 2)
end

---@cast TimerKit table

local installed = state.parts[PART_NAME]
if
  type(installed) == "table"
  and type(installed.revision) == "number"
  and installed.revision >= PART_REVISION
then
  -- An equal or newer revision of this part already serves every addon.
  return TimerKit
end

-- Read at call time, never copied: an upgraded core's helpers serve this part.
local helpers = state.helpers
local Timer = rawget(TimerKit, "Timer")

-- Transitions ----------------------------------------------------------------

---Deliver the one-shot of a resume, ignoring it unless that resume is still
---the timer's current start.
---@param timer TimerKit.TimerRecord
---@param native table|userdata the handle the firing callback was created for
---@return boolean fired
local function fireResumedTimer(timer, native)
  if
    timer[8] --[[repeating]]
    ~= true
  then
    -- A one-shot completes exactly as one the core started.
    return helpers.fireTimer(timer, native)
  end
  -- `rawequal`: an identity test that never runs a host `__eq`.
  if
    timer[5] --[[state]]
      ~= "running"
    or not rawequal(timer[6] --[[native]], native)
  then
    return false
  end
  -- Back on the interval. The timer is cancelled logically first, so a host
  -- constructor that raises leaves it cancelled rather than running without
  -- a handle; `armTimer` puts it back in its scope's active set.
  timer[6] --[[native]] = false
  timer[5] --[[state]] = "cancelled"
  timer[7] --[[deadline]] = false
  local scope = timer[2] --[[scope]]
  helpers.detachActive(scope, timer)
  helpers.armTimer(timer, scope, 2)
  timer
    [3] --[[callback]](timer)
  return true
end

---Ask the host for a one-shot of `remaining` seconds for a paused timer and
---mark it running. As in the core's `armTimer`, the host is asked first, so a
---constructor that raises leaves the timer paused.
---@param timer TimerKit.TimerRecord
---@param remaining number seconds left when the timer was paused
---@param level integer stack level the failure is reported at
local function armRemainder(timer, remaining, level)
  local native
  local callback = function()
    return state.dispatch.fireResumed(timer, native)
  end
  local handle = helpers.newOneShotHandle(remaining, callback)
  if not handle then
    error("MoltenCodes TimerKit host returned an invalid native timer handle", level)
  end
  native = handle
  timer[6] --[[native]] = handle
  timer[5] --[[state]] = "running"
  timer[7] --[[deadline]] = helpers.deadlineAfter(remaining)
end

---Pause a running timer, keeping what is left of its delay.
---@param timer TimerKit.TimerRecord
---@return boolean paused `false` when the timer was not running.
local function pauseTimer(timer)
  if
    timer[5] --[[state]]
    ~= "running"
  then
    return false
  end
  -- Without a clock (no deadline was kept) the full delay is left.
  local remaining = timer[4] --[[delay]]
  local deadline = timer[7] --[[deadline]]
  if type(deadline) == "number" then
    remaining = deadline - helpers.now()
    if remaining < 0 then
      remaining = 0
    end
  end
  -- Unbind the host callback before cancelling it, as the core's cancel does.
  local native = timer[6] --[[native]]
  timer[6] --[[native]] = false
  timer[5] --[[state]] = "paused"
  timer[7] --[[deadline]] = remaining
  if native then
    native:Cancel()
  end
  return true
end

-- Public methods -------------------------------------------------------------

---Pause a running timer; `Resume` starts it again with what was left.
---@param self TimerKit.TimerRecord
---@return boolean paused `false` when the timer was not running.
local function timerPause(self)
  helpers.validateTimer(self, "TimerKit.Timer:Pause", 3)
  return state.dispatch.pause(self)
end

---Resume a paused timer with what was left of its delay; a repeating timer
---returns to its interval after that first fire. A paused timer's scope is
---never closed: closing a scope cancels its paused timers.
---@param self TimerKit.TimerRecord
---@return boolean resumed `false` when the timer was not paused.
local function timerResume(self)
  helpers.validateTimer(self, "TimerKit.Timer:Resume", 3)
  if
    self[5] --[[state]]
    ~= "paused"
  then
    return false
  end
  armRemainder(self, self[7] --[[@as number]], 3)
  return true
end

---Return whether the timer is paused.
---@param self TimerKit.TimerRecord
---@return boolean paused
local function timerIsPaused(self)
  helpers.validateTimer(self, "TimerKit.Timer:IsPaused", 3)
  return self[5] --[[state]] == "paused"
end

-- Commit ---------------------------------------------------------------------

rawset(Timer, "Pause", timerPause)
rawset(Timer, "Resume", timerResume)
rawset(Timer, "IsPaused", timerIsPaused)
-- Resolved at call time by the resume one-shots and by `Pause`, so a higher
-- revision of this part replaces the code that pending resumes run.
state.dispatch.fireResumed = fireResumedTimer
state.dispatch.pause = pauseTimer
state.parts[PART_NAME] = { revision = PART_REVISION }

return TimerKit
