-- MoltenCodes RangeKit
--
-- How far a unit is from the player, in whole yards, and whether it is within
-- a given distance: what LibRangeCheck-3.0 gives unit frames, nameplates and
-- range displays.
--
-- The client answers no distance query for an arbitrary unit, so the estimate
-- comes from yes-or-no checks of known reach, sorted by range: the player's own
-- spells (`C_Spell.IsSpellInRange`, their reach read from
-- `C_Spell.GetSpellInfo`, never written down here) and the interact distances
-- of `CheckInteractDistance` (index 3, 7 yards; index 4, 28 yards, as
-- warcraft.wiki.gg documents them). The closest check that says "in range"
-- and the one below it bracket the distance.
--
-- A short built-in list per class names candidate spell IDs in four kinds:
-- `harm`, `friend`, `resurrect` and `pet`. Only those
-- `C_SpellBook.IsSpellInSpellBook` reports are used, so one list serves
-- Retail, Mists of Pandaria Classic and Classic Era, and a spell a flavour or
-- the player lacks simply drops out. The IDs come from LibRangeCheck-3.0
-- (MIT); none of its code is used. See docs/API.md for the table.
--
-- The client refuses `CheckInteractDistance` from addon code in combat for a
-- unit the player cannot attack (patch 10.2.0 hotfixes of 2023-11-16 and
-- 2023-12-11). Whether Classic flavours do the same is not documented, so the
-- interact checks are skipped for such a unit during `InCombatLockdown()` on
-- every flavour (docs/ROADMAP.md, rangeKit, the safe reading).
--
-- RangeKit requires Registry API 2. It reads at call time `CreateFrame`,
-- `C_EventUtils`, `C_Spell`, `C_SpellBook`, `Enum`, `UnitClass`,
-- `UnitExists`, `UnitCanAttack`, `UnitCanAssist`, `UnitIsDeadOrGhost`,
-- `UnitIsUnit`, `InCombatLockdown`, `CheckInteractDistance`, `issecretvalue`
-- and `geterrorhandler`.
--
-- Contents
-- --------
--   Constants ............. identity, limits, candidate spells, events
--   Public types .......... LuaCATS declarations for the published surface
--   Dependencies .......... Registry, host readers
--   Validation ............ public-surface and shared-state predicates
--   Bootstrap ............. Registry registration and inherited state
--   Host facilities ....... secret values, the error handler, the client
--   Argument checks ....... receivers, units, yards, kinds, limits
--   Checker lists ......... building the sorted lists from the spellbook
--   Range estimate ........ asking the checks, choosing a list per unit
--   Listeners ............. the rebuild events and change notifications
--   Connection methods .... Disconnect, IsConnected
--   Package public API .... the facade published through Registry
--   Commit ................ prototype/facade assignment, self-check, listening

-- Constants ------------------------------------------------------------------

local PACKAGE_NAME = "rangeKit"
local API_GENERATION = 1
local IMPLEMENTATION_REVISION = 2
local REQUIRED_REGISTRY_API = 2
local STATE_SCHEMA = 1

-- `maxListeners`: change listeners connected at once. Each holds a caller's
-- closure for the session, so the limit has a ceiling and no unbounded setting.
local MAX_LISTENERS, LISTENERS_CEILING = 32, 256

-- The kinds of list, in the order `DescribeCheckers` documents them.
local KINDS = { "harm", "friend", "resurrect", "pet", "interact" }
local KIND_NAMES = { harm = true, friend = true, resurrect = true, pet = true, interact = true }

-- The interact distances `CheckInteractDistance` checks, as warcraft.wiki.gg
-- documents them: index 3 (Duel) 7 yards, index 4 (Follow) 28 yards.
local INTERACT_DISTANCES = { { index = 3, range = 7 }, { index = 4, range = 28 } }

-- Candidate spell IDs per class file name (`UnitClass` second answer) and
-- kind, from LibRangeCheck-3.0 minor 39 (MIT). Their reach is read from the
-- client; an ID the player's spellbook does not report is skipped, so IDs of
-- every flavour sit side by side. Within a kind the first spell of a range
-- wins.
local CANDIDATE_SPELLS = {
  DEATHKNIGHT = { harm = { 49576, 47541 }, resurrect = { 61999 } },
  DEMONHUNTER = { harm = { 185123, 183752 } },
  DRUID = {
    harm = { 5176, 8921, 339, 33786 },
    friend = { 8936, 774, 5185 },
    resurrect = { 50769, 20484 },
  },
  EVOKER = { harm = { 362969 }, friend = { 361469, 355913 }, resurrect = { 361227 } },
  HUNTER = { harm = { 75, 466930, 2764 }, pet = { 136 } },
  MAGE = { harm = { 133, 116, 118, 5019 }, friend = { 1459, 475 } },
  MONK = {
    harm = { 117952, 115546, 115078 },
    friend = { 116670, 115450 },
    resurrect = { 115178 },
  },
  PALADIN = {
    harm = { 20271, 62124, 853, 20473 },
    friend = { 19750, 635, 85673 },
    resurrect = { 7328 },
  },
  PRIEST = {
    harm = { 589, 585, 8092, 5019 },
    friend = { 2061, 2050, 17, 527 },
    resurrect = { 2006 },
  },
  ROGUE = { harm = { 2094, 921, 185565, 2764 } },
  SHAMAN = {
    harm = { 403, 188196, 370, 8042 },
    friend = { 331, 8004, 546 },
    resurrect = { 2008 },
  },
  WARLOCK = {
    harm = { 686, 5782, 172, 5019 },
    friend = { 5697 },
    resurrect = { 20707 },
    pet = { 755 },
  },
  WARRIOR = { harm = { 355, 100, 5246, 2764 } },
}

-- The events after which the player's spells may have changed. All four are in
-- the generated documentation of Retail, Mists of Pandaria Classic and Classic
-- Era; each is still registered only when `C_EventUtils.IsEventValid` agrees.
local REBUILD_EVENTS = {
  "SPELLS_CHANGED",
  "LEARNED_SPELL_IN_SKILL_LINE",
  "PLAYER_TALENT_UPDATE",
  "CHARACTER_POINTS_CHANGED",
}
-- The player's pet changed: the pet spells may have changed with it.
local PET_EVENT = "UNIT_PET"

-- The `__metatable` of every connection handle. It hides the handle's metatable.
local CONNECTION_METATABLE_TAG = "RangeKit.Connection"

local FACADE_METHODS =
  { "GetRange", "IsInRange", "DescribeCheckers", "OnCheckersChanged", "SetLimits", "GetLimits" }
local CONNECTION_METHODS = { "Disconnect", "IsConnected" }

-- Public types ---------------------------------------------------------------

---A kind of checker list.
---@alias RangeKit.Kind "harm"|"friend"|"resurrect"|"pet"|"interact"

---One checker as `DescribeCheckers` describes it.
---@class RangeKit.CheckerInfo
---@field range integer Yards the checker answers for.
---@field minRange integer? The spell's minimum range, when it has one.
---@field source string `"spell:<id>"` or `"interact:<index>"`.

---A connected change listener.
---@class RangeKit.Connection
---@field Disconnect fun(self: RangeKit.Connection): boolean
---@field IsConnected fun(self: RangeKit.Connection): boolean

---The shared limits.
---@class RangeKit.Limits
---@field maxListeners integer Listeners connected at once: 1 to 256; default `32`.

---The RangeKit package facade published through Registry.
---@class RangeKit
---@field API integer Public API generation.
---@field REVISION integer Compatible implementation revision.
---@field MAX_LISTENERS integer Default of `maxListeners` (`32`).
---@field LISTENERS_CEILING integer The highest `maxListeners` accepts (`256`).
---@field GetRange fun(self: RangeKit, unit: string): integer?, integer?
---@field IsInRange fun(self: RangeKit, unit: string, yards: number): boolean?
---@field DescribeCheckers fun(self: RangeKit, kind: RangeKit.Kind): RangeKit.CheckerInfo[]
---@field OnCheckersChanged fun(self: RangeKit, callback: fun()): RangeKit.Connection
---@field SetLimits fun(self: RangeKit, limits: RangeKit.Limits)
---@field GetLimits fun(self: RangeKit): RangeKit.Limits

-- Dependencies ---------------------------------------------------------------

-- The shared MoltenCodes namespace is the one documented global handoff point between independently embedded copies.
-- selene: allow(global_usage)
local namespace = rawget(_G, "MoltenCodes")
local generations = type(namespace) == "table" and rawget(namespace, "Registries") or nil

-- Ask for Registry by generation and fall back to the alias. A future Registry
-- API generation takes over `MoltenCodes.Registry`, so reading the alias first
-- would hand this file a facade whose contract it was not written against.
local Registry = type(generations) == "table" and rawget(generations, REQUIRED_REGISTRY_API) or nil
if Registry == nil and type(namespace) == "table" then
  Registry = rawget(namespace, "Registry")
end
if type(Registry) ~= "table" or rawget(Registry, "API") ~= REQUIRED_REGISTRY_API then
  error("MoltenCodes RangeKit requires Registry API 2 to be loaded first", 2)
end

local bootstrapPackage = rawget(Registry, "Bootstrap")
if type(bootstrapPackage) ~= "function" then
  error("MoltenCodes RangeKit requires a valid Registry API 2 facade", 2)
end

---Read a host global without triggering a metatable, or `nil`.
---@param name string
---@return any
local function readGlobal(name)
  -- Host APIs are reachable only through the global table.
  -- selene: allow(global_usage)
  return rawget(_G, name)
end

-- Validation -----------------------------------------------------------------

---Whether `implementation` exposes the complete RangeKit API 1 surface.
---@param implementation any shared package table handed back by Registry
---@return boolean
local function validatePublicSurface(implementation)
  if
    type(implementation) ~= "table"
    or rawget(implementation, "API") ~= API_GENERATION
    or type(rawget(implementation, "REVISION")) ~= "number"
  then
    return false
  end
  for index = 1, #FACADE_METHODS do
    if type(rawget(implementation, FACADE_METHODS[index])) ~= "function" then
      return false
    end
  end
  return true
end

---Whether `value` is an exact integer from 1 to the ceiling.
---@param value any
---@return boolean
local function isListenerLimit(value)
  return type(value) == "number" and value >= 1 and value <= LISTENERS_CEILING and value % 1 == 0
end

---Whether `lists` holds an `all` and a `spells` array for every kind.
---@param lists any
---@return boolean
local function validateLists(lists)
  if type(lists) ~= "table" then
    return false
  end
  for index = 1, #KINDS do
    local list = rawget(lists, KINDS[index])
    if
      type(list) ~= "table"
      or type(rawget(list, "all")) ~= "table"
      or type(rawget(list, "spells")) ~= "table"
    then
      return false
    end
  end
  return true
end

---Whether `currentState` has the fields every API 1 revision shares.
---@param currentState any
---@return boolean
local function validateStateBase(currentState)
  if type(currentState) ~= "table" or rawget(currentState, "schema") ~= STATE_SCHEMA then
    return false
  end
  local limits = rawget(currentState, "limits")
  return type(rawget(currentState, "runtimeRevision")) == "number"
    and type(limits) == "table"
    and isListenerLimit(rawget(limits, "maxListeners"))
    and validateLists(rawget(currentState, "lists"))
    and type(rawget(currentState, "built")) == "boolean"
    and type(rawget(currentState, "listeners")) == "table"
    and type(rawget(currentState, "connectionPrototype")) == "table"
    and type(rawget(currentState, "connectionMetatable")) == "table"
    and type(rawget(currentState, "dispatch")) == "table"
    and type(rawget(currentState, "scripts")) == "table"
end

---Whether `implementation` carries package state of this revision's schema.
---@param implementation table
---@return boolean
local function validateCurrentState(implementation)
  return validateStateBase(rawget(implementation, "_state"))
end

---Empty lists of every kind: what the session holds before the first build.
---@return table<string, { all: table[], spells: table[] }>
local function emptyLists()
  local lists = {}
  for index = 1, #KINDS do
    lists[KINDS[index]] = { all = {}, spells = {} }
  end
  return lists
end

-- Bootstrap ------------------------------------------------------------------

-- `Registry:Bootstrap` owns the reconciliation every embedded package repeats:
-- look the package up, refuse to reinterpret state owned by a newer revision,
-- and register this one. What stays here is what only RangeKit can answer.
local RangeKit, previousRevision, selected = bootstrapPackage(Registry, {
  package = PACKAGE_NAME,
  api = API_GENERATION,
  revision = IMPLEMENTATION_REVISION,
  label = "MoltenCodes RangeKit",
  validatePublicSurface = validatePublicSurface,
  validateState = validateCurrentState,
})

if RangeKit == nil then
  -- An equal or newer compatible revision already owns the shared package table.
  return selected
end

local state = rawget(RangeKit, "_state")

if previousRevision == nil then
  if state ~= nil then
    error("MoltenCodes RangeKit package state is corrupted or incomplete", 2)
  end

  -- Functions every loading revision rewrites. The event frame holds the
  -- closure below for the session, so it looks its behaviour up here.
  local dispatch = {}
  local connectionPrototype = {}

  state = {
    schema = STATE_SCHEMA,
    runtimeRevision = 0,
    limits = { maxListeners = MAX_LISTENERS },
    -- The checker lists per kind, replaced whole by each rebuild, and whether
    -- the first build has happened.
    lists = emptyLists(),
    built = false,
    -- Connected listener records, in connection order.
    listeners = {},
    -- The frame that listens for the rebuild events, made once per session.
    eventFrame = false,
    connectionPrototype = connectionPrototype,
    connectionMetatable = {
      __index = connectionPrototype,
      __metatable = CONNECTION_METATABLE_TAG,
    },
    dispatch = dispatch,
    scripts = {
      OnEvent = function(_, event, unit)
        dispatch.event(event, unit)
      end,
    },
  }
  rawset(RangeKit, "_state", state)
elseif not validateStateBase(state) then
  error("MoltenCodes RangeKit package state is corrupted or incomplete", 2)
end

local dispatch = rawget(state, "dispatch")
local scripts = rawget(state, "scripts")
local listeners = rawget(state, "listeners")
local ConnectionPrototype = rawget(state, "connectionPrototype")
local CONNECTION_METATABLE = rawget(state, "connectionMetatable")
local sharedLimits = rawget(state, "limits")

-- Host facilities ------------------------------------------------------------

---Whether `value` is a secret value (Retail 12.x). `issecretvalue` is looked
---up at every call, so a probe that appears after load is used at once.
---@param value any
---@return boolean
local function isSecret(value)
  local probe = readGlobal("issecretvalue")
  return type(probe) == "function" and probe(value) == true
end

---Whether the client answered yes: a value that is not secret, `nil`,
---`false` or `0` (legacy calls answer `1` or `0`).
---@param value any
---@return boolean
local function isYes(value)
  if isSecret(value) then
    return false
  end
  return value ~= nil and value ~= false and value ~= 0
end

---A number the client answered, or `nil` for a secret or anything else.
---@param value any
---@return number?
local function plainNumber(value)
  if isSecret(value) or type(value) ~= "number" then
    return nil
  end
  return value
end

---Hand `failure` to the host error handler without raising. Outside a client
---it is printed, as the client's own default handler would.
---@param failure any
local function reportError(failure)
  local getErrorHandler = readGlobal("geterrorhandler")
  if type(getErrorHandler) == "function" then
    local handler = getErrorHandler()
    if type(handler) == "function" then
      handler(failure)
      return
    end
  end
  print(failure)
end

---The player's class file name (`"PRIEST"`), or `nil`.
---@return string?
local function playerClass()
  local unitClass = readGlobal("UnitClass")
  if type(unitClass) ~= "function" then
    return nil
  end
  local _, classFile = unitClass("player")
  if isSecret(classFile) or type(classFile) ~= "string" then
    return nil
  end
  return classFile
end

---Whether `unit` exists.
---@param unit string
---@return boolean
local function unitExists(unit)
  local query = readGlobal("UnitExists")
  return type(query) == "function" and isYes(query(unit))
end

---Whether the player can attack `unit`.
---@param unit string
---@return boolean
local function canAttack(unit)
  local query = readGlobal("UnitCanAttack")
  return type(query) == "function" and isYes(query("player", unit))
end

---Whether the player can assist `unit`.
---@param unit string
---@return boolean
local function canAssist(unit)
  local query = readGlobal("UnitCanAssist")
  return type(query) == "function" and isYes(query("player", unit))
end

---Whether `unit` is dead or a ghost.
---@param unit string
---@return boolean
local function isDead(unit)
  local query = readGlobal("UnitIsDeadOrGhost")
  return type(query) == "function" and isYes(query(unit))
end

---Whether `unit` is the player's pet.
---@param unit string
---@return boolean
local function isPet(unit)
  if unit == "pet" then
    return true
  end
  local query = readGlobal("UnitIsUnit")
  return type(query) == "function" and isYes(query(unit, "pet"))
end

---Whether the client is in combat lockdown.
---@return boolean
local function inCombat()
  local query = readGlobal("InCombatLockdown")
  return type(query) == "function" and isYes(query())
end

-- Argument checks ------------------------------------------------------------
--
-- Argument validation raises with an explicit stack level so the reported
-- position is the line that called the public method, never a line inside
-- RangeKit. `level` is always the value `error` needs *inside the function
-- that receives it*, so every further hop towards `error` adds exactly one.
-- Secrets are checked first, because comparing one raises.

---@param receiver any the table the method was called on
---@param label string public method name, used in the argument error
---@param level integer stack level the failure is reported at
local function validateFacade(receiver, label, level)
  -- `type` first: a secret receiver is never a table, and only a table is compared.
  if type(receiver) ~= "table" or receiver ~= RangeKit then
    error(label .. " must be called on the RangeKit facade; use " .. label .. "(...)", level)
  end
end

---@param unit any
---@param label string
---@param level integer stack level the failure is reported at
local function validateUnit(unit, label, level)
  if isSecret(unit) or type(unit) ~= "string" or unit == "" then
    error(label .. " unit must be a unit token string", level)
  end
end

---The record of a connection handle (connected or not), or raise.
---@param receiver any
---@param label string
---@param level integer stack level the failure is reported at
---@return table record
local function requireRecord(receiver, label, level)
  local record = nil
  if
    not isSecret(receiver)
    and type(receiver) == "table"
    and getmetatable(receiver) == CONNECTION_METATABLE_TAG
  then
    record = rawget(receiver, "_record")
  end
  if type(record) ~= "table" then
    error(
      label
        .. " must be called on a RangeKit connection; use connection:"
        .. label:match("[^:]+$")
        .. "(...)",
      level
    )
  end
  return record
end

-- Checker lists --------------------------------------------------------------
--
-- A checker is a table: `range` (whole yards), `source` (`"spell:589"`,
-- `"interact:4"`), and either `spellID` or `interactIndex`. A spell with a
-- minimum range also carries `minRange` and `closer`, the checker that answers
-- for units nearer than that minimum. Each kind keeps two ascending arrays:
-- `all`, and `spells`, the subset usable in combat on a unit the player cannot
-- attack (no interact check, directly or through `closer`).

---`value` rounded to whole yards.
---@param value number
---@return integer
local function toYards(value)
  return math.floor(value + 0.5)
end

---The reach of `spellID` when the player's spellbook has it: `range`,
---`minRange` in whole yards, or `nil`.
---@param spellID integer
---@return integer? range
---@return integer? minRange
local function knownSpellRange(spellID)
  local spellBook, spellApi, enum =
    readGlobal("C_SpellBook"), readGlobal("C_Spell"), readGlobal("Enum")
  if
    type(spellBook) ~= "table"
    or type(spellBook.IsSpellInSpellBook) ~= "function"
    or type(spellApi) ~= "table"
    or type(spellApi.GetSpellInfo) ~= "function"
    or type(enum) ~= "table"
    or type(enum.SpellBookSpellBank) ~= "table"
  then
    return nil
  end
  local bank = plainNumber(enum.SpellBookSpellBank.Player)
  if bank == nil or not isYes(spellBook.IsSpellInSpellBook(spellID, bank, true)) then
    return nil
  end
  local info = spellApi.GetSpellInfo(spellID)
  if isSecret(info) or type(info) ~= "table" then
    return nil
  end
  local maxRange = plainNumber(info.maxRange)
  if maxRange == nil then
    return nil
  end
  return toYards(maxRange), toYards(plainNumber(info.minRange) or 0)
end

---Insert `checker` into the ascending `list`, unless a checker of the same
---range is already there.
---@param list table[]
---@param checker table
local function insertSorted(list, checker)
  local range = checker.range
  for index = 1, #list do
    local existing = list[index].range
    if existing == range then
      return
    end
    if existing > range then
      table.insert(list, index, checker)
      return
    end
  end
  list[#list + 1] = checker
end

---The first checker of the ascending `list` without a minimum range whose
---range lies from `low` to `high`, or `nil`. Inside its range a unit is also
---inside `high`.
---@param list table[]
---@param low integer
---@param high integer
---@return table?
local function firstWithin(list, low, high)
  for index = 1, #list do
    local range = list[index].range
    if list[index].minRange == nil and range >= low and range <= high then
      return list[index]
    end
  end
  return nil
end

---Read the reach of every spell in `spellIDs`, putting those without a
---minimum range into `spells` and returning the others.
---@param spellIDs integer[]?
---@param spells table[]
---@param withMinimum table[]
local function addSpells(spellIDs, spells, withMinimum)
  if spellIDs == nil then
    return
  end
  for index = 1, #spellIDs do
    local spellID = spellIDs[index]
    local range, minRange = knownSpellRange(spellID)
    -- A melee spell answers 0: its reach depends on both units' combat reach,
    -- which the client does not expose, so it is left out.
    if range ~= nil and range > 0 then
      local checker = { range = range, source = "spell:" .. spellID, spellID = spellID }
      if minRange > 0 and minRange < range then
        checker.minRange = minRange
        withMinimum[#withMinimum + 1] = checker
      elseif minRange == 0 then
        insertSorted(spells, checker)
      end
    end
  end
end

---Build the lists of one kind from the candidate IDs and the interact checkers.
---@param first integer[]?
---@param second integer[]?
---@param interact table[]
---@return { all: table[], spells: table[] }
local function buildKind(first, second, interact)
  local spells, withMinimum = {}, {}
  addSpells(first, spells, withMinimum)
  addSpells(second, spells, withMinimum)
  local all = {}
  for index = 1, #spells do
    insertSorted(all, spells[index])
  end
  for index = 1, #interact do
    insertSorted(all, interact[index])
  end
  -- A spell with a minimum range says "out of range" for a unit too close, so
  -- it counts as in range when it says so or when a closer checker (one whose
  -- range lies from that minimum to the spell's range) does. Without one it
  -- would break the ordering the search relies on, and is left out.
  for index = 1, #withMinimum do
    local checker = withMinimum[index]
    local closer = firstWithin(spells, checker.minRange, checker.range)
    if closer ~= nil then
      checker.closer = closer
      insertSorted(spells, checker)
      insertSorted(all, checker)
    else
      closer = firstWithin(all, checker.minRange, checker.range)
      if closer ~= nil then
        checker.closer = closer
        insertSorted(all, checker)
      end
    end
  end
  return { all = all, spells = spells }
end

---The interact checkers, or none without `CheckInteractDistance`.
---@return table[]
local function interactCheckers()
  local checkers = {}
  if type(readGlobal("CheckInteractDistance")) ~= "function" then
    return checkers
  end
  for index = 1, #INTERACT_DISTANCES do
    local distance = INTERACT_DISTANCES[index]
    checkers[index] = {
      range = distance.range,
      source = "interact:" .. distance.index,
      interactIndex = distance.index,
    }
  end
  return checkers
end

---Fresh lists of every kind for the player as the client describes them now.
---@return table<string, { all: table[], spells: table[] }>
local function buildLists()
  local class = playerClass()
  local candidates = class and CANDIDATE_SPELLS[class] or {}
  local interact = interactCheckers()
  return {
    harm = buildKind(candidates.harm, nil, interact),
    friend = buildKind(candidates.friend, nil, interact),
    resurrect = buildKind(candidates.resurrect, nil, interact),
    -- Friendly spells reach the pet too, so its list holds both.
    pet = buildKind(candidates.pet, candidates.friend, interact),
    interact = buildKind(nil, nil, interact),
  }
end

---Whether two ascending checker arrays describe the same checks: the same
---range, minimum range and source at every position. The `closer` pairing
---follows from those, so it needs no comparison of its own.
---@param left table[]
---@param right table[]
---@return boolean
local function sameCheckers(left, right)
  if #left ~= #right then
    return false
  end
  for index = 1, #left do
    local leftChecker, rightChecker = left[index], right[index]
    if
      leftChecker.range ~= rightChecker.range
      or leftChecker.minRange ~= rightChecker.minRange
      or leftChecker.source ~= rightChecker.source
    then
      return false
    end
  end
  return true
end

---Whether every kind of `left` and `right` describes the same checks.
---@param left table
---@param right table
---@return boolean
local function sameLists(left, right)
  for index = 1, #KINDS do
    local kind = KINDS[index]
    if
      not sameCheckers(left[kind].all, right[kind].all)
      or not sameCheckers(left[kind].spells, right[kind].spells)
    then
      return false
    end
  end
  return true
end

-- Range estimate -------------------------------------------------------------

---Whether `checker`, without its `closer`, says `unit` is in range.
---@param checker table
---@param unit string
---@return boolean
local function checkOnce(checker, unit)
  local spellID = checker.spellID
  if spellID ~= nil then
    local spellApi = readGlobal("C_Spell")
    return type(spellApi) == "table"
      and type(spellApi.IsSpellInRange) == "function"
      and isYes(spellApi.IsSpellInRange(spellID, unit))
  end
  local checkInteractDistance = readGlobal("CheckInteractDistance")
  return type(checkInteractDistance) == "function"
    and isYes(checkInteractDistance(unit, checker.interactIndex))
end

---Whether `checker` says `unit` is in range. No answer counts as no.
---@param checker table
---@param unit string
---@return boolean
local function saysInRange(checker, unit)
  if checkOnce(checker, unit) then
    return true
  end
  local closer = checker.closer
  return closer ~= nil and checkOnce(closer, unit)
end

---Bracket `unit`'s distance with the ascending `list`: the smallest checker
---that says "in range" and the one below it. A binary search: being in range
---of one checker means being in range of every longer one.
---@param list table[]
---@param unit string
---@return integer? minRange
---@return integer? maxRange
local function estimate(list, unit)
  local count = #list
  if count == 0 then
    return nil, nil
  end
  local low, high, first = 1, count, nil
  while low <= high do
    local middle = math.floor((low + high) / 2)
    if saysInRange(list[middle], unit) then
      first = middle
      high = middle - 1
    else
      low = middle + 1
    end
  end
  if first == nil then
    return list[count].range, nil
  end
  if first == 1 then
    return 0, list[1].range
  end
  return list[first - 1].range, list[first].range
end

---Rebuild the lists; tell the listeners when they changed.
local function rebuild()
  local fresh = buildLists()
  local changed = not sameLists(rawget(state, "lists"), fresh)
  rawset(state, "lists", fresh)
  rawset(state, "built", true)
  if changed then
    dispatch.notify()
  end
end

---Build the lists on the first query, and listen for the rebuild events if
---the client could not make a frame at load.
local function ensureBuilt()
  dispatch.listen()
  if not rawget(state, "built") then
    rebuild()
  end
end

---The list to search for `unit`: its kind picks it, and combat on a unit the
---player cannot attack leaves out the interact checks.
---@param unit string
---@return table[]
local function listFor(unit)
  local lists = rawget(state, "lists")
  local attackable = canAttack(unit)
  local kind
  if isDead(unit) then
    kind = canAssist(unit) and "resurrect" or "interact"
  elseif attackable then
    kind = "harm"
  elseif isPet(unit) then
    kind = "pet"
  elseif canAssist(unit) then
    kind = "friend"
  else
    kind = "interact"
  end
  if not attackable and inCombat() then
    return lists[kind].spells
  end
  return lists[kind].all
end

---The estimate for `unit`, building the lists first when needed.
---@param unit string
---@return integer? minRange
---@return integer? maxRange
local function rangeOf(unit)
  if not unitExists(unit) then
    return nil, nil
  end
  ensureBuilt()
  local minRange, maxRange = estimate(listFor(unit), unit)
  return minRange, maxRange
end

-- Listeners ------------------------------------------------------------------

---Call every connected listener once. A listener that raises is reported and
---the others still run; one that disconnects another during the call is
---respected.
function dispatch.notify()
  local snapshot = {}
  for index = 1, #listeners do
    snapshot[index] = listeners[index]
  end
  for index = 1, #snapshot do
    local record = snapshot[index]
    if record.connected then
      local ok, failure = pcall(record.callback)
      if not ok then
        reportError(failure)
      end
    end
  end
end

---A rebuild event arrived: rebuild, and tell the listeners about a change.
---@param event string
---@param unit string?
function dispatch.event(event, unit)
  if event == PET_EVENT and unit ~= "player" then
    return
  end
  rebuild()
end

---Whether the client knows `event`; `true` when it cannot be asked.
---@param event string
---@return boolean
local function eventIsValid(event)
  local eventUtils = readGlobal("C_EventUtils")
  if type(eventUtils) ~= "table" or type(eventUtils.IsEventValid) ~= "function" then
    return true
  end
  return isYes(eventUtils.IsEventValid(event))
end

---Make the session's event frame once and register the rebuild events.
function dispatch.listen()
  if rawget(state, "eventFrame") then
    return
  end
  local createFrame = readGlobal("CreateFrame")
  if type(createFrame) ~= "function" then
    return
  end
  local eventFrame = createFrame("Frame")
  eventFrame:SetScript("OnEvent", scripts.OnEvent)
  for index = 1, #REBUILD_EVENTS do
    if eventIsValid(REBUILD_EVENTS[index]) then
      eventFrame:RegisterEvent(REBUILD_EVENTS[index])
    end
  end
  if eventIsValid(PET_EVENT) then
    eventFrame:RegisterUnitEvent(PET_EVENT, "player")
  end
  rawset(state, "eventFrame", eventFrame)
end

-- Connection methods ---------------------------------------------------------

---Stop the listener: `true`, or `false` when it already was.
---@param self RangeKit.Connection
---@return boolean
local function connectionDisconnect(self)
  local record = requireRecord(self, "RangeKit.Connection:Disconnect", 3)
  if not record.connected then
    return false
  end
  record.connected = false
  for index = #listeners, 1, -1 do
    if listeners[index] == record then
      table.remove(listeners, index)
    end
  end
  return true
end

---Whether the listener is still connected.
---@param self RangeKit.Connection
---@return boolean
local function connectionIsConnected(self)
  return requireRecord(self, "RangeKit.Connection:IsConnected", 3).connected == true
end

-- Package public API ---------------------------------------------------------

---Estimate how far `unit` is: `minRange, maxRange` in yards.
---@param self RangeKit
---@param unit string
---@return integer? minRange `nil` when no estimate exists; `0` when the shortest checker says in range
---@return integer? maxRange `nil` when the unit is beyond the longest checker
local function packageGetRange(self, unit)
  local label = "RangeKit:GetRange"
  validateFacade(self, label, 3)
  validateUnit(unit, label, 3)
  local minRange, maxRange = rangeOf(unit)
  return minRange, maxRange
end

---Whether `unit` is within `yards`: `true`, `false`, or `nil` when the
---estimate cannot decide.
---@param self RangeKit
---@param unit string
---@param yards number
---@return boolean?
local function packageIsInRange(self, unit, yards)
  local label = "RangeKit:IsInRange"
  validateFacade(self, label, 3)
  validateUnit(unit, label, 3)
  if
    isSecret(yards)
    or type(yards) ~= "number"
    or yards ~= yards
    or yards < 0
    or yards == math.huge
  then
    error(label .. " yards must be a finite number of at least 0", 2)
  end
  local minRange, maxRange = rangeOf(unit)
  if minRange == nil then
    return nil
  end
  if maxRange ~= nil and maxRange <= yards then
    return true
  end
  if minRange >= yards then
    return false
  end
  return nil
end

---Describe the checkers of `kind`, shortest first, in fresh tables.
---@param self RangeKit
---@param kind RangeKit.Kind
---@return RangeKit.CheckerInfo[]
local function packageDescribeCheckers(self, kind)
  local label = "RangeKit:DescribeCheckers"
  validateFacade(self, label, 3)
  if isSecret(kind) or type(kind) ~= "string" or not KIND_NAMES[kind] then
    error(label .. " kind must be harm, friend, resurrect, pet or interact", 2)
  end
  ensureBuilt()
  local list = rawget(state, "lists")[kind].all
  local described = {}
  for index = 1, #list do
    local checker = list[index]
    described[index] =
      { range = checker.range, minRange = checker.minRange, source = checker.source }
  end
  return described
end

---Call `callback()` after every rebuild that changed a list.
---@param self RangeKit
---@param callback fun()
---@return RangeKit.Connection
local function packageOnCheckersChanged(self, callback)
  local label = "RangeKit:OnCheckersChanged"
  validateFacade(self, label, 3)
  if isSecret(callback) or type(callback) ~= "function" then
    error(label .. " callback must be a function", 2)
  end
  local maxListeners = rawget(sharedLimits, "maxListeners")
  if #listeners >= maxListeners then
    error(
      label
        .. " holds at most "
        .. maxListeners
        .. " listeners; raise maxListeners with RangeKit:SetLimits",
      2
    )
  end
  dispatch.listen()
  local handle = setmetatable({}, CONNECTION_METATABLE)
  local record = { handle = handle, callback = callback, connected = true }
  rawset(handle, "_record", record)
  listeners[#listeners + 1] = record
  return handle
end

---Change `maxListeners`. Lowering it keeps every connection.
---@param self RangeKit
---@param limits RangeKit.Limits
local function packageSetLimits(self, limits)
  validateFacade(self, "RangeKit:SetLimits", 3)
  if isSecret(limits) or type(limits) ~= "table" then
    error("RangeKit:SetLimits limits must be a table", 2)
  end
  for key, value in pairs(limits) do
    if isSecret(key) or key ~= "maxListeners" then
      error("RangeKit:SetLimits limits holds an unknown field; it accepts maxListeners", 2)
    end
    if isSecret(value) then
      error("RangeKit:SetLimits limits.maxListeners must not be a secret value", 2)
    end
    if not isListenerLimit(value) then
      error(
        "RangeKit:SetLimits limits.maxListeners must be an integer from 1 to " .. LISTENERS_CEILING,
        2
      )
    end
  end
  if type(limits.maxListeners) ~= "nil" then
    rawset(sharedLimits, "maxListeners", limits.maxListeners)
  end
end

---Return a fresh copy of the shared limits. Allocates one table per call.
---@param self RangeKit
---@return RangeKit.Limits
local function packageGetLimits(self)
  validateFacade(self, "RangeKit:GetLimits", 3)
  return { maxListeners = rawget(sharedLimits, "maxListeners") }
end

-- Commit ---------------------------------------------------------------------

rawset(ConnectionPrototype, "Disconnect", connectionDisconnect)
rawset(ConnectionPrototype, "IsConnected", connectionIsConnected)

rawset(RangeKit, "API", API_GENERATION)
rawset(RangeKit, "REVISION", IMPLEMENTATION_REVISION)
rawset(RangeKit, "MAX_LISTENERS", MAX_LISTENERS)
rawset(RangeKit, "LISTENERS_CEILING", LISTENERS_CEILING)
rawset(RangeKit, "GetRange", packageGetRange)
rawset(RangeKit, "IsInRange", packageIsInRange)
rawset(RangeKit, "DescribeCheckers", packageDescribeCheckers)
rawset(RangeKit, "OnCheckersChanged", packageOnCheckersChanged)
rawset(RangeKit, "SetLimits", packageSetLimits)
rawset(RangeKit, "GetLimits", packageGetLimits)

rawset(state, "runtimeRevision", IMPLEMENTATION_REVISION)

if not validatePublicSurface(RangeKit) or not validateCurrentState(RangeKit) then
  error("MoltenCodes RangeKit package state is corrupted or incomplete", 2)
end
for index = 1, #CONNECTION_METHODS do
  if type(rawget(ConnectionPrototype, CONNECTION_METHODS[index])) ~= "function" then
    error("MoltenCodes RangeKit package state is corrupted or incomplete", 2)
  end
end

-- The rebuild events are listened for from load, so a change of the player's
-- spells reaches the listeners even before the first query.
dispatch.listen()

return RangeKit
