-- MoltenCodes AddonKit
--
-- One way in for addon authors: `local MC = MoltenCodes:For(...)` in every file
-- of an addon returns that addon's facade. `MC.TimerKit`, `MC.EventKit` and the
-- other Kits resolve on the first read through `Registry:Find` and are cached on
-- the facade, so later reads are plain field reads. `MC:NewAddon()` and
-- `MC:NewModule(name)` give the addon object over ModuleKit. Two optional parts
-- add the rest: `AddonKit-Database` (a SettingsKit database from plain
-- defaults) and `AddonKit-Composition` (the options panel with its slash
-- command, and the minimap launcher).
--
-- AddonKit holds no behaviour of its own beyond lookups, defaults and errors
-- that say the fix. Every call it makes is a documented API 1 call of another
-- Kit, so validation, bounds, secret checks and ownership stay those Kits'.
--
-- Where `For` lives. AddonKit installs `For` on the shared `MoltenCodes`
-- namespace (the same function is `AddonKit:For`). Registry is not touched: it
-- sits at its line budget, it is loaded by every addon that embeds any Kit (a
-- catalogue there would cost addons that never use one), and the catalogue
-- changes with every new Kit. AddonKit writes the key only when it is absent or
-- already holds AddonKit's own entry function, which every revision keeps.
--
-- Generations stay explicit. The catalogue maps each facade name to the API
-- generation AddonKit API 1 hands out. An entry's generation never changes
-- inside AddonKit API 1 (a spec holds it to a baseline); `MC:Use` pins another.
--
-- AddonKit requires Registry API 2 and nothing else. It reads `geterrorhandler`
-- at call time and `issecretvalue` once at load (again on each check only when
-- the host had none at load), and calls no other client function.
--
-- Contents
-- --------
--   Constants ............. identity, limits, the catalogue, part members
--   Public types .......... LuaCATS declarations for the published surface
--   Dependencies .......... Registry, the namespace, host readers
--   Validation ............ public-surface and shared-state predicates
--   Bootstrap ............. Registry registration and inherited state
--   Host facilities ....... secret values, the error handler
--   Messages .............. names, suggestions, the "not loaded" text
--   Kit lookup ............ facade records, resolving and caching Kits
--   Facade metatable ...... reads, writes, the namespace entry
--   Facade methods ........ Use, NewAddon, NewModule, GetAddon, GetModule,
--                           the module defaults and OnModuleCreated
--   Package public API .... For, GetCatalogue, SetLimits, GetLimits
--   Commit ................ helpers, methods, facade fields, namespace, self-check

-- Constants ------------------------------------------------------------------

local PACKAGE_NAME = "addonKit"
local API_GENERATION = 1
local IMPLEMENTATION_REVISION = 3
local REQUIRED_REGISTRY_API = 2
local STATE_SCHEMA = 1

-- `maxFacades`: addons holding a facade in the session. A facade is one small
-- table per addon, kept for the session, so the bound has a ceiling and no
-- unbounded setting.
local MAX_FACADES, FACADES_CEILING = 256, 4096

-- The `__metatable` of every facade; it also marks a facade for `getmetatable`.
local FACADE_METATABLE_TAG = "AddonKit.Facade"

-- The module name of the addon object inside the addon's ModuleKit container.
local MAIN_MODULE = "Main"

-- The key AddonKit installs on the shared namespace.
local NAMESPACE_ENTRY_KEY = "For"

-- Every Kit a facade hands out, by facade name, with the API generation
-- AddonKit API 1 hands out for it. The package ID is the facade name with its
-- first letter lower-cased (`TimerKit` is `timerKit`), so it is not stored.
-- An entry's generation never changes inside AddonKit API 1: a new Kit adds an
-- entry, and a Kit's next generation is reached with `MC:Use`. The Catalogue
-- spec compares this table with every package manifest.
local CATALOGUE = {
  ApiKit = 1,
  BarKit = 1,
  BindingKit = 1,
  BridgeKit = 1,
  BrokerKit = 1,
  CacheKit = 1,
  ClientKit = 1,
  CodecKit = 1,
  CommandKit = 1,
  CommKit = 1,
  CompatKit = 1,
  DialogKit = 1,
  EditModeKit = 1,
  EventKit = 1,
  GlowKit = 1,
  HookKit = 1,
  InteropKit = 1,
  LauncherKit = 1,
  LifecycleKit = 1,
  LocaleKit = 1,
  LogKit = 1,
  MediaKit = 1,
  MenuKit = 1,
  ModuleKit = 1,
  OptionsKit = 1,
  PanelKit = 1,
  PoolKit = 1,
  ProfileKit = 1,
  RangeKit = 1,
  ReadinessKit = 1,
  SchedulerKit = 1,
  SchemaKit = 1,
  SettingsKit = 1,
  SignalKit = 1,
  TestKit = 1,
  TimerKit = 1,
  ToastKit = 1,
  TooltipKit = 1,
  UnitFrameKit = 1,
  WidgetKit = 1,
}

-- Short names the documentation uses: `MC.S` is SchemaKit.
local ALIASES = { S = "SchemaKit" }

-- Facade members that live in a part, by member name. A member read while its
-- part is not loaded raises with the file to embed.
local PART_OF = {
  Database = "Database",
  Range = "Database",
  Enum = "Database",
  Options = "Composition",
  Launcher = "Composition",
  LAUNCHER_DEFAULTS = "Composition",
}

-- How a member is written in a message: methods with a colon, the rest with a dot.
local DOT_MEMBERS = { addonName = true, Registry = true, S = true, Range = true, Enum = true }

local CORE_METHODS = {
  "Use",
  "NewAddon",
  "NewModule",
  "GetAddon",
  "GetModule",
  "SetDefaultModuleState",
  "SetDefaultModulePrototype",
  "OnModuleCreated",
}

-- The ModuleKit revision that added the module defaults and the
-- module-created notice the three forwarders above call.
local MODULE_DEFAULTS_REVISION = 23
local FACADE_METHODS = { "For", "GetCatalogue", "SetLimits", "GetLimits" }

-- The longest edit distance a "did you mean" suggestion may be from what was typed.
local SUGGESTION_DISTANCE = 2

-- Public types ---------------------------------------------------------------

-- The Kits' own classes are declared in their source files, which an addon's
-- workspace holds and AddonKit's own workspace (Registry only) does not.
---@diagnostic disable: undefined-doc-name, undefined-doc-class

---What the addon object's `self.scope` holds while it is enabled, each field
---created on first read and released on disable (ModuleKit's module scope).
---@class AddonKit.Scope
---@field Events EventKit.Scope game events
---@field Timers TimerKit.Scope one-shot and repeating timers
---@field Hooks HookKit.Scope secure and raw hooks
---@field Commands CommandKit.Scope slash commands
---@field Comm CommKit.Scope addon messages
---@field Jobs SchedulerKit.Scope scheduled jobs
---@field Messages SignalKit.BusScope subscriptions on the addon's message bus

---The addon object: ModuleKit's module `"Main"`, or a module of the addon.
---Its own fields (`self.db`, methods) are the author's.
---@class AddonKit.Addon: ModuleKit.Module
---@field scope AddonKit.Scope
---@field OnInitialize fun(self: AddonKit.Addon)?
---@field OnEnable fun(self: AddonKit.Addon)?
---@field OnDisable fun(self: AddonKit.Addon)?
---@field [string] any

---What `MC:Options` takes beside the tree.
---@class AddonKit.OptionsSettings
---@field db SettingsKit.Database? the database every `bind` reads and writes
---@field slash string? a slash command name that opens the panel, without the `/`
---@field title string? the title in the settings list; default: the tree's `name`

---LibDBIcon-1.0's three saved fields, as `MC.LAUNCHER_DEFAULTS` gives them.
---@class AddonKit.LauncherDefaults
---@field hide boolean
---@field lock boolean
---@field minimapPos number

---One addon's facade: `local MC = MoltenCodes:For(...)`.
---@class MoltenCodesFacade
---@field addonName string the addon's folder name
---@field S SchemaKit SchemaKit, under the short name the documentation uses
---@field Registry Registry Registry API 2
---@field ApiKit ApiKit
---@field BarKit BarKit
---@field BindingKit BindingKit
---@field BridgeKit BridgeKit
---@field BrokerKit BrokerKit
---@field CacheKit CacheKit
---@field ClientKit ClientKit
---@field CodecKit CodecKit
---@field CommandKit CommandKit
---@field CommKit CommKit
---@field CompatKit CompatKit
---@field DialogKit DialogKit
---@field EditModeKit EditModeKit
---@field EventKit EventKit
---@field GlowKit GlowKit
---@field HookKit HookKit
---@field InteropKit InteropKit
---@field LauncherKit LauncherKit
---@field LifecycleKit LifecycleKit
---@field LocaleKit LocaleKit
---@field LogKit LogKit
---@field MediaKit MediaKit
---@field MenuKit MenuKit
---@field ModuleKit ModuleKit
---@field OptionsKit OptionsKit
---@field PanelKit PanelKit
---@field PoolKit PoolKit
---@field ProfileKit ProfileKit
---@field RangeKit RangeKit
---@field ReadinessKit ReadinessKit
---@field SchedulerKit SchedulerKit
---@field SchemaKit SchemaKit
---@field SettingsKit SettingsKit
---@field SignalKit SignalKit
---@field TestKit TestKit
---@field TimerKit TimerKit
---@field ToastKit ToastKit
---@field TooltipKit TooltipKit
---@field UnitFrameKit UnitFrameKit
---@field WidgetKit WidgetKit
---@field Use fun(self: MoltenCodesFacade, facadeName: string, generation: integer)
---@field NewAddon fun(self: MoltenCodesFacade, definition: ModuleKit.Definition?): AddonKit.Addon
---@field NewModule fun(self: MoltenCodesFacade, name: string, definition: ModuleKit.Definition?): AddonKit.Addon
---@field GetAddon fun(self: MoltenCodesFacade): AddonKit.Addon
---@field GetModule fun(self: MoltenCodesFacade, name: string): AddonKit.Addon
---@field SetDefaultModuleState fun(self: MoltenCodesFacade, enabled: boolean): boolean
---@field SetDefaultModulePrototype fun(self: MoltenCodesFacade, prototype: table?): table?
---@field OnModuleCreated fun(self: MoltenCodesFacade, callback: function|table, methodName: string?): SignalKit.Connection?, string?
---@field Database fun(self: MoltenCodesFacade, savedVariable: string, defaults: table, options: SettingsKit.Options?): SettingsKit.Database Database part
---@field Range fun(min: number, max: number, default: number): table Database part: an optional bounded number
---@field Enum fun(values: (string|number|boolean)[], default: string|number|boolean): table Database part: an optional choice
---@field Options fun(self: MoltenCodesFacade, tree: table, settings: AddonKit.OptionsSettings?): PanelKit.Panel Composition part
---@field Launcher fun(self: MoltenCodesFacade, definition: table, db: SettingsKit.Database, field: string?): LauncherKit.Launcher Composition part
---@field LAUNCHER_DEFAULTS AddonKit.LauncherDefaults Composition part: a fresh table per addon

---@diagnostic enable: undefined-doc-name, undefined-doc-class

---The shared limits.
---@class AddonKit.Limits
---@field maxFacades integer Addons holding a facade: 1 to 4096; default `256`.

---One catalogue entry, as `GetCatalogue` copies it.
---@class AddonKit.CatalogueEntry
---@field packageId string
---@field api integer

---The AddonKit package facade published through Registry.
---@class AddonKit
---@field API integer Public API generation.
---@field REVISION integer Compatible implementation revision.
---@field MAX_FACADES integer Default of `maxFacades` (`256`).
---@field FACADES_CEILING integer The highest `maxFacades` accepts (`4096`).
---@field For fun(self: AddonKit|MoltenCodesNamespace, addonName: string, ...: any): MoltenCodesFacade
---@field GetCatalogue fun(self: AddonKit): table<string, AddonKit.CatalogueEntry>
---@field SetLimits fun(self: AddonKit, limits: AddonKit.Limits)
---@field GetLimits fun(self: AddonKit): AddonKit.Limits

---AddonKit adds `For` to the shared namespace.
---@class MoltenCodesNamespace
---@field For fun(self: MoltenCodesNamespace, addonName: string, ...: any): MoltenCodesFacade

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
  error("MoltenCodes AddonKit requires Registry API 2 to be loaded first", 2)
end

local bootstrapPackage = rawget(Registry, "Bootstrap")
local findPackage = rawget(Registry, "Find")
if type(bootstrapPackage) ~= "function" or type(findPackage) ~= "function" then
  error("MoltenCodes AddonKit requires a valid Registry API 2 facade", 2)
end

-- Validation -----------------------------------------------------------------

---Whether `implementation` exposes the complete AddonKit API 1 surface.
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
local function isFacadeLimit(value)
  return type(value) == "number" and value >= 1 and value <= FACADES_CEILING and value % 1 == 0
end

-- The state fields every API 1 revision shares, with the type each must have.
local STATE_FIELDS = {
  runtimeRevision = "number",
  limits = "table",
  facades = "table",
  records = "table",
  facadeCount = "number",
  methods = "table",
  fields = "table",
  helpers = "table",
  parts = "table",
  dispatch = "table",
  metatable = "table",
  entry = "function",
}

---Whether `currentState` has the fields every API 1 revision shares.
---@param currentState any
---@return boolean
local function validateStateBase(currentState)
  if type(currentState) ~= "table" or rawget(currentState, "schema") ~= STATE_SCHEMA then
    return false
  end
  for field, fieldType in pairs(STATE_FIELDS) do
    if type(rawget(currentState, field)) ~= fieldType then
      return false
    end
  end
  return isFacadeLimit(rawget(rawget(currentState, "limits"), "maxFacades"))
end

---Whether `implementation` carries package state of this revision's schema.
---@param implementation table
---@return boolean
local function validateCurrentState(implementation)
  return validateStateBase(rawget(implementation, "_state"))
end

-- Bootstrap ------------------------------------------------------------------

-- `Registry:Bootstrap` owns the reconciliation every embedded package repeats:
-- look the package up, refuse to reinterpret state owned by a newer revision,
-- and register this one. What stays here is what only AddonKit can answer.
local AddonKit, previousRevision, selected = bootstrapPackage(Registry, {
  package = PACKAGE_NAME,
  api = API_GENERATION,
  revision = IMPLEMENTATION_REVISION,
  label = "MoltenCodes AddonKit",
  validatePublicSurface = validatePublicSurface,
  validateState = validateCurrentState,
})

if AddonKit == nil then
  -- An equal or newer compatible revision already owns the shared package table.
  return selected
end

local state = rawget(AddonKit, "_state")

if previousRevision == nil then
  if state ~= nil then
    error("MoltenCodes AddonKit package state is corrupted or incomplete", 2)
  end

  -- Functions every loading revision rewrites. Every facade's metatable and
  -- the namespace entry hold the closures below for the session, so they look
  -- their behaviour up here and an upgraded revision takes them over.
  local dispatch = {}

  state = {
    schema = STATE_SCHEMA,
    runtimeRevision = 0,
    limits = { maxFacades = MAX_FACADES },
    -- Addon name to facade; facade to its private record; how many there are.
    facades = {},
    records = {},
    facadeCount = 0,
    -- Facade members by name: methods (core and parts), and field factories
    -- whose value is made once per facade (parts).
    methods = {},
    fields = {},
    -- Core functions the parts call through this table, so a part always runs
    -- the newest core's helpers.
    helpers = {},
    -- Part name to `{ revision = n }`, written by each part file.
    parts = {},
    dispatch = dispatch,
    -- Whether a foreign value on `MoltenCodes.For` was already reported.
    reportedForeignEntry = false,
    -- No tail calls below: a tail call would drop this frame and shift the
    -- stack level every error counts from.
    metatable = {
      __index = function(facade, key)
        local value = dispatch.index(facade, key)
        return value
      end,
      __newindex = function(facade, key, value)
        dispatch.newindex(facade, key, value)
      end,
      __metatable = FACADE_METATABLE_TAG,
    },
    entry = function(receiver, addonName, ...)
      local facade = dispatch.forEntry(receiver, addonName, ...)
      return facade
    end,
  }
  rawset(AddonKit, "_state", state)
elseif not validateStateBase(state) then
  error("MoltenCodes AddonKit package state is corrupted or incomplete", 2)
end

---@type table<string, table>
local facades = rawget(state, "facades")
---@type table<table, table>
local records = rawget(state, "records")
local methods = rawget(state, "methods")
local fields = rawget(state, "fields")
local helpers = rawget(state, "helpers")
local dispatch = rawget(state, "dispatch")
local FACADE_METATABLE = rawget(state, "metatable")
local namespaceEntry = rawget(state, "entry")
local sharedLimits = rawget(state, "limits")

-- Host facilities ------------------------------------------------------------

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

-- shared:begin reportError 1
-- Copied from tooling/shared/lua/reportError.lua by python3 -m tooling.shared.sync; edit that file, not this copy.
---Report `failure` through the host error handler, or print it.
---@param failure any
local function reportError(failure)
  -- geterrorhandler is a client API reachable only through the global table.
  -- selene: allow(global_usage)
  local getErrorHandler = rawget(_G, "geterrorhandler")
  if type(getErrorHandler) == "function" then
    local handler = getErrorHandler()
    if type(handler) == "function" and pcall(handler, failure) then
      return
    end
  end
  print(failure)
end
-- shared:end reportError

---Remove a leading `AddonKit...lua:<line>: ` position from `message`, so a
---message raised again at the author's line names only the author's line.
---@param message any
---@return any
local function withoutAddonKitPosition(message)
  if type(message) ~= "string" then
    return message
  end
  local stripped = string.gsub(message, "^[^\n]-AddonKit[%w%-]*%.lua%]?:%d+: ", "", 1)
  return stripped
end

---Call `func(...)` and return what it returns; when it raises, raise its
---message again at `level`, so a Kit's refusal points at the author's line.
---A Kit called under `pcall` reports at the `pcall` frame, which carries no
---position, so its message arrives bare.
---@param level integer stack level the failure is reported at
---@param func function
---@return any ...
local function callAtCaller(level, func, ...)
  local results = { pcall(func, ...) }
  if not results[1] then
    error(withoutAddonKitPosition(results[2]), level)
  end
  return unpack(results, 2, table.maxn(results))
end

-- Messages -------------------------------------------------------------------

---The package ID of a catalogue name: `TimerKit` is `timerKit`.
---@param facadeName string
---@return string
local function packageIdOf(facadeName)
  return string.lower(string.sub(facadeName, 1, 1)) .. string.sub(facadeName, 2)
end

---How `key` is written in a message: `MC.TimerKit` or `MC:Database`.
---@param key string
---@return string
local function memberText(key)
  if CATALOGUE[key] or DOT_MEMBERS[key] or string.match(key, "^[A-Z_]+$") then
    return "MC." .. key
  end
  return "MC:" .. key
end

---The edit distance between `left` and `right`, or `limit + 1` once it is
---certainly larger than `limit`. Runs only on the error path.
---@param left string
---@param right string
---@param limit integer
---@return integer
local function editDistance(left, right, limit)
  local leftLength, rightLength = #left, #right
  if math.abs(leftLength - rightLength) > limit then
    return limit + 1
  end
  local previous = {}
  for column = 0, rightLength do
    previous[column] = column
  end
  for row = 1, leftLength do
    local current = { [0] = row }
    local smallest = row
    local leftByte = string.byte(left, row)
    for column = 1, rightLength do
      local cost = leftByte == string.byte(right, column) and 0 or 1
      local value =
        math.min(previous[column] + 1, current[column - 1] + 1, previous[column - 1] + cost)
      current[column] = value
      if value < smallest then
        smallest = value
      end
    end
    if smallest > limit then
      return limit + 1
    end
    previous = current
  end
  return previous[rightLength]
end

---Every name a facade answers, for suggestions.
---@return string[]
local function knownMembers()
  local names = { "addonName", "Registry" }
  for name in pairs(CATALOGUE) do
    names[#names + 1] = name
  end
  for name in pairs(ALIASES) do
    names[#names + 1] = name
  end
  for name in pairs(methods) do
    names[#names + 1] = name
  end
  for name in pairs(PART_OF) do
    if methods[name] == nil then
      names[#names + 1] = name
    end
  end
  table.sort(names)
  return names
end

---The member closest to `typed`, ignoring case and a missing `Kit` suffix,
---within `SUGGESTION_DISTANCE` edits; `nil` when none is close.
---@param typed string
---@return string?
local function suggestionFor(typed)
  local lowered = string.lower(typed)
  local best, bestDistance = nil, SUGGESTION_DISTANCE + 1
  local names = knownMembers()
  for index = 1, #names do
    local name = names[index]
    local candidate = string.lower(name)
    local distance = editDistance(lowered, candidate, SUGGESTION_DISTANCE)
    if candidate == lowered .. "kit" then
      distance = 0
    end
    if distance < bestDistance then
      best, bestDistance = name, distance
    end
  end
  return best
end

---The message for a facade read of a name AddonKit does not know.
---@param key string
---@return string
local function unknownMemberMessage(key)
  local message = "MoltenCodes has no Kit or helper named " .. key
  local suggestion = suggestionFor(key)
  if suggestion ~= nil then
    message = message .. "; did you mean " .. memberText(suggestion) .. "?"
  end
  return message
end

---The message for a Kit that `Registry:Find` did not answer.
---@param addonName string? `nil` when no facade asked (`MC.Range`)
---@param facadeName string
---@param generation integer
---@param reason any `Registry:Find`'s reason
---@return string
local function notLoadedMessage(addonName, facadeName, generation, reason)
  local who = addonName and (addonName .. " uses") or "This needs"
  local file = packageIdOf(facadeName) .. "\\" .. facadeName .. ".lua"
  if reason == "generation_mismatch" then
    return string.format(
      "%s MoltenCodes %s API %d, but only another API generation of it is loaded."
        .. " Embed a copy of %s that provides API %d, or pin the loaded one with MC:Use",
      who,
      facadeName,
      generation,
      file,
      generation
    )
  end
  if reason == "retired" then
    return string.format(
      "%s MoltenCodes %s API %d, which was retired by an unfinished upgrade this session; /reload",
      who,
      facadeName,
      generation
    )
  end
  return string.format(
    "%s MoltenCodes %s (API %d), which is not loaded. Add %s to embeds.xml after the files it"
      .. ' needs, or rebuild embeds.xml with the build tool (docs/EMBEDDING.md, "Load order")',
    who,
    facadeName,
    generation,
    file
  )
end

-- Kit lookup -----------------------------------------------------------------

---The private record of a facade receiver, or raise at `level`.
---@param receiver any the table the method was called on
---@param label string public method name, used in the error
---@param level integer stack level the failure is reported at
---@return table record
local function requireRecord(receiver, label, level)
  local record = nil
  if not isSecret(receiver) and type(receiver) == "table" then
    record = records[receiver]
  end
  if record == nil then
    error(label .. " is called with a colon on a facade: " .. label .. "(...)", level)
  end
  return record
end

---The Kit `facadeName` for `record`'s addon, cached on its facade; raise at
---`level` when it is not loaded.
---@param record table
---@param facadeName string a catalogue name
---@param level integer stack level the failure is reported at
---@return table implementation
local function requireKit(record, facadeName, level)
  local facade = record.facade
  local cached = rawget(facade, facadeName)
  if cached ~= nil then
    return cached
  end
  local generation = record.pins[facadeName] or CATALOGUE[facadeName]
  local implementation, reason = findPackage(Registry, packageIdOf(facadeName), generation)
  if implementation == nil then
    error(notLoadedMessage(record.addonName, facadeName, generation, reason), level)
  end
  rawset(facade, facadeName, implementation)
  return implementation
end

---Find SchemaKit for a helper called with a dot (`MC.Range`), which has no
---facade and therefore no pin; raise at `level` when it is not loaded.
---@param level integer stack level the failure is reported at
---@return table SchemaKit
local function requireSchemaKit(level)
  local generation = CATALOGUE.SchemaKit
  local implementation, reason = findPackage(Registry, "schemaKit", generation)
  if implementation == nil then
    error(notLoadedMessage(nil, "SchemaKit", generation, reason), level)
  end
  return implementation
end

---The addon's ModuleKit container, or raise at `level`.
---@param record table
---@param level integer stack level the failure is reported at
---@return table container
local function containerOf(record, level)
  local ModuleKit = requireKit(record, "ModuleKit", level + 1)
  return callAtCaller(level + 1, ModuleKit.ForAddon, ModuleKit, record.addonName)
end

---Refuse a name argument that is a secret or not a non-empty string.
---@param value any
---@param label string the argument, as the message names it
---@param level integer stack level the failure is reported at
local function requireName(value, label, level)
  if isSecret(value) then
    error(label .. " must not be a secret value", level)
  end
  if type(value) ~= "string" or value == "" then
    error(label .. " must be a non-empty string", level)
  end
end

-- Facade metatable -------------------------------------------------------------

---A facade read: a method, a part field, a Kit (resolved and cached), or an
---error that names the fix. Called through the metatable's `__index`, so
---level 3 is the line that read the field.
---@param facade table
---@param key any
---@return any
function dispatch.index(facade, key)
  if type(key) ~= "string" then
    error(
      "MC has no member of type " .. type(key) .. "; read a Kit by name, such as MC.TimerKit",
      3
    )
  end
  local method = methods[key]
  if method ~= nil then
    return method
  end
  local record = records[facade]
  local factory = fields[key]
  if factory ~= nil then
    local value = factory(record)
    rawset(facade, key, value)
    return value
  end
  local part = PART_OF[key]
  if part ~= nil then
    error(
      string.format(
        "%s is in AddonKit's %s part, which is not loaded: add addonKit\\parts\\AddonKit-%s.lua"
          .. " to embeds.xml after addonKit\\AddonKit.lua",
        memberText(key),
        part,
        part
      ),
      3
    )
  end
  if key == "Registry" then
    rawset(facade, key, Registry)
    return Registry
  end
  local facadeName = ALIASES[key] or key
  if CATALOGUE[facadeName] == nil then
    error(unknownMemberMessage(key), 3)
  end
  local implementation = requireKit(record, facadeName, 4)
  rawset(facade, key, implementation)
  return implementation
end

---A facade write, always refused: the facade is shared by every file of the
---addon and holds Kits and helpers only. Level 3 is the writing line.
---@param facade table
---@param key any
function dispatch.newindex(facade, key)
  local shown = type(key) == "string" and key or ("<" .. type(key) .. ">")
  error(
    "MC (the MoltenCodes facade of "
      .. records[facade].addonName
      .. ") holds Kits and helpers only; keep "
      .. shown
      .. " on your addon object",
    3
  )
end

---`MoltenCodes:For(addonName, ...)` and `AddonKit:For(addonName, ...)`:
---the addon's facade, created on the first call. Called through the stable
---entry function, so level 3 is the caller's line.
---@param receiver any
---@param addonName any
---@return MoltenCodesFacade
function dispatch.forEntry(receiver, addonName)
  if isSecret(receiver) or (receiver ~= namespace and receiver ~= AddonKit) then
    error("MoltenCodes:For is called with a colon: local MC = MoltenCodes:For(...)", 3)
  end
  if isSecret(addonName) then
    error("MoltenCodes:For addonName must not be a secret value", 3)
  end
  if type(addonName) ~= "string" or addonName == "" then
    error(
      "MoltenCodes:For addonName must be the addon's folder name, a non-empty string:"
        .. " local MC = MoltenCodes:For(...)",
      3
    )
  end
  local facade = facades[addonName]
  if facade ~= nil then
    return facade
  end
  local maxFacades = rawget(sharedLimits, "maxFacades")
  if rawget(state, "facadeCount") >= maxFacades then
    error(
      "MoltenCodes:For holds at most "
        .. maxFacades
        .. " addon facades; raise maxFacades with AddonKit:SetLimits",
      3
    )
  end
  facade = setmetatable({}, FACADE_METATABLE)
  rawset(facade, "addonName", addonName)
  records[facade] = { addonName = addonName, facade = facade, pins = {}, databases = {} }
  facades[addonName] = facade
  rawset(state, "facadeCount", rawget(state, "facadeCount") + 1)
  return facade
end

-- Facade methods ---------------------------------------------------------------

---Pin the API generation one Kit resolves at for this addon, before the first
---read of it. Every file of the addon shares the pin.
---@param self MoltenCodesFacade
---@param facadeName string a catalogue name, such as `"TimerKit"`
---@param generation integer
local function facadeUse(self, facadeName, generation)
  local record = requireRecord(self, "MC:Use", 3)
  requireName(facadeName, "MC:Use facadeName", 3)
  if CATALOGUE[facadeName] == nil then
    error("MC:Use facadeName: " .. unknownMemberMessage(facadeName), 2)
  end
  if isSecret(generation) then
    error("MC:Use generation must not be a secret value", 2)
  end
  if type(generation) ~= "number" or generation < 1 or generation % 1 ~= 0 then
    error("MC:Use generation must be a positive integer", 2)
  end
  local readNames = { facadeName }
  for alias, target in pairs(ALIASES) do
    if target == facadeName then
      readNames[#readNames + 1] = alias
    end
  end
  for index = 1, #readNames do
    local cached = rawget(self, readNames[index])
    if cached ~= nil and rawget(cached, "API") ~= generation then
      error(
        string.format(
          "MC:Use %s was already read at API %s; call MC:Use before the first read of MC.%s",
          facadeName,
          tostring(rawget(cached, "API")),
          readNames[index]
        ),
        2
      )
    end
  end
  record.pins[facadeName] = generation
end

---Refuse a definition argument that is a secret or neither a table nor `nil`.
---@param definition any
---@param label string
---@param level integer stack level the failure is reported at
local function checkDefinition(definition, label, level)
  if isSecret(definition) or (type(definition) ~= "nil" and type(definition) ~= "table") then
    error(label .. " definition must be a ModuleKit definition table or nil", level)
  end
end

---The addon object: the module `"Main"` of the addon's ModuleKit container.
---`OnInitialize` runs when the addon has loaded, `OnEnable` at login,
---`OnDisable` on `Disable()` and at logout.
---@param self MoltenCodesFacade
---@param definition table? a ModuleKit definition, passed to `CreateModule` as it is
---@return AddonKit.Addon
local function facadeNewAddon(self, definition)
  local record = requireRecord(self, "MC:NewAddon", 3)
  checkDefinition(definition, "MC:NewAddon", 3)
  local container = containerOf(record, 3)
  if container:HasModule(MAIN_MODULE) then
    error(
      "MC:NewAddon "
        .. record.addonName
        .. " already has its addon object; read it with MC:GetAddon(), or create a module with MC:NewModule(name)",
      2
    )
  end
  local main = callAtCaller(3, container.CreateModule, container, MAIN_MODULE, definition)
  -- The module default never applies to the addon object, as in AceAddon:
  -- an author who turned modules off first still gets an addon that enables.
  local wantsOff = type(definition) == "table" and rawget(definition, "enabledState") == false
  local getDefault = container.GetDefaultModuleState
  if not wantsOff and type(getDefault) == "function" and getDefault(container) == false then
    main:SetEnabledState(true)
  end
  return main
end

---A module of the addon. It depends on the addon object, so the addon
---initializes and enables first and disabling the addon disables it, as
---AceAddon-3.0 does with its modules.
---@param self MoltenCodesFacade
---@param name string
---@param definition table? a ModuleKit definition, passed to `CreateModule` with `"Main"` added to `dependsOn`
---@return AddonKit.Addon
local function facadeNewModule(self, name, definition)
  local record = requireRecord(self, "MC:NewModule", 3)
  requireName(name, "MC:NewModule name", 3)
  if name == MAIN_MODULE then
    error("MC:NewModule the name Main belongs to the addon object; create it with MC:NewAddon()", 2)
  end
  checkDefinition(definition, "MC:NewModule", 3)
  local container = containerOf(record, 3)
  if definition == nil then
    local module = callAtCaller(3, container.CreateModule, container, name)
    callAtCaller(3, module.DependsOn, module, MAIN_MODULE)
    return module
  end
  -- A definition table is atomic, so the dependency goes into a copy of it.
  local copy = {}
  for key, value in pairs(definition) do
    copy[key] = value
  end
  local dependsOn = copy.dependsOn
  if type(dependsOn) == "table" then
    local merged = { MAIN_MODULE }
    for index = 1, #dependsOn do
      if dependsOn[index] ~= MAIN_MODULE then
        merged[#merged + 1] = dependsOn[index]
      end
    end
    copy.dependsOn = merged
  elseif dependsOn == nil then
    copy.dependsOn = { MAIN_MODULE }
  end
  return callAtCaller(3, container.CreateModule, container, name, copy)
end

---The addon object, from any file of the addon.
---@param self MoltenCodesFacade
---@return AddonKit.Addon
local function facadeGetAddon(self)
  local record = requireRecord(self, "MC:GetAddon", 3)
  local module = containerOf(record, 3):GetModule(MAIN_MODULE)
  if module == nil then
    error(
      "MC:GetAddon "
        .. record.addonName
        .. " has no addon object yet; create it with MC:NewAddon() in the file the .toc loads first",
      2
    )
  end
  return module
end

---A module of the addon, from any file of the addon.
---@param self MoltenCodesFacade
---@param name string
---@return AddonKit.Addon
local function facadeGetModule(self, name)
  local record = requireRecord(self, "MC:GetModule", 3)
  requireName(name, "MC:GetModule name", 3)
  local module = containerOf(record, 3):GetModule(name)
  if module == nil then
    error(
      string.format(
        'MC:GetModule %s has no module named %s; create it with MC:NewModule("%s")',
        record.addonName,
        name,
        name
      ),
      2
    )
  end
  return module
end

---The addon's ModuleKit container, refusing a ModuleKit revision without
---the module defaults with the fix.
---@param self MoltenCodesFacade
---@param label string the method, `MC:SetDefaultModuleState`
---@param methodName string the container method it forwards to
---@return table container
local function containerWithDefaults(self, label, methodName)
  local record = requireRecord(self, label, 4)
  local container = containerOf(record, 4)
  if type(container[methodName]) ~= "function" then
    error(
      label
        .. " needs ModuleKit revision "
        .. MODULE_DEFAULTS_REVISION
        .. " or later; update the copy of moduleKit your addon embeds",
      3
    )
  end
  return container
end

---The starting intent of the addon's modules created from now on; the addon
---object itself is never affected. Forwards to ModuleKit.
---@param self MoltenCodesFacade
---@param enabled boolean
---@return boolean previous
local function facadeSetDefaultModuleState(self, enabled)
  local container = containerWithDefaults(self, "MC:SetDefaultModuleState", "SetDefaultModuleState")
  return callAtCaller(3, container.SetDefaultModuleState, container, enabled)
end

---The prototype of the addon's modules created from now on, or `nil`.
---Forwards to ModuleKit.
---@param self MoltenCodesFacade
---@param prototype table|nil
---@return table|nil previous
local function facadeSetDefaultModulePrototype(self, prototype)
  local container =
    containerWithDefaults(self, "MC:SetDefaultModulePrototype", "SetDefaultModulePrototype")
  return callAtCaller(3, container.SetDefaultModulePrototype, container, prototype)
end

---Call `callback(module)`, or a receiver's method, for every module of the
---addon created from now on. Forwards to ModuleKit.
---@param self MoltenCodesFacade
---@param callback function|table
---@param methodName string?
---@return table|nil connection
---@return string|nil reason
local function facadeOnModuleCreated(self, callback, methodName)
  local container = containerWithDefaults(self, "MC:OnModuleCreated", "OnModuleCreated")
  return callAtCaller(3, container.OnModuleCreated, container, callback, methodName)
end

-- Package public API ---------------------------------------------------------

-- shared:begin validateFacade 1 __FACADE__=AddonKit
-- Copied from tooling/shared/lua/validateFacade.lua by python3 -m tooling.shared.sync; edit that file, not this copy.
---Raise at `level` unless `receiver` is the AddonKit facade.
---@param receiver any the table the method was called on
---@param label string qualified method name, used in the argument error
---@param level integer stack level the failure is reported at
local function validateFacade(receiver, label, level)
  if type(receiver) ~= "table" or receiver ~= AddonKit then
    local hint = "; use " .. label .. "(...)"
    error(label .. " must be called on the AddonKit facade" .. hint, level)
  end
end
-- shared:end validateFacade

---A fresh copy of the catalogue: facade name to package ID and generation.
---@param self AddonKit
---@return table<string, AddonKit.CatalogueEntry>
local function packageGetCatalogue(self)
  validateFacade(self, "AddonKit:GetCatalogue", 3)
  local copy = {}
  for facadeName, generation in pairs(CATALOGUE) do
    copy[facadeName] = { packageId = packageIdOf(facadeName), api = generation }
  end
  return copy
end

---Change `maxFacades`. Lowering it keeps every facade.
---@param self AddonKit
---@param limits AddonKit.Limits
local function packageSetLimits(self, limits)
  validateFacade(self, "AddonKit:SetLimits", 3)
  if isSecret(limits) or type(limits) ~= "table" then
    error("AddonKit:SetLimits limits must be a table", 2)
  end
  for key, value in pairs(limits) do
    if isSecret(key) or key ~= "maxFacades" then
      error("AddonKit:SetLimits limits holds an unknown field; it accepts maxFacades", 2)
    end
    if isSecret(value) then
      error("AddonKit:SetLimits limits.maxFacades must not be a secret value", 2)
    end
    if not isFacadeLimit(value) then
      error(
        "AddonKit:SetLimits limits.maxFacades must be an integer from 1 to " .. FACADES_CEILING,
        2
      )
    end
  end
  if type(limits.maxFacades) ~= "nil" then
    rawset(sharedLimits, "maxFacades", limits.maxFacades)
  end
end

---Return a fresh copy of the shared limits. Allocates one table per call.
---@param self AddonKit
---@return AddonKit.Limits
local function packageGetLimits(self)
  validateFacade(self, "AddonKit:GetLimits", 3)
  return { maxFacades = rawget(sharedLimits, "maxFacades") }
end

-- Commit ---------------------------------------------------------------------

-- Helpers the parts call through `_state.helpers`. A part keeps no copy, so an
-- upgraded core's helpers serve parts loaded before it.
rawset(helpers, "isSecret", isSecret)
rawset(helpers, "reportError", reportError)
rawset(helpers, "callAtCaller", callAtCaller)
rawset(helpers, "withoutPosition", withoutAddonKitPosition)
rawset(helpers, "requireRecord", requireRecord)
rawset(helpers, "requireKit", requireKit)
rawset(helpers, "requireSchemaKit", requireSchemaKit)
rawset(helpers, "requireName", requireName)
rawset(helpers, "isFacade", function(value)
  return not isSecret(value) and type(value) == "table" and records[value] ~= nil
end)

rawset(methods, "Use", facadeUse)
rawset(methods, "NewAddon", facadeNewAddon)
rawset(methods, "NewModule", facadeNewModule)
rawset(methods, "GetAddon", facadeGetAddon)
rawset(methods, "GetModule", facadeGetModule)
rawset(methods, "SetDefaultModuleState", facadeSetDefaultModuleState)
rawset(methods, "SetDefaultModulePrototype", facadeSetDefaultModulePrototype)
rawset(methods, "OnModuleCreated", facadeOnModuleCreated)

rawset(AddonKit, "API", API_GENERATION)
rawset(AddonKit, "REVISION", IMPLEMENTATION_REVISION)
rawset(AddonKit, "MAX_FACADES", MAX_FACADES)
rawset(AddonKit, "FACADES_CEILING", FACADES_CEILING)
rawset(AddonKit, "For", namespaceEntry)
rawset(AddonKit, "GetCatalogue", packageGetCatalogue)
rawset(AddonKit, "SetLimits", packageSetLimits)
rawset(AddonKit, "GetLimits", packageGetLimits)

-- Claim `MoltenCodes.For` when it is free or already ours. A foreign value is
-- left alone and reported once; `AddonKit:For` keeps working.
local currentEntry = rawget(namespace, NAMESPACE_ENTRY_KEY)
if currentEntry == nil or currentEntry == namespaceEntry then
  rawset(namespace, NAMESPACE_ENTRY_KEY, namespaceEntry)
elseif not rawget(state, "reportedForeignEntry") then
  rawset(state, "reportedForeignEntry", true)
  reportError(
    "MoltenCodes AddonKit: MoltenCodes.For is owned by another value, so it was left alone;"
      .. ' use MoltenCodes.Registries[2]:Get("addonKit", 1):For(...)'
  )
end

rawset(state, "runtimeRevision", IMPLEMENTATION_REVISION)

if not validatePublicSurface(AddonKit) or not validateCurrentState(AddonKit) then
  error("MoltenCodes AddonKit package state is corrupted or incomplete", 2)
end
for index = 1, #CORE_METHODS do
  if type(rawget(methods, CORE_METHODS[index])) ~= "function" then
    error("MoltenCodes AddonKit package state is corrupted or incomplete", 2)
  end
end

return AddonKit
