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
--   PreviewAceDB      an AceDB-3.0 saved variable rebuilt in the SettingsKit
--   ImportAceDB       layout, every value checked against the addon's
--   AceDBMigration    schema and AceDB defaults that differ written as values
--                     (design section 7, step N3).
--   OpenAceComm       an AceComm-3.0 channel on one prefix through a
--   GetStatistics     CommKit scope: the bytes AceComm sends, and AceComm's
--                     reassembly with bounds (design section 8.3, step N4).
--
-- BridgeKit needs Registry API 2. `DefineAceConfig` finds OptionsKit API 1
-- through `Registry:Find` when it is called; without it, it raises at the
-- caller, and `ConvertAceConfig` still returns a plain tree table. The AceDB
-- importer finds SchemaKit API 1 the same way, and reads SettingsKit's
-- profile-name limit when SettingsKit API 1 is loaded. `OpenAceComm` needs
-- CommKit API 1 with raw addon messages (revision 8 and later).
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
--   AceDB importer ........ the walk from an AceDB table to SettingsKit's layout
--   AceComm channel ....... AceComm's framing through CommKit's raw messages
--   Package public API .... the facade published through Registry
--   Commit ................ facade assignment and self-check

-- Constants ------------------------------------------------------------------

local PACKAGE_NAME = "bridgeKit"
local API_GENERATION = 1
local IMPLEMENTATION_REVISION = 4
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
  "maxImportEntries",
  "maxAceStreams",
  "maxAceStreamsPerSender",
  "maxAceStreamBytes",
  "maxAceSpoolBytes",
  "aceStreamTimeout",
  "maxDropReportSenders",
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
  maxImportEntries = { default = 65536, ceiling = 2 ^ 30, unbounded = true },
  maxAceStreams = { default = 64, ceiling = 1024, unboundedRefusal = "other players grow it" },
  maxAceStreamsPerSender = { default = 4, ceiling = 64, unboundedRefusal = "other players grow it" },
  maxAceStreamBytes = { default = 65536, ceiling = 1048576, unboundedRefusal = "a peer chooses it" },
  maxAceSpoolBytes = {
    default = 1048576,
    ceiling = 2 ^ 26,
    unboundedRefusal = "other players grow it",
  },
  aceStreamTimeout = {
    default = 30,
    ceiling = 600,
    unboundedRefusal = "a stream a peer never finishes would be held forever",
  },
  maxDropReportSenders = {
    default = 64,
    ceiling = 1024,
    unboundedRefusal = "other players grow it",
  },
  maxListValues = {
    default = 4096,
    ceiling = 7900,
    unboundedRefusal = "AceDeserialize returns its values through unpack, which the Lua stack bounds",
  },
}

-- The actions a report counts, in the order `FormatReport` sums them up
-- (design section 5.2): a conversion's, and an import's.
local REPORT_ACTIONS = { "converted", "dropped", "changed", "renamed", "unsupported" }
local IMPORT_ACTIONS =
  { "imported", "materialised", "dropped", "changed", "renamed", "unsupported" }

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
---@field maxImportEntries (integer|table)? Entries one AceDB import walks or copies; `BridgeKit.UNBOUNDED` lifts it.
---@field maxAceStreams integer? AceComm streams held at once, every prefix and sender.
---@field maxAceStreamsPerSender integer? AceComm streams one sender may hold.
---@field maxAceStreamBytes integer? Bytes of one AceComm stream.
---@field maxAceSpoolBytes integer? Bytes of every AceComm stream held.
---@field aceStreamTimeout integer? Seconds a stream may go without a part.
---@field maxDropReportSenders integer? Senders the drop reports track before the rest share one entry.

---One report entry. No entry holds a value from the source.
---@class BridgeKit.ReportEntry
---@field path string The converted option path, or the saved-variable path; `""` for the root.
---@field field string? The Ace field the entry is about.
---@field action "dropped"|"changed"|"renamed"|"unsupported"|"materialised"
---@field reason string From the vocabulary in docs/API.md.
---@field detail string? Text BridgeKit wrote: SchemaKit's path, rule and expectation for `schemaRefused`.

---What a conversion did, entry by entry and counted.
---@class BridgeKit.Report
---@field kind "aceConfig"|"aceDB"
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

---Where an AceDB scope SettingsKit lacks goes.
---@class BridgeKit.ScopeDestination
---@field into "global"
---@field field string A declared `map` field of the global scope.

---Where an AceDB namespace goes.
---@class BridgeKit.NamespaceDestination
---@field field string A declared record or map field of the scopes the namespace has data for.
---@field defaults table? That namespace's AceDB defaults.

---The plan the AceDB importer methods accept.
---@class BridgeKit.ImportPlan
---@field schema table The schema table the addon passes to `SettingsKit:Open`.
---@field aceDefaults table? The defaults table the addon passed to `AceDB:New`.
---@field scopes table<string, BridgeKit.ScopeDestination>?
---@field namespaces table<string, BridgeKit.NamespaceDestination>?
---@field renameProfile (fun(name: string): string?)?
---@field renameCharacter (fun(key: string): string?)?
---@field version integer? `ImportAceDB` only: stamped into the target.
---@field backup string? The global that receives the backup; required by `AceDBMigration`.
---@field replaceBackup boolean? Overwrite a backup global that holds data.
---@field onReport (fun(report: BridgeKit.Report))? `AceDBMigration` only.

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
---@field PreviewAceDB fun(self: BridgeKit, source: table|string, plan: BridgeKit.ImportPlan): BridgeKit.Report, string?
---@field ImportAceDB fun(self: BridgeKit, source: table|string, targetName: string, plan: BridgeKit.ImportPlan): BridgeKit.Report|nil, string?, BridgeKit.Report?
---@field AceDBMigration fun(self: BridgeKit, plan: BridgeKit.ImportPlan): fun(raw: table)
---@field OpenAceComm fun(self: BridgeKit, scope: table, prefix: string, callback: fun(prefix: string, message: string, distribution: string, sender: string), options: table?): table|nil, string?
---@field GetStatistics fun(self: BridgeKit): table
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
  "PreviewAceDB",
  "ImportAceDB",
  "AceDBMigration",
  "OpenAceComm",
  "GetStatistics",
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
---@return table|nil entry the stored entry, or `nil` when the report is full
local function noteEntry(report, path, field, action, reason)
  report.counts[action] = report.counts[action] + 1
  local entries = report.entries
  if exceeds(#entries + 1, limits.maxReportEntries) then
    report.truncated = report.truncated + 1
    return nil
  end
  local entry = { path = path, field = field, action = action, reason = reason }
  entries[#entries + 1] = entry
  return entry
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

-- OptionsKit's ceiling on keys per option path; also bounds the measure of a
-- replacement option.
local MAX_OPTION_DEPTH = 32

local measureOption

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

---Whether `value` is secret on this client; never tests it otherwise.
---@param value any
---@return boolean
local function isSecretValue(value)
  local probe = readSecretProbe()
  return probe ~= nil and type(value) ~= "nil" and probe(value) == true
end

---A multiselect state as OptionsKit holds it: a secret answer is placed
---unexamined, any other is read for truth.
---@param answer any
---@return any
local function stateOf(answer)
  if isSecretValue(answer) then
    return answer
  end
  return answer and true or false
end

---Call a callback once at conversion, reporting it `evaluatedOnce`, and also
---`missingMethod` when its method names nothing; `nil` when it cannot run.
---@param work table
---@param spec table
---@param context table
---@param field string
---@return any
local function evaluateOnce(work, spec, context, field)
  noteEntry(work.report, context.path, field, "changed", "evaluatedOnce")
  if not methodExists(spec) then
    noteEntry(work.report, context.path, field, "changed", "missingMethod")
    return nil
  end
  return (callAce(spec, context.aceInfo, field))
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
    elseif predicates[index] then
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
      -- A secret answer counts as false and is never tested for truth;
      -- any other truthy answer hides, as OptionsKit and Ace both read it.
      local probe = readSecretProbe()
      if not (probe ~= nil and type(answer) ~= "nil" and probe(answer) == true) and answer then
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
    else
      -- OptionsKit keys are identifiers, and Ace's validator refuses any key
      -- that is not a string; such an option cannot be carried over.
      work.nonStringKeys = (work.nonStringKeys or 0) + 1
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

local convertOption, convertBody

---The options and levels of an OptionsKit option given to `replace`: the
---option itself and every option below it, and the depth of its deepest
---descendant (0 for the option alone). Bounded by `MAX_OPTION_DEPTH`, which
---also stops a cyclic table.
---@param option any
---@param level integer
---@return integer options
---@return integer levels
function measureOption(option, level)
  if type(option) ~= "table" or level > MAX_OPTION_DEPTH then
    return 1, 0
  end
  local options, levels = 1, 0
  local args = rawget(option, "args")
  if type(args) == "table" then
    for _, child in next, args do
      local childOptions, childLevels = measureOption(child, level + 1)
      options = options + childOptions
      if childLevels + 1 > levels then
        levels = childLevels + 1
      end
    end
  end
  return options, levels
end

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
    local result = evaluateOnce(work, spec, context, "name")
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
    if order == order then
      target.order = order
    else
      noteEntry(work.report, context.path, "order", "dropped", "malformedField")
    end
    return
  end
  local spec = callbackSpec(order, context.handler)
  if spec then
    local result = evaluateOnce(work, spec, context, "order")
    local probe = work.probe
    if probe ~= nil and type(result) ~= "nil" and probe(result) == true then
      conversionError(context.where .. ".order must not return a secret value")
    end
    if type(result) == "number" and result == result then
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
    if count > work.largestValues then
      work.largestValues = count
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
    sorting = evaluateOnce(work, spec, context, "sorting")
  end
  if type(sorting) ~= "table" or staticValues == nil then
    noteEntry(work.report, context.path, "sorting", "dropped", "sortingKey")
    return
  end
  local copy = {}
  for index = 1, #sorting do
    local key = sorting[index]
    if type(key) == "nil" or isSecretValue(key) or staticValues[key] == nil then
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
  local bindPath = work.bind[context.optionPath]
  if bindPath ~= nil then
    target.bind = bindPath
    work.boundPaths[context.optionPath] = true
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
        states[key] = stateOf(callAce(getSpec, aceInfo, "get", key))
      end
      return states
    end
    target.set = function(info, states)
      for key in next, keysOf(info) do
        local wanted = states[key] == true
        local current = callAce(getSpec, aceInfo, "get", key)
        -- A secret state cannot be compared, so its key is always written.
        if isSecretValue(current) or (current and true or false) ~= wanted then
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

---Wrap the resolved `validate`: a string refuses with that message, `false`
---or `nil` with the option's `usage` or `"invalid value"`, anything else
---accepts, as in Ace; a secret answer refuses without being compared.
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
    -- Ace refuses only a string (its message), `false` or `nil`; any other
    -- answer accepts (AceConfigDialog-3.0.lua:741-750).
    if type(answer) == "string" then
      return false, answer
    end
    if not answer then
      return false, fallback
    end
    return true
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
        local current = getSpec and callAce(getSpec, aceInfo, "get", key) or nil
        if not getSpec or isSecretValue(current) or (current and true or false) ~= wanted then
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
    checkMethod(work, callbackSpec(confirm, context.handler), context.path, "confirm")
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
        if KEPT_TYPES[field][type(value)] and (type(value) ~= "number" or value == value) then
          target[field] = value
        else
          noteEntry(report, path, field, "dropped", "malformedField")
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
            local answer = evaluateOnce(work, callback, context, "hasAlpha")
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
          size = evaluateOnce(work, callback, context, "fontSize")
        end
        if type(size) == "string" and not isSecretValue(size) and FONT_SIZES[size] then
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
    if type(minimum) ~= "number" or minimum ~= minimum then
      -- The dialog's own bound (AceConfigDialog-3.0.lua:877), unless it would
      -- cross the bound the option gives.
      minimum = type(target.softMin) == "number" and -math.huge or 0
      if type(maximum) == "number" and maximum < minimum then
        minimum = -math.huge
      end
      noteEntry(report, path, "min", "changed", "defaultBound")
    end
    if type(maximum) ~= "number" or maximum ~= maximum then
      maximum = type(target.softMax) == "number" and math.huge or 100
      if maximum < minimum then
        maximum = math.huge
      end
      noteEntry(report, path, "max", "changed", "defaultBound")
    end
    if minimum > maximum then
      noteEntry(report, path, "min", "unsupported", "malformedField")
      return false
    end
    target.min, target.max = minimum, maximum
    -- OptionsKit refuses hints it cannot honour; Ace draws them anyway.
    for _, hint in ipairs({ "step", "bigStep" }) do
      if type(target[hint]) == "number" and not (target[hint] > 0) then
        target[hint] = nil
        noteEntry(report, path, hint, "dropped", "malformedField")
      end
    end
    for _, hint in ipairs({ "softMin", "softMax" }) do
      if type(target[hint]) == "number" and (target[hint] < minimum or target[hint] > maximum) then
        target[hint] = nil
        noteEntry(report, path, hint, "dropped", "malformedField")
      end
    end
    if
      type(target.softMin) == "number"
      and type(target.softMax) == "number"
      and target.softMin > target.softMax
    then
      target.softMin, target.softMax = nil, nil
      noteEntry(report, path, "softMin", "dropped", "malformedField")
    end
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
  elseif type(args) ~= "nil" then
    noteEntry(work.report, context.path, "args", "dropped", "malformedField")
  end
  local plugins = readField(work, aceGroup, "plugins", context.where)
  if type(plugins) == "table" then
    -- Plugins are merged in the sorted order of their names, so which of two
    -- plugins defining one key wins does not depend on `next`.
    local names = {}
    for name in next, plugins do
      if type(name) == "string" then
        names[#names + 1] = name
      end
    end
    table.sort(names)
    for _, name in ipairs(names) do
      local pluginArgs = rawget(plugins, name)
      if type(pluginArgs) == "table" then
        for key, option in next, pluginArgs do
          if type(merged[key]) ~= "nil" then
            noteEntry(work.report, context.path, "plugins", "dropped", "pluginShadowed")
          end
          merged[key] = option
        end
      else
        noteEntry(work.report, context.path, "plugins", "dropped", "malformedField")
      end
    end
  elseif type(plugins) ~= "nil" then
    noteEntry(work.report, context.path, "plugins", "dropped", "malformedField")
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
  work.nonStringKeys = 0
  local convertedFor, order = convertKeys(work, args, context.where .. ".args")
  if work.nonStringKeys > 0 then
    noteEntry(work.report, context.path, "args", "unsupported", "unknownType")
  end
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
      -- The report shows a path with long keys cut; `bind`, `replace` and
      -- `paths` use the whole one.
      local childPath = renderPath(childKeys)
      local childOptionPath = table.concat(childKeys, ".")
      if key ~= aceKey then
        noteEntry(work.report, childPath, nil, "renamed", "identifier")
      end
      local converted = convertOption(work, child, {
        keys = childKeys,
        aceKeys = childAceKeys,
        aceKey = aceKey,
        path = childPath,
        optionPath = childOptionPath,
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
  local replacement = work.replace[context.optionPath]
  if replacement ~= nil then
    work.replaced[context.optionPath] = true
    noteEntry(work.report, path, nil, "changed", "replaced")
    -- The replacement's own options and depth count toward what OptionsKit
    -- checks, so `maxDepth` and `optionCount` describe the tree it receives.
    local options, levels = measureOption(replacement, 0)
    work.optionCount = work.optionCount + options
    if exceeds(work.optionCount, work.maxOptions) then
      conversionError(
        "source has more than options.maxOptions (" .. tostring(work.maxOptions) .. ") options"
      )
    end
    if depth + levels > work.deepest then
      work.deepest = depth + levels
    end
    work.paths[context.optionPath] = context.aceKeys
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
  local converted = convertBody(work, aceOption, spec, target, context)
  if not converted then
    if depth > 0 then
      work.optionCount = work.optionCount - 1
    end
    return nil
  end
  -- A converted option is counted, never listed: the report lists what changed.
  if depth > 0 then
    work.report.counts.converted = work.report.counts.converted + 1
    work.paths[context.optionPath] = context.aceKeys
  end
  return target
end

---Convert the fields of one option into `target`. Returns `false` when the
---option cannot exist in OptionsKit.
---@param work table
---@param aceOption table
---@param spec table the kind's entry in `KIND_FIELDS`
---@param target table
---@param context table
---@return boolean
function convertBody(work, aceOption, spec, target, context)
  local path, depth = context.path, #context.keys
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
      return false
    end
    if spec.value then
      if not convertAccessors(work, target, context) then
        return false
      end
      convertValidate(work, target, context)
    elseif spec.kind == "execute" then
      local funcSpec = callbackSpec(context.resolved.func, context.handler)
      if not funcSpec then
        noteEntry(work.report, path, "func", "unsupported", "noAccessor")
        return false
      end
      checkMethod(work, funcSpec, path, "func")
      local aceInfo = context.aceInfo
      target.func = function()
        callAce(funcSpec, aceInfo, "func")
      end
    end
  end
  convertConfirm(work, aceOption, target, context)
  return true
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

---Raise at the caller's caller: `label` and the problem.
---@param label string
---@param problem string
---@param level integer|nil the `error` level, 4 unless the check runs deeper
local function refuseOption(label, problem, level)
  error(label .. " " .. problem, level or 4)
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
    largestValues = 0,
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
    optionPath = "",
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
    largestValues = work.largestValues,
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
    -- A values table larger than OptionsKit's default is the addon's own data,
    -- which Ace accepted; the tree is defined with room for it.
    maxDynamicEntries = conversion.largestValues > DEFAULT_MAX_OPTIONS and conversion.largestValues
      or nil,
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
  local actions = report.kind == "aceDB" and IMPORT_ACTIONS or REPORT_ACTIONS
  for _, action in ipairs(actions) do
    local count = report.counts[action]
    if type(count) == "number" and (count > 0 or action == actions[1]) then
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

-- Report paths for saved-variable keys --------------------------------------
--
-- Shared by the AceDB importer and the AceComm channel, which live in blocks
-- of their own below.

---A report path segment for one key: an identifier as it is, any other key
---bracketed, with strings quoted and escaped the way SchemaKit renders keys
---(`|` doubled, `\` and `"` escaped, other control bytes `\ddd`), and cut past
---`PATH_KEY_LIMIT` bytes.
---@param key any
---@return string
local function renderKey(key)
  if type(key) == "string" then
    if stringFind(key, IDENTIFIER_PATTERN) ~= nil and #key <= PATH_KEY_LIMIT then
      return key
    end
    local shown = #key > PATH_KEY_LIMIT and stringSub(key, 1, PATH_KEY_LIMIT) or key
    shown = string.gsub(shown, '[%c|\\"]', function(character)
      if character == "|" then
        return "||"
      elseif character == "\\" or character == '"' then
        return "\\" .. character
      end
      return string.format("\\%03d", string.byte(character))
    end)
    return '["' .. shown .. (#key > PATH_KEY_LIMIT and '..."]' or '"]')
  elseif type(key) == "number" then
    return "[" .. (key == key and string.format("%.14g", key) or "NaN") .. "]"
  elseif type(key) == "boolean" then
    return "[" .. tostring(key) .. "]"
  end
  return "[" .. type(key) .. "]"
end

---`path` with `key` appended as a report path segment.
---@param path string
---@param key any
---@return string
local function joinPath(path, key)
  local segment = renderKey(key)
  if path == "" then
    return segment
  end
  if stringSub(segment, 1, 1) == "[" then
    return path .. segment
  end
  return path .. "." .. segment
end

-- The importer and the channel each live in a `do` block that exports only
-- its public methods: the main chunk of a Lua 5.1 file holds at most 200
-- locals, and their helpers would pass that.
local previewAceDB, importAceDB, aceDBMigration
local openAceComm, getStatistics

do
  -- AceDB importer ---------------------------------------------------------------
  --
  -- The importer reads an AceDB-3.0 saved variable and builds the SettingsKit
  -- layout of API generation 1 from it (design section 7, SettingsKit's
  -- `docs/API.md`, "The saved table"). Every value is checked against the
  -- SettingsKit schema the addon will open with before it is written: a probe
  -- table holding only the path to that value is checked with the scope's
  -- sealed schema, which is sound because every field of a SettingsKit record is
  -- optional. Where the source holds nothing, an AceDB default that differs from
  -- the SettingsKit default is written as a value, so every field reads after
  -- the import what it read under AceDB (design section 7.6).
  --
  -- Walking is bounded twice: by SchemaKit's `maxDepth` for nesting, and by
  -- `maxImportEntries` for the whole source; passing the second refuses the
  -- import as a whole.

  -- The SettingsKit scopes, and where each lives in the layout.
  local SECTION_FOR_SCOPE = {
    global = "global",
    profile = "profiles",
    char = "char",
    realm = "realm",
    class = "class",
    faction = "faction",
  }
  local KEYED_SCOPES = { "char", "realm", "class", "faction" }

  -- AceDB scopes SettingsKit lacks (design section 7.3).
  local UNSUPPORTED_SCOPES = { "race", "factionrealm", "factionrealmregion", "locale" }

  -- Every top-level key of an AceDB saved variable the importer knows.
  local ACE_TOP_LEVEL = {
    profileKeys = true,
    profiles = true,
    global = true,
    char = true,
    realm = true,
    class = true,
    faction = true,
    race = true,
    factionrealm = true,
    factionrealmregion = true,
    locale = true,
    namespaces = true,
  }

  -- The sections of a namespace, in the order they are imported, and the
  -- SettingsKit scope each one maps to.
  local NAMESPACE_SECTIONS = {
    { "global", "global" },
    { "profiles", "profile" },
    { "char", "char" },
    { "realm", "realm" },
    { "class", "class" },
    { "faction", "faction" },
  }

  -- The plan fields each importer method accepts.
  local PLAN_FIELDS = {
    preview = {
      schema = true,
      aceDefaults = true,
      scopes = true,
      namespaces = true,
      renameProfile = true,
      renameCharacter = true,
    },
  }
  PLAN_FIELDS.import = { version = true, backup = true, replaceBackup = true }
  PLAN_FIELDS.migration = { backup = true, replaceBackup = true, onReport = true }
  for _, mode in ipairs({ "import", "migration" }) do
    for field in next, PLAN_FIELDS.preview do
      PLAN_FIELDS[mode][field] = true
    end
  end

  -- An import that passes `maxImportEntries` stops with this error, which the
  -- public method turns into its `"maxImportEntries"` refusal.
  local IMPORT_OVERFLOW = "\0BridgeKit import overflow\0"

  -- The interface numbers of the clients whose AceDB keys characters and realms
  -- by name and ruleset (design section 7.3).
  local RULESET_INTERFACE_FIRST, RULESET_INTERFACE_LAST = 16000, 19999

  -- The longest profile name SettingsKit accepts when it is not loaded to ask.
  local DEFAULT_PROFILE_NAME_LENGTH = 64

  local copyCounted, mergeSpecs, applySpec

  ---Count one entry of the source, and stop the walk past `maxImportEntries`.
  ---@param ctx table
  local function countEntry(ctx)
    ctx.entries = ctx.entries + 1
    if exceeds(ctx.entries, ctx.maxEntries) then
      error(IMPORT_OVERFLOW, 0)
    end
  end

  ---The keys of `source` in a stable order: by type, then by value.
  ---@param source table
  ---@return any[]
  local function sortedKeys(source, ctx, path)
    local keys = {}
    local probe = readSecretProbe()
    local secret = false
    for key in next, source do
      -- A key is counted as it is met, so a huge section stops the walk
      -- before it is sorted; a secret one is never compared.
      if ctx ~= nil then
        countEntry(ctx)
      end
      if probe ~= nil and probe(key) == true then
        secret = true
      else
        keys[#keys + 1] = key
      end
    end
    if secret and ctx ~= nil then
      noteEntry(ctx.report, path or "", nil, "dropped", "secretValue")
    end
    local rank = { string = 1, number = 2, boolean = 3 }
    table.sort(keys, function(left, right)
      local leftType, rightType = type(left), type(right)
      if leftType ~= rightType then
        return (rank[leftType] or 4) < (rank[rightType] or 4)
      end
      if leftType == "string" or leftType == "number" then
        return left < right
      end
      if leftType == "boolean" then
        return left == false and right == true
      end
      return false
    end)
    return keys
  end

  ---Whether two values are deeply equal: tables entry by entry, NaN never.
  ---@param left any
  ---@param right any
  ---@param depth integer?
  ---@return boolean
  local function deepEqual(left, right, depth)
    depth = depth or 0
    if left == right then
      return true
    end
    if type(left) ~= "table" or type(right) ~= "table" or depth > MAX_OPTION_DEPTH * 4 then
      return false
    end
    for key, value in next, left do
      if not deepEqual(value, rawget(right, key), depth + 1) then
        return false
      end
    end
    for key in next, right do
      if type(rawget(left, key)) == "nil" then
        return false
      end
    end
    return true
  end

  ---Two AceDB default specifications as one: `first`'s entries win, `second`
  ---fills the rest, tables merged all the way down. AceDB applies an explicit
  ---table default and then `"**"` to the same saved table, each filling only
  ---what is still missing (AceDB-3.0.lua:118-124).
  ---@param first table
  ---@param second table
  ---@param depth integer
  ---@return table
  function mergeSpecs(first, second, depth)
    local merged = {}
    for field, value in next, first do
      merged[field] = value
    end
    if depth > MAX_OPTION_DEPTH * 4 then
      return merged
    end
    for field, value in next, second do
      local held = merged[field]
      if type(held) == "nil" then
        merged[field] = value
      elseif type(held) == "table" and type(value) == "table" then
        merged[field] = mergeSpecs(held, value, depth + 1)
      end
    end
    return merged
  end

  ---What AceDB reads for a saved value under a default specification: the
  ---value with every default it lacks filled in, explicit defaults first, then
  ---`"**"` under explicit table defaults, and `"*"`/`"**"` table defaults into
  ---the value's own table entries (AceDB-3.0.lua:89-132). Works on `value`,
  ---which the caller has copied; keys a wildcard would create on first read are
  ---not invented.
  ---@param value table
  ---@param spec table
  ---@param depth integer
  ---@return table value
  function applySpec(value, spec, depth)
    if depth > MAX_OPTION_DEPTH * 4 then
      return value
    end
    local everywhere = rawget(spec, "**")
    for field, default in next, spec do
      if field == "*" or field == "**" then
        if type(default) == "table" then
          for key, held in next, value do
            if type(rawget(spec, key)) == "nil" and type(held) == "table" then
              applySpec(held, default, depth + 1)
            end
          end
        end
      elseif type(default) == "table" then
        if type(rawget(value, field)) == "nil" then
          rawset(value, field, {})
        end
        local held = rawget(value, field)
        if type(held) == "table" then
          applySpec(held, default, depth + 1)
          if type(everywhere) == "table" then
            applySpec(held, everywhere, depth + 1)
          end
        end
      elseif type(rawget(value, field)) == "nil" then
        rawset(value, field, default)
      end
    end
    return value
  end

  ---The AceDB default for `key` in a defaults table: the explicit entry, merged
  ---deeply over `"**"` when both are tables, else `"*"`, else `"**"`
  ---(AceDB-3.0.lua:93-124).
  ---@param defaults any
  ---@param key any
  ---@return any
  local function aceDefaultFor(defaults, key)
    if type(defaults) ~= "table" then
      return nil
    end
    local explicit = rawget(defaults, key)
    local everywhere = rawget(defaults, "**")
    if type(explicit) ~= "nil" then
      if type(explicit) == "table" and type(everywhere) == "table" then
        return mergeSpecs(explicit, everywhere, 0)
      end
      return explicit
    end
    local unnamed = rawget(defaults, "*")
    if type(unnamed) ~= "nil" then
      return unnamed
    end
    return everywhere
  end

  ---Why a value can never be stored in a saved variable, or `nil` when it can:
  ---a function, userdata or coroutine anywhere in it, a table with a metatable,
  ---or a secret.
  ---@param ctx table
  ---@param value any
  ---@param depth integer
  ---@return string|nil reason
  local function unstorable(ctx, value, depth)
    local probe = ctx.probe
    if probe ~= nil and probe(value) == true then
      return "secretValue"
    end
    local valueType = type(value)
    if valueType == "function" or valueType == "userdata" or valueType == "thread" then
      return "notStorable"
    end
    if valueType ~= "table" then
      return nil
    end
    if depth > ctx.maxDepth then
      return "tooDeep"
    end
    if getmetatable(value) ~= nil then
      return "notStorable"
    end
    for key, entry in next, value do
      countEntry(ctx)
      local reason = unstorable(ctx, key, depth + 1) or unstorable(ctx, entry, depth + 1)
      if reason ~= nil then
        return reason
      end
    end
    return nil
  end

  ---A copy of a storable value; tables are copied, a table reached twice once.
  ---@param value any
  ---@param copies table|nil
  ---@return any
  local function copyValue(value, copies)
    if type(value) ~= "table" then
      return value
    end
    copies = copies or {}
    local existing = copies[value]
    if existing ~= nil then
      return existing
    end
    local copy = {}
    copies[value] = copy
    for key, entry in next, value do
      copy[copyValue(key, copies)] = copyValue(entry, copies)
    end
    return copy
  end

  ---A copy of `value` for a backup, counting every entry against
  ---`maxImportEntries`; a table reached twice is copied once and stays shared.
  ---@param ctx table
  ---@param value any
  ---@param copies table
  ---@return any
  function copyCounted(ctx, value, copies)
    if type(value) ~= "table" then
      return value
    end
    -- An own work list rather than recursion, so no nesting depth reaches
    -- the Lua stack (design section 7.4).
    local root = {}
    copies[value] = root
    local pending = { value }
    while #pending > 0 do
      local original = table.remove(pending)
      local copy = copies[original]
      for key, entry in next, original do
        countEntry(ctx)
        local copiedKey, copiedEntry = key, entry
        if type(key) == "table" then
          copiedKey = copies[key]
          if copiedKey == nil then
            copiedKey = {}
            copies[key] = copiedKey
            pending[#pending + 1] = key
          end
        end
        if type(entry) == "table" then
          copiedEntry = copies[entry]
          if copiedEntry == nil then
            copiedEntry = {}
            copies[entry] = copiedEntry
            pending[#pending + 1] = entry
          end
        end
        copy[copiedKey] = copiedEntry
      end
    end
    return root
  end

  ---Check `value` at `keys` of `scope` with the scope's schema, through a probe
  ---table that holds only that path. Returns `true`, or `false` and the
  ---failure's detail, which holds SchemaKit's path, rule and expectation, never
  ---the value.
  ---@param ctx table
  ---@param scope string
  ---@param keys any[]
  ---@param value any
  ---@return boolean ok
  ---@return string|nil detail
  local function checkAt(ctx, scope, keys, value)
    local probe = value
    for index = #keys, 1, -1 do
      probe = { [keys[index]] = probe }
    end
    local ok, failure = ctx.scopes[scope].schema:Check(probe)
    if ok then
      return true, nil
    end
    local where = failure.path ~= "" and (failure.path .. " ") or ""
    return false, where .. failure.rule .. ": expected " .. tostring(failure.expected)
  end

  ---Note a refused value with SchemaKit's explanation.
  ---@param ctx table
  ---@param path string
  ---@param detail string|nil
  local function noteRefused(ctx, path, detail)
    local entry = noteEntry(ctx.report, path, nil, "dropped", "schemaRefused")
    if entry ~= nil then
      entry.detail = detail
    end
  end

  ---Report, once per field of a scope, a field whose reading changes with the
  ---import because the source holds nothing there and the two defaults differ:
  ---AceDB had none and SettingsKit has one, or the AceDB default cannot be
  ---written.
  ---@param ctx table
  ---@param scope string
  ---@param keys any[] the path inside the scope
  local function noteDefaultOnce(ctx, scope, keys)
    local parts = {}
    for index = 1, #keys do
      parts[index] = renderKey(keys[index])
    end
    local key = scope .. "\0" .. table.concat(parts, "\0")
    if ctx.notedDefaults[key] then
      return
    end
    ctx.notedDefaults[key] = true
    local path = scope
    for index = 1, #keys do
      path = joinPath(path, keys[index])
    end
    noteEntry(ctx.report, path, nil, "changed", "defaultDiffers")
  end

  local importRecord, importMap

  ---Import one value field: the source value when there is one and the schema
  ---accepts it, otherwise the AceDB default when it differs from the
  ---SettingsKit default (design section 7.6).
  ---@param ctx table
  ---@param scope string
  ---@param keys any[] the path inside the scope, this field's key last
  ---@param path string
  ---@param sourceValue any
  ---@param aceDefault any
  ---@param settingsDefault any
  ---@return boolean written, any value
  local function importValue(ctx, scope, keys, path, sourceValue, aceDefault, settingsDefault)
    local candidate, materialising = sourceValue, false
    if type(sourceValue) == "nil" then
      if type(aceDefault) == "nil" then
        -- AceDB read nothing here; SettingsKit will read its default.
        if type(settingsDefault) ~= "nil" and ctx.aceDefaults ~= nil then
          noteDefaultOnce(ctx, scope, keys)
        end
        return false, nil
      end
      candidate = aceDefault
      if type(aceDefault) == "table" then
        candidate = applySpec({}, aceDefault, 0)
      end
      if deepEqual(candidate, settingsDefault) then
        return false, nil
      end
      materialising = true
    elseif type(sourceValue) == "table" and type(aceDefault) == "table" then
      -- AceDB fills a saved table's missing entries from its default.
      local merged = applySpec(copyValue(sourceValue), aceDefault, 0)
      if not deepEqual(merged, sourceValue) then
        candidate, materialising = merged, true
      end
    end
    local reason = unstorable(ctx, candidate, #keys)
    if reason ~= nil then
      noteEntry(ctx.report, path, nil, "dropped", reason)
      return false, nil
    end
    local ok, detail = checkAt(ctx, scope, keys, candidate)
    if not ok then
      noteRefused(ctx, path, detail)
      return false, nil
    end
    if materialising then
      noteEntry(ctx.report, path, nil, "materialised", "defaultDiffers")
    else
      ctx.report.counts.imported = ctx.report.counts.imported + 1
    end
    return true, copyValue(candidate)
  end

  ---Import a field of a record: a nested record or map is walked into, any
  ---other kind is imported whole.
  ---@param ctx table
  ---@param scope string
  ---@param describe table the field's description
  ---@param keys any[]
  ---@param path string
  ---@param sourceValue any
  ---@param aceDefault any
  ---@param settingsDefault any
  ---@return boolean written, any value
  local function importField(
    ctx,
    scope,
    describe,
    keys,
    path,
    sourceValue,
    aceDefault,
    settingsDefault
  )
    local probe = ctx.probe
    if probe ~= nil and type(sourceValue) ~= "nil" and probe(sourceValue) == true then
      noteEntry(ctx.report, path, nil, "dropped", "secretValue")
      return false, nil
    end
    local kind = describe.kind
    if
      (kind == "table" or kind == "map")
      and type(sourceValue) ~= "nil"
      and type(sourceValue) ~= "table"
    then
      local _, detail = checkAt(ctx, scope, keys, sourceValue)
      noteRefused(ctx, path, detail)
      return false, nil
    end
    if kind == "table" then
      local nested = settingsDefault
      if type(nested) ~= "table" then
        nested = describe.default
      end
      local record = importRecord(ctx, scope, describe, keys, path, sourceValue, aceDefault, nested)
      return record ~= nil, record
    elseif kind == "map" then
      local entries = importMap(ctx, scope, describe, keys, path, sourceValue, aceDefault)
      return entries ~= nil, entries
    end
    return importValue(ctx, scope, keys, path, sourceValue, aceDefault, settingsDefault)
  end

  ---Import a record (a SchemaKit `table`). Returns the new table, or `nil` when
  ---nothing in it was written.
  ---@param ctx table
  ---@param scope string
  ---@param describe table
  ---@param keys any[]
  ---@param path string
  ---@param source table|nil
  ---@param aceDefaults any
  ---@param settingsDefaults table|nil the record's own default, when it has one
  ---@return table|nil
  function importRecord(ctx, scope, describe, keys, path, source, aceDefaults, settingsDefaults)
    if #keys >= ctx.maxDepth then
      noteEntry(ctx.report, path, nil, "dropped", "tooDeep")
      return nil
    end
    local result, written = {}, false
    local fields = describe.fields or {}
    -- Every key of the source is counted once, here, before any is walked.
    local sourceKeys = type(source) == "table" and sortedKeys(source, ctx, path) or {}
    for _, name in ipairs(describe.fieldNames or {}) do
      local sourceValue = source and rawget(source, name)
      local settingsDefault = fields[name].default
      if type(settingsDefaults) == "table" and type(rawget(settingsDefaults, name)) ~= "nil" then
        settingsDefault = rawget(settingsDefaults, name)
      end
      local ok, value = importField(
        ctx,
        scope,
        fields[name],
        extendKeys(keys, name),
        joinPath(path, name),
        sourceValue,
        aceDefaultFor(aceDefaults, name),
        settingsDefault
      )
      if ok then
        result[name], written = value, true
      end
    end
    local held = {}
    for _, key in ipairs(sourceKeys) do
      -- `sourceKeys` is empty unless `source` is a table.
      ---@cast source table
      held[key] = true
      if type(key) ~= "string" or fields[key] == nil then
        local keyPath = joinPath(path, key)
        if describe.open then
          -- An undeclared field of an open record reads what AceDB read,
          -- its AceDB default merged in.
          local ok, value = importValue(
            ctx,
            scope,
            extendKeys(keys, key),
            keyPath,
            rawget(source, key),
            aceDefaultFor(aceDefaults, key),
            nil
          )
          if ok then
            result[key], written = value, true
          end
        else
          local _, detail = checkAt(ctx, scope, extendKeys(keys, key), true)
          noteRefused(ctx, keyPath, detail)
        end
      end
    end
    -- AceDB defaults for keys the record does not declare: an open record
    -- takes them, a closed one cannot, which changes what the key reads.
    if type(aceDefaults) == "table" then
      for _, key in ipairs(sortedKeys(aceDefaults)) do
        if
          key ~= "*"
          and key ~= "**"
          and not held[key]
          and (type(key) ~= "string" or fields[key] == nil)
        then
          if describe.open then
            local ok, value = importValue(
              ctx,
              scope,
              extendKeys(keys, key),
              joinPath(path, key),
              nil,
              aceDefaultFor(aceDefaults, key),
              nil
            )
            if ok then
              result[key], written = value, true
            end
          else
            noteDefaultOnce(ctx, scope, extendKeys(keys, key))
          end
        end
      end
    end
    if not written then
      return nil
    end
    return result
  end

  ---Import a map (a SchemaKit `map`): every key the source holds, in sorted
  ---order up to the map's `max`, each entry walked when the map's values are
  ---records. Returns the new table, or `nil` when nothing was written.
  ---@param ctx table
  ---@param scope string
  ---@param describe table
  ---@param keys any[]
  ---@param path string
  ---@param source table|nil
  ---@param aceDefaults any
  ---@return table|nil
  function importMap(ctx, scope, describe, keys, path, source, aceDefaults)
    local valueDescribe = describe.values or { kind = "any" }
    local wildcardDefault = valueDescribe.default
    local aceWildcard = type(aceDefaults) == "table"
        and (rawget(aceDefaults, "*") or rawget(aceDefaults, "**"))
      or nil
    if type(aceWildcard) ~= "nil" and not deepEqual(aceWildcard, wildcardDefault) then
      noteEntry(ctx.report, path, nil, "changed", "wildcardDefaultDiffers")
    end
    local result, count = {}, 0
    local maximum = describe.max
    local function importEntry(key, sourceEntry)
      local settingsDefault = wildcardDefault
      if type(describe.default) == "table" and type(rawget(describe.default, key)) ~= "nil" then
        settingsDefault = rawget(describe.default, key)
      end
      local ok, value = importField(
        ctx,
        scope,
        valueDescribe,
        extendKeys(keys, key),
        joinPath(path, key),
        sourceEntry,
        aceDefaultFor(aceDefaults, key),
        settingsDefault
      )
      -- A record entry the source holds stays an entry even when nothing in
      -- it differs from the defaults: a map's keys are data of their own.
      if
        not ok
        and valueDescribe.kind == "table"
        and type(sourceEntry) == "table"
        and #keys + 1 < ctx.maxDepth
        and not (ctx.probe ~= nil and ctx.probe(sourceEntry) == true)
      then
        ok, value = true, {}
      end
      if ok then
        result[key], count = value, count + 1
      end
    end
    local held = {}
    local dropped = false
    if type(source) == "table" then
      for _, key in ipairs(sortedKeys(source, ctx, path)) do
        held[key] = true
        if type(maximum) == "number" and count >= maximum then
          dropped = true
        else
          importEntry(key, rawget(source, key))
        end
      end
    end
    -- A key the source lacks reads AceDB's default for it under AceDB (an
    -- explicit entry, or the wildcard for a key the map's own default names)
    -- and the map's default under SettingsKit; it is materialised when the
    -- two differ. Keys past `max` are reported like source keys are.
    local defaultKeys = {}
    if type(aceDefaults) == "table" then
      for _, key in ipairs(sortedKeys(aceDefaults)) do
        if key ~= "*" and key ~= "**" then
          defaultKeys[#defaultKeys + 1] = key
        end
      end
    end
    if type(describe.default) == "table" then
      for _, key in ipairs(sortedKeys(describe.default)) do
        defaultKeys[#defaultKeys + 1] = key
      end
    end
    for _, key in ipairs(defaultKeys) do
      if not held[key] then
        held[key] = true
        if type(maximum) == "number" and count >= maximum then
          dropped = true
        else
          importEntry(key, nil)
        end
      end
    end
    if dropped then
      noteEntry(ctx.report, path, nil, "dropped", "mapFull")
    end
    if count == 0 then
      return nil
    end
    return result
  end

  ---Report, once per field, every AceDB default of `scope` that differs from
  ---the SettingsKit default: an entry the source lacks entirely (a character
  ---that never saved anything) reads the SettingsKit default from now on.
  ---A scope AceDB has no defaults for is still compared: every field
  ---SettingsKit defaults then reads differently.
  ---@param ctx table
  ---@param scope string
  ---@param describe table
  ---@param aceDefaults any
  ---@param keys any[] the path inside the scope
  ---@param recordDefault any the record's own default, when it has one
  local function noteDefaultsThatDiffer(ctx, scope, describe, aceDefaults, keys, recordDefault)
    if #keys >= ctx.maxDepth then
      return
    end
    local fields = describe.fields or {}
    for _, name in ipairs(describe.fieldNames or {}) do
      local field = fields[name]
      local aceDefault = aceDefaultFor(aceDefaults, name)
      local settingsDefault = field.default
      if type(recordDefault) == "table" and type(rawget(recordDefault, name)) ~= "nil" then
        settingsDefault = rawget(recordDefault, name)
      end
      if field.kind == "table" then
        local nested = settingsDefault
        if type(nested) ~= "table" then
          nested = field.default
        end
        noteDefaultsThatDiffer(ctx, scope, field, aceDefault, extendKeys(keys, name), nested)
      elseif field.kind ~= "map" then
        local aceReads = aceDefault
        if type(aceDefault) == "table" then
          aceReads = applySpec({}, aceDefault, 0)
        end
        if not deepEqual(aceReads, settingsDefault) then
          noteDefaultOnce(ctx, scope, extendKeys(keys, name))
        end
      end
    end
  end

  ---A profile's name in the layout, or `nil` to drop it: `renameProfile` first,
  ---then SettingsKit's rules (design section 7.3).
  ---@param ctx table
  ---@param name any
  ---@return string|nil
  local function profileNameFor(ctx, name)
    local path = joinPath("profiles", name)
    local newName = name
    if ctx.plan.renameProfile ~= nil then
      newName = ctx.plan.renameProfile(name)
      if ctx.probe ~= nil and type(newName) ~= "nil" and ctx.probe(newName) == true then
        newName = nil
      end
      if type(newName) ~= "string" then
        noteEntry(ctx.report, path, nil, "dropped", "renamedProfile")
        return nil
      end
      if newName ~= name then
        noteEntry(ctx.report, path, nil, "renamed", "renamedProfile")
      end
    end
    if type(newName) ~= "string" then
      noteEntry(ctx.report, path, nil, "dropped", "profileNameBlank")
      return nil
    end
    if #newName > ctx.maxProfileNameLength then
      noteEntry(ctx.report, path, nil, "dropped", "profileNameTooLong")
      return nil
    end
    if stringFind(newName, "%S") == nil then
      noteEntry(ctx.report, path, nil, "dropped", "profileNameBlank")
      return nil
    end
    return newName
  end

  ---A character's key in the layout, or `nil` to drop it.
  ---@param ctx table
  ---@param key any
  ---@return any
  local function characterKeyFor(ctx, key)
    local rename = ctx.plan.renameCharacter
    if rename == nil then
      return key
    end
    local newKey = rename(key)
    local path = joinPath("char", key)
    if type(newKey) ~= "string" or (ctx.probe ~= nil and ctx.probe(newKey) == true) then
      noteEntry(ctx.report, path, nil, "dropped", "renamedCharacter")
      return nil
    end
    if newKey ~= key then
      noteEntry(ctx.report, path, nil, "renamed", "renamedCharacter")
    end
    return newKey
  end

  ---A section of the source, or `nil`; a section that is not a table is
  ---reported and treated as absent.
  ---@param ctx table
  ---@param source table
  ---@param name string
  ---@return table|nil
  local function sourceSection(ctx, source, name)
    local section = rawget(source, name)
    if type(section) == "nil" then
      return nil
    end
    if type(section) ~= "table" or (ctx.probe ~= nil and ctx.probe(section) == true) then
      noteEntry(ctx.report, name, nil, "dropped", "notStorable")
      return nil
    end
    return section
  end

  ---Whether a section holds anything.
  ---@param section table|nil
  ---@return boolean
  local function holdsEntries(section)
    return type(section) == "table" and type(next(section)) ~= "nil"
  end

  ---Call a client function by name, or `nil` when the client lacks it or
  ---answers with a secret.
  ---@param ctx table
  ---@param name string
  ---@return ...
  local function askClient(ctx, name, ...)
    -- These are World of Warcraft client APIs reachable only through the global table.
    -- selene: allow(global_usage)
    local fn = rawget(_G, name)
    if type(fn) ~= "function" then
      return nil
    end
    local first, second, third, fourth = fn(...)
    local probe = ctx.probe
    if
      probe ~= nil and (probe(first) == true or probe(second) == true or probe(fourth) == true)
    then
      return nil
    end
    return first, second, third, fourth
  end

  ---Report what the current character's keys say about the import: its
  ---SettingsKit key missing from `char`, and keys that will not line up
  ---(design section 7.3).
  ---@param ctx table
  ---@param source table
  ---@param layout table
  local function noteCharacterKeys(ctx, source, layout)
    local chars, realms = rawget(source, "char"), rawget(source, "realm")
    local _, _, _, interface = askClient(ctx, "GetBuildInfo")
    local ruleset = type(interface) == "number"
      and interface >= RULESET_INTERFACE_FIRST
      and interface <= RULESET_INTERFACE_LAST
    if ruleset then
      if holdsEntries(chars) then
        noteEntry(ctx.report, "char", nil, "changed", "characterKeyMismatch")
      end
      if holdsEntries(realms) then
        noteEntry(ctx.report, "realm", nil, "changed", "realmKeyMismatch")
      end
    end
    if not ctx.declared.char or not holdsEntries(chars) then
      return
    end
    local name = askClient(ctx, "UnitName", "player")
    local realm = askClient(ctx, "GetRealmName")
    if type(name) ~= "string" or type(realm) ~= "string" then
      return
    end
    local settingsKey = name .. " - " .. realm
    local unmodified = askClient(ctx, "UnitNameUnmodified", "player")
    if type(unmodified) == "string" and unmodified ~= name then
      noteEntry(
        ctx.report,
        joinPath("char", unmodified .. " - " .. realm),
        nil,
        "changed",
        "characterKeyMismatch"
      )
    end
    if type(layout.char) ~= "table" or type(rawget(layout.char, settingsKey)) == "nil" then
      noteEntry(
        ctx.report,
        joinPath("char", settingsKey),
        nil,
        "changed",
        "currentCharacterMissing"
      )
    end
  end

  ---Pair each source key of a section with its layout key. A key `rename`
  ---maps to `nil` is skipped (`rename` reports why). Source keys that land on
  ---one layout key collide: the key that keeps its own name wins, otherwise
  ---the first in sorted order, and every other is reported `keyCollision`, so
  ---which entry survives never depends on the order AceDB saved them in.
  ---@param ctx table
  ---@param keys any[] the section's keys, sorted
  ---@param section string the section's report path
  ---@param rename fun(key: any): any
  ---@return any[][] pairs `{ sourceKey, layoutKey }`, in the order of `keys`
  local function resolveKeys(ctx, keys, section, rename)
    local layoutKeys, claimedBy = {}, {}
    for _, key in ipairs(keys) do
      local layoutKey = rename(key)
      layoutKeys[key] = layoutKey
      if layoutKey ~= nil then
        local holder = claimedBy[layoutKey]
        if holder == nil or (key == layoutKey and holder ~= layoutKey) then
          claimedBy[layoutKey] = key
        end
      end
    end
    local resolved = {}
    for _, key in ipairs(keys) do
      local layoutKey = layoutKeys[key]
      if layoutKey ~= nil then
        if claimedBy[layoutKey] == key then
          resolved[#resolved + 1] = { key, layoutKey }
        else
          noteEntry(ctx.report, joinPath(section, key), nil, "dropped", "keyCollision")
        end
      end
    end
    return resolved
  end

  ---Import the profiles and the profile choices.
  ---@param ctx table
  ---@param source table
  ---@param layout table
  ---@return table<any, string> profileNames source name to layout name
  local function importProfiles(ctx, source, layout)
    local profiles = sourceSection(ctx, source, "profiles")
    local names = {}
    if not ctx.declared.profile then
      if holdsEntries(profiles) then
        noteEntry(ctx.report, "profiles", nil, "dropped", "undeclaredScope")
      end
      return names
    end
    layout.profiles = {}
    local describe = ctx.scopes.profile.describe
    if profiles ~= nil then
      local resolved = resolveKeys(
        ctx,
        sortedKeys(profiles, ctx, "profiles"),
        "profiles",
        function(name)
          if type(rawget(profiles, name)) ~= "table" then
            noteEntry(ctx.report, joinPath("profiles", name), nil, "dropped", "notStorable")
            return nil
          end
          return profileNameFor(ctx, name)
        end
      )
      for _, pair in ipairs(resolved) do
        local name, newName = pair[1], pair[2]
        names[name] = newName
        -- A scope's schema describes one entry, so the path inside it starts
        -- below the entry's own key.
        layout.profiles[newName] = importRecord(
          ctx,
          "profile",
          describe,
          {},
          joinPath("profiles", newName),
          rawget(profiles, name),
          ctx.aceDefaults and rawget(ctx.aceDefaults, "profile"),
          nil
        ) or {}
      end
    end
    local profileKeys = sourceSection(ctx, source, "profileKeys")
    if profileKeys ~= nil then
      layout.profileKeys = {}
      local resolved = resolveKeys(
        ctx,
        sortedKeys(profileKeys, ctx, "profileKeys"),
        "profileKeys",
        function(key)
          return characterKeyFor(ctx, key)
        end
      )
      for _, pair in ipairs(resolved) do
        local key, newKey = pair[1], pair[2]
        local chosen = rawget(profileKeys, key)
        -- The choice is probed before it is used as a key, so a secret never
        -- reaches a table lookup.
        if ctx.probe ~= nil and ctx.probe(chosen) == true then
          noteEntry(ctx.report, joinPath("profileKeys", key), nil, "dropped", "secretValue")
        elseif names[chosen] ~= nil then
          layout.profileKeys[newKey] = names[chosen]
        else
          noteEntry(ctx.report, joinPath("profileKeys", key), nil, "dropped", "danglingProfileKey")
        end
      end
    end
    return names
  end

  ---Import `char`, `realm`, `class` and `faction`.
  ---@param ctx table
  ---@param source table
  ---@param layout table
  local function importKeyedScopes(ctx, source, layout)
    for _, scope in ipairs(KEYED_SCOPES) do
      local section = sourceSection(ctx, source, scope)
      if not ctx.declared[scope] then
        if holdsEntries(section) then
          noteEntry(ctx.report, scope, nil, "dropped", "undeclaredScope")
        end
      else
        layout[scope] = {}
        if section ~= nil then
          local resolved = resolveKeys(ctx, sortedKeys(section, ctx, scope), scope, function(key)
            if type(rawget(section, key)) ~= "table" then
              noteEntry(ctx.report, joinPath(scope, key), nil, "dropped", "notStorable")
              return nil
            end
            if scope == "char" then
              return characterKeyFor(ctx, key)
            end
            return key
          end)
          for _, pair in ipairs(resolved) do
            local key, newKey = pair[1], pair[2]
            layout[scope][newKey] = importRecord(
              ctx,
              scope,
              ctx.scopes[scope].describe,
              {},
              joinPath(scope, newKey),
              rawget(section, key),
              ctx.aceDefaults and rawget(ctx.aceDefaults, scope),
              nil
            )
          end
        end
      end
    end
  end

  ---Write `value` into the layout section of `scope` for `entryKey` (`nil` for
  ---the global section), under `field`, merging with what is already there.
  ---An entry already present wins and the newcomer is reported `keyCollision`;
  ---a map field stops at its `max`, reported `mapFull`, so the merge never
  ---builds a table the schema would refuse.
  ---@param ctx table
  ---@param layout table
  ---@param scope string
  ---@param entryKey any
  ---@param field string
  ---@param value table
  ---@param path string the field's report path
  local function placeUnder(ctx, layout, scope, entryKey, field, value, path)
    local section = SECTION_FOR_SCOPE[scope]
    layout[section] = layout[section] or {}
    local target = layout[section]
    if entryKey ~= nil then
      target[entryKey] = target[entryKey] or {}
      target = target[entryKey]
    end
    local existing = target[field]
    if type(existing) ~= "table" then
      target[field] = value
      return
    end
    local describe = ctx.scopes[scope].describe.fields[field]
    local maximum = describe and describe.kind == "map" and describe.max or nil
    local count = 0
    for _ in next, existing do
      count = count + 1
    end
    local full = false
    for _, key in ipairs(sortedKeys(value)) do
      if type(rawget(existing, key)) ~= "nil" then
        noteEntry(ctx.report, joinPath(path, key), nil, "dropped", "keyCollision")
      elseif type(maximum) == "number" and count >= maximum then
        full = true
      else
        existing[key] = rawget(value, key)
        count = count + 1
      end
    end
    if full then
      noteEntry(ctx.report, path, nil, "dropped", "mapFull")
    end
  end

  ---Import the AceDB scopes SettingsKit lacks into the map fields `plan.scopes`
  ---names, or report them dropped.
  ---@param ctx table
  ---@param source table
  ---@param layout table
  local function importUnsupportedScopes(ctx, source, layout)
    for _, scope in ipairs(UNSUPPORTED_SCOPES) do
      local section = sourceSection(ctx, source, scope)
      local destination = ctx.plan.scopes and ctx.plan.scopes[scope]
      if holdsEntries(section) and destination == nil then
        noteEntry(ctx.report, scope, nil, "dropped", "unsupportedScope")
      elseif destination ~= nil then
        local into, field = destination.into, destination.field
        local describe = ctx.scopes[into].describe.fields[field]
        local entries = importMap(
          ctx,
          into,
          describe,
          { field },
          joinPath(into, field),
          section,
          ctx.aceDefaults and rawget(ctx.aceDefaults, scope)
        )
        if entries ~= nil then
          placeUnder(ctx, layout, into, nil, field, entries, joinPath(into, field))
        end
      end
    end
  end

  ---Import each namespace's sections under the field `plan.namespaces` names in
  ---the same SettingsKit sections, or report the namespace dropped.
  ---@param ctx table
  ---@param source table
  ---@param layout table
  ---@param profileNames table<any, string>
  local function importNamespaces(ctx, source, layout, profileNames)
    local namespaces = sourceSection(ctx, source, "namespaces")
    if namespaces == nil then
      return
    end
    for _, name in ipairs(sortedKeys(namespaces, ctx, "namespaces")) do
      local mapping = ctx.plan.namespaces and type(name) == "string" and ctx.plan.namespaces[name]
      local namespaceData = rawget(namespaces, name)
      if not mapping then
        noteEntry(ctx.report, joinPath("namespaces", name), nil, "dropped", "unmappedNamespace")
      elseif type(namespaceData) == "table" then
        for _, pair in ipairs(NAMESPACE_SECTIONS) do
          local section, scope = pair[1], pair[2]
          local data = rawget(namespaceData, section)
          local describe = ctx.declared[scope] and ctx.scopes[scope].describe.fields[mapping.field]
          local defaults = type(mapping.defaults) == "table" and rawget(mapping.defaults, scope)
            or nil
          if holdsEntries(data) and not describe then
            noteEntry(
              ctx.report,
              joinPath(joinPath("namespaces", name), section),
              nil,
              "dropped",
              "undeclaredScope"
            )
          elseif type(data) == "table" and describe then
            local function importOne(entry, layoutKey, keys, path)
              local ok, value =
                importField(ctx, scope, describe, keys, path, entry, defaults, describe.default)
              if ok then
                placeUnder(ctx, layout, scope, layoutKey, mapping.field, value, path)
              end
            end
            if scope == "global" then
              importOne(data, nil, { mapping.field }, joinPath("global", mapping.field))
            else
              local sectionPath = joinPath(joinPath("namespaces", name), section)
              local resolved = resolveKeys(
                ctx,
                sortedKeys(data, ctx, sectionPath),
                sectionPath,
                function(key)
                  if scope == "profile" then
                    return profileNames[key]
                  elseif scope == "char" then
                    return characterKeyFor(ctx, key)
                  end
                  return key
                end
              )
              for _, resolvedPair in ipairs(resolved) do
                local key, layoutKey = resolvedPair[1], resolvedPair[2]
                importOne(
                  rawget(data, key),
                  layoutKey,
                  { mapping.field },
                  joinPath(joinPath(SECTION_FOR_SCOPE[scope], layoutKey), mapping.field)
                )
              end
            end
          end
        end
      end
    end
  end

  ---Build the SettingsKit layout and the report from an AceDB table. Raises
  ---`IMPORT_OVERFLOW` past `maxImportEntries`; an error the addon's rename
  ---functions raise propagates.
  ---@param ctx table
  ---@param source table
  ---@return table layout
  local function buildLayout(ctx, source)
    local layout = {}
    if ctx.aceDefaults == nil then
      noteEntry(ctx.report, "", nil, "changed", "aceDefaultsUnknown")
    end
    for _, key in ipairs(sortedKeys(source, ctx, "")) do
      -- Inside a migration the table carries SettingsKit's own `version`.
      local settingsVersion = ctx.mode == "migration" and key == "version"
      if not settingsVersion and (type(key) ~= "string" or not ACE_TOP_LEVEL[key]) then
        noteEntry(ctx.report, renderKey(key), nil, "dropped", "unknownTopLevelKey")
      end
    end
    if ctx.declared.global then
      layout.global = importRecord(
        ctx,
        "global",
        ctx.scopes.global.describe,
        {},
        "global",
        sourceSection(ctx, source, "global"),
        ctx.aceDefaults and rawget(ctx.aceDefaults, "global"),
        nil
      ) or {}
    elseif holdsEntries(rawget(source, "global")) then
      noteEntry(ctx.report, "global", nil, "dropped", "undeclaredScope")
    end
    local profileNames = importProfiles(ctx, source, layout)
    importKeyedScopes(ctx, source, layout)
    importUnsupportedScopes(ctx, source, layout)
    importNamespaces(ctx, source, layout, profileNames)
    noteCharacterKeys(ctx, source, layout)
    if ctx.aceDefaults ~= nil then
      for _, scope in ipairs({ "profile", "char", "realm", "class", "faction" }) do
        if ctx.declared[scope] then
          noteDefaultsThatDiffer(
            ctx,
            scope,
            ctx.scopes[scope].describe,
            rawget(ctx.aceDefaults, scope),
            {},
            nil
          )
        end
      end
    end
    layout.namespaces = {}
    return layout
  end

  -- `readPlanSchema` runs one frame below `readPlan`, so its refusals name the
  -- public method's caller from one level further up.
  local SCHEMA_LEVEL = 5

  ---Seal and describe every scope of `plan.schema`, raising at the caller for a
  ---scope SettingsKit would refuse.
  ---@param label string
  ---@param SchemaKit table
  ---@param schema any
  ---@return table scopes scope name to `{ schema, describe }`
  ---@return table<string, boolean> declared
  local function readPlanSchema(label, SchemaKit, schema)
    if type(schema) ~= "table" then
      refuseOption(
        label,
        "plan.schema is required: the schema table passed to SettingsKit:Open",
        SCHEMA_LEVEL
      )
    end
    local scopes, declared = {}, {}
    for scope, node in next, schema do
      if type(scope) ~= "string" or SECTION_FOR_SCOPE[scope] == nil then
        refuseOption(
          label,
          "plan.schema has a scope SettingsKit does not know: " .. renderKey(scope),
          SCHEMA_LEVEL
        )
      end
      local ok, sealed = pcall(SchemaKit.Seal, SchemaKit, node)
      if not ok then
        refuseOption(
          label,
          "plan.schema." .. scope .. " must be a SchemaKit table node or sealed schema",
          SCHEMA_LEVEL
        )
      end
      local describe = sealed:Describe()
      if describe.kind ~= "table" then
        refuseOption(label, "plan.schema." .. scope .. " must be a SchemaKit.table", SCHEMA_LEVEL)
      end
      scopes[scope] = { schema = sealed, describe = describe }
      declared[scope] = true
    end
    return scopes, declared
  end

  ---Validate an importer plan and build the walk's context. Raises at the
  ---caller's caller for a programming error.
  ---@param label string
  ---@param plan any
  ---@param mode "preview"|"import"|"migration"
  ---@return table ctx
  local function readPlan(label, plan, mode)
    if type(plan) ~= "table" then
      refuseOption(label, "plan must be a table")
    end
    local probe = readSecretProbe()
    local allowed = PLAN_FIELDS[mode]
    for key, value in next, plan do
      if probe ~= nil and (probe(key) == true or probe(value) == true) then
        refuseOption(label, "plan must not hold a secret key or value")
      end
      if type(key) ~= "string" or not allowed[key] then
        refuseOption(label, "plan has no field named " .. renderKey(key))
      end
    end
    local SchemaKit = Registry:Find("schemaKit", 1)
    if type(SchemaKit) ~= "table" then
      refuseOption(label, "requires SchemaKit API 1, which is not loaded")
    end
    local scopes, declared = readPlanSchema(label, SchemaKit, plan.schema)
    for _, field in ipairs({ "aceDefaults", "scopes", "namespaces" }) do
      if type(plan[field]) ~= "nil" and type(plan[field]) ~= "table" then
        refuseOption(label, "plan." .. field .. " must be a table")
      end
    end
    for _, field in ipairs({ "renameProfile", "renameCharacter", "onReport" }) do
      if type(plan[field]) ~= "nil" and type(plan[field]) ~= "function" then
        refuseOption(label, "plan." .. field .. " must be a function")
      end
    end
    for scope, destination in next, plan.scopes or {} do
      local known = false
      for _, name in ipairs(UNSUPPORTED_SCOPES) do
        known = known or scope == name
      end
      if not known then
        refuseOption(
          label,
          "plan.scopes names a scope SettingsKit has itself or AceDB lacks: " .. renderKey(scope)
        )
      end
      if
        type(destination) ~= "table"
        or destination.into ~= "global"
        or type(destination.field) ~= "string"
      then
        refuseOption(
          label,
          "plan.scopes." .. scope .. ' must be { into = "global", field = "<map field>" }'
        )
      end
      local fields = declared.global and scopes.global.describe.fields or {}
      local target = fields[destination.field]
      if type(target) ~= "table" or target.kind ~= "map" then
        refuseOption(
          label,
          "plan.scopes."
            .. scope
            .. '.field "'
            .. destination.field
            .. '" is not a declared map field of scope "global"'
        )
      end
    end
    for name, mapping in next, plan.namespaces or {} do
      if type(name) ~= "string" or type(mapping) ~= "table" or type(mapping.field) ~= "string" then
        refuseOption(
          label,
          'plan.namespaces entries must be { field = "<field>", defaults = <table>? }'
        )
      end
      if type(mapping.defaults) ~= "nil" and type(mapping.defaults) ~= "table" then
        refuseOption(label, "plan.namespaces." .. name .. ".defaults must be a table")
      end
      local found = false
      for scope in next, declared do
        local target = scopes[scope].describe.fields[mapping.field]
        if type(target) == "table" and (target.kind == "table" or target.kind == "map") then
          found = true
        end
      end
      if not found then
        refuseOption(
          label,
          "plan.namespaces."
            .. name
            .. '.field "'
            .. mapping.field
            .. '" is not a declared record or map field of any scope'
        )
      end
    end
    if
      mode == "import"
      and type(plan.version) ~= "nil"
      and not isIntegerUpTo(plan.version, 2 ^ 53)
    then
      refuseOption(label, "plan.version must be a positive integer")
    end
    if mode == "migration" and type(plan.backup) ~= "string" then
      refuseOption(
        label,
        "plan.backup is required: the name of a global listed in ## SavedVariables"
      )
    end
    if type(plan.backup) ~= "nil" and (type(plan.backup) ~= "string" or plan.backup == "") then
      refuseOption(label, "plan.backup must be the name of a global")
    end
    if type(plan.replaceBackup) ~= "nil" and type(plan.replaceBackup) ~= "boolean" then
      refuseOption(label, "plan.replaceBackup must be a boolean")
    end
    local SettingsKit = Registry:Find("settingsKit", 1)
    local maxProfileNameLength = DEFAULT_PROFILE_NAME_LENGTH
    if type(SettingsKit) == "table" and type(SettingsKit.GetLimits) == "function" then
      maxProfileNameLength = SettingsKit:GetLimits().maxProfileNameLength or maxProfileNameLength
    end
    local actions = {}
    return {
      mode = mode,
      plan = plan,
      probe = probe,
      scopes = scopes,
      declared = declared,
      aceDefaults = plan.aceDefaults,
      actions = actions,
      entries = 0,
      notedDefaults = {},
      maxEntries = limits.maxImportEntries,
      maxDepth = SchemaKit:GetLimits().maxDepth,
      maxProfileNameLength = maxProfileNameLength,
    }
  end

  ---A new import report: every import action counted, `0` included.
  ---@return BridgeKit.Report
  local function newImportReport()
    local counts = {}
    for _, action in ipairs(IMPORT_ACTIONS) do
      counts[action] = 0
    end
    return { kind = "aceDB", entries = {}, counts = counts, truncated = 0 }
  end

  ---Run the walk over `source`, turning an overflow into a result. The walk's
  ---running state is reset first, so one context serves any number of walks.
  ---@param ctx table
  ---@param source table
  ---@return table|nil layout `nil` past `maxImportEntries`
  local function walkSource(ctx, source)
    ctx.report = newImportReport()
    ctx.entries = 0
    ctx.notedDefaults = {}
    local ok, result = pcall(buildLayout, ctx, source)
    if ok then
      return result
    end
    if result == IMPORT_OVERFLOW then
      return nil
    end
    error(result, 0)
  end

  ---The AceDB table a `source` argument names: a table, or the name of a
  ---global holding one.
  ---@param label string
  ---@param source any
  ---@return table
  ---@return string sourceName the global's name, or `"table"`
  local function readSource(label, source)
    local probe = readSecretProbe()
    if probe ~= nil and probe(source) == true then
      refuseOption(label, "source must not be a secret value")
    end
    if type(source) == "string" then
      -- The saved variable lives in the global table under its TOC name. The
      -- refusal is raised here, not through `refuseOption`, so the type test
      -- visibly guards the value (docs/TOOLING.md, "How a guard is
      -- recognised"); level 3 is the public method's caller.
      -- selene: allow(global_usage)
      local value = rawget(_G, source)
      if type(value) ~= "table" then
        error(
          label .. ' source names the global "' .. source .. '", which does not hold a table',
          3
        )
      end
      return value, source
    end
    if type(source) ~= "table" then
      refuseOption(label, "source must be a table or the name of a global holding one")
    end
    return source, "table"
  end

  ---Whether a global is free for an import to write: `nil` or an empty table.
  ---@param name string
  ---@return boolean
  local function globalIsFree(name)
    -- selene: allow(global_usage)
    local value = rawget(_G, name)
    return type(value) == "nil" or (type(value) == "table" and type(next(value)) == "nil")
  end

  ---The backup of `source` (design section 7.8): bounded by `maxImportEntries`,
  ---tables reached twice kept shared.
  ---@param data table the source table or the contents moved out of it
  ---@param sourceName string
  ---@return table
  local function backupOf(data, sourceName)
    return {
      bridgeKit = IMPLEMENTATION_REVISION,
      source = sourceName,
      commit = ACE_BASELINE.commit,
      data = data,
    }
  end

  ---The report an import of `source` would produce, with the same entries and
  ---counts; writes nothing anywhere (design section 5.5).
  ---@param self BridgeKit
  ---@param source table|string
  ---@param plan BridgeKit.ImportPlan
  ---@return BridgeKit.Report report
  ---@return string|nil reason `"maxImportEntries"` when the source is too large to import
  function previewAceDB(self, source, plan)
    local label = "BridgeKit:PreviewAceDB"
    validateFacade(self, label, 3)
    local sourceTable = readSource(label, source)
    local ctx = readPlan(label, plan, "preview")
    local layout = walkSource(ctx, sourceTable)
    if layout == nil then
      return ctx.report, "maxImportEntries"
    end
    return ctx.report, nil
  end

  ---Build the SettingsKit layout from an AceDB saved variable in an empty
  ---target global, before `SettingsKit:Open` (design sections 5.5 and 7.7). The
  ---source is never written. Returns the report, or `nil` and a refusal (and
  ---the report so far for `"maxImportEntries"`).
  ---@param self BridgeKit
  ---@param source table|string
  ---@param targetName string
  ---@param plan BridgeKit.ImportPlan
  ---@return BridgeKit.Report|nil report
  ---@return string|nil reason `"targetNotEmpty"`, `"backupTaken"` or `"maxImportEntries"`
  ---@return BridgeKit.Report|nil partial the report so far, with `"maxImportEntries"`
  function importAceDB(self, source, targetName, plan)
    local label = "BridgeKit:ImportAceDB"
    validateFacade(self, label, 3)
    local sourceTable, sourceName = readSource(label, source)
    if type(targetName) ~= "string" or isSecretValue(targetName) or targetName == "" then
      refuseOption(label, "targetName must be the name of a global")
    end
    local ctx = readPlan(label, plan, "import")
    if not globalIsFree(targetName) then
      return nil, "targetNotEmpty"
    end
    if plan.backup ~= nil and not plan.replaceBackup and not globalIsFree(plan.backup) then
      return nil, "backupTaken"
    end
    local layout = walkSource(ctx, sourceTable)
    if layout == nil then
      return nil, "maxImportEntries", ctx.report
    end
    if plan.version ~= nil then
      layout.version = plan.version
    end
    if plan.backup ~= nil then
      -- The copy is bounded like the walk: a source too large to copy is
      -- refused before anything is written.
      ctx.entries = 0
      local copied, data = pcall(copyCounted, ctx, sourceTable, {})
      if not copied then
        if data == IMPORT_OVERFLOW then
          return nil, "maxImportEntries", ctx.report
        end
        error(data, 0)
      end
      -- selene: allow(global_usage)
      rawset(_G, plan.backup, backupOf(data, sourceName))
    end
    -- An empty table the client loaded for the target is filled in place, so
    -- the global keeps the identity the client saves.
    -- selene: allow(global_usage)
    local target = rawget(_G, targetName)
    if type(target) ~= "table" then
      target = {}
      -- selene: allow(global_usage)
      rawset(_G, targetName, target)
    end
    for key, value in next, layout do
      target[key] = value
    end
    return ctx.report
  end

  ---A SettingsKit migration step that turns an AceDB table into the SettingsKit
  ---layout in place of the same saved variable (design sections 5.5 and 7.7):
  ---`migrations = { [n] = BridgeKit:AceDBMigration(plan) }`. The step moves the
  ---old contents into the backup global, after the new layout was built and
  ---`onReport` ran, so a step that raises leaves no backup behind.
  ---@param self BridgeKit
  ---@param plan BridgeKit.ImportPlan
  ---@return fun(raw: table)
  function aceDBMigration(self, plan)
    local label = "BridgeKit:AceDBMigration"
    validateFacade(self, label, 3)
    local ctx = readPlan(label, plan, "migration")
    local backupName = plan.backup
    ---@cast backupName string
    return function(raw)
      if not plan.replaceBackup and not globalIsFree(backupName) then
        error(label .. ' backup global "' .. backupName .. '" already holds data', 2)
      end
      local layout = walkSource(ctx, raw)
      if layout == nil then
        error(label .. " the saved table has more than maxImportEntries entries", 2)
      end
      if plan.onReport ~= nil then
        plan.onReport(ctx.report)
      end
      -- The table the step receives is SettingsKit's own copy, private to the
      -- step, so its contents move into the backup instead of being copied
      -- again.
      -- SettingsKit's own `version` is no AceDB data and stays SettingsKit's.
      local moved = {}
      for key, value in next, raw do
        if key ~= "version" then
          moved[key] = value
        end
      end
      -- selene: allow(global_usage)
      rawset(_G, backupName, backupOf(moved, "table"))
      for key in next, moved do
        raw[key] = nil
      end
      for key, value in next, layout do
        raw[key] = value
      end
    end
  end
end

do
  -- AceComm channel ------------------------------------------------------------
  --
  -- A channel speaks AceComm-3.0's framing on one prefix through a CommKit scope
  -- (design section 8.3): it sends a text as the addon messages AceComm would
  -- send, through CommKit's raw sends (so the traffic shares CommKit's queue and
  -- budget), and reassembles what peers send with AceComm's rules and bounds
  -- Ace lacks. Streams belong to the prefix, not to a channel: every channel on
  -- a prefix receives each completed message, in the order the channels were
  -- opened, and only the first live channel reads the raw messages, so the
  -- reassembly runs once however many channels share it.
  --
  -- Expiry is checked on every message a channel receives: a stream whose last
  -- part is older than `aceStreamTimeout` is dropped then. A quiet prefix keeps
  -- its stale streams until its next message, bounded by `maxAceSpoolBytes`.

  -- AceComm's control bytes (design section 8.3).
  local ACE_CONTROL =
    { first = 1, middle = 2, last = 3, escape = 4, reservedLow = 5, reservedHigh = 9 }

  -- The text bytes one multipart message carries after its control byte, and
  -- the most a single message holds.
  local ACE_PART_BYTES = 254
  local ACE_MESSAGE_BYTES = 255

  -- The most parts CommKit's `SendRaw` takes in one message.
  local MAX_RAW_PARTS = 4096

  -- AceComm's priority names, which are CommKit's too.
  local ACE_PRIORITIES = { ALERT = true, NORMAL = true, BULK = true }

  -- The fields `channel:Send` accepts.
  local CHANNEL_SEND_KEYS =
    { text = true, distribution = true, target = true, onProgress = true, onComplete = true }

  -- The options `OpenAceComm` accepts.
  local CHANNEL_OPTION_KEYS = { priority = true, wire = true, ambiguate = true }

  -- How long a sender's dropped streams wait before they are reported again.
  local DROP_REPORT_SECONDS = 60

  -- The statistics counters, in the order `GetStatistics` lists them.
  local ACE_STATISTICS = {
    "aceMessagesSent",
    "acePartsSent",
    "aceMessagesReceived",
    "aceBytesReceived",
    "aceStreamsOpened",
    "aceStreamsCompleted",
    "aceStreamsReplaced",
    "aceStreamsExpired",
    "aceStreamsOversize",
    "aceStreamsRefusedQuota",
    "aceOrphanParts",
    "aceReservedControl",
  }

  local aceComm = rawget(state, "aceComm")
  if type(aceComm) ~= "table" then
    aceComm = {
      prefixes = {},
      streams = {},
      streamCount = 0,
      senderStreams = {},
      spoolBytes = 0,
      statistics = {},
      dropReports = { bySender = {}, count = 0 },
      channelPrototype = {},
    }
    aceComm.channelMetatable = { __index = aceComm.channelPrototype }
    rawset(state, "aceComm", aceComm)
  end
  for _, name in ipairs(ACE_STATISTICS) do
    if type(aceComm.statistics[name]) == "nil" then
      aceComm.statistics[name] = 0
    end
  end
  local CHANNEL_METATABLE = aceComm.channelMetatable
  rawset(CHANNEL_METATABLE, "__index", aceComm.channelPrototype)

  ---A client function by name, or `nil`; read at every call because a client
  ---can gain it after BridgeKit loads.
  ---@param name string
  ---@return function|nil
  local function clientFunction(name)
    -- These are World of Warcraft client APIs reachable only through the global table.
    -- selene: allow(global_usage)
    local fn = rawget(_G, name)
    if type(fn) == "function" then
      return fn
    end
    return nil
  end

  ---Seconds on the client's clock, or 0 without one.
  ---@return number
  local function now()
    local clock = clientFunction("GetTimePreciseSec") or clientFunction("GetTime")
    if clock == nil then
      return 0
    end
    return clock()
  end

  ---Call an addon callback isolated, as CommKit calls its own: an error goes to
  ---the client's error handler and the next callback still runs.
  ---@param callback function
  local function callIsolated(callback, ...)
    local secureCall = clientFunction("securecallfunction")
    if secureCall ~= nil then
      secureCall(callback, ...)
      return
    end
    local ok, failure = pcall(callback, ...)
    if not ok then
      local handler = clientFunction("geterrorhandler")
      local report = handler and handler() or nil
      if type(report) == "function" then
        report(failure)
      end
    end
  end

  ---Count one statistic.
  ---@param name string
  ---@param amount integer?
  local function countAce(name, amount)
    aceComm.statistics[name] = aceComm.statistics[name] + (amount or 1)
  end

  ---Report a dropped stream through the client's error handler, at most once
  ---per sender per minute; past `maxDropReportSenders` senders share one entry.
  ---@param prefix string
  ---@param sender string
  ---@param reason string
  local function noteAceDrop(prefix, sender, reason)
    local reports = aceComm.dropReports
    local current = now()
    local key = sender
    if reports.bySender[key] == nil and reports.count >= limits.maxDropReportSenders then
      for known, at in next, reports.bySender do
        if current - at >= DROP_REPORT_SECONDS then
          reports.bySender[known] = nil
          reports.count = reports.count - 1
        end
      end
      if reports.count >= limits.maxDropReportSenders then
        key = "*"
      end
    end
    local last = reports.bySender[key]
    if last ~= nil and current - last < DROP_REPORT_SECONDS then
      return
    end
    if last == nil then
      reports.count = reports.count + 1
    end
    reports.bySender[key] = current
    local handler = clientFunction("geterrorhandler")
    local report = handler and handler() or nil
    if type(report) == "function" then
      local who = key == "*" and "several senders" or sender
      report(
        "BridgeKit: dropped an AceComm stream from "
          .. who
          .. ' on prefix "'
          .. prefix
          .. '" ('
          .. reason
          .. ")"
      )
    end
  end

  ---Forget a stream and give back what it held.
  ---@param key string
  local function closeAceStream(key)
    local stream = aceComm.streams[key]
    if stream == nil then
      return
    end
    aceComm.streams[key] = nil
    aceComm.streamCount = aceComm.streamCount - 1
    aceComm.spoolBytes = aceComm.spoolBytes - stream.bytes
    local held = aceComm.senderStreams[stream.sender] - 1
    aceComm.senderStreams[stream.sender] = held > 0 and held or nil
  end

  ---Drop every stream whose last part is older than `aceStreamTimeout`.
  ---@param current number
  local function expireAceStreams(current)
    for key, stream in next, aceComm.streams do
      if current >= stream.deadline then
        closeAceStream(key)
        countAce("aceStreamsExpired")
        noteAceDrop(stream.prefix, stream.sender, "expired")
      end
    end
  end

  ---Hand one whole message to every live channel on its prefix, in the order
  ---they were opened.
  ---@param prefix string
  ---@param message string
  ---@param distribution string
  ---@param sender string
  local function deliverAce(prefix, message, distribution, sender)
    local record = aceComm.prefixes[prefix]
    if record == nil then
      return
    end
    countAce("aceMessagesReceived")
    countAce("aceBytesReceived", #message)
    local ambiguate = clientFunction("Ambiguate")
    local shortSender = ambiguate and ambiguate(sender, "none") or sender
    local channels = record.channels
    for index = 1, #channels do
      local channel = channels[index]
      if not channel:IsClosed() then
        local shown = rawget(channel, "_ambiguate") and shortSender or sender
        callIsolated(rawget(channel, "_callback"), prefix, message, distribution, shown)
      end
    end
  end

  ---Add `piece` to a held stream, or drop the stream when it would pass a bound.
  ---@param key string
  ---@param stream table
  ---@param piece string
  ---@param current number
  ---@return boolean kept
  local function appendToStream(key, stream, piece, current)
    local length = #piece
    if stream.bytes + length > limits.maxAceStreamBytes then
      closeAceStream(key)
      countAce("aceStreamsOversize")
      noteAceDrop(stream.prefix, stream.sender, "oversize")
      return false
    end
    if aceComm.spoolBytes + length > limits.maxAceSpoolBytes then
      closeAceStream(key)
      countAce("aceStreamsRefusedQuota")
      noteAceDrop(stream.prefix, stream.sender, "quota")
      return false
    end
    local parts = stream.parts
    parts[#parts + 1] = piece
    stream.bytes = stream.bytes + length
    aceComm.spoolBytes = aceComm.spoolBytes + length
    stream.deadline = current + limits.aceStreamTimeout
    return true
  end

  ---Open a stream with its first part, replacing one held for the same prefix,
  ---distribution and sender, as AceComm does.
  ---@param key string
  ---@param prefix string
  ---@param sender string
  ---@param piece string
  ---@param current number
  local function openAceStream(key, prefix, sender, piece, current)
    if aceComm.streams[key] ~= nil then
      closeAceStream(key)
      countAce("aceStreamsReplaced")
    end
    local held = aceComm.senderStreams[sender] or 0
    if
      aceComm.streamCount >= limits.maxAceStreams
      or held >= limits.maxAceStreamsPerSender
      or aceComm.spoolBytes + #piece > limits.maxAceSpoolBytes
    then
      countAce("aceStreamsRefusedQuota")
      noteAceDrop(prefix, sender, "quota")
      return
    end
    if #piece > limits.maxAceStreamBytes then
      countAce("aceStreamsOversize")
      noteAceDrop(prefix, sender, "oversize")
      return
    end
    aceComm.streams[key] = {
      prefix = prefix,
      sender = sender,
      parts = { piece },
      bytes = #piece,
      deadline = current + limits.aceStreamTimeout,
    }
    aceComm.streamCount = aceComm.streamCount + 1
    aceComm.senderStreams[sender] = held + 1
    aceComm.spoolBytes = aceComm.spoolBytes + #piece
    countAce("aceStreamsOpened")
  end

  ---Read one addon message on an AceComm prefix with AceComm's rules
  ---(design section 8.3): `01` opens a stream, `02` adds to it, `03` adds and
  ---delivers it, `04` delivers the rest of the message, `05`-`09` are reserved
  ---and ignored, anything else is a whole message.
  ---@param prefix string
  ---@param text string
  ---@param distribution string
  ---@param sender string
  local function receiveAce(prefix, text, distribution, sender)
    local current = now()
    expireAceStreams(current)
    local control = string.byte(text, 1)
    local key = prefix .. "\t" .. distribution .. "\t" .. sender
    if control == ACE_CONTROL.first then
      openAceStream(key, prefix, sender, stringSub(text, 2), current)
    elseif control == ACE_CONTROL.middle or control == ACE_CONTROL.last then
      local stream = aceComm.streams[key]
      if stream == nil then
        countAce("aceOrphanParts")
        return
      end
      if
        appendToStream(key, stream, stringSub(text, 2), current) and control == ACE_CONTROL.last
      then
        local message = table.concat(stream.parts)
        closeAceStream(key)
        countAce("aceStreamsCompleted")
        deliverAce(prefix, message, distribution, sender)
      end
    elseif control == ACE_CONTROL.escape then
      deliverAce(prefix, stringSub(text, 2), distribution, sender)
    elseif
      control ~= nil
      and control >= ACE_CONTROL.reservedLow
      and control <= ACE_CONTROL.reservedHigh
    then
      countAce("aceReservedControl")
    else
      deliverAce(prefix, text, distribution, sender)
    end
  end

  ---The addon messages AceComm sends for `text` (design section 8.3).
  ---@param text string
  ---@return string[]
  local function aceParts(text)
    local length = #text
    local first = string.byte(text, 1)
    local controlFirst = first ~= nil
      and first >= ACE_CONTROL.first
      and first <= ACE_CONTROL.reservedHigh
    if length <= ACE_MESSAGE_BYTES and not controlFirst then
      return { text }
    end
    if controlFirst and length + 1 <= ACE_MESSAGE_BYTES then
      return { string.char(ACE_CONTROL.escape) .. text }
    end
    local parts = { string.char(ACE_CONTROL.first) .. stringSub(text, 1, ACE_PART_BYTES) }
    local position = ACE_PART_BYTES + 1
    while length - position + 1 > ACE_PART_BYTES do
      parts[#parts + 1] = string.char(ACE_CONTROL.middle)
        .. stringSub(text, position, position + ACE_PART_BYTES - 1)
      position = position + ACE_PART_BYTES
    end
    parts[#parts + 1] = string.char(ACE_CONTROL.last) .. stringSub(text, position)
    return parts
  end

  ---The first live channel on a prefix, closed channels pruned.
  ---@param record table
  ---@return table|nil
  local function firstLiveChannel(record)
    local channels = record.channels
    local index = 1
    while index <= #channels do
      if channels[index]:IsClosed() then
        table.remove(channels, index)
      else
        return channels[index]
      end
    end
    return nil
  end

  ---Forget a prefix's record and its streams once no channel is left on it.
  ---@param prefix string
  local function releasePrefix(prefix)
    local record = aceComm.prefixes[prefix]
    if record == nil or firstLiveChannel(record) ~= nil then
      return
    end
    aceComm.prefixes[prefix] = nil
    for key, stream in next, aceComm.streams do
      if stream.prefix == prefix then
        closeAceStream(key)
      end
    end
  end

  local ChannelMethods = {}

  ---Send a text as AceComm sends it, through the channel's CommKit scope.
  ---Returns CommKit's send handle, or `nil` and `"closed"`, `"nulByte"`,
  ---`"tooLarge"` or a refusal of CommKit's `SendRaw`.
  ---@param self table
  ---@param request table
  ---@return table|nil handle
  ---@return string|nil reason
  function ChannelMethods.Send(self, request)
    local label = "BridgeKit channel:Send"
    if getmetatable(self) ~= CHANNEL_METATABLE then
      error(label .. " must be called on a BridgeKit channel; use channel:Send(...)", 2)
    end
    if type(request) ~= "table" then
      error(label .. " request must be a table", 2)
    end
    for key in next, request do
      if isSecretValue(key) or type(key) ~= "string" or not CHANNEL_SEND_KEYS[key] then
        error(label .. " request has an unknown field", 2)
      end
    end
    local text = rawget(request, "text")
    if type(text) ~= "string" or isSecretValue(text) or text == "" then
      error(label .. " request.text must be a non-empty string that is not secret", 2)
    end
    if self:IsClosed() then
      return nil, "closed"
    end
    -- AceComm refuses NUL (AceComm-3.0.lua:77); the client cannot carry it.
    if stringFind(text, "%z") ~= nil then
      return nil, "nulByte"
    end
    local parts = aceParts(text)
    if #parts > MAX_RAW_PARTS then
      return nil, "tooLarge"
    end
    local CommKit = rawget(self, "_commKit")
    local ok, handle, reason = pcall(rawget(self, "_scope").SendRaw, rawget(self, "_scope"), {
      prefix = rawget(self, "_prefix"),
      parts = parts,
      distribution = rawget(request, "distribution"),
      target = rawget(request, "target"),
      priority = rawget(CommKit, "Priority")[rawget(self, "_priority")],
      onProgress = rawget(request, "onProgress"),
      onComplete = rawget(request, "onComplete"),
    })
    if not ok then
      local message = type(handle) == "string" and string.gsub(handle, "^[^\n]-:%d+: ", "")
        or tostring(handle)
      error(label .. " " .. message, 2)
    end
    if handle ~= nil then
      countAce("aceMessagesSent")
      countAce("acePartsSent", #parts)
    end
    return handle, reason
  end

  ---Close the channel: its raw registration ends, and the prefix's streams go
  ---with its last channel. Returns `false` when it was already closed.
  ---@param self table
  ---@return boolean
  function ChannelMethods.Close(self)
    if getmetatable(self) ~= CHANNEL_METATABLE then
      error("BridgeKit channel:Close must be called on a BridgeKit channel; use channel:Close()", 2)
    end
    if rawget(self, "_closed") then
      return false
    end
    rawset(self, "_closed", true)
    local connection = rawget(self, "_connection")
    if connection:IsConnected() then
      connection:Disconnect()
    end
    releasePrefix(rawget(self, "_prefix"))
    return true
  end

  ---Whether the channel is closed, by `Close` or with its CommKit scope.
  ---@param self table
  ---@return boolean
  function ChannelMethods.IsClosed(self)
    return rawget(self, "_closed") == true or not rawget(self, "_connection"):IsConnected()
  end

  ---@param self table
  ---@return string
  function ChannelMethods.GetPrefix(self)
    return rawget(self, "_prefix")
  end

  ---@param self table
  ---@return "ALERT"|"NORMAL"|"BULK"
  function ChannelMethods.GetPriority(self)
    return rawget(self, "_priority")
  end

  ---@param self table
  ---@return integer
  function ChannelMethods.GetWireVersion(self)
    return rawget(self, "_wire")
  end

  for name, method in next, ChannelMethods do
    rawset(aceComm.channelPrototype, name, method)
  end

  ---CommKit API 1 with raw addon messages, or `nil`.
  ---@return table|nil CommKit
  local function findRawCommKit()
    local CommKit = Registry:Find("commKit", 1)
    if type(CommKit) ~= "table" then
      return nil
    end
    local prototype = rawget(CommKit, "Scope")
    if
      type(prototype) ~= "table"
      or type(rawget(prototype, "RegisterRaw")) ~= "function"
      or type(rawget(prototype, "SendRaw")) ~= "function"
      or type(rawget(CommKit, "Priority")) ~= "table"
    then
      return nil
    end
    return CommKit
  end

  ---Read the options of `OpenAceComm`, raising at the caller's caller.
  ---@param label string
  ---@param options any
  ---@return table
  local function readChannelOptions(label, options)
    local read = { priority = "NORMAL", wire = ACE_WIRE_VERSION, ambiguate = true }
    if type(options) == "nil" then
      return read
    end
    if type(options) ~= "table" then
      refuseOption(label, "options must be a table or nil")
    end
    for key, value in next, options do
      if isSecretValue(key) or isSecretValue(value) then
        refuseOption(label, "options must not hold a secret key or value")
      end
      if type(key) ~= "string" or not CHANNEL_OPTION_KEYS[key] then
        refuseOption(label, "options has no field named " .. renderKey(key))
      end
    end
    local priority = rawget(options, "priority")
    if type(priority) ~= "nil" then
      if type(priority) ~= "string" or not ACE_PRIORITIES[priority] then
        refuseOption(label, 'options.priority must be "ALERT", "NORMAL" or "BULK"')
      end
      read.priority = priority
    end
    local wire = rawget(options, "wire")
    if type(wire) ~= "nil" then
      if wire ~= ACE_WIRE_VERSION then
        refuseOption(label, "options.wire must be a wire version this revision speaks: 1")
      end
      read.wire = wire
    end
    local ambiguate = rawget(options, "ambiguate")
    if type(ambiguate) ~= "nil" then
      if type(ambiguate) ~= "boolean" then
        refuseOption(label, "options.ambiguate must be a boolean")
      end
      read.ambiguate = ambiguate
    end
    return read
  end

  ---Open an AceComm-3.0 channel on `prefix` through a CommKit scope (design
  ---section 5.7). Returns the channel, or `nil` and CommKit's registration
  ---refusal.
  ---@param self BridgeKit
  ---@param scope table a CommKit scope
  ---@param prefix string
  ---@param callback fun(prefix: string, message: string, distribution: string, sender: string)
  ---@param options table?
  ---@return table|nil channel
  ---@return string|nil reason
  function openAceComm(self, scope, prefix, callback, options)
    local label = "BridgeKit:OpenAceComm"
    validateFacade(self, label, 3)
    local CommKit = findRawCommKit()
    if CommKit == nil then
      error(
        label
          .. " requires CommKit API 1 with raw addon messages (RegisterRaw, SendRaw), which is not loaded",
        2
      )
    end
    if isSecretValue(scope) or type(scope) ~= "table" or type(scope.RegisterRaw) ~= "function" then
      error(label .. " scope must be a CommKit scope", 2)
    end
    if type(prefix) ~= "string" or isSecretValue(prefix) or #prefix < 1 or #prefix > 16 then
      error(label .. " prefix must be a string of 1 to 16 bytes that is not secret", 2)
    end
    if type(callback) ~= "function" then
      error(label .. " callback must be a function", 2)
    end
    local read = readChannelOptions(label, options)
    local record = aceComm.prefixes[prefix]
    if record ~= nil and firstLiveChannel(record) == nil then
      releasePrefix(prefix)
      record = nil
    end
    if record ~= nil and record.priority ~= read.priority then
      error(
        label
          .. ' options.priority "'
          .. read.priority
          .. '" differs from "'
          .. record.priority
          .. '", which the first channel on prefix "'
          .. prefix
          .. '" set',
        2
      )
    end
    local channel = setmetatable({
      _prefix = prefix,
      _priority = read.priority,
      _wire = read.wire,
      _callback = callback,
      _ambiguate = read.ambiguate,
      _scope = scope,
      _commKit = CommKit,
      _closed = false,
    }, CHANNEL_METATABLE)
    local connection, reason = scope:RegisterRaw(
      prefix,
      function(rawPrefix, text, distribution, sender)
        local current = aceComm.prefixes[rawPrefix]
        if current ~= nil and firstLiveChannel(current) == channel then
          receiveAce(rawPrefix, text, distribution, sender)
        end
      end
    )
    if connection == nil then
      return nil, reason
    end
    rawset(channel, "_connection", connection)
    if record == nil then
      record = { priority = read.priority, channels = {} }
      aceComm.prefixes[prefix] = record
    end
    record.channels[#record.channels + 1] = channel
    return channel, nil
  end

  ---The AceComm counters and the current stream totals, in a fresh table.
  ---@param self BridgeKit
  ---@return table
  function getStatistics(self)
    validateFacade(self, "BridgeKit:GetStatistics", 3)
    local copy = {}
    for _, name in ipairs(ACE_STATISTICS) do
      copy[name] = aceComm.statistics[name]
    end
    copy.openStreams = aceComm.streamCount
    copy.spoolBytes = aceComm.spoolBytes
    return copy
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
rawset(BridgeKit, "ConvertAceConfig", convertAceConfig)
rawset(BridgeKit, "DefineAceConfig", defineAceConfig)
rawset(BridgeKit, "FormatReport", formatReport)
rawset(BridgeKit, "PreviewAceDB", previewAceDB)
rawset(BridgeKit, "ImportAceDB", importAceDB)
rawset(BridgeKit, "AceDBMigration", aceDBMigration)
rawset(BridgeKit, "OpenAceComm", openAceComm)
rawset(BridgeKit, "GetStatistics", getStatistics)
rawset(BridgeKit, "SetLimits", setLimits)
rawset(BridgeKit, "GetLimits", getLimits)

if not validatePublicSurface(BridgeKit) or not validateCurrentState(BridgeKit) then
  error("MoltenCodes BridgeKit package state is corrupted or incomplete", 2)
end

return BridgeKit
