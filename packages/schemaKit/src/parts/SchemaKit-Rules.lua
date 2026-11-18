-- MoltenCodes SchemaKit part Rules
--
-- The builders whose rules need more than a type and bounds: a `string`
-- node's `pattern` (validated when the node is built, so `Check` can never
-- raise inside SchemaKit on a malformed one), `SchemaKit.custom` and
-- `SchemaKit.oneOf`. The core's checker keeps every kind, so a node built
-- while this part was loaded checks the same in a session without it.
--
-- The part needs SchemaKit's core loaded first (API 1, revision 7 or later:
-- the first with `state.parts`, `state.dispatch` and `state.helpers`). It
-- calls the core only through `state.helpers`, read at call time, so an
-- upgraded core serves it.
--
-- Contents
-- --------
--   Constants ........ identity, kinds, the pattern specials
--   Dependencies ..... SchemaKit's core and its state
--   Patterns ......... the whole-pattern walk `string.find` would make
--   Builders ......... compilePattern, oneOf, custom
--   Commit ........... members, dispatch entry and the part's revision

-- Constants ------------------------------------------------------------------

local PART_NAME = "Rules"
local PART_REVISION = 1
local REQUIRED_REGISTRY_API = 2
local CORE_PACKAGE, CORE_API = "schemaKit", 1

-- Node kinds this part builds or refuses inside (node layout 2).
local KIND_OPTIONAL = "optional"
local KIND_ONE_OF = "oneOf"
local KIND_CUSTOM = "custom"

-- Lua 5.1's `string.find` treats a pattern without one of these characters as
-- plain text, and never interprets it. The class is the `SPECIALS` string of
-- `lstrlib.c` written as a Lua pattern.
local PATTERN_SPECIALS = "[%^%$%*%+%?%.%(%[%%%-]"

local find = string.find
local byte = string.byte
local sub = string.sub

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
if
  type(state) ~= "table"
  or type(rawget(state, "parts")) ~= "table"
  or type(rawget(state, "dispatch")) ~= "table"
  or type(rawget(state, "helpers")) ~= "table"
then
  error("MoltenCodes SchemaKit part Rules requires SchemaKit API 1 to be loaded first", 2)
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

local dispatch = rawget(state, "dispatch")
-- Read at call time, never copied: an upgraded core's helpers serve this part.
local helpers = rawget(state, "helpers")
-- The shared limits; `maxPatternCaptures` is read when a pattern is walked.
local limits = rawget(state, "limits")

-- Patterns -------------------------------------------------------------------

---Return the index just past the single-character class that starts at
---`index` (`x`, `%x` or a `[...]` set), or `nil` when the class is malformed.
---Mirrors `classEnd` in Lua 5.1's `lstrlib.c`, including a `]` or `%]` right
---after `[` or `[^` being a member of the set rather than its end.
---@param pattern string
---@param index integer
---@param length integer
---@return integer?
local function patternClassEnd(pattern, index, length)
  local character = sub(pattern, index, index)
  index = index + 1
  if character == "%" then
    if index > length then
      return nil
    end
    return index + 1
  elseif character == "[" then
    if sub(pattern, index, index) == "^" then
      index = index + 1
    end
    repeat
      if index > length then
        return nil
      end
      local member = sub(pattern, index, index)
      index = index + 1
      if member == "%" and index <= length then
        index = index + 1
      end
    until sub(pattern, index, index) == "]"
    return index + 1
  end
  return index
end

---Whether `string.find` can use `pattern` on every subject without raising.
---
---Lua 5.1 reports a malformed pattern only when matching reaches the broken
---part, so a pattern such as `"a["` finds nothing in `""` without complaint
---and raises on `"ab"`. Trying the pattern once when the node is built is
---therefore not enough: `Check` would raise from inside SchemaKit on the
---first string that gets that far. This walks the whole pattern the way the
---matcher would and refuses every construct the matcher raises on: a trailing
---`%`, an unclosed `[`, `%b` without two characters, `%f` without a set, a
---back-reference to a capture that is not closed, an unbalanced `(` or `)`,
---and more captures than the `maxPatternCaptures` limit (at most 32, the
---matcher's own ceiling).
---@param pattern string
---@return boolean
local function isValidPattern(pattern)
  -- The matcher stops at the first NUL byte, so nothing after it matters.
  local nulIndex = find(pattern, "\0", 1, true)
  if type(nulIndex) ~= "nil" then
    pattern = sub(pattern, 1, nulIndex - 1)
  end
  if type(find(pattern, PATTERN_SPECIALS)) == "nil" then
    return true
  end

  local length = #pattern
  local index = 1
  if sub(pattern, 1, 1) == "^" then
    index = 2
  end
  local captureCount = 0
  local openCaptures = {}
  local openCount = 0
  local closedCaptures = {}
  while index <= length do
    local character = sub(pattern, index, index)
    local following = sub(pattern, index + 1, index + 1)
    if character == "(" then
      captureCount = captureCount + 1
      if captureCount > rawget(limits, "maxPatternCaptures") then
        return false
      end
      if following == ")" then
        -- A position capture is complete at once.
        closedCaptures[captureCount] = true
        index = index + 2
      else
        openCount = openCount + 1
        openCaptures[openCount] = captureCount
        index = index + 1
      end
    elseif character == ")" then
      if openCount == 0 then
        return false
      end
      closedCaptures[openCaptures[openCount]] = true
      openCount = openCount - 1
      index = index + 1
    elseif character == "$" and index == length then
      index = index + 1
    elseif character == "%" and following == "b" then
      if index + 3 > length then
        return false
      end
      index = index + 4
    elseif character == "%" and following == "f" then
      index = index + 2
      if sub(pattern, index, index) ~= "[" then
        return false
      end
      local classEnd = patternClassEnd(pattern, index, length)
      if classEnd == nil then
        return false
      end
      index = classEnd
    elseif character == "%" and type(find(following, "^%d$")) ~= "nil" then
      local captureIndex = byte(following) - 48
      if closedCaptures[captureIndex] ~= true then
        return false
      end
      index = index + 2
    else
      local classEnd = patternClassEnd(pattern, index, length)
      if classEnd == nil then
        return false
      end
      index = classEnd
      local quantifier = sub(pattern, index, index)
      if quantifier == "*" or quantifier == "+" or quantifier == "-" or quantifier == "?" then
        index = index + 1
      end
    end
  end
  return openCount == 0
end

-- Builders -------------------------------------------------------------------

---Validate `pattern` and store it on the `string` node being built. The core's
---`string` builder calls this through `state.dispatch.compilePattern`.
---@param node table the compiled string node
---@param pattern any the spec's `pattern` field
---@param level integer stack level the failure is reported at
local function compilePattern(node, pattern, level)
  if type(pattern) ~= "string" or helpers.isSecret(pattern) or pattern == "" then
    error("SchemaKit.string pattern must be a non-empty string", level)
  end
  if not isValidPattern(pattern) then
    error("SchemaKit.string pattern is not a valid Lua pattern", level)
  end
  node.pattern = pattern
  node.expectedPattern = "string matching " .. helpers.quote(pattern)
end

---Describe a value that matches at least one of `alternatives`, tried in order.
---@param alternatives (SchemaKit.Node|SchemaKit.Schema)[]
---@return SchemaKit.Node
local function buildOneOf(alternatives)
  helpers.refuseColonCall(alternatives, "SchemaKit.oneOf", 3)
  local length = helpers.validateList(alternatives, "SchemaKit.oneOf alternatives", 3)
  local compiled = {}
  local expected = ""
  for index = 1, length do
    local alternative =
      helpers.resolveChild(alternatives[index], "SchemaKit.oneOf alternatives[" .. index .. "]", 3)
    if alternative.kind == KIND_OPTIONAL then
      error("SchemaKit.oneOf alternatives must not be optional; wrap the oneOf instead", 2)
    end
    compiled[index] = alternative
    expected = expected .. (index == 1 and "" or " or ") .. alternative.expected
  end

  local node = helpers.newCompiledNode(KIND_ONE_OF, expected)
  node.alternatives = compiled
  return helpers.publishNode(node)
end

---Describe a value accepted by `check`, which returns a truthy value for an
---acceptable one. `description` is what a failure reports as expected.
---@param check fun(value: any): boolean
---@param description string
---@return SchemaKit.Node
local function buildCustom(check, description)
  helpers.refuseColonCall(check, "SchemaKit.custom", 3)
  if type(check) ~= "function" then
    error("SchemaKit.custom check must be a function", 2)
  end
  if type(description) ~= "string" or helpers.isSecret(description) or description == "" then
    error("SchemaKit.custom description must be a non-empty string", 2)
  end
  local node = helpers.newCompiledNode(KIND_CUSTOM, description)
  node.check = check
  return helpers.publishNode(node)
end

-- Commit ---------------------------------------------------------------------

rawset(SchemaKit, "oneOf", buildOneOf)
rawset(SchemaKit, "custom", buildCustom)
rawset(dispatch, "compilePattern", compilePattern)
rawset(parts, PART_NAME, { revision = PART_REVISION })
helpers.adoptPart(PART_NAME)

return SchemaKit
