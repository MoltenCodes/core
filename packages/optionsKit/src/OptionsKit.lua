-- MoltenCodes OptionsKit
--
-- A typed, validated, introspectable options tree for World of Warcraft addons,
-- with no renderer. An addon declares what it exposes as configurable once, as
-- a tree of groups and typed options; OptionsKit checks the tree when it is
-- defined, builds a SchemaKit schema for every value-carrying option, and then
-- answers the three questions every front end asks: what is there (`Walk`,
-- `Describe`), what is it now (`Get`) and may it become this (`Set`,
-- `Validate`). A dialog (WidgetKit) and a command line (CommandKit) read the
-- same tree.
--
-- An option's value is read and written either through the addon's own
-- `get(info)` / `set(info, value)` functions or through `bind =
-- "profile.path.to.value"`, which walks a SettingsKit database passed to
-- `Define` as `options.db`. `ProfileOptions(db)` builds a ready-made group
-- over a SettingsKit database's profiles from these same kinds.
--
-- OptionsKit requires Registry API 2, SchemaKit API 1 and SignalKit API 1.
-- SettingsKit API 1 is optional and found through `Registry:Find` only when
-- `Define` receives `options.db` or `ProfileOptions` is called.
--
-- Contents
-- --------
--   Constants ............. identity, bounds, kinds, accepted fields, method lists
--   Public types .......... LuaCATS declarations for the published surface
--   Dependencies .......... Registry, SchemaKit, SignalKit, the secret probe
--   Validation ............ public-surface and shared-state predicates
--   Bootstrap ............. Registry registration and inherited state
--   Argument checks ....... receivers, names, paths, option tables
--   Definition checks ..... one function per field family of an option
--   Schemas ............... the SchemaKit schema of each value kind
--   Building .............. option records, the path index, sorted children
--   Bound values .......... reading and writing a SettingsKit database path
--   Tree methods .......... the handle `Define` returns
--   Describe .............. the plain, allocating snapshot for renderers
--   Profile options ....... the ready-made group over a database's profiles
--   Package public API .... the facade published through Registry
--   Commit ................ prototype/facade assignment and self-check
--
-- Layout and invariants are described in `docs/INTERNALS.md`.

-- Constants ------------------------------------------------------------------

local PACKAGE_NAME = "optionsKit"
local API_GENERATION = 1
local IMPLEMENTATION_REVISION = 3
local REQUIRED_REGISTRY_API = 2
local REQUIRED_SCHEMAKIT_API = 1
local REQUIRED_SIGNALKIT_API = 1
local OPTIONAL_SETTINGSKIT_API = 1
local STATE_SCHEMA = 1

-- Every tree records the layout it was built with, so a later revision that
-- changes the layout can upgrade old trees instead of guessing from which
-- fields exist. Layout 2 (revision 2) added `_profileLinks`.
local TREE_SCHEMA = 2

-- The default of `Define`'s `maxOptions`: the most options one tree holds,
-- counting groups and everything below the root. A tree is walked and described
-- in full by every renderer, so a huge one is a visible hitch on the first
-- options screen; the tree is the consumer's own data, so the consumer may
-- raise the bound or lift it with `OptionsKit.UNBOUNDED`.
local MAX_OPTIONS = 1024

-- The default of `Define`'s `maxDepth`: the most keys an option's path may
-- have. Real trees are three or four levels deep; the bound also turns a
-- cyclic tree into an error instead of a stack overflow.
local MAX_DEPTH = 8

-- The highest `maxDepth` a tree may ask for. `Define` builds and `Describe`
-- describes a tree by recursion, several Lua and C frames per level, so the
-- depth is paid on the Lua stack and is never unbounded.
local MAX_DEPTH_CEILING = 32

-- The order an option without `order` sorts at, as in AceConfig.
local DEFAULT_ORDER = 100

-- The default of `Define`'s `maxDynamicEntries`: the most entries a static
-- `values` table may have, and the bound the `SchemaKit.map` of a multiselect
-- whose values come from a function gets, because such values cannot be
-- counted at Define.
local MAX_DYNAMIC_ENTRIES = 1024

-- `SchemaKit.map` requires an integer bound, so a tree opened with
-- `maxDynamicEntries = OptionsKit.UNBOUNDED` gives a multiselect over a values
-- function this one. Every key must still be a key of the function's current
-- table, so the function's own table is the real bound.
local UNBOUNDED_MAP_MAX = 2147483647

-- Option kinds.
local KIND_GROUP = "group"
local KIND_TOGGLE = "toggle"
local KIND_RANGE = "range"
local KIND_SELECT = "select"
local KIND_MULTISELECT = "multiselect"
local KIND_INPUT = "input"
local KIND_COLOR = "color"
local KIND_KEYBINDING = "keybinding"
local KIND_EXECUTE = "execute"
local KIND_HEADER = "header"
local KIND_DESCRIPTION = "description"

-- Kinds that carry a value, and so have a schema and a reader and writer.
local VALUE_KINDS = {
    [KIND_TOGGLE] = true,
    [KIND_RANGE] = true,
    [KIND_SELECT] = true,
    [KIND_MULTISELECT] = true,
    [KIND_INPUT] = true,
    [KIND_COLOR] = true,
    [KIND_KEYBINDING] = true,
}

-- Fields every option accepts.
local COMMON_FIELDS =
    { type = true, name = true, desc = true, order = true, disabled = true, hidden = true }

-- Fields every value-carrying option accepts on top of the common ones.
local VALUE_FIELDS = { get = true, set = true, bind = true, validate = true }

-- Fields each kind accepts on top of the common (and, for value kinds, value)
-- fields. An unknown field is refused at Define: a misspelt `witdh` fails
-- loudly instead of being silently ignored.
local KIND_FIELDS = {
    [KIND_GROUP] = { args = true, inline = true },
    [KIND_TOGGLE] = { tristate = true },
    [KIND_RANGE] = {
        min = true,
        max = true,
        step = true,
        softMin = true,
        softMax = true,
        bigStep = true,
        isPercent = true,
    },
    [KIND_SELECT] = { values = true, sorting = true },
    [KIND_MULTISELECT] = { values = true, sorting = true },
    [KIND_INPUT] = { pattern = true, multiline = true, usage = true },
    [KIND_COLOR] = { hasAlpha = true },
    [KIND_KEYBINDING] = {},
    [KIND_EXECUTE] = { func = true, confirm = true },
    [KIND_HEADER] = {},
    [KIND_DESCRIPTION] = { fontSize = true },
}

-- The SettingsKit scopes a `bind` path may start with.
local BIND_SCOPES =
    { global = true, char = true, realm = true, class = true, faction = true, profile = true }

-- The accepted `description.fontSize` values.
local FONT_SIZES = { small = true, medium = true, large = true }

-- The complete set of fields `Define` options accept.
local DEFINE_OPTION_KEYS =
    { db = true, maxOptions = true, maxDepth = true, maxDynamicEntries = true }

-- An option key or a bind path segment: an identifier, so a dotted path can
-- never be ambiguous.
local KEY_PATTERN = "^[%a_][%w_]*$"

-- The published surface, listed once so the public-surface predicate reads as
-- a checklist instead of a long boolean expression.
local FACADE_METHODS = { "Define", "Get", "Undefine", "ProfileOptions" }
local TREE_METHODS = {
    "Get",
    "Set",
    "Validate",
    "Reset",
    "Execute",
    "IsDisabled",
    "IsHidden",
    "Walk",
    "Describe",
    "OnChange",
}

-- Public types ---------------------------------------------------------------
--
-- OptionsKit publishes its methods by writing them onto a Registry-owned
-- prototype table, so the editor-facing contract is declared here as LuaCATS
-- classes rather than inferred from those assignments.

---What an option is.
---@alias OptionsKit.Kind "group"|"toggle"|"range"|"select"|"multiselect"|"input"|"color"|"keybinding"|"execute"|"header"|"description"

---The context every option callback receives. One table per option, built at
---`Define` and handed to every call for that option: do not keep it after the
---call returns and do not modify it.
---@class OptionsKit.Info
---@field [integer] string The option's key path: `info[1]` is the top-level key, `info[#info]` the option's own key.
---@field path string The dotted path, `""` for the root group.
---@field kind OptionsKit.Kind
---@field tree OptionsKit.Tree The tree the option belongs to.

---A flag that is fixed, or decided per call.
---@alias OptionsKit.Predicate boolean|fun(info: OptionsKit.Info): boolean

---One node of the tree passed to `Define`. Which fields apply depends on
---`type`; `docs/API.md` lists them per kind. The table is read once at
---`Define`: later edits to it have no effect.
---@class OptionsKit.Option
---@field type OptionsKit.Kind
---@field name string? Label. Required except on the root group.
---@field desc (string|fun(info: OptionsKit.Info): string)? Longer help text, or a function `Describe` calls for it, so the text can follow the current state.
---@field order number? Sort position among siblings, default 100; ties sort by name, then key.
---@field disabled OptionsKit.Predicate? A disabled group disables everything below it.
---@field hidden OptionsKit.Predicate? A hidden group hides everything below it.
---@field args table<string, OptionsKit.Option>? `group`: the children, by key.
---@field inline boolean? `group`: a renderer draws it inside its parent.
---@field get fun(info: OptionsKit.Info): any Value kinds: the reader, with `set`.
---@field set fun(info: OptionsKit.Info, value: any) Value kinds: the writer, with `get`.
---@field bind string? Value kinds: `"profile.path.to.value"` into `options.db`, instead of `get`/`set`.
---@field validate fun(info: OptionsKit.Info, value: any): boolean, string? Value kinds: a check after the schema.
---@field tristate boolean? `toggle`: `nil` is a third state.
---@field min number? `range`
---@field max number? `range`
---@field step number? `range`
---@field softMin number? `range`
---@field softMax number? `range`
---@field bigStep number? `range`
---@field isPercent boolean? `range`
---@field values table<string|number, string>|fun(info: OptionsKit.Info): table<string|number, string> `select`, `multiselect`: key to label.
---@field sorting (string|number)[]? `select`, `multiselect`: display order of the keys.
---@field pattern string? `input`: a Lua pattern the text must contain.
---@field multiline boolean? `input`
---@field usage string? `input`: what to type, for a command line.
---@field hasAlpha boolean? `color`: the value has an `a` field.
---@field func fun(info: OptionsKit.Info)? `execute`: what runs.
---@field confirm boolean|string? `execute`: a renderer asks first; a string is the question.
---@field fontSize "small"|"medium"|"large"? `description`

---Option table accepted by `OptionsKit:Define`.
---@class OptionsKit.DefineOptions
---@field db table? A SettingsKit API 1 database; required when any option uses `bind`.
---@field maxOptions (integer|table)? The most options the tree holds below the root: a positive integer or `OptionsKit.UNBOUNDED`; default `1024`.
---@field maxDepth integer? The most keys an option path has: an integer from `1` to `32`; default `8`. `UNBOUNDED` is refused: the tree is built recursively on the Lua stack.
---@field maxDynamicEntries (integer|table)? The most entries of a `values` table, and the map bound of a multiselect over a values function: a positive integer or `OptionsKit.UNBOUNDED`; default `1024`.

---The hook `ProfileOptions` passes every user-visible string through:
---`key` names the string (`docs/API.md` lists the keys) and `default` is its
---English text. A string result is used; anything else keeps the default.
---@alias OptionsKit.Localize fun(key: string, default: string): string?

---Option table accepted by `OptionsKit:ProfileOptions`.
---@class OptionsKit.ProfileOptionsOptions
---@field name string? The group's label; default the localised `group.name`, "Profiles".
---@field order number? The group's sort position among its siblings; default `100`.
---@field description string? The introduction text shown above the options; default the localised `intro`.
---@field localize OptionsKit.Localize? Translates the group's strings.

---One node of `tree:Describe()`. Every table in it is fresh.
---@class OptionsKit.Description
---@field kind OptionsKit.Kind
---@field key string? Absent on the root.
---@field path string
---@field depth integer `0` for the root.
---@field name string
---@field desc string?
---@field order number
---@field disabled boolean Effective: an ancestor's flag counts.
---@field hidden boolean Effective: an ancestor's flag counts.
---@field addonName string? Root only.
---@field children OptionsKit.Description[]? `group`: sorted.
---@field inline boolean? `group`
---@field value any Value kinds: the current value.
---@field schema table? Value kinds: `schema:Describe()` of the option's schema.
---@field bind string? Value kinds bound to a database.

---A callback `OnChange` connects: the tree, the option's path and the value
---set (after `Reset`, the value read back).
---@alias OptionsKit.ChangeCallback fun(tree: OptionsKit.Tree, path: string, value: any)

---A defined options tree.
---@class OptionsKit.Tree
---@field Get fun(self: OptionsKit.Tree, path: string): any
---@field Set fun(self: OptionsKit.Tree, path: string, value: any): boolean, string?
---@field Validate fun(self: OptionsKit.Tree, path: string, value: any): boolean, string?
---@field Reset fun(self: OptionsKit.Tree, path: string): any
---@field Execute fun(self: OptionsKit.Tree, path: string)
---@field IsDisabled fun(self: OptionsKit.Tree, path: string): boolean
---@field IsHidden fun(self: OptionsKit.Tree, path: string): boolean
---@field Walk fun(self: OptionsKit.Tree, visitor: fun(path: string, kind: OptionsKit.Kind, depth: integer)): integer
---@field Describe fun(self: OptionsKit.Tree): OptionsKit.Description
---@field OnChange fun(self: OptionsKit.Tree, callback: OptionsKit.ChangeCallback): table

---The OptionsKit package facade published through Registry.
---@class OptionsKit
---@field API integer Public API generation.
---@field REVISION integer Compatible implementation revision.
---@field MAX_OPTIONS integer Default of `maxOptions`: the most options one tree holds.
---@field MAX_DEPTH integer Default of `maxDepth`: the most keys an option path has.
---@field UNBOUNDED table Sentinel `maxOptions` and `maxDynamicEntries` accept to lift the bound; one table shared by every revision.
---@field Tree OptionsKit.Tree Shared tree prototype.
---@field Define fun(self: OptionsKit, addonName: string, tree: OptionsKit.Option, options: OptionsKit.DefineOptions?): OptionsKit.Tree
---@field Get fun(self: OptionsKit, addonName: string): OptionsKit.Tree?
---@field Undefine fun(self: OptionsKit, addonName: string): boolean
---@field ProfileOptions fun(self: OptionsKit, db: table, options: OptionsKit.ProfileOptionsOptions?): OptionsKit.Option

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
    error("MoltenCodes OptionsKit requires Registry API 2 to be loaded first", 2)
end

local bootstrapPackage = rawget(Registry, "Bootstrap")
local getPackage = rawget(Registry, "Get")
if type(bootstrapPackage) ~= "function" or type(getPackage) ~= "function" then
    error("MoltenCodes OptionsKit requires a valid Registry API 2 facade", 2)
end

-- SchemaKit and SignalKit are required: every value option has a schema and
-- every tree a change signal. Both are checked at load, so a missing one fails
-- loudly at this file instead of at the first `Define`.
local SchemaKit = getPackage(Registry, "schemaKit", REQUIRED_SCHEMAKIT_API)
if
    type(SchemaKit) ~= "table"
    or rawget(SchemaKit, "API") ~= REQUIRED_SCHEMAKIT_API
    or type(rawget(SchemaKit, "Seal")) ~= "function"
    or type(rawget(SchemaKit, "boolean")) ~= "function"
    or type(rawget(SchemaKit, "number")) ~= "function"
    or type(rawget(SchemaKit, "string")) ~= "function"
    or type(rawget(SchemaKit, "enum")) ~= "function"
    or type(rawget(SchemaKit, "table")) ~= "function"
    or type(rawget(SchemaKit, "map")) ~= "function"
    or type(rawget(SchemaKit, "optional")) ~= "function"
    or type(rawget(SchemaKit, "custom")) ~= "function"
then
    error("MoltenCodes OptionsKit requires SchemaKit API 1 to be loaded first", 2)
end

local SignalKit = getPackage(Registry, "signalKit", REQUIRED_SIGNALKIT_API)
if
    type(SignalKit) ~= "table"
    or rawget(SignalKit, "API") ~= REQUIRED_SIGNALKIT_API
    or type(rawget(SignalKit, "New")) ~= "function"
    or type(rawget(SignalKit, "Connect")) ~= "function"
    or type(rawget(SignalKit, "Fire")) ~= "function"
    or type(rawget(SignalKit, "DisconnectAll")) ~= "function"
then
    error("MoltenCodes OptionsKit requires SignalKit API 1 to be loaded first", 2)
end

---Whether `value` is a secret value (Retail 12.x).
---
---`issecretvalue` is read from the global table at every call, as SchemaKit
---reads it, so a probe that appears after load is used at once. It costs one
---`rawget` per call and allocates nothing.
---@param value any
---@return boolean
local function isSecret(value)
    -- issecretvalue is a World of Warcraft client API reachable only through the global table.
    -- selene: allow(global_usage)
    local probe = rawget(_G, "issecretvalue")
    return type(probe) == "function" and probe(value) == true
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

---Whether `implementation` exposes the complete OptionsKit API 1 surface.
---@param implementation any shared package table handed back by Registry
---@return boolean
local function validatePublicSurface(implementation)
    if
        type(implementation) ~= "table"
        or rawget(implementation, "API") ~= API_GENERATION
        or type(rawget(implementation, "REVISION")) ~= "number"
        or type(rawget(implementation, "MAX_OPTIONS")) ~= "number"
        or type(rawget(implementation, "MAX_DEPTH")) ~= "number"
        or type(rawget(implementation, "Tree")) ~= "table"
        or type(rawget(implementation, "UNBOUNDED")) ~= "table"
    then
        return false
    end

    return hasMethods(implementation, FACADE_METHODS)
        and hasMethods(rawget(implementation, "Tree"), TREE_METHODS)
end

---Whether `currentState` has the fields every API 1 revision shares.
---@param currentState any
---@return boolean
local function validateStateBase(currentState)
    return type(currentState) == "table"
        and rawget(currentState, "schema") == STATE_SCHEMA
        and type(rawget(currentState, "runtimeRevision")) == "number"
        and type(rawget(currentState, "treeMetatable")) == "table"
        and type(rawget(currentState, "trees")) == "table"
        and type(rawget(currentState, "unbounded")) == "table"
end

---Whether `implementation` carries package state of this revision's schema,
---and publishes the sentinel that state keeps.
---@param implementation table
---@return boolean
local function validateCurrentState(implementation)
    local currentState = rawget(implementation, "_state")
    return validateStateBase(currentState)
        and rawget(implementation, "UNBOUNDED") == rawget(currentState, "unbounded")
        and type(rawget(currentState, "profileGroups")) == "table"
end

-- Bootstrap ------------------------------------------------------------------

-- `Registry:Bootstrap` owns the reconciliation every embedded package repeats:
-- look the package up, refuse to reinterpret state owned by a newer revision,
-- and register this one. What stays here is what only OptionsKit can answer.
local OptionsKit, previousRevision, selected = bootstrapPackage(Registry, {
    package = PACKAGE_NAME,
    api = API_GENERATION,
    revision = IMPLEMENTATION_REVISION,
    label = "MoltenCodes OptionsKit",
    validatePublicSurface = validatePublicSurface,
    validateState = validateCurrentState,
})

if OptionsKit == nil then
    -- An equal or newer compatible revision already owns the shared package table.
    return selected
end

local Tree = rawget(OptionsKit, "Tree")
local state = rawget(OptionsKit, "_state")

if previousRevision == nil then
    if Tree ~= nil or state ~= nil then
        error("MoltenCodes OptionsKit package state is corrupted or incomplete", 2)
    end

    Tree = {}
    state = {
        schema = STATE_SCHEMA,
        runtimeRevision = 0,
        treeMetatable = {},
        -- Addon name to that addon's tree. At most one per addon name.
        trees = {},
        -- `OptionsKit.UNBOUNDED` lives here so every revision publishes the
        -- same table and a `Define` option written against one copy keeps its
        -- meaning after an upgrade.
        unbounded = {},
        -- The group table `ProfileOptions` returned to the link record behind
        -- it, so `Define` recognises the group when it meets it in a tree.
        -- Weak keys: a group the consumer dropped is forgotten with it.
        profileGroups = setmetatable({}, { __mode = "k" }),
    }
    rawset(OptionsKit, "Tree", Tree)
    rawset(OptionsKit, "_state", state)
elseif type(Tree) ~= "table" or not validateStateBase(state) then
    error("MoltenCodes OptionsKit package state is corrupted or incomplete", 2)
end

-- Revision 1 had no profile groups and built tree layout 1. The group map is
-- added, and every tree gains the (empty) list of profile links `Undefine`
-- detaches: a revision 1 tree cannot contain a profile group. Revision 3
-- changed no layout, so a revision 2 state needs nothing here.
if rawget(state, "profileGroups") == nil then
    rawset(state, "profileGroups", setmetatable({}, { __mode = "k" }))
end
for _, existingTree in next, rawget(state, "trees") do
    if rawget(existingTree, "_schema") == 1 then
        rawset(existingTree, "_profileLinks", {})
        rawset(existingTree, "_schema", TREE_SCHEMA)
    end
end

-- The metatable and prototype are kept across upgrades, so trees built by an
-- older copy keep their records and gain this copy's methods without being
-- replaced.
local TREE_METATABLE = rawget(state, "treeMetatable")
local trees = rawget(state, "trees")
local UNBOUNDED = rawget(state, "unbounded")
local profileGroups = rawget(state, "profileGroups")
rawset(TREE_METATABLE, "__index", Tree)

-- Argument checks ------------------------------------------------------------
--
-- Argument validation raises with an explicit stack level so the reported
-- position is the line that called the public method, never a line inside
-- OptionsKit. `level` is always the value `error` needs *inside the function
-- that receives it*, so every further hop towards `error` adds exactly one.

---@param addonName any
---@param label string qualified parameter name, used in the argument error
---@param level integer stack level the failure is reported at
local function validateAddonName(addonName, label, level)
    if isSecret(addonName) then
        error(label .. " must not be a secret value", level)
    end
    if type(addonName) ~= "string" or addonName == "" then
        error(label .. " must be a non-empty string", level)
    end
end

---@param tree any receiver the public method was called on
---@param methodName string qualified public method name, used in the argument error
---@param level integer stack level the failure is reported at
local function validateTree(tree, methodName, level)
    if type(tree) ~= "table" or getmetatable(tree) ~= TREE_METATABLE then
        error(methodName .. " must be called on an OptionsKit tree", level)
    end
    if rawget(tree, "_defined") ~= true then
        error(methodName .. " cannot be called on an undefined tree", level)
    end
end

---Return the record at `path`, raising at the caller for a malformed or
---unknown path. Two type tests, one secret probe and one table read.
---@param tree OptionsKit.Tree
---@param path any
---@param methodName string
---@param level integer
---@return table record
local function findRecord(tree, path, methodName, level)
    if isSecret(path) then
        error(methodName .. " path must not be a secret value", level)
    end
    if type(path) ~= "string" then
        error(methodName .. " path must be a string", level)
    end
    local record = rawget(rawget(tree, "_records"), path)
    if record == nil then
        error(methodName .. ' unknown path "' .. path .. '"', level)
    end
    return record
end

---Return the value option at `path`, raising at the caller otherwise.
---@param tree OptionsKit.Tree
---@param path any
---@param methodName string
---@param level integer
---@return table record
local function findValueRecord(tree, path, methodName, level)
    local record = findRecord(tree, path, methodName, level + 1)
    local kind = rawget(record, "_kind")
    if VALUE_KINDS[kind] ~= true then
        error(methodName .. ' path "' .. path .. '" is a ' .. kind .. ", not a value option", level)
    end
    return record
end

-- Definition checks ----------------------------------------------------------
--
-- Every check takes the label of the field it checks, such as
-- `OptionsKit:Define tree.args.general.args.scale.min`, so the message names
-- the whole path to the offending field. Labels are built at Define only.

---@param value any
---@param label string
---@param level integer
local function checkOptionalString(value, label, level)
    if value ~= nil and type(value) ~= "string" then
        error(label .. " must be a string", level)
    end
end

---@param value any
---@param label string
---@param level integer
local function checkOptionalStringOrFunction(value, label, level)
    local valueType = type(value)
    if value ~= nil and valueType ~= "string" and valueType ~= "function" then
        error(label .. " must be a string or a function", level)
    end
end

---@param value any
---@param label string
---@param level integer
local function checkOptionalBoolean(value, label, level)
    if value ~= nil and type(value) ~= "boolean" then
        error(label .. " must be a boolean", level)
    end
end

---@param value any
---@param label string
---@param level integer
local function checkOptionalFunction(value, label, level)
    if value ~= nil and type(value) ~= "function" then
        error(label .. " must be a function", level)
    end
end

---@param value any
---@param label string
---@param level integer
local function checkNumber(value, label, level)
    -- `value ~= value` is true for NaN only.
    if type(value) ~= "number" or value ~= value then
        error(label .. " must be a number", level)
    end
end

---@param value any
---@param label string
---@param level integer
local function checkPositiveNumber(value, label, level)
    if value ~= nil then
        checkNumber(value, label, level + 1)
        if value <= 0 then
            error(label .. " must be greater than 0", level)
        end
    end
end

---@param value any
---@param label string
---@param level integer
local function checkPredicate(value, label, level)
    local valueType = type(value)
    if value ~= nil and valueType ~= "boolean" and valueType ~= "function" then
        error(label .. " must be a boolean or a function", level)
    end
end

---Refuse any field of `spec` that its kind does not accept.
---@param spec table
---@param kind OptionsKit.Kind
---@param label string
---@param level integer
local function checkKnownFields(spec, kind, label, level)
    local kindFields = KIND_FIELDS[kind]
    local isValueKind = VALUE_KINDS[kind] == true
    for field in pairs(spec) do
        if type(field) ~= "string" then
            error(label .. " contains a field that is not a string", level)
        end
        if
            not (COMMON_FIELDS[field] or kindFields[field] or (isValueKind and VALUE_FIELDS[field]))
        then
            error(
                label .. ' contains unknown field "' .. field .. '" for type "' .. kind .. '"',
                level
            )
        end
    end
end

---Check the fields every option shares.
---@param spec table
---@param isRoot boolean
---@param label string
---@param level integer
local function checkCommonFields(spec, isRoot, label, level)
    if isRoot then
        checkOptionalString(spec.name, label .. ".name", level + 1)
    elseif type(spec.name) ~= "string" then
        error(label .. ".name must be a string", level)
    end
    checkOptionalStringOrFunction(spec.desc, label .. ".desc", level + 1)
    if spec.order ~= nil then
        checkNumber(spec.order, label .. ".order", level + 1)
    end
    checkPredicate(spec.disabled, label .. ".disabled", level + 1)
    checkPredicate(spec.hidden, label .. ".hidden", level + 1)
end

---Check a `range` option's bounds.
---@param spec table
---@param label string
---@param level integer
local function checkRangeFields(spec, label, level)
    checkNumber(spec.min, label .. ".min", level + 1)
    checkNumber(spec.max, label .. ".max", level + 1)
    if spec.min > spec.max then
        error(label .. ".min must not be greater than max", level)
    end
    checkPositiveNumber(spec.step, label .. ".step", level + 1)
    checkPositiveNumber(spec.bigStep, label .. ".bigStep", level + 1)
    local softMin = spec.softMin
    local softMax = spec.softMax
    if softMin ~= nil then
        checkNumber(softMin, label .. ".softMin", level + 1)
        if softMin < spec.min or softMin > spec.max then
            error(label .. ".softMin must lie between min and max", level)
        end
    end
    if softMax ~= nil then
        checkNumber(softMax, label .. ".softMax", level + 1)
        if softMax < spec.min or softMax > spec.max then
            error(label .. ".softMax must lie between min and max", level)
        end
    end
    if softMin ~= nil and softMax ~= nil and softMin > softMax then
        error(label .. ".softMin must not be greater than softMax", level)
    end
    checkOptionalBoolean(spec.isPercent, label .. ".isPercent", level + 1)
end

---Check and copy a `values` table: keys are strings or numbers, labels
---strings. Returns the copy and its keys, sorted for a deterministic schema.
---@param values table
---@param maxEntries number the tree's `maxDynamicEntries`, `math.huge` when unbounded
---@param label string
---@param level integer
---@return table copy
---@return (string|number)[] keys
local function copyValues(values, maxEntries, label, level)
    local copy = {}
    local keys = {}
    for key, text in pairs(values) do
        local keyType = type(key)
        if keyType ~= "string" and keyType ~= "number" then
            error(label .. " keys must be strings or numbers", level)
        end
        if type(text) ~= "string" then
            error(label .. " labels must be strings", level)
        end
        copy[key] = text
        keys[#keys + 1] = key
    end
    if #keys == 0 then
        error(label .. " must not be empty", level)
    end
    if #keys > maxEntries then
        error(label .. " must have at most " .. maxEntries .. " entries", level)
    end
    return copy, keys
end

---Check and copy a `sorting` array: every entry a string or number and, when
---the values are a table, one of its keys.
---@param sorting any
---@param values table|false copied values, or `false` when they come from a function
---@param label string
---@param level integer
---@return (string|number)[]|false copy
local function copySorting(sorting, values, label, level)
    if sorting == nil then
        return false
    end
    if type(sorting) ~= "table" then
        error(label .. " must be an array", level)
    end
    local copy = {}
    local count = #sorting
    for index = 1, count do
        local key = sorting[index]
        local keyType = type(key)
        if keyType ~= "string" and keyType ~= "number" then
            error(label .. " entries must be strings or numbers", level)
        end
        if values and values[key] == nil then
            error(label .. " entries must be keys of values", level)
        end
        copy[index] = key
    end
    for key in pairs(sorting) do
        if type(key) ~= "number" or key < 1 or key > count or key % 1 ~= 0 then
            error(label .. " must be an array", level)
        end
    end
    return copy
end

---Parse `bind` into its scope and keys. Returns the scope name and an array of
---at least one key.
---@param bind any
---@param label string
---@param level integer
---@return string scope
---@return string[] keys
local function parseBind(bind, label, level)
    if type(bind) ~= "string" then
        error(label .. " must be a string", level)
    end
    local scope = nil
    local keys = {}
    for segment in (bind .. "."):gmatch("([^.]*)%.") do
        if not segment:find(KEY_PATTERN) then
            error(label .. ' "' .. bind .. '" must be dot-separated identifiers', level)
        end
        if scope == nil then
            scope = segment
        else
            keys[#keys + 1] = segment
        end
    end
    if scope == nil or BIND_SCOPES[scope] ~= true then
        error(
            label
                .. ' "'
                .. bind
                .. '" must start with global, char, realm, class, faction or profile',
            level
        )
    end
    if #keys == 0 then
        error(label .. ' "' .. bind .. '" must name a value inside the scope', level)
    end
    return scope, keys
end

-- Schemas --------------------------------------------------------------------

local UNIT_INTERVAL = SchemaKit.number({ min = 0, max = 1 })

---Build the check a `select` key must pass when the values come from a
---function: the key is a string or number the function's current table has.
---@param valuesFunction fun(info: OptionsKit.Info): table
---@param info OptionsKit.Info
---@return fun(value: any): boolean
local function newDynamicKeyCheck(valuesFunction, info)
    return function(value)
        local valueType = type(value)
        if valueType ~= "string" and valueType ~= "number" then
            return false
        end
        local values = valuesFunction(info)
        return type(values) == "table" and values[value] ~= nil
    end
end

---Build the SchemaKit node describing the keys of a `select` or `multiselect`.
---@param keys (string|number)[]|false
---@param valuesFunction function|false
---@param info OptionsKit.Info
---@return table node
local function buildKeyNode(keys, valuesFunction, info)
    if keys then
        return SchemaKit.enum(keys)
    end
    ---@cast valuesFunction fun(info: OptionsKit.Info): table
    return SchemaKit.custom(
        newDynamicKeyCheck(valuesFunction, info),
        "a key of the values of " .. info.path
    )
end

---Build the sealed schema of a value option.
---@param kind OptionsKit.Kind
---@param spec table
---@param keys (string|number)[]|false keys of a `select`/`multiselect` values table
---@param valuesFunction function|false a `select`/`multiselect` values function
---@param info OptionsKit.Info
---@param dynamicMax integer the map bound of a multiselect over a values function
---@param label string
---@param level integer
---@return table schema
local function buildSchema(kind, spec, keys, valuesFunction, info, dynamicMax, label, level)
    local node
    if kind == KIND_TOGGLE then
        node = SchemaKit.boolean()
        if spec.tristate then
            node = SchemaKit.optional(node)
        end
    elseif kind == KIND_RANGE then
        node = SchemaKit.number({ min = spec.min, max = spec.max })
    elseif kind == KIND_SELECT then
        node = buildKeyNode(keys, valuesFunction, info)
    elseif kind == KIND_MULTISELECT then
        node = SchemaKit.map({
            keys = buildKeyNode(keys, valuesFunction, info),
            values = SchemaKit.boolean(),
            max = keys and #keys or dynamicMax,
        })
    elseif kind == KIND_INPUT then
        if spec.pattern == nil then
            node = SchemaKit.string()
        else
            -- SchemaKit validates the pattern and would report it at this
            -- line; the protected call moves the report to the caller.
            local built, result = pcall(SchemaKit.string, { pattern = spec.pattern })
            if not built then
                error(label .. ".pattern is not a valid Lua pattern", level)
            end
            node = result
        end
    elseif kind == KIND_COLOR then
        local fields = { r = UNIT_INTERVAL, g = UNIT_INTERVAL, b = UNIT_INTERVAL }
        if spec.hasAlpha then
            fields.a = UNIT_INTERVAL
        end
        node = SchemaKit.table({ fields = fields })
    else
        node = SchemaKit.string()
    end
    return SchemaKit:Seal(node)
end

-- Building -------------------------------------------------------------------

---Orders siblings by `order`, then name, then key. Plain data only: no
---consumer code runs inside `table.sort`.
---@param left table
---@param right table
---@return boolean
local function compareRecords(left, right)
    local leftOrder = rawget(left, "_order")
    local rightOrder = rawget(right, "_order")
    if leftOrder ~= rightOrder then
        return leftOrder < rightOrder
    end
    local leftName = rawget(left, "_name")
    local rightName = rawget(right, "_name")
    if leftName ~= rightName then
        return leftName < rightName
    end
    return rawget(left, "_key") < rawget(right, "_key")
end

---Build the info table of an option: its key path, dotted path, kind and tree.
---@param parent table|false parent record
---@param key string|false
---@param path string
---@param kind OptionsKit.Kind
---@param tree OptionsKit.Tree
---@return OptionsKit.Info
local function newInfo(parent, key, path, kind, tree)
    local info = { path = path, kind = kind, tree = tree }
    if parent then
        local parentInfo = rawget(parent, "_info")
        for index = 1, #parentInfo do
            info[index] = parentInfo[index]
        end
        info[#parentInfo + 1] = key
    end
    return info
end

---Fill the value fields of a record: schema, reader and writer, validator.
---@param context table build context
---@param record table
---@param spec table
---@param label string
---@param level integer
local function buildValueFields(context, record, spec, label, level)
    local kind = rawget(record, "_kind")
    local info = rawget(record, "_info")

    if spec.bind ~= nil then
        if spec.get ~= nil or spec.set ~= nil then
            error(label .. " must use either bind or get and set, not both", level)
        end
        local db = context.db
        if not db then
            error(label .. ".bind needs a SettingsKit database passed as options.db", level)
        end
        local scope, keys = parseBind(spec.bind, label .. ".bind", level + 1)
        -- `rawget`: SettingsKit raises at its own line when an undeclared or
        -- unavailable scope is read through the database's metatable.
        if type(rawget(db, scope)) ~= "table" then
            error(
                label .. '.bind scope "' .. scope .. '" is not an available scope of options.db',
                level
            )
        end
        rawset(record, "_bind", spec.bind)
        rawset(record, "_bindScope", scope)
        rawset(record, "_bindKeys", keys)
        rawset(record, "_bindCount", #keys)
    else
        if type(spec.get) ~= "function" or type(spec.set) ~= "function" then
            error(label .. " needs get and set functions, or bind", level)
        end
        rawset(record, "_get", spec.get)
        rawset(record, "_set", spec.set)
    end

    checkOptionalFunction(spec.validate, label .. ".validate", level + 1)
    rawset(record, "_validate", spec.validate or false)

    local keys = false ---@type (string|number)[]|false
    local valuesFunction = false ---@type function|false
    if kind == KIND_TOGGLE then
        checkOptionalBoolean(spec.tristate, label .. ".tristate", level + 1)
    elseif kind == KIND_RANGE then
        checkRangeFields(spec, label, level + 1)
    elseif kind == KIND_SELECT or kind == KIND_MULTISELECT then
        local values = spec.values
        local copied = false ---@type table|false
        if type(values) == "function" then
            valuesFunction = values
        elseif type(values) == "table" then
            copied, keys =
                copyValues(values, context.maxDynamicEntries, label .. ".values", level + 1)
            table.sort(keys, function(left, right)
                if type(left) == type(right) then
                    return left < right
                end
                return type(left) == "number"
            end)
        else
            error(label .. ".values must be a table or a function", level)
        end
        rawset(record, "_values", copied or valuesFunction)
        rawset(
            record,
            "_sorting",
            copySorting(spec.sorting, copied, label .. ".sorting", level + 1)
        )
    elseif kind == KIND_INPUT then
        checkOptionalString(spec.pattern, label .. ".pattern", level + 1)
        checkOptionalBoolean(spec.multiline, label .. ".multiline", level + 1)
        checkOptionalString(spec.usage, label .. ".usage", level + 1)
    elseif kind == KIND_COLOR then
        checkOptionalBoolean(spec.hasAlpha, label .. ".hasAlpha", level + 1)
    end

    local dynamicMax = context.maxDynamicEntries
    if dynamicMax == math.huge then
        dynamicMax = UNBOUNDED_MAP_MAX
    end
    rawset(
        record,
        "_schema",
        buildSchema(kind, spec, keys, valuesFunction, info, dynamicMax, label, level + 1)
    )
    -- Prebuilt so a failing `Set` names the option without building a string
    -- on the valid path.
    rawset(record, "_setArgument", "OptionsKit.Tree:Set " .. rawget(record, "_path"))
end

---Copy the renderer hints of a kind into the record, for `Describe`.
---@param record table
---@param spec table
local function copyHints(record, spec)
    local kind = rawget(record, "_kind")
    local hints = {}
    local fields = KIND_FIELDS[kind]
    for field in pairs(fields) do
        -- `args` becomes the children, and `values`/`sorting` are copied on
        -- their own; everything else is a plain value.
        if field ~= "args" and field ~= "values" and field ~= "sorting" and field ~= "func" then
            hints[field] = spec[field]
        end
    end
    rawset(record, "_hints", hints)
end

---When `spec` is a group `ProfileOptions` returned, remember its link and
---the path it lands at, so `define` can attach it once the whole tree is
---built. A group already defined in a tree, or appearing twice in this one,
---is refused: its link carries the chosen profiles and the tree it notifies,
---which cannot be shared.
---@param context table
---@param spec table
---@param path string
---@param label string
---@param level integer
local function collectProfileLink(context, spec, path, label, level)
    local link = rawget(profileGroups, spec)
    if link == nil then
        return
    end
    if link.tree then
        error(
            label
                .. ' is a profile group already defined in the tree of "'
                .. rawget(link.tree, "_addonName")
                .. '"; Undefine it first',
            level
        )
    end
    local links = context.profileLinks
    for index = 1, #links do
        if links[index] == link then
            error(label .. " is a profile group that already appears in this tree", level)
        end
    end
    links[#links + 1] = link
    context.profilePaths[#links] = path
end

local buildOption

---Build every child of a group, sort them and link them to the group.
---@param context table
---@param record table the group's record
---@param args any
---@param label string
---@param level integer
local function buildChildren(context, record, args, label, level)
    if type(args) ~= "table" then
        error(label .. ".args must be a table", level)
    end
    local children = {}
    for key, childSpec in pairs(args) do
        if type(key) ~= "string" or not key:find(KEY_PATTERN) then
            error(label .. ".args keys must be identifiers (letters, digits and _)", level)
        end
        children[#children + 1] =
            buildOption(context, childSpec, record, key, label .. ".args." .. key, level + 1)
    end
    table.sort(children, compareRecords)
    rawset(record, "_children", children)
end

---Build the record of one option and, for a group, of everything below it.
---@param context table
---@param spec any
---@param parent table|false
---@param key string|false
---@param label string
---@param level integer
---@return table record
buildOption = function(context, spec, parent, key, label, level)
    if type(spec) ~= "table" then
        error(label .. " must be an option table", level)
    end
    local kind = spec.type
    if type(kind) ~= "string" or KIND_FIELDS[kind] == nil then
        error(label .. '.type must be an option type such as "group" or "toggle"', level)
    end
    checkKnownFields(spec, kind, label, level + 1)

    local isRoot = parent == false
    if isRoot and kind ~= KIND_GROUP then
        error(label .. '.type must be "group" at the root', level)
    end
    checkCommonFields(spec, isRoot, label, level + 1)

    local depth = 0
    local path = ""
    if parent then
        depth = rawget(parent, "_depth") + 1
        if depth > context.maxDepth then
            error(label .. " is deeper than " .. context.maxDepth .. " levels", level)
        end
        context.count = context.count + 1
        if context.count > context.maxOptions then
            error(context.label .. " has more than " .. context.maxOptions .. " options", level)
        end
        local parentPath = rawget(parent, "_path")
        path = parentPath == "" and key or parentPath .. "." .. key
    end

    local record = {
        _kind = kind,
        _key = key,
        _path = path,
        _depth = depth,
        _parent = parent,
        _info = newInfo(parent, key, path, kind, context.tree),
        _name = spec.name or context.addonName,
        _desc = spec.desc or false,
        _order = spec.order or DEFAULT_ORDER,
        _disabled = spec.disabled or false,
        _hidden = spec.hidden or false,
    }
    copyHints(record, spec)

    if kind == KIND_GROUP then
        checkOptionalBoolean(spec.inline, label .. ".inline", level + 1)
        collectProfileLink(context, spec, path, label, level + 1)
        buildChildren(context, record, spec.args, label, level + 1)
    elseif VALUE_KINDS[kind] then
        buildValueFields(context, record, spec, label, level + 1)
    elseif kind == KIND_EXECUTE then
        if type(spec.func) ~= "function" then
            error(label .. ".func must be a function", level)
        end
        local confirm = spec.confirm
        if confirm ~= nil and type(confirm) ~= "boolean" and type(confirm) ~= "string" then
            error(label .. ".confirm must be a boolean or a string", level)
        end
        rawset(record, "_func", spec.func)
    elseif kind == KIND_DESCRIPTION then
        if spec.fontSize ~= nil and FONT_SIZES[spec.fontSize] ~= true then
            error(label .. '.fontSize must be "small", "medium" or "large"', level)
        end
    end

    if parent then
        rawset(context.records, path, record)
    end
    return record
end

---Append `record`'s descendants to `walk` in pre-order.
---@param record table
---@param walk table[]
local function flatten(record, walk)
    local children = rawget(record, "_children")
    if children == nil then
        return
    end
    for index = 1, #children do
        local child = children[index]
        walk[#walk + 1] = child
        flatten(child, walk)
    end
end

-- Bound values ---------------------------------------------------------------

---Store `value` at `container[key]`. A named function rather than a closure,
---so the protected call around a database write allocates nothing.
---@param container table
---@param key string
---@param value any
local function assignField(container, key, value)
    container[key] = value
end

---Strip the `file:line: ` position an error message carries, keeping its text.
---@param message any
---@return string
local function withoutPosition(message)
    local text = tostring(message)
    return (text:gsub("^[^\n]-:%d+: ", "", 1))
end

---Walk a bound option's path through the database's views, reading the scope
---table at call time so a profile switch is seen at once.
---
---Returns the deepest table reached and the index of the key to use in it: the
---last key when every intermediate table exists, otherwise the first key whose
---table does not exist yet. SettingsKit reads a record without a default and
---without saved data as `nil`, so a missing intermediate is an unset value,
---not an error.
---@param tree OptionsKit.Tree
---@param record table
---@param methodName string
---@param level integer
---@return table container
---@return integer index
local function walkBound(tree, record, methodName, level)
    local scope = rawget(record, "_bindScope")
    local container = rawget(rawget(tree, "_db"), scope)
    if type(container) ~= "table" then
        error(
            methodName .. ' bind scope "' .. scope .. '" is not an available scope of the database',
            level
        )
    end
    local keys = rawget(record, "_bindKeys")
    local count = rawget(record, "_bindCount")
    for index = 1, count - 1 do
        local nested = container[keys[index]]
        if nested == nil then
            return container, index
        end
        if type(nested) ~= "table" then
            error(
                methodName
                    .. ' bind path "'
                    .. rawget(record, "_bind")
                    .. '" does not lead to a table',
                level
            )
        end
        container = nested
    end
    return container, count
end

---Ask the database whether writing `value` at a bound option's path would be
---accepted, without writing. The key array split at `Define` is passed as it
---is, which SettingsKit checks without allocating. Returns `true`, or `false`
---and SettingsKit's message: the text `Set` would raise after its prefix.
---@param tree OptionsKit.Tree
---@param record table
---@param value any
---@param methodName string
---@param level integer
---@return boolean accepted
---@return string|nil message
local function validateBound(tree, record, value, methodName, level)
    local db = rawget(tree, "_db")
    local scope = rawget(record, "_bindScope")
    if type(rawget(db, scope)) ~= "table" then
        error(
            methodName .. ' bind scope "' .. scope .. '" is not an available scope of the database',
            level
        )
    end
    local accepted, message = db:Validate(scope, rawget(record, "_bindKeys"), value)
    if accepted == true then
        return true, nil
    end
    return false, withoutPosition(message)
end

---@param tree OptionsKit.Tree
---@param record table
---@param methodName string
---@param level integer
---@return any
local function readValue(tree, record, methodName, level)
    if rawget(record, "_bindScope") then
        local container, index = walkBound(tree, record, methodName, level + 1)
        local count = rawget(record, "_bindCount")
        if index < count then
            return nil
        end
        return container[rawget(record, "_bindKeys")[count]]
    end
    return rawget(record, "_get")(rawget(record, "_info"))
end

---Write a bound value through the database's views. A missing intermediate
---record is written as a nested table holding the value, which SettingsKit
---validates like any other write; clearing a value whose record does not
---exist does nothing. A SettingsKit refusal is raised again at the caller's
---line with its message kept.
---
---The protected write also catches an error from one of SettingsKit's own
---`OnChange` listeners, which runs after the value was stored. Only on that
---failure path, `db:Validate` tells the two apart: it accepts the value when
---the write was not refused, and the listener's error is then re-raised
---unchanged rather than reported as a refusal.
---@param tree OptionsKit.Tree
---@param record table
---@param value any
---@param methodName string
---@param level integer
local function writeBound(tree, record, value, methodName, level)
    local container, index = walkBound(tree, record, methodName, level + 1)
    local keys = rawget(record, "_bindKeys")
    local count = rawget(record, "_bindCount")
    local stored = value
    if index < count then
        if value == nil then
            return
        end
        for position = count, index + 1, -1 do
            stored = { [keys[position]] = stored }
        end
    end
    local written, failure = pcall(assignField, container, keys[index], stored)
    if not written then
        local db = rawget(tree, "_db")
        if db:Validate(rawget(record, "_bindScope"), keys, value) == true then
            error(failure, 0)
        end
        error(
            methodName
                .. " "
                .. rawget(record, "_path")
                .. " refused by the database: "
                .. withoutPosition(failure),
            level
        )
    end
end

---@param tree OptionsKit.Tree
---@param record table
---@param value any
---@param methodName string
---@param level integer
local function writeValue(tree, record, value, methodName, level)
    if rawget(record, "_bindScope") then
        writeBound(tree, record, value, methodName, level + 1)
        return
    end
    rawget(record, "_set")(rawget(record, "_info"), value)
end

---Run the option's own `validate`. Returns `true`, or `false` and a message.
---@param record table
---@param value any
---@return boolean accepted
---@return string|nil message
local function runValidate(record, value)
    local validate = rawget(record, "_validate")
    if not validate then
        return true, nil
    end
    local accepted, message = validate(rawget(record, "_info"), value)
    if accepted == true then
        return true, nil
    end
    if type(message) ~= "string" then
        message = "refused by validate"
    end
    return false, message
end

---Evaluate one `disabled`/`hidden` field on `record` and its ancestors.
---@param record table|false
---@param field string `"_disabled"` or `"_hidden"`
---@return boolean
local function effectiveFlag(record, field)
    while record do
        local flag = rawget(record, field)
        if flag == true then
            return true
        end
        if flag and flag(rawget(record, "_info")) then
            return true
        end
        record = rawget(record, "_parent")
    end
    return false
end

-- Tree methods ---------------------------------------------------------------

---Read the value of the option at `path`: the getter's result, or the bound
---database value. The value is returned as it is, unchecked.
---@param self OptionsKit.Tree
---@param path string
---@return any value
local function treeGet(self, path)
    validateTree(self, "OptionsKit.Tree:Get", 3)
    local record = findValueRecord(self, path, "OptionsKit.Tree:Get", 3)
    return readValue(self, record, "OptionsKit.Tree:Get", 3)
end

---Write the option at `path`: the schema is asserted at the caller's line,
---then `validate` runs, then the setter or the bound write, then `OnChange`
---fires. Hidden and disabled options are written like any other.
---@param self OptionsKit.Tree
---@param path string
---@param value any
---@return boolean written
---@return string|nil message why `validate` refused
local function treeSet(self, path, value)
    validateTree(self, "OptionsKit.Tree:Set", 3)
    local record = findValueRecord(self, path, "OptionsKit.Tree:Set", 3)
    if isSecret(value) then
        error("OptionsKit.Tree:Set value must not be a secret value", 2)
    end
    rawget(record, "_schema"):Assert(value, rawget(record, "_setArgument"), 2)
    local accepted, message = runValidate(record, value)
    if not accepted then
        return false, message
    end
    writeValue(self, record, value, "OptionsKit.Tree:Set", 3)
    rawget(self, "_changed"):Fire(self, path, value)
    return true, nil
end

---Whether `value` would be accepted at `path`, without writing it: the schema
---and `validate`. Never raises for the value; allocates only the message of a
---schema refusal.
---@param self OptionsKit.Tree
---@param path string
---@param value any
---@return boolean accepted
---@return string|nil message
local function treeValidate(self, path, value)
    validateTree(self, "OptionsKit.Tree:Validate", 3)
    local record = findValueRecord(self, path, "OptionsKit.Tree:Validate", 3)
    if isSecret(value) then
        return false, "secret value"
    end
    local valid, failure = rawget(record, "_schema"):Check(value)
    if not valid then
        local where = failure.path == "" and "" or failure.path .. ": "
        return false, where .. "expected " .. failure.expected .. ", found " .. failure.found
    end
    local accepted, message = runValidate(record, value)
    if not accepted or not rawget(record, "_bindScope") then
        return accepted, message
    end
    return validateBound(self, record, value, "OptionsKit.Tree:Validate", 3)
end

---Reset a bound option to its SettingsKit default by clearing the stored
---value, so the database's default fallback answers. Fires `OnChange` with
---the value read back, and returns it. Raises for an option with get/set.
---@param self OptionsKit.Tree
---@param path string
---@return any value the default now in effect
local function treeReset(self, path)
    validateTree(self, "OptionsKit.Tree:Reset", 3)
    local record = findValueRecord(self, path, "OptionsKit.Tree:Reset", 3)
    if not rawget(record, "_bindScope") then
        error(
            'OptionsKit.Tree:Reset path "'
                .. path
                .. '" is not bound to a database and has no default',
            2
        )
    end
    writeValue(self, record, nil, "OptionsKit.Tree:Reset", 3)
    local value = readValue(self, record, "OptionsKit.Tree:Reset", 3)
    rawget(self, "_changed"):Fire(self, path, value)
    return value
end

---Run the `func` of the `execute` option at `path`. `confirm` is a renderer's
---concern: this call does not ask.
---@param self OptionsKit.Tree
---@param path string
local function treeExecute(self, path)
    validateTree(self, "OptionsKit.Tree:Execute", 3)
    local record = findRecord(self, path, "OptionsKit.Tree:Execute", 3)
    if rawget(record, "_kind") ~= KIND_EXECUTE then
        error('OptionsKit.Tree:Execute path "' .. path .. '" is not an execute option', 2)
    end
    rawget(record, "_func")(rawget(record, "_info"))
end

---Whether the option at `path`, or a group above it, is disabled.
---@param self OptionsKit.Tree
---@param path string
---@return boolean
local function treeIsDisabled(self, path)
    validateTree(self, "OptionsKit.Tree:IsDisabled", 3)
    return effectiveFlag(findRecord(self, path, "OptionsKit.Tree:IsDisabled", 3), "_disabled")
end

---Whether the option at `path`, or a group above it, is hidden.
---@param self OptionsKit.Tree
---@param path string
---@return boolean
local function treeIsHidden(self, path)
    validateTree(self, "OptionsKit.Tree:IsHidden", 3)
    return effectiveFlag(findRecord(self, path, "OptionsKit.Tree:IsHidden", 3), "_hidden")
end

---Visit every option below the root depth-first, siblings in `order` then
---name then key, as `visitor(path, kind, depth)`. Allocates nothing.
---@param self OptionsKit.Tree
---@param visitor fun(path: string, kind: OptionsKit.Kind, depth: integer)
---@return integer visited
local function treeWalk(self, visitor)
    validateTree(self, "OptionsKit.Tree:Walk", 3)
    if type(visitor) ~= "function" then
        error("OptionsKit.Tree:Walk visitor must be a function", 2)
    end
    local walk = rawget(self, "_walk")
    local count = #walk
    for index = 1, count do
        local record = walk[index]
        visitor(rawget(record, "_path"), rawget(record, "_kind"), rawget(record, "_depth"))
    end
    return count
end

---Connect `callback(tree, path, value)` to every `Set` and `Reset`, and to
---the profile signals of each profile group's database while the tree holds it.
---@param self OptionsKit.Tree
---@param callback OptionsKit.ChangeCallback
---@return table connection a SignalKit connection
local function treeOnChange(self, callback)
    validateTree(self, "OptionsKit.Tree:OnChange", 3)
    if type(callback) ~= "function" then
        error("OptionsKit.Tree:OnChange callback must be a function", 2)
    end
    return rawget(self, "_changed"):Connect(callback)
end

-- Describe -------------------------------------------------------------------

-- What `getmetatable` answers for a SettingsKit view: its `__metatable`.
local SETTINGS_VIEW = "SettingsKit.View"

-- What `Describe` shows instead of a table it will not copy.
local DEPTH_EXCEEDED = "<depth exceeded>"
local CYCLE = "<cycle>"

---Copy a value for `Describe`, so a description holds only fresh plain
---tables: never the table a getter returned, and never a SettingsKit view,
---which `pairs` sees as empty and which writes through to the saved variable.
---A view of the tree's own database is copied through `db:Pairs`, so its
---defaults are included. A table nested deeper than `MAX_DEPTH` becomes the
---string `"<depth exceeded>"`, and a table that contains itself (a cycle
---through the copy's own ancestors) becomes `"<cycle>"`, so no original table
---ever reaches the description.
---
---A secret value, at the top or nested, is passed through as it is, before
---anything inspects it: a copy would both touch the secret and turn it into
---a table a consumer no longer recognises as secret.
---@param value any
---@param db table|false the tree's database, for a bound option
---@param depth integer
---@param ancestors table<table, true>|nil the tables being copied above this one
---@return any
local function snapshotValue(value, db, depth, ancestors)
    if isSecret(value) or type(value) ~= "table" then
        return value
    end
    if ancestors ~= nil and ancestors[value] then
        return CYCLE
    end
    if depth > MAX_DEPTH then
        return DEPTH_EXCEEDED
    end
    ancestors = ancestors or {}
    ancestors[value] = true
    local copy = {}
    if db and getmetatable(value) == SETTINGS_VIEW then
        for key, item in db:Pairs(value) do
            copy[key] = snapshotValue(item, db, depth + 1, ancestors)
        end
    else
        for key, item in pairs(value) do
            copy[key] = snapshotValue(item, db, depth + 1, ancestors)
        end
    end
    ancestors[value] = nil
    return copy
end

---Copy a `values` table, calling the function first when the values are one.
---@param record table
---@param level integer
---@return table
local function describeValues(record, level)
    local values = rawget(record, "_values")
    if type(values) == "function" then
        values = values(rawget(record, "_info"))
        if type(values) ~= "table" then
            error(
                'OptionsKit.Tree:Describe values function of "'
                    .. rawget(record, "_path")
                    .. '" returned no table',
                level
            )
        end
    end
    local copy = {}
    for key, text in pairs(values) do
        copy[key] = text
    end
    return copy
end

---Build the description of `record` and everything below it.
---@param tree OptionsKit.Tree
---@param record table
---@param level integer
---@return OptionsKit.Description
local function describeRecord(tree, record, level)
    local kind = rawget(record, "_kind")
    local node = {
        kind = kind,
        path = rawget(record, "_path"),
        depth = rawget(record, "_depth"),
        name = rawget(record, "_name"),
        order = rawget(record, "_order"),
        disabled = effectiveFlag(record, "_disabled"),
        hidden = effectiveFlag(record, "_hidden"),
    }
    local key = rawget(record, "_key")
    if key then
        node.key = key
    end
    local desc = rawget(record, "_desc")
    if type(desc) == "function" then
        desc = desc(rawget(record, "_info"))
        if type(desc) ~= "string" then
            error(
                'OptionsKit.Tree:Describe desc function of "'
                    .. rawget(record, "_path")
                    .. '" returned no string',
                level
            )
        end
    end
    if desc then
        node.desc = desc
    end
    for field, value in pairs(rawget(record, "_hints")) do
        node[field] = value
    end

    if kind == KIND_GROUP then
        local children = rawget(record, "_children")
        local described = {}
        for index = 1, #children do
            described[index] = describeRecord(tree, children[index], level + 1)
        end
        node.children = described
    elseif VALUE_KINDS[kind] then
        local bound = rawget(record, "_bindScope") and rawget(tree, "_db") or false
        node.value = snapshotValue(
            readValue(tree, record, "OptionsKit.Tree:Describe", level + 1),
            bound,
            1,
            nil
        )
        node.schema = rawget(record, "_schema"):Describe()
        local bind = rawget(record, "_bind")
        if bind then
            node.bind = bind
        end
        if kind == KIND_SELECT or kind == KIND_MULTISELECT then
            node.values = describeValues(record, level + 1)
            local sorting = rawget(record, "_sorting")
            if sorting then
                local copy = {}
                for index = 1, #sorting do
                    copy[index] = sorting[index]
                end
                node.sorting = copy
            end
        end
    end
    return node
end

---A fresh plain description of the whole tree, for renderers: every option's
---fields, effective `disabled`/`hidden`, current value and schema description.
---Allocates by design; call it again to refresh.
---@param self OptionsKit.Tree
---@return OptionsKit.Description root
local function treeDescribe(self)
    validateTree(self, "OptionsKit.Tree:Describe", 3)
    local root = describeRecord(self, rawget(self, "_root"), 3)
    root.addonName = rawget(self, "_addonName")
    return root
end

-- Profile options ------------------------------------------------------------
--
-- `OptionsKit:ProfileOptions(db, options)` builds the group AceDBOptions gives
-- an AceDB database, over a SettingsKit database: choose the current profile,
-- create one, copy another one's settings into it, reset it, delete one. It is
-- built from the existing kinds only (`description`, `select`, `input` and
-- `execute`), so every renderer shows it without knowing what a profile is.
--
-- The group's callbacks close over one *link* record: the database, the
-- SettingsKit facade, the translation hook, the profiles chosen for copying
-- and deleting, and — once `Define` has placed the group in a tree — that tree
-- and the group's path in it. While a tree holds the group, the link is
-- connected to the database's four profile signals and fires the tree's
-- `OnChange` on each, so a renderer redraws after a switch made elsewhere;
-- `Undefine` disconnects them. The group table is the key of
-- `state.profileGroups`, which is how `Define` finds the link.

-- The methods the group calls on the database. Checked structurally, as
-- `options.db` is: SettingsKit API 1 publishes no predicate for its databases.
local PROFILE_DATABASE_METHODS = {
    "GetProfile",
    "SetProfile",
    "GetProfiles",
    "CopyProfile",
    "ResetProfile",
    "DeleteProfile",
    "OnProfileChanged",
    "OnProfileCopied",
    "OnProfileReset",
    "OnProfileDeleted",
}

-- The complete set of fields `ProfileOptions` options accept.
local PROFILE_OPTION_KEYS = { name = true, order = true, description = true, localize = true }

-- Every user-visible string of the profile group, by the key the `localize`
-- hook receives, in English. `%s` stands for the current profile's name in
-- quotes, except in `new.long`, where it is the byte limit.
local PROFILE_STRINGS = {
    ["group.name"] = "Profiles",
    ["group.desc"] = "This character uses the profile %s.",
    ["intro"] = "Profiles keep separate sets of settings. Choose the one this character uses, "
        .. "create a new one, copy another profile's settings into it, reset it, or delete one "
        .. "you no longer need.",
    ["current.name"] = "Current profile",
    ["current.desc"] = "The profile this character uses, now %s. Choosing a name that has no "
        .. "profile yet creates an empty one.",
    ["new.name"] = "New profile",
    ["new.desc"] = "Type a name to create an empty profile and switch to it. The name of an "
        .. "existing profile switches to that profile.",
    ["new.usage"] = "<profile name>",
    ["new.blank"] = "a profile name needs a character other than whitespace",
    ["new.long"] = "a profile name has at most %s bytes",
    ["copySource.name"] = "Copy from",
    ["copySource.desc"] = "The profile whose settings replace those of %s when you copy.",
    ["copy.name"] = "Copy",
    ["copy.desc"] = "Replace every setting of %s with a copy of the profile chosen above.",
    ["copy.confirm"] = "Replace the current profile's settings with a copy of the chosen profile?",
    ["reset.name"] = "Reset profile",
    ["reset.desc"] = "Return every setting of %s to its default.",
    ["reset.confirm"] = "Reset the current profile to its defaults?",
    ["deleteTarget.name"] = "Delete",
    ["deleteTarget.desc"] = "A profile other than %s, to delete.",
    ["delete.name"] = "Delete profile",
    ["delete.desc"] = "Delete the profile chosen above. Characters that used it start on the "
        .. "default profile next time.",
    ["delete.confirm"] = "Delete the chosen profile? Its settings cannot be recovered.",
}

-- The keys of the group's options, so the paths built at attach and the
-- messages that name them agree.
local PROFILE_KEY_CURRENT = "current"
local PROFILE_KEY_COPY_SOURCE = "copySource"
local PROFILE_KEY_DELETE_TARGET = "deleteTarget"

---Find SettingsKit API 1 through the Registry, or `nil`. It is an optional
---dependency, so it is looked up at call time, never at load.
---@return table|nil SettingsKit
local function findSettingsKit()
    local findPackage = rawget(Registry, "Find")
    if type(findPackage) ~= "function" then
        return nil
    end
    local SettingsKit = findPackage(Registry, "settingsKit", OPTIONAL_SETTINGSKIT_API)
    if type(SettingsKit) ~= "table" then
        return nil
    end
    return SettingsKit
end

---Refuse anything but a table offering every method the group calls.
---@param db any
---@param label string
---@param level integer
local function validateProfileDatabase(db, label, level)
    if type(db) ~= "table" then
        error(label .. " must be a SettingsKit database", level)
    end
    for index = 1, #PROFILE_DATABASE_METHODS do
        if type(db[PROFILE_DATABASE_METHODS[index]]) ~= "function" then
            error(label .. " must be a SettingsKit database", level)
        end
    end
end

---Read the `ProfileOptions` options into `link`.
---@param options any
---@param link table
---@param level integer
local function readProfileOptions(options, link, level)
    if options == nil then
        return
    end
    if type(options) ~= "table" then
        error("OptionsKit:ProfileOptions options must be a table", level)
    end
    local firstUnknown = nil
    for key in pairs(options) do
        if PROFILE_OPTION_KEYS[key] ~= true then
            local text = type(key) == "string" and key or "<" .. type(key) .. " key>"
            if firstUnknown == nil or text < firstUnknown then
                firstUnknown = text
            end
        end
    end
    if firstUnknown ~= nil then
        error(
            'OptionsKit:ProfileOptions options contains unknown field "' .. firstUnknown .. '"',
            level
        )
    end
    checkOptionalString(
        rawget(options, "name"),
        "OptionsKit:ProfileOptions options.name",
        level + 1
    )
    local order = rawget(options, "order")
    if order ~= nil then
        checkNumber(order, "OptionsKit:ProfileOptions options.order", level + 1)
    end
    checkOptionalString(
        rawget(options, "description"),
        "OptionsKit:ProfileOptions options.description",
        level + 1
    )
    checkOptionalFunction(
        rawget(options, "localize"),
        "OptionsKit:ProfileOptions options.localize",
        level + 1
    )
    link.name = rawget(options, "name") or false
    link.order = order or false
    link.description = rawget(options, "description") or false
    link.localize = rawget(options, "localize") or false
end

---The text for `key`: the hook's answer when it is a string, else the English
---default.
---@param link table
---@param key string
---@return string
local function translate(link, key)
    local default = PROFILE_STRINGS[key]
    local localize = link.localize
    if localize then
        local text = localize(key, default)
        if type(text) == "string" then
            return text
        end
    end
    return default
end

---Put `value` where `template` says `%s`. A function replacement, so a `%` in
---a profile name is never read as a `gsub` capture.
---@param template string
---@param value string
---@return string
local function fill(template, value)
    return (template:gsub("%%s", function()
        return value
    end))
end

---The text for `key` with the current profile's name, quoted, filled in.
---@param link table
---@param key string
---@return string
local function withCurrentProfile(link, key)
    return fill(translate(link, key), '"' .. link.db:GetProfile() .. '"')
end

---The per-character profile name SettingsKit builds, `"<name> - <realm>"`, or
---`false` when the client does not know the player. Read once, at
---`ProfileOptions`, the way SettingsKit reads it once at `Open`.
---@return string|false
local function readCharacterProfile()
    -- UnitName and GetRealmName are World of Warcraft client APIs reachable only through the global table.
    -- selene: allow(global_usage)
    local unitName = rawget(_G, "UnitName")
    -- selene: allow(global_usage)
    local getRealmName = rawget(_G, "GetRealmName")
    if type(unitName) ~= "function" or type(getRealmName) ~= "function" then
        return false
    end
    local name = unitName("player")
    local realm = getRealmName()
    if isSecret(name) or isSecret(realm) then
        return false
    end
    if type(name) ~= "string" or name == "" or type(realm) ~= "string" or realm == "" then
        return false
    end
    return name .. " - " .. realm
end

---The choices of the current-profile select: every profile, the current one
---(which `GetProfiles` always includes, so a fresh database shows the default
---it was opened with) and this character's own profile, which a switch
---creates. SettingsKit's own default profile is not offered by name: a
---database opened with another `defaultProfile` never asked for it. Key and
---label are the name. Allocates, as `GetProfiles`.
---@param link table
---@return table<string, string>
local function currentChoices(link)
    local choices = {}
    local names = link.db:GetProfiles()
    for index = 1, #names do
        choices[names[index]] = names[index]
    end
    local current = link.db:GetProfile()
    choices[current] = current
    if link.characterProfile then
        choices[link.characterProfile] = link.characterProfile
    end
    return choices
end

---Every profile but the current one: what can be copied from or deleted.
---@param link table
---@return table<string, string>
local function otherChoices(link)
    local choices = {}
    local current = link.db:GetProfile()
    local names = link.db:GetProfiles()
    for index = 1, #names do
        local name = names[index]
        if name ~= current then
            choices[name] = name
        end
    end
    return choices
end

---Whether `name` is a profile that exists and is not the current one. Walks
---the name array `GetProfiles` returns rather than building a choice map, so
---the `disabled` predicates and the select getters allocate that array only.
---@param link table
---@param name any a profile name the group stored itself, or `false`
---@return boolean
local function isOtherProfile(link, name)
    if type(name) ~= "string" or name == link.db:GetProfile() then
        return false
    end
    local names = link.db:GetProfiles()
    for index = 1, #names do
        if names[index] == name then
            return true
        end
    end
    return false
end

---Switch the database to `name` without the link's own listener firing the
---tree: `Set` fires `OnChange` for this write itself. The flag is restored to
---what it was, not cleared, so a switch made from a listener of an outer
---switch leaves the outer one suppressed until it returns; it is restored
---even when SettingsKit or one of its listeners raises, and the error then
---propagates as it is.
---@param link table
---@param name string
local function switchProfile(link, name)
    local db = link.db
    local outer = link.suppress
    link.suppress = true
    local switched, failure = pcall(db.SetProfile, db, name)
    link.suppress = outer
    if not switched then
        error(failure, 0)
    end
end

---The check the new-profile input runs: SettingsKit's own rules for a profile
---name, answered as a message instead of an error, so an edit box can show it.
---@param link table
---@param name string
---@return boolean accepted
---@return string|nil message
local function validateNewProfileName(link, name)
    if not name:find("%S") then
        return false, translate(link, "new.blank")
    end
    local maxLength = link.SettingsKit:GetLimits().maxProfileNameLength
    if #name > maxLength then
        return false, fill(translate(link, "new.long"), tostring(maxLength))
    end
    return true, nil
end

---Raise, at the caller of `Execute`, for a button pressed before its select
---was set: a renderer that honours `disabled` never gets here.
---@param info OptionsKit.Info
---@param selectKey string
local function refuseUnchosen(info, selectKey)
    local parentPath = info.path:match("^(.*)%.[^.]+$") or ""
    local selectPath = parentPath == "" and selectKey or parentPath .. "." .. selectKey
    -- refuseUnchosen <- func <- Execute <- the caller
    error(
        "OptionsKit.Tree:Execute " .. info.path .. ' needs "' .. selectPath .. '" to be set first',
        4
    )
end

---Build the group's options. Every callback closes over `link` only, so the
---group works in whichever tree `Define` places it.
---@param link table
---@return table<string, OptionsKit.Option> args
local function buildProfileArgs(link)
    local db = link.db
    return {
        intro = {
            type = KIND_DESCRIPTION,
            name = link.description or translate(link, "intro"),
            fontSize = "medium",
            order = 1,
        },
        [PROFILE_KEY_CURRENT] = {
            type = KIND_SELECT,
            name = translate(link, "current.name"),
            desc = function()
                return withCurrentProfile(link, "current.desc")
            end,
            order = 2,
            values = function()
                return currentChoices(link)
            end,
            get = function()
                return db:GetProfile()
            end,
            set = function(_, name)
                switchProfile(link, name)
            end,
        },
        new = {
            type = KIND_INPUT,
            name = translate(link, "new.name"),
            desc = translate(link, "new.desc"),
            usage = translate(link, "new.usage"),
            order = 3,
            get = function()
                return ""
            end,
            validate = function(_, name)
                return validateNewProfileName(link, name)
            end,
            -- Not suppressed: the current profile changed, so the link fires
            -- `current` as for any other switch, beside `Set`'s own `new`.
            set = function(_, name)
                db:SetProfile(name)
            end,
        },
        [PROFILE_KEY_COPY_SOURCE] = {
            type = KIND_SELECT,
            name = translate(link, "copySource.name"),
            desc = function()
                return withCurrentProfile(link, "copySource.desc")
            end,
            order = 4,
            values = function()
                return otherChoices(link)
            end,
            get = function()
                return isOtherProfile(link, link.copySource) and link.copySource or nil
            end,
            set = function(_, name)
                link.copySource = name
            end,
        },
        copy = {
            type = KIND_EXECUTE,
            name = translate(link, "copy.name"),
            desc = function()
                return withCurrentProfile(link, "copy.desc")
            end,
            confirm = translate(link, "copy.confirm"),
            order = 5,
            disabled = function()
                return not isOtherProfile(link, link.copySource)
            end,
            func = function(info)
                local source = link.copySource
                if not isOtherProfile(link, source) then
                    refuseUnchosen(info, PROFILE_KEY_COPY_SOURCE)
                end
                db:CopyProfile(source)
            end,
        },
        reset = {
            type = KIND_EXECUTE,
            name = translate(link, "reset.name"),
            desc = function()
                return withCurrentProfile(link, "reset.desc")
            end,
            confirm = translate(link, "reset.confirm"),
            order = 6,
            func = function()
                db:ResetProfile()
            end,
        },
        [PROFILE_KEY_DELETE_TARGET] = {
            type = KIND_SELECT,
            name = translate(link, "deleteTarget.name"),
            desc = function()
                return withCurrentProfile(link, "deleteTarget.desc")
            end,
            order = 7,
            values = function()
                return otherChoices(link)
            end,
            get = function()
                return isOtherProfile(link, link.deleteTarget) and link.deleteTarget or nil
            end,
            set = function(_, name)
                link.deleteTarget = name
            end,
        },
        delete = {
            type = KIND_EXECUTE,
            name = translate(link, "delete.name"),
            desc = translate(link, "delete.desc"),
            confirm = translate(link, "delete.confirm"),
            order = 8,
            disabled = function()
                return not isOtherProfile(link, link.deleteTarget)
            end,
            func = function(info)
                local target = link.deleteTarget
                if not isOtherProfile(link, target) then
                    refuseUnchosen(info, PROFILE_KEY_DELETE_TARGET)
                end
                -- Forgotten first: the deletion fires the tree's `OnChange`,
                -- and a listener may choose the next target.
                link.deleteTarget = false
                db:DeleteProfile(target)
            end,
        },
    }
end

-- The database methods a link connects to, in connection order.
local PROFILE_SIGNAL_METHODS =
    { "OnProfileChanged", "OnProfileCopied", "OnProfileReset", "OnProfileDeleted" }

---Disconnect every connection in `connections`.
---@param connections table
local function disconnectAll(connections)
    for index = 1, #connections do
        connections[index]:Disconnect()
    end
end

---Attach `link` to the tree `Define` placed its group in, at `path`: connect
---the database's profile signals, then record the tree. Each signal fires the
---tree's `OnChange` with the current-profile option's path and the current
---profile's name — unless the group's own `current` is switching, which
---fires by itself. A connect that raises (a database that is not SettingsKit's
---after all) undoes the connections made before it and leaves the link free,
---so the error reaches the caller of `Define` without a stuck group.
---@param link table
---@param tree OptionsKit.Tree
---@param path string the group's path, `""` when the group is the root
local function attachProfileLink(link, tree, path)
    local currentPath = path == "" and PROFILE_KEY_CURRENT or path .. "." .. PROFILE_KEY_CURRENT
    local db = link.db
    local function notify()
        if link.suppress then
            return
        end
        rawget(tree, "_changed"):Fire(tree, currentPath, db:GetProfile())
    end
    local connections = {}
    for index = 1, #PROFILE_SIGNAL_METHODS do
        local connected, result = pcall(db[PROFILE_SIGNAL_METHODS[index]], db, notify)
        if not connected then
            disconnectAll(connections)
            error(result, 0)
        end
        connections[index] = result
    end
    link.connections = connections
    link.tree = tree
end

---Detach `link` from its tree: disconnect the profile signals, so the group
---can be defined again elsewhere.
---@param link table
local function detachProfileLink(link)
    local connections = link.connections
    if not connections then
        return
    end
    disconnectAll(connections)
    link.connections = false
    link.tree = false
end

---Build a ready-made options group over the profiles of a SettingsKit
---database, to place in a tree's `args`. See `docs/API.md`, *Profile options*.
---@param _ OptionsKit
---@param db table a SettingsKit API 1 database
---@param options OptionsKit.ProfileOptionsOptions?
---@return OptionsKit.Option group
local function profileOptions(_, db, options)
    local SettingsKit = findSettingsKit()
    if SettingsKit == nil then
        error("OptionsKit:ProfileOptions needs SettingsKit API 1 to be loaded", 2)
    end
    validateProfileDatabase(db, "OptionsKit:ProfileOptions db", 3)
    local link = {
        db = db,
        SettingsKit = SettingsKit,
        characterProfile = readCharacterProfile(),
        -- The `ProfileOptions` options, `false` when absent.
        name = false,
        order = false,
        description = false,
        localize = false,
        -- The profiles chosen in the copy and delete selects, `false` for none.
        copySource = false,
        deleteTarget = false,
        -- `true` while the group's own `Set` switches the profile.
        suppress = false,
        -- Set by `attachProfileLink`, cleared by `detachProfileLink`.
        tree = false,
        connections = false,
    }
    readProfileOptions(options, link, 3)

    local group = {
        type = KIND_GROUP,
        name = link.name or translate(link, "group.name"),
        desc = function()
            return withCurrentProfile(link, "group.desc")
        end,
        args = buildProfileArgs(link),
    }
    if link.order then
        group.order = link.order
    end
    rawset(profileGroups, group, link)
    return group
end

-- Package public API ---------------------------------------------------------

---Read a `maxOptions` or `maxDynamicEntries` option: absent means `default`,
---`OptionsKit.UNBOUNDED` means `math.huge`, anything else must be a positive
---integer. The tree is the consumer's own data, so the consumer may lift both.
---@param value any
---@param default integer
---@param name string the option's field name, used in the argument error
---@param level integer stack level the failure is reported at
---@return number capacity
local function readCapacityOption(value, default, name, level)
    if value == nil then
        return default
    end
    if value == UNBOUNDED then
        return math.huge
    end
    if
        type(value) ~= "number"
        or value ~= value
        or value < 1
        or value == math.huge
        or math.floor(value) ~= value
    then
        error(
            "OptionsKit:Define options."
                .. name
                .. " must be a positive integer or OptionsKit.UNBOUNDED",
            level
        )
    end
    return value
end

---Read the `maxDepth` option: absent means `MAX_DEPTH`; otherwise an integer
---from 1 to `MAX_DEPTH_CEILING`. `UNBOUNDED` is refused with its reason.
---@param value any
---@param level integer stack level the failure is reported at
---@return integer maxDepth
local function readMaxDepthOption(value, level)
    if value == nil then
        return MAX_DEPTH
    end
    if value == UNBOUNDED then
        error(
            "OptionsKit:Define options.maxDepth cannot be OptionsKit.UNBOUNDED: the tree is built on the Lua stack, so the ceiling is "
                .. MAX_DEPTH_CEILING,
            level
        )
    end
    if
        type(value) ~= "number"
        or value ~= value
        or value < 1
        or value > MAX_DEPTH_CEILING
        or math.floor(value) ~= value
    then
        error(
            "OptionsKit:Define options.maxDepth must be an integer from 1 to " .. MAX_DEPTH_CEILING,
            level
        )
    end
    return value
end

---Read the `Define` options: `options.db`, checked for the SettingsKit
---database surface, and the three limits into `context`.
---@param options any
---@param context table the build context, whose limits this fills in
---@param level integer
---@return table|false db
local function readDefineOptions(options, context, level)
    context.maxOptions = MAX_OPTIONS
    context.maxDepth = MAX_DEPTH
    context.maxDynamicEntries = MAX_DYNAMIC_ENTRIES
    if options == nil then
        return false
    end
    if type(options) ~= "table" then
        error("OptionsKit:Define options must be a table", level)
    end
    -- Name the alphabetically first unknown field, so the message does not
    -- depend on hash order, and name a key that is not a string by its type:
    -- `tostring` could run a caller's `__tostring`.
    local firstUnknown = nil
    for key in pairs(options) do
        if DEFINE_OPTION_KEYS[key] ~= true then
            local text = type(key) == "string" and key or "<" .. type(key) .. " key>"
            if firstUnknown == nil or text < firstUnknown then
                firstUnknown = text
            end
        end
    end
    if firstUnknown ~= nil then
        error('OptionsKit:Define options contains unknown field "' .. firstUnknown .. '"', level)
    end
    context.maxOptions =
        readCapacityOption(rawget(options, "maxOptions"), MAX_OPTIONS, "maxOptions", level + 1)
    context.maxDepth = readMaxDepthOption(rawget(options, "maxDepth"), level + 1)
    context.maxDynamicEntries = readCapacityOption(
        rawget(options, "maxDynamicEntries"),
        MAX_DYNAMIC_ENTRIES,
        "maxDynamicEntries",
        level + 1
    )
    local db = options.db
    if db == nil then
        return false
    end
    if findSettingsKit() == nil then
        error("OptionsKit:Define options.db needs SettingsKit API 1 to be loaded", level)
    end
    if
        type(db) ~= "table"
        or type(db.OnChange) ~= "function"
        or type(db.Validate) ~= "function"
    then
        error("OptionsKit:Define options.db must be a SettingsKit database", level)
    end
    return db
end

---Define the options tree of an addon. The tree is checked in full and copied:
---later edits to the tables passed have no effect.
---@param _ OptionsKit
---@param addonName string
---@param spec OptionsKit.Option the root group
---@param options OptionsKit.DefineOptions?
---@return OptionsKit.Tree tree
local function define(_, addonName, spec, options)
    validateAddonName(addonName, "OptionsKit:Define addonName", 3)
    if rawget(trees, addonName) ~= nil then
        error('OptionsKit:Define "' .. addonName .. '" already has a tree; Undefine it first', 2)
    end
    local context = {
        db = false,
        tree = false,
        addonName = addonName,
        label = "OptionsKit:Define tree",
        count = 0,
        records = {},
        -- The profile groups met while building, and the path of each.
        profileLinks = {},
        profilePaths = {},
        -- Filled in by `readDefineOptions`: numbers, `math.huge` for
        -- `OptionsKit.UNBOUNDED`.
        maxOptions = MAX_OPTIONS,
        maxDepth = MAX_DEPTH,
        maxDynamicEntries = MAX_DYNAMIC_ENTRIES,
    }
    local db = readDefineOptions(options, context, 3)

    local tree = setmetatable({
        _schema = TREE_SCHEMA,
        _addonName = addonName,
        _defined = false,
        _db = db,
        -- The limits the tree was defined under, `math.huge` for unbounded.
        -- Only `Define` enforces them; they are kept for inspection.
        _maxOptions = context.maxOptions,
        _maxDepth = context.maxDepth,
        _maxDynamicEntries = context.maxDynamicEntries,
    }, TREE_METATABLE)
    context.db = db
    context.tree = tree
    local root = buildOption(context, spec, false, false, context.label, 3)
    local walk = {}
    flatten(root, walk)

    rawset(tree, "_root", root)
    rawset(tree, "_records", context.records)
    rawset(tree, "_walk", walk)
    rawset(tree, "_changed", SignalKit:New())
    -- Attached last: a refusal above leaves no link pointing at this tree,
    -- and a link that fails to attach frees the ones attached before it.
    local links = context.profileLinks
    local paths = context.profilePaths
    for index = 1, #links do
        local attached, failure = pcall(attachProfileLink, links[index], tree, paths[index])
        if not attached then
            for previous = 1, index - 1 do
                detachProfileLink(links[previous])
            end
            error(failure, 0)
        end
    end
    rawset(tree, "_profileLinks", links)
    rawset(tree, "_defined", true)
    rawset(trees, addonName, tree)
    return tree
end

---Return the tree defined for `addonName`, or `nil`.
---@param _ OptionsKit
---@param addonName string
---@return OptionsKit.Tree|nil
local function getTree(_, addonName)
    validateAddonName(addonName, "OptionsKit:Get addonName", 3)
    return rawget(trees, addonName)
end

---Forget the tree of `addonName` and disconnect its `OnChange` listeners. The
---old handle refuses every method afterwards. Meant for tests and reloads of
---a module's options.
---@param _ OptionsKit
---@param addonName string
---@return boolean removed `false` when there was no tree.
local function undefine(_, addonName)
    validateAddonName(addonName, "OptionsKit:Undefine addonName", 3)
    local tree = rawget(trees, addonName)
    if tree == nil then
        return false
    end
    rawset(trees, addonName, nil)
    rawset(tree, "_defined", false)
    rawget(tree, "_changed"):DisconnectAll()
    local links = rawget(tree, "_profileLinks")
    for index = 1, #links do
        detachProfileLink(links[index])
    end
    return true
end

-- Commit ---------------------------------------------------------------------

rawset(Tree, "Get", treeGet)
rawset(Tree, "Set", treeSet)
rawset(Tree, "Validate", treeValidate)
rawset(Tree, "Reset", treeReset)
rawset(Tree, "Execute", treeExecute)
rawset(Tree, "IsDisabled", treeIsDisabled)
rawset(Tree, "IsHidden", treeIsHidden)
rawset(Tree, "Walk", treeWalk)
rawset(Tree, "Describe", treeDescribe)
rawset(Tree, "OnChange", treeOnChange)

rawset(OptionsKit, "API", API_GENERATION)
rawset(OptionsKit, "REVISION", IMPLEMENTATION_REVISION)
rawset(OptionsKit, "MAX_OPTIONS", MAX_OPTIONS)
rawset(OptionsKit, "MAX_DEPTH", MAX_DEPTH)
rawset(OptionsKit, "UNBOUNDED", UNBOUNDED)
rawset(OptionsKit, "Define", define)
rawset(OptionsKit, "Get", getTree)
rawset(OptionsKit, "Undefine", undefine)
rawset(OptionsKit, "ProfileOptions", profileOptions)

rawset(state, "runtimeRevision", IMPLEMENTATION_REVISION)

if not validatePublicSurface(OptionsKit) or not validateCurrentState(OptionsKit) then
    error("MoltenCodes OptionsKit package state is corrupted or incomplete", 2)
end

return OptionsKit
