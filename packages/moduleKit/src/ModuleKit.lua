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
--   Dependency injection . Provider registration, scoped resolution, cycles.
--   Module scopes ........ Per-module timer, event and job scopes released on
--                          disable, resolved through `Registry:Find`.
--   Lifecycle operations . Single-module transitions, dependency policies,
--                          intent versus fact, recovery of blocked dependents,
--                          whole-container passes and deferred catch-up.
--   Module public API ..... Methods installed on the shared Module prototype.
--   Addon public API ...... Methods installed on the shared Addon prototype.
--   Addon creation ........ Container identity and LifecycleKit subscriptions.
--   Commit ................ Publishing the public surface and runtime dispatch.
--
-- `docs/INTERNALS.md` explains the graph algorithm, the failure model, the
-- lifecycle replay hazard that the dispatched-phase set guards against, module
-- scopes, and the intent-versus-fact enable state.

local PACKAGE_NAME = "moduleKit"
local API_GENERATION = 1
local IMPLEMENTATION_REVISION = 6
local REQUIRED_REGISTRY_API = 2
local REQUIRED_LIFECYCLE_API = 1
local STATE_SCHEMA = 1

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
---@field onInitialize fun(self: ModuleKit.Module, injections: table<string, any>)?
---@field onEnable fun(self: ModuleKit.Module)?
---@field onDisable fun(self: ModuleKit.Module)?

---One module inside an addon container.
---
---Hook fields are assigned by the consumer, either through the definition table
---or directly on the module, and are called by ModuleKit at the matching phase.
---@class ModuleKit.Module
---@field scope ModuleKit.Scope framework registrations released on disable
---@field OnInitialize fun(self: ModuleKit.Module, injections: table<string, any>)?
---@field OnEnable fun(self: ModuleKit.Module)?
---@field OnDisable fun(self: ModuleKit.Module)?
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
---@field ProvideValue fun(self: ModuleKit.Addon, name: string, value: any): ModuleKit.Addon
---@field ProvideSingleton fun(self: ModuleKit.Addon, name: string, factory: fun(addon: ModuleKit.Addon): any): ModuleKit.Addon
---@field ProvideModule fun(self: ModuleKit.Addon, name: string, factory: fun(addon: ModuleKit.Addon, module: ModuleKit.Module): any): ModuleKit.Addon
---@field ProvideTransient fun(self: ModuleKit.Addon, name: string, factory: fun(addon: ModuleKit.Addon, module: ModuleKit.Module|nil): any): ModuleKit.Addon
---@field Resolve fun(self: ModuleKit.Addon, name: string, requestingModule: ModuleKit.Module|nil): any

---Per-module owner of framework registrations, released when the module is
---disabled. Each field is created on first read, only while the module is
---enabling or enabled, and is `nil` when the Kit behind it is not loaded.
---@class ModuleKit.Scope
---@field Timers table? a TimerKit scope (`TimerKit:CreateScope()`)
---@field Events table? an EventKit scope (`EventKit:CreateScope()`)
---@field Jobs table? a SchedulerKit scope (`SchedulerKit:CreateScope()`)

---Intent and fact of one module's enable state, as `GetEnableState` reports it.
---@class ModuleKit.EnableState
---@field wanted boolean whether the module is meant to be enabled
---@field actual boolean whether the module is enabled right now
---@field blockedBy string|nil the hard dependency whose failure keeps it off

---An error object wrapped so that `nil` and `false` stay representable.
---@class ModuleKit.ErrorRecord
---@field value any the original Lua error object

---The ModuleKit package facade published through Registry.
---@class ModuleKit
---@field API integer Public API generation.
---@field REVISION integer Compatible implementation revision.
---@field Addon ModuleKit.Addon Shared container prototype.
---@field Module ModuleKit.Module Shared module prototype.
---@field ForAddon fun(self: ModuleKit, addonName: string): ModuleKit.Addon

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

---Whether `implementation` carries runtime state this revision has committed.
---@param implementation table
---@return boolean
local function validateCurrentState(implementation)
    local currentState = rawget(implementation, "_state")
    local dispatch = type(currentState) == "table" and rawget(currentState, "dispatch") or nil
    return validateStateBase(currentState)
        and rawget(currentState, "runtimeRevision") == IMPLEMENTATION_REVISION
        and type(dispatch) == "table"
        and type(rawget(dispatch, "initializeAll")) == "function"
        and type(rawget(dispatch, "enableAll")) == "function"
        and type(rawget(dispatch, "shutdown")) == "function"
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
end

-- Every module scope shares this metatable. It lives in shared state, and each
-- revision installs its own `__index` on it, so scopes created by an older copy
-- observe the newer lookup after an upgrade.
local SCOPE_METATABLE = rawget(state, "scopeMetatable")

local ADDON_METATABLE = { __index = Addon }
local MODULE_METATABLE = { __index = Module }

-- Validation helpers --------------------------------------------------------

---@param value any
---@param label string argument description, used in the argument error
---@param level integer? stack level the failure is reported at; defaults to `3`
local function validateNonEmptyString(value, label, level)
    if type(value) ~= "string" or value == "" then
        error(label .. " must be a non-empty string", level or 3)
    end
end

---@param value any
---@param methodName string public method name, used in the argument error
local function validateModuleName(value, methodName)
    validateNonEmptyString(value, "ModuleKit.Module:" .. methodName .. " moduleName", 4)
end

---@param value any
---@param methodName string public method name, used in the argument error
local function validateProviderName(value, methodName)
    validateNonEmptyString(value, "ModuleKit.Addon:" .. methodName .. " providerName", 4)
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
---@param methodName string public method name, used in the argument error
local function ensureDefinitionMutable(module, methodName)
    if rawget(module, "_state") ~= "created" then
        error(
            "ModuleKit.Module:"
                .. methodName
                .. ' cannot change module "'
                .. rawget(module, "_name")
                .. '" after initialization',
            3
        )
    end
end

---Refuse an operation on a container whose addon has already shut down.
---@param addon ModuleKit.Addon
---@param methodName string public method name, used in the argument error
local function ensureNotShutdown(addon, methodName)
    if rawget(addon, "_shutdown") == true then
        error("ModuleKit.Addon:" .. methodName .. " cannot run after addon shutdown", 3)
    end
end

---Record one dependency or ordering edge by target name.
---
---Targets are names rather than objects, so an edge can be declared before the
---module it names exists.
---@param module ModuleKit.Module
---@param field "_hardDependencies"|"_optionalDependencies"|"_before"|"_after"
---@param targetName string
---@param methodName string public method name, used in the argument errors
---@return ModuleKit.Module module
local function addNameConstraint(module, field, targetName, methodName)
    ensureDefinitionMutable(module, methodName)
    ensureNotShutdown(rawget(module, "_addon"), methodName)
    validateModuleName(targetName, methodName)

    if targetName == rawget(module, "_name") then
        error('ModuleKit module "' .. targetName .. '" cannot depend/order against itself', 3)
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
                3
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
---@param addon ModuleKit.Addon
---@return ModuleKit.Module[] order activation order for the whole container
local function buildGraph(addon)
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
                    3
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
        error("ModuleKit dependency cycle detected: " .. description, 3)
    end

    return result
end

---Return the modules `module` requires, in deterministic order.
---@param module ModuleKit.Module
---@return ModuleKit.Module[]
local function hardDependencies(module)
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
                3
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
    validateProviderName(name, methodName)
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
    validateProviderName(name, "Resolve")

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
-- A module registers timers, events and scheduler jobs through `module.scope`
-- and ModuleKit releases all of them when the module is disabled, so a module
-- needs no `OnDisable` just to clean up. ModuleKit has no hard dependency on
-- the Kits behind the scope: each is resolved through `Registry:Find` on first
-- use, and a field whose Kit is not loaded reads as `nil`.

---The Kit behind each scope field, and the order scopes are closed in.
local SCOPE_FIELDS = { "Events", "Jobs", "Timers" }
local SCOPE_PACKAGES = {
    Events = "eventKit",
    Jobs = "schedulerKit",
    Timers = "timerKit",
}
-- eventKit, schedulerKit and timerKit are all API generation 1.
local SCOPE_PACKAGE_API = 1

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
    local createScope = kit ~= nil and rawget(kit, "CreateScope") or nil
    if type(createScope) ~= "function" then
        -- The Kit is not loaded, or is a revision without owner scopes.
        return nil
    end

    local created = createScope(kit)
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

---Enable exactly `module`, initializing it first when it is still `created`.
---@param module ModuleKit.Module
---@return ModuleKit.Module module
local function enableOne(module)
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
            3
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
    return module
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

---Record that `module` is meant to stay disabled, which also ends any wait
---for a dependency to recover.
---@param module ModuleKit.Module
local function markWantedDisabled(module)
    rawset(module, "_wantedEnabled", false)
    rawset(module, "_enableBlockedBy", nil)
end

---Initialize `module` under the container's dependency policy.
---@param module ModuleKit.Module
---@param visiting table<ModuleKit.Module, boolean>|nil recursion guard, `automatic` policy only
---@return ModuleKit.Module module
local function initializeWithPolicy(module, visiting)
    local addon = rawget(module, "_addon")
    ensureNotShutdown(addon, "Initialize")

    if rawget(module, "_state") ~= "created" then
        return module
    end

    local dependencies = hardDependencies(module)
    local policy = rawget(addon, "_dependencyPolicy")

    if policy == "automatic" then
        visiting = visiting or {}
        if visiting[module] then
            error(
                'ModuleKit dependency cycle detected while initializing "'
                    .. rawget(module, "_name")
                    .. '"',
                3
            )
        end
        visiting[module] = true
        for index = 1, #dependencies do
            initializeWithPolicy(dependencies[index], visiting)
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
                    3
                )
            end
        end
    end

    return initializeOne(module)
end

---Enable `module` under the container's dependency policy.
---@param module ModuleKit.Module
---@param visiting table<ModuleKit.Module, boolean>|nil recursion guard, `automatic` policy only
---@return ModuleKit.Module module
local function enableWithPolicy(module, visiting)
    local addon = rawget(module, "_addon")
    ensureNotShutdown(addon, "Enable")

    local dependencies = hardDependencies(module)
    local policy = rawget(addon, "_dependencyPolicy")

    if policy == "automatic" then
        visiting = visiting or {}
        if visiting[module] then
            error(
                'ModuleKit dependency cycle detected while enabling "'
                    .. rawget(module, "_name")
                    .. '"',
                3
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
            enableWithPolicy(dependency, visiting)
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
                    3
                )
            end
        end
    end

    return enableOne(module)
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
            if ready then
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
---@param addon ModuleKit.Addon
---@param module ModuleKit.Module
local function catchUpModule(addon, module)
    local lifecycle = rawget(addon, "_lifecycle")
    if lifecycle:IsLoaded() then
        initializeWithPolicy(module)
    end
    if lifecycle:IsReady() then
        enableWithPolicy(module)
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
---@param pass fun(order: ModuleKit.Module[], shutdown: boolean|nil): ModuleKit.ErrorRecord|nil
---@param order ModuleKit.Module[] modules in the order the pass must visit them
---@param shutdown boolean|nil terminal-cleanup flag, for the disable pass
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
---@return ModuleKit.Addon addon
local function initializeAllInternal(addon)
    ensureNotShutdown(addon, "InitializeAll")
    local order = buildGraph(addon)
    return runContainerPass(addon, runInitializeAllPass, order)
end

---Enable every module in `order`, initializing the ones still in `created`.
---@param order ModuleKit.Module[]
---@return ModuleKit.ErrorRecord|nil firstError
local function runEnableAllPass(order)
    local firstError
    local failed = {}

    for index = 1, #order do
        local module = order[index]
        local blockedBy
        local dependencies = hardDependencies(module)
        for depIndex = 1, #dependencies do
            local dependency = dependencies[depIndex]
            if failed[dependency] or rawget(dependency, "_state") ~= "enabled" then
                blockedBy = rawget(dependency, "_name")
                break
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

    return firstError
end

---Enable the whole container in deterministic graph order.
---
---This is a target state, not a delta: a module that was explicitly disabled
---earlier is enabled again. See `docs/API.md` for why.
---@param addon ModuleKit.Addon
---@return ModuleKit.Addon addon
local function enableAllInternal(addon)
    ensureNotShutdown(addon, "EnableAll")
    local order = buildGraph(addon)

    -- The whole container is meant to be enabled; the pass records which
    -- modules a failed dependency blocks.
    for index = 1, #order do
        rawset(order[index], "_wantedEnabled", true)
        rawset(order[index], "_enableBlockedBy", nil)
    end

    return runContainerPass(addon, runEnableAllPass, order)
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
---@return ModuleKit.Addon addon
local function disableAllInternal(addon, shutdown)
    local order
    local seedError
    local graphOk, graphResult = pcall(buildGraph, addon)

    if graphOk then
        order = graphResult
    elseif shutdown then
        -- Shutdown is terminal cleanup. A malformed inactive definition must
        -- not prevent already-enabled modules from releasing resources. Keep
        -- the graph error for diagnostics, but continue in a safe order based
        -- on the hard-dependency edges of enabled modules only.
        seedError = { value = graphResult }
        order = buildEnabledHardOrder(addon)
    else
        error(graphResult, 0)
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
---names the hard dependency whose failure keeps a wanted module off.
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
    return addNameConstraint(self, "_hardDependencies", moduleName, "DependsOn")
end

---Order after `moduleName` when it exists, without requiring it.
---@param self ModuleKit.Module
---@param moduleName string
---@return ModuleKit.Module self
local function moduleOptionalDependency(self, moduleName)
    return addNameConstraint(self, "_optionalDependencies", moduleName, "OptionalDependency")
end

---Order this module before `moduleName`, without requiring it.
---@param self ModuleKit.Module
---@param moduleName string
---@return ModuleKit.Module self
local function moduleBefore(self, moduleName)
    return addNameConstraint(self, "_before", moduleName, "Before")
end

---Order this module after `moduleName`, without requiring it.
---@param self ModuleKit.Module
---@param moduleName string
---@return ModuleKit.Module self
local function moduleAfter(self, moduleName)
    return addNameConstraint(self, "_after", moduleName, "After")
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
    ensureDefinitionMutable(self, "Inject")
    ensureNotShutdown(rawget(self, "_addon"), "Inject")

    local specification = rawget(self, "_injectSpec")
    if type(aliasOrMap) == "table" and target == nil then
        local aliases = {}
        for alias in next, aliasOrMap do
            if type(alias) ~= "string" or alias == "" then
                error("ModuleKit.Module:Inject map aliases must be non-empty strings", 3)
            end
            aliases[#aliases + 1] = alias
        end
        table.sort(aliases)

        for index = 1, #aliases do
            local alias = aliases[index]
            local dependency = rawget(aliasOrMap, alias)
            validateNonEmptyString(dependency, "ModuleKit.Module:Inject target", 3)
            rawset(specification, alias, dependency)
        end
        return self
    end

    validateNonEmptyString(aliasOrMap, "ModuleKit.Module:Inject alias", 3)
    validateNonEmptyString(target, "ModuleKit.Module:Inject target", 3)
    rawset(specification, aliasOrMap, target)
    return self
end

---Initialize this module under the container's dependency policy.
---@param self ModuleKit.Module
---@return ModuleKit.Module self
local function moduleInitialize(self)
    return initializeWithPolicy(self)
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
    ensureNotShutdown(self, "SetDependencyPolicy")
    if policy ~= "automatic" and policy ~= "strict" then
        error('ModuleKit.Addon:SetDependencyPolicy policy must be "automatic" or "strict"', 3)
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
    inject = true,
    onInitialize = true,
    onEnable = true,
    onDisable = true,
}

---Apply one dense-array definition field by calling `method` per entry.
---@param module ModuleKit.Module
---@param definition ModuleKit.Definition
---@param key "dependsOn"|"optionalDependencies"|"before"|"after"
---@param method fun(module: ModuleKit.Module, targetName: string): ModuleKit.Module
local function applyDefinitionList(module, definition, key, method)
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
        method(module, rawget(values, index))
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
---@param module ModuleKit.Module
---@param definition ModuleKit.Definition|nil
local function applyDefinition(module, definition)
    if definition == nil then
        return
    end
    if type(definition) ~= "table" then
        error("ModuleKit.Addon:CreateModule definition must be a table when provided", 4)
    end

    local unknown = {}
    for key in next, definition do
        if type(key) ~= "string" or DEFINITION_FIELDS[key] ~= true then
            unknown[#unknown + 1] = tostring(key)
        end
    end
    if #unknown > 0 then
        table.sort(unknown)
        error('ModuleKit module definition contains unknown field "' .. unknown[1] .. '"', 4)
    end

    -- Apply in a fixed order so malformed definitions fail deterministically
    -- on every Lua implementation and every load order.
    applyDefinitionList(module, definition, "dependsOn", moduleDependsOn)
    applyDefinitionList(module, definition, "optionalDependencies", moduleOptionalDependency)
    applyDefinitionList(module, definition, "before", moduleBefore)
    applyDefinitionList(module, definition, "after", moduleAfter)

    local inject = rawget(definition, "inject")
    if inject ~= nil then
        moduleInject(module, inject)
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
    ensureNotShutdown(self, "CreateModule")
    validateModuleName(name, "CreateModule")

    local modules = rawget(self, "_modules")
    if rawget(modules, name) ~= nil or rawget(rawget(self, "_providers"), name) ~= nil then
        error('ModuleKit.Addon:CreateModule name "' .. name .. '" is already in use', 3)
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
    validateLateModuleOrdering(self, module)

    rawset(modules, name, module)
    order[#order + 1] = module

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
    validateModuleName(name, "GetModule")
    return rawget(rawget(self, "_modules"), name)
end

---Report whether the named module exists in this container.
---@param self ModuleKit.Addon
---@param name string
---@return boolean
local function addonHasModule(self, name)
    validateModuleName(name, "HasModule")
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
    return initializeAllInternal(self)
end

---Enable every module in the container, including ones explicitly disabled.
---@param self ModuleKit.Addon
---@return ModuleKit.Addon self
local function addonEnableAll(self)
    return enableAllInternal(self)
end

---Disable every enabled module without terminating the container.
---@param self ModuleKit.Addon
---@return ModuleKit.Addon self
local function addonDisableAll(self)
    return disableAllInternal(self, false)
end

---Register an addon-scoped constant. `nil` is rejected.
---@param self ModuleKit.Addon
---@param name string
---@param value any
---@return ModuleKit.Addon self
local function addonProvideValue(self, name, value)
    ensureNotShutdown(self, "ProvideValue")
    if value == nil then
        error("ModuleKit.Addon:ProvideValue value must not be nil", 3)
    end
    return registerProvider(self, name, { kind = "value", value = value }, "ProvideValue")
end

---@param factory any
---@param methodName string public method name, used in the argument error
local function validateFactory(factory, methodName)
    if type(factory) ~= "function" then
        error("ModuleKit.Addon:" .. methodName .. " factory must be a function", 4)
    end
end

---Register a factory resolved once per container.
---@param self ModuleKit.Addon
---@param name string
---@param factory fun(addon: ModuleKit.Addon): any
---@return ModuleKit.Addon self
local function addonProvideSingleton(self, name, factory)
    ensureNotShutdown(self, "ProvideSingleton")
    validateFactory(factory, "ProvideSingleton")
    return registerProvider(self, name, {
        kind = "singleton",
        factory = factory,
        resolved = false,
        value = nil,
    }, "ProvideSingleton")
end

---Register a factory resolved once per requesting module.
---@param self ModuleKit.Addon
---@param name string
---@param factory fun(addon: ModuleKit.Addon, module: ModuleKit.Module): any
---@return ModuleKit.Addon self
local function addonProvideModule(self, name, factory)
    ensureNotShutdown(self, "ProvideModule")
    validateFactory(factory, "ProvideModule")
    return registerProvider(self, name, {
        kind = "module",
        factory = factory,
        cache = {},
    }, "ProvideModule")
end

---Register a factory resolved on every resolution.
---@param self ModuleKit.Addon
---@param name string
---@param factory fun(addon: ModuleKit.Addon, module: ModuleKit.Module|nil): any
---@return ModuleKit.Addon self
local function addonProvideTransient(self, name, factory)
    ensureNotShutdown(self, "ProvideTransient")
    validateFactory(factory, "ProvideTransient")
    return registerProvider(self, name, {
        kind = "transient",
        factory = factory,
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
                3
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

---Call one whole-container pass through shared runtime dispatch.
---
---Going through shared state rather than a captured local is what lets a newer
---compatible revision upgrade containers an older copy created.
---@param name "initializeAll"|"enableAll"|"shutdown"
---@param addon ModuleKit.Addon
---@return ModuleKit.Addon addon
local function invokeDispatch(name, addon)
    local dispatch = rawget(state, "dispatch")
    local callback = type(dispatch) == "table" and rawget(dispatch, name) or nil
    if type(callback) ~= "function" then
        error("MoltenCodes ModuleKit runtime dispatch is corrupted or incomplete", 2)
    end
    return callback(addon)
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
    rawset(addon, "_subscriptions", {})
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
rawset(ModuleKit, "ForAddon", forAddon)

-- Lifecycle subscriptions installed by revision 1 closed over that revision's
-- local implementation functions. Revision 2 moves them behind shared-state
-- dispatch so existing addon containers observe future compatible bug fixes
-- without replacing container identity or requiring addon reloads.
local dispatch = rawget(state, "dispatch")
rawset(dispatch, "initializeAll", initializeAllInternal)
rawset(dispatch, "enableAll", enableAllInternal)
rawset(dispatch, "shutdown", function(addon)
    return disableAllInternal(addon, true)
end)

if rawget(state, "runtimeRevision") ~= IMPLEMENTATION_REVISION then
    migrateAddonSubscriptions()
    rawset(state, "runtimeRevision", IMPLEMENTATION_REVISION)
end

if not validatePublicSurface(ModuleKit) or not validateCurrentState(ModuleKit) then
    error("MoltenCodes ModuleKit package state is corrupted or incomplete", 2)
end

return ModuleKit
