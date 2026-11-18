-- MoltenCodes ModuleKit
--
-- Addon-scoped module lifecycle and dependency graphs. ModuleKit is
-- intentionally independent from WoW Frame APIs; lifecycle timing is supplied
-- by LifecycleKit and package identity by Registry.
--
-- This file is ModuleKit's core. Three optional parts carry what only some
-- addons use (docs/decisions/0001-kit-core-and-parts.md): `Injection`
-- (providers, `Resolve`, `Inject` and the `inject` definition field),
-- `Implements` (`implements` contracts) and `RequiredAddons` (the
-- `requiresAddons` definition field and the reaction to another addon's
-- halt). Their members stay on the prototypes as stubs that name the file to
-- embed; the core reaches a loaded part only through `state.dispatch`.
--
-- Contents
--
--   Dependencies ......... Registry and LifecycleKit handshake.
--   Bootstrap ............ Embedded revision reconciliation and shared state;
--                          an in-place upgrade from revision 23 only.
--   Shared helpers ....... isSecret, describeKey, validateFacade, reportError
--                          and the limits loop, copied by tooling/shared.
--   Validation helpers ... Argument checks and definition-mutability rules.
--   Graph ................ Edge construction, cycle reporting, topological order.
--   Optional packages .... Silent `Registry:Find` lookup shared by the sections
--                          that use a Kit the addon may not embed.
--   Module scopes ........ Per-module addon-message, command, event, hook,
--                          job, message and timer scopes released on disable,
--                          resolved through `Registry:Find`.
--   Lifecycle operations . Single-module transitions, dependency policies,
--                          intent versus fact, recovery of blocked dependents,
--                          the container's own halt, whole-container passes and
--                          deferred catch-up.
--   Module public API ..... Methods installed on the shared Module prototype.
--   Addon public API ...... Methods installed on the shared Addon prototype.
--   Addon creation ........ Container identity and LifecycleKit subscriptions,
--                           including the halted notice.
--   Package-wide limits ... `SetLimits` / `GetLimits` and the coupling to
--                           LifecycleKit's dependency limit.
--   Parts ................. Stubs, `HasPart`, the dispatch defaults and the
--                           helpers the parts call.
--   Commit ................ Publishing the public surface and runtime dispatch.
--
-- `docs/INTERNALS.md` explains the graph algorithm, the failure model, the
-- lifecycle replay hazard that the dispatched-phase set guards against, module
-- scopes, the intent-versus-fact enable state, halted addons and the parts.

local PACKAGE_NAME = "moduleKit"
local API_GENERATION = 1
local IMPLEMENTATION_REVISION = 24
-- The core interface the parts read: `state.helpers`, the `state.dispatch`
-- entries they fill, `state.parts`. A part refuses a core that publishes a
-- lower number.
local PART_INTERFACE = 1
local REQUIRED_REGISTRY_API = 2
local REQUIRED_LIFECYCLE_API = 1
local STATE_SCHEMA = 1

-- The default of `maxRequiredAddons`, the most addons one module may name in
-- `requiresAddons`. It matches the number of dependencies LifecycleKit lets
-- one addon declare with `DependsOn`, which bounds the addon as a whole
-- whatever this limit says. `ModuleKit:SetLimits` opens it.
local DEFAULT_MAX_REQUIRED_ADDONS = 16

-- The largest `maxRequiredAddons` a positive integer may name. A module that
-- needs more than this many other addons is a generated or mistaken
-- definition; LifecycleKit's own `maxDependencies`, when it reports one,
-- lowers it further (see `LIMIT_RULES`).
local MAXIMUM_REQUIRED_ADDONS = 1024

-- The `blockedBy` value of every wanted module once its own addon has halted.
local OWN_ADDON_HALTED = "halted"

-- Public types --------------------------------------------------------------
--
-- ModuleKit publishes its methods by writing them onto Registry-owned prototype
-- tables, so the editor-facing contract is declared here as LuaCATS classes
-- rather than inferred from those assignments.

---Stable state a module moves through.
---@alias ModuleKit.ModuleState
---| "created"      # defined but not initialized
---| "initialized"  # `OnInitialize` completed
---| "enabled"      # `OnEnable` completed
---| "disabled"     # `OnDisable` completed

---How targeted operations treat unmet hard dependencies.
---@alias ModuleKit.DependencyPolicy "automatic"|"strict"

---What reading a module scope field answers when the Kit behind it is not
---loaded: `"nil"` (the default) or `"raise"`, an error at the reading line.
---@alias ModuleKit.MissingScopePolicy "nil"|"raise"

---The atomic definition table `Addon:CreateModule` accepts.
---
---Unknown fields and sparse list fields are rejected rather than ignored.
---@class ModuleKit.Definition
---@field dependsOn string[]? required modules, as `DependsOn` edges
---@field optionalDependencies string[]? ordering-only edges that do not activate
---@field before string[]? modules this one must precede
---@field after string[]? modules this one must follow
---@field inject table<string, string>? alias-to-provider/module-name map
---@field requiresAddons string[]? other addons this module cannot work without, at most `maxRequiredAddons` (default 16; see `ModuleKit:SetLimits`)
---@field implements ModuleKit.Implements? members the module must carry when `CreateModule` returns
---@field onInitialize fun(self: ModuleKit.Module, injections: table<string, any>)?
---@field onEnable fun(self: ModuleKit.Module, injections: table<string, any>)?
---@field onDisable fun(self: ModuleKit.Module, injections: table<string, any>)?
---@field enabledState boolean? the starting intent; the container's default state when omitted
---@field prototype table|false|nil the module's prototype; `false` for none when the container has a default

---What a provided value, or a module, must carry: a dense array of distinct
---method names, each looked up as `value[name]` and required to be a function,
---or a SchemaKit node or sealed schema when SchemaKit API 1 is loaded.
---@alias ModuleKit.Implements string[]|table

---Options accepted by `ProvideValue`, `ProvideSingleton`, `ProvideModule` and
---`ProvideTransient`. Unknown fields are rejected.
---@class ModuleKit.ProvideOptions
---@field implements ModuleKit.Implements? checked on every value the provider produces; see `docs/API.md`

---One module inside an addon container.
---
---Hook fields are assigned by the consumer, either through the definition table
---or directly on the module, and are called by ModuleKit at the matching phase.
---@class ModuleKit.Module
---@field scope ModuleKit.Scope framework registrations released on disable
---@field OnInitialize fun(self: ModuleKit.Module, injections: table<string, any>)?
---@field OnEnable fun(self: ModuleKit.Module, injections: table<string, any>)?
---@field OnDisable fun(self: ModuleKit.Module, injections: table<string, any>)?
---@field GetName fun(self: ModuleKit.Module): string
---@field GetAddon fun(self: ModuleKit.Module): ModuleKit.Addon
---@field GetState fun(self: ModuleKit.Module): ModuleKit.ModuleState
---@field IsInitialized fun(self: ModuleKit.Module): boolean
---@field IsEnabled fun(self: ModuleKit.Module): boolean
---@field GetLastError fun(self: ModuleKit.Module): any
---@field HasLastError fun(self: ModuleKit.Module): boolean
---@field GetBlockedBy fun(self: ModuleKit.Module): string|nil
---@field GetEnableState fun(self: ModuleKit.Module): ModuleKit.EnableState
---@field GetInjections fun(self: ModuleKit.Module): table<string, any>
---@field DependsOn fun(self: ModuleKit.Module, moduleName: string): ModuleKit.Module
---@field OptionalDependency fun(self: ModuleKit.Module, moduleName: string): ModuleKit.Module
---@field Before fun(self: ModuleKit.Module, moduleName: string): ModuleKit.Module
---@field After fun(self: ModuleKit.Module, moduleName: string): ModuleKit.Module
---@field Inject fun(self: ModuleKit.Module, aliasOrMap: string|table<string, string>, target: string?): ModuleKit.Module
---@field Initialize fun(self: ModuleKit.Module): ModuleKit.Module
---@field Enable fun(self: ModuleKit.Module): ModuleKit.Module
---@field Disable fun(self: ModuleKit.Module): ModuleKit.Module
---@field Activate fun(self: ModuleKit.Module): ModuleKit.Module
---@field Resolve fun(self: ModuleKit.Module, providerName: string): any
---@field SetEnabledState fun(self: ModuleKit.Module, enabled: boolean): boolean
---@field package _prototype table|nil the prototype it was created with; see `addonConveniences.prototypeMetatable`
---@field package _addon ModuleKit.Addon the owning container
---@field package _name string
---@field package _order integer creation order inside the container, from 1
---@field package _state ModuleKit.ModuleState
---@field package _wantedEnabled boolean intent: whether the module is meant to be enabled
---@field package _enableBlockedBy string|nil what keeps a wanted module off
---@field package _scope ModuleKit.Scope
---@field package _scopeOpen boolean|nil whether scope fields may be created; absent reads as closed
---@field package _injections table<string, any>|nil resolved at initialization
---@field package _lastError any the last failure's error object, which may be `nil` or `false`
---@field package _hasLastError boolean|nil `true` when `_lastError` holds a real error; absent reads as `false`
---@field package _blockedBy string|nil the module that blocked the last operation
---@field package _requiredAddons string[]|nil `requiresAddons`; absent reads as none
---@field package _hardDependencies table<string, boolean>|nil `DependsOn` names; absent reads as none
---@field package _optionalDependencies table<string, boolean>|nil absent reads as none
---@field package _before table<string, boolean>|nil absent reads as none
---@field package _after table<string, boolean>|nil absent reads as none
---@field package _injectSpec table<string, string>|nil alias to provider name; absent reads as none
---@field package _hardDependencyList ModuleKit.Module[]|nil resolved `_hardDependencies`, oldest first; see `hardDependencies`
---@field package _keptScopes table<string, table>|nil Kit scopes closed at the last disable, kept for `Reopen`; see `scopeIndex`

---One addon's module container, bound to that addon's LifecycleKit instance.
---@class ModuleKit.Addon
---@field GetAddonName fun(self: ModuleKit.Addon): string
---@field GetDependencyPolicy fun(self: ModuleKit.Addon): ModuleKit.DependencyPolicy
---@field SetDependencyPolicy fun(self: ModuleKit.Addon, policy: ModuleKit.DependencyPolicy): ModuleKit.DependencyPolicy
---@field GetMissingScopePolicy fun(self: ModuleKit.Addon): ModuleKit.MissingScopePolicy
---@field SetMissingScopePolicy fun(self: ModuleKit.Addon, policy: ModuleKit.MissingScopePolicy): ModuleKit.MissingScopePolicy
---@field CreateModule fun(self: ModuleKit.Addon, name: string, definition: ModuleKit.Definition?): ModuleKit.Module
---@field GetModule fun(self: ModuleKit.Addon, name: string): ModuleKit.Module|nil
---@field HasModule fun(self: ModuleKit.Addon, name: string): boolean
---@field GetModules fun(self: ModuleKit.Addon): ModuleKit.Module[]
---@field GetActivationOrder fun(self: ModuleKit.Addon): string[]
---@field ValidateGraph fun(self: ModuleKit.Addon): boolean
---@field InitializeAll fun(self: ModuleKit.Addon): ModuleKit.Addon
---@field EnableAll fun(self: ModuleKit.Addon): ModuleKit.Addon
---@field DisableAll fun(self: ModuleKit.Addon): ModuleKit.Addon
---@field ProvideValue fun(self: ModuleKit.Addon, name: string, value: any, options: ModuleKit.ProvideOptions?): ModuleKit.Addon
---@field ProvideSingleton fun(self: ModuleKit.Addon, name: string, factory: (fun(addon: ModuleKit.Addon): any), options: ModuleKit.ProvideOptions?): ModuleKit.Addon
---@field ProvideModule fun(self: ModuleKit.Addon, name: string, factory: (fun(addon: ModuleKit.Addon, module: ModuleKit.Module): any), options: ModuleKit.ProvideOptions?): ModuleKit.Addon
---@field ProvideTransient fun(self: ModuleKit.Addon, name: string, factory: (fun(addon: ModuleKit.Addon, module: ModuleKit.Module|nil): any), options: ModuleKit.ProvideOptions?): ModuleKit.Addon
---@field Resolve fun(self: ModuleKit.Addon, name: string, requestingModule: ModuleKit.Module|nil): any
---@field SetDefaultModuleState fun(self: ModuleKit.Addon, enabled: boolean): boolean
---@field GetDefaultModuleState fun(self: ModuleKit.Addon): boolean
---@field SetDefaultModulePrototype fun(self: ModuleKit.Addon, prototype: table?): table?
---@field GetDefaultModulePrototype fun(self: ModuleKit.Addon): table?
---@field OnModuleCreated fun(self: ModuleKit.Addon, callback: (fun(module: ModuleKit.Module))|table, methodName: string?): table|nil, string?
---@field package _defaultModuleState false|nil `false` when modules start unwanted; absent reads as `true`
---@field package _defaultModulePrototype table|nil
---@field package _moduleCreatedBus table|nil the addon's SignalKit bus, once `OnModuleCreated` subscribed
---@field package _name string the addon folder name
---@field package _lifecycle LifecycleKit.Instance
---@field package _dependencyPolicy ModuleKit.DependencyPolicy
---@field package _modules table<string, ModuleKit.Module>
---@field package _moduleOrder ModuleKit.Module[] every module, in creation order
---@field package _providers table<string, table>|nil created by the Injection part on the first provider
---@field package _resolutionStack table[]|nil created by the Injection part on the first factory run
---@field package _shutdown boolean
---@field package _subscriptions table<string, table> LifecycleKit handles by phase or notice
---@field package _dispatched table<string, boolean> phases and notices already delivered
---@field package _passDepth integer whole-container passes currently running
---@field package _pendingCatchUp ModuleKit.Module[]|nil catch-up deferred until the outermost pass ends; created on the first deferral
---@field package _flushingCatchUp boolean|nil
---@field package _graphOrder ModuleKit.Module[]|nil the cached, validated activation order; see `buildGraph`
---@field package _graphDependents table<ModuleKit.Module, ModuleKit.Module[]>|nil cached hard dependents, newest first
---@field package _mayHaveBlocked boolean|nil `false` when no module can be blocked; absent (an older revision's container) means unknown
---@field package _missingScopePolicy ModuleKit.MissingScopePolicy|nil absent reads as `"nil"`

---Per-module owner of framework registrations, released when the module is
---disabled. Each field is created on first read, only while the module is
---enabling or enabled, and is `nil` when the Kit behind it is not loaded.
---@class ModuleKit.Scope
---@field Timers table? a TimerKit scope (`TimerKit:CreateScope()`)
---@field Events table? an EventKit scope (`EventKit:CreateScope()`)
---@field Jobs table? a SchedulerKit scope (`SchedulerKit:CreateScope()`)
---@field Hooks table? a HookKit scope (`HookKit:CreateScope()`)
---@field Commands table? a CommandKit scope (`CommandKit:CreateScope()`)
---@field Comm table? a CommKit scope (`CommKit:CreateScope()`)
---@field Messages table? a scope over the addon's SignalKit bus (`SignalKit:ForAddon(addonName):CreateScope()`); also `nil` when the bus cannot be had

---Intent and fact of one module's enable state, as `GetEnableState` reports it.
---@class ModuleKit.EnableState
---@field wanted boolean whether the module is meant to be enabled
---@field actual boolean whether the module is enabled right now
---@field blockedBy string|nil what keeps a wanted module off: a hard dependency, a required addon that halted, or `"halted"` when its own addon halted

---An error object wrapped so that `nil` and `false` stay representable.
---@class ModuleKit.ErrorRecord
---@field value any the original Lua error object

---The package-wide limits, shared by every consumer in the session.
---`SetLimits` accepts any subset; `GetLimits` returns a fresh copy.
---@class ModuleKit.Limits
---@field maxRequiredAddons integer|table Most addons one module may name in `requiresAddons`: a positive integer or `ModuleKit.UNBOUNDED`; default 16. Never above LifecycleKit's `maxDependencies` when LifecycleKit reports one.

---The ModuleKit package facade published through Registry.
---@class ModuleKit
---@field API integer Public API generation.
---@field REVISION integer Compatible implementation revision.
---@field UNBOUNDED table Sentinel that lifts a limit whose retention is the consumer's own.
---@field Addon ModuleKit.Addon Shared container prototype.
---@field Module ModuleKit.Module Shared module prototype.
---@field ForAddon fun(self: ModuleKit, addonName: string): ModuleKit.Addon
---@field FindAddon fun(self: ModuleKit, addonName: string): ModuleKit.Addon|nil
---@field GetAddons fun(self: ModuleKit): string[]
---@field SetLimits fun(self: ModuleKit, limits: ModuleKit.Limits|table)
---@field GetLimits fun(self: ModuleKit): ModuleKit.Limits

-- Standard functions every lifecycle path calls, read once: a global read is a
-- hash lookup in `_G` on every call, a local is not. A whole-container pass
-- makes several hundred of these calls.
local rawget = rawget
local rawset = rawset
local type = type
local next = next

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
  error("MoltenCodes ModuleKit requires Registry API 2 to be loaded first", 2)
end

local bootstrapPackage = rawget(Registry, "Bootstrap")
local getPackage = rawget(Registry, "Get")
if type(bootstrapPackage) ~= "function" or type(getPackage) ~= "function" then
  error("MoltenCodes ModuleKit requires a valid Registry API 2 facade", 2)
end

local LifecycleKit, lifecycleRevision = getPackage(Registry, "lifecycleKit", REQUIRED_LIFECYCLE_API)
if type(LifecycleKit) == "nil" then
  error("MoltenCodes ModuleKit requires LifecycleKit API 1 to be loaded first", 2)
end
if
  type(LifecycleKit) ~= "table"
  or type(lifecycleRevision) ~= "number"
  or rawget(LifecycleKit, "API") ~= REQUIRED_LIFECYCLE_API
  or rawget(LifecycleKit, "REVISION") ~= lifecycleRevision
  or type(rawget(LifecycleKit, "ForAddon")) ~= "function"
then
  error("MoltenCodes ModuleKit requires a valid LifecycleKit API 1 facade", 2)
end

-- Bootstrap -----------------------------------------------------------------

---Whether `implementation` exposes the complete ModuleKit API 1 surface.
---@param implementation any shared package table handed back by Registry
---@return boolean
local function validatePublicSurface(implementation)
  if
    type(implementation) ~= "table"
    or rawget(implementation, "API") ~= API_GENERATION
    or type(rawget(implementation, "REVISION")) ~= "number"
    or type(rawget(implementation, "Addon")) ~= "table"
    or type(rawget(implementation, "Module")) ~= "table"
    or type(rawget(implementation, "ForAddon")) ~= "function"
    or type(rawget(implementation, "UNBOUNDED")) ~= "table"
    or type(rawget(implementation, "SetLimits")) ~= "function"
    or type(rawget(implementation, "GetLimits")) ~= "function"
  then
    return false
  end

  local Addon = rawget(implementation, "Addon")
  local Module = rawget(implementation, "Module")

  return type(rawget(Addon, "GetAddonName")) == "function"
    and type(rawget(Addon, "GetDependencyPolicy")) == "function"
    and type(rawget(Addon, "SetDependencyPolicy")) == "function"
    and type(rawget(Addon, "CreateModule")) == "function"
    and type(rawget(Addon, "GetModule")) == "function"
    and type(rawget(Addon, "HasModule")) == "function"
    and type(rawget(Addon, "GetModules")) == "function"
    and type(rawget(Addon, "GetActivationOrder")) == "function"
    and type(rawget(Addon, "ValidateGraph")) == "function"
    and type(rawget(Addon, "InitializeAll")) == "function"
    and type(rawget(Addon, "EnableAll")) == "function"
    and type(rawget(Addon, "DisableAll")) == "function"
    and type(rawget(Addon, "ProvideValue")) == "function"
    and type(rawget(Addon, "ProvideSingleton")) == "function"
    and type(rawget(Addon, "ProvideModule")) == "function"
    and type(rawget(Addon, "ProvideTransient")) == "function"
    and type(rawget(Addon, "Resolve")) == "function"
    and type(rawget(Module, "GetName")) == "function"
    and type(rawget(Module, "GetAddon")) == "function"
    and type(rawget(Module, "GetState")) == "function"
    and type(rawget(Module, "IsInitialized")) == "function"
    and type(rawget(Module, "IsEnabled")) == "function"
    and type(rawget(Module, "GetLastError")) == "function"
    and type(rawget(Module, "HasLastError")) == "function"
    and type(rawget(Module, "GetBlockedBy")) == "function"
    and type(rawget(Module, "GetEnableState")) == "function"
    and type(rawget(Module, "GetInjections")) == "function"
    and type(rawget(Module, "DependsOn")) == "function"
    and type(rawget(Module, "OptionalDependency")) == "function"
    and type(rawget(Module, "Before")) == "function"
    and type(rawget(Module, "After")) == "function"
    and type(rawget(Module, "Inject")) == "function"
    and type(rawget(Module, "Initialize")) == "function"
    and type(rawget(Module, "Enable")) == "function"
    and type(rawget(Module, "Disable")) == "function"
    and type(rawget(Module, "Activate")) == "function"
    and type(rawget(Module, "Resolve")) == "function"
end

---Whether `currentState` has the fields every API 1 revision shares.
---@param currentState any
---@return boolean
local function validateStateBase(currentState)
  return type(currentState) == "table"
    and rawget(currentState, "schema") == STATE_SCHEMA
    and type(rawget(currentState, "addons")) == "table"
end

-- Shared helpers ------------------------------------------------------------
--
-- Secret values (Retail 12.0.0 and later) raise when compared, so every
-- argument a comparison would touch is checked with the host probe first. A
-- host without `issecretvalue` has no secret values.

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

-- shared:begin reportError 1
-- Copied from tooling/shared/lua/reportError.lua by python3 -m tooling.shared.sync; edit that file, not this copy.
---Report `failure` through the host error handler, or print it.
---@param failure any
local function reportError(failure)
  -- geterrorhandler is a client API reachable only through the global table.
  -- selene: allow(global_usage)
  local getErrorHandler = rawget(_G, "geterrorhandler")
  if type(getErrorHandler) == "function" then
    local handler = getErrorHandler()
    if type(handler) == "function" and pcall(handler, failure) then
      return
    end
  end
  print(failure)
end
-- shared:end reportError

---Whether `value` is an exact integer of one or more. `nan` and both
---infinities are rejected before the integer test can accept them. A caller
---that takes the value from outside the Kit refuses a secret value first.
---@param value any
---@return boolean
local function isPositiveInteger(value)
  return type(value) == "number"
    and value == value
    and value ~= math.huge
    and value ~= -math.huge
    and value >= 1
    and value % 1 == 0
end

---Whether `limits` holds a valid value for every package-wide limit.
---@param limits any
---@param unbounded table the package's `UNBOUNDED` sentinel
---@return boolean
local function validateLimitsState(limits, unbounded)
  if type(limits) ~= "table" then
    return false
  end
  local value = rawget(limits, "maxRequiredAddons")
  return value == unbounded or isPositiveInteger(value)
end

---Whether `implementation` carries runtime state this revision has committed.
---@param implementation table
---@return boolean
local function validateCurrentState(implementation)
  local currentState = rawget(implementation, "_state")
  local dispatch = type(currentState) == "table" and rawget(currentState, "dispatch") or nil
  local unbounded = type(currentState) == "table" and rawget(currentState, "unbounded") or nil
  return validateStateBase(currentState)
    and rawget(currentState, "runtimeRevision") == IMPLEMENTATION_REVISION
    and type(unbounded) == "table"
    and rawget(implementation, "UNBOUNDED") == unbounded
    and validateLimitsState(rawget(currentState, "limits"), unbounded)
    and type(dispatch) == "table"
    and type(rawget(dispatch, "initializeAll")) == "function"
    and type(rawget(dispatch, "enableAll")) == "function"
    and type(rawget(dispatch, "shutdown")) == "function"
    and type(rawget(dispatch, "halted")) == "function"
    and type(rawget(dispatch, "dependencyHalted")) == "function"
    and type(rawget(dispatch, "resolveForHook")) == "function"
    and rawget(currentState, "partInterface") == PART_INTERFACE
    and type(rawget(currentState, "parts")) == "table"
    and type(rawget(currentState, "helpers")) == "table"
end

---Resume a copy that already registered this revision.
---
---Registry may have accepted this revision during an earlier bootstrap that
---failed before ModuleKit finished committing its shared runtime dispatch.
---Resuming re-runs the rest of this file against the same facade instead of
---leaving the package stuck with a half-built dispatch table.
---@param implementation table the shared package table Registry selected
---@param complete boolean whether that copy already committed this revision
---@return integer|nil previousRevision `nil` accepts the copy unchanged
local function resumeSameRevision(implementation, complete)
  if complete then
    return nil
  end

  local existingState = rawget(implementation, "_state")
  if not validateStateBase(existingState) then
    error("MoltenCodes ModuleKit package state is corrupted or incomplete", 2)
  end

  local runtimeRevision = rawget(existingState, "runtimeRevision")
  if type(runtimeRevision) ~= "number" then
    runtimeRevision = rawget(implementation, "REVISION")
  end
  return runtimeRevision or 0
end

-- `Registry:Bootstrap` owns the reconciliation every embedded package repeats:
-- look the package up, refuse to reinterpret state owned by a newer revision,
-- and register this one. What stays here is what only ModuleKit can answer.
local ModuleKit, previousRevision, selected = bootstrapPackage(Registry, {
  package = PACKAGE_NAME,
  api = API_GENERATION,
  revision = IMPLEMENTATION_REVISION,
  label = "MoltenCodes ModuleKit",
  validatePublicSurface = validatePublicSurface,
  validateState = validateCurrentState,
  resume = resumeSameRevision,
})

if type(ModuleKit) == "nil" then
  -- Equal or newer compatible revision already owns the shared package table.
  return selected
end

-- Registry keeps the identity of the two prototype tables below stable across
-- compatible embedded revisions, so containers and modules created by an older
-- copy observe newer methods.
local Addon = rawget(ModuleKit, "Addon")
local Module = rawget(ModuleKit, "Module")

local state = rawget(ModuleKit, "_state")

if type(previousRevision) == "nil" then
  if Addon ~= nil or Module ~= nil or state ~= nil then
    error("MoltenCodes ModuleKit package state is corrupted or incomplete", 2)
  end

  Addon = {}
  Module = {}
  state = {
    schema = STATE_SCHEMA,
    addons = {},
    dispatch = {},
    scopeMetatable = {},
    runtimeRevision = 0,
    -- The sentinel and the package-wide limits live here, so every later
    -- revision shares the sentinel's identity and inherits the limits a
    -- consumer set.
    unbounded = {},
    limits = { maxRequiredAddons = DEFAULT_MAX_REQUIRED_ADDONS },
    -- Module prototype to the metatable of its modules (revision 23); see
    -- `addonConveniences.prototypeMetatable`.
    prototypeLayers = {},
  }

  rawset(ModuleKit, "Addon", Addon)
  rawset(ModuleKit, "Module", Module)
  rawset(ModuleKit, "_state", state)
else
  -- The upgrade floor (docs/INTERNALS.md, "Upgrades"): no revision was ever
  -- published, so only the state revision 23 left is taken over in place.
  -- An older embedded copy is refused rather than half-converted.
  if type(previousRevision) ~= "number" or previousRevision < 23 then
    error(
      "MoltenCodes ModuleKit cannot take over the state of revision "
        .. tostring(previousRevision)
        .. " in place; revision 23 is the oldest it upgrades",
      2
    )
  end
  if
    type(Addon) ~= "table"
    or type(Module) ~= "table"
    or not validateStateBase(state)
    or type(state.dispatch) ~= "table"
    or type(state.runtimeRevision) ~= "number"
    or type(state.scopeMetatable) ~= "table"
    or type(state.unbounded) ~= "table"
    or not validateLimitsState(state.limits, state.unbounded)
    or type(state.prototypeLayers) ~= "table"
  then
    error("MoltenCodes ModuleKit package state is corrupted or incomplete", 2)
  end
end

-- What the parts share with the core (revision 24): the installed parts by
-- name, the core functions they call, and the unserved-state reports already
-- made. Created here for a new state and for one revision 23 left.
if state.parts == nil then
  state.parts = {}
  state.helpers = {}
  state.unservedReported = {}
end
state.partInterface = PART_INTERFACE

-- The sentinel and the limits table are shared by every revision; this copy
-- reads and writes them in place.
local UNBOUNDED = state.unbounded
local sharedLimits = state.limits

-- The runtime dispatch table: the whole-container passes LifecycleKit's
-- subscriptions reach, and the entries the parts fill. Stable for the
-- session, so every revision and part reads the current entry at call time.
local dispatch = state.dispatch

-- shared:begin validateFacade 1 __FACADE__=ModuleKit
-- Copied from tooling/shared/lua/validateFacade.lua by python3 -m tooling.shared.sync; edit that file, not this copy.
---Raise at `level` unless `receiver` is the ModuleKit facade.
---@param receiver any the table the method was called on
---@param label string qualified method name, used in the argument error
---@param level integer stack level the failure is reported at
local function validateFacade(receiver, label, level)
  if type(receiver) ~= "table" or receiver ~= ModuleKit then
    local hint = "; use " .. label .. "(...)"
    error(label .. " must be called on the ModuleKit facade" .. hint, level)
  end
end
-- shared:end validateFacade

---LifecycleKit's per-addon dependency limit, when the loaded LifecycleKit
---reports one through `GetLimits`, or `nil` when it reports none or reports
---its own `UNBOUNDED`.
---
---Read at call time rather than at load: LifecycleKit may be upgraded in
---place, and its limit may be changed, after ModuleKit loaded. `GetLimits` is
---optional because LifecycleKit revisions without it are supported.
---@return integer|nil ceiling
local function lifecycleDependencyCeiling()
  local getLimits = rawget(LifecycleKit, "GetLimits")
  if type(getLimits) ~= "function" then
    return nil
  end
  local limits = getLimits(LifecycleKit)
  if type(limits) ~= "table" then
    return nil
  end
  local value = rawget(limits, "maxDependencies")
  if isPositiveInteger(value) then
    return value
  end
  return nil
end

-- The package-wide limits `SetLimits` accepts, in the order `GetLimits`
-- reports them. `maxRequiredAddons` is also bounded by LifecycleKit's
-- `maxDependencies` when LifecycleKit reports one, since every required addon
-- becomes a `DependsOn` of the module's addon; `setLimits` refuses
-- `UNBOUNDED` against that ceiling too.
local LIMIT_RULES = {
  {
    name = "maxRequiredAddons",
    ceiling = MAXIMUM_REQUIRED_ADDONS,
    unbounded = true,
    check = function(value, level)
      local ceiling = lifecycleDependencyCeiling()
      if ceiling ~= nil and value > ceiling then
        error(
          "ModuleKit:SetLimits limits.maxRequiredAddons must be an integer from 1 to "
            .. ceiling
            .. ", LifecycleKit's maxDependencies",
          level
        )
      end
    end,
  },
}

-- shared:begin limits 1 __FACADE__=ModuleKit
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
    local where = "ModuleKit:SetLimits limits." .. rule.name
    if isSecret(value) then
      error(where .. " must not be a secret value", level)
    end
    if value == UNBOUNDED and UNBOUNDED ~= nil then
      if rule.unbounded then
        return
      end
      local reason = rule.unboundedReason and (": " .. rule.unboundedReason) or ""
      error(where .. " cannot be ModuleKit.UNBOUNDED" .. reason, level)
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
      error("ModuleKit:SetLimits limits must be a table", level)
    end
    local key = next(limits)
    while type(key) ~= "nil" do
      local rule = type(key) == "string" and rulesByName[key] or nil
      if rule == nil then
        local named = "ModuleKit:SetLimits limits." .. describeKey(key)
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

-- Every module scope shares this metatable. It lives in shared state, and each
-- revision installs its own `__index` on it, so scopes created by an older copy
-- observe the newer lookup after an upgrade.
local SCOPE_METATABLE = state.scopeMetatable

local ADDON_METATABLE = { __index = Addon }
local MODULE_METATABLE = { __index = Module }

-- The name set a module reads for a constraint kind it never declared
-- (`_hardDependencies`, `_optionalDependencies`, `_before`, `_after`). It is never
-- written: the first declaration gives the module its own table. Leaving the
-- fields absent keeps a module that declares nothing at a quarter of the table
-- slots it would otherwise need; see `docs/INTERNALS.md` (Allocation policy).
local EMPTY_NAME_SET = {}

-- The module list `hardDependencies` and the dependent lookups answer when
-- there is nothing to list. It is never written, and every caller only reads
-- the lists it is handed.
local NO_MODULES = {}

---Return one of `module`'s constraint name sets, or the shared empty set.
---@param module ModuleKit.Module
---@param field "_hardDependencies"|"_optionalDependencies"|"_before"|"_after"
---@return table<string, any>
local function moduleNameSet(module, field)
  local set = module[field]
  if set == nil then
    return EMPTY_NAME_SET
  end
  return set
end

-- Validation helpers --------------------------------------------------------

---The refusal of a member or field whose part is not loaded, naming the file
---to embed after the core.
---@param label string what was asked for, `ModuleKit.Addon:Resolve`
---@param partName string
---@return string
local function partMissingMessage(label, partName)
  return label
    .. " is in ModuleKit's "
    .. partName
    .. " part, which is not loaded: add moduleKit\\parts\\ModuleKit-"
    .. partName
    .. ".lua to embeds.xml after moduleKit\\ModuleKit.lua"
end

-- Error levels. Every helper that raises takes the level it raises at,
-- counted from its own frame (`2` is its caller), and names the public method
-- in full, `ModuleKit.Module:Enable` or `ModuleKit.Addon:CreateModule`. Lua 5.1
-- counts a frame replaced by a tail call as one level, so the count is the same
-- whether a public method tail-calls its helper or not.

---@param value any
---@param label string argument description, used in the argument error
---@param level integer stack level the failure is reported at, counted from this function
local function validateNonEmptyString(value, label, level)
  if isSecret(value) then
    error(label .. " must not be a secret value", level)
  end
  if type(value) ~= "string" or value == "" then
    error(label .. " must be a non-empty string", level)
  end
end

---Copy one level of `source`, so a caller cannot mutate container-owned state.
---@param source table<any, any>
---@return table<any, any>
local function shallowCopy(source)
  local copy = {}
  for key, value in pairs(source) do
    copy[key] = value
  end
  return copy
end

---Refuse a definition change to a module that has already been initialized.
---@param module ModuleKit.Module
---@param methodName string public `Module` method name, used in the argument error
---@param level integer stack level the failure is reported at, counted from this function
local function ensureDefinitionMutable(module, methodName, level)
  if module._state ~= "created" then
    error(
      "ModuleKit.Module:"
        .. methodName
        .. ' cannot change module "'
        .. module._name
        .. '" after initialization',
      level
    )
  end
end

---Refuse an operation on a container whose addon has already shut down.
---@param addon ModuleKit.Addon
---@param methodLabel string the public method in full, `ModuleKit.Addon:CreateModule` or `ModuleKit.Module:Enable`
---@param level integer stack level the failure is reported at, counted from this function
local function ensureNotShutdown(addon, methodLabel, level)
  if addon._shutdown == true then
    error(methodLabel .. " cannot run after addon shutdown", level)
  end
end

---Forget the container's cached graph order and dependent lists.
---
---Called wherever the graph can change: a module is added, or a module in
---`created` state gains a constraint. Modules are never removed, and a
---constraint can only be added before its module initializes, so nothing else
---can make the cache wrong. See `buildGraph`.
---@param addon ModuleKit.Addon
local function invalidateGraph(addon)
  if addon._graphOrder ~= nil then
    addon._graphOrder = nil
    addon._graphDependents = nil
  end
end

---Record one dependency or ordering edge by target name.
---
---Targets are names rather than objects, so an edge can be declared before the
---module it names exists.
---@param module ModuleKit.Module
---@param field "_hardDependencies"|"_optionalDependencies"|"_before"|"_after"
---@param targetName string
---@param methodName string public `Module` method name, used in the argument errors
---@param level integer stack level the failures are reported at, counted from this function: `3` from the public method, `5` from a `CreateModule` definition list
---@return ModuleKit.Module module
local function addNameConstraint(module, field, targetName, methodName, level)
  ensureDefinitionMutable(module, methodName, level + 1)
  ensureNotShutdown(module._addon, "ModuleKit.Module:" .. methodName, level + 1)
  validateNonEmptyString(targetName, "ModuleKit.Module:" .. methodName .. " moduleName", level + 1)

  if targetName == module._name then
    error('ModuleKit module "' .. targetName .. '" cannot depend/order against itself', level)
  end

  if field == "_before" then
    local addon = module._addon
    local target = rawget(addon._modules, targetName)
    if target ~= nil and target._state ~= "created" then
      error(
        'ModuleKit module "'
          .. module._name
          .. '" cannot be ordered before already-initialized module "'
          .. targetName
          .. '"',
        level
      )
    end
  end

  local names = rawget(module, field)
  if names == nil then
    names = {}
    rawset(module, field, names)
  end
  rawset(names, targetName, true)

  -- The container's validated order, and this module's resolved dependency
  -- list, were computed without this edge.
  invalidateGraph(module._addon)
  if field == "_hardDependencies" and module._hardDependencyList ~= nil then
    module._hardDependencyList = nil
  end
  return module
end

---Refuse a late module that would have to run before an initialized one.
---@param addon ModuleKit.Addon
---@param newModule ModuleKit.Module
local function validateLateModuleOrdering(addon, newModule)
  local order = addon._moduleOrder
  local newName = newModule._name
  local newBefore = moduleNameSet(newModule, "_before")

  for index = 1, #order do
    local existingModule = order[index]
    if existingModule._state ~= "created" then
      local existingName = existingModule._name
      local existingOptional = moduleNameSet(existingModule, "_optionalDependencies")
      local existingAfter = moduleNameSet(existingModule, "_after")
      local existingHard = moduleNameSet(existingModule, "_hardDependencies")

      if
        rawget(newBefore, existingName) == true
        or rawget(existingOptional, newName) == true
        or rawget(existingAfter, newName) == true
        or rawget(existingHard, newName) == true
      then
        error(
          'ModuleKit cannot create late module "'
            .. newName
            .. '" because it would need to run before already-initialized module "'
            .. existingName
            .. '"',
          3
        )
      end
    end
  end
end

-- Graph ---------------------------------------------------------------------

---Creation order of `module`, the deterministic tie-break inside a container.
---@param module ModuleKit.Module
---@return integer
local function moduleSortKey(module)
  return module._order
end

-- The sort comparators are shared functions rather than closures written at
-- each call, so sorting allocates nothing of its own.

---`table.sort` comparator: older modules first.
---@param left ModuleKit.Module
---@param right ModuleKit.Module
---@return boolean
local function createdEarlier(left, right)
  return moduleSortKey(left) < moduleSortKey(right)
end

---`table.sort` comparator: newer modules first.
---@param left ModuleKit.Module
---@param right ModuleKit.Module
---@return boolean
local function createdLater(left, right)
  return moduleSortKey(left) > moduleSortKey(right)
end

---`table.sort` comparator: older modules first, by name for equal positions.
---
---Creation order is unique inside a container, so the name only decides for
---state an external writer corrupted; it keeps the order deterministic even
---then.
---@param left ModuleKit.Module
---@param right ModuleKit.Module
---@return boolean
local function createdEarlierThenName(left, right)
  local leftOrder = moduleSortKey(left)
  local rightOrder = moduleSortKey(right)
  if leftOrder == rightOrder then
    return rawget(left, "_name") < rawget(right, "_name")
  end
  return leftOrder < rightOrder
end

---Return the keys of a name set as a sorted array.
---@param names table<string, boolean>
---@return string[]
local function sortedNameKeys(names)
  local result = {}
  for name in pairs(names) do
    result[#result + 1] = name
  end
  table.sort(result)
  return result
end

---Add one predecessor edge, keeping the indegree count in step.
---@param adjacency table<ModuleKit.Module, table<ModuleKit.Module, boolean>>
---@param indegree table<ModuleKit.Module, integer>
---@param fromModule ModuleKit.Module predecessor
---@param toModule ModuleKit.Module successor
local function addEdge(adjacency, indegree, fromModule, toModule)
  if fromModule == toModule then
    return
  end

  local edges = adjacency[fromModule]
  if edges[toModule] ~= true then
    edges[toModule] = true
    indegree[toModule] = indegree[toModule] + 1
  end
end

---Add an edge between `module` and every existing module a name set names.
---
---The targets are visited in creation order, so `pairs` order over the set
---cannot leak into the edges. A name with no module behind it adds nothing:
---these are ordering constraints, not requirements.
---@param addon ModuleKit.Addon
---@param adjacency table<ModuleKit.Module, table<ModuleKit.Module, boolean>>
---@param indegree table<ModuleKit.Module, integer>
---@param module ModuleKit.Module
---@param names table<string, boolean>
---@param moduleFirst boolean `true` when `module` precedes the targets (`Before`)
local function addOrderingEdges(addon, adjacency, indegree, module, names, moduleFirst)
  if next(names) == nil then
    return
  end

  local modules = addon._modules
  local targets = {}
  for name in pairs(names) do
    local target = rawget(modules, name)
    if target ~= nil then
      targets[#targets + 1] = target
    end
  end
  table.sort(targets, createdEarlierThenName)

  for index = 1, #targets do
    if moduleFirst then
      addEdge(adjacency, indegree, module, targets[index])
    else
      addEdge(adjacency, indegree, targets[index], module)
    end
  end
end

---Return the successors of `module` in creation order.
---@param adjacency table<ModuleKit.Module, table<ModuleKit.Module, boolean>>
---@param module ModuleKit.Module
---@return ModuleKit.Module[]
local function orderedSuccessors(adjacency, module)
  local edges = adjacency[module]
  if next(edges) == nil then
    return NO_MODULES
  end
  local targets = {}
  for target in pairs(edges) do
    targets[#targets + 1] = target
  end
  table.sort(targets, createdEarlier)
  return targets
end

---Return the names on one cycle of the graph, for the diagnostic message.
---@param order ModuleKit.Module[]
---@param adjacency table<ModuleKit.Module, table<ModuleKit.Module, boolean>>
---@return string[]|nil cycle `nil` when the graph is acyclic
local function findCycle(order, adjacency)
  local visiting = {}
  local visited = {}
  local stack = {}

  local function visit(module)
    if visited[module] then
      return nil
    end
    if visiting[module] then
      local startIndex = 1
      for index = 1, #stack do
        if stack[index] == module then
          startIndex = index
          break
        end
      end

      local names = {}
      for index = startIndex, #stack do
        names[#names + 1] = rawget(stack[index], "_name")
      end
      names[#names + 1] = module._name
      return names
    end

    visiting[module] = true
    stack[#stack + 1] = module

    local targets = orderedSuccessors(adjacency, module)
    for index = 1, #targets do
      local cycle = visit(targets[index])
      if cycle ~= nil then
        return cycle
      end
    end

    stack[#stack] = nil
    visiting[module] = nil
    visited[module] = true
    return nil
  end

  for index = 1, #order do
    local cycle = visit(order[index])
    if cycle ~= nil then
      return cycle
    end
  end
  return nil
end

---Insert `module` into the ready set, keeping it sorted by creation order.
---
---The set is stored in *descending* creation order so the next module to emit
---is always its last element: removing the last element is O(1), while
---removing the first would shift the whole array on every emission.
---
---Creation order is unique inside one container, so the comparison is a total
---order and the position found here is the only valid one. Together with the
---descending layout this keeps the emitted order identical to a full re-sort
---after every insertion, without paying for one.
---@param ready ModuleKit.Module[] ready set, sorted by descending creation order
---@param module ModuleKit.Module
local function insertReady(ready, module)
  local moduleOrder = moduleSortKey(module)
  local low = 1
  local high = #ready

  -- Binary search for the first entry created before `module`; that index is
  -- where `module` belongs in a descending array.
  while low <= high do
    local middle = math.floor((low + high) / 2)
    if moduleSortKey(ready[middle]) > moduleOrder then
      low = middle + 1
    else
      high = middle - 1
    end
  end

  table.insert(ready, low, module)
end

---Order `order` so every module follows the modules it has edges from.
---
---Kahn's algorithm, with creation order as the deterministic tie-break among
---modules that are simultaneously ready.
---@param order ModuleKit.Module[] every module in the graph, in creation order
---@param adjacency table<ModuleKit.Module, table<ModuleKit.Module, boolean>> predecessor → successors
---@param indegree table<ModuleKit.Module, integer> remaining unsatisfied predecessors
---@return ModuleKit.Module[]|nil order `nil` when the graph contains a cycle
local function topologicalSort(order, adjacency, indegree)
  -- `order` is in creation order, so walking it backwards fills the ready
  -- set already sorted newest first, as `insertReady` keeps it.
  local ready = {}
  for index = #order, 1, -1 do
    local module = order[index]
    if indegree[module] == 0 then
      ready[#ready + 1] = module
    end
  end

  local result = {}
  while #ready > 0 do
    local last = #ready
    local module = ready[last]
    ready[last] = nil
    result[#result + 1] = module

    local targets = orderedSuccessors(adjacency, module)
    for index = 1, #targets do
      local target = targets[index]
      indegree[target] = indegree[target] - 1
      if indegree[target] == 0 then
        insertReady(ready, target)
      end
    end
  end

  if #result ~= #order then
    return nil
  end
  return result
end

---Return the modules `module` requires, oldest first.
---
---The list is resolved once and kept on the module as `_hardDependencyList`:
---modules are never removed, so once every name resolves the list stays right
---until the module declares another dependency, which clears it (see
---`addNameConstraint`). A module that requires nothing keeps the shared empty
---list, so the common case allocates nothing. A missing dependency raises and
---caches nothing, so it is reported every time.
---
---The whole-container passes read `_hardDependencyList` directly and call
---this only when it is absent, since they ask once per module per pass.
---@param module ModuleKit.Module
---@param level integer|nil error level of a missing dependency, counted from this function; `3` when omitted
---@return ModuleKit.Module[] dependencies read-only
local function hardDependencies(module, level)
  local cached = module._hardDependencyList
  if cached ~= nil then
    return cached
  end

  local names = moduleNameSet(module, "_hardDependencies")
  if next(names) == nil then
    module._hardDependencyList = NO_MODULES
    return NO_MODULES
  end

  local modules = module._addon._modules
  local sortedNames = sortedNameKeys(names)
  local result = {}
  for index = 1, #sortedNames do
    local dependencyName = sortedNames[index]
    local dependency = rawget(modules, dependencyName)
    if dependency == nil then
      error(
        'ModuleKit module "'
          .. module._name
          .. '" requires missing dependency "'
          .. dependencyName
          .. '"',
        level or 3
      )
    end
    result[#result + 1] = dependency
  end
  table.sort(result, createdEarlier)

  module._hardDependencyList = result
  return result
end

---Build, topologically sort and cache the container's complete module graph.
---
---The validated order is kept on the container as `_graphOrder`, beside
---`_graphDependents` (each module's hard dependents, newest first), and
---`invalidateGraph` drops both whenever the graph can change. Every later
---whole-container pass, `ValidateGraph` and `GetActivationOrder` then reuse it
---without allocating. An invalid graph is never cached, so its diagnostic is
---raised on every call. The cached array is shared by every caller and must
---never be written; a rebuild replaces it rather than editing it, so a pass
---still walking an older array is unaffected.
---
---`level` is the error level of a missing dependency or a cycle, counted from
---this function: `3` names the caller of a public method that calls it
---directly, and the whole-container passes pass one more for their own frame.
---@param addon ModuleKit.Addon
---@param level integer|nil error level; `3` when omitted
---@return ModuleKit.Module[] order activation order for the whole container; read-only
local function buildGraph(addon, level)
  local cached = addon._graphOrder
  if cached ~= nil then
    return cached
  end

  level = level or 3
  local order = addon._moduleOrder
  local adjacency = {}
  local indegree = {}
  local dependents = {}

  for index = 1, #order do
    local module = order[index]
    adjacency[module] = {}
    indegree[module] = 0
  end

  for index = 1, #order do
    local module = order[index]
    local dependencies = hardDependencies(module, level + 1)
    for dependencyIndex = 1, #dependencies do
      local dependency = dependencies[dependencyIndex]
      addEdge(adjacency, indegree, dependency, module)
      local list = dependents[dependency]
      if list == nil then
        list = {}
        dependents[dependency] = list
      end
      list[#list + 1] = module
    end

    -- Most modules declare no ordering constraint at all, and an absent set
    -- adds nothing.
    local optional = module._optionalDependencies
    if optional ~= nil then
      addOrderingEdges(addon, adjacency, indegree, module, optional, false)
    end
    local after = module._after
    if after ~= nil then
      addOrderingEdges(addon, adjacency, indegree, module, after, false)
    end
    local before = module._before
    if before ~= nil then
      addOrderingEdges(addon, adjacency, indegree, module, before, true)
    end
  end

  local result = topologicalSort(order, adjacency, indegree)
  if result == nil then
    local cycle = findCycle(order, adjacency)
    local description = cycle and table.concat(cycle, " -> ") or "unknown cycle"
    error("ModuleKit dependency cycle detected: " .. description, level)
  end

  -- Modules were visited in creation order, so each dependent list is
  -- already oldest first; the lookups want the newest first.
  for _, list in pairs(dependents) do
    table.sort(list, createdLater)
  end

  addon._graphOrder = result
  addon._graphDependents = dependents
  return result
end

---Return the modules that require `module`, newest first, without checking
---their state.
---
---Read from the cached graph when there is one. Without it (the graph was
---never built, has changed since, or is invalid, which targeted operations
---tolerate) the container is scanned instead, which allocates.
---@param module ModuleKit.Module
---@return ModuleKit.Module[] dependents read-only
local function hardDependentsOf(module)
  local addon = module._addon
  local cachedDependents = addon._graphDependents
  if cachedDependents ~= nil then
    return cachedDependents[module] or NO_MODULES
  end

  local order = addon._moduleOrder
  local moduleName = module._name
  local result
  for index = #order, 1, -1 do
    local candidate = order[index]
    if
      candidate ~= module
      and rawget(moduleNameSet(candidate, "_hardDependencies"), moduleName) == true
    then
      result = result or {}
      result[#result + 1] = candidate
    end
  end
  return result or NO_MODULES
end

---Return the newest enabled module that requires `module`, if any.
---
---The disable paths ask only whether such a dependent exists and which one to
---name, so this answers without building a list.
---@param module ModuleKit.Module
---@return ModuleKit.Module|nil dependent
local function firstEnabledHardDependent(module)
  -- The cached lookup is written out: the disable pass asks this for every
  -- enabled module, and most have no dependents at all.
  local cachedDependents = module._addon._graphDependents
  local dependents
  if cachedDependents ~= nil then
    dependents = cachedDependents[module]
    if dependents == nil then
      return nil
    end
  else
    dependents = hardDependentsOf(module)
  end
  for index = 1, #dependents do
    local dependent = dependents[index]
    if dependent._state == "enabled" then
      return dependent
    end
  end
  return nil
end

---Return the enabled modules that require `module`, newest first.
---
---Allocates a list only when there is at least one.
---@param module ModuleKit.Module
---@return ModuleKit.Module[] dependents read-only when empty
local function enabledHardDependents(module)
  local dependents = hardDependentsOf(module)
  local result
  for index = 1, #dependents do
    local dependent = dependents[index]
    if dependent._state == "enabled" then
      result = result or {}
      result[#result + 1] = dependent
    end
  end
  return result or NO_MODULES
end

---Order the currently enabled modules by their hard dependencies alone.
---@param addon ModuleKit.Addon
---@return ModuleKit.Module[] order
local function buildEnabledHardOrder(addon)
  local allModules = addon._moduleOrder
  local modulesByName = addon._modules
  local order = {}
  local enabled = {}

  for index = 1, #allModules do
    local module = allModules[index]
    if module._state == "enabled" then
      order[#order + 1] = module
      enabled[module] = true
    end
  end

  local adjacency = {}
  local indegree = {}
  for index = 1, #order do
    local module = order[index]
    adjacency[module] = {}
    indegree[module] = 0
  end

  for index = 1, #order do
    local module = order[index]
    for dependencyName in pairs(moduleNameSet(module, "_hardDependencies")) do
      local dependency = rawget(modulesByName, dependencyName)
      if dependency ~= nil and enabled[dependency] then
        addEdge(adjacency, indegree, dependency, module)
      end
    end
  end

  local result = topologicalSort(order, adjacency, indegree)
  if result == nil then
    -- A hard-dependency cycle cannot be produced by supported lifecycle
    -- operations. If state was externally corrupted, shutdown still needs
    -- a deterministic best-effort cleanup order rather than leaking every
    -- enabled module.
    return order
  end

  return result
end

-- Optional packages ---------------------------------------------------------

---Silent optional-dependency lookup.
---
---Registry revision 7 added `Find`; an older Registry's `Get` also returns
---`nil` for a missing package, so it is a correct fallback. The method is read
---on every call because an embedded Registry upgrade replaces it in place.
---@param packageName string
---@param api integer
---@return table|nil
local function findOptionalPackage(packageName, api)
  local find = rawget(Registry, "Find")
  if type(find) ~= "function" then
    find = rawget(Registry, "Get")
  end
  local implementation = find(Registry, packageName, api)
  if type(implementation) ~= "table" then
    return nil
  end
  return implementation
end

-- The file an addon adds for SignalKit's buses, named in the missing-part
-- errors of `scope.Messages` and `OnModuleCreated`.
local SIGNALKIT_BUS_FILE = "signalKit\\parts\\SignalKit-Bus.lua"

---Whether a SignalKit facade serves buses.
---
---A SignalKit split into parts (revision 13 on) keeps `Bus` and `ForAddon` on
---its facade as stubs that raise until its Bus part loads, so only `HasPart`
---can tell; a revision before 13 has no `HasPart` and serves buses when it has
---both methods.
---@param kit table the SignalKit facade
---@return boolean
local function signalKitHasBuses(kit)
  local hasPart = rawget(kit, "HasPart")
  if type(hasPart) == "function" then
    return hasPart(kit, "Bus") == true
  end
  return type(rawget(kit, "Bus")) == "function" and type(rawget(kit, "ForAddon")) == "function"
end

-- Module scopes -------------------------------------------------------------
--
-- A module registers addon-message prefixes, slash commands, timers, events,
-- scheduler jobs, hooks and bus subscriptions through `module.scope`, and
-- ModuleKit releases all of them when the module is disabled, so a module
-- needs no `OnDisable` just to clean up.
-- ModuleKit has no hard dependency on the Kits behind the scope: each is
-- resolved through `Registry:Find` on first use, and a field whose Kit is not
-- loaded reads as `nil`.

---The order scope fields are closed in. It is alphabetical, which is all it
---needs to be: the fields are independent of each other.
local SCOPE_FIELDS = { "Comm", "Commands", "Events", "Hooks", "Jobs", "Messages", "Timers" }

---The Kit behind each scope field.
local SCOPE_PACKAGES = {
  Comm = "commKit",
  Commands = "commandKit",
  Events = "eventKit",
  Hooks = "hookKit",
  Jobs = "schedulerKit",
  Messages = "signalKit",
  Timers = "timerKit",
}
-- commKit, commandKit, eventKit, hookKit, schedulerKit, signalKit and timerKit
-- are all API generation 1.
local SCOPE_PACKAGE_API = 1

---Create the scope field `key` on first read; the module scope's `__index`.
---Its helpers live in this block to keep the main chunk under Lua 5.1's
---200-local limit.
---@type fun(scope: ModuleKit.Scope, key: any): table|nil
local scopeIndex
do
  ---Create an owner scope through the Kit's own `CreateScope()`.
  ---
  ---Used by every field but `Messages`.
  ---@param kit table the Kit's facade
  ---@return table|nil scope `nil` for a Kit revision without owner scopes
  local function createKitScope(kit)
    local createScope = rawget(kit, "CreateScope")
    if type(createScope) ~= "function" then
      return nil
    end
    return createScope(kit)
  end

  ---Create a scope over the SignalKit bus of the module's addon.
  ---
  ---The caller has checked that `kit` serves buses (`signalKitHasBuses`). A
  ---bus that cannot be had yields `nil`: `ForAddon` answers `nil, "full"` when
  ---the session already holds its bound of buses, and a bus that was closed
  ---refuses new scopes. The field then reads as `nil`, exactly as it does when
  ---the Kit is absent.
  ---@param kit table the SignalKit facade
  ---@param module ModuleKit.Module
  ---@return table|nil scope
  local function createMessagesScope(kit, module)
    local addonName = rawget(module._addon, "_name")
    local bus = rawget(kit, "ForAddon")(kit, addonName)
    if type(bus) ~= "table" then
      return nil
    end

    -- A closed bus raises from `CreateScope`, and it offers no public query to
    -- ask first; the refusal is the answer.
    local ok, scope = pcall(bus.CreateScope, bus)
    if not ok then
      return nil
    end
    return scope
  end

  -- The facade behind each scope field, for the missing-Kit error.
  local SCOPE_FACADES = {
    Comm = "CommKit",
    Commands = "CommandKit",
    Events = "EventKit",
    Hooks = "HookKit",
    Jobs = "SchedulerKit",
    Messages = "SignalKit",
    Timers = "TimerKit",
  }

  ---Answer a scope field whose Kit is not loaded, or is a revision without
  ---owner scopes: `nil`, or under the container's `"raise"` policy an error at
  ---the line that read the field (`__index` is one frame below it).
  ---@param module ModuleKit.Module
  ---@param key string a scope field name
  local function missingScopeKit(module, key)
    if rawget(module._addon, "_missingScopePolicy") ~= "raise" then
      return
    end
    local facade = SCOPE_FACADES[key]
    local signalKit = key == "Messages"
        and findOptionalPackage(SCOPE_PACKAGES[key], SCOPE_PACKAGE_API)
      or nil
    if signalKit ~= nil and rawget(signalKit, "HasPart") ~= nil then
      -- SignalKit is split into parts and loaded without its Bus part: name
      -- the part's file rather than SignalKit's core.
      error(
        'ModuleKit module "'
          .. tostring(module._name)
          .. "\" scope.Messages needs SignalKit's Bus part, which is not loaded; add "
          .. SIGNALKIT_BUS_FILE
          .. " from MoltenCodes to your embeds.xml after signalKit\\SignalKit.lua",
        3
      )
    end
    error(
      'ModuleKit module "'
        .. tostring(module._name)
        .. '" scope.'
        .. key
        .. " needs "
        .. facade
        .. " API "
        .. SCOPE_PACKAGE_API
        .. ", which is not loaded; add "
        .. SCOPE_PACKAGES[key]
        .. "\\"
        .. facade
        .. ".lua from MoltenCodes to your embeds.xml",
      3
    )
  end

  ---Reopen a scope the module kept from its last enabled period.
  ---
  ---Only a Kit scope with `Reopen` is ever kept (see `closeModuleScope`). A
  ---reopen that raises or answers anything but `true` gives the scope up, and
  ---the caller creates a new one as before; nothing reaches the module.
  ---@param kept table the closed, empty Kit scope
  ---@return boolean reopened
  local function reopenKeptScope(kept)
    local reopen = kept.Reopen
    if type(reopen) ~= "function" then
      return false
    end
    local ok, reopened = pcall(reopen, kept)
    return ok and reopened == true
  end

  ---Create the scope field `key` on first read.
  ---
  ---The field is written onto the scope with `rawset`, so every later read is a
  ---plain table hit and this function runs once per field per enable. The scope
  ---closed at the module's last disable is reopened when its Kit can, so the
  ---field is the same object across enable cycles and the Registry lookup and the
  ---construction are skipped.
  ---
  ---`key` is never a secret: the client raises on `scope[secret]` before any
  ---`__index` runs (docs/EMBEDDING.md, measured on Retail 12.1.0).
  ---@param scope ModuleKit.Scope
  ---@param key any
  ---@return table|nil
  function scopeIndex(scope, key)
    local packageName = SCOPE_PACKAGES[key]
    if packageName == nil then
      return nil
    end

    local module = rawget(scope, "_module")
    if module._scopeOpen ~= true then
      error(
        'ModuleKit module "'
          .. tostring(module._name)
          .. '" scope.'
          .. key
          .. " is available only while the module is enabling or enabled",
        2
      )
    end

    local keptScopes = module._keptScopes
    if keptScopes ~= nil then
      local kept = keptScopes[key]
      if kept ~= nil then
        keptScopes[key] = nil
        if reopenKeptScope(kept) then
          rawset(scope, key, kept)
          return kept
        end
      end
    end

    local kit = findOptionalPackage(packageName, SCOPE_PACKAGE_API)
    if type(kit) == "nil" then
      -- Not a tail call, so the error level still counts this frame.
      missingScopeKit(module, key)
      return nil
    end

    local created
    if key == "Messages" then
      if not signalKitHasBuses(kit) then
        -- Not a tail call, so the error level still counts this frame.
        missingScopeKit(module, key)
        return nil
      end
      created = createMessagesScope(kit, module)
    else
      if type(rawget(kit, "CreateScope")) ~= "function" then
        -- Not a tail call, so the error level still counts this frame.
        missingScopeKit(module, key)
        return nil
      end
      created = createKitScope(kit)
    end
    if type(created) == "nil" then
      -- A bus that cannot be had: a runtime state, not a missing file, so it
      -- reads as `nil` under either policy. Nothing is stored, so a later read
      -- tries again.
      return nil
    end

    rawset(scope, key, created)
    return created
  end
end

---Create the scope object a module carries for its whole life.
---@param module ModuleKit.Module
---@return ModuleKit.Scope
local function newModuleScope(module)
  return setmetatable({ _module = module }, SCOPE_METATABLE)
end

---Close every scope field the module created and mark the scope closed.
---
---Every field is closed even when one `Close` raises; the first failure is
---returned so the caller can re-raise it once the module's state is settled.
---@param module ModuleKit.Module
---@return ModuleKit.ErrorRecord|nil firstError
local function closeModuleScope(module)
  module._scopeOpen = false

  local scope = module._scope
  if scope == nil then
    return nil
  end
  -- A scope holds `_module` and whatever fields were read. When the only key
  -- is `_module` there is nothing to close, which is the usual case and
  -- costs one or two `next` calls instead of a read per field.
  local firstKey = next(scope)
  if firstKey == "_module" and next(scope, firstKey) == nil then
    return nil
  end

  local firstError
  for index = 1, #SCOPE_FIELDS do
    local key = SCOPE_FIELDS[index]
    local owned = rawget(scope, key)
    if owned ~= nil then
      rawset(scope, key, nil)
      local close = type(owned) == "table" and owned.Close or nil
      if type(close) == "function" then
        local ok, value = pcall(close, owned)
        if not ok then
          if firstError == nil then
            firstError = { value = value }
          end
        elseif type(owned.Reopen) == "function" then
          -- Closed cleanly and can be reopened: kept for the next enable.
          local keptScopes = module._keptScopes
          if keptScopes == nil then
            keptScopes = {}
            module._keptScopes = keptScopes
          end
          keptScopes[key] = owned
        end
      end
    end
  end
  return firstError
end

-- Lifecycle operations ------------------------------------------------------

---Keep the first failure of a pass that continues after independent errors.
---@param current ModuleKit.ErrorRecord|nil
---@param ok boolean
---@param value any
---@return ModuleKit.ErrorRecord|nil
local function captureFirstError(current, ok, value)
  if current ~= nil or ok then
    return current
  end
  return { value = value }
end

---Re-raise a captured failure unchanged, or return when there was none.
---@param record ModuleKit.ErrorRecord|nil
local function raiseCaptured(record)
  if record ~= nil then
    error(record.value, 0)
  end
end

---Record why the last operation on `module` did not complete.
---@param module ModuleKit.Module
---@param value any error object, which may legitimately be `nil`
---@param blockedBy string|nil dependency or dependent name that blocked it
---@param hasError boolean whether `value` is a real error object
local function recordFailure(module, value, blockedBy, hasError)
  module._lastError = value
  if hasError == true then
    module._hasLastError = true
  elseif module._hasLastError ~= nil then
    module._hasLastError = nil
  end
  module._blockedBy = blockedBy
end

---Clear the failure record after a successful transition.
---
---An absent `_hasLastError` reads as `false`, so a module that never failed
---carries none of the three fields. Only `recordFailure(..., true)` stores an
---error object, and it always stores `_hasLastError` beside it (every other
---failure records `nil`), so testing the flag covers `_lastError` without
---reading the consumer's error object.
---
---Each field is cleared only when set. Lua 5.1 stores a key even when `nil` is
---assigned to it while it is absent, so an unconditional clear would spend a
---table slot on every field and eventually force a rehash; ModuleKit clears
---its own optional fields this way throughout. This runs on every successful
---transition, and two reads are all it costs a module that has not failed.
---@param module ModuleKit.Module
local function clearFailure(module)
  if module._hasLastError ~= nil then
    module._hasLastError = nil
    module._lastError = nil
  end
  if module._blockedBy ~= nil then
    module._blockedBy = nil
  end
end

---Call one consumer lifecycle hook, if the module defines it.
---@param module ModuleKit.Module
---@param name "OnInitialize"|"OnEnable"|"OnDisable"
---@return boolean ok
---@return any errorValue
local function invokeHook(module, name)
  local callback = rawget(module, name)
  -- A module created with a prototype may inherit its hooks from it; the
  -- lookup goes through the module's layer, so framework methods still win.
  if callback == nil and module._prototype ~= nil then
    callback = module[name]
  end
  local kind = type(callback)
  if kind == "function" then
    return pcall(callback, module, module._injections)
  end
  if kind == "nil" then
    return true, nil
  end
  return false, 'ModuleKit module "' .. module._name .. '" ' .. name .. " must be a function"
end

---Initialize exactly `module`, ignoring dependency policy.
---@param module ModuleKit.Module
---@return ModuleKit.Module module
local function initializeOne(module)
  local current = module._state
  if current ~= "created" then
    return module
  end

  -- The Injection part resolves the declared aliases; without it every
  -- module receives an empty table of its own (`defaultResolveForHook`).
  local ok, injectionsOrError = pcall(dispatch.resolveForHook, module)
  if not ok then
    recordFailure(module, injectionsOrError, nil, true)
    error(injectionsOrError, 0)
  end

  local hookOk, hookError = invokeHook(module, "OnInitialize")
  if not hookOk then
    module._injections = nil
    recordFailure(module, hookError, nil, true)
    error(hookError, 0)
  end

  module._state = "initialized"
  clearFailure(module)
  return module
end

-- Halted addons -------------------------------------------------------------
--
-- LifecycleKit lets an addon declare itself non-functional for the rest of the
-- session (`Halt`), and tells the addons that declared it with `DependsOn`.
-- ModuleKit maps both onto the enable state: the module keeps its intent, is
-- taken down, and records what blocks it. Halted is terminal, so nothing ever
-- recovers such a module; every enable path refuses it instead. The core
-- answers the container's own halt; another addon's halt is the
-- RequiredAddons part's, reached through `dispatch.requiredAddonBlocker` and
-- `dispatch.dependencyHalted`.

---Record what keeps the wanted `module` off, and tell its container that a
---blocked module may exist.
---
---`_mayHaveBlocked` lets `recoverBlockedDependents` skip its scan of every
---module on the many enables where nothing is blocked. It is set here, at
---every write of a blocker, and cleared only by a scan that found none; a
---container an older revision made has no flag and is scanned as before.
---@param module ModuleKit.Module
---@param blocker string
local function markBlocked(module, blocker)
  module._enableBlockedBy = blocker
  module._addon._mayHaveBlocked = true
end

---Whether the addon that owns `addon` has halted.
---
---A LifecycleKit revision older than the halted state has no `IsHalted`; its
---addons never halt.
---@param addon ModuleKit.Addon
---@return boolean
local function isContainerHalted(addon)
  local lifecycle = addon._lifecycle
  local isHalted = type(lifecycle) == "table" and lifecycle.IsHalted or nil
  return type(isHalted) == "function" and isHalted(lifecycle) == true
end

---Return what a halt blocks `module` on, if anything.
---@param module ModuleKit.Module
---@return string|nil blocker `"halted"` when its own addon halted, the first halted addon of `requiresAddons`, or `nil`
local function haltBlocker(module)
  -- Every enable asks this twice, before and after `OnEnable`, so the halt
  -- is read from the instance's `_halted` field, which LifecycleKit documents
  -- as a stable API 1 field and sets before it tells anyone of the halt. An
  -- instance of a revision older than the halted state has no such field and
  -- never halts. `_lifecycle` is always the instance `LifecycleKit:ForAddon`
  -- returned (`installAddonSubscriptions` refuses a container without one).
  if rawget(module._addon._lifecycle, "_halted") == true then
    return OWN_ADDON_HALTED
  end

  -- Only the RequiredAddons part gives a module `_requiredAddons`, and it
  -- answers which of them halted.
  if module._requiredAddons == nil then
    return nil
  end
  return dispatch.requiredAddonBlocker(module)
end

---Record that an enable of `module` was refused because of a halt.
---@param module ModuleKit.Module
---@param blocker string what `haltBlocker` returned
local function recordHaltRefusal(module, blocker)
  recordFailure(module, nil, blocker, false)
  if module._wantedEnabled == true then
    markBlocked(module, blocker)
  end
end

---The message a refused targeted enable raises.
---@param module ModuleKit.Module
---@param blocker string what `haltBlocker` returned
---@return string
local function haltRefusalMessage(module, blocker)
  local prefix = 'ModuleKit module "' .. module._name .. '" cannot be enabled because '
  if blocker == OWN_ADDON_HALTED then
    return prefix .. 'its addon "' .. module._addon._name .. '" has halted'
  end
  return prefix .. 'required addon "' .. blocker .. '" has halted'
end

---Disable exactly `module`, ignoring dependency policy.
---@param module ModuleKit.Module
---@return ModuleKit.Module module
local function disableOne(module)
  if module._state ~= "enabled" then
    return module
  end

  local ok, value = invokeHook(module, "OnDisable")
  if not ok then
    recordFailure(module, value, nil, true)
    error(value, 0)
  end

  module._state = "disabled"
  clearFailure(module)

  -- The module is disabled either way; a scope that failed to close is
  -- reported after the transition rather than leaving the module enabled.
  local scopeFailure = closeModuleScope(module)
  if scopeFailure ~= nil then
    raiseCaptured(scopeFailure)
  end
  return module
end

---Enable exactly `module`, initializing it first when it is still `created`.
---@param module ModuleKit.Module
---@param level integer error level of an unexpected-state refusal, counted from this function
---@return ModuleKit.Module module
local function enableOne(module, level)
  local current = module._state
  if current == "enabled" then
    return module
  end
  if current == "created" then
    initializeOne(module)
    current = module._state
  end
  if current ~= "initialized" and current ~= "disabled" then
    error(
      'ModuleKit module "'
        .. module._name
        .. '" cannot be enabled from state "'
        .. tostring(current)
        .. '"',
      level
    )
  end

  -- The scope is usable from `OnEnable` on, so a hook can register the
  -- work it owns. A failed `OnEnable` leaves the module where it was, so
  -- whatever it registered before failing is released with it.
  module._scopeOpen = true
  local ok, value = invokeHook(module, "OnEnable")
  if not ok then
    closeModuleScope(module)
    recordFailure(module, value, nil, true)
    error(value, 0)
  end

  module._state = "enabled"
  module._wantedEnabled = true
  if module._enableBlockedBy ~= nil then
    module._enableBlockedBy = nil
  end
  clearFailure(module)

  -- `OnEnable` may itself halt the addon or a required addon, typically on
  -- finding its saved variables unusable. The halt pass skipped this module
  -- because it was not enabled yet, so it is taken down here, as that pass
  -- would have: disabled, still wanted, and blocked by the halt.
  local blocker = haltBlocker(module)
  if blocker == OWN_ADDON_HALTED then
    -- Terminal cleanup, like the halt pass: the scope is released even
    -- when `OnDisable` fails.
    markBlocked(module, OWN_ADDON_HALTED)
    local disabled, failure = pcall(disableOne, module)
    if not disabled then
      closeModuleScope(module)
      error(failure, 0)
    end
  elseif blocker ~= nil then
    markBlocked(module, blocker)
    disableOne(module)
  end
  return module
end

---Record that `module` is meant to stay disabled, which also ends any wait
---for a dependency to recover.
---@param module ModuleKit.Module
local function markWantedDisabled(module)
  module._wantedEnabled = false
  if module._enableBlockedBy ~= nil then
    module._enableBlockedBy = nil
  end
end

---Initialize `module` under the container's dependency policy.
---
---Like `enableWithPolicy`, the `automatic` recursion adds its depth to the
---error level, so a cycle or a missing dependency found deep in the chain is
---reported at the line that called `Initialize` or `Activate`.
---@param module ModuleKit.Module
---@param visiting table<ModuleKit.Module, boolean>|nil recursion guard, `automatic` policy only
---@param depth integer|nil frames between this call and the public method: the recursion depth, plus two under definition catch-up; `nil` for a direct call
---@return ModuleKit.Module module
local function initializeWithPolicy(module, visiting, depth)
  depth = depth or 0
  local addon = module._addon
  ensureNotShutdown(addon, "ModuleKit.Module:Initialize", 4 + depth)

  if module._state ~= "created" then
    return module
  end

  local dependencies = hardDependencies(module, 4 + depth)
  local policy = addon._dependencyPolicy

  if policy == "automatic" then
    -- A module that requires nothing cannot close a cycle, so it needs no
    -- recursion guard and allocates none.
    if #dependencies > 0 then
      visiting = visiting or {}
      if visiting[module] then
        error(
          'ModuleKit dependency cycle detected while initializing "' .. module._name .. '"',
          3 + depth
        )
      end
      visiting[module] = true
      for index = 1, #dependencies do
        initializeWithPolicy(dependencies[index], visiting, depth + 1)
      end
      visiting[module] = nil
    end
  else
    for index = 1, #dependencies do
      local dependency = dependencies[index]
      if dependency._state == "created" then
        local name = dependency._name
        recordFailure(module, nil, name, false)
        error(
          'ModuleKit strict policy: module "'
            .. module._name
            .. '" requires initialized dependency "'
            .. name
            .. '"',
          3 + depth
        )
      end
    end
  end

  return initializeOne(module)
end

---Enable `module` under the container's dependency policy.
---
---The `automatic` policy recurses into hard dependencies, one stack frame per
---level, so `depth` is added to the error level: a refusal deep in the chain
---is still reported at the line that called `Enable` or `Activate`.
---@param module ModuleKit.Module
---@param visiting table<ModuleKit.Module, boolean>|nil recursion guard, `automatic` policy only
---@param depth integer|nil frames between this call and the public method: the recursion depth, plus two under definition catch-up; `nil` for a direct call
---@return ModuleKit.Module module
local function enableWithPolicy(module, visiting, depth)
  depth = depth or 0
  local addon = module._addon
  ensureNotShutdown(addon, "ModuleKit.Module:Enable", 4 + depth)

  -- A halt is terminal, so no dependency policy can satisfy it.
  if module._state ~= "enabled" then
    local blocker = haltBlocker(module)
    if blocker ~= nil then
      recordHaltRefusal(module, blocker)
      error(haltRefusalMessage(module, blocker), 3 + depth)
    end
  end

  local dependencies = hardDependencies(module, 4 + depth)
  local policy = addon._dependencyPolicy

  if policy == "automatic" then
    -- A module that requires nothing cannot close a cycle, so it needs no
    -- recursion guard and allocates none.
    if #dependencies > 0 then
      visiting = visiting or {}
      if visiting[module] then
        error(
          'ModuleKit dependency cycle detected while enabling "' .. module._name .. '"',
          3 + depth
        )
      end
      visiting[module] = true
      for index = 1, #dependencies do
        local dependency = dependencies[index]
        if dependency._state ~= "enabled" then
          -- Stays recorded if enabling the dependency raises, which is
          -- what lets the dependency's later recovery bring this module
          -- back; see `recoverBlockedDependents`.
          markBlocked(module, dependency._name)
        end
        enableWithPolicy(dependency, visiting, depth + 1)
        if dependency._state ~= "enabled" then
          -- A halt inside the dependency's own `OnEnable` took it down
          -- again (see `enableOne`). This module stays off. When the
          -- halt stops this module too (its own addon, or an addon it
          -- requires), the halt is what blocks it, as a direct `Enable`
          -- of it now records; otherwise the dependency does, exactly as
          -- the `ready` pass would leave it.
          local blocker = haltBlocker(module) or dependency._name
          recordFailure(module, nil, blocker, false)
          markBlocked(module, blocker)
          visiting[module] = nil
          return module
        end
      end
      visiting[module] = nil
    end
    if module._enableBlockedBy ~= nil then
      module._enableBlockedBy = nil
    end
  else
    for index = 1, #dependencies do
      local dependency = dependencies[index]
      if dependency._state ~= "enabled" then
        local name = dependency._name
        recordFailure(module, nil, name, false)
        markBlocked(module, name)
        error(
          'ModuleKit strict policy: module "'
            .. module._name
            .. '" requires enabled dependency "'
            .. name
            .. '"',
          3 + depth
        )
      end
    end
  end

  -- Not a tail call: the level counts this frame and every frame of the
  -- `automatic` recursion above it.
  enableOne(module, 4 + depth)
  return module
end

---Disable `module` under the container's dependency policy.
---@param module ModuleKit.Module
---@return ModuleKit.Module module
local function disableWithPolicy(module)
  local addon = module._addon
  local dependents = enabledHardDependents(module)
  local policy = addon._dependencyPolicy

  if policy == "strict" and #dependents > 0 then
    error(
      'ModuleKit strict policy: cannot disable module "'
        .. module._name
        .. '" while dependent "'
        .. dependents[1]._name
        .. '" is enabled',
      3
    )
  end

  if policy == "automatic" then
    for index = 1, #dependents do
      -- A cascade is a block, not a change of intent: the dependent
      -- still wants to be enabled and waits for this module, so it
      -- recovers when this module is enabled again.
      local dependent = dependents[index]
      disableWithPolicy(dependent)
      markBlocked(dependent, module._name)
    end
  end

  return disableOne(module)
end

---Enable every blocked module whose hard dependencies are now all enabled.
---
---A module blocked by a dependency keeps its intent (`_wantedEnabled`) and
---records the dependency in `_enableBlockedBy`. When the dependency enables
---later, this pass brings the module back. It walks the full graph order, so a
---whole chain recovers in one pass and ordering constraints are respected.
---
---It does nothing inside a whole-container pass, which decides blocking for
---every module it visits, or when the graph is invalid, which targeted
---operations tolerate but a graph-ordered pass cannot.
---@param addon ModuleKit.Addon
---@return ModuleKit.ErrorRecord|nil firstError
local function recoverBlockedDependents(addon)
  if addon._shutdown == true or addon._passDepth > 0 then
    return nil
  end

  -- Every targeted `Enable` ends here, and almost always nothing is blocked.
  -- `false` means no blocker was written since a scan last found none (see
  -- `markBlocked`); otherwise a linear scan is enough to skip building the
  -- graph, and to skip asking LifecycleKit about a halt.
  if addon._mayHaveBlocked == false then
    return nil
  end
  local modules = addon._moduleOrder
  local anyBlocked = false
  for index = 1, #modules do
    if modules[index]._enableBlockedBy ~= nil then
      anyBlocked = true
      break
    end
  end
  if not anyBlocked then
    addon._mayHaveBlocked = false
    return nil
  end
  if isContainerHalted(addon) then
    -- Halted is terminal: nothing in this container can recover.
    return nil
  end

  local graphOk, order = pcall(buildGraph, addon)
  if not graphOk then
    return nil
  end

  local firstError
  for index = 1, #order do
    local module = order[index]
    if
      module._wantedEnabled == true
      and module._enableBlockedBy ~= nil
      and module._state ~= "enabled"
    then
      local ready = true
      local dependencies = hardDependencies(module)
      for dependencyIndex = 1, #dependencies do
        if dependencies[dependencyIndex]._state ~= "enabled" then
          ready = false
          break
        end
      end
      -- A required addon that halted keeps the module blocked on it.
      local blocker = ready and haltBlocker(module) or nil
      if blocker ~= nil then
        markBlocked(module, blocker)
      elseif ready then
        -- From here a failure is the module's own, not its
        -- dependency's, so it is not retried by the next recovery.
        module._enableBlockedBy = nil
        local ok, value = pcall(enableOne, module)
        firstError = captureFirstError(firstError, ok, value)
      end
    end
  end
  return firstError
end

-- Whole-container passes ----------------------------------------------------

---Catch one module up to the LifecycleKit phases its container has reached.
---
---Reached from `CreateModule` through `scheduleCatchUp`, two frames below the
---public method, so a missing dependency, a cycle or a `strict` refusal is
---reported at the line that called `CreateModule`.
---@param addon ModuleKit.Addon
---@param module ModuleKit.Module
local function catchUpModule(addon, module)
  local lifecycle = addon._lifecycle
  if lifecycle:IsLoaded() then
    initializeWithPolicy(module, nil, 2)
  end
  -- Catch-up is implicit, like the `ready` pass, so a module that is not
  -- wanted (`enabledState = false`, or the container's default state) is
  -- initialized but not enabled.
  if lifecycle:IsReady() and module._wantedEnabled ~= false then
    -- Catch-up is implicit, so a halt blocks it quietly instead of
    -- raising out of `CreateModule`; an explicit `Enable` still raises.
    local blocker = module._state ~= "enabled" and haltBlocker(module) or nil
    if blocker ~= nil then
      recordHaltRefusal(module, blocker)
    else
      enableWithPolicy(module, nil, 2)
    end
  end
end

---Catch a module up now, or queue it while a whole-container pass is running.
---
---A hook can create a module while `InitializeAll` / `EnableAll` / `DisableAll`
---is walking the graph. Catching it up there and then would happen outside the
---running pass's blocking set, so a module could be activated even though a
---hard dependency had already failed in the same pass. The module is queued
---instead and caught up once the outermost pass has finished.
---@param addon ModuleKit.Addon
---@param module ModuleKit.Module
local function scheduleCatchUp(addon, module)
  if addon._passDepth > 0 then
    -- The queue exists only once something waited on a pass.
    local pending = addon._pendingCatchUp
    if pending == nil then
      pending = {}
      addon._pendingCatchUp = pending
    end
    pending[#pending + 1] = module
    return
  end
  catchUpModule(addon, module)
end

---Catch up every module queued while the pass that just finished was running.
---
---Catching one module up can create another. Outside a pass `scheduleCatchUp`
---handles those immediately, and a nested pass that ends mid-flush leaves its
---modules on the queue for this loop to pick up, so one flush is enough.
---@param addon ModuleKit.Addon
---@param firstError ModuleKit.ErrorRecord|nil error record captured so far
---@return ModuleKit.ErrorRecord|nil firstError
local function flushPendingCatchUp(addon, firstError)
  if addon._flushingCatchUp == true or addon._pendingCatchUp == nil then
    return firstError
  end
  addon._flushingCatchUp = true

  -- The queue is drained with a cursor rather than `table.remove(pending, 1)`,
  -- which shifted every remaining entry down one slot per module and made a
  -- flush quadratic in the number of modules waiting. Entries appended while
  -- the loop runs — catching one module up can queue another — are picked up
  -- by the same pass, so the order modules are caught up in is unchanged.
  local pending = addon._pendingCatchUp
  local cursor = 1
  while cursor <= #pending do
    local module = pending[cursor]
    cursor = cursor + 1
    local ok, value = pcall(catchUpModule, addon, module)
    firstError = captureFirstError(firstError, ok, value)
  end

  -- Entries are appended only from inside `catchUpModule`, which is what this
  -- loop calls, so the last length test already saw everything the flush
  -- produced and the queue can be emptied in one go.
  for index = #pending, 1, -1 do
    pending[index] = nil
  end

  addon._flushingCatchUp = false
  return firstError
end

---Run one whole-container pass with re-entrancy bookkeeping.
---
---The pass body reports its first captured error by returning it rather than
---raising, so the depth counter is always restored and the deferred catch-up
---queue is always flushed, whichever way the pass ends.
---@param addon ModuleKit.Addon
---@param pass fun(order: ModuleKit.Module[], option: boolean|nil): ModuleKit.ErrorRecord|nil
---@param order ModuleKit.Module[] modules in the order the pass must visit them
---@param shutdown boolean|nil the pass's second argument: terminal cleanup for the disable pass, lifecycle-driven for the enable pass
---@param seedError ModuleKit.ErrorRecord|nil error captured before the pass could start
---@return ModuleKit.Addon addon
local function runContainerPass(addon, pass, order, shutdown, seedError)
  addon._passDepth = addon._passDepth + 1
  local ok, result = pcall(pass, order, shutdown)
  local depth = addon._passDepth - 1
  addon._passDepth = depth

  local firstError = seedError
  if ok then
    if firstError == nil then
      firstError = result
    end
  else
    firstError = captureFirstError(firstError, ok, result)
  end

  if depth == 0 then
    firstError = flushPendingCatchUp(addon, firstError)
  end

  raiseCaptured(firstError)
  return addon
end

---Initialize every module in `order`.
---
---Independent modules continue after a failure. A module whose hard dependency
---failed, or never left `created`, is recorded as blocked instead of attempted.
---@param order ModuleKit.Module[]
---@return ModuleKit.ErrorRecord|nil firstError
local function runInitializeAllPass(order)
  local firstError
  -- Created on the first failure, so a pass where everything succeeds
  -- allocates nothing.
  local failed

  for index = 1, #order do
    local module = order[index]
    local blockedBy
    local dependencies = module._hardDependencyList or hardDependencies(module)
    for depIndex = 1, #dependencies do
      local dependency = dependencies[depIndex]
      if (failed ~= nil and failed[dependency]) or dependency._state == "created" then
        blockedBy = dependency._name
        break
      end
    end

    if blockedBy ~= nil then
      failed = failed or {}
      failed[module] = true
      recordFailure(module, nil, blockedBy, false)
    elseif module._state == "created" then
      local ok, value = pcall(initializeOne, module)
      if not ok then
        failed = failed or {}
        failed[module] = true
        firstError = captureFirstError(firstError, ok, value)
      end
    end
  end

  return firstError
end

---Initialize the whole container in deterministic graph order.
---@param addon ModuleKit.Addon
---@param level integer|nil error level counted from this function: `3` when `InitializeAll` calls it, the default
---@return ModuleKit.Addon addon
local function initializeAllInternal(addon, level)
  level = level or 3
  ensureNotShutdown(addon, "ModuleKit.Addon:InitializeAll", level + 1)
  local order = buildGraph(addon, level + 1)
  return runContainerPass(addon, runInitializeAllPass, order)
end

---Enable every module in `order`, initializing the ones still in `created`.
---
---A lifecycle-driven pass respects intent: a module an explicit `Disable`
---switched off stays off, and its hard dependents are recorded as blocked by
---it, so they recover if it is enabled later.
---@param order ModuleKit.Module[]
---@param lifecycleDriven boolean|nil `true` for the LifecycleKit `ready` phase
---@return ModuleKit.ErrorRecord|nil firstError
local function runEnableAllPass(order, lifecycleDriven)
  local firstError
  -- Created on the first failure or block, so a clean pass allocates nothing.
  local failed

  for index = 1, #order do
    local module = order[index]
    -- A module that is not wanted is left alone: not failed, not blocked.
    local wanted = not lifecycleDriven
      or module._wantedEnabled ~= false
      or module._state == "enabled"
    if wanted then
      -- A halt blocks the module like a failed dependency, and so blocks
      -- its dependents behind it.
      local blockedBy
      if module._state ~= "enabled" then
        blockedBy = haltBlocker(module)
      end
      local dependencies = module._hardDependencyList or hardDependencies(module)
      for depIndex = 1, #dependencies do
        if blockedBy ~= nil then
          break
        end
        local dependency = dependencies[depIndex]
        if (failed ~= nil and failed[dependency]) or dependency._state ~= "enabled" then
          blockedBy = dependency._name
        end
      end

      if blockedBy ~= nil then
        failed = failed or {}
        failed[module] = true
        recordFailure(module, nil, blockedBy, false)
        markBlocked(module, blockedBy)
      else
        local ok, value = pcall(enableOne, module)
        if not ok then
          failed = failed or {}
          failed[module] = true
          firstError = captureFirstError(firstError, ok, value)
        end
      end
    end
  end

  return firstError
end

---Enable the whole container in deterministic graph order.
---
---Called by the addon, this is a target state, not a delta: every module is
---meant to be enabled, including one that was explicitly disabled earlier.
---See `docs/API.md` for why. Driven by LifecycleKit's `ready` phase it states
---no intent of its own, so a module the addon disabled before `ready` stays
---disabled.
---@param addon ModuleKit.Addon
---@param lifecycleDriven boolean|nil `true` for the LifecycleKit `ready` phase
---@param level integer|nil error level counted from this function: `3` when `EnableAll` calls it, the default
---@return ModuleKit.Addon addon
local function enableAllInternal(addon, lifecycleDriven, level)
  level = level or 3
  ensureNotShutdown(addon, "ModuleKit.Addon:EnableAll", level + 1)
  local order = buildGraph(addon, level + 1)

  if not lifecycleDriven then
    -- The whole container is meant to be enabled; the pass records which
    -- modules a failed dependency blocks.
    for index = 1, #order do
      local module = order[index]
      module._wantedEnabled = true
      if module._enableBlockedBy ~= nil then
        module._enableBlockedBy = nil
      end
    end
  end

  return runContainerPass(addon, runEnableAllPass, order, lifecycleDriven)
end

---Disable every enabled module in `order`, walking it in reverse.
---@param order ModuleKit.Module[]
---@param shutdown boolean|nil terminal cleanup, which ignores dependent failures
---@return ModuleKit.ErrorRecord|nil firstError
local function runDisableAllPass(order, shutdown)
  local firstError

  for index = #order, 1, -1 do
    local module = order[index]
    if module._state == "enabled" then
      if not shutdown then
        local dependent = firstEnabledHardDependent(module)
        if dependent ~= nil then
          -- A previously attempted dependent failed to disable. Do
          -- not break the hard-dependency invariant in a reusable
          -- (non-terminal) container by disabling its dependency.
          recordFailure(module, nil, dependent._name, false)
        else
          local ok, value = pcall(disableOne, module)
          if not ok then
            firstError = captureFirstError(firstError, ok, value)
          end
        end
      else
        local ok, value = pcall(disableOne, module)
        if not ok then
          firstError = captureFirstError(firstError, ok, value)
          -- Shutdown is terminal: a module whose `OnDisable` failed
          -- still releases what it registered through its scope.
          closeModuleScope(module)
        end
      end
    end
  end

  return firstError
end

---Disable the whole container in reverse graph order.
---@param addon ModuleKit.Addon
---@param shutdown boolean `true` for terminal LifecycleKit cleanup
---@param level integer|nil error level of an invalid graph outside shutdown, counted from this function: `3` when `DisableAll` calls it, the default
---@return ModuleKit.Addon addon
local function disableAllInternal(addon, shutdown, level)
  local order
  local seedError

  if not shutdown then
    order = buildGraph(addon, (level or 3) + 1)
  else
    local graphOk, graphResult = pcall(buildGraph, addon)
    if graphOk then
      order = graphResult
    else
      -- Shutdown is terminal cleanup. A malformed inactive definition
      -- must not prevent already-enabled modules from releasing
      -- resources. Keep the graph error for diagnostics, but continue in
      -- a safe order based on the hard-dependency edges of enabled
      -- modules only.
      seedError = { value = graphResult }
      order = buildEnabledHardOrder(addon)
    end
  end

  if shutdown then
    addon._shutdown = true
  else
    for index = 1, #order do
      markWantedDisabled(order[index])
    end
  end

  return runContainerPass(addon, runDisableAllPass, order, shutdown, seedError)
end

-- Halt passes ---------------------------------------------------------------

---Take every module down after the container's own addon halted.
---
---LifecycleKit never delivers `shutdown` to a halted addon, so this is the
---container's terminal cleanup: it disables every enabled module in reverse
---graph order, best effort, exactly like shutdown (a module whose `OnDisable`
---fails still has its scopes closed). Unlike shutdown it keeps intent and
---leaves the container usable for inspection: every wanted module records
---`"halted"` as what blocks it.
---@param addon ModuleKit.Addon
---@return ModuleKit.Addon addon
local function haltAllInternal(addon)
  if addon._shutdown == true then
    return addon
  end

  local order
  local seedError
  local graphOk, graphResult = pcall(buildGraph, addon)
  if graphOk then
    order = graphResult
  else
    -- As at shutdown, an invalid inactive definition must not keep the
    -- enabled modules from releasing what they hold.
    seedError = { value = graphResult }
    order = buildEnabledHardOrder(addon)
  end

  local modules = addon._moduleOrder
  for index = 1, #modules do
    local module = modules[index]
    if module._wantedEnabled == true then
      markBlocked(module, OWN_ADDON_HALTED)
    end
  end

  return runContainerPass(addon, runDisableAllPass, order, true, seedError)
end

---Call one whole-container pass through shared runtime dispatch.
---
---Going through shared state rather than a captured local is what lets a newer
---compatible revision upgrade containers an older copy created.
---@param name "initializeAll"|"enableAll"|"shutdown"|"halted"|"dependencyHalted"
---@param addon ModuleKit.Addon
---@param argument any passed on after `addon`: the halted addon's name for `dependencyHalted`
---@return ModuleKit.Addon addon
local function invokeDispatch(name, addon, argument)
  local callback = dispatch[name]
  if type(callback) ~= "function" then
    error("MoltenCodes ModuleKit runtime dispatch is corrupted or incomplete", 2)
  end
  return callback(addon, argument)
end

-- Module public API ---------------------------------------------------------

---Return this module's name.
---@param self ModuleKit.Module
---@return string
local function moduleGetName(self)
  return rawget(self, "_name")
end

---Return the addon container that owns this module.
---@param self ModuleKit.Module
---@return ModuleKit.Addon
local function moduleGetAddon(self)
  return rawget(self, "_addon")
end

---Return the module's current stable state.
---@param self ModuleKit.Module
---@return ModuleKit.ModuleState
local function moduleGetState(self)
  return rawget(self, "_state")
end

---Report whether initialization has completed at least once.
---@param self ModuleKit.Module
---@return boolean
local function moduleIsInitialized(self)
  return rawget(self, "_state") ~= "created"
end

---Report whether the module is currently enabled.
---@param self ModuleKit.Module
---@return boolean
local function moduleIsEnabled(self)
  return rawget(self, "_state") == "enabled"
end

---Return the last error object, which may itself legitimately be `nil`.
---Pair with `HasLastError` to tell "no error" from "an error object of `nil`".
---@param self ModuleKit.Module
---@return any
local function moduleGetLastError(self)
  return rawget(self, "_lastError")
end

---Report whether the last operation recorded an actual error.
---@param self ModuleKit.Module
---@return boolean
local function moduleHasLastError(self)
  return rawget(self, "_hasLastError") == true
end

---Return the dependency or dependent name that blocked the last operation.
---@param self ModuleKit.Module
---@return string|nil
local function moduleGetBlockedBy(self)
  return rawget(self, "_blockedBy")
end

---Return a fresh snapshot of this module's intent and fact.
---
---`wanted` is what `Enable`/`Disable` (and the container-wide forms) last
---asked for; `actual` is whether the module is enabled right now; `blockedBy`
---names what keeps a wanted module off: a hard dependency, a required addon
---that halted, or `"halted"` when the module's own addon halted.
---@param self ModuleKit.Module
---@return ModuleKit.EnableState
local function moduleGetEnableState(self)
  return {
    wanted = rawget(self, "_wantedEnabled") == true,
    actual = rawget(self, "_state") == "enabled",
    blockedBy = rawget(self, "_enableBlockedBy"),
  }
end

---Return a shallow-copy snapshot of the resolved injection table.
---@param self ModuleKit.Module
---@return table<string, any>
local function moduleGetInjections(self)
  local injections = rawget(self, "_injections")
  if injections == nil then
    return {}
  end
  return shallowCopy(injections)
end

---Require `moduleName` to be active before this module, and order against it.
---@param self ModuleKit.Module
---@param moduleName string
---@return ModuleKit.Module self
local function moduleDependsOn(self, moduleName)
  return addNameConstraint(self, "_hardDependencies", moduleName, "DependsOn", 3)
end

---Order after `moduleName` when it exists, without requiring it.
---@param self ModuleKit.Module
---@param moduleName string
---@return ModuleKit.Module self
local function moduleOptionalDependency(self, moduleName)
  return addNameConstraint(self, "_optionalDependencies", moduleName, "OptionalDependency", 3)
end

---Order this module before `moduleName`, without requiring it.
---@param self ModuleKit.Module
---@param moduleName string
---@return ModuleKit.Module self
local function moduleBefore(self, moduleName)
  return addNameConstraint(self, "_before", moduleName, "Before", 3)
end

---Order this module after `moduleName`, without requiring it.
---@param self ModuleKit.Module
---@param moduleName string
---@return ModuleKit.Module self
local function moduleAfter(self, moduleName)
  return addNameConstraint(self, "_after", moduleName, "After", 3)
end

---Initialize this module under the container's dependency policy.
---@param self ModuleKit.Module
---@return ModuleKit.Module self
local function moduleInitialize(self)
  -- Not a tail call: the error levels `initializeWithPolicy` raises at
  -- count this frame.
  initializeWithPolicy(self)
  return self
end

---Enable this module under the container's dependency policy.
---@param self ModuleKit.Module
---@return ModuleKit.Module self
local function moduleEnable(self)
  -- Refused before the wanted state is recorded: a refused call must not
  -- change what `GetEnableState` reports. `enableWithPolicy` checks again.
  ensureNotShutdown(self._addon, "ModuleKit.Module:Enable", 3)
  self._wantedEnabled = true
  enableWithPolicy(self)
  raiseCaptured(recoverBlockedDependents(self._addon))
  return self
end

---Disable this module under the container's dependency policy.
---@param self ModuleKit.Module
---@return ModuleKit.Module self
local function moduleDisable(self)
  markWantedDisabled(self)
  return disableWithPolicy(self)
end

---Catch this module up to the LifecycleKit phases its container has reached.
---
---This is an explicit request, so it runs immediately even when called from a
---hook during a whole-container pass. Definition-table catch-up is deferred
---instead; see `scheduleCatchUp`.
---@param self ModuleKit.Module
---@return ModuleKit.Module self
local function moduleActivate(self)
  local addon = rawget(self, "_addon")
  local lifecycle = addon._lifecycle

  if lifecycle:IsLoaded() then
    initializeWithPolicy(self)
  end
  if lifecycle:IsReady() then
    enableWithPolicy(self)
    raiseCaptured(recoverBlockedDependents(addon))
  end
  return self
end

-- Addon public API ----------------------------------------------------------

---Return the addon name this container was created for.
---@param self ModuleKit.Addon
---@return string
local function addonGetAddonName(self)
  return rawget(self, "_name")
end

-- Container and module conveniences share one main-chunk local, because Lua
-- 5.1 allows a chunk at most 200 and this file sits near that limit: the
-- dependency and missing-scope policies, the module defaults (state and
-- prototype), the module-created notice, `SetEnabledState`, and the
-- prototype layers they rely on. The fields are installed on `Addon`,
-- `Module` and the facade in the commit section.
local addonConveniences = {
  -- The bus topic `CreateModule` publishes a new module on, once
  -- `OnModuleCreated` subscribed to it on the addon's SignalKit bus.
  MODULE_CREATED_TOPIC = "ModuleKit.ModuleCreated",
  -- The method a receiver subscribed without a method name is called by.
  MODULE_CREATED_METHOD = "OnModuleCreated",
}

---Return the container's dependency policy.
---@param self ModuleKit.Addon
---@return ModuleKit.DependencyPolicy
function addonConveniences.GetDependencyPolicy(self)
  return rawget(self, "_dependencyPolicy")
end

---Change the container's dependency policy. A secret policy is refused before
---it is compared with the two policy names, since comparing it would raise here
---instead of at the caller.
---@param self ModuleKit.Addon
---@param policy ModuleKit.DependencyPolicy
---@return ModuleKit.DependencyPolicy previous
function addonConveniences.SetDependencyPolicy(self, policy)
  ensureNotShutdown(self, "ModuleKit.Addon:SetDependencyPolicy", 3)
  if isSecret(policy) then
    error("ModuleKit.Addon:SetDependencyPolicy policy must not be a secret value", 2)
  end
  if policy ~= "automatic" and policy ~= "strict" then
    error('ModuleKit.Addon:SetDependencyPolicy policy must be "automatic" or "strict"', 2)
  end
  local previous = rawget(self, "_dependencyPolicy")
  rawset(self, "_dependencyPolicy", policy)
  return previous
end

---Return what reading a scope field answers when its Kit is not loaded.
---@param self ModuleKit.Addon
---@return ModuleKit.MissingScopePolicy
function addonConveniences.GetMissingScopePolicy(self)
  if rawget(self, "_missingScopePolicy") == "raise" then
    return "raise"
  end
  return "nil"
end

---Choose what reading a module scope field answers when the Kit behind it is
---not loaded, or is a revision without owner scopes: `"nil"`, the default, or
---`"raise"`, an error at the reading line that names the file to embed. A
---secret policy is refused before it is compared with the policy names.
---@param self ModuleKit.Addon
---@param policy ModuleKit.MissingScopePolicy
---@return ModuleKit.MissingScopePolicy previous
function addonConveniences.SetMissingScopePolicy(self, policy)
  ensureNotShutdown(self, "ModuleKit.Addon:SetMissingScopePolicy", 3)
  if isSecret(policy) then
    error("ModuleKit.Addon:SetMissingScopePolicy policy must not be a secret value", 2)
  end
  if policy ~= "nil" and policy ~= "raise" then
    error('ModuleKit.Addon:SetMissingScopePolicy policy must be "nil" or "raise"', 2)
  end
  local previous = addonConveniences.GetMissingScopePolicy(self)
  -- The default leaves no field behind, so a container that never chose a
  -- policy carries none.
  if policy == "raise" then
    rawset(self, "_missingScopePolicy", "raise")
  else
    rawset(self, "_missingScopePolicy", nil)
  end
  return previous
end

---Refuse a boolean argument that is secret or not a boolean.
---@param value any
---@param label string the argument in full, `ModuleKit.Module:SetEnabledState enabled`
---@param level integer stack level the failure is reported at, counted from this function
function addonConveniences.checkBoolean(value, label, level)
  if isSecret(value) then
    error(label .. " must not be a secret value", level)
  end
  if type(value) ~= "boolean" then
    error(label .. " must be a boolean", level)
  end
end

---Set what the module is meant to be, without running a hook or changing
---whether it is enabled now. `false` before the addon is ready keeps the
---module out of the `ready` pass; afterwards it changes what recovery and
---`GetEnableState` see. AceAddon-3.0's `SetEnabledState`.
---@param self ModuleKit.Module
---@param enabled boolean
---@return boolean previous the intent before this call
function addonConveniences.SetEnabledState(self, enabled)
  ensureNotShutdown(rawget(self, "_addon"), "ModuleKit.Module:SetEnabledState", 3)
  addonConveniences.checkBoolean(enabled, "ModuleKit.Module:SetEnabledState enabled", 3)
  local previous = rawget(self, "_wantedEnabled") ~= false
  if enabled then
    rawset(self, "_wantedEnabled", true)
  else
    markWantedDisabled(self)
  end
  return previous
end

---Set the starting intent of the modules this container creates from now on.
---AceAddon-3.0 refuses the call once a module exists; it applies forward here,
---because an AddonKit addon object is itself a module and always exists first.
---@param self ModuleKit.Addon
---@param enabled boolean
---@return boolean previous
function addonConveniences.SetDefaultModuleState(self, enabled)
  ensureNotShutdown(self, "ModuleKit.Addon:SetDefaultModuleState", 3)
  addonConveniences.checkBoolean(enabled, "ModuleKit.Addon:SetDefaultModuleState enabled", 3)
  local previous = rawget(self, "_defaultModuleState") ~= false
  -- The default, `true`, leaves no field behind.
  if enabled then
    rawset(self, "_defaultModuleState", nil)
  else
    rawset(self, "_defaultModuleState", false)
  end
  return previous
end

---Return the starting intent of modules created from now on.
---@param self ModuleKit.Addon
---@return boolean
function addonConveniences.GetDefaultModuleState(self)
  return rawget(self, "_defaultModuleState") ~= false
end

---Refuse a module prototype ModuleKit cannot honour: anything but a
---non-secret table, and a table whose own key would shadow what ModuleKit
---reads on a module: a `Module` method (framework methods always win, so the
---entry would never be seen), `scope`, or a private `_` field.
---@param prototype any
---@param label string the argument in full, `ModuleKit.Addon:SetDefaultModulePrototype prototype`
---@param level integer stack level the failure is reported at, counted from this function
function addonConveniences.checkPrototype(prototype, label, level)
  if isSecret(prototype) then
    error(label .. " must not be a secret value", level)
  end
  if type(prototype) ~= "table" then
    error(label .. " must be a table", level)
  end
  for key in next, prototype do
    if isSecret(key) then
      error(label .. " keys must not be secret values", level)
    end
    if type(key) == "string" then
      if rawget(Module, key) ~= nil then
        error(label .. ' key "' .. key .. "\" shadows ModuleKit's Module:" .. key, level)
      end
      if key == "scope" or key:sub(1, 1) == "_" then
        error(label .. ' key "' .. key .. '" is reserved for ModuleKit', level)
      end
    end
  end
end

---Copy the current `Module` methods into a prototype layer, dropping names
---that are no longer methods. Run when a layer is made and, for every layer,
---when a newer revision commits its methods.
---@param layer table
function addonConveniences.fillLayer(layer)
  for name in next, layer do
    rawset(layer, name, nil)
  end
  for name, method in next, Module do
    rawset(layer, name, method)
  end
end

---Refill every prototype layer from the current `Module` methods.
function addonConveniences.refreshLayers()
  for _, metatable in next, state.prototypeLayers do
    addonConveniences.fillLayer(rawget(metatable, "__index"))
  end
end

---The metatable of every module created with `prototype`, made once per
---prototype. Its `__index` is a layer holding the `Module` methods whose own
---`__index` is the prototype, so a lookup is table reads only: the module's
---own fields, then ModuleKit's methods, then the prototype. Layers live in
---the shared state for the session, as containers do; Lua 5.1 has no
---ephemeron tables, so a weak key would not let a prototype go either.
---@param prototype table
---@return table metatable
function addonConveniences.prototypeMetatable(prototype)
  local layers = state.prototypeLayers
  local metatable = rawget(layers, prototype)
  if metatable == nil then
    local layer = setmetatable({}, { __index = prototype })
    addonConveniences.fillLayer(layer)
    metatable = { __index = layer }
    rawset(layers, prototype, metatable)
  end
  return metatable
end

---Set the prototype of modules this container creates from now on, or clear
---it with `nil`. A module keeps the prototype it was created with.
---@param self ModuleKit.Addon
---@param prototype table|nil
---@return table|nil previous
function addonConveniences.SetDefaultModulePrototype(self, prototype)
  ensureNotShutdown(self, "ModuleKit.Addon:SetDefaultModulePrototype", 3)
  if isSecret(prototype) or prototype ~= nil then
    addonConveniences.checkPrototype(
      prototype,
      "ModuleKit.Addon:SetDefaultModulePrototype prototype",
      3
    )
  end
  local previous = rawget(self, "_defaultModulePrototype")
  rawset(self, "_defaultModulePrototype", prototype)
  return previous
end

---Return the prototype of modules created from now on, or `nil`.
---@param self ModuleKit.Addon
---@return table|nil
function addonConveniences.GetDefaultModulePrototype(self)
  return rawget(self, "_defaultModulePrototype")
end

---Call `callback(module)`, or `receiver[methodName](receiver, module)`, for
---every module this container creates from now on. The subscription is made
---on the addon's SignalKit bus, which isolates and reports a listener's
---error, so `CreateModule` still returns its module.
---@param self ModuleKit.Addon
---@param callback function|table a function, or a receiver table
---@param methodName string? the receiver's method; `"OnModuleCreated"` when omitted
---@return table|nil connection a SignalKit connection
---@return string|nil reason `"full"` at the bus limits
function addonConveniences.OnModuleCreated(self, callback, methodName)
  local label = "ModuleKit.Addon:OnModuleCreated"
  ensureNotShutdown(self, label, 3)
  if isSecret(callback) then
    error(label .. " callback must not be a secret value", 2)
  end
  if type(callback) == "table" then
    if methodName == nil then
      methodName = addonConveniences.MODULE_CREATED_METHOD
    end
    if isSecret(methodName) then
      error(label .. " methodName must not be a secret value", 2)
    end
    if type(methodName) ~= "string" or methodName == "" then
      error(label .. " methodName must be a non-empty string", 2)
    end
    if type(callback[methodName]) ~= "function" then
      error(label .. ' receiver has no method "' .. methodName .. '"', 2)
    end
  elseif type(callback) ~= "function" then
    error(label .. " callback must be a function, or a receiver table followed by a method name", 2)
  end

  local SignalKit = findOptionalPackage("signalKit", 1)
  if SignalKit == nil then
    error(label .. " needs SignalKit API 1, which is not loaded", 2)
  end
  if not signalKitHasBuses(SignalKit) then
    -- A SignalKit split into parts lacks only the part; an older one without
    -- `ForAddon` predates buses and counts as no SignalKit at all.
    if rawget(SignalKit, "HasPart") == nil then
      error(label .. " needs SignalKit API 1, which is not loaded", 2)
    end
    error(
      label
        .. " needs SignalKit's Bus part, which is not loaded: add "
        .. SIGNALKIT_BUS_FILE
        .. " to embeds.xml after signalKit\\SignalKit.lua",
      2
    )
  end
  local bus, reason = SignalKit:ForAddon(rawget(self, "_name"))
  if bus == nil then
    return nil, reason
  end
  local topic = addonConveniences.MODULE_CREATED_TOPIC
  local declared, declareReason = bus:DeclareTopic(topic, {
    arguments = 1,
    description = "ModuleKit created a module in this addon; the argument is the module.",
  })
  if not declared then
    return nil, declareReason
  end
  local connection, subscribeReason
  if type(callback) == "table" then
    connection, subscribeReason = bus:Subscribe(topic, callback, methodName)
  else
    connection, subscribeReason = bus:Subscribe(topic, callback)
  end
  if connection == nil then
    return nil, subscribeReason
  end
  rawset(self, "_moduleCreatedBus", bus)
  return connection
end

---Publish a module just created, when someone subscribed to the notice.
---@param addon ModuleKit.Addon
---@param module ModuleKit.Module
function addonConveniences.publishCreated(addon, module)
  local bus = addon._moduleCreatedBus
  if bus ~= nil then
    bus:Publish(addonConveniences.MODULE_CREATED_TOPIC, module)
  end
end

---Return the container for `addonName`, or `nil`, never creating one.
---@param self ModuleKit
---@param addonName string
---@return ModuleKit.Addon|nil
function addonConveniences.FindAddon(self, addonName)
  validateFacade(self, "ModuleKit:FindAddon", 3)
  validateNonEmptyString(addonName, "ModuleKit:FindAddon addonName", 3)
  return rawget(state.addons, addonName)
end

---Return a new sorted array of every container's addon name. Diagnostics: it
---allocates.
---@param self ModuleKit
---@return string[]
function addonConveniences.GetAddons(self)
  validateFacade(self, "ModuleKit:GetAddons", 3)
  local names = {}
  for name in next, state.addons do
    names[#names + 1] = name
  end
  table.sort(names)
  return names
end

local DEFINITION_FIELDS = {
  enabledState = true,
  prototype = true,
  dependsOn = true,
  optionalDependencies = true,
  before = true,
  after = true,
  requiresAddons = true,
  implements = true,
  inject = true,
  onInitialize = true,
  onEnable = true,
  onDisable = true,
}

---Refuse a definition field whose part is not loaded, naming the file to
---embed.
---@param field "inject"|"implements"|"requiresAddons"
---@param partName "Injection"|"Implements"|"RequiredAddons"
---@param level integer stack level the failure is reported at, counted from this function
local function refuseFieldWithoutPart(field, partName, level)
  if type(state.parts[partName]) ~= "table" then
    error(
      partMissingMessage(
        'ModuleKit.Addon:CreateModule definition field "' .. field .. '"',
        partName
      ),
      level
    )
  end
end

---Apply one dense-array definition field entry by entry: through the
---constraint `field` a `Module` method records, or, for `requiresAddons`
---(`field` is `nil`), through the RequiredAddons part's `addRequiredAddon`
---(`dispatch.addRequiredAddon`). Every refusal is raised at
---the caller of `CreateModule`, and an entry reports the same message the
---`Module` method it stands for would.
---@param module ModuleKit.Module
---@param definition ModuleKit.Definition
---@param key "dependsOn"|"optionalDependencies"|"before"|"after"|"requiresAddons"
---@param field "_hardDependencies"|"_optionalDependencies"|"_before"|"_after"|nil
---@param methodName string|nil the `Module` method the field stands for, used in the argument errors
local function applyDefinitionList(module, definition, key, field, methodName)
  local values = rawget(definition, key)
  if type(values) == "nil" then
    return
  end
  if type(values) ~= "table" then
    error("ModuleKit module definition " .. key .. " must be a dense array", 4)
  end

  local count = 0
  local maximum = 0
  for index in next, values do
    -- A secret key cannot be a dense-array index, and comparing it would
    -- raise here, so it is refused as a density failure first.
    if isSecret(index) or type(index) ~= "number" or index < 1 or index % 1 ~= 0 then
      error("ModuleKit module definition " .. key .. " must be a dense array", 4)
    end
    count = count + 1
    if index > maximum then
      maximum = index
    end
  end
  if count ~= maximum then
    error("ModuleKit module definition " .. key .. " must be a dense array", 4)
  end

  for index = 1, count do
    local value = rawget(values, index)
    if field == nil then
      -- Level 5 inside the part counts this frame, `applyDefinition` and
      -- `CreateModule`, as below.
      dispatch.addRequiredAddon(module, value)
    else
      -- A constraint field always comes with the method it stands for.
      ---@cast methodName string
      -- Level 5 counts this frame, `applyDefinition` and `CreateModule`.
      addNameConstraint(module, field, value, methodName, 5)
    end
  end
end

---Copy one definition hook onto the module under its public field name.
---@param module ModuleKit.Module
---@param definition ModuleKit.Definition
---@param key "onInitialize"|"onEnable"|"onDisable"
---@param field "OnInitialize"|"OnEnable"|"OnDisable"
local function applyDefinitionCallback(module, definition, key, field)
  local callback = rawget(definition, key)
  if type(callback) == "nil" then
    return
  end
  if type(callback) ~= "function" then
    error("ModuleKit module definition " .. key .. " must be a function", 4)
  end
  rawset(module, field, callback)
end

---Apply a complete definition table in a fixed, deterministic field order.
---
---Called by `CreateModule`, so its own refusals use level 3 and the helpers
---it calls count their frames on top.
---@param module ModuleKit.Module
---@param definition ModuleKit.Definition|nil
local function applyDefinition(module, definition)
  if type(definition) == "nil" then
    return
  end
  if type(definition) ~= "table" then
    error("ModuleKit.Addon:CreateModule definition must be a table when provided", 3)
  end

  local unknown = {}
  for key in next, definition do
    if isSecret(key) then
      error("ModuleKit module definition field names must not be secret values", 3)
    end
    if type(key) ~= "string" or DEFINITION_FIELDS[key] ~= true then
      unknown[#unknown + 1] = describeKey(key)
    end
  end
  if #unknown > 0 then
    table.sort(unknown)
    error('ModuleKit module definition contains unknown field "' .. unknown[1] .. '"', 3)
  end

  -- Apply in a fixed order so malformed definitions fail deterministically
  -- on every Lua implementation and every load order.
  local enabledState = rawget(definition, "enabledState")
  if isSecret(enabledState) or enabledState ~= nil then
    addonConveniences.checkBoolean(enabledState, "ModuleKit module definition enabledState", 4)
    module._wantedEnabled = enabledState
  end
  local prototype = rawget(definition, "prototype")
  if isSecret(prototype) or (prototype ~= nil and prototype ~= false) then
    addonConveniences.checkPrototype(prototype, "ModuleKit module definition prototype", 4)
  end
  applyDefinitionList(module, definition, "dependsOn", "_hardDependencies", "DependsOn")
  applyDefinitionList(
    module,
    definition,
    "optionalDependencies",
    "_optionalDependencies",
    "OptionalDependency"
  )
  applyDefinitionList(module, definition, "before", "_before", "Before")
  applyDefinitionList(module, definition, "after", "_after", "After")
  if rawget(definition, "requiresAddons") ~= nil then
    refuseFieldWithoutPart("requiresAddons", "RequiredAddons", 4)
    applyDefinitionList(module, definition, "requiresAddons", nil, nil)
  end

  local inject = rawget(definition, "inject")
  if type(inject) ~= "nil" then
    refuseFieldWithoutPart("inject", "Injection", 4)
    dispatch.addInjections(module, inject, nil, 4)
  end

  applyDefinitionCallback(module, definition, "onInitialize", "OnInitialize")
  applyDefinitionCallback(module, definition, "onEnable", "OnEnable")
  applyDefinitionCallback(module, definition, "onDisable", "OnDisable")
end

---Create a uniquely named module in this container.
---@param self ModuleKit.Addon
---@param name string
---@param definition ModuleKit.Definition|nil atomic definition table; see `docs/API.md`
---@return ModuleKit.Module module
local function addonCreateModule(self, name, definition)
  ensureNotShutdown(self, "ModuleKit.Addon:CreateModule", 3)
  validateNonEmptyString(name, "ModuleKit.Addon:CreateModule name", 3)

  local modules = self._modules
  -- `_providers` exists once the Injection part registered a provider.
  local providers = self._providers
  if rawget(modules, name) ~= nil or (providers ~= nil and rawget(providers, name) ~= nil) then
    error('ModuleKit.Addon:CreateModule name "' .. name .. '" is already in use', 2)
  end

  local order = self._moduleOrder
  -- Only what every module needs is stored. The constraint sets, the
  -- injection specification, `requiresAddons` and the failure record are
  -- absent until something writes them, and read as empty or `false` (see
  -- `moduleNameSet`, `haltBlocker`, `clearFailure`).
  --
  -- The entries written as `nil` reserve room: Lua 5.1 sizes a table's hash
  -- part from the number of fields in its constructor, and these are the
  -- fields almost every module receives next (its scope here, its hooks
  -- from the addon, its injections and scope flag when it enables). The
  -- module is then built with the sixteen slots it keeps, instead of being
  -- rehashed into them as fields arrive.
  local module = setmetatable({
    _addon = self,
    _name = name,
    _order = #order + 1,
    _state = "created",
    -- Every module is meant to be enabled once its addon is ready, until
    -- an explicit `Disable` says otherwise, unless the container's default
    -- state or the definition's `enabledState` says it is not.
    _wantedEnabled = rawget(self, "_defaultModuleState") ~= false,
    _scope = nil,
    scope = nil,
    OnInitialize = nil,
    OnEnable = nil,
    OnDisable = nil,
    _injections = nil,
    _scopeOpen = nil,
  }, MODULE_METATABLE)
  local scope = newModuleScope(module)
  module._scope = scope
  module.scope = scope

  applyDefinition(module, definition)
  -- The prototype is the definition's (`false` for none) or the container's
  -- default, chosen once: a later default does not change this module.
  local prototype = rawget(self, "_defaultModulePrototype")
  if type(definition) == "table" and rawget(definition, "prototype") ~= nil then
    prototype = rawget(definition, "prototype")
  end
  if prototype then
    module._prototype = prototype
    setmetatable(module, addonConveniences.prototypeMetatable(prototype))
  end
  -- The definition is atomic, so what the module carries when this returns
  -- is what it will carry: ModuleKit's own methods and the hooks the
  -- definition set. Checked before the module is published, so a refusal
  -- leaves the container without it.
  local implements = type(definition) == "table" and rawget(definition, "implements") or nil
  if implements ~= nil then
    refuseFieldWithoutPart("implements", "Implements", 3)
    local contract =
      dispatch.compileImplements(implements, "ModuleKit module definition implements", 3)
    dispatch.checkImplements(contract, module, 'module "' .. name .. '"', 3)
  end
  validateLateModuleOrdering(self, module)
  -- Only the RequiredAddons part gives a module required addons to declare.
  if module._requiredAddons ~= nil then
    dispatch.declareRequiredAddons(self, module)
  end

  rawset(modules, name, module)
  order[#order + 1] = module
  invalidateGraph(self)

  -- A required addon may have halted before this module existed, or the
  -- container's own addon may have: record the block now, so the enable
  -- state shows it before anything tries to enable the module.
  local blocker = haltBlocker(module)
  if blocker ~= nil and module._wantedEnabled == true then
    markBlocked(module, blocker)
  end

  -- Before the catch-up, so a listener can still give a late definition
  -- module what it needs before it initializes.
  addonConveniences.publishCreated(self, module)

  -- A fully specified late-created module can catch up immediately. For the
  -- common mutable-object style, omit the definition and call :Activate()
  -- after assigning callbacks/dependencies so no user setup is raced.
  --
  -- Created from a hook while a whole-container pass is running, the catch-up
  -- is deferred to the end of that pass; see `scheduleCatchUp`.
  if type(definition) ~= "nil" then
    scheduleCatchUp(self, module)
  end

  return module
end

---Return the named module, or `nil`.
---@param self ModuleKit.Addon
---@param name string
---@return ModuleKit.Module|nil
local function addonGetModule(self, name)
  validateNonEmptyString(name, "ModuleKit.Addon:GetModule name", 3)
  return rawget(rawget(self, "_modules"), name)
end

---Report whether the named module exists in this container.
---@param self ModuleKit.Addon
---@param name string
---@return boolean
local function addonHasModule(self, name)
  validateNonEmptyString(name, "ModuleKit.Addon:HasModule name", 3)
  return rawget(rawget(self, "_modules"), name) ~= nil
end

---Return a new array snapshot of every module, in creation order.
---@param self ModuleKit.Addon
---@return ModuleKit.Module[]
local function addonGetModules(self)
  local modules = {}
  local order = rawget(self, "_moduleOrder")
  for index = 1, #order do
    modules[index] = order[index]
  end
  return modules
end

---Return module names in deterministic full-graph topological order.
---@param self ModuleKit.Addon
---@return string[]
local function addonGetActivationOrder(self)
  local order = buildGraph(self)
  local names = {}
  for index = 1, #order do
    names[index] = rawget(order[index], "_name")
  end
  return names
end

---Validate the complete graph, raising a diagnostic on the first problem.
---@param self ModuleKit.Addon
---@return boolean `true` on success
local function addonValidateGraph(self)
  buildGraph(self)
  return true
end

---Initialize every module in the container.
---@param self ModuleKit.Addon
---@return ModuleKit.Addon self
local function addonInitializeAll(self)
  -- Not a tail call: the error levels `initializeAllInternal` raises at count
  -- this frame.
  local addon = initializeAllInternal(self, 3)
  return addon
end

---Enable every module in the container, including ones explicitly disabled.
---@param self ModuleKit.Addon
---@return ModuleKit.Addon self
local function addonEnableAll(self)
  -- Not a tail call, for the same reason as `addonInitializeAll`.
  local addon = enableAllInternal(self, false, 3)
  return addon
end

---Disable every enabled module without terminating the container.
---@param self ModuleKit.Addon
---@return ModuleKit.Addon self
local function addonDisableAll(self)
  -- Not a tail call, for the same reason as `addonInitializeAll`.
  local addon = disableAllInternal(self, false, 3)
  return addon
end

-- Addon creation / lifecycle integration -----------------------------------

---The LifecycleKit phases a container subscribes to, in delivery order.
local LIFECYCLE_PHASES = { "loaded", "ready", "shutdown" }

---LifecycleKit subscription method per phase.
local PHASE_SUBSCRIBE = {
  loaded = "OnLoaded",
  ready = "OnReady",
  shutdown = "OnShutdown",
}

---Shared runtime dispatch entry point per phase.
local PHASE_DISPATCH = {
  loaded = "initializeAll",
  ready = "enableAll",
  shutdown = "shutdown",
}

---Subscribe a new container to its addon's halted notice.
---
---A LifecycleKit revision older than the halted state offers no notice, and
---its addons never halt, so nothing is subscribed. The subscription replays
---synchronously for an addon that has already halted; a new container holds
---no modules yet, so the replay only records the halt. The notice of another
---addon's halt is the RequiredAddons part's, subscribed when a module first
---declares `requiresAddons`.
---@param addon ModuleKit.Addon
---@param lifecycle LifecycleKit.Instance
local function installHaltSubscription(addon, lifecycle)
  local onHalted = lifecycle.OnHalted
  if type(onHalted) ~= "function" then
    return
  end
  addon._subscriptions.halted = onHalted(lifecycle, function()
    -- Recorded first, like a phase: the halt has happened even if taking
    -- the modules down raises.
    addon._dispatched.halted = true
    invokeDispatch("halted", addon)
  end)
end

---Subscribe a new container to the LifecycleKit phases.
---
---LifecycleKit replays a phase it has already reached to every new
---subscriber, which is exactly what a freshly created container wants. The
---dispatched-phase set records each delivered phase before it runs, so a
---later revision that takes the container over never runs one twice.
---@param addon ModuleKit.Addon
local function installAddonSubscriptions(addon)
  local lifecycle = addon._lifecycle
  for index = 1, #LIFECYCLE_PHASES do
    local phase = LIFECYCLE_PHASES[index]
    local dispatchName = PHASE_DISPATCH[phase]
    local subscribe = lifecycle[PHASE_SUBSCRIBE[phase]]
    -- A replayed phase runs a pass over a container that holds no module
    -- yet, so nothing in the replay can shut the container down.
    addon._subscriptions[phase] = subscribe(lifecycle, function()
      -- Record the phase before dispatching. It has happened even if the
      -- dispatch raises, and a later in-place upgrade must not run it a
      -- second time.
      addon._dispatched[phase] = true
      return invokeDispatch(dispatchName, addon)
    end)
  end

  installHaltSubscription(addon, lifecycle)
end

---Create the container for `addonName` and bind it to its lifecycle.
---
---Providers, the resolution stack and the catch-up queue are created on
---first use (by the Injection part, or by the first deferred catch-up), so a
---container that never uses them carries none of them.
---@param addonName string
---@return ModuleKit.Addon
local function createAddon(addonName)
  local lifecycle = LifecycleKit:ForAddon(addonName)
  local addon = setmetatable({
    _name = addonName,
    _lifecycle = lifecycle,
    _dependencyPolicy = "automatic",
    _modules = {},
    _moduleOrder = {},
    _shutdown = lifecycle:IsShutdown(),
    _subscriptions = {},
    -- A new container has received nothing yet, so every phase LifecycleKit
    -- has already reached is replayed into it on subscription.
    _dispatched = {},
    _passDepth = 0,
    -- Nothing is blocked yet; see `markBlocked`.
    _mayHaveBlocked = false,
  }, ADDON_METATABLE)

  state.addons[addonName] = addon

  if not addon._shutdown then
    installAddonSubscriptions(addon)
  end

  return addon
end

---Return the stable container for `addonName`, creating it on demand.
---@param self ModuleKit
---@param addonName string addon folder name, as LifecycleKit matches it
---@return ModuleKit.Addon addon
local function forAddon(self, addonName)
  validateFacade(self, "ModuleKit:ForAddon", 3)
  validateNonEmptyString(addonName, "ModuleKit:ForAddon addonName", 3)

  local addon = state.addons[addonName]
  if addon ~= nil then
    return addon
  end
  return createAddon(addonName)
end

-- Package-wide limits ------------------------------------------------------

---Change any subset of the package-wide limits. Affects every consumer in the
---session. Lowering a limit never removes what modules already declared.
---
---The shared block checks the whole update first; `UNBOUNDED` is then refused
---when LifecycleKit reports a `maxDependencies` of its own, which the module
---could never exceed. Nothing is written until every check passed.
---@param self ModuleKit
---@param limits ModuleKit.Limits|table
local function setLimits(self, limits)
  validateFacade(self, "ModuleKit:SetLimits", 3)
  validateLimitUpdate(limits, 3)
  if rawget(limits, "maxRequiredAddons") == UNBOUNDED then
    local ceiling = lifecycleDependencyCeiling()
    if ceiling ~= nil then
      error(
        "ModuleKit:SetLimits limits.maxRequiredAddons cannot be ModuleKit.UNBOUNDED: "
          .. "LifecycleKit accepts at most "
          .. ceiling
          .. " dependencies per addon",
        2
      )
    end
  end
  applyLimitUpdate(sharedLimits, limits)
end

---Return a fresh copy of the package-wide limits. Allocates one table.
---@param self ModuleKit
---@return ModuleKit.Limits limits
local function getLimits(self)
  validateFacade(self, "ModuleKit:GetLimits", 3)
  return copyLimits(sharedLimits)
end

-- Parts ---------------------------------------------------------------------
--
-- The members of each part stay on the prototypes even without it: a stub
-- that raises at the caller's line with the file to embed. A Kit that uses a
-- part optionally asks `ModuleKit:HasPart`, never `type(member)`, which a stub
-- satisfies. The core reaches a part only through `state.dispatch`; the
-- defaults below stand in while a part is not loaded, and are exact then:
-- without the part no module can hold what it would serve. State an older
-- revision made for a part that is not loaded is left in place and reported
-- once through the host error handler when it would have been served.

-- The members each part provides, by prototype, and the dispatch entries it
-- fills (each with its default here).
local PART_LAYOUT = {
  Injection = {
    Addon = { "ProvideValue", "ProvideSingleton", "ProvideModule", "ProvideTransient", "Resolve" },
    Module = { "Resolve", "Inject" },
    dispatch = { "resolveForHook", "addInjections" },
  },
  Implements = { dispatch = { "compileImplements", "checkImplements" } },
  RequiredAddons = {
    dispatch = {
      "addRequiredAddon",
      "declareRequiredAddons",
      "requiredAddonBlocker",
      "dependencyHalted",
    },
  },
}

---Report once per part that state it would serve was found without it.
---@param partName string
---@param what string what was left unserved, for the message
local function reportUnserved(partName, what)
  local reported = state.unservedReported
  if reported[partName] == true then
    return
  end
  reported[partName] = true
  reportError(
    "MoltenCodes ModuleKit found "
      .. what
      .. " an earlier revision made: "
      .. partMissingMessage("serving it", partName)
  )
end

-- The dispatch defaults, used while their part is not loaded.
local PART_DEFAULTS = {
  -- Every module gets an injection table of its own, even with nothing to
  -- inject: its hooks receive it and may write into it.
  resolveForHook = function(module)
    if module._injectSpec ~= nil then
      reportUnserved("Injection", "a module with injections")
    end
    local injections = {}
    module._injections = injections
    return injections
  end,
  -- The core refuses `inject`, `implements` and `requiresAddons` before it
  -- calls these, so only a corrupted state reaches them.
  addInjections = function()
    error("MoltenCodes ModuleKit runtime dispatch is corrupted or incomplete", 2)
  end,
  compileImplements = function()
    error("MoltenCodes ModuleKit runtime dispatch is corrupted or incomplete", 2)
  end,
  addRequiredAddon = function()
    error("MoltenCodes ModuleKit runtime dispatch is corrupted or incomplete", 2)
  end,
  -- A provider an earlier revision registered with an `implements` contract.
  checkImplements = function()
    reportUnserved("Implements", "an implements contract")
  end,
  declareRequiredAddons = function() end,
  requiredAddonBlocker = function()
    reportUnserved("RequiredAddons", "a module with requiresAddons")
    return nil
  end,
  dependencyHalted = function(addon)
    return addon
  end,
}

---A member that raises, at its caller's line, that `partName` is not loaded.
---@param label string the member as its caller wrote it, `ModuleKit.Addon:Resolve`
---@param partName string
---@return function
local function newPartStub(label, partName)
  -- The message is built only when the stub raises, so an addon that never
  -- calls a missing part holds no message text for it.
  return function()
    error(partMissingMessage(label, partName), 2)
  end
end

---Install a stub for every member, and the default for every dispatch entry,
---of each part that is not installed. A part already installed by any addon
---keeps its members and entries.
local function installPartStubs()
  for partName, layout in next, PART_LAYOUT do
    if type(state.parts[partName]) ~= "table" then
      for _, prototypeName in ipairs({ "Addon", "Module" }) do
        local members = layout[prototypeName]
        if members ~= nil then
          local prototype = prototypeName == "Addon" and Addon or Module
          for index = 1, #members do
            local member = members[index]
            rawset(
              prototype,
              member,
              newPartStub("ModuleKit." .. prototypeName .. ":" .. member, partName)
            )
          end
        end
      end
      local entries = layout.dispatch
      for index = 1, #entries do
        rawset(dispatch, entries[index], PART_DEFAULTS[entries[index]])
      end
    end
  end
end

---Whether the named part is installed in this session.
---@param self ModuleKit
---@param name string a part name: `"Injection"`, `"Implements"` or `"RequiredAddons"`
---@return boolean installed
local function hasPart(self, name)
  validateFacade(self, "ModuleKit:HasPart", 3)
  -- Refused before it is used as a key, which would raise here.
  if isSecret(name) then
    error("ModuleKit:HasPart name must not be a secret value", 2)
  end
  if type(name) ~= "string" then
    error("ModuleKit:HasPart name must be a part name string", 2)
  end
  return type(state.parts[name]) == "table"
end

-- Commit --------------------------------------------------------------------

rawset(Module, "GetName", moduleGetName)
rawset(Module, "GetAddon", moduleGetAddon)
rawset(Module, "GetState", moduleGetState)
rawset(Module, "IsInitialized", moduleIsInitialized)
rawset(Module, "IsEnabled", moduleIsEnabled)
rawset(Module, "GetLastError", moduleGetLastError)
rawset(Module, "HasLastError", moduleHasLastError)
rawset(Module, "GetBlockedBy", moduleGetBlockedBy)
rawset(Module, "GetEnableState", moduleGetEnableState)
rawset(Module, "GetInjections", moduleGetInjections)
rawset(Module, "DependsOn", moduleDependsOn)
rawset(Module, "OptionalDependency", moduleOptionalDependency)
rawset(Module, "Before", moduleBefore)
rawset(Module, "After", moduleAfter)
rawset(Module, "Initialize", moduleInitialize)
rawset(Module, "Enable", moduleEnable)
rawset(Module, "Disable", moduleDisable)
rawset(Module, "Activate", moduleActivate)
rawset(Module, "SetEnabledState", addonConveniences.SetEnabledState)

-- The members of every part not loaded are stubs; a loaded part keeps its own.
installPartStubs()

-- Every prototype layer holds a copy of the `Module` methods, so a module
-- created with a prototype by an older revision gains this revision's methods
-- here, as a plain module does through the shared `Module` table.
addonConveniences.refreshLayers()

rawset(Addon, "GetAddonName", addonGetAddonName)
rawset(Addon, "GetDependencyPolicy", addonConveniences.GetDependencyPolicy)
rawset(Addon, "SetDependencyPolicy", addonConveniences.SetDependencyPolicy)
rawset(Addon, "GetMissingScopePolicy", addonConveniences.GetMissingScopePolicy)
rawset(Addon, "SetMissingScopePolicy", addonConveniences.SetMissingScopePolicy)
rawset(Addon, "SetDefaultModuleState", addonConveniences.SetDefaultModuleState)
rawset(Addon, "GetDefaultModuleState", addonConveniences.GetDefaultModuleState)
rawset(Addon, "SetDefaultModulePrototype", addonConveniences.SetDefaultModulePrototype)
rawset(Addon, "GetDefaultModulePrototype", addonConveniences.GetDefaultModulePrototype)
rawset(Addon, "OnModuleCreated", addonConveniences.OnModuleCreated)
rawset(Addon, "CreateModule", addonCreateModule)
rawset(Addon, "GetModule", addonGetModule)
rawset(Addon, "HasModule", addonHasModule)
rawset(Addon, "GetModules", addonGetModules)
rawset(Addon, "GetActivationOrder", addonGetActivationOrder)
rawset(Addon, "ValidateGraph", addonValidateGraph)
rawset(Addon, "InitializeAll", addonInitializeAll)
rawset(Addon, "EnableAll", addonEnableAll)
rawset(Addon, "DisableAll", addonDisableAll)

rawset(SCOPE_METATABLE, "__index", scopeIndex)

rawset(ModuleKit, "API", API_GENERATION)
rawset(ModuleKit, "REVISION", IMPLEMENTATION_REVISION)
rawset(ModuleKit, "UNBOUNDED", UNBOUNDED)
rawset(ModuleKit, "ForAddon", forAddon)
rawset(ModuleKit, "FindAddon", addonConveniences.FindAddon)
rawset(ModuleKit, "GetAddons", addonConveniences.GetAddons)
rawset(ModuleKit, "SetLimits", setLimits)
rawset(ModuleKit, "GetLimits", getLimits)
rawset(ModuleKit, "HasPart", hasPart)

-- The core functions the parts call, read by them at call time, so a part
-- loaded before this revision serves through this revision's code.
local helpers = state.helpers
helpers.isSecret = isSecret
helpers.describeKey = describeKey
helpers.validateNonEmptyString = validateNonEmptyString
helpers.ensureNotShutdown = ensureNotShutdown
helpers.ensureDefinitionMutable = ensureDefinitionMutable
helpers.findOptionalPackage = findOptionalPackage
helpers.partMissingMessage = partMissingMessage
helpers.refreshLayers = addonConveniences.refreshLayers
helpers.invokeDispatch = invokeDispatch
helpers.enabledHardDependents = enabledHardDependents
helpers.markBlocked = markBlocked
helpers.disableOne = disableOne
helpers.captureFirstError = captureFirstError
helpers.raiseCaptured = raiseCaptured

-- Lifecycle subscriptions installed by revision 1 closed over that revision's
-- local implementation functions. Revision 2 moves them behind shared-state
-- dispatch so existing addon containers observe future compatible bug fixes
-- without replacing container identity or requiring addon reloads.
rawset(dispatch, "initializeAll", initializeAllInternal)
rawset(dispatch, "enableAll", function(addon)
  return enableAllInternal(addon, true)
end)
rawset(dispatch, "shutdown", function(addon)
  return disableAllInternal(addon, true)
end)
rawset(dispatch, "halted", haltAllInternal)

if state.runtimeRevision ~= IMPLEMENTATION_REVISION then
  -- Containers revision 23 made are complete and their LifecycleKit
  -- subscriptions already reach the shared dispatch, so they are kept as
  -- they are. Only a cached graph is rebuilt by the revision that walks it.
  for _, addon in next, state.addons do
    addon._graphOrder = nil
    addon._graphDependents = nil
  end
  state.runtimeRevision = IMPLEMENTATION_REVISION
end

if not validatePublicSurface(ModuleKit) or not validateCurrentState(ModuleKit) then
  error("MoltenCodes ModuleKit package state is corrupted or incomplete", 2)
end

return ModuleKit
