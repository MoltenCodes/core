-- MoltenCodes SchemaKit
--
-- One validation core for the values a Kit or an addon receives from outside
-- its own code: API arguments, saved variables, options and received
-- messages. A schema is described with builders, sealed once, and then checks
-- values with a structured failure (path, rule, expected, found) that never
-- contains the offending value.
--
-- SchemaKit is pure Lua. The one host facility it reads is `issecretvalue`
-- (Retail 12.x): the checker looks it up at every check, so a probe installed
-- later is seen; the argument checks use the shared probe rule (read at load,
-- read again per call only when it was absent at load). Without it nothing is
-- secret.
--
-- This file is the core (docs/decisions/0001-kit-core-and-parts.md). Two
-- optional parts hold the builders only some schemas need:
-- `SchemaKit-Rules.lua` (string patterns, `custom`, `oneOf`) and
-- `SchemaKit-Apply.lua` (`schema:Apply`). The checker keeps every kind, so a
-- schema built while a part was loaded checks the same without it.
--
-- Contents
-- --------
--   Constants ............. identity, limits, kinds, rules, fixed phrases
--   Public types .......... LuaCATS declarations for the published surface
--   Dependencies .......... Registry
--   Validation ............ public-surface and shared-state predicates
--   Bootstrap ............. Registry registration and inherited state
--   Limits ................ the shared limits and their file-local copies
--   Formatting ............ numbers, literals and path segments for messages
--   Failure recording ..... the per-schema record, rules, the path stack
--   Checking .............. the compiled checker, one function per kind
--   Plain copies .......... declared defaults, copied and bounded
--   Describing ............ the plain description for documentation and UIs
--   Argument checks ....... specs, children, bounds and receivers
--   Builders .............. the functions that create schema nodes
--   Schema methods ........ Check, Assert, Describe
--   Package public API .... Seal, SetLimits, GetLimits, GetLimit
--   Parts ................. the part interface, stubs, kept members, HasPart
--   Node layout upgrade ... rebuilding layout 1 nodes as layout 2
--   Commit ................ prototype/facade assignment and self-check
--
-- The compiled form is described in `docs/INTERNALS.md`.

-- Constants ------------------------------------------------------------------

local PACKAGE_NAME = "schemaKit"
local API_GENERATION = 1
local IMPLEMENTATION_REVISION = 7
local REQUIRED_REGISTRY_API = 2
local STATE_SCHEMA = 1

-- Every compiled node and every schema record carries the layout it was built
-- with, so a later revision that changes a layout can recognise and upgrade
-- old ones instead of guessing from which fields exist. Layout 2 (revision 6)
-- holds only the fields a node uses; layout 1 held every field, `false` when
-- unused. The checker tests fields for truth, so it reads both.
local NODE_LAYOUT = 2
local RECORD_LAYOUT = 1

-- The defaults of the four shared limits (see `SetLimits` and docs/API.md
-- "Limits"). Each is read through a file-local copy the Limits section keeps
-- in step with `state.limits`, so a hot path reads an upvalue, never a table.
--
-- `maxDepth`: how many nested tables a checked value may have, counting the
-- outermost. A value nested deeper fails with rule "depth" however the schema
-- is built, so the work a hostile value can cause is bounded by the schema's
-- own shape.
local MAX_DEPTH = 16

-- `defaultArrayMax`: an array schema without `max` accepts at most this many
-- elements. A map has no default: its `max` is required, because a map is
-- what a hostile message would inflate.
local DEFAULT_ARRAY_MAX = 1024

-- `pathKeyLimit`: a key shown in a failure path is cut to this many
-- characters. Map keys can come from a received message, and a path must stay
-- short and printable.
local PATH_KEY_LIMIT = 32

-- `maxPatternCaptures`: the most captures a `string` pattern may open.
-- `LUA_MAXCAPTURES` in Lua 5.1: a pattern opening more captures raises.
local MAX_PATTERN_CAPTURES = 32

-- Hard ceilings `SetLimits` refuses to pass, each with the reason a larger
-- value is unsafe. `defaultArrayMax` has none: an array's elements are the
-- consumer's own data, already in memory, and SchemaKit retains none of them.
local LIMIT_CEILINGS = {
  maxDepth = 64,
  maxPatternCaptures = 32,
  pathKeyLimit = 1024,
}
local LIMIT_CEILING_REASONS = {
  maxDepth = "checking, applying and default validation recurse once per nesting level of a value its sender shapes",
  maxPatternCaptures = "Lua 5.1 raises on a pattern with more than 32 captures (LUA_MAXCAPTURES)",
  pathKeyLimit = "failure paths print keys a received message chooses",
}

local KIND_STRING = "string"
local KIND_NUMBER = "number"
local KIND_BOOLEAN = "boolean"
local KIND_ENUM = "enum"
local KIND_TABLE = "table"
local KIND_ARRAY = "array"
local KIND_MAP = "map"
local KIND_OPTIONAL = "optional"
local KIND_ONE_OF = "oneOf"
local KIND_ANY = "any"
local KIND_CUSTOM = "custom"

local RULE_SECRET = "secret"
local RULE_REQUIRED = "required"
local RULE_TYPE = "type"
local RULE_MIN = "min"
local RULE_MAX = "max"
local RULE_INTEGER = "integer"
local RULE_PATTERN = "pattern"
local RULE_ENUM = "enum"
local RULE_UNKNOWN = "unknown"
local RULE_SEQUENCE = "sequence"
local RULE_DEPTH = "depth"
local RULE_ONE_OF = "oneOf"
local RULE_CUSTOM = "custom"

-- Fixed `found` phrases. A failure describes what it found by type or by a
-- phrase from this list, never by the value itself.
local FOUND_SECRET = "secret value"
local FOUND_NIL = "nil"
local FOUND_NAN = "NaN"
local FOUND_FRACTION = "fractional number"
local FOUND_INFINITE = "infinite number"
local FOUND_SMALLER = "smaller number"
local FOUND_LARGER = "larger number"
local FOUND_NON_MATCHING = "non-matching string"
local FOUND_UNDECLARED = "undeclared field"
local FOUND_SEQUENCE = "table with keys outside 1 to n"
local FOUND_DEPTH = "table nested deeper"
local FOUND_UNLISTED = {
  string = "unlisted string",
  number = "unlisted number",
  boolean = "unlisted boolean",
}

local EXPECTED_DECLARED = "only declared fields"
local EXPECTED_SEQUENCE = "array with keys 1 to n"
local EXPECTED_ANY = "any value"

-- The complete set of fields each spec and option table accepts.
local STRING_SPEC_KEYS = { min = true, max = true, pattern = true, oneOf = true }
local NUMBER_SPEC_KEYS = { min = true, max = true, integer = true }
local TABLE_SPEC_KEYS = { fields = true, open = true }
local ARRAY_SPEC_KEYS = { of = true, min = true, max = true }
local MAP_SPEC_KEYS = { keys = true, values = true, max = true }
local SEAL_OPTION_KEYS = { freshFailures = true }

-- The published surface, listed once so the public-surface predicate reads as
-- a checklist instead of a long boolean expression.
local FACADE_FUNCTIONS = {
  "string",
  "number",
  "boolean",
  "enum",
  "table",
  "array",
  "map",
  "optional",
  "oneOf",
  "any",
  "custom",
  "Seal",
  "SetLimits",
  "GetLimits",
  "GetLimit",
  "HasPart",
}
local SCHEMA_METHODS = { "Check", "Assert", "Apply", "Describe" }

local find = string.find
local format = string.format
local byte = string.byte
local gsub = string.gsub
local sub = string.sub
local floor = math.floor
local HUGE = math.huge

-- Public types ---------------------------------------------------------------

---Spec accepted by `SchemaKit.string`.
---@class SchemaKit.StringSpec
---@field min integer? Fewest characters (bytes). At least `0`.
---@field max integer? Most characters (bytes). At least `min`.
---@field pattern string? A Lua pattern the string must contain; anchor it with `^` and `$` to match the whole string. Needs the Rules part.
---@field oneOf string[]? The only strings accepted.

---Spec accepted by `SchemaKit.number`.
---@class SchemaKit.NumberSpec
---@field min number? Smallest accepted value, inclusive.
---@field max number? Largest accepted value, inclusive.
---@field integer boolean? Accept finite whole numbers only.

---Spec accepted by `SchemaKit.table`.
---@class SchemaKit.TableSpec
---@field fields table<string, SchemaKit.Node|SchemaKit.Schema> Required. The declared fields by name.
---@field open boolean? Accept fields that are not declared, unchecked. Defaults to `false`.

---Spec accepted by `SchemaKit.array`.
---@class SchemaKit.ArraySpec
---@field of SchemaKit.Node|SchemaKit.Schema Required. The schema of every element.
---@field min integer? Fewest elements. Defaults to `0`.
---@field max integer? Most elements. Defaults to the `defaultArrayMax` limit (`1024`).

---Spec accepted by `SchemaKit.map`.
---@class SchemaKit.MapSpec
---@field keys SchemaKit.Node|SchemaKit.Schema Required. The schema of every key.
---@field values SchemaKit.Node|SchemaKit.Schema Required. The schema of every value.
---@field max integer Required. Most entries.

---Options accepted by `SchemaKit:Seal`.
---@class SchemaKit.SealOptions
---@field freshFailures boolean? Return a new failure table from every failing call instead of the schema's reused one.

---A failed check. By default the same table is returned by every failing call
---on one schema and overwritten by the next; copy the fields you keep.
---@class SchemaKit.Failure
---@field path string Where the failure is, for example `frames[3].point`; `""` for the value itself.
---@field rule SchemaKit.Rule The rule that failed.
---@field expected string What the schema accepts there.
---@field found string The type or a fixed description of what was found; never the value.

---@alias SchemaKit.Rule
---| "secret"
---| "required"
---| "type"
---| "min"
---| "max"
---| "integer"
---| "pattern"
---| "enum"
---| "unknown"
---| "sequence"
---| "depth"
---| "oneOf"
---| "custom"

---An immutable, unsealed schema node returned by a builder. It has no methods
---of its own: pass it to another builder or to `SchemaKit:Seal`.
---@class SchemaKit.Node

---A plain description of a schema, freshly built by `schema:Describe()`.
---@class SchemaKit.Description
---@field kind string `string`, `number`, `boolean`, `enum`, `table`, `array`, `map`, `oneOf`, `any` or `custom`.
---@field optional boolean? `true` when `nil` is accepted.
---@field default any? The default `Apply` fills in, as a fresh copy.
---@field min number? String length, number or array bound.
---@field max number? String length, number, array or map bound.
---@field pattern string? String pattern.
---@field oneOf string[]? Accepted strings.
---@field integer boolean? Number accepts whole numbers only.
---@field values any[]|SchemaKit.Description? Enum values in declaration order, or the schema of a map's values.
---@field fields table<string, SchemaKit.Description>? Table fields by name.
---@field fieldNames string[]? Table field names, sorted.
---@field open boolean? Table accepts undeclared fields.
---@field of SchemaKit.Description? Array element schema.
---@field keys SchemaKit.Description? Map key schema.
---@field alternatives SchemaKit.Description[]? `oneOf` alternatives in order.
---@field description string? A custom check's description.

---A sealed schema. Immutable and safe to share across addons.
---@class SchemaKit.Schema
---@field Check fun(self: SchemaKit.Schema, value: any): boolean, SchemaKit.Failure?
---@field Assert fun(self: SchemaKit.Schema, value: any, argumentName: string?, level: integer?): any
---@field Apply fun(self: SchemaKit.Schema, value: any): boolean, any In the Apply part.
---@field Describe fun(self: SchemaKit.Schema): SchemaKit.Description

---The SchemaKit package facade published through Registry. Builders are
---called with a dot (`SchemaKit.string{ max = 32 }`); `Seal` with a colon.
---@class SchemaKit
---@field API integer Public API generation.
---@field REVISION integer Compatible implementation revision.
---@field MAX_DEPTH integer Default of the `maxDepth` limit (`16`).
---@field DEFAULT_ARRAY_MAX integer Default of the `defaultArrayMax` limit (`1024`).
---@field UNBOUNDED table Sentinel `SetLimits{ defaultArrayMax }` accepts to lift the default array bound; one table shared by every revision.
---@field Schema SchemaKit.Schema Shared sealed-schema prototype.
---@field string fun(spec: SchemaKit.StringSpec?): SchemaKit.Node
---@field number fun(spec: SchemaKit.NumberSpec?): SchemaKit.Node
---@field boolean fun(): SchemaKit.Node
---@field enum fun(values: any[]): SchemaKit.Node
---@field table fun(spec: SchemaKit.TableSpec): SchemaKit.Node
---@field array fun(spec: SchemaKit.ArraySpec): SchemaKit.Node
---@field map fun(spec: SchemaKit.MapSpec): SchemaKit.Node
---@field optional fun(schema: SchemaKit.Node|SchemaKit.Schema, default: any?): SchemaKit.Node
---@field oneOf fun(alternatives: (SchemaKit.Node|SchemaKit.Schema)[]): SchemaKit.Node In the Rules part.
---@field any fun(): SchemaKit.Node
---@field custom fun(check: fun(value: any): boolean, description: string): SchemaKit.Node In the Rules part.
---@field Seal fun(self: SchemaKit, node: SchemaKit.Node|SchemaKit.Schema, options: SchemaKit.SealOptions?): SchemaKit.Schema
---@field SetLimits fun(self: SchemaKit, limits: SchemaKit.Limits)
---@field GetLimits fun(self: SchemaKit): SchemaKit.Limits
---@field GetLimit fun(self: SchemaKit, name: string): integer|table
---@field HasPart fun(self: SchemaKit, partName: string): boolean Whether the named part (`"Rules"`, `"Apply"`) is loaded.

---The limits every consumer in the session shares. `SetLimits` accepts any
---subset; `GetLimits` returns all four in a fresh table.
---@class SchemaKit.Limits
---@field maxDepth integer? Most nested tables a checked value may have: `1` to `64`, default `16`.
---@field maxPatternCaptures integer? Most captures a `string` pattern may open: `1` to `32`, default `32`.
---@field pathKeyLimit integer? Characters of a key shown in a failure path: `1` to `1024`, default `32`.
---@field defaultArrayMax (integer|table)? Element bound of an array built without `max`: a positive integer or `SchemaKit.UNBOUNDED`, default `1024`.

---The private compiled form of one node. Fields a kind does not use are
---absent (layout 2) or `false` (layout 1, built before revision 6 and
---rebuilt by its upgrade). See `docs/INTERNALS.md`.
---@class SchemaKit.CompiledNode
---@field layout integer
---@field kind string
---@field expected string
---@field min number?
---@field max number?
---@field expectedMin string?
---@field expectedMax string?
---@field foundMax string?
---@field pattern string?
---@field expectedPattern string?
---@field valueSet table?
---@field valueList any[]?
---@field expectedEnum string?
---@field integer boolean?
---@field fieldNames string[]?
---@field fieldNodes SchemaKit.CompiledNode[]?
---@field fieldSet table<string, true>?
---@field open boolean?
---@field of SchemaKit.CompiledNode?
---@field keys SchemaKit.CompiledNode?
---@field values SchemaKit.CompiledNode?
---@field inner SchemaKit.CompiledNode?
---@field hasDefault boolean?
---@field default any
---@field alternatives SchemaKit.CompiledNode[]?
---@field check function?

---The private per-schema record behind one sealed schema.
---@class SchemaKit.Record
---@field layout integer
---@field root SchemaKit.CompiledNode
---@field failure SchemaKit.Failure
---@field segments any[]
---@field segmentCount integer
---@field freshFailures boolean

-- Dependencies ---------------------------------------------------------------

-- The shared MoltenCodes namespace is the one documented global handoff point between independently embedded copies.
-- selene: allow(global_usage)
local namespace = rawget(_G, "MoltenCodes")
local generations = type(namespace) == "table" and rawget(namespace, "Registries") or nil

-- Ask for Registry by generation and fall back to the alias. A future Registry
-- API generation takes over `MoltenCodes.Registry`, so reading the alias first
-- would hand this file a facade whose contract it was not written against.
local Registry = type(generations) == "table" and rawget(generations, REQUIRED_REGISTRY_API) or nil
if type(Registry) == "nil" and type(namespace) == "table" then
  Registry = rawget(namespace, "Registry")
end
if type(Registry) ~= "table" or rawget(Registry, "API") ~= REQUIRED_REGISTRY_API then
  error("MoltenCodes SchemaKit requires Registry API 2 to be loaded first", 2)
end

local bootstrapPackage = rawget(Registry, "Bootstrap")
if type(bootstrapPackage) ~= "function" then
  error("MoltenCodes SchemaKit requires a valid Registry API 2 facade", 2)
end

---Return the host's secret-value probe, or `nil` on a client without one.
---
---Read at every call rather than once at load: the probe costs one `rawget`,
---and a test or a later-loading shim that installs it is then seen at once.
---@return (fun(value: any): boolean)?
local function currentSecretProbe()
  -- issecretvalue is a World of Warcraft client API reachable only through the global table.
  -- selene: allow(global_usage)
  local probe = rawget(_G, "issecretvalue")
  if type(probe) == "function" then
    return probe
  end
  return nil
end

-- Builders, `Seal` and `Assert` ask `isSecret` about a caller's flag, bound,
-- literal, pattern, description, name or level before testing, comparing or
-- doing arithmetic on it, each of which raises on a secret inside SchemaKit.
-- The checker passes `currentSecretProbe()` along instead, one read per check.
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

-- Validation -----------------------------------------------------------------

---Whether every name in `names` is a function field of `container`.
---@param container table
---@param names string[]
---@return boolean
local function hasFunctions(container, names)
  for index = 1, #names do
    if type(rawget(container, names[index])) ~= "function" then
      return false
    end
  end
  return true
end

---Whether `implementation` exposes the complete SchemaKit API 1 surface.
---@param implementation any shared package table handed back by Registry
---@return boolean
local function validatePublicSurface(implementation)
  if
    type(implementation) ~= "table"
    or rawget(implementation, "API") ~= API_GENERATION
    or type(rawget(implementation, "REVISION")) ~= "number"
    or type(rawget(implementation, "Schema")) ~= "table"
    or type(rawget(implementation, "UNBOUNDED")) ~= "table"
  then
    return false
  end

  return hasFunctions(implementation, FACADE_FUNCTIONS)
    and hasFunctions(rawget(implementation, "Schema"), SCHEMA_METHODS)
end

---Whether `currentState` has the fields every API 1 revision shares.
---@param currentState any
---@return boolean
local function validateStateBase(currentState)
  return type(currentState) == "table"
    and rawget(currentState, "schema") == STATE_SCHEMA
    and type(rawget(currentState, "runtimeRevision")) == "number"
    and type(rawget(currentState, "nodes")) == "table"
    and type(rawget(currentState, "records")) == "table"
    and type(rawget(currentState, "nodeMetatable")) == "table"
    and type(rawget(currentState, "schemaMetatable")) == "table"
    and type(rawget(currentState, "unbounded")) == "table"
    and type(rawget(currentState, "limits")) == "table"
end

---Whether `implementation` carries package state of this revision's schema,
---and publishes the sentinel that state keeps.
---@param implementation table
---@return boolean
local function validateCurrentState(implementation)
  local currentState = rawget(implementation, "_state")
  return validateStateBase(currentState)
    and type(rawget(currentState, "parts")) == "table"
    and type(rawget(currentState, "dispatch")) == "table"
    and type(rawget(currentState, "helpers")) == "table"
    and rawget(implementation, "UNBOUNDED") == rawget(currentState, "unbounded")
end

-- Bootstrap ------------------------------------------------------------------

-- `Registry:Bootstrap` owns the reconciliation every embedded package repeats:
-- look the package up, refuse to reinterpret state owned by a newer revision,
-- and register this one. What stays here is what only SchemaKit can answer.
local SchemaKit, previousRevision, selected = bootstrapPackage(Registry, {
  package = PACKAGE_NAME,
  api = API_GENERATION,
  revision = IMPLEMENTATION_REVISION,
  label = "MoltenCodes SchemaKit",
  validatePublicSurface = validatePublicSurface,
  validateState = validateCurrentState,
})

if type(SchemaKit) == "nil" then
  -- An equal or newer compatible revision already owns the shared package table.
  return selected
end

local Schema = rawget(SchemaKit, "Schema")
local state = rawget(SchemaKit, "_state")

if type(previousRevision) == "nil" then
  if Schema ~= nil or state ~= nil then
    error("MoltenCodes SchemaKit package state is corrupted or incomplete", 2)
  end

  Schema = {}
  state = {
    schema = STATE_SCHEMA,
    runtimeRevision = 0,
    -- Node proxy -> compiled node, and sealed schema -> record. Both are
    -- weak-keyed: a proxy nobody holds any more can be collected, while
    -- the compiled nodes stay alive through the parents that use them.
    nodes = setmetatable({}, { __mode = "k" }),
    records = setmetatable({}, { __mode = "k" }),
    nodeMetatable = {},
    schemaMetatable = {},
    -- `SchemaKit.UNBOUNDED` lives here so every revision publishes the
    -- same table.
    unbounded = {},
    -- The shared limits; `SetLimits` writes here, so a limit a consumer
    -- set survives an in-place upgrade.
    limits = {
      maxDepth = MAX_DEPTH,
      maxPatternCaptures = MAX_PATTERN_CAPTURES,
      pathKeyLimit = PATH_KEY_LIMIT,
      defaultArrayMax = DEFAULT_ARRAY_MAX,
    },
  }
  rawset(SchemaKit, "Schema", Schema)
  rawset(SchemaKit, "_state", state)
elseif type(Schema) ~= "table" or not validateStateBase(state) then
  error("MoltenCodes SchemaKit package state is corrupted or incomplete", 2)
end

-- The metatables, the prototype and both weak tables are kept across
-- upgrades, so nodes and schemas built by an older copy keep working and run
-- this copy's checker.
local NODE_METATABLE = rawget(state, "nodeMetatable")
local SCHEMA_METATABLE = rawget(state, "schemaMetatable")
local compiledNodes = rawget(state, "nodes")
local schemaRecords = rawget(state, "records")
local UNBOUNDED = rawget(state, "unbounded")
local sharedLimits = rawget(state, "limits")

-- The part interface (see "Parts" below). `parts` and `dispatch` are kept
-- across upgrades: a part's entries outlive the core revision that was loaded
-- when the part installed them. Revision 6 and older had neither.
if type(rawget(state, "parts")) ~= "table" then
  rawset(state, "parts", {})
end
if type(rawget(state, "dispatch")) ~= "table" then
  rawset(state, "dispatch", {})
end
local installedParts = rawget(state, "parts")
local dispatch = rawget(state, "dispatch")

-- Limits ---------------------------------------------------------------------
--
-- `state.limits` is the one copy every revision reads. The checker, the
-- formatter and the builders read these file-local copies instead, refreshed
-- here at load (so an upgrade inherits what a consumer set) and by
-- `SetLimits`.

local maxDepth = MAX_DEPTH
local expectedDepth = ""
local pathKeyLimit = PATH_KEY_LIMIT
-- `math.huge` while `defaultArrayMax` is `SchemaKit.UNBOUNDED`.
local defaultArrayMax = DEFAULT_ARRAY_MAX

---Copy the shared limits into the file-local copies the hot paths read.
local function loadLimits()
  maxDepth = rawget(sharedLimits, "maxDepth")
  expectedDepth = "at most " .. maxDepth .. " nested tables"
  pathKeyLimit = rawget(sharedLimits, "pathKeyLimit")
  local arrayMax = rawget(sharedLimits, "defaultArrayMax")
  if type(arrayMax) == "number" then
    defaultArrayMax = arrayMax
  else
    defaultArrayMax = HUGE
  end
end

loadLimits()

-- Formatting -----------------------------------------------------------------
--
-- Everything formatted here is either the schema author's own constant (a
-- bound, a pattern, an enum value) or a key of a checked table. Keys cannot be
-- secret, because a secret raises when it is stored as a key. Checked values
-- are never formatted.

---@param value number
---@return string
local function formatNumber(value)
  return format("%.14g", value)
end

---Return the visible form of one byte `quote` escapes.
---@param character string
---@return string
local function escapeCharacter(character)
  if character == "|" then
    return "||"
  elseif character == "\\" then
    return "\\\\"
  elseif character == '"' then
    return '\\"'
  end
  return format("\\%03d", byte(character))
end

---Render a string for a message: quoted, with every byte that could change
---how the message displays made visible.
---
---`%q` is not enough in Lua 5.1: it leaves control bytes other than newline,
---carriage return and NUL as they are, and nothing escapes `|`, which starts
---a World of Warcraft escape sequence (`|T...|t` textures, `|H...|h` links,
---`|c` colours) in any text the client renders. `|` is doubled, which the
---client displays as one literal `|`; `\` and `"` are escaped as in Lua; and
---every other control byte (0 to 31, and 127) becomes `\ddd`.
---@param text string
---@return string
local function quote(text)
  local escaped = gsub(text, '[%c\127\\"|]', escapeCharacter)
  return '"' .. escaped .. '"'
end

---Render one enum value, which the builder restricts to strings, numbers and
---booleans.
---@param value string|number|boolean
---@return string
local function formatLiteral(value)
  local valueType = type(value)
  if valueType == "string" then
    return quote(value)
  elseif valueType == "number" then
    return formatNumber(value)
  end
  return tostring(value)
end

---Render one path segment. `isFirst` drops the leading dot of a name.
---@param key any
---@param isFirst boolean
---@return string
local function formatSegment(key, isFirst)
  local keyType = type(key)
  if keyType == "string" then
    if #key <= pathKeyLimit and type(find(key, "^[%a_][%w_]*$")) ~= "nil" then
      if isFirst then
        return key
      end
      return "." .. key
    end
    local shown = key
    if #shown > pathKeyLimit then
      -- Never cut inside a UTF-8 sequence: while the first byte left
      -- out is a continuation byte (0x80 to 0xBF), leave out one more,
      -- so the cut falls before the sequence's lead byte.
      local cut = pathKeyLimit
      local nextByte = byte(key, cut + 1)
      while cut > 0 and nextByte >= 0x80 and nextByte <= 0xBF do
        cut = cut - 1
        nextByte = byte(key, cut + 1)
      end
      shown = sub(key, 1, cut) .. "..."
    end
    return "[" .. quote(shown) .. "]"
  elseif keyType == "number" then
    return "[" .. formatNumber(key) .. "]"
  elseif keyType == "boolean" then
    return "[" .. tostring(key) .. "]"
  end
  -- A table, function or userdata key has no printable identity that is
  -- stable or safe, so its type stands in for it.
  return "[" .. keyType .. "]"
end

-- Failure recording ----------------------------------------------------------
--
-- Checking records a failure in two halves. The leaf that fails writes the
-- rule, expected and found phrases into the record's failure table. Then every
-- container on the way back up pushes the key it was checking onto the
-- record's segment stack. Nothing is pushed while a value is valid, so a valid
-- check allocates nothing; the path string is built once, at the top, only
-- for a failure.

---@param root SchemaKit.CompiledNode
---@param freshFailures boolean
---@return SchemaKit.Record
local function newRecord(root, freshFailures)
  return {
    layout = RECORD_LAYOUT,
    root = root,
    failure = { path = "", rule = RULE_TYPE, expected = "", found = "" },
    segments = {},
    segmentCount = 0,
    freshFailures = freshFailures,
  }
end

---Record a leaf failure and return `false`, so a checker can `return fail(...)`.
---@param record SchemaKit.Record
---@param rule SchemaKit.Rule
---@param expected string
---@param found string
---@return boolean
local function fail(record, rule, expected, found)
  local failure = record.failure
  failure.rule = rule
  failure.expected = expected
  failure.found = found
  return false
end

---Push the key a container was checking when its child failed; returns `false`.
---@param record SchemaKit.Record
---@param key any
---@return boolean
local function pushSegment(record, key)
  local count = record.segmentCount + 1
  record.segmentCount = count
  record.segments[count] = key
  return false
end

---Drop every segment above `count`, releasing the keys they referenced.
---@param record SchemaKit.Record
---@param count integer
local function restoreSegments(record, count)
  local segments = record.segments
  for index = record.segmentCount, count + 1, -1 do
    segments[index] = nil
  end
  record.segmentCount = count
end

---Build the path from the segment stack, empty the stack, and return the
---failure the caller receives: the reused table, or a copy of it.
---@param record SchemaKit.Record
---@return SchemaKit.Failure
local function finishFailure(record)
  local segments = record.segments
  local path = ""
  -- Segments were pushed innermost first, so the path is read backwards.
  for index = record.segmentCount, 1, -1 do
    path = path .. formatSegment(segments[index], index == record.segmentCount)
  end
  restoreSegments(record, 0)

  local failure = record.failure
  failure.path = path
  if record.freshFailures then
    return {
      path = path,
      rule = failure.rule,
      expected = failure.expected,
      found = failure.found,
    }
  end
  return failure
end

---Build the one-line message `Assert` and the builders raise.
---@param subject string what was checked, for example an argument name
---@param failure SchemaKit.Failure
---@return string
local function formatFailure(subject, failure)
  local path = failure.path
  local location = subject
  if path ~= "" then
    if sub(path, 1, 1) == "[" then
      location = subject .. path
    else
      location = subject .. "." .. path
    end
  end
  return location .. ": expected " .. failure.expected .. ", found " .. failure.found
end

-- Checking -------------------------------------------------------------------
--
-- One recursive function, `checkNode`, handles what every node shares (the
-- secret probe, `optional`, a required `nil`) and dispatches on `kind` to one
-- checker per kind. Checkers are file-local functions over the compiled node
-- table: no closure is created per node or per call. User tables are read with
-- `rawget` and `next`, so a metatable on a checked value cannot run code or
-- lie about its contents.

local checkNode

---@param record SchemaKit.Record
---@param node SchemaKit.CompiledNode
---@param value any
---@return boolean
local function checkString(record, node, value)
  if type(value) ~= "string" then
    return fail(record, RULE_TYPE, node.expected, type(value))
  end

  local valueSet = node.valueSet
  if valueSet and valueSet[value] == nil then
    return fail(record, RULE_ENUM, node.expectedEnum --[[@as string]], FOUND_UNLISTED.string)
  end

  local length = #value
  local min = node.min
  if min and length < min then
    return fail(record, RULE_MIN, node.expectedMin --[[@as string]], "string of length " .. length)
  end
  local max = node.max
  if max and length > max then
    return fail(record, RULE_MAX, node.expectedMax --[[@as string]], "string of length " .. length)
  end

  local pattern = node.pattern
  if pattern and type(find(value, pattern)) == "nil" then
    return fail(record, RULE_PATTERN, node.expectedPattern --[[@as string]], FOUND_NON_MATCHING)
  end
  return true
end

---@param record SchemaKit.Record
---@param node SchemaKit.CompiledNode
---@param value any
---@return boolean
local function checkNumber(record, node, value)
  if type(value) ~= "number" then
    return fail(record, RULE_TYPE, node.expected, type(value))
  end
  if value ~= value then
    return fail(record, RULE_TYPE, node.expected, FOUND_NAN)
  end

  if node.integer then
    if value == HUGE or value == -HUGE then
      return fail(record, RULE_INTEGER, node.expected, FOUND_INFINITE)
    end
    if floor(value) ~= value then
      return fail(record, RULE_INTEGER, node.expected, FOUND_FRACTION)
    end
  end

  local min = node.min
  if min and value < min then
    return fail(record, RULE_MIN, node.expectedMin --[[@as string]], FOUND_SMALLER)
  end
  local max = node.max
  if max and value > max then
    return fail(record, RULE_MAX, node.expectedMax --[[@as string]], FOUND_LARGER)
  end
  return true
end

---@param record SchemaKit.Record
---@param node SchemaKit.CompiledNode
---@param value any
---@return boolean
local function checkEnum(record, node, value)
  local valueSet = node.valueSet --[[@as table]]
  if valueSet[value] ~= nil then
    return true
  end
  local valueType = type(value)
  return fail(record, RULE_ENUM, node.expected, FOUND_UNLISTED[valueType] or valueType)
end

---@param record SchemaKit.Record
---@param node SchemaKit.CompiledNode
---@param value any
---@param depth integer
---@param secretProbe (fun(value: any): boolean)?
---@return boolean
local function checkTable(record, node, value, depth, secretProbe)
  if type(value) ~= "table" then
    return fail(record, RULE_TYPE, node.expected, type(value))
  end
  if depth > maxDepth then
    return fail(record, RULE_DEPTH, expectedDepth, FOUND_DEPTH)
  end

  -- Declared fields in sorted order, so which of several failing fields is
  -- reported does not depend on hash order.
  local names = node.fieldNames --[[@as string[] ]]
  local nodes = node.fieldNodes --[[@as SchemaKit.CompiledNode[] ]]
  for index = 1, #names do
    local name = names[index]
    if not checkNode(record, nodes[index], rawget(value, name), depth + 1, secretProbe) then
      return pushSegment(record, name)
    end
  end

  -- A closed table stops at its first undeclared key, so this loop runs at
  -- most once per declared field plus one, however large the value is.
  if not node.open then
    local fieldSet = node.fieldSet --[[@as table]]
    for key in next, value do
      if fieldSet[key] == nil then
        fail(record, RULE_UNKNOWN, EXPECTED_DECLARED, FOUND_UNDECLARED)
        return pushSegment(record, key)
      end
    end
  end
  return true
end

---@param record SchemaKit.Record
---@param node SchemaKit.CompiledNode
---@param value any
---@param depth integer
---@param secretProbe (fun(value: any): boolean)?
---@return boolean
local function checkArray(record, node, value, depth, secretProbe)
  if type(value) ~= "table" then
    return fail(record, RULE_TYPE, node.expected, type(value))
  end
  if depth > maxDepth then
    return fail(record, RULE_DEPTH, expectedDepth, FOUND_DEPTH)
  end

  -- Count the entries first, stopping one past the bound: an oversized
  -- table costs `max + 1` steps, never its full size.
  local max = node.max --[[@as integer]]
  local count = 0
  for _ in next, value do
    count = count + 1
    if count > max then
      return fail(
        record,
        RULE_MAX,
        node.expectedMax --[[@as string]],
        node.foundMax --[[@as string]]
      )
    end
  end
  if count < node.min then
    return fail(
      record,
      RULE_MIN,
      node.expectedMin --[[@as string]],
      "array of " .. count .. " elements"
    )
  end

  -- `count` entries with every index 1..count present means the keys are
  -- exactly 1..count: an array with no holes and no other keys.
  local elementNode = node.of --[[@as SchemaKit.CompiledNode]]
  for index = 1, count do
    local element = rawget(value, index)
    if type(element) == "nil" then
      return fail(record, RULE_SEQUENCE, EXPECTED_SEQUENCE, FOUND_SEQUENCE)
    end
    if not checkNode(record, elementNode, element, depth + 1, secretProbe) then
      return pushSegment(record, index)
    end
  end
  return true
end

---@param record SchemaKit.Record
---@param node SchemaKit.CompiledNode
---@param value any
---@param depth integer
---@param secretProbe (fun(value: any): boolean)?
---@return boolean
local function checkMap(record, node, value, depth, secretProbe)
  if type(value) ~= "table" then
    return fail(record, RULE_TYPE, node.expected, type(value))
  end
  if depth > maxDepth then
    return fail(record, RULE_DEPTH, expectedDepth, FOUND_DEPTH)
  end

  local max = node.max --[[@as integer]]
  local keyNode = node.keys --[[@as SchemaKit.CompiledNode]]
  local valueNode = node.values --[[@as SchemaKit.CompiledNode]]
  local count = 0
  for key, entry in next, value do
    count = count + 1
    if count > max then
      return fail(
        record,
        RULE_MAX,
        node.expectedMax --[[@as string]],
        node.foundMax --[[@as string]]
      )
    end
    if not checkNode(record, keyNode, key, depth + 1, secretProbe) then
      -- Only on failure: say that the key, not its value, is wrong.
      local failure = record.failure
      failure.expected = "key " .. failure.expected
      return pushSegment(record, key)
    end
    if not checkNode(record, valueNode, entry, depth + 1, secretProbe) then
      return pushSegment(record, key)
    end
  end
  return true
end

---@param record SchemaKit.Record
---@param node SchemaKit.CompiledNode
---@param value any
---@param depth integer
---@param secretProbe (fun(value: any): boolean)?
---@return boolean
local function checkOneOf(record, node, value, depth, secretProbe)
  local alternatives = node.alternatives --[[@as SchemaKit.CompiledNode[] ]]
  local saved = record.segmentCount
  for index = 1, #alternatives do
    if checkNode(record, alternatives[index], value, depth, secretProbe) then
      return true
    end
    -- The alternative's own path is not the answer; the oneOf is.
    restoreSegments(record, saved)
  end
  return fail(record, RULE_ONE_OF, node.expected, type(value))
end

---Check `value` against `node`, recording a failure in `record`.
---@param record SchemaKit.Record
---@param node SchemaKit.CompiledNode
---@param value any
---@param depth integer how many tables deep `value` is if it is a table
---@param secretProbe (fun(value: any): boolean)?
---@return boolean
checkNode = function(record, node, value, depth, secretProbe)
  -- First, before any comparison: comparing a secret, testing a secret
  -- boolean or using a secret as a key raises in the client.
  if secretProbe ~= nil and secretProbe(value) then
    return fail(record, RULE_SECRET, node.expected, FOUND_SECRET)
  end

  local kind = node.kind
  if kind == KIND_OPTIONAL then
    if type(value) == "nil" then
      return true
    end
    -- Builders never nest an optional directly inside another.
    node = node.inner --[[@as SchemaKit.CompiledNode]]
    kind = node.kind
  elseif type(value) == "nil" then
    return fail(record, RULE_REQUIRED, node.expected, FOUND_NIL)
  end

  if kind == KIND_STRING then
    return checkString(record, node, value)
  elseif kind == KIND_NUMBER then
    return checkNumber(record, node, value)
  elseif kind == KIND_BOOLEAN then
    if type(value) ~= "boolean" then
      return fail(record, RULE_TYPE, node.expected, type(value))
    end
    return true
  elseif kind == KIND_ENUM then
    return checkEnum(record, node, value)
  elseif kind == KIND_TABLE then
    return checkTable(record, node, value, depth, secretProbe)
  elseif kind == KIND_ARRAY then
    return checkArray(record, node, value, depth, secretProbe)
  elseif kind == KIND_MAP then
    return checkMap(record, node, value, depth, secretProbe)
  elseif kind == KIND_ONE_OF then
    return checkOneOf(record, node, value, depth, secretProbe)
  elseif kind == KIND_CUSTOM then
    local check = node.check --[[@as function]]
    local accepted = check(value)
    -- A secret answer cannot be tested without raising here, so it
    -- rejects the value like a falsy answer does.
    if secretProbe ~= nil and secretProbe(accepted) then
      return fail(record, RULE_CUSTOM, node.expected, type(value))
    end
    if accepted then
      return true
    end
    return fail(record, RULE_CUSTOM, node.expected, type(value))
  end
  -- KIND_ANY: every value but nil, which was refused above.
  return true
end

---Run a whole check from the top of `record`'s schema.
---@param record SchemaKit.Record
---@param value any
---@param secretProbe (fun(value: any): boolean)?
---@return boolean ok
---@return SchemaKit.Failure? failure
local function runCheck(record, value, secretProbe)
  restoreSegments(record, 0)
  if checkNode(record, record.root, value, 1, secretProbe) then
    return true
  end
  return false, finishFailure(record)
end

-- Plain copies -----------------------------------------------------------------
--
-- A declared default is stored and described as a plain copy. `Apply` (the
-- Apply part) fills those copies in; `optional` bounds them when built.

---Deep-copy a plain value: tables are copied, everything else is shared.
---Only called on defaults, which the `optional` builder bounded.
---@param value any
---@return any
local function copyPlain(value)
  if type(value) ~= "table" then
    return value
  end
  local result = {}
  for key, entry in next, value do
    result[key] = copyPlain(entry)
  end
  return result
end

---Whether `value` nests at most `maxDepth - depth + 1` further tables; a
---cyclic table never does.
---@param value any
---@param depth integer
---@return boolean
local function plainDepthWithin(value, depth)
  if type(value) ~= "table" then
    return true
  end
  if depth > maxDepth then
    return false
  end
  for _, entry in next, value do
    if not plainDepthWithin(entry, depth + 1) then
      return false
    end
  end
  return true
end

-- Describing -----------------------------------------------------------------

local describeNode

---@param list any[]
---@return any[]
local function copyList(list)
  local result = {}
  for index = 1, #list do
    result[index] = list[index]
  end
  return result
end

---Build a fresh plain description of `node`.
---@param node SchemaKit.CompiledNode
---@return SchemaKit.Description
describeNode = function(node)
  local kind = node.kind
  if kind == KIND_OPTIONAL then
    local description = describeNode(node.inner --[[@as SchemaKit.CompiledNode]])
    description.optional = true
    if node.hasDefault then
      description.default = copyPlain(node.default)
    end
    return description
  end

  ---@type SchemaKit.Description
  local description = { kind = kind }
  if kind == KIND_STRING then
    description.min = node.min or nil
    description.max = node.max or nil
    description.pattern = node.pattern or nil
    if node.valueList then
      description.oneOf = copyList(node.valueList --[[@as any[] ]])
    end
  elseif kind == KIND_NUMBER then
    description.min = node.min or nil
    description.max = node.max or nil
    description.integer = node.integer == true
  elseif kind == KIND_ENUM then
    description.values = copyList(node.valueList --[[@as any[] ]])
  elseif kind == KIND_TABLE then
    local names = node.fieldNames --[[@as string[] ]]
    local nodes = node.fieldNodes --[[@as SchemaKit.CompiledNode[] ]]
    local fields = {}
    for index = 1, #names do
      fields[names[index]] = describeNode(nodes[index])
    end
    description.fields = fields
    description.fieldNames = copyList(names)
    description.open = node.open == true
  elseif kind == KIND_ARRAY then
    description.of = describeNode(node.of --[[@as SchemaKit.CompiledNode]])
    description.min = node.min or nil
    -- An array built under an unbounded default has no `max` to describe.
    if node.max ~= HUGE then
      description.max = node.max or nil
    end
  elseif kind == KIND_MAP then
    description.keys = describeNode(node.keys --[[@as SchemaKit.CompiledNode]])
    description.values = describeNode(node.values --[[@as SchemaKit.CompiledNode]])
    description.max = node.max or nil
  elseif kind == KIND_ONE_OF then
    local alternatives = node.alternatives --[[@as SchemaKit.CompiledNode[] ]]
    local described = {}
    for index = 1, #alternatives do
      described[index] = describeNode(alternatives[index])
    end
    description.alternatives = described
  elseif kind == KIND_CUSTOM then
    description.description = node.expected
  end
  return description
end

-- Argument checks ------------------------------------------------------------
--
-- Argument validation raises with an explicit stack level so the reported
-- position is the line that called the builder or method, never a line inside
-- SchemaKit. `level` is always the value `error` needs *inside the function
-- that receives it*, so every further hop towards `error` adds exactly one.
-- Messages name the parameter and never format the value that was passed.

---Refuse a builder called with a colon: `SchemaKit:string{}` hands the facade
---in as the first argument.
---@param argument any
---@param label string
---@param level integer
local function refuseColonCall(argument, label, level)
  if rawequal(argument, SchemaKit) then
    error(label .. " is called with a dot, not a colon", level)
  end
end

---Return the alphabetically first key of `options` outside `allowedKeys`, as
---it appears in a message, or `nil` when every key is allowed. Sorting makes
---the reported field independent of hash order.
---@param options table
---@param allowedKeys table<string, true>
---@return string?
local function firstUnknownField(options, allowedKeys)
  local firstUnknown = nil
  for key in next, options do
    if allowedKeys[key] ~= true then
      local text = type(key) == "string" and key or "<" .. type(key) .. " key>"
      if firstUnknown == nil or text < firstUnknown then
        firstUnknown = text
      end
    end
  end
  return firstUnknown
end

---Refuse a non-table spec and any field outside `allowedKeys`, reporting the
---alphabetically first unknown field.
---@param spec any
---@param allowedKeys table<string, true>
---@param label string
---@param level integer
local function validateSpecKeys(spec, allowedKeys, label, level)
  if type(spec) ~= "table" then
    error(label .. " spec must be a table", level)
  end
  local firstUnknown = firstUnknownField(spec, allowedKeys)
  if firstUnknown ~= nil then
    error(label .. ' spec contains unknown field "' .. firstUnknown .. '"', level)
  end
end

---Whether `value` is a non-negative integer. A secret number answers `false`
---before it is compared, so every caller refuses it with its own message.
---@param value any
---@return boolean
local function isNonNegativeInteger(value)
  return type(value) == "number"
    and not isSecret(value)
    and value == value
    and value >= 0
    and value ~= HUGE
    and floor(value) == value
end

---Validate an optional non-negative integer bound.
---@param value any
---@param label string e.g. "SchemaKit.string min"
---@param level integer
local function validateCount(value, label, level)
  if type(value) ~= "nil" and not isNonNegativeInteger(value) then
    error(label .. " must be a non-negative integer", level)
  end
end

---Return the compiled node behind a node proxy or a sealed schema.
---@param child any
---@param label string
---@param level integer
---@return SchemaKit.CompiledNode
local function resolveChild(child, label, level)
  if type(child) == "table" then
    local compiled = compiledNodes[child]
    if compiled ~= nil then
      return compiled
    end
    local record = schemaRecords[child]
    if record ~= nil then
      return record.root
    end
  end
  error(label .. " must be a SchemaKit schema node or sealed schema", level)
end

---Return `list`'s length when its keys are exactly 1..n, otherwise `nil`.
---@param list table
---@return integer?
local function sequenceLength(list)
  local count = 0
  for _ in next, list do
    count = count + 1
  end
  for index = 1, count do
    if type(rawget(list, index)) == "nil" then
      return nil
    end
  end
  return count
end

---Validate a non-empty array argument, returning its length.
---@param list any
---@param label string
---@param level integer
---@return integer
local function validateList(list, label, level)
  -- A single node or schema is a table too, and an empty one: name the
  -- mistake instead of calling it an empty list.
  if type(list) ~= "table" or compiledNodes[list] ~= nil or schemaRecords[list] ~= nil then
    error(label .. " must be an array", level)
  end
  local length = sequenceLength(list)
  if length == nil then
    error(label .. " must be an array without holes or other keys", level)
  end
  if length == 0 then
    error(label .. " must not be empty", level)
  end
  return length
end

---Wrap a compiled node in an immutable proxy and return the proxy.
---@param compiled SchemaKit.CompiledNode
---@return SchemaKit.Node
local function publishNode(compiled)
  local proxy = setmetatable({}, NODE_METATABLE)
  compiledNodes[proxy] = compiled
  return proxy
end

---Return a compiled node of `kind` holding only its layout, kind and
---expected phrase. The builder sets the fields its kind uses; every other
---field stays absent. A fixed shape with `false` placeholders buys nothing in
---Lua 5.1 (a missing key reads as fast as a `false` one) and cost a 32-slot
---hash part per node (1 344 B) where most nodes use 3 to 7 fields.
---@param kind string
---@param expected string
---@return SchemaKit.CompiledNode
local function newCompiledNode(kind, expected)
  return { layout = NODE_LAYOUT, kind = kind, expected = expected }
end

---Build the "one of ..." phrase and the lookup set for a list of literals.
---@param list any[]
---@param length integer
---@param label string
---@param level integer
---@return table<any, true> set
---@return any[] copy
---@return string expected
local function compileLiterals(list, length, label, level)
  local set = {}
  local copy = {}
  local rendered = ""
  for index = 1, length do
    local value = list[index]
    local valueType = type(value)
    -- A secret literal is refused before the NaN test and the set lookup,
    -- which compare it and use it as a key.
    if
      (valueType ~= "string" and valueType ~= "number" and valueType ~= "boolean")
      or isSecret(value)
    then
      error(label .. " values must be strings, numbers or booleans", level)
    end
    if value ~= value then
      error(label .. " values must not be NaN", level)
    end
    if set[value] ~= nil then
      error(label .. " values must not repeat", level)
    end
    set[value] = true
    copy[index] = value
    rendered = rendered .. (index == 1 and "" or ", ") .. formatLiteral(value)
  end
  return set, copy, "one of " .. rendered
end

-- Builders -------------------------------------------------------------------

---Describe a string, optionally bounded in length, matched against a pattern
---or restricted to a list.
---@param spec SchemaKit.StringSpec?
---@return SchemaKit.Node
local function buildString(spec)
  refuseColonCall(spec, "SchemaKit.string", 3)
  local node = newCompiledNode(KIND_STRING, "string")
  if type(spec) == "nil" then
    return publishNode(node)
  end
  validateSpecKeys(spec, STRING_SPEC_KEYS, "SchemaKit.string", 3)

  local min, max = rawget(spec, "min"), rawget(spec, "max")
  validateCount(min, "SchemaKit.string min", 3)
  validateCount(max, "SchemaKit.string max", 3)
  if type(min) ~= "nil" and type(max) ~= "nil" and min > max then
    error("SchemaKit.string min must not be greater than max", 2)
  end
  if type(min) ~= "nil" then
    node.min = min
    node.expectedMin = "string of at least " .. min .. " characters"
  end
  if type(max) ~= "nil" then
    node.max = max
    node.expectedMax = "string of at most " .. max .. " characters"
  end

  local pattern = rawget(spec, "pattern")
  if type(pattern) ~= "nil" then
    -- The Rules part validates and compiles the pattern; without it the
    -- default entry raises the not-loaded message at the caller's line.
    dispatch.compilePattern(node, pattern, 3)
  end

  local oneOf = rawget(spec, "oneOf")
  if type(oneOf) ~= "nil" then
    local length = validateList(oneOf, "SchemaKit.string oneOf", 3)
    for index = 1, length do
      if type(oneOf[index]) ~= "string" then
        error("SchemaKit.string oneOf must list strings only", 2)
      end
    end
    node.valueSet, node.valueList, node.expectedEnum =
      compileLiterals(oneOf, length, "SchemaKit.string oneOf", 3)
    -- A restricted string is described by its list everywhere.
    node.expected = node.expectedEnum --[[@as string]]
  end
  return publishNode(node)
end

---Describe a number, optionally bounded and restricted to whole numbers.
---@param spec SchemaKit.NumberSpec?
---@return SchemaKit.Node
local function buildNumber(spec)
  refuseColonCall(spec, "SchemaKit.number", 3)
  local node = newCompiledNode(KIND_NUMBER, "number")
  if type(spec) == "nil" then
    return publishNode(node)
  end
  validateSpecKeys(spec, NUMBER_SPEC_KEYS, "SchemaKit.number", 3)

  local integer = rawget(spec, "integer")
  if type(integer) ~= "nil" and (type(integer) ~= "boolean" or isSecret(integer)) then
    error("SchemaKit.number integer must be a boolean", 2)
  end
  -- Stored only when set, so a plain number node keeps to its three fields.
  if integer == true then
    node.integer = true
  end
  local noun = integer == true and "integer" or "number"
  node.expected = noun

  local min, max = rawget(spec, "min"), rawget(spec, "max")
  -- `issecretvalue` first: the NaN test compares the bound with itself.
  if type(min) ~= "nil" and (type(min) ~= "number" or isSecret(min) or min ~= min) then
    error("SchemaKit.number min must be a number", 2)
  end
  if type(max) ~= "nil" and (type(max) ~= "number" or isSecret(max) or max ~= max) then
    error("SchemaKit.number max must be a number", 2)
  end
  if type(min) ~= "nil" and type(max) ~= "nil" and min > max then
    error("SchemaKit.number min must not be greater than max", 2)
  end
  if type(min) ~= "nil" then
    node.min = min
    node.expectedMin = noun .. " >= " .. formatNumber(min)
  end
  if type(max) ~= "nil" then
    node.max = max
    node.expectedMax = noun .. " <= " .. formatNumber(max)
  end
  return publishNode(node)
end

---Describe a boolean.
---@return SchemaKit.Node
local function buildBoolean(...)
  local argument = ...
  refuseColonCall(argument, "SchemaKit.boolean", 3)
  if select("#", ...) > 0 then
    error("SchemaKit.boolean takes no arguments", 2)
  end
  return publishNode(newCompiledNode(KIND_BOOLEAN, "boolean"))
end

---Describe a value that must equal one of `values` (strings, numbers or
---booleans).
---@param values any[]
---@return SchemaKit.Node
local function buildEnum(values)
  refuseColonCall(values, "SchemaKit.enum", 3)
  local length = validateList(values, "SchemaKit.enum values", 3)
  local node = newCompiledNode(KIND_ENUM, "")
  local set, copy, expected = compileLiterals(values, length, "SchemaKit.enum", 3)
  node.valueSet = set
  node.valueList = copy
  node.expected = expected
  return publishNode(node)
end

---Describe a table with named fields, closed to other fields unless `open`.
---@param spec SchemaKit.TableSpec
---@return SchemaKit.Node
local function buildTable(spec)
  refuseColonCall(spec, "SchemaKit.table", 3)
  validateSpecKeys(spec, TABLE_SPEC_KEYS, "SchemaKit.table", 3)

  local fields = rawget(spec, "fields")
  -- A node or a sealed schema is a table with no keys of its own, which
  -- would otherwise be read as a table schema with no fields at all.
  if type(fields) ~= "table" or compiledNodes[fields] ~= nil or schemaRecords[fields] ~= nil then
    error("SchemaKit.table fields must be a table of schema nodes by name", 2)
  end
  local open = rawget(spec, "open")
  if type(open) ~= "nil" and (type(open) ~= "boolean" or isSecret(open)) then
    error("SchemaKit.table open must be a boolean", 2)
  end

  local names = {}
  for name in next, fields do
    if type(name) ~= "string" or name == "" then
      error("SchemaKit.table field names must be non-empty strings", 2)
    end
    names[#names + 1] = name
  end
  table.sort(names)

  local nodes = {}
  local fieldSet = {}
  for index = 1, #names do
    local name = names[index]
    nodes[index] = resolveChild(rawget(fields, name), "SchemaKit.table fields." .. name, 3)
    fieldSet[name] = true
  end

  local node = newCompiledNode(KIND_TABLE, "table")
  node.fieldNames = names
  node.fieldNodes = nodes
  node.fieldSet = fieldSet
  if open == true then
    node.open = true
  end
  return publishNode(node)
end

---Describe an array: keys exactly 1..n, every element matching `of`.
---@param spec SchemaKit.ArraySpec
---@return SchemaKit.Node
local function buildArray(spec)
  refuseColonCall(spec, "SchemaKit.array", 3)
  validateSpecKeys(spec, ARRAY_SPEC_KEYS, "SchemaKit.array", 3)

  local of = resolveChild(rawget(spec, "of"), "SchemaKit.array of", 3)
  local min, max = rawget(spec, "min"), rawget(spec, "max")
  validateCount(min, "SchemaKit.array min", 3)
  validateCount(max, "SchemaKit.array max", 3)
  min = min or 0
  -- The default is read when the node is built, so a node keeps the bound it
  -- was built with whatever `SetLimits` does later. `math.huge` stands for
  -- `SchemaKit.UNBOUNDED`: the count check never fires, and no message
  -- ever names that bound.
  max = max or defaultArrayMax
  if min > max then
    error("SchemaKit.array min must not be greater than max", 2)
  end

  local node = newCompiledNode(KIND_ARRAY, "array")
  node.of = of
  node.min = min
  node.max = max
  node.expectedMin = "array of at least " .. min .. " elements"
  if max ~= HUGE then
    node.expectedMax = "array of at most " .. max .. " elements"
    node.foundMax = "table with more than " .. max .. " entries"
  end
  return publishNode(node)
end

---Describe a map: every key matching `keys`, every value matching `values`,
---at most `max` entries.
---@param spec SchemaKit.MapSpec
---@return SchemaKit.Node
local function buildMap(spec)
  refuseColonCall(spec, "SchemaKit.map", 3)
  validateSpecKeys(spec, MAP_SPEC_KEYS, "SchemaKit.map", 3)

  local keys = resolveChild(rawget(spec, "keys"), "SchemaKit.map keys", 3)
  if keys.kind == KIND_OPTIONAL then
    error("SchemaKit.map keys must not be optional", 2)
  end
  local values = resolveChild(rawget(spec, "values"), "SchemaKit.map values", 3)
  local max = rawget(spec, "max")
  if type(max) == "nil" then
    error("SchemaKit.map max is required", 2)
  end
  if not isNonNegativeInteger(max) or max < 1 then
    error("SchemaKit.map max must be a positive integer", 2)
  end

  local node = newCompiledNode(KIND_MAP, "table")
  node.keys = keys
  node.values = values
  node.max = max
  node.expectedMax = "table of at most " .. max .. " entries"
  node.foundMax = "table with more than " .. max .. " entries"
  return publishNode(node)
end

---Describe a value that may be `nil`; `Apply` fills in a copy of `default`.
---@param schema SchemaKit.Node|SchemaKit.Schema
---@param default any?
---@return SchemaKit.Node
local function buildOptional(schema, default)
  refuseColonCall(schema, "SchemaKit.optional", 3)
  local inner = resolveChild(schema, "SchemaKit.optional schema", 3)
  if inner.kind == KIND_OPTIONAL then
    error("SchemaKit.optional schema is already optional", 2)
  end

  local node = newCompiledNode(KIND_OPTIONAL, inner.expected)
  node.inner = inner
  if type(default) ~= "nil" then
    if not plainDepthWithin(default, 1) then
      error("SchemaKit.optional default nests deeper than " .. maxDepth .. " tables", 2)
    end
    -- The default is checked like any value, so a schema can never fill
    -- in something it would itself refuse.
    local record = newRecord(inner, false)
    local ok, failure = runCheck(record, default, currentSecretProbe())
    if not ok then
      error(formatFailure("SchemaKit.optional default", failure --[[@as SchemaKit.Failure]]), 2)
    end
    node.hasDefault = true
    node.default = copyPlain(default)
  end
  return publishNode(node)
end

---Describe any value except `nil`.
---@return SchemaKit.Node
local function buildAny(...)
  local argument = ...
  refuseColonCall(argument, "SchemaKit.any", 3)
  if select("#", ...) > 0 then
    error("SchemaKit.any takes no arguments", 2)
  end
  return publishNode(newCompiledNode(KIND_ANY, EXPECTED_ANY))
end

-- Schema methods -------------------------------------------------------------

---@param schema any receiver the public method was called on
---@param label string public method name, used in the argument error
---@param level integer stack level the failure is reported at
---@return SchemaKit.Record
local function recordOf(schema, label, level)
  -- `type` first: indexing the weak table with a secret would raise.
  if type(schema) == "table" then
    local record = schemaRecords[schema]
    if record ~= nil then
      return record
    end
  end
  error(label .. " must be called on a sealed SchemaKit schema", level)
end

---Check `value`. Returns `true`, or `false` and the failure.
---@param self SchemaKit.Schema
---@param value any
---@return boolean ok
---@return SchemaKit.Failure? failure
local function schemaCheck(self, value)
  local record = recordOf(self, "SchemaKit.Schema:Check", 3)
  return runCheck(record, value, currentSecretProbe())
end

---Check `value` and raise at the caller when it fails. Returns `value`.
---
---`level` means what it means to `error` in the function that calls `Assert`:
---`1` (the default) reports the line that called `Assert`, `2` that
---function's caller.
---@param self SchemaKit.Schema
---@param value any
---@param argumentName string? names the value in the message; defaults to `"value"`
---@param level integer? defaults to `1`
---@return any value
local function schemaAssert(self, value, argumentName, level)
  local record = recordOf(self, "SchemaKit.Schema:Assert", 3)
  if type(argumentName) == "nil" then
    argumentName = "value"
  elseif type(argumentName) ~= "string" or isSecret(argumentName) or argumentName == "" then
    error("SchemaKit.Schema:Assert argumentName must be a non-empty string", 2)
  end
  if type(level) == "nil" then
    level = 1
  elseif not isNonNegativeInteger(level) or level < 1 then
    error("SchemaKit.Schema:Assert level must be a positive integer", 2)
  end

  local ok, failure = runCheck(record, value, currentSecretProbe())
  if ok then
    return value
  end
  error(formatFailure(argumentName, failure --[[@as SchemaKit.Failure]]), level + 1)
end

---Return a fresh plain description of the schema. Allocates.
---@param self SchemaKit.Schema
---@return SchemaKit.Description
local function schemaDescribe(self)
  local record = recordOf(self, "SchemaKit.Schema:Describe", 3)
  return describeNode(record.root)
end

---Refuse a write to a node proxy; `level` 2 is the line that wrote.
local function refuseNodeWrite()
  error("SchemaKit schema nodes are immutable", 2)
end

---Refuse a write to a sealed schema; `level` 2 is the line that wrote.
local function refuseSchemaWrite()
  error("SchemaKit schemas are sealed and cannot be modified", 2)
end

-- Package public API ---------------------------------------------------------

---Seal `node` into a schema that can check, apply and describe values.
---
---Nodes are already immutable; sealing gives the compiled node its own
---failure record and options. Sealing a sealed schema returns a new schema
---sharing the same compiled checker.
---@param facade SchemaKit
---@param node SchemaKit.Node|SchemaKit.Schema
---@param options SchemaKit.SealOptions?
---@return SchemaKit.Schema schema
local function packageSeal(facade, node, options)
  -- `SchemaKit.Seal(node)` hands the node in as `facade` and leaves `node`
  -- nil; name that mistake instead of calling the node invalid.
  if not rawequal(facade, SchemaKit) then
    error("SchemaKit:Seal is called with a colon, not a dot", 2)
  end
  local root = resolveChild(node, "SchemaKit:Seal node", 3)
  local freshFailures = false
  if type(options) ~= "nil" then
    if type(options) ~= "table" then
      error("SchemaKit:Seal options must be a table", 2)
    end
    local firstUnknown = firstUnknownField(options, SEAL_OPTION_KEYS)
    if firstUnknown ~= nil then
      error('SchemaKit:Seal options contains unknown field "' .. firstUnknown .. '"', 2)
    end
    local fresh = rawget(options, "freshFailures")
    if type(fresh) ~= "nil" and (type(fresh) ~= "boolean" or isSecret(fresh)) then
      error("SchemaKit:Seal freshFailures must be a boolean", 2)
    end
    freshFailures = fresh == true
  end

  local schema = setmetatable({}, SCHEMA_METATABLE)
  schemaRecords[schema] = newRecord(root, freshFailures)
  return schema
end

-- `describeKey` names a caller's table key in a refusal without running its
-- `__tostring`, which is foreign code that could raise or answer a secret.
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

---Refuse a `SetLimits` argument before anything is written, so a refused
---call changes no limit.
---@param limits any
---@param level integer stack level the failure is reported at
local function validateLimitUpdate(limits, level)
  if type(limits) ~= "table" then
    error("SchemaKit:SetLimits limits must be a table", level)
  end
  local secretProbe = currentSecretProbe()
  for key, value in next, limits do
    if type(key) ~= "string" or rawget(sharedLimits, key) == nil then
      error(
        "SchemaKit:SetLimits limits." .. describeKey(key) .. " is not a recognised limit",
        level
      )
    end
    local ceiling = LIMIT_CEILINGS[key]
    -- The secret check runs before the value meets the sentinel or a
    -- number; a secret is refused like any other invalid value.
    local secret = secretProbe ~= nil and secretProbe(value) == true
    if not secret and value == UNBOUNDED then
      if ceiling ~= nil then
        error(
          "SchemaKit:SetLimits limits."
            .. key
            .. " cannot be SchemaKit.UNBOUNDED: "
            .. LIMIT_CEILING_REASONS[key],
          level
        )
      end
    elseif secret or not isNonNegativeInteger(value) or value < 1 then
      if ceiling ~= nil then
        error(
          "SchemaKit:SetLimits limits." .. key .. " must be an integer from 1 to " .. ceiling,
          level
        )
      end
      error(
        "SchemaKit:SetLimits limits." .. key .. " must be a positive integer or SchemaKit.UNBOUNDED",
        level
      )
    elseif ceiling ~= nil and value > ceiling then
      error(
        "SchemaKit:SetLimits limits."
          .. key
          .. " must be an integer from 1 to "
          .. ceiling
          .. ": "
          .. LIMIT_CEILING_REASONS[key],
        level
      )
    end
  end
end

---Change any subset of the shared limits. Affects every consumer in the
---session. `maxDepth` and `pathKeyLimit` apply to the next check;
---`maxPatternCaptures` and `defaultArrayMax` to the next node built.
---@param facade SchemaKit
---@param limits SchemaKit.Limits
local function packageSetLimits(facade, limits)
  if not rawequal(facade, SchemaKit) then
    error("SchemaKit:SetLimits is called with a colon, not a dot", 2)
  end
  validateLimitUpdate(limits, 3)
  for key, value in next, limits do
    rawset(sharedLimits, key, value)
  end
  loadLimits()
end

---Return the current value of one shared limit without allocating, for a
---consumer that reads a limit on a hot path (SettingsKit reads `maxDepth` on
---every nested write). `defaultArrayMax` may answer `SchemaKit.UNBOUNDED`.
---@param facade SchemaKit
---@param name string `"maxDepth"`, `"maxPatternCaptures"`, `"pathKeyLimit"` or `"defaultArrayMax"`
---@return integer|table value
local function packageGetLimit(facade, name)
  if not rawequal(facade, SchemaKit) then
    error("SchemaKit:GetLimit is called with a colon, not a dot", 2)
  end
  if isSecret(name) then
    error("SchemaKit:GetLimit name must not be a secret value", 2)
  end
  local value = type(name) == "string" and rawget(sharedLimits, name) or nil
  if type(value) == "nil" then
    error(
      "SchemaKit:GetLimit name must be maxDepth, maxPatternCaptures, pathKeyLimit or defaultArrayMax",
      2
    )
  end
  return value
end

---Return a fresh copy of the shared limits; `defaultArrayMax` may be
---`SchemaKit.UNBOUNDED`.
---@param facade SchemaKit
---@return SchemaKit.Limits
local function packageGetLimits(facade)
  if not rawequal(facade, SchemaKit) then
    error("SchemaKit:GetLimits is called with a colon, not a dot", 2)
  end
  return {
    maxDepth = rawget(sharedLimits, "maxDepth"),
    maxPatternCaptures = rawget(sharedLimits, "maxPatternCaptures"),
    pathKeyLimit = rawget(sharedLimits, "pathKeyLimit"),
    defaultArrayMax = rawget(sharedLimits, "defaultArrayMax"),
  }
end

-- Parts ----------------------------------------------------------------------
--
-- Revision 7 moves the builders only some schemas need into two part files
-- (docs/decisions/0001-kit-core-and-parts.md): `SchemaKit-Rules.lua` (string
-- patterns, `custom`, `oneOf`) and `SchemaKit-Apply.lua` (`schema:Apply`).
-- The core publishes in its state what a part needs and nothing else:
--
--   parts          part name to `{ revision = n }`, written by each part;
--   dispatch       entries a part installs and no core revision overwrites:
--                  `compilePattern(node, pattern, level)` from Rules;
--   helpers        the core functions a part calls, read through this table
--                  at call time and rewritten by every core revision, so a
--                  newer core loaded after a part serves it;
--   legacyMembers  the members a revision 6 copy installed, kept while the
--                  part that replaces them is absent (see below).
--
-- A member a part provides stays on the facade or the `Schema` prototype
-- while the part is absent, as a stub that raises at the caller's line with
-- the file to add, so the public-surface check of every other copy still
-- accepts the facade. A part's members are never replaced once it installed
-- them.
--
-- Revision 6 was the last single-file revision. An addon that embeds it may
-- share a session with one embedding revision 7 without the parts; revision
-- 6's `string`, `custom`, `oneOf` and `Schema.Apply` are then kept instead of
-- the stubs. They build layout 2 nodes into the shared `state.nodes`, which
-- this checker reads unchanged, and read the same layout in `Apply`. The part
-- that replaces them drops them when it loads (`helpers.adoptPart`). The
-- reverse order cannot be served: revision 7 loaded first and a revision 6
-- copy after it, the older copy yields, and its pattern, custom, oneOf and
-- Apply calls raise the not-loaded message until some addon embeds the parts.

-- The part machinery shares one table, so the main chunk gains one local.
-- Only what runs after load lives in it; installing the members is inline
-- code of the main chunk (see "Commit"), freed once the file has run.
local Parts = {}

---The error a member of a part that is not loaded raises.
---@param label string the member as a caller wrote it
---@param partName string `"Rules"` or `"Apply"`
---@return string
function Parts.missingMessage(label, partName)
  return label
    .. " is in SchemaKit's "
    .. partName
    .. " part, which is not loaded: add schemaKit\\parts\\SchemaKit-"
    .. partName
    .. ".lua"
end

---Stub of `SchemaKit.custom` while the Rules part is absent.
function Parts.customStub()
  error(Parts.missingMessage("SchemaKit.custom", "Rules"), 2)
end

---Stub of `SchemaKit.oneOf` while the Rules part is absent.
function Parts.oneOfStub()
  error(Parts.missingMessage("SchemaKit.oneOf", "Rules"), 2)
end

---Stub of `Schema:Apply` while the Apply part is absent. The receiver is
---checked first, so a dot call is named as it always was.
---@param self any
function Parts.applyStub(self)
  recordOf(self, "SchemaKit.Schema:Apply", 3)
  error(Parts.missingMessage("SchemaKit.Schema:Apply", "Apply"), 2)
end

---Default `dispatch.compilePattern` while the Rules part is absent.
---@param _ table the string node being built
---@param _ any the pattern
---@param level integer stack level the failure is reported at
function Parts.compilePatternStub(_, _, level)
  error(Parts.missingMessage("SchemaKit.string pattern", "Rules"), level)
end

---Called by a part once its members are installed: drop the revision 6
---members it replaces, and give the facade the core's `string` back when the
---Rules part takes over patterns.
---@param partName string
function Parts.adoptPart(partName)
  local legacy = rawget(state, "legacyMembers")
  if partName == "Rules" then
    rawset(SchemaKit, "string", buildString)
    if type(legacy) == "table" then
      legacy.string, legacy.custom, legacy.oneOf = nil, nil, nil
    end
  elseif type(legacy) == "table" then
    legacy.Apply = nil
  end
  if type(legacy) == "table" and next(legacy) == nil then
    rawset(state, "legacyMembers", nil)
  end
end

---Whether the named part (`"Rules"`, `"Apply"`) is loaded. An unknown name
---answers `false`.
---@param facade SchemaKit
---@param partName string
---@return boolean
function Parts.hasPart(facade, partName)
  if not rawequal(facade, SchemaKit) then
    error("SchemaKit:HasPart is called with a colon, not a dot", 2)
  end
  if isSecret(partName) then
    error("SchemaKit:HasPart partName must not be a secret value", 2)
  end
  if type(partName) ~= "string" then
    error("SchemaKit:HasPart partName must be a string", 2)
  end
  return rawget(installedParts, partName) ~= nil
end

-- What the parts call, rewritten by every core revision.
rawset(state, "helpers", {
  isSecret = isSecret,
  currentSecretProbe = currentSecretProbe,
  refuseColonCall = refuseColonCall,
  validateList = validateList,
  resolveChild = resolveChild,
  newCompiledNode = newCompiledNode,
  publishNode = publishNode,
  quote = quote,
  recordOf = recordOf,
  checkNode = checkNode,
  runCheck = runCheck,
  restoreSegments = restoreSegments,
  copyPlain = copyPlain,
  adoptPart = Parts.adoptPart,
})

-- Node layout upgrade --------------------------------------------------------
--
-- Revision 6 builds sparse nodes (layout 2). Nodes an older revision built
-- hold every field, `false` when unused, in a 32-slot hash part. The checker
-- reads both layouts, so the old nodes would keep working; they are rebuilt
-- anyway, because Lua 5.1 never shrinks a hash part in place and those nodes
-- are most of what a schema holds. Every reference is re-pointed through one
-- old-to-new map: the proxy table, the schema records and the nodes' own
-- child fields.

if previousRevision ~= nil and previousRevision < 6 then
  -- The child fields that hold one compiled node, and those that hold a list.
  local SINGLE_CHILD_FIELDS = { "of", "keys", "values", "inner" }
  local LIST_CHILD_FIELDS = { "fieldNodes", "alternatives" }

  ---Return the sparse copy of `node`: every field that is not `false`, and
  ---`default` whenever `hasDefault` is set (a declared default may be `false`).
  ---@param node table
  ---@return table
  local function sparseCopy(node)
    local copy = {}
    for field, value in next, node do
      if value ~= false or (field == "default" and node.hasDefault == true) then
        copy[field] = value
      end
    end
    copy.layout = NODE_LAYOUT
    return copy
  end

  ---Rebuild every layout 1 node reachable from `node`, filling `rebuilt`
  ---(old node to new node), and return the node to reference instead.
  ---@param node table
  ---@param rebuilt table<table, table>
  ---@return table
  local function rebuildNode(node, rebuilt)
    local done = rebuilt[node]
    if done ~= nil then
      return done
    end
    if node.layout ~= 1 then
      rebuilt[node] = node
      return node
    end
    local copy = sparseCopy(node)
    rebuilt[node] = copy
    for index = 1, #SINGLE_CHILD_FIELDS do
      local field = SINGLE_CHILD_FIELDS[index]
      local child = copy[field]
      if type(child) == "table" then
        copy[field] = rebuildNode(child, rebuilt)
      end
    end
    for index = 1, #LIST_CHILD_FIELDS do
      local list = copy[LIST_CHILD_FIELDS[index]]
      if type(list) == "table" then
        for position = 1, #list do
          list[position] = rebuildNode(list[position], rebuilt)
        end
      end
    end
    return copy
  end

  ---Rebuild the nodes behind every live proxy and schema record.
  local function upgradeNodeLayouts()
    local rebuilt = {}
    for proxy, node in next, compiledNodes do
      compiledNodes[proxy] = rebuildNode(node, rebuilt)
    end
    for _, record in next, schemaRecords do
      record.root = rebuildNode(record.root, rebuilt)
    end
  end
  upgradeNodeLayouts()
end

-- Commit ---------------------------------------------------------------------

-- `__metatable` makes `setmetatable` refuse to replace either metatable and
-- makes `getmetatable` return a name instead of the table. Receivers are
-- recognised through the weak tables, never through `getmetatable`.
rawset(NODE_METATABLE, "__newindex", refuseNodeWrite)
rawset(NODE_METATABLE, "__metatable", "SchemaKit.Node")
rawset(SCHEMA_METATABLE, "__index", Schema)
rawset(SCHEMA_METATABLE, "__newindex", refuseSchemaWrite)
rawset(SCHEMA_METATABLE, "__metatable", "SchemaKit.Schema")

rawset(Schema, "Check", schemaCheck)
rawset(Schema, "Assert", schemaAssert)
rawset(Schema, "Describe", schemaDescribe)

rawset(SchemaKit, "API", API_GENERATION)
rawset(SchemaKit, "REVISION", IMPLEMENTATION_REVISION)
rawset(SchemaKit, "MAX_DEPTH", MAX_DEPTH)
rawset(SchemaKit, "DEFAULT_ARRAY_MAX", DEFAULT_ARRAY_MAX)
rawset(SchemaKit, "UNBOUNDED", UNBOUNDED)
rawset(SchemaKit, "number", buildNumber)
rawset(SchemaKit, "boolean", buildBoolean)
rawset(SchemaKit, "enum", buildEnum)
rawset(SchemaKit, "table", buildTable)
rawset(SchemaKit, "array", buildArray)
rawset(SchemaKit, "map", buildMap)
rawset(SchemaKit, "optional", buildOptional)
rawset(SchemaKit, "any", buildAny)
rawset(SchemaKit, "Seal", packageSeal)
rawset(SchemaKit, "SetLimits", packageSetLimits)
rawset(SchemaKit, "GetLimits", packageGetLimits)
rawset(SchemaKit, "GetLimit", packageGetLimit)
rawset(SchemaKit, "HasPart", Parts.hasPart)

-- Every member whose part is not loaded: the member a revision 6 copy left,
-- or the stub. A loaded part's members stay as it installed them. `string`
-- is the core's own builder unless revision 6's is kept for its patterns.
do
  if previousRevision == 6 then
    rawset(state, "legacyMembers", {
      string = rawget(SchemaKit, "string"),
      custom = rawget(SchemaKit, "custom"),
      oneOf = rawget(SchemaKit, "oneOf"),
      Apply = rawget(Schema, "Apply"),
    })
  end
  local legacy = rawget(state, "legacyMembers") or {}
  if rawget(installedParts, "Rules") == nil then
    rawset(SchemaKit, "string", legacy.string or buildString)
    rawset(SchemaKit, "custom", legacy.custom or Parts.customStub)
    rawset(SchemaKit, "oneOf", legacy.oneOf or Parts.oneOfStub)
    rawset(dispatch, "compilePattern", Parts.compilePatternStub)
  else
    rawset(SchemaKit, "string", buildString)
  end
  if rawget(installedParts, "Apply") == nil then
    rawset(Schema, "Apply", legacy.Apply or Parts.applyStub)
  end
end
rawset(state, "runtimeRevision", IMPLEMENTATION_REVISION)

if not validatePublicSurface(SchemaKit) or not validateCurrentState(SchemaKit) then
  error("MoltenCodes SchemaKit package state is corrupted or incomplete", 2)
end

return SchemaKit
