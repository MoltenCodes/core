-- MoltenCodes ModuleKit
--
-- Addon-scoped module lifecycle, dependency graphs, and dependency injection.
-- ModuleKit is intentionally independent from WoW Frame APIs; lifecycle timing
-- is supplied by LifecycleKit and package identity by Registry.

local PACKAGE_NAME = "moduleKit"
local API_GENERATION = 1
local IMPLEMENTATION_REVISION = 2
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

local function topologicalSort(order, adjacency, indegree)
    local ready = {}
    for index = 1, #order do
        local module = order[index]
        if indegree[module] == 0 then
            ready[#ready + 1] = module
        end
    end

    table.sort(ready, function(left, right)
        return moduleSortKey(left) < moduleSortKey(right)
    end)

    local result = {}
    while #ready > 0 do
        local module = table.remove(ready, 1)
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
                ready[#ready + 1] = target
                table.sort(ready, function(left, right)
                    return moduleSortKey(left) < moduleSortKey(right)
                end)
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

local function initializeAllInternal(addon)
    ensureNotShutdown(addon, "InitializeAll")
    local order = buildGraph(addon)
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

    raiseCaptured(firstError)
    return addon
end

local function enableAllInternal(addon)
    ensureNotShutdown(addon, "EnableAll")
    local order = buildGraph(addon)
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

    raiseCaptured(firstError)
    return addon
end

local function disableAllInternal(addon, shutdown)
    local order
    local firstError
    local graphOk, graphResult = pcall(buildGraph, addon)

    if graphOk then
        order = graphResult
    elseif shutdown then
        -- Shutdown is terminal cleanup. A malformed inactive definition must
        -- not prevent already-enabled modules from releasing resources. Keep
        -- the graph error for diagnostics, but continue in a safe order based
        -- on the hard-dependency edges of enabled modules only.
        firstError = { value = graphResult }
        order = buildEnabledHardOrder(addon)
    else
        error(graphResult, 0)
    end

    if shutdown then
        rawset(addon, "_shutdown", true)
    end

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

    raiseCaptured(firstError)
    return addon
end

-- Module public API ---------------------------------------------------------

local function moduleGetName(self)
    return rawget(self, "_name")
end

local function moduleGetAddon(self)
    return rawget(self, "_addon")
end

local function moduleGetState(self)
    return rawget(self, "_state")
end

local function moduleIsInitialized(self)
    return rawget(self, "_state") ~= "created"
end

local function moduleIsEnabled(self)
    return rawget(self, "_state") == "enabled"
end

local function moduleGetLastError(self)
    return rawget(self, "_lastError")
end

local function moduleHasLastError(self)
    return rawget(self, "_hasLastError") == true
end

local function moduleGetBlockedBy(self)
    return rawget(self, "_blockedBy")
end

local function moduleGetInjections(self)
    local injections = rawget(self, "_injections")
    if injections == nil then
        return {}
    end
    return shallowCopy(injections)
end

local function moduleDependsOn(self, moduleName)
    return addNameConstraint(self, "_hardDependencies", moduleName, "DependsOn")
end

local function moduleOptionalDependency(self, moduleName)
    return addNameConstraint(self, "_optionalDependencies", moduleName, "OptionalDependency")
end

local function moduleBefore(self, moduleName)
    return addNameConstraint(self, "_before", moduleName, "Before")
end

local function moduleAfter(self, moduleName)
    return addNameConstraint(self, "_after", moduleName, "After")
end

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

local function moduleInitialize(self)
    return initializeWithPolicy(self)
end

local function moduleEnable(self)
    return enableWithPolicy(self)
end

local function moduleDisable(self)
    return disableWithPolicy(self)
end

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

local function moduleResolve(self, providerName)
    return resolveProvider(rawget(self, "_addon"), providerName, self)
end

-- Addon public API ----------------------------------------------------------

local function addonGetAddonName(self)
    return rawget(self, "_name")
end

local function addonGetDependencyPolicy(self)
    return rawget(self, "_dependencyPolicy")
end

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
    if definition ~= nil then
        local lifecycle = rawget(self, "_lifecycle")
        if lifecycle:IsLoaded() then
            initializeWithPolicy(module)
        end
        if lifecycle:IsReady() then
            enableWithPolicy(module)
        end
    end

    return module
end

local function addonGetModule(self, name)
    validateModuleName(name, "GetModule")
    return rawget(rawget(self, "_modules"), name)
end

local function addonHasModule(self, name)
    validateModuleName(name, "HasModule")
    return rawget(rawget(self, "_modules"), name) ~= nil
end

local function addonGetModules(self)
    local modules = {}
    local order = rawget(self, "_moduleOrder")
    for index = 1, #order do
        modules[index] = order[index]
    end
    return modules
end

local function addonGetActivationOrder(self)
    local order = buildGraph(self)
    local names = {}
    for index = 1, #order do
        names[index] = rawget(order[index], "_name")
    end
    return names
end

local function addonValidateGraph(self)
    buildGraph(self)
    return true
end

local function addonInitializeAll(self)
    return initializeAllInternal(self)
end

local function addonEnableAll(self)
    return enableAllInternal(self)
end

local function addonDisableAll(self)
    return disableAllInternal(self, false)
end

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

local function addonProvideModule(self, name, factory)
    ensureNotShutdown(self, "ProvideModule")
    validateFactory(factory, "ProvideModule")
    return registerProvider(self, name, {
        kind = "module",
        factory = factory,
        cache = {},
    }, "ProvideModule")
end

local function addonProvideTransient(self, name, factory)
    ensureNotShutdown(self, "ProvideTransient")
    validateFactory(factory, "ProvideTransient")
    return registerProvider(self, name, {
        kind = "transient",
        factory = factory,
    }, "ProvideTransient")
end

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

local function invokeDispatch(name, addon)
    local dispatch = rawget(state, "dispatch")
    local callback = type(dispatch) == "table" and rawget(dispatch, name) or nil
    if type(callback) ~= "function" then
        error("MoltenCodes ModuleKit runtime dispatch is corrupted or incomplete", 2)
    end
    return callback(addon)
end

local function disconnectAddonSubscriptions(addon)
    local subscriptions = rawget(addon, "_subscriptions")
    if type(subscriptions) ~= "table" then
        rawset(addon, "_subscriptions", {})
        return
    end

    local keys = { "loaded", "ready", "shutdown" }
    for index = 1, #keys do
        local subscription = rawget(subscriptions, keys[index])
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

local function installAddonSubscriptions(addon)
    local lifecycle = rawget(addon, "_lifecycle")
    if
        type(lifecycle) ~= "table"
        or type(lifecycle.IsShutdown) ~= "function"
        or type(lifecycle.OnLoaded) ~= "function"
        or type(lifecycle.OnReady) ~= "function"
        or type(lifecycle.OnShutdown) ~= "function"
    then
        error("MoltenCodes ModuleKit addon lifecycle state is corrupted", 2)
    end

    local subscriptions = {}
    rawset(addon, "_subscriptions", subscriptions)

    if rawget(addon, "_shutdown") == true then
        return
    end

    subscriptions.loaded = lifecycle:OnLoaded(function()
        return invokeDispatch("initializeAll", addon)
    end)
    subscriptions.ready = lifecycle:OnReady(function()
        return invokeDispatch("enableAll", addon)
    end)
    subscriptions.shutdown = lifecycle:OnShutdown(function()
        return invokeDispatch("shutdown", addon)
    end)
end

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
    }, ADDON_METATABLE)

    local addons = rawget(state, "addons")
    rawset(addons, addonName, addon)

    if not rawget(addon, "_shutdown") then
        installAddonSubscriptions(addon)
    end

    return addon
end

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
                installAddonSubscriptions(addon)
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
