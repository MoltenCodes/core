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
--              the stored version to `options.version`;
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
local IMPLEMENTATION_REVISION = 4
local REQUIRED_REGISTRY_API = 2
local REQUIRED_SCHEMAKIT_API = 1
local REQUIRED_SIGNALKIT_API = 1
local OPTIONAL_EVENTKIT_API = 1
local STATE_SCHEMA = 1

-- Every database and view node carries the layout it was built with, so a
-- later revision that changes a layout can upgrade old objects instead of
-- guessing from which fields exist.
local DATABASE_SCHEMA = 1
local NODE_SCHEMA = 1

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
local OPTION_KEYS =
    { defaultProfile = true, version = true, migrations = true, maxScannedEntries = true }

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
}

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

---One step of a saved-table migration. It receives the raw saved table and
---changes it in place; its return value is ignored.
---@alias SettingsKit.Migration fun(raw: table)

---Options accepted by `SettingsKit:Open`.
---@class SettingsKit.Options
---@field defaultProfile string? `"Default"` (the default), `"char"` for one profile per character, or any other profile name.
---@field version integer? The saved-table version this addon writes. Omitted: no versioning.
---@field migrations table<integer, SettingsKit.Migration>? Steps by the version they produce; requires `version`.
---@field maxScannedEntries (integer|table)? Most entries the secret-value scan of one written table visits: a positive integer or `SettingsKit.UNBOUNDED`; default `65536`.

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
---@field proxied "record"|"map"|false Whether reads of this value go through a view, and which kind.
---@field fieldNames string[]|false Record: declared field names, sorted.
---@field fields table<string, SettingsKit.Plan>|false Record: the plan of each field.
---@field ownDefaults table|false Record: every field default, filled.
---@field values SettingsKit.Plan|false Map: the plan of every value.
---@field max integer|false Map: the most entries it may hold.
---@field keyKind string|false Map: the SchemaKit kind of its keys, for converting a dotted path segment.
---@field default any The declared default, filled; for a map's values, the wildcard default.

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
    local probe = readIsSecret()
    return probe ~= nil and probe(value) == true
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

---Validate `Open`'s options and return what the database keeps of them.
---@param options any
---@param level integer stack level the failures are reported at
---@return string defaultProfile, integer|false version, table|false migrations, number maxScannedEntries
local function readOptions(options, level)
    if type(options) == "nil" then
        return DEFAULT_PROFILE_NAME, false, false, DEFAULT_MAX_SCANNED_ENTRIES
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
                error(
                    "SettingsKit:Open options.migrations[" .. step .. "] must be a function",
                    level
                )
            end
        end
    end

    local maxScannedEntries = readMaxScannedEntries(rawget(options, "maxScannedEntries"), level + 1)

    return defaultProfile, version or false, migrations or false, maxScannedEntries
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
            rawset(
                value,
                index,
                fillDefaults(description.of, rawget(value, index), depth + 1, maxDepth)
            )
        end
    end
    return value
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
        proxied = false,
        fieldNames = false,
        fields = false,
        ownDefaults = false,
        values = false,
        max = false,
        keyKind = false,
        default = fillDefaults(description, nil, depth, maxDepth),
    }
    if depth > maxDepth then
        return plan
    end

    if description.kind == "table" then
        plan.proxied = KIND_RECORD
        plan.fieldNames = {}
        plan.fields = {}
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
        end
        plan.ownDefaults = fillDefaults(description, {}, depth, maxDepth)
    elseif description.kind == "map" then
        local valuesPlan, refusal =
            compilePlan(description.values, depth + 1, label .. "[*]", maxDepth)
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

---Resolve the saved table behind `node`, or `nil` when it does not exist yet.
---@param node table
---@return table|nil
local function resolveContainer(node)
    local parent = node.parent
    if parent == false then
        if node.dead then
            return nil
        end
        local section = rawget(node.db._raw, node.sectionName)
        if type(section) ~= "table" then
            return nil
        end
        if node.sectionKey == false then
            return section
        end
        local container = rawget(section, node.sectionKey)
        if type(container) == "table" then
            return container
        end
        return nil
    end

    local parentContainer = resolveContainer(parent)
    if parentContainer == nil then
        return nil
    end
    local container = rawget(parentContainer, node.key)
    if type(container) == "table" then
        return container
    end
    return nil
end

---Resolve the saved table behind `node`, creating it and every missing table
---above it. A non-table value in the way is replaced.
---@param node table
---@return table
local function resolveForWrite(node)
    local parent = node.parent
    if parent == false then
        local raw = node.db._raw
        local section = rawget(raw, node.sectionName)
        if type(section) ~= "table" then
            section = {}
            rawset(raw, node.sectionName, section)
        end
        if node.sectionKey == false then
            return section
        end
        local container = rawget(section, node.sectionKey)
        if type(container) ~= "table" then
            container = {}
            rawset(section, node.sectionKey, container)
        end
        return container
    end

    local parentContainer = resolveForWrite(parent)
    local container = rawget(parentContainer, node.key)
    if type(container) ~= "table" then
        container = {}
        rawset(parentContainer, node.key, container)
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

---Build a view: a proxy and its node, and for a record every child view.
---@param db table
---@param scope table the scope record
---@param plan SettingsKit.Plan
---@param parent table|false parent node, `false` for a scope root
---@param key any key in the parent's table
---@param defaults table|false the defaults this view reads from
---@param displayPath string where the view is, for messages (`profile.frame`)
---@param path string where the view is, relative to the scope (`frame`)
---@return table proxy, table node
local function newView(db, scope, plan, parent, key, defaults, displayPath, path)
    local node = {
        layout = NODE_SCHEMA,
        kind = plan.proxied,
        plan = plan,
        db = db,
        scope = scope,
        parent = parent,
        key = key,
        root = false,
        dead = false,
        sectionName = false,
        sectionKey = false,
        defaults = defaults,
        displayPath = displayPath,
        path = path,
        -- The scratch table this view contributes to a write's probe, and the
        -- one key currently set in it.
        probe = {},
        probeSet = false,
        probeKey = false,
        children = false,
        entries = false,
    }
    if parent == false then
        node.root = node
    else
        node.root = parent.root
    end

    local proxy = setmetatable({}, VIEW_METATABLE)
    views[proxy] = node

    if plan.proxied == KIND_RECORD then
        local children = {}
        local fieldNames = plan.fieldNames --[[@as string[] ]]
        for index = 1, #fieldNames do
            local name = fieldNames[index]
            local field = plan.fields[name]
            if field.proxied ~= false then
                local segment = formatKey(name)
                children[name] = newView(
                    db,
                    scope,
                    field,
                    node,
                    name,
                    viewDefaults(defaults, name, field),
                    displayPath .. segment,
                    joinRelative(path, segment)
                )
            end
        end
        node.children = children
    else
        -- Entry views are made on first access and cached while somebody
        -- holds them.
        node.entries = setmetatable({}, WEAK_VALUES)
    end
    return proxy, node
end

---Build the root view of a scope over `section[sectionKey]`.
---@param db table
---@param scope table the scope record
---@param sectionKey string|false the key inside the section; `false` for `global`
---@return table proxy
local function newRootView(db, scope, sectionKey)
    local plan = scope.plan
    local proxy, node = newView(db, scope, plan, false, false, plan.ownDefaults, scope.name, "")
    node.sectionName = scope.sectionName
    node.sectionKey = sectionKey
    return proxy
end

---Return the view of entry `key` of a keyed section, building it on first use.
---@param node table the map node
---@param key any
---@return table proxy
local function entryView(node, key)
    local entries = node.entries
    local proxy = rawget(entries, key)
    if proxy ~= nil then
        return proxy
    end

    local valuesPlan = node.plan.values --[[@as SettingsKit.Plan]]
    local segment = formatKey(key)
    proxy = newView(
        node.db,
        node.scope,
        valuesPlan,
        node,
        key,
        viewDefaults(node.defaults, key, valuesPlan),
        node.displayPath .. segment,
        joinRelative(node.path, segment)
    )
    rawset(entries, key, proxy)
    return proxy
end

---Whether storing anything below `node` would create a keyed-section entry
---that is not saved yet. Only a validated write may create one, after the key
---schema and the section's `max` were checked.
---@param node table
---@return boolean
local function wouldCreateEntry(node)
    local child = node
    local parent = child.parent
    while parent ~= false do
        if parent.kind == KIND_MAP then
            local container = resolveContainer(parent)
            if container == nil or type(rawget(container, child.key)) == "nil" then
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
---keyed-section entry that is not saved yet the copy is returned unstored, so
---a read never creates an entry.
---@param node table
---@param key any
---@param default table
---@return table
local function materialise(node, key, default)
    local copy = copyPlain(default)
    if node.root.dead or wouldCreateEntry(node) then
        return copy
    end
    local container = resolveForWrite(node)
    rawset(container, key, copy)
    return copy
end

---Read `key` through a record view.
---@param node table
---@param key any
---@return any
local function readRecord(node, key)
    if isSecret(key) then
        -- readRecord <- viewIndex <- the reading line
        error(
            "SettingsKit ("
                .. node.db._name
                .. ") "
                .. node.displayPath
                .. " cannot be read with a secret key",
            3
        )
    end
    local container = resolveContainer(node)
    local value = nil
    if container ~= nil then
        value = rawget(container, key)
    end

    local field = node.plan.fields[key]
    if type(value) ~= "nil" then
        if field ~= nil and field.proxied ~= false and type(value) == "table" then
            return node.children[key]
        end
        return value
    end
    if field == nil then
        return nil
    end

    local defaults = node.defaults
    local default = nil
    if defaults then
        default = rawget(defaults, key)
    end
    if field.proxied ~= false then
        if type(default) ~= "nil" then
            return node.children[key]
        end
        return nil
    end
    if type(default) == "table" then
        return materialise(node, key, default)
    end
    return default
end

---Read `key` through a keyed-section view, falling back to the section's own
---default entries and then to its wildcard default.
---@param node table
---@param key any
---@return any
local function readMap(node, key)
    -- The secret probe comes first: the key is compared and used to index
    -- below, and either raises on a secret.
    if isSecret(key) then
        -- readMap <- viewIndex <- the reading line
        error(
            "SettingsKit ("
                .. node.db._name
                .. ") "
                .. node.displayPath
                .. " cannot be read with a secret key",
            3
        )
    end
    -- Without this, `view[nil]` would answer with the wildcard default.
    if type(key) == "nil" then
        return nil
    end

    local container = resolveContainer(node)
    local value = nil
    if container ~= nil then
        value = rawget(container, key)
    end

    local valuesPlan = node.plan.values
    if type(value) ~= "nil" then
        if valuesPlan.proxied ~= false and type(value) == "table" then
            return entryView(node, key)
        end
        return value
    end

    local default = nil
    if node.defaults then
        default = rawget(node.defaults, key)
    end
    if type(default) == "nil" then
        default = valuesPlan.default
    end
    if type(default) == "nil" then
        return nil
    end
    if valuesPlan.proxied ~= false then
        return entryView(node, key)
    end
    if type(default) == "table" then
        -- A missing entry is never stored by a read: the key may be one the
        -- key schema refuses, and the section may be full.
        return copyPlain(default)
    end
    return default
end

---The `__index` of every view.
---@param proxy table
---@param key any
---@return any
local function viewIndex(proxy, key)
    local node = rawget(views, proxy)
    if node == nil then
        return nil
    end
    if node.kind == KIND_RECORD then
        return readRecord(node, key)
    end
    return readMap(node, key)
end

---Set `key` in `node`'s probe table, clearing whatever key an earlier,
---interrupted write left there.
---@param node table
---@param key any
---@param value any
local function setProbe(node, key, value)
    local probe = node.probe
    if node.probeSet then
        rawset(probe, node.probeKey, nil)
    end
    rawset(probe, key, value)
    node.probeSet = true
    node.probeKey = key
end

---@param node table
local function clearProbe(node)
    if node.probeSet then
        rawset(node.probe, node.probeKey, nil)
        node.probeSet = false
        node.probeKey = false
    end
end

---Check the write `node[key] = value` against the scope's schema.
---
---The probe is a chain of scratch tables, one per view from the scope root down
---to `node`, holding only the path to the written key and the value. Every
---field of a record read through a view is optional (`compilePlan` refuses
---otherwise), so the chain is valid exactly when the written value is valid
---where it is written. A valid check allocates nothing.
---@param node table
---@param key any
---@param value any
---@return boolean ok, SchemaKit.Failure|nil failure
local function checkWrite(node, key, value)
    local child = node
    local parent = child.parent
    while parent ~= false do
        setProbe(parent, child.key, child.probe)
        child = parent
        parent = child.parent
    end
    setProbe(node, key, value)

    local ok, failure = node.scope.schema:Check(child.probe)

    child = node
    while child ~= false do
        clearProbe(child)
        child = child.parent
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
    local where = node.scope.name
    if path ~= "" then
        if path:sub(1, 1) == "[" then
            where = where .. path
        else
            where = where .. "." .. path
        end
    end
    return "SettingsKit ("
        .. node.db._name
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
    return "SettingsKit (" .. node.db._name .. ") "
end

---Return why the write `node[key] = value` would be refused, or `nil` when it
---would be accepted. Runs every check a write runs, in the same order, and
---writes nothing: the probe chain is set and cleared again. The message is
---built only for a refusal, so an accepted write allocates nothing here.
---@param node table
---@param key any
---@param value any
---@return string|nil refusal
local function refuseWrite(node, key, value)
    if node.root.dead then
        return refusalLabel(node)
            .. node.displayPath
            .. " belongs to a profile that was deleted or reset away"
    end

    local isSecretValue = readIsSecret()
    if isSecretValue ~= nil and isSecretValue(key) then
        return refusalLabel(node)
            .. node.displayPath
            .. " refused a secret key: saved variables never hold secret values"
    end
    -- Every table is scanned, whether or not the host has secret values: a
    -- view stored in a saved table would alias another view's data and be
    -- written through without validation, and a metatable never survives a
    -- save.
    local problem = nil
    if isSecretValue ~= nil and isSecretValue(value) then
        problem = "secret"
    elseif type(value) == "table" then
        problem = scanValue(
            value,
            isSecretValue,
            1,
            readMaxDepth(),
            rawget(node.db, "_maxScannedEntries")
        )
    end
    if problem ~= nil then
        return refusalLabel(node) .. node.displayPath .. formatKey(key) .. VALUE_REFUSALS[problem]
    end

    local ok, failure = checkWrite(node, key, value)
    if not ok then
        ---@cast failure SchemaKit.Failure
        return failureMessage(node, failure)
    end

    if type(value) ~= "nil" then
        local fullMap = findFullMap(node, key)
        if fullMap ~= nil then
            return refusalLabel(node)
                .. fullMap.displayPath
                .. ": expected at most "
                .. fullMap.plan.max
                .. " entries"
        end
    end
    return nil
end

---Validate and store `node[key] = value`, then fire the scope's change signal.
---Every refusal is raised at the writing line: this function is called by
---`viewNewIndex`, which is called by the writer, so the level is 3.
---
---A nil or NaN key never gets here: Lua 5.1 refuses it while looking for the
---slot, before it consults `__newindex`.
---@param node table
---@param key any
---@param value any
local function writeView(node, key, value)
    local refusal = refuseWrite(node, key, value)
    if refusal ~= nil then
        error(refusal, 3)
    end

    local container
    if type(value) == "nil" then
        container = resolveContainer(node)
    else
        container = resolveForWrite(node)
    end
    if container ~= nil then
        rawset(container, key, value)
    end

    local scope = node.scope
    scope.signal:Fire(node.db, scope.name, key, value, node.path)
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
                + compactValue(
                    plan.fields[name],
                    container,
                    name,
                    value,
                    default,
                    isSecretValue,
                    maxDepth
                )
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
            removed = removed
                + compactRecord(plan, container, plan.ownDefaults, isSecretValue, maxDepth)
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

---Build the `PLAYER_LOGOUT` listener of one database. It calls through the
---shared dispatch table so an upgrade replaces its behaviour.
---@param db table
---@return fun()
local function newLogoutListener(db)
    return function()
        local compactOnLogout = rawget(dispatch, "compactOnLogout")
        compactOnLogout(db)
    end
end

---Compact at logout. A failure is reported, never raised into EventKit's
---dispatch, so one addon's database cannot stop another's compaction.
---@param db table
local function compactOnLogout(db)
    local ok, failure = pcall(compactDatabase, db)
    if not ok then
        reportError(failure)
    end
end

---Connect the logout compaction when EventKit is embedded. The connection is
---not kept: a database lives for the session and is never disconnected, and
---EventKit holds the listener.
---@param db table
local function connectLogout(db)
    local findPackage = rawget(Registry, "Find")
    if type(findPackage) ~= "function" then
        return
    end
    local EventKit = findPackage(Registry, "eventKit", OPTIONAL_EVENTKIT_API)
    if type(EventKit) ~= "table" or type(rawget(EventKit, "Connect")) ~= "function" then
        return
    end
    EventKit:Connect("PLAYER_LOGOUT", newLogoutListener(db))
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

---Run the migrations between the stored version and `version`, storing the
---version after each step so a failing step is retried and a finished one
---never runs again.
---@param raw table
---@param name string saved-variable name, for messages
---@param version integer|false
---@param migrations table|false
---@param level integer stack level the failures are reported at
local function migrate(raw, name, version, migrations, level)
    if version == false then
        return
    end

    -- A table with nothing in it was never written by an older version.
    if type(next(raw)) == "nil" then
        rawset(raw, "version", version)
        return
    end

    local stored = rawget(raw, "version")
    if type(stored) == "nil" then
        stored = 0
    elseif isSecret(stored) or not isIntegerAtLeast(stored, 0) then
        error("SettingsKit:Open " .. name .. ".version must be a non-negative integer", level)
    end

    for step = stored + 1, version do
        local migration = migrations and rawget(migrations, step)
        if type(migration) ~= "nil" then
            local ok, failure = pcall(migration, raw)
            if not ok then
                if isSecret(failure) then
                    failure = "<secret value>"
                end
                error(
                    "SettingsKit:Open migration "
                        .. step
                        .. " of "
                        .. name
                        .. " failed: "
                        .. tostring(failure),
                    level
                )
            end
        end
        rawset(raw, "version", step)
    end
end

---Create every missing section of the saved table; refuse one that is not a
---table.
---@param raw table
---@param name string saved-variable name, for messages
---@param level integer stack level the failures are reported at
local function ensureLayout(raw, name, level)
    for index = 1, #LAYOUT_SECTIONS do
        local sectionName = LAYOUT_SECTIONS[index]
        local section = rawget(raw, sectionName)
        if type(section) == "nil" then
            rawset(raw, sectionName, {})
        elseif type(section) ~= "table" then
            error("SettingsKit:Open " .. name .. "." .. sectionName .. " must be a table", level)
        end
    end
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
    db._signals.profileChanged:Fire(self, name, previous)
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
    db._signals.profileCopied:Fire(self, from, current)
end

---Remove every value of the current profile, so it reads its defaults again.
---@param self SettingsKit.Database
local function databaseResetProfile(self)
    validateDatabase(self, "SettingsKit.Database:ResetProfile", 3)
    local db = self --[[@as table]]
    local current = db._profile
    ensureProfile(db._raw, current)
    wipe(rawget(rawget(db._raw, "profiles"), current))
    db._signals.profileReset:Fire(self, current)
end

---Delete a profile that is not the current one. Characters that used it fall
---back to the default profile at their next `Open`.
---@param self SettingsKit.Database
---@param name string
local function databaseDeleteProfile(self, name)
    validateDatabase(self, "SettingsKit.Database:DeleteProfile", 3)
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
    db._signals.profileDeleted:Fire(self, name)
end

---Wipe the whole saved variable back to an empty layout. Every profile view
---obtained before is detached; `db.profile` is a new view of the default
---profile.
---@param self SettingsKit.Database
local function databaseResetDatabase(self)
    validateDatabase(self, "SettingsKit.Database:ResetDatabase", 3)
    local db = self --[[@as table]]
    local raw = db._raw
    local previous = db._profile

    wipe(raw)
    if db._version ~= false then
        rawset(raw, "version", db._version)
    end
    ensureLayout(raw, db._name, 3)

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

    db._signals.profileReset:Fire(self, name)
    if name ~= previous then
        db._signals.profileChanged:Fire(self, name, previous)
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
    return rawget(rawget(db, "_signals"), signalName):Connect(callback)
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
    return connectProfileSignal(
        self,
        "profileReset",
        "SettingsKit.Database:OnProfileReset",
        callback
    )
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
    if node == nil or node.db ~= self then
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
                .. node.displayPath
                .. " refused a secret key: saved variables never hold secret values"
    end
    if type(key) == "nil" or key ~= key then
        return nil, refusalLabel(node) .. node.displayPath .. " key must not be nil or NaN"
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
                .. node.displayPath
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
            "SettingsKit (" .. db._name .. ") " .. node.displayPath .. " key must not be nil or NaN"
    end
    refusal = refuseWrite(node, key, value)
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
    local unavailable = rawget(db, "_unavailable")
    local reason = type(unavailable) == "table" and rawget(unavailable, key) or nil
    if reason ~= nil then
        -- databaseIndex <- the reading line
        error(reason, 2)
    end
    return nil
end

---The database metatable's `__newindex`: a database has no writable fields.
local function databaseNewIndex()
    error("SettingsKit databases are read-only; write through db.<scope> instead", 2)
end

-- Package public API ---------------------------------------------------------

---Build the scope records of a database from the validated schema table.
---@param schema table
---@param keys table<string, string|false>
---@param name string saved-variable name, for messages
---@param level integer stack level the failures are reported at
---@return table scopes, table unavailable
local function buildScopes(schema, keys, name, level)
    local scopes = {}
    local unavailable = {}
    local sealSchema = rawget(SchemaKit, "Seal")
    for index = 1, #SCOPE_NAMES do
        local scopeName = SCOPE_NAMES[index]
        local node = rawget(schema, scopeName)
        if type(node) == "nil" then
            unavailable[scopeName] = "SettingsKit ("
                .. name
                .. ") db."
                .. scopeName
                .. " is not declared; pass schema."
                .. scopeName
                .. " to SettingsKit:Open"
        else
            -- Sealing a sealed schema returns a new one with its own failure
            -- table, so a consumer checking with the same schema can never see
            -- its failure overwritten by a write here.
            local sealed = sealSchema(SchemaKit, node)
            local description = sealed:Describe()
            if description.kind ~= "table" then
                error(
                    "SettingsKit:Open schema." .. scopeName .. " must be a SchemaKit.table schema",
                    level
                )
            end
            local plan, refusal =
                compilePlan(description, 1, "schema." .. scopeName, readMaxDepth())
            if plan == nil then
                error("SettingsKit:Open " .. tostring(refusal), level)
            end

            ---@type string|false
            local sectionKey = false
            local available = true
            if scopeName ~= "global" and scopeName ~= "profile" then
                sectionKey = keys[scopeName]
                available = sectionKey ~= false
            end
            if not available then
                unavailable[scopeName] = "SettingsKit ("
                    .. name
                    .. ") db."
                    .. scopeName
                    .. " is unavailable: "
                    .. UNAVAILABLE_REASONS[scopeName]
                    .. " when the database was opened"
            end

            scopes[scopeName] = {
                name = scopeName,
                schema = sealed,
                plan = plan,
                sectionName = SCOPE_SECTIONS[scopeName],
                sectionKey = sectionKey,
                available = available,
                signal = available and SignalKit:New() or false,
            }
        end
    end
    return scopes, unavailable
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
                "SettingsKit:Open "
                    .. savedVariable
                    .. " is already open with a different schema table",
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
    local defaultProfile, version, migrations, maxScannedEntries = readOptions(options, 3)

    local raw = readGlobal(savedVariable)
    if type(raw) ~= "nil" and type(raw) ~= "table" then
        error("SettingsKit:Open " .. savedVariable .. " must be a table or nil", 2)
    end

    -- Scope keys are read once, before anything is written, so a schema or
    -- layout refusal leaves the saved variable untouched.
    local keys = readScopeKeys()
    local scopes, unavailable = buildScopes(schema, keys, savedVariable, 3)

    if type(raw) == "nil" then
        raw = {}
        writeGlobal(savedVariable, raw)
    end
    migrate(raw, savedVariable, version, migrations, 3)
    ensureLayout(raw, savedVariable, 3)

    local charKey = keys.char
    local resolvedDefault = defaultProfile
    if defaultProfile == CHARACTER_PROFILE then
        resolvedDefault = charKey or DEFAULT_PROFILE_NAME
    end
    local profileName = resolvedDefault
    if charKey ~= false then
        local stored = rawget(rawget(raw, "profileKeys"), charKey)
        if isStoredProfileName(stored) then
            profileName = stored
        end
    end
    ensureProfile(raw, profileName)

    local db = setmetatable({
        _layout = DATABASE_SCHEMA,
        _name = savedVariable,
        _raw = raw,
        _schemaSource = schema,
        _scopes = scopes,
        _unavailable = unavailable,
        _charKey = charKey,
        _defaultProfile = resolvedDefault,
        _profile = profileName,
        _profileRoots = {},
        _version = version,
        -- `math.huge` when opened with `maxScannedEntries = SettingsKit.UNBOUNDED`.
        _maxScannedEntries = maxScannedEntries,
        _signals = {
            profileChanged = SignalKit:New(),
            profileCopied = SignalKit:New(),
            profileReset = SignalKit:New(),
            profileDeleted = SignalKit:New(),
        },
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
            error(
                "SettingsKit:SetLimits limits." .. tostring(key) .. " is not a recognised limit",
                level
            )
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

-- Revision 1 gave an entry view of a keyed section declared without a default
-- `false` for its defaults, and passed that `false` on to the record views
-- below it, so those views read `nil` where the wildcard and field defaults
-- apply. Their nodes survive the upgrade in `state.views`; recompute every
-- node's defaults the way `viewDefaults` builds them now. A node revision 1
-- built correctly gets the same table back.
if previousRevision ~= nil and previousRevision < 2 then
    local repaired = {}
    for _, node in next, views do
        repairNodeDefaults(node, repaired)
    end
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
rawset(state, "runtimeRevision", IMPLEMENTATION_REVISION)

if not validatePublicSurface(SettingsKit) or not validateCurrentState(SettingsKit) then
    error("MoltenCodes SettingsKit package state is corrupted or incomplete", 2)
end

return SettingsKit
