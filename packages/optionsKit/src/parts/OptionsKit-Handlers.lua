-- MoltenCodes OptionsKit part Handlers
--
-- AceConfig's ways of wiring a tree: a `handler` table and method names (a
-- string naming a method of the handler in force, ADR 0003) in every field
-- that takes a callback, the accessors `get`, `set`, `validate` and `func`
-- declared on a group and inherited by the options below it, and a group's
-- `plugins`, whose options join its children. Without this part `Define`
-- refuses these at the caller's line and names this file (ADR 0001, point 5).
--
-- Everything this part does happens at `Define`: method names become callers
-- and inherited accessors are resolved into the records, so `Get`, `Set` and
-- the predicates run the same function paths with or without it. The part
-- adds nothing to the facade; it extends the core's field tables and fills
-- its hooks (`Hints`) in `bind`, which runs at load and again whenever a
-- newer core loads, since every core revision builds those tables anew.
--
-- Contents
-- --------
--   Constants ........ identity, the fields this part adds
--   Dependencies ..... OptionsKit's core, its state and the helpers it lends
--   Method names ..... the handler check, method callers, inherited accessors
--   Plugins .......... a group's plugin options built as its children
--   Binding .......... the field tables and hooks this part fills
--   Commit ........... the part's revision

-- Constants ------------------------------------------------------------------

local PART_NAME = "Handlers"
local PART_REVISION = 1
local REQUIRED_REGISTRY_API = 2
local CORE_PACKAGE, CORE_API = "optionsKit", 1
-- The first core revision with the hooks this part fills.
local REQUIRED_CORE_REVISION = 16

-- The fields a group gains: the accessors it passes down, and `plugins`.
local GROUP_FIELDS = { "plugins", "get", "set", "validate", "func" }

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
  error("MoltenCodes OptionsKit part Handlers requires OptionsKit API 1 to be loaded first", 2)
end
---@cast OptionsKit table
if
  type(rawget(OptionsKit, "REVISION")) ~= "number" or OptionsKit.REVISION < REQUIRED_CORE_REVISION
then
  error(
    "MoltenCodes OptionsKit part Handlers requires OptionsKit revision 16 or later to be loaded first",
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

-- Method names ---------------------------------------------------------------

---Refuse a `handler` that is not a table; return it to keep as a hint.
---@param value any
---@param record table
---@param field string
---@param level integer
---@return any value
local function checkHandler(value, record, field, level)
  if type(value) ~= "table" then
    error(helpers.labelOf(record, field) .. " must be a table", level)
  end
  return value
end

---Refuse an accessor a group passes down that is not a function, a method
---name or `false`.
---@param value any
---@param record table
---@param field string
---@param level integer
local function checkAccessor(value, record, field, level)
  local valueType = type(value)
  if
    valueType ~= "nil"
    and valueType ~= "function"
    and valueType ~= "string"
    and value ~= false
  then
    error(helpers.labelOf(record, field) .. " must be a function, a method name or false", level)
  end
end

---The function that calls method `methodName` of `handler`, looked up on
---every call (late binding), shared by every option of one build with the
---same handler and name. It is stored where a function would be, so the
---paths that call it are the function paths, unchanged.
---@param context table the build context
---@param handler table
---@param methodName string
---@return function
local function methodCaller(context, handler, methodName)
  local byName = context.methodCallers[handler]
  if byName == nil then
    byName = {}
    context.methodCallers[handler] = byName
  end
  local caller = byName[methodName]
  if caller == nil then
    caller = function(info, ...)
      local method = handler[methodName]
      if type(method) ~= "function" then
        local tree = info.tree
        error(
          "OptionsKit ("
            .. tostring(rawget(tree, "_addonName"))
            .. ") "
            .. info.path
            .. ': handler method "'
            .. methodName
            .. '" is missing',
          2
        )
      end
      return method(handler, info, ...)
    end
    byName[methodName] = caller
  end
  return caller
end

---Resolve one callback field: a function as it is, a method name into the
---caller of that method of the handler in force, which must have it now
---(ADR 0003); anything else (`nil`, `false`, a boolean) as it is.
---@param context table
---@param record table
---@param value any
---@param field string
---@param level integer
---@return any
local function resolveCallback(context, record, value, field, level)
  if type(value) ~= "string" then
    return value
  end
  local labelOf = helpers.labelOf
  local handler = helpers.handlerInForce(record)
  if handler == nil then
    error(
      labelOf(record, field) .. ' is a method name ("' .. value .. '"), but no handler is in force',
      level
    )
  end
  if type(handler[value]) ~= "function" then
    error(
      labelOf(record, field)
        .. ' names method "'
        .. value
        .. '", which the handler in force does not have',
      level
    )
  end
  return methodCaller(context, handler, value)
end

---The value of accessor `field` in force for `record`: its own when the spec
---has one, else the nearest group's above it, `false` stopping the search
---(AceConfig's rule). A method name is resolved against the record's own
---handler in force.
---@param context table
---@param record table
---@param own any the spec's own value
---@param field string
---@param level integer
---@return any
local function resolveAccessor(context, record, own, field, level)
  local value = own
  if type(value) == "nil" and context.inheritsAccessors then
    local parent = rawget(record, "_parent")
    while parent do
      local hints = parent._hints
      local inherited = hints and hints[field]
      if type(inherited) ~= "nil" then
        value = inherited
        break
      end
      parent = rawget(parent, "_parent")
    end
  end
  return resolveCallback(context, record, value, field, level + 1)
end

-- Plugins --------------------------------------------------------------------

---Build the options of a group's `plugins` as children of the group: a
---plugin's name is not part of any path, and a key that two plugins, or a
---plugin and `args`, both define is refused.
---@param context table
---@param record table the group's record
---@param args table the group's `args`, already built
---@param plugins any
---@param children table[] the group's children, appended to
---@param depth integer the group's depth
---@param level integer
local function buildPlugins(context, record, args, plugins, children, depth, level)
  local labelOf = helpers.labelOf
  if type(plugins) ~= "table" then
    error(labelOf(record, "plugins") .. " must be a table", level)
  end
  -- Where each key came from, for the collision message; only a group with
  -- plugins pays for it.
  local origins = {}
  for key in pairs(args) do
    origins[key] = "args"
  end
  for pluginName, pluginArgs in pairs(plugins) do
    if type(pluginName) ~= "string" or type(pluginArgs) ~= "table" then
      error(labelOf(record, "plugins") .. " must map plugin names to tables of options", level)
    end
    for key, childSpec in pairs(pluginArgs) do
      if type(key) ~= "string" or not key:find(helpers.keyPattern) then
        error(
          labelOf(record, "plugins")
            .. "."
            .. pluginName
            .. " keys must be identifiers (letters, digits and _)",
          level
        )
      end
      local origin = origins[key]
      if origin ~= nil then
        error(
          labelOf(record, "plugins")
            .. "."
            .. pluginName
            .. "."
            .. key
            .. " collides with "
            .. (origin == "args" and "args." or ("plugins." .. origin .. "."))
            .. key,
          level
        )
      end
      origins[key] = pluginName
      children[#children + 1] =
        helpers.buildOption(context, childSpec, record, key, depth + 1, level + 1)
    end
  end
end

-- Binding --------------------------------------------------------------------

---Extend the core's field tables and fill its hooks. Called by this file and
---by every newer core, which builds those tables anew.
---@param coreHelpers table the core's `state.helpers`
local function bind(coreHelpers)
  helpers = coreHelpers
  local Fields, Hints = coreHelpers.Fields, coreHelpers.Hints
  Fields.common.handler = true
  local groupFields = Fields.kind[coreHelpers.kindGroup]
  for index = 1, #GROUP_FIELDS do
    groupFields[GROUP_FIELDS[index]] = true
  end
  Hints.roles.handler = checkHandler
  Hints.checkAccessor = checkAccessor
  Hints.callback = resolveCallback
  Hints.accessor = resolveAccessor
  Hints.buildPlugins = buildPlugins
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
