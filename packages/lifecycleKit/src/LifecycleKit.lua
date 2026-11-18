-- MoltenCodes LifecycleKit
--
-- Per-addon lifecycle coordination built on MoltenCodes EventKit. LifecycleKit
-- keeps WoW event details at the boundary and exposes replay-aware, one-shot
-- phase subscriptions for addon code, and closes the other Kits' addon scopes
-- when an addon shuts down.
--
-- This file is the core every user of LifecycleKit needs: the phases (loaded,
-- ready, shutdown), their subscriptions and queries, the observers of the
-- halted state (`IsHalted`, `GetHaltReason`, `OnHalted`) and the shutdown of
-- addon scopes. Two optional parts add the rest (docs/decisions/
-- 0001-kit-core-and-parts.md):
--
--   * `parts/LifecycleKit-CombatGate.lua`: the shared lockdown state, the
--     bounded "run when out of combat" queue and the combat notices;
--   * `parts/LifecycleKit-Halt.lua`: `Halt`, `DependsOn` and
--     `OnDependencyHalted`.
--
-- Without a part its members stay on the facade and the prototypes as stubs
-- that raise at the caller's line with the file to embed.
--
-- Contents
-- --------
--   Constants ............. package identity, state schema, default bounds,
--                           the parts and their members
--   Public types .......... LuaCATS classes and aliases for the public surface
--   Dependencies .......... Registry, EventKit; SignalKit, TimerKit,
--                           SchedulerKit, HookKit, CommandKit and CommKit
--                           (optional)
--   Shared helpers ........ isSecret, describeKey, limits (tooling/shared/lua)
--   Public-surface validation  facade shape accepted from other copies
--   Bootstrap ............. Registry registration, prototypes, package state
--   In-place upgrade ...... schema 3 (revision 18) to 4
--   Host-state probes ..... addon load state, login
--   Subscription .......... subscription records and their handle methods
--   Delivery .............. the per-instance subscriber lists, and revision
--                           18's signals on an inherited instance
--   Phase machinery ....... loaded, ready and shutdown transitions, the
--                           closing of addon scopes
--   Shared event coordination  the package-wide host watchers
--   Instance creation ..... ForAddon's slow path
--   Public instance API ... queries and phase subscriptions
--   Public package API .... ForAddon, HasPart, SetLimits, GetLimits
--   Parts ................. stubs, the interface the parts read, an inherited
--                           combat queue without its part
--   Commit ................ prototype/facade assignment, the
--                           CLOSES_ADDON_SCOPES capability and self-check

local PACKAGE_NAME = "lifecycleKit"
local API_GENERATION = 1
local IMPLEMENTATION_REVISION = 19
local REQUIRED_REGISTRY_API = 2
local REQUIRED_EVENT_KIT_API = 1
-- SignalKit, TimerKit, SchedulerKit, HookKit, CommandKit and CommKit are
-- optional: each is found through `Registry:Find` at shutdown (SignalKit also
-- to serve an instance revision 18 made), so an addon that embeds none of them
-- shuts down exactly as before. None of them depends on LifecycleKit;
-- LifecycleKit calls into them (design constitution, 4b).
local OPTIONAL_KIT_API = 1

-- The package ids whose addon scopes (for SignalKit, the addon bus) shutdown
-- closes, in this order, which is also the first-error precedence (see
-- `closeAddonOwnedScopes`). Published read-only as
-- `LifecycleKit.CLOSES_ADDON_SCOPES`: a scope-owning Kit reads it to decide
-- whether LifecycleKit covers its addon scopes at logout or whether it has to
-- arrange that itself. Every revision from 13 on publishes the same set; a
-- revision that stops closing one of them has to drop it from this list.
local CLOSED_ADDON_SCOPE_PACKAGES = {
  "timerKit",
  "schedulerKit",
  "eventKit",
  "hookKit",
  "commandKit",
  "commKit",
  "signalKit",
}

-- The method each package closes an addon's scopes with, when it is not
-- `CloseAddonScopes`.
local CLOSING_METHODS = { signalKit = "CloseAddonBus" }

-- Schema 4 replaced the per-instance SignalKit signals with subscriber lists
-- and added the part interface. Schema 3 (revision 18) is migrated in place;
-- older state is refused (the upgrade floor, docs/API.md).
local STATE_SCHEMA = 4
local PREVIOUS_STATE_SCHEMA = 3

-- The interface the parts read: `state.helpers`, `state.dispatch`,
-- `state.parts`. A part refuses to load against a core whose number is lower
-- than the one it was written for.
local PART_INTERFACE = 1

-- How many deferred calls one addon may have waiting for the end of combat,
-- unless changed (CombatGate part). How many other addons one addon may declare
-- with `DependsOn`, unless changed (Halt part). Both limits stay in the core's
-- table, so `SetLimits`/`GetLimits` keep one shape with or without the parts.
local DEFAULT_COMBAT_QUEUE_LIMIT = 64
local DEFAULT_MAX_DEPENDENCIES = 16

-- The largest value `SetLimits` accepts for either limit. Both lists belong to
-- one addon and accept `UNBOUNDED`, so the ceiling only refuses a mistaken
-- number; it is the largest 32-bit signed integer.
local LIMIT_CEILING = 2147483647

-- The phases whose subscriptions are spent by their one delivery.
local ONE_SHOT_KEYS = { loaded = true, ready = true, shutdown = true, halted = true }

-- The parts, and the members each provides, by the table they sit on.
local PART_LAYOUT = {
  {
    name = "CombatGate",
    facade = { "IsInCombat" },
    instance = {
      "WhenOutOfCombat",
      "OnCombatStart",
      "OnCombatEnd",
      "SetCombatQueueLimit",
      "GetCombatQueueLimit",
    },
    deferredCall = { "Cancel", "IsPending" },
  },
  {
    name = "Halt",
    facade = {},
    instance = { "Halt", "DependsOn", "OnDependencyHalted" },
    deferredCall = {},
  },
}

-- Public types --------------------------------------------------------------
--
-- LifecycleKit publishes its methods by writing them onto Registry-owned
-- prototype tables, so the editor-facing contract is declared here as LuaCATS
-- classes rather than inferred from those assignments.

---Lifecycle state reported by `Instance:GetState()`.
---@alias LifecycleKit.State
---| "loading"   # the addon's `ADDON_LOADED` has not been observed yet
---| "loaded"    # `ADDON_LOADED` completed for this addon
---| "ready"     # the addon is loaded and the player is logged in
---| "shutdown"  # `PLAYER_LOGOUT` was observed
---| "halted"    # the addon called `Halt`; terminal for the session

---A callback invoked once for the phase it subscribed to.
---@alias LifecycleKit.PhaseCallback fun(instance: LifecycleKit.Instance)

---A callback invoked once when the addon halts.
---@alias LifecycleKit.HaltedCallback fun(instance: LifecycleKit.Instance, reason: string)

---A callback invoked each time a declared dependency halts (Halt part).
---@alias LifecycleKit.DependencyHaltedCallback fun(instance: LifecycleKit.Instance, dependencyName: string, reason: string)

---A callback invoked on every combat start or combat end (CombatGate part).
---@alias LifecycleKit.CombatCallback fun(instance: LifecycleKit.Instance)

---A deferred call: `ran` is `true` when it ran out of combat, and `false` with
---a reason when the queue was closed before it could run (CombatGate part).
---@alias LifecycleKit.DeferredCallback fun(instance: LifecycleKit.Instance, ran: boolean, reason: "shutdown"|"halted"|nil)

---An error object wrapped so that `nil` and `false` stay representable.
---@class LifecycleKit.ErrorRecord
---@field value any the original Lua error object

---The per-addon lifecycle handle returned by `LifecycleKit:ForAddon`.
---@class LifecycleKit.Instance
---@field GetAddonName fun(self: LifecycleKit.Instance): string
---@field GetState fun(self: LifecycleKit.Instance): LifecycleKit.State
---@field IsLoaded fun(self: LifecycleKit.Instance): boolean
---@field IsReady fun(self: LifecycleKit.Instance): boolean
---@field IsShutdown fun(self: LifecycleKit.Instance): boolean
---@field IsHalted fun(self: LifecycleKit.Instance): boolean
---@field GetHaltReason fun(self: LifecycleKit.Instance): string|nil
---@field OnLoaded fun(self: LifecycleKit.Instance, callback: LifecycleKit.PhaseCallback): LifecycleKit.Subscription
---@field OnReady fun(self: LifecycleKit.Instance, callback: LifecycleKit.PhaseCallback): LifecycleKit.Subscription
---@field OnShutdown fun(self: LifecycleKit.Instance, callback: LifecycleKit.PhaseCallback): LifecycleKit.Subscription
---@field OnHalted fun(self: LifecycleKit.Instance, callback: LifecycleKit.HaltedCallback): LifecycleKit.Subscription
---@field Halt fun(self: LifecycleKit.Instance, reason: string): boolean Halt part.
---@field DependsOn fun(self: LifecycleKit.Instance, addonName: string): boolean|nil, string|nil Halt part.
---@field OnDependencyHalted fun(self: LifecycleKit.Instance, callback: LifecycleKit.DependencyHaltedCallback): LifecycleKit.Subscription Halt part.
---@field WhenOutOfCombat fun(self: LifecycleKit.Instance, callback: LifecycleKit.DeferredCallback): LifecycleKit.DeferredCall|nil, string|nil CombatGate part.
---@field OnCombatStart fun(self: LifecycleKit.Instance, callback: LifecycleKit.CombatCallback): LifecycleKit.Subscription CombatGate part.
---@field OnCombatEnd fun(self: LifecycleKit.Instance, callback: LifecycleKit.CombatCallback): LifecycleKit.Subscription CombatGate part.
---@field SetCombatQueueLimit fun(self: LifecycleKit.Instance, limit: integer|table) CombatGate part.
---@field GetCombatQueueLimit fun(self: LifecycleKit.Instance): integer|table CombatGate part.

---A subscription handle: one-shot for phases, repeating for combat and
---dependency notifications.
---@class LifecycleKit.Subscription
---@field Disconnect fun(self: LifecycleKit.Subscription): boolean
---@field IsConnected fun(self: LifecycleKit.Subscription): boolean

---A call waiting in an addon's combat queue (CombatGate part).
---@class LifecycleKit.DeferredCall
---@field Cancel fun(self: LifecycleKit.DeferredCall): boolean
---@field IsPending fun(self: LifecycleKit.DeferredCall): boolean

---The LifecycleKit package facade published through Registry.
---@class LifecycleKit
---@field API integer Public API generation.
---@field REVISION integer Compatible implementation revision.
---@field Instance LifecycleKit.Instance Shared lifecycle-instance prototype.
---@field Subscription LifecycleKit.Subscription Shared subscription prototype.
---@field DeferredCall LifecycleKit.DeferredCall Shared deferred-call prototype.
---@field ForAddon fun(self: LifecycleKit, addonName: string): LifecycleKit.Instance
---@field IsInCombat fun(self: LifecycleKit): boolean CombatGate part.
---@field HasPart fun(self: LifecycleKit, name: string): boolean Whether the named part (`"CombatGate"`, `"Halt"`) is installed.
---@field UNBOUNDED table Sentinel a limit takes to be lifted.
---@field SetLimits fun(self: LifecycleKit, limits: table)
---@field GetLimits fun(self: LifecycleKit): LifecycleKit.Limits
---@field CLOSES_ADDON_SCOPES table<string, boolean> Read-only set of the package ids whose addon scopes (or, for `signalKit`, bus) shutdown closes.

---The package-wide limits. `SetLimits` accepts any subset; `GetLimits` returns
---a fresh copy of all of them.
---@class LifecycleKit.Limits
---@field maxDependencies integer|table Addons one addon may declare with `DependsOn`: an integer from 1 to 2147483647 or `LifecycleKit.UNBOUNDED`; default `16`.
---@field defaultCombatQueueLimit integer|table The combat-queue limit new instances start with: an integer from 1 to 2147483647 or `LifecycleKit.UNBOUNDED`; default `64`.

-- Dependencies --------------------------------------------------------------

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
  error("MoltenCodes LifecycleKit requires Registry API 2 to be loaded first", 2)
end

local bootstrapPackage = rawget(Registry, "Bootstrap")
local getPackage = rawget(Registry, "Get")
if type(bootstrapPackage) ~= "function" or type(getPackage) ~= "function" then
  error("MoltenCodes LifecycleKit requires a valid Registry API 2 facade", 2)
end

local EventKit, eventKitRevision = getPackage(Registry, "eventKit", REQUIRED_EVENT_KIT_API)
if type(EventKit) == "nil" then
  error("MoltenCodes LifecycleKit requires EventKit API 1 to be loaded first", 2)
end
local EventKitConnection = type(EventKit) == "table" and rawget(EventKit, "Connection") or nil
if
  type(EventKit) ~= "table"
  or type(eventKitRevision) ~= "number"
  or rawget(EventKit, "API") ~= REQUIRED_EVENT_KIT_API
  or rawget(EventKit, "REVISION") ~= eventKitRevision
  or type(rawget(EventKit, "Connect")) ~= "function"
  or type(rawget(EventKit, "Once")) ~= "function"
  or type(EventKitConnection) ~= "table"
  or type(rawget(EventKitConnection, "Disconnect")) ~= "function"
then
  error("MoltenCodes LifecycleKit requires a valid EventKit API 1 facade", 2)
end

---Silent lookup of an optional dependency.
---
---Registry revision 7 added `Find`; an older Registry's `Get` also returns
---`nil` for a missing package, so it is a correct fallback. The method is read
---on every call because an embedded Registry upgrade replaces it in place.
---@param packageName string
---@return table|nil implementation `nil` when the package is not loaded
local function findOptionalPackage(packageName)
  local find = rawget(Registry, "Find")
  if type(find) ~= "function" then
    find = getPackage
  end
  local implementation = find(Registry, packageName, OPTIONAL_KIT_API)
  if type(implementation) ~= "table" then
    return nil
  end
  return implementation
end

-- Shared helpers --------------------------------------------------------------

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

---Raise at `level` when `value` is secret, naming `label`.
---
---On a client with secret values, comparing a secret with a value of its own
---type, or using it as a key, raises inside LifecycleKit instead of at the
---caller. Values LifecycleKit did not create are tested for absence with
---`type(value) == "nil"`, the repository rule, and a secret is refused first.
---@param value any
---@param label string qualified argument name, used in the argument error
---@param level integer stack level the failure is reported at
local function refuseSecret(value, label, level)
  if isSecret(value) then
    error(label .. " must not be a secret value", level)
  end
end

-- The limits block reads `UNBOUNDED` and `LIMIT_RULES`. The sentinel lives in
-- the package state so every revision publishes the same table; it is
-- assigned in the bootstrap below, before any limit is validated.
---@type table
local UNBOUNDED
local LIMIT_RULES = {
  { name = "maxDependencies", ceiling = LIMIT_CEILING, unbounded = true },
  { name = "defaultCombatQueueLimit", ceiling = LIMIT_CEILING, unbounded = true },
}

-- shared:begin limits 1 __FACADE__=LifecycleKit
-- Copied from tooling/shared/lua/limits.lua by python3 -m tooling.shared.sync; edit that file, not this copy.
---Check a whole `SetLimits` update; raises at `level`.
---@type fun(limits: any, level: integer)
local validateLimitUpdate
---Write the names an update gives into `target`.
---@type fun(target: table, limits: table)
local applyLimitUpdate
---A fresh table of every limit in `source`.
---@type fun(source: table): table
local copyLimits
do
  local rulesByName = {}
  local names = {}
  for index = 1, #LIMIT_RULES do
    local rule = LIMIT_RULES[index]
    rulesByName[rule.name] = rule
    names[index] = rule.name
  end
  local accepted = table.concat(names, ", ")

  local function validateValue(rule, value, level)
    local where = "LifecycleKit:SetLimits limits." .. rule.name
    if isSecret(value) then
      error(where .. " must not be a secret value", level)
    end
    if value == UNBOUNDED and UNBOUNDED ~= nil then
      if rule.unbounded then
        return
      end
      local reason = rule.unboundedReason and (": " .. rule.unboundedReason) or ""
      error(where .. " cannot be LifecycleKit.UNBOUNDED" .. reason, level)
    end
    local minimum = rule.minimum or 1
    local integer = rule.integer ~= false
    if
      type(value) ~= "number"
      or value ~= value
      or value < minimum
      or value > rule.ceiling
      or (integer and value % 1 ~= 0)
    then
      local kind = integer and "an integer" or "a number"
      local range = " from " .. minimum .. " to " .. rule.ceiling
      error(where .. " must be " .. kind .. range, level)
    end
    if rule.check then
      rule.check(value, level + 1)
    end
  end

  validateLimitUpdate = function(limits, level)
    if isSecret(limits) or type(limits) ~= "table" then
      error("LifecycleKit:SetLimits limits must be a table", level)
    end
    local key = next(limits)
    while type(key) ~= "nil" do
      local rule = type(key) == "string" and rulesByName[key] or nil
      if rule == nil then
        local named = "LifecycleKit:SetLimits limits." .. describeKey(key)
        error(named .. " is not a recognised limit; it accepts " .. accepted, level)
      end
      validateValue(rule, rawget(limits, key), level + 1)
      key = next(limits, key)
    end
  end

  applyLimitUpdate = function(target, limits)
    for index = 1, #LIMIT_RULES do
      local name = LIMIT_RULES[index].name
      local value = rawget(limits, name)
      if type(value) ~= "nil" then
        rawset(target, name, value)
      end
    end
  end

  copyLimits = function(source)
    local copy = {}
    for index = 1, #LIMIT_RULES do
      local name = LIMIT_RULES[index].name
      copy[name] = rawget(source, name)
    end
    return copy
  end
end
-- shared:end limits

-- Public-surface validation --------------------------------------------------

-- Every method a compatible copy must publish on the instance prototype. The
-- members of a part count too: without the part they are stubs.
local INSTANCE_METHODS = {
  "GetAddonName",
  "GetState",
  "IsLoaded",
  "IsReady",
  "IsShutdown",
  "IsHalted",
  "GetHaltReason",
  "OnLoaded",
  "OnReady",
  "OnShutdown",
  "OnHalted",
  "Halt",
  "DependsOn",
  "OnDependencyHalted",
  "WhenOutOfCombat",
  "OnCombatStart",
  "OnCombatEnd",
  "SetCombatQueueLimit",
  "GetCombatQueueLimit",
}

---Whether every name in `methodNames` is a function on `prototype`.
---@param prototype table
---@param methodNames string[]
---@return boolean
local function hasMethods(prototype, methodNames)
  for index = 1, #methodNames do
    if type(rawget(prototype, methodNames[index])) ~= "function" then
      return false
    end
  end
  return true
end

---Whether `implementation` exposes the complete LifecycleKit API 1 surface.
---@param implementation any shared package table handed back by Registry
---@return boolean
local function validatePublicSurface(implementation)
  if
    type(implementation) ~= "table"
    or rawget(implementation, "API") ~= API_GENERATION
    or type(rawget(implementation, "REVISION")) ~= "number"
    or type(rawget(implementation, "Instance")) ~= "table"
    or type(rawget(implementation, "Subscription")) ~= "table"
    or type(rawget(implementation, "DeferredCall")) ~= "table"
    or type(rawget(implementation, "ForAddon")) ~= "function"
    or type(rawget(implementation, "IsInCombat")) ~= "function"
    or type(rawget(implementation, "UNBOUNDED")) ~= "table"
    or type(rawget(implementation, "SetLimits")) ~= "function"
    or type(rawget(implementation, "GetLimits")) ~= "function"
    or type(rawget(implementation, "CLOSES_ADDON_SCOPES")) ~= "table"
  then
    return false
  end

  local Subscription = rawget(implementation, "Subscription")
  local DeferredCall = rawget(implementation, "DeferredCall")
  return hasMethods(rawget(implementation, "Instance"), INSTANCE_METHODS)
    and type(rawget(Subscription, "Disconnect")) == "function"
    and type(rawget(Subscription, "IsConnected")) == "function"
    and type(rawget(DeferredCall, "Cancel")) == "function"
    and type(rawget(DeferredCall, "IsPending")) == "function"
end

---Whether `currentState` carries package state of this revision's schema.
---@param currentState any
---@return boolean
local function validateCurrentState(currentState)
  if type(currentState) ~= "table" then
    return false
  end
  local capabilities = currentState.addonScopeCapabilities
  return currentState.schema == STATE_SCHEMA
    and type(currentState.addons) == "table"
    and type(currentState.instances) == "table"
    and type(currentState.globalWatchers) == "table"
    and type(currentState.loginSeen) == "boolean"
    and type(currentState.shutdownSeen) == "boolean"
    and type(currentState.unbounded) == "table"
    and type(currentState.limits) == "table"
    and type(currentState.dispatchDepth) == "number"
    and type(currentState.parts) == "table"
    and type(currentState.helpers) == "table"
    and type(currentState.dispatch) == "table"
    and type(capabilities) == "table"
    and type(capabilities.entries) == "table"
    and type(capabilities.view) == "table"
end

-- Bootstrap -----------------------------------------------------------------
--
-- `Registry:Bootstrap` owns the reconciliation every embedded package repeats:
-- look the package up, refuse to reinterpret state owned by a newer revision,
-- and register this one. What stays here is what only LifecycleKit can answer.
--
-- LifecycleKit always resumes a copy that carries its own revision. Its shared
-- host watchers live outside the package state this file validates, so a
-- previous live upgrade can have committed the Registry revision and then
-- failed while installing them. Re-running the rest of this file against the
-- stable facade is idempotent and repairs that incomplete runtime setup; the
-- state checks below still reject a facade whose package state is unusable.
local LifecycleKit, previousRevision, selected = bootstrapPackage(Registry, {
  package = PACKAGE_NAME,
  api = API_GENERATION,
  revision = IMPLEMENTATION_REVISION,
  label = "MoltenCodes LifecycleKit",
  validatePublicSurface = validatePublicSurface,
  resume = function()
    return IMPLEMENTATION_REVISION
  end,
})

if type(LifecycleKit) == "nil" then
  -- A newer compatible embedded revision already owns the package.
  return selected
end

-- Past this point the facade is always a table: Registry handed back the one
-- this copy fills in, whether fresh, inherited from an older revision or
-- resumed at this revision.
---@cast LifecycleKit table

-- Registry keeps the identity of the prototype tables below stable across
-- compatible embedded revisions, so instances created by an older copy observe
-- newer methods.
local Instance = rawget(LifecycleKit, "Instance")
local Subscription = rawget(LifecycleKit, "Subscription")
local DeferredCall = rawget(LifecycleKit, "DeferredCall")

local state = rawget(LifecycleKit, "_state")

-- Whether this copy takes over state an older revision created.
local upgradesOlderRevision = type(previousRevision) ~= "nil"
  and previousRevision < IMPLEMENTATION_REVISION

---Refuse every write to `LifecycleKit.CLOSES_ADDON_SCOPES`.
---
---The view holds no keys of its own, so `__newindex` sees every assignment,
---including one that would overwrite an existing entry.
---@param _ table
---@param key any
local function refuseCapabilityWrite(_, key)
  error(
    'LifecycleKit.CLOSES_ADDON_SCOPES is read-only; field "'
      .. describeKey(key)
      .. '" cannot be written',
    2
  )
end

---Add what schema 4 holds beyond schema 3: the part interface and the depth
---of the deliveries in progress. Used for a fresh state and for revision 18's.
---@param target table
local function addSchemaFourFields(target)
  -- Part name -> `{ revision = n }` of each installed part.
  target.parts = {}
  -- The core functions a part calls, read at call time (see "Parts").
  target.helpers = {}
  -- The core's calls into a part, filled by the part; the core's defaults
  -- stand in while it is not loaded.
  target.dispatch = {}
  -- How many deliveries are running. A subscription disconnected meanwhile
  -- is only marked, so the running loop's indices stay valid.
  target.dispatchDepth = 0
  target.schema = STATE_SCHEMA
end

if type(previousRevision) == "nil" then
  if Instance ~= nil or Subscription ~= nil or DeferredCall ~= nil or state ~= nil then
    error("MoltenCodes LifecycleKit package state is corrupted or incomplete", 2)
  end

  Instance = {}
  Subscription = {}
  DeferredCall = {}
  local entries = {}
  state = {
    -- addonName -> instance, for lookup by name.
    addons = {},
    -- Every instance, in creation order for instances this revision created:
    -- the allocation-free iteration order of the notices to every addon.
    instances = {},
    globalWatchers = {},
    loginSeen = false,
    shutdownSeen = false,
    -- `LifecycleKit.UNBOUNDED`. It lives in the state so that every revision
    -- publishes the same table and a comparison against it keeps working
    -- across an upgrade.
    unbounded = {},
    -- The package-wide limits `SetLimits` writes; a newer copy inherits what a
    -- consumer set.
    limits = {
      maxDependencies = DEFAULT_MAX_DEPENDENCIES,
      defaultCombatQueueLimit = DEFAULT_COMBAT_QUEUE_LIMIT,
    },
    -- The entries of `CLOSES_ADDON_SCOPES` and the read-only view over them.
    -- Every revision from 13 on hands out the same view, so a reader that kept
    -- it across an upgrade still reads the current set.
    addonScopeCapabilities = {
      entries = entries,
      view = setmetatable({}, {
        __index = entries,
        __newindex = refuseCapabilityWrite,
        __metatable = false,
      }),
    },
  }
  addSchemaFourFields(state)

  rawset(LifecycleKit, "Instance", Instance)
  rawset(LifecycleKit, "Subscription", Subscription)
  rawset(LifecycleKit, "DeferredCall", DeferredCall)
  rawset(LifecycleKit, "_state", state)
elseif
  type(Instance) ~= "table"
  or type(Subscription) ~= "table"
  or type(DeferredCall) ~= "table"
  or type(state) ~= "table"
then
  error("MoltenCodes LifecycleKit package state is corrupted or incomplete", 2)
end

local INSTANCE_METATABLE = { __index = Instance }
local SUBSCRIPTION_METATABLE = { __index = Subscription }

-- In-place upgrade ----------------------------------------------------------
--
-- The upgrade floor: only revision 18's state (schema 3) is taken over; schema
-- 2 and the per-revision fills of revisions 7 to 15 are gone, since no revision
-- before 19 was ever published. A same-schema copy of an older revision (a
-- reload, or a test copy under a lower number) only has its watchers replaced.

---Disconnect every shared host watcher an older revision installed.
---
---A watcher calls the handler of the revision that connected it, so leaving
---an older one in place would keep running that revision's phase machinery.
---The bootstrap tail installs this revision's watchers again (and the
---CombatGate part its own) and reconciles any phase that passed in between.
local function disconnectInheritedWatchers()
  local watchers = state.globalWatchers
  if type(watchers) ~= "table" then
    return
  end
  for key, connection in pairs(watchers) do
    watchers[key] = nil
    if type(connection) == "table" and type(connection.Disconnect) == "function" then
      connection:Disconnect()
    end
  end
end

---Bring revision 18's schema 3 to schema 4.
---
---Revision 18's instances keep their SignalKit signals (`_signals`), the
---capture records their listeners write into (`_phaseCaptures`), and their
---combat queues and dependency lists, whose fields the parts read unchanged.
---Their reusable combat capture records are released: nothing fires a combat
---signal with them any more (see "Delivery").
local function migrateState()
  if not upgradesOlderRevision then
    return
  end
  if state.schema == PREVIOUS_STATE_SCHEMA and type(state.addons) == "table" then
    for _, instance in pairs(state.addons) do
      if type(instance) == "table" then
        instance._combatCaptures = nil
      end
    end
    addSchemaFourFields(state)
  end
  if state.schema == STATE_SCHEMA then
    disconnectInheritedWatchers()
  end
end

migrateState()

if not validateCurrentState(state) then
  error("MoltenCodes LifecycleKit package state is corrupted or incomplete", 2)
end

UNBOUNDED = state.unbounded
local sharedLimits = state.limits
local addonScopeCapabilities = state.addonScopeCapabilities
local CLOSES_ADDON_SCOPES = addonScopeCapabilities.view
local helpers = state.helpers
local dispatch = state.dispatch

-- Host-state probes ---------------------------------------------------------

---Report whether `ADDON_LOADED` has already completed for `addonName`.
---
---Both the modern and the legacy host API return `(loaded, finished)`: an addon
---that is mid-load answers `true, false`. Only the second value confirms that
---the `ADDON_LOADED` transition finished, so only that value is trusted here.
---@param addonName string
---@return boolean
local function isAddonFinishedLoading(addonName)
  -- C_AddOns is a World of Warcraft client API reachable only through the global table.
  -- selene: allow(global_usage)
  local addonsApi = rawget(_G, "C_AddOns")
  local modern = type(addonsApi) == "table" and rawget(addonsApi, "IsAddOnLoaded") or nil
  if type(modern) == "function" then
    local _, finished = modern(addonName)
    return finished == true
  end

  -- Legacy IsAddOnLoaded is a World of Warcraft client global kept for older clients.
  -- selene: allow(global_usage)
  local legacy = rawget(_G, "IsAddOnLoaded")
  if type(legacy) == "function" then
    local _, finished = legacy(addonName)
    return finished == true
  end

  return false
end

---Report whether the host says the player is already logged in.
---@return boolean
local function isPlayerLoggedIn()
  -- IsLoggedIn is a World of Warcraft client API reachable only through the global table.
  -- selene: allow(global_usage)
  local probe = rawget(_G, "IsLoggedIn")
  return type(probe) == "function" and probe() == true
end

-- Subscription --------------------------------------------------------------
--
-- A subscription is its own record in its instance's list for one phase or
-- notice (`instance._lists[key]`, created with the first subscription), the
-- connection model EventKit uses. While connected it holds `_callback`,
-- `_instance` and `_key`; disconnecting drops all three, so a spent
-- subscription retains nothing.
--
-- A subscription revision 18 made instead wraps a SignalKit connection
-- (`_inner`), which this revision still answers for.

---@param value any
---@return LifecycleKit.ErrorRecord
local function newErrorRecord(value)
  return { value = value }
end

---Re-raise a captured error unchanged, or return when there was none.
---@param errorRecord LifecycleKit.ErrorRecord|nil
local function raisePhaseError(errorRecord)
  if errorRecord ~= nil then
    error(errorRecord.value, 0)
  end
end

---Return a subscription handle that is already spent.
---@return LifecycleKit.Subscription
local function newDisconnectedSubscription()
  return setmetatable({ _connected = false }, SUBSCRIPTION_METATABLE)
end

---Report whether this subscription is still pending delivery.
---@param self LifecycleKit.Subscription
---@return boolean
local function isSubscriptionConnected(self)
  if self._connected ~= true then
    return false
  end

  local inner = self._inner
  if inner ~= nil and inner:IsConnected() ~= true then
    -- SignalKit may disconnect a revision 18 listener as part of terminal
    -- cleanup. Keep the public LifecycleKit subscription in sync.
    self._connected = false
    self._inner = nil
    return false
  end

  return true
end

---Take a record out of its list now, when no delivery is iterating lists.
---@param instance table
---@param key string
---@param record table
local function removeFromList(instance, key, record)
  local lists = instance._lists
  local list = lists and lists[key]
  if list == nil then
    return
  end
  for index = #list, 1, -1 do
    if list[index] == record then
      table.remove(list, index)
      return
    end
  end
end

---Mark a record disconnected and release what it held.
---@param record table
local function releaseRecord(record)
  local instance, key = record._instance, record._key
  record._connected = false
  record._callback = nil
  record._instance = nil
  record._key = nil
  if instance ~= nil and state.dispatchDepth == 0 then
    removeFromList(instance, key, record)
  end
end

---Cancel a pending subscription.
---@param self LifecycleKit.Subscription
---@return boolean changed `true` only when a pending subscription became disconnected
local function disconnectSubscription(self)
  if not isSubscriptionConnected(self) then
    return false
  end

  local inner = self._inner
  if inner ~= nil then
    self._connected = false
    self._inner = nil
    inner:Disconnect()
    return true
  end
  releaseRecord(self)
  return true
end

---Append a connected subscription record to `instance`'s list for `key`.
---@param instance table
---@param key string
---@param callback function
---@return LifecycleKit.Subscription
local function addSubscription(instance, key, callback)
  local lists = instance._lists
  if lists == nil then
    lists = {}
    instance._lists = lists
  end
  local list = lists[key]
  if list == nil then
    list = {}
    lists[key] = list
  elseif state.dispatchDepth == 0 then
    -- Records disconnected during a delivery stay until here, the next
    -- subscription to the same list outside a delivery.
    for index = #list, 1, -1 do
      if list[index]._connected ~= true then
        table.remove(list, index)
      end
    end
  end
  local record = setmetatable({
    _connected = true,
    _callback = callback,
    _instance = instance,
    _key = key,
  }, SUBSCRIPTION_METATABLE)
  list[#list + 1] = record
  return record
end

---Disconnect every subscription in `instance`'s list for `key`, and revision
---18's listeners on its signal of the same name.
---@param instance table
---@param key string
local function disconnectList(instance, key)
  local lists = instance._lists
  local list = lists and lists[key]
  if list ~= nil then
    lists[key] = nil
    for index = 1, #list do
      local record = list[index]
      record._connected = false
      record._callback = nil
      record._instance = nil
      record._key = nil
    end
  end

  local signals = instance._signals
  local signal = signals and signals[key]
  if signal ~= nil then
    local SignalKit = findOptionalPackage("signalKit")
    if SignalKit ~= nil then
      SignalKit.DisconnectAll(signal)
    end
  end
end

-- Delivery --------------------------------------------------------------------
--
-- Every notification LifecycleKit delivers — a phase, a halt, a combat change,
-- a halted dependency — goes through `deliver`: each subscriber runs protected,
-- in subscription order, and the first failure is returned as an error record
-- once every subscriber had its delivery. The caller re-raises it after its
-- own state is committed.
--
-- A one-shot list is detached before its first callback runs, so each record
-- is delivered once; anything subscribing meanwhile finds the phase reached
-- and is replayed. A repeating list is iterated up to the length it had when
-- the delivery began, so a subscription made during it waits for the next
-- one, and a record disconnected during it is skipped at once.

---Fire revision 18's signal `key` on an instance that revision made.
---
---Revision 18's listeners record the first callback failure into
---`instance._phaseCaptures[key]` while that record is active, so this installs
---one for the fire and restores the enclosing one afterwards. SignalKit is
---loaded, since revision 18 required it.
---@param instance table
---@param signal table
---@param key string
---@param first any
---@param second any
---@return LifecycleKit.ErrorRecord|nil
local function fireInheritedSignal(instance, signal, key, first, second)
  local SignalKit = findOptionalPackage("signalKit")
  if SignalKit == nil then
    return nil
  end
  local captures = instance._phaseCaptures
  if type(captures) ~= "table" then
    captures = {}
    instance._phaseCaptures = captures
  end
  local enclosing = captures[key]
  local capture = { active = true, failed = false }
  captures[key] = capture

  local ok, signalError = pcall(SignalKit.Fire, signal, instance, first, second)

  capture.active = false
  captures[key] = enclosing
  if not ok then
    return newErrorRecord(signalError)
  end
  if capture.failed == true then
    return newErrorRecord(capture.value)
  end
  return nil
end

---Deliver `key` to every subscriber of `instance`.
---@param instance table
---@param key string a phase, `"halted"`, or a notice
---@param first any second argument delivered to subscribers
---@param second any third argument delivered to subscribers
---@return LifecycleKit.ErrorRecord|nil firstError
local function deliver(instance, key, first, second)
  local firstError = nil

  local signals = instance._signals
  local signal = signals and signals[key]
  if signal ~= nil then
    firstError = fireInheritedSignal(instance, signal, key, first, second)
  end

  local lists = instance._lists
  local list = lists and lists[key]
  if list == nil then
    return firstError
  end
  local oneShot = ONE_SHOT_KEYS[key] == true
  if oneShot then
    lists[key] = nil
  end

  state.dispatchDepth = state.dispatchDepth + 1
  local count = #list
  for index = 1, count do
    local record = list[index]
    local callback = record._callback
    if record._connected == true and callback ~= nil then
      if oneShot then
        record._connected = false
        record._callback = nil
        record._instance = nil
        record._key = nil
      end
      local ok, message = pcall(callback, instance, first, second)
      if not ok and firstError == nil then
        firstError = newErrorRecord(message)
      end
    end
  end
  state.dispatchDepth = state.dispatchDepth - 1
  return firstError
end

-- Phase machinery -----------------------------------------------------------

---Whether `instance` has reached a terminal state (shutdown or halted).
---@param instance LifecycleKit.Instance
---@return boolean
local function isTerminal(instance)
  return instance._shutdown == true or instance._halted == true
end

---Enter the `ready` phase unless an earlier transition already made it impossible.
---@param instance LifecycleKit.Instance
---@return LifecycleKit.ErrorRecord|nil
local function markReady(instance)
  if instance._ready == true or isTerminal(instance) then
    return nil
  end

  instance._ready = true
  return deliver(instance, "ready")
end

---Enter the `loaded` phase, continuing straight into `ready` when applicable.
---@param instance LifecycleKit.Instance
---@return LifecycleKit.ErrorRecord|nil
local function markLoaded(instance)
  if instance._loaded == true or isTerminal(instance) then
    return nil
  end

  instance._loaded = true

  local firstError = deliver(instance, "loaded")
  if state.loginSeen == true or isPlayerLoggedIn() then
    state.loginSeen = true
    local readyError = markReady(instance)
    if firstError == nil then
      firstError = readyError
    end
  end

  return firstError
end

---Close one Kit's scopes of the addon `instance` names.
---
---The Kit is found through `Registry:Find` (EventKit too, so one loop serves
---all seven). Without it, or with a revision that lacks the closing method,
---there is nothing to close; `false` (the addon never had a scope, or a Kit
---that closed it itself) is a normal result. A failure is returned as an
---error record for the first-error policy.
---@param instance LifecycleKit.Instance
---@param packageId string
---@return LifecycleKit.ErrorRecord|nil
local function closeAddonScopesOf(instance, packageId)
  local kit = findOptionalPackage(packageId)
  local close = kit ~= nil and rawget(kit, CLOSING_METHODS[packageId] or "CloseAddonScopes") or nil
  if type(close) ~= "function" then
    return nil
  end

  local ok, closeError = pcall(close, kit, instance._addonName)
  if not ok then
    return newErrorRecord(closeError)
  end
  return nil
end

---Release everything the addon owns through the other Kits' addon scopes.
---
---The order of `CLOSED_ADDON_SCOPE_PACKAGES` is deliberate, and it is also the
---first-error precedence:
---
---1. the TimerKit scope and
---2. the SchedulerKit scope first, so no timer fires and no job runs into
---   event listeners, hooks or subscribers that are being torn down;
---3. the EventKit scope, so no host event fires into hooks or subscribers
---   that are being torn down;
---4. the HookKit scope, so the addon's hooks stop running;
---5. the CommandKit scope, so the addon's slash commands become inert;
---6. the CommKit scope, so the addon's addon messages stop being sent and
---   received;
---7. the SignalKit bus last, because other addons' shutdown paths may still
---   publish on it. Publishing on a closed bus delivers nothing and does not
---   raise, so closing it last only keeps it useful for longer.
---
---Every step runs even when an earlier one failed.
---@param instance LifecycleKit.Instance
---@return LifecycleKit.ErrorRecord|nil firstError
local function closeAddonOwnedScopes(instance)
  local firstError = nil
  for index = 1, #CLOSED_ADDON_SCOPE_PACKAGES do
    local closeError = closeAddonScopesOf(instance, CLOSED_ADDON_SCOPE_PACKAGES[index])
    if firstError == nil then
      firstError = closeError
    end
  end
  return firstError
end

-- The lists a terminal state makes unreachable, besides the unreached phases.
local NOTICE_KEYS = { "dependencyHalted", "combatStart", "combatEnd" }

---Drop every pending subscription a terminal state makes unreachable.
---
---Called on shutdown and on halt. The phases already reached keep nothing
---pending (their subscriptions were one-shot), so only the unreached ones and
---the repeating notices are cleared. The list named by `keepKey` is the
---terminal phase itself, which still has to be delivered.
---@param instance LifecycleKit.Instance
---@param keepKey "shutdown"|"halted"
local function disconnectUnreachable(instance, keepKey)
  if instance._loaded ~= true then
    disconnectList(instance, "loaded")
  end
  if instance._ready ~= true then
    disconnectList(instance, "ready")
  end
  if keepKey ~= "shutdown" then
    disconnectList(instance, "shutdown")
  end
  if keepKey ~= "halted" then
    disconnectList(instance, "halted")
  end
  for index = 1, #NOTICE_KEYS do
    disconnectList(instance, NOTICE_KEYS[index])
  end
end

---Enter the terminal `shutdown` phase and release unreachable subscriptions.
---
---Order, and therefore first-error precedence: the combat queue is closed
---(CombatGate part; each pending call learns it will never run), then the
---shutdown callbacks run, then the addon's scopes are closed in
---`closeAddonOwnedScopes` order.
---
---A halted addon never reaches `shutdown`: halted is terminal. Its scopes and
---its bus are still closed at logout so they end with the session like
---everyone else's.
---@param instance LifecycleKit.Instance
---@return LifecycleKit.ErrorRecord|nil
local function markShutdown(instance)
  if instance._shutdown == true then
    return nil
  end
  if instance._halted == true then
    return closeAddonOwnedScopes(instance)
  end

  instance._shutdown = true

  -- Once shutdown is reached, anything not yet delivered can no longer
  -- occur. Drop those subscriptions so callback closures do not remain
  -- retained behind subscriptions that can never fire.
  disconnectUnreachable(instance, "shutdown")

  local queueError = dispatch.closeCombatQueue(instance, "shutdown")
  local phaseError = deliver(instance, "shutdown")
  local scopeError = closeAddonOwnedScopes(instance)
  return queueError or phaseError or scopeError
end

-- Shared event coordination -------------------------------------------------

---`ADDON_LOADED` handler shared by every addon LifecycleKit tracks.
---@param _ string event name
---@param addonName string
local function onAddonLoaded(_, addonName)
  local instance = state.addons[addonName]
  if instance ~= nil then
    raisePhaseError(markLoaded(instance))
  end
end

---Return every instance in `addons`, ordered by addon name.
---@param addons table<string, table>
---@return table[]
local function sortedInstances(addons)
  local names = {}
  for addonName in pairs(addons) do
    names[#names + 1] = addonName
  end
  table.sort(names)

  local ordered = {}
  for index = 1, #names do
    ordered[index] = addons[names[index]]
  end
  return ordered
end

---Run `callback` for every instance, by addon name, keeping the first error only.
---
---Used for the one-shot global phases, where a sorted snapshot is affordable
---and protects the iteration from instances created by a callback.
---@param callback fun(instance: LifecycleKit.Instance): LifecycleKit.ErrorRecord|nil
---@return LifecycleKit.ErrorRecord|nil firstError first captured error, or `nil`
local function runForAllAddons(callback)
  local ordered = sortedInstances(state.addons)
  local firstError = nil

  for index = 1, #ordered do
    local ok, result = pcall(callback, ordered[index])
    local candidate = result
    if not ok then
      candidate = newErrorRecord(result)
    end

    if candidate ~= nil and firstError == nil then
      firstError = candidate
    end
  end

  return firstError
end

---Promote every loaded instance to `ready`.
---@return LifecycleKit.ErrorRecord|nil
local function readyLoadedAddons()
  return runForAllAddons(function(instance)
    if instance._loaded == true then
      return markReady(instance)
    end
    return nil
  end)
end

---`PLAYER_LOGIN` handler: promote every loaded instance to `ready`.
---
---The host may have entered combat before login (a `/reload` in combat), so
---the CombatGate part re-reads the combat flag from the host first, before
---any `OnReady` callback (and the module `OnEnable` hooks ModuleKit runs from
---it) can ask `IsInCombat()` and be told the state from load time.
local function onPlayerLogin()
  state.loginSeen = true
  state.globalWatchers.playerLogin = nil

  local combatError = dispatch.reconcileCombat()
  local readyError = readyLoadedAddons()
  raisePhaseError(combatError or readyError)
end

---`PLAYER_LOGOUT` handler: stop every other watcher and drive every instance
---into `shutdown`.
local function onPlayerLogout()
  state.shutdownSeen = true
  local watchers = state.globalWatchers
  watchers.playerLogout = nil
  for key, connection in pairs(watchers) do
    watchers[key] = nil
    connection:Disconnect()
  end

  raisePhaseError(runForAllAddons(markShutdown))
end

---Install the shared host watchers.
---
---`ADDON_LOADED`, `PLAYER_LOGIN` and `PLAYER_LOGOUT` drive the phases; the
---CombatGate part adds its own two to the same table when it is loaded.
---
---Idempotent: only missing watchers are created, and a partial failure rolls
---back the watchers this call created before re-raising. Once `PLAYER_LOGOUT`
---has been observed no watcher is installed at all, because every remaining
---transition is already decided and instances created afterwards go straight
---to `shutdown`.
---@return LifecycleKit.ErrorRecord|nil combatError what reconciling the combat state raised
local function ensureGlobalWatchers()
  if state.shutdownSeen == true then
    return nil
  end

  local watchers = state.globalWatchers
  local created = {}

  local ok, message = pcall(function()
    if watchers.addonLoaded == nil then
      watchers.addonLoaded = EventKit:Connect("ADDON_LOADED", onAddonLoaded)
      created[#created + 1] = "addonLoaded"
    end

    if state.loginSeen ~= true then
      if isPlayerLoggedIn() then
        state.loginSeen = true
      elseif watchers.playerLogin == nil then
        watchers.playerLogin = EventKit:Once("PLAYER_LOGIN", onPlayerLogin)
        created[#created + 1] = "playerLogin"
      end
    end

    if watchers.playerLogout == nil then
      watchers.playerLogout = EventKit:Once("PLAYER_LOGOUT", onPlayerLogout)
      created[#created + 1] = "playerLogout"
    end
  end)

  if not ok then
    for index = #created, 1, -1 do
      local connection = watchers[created[index]]
      watchers[created[index]] = nil
      connection:Disconnect()
    end
    error(message, 0)
  end

  return dispatch.ensureCombatWatchers()
end

-- Instance creation ---------------------------------------------------------

---Create, publish and catch up the lifecycle instance for `addonName`.
---@param addonName string
---@return LifecycleKit.Instance
local function createInstance(addonName)
  -- Combat may have started or ended while nobody was watching.
  raisePhaseError(ensureGlobalWatchers())

  -- Probe before publishing the instance into shared package state so a host
  -- API error cannot leave a half-constructed cached object behind.
  local alreadyLoaded = isAddonFinishedLoading(addonName)

  -- Lists and the parts' fields are created on first use, so an instance
  -- nobody subscribes to holds its name and its four phase flags only.
  local instance = setmetatable({
    _addonName = addonName,
    _loaded = false,
    _ready = false,
    _shutdown = false,
    _halted = false,
  }, INSTANCE_METATABLE)
  dispatch.instanceCreated(instance)

  local instances = state.instances
  state.addons[addonName] = instance
  instances[#instances + 1] = instance

  if alreadyLoaded then
    raisePhaseError(markLoaded(instance))
  end

  if state.shutdownSeen == true then
    raisePhaseError(markShutdown(instance))
  end

  return instance
end

-- Public instance API -------------------------------------------------------

---Return the addon name this lifecycle instance was created for.
---@param self LifecycleKit.Instance
---@return string addonName
local function getAddonName(self)
  return self._addonName
end

---Return the lifecycle state this instance is in.
---
---`halted` wins over every phase: an addon that halted stays halted for the
---rest of the session.
---@param self LifecycleKit.Instance
---@return LifecycleKit.State
local function getState(self)
  if self._halted == true then
    return "halted"
  end
  if self._shutdown == true then
    return "shutdown"
  end
  if self._ready == true then
    return "ready"
  end
  if self._loaded == true then
    return "loaded"
  end
  return "loading"
end

---Report whether the `loaded` phase itself was reached.
---@param self LifecycleKit.Instance
---@return boolean
local function isLoaded(self)
  return self._loaded == true
end

---Report whether the `ready` phase itself was reached.
---@param self LifecycleKit.Instance
---@return boolean
local function isReady(self)
  return self._ready == true
end

---Report whether the `shutdown` phase itself was reached.
---@param self LifecycleKit.Instance
---@return boolean
local function isShutdown(self)
  return self._shutdown == true
end

---Report whether the addon halted.
---
---Answered by the core: a halt can come from any addon that embeds the Halt
---part, and without it nothing halts, so `false` is then exact.
---@param self LifecycleKit.Instance
---@return boolean
local function isHalted(self)
  return self._halted == true
end

---Return the reason given to `Halt`, or `nil` while the addon is not halted.
---@param self LifecycleKit.Instance
---@return string|nil reason
local function getHaltReason(self)
  return self._haltReason
end

---Shared implementation of the one-shot phase subscriptions.
---
---The argument error is raised at level 3 so it points at the addon code that
---called the public method: level 1 is this function, level 2 the public
---method, level 3 its caller. That only holds while the public methods call
---this function in a non-tail position; see `onLoaded` for why.
---@param self LifecycleKit.Instance
---@param phaseKey "loaded"|"ready"|"shutdown"|"halted"
---@param reached boolean whether the phase has already occurred
---@param callback function
---@param methodName string public method name, used in the argument error
---@param replayArgument any second argument of a replayed delivery
---@return LifecycleKit.Subscription
local function subscribePhase(self, phaseKey, reached, callback, methodName, replayArgument)
  if type(callback) ~= "function" then
    error("LifecycleKit.Instance:" .. methodName .. " callback must be a function", 3)
  end

  if reached then
    local subscription = newDisconnectedSubscription()
    local ok, callbackError = pcall(callback, self, replayArgument)
    if not ok then
      -- Replay and dispatch report a failing callback the same way: the
      -- original Lua error object, re-raised unchanged once LifecycleKit
      -- has committed its own state. A subscriber cannot know which of the
      -- two paths it will take, so the two must not differ.
      error(callbackError, 0)
    end
    return subscription
  end

  -- A terminal state makes every phase other than itself unreachable:
  -- shutdown rules out loaded, ready and halted; halted rules out all four.
  if self._halted == true then
    return newDisconnectedSubscription()
  end
  if phaseKey ~= "shutdown" and self._shutdown == true then
    return newDisconnectedSubscription()
  end

  return addSubscription(self, phaseKey, callback)
end

---Shared implementation of the repeating subscriptions the parts offer.
---
---Callers validate `callback` themselves, at their own level.
---@param self LifecycleKit.Instance
---@param key "dependencyHalted"|"combatStart"|"combatEnd"
---@param callback function
---@return LifecycleKit.Subscription
local function subscribeRepeating(self, key, callback)
  if isTerminal(self) then
    return newDisconnectedSubscription()
  end
  return addSubscription(self, key, callback)
end

---Subscribe to the `loaded` phase, replaying it if it already occurred.
---
---The call to `subscribePhase` is deliberately not a tail call. Lua 5.1 drops
---the calling frame on a tail call, which would collapse one level and make
---`subscribePhase`'s argument error point one frame past the addon code that
---called this method. `Errors_spec` pins the reported file and line.
---@param self LifecycleKit.Instance
---@param callback LifecycleKit.PhaseCallback
---@return LifecycleKit.Subscription subscription
local function onLoaded(self, callback)
  local subscription = subscribePhase(self, "loaded", self._loaded == true, callback, "OnLoaded")
  return subscription
end

---Subscribe to the `ready` phase, replaying it if it already occurred.
---@param self LifecycleKit.Instance
---@param callback LifecycleKit.PhaseCallback
---@return LifecycleKit.Subscription subscription
local function onReady(self, callback)
  -- Not a tail call, for the reason documented on `onLoaded`.
  local subscription = subscribePhase(self, "ready", self._ready == true, callback, "OnReady")
  return subscription
end

---Subscribe to the `shutdown` phase, replaying it if it already occurred.
---@param self LifecycleKit.Instance
---@param callback LifecycleKit.PhaseCallback
---@return LifecycleKit.Subscription subscription
local function onShutdown(self, callback)
  -- Not a tail call, for the reason documented on `onLoaded`.
  local subscription =
    subscribePhase(self, "shutdown", self._shutdown == true, callback, "OnShutdown")
  return subscription
end

---Subscribe to the addon halting, replaying it if the addon already halted.
---
---In the core because TestKit and ModuleKit subscribe unconditionally: without
---the Halt part nothing halts, and the subscription simply never fires.
---@param self LifecycleKit.Instance
---@param callback LifecycleKit.HaltedCallback
---@return LifecycleKit.Subscription subscription
local function onHalted(self, callback)
  -- Not a tail call, for the reason documented on `onLoaded`.
  local subscription =
    subscribePhase(self, "halted", self._halted == true, callback, "OnHalted", self._haltReason)
  return subscription
end

-- Public package API --------------------------------------------------------

---Return the stable lifecycle instance for `addonName`, creating it on demand.
---
---`addonName` is matched exactly against the name WoW reports in
---`ADDON_LOADED`, which is the addon's folder name as installed. See
---`docs/API.md` for why the name is not normalised.
---
---The argument error is raised at level 2 because this function is the frame
---the consumer calls: level 1 is this function, level 2 its caller.
---@param _ LifecycleKit
---@param addonName string addon folder name, exactly as installed
---@return LifecycleKit.Instance instance
local function forAddon(_, addonName)
  refuseSecret(addonName, "LifecycleKit:ForAddon addonName", 3)
  if type(addonName) ~= "string" or addonName == "" then
    error("LifecycleKit:ForAddon addonName must be a non-empty string", 2)
  end

  local existingInstance = state.addons[addonName]
  if existingInstance ~= nil then
    return existingInstance
  end

  return createInstance(addonName)
end

---Whether the named part is installed in this session.
---@param _ LifecycleKit
---@param name string `"CombatGate"` or `"Halt"`
---@return boolean installed
local function hasPart(_, name)
  if isSecret(name) or type(name) ~= "string" then
    error("LifecycleKit:HasPart name must be a part name string", 2)
  end
  return type(state.parts[name]) == "table"
end

---Raise unless `self` is the facade, naming `methodName`.
---@param self any
---@param methodName string
---@param usage string the call as it should be written
local function refuseOtherReceiver(self, methodName, usage)
  -- The type test comes first: a dot call can hand a secret in as `self`.
  if type(self) ~= "table" or self ~= LifecycleKit then
    error(
      "LifecycleKit:"
        .. methodName
        .. " must be called on the LifecycleKit facade; use LifecycleKit:"
        .. usage,
      3
    )
  end
end

---Change any subset of the package-wide limits, shared by every addon in the
---session. The whole table is validated first, so a refused call changes
---nothing.
---
---Lowering `maxDependencies` forgets no dependency already declared; further
---`DependsOn` calls answer `nil, "full"` until the list is below it.
---`defaultCombatQueueLimit` is the limit instances created from now on start
---with; instances that already exist keep theirs (`SetCombatQueueLimit`
---changes one).
---@param self LifecycleKit
---@param limits table any subset of `LifecycleKit.Limits`
local function setLimits(self, limits)
  refuseOtherReceiver(self, "SetLimits", "SetLimits(limits)")
  validateLimitUpdate(limits, 3)
  applyLimitUpdate(sharedLimits, limits)
end

---Return a fresh copy of the package-wide limits. Allocates one table.
---@param self LifecycleKit
---@return LifecycleKit.Limits
local function getLimits(self)
  refuseOtherReceiver(self, "GetLimits", "GetLimits()")
  return copyLimits(sharedLimits)
end

-- Parts -----------------------------------------------------------------------
--
-- What the core keeps for its parts, so a part loaded by any addon finds it:
-- `state.parts` (part name to its revision), `state.helpers` (the core
-- functions a part calls, read at call time, so an upgraded core serves an
-- older part) and `state.dispatch` (the core's calls into a part; the
-- defaults below stand in while it is not loaded, and are exact then, because
-- no combat queue or notice can exist without its part).
--
-- Every member a part provides stays on the facade and the prototypes even
-- without its part: a stub that raises at the caller's line with the file to
-- embed. Other Kits ask `HasPart`, never `type(member) == "function"`.

---A member that raises, at its caller's line, that `partName` is not loaded.
---@param label string the member as its caller wrote it
---@param partName string
---@return function
local function newPartStub(label, partName)
  -- The message is built only when the stub raises, so an addon that never
  -- calls a missing part holds no message text for it.
  return function()
    error(
      label
        .. " is in LifecycleKit's "
        .. partName
        .. " part, which is not loaded: add lifecycleKit\\parts\\LifecycleKit-"
        .. partName
        .. ".lua to embeds.xml after lifecycleKit\\LifecycleKit.lua",
      2
    )
  end
end

---Put the stubs of every part that is not installed in place.
local function installPartStubs()
  for index = 1, #PART_LAYOUT do
    local part = PART_LAYOUT[index]
    if type(state.parts[part.name]) ~= "table" then
      for _, name in ipairs(part.facade) do
        rawset(LifecycleKit, name, newPartStub("LifecycleKit:" .. name, part.name))
      end
      for _, name in ipairs(part.instance) do
        rawset(Instance, name, newPartStub("LifecycleKit.Instance:" .. name, part.name))
      end
      for _, name in ipairs(part.deferredCall) do
        rawset(DeferredCall, name, newPartStub("LifecycleKit.DeferredCall:" .. name, part.name))
      end
    end
  end
end

---Hand a diagnostic to the host error handler, best-effort.
---@param value any
local function reportError(value)
  -- geterrorhandler is the World of Warcraft client error sink, published as a global.
  -- selene: allow(global_usage)
  local getErrorHandler = rawget(_G, "geterrorhandler")
  local ok, handler = pcall(getErrorHandler)
  if not ok or type(handler) ~= "function" then
    return
  end
  pcall(handler, value)
end

---Run or refuse the calls still waiting in an instance's combat queue that
---revision 18 made, without the CombatGate part.
---
---Each pending call is called protected with `(instance, ran, reason)`, oldest
---first; the first failure is returned once all ran. Without the part this is
---also the default `closeCombatQueue`: shutdown and halt close an inherited
---queue exactly as revision 18 did.
---@param instance table
---@param ran boolean
---@param reason "shutdown"|"halted"|nil
---@return LifecycleKit.ErrorRecord|nil
local function runInheritedQueue(instance, ran, reason)
  local queue = instance._combatQueue
  if type(queue) ~= "table" or instance._combatPending == 0 then
    return nil
  end
  local firstError = nil
  for index = 1, instance._combatQueueLength or #queue do
    local handle = queue[index]
    queue[index] = nil
    if handle ~= nil and handle._pending == true then
      local callback = handle._callback
      handle._pending = false
      handle._callback = nil
      handle._instance = nil
      local ok, message = pcall(callback, instance, ran, reason)
      if not ok and firstError == nil then
        firstError = newErrorRecord(message)
      end
    end
  end
  instance._combatQueueLength = 0
  instance._combatPending = 0
  return firstError
end

---After taking over revision 18's state: when the CombatGate part is still
---not loaded, run the calls its queues hold while out of combat (or leave
---them for shutdown to close), and say once which file to embed.
local function settleInheritedQueues()
  if type(state.parts.CombatGate) == "table" then
    return
  end
  local pending = 0
  for index = 1, #state.instances do
    local instance = state.instances[index]
    if type(instance._combatPending) == "number" and instance._combatPending > 0 then
      pending = pending + instance._combatPending
      -- InCombatLockdown is a World of Warcraft client API reachable only through the global table.
      -- selene: allow(global_usage)
      local inCombat = rawget(_G, "InCombatLockdown")
      if not (type(inCombat) == "function" and inCombat() == true) and not isTerminal(instance) then
        local runError = runInheritedQueue(instance, true, nil)
        if runError ~= nil then
          reportError(runError.value)
        end
      end
    end
  end
  if pending > 0 then
    reportError(
      "MoltenCodes LifecycleKit revision "
        .. IMPLEMENTATION_REVISION
        .. " took over "
        .. pending
        .. " calls waiting for the end of combat without its CombatGate part: they ran"
        .. " now when out of combat, or are closed at shutdown. Embed"
        .. " lifecycleKit\\parts\\LifecycleKit-CombatGate.lua after lifecycleKit\\LifecycleKit.lua"
    )
  end
end

-- The defaults stand in until a part fills its entries; an installed part
-- keeps its own across a core reload.
if type(state.parts.CombatGate) ~= "table" then
  dispatch.ensureCombatWatchers = function()
    return nil
  end
  dispatch.reconcileCombat = function()
    return nil
  end
  dispatch.instanceCreated = function() end
  dispatch.closeCombatQueue = function(instance, reason)
    return runInheritedQueue(instance, false, reason)
  end
end

helpers.isSecret = isSecret
helpers.refuseSecret = refuseSecret
helpers.newErrorRecord = newErrorRecord
helpers.raisePhaseError = raisePhaseError
helpers.newDisconnectedSubscription = newDisconnectedSubscription
helpers.isSubscriptionConnected = isSubscriptionConnected
helpers.subscribeRepeating = subscribeRepeating
helpers.deliver = deliver
helpers.isTerminal = isTerminal
helpers.disconnectUnreachable = disconnectUnreachable
helpers.disconnectList = disconnectList

-- Commit --------------------------------------------------------------------

rawset(Subscription, "Disconnect", disconnectSubscription)
rawset(Subscription, "IsConnected", isSubscriptionConnected)

rawset(Instance, "GetAddonName", getAddonName)
rawset(Instance, "GetState", getState)
rawset(Instance, "IsLoaded", isLoaded)
rawset(Instance, "IsReady", isReady)
rawset(Instance, "IsShutdown", isShutdown)
rawset(Instance, "IsHalted", isHalted)
rawset(Instance, "GetHaltReason", getHaltReason)
rawset(Instance, "OnLoaded", onLoaded)
rawset(Instance, "OnReady", onReady)
rawset(Instance, "OnShutdown", onShutdown)
rawset(Instance, "OnHalted", onHalted)

rawset(LifecycleKit, "API", API_GENERATION)
rawset(LifecycleKit, "REVISION", IMPLEMENTATION_REVISION)
rawset(LifecycleKit, "ForAddon", forAddon)
rawset(LifecycleKit, "HasPart", hasPart)
rawset(LifecycleKit, "UNBOUNDED", UNBOUNDED)
rawset(LifecycleKit, "SetLimits", setLimits)
rawset(LifecycleKit, "GetLimits", getLimits)
installPartStubs()
state.partInterface = PART_INTERFACE

-- The capability set is rewritten in place so it names exactly what this
-- copy's `closeAddonOwnedScopes` closes.
local capabilityEntries = addonScopeCapabilities.entries
for packageId in pairs(capabilityEntries) do
  capabilityEntries[packageId] = nil
end
for index = 1, #CLOSED_ADDON_SCOPE_PACKAGES do
  capabilityEntries[CLOSED_ADDON_SCOPE_PACKAGES[index]] = true
end
rawset(LifecycleKit, "CLOSES_ADDON_SCOPES", CLOSES_ADDON_SCOPES)

if not validatePublicSurface(LifecycleKit) then
  error("MoltenCodes LifecycleKit package state is corrupted or incomplete", 2)
end

-- Re-establish shared watchers for every live compatible state. Besides normal
-- upgrades, this makes same-revision bootstrap idempotent after a prior host
-- registration failure. Reconcile globally observable state: a missing watcher
-- may have allowed PLAYER_LOGIN, PLAYER_LOGOUT or a combat change to pass
-- before a later embedded copy repaired the bootstrap.
if type(previousRevision) ~= "nil" and next(state.addons) ~= nil then
  local watcherError = ensureGlobalWatchers()

  local firstError
  if state.shutdownSeen == true then
    firstError = runForAllAddons(markShutdown)
  else
    -- Same order as `onPlayerLogin`: the combat flag is reconciled before any
    -- `OnReady` callback can read it, and always, even when a ready callback
    -- raises. A combat failure is re-raised ahead of a ready failure.
    local combatError = watcherError or dispatch.reconcileCombat()
    local readyError
    if state.loginSeen == true then
      readyError = readyLoadedAddons()
    end
    firstError = combatError or readyError
  end

  -- Revision 18's combat queues wait for the CombatGate part, which an addon
  -- embedding it loads right after this file; what is still missing on the
  -- next frame is settled then.
  if upgradesOlderRevision then
    -- C_Timer is a World of Warcraft client API reachable only through the global table.
    -- selene: allow(global_usage)
    local timers = rawget(_G, "C_Timer")
    local newTimer = type(timers) == "table" and rawget(timers, "NewTimer") or nil
    if type(newTimer) == "function" then
      pcall(newTimer, 0, settleInheritedQueues)
    end
  end

  raisePhaseError(firstError)
end

return LifecycleKit
