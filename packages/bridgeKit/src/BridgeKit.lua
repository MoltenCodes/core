-- MoltenCodes BridgeKit
--
-- Tools for moving an addon from Ace3 to the MoltenCodes Kits without breaking
-- what its players already have: data an Ace3 addon wrote must stay readable,
-- and peers still running the Ace3 version must still understand it. The
-- canonical design is `docs/BRIDGE_KIT_DESIGN.md`; this file is written from
-- the format descriptions there, never from Ace3's source (section 3.2).
--
-- This revision ships the first part, the AceSerializer-3.0 wire format
-- (design section 8.1 and 8.2, delivery step N1):
--
--   AceSerialize    the same text Ace's `Serialize` writes for the same values
--                   on the same client, with refusals where Ace would raise or
--                   write undefined bytes (NaN, cycles, functions, limits).
--   AceDeserialize  every text Ace's `Deserialize` accepts, within the limits;
--                   malformed text is `false, reason` and never raises.
--
-- The AceConfig adapter, the AceDB importer and the AceComm channel follow in
-- later revisions (design section 15, steps N2 to N4).
--
-- BridgeKit needs Registry API 2 and nothing else.
--
-- Contents
-- --------
--   Constants ............. identity, baseline, reasons, the escape tables
--   Public types .......... LuaCATS declarations for the published surface
--   Dependencies .......... Registry and the host facilities read
--   Validation ............ public-surface and shared-state predicates
--   Bootstrap ............. Registry registration and inherited state
--   Argument checks ....... receivers, limits, secret values
--   Writer ................ AceSerialize's value walk
--   Reader ................ AceDeserialize's token walk
--   Package public API .... the facade published through Registry
--   Commit ................ facade assignment and self-check

-- Constants ------------------------------------------------------------------

local PACKAGE_NAME = "bridgeKit"
local API_GENERATION = 1
local IMPLEMENTATION_REVISION = 1
local REQUIRED_REGISTRY_API = 2
local STATE_SCHEMA = 1

-- The newest AceComm wire version this revision speaks (design section 8.5).
local ACE_WIRE_VERSION = 1

-- What BridgeKit reproduces: Ace3 at this commit, and the library revisions
-- (`MINOR`) at it (design section 3.1). Published read-only as `ACE_BASELINE`.
local ACE_BASELINE = {
  commit = "5e2e0d3b3fd125ef1518744c6a9dd21f68f6e773",
  AceComm = 14,
  AceSerializer = 5,
  AceDB = 37,
  AceConfigRegistry = 22,
}

-- Why `AceSerialize` refused (docs/API.md, "AceSerialize").
local WRITE_REASON = {
  unsupportedType = "unsupportedType",
  cycle = "cycle",
  nan = "nan",
  maxDepth = "maxDepth",
  maxValues = "maxValues",
  maxStringLength = "maxStringLength",
  maxTextBytes = "maxTextBytes",
}

-- Why `AceDeserialize` refused (docs/API.md, "AceDeserialize").
local READ_REASON = {
  notAceSerializer = "notAceSerializer",
  missingTerminator = "missingTerminator",
  invalidNumber = "invalidNumber",
  invalidFloat = "invalidFloat",
  invalidEscape = "invalidEscape",
  unknownControl = "unknownControl",
  tableFormat = "tableFormat",
  invalidKey = "invalidKey",
  maxDepth = "maxDepth",
  maxValues = "maxValues",
  maxStringLength = "maxStringLength",
  maxTextBytes = "maxTextBytes",
  maxListValues = "maxListValues",
}

-- The limits, their defaults, their ceilings and whether `UNBOUNDED` lifts
-- them (design section 9). Only the serializer's exist in this revision.
local LIMIT_NAMES = { "maxDepth", "maxValues", "maxStringLength", "maxTextBytes", "maxListValues" }
local LIMIT_RULES = {
  maxDepth = {
    default = 16,
    ceiling = 128,
    unboundedRefusal = "the reader and writer recurse on the Lua call stack",
  },
  maxValues = { default = 65536, ceiling = 2 ^ 24, unbounded = true },
  maxStringLength = { default = 65536, ceiling = 2 ^ 30, unbounded = true },
  maxTextBytes = {
    default = 1048576,
    ceiling = 2 ^ 26,
    unboundedRefusal = "a peer chooses the size of the text a reader is given",
  },
  maxListValues = {
    default = 4096,
    ceiling = 7900,
    unboundedRefusal = "AceDeserialize returns its values through unpack, which the Lua stack bounds",
  },
}

-- AceSerializer escapes a string's control bytes, space, caret, tilde and DEL
-- with a tilde and one character (design section 8.1, "String escaping"). The
-- pattern is the set of bytes that get escaped; the table gives each its
-- escape, built once here so the writer allocates no closure.
local ESCAPE_PATTERN = "[%c \094\126\127]"
local ESCAPE_FOR = {}
for byte = 0, 32 do
  ESCAPE_FOR[string.char(byte)] = "~" .. string.char(byte + 64)
end
-- The general rule would write byte 30 as `~^`, a caret, so it has its own.
ESCAPE_FOR["\030"] = "~z"
ESCAPE_FOR["^"] = "~}"
ESCAPE_FOR["~"] = "~|"
ESCAPE_FOR["\127"] = "~{"

-- The four characters after a tilde that do not follow the "byte plus 64"
-- rule. `~~` is no escape at all: Ace refuses it, and so does BridgeKit.
local UNESCAPE_SPECIAL = { z = "\030", ["{"] = "\127", ["|"] = "~", ["}"] = "^" }

-- The infinity spellings a reader accepts in a `^N` token: Ace's own, which a
-- client whose `tostring` writes `1.#INF` produces, and the C library's.
local INFINITY_TEXT =
  { ["1.#INF"] = math.huge, inf = math.huge, ["-1.#INF"] = -math.huge, ["-inf"] = -math.huge }

-- The mantissa of a `^F` token is the fraction `frexp` returns scaled to an
-- integer by 2^53, the precision of a double.
local MANTISSA_SCALE = 2 ^ 53
local MANTISSA_BITS = 53

-- A `^F` exponent beyond this bound gives zero or infinity for every finite
-- mantissa (2^1024 times 2^-2200 underflows, 2^-1074 times 2^2200 overflows),
-- so the reader clamps to it before `ldexp`, whose C argument is an `int`.
local EXPONENT_BOUND = 2200

-- Public types ---------------------------------------------------------------

---Why `AceSerialize` refused.
---@alias BridgeKit.WriteReason "unsupportedType"|"cycle"|"nan"|"maxDepth"|"maxValues"|"maxStringLength"|"maxTextBytes"

---Why `AceDeserialize` refused.
---@alias BridgeKit.ReadReason "notAceSerializer"|"missingTerminator"|"invalidNumber"|"invalidFloat"|"invalidEscape"|"unknownControl"|"tableFormat"|"invalidKey"|"maxDepth"|"maxValues"|"maxStringLength"|"maxTextBytes"|"maxListValues"

---The limits `SetLimits` accepts and `GetLimits` returns.
---@class BridgeKit.Limits
---@field maxDepth integer? Table nesting, both ways; a top-level table is depth 1.
---@field maxValues (integer|table)? Values in one text, keys included; `BridgeKit.UNBOUNDED` lifts it.
---@field maxStringLength (integer|table)? Bytes of one string, unescaped; `BridgeKit.UNBOUNDED` lifts it.
---@field maxTextBytes integer? Bytes of the text `AceSerialize` writes and `AceDeserialize` reads.
---@field maxListValues integer? Top-level values `AceDeserialize` returns.

---What BridgeKit reproduces of Ace3.
---@class BridgeKit.Baseline
---@field commit string The Ace3 commit the formats were read from.
---@field AceComm integer
---@field AceSerializer integer
---@field AceDB integer
---@field AceConfigRegistry integer

---The BridgeKit package facade published through Registry.
---@class BridgeKit
---@field API integer Public API generation.
---@field REVISION integer Compatible implementation revision.
---@field UNBOUNDED table Sentinel for the limits that accept it.
---@field ACE_WIRE_VERSION integer The newest AceComm wire version this revision speaks.
---@field ACE_BASELINE BridgeKit.Baseline Read-only.
---@field AceSerialize fun(self: BridgeKit, ...: any): boolean, string|BridgeKit.WriteReason
---@field AceDeserialize fun(self: BridgeKit, text: string): boolean, ...
---@field SetLimits fun(self: BridgeKit, limits: BridgeKit.Limits)
---@field GetLimits fun(self: BridgeKit): BridgeKit.Limits

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
  error("MoltenCodes BridgeKit requires Registry API 2 to be loaded first", 2)
end

local bootstrapPackage = rawget(Registry, "Bootstrap")
if type(bootstrapPackage) ~= "function" then
  error("MoltenCodes BridgeKit requires a valid Registry API 2 facade", 2)
end

---The client's `issecretvalue`, read at every call because a client can gain
---it after BridgeKit loads; `nil` on a client without secret values.
---@return (fun(value: any): boolean)|nil
local function readSecretProbe()
  -- issecretvalue is a World of Warcraft client API reachable only through the global table.
  -- selene: allow(global_usage)
  local probe = rawget(_G, "issecretvalue")
  if type(probe) == "function" then
    return probe
  end
  return nil
end

local frexp = math.frexp
local ldexp = math.ldexp
local stringFind = string.find
local stringSub = string.sub
local tostring = tostring
local tonumber = tonumber
local type = type

-- Validation -----------------------------------------------------------------

-- Every member the facade publishes, used by the surface check.
local PUBLIC_METHODS = { "AceSerialize", "AceDeserialize", "SetLimits", "GetLimits" }

---Whether `implementation` exposes the complete BridgeKit API 1 surface.
---@param implementation any shared package table handed back by Registry
---@return boolean
local function validatePublicSurface(implementation)
  if
    type(implementation) ~= "table"
    or rawget(implementation, "API") ~= API_GENERATION
    or type(rawget(implementation, "REVISION")) ~= "number"
    or type(rawget(implementation, "UNBOUNDED")) ~= "table"
    or type(rawget(implementation, "ACE_BASELINE")) ~= "table"
    or type(rawget(implementation, "ACE_WIRE_VERSION")) ~= "number"
  then
    return false
  end
  for index = 1, #PUBLIC_METHODS do
    if type(rawget(implementation, PUBLIC_METHODS[index])) ~= "function" then
      return false
    end
  end
  return true
end

---Whether `value` is an exact integer from 1 to `ceiling`. NaN fails every
---comparison and infinity the ceiling, with no special case.
---@param value any
---@param ceiling number
---@return boolean
local function isIntegerUpTo(value, ceiling)
  return type(value) == "number" and value >= 1 and value <= ceiling and value % 1 == 0
end

---Whether `currentState` has the fields every API 1 revision shares.
---@param currentState any
---@return boolean
local function validateStateBase(currentState)
  if
    type(currentState) ~= "table"
    or rawget(currentState, "schema") ~= STATE_SCHEMA
    or type(rawget(currentState, "unbounded")) ~= "table"
    or type(rawget(currentState, "limits")) ~= "table"
    or type(rawget(currentState, "baseline")) ~= "table"
  then
    return false
  end
  return true
end

---Whether `implementation` carries state of this schema and publishes the
---sentinel and the baseline that state owns.
---@param implementation table
---@return boolean
local function validateCurrentState(implementation)
  local currentState = rawget(implementation, "_state")
  return validateStateBase(currentState)
    and rawget(implementation, "UNBOUNDED") == rawget(currentState, "unbounded")
    and rawget(implementation, "ACE_BASELINE") == rawget(currentState, "baseline")
end

-- Bootstrap ------------------------------------------------------------------

---A read-only view of `contents`: reads go through, every write raises, and
---the metatable is locked so nobody can replace it.
---@param contents table
---@return table
local function readOnly(contents)
  return setmetatable({}, {
    __index = contents,
    __newindex = function()
      error("BridgeKit.ACE_BASELINE is read-only", 2)
    end,
    __metatable = false,
  })
end

local BridgeKit, previousRevision, selected = bootstrapPackage(Registry, {
  package = PACKAGE_NAME,
  api = API_GENERATION,
  revision = IMPLEMENTATION_REVISION,
  label = "MoltenCodes BridgeKit",
  validatePublicSurface = validatePublicSurface,
  validateState = validateCurrentState,
})

if type(BridgeKit) == "nil" then
  -- An equal or newer compatible revision already owns the shared package table.
  return selected
end

local state = rawget(BridgeKit, "_state")

if type(previousRevision) == "nil" then
  if state ~= nil then
    error("MoltenCodes BridgeKit package state is corrupted or incomplete", 2)
  end
  state = {
    schema = STATE_SCHEMA,
    -- The sentinel `SetLimits` accepts to lift a limit, and the baseline.
    -- They live here, not in file locals, so every embedded copy and every
    -- revision hands out the same tables.
    unbounded = {},
    baseline = readOnly(ACE_BASELINE),
    limits = {},
  }
  rawset(BridgeKit, "_state", state)
elseif not validateStateBase(state) then
  error("MoltenCodes BridgeKit package state is corrupted or incomplete", 2)
end

local UNBOUNDED = rawget(state, "unbounded")
local limits = rawget(state, "limits")
-- A limit this revision knows and the inherited state lacks gets its default;
-- the ones a consumer set are kept.
for index = 1, #LIMIT_NAMES do
  local name = LIMIT_NAMES[index]
  if type(rawget(limits, name)) == "nil" then
    rawset(limits, name, LIMIT_RULES[name].default)
  end
end

-- Argument checks ------------------------------------------------------------

-- Every check raises with an explicit stack level so the reported position is
-- the line that called the public method, never a line inside BridgeKit.

---@param receiver any the table the method was called on
---@param label string the public method, `BridgeKit:AceSerialize`
---@param level integer stack level the failure is reported at
local function validateFacade(receiver, label, level)
  -- The type test runs first, so a caller's non-table receiver, a secret
  -- included, is never compared with the facade.
  if type(receiver) ~= "table" or receiver ~= BridgeKit then
    error(label .. " must be called on the BridgeKit facade; use " .. label .. "(...)", level)
  end
end

---Refuse a `SetLimits` argument before any limit changes, so a call with one
---bad entry leaves every limit as it was.
---@param update any
---@param level integer
local function validateLimitUpdate(update, level)
  local label = "BridgeKit:SetLimits limits"
  if type(update) ~= "table" then
    error(label .. " must be a table", level)
  end
  local probe = readSecretProbe()
  for key, value in next, update do
    if probe ~= nil and probe(key) == true then
      error(label .. " must not have a secret key", level)
    end
    local rule = type(key) == "string" and LIMIT_RULES[key] or nil
    if rule == nil then
      error(
        label
          .. " has no limit named "
          .. (type(key) == "string" and key or ("[" .. type(key) .. "]")),
        level
      )
    end
    if probe ~= nil and probe(value) == true then
      error(label .. "." .. key .. " must not be a secret value", level)
    end
    local range = "an integer from 1 to " .. string.format("%.0f", rule.ceiling)
    if value == UNBOUNDED then
      if not rule.unbounded then
        error(
          label
            .. "."
            .. key
            .. " cannot be BridgeKit.UNBOUNDED because "
            .. rule.unboundedRefusal
            .. "; use "
            .. range,
          level
        )
      end
    elseif not isIntegerUpTo(value, rule.ceiling) then
      local alternative = rule.unbounded and " or BridgeKit.UNBOUNDED" or ""
      error(label .. "." .. key .. " must be " .. range .. alternative, level)
    end
  end
end

---Whether `amount` passes `limit`, which may be `UNBOUNDED`.
---@param amount number
---@param limit number|table
---@return boolean
local function exceeds(amount, limit)
  return limit ~= UNBOUNDED and amount > limit
end

-- Writer ---------------------------------------------------------------------
--
-- One call builds a work record: the output pieces, their byte total, the
-- values written, the tables on the current path (for cycles), the limits the
-- call started with and the secret probe. `writeValue` returns `false` and a
-- reason to unwind; a secret is the reason `"secret"`, which the public method
-- turns into an error at its caller, because an error raised this deep would
-- point inside BridgeKit.

local writeValue

---Append one piece to the output, refusing once it passes `maxTextBytes`.
---@param work table
---@param piece string
---@return boolean ok
local function append(work, piece)
  local bytes = work.bytes + #piece
  if bytes > work.maxTextBytes then
    return false
  end
  work.bytes = bytes
  local pieces = work.pieces
  pieces[#pieces + 1] = piece
  return true
end

---The `^N`, `^F` or infinity token of a number that is not NaN.
---@param value number
---@return string
local function numberToken(value)
  local text = tostring(value)
  -- `tostring` writes 14 significant digits, which is exact for most numbers
  -- people store; the rest are written as a mantissa and an exponent.
  if tonumber(text) == value then
    return "^N" .. text
  end
  if value == math.huge then
    return "^N1.#INF"
  end
  if value == -math.huge then
    return "^N-1.#INF"
  end
  local mantissa, exponent = frexp(value)
  local mantissaText = string.format("%.0f", mantissa * MANTISSA_SCALE)
  local exponentText = tostring(exponent - MANTISSA_BITS)
  return "^F" .. mantissaText .. "^f" .. exponentText
end

---Write the pairs of `value`, then its end code.
---@param work table
---@param value table
---@param depth integer the table's own depth
---@return boolean ok
---@return string|nil reason
local function writeTable(work, value, depth)
  if depth > work.maxDepth then
    return false, WRITE_REASON.maxDepth
  end
  local onPath = work.onPath
  if onPath[value] then
    return false, WRITE_REASON.cycle
  end
  if not append(work, "^T") then
    return false, WRITE_REASON.maxTextBytes
  end
  onPath[value] = true
  for key, entry in next, value do
    local ok, reason = writeValue(work, key, depth)
    if ok then
      ok, reason = writeValue(work, entry, depth)
    end
    if not ok then
      return false, reason
    end
  end
  onPath[value] = nil
  if not append(work, "^t") then
    return false, WRITE_REASON.maxTextBytes
  end
  return true, nil
end

---Write one value. `depth` is the depth of the table holding it, 0 at the top.
---@param work table
---@param value any
---@param depth integer
---@return boolean ok
---@return string|nil reason
function writeValue(work, value, depth)
  local probe = work.probe
  if probe ~= nil and probe(value) == true then
    return false, "secret"
  end
  local count = work.count + 1
  if exceeds(count, work.maxValues) then
    return false, WRITE_REASON.maxValues
  end
  work.count = count

  local valueType = type(value)
  local piece
  if valueType == "string" then
    if exceeds(#value, work.maxStringLength) then
      return false, WRITE_REASON.maxStringLength
    end
    if stringFind(value, ESCAPE_PATTERN) ~= nil then
      piece = "^S" .. string.gsub(value, ESCAPE_PATTERN, ESCAPE_FOR)
    else
      piece = "^S" .. value
    end
  elseif valueType == "number" then
    if value ~= value then
      return false, WRITE_REASON.nan
    end
    piece = numberToken(value)
  elseif valueType == "boolean" then
    piece = value and "^B" or "^b"
  elseif valueType == "nil" then
    piece = "^Z"
  elseif valueType == "table" then
    return writeTable(work, value, depth + 1)
  else
    return false, WRITE_REASON.unsupportedType
  end
  if not append(work, piece) then
    return false, WRITE_REASON.maxTextBytes
  end
  return true, nil
end

---Serialise the values of an argument list.
---@param probe (fun(value: any): boolean)|nil
---@param ... any
---@return boolean ok
---@return string textOrReason
local function serialize(probe, ...)
  local work = {
    pieces = {},
    bytes = 0,
    count = 0,
    onPath = {},
    probe = probe,
    maxDepth = limits.maxDepth,
    maxValues = limits.maxValues,
    maxStringLength = limits.maxStringLength,
    maxTextBytes = limits.maxTextBytes,
  }
  if not append(work, "^1") then
    return false, WRITE_REASON.maxTextBytes
  end
  for index = 1, select("#", ...) do
    local ok, reason = writeValue(work, (select(index, ...)), 0)
    if not ok then
      -- A failed write always names its reason.
      ---@cast reason string
      return false, reason
    end
  end
  if not append(work, "^^") then
    return false, WRITE_REASON.maxTextBytes
  end
  return true, table.concat(work.pieces)
end

-- Reader ---------------------------------------------------------------------
--
-- The reader first removes every control byte and space from the text, as Ace
-- does, then walks it token by token: a caret, one character (the code), and
-- the data up to the next caret. A reader record holds the text, the cursor
-- and the code and data of the current token. Nothing here can raise on any
-- string: every token is cut with `string.sub` at found positions, numbers are
-- read with `tonumber`, and the recursion is bounded by `maxDepth`.

-- The value a `^^` token reads as: the end of the values. Inside a table Ace
-- reads it as a missing key or value, which is a table format error.
local END = {}

---Move the reader to the next token. Returns `false` when there is none: no
---caret left, or a caret that ends the text with no code after it.
---@param reader table
---@return boolean found
local function nextToken(reader)
  local text = reader.text
  local caret = stringFind(text, "^", reader.cursor, true)
  if caret == nil or caret == reader.length then
    return false
  end
  local following = stringFind(text, "^", caret + 2, true)
  local dataEnd = following and following - 1 or reader.length
  reader.code = stringSub(text, caret + 1, caret + 1)
  reader.data = stringSub(text, caret + 2, dataEnd)
  reader.cursor = dataEnd + 1
  return true
end

---Undo AceSerializer's string escaping, or `nil` for an escape Ace refuses.
---@param data string
---@return string|nil
local function unescape(data)
  if stringFind(data, "~", 1, true) == nil then
    return data
  end
  local invalid = false
  local text = string.gsub(data, "~(.)", function(character)
    local special = UNESCAPE_SPECIAL[character]
    if special ~= nil then
      return special
    end
    local byte = string.byte(character) - 64
    if character == "~" or byte < 0 then
      invalid = true
      return ""
    end
    return string.char(byte)
  end)
  if invalid then
    return nil
  end
  return text
end

---The value of a `^F` token. Ace computes `mantissa * 2^exponent`, which reads
---0 for a number whose `2^exponent` alone underflows although the product is
---representable: some subnormal numbers, which Ace's own writer produces.
---BridgeKit scales with `ldexp` instead, so it reads back every number it and
---Ace write; for every other integer exponent the two agree exactly. A
---non-integer exponent, which no writer produces, is computed as Ace does.
---@param mantissa number
---@param exponent number
---@return number
local function scaleMantissa(mantissa, exponent)
  if exponent ~= exponent or exponent % 1 ~= 0 then
    return mantissa * 2 ^ exponent
  end
  if exponent > EXPONENT_BOUND then
    exponent = EXPONENT_BOUND
  elseif exponent < -EXPONENT_BOUND then
    exponent = -EXPONENT_BOUND
  end
  return ldexp(mantissa, exponent)
end

local readValue

---Read the pairs of a table after its `^T`, through its `^t`.
---@param reader table
---@param depth integer the table's own depth
---@return boolean ok
---@return any valueOrReason
local function readTable(reader, depth)
  if depth > reader.maxDepth then
    return false, READ_REASON.maxDepth
  end
  local result = {}
  while true do
    if not nextToken(reader) then
      return false, READ_REASON.missingTerminator
    end
    if reader.code == "t" then
      return true, result
    end
    local ok, key = readValue(reader, depth)
    if not ok then
      return false, key
    end
    if key == nil or key == END then
      return false, READ_REASON.tableFormat
    end
    if key ~= key then
      return false, READ_REASON.invalidKey
    end
    if not nextToken(reader) then
      return false, READ_REASON.missingTerminator
    end
    if reader.code == "t" then
      return false, READ_REASON.unknownControl
    end
    local entry
    ok, entry = readValue(reader, depth)
    if not ok then
      return false, entry
    end
    if entry == nil or entry == END then
      return false, READ_REASON.tableFormat
    end
    result[key] = entry
  end
end

---Read the value of the current token. `depth` is the depth of the table
---holding it, 0 at the top. A `^^` token reads as `END`.
---@param reader table
---@param depth integer
---@return boolean ok
---@return any valueOrReason
function readValue(reader, depth)
  local code, data = reader.code, reader.data
  -- The end code is no value, so it does not count against `maxValues`.
  if code == "^" then
    return true, END
  end
  local count = reader.count + 1
  if exceeds(count, reader.maxValues) then
    return false, READ_REASON.maxValues
  end
  reader.count = count

  if code == "S" then
    local text = unescape(data)
    if text == nil then
      return false, READ_REASON.invalidEscape
    end
    if exceeds(#text, reader.maxStringLength) then
      return false, READ_REASON.maxStringLength
    end
    return true, text
  elseif code == "N" then
    local number = INFINITY_TEXT[data] or tonumber(data)
    if number == nil then
      return false, READ_REASON.invalidNumber
    end
    return true, number
  elseif code == "F" then
    local mantissa = tonumber(data)
    if not nextToken(reader) or reader.code ~= "f" then
      return false, READ_REASON.invalidFloat
    end
    local exponent = tonumber(reader.data)
    if mantissa == nil or exponent == nil then
      return false, READ_REASON.invalidFloat
    end
    return true, scaleMantissa(mantissa, exponent)
  elseif code == "B" then
    return true, true
  elseif code == "b" then
    return true, false
  elseif code == "Z" then
    return true, nil
  elseif code == "T" then
    return readTable(reader, depth + 1)
  end
  return false, READ_REASON.unknownControl
end

---Read every top-level value of `text` into `values`, counting them in
---`values.n`.
---@param text string
---@param values table
---@return boolean ok
---@return string|nil reason
local function deserializeInto(text, values)
  if #text > limits.maxTextBytes then
    return false, READ_REASON.maxTextBytes
  end
  local stripped = string.gsub(text, "[%c ]", "")
  local reader = {
    text = stripped,
    length = #stripped,
    cursor = 1,
    code = false,
    data = false,
    count = 0,
    maxDepth = limits.maxDepth,
    maxValues = limits.maxValues,
    maxStringLength = limits.maxStringLength,
  }
  if not nextToken(reader) or reader.code ~= "1" then
    return false, READ_REASON.notAceSerializer
  end
  local maxListValues = limits.maxListValues
  local listed = 0
  while true do
    if not nextToken(reader) then
      return false, READ_REASON.missingTerminator
    end
    local ok, value = readValue(reader, 0)
    if not ok then
      return false, value
    end
    if value == END then
      values.n = listed
      return true, nil
    end
    listed = listed + 1
    if listed > maxListValues then
      return false, READ_REASON.maxListValues
    end
    values[listed] = value
  end
end

-- Package public API ---------------------------------------------------------

---Serialise values to AceSerializer-3.0 text: the text Ace's `Serialize`
---writes for the same values on the same client. Returns `true, text`, or
---`false, reason` where Ace would raise or write undefined bytes and where a
---limit is passed. A secret anywhere raises at the caller.
---@param self BridgeKit
---@param ... any
---@return boolean ok
---@return string|BridgeKit.WriteReason textOrReason
local function aceSerialize(self, ...)
  validateFacade(self, "BridgeKit:AceSerialize", 3)
  local ok, result = serialize(readSecretProbe(), ...)
  if not ok and result == "secret" then
    error("BridgeKit:AceSerialize value must not contain a secret value", 2)
  end
  return ok, result
end

---Read AceSerializer-3.0 text: `true` and every value (their count kept,
---`nil`s included), or `false, reason`. Never raises on malformed text; raises
---at the caller only for a `text` that is not a string or is secret.
---@param self BridgeKit
---@param text string
---@return boolean ok
---@return ... any values, or the reason
local function aceDeserialize(self, text)
  validateFacade(self, "BridgeKit:AceDeserialize", 3)
  if type(text) ~= "string" then
    error("BridgeKit:AceDeserialize text must be a string", 2)
  end
  local probe = readSecretProbe()
  if probe ~= nil and probe(text) == true then
    error("BridgeKit:AceDeserialize text must not be a secret value", 2)
  end
  local values = {}
  local ok, reason = deserializeInto(text, values)
  if not ok then
    return false, reason
  end
  return true, unpack(values, 1, values.n)
end

---Change any subset of the shared limits. The whole table is checked before
---anything changes. Affects every consumer in the session.
---@param self BridgeKit
---@param update BridgeKit.Limits
local function setLimits(self, update)
  validateFacade(self, "BridgeKit:SetLimits", 3)
  validateLimitUpdate(update, 3)
  for index = 1, #LIMIT_NAMES do
    local name = LIMIT_NAMES[index]
    local value = rawget(update, name)
    if type(value) ~= "nil" then
      rawset(limits, name, value)
    end
  end
end

---Return a fresh copy of the shared limits.
---@param self BridgeKit
---@return BridgeKit.Limits
local function getLimits(self)
  validateFacade(self, "BridgeKit:GetLimits", 3)
  local copy = {}
  for index = 1, #LIMIT_NAMES do
    local name = LIMIT_NAMES[index]
    copy[name] = rawget(limits, name)
  end
  return copy
end

-- Commit ---------------------------------------------------------------------

rawset(BridgeKit, "API", API_GENERATION)
rawset(BridgeKit, "REVISION", IMPLEMENTATION_REVISION)
rawset(BridgeKit, "UNBOUNDED", UNBOUNDED)
rawset(BridgeKit, "ACE_WIRE_VERSION", ACE_WIRE_VERSION)
rawset(BridgeKit, "ACE_BASELINE", rawget(state, "baseline"))
rawset(BridgeKit, "AceSerialize", aceSerialize)
rawset(BridgeKit, "AceDeserialize", aceDeserialize)
rawset(BridgeKit, "SetLimits", setLimits)
rawset(BridgeKit, "GetLimits", getLimits)

if not validatePublicSurface(BridgeKit) or not validateCurrentState(BridgeKit) then
  error("MoltenCodes BridgeKit package state is corrupted or incomplete", 2)
end

return BridgeKit
