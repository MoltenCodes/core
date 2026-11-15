-- MoltenCodes ClientKit
--
-- One place that answers "which client is this and what can it do": the client
-- flavour, the build and interface number, a fixed table of capability flags,
-- probes for secret values, restricted frames and event names, and shims for
-- the few host calls whose name or shape differs between flavours.
--
-- Everything is read from the host once, at bootstrap, into shared package
-- state. After that every probe is a table read and every shim adds one call.
-- An in-place upgrade re-reads the host into the same tables. The one thing
-- read later is an addon's `.toc` manifest, read once per addon on the first
-- `GetManifest` call and kept for the session.
--
-- ClientKit also carries the framework's deprecation warnings, because
-- Registry's line budget leaves no room for them: a Kit declares what it
-- deprecates with `Deprecate` and calls the reporter's `Warn` on the
-- deprecated path, and the consuming addon is told once per call site (or
-- once per addon) through the host error handler. Kits reach this through
-- `Registry:Find`, so it adds no load-order edge. See docs/API.md,
-- "Deprecations".
--
-- Capabilities are probed, never inferred from the flavour. A flag is `true`
-- only when the host actually exposes the facility, so a client ClientKit has
-- never heard of still answers correctly, and an absent `WOW_PROJECT_ID` can
-- never turn every flag on. See docs/API.md.
--
-- Contents
-- --------
--   Constants ............. identity, flavour map, capability names, manifest fields
--   Public types .......... LuaCATS declarations for the published surface
--   Dependencies .......... Registry
--   Bootstrap ............. surface/state validation, registration, state
--   Host probing .......... flavour, build, locale, capabilities, bound host functions
--   Validation helpers .... argument checks that report at the caller
--   Identity .............. GetFlavor, GetBuild, GetInterfaceNumber, IsAtLeast
--   Capabilities .......... Has
--   Taint probes .......... IsSecret, CanAccessFrame, IsEventValid
--   Shims ................. GetAddOnMetadata, IsAddOnLoaded, GetSpellInfo, GetItemInfo
--   Manifests ............. GetManifest and the read-only manifest snapshot
--   Deprecations .......... Deprecate, reporters, reports, the mode, limits
--   Commit ................ facade assignment and self-check

-- Constants ------------------------------------------------------------------

local PACKAGE_NAME = "clientKit"
local API_GENERATION = 1
local IMPLEMENTATION_REVISION = 8
local REQUIRED_REGISTRY_API = 2
local STATE_SCHEMA = 1

-- `WOW_PROJECT_ID` values mapped to flavours. The numbers are compared as
-- literals rather than against the client's `WOW_PROJECT_*` constants, because
-- a constant a client predates is simply absent and `nil == nil` would match.
--
--   1   WOW_PROJECT_MAINLINE                  Retail
--   2   WOW_PROJECT_CLASSIC                   Classic Era, Hardcore, Season of Discovery
--   5   WOW_PROJECT_BURNING_CRUSADE_CLASSIC   Burning Crusade Classic (Anniversary)
--   19  WOW_PROJECT_MISTS_CLASSIC             Mists of Pandaria Classic
--
-- Any other number, and a missing or non-number project id, yields
-- `FALLBACK_FLAVOR`: the flavour that assumes the least about the client.
local FLAVOR_BY_PROJECT_ID = {
  [1] = "mainline",
  [2] = "classic",
  [5] = "tbc",
  [19] = "mists",
}
local FALLBACK_FLAVOR = "classic"

-- The one interface number a host without `GetBuildInfo` reports. Zero keeps
-- `IsAtLeast` false for every real interface number, which is the conservative
-- answer when the build is unknown.
local UNKNOWN_INTERFACE_NUMBER = 0

-- The closed set of capability names `Has` accepts. The order is the order
-- docs/API.md lists them in; the probe for each lives in `probeCapabilities`.
local CAPABILITY_NAMES = {
  "C_AddOns",
  "C_Spell",
  "C_Item",
  "C_Timer",
  "spellbookApi",
  "eventValidity",
  "secretValues",
  "forbiddenFrames",
  "restrictedFrames",
  "secureCall",
  "profilingClock",
  "preciseClock",
}

-- Error-message stand-in for a value that `issecretvalue` reports secret. A
-- message built from a secret is itself secret, so it is never formatted in.
local SECRET_PLACEHOLDER = "<secret value>"

-- The `.toc` fields a manifest snapshot reads at creation, as `{ key, field }`
-- pairs: `key` is the snapshot field, `field` the `## Field` name asked of the
-- host. `Title` and `Notes` are absent here because they take the locale
-- fallback in `readLocalisedField`; the list fields are absent because
-- `readListField` reads them. Every other `.toc` field, `X-` fields included,
-- is read on demand through `manifest:Get`.
local MANIFEST_SCALAR_FIELDS = {
  { "version", "Version" },
  { "author", "Author" },
  { "interface", "Interface" },
  { "iconTexture", "IconTexture" },
  { "iconAtlas", "IconAtlas" },
  { "category", "Category" },
  { "group", "Group" },
  { "loadOnDemand", "LoadOnDemand" },
  { "defaultState", "DefaultState" },
  { "addonCompartmentFunc", "AddonCompartmentFunc" },
}

-- The `.toc` fields that hold comma-separated lists, as `{ key, field,
-- aliasField, hostListName }`. `aliasField` is the second spelling a `.toc`
-- may use for the same list (`## Dependencies` and `## RequiredDeps` are one
-- field); `hostListName` names the entry in the bound host table that returns
-- the list as multiple values when the metadata call does not export it.
local MANIFEST_LIST_FIELDS = {
  { "dependencies", "Dependencies", "RequiredDeps", "getAddOnDependencies" },
  { "optionalDependencies", "OptionalDeps", false, "getAddOnOptionalDependencies" },
  { "savedVariables", "SavedVariables", false, false },
  { "savedVariablesPerCharacter", "SavedVariablesPerCharacter", false, false },
}

-- The `.toc` fields that may carry a locale suffix (`## Notes-deDE`). The
-- suffixed form is tried before the plain one.
local MANIFEST_LOCALISED_FIELDS = {
  { "title", "Title" },
  { "notes", "Notes" },
}

-- The deprecation modes `SetDeprecationMode` accepts, and the default one.
-- `"report"` records a report and hands it to the host error handler,
-- `"silent"` only records it, `"raise"` raises it at the consumer's line on
-- every call and records nothing (a developer switch).
local DEPRECATION_MODES = { report = true, silent = true, raise = true }
local DEFAULT_DEPRECATION_MODE = "report"

-- The deprecation limits: the default of each and the ceiling `SetLimits`
-- refuses to go past. Neither takes an unbounded value: deprecations are
-- declared by Kits and reports are bounded by the session, so a ceiling
-- covers every real need and keeps one caller from growing the state
-- without bound.
local LIMIT_DEFAULTS = { maxDeprecations = 128, maxReports = 256 }
local LIMIT_CEILINGS = { maxDeprecations = 1024, maxReports = 4096 }
local LIMIT_NAMES = { "maxDeprecations", "maxReports" }

-- The `level` a reporter's `Warn` uses when none is given: as for `error`,
-- level 2 is the caller of the function that called `Warn`, which is the
-- consumer that called the Kit's deprecated method.
local DEFAULT_WARN_LEVEL = 2

-- Who a report names when neither the Kit nor the call site names an addon.
local UNKNOWN_ADDON = "unknown"

-- Shape of a locale code as `GetLocale` reports it: `enUS`, `deDE`, `zhCN`.
-- Anything else is treated as no locale, so no suffixed field is ever asked
-- for with a name the host cannot have.
local LOCALE_CODE_PATTERN = "^%l%l%u%u$"

-- One item of a comma-separated `.toc` list, with the surrounding whitespace
-- captured away: `## Dependencies: Ace3, LibStub` yields `Ace3` and `LibStub`.
local LIST_ITEM_PATTERN = "^%s*(.-)%s*$"

-- Public types --------------------------------------------------------------
--
-- ClientKit publishes its methods by writing them onto a Registry-owned facade
-- table, so the editor-facing contract is declared here as LuaCATS classes
-- rather than inferred from those assignments.

---The client family, derived from `WOW_PROJECT_ID`.
---@alias ClientKit.Flavor "mainline"|"mists"|"tbc"|"classic"

---A name from the fixed capability table in docs/API.md.
---@alias ClientKit.Capability "C_AddOns"|"C_Spell"|"C_Item"|"C_Timer"|"spellbookApi"|"eventValidity"|"secretValues"|"forbiddenFrames"|"restrictedFrames"|"secureCall"|"profilingClock"|"preciseClock"

---The one shape `ClientKit:GetSpellInfo` returns on every flavour.
---
---On a client with `C_Spell.GetSpellInfo` this is the host's own table, which
---may carry further fields (for example `originalIconID`); only the six below
---are the contract.
---@class ClientKit.SpellInfo
---@field name string Localised spell name.
---@field iconID integer|string File ID (or texture path on old clients) of the spell icon.
---@field castTime integer Cast time in milliseconds; `0` for instant spells.
---@field minRange number Minimum range in yards.
---@field maxRange number Maximum range in yards.
---@field spellID integer The resolved spell ID.

---Why `ClientKit:GetManifest` returned no manifest.
---
---`"unknown"`: the host lists no addon by that name. `"unavailable"`: the host
---has neither `C_AddOns.GetAddOnMetadata` nor `GetAddOnMetadata`, so no `.toc`
---can be read at all.
---@alias ClientKit.ManifestFailure "unknown"|"unavailable"

---A read-only snapshot of one addon's `.toc` metadata.
---
---Every field below is read from the host once, when the snapshot is created;
---the scalar fields hold the `.toc` string unchanged, or `nil` when the field is
---absent, empty or not exported by the client. The four list fields are always
---arrays (possibly empty) split on commas. Writing any field raises at the
---caller's line. The arrays are shared by every caller of the same manifest and
---are to be treated as read-only too; Lua 5.1 cannot refuse writes to them
---without breaking `#` and `ipairs`.
---@class ClientKit.Manifest
---@field name string The addon folder name the manifest was asked for.
---@field title string? `## Title-<locale>`, else `## Title`.
---@field notes string? `## Notes-<locale>`, else `## Notes`.
---@field version string? `## Version`.
---@field author string? `## Author`.
---@field interface string? `## Interface`, as written.
---@field iconTexture string? `## IconTexture`.
---@field iconAtlas string? `## IconAtlas`.
---@field category string? `## Category`.
---@field group string? `## Group`.
---@field loadOnDemand string? `## LoadOnDemand`, as written (`"1"` when set).
---@field defaultState string? `## DefaultState`.
---@field addonCompartmentFunc string? `## AddonCompartmentFunc`.
---@field dependencies string[] `## Dependencies` (or `## RequiredDeps`) split into names.
---@field optionalDependencies string[] `## OptionalDeps` split into names.
---@field savedVariables string[] `## SavedVariables` split into names.
---@field savedVariablesPerCharacter string[] `## SavedVariablesPerCharacter` split into names.
---@field Get fun(self: ClientKit.Manifest, field: string): string? Any raw `## Field`, `X-` fields included; read once and remembered.

---What `ClientKit:Deprecate` is told about one deprecated thing.
---@class ClientKit.DeprecationSpec
---@field name string What is deprecated, for example `"TimerKit:After"`, `"EventKit API 1"` or `"SettingsKit:Open option legacy"`.
---@field removal string When, or in what, it goes away, for example `"TimerKit API 2"`.
---@field replacement string? What to use instead, for example `"TimerKit:Delay"`.

---The handle a Kit keeps for one deprecation and calls on the deprecated path.
---@class ClientKit.DeprecationReporter
---@field name string The deprecated thing's name, as declared.
---@field Warn fun(self: ClientKit.DeprecationReporter, level: integer?, addonName: string?) Tell the consumer once per call site, or once per addon when `addonName` is given.

---One row of `ClientKit:GetDeprecationReports`.
---@class ClientKit.DeprecationReport
---@field name string What is deprecated.
---@field replacement string? What to use instead.
---@field removal string When, or in what, it goes away.
---@field addon string The consuming addon, or `"unknown"`.
---@field site string? The call site, for example `"Interface/AddOns/MyAddon/Core.lua:42"`, when the client could name it.

---What `ClientKit:SetDeprecationMode` accepts.
---@alias ClientKit.DeprecationMode "report"|"silent"|"raise"

---The deprecation limits `ClientKit:SetLimits` changes and `GetLimits` reports.
---@class ClientKit.Limits
---@field maxDeprecations integer? Deprecations declared under distinct names; 128 by default, at most 1024.
---@field maxReports integer? Reports recorded for the session; 256 by default, at most 4096.

---The ClientKit package facade published through Registry.
---@class ClientKit
---@field API integer Public API generation.
---@field REVISION integer Compatible implementation revision.
---@field GetFlavor fun(self: ClientKit): ClientKit.Flavor
---@field GetBuild fun(self: ClientKit): version: string?, build: integer?, buildDate: string?
---@field GetInterfaceNumber fun(self: ClientKit): integer
---@field IsAtLeast fun(self: ClientKit, interfaceNumber: number): boolean
---@field Has fun(self: ClientKit, capability: ClientKit.Capability): boolean
---@field IsSecret fun(self: ClientKit, value: any): boolean
---@field CanAccessFrame fun(self: ClientKit, frame: table): boolean
---@field IsEventValid fun(self: ClientKit, eventName: string): boolean?
---@field GetAddOnMetadata fun(self: ClientKit, addon: string|integer, field: string): string?
---@field IsAddOnLoaded fun(self: ClientKit, addon: string|integer): loaded: boolean, finished: boolean
---@field GetSpellInfo fun(self: ClientKit, spell: integer|string): ClientKit.SpellInfo?
---@field GetItemInfo fun(self: ClientKit, item: integer|string): ...
---@field GetManifest fun(self: ClientKit, addonName: string): manifest: ClientKit.Manifest?, reason: ClientKit.ManifestFailure?
---@field Deprecate fun(self: ClientKit, spec: ClientKit.DeprecationSpec): ClientKit.DeprecationReporter
---@field GetDeprecationReports fun(self: ClientKit): ClientKit.DeprecationReport[]
---@field SetDeprecationMode fun(self: ClientKit, mode: ClientKit.DeprecationMode)
---@field GetDeprecationMode fun(self: ClientKit): ClientKit.DeprecationMode
---@field SetLimits fun(self: ClientKit, limits: ClientKit.Limits)
---@field GetLimits fun(self: ClientKit): ClientKit.Limits

-- Dependencies --------------------------------------------------------------

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
  error("MoltenCodes ClientKit requires Registry API 2 to be loaded first", 2)
end

local bootstrapPackage = rawget(Registry, "Bootstrap")
if type(bootstrapPackage) ~= "function" then
  error("MoltenCodes ClientKit requires a valid Registry API 2 facade", 2)
end

-- Bootstrap -----------------------------------------------------------------

-- Every method name the facade publishes, used by the surface check.
local PUBLIC_METHODS = {
  "GetFlavor",
  "GetBuild",
  "GetInterfaceNumber",
  "IsAtLeast",
  "Has",
  "IsSecret",
  "CanAccessFrame",
  "IsEventValid",
  "GetAddOnMetadata",
  "IsAddOnLoaded",
  "GetSpellInfo",
  "GetItemInfo",
  "GetManifest",
  "Deprecate",
  "GetDeprecationReports",
  "SetDeprecationMode",
  "GetDeprecationMode",
  "SetLimits",
  "GetLimits",
}

---Whether `implementation` exposes the complete ClientKit API 1 surface.
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

  for index = 1, #PUBLIC_METHODS do
    if type(rawget(implementation, PUBLIC_METHODS[index])) ~= "function" then
      return false
    end
  end
  return true
end

---Whether `deprecation`, the `state.deprecation` table revision 6 added, has
---the shape this revision creates it with (see `newDeprecationState`).
---@param deprecation any
---@return boolean
local function validateDeprecationState(deprecation)
  if
    type(deprecation) ~= "table"
    or DEPRECATION_MODES[rawget(deprecation, "mode")] ~= true
    or type(rawget(deprecation, "reporters")) ~= "table"
    or type(rawget(deprecation, "count")) ~= "number"
    or type(rawget(deprecation, "reports")) ~= "table"
    or type(rawget(deprecation, "limits")) ~= "table"
    or type(rawget(deprecation, "prototype")) ~= "table"
    or type(rawget(deprecation, "metatable")) ~= "table"
    or type(rawget(deprecation, "capReported")) ~= "boolean"
  then
    return false
  end
  local inert = rawget(deprecation, "inert")
  if inert ~= false and type(inert) ~= "table" then
    return false
  end
  local limits = rawget(deprecation, "limits")
  for index = 1, #LIMIT_NAMES do
    if type(rawget(limits, LIMIT_NAMES[index])) ~= "number" then
      return false
    end
  end
  return true
end

---Whether `currentState` has the shape this revision's schema requires.
---
---Revision 2 added `locale`, `manifests` and `manifestPrototype` and revision
---6 added `deprecation`, each without a schema change, so a copy carrying
---this revision has all four.
---@param currentState any
---@return boolean
local function validateState(currentState)
  if
    type(currentState) ~= "table"
    or rawget(currentState, "schema") ~= STATE_SCHEMA
    or type(rawget(currentState, "flavor")) ~= "string"
    or type(rawget(currentState, "interfaceNumber")) ~= "number"
    or type(rawget(currentState, "capabilities")) ~= "table"
    or type(rawget(currentState, "host")) ~= "table"
    or type(rawget(currentState, "manifests")) ~= "table"
    or type(rawget(currentState, "manifestPrototype")) ~= "table"
    or not validateDeprecationState(rawget(currentState, "deprecation"))
  then
    return false
  end

  local locale = rawget(currentState, "locale")
  if locale ~= false and type(locale) ~= "string" then
    return false
  end

  local capabilities = rawget(currentState, "capabilities")
  for index = 1, #CAPABILITY_NAMES do
    if type(rawget(capabilities, CAPABILITY_NAMES[index])) ~= "boolean" then
      return false
    end
  end
  return true
end

---Whether a copy carrying this revision already committed its state.
---@param implementation table
---@return boolean
local function validateCurrentState(implementation)
  return validateState(rawget(implementation, "_state"))
end

-- `Registry:Bootstrap` owns the reconciliation every embedded package repeats:
-- look the package up, refuse to reinterpret state owned by a newer revision,
-- and register this one. What stays here is what only ClientKit can answer.
local ClientKit, previousRevision, selected = bootstrapPackage(Registry, {
  package = PACKAGE_NAME,
  api = API_GENERATION,
  revision = IMPLEMENTATION_REVISION,
  label = "MoltenCodes ClientKit",
  validatePublicSurface = validatePublicSurface,
  validateState = validateCurrentState,
})

if type(ClientKit) == "nil" then
  -- Equal or newer compatible revision already owns the shared package table.
  return selected
end

local state = rawget(ClientKit, "_state")

---The deprecation state as revision 6 creates it, on a first load and on an
---upgrade from an older revision alike. Every field has its final type, so
---nothing is added later; until a Kit calls `Deprecate` these few small
---tables are all deprecation warnings cost.
---@return table
local function newDeprecationState()
  local prototype = {}
  return {
    -- The session's mode, one of `DEPRECATION_MODES`.
    mode = DEFAULT_DEPRECATION_MODE,
    -- Deprecated name to its reporter. Bounded by `limits.maxDeprecations`.
    reporters = {},
    -- How many names `reporters` holds, kept so the limit check is one
    -- comparison rather than a walk.
    count = 0,
    -- The recorded reports in report order. Bounded by `limits.maxReports`.
    reports = {},
    limits = {
      maxDeprecations = LIMIT_DEFAULTS.maxDeprecations,
      maxReports = LIMIT_DEFAULTS.maxReports,
    },
    -- `Warn` lives here, and every reporter's metatable points here, so a
    -- newer revision rewrites `Warn` in place for reporters made before it.
    prototype = prototype,
    metatable = { __index = prototype },
    -- The one reporter handed out past `maxDeprecations`, made when first
    -- needed; it reports nothing.
    inert = false,
    -- Whether going past `maxDeprecations` was reported, so it is reported
    -- once a session.
    capReported = false,
  }
end

if type(previousRevision) == "nil" then
  if state ~= nil then
    error("MoltenCodes ClientKit package state is corrupted or incomplete", 2)
  end

  -- Every field is created here with its final type, so re-probing the host
  -- on an upgrade only overwrites values and never grows a table.
  state = {
    schema = STATE_SCHEMA,
    flavor = FALLBACK_FLAVOR,
    interfaceNumber = UNKNOWN_INTERFACE_NUMBER,
    version = false,
    build = false,
    buildDate = false,
    -- The client locale code (`"deDE"`), or `false` when the host reports
    -- none; it chooses the suffixed `.toc` field a manifest tries first.
    locale = false,
    capabilities = {},
    -- The host functions the probes and shims call, or `false` when the
    -- host does not provide them.
    host = {},
    -- Lower-cased addon folder name to its manifest record (see
    -- "Manifests"). Only addons the host lists are ever stored, so the
    -- table is bounded by the addons installed in the client, a set no
    -- caller can grow; the host matches names case-insensitively, hence
    -- the lower-cased key.
    manifests = {},
    -- The metatable target every manifest snapshot resolves `Get` through.
    -- Kept in state so a newer revision rewrites the method in place and
    -- a snapshot cached before the upgrade answers with the new code.
    manifestPrototype = {},
    -- Deprecation warnings (see "Deprecations").
    deprecation = newDeprecationState(),
  }
  rawset(ClientKit, "_state", state)
elseif
  type(state) ~= "table"
  or type(rawget(state, "capabilities")) ~= "table"
  or type(rawget(state, "host")) ~= "table"
then
  -- Revision 1 created both tables, so an inherited state without either was
  -- modified from outside and is refused rather than silently rebuilt.
  error("MoltenCodes ClientKit package state is corrupted or incomplete", 2)
else
  -- Upgrade over revision 1, which had no manifests: add the two tables
  -- revision 2 introduced. Both are created empty exactly once; a later
  -- revision inherits them with whatever manifests were read meanwhile. A
  -- value that is present but not a table was written from outside, since
  -- no revision creates either field as anything else, and is refused like
  -- a missing capability or host table rather than indexed later.
  for _, tableName in ipairs({ "manifests", "manifestPrototype" }) do
    local inherited = rawget(state, tableName)
    if inherited == nil then
      rawset(state, tableName, {})
    elseif type(inherited) ~= "table" then
      error("MoltenCodes ClientKit package state is corrupted or incomplete", 2)
    end
  end

  -- Upgrade over revision 5 or older, which had no deprecation warnings:
  -- create their state once. An inherited one must have the shape revision
  -- 6 gave it; anything else was written from outside and is refused.
  local inheritedDeprecation = rawget(state, "deprecation")
  if inheritedDeprecation == nil then
    rawset(state, "deprecation", newDeprecationState())
  elseif not validateDeprecationState(inheritedDeprecation) then
    error("MoltenCodes ClientKit package state is corrupted or incomplete", 2)
  end
end

local capabilities = rawget(state, "capabilities")
local host = rawget(state, "host")
local manifests = rawget(state, "manifests")
local manifestPrototype = rawget(state, "manifestPrototype")
local deprecation = rawget(state, "deprecation")

-- Host probing ---------------------------------------------------------------
--
-- Every read of a client global goes through `rawget(_G, name)`: the client API
-- only exists in the global table, and a raw read never triggers a metatable
-- another addon may have installed on `_G`.

---Read one client global.
---@param name string
---@return any
local function readGlobal(name)
  -- The World of Warcraft client API is reachable only through the global table.
  -- selene: allow(global_usage)
  return rawget(_G, name)
end

---Return the function `namespaceName.functionName`, or `false`.
---@param namespaceName string client namespace table, for example `"C_Spell"`
---@param functionName string
---@return function|false
local function readNamespaceFunction(namespaceName, functionName)
  local namespaceTable = readGlobal(namespaceName)
  if type(namespaceTable) ~= "table" then
    return false
  end
  local value = rawget(namespaceTable, functionName)
  if type(value) ~= "function" then
    return false
  end
  return value
end

---Return the global function `name`, or `false`.
---@param name string
---@return function|false
local function readGlobalFunction(name)
  local value = readGlobal(name)
  if type(value) ~= "function" then
    return false
  end
  return value
end

---Whether the client namespace table `name` exists.
---@param name string
---@return boolean
local function hasNamespace(name)
  return type(readGlobal(name)) == "table"
end

---Whether `UIParent` answers the frame method `methodName`.
---
---Frame methods cannot be probed without a frame, and creating one at load
---would leave a permanent frame behind, so the probe asks the one frame every
---client creates before any addon loads. The lookup goes through the frame's
---metatable, where the client keeps its methods; it never calls the method.
---@param methodName string
---@return boolean
local function uiParentHasMethod(methodName)
  local uiParent = readGlobal("UIParent")
  if type(uiParent) ~= "table" then
    return false
  end
  return type(uiParent[methodName]) == "function"
end

---Derive the flavour from `WOW_PROJECT_ID`.
---
---The project id must be a number before anything is compared, which is what
---keeps a missing id from matching every flavour at once.
---@return ClientKit.Flavor
local function probeFlavor()
  local projectId = readGlobal("WOW_PROJECT_ID")
  if type(projectId) ~= "number" then
    return FALLBACK_FLAVOR
  end
  return FLAVOR_BY_PROJECT_ID[projectId] or FALLBACK_FLAVOR
end

---Read `GetBuildInfo()` into `state`.
local function probeBuild()
  local getBuildInfo = readGlobalFunction("GetBuildInfo")
  local version, build, buildDate, interfaceNumber
  if getBuildInfo then
    version, build, buildDate, interfaceNumber = getBuildInfo()
  end

  -- The client returns the build number as a string; it is published as an
  -- integer so callers can compare it.
  local buildNumber = tonumber(build)

  rawset(state, "version", type(version) == "string" and version or false)
  rawset(state, "build", buildNumber or false)
  rawset(state, "buildDate", type(buildDate) == "string" and buildDate or false)
  rawset(
    state,
    "interfaceNumber",
    type(interfaceNumber) == "number" and interfaceNumber or UNKNOWN_INTERFACE_NUMBER
  )
end

---Fill the capability table. Each flag is `true` only when the host exposes
---the facility; nothing here reads the flavour.
local function probeCapabilities()
  rawset(capabilities, "C_AddOns", hasNamespace("C_AddOns"))
  rawset(capabilities, "C_Spell", hasNamespace("C_Spell"))
  rawset(capabilities, "C_Item", hasNamespace("C_Item"))
  rawset(capabilities, "C_Timer", hasNamespace("C_Timer"))
  rawset(
    capabilities,
    "spellbookApi",
    readNamespaceFunction("C_SpellBook", "GetSpellBookItemInfo") ~= false
  )
  rawset(capabilities, "eventValidity", rawget(host, "isEventValid") ~= false)
  rawset(capabilities, "secretValues", rawget(host, "isSecretValue") ~= false)
  rawset(capabilities, "forbiddenFrames", uiParentHasMethod("IsForbidden"))
  rawset(capabilities, "restrictedFrames", uiParentHasMethod("CanBeAccessedInContext"))
  rawset(capabilities, "secureCall", readGlobalFunction("securecallfunction") ~= false)
  rawset(capabilities, "profilingClock", readGlobalFunction("debugprofilestop") ~= false)
  rawset(capabilities, "preciseClock", readGlobalFunction("GetTimePreciseSec") ~= false)
end

---Read `GetLocale()` into `state.locale`.
---
---The locale is fixed for the session like the flavour and the build, so it
---is read here rather than on every manifest. A host without `GetLocale`, or
---one answering something that is not a locale code, leaves `false`: the
---manifest then reads the plain `## Title` and `## Notes` only.
local function probeLocale()
  local getLocale = rawget(host, "getLocale")
  local locale = getLocale and getLocale() or nil
  if type(locale) ~= "string" or type(locale:match(LOCALE_CODE_PATTERN)) == "nil" then
    rawset(state, "locale", false)
  else
    rawset(state, "locale", locale)
  end
end

---Return `C_AddOns.functionName`, else the global `legacyName`, else `false`.
---@param functionName string the `C_AddOns` function name
---@param legacyName string the legacy global of the same shape
---@return function|false
local function readAddOnFunction(functionName, legacyName)
  return readNamespaceFunction("C_AddOns", functionName) or readGlobalFunction(legacyName)
end

---Bind the host functions the probes and shims call. The modern `C_*` form is
---preferred; the legacy global is kept only as the fallback for a client that
---lacks it.
---
---Revision 2 added `getLocale`, `getAddOnInfo`, `getAddOnDependencies` and
---`getAddOnOptionalDependencies`, so an upgrade over revision 1 grows the host
---table by those four entries once; every later bootstrap only overwrites.
local function bindHostFunctions()
  rawset(host, "isSecretValue", readGlobalFunction("issecretvalue"))
  rawset(host, "isEventValid", readNamespaceFunction("C_EventUtils", "IsEventValid"))
  rawset(host, "getLocale", readGlobalFunction("GetLocale"))

  rawset(host, "getAddOnMetadata", readAddOnFunction("GetAddOnMetadata", "GetAddOnMetadata"))
  rawset(host, "isAddOnLoaded", readAddOnFunction("IsAddOnLoaded", "IsAddOnLoaded"))
  rawset(host, "getAddOnInfo", readAddOnFunction("GetAddOnInfo", "GetAddOnInfo"))
  rawset(
    host,
    "getAddOnDependencies",
    readAddOnFunction("GetAddOnDependencies", "GetAddOnDependencies")
  )
  rawset(
    host,
    "getAddOnOptionalDependencies",
    readAddOnFunction("GetAddOnOptionalDependencies", "GetAddOnOptionalDependencies")
  )
  rawset(
    host,
    "getItemInfo",
    readNamespaceFunction("C_Item", "GetItemInfo") or readGlobalFunction("GetItemInfo")
  )

  -- The two spell forms return different shapes, so both are kept: the
  -- modern one passes its table through, the legacy one is reshaped.
  rawset(host, "getSpellInfoTable", readNamespaceFunction("C_Spell", "GetSpellInfo"))
  rawset(host, "getSpellInfoValues", readGlobalFunction("GetSpellInfo"))
end

-- Probe on every bootstrap, first load and upgrade alike, so a newer revision
-- re-reads the host into the same shared tables.
rawset(state, "flavor", probeFlavor())
probeBuild()
bindHostFunctions()
probeLocale()
probeCapabilities()

---The secret probe: the `issecretvalue` bound at load, or, when the client had
---none then, the global's current value, so a probe installed after load is
---still honoured. `false` when there is none (nothing is secret).
---@return function|false
local function readSecretProbe()
  local isSecretValue = rawget(host, "isSecretValue")
  if isSecretValue then
    return isSecretValue
  end
  return readGlobalFunction("issecretvalue")
end

-- Validation helpers ----------------------------------------------------------
--
-- Argument validation raises with an explicit stack level so the reported
-- position is the line that called the public method. `level` is the value
-- `error` needs inside the function that receives it.

---Describe a caller-supplied value for an error message without formatting a
---secret into it, and without running its code: a table or userdata may carry
---a `__tostring` metamethod, so anything but a string, number, boolean or `nil`
---is named by its type (`<table>`).
---@param value any
---@return string
local function describeValue(value)
  local isSecretValue = readSecretProbe()
  if isSecretValue and isSecretValue(value) then
    return SECRET_PLACEHOLDER
  end
  local valueType = type(value)
  if valueType == "string" then
    return string.format("%q", value)
  end
  if valueType == "number" or valueType == "boolean" or valueType == "nil" then
    return tostring(value)
  end
  return "<" .. valueType .. ">"
end

---@param value any
---@param methodName string public method name, used in the argument error
---@param parameterName string
---@param level integer stack level the failure is reported at
local function validateString(value, methodName, parameterName, level)
  if type(value) ~= "string" then
    error(methodName .. " " .. parameterName .. " must be a string", level)
  end
end

---Refuse a value `issecretvalue` reports secret before it is compared, used
---as a table key or formatted into a message; each of those is a host error
---on a secret. A host without secret values has nothing to refuse.
---@param value any
---@param methodName string public method name, used in the argument error
---@param parameterName string
---@param level integer stack level the failure is reported at
local function validateNotSecret(value, methodName, parameterName, level)
  local isSecretValue = readSecretProbe()
  if isSecretValue and isSecretValue(value) then
    error(methodName .. " " .. parameterName .. " must not be a secret value", level)
  end
end

---@param value any
---@param methodName string public method name, used in the argument error
---@param parameterName string
---@param expected string how the accepted forms are described, for example "an item ID or an item name"
---@param level integer stack level the failure is reported at
local function validateIdOrName(value, methodName, parameterName, expected, level)
  local valueType = type(value)
  if valueType ~= "number" and valueType ~= "string" then
    error(methodName .. " " .. parameterName .. " must be " .. expected, level)
  end
end

-- Identity ---------------------------------------------------------------------

---Return the client flavour.
---@return ClientKit.Flavor
local function packageGetFlavor()
  return rawget(state, "flavor")
end

---Return the client version string, build number and build date.
---
---Each value is `nil` when the host does not report it.
---@return string? version For example `"12.1.0"`.
---@return integer? build The client build number.
---@return string? buildDate For example `"Sep 23 2026"`.
local function packageGetBuild()
  return rawget(state, "version") or nil,
    rawget(state, "build") or nil,
    rawget(state, "buildDate") or nil
end

---Return the `## Interface` number of the running client, or `0` when the host
---does not report one.
---@return integer
local function packageGetInterfaceNumber()
  return rawget(state, "interfaceNumber")
end

---Whether the running client's interface number is at least `interfaceNumber`.
---
---Interface numbers are ordered within one flavour only: Classic Era's `11509`
---is lower than Mists Classic's `50504` although both are current. Combine
---this with `GetFlavor()` when the floor depends on the flavour.
---
---A secret `interfaceNumber` is refused first: the NaN test and the floor
---comparison both compare it, and comparing a secret from insecure code
---raises inside ClientKit rather than at the caller.
---@param _ ClientKit
---@param interfaceNumber number
---@return boolean
local function packageIsAtLeast(_, interfaceNumber)
  validateNotSecret(interfaceNumber, "ClientKit:IsAtLeast", "interfaceNumber", 3)
  if type(interfaceNumber) ~= "number" or interfaceNumber ~= interfaceNumber then
    error("ClientKit:IsAtLeast interfaceNumber must be a number", 2)
  end
  return rawget(state, "interfaceNumber") >= interfaceNumber
end

-- Capabilities -------------------------------------------------------------------

---Whether the host exposes `capability`.
---
---An unknown name raises at the caller instead of answering `false`, so a typo
---cannot silently disable a feature. A secret name is refused before it is
---used as the table key, which the host would raise on with no useful line.
---@param _ ClientKit
---@param capability ClientKit.Capability
---@return boolean
local function packageHas(_, capability)
  validateString(capability, "ClientKit:Has", "capability", 3)
  validateNotSecret(capability, "ClientKit:Has", "capability", 3)
  local value = rawget(capabilities, capability)
  if value == nil then
    error("ClientKit:Has does not know capability " .. describeValue(capability), 2)
  end
  return value
end

-- Taint probes -------------------------------------------------------------------

---Whether `value` is a secret value.
---
---Uses `issecretvalue` when the host provides it; clients without secret values
---answer `false` for everything.
---@param _ ClientKit
---@param value any
---@return boolean
local function packageIsSecret(_, value)
  local isSecretValue = readSecretProbe()
  if not isSecretValue then
    return false
  end
  return isSecretValue(value) == true
end

---Whether insecure code may touch `frame` in the current execution context.
---
---`false` when `frame:IsForbidden()` says so, or when
---`frame:CanBeAccessedInContext()` exists and refuses. `true` means only that
---the host offers no restriction it can report — not that touching the frame is
---safe in every other respect.
---@param _ ClientKit
---@param frame table
---@return boolean
local function packageCanAccessFrame(_, frame)
  if type(frame) ~= "table" then
    error("ClientKit:CanAccessFrame frame must be a frame table", 2)
  end

  local isForbidden = frame.IsForbidden
  if type(isForbidden) == "function" and isForbidden(frame) then
    return false
  end

  local canBeAccessedInContext = frame.CanBeAccessedInContext
  if type(canBeAccessedInContext) == "function" and not canBeAccessedInContext(frame) then
    return false
  end

  return true
end

---Whether the running client knows the event `eventName`.
---
---Returns `true` or `false` from `C_EventUtils.IsEventValid` when the host
---provides it, and `nil` — "unknown", not "invalid" — when it does not.
---@param _ ClientKit
---@param eventName string
---@return boolean?
local function packageIsEventValid(_, eventName)
  validateString(eventName, "ClientKit:IsEventValid", "eventName", 3)
  local isEventValid = rawget(host, "isEventValid")
  if not isEventValid then
    return nil
  end
  return isEventValid(eventName) and true or false
end

-- Shims --------------------------------------------------------------------------

---Return one `## Field` of an addon's `.toc`, or `nil` when it is absent or
---empty.
---@param _ ClientKit
---@param addon string|integer addon folder name or index
---@param field string `.toc` field name, for example `"Version"` or `"X-Website"`
---@return string?
local function packageGetAddOnMetadata(_, addon, field)
  validateIdOrName(addon, "ClientKit:GetAddOnMetadata", "addon", "an addon name or index", 3)
  validateString(field, "ClientKit:GetAddOnMetadata", "field", 3)

  local getAddOnMetadata = rawget(host, "getAddOnMetadata")
  if not getAddOnMetadata then
    return nil
  end

  local value = getAddOnMetadata(addon, field)
  if type(value) ~= "string" or value == "" then
    return nil
  end
  return value
end

---Whether an addon is loading, and whether its load has finished.
---
---Always two booleans. `loaded, not finished` is an addon whose files are
---running but whose `ADDON_LOADED` has not completed.
---@param _ ClientKit
---@param addon string|integer addon folder name or index
---@return boolean loaded
---@return boolean finished
local function packageIsAddOnLoaded(_, addon)
  validateIdOrName(addon, "ClientKit:IsAddOnLoaded", "addon", "an addon name or index", 3)

  local isAddOnLoaded = rawget(host, "isAddOnLoaded")
  if not isAddOnLoaded then
    return false, false
  end

  -- Older clients answer `1`/`nil` rather than booleans.
  local loaded, finished = isAddOnLoaded(addon)
  return loaded and true or false, finished and true or false
end

---Return a spell's name, icon, cast time, range and ID as one table, or `nil`
---when the client does not know the spell.
---
---On a client with `C_Spell.GetSpellInfo` the host's table is returned as is.
---On an older client the legacy multiple returns are copied into a new table,
---so that path allocates one table per known spell.
---@param _ ClientKit
---@param spell integer|string spell ID or spell name
---@return ClientKit.SpellInfo?
local function packageGetSpellInfo(_, spell)
  validateIdOrName(spell, "ClientKit:GetSpellInfo", "spell", "a spell ID or a spell name", 3)

  local getSpellInfoTable = rawget(host, "getSpellInfoTable")
  if getSpellInfoTable then
    return getSpellInfoTable(spell)
  end

  local getSpellInfoValues = rawget(host, "getSpellInfoValues")
  if not getSpellInfoValues then
    return nil
  end

  local name, _, iconID, castTime, minRange, maxRange, spellID = getSpellInfoValues(spell)
  if not name then
    return nil
  end
  return {
    name = name,
    iconID = iconID,
    castTime = castTime,
    minRange = minRange,
    maxRange = maxRange,
    spellID = spellID,
  }
end

---Return the host's item information for `item`, unchanged.
---
---`C_Item.GetItemInfo` and the legacy `GetItemInfo` return the same list, so
---this shim only chooses between them: `itemName, itemLink, itemQuality,
---itemLevel, itemMinLevel, itemType, itemSubType, itemStackCount,
---itemEquipLoc, itemTexture, sellPrice, classID, subclassID, bindType,
---expansionID, setID, isCraftingReagent, itemDescription`, with trailing
---values a client does not provide left `nil`. Nothing is returned while the
---item is not in the client's cache; the client then requests it and fires
---`GET_ITEM_INFO_RECEIVED`.
---@param _ ClientKit
---@param item integer|string item ID, item name or item link
---@return ...
local function packageGetItemInfo(_, item)
  validateIdOrName(item, "ClientKit:GetItemInfo", "item", "an item ID, name or link", 3)

  local getItemInfo = rawget(host, "getItemInfo")
  if not getItemInfo then
    return nil
  end
  return getItemInfo(item)
end

-- Manifests ----------------------------------------------------------------------
--
-- A manifest is a read-only snapshot of one addon's `.toc`, built on the first
-- `GetManifest(addonName)` call for that addon and kept in `state.manifests`
-- for the session under the lower-cased name, because the host matches addon
-- names case-insensitively. The snapshot handed out is a proxy: an empty table whose
-- metatable reads through to a private `entries` table and refuses every
-- write, so one consumer cannot change what another reads. `Get` is resolved
-- through `manifestPrototype`, which lives in the state so a newer revision
-- rewrites it in place for snapshots created before the upgrade.
--
-- Every host read goes through `pcall`. The clients differ in which `.toc`
-- fields their metadata call exports, and a client that does not export a
-- field raises instead of answering `nil`. For a snapshot that means "absent",
-- not "failed", so the error is swallowed and the field reads `nil`.

---One cached manifest: the proxy callers hold, and what it reads through to.
---@class ClientKit.ManifestRecord
---@field name string Addon folder name as the host spells it, else as the caller spelt it.
---@field view table The read-only proxy handed to callers.
---@field entries table The snapshot fields the proxy reads through to.
---@field memo table<string, string|false> Raw `.toc` values by field name; `false` marks a snapshot field the host had no value for.

-- Shared by every `entries` table: `Get`, and nothing else, comes from the
-- prototype. A snapshot field that is `nil` therefore falls through to the
-- prototype and still reads `nil`.
local ENTRIES_METATABLE = { __index = manifestPrototype }

---Refuse every write to a manifest snapshot, at the line that wrote.
---
---The proxy holds no keys of its own, so `__newindex` sees every assignment,
---including one that would overwrite a field the snapshot has.
---@param view table
---@param key any
local function refuseManifestWrite(view, key)
  error(
    "ClientKit manifest for "
      .. describeValue(view.name)
      .. " is read-only; field "
      .. describeValue(key)
      .. " cannot be written",
    2
  )
end

---Read one raw `.toc` field from the host: `nil` when the field is absent or
---empty, when the client does not export it, or when the host has no metadata
---call.
---@param addonName string
---@param field string
---@return string?
local function readManifestField(addonName, field)
  local getAddOnMetadata = rawget(host, "getAddOnMetadata")
  if not getAddOnMetadata then
    return nil
  end
  local ok, value = pcall(getAddOnMetadata, addonName, field)
  if not ok or type(value) ~= "string" or value == "" then
    return nil
  end
  return value
end

---Read a snapshot field and remember it, absence included, so a later
---`Get(field)` for the same spelling never asks the host again.
---@param record ClientKit.ManifestRecord
---@param field string
---@return string?
local function rememberField(record, field)
  local value = readManifestField(rawget(record, "name"), field)
  rawset(rawget(record, "memo"), field, value or false)
  return value
end

---Read a field whose `.toc` spelling may carry the client locale as a suffix:
---`Title-deDE` is tried before `Title` when the locale is known.
---@param record ClientKit.ManifestRecord
---@param field string the plain field name, `"Title"` or `"Notes"`
---@return string?
local function readLocalisedField(record, field)
  local locale = rawget(state, "locale")
  if locale then
    local localised = rememberField(record, field .. "-" .. locale)
    if localised ~= nil then
      return localised
    end
  end
  return rememberField(record, field)
end

---Split a comma-separated `.toc` list into trimmed, non-empty names.
---@param raw string
---@return string[]
local function splitList(raw)
  local items = {}
  for piece in raw:gmatch("[^,]+") do
    local item = piece:match(LIST_ITEM_PATTERN)
    if item ~= "" then
      items[#items + 1] = item
    end
  end
  return items
end

---Collect the multiple returns of a host list call into an array.
---@param ok boolean whether the `pcall` succeeded
---@param ... any the call's returns
---@return string[]? items `nil` when the call raised
local function packHostList(ok, ...)
  if not ok then
    return nil
  end
  local items = {}
  for index = 1, select("#", ...) do
    local item = select(index, ...)
    if type(item) == "string" and item ~= "" then
      items[#items + 1] = item
    end
  end
  return items
end

---Ask the host's own list call (`C_AddOns.GetAddOnDependencies`, say) for a
---list the metadata call did not export.
---@param hostListName string|false entry in the bound host table, or `false` when no such call exists
---@param addonName string
---@return string[]? items `nil` when the host lacks the call or it raised
local function readHostList(hostListName, addonName)
  local hostList = hostListName and rawget(host, hostListName) or false
  if not hostList then
    return nil
  end
  return packHostList(pcall(hostList, addonName))
end

---Read a list field as an array, from the metadata string under either of its
---spellings, else from the host's dedicated list call, else empty.
---@param record ClientKit.ManifestRecord
---@param field string
---@param aliasField string|false
---@param hostListName string|false
---@return string[]
local function readListField(record, field, aliasField, hostListName)
  local raw = rememberField(record, field)
  if raw == nil and aliasField then
    raw = rememberField(record, aliasField)
  end
  if raw ~= nil then
    return splitList(raw)
  end
  return readHostList(hostListName, rawget(record, "name")) or {}
end

---Whether the host lists an addon named `addonName`, and how it spells it.
---
---`GetAddOnInfo` does not raise for a name it does not know on either client
---generation: it echoes the name back with the fifth return, `reason`, set to
---`"MISSING"`. The `pcall` guards only against an argument the host rejects
---outright. The caller asks this only on a host that has the call; a host
---without it is recognised through `hostHasTitle` instead.
---@param getAddOnInfo function the bound `GetAddOnInfo`
---@param addonName string
---@return boolean listed
---@return string? hostName the folder name as the host spells it, when listed
local function hostListsAddOn(getAddOnInfo, addonName)
  local ok, hostName, _, _, _, reason = pcall(getAddOnInfo, addonName)
  if not ok or type(hostName) ~= "string" or reason == "MISSING" then
    return false
  end
  return true, hostName
end

---Whether `## Title`, in its localised or plain spelling, reads for
---`addonName`. Used only to recognise an addon on a host without
---`GetAddOnInfo`; the snapshot re-reads the field into its memo afterwards.
---@param addonName string
---@return boolean
local function hostHasTitle(addonName)
  local locale = rawget(state, "locale")
  if locale and readManifestField(addonName, "Title-" .. locale) ~= nil then
    return true
  end
  return readManifestField(addonName, "Title") ~= nil
end

---Read every snapshot field of `addonName` from the host and wrap the result
---in its read-only proxy. This is the one allocating step of the manifest
---path: the record, its entries, memo and proxy tables, the proxy's metatable
---and the four list arrays, once per addon per session.
---@param addonName string
---@return ClientKit.ManifestRecord
local function buildManifestRecord(addonName)
  local entries = setmetatable({ name = addonName }, ENTRIES_METATABLE)
  local record = { name = addonName, entries = entries, memo = {}, view = false }

  for index = 1, #MANIFEST_LOCALISED_FIELDS do
    local pair = MANIFEST_LOCALISED_FIELDS[index]
    rawset(entries, pair[1], readLocalisedField(record, pair[2]))
  end
  for index = 1, #MANIFEST_SCALAR_FIELDS do
    local pair = MANIFEST_SCALAR_FIELDS[index]
    rawset(entries, pair[1], rememberField(record, pair[2]))
  end
  for index = 1, #MANIFEST_LIST_FIELDS do
    local row = MANIFEST_LIST_FIELDS[index]
    rawset(entries, row[1], readListField(record, row[2], row[3], row[4]))
  end

  rawset(
    record,
    "view",
    setmetatable({}, {
      __index = entries,
      __newindex = refuseManifestWrite,
      __metatable = false,
    })
  )
  return record
end

---Return any raw `## Field` of the manifest's `.toc`, `X-` fields included.
---
---A field is asked of the host once and remembered; the snapshot fields were
---already remembered when the manifest was built, absence included. A field
---the `.toc` does not have is asked again on each call rather than remembered,
---so the memo grows only by fields the file actually has, never by the names a
---caller tries.
---@param view ClientKit.Manifest
---@param field string `.toc` field name, for example `"X-Website"` or `"RequiredDeps"`
---@return string?
local function manifestGet(view, field)
  -- The receiver is the caller's value, so its `name` is read without a
  -- boolean test and asked of `issecretvalue` before it is lowered or used
  -- as a key: testing, lowering or keying a secret raises inside ClientKit.
  -- A secret name belongs to no manifest, so it takes the receiver refusal.
  local name
  if type(view) == "table" then
    name = view.name
  end
  local record
  if type(name) == "string" and not packageIsSecret(ClientKit, name) then
    record = rawget(manifests, string.lower(name))
  end
  if record == nil or not rawequal(rawget(record, "view"), view) then
    error("ClientKit.Manifest:Get must be called on a manifest", 2)
  end
  validateString(field, "ClientKit.Manifest:Get", "field", 3)
  validateNotSecret(field, "ClientKit.Manifest:Get", "field", 3)

  local memo = rawget(record, "memo")
  local remembered = rawget(memo, field)
  if remembered ~= nil then
    return remembered or nil
  end

  local value = readManifestField(rawget(record, "name"), field)
  if value ~= nil then
    rawset(memo, field, value)
  end
  return value
end

---Return the read-only manifest of the addon `addonName`, reading its `.toc`
---on the first call and answering from the cache after that.
---
---The name is matched case-insensitively, as the host matches it, so every
---spelling of one addon shares one snapshot; `manifest.name` carries the
---host's spelling when `GetAddOnInfo` reports one. `nil, "unknown"` is an
---addon the host does not list; nothing is cached for it, so a misspelt name
---costs one host round trip per call and never grows the cache.
---`nil, "unavailable"` is a host with no metadata call at all.
---
---Whether the host lists the addon is asked of `GetAddOnInfo` when the host
---has it, and of a readable `## Title` only when it does not: once
---`GetAddOnInfo` has answered `"MISSING"` no metadata can read for that name,
---so asking for the title would only add host calls for every unknown name.
---@param _ ClientKit
---@param addonName string addon folder name
---@return ClientKit.Manifest? manifest
---@return ClientKit.ManifestFailure? reason
local function packageGetManifest(_, addonName)
  validateString(addonName, "ClientKit:GetManifest", "addonName", 3)
  validateNotSecret(addonName, "ClientKit:GetManifest", "addonName", 3)

  local key = string.lower(addonName)
  local record = rawget(manifests, key)
  if record ~= nil then
    return rawget(record, "view")
  end

  if not rawget(host, "getAddOnMetadata") then
    return nil, "unavailable"
  end

  local hostName = addonName
  local getAddOnInfo = rawget(host, "getAddOnInfo")
  if getAddOnInfo then
    local listed, spelling = hostListsAddOn(getAddOnInfo, addonName)
    if not listed then
      return nil, "unknown"
    end
    hostName = spelling or addonName
  elseif not hostHasTitle(addonName) then
    return nil, "unknown"
  end

  record = buildManifestRecord(hostName)
  rawset(manifests, key, record)
  return rawget(record, "view")
end

-- Deprecations -------------------------------------------------------------------
--
-- A Kit declares each thing it deprecates once, with `Deprecate`, and keeps the
-- reporter it gets back; on the deprecated path it calls `reporter:Warn()`.
-- The consumer is told once per call site, or once per addon when the Kit
-- passes the addon's name, and never once per call: each reporter keeps a
-- once-table keyed by the call site's `debugstack` frame or by the addon name,
-- and a repeated call costs a lookup in it. Everything lives in
-- `state.deprecation`, so reporters, reports and the mode survive an in-place
-- upgrade, and `Warn` is resolved through a prototype a newer revision
-- rewrites.
--
-- The call site comes from the client's `debugstack`, not from the `debug`
-- library, which the Retail client does not publish. `debugstack`'s level 1 is
-- the function that calls it, so inside `readCallSite` level 1 is
-- `readCallSite`, 2 is `Warn`, 3 the Kit's method and 4 its caller: a `Warn`
-- level `n`, counted as the Kit's own `error(message, n)` would count it, is
-- `debugstack` level `n + 2`.
--
-- The section sits in a `do` block so its helpers do not count against the
-- main chunk's 200 locals.

local packageDeprecate
local packageGetDeprecationReports
local packageSetDeprecationMode
local packageGetDeprecationMode
local packageSetLimits
local packageGetLimits
local reporterWarn

do
  -- The client's `debugstack`, read once per load like the host functions
  -- above. It is kept in this block rather than in `state.host` because the
  -- only reader is `readCallSite` below, which a newer revision replaces
  -- together with this local.
  -- selene: allow(global_usage)
  local debugStack = rawget(_G, "debugstack")
  if type(debugStack) ~= "function" then
    debugStack = false
  end

  -- `Interface/AddOns/` in any letter case and with either path separator: the
  -- Retail client writes `[Interface/AddOns/MyAddon/Core.lua]:42:`, and the
  -- other forms a client may use (`[string "@Interface\AddOns\..."]:42:`) are
  -- accepted until a client suite has shown each flavour's spelling.
  local ADDONS_FOLDER_PATTERN =
    "[Ii][Nn][Tt][Ee][Rr][Ff][Aa][Cc][Ee][/\\][Aa][Dd][Dd][Oo][Nn][Ss][/\\]"

  -- From the `Interface` of `ADDONS_FOLDER_PATTERN`: the file path (up to a
  -- quote, a bracket or a colon), the closing quote or bracket if any, and
  -- the line number.
  local FRAME_LOCATION_PATTERN = '^([^"%]:]+)["%]]*:(%d+)'

  -- The addon folder of a normalised path `Interface/AddOns/<Addon>/...`.
  local ADDON_FOLDER_PATTERN = "^[^/]+/[^/]+/([^/]+)"

  ---Validate a text the caller must supply: not secret, then a non-empty
  ---string.
  ---@param value any
  ---@param methodName string public method name, used in the argument error
  ---@param parameterName string
  ---@param level integer stack level the failure is reported at
  local function validateText(value, methodName, parameterName, level)
    validateNotSecret(value, methodName, parameterName, level + 1)
    if type(value) ~= "string" or value == "" then
      error(methodName .. " " .. parameterName .. " must be a non-empty string", level)
    end
  end

  ---Validate a text the caller may leave out: not secret, then `nil` or a
  ---non-empty string.
  ---@param value any
  ---@param methodName string public method name, used in the argument error
  ---@param parameterName string
  ---@param level integer stack level the failure is reported at
  local function validateOptionalText(value, methodName, parameterName, level)
    validateNotSecret(value, methodName, parameterName, level + 1)
    if value ~= nil and (type(value) ~= "string" or value == "") then
      error(methodName .. " " .. parameterName .. " must be a non-empty string or nil", level)
    end
  end

  ---Hand `message` to the host error handler, else to `print`.
  ---
  ---Neither may raise into the Kit's deprecated method: a deprecation warning
  ---must never break the call it warns about, so both run under `pcall` and
  ---a failure is dropped. `geterrorhandler` is read on every report because
  ---an error-capturing addon replaces the handler after ClientKit loads.
  ---@param message string
  local function deliver(message)
    local getErrorHandler = readGlobal("geterrorhandler")
    if type(getErrorHandler) == "function" then
      local found, handler = pcall(getErrorHandler)
      if found and type(handler) == "function" then
        pcall(handler, message)
        return
      end
    end
    local printMessage = readGlobal("print")
    if type(printMessage) == "function" then
      pcall(printMessage, message)
    end
  end

  ---Return the client's text for the frame `level` above `Warn`'s caller, or
  ---`nil` when the host has no `debugstack`, answers nothing or answers a
  ---secret. Called from `Warn` only; see the section comment for the level.
  ---
  ---The raw text is returned unchanged, because it is the once-key and must
  ---not cost a new string before the lookup.
  ---@param level integer `Warn`'s level
  ---@return string? text
  local function readCallSite(level)
    if not debugStack then
      return nil
    end
    local text = debugStack(level + 2, 1, 0)
    if type(text) ~= "string" or packageIsSecret(ClientKit, text) or text == "" then
      return nil
    end
    return text
  end

  ---Name the addon and the location of a `debugstack` frame.
  ---
  ---Only the first line is read: with more frames below it, the client adds a
  ---`...` line. A frame outside `Interface/AddOns/` (a chunk loaded from a
  ---string, say) names no addon, and its trimmed text is the location.
  ---@param text string
  ---@return string? addon the folder after `Interface/AddOns/`
  ---@return string? location `Interface/AddOns/MyAddon/Core.lua:42`, or the frame's text
  local function describeCallSite(text)
    local frame = string.match(text, "^%s*([^\n]-)%s*\n") or string.match(text, "^%s*(.-)%s*$")
    local start = string.find(frame, ADDONS_FOLDER_PATTERN)
    local path, line
    if start then
      path, line = string.match(frame, FRAME_LOCATION_PATTERN, start)
    end
    if type(path) == "nil" then
      if frame == "" then
        return nil, nil
      end
      return nil, frame
    end
    path = string.gsub(path, "\\", "/")
    return string.match(path, ADDON_FOLDER_PATTERN), path .. ":" .. line
  end

  ---The text one report carries.
  ---@param reporter table
  ---@param addon string
  ---@param location string?
  ---@return string
  local function formatReport(reporter, addon, location)
    local text = "MoltenCodes: " .. rawget(reporter, "name") .. " is deprecated"
    local replacement = rawget(reporter, "replacement")
    if replacement then
      text = text .. "; use " .. replacement
    end
    text = text .. ". Removal: " .. rawget(reporter, "removal") .. ". Called from " .. addon
    if location then
      text = text .. " (" .. location .. ")"
    end
    return text .. "."
  end

  ---Return the one reporter handed out past `maxDeprecations`, reporting the
  ---limit once a session (unless the mode is `"silent"`). It never raises: a
  ---Kit declares its deprecations while it loads, and a full table must not
  ---stop that.
  ---@param name string the name that did not fit
  ---@return table reporter
  local function inertReporterFor(name)
    if not rawget(deprecation, "capReported") then
      rawset(deprecation, "capReported", true)
      if rawget(deprecation, "mode") ~= "silent" then
        deliver(
          "MoltenCodes ClientKit: maxDeprecations ("
            .. rawget(rawget(deprecation, "limits"), "maxDeprecations")
            .. ") reached; "
            .. describeValue(name)
            .. " and later deprecations report nothing (raise it with ClientKit:SetLimits)."
        )
      end
    end
    local inert = rawget(deprecation, "inert")
    if not inert then
      inert = setmetatable({
        name = "",
        removal = "",
        replacement = false,
        seen = {},
        inert = true,
      }, rawget(deprecation, "metatable"))
      rawset(deprecation, "inert", inert)
    end
    return inert
  end

  ---Declare one deprecated thing and return its reporter.
  ---
  ---A name declared before returns the same reporter, with this call's
  ---`removal` and `replacement`, so a Kit upgraded in place re-declaring its
  ---deprecations at load adds nothing and the newer text wins.
  ---@param _ ClientKit
  ---@param spec ClientKit.DeprecationSpec
  ---@return ClientKit.DeprecationReporter
  packageDeprecate = function(_, spec)
    validateNotSecret(spec, "ClientKit:Deprecate", "spec", 3)
    if type(spec) ~= "table" then
      error("ClientKit:Deprecate spec must be a table", 2)
    end
    local name, removal, replacement = spec.name, spec.removal, spec.replacement
    validateText(name, "ClientKit:Deprecate", "spec.name", 3)
    validateText(removal, "ClientKit:Deprecate", "spec.removal", 3)
    validateOptionalText(replacement, "ClientKit:Deprecate", "spec.replacement", 3)

    local reporters = rawget(deprecation, "reporters")
    local reporter = rawget(reporters, name)
    if reporter ~= nil then
      rawset(reporter, "removal", removal)
      rawset(reporter, "replacement", replacement or false)
      return reporter
    end

    local count = rawget(deprecation, "count")
    if count >= rawget(rawget(deprecation, "limits"), "maxDeprecations") then
      return inertReporterFor(name)
    end
    reporter = setmetatable({
      name = name,
      removal = removal,
      replacement = replacement or false,
      -- Call-site frame text, or addon name, to `true`; `true` itself is the
      -- key when the client names no site and the Kit no addon.
      seen = {},
      inert = false,
    }, rawget(deprecation, "metatable"))
    rawset(reporters, name, reporter)
    rawset(deprecation, "count", count + 1)
    return reporter
  end

  ---Tell the consumer that called the Kit's deprecated method, once per call
  ---site, or once per addon when `addonName` is given.
  ---
  ---`level` counts as the Kit's own `error(message, level)` would: 1 is the
  ---Kit's method, 2 (the default) its caller. In `"raise"` mode every call
  ---raises the report at that level and nothing is recorded, so a Kit calls
  ---`Warn` before it changes any state.
  ---@param self ClientKit.DeprecationReporter
  ---@param level integer?
  ---@param addonName string? the consuming addon, when the Kit knows it
  reporterWarn = function(self, level, addonName)
    local seen = type(self) == "table"
      and rawequal(getmetatable(self), rawget(deprecation, "metatable"))
      and rawget(self, "seen")
    if type(seen) ~= "table" then
      error("ClientKit.DeprecationReporter:Warn must be called on a reporter", 2)
    end
    validateNotSecret(level, "ClientKit.DeprecationReporter:Warn", "level", 3)
    if level == nil then
      level = DEFAULT_WARN_LEVEL
    elseif
      type(level) ~= "number"
      or level < 1
      or level ~= math.floor(level)
      or level == math.huge
    then
      error("ClientKit.DeprecationReporter:Warn level must be a positive integer or nil", 2)
    end
    validateOptionalText(addonName, "ClientKit.DeprecationReporter:Warn", "addonName", 3)
    if rawget(self, "inert") then
      return
    end

    local mode = rawget(deprecation, "mode")
    if mode == "raise" then
      local siteAddon, location
      local raiseText = readCallSite(level)
      if raiseText then
        siteAddon, location = describeCallSite(raiseText)
      end
      error(formatReport(self, addonName or siteAddon or UNKNOWN_ADDON, location), level + 1)
    end

    local reports = rawget(deprecation, "reports")
    if #reports >= rawget(rawget(deprecation, "limits"), "maxReports") then
      return
    end

    local key, text
    if addonName ~= nil then
      if rawget(seen, addonName) then
        return
      end
      key = addonName
      text = readCallSite(level)
    else
      text = readCallSite(level)
      key = text or true
      if rawget(seen, key) then
        return
      end
    end
    rawset(seen, key, true)

    local siteAddon, location
    if text then
      siteAddon, location = describeCallSite(text)
    end
    local addon = addonName or siteAddon or UNKNOWN_ADDON
    reports[#reports + 1] = {
      name = rawget(self, "name"),
      replacement = rawget(self, "replacement") or nil,
      removal = rawget(self, "removal"),
      addon = addon,
      site = location,
    }
    if mode == "report" then
      deliver(formatReport(self, addon, location))
    end
  end

  ---Return every report recorded this session, oldest first, as fresh rows a
  ---caller may keep or change.
  ---@return ClientKit.DeprecationReport[]
  packageGetDeprecationReports = function()
    local reports = rawget(deprecation, "reports")
    local rows = {}
    for index = 1, #reports do
      local report = reports[index]
      rows[index] = {
        name = report.name,
        replacement = report.replacement,
        removal = report.removal,
        addon = report.addon,
        site = report.site,
      }
    end
    return rows
  end

  ---Set the session's deprecation mode. One switch for every addon in the
  ---session; `"raise"` is meant for development.
  ---@param _ ClientKit
  ---@param mode ClientKit.DeprecationMode
  packageSetDeprecationMode = function(_, mode)
    validateNotSecret(mode, "ClientKit:SetDeprecationMode", "mode", 3)
    if type(mode) ~= "string" or DEPRECATION_MODES[mode] ~= true then
      error('ClientKit:SetDeprecationMode mode must be "report", "silent" or "raise"', 2)
    end
    rawset(deprecation, "mode", mode)
  end

  ---Return the session's deprecation mode.
  ---@return ClientKit.DeprecationMode
  packageGetDeprecationMode = function()
    return rawget(deprecation, "mode")
  end

  ---Change any subset of the deprecation limits. Every entry is checked
  ---before any is applied, so a refused call changes nothing. Lowering a
  ---limit below what is already held keeps it: past `maxDeprecations` new
  ---names get the inert reporter, past `maxReports` nothing more is recorded.
  ---@param _ ClientKit
  ---@param limits ClientKit.Limits
  packageSetLimits = function(_, limits)
    validateNotSecret(limits, "ClientKit:SetLimits", "limits", 3)
    if type(limits) ~= "table" then
      error("ClientKit:SetLimits limits must be a table", 2)
    end
    for key, value in pairs(limits) do
      local ceiling = type(key) == "string"
        and not packageIsSecret(ClientKit, key)
        and LIMIT_CEILINGS[key]
      if not ceiling then
        error("ClientKit:SetLimits does not know limit " .. describeValue(key), 2)
      end
      validateNotSecret(value, "ClientKit:SetLimits", "limits." .. key, 3)
      if type(value) ~= "number" or value < 1 or value > ceiling or value ~= math.floor(value) then
        error(
          "ClientKit:SetLimits limits." .. key .. " must be an integer from 1 to " .. ceiling,
          2
        )
      end
    end
    local current = rawget(deprecation, "limits")
    for index = 1, #LIMIT_NAMES do
      local limitName = LIMIT_NAMES[index]
      local value = rawget(limits, limitName)
      if value ~= nil then
        rawset(current, limitName, value)
      end
    end
  end

  ---Return the deprecation limits as a fresh table.
  ---@return ClientKit.Limits
  packageGetLimits = function()
    local current = rawget(deprecation, "limits")
    return {
      maxDeprecations = rawget(current, "maxDeprecations"),
      maxReports = rawget(current, "maxReports"),
    }
  end
end

-- Commit ----------------------------------------------------------------------

rawset(manifestPrototype, "Get", manifestGet)
rawset(rawget(deprecation, "prototype"), "Warn", reporterWarn)

rawset(ClientKit, "API", API_GENERATION)
rawset(ClientKit, "REVISION", IMPLEMENTATION_REVISION)
rawset(ClientKit, "GetFlavor", packageGetFlavor)
rawset(ClientKit, "GetBuild", packageGetBuild)
rawset(ClientKit, "GetInterfaceNumber", packageGetInterfaceNumber)
rawset(ClientKit, "IsAtLeast", packageIsAtLeast)
rawset(ClientKit, "Has", packageHas)
rawset(ClientKit, "IsSecret", packageIsSecret)
rawset(ClientKit, "CanAccessFrame", packageCanAccessFrame)
rawset(ClientKit, "IsEventValid", packageIsEventValid)
rawset(ClientKit, "GetAddOnMetadata", packageGetAddOnMetadata)
rawset(ClientKit, "IsAddOnLoaded", packageIsAddOnLoaded)
rawset(ClientKit, "GetSpellInfo", packageGetSpellInfo)
rawset(ClientKit, "GetItemInfo", packageGetItemInfo)
rawset(ClientKit, "GetManifest", packageGetManifest)
rawset(ClientKit, "Deprecate", packageDeprecate)
rawset(ClientKit, "GetDeprecationReports", packageGetDeprecationReports)
rawset(ClientKit, "SetDeprecationMode", packageSetDeprecationMode)
rawset(ClientKit, "GetDeprecationMode", packageGetDeprecationMode)
rawset(ClientKit, "SetLimits", packageSetLimits)
rawset(ClientKit, "GetLimits", packageGetLimits)

if not validatePublicSurface(ClientKit) or not validateCurrentState(ClientKit) then
  error("MoltenCodes ClientKit package state is corrupted or incomplete", 2)
end

return ClientKit
