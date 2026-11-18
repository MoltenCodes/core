-- MoltenCodes LifecycleKit part Halt
--
-- Halting (docs/API.md, "Halted state"): `Halt`, with which an addon declares
-- itself non-functional for the rest of the session, and the dependencies
-- between addons, `DependsOn` and `OnDependencyHalted`, through which the
-- addons that declared a halted one are told.
--
-- The observers stay in the core (`IsHalted`, `GetHaltReason`, `OnHalted`, the
-- `"halted"` answer of `GetState`): a halt can come from any addon that embeds
-- this part, and an addon that only watches for one needs nothing else.
--
-- The part needs LifecycleKit's core loaded first (docs/decisions/
-- 0001-kit-core-and-parts.md). Each addon's dependency list lives in its
-- instance (`_dependencies`, created by the first `DependsOn`, the field
-- revision 18 used), so a higher revision of this part takes it over in place.
-- The part calls the core through `state.helpers`, read at call time.
--
-- Contents
-- --------
--   Constants ........ identity
--   Dependencies ..... LifecycleKit's core and its state
--   Dependencies between addons  lookup and the announcement of a halt
--   Public API ....... Halt, DependsOn, OnDependencyHalted
--   Commit ........... members and the part's revision

-- Constants ------------------------------------------------------------------

local PART_NAME = "Halt"
local PART_REVISION = 1
local REQUIRED_REGISTRY_API = 2
local CORE_PACKAGE, CORE_API = "lifecycleKit", 1
-- The core interface this part reads (`state.helpers`, `state.dispatch`).
local REQUIRED_PART_INTERFACE = 1

-- Dependencies ---------------------------------------------------------------

-- The shared MoltenCodes namespace is the one documented global handoff point between independently embedded copies.
-- selene: allow(global_usage)
local namespace = rawget(_G, "MoltenCodes")
local generations = type(namespace) == "table" and rawget(namespace, "Registries") or nil
local Registry = type(generations) == "table" and rawget(generations, REQUIRED_REGISTRY_API) or nil
local LifecycleKit = nil
if type(Registry) == "table" and type(rawget(Registry, "Get")) == "function" then
  LifecycleKit = Registry:Get(CORE_PACKAGE, CORE_API)
end
local state = type(LifecycleKit) == "table" and rawget(LifecycleKit, "_state") or nil
local partInterface = type(state) == "table" and rawget(state, "partInterface") or nil
if
  type(state) ~= "table"
  or type(partInterface) ~= "number"
  or partInterface < REQUIRED_PART_INTERFACE
  or type(rawget(state, "parts")) ~= "table"
  or type(rawget(state, "helpers")) ~= "table"
  or type(rawget(state, "dispatch")) ~= "table"
then
  error("MoltenCodes LifecycleKit part Halt requires LifecycleKit API 1 to be loaded first", 2)
end

---@cast LifecycleKit table

local installed = state.parts[PART_NAME]
if
  type(installed) == "table"
  and type(installed.revision) == "number"
  and installed.revision >= PART_REVISION
then
  -- An equal or newer revision of this part already serves every addon.
  return LifecycleKit
end

-- Read at call time, never copied: an upgraded core's helpers serve this part.
local helpers = state.helpers
local dispatch = state.dispatch
local Instance = rawget(LifecycleKit, "Instance")

-- Dependencies between addons ---------------------------------------------------

---Whether `instance` declared `addonName` with `DependsOn`.
---@param instance table
---@param addonName string
---@return boolean
local function dependsOnAddon(instance, addonName)
  local dependencies = instance._dependencies
  if dependencies == nil then
    return false
  end
  for index = 1, #dependencies do
    if dependencies[index] == addonName then
      return true
    end
  end
  return false
end

---Tell every live addon that declared `halted` as a dependency.
---@param halted table
---@param reason string
---@return LifecycleKit.ErrorRecord|nil
local function announceHalt(halted, reason)
  local instances = state.instances
  local count = #instances
  local addonName = halted._addonName
  local isTerminal = helpers.isTerminal
  local firstError = nil

  for index = 1, count do
    local dependent = instances[index]
    if
      dependent ~= halted
      and not isTerminal(dependent)
      and dependsOnAddon(dependent, addonName)
    then
      local notifyError = helpers.deliver(dependent, "dependencyHalted", addonName, reason)
      if firstError == nil then
        firstError = notifyError
      end
    end
  end

  return firstError
end

-- Public API --------------------------------------------------------------------

---Declare this addon non-functional for the rest of the session.
---
---Every phase not yet reached becomes unreachable and its pending callbacks
---are disconnected, the combat queue is closed with `(instance, false,
---"halted")`, the `OnHalted` subscribers run, and then every addon that
---declared this one with `DependsOn` receives `OnDependencyHalted`. Halted is
---terminal: there is no resume in API 1.
---@param self LifecycleKit.Instance
---@param reason string why the addon cannot work, for dependents and diagnostics
---@return boolean halted `true` for the call that halted; `false` when already halted or shut down
local function halt(self, reason)
  helpers.refuseSecret(reason, "LifecycleKit.Instance:Halt reason", 3)
  if type(reason) ~= "string" or reason == "" then
    error("LifecycleKit.Instance:Halt reason must be a non-empty string", 2)
  end
  if helpers.isTerminal(self) then
    return false
  end

  self._halted = true
  self._haltReason = reason
  helpers.disconnectUnreachable(self, "halted")

  local queueError = dispatch.closeCombatQueue(self, "halted")
  local haltedError = helpers.deliver(self, "halted", reason)
  local announceError = announceHalt(self, reason)

  helpers.raisePhaseError(queueError or haltedError or announceError)
  return true
end

---Record that this addon cannot work without `addonName`.
---
---When `addonName` halts, this addon's `OnDependencyHalted` subscribers are
---told. If it has already halted, they are told at once.
---@param self LifecycleKit.Instance
---@param addonName string the dependency's folder name, exactly as installed
---@return boolean|nil recorded `true` when newly recorded, `false` when already recorded, `nil` when refused
---@return string|nil reason `"full"`, `"halted"` or `"shutdown"` when refused
local function dependsOn(self, addonName)
  helpers.refuseSecret(addonName, "LifecycleKit.Instance:DependsOn addonName", 3)
  if type(addonName) ~= "string" or addonName == "" then
    error("LifecycleKit.Instance:DependsOn addonName must be a non-empty string", 2)
  end
  if addonName == self._addonName then
    error("LifecycleKit.Instance:DependsOn addonName must name another addon", 2)
  end
  if self._halted == true then
    return nil, "halted"
  end
  if self._shutdown == true then
    return nil, "shutdown"
  end
  if dependsOnAddon(self, addonName) then
    return false
  end

  local dependencies = self._dependencies
  if dependencies == nil then
    dependencies = {}
    self._dependencies = dependencies
  end
  local maxDependencies = state.limits.maxDependencies
  if maxDependencies ~= state.unbounded and #dependencies >= maxDependencies then
    return nil, "full"
  end
  dependencies[#dependencies + 1] = addonName

  local dependency = state.addons[addonName]
  if dependency ~= nil and dependency._halted == true then
    helpers.raisePhaseError(
      helpers.deliver(self, "dependencyHalted", addonName, dependency._haltReason)
    )
  end
  return true
end

---Subscribe to every halt of a declared dependency.
---
---Dependencies that halted before this call are replayed at once, so the order
---of `DependsOn` and `OnDependencyHalted` does not matter: each subscriber
---hears of each halted dependency exactly once.
---@param self LifecycleKit.Instance
---@param callback LifecycleKit.DependencyHaltedCallback
---@return LifecycleKit.Subscription subscription
local function onDependencyHalted(self, callback)
  if type(callback) ~= "function" then
    error("LifecycleKit.Instance:OnDependencyHalted callback must be a function", 2)
  end

  local isSubscriptionConnected = helpers.isSubscriptionConnected
  local subscription = helpers.subscribeRepeating(self, "dependencyHalted", callback)
  if not isSubscriptionConnected(subscription) then
    return subscription
  end

  local addons = state.addons
  local dependencies = self._dependencies or {}
  local firstError = nil
  for index = 1, #dependencies do
    -- A replayed callback may end its own subscription, typically by
    -- halting this addon in response, which disconnects it like a
    -- dispatch would. A disconnected subscription hears nothing more.
    if not isSubscriptionConnected(subscription) then
      break
    end
    local dependencyName = dependencies[index]
    local dependency = addons[dependencyName]
    if dependency ~= nil and dependency._halted == true then
      local ok, message = pcall(callback, self, dependencyName, dependency._haltReason)
      if not ok and firstError == nil then
        firstError = helpers.newErrorRecord(message)
      end
    end
  end

  -- A failing replay leaves the subscription connected, exactly as a
  -- failing dispatch would: later halts are still delivered to it.
  helpers.raisePhaseError(firstError)
  return subscription
end

-- Commit --------------------------------------------------------------------

rawset(Instance, "Halt", halt)
rawset(Instance, "DependsOn", dependsOn)
rawset(Instance, "OnDependencyHalted", onDependencyHalted)

state.parts[PART_NAME] = { revision = PART_REVISION }

return LifecycleKit
