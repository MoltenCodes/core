-- MoltenCodes CompatKit
--
-- Compatibility plumbing three kinds of addon code keep rewriting:
--
--   shims       named, integer-versioned fixes applied once per session, the
--               newest version winning across embedded copies, any of them
--               switched off by name (TaintLess's model);
--   providers   one registry per kind of pluggable implementation, each entry
--               with a liveness probe and a priority, resolved through a
--               deterministic cascade and memoised until the probe says the
--               memoised entry died (LibSink's model);
--   catalogue   the taint-hostile Blizzard subsystems and their sanctioned
--               replacements, as data (`CompatKit.CATALOGUE`), mirrored from
--               docs/EMBEDDING.md and checked against the apiKit metadata.
--
-- CompatKit requires Registry API 2 and nothing else. ClientKit (the client
-- flavour a shim is filtered on) and ApiKit (the documented surface a shim's
-- `covers` names are checked against) are found at call time through
-- `Registry:Find` and are absent without breaking anything. Everything here is
-- load-time work apart from `registry:Resolve`, which is allocation-free.
--
-- Contents
-- --------
--   Constants ............. identity, limits, statuses, the catalogue rows
--   Public types .......... LuaCATS declarations for the published surface
--   Dependencies .......... Registry
--   Validation ............ public-surface and shared-state predicates
--   Bootstrap ............. Registry registration and inherited state
--   Host facilities ....... secret values, the error handler, optional Kits
--   Argument checks ....... names, versions, priorities, option tables
--   Read-only views ....... the proxy every published table uses
--   Shims ................. Shim, SkipShim, GetShims, Apply and the context
--   Providers ............. Providers and the registry prototype
--   Limits ................ SetLimits, GetLimits
--   Catalogue ............. CATALOGUE built from the rows
--   Commit ................ prototype/facade assignment and self-check
--
-- Layout and invariants are described in `docs/INTERNALS.md`.

-- Constants ------------------------------------------------------------------

local PACKAGE_NAME = "compatKit"
local API_GENERATION = 1
local IMPLEMENTATION_REVISION = 2
local REQUIRED_REGISTRY_API = 2
local STATE_SCHEMA = 1

-- The optional Kits, found through `Registry:Find` at call time.
local CLIENTKIT_PACKAGE = "clientKit"
local CLIENTKIT_API = 1
local APIKIT_PACKAGE = "apiKit"
local APIKIT_API = 1

-- ApiKit publishes its namespace root as `MoltenCodes.wow`; every `api` table
-- under it holds the installed bindings of one flavour, and only the running
-- flavour's table is ever filled. `APIKIT_ROOT_DEPTH` is how many nested
-- tables may lie between the root and an `api` table: `retail.api` has one,
-- `classic.era.api` has two, and the walk stops below that.
local APIKIT_ROOT_KEY = "wow"
local APIKIT_API_KEY = "api"
local APIKIT_ROOT_DEPTH = 2

-- Defaults of the three limits. Shims and providers are load-time
-- registrations by addons, so these guard against a runaway loop rather than
-- budget any real addon; every one of them accepts `UNBOUNDED`.
local MAX_SHIMS = 64
local MAX_PROVIDERS = 32
local MAX_PROVIDER_KINDS = 32

-- The limits `SetLimits` accepts, in the order `GetLimits` reports them.
local LIMIT_NAMES = { "maxShims", "maxProviders", "maxProviderKinds" }
local LIMIT_NAME_SET = { maxShims = true, maxProviders = true, maxProviderKinds = true }

-- Lua 5.1 numbers are doubles; integers are exact only up to 2^53.
local MAXIMUM_INTEGER = 2 ^ 53

-- What `Shim` reports about a registration.
local SHIM_PENDING = "pending"
local SHIM_REPLACED = "replaced"
local SHIM_RECORDED = "recorded"
local SHIM_IGNORED = "ignored"
local SHIM_FULL = "full"

-- The status a shim record carries in `GetShims`.
local STATUS_PENDING = "pending"
local STATUS_APPLIED = "applied"
local STATUS_SKIPPED = "skipped"
local STATUS_FAILED = "failed"
local STATUS_FILTERED = "filtered"

-- What a provider registry reports.
local PROVIDER_EXISTS = "exists"
local PROVIDER_FULL = "full"
local PROVIDER_NONE = "none"
local DEFAULT_PRIORITY = 0

-- The fields a `Shim` option table may carry.
local SHIM_OPTION_KEYS = { description = true, flavours = true, covers = true }

-- Shapes of a documented API name: a global (`GetMouseFoci`) or one function
-- of one namespace (`C_TooltipInfo.GetUnit`). Both halves must be identifiers.
local API_GLOBAL_NAME_PATTERN = "^[%a_][%w_]*$"
local API_NAMESPACED_NAME_PATTERN = "^[%a_][%w_]*%.[%a_][%w_]*$"

-- The `__metatable` value every provider registry carries; it hides the
-- prototype and is how a receiver is recognised.
local REGISTRY_TAG = "CompatKit.ProviderRegistry"

local FACADE_METHODS = {
  "Shim",
  "SkipShim",
  "GetShims",
  "Apply",
  "Providers",
  "SetLimits",
  "GetLimits",
}
local REGISTRY_METHODS = { "Register", "Unregister", "Resolve", "List" }

-- The catalogue of taint-hostile subsystems. The same rows, in the same
-- order, are the table in docs/EMBEDDING.md ("Catalogue of taint-hostile
-- subsystems"); `tooling/tests/test_compat_catalogue.py` holds the two
-- together and checks every `replacementApi` and its `flavours` against the
-- committed apiKit metadata. `replacementApi` is `false` when the sanctioned
-- replacement is FrameXML or the addon's own frames, which the documented
-- API tables do not describe; `flavours` is then empty.
local CATALOGUE_ROWS = {
  {
    subsystem = "UIDropDownMenu (UIDropDownMenu_*, EasyMenu)",
    reason = "One shared set of dropdown frames and globals (UIDROPDOWNMENU_OPEN_MENU, "
      .. "UIDROPDOWNMENU_MENU_LEVEL) serves every menu; a write from insecure code taints "
      .. "them and blocks the next secure menu (unit frame and raid frame menus)",
    replacement = "Menu and MenuUtil (Blizzard_Menu, FrameXML): own menu descriptions, "
      .. "no shared globals",
    replacementApi = false,
    flavours = {},
  },
  {
    subsystem = "StaticPopup_Show dialogs",
    reason = "The four StaticPopup<n> frames are shared; a dialog shown from insecure code "
      .. "taints the frame Blizzard reuses for its next protected confirmation",
    replacement = "Own dialog frames (WidgetKit; dialogKit when it ships)",
    replacementApi = false,
    flavours = {},
  },
  {
    subsystem = "ActionButton_ShowOverlayGlow / ActionButton_HideOverlayGlow",
    reason = "Writes overlay fields on secure action buttons, tainting the action bar and "
      .. "blocking its secure updates in combat",
    replacement = "Own glow frame parented to the button, state kept in a table of your own "
      .. "keyed by the button",
    replacementApi = false,
    flavours = {},
  },
  {
    subsystem = "Hidden tooltip scanning (GameTooltip:SetOwner/SetUnit, "
      .. "GameTooltipTextLeft<n>)",
    reason = "GameTooltip is shared with the secure UI; setting it from insecure code taints "
      .. "it, and in combat the text it shows is a secret value",
    replacement = "C_TooltipInfo.GetUnit and its siblings return the tooltip data as a table; "
      .. "post-hook with TooltipDataProcessor.AddTooltipPostCall",
    replacementApi = "C_TooltipInfo.GetUnit",
    flavours = { "beta", "ptr", "retail" },
  },
  {
    subsystem = "GetAddOnMetadata (legacy global)",
    reason = "Removed from Retail in 10.1; an addon that writes the global back to shim it "
      .. "taints a name secure code reads",
    replacement = "C_AddOns.GetAddOnMetadata (ClientKit:GetAddOnMetadata chooses per client)",
    replacementApi = "C_AddOns.GetAddOnMetadata",
    flavours = { "beta", "classic-era", "classic-mop", "ptr", "retail" },
  },
  {
    subsystem = "ShowUIPanel / HideUIPanel on Blizzard panels",
    reason = "UIParent's panel management (UIPanelWindows, UIParent_ManageFramePositions) is "
      .. "secure; a call from insecure code taints its layout state and blocks secure "
      .. "panels in combat",
    replacement = "Own frames outside the UIPanel system; UISpecialFrames for Escape to close",
    replacementApi = false,
    flavours = {},
  },
  {
    subsystem = "InterfaceOptionsFrame_OpenToCategory",
    reason = "Removed with InterfaceOptionsFrame in 10.0; compatibility wrappers that recreate "
      .. "it write into the Settings frames",
    replacement = "Settings.OpenToCategory(categoryID) (Blizzard_Settings, FrameXML) opens "
      .. "your category; C_SettingsUtil.OpenSettingsPanel opens the panel",
    replacementApi = "C_SettingsUtil.OpenSettingsPanel",
    flavours = { "beta", "classic-era", "classic-mop", "ptr", "retail" },
  },
  {
    subsystem = "SetOverrideBindingClick in combat",
    reason = "Protected while in combat lockdown; a call from insecure code then raises "
      .. "ADDON_ACTION_BLOCKED and the binding is lost",
    replacement = "Record the intent at once and apply it out of combat "
      .. "(LifecycleKit instance:WhenOutOfCombat)",
    replacementApi = false,
    flavours = {},
  },
  {
    subsystem = "CompactUnitFrame hooks that write frame fields",
    reason = "The compact raid frames are secure; replacing CompactUnitFrame_* functions or "
      .. "writing fields on the frames taints them for the session",
    replacement = "hooksecurefunc post-hooks (HookKit SecureHook) that write nothing on the "
      .. "frame; read auras through C_UnitAuras.GetAuraDataByIndex",
    replacementApi = "C_UnitAuras.GetAuraDataByIndex",
    flavours = { "beta", "classic-era", "classic-mop", "ptr", "retail" },
  },
}

local tableSort = table.sort
local tableRemove = table.remove
local tableInsert = table.insert

-- Public types ---------------------------------------------------------------
--
-- CompatKit publishes its methods by writing them onto Registry-owned tables,
-- so the editor-facing contract is declared here as LuaCATS classes rather
-- than inferred from those assignments.

---A shim implementation: run at most once per session by `Apply`.
---@alias CompatKit.ShimImplementation fun(context: CompatKit.ShimContext)

---What `Shim` reports: `"pending"` (first registration), `"replaced"` (a
---newer version replaced the pending one), `"recorded"` (a newer version was
---recorded after the shim ran; it is not run), `"ignored"` (an equal or lower
---version), `"full"` (the `maxShims` limit).
---@alias CompatKit.ShimResult "pending"|"replaced"|"recorded"|"ignored"|"full"

---Where a shim stands: `"pending"` (registered, not applied yet),
---`"applied"`, `"skipped"` (host opt-out), `"failed"` (its implementation
---raised) or `"filtered"` (its `flavours` exclude the running client).
---@alias CompatKit.ShimStatus "pending"|"applied"|"skipped"|"failed"|"filtered"

---Options accepted by `CompatKit:Shim`.
---@class CompatKit.ShimOptions
---@field description string? What the shim does, for `GetShims` listings.
---@field flavours string[]? ClientKit flavour ids (`"mainline"`, `"mists"`, `"tbc"`, `"classic"`) the shim applies to. Elsewhere it is filtered; without ClientKit it applies everywhere.
---@field covers string[]? Documented API names the shim relates to (`"C_TooltipInfo.GetUnit"`), checked with `hasApi` at apply time when ApiKit is loaded.

---The read-only table every shim implementation receives.
---@class CompatKit.ShimContext
---@field flavour string|false The ClientKit flavour, or `false` without ClientKit.
---@field hasApi fun(name: string): boolean Whether ApiKit's installed surface binds the documented function `name` (`"C_TooltipInfo.GetUnit"` or a global such as `"GetMouseFoci"`). `false` without ApiKit or without an installed flavour file.
---@field hasGlobal fun(name: string): boolean Whether the host global `name` (a dotted path is followed) is not `nil`.

---One row of `CompatKit:GetShims()`. A fresh table per row per call.
---@class CompatKit.ShimRecord
---@field name string
---@field version integer The newest version registered.
---@field applied integer|false The version that ran, or `false`.
---@field skipped boolean Whether `SkipShim` named it.
---@field failed any|false The error value its implementation raised, or `false`.
---@field status CompatKit.ShimStatus
---@field description string|false
---@field flavours string[]|false A copy of `options.flavours`, or `false`.
---@field covers string[]|false A copy of `options.covers`, or `false`.
---@field missing string[]|false The `covers` names `hasApi` reported absent when the shim ran with ApiKit loaded; `false` before it ran or without ApiKit.

---A provider's liveness probe: `true` while the provider can be used.
---@alias CompatKit.ProviderProbe fun(): boolean

---One row of `registry:List()`. A fresh table per row per call.
---@class CompatKit.ProviderRow
---@field name string
---@field priority integer
---@field alive boolean What the probe answered for this listing.

---One registry of providers of a kind, returned by `CompatKit:Providers`.
---@class CompatKit.ProviderRegistry
---@field Register fun(self: CompatKit.ProviderRegistry, name: string, implementation: any, probe: CompatKit.ProviderProbe?, priority: integer?): boolean, ("exists"|"full")?
---@field Unregister fun(self: CompatKit.ProviderRegistry, name: string): boolean
---@field Resolve fun(self: CompatKit.ProviderRegistry, preferred: string?): any, string
---@field List fun(self: CompatKit.ProviderRegistry): CompatKit.ProviderRow[]

---One catalogue row, read-only.
---@class CompatKit.CatalogueRow
---@field subsystem string The Blizzard subsystem or call.
---@field reason string Why touching it from insecure code taints.
---@field replacement string The sanctioned replacement.
---@field replacementApi string|false The documented API the replacement names, checked against the apiKit metadata; `false` for FrameXML or own frames.
---@field flavours string[] Read-only view of the apiKit flavour ids whose metadata documents `replacementApi`; index from 1 to `flavourCount`.
---@field flavourCount integer

---The shared limits. `SetLimits` accepts any subset; `GetLimits` returns all.
---@class CompatKit.Limits
---@field maxShims integer|table Most shims `Shim` records: a positive integer or `CompatKit.UNBOUNDED`; default `64`.
---@field maxProviders integer|table Most providers one kind holds; default `32`.
---@field maxProviderKinds integer|table Most kinds `Providers` creates; default `32`.

---The CompatKit package facade published through Registry.
---@class CompatKit
---@field API integer Public API generation.
---@field REVISION integer Compatible implementation revision.
---@field UNBOUNDED table Sentinel that lifts a limit; the same table for every revision.
---@field CATALOGUE CompatKit.CatalogueRow[] Read-only view of the catalogue rows; index from 1 to `CATALOGUE_COUNT`.
---@field CATALOGUE_COUNT integer
---@field Shim fun(self: CompatKit, name: string, version: integer, implementation: CompatKit.ShimImplementation, options: CompatKit.ShimOptions?): boolean, CompatKit.ShimResult
---@field SkipShim fun(self: CompatKit, name: string): boolean, "full"?
---@field GetShims fun(self: CompatKit): CompatKit.ShimRecord[]
---@field Apply fun(self: CompatKit): applied: integer, skipped: integer, failed: integer
---@field Providers fun(self: CompatKit, kind: string): CompatKit.ProviderRegistry
---@field SetLimits fun(self: CompatKit, limits: CompatKit.Limits)
---@field GetLimits fun(self: CompatKit): CompatKit.Limits

---One shim as the package keeps it. Private.
---@class CompatKit.ShimEntry
---@field name string
---@field version integer
---@field implementation CompatKit.ShimImplementation|false pending implementation; `false` once attempted
---@field applied integer|false
---@field attempted boolean whether `Apply` ran, failed or filtered it
---@field skipped boolean
---@field failed any|false
---@field filtered boolean
---@field description string|false
---@field flavours string[]|false
---@field covers string[]|false
---@field missing string[]|false

---One provider as a registry keeps it. Private.
---@class CompatKit.ProviderEntry
---@field implementation any
---@field probe CompatKit.ProviderProbe|false
---@field priority integer

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
  error("MoltenCodes CompatKit requires Registry API 2 to be loaded first", 2)
end

local bootstrapPackage = rawget(Registry, "Bootstrap")
if type(bootstrapPackage) ~= "function" or type(rawget(Registry, "Find")) ~= "function" then
  error("MoltenCodes CompatKit requires a valid Registry API 2 facade", 2)
end

---Read a host global without triggering a metatable, or `nil`.
---@param name string
---@return any
local function readGlobal(name)
  -- The World of Warcraft client API is reachable only through the global table.
  -- selene: allow(global_usage)
  return rawget(_G, name)
end

-- Validation -----------------------------------------------------------------

---Whether `implementation` exposes the complete CompatKit API 1 surface.
---@param implementation any shared package table handed back by Registry
---@return boolean
local function validatePublicSurface(implementation)
  if
    type(implementation) ~= "table"
    or rawget(implementation, "API") ~= API_GENERATION
    or type(rawget(implementation, "REVISION")) ~= "number"
    or type(rawget(implementation, "UNBOUNDED")) ~= "table"
    or type(rawget(implementation, "CATALOGUE")) ~= "table"
    or type(rawget(implementation, "CATALOGUE_COUNT")) ~= "number"
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

---Whether `value` is an exact integer of one or more. `nan` fails every
---comparison and infinity is refused before the integer test.
---@param value any
---@return boolean
local function isPositiveInteger(value)
  return type(value) == "number" and value >= 1 and value <= MAXIMUM_INTEGER and value % 1 == 0
end

---Whether `limits` holds a valid value for every limit this revision knows.
---@param limits any
---@param unbounded any the package's sentinel
---@return boolean
local function validateLimitsTable(limits, unbounded)
  if type(limits) ~= "table" then
    return false
  end
  for index = 1, #LIMIT_NAMES do
    local value = rawget(limits, LIMIT_NAMES[index])
    if value ~= unbounded and not isPositiveInteger(value) then
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
  local unbounded = rawget(currentState, "unbounded")
  return type(unbounded) == "table"
    and validateLimitsTable(rawget(currentState, "limits"), unbounded)
    and type(rawget(currentState, "runtimeRevision")) == "number"
    and type(rawget(currentState, "shims")) == "table"
    and type(rawget(currentState, "shimCount")) == "number"
    and type(rawget(currentState, "skips")) == "table"
    and type(rawget(currentState, "skipCount")) == "number"
    and type(rawget(currentState, "providers")) == "table"
    and type(rawget(currentState, "providerKindCount")) == "number"
    and type(rawget(currentState, "registryPrototype")) == "table"
    and type(rawget(currentState, "registryMetatable")) == "table"
    and type(rawget(currentState, "applying")) == "boolean"
end

---Whether `implementation` carries package state of this revision's schema,
---and publishes the sentinel that state owns.
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
-- and register this one. What stays here is what only CompatKit can answer.
local CompatKit, previousRevision, selected = bootstrapPackage(Registry, {
  package = PACKAGE_NAME,
  api = API_GENERATION,
  revision = IMPLEMENTATION_REVISION,
  label = "MoltenCodes CompatKit",
  validatePublicSurface = validatePublicSurface,
  validateState = validateCurrentState,
})

if CompatKit == nil then
  -- An equal or newer compatible revision already owns the shared package table.
  return selected
end

local state = rawget(CompatKit, "_state")

if previousRevision == nil then
  if state ~= nil then
    error("MoltenCodes CompatKit package state is corrupted or incomplete", 2)
  end

  state = {
    schema = STATE_SCHEMA,
    runtimeRevision = 0,
    -- The sentinel `SetLimits` accepts to lift a limit. It lives here, not
    -- in a file local, so every embedded revision hands out the same table.
    unbounded = {},
    -- The shared limits, kept across upgrades like everything else here.
    limits = {
      maxShims = MAX_SHIMS,
      maxProviders = MAX_PROVIDERS,
      maxProviderKinds = MAX_PROVIDER_KINDS,
    },
    -- Shim name to its entry (see "Shims"), and how many there are.
    shims = {},
    shimCount = 0,
    -- Names `SkipShim` marked, whether or not a shim of that name exists
    -- yet: the opt-out may arrive before the registration. `skipCount` is
    -- how many of them have no shim yet; those count against `maxShims`
    -- until their shim arrives, so the table is bounded like the shims.
    skips = {},
    skipCount = 0,
    -- Provider kind to its registry object, and how many kinds exist.
    providers = {},
    providerKindCount = 0,
    -- The prototype and metatable every registry shares. The prototype's
    -- functions are rewritten by every loading revision.
    registryPrototype = {},
    registryMetatable = {},
    -- Whether `Apply` is running, so a shim cannot re-enter it.
    applying = false,
  }
  rawset(CompatKit, "_state", state)
elseif not validateStateBase(state) then
  error("MoltenCodes CompatKit package state is corrupted or incomplete", 2)
end

local shims = rawget(state, "shims")
local skips = rawget(state, "skips")
local providerRegistries = rawget(state, "providers")
local RegistryPrototype = rawget(state, "registryPrototype")
local REGISTRY_METATABLE = rawget(state, "registryMetatable")
local sharedLimits = rawget(state, "limits")
local UNBOUNDED = rawget(state, "unbounded")

-- Host facilities ------------------------------------------------------------

---Whether `value` is a secret value (Retail 12.x). `issecretvalue` is looked
---up at every call, so a probe that appears after load is used at once.
---@param value any
---@return boolean
local function isSecret(value)
  local probe = readGlobal("issecretvalue")
  return type(probe) == "function" and probe(value) == true
end

---Hand a failure from a shim or a probe to the host error handler.
---
---The failure is passed on unchanged: it may be a secret string built from a
---secret value, and CompatKit never inspects it. Outside a client there is no
---handler, and printing is what the client's default handler does; a handler
---that itself raises (an error-display addon with a bug) falls back to the
---same print, so reporting one failure can never become a second one.
---@param failure any
local function reportError(failure)
  local getErrorHandler = readGlobal("geterrorhandler")
  if type(getErrorHandler) == "function" then
    local handler = getErrorHandler()
    if type(handler) == "function" and pcall(handler, failure) then
      return
    end
  end
  print(failure)
end

---Find an optional Kit through `Registry:Find`, or `nil` when it is not
---registered. Called at call time, never at load, so load order is free.
---@param packageName string
---@param api integer
---@return table|nil
local function findOptional(packageName, api)
  local found = Registry:Find(packageName, api)
  if type(found) == "table" then
    return found
  end
  return nil
end

-- Argument checks ------------------------------------------------------------
--
-- Argument validation raises with an explicit stack level so the reported
-- position is the line that called the public method, never a line inside
-- CompatKit. `level` is always the value `error` needs *inside the function
-- that receives it*, so every further hop towards `error` adds exactly one.
-- Secrets are checked first, because comparing one raises.

---@param value any
---@param label string argument description, used in the argument error
---@param level integer stack level the failure is reported at
local function validateName(value, label, level)
  if isSecret(value) then
    error(label .. " must not be a secret value", level)
  end
  if type(value) ~= "string" or value == "" then
    error(label .. " must be a non-empty string", level)
  end
end

---@param value any
---@param label string
---@param level integer
local function validateVersion(value, label, level)
  if isSecret(value) then
    error(label .. " must not be a secret value", level)
  end
  if not isPositiveInteger(value) then
    error(label .. " must be a positive integer", level)
  end
end

---A priority is any integer, negative ones included, so a fallback can sit
---below the default `0`.
---@param value any
---@param label string
---@param level integer
local function validatePriority(value, label, level)
  if isSecret(value) then
    error(label .. " must not be a secret value", level)
  end
  if
    type(value) ~= "number"
    or value % 1 ~= 0
    or value < -MAXIMUM_INTEGER
    or value > MAXIMUM_INTEGER
  then
    error(label .. " must be an integer", level)
  end
end

---Refuse a receiver that is not the facade.
---@param receiver any
---@param label string public method name
---@param level integer
local function validateFacade(receiver, label, level)
  -- `type` first: a secret receiver is never a table, and only a table is compared.
  if type(receiver) ~= "table" or receiver ~= CompatKit then
    error(label .. " must be called on the CompatKit facade; use " .. label .. "(...)", level)
  end
end

---Refuse a receiver that is not a provider registry.
---@param receiver any
---@param methodName string `"CompatKit.ProviderRegistry:Register"` and the like
---@param level integer
local function validateRegistry(receiver, methodName, level)
  if type(receiver) ~= "table" or getmetatable(receiver) ~= REGISTRY_TAG then
    error(
      methodName
        .. " must be called on a provider registry; use registry:"
        .. methodName:match("[^:]+$")
        .. "(...)",
      level
    )
  end
end

---Refuse a non-table option table and any field outside `allowedKeys`,
---naming the alphabetically first unknown field without allocating.
---@param options any
---@param allowedKeys table<string, true>
---@param methodName string
---@param level integer
local function validateOptionKeys(options, allowedKeys, methodName, level)
  if type(options) ~= "table" then
    error(methodName .. " options must be a table or nil", level)
  end
  local firstUnknown = nil
  for key in next, options do
    if isSecret(key) then
      error(methodName .. " options must not have a secret key", level)
    end
    if allowedKeys[key] ~= true then
      local text = type(key) == "string" and key or "<" .. type(key) .. " key>"
      if firstUnknown == nil or text < firstUnknown then
        firstUnknown = text
      end
    end
  end
  if firstUnknown ~= nil then
    error(methodName .. ' options contains unknown field "' .. firstUnknown .. '"', level)
  end
end

---Whether `name` has the shape of a documented API name.
---@param name string
---@return boolean
local function isApiName(name)
  return name:match(API_GLOBAL_NAME_PATTERN) ~= nil
    or name:match(API_NAMESPACED_NAME_PATTERN) ~= nil
end

---Copy a non-empty array of non-secret, non-empty strings, each accepted by
---`isValid` when one is given.
---@param value any
---@param label string `"CompatKit:Shim options.covers"` and the like
---@param what string how one entry is described in the errors
---@param isValid (fun(entry: string): boolean)|false
---@param level integer
---@return string[]
local function readStringArray(value, label, what, isValid, level)
  if type(value) ~= "table" or #value == 0 then
    error(label .. " must be a non-empty array of " .. what .. "s", level)
  end
  local copy = {}
  for index = 1, #value do
    local entry = value[index]
    if isSecret(entry) then
      error(label .. " must not contain a secret value", level)
    end
    if type(entry) ~= "string" or entry == "" or (isValid and not isValid(entry)) then
      error(label .. " contains an invalid " .. what, level)
    end
    copy[index] = entry
  end
  return copy
end

---Read the options of `Shim` into the three fields a shim entry keeps.
---@param options any
---@param level integer
---@return string|false description
---@return string[]|false flavours
---@return string[]|false covers
local function readShimOptions(options, level)
  if isSecret(options) then
    error("CompatKit:Shim options must not be a secret value", level)
  end
  if type(options) == "nil" then
    return false, false, false
  end
  validateOptionKeys(options, SHIM_OPTION_KEYS, "CompatKit:Shim", level + 1)

  -- Each field is checked for secrecy first; absence is tested with `type`.
  local description = rawget(options, "description")
  if isSecret(description) then
    error("CompatKit:Shim options.description must not be a secret value", level)
  end
  if type(description) ~= "nil" and type(description) ~= "string" then
    error("CompatKit:Shim options.description must be a string", level)
  end

  local flavours = rawget(options, "flavours")
  if isSecret(flavours) then
    error("CompatKit:Shim options.flavours must not be a secret value", level)
  end
  if type(flavours) ~= "nil" then
    flavours =
      readStringArray(flavours, "CompatKit:Shim options.flavours", "flavour id", false, level + 1)
  end

  local covers = rawget(options, "covers")
  if isSecret(covers) then
    error("CompatKit:Shim options.covers must not be a secret value", level)
  end
  if type(covers) ~= "nil" then
    covers =
      readStringArray(covers, "CompatKit:Shim options.covers", "API name", isApiName, level + 1)
  end

  return description or false, flavours or false, covers or false
end

-- Read-only views ------------------------------------------------------------
--
-- A published table (the catalogue, its rows, a shim context) is an empty
-- proxy whose metatable reads through to the real table and refuses every
-- write at the writer's line. On Lua 5.1 `#`, `ipairs` and `pairs` do not see
-- through a proxy, which is why every array view comes with a count.

---Build a read-only view of `fields`.
---@param fields table
---@param label string what the error names, for example `"CompatKit.CATALOGUE"`
---@return table view
local function newReadOnlyView(fields, label)
  return setmetatable({}, {
    __index = fields,
    __newindex = function(_, key)
      local keyText = "<" .. type(key) .. ">"
      if type(key) == "string" and not isSecret(key) then
        keyText = '"' .. key .. '"'
      end
      error(label .. " is read-only; field " .. keyText .. " cannot be written", 2)
    end,
    __metatable = false,
  })
end

---Copy an array of strings, or pass `false` through.
---@param array string[]|false
---@return string[]|false
local function copyArray(array)
  if array == false then
    return false
  end
  local copy = {}
  for index = 1, #array do
    copy[index] = array[index]
  end
  return copy
end

-- Shims ----------------------------------------------------------------------
--
-- One entry per name. A registration before `Apply` keeps the highest version
-- and its implementation; `Apply` runs each pending, unskipped, unfiltered
-- implementation once, in name order, and marks the entry attempted whatever
-- happened, so a shim is never run twice in one session. A registration with a
-- higher version after that only moves `version`: the record then shows which
-- version ran and which is the newest present.

---Whether the shim `entry` applies to the running client: always without
---ClientKit, else when `flavours` is absent or names the client's flavour.
---@param entry CompatKit.ShimEntry
---@param flavour string|false
---@return boolean
local function shimAppliesTo(entry, flavour)
  local flavours = rawget(entry, "flavours")
  if flavours == false or flavour == false then
    return true
  end
  for index = 1, #flavours do
    if flavours[index] == flavour then
      return true
    end
  end
  return false
end

---Read the client flavour from ClientKit, or `false` without it.
---@return string|false
local function readFlavour()
  local ClientKit = findOptional(CLIENTKIT_PACKAGE, CLIENTKIT_API)
  local getFlavor = ClientKit and rawget(ClientKit, "GetFlavor") or nil
  if type(getFlavor) ~= "function" then
    return false
  end
  local flavour = getFlavor(ClientKit)
  if type(flavour) ~= "string" then
    return false
  end
  return flavour
end

---Follow the dotted path `name` through the host global table with raw reads:
---the first segment is a global, every later one a field of the table before
---it. A missing or non-table step ends the walk with `nil`; a later segment is
---never read as a global of its own.
---@param name string
---@return any
local function readGlobalPath(name)
  local dot = name:find(".", 1, true)
  local value = readGlobal(dot and name:sub(1, dot - 1) or name)
  while dot ~= nil do
    if type(value) ~= "table" then
      return nil
    end
    local start = dot + 1
    dot = name:find(".", start, true)
    value = rawget(value, dot and name:sub(start, dot - 1) or name:sub(start))
  end
  return value
end

---Collect every function bound in the `api` tables under ApiKit's namespace
---root into `index`, keyed by the function itself.
---
---Bindings are direct aliases of host functions, so identity is the one check
---that needs no copy of the naming rules; only the running flavour's `api`
---table holds anything, so walking every one costs the installed surface once.
---@param root any
---@param depth integer how many nested tables may still be entered below `root`
---@param index table<function, true>
local function collectInstalledFunctions(root, depth, index)
  if type(root) ~= "table" then
    return
  end
  for key, value in next, root do
    if key == APIKIT_API_KEY and type(value) == "table" then
      for _, namespaceTable in next, value do
        if type(namespaceTable) == "table" then
          for _, binding in next, namespaceTable do
            if type(binding) == "function" then
              index[binding] = true
            end
          end
        end
      end
    elseif type(value) == "table" and depth > 0 then
      collectInstalledFunctions(value, depth - 1, index)
    end
  end
end

---Build the installed-surface index for one `Apply`, or `nil` without ApiKit.
---@return table<function, true>|nil
local function buildInstalledIndex()
  if findOptional(APIKIT_PACKAGE, APIKIT_API) == nil then
    return nil
  end
  local currentNamespace = readGlobal("MoltenCodes")
  local root = type(currentNamespace) == "table" and rawget(currentNamespace, APIKIT_ROOT_KEY)
    or nil
  local index = {}
  collectInstalledFunctions(root, APIKIT_ROOT_DEPTH, index)
  return index
end

---Build the read-only context one `Apply` hands to every shim it runs.
---
---`hasApi` builds the installed-surface index on its first call and keeps it
---for this `Apply` only, so a flavour file that loads between two `Apply`
---calls is seen by the second.
---@param flavour string|false
---@return CompatKit.ShimContext context
---@return fun(): table<function, true>|nil installedIndex the index reader, for `covers`
local function newShimContext(flavour)
  local installedIndex = nil
  local indexBuilt = false

  local function installedFunctions()
    if not indexBuilt then
      installedIndex = buildInstalledIndex()
      indexBuilt = true
    end
    return installedIndex
  end

  local function hasApi(name)
    validateName(name, "CompatKit.ShimContext.hasApi name", 3)
    local index = installedFunctions()
    if index == nil then
      return false
    end
    local hostFunction = readGlobalPath(name)
    return type(hostFunction) == "function" and index[hostFunction] == true
  end

  local function hasGlobal(name)
    validateName(name, "CompatKit.ShimContext.hasGlobal name", 3)
    -- A host value may be secret: absence is tested with `type`.
    return type(readGlobalPath(name)) ~= "nil"
  end

  local fields = { flavour = flavour, hasApi = hasApi, hasGlobal = hasGlobal }
  return newReadOnlyView(fields, "CompatKit shim context"), installedFunctions
end

---The `covers` names of `entry` that ApiKit's installed surface lacks, or
---`false` when ApiKit is absent or the shim covers nothing.
---@param entry CompatKit.ShimEntry
---@param context CompatKit.ShimContext
---@param installedFunctions fun(): table<function, true>|nil
---@return string[]|false
local function findMissingCovers(entry, context, installedFunctions)
  local covers = rawget(entry, "covers")
  if covers == false or installedFunctions() == nil then
    return false
  end
  local missing = {}
  for index = 1, #covers do
    if not context.hasApi(covers[index]) then
      missing[#missing + 1] = covers[index]
    end
  end
  return missing
end

---Run one pending shim under isolation and record the outcome.
---@param entry CompatKit.ShimEntry
---@param context CompatKit.ShimContext
---@return boolean succeeded
local function runShim(entry, context)
  local implementation = rawget(entry, "implementation")
  rawset(entry, "implementation", false)
  rawset(entry, "attempted", true)
  local ok, failure = pcall(implementation, context)
  if ok then
    rawset(entry, "applied", rawget(entry, "version"))
    return true
  end
  rawset(entry, "failed", failure)
  reportError(failure)
  return false
end

---Order two shim rows by name.
---@param left { name: string }
---@param right { name: string }
---@return boolean
local function rowBefore(left, right)
  return left.name < right.name
end

---The status a shim entry reports.
---@param entry CompatKit.ShimEntry
---@return CompatKit.ShimStatus
local function shimStatus(entry)
  if rawget(entry, "applied") ~= false then
    return STATUS_APPLIED
  end
  if rawget(entry, "failed") ~= false then
    return STATUS_FAILED
  end
  if rawget(entry, "filtered") then
    return STATUS_FILTERED
  end
  if rawget(entry, "skipped") then
    return STATUS_SKIPPED
  end
  return STATUS_PENDING
end

---Register `implementation` as version `version` of the shim `name`.
---
---Returns `true` with `"pending"` (a new shim), `"replaced"` (a newer version
---replaced the pending one) or `"recorded"` (the shim already ran; the newer
---version is recorded, not run); `false, "ignored"` for an equal or lower
---version; `false, "full"` at the `maxShims` limit.
---@param self CompatKit
---@param name string
---@param version integer
---@param implementation CompatKit.ShimImplementation
---@param options CompatKit.ShimOptions?
---@return boolean accepted
---@return CompatKit.ShimResult result
local function packageShim(self, name, version, implementation, options)
  validateFacade(self, "CompatKit:Shim", 3)
  validateName(name, "CompatKit:Shim name", 3)
  validateVersion(version, "CompatKit:Shim version", 3)
  if type(implementation) ~= "function" then
    error("CompatKit:Shim implementation must be a function", 2)
  end
  local description, flavours, covers = readShimOptions(options, 3)

  local entry = shims[name]
  if entry ~= nil then
    if version <= rawget(entry, "version") then
      return false, SHIM_IGNORED
    end
    rawset(entry, "version", version)
    rawset(entry, "description", description)
    rawset(entry, "flavours", flavours)
    rawset(entry, "covers", covers)
    if rawget(entry, "attempted") then
      -- `covers` moved with the version, so what the applied version
      -- found missing no longer describes this record.
      rawset(entry, "missing", false)
      return true, SHIM_RECORDED
    end
    -- A skipped shim's implementation is never kept: it will not run.
    if not rawget(entry, "skipped") then
      rawset(entry, "implementation", implementation)
    end
    return true, SHIM_REPLACED
  end

  -- A skip recorded before this registration already holds a slot, which
  -- this shim now takes over; any other new name needs a free one.
  local skipped = skips[name] == true
  local shimCount = rawget(state, "shimCount")
  local skipCount = rawget(state, "skipCount")
  local maxShims = rawget(sharedLimits, "maxShims")
  if not skipped and maxShims ~= UNBOUNDED and shimCount + skipCount >= maxShims then
    return false, SHIM_FULL
  end

  shims[name] = {
    name = name,
    version = version,
    implementation = not skipped and implementation or false,
    applied = false,
    attempted = false,
    skipped = skipped,
    failed = false,
    filtered = false,
    description = description,
    flavours = flavours,
    covers = covers,
    missing = false,
  }
  rawset(state, "shimCount", shimCount + 1)
  if skipped then
    rawset(state, "skipCount", skipCount - 1)
  end
  return true, SHIM_PENDING
end

---Mark the shim `name` as never to run, before or after it is registered.
---
---Returns `true`, or `false, "full"` when `name` has no shim yet and the
---shims plus the skips waiting for theirs already reach `maxShims`: a skip
---for a name that never arrives is retained for the session, so it takes a
---slot like a shim. A shim that already ran keeps its result; the mark is
---recorded for the listing. A pending shim's implementation is dropped.
---@param self CompatKit
---@param name string
---@return boolean marked
---@return "full"? reason
local function packageSkipShim(self, name)
  validateFacade(self, "CompatKit:SkipShim", 3)
  validateName(name, "CompatKit:SkipShim name", 3)

  local entry = shims[name]
  if entry ~= nil then
    skips[name] = true
    rawset(entry, "skipped", true)
    if not rawget(entry, "attempted") then
      rawset(entry, "implementation", false)
    end
    return true
  end
  if skips[name] == true then
    return true
  end

  local skipCount = rawget(state, "skipCount")
  local maxShims = rawget(sharedLimits, "maxShims")
  if maxShims ~= UNBOUNDED and rawget(state, "shimCount") + skipCount >= maxShims then
    return false, SHIM_FULL
  end
  skips[name] = true
  rawset(state, "skipCount", skipCount + 1)
  return true
end

---Return a fresh, name-sorted array of fresh shim records.
---@param self CompatKit
---@return CompatKit.ShimRecord[]
local function packageGetShims(self)
  validateFacade(self, "CompatKit:GetShims", 3)
  local rows = {}
  for _, entry in next, shims do
    rows[#rows + 1] = {
      name = rawget(entry, "name"),
      version = rawget(entry, "version"),
      applied = rawget(entry, "applied"),
      skipped = rawget(entry, "skipped"),
      failed = rawget(entry, "failed"),
      status = shimStatus(entry),
      description = rawget(entry, "description"),
      flavours = copyArray(rawget(entry, "flavours")),
      covers = copyArray(rawget(entry, "covers")),
      missing = copyArray(rawget(entry, "missing")),
    }
  end
  tableSort(rows, rowBefore)
  return rows
end

---Run the sorted `pending` entries under the guard `Apply` set; see `Apply`
---for the contract. Split out so `Apply` can run it under `pcall` and clear
---the guard whatever happens inside.
---@param pending CompatKit.ShimEntry[]
---@param flavour string|false
---@return integer applied
---@return integer skipped
---@return integer failed
local function applyPending(pending, flavour)
  local context, installedFunctions = newShimContext(flavour)
  local applied, skipped, failed = 0, 0, 0
  for index = 1, #pending do
    local entry = pending[index]
    if rawget(entry, "skipped") then
      skipped = skipped + 1
    elseif not shimAppliesTo(entry, flavour) then
      rawset(entry, "attempted", true)
      rawset(entry, "implementation", false)
      rawset(entry, "filtered", true)
      skipped = skipped + 1
    else
      rawset(entry, "missing", findMissingCovers(entry, context, installedFunctions))
      if runShim(entry, context) then
        applied = applied + 1
      else
        failed = failed + 1
      end
    end
  end
  return applied, skipped, failed
end

---Run every pending shim that is not skipped and applies to this client, in
---name order, each isolated: a failing shim is reported through the host
---error handler, recorded as `failed`, and does not stop the others.
---
---Returns how many shims ran, how many were left out (skipped by name or
---filtered by flavour) and how many failed, counting this call only. A second
---call runs only shims registered since; nothing runs twice.
---@param self CompatKit
---@return integer applied
---@return integer skipped
---@return integer failed
local function packageApply(self)
  validateFacade(self, "CompatKit:Apply", 3)
  if rawget(state, "applying") then
    error("CompatKit:Apply cannot be called from inside a shim", 2)
  end

  local pending = {}
  for _, entry in next, shims do
    if not rawget(entry, "attempted") then
      pending[#pending + 1] = entry
    end
  end
  tableSort(pending, rowBefore)
  local flavour = readFlavour()

  -- The guard is cleared whatever happens inside, so one failure that
  -- escapes the per-shim isolation cannot lock `Apply` for the session.
  rawset(state, "applying", true)
  local ok, appliedOrFailure, skipped, failed = pcall(applyPending, pending, flavour)
  rawset(state, "applying", false)
  if not ok then
    error(appliedOrFailure, 0)
  end
  return appliedOrFailure, skipped, failed
end

-- Providers ------------------------------------------------------------------
--
-- A registry keeps its providers by name and, beside them, an array of the
-- names ordered by priority (higher first) and then by name, so the cascade is
-- one walk over that array and allocates nothing. `_resolved` memoises the
-- cascade's last answer; every `Resolve` asks that provider's probe again
-- before trusting it.

---Whether `entry`'s probe reports it alive. A probe that raises is reported
---through the host error handler and counts as dead.
---@param entry CompatKit.ProviderEntry
---@return boolean
local function providerAlive(entry)
  local probe = rawget(entry, "probe")
  if probe == false then
    return true
  end
  local ok, alive = pcall(probe)
  if not ok then
    reportError(alive)
    return false
  end
  -- Only `true` counts as alive. The answer is the probe's, so a secret is
  -- dead before it is compared.
  return not isSecret(alive) and alive == true
end

---Whether the provider `left` comes before `right` in the cascade.
---@param leftName string
---@param leftPriority integer
---@param rightName string
---@param rightPriority integer
---@return boolean
local function providerBefore(leftName, leftPriority, rightName, rightPriority)
  if leftPriority ~= rightPriority then
    return leftPriority > rightPriority
  end
  return leftName < rightName
end

---Insert `name` into the registry's ordered array at its cascade position.
---@param registry table
---@param name string
---@param priority integer
local function insertOrdered(registry, name, priority)
  local order = rawget(registry, "_order")
  local providers = rawget(registry, "_providers")
  local position = #order + 1
  for index = 1, #order do
    local otherName = order[index]
    if providerBefore(name, priority, otherName, rawget(providers[otherName], "priority")) then
      position = index
      break
    end
  end
  tableInsert(order, position, name)
end

---Remove `name` from the registry's ordered array.
---@param registry table
---@param name string
local function removeOrdered(registry, name)
  local order = rawget(registry, "_order")
  for index = 1, #order do
    if order[index] == name then
      tableRemove(order, index)
      return
    end
  end
end

---Register `implementation` as the provider `name` of this kind.
---
---Returns `true`, or `false, "exists"` when the name is taken (unregister it
---first), or `false, "full"` at the `maxProviders` limit. `probe` answers
---whether the provider is usable right now (default: always); `priority`
---orders the cascade, higher first, default `0`.
---@param self CompatKit.ProviderRegistry
---@param name string
---@param implementation any anything but `nil`; what `Resolve` hands back
---@param probe CompatKit.ProviderProbe?
---@param priority integer?
---@return boolean registered
---@return ("exists"|"full")? reason
local function registryRegister(self, name, implementation, probe, priority)
  local methodName = "CompatKit.ProviderRegistry:Register"
  validateRegistry(self, methodName, 3)
  validateName(name, methodName .. " name", 3)
  -- Each argument is checked for secrecy first; absence is tested with `type`.
  if isSecret(implementation) then
    error(methodName .. " implementation must not be a secret value", 2)
  end
  if type(implementation) == "nil" then
    error(methodName .. " implementation must not be nil", 2)
  end
  if isSecret(probe) then
    error(methodName .. " probe must not be a secret value", 2)
  end
  if type(probe) ~= "nil" and type(probe) ~= "function" then
    error(methodName .. " probe must be a function or nil", 2)
  end
  if isSecret(priority) then
    error(methodName .. " priority must not be a secret value", 2)
  end
  if type(priority) == "nil" then
    priority = DEFAULT_PRIORITY
  else
    validatePriority(priority, methodName .. " priority", 3)
  end

  local providers = rawget(self, "_providers")
  if providers[name] ~= nil then
    return false, PROVIDER_EXISTS
  end
  local count = rawget(self, "_count")
  local maxProviders = rawget(sharedLimits, "maxProviders")
  if maxProviders ~= UNBOUNDED and count >= maxProviders then
    return false, PROVIDER_FULL
  end

  providers[name] = { implementation = implementation, probe = probe or false, priority = priority }
  rawset(self, "_count", count + 1)
  insertOrdered(self, name, priority)
  return true
end

---Remove the provider `name`. Returns whether it was registered.
---@param self CompatKit.ProviderRegistry
---@param name string
---@return boolean removed
local function registryUnregister(self, name)
  local methodName = "CompatKit.ProviderRegistry:Unregister"
  validateRegistry(self, methodName, 3)
  validateName(name, methodName .. " name", 3)

  local providers = rawget(self, "_providers")
  if providers[name] == nil then
    return false
  end
  providers[name] = nil
  rawset(self, "_count", rawget(self, "_count") - 1)
  removeOrdered(self, name)
  if rawget(self, "_resolved") == name then
    rawset(self, "_resolved", false)
  end
  return true
end

---Return a live provider's implementation and name, or `nil, "none"`.
---
---`preferred`, when it names a live provider, wins. Otherwise the memoised
---answer is returned when its probe still says alive; else the cascade finds
---the highest-priority live provider (ties broken by name order), memoises
---it and returns it. Allocation-free.
---@param self CompatKit.ProviderRegistry
---@param preferred string?
---@return any implementation
---@return string nameOrReason
local function registryResolve(self, preferred)
  local methodName = "CompatKit.ProviderRegistry:Resolve"
  validateRegistry(self, methodName, 3)
  local providers = rawget(self, "_providers")

  -- A provider whose probe said dead in this call is not asked again: the
  -- preferred one is remembered in `deadPreferred`, the memoised one in
  -- `deadMemo`, so a raising probe is reported once per `Resolve`.
  local deadPreferred = false ---@type string|false
  if isSecret(preferred) then
    error(methodName .. " preferred must not be a secret value", 2)
  end
  if type(preferred) ~= "nil" then
    validateName(preferred, methodName .. " preferred", 3)
    local entry = providers[preferred]
    if entry ~= nil then
      if providerAlive(entry) then
        return rawget(entry, "implementation"), preferred
      end
      deadPreferred = preferred
    end
  end

  local deadMemo = false ---@type string|false
  local resolved = rawget(self, "_resolved")
  if resolved ~= false then
    local entry = providers[resolved]
    if entry ~= nil and resolved ~= deadPreferred and providerAlive(entry) then
      return rawget(entry, "implementation"), resolved
    end
    deadMemo = resolved
    rawset(self, "_resolved", false)
  end

  local order = rawget(self, "_order")
  for index = 1, #order do
    local name = order[index]
    if name ~= deadPreferred and name ~= deadMemo and providerAlive(providers[name]) then
      rawset(self, "_resolved", name)
      return rawget(providers[name], "implementation"), name
    end
  end
  return nil, PROVIDER_NONE
end

---Return a fresh array of fresh `{ name, priority, alive }` rows in cascade
---order, asking every probe once. For consoles and options pages.
---@param self CompatKit.ProviderRegistry
---@return CompatKit.ProviderRow[]
local function registryList(self)
  validateRegistry(self, "CompatKit.ProviderRegistry:List", 3)
  local providers = rawget(self, "_providers")
  local order = rawget(self, "_order")
  local rows = {}
  for index = 1, #order do
    local name = order[index]
    local entry = providers[name]
    rows[index] = {
      name = name,
      priority = rawget(entry, "priority"),
      alive = providerAlive(entry),
    }
  end
  return rows
end

---Return the provider registry of `kind`, the same object on every call.
---Raises at the `maxProviderKinds` limit.
---@param self CompatKit
---@param kind string
---@return CompatKit.ProviderRegistry registry
local function packageProviders(self, kind)
  validateFacade(self, "CompatKit:Providers", 3)
  validateName(kind, "CompatKit:Providers kind", 3)

  local registry = providerRegistries[kind]
  if registry ~= nil then
    return registry
  end
  local kindCount = rawget(state, "providerKindCount")
  local maxKinds = rawget(sharedLimits, "maxProviderKinds")
  if maxKinds ~= UNBOUNDED and kindCount >= maxKinds then
    error("CompatKit:Providers refuses more than " .. maxKinds .. " kinds", 2)
  end

  registry = setmetatable({
    _kind = kind,
    _providers = {},
    _order = {},
    _count = 0,
    _resolved = false,
  }, REGISTRY_METATABLE)
  providerRegistries[kind] = registry
  rawset(state, "providerKindCount", kindCount + 1)
  return registry
end

-- Limits ---------------------------------------------------------------------

---Refuse one `SetLimits` value: a positive integer or the sentinel.
---@param name string a recognised limit name
---@param value any
---@param level integer
local function validateLimitValue(name, value, level)
  local label = "CompatKit:SetLimits limits." .. name
  if isSecret(value) then
    error(label .. " must not be a secret value", level)
  end
  if value ~= UNBOUNDED and not isPositiveInteger(value) then
    error(label .. " must be a positive integer or CompatKit.UNBOUNDED", level)
  end
end

---Refuse a `SetLimits` argument before any limit changes, so a call with one
---bad entry leaves every limit as it was.
---@param limits any
---@param level integer
local function validateLimitUpdate(limits, level)
  if type(limits) ~= "table" then
    error("CompatKit:SetLimits limits must be a table", level)
  end
  for key, value in next, limits do
    if isSecret(key) then
      error("CompatKit:SetLimits limits must not have a secret key", level)
    end
    if type(key) ~= "string" or LIMIT_NAME_SET[key] ~= true then
      error("CompatKit:SetLimits limits." .. tostring(key) .. " is not a recognised limit", level)
    end
    validateLimitValue(key, value, level + 1)
  end
end

---Change any subset of the shared limits. Affects every consumer.
---
---Lowering a limit below what exists removes nothing: further registrations
---are refused with `"full"`, further kinds raise, until the count is under
---the limit again.
---@param self CompatKit
---@param limits CompatKit.Limits
local function packageSetLimits(self, limits)
  validateFacade(self, "CompatKit:SetLimits", 3)
  validateLimitUpdate(limits, 3)
  for index = 1, #LIMIT_NAMES do
    local name = LIMIT_NAMES[index]
    local value = rawget(limits, name)
    if type(value) ~= "nil" then
      rawset(sharedLimits, name, value)
    end
  end
end

---Return a fresh copy of the shared limits. Allocates one table per call.
---@param self CompatKit
---@return CompatKit.Limits
local function packageGetLimits(self)
  validateFacade(self, "CompatKit:GetLimits", 3)
  return {
    maxShims = rawget(sharedLimits, "maxShims"),
    maxProviders = rawget(sharedLimits, "maxProviders"),
    maxProviderKinds = rawget(sharedLimits, "maxProviderKinds"),
  }
end

-- Catalogue ------------------------------------------------------------------

---Build the read-only catalogue from `CATALOGUE_ROWS`: a view over an array
---of row views, each row's `flavours` a view with its own `flavourCount`.
---@return table catalogue
---@return integer count
local function buildCatalogue()
  local rows = {}
  for index = 1, #CATALOGUE_ROWS do
    local row = CATALOGUE_ROWS[index]
    local label = "CompatKit.CATALOGUE[" .. index .. "]"
    rows[index] = newReadOnlyView({
      subsystem = row.subsystem,
      reason = row.reason,
      replacement = row.replacement,
      replacementApi = row.replacementApi,
      flavours = newReadOnlyView(row.flavours, label .. ".flavours"),
      flavourCount = #row.flavours,
    }, label)
  end
  return newReadOnlyView(rows, "CompatKit.CATALOGUE"), #rows
end

local catalogue, catalogueCount = buildCatalogue()

-- Commit ---------------------------------------------------------------------

rawset(RegistryPrototype, "Register", registryRegister)
rawset(RegistryPrototype, "Unregister", registryUnregister)
rawset(RegistryPrototype, "Resolve", registryResolve)
rawset(RegistryPrototype, "List", registryList)
rawset(REGISTRY_METATABLE, "__index", RegistryPrototype)
-- `__metatable` hides the prototype and is what `validateRegistry` recognises.
rawset(REGISTRY_METATABLE, "__metatable", REGISTRY_TAG)

rawset(CompatKit, "API", API_GENERATION)
rawset(CompatKit, "REVISION", IMPLEMENTATION_REVISION)
rawset(CompatKit, "UNBOUNDED", UNBOUNDED)
rawset(CompatKit, "CATALOGUE", catalogue)
rawset(CompatKit, "CATALOGUE_COUNT", catalogueCount)
rawset(CompatKit, "Shim", packageShim)
rawset(CompatKit, "SkipShim", packageSkipShim)
rawset(CompatKit, "GetShims", packageGetShims)
rawset(CompatKit, "Apply", packageApply)
rawset(CompatKit, "Providers", packageProviders)
rawset(CompatKit, "SetLimits", packageSetLimits)
rawset(CompatKit, "GetLimits", packageGetLimits)

rawset(state, "runtimeRevision", IMPLEMENTATION_REVISION)

if not validatePublicSurface(CompatKit) or not validateCurrentState(CompatKit) then
  error("MoltenCodes CompatKit package state is corrupted or incomplete", 2)
end
for index = 1, #REGISTRY_METHODS do
  if type(rawget(RegistryPrototype, REGISTRY_METHODS[index])) ~= "function" then
    error("MoltenCodes CompatKit package state is corrupted or incomplete", 2)
  end
end

return CompatKit
