-- MoltenCodes ModuleKit part Injection
--
-- Dependency injection inside one addon container (docs/API.md, "Dependency
-- injection"): the four provider kinds (`ProvideValue`, `ProvideSingleton`,
-- `ProvideModule`, `ProvideTransient`), `Resolve` on the container and on a
-- module, `Inject` and the `inject` definition field, and the resolution of a
-- module's injections when it initializes.
--
-- The part needs ModuleKit's core loaded first (docs/decisions/
-- 0001-kit-core-and-parts.md). It writes its members onto the core's shared
-- `Addon` and `Module` prototypes, replacing the stubs the core installs, and
-- fills two entries of the core's `state.dispatch`: `resolveForHook`, which
-- the core calls when a module initializes, and `addInjections`, which it
-- calls for a definition's `inject` field. It calls the core only through
-- `state.helpers`, read at call time, so a core upgraded after this part
-- loaded serves it. Providers and the resolution stack live in the container
-- (`_providers`, `_resolutionStack`), created on first use, so a higher
-- revision of this part takes them over in place.
--
-- A provider's `implements` option is the Implements part's: this part
-- compiles and checks it through the core's dispatch entries that part fills,
-- and refuses the option at the caller's line while that part is not loaded.
--
-- Contents
-- --------
--   Constants ........ identity
--   Dependencies ..... ModuleKit's core and its state
--   Providers ........ options, registration, resolution, cycles
--   Injections ....... aliases and their resolution at initialization
--   Public methods ... the Addon and Module members
--   Commit ........... members, dispatch entries and the part's revision

-- Constants ------------------------------------------------------------------

local PART_NAME = "Injection"
local PART_REVISION = 1
local REQUIRED_REGISTRY_API = 2
local CORE_PACKAGE, CORE_API = "moduleKit", 1
-- The core interface this part reads (`state.helpers`, `state.dispatch`).
-- ModuleKit's core publishes the number.
local REQUIRED_PART_INTERFACE = 1

-- Dependencies ---------------------------------------------------------------

-- The shared MoltenCodes namespace is the one documented global handoff point between independently embedded copies.
-- selene: allow(global_usage)
local namespace = rawget(_G, "MoltenCodes")
local generations = type(namespace) == "table" and rawget(namespace, "Registries") or nil
local Registry = type(generations) == "table" and rawget(generations, REQUIRED_REGISTRY_API) or nil
local ModuleKit = nil
if type(Registry) == "table" and type(rawget(Registry, "Get")) == "function" then
  ModuleKit = Registry:Get(CORE_PACKAGE, CORE_API)
end
local state = type(ModuleKit) == "table" and rawget(ModuleKit, "_state") or nil
local partInterface = type(state) == "table" and rawget(state, "partInterface") or nil
if
  type(state) ~= "table"
  or type(partInterface) ~= "number"
  or partInterface < REQUIRED_PART_INTERFACE
  or type(rawget(state, "parts")) ~= "table"
  or type(rawget(state, "helpers")) ~= "table"
  or type(rawget(state, "dispatch")) ~= "table"
then
  error("MoltenCodes ModuleKit part Injection requires ModuleKit API 1 to be loaded first", 2)
end

---@cast ModuleKit table

local installed = state.parts[PART_NAME]
if
  type(installed) == "table"
  and type(installed.revision) == "number"
  and installed.revision >= PART_REVISION
then
  -- An equal or newer revision of this part already serves every addon.
  return ModuleKit
end

-- Read at call time, never copied: an upgraded core's helpers serve this part.
local helpers = state.helpers
local dispatch = state.dispatch
local Addon = rawget(ModuleKit, "Addon")
local Module = rawget(ModuleKit, "Module")

-- Providers ------------------------------------------------------------------

---Whether a resolution-stack entry names the resolution being attempted.
---@param record any
---@param name string
---@param kind "value"|"singleton"|"module"|"transient"
---@param requestingModule ModuleKit.Module|nil
---@return boolean
local function resolutionRecordMatches(record, name, kind, requestingModule)
  if type(record) ~= "table" or record.name ~= name then
    return false
  end
  if kind == "module" then
    return record.requestingModule == requestingModule
  end
  return true
end

---Render one resolution for the cycle diagnostic.
---@param name string
---@param requestingModule ModuleKit.Module|nil
---@return string
local function resolutionLabel(name, requestingModule)
  if requestingModule ~= nil then
    return name .. "[" .. tostring(requestingModule._name) .. "]"
  end
  return name
end

---Read the options table of a `Provide*` method and compile its `implements`.
---@param options any the caller's options, `nil` when omitted
---@param methodName string public method name, used in the argument errors
---@param level integer stack level the failure is reported at
---@return table|nil contract
local function readProvideOptions(options, methodName, level)
  if type(options) == "nil" then
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
    if helpers.isSecret(key) then
      error(label .. " field names must not be secret values", level)
    end
    if key ~= "implements" then
      unknown = unknown or {}
      unknown[#unknown + 1] = helpers.describeKey(key)
    end
  end
  if unknown ~= nil then
    table.sort(unknown)
    error(label .. ' contains unknown field "' .. unknown[1] .. '"', level)
  end
  local implements = rawget(options, "implements")
  if type(implements) == "nil" then
    return nil
  end
  if type(state.parts.Implements) ~= "table" then
    error(helpers.partMissingMessage(label .. ' field "implements"', "Implements"), level)
  end
  return dispatch.compileImplements(implements, label .. ".implements", level + 1)
end

---Whether `name` is already taken by a module or another provider.
---@param addon ModuleKit.Addon
---@param name string
---@return boolean
local function providerConflict(addon, name)
  local providers = addon._providers
  return rawget(addon._modules, name) ~= nil
    or (providers ~= nil and rawget(providers, name) ~= nil)
end

---Publish one provider record under `name`, creating the container's provider
---table on its first provider.
---@param addon ModuleKit.Addon
---@param name string
---@param provider table provider record; its `kind` selects the resolution rule
---@param methodName string public method name, used in the argument errors
---@return ModuleKit.Addon addon
local function registerProvider(addon, name, provider, methodName)
  helpers.validateNonEmptyString(name, "ModuleKit.Addon:" .. methodName .. " providerName", 4)
  if providerConflict(addon, name) then
    error("ModuleKit.Addon:" .. methodName .. ' name "' .. name .. '" is already in use', 3)
  end
  local providers = addon._providers
  if providers == nil then
    providers = {}
    addon._providers = providers
  end
  rawset(providers, name, provider)
  return addon
end

---Run a lazy provider's factory with the resolution recorded on the
---container's stack, so a factory that resolves its way back to itself is
---reported as a cycle rather than recursing until the stack overflows.
---@param addon ModuleKit.Addon
---@param provider table
---@param name string
---@param kind "singleton"|"module"|"transient"
---@param requestingModule ModuleKit.Module|nil
---@return any value
local function runFactory(addon, provider, name, kind, requestingModule)
  local stack = addon._resolutionStack
  if stack == nil then
    stack = {}
    addon._resolutionStack = stack
  end
  for index = 1, #stack do
    if resolutionRecordMatches(stack[index], name, kind, requestingModule) then
      local cycle = {}
      for cycleIndex = index, #stack do
        local record = stack[cycleIndex]
        cycle[#cycle + 1] = resolutionLabel(record.name, record.requestingModule)
      end
      cycle[#cycle + 1] = resolutionLabel(name, kind == "module" and requestingModule or nil)
      -- Level 4: this frame, `resolveProvider`, the public method's caller.
      error("ModuleKit provider resolution cycle: " .. table.concat(cycle, " -> "), 4)
    end
  end

  stack[#stack + 1] = {
    name = name,
    requestingModule = kind == "module" and requestingModule or nil,
  }
  local factory = provider.factory
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
  if type(value) == "nil" then
    error('ModuleKit provider "' .. name .. '" factory returned nil', 4)
  end
  return value
end

---Resolve one injectable, falling back to a module of the same name.
---@param addon ModuleKit.Addon
---@param name string
---@param requestingModule ModuleKit.Module|nil scope context for module providers
---@return any value
local function resolveProvider(addon, name, requestingModule)
  helpers.validateNonEmptyString(name, "ModuleKit.Addon:Resolve providerName", 4)

  local providers = addon._providers
  local provider = providers ~= nil and rawget(providers, name) or nil
  if provider == nil then
    local module = rawget(addon._modules, name)
    if module ~= nil then
      return module
    end
    error('ModuleKit injectable "' .. name .. '" does not exist', 3)
  end

  local kind = provider.kind
  if kind == "value" then
    return provider.value
  end

  if kind == "module" and requestingModule == nil then
    error('ModuleKit module-scoped provider "' .. name .. '" requires a requesting module', 3)
  end

  if kind == "singleton" and provider.resolved == true then
    return provider.value
  end

  if kind == "module" then
    local record = rawget(provider.cache, requestingModule)
    if record ~= nil then
      return record.value
    end
  end

  -- Not a tail call: its error levels count this frame.
  local value = runFactory(addon, provider, name, kind, requestingModule)
  -- Checked before caching, so a refused value is produced again on the next
  -- resolution rather than served from the cache. Level 4 counts this frame.
  local contract = provider.implements
  if contract ~= nil then
    dispatch.checkImplements(
      contract,
      value,
      'provider "' .. resolutionLabel(name, kind == "module" and requestingModule or nil) .. '"',
      4
    )
  end

  if kind == "singleton" then
    provider.value = value
    provider.resolved = true
  elseif kind == "module" then
    rawset(provider.cache, requestingModule, { value = value })
  end

  return value
end

-- Injections -----------------------------------------------------------------

---Resolve every declared injection alias of `module`, in alias order, and
---keep the table on the module for its hooks.
---@param module ModuleKit.Module
---@return table<string, any> injections
local function resolveInjections(module)
  local addon = module._addon
  local specification = module._injectSpec
  -- Every module gets a table of its own, even with nothing to inject: its
  -- hooks receive it and may write into it.
  local resolved = {}
  if specification == nil or next(specification) == nil then
    module._injections = resolved
    return resolved
  end

  local aliases = {}
  for alias in pairs(specification) do
    aliases[#aliases + 1] = alias
  end
  table.sort(aliases)

  for index = 1, #aliases do
    local alias = aliases[index]
    resolved[alias] = resolveProvider(addon, rawget(specification, alias), module)
  end

  module._injections = resolved
  return resolved
end

---Return the module's own injection specification, creating it on the first
---alias; until then the module carries none.
---@param module ModuleKit.Module
---@return table<string, string> specification
local function ownInjectSpecification(module)
  local specification = module._injectSpec
  if specification == nil then
    specification = {}
    module._injectSpec = specification
  end
  return specification
end

---Record injection aliases on `module`.
---@param module ModuleKit.Module
---@param aliasOrMap any one alias, or an alias-to-name map
---@param target any target name, when a single alias was given
---@param level integer stack level the failures are reported at, counted from this function: `3` from `Inject`, `4` from a `CreateModule` definition
local function addInjections(module, aliasOrMap, target, level)
  helpers.ensureDefinitionMutable(module, "Inject", level + 1)
  helpers.ensureNotShutdown(module._addon, "ModuleKit.Module:Inject", level + 1)

  if type(aliasOrMap) == "table" and type(target) == "nil" then
    local aliases = {}
    for alias in next, aliasOrMap do
      if helpers.isSecret(alias) then
        error("ModuleKit.Module:Inject map aliases must not be secret values", level)
      end
      if type(alias) ~= "string" or alias == "" then
        error("ModuleKit.Module:Inject map aliases must be non-empty strings", level)
      end
      aliases[#aliases + 1] = alias
    end
    table.sort(aliases)

    -- Every target is checked before the first alias is stored, so a refused
    -- map leaves the specification as it was (`docs/API.md`: refused "before
    -- anything changes").
    for index = 1, #aliases do
      helpers.validateNonEmptyString(
        rawget(aliasOrMap, aliases[index]),
        "ModuleKit.Module:Inject target",
        level + 1
      )
    end
    local specification = ownInjectSpecification(module)
    for index = 1, #aliases do
      local alias = aliases[index]
      rawset(specification, alias, rawget(aliasOrMap, alias))
    end
    return
  end

  helpers.validateNonEmptyString(aliasOrMap, "ModuleKit.Module:Inject alias", level + 1)
  helpers.validateNonEmptyString(target, "ModuleKit.Module:Inject target", level + 1)
  rawset(ownInjectSpecification(module), aliasOrMap, target)
end

-- Public methods -------------------------------------------------------------

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

---Resolve an injectable with this module as the scope context.
---@param self ModuleKit.Module
---@param providerName string
---@return any
local function moduleResolve(self, providerName)
  helpers.validateNonEmptyString(providerName, "ModuleKit.Module:Resolve providerName", 3)
  return resolveProvider(rawget(self, "_addon"), providerName, self)
end

---Register an addon-scoped constant. `nil` is rejected. The value exists
---already, so `options.implements` is checked here, at the caller's line.
---@param self ModuleKit.Addon
---@param name string
---@param value any
---@param options ModuleKit.ProvideOptions|nil
---@return ModuleKit.Addon self
local function addonProvideValue(self, name, value, options)
  helpers.ensureNotShutdown(self, "ModuleKit.Addon:ProvideValue", 3)
  if type(value) == "nil" then
    error("ModuleKit.Addon:ProvideValue value must not be nil", 2)
  end
  helpers.validateNonEmptyString(name, "ModuleKit.Addon:ProvideValue providerName", 3)
  local contract = readProvideOptions(options, "ProvideValue", 3)
  if contract ~= nil then
    dispatch.checkImplements(contract, value, 'provider "' .. name .. '"', 3)
  end
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
  helpers.ensureNotShutdown(self, "ModuleKit.Addon:ProvideSingleton", 3)
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
  helpers.ensureNotShutdown(self, "ModuleKit.Addon:ProvideModule", 3)
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
  helpers.ensureNotShutdown(self, "ModuleKit.Addon:ProvideTransient", 3)
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
  if type(requestingModule) ~= "nil" then
    if helpers.isSecret(requestingModule) then
      error("ModuleKit.Addon:Resolve requestingModule must not be a secret value", 2)
    end
    -- Ownership is decided by identity with the module this container
    -- keeps under the name, so nothing read from the caller's table is
    -- compared: a module listed in `_modules` always belongs to `self`.
    -- A secret `_name` names no module and is refused as not owned.
    local modules = rawget(self, "_modules")
    local requesterName = type(requestingModule) == "table" and rawget(requestingModule, "_name")
      or nil
    if
      helpers.isSecret(requesterName)
      or type(requesterName) ~= "string"
      or rawget(modules, requesterName) ~= requestingModule
    then
      error("ModuleKit.Addon:Resolve requestingModule must be a module owned by this addon", 2)
    end
  end
  return resolveProvider(self, name, requestingModule)
end

-- Commit ---------------------------------------------------------------------

rawset(Addon, "ProvideValue", addonProvideValue)
rawset(Addon, "ProvideSingleton", addonProvideSingleton)
rawset(Addon, "ProvideModule", addonProvideModule)
rawset(Addon, "ProvideTransient", addonProvideTransient)
rawset(Addon, "Resolve", addonResolve)
rawset(Module, "Resolve", moduleResolve)
rawset(Module, "Inject", moduleInject)
-- Modules created with a prototype read the `Module` methods from a copy.
helpers.refreshLayers()

dispatch.resolveForHook = resolveInjections
dispatch.addInjections = addInjections

-- Recorded last: a part that failed to load above is never reported installed.
state.parts[PART_NAME] = { revision = PART_REVISION }

return ModuleKit
