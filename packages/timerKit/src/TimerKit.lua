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
-- without such a LifecycleKit one package-level EventKit `PLAYER_LOGOUT`
-- connection makes it; with neither, the addon makes it from its own logout
-- handler.
--
-- This file is TimerKit's core. Pausing (`Timer:Pause`, `Resume`, `IsPaused`)
-- is the Pausing part, `parts/TimerKit-Pausing.lua`; without it those members
-- raise at the caller's line with the file to embed (docs/API.md, "Parts";
-- docs/decisions/0001-kit-core-and-parts.md).
--
-- An in-place upgrade is supported from revision 14, the revision before this
-- one, and no further back: no earlier revision was ever published, so the
-- conversions of the timers and state they built are gone (docs/API.md,
-- "Upgrading in place").
--
-- Contents
-- --------
--   Constants ............. package identity, the part layout, option keys
--   Public types .......... LuaCATS declarations for the published surface
--   Dependencies .......... Registry, C_Timer, the monotonic clock;
--                           LifecycleKit and EventKit (optional)
--   Validation ............ public-surface and shared-state validation
--   Bootstrap ............. Registry registration and inherited state
--   Generic helpers ....... error capture, the shared secret-probe and
--                           key-naming blocks, argument validation
--   Timer records ......... the nine array slots of a timer
--   Method-name callbacks . the receiver-and-method form
--   Timer internals ....... start, cancel, fire, restart, deadlines
--   Scope internals ....... active-set bookkeeping, bulk cancel, close
--   Logout coverage ....... who closes an addon scope at logout, decided at
--                           the first ForAddon (LifecycleKit, EventKit, none)
--   Timer public methods .. the handle a timer owner receives
--   Scope public methods .. the handle a scope owner receives
--   Package public API .... the facade published through Registry
--   Parts ................. HasPart, the stubs of absent parts, the helpers
--                           a part calls
--   Commit ................ prototype/facade assignment and self-check

local PACKAGE_NAME = "timerKit"
local API_GENERATION = 1
local IMPLEMENTATION_REVISION = 15
local REQUIRED_REGISTRY_API = 2
local STATE_SCHEMA = 1

-- The upgrade floor: the oldest revision whose state this one takes over in
-- place. Revisions before it were never published (docs/API.md, "Upgrading
-- in place"); meeting one is refused at load with a message that says so.
local OLDEST_UPGRADABLE_REVISION = 14

-- The interface the core offers its parts: `state.parts`, `state.helpers` and
-- the `state.dispatch` entries a part fills. Entries are only ever added; a
-- core that has to change one adds a new entry and raises this number.
local PART_INTERFACE = 1

-- Each part, the file an author embeds for it, and the `Timer` members it
-- provides. Without the part those members are stubs that name the file.
local CORE_FILE = "timerKit\\TimerKit.lua"
local PART_LAYOUT = {
  {
    name = "Pausing",
    file = "timerKit\\parts\\TimerKit-Pausing.lua",
    timer = { "Pause", "Resume", "IsPaused" },
  },
}

-- LifecycleKit and EventKit are optional. Each is found through
-- `Registry:Find` when an addon asks for its scope, only to arrange that the
-- scope is closed at logout; TimerKit never depends on either.
local OPTIONAL_LIFECYCLE_KIT_API = 1
local OPTIONAL_EVENT_KIT_API = 1
local LOGOUT_EVENT = "PLAYER_LOGOUT"

-- How an addon scope is closed at logout, recorded on the scope as
-- `_logoutRoute`. `false` means "not decided yet"; `LOGOUT_ROUTE_NONE` is
-- re-examined at the next `ForAddon`, because a Kit loaded later may make
-- logout observable.
local LOGOUT_ROUTE_LIFECYCLE = "lifecycleKit"
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

---Logical state of a TimerKit timer; `"paused"` from revision 12.
---@alias TimerKit.TimerState "idle"|"running"|"paused"|"completed"|"cancelled"

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
---@field Pause fun(self: TimerKit.Timer): boolean Pausing part.
---@field Resume fun(self: TimerKit.Timer): boolean Pausing part.
---@field IsPaused fun(self: TimerKit.Timer): boolean Pausing part.

---An ownership scope for timers, closed by its owner or, for an addon scope,
---through `TimerKit:CloseAddonScopes`.
---@class TimerKit.Scope
---@field New fun(self: TimerKit.Scope, options: TimerKit.TimerOptions): TimerKit.Timer
---@field After (fun(self: TimerKit.Scope, delay: number, callback: TimerKit.Callback): TimerKit.Timer)|(fun(self: TimerKit.Scope, delay: number, receiver: table, methodName: string): TimerKit.Timer)
---@field Every (fun(self: TimerKit.Scope, interval: number, callback: TimerKit.Callback): TimerKit.Timer)|(fun(self: TimerKit.Scope, interval: number, receiver: table, methodName: string): TimerKit.Timer)
---@field CancelAll fun(self: TimerKit.Scope): integer
---@field Close fun(self: TimerKit.Scope): boolean
---@field Reopen fun(self: TimerKit.Scope): boolean
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
---@field After (fun(self: TimerKit, delay: number, callback: TimerKit.Callback): TimerKit.Timer)|(fun(self: TimerKit, delay: number, receiver: table, methodName: string): TimerKit.Timer)
---@field Every (fun(self: TimerKit, interval: number, callback: TimerKit.Callback): TimerKit.Timer)|(fun(self: TimerKit, interval: number, receiver: table, methodName: string): TimerKit.Timer)
---@field CreateScope fun(self: TimerKit): TimerKit.Scope
---@field ForAddon fun(self: TimerKit, addonName: string): TimerKit.Scope
---@field CloseAddonScopes fun(self: TimerKit, addonName: string): boolean
---@field HasPart fun(self: TimerKit, name: string): boolean `true` when the named part ("Pausing") is installed

---A timer as TimerKit stores it: the public handle plus
---nine array slots only TimerKit reads and writes (docs/INTERNALS.md, "Timer
---record"). Internal functions take this type; `TimerKit.Timer` above stays
---the published contract.
---@class TimerKit.TimerRecord : TimerKit.Timer
---@field [1] integer Creation order within the session.
---@field [2] TimerKit.ScopeRecord The owning scope.
---@field [3] TimerKit.Callback The callback.
---@field [4] number The delay or repeat interval.
---@field [5] TimerKit.TimerState The logical state.
---@field [6] any The host handle while running, `false` otherwise.
---@field [7] number|false The deadline while running, the remainder while paused.
---@field [8] true? `true` on a repeating timer, `nil` on a one-shot.
---@field [9] any The owner's user data.

---A scope as TimerKit stores it.
---@class TimerKit.ScopeRecord : TimerKit.Scope
---@field _addonName string?
---@field _active table<TimerKit.TimerRecord, true>
---@field _activeCount integer
---@field _closed boolean
---@field _logoutRoute string|false?

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
    and type(rawget(implementation, "HasPart")) == "function"
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
    and type(rawget(Timer, "Pause")) == "function"
    and type(rawget(Timer, "Resume")) == "function"
    and type(rawget(Timer, "IsPaused")) == "function"
    and type(rawget(Scope, "New")) == "function"
    and type(rawget(Scope, "After")) == "function"
    and type(rawget(Scope, "Every")) == "function"
    and type(rawget(Scope, "CancelAll")) == "function"
    and type(rawget(Scope, "Close")) == "function"
    and type(rawget(Scope, "Reopen")) == "function"
    and type(rawget(Scope, "IsClosed")) == "function"
    and type(rawget(Scope, "GetAddonName")) == "function"
    and type(rawget(Scope, "GetActiveCount")) == "function"
end

---Whether `currentState` has the fields revision 14 and this revision share,
---the state shape an in-place upgrade starts from.
---@param currentState any
---@return boolean
local function validateStateBase(currentState)
  return type(currentState) == "table"
    and rawget(currentState, "schema") == STATE_SCHEMA
    and type(rawget(currentState, "addonScopes")) == "table"
    and type(rawget(currentState, "dispatch")) == "table"
    and type(rawget(currentState, "nextTimerId")) == "number"
    and type(rawget(currentState, "runtimeRevision")) == "number"
    and type(rawget(currentState, "timerRecordMetatable")) == "table"
    and type(rawget(currentState, "scopeMetatable")) == "table"
    and rawget(currentState, "logoutConnection") ~= nil
    and rawget(currentState, "logoutEventScope") ~= nil
end

---Whether `implementation` carries package state of this revision's schema.
---@param implementation table
---@return boolean
local function validateCurrentState(implementation)
  local currentState = rawget(implementation, "_state")
  return validateStateBase(currentState)
    and type(rawget(currentState, "defaultScope")) == "table"
    and type(rawget(currentState, "parts")) == "table"
    and type(rawget(currentState, "helpers")) == "table"
    and rawget(currentState, "partInterface") == PART_INTERFACE
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
    -- The metatables of every timer (nine array slots, see "Timer records")
    -- and every scope. Shared by every revision, so handles survive upgrades.
    timerRecordMetatable = {},
    scopeMetatable = {},
    -- The one EventKit `PLAYER_LOGOUT` connection that closes addon scopes
    -- when no LifecycleKit does, and the EventKit scope that owns it;
    -- `false` until an addon needs them.
    logoutConnection = false,
    logoutEventScope = false,
    -- The part interface: the installed parts by name (each `{ revision }`),
    -- the core functions a part calls, read at call time so a core upgraded
    -- after a part loaded serves it, and the interface number a part checks.
    parts = {},
    helpers = {},
    partInterface = PART_INTERFACE,
  }
  rawset(TimerKit, "Timer", Timer)
  rawset(TimerKit, "Scope", Scope)
  rawset(TimerKit, "_state", state)
elseif previousRevision < OLDEST_UPGRADABLE_REVISION then
  error(
    "MoltenCodes TimerKit revision "
      .. IMPLEMENTATION_REVISION
      .. " upgrades in place from revision "
      .. OLDEST_UPGRADABLE_REVISION
      .. " or later only; an addon embeds revision "
      .. tostring(previousRevision)
      .. ", which was never published",
    2
  )
elseif type(Timer) ~= "table" or type(Scope) ~= "table" or not validateStateBase(state) then
  error("MoltenCodes TimerKit package state is corrupted or incomplete", 2)
end

-- Revision 15 adds the part interface without a schema change; revision 14
-- state does not have it yet.
if state.parts == nil then
  state.parts = {}
end
if state.helpers == nil then
  state.helpers = {}
end
state.partInterface = PART_INTERFACE

-- `TIMER_METATABLE` marks a TimerKit timer, `SCOPE_METATABLE` a scope. Both
-- have a method-table `__index` and nothing else, so the internal paths read
-- and write their fields by plain indexing.
local TIMER_METATABLE = state.timerRecordMetatable
local SCOPE_METATABLE = state.scopeMetatable
rawset(TIMER_METATABLE, "__index", Timer)
rawset(SCOPE_METATABLE, "__index", Scope)

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
-- secret values. The probe rule (read once at load, again per check only when
-- it was absent then) is the shared block's.

-- shared:begin isSecret 1
-- Copied from tooling/shared/lua/isSecret.lua by python3 -m tooling.shared.sync; edit that file, not this copy.
---Whether `value` is a secret value the host forbids comparing.
---@type fun(value: any): boolean
local isSecret
do
  -- issecretvalue is a client API reachable only through the global table.
  -- selene: allow(global_usage)
  local loadedProbe = rawget(_G, "issecretvalue")
  if type(loadedProbe) ~= "function" then
    loadedProbe = nil
  end

  isSecret = function(value)
    local probe = loadedProbe
    if probe == nil then
      -- selene: allow(global_usage)
      probe = rawget(_G, "issecretvalue")
      if type(probe) ~= "function" then
        return false
      end
    end
    return probe(value) == true
  end
end
-- shared:end isSecret

---Refuse a secret argument before any comparison touches it.
---@param value any
---@param label string argument description, used in the argument error
---@param level integer stack level the failure is reported at
local function refuseSecret(value, label, level)
  if isSecret(value) then
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
  if isSecret(delay) then
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

-- shared:begin describeKey 1
-- Copied from tooling/shared/lua/describeKey.lua by python3 -m tooling.shared.sync; edit that file, not this copy.
---Name `key` for an error message without running any of the caller's code.
---@param key any
---@return string
local function describeKey(key)
  if isSecret(key) then
    return "<secret>"
  end
  local kind = type(key)
  if kind == "string" then
    return key
  end
  if kind == "number" or kind == "boolean" then
    return tostring(key)
  end
  return "<" .. kind .. ">"
end
-- shared:end describeKey

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
      local text = describeKey(key)
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
  -- `getmetatable` answers this metatable for a TimerKit scope only, so no
  -- `type` test is needed in front of it.
  if getmetatable(scope) ~= SCOPE_METATABLE then
    error(methodName .. " must be called on a TimerKit scope", level)
  end
end

---Refuse anything but a TimerKit timer.
---
---`getmetatable` answers this metatable for a TimerKit timer only (it is
---never handed out), so no `type` test is needed in front of it.
---@param timer any receiver the public method was called on
---@param methodName string public method name, used in the argument error
---@param level integer stack level the failure is reported at
local function validateTimer(timer, methodName, level)
  if getmetatable(timer) ~= TIMER_METATABLE then
    error(methodName .. " must be called on a TimerKit timer", level)
  end
end

-- Timer records ---------------------------------------------------------------
--
-- A timer keeps its fields in nine array slots (docs/INTERNALS.md, "Timer
-- record"):
--
--   [1] id        creation order within the session, for bulk cancellation
--   [2] scope     the owning scope
--   [3] callback  the function the timer calls
--   [4] delay     the delay or repeat interval in seconds
--   [5] state     "idle", "running", "paused", "completed" or "cancelled"
--   [6] native    the host handle while running, `false` otherwise
--   [7] deadline  the next fire's instant while running, the remainder while
--                 paused, `false` otherwise
--   [8] repeating `true` on a repeating timer, `nil` on a one-shot
--   [9] userData  the owner's opaque value
--
-- Every timer is built by one constructor that names all nine slots (the
-- last two may be `nil`), so its array part is sized once and `SetUserData`
-- never grows it. Each access names its slot in a comment. The Pausing part
-- reads and writes the same slots.

-- Method-name callbacks -----------------------------------------------------
--
-- `After(delay, receiver, methodName)` and `Every(interval, receiver,
-- methodName)` are AceTimer's `ScheduleTimer("Method", delay)`. The method
-- must exist on the receiver when the timer starts, or the call raises at the
-- caller's line. It is then looked up on the receiver at every fire, as
-- AceTimer does, so a method replaced or hooked after the start is the one
-- that runs. The lookup lives in one closure per timer, which becomes the
-- timer's callback: the per-timer paths stay those of a closure callback.

---Return the callback that calls `receiver[methodName](receiver, timer)`.
---@param receiver table
---@param methodName string
---@return TimerKit.Callback
local function bindMethod(receiver, methodName)
  return function(timer)
    local method = receiver[methodName]
    -- `== nil` rather than `type`: comparing even a secret value with `nil`
    -- answers `false` without raising (docs/EMBEDDING.md, measured on Retail
    -- 12.1.0), and the test is a VM instruction instead of a C call.
    if method == nil then
      error('TimerKit timer receiver has no method "' .. methodName .. '"', 2)
    end
    return method(receiver, timer)
  end
end

---Accept a callback function, or a receiver table followed by a method name
---that names a function on it, and return the function the timer calls.
---@param callback any the third argument of `After` or `Every`
---@param methodName any the fourth argument
---@param label string public method name, used in the argument errors
---@param level integer stack level the failures are reported at
---@return TimerKit.Callback
local function resolveCallback(callback, methodName, label, level)
  local callbackType = type(callback)
  if callbackType == "function" then
    return callback
  end
  if callbackType ~= "table" then
    error(
      label .. " callback must be a function, or a receiver table followed by a method name",
      level
    )
  end
  if isSecret(callback) then
    error(label .. " receiver must not be a secret value", level)
  end
  if isSecret(methodName) then
    error(label .. " methodName must not be a secret value", level)
  end
  if type(methodName) ~= "string" or methodName == "" then
    error(label .. " methodName must be a non-empty string", level)
  end
  if type(callback[methodName]) ~= "function" then
    error(label .. ' receiver has no method "' .. methodName .. '"', level)
  end
  return bindMethod(callback, methodName)
end

-- Timer internals -----------------------------------------------------------
--
-- A timer is a table only TimerKit writes. The per-timer paths below read and
-- write its slots by plain indexing: the timer metatable has no `__newindex`,
-- and the slots a timer may leave empty (`[8]`, `[9]`) fall through `__index`
-- to the `Timer` prototype, which holds only the capitalised public methods
-- and so answers `nil`.
--
-- Stale host callbacks. Every start creates one host handle and one callback
-- closure that remembers it. The callback fires the timer only while the
-- timer is running and its handle slot still holds that very handle. Cancel,
-- restart, pause and a delivered one-shot replace the handle before anything
-- else happens, so a callback from an earlier start can never re-enter the
-- timer, even when the host's own cancellation raised.
--
-- Host callbacks resolve their handler through `state.dispatch` when they
-- run, so a callback created before an in-place upgrade runs the newer
-- revision's code: `fireStarted` for a start, `fireResumed` (the Pausing
-- part's) for the one-shot of a resume.

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
---@return boolean cancelled `false` when the timer was neither running nor paused.
local function cancelTimer(timer)
  -- A paused timer is cancelled like a running one; it holds no handle.
  local timerState = timer[5] --[[state]]
  if timerState ~= "running" and timerState ~= "paused" then
    return false
  end

  -- Unbind the host callback before asking the host to cancel. Even if the
  -- host cancellation itself errors, a stale callback cannot re-enter the
  -- logical timer after this point.
  local native = timer[6] --[[native]]
  timer[6] --[[native]] = false
  timer[5] --[[state]] = "cancelled"
  timer[7] --[[deadline]] = false
  detachActive(timer[2] --[[scope]], timer)

  -- The handle is trusted to have `Cancel` (docs/API.md, "Native
  -- boundary"): a handle without one raises here, after the logical
  -- cancellation above is complete. A paused timer holds `false`.
  if native then
    native:Cancel()
  end
  return true
end

---Deliver the callback of the start that created host handle `native`,
---ignoring it unless that start is still the timer's current one.
---
---This is the path of every fire, so the stale check, the delivery and the
---active-set bookkeeping are written out in one frame.
---@param timer TimerKit.TimerRecord
---@param native table|userdata the handle the firing callback was created for
---@return boolean fired
local function fireTimer(timer, native)
  -- `rawequal`: an identity test that never runs a host `__eq`.
  if
    timer[5] --[[state]]
      ~= "running"
    or not rawequal(timer[6] --[[native]], native)
  then
    return false
  end

  if
    timer[8] --[[repeating]]
    == true
  then
    -- The host re-arms a ticker relative to the tick it just delivered, so
    -- the next deadline is one interval from now, not from the first start.
    if nativeGetTimePreciseSec ~= nil then
      timer[7] --[[deadline]] = nativeGetTimePreciseSec() + timer[4] --[[delay]]
    end
  else
    timer[6] --[[native]] = false
    timer[5] --[[state]] = "completed"
    timer[7] --[[deadline]] = false
    local scope = timer[2] --[[scope]]
    local active = scope._active
    if active[timer] == true then
      active[timer] = nil
      scope._activeCount = scope._activeCount - 1
    end
  end

  timer
    [3] --[[callback]](timer)
  return true
end

---Bind a fresh host callback to `timer` and ask the host for its handle.
---
---The caller has checked that the timer is not running and its scope is open;
---`level` identifies the public caller so a missing host handle is reported at
---its line.
---
---The host is asked first and the timer marked running only once it has
---answered, so a constructor that raises leaves the timer exactly as it was
---and its error object reaches the caller unchanged, with no `pcall` on the
---start path. The handle is trusted: TimerKit does not check that it has a
---`Cancel` method (docs/API.md, "Native boundary"). Only a missing handle is
---refused, because the stale-callback check compares the handle slot with the
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
    return state.dispatch.fireStarted(timer, native)
  end

  local delay = timer[4] --[[delay]]
  local constructor = timer[8] --[[repeating]] == true and nativeNewTicker or nativeNewTimer
  local handle = constructor(delay, callback)
  if not handle then
    error("MoltenCodes TimerKit host returned an invalid native timer handle", level)
  end

  native = handle
  timer[6] --[[native]] = handle
  timer[5] --[[state]] = "running"
  -- Record the timer as running in its scope. Inline: every start takes this path.
  local active = scope._active
  if active[timer] ~= true then
    active[timer] = true
    scope._activeCount = scope._activeCount + 1
  end
  if nativeGetTimePreciseSec ~= nil then
    timer[7] --[[deadline]] = nativeGetTimePreciseSec() + delay
  end
end

-- The caller has already validated `timer`; `level` identifies that caller so a
-- closed-scope or invalid-host-handle failure still reports at its line.
---Start `timer` and bind a fresh host callback to the handle it creates.
---@param timer TimerKit.TimerRecord
---@param methodName string public method name, used in the argument error
---@param level integer stack level the failure is reported at
---@return boolean started `false` when the timer was already running or paused.
local function startTimer(timer, methodName, level)
  local previousState = timer[5] --[[state]]
  if previousState == "running" or previousState == "paused" then
    return false
  end

  local scope = timer[2] --[[scope]]
  if scope._closed == true then
    error(methodName .. " cannot start a timer in a closed scope", level)
  end

  -- The handle slot holds no handle while the host constructor runs.
  timer[6] --[[native]] = false
  armTimer(timer, scope, level + 1)
  return true
end

---Cancel `timer` when it is running or paused, then start it again.
---@param timer TimerKit.TimerRecord
---@param methodName string public method name, used in the argument error
---@param level integer stack level the failure is reported at
---@return boolean started
local function restartTimer(timer, methodName, level)
  local scope = timer[2] --[[scope]]
  if scope._closed == true then
    error(methodName .. " cannot restart a timer in a closed scope", level)
  end

  local timerState = timer[5] --[[state]]
  if timerState == "running" or timerState == "paused" then
    cancelTimer(timer)
  end
  return startTimer(timer, methodName, level + 1)
end

---Build one idle timer. The caller owns all validation.
---
---The constructor names all nine slots, the last two possibly `nil`, so the
---array part is sized once for every timer and `SetUserData` never grows it.
---@param scope TimerKit.ScopeRecord
---@param delay number
---@param callback TimerKit.Callback
---@param repeating boolean
---@return TimerKit.TimerRecord
local function constructTimer(scope, delay, callback, repeating)
  -- The per-session identifier orders bulk cancellation by creation.
  local id = state.nextTimerId + 1
  state.nextTimerId = id
  return setmetatable({
    id,
    scope,
    callback,
    delay,
    "idle",
    false,
    false,
    repeating or nil,
    nil,
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

---Build, arm and record a timer whose arguments the caller has accepted.
---
---`After` and `Every` reach this from their one-condition fast path, so the
---whole start is two Lua frames: construction and the host request are
---written out here rather than split across `constructTimer` and `armTimer`.
---@param scope TimerKit.ScopeRecord an open scope
---@param delay number
---@param callback TimerKit.Callback
---@param repeating boolean
---@param level integer stack level an invalid host handle is reported at
---@return TimerKit.TimerRecord
local function launchTimer(scope, delay, callback, repeating, level)
  local id = state.nextTimerId + 1
  state.nextTimerId = id
  local timer = setmetatable({
    id,
    scope,
    callback,
    delay,
    "idle",
    false,
    false,
    repeating or nil,
    nil,
  }, TIMER_METATABLE)

  -- As in `armTimer`: the host is asked first, and its callback ignores a
  -- call made before the handle is known.
  local native
  local constructor = repeating and nativeNewTicker or nativeNewTimer
  local handle = constructor(delay, function()
    return state.dispatch.fireStarted(timer, native)
  end)
  if not handle then
    error("MoltenCodes TimerKit host returned an invalid native timer handle", level)
  end

  native = handle
  timer[6] --[[native]] = handle
  timer[5] --[[state]] = "running"
  scope._active[timer] = true
  scope._activeCount = scope._activeCount + 1
  if nativeGetTimePreciseSec ~= nil then
    timer[7] --[[deadline]] = nativeGetTimePreciseSec() + delay
  end
  return timer
end

-- The slow path of `Scope:After`/`Scope:Every` and their package-level
-- counterparts: every argument is validated in order, so the fast path's
-- single condition only decides that a check failed and this function says
-- which one, at the caller's line. Method-name callbacks always come here.
---@param scope TimerKit.ScopeRecord
---@param delay any
---@param callback any
---@param methodName any
---@param repeating boolean
---@param label string public method name, used in the argument errors
---@param level integer stack level the failures are reported at
---@return TimerKit.Timer
local function startTimerInScope(scope, delay, callback, methodName, repeating, label, level)
  validateScope(scope, label, level + 1)
  if scope._closed == true then
    error(label .. " cannot create a timer in a closed scope", level)
  end
  local resolved = resolveCallback(callback, methodName, label, level + 1)
  validateDelay(delay, repeating, label, level + 1)
  local timer = launchTimer(scope, delay, resolved, repeating, level + 1)
  return timer
end

-- Scope internals -----------------------------------------------------------

---Order two timers by creation. File-level, so a bulk cancel allocates only
---its snapshot.
---@param left TimerKit.Timer
---@param right TimerKit.Timer
---@return boolean
local function createdBefore(left, right)
  return left[1] --[[id]] < right[1] --[[id]]
end

---Return every running or paused timer of `scope`, ordered by creation, as a
---snapshot.
---@param scope TimerKit.ScopeRecord
---@return TimerKit.TimerRecord[]
local function snapshotActive(scope)
  local timers = {}
  for timer in pairs(scope._active) do
    timers[#timers + 1] = timer
  end
  table.sort(timers, createdBefore)
  return timers
end

-- Internal bulk cancellation. The caller owns validation, so scope cleanup
-- driven by `CloseAddonScopes` does not have to fake a public call site.
---@param scope TimerKit.ScopeRecord
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

---Terminally close `scope` after best-effort cancellation.
---
---A timer callback may close its own scope, including through
---`CloseAddonScopes`; the timer that is firing is cancelled like the rest,
---which for a ticker means it does not tick again.
---@param scope TimerKit.ScopeRecord
---@return boolean closed `false` when the scope was already closed.
local function closeScope(scope)
  if scope._closed == true then
    return false
  end

  -- Make the scope terminal before cleanup begins. Callback re-entry cannot
  -- schedule replacement timers while the close is in progress.
  scope._closed = true

  local ok, cancelError = pcall(cancelAllInScope, scope)
  raiseCaptured(captureFirstError(nil, ok, cancelError))
  return true
end

---Build one open scope. `addonName` is `nil` for a manually owned scope.
---@param addonName string|nil
---@return TimerKit.ScopeRecord
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
--   3. No such LifecycleKit, but EventKit: one package-level `PLAYER_LOGOUT`
--      connection, in an EventKit scope of TimerKit's own, closes every
--      addon scope route 1 does not cover.
--   4. Neither: nothing is subscribed, and the addon calls
--      `CloseAddonScopes` itself. This outcome is examined again at the next
--      `ForAddon`, since a Kit loaded later can change it.
--
-- The numbers are the documented ones (docs/API.md, "At logout"). Route 2, an
-- `OnShutdown` subscription per addon for a LifecycleKit before revision 13,
-- is gone with the upgrade floor: no such LifecycleKit was ever published.
-- The `PLAYER_LOGOUT` connection's callback resolves TimerKit's behaviour
-- through `state.dispatch` when it runs, so a newer revision upgrades it in
-- place.

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

---Close, at `PLAYER_LOGOUT`, every addon scope route 1 does not cover (route
---3), in addon-name order. Every scope is attempted; the first failure is
---re-raised afterwards, and EventKit reports it through the host error
---handler.
local function closeOnLogout()
  state.logoutConnection = false

  local addonScopes = state.addonScopes
  local names = {}
  for addonName in pairs(addonScopes) do
    names[#names + 1] = addonName
  end
  table.sort(names)

  local firstError
  for index = 1, #names do
    local scope = addonScopes[names[index]]
    if scope._logoutRoute ~= LOGOUT_ROUTE_LIFECYCLE then
      local ok, closeError = pcall(closeScope, scope)
      firstError = captureFirstError(firstError, ok, closeError)
    end
  end
  raiseCaptured(firstError)
end

---Whether the package-level `PLAYER_LOGOUT` connection is live.
---@return boolean
local function hasLogoutConnection()
  local connection = state.logoutConnection
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
    local ownScope = state.logoutEventScope
    if type(ownScope) ~= "table" or ownScope:IsClosed() then
      ownScope = EventKit:CreateScope()
    end
    local logoutConnection = ownScope:Once(LOGOUT_EVENT, function()
      local handler = state.dispatch.closeOnLogout
      if type(handler) == "function" then
        handler()
      end
    end)
    return ownScope, logoutConnection
  end)
  if not ok or type(connection) ~= "table" then
    return false
  end
  state.logoutEventScope = eventScope
  state.logoutConnection = connection
  return true
end

---Decide who closes `scope` at logout, unless that is already decided.
---
---Called by `ForAddon` for every scope it returns, so the common case costs one
---field read. Only an undecided scope, or one nobody could close before, looks
---for LifecycleKit and EventKit.
---@param scope TimerKit.ScopeRecord an addon scope
local function ensureLogoutRoute(scope)
  local route = scope._logoutRoute
  if (route ~= false and route ~= LOGOUT_ROUTE_NONE) or scope._closed == true then
    return
  end

  local LifecycleKit = findOptionalPackage("lifecycleKit", OPTIONAL_LIFECYCLE_KIT_API)
  if type(LifecycleKit) ~= "nil" and lifecycleClosesAddonScopes(LifecycleKit) then
    -- LifecycleKit closes the scopes of the addons it has an instance for, so
    -- make sure this addon has one. Nothing is subscribed; a refusal only
    -- leaves the addon unknown to it.
    pcall(function()
      LifecycleKit:ForAddon(scope._addonName)
    end)
    scope._logoutRoute = LOGOUT_ROUTE_LIFECYCLE
    return
  end

  if ensureLogoutConnection() then
    scope._logoutRoute = LOGOUT_ROUTE_EVENT
    return
  end
  scope._logoutRoute = LOGOUT_ROUTE_NONE
end

-- Timer public methods ------------------------------------------------------

---Return the logical timer state.
---@param self TimerKit.TimerRecord
---@return TimerKit.TimerState state
local function timerGetState(self)
  validateTimer(self, "TimerKit.Timer:GetState", 3)
  return self[5] --[[state]]
end

---Return the configured delay or repeat interval in seconds.
---@param self TimerKit.TimerRecord
---@return number seconds
local function timerGetDelay(self)
  validateTimer(self, "TimerKit.Timer:GetDelay", 3)
  return self[4] --[[delay]]
end

---Return the scope that owns this timer.
---@param self TimerKit.TimerRecord
---@return TimerKit.Scope scope
local function timerGetScope(self)
  validateTimer(self, "TimerKit.Timer:GetScope", 3)
  return self[2] --[[scope]]
end

---Return the opaque value attached to this timer, or `nil` when none is set.
---@param self TimerKit.TimerRecord
---@return any userData
local function timerGetUserData(self)
  validateTimer(self, "TimerKit.Timer:GetUserData", 3)
  return self[9] --[[userData]]
end

---Attach one opaque value to this timer. TimerKit stores the reference and
---never reads, copies, or clears it; passing `nil` detaches it again.
---@param self TimerKit.TimerRecord
---@param value any
---@return TimerKit.Timer self
local function timerSetUserData(self, value)
  validateTimer(self, "TimerKit.Timer:SetUserData", 3)
  self[9] --[[userData]] = value
  return self
end

---Return whether the timer repeats instead of firing once.
---@param self TimerKit.TimerRecord
---@return boolean repeating
local function timerIsRepeating(self)
  validateTimer(self, "TimerKit.Timer:IsRepeating", 3)
  return self[8] --[[repeating]] == true
end

---Return whether the logical timer is currently running; a paused timer is not.
---@param self TimerKit.TimerRecord
---@return boolean pending
local function timerIsPending(self)
  validateTimer(self, "TimerKit.Timer:IsPending", 3)
  return self[5] --[[state]] == "running"
end

---Return whether the timer was logically cancelled.
---@param self TimerKit.TimerRecord
---@return boolean cancelled
local function timerIsCancelled(self)
  validateTimer(self, "TimerKit.Timer:IsCancelled", 3)
  return self[5] --[[state]] == "cancelled"
end

---Start an idle, completed, or cancelled timer.
---@param self TimerKit.TimerRecord
---@return boolean started `false` when the timer was already running or paused.
local function timerStart(self)
  validateTimer(self, "TimerKit.Timer:Start", 3)
  return startTimer(self, "TimerKit.Timer:Start", 3)
end

---Cancel a running or paused timer.
---@param self TimerKit.TimerRecord
---@return boolean cancelled `false` when the timer was neither running nor paused.
local function timerCancel(self)
  -- `validateTimer` and `cancelTimer`, written out: `Cancel` is the one timer
  -- method on the start-and-cancel path. The validator runs only to raise.
  if getmetatable(self) ~= TIMER_METATABLE then
    validateTimer(self, "TimerKit.Timer:Cancel", 3)
  end
  local timerState = self[5] --[[state]]
  if timerState ~= "running" and timerState ~= "paused" then
    return false
  end
  -- Unbound before the host is asked, as in `cancelTimer`.
  local native = self[6] --[[native]]
  self[6] --[[native]] = false
  self[5] --[[state]] = "cancelled"
  self[7] --[[deadline]] = false
  local scope = self[2] --[[scope]]
  local active = scope._active
  if active[self] == true then
    active[self] = nil
    scope._activeCount = scope._activeCount - 1
  end
  if native then
    native:Cancel()
  end
  return true
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
  if
    self[5] --[[state]]
    ~= "running"
  then
    return nil
  end
  local deadline = self[7] --[[deadline]]
  if type(deadline) ~= "number" then
    -- Started on a host without `GetTimePreciseSec`; see API.md.
    return nil
  end
  return deadline
end

---Return the seconds left until this timer fires next, the seconds it kept
---when paused, or `nil` when it is neither running nor paused. Never
---negative: a timer the host has not delivered yet although its deadline
---passed reports `0`.
---@param self TimerKit.TimerRecord
---@return number? remaining seconds, an estimate; see `GetDeadline`
local function timerGetRemaining(self)
  validateTimer(self, "TimerKit.Timer:GetRemaining", 3)
  local timerState = self[5] --[[state]]
  if timerState == "paused" then
    -- A paused timer keeps its remainder in the deadline slot (Pausing part).
    return self[7] --[[@as number]]
  end
  if timerState ~= "running" then
    return nil
  end
  local deadline = self[7] --[[deadline]]
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

-- `After` and `Every` test every argument in one condition: the receiver,
-- the closed state, the callback, the delay's type, the secret probe (before
-- any comparison touches the delay) and its range. `delay >= 0 and delay <
-- HUGE` is false for NaN and both infinities. Only when the condition fails,
-- or for a method-name callback, does `startTimerInScope` run the validators,
-- which raise the exact message at the caller's line.

---Create and immediately start a one-shot timer in this scope.
---
---`callback` may instead be a receiver table followed by a method name: the
---timer then calls `receiver[methodName](receiver, timer)`, looking the method
---up at every fire (see "Method-name callbacks").
---@param self TimerKit.ScopeRecord
---@param delay number Finite seconds greater than or equal to zero.
---@param callback TimerKit.Callback|table
---@param methodName string? the method's name when `callback` is a receiver
---@return TimerKit.Timer timer
local function scopeAfter(self, delay, callback, methodName)
  if
    getmetatable(self) ~= SCOPE_METATABLE
    or self._closed == true
    or type(callback) ~= "function"
    or type(delay) ~= "number"
    or isSecret(delay)
    or not (delay >= 0 and delay < HUGE)
  then
    return startTimerInScope(self, delay, callback, methodName, false, "TimerKit.Scope:After", 3)
  end
  local timer = launchTimer(self, delay, callback, false, 3)
  return timer
end

---Create and immediately start a repeating timer in this scope.
---
---`callback` may instead be a receiver table followed by a method name, as for
---`After`.
---@param self TimerKit.ScopeRecord
---@param interval number Finite seconds greater than zero.
---@param callback TimerKit.Callback|table
---@param methodName string? the method's name when `callback` is a receiver
---@return TimerKit.Timer timer
local function scopeEvery(self, interval, callback, methodName)
  if
    getmetatable(self) ~= SCOPE_METATABLE
    or self._closed == true
    or type(callback) ~= "function"
    or type(interval) ~= "number"
    or isSecret(interval)
    or not (interval > 0 and interval < HUGE)
  then
    return startTimerInScope(self, interval, callback, methodName, true, "TimerKit.Scope:Every", 3)
  end
  local timer = launchTimer(self, interval, callback, true, 3)
  return timer
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

---Reopen a closed manual scope, so it can own timers again.
---
---A reopened scope is empty and behaves like a new one; the timers its close
---cancelled stay cancelled and can be started again. ModuleKit uses this to
---keep one scope per module across enable cycles. An addon scope is not
---reopened: closing it is its addon's teardown, which stays terminal.
---@param self TimerKit.ScopeRecord
---@return boolean reopened `false` when the scope was open.
local function scopeReopen(self)
  validateScope(self, "TimerKit.Scope:Reopen", 3)
  if self._addonName ~= nil then
    error("TimerKit.Scope:Reopen cannot reopen an addon scope", 2)
  end
  if self._closed ~= true then
    return false
  end
  self._closed = false
  return true
end

---Return whether the scope is terminally closed.
---@param self TimerKit.ScopeRecord
---@return boolean closed
local function scopeIsClosed(self)
  validateScope(self, "TimerKit.Scope:IsClosed", 3)
  return self._closed == true
end

---Return the owning addon name, or `nil` for a manual scope.
---@param self TimerKit.ScopeRecord
---@return string? addonName
local function scopeGetAddonName(self)
  validateScope(self, "TimerKit.Scope:GetAddonName", 3)
  return self._addonName
end

---Return the number of logically running or paused timers owned by this scope.
---@param self TimerKit.ScopeRecord
---@return integer activeCount
local function scopeGetActiveCount(self)
  validateScope(self, "TimerKit.Scope:GetActiveCount", 3)
  return self._activeCount
end

-- Package public API --------------------------------------------------------

---Return TimerKit's internal manual scope, replacing it once it is closed.
---@return TimerKit.ScopeRecord
local function getDefaultScope()
  local scope = state.defaultScope
  if scope == false or scope._closed == true then
    scope = newScope(nil)
    state.defaultScope = scope
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
---The same fast path as `Scope:After`; the package scope is always open.
---@param _ TimerKit
---@param delay number Finite seconds greater than or equal to zero.
---@param callback TimerKit.Callback|table
---@param methodName string? the method's name when `callback` is a receiver
---@return TimerKit.Timer timer
local function packageAfter(_, delay, callback, methodName)
  local scope = getDefaultScope()
  if
    type(callback) ~= "function"
    or type(delay) ~= "number"
    or isSecret(delay)
    or not (delay >= 0 and delay < HUGE)
  then
    return startTimerInScope(scope, delay, callback, methodName, false, "TimerKit:After", 3)
  end
  local timer = launchTimer(scope, delay, callback, false, 3)
  return timer
end

---Create and immediately start a repeating timer in the internal manual scope.
---The same fast path as `Scope:Every`.
---@param _ TimerKit
---@param interval number Finite seconds greater than zero.
---@param callback TimerKit.Callback|table
---@param methodName string? the method's name when `callback` is a receiver
---@return TimerKit.Timer timer
local function packageEvery(_, interval, callback, methodName)
  local scope = getDefaultScope()
  if
    type(callback) ~= "function"
    or type(interval) ~= "number"
    or isSecret(interval)
    or not (interval > 0 and interval < HUGE)
  then
    return startTimerInScope(scope, interval, callback, methodName, true, "TimerKit:Every", 3)
  end
  local timer = launchTimer(scope, interval, callback, true, 3)
  return timer
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

  local addonScopes = state.addonScopes
  local scope = addonScopes[addonName]
  if scope == nil then
    scope = newScope(addonName)
    scope._logoutRoute = false
    addonScopes[addonName] = scope
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
  if isSecret(self) or self ~= TimerKit then
    error(
      "TimerKit:CloseAddonScopes must be called on the TimerKit facade; "
        .. "use TimerKit:CloseAddonScopes(addonName)",
      2
    )
  end
  validateNonEmptyString(addonName, "TimerKit:CloseAddonScopes addonName", 3)

  local scope = state.addonScopes[addonName]
  if scope == nil then
    return false
  end
  return closeScope(scope)
end

-- Parts ---------------------------------------------------------------------
--
-- What the core keeps for its parts, so a part loaded by any addon finds it:
-- `state.parts` (part name to `{ revision }`), `state.helpers` (the core
-- functions a part calls, read at call time, so a core upgraded after the part
-- loaded serves it) and `state.partInterface`. The core reaches a part only
-- through `state.dispatch` entries the part fills (`fireResumed`, `pause`);
-- no host callback that needs one can exist before the part made it.
--
-- Every member a part provides stays on its prototype even without the part:
-- a stub that raises at the caller's line with the file to embed. Other Kits
-- ask `HasPart`, never `type(Timer.Pause) == "function"`, which a stub
-- satisfies.

---A member that raises, at its caller's line, that `part` is not loaded.
---@param label string the member as its caller wrote it
---@param part table one entry of `PART_LAYOUT`
---@return function
local function newPartStub(label, part)
  -- The message is built only when the stub raises, so an addon that never
  -- calls a missing part holds no message text for it.
  return function()
    error(
      label
        .. " is in TimerKit's "
        .. part.name
        .. " part, which is not loaded: add "
        .. part.file
        .. " to embeds.xml after "
        .. CORE_FILE,
      2
    )
  end
end

---Put a stub in place of every member of each part that is not installed. A
---member of an installed part is the part's own and stays.
local function installPartStubs()
  for index = 1, #PART_LAYOUT do
    local part = PART_LAYOUT[index]
    if state.parts[part.name] == nil then
      for memberIndex = 1, #part.timer do
        local member = part.timer[memberIndex]
        rawset(Timer, member, newPartStub("TimerKit.Timer:" .. member, part))
      end
    end
  end
end

---Whether the named part is installed in this session.
---@param _ TimerKit
---@param name string a part name, such as `"Pausing"`
---@return boolean installed
local function hasPart(_, name)
  if isSecret(name) or type(name) ~= "string" then
    error("TimerKit:HasPart name must be a part name string", 2)
  end
  return type(state.parts[name]) == "table"
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
installPartStubs()

rawset(Scope, "New", scopeNew)
rawset(Scope, "After", scopeAfter)
rawset(Scope, "Every", scopeEvery)
rawset(Scope, "CancelAll", scopeCancelAll)
rawset(Scope, "Close", scopeClose)
rawset(Scope, "Reopen", scopeReopen)
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
rawset(TimerKit, "HasPart", hasPart)

if state.defaultScope == false then
  state.defaultScope = newScope(nil)
elseif getmetatable(state.defaultScope) ~= SCOPE_METATABLE then
  error("MoltenCodes TimerKit package state is corrupted or incomplete", 2)
end

-- The core functions the parts call, refreshed by every core revision.
local helpers = state.helpers
helpers.validateTimer = validateTimer
helpers.armTimer = armTimer
helpers.detachActive = detachActive
helpers.fireTimer = fireTimer
helpers.deadlineAfter = deadlineAfter
helpers.now = now
helpers.newOneShotHandle = nativeNewTimer

local dispatch = state.dispatch
-- Host callbacks resolve `fireStarted` when they fire, and the PLAYER_LOGOUT
-- connection resolves `closeOnLogout`, so those an older copy made run this
-- revision's code. `fireResumed` and `pause` belong to the Pausing part. When
-- the part is absent after an upgrade, revision 14's own `fireResumed` stays
-- in place for the resume one-shots that revision armed; it writes the same
-- timer slots and arms the next tick through `fireStarted`.
dispatch.fireStarted = fireTimer
dispatch.closeOnLogout = closeOnLogout
state.runtimeRevision = IMPLEMENTATION_REVISION

if not validatePublicSurface(TimerKit) or not validateCurrentState(TimerKit) then
  error("MoltenCodes TimerKit package state is corrupted or incomplete", 2)
end

-- The upgrade from revision 14, run once in the main chunk. Revision 14 also
-- published `fire` (revision 9 callbacks), `closeScope` (revision 5 shutdown
-- wrappers) and `closeOnShutdown` (route 2); none has a caller this revision
-- can meet, so they go. An addon scope route 2 covered (a LifecycleKit before
-- revision 13, never published) lets go of its `OnShutdown` subscription and
-- is given a route again, as a first `ForAddon` would.
if previousRevision ~= nil then
  dispatch.fire = nil
  dispatch.closeScope = nil
  dispatch.closeOnShutdown = nil
  local rerouted = {}
  for addonName, scope in pairs(state.addonScopes) do
    local subscription = scope._logoutSubscription
    scope._logoutSubscription = nil
    if scope._logoutRoute == "onShutdown" then
      if type(subscription) == "table" then
        pcall(subscription.Disconnect, subscription)
      end
      scope._logoutRoute = false
      rerouted[#rerouted + 1] = addonName
    end
  end
  table.sort(rerouted)
  for index = 1, #rerouted do
    ensureLogoutRoute(state.addonScopes[rerouted[index]])
  end
end

return TimerKit
