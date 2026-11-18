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
-- `Define` as `options.db`. `ProfileOptions(db)` returns a ready-made group
-- over a SettingsKit database's profiles, built from these same kinds once per
-- database and options; with SettingsKit revision 11 it also carries one
-- profile choice per specialization (SettingsKit's spec profiles).
--
-- OptionsKit requires Registry API 2, SchemaKit API 1 (with its Rules part
-- for input patterns and values functions) and SignalKit API 1. SettingsKit
-- API 1 is optional and found through `Registry:Find` only when `Define`
-- receives `options.db` or `ProfileOptions` is called.
--
-- This file is the core (docs/decisions/0001-kit-core-and-parts.md, revision
-- 16): what every tree needs. Five optional parts add the rest: Presentation
-- (AceConfig's presentation fields, function names and orders, per-interface
-- flags), Handlers (handlers, method names, inherited accessors, plugins),
-- Bind (`bind` into a SettingsKit database), Profiles (`ProfileOptions` and
-- its links) and Dynamic (trees that change shape). A part extends the
-- field tables and fills the hooks (`Hints`, `Resolve`, `Bound`) the core
-- publishes in `state.helpers`.
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
--   Info tables ........... each option's `info`, built on first use
--   Schemas ............... the SchemaKit schemas, shared per kind and inputs
--   Building .............. option records, the path index, sorted children
--   Bound values .......... the readers and writers, bound ones through `Bound`
--   Tree methods .......... the handle `Define` returns
--   Describe .............. the plain, allocating snapshot for renderers
--                            (`DescribeOption`: one option or group of it)
--   Profile groups ........ the hooks the Profiles part fills, the core's detach
--   Package public API .... the facade published through Registry
--   Revision 15 routing ... revision 15's methods while a part is absent
--   Commit ................ prototype/facade assignment and self-check
--
-- Layout and invariants are described in `docs/INTERNALS.md`.

-- Constants ------------------------------------------------------------------

local PACKAGE_NAME = "optionsKit"
local API_GENERATION = 1
local IMPLEMENTATION_REVISION = 16
local REQUIRED_REGISTRY_API = 2
local REQUIRED_SCHEMAKIT_API = 1
local REQUIRED_SIGNALKIT_API = 1
local OPTIONAL_SETTINGSKIT_API = 1
local STATE_SCHEMA = 1

-- Every tree records the layout it was built with, so a later revision that
-- changes the layout can upgrade old trees instead of guessing from which
-- fields exist. Layout 2 (revision 2) added `_profileLinks`; layout 3
-- (revision 15) keeps the limits a rebuild checks against.
local TREE_SCHEMA = 3

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

-- The fields an option may carry, and what `Define` does with each. One table,
-- so the main chunk spends one local on them. An unknown field is refused at
-- Define: a misspelt `witdh` fails loudly instead of being silently ignored.
local Fields = {}

-- Fields every option accepts in the core. The Presentation part adds
-- AceConfig's presentation fields and the per-interface hidden flags, and the
-- Handlers part `handler` (revision 16, ADR 0001).
Fields.common = {
  type = true,
  name = true,
  desc = true,
  order = true,
  disabled = true,
  hidden = true,
  confirm = true,
  confirmText = true,
  arg = true,
}
-- Fields every kind but `group` accepts: how wide a control is and which
-- widget draws it, which mean nothing for a group. Empty in the core; the
-- Presentation part fills it.
Fields.control = {}
-- Fields every value-carrying option accepts on top of the common ones. The
-- Bind part adds `bind`.
Fields.value = { get = true, set = true, validate = true }
-- Fields each kind accepts on top of the common, control and value fields.
-- The parts add their own: a group's inherited accessors and `plugins`
-- (Handlers), the per-interface inline flags and the image fields
-- (Presentation).
Fields.kind = {
  [KIND_GROUP] = { args = true, inline = true, childGroups = true },
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
  [KIND_MULTISELECT] = { values = true, sorting = true, tristate = true },
  [KIND_INPUT] = { pattern = true, multiline = true, usage = true },
  [KIND_COLOR] = { hasAlpha = true },
  [KIND_KEYBINDING] = {},
  [KIND_EXECUTE] = { func = true },
  [KIND_HEADER] = {},
  [KIND_DESCRIPTION] = { fontSize = true },
}
-- Fields a record keeps in fields of its own, never in `_hints`. Every other
-- accepted field is a hint (revision 13), so an option that sets none keeps
-- the 8 hash slots of its constructor.
Fields.record = {
  type = true,
  name = true,
  args = true,
  plugins = true,
  values = true,
  sorting = true,
  bind = true,
}
-- The accessors: record fields on the kinds that use them, hints on a group,
-- which only passes them down (Handlers part).
Fields.accessor = { get = true, set = true, validate = true, func = true }
-- Hints `Describe` does not copy as they are: `confirm` and `inline`, which
-- it reports resolved, and what never reaches a description (`arg`,
-- `handler`, a group's accessors). The Presentation part adds the
-- per-interface flags, which it folds into `hidden` and `inline`.
Fields.notDescribed = {
  desc = true,
  order = true,
  disabled = true,
  hidden = true,
  confirm = true,
  inline = true,
  arg = true,
  handler = true,
  get = true,
  set = true,
  validate = true,
  func = true,
}
-- Fields a string may name a method of the handler in force in (ADR 0003),
-- which only the Handlers part resolves; without it such a string is refused
-- at `Define`. In every other field that takes a function, a string is the
-- value itself (`name`, `desc`, `width`, `image`, `icon`, `fontSize`,
-- `tooltipHyperlink`, Ace3's literal fields), and `confirm`'s string is the
-- question.
Fields.method = {
  get = true,
  set = true,
  validate = true,
  func = true,
  disabled = true,
  hidden = true,
  guiHidden = true,
  dialogHidden = true,
  cmdHidden = true,
  values = true,
  sorting = true,
  order = true,
  iconCoords = true,
  imageCoords = true,
}
-- The interfaces `IsHidden`, `Describe` and `DescribeOption` accept. What
-- each reads in place of `hidden` and `inline` is the Presentation part's.
Fields.interfaces = { dialog = true, cmd = true }
-- The fields each part accepts, as `field@kinds` (`*` every kind, `-` every
-- kind but `group`), read only when `Define` refuses a field, to name the part
-- to embed (revision 16, ADR 0001 point 5).
Fields.parts = {
  Presentation = " descStyle@* guiHidden@* dialogHidden@* cmdHidden@* icon@*"
    .. " iconCoords@* tooltipHyperlink@* width@- relWidth@- dialogControl@- control@-"
    .. " guiInline@group dialogInline@group cmdInline@group"
    .. " image@toggle,execute,description imageCoords@toggle,execute,description"
    .. " imageWidth@execute,description imageHeight@execute,description"
    .. " style@select itemControl@select ",
  Handlers = " handler@* plugins@group get@group set@group validate@group func@group ",
  Bind = " bind@toggle,range,select,multiselect,input,color,keybinding ",
}
-- The forms each field accepts, as `GetFields` reports them, one letter per
-- form: `s` string, `n` number, `b` boolean, `t` table, `f` function, `m` a
-- string naming a handler method, `a` any value. A string rather than tables,
-- so only a call to `GetFields` pays for the sets it builds. `GetFields`
-- reports only the fields the loaded parts accept, `m` only with the Handlers
-- part, and `f` on `name`, `order`, `fontSize` and `sorting` only with the
-- Presentation part.
Fields.forms = "type=s name=sf desc=sf order=nfm disabled=bfm hidden=bfm guiHidden=bfm"
  .. " dialogHidden=bfm cmdHidden=bfm descStyle=s confirm=bsf confirmText=s arg=a"
  .. " handler=t icon=snf iconCoords=tfm tooltipHyperlink=sf width=snf relWidth=n"
  .. " dialogControl=s control=s itemControl=s get=fmb set=fmb validate=fmb func=fmb"
  .. " bind=s args=t plugins=t inline=b guiInline=b dialogInline=b cmdInline=b"
  .. " childGroups=s tristate=b image=snf imageCoords=tfm imageWidth=n imageHeight=n"
  .. " min=n max=n step=n softMin=n softMax=n bigStep=n isPercent=b values=tfm"
  .. " sorting=tfm style=s pattern=s multiline=bn usage=s hasAlpha=b fontSize=sf"
-- The fields whose function form is the Presentation part's.
Fields.functionForms = { name = true, order = true, fontSize = true, sorting = true }
-- What each letter of `Fields.forms` stands for.
Fields.formNames = {
  s = "string",
  n = "number",
  b = "boolean",
  t = "table",
  f = "function",
  m = "method",
  a = "any",
}
-- The accepted `description.fontSize` values.
local FONT_SIZES = { small = true, medium = true, large = true }

-- The accepted `group.childGroups` values, Ace3's names for how a renderer
-- shows the group's non-inline child groups: tabs, a tree, or a dropdown.
local CHILD_GROUPS = { tab = true, tree = true, select = true }

-- The complete set of fields `Define` options accept.
local DEFINE_OPTION_KEYS =
  { db = true, maxOptions = true, maxDepth = true, maxDynamicEntries = true }

-- An option key or a bind path segment: an identifier, so a dotted path can
-- never be ambiguous.
local KEY_PATTERN = "^[%a_][%w_]*$"

-- The published surface, listed once so the public-surface predicate reads as
-- a checklist instead of a long boolean expression.
local FACADE_METHODS =
  { "Define", "Get", "Undefine", "ProfileOptions", "GetFields", "GetTrees", "IsPartLoaded" }
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
  "DescribeOption",
  "OnChange",
  "GetConfirmation",
  "OnStructureChanged",
  "NotifyChange",
  "Replace",
  "Remove",
}

-- The members each part provides, and the core installs as a stub that names
-- the part when the part is not loaded (ADR 0001, point 5), so the facade and
-- the tree prototype stay complete whichever parts an addon embeds.
local PART_MEMBERS = {
  Profiles = { facade = { "ProfileOptions" }, tree = {} },
  Dynamic = { facade = {}, tree = { "NotifyChange", "Replace", "Remove" } },
  -- Revision 16: parts without members of their own, which extend the field
  -- tables and hooks when they bind.
  Presentation = { facade = {}, tree = {} },
  Handlers = { facade = {}, tree = {} },
  Bind = { facade = {}, tree = {} },
}

-- The value `_defined` holds while a tree waits for the rebuild
-- `NotifyChange` asked for (revision 15). Every method already tests the field
-- for `true`, so a clean tree pays nothing for the dirty state.
local DIRTY = "dirty"

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
---@field childGroups ("tab"|"tree"|"select")? `group`: how a renderer shows its non-inline child groups.
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
---@field childGroups ("tab"|"tree"|"select")? `group`
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
---@field DescribeOption fun(self: OptionsKit.Tree, path: string): OptionsKit.Description|nil
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
if type(Registry) == "nil" and type(namespace) == "table" then
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
    and type(rawget(currentState, "profileLinksByDatabase")) == "table"
    and type(rawget(currentState, "parts")) == "table"
    and type(rawget(currentState, "helpers")) == "table"
    and type(rawget(currentState, "treeSources")) == "table"
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

if type(OptionsKit) == "nil" then
  -- An equal or newer compatible revision already owns the shared package table.
  return selected
end

local Tree = rawget(OptionsKit, "Tree")
local state = rawget(OptionsKit, "_state")

if type(previousRevision) == "nil" then
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
    -- Weak keys and values (set below, for every revision's state): the link
    -- references its group, so weak keys alone would keep every entry under
    -- Lua 5.1. An entry lives while its link is held by the cache, a tree or
    -- the group's own callbacks in a group the consumer still holds.
    profileGroups = {},
    -- Revision 8: a database to the link of the group `ProfileOptions`
    -- last built for it (revision 9: one link, no longer one per distinct
    -- set of options), so a later call with the same database and options
    -- returns the same group. The link references the database, so an entry
    -- lives for the session; there is one per database.
    profileLinksByDatabase = setmetatable({}, { __mode = "k" }),
  }
  rawset(OptionsKit, "Tree", Tree)
  rawset(OptionsKit, "_state", state)
elseif type(Tree) ~= "table" or not validateStateBase(state) then
  error("MoltenCodes OptionsKit package state is corrupted or incomplete", 2)
end

-- Revision 1 had no profile groups and built tree layout 1. The group map is
-- added, and every tree gains the (empty) list of profile links `Undefine`
-- detaches: a revision 1 tree cannot contain a profile group. Revisions 3
-- to 6 changed no layout; revision 7 changed only the record layout, which
-- every reader accepts in both forms.
if rawget(state, "profileGroups") == nil then
  rawset(state, "profileGroups", {})
end
-- Revisions 2 to 8 made the group map weak-keyed only, which never released
-- an entry (its link references the group). Revision 9 makes it weak in keys
-- and values, on an inherited map as on a new one.
setmetatable(rawget(state, "profileGroups"), { __mode = "kv" })
-- Revision 8 caches the groups per database. Groups an older revision built
-- are not in the cache: they keep working, and the first call after the
-- upgrade builds the group later calls return.
if rawget(state, "profileLinksByDatabase") == nil then
  rawset(state, "profileLinksByDatabase", setmetatable({}, { __mode = "k" }))
end
-- Revision 8 kept an array of links per database, one per distinct set of
-- options, which grew with every new `localize` closure. Revision 9 keeps one
-- link: an inherited array is reduced to its last link. The other groups keep
-- working wherever they are held; later calls with their options build anew.
for database, entry in next, rawget(state, "profileLinksByDatabase") do
  if rawget(entry, "db") == nil then
    rawset(rawget(state, "profileLinksByDatabase"), database, entry[#entry])
  end
end
-- Revision 15 splits the Kit into a core and parts (ADR 0001). `parts` holds
-- each loaded part's record (its revision, its `bind` and its members),
-- `helpers` the core functions the parts call, rewritten by every core
-- revision. `treeSources` keeps the table each tree was defined from, weakly,
-- so `NotifyChange` can read it again while the addon holds it and nothing is
-- kept alive for an addon that dropped it.
if rawget(state, "parts") == nil then
  rawset(state, "parts", {})
end
if rawget(state, "treeSources") == nil then
  rawset(state, "treeSources", setmetatable({}, { __mode = "v" }))
end
-- A single-file revision (14 or older) installed `ProfileOptions` itself.
-- Kept for the session when no addon loads the Profiles part, so an addon
-- that embedded the older complete copy keeps its profile group.
if
  type(previousRevision) == "number"
  and previousRevision < 15
  and rawget(state, "legacyMembers") == nil
then
  rawset(state, "legacyMembers", { ProfileOptions = rawget(OptionsKit, "ProfileOptions") })
end
for _, existingTree in next, rawget(state, "trees") do
  if rawget(existingTree, "_schema") == 1 then
    rawset(existingTree, "_profileLinks", {})
  end
  -- Layout 3 (revision 15): the limits a rebuild checks against. Revisions
  -- 8 and earlier wrote them under these names; later ones did not, and
  -- their trees were defined under limits nobody kept, so the defaults stand
  -- in.
  if rawget(existingTree, "_schema") ~= TREE_SCHEMA then
    if type(rawget(existingTree, "_maxOptions")) ~= "number" then
      rawset(existingTree, "_maxOptions", MAX_OPTIONS)
    end
    if type(rawget(existingTree, "_maxDepth")) ~= "number" then
      rawset(existingTree, "_maxDepth", MAX_DEPTH)
    end
    if type(rawget(existingTree, "_maxDynamicEntries")) ~= "number" then
      rawset(existingTree, "_maxDynamicEntries", MAX_DYNAMIC_ENTRIES)
    end
    rawset(existingTree, "_schema", TREE_SCHEMA)
  end
end

-- The metatable and prototype are kept across upgrades, so trees built by an
-- older copy keep their records and gain this copy's methods without being
-- replaced.
local TREE_METATABLE = rawget(state, "treeMetatable")
local trees = rawget(state, "trees")
local UNBOUNDED = rawget(state, "unbounded")
local parts = rawget(state, "parts")
local treeSources = rawget(state, "treeSources")
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
  local defined = rawget(tree, "_defined")
  if defined ~= true then
    -- Only the Dynamic part marks a tree dirty, so its rebuild is there.
    -- The rebuild never raises: a refused rebuild keeps the structure.
    if defined == DIRTY then
      local dynamic = rawget(parts, "Dynamic")
      if type(dynamic) == "table" and type(dynamic.rebuild) == "function" then
        dynamic.rebuild(tree)
      else
        rawset(tree, "_defined", true)
      end
      -- A builder may have undefined the tree.
      if rawget(tree, "_defined") ~= false then
        return
      end
    end
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
-- Every message names the whole path to the offending field, such as
-- `OptionsKit:Define tree.args.general.args.scale.min`. A check receives the
-- field's owner (an option's record, or a literal label such as
-- `OptionsKit:ProfileOptions options`) and the field name, and builds the
-- label only on the branch that raises (revision 13), so a valid tree builds
-- none.

-- The label of the root option, the start of every `Define` label.
local DEFINE_LABEL = "OptionsKit:Define tree"

-- What option labels start from: `Define`'s label and the root, or, while a
-- rebuild or a `Replace` checks a tree (revision 15), that method's label and
-- the path of the option it checks. Builds run no consumer code, so one
-- file-level record serves them; each build sets it before it starts.
local LabelBase = { prefix = DEFINE_LABEL, path = "" }

---The label of the option at `path`: `DEFINE_LABEL` and `.args.<key>` for each
---key of the path. Failure path only.
---@param path string
---@return string
local function optionLabel(path)
  local base = LabelBase.path
  if base ~= "" then
    -- A `Replace` (revision 15) names fields from the option it was given.
    if path == base then
      return LabelBase.prefix
    end
    path = string.sub(path, #base + 2)
  elseif path == "" then
    return LabelBase.prefix
  end
  return LabelBase.prefix .. ".args." .. string.gsub(path, "%.", ".args.")
end

---The label of `field` of `owner`, or of `owner` itself without a field.
---Failure path only.
---@param owner table|string an option's record, or a literal label
---@param field string|nil
---@return string
local function labelOf(owner, field)
  local label = owner
  if type(owner) == "table" then
    label = optionLabel(rawget(owner, "_path"))
  end
  ---@cast label string
  if field ~= nil then
    return label .. "." .. field
  end
  return label
end

---@param value any
---@param owner table|string the option record, or a literal label
---@param field string|nil
---@param level integer
local function checkOptionalString(value, owner, field, level)
  local valueType = type(value)
  if valueType ~= "nil" and valueType ~= "string" then
    error(labelOf(owner, field) .. " must be a string", level)
  end
end

---@param value any
---@param owner table|string the option record, or a literal label
---@param field string|nil
---@param level integer
local function checkOptionalStringOrFunction(value, owner, field, level)
  local valueType = type(value)
  if valueType ~= "nil" and valueType ~= "string" and valueType ~= "function" then
    error(labelOf(owner, field) .. " must be a string or a function", level)
  end
end

---@param value any
---@param owner table|string the option record, or a literal label
---@param field string|nil
---@param level integer
local function checkOptionalBoolean(value, owner, field, level)
  local valueType = type(value)
  if valueType ~= "nil" and valueType ~= "boolean" then
    error(labelOf(owner, field) .. " must be a boolean", level)
  end
end

---@param value any
---@param owner table|string the option record, or a literal label
---@param field string|nil
---@param level integer
local function checkOptionalFunction(value, owner, field, level)
  local valueType = type(value)
  if valueType ~= "nil" and valueType ~= "function" then
    error(labelOf(owner, field) .. " must be a function", level)
  end
end

---@param value any
---@param owner table|string the option record, or a literal label
---@param field string|nil
---@param level integer
local function checkNumber(value, owner, field, level)
  -- `value ~= value` is true for NaN only.
  if type(value) ~= "number" or value ~= value then
    error(labelOf(owner, field) .. " must be a number", level)
  end
end

---@param value any
---@param owner table|string the option record, or a literal label
---@param field string|nil
---@param level integer
local function checkPositiveNumber(value, owner, field, level)
  if type(value) ~= "nil" then
    checkNumber(value, owner, field, level + 1)
    if value <= 0 then
      error(labelOf(owner, field) .. " must be greater than 0", level)
    end
  end
end

-- The extension points of option definitions, in one table so the main chunk
-- spends one local on them (revision 16, ADR 0001). The core fills what every
-- tree needs; the Presentation and Handlers parts replace or add entries when
-- they bind, and every core revision rebuilds the table and binds the loaded
-- parts again, so the newest core always serves with the parts' functions.
local Hints = {}

---The message for a field only part `partName` accepts. Failure path only.
---@param label string the field's label
---@param partName string
---@return string
local function needsPart(label, partName)
  return label
    .. " needs OptionsKit's "
    .. partName
    .. " part: add optionsKit\\parts\\OptionsKit-"
    .. partName
    .. ".lua to embeds.xml (or rebuild it with python3 -m tooling.package.embeds)"
end

do
  ---Refuse a predicate that is not a boolean, a function or a method name.
  ---A method name is resolved, or refused without the Handlers part, by
  ---`Hints.resolve`.
  ---@param value any
  ---@param record table
  ---@param field string
  ---@param level integer
  local function checkMethodPredicate(value, record, field, level)
    local valueType = type(value)
    if
      valueType ~= "nil"
      and valueType ~= "boolean"
      and valueType ~= "function"
      and valueType ~= "string"
    then
      error(labelOf(record, field) .. " must be a boolean, a function or a method name", level)
    end
  end
  Hints.checkMethodPredicate = checkMethodPredicate

  ---Refuse the function form of `name`, `order`, `fontSize` or `sorting`
  ---without the Presentation part, which resolves it at `Describe`. The part
  ---replaces this with a function that accepts.
  ---@param record table
  ---@param field string
  ---@param level integer
  function Hints.functionForm(record, field, level)
    error(needsPart(labelOf(record, field) .. " is a function, which", "Presentation"), level)
  end

  ---Check the fields every option shares that are read for every option:
  ---the label, the description, the order and the two flags. The other
  ---fields are checked only when present (`Hints.roles`).
  ---@param spec table
  ---@param isRoot boolean
  ---@param record table
  ---@param level integer
  function Hints.checkCommon(spec, isRoot, record, level)
    local name = spec.name
    local nameType = type(name)
    if nameType ~= "string" and nameType ~= "function" and not (isRoot and nameType == "nil") then
      error(labelOf(record, "name") .. " must be a string or a function", level)
    end
    if nameType == "function" then
      Hints.functionForm(record, "name", level + 1)
    end
    checkOptionalStringOrFunction(spec.desc, record, "desc", level + 1)
    local order = spec.order
    if order ~= nil then
      local orderType = type(order)
      if orderType ~= "function" and orderType ~= "string" then
        if orderType ~= "number" or order ~= order then
          error(labelOf(record, "order") .. " must be a number, a function or a method name", level)
        end
      else
        Hints.functionForm(record, "order", level + 1)
      end
    end
    checkMethodPredicate(spec.disabled, record, "disabled", level + 1)
    checkMethodPredicate(spec.hidden, record, "hidden", level + 1)
  end

  -- What `checkKnownFields` does with each field, in one lookup: `"record"`
  -- for a field the record keeps elsewhere, `"accessor"` for one a group
  -- passes down, the check of a checked hint; a plain hint is absent. The
  -- parts add the checks of their fields.
  ---@type table<string, string|function>
  local roles = {
    confirm = function(value, record, field, level)
      local valueType = type(value)
      if valueType ~= "boolean" and valueType ~= "string" and valueType ~= "function" then
        error(labelOf(record, field) .. " must be a boolean, a string or a function", level)
      end
      return value
    end,
    confirmText = function(value, record, field, level)
      checkOptionalString(value, record, field, level + 1)
      return value
    end,
    tristate = function(value, record, field, level)
      checkOptionalBoolean(value, record, field, level + 1)
      return value
    end,
  }
  for field in pairs(Fields.record) do
    roles[field] = "record"
  end
  for field in pairs(Fields.accessor) do
    roles[field] = "accessor"
  end
  Hints.roles = roles

  ---The part that accepts `field` on `kind`, or `nil` when none does: read
  ---only when `Define` refuses a field.
  ---@param field string
  ---@param kind string
  ---@return string|nil
  function Hints.partOf(field, kind)
    for partName, list in pairs(Fields.parts) do
      local kinds = string.match(list, " " .. field .. "@([^ ]+) ")
      if
        kinds == "*"
        or (kinds == "-" and kind ~= KIND_GROUP)
        or (kinds ~= nil and string.find("," .. kinds .. ",", "," .. kind .. ",", 1, true))
      then
        return partName
      end
    end
    return nil
  end

  ---The handler in force for `record`: its own `handler`, else the nearest
  ---ancestor's, or `nil`. Only the Handlers part accepts `handler`, but the
  ---core answers it for `info.handler` and for the Dynamic part.
  ---@param record table|false
  ---@return table|nil
  function Hints.handlerInForce(record)
    while record do
      local hints = record._hints
      local handler = hints and hints.handler
      if handler ~= nil then
        return handler
      end
      record = rawget(record, "_parent")
    end
    return nil
  end

  ---Resolve one callback field: a function as it is; a method name needs
  ---the Handlers part, which replaces this function; anything else (`nil`,
  ---`false`, a boolean) as it is.
  ---@param _ table the build context
  ---@param record table
  ---@param value any
  ---@param field string
  ---@param level integer
  ---@return any
  function Hints.callback(_, record, value, field, level)
    if type(value) ~= "string" then
      return value
    end
    error(
      needsPart(
        labelOf(record, field) .. ' is a method name ("' .. value .. '"), which',
        "Handlers"
      ),
      level
    )
  end

  ---The value of accessor `field` in force for `record`. Without the
  ---Handlers part, no group passes an accessor down, so it is the spec's own.
  ---@param context table
  ---@param record table
  ---@param own any the spec's own value
  ---@param field string
  ---@param level integer
  ---@return any
  function Hints.accessor(context, record, own, field, level)
    return Hints.callback(context, record, own, field, level + 1)
  end

  ---Turn the method names among the hints into callers (or refuse them
  ---without the Handlers part). A group's accessors stay as written: each
  ---option below it resolves them against its own handler in force.
  ---@param context table
  ---@param record table
  ---@param level integer
  function Hints.resolve(context, record, level)
    local hints = record._hints
    if hints == nil or not context.usesMethodNames then
      return
    end
    local isGroup = rawget(record, "_kind") == KIND_GROUP
    for field, value in pairs(hints) do
      if
        type(value) == "string"
        and Fields.method[field]
        and not (isGroup and Fields.accessor[field])
      then
        hints[field] = Hints.callback(context, record, value, field, level + 1)
      end
    end
  end
end

-- What reads and writes a bound option (`bind`): the Bind part's, which
-- replaces `build`, `read`, `write` and `validate` when it binds (revision
-- 16). The core reaches them only for a record with `_bindScope`, which only
-- the Bind part builds. A tree revision 15 defined keeps such records across
-- an upgrade to a core without the part: they are then served by revision
-- 15's captured methods (see "Revision 15 routing"), or raise at the
-- caller's line naming the part. `database` and `text` stay the core's: they
-- only read the record, and `IsDisabled` and `Describe` need them.
local Bound = {}

-- The prefix of a bind into a SettingsKit namespace: `ns:<name>.<scope>...`.
Bound.NAMESPACE_PREFIX = "ns:"

---The database a bound record reads and writes: the namespace child a `ns:`
---bind found at `Define` (kept under key `0` of the keys array, outside its
---array part), else the tree's database.
---@param tree OptionsKit.Tree
---@param record table
---@return table db
function Bound.database(tree, record)
  local namespaceBinding = rawget(record, "_bindKeys")[0]
  if namespaceBinding ~= nil then
    return namespaceBinding.db
  end
  return rawget(tree, "_db")
end

---The `bind` text of a bound record, rebuilt from its scope and keys.
---Failure and `Describe` paths.
---@param record table
---@return string
function Bound.text(record)
  local keys = rawget(record, "_bindKeys")
  local text = rawget(record, "_bindScope") .. "." .. table.concat(keys, ".")
  local namespaceBinding = keys[0]
  if namespaceBinding ~= nil then
    return Bound.NAMESPACE_PREFIX .. namespaceBinding.name .. "." .. text
  end
  return text
end

---Raise for a bound record met without the Bind part.
---@param record table
---@param methodName string
---@param level integer
function Bound.missing(record, methodName, level)
  error(
    needsPart(tostring(methodName) .. " " .. rawget(record, "_path") .. " is bound, which", "Bind"),
    level
  )
end

-- How a session that upgraded from revision 15 keeps that revision's trees
-- and `Define` working while a part is absent; filled in "Revision 15
-- routing", near the end of the file. One table, one main-chunk local.
local Legacy = {}

---`bind` in a spec without the Bind part (a `Define` the core would refuse
---only for it is handed to revision 15 first, see `define`).
---@param _ table the build context
---@param record table
---@param _ table the spec
---@param level integer
function Bound.build(_, record, _, level)
  error(needsPart(labelOf(record, "bind"), "Bind"), level)
end

---Refuse any field of `spec` that its kind does not accept, and collect the
---hints: every accepted field the record does not keep in a field of its own.
---@param context table the build context, told whether the tree uses method
---names or inherited accessors so the work for them is skipped otherwise
---@param spec table
---@param kind OptionsKit.Kind
---@param record table
---@param level integer
local function checkKnownFields(context, spec, kind, record, level)
  local kindFields = Fields.kind[kind]
  local common, control, valueFields = Fields.common, Fields.control, Fields.value
  local roles, methodFields = Hints.roles, Fields.method
  local isGroup = kind == KIND_GROUP
  local isValueKind = VALUE_KINDS[kind] == true
  local hints = nil
  for field, value in pairs(spec) do
    if type(field) ~= "string" then
      error(labelOf(record) .. " contains a field that is not a string", level)
    end
    -- Refused here, before any field is read: the checks and the record
    -- below test flags such as `disabled`, `tristate` and `hasAlpha` for
    -- truth, and compare numbers and strings, which raises inside
    -- OptionsKit for a secret (Retail 12.x) instead of at the caller.
    if isSecret(value) then
      error(labelOf(record, field) .. " must not be a secret value", level)
    end
    if
      not (
        common[field]
        or kindFields[field]
        or (not isGroup and control[field])
        or (isValueKind and valueFields[field])
      )
    then
      -- A field a part accepts names the part to embed (ADR 0001, point 5).
      local partName = Hints.partOf(field, kind)
      if partName ~= nil and type(rawget(parts, partName)) ~= "table" then
        error(needsPart(labelOf(record, field), partName), level)
      end
      error(
        labelOf(record) .. ' contains unknown field "' .. field .. '" for type "' .. kind .. '"',
        level
      )
    end
    -- One lookup says what the field is (`Hints.roles`): a record field,
    -- an accessor (a hint on a group, which passes it down), a hint with a
    -- check (revision 14, run only for the fields an option sets), or a
    -- plain hint (revision 13: collected in the same walk).
    local role = roles[field]
    if role ~= "record" then
      if role == "accessor" then
        if isGroup then
          Hints.checkAccessor(value, record, field, level + 1)
          context.inheritsAccessors = true
          hints = hints or {}
          hints[field] = value
        end
      else
        if role ~= nil then
          value = role(value, record, field, level + 1)
          if isGroup and field == "confirm" then
            context.groupConfirm = true
          end
        end
        if type(value) == "string" and methodFields[field] then
          context.usesMethodNames = true
        end
        hints = hints or {}
        hints[field] = value
      end
    end
  end
  -- Absent rather than a shared empty table: a record without hints keeps
  -- the slot free.
  if hints ~= nil then
    rawset(record, "_hints", hints)
  end
end

---Check a `range` option's bounds.
---@param spec table
---@param record table
---@param level integer
local function checkRangeFields(spec, record, level)
  checkNumber(spec.min, record, "min", level + 1)
  checkNumber(spec.max, record, "max", level + 1)
  if spec.min > spec.max then
    error(labelOf(record, "min") .. " must not be greater than max", level)
  end
  checkPositiveNumber(spec.step, record, "step", level + 1)
  checkPositiveNumber(spec.bigStep, record, "bigStep", level + 1)
  local softMin = spec.softMin
  local softMax = spec.softMax
  if type(softMin) ~= "nil" then
    checkNumber(softMin, record, "softMin", level + 1)
    if softMin < spec.min or softMin > spec.max then
      error(labelOf(record, "softMin") .. " must lie between min and max", level)
    end
  end
  if type(softMax) ~= "nil" then
    checkNumber(softMax, record, "softMax", level + 1)
    if softMax < spec.min or softMax > spec.max then
      error(labelOf(record, "softMax") .. " must lie between min and max", level)
    end
  end
  if type(softMin) ~= "nil" and type(softMax) ~= "nil" and softMin > softMax then
    error(labelOf(record, "softMin") .. " must not be greater than softMax", level)
  end
  checkOptionalBoolean(spec.isPercent, record, "isPercent", level + 1)
end

---Orders the keys of a `values` table: numbers first, each type ascending.
---@param left string|number
---@param right string|number
---@return boolean
local function compareValueKeys(left, right)
  if type(left) == type(right) then
    return left < right
  end
  return type(left) == "number"
end

---Check and copy a `values` table: keys are strings or numbers, labels
---strings. Returns the copy and its keys, sorted for a deterministic schema.
---@param values table
---@param maxEntries number the tree's `maxDynamicEntries`, `math.huge` when unbounded
---@param record table
---@param level integer
---@return table copy
---@return (string|number)[] keys
local function copyValues(values, maxEntries, record, level)
  local copy = {}
  local keys = {}
  for key, text in pairs(values) do
    local keyType = type(key)
    if keyType ~= "string" and keyType ~= "number" then
      error(labelOf(record, "values") .. " keys must be strings or numbers", level)
    end
    if type(text) ~= "string" then
      error(labelOf(record, "values") .. " labels must be strings", level)
    end
    copy[key] = text
    keys[#keys + 1] = key
  end
  if #keys == 0 then
    error(labelOf(record, "values") .. " must not be empty", level)
  end
  if #keys > maxEntries then
    error(labelOf(record, "values") .. " must have at most " .. maxEntries .. " entries", level)
  end
  return copy, keys
end

---Check and copy a `sorting` array: every entry a string or number and, when
---the values are a table, one of its keys.
---@param sorting any
---@param values table|false copied values, or `false` when they come from a function
---@param record table
---@param level integer
---@return (string|number)[]|false copy
local function copySorting(sorting, values, record, level)
  if type(sorting) == "nil" then
    return false
  end
  if type(sorting) ~= "table" then
    error(labelOf(record, "sorting") .. " must be an array", level)
  end
  local copy = {}
  local count = #sorting
  for index = 1, count do
    local key = sorting[index]
    local keyType = type(key)
    if keyType ~= "string" and keyType ~= "number" then
      error(labelOf(record, "sorting") .. " entries must be strings or numbers", level)
    end
    if values and values[key] == nil then
      error(labelOf(record, "sorting") .. " entries must be keys of values", level)
    end
    copy[index] = key
  end
  for key in pairs(sorting) do
    if type(key) ~= "number" or key < 1 or key > count or key % 1 ~= 0 then
      error(labelOf(record, "sorting") .. " must be an array", level)
    end
  end
  return copy
end

-- Record fields --------------------------------------------------------------
--
-- A record keeps only what it cannot derive (revision 13): its key, depth and
-- bind text come from its path and parent when asked for, so the common
-- option (name, description, get and set or bind, schema) keeps to the 8 hash
-- slots of its constructor instead of 16. Records an older revision built
-- still hold `_key`, `_depth`, `_bind` and `_bindCount`; the accessors below
-- derive the same answers for them.

---The key of `record` in its parent, or `false` for the root. Keys are
---identifiers, so the path's last segment is the key; the string already
---exists, so the match allocates nothing.
---@param record table
---@return string|false
local function keyOf(record)
  local path = rawget(record, "_path")
  if path == "" then
    return false
  end
  return (string.match(path, "[^.]+$"))
end

---How many groups lie above `record`: `0` for the root.
---@param record table
---@return integer
local function depthOf(record)
  local depth = 0
  local parent = rawget(record, "_parent")
  while parent do
    depth = depth + 1
    parent = rawget(parent, "_parent")
  end
  return depth
end

---The presentation field `name` of `record` (`"desc"`, `"order"`,
---`"disabled"` or `"hidden"`), or `nil`. A record revision 12 or earlier built
---keeps it as its own field `legacyName` (`"_desc"`, ...), which is read
---first.
---@param record table
---@param name string
---@param legacyName string
---@return any
local function presentationOf(record, name, legacyName)
  -- Records are OptionsKit's own tables without a metatable, so plain
  -- indexing is a raw lookup without a call; this runs for every option a
  -- `Describe` or an `IsDisabled` walk visits.
  local legacy = record[legacyName]
  if type(legacy) ~= "nil" then
    return legacy
  end
  local hints = record._hints
  if hints then
    return hints[name]
  end
  return nil
end

-- Info tables ----------------------------------------------------------------
--
-- Every callback of an option receives the option's `info`: its key path as an
-- array, its dotted `path`, its `kind` and its `tree`. One per option, kept for
-- the tree's lifetime, but built on first use rather than at `Define`: a tree
-- whose options are never read or shown (an options screen never opened)
-- never pays for them. A record built by an older revision already has one.

---The `info` of `record`, built the first time it is asked for.
---@param record table
---@return OptionsKit.Info
local function infoOf(record)
  local info = rawget(record, "_info")
  if info ~= nil then
    return info
  end
  -- The keys from the root down: collect them up the parent chain, then
  -- reverse them into the array part.
  local depth = depthOf(record)
  info = { path = rawget(record, "_path"), kind = rawget(record, "_kind") }
  local node = record
  for index = depth, 1, -1 do
    info[index] = keyOf(node)
    node = rawget(node, "_parent")
  end
  -- `node` is now the root, which alone keeps the tree.
  info.tree = rawget(node, "_tree")
  -- Revision 14: the option's own `arg` and the handler in force, as
  -- AceConfig's `info` carries them; absent for an option without them.
  local hints = rawget(record, "_hints")
  if hints ~= nil and type(hints.arg) ~= "nil" then
    info.arg = hints.arg
  end
  local handler = Hints.handlerInForce(record)
  if handler ~= nil then
    info.handler = handler
  end
  rawset(record, "_info", info)
  return info
end

-- Schemas --------------------------------------------------------------------

local UNIT_INTERVAL = SchemaKit.number({ min = 0, max = 1 })

-- Shared schemas. A value option's schema depends only on its kind and a few
-- plain fields (`tristate`, `min`/`max`, `pattern`, `hasAlpha`, the keys of a
-- `values` table), and a sealed schema is immutable, so every option with the
-- same inputs shares one: `Define` builds a schema only for inputs it has not
-- seen yet in this session, instead of one node and one sealed record per
-- option. A select or multiselect over a values function is the exception: its
-- check calls that option's function, so it keeps a schema of its own. Keys of
-- a `values` table are cached in a trie (one level per sorted key), so a hit
-- builds no key string. A file-level cache, not package state: a newer revision
-- starts empty, and the trees an older one built keep their own schemas.
local SharedSchemas = {
  -- Fixed schemas by name, built on first use.
  fixed = {},
  -- `min` to `max` to the range schema.
  ranges = {},
  -- `pattern` to the input schema.
  patterns = {},
  -- The trie roots of select and multiselect key sets; a set's schema sits
  -- under the `SharedSchemas.LEAF` key of its last key's node.
  selects = {},
  multiselects = {},
  -- The trie key of a leaf: a table, so it never equals an option key.
  LEAF = {},
}

---The shared schema `name`, built by `build` the first time.
---@param name string
---@param build fun(): table the unsealed node
---@return table schema
function SharedSchemas.fixedSchema(name, build)
  local schema = SharedSchemas.fixed[name]
  if schema == nil then
    schema = SchemaKit:Seal(build())
    SharedSchemas.fixed[name] = schema
  end
  return schema
end

---The trie node of a sorted key list under `root`, created as needed.
---@param root table
---@param keys (string|number)[]
---@return table node
function SharedSchemas.keySetNode(root, keys)
  local node = root
  for index = 1, #keys do
    local key = keys[index]
    local child = node[key]
    if child == nil then
      child = {}
      node[key] = child
    end
    node = child
  end
  return node
end

---The shared schema of a range's bounds. A NaN never reaches here: `Define`
---refuses it first, and it could not be a table key.
---@param min number
---@param max number
---@return table schema
function SharedSchemas.range(min, max)
  local byMax = SharedSchemas.ranges[min]
  if byMax == nil then
    byMax = {}
    SharedSchemas.ranges[min] = byMax
  end
  local schema = byMax[max]
  if schema == nil then
    schema = SchemaKit:Seal(SchemaKit.number({ min = min, max = max }))
    byMax[max] = schema
  end
  return schema
end

---The message for an option whose schema needs SchemaKit's Rules part
---(SchemaKit 0.3.0, revision 7): a pattern or a values function.
---@param label string the option's field label
---@return string
function SharedSchemas.needsRules(label)
  return label
    .. " needs SchemaKit's Rules part: add schemaKit\\parts\\SchemaKit-Rules.lua"
    .. " to embeds.xml (or rebuild it with python3 -m tooling.package.embeds)"
end

---The shared schema of an input's pattern. SchemaKit validates the pattern
---and would report it at its own line; the protected call moves the report to
---the caller of `Define`.
---@param pattern string
---@param record table
---@param level integer
---@return table schema
function SharedSchemas.input(pattern, record, level)
  local schema = SharedSchemas.patterns[pattern]
  if schema == nil then
    -- SchemaKit 0.3.0 (revision 7) builds patterns in its Rules part. Asked
    -- first, so the protected call below never reports the missing part as
    -- an invalid pattern.
    local hasPart = rawget(SchemaKit, "HasPart")
    if type(hasPart) == "function" and hasPart(SchemaKit, "Rules") ~= true then
      error(SharedSchemas.needsRules(labelOf(record, "pattern")), level)
    end
    local built, result = pcall(SchemaKit.string, { pattern = pattern })
    if not built then
      error(labelOf(record, "pattern") .. " is not a valid Lua pattern", level)
    end
    schema = SchemaKit:Seal(result)
    SharedSchemas.patterns[pattern] = schema
  end
  return schema
end

---The shared schema of a select or multiselect over a values table with
---`keys` (sorted).
---@param kind OptionsKit.Kind
---@param keys (string|number)[]
---@return table schema
function SharedSchemas.keySet(kind, keys)
  local root = kind == KIND_SELECT and SharedSchemas.selects or SharedSchemas.multiselects
  local node = SharedSchemas.keySetNode(root, keys)
  local schema = node[SharedSchemas.LEAF]
  if schema == nil then
    local keyNode = SchemaKit.enum(keys)
    if kind == KIND_SELECT then
      schema = SchemaKit:Seal(keyNode)
    else
      schema =
        SchemaKit:Seal(SchemaKit.map({ keys = keyNode, values = SchemaKit.boolean(), max = #keys }))
    end
    node[SharedSchemas.LEAF] = schema
  end
  return schema
end

---Build the check a `select` key must pass when the values come from a
---function: the key is a string or number the function's current table has.
---The option's `info` is read when the check runs, since it is built on first
---use (see `infoOf`).
---@param valuesFunction fun(info: OptionsKit.Info): table
---@param record table the option's record
---@return fun(value: any): boolean
local function newDynamicKeyCheck(valuesFunction, record)
  return function(value)
    local valueType = type(value)
    if valueType ~= "string" and valueType ~= "number" then
      return false
    end
    local values = valuesFunction(infoOf(record))
    return type(values) == "table" and type(values[value]) ~= "nil"
  end
end

---Build the sealed schema of a value option: a shared one (above), or, over a
---values function, one of its own.
---@param kind OptionsKit.Kind
---@param spec table
---@param keys (string|number)[]|false keys of a `select`/`multiselect` values table
---@param valuesFunction function|false a `select`/`multiselect` values function
---@param record table the option's record
---@param dynamicMax integer the map bound of a multiselect over a values function
---@param level integer
---@return table schema
local function buildSchema(kind, spec, keys, valuesFunction, record, dynamicMax, level)
  if kind == KIND_TOGGLE then
    if spec.tristate then
      return SharedSchemas.fixedSchema("tristate", function()
        return SchemaKit.optional(SchemaKit.boolean())
      end)
    end
    return SharedSchemas.fixedSchema("toggle", SchemaKit.boolean)
  elseif kind == KIND_RANGE then
    return SharedSchemas.range(spec.min, spec.max)
  elseif kind == KIND_SELECT or kind == KIND_MULTISELECT then
    if keys then
      return SharedSchemas.keySet(kind, keys)
    end
    ---@cast valuesFunction fun(info: OptionsKit.Info): table
    local hasPart = rawget(SchemaKit, "HasPart")
    if type(hasPart) == "function" and hasPart(SchemaKit, "Rules") ~= true then
      error(SharedSchemas.needsRules(labelOf(record, "values")), level)
    end
    local keyNode = SchemaKit.custom(
      newDynamicKeyCheck(valuesFunction, record),
      "a key of the values of " .. rawget(record, "_path")
    )
    if kind == KIND_SELECT then
      return SchemaKit:Seal(keyNode)
    end
    return SchemaKit:Seal(
      SchemaKit.map({ keys = keyNode, values = SchemaKit.boolean(), max = dynamicMax })
    )
  elseif kind == KIND_INPUT and type(spec.pattern) ~= "nil" then
    return SharedSchemas.input(spec.pattern, record, level + 1)
  elseif kind == KIND_COLOR then
    if spec.hasAlpha then
      return SharedSchemas.fixedSchema("colorAlpha", function()
        return SchemaKit.table({
          fields = { r = UNIT_INTERVAL, g = UNIT_INTERVAL, b = UNIT_INTERVAL, a = UNIT_INTERVAL },
        })
      end)
    end
    return SharedSchemas.fixedSchema("color", function()
      return SchemaKit.table({
        fields = { r = UNIT_INTERVAL, g = UNIT_INTERVAL, b = UNIT_INTERVAL },
      })
    end)
  end
  -- An input without a pattern, and a keybinding.
  return SharedSchemas.fixedSchema("string", SchemaKit.string)
end

-- Building -------------------------------------------------------------------

---Orders siblings by `order`, then name, then key. Plain data only: no
---consumer code runs inside `table.sort`.
---@param left table
---@param right table
---@return boolean
local function compareRecords(left, right)
  -- Only `Define` sorts, and only records it has just built, which have no
  -- metatable: plain indexing is a raw lookup without a call, which matters
  -- because `table.sort` calls this about n log n times.
  local leftHints, rightHints = left._hints, right._hints
  local leftOrder = leftHints and leftHints.order or DEFAULT_ORDER
  local rightOrder = rightHints and rightHints.order or DEFAULT_ORDER
  if leftOrder ~= rightOrder then
    return leftOrder < rightOrder
  end
  local leftName = left._name
  local rightName = right._name
  if leftName ~= rightName then
    return leftName < rightName
  end
  return keyOf(left) < keyOf(right)
end

---Fill the value fields of a record: schema, reader and writer, validator.
---The accessors are the option's own or, with the Handlers part, the nearest
---group's above it (resolved here once); a method name becomes the caller of
---that method of the handler in force. A bind is the Bind part's.
---@param context table build context
---@param record table
---@param spec table
---@param level integer
local function buildValueFields(context, record, spec, level)
  local kind = rawget(record, "_kind")

  if type(spec.bind) ~= "nil" then
    -- Only the Bind part accepts `bind`, so it is loaded here.
    Bound.build(context, record, spec, level + 1)
  else
    -- Functions of its own, the common case, need no resolution.
    local getter, setter = spec.get, spec.set
    if type(getter) ~= "function" then
      getter = Hints.accessor(context, record, getter, "get", level + 1)
    end
    if type(setter) ~= "function" then
      setter = Hints.accessor(context, record, setter, "set", level + 1)
    end
    if type(getter) ~= "function" or type(setter) ~= "function" then
      if type(spec.get) ~= "nil" and type(spec.get) ~= "function" and spec.get ~= false then
        error(labelOf(record, "get") .. " must be a function, a method name or false", level)
      end
      if type(spec.set) ~= "nil" and type(spec.set) ~= "function" and spec.set ~= false then
        error(labelOf(record, "set") .. " must be a function, a method name or false", level)
      end
      error(labelOf(record) .. " needs get and set functions, or bind", level)
    end
    rawset(record, "_get", getter)
    rawset(record, "_set", setter)
  end

  local validate = spec.validate
  if type(validate) ~= "nil" and type(validate) ~= "function" and type(validate) ~= "string" then
    if validate ~= false then
      error(labelOf(record, "validate") .. " must be a function, a method name or false", level)
    end
  end
  if type(validate) == "string" or (validate == nil and context.inheritsAccessors) then
    validate = Hints.accessor(context, record, validate, "validate", level + 1)
  end
  -- Absent fields stay `nil` rather than `false`: a value record then keeps
  -- the 8 hash slots its constructor sized.
  if type(validate) == "function" then
    rawset(record, "_validate", validate)
  end

  local keys = false ---@type (string|number)[]|false
  local valuesFunction = false ---@type function|false
  if kind == KIND_TOGGLE then
    checkOptionalBoolean(spec.tristate, record, "tristate", level + 1)
  elseif kind == KIND_RANGE then
    checkRangeFields(spec, record, level + 1)
  elseif kind == KIND_SELECT or kind == KIND_MULTISELECT then
    local values = spec.values
    local copied = false ---@type table|false
    if type(values) == "string" then
      values = Hints.callback(context, record, values, "values", level + 1)
    end
    if type(values) == "function" then
      valuesFunction = values
    elseif type(values) == "table" then
      -- One checked copy per values table and `Define`: options that share
      -- a table share its copy and sorted keys, which nothing modifies.
      local shared = context.valueCopies[values]
      if shared == nil then
        local copy, sortedKeys = copyValues(values, context.maxDynamicEntries, record, level + 1)
        table.sort(sortedKeys, compareValueKeys)
        shared = { copy = copy, keys = sortedKeys }
        context.valueCopies[values] = shared
      end
      copied, keys = shared.copy, shared.keys
    else
      error(labelOf(record, "values") .. " must be a table, a function or a method name", level)
    end
    rawset(record, "_values", copied or valuesFunction)
    local sorting = spec.sorting
    if type(sorting) == "string" then
      sorting = Hints.callback(context, record, sorting, "sorting", level + 1)
    end
    if type(sorting) == "function" then
      -- Resolved and checked by `Describe` (the Presentation part).
      Hints.functionForm(record, "sorting", level + 1)
      rawset(record, "_sorting", sorting)
    else
      rawset(record, "_sorting", copySorting(sorting, copied, record, level + 1) or nil)
    end
  elseif kind == KIND_INPUT then
    checkOptionalString(spec.pattern, record, "pattern", level + 1)
    local multiline = spec.multiline
    if
      type(multiline) ~= "nil"
      and type(multiline) ~= "boolean"
      and not (
        type(multiline) == "number"
        and multiline >= 1
        and multiline % 1 == 0
        and multiline < math.huge
      )
    then
      error(labelOf(record, "multiline") .. " must be a boolean or a positive integer", level)
    end
    checkOptionalString(spec.usage, record, "usage", level + 1)
  elseif kind == KIND_COLOR then
    checkOptionalBoolean(spec.hasAlpha, record, "hasAlpha", level + 1)
  end

  local dynamicMax = context.maxDynamicEntries
  if dynamicMax == math.huge then
    dynamicMax = UNBOUNDED_MAP_MAX
  end
  rawset(
    record,
    "_schema",
    buildSchema(kind, spec, keys, valuesFunction, record, dynamicMax, level + 1)
  )
end

local buildOption

---Build every child of a group, sort them and link them to the group. The
---options of the group's `plugins` (revision 14) are built as children too:
---a plugin's name is not part of any path, and a key that two plugins, or a
---plugin and `args`, both define is refused.
---@param context table
---@param record table the group's record
---@param args any
---@param plugins any
---@param depth integer the group's depth
---@param level integer
local function buildChildren(context, record, args, plugins, depth, level)
  if type(args) ~= "table" then
    error(labelOf(record, "args") .. " must be a table", level)
  end
  local children = {}
  for key, childSpec in pairs(args) do
    if type(key) ~= "string" or not key:find(KEY_PATTERN) then
      error(labelOf(record, "args") .. " keys must be identifiers (letters, digits and _)", level)
    end
    children[#children + 1] = buildOption(context, childSpec, record, key, depth + 1, level + 1)
  end
  if type(plugins) ~= "nil" then
    -- Only the Handlers part accepts `plugins`, so it is loaded here.
    Hints.buildPlugins(context, record, args, plugins, children, depth, level + 1)
  end
  local dynamic = false
  for index = 1, #children do
    local child = children[index]
    local hints = child._hints
    if
      type(child._name) == "function"
      or (hints and type(hints.order) ~= "nil" and type(hints.order) ~= "number")
    then
      dynamic = true
      break
    end
  end
  -- A function `name` or `order` is accepted only with the Presentation
  -- part, whose comparator sorts it.
  table.sort(children, dynamic and Hints.compareDynamicRecords or compareRecords)
  rawset(record, "_children", children)
end

---Build the record of one option and, for a group, of everything below it.
---@param context table
---@param spec any
---@param parent table|false
---@param key string|false
---@param depth integer how many groups lie above the option
---@param level integer
---@return table record
buildOption = function(context, spec, parent, key, depth, level)
  local path = ""
  if parent then
    local parentPath = rawget(parent, "_path")
    path = parentPath == "" and key or parentPath .. "." .. key
  end
  if type(spec) ~= "table" then
    error(optionLabel(path) .. " must be an option table", level)
  end
  local kind = spec.type
  if isSecret(kind) then
    error(optionLabel(path) .. ".type must not be a secret value", level)
  end
  if type(kind) ~= "string" or Fields.kind[kind] == nil then
    error(optionLabel(path) .. '.type must be an option type such as "group" or "toggle"', level)
  end

  -- Eight constructor entries, so Lua sizes an 8-slot hash part, which a
  -- value option (kind, path, parent, name, get and set or bind, schema and
  -- hints) fills without a rehash. `desc`, `order`, `disabled` and `hidden`
  -- live in `_hints` with the renderer hints (`checkKnownFields`), and `_name` is
  -- set once the fields are checked (it is tested for truth, which a secret
  -- refuses). The checks below raise before the record is used. `_info` is
  -- built on first use (`infoOf`); only the root keeps the tree.
  local record = {
    _kind = kind,
    _path = path,
    _parent = parent,
    _name = false,
    -- Listed to size the hash part; `nil` until set.
    _hints = nil,
    _get = nil,
    _set = nil,
    _schema = nil,
  }
  checkKnownFields(context, spec, kind, record, level + 1)

  local isRoot = parent == false
  if isRoot and kind ~= KIND_GROUP then
    error(labelOf(record, "type") .. ' must be "group" at the root', level)
  end
  Hints.checkCommon(spec, isRoot, record, level + 1)
  -- A function name (revision 14) is kept here as it is: `Describe` calls
  -- it, and the sort at `Define` uses the key in its place.
  rawset(record, "_name", spec.name or context.addonName)

  if parent then
    if depth > context.maxDepth then
      error(labelOf(record) .. " is deeper than " .. context.maxDepth .. " levels", level)
    end
    context.count = context.count + 1
    if context.count > context.maxOptions then
      error(context.label .. " has more than " .. context.maxOptions .. " options", level)
    end
  end

  if isRoot then
    rawset(record, "_tree", context.tree)
  end
  Hints.resolve(context, record, level + 1)

  if kind == KIND_GROUP then
    checkOptionalBoolean(spec.inline, record, "inline", level + 1)
    if
      type(spec.childGroups) ~= "nil"
      and (isSecret(spec.childGroups) or CHILD_GROUPS[spec.childGroups] ~= true)
    then
      error(labelOf(record, "childGroups") .. ' must be "tab", "tree" or "select"', level)
    end
    -- A group `ProfileOptions` returned is linked to the tree by the
    -- Profiles part (revision 2), which fills this hook when it binds.
    local collectProfileLink = Hints.collectProfileLink
    if collectProfileLink ~= nil then
      collectProfileLink(context, spec, path, record, level + 1)
    end
    buildChildren(context, record, spec.args, spec.plugins, depth, level + 1)
  elseif VALUE_KINDS[kind] then
    buildValueFields(context, record, spec, level + 1)
  elseif kind == KIND_EXECUTE then
    local own = spec.func
    if type(own) ~= "nil" and type(own) ~= "function" and type(own) ~= "string" then
      error(labelOf(record, "func") .. " must be a function", level)
    end
    local func = Hints.accessor(context, record, own, "func", level + 1)
    if type(func) ~= "function" then
      error(labelOf(record, "func") .. " must be a function", level)
    end
    rawset(record, "_func", func)
  elseif kind == KIND_DESCRIPTION then
    local fontSize = spec.fontSize
    if
      type(fontSize) ~= "nil"
      and type(fontSize) ~= "function"
      and FONT_SIZES[fontSize] ~= true
    then
      error(
        labelOf(record, "fontSize") .. ' must be "small", "medium", "large" or a function',
        level
      )
    end
    if type(fontSize) == "function" then
      Hints.functionForm(record, "fontSize", level + 1)
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

---Strip the `file:line: ` position an error message carries, keeping its text.
---@param message any
---@return string
local function withoutPosition(message)
  local text = tostring(message)
  return (text:gsub("^[^\n]-:%d+: ", "", 1))
end

---@param tree OptionsKit.Tree
---@param record table
---@param methodName string
---@param level integer
---@return any
local function readValue(tree, record, methodName, level)
  if rawget(record, "_bindScope") then
    return Bound.read(tree, record, methodName, level + 1)
  end
  return rawget(record, "_get")(infoOf(record))
end

---@param tree OptionsKit.Tree
---@param record table
---@param value any
---@param methodName string
---@param level integer
local function writeValue(tree, record, value, methodName, level)
  if rawget(record, "_bindScope") then
    Bound.write(tree, record, value, methodName, level + 1)
    return
  end
  rawget(record, "_set")(infoOf(record), value)
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
  local accepted, message = validate(infoOf(record), value)
  if not isSecret(accepted) and accepted == true then
    return true, nil
  end
  if type(message) ~= "string" then
    message = "refused by validate"
  end
  return false, message
end

---Evaluate one `disabled`/`hidden` field on `record` and its ancestors.
---@param record table|false
---@param field string `"disabled"` or `"hidden"`
---@param legacyField string `"_disabled"` or `"_hidden"`, where revision 12 kept it
---@return boolean
local function effectiveFlag(record, field, legacyField)
  while record do
    local flag = presentationOf(record, field, legacyField)
    if flag == true then
      return true
    end
    -- A predicate's answer is consumer code's and may be secret (Retail
    -- 12.x); testing a secret for truth raises, so a secret answer counts
    -- as "no", the answer that keeps the option usable.
    if flag then
      local answer = flag(infoOf(record))
      if not isSecret(answer) and answer then
        return true
      end
    end
    record = rawget(record, "_parent")
  end
  return false
end

---Whether a SettingsKit database refuses every write: SettingsKit opens data
---a newer version of the addon saved read-only (SettingsKit revision 5 and
---later). A database without `IsReadOnly` (an older SettingsKit revision, or
---a stand-in) is writable. The answer is asked about secrecy before it is
---compared, as every answer from outside OptionsKit is, and a secret answer
---counts as writable.
---@param db table
---@return boolean
local function isDatabaseReadOnly(db)
  local method = db.IsReadOnly
  if type(method) ~= "function" then
    return false
  end
  local answer = method(db)
  return not isSecret(answer) and answer == true
end

---Whether `record` is disabled: its own `disabled` or a group's above it, or,
---for an option bound to a database path, a read-only database, so a
---renderer greys out a value SettingsKit would refuse to write.
---@param tree OptionsKit.Tree
---@param record table
---@param methodName string the public method asking, named in a Bind refusal
---@param level integer
---@return boolean
local function isRecordDisabled(tree, record, methodName, level)
  if effectiveFlag(record, "disabled", "_disabled") then
    return true
  end
  if rawget(record, "_bindScope") then
    return isDatabaseReadOnly(Bound.database(tree, record, methodName, level + 1))
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
  if rawget(record, "_bindScope") then
    -- A bound record a revision 15 tree kept, without the Bind part.
    local legacySet = Legacy.method("Bind", "Set")
    if legacySet ~= nil then
      local written, message = legacySet(self, path, value)
      return written, message
    end
  end
  local schema = rawget(record, "_schema")
  -- `Check` first, so the valid path builds no label: `Assert` runs only to
  -- raise the refusal at the caller's line, naming the option.
  if not schema:Check(value) then
    schema:Assert(value, "OptionsKit.Tree:Set " .. rawget(record, "_path"), 2)
  end
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
  return Bound.validate(self, record, value, "OptionsKit.Tree:Validate", 3)
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
      'OptionsKit.Tree:Reset path "' .. path .. '" is not bound to a database and has no default',
      2
    )
  end
  local legacyReset = Legacy.method("Bind", "Reset")
  if legacyReset ~= nil then
    local reset = legacyReset(self, path)
    return reset
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
  rawget(record, "_func")(infoOf(record))
end

---Whether the option at `path`, or a group above it, is disabled; a bound
---option also while its database is read-only.
---@param self OptionsKit.Tree
---@param path string
---@return boolean
local function treeIsDisabled(self, path)
  validateTree(self, "OptionsKit.Tree:IsDisabled", 3)
  local record = findRecord(self, path, "OptionsKit.Tree:IsDisabled", 3)
  return isRecordDisabled(self, record, "OptionsKit.Tree:IsDisabled", 3)
end

---Check the optional interface argument of `IsHidden`, `Describe` and
---`DescribeOption` (revision 14): `nil`, `"dialog"` or `"cmd"`.
---@param interface any
---@param methodName string
---@param level integer
local function checkInterface(interface, methodName, level)
  if type(interface) == "nil" then
    return
  end
  if isSecret(interface) or Fields.interfaces[interface] == nil then
    error(methodName .. ' interface must be "dialog" or "cmd"', level)
  end
end

-- What `Describe` resolves at describe time: the Presentation part's
-- function forms, hint functions and per-interface flags (`name`, `order`,
-- `hint`, `sortNodes`, `sortingFunction`, `inline`, `hiddenFlag`), filled
-- when it binds; `nil` without it. One table, so the main chunk spends one
-- local on them (revision 16).
local Resolve = {}

---Whether `record` or a group above it is hidden for `interface` (`nil`: the
---plain `hidden` flags only). A secret predicate answer counts as "no", as in
---`effectiveFlag`.
---@param record table|false
---@param interface string|nil
---@return boolean
local function effectiveHidden(record, interface)
  while record do
    local flag
    -- Only the Presentation part accepts per-interface flags; without it the
    -- interface's answer is the plain `hidden`.
    if interface == nil or Resolve.hiddenFlag == nil then
      flag = presentationOf(record, "hidden", "_hidden")
    else
      flag = Resolve.hiddenFlag(record, interface)
    end
    if flag == true then
      return true
    end
    if flag then
      local answer = flag(infoOf(record))
      if not isSecret(answer) and answer then
        return true
      end
    end
    record = rawget(record, "_parent")
  end
  return false
end

---Whether the option at `path`, or a group above it, is hidden, for
---`interface` when one is given (revision 14).
---@param self OptionsKit.Tree
---@param path string
---@param interface "dialog"|"cmd"|nil
---@return boolean
local function treeIsHidden(self, path, interface)
  validateTree(self, "OptionsKit.Tree:IsHidden", 3)
  local record = findRecord(self, path, "OptionsKit.Tree:IsHidden", 3)
  if interface ~= nil then
    checkInterface(interface, "OptionsKit.Tree:IsHidden", 3)
    -- Only the Presentation part reads per-interface flags; a tree revision
    -- 15 defined with them keeps that revision's answer while it is absent.
    if Resolve.hiddenFlag == nil then
      local legacyIsHidden = Legacy.describer(self, "IsHidden")
      if legacyIsHidden ~= nil then
        local hidden = legacyIsHidden(self, path, interface)
        return hidden
      end
    end
  end
  return effectiveHidden(record, interface)
end

---The `confirm` in force for `record`: its own, else the nearest group's
---above it (AceConfig inherits it), `nil` when none says.
---@param record table|false
---@return any
local function confirmOf(record)
  while record do
    local hints = record._hints
    local confirm = hints and hints.confirm
    if type(confirm) ~= "nil" then
      return confirm
    end
    record = rawget(record, "_parent")
  end
  return nil
end

---The text to ask with when `confirm` is `true`: the option's
---`confirmText`, else its name and, after `" - "`, its description, each
---resolved as `Describe` resolves it (AceConfigDialog's default question).
---@param record table
---@return string
local function defaultConfirmation(record)
  local hints = record._hints
  local text = hints and hints.confirmText
  if type(text) == "string" then
    return text
  end
  local name = rawget(record, "_name")
  if type(name) == "function" then
    name = name(infoOf(record))
  end
  if type(name) ~= "string" or isSecret(name) then
    name = keyOf(record) or ""
  end
  local desc = presentationOf(record, "desc", "_desc")
  if type(desc) == "function" then
    desc = desc(infoOf(record))
  end
  if type(desc) == "string" and not isSecret(desc) and desc ~= "" then
    return name .. " - " .. desc
  end
  return name
end

---The question to ask before `Set(path, value)` or `Execute(path)`, or `nil`
---when none is needed (revision 14). `Set` and `Execute` never ask: a
---renderer calls this first.
---@param self OptionsKit.Tree
---@param path string
---@param value any the value about to be set; `nil` for an `execute`
---@return string|nil question
local function treeGetConfirmation(self, path, value)
  validateTree(self, "OptionsKit.Tree:GetConfirmation", 3)
  local record = findRecord(self, path, "OptionsKit.Tree:GetConfirmation", 3)
  local confirm = confirmOf(record)
  if type(confirm) == "function" then
    confirm = confirm(infoOf(record), value)
    -- A string is the question, secret or not: it is handed on, never
    -- compared. Anything else is tested only once known not to be secret.
    if type(confirm) == "string" then
      return confirm
    end
    if isSecret(confirm) then
      return nil
    end
  end
  if type(confirm) == "string" then
    return confirm
  end
  if confirm == true then
    return defaultConfirmation(record)
  end
  return nil
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
    visitor(rawget(record, "_path"), rawget(record, "_kind"), depthOf(record))
  end
  return count
end

---Connect `callback(tree, path)` to every change of the tree's structure
---(revision 15): a `Replace` or `Remove`, and a `NotifyChange` that makes a
---clean tree dirty. The signal is created on the first connection, so a tree
---nobody listens to has none. A static tree (no Dynamic part) never fires
---it, so a renderer may connect whatever parts are loaded.
---@param self OptionsKit.Tree
---@param callback fun(tree: OptionsKit.Tree, path: string)
---@return table connection a SignalKit connection
local function treeOnStructureChanged(self, callback)
  validateTree(self, "OptionsKit.Tree:OnStructureChanged", 3)
  if type(callback) ~= "function" then
    error("OptionsKit.Tree:OnStructureChanged callback must be a function", 2)
  end
  local signal = rawget(self, "_structureChanged")
  if signal == nil then
    signal = SignalKit:New()
    rawset(self, "_structureChanged", signal)
  end
  return signal:Connect(callback)
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
---@param methodName string the public method describing, named in its errors
---@param level integer
---@return table
local function describeValues(record, methodName, level)
  local values = rawget(record, "_values")
  if type(values) == "function" then
    values = values(infoOf(record))
    if type(values) ~= "table" then
      error(
        methodName .. ' values function of "' .. rawget(record, "_path") .. '" returned no table',
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

---Raise for a presentation function of a tree revision 15 defined, met
---after a core-only upgrade without the Presentation part.
---@param record table
---@param field string
---@param methodName string
---@param level integer
local function presentationMissing(record, field, methodName, level)
  error(
    needsPart(
      methodName .. " " .. field .. ' of "' .. rawget(record, "_path") .. '" is a function, which',
      "Presentation"
    ),
    level
  )
end

---The sorting array of a select for its description: a copy of the array,
---or a sorting function's answer (the Presentation part's).
---@param record table
---@param values table the described values
---@param methodName string
---@param level integer
---@return (string|number)[]|nil
local function describeSorting(record, values, methodName, level)
  local sorting = rawget(record, "_sorting")
  if type(sorting) == "function" then
    if Resolve.sortingFunction == nil then
      presentationMissing(record, "sorting", methodName, level + 1)
    end
    return Resolve.sortingFunction(record, sorting, values, methodName, level + 1)
  end
  if sorting then
    local copy = {}
    for index = 1, #sorting do
      copy[index] = sorting[index]
    end
    return copy
  end
  return nil
end

---Build the description of `record` and everything below it, for
---`interface` when one is given (revision 14: `hidden` and `inline` are then
---that interface's).
---@param tree OptionsKit.Tree
---@param record table
---@param methodName string the public method describing, named in its errors
---@param level integer
---@param interface string|nil
---@return OptionsKit.Description node
---@return boolean dynamic whether its name or order came from a function
local function describeRecord(tree, record, methodName, level, interface, inheritedConfirm)
  local kind = rawget(record, "_kind")
  local name = rawget(record, "_name")
  local dynamic = false
  if type(name) == "function" then
    if Resolve.name == nil then
      presentationMissing(record, "name", methodName, level + 1)
    end
    name, dynamic = Resolve.name(record, methodName, level + 1)
  end
  local order = presentationOf(record, "order", "_order")
  if order == nil then
    order = DEFAULT_ORDER
  elseif type(order) == "function" then
    if Resolve.order == nil then
      presentationMissing(record, "order", methodName, level + 1)
    end
    order, dynamic = Resolve.order(record, methodName, level + 1)
  end
  local node = {
    kind = kind,
    path = rawget(record, "_path"),
    depth = depthOf(record),
    name = name,
    order = order,
    disabled = isRecordDisabled(tree, record, methodName, level + 1),
    hidden = effectiveHidden(record, interface),
  }
  local key = keyOf(record)
  if key then
    node.key = key
  end
  local desc = presentationOf(record, "desc", "_desc")
  if type(desc) == "function" then
    desc = desc(infoOf(record))
    if type(desc) ~= "string" then
      error(
        methodName .. ' desc function of "' .. rawget(record, "_path") .. '" returned no string',
        level
      )
    end
  end
  -- A type test, not a truth test: a `desc` function may return a secret
  -- string, which is passed through like a getter's secret value.
  if type(desc) == "string" then
    node.desc = desc
  end
  local hints = rawget(record, "_hints")
  if hints ~= nil then
    local notDescribed = Fields.notDescribed
    for field, value in pairs(hints) do
      if not notDescribed[field] then
        local valueType = type(value)
        if valueType == "function" or valueType == "table" then
          -- Only the Presentation part accepts a function or a table hint.
          if Resolve.hint == nil then
            presentationMissing(record, field, methodName, level + 1)
          end
          Resolve.hint(node, record, field, value, methodName, level + 1)
        elseif node[field] == nil then
          node[field] = value
        end
      end
    end
    if kind == KIND_GROUP then
      if interface ~= nil and Resolve.inline ~= nil then
        node.inline = Resolve.inline(hints, interface)
      else
        node.inline = hints.inline
      end
    end
  end
  -- The `confirm` in force, a group's included (handed down by the parent's
  -- description); `true` for a function, whose question `GetConfirmation`
  -- answers.
  local confirm = hints and hints.confirm
  if confirm == nil then
    confirm = inheritedConfirm
  end
  if type(confirm) == "function" then
    node.confirm = true
  elseif type(confirm) ~= "nil" then
    node.confirm = confirm
  end

  if kind == KIND_GROUP then
    local children = rawget(record, "_children")
    local described = {}
    local resort = false
    for index = 1, #children do
      local child, childDynamic =
        describeRecord(tree, children[index], methodName, level + 1, interface, confirm)
      described[index] = child
      resort = resort or childDynamic
    end
    if resort then
      Resolve.sortNodes(described)
    end
    node.children = described
  elseif VALUE_KINDS[kind] then
    local bound = rawget(record, "_bindScope")
        and Bound.database(tree, record, methodName, level + 1)
      or false
    node.value = snapshotValue(readValue(tree, record, methodName, level + 1), bound, 1, nil)
    node.schema = rawget(record, "_schema"):Describe()
    if rawget(record, "_bindScope") then
      node.bind = Bound.text(record)
    end
    if kind == KIND_SELECT or kind == KIND_MULTISELECT then
      node.values = describeValues(record, methodName, level + 1)
      node.sorting = describeSorting(record, node.values, methodName, level + 1)
    end
  end
  return node, dynamic
end

---A fresh plain description of the whole tree, for renderers: every option's
---fields, effective `disabled`/`hidden`, current value and schema description.
---Allocates by design; call it again to refresh. `interface` (revision 14),
---`"dialog"` or `"cmd"`, makes `hidden` and `inline` that interface's.
---@param self OptionsKit.Tree
---@param interface "dialog"|"cmd"|nil
---@return OptionsKit.Description root
local function treeDescribe(self, interface)
  validateTree(self, "OptionsKit.Tree:Describe", 3)
  if interface ~= nil then
    checkInterface(interface, "OptionsKit.Tree:Describe", 3)
  end
  local legacyDescribe = Legacy.describer(self, "Describe")
  if legacyDescribe ~= nil then
    local described = legacyDescribe(self, interface)
    return described
  end
  local root =
    describeRecord(self, rawget(self, "_root"), "OptionsKit.Tree:Describe", 3, interface, nil)
  root.addonName = rawget(self, "_addonName")
  return root
end

---A fresh plain description of the option at `path` and everything below it:
---exactly the node `Describe` would build for it, so only that option's (or
---group's) getters, predicates, `desc` and values functions run. `""` names
---the root and answers what `Describe` answers. `nil` when the tree has no
---option at `path`; a path that is not a string, or is secret, raises.
---A command line or a renderer that refreshes one widget calls this instead
---of describing the whole tree.
---@param self OptionsKit.Tree
---@param path string
---@param interface "dialog"|"cmd"|nil
---@return OptionsKit.Description|nil node
local function treeDescribeOption(self, path, interface)
  validateTree(self, "OptionsKit.Tree:DescribeOption", 3)
  if isSecret(path) then
    error("OptionsKit.Tree:DescribeOption path must not be a secret value", 2)
  end
  if type(path) ~= "string" then
    error("OptionsKit.Tree:DescribeOption path must be a string", 2)
  end
  if interface ~= nil then
    checkInterface(interface, "OptionsKit.Tree:DescribeOption", 3)
  end
  local legacyDescribeOption = Legacy.describer(self, "DescribeOption")
  if legacyDescribeOption ~= nil then
    local described = legacyDescribeOption(self, path, interface)
    return described
  end
  if path == "" then
    local root = describeRecord(
      self,
      rawget(self, "_root"),
      "OptionsKit.Tree:DescribeOption",
      3,
      interface,
      nil
    )
    root.addonName = rawget(self, "_addonName")
    return root
  end
  local record = rawget(rawget(self, "_records"), path)
  if record == nil then
    return nil
  end
  -- Only a tree with a group's `confirm` needs the walk up.
  local inherited = nil
  if rawget(self, "_groupConfirm") then
    inherited = confirmOf(rawget(record, "_parent"))
  end
  return (describeRecord(self, record, "OptionsKit.Tree:DescribeOption", 3, interface, inherited))
end

-- Profile groups -------------------------------------------------------------
--
-- `OptionsKit:ProfileOptions` and the links that connect its group to a tree
-- live in the Profiles part (ADR 0001; part revision 2 took the links from
-- the core, revision 16). The part fills three hooks when it binds:
-- `Hints.collectProfileLink` (`Define` meets a group), `Hints.attachLinks`
-- (`Define` places the groups) and `Hints.detachProfileLink`. The core keeps
-- `findSettingsKit`, which the parts call, and a detach of its own, which
-- `Undefine` and the Dynamic part use for a link attached by any revision.

---Find SettingsKit API 1 through the Registry, or `nil`. It is an optional
---dependency, so it is looked up at call time, never at load. Not kept
---between calls: `ProfileOptions` refuses at once when SettingsKit is gone
---from the Registry (a retired copy, whose table is in no state to be used),
---even for a database whose group it built.
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

---Detach `link` from its tree: disconnect the profile signals, so the group
---can be defined again elsewhere. Kept in the core because a link attached by
---revision 15 or by any part revision has this layout, and `Undefine` must
---free it whether the Profiles part is loaded or not.
---@param link table
local function detachProfileLink(link)
  local connections = link.connections
  if not connections then
    return
  end
  for index = 1, #connections do
    connections[index]:Disconnect()
  end
  link.connections = false
  link.tree = false
  link.path = nil
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
  if type(value) == "nil" then
    return default
  end
  -- Refused before any comparison: the checks below compare numbers, and a
  -- secret compared with a number raises inside OptionsKit, not at the caller.
  if isSecret(value) then
    error("OptionsKit:Define options." .. name .. " must not be a secret value", level)
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
      "OptionsKit:Define options." .. name .. " must be a positive integer or OptionsKit.UNBOUNDED",
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
  if type(value) == "nil" then
    return MAX_DEPTH
  end
  if isSecret(value) then
    error("OptionsKit:Define options.maxDepth must not be a secret value", level)
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
  if type(options) == "nil" then
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
  if type(db) == "nil" then
    return false
  end
  if findSettingsKit() == nil then
    error("OptionsKit:Define options.db needs SettingsKit API 1 to be loaded", level)
  end
  if type(db) ~= "table" or type(db.OnChange) ~= "function" or type(db.Validate) ~= "function" then
    error("OptionsKit:Define options.db must be a SettingsKit database", level)
  end
  return db
end

---A fresh build context: what `buildOption` reads and fills while it checks a
---tree, for `Define`, a rebuild and a `Replace` alike.
---@param addonName string
---@param tree OptionsKit.Tree|false
---@param db table|false
---@param label string the label the count limit's message starts with
---@return table context
local function newBuildContext(addonName, tree, db, label)
  return {
    db = db,
    tree = tree,
    addonName = addonName,
    label = label,
    count = 0,
    records = {},
    -- A values table to its checked copy and sorted keys, `{ copy, keys }`,
    -- so the options sharing one table share them.
    valueCopies = {},
    -- A handler to its method callers by name (revision 14), so the options
    -- naming one method of one handler share one caller.
    methodCallers = {},
    -- The profile groups met while building, and the path of each.
    profileLinks = {},
    profilePaths = {},
    -- The tree being rebuilt, whose own profile groups stay attached
    -- (revision 15), or `false`.
    rebuilding = false,
    -- Numbers, `math.huge` for `OptionsKit.UNBOUNDED`; `readDefineOptions`
    -- or the tree's kept limits fill them in.
    maxOptions = MAX_OPTIONS,
    maxDepth = MAX_DEPTH,
    maxDynamicEntries = MAX_DYNAMIC_ENTRIES,
  }
end

---Build and check the records of `spec` as the root of `context`'s tree.
---Returns the root record and the walk array. Raises at `level` for a field
---refused.
---@param context table
---@param spec any
---@param level integer
---@return table root
---@return table[] walk
local function buildStructure(context, spec, level)
  local root = buildOption(context, spec, false, false, 0, level + 1)
  local walk = {}
  flatten(root, walk)
  return root, walk
end

---Attach the profile groups `Define` collected. Only the Profiles part
---collects them, so a list that is not empty means its hook is there.
---@param links table[]
---@param paths string[]
---@param tree OptionsKit.Tree
local function attachLinks(links, paths, tree)
  if #links > 0 then
    Hints.attachLinks(links, paths, tree)
  end
end

---The message of a member whose part is not loaded (ADR 0001, point 5).
---@param member string the member as the caller writes it
---@param partName string
---@return string
local function partMissingMessage(member, partName)
  return member
    .. " is in OptionsKit's "
    .. partName
    .. " part, which is not loaded: add optionsKit\\parts\\OptionsKit-"
    .. partName
    .. ".lua to embeds.xml (or rebuild it with python3 -m tooling.package.embeds)"
end

---Define the options tree of an addon. The tree is checked in full and copied:
---later edits to the tables passed have no effect until `NotifyChange`
---(revision 15, Dynamic part). `spec` may be a builder, `fun(addonName):
---table`, called now and on every rebuild (Dynamic part).
---@param _ OptionsKit
---@param addonName string
---@param spec OptionsKit.Option|fun(addonName: string): OptionsKit.Option the root group
---@param options OptionsKit.DefineOptions?
---@return OptionsKit.Tree tree
local function define(_, addonName, spec, options)
  validateAddonName(addonName, "OptionsKit:Define addonName", 3)
  if rawget(trees, addonName) ~= nil then
    error('OptionsKit:Define "' .. addonName .. '" already has a tree; Undefine it first', 2)
  end
  local builder = nil
  if type(spec) == "function" then
    if rawget(parts, "Dynamic") == nil then
      error(
        "OptionsKit:Define tree is a function, which needs OptionsKit's Dynamic part: add optionsKit\\parts\\OptionsKit-Dynamic.lua to embeds.xml (or rebuild it with python3 -m tooling.package.embeds)",
        2
      )
    end
    builder = spec
  end
  if builder == nil then
    local legacyTree = Legacy.define(addonName, spec, options)
    if legacyTree ~= nil then
      return legacyTree
    end
  end
  local context = newBuildContext(addonName, false, false, DEFINE_LABEL)
  local db = readDefineOptions(options, context, 3)
  if builder ~= nil then
    -- The builder's own error propagates as it is: it is the addon's code.
    spec = builder(addonName)
    if type(spec) ~= "table" then
      error("OptionsKit:Define tree function must return the root group table", 2)
    end
  end

  local tree = setmetatable({
    _schema = TREE_SCHEMA,
    _addonName = addonName,
    _defined = false,
    _db = db,
    -- The limits the tree was defined under, `math.huge` for unbounded:
    -- a rebuild or a `Replace` (revision 15) checks against them.
    _maxOptions = context.maxOptions,
    _maxDepth = context.maxDepth,
    _maxDynamicEntries = context.maxDynamicEntries,
  }, TREE_METATABLE)
  if builder ~= nil then
    rawset(tree, "_builder", builder)
  end
  context.db = db
  context.tree = tree
  LabelBase.prefix, LabelBase.path = DEFINE_LABEL, ""
  local root, walk = buildStructure(context, spec, 3)

  rawset(tree, "_root", root)
  rawset(tree, "_records", context.records)
  rawset(tree, "_walk", walk)
  rawset(tree, "_changed", SignalKit:New())
  -- Attached last: a refusal above leaves no link pointing at this tree,
  -- and a link that fails to attach frees the ones attached before it.
  attachLinks(context.profileLinks, context.profilePaths, tree)
  rawset(tree, "_profileLinks", context.profileLinks)
  if context.groupConfirm then
    -- A group's `confirm` applies below it; `DescribeOption` then looks up.
    rawset(tree, "_groupConfirm", true)
  end
  rawset(tree, "_defined", true)
  rawset(trees, addonName, tree)
  if builder == nil then
    -- Weakly: kept only while the addon holds the table itself.
    rawset(treeSources, tree, spec)
  end
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
  rawset(treeSources, tree, nil)
  rawget(tree, "_changed"):DisconnectAll()
  local structureChanged = rawget(tree, "_structureChanged")
  if structureChanged ~= nil then
    structureChanged:DisconnectAll()
  end
  local links = rawget(tree, "_profileLinks")
  for index = 1, #links do
    local link = links[index]
    detachProfileLink(link)
    -- The group is cached per database (revision 8), so the next tree may
    -- receive it again: it starts there with no copy or delete choice, as a
    -- freshly built group did.
    link.copySource = false
    link.deleteTarget = false
  end
  return true
end

---The fields `kind` accepts (revision 14), each mapped to a fresh set of the
---forms it takes: Lua type names, `method` for a string naming a handler
---method and `any` for `arg`. A fresh table on every call, for converters
---such as BridgeKit's, which ask once per conversion.
---@param _ OptionsKit
---@param kind OptionsKit.Kind
---@return table<string, table<string, true>>
local function getFields(_, kind)
  if isSecret(kind) or type(kind) ~= "string" or Fields.kind[kind] == nil then
    error('OptionsKit:GetFields kind must be an option type such as "group" or "toggle"', 2)
  end
  local accepted = {}
  for field in pairs(Fields.common) do
    accepted[field] = true
  end
  for field in pairs(Fields.kind[kind]) do
    accepted[field] = true
  end
  if kind ~= KIND_GROUP then
    for field in pairs(Fields.control) do
      accepted[field] = true
    end
  end
  if VALUE_KINDS[kind] then
    for field in pairs(Fields.value) do
      accepted[field] = true
    end
  end
  -- A method name is a form only with the Handlers part, and the function
  -- form of `name`, `order`, `fontSize` and `sorting` only with the
  -- Presentation part (revision 16).
  local methods = type(rawget(parts, "Handlers")) == "table"
  local functions = type(rawget(parts, "Presentation")) == "table"
  local fields = {}
  for field, letters in string.gmatch(Fields.forms, "(%w+)=(%a+)") do
    if accepted[field] then
      local forms = {}
      for letter in string.gmatch(letters, "%a") do
        if
          (letter ~= "m" or methods)
          and (letter ~= "f" or functions or not Fields.functionForms[field])
        then
          forms[Fields.formNames[letter]] = true
        end
      end
      fields[field] = forms
    end
  end
  return fields
end

---The addon names that have a tree, sorted: a fresh array (revision 15), for
---diagnostics, as AceConfigRegistry's `IterateOptionsTables`.
---@param _ OptionsKit
---@return string[]
local function getTrees(_)
  local names = {}
  for addonName in pairs(trees) do
    names[#names + 1] = addonName
  end
  table.sort(names)
  return names
end

---Whether the part `partName` is loaded (revision 15): `"Profiles"` or
---`"Dynamic"`. A converter or a renderer asks before it relies on one.
---@param _ OptionsKit
---@param partName string
---@return boolean
local function isPartLoaded(_, partName)
  if isSecret(partName) or type(partName) ~= "string" then
    error("OptionsKit:IsPartLoaded partName must be a string", 2)
  end
  return type(rawget(parts, partName)) == "table"
end

---A member that raises at the caller's line, naming the part to embed.
---@param member string
---@param partName string
---@return function
local function partStub(member, partName)
  return function()
    error(partMissingMessage(member, partName), 2)
  end
end

-- Revision 15 routing ---------------------------------------------------------
--
-- Revision 15 was the last core with the presentation fields, method names
-- and binds inside. An addon embedding revision 15 alone may share a session
-- with one embedding this core without the parts. Before this core commits,
-- an upgrade from revision 15 captures that revision's `Define` and tree
-- methods into `state.legacyMembers.revision15`, and marks the trees that
-- need a part. Routing happens only on the branch that needs an absent part,
-- never on the common path:
--
--   * a bound record (`_bindScope`) with the Bind part absent: `Get`, `Set`,
--     `Validate` and `Reset` call revision 15's method for the whole call;
--   * a marked tree with the Presentation or Bind part absent: `Describe`,
--     `DescribeOption` and `IsHidden` with an interface call revision 15's;
--   * a `Define` whose spec uses a field of an absent part is handed to
--     revision 15's `Define`, and the tree it returns is marked.
--
-- Method callers, inherited accessors and plugins are resolved into the
-- records at `Define`, so trees using them need no routing. Once every part
-- is loaded, `Legacy.dropWhenComplete` removes the captured functions, so the
-- revision 15 closures are collected and this revision serves throughout.

-- The tree methods captured from revision 15.
Legacy.METHODS = { "Get", "Set", "Validate", "Reset", "IsHidden", "Describe", "DescribeOption" }

-- The parts revision 15 had inside its single file.
Legacy.PARTS = { "Presentation", "Handlers", "Bind" }

---The captured revision 15 functions while some part is absent, else `nil`.
---@return table|nil
function Legacy.captured()
  local legacy = rawget(state, "legacyMembers")
  return type(legacy) == "table" and legacy.revision15 or nil
end

---Revision 15's method `methodName` when `partName` is absent and something
---was captured, else `nil`.
---@param partName string
---@param methodName string
---@return function|nil
function Legacy.method(partName, methodName)
  local captured = Legacy.captured()
  if captured == nil or type(rawget(parts, partName)) == "table" then
    return nil
  end
  return captured[methodName]
end

---Revision 15's describing method for `tree`, when the tree was marked as
---needing a part that is absent, else `nil`.
---@param tree OptionsKit.Tree
---@param methodName string `"Describe"`, `"DescribeOption"` or `"IsHidden"`
---@return function|nil
function Legacy.describer(tree, methodName)
  local captured = Legacy.captured()
  if captured == nil or captured.trees[tree] == nil then
    return nil
  end
  return Legacy.method("Presentation", methodName) or Legacy.method("Bind", methodName)
end

---Whether `spec` (an option table and everything below it) uses a field
---of a part that is not loaded. Read only while revision 15 is captured.
---@param spec any
---@param depth integer
---@return boolean
function Legacy.specNeedsAbsentPart(spec, depth)
  if type(spec) ~= "table" or depth > MAX_DEPTH_CEILING then
    return false
  end
  local kind = spec.type
  for field, value in pairs(spec) do
    if type(field) == "string" then
      local partName = Hints.partOf(field, kind)
      if partName ~= nil and type(rawget(parts, partName)) ~= "table" then
        return true
      end
      if
        type(value) == "string"
        and Fields.method[field]
        and type(rawget(parts, "Handlers")) ~= "table"
      then
        return true
      end
      if
        type(value) == "function"
        and Fields.functionForms[field]
        and type(rawget(parts, "Presentation")) ~= "table"
      then
        return true
      end
    end
  end
  for _, children in pairs({ spec.args, spec.plugins }) do
    if type(children) == "table" then
      for _, child in pairs(children) do
        if spec.plugins == children and type(child) == "table" then
          for _, pluginChild in pairs(child) do
            if Legacy.specNeedsAbsentPart(pluginChild, depth + 1) then
              return true
            end
          end
        elseif Legacy.specNeedsAbsentPart(child, depth + 1) then
          return true
        end
      end
    end
  end
  return false
end

---Hand a `Define` this core would refuse only for an absent part to revision
---15's, and mark the tree it returns. `nil` when it is not handed over.
---@param addonName string
---@param spec any
---@param options any
---@return OptionsKit.Tree|nil
function Legacy.define(addonName, spec, options)
  local captured = Legacy.captured()
  if captured == nil or not Legacy.specNeedsAbsentPart(spec, 1) then
    return nil
  end
  local tree = captured.Define(OptionsKit, addonName, spec, options)
  captured.trees[tree] = true
  return tree
end

---Drop the captured revision 15 functions once every part it had inside is
---loaded. Called at this core's commit and by each part when it installs.
function Legacy.dropWhenComplete()
  local legacy = rawget(state, "legacyMembers")
  if type(legacy) ~= "table" or legacy.revision15 == nil then
    return
  end
  for index = 1, #Legacy.PARTS do
    if type(rawget(parts, Legacy.PARTS[index])) ~= "table" then
      return
    end
  end
  legacy.revision15 = nil
end

---`Get` of a bound record without the Bind part.
---@param tree OptionsKit.Tree
---@param record table
---@param methodName string
---@param level integer
---@return any
function Bound.read(tree, record, methodName, level)
  local get = Legacy.method("Bind", "Get")
  if get == nil then
    Bound.missing(record, methodName, level + 1)
  end
  local value = get(tree, rawget(record, "_path"))
  return value
end

---Write of a bound record without the Bind part. `Set` and `Reset` hand the
---whole call to revision 15 before they get here, so this only raises.
---@param _ OptionsKit.Tree
---@param record table
---@param _ any
---@param methodName string
---@param level integer
function Bound.write(_, record, _, methodName, level)
  Bound.missing(record, methodName, level + 1)
end

---`Validate` of a bound record without the Bind part.
---@param tree OptionsKit.Tree
---@param record table
---@param value any
---@param methodName string
---@param level integer
---@return boolean accepted
---@return string|nil message
function Bound.validate(tree, record, value, methodName, level)
  local validate = Legacy.method("Bind", "Validate")
  if validate == nil then
    Bound.missing(record, methodName, level + 1)
  end
  local accepted, message = validate(tree, rawget(record, "_path"), value)
  return accepted, message
end

-- The capture itself, before this core's methods are committed.
if previousRevision == 15 then
  -- Defined inside the branch, so the function is freed with the main chunk.
  ---Whether one record built by revision 15 needs a part: a bind, a function
  ---name or sorting, or a hint only the Presentation part resolves.
  ---@param record table
  ---@return boolean
  local function recordNeedsPart(record)
    if
      rawget(record, "_bindScope") ~= nil
      or type(rawget(record, "_name")) == "function"
      or type(rawget(record, "_sorting")) == "function"
    then
      return true
    end
    local hints = rawget(record, "_hints")
    if hints == nil then
      return false
    end
    for field, value in pairs(hints) do
      local valueType = type(value)
      if valueType == "function" or valueType == "table" then
        return true
      end
      if Hints.partOf(field, rawget(record, "_kind")) == "Presentation" then
        return true
      end
    end
    return false
  end

  local captured = {
    Define = rawget(OptionsKit, "Define"),
    -- Trees that need a part, weakly: an undefined tree is not kept.
    trees = setmetatable({}, { __mode = "k" }),
  }
  for index = 1, #Legacy.METHODS do
    local name = Legacy.METHODS[index]
    captured[name] = rawget(Tree, name)
  end
  for _, existingTree in next, trees do
    for _, record in next, rawget(existingTree, "_records") do
      if recordNeedsPart(record) then
        captured.trees[existingTree] = true
        break
      end
    end
  end
  local legacy = rawget(state, "legacyMembers")
  if type(legacy) ~= "table" then
    legacy = {}
    rawset(state, "legacyMembers", legacy)
  end
  legacy.revision15 = captured
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
rawset(Tree, "DescribeOption", treeDescribeOption)
rawset(Tree, "OnChange", treeOnChange)
rawset(Tree, "GetConfirmation", treeGetConfirmation)
rawset(Tree, "OnStructureChanged", treeOnStructureChanged)

rawset(OptionsKit, "API", API_GENERATION)
rawset(OptionsKit, "REVISION", IMPLEMENTATION_REVISION)
rawset(OptionsKit, "MAX_OPTIONS", MAX_OPTIONS)
rawset(OptionsKit, "MAX_DEPTH", MAX_DEPTH)
rawset(OptionsKit, "UNBOUNDED", UNBOUNDED)
-- A copy, so a consumer that writes to the published table cannot change
-- what `Define` accepts. Its presence tells other Kits this revision knows
-- the `childGroups` hint.
rawset(OptionsKit, "CHILD_GROUPS", { tab = true, tree = true, select = true })
rawset(OptionsKit, "Define", define)
rawset(OptionsKit, "Get", getTree)
rawset(OptionsKit, "Undefine", undefine)
rawset(OptionsKit, "GetFields", getFields)
rawset(OptionsKit, "GetTrees", getTrees)
rawset(OptionsKit, "IsPartLoaded", isPartLoaded)

-- The core functions the parts call, rewritten by every core revision and
-- handed to every loaded part's `bind`, so each part runs the newest ones.
-- Additive inside API 1: a helper's arguments and meaning never change.
rawset(state, "helpers", {
  isSecret = isSecret,
  isDatabaseReadOnly = isDatabaseReadOnly,
  findSettingsKit = findSettingsKit,
  checkOptionalString = checkOptionalString,
  checkNumber = checkNumber,
  checkOptionalFunction = checkOptionalFunction,
  validateTree = validateTree,
  findRecord = findRecord,
  newBuildContext = newBuildContext,
  buildStructure = buildStructure,
  buildOption = buildOption,
  flatten = flatten,
  -- The plain comparator, or the Presentation part's, which sorts function
  -- names and orders, once that part has bound. Read through the hook at
  -- call time, so the order the parts bind in does not matter.
  compareRecords = function(left, right)
    return (Hints.compareDynamicRecords or compareRecords)(left, right)
  end,
  depthOf = depthOf,
  attachLinks = attachLinks,
  detachProfileLink = detachProfileLink,
  withoutPosition = withoutPosition,
  handlerInForce = Hints.handlerInForce,
  labelBase = LabelBase,
  defineLabel = DEFINE_LABEL,
  keyPattern = KEY_PATTERN,
  dirty = DIRTY,
  treeSources = treeSources,
  -- Revision 16: what the Presentation, Handlers and Bind parts extend and
  -- call (ADR 0001).
  Fields = Fields,
  Hints = Hints,
  Resolve = Resolve,
  Bound = Bound,
  needsPart = needsPart,
  labelOf = labelOf,
  checkOptionalStringOrFunction = checkOptionalStringOrFunction,
  checkOptionalBoolean = checkOptionalBoolean,
  checkPositiveNumber = checkPositiveNumber,
  infoOf = infoOf,
  keyOf = keyOf,
  presentationOf = presentationOf,
  defaultOrder = DEFAULT_ORDER,
  fontSizes = FONT_SIZES,
  checkMethodPredicate = Hints.checkMethodPredicate,
  kindGroup = KIND_GROUP,
  dropLegacyWhenComplete = Legacy.dropWhenComplete,
})

-- Members of parts: the loaded part's own, else (for `ProfileOptions`) the
-- function an older single-file revision installed, else a stub naming the
-- part. A loaded part takes the newest helpers.
local legacyMembers = rawget(state, "legacyMembers")
for partName, members in pairs(PART_MEMBERS) do
  local part = rawget(parts, partName)
  local provided = type(part) == "table" and part.members or nil
  if type(part) == "table" and type(part.bind) == "function" then
    part.bind(rawget(state, "helpers"))
  end
  for index = 1, #members.facade do
    local member = members.facade[index]
    local value = provided and provided[member]
    if type(value) ~= "function" and type(legacyMembers) == "table" then
      value = legacyMembers[member]
    end
    if type(value) ~= "function" then
      value = partStub("OptionsKit:" .. member, partName)
    end
    rawset(OptionsKit, member, value)
  end
  for index = 1, #members.tree do
    local member = members.tree[index]
    local value = provided and provided[member]
    if type(value) ~= "function" then
      value = partStub("OptionsKit.Tree:" .. member, partName)
    end
    rawset(Tree, member, value)
  end
end

Legacy.dropWhenComplete()
rawset(state, "runtimeRevision", IMPLEMENTATION_REVISION)

if not validatePublicSurface(OptionsKit) or not validateCurrentState(OptionsKit) then
  error("MoltenCodes OptionsKit package state is corrupted or incomplete", 2)
end

return OptionsKit
