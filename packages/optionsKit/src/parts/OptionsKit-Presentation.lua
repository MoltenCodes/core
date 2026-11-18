-- MoltenCodes OptionsKit part Presentation
--
-- AceConfig's presentation fields: `width`, `relWidth`, `descStyle`, `icon`,
-- `iconCoords`, `image`, `imageCoords`, `imageWidth`, `imageHeight`,
-- `tooltipHyperlink`, `dialogControl`, `control`, `itemControl` and `style`;
-- the function forms of `name`, `order` and `fontSize` and `sorting`
-- functions, resolved by `Describe`; and the per-interface flags
-- (`guiHidden`, `dialogHidden`, `cmdHidden`, `guiInline`, `dialogInline`,
-- `cmdInline`) that `IsHidden`, `Describe` and `DescribeOption` read for
-- `"dialog"` and `"cmd"`. Without this part `Define` refuses these fields at
-- the caller's line and names this file (ADR 0001, point 5).
--
-- The part adds nothing to the facade. It extends the core's field tables
-- and fills its hooks (`Hints`, `Resolve`) in `bind`, which runs at load and
-- again whenever a newer core loads, since every core revision builds those
-- tables anew.
--
-- Contents
-- --------
--   Constants ........ identity, accepted values, the fields this part adds
--   Dependencies ..... OptionsKit's core, its state and the helpers it lends
--   Field checks ..... textures, coordinates, controls, widths, styles
--   Resolution ....... what `Describe` calls: functions, sorting, interfaces
--   Binding .......... the field tables and hooks this part fills
--   Commit ........... the part's revision

-- Constants ------------------------------------------------------------------

local PART_NAME = "Presentation"
local PART_REVISION = 1
local REQUIRED_REGISTRY_API = 2
local CORE_PACKAGE, CORE_API = "optionsKit", 1
-- The first core revision with the hooks this part fills.
local REQUIRED_CORE_REVISION = 16

-- The accepted strings of `width`, `descStyle` and a select's `style`.
local WIDTHS = { normal = true, half = true, double = true, full = true }
local DESC_STYLES = { inline = true, tooltip = true }
local SELECT_STYLES = { dropdown = true, radio = true }

-- What each interface reads in place of `hidden` and `inline`, the first one
-- set winning, as AceConfigDialog and AceConfigCmd pick them.
local INTERFACE_FLAGS = {
  dialog = { hidden = { "dialogHidden", "guiHidden" }, inline = { "dialogInline", "guiInline" } },
  cmd = { hidden = { "cmdHidden" }, inline = { "cmdInline" } },
}

-- The fields this part adds: to every option, to every kind but `group`, and
-- per kind.
local COMMON_FIELDS = {
  "descStyle",
  "guiHidden",
  "dialogHidden",
  "cmdHidden",
  "icon",
  "iconCoords",
  "tooltipHyperlink",
}
local CONTROL_FIELDS = { "width", "relWidth", "dialogControl", "control" }
local KIND_FIELDS = {
  group = { "guiInline", "dialogInline", "cmdInline" },
  toggle = { "image", "imageCoords" },
  select = { "style", "itemControl" },
  execute = { "image", "imageCoords", "imageWidth", "imageHeight" },
  description = { "image", "imageCoords", "imageWidth", "imageHeight" },
}
-- The per-interface flags `Describe` folds into `hidden` and `inline`.
local NOT_DESCRIBED =
  { "guiHidden", "dialogHidden", "cmdHidden", "guiInline", "dialogInline", "cmdInline" }

-- Dependencies ---------------------------------------------------------------

-- The shared MoltenCodes namespace is the one documented global handoff point between independently embedded copies.
-- selene: allow(global_usage)
local namespace = rawget(_G, "MoltenCodes")
local generations = type(namespace) == "table" and rawget(namespace, "Registries") or nil
local Registry = type(generations) == "table" and rawget(generations, REQUIRED_REGISTRY_API) or nil
local OptionsKit = nil
if type(Registry) == "table" and type(rawget(Registry, "Get")) == "function" then
  OptionsKit = Registry:Get(CORE_PACKAGE, CORE_API)
end
local state = type(OptionsKit) == "table" and rawget(OptionsKit, "_state") or nil
if
  type(state) ~= "table"
  or type(rawget(state, "parts")) ~= "table"
  or type(rawget(state, "helpers")) ~= "table"
then
  error("MoltenCodes OptionsKit part Presentation requires OptionsKit API 1 to be loaded first", 2)
end
---@cast OptionsKit table
if
  type(rawget(OptionsKit, "REVISION")) ~= "number" or OptionsKit.REVISION < REQUIRED_CORE_REVISION
then
  error(
    "MoltenCodes OptionsKit part Presentation requires OptionsKit revision 16 or later to be loaded first",
    2
  )
end

local parts = rawget(state, "parts")
local installed = rawget(parts, PART_NAME)
if
  type(installed) == "table"
  and type(installed.revision) == "number"
  and installed.revision >= PART_REVISION
then
  -- An equal or newer revision of this part already serves every addon.
  return OptionsKit
end

-- The core's helpers, taken again by `bind` whenever a newer core revision
-- loads, so this part always runs the newest helpers.
local helpers = rawget(state, "helpers")

-- Everything this part hands to the core's hooks, in one table.
local Presentation = {}

-- Field checks ---------------------------------------------------------------

---Whether `value` is a texture: a path or a file ID. `Describe` checks a
---texture function's answer with it too.
---@param value any
---@return boolean
local function isTexture(value)
  local valueType = type(value)
  return valueType == "string" or (valueType == "number" and value == value)
end

---Refuse a texture field that is neither a texture nor a function.
---@param value any
---@param record table
---@param field string
---@param level integer
local function checkTexture(value, record, field, level)
  if type(value) ~= "nil" and type(value) ~= "function" and not isTexture(value) then
    error(
      helpers.labelOf(record, field) .. " must be a texture path, a file ID or a function",
      level
    )
  end
end

---Whether `value` is an array of 4 or 8 numbers: texture coordinates, as
---`SetTexCoord` takes them.
---@param value any
---@return boolean
local function isCoordinates(value)
  if type(value) ~= "table" then
    return false
  end
  local count = 0
  for key, item in pairs(value) do
    if type(key) ~= "number" or type(item) ~= "number" or item ~= item then
      return false
    end
    count = count + 1
  end
  if count ~= 4 and count ~= 8 then
    return false
  end
  for index = 1, count do
    if value[index] == nil then
      return false
    end
  end
  return true
end

---Check a coordinates field and return what to keep: a table is copied, as
---the tree is copied at `Define`, so a later edit to the caller's table has
---no effect; a function or a method name as it is.
---@param value any
---@param record table
---@param field string
---@param level integer
---@return any
local function checkCoordinates(value, record, field, level)
  local valueType = type(value)
  if valueType == "function" or valueType == "string" then
    return value
  end
  if not isCoordinates(value) then
    error(
      helpers.labelOf(record, field)
        .. " must be an array of 4 or 8 numbers, a function or a method name",
      level
    )
  end
  local copy = {}
  for index = 1, #value do
    copy[index] = value[index]
  end
  return copy
end

---Refuse a widget type name that is not a non-empty string.
---@param value any
---@param record table
---@param field string
---@param level integer
---@return any value
local function checkControlName(value, record, field, level)
  if type(value) ~= "string" or value == "" then
    error(helpers.labelOf(record, field) .. " must be a non-empty string", level)
  end
  return value
end

---Refuse a value that is not a boolean.
---@param value any
---@param record table
---@param field string
---@param level integer
---@return any value
local function checkBooleanField(value, record, field, level)
  helpers.checkOptionalBoolean(value, record, field, level + 1)
  return value
end

---Refuse a value that is not a positive number.
---@param value any
---@param record table
---@param field string
---@param level integer
---@return any value
local function checkPositive(value, record, field, level)
  helpers.checkPositiveNumber(value, record, field, level + 1)
  return value
end

local FIELD_CHECKS = {
  guiHidden = function(value, record, field, level)
    helpers.checkMethodPredicate(value, record, field, level + 1)
    return value
  end,
  descStyle = function(value, record, field, level)
    if DESC_STYLES[value] ~= true then
      error(helpers.labelOf(record, field) .. ' must be "inline" or "tooltip"', level)
    end
    return value
  end,
  icon = function(value, record, field, level)
    checkTexture(value, record, field, level + 1)
    return value
  end,
  tooltipHyperlink = function(value, record, field, level)
    helpers.checkOptionalStringOrFunction(value, record, field, level + 1)
    return value
  end,
  width = function(value, record, field, level)
    local valueType = type(value)
    if
      valueType ~= "function"
      and WIDTHS[value] ~= true
      and not (valueType == "number" and value > 0 and value < math.huge)
    then
      error(
        helpers.labelOf(record, field)
          .. ' must be "normal", "half", "double", "full", a positive number or a function',
        level
      )
    end
    return value
  end,
  relWidth = function(value, record, field, level)
    if type(value) ~= "number" or not (value > 0 and value <= 1) then
      error(helpers.labelOf(record, field) .. " must be a number above 0 and at most 1", level)
    end
    return value
  end,
  dialogControl = checkControlName,
  control = checkControlName,
  itemControl = checkControlName,
  style = function(value, record, field, level)
    if SELECT_STYLES[value] ~= true then
      error(helpers.labelOf(record, field) .. ' must be "dropdown" or "radio"', level)
    end
    return value
  end,
  guiInline = checkBooleanField,
  dialogInline = checkBooleanField,
  cmdInline = checkBooleanField,
  imageWidth = checkPositive,
  imageHeight = checkPositive,
  iconCoords = function(value, record, field, level)
    return checkCoordinates(value, record, field, level + 1)
  end,
}
FIELD_CHECKS.dialogHidden = FIELD_CHECKS.guiHidden
FIELD_CHECKS.cmdHidden = FIELD_CHECKS.guiHidden
FIELD_CHECKS.image = FIELD_CHECKS.icon
FIELD_CHECKS.imageCoords = FIELD_CHECKS.iconCoords

-- Resolution -----------------------------------------------------------------

---Call a presentation function of `record`, raising at the caller of the
---describing method when the result is not what `accepts` allows.
---@param record table
---@param field string
---@param resolver function
---@param expected string what the message says the function returned no
---@param accepts fun(value: any): boolean
---@param methodName string
---@param level integer
---@return any first, any second, any third
local function call(record, field, resolver, expected, accepts, methodName, level)
  local first, second, third = resolver(helpers.infoOf(record))
  if not accepts(first) then
    error(
      methodName
        .. " "
        .. field
        .. ' function of "'
        .. rawget(record, "_path")
        .. '" returned no '
        .. expected,
      level
    )
  end
  return first, second, third
end

---Whether a resolved value is a string.
---@param value any
---@return boolean
local function isString(value)
  return type(value) == "string"
end

---Whether a resolved `width` is a named width or a positive number.
---@param value any
---@return boolean
local function isWidth(value)
  return WIDTHS[value] == true or (type(value) == "number" and value > 0)
end

---Whether a resolved `fontSize` is one of the three sizes.
---@param value any
---@return boolean
local function isFontSize(value)
  return type(value) == "string" and helpers.fontSizes[value] == true
end

---Whether a resolved `order` is a number other than NaN; a secret is not.
---@param value any
---@return boolean
local function isOrder(value)
  return type(value) == "number" and not helpers.isSecret(value) and value == value
end

-- Per field: what the message calls the result, and the test it passes.
local RESOLVERS = {
  width = { "string or number", isWidth },
  fontSize = { '"small", "medium" or "large"', isFontSize },
  image = { "texture", isTexture },
  icon = { "texture", isTexture },
  tooltipHyperlink = { "string", isString },
  imageCoords = { "array of 4 or 8 numbers", isCoordinates },
  iconCoords = { "array of 4 or 8 numbers", isCoordinates },
}

---Report one hint that is a function or a table: a function resolved, a
---table copied. Plain hints are copied by `describeRecord` itself.
---@param node table
---@param record table
---@param field string
---@param value function|table
---@param methodName string
---@param level integer
function Presentation.hint(node, record, field, value, methodName, level)
  local resolver = RESOLVERS[field]
  if resolver ~= nil and type(value) == "function" then
    local first, second, third =
      call(record, field, value, resolver[1], resolver[2], methodName, level + 1)
    value = first
    -- An image function may answer AceConfig's three values.
    if field == "image" then
      if type(second) == "number" and second > 0 then
        node.imageWidth = second
      end
      if type(third) == "number" and third > 0 then
        node.imageHeight = third
      end
    end
  end
  if type(value) == "table" then
    local copy = {}
    for index = 1, #value do
      copy[index] = value[index]
    end
    value = copy
  end
  -- An image function's sizes win over the fields only when given.
  if node[field] == nil then
    node[field] = value
  end
end

---The name of `record` for a description: a function's string result.
---@param record table
---@param methodName string
---@param level integer
---@return string name
---@return boolean dynamic whether a function answered
function Presentation.name(record, methodName, level)
  local name = rawget(record, "_name")
  if type(name) == "function" then
    return call(record, "name", name, "string", isString, methodName, level + 1), true
  end
  return name, false
end

---The order of `record` for a description: a function's number result.
---@param record table
---@param methodName string
---@param level integer
---@return number order
---@return boolean dynamic whether a function answered
function Presentation.order(record, methodName, level)
  local order = helpers.presentationOf(record, "order", "_order")
  if type(order) == "function" then
    return call(record, "order", order, "number", isOrder, methodName, level + 1), true
  end
  return order or helpers.defaultOrder, false
end

---`inline` of a group for `interface`: the first of the interface's own
---flags that is set, else `inline`.
---@param hints table
---@param interface string|nil
---@return boolean|nil
function Presentation.inline(hints, interface)
  if interface ~= nil then
    local names = INTERFACE_FLAGS[interface].inline
    for index = 1, #names do
      local flag = hints[names[index]]
      if type(flag) ~= "nil" then
        return flag
      end
    end
  end
  return hints.inline
end

---Sort described siblings by order, name and key, as `Define` sorts
---records, on the resolved plain values: run only when a sibling has a
---function `name` or `order`, so no consumer code runs inside the sort. A
---secret name sorts by its key.
---@param nodes table[]
function Presentation.sortNodes(nodes)
  table.sort(nodes, function(left, right)
    if left.order ~= right.order then
      return left.order < right.order
    end
    local leftName = left.name
    local rightName = right.name
    if type(leftName) ~= "string" or helpers.isSecret(leftName) then
      leftName = left.key
    end
    if type(rightName) ~= "string" or helpers.isSecret(rightName) then
      rightName = right.key
    end
    if leftName ~= rightName then
      return leftName < rightName
    end
    return left.key < right.key
  end)
end

---The sorting array a select's `sorting` function answers, checked like a
---`sorting` field at `Define`.
---@param record table
---@param sorting function
---@param values table the described values
---@param methodName string
---@param level integer
---@return table
function Presentation.sortingFunction(record, sorting, values, methodName, level)
  local answer = sorting(helpers.infoOf(record))
  local valid = type(answer) == "table"
  local copy = {}
  if valid then
    for index = 1, #answer do
      local key = answer[index]
      if (type(key) ~= "string" and type(key) ~= "number") or values[key] == nil then
        valid = false
        break
      end
      copy[index] = key
    end
  end
  if not valid then
    error(
      methodName
        .. ' sorting function of "'
        .. rawget(record, "_path")
        .. '" returned no array of keys of its values',
      level
    )
  end
  return copy
end

---`compareRecords` for siblings among which a `name` or an `order` is a
---function (revision 14), which `Describe` resolves: here such an order sorts
---as the default and such a name as the key.
---@param left table
---@param right table
---@return boolean
function Presentation.compareDynamicRecords(left, right)
  local leftHints, rightHints = left._hints, right._hints
  local leftOrder = leftHints and leftHints.order
  local rightOrder = rightHints and rightHints.order
  if type(leftOrder) ~= "number" then
    leftOrder = helpers.defaultOrder
  end
  if type(rightOrder) ~= "number" then
    rightOrder = helpers.defaultOrder
  end
  if leftOrder ~= rightOrder then
    return leftOrder < rightOrder
  end
  local leftName = left._name
  local rightName = right._name
  if type(leftName) ~= "string" then
    leftName = helpers.keyOf(left)
  end
  if type(rightName) ~= "string" then
    rightName = helpers.keyOf(right)
  end
  if leftName ~= rightName then
    return leftName < rightName
  end
  return helpers.keyOf(left) < helpers.keyOf(right)
end

---The `hidden` flag `record` itself has for `interface`: the first of the
---interface's own flags that is set (`dialogHidden`, then `guiHidden`; or
---`cmdHidden`), else `hidden`, as AceConfigDialog and AceConfigCmd pick them.
---@param record table
---@param interface string|nil
---@return any
function Presentation.hiddenFlag(record, interface)
  if interface ~= nil then
    local hints = record._hints
    if hints ~= nil then
      local names = INTERFACE_FLAGS[interface].hidden
      for index = 1, #names do
        local flag = hints[names[index]]
        if type(flag) ~= "nil" then
          return flag
        end
      end
    end
  end
  return helpers.presentationOf(record, "hidden", "_hidden")
end

-- Binding --------------------------------------------------------------------

---Add a list of field names to a set.
---@param set table<string, true>
---@param names string[]
local function addFields(set, names)
  for index = 1, #names do
    set[names[index]] = true
  end
end

---Extend the core's field tables and fill its hooks. Called by this file and
---by every newer core, which builds those tables anew.
---@param coreHelpers table the core's `state.helpers`
local function bind(coreHelpers)
  helpers = coreHelpers
  local Fields, Hints, Resolve = coreHelpers.Fields, coreHelpers.Hints, coreHelpers.Resolve
  addFields(Fields.common, COMMON_FIELDS)
  addFields(Fields.control, CONTROL_FIELDS)
  for kind, names in pairs(KIND_FIELDS) do
    addFields(Fields.kind[kind], names)
  end
  addFields(Fields.notDescribed, NOT_DESCRIBED)
  for field, check in pairs(FIELD_CHECKS) do
    Hints.roles[field] = check
  end
  -- The function forms of `name`, `order`, `fontSize` and `sorting` are
  -- accepted: `Describe` resolves them.
  Hints.functionForm = function() end
  Hints.compareDynamicRecords = Presentation.compareDynamicRecords
  Resolve.hint = Presentation.hint
  Resolve.name = Presentation.name
  Resolve.order = Presentation.order
  Resolve.inline = Presentation.inline
  Resolve.sortNodes = Presentation.sortNodes
  Resolve.sortingFunction = Presentation.sortingFunction
  Resolve.hiddenFlag = Presentation.hiddenFlag
end

-- Commit ---------------------------------------------------------------------

bind(helpers)
rawset(parts, PART_NAME, {
  revision = PART_REVISION,
  bind = bind,
  members = {},
})
helpers.dropLegacyWhenComplete()

return OptionsKit
