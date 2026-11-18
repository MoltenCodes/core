-- MoltenCodes SettingsKit part SpecProfiles
--
-- Spec profiles: a character assigns a profile to a *spec index*, and when the
-- index changes the database switches to that profile through its own
-- `SetProfile`. The index is the specialization on clients that have them
-- (Retail, Mists of Pandaria Classic) and the active talent group elsewhere
-- (Classic Era, Season of Discovery, Hardcore), where dual talent
-- specialization is the switching mechanism. This is what LibDualSpec-1.0
-- gives AceDB-3.0 databases. The research behind the client facts is recorded
-- in `docs/records/settingsKit.md`, "settingsKit spec profiles".
--
-- Publishes `SettingsKit:GetSpecIndex()`, `db:SetSpecProfile`,
-- `db:GetSpecProfile` and `db:ApplySpecProfile`, and the dispatch entries the
-- core calls: `onDatabaseOpened` (at `Open`) and `onSpecEvent` (the one shared
-- listener). The core keeps the `specProfiles` section of the saved table and
-- forgets the assignments of a deleted profile itself, so the data stays right
-- in a session that does not load this part (ADR 0001).
--
-- The part needs SettingsKit's core loaded first (API 1, revision 16 or later:
-- the first that leaves spec profiles to this part). It calls the core only
-- through `state.helpers`, read at call time, so an upgraded core serves it.
-- EventKit is optional; with its Units part (or an EventKit whose core still
-- has `ConnectUnit`) the switch is automatic, otherwise the addon calls
-- `db:ApplySpecProfile()` itself.
--
-- Contents
-- --------
--   Constants ........ identity, the spec-index bound, the events
--   Dependencies ..... SettingsKit's core and its state
--   Client ........... reading the spec index from the client
--   Assignments ...... the saved assignments and switching to them
--   Listener ......... the shared spec-event listener
--   Methods .......... GetSpecIndex, SetSpecProfile, GetSpecProfile, ApplySpecProfile
--   Commit ........... members, dispatch entries and the part's revision

-- Constants ------------------------------------------------------------------

local PART_NAME = "SpecProfiles"
local PART_REVISION = 1
local REQUIRED_REGISTRY_API = 2
local CORE_PACKAGE, CORE_API = "settingsKit", 1
local OPTIONAL_EVENTKIT_API = 1

-- The highest spec index an assignment may name. No class has more than
-- four specializations and no client more than two talent groups; eight
-- leaves room without letting a typo create a large saved table.
local MAX_SPEC_INDEX = 8

-- `WOW_PROJECT_ID` values whose clients key by specialization, compared
-- as literals as ClientKit does (a missing `WOW_PROJECT_*` constant would
-- otherwise match `nil`): 1 is Retail, 19 is Mists of Pandaria Classic.
-- Every other client, and a host without the constant, keys by talent
-- group, which every client answers.
local SPECIALIZATION_PROJECTS = { [1] = true, [19] = true }

local KIND_SPECIALIZATION = "specialization"
local KIND_TALENT_GROUP = "talentGroup"

-- The events after which the index may have changed. `PLAYER_ENTERING_WORLD`
-- catches up when the client had no specialization data yet at `Open`;
-- `PLAYER_LEVEL_CHANGED` covers Retail's starter specialization becoming a
-- real one. All four are documented on Retail, Mists of Pandaria Classic
-- and Classic Era.
local PLAIN_EVENTS =
  { "PLAYER_ENTERING_WORLD", "ACTIVE_TALENT_GROUP_CHANGED", "PLAYER_LEVEL_CHANGED" }
local UNIT_EVENT = "PLAYER_SPECIALIZATION_CHANGED"

-- The EventKit revision whose unit events are a part (`EventKit-Units`).
local FIRST_EVENTKIT_WITH_UNITS_PART = 23

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
local Database = type(SettingsKit) == "table" and rawget(SettingsKit, "Database") or nil
if
  type(state) ~= "table"
  or type(rawget(state, "parts")) ~= "table"
  or type(rawget(state, "helpers")) ~= "table"
  or type(rawget(state, "dispatch")) ~= "table"
  or type(rawget(rawget(state, "helpers"), "refuseReadOnly")) ~= "function"
  or type(Database) ~= "table"
then
  error(
    "MoltenCodes SettingsKit part SpecProfiles requires SettingsKit API 1 to be loaded first",
    2
  )
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
local databases = rawget(state, "databases")
-- Read at call time, never copied: an upgraded core's helpers serve this part.
local helpers = rawget(state, "helpers")

-- Client ---------------------------------------------------------------------

---A client answer usable as a spec index or count: a non-secret whole
---number of at least `minimum`, else `nil`.
---@param value any
---@param minimum integer
---@return integer|nil
local function usableNumber(value, minimum)
  if helpers.isSecret(value) or not helpers.isIntegerAtLeast(value, minimum) then
    return nil
  end
  return value
end

---The class's specialization count, from the class ID `UnitClass` answers.
---@param specializationInfo table
---@return integer
local function readSpecializationCount(specializationInfo)
  local countFor = rawget(specializationInfo, "GetNumSpecializationsForClassID")
  local unitClass = helpers.readGlobal("UnitClass")
  if type(countFor) ~= "function" or type(unitClass) ~= "function" then
    return 0
  end
  local classID = usableNumber((select(3, unitClass("player"))), 1)
  if classID == nil then
    return 0
  end
  return usableNumber(countFor(classID), 0) or 0
end

---The current specialization index and the class's count.
---@param specializationInfo table
---@return integer|nil index, integer count
local function readSpecialization(specializationInfo)
  local count = readSpecializationCount(specializationInfo)
  local getSpecialization = rawget(specializationInfo, "GetSpecialization")
  if type(getSpecialization) ~= "function" then
    return nil, count
  end
  local index = usableNumber(getSpecialization(), 1)
  -- An index above the class's count is Retail's starter specialization,
  -- which no player chose and no assignment names.
  if index == nil or index > count then
    return nil, count
  end
  return index, count
end

---The active talent group and the number of groups the character has.
---@param specializationInfo table
---@return integer|nil index, integer count
local function readTalentGroup(specializationInfo)
  local getActiveSpecGroup = rawget(specializationInfo, "GetActiveSpecGroup")
  if type(getActiveSpecGroup) ~= "function" then
    return nil, 0
  end
  local index = usableNumber(getActiveSpecGroup(), 1)
  -- `GetNumTalentGroups` is not in the generated documentation; Blizzard's
  -- Classic talent frame calls it. Without it, the active group is the
  -- only one known.
  local count = nil
  local getNumTalentGroups = helpers.readGlobal("GetNumTalentGroups")
  if type(getNumTalentGroups) == "function" then
    count = usableNumber(getNumTalentGroups(), 0)
  end
  count = count or index or 0
  if index == nil or index > MAX_SPEC_INDEX then
    return nil, count
  end
  if count < index then
    count = index
  end
  return index, count
end

---Which kind of index this client keys by.
---@return "specialization"|"talentGroup"
local function readKind()
  local projectId = helpers.readGlobal("WOW_PROJECT_ID")
  if type(projectId) == "number" and SPECIALIZATION_PROJECTS[projectId] == true then
    return KIND_SPECIALIZATION
  end
  return KIND_TALENT_GROUP
end

---The current spec index, the number of indexes and their kind. The index
---is `nil` while the client has no specialization data or the player has
---no specialization.
---@return integer|nil index, integer count, "specialization"|"talentGroup" kind
local function readSpecIndex()
  local kind = readKind()
  local specializationInfo = helpers.readGlobal("C_SpecializationInfo")
  if type(specializationInfo) ~= "table" then
    return nil, 0, kind
  end
  local isInitialized = rawget(specializationInfo, "IsInitialized")
  if type(isInitialized) == "function" then
    local initialized = isInitialized()
    if helpers.isSecret(initialized) or initialized ~= true then
      return nil, 0, kind
    end
  end
  local index, count
  if kind == KIND_SPECIALIZATION then
    index, count = readSpecialization(specializationInfo)
  else
    index, count = readTalentGroup(specializationInfo)
  end
  return index, count, kind
end

---Refuse anything but a spec index an assignment may name.
---@param value any
---@param methodName string
---@param level integer stack level the failure is reported at
local function validateSpecIndex(value, methodName, level)
  if helpers.isSecret(value) then
    error(methodName .. " index must not be a secret value", level)
  end
  if not helpers.isIntegerAtLeast(value, 1) or value > MAX_SPEC_INDEX then
    error(methodName .. " index must be an integer from 1 to " .. MAX_SPEC_INDEX, level)
  end
end

-- Assignments ----------------------------------------------------------------

---This character's assignments, or `nil` when it has none (or the saved
---entry is corrupted).
---@param db table
---@return table|nil
local function readAssignments(db)
  local charKey = rawget(db, "_charKey")
  local section = rawget(rawget(db, "_raw"), "specProfiles")
  if charKey == false or type(section) ~= "table" then
    return nil
  end
  local entry = rawget(section, charKey)
  if type(entry) ~= "table" then
    return nil
  end
  return entry
end

---The profile this character assigned to `index`, or `nil`. A stored
---value that is not a usable profile name is ignored.
---@param db table
---@param index integer
---@return string|nil
local function readAssignment(db, index)
  local entry = readAssignments(db)
  if entry == nil then
    return nil
  end
  local name = rawget(entry, index)
  if not helpers.isStoredProfileName(name) then
    return nil
  end
  return name
end

---Switch `db` to the profile assigned to `index`, remembering the index
---as applied. A read-only database never switches.
---@param db table
---@param index integer|nil
---@return boolean switched
local function applyIndex(db, index)
  if index == nil or rawget(db, "_readOnly") == true then
    return false
  end
  rawset(db, "_specIndex", index)
  local name = readAssignment(db, index)
  if name == nil or name == rawget(db, "_profile") then
    return false
  end
  rawget(Database, "SetProfile")(db, name)
  return true
end

-- Listener -------------------------------------------------------------------

---The one listener every database shares, connected to the spec events.
---It calls through the dispatch table, so an upgrade replaces it.
local function specListener()
  local onSpecEvent = rawget(dispatch, "onSpecEvent")
  onSpecEvent()
end

---Whether `EventKit` can connect unit events. EventKit revision 23 moves
---`ConnectUnit` into its Units part and leaves a raising stub on the facade
---without it, so from that revision `HasPart("Units")` decides; an older
---EventKit has `ConnectUnit` in its core (its `HasPart`, from revision 20,
---knows no `"Units"`).
---@param EventKit table
---@return boolean
local function hasUnitEvents(EventKit)
  local hasPart = rawget(EventKit, "HasPart")
  if type(hasPart) == "function" and hasPart(EventKit, "Units") == true then
    return true
  end
  local revision = rawget(EventKit, "REVISION")
  return type(rawget(EventKit, "ConnectUnit")) == "function"
    and type(revision) == "number"
    and revision < FIRST_EVENTKIT_WITH_UNITS_PART
end

---Connect the shared listener the first time a database needs it, when
---EventKit is embedded. Without EventKit the addon calls
---`db:ApplySpecProfile()` itself.
local function connectSpecListener()
  if rawget(state, "specListenerConnected") == true then
    return
  end
  local findPackage = rawget(Registry, "Find")
  if type(findPackage) ~= "function" then
    return
  end
  local EventKit = findPackage(Registry, "eventKit", OPTIONAL_EVENTKIT_API)
  if type(EventKit) ~= "table" or type(rawget(EventKit, "Connect")) ~= "function" then
    return
  end
  if not hasUnitEvents(EventKit) then
    return
  end
  for index = 1, #PLAIN_EVENTS do
    EventKit:Connect(PLAIN_EVENTS[index], specListener)
  end
  EventKit:ConnectUnit(UNIT_EVENT, specListener, "player")
  rawset(state, "specListenerConnected", true)
end

---After a spec event: apply the current index to every open database whose
---character has an assignment, unless that database already applied it,
---so an event that changes nothing never undoes a manual `SetProfile`.
---A database whose character has no assignment (any more) still records
---the index: one it kept from before its last assignment was cleared
---would otherwise match the index the character comes back to, and an
---assignment made meanwhile would never apply (revision 12).
---
---The switches run profile listeners, which may open databases; adding a
---key to `databases` while `next` walks it is undefined in Lua 5.1 (a
---rehash makes the walk skip databases, or raise). So the walk only
---collects the databases to switch, into an array allocated when there is
---at least one, and the switches run afterwards over that array, each
---checked again, since an earlier switch's listener may have changed it.
---A database opened meanwhile applied its assignment at `Open`.
local function onSpecEvent()
  local index = readSpecIndex()
  if index == nil then
    return
  end
  ---@type table[]|nil
  local pending = nil
  local pendingCount = 0
  for _, db in next, databases do
    if rawget(db, "_specIndex") ~= index then
      if readAssignments(db) ~= nil then
        pending = pending or {}
        pendingCount = pendingCount + 1
        pending[pendingCount] = db
      else
        -- A field of the database, not a key of `databases`.
        rawset(db, "_specIndex", index)
      end
    end
  end
  if pending == nil then
    return
  end
  for position = 1, pendingCount do
    local db = pending[position]
    if rawget(db, "_specIndex") ~= index and readAssignments(db) ~= nil then
      applyIndex(db, index)
    end
  end
end

---Called by `Open`: a character with assignments gets the listener and
---its assignment for the current index at once.
---@param db table
local function onDatabaseOpened(db)
  if readAssignments(db) == nil then
    return
  end
  connectSpecListener()
  applyIndex(db, (readSpecIndex()))
end

-- Methods --------------------------------------------------------------------

---@param self SettingsKit
---@return integer|nil index, integer count, "specialization"|"talentGroup" kind
local function getSpecIndex(self)
  helpers.validateFacade(self, "SettingsKit:GetSpecIndex", 3)
  return readSpecIndex()
end

---Assign profile `name` to spec index `index` for this character, or
---clear the assignment with `nil`, and apply it at once when `index` is
---the current one.
---@param self SettingsKit.Database
---@param index integer
---@param name string|nil
---@return boolean recorded `false` when the character key is unavailable
local function databaseSetSpecProfile(self, index, name)
  helpers.validateDatabase(self, "SettingsKit.Database:SetSpecProfile", 3)
  helpers.refuseNamespace(self, "SettingsKit.Database:SetSpecProfile", 3)
  helpers.refuseReadOnly(self, "SettingsKit.Database:SetSpecProfile", 3)
  validateSpecIndex(index, "SettingsKit.Database:SetSpecProfile", 3)
  if type(name) ~= "nil" then
    helpers.validateProfileName(name, "SettingsKit.Database:SetSpecProfile name", 3)
  end

  local db = self --[[@as table]]
  local charKey = rawget(db, "_charKey")
  if charKey == false then
    return false
  end
  local raw = rawget(db, "_raw")
  local section = rawget(raw, "specProfiles")
  if type(section) == "nil" then
    -- A database an older revision opened has no section yet.
    section = {}
    rawset(raw, "specProfiles", section)
  elseif type(section) ~= "table" then
    error(
      "SettingsKit.Database:SetSpecProfile "
        .. rawget(db, "_name")
        .. ".specProfiles must be a table",
      2
    )
  end

  local entry = rawget(section, charKey)
  if type(name) == "nil" then
    if type(entry) == "table" then
      rawset(entry, index, nil)
      if next(entry) == nil then
        rawset(section, charKey, nil)
      end
    end
    return true
  end
  if type(entry) ~= "table" then
    -- A corrupted entry is replaced, as a corrupted profile choice is.
    entry = {}
    rawset(section, charKey, entry)
  end
  rawset(entry, index, name)

  connectSpecListener()
  local current = readSpecIndex()
  if current == index then
    applyIndex(db, index)
  end
  return true
end

---@param self SettingsKit.Database
---@param index integer
---@return string|nil name the profile assigned to `index` for this character
local function databaseGetSpecProfile(self, index)
  helpers.validateDatabase(self, "SettingsKit.Database:GetSpecProfile", 3)
  validateSpecIndex(index, "SettingsKit.Database:GetSpecProfile", 3)
  -- A namespace's profile follows its parent's assignments.
  return readAssignment(rawget(self, "_parent") or self --[[@as table]], index)
end

---Switch to the profile assigned to the current spec index, for an addon
---without EventKit or one that wants to apply it at a moment of its own.
---@param self SettingsKit.Database
---@return boolean switched
local function databaseApplySpecProfile(self)
  helpers.validateDatabase(self, "SettingsKit.Database:ApplySpecProfile", 3)
  helpers.refuseNamespace(self, "SettingsKit.Database:ApplySpecProfile", 3)
  return applyIndex(self --[[@as table]], (readSpecIndex()))
end

-- Commit ---------------------------------------------------------------------

rawset(SettingsKit, "GetSpecIndex", getSpecIndex)
rawset(Database, "SetSpecProfile", databaseSetSpecProfile)
rawset(Database, "GetSpecProfile", databaseGetSpecProfile)
rawset(Database, "ApplySpecProfile", databaseApplySpecProfile)
rawset(dispatch, "onSpecEvent", onSpecEvent)
rawset(dispatch, "onDatabaseOpened", onDatabaseOpened)

-- Revision 11 of the core added the flag; state an older revision built gets it.
if type(rawget(state, "specListenerConnected")) ~= "boolean" then
  rawset(state, "specListenerConnected", false)
end
-- Databases a core revision without spec profiles (10 or earlier) opened
-- over a saved table a newer copy wrote in an earlier session may already
-- hold assignments; the core marks that case with `specProfilesCatchUp` when
-- it upgrades, and this part applies their assignments once, as revision 12
-- did at load. A database opened while spec profiles were loaded applied its
-- assignment at `Open`; applying it again would undo a manual `SetProfile`.
if rawget(state, "specProfilesCatchUp") == true then
  rawset(state, "specProfilesCatchUp", nil)
  for _, db in next, databases do
    onDatabaseOpened(db)
  end
end
-- The members an older single-file core kept for this part are replaced now.
rawset(state, "legacySpecProfiles", nil)
rawset(parts, PART_NAME, { revision = PART_REVISION })

return SettingsKit
