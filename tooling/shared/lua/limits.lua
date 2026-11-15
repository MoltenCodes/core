-- Shared helper: limits
--
-- The `SetLimits` and `GetLimits` loop over a table of rules the Kit declares
-- before this block:
--
--     local UNBOUNDED = ... -- the Kit's `UNBOUNDED` sentinel, or nil
--     local LIMIT_RULES = {
--       { name = "maxGlows", ceiling = 1024 },
--       { name = "ttlSeconds", ceiling = 86400, minimum = 0.1, integer = false },
--       { name = "maxEntries", ceiling = 65536, unbounded = true },
--       { name = "journalCapacity", ceiling = 4096, unboundedReason = "it is allocated" },
--     }
--
-- A rule may also carry `check = function(value, level)` for a cross-limit
-- rule (LogKit's against SignalKit); it raises at `level` like the rest.
-- `minimum` defaults to 1, `integer` to true and `unbounded` to false.
--
-- `validateLimitUpdate(limits, level)` checks a whole update before anything is
-- written, so a bad entry leaves every limit as it was; `applyLimitUpdate`
-- then writes the given names into the shared limits, and `copyLimits` answers
-- `GetLimits` with a fresh table. A key is named with `describeKey`, so a
-- caller's `__tostring` never runs. A key read by `next` cannot be a secret
-- (storing one raises), so only values are asked.
--
-- shared revision: 1
-- shared requires: isSecret, describeKey
-- shared parameters: __FACADE__
--
-- Everything above `shared:body` stays in this file; the body below it is
-- what `python3 -m tooling.shared.sync` copies between a Kit's markers, with
-- `__FACADE__` replaced by the Kit's facade name.

---Stand-ins for what a Kit declares before this block.
local function isSecret(_)
  return false
end
local function describeKey(key)
  return tostring(key)
end
local UNBOUNDED = math.huge
local LIMIT_RULES = { { name = "maxItems", ceiling = 10 } }
-- shared:body
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
    local where = "__FACADE__:SetLimits limits." .. rule.name
    if isSecret(value) then
      error(where .. " must not be a secret value", level)
    end
    if value == UNBOUNDED and UNBOUNDED ~= nil then
      if rule.unbounded then
        return
      end
      local reason = rule.unboundedReason and (": " .. rule.unboundedReason) or ""
      error(where .. " cannot be __FACADE__.UNBOUNDED" .. reason, level)
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
      error("__FACADE__:SetLimits limits must be a table", level)
    end
    local key = next(limits)
    while type(key) ~= "nil" do
      local rule = type(key) == "string" and rulesByName[key] or nil
      if rule == nil then
        local named = "__FACADE__:SetLimits limits." .. describeKey(key)
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
-- shared:exports
-- Not copied: what the host tests of this helper load (tooling/tests/test_shared_sync.py).
return {
  validateLimitUpdate = validateLimitUpdate,
  applyLimitUpdate = applyLimitUpdate,
  copyLimits = copyLimits,
}
