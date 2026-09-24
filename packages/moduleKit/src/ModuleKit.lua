-- MoltenCodes ModuleKit
--
-- Addon-scoped module lifecycle, dependency graphs, and dependency injection.
-- ModuleKit is intentionally independent from WoW Frame APIs; lifecycle timing
-- is supplied by LifecycleKit and package identity by Registry.
--
-- Contents
--
--   Dependencies ......... Registry and LifecycleKit handshake.
--   Bootstrap ............ Embedded revision reconciliation and shared state.
--   Validation helpers ... Argument checks and definition-mutability rules.
--   Graph ................ Edge construction, cycle reporting, topological order.
--   Optional packages .... Silent `Registry:Find` lookup shared by the sections
--                          that use a Kit the addon may not embed.
--   Dependency injection . Provider registration, `implements` contracts,
--                          scoped resolution, cycles.
--   Module scopes ........ Per-module addon-message, command, event, hook,
--                          job, message and timer scopes released on disable,
--                          resolved through `Registry:Find`.
--   Lifecycle operations . Single-module transitions, dependency policies,
--                          intent versus fact, recovery of blocked dependents,
--                          halted addons, whole-container passes and deferred
--                          catch-up.
--   Module public API ..... Methods installed on the shared Module prototype.
--   Addon public API ...... Methods installed on the shared Addon prototype.
--   Addon creation ........ Container identity and LifecycleKit subscriptions,
--                           including the halted notices.
--   Package-wide limits ... `SetLimits` / `GetLimits` and the coupling to
--                           LifecycleKit's dependency limit.
--   Commit ................ Publishing the public surface and runtime dispatch.
--
-- `docs/INTERNALS.md` explains the graph algorithm, the failure model, the
-- lifecycle replay hazard that the dispatched-phase set guards against, module
-- scopes, the intent-versus-fact enable state, and halted addons.

local PACKAGE_NAME = "moduleKit"
local API_GENERATION = 1
local IMPLEMENTATION_REVISION = 16
local REQUIRED_REGISTRY_API = 2
local REQUIRED_LIFECYCLE_API = 1
local STATE_SCHEMA = 1

-- The default of `maxRequiredAddons`, the most addons one module may name in
-- `requiresAddons`. It matches the number of dependencies LifecycleKit lets
-- one addon declare with `DependsOn`, which bounds the addon as a whole
-- whatever this limit says. `ModuleKit:SetLimits` opens it.
local DEFAULT_MAX_REQUIRED_ADDONS = 16

-- The package-wide limits `SetLimits` accepts, in the order `GetLimits`
-- reports them.
local LIMIT_NAMES = { "maxRequiredAddons" }
local KNOWN_LIMITS = { maxRequiredAddons = true }

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

---One addon's module container, bound to that addon's LifecycleKit instance.
---@class ModuleKit.Addon
---@field GetAddonName fun(self: ModuleKit.Addon): string
---@field GetDependencyPolicy fun(self: ModuleKit.Addon): ModuleKit.DependencyPolicy
---@field SetDependencyPolicy fun(self: ModuleKit.Addon, policy: ModuleKit.DependencyPolicy): ModuleKit.DependencyPolicy
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
---@field ProvideSingleton fun(self: ModuleKit.Addon, name: string, factory: fun(addon: ModuleKit.Addon): any, options: ModuleKit.ProvideOptions?): ModuleKit.Addon
---@field ProvideModule fun(self: ModuleKit.Addon, name: string, factory: fun(addon: ModuleKit.Addon, module: ModuleKit.Module): any, options: ModuleKit.ProvideOptions?): ModuleKit.Addon
---@field ProvideTransient fun(self: ModuleKit.Addon, name: string, factory: fun(addon: ModuleKit.Addon, module: ModuleKit.Module|nil): any, options: ModuleKit.ProvideOptions?): ModuleKit.Addon
---@field Resolve fun(self: ModuleKit.Addon, name: string, requestingModule: ModuleKit.Module|nil): any

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
---@field SetLimits fun(self: ModuleKit, limits: ModuleKit.Limits|table)
---@field GetLimits fun(self: ModuleKit): ModuleKit.Limits

-- Dependencies --------------------------------------------------------------

-- The shared MoltenCodes namespace is the one documented global handoff point between independently embedded copies.
-- selene: allow(global_usage)
local namespace = rawget(_G, "MoltenCodes")
local generations = type(namespace) == "table" and rawget(namespace, "Registries") or nil

-- Ask for Registry by generation and fall back to the alias. A future Registry
-- API generation takes over `MoltenCodes.Registry`, so reading the alias first
-- would hand this file a facade whose contract it was not written against.
local Registry = type(generations) == "table" and rawget(generations, REQUIRED_REGISTRY_API) or nil
if Registry == nil and type(namespace) == "table" then
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
if LifecycleKit == nil then
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

---Whether `value` is an exact integer of one or more. `nan` and both
---infinities are rejected before the integer test can accept them.
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
    for index = 1, #LIMIT_NAMES do
        local value = rawget(limits, LIMIT_NAMES[index])
        if value ~= unbounded and not isPositiveInteger(value) then
            return false
        end
    end
    return true
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

if ModuleKit == nil then
    -- Equal or newer compatible revision already owns the shared package table.
    return selected
end

-- Registry keeps the identity of the two prototype tables below stable across
-- compatible embedded revisions, so containers and modules created by an older
-- copy observe newer methods.
local Addon = rawget(ModuleKit, "Addon")
local Module = rawget(ModuleKit, "Module")

local state = rawget(ModuleKit, "_state")

if previousRevision == nil then
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
    }

    rawset(ModuleKit, "Addon", Addon)
    rawset(ModuleKit, "Module", Module)
    rawset(ModuleKit, "_state", state)
else
    if type(Addon) ~= "table" or type(Module) ~= "table" or not validateStateBase(state) then
        error("MoltenCodes ModuleKit package state is corrupted or incomplete", 2)
    end

    if type(rawget(state, "dispatch")) ~= "table" then
        rawset(state, "dispatch", {})
    end
    if type(rawget(state, "runtimeRevision")) ~= "number" then
        rawset(state, "runtimeRevision", previousRevision)
    end
    if type(rawget(state, "scopeMetatable")) ~= "table" then
        rawset(state, "scopeMetatable", {})
    end
    -- Revisions 1 to 13 kept no sentinel and no limits: the fields are
    -- additive, so the schema stays 1 and they are created here with the
    -- defaults those revisions enforced as constants.
    if type(rawget(state, "unbounded")) ~= "table" then
        rawset(state, "unbounded", {})
    end
    if type(rawget(state, "limits")) ~= "table" then
        rawset(state, "limits", { maxRequiredAddons = DEFAULT_MAX_REQUIRED_ADDONS })
    end
    if not validateLimitsState(rawget(state, "limits"), rawget(state, "unbounded")) then
        error("MoltenCodes ModuleKit package state is corrupted or incomplete", 2)
    end
end

-- The sentinel and the limits table are shared by every revision; this copy
-- reads and writes them in place.
local UNBOUNDED = rawget(state, "unbounded")
local sharedLimits = rawget(state, "limits")

-- Every module scope shares this metatable. It lives in shared state, and each
-- revision installs its own `__index` on it, so scopes created by an older copy
-- observe the newer lookup after an upgrade.
local SCOPE_METATABLE = rawget(state, "scopeMetatable")

local ADDON_METATABLE = { __index = Addon }
local MODULE_METATABLE = { __index = Module }

-- The `_requiredAddons` of every module that declares none. It is never
-- written: declaring a first required addon gives the module its own array.
local NO_REQUIRED_ADDONS = {}

-- Validation helpers --------------------------------------------------------

-- Error levels. Every helper that raises takes the level it raises at,
-- counted from its own frame (`2` is its caller), and names the public method
-- in full, `ModuleKit.Module:Enable` or `ModuleKit.Addon:CreateModule`. Lua 5.1
-- counts a frame replaced by a tail call as one level, so the count is the same
-- whether a public method tail-calls its helper or not.

---@param value any
---@param label string argument description, used in the argument error
---@param level integer stack level the failure is reported at, counted from this function
local function validateNonEmptyString(value, label, level)
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
    if rawget(module, "_state") ~= "created" then
        error(
            "ModuleKit.Module:"
                .. methodName
                .. ' cannot change module "'
                .. rawget(module, "_name")
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
    if rawget(addon, "_shutdown") == true then
        error(methodLabel .. " cannot run after addon shutdown", level)
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
    ensureNotShutdown(rawget(module, "_addon"), "ModuleKit.Module:" .. methodName, level + 1)
    validateNonEmptyString(
        targetName,
        "ModuleKit.Module:" .. methodName .. " moduleName",
        level + 1
    )

    if targetName == rawget(module, "_name") then
        error('ModuleKit module "' .. targetName .. '" cannot depend/order against itself', level)
    end

    if field == "_before" then
        local addon = rawget(module, "_addon")
        local target = rawget(rawget(addon, "_modules"), targetName)
        if target ~= nil and rawget(target, "_state") ~= "created" then
            error(
                'ModuleKit module "'
                    .. rawget(module, "_name")
                    .. '" cannot be ordered before already-initialized module "'
                    .. targetName
                    .. '"',
                level
            )
        end
    end

    rawset(rawget(module, field), targetName, true)
    return module
end

---Refuse a late module that would have to run before an initialized one.
---@param addon ModuleKit.Addon
---@param newModule ModuleKit.Module
local function validateLateModuleOrdering(addon, newModule)
    local order = rawget(addon, "_moduleOrder")
    local newName = rawget(newModule, "_name")
    local newBefore = rawget(newModule, "_before")

    for index = 1, #order do
        local existingModule = order[index]
        if rawget(existingModule, "_state") ~= "created" then
            local existingName = rawget(existingModule, "_name")
            local existingOptional = rawget(existingModule, "_optionalDependencies")
            local existingAfter = rawget(existingModule, "_after")
            local existingHard = rawget(existingModule, "_hardDependencies")

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
    return rawget(module, "_order")
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

---Resolve a name set to the modules that exist, in deterministic order.
---@param addon ModuleKit.Addon
---@param names table<string, boolean>
---@return ModuleKit.Module[]
local function orderedTargets(addon, names)
    local modules = rawget(addon, "_modules")
    local result = {}
    for name in pairs(names) do
        local target = rawget(modules, name)
        if target ~= nil then
            result[#result + 1] = target
        end
    end
    table.sort(result, function(left, right)
        local leftOrder = moduleSortKey(left)
        local rightOrder = moduleSortKey(right)
        if leftOrder == rightOrder then
            return rawget(left, "_name") < rawget(right, "_name")
        end
        return leftOrder < rightOrder
    end)
    return result
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
            names[#names + 1] = rawget(module, "_name")
            return names
        end

        visiting[module] = true
        stack[#stack + 1] = module

        local targets = {}
        for target in pairs(adjacency[module]) do
            targets[#targets + 1] = target
        end
        table.sort(targets, function(left, right)
            return moduleSortKey(left) < moduleSortKey(right)
        end)

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
    local ready = {}
    for index = 1, #order do
        local module = order[index]
        if indegree[module] == 0 then
            ready[#ready + 1] = module
        end
    end

    table.sort(ready, function(left, right)
        return moduleSortKey(left) > moduleSortKey(right)
    end)

    local result = {}
    while #ready > 0 do
        local last = #ready
        local module = ready[last]
        ready[last] = nil
        result[#result + 1] = module

        local targets = {}
        for target in pairs(adjacency[module]) do
            targets[#targets + 1] = target
        end
        table.sort(targets, function(left, right)
            return moduleSortKey(left) < moduleSortKey(right)
        end)

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

---Build and topologically sort the container's complete module graph.
---
---`level` is the error level of a missing dependency or a cycle, counted from
---this function: `3` names the caller of a public method that calls it
---directly, and the whole-container passes pass one more for their own frame.
---@param addon ModuleKit.Addon
---@param level integer|nil error level; `3` when omitted
---@return ModuleKit.Module[] order activation order for the whole container
local function buildGraph(addon, level)
    level = level or 3
    local order = rawget(addon, "_moduleOrder")
    local modules = rawget(addon, "_modules")
    local adjacency = {}
    local indegree = {}

    for index = 1, #order do
        local module = order[index]
        adjacency[module] = {}
        indegree[module] = 0
    end

    for index = 1, #order do
        local module = order[index]
        local moduleName = rawget(module, "_name")
        local hard = rawget(module, "_hardDependencies")
        local hardNames = sortedNameKeys(hard)

        for hardIndex = 1, #hardNames do
            local dependencyName = hardNames[hardIndex]
            local dependency = rawget(modules, dependencyName)
            if dependency == nil then
                error(
                    'ModuleKit module "'
                        .. moduleName
                        .. '" requires missing dependency "'
                        .. dependencyName
                        .. '"',
                    level
                )
            end
            addEdge(adjacency, indegree, dependency, module)
        end

        local optionalTargets = orderedTargets(addon, rawget(module, "_optionalDependencies"))
        for targetIndex = 1, #optionalTargets do
            addEdge(adjacency, indegree, optionalTargets[targetIndex], module)
        end

        local afterTargets = orderedTargets(addon, rawget(module, "_after"))
        for targetIndex = 1, #afterTargets do
            addEdge(adjacency, indegree, afterTargets[targetIndex], module)
        end

        local beforeTargets = orderedTargets(addon, rawget(module, "_before"))
        for targetIndex = 1, #beforeTargets do
            addEdge(adjacency, indegree, module, beforeTargets[targetIndex])
        end
    end

    local result = topologicalSort(order, adjacency, indegree)
    if result == nil then
        local cycle = findCycle(order, adjacency)
        local description = cycle and table.concat(cycle, " -> ") or "unknown cycle"
        error("ModuleKit dependency cycle detected: " .. description, level)
    end

    return result
end

---Return the modules `module` requires, in deterministic order.
---@param module ModuleKit.Module
---@param level integer|nil error level of a missing dependency, counted from this function; `3` when omitted
---@return ModuleKit.Module[]
local function hardDependencies(module, level)
    local addon = rawget(module, "_addon")
    local modules = rawget(addon, "_modules")
    local moduleName = rawget(module, "_name")
    local result = {}
    local names = sortedNameKeys(rawget(module, "_hardDependencies"))
    for index = 1, #names do
        local dependencyName = names[index]
        local dependency = rawget(modules, dependencyName)
        if dependency == nil then
            error(
                'ModuleKit module "'
                    .. moduleName
                    .. '" requires missing dependency "'
                    .. dependencyName
                    .. '"',
                level or 3
            )
        end
        result[#result + 1] = dependency
    end
    table.sort(result, function(left, right)
        return moduleSortKey(left) < moduleSortKey(right)
    end)
    return result
end

---Return the enabled modules that require `module`, newest first.
---@param module ModuleKit.Module
---@return ModuleKit.Module[]
local function enabledHardDependents(module)
    local addon = rawget(module, "_addon")
    local order = rawget(addon, "_moduleOrder")
    local moduleName = rawget(module, "_name")
    local result = {}

    for index = 1, #order do
        local candidate = order[index]
        if
            candidate ~= module
            and rawget(candidate, "_state") == "enabled"
            and rawget(rawget(candidate, "_hardDependencies"), moduleName) == true
        then
            result[#result + 1] = candidate
        end
    end

    table.sort(result, function(left, right)
        return moduleSortKey(left) > moduleSortKey(right)
    end)
    return result
end

---Order the currently enabled modules by their hard dependencies alone.
---@param addon ModuleKit.Addon
---@return ModuleKit.Module[] order
local function buildEnabledHardOrder(addon)
    local allModules = rawget(addon, "_moduleOrder")
    local modulesByName = rawget(addon, "_modules")
    local order = {}
    local enabled = {}

    for index = 1, #allModules do
        local module = allModules[index]
        if rawget(module, "_state") == "enabled" then
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
        for dependencyName in pairs(rawget(module, "_hardDependencies")) do
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

-- Dependency injection ------------------------------------------------------

---Whether a resolution-stack entry names the resolution being attempted.
---@param record any
---@param name string
---@param kind "value"|"singleton"|"module"|"transient"
---@param requestingModule ModuleKit.Module|nil
---@return boolean
local function resolutionRecordMatches(record, name, kind, requestingModule)
    if type(record) ~= "table" or rawget(record, "name") ~= name then
        return false
    end
    if kind == "module" then
        return rawget(record, "requestingModule") == requestingModule
    end
    return true
end

---Render one resolution for the cycle diagnostic.
---@param name string
---@param requestingModule ModuleKit.Module|nil
---@return string
local function resolutionLabel(name, requestingModule)
    if requestingModule ~= nil then
        return name .. "[" .. tostring(rawget(requestingModule, "_name")) .. "]"
    end
    return name
end

-- Implements contracts ------------------------------------------------------
--
-- A provider or a module definition may state what its value must carry, and
-- ModuleKit checks it exactly once per value: at registration for a value
-- provider and a module, and when the factory's result arrives for a lazy
-- provider, before that result is cached. The contract is compiled at
-- registration into a record kept on the provider, so a resolution pays one
-- lookup per declared name and allocates nothing when the value conforms.
-- Messages never format the checked value: they name the provider or module,
-- the member, and a type name.

---The package ID and API generation of SchemaKit, the one optional package the
---schema form of `implements` needs. It is found at registration, never at
---load, because nothing guarantees it has loaded before this file.
local SCHEMA_KIT_PACKAGE = "schemaKit"
local SCHEMA_KIT_API = 1

---The names `getmetatable` returns for SchemaKit nodes and sealed schemas,
---which set `__metatable` to them. They tell a schema from a method list even
---when SchemaKit is not loaded, which is what the refusal for that case needs.
local SCHEMA_METATABLE_NAMES = { ["SchemaKit.Schema"] = true, ["SchemaKit.Node"] = true }

---Whether `value` presents itself as a SchemaKit node or sealed schema.
---@param value any
---@return boolean
local function isSchemaLike(value)
    return type(value) == "table" and SCHEMA_METATABLE_NAMES[getmetatable(value)] == true
end

---Compile the list form of `implements`: a dense array of distinct non-empty
---strings, copied so a later edit of the caller's table changes nothing.
---@param list table
---@param label string argument description, used in the argument errors
---@param level integer stack level the failure is reported at
---@return string[] names
local function compileImplementsNames(list, label, level)
    local count = 0
    for key in next, list do
        if type(key) ~= "number" or key < 1 or key % 1 ~= 0 then
            error(label .. " must be a dense array of method names or a SchemaKit schema", level)
        end
        count = count + 1
    end
    if count == 0 then
        error(label .. " must name at least one method", level)
    end

    -- `count` positive-integer keys form a dense array only when every index
    -- from 1 to `count` is present; a hole anywhere is a density failure, not a
    -- bad entry.
    local names = {}
    local seen = {}
    for index = 1, count do
        local name = rawget(list, index)
        if name == nil then
            error(label .. " must be a dense array of method names or a SchemaKit schema", level)
        end
        if type(name) ~= "string" or name == "" then
            error(label .. " entries must be non-empty strings", level)
        end
        if seen[name] == true then
            error(label .. ' names "' .. name .. '" twice', level)
        end
        seen[name] = true
        names[index] = name
    end
    return names
end

---Compile the schema form of `implements`: seal the node or schema through the
---loaded SchemaKit, so the contract owns its failure record and cannot race
---the consumer's own checks on the same schema.
---@param candidate table a value `isSchemaLike` accepted
---@param label string argument description, used in the argument errors
---@param level integer stack level the failure is reported at
---@return table schema a sealed SchemaKit schema
local function compileImplementsSchema(candidate, label, level)
    local SchemaKit = findOptionalPackage(SCHEMA_KIT_PACKAGE, SCHEMA_KIT_API)
    if SchemaKit == nil then
        error(
            label
                .. " is a SchemaKit schema, but SchemaKit API "
                .. SCHEMA_KIT_API
                .. " is not loaded",
            level
        )
    end
    local seal = rawget(SchemaKit, "Seal")
    if type(seal) ~= "function" then
        error(label .. " must be a SchemaKit node or sealed schema", level)
    end
    local ok, schema = pcall(seal, SchemaKit, candidate)
    if not ok or type(schema) ~= "table" then
        error(label .. " must be a SchemaKit node or sealed schema", level)
    end
    return schema
end

---Compile an `implements` declaration into a contract record, or `nil` when
---none was declared.
---@param candidate any the caller's `implements` value
---@param label string argument description, used in the argument errors
---@param level integer stack level the failure is reported at
---@return table|nil contract `{ names = string[] }` or `{ schema = table }`
local function compileImplements(candidate, label, level)
    if candidate == nil then
        return nil
    end
    if type(candidate) ~= "table" then
        error(label .. " must be a dense array of method names or a SchemaKit schema", level)
    end
    if isSchemaLike(candidate) then
        return { schema = compileImplementsSchema(candidate, label, level + 1) }
    end
    return { names = compileImplementsNames(candidate, label, level + 1) }
end

---Render a SchemaKit failure record for a message. SchemaKit never puts the
---checked value in the record, so the rendering is secret-safe.
---@param failure table `{ path, rule, expected, found }`
---@return string
local function describeSchemaFailure(failure)
    local path = rawget(failure, "path")
    local where = ""
    if type(path) == "string" and path ~= "" then
        where = "at " .. path .. ", "
    end
    return where
        .. "expected "
        .. tostring(rawget(failure, "expected"))
        .. ", found "
        .. tostring(rawget(failure, "found"))
end

---Check `value` against a compiled contract, raising at `level` on the first
---member or schema rule it fails. Allocates nothing when the value conforms.
---@param contract table|nil the record `compileImplements` returned
---@param value any the provided value or the module table
---@param subject string what is checked, for the message: `provider "Database"` or `module "Inventory"`
---@param level integer stack level the failure is reported at
local function checkImplements(contract, value, subject, level)
    if contract == nil then
        return
    end

    local schema = rawget(contract, "schema")
    if schema ~= nil then
        local ok, failure = schema:Check(value)
        if not ok then
            error(
                "ModuleKit "
                    .. subject
                    .. " does not match its implements schema: "
                    .. describeSchemaFailure(failure),
                level
            )
        end
        return
    end

    local names = rawget(contract, "names")
    if type(value) ~= "table" then
        error(
            "ModuleKit "
                .. subject
                .. ' must implement "'
                .. names[1]
                .. '": the value is a '
                .. type(value)
                .. ", not a table",
            level
        )
    end
    for index = 1, #names do
        local name = names[index]
        local member = value[name]
        if member == nil then
            error(
                "ModuleKit " .. subject .. ' must implement "' .. name .. '": no such member',
                level
            )
        end
        if type(member) ~= "function" then
            error(
                "ModuleKit "
                    .. subject
                    .. ' must implement "'
                    .. name
                    .. '": member "'
                    .. name
                    .. '" is a '
                    .. type(member)
                    .. ", not a function",
                level
            )
        end
    end
end

---Read the options table of a `Provide*` method and compile its `implements`.
---@param options any the caller's options, `nil` when omitted
---@param methodName string public method name, used in the argument errors
---@param level integer stack level the failure is reported at
---@return table|nil contract
local function readProvideOptions(options, methodName, level)
    if options == nil then
        return nil
    end
    local label = "ModuleKit.Addon:" .. methodName .. " options"
    if type(options) ~= "table" then
        error(label .. " must be a table when provided", level)
    end
    -- Every unknown field is collected and the first in sorted order named, so
    -- the message does not depend on `next` order when there are several.
    local unknown
    for key in next, options do
        if key ~= "implements" then
            unknown = unknown or {}
            unknown[#unknown + 1] = tostring(key)
        end
    end
    if unknown ~= nil then
        table.sort(unknown)
        error(label .. ' contains unknown field "' .. unknown[1] .. '"', level)
    end
    return compileImplements(rawget(options, "implements"), label .. ".implements", level + 1)
end

-- Providers -----------------------------------------------------------------

---Whether `name` is already taken by a module or another provider.
---@param addon ModuleKit.Addon
---@param name string
---@return boolean
local function providerConflict(addon, name)
    return rawget(rawget(addon, "_modules"), name) ~= nil
        or rawget(rawget(addon, "_providers"), name) ~= nil
end

---Publish one provider record under `name`.
---@param addon ModuleKit.Addon
---@param name string
---@param provider table provider record; its `kind` selects the resolution rule
---@param methodName string public method name, used in the argument errors
---@return ModuleKit.Addon addon
local function registerProvider(addon, name, provider, methodName)
    validateNonEmptyString(name, "ModuleKit.Addon:" .. methodName .. " providerName", 4)
    if providerConflict(addon, name) then
        error("ModuleKit.Addon:" .. methodName .. ' name "' .. name .. '" is already in use', 3)
    end
    rawset(rawget(addon, "_providers"), name, provider)
    return addon
end

---Resolve one injectable, falling back to a module of the same name.
---
---Resolution is re-entrant: the container keeps a stack so a provider factory
---that resolves its way back to itself is reported as a cycle rather than
---recursing until the stack overflows.
---@param addon ModuleKit.Addon
---@param name string
---@param requestingModule ModuleKit.Module|nil scope context for module providers
---@return any value
local function resolveProvider(addon, name, requestingModule)
    validateNonEmptyString(name, "ModuleKit.Addon:Resolve providerName", 4)

    local providers = rawget(addon, "_providers")
    local provider = rawget(providers, name)
    if provider == nil then
        local module = rawget(rawget(addon, "_modules"), name)
        if module ~= nil then
            return module
        end
        error('ModuleKit injectable "' .. name .. '" does not exist', 3)
    end

    local kind = rawget(provider, "kind")
    if kind == "value" then
        return rawget(provider, "value")
    end

    if kind == "module" and requestingModule == nil then
        error('ModuleKit module-scoped provider "' .. name .. '" requires a requesting module', 3)
    end

    if kind == "singleton" and rawget(provider, "resolved") == true then
        return rawget(provider, "value")
    end

    if kind == "module" then
        local cache = rawget(provider, "cache")
        local record = rawget(cache, requestingModule)
        if record ~= nil then
            return rawget(record, "value")
        end
    end

    local stack = rawget(addon, "_resolutionStack")
    for index = 1, #stack do
        if resolutionRecordMatches(stack[index], name, kind, requestingModule) then
            local cycle = {}
            for cycleIndex = index, #stack do
                local record = stack[cycleIndex]
                cycle[#cycle + 1] =
                    resolutionLabel(rawget(record, "name"), rawget(record, "requestingModule"))
            end
            cycle[#cycle + 1] = resolutionLabel(name, kind == "module" and requestingModule or nil)
            error("ModuleKit provider resolution cycle: " .. table.concat(cycle, " -> "), 3)
        end
    end

    stack[#stack + 1] = {
        name = name,
        requestingModule = kind == "module" and requestingModule or nil,
    }
    local factory = rawget(provider, "factory")
    local ok, value
    if kind == "singleton" then
        ok, value = pcall(factory, addon)
    else
        ok, value = pcall(factory, addon, requestingModule)
    end
    stack[#stack] = nil

    if not ok then
        error(value, 0)
    end
    if value == nil then
        error('ModuleKit provider "' .. name .. '" factory returned nil', 3)
    end
    -- Checked before caching, so a refused value is produced again on the next
    -- resolution rather than served from the cache. Level 4 counts this frame.
    checkImplements(
        rawget(provider, "implements"),
        value,
        'provider "' .. resolutionLabel(name, kind == "module" and requestingModule or nil) .. '"',
        4
    )

    if kind == "singleton" then
        rawset(provider, "value", value)
        rawset(provider, "resolved", true)
    elseif kind == "module" then
        rawset(rawget(provider, "cache"), requestingModule, { value = value })
    end

    return value
end

---Resolve every declared injection alias of `module`, in alias order.
---@param module ModuleKit.Module
---@return table<string, any> injections
local function resolveInjections(module)
    local addon = rawget(module, "_addon")
    local specification = rawget(module, "_injectSpec")
    local resolved = {}
    local aliases = {}

    for alias in pairs(specification) do
        aliases[#aliases + 1] = alias
    end
    table.sort(aliases)

    for index = 1, #aliases do
        local alias = aliases[index]
        resolved[alias] = resolveProvider(addon, rawget(specification, alias), module)
    end

    rawset(module, "_injections", resolved)
    return resolved
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
---A SignalKit revision older than the one that introduced buses has neither
---`Bus` nor `ForAddon` and yields `nil`. So does a bus that cannot be had:
---`ForAddon` answers `nil, "full"` when the session already holds its bound
---of buses, and a bus that was closed refuses new scopes. The field then reads
---as `nil`, exactly as it does when the Kit is absent.
---@param kit table the SignalKit facade
---@param module ModuleKit.Module
---@return table|nil scope
local function createMessagesScope(kit, module)
    local forAddon = rawget(kit, "ForAddon")
    if type(rawget(kit, "Bus")) ~= "function" or type(forAddon) ~= "function" then
        return nil
    end

    local addonName = rawget(rawget(module, "_addon"), "_name")
    local bus = forAddon(kit, addonName)
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

---Create the scope field `key` on first read.
---
---The field is written onto the scope with `rawset`, so every later read is a
---plain table hit and this function runs once per field per enable.
---@param scope ModuleKit.Scope
---@param key any
---@return table|nil
local function scopeIndex(scope, key)
    local packageName = SCOPE_PACKAGES[key]
    if packageName == nil then
        return nil
    end

    local module = rawget(scope, "_module")
    if rawget(module, "_scopeOpen") ~= true then
        error(
            'ModuleKit module "'
                .. tostring(rawget(module, "_name"))
                .. '" scope.'
                .. key
                .. " is available only while the module is enabling or enabled",
            2
        )
    end

    local kit = findOptionalPackage(packageName, SCOPE_PACKAGE_API)
    if kit == nil then
        return nil
    end

    local created
    if key == "Messages" then
        created = createMessagesScope(kit, module)
    else
        created = createKitScope(kit)
    end
    if created == nil then
        -- A Kit revision without owner scopes, or a bus that cannot be had.
        -- Nothing is stored, so a later read tries again.
        return nil
    end

    rawset(scope, key, created)
    return created
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
    rawset(module, "_scopeOpen", false)

    local scope = rawget(module, "_scope")
    if type(scope) ~= "table" then
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
                if not ok and firstError == nil then
                    firstError = { value = value }
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
        error(rawget(record, "value"), 0)
    end
end

---Record why the last operation on `module` did not complete.
---@param module ModuleKit.Module
---@param value any error object, which may legitimately be `nil`
---@param blockedBy string|nil dependency or dependent name that blocked it
---@param hasError boolean whether `value` is a real error object
local function recordFailure(module, value, blockedBy, hasError)
    rawset(module, "_lastError", value)
    rawset(module, "_hasLastError", hasError == true)
    rawset(module, "_blockedBy", blockedBy)
end

---Clear the failure record after a successful transition.
---@param module ModuleKit.Module
local function clearFailure(module)
    rawset(module, "_lastError", nil)
    rawset(module, "_hasLastError", false)
    rawset(module, "_blockedBy", nil)
end

---Call one consumer lifecycle hook, if the module defines it.
---@param module ModuleKit.Module
---@param name "OnInitialize"|"OnEnable"|"OnDisable"
---@return boolean ok
---@return any errorValue
local function invokeHook(module, name)
    local callback = rawget(module, name)
    if callback == nil then
        return true, nil
    end
    if type(callback) ~= "function" then
        return false,
            'ModuleKit module "' .. rawget(module, "_name") .. '" ' .. name .. " must be a function"
    end

    return pcall(callback, module, rawget(module, "_injections"))
end

---Initialize exactly `module`, ignoring dependency policy.
---@param module ModuleKit.Module
---@return ModuleKit.Module module
local function initializeOne(module)
    local current = rawget(module, "_state")
    if current ~= "created" then
        return module
    end

    local ok, injectionsOrError = pcall(resolveInjections, module)
    if not ok then
        recordFailure(module, injectionsOrError, nil, true)
        error(injectionsOrError, 0)
    end

    local hookOk, hookError = invokeHook(module, "OnInitialize")
    if not hookOk then
        rawset(module, "_injections", nil)
        recordFailure(module, hookError, nil, true)
        error(hookError, 0)
    end

    rawset(module, "_state", "initialized")
    clearFailure(module)
    return module
end

-- Halted addons -------------------------------------------------------------
--
-- LifecycleKit lets an addon declare itself non-functional for the rest of the
-- session (`Halt`), and tells the addons that declared it with `DependsOn`.
-- ModuleKit maps both onto the enable state: the module keeps its intent, is
-- taken down, and records what blocks it. Halted is terminal, so nothing ever
-- recovers such a module; every enable path refuses it instead.

---Whether the addon that owns `addon` has halted.
---
---A LifecycleKit revision older than the halted state has no `IsHalted`; its
---addons never halt.
---@param addon ModuleKit.Addon
---@return boolean
local function isContainerHalted(addon)
    local lifecycle = rawget(addon, "_lifecycle")
    local isHalted = type(lifecycle) == "table" and lifecycle.IsHalted or nil
    return type(isHalted) == "function" and isHalted(lifecycle) == true
end

---Whether the addon named `addonName` has halted.
---@param addonName string
---@return boolean
local function isOtherAddonHalted(addonName)
    local instance = LifecycleKit:ForAddon(addonName)
    local getHaltReason = instance.GetHaltReason
    return type(getHaltReason) == "function" and getHaltReason(instance) ~= nil
end

---Whether `module` names `addonName` in `requiresAddons`.
---@param module ModuleKit.Module
---@param addonName string
---@return boolean
local function requiresAddon(module, addonName)
    local required = rawget(module, "_requiredAddons")
    for index = 1, #required do
        if required[index] == addonName then
            return true
        end
    end
    return false
end

---Return what a halt blocks `module` on, if anything.
---@param module ModuleKit.Module
---@return string|nil blocker `"halted"` when its own addon halted, the first halted addon of `requiresAddons`, or `nil`
local function haltBlocker(module)
    if isContainerHalted(rawget(module, "_addon")) then
        return OWN_ADDON_HALTED
    end

    local required = rawget(module, "_requiredAddons")
    for index = 1, #required do
        local addonName = required[index]
        if isOtherAddonHalted(addonName) then
            return addonName
        end
    end
    return nil
end

---Record that an enable of `module` was refused because of a halt.
---@param module ModuleKit.Module
---@param blocker string what `haltBlocker` returned
local function recordHaltRefusal(module, blocker)
    recordFailure(module, nil, blocker, false)
    if rawget(module, "_wantedEnabled") == true then
        rawset(module, "_enableBlockedBy", blocker)
    end
end

---The message a refused targeted enable raises.
---@param module ModuleKit.Module
---@param blocker string what `haltBlocker` returned
---@return string
local function haltRefusalMessage(module, blocker)
    local prefix = 'ModuleKit module "' .. rawget(module, "_name") .. '" cannot be enabled because '
    if blocker == OWN_ADDON_HALTED then
        return prefix
            .. 'its addon "'
            .. rawget(rawget(module, "_addon"), "_name")
            .. '" has halted'
    end
    return prefix .. 'required addon "' .. blocker .. '" has halted'
end

---Disable exactly `module`, ignoring dependency policy.
---@param module ModuleKit.Module
---@return ModuleKit.Module module
local function disableOne(module)
    if rawget(module, "_state") ~= "enabled" then
        return module
    end

    local ok, value = invokeHook(module, "OnDisable")
    if not ok then
        recordFailure(module, value, nil, true)
        error(value, 0)
    end

    rawset(module, "_state", "disabled")
    clearFailure(module)

    -- The module is disabled either way; a scope that failed to close is
    -- reported after the transition rather than leaving the module enabled.
    raiseCaptured(closeModuleScope(module))
    return module
end

---Enable exactly `module`, initializing it first when it is still `created`.
---@param module ModuleKit.Module
---@param level integer error level of an unexpected-state refusal, counted from this function
---@return ModuleKit.Module module
local function enableOne(module, level)
    local current = rawget(module, "_state")
    if current == "enabled" then
        return module
    end
    if current == "created" then
        initializeOne(module)
        current = rawget(module, "_state")
    end
    if current ~= "initialized" and current ~= "disabled" then
        error(
            'ModuleKit module "'
                .. rawget(module, "_name")
                .. '" cannot be enabled from state "'
                .. tostring(current)
                .. '"',
            level
        )
    end

    -- The scope is usable from `OnEnable` on, so a hook can register the
    -- work it owns. A failed `OnEnable` leaves the module where it was, so
    -- whatever it registered before failing is released with it.
    rawset(module, "_scopeOpen", true)
    local ok, value = invokeHook(module, "OnEnable")
    if not ok then
        closeModuleScope(module)
        recordFailure(module, value, nil, true)
        error(value, 0)
    end

    rawset(module, "_state", "enabled")
    rawset(module, "_wantedEnabled", true)
    rawset(module, "_enableBlockedBy", nil)
    clearFailure(module)

    -- `OnEnable` may itself halt the addon or a required addon, typically on
    -- finding its saved variables unusable. The halt pass skipped this module
    -- because it was not enabled yet, so it is taken down here, as that pass
    -- would have: disabled, still wanted, and blocked by the halt.
    local blocker = haltBlocker(module)
    if blocker == OWN_ADDON_HALTED then
        -- Terminal cleanup, like the halt pass: the scope is released even
        -- when `OnDisable` fails.
        rawset(module, "_enableBlockedBy", blocker)
        local disabled, failure = pcall(disableOne, module)
        if not disabled then
            closeModuleScope(module)
            error(failure, 0)
        end
    elseif blocker ~= nil then
        rawset(module, "_enableBlockedBy", blocker)
        disableOne(module)
    end
    return module
end

---Record that `module` is meant to stay disabled, which also ends any wait
---for a dependency to recover.
---@param module ModuleKit.Module
local function markWantedDisabled(module)
    rawset(module, "_wantedEnabled", false)
    rawset(module, "_enableBlockedBy", nil)
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
    local addon = rawget(module, "_addon")
    ensureNotShutdown(addon, "ModuleKit.Module:Initialize", 4 + depth)

    if rawget(module, "_state") ~= "created" then
        return module
    end

    local dependencies = hardDependencies(module, 4 + depth)
    local policy = rawget(addon, "_dependencyPolicy")

    if policy == "automatic" then
        visiting = visiting or {}
        if visiting[module] then
            error(
                'ModuleKit dependency cycle detected while initializing "'
                    .. rawget(module, "_name")
                    .. '"',
                3 + depth
            )
        end
        visiting[module] = true
        for index = 1, #dependencies do
            initializeWithPolicy(dependencies[index], visiting, depth + 1)
        end
        visiting[module] = nil
    else
        for index = 1, #dependencies do
            local dependency = dependencies[index]
            if rawget(dependency, "_state") == "created" then
                local name = rawget(dependency, "_name")
                recordFailure(module, nil, name, false)
                error(
                    'ModuleKit strict policy: module "'
                        .. rawget(module, "_name")
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
    local addon = rawget(module, "_addon")
    ensureNotShutdown(addon, "ModuleKit.Module:Enable", 4 + depth)

    -- A halt is terminal, so no dependency policy can satisfy it.
    if rawget(module, "_state") ~= "enabled" then
        local blocker = haltBlocker(module)
        if blocker ~= nil then
            recordHaltRefusal(module, blocker)
            error(haltRefusalMessage(module, blocker), 3 + depth)
        end
    end

    local dependencies = hardDependencies(module, 4 + depth)
    local policy = rawget(addon, "_dependencyPolicy")

    if policy == "automatic" then
        visiting = visiting or {}
        if visiting[module] then
            error(
                'ModuleKit dependency cycle detected while enabling "'
                    .. rawget(module, "_name")
                    .. '"',
                3 + depth
            )
        end
        visiting[module] = true
        for index = 1, #dependencies do
            local dependency = dependencies[index]
            if rawget(dependency, "_state") ~= "enabled" then
                -- Stays recorded if enabling the dependency raises, which is
                -- what lets the dependency's later recovery bring this module
                -- back; see `recoverBlockedDependents`.
                rawset(module, "_enableBlockedBy", rawget(dependency, "_name"))
            end
            enableWithPolicy(dependency, visiting, depth + 1)
            if rawget(dependency, "_state") ~= "enabled" then
                -- A halt inside the dependency's own `OnEnable` took it down
                -- again (see `enableOne`). This module stays off. When the
                -- halt stops this module too (its own addon, or an addon it
                -- requires), the halt is what blocks it, as a direct `Enable`
                -- of it now records; otherwise the dependency does, exactly as
                -- the `ready` pass would leave it.
                local blocker = haltBlocker(module) or rawget(dependency, "_name")
                recordFailure(module, nil, blocker, false)
                rawset(module, "_enableBlockedBy", blocker)
                visiting[module] = nil
                return module
            end
        end
        rawset(module, "_enableBlockedBy", nil)
        visiting[module] = nil
    else
        for index = 1, #dependencies do
            local dependency = dependencies[index]
            if rawget(dependency, "_state") ~= "enabled" then
                local name = rawget(dependency, "_name")
                recordFailure(module, nil, name, false)
                rawset(module, "_enableBlockedBy", name)
                error(
                    'ModuleKit strict policy: module "'
                        .. rawget(module, "_name")
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
    local addon = rawget(module, "_addon")
    local dependents = enabledHardDependents(module)
    local policy = rawget(addon, "_dependencyPolicy")

    if policy == "strict" and #dependents > 0 then
        error(
            'ModuleKit strict policy: cannot disable module "'
                .. rawget(module, "_name")
                .. '" while dependent "'
                .. rawget(dependents[1], "_name")
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
            rawset(dependent, "_enableBlockedBy", rawget(module, "_name"))
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
    if rawget(addon, "_shutdown") == true or rawget(addon, "_passDepth") > 0 then
        return nil
    end
    if isContainerHalted(addon) then
        -- Halted is terminal: nothing in this container can recover.
        return nil
    end

    -- Every targeted `Enable` ends here, and almost always nothing is blocked:
    -- a linear scan is enough to skip building the graph.
    local modules = rawget(addon, "_moduleOrder")
    local anyBlocked = false
    for index = 1, #modules do
        if rawget(modules[index], "_enableBlockedBy") ~= nil then
            anyBlocked = true
            break
        end
    end
    if not anyBlocked then
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
            rawget(module, "_wantedEnabled") == true
            and rawget(module, "_enableBlockedBy") ~= nil
            and rawget(module, "_state") ~= "enabled"
        then
            local ready = true
            local dependencies = hardDependencies(module)
            for dependencyIndex = 1, #dependencies do
                if rawget(dependencies[dependencyIndex], "_state") ~= "enabled" then
                    ready = false
                    break
                end
            end
            -- A required addon that halted keeps the module blocked on it.
            local blocker = ready and haltBlocker(module) or nil
            if blocker ~= nil then
                rawset(module, "_enableBlockedBy", blocker)
            elseif ready then
                -- From here a failure is the module's own, not its
                -- dependency's, so it is not retried by the next recovery.
                rawset(module, "_enableBlockedBy", nil)
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
    local lifecycle = rawget(addon, "_lifecycle")
    if lifecycle:IsLoaded() then
        initializeWithPolicy(module, nil, 2)
    end
    if lifecycle:IsReady() then
        -- Catch-up is implicit, so a halt blocks it quietly instead of
        -- raising out of `CreateModule`; an explicit `Enable` still raises.
        local blocker = rawget(module, "_state") ~= "enabled" and haltBlocker(module) or nil
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
    if rawget(addon, "_passDepth") > 0 then
        local pending = rawget(addon, "_pendingCatchUp")
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
    if rawget(addon, "_flushingCatchUp") == true then
        return firstError
    end
    rawset(addon, "_flushingCatchUp", true)

    -- The queue is drained with a cursor rather than `table.remove(pending, 1)`,
    -- which shifted every remaining entry down one slot per module and made a
    -- flush quadratic in the number of modules waiting. Entries appended while
    -- the loop runs — catching one module up can queue another — are picked up
    -- by the same pass, so the order modules are caught up in is unchanged.
    local pending = rawget(addon, "_pendingCatchUp")
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

    rawset(addon, "_flushingCatchUp", false)
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
    rawset(addon, "_passDepth", rawget(addon, "_passDepth") + 1)
    local ok, result = pcall(pass, order, shutdown)
    local depth = rawget(addon, "_passDepth") - 1
    rawset(addon, "_passDepth", depth)

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
    local failed = {}

    for index = 1, #order do
        local module = order[index]
        local blockedBy
        local dependencies = hardDependencies(module)
        for depIndex = 1, #dependencies do
            local dependency = dependencies[depIndex]
            if failed[dependency] or rawget(dependency, "_state") == "created" then
                blockedBy = rawget(dependency, "_name")
                break
            end
        end

        if blockedBy ~= nil then
            failed[module] = true
            recordFailure(module, nil, blockedBy, false)
        elseif rawget(module, "_state") == "created" then
            local ok, value = pcall(initializeOne, module)
            if not ok then
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
    local failed = {}

    for index = 1, #order do
        local module = order[index]
        -- A module that is not wanted is left alone: not failed, not blocked.
        local wanted = not lifecycleDriven
            or rawget(module, "_wantedEnabled") ~= false
            or rawget(module, "_state") == "enabled"
        if wanted then
            -- A halt blocks the module like a failed dependency, and so blocks
            -- its dependents behind it.
            local blockedBy
            if rawget(module, "_state") ~= "enabled" then
                blockedBy = haltBlocker(module)
            end
            local dependencies = hardDependencies(module)
            for depIndex = 1, #dependencies do
                if blockedBy ~= nil then
                    break
                end
                local dependency = dependencies[depIndex]
                if failed[dependency] or rawget(dependency, "_state") ~= "enabled" then
                    blockedBy = rawget(dependency, "_name")
                end
            end

            if blockedBy ~= nil then
                failed[module] = true
                recordFailure(module, nil, blockedBy, false)
                rawset(module, "_enableBlockedBy", blockedBy)
            else
                local ok, value = pcall(enableOne, module)
                if not ok then
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
            rawset(order[index], "_wantedEnabled", true)
            rawset(order[index], "_enableBlockedBy", nil)
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
        if rawget(module, "_state") == "enabled" then
            if not shutdown then
                local dependents = enabledHardDependents(module)
                if #dependents > 0 then
                    -- A previously attempted dependent failed to disable. Do
                    -- not break the hard-dependency invariant in a reusable
                    -- (non-terminal) container by disabling its dependency.
                    recordFailure(module, nil, rawget(dependents[1], "_name"), false)
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
        rawset(addon, "_shutdown", true)
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
    if rawget(addon, "_shutdown") == true then
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

    local modules = rawget(addon, "_moduleOrder")
    for index = 1, #modules do
        local module = modules[index]
        if rawget(module, "_wantedEnabled") == true then
            rawset(module, "_enableBlockedBy", OWN_ADDON_HALTED)
        end
    end

    return runContainerPass(addon, runDisableAllPass, order, true, seedError)
end

---Disable `module` because `blockedBy` halted, taking its enabled hard
---dependents down first.
---
---The cascade ignores the dependency policy, as shutdown does: a halted addon
---cannot be waited for. Dependents keep their intent and are blocked by
---`module`, which is itself blocked for good.
---@param module ModuleKit.Module
---@param blockedBy string
local function blockForHaltedAddon(module, blockedBy)
    local dependents = enabledHardDependents(module)
    for index = 1, #dependents do
        blockForHaltedAddon(dependents[index], rawget(module, "_name"))
    end

    if rawget(module, "_wantedEnabled") == true then
        rawset(module, "_enableBlockedBy", blockedBy)
    end
    disableOne(module)
end

---Take down the modules that name a halted addon in `requiresAddons`.
---
---Modules are visited newest first; each one is independent, so a failing
---`OnDisable` leaves that module enabled and the rest are still visited. The
---first failure is re-raised afterwards.
---@param addon ModuleKit.Addon
---@param haltedAddonName string
---@return ModuleKit.Addon addon
local function dependencyHaltedInternal(addon, haltedAddonName)
    if rawget(addon, "_shutdown") == true then
        return addon
    end

    local modules = rawget(addon, "_moduleOrder")
    local firstError
    for index = #modules, 1, -1 do
        local module = modules[index]
        if requiresAddon(module, haltedAddonName) then
            local ok, value = pcall(blockForHaltedAddon, module, haltedAddonName)
            firstError = captureFirstError(firstError, ok, value)
        end
    end

    raiseCaptured(firstError)
    return addon
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

---Record injection aliases on `module`.
---@param module ModuleKit.Module
---@param aliasOrMap any one alias, or an alias-to-name map
---@param target any target name, when a single alias was given
---@param level integer stack level the failures are reported at, counted from this function: `3` from `Inject`, `4` from a `CreateModule` definition
local function addInjections(module, aliasOrMap, target, level)
    ensureDefinitionMutable(module, "Inject", level + 1)
    ensureNotShutdown(rawget(module, "_addon"), "ModuleKit.Module:Inject", level + 1)

    local specification = rawget(module, "_injectSpec")
    if type(aliasOrMap) == "table" and target == nil then
        local aliases = {}
        for alias in next, aliasOrMap do
            if type(alias) ~= "string" or alias == "" then
                error("ModuleKit.Module:Inject map aliases must be non-empty strings", level)
            end
            aliases[#aliases + 1] = alias
        end
        table.sort(aliases)

        for index = 1, #aliases do
            local alias = aliases[index]
            local dependency = rawget(aliasOrMap, alias)
            validateNonEmptyString(dependency, "ModuleKit.Module:Inject target", level + 1)
            rawset(specification, alias, dependency)
        end
        return
    end

    validateNonEmptyString(aliasOrMap, "ModuleKit.Module:Inject alias", level + 1)
    validateNonEmptyString(target, "ModuleKit.Module:Inject target", level + 1)
    rawset(specification, aliasOrMap, target)
end

---Declare injection aliases.
---
---Targets are provider or module **names**, never the objects themselves: the
---container resolves a name at initialization time, so a module can inject
---something that does not exist yet when the declaration is written.
---@param self ModuleKit.Module
---@param aliasOrMap string|table<string, string> one alias, or an alias-to-name map
---@param target string|nil target name, when a single alias was given
---@return ModuleKit.Module self
---@overload fun(self: ModuleKit.Module, map: table<string, string>): ModuleKit.Module
local function moduleInject(self, aliasOrMap, target)
    addInjections(self, aliasOrMap, target, 3)
    return self
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
    rawset(self, "_wantedEnabled", true)
    enableWithPolicy(self)
    raiseCaptured(recoverBlockedDependents(rawget(self, "_addon")))
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
    local lifecycle = rawget(addon, "_lifecycle")

    if lifecycle:IsLoaded() then
        initializeWithPolicy(self)
    end
    if lifecycle:IsReady() then
        enableWithPolicy(self)
        raiseCaptured(recoverBlockedDependents(addon))
    end
    return self
end

---Resolve an injectable with this module as the scope context.
---@param self ModuleKit.Module
---@param providerName string
---@return any
local function moduleResolve(self, providerName)
    validateNonEmptyString(providerName, "ModuleKit.Module:Resolve providerName", 3)
    return resolveProvider(rawget(self, "_addon"), providerName, self)
end

-- Addon public API ----------------------------------------------------------

---Return the addon name this container was created for.
---@param self ModuleKit.Addon
---@return string
local function addonGetAddonName(self)
    return rawget(self, "_name")
end

---Return the container's dependency policy.
---@param self ModuleKit.Addon
---@return ModuleKit.DependencyPolicy
local function addonGetDependencyPolicy(self)
    return rawget(self, "_dependencyPolicy")
end

---Change the container's dependency policy.
---@param self ModuleKit.Addon
---@param policy ModuleKit.DependencyPolicy
---@return ModuleKit.DependencyPolicy previous
local function addonSetDependencyPolicy(self, policy)
    ensureNotShutdown(self, "ModuleKit.Addon:SetDependencyPolicy", 3)
    if policy ~= "automatic" and policy ~= "strict" then
        error('ModuleKit.Addon:SetDependencyPolicy policy must be "automatic" or "strict"', 2)
    end
    local previous = rawget(self, "_dependencyPolicy")
    rawset(self, "_dependencyPolicy", policy)
    return previous
end

local DEFINITION_FIELDS = {
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

---Record one `requiresAddons` entry on `module`.
---
---Raised errors use level 5, the caller of `CreateModule`: this function is
---called by `applyDefinitionList`, which `applyDefinition` calls from
---`CreateModule`.
---@param module ModuleKit.Module
---@param addonName any
---@return ModuleKit.Module module
local function addRequiredAddon(module, addonName)
    if type(addonName) ~= "string" or addonName == "" then
        error("ModuleKit module definition requiresAddons entries must be non-empty strings", 5)
    end
    if addonName == rawget(rawget(module, "_addon"), "_name") then
        error(
            'ModuleKit module definition requiresAddons must name other addons, not "'
                .. addonName
                .. '" itself',
            5
        )
    end
    if requiresAddon(module, addonName) then
        return module
    end

    local required = rawget(module, "_requiredAddons")
    local maxRequiredAddons = rawget(sharedLimits, "maxRequiredAddons")
    if maxRequiredAddons ~= UNBOUNDED and #required >= maxRequiredAddons then
        error(
            "ModuleKit module definition requiresAddons must list at most "
                .. tostring(maxRequiredAddons)
                .. " addons (ModuleKit:SetLimits maxRequiredAddons)",
            5
        )
    end
    if required == NO_REQUIRED_ADDONS then
        required = {}
        rawset(module, "_requiredAddons", required)
    end
    required[#required + 1] = addonName
    return module
end

---Apply one dense-array definition field entry by entry: through the
---constraint `field` a `Module` method records, or, for `requiresAddons`
---(`field` is `nil`), through `addRequiredAddon`. Every refusal is raised at
---the caller of `CreateModule`, and an entry reports the same message the
---`Module` method it stands for would.
---@param module ModuleKit.Module
---@param definition ModuleKit.Definition
---@param key "dependsOn"|"optionalDependencies"|"before"|"after"|"requiresAddons"
---@param field "_hardDependencies"|"_optionalDependencies"|"_before"|"_after"|nil
---@param methodName string|nil the `Module` method the field stands for, used in the argument errors
local function applyDefinitionList(module, definition, key, field, methodName)
    local values = rawget(definition, key)
    if values == nil then
        return
    end
    if type(values) ~= "table" then
        error("ModuleKit module definition " .. key .. " must be a dense array", 4)
    end

    local count = 0
    local maximum = 0
    for index in next, values do
        if type(index) ~= "number" or index < 1 or index % 1 ~= 0 then
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
            addRequiredAddon(module, value)
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
    if callback == nil then
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
    if definition == nil then
        return
    end
    if type(definition) ~= "table" then
        error("ModuleKit.Addon:CreateModule definition must be a table when provided", 3)
    end

    local unknown = {}
    for key in next, definition do
        if type(key) ~= "string" or DEFINITION_FIELDS[key] ~= true then
            unknown[#unknown + 1] = tostring(key)
        end
    end
    if #unknown > 0 then
        table.sort(unknown)
        error('ModuleKit module definition contains unknown field "' .. unknown[1] .. '"', 3)
    end

    -- Apply in a fixed order so malformed definitions fail deterministically
    -- on every Lua implementation and every load order.
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
    applyDefinitionList(module, definition, "requiresAddons", nil, nil)

    local inject = rawget(definition, "inject")
    if inject ~= nil then
        addInjections(module, inject, nil, 4)
    end

    applyDefinitionCallback(module, definition, "onInitialize", "OnInitialize")
    applyDefinitionCallback(module, definition, "onEnable", "OnEnable")
    applyDefinitionCallback(module, definition, "onDisable", "OnDisable")
end

---Declare every addon `module` requires as a LifecycleKit dependency of its
---container's addon, so the addon hears when one of them halts.
---
---Runs before the module is published, so a refusal leaves the container
---without it. LifecycleKit keeps an addon's declarations for the session:
---entries declared before a refusal stay declared, which only means their
---halts are also announced. A LifecycleKit revision without `DependsOn`
---announces nothing; enabling still checks each required addon directly.
---@param addon ModuleKit.Addon
---@param module ModuleKit.Module
local function declareRequiredAddons(addon, module)
    local required = rawget(module, "_requiredAddons")
    if #required == 0 then
        return
    end

    local lifecycle = rawget(addon, "_lifecycle")
    local dependsOn = lifecycle.DependsOn
    if type(dependsOn) ~= "function" then
        return
    end

    for index = 1, #required do
        local recorded, reason = dependsOn(lifecycle, required[index])
        -- `"halted"` needs nothing here: the container's own halt already
        -- blocks every module. `"shutdown"` cannot occur, because a shut-down
        -- container refuses `CreateModule` before this point.
        if recorded == nil and reason == "full" then
            error(
                'ModuleKit.Addon:CreateModule module "'
                    .. rawget(module, "_name")
                    .. '" requires addon "'
                    .. required[index]
                    .. '", but addon "'
                    .. rawget(addon, "_name")
                    .. '" already declares the most addon dependencies LifecycleKit accepts',
                3
            )
        end
    end
end

---Create a uniquely named module in this container.
---@param self ModuleKit.Addon
---@param name string
---@param definition ModuleKit.Definition|nil atomic definition table; see `docs/API.md`
---@return ModuleKit.Module module
local function addonCreateModule(self, name, definition)
    ensureNotShutdown(self, "ModuleKit.Addon:CreateModule", 3)
    validateNonEmptyString(name, "ModuleKit.Addon:CreateModule name", 3)

    local modules = rawget(self, "_modules")
    if rawget(modules, name) ~= nil or rawget(rawget(self, "_providers"), name) ~= nil then
        error('ModuleKit.Addon:CreateModule name "' .. name .. '" is already in use', 2)
    end

    local order = rawget(self, "_moduleOrder")
    local module = setmetatable({
        _addon = self,
        _name = name,
        _order = #order + 1,
        _state = "created",
        _hardDependencies = {},
        _optionalDependencies = {},
        _before = {},
        _after = {},
        _requiredAddons = NO_REQUIRED_ADDONS,
        _injectSpec = {},
        _injections = nil,
        _lastError = nil,
        _hasLastError = false,
        _blockedBy = nil,
        -- Every module is meant to be enabled once its addon is ready, until
        -- an explicit `Disable` says otherwise.
        _wantedEnabled = true,
        _enableBlockedBy = nil,
        _scopeOpen = false,
    }, MODULE_METATABLE)
    local scope = newModuleScope(module)
    rawset(module, "_scope", scope)
    rawset(module, "scope", scope)

    applyDefinition(module, definition)
    -- The definition is atomic, so what the module carries when this returns
    -- is what it will carry: ModuleKit's own methods and the hooks the
    -- definition set. Checked before the module is published, so a refusal
    -- leaves the container without it.
    if definition ~= nil then
        local contract = compileImplements(
            rawget(definition, "implements"),
            "ModuleKit module definition implements",
            3
        )
        checkImplements(contract, module, 'module "' .. name .. '"', 3)
    end
    validateLateModuleOrdering(self, module)
    declareRequiredAddons(self, module)

    rawset(modules, name, module)
    order[#order + 1] = module

    -- A required addon may have halted before this module existed, or the
    -- container's own addon may have: record the block now, so the enable
    -- state shows it before anything tries to enable the module.
    local blocker = haltBlocker(module)
    if blocker ~= nil and rawget(module, "_wantedEnabled") == true then
        rawset(module, "_enableBlockedBy", blocker)
    end

    -- A fully specified late-created module can catch up immediately. For the
    -- common mutable-object style, omit the definition and call :Activate()
    -- after assigning callbacks/dependencies so no user setup is raced.
    --
    -- Created from a hook while a whole-container pass is running, the catch-up
    -- is deferred to the end of that pass; see `scheduleCatchUp`.
    if definition ~= nil then
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

---Register an addon-scoped constant. `nil` is rejected. The value exists
---already, so `options.implements` is checked here, at the caller's line.
---@param self ModuleKit.Addon
---@param name string
---@param value any
---@param options ModuleKit.ProvideOptions|nil
---@return ModuleKit.Addon self
local function addonProvideValue(self, name, value, options)
    ensureNotShutdown(self, "ModuleKit.Addon:ProvideValue", 3)
    if value == nil then
        error("ModuleKit.Addon:ProvideValue value must not be nil", 2)
    end
    validateNonEmptyString(name, "ModuleKit.Addon:ProvideValue providerName", 3)
    local contract = readProvideOptions(options, "ProvideValue", 3)
    checkImplements(contract, value, 'provider "' .. name .. '"', 3)
    return registerProvider(
        self,
        name,
        { kind = "value", value = value, implements = contract },
        "ProvideValue"
    )
end

---@param factory any
---@param methodName string public method name, used in the argument error
local function validateFactory(factory, methodName)
    if type(factory) ~= "function" then
        error("ModuleKit.Addon:" .. methodName .. " factory must be a function", 3)
    end
end

---Register a factory resolved once per container. `options.implements` is
---checked against the factory's result when it first arrives.
---@param self ModuleKit.Addon
---@param name string
---@param factory fun(addon: ModuleKit.Addon): any
---@param options ModuleKit.ProvideOptions|nil
---@return ModuleKit.Addon self
local function addonProvideSingleton(self, name, factory, options)
    ensureNotShutdown(self, "ModuleKit.Addon:ProvideSingleton", 3)
    validateFactory(factory, "ProvideSingleton")
    local contract = readProvideOptions(options, "ProvideSingleton", 3)
    return registerProvider(self, name, {
        kind = "singleton",
        factory = factory,
        resolved = false,
        value = nil,
        implements = contract,
    }, "ProvideSingleton")
end

---Register a factory resolved once per requesting module.
---`options.implements` is checked against each requesting module's value when
---it first arrives.
---@param self ModuleKit.Addon
---@param name string
---@param factory fun(addon: ModuleKit.Addon, module: ModuleKit.Module): any
---@param options ModuleKit.ProvideOptions|nil
---@return ModuleKit.Addon self
local function addonProvideModule(self, name, factory, options)
    ensureNotShutdown(self, "ModuleKit.Addon:ProvideModule", 3)
    validateFactory(factory, "ProvideModule")
    local contract = readProvideOptions(options, "ProvideModule", 3)
    return registerProvider(self, name, {
        kind = "module",
        factory = factory,
        cache = {},
        implements = contract,
    }, "ProvideModule")
end

---Register a factory resolved on every resolution. Every value it produces is
---new, so `options.implements` is checked on every resolution.
---@param self ModuleKit.Addon
---@param name string
---@param factory fun(addon: ModuleKit.Addon, module: ModuleKit.Module|nil): any
---@param options ModuleKit.ProvideOptions|nil
---@return ModuleKit.Addon self
local function addonProvideTransient(self, name, factory, options)
    ensureNotShutdown(self, "ModuleKit.Addon:ProvideTransient", 3)
    validateFactory(factory, "ProvideTransient")
    local contract = readProvideOptions(options, "ProvideTransient", 3)
    return registerProvider(self, name, {
        kind = "transient",
        factory = factory,
        implements = contract,
    }, "ProvideTransient")
end

---Resolve an injectable, optionally with module scope context.
---@param self ModuleKit.Addon
---@param name string
---@param requestingModule ModuleKit.Module|nil must be owned by this container
---@return any
local function addonResolve(self, name, requestingModule)
    if requestingModule ~= nil then
        local modules = rawget(self, "_modules")
        local requesterName = type(requestingModule) == "table"
                and rawget(requestingModule, "_name")
            or nil
        if
            type(requesterName) ~= "string"
            or rawget(requestingModule, "_addon") ~= self
            or rawget(modules, requesterName) ~= requestingModule
        then
            error(
                "ModuleKit.Addon:Resolve requestingModule must be a module owned by this addon",
                2
            )
        end
    end
    return resolveProvider(self, name, requestingModule)
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

---LifecycleKit query that reports whether a phase has already been reached.
local PHASE_REACHED_QUERY = {
    loaded = "IsLoaded",
    ready = "IsReady",
    shutdown = "IsShutdown",
}

---Shared runtime dispatch entry point per phase.
local PHASE_DISPATCH = {
    loaded = "initializeAll",
    ready = "enableAll",
    shutdown = "shutdown",
}

---The LifecycleKit notices a container subscribes to beside the phases:
---its own addon halting, and a declared addon dependency halting. Both are
---keys of `_subscriptions`.
local HALT_NOTICES = { "halted", "dependencyHalted" }

---Call one whole-container pass through shared runtime dispatch.
---
---Going through shared state rather than a captured local is what lets a newer
---compatible revision upgrade containers an older copy created.
---@param name "initializeAll"|"enableAll"|"shutdown"|"halted"|"dependencyHalted"
---@param addon ModuleKit.Addon
---@param argument any passed on after `addon`: the halted addon's name for `dependencyHalted`
---@return ModuleKit.Addon addon
local function invokeDispatch(name, addon, argument)
    local dispatch = rawget(state, "dispatch")
    local callback = type(dispatch) == "table" and rawget(dispatch, name) or nil
    if type(callback) ~= "function" then
        error("MoltenCodes ModuleKit runtime dispatch is corrupted or incomplete", 2)
    end
    return callback(addon, argument)
end

---Report whether LifecycleKit has already reached `phase` for `lifecycle`.
---@param lifecycle LifecycleKit.Instance
---@param phase "loaded"|"ready"|"shutdown"
---@return boolean
local function isPhaseReached(lifecycle, phase)
    local query = lifecycle[PHASE_REACHED_QUERY[phase]]
    return query(lifecycle) == true
end

---Install the per-module fields revision 6 added, on a module an earlier
---revision created.
---
---An earlier revision recorded no intent, so it is derived from the fact: a
---disabled module was disabled deliberately or by a failure, and every other
---module is still meant to be enabled. Fields already present are kept, which
---is what carries intent and blocking across an upgrade unchanged.
---@param module ModuleKit.Module
local function ensureModuleRuntimeFields(module)
    local moduleState = rawget(module, "_state")
    if type(rawget(module, "_wantedEnabled")) ~= "boolean" then
        rawset(module, "_wantedEnabled", moduleState ~= "disabled")
    end
    if type(rawget(module, "_scopeOpen")) ~= "boolean" then
        rawset(module, "_scopeOpen", moduleState == "enabled")
    end
    if type(rawget(module, "_requiredAddons")) ~= "table" then
        -- Revision 8 added `requiresAddons`; an older module declared none.
        rawset(module, "_requiredAddons", NO_REQUIRED_ADDONS)
    end
    if type(rawget(module, "_scope")) ~= "table" then
        local scope = newModuleScope(module)
        rawset(module, "_scope", scope)
        if rawget(module, "scope") == nil then
            rawset(module, "scope", scope)
        end
    end
end

---Install the per-container runtime fields this implementation revision owns.
---
---A container created by an earlier compatible revision carries neither the
---dispatched-phase set nor the whole-container pass bookkeeping, so an
---in-place upgrade adds them before anything reads them.
---
---The dispatched set is rebuilt from LifecycleKit: every revision subscribed
---to all three phases when it created a container, and LifecycleKit replays a
---phase it has already reached to every new subscriber. For a carried-over
---container, "phase reached" and "phase already dispatched into this
---container" therefore mean the same thing.
---@param addon ModuleKit.Addon
---@param lifecycle LifecycleKit.Instance
local function ensureContainerRuntimeFields(addon, lifecycle)
    if type(rawget(addon, "_dispatched")) ~= "table" then
        local dispatched = {}
        for index = 1, #LIFECYCLE_PHASES do
            local phase = LIFECYCLE_PHASES[index]
            if isPhaseReached(lifecycle, phase) then
                rawset(dispatched, phase, true)
            end
        end
        rawset(addon, "_dispatched", dispatched)
    end

    if type(rawget(addon, "_passDepth")) ~= "number" then
        rawset(addon, "_passDepth", 0)
    end
    if type(rawget(addon, "_pendingCatchUp")) ~= "table" then
        rawset(addon, "_pendingCatchUp", {})
    end

    local order = rawget(addon, "_moduleOrder")
    for index = 1, #order do
        ensureModuleRuntimeFields(order[index])
    end
end

---Disconnect one LifecycleKit subscription handle.
---@param subscription any handle returned by a LifecycleKit `On<Phase>` call
local function disconnectSubscriptionHandle(subscription)
    local disconnect = type(subscription) == "table" and subscription.Disconnect or nil
    if type(disconnect) ~= "function" then
        error("MoltenCodes ModuleKit lifecycle subscription state is corrupted", 2)
    end
    disconnect(subscription)
end

---Drop every LifecycleKit subscription this container currently holds.
---@param addon ModuleKit.Addon
local function disconnectAddonSubscriptions(addon)
    local subscriptions = rawget(addon, "_subscriptions")
    if type(subscriptions) ~= "table" then
        rawset(addon, "_subscriptions", {})
        return
    end

    for index = 1, #LIFECYCLE_PHASES do
        local subscription = rawget(subscriptions, LIFECYCLE_PHASES[index])
        if subscription ~= nil then
            disconnectSubscriptionHandle(subscription)
        end
    end
    for index = 1, #HALT_NOTICES do
        local subscription = rawget(subscriptions, HALT_NOTICES[index])
        if subscription ~= nil then
            disconnectSubscriptionHandle(subscription)
        end
    end
    rawset(addon, "_subscriptions", {})
end

---Subscribe the container to its addon's halted notices.
---
---A LifecycleKit revision older than the halted state offers neither notice,
---and its addons never halt, so nothing is subscribed.
---
---Both subscriptions replay synchronously, like the phases, and the replay
---hazard applies to them too:
---
---- `OnHalted` replays for an addon that has already halted. A new container
---  holds no modules yet, so the replay only records the halt. During an
---  upgrade the halt is recorded as dispatched without running, so no module
---  hook can run out of package bootstrap; enabling still refuses every
---  module, because each enable path asks LifecycleKit directly.
---- `OnDependencyHalted` replays every declared dependency that has already
---  halted. The replay is ignored: a module that requires a halted addon is
---  blocked when it is created (see `addonCreateModule`), and an upgrade must
---  not disable modules from package bootstrap.
---@param addon ModuleKit.Addon
---@param lifecycle LifecycleKit.Instance
---@param duringUpgrade boolean|nil `true` while migrating a carried-over container
local function installHaltSubscriptions(addon, lifecycle, duringUpgrade)
    local onHalted = lifecycle.OnHalted
    local onDependencyHalted = lifecycle.OnDependencyHalted
    if type(onHalted) ~= "function" or type(onDependencyHalted) ~= "function" then
        return
    end

    local dispatched = rawget(addon, "_dispatched")
    if rawget(dispatched, "halted") ~= true then
        if duringUpgrade and isContainerHalted(addon) then
            rawset(dispatched, "halted", true)
        else
            local handle = onHalted(lifecycle, function()
                -- Recorded first, like a phase: the halt has happened even if
                -- taking the modules down raises.
                rawset(rawget(addon, "_dispatched"), "halted", true)
                invokeDispatch("halted", addon)
            end)
            rawget(addon, "_subscriptions").halted = handle
        end
    end

    local replaying = true
    local handle = onDependencyHalted(lifecycle, function(_, haltedAddonName)
        if not replaying then
            invokeDispatch("dependencyHalted", addon, haltedAddonName)
        end
    end)
    replaying = false
    rawget(addon, "_subscriptions").dependencyHalted = handle
end

---Subscribe the container to the LifecycleKit phases it has not received yet.
---
---LifecycleKit replays a phase it has already reached to every new subscriber.
---That is exactly what a freshly created container wants, and exactly what an
---in-place upgrade must avoid: re-subscribing there would run module hooks out
---of package bootstrap, and the replayed `ready` phase would call `EnableAll`,
---silently re-enabling a module the addon had deliberately disabled.
---
---The dispatched-phase set is the guard. During an upgrade the lifecycle is
---also probed directly, so no already-reached phase can be subscribed to even
---if the set were wrong, and a module hook can therefore never run out of
---package bootstrap.
---@param addon ModuleKit.Addon
---@param duringUpgrade boolean|nil `true` while migrating a carried-over container
local function installAddonSubscriptions(addon, duringUpgrade)
    local lifecycle = rawget(addon, "_lifecycle")
    if
        type(lifecycle) ~= "table"
        or type(lifecycle.IsShutdown) ~= "function"
        or type(lifecycle.IsLoaded) ~= "function"
        or type(lifecycle.IsReady) ~= "function"
        or type(lifecycle.OnLoaded) ~= "function"
        or type(lifecycle.OnReady) ~= "function"
        or type(lifecycle.OnShutdown) ~= "function"
    then
        error("MoltenCodes ModuleKit addon lifecycle state is corrupted", 2)
    end

    ensureContainerRuntimeFields(addon, lifecycle)

    rawset(addon, "_subscriptions", {})

    if rawget(addon, "_shutdown") == true then
        return
    end

    local dispatched = rawget(addon, "_dispatched")
    for index = 1, #LIFECYCLE_PHASES do
        local phase = LIFECYCLE_PHASES[index]
        if rawget(dispatched, phase) ~= true then
            if duringUpgrade and isPhaseReached(lifecycle, phase) then
                -- The dispatched set disagreed with LifecycleKit. Trust the
                -- lifecycle and record the phase rather than subscribing, so a
                -- replay cannot reach module hooks from package bootstrap.
                rawset(dispatched, phase, true)
            else
                local dispatchName = PHASE_DISPATCH[phase]
                local subscribe = lifecycle[PHASE_SUBSCRIBE[phase]]
                local handle = subscribe(lifecycle, function()
                    -- Record the phase before dispatching. It has happened even
                    -- if the dispatch raises, and a later in-place upgrade must
                    -- not run it a second time.
                    rawset(rawget(addon, "_dispatched"), phase, true)
                    return invokeDispatch(dispatchName, addon)
                end)

                -- `subscribe` is not a passive registration: LifecycleKit
                -- replays a phase it has already reached to the new subscriber,
                -- synchronously, before it returns the handle. A module hook
                -- running inside that replay can reach container shutdown, so
                -- the `_shutdown` test above is stale from here on and the
                -- container may no longer own the table this loop started with.
                --
                -- Re-test and re-read both. A shutdown that happened during the
                -- replay disconnects the handle it just produced and abandons
                -- the phases behind it: a shut-down container must not be left
                -- listening for `ready`, and a handle filed in a `_subscriptions`
                -- table the container has replaced is one nothing would ever
                -- disconnect.
                if rawget(addon, "_shutdown") == true then
                    disconnectSubscriptionHandle(handle)
                    return
                end

                rawget(addon, "_subscriptions")[phase] = handle
            end
        end
    end

    installHaltSubscriptions(addon, lifecycle, duringUpgrade)
end

---Create the container for `addonName` and bind it to its lifecycle.
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
        _providers = {},
        _resolutionStack = {},
        _shutdown = lifecycle:IsShutdown(),
        _subscriptions = {},
        -- A new container has received nothing yet, so every phase LifecycleKit
        -- has already reached is replayed into it on subscription.
        _dispatched = {},
        _passDepth = 0,
        _pendingCatchUp = {},
    }, ADDON_METATABLE)

    local addons = rawget(state, "addons")
    rawset(addons, addonName, addon)

    if not rawget(addon, "_shutdown") then
        installAddonSubscriptions(addon)
    end

    return addon
end

---Return the stable container for `addonName`, creating it on demand.
---@param _ ModuleKit
---@param addonName string addon folder name, as LifecycleKit matches it
---@return ModuleKit.Addon addon
local function forAddon(_, addonName)
    validateNonEmptyString(addonName, "ModuleKit:ForAddon addonName", 3)

    local addons = rawget(state, "addons")
    local addon = rawget(addons, addonName)
    if addon ~= nil then
        return addon
    end
    return createAddon(addonName)
end

-- Package-wide limits ------------------------------------------------------

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

---Refuse `limits` unless every entry names a known limit with a valid value.
---Nothing is changed here, so a refusal leaves every limit as it was.
---@param limits any
---@param level integer error level of the `SetLimits` caller
local function validateLimitUpdate(limits, level)
    if type(limits) ~= "table" then
        error("ModuleKit:SetLimits limits must be a table", level)
    end
    local ceiling = lifecycleDependencyCeiling()
    local key = next(limits)
    while key ~= nil do
        if type(key) ~= "string" or KNOWN_LIMITS[key] ~= true then
            error(
                "ModuleKit:SetLimits limits." .. tostring(key) .. " is not a recognised limit",
                level
            )
        end
        local value = rawget(limits, key)
        if value == UNBOUNDED then
            if ceiling ~= nil then
                error(
                    "ModuleKit:SetLimits limits."
                        .. key
                        .. " cannot be ModuleKit.UNBOUNDED: LifecycleKit accepts at most "
                        .. ceiling
                        .. " dependencies per addon",
                    level
                )
            end
        elseif not isPositiveInteger(value) then
            error(
                "ModuleKit:SetLimits limits."
                    .. key
                    .. " must be a positive integer or ModuleKit.UNBOUNDED",
                level
            )
        elseif ceiling ~= nil and value > ceiling then
            error(
                "ModuleKit:SetLimits limits."
                    .. key
                    .. " must be an integer from 1 to "
                    .. ceiling
                    .. ", LifecycleKit's maxDependencies",
                level
            )
        end
        key = next(limits, key)
    end
end

---Change any subset of the package-wide limits. Affects every consumer in the
---session. Lowering a limit never removes what modules already declared.
---@param self ModuleKit
---@param limits ModuleKit.Limits|table
local function setLimits(self, limits)
    if self ~= ModuleKit then
        error(
            "ModuleKit:SetLimits must be called on the ModuleKit facade; use ModuleKit:SetLimits(...)",
            2
        )
    end
    validateLimitUpdate(limits, 3)
    for index = 1, #LIMIT_NAMES do
        local name = LIMIT_NAMES[index]
        local value = rawget(limits, name)
        if value ~= nil then
            rawset(sharedLimits, name, value)
        end
    end
end

---Return a fresh copy of the package-wide limits. Allocates one table.
---@param self ModuleKit
---@return ModuleKit.Limits limits
local function getLimits(self)
    if self ~= ModuleKit then
        error(
            "ModuleKit:GetLimits must be called on the ModuleKit facade; use ModuleKit:GetLimits()",
            2
        )
    end
    return { maxRequiredAddons = rawget(sharedLimits, "maxRequiredAddons") }
end

---Move every live container's LifecycleKit subscriptions onto this revision.
local function migrateAddonSubscriptions()
    local addons = rawget(state, "addons")
    local names = {}
    for name in pairs(addons) do
        names[#names + 1] = name
    end
    table.sort(names)

    local firstError
    for index = 1, #names do
        local addon = rawget(addons, names[index])
        if type(addon) ~= "table" then
            if firstError == nil then
                firstError = { value = "MoltenCodes ModuleKit addon state is corrupted" }
            end
        else
            local ok, value = pcall(function()
                disconnectAddonSubscriptions(addon)
                installAddonSubscriptions(addon, true)
            end)
            firstError = captureFirstError(firstError, ok, value)
        end
    end

    raiseCaptured(firstError)
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
rawset(Module, "Inject", moduleInject)
rawset(Module, "Initialize", moduleInitialize)
rawset(Module, "Enable", moduleEnable)
rawset(Module, "Disable", moduleDisable)
rawset(Module, "Activate", moduleActivate)
rawset(Module, "Resolve", moduleResolve)

rawset(Addon, "GetAddonName", addonGetAddonName)
rawset(Addon, "GetDependencyPolicy", addonGetDependencyPolicy)
rawset(Addon, "SetDependencyPolicy", addonSetDependencyPolicy)
rawset(Addon, "CreateModule", addonCreateModule)
rawset(Addon, "GetModule", addonGetModule)
rawset(Addon, "HasModule", addonHasModule)
rawset(Addon, "GetModules", addonGetModules)
rawset(Addon, "GetActivationOrder", addonGetActivationOrder)
rawset(Addon, "ValidateGraph", addonValidateGraph)
rawset(Addon, "InitializeAll", addonInitializeAll)
rawset(Addon, "EnableAll", addonEnableAll)
rawset(Addon, "DisableAll", addonDisableAll)
rawset(Addon, "ProvideValue", addonProvideValue)
rawset(Addon, "ProvideSingleton", addonProvideSingleton)
rawset(Addon, "ProvideModule", addonProvideModule)
rawset(Addon, "ProvideTransient", addonProvideTransient)
rawset(Addon, "Resolve", addonResolve)

rawset(SCOPE_METATABLE, "__index", scopeIndex)

rawset(ModuleKit, "API", API_GENERATION)
rawset(ModuleKit, "REVISION", IMPLEMENTATION_REVISION)
rawset(ModuleKit, "UNBOUNDED", UNBOUNDED)
rawset(ModuleKit, "ForAddon", forAddon)
rawset(ModuleKit, "SetLimits", setLimits)
rawset(ModuleKit, "GetLimits", getLimits)

-- Lifecycle subscriptions installed by revision 1 closed over that revision's
-- local implementation functions. Revision 2 moves them behind shared-state
-- dispatch so existing addon containers observe future compatible bug fixes
-- without replacing container identity or requiring addon reloads.
local dispatch = rawget(state, "dispatch")
rawset(dispatch, "initializeAll", initializeAllInternal)
rawset(dispatch, "enableAll", function(addon)
    return enableAllInternal(addon, true)
end)
rawset(dispatch, "shutdown", function(addon)
    return disableAllInternal(addon, true)
end)
rawset(dispatch, "halted", haltAllInternal)
rawset(dispatch, "dependencyHalted", dependencyHaltedInternal)

if rawget(state, "runtimeRevision") ~= IMPLEMENTATION_REVISION then
    migrateAddonSubscriptions()
    rawset(state, "runtimeRevision", IMPLEMENTATION_REVISION)
end

if not validatePublicSurface(ModuleKit) or not validateCurrentState(ModuleKit) then
    error("MoltenCodes ModuleKit package state is corrupted or incomplete", 2)
end

return ModuleKit
