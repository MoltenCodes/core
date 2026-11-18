-- MoltenCodes ModuleKit part RequiredAddons
--
-- Modules that cannot work without another addon (docs/API.md, "Halted
-- addons"): the `requiresAddons` definition field, its LifecycleKit
-- `DependsOn` declarations, and the reaction when one of those addons halts.
-- Such a module is taken down with its enabled hard dependents, keeps its
-- intent, and records the halted addon as what blocks it; an enable is
-- refused for the rest of the session.
--
-- The reaction to the container's own addon halting is not here: a halt can
-- come from any addon that embeds LifecycleKit's Halt part, so ModuleKit's
-- core answers it whatever parts an addon embeds.
--
-- The part needs ModuleKit's core loaded first, and LifecycleKit's Halt part,
-- which owns `DependsOn` and `OnDependencyHalted` (docs/decisions/
-- 0001-kit-core-and-parts.md). It fills four entries of the core's
-- `state.dispatch`: `addRequiredAddon` (one definition entry),
-- `declareRequiredAddons` (when the module is created), `requiredAddonBlocker`
-- (what a halt blocks an enable on) and `dependencyHalted` (the LifecycleKit
-- notice). It calls the core only through `state.helpers`, read at call time,
-- so a core upgraded after this part loaded serves it. Required-addon lists
-- live in the modules and the subscription in the container, so a higher
-- revision of this part takes them over in place.
--
-- Contents
-- --------
--   Constants ........ identity
--   Dependencies ..... ModuleKit's core, LifecycleKit and its Halt part
--   Declarations ..... the definition field and the DependsOn edges
--   Halts ............ what blocks an enable, the dependency-halted notice
--   Commit ........... dispatch entries and the part's revision

-- Constants ------------------------------------------------------------------

local PART_NAME = "RequiredAddons"
local PART_REVISION = 1
local REQUIRED_REGISTRY_API = 2
local CORE_PACKAGE, CORE_API = "moduleKit", 1
local REQUIRED_LIFECYCLE_API = 1
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
  error("MoltenCodes ModuleKit part RequiredAddons requires ModuleKit API 1 to be loaded first", 2)
end

---@cast ModuleKit table

-- ModuleKit's core requires LifecycleKit, so it is loaded. `DependsOn` is in
-- its Halt part since LifecycleKit split it out; a LifecycleKit that answers
-- `HasPart` must have that part, and one that predates parts has it built in.
local LifecycleKit = Registry:Get("lifecycleKit", REQUIRED_LIFECYCLE_API)
local lifecycleHasPart = type(LifecycleKit) == "table" and rawget(LifecycleKit, "HasPart") or nil
if type(lifecycleHasPart) == "function" and lifecycleHasPart(LifecycleKit, "Halt") ~= true then
  error(
    "MoltenCodes ModuleKit part RequiredAddons requires LifecycleKit's Halt part to be loaded "
      .. "first: add lifecycleKit\\parts\\LifecycleKit-Halt.lua to embeds.xml before it",
    2
  )
end
---@cast LifecycleKit table

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

-- Declarations ---------------------------------------------------------------

---Whether `module` names `addonName` in `requiresAddons`.
---@param module ModuleKit.Module
---@param addonName string
---@return boolean
local function requiresAddon(module, addonName)
  local required = module._requiredAddons
  if required == nil then
    return false
  end
  for index = 1, #required do
    if required[index] == addonName then
      return true
    end
  end
  return false
end

---Record one `requiresAddons` entry on `module`.
---
---Raised errors use level 5, the caller of `CreateModule`: this function is
---called by the core's definition-list walk, which its definition step calls
---from `CreateModule`.
---@param module ModuleKit.Module
---@param addonName any
local function addRequiredAddon(module, addonName)
  if helpers.isSecret(addonName) then
    error("ModuleKit module definition requiresAddons entries must not be secret values", 5)
  end
  if type(addonName) ~= "string" or addonName == "" then
    error("ModuleKit module definition requiresAddons entries must be non-empty strings", 5)
  end
  if addonName == module._addon._name then
    error(
      'ModuleKit module definition requiresAddons must name other addons, not "'
        .. addonName
        .. '" itself',
      5
    )
  end
  if requiresAddon(module, addonName) then
    return
  end

  local required = module._requiredAddons
  local count = required ~= nil and #required or 0
  local maxRequiredAddons = state.limits.maxRequiredAddons
  if maxRequiredAddons ~= state.unbounded and count >= maxRequiredAddons then
    error(
      "ModuleKit module definition requiresAddons must list at most "
        .. tostring(maxRequiredAddons)
        .. " addons (ModuleKit:SetLimits maxRequiredAddons)",
      5
    )
  end
  if required == nil then
    required = {}
    module._requiredAddons = required
  end
  required[count + 1] = addonName
end

---Subscribe the container to the halts of the addons its modules require,
---unless it already is.
---
---Only a container with a module that declares `requiresAddons` subscribes:
---the notice acts on such modules alone, so a container without one would
---receive every notice for nothing. `declareRequiredAddons` subscribes before
---the module's first `DependsOn`, which is when LifecycleKit could first
---announce a halt that matters.
---
---The subscription replays every declared dependency that has already halted.
---The replay is ignored: a module that requires a halted addon is blocked when
---it is created.
---@param addon ModuleKit.Addon
local function subscribeToDependencyHalts(addon)
  local subscriptions = addon._subscriptions
  if subscriptions.dependencyHalted ~= nil then
    return
  end
  local lifecycle = addon._lifecycle
  local replaying = true
  local handle = lifecycle:OnDependencyHalted(function(_, haltedAddonName)
    if not replaying then
      helpers.invokeDispatch("dependencyHalted", addon, haltedAddonName)
    end
  end)
  replaying = false
  addon._subscriptions.dependencyHalted = handle
end

---Declare every addon `module` requires as a LifecycleKit dependency of its
---container's addon, so the addon hears when one of them halts.
---
---Runs before the module is published, so a refusal leaves the container
---without it. LifecycleKit keeps an addon's declarations for the session:
---entries declared before a refusal stay declared, which only means their
---halts are also announced.
---@param addon ModuleKit.Addon
---@param module ModuleKit.Module
local function declareRequiredAddons(addon, module)
  local required = module._requiredAddons
  if required == nil or #required == 0 then
    return
  end

  -- Before the first `DependsOn`: declaring an addon that already halted
  -- announces it at once.
  subscribeToDependencyHalts(addon)

  local lifecycle = addon._lifecycle
  for index = 1, #required do
    local recorded, reason = lifecycle:DependsOn(required[index])
    -- `"halted"` needs nothing here: the container's own halt already
    -- blocks every module. `"shutdown"` cannot occur, because a shut-down
    -- container refuses `CreateModule` before this point.
    if type(recorded) == "nil" and reason == "full" then
      -- Level 3: this frame, `CreateModule`, its caller.
      error(
        'ModuleKit.Addon:CreateModule module "'
          .. module._name
          .. '" requires addon "'
          .. required[index]
          .. '", but addon "'
          .. addon._name
          .. '" already declares the most addon dependencies LifecycleKit accepts',
        3
      )
    end
  end
end

-- Halts ----------------------------------------------------------------------

---Whether the addon named `addonName` has halted.
---@param addonName string
---@return boolean
local function isOtherAddonHalted(addonName)
  local instance = LifecycleKit:ForAddon(addonName)
  return type(instance:GetHaltReason()) ~= "nil"
end

---The first addon of `module`'s `requiresAddons` that has halted, or `nil`.
---@param module ModuleKit.Module
---@return string|nil addonName
local function requiredAddonBlocker(module)
  local required = module._requiredAddons
  if required == nil then
    return nil
  end
  for index = 1, #required do
    local addonName = required[index]
    if isOtherAddonHalted(addonName) then
      return addonName
    end
  end
  return nil
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
  local dependents = helpers.enabledHardDependents(module)
  for index = 1, #dependents do
    blockForHaltedAddon(dependents[index], module._name)
  end

  if module._wantedEnabled == true then
    helpers.markBlocked(module, blockedBy)
  end
  helpers.disableOne(module)
end

---Take down the modules that name a halted addon in `requiresAddons`.
---
---Modules are visited newest first; each one is independent, so a failing
---`OnDisable` leaves that module enabled and the rest are still visited. The
---first failure is re-raised afterwards.
---@param addon ModuleKit.Addon
---@param haltedAddonName string
---@return ModuleKit.Addon addon
local function dependencyHalted(addon, haltedAddonName)
  if addon._shutdown == true then
    return addon
  end

  local modules = addon._moduleOrder
  local firstError
  for index = #modules, 1, -1 do
    local module = modules[index]
    if requiresAddon(module, haltedAddonName) then
      local ok, value = pcall(blockForHaltedAddon, module, haltedAddonName)
      firstError = helpers.captureFirstError(firstError, ok, value)
    end
  end

  helpers.raiseCaptured(firstError)
  return addon
end

-- Commit ---------------------------------------------------------------------

dispatch.addRequiredAddon = addRequiredAddon
dispatch.declareRequiredAddons = declareRequiredAddons
dispatch.requiredAddonBlocker = requiredAddonBlocker
dispatch.dependencyHalted = dependencyHalted

-- Recorded last: a part that failed to load above is never reported installed.
state.parts[PART_NAME] = { revision = PART_REVISION }

return ModuleKit
