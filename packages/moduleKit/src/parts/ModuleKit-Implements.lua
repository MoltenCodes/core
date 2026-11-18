-- MoltenCodes ModuleKit part Implements
--
-- `implements` contracts (docs/API.md, "Implements contracts"): a module
-- definition, or the options of a `Provide*` method, may state what its value
-- must carry, either as a dense array of method names or as a SchemaKit node
-- or sealed schema. ModuleKit checks it exactly once per value: at
-- registration for a value provider and a module, and when the factory's
-- result arrives for a lazy provider, before that result is cached. The
-- contract is compiled at registration into a record kept on the provider, so
-- a resolution pays one lookup per declared name and allocates nothing when
-- the value conforms. Messages never format the checked value: they name the
-- provider or module, the member, and a type name.
--
-- The part needs ModuleKit's core loaded first (docs/decisions/
-- 0001-kit-core-and-parts.md). It fills two entries of the core's
-- `state.dispatch`, `compileImplements` and `checkImplements`, which the core
-- calls for a definition's `implements` field and the Injection part calls for
-- a provider's `implements` option. It calls the core only through
-- `state.helpers`, read at call time, so a core upgraded after this part
-- loaded serves it. SchemaKit stays optional: the schema form finds it at
-- registration through `Registry:Find`.
--
-- Contents
-- --------
--   Constants ........ identity, SchemaKit's package and metatable names
--   Dependencies ..... ModuleKit's core and its state
--   Contracts ........ the list form, the schema form, the check
--   Commit ........... dispatch entries and the part's revision

-- Constants ------------------------------------------------------------------

local PART_NAME = "Implements"
local PART_REVISION = 1
local REQUIRED_REGISTRY_API = 2
local CORE_PACKAGE, CORE_API = "moduleKit", 1
-- The core interface this part reads (`state.helpers`, `state.dispatch`).
-- ModuleKit's core publishes the number.
local REQUIRED_PART_INTERFACE = 1

-- The package ID and API generation of SchemaKit, the one optional package the
-- schema form of `implements` needs. It is found at registration, never at
-- load, because nothing guarantees it has loaded before this file.
local SCHEMA_KIT_PACKAGE = "schemaKit"
local SCHEMA_KIT_API = 1

-- The names `getmetatable` returns for SchemaKit nodes and sealed schemas,
-- which set `__metatable` to them. They tell a schema from a method list even
-- when SchemaKit is not loaded, which is what the refusal for that case needs.
local SCHEMA_METATABLE_NAMES = { ["SchemaKit.Schema"] = true, ["SchemaKit.Node"] = true }

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
  error("MoltenCodes ModuleKit part Implements requires ModuleKit API 1 to be loaded first", 2)
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

-- Contracts ------------------------------------------------------------------

---Whether `value` presents itself as a SchemaKit node or sealed schema.
---@param value any
---@return boolean
local function isSchemaLike(value)
  if type(value) ~= "table" then
    return false
  end
  -- `__metatable` is the caller's to set, so what `getmetatable` returns is
  -- checked before it is used as a key.
  local metatableName = getmetatable(value)
  if helpers.isSecret(metatableName) then
    return false
  end
  return SCHEMA_METATABLE_NAMES[metatableName] == true
end

---Compile the list form of `implements`: a dense array of distinct non-empty
---strings, copied so a later edit of the caller's table changes nothing.
---@param list table
---@param label string argument description, used in the argument errors
---@param level integer stack level the failure is reported at
---@return string[] names
local function compileImplementsNames(list, label, level)
  local isSecret = helpers.isSecret
  local count = 0
  for key in next, list do
    -- A secret key cannot be a dense-array index, and comparing it would
    -- raise here, so it is refused as a density failure first.
    if isSecret(key) or type(key) ~= "number" or key < 1 or key % 1 ~= 0 then
      error(label .. " must be a dense array of method names or a SchemaKit schema", level)
    end
    count = count + 1
  end
  if count == 0 then
    error(label .. " must name at least one method", level)
  end

  -- `count` positive-integer keys form a dense array only when every index
  -- from 1 to `count` is present; a hole anywhere is a density failure, not a
  -- bad entry.
  local names = {}
  local seen = {}
  for index = 1, count do
    local name = rawget(list, index)
    if type(name) == "nil" then
      error(label .. " must be a dense array of method names or a SchemaKit schema", level)
    end
    if isSecret(name) then
      error(label .. " entries must not be secret values", level)
    end
    if type(name) ~= "string" or name == "" then
      error(label .. " entries must be non-empty strings", level)
    end
    if seen[name] == true then
      error(label .. ' names "' .. name .. '" twice', level)
    end
    seen[name] = true
    names[index] = name
  end
  return names
end

---Compile the schema form of `implements`: seal the node or schema through the
---loaded SchemaKit, so the contract owns its failure record and cannot race
---the consumer's own checks on the same schema.
---@param candidate table a value `isSchemaLike` accepted
---@param label string argument description, used in the argument errors
---@param level integer stack level the failure is reported at
---@return table schema a sealed SchemaKit schema
local function compileImplementsSchema(candidate, label, level)
  local SchemaKit = helpers.findOptionalPackage(SCHEMA_KIT_PACKAGE, SCHEMA_KIT_API)
  if type(SchemaKit) == "nil" then
    error(
      label .. " is a SchemaKit schema, but SchemaKit API " .. SCHEMA_KIT_API .. " is not loaded",
      level
    )
  end
  local seal = rawget(SchemaKit, "Seal")
  if type(seal) ~= "function" then
    error(label .. " must be a SchemaKit node or sealed schema", level)
  end
  local ok, schema = pcall(seal, SchemaKit, candidate)
  if not ok or type(schema) ~= "table" then
    error(label .. " must be a SchemaKit node or sealed schema", level)
  end
  return schema
end

---Compile an `implements` declaration into a contract record, or `nil` when
---none was declared.
---@param candidate any the caller's `implements` value
---@param label string argument description, used in the argument errors
---@param level integer stack level the failure is reported at
---@return table|nil contract `{ names = string[] }` or `{ schema = table }`
local function compileImplements(candidate, label, level)
  if type(candidate) == "nil" then
    return nil
  end
  if type(candidate) ~= "table" then
    error(label .. " must be a dense array of method names or a SchemaKit schema", level)
  end
  if isSchemaLike(candidate) then
    return { schema = compileImplementsSchema(candidate, label, level + 1) }
  end
  return { names = compileImplementsNames(candidate, label, level + 1) }
end

---Render a SchemaKit failure record for a message. SchemaKit never puts the
---checked value in the record, so the rendering is secret-safe.
---@param failure table `{ path, rule, expected, found }`
---@return string
local function describeSchemaFailure(failure)
  local path = rawget(failure, "path")
  local where = ""
  if type(path) == "string" and path ~= "" then
    where = "at " .. path .. ", "
  end
  return where
    .. "expected "
    .. tostring(rawget(failure, "expected"))
    .. ", found "
    .. tostring(rawget(failure, "found"))
end

---Check `value` against a compiled contract, raising at `level` on the first
---member or schema rule it fails. Allocates nothing when the value conforms.
---@param contract table|nil the record `compileImplements` returned
---@param value any the provided value or the module table
---@param subject string what is checked, for the message: `provider "Database"` or `module "Inventory"`
---@param level integer stack level the failure is reported at
local function checkImplements(contract, value, subject, level)
  if contract == nil then
    return
  end

  local schema = contract.schema
  if schema ~= nil then
    local ok, failure = schema:Check(value)
    if not ok then
      error(
        "ModuleKit "
          .. subject
          .. " does not match its implements schema: "
          .. describeSchemaFailure(failure),
        level
      )
    end
    return
  end

  local names = contract.names
  if type(value) ~= "table" then
    error(
      "ModuleKit "
        .. subject
        .. ' must implement "'
        .. names[1]
        .. '": the value is a '
        .. type(value)
        .. ", not a table",
      level
    )
  end
  for index = 1, #names do
    local name = names[index]
    local member = value[name]
    if type(member) == "nil" then
      error("ModuleKit " .. subject .. ' must implement "' .. name .. '": no such member', level)
    end
    if type(member) ~= "function" then
      error(
        "ModuleKit "
          .. subject
          .. ' must implement "'
          .. name
          .. '": member "'
          .. name
          .. '" is a '
          .. type(member)
          .. ", not a function",
        level
      )
    end
  end
end

-- Commit ---------------------------------------------------------------------

local dispatch = state.dispatch
dispatch.compileImplements = compileImplements
dispatch.checkImplements = checkImplements

-- Recorded last: a part that failed to load above is never reported installed.
state.parts[PART_NAME] = { revision = PART_REVISION }

return ModuleKit
