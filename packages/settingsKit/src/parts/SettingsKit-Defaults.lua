-- MoltenCodes SettingsKit part Defaults
--
-- `SettingsKit:Open(savedVariable, defaults)` and
-- `db:RegisterNamespace(name, defaults)` from plain AceDB-style defaults: a
-- scope given as a plain table instead of a SchemaKit schema. The write rules
-- are inferred from each default, exactly as AddonKit's `MC:Database` infers
-- a SchemaKit schema, and checked here, so a database opened from plain
-- defaults needs no SchemaKit and holds no schema nodes:
--
--   true / 1 / "text"     an optional boolean, number (not integer) or string
--                         of at most max(4096, #default) characters
--   { a = ..., b = ... }  a closed record of those fields
--   {}                    a free-form bag: string keys of at most 256
--                         characters or number keys, at most 1024 entries,
--                         values unchecked
--   { ["*"] = d }         a keyed section of at most 1024 entries, keys as the
--                         bag's, whose entries read `d`
--   { 1, 2, 3 }           an array of one primitive type of at most
--                         max(1024, #default) elements
--   a SchemaKit node      kept as written and made optional (a "leaf"), the
--                         only part of a defaults table that needs SchemaKit
--
-- For each scope the part builds two things (`compileDefaults`): the
-- description `schema:Describe()` would return for the inferred schema, which
-- the core compiles into its plan unchanged, and a checker that takes the
-- sealed schema's place in `scope.schema`. The checker's `Check(value)`
-- answers `true`, or `false` and a failure with SchemaKit's shape (`path`,
-- `rule`, `expected`, `found`) and SchemaKit's wording for every rule it
-- implements, so refusals read the same as with an inferred SchemaKit schema.
-- It walks the description itself; a leaf's subtree is handed to the leaf's
-- own sealed `Check`, its path prefixed.
--
-- The part needs SettingsKit's core loaded first (API 1, revision 16 or later:
-- the first that hands plain scopes to `state.dispatch.compileDefaults`). It
-- calls the core only through `state.helpers`, read at call time.
--
-- Contents
-- --------
--   Constants ........ identity, inferred bounds, SchemaKit's phrases
--   Dependencies ..... SettingsKit's core and its state
--   Inference ........ defaults to descriptions
--   Checking ......... the checker over a description
--   Compiling ........ the dispatch entry
--   Commit ........... the entry and the part's revision

-- Constants ------------------------------------------------------------------

local PART_NAME = "Defaults"
local PART_REVISION = 1
local REQUIRED_REGISTRY_API = 2
local CORE_PACKAGE, CORE_API = "settingsKit", 1

-- Bounds the inferred rules add where AceDB has none, so a database opened
-- from plain defaults is still bounded. They are AddonKit's inference bounds.
local INFERRED_STRING_MAX = 4096
local INFERRED_KEY_MAX = 256
local INFERRED_MAP_MAX = 1024

-- What `getmetatable` answers for SchemaKit's nodes and sealed schemas.
local SCHEMA_TAGS = { ["SchemaKit.Node"] = true, ["SchemaKit.Schema"] = true }

-- The phrase SchemaKit reports as `expected` for a value of the wrong type,
-- by description kind (a map is a table; `oneOf` is the inferred key rule).
local EXPECTED_BY_KIND = {
  boolean = "boolean",
  number = "number",
  string = "string",
  table = "table",
  map = "table",
  array = "array",
  any = "any value",
  oneOf = "string or number",
}

-- Dependencies ---------------------------------------------------------------

-- The shared MoltenCodes namespace is the one documented global handoff point between independently embedded copies.
-- selene: allow(global_usage)
local moltenCodes = rawget(_G, "MoltenCodes")
local generations = type(moltenCodes) == "table" and rawget(moltenCodes, "Registries") or nil
local Registry = type(generations) == "table" and rawget(generations, REQUIRED_REGISTRY_API) or nil
local SettingsKit = nil
if type(Registry) == "table" and type(rawget(Registry, "Get")) == "function" then
  SettingsKit = Registry:Get(CORE_PACKAGE, CORE_API)
end
local state = type(SettingsKit) == "table" and rawget(SettingsKit, "_state") or nil
if
  type(state) ~= "table"
  or type(rawget(state, "parts")) ~= "table"
  or type(rawget(state, "dispatch")) ~= "table"
  or type(rawget(state, "helpers")) ~= "table"
  or type(rawget(rawget(state, "helpers"), "findSchemaKit")) ~= "function"
then
  error("MoltenCodes SettingsKit part Defaults requires SettingsKit API 1 to be loaded first", 2)
end

local parts = rawget(state, "parts")
local installed = rawget(parts, PART_NAME)
if
  type(installed) == "table"
  and type(installed.revision) == "number"
  and installed.revision >= PART_REVISION
then
  -- An equal or newer revision of this part already serves every database.
  return SettingsKit
end

local dispatch = rawget(state, "dispatch")
-- Read at call time, never copied: an upgraded core's helpers serve this part.
local helpers = rawget(state, "helpers")

-- Inference ------------------------------------------------------------------
--
-- A refusal is stored in the compilation's context and unwinds the recursion
-- with an error of its own; `compileDefaults` catches it and raises the
-- stored message at the caller's line, so the recursion never has to count
-- stack levels.

local describeValue

---Raise a refusal of the defaults at `path`.
---@param context table the compilation in progress
---@param path string
---@param reason string
local function refuse(context, path, reason)
  context.refusal = context.label .. " defaults " .. path .. " " .. reason
  error(context.refusal, 0)
end

---Whether `value` is a SchemaKit node or sealed schema.
---@param value table
---@return boolean
local function isSchemaNode(value)
  return SCHEMA_TAGS[getmetatable(value)] == true
end

---The description of the inferred map keys: a string of at most 256
---characters, or a number (SchemaKit's `oneOf`, as AddonKit builds it).
---@return table
local function keysDescription()
  return {
    kind = "oneOf",
    alternatives = {
      { kind = "string", max = INFERRED_KEY_MAX },
      { kind = "number", integer = false },
    },
  }
end

---The description of one primitive value's type, without a default.
---@param value boolean|number|string
---@param longest integer? the longest string the bound must admit
---@return table
local function primitiveDescription(value, longest)
  local valueType = type(value)
  if valueType == "boolean" then
    return { kind = "boolean" }
  elseif valueType == "number" then
    return { kind = "number", integer = false }
  end
  return { kind = "string", max = math.max(INFERRED_STRING_MAX, longest or #value) }
end

---A deep copy of a plain default, the copy `Describe` hands out.
---@param value any
---@return any
local function copyPlain(value)
  if type(value) ~= "table" then
    return value
  end
  local copy = {}
  for key, entry in next, value do
    copy[key] = copyPlain(entry)
  end
  return copy
end

---Whether `value` is a non-empty sequence with keys exactly `1..n`.
---@param value table
---@return boolean
local function isSequence(value)
  local count = 0
  for _ in next, value do
    count = count + 1
  end
  return count > 0 and count == #value
end

---The description of an array default: every element one primitive type.
---@param context table
---@param value table
---@param path string
---@return table description
local function describeArray(context, value, path)
  local elementType = type(rawget(value, 1))
  local longest = 0
  for index = 1, #value do
    local element = rawget(value, index)
    local thisType = type(element)
    if
      thisType ~= elementType
      or (thisType ~= "boolean" and thisType ~= "number" and thisType ~= "string")
    then
      refuse(
        context,
        path,
        "is a list of mixed or table values; write its schema node inline"
          .. " (SchemaKit.array{ of = ... })"
      )
    end
    if thisType == "string" and #element > longest then
      longest = #element
    end
  end
  return {
    kind = "array",
    of = primitiveDescription(rawget(value, 1), longest),
    min = 0,
    max = math.max(INFERRED_MAP_MAX, #value),
    optional = true,
    default = copyPlain(value),
  }
end

---The description of a record default (named keys) or a keyed section
---(`["*"]` alone), required, as a scope's own table is.
---@param context table
---@param defaults table
---@param path string
---@param depth integer
---@return table description
local function describeRecord(context, defaults, path, depth)
  if depth > context.maxDepth then
    refuse(context, path, "nest deeper than " .. context.maxDepth .. " tables")
  end
  if rawget(defaults, "**") ~= nil then
    refuse(
      context,
      path,
      'uses ["**"], which has no SettingsKit form; give each key its defaults, or use ["*"] alone'
    )
  end
  local wildcard = rawget(defaults, "*")
  local fields = {}
  local fieldNames = {}
  for key, value in next, defaults do
    if key ~= "*" then
      if type(key) ~= "string" or key == "" then
        refuse(
          context,
          path,
          "has a "
            .. type(key)
            .. ' key; record keys are non-empty strings (use ["*"] for a keyed bag)'
        )
      end
      fields[key] = describeValue(context, value, path .. "." .. key, depth + 1)
      fieldNames[#fieldNames + 1] = key
    end
  end
  if wildcard == nil then
    table.sort(fieldNames)
    return { kind = "table", fields = fields, fieldNames = fieldNames, open = false }
  end
  if #fieldNames > 0 then
    refuse(
      context,
      path,
      'puts ["*"] beside named keys, which has no SettingsKit form; move the named keys'
        .. ' into a record of their own, or keep ["*"] alone'
    )
  end
  -- The optional default of the values is SettingsKit's wildcard default:
  -- every key reads it until written, as AceDB's ["*"] does.
  return {
    kind = "map",
    keys = keysDescription(),
    values = describeValue(context, wildcard, path .. "[*]", depth + 1),
    max = INFERRED_MAP_MAX,
  }
end

---The description of a SchemaKit leaf, made optional. The leaf is sealed
---here, so its failure table is SettingsKit's, never the author's.
---@param context table
---@param node table a SchemaKit node or sealed schema
---@return table description
local function describeLeaf(context, node)
  local schemaKit = helpers.findSchemaKit()
  local sealed = schemaKit:Seal(node)
  local description = sealed:Describe()
  description.optional = true
  context.leaves[description] = sealed
  return description
end

---The optional description of one default value.
---@param context table
---@param value any
---@param path string
---@param depth integer
---@return table description
function describeValue(context, value, path, depth)
  local valueType = type(value)
  if valueType == "boolean" or valueType == "number" or valueType == "string" then
    local description = primitiveDescription(value)
    description.optional = true
    description.default = value
    return description
  end
  if valueType ~= "table" then
    refuse(
      context,
      path,
      "is a " .. valueType .. "; a default is a boolean, number, string, table or schema node"
    )
  end
  if isSchemaNode(value) then
    return describeLeaf(context, value)
  end
  if next(value) == nil then
    -- `{}`: a free-form bag, as AceDB users use it; bounded, values unchecked.
    return {
      kind = "map",
      keys = keysDescription(),
      values = { kind = "any" },
      max = INFERRED_MAP_MAX,
      optional = true,
      default = {},
    }
  end
  if isSequence(value) then
    return describeArray(context, value, path)
  end
  local description = describeRecord(context, value, path, depth)
  description.optional = true
  description.default = {}
  return description
end

-- Checking -------------------------------------------------------------------
--
-- The checker records a failure as SchemaKit does: the leaf that fails writes
-- the rule, expected and found phrases into the checker's one failure table,
-- and every container on the way back pushes the key it was checking onto a
-- segment stack. Nothing is pushed while a value is valid, so a valid check
-- allocates nothing; the path is built once, at the top, only for a failure.
-- User tables are read with `rawget` and `next`.

local checkValue

-- `maxDepth` for the check in progress, read once per `Check`.
local currentMaxDepth = 16

---Record a failure and return `false`.
---@param checker table
---@param rule string
---@param expected string
---@param found string
---@return boolean
local function fail(checker, rule, expected, found)
  local failure = checker.failure
  failure.rule = rule
  failure.expected = expected
  failure.found = found
  return false
end

---Push the key a container was checking when its child failed.
---@param checker table
---@param key any
---@return boolean
local function pushSegment(checker, key)
  local count = checker.segmentCount + 1
  checker.segmentCount = count
  checker.segments[count] = key
  return false
end

---Refuse a table nested deeper than `maxDepth`, as SchemaKit's `depth` rule.
---@param checker table
---@return boolean
local function failDepth(checker)
  return fail(
    checker,
    "depth",
    "at most " .. currentMaxDepth .. " nested tables",
    "table nested deeper"
  )
end

---Check a closed record.
---@param checker table
---@param description table
---@param value table
---@param depth integer
---@return boolean
local function checkRecord(checker, description, value, depth)
  local fieldNames = description.fieldNames
  local fields = description.fields
  for index = 1, #fieldNames do
    local name = fieldNames[index]
    if not checkValue(checker, fields[name], rawget(value, name), depth + 1) then
      return pushSegment(checker, name)
    end
  end
  for key in next, value do
    if fields[key] == nil then
      fail(checker, "unknown", "only declared fields", "undeclared field")
      return pushSegment(checker, key)
    end
  end
  return true
end

---Whether `key` passes the inferred key rule; records SchemaKit's `oneOf`
---failure, prefixed with "key", when it does not.
---@param checker table
---@param key any
---@return boolean
local function checkKey(checker, key)
  local keyType = type(key)
  if (keyType == "string" and #key <= INFERRED_KEY_MAX) or keyType == "number" then
    return true
  end
  return fail(checker, "oneOf", "key string or number", keyType)
end

---Check a keyed section or bag: the entry count first, then each key and
---value, stopping one entry past the bound.
---@param checker table
---@param description table
---@param value table
---@param depth integer
---@return boolean
local function checkMap(checker, description, value, depth)
  local max = description.max
  local values = description.values
  local count = 0
  for key, entry in next, value do
    count = count + 1
    if count > max then
      return fail(
        checker,
        "max",
        "table of at most " .. max .. " entries",
        "table with more than " .. max .. " entries"
      )
    end
    if not checkKey(checker, key) then
      return pushSegment(checker, key)
    end
    if not checkValue(checker, values, entry, depth + 1) then
      return pushSegment(checker, key)
    end
  end
  return true
end

---Check an array: the count first, then keys exactly `1..n`, then each
---element.
---@param checker table
---@param description table
---@param value table
---@param depth integer
---@return boolean
local function checkArray(checker, description, value, depth)
  local max = description.max
  local count = 0
  for _ in next, value do
    count = count + 1
    if count > max then
      return fail(
        checker,
        "max",
        "array of at most " .. max .. " elements",
        "table with more than " .. max .. " entries"
      )
    end
  end
  local of = description.of
  for index = 1, count do
    local element = rawget(value, index)
    if type(element) == "nil" then
      return fail(checker, "sequence", "array with keys 1 to n", "table with keys outside 1 to n")
    end
    if not checkValue(checker, of, element, depth + 1) then
      return pushSegment(checker, index)
    end
  end
  return true
end

---Check a scalar of the description's kind.
---@param checker table
---@param description table
---@param value any
---@return boolean
local function checkScalar(checker, description, value)
  local kind = description.kind
  local valueType = type(value)
  if valueType ~= kind then
    return fail(checker, "type", kind, valueType)
  end
  if kind == "number" and value ~= value then
    return fail(checker, "type", "number", "NaN")
  end
  local max = description.max
  if kind == "string" and max and #value > max then
    return fail(
      checker,
      "max",
      "string of at most " .. max .. " characters",
      "string of length " .. #value
    )
  end
  return true
end

---Check `value` against `description`, recording a failure in `checker`.
---@param checker table
---@param description table
---@param value any
---@param depth integer how many tables deep `value` is if it is a table
---@return boolean
function checkValue(checker, description, value, depth)
  local leaf = checker.leaves[description]
  if leaf ~= nil then
    -- The leaf was made optional; its own check asks about secrets first.
    if type(value) == "nil" then
      return true
    end
    local ok, failure = leaf:Check(value)
    if ok then
      return true
    end
    checker.leafPath = failure.path
    return fail(checker, failure.rule, failure.expected, failure.found)
  end

  local kind = description.kind
  local expected = EXPECTED_BY_KIND[kind]
  -- First, before any comparison: a secret raises when compared or tested.
  if helpers.isSecret(value) then
    return fail(checker, "secret", expected, "secret value")
  end
  if type(value) == "nil" then
    if description.optional then
      return true
    end
    return fail(checker, "required", expected, "nil")
  end

  if kind == "table" or kind == "map" or kind == "array" then
    if type(value) ~= "table" then
      return fail(checker, "type", expected, type(value))
    end
    if depth > currentMaxDepth then
      return failDepth(checker)
    end
    if kind == "table" then
      return checkRecord(checker, description, value, depth)
    elseif kind == "map" then
      return checkMap(checker, description, value, depth)
    end
    return checkArray(checker, description, value, depth)
  elseif kind == "any" then
    return true
  end
  return checkScalar(checker, description, value)
end

---Build the failure's path from the segment stack (outermost last), then the
---path inside a failing leaf, and empty the stack.
---@param checker table
---@return string
local function finishPath(checker)
  local segments = checker.segments
  local path = ""
  for index = checker.segmentCount, 1, -1 do
    path = helpers.joinRelative(path, helpers.formatKey(segments[index]))
    segments[index] = nil
  end
  checker.segmentCount = 0
  local leafPath = checker.leafPath
  checker.leafPath = ""
  if leafPath == "" then
    return path
  end
  if path == "" or leafPath:sub(1, 1) == "[" then
    return path .. leafPath
  end
  return path .. "." .. leafPath
end

-- The checkers' shared prototype, kept in the part's state so an upgraded
-- part serves the checkers an older one built.
local Checker = {}

---Check `value` against the scope's inferred rules. Returns `true`, or
---`false` and the checker's one failure table, overwritten by its next
---failing check, as a sealed SchemaKit schema's is.
---@param self table
---@param value any
---@return boolean ok, table|nil failure
function Checker.Check(self, value)
  currentMaxDepth = helpers.readMaxDepth()
  if checkValue(self, self.root, value, 1) then
    return true
  end
  self.failure.path = finishPath(self)
  return false, self.failure
end

-- Compiling ------------------------------------------------------------------

---The dispatch entry `compileScope` calls for a plain scope table: the
---checker that takes the sealed schema's place, and the description of the
---inferred schema for the core's plan. Refusals raise at `level`.
---@param defaults table the scope's plain defaults
---@param scopeName string
---@param level integer stack level the failures are reported at
---@param label string the method the defaults were passed to
---@return table checker, table description
local function compileDefaults(defaults, scopeName, level, label)
  local context = { label = label, maxDepth = helpers.readMaxDepth(), leaves = {} }
  local ok, result = pcall(describeRecord, context, defaults, scopeName, 1)
  if not ok then
    if context.refusal ~= nil then
      error(context.refusal, level)
    end
    error(result, 0)
  end
  local checker = setmetatable({
    root = result,
    leaves = context.leaves,
    failure = { path = "", rule = "type", expected = "", found = "" },
    segments = {},
    segmentCount = 0,
    leafPath = "",
  }, rawget(state, "defaultsCheckerMetatable"))
  return checker, result
end

-- Commit ---------------------------------------------------------------------

do
  local metatable = rawget(state, "defaultsCheckerMetatable")
  if type(metatable) ~= "table" then
    metatable = {}
    rawset(state, "defaultsCheckerMetatable", metatable)
  end
  metatable.__index = Checker
end
rawset(dispatch, "compileDefaults", compileDefaults)
rawset(parts, PART_NAME, { revision = PART_REVISION })

return SettingsKit
