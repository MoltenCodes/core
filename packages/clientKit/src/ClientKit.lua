-- MoltenCodes ClientKit
--
-- One place that answers "which client is this and what can it do": the client
-- flavour, the build and interface number, a fixed table of capability flags,
-- probes for secret values, restricted frames and event names, and shims for
-- the few host calls whose name or shape differs between flavours.
--
-- Everything is read from the host once, at bootstrap, into shared package
-- state. After that every probe is a table read and every shim adds one call.
-- An in-place upgrade re-reads the host into the same tables.
--
-- Capabilities are probed, never inferred from the flavour. A flag is `true`
-- only when the host actually exposes the facility, so a client ClientKit has
-- never heard of still answers correctly, and an absent `WOW_PROJECT_ID` can
-- never turn every flag on. See docs/API.md.
--
-- Contents
-- --------
--   Constants ............. identity, flavour map, capability names
--   Public types .......... LuaCATS declarations for the published surface
--   Dependencies .......... Registry
--   Bootstrap ............. surface/state validation, registration, state
--   Host probing .......... flavour, build, capabilities, bound host functions
--   Validation helpers .... argument checks that report at the caller
--   Identity .............. GetFlavor, GetBuild, GetInterfaceNumber, IsAtLeast
--   Capabilities .......... Has
--   Taint probes .......... IsSecret, CanAccessFrame, IsEventValid
--   Shims ................. GetAddOnMetadata, IsAddOnLoaded, GetSpellInfo, GetItemInfo
--   Commit ................ facade assignment and self-check

-- Constants ------------------------------------------------------------------

local PACKAGE_NAME = "clientKit"
local API_GENERATION = 1
local IMPLEMENTATION_REVISION = 1
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

-- Dependencies --------------------------------------------------------------

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

---Whether `currentState` has the shape this revision's schema requires.
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
    then
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

if ClientKit == nil then
    -- Equal or newer compatible revision already owns the shared package table.
    return selected
end

local state = rawget(ClientKit, "_state")

if previousRevision == nil then
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
        capabilities = {},
        -- The host functions the probes and shims call, or `false` when the
        -- host does not provide them.
        host = {},
    }
    rawset(ClientKit, "_state", state)
elseif type(state) ~= "table" or type(rawget(state, "capabilities")) ~= "table" then
    error("MoltenCodes ClientKit package state is corrupted or incomplete", 2)
end

local capabilities = rawget(state, "capabilities")
local host = rawget(state, "host")
if type(host) ~= "table" then
    host = {}
    rawset(state, "host", host)
end

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

---Bind the host functions the probes and shims call. The modern `C_*` form is
---preferred; the legacy global is kept only as the fallback for a client that
---lacks it.
local function bindHostFunctions()
    rawset(host, "isSecretValue", readGlobalFunction("issecretvalue"))
    rawset(host, "isEventValid", readNamespaceFunction("C_EventUtils", "IsEventValid"))

    rawset(
        host,
        "getAddOnMetadata",
        readNamespaceFunction("C_AddOns", "GetAddOnMetadata")
            or readGlobalFunction("GetAddOnMetadata")
    )
    rawset(
        host,
        "isAddOnLoaded",
        readNamespaceFunction("C_AddOns", "IsAddOnLoaded") or readGlobalFunction("IsAddOnLoaded")
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
probeCapabilities()

-- Validation helpers ----------------------------------------------------------
--
-- Argument validation raises with an explicit stack level so the reported
-- position is the line that called the public method. `level` is the value
-- `error` needs inside the function that receives it.

---Describe a caller-supplied value for an error message without formatting a
---secret into it.
---@param value any
---@return string
local function describeValue(value)
    local isSecretValue = rawget(host, "isSecretValue")
    if isSecretValue and isSecretValue(value) then
        return SECRET_PLACEHOLDER
    end
    if type(value) == "string" then
        return string.format("%q", value)
    end
    return tostring(value)
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
---@param _ ClientKit
---@param interfaceNumber number
---@return boolean
local function packageIsAtLeast(_, interfaceNumber)
    if type(interfaceNumber) ~= "number" or interfaceNumber ~= interfaceNumber then
        error("ClientKit:IsAtLeast interfaceNumber must be a number", 2)
    end
    return rawget(state, "interfaceNumber") >= interfaceNumber
end

-- Capabilities -------------------------------------------------------------------

---Whether the host exposes `capability`.
---
---An unknown name raises at the caller instead of answering `false`, so a typo
---cannot silently disable a feature.
---@param _ ClientKit
---@param capability ClientKit.Capability
---@return boolean
local function packageHas(_, capability)
    validateString(capability, "ClientKit:Has", "capability", 3)
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
    local isSecretValue = rawget(host, "isSecretValue")
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
---expansionID, setID, isCraftingReagent`. Nothing is returned while the item is
---not in the client's cache; the client then requests it and fires
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

-- Commit ----------------------------------------------------------------------

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

if not validatePublicSurface(ClientKit) or not validateCurrentState(ClientKit) then
    error("MoltenCodes ClientKit package state is corrupted or incomplete", 2)
end

return ClientKit
