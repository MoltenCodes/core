-- MoltenCodes CommandKit part Arguments
--
-- Schema-checked command arguments (ADR 0001): a command spec's `arguments`,
-- one `SchemaKit.array` schema or a list of per-position schemas, compiled
-- when the command is registered and checked on every typed line before the
-- handler runs. The usage word of each argument (`<number>`, `<on|off>`,
-- `[text]`) is generated from its schema, and a refused argument prints
-- `path: argument 2: expected ..., found ...` with the command's usage.
--
-- The core compiles a spec without `arguments` itself and hands a spec's
-- `arguments` to this part through `_state.parts.Arguments`, so an addon
-- whose commands take plain words embeds neither this part nor SchemaKit.
-- Without the part, `Register` refuses `arguments` at the caller's line and
-- names this file. See `docs/API.md`, "Arguments".
--
-- The part needs SchemaKit API 1, and publishes into the core's helpers what
-- the Options part reads: `SchemaKit`, `BOOLEAN_WORDS` and `joinValues`.
--
-- Contents
-- --------
--   Constants ........ identity, the boolean words
--   Dependencies ..... CommandKit's core, its state and helpers, SchemaKit
--   Schemas .......... sealing, coercion and usage text from schemas
--   Checking ......... coercing and checking a typed line's arguments
--   Commit ........... the part's record and helpers, the hand-over dropped

-- Constants ------------------------------------------------------------------

local PART_NAME = "Arguments"
local PART_REVISION = 1
local REQUIRED_REGISTRY_API = 2
local REQUIRED_SCHEMAKIT_API = 1
local CORE_PACKAGE, CORE_API = "commandKit", 1

-- Words a boolean argument and a toggle option accept, lower-case.
local BOOLEAN_WORDS = {
  on = true,
  off = false,
  ["true"] = true,
  ["false"] = false,
  yes = true,
  no = false,
  ["1"] = true,
  ["0"] = false,
}

-- Dependencies ---------------------------------------------------------------

-- The shared MoltenCodes namespace is the one documented global handoff point between independently embedded copies.
-- selene: allow(global_usage)
local namespace = rawget(_G, "MoltenCodes")
local generations = type(namespace) == "table" and rawget(namespace, "Registries") or nil
local Registry = type(generations) == "table" and rawget(generations, REQUIRED_REGISTRY_API) or nil
local CommandKit = nil
if type(Registry) == "table" and type(rawget(Registry, "Get")) == "function" then
  CommandKit = Registry:Get(CORE_PACKAGE, CORE_API)
end
local state = type(CommandKit) == "table" and rawget(CommandKit, "_state") or nil
if
  type(state) ~= "table"
  or type(rawget(state, "parts")) ~= "table"
  or type(rawget(state, "helpers")) ~= "table"
then
  error("MoltenCodes CommandKit part Arguments requires CommandKit API 1 to be loaded first", 2)
end
-- The hand-over to this part arrived with core revision 12, which publishes
-- `failWithUsage` for it; an older core compiles arguments itself and never
-- asks a part.
if type(rawget(rawget(state, "helpers"), "failWithUsage")) ~= "function" then
  error(
    "MoltenCodes CommandKit part Arguments requires CommandKit revision 12 or later to be loaded first",
    2
  )
end

-- SchemaKit seals and checks every argument schema. Checked at load, so a
-- missing one fails loudly at this file instead of at the first `Register`.
local SchemaKit = Registry:Get("schemaKit", REQUIRED_SCHEMAKIT_API)
if
  type(SchemaKit) ~= "table"
  or rawget(SchemaKit, "API") ~= REQUIRED_SCHEMAKIT_API
  or type(rawget(SchemaKit, "Seal")) ~= "function"
  or type(rawget(SchemaKit, "string")) ~= "function"
  or type(rawget(SchemaKit, "optional")) ~= "function"
then
  error("MoltenCodes CommandKit part Arguments requires SchemaKit API 1 to be loaded first", 2)
end

local parts = rawget(state, "parts")
local installed = rawget(parts, PART_NAME)
if
  type(installed) == "table"
  and type(installed.revision) == "number"
  and installed.revision >= PART_REVISION
then
  -- An equal or newer revision of this part already serves every scope.
  return CommandKit
end

-- Read at call time, never copied: an upgraded core's helpers serve this part.
local helpers = rawget(state, "helpers")

-- Schemas --------------------------------------------------------------------
--
-- A command declares its arguments either as one `SchemaKit.array` schema, or
-- as a list of per-position schemas. Tokens arrive as strings, so each
-- position (or the array's element) is given a coercion when the command is
-- registered, read from the schema's own description: a number schema turns
-- the token into a number with `tonumber`, a boolean schema accepts the words
-- in `BOOLEAN_WORDS`, and everything else stays a string. A token that does
-- not convert stays a string, and the schema refuses it with its own message.

-- The names `getmetatable` returns for SchemaKit nodes and sealed schemas,
-- which set `__metatable`. Used only to tell a schema from a plain list.
local SCHEMA_METATABLE_NAMES = { ["SchemaKit.Schema"] = true, ["SchemaKit.Node"] = true }

---Whether `value` is a SchemaKit node or sealed schema.
---@param value any
---@return boolean
local function isSchema(value)
  return type(value) == "table" and SCHEMA_METATABLE_NAMES[getmetatable(value)] == true
end

---Seal a node or schema, or raise at the caller naming `label`.
---@param value any
---@param label string argument description, used in the argument error
---@param level integer stack level the failure is reported at
---@return table schema
local function sealSchema(value, label, level)
  if not isSchema(value) then
    error(label .. " must be a SchemaKit schema", level)
  end
  local ok, schema = pcall(rawget(SchemaKit, "Seal"), SchemaKit, value)
  if not ok then
    error(label .. " must be a SchemaKit schema", level)
  end
  return schema
end

---Whether every entry of `values` has the Lua type `typeName`.
---@param values any[]
---@param typeName string
---@return boolean
local function allOfType(values, typeName)
  for index = 1, #values do
    if type(values[index]) ~= typeName then
      return false
    end
  end
  return #values > 0
end

---The coercion a token needs before a schema described by `description`
---checks it: `"number"`, `"boolean"` or `"string"` (none).
---@param description table a SchemaKit description
---@return string
local function coercionOf(description)
  local kind = description.kind
  if kind == "number" or kind == "boolean" then
    return kind
  end
  if kind == "enum" then
    if allOfType(description.values, "number") then
      return "number"
    end
    if allOfType(description.values, "boolean") then
      return "boolean"
    end
  end
  return "string"
end

---Convert one token as `coercion` says; a token that does not convert is
---returned unchanged, for the schema to refuse.
---@param token any
---@param coercion string
---@return any
local function coerce(token, coercion)
  if type(token) ~= "string" then
    return token
  end
  if coercion == "number" then
    local number = tonumber(token)
    if number ~= nil then
      return number
    end
  elseif coercion == "boolean" then
    local word = BOOLEAN_WORDS[token:lower()]
    if word ~= nil then
      return word
    end
  end
  return token
end

---Join the string forms of `values` with `separator`.
---@param values any[]
---@param separator string
---@return string
local function joinValues(values, separator)
  local strings = {}
  for index = 1, #values do
    strings[index] = tostring(values[index])
  end
  return table.concat(strings, separator)
end

---The usage word of one argument, from its schema description: `<number>`,
---`<integer 1..10>`, `<on|off>`, `<a|b|c>`, `<text>`; square brackets when the
---argument may be left out.
---@param description table a SchemaKit description
---@return string
local function usageWord(description)
  local kind = description.kind
  local word
  if kind == "number" then
    word = description.integer and "integer" or "number"
    if type(description.min) ~= "nil" and type(description.max) ~= "nil" then
      word = word .. " " .. tostring(description.min) .. ".." .. tostring(description.max)
    end
  elseif kind == "boolean" then
    word = "on|off"
  elseif kind == "enum" then
    word = joinValues(description.values, "|")
  elseif kind == "string" then
    if type(description.oneOf) == "table" then
      word = joinValues(description.oneOf, "|")
    else
      word = "text"
    end
  elseif kind == "array" then
    word = usageWord(description.of):sub(2, -2) .. "..."
    local min = description.min
    if type(min) == "nil" or (type(min) == "number" and not helpers.isSecret(min) and min == 0) then
      return "[" .. word .. "]"
    end
    return "<" .. word .. ">"
  else
    word = kind
  end
  if description.optional then
    return "[" .. word .. "]"
  end
  return "<" .. word .. ">"
end

---Compile a spec's `arguments` field.
---@param arguments any
---@param label string argument description, used in the argument errors
---@param level integer stack level the failures are reported at
---@param maxPositions number the scope's `maxPositions`, `math.huge` when unbounded
---@return table compiled `{ mode, schemas, coercions, defaulted, count, usage }`
local function compileArguments(arguments, label, level, maxPositions)
  local compiled =
    { mode = "none", schemas = {}, coercions = {}, defaulted = {}, count = 0, usage = "" }
  if isSchema(arguments) then
    local schema = sealSchema(arguments, label, level + 1)
    local description = schema:Describe()
    if description.kind ~= "array" then
      error(label .. " must be a SchemaKit.array schema or a list of schemas", level)
    end
    compiled.mode = "array"
    compiled.schemas[1] = schema
    compiled.coercions[1] = coercionOf(description.of)
    compiled.usage = usageWord(description)
    return compiled
  end
  if type(arguments) ~= "table" or type(getmetatable(arguments)) ~= "nil" then
    error(label .. " must be a SchemaKit.array schema or a list of schemas", level)
  end
  local count = 0
  for key in next, arguments do
    if type(key) ~= "number" or key < 1 or key % 1 ~= 0 then
      error(label .. " must be a list of schemas", level)
    end
    -- Only a position past the limit is refused with the limit: any other
    -- key makes the table no list at all.
    if key > maxPositions then
      error(label .. " must be a list of at most " .. maxPositions .. " schemas", level)
    end
    count = count + 1
  end
  if count == 0 or type(arguments[count]) == "nil" then
    error(label .. " must be a non-empty list of schemas without holes", level)
  end
  local words = {}
  for position = 1, count do
    local schema = sealSchema(arguments[position], label .. "[" .. position .. "]", level + 1)
    local description = schema:Describe()
    compiled.schemas[position] = schema
    compiled.coercions[position] = coercionOf(description)
    compiled.defaulted[position] = type(description.default) ~= "nil"
    words[position] = usageWord(description)
  end
  compiled.mode = "positions"
  compiled.count = count
  compiled.usage = table.concat(words, " ")
  return compiled
end

---The message for a refused argument, from a SchemaKit failure. Read at once:
---the failure table belongs to the schema and is reused.
---@param prefix string `"argument 2"` or `"arguments"`
---@param failure table
---@return string
local function describeFailure(prefix, failure)
  local path = failure.path
  local where = prefix
  if type(path) == "string" and path ~= "" then
    if path:sub(1, 1) == "[" then
      where = prefix .. path
    else
      where = prefix .. "." .. path
    end
  end
  return where
    .. ": expected "
    .. tostring(failure.expected)
    .. ", found "
    .. tostring(failure.found)
end

-- Checking -------------------------------------------------------------------

---Coerce and check a command's arguments in place.
---@param scope CommandKit.Scope
---@param record table
---@param arguments any[]
---@param count integer tokens after the command path
---@return integer|nil passCount how many arguments the handler receives
local function checkArguments(scope, record, arguments, count)
  local mode = record._mode
  if mode == "none" then
    return count
  end
  local schemas = record._schemas
  local coercions = record._coercions
  if mode == "array" then
    local coercion = coercions[1]
    for index = 1, count do
      arguments[index] = coerce(arguments[index], coercion)
    end
    local ok, failure = schemas[1]:Check(arguments)
    if not ok then
      helpers.failWithUsage(scope, record, describeFailure("arguments", failure))
      return nil
    end
    return count
  end
  local positions = record._positionCount
  if count > positions then
    local noun = positions == 1 and " argument" or " arguments"
    helpers.failWithUsage(scope, record, "expected at most " .. positions .. noun)
    return nil
  end
  local defaulted = record._defaulted
  for position = 1, positions do
    local schema = schemas[position]
    local value = coerce(arguments[position], coercions[position])
    local ok, failure = schema:Check(value)
    if not ok then
      helpers.failWithUsage(scope, record, describeFailure("argument " .. position, failure))
      return nil
    end
    if value == nil and defaulted[position] then
      -- `Check` never fills a default; `Apply` hands out a fresh copy
      -- of the one `SchemaKit.optional` declared.
      local applied, filled = schema:Apply(nil)
      if applied then
        value = filled
      end
    end
    arguments[position] = value
  end
  return positions
end

-- Commit ---------------------------------------------------------------------

rawset(parts, PART_NAME, {
  revision = PART_REVISION,
  compile = compileArguments,
  check = checkArguments,
})
helpers.SchemaKit = SchemaKit
helpers.BOOLEAN_WORDS = BOOLEAN_WORDS
helpers.joinValues = joinValues
-- Records an older core compiled are read here as they are (same fields), so
-- its kept functions are no longer needed.
state.legacyArguments = nil

return CommandKit
