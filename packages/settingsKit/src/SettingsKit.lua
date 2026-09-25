-- MoltenCodes SettingsKit
--
-- Saved variables done once. `SettingsKit:Open(savedVariable, schema, options)`
-- opens a database over the addon's `## SavedVariables` table and hands back
-- live scope views: `db.global`, `db.char`, `db.realm`, `db.class`,
-- `db.faction` and `db.profile`.
--
--   reads      fall back to the schema's defaults, including wildcard defaults
--              for keyed sections, without writing them into the saved table;
--   writes     are checked against the field's SchemaKit schema at the
--              writer's line, refuse secret values, then fire `OnChange`;
--   profiles   one current profile per character, with copy, reset, delete
--              and change signals;
--   versions   `options.migrations` run once each, in ascending order, from
--              the stored version to `options.version`, each on a copy of
--              the saved table that replaces it only when the step returns;
--              data a newer version saved opens read-only unless the addon
--              passes `allowNewerData`;
--   Compact    removes every value still equal to its default, on demand and
--              on `PLAYER_LOGOUT` when EventKit is embedded.
--
-- SettingsKit requires Registry API 2, SchemaKit API 1 and SignalKit API 1.
-- EventKit API 1 is optional: it is found through `Registry:Find` when a
-- database is opened, and without it `db:Compact()` is the addon's to call.
--
-- Contents
-- --------
--   Constants ............. identity, bounds, scope names, method lists
--   Public types .......... LuaCATS declarations for the published surface
--   Dependencies .......... Registry, SchemaKit, SignalKit, host readers
--   Validation ............ public-surface and shared-state predicates
--   Bootstrap ............. Registry registration and inherited state
--   Host facilities ....... the secret-value probe and the error sink
--   Argument checks ....... receivers, names, schema and option tables
--   Plain tables .......... copy, compare, wipe, count, secret scan
--   Plans ................. what Open compiles from `schema:Describe()`
--   Views ................. the proxies behind `db.<scope>`: read and write
--   Compaction ............ removing values equal to their defaults
--   Scope keys ............ the character, realm, class and faction keys
--   Saved table ........... layout, migrations, profile selection
--   Database methods ...... the handle `Open` returns
--   Package public API .... the facade published through Registry
--   Upgrades .............. repairs of state an older revision built
--   Commit ................ prototype/facade assignment and self-check
--
-- Layout and invariants are described in `docs/INTERNALS.md`.

-- Constants ------------------------------------------------------------------

local PACKAGE_NAME = "settingsKit"
local API_GENERATION = 1
local IMPLEMENTATION_REVISION = 6
local REQUIRED_REGISTRY_API = 2
local REQUIRED_SCHEMAKIT_API = 1
local REQUIRED_SIGNALKIT_API = 1
local OPTIONAL_EVENTKIT_API = 1
local STATE_SCHEMA = 1

-- Every database, view node and plan carries the layout it was built with, so
-- a later revision that changes a layout can upgrade old objects instead of
-- guessing from which fields exist. Database layout 2 (revision 5) added
-- `_readOnly` and `_newerVersion`; layout 3 (revision 6) dropped
-- `_unavailable`, whose messages are now built when a missing scope is read.
-- Node layout 2 (revision 6) added what the read and write fast paths use
-- (`depth`, `pathKeys`, `kinds`, `ownEntries`, `valuesProxied`, `verified`)
-- and kept each node to at most 16 fields: `db`, `scope`, `dead` and
-- `sectionKey` only on a scope root, no `displayPath`, `sectionName` or
-- `probeSet`, and a keyed section's entry cache in `children`. Plan layout 2
-- (revision 6) added `ownKinds`, `fastChecks` and `defaultKind`.
local DATABASE_SCHEMA = 3
local NODE_SCHEMA = 2
local PLAN_SCHEMA = 2

-- The profile every character shares unless the addon asks otherwise.
local DEFAULT_PROFILE_NAME = "Default"

-- The `defaultProfile` value that means "one profile per character".
local CHARACTER_PROFILE = "char"

-- Profile names are shown in option screens and typed by players; 64 bytes is
-- generous for a name and small enough for a dropdown. It is the default of
-- the shared `maxProfileNameLength` limit.
local MAX_PROFILE_NAME_LENGTH = 64

-- A string key shown in a path is cut to this many bytes by default, as
-- SchemaKit cuts the keys in its failure paths. Keyed-section keys can come
-- from other players, and a path must stay short and printable. It is the
-- default of the shared `pathKeyLimit` limit.
local DEFAULT_PATH_KEY_LIMIT = 32

-- A table written into a scope is scanned for secret values before it is
-- stored. The scan is bounded so a hostile or cyclic table cannot stall the
-- writer: more entries than this and the write is refused. It is the default
-- of the per-database `maxScannedEntries` option.
local DEFAULT_MAX_SCANNED_ENTRIES = 65536

-- The shared limits `SetLimits` changes, in the order they are documented,
-- with the range each accepts. Neither accepts `SettingsKit.UNBOUNDED`: both
-- bound text the client renders, not the consumer's own data.
local LIMIT_NAMES = { "maxProfileNameLength", "pathKeyLimit" }
local LIMIT_MINIMUMS = {
  -- A character profile is named "Name - Realm"; a smaller bound could
  -- refuse the profile `defaultProfile = "char"` creates.
  maxProfileNameLength = MAX_PROFILE_NAME_LENGTH,
  pathKeyLimit = 1,
}
local LIMIT_CEILINGS = {
  maxProfileNameLength = 1024,
  pathKeyLimit = 1024,
}
local UNBOUNDED_REFUSALS = {
  maxProfileNameLength = "profile names are typed by players and shown in option screens and dropdowns",
  pathKeyLimit = "paths show keys other players can send, and every message must stay short and printable",
}

-- The scopes a schema may declare, in the order they are documented.
local SCOPE_NAMES = { "global", "char", "realm", "class", "faction", "profile" }

-- The section of the saved table each scope lives in.
local SCOPE_SECTIONS = {
  global = "global",
  char = "char",
  realm = "realm",
  class = "class",
  faction = "faction",
  profile = "profiles",
}

-- The scope names as a set, for refusing an unknown one without allocating.
local SCOPE_SET =
  { global = true, char = true, realm = true, class = true, faction = true, profile = true }

-- Every section of the saved table, created at Open when missing.
-- `namespaces` is reserved for API 1's second version (module namespaces).
local LAYOUT_SECTIONS =
  { "global", "profiles", "profileKeys", "char", "realm", "class", "faction", "namespaces" }

-- The complete set of fields an options table accepts.
local OPTION_KEYS = {
  defaultProfile = true,
  version = true,
  migrations = true,
  maxScannedEntries = true,
  allowNewerData = true,
}

-- The two kinds of view: a record (a SchemaKit `table`) and a keyed section
-- (a SchemaKit `map`).
local KIND_RECORD = "record"
local KIND_MAP = "map"

local FACADE_METHODS = { "Open", "SetLimits", "GetLimits" }
local DATABASE_METHODS = {
  "GetProfile",
  "SetProfile",
  "GetProfiles",
  "CopyProfile",
  "ResetProfile",
  "DeleteProfile",
  "ResetDatabase",
  "OnChange",
  "OnProfileChanged",
  "OnProfileCopied",
  "OnProfileReset",
  "OnProfileDeleted",
  "Compact",
  "GetSavedVariable",
  "Pairs",
  "Validate",
  "IsReadOnly",
}

-- How a record view answers a read of one declared field, decided once per
-- view from its plan and defaults (`kinds`) so a read tests no default's type.
-- The first three are plain values, the last two are record or keyed-section
-- fields that read through a child view.
local READ_DEFAULT = 1 -- the default value, which is not a table
local READ_COPY = 2 -- a copy of a plain-table default, stored on first read
local READ_NIL = 3 -- no default: `nil`
local READ_VIEW = 4 -- the child view, which has defaults to read
local READ_VIEW_OR_NIL = 5 -- the child view when something is saved, else `nil`

-- The description fields a scalar field may carry for the write fast path to
-- check it (`compileFastCheck`), by SchemaKit kind. A description with any
-- other field describes a rule this file does not know, and is always left
-- to SchemaKit.
local FAST_CHECK_FIELDS = {
  string = {
    kind = true,
    optional = true,
    default = true,
    min = true,
    max = true,
    pattern = true,
    oneOf = true,
  },
  number = { kind = true, optional = true, default = true, min = true, max = true, integer = true },
  boolean = { kind = true, optional = true, default = true },
  enum = { kind = true, optional = true, default = true, values = true },
}

-- The `probeKey` of a view whose probe table holds nothing: a table no caller
-- can ever write as a key, since it never leaves this file.
local NO_PROBE_KEY = {}

local WEAK_KEYS = { __mode = "k" }
local WEAK_VALUES = { __mode = "v" }

-- Public types ---------------------------------------------------------------
--
-- SettingsKit publishes its methods by writing them onto a Registry-owned
-- prototype table, so the editor-facing contract is declared here as LuaCATS
-- classes rather than inferred from those assignments.

---A scope name: `"global"`, `"char"`, `"realm"`, `"class"`, `"faction"` or `"profile"`.
---@alias SettingsKit.ScopeName "global"|"char"|"realm"|"class"|"faction"|"profile"

---The per-scope schemas `Open` accepts. Each is a SchemaKit `table` node or
---sealed schema whose fields are all `optional`.
---@class SettingsKit.Schema
---@field global (SchemaKit.Node|SchemaKit.Schema)?
---@field char (SchemaKit.Node|SchemaKit.Schema)?
---@field realm (SchemaKit.Node|SchemaKit.Schema)?
---@field class (SchemaKit.Node|SchemaKit.Schema)?
---@field faction (SchemaKit.Node|SchemaKit.Schema)?
---@field profile (SchemaKit.Node|SchemaKit.Schema)?

---One step of a saved-table migration. It receives a deep copy of the saved
---table's contents and changes that copy in place; its return value is
---ignored. The copy replaces the saved table's contents only when the step
---returns, so a step that raises leaves the saved table as it was. A step must
---not keep a reference to the table it was given once it returns.
---@alias SettingsKit.Migration fun(raw: table)

---Options accepted by `SettingsKit:Open`.
---@class SettingsKit.Options
---@field defaultProfile string? `"Default"` (the default), `"char"` for one profile per character, or any other profile name.
---@field version integer? The saved-table version this addon writes. Omitted: no versioning.
---@field migrations table<integer, SettingsKit.Migration>? Steps by the version they produce; requires `version`.
---@field maxScannedEntries (integer|table)? Most entries the secret-value scan of one written table visits: a positive integer or `SettingsKit.UNBOUNDED`; default `65536`.
---@field allowNewerData boolean? `true` opens a saved table whose stored version is newer than `version` writable; by default it opens read-only. Requires `version`.

---The limits every consumer in the session shares. `SetLimits` accepts any
---subset; `GetLimits` returns a fresh table.
---@class SettingsKit.Limits
---@field maxProfileNameLength integer Longest accepted profile name, in bytes: `64` to `1024`, default `64`.
---@field pathKeyLimit integer Bytes of a string key a message path shows before it is cut: `1` to `1024`, default `32`.

---Called after a validated write with the database, the scope name, the key
---written, the value written (`nil` for a reset to the default) and the path of
---the table that holds the key (`""` at the scope's top level).
---@alias SettingsKit.ChangeListener fun(db: SettingsKit.Database, scope: SettingsKit.ScopeName, key: any, value: any, path: string)

---Called after the current profile changed.
---@alias SettingsKit.ProfileChangedListener fun(db: SettingsKit.Database, name: string, previous: string)

---Called after another profile was copied into the current one.
---@alias SettingsKit.ProfileCopiedListener fun(db: SettingsKit.Database, from: string, name: string)

---Called after a profile was reset or deleted.
---@alias SettingsKit.ProfileListener fun(db: SettingsKit.Database, name: string)

---A database opened over one saved variable.
---@class SettingsKit.Database
---@field global table? Live view of the account-wide scope.
---@field char table? Live view of this character's scope.
---@field realm table? Live view of this realm's scope.
---@field class table? Live view of this class's scope.
---@field faction table? Live view of this faction's scope.
---@field profile table? Live view of the current profile.
---@field GetProfile fun(self: SettingsKit.Database): string
---@field SetProfile fun(self: SettingsKit.Database, name: string): boolean
---@field GetProfiles fun(self: SettingsKit.Database): string[]
---@field CopyProfile fun(self: SettingsKit.Database, from: string)
---@field ResetProfile fun(self: SettingsKit.Database)
---@field DeleteProfile fun(self: SettingsKit.Database, name: string)
---@field ResetDatabase fun(self: SettingsKit.Database)
---@field OnChange fun(self: SettingsKit.Database, scope: SettingsKit.ScopeName, callback: SettingsKit.ChangeListener): SignalKit.Connection
---@field OnProfileChanged fun(self: SettingsKit.Database, callback: SettingsKit.ProfileChangedListener): SignalKit.Connection
---@field OnProfileCopied fun(self: SettingsKit.Database, callback: SettingsKit.ProfileCopiedListener): SignalKit.Connection
---@field OnProfileReset fun(self: SettingsKit.Database, callback: SettingsKit.ProfileListener): SignalKit.Connection
---@field OnProfileDeleted fun(self: SettingsKit.Database, callback: SettingsKit.ProfileListener): SignalKit.Connection
---@field Compact fun(self: SettingsKit.Database): integer
---@field GetSavedVariable fun(self: SettingsKit.Database): string
---@field Validate fun(self: SettingsKit.Database, scope: SettingsKit.ScopeName, path: string|any[], value: any): boolean, string?
---@field Pairs fun(self: SettingsKit.Database, view: table): (fun(view: table, key: any): any, any), table, nil
---@field IsReadOnly fun(self: SettingsKit.Database): boolean

---The SettingsKit package facade published through Registry.
---@class SettingsKit
---@field API integer Public API generation.
---@field REVISION integer Compatible implementation revision.
---@field DEFAULT_PROFILE string `"Default"`, the shared profile's name.
---@field MAX_PROFILE_NAME_LENGTH integer Default longest profile name, in bytes (`64`); `GetLimits` reports the current one.
---@field UNBOUNDED table Sentinel `maxScannedEntries` accepts to lift the scan bound; one table shared by every revision.
---@field Database SettingsKit.Database Shared database prototype.
---@field Open fun(self: SettingsKit, savedVariable: string, schema: SettingsKit.Schema?, options: SettingsKit.Options?): SettingsKit.Database
---@field SetLimits fun(self: SettingsKit, limits: table)
---@field GetLimits fun(self: SettingsKit): SettingsKit.Limits

---What `Open` compiles once per scope from `schema:Describe()`. Private.
---@class SettingsKit.Plan
---@field layout integer Plan layout number (`2`); plans revision 5 compiled have none.
---@field proxied "record"|"map"|false Whether reads of this value go through a view, and which kind.
---@field fieldNames string[]|false Record: declared field names, sorted.
---@field fields table<string, SettingsKit.Plan>|false Record: the plan of each field.
---@field ownDefaults table|false Record: every field default, filled.
---@field ownKinds table<string, integer>|false Record: how each field reads with `ownDefaults` (`READ_*`).
---@field fastChecks table<string, table>|false Record: the write fast path's check of each simple scalar field.
---@field defaultKind integer How a read of the declared default answers: `READ_NIL`, `READ_COPY` or `READ_DEFAULT`.
---@field values SettingsKit.Plan|false Map: the plan of every value.
---@field max integer|false Map: the most entries it may hold.
---@field keyKind string|false Map: the SchemaKit kind of its keys, for converting a dotted path segment.
---@field default any The declared default, filled; for a map's values, the wildcard default.

-- Dependencies ---------------------------------------------------------------

-- The standard functions the read and write paths call most, read once into
-- locals: a global read is a hash lookup in the environment on every call, an
-- upvalue read is not. Lua 5.1 allows 200 locals in the main chunk, so only
-- the ones every read or write calls are localised.
local rawget = rawget
local type = type

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
  error("MoltenCodes SettingsKit requires Registry API 2 to be loaded first", 2)
end

local bootstrapPackage = rawget(Registry, "Bootstrap")
local getPackage = rawget(Registry, "Get")
if type(bootstrapPackage) ~= "function" or type(getPackage) ~= "function" then
  error("MoltenCodes SettingsKit requires a valid Registry API 2 facade", 2)
end

-- SchemaKit compiles, checks and describes every scope schema.
local SchemaKit = getPackage(Registry, "schemaKit", REQUIRED_SCHEMAKIT_API)
local SchemaPrototype = type(SchemaKit) == "table" and rawget(SchemaKit, "Schema") or nil
if
  type(SchemaKit) ~= "table"
  or rawget(SchemaKit, "API") ~= REQUIRED_SCHEMAKIT_API
  or type(rawget(SchemaKit, "Seal")) ~= "function"
  or type(rawget(SchemaKit, "MAX_DEPTH")) ~= "number"
  or type(SchemaPrototype) ~= "table"
  or type(rawget(SchemaPrototype, "Check")) ~= "function"
  or type(rawget(SchemaPrototype, "Describe")) ~= "function"
then
  error("MoltenCodes SettingsKit requires SchemaKit API 1 to be loaded first", 2)
end

-- SignalKit carries the change and profile signals.
local SignalKit = getPackage(Registry, "signalKit", REQUIRED_SIGNALKIT_API)
if
  type(SignalKit) ~= "table"
  or rawget(SignalKit, "API") ~= REQUIRED_SIGNALKIT_API
  or type(rawget(SignalKit, "New")) ~= "function"
then
  error("MoltenCodes SettingsKit requires SignalKit API 1 to be loaded first", 2)
end

---The deepest value SchemaKit follows now: its `maxDepth` limit, which
---`SchemaKit:SetLimits` may change at any time, so it is read when a check
---starts rather than once at load. Every scan, comparison and depth test in
---this file stops there, and views are built to the depth in force when the
---database is opened. A SchemaKit revision without `GetLimits` has only the
---fixed `MAX_DEPTH`. Allocates one table (`GetLimits` returns a fresh one),
---so only paths that walk tables call it.
---@return integer
local function readMaxDepth()
  local getLimits = rawget(SchemaKit, "GetLimits")
  if type(getLimits) == "function" then
    return getLimits(SchemaKit).maxDepth
  end
  return rawget(SchemaKit, "MAX_DEPTH")
end

---Read a host global without triggering a metatable, or `nil`.
---@param name string
---@return any
local function readGlobal(name)
  -- Host APIs and saved variables are reachable only through the global table.
  -- selene: allow(global_usage)
  return rawget(_G, name)
end

---Write a host global. Only `Open` calls this, to create a missing saved
---variable under the name the addon's TOC declares.
---@param name string
---@param value any
local function writeGlobal(name, value)
  -- The saved variable is the addon's own global, named by its TOC.
  -- selene: allow(global_usage)
  rawset(_G, name, value)
end

-- Validation -----------------------------------------------------------------

---Whether every name in `methodNames` is a function field of `prototype`.
---@param prototype table
---@param methodNames string[]
---@return boolean
local function hasMethods(prototype, methodNames)
  for index = 1, #methodNames do
    if type(rawget(prototype, methodNames[index])) ~= "function" then
      return false
    end
  end
  return true
end

---Whether `implementation` exposes the complete SettingsKit API 1 surface.
---@param implementation any shared package table handed back by Registry
---@return boolean
local function validatePublicSurface(implementation)
  if
    type(implementation) ~= "table"
    or rawget(implementation, "API") ~= API_GENERATION
    or type(rawget(implementation, "REVISION")) ~= "number"
    or type(rawget(implementation, "Database")) ~= "table"
    or type(rawget(implementation, "UNBOUNDED")) ~= "table"
  then
    return false
  end

  return hasMethods(implementation, FACADE_METHODS)
    and hasMethods(rawget(implementation, "Database"), DATABASE_METHODS)
end

---Whether `currentState` has the fields every API 1 revision shares.
---@param currentState any
---@return boolean
local function validateStateBase(currentState)
  return type(currentState) == "table"
    and rawget(currentState, "schema") == STATE_SCHEMA
    and type(rawget(currentState, "runtimeRevision")) == "number"
    and type(rawget(currentState, "dispatch")) == "table"
    and type(rawget(currentState, "databases")) == "table"
    and type(rawget(currentState, "views")) == "table"
    and type(rawget(currentState, "viewMetatable")) == "table"
    and type(rawget(currentState, "databaseMetatable")) == "table"
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
    and rawget(implementation, "UNBOUNDED") == rawget(currentState, "unbounded")
end

-- Bootstrap ------------------------------------------------------------------

-- `Registry:Bootstrap` owns the reconciliation every embedded package repeats:
-- look the package up, refuse to reinterpret state owned by a newer revision,
-- and register this one. What stays here is what only SettingsKit can answer.
local SettingsKit, previousRevision, selected = bootstrapPackage(Registry, {
  package = PACKAGE_NAME,
  api = API_GENERATION,
  revision = IMPLEMENTATION_REVISION,
  label = "MoltenCodes SettingsKit",
  validatePublicSurface = validatePublicSurface,
  validateState = validateCurrentState,
})

if SettingsKit == nil then
  -- An equal or newer compatible revision already owns the shared package table.
  return selected
end

local Database = rawget(SettingsKit, "Database")
local state = rawget(SettingsKit, "_state")

if previousRevision == nil then
  if Database ~= nil or state ~= nil then
    error("MoltenCodes SettingsKit package state is corrupted or incomplete", 2)
  end

  Database = {}
  state = {
    schema = STATE_SCHEMA,
    runtimeRevision = 0,
    -- Closures SettingsKit hands to other Kits (the logout listener) call
    -- through this table, so a newer revision replaces their behaviour.
    dispatch = {},
    -- Saved-variable name to its database: one database per name.
    databases = {},
    -- View proxy to its private node. Weak-keyed, and no node refers to
    -- its own proxy, so a view nobody holds can be collected.
    views = setmetatable({}, WEAK_KEYS),
    viewMetatable = {},
    databaseMetatable = {},
    -- `SettingsKit.UNBOUNDED` lives here so every revision publishes the
    -- same table and an option written against one copy keeps its meaning
    -- after an upgrade.
    unbounded = {},
    -- The shared limits; `SetLimits` writes here, so a newer revision
    -- inherits what a consumer set.
    limits = {
      maxProfileNameLength = MAX_PROFILE_NAME_LENGTH,
      pathKeyLimit = DEFAULT_PATH_KEY_LIMIT,
    },
    -- Databases the one shared `PLAYER_LOGOUT` listener compacts, in the
    -- order they were opened, and whether that listener is connected.
    logoutDatabases = {},
    logoutConnected = false,
  }
  rawset(SettingsKit, "Database", Database)
  rawset(SettingsKit, "_state", state)
elseif type(Database) ~= "table" or not validateStateBase(state) then
  error("MoltenCodes SettingsKit package state is corrupted or incomplete", 2)
end

-- The metatables and the prototype are kept across upgrades, so databases and
-- views built by an older copy gain this copy's behaviour without being
-- replaced.
local VIEW_METATABLE = rawget(state, "viewMetatable")
local DATABASE_METATABLE = rawget(state, "databaseMetatable")
local dispatch = rawget(state, "dispatch")
local databases = rawget(state, "databases")
local views = rawget(state, "views")
local UNBOUNDED = rawget(state, "unbounded")
local sharedLimits = rawget(state, "limits")

-- Revision 6 added the shared logout list; state an older revision built gets
-- an empty one, and its databases keep the listeners they connected.
if type(rawget(state, "logoutDatabases")) ~= "table" then
  rawset(state, "logoutDatabases", {})
  rawset(state, "logoutConnected", false)
end

-- Host facilities ------------------------------------------------------------

---Return the host's `issecretvalue`, or `nil` on a client without secrets.
---
---Read at every call rather than once at load, as SchemaKit does, so a probe
---that appears later is used at once. It costs one `rawget`.
---@return (fun(value: any): boolean)|nil
local function readIsSecret()
  local probe = readGlobal("issecretvalue")
  if type(probe) == "function" then
    return probe
  end
  return nil
end

---Whether `value` is a secret value.
---@param value any
---@return boolean
local function isSecret(value)
  -- issecretvalue is a World of Warcraft client API reachable only through the global table.
  -- selene: allow(global_usage)
  local probe = rawget(_G, "issecretvalue")
  return type(probe) == "function" and probe(value) == true
end

---Hand a failure nobody called for (a logout compaction) to the host error
---handler.
---@param message any
local function reportError(message)
  local getErrorHandler = readGlobal("geterrorhandler")
  if type(getErrorHandler) == "function" then
    local handler = getErrorHandler()
    if type(handler) == "function" then
      handler(message)
      return
    end
  end

  -- Outside a WoW client there is no error handler to report through.
  -- Printing is what the client's own default handler does.
  print(message)
end

-- Argument checks ------------------------------------------------------------
--
-- Argument validation raises with an explicit stack level so the reported
-- position is the line that called the public method, never a line inside
-- SettingsKit. `level` is always the value `error` needs *inside the function
-- that receives it*, so every further hop towards `error` adds exactly one.

---@param db any receiver the public method was called on
---@param methodName string qualified public method name, used in the argument error
---@param level integer stack level the failure is reported at
local function validateDatabase(db, methodName, level)
  if type(db) ~= "table" or getmetatable(db) ~= DATABASE_METATABLE then
    error(methodName .. " must be called on a SettingsKit database", level)
  end
end

---Refuse a secret scope name before it indexes the scope table, which would
---raise inside SettingsKit instead of at the caller.
---@param value any
---@param methodName string qualified public method name, used in the argument error
---@param level integer stack level the failure is reported at
local function validateScopeName(value, methodName, level)
  if isSecret(value) then
    error(methodName .. " scope must not be a secret value", level)
  end
end

---@param value any
---@param methodName string qualified public method name, used in the argument error
---@param level integer stack level the failure is reported at
local function validateCallback(value, methodName, level)
  if type(value) ~= "function" then
    error(methodName .. " callback must be a function", level)
  end
end

---Refuse anything but a usable profile name. The secret check comes before
---the length and content tests, which would raise on a secret.
---@param value any
---@param label string argument description, used in the argument error
---@param level integer stack level the failure is reported at
local function validateProfileName(value, label, level)
  if type(value) ~= "string" then
    error(label .. " must be a non-empty string", level)
  end
  if isSecret(value) then
    error(label .. " must not be a secret value", level)
  end
  if not value:find("%S") then
    error(label .. " must contain a character other than whitespace", level)
  end
  local maxLength = rawget(sharedLimits, "maxProfileNameLength")
  if #value > maxLength then
    error(label .. " must be at most " .. maxLength .. " bytes long", level)
  end
end

---@param value any
---@param level integer stack level the failure is reported at
local function validateSavedVariableName(value, level)
  if type(value) ~= "string" then
    error("SettingsKit:Open savedVariable must be the name of a saved variable", level)
  end
  if isSecret(value) then
    error("SettingsKit:Open savedVariable must not be a secret value", level)
  end
  if not value:find("^[%a_][%w_]*$") then
    error("SettingsKit:Open savedVariable must be the name of a saved variable", level)
  end
end

---Whether `value` is a whole number at least `minimum`.
---@param value any
---@param minimum integer
---@return boolean
local function isIntegerAtLeast(value, minimum)
  return type(value) == "number"
    and value == value
    and value >= minimum
    and value % 1 == 0
    and value < math.huge
end

---Report the alphabetically first key of `options` that is not in `known`,
---without allocating a sorted copy. A secret key is never a known one and is
---named `<secret>`: it is not used to index `known`, which would raise.
---@param options table
---@param known table<string, boolean>
---@return string|nil
local function firstUnknownKey(options, known)
  local firstUnknown = nil
  for key in next, options do
    if isSecret(key) or known[key] ~= true then
      local text = "<secret>"
      if not isSecret(key) then
        text = type(key) == "string" and key or ("<" .. type(key) .. ">")
      end
      if firstUnknown == nil or text < firstUnknown then
        firstUnknown = text
      end
    end
  end
  return firstUnknown
end

---Validate `maxScannedEntries` and return the budget the scan counts down:
---the integer itself, or `math.huge` for `SettingsKit.UNBOUNDED`, so the scan
---compares numbers and never tests for the sentinel. A secret is refused
---before any comparison, since comparing it with a number would raise.
---@param value any
---@param level integer stack level the failure is reported at
---@return number budget
local function readMaxScannedEntries(value, level)
  if type(value) == "nil" then
    return DEFAULT_MAX_SCANNED_ENTRIES
  end
  if isSecret(value) then
    error("SettingsKit:Open options.maxScannedEntries must not be a secret value", level)
  end
  if value == UNBOUNDED then
    return math.huge
  end
  if not isIntegerAtLeast(value, 1) then
    error(
      "SettingsKit:Open options.maxScannedEntries must be a positive integer or SettingsKit.UNBOUNDED",
      level
    )
  end
  return value
end

---Validate `allowNewerData`. A secret is refused before it is tested, since
---testing a secret for truth raises.
---@param value any
---@param version any the validated `options.version`, `nil` when absent
---@param level integer stack level the failure is reported at
---@return boolean allowNewerData
local function readAllowNewerData(value, version, level)
  if type(value) == "nil" then
    return false
  end
  if isSecret(value) then
    error("SettingsKit:Open options.allowNewerData must not be a secret value", level)
  end
  if type(value) ~= "boolean" then
    error("SettingsKit:Open options.allowNewerData must be a boolean", level)
  end
  -- Without a version there is nothing to be newer than, so the option could
  -- only be a mistake.
  if type(version) == "nil" then
    error("SettingsKit:Open options.allowNewerData requires options.version", level)
  end
  return value
end

---Validate `Open`'s options and return what the database keeps of them.
---@param options any
---@param level integer stack level the failures are reported at
---@return string defaultProfile, integer|false version, table|false migrations, number maxScannedEntries, boolean allowNewerData
local function readOptions(options, level)
  if type(options) == "nil" then
    return DEFAULT_PROFILE_NAME, false, false, DEFAULT_MAX_SCANNED_ENTRIES, false
  end
  if type(options) ~= "table" then
    error("SettingsKit:Open options must be a table", level)
  end

  local unknown = firstUnknownKey(options, OPTION_KEYS)
  if unknown ~= nil then
    error('SettingsKit:Open options contains unknown field "' .. unknown .. '"', level)
  end

  local defaultProfile = rawget(options, "defaultProfile")
  if type(defaultProfile) == "nil" then
    defaultProfile = DEFAULT_PROFILE_NAME
  else
    validateProfileName(defaultProfile, "SettingsKit:Open options.defaultProfile", level + 1)
  end

  local version = rawget(options, "version")
  if isSecret(version) then
    error("SettingsKit:Open options.version must not be a secret value", level)
  end
  if type(version) ~= "nil" and not isIntegerAtLeast(version, 1) then
    error("SettingsKit:Open options.version must be a positive integer", level)
  end

  local migrations = rawget(options, "migrations")
  if type(migrations) ~= "nil" then
    if type(migrations) ~= "table" then
      error("SettingsKit:Open options.migrations must be a table", level)
    end
    if type(version) == "nil" then
      error("SettingsKit:Open options.migrations requires options.version", level)
    end
    for step, migration in next, migrations do
      if isSecret(step) then
        error("SettingsKit:Open options.migrations must not have a secret key", level)
      end
      if not isIntegerAtLeast(step, 1) or step > version then
        error(
          "SettingsKit:Open options.migrations keys must be integers from 1 to options.version",
          level
        )
      end
      if type(migration) ~= "function" then
        error("SettingsKit:Open options.migrations[" .. step .. "] must be a function", level)
      end
    end
  end

  local maxScannedEntries = readMaxScannedEntries(rawget(options, "maxScannedEntries"), level + 1)
  local allowNewerData = readAllowNewerData(rawget(options, "allowNewerData"), version, level + 1)

  return defaultProfile, version or false, migrations or false, maxScannedEntries, allowNewerData
end

---Validate `Open`'s schema argument: a table of SchemaKit nodes or schemas
---keyed by scope name, with at least one scope.
---@param schema any
---@param level integer stack level the failures are reported at
local function validateSchemaTable(schema, level)
  if type(schema) ~= "table" then
    error("SettingsKit:Open schema must be a table of scope schemas", level)
  end

  local unknown = firstUnknownKey(schema, SCOPE_SET)
  if unknown ~= nil then
    error('SettingsKit:Open schema contains unknown scope "' .. unknown .. '"', level)
  end

  local declared = 0
  for index = 1, #SCOPE_NAMES do
    local scopeName = SCOPE_NAMES[index]
    local node = rawget(schema, scopeName)
    if type(node) ~= "nil" then
      local name = type(node) == "table" and getmetatable(node) or nil
      if name ~= "SchemaKit.Node" and name ~= "SchemaKit.Schema" then
        error(
          "SettingsKit:Open schema."
            .. scopeName
            .. " must be a SchemaKit schema node or sealed schema",
          level
        )
      end
      declared = declared + 1
    end
  end
  if declared == 0 then
    error("SettingsKit:Open schema must declare at least one scope", level)
  end
end

-- Plain tables ---------------------------------------------------------------

---Deep-copy a table of plain data. Defaults nest at most SchemaKit's
---`maxDepth` tables (SchemaKit refuses deeper ones), and saved tables are
---copied only after `isTooDeep` has measured them, so the recursion is bounded.
---@param value any
---@return any
local function copyPlain(value)
  if type(value) ~= "table" then
    return value
  end
  local copy = {}
  for key, item in next, value do
    rawset(copy, key, copyPlain(item))
  end
  return copy
end

---Whether a saved table nests more than `maxDepth` tables, which also catches
---a table that contains itself.
---@param value table
---@param depth integer depth of `value`, counting the outermost as 1
---@param maxDepth integer SchemaKit's `maxDepth` when the check started
---@return boolean
local function isTooDeep(value, depth, maxDepth)
  if depth > maxDepth then
    return true
  end
  for _, item in next, value do
    if type(item) == "table" and isTooDeep(item, depth + 1, maxDepth) then
      return true
    end
  end
  return false
end

---Whether two plain values are equal, comparing tables by content.
---
---A secret is never equal to anything: comparing it with its own type would raise.
---@param left any
---@param right any
---@param isSecretValue (fun(value: any): boolean)|nil
---@param depth integer
---@param maxDepth integer SchemaKit's `maxDepth` when the comparison started
---@return boolean
local function deepEqual(left, right, isSecretValue, depth, maxDepth)
  if isSecretValue ~= nil and (isSecretValue(left) or isSecretValue(right)) then
    return false
  end
  if type(left) ~= "table" or type(right) ~= "table" then
    return left == right
  end
  if depth > maxDepth then
    return false
  end

  local count = 0
  for key, item in next, left do
    if not deepEqual(item, rawget(right, key), isSecretValue, depth + 1, maxDepth) then
      return false
    end
    count = count + 1
  end
  for _ in next, right do
    count = count - 1
  end
  return count == 0
end

---Remove every key of `container`, keeping its identity.
---@param container table
local function wipe(container)
  local key = next(container)
  while type(key) ~= "nil" do
    rawset(container, key, nil)
    key = next(container)
  end
end

---Deep-copy a saved table for a migration step to change.
---
---A saved table was written by the client or by an addon, so unlike the
---defaults `copyPlain` copies it may share tables between keys or contain a
---cycle, and it may nest deeper than anything SettingsKit built. The copy
---keeps that shape: every table is copied once, through `copies`, and a table
---reached twice is the same copy both times, so shared references and cycles
---survive. The walk keeps its own work list instead of recursing, so no
---nesting depth can overflow the Lua stack. Keys are used as they are; a
---saved variable keys by strings, numbers and booleans. Only `next`,
---`rawget` and `rawset` touch the tables, so no metamethod runs, and a secret
---is carried over as it is without being indexed or compared.
---@param source table
---@param isSecretValue (fun(value: any): boolean)|nil
---@return table copy
local function copySavedTable(source, isSecretValue)
  local root = {}
  local copies = { [source] = root }
  local pending = { source }
  local pendingCount = 1
  while pendingCount > 0 do
    local original = pending[pendingCount]
    pending[pendingCount] = nil
    pendingCount = pendingCount - 1
    local copy = rawget(copies, original)
    for key, item in next, original do
      if type(item) == "table" and not (isSecretValue ~= nil and isSecretValue(item)) then
        local itemCopy = rawget(copies, item)
        if itemCopy == nil then
          itemCopy = {}
          rawset(copies, item, itemCopy)
          pendingCount = pendingCount + 1
          pending[pendingCount] = item
        end
        item = itemCopy
      end
      rawset(copy, key, item)
    end
  end
  return root
end

---Move the contents of `copy`, which a migration step changed, into `raw`.
---
---The client saves the saved-variable global by identity, so `raw` keeps it:
---it is emptied and refilled rather than replaced. A table inside the copy
---that refers to the copy itself (a cycle through the root) is pointed at
---`raw` instead, so the saved table has the shape the step built. The walk
---visits every table once, with its own work list, and uses only `next`,
---`rawget` and `rawset`.
---@param raw table the saved table
---@param copy table the root the step received
---@param isSecretValue (fun(value: any): boolean)|nil
local function adoptMigrated(raw, copy, isSecretValue)
  wipe(raw)
  for key, item in next, copy do
    rawset(raw, key, item)
  end

  local visited = { [raw] = true }
  local pending = { raw }
  local pendingCount = 1
  while pendingCount > 0 do
    local container = pending[pendingCount]
    pending[pendingCount] = nil
    pendingCount = pendingCount - 1
    for key, item in next, container do
      if type(item) == "table" and not (isSecretValue ~= nil and isSecretValue(item)) then
        if item == copy then
          -- Replacing the value of an existing key is allowed during `next`.
          rawset(container, key, raw)
        elseif rawget(visited, item) == nil then
          rawset(visited, item, true)
          pendingCount = pendingCount + 1
          pending[pendingCount] = item
        end
      end
    end
  end
end

---Count the entries of `container`, stopping at `limit`.
---@param container table|nil
---@param limit integer
---@return integer
local function countEntries(container, limit)
  if container == nil then
    return 0
  end
  local count = 0
  for _ in next, container do
    count = count + 1
    if count >= limit then
      return count
    end
  end
  return count
end

---Whether a table may be stored in a saved variable: a plain table, never a
---view and never one with a metatable (the client saves neither).
---
---Asked only after the secret check, so it never touches a secret.
---@param value table
---@return "view"|"metatable"|nil problem
local function plainTableProblem(value)
  if rawget(views, value) ~= nil then
    return "view"
  end
  if type(getmetatable(value)) ~= "nil" then
    return "metatable"
  end
  return nil
end

---Scan a table about to be stored: secret keys and values (when the host has
---secrets), views and tables with a metatable anywhere inside it.
---@param value table
---@param isSecretValue (fun(value: any): boolean)|nil
---@param depth integer
---@param maxDepth integer SchemaKit's `maxDepth` when the scan started
---@param budget integer entries still allowed to be visited
---@return "secret"|"view"|"metatable"|"size"|nil problem, integer budget
local function scanValue(value, isSecretValue, depth, maxDepth, budget)
  if depth > maxDepth then
    return "size", budget
  end
  ---@type "secret"|"view"|"metatable"|"size"|nil
  local problem = plainTableProblem(value)
  if problem ~= nil then
    return problem, budget
  end
  for key, item in next, value do
    budget = budget - 1
    if budget < 0 then
      return "size", budget
    end
    if isSecretValue ~= nil and (isSecretValue(key) or isSecretValue(item)) then
      return "secret", budget
    end
    if type(item) == "table" then
      problem, budget = scanValue(item, isSecretValue, depth + 1, maxDepth, budget)
      if problem ~= nil then
        return problem, budget
      end
    end
  end
  return nil, budget
end

-- What a refused value is told, by the problem `scanValue` found.
local VALUE_REFUSALS = {
  secret = " refused a secret value: saved variables never hold secret values",
  view = " refused a SettingsKit view: assign a plain table, not a table read through db.<scope>",
  metatable = " refused a table with a metatable: saved variables cannot hold metatables",
  size = " refused a table too large or too deep to scan",
}

---Return the visible form of one byte `quoteKey` escapes.
---@param character string
---@return string
local function escapeKeyCharacter(character)
  if character == "|" then
    return "||"
  elseif character == "\\" then
    return "\\\\"
  elseif character == '"' then
    return '\\"'
  end
  return string.format("\\%03d", string.byte(character))
end

---Render a string key for a message or a path, quoted, following the rule
---SchemaKit applies to its failure paths so both Kits show a key the same
---way. `%q` is not enough: in Lua 5.1 it leaves most control bytes as they
---are, and nothing escapes `|`, which starts a World of Warcraft escape
---sequence (`|T...|t` textures, `|H...|h` links, `|c` colours) in any text
---the client renders. `|` is doubled (the client shows one literal `|`),
---`\` and `"` are escaped as in Lua, and every other control byte (0 to 31
---and 127) becomes `\ddd`. A key longer than the shared `pathKeyLimit` is
---cut, never inside a UTF-8 sequence, and marked with `...`.
---@param key string
---@return string
local function quoteKey(key)
  local shown = key
  local pathKeyLimit = rawget(sharedLimits, "pathKeyLimit")
  if #shown > pathKeyLimit then
    -- While the first byte left out is a continuation byte (0x80 to
    -- 0xBF), leave out one more, so the cut falls before a lead byte.
    local cut = pathKeyLimit
    local nextByte = string.byte(key, cut + 1)
    while cut > 0 and nextByte >= 0x80 and nextByte <= 0xBF do
      cut = cut - 1
      nextByte = string.byte(key, cut + 1)
    end
    shown = key:sub(1, cut) .. "..."
  end
  local escaped = shown:gsub('[%c\127\\"|]', escapeKeyCharacter)
  return '"' .. escaped .. '"'
end

---Format a key as a path segment: `.name` for an identifier of at most
---`pathKeyLimit` bytes, `[1]` or `["two words"]` otherwise, rendered as
---SchemaKit renders the keys of its failure paths. Never called with a secret.
---@param key any
---@return string
local function formatKey(key)
  local keyType = type(key)
  if keyType == "string" then
    if #key <= rawget(sharedLimits, "pathKeyLimit") and key:find("^[%a_][%w_]*$") then
      return "." .. key
    end
    return "[" .. quoteKey(key) .. "]"
  end
  if keyType == "number" then
    return "[" .. string.format("%.14g", key) .. "]"
  end
  if keyType == "boolean" then
    return "[" .. tostring(key) .. "]"
  end
  -- A table, function or userdata key has no stable, safe printable form.
  return "[" .. keyType .. "]"
end

---Join a path and a formatted segment, dropping the dot a relative path would
---otherwise start with.
---@param path string
---@param segment string
---@return string
local function joinRelative(path, segment)
  if path == "" and segment:sub(1, 1) == "." then
    return segment:sub(2)
  end
  return path .. segment
end

-- Plans ----------------------------------------------------------------------
--
-- `Open` describes each scope schema once and compiles the description into a
-- plan: which values are read through a view, the defaults of every record
-- (filled the way `schema:Apply` fills them), and the wildcard default of
-- every keyed section. Plans never change afterwards and are shared by every
-- view of the scope, so nothing on the read path consults SchemaKit.

---Fill `value` with the defaults `description` declares, the way
---`schema:Apply` does: a missing value takes a copy of the declared default,
---then tables are filled field by field, entry by entry.
---
---`oneOf` alternatives are not filled: which alternative applies is decided by
---a check, and plans do not check.
---@param description SchemaKit.Description
---@param value any
---@param depth integer
---@param maxDepth integer SchemaKit's `maxDepth` when the database was opened
---@return any
local function fillDefaults(description, value, depth, maxDepth)
  if type(value) == "nil" then
    if type(description.default) == "nil" then
      return nil
    end
    value = copyPlain(description.default)
  end
  if type(value) ~= "table" or depth > maxDepth then
    return value
  end

  local kind = description.kind
  if kind == "table" then
    local fieldNames = description.fieldNames or {}
    for index = 1, #fieldNames do
      local name = fieldNames[index]
      local filled =
        fillDefaults(description.fields[name], rawget(value, name), depth + 1, maxDepth)
      if type(filled) ~= "nil" then
        rawset(value, name, filled)
      end
    end
  elseif kind == "map" then
    for key, entry in next, value do
      rawset(value, key, fillDefaults(description.values, entry, depth + 1, maxDepth))
    end
  elseif kind == "array" then
    for index = 1, #value do
      rawset(value, index, fillDefaults(description.of, rawget(value, index), depth + 1, maxDepth))
    end
  end
  return value
end

---How a read of a field of plan `fieldPlan` answers when nothing usable is
---saved, given the field's default `default`: one of the `READ_*` kinds.
---
---`default` comes from the consumer's schema, so it is tested with `type`.
---@param fieldPlan SettingsKit.Plan
---@param default any
---@return integer kind
local function readKindFor(fieldPlan, default)
  local defaultType = type(default)
  if fieldPlan.proxied ~= false then
    if defaultType ~= "nil" then
      return READ_VIEW
    end
    return READ_VIEW_OR_NIL
  end
  if defaultType == "table" then
    return READ_COPY
  end
  if defaultType == "nil" then
    return READ_NIL
  end
  return READ_DEFAULT
end

---The read kind of every declared field of a record plan read with
---`defaults`. `defaults` other than a table (a keyed section declared without
---a default hands down `false`) gives every field no default.
---@param plan SettingsKit.Plan a record plan
---@param defaults any
---@return table<string, integer> kinds
local function buildReadKinds(plan, defaults)
  local kinds = {}
  local fieldNames = plan.fieldNames --[[@as string[] ]]
  local hasDefaults = type(defaults) == "table"
  for index = 1, #fieldNames do
    local name = fieldNames[index]
    local default = nil
    if hasDefaults then
      default = rawget(defaults, name)
    end
    kinds[name] = readKindFor(plan.fields[name], default)
  end
  return kinds
end

---What the plan's own declared default is, as the plain-value `READ_*` kind a
---read of it takes: `READ_NIL` (none), `READ_COPY` (a table) or
---`READ_DEFAULT`. Decided when the plan is compiled, so a keyed-section read
---of a missing entry tests no default's type.
---@param plan SettingsKit.Plan
---@return integer
local function defaultKindOf(plan)
  local defaultType = type(plan.default)
  if defaultType == "nil" then
    return READ_NIL
  end
  if defaultType == "table" then
    return READ_COPY
  end
  return READ_DEFAULT
end

---Compile the check the write fast path runs for a scalar field, or `nil`
---when the field is left to SchemaKit.
---
---The check reproduces SchemaKit's rules for a `string`, `number`, `boolean`
---or `enum` exactly as `schema:Describe()` states them. A description with any
---field `FAST_CHECK_FIELDS` does not list, or a list value this file could not
---use as a key (a secret or NaN), gets no fast check, so a rule SchemaKit adds
---later is never skipped: the write then runs SchemaKit's own check.
---@param description SchemaKit.Description
---@return table|nil check
local function compileFastCheck(description)
  local kind = description.kind
  local allowed = FAST_CHECK_FIELDS[kind]
  if allowed == nil or description.optional ~= true then
    return nil
  end
  for name in next, description do
    if allowed[name] ~= true then
      return nil
    end
  end

  ---@type table|false
  local valueSet = false
  local list = description.oneOf or description.values
  if type(list) == "table" then
    valueSet = {}
    for index = 1, #list do
      local literal = list[index]
      if isSecret(literal) or literal ~= literal then
        return nil
      end
      valueSet[literal] = true
    end
  end
  return {
    kind = kind,
    min = description.min or false,
    max = description.max or false,
    integer = description.integer == true,
    pattern = description.pattern or false,
    valueSet = valueSet,
  }
end

---Compile a description into a plan.
---
---A record read through a view must accept a table holding any subset of its
---fields, because a saved variable starts empty and fills in one write at a
---time. Every field of such a record must therefore be `optional`; a required
---one is refused here, with the path that declares it.
---@param description SchemaKit.Description
---@param depth integer depth of the value, the scope's own table being 1
---@param label string the schema path, for the refusal
---@param maxDepth integer SchemaKit's `maxDepth` when the database was opened
---@return SettingsKit.Plan|nil plan, string|nil refusal
local function compilePlan(description, depth, label, maxDepth)
  ---@type SettingsKit.Plan
  local plan = {
    layout = PLAN_SCHEMA,
    proxied = false,
    fieldNames = false,
    fields = false,
    ownDefaults = false,
    ownKinds = false,
    fastChecks = false,
    values = false,
    max = false,
    keyKind = false,
    default = fillDefaults(description, nil, depth, maxDepth),
    defaultKind = READ_NIL,
  }
  plan.defaultKind = defaultKindOf(plan)
  if depth > maxDepth then
    return plan
  end

  if description.kind == "table" then
    plan.proxied = KIND_RECORD
    plan.fieldNames = {}
    plan.fields = {}
    local fastChecks = {}
    local fieldNames = description.fieldNames or {}
    for index = 1, #fieldNames do
      local name = fieldNames[index]
      local field = description.fields[name]
      local fieldLabel = label .. "." .. name
      if field.optional ~= true then
        return nil, fieldLabel .. " must be optional: a saved variable starts empty"
      end
      local fieldPlan, refusal = compilePlan(field, depth + 1, fieldLabel, maxDepth)
      if fieldPlan == nil then
        return nil, refusal
      end
      plan.fieldNames[index] = name
      plan.fields[name] = fieldPlan
      fastChecks[name] = compileFastCheck(field)
    end
    plan.ownDefaults = fillDefaults(description, {}, depth, maxDepth)
    plan.ownKinds = buildReadKinds(plan, plan.ownDefaults)
    plan.fastChecks = fastChecks
  elseif description.kind == "map" then
    local valuesPlan, refusal = compilePlan(description.values, depth + 1, label .. "[*]", maxDepth)
    if valuesPlan == nil then
      return nil, refusal
    end
    plan.proxied = KIND_MAP
    plan.values = valuesPlan
    plan.max = description.max
    plan.keyKind = description.keys and description.keys.kind or false
  end
  return plan
end

-- What this copy compiled for a scope schema, by the schema node or sealed
-- schema `Open` was given: SettingsKit's own seal of it and its plan. A node
-- is immutable from birth (SchemaKit's contract), so both stay valid as long
-- as SchemaKit's `maxDepth` and revision are the ones they were built under;
-- another database opened with the same schema then skips `Seal`, `Describe`
-- and the compilation. Sharing the seal between SettingsKit's databases keeps
-- the promise that matters: it is never the consumer's own schema, whose
-- failure table a write could overwrite. Weak-keyed, and an entry never
-- refers to its node, so it goes when the consumer drops the schema. Kept per
-- copy rather than in package state, so a newer copy compiles its own.
local compiledScopes = setmetatable({}, WEAK_KEYS)

---Return SettingsKit's seal of scope schema `node` and its plan, compiling
---both unless they were compiled under the same limits already.
---@param node table the schema node or sealed schema `Open` received
---@param scopeName string
---@param maxDepth integer SchemaKit's `maxDepth` as `Open` read it
---@param level integer stack level the failures are reported at
---@return SchemaKit.Schema sealed, SettingsKit.Plan plan
local function compileScope(node, scopeName, maxDepth, level)
  local schemaRevision = rawget(SchemaKit, "REVISION")
  local cached = compiledScopes[node]
  if cached ~= nil and cached.maxDepth == maxDepth and cached.schemaRevision == schemaRevision then
    return cached.sealed, cached.plan
  end

  -- Sealing a sealed schema returns a new one with its own failure table,
  -- so a consumer checking with the same schema can never see its failure
  -- overwritten by a write here.
  local sealed = SchemaKit:Seal(node)
  local description = sealed:Describe()
  if description.kind ~= "table" then
    error("SettingsKit:Open schema." .. scopeName .. " must be a SchemaKit.table schema", level)
  end
  local plan, refusal = compilePlan(description, 1, "schema." .. scopeName, maxDepth)
  if plan == nil then
    error("SettingsKit:Open " .. tostring(refusal), level)
  end
  compiledScopes[node] = {
    sealed = sealed,
    plan = plan,
    maxDepth = maxDepth,
    schemaRevision = schemaRevision,
  }
  return sealed, plan
end

-- Views ----------------------------------------------------------------------
--
-- `db.profile` and the other scopes are empty proxy tables. Lua 5.1 calls
-- `__newindex` only for a key the table does not hold, so a proxy that stored
-- anything would stop seeing writes to it; the saved data therefore lives
-- behind the proxy and is found again on every access. Each proxy has a private
-- node (in `state.views`) naming its parent node and its key in the parent, so
-- the table behind it is resolved from the saved variable downwards. That keeps
-- every view valid across `ResetProfile`, `CopyProfile` and `ResetDatabase`,
-- which change the saved tables in place or replace them.
--
-- Reads and writes are the hot paths. They index SettingsKit's own tables
-- (nodes, plans, defaults, probes) directly, reach saved tables only with
-- `rawget` and `rawset`, and decide everything that depends only on the
-- schema when a plan or view is built (`kinds`, `fastChecks`, `defaultKind`),
-- so a read tests the type only of what it finds in the saved variable.

---Resolve the saved table behind `node`, or `nil` when it does not exist yet.
---
---Walks down from the saved variable: the root's section, its entry, then one
---key per nesting level below the root (`pathKeys`), stopping at anything
---missing or not a table. One `rawget` and one `type` per level, no
---allocation.
---@param node table
---@return table|nil
local function resolveContainer(node)
  local root = node.root
  if root.dead then
    return nil
  end
  local container = rawget(root.db._raw, root.scope.sectionName)
  if type(container) ~= "table" then
    return nil
  end
  local sectionKey = root.sectionKey
  if sectionKey ~= false then
    container = rawget(container, sectionKey)
    if type(container) ~= "table" then
      return nil
    end
  end
  local pathKeys = node.pathKeys
  if pathKeys == nil then
    return container
  end
  for index = 1, #pathKeys do
    container = rawget(container, pathKeys[index])
    if type(container) ~= "table" then
      return nil
    end
  end
  return container
end

---Return the table at `container[key]`, creating it, or replacing a non-table
---value in the way.
---@param container table
---@param key any
---@return table
local function descendForWrite(container, key)
  local child = rawget(container, key)
  if type(child) ~= "table" then
    child = {}
    rawset(container, key, child)
  end
  return child
end

---Resolve the saved table behind `node`, creating it and every missing table
---above it. A non-table value in the way is replaced.
---@param node table
---@return table
local function resolveForWrite(node)
  local root = node.root
  local container = descendForWrite(root.db._raw, root.scope.sectionName)
  local sectionKey = root.sectionKey
  if sectionKey ~= false then
    container = descendForWrite(container, sectionKey)
  end
  local pathKeys = node.pathKeys
  if pathKeys ~= nil then
    for index = 1, #pathKeys do
      container = descendForWrite(container, pathKeys[index])
    end
  end
  return container
end

---The defaults a view of `plan` reads when it sits at `key` below a view
---reading `parentDefaults`: the parent's default for that key, else the
---declared default of `plan` (for a keyed-section entry, the wildcard
---default), else the record's own field defaults.
---
---`parentDefaults` is `false` below a keyed section declared without a default,
---so it is tested before it is indexed; `x and rawget(x, key)` would yield
---that `false` and skip both fallbacks.
---@param parentDefaults table|false
---@param key any
---@param plan SettingsKit.Plan
---@return table|false defaults
local function viewDefaults(parentDefaults, key, plan)
  local defaults = nil
  if parentDefaults then
    defaults = rawget(parentDefaults, key)
  end
  if type(defaults) == "nil" then
    defaults = plan.default
  end
  if type(defaults) == "nil" then
    defaults = plan.ownDefaults
  end
  return defaults
end

---The read kinds of a record view of `plan` reading `defaults`: the plan's
---own `ownKinds` when every field answers the same way, which is the common
---case and allocates nothing, else a table of its own.
---@param plan SettingsKit.Plan a record plan
---@param defaults any
---@return table<string, integer> kinds
local function readKindsOf(plan, defaults)
  local ownKinds = plan.ownKinds --[[@as table]]
  if defaults == plan.ownDefaults then
    return ownKinds
  end
  local hasDefaults = type(defaults) == "table"
  local fieldNames = plan.fieldNames --[[@as string[] ]]
  for index = 1, #fieldNames do
    local name = fieldNames[index]
    local default = nil
    if hasDefaults then
      default = rawget(defaults, name)
    end
    if readKindFor(plan.fields[name], default) ~= ownKinds[name] then
      return buildReadKinds(plan, defaults)
    end
  end
  return ownKinds
end

---The own default entries a keyed-section view reads before its wildcard, or
---`false` when it has none, so a read of a missing entry skips the lookup.
---@param defaults any
---@return table|false
local function ownEntriesOf(defaults)
  if type(defaults) == "table" and type(next(defaults)) ~= "nil" then
    return defaults
  end
  return false
end

---The keys from a scope root's saved table down to the table behind a view
---at `key` below `parent`: the parent's keys (a root has none) and `key`.
---@param parent table
---@param key any
---@return any[]
local function extendPathKeys(parent, key)
  local parentKeys = parent.pathKeys
  local pathKeys = {}
  local count = 0
  if parentKeys ~= nil then
    count = #parentKeys
    for index = 1, count do
      pathKeys[index] = parentKeys[index]
    end
  end
  pathKeys[count + 1] = key
  return pathKeys
end

-- The write fast path (`checkWrite`) skips SchemaKit's check of the whole
-- probe chain, but that check also refuses any chain nested deeper than
-- SchemaKit's `maxDepth`, which `SchemaKit:SetLimits` may lower at any time
-- and `SchemaKit:GetLimits` reads only by allocating. `depthProbes[depth]`
-- holds a sealed chain of `depth` nested closed tables with one optional
-- field each, and a Kit-owned value of exactly that shape: checking it passes
-- exactly when a probe chain of `depth` tables would pass SchemaKit's depth
-- rule, and costs one small table check per level. Built once per depth and
-- session, when the first view of that depth is built; never written after.
local depthProbes = {}

---Build the depth probe of `depth` unless it exists. Depth 1 needs none: the
---smallest `maxDepth` SchemaKit accepts is 1.
---@param depth integer
local function ensureDepthProbe(depth)
  if depth < 2 or depthProbes[depth] ~= nil then
    return
  end
  local buildTable = rawget(SchemaKit, "table")
  local buildOptional = rawget(SchemaKit, "optional")
  local node = buildTable({ fields = {} })
  local value = {}
  for _ = 2, depth do
    node = buildTable({ fields = { inner = buildOptional(node) } })
    value = { inner = value }
  end
  depthProbes[depth] = { schema = SchemaKit:Seal(node), value = value }
end

---Whether a probe chain of `depth` tables is within SchemaKit's `maxDepth`
---now. `depth` is `nil` for a scope root, whose chain is one table. `false`
---when no probe of that depth was built, so the caller runs the full check
---instead.
---@param depth integer|nil
---@return boolean
local function depthAllows(depth)
  if depth == nil then
    return true
  end
  local probe = depthProbes[depth]
  if probe == nil then
    return false
  end
  return probe.schema:Check(probe.value) == true
end

local newChildView

---Put `node` behind a new proxy and build what hangs below it: every child
---view of a record, or the empty entry cache of a keyed section.
---@param node table
---@return table proxy
local function attachView(node)
  local proxy = setmetatable({}, VIEW_METATABLE)
  views[proxy] = node

  local plan = node.plan
  if node.kind == KIND_RECORD then
    local children = {}
    local fieldNames = plan.fieldNames --[[@as string[] ]]
    for index = 1, #fieldNames do
      local name = fieldNames[index]
      local field = plan.fields[name]
      if field.proxied ~= false then
        children[name] = newChildView(node, name, field)
      end
    end
    node.children = children
  else
    -- Entry views are made on first access and cached while somebody
    -- holds them.
    node.children = setmetatable({}, WEAK_VALUES)
  end
  return proxy
end

---Build the view of `plan` at `key` below the view of `parent`: a record
---field's view, or a keyed-section entry's.
---
---A node has at most 16 fields, so Lua gives it a 16-slot table rather than a
---32-slot one: what only a scope root needs (`db`, `scope`, `dead`,
---`sectionKey`) lives on the root, reached through `root`, and the message
---path is derived from `path` (`displayPathOf`).
---@param parent table
---@param key any
---@param plan SettingsKit.Plan
---@return table proxy
newChildView = function(parent, key, plan)
  local defaults = viewDefaults(parent.defaults, key, plan)
  local path = joinRelative(parent.path, formatKey(key))
  local depth = (parent.depth or 1) + 1
  local pathKeys = extendPathKeys(parent, key)
  local node
  if plan.proxied == KIND_RECORD then
    ensureDepthProbe(depth)
    node = {
      layout = NODE_SCHEMA,
      kind = KIND_RECORD,
      plan = plan,
      parent = parent,
      key = key,
      root = parent.root,
      defaults = defaults,
      path = path,
      depth = depth,
      pathKeys = pathKeys,
      verified = false,
      probe = {},
      probeKey = NO_PROBE_KEY,
      children = false,
      kinds = readKindsOf(plan, defaults),
    }
  else
    node = {
      layout = NODE_SCHEMA,
      kind = KIND_MAP,
      plan = plan,
      parent = parent,
      key = key,
      root = parent.root,
      defaults = defaults,
      path = path,
      depth = depth,
      pathKeys = pathKeys,
      verified = false,
      probe = {},
      probeKey = NO_PROBE_KEY,
      children = false,
      ownEntries = ownEntriesOf(defaults),
      valuesProxied = plan.values.proxied ~= false,
    }
  end
  return attachView(node)
end

---Build the root view of a scope over `section[sectionKey]`.
---@param db table
---@param scope table the scope record
---@param sectionKey string|false the key inside the section; `false` for `global`
---@return table proxy
local function newRootView(db, scope, sectionKey)
  local plan = scope.plan
  local node = {
    layout = NODE_SCHEMA,
    kind = KIND_RECORD,
    plan = plan,
    parent = false,
    root = false,
    defaults = plan.ownDefaults,
    path = "",
    -- Nothing is above a root, so its keys need no proving (`checkWrite`).
    verified = true,
    probe = {},
    probeKey = NO_PROBE_KEY,
    children = false,
    kinds = readKindsOf(plan, plan.ownDefaults),
    db = db,
    scope = scope,
    -- Set by `DeleteProfile` and `ResetDatabase`: the view is detached.
    dead = false,
    sectionKey = sectionKey,
  }
  node.root = node
  return attachView(node)
end

---Return the view of entry `key` of a keyed section, building it on first use.
---@param node table the map node
---@param key any
---@return table proxy
local function entryView(node, key)
  local entries = node.children
  local proxy = rawget(entries, key)
  if proxy ~= nil then
    return proxy
  end
  proxy = newChildView(node, key, node.plan.values --[[@as SettingsKit.Plan]])
  rawset(entries, key, proxy)
  return proxy
end

---Where the view of `node` is, for messages: the scope name followed by its
---`path` (`profile.frame`, `profile.auras[118]`).
---@param node table
---@return string
local function displayPathOf(node)
  local scopeName = node.root.scope.name
  local path = node.path
  if path == "" then
    return scopeName
  end
  if path:sub(1, 1) == "[" then
    return scopeName .. path
  end
  return scopeName .. "." .. path
end

---Whether storing anything below `node` would create a keyed-section entry
---that is not saved yet. Only a validated write may create one, after the key
---schema and the section's `max` were checked. An entry stored as something
---other than a table reads as absent, so it counts as not saved: a read never
---replaces it.
---@param node table
---@return boolean
local function wouldCreateEntry(node)
  local child = node
  local parent = child.parent
  while parent ~= false do
    if parent.kind == KIND_MAP then
      local container = resolveContainer(parent)
      if container == nil or type(rawget(container, child.key)) ~= "table" then
        return true
      end
    end
    child = parent
    parent = child.parent
  end
  return false
end

---Store a copy of a table-valued default and return it.
---
---A view hands out record and keyed-section defaults through child views, but
---an array (or `any`, `oneOf`, `custom`) default is a plain table the caller
---may edit in place. Handing out the shared default would let that edit change
---the default for the session, so the first read stores a copy instead;
---`Compact` removes it again while it still equals the default. Inside a
---keyed-section entry that is not saved yet, and in a read-only database, the
---copy is returned unstored, so a read never creates an entry and never
---changes data a newer version saved.
---@param node table
---@param key any
---@param default table
---@return table
local function materialise(node, key, default)
  local copy = copyPlain(default)
  local root = node.root
  if root.dead or root.db._readOnly == true or wouldCreateEntry(node) then
    return copy
  end
  local container = resolveForWrite(node)
  rawset(container, key, copy)
  return copy
end

---Raise the refusal of a read with a secret key at the reading line:
---raiseSecretRead <- viewIndex <- the reading line.
---@param node table
local function raiseSecretRead(node)
  error(
    "SettingsKit ("
      .. node.root.db._name
      .. ") "
      .. displayPathOf(node)
      .. " cannot be read with a secret key",
    3
  )
end

---Read `key` through a keyed-section view, falling back to the section's own
---default entries and then to its wildcard default. The key was asked about
---secrecy, and `container` is the resolved saved table (`nil` when absent).
---@param node table
---@param key any
---@param container table|nil
---@return any
local function readMap(node, key, container)
  -- Without this, `view[nil]` would answer with the wildcard default.
  if type(key) == "nil" then
    return nil
  end

  local valuesProxied = node.valuesProxied
  if container ~= nil then
    local value = rawget(container, key)
    local valueType = type(value)
    if valueType ~= "nil" then
      if not valuesProxied then
        return value
      end
      if valueType == "table" then
        return entryView(node, key)
      end
      -- An entry declared as a record or keyed section but stored as a
      -- scalar reads as absent, as in a record read.
    end
  end

  local ownEntries = node.ownEntries
  if ownEntries ~= false then
    local default = ownEntries[key]
    local defaultType = type(default)
    if defaultType ~= "nil" then
      if valuesProxied then
        return entryView(node, key)
      end
      if defaultType == "table" then
        -- A missing entry is never stored by a read: the key may be one
        -- the key schema refuses, and the section may be full.
        return copyPlain(default)
      end
      return default
    end
  end

  local valuesPlan = node.plan.values
  local defaultKind = valuesPlan.defaultKind
  if defaultKind == READ_NIL then
    return nil
  end
  if valuesProxied then
    return entryView(node, key)
  end
  if defaultKind == READ_COPY then
    return copyPlain(valuesPlan.default)
  end
  return valuesPlan.default
end

---The `__index` of every view: every read through a view is one call of it.
---
---The secret probe comes first: the key is compared and used to index below,
---and either raises on a secret. A keyed-section read continues in
---`readMap`; a record read, the common one, is answered here, so it costs
---this call and `resolveContainer` only. `kinds` answers everything that
---depends only on the schema: an undeclared key (`nil` there) returns what is
---saved or `nil`, a record or keyed-section field returns its child view, and
---a missing value its default.
---@param proxy table
---@param key any
---@return any
local function viewIndex(proxy, key)
  local node = views[proxy]
  if node == nil then
    return nil
  end
  -- issecretvalue is a World of Warcraft client API reachable only through the global table.
  -- selene: allow(global_usage)
  local isSecretValue = rawget(_G, "issecretvalue")
  if type(isSecretValue) == "function" and isSecretValue(key) == true then
    raiseSecretRead(node)
  end

  local container = resolveContainer(node)
  if node.kind ~= KIND_RECORD then
    return readMap(node, key, container)
  end

  local kind = node.kinds[key]
  if container ~= nil then
    local value = rawget(container, key)
    local valueType = type(value)
    if valueType ~= "nil" then
      if kind == nil or kind < READ_VIEW then
        return value
      end
      if valueType == "table" then
        return node.children[key]
      end
      -- A record or keyed section stored as something other than a table:
      -- corrupted or hand-edited data. It reads as absent, so the view
      -- below and its defaults stay usable, and the next write through that
      -- view replaces it (`resolveForWrite`).
    end
  end

  if kind == READ_DEFAULT then
    return node.defaults[key]
  elseif kind == READ_VIEW then
    return node.children[key]
  elseif kind == READ_COPY then
    return materialise(node, key, node.defaults[key])
  end
  return nil
end

---Set `key` in `node`'s probe table, clearing whatever key an earlier,
---interrupted write left there.
---@param node table
---@param key any
---@param value any
local function setProbe(node, key, value)
  local probe = node.probe
  local previousKey = node.probeKey
  if previousKey ~= NO_PROBE_KEY then
    rawset(probe, previousKey, nil)
  end
  rawset(probe, key, value)
  node.probeKey = key
end

---@param node table
local function clearProbe(node)
  local previousKey = node.probeKey
  if previousKey ~= NO_PROBE_KEY then
    rawset(node.probe, previousKey, nil)
    node.probeKey = NO_PROBE_KEY
  end
end

---Whether a value SchemaKit would check against the scalar field described
---by `check` passes, by exactly the rules SchemaKit applies to a `string`,
---`number`, `boolean` or `enum` (see `compileFastCheck`). `value` was asked
---about secrecy; `nil` passes because every field is optional.
---@param check table
---@param value any
---@param valueType string `type(value)`
---@return boolean
local function passesFastCheck(check, value, valueType)
  if valueType == "nil" then
    return true
  end
  local kind = check.kind
  if kind == "number" then
    if valueType ~= "number" or value ~= value then
      return false
    end
    if
      check.integer
      and (value == math.huge or value == -math.huge or math.floor(value) ~= value)
    then
      return false
    end
    local min, max = check.min, check.max
    return (min == false or value >= min) and (max == false or value <= max)
  elseif kind == "string" then
    if valueType ~= "string" then
      return false
    end
    local valueSet = check.valueSet
    if valueSet ~= false and valueSet[value] == nil then
      return false
    end
    local length = #value
    local min, max, pattern = check.min, check.max, check.pattern
    return (min == false or length >= min)
      and (max == false or length <= max)
      and (pattern == false or type(string.find(value, pattern)) ~= "nil")
  elseif kind == "boolean" then
    return valueType == "boolean"
  end
  return check.valueSet[value] ~= nil
end

---Check the write `node[key] = value` against the scope's schema.
---
---**Full check.** The probe is a chain of scratch tables, one per view from
---the scope root down to `node`, holding only the path to the written key and
---the value. Every field of a record read through a view is optional
---(`compilePlan` refuses otherwise), so the chain is valid exactly when the
---written value is valid where it is written. A valid check allocates nothing.
---
---**Fast path.** For a value that is not a table, written to a declared
---scalar field of a record view, the full check passes exactly when: the
---value passes the field's own rules; the chain above the view passes, which
---depends only on its keys (declared fields, and keyed-section keys the key
---schema accepts, in sections whose `max` allows one entry), none of which
---can change once a full check through the view passed (`verified`); and the
---chain is within SchemaKit's `maxDepth` (`depthAllows`). When all three
---hold, SchemaKit is not asked; otherwise it is, so every refusal and its
---message come from SchemaKit.
---@param node table
---@param key any
---@param value any
---@param valueType string `type(value)`
---@return boolean ok, SchemaKit.Failure|nil failure
local function checkWrite(node, key, value, valueType)
  if node.verified and valueType ~= "table" and node.kind == KIND_RECORD then
    local fastCheck = node.plan.fastChecks[key]
    if
      fastCheck ~= nil
      and passesFastCheck(fastCheck, value, valueType)
      and depthAllows(node.depth)
    then
      return true, nil
    end
  end

  local child = node
  local parent = child.parent
  while parent ~= false do
    setProbe(parent, child.key, child.probe)
    child = parent
    parent = child.parent
  end
  setProbe(node, key, value)

  -- `child` is the scope root now.
  local ok, failure = child.scope.schema:Check(child.probe)

  child = node
  while child ~= false do
    clearProbe(child)
    child = child.parent
  end
  if ok then
    node.verified = true
  end
  return ok, failure
end

---Return the keyed-section node the write `node[key] = value` would grow past
---its bound, or `nil`.
---@param node table
---@param key any
---@return table|nil
local function findFullMap(node, key)
  if node.kind == KIND_MAP then
    local container = resolveContainer(node)
    local max = node.plan.max
    if
      (container == nil or type(rawget(container, key)) == "nil")
      and countEntries(container, max) >= max
    then
      return node
    end
  end

  local child = node
  local parent = child.parent
  while parent ~= false do
    if parent.kind == KIND_MAP then
      local container = resolveContainer(parent)
      local max = parent.plan.max
      if
        (container == nil or type(rawget(container, child.key)) == "nil")
        and countEntries(container, max) >= max
      then
        return parent
      end
    end
    child = parent
    parent = child.parent
  end
  return nil
end

---Build the message for a failed write, in the shape `schema:Assert` uses.
---@param node table
---@param failure SchemaKit.Failure
---@return string
local function failureMessage(node, failure)
  local path = failure.path
  local root = node.root
  local where = root.scope.name
  if path ~= "" then
    if path:sub(1, 1) == "[" then
      where = where .. path
    else
      where = where .. "." .. path
    end
  end
  return "SettingsKit ("
    .. root.db._name
    .. ") "
    .. where
    .. ": expected "
    .. failure.expected
    .. ", found "
    .. failure.found
end

---The `SettingsKit (<saved variable>) ` prefix every refusal starts with.
---@param node table
---@return string
local function refusalLabel(node)
  return "SettingsKit (" .. node.root.db._name .. ") "
end

---Why a read-only database refuses writes, and how to open it writable: the
---tail of every read-only refusal. Both versions are integers `Open`
---validated, so nothing here can be secret.
---@param db table
---@return string
local function readOnlyReason(db)
  return "the saved table has version "
    .. rawget(db, "_newerVersion")
    .. ", newer than options.version "
    .. rawget(db, "_version")
    .. "; pass options.allowNewerData = true to SettingsKit:Open to write it"
end

---Return why the write `node[key] = value` would be refused, or `nil` when it
---would be accepted. Runs every check a write runs, in the same order, and
---writes nothing: the probe chain is set and cleared again. The message is
---built only for a refusal, so an accepted write allocates nothing here.
---@param node table
---@param key any
---@param value any
---@param valueType string `type(value)`
---@return string|nil refusal
local function refuseWrite(node, key, value, valueType)
  local db = node.root.db
  if db._readOnly == true then
    return refusalLabel(node) .. displayPathOf(node) .. " is read-only: " .. readOnlyReason(db)
  end
  if node.root.dead then
    return refusalLabel(node)
      .. displayPathOf(node)
      .. " belongs to a profile that was deleted or reset away"
  end

  -- issecretvalue is a World of Warcraft client API reachable only through the global table.
  -- selene: allow(global_usage)
  local isSecretValue = rawget(_G, "issecretvalue")
  if type(isSecretValue) ~= "function" then
    isSecretValue = nil
  end
  if isSecretValue ~= nil and isSecretValue(key) == true then
    return refusalLabel(node)
      .. displayPathOf(node)
      .. " refused a secret key: saved variables never hold secret values"
  end
  -- Every table is scanned, whether or not the host has secret values: a
  -- view stored in a saved table would alias another view's data and be
  -- written through without validation, and a metatable never survives a
  -- save.
  local problem = nil
  if isSecretValue ~= nil and isSecretValue(value) == true then
    problem = "secret"
  elseif valueType == "table" then
    problem = scanValue(value, isSecretValue, 1, readMaxDepth(), db._maxScannedEntries)
  end
  if problem ~= nil then
    return refusalLabel(node) .. displayPathOf(node) .. formatKey(key) .. VALUE_REFUSALS[problem]
  end

  local ok, failure = checkWrite(node, key, value, valueType)
  if not ok then
    ---@cast failure SchemaKit.Failure
    return failureMessage(node, failure)
  end

  if valueType ~= "nil" then
    local fullMap = findFullMap(node, key)
    if fullMap ~= nil then
      return refusalLabel(node)
        .. displayPathOf(fullMap)
        .. ": expected at most "
        .. fullMap.plan.max
        .. " entries"
    end
  end
  return nil
end

---Validate and store `node[key] = value`, then fire the scope's change signal
---when anybody connected to it. Every refusal is raised at the writing line:
---this function is called by `viewNewIndex`, which is called by the writer,
---so the level is 3.
---
---A nil or NaN key never gets here: Lua 5.1 refuses it while looking for the
---slot, before it consults `__newindex`.
---@param node table
---@param key any
---@param value any
local function writeView(node, key, value)
  local valueType = type(value)
  local refusal = refuseWrite(node, key, value, valueType)
  if refusal ~= nil then
    error(refusal, 3)
  end

  local container
  if valueType == "nil" then
    container = resolveContainer(node)
  else
    container = resolveForWrite(node)
  end
  if container ~= nil then
    rawset(container, key, value)
  end

  -- The signal is created by the first `OnChange` of the scope.
  local root = node.root
  local scope = root.scope
  local signal = scope.signal
  if signal ~= false then
    signal:Fire(root.db, scope.name, key, value, node.path)
  end
end

---The `__newindex` of every view.
---@param proxy table
---@param key any
---@param value any
local function viewNewIndex(proxy, key, value)
  local node = rawget(views, proxy)
  if node == nil then
    error("SettingsKit views cannot be written once detached", 2)
  end
  writeView(node, key, value)
end

---The iterator `db:Pairs(view)` returns. Stateless: everything it needs is
---the view and the previous key, so iterating allocates no closure.
---
---Phase one walks the keys that have a default (the record's field defaults,
---or a keyed section's own default entries; never the unbounded wildcard);
---phase two walks the saved keys without a default. The previous key tells
---the phases apart: a key with a default belongs to phase one. Reading a value
---in phase one may store a plain-table default (`materialise`), which only
---adds a key phase two skips, so the saved table is never changed while
---phase two walks it.
---@param proxy table
---@param previous any
---@return any key, any value
local function pairsNext(proxy, previous)
  local node = rawget(views, proxy)
  if node == nil then
    return nil
  end
  local defaults = node.defaults
  local key = nil

  local inPhaseOne = type(previous) == "nil"
    or (defaults and type(rawget(defaults, previous)) ~= "nil")
  if inPhaseOne and defaults then
    key = next(defaults, previous)
    if type(key) ~= "nil" then
      return key, viewIndex(proxy, key)
    end
    previous = nil
  elseif inPhaseOne then
    previous = nil
  end

  local container = resolveContainer(node)
  if container == nil then
    return nil
  end
  key = next(container, previous)
  while type(key) ~= "nil" and defaults and type(rawget(defaults, key)) ~= "nil" do
    key = next(container, key)
  end
  if type(key) == "nil" then
    return nil
  end
  return key, viewIndex(proxy, key)
end

-- Compaction -----------------------------------------------------------------
--
-- A value equal to its default is removed, and so is a record or keyed-section
-- table left empty that has a default to fall back to: reading it through a
-- view gives the same answer either way. A table without a default is kept
-- even when empty, because removing it would turn a view into `nil`.

local compactValue

---The recursion follows the plan, which `compilePlan` stops at the depth in
---force when the database was opened, so it needs no depth bound of its own;
---`maxDepth` bounds only the comparison of a leaf value with its default.
---@param plan SettingsKit.Plan a record plan
---@param container table
---@param defaults table|false
---@param isSecretValue (fun(value: any): boolean)|nil
---@param maxDepth integer SchemaKit's `maxDepth` when the compaction started
---@return integer removed
local function compactRecord(plan, container, defaults, isSecretValue, maxDepth)
  local removed = 0
  local fieldNames = plan.fieldNames --[[@as string[] ]]
  for index = 1, #fieldNames do
    local name = fieldNames[index]
    local value = rawget(container, name)
    if type(value) ~= "nil" then
      local default = nil
      if defaults then
        default = rawget(defaults, name)
      end
      removed = removed
        + compactValue(plan.fields[name], container, name, value, default, isSecretValue, maxDepth)
    end
  end
  return removed
end

---@param plan SettingsKit.Plan a map plan
---@param container table
---@param defaults table|false|nil
---@param isSecretValue (fun(value: any): boolean)|nil
---@param maxDepth integer SchemaKit's `maxDepth` when the compaction started
---@return integer removed
local function compactMap(plan, container, defaults, isSecretValue, maxDepth)
  local removed = 0
  local valuesPlan = plan.values --[[@as SettingsKit.Plan]]
  for key, entry in next, container do
    local default = nil
    if defaults then
      default = rawget(defaults, key)
    end
    if type(default) == "nil" then
      default = valuesPlan.default
    end
    removed = removed
      + compactValue(valuesPlan, container, key, entry, default, isSecretValue, maxDepth)
  end
  return removed
end

---Compact `container[key] = value` against `default`.
---@param plan SettingsKit.Plan
---@param container table
---@param key any
---@param value any
---@param default any
---@param isSecretValue (fun(value: any): boolean)|nil
---@param maxDepth integer SchemaKit's `maxDepth` when the compaction started
---@return integer removed
compactValue = function(plan, container, key, value, default, isSecretValue, maxDepth)
  if plan.proxied ~= false and type(value) == "table" then
    local removed
    if plan.proxied == KIND_RECORD then
      local childDefaults = default
      if type(childDefaults) == "nil" then
        childDefaults = plan.ownDefaults
      end
      removed = compactRecord(plan, value, childDefaults, isSecretValue, maxDepth)
    else
      removed = compactMap(plan, value, default, isSecretValue, maxDepth)
    end
    if type(default) ~= "nil" and type(next(value)) == "nil" then
      rawset(container, key, nil)
      removed = removed + 1
    end
    return removed
  end

  if type(default) ~= "nil" and deepEqual(value, default, isSecretValue, 1, maxDepth) then
    rawset(container, key, nil)
    return 1
  end
  return 0
end

---Compact every table of one scope's section.
---@param raw table
---@param scope table
---@param isSecretValue (fun(value: any): boolean)|nil
---@param maxDepth integer SchemaKit's `maxDepth` when the compaction started
---@return integer removed
local function compactScope(raw, scope, isSecretValue, maxDepth)
  local plan = scope.plan
  local section = rawget(raw, scope.sectionName)
  if type(section) ~= "table" then
    return 0
  end
  if scope.name == "global" then
    return compactRecord(plan, section, plan.ownDefaults, isSecretValue, maxDepth)
  end

  local removed = 0
  for sectionKey, container in next, section do
    if type(container) == "table" then
      removed = removed + compactRecord(plan, container, plan.ownDefaults, isSecretValue, maxDepth)
      -- An empty profile is still a profile; an empty character, realm,
      -- class or faction entry is just an absent one.
      if scope.name ~= "profile" and type(next(container)) == "nil" then
        rawset(section, sectionKey, nil)
      end
    end
  end
  return removed
end

---Compact every declared scope of `db`.
---@param db table
---@return integer removed
local function compactDatabase(db)
  local raw = db._raw
  local isSecretValue = readIsSecret()
  local maxDepth = readMaxDepth()
  local removed = 0
  for index = 1, #SCOPE_NAMES do
    local scope = rawget(db._scopes, SCOPE_NAMES[index])
    if scope ~= nil then
      removed = removed + compactScope(raw, scope, isSecretValue, maxDepth)
    end
  end
  return removed
end

---Compact at logout. A failure is reported, never raised into EventKit's
---dispatch, so one addon's database cannot stop another's compaction. A
---read-only database is skipped: compaction removes saved values, and the
---newer version that wrote them decides what they should be.
---@param db table
local function compactOnLogout(db)
  if rawget(db, "_readOnly") == true then
    return
  end
  local ok, failure = pcall(compactDatabase, db)
  if not ok then
    reportError(failure)
  end
end

---Compact, at logout, every database that joined the shared logout list, in
---the order they were opened, each on its own terms (`compactOnLogout`).
local function compactAllOnLogout()
  local logoutDatabases = rawget(state, "logoutDatabases")
  for index = 1, #logoutDatabases do
    compactOnLogout(logoutDatabases[index])
  end
end

---The one `PLAYER_LOGOUT` listener every database opened by revision 6 or later
---shares. It calls through the shared dispatch table, so an upgrade replaces
---its behaviour.
local function logoutListener()
  local compactAll = rawget(dispatch, "compactAllOnLogout")
  compactAll()
end

---Join the logout compaction when EventKit is embedded: add `db` to the shared
---logout list, and connect the one shared listener the first time. A
---database therefore costs EventKit no listener of its own. The connection is
---not kept: databases live for the session and are never disconnected, and
---EventKit holds the listener. Databases revisions 1 to 5 opened keep the
---listener each connected for itself and are not on the list.
---@param db table
local function connectLogout(db)
  -- Once the listener is connected, EventKit was registered, and a
  -- registered package stays registered: no need to find it again.
  if rawget(state, "logoutConnected") ~= true then
    local findPackage = rawget(Registry, "Find")
    if type(findPackage) ~= "function" then
      return
    end
    local EventKit = findPackage(Registry, "eventKit", OPTIONAL_EVENTKIT_API)
    if type(EventKit) ~= "table" or type(rawget(EventKit, "Connect")) ~= "function" then
      return
    end
    EventKit:Connect("PLAYER_LOGOUT", logoutListener)
    rawset(state, "logoutConnected", true)
  end
  local logoutDatabases = rawget(state, "logoutDatabases")
  logoutDatabases[#logoutDatabases + 1] = db
end

-- Scope keys -----------------------------------------------------------------

---Return `value` when it can key a saved table: a non-empty, non-secret string.
---@param value any
---@param isSecretValue (fun(value: any): boolean)|nil
---@return string|nil
local function usableKey(value, isSecretValue)
  if type(value) ~= "string" then
    return nil
  end
  if isSecretValue ~= nil and isSecretValue(value) then
    return nil
  end
  if value == "" then
    return nil
  end
  return value
end

---Call a host function by name with `...`, or return nothing without it.
---@param name string
---@return any ...
local function callHost(name, ...)
  local host = readGlobal(name)
  if type(host) ~= "function" then
    return nil
  end
  return host(...)
end

---Read the four scope keys once, the way `Open` resolves them.
---@return table<string, string|false> keys
local function readScopeKeys()
  local isSecretValue = readIsSecret()
  local playerName = usableKey((callHost("UnitName", "player")), isSecretValue)
  local realm = usableKey((callHost("GetRealmName")), isSecretValue)
  local class = usableKey((select(2, callHost("UnitClass", "player"))), isSecretValue)
  local faction = usableKey((callHost("UnitFactionGroup", "player")), isSecretValue)

  ---@type string|false
  local character = false
  if playerName ~= nil and realm ~= nil then
    character = playerName .. " - " .. realm
  end
  return {
    char = character,
    realm = realm or false,
    class = class or false,
    faction = faction or false,
  }
end

-- Why each scope can be unavailable, for the error a read of it raises.
local UNAVAILABLE_REASONS = {
  char = 'UnitName("player") or GetRealmName() returned no name',
  realm = "GetRealmName() returned no realm",
  class = 'UnitClass("player") returned no class',
  faction = 'UnitFactionGroup("player") returned no faction',
}

-- Saved table ----------------------------------------------------------------

---Return the first layout section of `candidate` that is present but not a
---table, or `nil` when every section is absent or a table. Asks `type` only,
---so it writes nothing and never touches a secret.
---@param candidate table the saved table, or a migrated copy of it
---@return string|nil sectionName
local function findLayoutProblem(candidate)
  for index = 1, #LAYOUT_SECTIONS do
    local sectionName = LAYOUT_SECTIONS[index]
    local section = rawget(candidate, sectionName)
    if type(section) ~= "nil" and type(section) ~= "table" then
      return sectionName
    end
  end
  return nil
end

---Refuse a saved table whose layout sections are not all tables. Called
---before `Open` writes anything but the migrations, so a refused table is
---left exactly as the client loaded it.
---@param raw table
---@param name string saved-variable name, for messages
---@param level integer stack level the failure is reported at
local function validateLayout(raw, name, level)
  local sectionName = findLayoutProblem(raw)
  if sectionName ~= nil then
    error("SettingsKit:Open " .. name .. "." .. sectionName .. " must be a table", level)
  end
end

---Create every missing section of the saved table. The layout was validated
---first, so every present section is a table.
---@param raw table
local function createLayout(raw)
  for index = 1, #LAYOUT_SECTIONS do
    local sectionName = LAYOUT_SECTIONS[index]
    if type(rawget(raw, sectionName)) == "nil" then
      rawset(raw, sectionName, {})
    end
  end
end

---Raise the failure of migration `step` at the caller of `Open`. A secret
---error value is never formatted into the message.
---@param name string saved-variable name
---@param step integer
---@param failure any
---@param level integer stack level the failure is reported at
local function raiseMigrationFailure(name, step, failure, level)
  if isSecret(failure) then
    failure = "<secret value>"
  end
  error(
    "SettingsKit:Open migration " .. step .. " of " .. name .. " failed: " .. tostring(failure),
    level
  )
end

---Run one migration step as a transaction: the step changes a deep copy of
---the saved table, and the copy's contents replace the saved table's only
---when the step returns (and, for the last step, when the result has a valid
---layout). A step that raises, or a last step that leaves a layout section
---that is not a table, leaves the saved table exactly as it was, so the retry
---at the next `Open` starts from untouched data instead of re-applying the
---writes the failed attempt made.
---@param raw table
---@param name string saved-variable name, for messages
---@param migration function
---@param isLast boolean whether this is the last step with a function
---@return boolean ok, any failure
local function runMigrationStep(raw, name, migration, isLast)
  local isSecretValue = readIsSecret()
  local copy = copySavedTable(raw, isSecretValue)
  local ok, failure = pcall(migration, copy)
  if not ok then
    return false, failure
  end
  if isLast then
    -- Steps before the last may pass through any shape (a pre-SettingsKit
    -- table can hold a field named `global`); the result the views will
    -- read must have the layout, and is refused before it is committed.
    local sectionName = findLayoutProblem(copy)
    if sectionName ~= nil then
      return false, name .. "." .. sectionName .. " must be a table"
    end
  end
  adoptMigrated(raw, copy, isSecretValue)
  return true, nil
end

---The highest step from `first` to `last` that has a migration function, or
---`false` when none has.
---@param migrations table|false
---@param first integer
---@param last integer
---@return integer|false
local function findLastMigration(migrations, first, last)
  if migrations == false then
    return false
  end
  for step = last, first, -1 do
    if type(rawget(migrations, step)) ~= "nil" then
      return step
    end
  end
  return false
end

---Run the migrations between the stored version and `version`, storing the
---version after each step so a failing step is retried and a finished one
---never runs again. Returns the stored version when it is newer than
---`version` (data a newer version of the addon saved), which is left as it
---is, and `false` otherwise.
---
---The layout is checked before anything is written when no step with a
---function is pending, and on the result of the last such step before that
---result is committed, so a table `Open` refuses never has its version
---stamped or a migration committed on the way to the refusal.
---@param raw table
---@param name string saved-variable name, for messages
---@param version integer|false
---@param migrations table|false
---@param level integer stack level the failures are reported at
---@return integer|false newerVersion
local function migrate(raw, name, version, migrations, level)
  if version == false then
    return false
  end

  -- A table with nothing in it was never written by an older version.
  if type(next(raw)) == "nil" then
    rawset(raw, "version", version)
    return false
  end

  local stored = rawget(raw, "version")
  if type(stored) == "nil" then
    stored = 0
  elseif isSecret(stored) or not isIntegerAtLeast(stored, 0) then
    error("SettingsKit:Open " .. name .. ".version must be a non-negative integer", level)
  end
  if stored > version then
    return stored
  end

  local lastMigration = findLastMigration(migrations, stored + 1, version)
  if lastMigration == false then
    validateLayout(raw, name, level + 1)
  end
  for step = stored + 1, version do
    -- `migrations` is `false` when the option was omitted: every step is
    -- then a version stamp with nothing to run.
    local migration = nil
    if migrations ~= false then
      migration = rawget(migrations, step)
    end
    if type(migration) ~= "nil" then
      local ok, failure = runMigrationStep(raw, name, migration, step == lastMigration)
      if not ok then
        raiseMigrationFailure(name, step, failure, level + 1)
      end
    end
    rawset(raw, "version", step)
  end
  return false
end

---Whether a stored profile name is still usable. A corrupted entry is ignored
---rather than trusted.
---@param value any
---@return boolean
local function isStoredProfileName(value)
  return type(value) == "string"
    and not isSecret(value)
    and value:find("%S") ~= nil
    and #value <= rawget(sharedLimits, "maxProfileNameLength")
end

---Make sure the profile `name` has a table.
---@param raw table
---@param name string
local function ensureProfile(raw, name)
  local profiles = rawget(raw, "profiles")
  if type(profiles) ~= "table" then
    profiles = {}
    rawset(raw, "profiles", profiles)
  end
  if type(rawget(profiles, name)) ~= "table" then
    rawset(profiles, name, {})
  end
end

---Return the cached root view of profile `name`, building it on first use.
---@param db table
---@param name string
---@return table proxy
local function profileView(db, name)
  local roots = db._profileRoots
  local proxy = rawget(roots, name)
  if proxy == nil then
    proxy = newRootView(db, rawget(db._scopes, "profile"), name)
    rawset(roots, name, proxy)
  end
  return proxy
end

---Detach the cached root view of profile `name`: reads fall back to defaults
---and writes are refused from now on.
---@param db table
---@param name string
local function detachProfileView(db, name)
  local roots = db._profileRoots
  local proxy = rawget(roots, name)
  if proxy ~= nil then
    local node = rawget(views, proxy)
    if node ~= nil then
      node.dead = true
    end
    rawset(roots, name, nil)
  end
end

---Point `db.profile` at the current profile's view, when the profile scope is
---declared.
---@param db table
local function publishProfileView(db)
  if rawget(db._scopes, "profile") ~= nil then
    rawset(db, "profile", profileView(db, db._profile))
  end
end

-- Database methods -----------------------------------------------------------

---Fire the profile signal `signalName` of `db` with `...`, when anybody ever
---connected to it: the signal is created by the first `OnProfile*` call, so a
---database nobody listens to allocates none.
---@param db table
---@param signalName string
---@param ... any
local function fireProfileSignal(db, signalName, ...)
  local signal = db._signals[signalName]
  if signal ~= nil then
    signal:Fire(...)
  end
end

---Refuse a method that changes the saved table when the database is
---read-only. Every changing method asks this right after its receiver check,
---so nothing is validated, created or signalled on a read-only database.
---@param db table a validated database
---@param methodName string qualified public method name, used in the error
---@param level integer stack level the failure is reported at
local function refuseReadOnly(db, methodName, level)
  if rawget(db, "_readOnly") == true then
    error(
      methodName
        .. " cannot change "
        .. rawget(db, "_name")
        .. ", which is read-only: "
        .. readOnlyReason(db),
      level
    )
  end
end

---@param self SettingsKit.Database
---@return boolean readOnly `true` when the saved table was written by a newer version and `allowNewerData` was not passed
local function databaseIsReadOnly(self)
  validateDatabase(self, "SettingsKit.Database:IsReadOnly", 3)
  return rawget(self, "_readOnly") == true
end

---@param self SettingsKit.Database
---@return string name the current profile
local function databaseGetProfile(self)
  validateDatabase(self, "SettingsKit.Database:GetProfile", 3)
  return rawget(self, "_profile")
end

---@param self SettingsKit.Database
---@return string savedVariable the global name the database was opened over
local function databaseGetSavedVariable(self)
  validateDatabase(self, "SettingsKit.Database:GetSavedVariable", 3)
  return rawget(self, "_name")
end

---Switch the current profile, creating it when it does not exist, and record
---the choice for this character.
---@param self SettingsKit.Database
---@param name string
---@return boolean changed `false` when `name` already was the current profile
local function databaseSetProfile(self, name)
  validateDatabase(self, "SettingsKit.Database:SetProfile", 3)
  refuseReadOnly(self, "SettingsKit.Database:SetProfile", 3)
  validateProfileName(name, "SettingsKit.Database:SetProfile name", 3)

  local db = self --[[@as table]]
  local previous = db._profile
  if name == previous then
    return false
  end

  local raw = db._raw
  ensureProfile(raw, name)
  if db._charKey ~= false then
    rawset(rawget(raw, "profileKeys"), db._charKey, name)
  end
  db._profile = name
  publishProfileView(db)
  fireProfileSignal(db, "profileChanged", self, name, previous)
  return true
end

---Return every profile name, sorted. Allocates a fresh array on every call.
---@param self SettingsKit.Database
---@return string[] names
local function databaseGetProfiles(self)
  validateDatabase(self, "SettingsKit.Database:GetProfiles", 3)
  local db = self --[[@as table]]
  local names = {}
  local current = db._profile
  local hasCurrent = false
  local profiles = rawget(db._raw, "profiles")
  if type(profiles) == "table" then
    for name, profile in next, profiles do
      if isStoredProfileName(name) and type(profile) == "table" then
        names[#names + 1] = name
        if name == current then
          hasCurrent = true
        end
      end
    end
  end
  if not hasCurrent then
    names[#names + 1] = current
  end
  table.sort(names)
  return names
end

---Replace the current profile's contents with a copy of profile `from`.
---@param self SettingsKit.Database
---@param from string
local function databaseCopyProfile(self, from)
  validateDatabase(self, "SettingsKit.Database:CopyProfile", 3)
  refuseReadOnly(self, "SettingsKit.Database:CopyProfile", 3)
  validateProfileName(from, "SettingsKit.Database:CopyProfile from", 3)

  local db = self --[[@as table]]
  local current = db._profile
  if from == current then
    error("SettingsKit.Database:CopyProfile cannot copy the current profile onto itself", 2)
  end
  local raw = db._raw
  local source = rawget(rawget(raw, "profiles"), from)
  if type(source) ~= "table" then
    error("SettingsKit.Database:CopyProfile from names a profile that does not exist", 2)
  end
  local maxDepth = readMaxDepth()
  if isTooDeep(source, 1, maxDepth) then
    error("SettingsKit.Database:CopyProfile from nests more than " .. maxDepth .. " tables", 2)
  end

  ensureProfile(raw, current)
  local target = rawget(rawget(raw, "profiles"), current)
  wipe(target)
  for key, value in next, source do
    rawset(target, key, copyPlain(value))
  end
  fireProfileSignal(db, "profileCopied", self, from, current)
end

---Remove every value of the current profile, so it reads its defaults again.
---@param self SettingsKit.Database
local function databaseResetProfile(self)
  validateDatabase(self, "SettingsKit.Database:ResetProfile", 3)
  refuseReadOnly(self, "SettingsKit.Database:ResetProfile", 3)
  local db = self --[[@as table]]
  local current = db._profile
  ensureProfile(db._raw, current)
  wipe(rawget(rawget(db._raw, "profiles"), current))
  fireProfileSignal(db, "profileReset", self, current)
end

---Delete a profile that is not the current one. Characters that used it fall
---back to the default profile at their next `Open`.
---@param self SettingsKit.Database
---@param name string
local function databaseDeleteProfile(self, name)
  validateDatabase(self, "SettingsKit.Database:DeleteProfile", 3)
  refuseReadOnly(self, "SettingsKit.Database:DeleteProfile", 3)
  validateProfileName(name, "SettingsKit.Database:DeleteProfile name", 3)

  local db = self --[[@as table]]
  if name == db._profile then
    error("SettingsKit.Database:DeleteProfile cannot delete the current profile", 2)
  end
  local raw = db._raw
  local profiles = rawget(raw, "profiles")
  if type(rawget(profiles, name)) ~= "table" then
    error("SettingsKit.Database:DeleteProfile name names a profile that does not exist", 2)
  end

  rawset(profiles, name, nil)
  local profileKeys = rawget(raw, "profileKeys")
  for character, profile in next, profileKeys do
    -- A saved value is asked about secrecy before it is compared.
    if not isSecret(profile) and profile == name then
      rawset(profileKeys, character, nil)
    end
  end
  detachProfileView(db, name)
  fireProfileSignal(db, "profileDeleted", self, name)
end

---Wipe the whole saved variable back to an empty layout. Every profile view
---obtained before is detached; `db.profile` is a new view of the default
---profile.
---
---The version stamped again is `options.version`, except in a database
---opened with `allowNewerData` over newer data: that one keeps the newer
---stored version, because SettingsKit never lowers a stored version.
---@param self SettingsKit.Database
local function databaseResetDatabase(self)
  validateDatabase(self, "SettingsKit.Database:ResetDatabase", 3)
  refuseReadOnly(self, "SettingsKit.Database:ResetDatabase", 3)
  local db = self --[[@as table]]
  local raw = db._raw
  local previous = db._profile

  wipe(raw)
  local stamp = db._version
  if rawget(db, "_newerVersion") ~= false then
    stamp = rawget(db, "_newerVersion")
  end
  if stamp ~= false then
    rawset(raw, "version", stamp)
  end
  createLayout(raw)

  for name in next, db._profileRoots do
    local node = rawget(views, rawget(db._profileRoots, name))
    if node ~= nil then
      node.dead = true
    end
  end
  wipe(db._profileRoots)

  local name = db._defaultProfile
  ensureProfile(raw, name)
  db._profile = name
  publishProfileView(db)

  fireProfileSignal(db, "profileReset", self, name)
  if name ~= previous then
    fireProfileSignal(db, "profileChanged", self, name, previous)
  end
end

---Connect a listener to validated writes of one scope.
---@param self SettingsKit.Database
---@param scopeName SettingsKit.ScopeName
---@param callback SettingsKit.ChangeListener
---@return SignalKit.Connection connection
local function databaseOnChange(self, scopeName, callback)
  validateDatabase(self, "SettingsKit.Database:OnChange", 3)
  local db = self --[[@as table]]
  validateScopeName(scopeName, "SettingsKit.Database:OnChange", 3)
  local scope = type(scopeName) == "string" and rawget(db._scopes, scopeName) or nil
  if scope == nil or not scope.available then
    error("SettingsKit.Database:OnChange scope must name a declared, available scope", 2)
  end
  validateCallback(callback, "SettingsKit.Database:OnChange", 3)
  -- Created on first use, so a scope nobody listens to costs no signal and
  -- its writes skip the dispatch.
  if scope.signal == false then
    scope.signal = SignalKit:New()
  end
  return scope.signal:Connect(callback)
end

---Connect `callback` to one of the database's profile signals.
---@param db any
---@param signalName string
---@param methodName string
---@param callback any
---@return SignalKit.Connection
local function connectProfileSignal(db, signalName, methodName, callback)
  -- connectProfileSignal <- the public method <- the caller
  validateDatabase(db, methodName, 4)
  validateCallback(callback, methodName, 4)
  -- Created on first use; `fireProfileSignal` skips a signal never created.
  local signals = rawget(db, "_signals")
  local signal = rawget(signals, signalName)
  if signal == nil then
    signal = SignalKit:New()
    rawset(signals, signalName, signal)
  end
  return signal:Connect(callback)
end

---@param self SettingsKit.Database
---@param callback SettingsKit.ProfileChangedListener
---@return SignalKit.Connection connection
local function databaseOnProfileChanged(self, callback)
  return connectProfileSignal(
    self,
    "profileChanged",
    "SettingsKit.Database:OnProfileChanged",
    callback
  )
end

---@param self SettingsKit.Database
---@param callback SettingsKit.ProfileCopiedListener
---@return SignalKit.Connection connection
local function databaseOnProfileCopied(self, callback)
  return connectProfileSignal(
    self,
    "profileCopied",
    "SettingsKit.Database:OnProfileCopied",
    callback
  )
end

---@param self SettingsKit.Database
---@param callback SettingsKit.ProfileListener
---@return SignalKit.Connection connection
local function databaseOnProfileReset(self, callback)
  return connectProfileSignal(self, "profileReset", "SettingsKit.Database:OnProfileReset", callback)
end

---@param self SettingsKit.Database
---@param callback SettingsKit.ProfileListener
---@return SignalKit.Connection connection
local function databaseOnProfileDeleted(self, callback)
  return connectProfileSignal(
    self,
    "profileDeleted",
    "SettingsKit.Database:OnProfileDeleted",
    callback
  )
end

---Iterate a view: every key with a default, then every saved key without one,
---each with the value a read of it returns.
---
---`for key, value in db:Pairs(db.profile) do ... end`. The iterator is
---stateless and allocates nothing. As with `pairs`, do not add keys to the
---view while iterating it.
---@param self SettingsKit.Database
---@param view table a view of this database
---@return function iterator, table view, nil
local function databasePairs(self, view)
  validateDatabase(self, "SettingsKit.Database:Pairs", 3)
  local node = type(view) == "table" and rawget(views, view) or nil
  if node == nil or node.root.db ~= self then
    error("SettingsKit.Database:Pairs view must be a view of this database", 2)
  end
  return pairsNext, view, nil
end

---Step from `node` to the view of its record field or keyed-section entry
---`key`, the way reading `node[key]` would, without reading any value.
---@param node table
---@param key any
---@return table|nil child, string|nil refusal
local function descendPath(node, key)
  if isSecret(key) then
    return nil,
      refusalLabel(node)
        .. displayPathOf(node)
        .. " refused a secret key: saved variables never hold secret values"
  end
  if type(key) == "nil" or key ~= key then
    return nil, refusalLabel(node) .. displayPathOf(node) .. " key must not be nil or NaN"
  end

  local child = nil
  if node.kind == KIND_RECORD then
    child = node.children[key]
  elseif node.plan.values.proxied ~= false then
    child = entryView(node, key)
  end
  if child == nil then
    return nil,
      refusalLabel(node)
        .. displayPathOf(node)
        .. formatKey(key)
        .. " is not a record or keyed section"
  end
  return rawget(views, child)
end

---Turn a dotted-path segment into the key it names: a number when it is one
---and the segment indexes a keyed section whose keys are numbers.
---@param node table
---@param segment string
---@return string|number
local function segmentKey(node, segment)
  if node.kind == KIND_MAP and node.plan.keyKind == "number" then
    local number = tonumber(segment)
    if number ~= nil then
      return number
    end
  end
  return segment
end

---Check whether writing `value` at `path` in `scope` would be accepted,
---without writing anything.
---
---Runs exactly the checks a write through a view runs: the secret, view and
---metatable refusals, the schema check, and the key schema and `max` of every
---keyed section on the path. `path` is a dotted string (`"frame.x"`,
---`"auras.118.shown"`, where a segment indexing a keyed section with number
---keys becomes a number) or an array of keys (`{ "auras", 118, "shown" }`),
---whose keys are used as they are. An array path allocates nothing for a
---valid value while the entry views on it are cached (a keyed-section entry
---view is rebuilt after a collection dropped it); a dotted string allocates
---its segments.
---@param self SettingsKit.Database
---@param scopeName SettingsKit.ScopeName
---@param path string|any[]
---@param value any
---@return boolean ok, string|nil message the text a refused write would raise, without a position
local function databaseValidate(self, scopeName, path, value)
  validateDatabase(self, "SettingsKit.Database:Validate", 3)
  local db = self --[[@as table]]
  validateScopeName(scopeName, "SettingsKit.Database:Validate", 3)
  local scope = type(scopeName) == "string" and rawget(db._scopes, scopeName) or nil
  if scope == nil or not scope.available then
    error("SettingsKit.Database:Validate scope must name a declared, available scope", 2)
  end
  local node = rawget(views, rawget(db, scopeName))
  local refusal = nil
  local key = nil

  local pathType = type(path)
  if pathType == "table" and rawget(views, path) == nil then
    local count = #path
    if count == 0 then
      error(
        "SettingsKit.Database:Validate path must be a dotted string or a non-empty array of keys",
        2
      )
    end
    for index = 1, count - 1 do
      node, refusal = descendPath(node, rawget(path, index))
      if node == nil then
        return false, refusal
      end
    end
    key = rawget(path, count)
  elseif pathType == "string" and not isSecret(path) and path ~= "" then
    local start = 1
    while true do
      local stop = path:find(".", start, true)
      local segment = path:sub(start, stop and stop - 1 or -1)
      if segment == "" then
        error("SettingsKit.Database:Validate path must not contain an empty segment", 2)
      end
      if stop == nil then
        key = segmentKey(node, segment)
        break
      end
      node, refusal = descendPath(node, segmentKey(node, segment))
      if node == nil then
        return false, refusal
      end
      start = stop + 1
    end
  else
    error(
      "SettingsKit.Database:Validate path must be a dotted string or a non-empty array of keys",
      2
    )
  end

  -- A write would never reach SettingsKit with these keys; say so the same
  -- way a step on the path does.
  if not isSecret(key) and (type(key) == "nil" or key ~= key) then
    return false,
      "SettingsKit (" .. db._name .. ") " .. displayPathOf(node) .. " key must not be nil or NaN"
  end
  refusal = refuseWrite(node, key, value, type(value))
  if refusal ~= nil then
    return false, refusal
  end
  return true
end

---Remove every saved value equal to its default, in every character, realm,
---class, faction and profile entry of every declared scope.
---@param self SettingsKit.Database
---@return integer removed how many values and tables were removed
local function databaseCompact(self)
  validateDatabase(self, "SettingsKit.Database:Compact", 3)
  refuseReadOnly(self, "SettingsKit.Database:Compact", 3)
  return compactDatabase(self)
end

---The database metatable's `__index`: methods from the prototype, and a clear
---error for a scope that is not declared or not available.
---@param db table
---@param key any
---@return any
local function databaseIndex(db, key)
  -- A secret key would raise inside SettingsKit while it indexes the
  -- prototype; refuse it at the reading line instead.
  if isSecret(key) then
    -- databaseIndex <- the reading line
    error("SettingsKit databases cannot be read with a secret key", 2)
  end
  local method = rawget(Database, key)
  if method ~= nil then
    return method
  end
  -- A declared, available scope is a field of the database and never gets
  -- here, so a scope name that does is undeclared or unavailable. The
  -- message is built only now, so a database whose missing scopes nobody
  -- reads builds none.
  if SCOPE_SET[key] == true then
    local scope = rawget(rawget(db, "_scopes"), key)
    if scope == nil then
      -- databaseIndex <- the reading line
      error(
        "SettingsKit ("
          .. rawget(db, "_name")
          .. ") db."
          .. key
          .. " is not declared; pass schema."
          .. key
          .. " to SettingsKit:Open",
        2
      )
    elseif not scope.available then
      error(
        "SettingsKit ("
          .. rawget(db, "_name")
          .. ") db."
          .. key
          .. " is unavailable: "
          .. UNAVAILABLE_REASONS[key]
          .. " when the database was opened",
        2
      )
    end
  end
  return nil
end

---The database metatable's `__newindex`: a database has no writable fields.
local function databaseNewIndex()
  error("SettingsKit databases are read-only; write through db.<scope> instead", 2)
end

-- Package public API ---------------------------------------------------------

---Build the scope records of a database from the validated schema table.
---A scope that is not declared gets no record; `databaseIndex` builds the
---message a read of it raises from the record's absence, or from its
---`available` flag.
---@param schema table
---@param keys table<string, string|false>
---@param level integer stack level the failures are reported at
---@return table scopes
local function buildScopes(schema, keys, level)
  local scopes = {}
  -- Read once for every scope: `GetLimits` allocates its answer.
  local maxDepth = readMaxDepth()
  for index = 1, #SCOPE_NAMES do
    local scopeName = SCOPE_NAMES[index]
    local node = rawget(schema, scopeName)
    if type(node) ~= "nil" then
      local sealed, plan = compileScope(node, scopeName, maxDepth, level + 1)

      ---@type string|false
      local sectionKey = false
      local available = true
      if scopeName ~= "global" and scopeName ~= "profile" then
        sectionKey = keys[scopeName]
        available = sectionKey ~= false
      end

      scopes[scopeName] = {
        name = scopeName,
        schema = sealed,
        plan = plan,
        sectionName = SCOPE_SECTIONS[scopeName],
        sectionKey = sectionKey,
        available = available,
        -- `OnChange` creates the signal on first use.
        signal = false,
      }
    end
  end
  return scopes
end

---Open the database over the saved variable `savedVariable`.
---
---Call it from the addon's loaded phase (`ADDON_LOADED` for the addon), the
---first moment the client guarantees the saved variable exists. Opening the
---same name again returns the same database.
---@param _ SettingsKit
---@param savedVariable string the global name from the TOC's `## SavedVariables`
---@param schema SettingsKit.Schema? per-scope SchemaKit table schemas; may be omitted when reopening
---@param options SettingsKit.Options?
---@return SettingsKit.Database db
local function open(_, savedVariable, schema, options)
  validateSavedVariableName(savedVariable, 3)

  local existing = rawget(databases, savedVariable)
  if existing ~= nil then
    -- A secret is never a table, so the type test keeps it from the
    -- identity comparison.
    if
      type(schema) ~= "nil"
      and (type(schema) ~= "table" or schema ~= rawget(existing, "_schemaSource"))
    then
      error(
        "SettingsKit:Open " .. savedVariable .. " is already open with a different schema table",
        2
      )
    end
    local current = readGlobal(savedVariable)
    if type(current) ~= "table" or current ~= rawget(existing, "_raw") then
      error(
        "SettingsKit:Open "
          .. savedVariable
          .. " was replaced after it was opened; open the database in the addon's loaded phase",
        2
      )
    end
    return existing
  end

  validateSchemaTable(schema, 3)
  ---@cast schema table
  local defaultProfile, version, migrations, maxScannedEntries, allowNewerData =
    readOptions(options, 3)

  local raw = readGlobal(savedVariable)
  if type(raw) ~= "nil" and type(raw) ~= "table" then
    error("SettingsKit:Open " .. savedVariable .. " must be a table or nil", 2)
  end

  -- Scope keys are read once, before anything is written, so a schema or
  -- layout refusal leaves the saved variable untouched.
  local keys = readScopeKeys()
  local scopes = buildScopes(schema, keys, 3)

  if type(raw) == "nil" then
    raw = {}
    writeGlobal(savedVariable, raw)
  end
  -- Data a newer version of the addon saved is left as that version wrote
  -- it: nothing is migrated, the stored version is never lowered, and unless
  -- the addon opted in, nothing is written at all.
  local newerVersion = migrate(raw, savedVariable, version, migrations, 3)
  local readOnly = newerVersion ~= false and not allowNewerData
  validateLayout(raw, savedVariable, 3)
  if not readOnly then
    createLayout(raw)
  end

  local charKey = keys.char
  local resolvedDefault = defaultProfile
  if defaultProfile == CHARACTER_PROFILE then
    resolvedDefault = charKey or DEFAULT_PROFILE_NAME
  end
  local profileName = resolvedDefault
  -- A read-only database may lack the section, since it created none.
  local profileKeys = rawget(raw, "profileKeys")
  if charKey ~= false and type(profileKeys) == "table" then
    local stored = rawget(profileKeys, charKey)
    if isStoredProfileName(stored) then
      profileName = stored
    end
  end
  if not readOnly then
    ensureProfile(raw, profileName)
  end

  local db = setmetatable({
    _layout = DATABASE_SCHEMA,
    _name = savedVariable,
    _raw = raw,
    _schemaSource = schema,
    _scopes = scopes,
    _charKey = charKey,
    _defaultProfile = resolvedDefault,
    _profile = profileName,
    _profileRoots = {},
    _version = version,
    -- The stored version when it is newer than `options.version`, else `false`.
    _newerVersion = newerVersion,
    -- `true` when newer data was opened without `allowNewerData`.
    _readOnly = readOnly,
    -- `math.huge` when opened with `maxScannedEntries = SettingsKit.UNBOUNDED`.
    _maxScannedEntries = maxScannedEntries,
    -- The four profile signals, each created by its first `OnProfile*`.
    _signals = {},
  }, DATABASE_METATABLE)

  for index = 1, #SCOPE_NAMES do
    local scopeName = SCOPE_NAMES[index]
    local scope = rawget(scopes, scopeName)
    if scope ~= nil and scope.available and scopeName ~= "profile" then
      rawset(db, scopeName, newRootView(db, scope, scope.sectionKey))
    end
  end
  publishProfileView(db)

  connectLogout(db)
  rawset(databases, savedVariable, db)
  return db --[[@as SettingsKit.Database]]
end

---@param receiver any
---@param label string qualified public method name, used in the argument error
---@param level integer stack level the failure is reported at
local function validateFacade(receiver, label, level)
  if receiver ~= SettingsKit then
    error(label .. " must be called on the SettingsKit facade; use " .. label .. "(...)", level)
  end
end

---Refuse a limit update before anything changes: a secret key or value, an
---unknown name, `SettingsKit.UNBOUNDED` (with the reason) or a value outside
---the range. A secret is refused before it indexes a table or is compared,
---because either raises.
---@param limits any
---@param level integer stack level the failures are reported at
local function validateLimitUpdate(limits, level)
  if type(limits) ~= "table" then
    error("SettingsKit:SetLimits limits must be a table", level)
  end
  local key = next(limits)
  while type(key) ~= "nil" do
    if isSecret(key) then
      error("SettingsKit:SetLimits limits must not have a secret key", level)
    end
    if type(key) ~= "string" or LIMIT_CEILINGS[key] == nil then
      error("SettingsKit:SetLimits limits." .. tostring(key) .. " is not a recognised limit", level)
    end
    local value = rawget(limits, key)
    if isSecret(value) then
      error("SettingsKit:SetLimits limits." .. key .. " must not be a secret value", level)
    end
    if value == UNBOUNDED then
      error(
        "SettingsKit:SetLimits limits."
          .. key
          .. " cannot be SettingsKit.UNBOUNDED: "
          .. UNBOUNDED_REFUSALS[key],
        level
      )
    end
    local minimum = LIMIT_MINIMUMS[key]
    local ceiling = LIMIT_CEILINGS[key]
    if not isIntegerAtLeast(value, minimum) or value > ceiling then
      error(
        "SettingsKit:SetLimits limits."
          .. key
          .. " must be an integer from "
          .. minimum
          .. " to "
          .. ceiling,
        level
      )
    end
    key = next(limits, key)
  end
end

---Change any subset of the shared limits. Affects every consumer in the
---session; nothing changes when any value is refused.
---@param self SettingsKit
---@param limits table
local function setLimits(self, limits)
  validateFacade(self, "SettingsKit:SetLimits", 3)
  validateLimitUpdate(limits, 3)
  for index = 1, #LIMIT_NAMES do
    local name = LIMIT_NAMES[index]
    local value = rawget(limits, name)
    if type(value) ~= "nil" then
      rawset(sharedLimits, name, value)
    end
  end
end

---Return a fresh copy of the shared limits.
---@param self SettingsKit
---@return SettingsKit.Limits
local function getLimits(self)
  validateFacade(self, "SettingsKit:GetLimits", 3)
  return {
    maxProfileNameLength = rawget(sharedLimits, "maxProfileNameLength"),
    pathKeyLimit = rawget(sharedLimits, "pathKeyLimit"),
  }
end

-- Upgrades -------------------------------------------------------------------
--
-- Each repair declares its helpers inside its own block: they run once, at
-- load, and Lua 5.1 allows the main chunk only 200 locals.

-- Revision 1 gave an entry view of a keyed section declared without a default
-- `false` for its defaults, and passed that `false` on to the record views
-- below it, so those views read `nil` where the wildcard and field defaults
-- apply. Their nodes survive the upgrade in `state.views`; recompute every
-- node's defaults the way `viewDefaults` builds them now. A node revision 1
-- built correctly gets the same table back.
if previousRevision ~= nil and previousRevision < 2 then
  ---Recompute the defaults of `node`, after those of every node above it, once
  ---each. A scope root always read its plan's own field defaults, so the walk
  ---stops there.
  ---@param node table
  ---@param repaired table<table, boolean> nodes already recomputed
  local function repairNodeDefaults(node, repaired)
    if repaired[node] then
      return
    end
    repaired[node] = true
    local parent = node.parent
    if parent == false then
      return
    end
    repairNodeDefaults(parent, repaired)
    node.defaults = viewDefaults(parent.defaults, node.key, node.plan)
  end

  local repaired = {}
  for _, node in next, views do
    repairNodeDefaults(node, repaired)
  end
end

-- Revision 5 records on every database whether it is read-only and which
-- newer stored version it was opened over. Databases an older revision opened
-- lack both fields; they get them once, here.
if previousRevision ~= nil and previousRevision < 5 then
  ---Bring a layout 1 database (revisions 1 to 4) to layout 2 by adding the
  ---fields revision 5 reads. The database was opened writable under the older
  ---contract and stays writable: turning it read-only in the middle of a
  ---session would break an addon that already writes through it. Its
  ---`_newerVersion` is still recorded from the saved table, so `ResetDatabase`
  ---never lowers a newer stored version.
  ---@param db table
  local function upgradeDatabaseLayout(db)
    local newerVersion = false
    local version = rawget(db, "_version")
    local stored = rawget(rawget(db, "_raw"), "version")
    if
      version ~= false
      and type(stored) == "number"
      and not isSecret(stored)
      and isIntegerAtLeast(stored, 0)
      and stored > version
    then
      newerVersion = stored
    end
    rawset(db, "_newerVersion", newerVersion)
    rawset(db, "_readOnly", false)
    rawset(db, "_layout", 2)
  end

  for _, db in next, databases do
    if rawget(db, "_layout") == 1 then
      upgradeDatabaseLayout(db)
    end
  end
end

-- Revision 6 reads through `kinds`, `pathKeys` and the plans' `ownKinds` and
-- `defaultKind`, and writes through `fastChecks` and `verified`. Nodes and
-- plans an older revision built lack them; every live node gets them here,
-- and so does the plan of every scope, including scopes whose views are not
-- built yet. This runs after the revision 2 repair of `defaults` above, which
-- the read kinds are derived from, and for every node, since a repaired node
-- may already carry kinds derived from its old defaults.
if previousRevision ~= nil and previousRevision < 6 then
  ---Bring a plan revision 5 compiled (layout 1) to layout 2, children first.
  ---Revision 5 kept no description, so such a plan gets no fast checks: every
  ---write through it runs SchemaKit's check, as it did.
  ---@param plan SettingsKit.Plan
  local function upgradePlan(plan)
    if plan.layout == PLAN_SCHEMA then
      return
    end
    if plan.proxied == KIND_RECORD then
      local fieldNames = plan.fieldNames --[[@as string[] ]]
      for index = 1, #fieldNames do
        upgradePlan(plan.fields[fieldNames[index]])
      end
      plan.ownKinds = buildReadKinds(plan, plan.ownDefaults)
      plan.fastChecks = {}
    elseif plan.proxied == KIND_MAP then
      upgradePlan(plan.values --[[@as SettingsKit.Plan]])
    end
    plan.defaultKind = defaultKindOf(plan)
    plan.layout = PLAN_SCHEMA
  end

  ---Bring `node` to layout 2, after its parent, once each: add what the read
  ---and write paths use, and drop what moved. Everything is derived from what
  ---every revision keeps (`parent`, `key`, `plan`, `defaults`), so a node that
  ---is already in layout 2 gets the same values back, except `verified`,
  ---which starts over: the next full check through the node sets it again.
  ---Old nodes keep their 32-slot tables; only nodes built from now on are
  ---smaller.
  ---@param node table
  ---@param upgraded table<table, boolean> nodes already brought to layout 2
  local function upgradeNodeLayout(node, upgraded)
    if upgraded[node] then
      return
    end
    upgraded[node] = true
    local parent = node.parent
    local plan = node.plan
    upgradePlan(plan)

    if parent == false then
      -- A root keeps `db`, `scope`, `dead` and `sectionKey`; the section
      -- name is read from its scope.
      node.sectionName = nil
      node.verified = true
    else
      upgradeNodeLayout(parent, upgraded)
      node.depth = (parent.depth or 1) + 1
      node.pathKeys = extendPathKeys(parent, node.key)
      node.verified = false
      node.db = nil
      node.scope = nil
      node.dead = nil
      node.sectionName = nil
      node.sectionKey = nil
    end
    -- Messages derive the display path from `path` now.
    node.displayPath = nil
    -- Layout 1 said whether a probe key is set in `probeSet`; layout 2
    -- keeps the key, or `NO_PROBE_KEY` when none is set.
    if node.probeSet == false then
      node.probeKey = NO_PROBE_KEY
    end
    node.probeSet = nil

    if node.kind == KIND_RECORD then
      node.kinds = readKindsOf(plan, node.defaults)
      if parent ~= false then
        ensureDepthProbe(node.depth)
      end
      node.entries = nil
    else
      -- Layout 1 kept a keyed section's entry cache in `entries`.
      if type(node.entries) == "table" then
        node.children = node.entries
      end
      node.entries = nil
      node.ownEntries = ownEntriesOf(node.defaults)
      node.valuesProxied = plan.values.proxied ~= false
    end
    node.layout = NODE_SCHEMA
  end

  ---Bring every database to layout 3, and every scope plan and live node to
  ---layout 2. A function of its own so its loop variables do not count
  ---against the main chunk's 200 locals.
  local function upgradeLayouts()
    for _, db in next, databases do
      -- `databaseIndex` builds the missing-scope messages from `_scopes`
      -- now, in the same words.
      rawset(db, "_unavailable", nil)
      rawset(db, "_layout", DATABASE_SCHEMA)
      for _, scope in next, rawget(db, "_scopes") do
        upgradePlan(scope.plan)
      end
    end
    local upgraded = {}
    for _, node in next, views do
      upgradeNodeLayout(node, upgraded)
    end
  end
  upgradeLayouts()
end

-- Commit ---------------------------------------------------------------------

rawset(Database, "GetProfile", databaseGetProfile)
rawset(Database, "SetProfile", databaseSetProfile)
rawset(Database, "GetProfiles", databaseGetProfiles)
rawset(Database, "CopyProfile", databaseCopyProfile)
rawset(Database, "ResetProfile", databaseResetProfile)
rawset(Database, "DeleteProfile", databaseDeleteProfile)
rawset(Database, "ResetDatabase", databaseResetDatabase)
rawset(Database, "OnChange", databaseOnChange)
rawset(Database, "OnProfileChanged", databaseOnProfileChanged)
rawset(Database, "OnProfileCopied", databaseOnProfileCopied)
rawset(Database, "OnProfileReset", databaseOnProfileReset)
rawset(Database, "OnProfileDeleted", databaseOnProfileDeleted)
rawset(Database, "Compact", databaseCompact)
rawset(Database, "GetSavedVariable", databaseGetSavedVariable)
rawset(Database, "Pairs", databasePairs)
rawset(Database, "Validate", databaseValidate)
rawset(Database, "IsReadOnly", databaseIsReadOnly)

rawset(VIEW_METATABLE, "__index", viewIndex)
rawset(VIEW_METATABLE, "__newindex", viewNewIndex)
rawset(VIEW_METATABLE, "__metatable", "SettingsKit.View")
rawset(DATABASE_METATABLE, "__index", databaseIndex)
rawset(DATABASE_METATABLE, "__newindex", databaseNewIndex)

rawset(SettingsKit, "API", API_GENERATION)
rawset(SettingsKit, "REVISION", IMPLEMENTATION_REVISION)
rawset(SettingsKit, "DEFAULT_PROFILE", DEFAULT_PROFILE_NAME)
rawset(SettingsKit, "MAX_PROFILE_NAME_LENGTH", MAX_PROFILE_NAME_LENGTH)
rawset(SettingsKit, "UNBOUNDED", UNBOUNDED)
rawset(SettingsKit, "Open", open)
rawset(SettingsKit, "SetLimits", setLimits)
rawset(SettingsKit, "GetLimits", getLimits)

rawset(dispatch, "compactOnLogout", compactOnLogout)
rawset(dispatch, "compactAllOnLogout", compactAllOnLogout)
rawset(state, "runtimeRevision", IMPLEMENTATION_REVISION)

if not validatePublicSurface(SettingsKit) or not validateCurrentState(SettingsKit) then
  error("MoltenCodes SettingsKit package state is corrupted or incomplete", 2)
end

return SettingsKit
