-- MoltenCodes TimerKit
--
-- Cancelable, scope-aware World of Warcraft timers. TimerKit keeps the C_Timer
-- boundary narrow, adds deterministic logical state and guards stale native
-- callbacks across restart/cancel operations.
--
-- TimerKit requires Registry and nothing else. It keeps one canonical scope per
-- addon (`ForAddon`) that is closed through `CloseAddonScopes` at logout, the
-- two-step EventKit, HookKit, CommandKit and CommKit use (design constitution,
-- principle 4b). Who makes that call is decided at the addon's first
-- `ForAddon`, from the optional Kits found through `Registry:Find`: a
-- LifecycleKit that lists TimerKit in `CLOSES_ADDON_SCOPES` makes it itself;
-- an older LifecycleKit is asked for an `OnShutdown` subscription; without
-- LifecycleKit one package-level EventKit `PLAYER_LOGOUT` connection makes it;
-- with neither, the addon makes it from its own logout handler.
--
-- Contents
-- --------
--   Constants ............. package identity and option keys
--   Public types .......... LuaCATS declarations for the published surface
--   Dependencies .......... Registry, C_Timer, the monotonic clock;
--                           LifecycleKit and EventKit (optional)
--   Validation ............ public-surface and shared-state validation
--   Bootstrap ............. Registry registration and inherited state
--   In-place upgrade ...... revision-5 shutdown subscriptions released,
--                           revision-7 logout fields added
--   Generic helpers ....... error capture and argument validation
--   Timer internals ....... start, cancel, fire, restart, deadlines
--   Scope internals ....... active-set bookkeeping, bulk cancel, close
--   Logout coverage ....... who closes an addon scope at logout, decided at
--                           the first ForAddon (LifecycleKit, EventKit, none)
--   Timer public methods .. the handle a timer owner receives
--   Scope public methods .. the handle a scope owner receives
--   Package public API .... the facade published through Registry
--   Commit ................ prototype/facade assignment and self-check

local PACKAGE_NAME = "timerKit"
local API_GENERATION = 1
local IMPLEMENTATION_REVISION = 11
local REQUIRED_REGISTRY_API = 2
local STATE_SCHEMA = 1

-- LifecycleKit and EventKit are optional. Each is found through
-- `Registry:Find` when an addon asks for its scope, only to arrange that the
-- scope is closed at logout; TimerKit never depends on either.
local OPTIONAL_LIFECYCLE_KIT_API = 1
local OPTIONAL_EVENT_KIT_API = 1
local LOGOUT_EVENT = "PLAYER_LOGOUT"

-- How an addon scope is closed at logout, recorded on the scope as
-- `_logoutRoute`. `false` means "not decided yet" (a scope an older revision
-- created); `LOGOUT_ROUTE_NONE` is re-examined at the next `ForAddon`, because
-- a Kit loaded later may make logout observable.
local LOGOUT_ROUTE_LIFECYCLE = "lifecycleKit"
local LOGOUT_ROUTE_SHUTDOWN_SUBSCRIPTION = "onShutdown"
local LOGOUT_ROUTE_EVENT = "playerLogout"
local LOGOUT_ROUTE_NONE = "none"

-- The complete set of fields `New`-style option tables accept. Hoisting it to a
-- file-local constant keeps option validation allocation-free: every `New()`
-- reuses this table instead of building a fresh allowed-key set per call.
local TIMER_OPTION_KEYS = {
  delay = true,
  callback = true,
  repeating = true,
}

-- Public types --------------------------------------------------------------
--
-- TimerKit publishes its methods by writing them onto Registry-owned prototype
-- tables, so the editor-facing contract is declared here as LuaCATS classes
-- rather than inferred from those assignments.

---Logical state of a TimerKit timer.
---@alias TimerKit.TimerState "idle"|"running"|"completed"|"cancelled"

---A timer callback, invoked with the logical timer handle that fired.
---@alias TimerKit.Callback fun(timer: TimerKit.Timer)

---Option table accepted by `TimerKit:New` and `TimerKit.Scope:New`.
---@class TimerKit.TimerOptions
---@field delay number Finite seconds; must be greater than zero when repeating.
---@field callback TimerKit.Callback Receives the logical timer handle.
---@field repeating boolean? Defaults to `false`.

---A cancelable logical timer owned by exactly one scope.
---@class TimerKit.Timer
---@field GetState fun(self: TimerKit.Timer): TimerKit.TimerState
---@field GetDelay fun(self: TimerKit.Timer): number
---@field GetScope fun(self: TimerKit.Timer): TimerKit.Scope
---@field GetUserData fun(self: TimerKit.Timer): any
---@field SetUserData fun(self: TimerKit.Timer, value: any): TimerKit.Timer
---@field IsRepeating fun(self: TimerKit.Timer): boolean
---@field IsPending fun(self: TimerKit.Timer): boolean
---@field IsCancelled fun(self: TimerKit.Timer): boolean
---@field Start fun(self: TimerKit.Timer): boolean
---@field Cancel fun(self: TimerKit.Timer): boolean
---@field Restart fun(self: TimerKit.Timer): boolean
---@field GetRemaining fun(self: TimerKit.Timer): number?
---@field GetDeadline fun(self: TimerKit.Timer): number?

---An ownership scope for timers, closed by its owner or, for an addon scope,
---through `TimerKit:CloseAddonScopes`.
---@class TimerKit.Scope
---@field New fun(self: TimerKit.Scope, options: TimerKit.TimerOptions): TimerKit.Timer
---@field After fun(self: TimerKit.Scope, delay: number, callback: TimerKit.Callback): TimerKit.Timer
---@field Every fun(self: TimerKit.Scope, interval: number, callback: TimerKit.Callback): TimerKit.Timer
---@field CancelAll fun(self: TimerKit.Scope): integer
---@field Close fun(self: TimerKit.Scope): boolean
---@field IsClosed fun(self: TimerKit.Scope): boolean
---@field GetAddonName fun(self: TimerKit.Scope): string?
---@field GetActiveCount fun(self: TimerKit.Scope): integer

---The TimerKit package facade published through Registry.
---@class TimerKit
---@field API integer Public API generation.
---@field REVISION integer Compatible implementation revision.
---@field Timer TimerKit.Timer Shared timer prototype.
---@field Scope TimerKit.Scope Shared scope prototype.
---@field New fun(self: TimerKit, options: TimerKit.TimerOptions): TimerKit.Timer
---@field After fun(self: TimerKit, delay: number, callback: TimerKit.Callback): TimerKit.Timer
---@field Every fun(self: TimerKit, interval: number, callback: TimerKit.Callback): TimerKit.Timer
---@field CreateScope fun(self: TimerKit): TimerKit.Scope
---@field ForAddon fun(self: TimerKit, addonName: string): TimerKit.Scope
---@field CloseAddonScopes fun(self: TimerKit, addonName: string): boolean

---A timer as TimerKit stores it: the public handle plus the private fields
---only TimerKit reads and writes (docs/INTERNALS.md). Internal functions take
---this type; `TimerKit.Timer` above stays the published contract.
---@class TimerKit.TimerRecord : TimerKit.Timer
---@field _id integer Creation order within the session.
---@field _scope TimerKit.ScopeRecord
---@field _callback TimerKit.Callback
---@field _delay number
---@field _repeating true? Absent on a one-shot timer.
---@field _state TimerKit.TimerState
---@field _native any The host handle while running, `false` otherwise.
---@field _deadline number|false
---@field _userData any
---@field _generation integer? Only on timers revision 9 or older built.

---A scope as TimerKit stores it.
---@class TimerKit.ScopeRecord : TimerKit.Scope
---@field _addonName string?
---@field _active table<TimerKit.TimerRecord, true>
---@field _activeCount integer
---@field _closed boolean
---@field _logoutRoute string|false?
---@field _logoutSubscription table|false?

-- Dependencies --------------------------------------------------------------

-- The standard functions the per-timer paths call, read once into locals: a
-- global read is a hash lookup in `_G` on every call, a local is not.
local type = type
local error = error
local pcall = pcall
local getmetatable = getmetatable
local setmetatable = setmetatable
local rawequal = rawequal

-- The shared MoltenCodes namespace is the one documented global handoff point between independently embedded copies.
-- selene: allow(global_usage)
local namespace = rawget(_G, "MoltenCodes")
local generations = type(namespace) == "table" and rawget(namespace, "Registries") or nil

-- Ask for Registry by generation and fall back to the alias. A future Registry
-- API generation takes over `MoltenCodes.Registry`, so reading the alias first
-- would hand this file a facade whose contract it was not written against.
local Registry = type(generations) == "table" and rawget(generations, REQUIRED_REGISTRY_API) or nil
if type(Registry) == "nil" and type(namespace) == "table" then
  Registry = rawget(namespace, "Registry")
end
if type(Registry) ~= "table" or rawget(Registry, "API") ~= REQUIRED_REGISTRY_API then
  error("MoltenCodes TimerKit requires Registry API 2 to be loaded first", 2)
end

local bootstrapPackage = rawget(Registry, "Bootstrap")
local getPackage = rawget(Registry, "Get")
if type(bootstrapPackage) ~= "function" or type(getPackage) ~= "function" then
  error("MoltenCodes TimerKit requires a valid Registry API 2 facade", 2)
end

---Silent lookup of an optional package.
---
---Registry revision 7 added `Find`; an older Registry's `Get` also returns
---`nil` for a missing package, so it is a correct fallback. The method is read
---on every call because an embedded Registry upgrade replaces it in place.
---@param packageName string
---@param api integer
---@return table|nil implementation `nil` when the package is not loaded
local function findOptionalPackage(packageName, api)
  local find = rawget(Registry, "Find")
  if type(find) ~= "function" then
    find = getPackage
  end
  local implementation = find(Registry, packageName, api)
  if type(implementation) ~= "table" then
    return nil
  end
  return implementation
end

-- C_Timer is a World of Warcraft client API reachable only through the global table.
-- selene: allow(global_usage)
local wowTimerApi = rawget(_G, "C_Timer")
local nativeNewTimer = type(wowTimerApi) == "table" and rawget(wowTimerApi, "NewTimer") or nil
local nativeNewTicker = type(wowTimerApi) == "table" and rawget(wowTimerApi, "NewTicker") or nil
if type(nativeNewTimer) ~= "function" or type(nativeNewTicker) ~= "function" then
  error("MoltenCodes TimerKit requires C_Timer.NewTimer and C_Timer.NewTicker", 2)
end

-- Deadlines are read from the same monotonic wall clock SchedulerKit falls back
-- to. `C_Timer` fires on wall time, so the CPU clock (`debugprofilestop`) would
-- be the wrong reference, and `GetTime()` is frame-quantised. The value is only
-- ever used for introspection; TimerKit never schedules from it, so it is
-- optional: a host without it loads TimerKit normally and records no deadlines.
-- Requiring it would add a host facility inside API generation 1.
-- GetTimePreciseSec is a World of Warcraft client API reachable only through the global table.
-- selene: allow(global_usage)
local nativeGetTimePreciseSec = rawget(_G, "GetTimePreciseSec")
if type(nativeGetTimePreciseSec) ~= "function" then
  nativeGetTimePreciseSec = nil
end

-- Validation ----------------------------------------------------------------

---Whether `implementation` exposes the complete TimerKit API 1 surface.
---@param implementation any shared package table handed back by Registry
---@return boolean
local function validatePublicSurface(implementation)
  if
    type(implementation) ~= "table"
    or rawget(implementation, "API") ~= API_GENERATION
    or type(rawget(implementation, "REVISION")) ~= "number"
    or type(rawget(implementation, "Timer")) ~= "table"
    or type(rawget(implementation, "Scope")) ~= "table"
  then
    return false
  end

  local Timer = rawget(implementation, "Timer")
  local Scope = rawget(implementation, "Scope")

  return type(rawget(implementation, "New")) == "function"
    and type(rawget(implementation, "After")) == "function"
    and type(rawget(implementation, "Every")) == "function"
    and type(rawget(implementation, "CreateScope")) == "function"
    and type(rawget(implementation, "ForAddon")) == "function"
    and type(rawget(implementation, "CloseAddonScopes")) == "function"
    and type(rawget(Timer, "GetState")) == "function"
    and type(rawget(Timer, "GetDelay")) == "function"
    and type(rawget(Timer, "GetScope")) == "function"
    and type(rawget(Timer, "GetUserData")) == "function"
    and type(rawget(Timer, "SetUserData")) == "function"
    and type(rawget(Timer, "IsRepeating")) == "function"
    and type(rawget(Timer, "IsPending")) == "function"
    and type(rawget(Timer, "IsCancelled")) == "function"
    and type(rawget(Timer, "Start")) == "function"
    and type(rawget(Timer, "Cancel")) == "function"
    and type(rawget(Timer, "Restart")) == "function"
    and type(rawget(Timer, "GetRemaining")) == "function"
    and type(rawget(Timer, "GetDeadline")) == "function"
    and type(rawget(Scope, "New")) == "function"
    and type(rawget(Scope, "After")) == "function"
    and type(rawget(Scope, "Every")) == "function"
    and type(rawget(Scope, "CancelAll")) == "function"
    and type(rawget(Scope, "Close")) == "function"
    and type(rawget(Scope, "IsClosed")) == "function"
    and type(rawget(Scope, "GetAddonName")) == "function"
    and type(rawget(Scope, "GetActiveCount")) == "function"
end

---Whether `currentState` has the fields every API 1 revision shares.
---@param currentState any
---@return boolean
local function validateStateBase(currentState)
  return type(currentState) == "table"
    and rawget(currentState, "schema") == STATE_SCHEMA
    and type(rawget(currentState, "addonScopes")) == "table"
    and type(rawget(currentState, "dispatch")) == "table"
    and type(rawget(currentState, "nextTimerId")) == "number"
    and type(rawget(currentState, "runtimeRevision")) == "number"
    and type(rawget(currentState, "timerMetatable")) == "table"
    and type(rawget(currentState, "scopeMetatable")) == "table"
end

---Whether `implementation` carries package state of this revision's schema.
---@param implementation table
---@return boolean
local function validateCurrentState(implementation)
  local currentState = rawget(implementation, "_state")
  return validateStateBase(currentState)
    and type(rawget(currentState, "defaultScope")) == "table"
    and rawget(currentState, "logoutConnection") ~= nil
    and rawget(currentState, "logoutEventScope") ~= nil
end

-- Bootstrap -----------------------------------------------------------------

-- `Registry:Bootstrap` owns the reconciliation every embedded package repeats:
-- look the package up, refuse to reinterpret state owned by a newer revision,
-- and register this one. What stays here is what only TimerKit can answer.
local TimerKit, previousRevision, selected = bootstrapPackage(Registry, {
  package = PACKAGE_NAME,
  api = API_GENERATION,
  revision = IMPLEMENTATION_REVISION,
  label = "MoltenCodes TimerKit",
  validatePublicSurface = validatePublicSurface,
  validateState = validateCurrentState,
})

if type(TimerKit) == "nil" then
  -- Equal or newer compatible revision already owns the shared package table.
  return selected
end

local Timer = rawget(TimerKit, "Timer")
local Scope = rawget(TimerKit, "Scope")
local state = rawget(TimerKit, "_state")

if type(previousRevision) == "nil" then
  if Timer ~= nil or Scope ~= nil or state ~= nil then
    error("MoltenCodes TimerKit package state is corrupted or incomplete", 2)
  end

  Timer = {}
  Scope = {}
  state = {
    schema = STATE_SCHEMA,
    addonScopes = {},
    defaultScope = false,
    dispatch = {},
    nextTimerId = 0,
    runtimeRevision = 0,
    timerMetatable = {},
    scopeMetatable = {},
    -- The one EventKit `PLAYER_LOGOUT` connection that closes addon scopes
    -- when no LifecycleKit does, and the EventKit scope that owns it;
    -- `false` until an addon needs them.
    logoutConnection = false,
    logoutEventScope = false,
  }
  rawset(TimerKit, "Timer", Timer)
  rawset(TimerKit, "Scope", Scope)
  rawset(TimerKit, "_state", state)
elseif type(Timer) ~= "table" or type(Scope) ~= "table" or not validateStateBase(state) then
  error("MoltenCodes TimerKit package state is corrupted or incomplete", 2)
end

local TIMER_METATABLE = rawget(state, "timerMetatable")
local SCOPE_METATABLE = rawget(state, "scopeMetatable")
rawset(TIMER_METATABLE, "__index", Timer)
rawset(SCOPE_METATABLE, "__index", Scope)

-- In-place upgrade ----------------------------------------------------------

---Release the LifecycleKit shutdown subscriptions revision 5 and older held.
---
---Those revisions required LifecycleKit and subscribed every addon scope to
---its addon's shutdown. This revision knows nothing of LifecycleKit: the
---scope is closed by whoever observes the shutdown, through
---`CloseAddonScopes` (LifecycleKit does so at logout). Keeping the inherited
---subscription would close the scope twice from two places, so it is
---disconnected here and the scope stays open until that call.
---
---The release is best-effort. A subscription whose `Disconnect` is missing or
---raises is dropped all the same: its wrapper resolves `dispatch.closeScope`
---at call time, and closing an already closed scope is a no-op, so the worst
---it can do is close the scope once at shutdown, which is what it was for.
local function releaseInheritedShutdownSubscriptions()
  for _, scope in pairs(rawget(state, "addonScopes")) do
    if type(scope) == "table" then
      local subscription = rawget(scope, "_shutdownSubscription")
      rawset(scope, "_shutdownSubscription", nil)
      if type(subscription) == "table" and type(subscription.Disconnect) == "function" then
        pcall(subscription.Disconnect, subscription)
      end
    end
  end
end

if type(previousRevision) ~= "nil" and previousRevision < IMPLEMENTATION_REVISION then
  releaseInheritedShutdownSubscriptions()
end

-- Revision 7 adds the logout fallback without a schema change. Older state
-- has neither field; its addon scopes are given a logout route at the end of
-- the bootstrap, once the functions that decide one exist.
if rawget(state, "logoutConnection") == nil then
  rawset(state, "logoutConnection", false)
end
if rawget(state, "logoutEventScope") == nil then
  rawset(state, "logoutEventScope", false)
end

-- Generic helpers -----------------------------------------------------------

---Wrap an error object so that `nil` and `false` stay representable.
---@param value any
---@return { value: any }
local function newErrorRecord(value)
  return { value = value }
end

---Keep the first failure of a best-effort loop.
---@param firstError { value: any }|nil
---@param ok boolean
---@param value any
---@return { value: any }|nil firstError
local function captureFirstError(firstError, ok, value)
  if not ok and firstError == nil then
    return newErrorRecord(value)
  end
  return firstError
end

---Re-raise a captured failure unchanged, or return when there was none.
---@param firstError { value: any }|nil
local function raiseCaptured(firstError)
  if firstError ~= nil then
    error(firstError.value, 0)
  end
end

-- Argument validation raises with an explicit stack level so the reported
-- position is the line that called the public method, never a line inside
-- TimerKit. `level` is always the value `error` needs *inside the function that
-- receives it*, so every further hop towards `error` adds exactly one.
--
-- Secret values (Retail 12.0.0 and later) raise when compared, so an argument
-- a check would compare is first asked about with the host probe, and absence
-- is tested with `type(value) == "nil"`. A host without `issecretvalue` has no
-- secret values.

-- issecretvalue is a World of Warcraft client API reachable only through the global table.
-- selene: allow(global_usage)
local nativeIsSecretValue = rawget(_G, "issecretvalue")
if type(nativeIsSecretValue) ~= "function" then
  nativeIsSecretValue = nil
end

---Whether `value` is a secret value the host forbids comparing.
---@param value any
---@return boolean
local function isSecretValue(value)
  if nativeIsSecretValue == nil then
    return false
  end
  return nativeIsSecretValue(value) and true or false
end

---Refuse a secret argument before any comparison touches it.
---@param value any
---@param label string argument description, used in the argument error
---@param level integer stack level the failure is reported at
local function refuseSecret(value, label, level)
  if isSecretValue(value) then
    error(label .. " must not be a secret value", level)
  end
end

---@param value any
---@param label string argument description, used in the argument error
---@param level integer stack level the failure is reported at
local function validateNonEmptyString(value, label, level)
  refuseSecret(value, label, level + 1)
  if type(value) ~= "string" or value == "" then
    error(label .. " must be a non-empty string", level)
  end
end

local HUGE = math.huge

-- The delay check runs on every timer creation, so it takes the public method
-- name and builds the "<method> delay" label only when it raises: building
-- it up front would hash and intern the same string on every call.
---@param delay any finite seconds; strictly positive for a repeating timer
---@param repeating boolean
---@param methodName string public method name, used in the argument error
---@param level integer stack level the failure is reported at
local function validateDelay(delay, repeating, methodName, level)
  if nativeIsSecretValue ~= nil and nativeIsSecretValue(delay) then
    error(methodName .. " delay must not be a secret value", level)
  end
  if type(delay) ~= "number" or delay ~= delay or delay == HUGE or delay == -HUGE then
    error(methodName .. " delay must be a finite number", level)
  end

  if repeating then
    if delay <= 0 then
      error(methodName .. " delay must be greater than zero for repeating timers", level)
    end
  elseif delay < 0 then
    error(methodName .. " delay must be zero or greater", level)
  end
end

---Validate one `New`-style option table and unpack the values it carries.
---@param options any
---@param methodName string public method name, used in the argument errors
---@param level integer stack level the failures are reported at
---@return number delay
---@return TimerKit.Callback callback
---@return boolean repeating
local function validateOptions(options, methodName, level)
  if type(options) ~= "table" then
    error(methodName .. " options must be a table", level)
  end

  -- Report the alphabetically first unknown field without allocating: track
  -- the smallest key seen instead of collecting and sorting every offender.
  local firstUnknown = nil
  for key in next, options do
    if TIMER_OPTION_KEYS[key] ~= true then
      local text = tostring(key)
      if firstUnknown == nil or text < firstUnknown then
        firstUnknown = text
      end
    end
  end
  if firstUnknown ~= nil then
    error(methodName .. ' options contains unknown field "' .. firstUnknown .. '"', level)
  end

  local callback = rawget(options, "callback")
  if type(callback) ~= "function" then
    error(methodName .. " callback must be a function", level)
  end

  local repeating = rawget(options, "repeating")
  refuseSecret(repeating, methodName .. " repeating", level + 1)
  if type(repeating) == "nil" then
    repeating = false
  elseif type(repeating) ~= "boolean" then
    error(methodName .. " repeating must be a boolean", level)
  end

  local delay = rawget(options, "delay")
  validateDelay(delay, repeating, methodName, level + 1)
  return delay, callback, repeating
end

---@param scope any receiver the public method was called on
---@param methodName string public method name, used in the argument error
---@param level integer stack level the failure is reported at
local function validateScope(scope, methodName, level)
  if type(scope) ~= "table" or getmetatable(scope) ~= SCOPE_METATABLE then
    error(methodName .. " must be called on a TimerKit scope", level)
  end
end

---@param timer any receiver the public method was called on
---@param methodName string public method name, used in the argument error
---@param level integer stack level the failure is reported at
local function validateTimer(timer, methodName, level)
  if type(timer) ~= "table" or getmetatable(timer) ~= TIMER_METATABLE then
    error(methodName .. " must be called on a TimerKit timer", level)
  end
end

-- Timer internals -----------------------------------------------------------
--
-- A timer is a table only TimerKit writes (docs/INTERNALS.md lists its
-- fields). The per-timer paths below read and write those fields by plain
-- indexing rather than `rawget`/`rawset`: indexing is one VM instruction, the
-- raw functions are C calls, and the paths run on every start, cancel and
-- tick. The result is the same: the timer metatable has no `__newindex`, and
-- a field that is absent (on a timer an older revision built) falls through
-- `__index` to the `Timer` prototype, which holds only the capitalised public
-- methods and so answers `nil` exactly as `rawget` would.
--
-- Stale host callbacks. Every start creates one host handle and one callback
-- closure that remembers it. The callback fires the timer only while the
-- timer is running and `_native` is still that very handle. Cancel, restart
-- and a delivered one-shot replace `_native` before anything else happens, so
-- a callback from an earlier start can never re-enter the timer, even when
-- the host's own cancellation raised. Revision 9 and older bound callbacks to
-- a per-timer `_generation` counter instead; `fireLegacyTimer` keeps serving
-- the callbacks those revisions left running. They fire only while the timer
-- is running with the generation they were created for, and every start moves
-- such a timer's counter on, so they go stale exactly when a revision 9
-- callback would have.

---Current monotonic wall-clock seconds, the reference every deadline uses.
---Only called once a deadline exists, which implies the clock does.
---@return number seconds
local function now()
  return nativeGetTimePreciseSec()
end

---The deadline for a fire `delay` seconds from now, or `false` without a clock.
---@param delay number
---@return number|false deadline
local function deadlineAfter(delay)
  if nativeGetTimePreciseSec == nil then
    return false
  end
  return nativeGetTimePreciseSec() + delay
end

---Record `timer` as no longer running inside `scope`.
---@param scope TimerKit.ScopeRecord
---@param timer TimerKit.TimerRecord
local function detachActive(scope, timer)
  local active = scope._active
  if active[timer] == true then
    active[timer] = nil
    scope._activeCount = scope._activeCount - 1
  end
end

---Cancel `timer` logically, then ask the host to cancel its native handle.
---@param timer TimerKit.TimerRecord
---@return boolean cancelled `false` when the timer was not running.
local function cancelTimer(timer)
  if timer._state ~= "running" then
    return false
  end

  -- Unbind the host callback before asking the host to cancel. Even if the
  -- host cancellation itself errors, a stale callback cannot re-enter the
  -- logical timer after this point. A callback revision 9 or older created
  -- checks `_generation` and the state instead, so the state change makes it
  -- stale, and `startTimer` moves the generation on before the timer can run
  -- again.
  local native = timer._native
  timer._native = false
  timer._state = "cancelled"
  timer._deadline = false
  -- `detachActive`, inline: this is the path every `Cancel` takes.
  local scope = timer._scope
  local active = scope._active
  if active[timer] == true then
    active[timer] = nil
    scope._activeCount = scope._activeCount - 1
  end

  -- The handle is trusted to have `Cancel` (docs/API.md, "Native
  -- boundary"): a handle without one raises here, after the logical
  -- cancellation above is complete. `false` is a timer an older revision
  -- left without a handle.
  if native then
    native:Cancel()
  end
  return true
end

---Deliver one host callback the stale check accepted.
---@param timer TimerKit.TimerRecord
---@return boolean fired always `true`
local function deliverTimer(timer)
  if timer._repeating == true then
    -- The host re-arms a ticker relative to the tick it just delivered, so
    -- the next deadline is one interval from now, not from the first start.
    timer._deadline = deadlineAfter(timer._delay)
  else
    timer._native = false
    timer._state = "completed"
    timer._deadline = false
    detachActive(timer._scope, timer)
  end

  timer._callback(timer)
  return true
end

---Deliver the callback of the start that created host handle `native`,
---ignoring it unless that start is still the timer's current one.
---@param timer TimerKit.TimerRecord
---@param native table|userdata the handle the firing callback was created for
---@return boolean fired
local function fireTimer(timer, native)
  -- `rawequal`: an identity test that never runs a host `__eq`.
  if timer._state ~= "running" or not rawequal(timer._native, native) then
    return false
  end
  return deliverTimer(timer)
end

---Deliver a host callback that revision 9 or older created, bound to the
---timer's `_generation` counter at that start.
---@param timer TimerKit.TimerRecord
---@param generation integer generation the native handle was created for
---@return boolean fired
local function fireLegacyTimer(timer, generation)
  if timer._generation ~= generation or timer._state ~= "running" then
    return false
  end
  return deliverTimer(timer)
end

---Forward a host callback to the running revision's `fireTimer`.
---
---Called by the closure every start hands the host. It resolves the handler
---through the shared dispatch table when the callback runs, so a callback
---created before an in-place upgrade runs the newer revision's code.
---@param timer TimerKit.TimerRecord
---@param native table|userdata|nil the host handle of the start, `nil` while
---the host constructor has not returned yet
---@return boolean fired
local function dispatchFire(timer, native)
  -- Both tables are TimerKit's own and have no metatable, so indexing them is
  -- a raw read.
  local dispatchTable = state.dispatch
  local fire = type(dispatchTable) == "table" and dispatchTable.fireStarted or nil
  if type(fire) ~= "function" then
    error("MoltenCodes TimerKit runtime dispatch is corrupted", 0)
  end
  return fire(timer, native)
end

---Bind a fresh host callback to `timer` and ask the host for its handle.
---
---The caller has checked that the timer is not running and its scope is open,
---and made older revisions' callbacks stale; `level` identifies the public
---caller so a missing host handle is reported at its line.
---
---The host is asked first and the timer marked running only once it has
---answered, so a constructor that raises leaves the timer exactly as it was
---and its error object reaches the caller unchanged, with no `pcall` on the
---start path. The handle is trusted: TimerKit does not check that it has a
---`Cancel` method (docs/API.md, "Native boundary"). Only a missing handle is
---refused, because the stale-callback check compares `_native` with the
---handle the callback captured, and a callback created before the host
---returned still holds `nil`.
---@param timer TimerKit.TimerRecord
---@param scope TimerKit.ScopeRecord the timer's scope
---@param level integer stack level the failure is reported at
local function armTimer(timer, scope, level)
  -- The callback's only per-start state is the timer and the handle, which is
  -- assigned once the host returns it: until then `native` is `nil` and the
  -- timer is not running, so a host that called back from inside the
  -- constructor would be ignored rather than fire a half-started timer.
  local native
  local callback = function()
    return dispatchFire(timer, native)
  end

  local delay = timer._delay
  local constructor = timer._repeating == true and nativeNewTicker or nativeNewTimer
  local handle = constructor(delay, callback)
  if not handle then
    error("MoltenCodes TimerKit host returned an invalid native timer handle", level)
  end

  native = handle
  timer._native = handle
  timer._state = "running"
  -- Record the timer as running in its scope. Inline: every start takes this path.
  local active = scope._active
  if active[timer] ~= true then
    active[timer] = true
    scope._activeCount = scope._activeCount + 1
  end
  if nativeGetTimePreciseSec ~= nil then
    timer._deadline = nativeGetTimePreciseSec() + delay
  end
end

-- The caller has already validated `timer`; `level` identifies that caller so a
-- closed-scope or invalid-host-handle failure still reports at its line.
---Start `timer` and bind a fresh host callback to the handle it creates.
---@param timer TimerKit.TimerRecord
---@param methodName string public method name, used in the argument error
---@param level integer stack level the failure is reported at
---@return boolean started `false` when the timer was already running.
local function startTimer(timer, methodName, level)
  local previousState = timer._state
  if previousState == "running" then
    return false
  end

  local scope = timer._scope
  if scope._closed == true then
    error(methodName .. " cannot start a timer in a closed scope", level)
  end

  -- A timer revision 9 or older built also carries `_generation`, which the
  -- callbacks those revisions created compare; moving it on makes them stale
  -- before the timer runs again. `_native` holds no handle while the host
  -- constructor runs.
  local generation = timer._generation
  if generation ~= nil then
    timer._generation = generation + 1
  end
  timer._native = false

  armTimer(timer, scope, level + 1)
  return true
end

---Cancel `timer` when it is running, then start it again.
---@param timer TimerKit.TimerRecord
---@param methodName string public method name, used in the argument error
---@param level integer stack level the failure is reported at
---@return boolean started
local function restartTimer(timer, methodName, level)
  local scope = timer._scope
  if scope._closed == true then
    error(methodName .. " cannot restart a timer in a closed scope", level)
  end

  if timer._state == "running" then
    cancelTimer(timer)
  end
  return startTimer(timer, methodName, level + 1)
end

---Build one idle timer. The caller owns all validation.
---
---The constructors list every field the timer will ever hold, `_userData`
---included with a `nil` value, so Lua sizes the table once and no later
---write rehashes it: attaching user data allocates nothing (docs/API.md). A
---one-shot timer leaves `_repeating` out (absent reads as not repeating),
---which keeps it at eight fields, the smallest hash Lua gives it room for;
---a repeating timer is long-lived and keeps the field.
---@param scope TimerKit.ScopeRecord
---@param delay number
---@param callback TimerKit.Callback
---@param repeating boolean
---@return TimerKit.TimerRecord
local function constructTimer(scope, delay, callback, repeating)
  -- The per-session identifier orders bulk cancellation by creation.
  local id = state.nextTimerId + 1
  state.nextTimerId = id
  if repeating then
    return setmetatable({
      _id = id,
      _scope = scope,
      _callback = callback,
      _delay = delay,
      _repeating = true,
      _state = "idle",
      _native = false,
      _deadline = false,
      _userData = nil,
    }, TIMER_METATABLE)
  end
  return setmetatable({
    _id = id,
    _scope = scope,
    _callback = callback,
    _delay = delay,
    _state = "idle",
    _native = false,
    _deadline = false,
    _userData = nil,
  }, TIMER_METATABLE)
end

---Validate a `New` option table and build the idle timer it describes.
---@param scope TimerKit.ScopeRecord
---@param options any
---@param methodName string public method name, used in the argument errors
---@param level integer stack level the failures are reported at
---@return TimerKit.Timer
local function newTimerInScope(scope, options, methodName, level)
  validateScope(scope, methodName, level + 1)
  if scope._closed == true then
    error(methodName .. " cannot create a timer in a closed scope", level)
  end
  local delay, callback, repeating = validateOptions(options, methodName, level + 1)
  return constructTimer(scope, delay, callback, repeating)
end

-- Shared by `Scope:After`/`Scope:Every` and their package-level counterparts, so
-- both entry points sit at the same distance from the validators and report
-- argument errors at their own caller's line.
---@param scope TimerKit.ScopeRecord
---@param delay any
---@param callback any
---@param repeating boolean
---@param methodName string public method name, used in the argument errors
---@param level integer stack level the failures are reported at
---@return TimerKit.Timer
local function startTimerInScope(scope, delay, callback, repeating, methodName, level)
  -- The receiver check of `validateScope`, inline: this is the path every
  -- `After` and `Every` takes.
  if type(scope) ~= "table" or getmetatable(scope) ~= SCOPE_METATABLE then
    error(methodName .. " must be called on a TimerKit scope", level)
  end
  if scope._closed == true then
    error(methodName .. " cannot create a timer in a closed scope", level)
  end
  if type(callback) ~= "function" then
    error(methodName .. " callback must be a function", level)
  end
  validateDelay(delay, repeating, methodName, level + 1)
  local timer = constructTimer(scope, delay, callback, repeating)
  -- A timer built a line above is idle, holds no handle and has no older
  -- revision's callbacks, so it goes straight to the host.
  armTimer(timer, scope, level + 1)
  return timer
end

-- Scope internals -----------------------------------------------------------

---Order two timers by creation. File-level, so a bulk cancel allocates only
---its snapshot.
---@param left TimerKit.Timer
---@param right TimerKit.Timer
---@return boolean
local function createdBefore(left, right)
  return rawget(left, "_id") < rawget(right, "_id")
end

---Return every running timer of `scope`, ordered by creation, as a snapshot.
---@param scope TimerKit.Scope
---@return TimerKit.Timer[]
local function snapshotActive(scope)
  local timers = {}
  local active = rawget(scope, "_active")
  for timer in pairs(active) do
    timers[#timers + 1] = timer
  end
  table.sort(timers, createdBefore)
  return timers
end

-- Internal bulk cancellation. The caller owns validation, so scope cleanup
-- driven by `CloseAddonScopes` does not have to fake a public call site.
---@param scope TimerKit.Scope
---@return integer cancelled
local function cancelAllInScope(scope)
  local timers = snapshotActive(scope)
  local cancelled = 0
  local firstError

  for index = 1, #timers do
    local ok, result = pcall(cancelTimer, timers[index])
    if ok then
      if result == true then
        cancelled = cancelled + 1
      end
    else
      -- A timer whose native cancellation raised is still logically
      -- cancelled, but the count never reaches a caller: the captured
      -- error is re-raised below instead of returning a total.
      firstError = captureFirstError(firstError, false, result)
    end
  end

  raiseCaptured(firstError)
  return cancelled
end

---Disconnect the LifecycleKit `OnShutdown` subscription an addon scope holds,
---if any. Best-effort: the subscription only closes a scope, and closing a
---closed scope is a no-op, so one that cannot be disconnected is harmless.
---@param scope TimerKit.Scope
local function releaseLogoutSubscription(scope)
  local subscription = rawget(scope, "_logoutSubscription")
  if type(subscription) ~= "table" then
    return
  end
  rawset(scope, "_logoutSubscription", false)
  local disconnectSubscription = subscription.Disconnect
  if type(disconnectSubscription) == "function" then
    pcall(disconnectSubscription, subscription)
  end
end

---Terminally close `scope` after best-effort cancellation.
---
---A timer callback may close its own scope, including through
---`CloseAddonScopes`; the timer that is firing is cancelled like the rest,
---which for a ticker means it does not tick again. An addon scope also lets
---go of its LifecycleKit shutdown subscription, which has nothing left to do.
---@param scope TimerKit.Scope
---@return boolean closed `false` when the scope was already closed.
local function closeScope(scope)
  if rawget(scope, "_closed") == true then
    return false
  end

  -- Make the scope terminal before cleanup begins. Callback re-entry cannot
  -- schedule replacement timers while the close is in progress.
  rawset(scope, "_closed", true)
  releaseLogoutSubscription(scope)

  local ok, cancelError = pcall(cancelAllInScope, scope)
  raiseCaptured(captureFirstError(nil, ok, cancelError))
  return true
end

---Build one open scope. `addonName` is `nil` for a manually owned scope.
---@param addonName string|nil
---@return TimerKit.Scope
local function newScope(addonName)
  return setmetatable({
    _addonName = addonName,
    _active = {},
    _activeCount = 0,
    _closed = false,
  }, SCOPE_METATABLE)
end

-- Logout coverage -----------------------------------------------------------
--
-- An addon scope must close at logout whenever the framework can observe
-- logout at all, whatever revisions an addon's libraries pair. The first
-- `ForAddon` for an addon picks the first of these that applies and records
-- it on the scope as `_logoutRoute`:
--
--   1. LifecycleKit lists "timerKit" in `CLOSES_ADDON_SCOPES`: it calls
--      `CloseAddonScopes` at shutdown, after the addon's shutdown callbacks.
--      Nothing is subscribed; `LifecycleKit:ForAddon` is called once so the
--      addon has an instance and its shutdown pass reaches this scope.
--   2. An older LifecycleKit, without that capability: one `OnShutdown`
--      subscription per addon closes the scope among the shutdown callbacks,
--      as revisions 5 and older did. The handle is kept on the scope, so
--      closing the scope disconnects it.
--   3. No LifecycleKit, but EventKit: one package-level `PLAYER_LOGOUT`
--      connection, in an EventKit scope of TimerKit's own, closes every
--      addon scope that neither LifecycleKit route covers.
--   4. Neither: nothing is subscribed, and the addon calls
--      `CloseAddonScopes` itself. This outcome is examined again at the next
--      `ForAddon`, since a Kit loaded later can change it.
--
-- Callbacks handed to other Kits resolve TimerKit's behaviour through
-- `state.dispatch` when they run, so a newer revision upgrades them in place.

---Whether `LifecycleKit` closes TimerKit's addon scopes at shutdown itself.
---
---`CLOSES_ADDON_SCOPES` is a read-only view, so it is read by ordinary
---indexing; a revision without the field closes none.
---@param LifecycleKit table
---@return boolean
local function lifecycleClosesAddonScopes(LifecycleKit)
  local capabilities = rawget(LifecycleKit, "CLOSES_ADDON_SCOPES")
  return type(capabilities) == "table" and capabilities[PACKAGE_NAME] == true
end

---The LifecycleKit that closes TimerKit's addon scopes itself, or `nil`.
---@return table|nil
local function findClosingLifecycleKit()
  local LifecycleKit = findOptionalPackage("lifecycleKit", OPTIONAL_LIFECYCLE_KIT_API)
  if type(LifecycleKit) ~= "nil" and lifecycleClosesAddonScopes(LifecycleKit) then
    return LifecycleKit
  end
  return nil
end

---Close an addon scope from a LifecycleKit `OnShutdown` callback (route 2).
---
---When a LifecycleKit that closes TimerKit's scopes itself has replaced the
---older one in the meantime, it makes the call after the shutdown callbacks,
---so this one steps aside and keeps that ordering.
---@param addonName string
---@return boolean closed
local function closeOnShutdown(addonName)
  local scope = rawget(rawget(state, "addonScopes"), addonName)
  if scope == nil then
    return false
  end
  -- The subscription is one-shot and has fired; nothing is left to release.
  rawset(scope, "_logoutSubscription", false)
  if findClosingLifecycleKit() ~= nil then
    return false
  end
  return closeScope(scope)
end

---Close, at `PLAYER_LOGOUT`, every addon scope no LifecycleKit route covers
---(route 3), in addon-name order. Every scope is attempted; the first failure
---is re-raised afterwards, and EventKit reports it through the host error
---handler.
local function closeOnLogout()
  rawset(state, "logoutConnection", false)

  local addonScopes = rawget(state, "addonScopes")
  local names = {}
  for addonName in pairs(addonScopes) do
    names[#names + 1] = addonName
  end
  table.sort(names)

  local firstError
  for index = 1, #names do
    local scope = rawget(addonScopes, names[index])
    local route = rawget(scope, "_logoutRoute")
    if route ~= LOGOUT_ROUTE_LIFECYCLE and route ~= LOGOUT_ROUTE_SHUTDOWN_SUBSCRIPTION then
      local ok, closeError = pcall(closeScope, scope)
      firstError = captureFirstError(firstError, ok, closeError)
    end
  end
  raiseCaptured(firstError)
end

---Subscribe the addon scope to an older LifecycleKit's shutdown (route 2).
---@param LifecycleKit table
---@param addonName string
---@return table|nil subscription `nil` when LifecycleKit refused
local function subscribeToShutdown(LifecycleKit, addonName)
  local ok, subscription = pcall(function()
    return LifecycleKit:ForAddon(addonName):OnShutdown(function()
      local closeForShutdown = rawget(rawget(state, "dispatch"), "closeOnShutdown")
      if type(closeForShutdown) == "function" then
        closeForShutdown(addonName)
      end
    end)
  end)
  if not ok or type(subscription) ~= "table" then
    return nil
  end
  return subscription
end

---Whether the package-level `PLAYER_LOGOUT` connection is live.
---@return boolean
local function hasLogoutConnection()
  local connection = rawget(state, "logoutConnection")
  if type(connection) ~= "table" then
    return false
  end
  local ok, connected = pcall(connection.IsConnected, connection)
  return ok and connected == true
end

---Make sure one EventKit `PLAYER_LOGOUT` connection closes the addon scopes
---no LifecycleKit covers (route 3), creating it on first need.
---@return boolean covered `false` when EventKit is absent or refused
local function ensureLogoutConnection()
  if hasLogoutConnection() then
    return true
  end
  local EventKit = findOptionalPackage("eventKit", OPTIONAL_EVENT_KIT_API)
  if type(EventKit) == "nil" then
    return false
  end

  local ok, eventScope, connection = pcall(function()
    local ownScope = rawget(state, "logoutEventScope")
    if type(ownScope) ~= "table" or ownScope:IsClosed() then
      ownScope = EventKit:CreateScope()
    end
    local logoutConnection = ownScope:Once(LOGOUT_EVENT, function()
      local handler = rawget(rawget(state, "dispatch"), "closeOnLogout")
      if type(handler) == "function" then
        handler()
      end
    end)
    return ownScope, logoutConnection
  end)
  if not ok or type(connection) ~= "table" then
    return false
  end
  rawset(state, "logoutEventScope", eventScope)
  rawset(state, "logoutConnection", connection)
  return true
end

---Decide who closes `scope` at logout, unless that is already decided.
---
---Called by `ForAddon` for every scope it returns, so the common case costs one
---field read. Only an undecided scope, or one nobody could close before, looks
---for LifecycleKit and EventKit.
---@param scope TimerKit.Scope an addon scope
local function ensureLogoutRoute(scope)
  local route = rawget(scope, "_logoutRoute")
  if (route ~= false and route ~= LOGOUT_ROUTE_NONE) or rawget(scope, "_closed") == true then
    return
  end

  local LifecycleKit = findOptionalPackage("lifecycleKit", OPTIONAL_LIFECYCLE_KIT_API)
  if type(LifecycleKit) ~= "nil" then
    if lifecycleClosesAddonScopes(LifecycleKit) then
      -- LifecycleKit closes the scopes of the addons it has an
      -- instance for, so make sure this addon has one. Nothing is
      -- subscribed; a refusal only leaves the addon unknown to it.
      pcall(function()
        LifecycleKit:ForAddon(rawget(scope, "_addonName"))
      end)
      rawset(scope, "_logoutRoute", LOGOUT_ROUTE_LIFECYCLE)
      return
    end
    local subscription = subscribeToShutdown(LifecycleKit, rawget(scope, "_addonName"))
    if subscription ~= nil then
      rawset(scope, "_logoutSubscription", subscription)
      rawset(scope, "_logoutRoute", LOGOUT_ROUTE_SHUTDOWN_SUBSCRIPTION)
      return
    end
  end

  if ensureLogoutConnection() then
    rawset(scope, "_logoutRoute", LOGOUT_ROUTE_EVENT)
    return
  end
  rawset(scope, "_logoutRoute", LOGOUT_ROUTE_NONE)
end

-- Timer public methods ------------------------------------------------------

---Return the logical timer state.
---@param self TimerKit.TimerRecord
---@return TimerKit.TimerState state
local function timerGetState(self)
  validateTimer(self, "TimerKit.Timer:GetState", 3)
  return rawget(self, "_state")
end

---Return the configured delay or repeat interval in seconds.
---@param self TimerKit.TimerRecord
---@return number seconds
local function timerGetDelay(self)
  validateTimer(self, "TimerKit.Timer:GetDelay", 3)
  return rawget(self, "_delay")
end

---Return the scope that owns this timer.
---@param self TimerKit.TimerRecord
---@return TimerKit.Scope scope
local function timerGetScope(self)
  validateTimer(self, "TimerKit.Timer:GetScope", 3)
  return rawget(self, "_scope")
end

---Return the opaque value attached to this timer, or `nil` when none is set.
---@param self TimerKit.TimerRecord
---@return any userData
local function timerGetUserData(self)
  validateTimer(self, "TimerKit.Timer:GetUserData", 3)
  return rawget(self, "_userData")
end

---Attach one opaque value to this timer. TimerKit stores the reference and
---never reads, copies, or clears it; passing `nil` detaches it again.
---@param self TimerKit.TimerRecord
---@param value any
---@return TimerKit.Timer self
local function timerSetUserData(self, value)
  validateTimer(self, "TimerKit.Timer:SetUserData", 3)
  rawset(self, "_userData", value)
  return self
end

---Return whether the timer repeats instead of firing once.
---@param self TimerKit.TimerRecord
---@return boolean repeating
local function timerIsRepeating(self)
  validateTimer(self, "TimerKit.Timer:IsRepeating", 3)
  return rawget(self, "_repeating") == true
end

---Return whether the logical timer is currently running.
---@param self TimerKit.TimerRecord
---@return boolean pending
local function timerIsPending(self)
  validateTimer(self, "TimerKit.Timer:IsPending", 3)
  return rawget(self, "_state") == "running"
end

---Return whether the timer was logically cancelled.
---@param self TimerKit.TimerRecord
---@return boolean cancelled
local function timerIsCancelled(self)
  validateTimer(self, "TimerKit.Timer:IsCancelled", 3)
  return rawget(self, "_state") == "cancelled"
end

---Start an idle, completed, or cancelled timer.
---@param self TimerKit.TimerRecord
---@return boolean started `false` when the timer was already running.
local function timerStart(self)
  validateTimer(self, "TimerKit.Timer:Start", 3)
  return startTimer(self, "TimerKit.Timer:Start", 3)
end

---Cancel a running timer.
---@param self TimerKit.TimerRecord
---@return boolean cancelled `false` when the timer was not running.
local function timerCancel(self)
  -- The receiver check of `validateTimer`, inline: `Cancel` is the one timer
  -- method on the start-and-cancel path.
  if type(self) ~= "table" or getmetatable(self) ~= TIMER_METATABLE then
    error("TimerKit.Timer:Cancel must be called on a TimerKit timer", 2)
  end
  return cancelTimer(self)
end

---Cancel the timer when needed and start a fresh logical generation.
---@param self TimerKit.TimerRecord
---@return boolean started
local function timerRestart(self)
  validateTimer(self, "TimerKit.Timer:Restart", 3)
  return restartTimer(self, "TimerKit.Timer:Restart", 3)
end

---Return the monotonic instant this timer fires next, or `nil` when it is not
---running.
---
---The instant is on the `GetTimePreciseSec()` clock. It is TimerKit's own
---accounting of when it asked the host to fire, not a promise from the host:
---`C_Timer` delivers on the first frame at or after that instant.
---@param self TimerKit.TimerRecord
---@return number? deadline seconds on the `GetTimePreciseSec()` clock
local function timerGetDeadline(self)
  validateTimer(self, "TimerKit.Timer:GetDeadline", 3)
  if rawget(self, "_state") ~= "running" then
    return nil
  end
  local deadline = rawget(self, "_deadline")
  if type(deadline) ~= "number" then
    -- Started by a revision that kept no deadline; see API.md.
    return nil
  end
  return deadline
end

---Return the seconds left until this timer fires next, or `nil` when it is not
---running. Never negative: a timer the host has not delivered yet although its
---deadline passed reports `0`.
---@param self TimerKit.TimerRecord
---@return number? remaining seconds, an estimate; see `GetDeadline`
local function timerGetRemaining(self)
  validateTimer(self, "TimerKit.Timer:GetRemaining", 3)
  if rawget(self, "_state") ~= "running" then
    return nil
  end
  local deadline = rawget(self, "_deadline")
  if type(deadline) ~= "number" then
    return nil
  end
  local remaining = deadline - now()
  if remaining < 0 then
    return 0
  end
  return remaining
end

-- Scope public methods ------------------------------------------------------

---Create an idle timer owned by this scope.
---@param self TimerKit.ScopeRecord
---@param options TimerKit.TimerOptions
---@return TimerKit.Timer timer
local function scopeNew(self, options)
  return newTimerInScope(self, options, "TimerKit.Scope:New", 3)
end

---Create and immediately start a one-shot timer in this scope.
---@param self TimerKit.ScopeRecord
---@param delay number Finite seconds greater than or equal to zero.
---@param callback TimerKit.Callback
---@return TimerKit.Timer timer
local function scopeAfter(self, delay, callback)
  return startTimerInScope(self, delay, callback, false, "TimerKit.Scope:After", 3)
end

---Create and immediately start a repeating timer in this scope.
---@param self TimerKit.ScopeRecord
---@param interval number Finite seconds greater than zero.
---@param callback TimerKit.Callback
---@return TimerKit.Timer timer
local function scopeEvery(self, interval, callback)
  return startTimerInScope(self, interval, callback, true, "TimerKit.Scope:Every", 3)
end

---Cancel every active timer while keeping the scope reusable.
---@param self TimerKit.ScopeRecord
---@return integer cancelled
local function scopeCancelAll(self)
  validateScope(self, "TimerKit.Scope:CancelAll", 3)
  return cancelAllInScope(self)
end

---Terminally close the scope after best-effort cancellation.
---@param self TimerKit.ScopeRecord
---@return boolean closed `false` when the scope was already closed.
local function scopeClose(self)
  validateScope(self, "TimerKit.Scope:Close", 3)
  return closeScope(self)
end

---Return whether the scope is terminally closed.
---@param self TimerKit.ScopeRecord
---@return boolean closed
local function scopeIsClosed(self)
  validateScope(self, "TimerKit.Scope:IsClosed", 3)
  return rawget(self, "_closed") == true
end

---Return the owning addon name, or `nil` for a manual scope.
---@param self TimerKit.ScopeRecord
---@return string? addonName
local function scopeGetAddonName(self)
  validateScope(self, "TimerKit.Scope:GetAddonName", 3)
  return rawget(self, "_addonName")
end

---Return the number of logically running timers owned by this scope.
---@param self TimerKit.ScopeRecord
---@return integer activeCount
local function scopeGetActiveCount(self)
  validateScope(self, "TimerKit.Scope:GetActiveCount", 3)
  return rawget(self, "_activeCount")
end

-- Package public API --------------------------------------------------------

---Return TimerKit's internal manual scope, replacing it once it is closed.
---@return TimerKit.ScopeRecord
local function getDefaultScope()
  local scope = rawget(state, "defaultScope")
  if scope == false or rawget(scope, "_closed") == true then
    scope = newScope(nil)
    rawset(state, "defaultScope", scope)
  end
  return scope
end

---Create an idle timer in TimerKit's internal manual scope.
---@param _ TimerKit
---@param options TimerKit.TimerOptions
---@return TimerKit.Timer timer
local function packageNew(_, options)
  return newTimerInScope(getDefaultScope(), options, "TimerKit:New", 3)
end

---Create and immediately start a one-shot timer in the internal manual scope.
---@param _ TimerKit
---@param delay number Finite seconds greater than or equal to zero.
---@param callback TimerKit.Callback
---@return TimerKit.Timer timer
local function packageAfter(_, delay, callback)
  return startTimerInScope(getDefaultScope(), delay, callback, false, "TimerKit:After", 3)
end

---Create and immediately start a repeating timer in the internal manual scope.
---@param _ TimerKit
---@param interval number Finite seconds greater than zero.
---@param callback TimerKit.Callback
---@return TimerKit.Timer timer
local function packageEvery(_, interval, callback)
  return startTimerInScope(getDefaultScope(), interval, callback, true, "TimerKit:Every", 3)
end

---Create a manually owned timer scope, closed only by its owner.
---@return TimerKit.Scope scope
local function createScope()
  return newScope(nil)
end

---Return the canonical timer scope for an addon, creating it on demand.
---
---The scope is closed at logout through `TimerKit:CloseAddonScopes(addonName)`
---by LifecycleKit, or by TimerKit's own EventKit `PLAYER_LOGOUT` connection
---when LifecycleKit is absent; with neither loaded, the addon makes the call
---itself. See "Logout coverage" above and docs/API.md, "At logout".
---@param _ TimerKit
---@param addonName string addon folder name
---@return TimerKit.Scope scope
local function forAddon(_, addonName)
  validateNonEmptyString(addonName, "TimerKit:ForAddon addonName", 3)

  local addonScopes = rawget(state, "addonScopes")
  local scope = rawget(addonScopes, addonName)
  if scope == nil then
    scope = newScope(addonName)
    rawset(scope, "_logoutRoute", false)
    rawset(scope, "_logoutSubscription", false)
    rawset(addonScopes, addonName, scope)
  end
  ensureLogoutRoute(scope)
  return scope
end

---Close the canonical scope of an addon, cancelling every timer it owns.
---
---Closing is terminal, exactly like addon shutdown: the closed scope stays the
---canonical scope, so a later `ForAddon(addonName)` returns it and refuses new
---timers. An addon that never asked for a scope has nothing to close: nothing
---is recorded, so the addon-scope map grows only with `ForAddon` calls, as
---EventKit, HookKit, CommandKit and CommKit do.
---
---A failing native cancellation does not stop the sweep; every timer is
---cancelled logically and the first error is re-raised afterwards, as
---`TimerKit.Scope:Close()` documents.
---@param self TimerKit
---@param addonName string addon folder name
---@return boolean closed `false` when the addon has no scope or it was already closed.
local function closeAddonScopes(self, addonName)
  if isSecretValue(self) or self ~= TimerKit then
    error(
      "TimerKit:CloseAddonScopes must be called on the TimerKit facade; "
        .. "use TimerKit:CloseAddonScopes(addonName)",
      2
    )
  end
  validateNonEmptyString(addonName, "TimerKit:CloseAddonScopes addonName", 3)

  local scope = rawget(rawget(state, "addonScopes"), addonName)
  if scope == nil then
    return false
  end
  return closeScope(scope)
end

-- Commit -------------------------------------------------------------------

rawset(Timer, "GetState", timerGetState)
rawset(Timer, "GetDelay", timerGetDelay)
rawset(Timer, "GetScope", timerGetScope)
rawset(Timer, "GetUserData", timerGetUserData)
rawset(Timer, "SetUserData", timerSetUserData)
rawset(Timer, "IsRepeating", timerIsRepeating)
rawset(Timer, "IsPending", timerIsPending)
rawset(Timer, "IsCancelled", timerIsCancelled)
rawset(Timer, "Start", timerStart)
rawset(Timer, "Cancel", timerCancel)
rawset(Timer, "Restart", timerRestart)
rawset(Timer, "GetRemaining", timerGetRemaining)
rawset(Timer, "GetDeadline", timerGetDeadline)

rawset(Scope, "New", scopeNew)
rawset(Scope, "After", scopeAfter)
rawset(Scope, "Every", scopeEvery)
rawset(Scope, "CancelAll", scopeCancelAll)
rawset(Scope, "Close", scopeClose)
rawset(Scope, "IsClosed", scopeIsClosed)
rawset(Scope, "GetAddonName", scopeGetAddonName)
rawset(Scope, "GetActiveCount", scopeGetActiveCount)

rawset(TimerKit, "API", API_GENERATION)
rawset(TimerKit, "REVISION", IMPLEMENTATION_REVISION)
rawset(TimerKit, "New", packageNew)
rawset(TimerKit, "After", packageAfter)
rawset(TimerKit, "Every", packageEvery)
rawset(TimerKit, "CreateScope", createScope)
rawset(TimerKit, "ForAddon", forAddon)
rawset(TimerKit, "CloseAddonScopes", closeAddonScopes)

local defaultScope = rawget(state, "defaultScope")
if defaultScope == false then
  rawset(state, "defaultScope", newScope(nil))
elseif type(defaultScope) ~= "table" or getmetatable(defaultScope) ~= SCOPE_METATABLE then
  error("MoltenCodes TimerKit package state is corrupted or incomplete", 2)
end

local dispatch = rawget(state, "dispatch")
-- Revision 10 binds host callbacks to their handle and routes them through
-- `fireStarted`; `fire` stays published for the callbacks revision 9 and
-- older created, which pass the timer's generation instead.
rawset(dispatch, "fireStarted", fireTimer)
rawset(dispatch, "fire", fireLegacyTimer)
-- No revision from 6 on calls `closeScope` through dispatch. It stays published
-- for the shutdown wrappers of revision 5 and older, in case one could not be
-- disconnected during the upgrade; see `releaseInheritedShutdownSubscriptions`.
rawset(dispatch, "closeScope", closeScope)
-- The logout routes' callbacks resolve these at call time (see "Logout
-- coverage"), so connections an older revision 7+ copy made run this code.
rawset(dispatch, "closeOnShutdown", closeOnShutdown)
rawset(dispatch, "closeOnLogout", closeOnLogout)
rawset(state, "runtimeRevision", IMPLEMENTATION_REVISION)

if not validatePublicSurface(TimerKit) or not validateCurrentState(TimerKit) then
  error("MoltenCodes TimerKit package state is corrupted or incomplete", 2)
end

-- Addon scopes an older revision created have no logout route yet. They are
-- given one now, in addon-name order, exactly as a first `ForAddon` would;
-- scopes whose route a revision 7+ copy already decided keep it, with any
-- subscription or connection it made.
local function routeInheritedAddonScopes()
  local addonScopes = rawget(state, "addonScopes")
  local names = {}
  for addonName, scope in pairs(addonScopes) do
    if type(scope) == "table" and rawget(scope, "_logoutRoute") == nil then
      names[#names + 1] = addonName
    end
  end
  table.sort(names)
  for index = 1, #names do
    local scope = rawget(addonScopes, names[index])
    rawset(scope, "_logoutRoute", false)
    rawset(scope, "_logoutSubscription", false)
    ensureLogoutRoute(scope)
  end
end

if type(previousRevision) ~= "nil" and previousRevision < IMPLEMENTATION_REVISION then
  routeInheritedAddonScopes()
end

return TimerKit
