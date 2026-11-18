-- MoltenCodes AddonKit part Database
--
-- `MC:Database(savedVariable, defaults, options?)`: a SettingsKit database
-- opened from an AceDB-style defaults table, plus `MC.Range` and `MC.Enum`,
-- the two schema nodes a defaults table most often needs written by hand.
--
-- The defaults go to `SettingsKit:Open` as they are: SettingsKit's Defaults
-- part reads plain defaults itself, infers every field's type and every map's
-- bound from them and checks writes without SchemaKit (part revision 1 of
-- this file inferred a SchemaKit schema instead; the rules are the same, see
-- SettingsKit's docs/API.md, *Opening a database*). SchemaKit nodes inside the
-- defaults (`MC.Range`, `MC.Enum`, `MC.S.*`) are kept as written. This part
-- adds the AddonKit side: the refusal to open before ADDON_LOADED, the same
-- database for the same defaults table, and refusals of the defaults' scopes
-- that say what to write.
--
-- The part needs AddonKit's core loaded first, and SettingsKit with its
-- Defaults part and LifecycleKit when `Database` runs (LifecycleKit tells
-- whether the addon has loaded: the client restores a saved variable only at
-- ADDON_LOADED). SchemaKit is needed only for the schema nodes.
--
-- Contents
-- --------
--   Constants ........ identity, scopes
--   Dependencies ..... AddonKit's core and its state
--   Scopes ........... the defaults table's scopes checked
--   Methods .......... Database, Range, Enum
--   Commit ........... members and the part's revision

-- Constants ------------------------------------------------------------------

local PART_NAME = "Database"
local PART_REVISION = 2
local REQUIRED_REGISTRY_API = 2
local CORE_PACKAGE, CORE_API = "addonKit", 1

-- SettingsKit's scopes (all ten since its revision 15), in the order a
-- message lists them.
local SCOPE_NAMES = {
  "profile",
  "global",
  "char",
  "realm",
  "class",
  "faction",
  "race",
  "factionrealm",
  "factionrealmregion",
  "locale",
}
local SCOPES = {}
for index = 1, #SCOPE_NAMES do
  SCOPES[SCOPE_NAMES[index]] = true
end

-- Dependencies ---------------------------------------------------------------

-- The shared MoltenCodes namespace is the one documented global handoff point between independently embedded copies.
-- selene: allow(global_usage)
local namespace = rawget(_G, "MoltenCodes")
local generations = type(namespace) == "table" and rawget(namespace, "Registries") or nil
local Registry = type(generations) == "table" and rawget(generations, REQUIRED_REGISTRY_API) or nil
local AddonKit = nil
if type(Registry) == "table" and type(rawget(Registry, "Get")) == "function" then
  AddonKit = Registry:Get(CORE_PACKAGE, CORE_API)
end
local state = type(AddonKit) == "table" and rawget(AddonKit, "_state") or nil
if
  type(state) ~= "table"
  or type(rawget(state, "methods")) ~= "table"
  or type(rawget(state, "helpers")) ~= "table"
  or type(rawget(state, "parts")) ~= "table"
then
  error("MoltenCodes AddonKit part Database requires AddonKit API 1 to be loaded first", 2)
end

local parts = rawget(state, "parts")
local installed = rawget(parts, PART_NAME)
if
  type(installed) == "table"
  and type(installed.revision) == "number"
  and installed.revision >= PART_REVISION
then
  -- An equal or newer revision of this part already serves every facade.
  return AddonKit
end

local methods = rawget(state, "methods")
-- Read at call time, never copied: an upgraded core's helpers serve this part.
local helpers = rawget(state, "helpers")

-- Scopes ---------------------------------------------------------------------
--
-- SettingsKit refuses the same mistakes, in its own words ("schema must
-- declare at least one scope"); these say what to write in the defaults an
-- author passed. They raise with level 0 (no position): `Database` runs them
-- under `callAtCaller`, which raises the message again at the author's line.

---Check the scopes of a whole defaults table: at least one, each a scope
---SettingsKit has, each a table (plain defaults or a schema node).
---@param defaults table
local function checkScopes(defaults)
  local any = false
  for scope, scopeDefaults in pairs(defaults) do
    if type(scope) ~= "string" or not SCOPES[scope] then
      error(
        "MC:Database defaults has the scope "
          .. tostring(scope)
          .. ", which SettingsKit does not have; its scopes are "
          .. table.concat(SCOPE_NAMES, ", "),
        0
      )
    end
    if type(scopeDefaults) ~= "table" then
      error("MC:Database defaults." .. scope .. " must be a table of defaults", 0)
    end
    any = true
  end
  if not any then
    error("MC:Database defaults must hold at least one scope, such as profile = { ... }", 0)
  end
end

-- Methods --------------------------------------------------------------------

---Open a database from AceDB-style defaults, which SettingsKit's Defaults
---part reads.
---
---Refuses to open before the addon's ADDON_LOADED: the client restores the
---saved variable only then and replaces what an earlier open created. A
---second call for the same saved variable answers the same database when it
---is given the same defaults table.
---@param self MoltenCodesFacade
---@param savedVariable string the `## SavedVariables` name
---@param defaults table `{ profile = { ... }, global = { ... } }`
---@param options table? `SettingsKit:Open`'s options
---@return table db a SettingsKit database
local function facadeDatabase(self, savedVariable, defaults, options)
  local record = helpers.requireRecord(self, "MC:Database", 3)
  helpers.requireName(savedVariable, "MC:Database savedVariable", 3)
  if helpers.isSecret(defaults) or type(defaults) ~= "table" then
    error("MC:Database defaults must be a table: { profile = { ... }, global = { ... } }", 2)
  end
  if helpers.isSecret(options) or (type(options) ~= "nil" and type(options) ~= "table") then
    error("MC:Database options must be a table of SettingsKit:Open options or nil", 2)
  end
  local opened = record.databases[savedVariable]
  if opened ~= nil then
    if opened.defaults ~= defaults then
      error(
        "MC:Database "
          .. savedVariable
          .. " is already open with another defaults table; open it once and keep the database (self.db)",
        2
      )
    end
    return opened.db
  end
  local LifecycleKit = helpers.requireKit(record, "LifecycleKit", 3)
  local SettingsKit = helpers.requireKit(record, "SettingsKit", 3)
  local lifecycle = helpers.callAtCaller(3, LifecycleKit.ForAddon, LifecycleKit, record.addonName)
  if not lifecycle:IsLoaded() then
    error(
      record.addonName
        .. " opened "
        .. savedVariable
        .. " before ADDON_LOADED; open it in OnInitialize, after the client restored it",
      2
    )
  end
  helpers.callAtCaller(3, checkScopes, defaults)
  local db =
    helpers.callAtCaller(3, SettingsKit.Open, SettingsKit, savedVariable, defaults, options)
  record.databases[savedVariable] = { defaults = defaults, db = db }
  return db
end

---Refuse a facade passed as the first argument of a dot helper.
---@param first any
---@param label string
---@param usage string
local function refuseColonCall(first, label, usage)
  if helpers.isFacade(first) then
    error(label .. " is called with a dot: " .. usage, 3)
  end
end

---An optional number from `min` to `max`, reading `default` until written:
---`scale = MC.Range(0.5, 2, 1)`.
---@param min number
---@param max number
---@param default number
---@return table node
local function facadeRange(min, max, default)
  if helpers.isSecret(min) or helpers.isSecret(max) or helpers.isSecret(default) then
    error("MC.Range min, max and default must not be secret values", 2)
  end
  refuseColonCall(min, "MC.Range", "MC.Range(min, max, default)")
  if type(min) ~= "number" or type(max) ~= "number" or type(default) ~= "number" then
    error("MC.Range takes three numbers: MC.Range(min, max, default)", 2)
  end
  local SchemaKit = helpers.requireSchemaKit(3)
  local bounded = helpers.callAtCaller(3, SchemaKit.number, { min = min, max = max })
  return helpers.callAtCaller(3, SchemaKit.optional, bounded, default)
end

---An optional choice among `values`, reading `default` until written:
---`anchor = MC.Enum({ "TOP", "CENTER" }, "TOP")`.
---@param values (string|number|boolean)[]
---@param default string|number|boolean
---@return table node
local function facadeEnum(values, default)
  if helpers.isSecret(values) or helpers.isSecret(default) then
    error("MC.Enum values and default must not be secret values", 2)
  end
  refuseColonCall(values, "MC.Enum", "MC.Enum(values, default)")
  if type(values) ~= "table" then
    error(
      "MC.Enum values must be a list of strings, numbers or booleans: MC.Enum(values, default)",
      2
    )
  end
  if default == nil then
    error("MC.Enum needs a default, one of the values: MC.Enum(values, default)", 2)
  end
  local SchemaKit = helpers.requireSchemaKit(3)
  local choice = helpers.callAtCaller(3, SchemaKit.enum, values)
  return helpers.callAtCaller(3, SchemaKit.optional, choice, default)
end

-- Commit ---------------------------------------------------------------------

rawset(methods, "Database", facadeDatabase)
rawset(methods, "Range", facadeRange)
rawset(methods, "Enum", facadeEnum)
rawset(parts, PART_NAME, { revision = PART_REVISION })

return AddonKit
