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
--   Lifecycle operations . Single-module transitions, dependency policies,
--                          whole-container passes and deferred catch-up.
--   Module public API ..... Methods installed on the shared Module prototype.
--   Addon public API ...... Methods installed on the shared Addon prototype.
--   Addon creation ........ Container identity and LifecycleKit subscriptions.
--   Commit ................ Publishing the public surface and runtime dispatch.
--
-- `docs/INTERNALS.md` explains the graph algorithm, the failure model, and the
-- lifecycle replay hazard that the dispatched-phase set guards against.

local PACKAGE_NAME = "moduleKit"
local API_GENERATION = 1
local IMPLEMENTATION_REVISION = 3
local REQUIRED_REGISTRY_API = 2
local REQUIRED_LIFECYCLE_API = 1
local STATE_SCHEMA = 1

-- Dependencies --------------------------------------------------------------

-- The shared MoltenCodes namespace is the one documented global handoff point between independently embedded copies.
-- selene: allow(global_usage)
local namespace = rawget(_G, "MoltenCodes")
if type(namespace) ~= "table" then
    error("MoltenCodes ModuleKit requires Registry API 2 to be loaded first", 2)
end

local Registry = rawget(namespace, "Registry")
if type(Registry) ~= "table" or rawget(Registry, "API") ~= REQUIRED_REGISTRY_API then
    error("MoltenCodes ModuleKit requires Registry API 2 to be loaded first", 2)
end

local registerPackage = rawget(Registry, "Register")
local getPackage = rawget(Registry, "Get")
if type(registerPackage) ~= "function" or type(getPackage) ~= "function" then
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

local function validateStateBase(currentState)
    return type(currentState) == "table"
        and rawget(currentState, "schema") == STATE_SCHEMA
        and type(rawget(currentState, "addons")) == "table"
end

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

local existing, existingRevision = getPackage(Registry, PACKAGE_NAME, API_GENERATION)
local existingFacadeRevision
if existing ~= nil then
    if type(existing) ~= "table" or rawget(existing, "API") ~= API_GENERATION then
        error("MoltenCodes ModuleKit package state is corrupted or incomplete", 2)
    end
    existingFacadeRevision = rawget(existing, "REVISION")
    if type(existingFacadeRevision) ~= "number" or existingFacadeRevision > existingRevision then
        error("MoltenCodes ModuleKit package state is corrupted or incomplete", 2)
    end

    -- A future compatible revision wins. Older embedded copies must not
    -- overwrite or reinterpret its state.
    if existingRevision > IMPLEMENTATION_REVISION then
        if existingFacadeRevision ~= existingRevision or not validatePublicSurface(existing) then
            error("MoltenCodes ModuleKit package state is corrupted or incomplete", 2)
        end
        return existing
    end
end

local ModuleKit, previousRevision =
    registerPackage(Registry, PACKAGE_NAME, API_GENERATION, IMPLEMENTATION_REVISION)

if ModuleKit == nil then
    -- Registry may already have accepted this revision during an earlier
    -- bootstrap that failed before ModuleKit finished committing its runtime
    -- state. Resume that same revision instead of leaving the package stuck.
    if existing == nil or existingRevision ~= IMPLEMENTATION_REVISION then
        return existing
    end

    local existingState = rawget(existing, "_state")
    local runtimeRevision = type(existingState) == "table"
            and rawget(existingState, "runtimeRevision")
        or nil
    if
        existingFacadeRevision == IMPLEMENTATION_REVISION
        and runtimeRevision == IMPLEMENTATION_REVISION
        and validatePublicSurface(existing)
        and validateCurrentState(existing)
    then
        return existing
    end

    if not validateStateBase(existingState) then
        error("MoltenCodes ModuleKit package state is corrupted or incomplete", 2)
    end

    ModuleKit = existing
    previousRevision = runtimeRevision or existingFacadeRevision or 0
end

--- Stable state a module moves through.
--- @alias ModuleKit.ModuleState
--- | "created"      # defined but not initialized
--- | "initialized"  # `OnInitialize` completed
--- | "enabled"      # `OnEnable` completed
--- | "disabled"     # `OnDisable` completed

--- How targeted operations treat unmet hard dependencies.
--- @alias ModuleKit.DependencyPolicy "automatic"|"strict"

--- Method prototype shared by every addon container.
---
--- Registry keeps this table's identity stable across compatible embedded
--- revisions, so containers created by an older copy observe newer methods.
--- @class ModuleKit.Addon
local Addon = rawget(ModuleKit, "Addon")

--- Method prototype shared by every module.
--- @class ModuleKit.Module
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
end

local ADDON_METATABLE = { __index = Addon }
local MODULE_METATABLE = { __index = Module }

-- Validation helpers --------------------------------------------------------

local function validateNonEmptyString(value, label, level)
    if type(value) ~= "string" or value == "" then
        error(label .. " must be a non-empty string", level or 3)
    end
end

local function validateModuleName(value, methodName)
    validateNonEmptyString(value, "ModuleKit.Module:" .. methodName .. " moduleName", 4)
end

local function validateProviderName(value, methodName)
    validateNonEmptyString(value, "ModuleKit.Addon:" .. methodName .. " providerName", 4)
end

local function shallowCopy(source)
    local copy = {}
    for key, value in pairs(source) do
        copy[key] = value
    end
    return copy
end

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

local function ensureNotShutdown(addon, methodName)
    if rawget(addon, "_shutdown") == true then
        error("ModuleKit.Addon:" .. methodName .. " cannot run after addon shutdown", 3)
    end
end

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

local function moduleSortKey(module)
    return rawget(module, "_order")
end

local function sortedNameKeys(names)
    local result = {}
    for name in pairs(names) do
        result[#result + 1] = name
    end
    table.sort(result)
    return result
end

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

--- Insert `module` into the ready set, keeping it sorted by creation order.
---
--- The set is stored in *descending* creation order so the next module to emit
--- is always its last element: removing the last element is O(1), while
--- removing the first would shift the whole array on every emission.
---
--- Creation order is unique inside one container, so the comparison is a total
--- order and the position found here is the only valid one. Together with the
--- descending layout this keeps the emitted order identical to a full re-sort
--- after every insertion, without paying for one.
--- @param ready table[] ready set, sorted by descending creation order
--- @param module table
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

--- Order `order` so every module follows the modules it has edges from.
---
--- Kahn's algorithm, with creation order as the deterministic tie-break among
--- modules that are simultaneously ready.
--- @param order table[] every module in the graph, in creation order
--- @param adjacency table<table, table<table, boolean>> predecessor → successors
--- @param indegree table<table, integer> remaining unsatisfied predecessors
--- @return table[]|nil order `nil` when the graph contains a cycle
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

local function resolutionRecordMatches(record, name, kind, requestingModule)
    if type(record) ~= "table" or rawget(record, "name") ~= name then
        return false
    end
    if kind == "module" then
        return rawget(record, "requestingModule") == requestingModule
    end
    return true
end

local function resolutionLabel(name, requestingModule)
    if requestingModule ~= nil then
        return name .. "[" .. tostring(rawget(requestingModule, "_name")) .. "]"
    end
    return name
end

local function providerConflict(addon, name)
    return rawget(rawget(addon, "_modules"), name) ~= nil
        or rawget(rawget(addon, "_providers"), name) ~= nil
end

local function registerProvider(addon, name, provider, methodName)
    validateProviderName(name, methodName)
    if providerConflict(addon, name) then
        error("ModuleKit.Addon:" .. methodName .. ' name "' .. name .. '" is already in use', 3)
    end
    rawset(rawget(addon, "_providers"), name, provider)
    return addon
end

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

-- Lifecycle operations ------------------------------------------------------

local function recordFailure(module, value, blockedBy, hasError)
    rawset(module, "_lastError", value)
    rawset(module, "_hasLastError", hasError == true)
    rawset(module, "_blockedBy", blockedBy)
end

local function clearFailure(module)
    rawset(module, "_lastError", nil)
    rawset(module, "_hasLastError", false)
    rawset(module, "_blockedBy", nil)
end

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

    local ok, value = invokeHook(module, "OnEnable")
    if not ok then
        recordFailure(module, value, nil, true)
        error(value, 0)
    end

    rawset(module, "_state", "enabled")
    clearFailure(module)
    return module
end

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
    return module
end

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
            enableWithPolicy(dependencies[index], visiting)
        end
        visiting[module] = nil
    else
        for index = 1, #dependencies do
            local dependency = dependencies[index]
            if rawget(dependency, "_state") ~= "enabled" then
                local name = rawget(dependency, "_name")
                recordFailure(module, nil, name, false)
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
            disableWithPolicy(dependents[index])
        end
    end

    return disableOne(module)
end

local function captureFirstError(current, ok, value)
    if current ~= nil or ok then
        return current
    end
    return { value = value }
end

local function raiseCaptured(record)
    if record ~= nil then
        error(rawget(record, "value"), 0)
    end
end

-- Whole-container passes ----------------------------------------------------

--- Catch one module up to the LifecycleKit phases its container has reached.
--- @param addon table
--- @param module table
local function catchUpModule(addon, module)
    local lifecycle = rawget(addon, "_lifecycle")
    if lifecycle:IsLoaded() then
        initializeWithPolicy(module)
    end
    if lifecycle:IsReady() then
        enableWithPolicy(module)
    end
end

--- Catch a module up now, or queue it while a whole-container pass is running.
---
--- A hook can create a module while `InitializeAll` / `EnableAll` / `DisableAll`
--- is walking the graph. Catching it up there and then would happen outside the
--- running pass's blocking set, so a module could be activated even though a
--- hard dependency had already failed in the same pass. The module is queued
--- instead and caught up once the outermost pass has finished.
--- @param addon table
--- @param module table
local function scheduleCatchUp(addon, module)
    if rawget(addon, "_passDepth") > 0 then
        local pending = rawget(addon, "_pendingCatchUp")
        pending[#pending + 1] = module
        return
    end
    catchUpModule(addon, module)
end

--- Catch up every module queued while the pass that just finished was running.
---
--- Catching one module up can create another. Outside a pass `scheduleCatchUp`
--- handles those immediately, and a nested pass that ends mid-flush leaves its
--- modules on the queue for this loop to pick up, so one flush is enough.
--- @param addon table
--- @param firstError table|nil error record captured so far
--- @return table|nil firstError
local function flushPendingCatchUp(addon, firstError)
    if rawget(addon, "_flushingCatchUp") == true then
        return firstError
    end
    rawset(addon, "_flushingCatchUp", true)

    local pending = rawget(addon, "_pendingCatchUp")
    while #pending > 0 do
        local module = table.remove(pending, 1)
        local ok, value = pcall(catchUpModule, addon, module)
        firstError = captureFirstError(firstError, ok, value)
    end

    rawset(addon, "_flushingCatchUp", false)
    return firstError
end

--- Run one whole-container pass with re-entrancy bookkeeping.
---
--- The pass body reports its first captured error by returning it rather than
--- raising, so the depth counter is always restored and the deferred catch-up
--- queue is always flushed, whichever way the pass ends.
--- @param addon table
--- @param pass fun(order: table[], shutdown: boolean|nil): table|nil
--- @param order table[] modules in the order the pass must visit them
--- @param shutdown boolean|nil terminal-cleanup flag, for the disable pass
--- @param seedError table|nil error captured before the pass could start
--- @return table addon
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

--- Initialize every module in `order`.
---
--- Independent modules continue after a failure. A module whose hard dependency
--- failed, or never left `created`, is recorded as blocked instead of attempted.
--- @return table|nil firstError
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

--- Initialize the whole container in deterministic graph order.
--- @param addon table
--- @return table addon
local function initializeAllInternal(addon)
    ensureNotShutdown(addon, "InitializeAll")
    local order = buildGraph(addon)
    return runContainerPass(addon, runInitializeAllPass, order)
end

--- Enable every module in `order`, initializing the ones still in `created`.
--- @return table|nil firstError
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

--- Enable the whole container in deterministic graph order.
---
--- This is a target state, not a delta: a module that was explicitly disabled
--- earlier is enabled again. See `docs/API.md` for why.
--- @param addon table
--- @return table addon
local function enableAllInternal(addon)
    ensureNotShutdown(addon, "EnableAll")
    local order = buildGraph(addon)
    return runContainerPass(addon, runEnableAllPass, order)
end

--- Disable every enabled module in `order`, walking it in reverse.
--- @param shutdown boolean|nil terminal cleanup, which ignores dependent failures
--- @return table|nil firstError
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
                end
            end
        end
    end

    return firstError
end

--- Disable the whole container in reverse graph order.
--- @param addon table
--- @param shutdown boolean `true` for terminal LifecycleKit cleanup
--- @return table addon
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
    end

    return runContainerPass(addon, runDisableAllPass, order, shutdown, seedError)
end

-- Module public API ---------------------------------------------------------

--- Return this module's name.
--- @param self ModuleKit.Module
--- @return string
local function moduleGetName(self)
    return rawget(self, "_name")
end

--- Return the addon container that owns this module.
--- @param self ModuleKit.Module
--- @return ModuleKit.Addon
local function moduleGetAddon(self)
    return rawget(self, "_addon")
end

--- Return the module's current stable state.
--- @param self ModuleKit.Module
--- @return ModuleKit.ModuleState
local function moduleGetState(self)
    return rawget(self, "_state")
end

--- Report whether initialization has completed at least once.
--- @param self ModuleKit.Module
--- @return boolean
local function moduleIsInitialized(self)
    return rawget(self, "_state") ~= "created"
end

--- Report whether the module is currently enabled.
--- @param self ModuleKit.Module
--- @return boolean
local function moduleIsEnabled(self)
    return rawget(self, "_state") == "enabled"
end

--- Return the last error object, which may itself legitimately be `nil`.
--- Pair with `HasLastError` to tell "no error" from "an error object of `nil`".
--- @param self ModuleKit.Module
--- @return any
local function moduleGetLastError(self)
    return rawget(self, "_lastError")
end

--- Report whether the last operation recorded an actual error.
--- @param self ModuleKit.Module
--- @return boolean
local function moduleHasLastError(self)
    return rawget(self, "_hasLastError") == true
end

--- Return the dependency or dependent name that blocked the last operation.
--- @param self ModuleKit.Module
--- @return string|nil
local function moduleGetBlockedBy(self)
    return rawget(self, "_blockedBy")
end

--- Return a shallow-copy snapshot of the resolved injection table.
--- @param self ModuleKit.Module
--- @return table<string, any>
local function moduleGetInjections(self)
    local injections = rawget(self, "_injections")
    if injections == nil then
        return {}
    end
    return shallowCopy(injections)
end

--- Require `moduleName` to be active before this module, and order against it.
--- @param self ModuleKit.Module
--- @param moduleName string
--- @return ModuleKit.Module self
local function moduleDependsOn(self, moduleName)
    return addNameConstraint(self, "_hardDependencies", moduleName, "DependsOn")
end

--- Order after `moduleName` when it exists, without requiring it.
--- @param self ModuleKit.Module
--- @param moduleName string
--- @return ModuleKit.Module self
local function moduleOptionalDependency(self, moduleName)
    return addNameConstraint(self, "_optionalDependencies", moduleName, "OptionalDependency")
end

--- Order this module before `moduleName`, without requiring it.
--- @param self ModuleKit.Module
--- @param moduleName string
--- @return ModuleKit.Module self
local function moduleBefore(self, moduleName)
    return addNameConstraint(self, "_before", moduleName, "Before")
end

--- Order this module after `moduleName`, without requiring it.
--- @param self ModuleKit.Module
--- @param moduleName string
--- @return ModuleKit.Module self
local function moduleAfter(self, moduleName)
    return addNameConstraint(self, "_after", moduleName, "After")
end

--- Declare injection aliases.
---
--- Targets are provider or module **names**, never the objects themselves: the
--- container resolves a name at initialization time, so a module can inject
--- something that does not exist yet when the declaration is written.
--- @param self ModuleKit.Module
--- @param aliasOrMap string|table<string, string> one alias, or an alias-to-name map
--- @param target string|nil target name, when a single alias was given
--- @return ModuleKit.Module self
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

--- Initialize this module under the container's dependency policy.
--- @param self ModuleKit.Module
--- @return ModuleKit.Module self
local function moduleInitialize(self)
    return initializeWithPolicy(self)
end

--- Enable this module under the container's dependency policy.
--- @param self ModuleKit.Module
--- @return ModuleKit.Module self
local function moduleEnable(self)
    return enableWithPolicy(self)
end

--- Disable this module under the container's dependency policy.
--- @param self ModuleKit.Module
--- @return ModuleKit.Module self
local function moduleDisable(self)
    return disableWithPolicy(self)
end

--- Catch this module up to the LifecycleKit phases its container has reached.
---
--- This is an explicit request, so it runs immediately even when called from a
--- hook during a whole-container pass. Definition-table catch-up is deferred
--- instead; see `scheduleCatchUp`.
--- @param self ModuleKit.Module
--- @return ModuleKit.Module self
local function moduleActivate(self)
    local addon = rawget(self, "_addon")
    local lifecycle = rawget(addon, "_lifecycle")

    if lifecycle:IsLoaded() then
        initializeWithPolicy(self)
    end
    if lifecycle:IsReady() then
        enableWithPolicy(self)
    end
    return self
end

--- Resolve an injectable with this module as the scope context.
--- @param self ModuleKit.Module
--- @param providerName string
--- @return any
local function moduleResolve(self, providerName)
    return resolveProvider(rawget(self, "_addon"), providerName, self)
end

-- Addon public API ----------------------------------------------------------

--- Return the addon name this container was created for.
--- @param self ModuleKit.Addon
--- @return string
local function addonGetAddonName(self)
    return rawget(self, "_name")
end

--- Return the container's dependency policy.
--- @param self ModuleKit.Addon
--- @return ModuleKit.DependencyPolicy
local function addonGetDependencyPolicy(self)
    return rawget(self, "_dependencyPolicy")
end

--- Change the container's dependency policy.
--- @param self ModuleKit.Addon
--- @param policy ModuleKit.DependencyPolicy
--- @return ModuleKit.DependencyPolicy previous
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

--- Create a uniquely named module in this container.
--- @param self ModuleKit.Addon
--- @param name string
--- @param definition table|nil atomic definition table; see `docs/API.md`
--- @return ModuleKit.Module
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
    }, MODULE_METATABLE)

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

--- Return the named module, or `nil`.
--- @param self ModuleKit.Addon
--- @param name string
--- @return ModuleKit.Module|nil
local function addonGetModule(self, name)
    validateModuleName(name, "GetModule")
    return rawget(rawget(self, "_modules"), name)
end

--- Report whether the named module exists in this container.
--- @param self ModuleKit.Addon
--- @param name string
--- @return boolean
local function addonHasModule(self, name)
    validateModuleName(name, "HasModule")
    return rawget(rawget(self, "_modules"), name) ~= nil
end

--- Return a new array snapshot of every module, in creation order.
--- @param self ModuleKit.Addon
--- @return ModuleKit.Module[]
local function addonGetModules(self)
    local modules = {}
    local order = rawget(self, "_moduleOrder")
    for index = 1, #order do
        modules[index] = order[index]
    end
    return modules
end

--- Return module names in deterministic full-graph topological order.
--- @param self ModuleKit.Addon
--- @return string[]
local function addonGetActivationOrder(self)
    local order = buildGraph(self)
    local names = {}
    for index = 1, #order do
        names[index] = rawget(order[index], "_name")
    end
    return names
end

--- Validate the complete graph, raising a diagnostic on the first problem.
--- @param self ModuleKit.Addon
--- @return boolean `true` on success
local function addonValidateGraph(self)
    buildGraph(self)
    return true
end

--- Initialize every module in the container.
--- @param self ModuleKit.Addon
--- @return ModuleKit.Addon self
local function addonInitializeAll(self)
    return initializeAllInternal(self)
end

--- Enable every module in the container, including ones explicitly disabled.
--- @param self ModuleKit.Addon
--- @return ModuleKit.Addon self
local function addonEnableAll(self)
    return enableAllInternal(self)
end

--- Disable every enabled module without terminating the container.
--- @param self ModuleKit.Addon
--- @return ModuleKit.Addon self
local function addonDisableAll(self)
    return disableAllInternal(self, false)
end

--- Register an addon-scoped constant. `nil` is rejected.
--- @param self ModuleKit.Addon
--- @param name string
--- @param value any
--- @return ModuleKit.Addon self
local function addonProvideValue(self, name, value)
    ensureNotShutdown(self, "ProvideValue")
    if value == nil then
        error("ModuleKit.Addon:ProvideValue value must not be nil", 3)
    end
    return registerProvider(self, name, { kind = "value", value = value }, "ProvideValue")
end

local function validateFactory(factory, methodName)
    if type(factory) ~= "function" then
        error("ModuleKit.Addon:" .. methodName .. " factory must be a function", 4)
    end
end

--- Register a factory resolved once per container.
--- @param self ModuleKit.Addon
--- @param name string
--- @param factory fun(addon: ModuleKit.Addon): any
--- @return ModuleKit.Addon self
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

--- Register a factory resolved once per requesting module.
--- @param self ModuleKit.Addon
--- @param name string
--- @param factory fun(addon: ModuleKit.Addon, module: ModuleKit.Module): any
--- @return ModuleKit.Addon self
local function addonProvideModule(self, name, factory)
    ensureNotShutdown(self, "ProvideModule")
    validateFactory(factory, "ProvideModule")
    return registerProvider(self, name, {
        kind = "module",
        factory = factory,
        cache = {},
    }, "ProvideModule")
end

--- Register a factory resolved on every resolution.
--- @param self ModuleKit.Addon
--- @param name string
--- @param factory fun(addon: ModuleKit.Addon, module: ModuleKit.Module|nil): any
--- @return ModuleKit.Addon self
local function addonProvideTransient(self, name, factory)
    ensureNotShutdown(self, "ProvideTransient")
    validateFactory(factory, "ProvideTransient")
    return registerProvider(self, name, {
        kind = "transient",
        factory = factory,
    }, "ProvideTransient")
end

--- Resolve an injectable, optionally with module scope context.
--- @param self ModuleKit.Addon
--- @param name string
--- @param requestingModule ModuleKit.Module|nil must be owned by this container
--- @return any
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

--- The LifecycleKit phases a container subscribes to, in delivery order.
local LIFECYCLE_PHASES = { "loaded", "ready", "shutdown" }

--- LifecycleKit subscription method per phase.
local PHASE_SUBSCRIBE = {
    loaded = "OnLoaded",
    ready = "OnReady",
    shutdown = "OnShutdown",
}

--- LifecycleKit query that reports whether a phase has already been reached.
local PHASE_REACHED_QUERY = {
    loaded = "IsLoaded",
    ready = "IsReady",
    shutdown = "IsShutdown",
}

--- Shared runtime dispatch entry point per phase.
local PHASE_DISPATCH = {
    loaded = "initializeAll",
    ready = "enableAll",
    shutdown = "shutdown",
}

local function invokeDispatch(name, addon)
    local dispatch = rawget(state, "dispatch")
    local callback = type(dispatch) == "table" and rawget(dispatch, name) or nil
    if type(callback) ~= "function" then
        error("MoltenCodes ModuleKit runtime dispatch is corrupted or incomplete", 2)
    end
    return callback(addon)
end

--- Report whether LifecycleKit has already reached `phase` for `lifecycle`.
--- @param lifecycle table
--- @param phase "loaded"|"ready"|"shutdown"
--- @return boolean
local function isPhaseReached(lifecycle, phase)
    local query = lifecycle[PHASE_REACHED_QUERY[phase]]
    return query(lifecycle) == true
end

--- Install the per-container runtime fields this implementation revision owns.
---
--- A container created by an earlier compatible revision carries neither the
--- dispatched-phase set nor the whole-container pass bookkeeping, so an
--- in-place upgrade adds them before anything reads them.
---
--- The dispatched set is rebuilt from LifecycleKit: every revision subscribed
--- to all three phases when it created a container, and LifecycleKit replays a
--- phase it has already reached to every new subscriber. For a carried-over
--- container, "phase reached" and "phase already dispatched into this
--- container" therefore mean the same thing.
--- @param addon table
--- @param lifecycle table
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
end

--- Drop every LifecycleKit subscription this container currently holds.
--- @param addon table
local function disconnectAddonSubscriptions(addon)
    local subscriptions = rawget(addon, "_subscriptions")
    if type(subscriptions) ~= "table" then
        rawset(addon, "_subscriptions", {})
        return
    end

    for index = 1, #LIFECYCLE_PHASES do
        local subscription = rawget(subscriptions, LIFECYCLE_PHASES[index])
        if subscription ~= nil then
            local disconnect = type(subscription) == "table" and subscription.Disconnect or nil
            if type(disconnect) ~= "function" then
                error("MoltenCodes ModuleKit lifecycle subscription state is corrupted", 2)
            end
            disconnect(subscription)
        end
    end
    rawset(addon, "_subscriptions", {})
end

--- Subscribe the container to the LifecycleKit phases it has not received yet.
---
--- LifecycleKit replays a phase it has already reached to every new subscriber.
--- That is exactly what a freshly created container wants, and exactly what an
--- in-place upgrade must avoid: re-subscribing there would run module hooks out
--- of package bootstrap, and the replayed `ready` phase would call `EnableAll`,
--- silently re-enabling a module the addon had deliberately disabled.
---
--- The dispatched-phase set is the guard. During an upgrade the lifecycle is
--- also probed directly, so no already-reached phase can be subscribed to even
--- if the set were wrong, and a module hook can therefore never run out of
--- package bootstrap.
--- @param addon table
--- @param duringUpgrade boolean|nil `true` while migrating a carried-over container
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

    local subscriptions = {}
    rawset(addon, "_subscriptions", subscriptions)

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
                subscriptions[phase] = subscribe(lifecycle, function()
                    -- Record the phase before dispatching. It has happened even
                    -- if the dispatch raises, and a later in-place upgrade must
                    -- not run it a second time.
                    rawset(rawget(addon, "_dispatched"), phase, true)
                    return invokeDispatch(dispatchName, addon)
                end)
            end
        end
    end
end

--- Create the container for `addonName` and bind it to its lifecycle.
--- @param addonName string
--- @return ModuleKit.Addon
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

--- Return the stable container for `addonName`, creating it on demand.
--- @param addonName string addon folder name, as LifecycleKit matches it
--- @return ModuleKit.Addon
local function forAddon(_, addonName)
    validateNonEmptyString(addonName, "ModuleKit:ForAddon addonName", 3)

    local addons = rawget(state, "addons")
    local addon = rawget(addons, addonName)
    if addon ~= nil then
        return addon
    end
    return createAddon(addonName)
end

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
