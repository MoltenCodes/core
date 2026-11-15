-- MoltenCodes SettingsKit part Namespaces
--
-- `db:RegisterNamespace(name, schema)` and `db:GetNamespace(name, options?)`:
-- child databases, each with a schema of its own, over the saved variable's
-- `namespaces[name]`, in AceDB-3.0's namespace layout (the sections of the
-- scopes the child declares, keyed as the parent's are, and no `profileKeys`),
-- so data imported from AceDB keeps its shape.
--
-- A namespace is a database: its views, `OnChange`, `Getter`, `Validate`,
-- `Pairs`, `Compact`, `Resync` and profile signals work as a database's, at
-- the same speed, because it is built with the same private layout and the
-- same metatable. Its profile is its parent's: the parent's `SetProfile`,
-- `CopyProfile`, `ResetProfile`, `DeleteProfile` and `ResetDatabase` change
-- every namespace too (the core calls this part's `state.dispatch.namespaces`
-- for a database that has namespaces), and the core refuses those methods on
-- a namespace. A cascaded operation runs in three phases:
--
--   1. refusals and `OnProfileShutdown`, before anything changes (the parent's
--      listeners first, then each namespace's, in registration order);
--   2. the parent's change, then every namespace's, with no user code between;
--      namespaces nobody registered this session get the raw part of a copy,
--      reset or delete, as AceDB gives them;
--   3. the namespaces' signals, in registration order, then the parent's.
--
-- At logout the part fires each namespace's `OnDatabaseShutdown` after its
-- parent's, compacts the namespaces with the parent, then removes empty
-- profiles, empty sections and empty namespace tables inside `namespaces`.
--
-- The part needs SettingsKit's core loaded first (API 1, revision 15 or later:
-- the first with `state.parts` and `state.helpers`). It calls the core only
-- through `state.helpers`, read at call time, so an upgraded core serves it.
--
-- Contents
-- --------
--   Constants ........ identity, bounds
--   Dependencies ..... SettingsKit's core and its state
--   Registration ..... building a namespace over its saved table
--   Cascade .......... what each profile operation does to the namespaces
--   Logout ........... shutdown signals and the cleanup inside `namespaces`
--   Methods .......... RegisterNamespace, GetNamespace
--   Commit ........... members, dispatch entry and the part's revision

-- Constants ------------------------------------------------------------------

local PART_NAME = "Namespaces"
local PART_REVISION = 1
local REQUIRED_REGISTRY_API = 2
local CORE_PACKAGE, CORE_API = "settingsKit", 1

-- A namespace name is usually a module's name. 64 bytes is the profile-name
-- bound too: long enough for any module name, short enough to show.
local MAX_NAMESPACE_NAME_LENGTH = 64

local REGISTER_LABEL = "SettingsKit.Database:RegisterNamespace"
local GET_LABEL = "SettingsKit.Database:GetNamespace"

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
  or type(Database) ~= "table"
then
  error("MoltenCodes SettingsKit part Namespaces requires SettingsKit API 1 to be loaded first", 2)
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
-- Read at call time, never copied: an upgraded core's helpers serve this part.
local helpers = rawget(state, "helpers")

-- Registration ---------------------------------------------------------------

---Refuse anything but a usable namespace name, at the caller's line. The
---secret check comes before the length and content tests, which would raise.
---@param name any
---@param label string qualified public method name, used in the error
---@param level integer stack level the failure is reported at
local function validateName(name, label, level)
  if type(name) ~= "string" then
    error(label .. " name must be a non-empty string", level)
  end
  if helpers.isSecret(name) then
    error(label .. " name must not be a secret value", level)
  end
  if not name:find("%S") then
    error(label .. " name must contain a character other than whitespace", level)
  end
  if #name > MAX_NAMESPACE_NAME_LENGTH then
    error(label .. " name must be at most " .. MAX_NAMESPACE_NAME_LENGTH .. " bytes long", level)
  end
end

---Refuse a namespace receiver: namespaces do not nest.
---@param db table a validated database
---@param label string qualified public method name, used in the error
---@param level integer stack level the failure is reported at
local function refuseNamespaceReceiver(db, label, level)
  if rawget(db, "_parent") ~= nil then
    error(label .. " cannot be called on a namespace: namespaces do not nest", level)
  end
end

---The section a declared scope lives in, inside a namespace's saved table.
---@param scopeName string
---@return string
local function sectionOf(scopeName)
  return helpers.Scopes.sections[scopeName]
end

---The first declared scope's section of `raw` that is present but not a
---table, or `nil`.
---@param raw table a namespace's saved table
---@param scopes table the namespace's scope records
---@return string|nil sectionName
local function findSectionProblem(raw, scopes)
  for scopeName in next, scopes do
    local section = rawget(raw, sectionOf(scopeName))
    if type(section) ~= "nil" and type(section) ~= "table" then
      return sectionOf(scopeName)
    end
  end
  return nil
end

---Create every declared scope's missing section of `raw`, and the current
---profile's table when the namespace declares `profile`.
---@param raw table a namespace's saved table
---@param scopes table the namespace's scope records
---@param profileName string
---@return boolean created whether the profile's table was created
local function createSections(raw, scopes, profileName)
  for scopeName in next, scopes do
    if scopeName ~= "profile" and type(rawget(raw, sectionOf(scopeName))) == "nil" then
      rawset(raw, sectionOf(scopeName), {})
    end
  end
  if rawget(scopes, "profile") ~= nil then
    return helpers.ensureProfile(raw, profileName)
  end
  return false
end

---The `namespaces` section of a parent's saved table, created when missing
---and the parent is writable; `nil` when there is none to use.
---@param parent table
---@return table|nil
local function namespacesSection(parent)
  local raw = rawget(parent, "_raw")
  local section = rawget(raw, "namespaces")
  if type(section) == "table" then
    return section
  end
  if type(section) == "nil" and rawget(parent, "_readOnly") ~= true then
    section = {}
    rawset(raw, "namespaces", section)
    return section
  end
  return nil
end

---The saved table of namespace `name` of `parent`: the stored one, a new one
---stored for a writable parent, or a table of its own for a read-only parent
---with nothing stored (it reads defaults; nothing is ever written to it).
---@param parent table
---@param name string
---@return table raw, boolean stored
local function resolveSavedTable(parent, name)
  local section = namespacesSection(parent)
  local raw = section and rawget(section, name)
  if type(raw) == "table" then
    return raw, true
  end
  raw = {}
  if section ~= nil and rawget(parent, "_readOnly") ~= true then
    rawset(section, name, raw)
    return raw, true
  end
  return raw, false
end

---The registry of `parent`'s namespaces, created on the first registration:
---one table holding the namespaces in registration order (`registry[1]` to
---`registry[#registry]`) and each by its name (`registry[name]`, a string,
---so never one of the indexes).
---@param parent table
---@return table
local function registryOf(parent)
  local registry = rawget(parent, "_namespaces")
  if registry == nil then
    registry = {}
    rawset(parent, "_namespaces", registry)
  end
  return registry
end

---Build namespace `name` of `parent` over its saved table.
---@param parent table
---@param name string
---@param schema table the validated scope schemas
---@param level integer stack level the failures are reported at
---@return table child
local function buildNamespace(parent, name, schema, level)
  local parentName = rawget(parent, "_name")
  local label = parentName .. ".namespaces" .. helpers.formatKey(name)
  local section = rawget(rawget(parent, "_raw"), "namespaces")
  local stored = type(section) == "table" and rawget(section, name) or nil
  if type(stored) ~= "nil" and type(stored) ~= "table" then
    error(REGISTER_LABEL .. " " .. label .. " must be a table", level)
  end

  -- The scope keys are read now, as `Open` reads them; `char` is the parent's
  -- key, so a namespace's character data and its parent's agree.
  local keys = helpers.readScopeKeys(schema)
  keys.char = rawget(parent, "_charKey")
  local scopes = helpers.buildScopes(schema, keys, level + 1, REGISTER_LABEL)
  if type(stored) == "table" then
    local problem = findSectionProblem(stored, scopes)
    if problem ~= nil then
      error(REGISTER_LABEL .. " " .. label .. "." .. problem .. " must be a table", level)
    end
  end

  local readOnly = rawget(parent, "_readOnly") == true
  local raw = resolveSavedTable(parent, name)
  local profileName = rawget(parent, "_profile")
  local createdProfile = false
  if not readOnly then
    createdProfile = createSections(raw, scopes, profileName)
  end

  -- `Bars`, or `["two words"]` for a name that is not an identifier.
  local shownName = (helpers.formatKey(name):gsub("^%.", ""))
  local child = setmetatable({
    _layout = helpers.DATABASE_SCHEMA,
    -- Messages name the namespace; `GetSavedVariable` answers the parent's.
    _name = parentName .. " namespace " .. shownName,
    _raw = raw,
    _schemaSource = schema,
    _scopes = scopes,
    _charKey = rawget(parent, "_charKey"),
    _profile = profileName,
    _profileRoots = {},
    _readOnly = readOnly,
    _maxScannedEntries = rawget(parent, "_maxScannedEntries"),
    _generation = 0,
    _parent = parent,
    _namespaceName = name,
  }, helpers.DATABASE_METATABLE)
  if readOnly then
    -- Only a refused write reads them, to say why.
    rawset(child, "_version", rawget(parent, "_version"))
    rawset(child, "_newerVersion", rawget(parent, "_newerVersion"))
  end
  for scopeName, scope in next, scopes do
    if scopeName ~= "profile" and scope.available then
      rawset(child, scopeName, helpers.newRootView(child))
    end
  end
  helpers.publishProfileView(child)
  if createdProfile then
    helpers.noteCreatedProfile(child, profileName)
  end
  return child
end

-- Cascade --------------------------------------------------------------------
--
-- `dispatch.namespaces(db, phase, ...)`: the core calls it for a database
-- that has namespaces, at fixed points of its profile methods, and for a
-- namespace from `Resync`. Each phase below is one entry of `PHASES`.

---The namespaces nobody registered this session: the tables of `namespaces`
---with a `profiles` table, which a copy, reset or delete reaches raw.
---@param parent table
---@param registry table
---@param visit fun(profiles: table)
local function forEachUnregistered(parent, registry, visit)
  local section = rawget(rawget(parent, "_raw"), "namespaces")
  if type(section) ~= "table" then
    return
  end
  for name, data in next, section do
    -- Registered names are strings; any other key is a namespace nobody
    -- registered, whatever an index of the registry holds.
    if (type(name) ~= "string" or rawget(registry, name) == nil) and type(data) == "table" then
      local profiles = rawget(data, "profiles")
      if type(profiles) == "table" then
        visit(profiles)
      end
    end
  end
end

---Whether namespace `child` declares the profile scope.
---@param child table
---@return boolean
local function declaresProfile(child)
  return rawget(rawget(child, "_scopes"), "profile") ~= nil
end

---Fire `signalName` on every namespace of `registry`, in registration order.
---@param registry table
---@param signalName string
---@param ... any after the namespace itself
local function fireAll(registry, signalName, ...)
  local order = registry
  for index = 1, #order do
    helpers.fireProfileSignal(order[index], signalName, order[index], ...)
  end
end

---Fire `OnNewProfile` on each namespace whose profile table `created` marks.
---@param registry table
---@param created table<table, boolean>|nil
---@param name string
local function fireCreated(registry, created, name)
  if created == nil then
    return
  end
  local order = registry
  for index = 1, #order do
    local child = order[index]
    if created[child] == true then
      helpers.noteCreatedProfile(child, name)
      helpers.fireProfileSignal(child, "newProfile", child, name)
    end
  end
end

---Make a namespace's views find its saved tables again after a change.
---@param child table
local function refresh(child)
  helpers.bumpGeneration(child)
  helpers.rebindDatabase(child)
end

local PHASES = {}

---Before a copy: the copy of every namespace's `from` profile must stay
---within SchemaKit's `maxDepth`, like the parent's. Answers the refusal.
---@param parent table
---@param registry table
---@param from string
---@param maxDepth integer
---@return string|nil refusal
function PHASES.checkCopy(parent, registry, from, maxDepth)
  local refusal = nil
  local function measure(profiles, label)
    local source = rawget(profiles, from)
    if refusal == nil and type(source) == "table" and helpers.isTooDeep(source, 1, maxDepth) then
      refusal = "SettingsKit.Database:CopyProfile from nests more than "
        .. maxDepth
        .. " tables in "
        .. label
    end
  end
  local order = registry
  for index = 1, #order do
    local profiles = rawget(rawget(order[index], "_raw"), "profiles")
    if type(profiles) == "table" then
      measure(profiles, rawget(order[index], "_name"))
    end
  end
  forEachUnregistered(parent, registry, function(profiles)
    measure(profiles, rawget(parent, "_name") .. ".namespaces")
  end)
  return refusal
end

---Before a switch: every namespace hears `OnProfileShutdown`.
---@param _ table the parent
---@param registry table
---@param previous string
function PHASES.shutdown(_, registry, previous)
  fireAll(registry, "profileShutdown", previous)
end

---After the parent switched: point every namespace at the profile, then fire.
---@param _ table the parent
---@param registry table
---@param name string
---@param previous string
function PHASES.setProfile(_, registry, name, previous)
  local created = nil
  local order = registry
  for index = 1, #order do
    local child = order[index]
    rawset(child, "_profile", name)
    local createdTable = declaresProfile(child)
      and helpers.ensureProfile(rawget(child, "_raw"), name)
    helpers.publishProfileView(child)
    if createdTable then
      -- Switching to an existing profile changes no saved table, so only a
      -- created one makes the views look again, as for the parent.
      refresh(child)
      created = created or {}
      created[child] = true
    end
  end
  fireCreated(registry, created, name)
  fireAll(registry, "profileChanged", name, previous)
end

---Replace `profiles[current]` with a copy of `profiles[from]` (an empty table
---when `from` is missing, as AceDB does), keeping the target's identity.
---@param profiles table
---@param from string
---@param current string
---@return boolean created whether the target's table was created
local function copyInto(profiles, from, current)
  local target = rawget(profiles, current)
  local created = type(target) ~= "table"
  if created then
    target = {}
    rawset(profiles, current, target)
  else
    helpers.wipe(target)
  end
  local source = rawget(profiles, from)
  if type(source) == "table" then
    for key, value in next, source do
      rawset(target, key, helpers.copyPlain(value))
    end
  end
  return created
end

---After the parent copied `from` onto `current`: every namespace does too.
---@param parent table
---@param registry table
---@param from string
---@param current string
function PHASES.copyProfile(parent, registry, from, current)
  local created = nil
  local order = registry
  for index = 1, #order do
    local child = order[index]
    local raw = rawget(child, "_raw")
    if declaresProfile(child) then
      helpers.ensureProfile(raw, current)
    end
    local profiles = rawget(raw, "profiles")
    if
      type(profiles) == "table"
      and copyInto(profiles, from, current)
      and declaresProfile(child)
    then
      created = created or {}
      created[child] = true
    end
    refresh(child)
  end
  forEachUnregistered(parent, registry, function(profiles)
    copyInto(profiles, from, current)
  end)
  fireCreated(registry, created, current)
  fireAll(registry, "profileCopied", from, current)
end

---After the parent emptied `current`: every namespace's `current` is emptied;
---a namespace nobody registered loses it, as AceDB does.
---@param parent table
---@param registry table
---@param current string
function PHASES.resetProfile(parent, registry, current)
  local created = nil
  local order = registry
  for index = 1, #order do
    local child = order[index]
    local raw = rawget(child, "_raw")
    if declaresProfile(child) and helpers.ensureProfile(raw, current) then
      created = created or {}
      created[child] = true
    end
    local profiles = rawget(raw, "profiles")
    local profile = type(profiles) == "table" and rawget(profiles, current) or nil
    if type(profile) == "table" then
      helpers.wipe(profile)
    end
    refresh(child)
  end
  forEachUnregistered(parent, registry, function(profiles)
    rawset(profiles, current, nil)
  end)
  fireCreated(registry, created, current)
  fireAll(registry, "profileReset", current)
end

---After the parent deleted `name`: every namespace's `name` goes, and the
---namespaces' views of it are detached.
---@param parent table
---@param registry table
---@param name string
function PHASES.deleteProfile(parent, registry, name)
  local order = registry
  for index = 1, #order do
    local child = order[index]
    local profiles = rawget(rawget(child, "_raw"), "profiles")
    if type(profiles) == "table" then
      rawset(profiles, name, nil)
    end
    helpers.bumpGeneration(child)
    helpers.detachProfileView(child, name)
    helpers.rebindDatabase(child)
  end
  forEachUnregistered(parent, registry, function(profiles)
    rawset(profiles, name, nil)
  end)
  fireAll(registry, "profileDeleted", name)
end

---After the parent wiped its saved variable: every namespace gets a new saved
---table in the new `namespaces` section, its profile views are detached and
---`child.profile` is a new view, as the parent's are.
---@param parent table
---@param registry table
---@param name string the profile the parent switched to
---@param previous string
function PHASES.resetDatabase(parent, registry, name, previous)
  local order = registry
  local created = {}
  for index = 1, #order do
    local child = order[index]
    local raw = resolveSavedTable(parent, rawget(child, "_namespaceName"))
    rawset(child, "_raw", raw)
    rawset(child, "_profile", name)
    if createSections(raw, rawget(child, "_scopes"), name) then
      created[child] = true
    end
    helpers.bumpGeneration(child)
    for profileName in next, rawget(child, "_profileRoots") do
      helpers.detachProfileView(child, profileName)
    end
    helpers.publishProfileView(child)
    helpers.rebindDatabase(child)
  end
  fireAll(registry, "databaseReset")
  fireCreated(registry, created, name)
  fireAll(registry, "profileReset", name)
  if name ~= previous then
    fireAll(registry, "profileChanged", name, previous)
  end
end

---The parent's `Compact`: every namespace is compacted too. Answers the
---number of values removed.
---@param _ table the parent
---@param registry table
---@return integer removed
function PHASES.compact(_, registry)
  local removed = 0
  local order = registry
  for index = 1, #order do
    removed = removed + helpers.compactDatabase(order[index])
  end
  return removed
end

---Find a namespace's saved table again (after a direct edit), and rebind.
---@param parent table
---@param child table
local function resync(parent, child)
  rawset(child, "_raw", (resolveSavedTable(parent, rawget(child, "_namespaceName"))))
  refresh(child)
end

---The parent's `Resync`: every namespace finds its saved table again.
---@param parent table
---@param registry table
function PHASES.resync(parent, registry)
  for index = 1, #registry do
    resync(parent, registry[index])
  end
end

-- Logout ---------------------------------------------------------------------

---At logout, after the parent's `OnDatabaseShutdown`: each namespace's, in
---registration order. A raising listener is reported and the next one runs.
---@param _ table the parent
---@param registry table
function PHASES.shutdownDatabase(_, registry)
  local order = registry
  for index = 1, #order do
    local child = order[index]
    local fired, failure = pcall(helpers.fireProfileSignal, child, "databaseShutdown", child)
    if not fired then
      helpers.reportError(failure)
    end
  end
end

---Remove the empty entries of a namespace's keyed sections (profiles
---included), then its empty sections. `global` is a record, not a keyed
---section, so only an empty `global` itself goes.
---@param data table one namespace's saved table
local function removeEmpty(data)
  for sectionName, section in next, data do
    if type(section) == "table" then
      if sectionName ~= "global" then
        for key, entry in next, section do
          if type(entry) == "table" and next(entry) == nil then
            rawset(section, key, nil)
          end
        end
      end
      if next(section) == nil then
        rawset(data, sectionName, nil)
      end
    end
  end
end

---At logout, after compaction: AceDB-3.0's cleanup inside `namespaces` only,
---so a namespace that holds nothing but defaults saves nothing. The parent's
---own layout stays as `Open` made it.
---@param parent table
function PHASES.logout(parent)
  local section = rawget(rawget(parent, "_raw"), "namespaces")
  if type(section) ~= "table" then
    return
  end
  for name, data in next, section do
    if type(data) == "table" then
      removeEmpty(data)
      if next(data) == nil then
        rawset(section, name, nil)
      end
    end
  end
end

---The one entry the core calls (`state.dispatch.namespaces`).
---@param db table a database with namespaces, or a namespace
---@param phase string
---@param ... any
---@return any
local function onPhase(db, phase, ...)
  local parent = rawget(db, "_parent")
  if parent ~= nil then
    -- A namespace's own `Resync`; nothing else reaches here for one.
    if phase == "resync" then
      resync(parent, db)
    end
    return nil
  end
  local handler = PHASES[phase]
  local registry = rawget(db, "_namespaces")
  if handler == nil or registry == nil then
    return nil
  end
  return handler(db, registry, ...)
end

-- Methods --------------------------------------------------------------------

---Register namespace `name` of this database with its own scope schemas, or
---return the one registered with the same schema table.
---@param self SettingsKit.Database
---@param name string
---@param schema SettingsKit.Schema
---@return SettingsKit.Database namespace
local function registerNamespace(self, name, schema)
  helpers.validateDatabase(self, REGISTER_LABEL, 3)
  local db = self --[[@as table]]
  refuseNamespaceReceiver(db, REGISTER_LABEL, 3)
  validateName(name, REGISTER_LABEL, 3)

  local registry = rawget(db, "_namespaces")
  local existing = registry and rawget(registry, name)
  if existing ~= nil then
    -- A secret is never a table, so the type test keeps it from the
    -- identity comparison.
    if type(schema) ~= "table" or schema ~= rawget(existing, "_schemaSource") then
      error(
        REGISTER_LABEL
          .. " "
          .. rawget(existing, "_name")
          .. " is already registered with a different schema table",
        2
      )
    end
    return existing
  end

  helpers.validateSchemaTable(schema, 3, REGISTER_LABEL)
  local count = registry and #registry or 0
  local bound = rawget(db, "_maxNamespaces") or helpers.DEFAULT_MAX_NAMESPACES
  if count >= bound then
    error(
      REGISTER_LABEL
        .. " cannot register more than "
        .. bound
        .. " namespaces in "
        .. rawget(db, "_name")
        .. "; raise options.maxNamespaces in SettingsKit:Open",
      2
    )
  end

  local child = buildNamespace(db, name, schema, 3)
  registry = registryOf(db)
  registry[count + 1] = child
  registry[name] = child
  return child --[[@as SettingsKit.Database]]
end

---Return registered namespace `name`; a name nobody registered raises, or
---answers `nil` with `{ missingOk = true }`.
---@param self SettingsKit.Database
---@param name string
---@param options { missingOk: boolean? }?
---@return SettingsKit.Database|nil namespace
local function getNamespace(self, name, options)
  helpers.validateDatabase(self, GET_LABEL, 3)
  local db = self --[[@as table]]
  refuseNamespaceReceiver(db, GET_LABEL, 3)
  validateName(name, GET_LABEL, 3)
  local missingOk = helpers.readMissingOk(options, GET_LABEL, 3)
  local registry = rawget(db, "_namespaces")
  local child = registry and rawget(registry, name)
  if child == nil then
    if missingOk then
      return nil
    end
    error(GET_LABEL .. " name names no registered namespace", 2)
  end
  return child
end

-- Commit ---------------------------------------------------------------------

rawset(Database, "RegisterNamespace", registerNamespace)
rawset(Database, "GetNamespace", getNamespace)
rawset(dispatch, "namespaces", onPhase)
rawset(parts, PART_NAME, { revision = PART_REVISION })

return SettingsKit
