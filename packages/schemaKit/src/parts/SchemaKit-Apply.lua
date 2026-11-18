-- MoltenCodes SchemaKit part Apply
--
-- `schema:Apply(value)`: a checked copy of `value` with every declared default
-- filled in. `Apply` is two passes over the same schema. The first builds a
-- copy and fills every declared default where the value is `nil`; it is
-- tolerant and simply keeps a value it cannot copy (wrong type, too deep, too
-- large, a secret), because the second pass, an ordinary check of the copy,
-- reports that value with the same rule and path `Check` would.
--
-- The part needs SchemaKit's core loaded first (API 1, revision 7 or later:
-- the first with `state.parts` and `state.helpers`). It calls the core only
-- through `state.helpers`, read at call time, so an upgraded core serves it.
--
-- Contents
-- --------
--   Constants ........ identity, kinds
--   Dependencies ..... SchemaKit's core and its state
--   Copying .......... one copier per container kind
--   Apply ............ the method
--   Commit ........... the member and the part's revision

-- Constants ------------------------------------------------------------------

local PART_NAME = "Apply"
local PART_REVISION = 1
local REQUIRED_REGISTRY_API = 2
local CORE_PACKAGE, CORE_API = "schemaKit", 1

-- Node kinds the copy descends into (node layout 2).
local KIND_OPTIONAL = "optional"
local KIND_TABLE = "table"
local KIND_ARRAY = "array"
local KIND_MAP = "map"
local KIND_ONE_OF = "oneOf"

-- Dependencies ---------------------------------------------------------------

-- The shared MoltenCodes namespace is the one documented global handoff point between independently embedded copies.
-- selene: allow(global_usage)
local moltenCodes = rawget(_G, "MoltenCodes")
local generations = type(moltenCodes) == "table" and rawget(moltenCodes, "Registries") or nil
local Registry = type(generations) == "table" and rawget(generations, REQUIRED_REGISTRY_API) or nil
local SchemaKit = nil
if type(Registry) == "table" and type(rawget(Registry, "Get")) == "function" then
  SchemaKit = Registry:Get(CORE_PACKAGE, CORE_API)
end
local state = type(SchemaKit) == "table" and rawget(SchemaKit, "_state") or nil
local Schema = type(SchemaKit) == "table" and rawget(SchemaKit, "Schema") or nil
if
  type(state) ~= "table"
  or type(rawget(state, "parts")) ~= "table"
  or type(rawget(state, "helpers")) ~= "table"
  or type(Schema) ~= "table"
then
  error("MoltenCodes SchemaKit part Apply requires SchemaKit API 1 to be loaded first", 2)
end

local parts = rawget(state, "parts")
local installed = rawget(parts, PART_NAME)
if
  type(installed) == "table"
  and type(installed.revision) == "number"
  and installed.revision >= PART_REVISION
then
  -- An equal or newer revision of this part already serves every schema.
  return SchemaKit
end

-- Read at call time, never copied: an upgraded core's helpers serve this part.
local helpers = rawget(state, "helpers")
local limits = rawget(state, "limits")

-- The `maxDepth` limit, read from the shared limits at the start of every
-- `Apply`, so the copiers compare an upvalue.
local maxDepth = 16

-- Copying --------------------------------------------------------------------

local copyNode

---Count `value`'s entries, stopping at `limit + 1`.
---@param value table
---@param limit integer
---@return integer
local function countEntries(value, limit)
  local count = 0
  for _ in next, value do
    count = count + 1
    if count > limit then
      return count
    end
  end
  return count
end

---@param record SchemaKit.Record
---@param node SchemaKit.CompiledNode
---@param value any
---@param depth integer
---@param isSecret (fun(value: any): boolean)?
---@return any
local function copyTable(record, node, value, depth, isSecret)
  if type(value) ~= "table" or depth > maxDepth then
    return value
  end

  local result = {}
  local names = node.fieldNames --[[@as string[] ]]
  local nodes = node.fieldNodes --[[@as SchemaKit.CompiledNode[] ]]
  for index = 1, #names do
    local name = names[index]
    result[name] = copyNode(record, nodes[index], rawget(value, name), depth + 1, isSecret)
  end

  -- Undeclared fields of an open table are kept as they are, unchecked and
  -- shared. A closed table with one is kept whole, for the check to refuse.
  local fieldSet = node.fieldSet --[[@as table]]
  for key, entry in next, value do
    if fieldSet[key] == nil then
      if not node.open then
        return value
      end
      result[key] = entry
    end
  end
  return result
end

---@param record SchemaKit.Record
---@param node SchemaKit.CompiledNode
---@param value any
---@param depth integer
---@param isSecret (fun(value: any): boolean)?
---@return any
local function copyArray(record, node, value, depth, isSecret)
  if type(value) ~= "table" or depth > maxDepth then
    return value
  end
  local count = countEntries(value, node.max --[[@as integer]])
  if count > node.max then
    return value
  end

  local result = {}
  local elementNode = node.of --[[@as SchemaKit.CompiledNode]]
  for index = 1, count do
    local element = rawget(value, index)
    if type(element) == "nil" then
      return value
    end
    result[index] = copyNode(record, elementNode, element, depth + 1, isSecret)
  end
  return result
end

---@param record SchemaKit.Record
---@param node SchemaKit.CompiledNode
---@param value any
---@param depth integer
---@param isSecret (fun(value: any): boolean)?
---@return any
local function copyMap(record, node, value, depth, isSecret)
  if type(value) ~= "table" or depth > maxDepth then
    return value
  end
  if
    countEntries(value, node.max --[[@as integer]]) > node.max
  then
    return value
  end

  local result = {}
  local valueNode = node.values --[[@as SchemaKit.CompiledNode]]
  for key, entry in next, value do
    result[key] = copyNode(record, valueNode, entry, depth + 1, isSecret)
  end
  return result
end

---@param record SchemaKit.Record
---@param node SchemaKit.CompiledNode
---@param value any
---@param depth integer
---@param isSecret (fun(value: any): boolean)?
---@return any
local function copyOneOf(record, node, value, depth, isSecret)
  -- The first alternative whose filled copy checks is the one applied.
  local alternatives = node.alternatives --[[@as SchemaKit.CompiledNode[] ]]
  local saved = record.segmentCount
  for index = 1, #alternatives do
    local alternative = alternatives[index]
    local copied = copyNode(record, alternative, value, depth, isSecret)
    local accepted = helpers.checkNode(record, alternative, copied, depth, isSecret)
    helpers.restoreSegments(record, saved)
    if accepted then
      return copied
    end
  end
  return value
end

---Copy `value` as `node` describes it, filling defaults where it is `nil`.
---@param record SchemaKit.Record
---@param node SchemaKit.CompiledNode
---@param value any
---@param depth integer
---@param isSecret (fun(value: any): boolean)?
---@return any
copyNode = function(record, node, value, depth, isSecret)
  if isSecret ~= nil and isSecret(value) then
    return value
  end

  local kind = node.kind
  if kind == KIND_OPTIONAL then
    if type(value) == "nil" then
      if not node.hasDefault then
        return nil
      end
      -- The default goes through the inner schema like any value, so
      -- the defaults declared inside it are filled in too.
      value = helpers.copyPlain(node.default)
    end
    node = node.inner --[[@as SchemaKit.CompiledNode]]
    kind = node.kind
  end

  if kind == KIND_TABLE then
    return copyTable(record, node, value, depth, isSecret)
  elseif kind == KIND_ARRAY then
    return copyArray(record, node, value, depth, isSecret)
  elseif kind == KIND_MAP then
    return copyMap(record, node, value, depth, isSecret)
  elseif kind == KIND_ONE_OF then
    return copyOneOf(record, node, value, depth, isSecret)
  end
  return value
end

-- Apply ----------------------------------------------------------------------

---Return `true` and a copy of `value` with every declared default filled in,
---or `false` and the failure when the filled copy does not check. Allocates.
---@param self SchemaKit.Schema
---@param value any
---@return boolean ok
---@return any copyOrFailure
local function schemaApply(self, value)
  local record = helpers.recordOf(self, "SchemaKit.Schema:Apply", 3)
  local isSecret = helpers.currentSecretProbe()
  maxDepth = rawget(limits, "maxDepth")
  local copied = copyNode(record, record.root, value, 1, isSecret)
  local ok, failure = helpers.runCheck(record, copied, isSecret)
  if ok then
    return true, copied
  end
  return false, failure
end

-- Commit ---------------------------------------------------------------------

rawset(Schema, "Apply", schemaApply)
rawset(parts, PART_NAME, { revision = PART_REVISION })
helpers.adoptPart(PART_NAME)

return SchemaKit
