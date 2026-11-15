-- MoltenCodes BridgeKit
--
-- Tools for moving an addon from Ace3 to the MoltenCodes Kits without breaking
-- what its players already have: data an Ace3 addon wrote must stay readable,
-- and peers still running the Ace3 version must still understand it. The
-- canonical design is `docs/BRIDGE_KIT_DESIGN.md`; this file is written from
-- the format descriptions there, never from Ace3's source (section 3.2).
--
-- This revision ships two parts:
--
--   AceSerialize      the same text Ace's `Serialize` writes for the same
--   AceDeserialize    values on the same client, and every text its
--                     `Deserialize` accepts, within the limits (design
--                     sections 8.1 and 8.2, step N1).
--   ConvertAceConfig  an AceConfig-3.0 options table converted to a table for
--   DefineAceConfig   `OptionsKit:Define`, its callbacks wrapped and called in
--   FormatReport      Ace's shape, and a report of everything that changed
--                     (design section 6, step N2).
--
-- The AceDB importer and the AceComm channel follow in later revisions
-- (design section 15, steps N3 and N4).
--
-- BridgeKit needs Registry API 2. `DefineAceConfig` finds OptionsKit API 1
-- through `Registry:Find` when it is called; without it, it raises at the
-- caller, and `ConvertAceConfig` still returns a plain tree table.
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
--   Reports ............... the report shape both conversions share
--   AceConfig adapter ..... the walk from an Ace options table to OptionsKit's
--   Conversion methods .... options, ConvertAceConfig, DefineAceConfig, FormatReport
--   Package public API .... the facade published through Registry
--   Commit ................ facade assignment and self-check

-- Constants ------------------------------------------------------------------

local PACKAGE_NAME = "bridgeKit"
local API_GENERATION = 1
local IMPLEMENTATION_REVISION = 2
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
local LIMIT_NAMES = {
  "maxDepth",
  "maxValues",
  "maxStringLength",
  "maxTextBytes",
  "maxListValues",
  "maxReportEntries",
}
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
  maxReportEntries = { default = 1024, ceiling = 2 ^ 24, unbounded = true },
  maxListValues = {
    default = 4096,
    ceiling = 7900,
    unboundedRefusal = "AceDeserialize returns its values through unpack, which the Lua stack bounds",
  },
}

-- The actions a report counts, in the order `FormatReport` sums them up
-- (design section 5.2). The AceDB importer adds its own two.
local REPORT_ACTIONS = { "converted", "dropped", "changed", "renamed", "unsupported" }

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
-- rule. Ace reads a tilde before any character from `@` (64) to `}` (125)
-- and refuses every other, `~~` and the high bytes included; the recorded
-- fixtures pin this byte by byte.
local UNESCAPE_SPECIAL = { z = "\030", ["{"] = "\127", ["|"] = "~", ["}"] = "^" }
local UNESCAPE_LOWEST, UNESCAPE_HIGHEST = 64, 125

-- The infinity spellings a reader accepts in a `^N` token: Ace's own, which a
-- client whose `tostring` writes `1.#INF` produces, and the C library's.
local INFINITY_TEXT =
  { ["1.#INF"] = math.huge, inf = math.huge, ["-1.#INF"] = -math.huge, ["-inf"] = -math.huge }

-- The mantissa of a `^F` token is the fraction `frexp` returns scaled to an
-- integer by 2^53, the precision of a double.
local MANTISSA_SCALE = 2 ^ 53
local MANTISSA_BITS = 53

-- The smallest exponent for which `2^exponent` is still a double: below it
-- the power alone underflows to zero. A `^F` exponent below that is scaled
-- with `ldexp`, clamped first to `-EXPONENT_BOUND`, where every finite
-- mantissa (at most 2^1024) underflows anyway; `ldexp` takes a C `int`.
local SMALLEST_POWER_EXPONENT = -1074
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
---@field maxReportEntries (integer|table)? Entries one report stores; `BridgeKit.UNBOUNDED` lifts it.

---One report entry. No entry holds a value from the source.
---@class BridgeKit.ReportEntry
---@field path string The converted option path, `""` for the root.
---@field field string? The Ace field the entry is about.
---@field action "dropped"|"changed"|"renamed"|"unsupported"
---@field reason string From the vocabulary in docs/API.md.

---What a conversion did, entry by entry and counted.
---@class BridgeKit.Report
---@field kind "aceConfig"
---@field entries BridgeKit.ReportEntry[] In walk order, at most `maxReportEntries`.
---@field counts table<string, integer> Every action, `0` included.
---@field truncated integer Entries not stored because `maxReportEntries` was reached.

---What `ConvertAceConfig` returns.
---@class BridgeKit.Conversion
---@field tree table The table for `OptionsKit:Define`.
---@field report BridgeKit.Report
---@field paths table<string, string[]> Converted option path to the original Ace keys.
---@field maxDepth integer The longest option path, in keys.
---@field optionCount integer Options converted, groups included, the root excluded.

---The options `ConvertAceConfig` accepts.
---@class BridgeKit.ConvertOptions
---@field uiType ("dialog"|"dropdown"|"cmd")? Default `"dialog"`.
---@field uiName string? Default `"BridgeKit-1"`.
---@field bind table<string, string>? Option path to a SettingsKit bind path.
---@field replace table<string, table>? Option path to an OptionsKit option used as it is.
---@field strict boolean? Raise when anything was dropped, changed or left out.
---@field maxOptions (integer|table)? Default 1024; `BridgeKit.UNBOUNDED` lifts it.
---@field maxDepth integer? Keys per option path, 1 to 32; default 8.

---The options `DefineAceConfig` accepts.
---@class BridgeKit.DefineOptions: BridgeKit.ConvertOptions
---@field db table? The SettingsKit database `bind` paths need.

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
---@field ConvertAceConfig fun(self: BridgeKit, appName: string, source: table|function, options: BridgeKit.ConvertOptions?): BridgeKit.Conversion
---@field DefineAceConfig fun(self: BridgeKit, addonName: string, source: table|function, options: BridgeKit.DefineOptions?): table, BridgeKit.Report
---@field FormatReport fun(self: BridgeKit, report: BridgeKit.Report, maxLines: integer?): string[]
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
local PUBLIC_METHODS = {
  "AceSerialize",
  "AceDeserialize",
  "ConvertAceConfig",
  "DefineAceConfig",
  "FormatReport",
  "SetLimits",
  "GetLimits",
}

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
    or type(rawget(currentState, "baselineData")) ~= "table"
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

---A read-only view of `contents`: field reads go through, every write raises,
---and the metatable is locked so nobody can replace it. It is a proxy, so
---`pairs` sees no fields and `rawset` writes to the proxy, not the contents.
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
    baselineData = {},
    limits = {},
  }
  state.baseline = readOnly(state.baselineData)
  rawset(BridgeKit, "_state", state)
elseif not validateStateBase(state) then
  error("MoltenCodes BridgeKit package state is corrupted or incomplete", 2)
end

local UNBOUNDED = rawget(state, "unbounded")
-- The published baseline keeps its identity, and the newest revision writes
-- what it reproduces into it, so a revision that moves the Ace3 pin publishes
-- the new values through the same table.
local baselineData = rawget(state, "baselineData")
for field, value in next, ACE_BASELINE do
  rawset(baselineData, field, value)
end
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
    local byte = string.byte(character)
    if byte < UNESCAPE_LOWEST or byte > UNESCAPE_HIGHEST then
      invalid = true
      return ""
    end
    return string.char(byte - 64)
  end)
  if invalid then
    return nil
  end
  return text
end

---The value of a `^F` token: `mantissa * 2^exponent`, as Ace computes it,
---with one exception. When `2^exponent` alone underflows to zero, which
---happens for some subnormal numbers Ace's own writer produces, Ace reads 0
---although the product is representable; BridgeKit scales a finite mantissa
---with `ldexp` there and reads the number back exactly. Everywhere else,
---overflow to infinity and NaN included, the two agree.
---@param mantissa number
---@param exponent number
---@return number
local function scaleMantissa(mantissa, exponent)
  if
    exponent < SMALLEST_POWER_EXPONENT
    and exponent % 1 == 0
    and mantissa == mantissa
    and mantissa ~= math.huge
    and mantissa ~= -math.huge
  then
    if exponent < -EXPONENT_BOUND then
      exponent = -EXPONENT_BOUND
    end
    return ldexp(mantissa, exponent)
  end
  return mantissa * 2 ^ exponent
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

-- Reports --------------------------------------------------------------------
--
-- A report is the plain table the caller owns (design section 5.2): entries in
-- walk order up to `maxReportEntries`, a count per action, and how many
-- entries did not fit. No entry holds a value from the source: a path is made
-- of converted keys, which are identifiers BridgeKit wrote, and a field is an
-- Ace field name.

---A new, empty report of `kind`.
---@param kind "aceConfig"|"aceDB"
---@return BridgeKit.Report
local function newReport(kind)
  local counts = {}
  for index = 1, #REPORT_ACTIONS do
    counts[REPORT_ACTIONS[index]] = 0
  end
  return { kind = kind, entries = {}, counts = counts, truncated = 0 }
end

---Whether `list` holds `value`.
---@param list any[]
---@param value any
---@return boolean
local function listHolds(list, value)
  for index = 1, #list do
    if list[index] == value then
      return true
    end
  end
  return false
end

---Count one action and record its entry while `maxReportEntries` allows.
---@param report BridgeKit.Report
---@param path string the converted path, `""` for the root
---@param field string|nil the Ace field the entry is about
---@param action string
---@param reason string
local function noteEntry(report, path, field, action, reason)
  report.counts[action] = report.counts[action] + 1
  local entries = report.entries
  if exceeds(#entries + 1, limits.maxReportEntries) then
    report.truncated = report.truncated + 1
    return
  end
  entries[#entries + 1] = { path = path, field = field, action = action, reason = reason }
end

-- AceConfig adapter ------------------------------------------------------------
--
-- `ConvertAceConfig` walks an AceConfig-3.0 options table once, depth first,
-- and builds a new table in OptionsKit's vocabulary (design section 6). The
-- walk carries the inherited definitions AceConfigDialog would resolve for an
-- option (`get`, `set`, `func`, `confirm`, `validate`, `disabled`, `hidden`
-- and `handler`), so each converted option names its own callbacks, which
-- OptionsKit requires. Every Ace callback is wrapped: the wrapper calls it with
-- the option's Ace `info` and the arguments in Ace's shape, and looks a method
-- name up on the handler at call time, as Ace does.
--
-- A programming error found during the walk (a secret field, a limit passed)
-- is raised with `CONVERSION_ERROR_PREFIX` and turned into an error at the
-- caller's line by the public method; an error an Ace callback raises (a
-- `name` function evaluated once) propagates unchanged.

-- The fields AceConfigDialog inherits from an option's ancestors.
local INHERITED_FIELDS =
  { "get", "set", "func", "confirm", "validate", "disabled", "hidden", "handler" }

-- The per-interface flags each `uiType` folds into `hidden` and `inline`
-- (design section 6.2); the others are dropped.
local INTERFACE_FLAGS = {
  dialog = { hidden = { "guiHidden", "dialogHidden" }, inline = { "guiInline", "dialogInline" } },
  dropdown = { hidden = { "dropdownHidden" }, inline = { "dropdownInline" } },
  cmd = { hidden = { "cmdHidden" }, inline = { "cmdInline" } },
}
local HIDDEN_FLAGS = { "guiHidden", "dialogHidden", "dropdownHidden", "cmdHidden" }
local INLINE_FLAGS = { "guiInline", "dialogInline", "dropdownInline", "cmdInline" }

-- Fields every Ace option may carry that the conversion consumes itself, so
-- they are never reported as unknown.
local BASE_FIELDS = {
  type = true,
  name = true,
  desc = true,
  descStyle = true,
  order = true,
  validate = true,
  confirm = true,
  confirmText = true,
  disabled = true,
  hidden = true,
  tooltipHyperlink = true,
  icon = true,
  iconCoords = true,
  handler = true,
  get = true,
  set = true,
  func = true,
  arg = true,
  width = true,
  relWidth = true,
  control = true,
  dialogControl = true,
  dropdownControl = true,
  itemControl = true,
}
for index = 1, #HIDDEN_FLAGS do
  BASE_FIELDS[HIDDEN_FLAGS[index]] = true
end

-- Fields dropped everywhere as a presentation choice, and the custom AceGUI
-- controls.
local PRESENTATION_FIELDS =
  { "descStyle", "tooltipHyperlink", "icon", "iconCoords", "width", "relWidth" }
local CONTROL_FIELDS = { "control", "dialogControl", "dropdownControl", "itemControl" }

-- Per kind: the OptionsKit kind, and each own field with what happens to it.
-- `keep` copies the field when its type is one of `types`; `drop` reports it
-- as a presentation choice; the rest are handled by the kind's converter.
local KIND_FIELDS = {
  group = {
    kind = "group",
    own = {
      args = "args",
      plugins = "args",
      inline = "inline",
      childGroups = "drop",
      guiInline = "inline",
      dialogInline = "inline",
      dropdownInline = "inline",
      cmdInline = "inline",
    },
  },
  execute = {
    kind = "execute",
    own = { image = "drop", imageCoords = "drop", imageWidth = "drop", imageHeight = "drop" },
  },
  input = {
    kind = "input",
    value = true,
    own = { pattern = "keep", usage = "keep", multiline = "multiline" },
  },
  toggle = {
    kind = "toggle",
    value = true,
    own = {
      tristate = "keep",
      image = "drop",
      imageCoords = "drop",
      imageWidth = "drop",
      imageHeight = "drop",
    },
  },
  range = {
    kind = "range",
    value = true,
    own = {
      min = "bound",
      max = "bound",
      softMin = "keep",
      softMax = "keep",
      step = "keep",
      bigStep = "keep",
      isPercent = "keep",
    },
  },
  select = {
    kind = "select",
    value = true,
    own = { values = "values", sorting = "sorting", style = "drop" },
  },
  multiselect = {
    kind = "multiselect",
    value = true,
    own = { values = "values", sorting = "sorting", style = "drop", tristate = "tristate" },
  },
  color = { kind = "color", value = true, own = { hasAlpha = "hasAlpha" } },
  keybinding = { kind = "keybinding", value = true, own = {} },
  header = { kind = "header", own = {} },
  description = {
    kind = "description",
    own = {
      fontSize = "fontSize",
      image = "drop",
      imageCoords = "drop",
      imageWidth = "drop",
      imageHeight = "drop",
    },
  },
}

-- The fields OptionsKit accepts for each kept field, with the Lua types it
-- accepts; a field of another type is dropped and reported.
local KEPT_TYPES = {
  pattern = { string = true },
  usage = { string = true },
  tristate = { boolean = true },
  softMin = { number = true },
  softMax = { number = true },
  step = { number = true },
  bigStep = { number = true },
  isPercent = { boolean = true },
}

local FONT_SIZES = { small = true, medium = true, large = true }

-- The identifier rule OptionsKit applies to every key of `args`.
local IDENTIFIER_PATTERN = "^[%a_][%w_]*$"

-- The longest key a report path shows before it is cut, as SettingsKit cuts.
local PATH_KEY_LIMIT = 32

-- A conversion error is raised with this prefix, which no text an addon's own
-- error carries starts with, and re-raised at the caller's line by the public
-- method without it.
local CONVERSION_ERROR_PREFIX = "\0BridgeKit conversion error\0"

---Raise a conversion error for the public method to report at its caller.
---@param message string
local function conversionError(message)
  error(CONVERSION_ERROR_PREFIX .. message, 0)
end

---The value of `field` on an Ace table, refused when secret. `where` names the
---table in the message, `source.args.general`.
---@param work table
---@param aceTable table
---@param field string
---@param where string
---@return any
local function readField(work, aceTable, field, where)
  local value = rawget(aceTable, field)
  local probe = work.probe
  if probe ~= nil and type(value) ~= "nil" and probe(value) == true then
    conversionError(where .. "." .. field .. " must not be a secret value")
  end
  return value
end

---A report path: the converted keys joined with dots, each key longer than
---`PATH_KEY_LIMIT` bytes cut and marked.
---@param keys string[]
---@return string
local function renderPath(keys)
  local parts = {}
  for index = 1, #keys do
    local key = keys[index]
    if #key > PATH_KEY_LIMIT then
      key = stringSub(key, 1, PATH_KEY_LIMIT) .. "..."
    end
    parts[index] = key
  end
  return table.concat(parts, ".")
end

---A copy of `keys` with `key` appended.
---@param keys any[]
---@param key any
---@return any[]
local function extendKeys(keys, key)
  local extended = {}
  for index = 1, #keys do
    extended[index] = keys[index]
  end
  extended[#keys + 1] = key
  return extended
end

---A callback specification: an Ace function, or a method name looked up on
---the handler in force, or `false` when the field says none.
---@param value any
---@param handler any
---@return table|false|nil
local function callbackSpec(value, handler)
  if type(value) == "function" then
    return { fn = value }
  elseif type(value) == "string" then
    return { method = value, handler = handler }
  elseif value == false then
    return false
  end
  return nil
end

---Call an Ace callback with the Ace `info` and `...`. A method missing at call
---time raises Ace's own message (AceConfigDialog-3.0.lua:218-221).
---@param spec table
---@param aceInfo table
---@param member string the Ace field, for the message
---@return ...
local function callAce(spec, aceInfo, member, ...)
  local fn = spec.fn
  if fn ~= nil then
    return fn(aceInfo, ...)
  end
  local handler = spec.handler
  local method = type(handler) == "table" and handler[spec.method] or nil
  if type(method) ~= "function" then
    error("Method " .. spec.method .. " doesn't exist in handler for type " .. member, 2)
  end
  return method(handler, aceInfo, ...)
end

---Whether a method a spec names exists on its handler now.
---@param spec table
---@return boolean
local function methodExists(spec)
  if spec.fn ~= nil then
    return true
  end
  local handler = spec.handler
  return type(handler) == "table" and type(handler[spec.method]) == "function"
end

---Note a method name that names nothing on its handler at conversion.
---@param work table
---@param spec table|false|nil
---@param path string
---@param field string
local function checkMethod(work, spec, path, field)
  if spec and not methodExists(spec) then
    noteEntry(work.report, path, field, "changed", "missingMethod")
  end
end

---A predicate for OptionsKit (`disabled`, `hidden`) from one Ace value: a
---boolean is kept, a callback is wrapped.
---@param value any
---@param handler any
---@param aceInfo table
---@param member string
---@return boolean|function|nil
local function predicateFrom(value, handler, aceInfo, member)
  if type(value) == "boolean" then
    return value
  end
  local spec = callbackSpec(value, handler)
  if spec then
    return function()
      return callAce(spec, aceInfo, member)
    end
  end
  return nil
end

---Combine predicates into one that answers `true` when any of them does. A
---secret answer counts as `false`, as OptionsKit counts it.
---@param predicates table
---@return boolean|function|nil
local function anyOf(predicates)
  local count = #predicates
  if count == 0 then
    return nil
  end
  if count == 1 then
    return predicates[1]
  end
  local allBooleans = true
  for index = 1, count do
    if type(predicates[index]) ~= "boolean" then
      allBooleans = false
    elseif predicates[index] == true then
      return true
    end
  end
  if allBooleans then
    return false
  end
  return function(info)
    for index = 1, count do
      local predicate = predicates[index]
      local answer = predicate
      if type(predicate) == "function" then
        answer = predicate(info)
      end
      local probe = readSecretProbe()
      if answer == true and not (probe ~= nil and probe(answer) == true) then
        return true
      end
    end
    return false
  end
end

---The converted key of every key of `args`, in the sorted order of the
---original keys: an identifier keeps its name; any other key has every byte
---outside `[%w_]` replaced with `_`, a leading digit prefixed with `_`, and a
---collision with a sibling suffixed `_2`, `_3`, ... (design section 6.4).
---@param work table
---@param args table
---@param where string
---@return table<string, string> convertedFor original key to converted key
---@return string[] order the original keys, sorted
local function convertKeys(work, args, where)
  local originals = {}
  local probe = work.probe
  for key in next, args do
    if probe ~= nil and probe(key) == true then
      conversionError(where .. " must not have a secret key")
    end
    if type(key) == "string" then
      originals[#originals + 1] = key
    end
  end
  table.sort(originals)
  local used, convertedFor = {}, {}
  for index = 1, #originals do
    local key = originals[index]
    if stringFind(key, IDENTIFIER_PATTERN) ~= nil then
      used[key] = true
      convertedFor[key] = key
    end
  end
  for index = 1, #originals do
    local key = originals[index]
    if convertedFor[key] == nil then
      local base = string.gsub(key, "[^%w_]", "_")
      if base == "" or stringFind(base, "^%d") ~= nil then
        base = "_" .. base
      end
      local candidate, suffix = base, 1
      while used[candidate] do
        suffix = suffix + 1
        candidate = base .. "_" .. suffix
      end
      used[candidate] = true
      convertedFor[key] = candidate
    end
  end
  return convertedFor, originals
end

local convertOption

---The Ace `info` table of one option (AceConfigDialog-3.0.lua:201-209): the
---original keys at `1..n`, the app name at `[0]` and `appName`, the source
---root, the option's `arg`, `handler`, table and `type`, and the interface.
---@param work table
---@param aceKeys string[]
---@param aceOption table
---@param handler any
---@return table
local function aceInfoFor(work, aceKeys, aceOption, handler)
  local info = {}
  for index = 1, #aceKeys do
    info[index] = aceKeys[index]
  end
  info[0] = work.appName
  info.appName = work.appName
  info.options = work.root
  info.arg = rawget(aceOption, "arg")
  info.handler = handler
  info.option = aceOption
  info.type = rawget(aceOption, "type")
  info.uiType = work.uiType
  info.uiName = work.uiName
  return info
end

---The definitions in force for an option: its own where it has one, its
---parent's otherwise (AceConfigDialog-3.0.lua:131-139, 164-185).
---@param work table
---@param aceOption table
---@param inherited table
---@param where string
---@return table
local function resolveInherited(work, aceOption, inherited, where)
  local resolved = {}
  for index = 1, #INHERITED_FIELDS do
    local field = INHERITED_FIELDS[index]
    local own = readField(work, aceOption, field, where)
    if type(own) ~= "nil" then
      resolved[field] = own
    else
      resolved[field] = inherited[field]
    end
  end
  return resolved
end

---Convert `name`: a string is kept, a callback is called once with the Ace
---`info` and its string result kept.
---@param work table
---@param aceOption table
---@param target table
---@param context table
local function convertName(work, aceOption, target, context)
  local name = readField(work, aceOption, "name", context.where)
  if type(name) == "string" then
    target.name = name
    return
  end
  local spec = callbackSpec(name, context.handler)
  if spec then
    noteEntry(work.report, context.path, "name", "changed", "evaluatedOnce")
    local result = methodExists(spec) and callAce(spec, context.aceInfo, "name") or nil
    local probe = work.probe
    if probe ~= nil and type(result) ~= "nil" and probe(result) == true then
      conversionError(context.where .. ".name must not return a secret value")
    end
    if type(result) == "string" then
      target.name = result
      return
    end
  end
  target.name = context.aceKey
end

---Convert `order`: a number is kept, a callback is called once.
---@param work table
---@param aceOption table
---@param target table
---@param context table
local function convertOrder(work, aceOption, target, context)
  local order = readField(work, aceOption, "order", context.where)
  if type(order) == "number" then
    target.order = order
    return
  end
  local spec = callbackSpec(order, context.handler)
  if spec then
    noteEntry(work.report, context.path, "order", "changed", "evaluatedOnce")
    local result = methodExists(spec) and callAce(spec, context.aceInfo, "order") or nil
    local probe = work.probe
    if probe ~= nil and type(result) ~= "nil" and probe(result) == true then
      conversionError(context.where .. ".order must not return a secret value")
    end
    if type(result) == "number" then
      target.order = result
    end
  end
end

---Convert `desc`: a string is kept, a callback is wrapped so it reads the
---current state when a renderer describes the option.
---@param work table
---@param aceOption table
---@param target table
---@param context table
local function convertDescription(work, aceOption, target, context)
  local desc = readField(work, aceOption, "desc", context.where)
  if type(desc) == "string" then
    target.desc = desc
    return
  end
  local spec = callbackSpec(desc, context.handler)
  if spec then
    checkMethod(work, spec, context.path, "desc")
    local aceInfo = context.aceInfo
    target.desc = function()
      local text = callAce(spec, aceInfo, "desc")
      if type(text) == "string" then
        return text
      end
      return ""
    end
  end
end

---Report the fields every option may carry that the conversion drops.
---@param work table
---@param aceOption table
---@param context table
local function dropCommonFields(work, aceOption, context)
  for index = 1, #PRESENTATION_FIELDS do
    local field = PRESENTATION_FIELDS[index]
    if type(readField(work, aceOption, field, context.where)) ~= "nil" then
      noteEntry(work.report, context.path, field, "dropped", "presentation")
    end
  end
  for index = 1, #CONTROL_FIELDS do
    local field = CONTROL_FIELDS[index]
    if type(readField(work, aceOption, field, context.where)) ~= "nil" then
      noteEntry(work.report, context.path, field, "dropped", "customControl")
    end
  end
end

---Set `disabled` and `hidden`: the nearest definition, as Ace resolves it,
---with the hidden flags of `uiType` folded in. OptionsKit also applies every
---ancestor's flag, so an option that clears a flag an ancestor sets keeps it.
---@param work table
---@param aceOption table
---@param target table
---@param context table
local function convertFlags(work, aceOption, target, context)
  local resolved, aceInfo, handler = context.resolved, context.aceInfo, context.handler
  target.disabled = predicateFrom(resolved.disabled, handler, aceInfo, "disabled")

  local hiddenParts = {}
  local hidden = predicateFrom(resolved.hidden, handler, aceInfo, "hidden")
  if type(hidden) ~= "nil" then
    hiddenParts[1] = hidden
  end
  local folded = INTERFACE_FLAGS[work.uiType].hidden
  for index = 1, #HIDDEN_FLAGS do
    local field = HIDDEN_FLAGS[index]
    local value = readField(work, aceOption, field, context.where)
    if type(value) ~= "nil" then
      if listHolds(folded, field) then
        noteEntry(work.report, context.path, field, "changed", "perInterfaceFlag")
        hiddenParts[#hiddenParts + 1] = predicateFrom(value, handler, aceInfo, "hidden")
      else
        noteEntry(work.report, context.path, field, "dropped", "perInterfaceFlag")
      end
    end
  end
  target.hidden = anyOf(hiddenParts)

  for _, field in ipairs({ "disabled", "hidden" }) do
    local own = rawget(aceOption, field)
    if
      (own == false or type(own) == "function" or type(own) == "string")
      and context.ancestorFlags[field]
    then
      noteEntry(work.report, context.path, field, "changed", "cannotOverrideAncestor")
    end
  end
end

---The `values` of a select or multiselect: a table copied with its string and
---number keys and string labels, a callback wrapped the same way. Returns
---`nil` when nothing is left.
---@param work table
---@param aceOption table
---@param context table
---@return table|function|nil values
---@return table|nil staticValues the copied table, when `values` is one
local function convertValues(work, aceOption, context)
  local values = readField(work, aceOption, "values", context.where)
  local probe = work.probe
  if type(values) == "table" then
    local copy, count, dropped = {}, 0, false
    for key, label in next, values do
      if probe ~= nil and (probe(key) == true or probe(label) == true) then
        conversionError(context.where .. ".values must not hold a secret key or label")
      end
      if (type(key) == "string" or type(key) == "number") and type(label) == "string" then
        copy[key] = label
        count = count + 1
      else
        dropped = true
      end
    end
    if dropped then
      noteEntry(work.report, context.path, "values", "dropped", "valueKey")
    end
    if count == 0 then
      return nil, nil
    end
    return copy, copy
  end
  local spec = callbackSpec(values, context.handler)
  if not spec then
    return nil, nil
  end
  checkMethod(work, spec, context.path, "values")
  local aceInfo, report, path = context.aceInfo, work.report, context.path
  local reported = false
  return function()
    local answer = callAce(spec, aceInfo, "values")
    local copy = {}
    if type(answer) ~= "table" then
      return copy
    end
    for key, label in next, answer do
      if (type(key) == "string" or type(key) == "number") and type(label) == "string" then
        copy[key] = label
      elseif not reported then
        reported = true
        noteEntry(report, path, "values", "dropped", "valueKey")
      end
    end
    return copy
  end,
    nil
end

---Convert `sorting`: a table of keys of a table `values` is kept; a callback
---is called once; anything else is dropped.
---@param work table
---@param aceOption table
---@param target table
---@param staticValues table|nil
---@param context table
local function convertSorting(work, aceOption, target, staticValues, context)
  local sorting = readField(work, aceOption, "sorting", context.where)
  if type(sorting) == "nil" then
    return
  end
  local spec = callbackSpec(sorting, context.handler)
  if spec then
    noteEntry(work.report, context.path, "sorting", "changed", "evaluatedOnce")
    sorting = methodExists(spec) and callAce(spec, context.aceInfo, "sorting") or nil
  end
  if type(sorting) ~= "table" or staticValues == nil then
    noteEntry(work.report, context.path, "sorting", "dropped", "sortingKey")
    return
  end
  local copy = {}
  for index = 1, #sorting do
    local key = sorting[index]
    if type(key) == "nil" or staticValues[key] == nil then
      noteEntry(work.report, context.path, "sorting", "dropped", "sortingKey")
      return
    end
    copy[index] = key
  end
  target.sorting = copy
end

---Convert the getter and setter of a value option to OptionsKit's shape,
---or bind the option to the database. Returns `false` when the option has
---no accessor and cannot exist in OptionsKit.
---@param work table
---@param target table
---@param context table
---@return boolean converted
local function convertAccessors(work, target, context)
  local bindPath = work.bind[context.path]
  if bindPath ~= nil then
    target.bind = bindPath
    work.boundPaths[context.path] = true
    noteEntry(work.report, context.path, nil, "changed", "boundToDatabase")
    return true
  end
  local resolved, handler, aceInfo = context.resolved, context.handler, context.aceInfo
  local getSpec = callbackSpec(resolved.get, handler)
  local setSpec = callbackSpec(resolved.set, handler)
  if not getSpec or not setSpec then
    noteEntry(work.report, context.path, nil, "unsupported", "noAccessor")
    return false
  end
  checkMethod(work, getSpec, context.path, "get")
  checkMethod(work, setSpec, context.path, "set")
  local kind = target.type
  if kind == "color" then
    target.get = function()
      local red, green, blue, alpha = callAce(getSpec, aceInfo, "get")
      if type(red) == "nil" then
        return nil
      end
      return { r = red, g = green, b = blue, a = target.hasAlpha and alpha or nil }
    end
    target.set = function(_, color)
      callAce(setSpec, aceInfo, "set", color.r, color.g, color.b, color.a)
    end
  elseif kind == "multiselect" then
    local keysOf = context.keysOf
    target.get = function(info)
      local states = {}
      for key in next, keysOf(info) do
        states[key] = callAce(getSpec, aceInfo, "get", key) == true
      end
      return states
    end
    target.set = function(info, states)
      for key in next, keysOf(info) do
        local wanted = states[key] == true
        if (callAce(getSpec, aceInfo, "get", key) == true) ~= wanted then
          callAce(setSpec, aceInfo, "set", key, wanted)
        end
      end
    end
  else
    target.get = function()
      return (callAce(getSpec, aceInfo, "get"))
    end
    target.set = function(_, value)
      callAce(setSpec, aceInfo, "set", value)
    end
  end
  return true
end

---Wrap the resolved `validate`: `true` accepts, a string refuses with that
---message, anything else with the option's `usage` or `"invalid value"`; a
---secret answer refuses without being compared (design section 6.1).
---@param work table
---@param target table
---@param context table
local function convertValidate(work, target, context)
  local spec = callbackSpec(context.resolved.validate, context.handler)
  if not spec then
    return
  end
  checkMethod(work, spec, context.path, "validate")
  local aceInfo, kind = context.aceInfo, target.type
  local fallback = type(target.usage) == "string" and target.usage or "invalid value"
  local function verdict(answer)
    local probe = readSecretProbe()
    if probe ~= nil and type(answer) ~= "nil" and probe(answer) == true then
      return false, fallback
    end
    if answer == true then
      return true
    end
    if type(answer) == "string" then
      return false, answer
    end
    return false, fallback
  end
  if kind == "color" then
    target.validate = function(_, color)
      return verdict(callAce(spec, aceInfo, "validate", color.r, color.g, color.b, color.a))
    end
  elseif kind == "multiselect" then
    local getSpec = callbackSpec(context.resolved.get, context.handler)
    local keysOf = context.keysOf
    target.validate = function(info, states)
      for key in next, keysOf(info) do
        local wanted = states[key] == true
        if not getSpec or (callAce(getSpec, aceInfo, "get", key) == true) ~= wanted then
          local ok, message = verdict(callAce(spec, aceInfo, "validate", key, wanted))
          if not ok then
            return false, message
          end
        end
      end
      return true
    end
  else
    target.validate = function(_, value)
      return verdict(callAce(spec, aceInfo, "validate", value))
    end
  end
end

---Convert `confirm` and `confirmText` on an `execute`, and report them on
---any other kind, where OptionsKit asks for no confirmation.
---@param work table
---@param aceOption table
---@param target table
---@param context table
local function convertConfirm(work, aceOption, target, context)
  local confirm = context.resolved.confirm
  local confirmText = readField(work, aceOption, "confirmText", context.where)
  if target.type ~= "execute" then
    if type(confirm) ~= "nil" and confirm ~= false then
      noteEntry(work.report, context.path, "confirm", "dropped", "confirmOnValue")
    end
    return
  end
  if confirm == true then
    target.confirm = type(confirmText) == "string" and confirmText or true
  elseif callbackSpec(confirm, context.handler) then
    noteEntry(work.report, context.path, "confirm", "changed", "dynamicConfirm")
    target.confirm = type(confirmText) == "string" and confirmText or true
  end
end

---Convert the own fields of a value or display option: kept fields, range
---bounds, `values` and `sorting`, `multiline`, `hasAlpha`, `fontSize`, and
---report the dropped ones and any field the kind does not know.
---@param work table
---@param aceOption table
---@param target table
---@param spec table the kind's entry in `KIND_FIELDS`
---@param context table
---@return boolean converted `false` when the option cannot exist in OptionsKit
local function convertOwnFields(work, aceOption, target, spec, context)
  local report, path, where = work.report, context.path, context.where
  local own = spec.own
  for field, rule in next, own do
    local value = readField(work, aceOption, field, where)
    if type(value) ~= "nil" then
      if rule == "keep" then
        if KEPT_TYPES[field][type(value)] then
          target[field] = value
        else
          noteEntry(report, path, field, "dropped", "presentation")
        end
      elseif rule == "drop" then
        noteEntry(report, path, field, "dropped", "presentation")
      elseif rule == "multiline" then
        if value == true then
          target.multiline = true
        elseif type(value) == "number" then
          target.multiline = true
          noteEntry(report, path, field, "changed", "lineCount")
        end
      elseif rule == "hasAlpha" then
        if type(value) == "boolean" then
          target.hasAlpha = value
        else
          local callback = callbackSpec(value, context.handler)
          if callback then
            noteEntry(report, path, field, "changed", "evaluatedOnce")
            local answer = methodExists(callback) and callAce(callback, context.aceInfo, "hasAlpha")
              or nil
            local probe = work.probe
            if probe ~= nil and type(answer) ~= "nil" and probe(answer) == true then
              conversionError(where .. ".hasAlpha must not return a secret value")
            end
            target.hasAlpha = answer == true
          end
        end
      elseif rule == "fontSize" then
        -- A string is the size itself; only a function is evaluated.
        local size = value
        local callback = type(value) == "function" and callbackSpec(value, context.handler) or nil
        if callback then
          noteEntry(report, path, field, "changed", "evaluatedOnce")
          size = methodExists(callback) and callAce(callback, context.aceInfo, "fontSize") or nil
        end
        if type(size) == "string" and FONT_SIZES[size] then
          target.fontSize = size
        else
          noteEntry(report, path, field, "dropped", "fontSize")
        end
      elseif rule == "tristate" then
        noteEntry(report, path, field, "changed", "multiselectTristate")
      end
    end
  end
  for field in next, aceOption do
    if type(field) == "string" and not BASE_FIELDS[field] and own[field] == nil then
      noteEntry(report, path, field, "dropped", "unknownField")
    end
  end

  if spec.kind == "range" then
    local minimum = readField(work, aceOption, "min", where)
    local maximum = readField(work, aceOption, "max", where)
    if type(minimum) ~= "number" then
      minimum = type(target.softMin) == "number" and -math.huge or 0
      noteEntry(report, path, "min", "changed", "defaultBound")
    end
    if type(maximum) ~= "number" then
      maximum = type(target.softMax) == "number" and math.huge or 100
      noteEntry(report, path, "max", "changed", "defaultBound")
    end
    target.min, target.max = minimum, maximum
    if type(target.step) == "number" then
      noteEntry(report, path, "step", "changed", "stepNotEnforced")
    end
  elseif spec.kind == "select" or spec.kind == "multiselect" then
    local values, staticValues = convertValues(work, aceOption, context)
    if values == nil then
      noteEntry(report, path, "values", "unsupported", "emptyValues")
      return false
    end
    target.values = values
    convertSorting(work, aceOption, target, staticValues, context)
    if type(values) == "table" then
      context.keysOf = function()
        return values
      end
    else
      context.keysOf = function(info)
        return values(info)
      end
    end
  end
  return true
end

---Merge a group's `plugins` into its `args`: a plugin key that collides with
---an `args` key wins, as `GetSubOption` searches plugins first
---(AceConfigDialog-3.0.lua:117-127), and the shadowed one is reported.
---@param work table
---@param aceGroup table
---@param context table
---@return table merged original key to Ace option
local function mergedArgs(work, aceGroup, context)
  local merged = {}
  local args = readField(work, aceGroup, "args", context.where)
  if type(args) == "table" then
    for key, option in next, args do
      merged[key] = option
    end
  end
  local plugins = readField(work, aceGroup, "plugins", context.where)
  if type(plugins) == "table" then
    for _, pluginArgs in next, plugins do
      if type(pluginArgs) == "table" then
        for key, option in next, pluginArgs do
          if type(args) == "table" and rawget(args, key) ~= nil then
            noteEntry(work.report, context.path, "plugins", "dropped", "pluginShadowed")
          end
          merged[key] = option
        end
      end
    end
  end
  return merged
end

---Convert a group's children into `target.args`.
---@param work table
---@param aceGroup table
---@param target table
---@param context table
local function convertChildren(work, aceGroup, target, context)
  local args = mergedArgs(work, aceGroup, context)
  local convertedFor, order = convertKeys(work, args, context.where .. ".args")
  target.args = {}
  local ancestorFlags = {
    disabled = context.ancestorFlags.disabled
      or (type(rawget(aceGroup, "disabled")) ~= "nil" and rawget(aceGroup, "disabled") ~= false),
    hidden = context.ancestorFlags.hidden
      or (type(rawget(aceGroup, "hidden")) ~= "nil" and rawget(aceGroup, "hidden") ~= false),
  }
  for index = 1, #order do
    local aceKey = order[index]
    local child = args[aceKey]
    local probe = work.probe
    if probe ~= nil and probe(child) == true then
      conversionError(context.where .. ".args must not hold a secret option")
    end
    if type(child) ~= "table" then
      noteEntry(
        work.report,
        renderPath(extendKeys(context.keys, convertedFor[aceKey])),
        nil,
        "unsupported",
        "unknownType"
      )
    else
      local key = convertedFor[aceKey]
      local childKeys = extendKeys(context.keys, key)
      local childAceKeys = extendKeys(context.aceKeys, aceKey)
      local childPath = renderPath(childKeys)
      if key ~= aceKey then
        noteEntry(work.report, childPath, nil, "renamed", "identifier")
      end
      local converted = convertOption(work, child, {
        keys = childKeys,
        aceKeys = childAceKeys,
        aceKey = aceKey,
        path = childPath,
        where = context.where
          .. ".args"
          .. (
            stringFind(aceKey, IDENTIFIER_PATTERN) and ("." .. aceKey)
            or ("[" .. string.format("%q", aceKey) .. "]")
          ),
        inherited = context.resolved,
        ancestorFlags = ancestorFlags,
      })
      if converted ~= nil then
        target.args[key] = converted
      end
    end
  end
end

---Convert one Ace option, or return `nil` when it cannot exist in OptionsKit.
---@param work table
---@param aceOption table
---@param context table
---@return table|nil
function convertOption(work, aceOption, context)
  local depth = #context.keys
  if depth > work.maxDepth then
    conversionError(context.where .. " is deeper than options.maxDepth (" .. work.maxDepth .. ")")
  end
  if depth > work.deepest then
    work.deepest = depth
  end

  local path = context.path
  local replacement = work.replace[path]
  if replacement ~= nil then
    work.replaced[path] = true
    noteEntry(work.report, path, nil, "changed", "replaced")
    work.optionCount = work.optionCount + 1
    work.paths[path] = context.aceKeys
    return replacement
  end

  local aceType = readField(work, aceOption, "type", context.where)
  local spec = type(aceType) == "string" and KIND_FIELDS[aceType] or nil
  if spec == nil then
    noteEntry(work.report, path, "type", "unsupported", "unknownType")
    return nil
  end
  if depth > 0 then
    work.optionCount = work.optionCount + 1
    if exceeds(work.optionCount, work.maxOptions) then
      conversionError(
        "source has more than options.maxOptions (" .. tostring(work.maxOptions) .. ") options"
      )
    end
  end

  context.resolved = resolveInherited(work, aceOption, context.inherited, context.where)
  context.handler = context.resolved.handler
  context.aceInfo = aceInfoFor(work, context.aceKeys, aceOption, context.handler)

  local target = { type = spec.kind }
  if depth > 0 or type(rawget(aceOption, "name")) ~= "nil" then
    convertName(work, aceOption, target, context)
  end
  convertOrder(work, aceOption, target, context)
  convertDescription(work, aceOption, target, context)
  dropCommonFields(work, aceOption, context)
  convertFlags(work, aceOption, target, context)

  if spec.kind == "group" then
    if readField(work, aceOption, "inline", context.where) == true then
      target.inline = true
    end
    local folded = INTERFACE_FLAGS[work.uiType].inline
    for index = 1, #INLINE_FLAGS do
      local field = INLINE_FLAGS[index]
      local value = readField(work, aceOption, field, context.where)
      if type(value) ~= "nil" then
        if listHolds(folded, field) then
          noteEntry(work.report, path, field, "changed", "perInterfaceFlag")
          if value == true then
            target.inline = true
          end
        else
          noteEntry(work.report, path, field, "dropped", "perInterfaceFlag")
        end
      end
    end
    if type(readField(work, aceOption, "childGroups", context.where)) ~= "nil" then
      noteEntry(work.report, path, "childGroups", "dropped", "presentation")
    end
    for field in next, aceOption do
      if type(field) == "string" and not BASE_FIELDS[field] and spec.own[field] == nil then
        noteEntry(work.report, path, field, "dropped", "unknownField")
      end
    end
    convertChildren(work, aceOption, target, context)
  else
    if not convertOwnFields(work, aceOption, target, spec, context) then
      return nil
    end
    if spec.value then
      if not convertAccessors(work, target, context) then
        return nil
      end
      convertValidate(work, target, context)
    elseif spec.kind == "execute" then
      local funcSpec = callbackSpec(context.resolved.func, context.handler)
      if not funcSpec then
        noteEntry(work.report, path, "func", "unsupported", "noAccessor")
        return nil
      end
      checkMethod(work, funcSpec, path, "func")
      local aceInfo = context.aceInfo
      target.func = function()
        callAce(funcSpec, aceInfo, "func")
      end
    end
  end
  convertConfirm(work, aceOption, target, context)
  -- A converted option is counted, never listed: the report lists what changed.
  if depth > 0 then
    work.report.counts.converted = work.report.counts.converted + 1
  end
  if depth > 0 then
    work.paths[path] = context.aceKeys
  end
  return target
end

-- Conversion methods ---------------------------------------------------------

-- The options `ConvertAceConfig` accepts, and `DefineAceConfig` with `db`.
local CONVERT_OPTION_KEYS = {
  uiType = true,
  uiName = true,
  bind = true,
  replace = true,
  strict = true,
  maxOptions = true,
  maxDepth = true,
}
local DEFINE_OPTION_KEYS = { db = true }
for key in next, CONVERT_OPTION_KEYS do
  DEFINE_OPTION_KEYS[key] = true
end

-- OptionsKit's own defaults, which the conversion applies too.
local DEFAULT_MAX_OPTIONS = 1024
local DEFAULT_OPTION_DEPTH = 8
local MAX_OPTION_DEPTH = 32

---Raise at the caller's caller: `label` and the problem.
---@param label string
---@param problem string
local function refuseOption(label, problem)
  error(label .. " " .. problem, 4)
end

---Validate the options of `ConvertAceConfig` or `DefineAceConfig` and return
---them with their defaults. Every check comes before anything else runs.
---@param label string
---@param options any
---@param allowed table<string, true>
---@return table
local function readConvertOptions(label, options, allowed)
  local read = {
    uiType = "dialog",
    uiName = "BridgeKit-1",
    bind = {},
    replace = {},
    strict = false,
    maxOptions = DEFAULT_MAX_OPTIONS,
    maxDepth = DEFAULT_OPTION_DEPTH,
  }
  if type(options) == "nil" then
    return read
  end
  if type(options) ~= "table" then
    refuseOption(label, "options must be a table or nil")
  end
  local probe = readSecretProbe()
  for key, value in next, options do
    if probe ~= nil and probe(key) == true then
      refuseOption(label, "options must not have a secret key")
    end
    if type(key) ~= "string" or not allowed[key] then
      refuseOption(
        label,
        "options has no field named "
          .. (type(key) == "string" and key or ("[" .. type(key) .. "]"))
      )
    end
    if probe ~= nil and probe(value) == true then
      refuseOption(label, "options." .. key .. " must not be a secret value")
    end
  end
  local uiType = rawget(options, "uiType")
  if type(uiType) ~= "nil" then
    if type(uiType) ~= "string" or INTERFACE_FLAGS[uiType] == nil then
      refuseOption(label, 'options.uiType must be "dialog", "dropdown" or "cmd"')
    end
    read.uiType = uiType
  end
  local uiName = rawget(options, "uiName")
  if type(uiName) ~= "nil" then
    -- AceConfigRegistry-3.0.lua:307 holds an interface name to this shape.
    if type(uiName) ~= "string" or stringFind(uiName, "[A-Za-z]%-[0-9]") == nil then
      refuseOption(label, 'options.uiName must be a string like "MyAddon-1"')
    end
    read.uiName = uiName
  end
  for _, field in ipairs({ "bind", "replace" }) do
    local map = rawget(options, field)
    if type(map) ~= "nil" then
      if type(map) ~= "table" then
        refuseOption(label, "options." .. field .. " must be a table of option paths")
      end
      for path, target in next, map do
        if probe ~= nil and (probe(path) == true or probe(target) == true) then
          refuseOption(label, "options." .. field .. " must not hold a secret path or value")
        end
        local wanted = field == "bind" and "string" or "table"
        if type(path) ~= "string" or type(target) ~= wanted then
          refuseOption(label, "options." .. field .. " must map option paths to " .. wanted .. "s")
        end
      end
      read[field] = map
    end
  end
  local strict = rawget(options, "strict")
  if type(strict) ~= "nil" then
    if type(strict) ~= "boolean" then
      refuseOption(label, "options.strict must be a boolean")
    end
    read.strict = strict
  end
  local maxOptions = rawget(options, "maxOptions")
  if type(maxOptions) ~= "nil" then
    if maxOptions ~= UNBOUNDED and not isIntegerUpTo(maxOptions, 2 ^ 53) then
      refuseOption(label, "options.maxOptions must be a positive integer or BridgeKit.UNBOUNDED")
    end
    read.maxOptions = maxOptions
  end
  local maxDepth = rawget(options, "maxDepth")
  if type(maxDepth) ~= "nil" then
    if not isIntegerUpTo(maxDepth, MAX_OPTION_DEPTH) then
      refuseOption(label, "options.maxDepth must be an integer from 1 to " .. MAX_OPTION_DEPTH)
    end
    read.maxDepth = maxDepth
  end
  if allowed.db then
    read.db = rawget(options, "db")
  end
  return read
end

---Check the arguments shared by both conversion methods.
---@param label string
---@param name any
---@param nameLabel string
---@param source any
local function validateConversionArguments(label, name, nameLabel, source)
  local probe = readSecretProbe()
  if type(name) ~= "string" or (probe ~= nil and probe(name) == true) or name == "" then
    if type(name) == "string" and probe ~= nil and probe(name) == true then
      refuseOption(label, nameLabel .. " must not be a secret value")
    end
    refuseOption(label, nameLabel .. " must be a non-empty string")
  end
  if probe ~= nil and probe(source) == true then
    refuseOption(label, "source must not be a secret value")
  end
  if type(source) ~= "table" and type(source) ~= "function" then
    refuseOption(label, "source must be a table or a function")
  end
end

---Convert after the arguments were checked. Returns the conversion, or raises
---a conversion error for a problem found in the source.
---@param appName string
---@param source table|function
---@param read table the options with their defaults
---@return BridgeKit.Conversion
local function convert(appName, source, read)
  local report = newReport("aceConfig")
  local root = source
  if type(source) == "function" then
    -- AceConfigRegistry-3.0.lua:331-341 calls an options function this way.
    root = source(read.uiType, read.uiName, appName)
    if type(root) ~= "table" then
      conversionError("source function did not return a table")
    end
    noteEntry(report, "", nil, "changed", "sourceFunction")
  end
  ---@cast root table
  local work = {
    probe = readSecretProbe(),
    report = report,
    appName = appName,
    root = root,
    uiType = read.uiType,
    uiName = read.uiName,
    bind = read.bind,
    replace = read.replace,
    boundPaths = {},
    replaced = {},
    paths = {},
    optionCount = 0,
    maxOptions = read.maxOptions,
    maxDepth = read.maxDepth,
    deepest = 0,
  }
  local rootType = readField(work, root, "type", "source")
  if rootType ~= "group" then
    -- The same rule as AceConfigRegistry-3.0.lua:319-321.
    conversionError('source.type must be "group" at the root')
  end
  local tree = convertOption(work, root, {
    keys = {},
    aceKeys = {},
    aceKey = appName,
    path = "",
    where = "source",
    inherited = {},
    ancestorFlags = {},
  })
  for _, field in ipairs({ "bind", "replace" }) do
    local seen = field == "bind" and work.boundPaths or work.replaced
    for path in next, work[field] do
      if not seen[path] then
        conversionError("options." .. field .. " names no converted option: " .. path)
      end
    end
  end
  return {
    tree = tree,
    report = report,
    paths = work.paths,
    maxDepth = math.max(work.deepest, 1),
    optionCount = work.optionCount,
  }
end

---Raise for `strict` when the report holds anything but renames.
---@param label string
---@param report BridgeKit.Report
local function enforceStrict(label, report)
  local counts = report.counts
  local problems = counts.dropped + counts.changed + counts.unsupported
  if problems == 0 then
    return
  end
  local first = ""
  for _, entry in ipairs(report.entries) do
    if entry.action ~= "renamed" then
      first = "; first: "
        .. (entry.path == "" and "(root)" or entry.path)
        .. (entry.field and (" " .. entry.field) or "")
        .. " ("
        .. entry.reason
        .. ")"
      break
    end
  end
  refuseOption(label, "strict: " .. problems .. " fields changed or dropped" .. first)
end

---Run `fn(...)`; a conversion error it raises becomes an error at the
---public method's caller, any other error propagates unchanged.
---@param label string
---@param fn function
---@return ...
local function runConversion(label, fn, ...)
  local results = { pcall(fn, ...) }
  if results[1] then
    return unpack(results, 2, table.maxn(results))
  end
  local failure = results[2]
  local prefixLength = #CONVERSION_ERROR_PREFIX
  if
    type(failure) == "string" and stringSub(failure, 1, prefixLength) == CONVERSION_ERROR_PREFIX
  then
    error(label .. " " .. stringSub(failure, prefixLength + 1), 3)
  end
  error(failure, 0)
end

---Convert an AceConfig-3.0 options table, or a function returning one, into a
---table for `OptionsKit:Define` and a report (design section 5.3). Raises at
---the caller for a programming error; everything about the data is in the
---report.
---@param self BridgeKit
---@param appName string
---@param source table|function
---@param options BridgeKit.ConvertOptions?
---@return BridgeKit.Conversion
local function convertAceConfig(self, appName, source, options)
  local label = "BridgeKit:ConvertAceConfig"
  validateFacade(self, label, 3)
  validateConversionArguments(label, appName, "appName", source)
  local read = readConvertOptions(label, options, CONVERT_OPTION_KEYS)
  local conversion = runConversion(label, convert, appName, source, read)
  if read.strict then
    enforceStrict(label, conversion.report)
  end
  return conversion
end

---`ConvertAceConfig`, then `OptionsKit:Define` with the converted tree
---(design section 5.4). Returns the tree handle and the report.
---@param self BridgeKit
---@param addonName string
---@param source table|function
---@param options BridgeKit.DefineOptions?
---@return table tree the OptionsKit tree handle
---@return BridgeKit.Report report
local function defineAceConfig(self, addonName, source, options)
  local label = "BridgeKit:DefineAceConfig"
  validateFacade(self, label, 3)
  validateConversionArguments(label, addonName, "addonName", source)
  local read = readConvertOptions(label, options, DEFINE_OPTION_KEYS)
  local OptionsKit, reason = Registry:Find("optionsKit", 1)
  if type(OptionsKit) ~= "table" then
    error(
      label .. " requires OptionsKit API 1, which is not loaded (" .. tostring(reason) .. ")",
      2
    )
  end
  local conversion = runConversion(label, convert, addonName, source, read)
  if read.strict then
    enforceStrict(label, conversion.report)
  end
  local ok, result = pcall(OptionsKit.Define, OptionsKit, addonName, conversion.tree, {
    db = read.db,
    maxOptions = read.maxOptions == UNBOUNDED and OptionsKit.UNBOUNDED or read.maxOptions,
    maxDepth = conversion.maxDepth,
  })
  if not ok then
    local message = type(result) == "string" and string.gsub(result, "^[^\n]-:%d+: ", "")
      or tostring(result)
    error(label .. " " .. message, 2)
  end
  return result, conversion.report
end

---Display lines for a report: `"<path> <field>: <action> (<reason>)"`, at
---most `maxLines` of them (50 by default), then one summary line. Safe to
---print: a report holds no value from the source.
---@param self BridgeKit
---@param report BridgeKit.Report
---@param maxLines integer?
---@return string[]
local function formatReport(self, report, maxLines)
  local label = "BridgeKit:FormatReport"
  validateFacade(self, label, 3)
  if
    type(report) ~= "table"
    or type(report.entries) ~= "table"
    or type(report.counts) ~= "table"
  then
    error(label .. " report must be a report BridgeKit returned", 2)
  end
  if type(maxLines) == "nil" then
    maxLines = 50
  elseif not isIntegerUpTo(maxLines, 2 ^ 31) then
    error(label .. " maxLines must be a positive integer", 2)
  end
  local lines = {}
  local entries = report.entries
  for index = 1, math.min(#entries, maxLines) do
    local entry = entries[index]
    local path = entry.path == "" and "(root)" or entry.path
    local field = entry.field and (" " .. entry.field) or ""
    lines[index] = path .. field .. ": " .. entry.action .. " (" .. entry.reason .. ")"
  end
  local summary = {}
  for _, action in ipairs(REPORT_ACTIONS) do
    local count = report.counts[action]
    if type(count) == "number" and (count > 0 or action == "converted") then
      summary[#summary + 1] = count .. " " .. action
    end
  end
  local hidden = #entries - math.min(#entries, maxLines) + (report.truncated or 0)
  if hidden > 0 then
    summary[#summary + 1] = hidden .. " more not shown"
  end
  lines[#lines + 1] = table.concat(summary, ", ")
  return lines
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
rawset(BridgeKit, "ConvertAceConfig", convertAceConfig)
rawset(BridgeKit, "DefineAceConfig", defineAceConfig)
rawset(BridgeKit, "FormatReport", formatReport)
rawset(BridgeKit, "SetLimits", setLimits)
rawset(BridgeKit, "GetLimits", getLimits)

if not validatePublicSurface(BridgeKit) or not validateCurrentState(BridgeKit) then
  error("MoltenCodes BridgeKit package state is corrupted or incomplete", 2)
end

return BridgeKit
