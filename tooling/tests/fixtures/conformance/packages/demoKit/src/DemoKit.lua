-- DemoKit: the fixture Kit of the conformance suite's own tests.
--
-- It follows the Kit conventions the suite checks, using the shared helper
-- blocks of tooling/shared/lua/. tooling/tests/test_kit_conformance.py copies
-- it with one convention broken at a time and expects the matching case to
-- fail.

local PACKAGE_NAME = "demoKit"
local API_GENERATION = 1
local IMPLEMENTATION_REVISION = 2
local REQUIRED_REGISTRY_API = 2
local UNBOUNDED = setmetatable({}, { __metatable = "DemoKit.UNBOUNDED" })
local LIMIT_RULES = { { name = "maxItems", ceiling = 64 } }

-- selene: allow(global_usage)
local namespace = rawget(_G, "MoltenCodes")
local generations = type(namespace) == "table" and rawget(namespace, "Registries") or nil
local Registry = type(generations) == "table" and rawget(generations, REQUIRED_REGISTRY_API) or nil
if type(Registry) ~= "table" or rawget(Registry, "API") ~= REQUIRED_REGISTRY_API then
  error("MoltenCodes DemoKit requires Registry API 2 to be loaded first", 2)
end

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
-- shared:begin limits 1 __FACADE__=DemoKit
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
    local where = "DemoKit:SetLimits limits." .. rule.name
    if isSecret(value) then
      error(where .. " must not be a secret value", level)
    end
    if value == UNBOUNDED and UNBOUNDED ~= nil then
      if rule.unbounded then
        return
      end
      local reason = rule.unboundedReason and (": " .. rule.unboundedReason) or ""
      error(where .. " cannot be DemoKit.UNBOUNDED" .. reason, level)
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
      error("DemoKit:SetLimits limits must be a table", level)
    end
    local key = next(limits)
    while type(key) ~= "nil" do
      local rule = type(key) == "string" and rulesByName[key] or nil
      if rule == nil then
        local named = "DemoKit:SetLimits limits." .. describeKey(key)
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

local function validatePublicSurface(implementation)
  return type(implementation) == "table"
    and type(rawget(implementation, "Add")) == "function"
    and type(rawget(implementation, "Count")) == "function"
    and type(rawget(implementation, "SetLimits")) == "function"
    and type(rawget(implementation, "GetLimits")) == "function"
end

local function validateState(implementation)
  local state = rawget(implementation, "_state")
  return type(state) == "table" and type(rawget(state, "items")) == "table"
end

local DemoKit, previousRevision, selected = Registry:Bootstrap({
  package = PACKAGE_NAME,
  api = API_GENERATION,
  revision = IMPLEMENTATION_REVISION,
  label = "MoltenCodes DemoKit",
  validatePublicSurface = validatePublicSurface,
  validateState = validateState,
})
if DemoKit == nil then
  return selected
end

local state = rawget(DemoKit, "_state")
if previousRevision == nil or state == nil then
  state = { items = {}, limits = { maxItems = 8 } }
  rawset(DemoKit, "_state", state)
end

-- shared:begin validateFacade 1 __FACADE__=DemoKit
-- Copied from tooling/shared/lua/validateFacade.lua by python3 -m tooling.shared.sync; edit that file, not this copy.
---Raise at `level` unless `receiver` is the DemoKit facade.
---@param receiver any the table the method was called on
---@param label string qualified method name, used in the argument error
---@param level integer stack level the failure is reported at
local function validateFacade(receiver, label, level)
  if type(receiver) ~= "table" or receiver ~= DemoKit then
    local hint = "; use " .. label .. "(...)"
    error(label .. " must be called on the DemoKit facade" .. hint, level)
  end
end
-- shared:end validateFacade

local function facadeAdd(self, name)
  validateFacade(self, "DemoKit:Add", 3)
  if isSecret(name) then
    error("DemoKit:Add name must not be a secret value", 2)
  end
  if type(name) ~= "string" or name == "" then
    error("DemoKit:Add name must be a non-empty string", 2)
  end
  if #state.items >= state.limits.maxItems then
    return false
  end
  state.items[#state.items + 1] = name
  return true
end

local function facadeCount(self)
  validateFacade(self, "DemoKit:Count", 3)
  return #state.items
end

local function facadeSetLimits(self, limits)
  validateFacade(self, "DemoKit:SetLimits", 3)
  validateLimitUpdate(limits, 3)
  applyLimitUpdate(state.limits, limits)
end

local function facadeGetLimits(self)
  validateFacade(self, "DemoKit:GetLimits", 3)
  return copyLimits(state.limits)
end

rawset(DemoKit, "API", API_GENERATION)
rawset(DemoKit, "REVISION", IMPLEMENTATION_REVISION)
rawset(DemoKit, "UNBOUNDED", UNBOUNDED)
rawset(DemoKit, "Add", facadeAdd)
rawset(DemoKit, "Count", facadeCount)
rawset(DemoKit, "SetLimits", facadeSetLimits)
rawset(DemoKit, "GetLimits", facadeGetLimits)

return DemoKit
