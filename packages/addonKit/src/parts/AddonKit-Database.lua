-- MoltenCodes AddonKit part Database
--
-- `MC:Database(savedVariable, defaults, options?)`: a SettingsKit database
-- opened from an AceDB-style defaults table, with the SchemaKit schema
-- inferred from the defaults, plus `MC.Range` and `MC.Enum`, the two schema
-- nodes a defaults table most often needs written by hand.
--
-- The inference gives every field a type and every map a bound, which is
-- what SettingsKit's guarantees need. It does not invent constraints: a
-- range or a choice is written inline as a schema node. What it infers:
--
--   true / 1 / "text"     optional(boolean / number / string, value);
--                         strings get a length bound, numbers are not made
--                         integers (`scale = 1` accepts 1.5)
--   { a = ..., b = ... }  an optional record of the inferred fields
--   {}                    a bounded free-form bag: string or number keys, any values
--   { ["*"] = ... }       a bounded map whose entries read the wildcard's defaults
--   { 1, 2, 3 }           an optional array of that one primitive type
--   a SchemaKit node      itself, made optional when it is not
--
-- The part needs AddonKit's core loaded first, and SchemaKit, SettingsKit and
-- LifecycleKit when `Database` runs (LifecycleKit tells whether the addon has
-- loaded: the client restores a saved variable only at ADDON_LOADED).
--
-- Contents
-- --------
--   Constants ........ identity, scopes, inferred bounds
--   Dependencies ..... AddonKit's core and its state
--   Inference ........ defaults to schema nodes
--   Methods .......... Database, Range, Enum
--   Commit ........... members and the part's revision

-- Constants ------------------------------------------------------------------

local PART_NAME = "Database"
local PART_REVISION = 1
local REQUIRED_REGISTRY_API = 2
local CORE_PACKAGE, CORE_API = "addonKit", 1

-- SettingsKit's scopes, in the order a message lists them.
local SCOPE_NAMES = { "profile", "global", "char", "realm", "class", "faction" }
local SCOPES = {}
for index = 1, #SCOPE_NAMES do
  SCOPES[SCOPE_NAMES[index]] = true
end

-- Bounds the inferred schema adds where AceDB has none, so an inferred
-- database is still bounded: SchemaKit requires every map to have one.
local INFERRED_STRING_MAX = 4096
local INFERRED_KEY_MAX = 256
local INFERRED_MAP_MAX = 1024

-- How deep a defaults table may nest: SchemaKit's own default depth.
local MAX_DEFAULTS_DEPTH = 16

-- What `getmetatable` answers for SchemaKit's nodes and sealed schemas.
local SCHEMA_TAGS = { ["SchemaKit.Node"] = true, ["SchemaKit.Schema"] = true }

-- Dependencies ---------------------------------------------------------------

-- The shared MoltenCodes namespace is the one documented global handoff point between independently embedded copies.
-- selene: allow(global_usage)
local namespace = rawget(_G, "MoltenCodes")
local generations = type(namespace) == "table" and rawget(namespace, "Registries") or nil
local Registry = type(generations) == "table" and rawget(generations, REQUIRED_REGISTRY_API) or nil
local AddonKit = nil
if type(Registry) == "table" and type(rawget(Registry, "Get")) == "function" then
  AddonKit = Registry:Get(CORE_PACKAGE, CORE_API)
end
local state = type(AddonKit) == "table" and rawget(AddonKit, "_state") or nil
if
  type(state) ~= "table"
  or type(rawget(state, "methods")) ~= "table"
  or type(rawget(state, "helpers")) ~= "table"
  or type(rawget(state, "parts")) ~= "table"
then
  error("MoltenCodes AddonKit part Database requires AddonKit API 1 to be loaded first", 2)
end

local parts = rawget(state, "parts")
local installed = rawget(parts, PART_NAME)
if
  type(installed) == "table"
  and type(installed.revision) == "number"
  and installed.revision >= PART_REVISION
then
  -- An equal or newer revision of this part already serves every facade.
  return AddonKit
end

local methods = rawget(state, "methods")
-- Read at call time, never copied: an upgraded core's helpers serve this part.
local helpers = rawget(state, "helpers")

-- Inference ------------------------------------------------------------------
--
-- Inference raises with level 0 (no position): `Database` runs it under
-- `callAtCaller`, which raises the message again at the author's line.

local inferNode

---Whether `value` is a SchemaKit node or sealed schema.
---@param value any
---@return boolean
local function isSchemaNode(value)
  return type(value) == "table" and SCHEMA_TAGS[getmetatable(value)] == true
end

---`node` made optional; a node that already is optional stays as it is.
---@param SchemaKit table
---@param node table
---@return table
local function asOptional(SchemaKit, node)
  local ok, optional = pcall(SchemaKit.optional, node)
  if ok then
    return optional
  end
  return node
end

---The key schema of an inferred map or bag: a bounded string, or a number.
---@param SchemaKit table
---@return table
local function inferredKeys(SchemaKit)
  return SchemaKit.oneOf({ SchemaKit.string({ max = INFERRED_KEY_MAX }), SchemaKit.number() })
end

---The node of one primitive value, without a default.
---@param SchemaKit table
---@param value boolean|number|string
---@return table
local function primitiveNode(SchemaKit, value)
  local valueType = type(value)
  if valueType == "boolean" then
    return SchemaKit.boolean()
  elseif valueType == "number" then
    return SchemaKit.number()
  end
  return SchemaKit.string({ max = math.max(INFERRED_STRING_MAX, #value) })
end

---Whether `value` is a non-empty sequence with keys exactly `1..n`.
---@param value table
---@return boolean
local function isSequence(value)
  local count = 0
  for _ in pairs(value) do
    count = count + 1
  end
  return count > 0 and count == #value
end

---An array default: every element one primitive type.
---@param SchemaKit table
---@param value table
---@param path string
---@return table node
local function inferArray(SchemaKit, value, path)
  local elementType = type(value[1])
  for index = 1, #value do
    local element = value[index]
    local thisType = type(element)
    if
      thisType ~= elementType
      or (thisType ~= "boolean" and thisType ~= "number" and thisType ~= "string")
    then
      error(
        "MC:Database defaults "
          .. path
          .. " is a list of mixed or table values; write its schema node inline (MC.S.array{ of = ... })",
        0
      )
    end
  end
  local copy = {}
  for index = 1, #value do
    copy[index] = value[index]
  end
  local longest = 0
  if elementType == "string" then
    for index = 1, #value do
      longest = math.max(longest, #value[index])
    end
  end
  local element = elementType == "string"
      and SchemaKit.string({ max = math.max(INFERRED_STRING_MAX, longest) })
    or primitiveNode(SchemaKit, value[1])
  return SchemaKit.optional(
    SchemaKit.array({ of = element, max = math.max(INFERRED_MAP_MAX, #value) }),
    copy
  )
end

---A record: a defaults table with named keys, or a wildcard map.
---@param SchemaKit table
---@param defaults table
---@param path string
---@param depth integer
---@return table node a required `table` or `map` node
local function inferRecord(SchemaKit, defaults, path, depth)
  if depth > MAX_DEFAULTS_DEPTH then
    error(
      "MC:Database defaults " .. path .. " nest deeper than " .. MAX_DEFAULTS_DEPTH .. " tables",
      0
    )
  end
  if defaults["**"] ~= nil then
    error(
      "MC:Database defaults "
        .. path
        .. ' uses ["**"], which has no SettingsKit form; give each key its defaults, or use ["*"] alone',
      0
    )
  end
  local wildcard = defaults["*"]
  local fieldNodes = {}
  local named = false
  for key, value in pairs(defaults) do
    if key ~= "*" then
      if type(key) ~= "string" or key == "" then
        error(
          "MC:Database defaults "
            .. path
            .. " has a "
            .. type(key)
            .. ' key; record keys are non-empty strings (use ["*"] for a keyed bag)',
          0
        )
      end
      named = true
      fieldNodes[key] = inferNode(SchemaKit, value, path .. "." .. key, depth + 1)
    end
  end
  if wildcard == nil then
    return SchemaKit.table({ fields = fieldNodes })
  end
  if named then
    error(
      "MC:Database defaults "
        .. path
        .. ' puts ["*"] beside named keys, which has no SettingsKit form; move the named keys'
        .. ' into a record of their own, or keep ["*"] alone',
      0
    )
  end
  -- The optional default of the values is SettingsKit's wildcard default:
  -- every key reads it until written, as AceDB's ["*"] does.
  local values = inferNode(SchemaKit, wildcard, path .. "[*]", depth + 1)
  return SchemaKit.map({ keys = inferredKeys(SchemaKit), values = values, max = INFERRED_MAP_MAX })
end

---The optional node of one default value.
---@param SchemaKit table
---@param value any
---@param path string
---@param depth integer
---@return table node
function inferNode(SchemaKit, value, path, depth)
  local valueType = type(value)
  if valueType == "boolean" or valueType == "number" or valueType == "string" then
    return SchemaKit.optional(primitiveNode(SchemaKit, value), value)
  end
  if valueType ~= "table" then
    error(
      "MC:Database defaults "
        .. path
        .. " is a "
        .. valueType
        .. "; a default is a boolean, number, string, table or schema node",
      0
    )
  end
  if isSchemaNode(value) then
    return asOptional(SchemaKit, value)
  end
  if next(value) == nil then
    -- `{}`: a free-form bag, as AceDB users use it; bounded, values unchecked.
    return SchemaKit.optional(
      SchemaKit.map({
        keys = inferredKeys(SchemaKit),
        values = SchemaKit.any(),
        max = INFERRED_MAP_MAX,
      }),
      {}
    )
  end
  if isSequence(value) then
    return inferArray(SchemaKit, value, path)
  end
  return SchemaKit.optional(inferRecord(SchemaKit, value, path, depth), {})
end

---The SettingsKit schema of a whole defaults table: one record per scope.
---@param SchemaKit table
---@param defaults table
---@return table schema
local function inferSchema(SchemaKit, defaults)
  local schema = {}
  local any = false
  for scope, scopeDefaults in pairs(defaults) do
    if type(scope) ~= "string" or not SCOPES[scope] then
      error(
        "MC:Database defaults has the scope "
          .. tostring(scope)
          .. ", which SettingsKit does not have; its scopes are "
          .. table.concat(SCOPE_NAMES, ", "),
        0
      )
    end
    if isSchemaNode(scopeDefaults) then
      schema[scope] = scopeDefaults
    elseif type(scopeDefaults) == "table" then
      schema[scope] = inferRecord(SchemaKit, scopeDefaults, scope, 1)
    else
      error("MC:Database defaults." .. scope .. " must be a table of defaults", 0)
    end
    any = true
  end
  if not any then
    error("MC:Database defaults must hold at least one scope, such as profile = { ... }", 0)
  end
  return schema
end

-- Methods --------------------------------------------------------------------

---Open a database from AceDB-style defaults, the schema inferred.
---
---Refuses to open before the addon's ADDON_LOADED: the client restores the
---saved variable only then and replaces what an earlier open created. A
---second call for the same saved variable answers the same database when it
---is given the same defaults table.
---@param self MoltenCodesFacade
---@param savedVariable string the `## SavedVariables` name
---@param defaults table `{ profile = { ... }, global = { ... } }`
---@param options table? `SettingsKit:Open`'s options
---@return table db a SettingsKit database
local function facadeDatabase(self, savedVariable, defaults, options)
  local record = helpers.requireRecord(self, "MC:Database", 3)
  helpers.requireName(savedVariable, "MC:Database savedVariable", 3)
  if helpers.isSecret(defaults) or type(defaults) ~= "table" then
    error("MC:Database defaults must be a table: { profile = { ... }, global = { ... } }", 2)
  end
  if helpers.isSecret(options) or (type(options) ~= "nil" and type(options) ~= "table") then
    error("MC:Database options must be a table of SettingsKit:Open options or nil", 2)
  end
  local opened = record.databases[savedVariable]
  if opened ~= nil then
    if opened.defaults ~= defaults then
      error(
        "MC:Database "
          .. savedVariable
          .. " is already open with another defaults table; open it once and keep the database (self.db)",
        2
      )
    end
    return opened.db
  end
  local LifecycleKit = helpers.requireKit(record, "LifecycleKit", 3)
  local SchemaKit = helpers.requireKit(record, "SchemaKit", 3)
  local SettingsKit = helpers.requireKit(record, "SettingsKit", 3)
  local lifecycle = helpers.callAtCaller(3, LifecycleKit.ForAddon, LifecycleKit, record.addonName)
  if not lifecycle:IsLoaded() then
    error(
      record.addonName
        .. " opened "
        .. savedVariable
        .. " before ADDON_LOADED; open it in OnInitialize, after the client restored it",
      2
    )
  end
  local schema = helpers.callAtCaller(3, inferSchema, SchemaKit, defaults)
  local db = helpers.callAtCaller(3, SettingsKit.Open, SettingsKit, savedVariable, schema, options)
  record.databases[savedVariable] = { defaults = defaults, db = db }
  return db
end

---Refuse a facade passed as the first argument of a dot helper.
---@param first any
---@param label string
---@param usage string
local function refuseColonCall(first, label, usage)
  if helpers.isFacade(first) then
    error(label .. " is called with a dot: " .. usage, 3)
  end
end

---An optional number from `min` to `max`, reading `default` until written:
---`scale = MC.Range(0.5, 2, 1)`.
---@param min number
---@param max number
---@param default number
---@return table node
local function facadeRange(min, max, default)
  if helpers.isSecret(min) or helpers.isSecret(max) or helpers.isSecret(default) then
    error("MC.Range min, max and default must not be secret values", 2)
  end
  refuseColonCall(min, "MC.Range", "MC.Range(min, max, default)")
  if type(min) ~= "number" or type(max) ~= "number" or type(default) ~= "number" then
    error("MC.Range takes three numbers: MC.Range(min, max, default)", 2)
  end
  local SchemaKit = helpers.requireSchemaKit(3)
  local bounded = helpers.callAtCaller(3, SchemaKit.number, { min = min, max = max })
  return helpers.callAtCaller(3, SchemaKit.optional, bounded, default)
end

---An optional choice among `values`, reading `default` until written:
---`anchor = MC.Enum({ "TOP", "CENTER" }, "TOP")`.
---@param values (string|number|boolean)[]
---@param default string|number|boolean
---@return table node
local function facadeEnum(values, default)
  if helpers.isSecret(values) or helpers.isSecret(default) then
    error("MC.Enum values and default must not be secret values", 2)
  end
  refuseColonCall(values, "MC.Enum", "MC.Enum(values, default)")
  if type(values) ~= "table" then
    error(
      "MC.Enum values must be a list of strings, numbers or booleans: MC.Enum(values, default)",
      2
    )
  end
  if default == nil then
    error("MC.Enum needs a default, one of the values: MC.Enum(values, default)", 2)
  end
  local SchemaKit = helpers.requireSchemaKit(3)
  local choice = helpers.callAtCaller(3, SchemaKit.enum, values)
  return helpers.callAtCaller(3, SchemaKit.optional, choice, default)
end

-- Commit ---------------------------------------------------------------------

rawset(methods, "Database", facadeDatabase)
rawset(methods, "Range", facadeRange)
rawset(methods, "Enum", facadeEnum)
rawset(parts, PART_NAME, { revision = PART_REVISION })

return AddonKit
