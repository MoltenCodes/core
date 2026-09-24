-- MoltenCodes BrokerKit
--
-- Data objects for display addons, compatible with the LibDataBroker-1.1
-- contract every display addon consumes (Titan Panel, Bazooka, ChocolateBar):
-- an addon creates a named object, writes `text`, `icon`, `OnClick` and the
-- other attributes as plain fields, and every display that shows it reads them
-- as plain fields and learns about changes through a signal. BrokerKit adds
-- what LibDataBroker lacks: attribute types checked at the caller's line,
-- change notification per object and per attribute through SignalKit, sorted
-- enumeration, and bounded retention.
--
-- When LibDataBroker-1.1 is loaded, BrokerKit can expose its objects into it
-- (existing display addons see them) and adopt its objects read-only (an addon
-- written against BrokerKit sees theirs). Both go through LibStub, found at
-- call time with `rawget(_G, "LibStub")`; neither is required.
--
-- BrokerKit requires Registry API 2 and SignalKit API 1. It reads two optional
-- host facilities at call time: `issecretvalue` (without it nothing is secret)
-- and `LibStub`.
--
-- Contents
-- --------
--   Constants ............. identity, limits, attributes, LibDataBroker names
--   Public types .......... LuaCATS declarations for the published surface
--   Dependencies .......... Registry, SignalKit, host readers
--   Validation ............ public-surface and shared-state predicates
--   Bootstrap ............. Registry registration and inherited state
--   Host facilities ....... secret values
--   Argument checks ....... names, attribute names and values, limits
--   Objects ............... proxies, records, the sorted name cache
--   Attributes ............ the one write path every origin shares
--   LibDataBroker ......... finding it, exposing into it, adopting from it
--   Object methods ........ Set, Get, OnChange
--   Package public API .... the facade published through Registry
--   Commit ................ prototype/facade assignment, self-check
--
-- Layout and invariants are described in `docs/INTERNALS.md`.

-- Constants ------------------------------------------------------------------

local PACKAGE_NAME = "brokerKit"
local API_GENERATION = 1
local IMPLEMENTATION_REVISION = 2
local REQUIRED_REGISTRY_API = 2
local REQUIRED_SIGNALKIT_API = 1
local STATE_SCHEMA = 1

-- Every object record carries the layout it was built with, so a later
-- revision that changes the layout can upgrade old records instead of guessing.
local RECORD_SCHEMA = 1

-- The default of the `maxObjects` limit: the most data objects the session
-- holds, adopted ones included. An object is one addon's panel entry, so a
-- session with a few dozen is large; this only stops a loop that invents names.
local MAX_OBJECTS = 256

-- The default of the `maxAttributes` limit: the most attributes one object
-- holds. LibDataBroker names fifteen; the rest is room for custom ones.
local MAX_ATTRIBUTES = 32

-- The limits `SetLimits` accepts, in the order `GetLimits` reports them.
local LIMIT_NAMES = { "maxObjects", "maxAttributes" }
local LIMIT_NAME_SET = { maxObjects = true, maxAttributes = true }

-- The two object types LibDataBroker's data specification names. A display
-- addon shows a data source's text and a launcher's icon; nothing else is
-- defined, so nothing else is accepted for a MoltenCodes object.
local TYPE_DATA_SOURCE = "data source"
local TYPE_LAUNCHER = "launcher"

-- The kinds of value a known attribute accepts, and the message for each.
local KIND_OBJECT_TYPE = "objectType"
local KIND_STRING = "string"
local KIND_STRING_OR_NUMBER = "stringOrNumber"
local KIND_NUMBER = "number"
local KIND_TABLE = "table"
local KIND_FUNCTION = "function"
local KIND_MESSAGES = {
    [KIND_OBJECT_TYPE] = 'must be "data source" or "launcher"',
    [KIND_STRING] = "must be a string",
    [KIND_STRING_OR_NUMBER] = "must be a string or a number",
    [KIND_NUMBER] = "must be a number",
    [KIND_TABLE] = "must be a table",
    [KIND_FUNCTION] = "must be a function",
}

-- The attributes LibDataBroker's data specification names, with the kind of
-- value each accepts. `icon` and `value` accept a number as well as a string:
-- an icon is a path or a FileDataID, and displays show `value` through
-- `tostring` next to `suffix`. Any other attribute is a custom one and accepts
-- any value. Only `type` cannot be cleared, because every display reads it.
local KNOWN_ATTRIBUTES = {
    type = KIND_OBJECT_TYPE,
    text = KIND_STRING,
    label = KIND_STRING,
    icon = KIND_STRING_OR_NUMBER,
    value = KIND_STRING_OR_NUMBER,
    suffix = KIND_STRING,
    tocname = KIND_STRING,
    iconCoords = KIND_TABLE,
    iconR = KIND_NUMBER,
    iconG = KIND_NUMBER,
    iconB = KIND_NUMBER,
    OnClick = KIND_FUNCTION,
    OnEnter = KIND_FUNCTION,
    OnLeave = KIND_FUNCTION,
    OnTooltipShow = KIND_FUNCTION,
}

-- Names a field write can never take: the object's identity and its methods.
-- `name` is read as a plain field and the three methods are found through the
-- same lookup chain, so an attribute of that name would shadow them.
local RESERVED_ATTRIBUTES = { name = true, Set = true, Get = true, OnChange = true }

-- What the shared write path reports.
local STATUS_CHANGED = "changed"
local STATUS_UNCHANGED = "unchanged"
local STATUS_FULL = "full"

-- LibDataBroker-1.1: its LibStub major and the two events BrokerKit follows.
-- The per-name and per-attribute events LibDataBroker also fires carry the
-- same payload, so the general ones are enough.
local LIBDATABROKER_MAJOR = "LibDataBroker-1.1"
local LIBDATABROKER_CREATED = "LibDataBroker_DataObjectCreated"
local LIBDATABROKER_CHANGED = "LibDataBroker_AttributeChanged"

-- The `__metatable` of every object proxy. It hides the proxy's metatable and
-- is how a receiver is recognised.
local OBJECT_METATABLE_TAG = "BrokerKit.Object"

local FACADE_METHODS = {
    "New",
    "Get",
    "Objects",
    "Iterate",
    "OnObjectAdded",
    "IsForeign",
    "ExposeToLibDataBroker",
    "AdoptFromLibDataBroker",
    "SetLimits",
    "GetLimits",
}
local OBJECT_METHODS = { "Set", "Get", "OnChange" }

local tableSort = table.sort

-- Public types ---------------------------------------------------------------

---One of the two object types LibDataBroker displays understand.
---@alias BrokerKit.ObjectType "data source"|"launcher"

---The attributes of a new object. Every field is optional; `type` defaults to
---`"data source"`. Any other field is a custom attribute and may hold any value.
---@class BrokerKit.Definition
---@field type BrokerKit.ObjectType?
---@field text string? The text a data source shows.
---@field label string? A short label shown before `text`.
---@field icon (string|integer)? A texture path or a FileDataID.
---@field value (string|number)? A value shown with `suffix`.
---@field suffix string? The unit of `value`.
---@field tocname string? The addon this object belongs to.
---@field iconCoords number[]? Texture coordinates of `icon`.
---@field iconR number? Icon vertex colour, red.
---@field iconG number? Icon vertex colour, green.
---@field iconB number? Icon vertex colour, blue.
---@field OnClick fun(frame: table, button: string)? Called by a display when the entry is clicked.
---@field OnEnter fun(frame: table)? Called by a display when the cursor enters the entry.
---@field OnLeave fun(frame: table)? Called by a display when the cursor leaves the entry.
---@field OnTooltipShow fun(tooltip: table)? Called by a display to fill a tooltip.
---@field [string] any

---Called after an attribute changed, with the object, the attribute, the new
---value and the previous one.
---@alias BrokerKit.ChangeListener fun(object: BrokerKit.Object, attribute: string, value: any, previous: any)

---Called after an object was created or adopted.
---@alias BrokerKit.AddedListener fun(object: BrokerKit.Object)

---A data object. Attributes are plain fields: reading one is a field read and
---writing one fires the object's change signals, exactly as with a
---LibDataBroker data object. `Set` and `Get` are the explicit form.
---@class BrokerKit.Object : BrokerKit.Definition
---@field name string The object's name; read-only.
---@field type BrokerKit.ObjectType
---@field Set fun(self: BrokerKit.Object, attribute: string, value: any)
---@field Get fun(self: BrokerKit.Object, attribute: string): any
---@field OnChange fun(self: BrokerKit.Object, attribute: string|BrokerKit.ChangeListener, callback: BrokerKit.ChangeListener?): SignalKit.Connection

---Why a bridge call did nothing.
---@alias BrokerKit.BridgeReason "absent"|"already"

---The shared limits. `SetLimits` accepts any subset; `GetLimits` returns all.
---@class BrokerKit.Limits
---@field maxObjects integer|table Most objects the session holds, adopted ones included: a positive integer or `BrokerKit.UNBOUNDED`; default `256`.
---@field maxAttributes integer|table Most attributes one object holds: a positive integer or `BrokerKit.UNBOUNDED`; default `32`.

---The BrokerKit package facade published through Registry.
---@class BrokerKit
---@field API integer Public API generation.
---@field REVISION integer Compatible implementation revision.
---@field MAX_OBJECTS integer Default of the `maxObjects` limit (`256`).
---@field MAX_ATTRIBUTES integer Default of the `maxAttributes` limit (`32`).
---@field UNBOUNDED table Sentinel that lifts a limit; the same table for every revision.
---@field New fun(self: BrokerKit, name: string, definition: BrokerKit.Definition?): BrokerKit.Object
---@field Get fun(self: BrokerKit, name: string): BrokerKit.Object?
---@field Objects fun(self: BrokerKit): string[]
---@field Iterate fun(self: BrokerKit): (fun(cache: table, previous: string?): string?, BrokerKit.Object?), table, nil
---@field OnObjectAdded fun(self: BrokerKit, callback: BrokerKit.AddedListener): SignalKit.Connection
---@field IsForeign fun(self: BrokerKit, object: BrokerKit.Object): boolean
---@field ExposeToLibDataBroker fun(self: BrokerKit): boolean, BrokerKit.BridgeReason?
---@field AdoptFromLibDataBroker fun(self: BrokerKit): boolean, BrokerKit.BridgeReason?
---@field SetLimits fun(self: BrokerKit, limits: BrokerKit.Limits)
---@field GetLimits fun(self: BrokerKit): BrokerKit.Limits

---The subset of LibDataBroker-1.1 BrokerKit calls. Private.
---@class BrokerKit.LibDataBroker
---@field NewDataObject fun(self: table, name: string, dataobj: table?): table?
---@field DataObjectIterator fun(self: table): fun(t: table, k: any): any, any
---@field GetDataObjectByName fun(self: table, name: string): table?
---@field pairs (fun(self: table, dataobj: table): fun(t: table, k: any): any, any)?
---@field RegisterCallback (fun(owner: table, eventName: string, callback: function))?

---One build of the sorted enumeration. Private.
---@class BrokerKit.SortedCache
---@field names string[] every object name sorted with `<`
---@field positions table<string, integer> each name's index in `names`

---Everything BrokerKit keeps per object. Private.
---@class BrokerKit.Record
---@field schema integer
---@field name string
---@field proxy BrokerKit.Object the table consumers hold
---@field attributes table the attribute storage the proxy reads through
---@field foreign boolean adopted from LibDataBroker, so read-only
---@field source table|false the LibDataBroker data object a foreign record wraps
---@field mirror table|false the LibDataBroker data object an exposed record writes into
---@field attributeCount integer attributes currently holding a value
---@field anySignal table|false the signal `OnChange(callback)` connects to
---@field attributeSignals table<string, table> the signals `OnChange(attribute, callback)` connects to

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
    error("MoltenCodes BrokerKit requires Registry API 2 to be loaded first", 2)
end

local bootstrapPackage = rawget(Registry, "Bootstrap")
local getPackage = rawget(Registry, "Get")
if type(bootstrapPackage) ~= "function" or type(getPackage) ~= "function" then
    error("MoltenCodes BrokerKit requires a valid Registry API 2 facade", 2)
end

-- SignalKit carries the change signals and the object-added signal.
local SignalKit = getPackage(Registry, "signalKit", REQUIRED_SIGNALKIT_API)
if
    type(SignalKit) ~= "table"
    or rawget(SignalKit, "API") ~= REQUIRED_SIGNALKIT_API
    or type(rawget(SignalKit, "New")) ~= "function"
then
    error("MoltenCodes BrokerKit requires SignalKit API 1 to be loaded first", 2)
end

---Read a host global without triggering a metatable, or `nil`.
---@param name string
---@return any
local function readGlobal(name)
    -- Host APIs and LibStub are reachable only through the global table.
    -- selene: allow(global_usage)
    return rawget(_G, name)
end

-- Validation -----------------------------------------------------------------

---Whether `implementation` exposes the complete BrokerKit API 1 surface.
---@param implementation any shared package table handed back by Registry
---@return boolean
local function validatePublicSurface(implementation)
    if
        type(implementation) ~= "table"
        or rawget(implementation, "API") ~= API_GENERATION
        or type(rawget(implementation, "REVISION")) ~= "number"
        or type(rawget(implementation, "UNBOUNDED")) ~= "table"
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
---comparison and both infinities are refused before the integer test.
---@param value any
---@return boolean
local function isPositiveInteger(value)
    return type(value) == "number" and value >= 1 and value ~= math.huge and value % 1 == 0
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
    local libDataBroker = rawget(currentState, "libDataBroker")
    local unbounded = rawget(currentState, "unbounded")
    return type(rawget(currentState, "runtimeRevision")) == "number"
        and type(unbounded) == "table"
        and validateLimitsTable(rawget(currentState, "limits"), unbounded)
        and type(rawget(currentState, "objects")) == "table"
        and type(rawget(currentState, "records")) == "table"
        and type(rawget(currentState, "objectCount")) == "number"
        and type(rawget(currentState, "version")) == "number"
        and type(rawget(currentState, "addedSignal")) == "table"
        and type(rawget(currentState, "objectPrototype")) == "table"
        and type(rawget(currentState, "prototypeMetatable")) == "table"
        and type(rawget(currentState, "objectNewIndex")) == "function"
        and type(rawget(currentState, "dispatch")) == "table"
        and type(libDataBroker) == "table"
        and type(rawget(libDataBroker, "callbackOwner")) == "table"
        and type(rawget(libDataBroker, "onCreated")) == "function"
        and type(rawget(libDataBroker, "onAttributeChanged")) == "function"
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
-- and register this one. What stays here is what only BrokerKit can answer.
local BrokerKit, previousRevision, selected = bootstrapPackage(Registry, {
    package = PACKAGE_NAME,
    api = API_GENERATION,
    revision = IMPLEMENTATION_REVISION,
    label = "MoltenCodes BrokerKit",
    validatePublicSurface = validatePublicSurface,
    validateState = validateCurrentState,
})

if BrokerKit == nil then
    -- An equal or newer compatible revision already owns the shared package table.
    return selected
end

local state = rawget(BrokerKit, "_state")

if previousRevision == nil then
    if state ~= nil then
        error("MoltenCodes BrokerKit package state is corrupted or incomplete", 2)
    end

    -- Functions every loading revision rewrites. The closures below are handed
    -- to object metatables and to LibDataBroker and cannot be replaced, so they
    -- look their behaviour up here at every call.
    local dispatch = {}
    local objectPrototype = {}

    state = {
        schema = STATE_SCHEMA,
        runtimeRevision = 0,
        -- The sentinel `SetLimits` accepts to lift a limit. It lives here, not
        -- in a file local, so every embedded revision hands out the same table.
        unbounded = {},
        -- The shared limits, kept across upgrades like everything else here.
        limits = {
            maxObjects = MAX_OBJECTS,
            maxAttributes = MAX_ATTRIBUTES,
        },
        -- Object name to its record, and proxy to its record. Objects live for
        -- the session: a display addon keeps references to them.
        objects = {},
        records = {},
        objectCount = 0,
        -- Bumped by every added object; the sorted name cache compares against it.
        version = 0,
        -- The sorted enumeration: `{ names, positions }` built together, or
        -- `false`. `Iterate` hands this table out as its state.
        sortedCache = false,
        sortedVersion = -1,
        -- The signal `OnObjectAdded` connects to.
        addedSignal = SignalKit:New(),
        -- The methods every object reaches through its lookup chain, and the
        -- metatable that chains an object's identity table to them. The
        -- prototype's functions are rewritten by every loading revision.
        objectPrototype = objectPrototype,
        prototypeMetatable = { __index = objectPrototype },
        -- The `__newindex` of every proxy. One stable closure, so an upgrade
        -- changes what a field write does without touching existing objects.
        objectNewIndex = function(proxy, key, value)
            dispatch.assignFromProxy(proxy, key, value)
        end,
        dispatch = dispatch,
        libDataBroker = {
            -- The library exposed into, or `false` before `ExposeToLibDataBroker`.
            exposeTarget = false,
            -- The library adopted from, or `false` before `AdoptFromLibDataBroker`.
            adoptSource = false,
            -- The library the callbacks were registered with, or `false`.
            subscribed = false,
            -- The table CallbackHandler files our registrations under. It must
            -- not be the library itself, which CallbackHandler refuses.
            callbackOwner = {},
            onCreated = function(_, name, dataObject)
                dispatch.onDataObjectCreated(name, dataObject)
            end,
            onAttributeChanged = function(_, name, attribute, value, dataObject)
                dispatch.onAttributeChanged(name, attribute, value, dataObject)
            end,
        },
    }
    rawset(BrokerKit, "_state", state)
elseif not validateStateBase(state) then
    error("MoltenCodes BrokerKit package state is corrupted or incomplete", 2)
end

---@type table<string, BrokerKit.Record>
local objects = rawget(state, "objects")
---@type table<table, BrokerKit.Record>
local records = rawget(state, "records")
local dispatch = rawget(state, "dispatch")
local libDataBroker = rawget(state, "libDataBroker")
local ObjectPrototype = rawget(state, "objectPrototype")
local PROTOTYPE_METATABLE = rawget(state, "prototypeMetatable")
local objectNewIndex = rawget(state, "objectNewIndex")
local addedSignal = rawget(state, "addedSignal")
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

-- Argument checks ------------------------------------------------------------
--
-- Argument validation raises with an explicit stack level so the reported
-- position is the line that called the public method, never a line inside
-- BrokerKit. `level` is always the value `error` needs *inside the function
-- that receives it*, so every further hop towards `error` adds exactly one.
-- Secrets are checked first, because comparing one raises, and `nil` is
-- tested with `type` for the same reason.

---@param receiver any the table the method was called on
---@param label string public method name, used in the argument error
---@param level integer stack level the failure is reported at
local function validateFacade(receiver, label, level)
    -- `type` first: a secret receiver is never a table, and comparing it raises.
    if type(receiver) ~= "table" or receiver ~= BrokerKit then
        error(label .. " must be called on the BrokerKit facade; use " .. label .. "(...)", level)
    end
end

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

---Refuse an attribute name that is secret, not a non-empty string, or
---reserved for the object's identity and methods.
---@param key any
---@param label string public method name, used in the argument error
---@param level integer stack level the failure is reported at
local function validateAttributeName(key, label, level)
    if isSecret(key) then
        error(label .. " attribute name must not be a secret value", level)
    end
    if type(key) ~= "string" or key == "" then
        error(label .. " attribute name must be a non-empty string", level)
    end
    if RESERVED_ATTRIBUTES[key] == true then
        error(label .. ' attribute "' .. key .. '" is reserved', level)
    end
end

---Whether `value` is acceptable for an attribute of `kind`. `nil` clears any
---attribute except `type`.
---@param kind string one of the `KIND_*` values
---@param value any a non-secret value
---@return boolean
local function matchesKind(kind, value)
    local valueType = type(value)
    if kind == KIND_OBJECT_TYPE then
        return value == TYPE_DATA_SOURCE or value == TYPE_LAUNCHER
    end
    if valueType == "nil" then
        return true
    end
    if kind == KIND_STRING_OR_NUMBER then
        return valueType == "string" or valueType == "number"
    end
    return valueType == kind
end

---Refuse a value a known attribute cannot hold. A known attribute never holds
---a secret, because displays format it and LibDataBroker compares it; a
---custom attribute holds anything, secrets included.
---@param key string a validated attribute name
---@param value any
---@param label string public method name, used in the argument error
---@param level integer stack level the failure is reported at
---@return boolean secret whether `value` is a secret value
local function validateAttributeValue(key, value, label, level)
    local kind = KNOWN_ATTRIBUTES[key]
    if kind == nil then
        return isSecret(value)
    end
    if isSecret(value) then
        error(label .. ' attribute "' .. key .. '" must not be a secret value', level)
    end
    if not matchesKind(kind, value) then
        error(label .. ' attribute "' .. key .. '" ' .. KIND_MESSAGES[kind], level)
    end
    return false
end

---Refuse one `SetLimits` value: a positive integer or `UNBOUNDED`.
---@param name string a recognised limit name
---@param value any
---@param level integer stack level the failure is reported at
local function validateLimitValue(name, value, level)
    local label = "BrokerKit:SetLimits limits." .. name
    if isSecret(value) then
        error(label .. " must not be a secret value", level)
    end
    if value ~= UNBOUNDED and not isPositiveInteger(value) then
        error(label .. " must be a positive integer or BrokerKit.UNBOUNDED", level)
    end
end

---Refuse a `SetLimits` argument before any limit changes, so a call with one
---bad entry leaves every limit as it was.
---@param limits any
---@param level integer stack level the failure is reported at
local function validateLimitUpdate(limits, level)
    if type(limits) ~= "table" then
        error("BrokerKit:SetLimits limits must be a table", level)
    end
    for key, value in next, limits do
        if isSecret(key) then
            error("BrokerKit:SetLimits limits must not have a secret key", level)
        end
        if type(key) ~= "string" or LIMIT_NAME_SET[key] ~= true then
            error(
                "BrokerKit:SetLimits limits." .. tostring(key) .. " is not a recognised limit",
                level
            )
        end
        validateLimitValue(key, value, level + 1)
    end
end

-- Objects --------------------------------------------------------------------
--
-- A consumer holds a proxy: an empty table whose metatable reads through the
-- attribute table and writes through `objectNewIndex`. The attribute table
-- reads through a per-object identity table (`name`) which reads through the
-- shared prototype (`Set`, `Get`, `OnChange`). Reads are table lookups with
-- no function call; every write goes through one path that fires the signals.

---Whether one more object may be created under the shared limit.
---@return boolean
local function underObjectLimit()
    local maxObjects = rawget(sharedLimits, "maxObjects")
    return maxObjects == UNBOUNDED or rawget(state, "objectCount") < maxObjects
end

---Create the record and proxy of a new object and register both. The caller
---has checked the name, the limit and, for a foreign object, the source.
---@param name string
---@param foreign boolean
---@param source table|false
---@return BrokerKit.Record
local function createRecord(name, foreign, source)
    local identity = setmetatable({ name = name }, PROTOTYPE_METATABLE)
    local attributes = setmetatable({}, { __index = identity })
    local proxy = setmetatable({}, {
        __index = attributes,
        __newindex = objectNewIndex,
        __metatable = OBJECT_METATABLE_TAG,
    })
    local record = {
        schema = RECORD_SCHEMA,
        name = name,
        proxy = proxy,
        attributes = attributes,
        foreign = foreign,
        source = source,
        mirror = false,
        attributeCount = 0,
        anySignal = false,
        attributeSignals = {},
    }
    objects[name] = record
    records[proxy] = record
    rawset(state, "objectCount", rawget(state, "objectCount") + 1)
    rawset(state, "version", rawget(state, "version") + 1)
    return record
end

---The record of a proxy, or `nil` for anything that is not a broker object.
---`type` first: indexing `records` with a secret would raise.
---@param proxy any
---@return BrokerKit.Record|nil
local function recordOf(proxy)
    if type(proxy) ~= "table" then
        return nil
    end
    return records[proxy]
end

---The sorted enumeration, from the cache when it is current. A rebuild makes
---a new `names` array and, beside it, the `positions` of those names, so a
---walk over one array continues from positions that belong to that array
---even after a later rebuild. Neither table is modified once built.
---@return BrokerKit.SortedCache
local function currentSortedCache()
    local cache = rawget(state, "sortedCache")
    if cache == false or rawget(state, "sortedVersion") ~= rawget(state, "version") then
        local names = {}
        local positions = {}
        local count = 0
        for name in next, objects do
            count = count + 1
            names[count] = name
        end
        tableSort(names)
        for index = 1, count do
            positions[names[index]] = index
        end
        cache = { names = names, positions = positions }
        rawset(state, "sortedCache", cache)
        rawset(state, "sortedVersion", rawget(state, "version"))
    end
    return cache
end

---The iterator `Iterate` returns: the name after `previous` in the cache the
---walk started with, and its object. Allocates nothing.
---@param cache BrokerKit.SortedCache
---@param previous string?
---@return string? name
---@return BrokerKit.Object? object
local function iterateNext(cache, previous)
    local index = 1
    if type(previous) ~= "nil" then
        index = cache.positions[previous] + 1
    end
    local name = cache.names[index]
    if name == nil then
        return nil
    end
    return name, objects[name].proxy
end

-- Attributes -----------------------------------------------------------------
--
-- `Set`, a field write, `New` and adoption all store attributes through
-- `writeAttribute`, so the same-value check and the attribute limit hold
-- whatever the origin. What happens after a change (the LibDataBroker mirror,
-- the signals) is the caller's, because it differs by origin.

---Store `value` as `key`, or say why not. A write of the same value is one
---comparison and changes nothing; a secret on either side is never compared,
---so it always counts as a change.
---@param record BrokerKit.Record
---@param key string a validated attribute name
---@param value any
---@param valueIsSecret boolean
---@return string status one of the `STATUS_*` values
local function writeAttribute(record, key, value, valueIsSecret)
    local attributes = record.attributes
    local previous = rawget(attributes, key)
    local hadValue = type(previous) ~= "nil"
    local hasValue = type(value) ~= "nil"
    if not hadValue and not hasValue then
        return STATUS_UNCHANGED
    end
    if hadValue and hasValue and not valueIsSecret and not isSecret(previous) then
        if previous == value then
            return STATUS_UNCHANGED
        end
    end
    if not hadValue then
        local maxAttributes = rawget(sharedLimits, "maxAttributes")
        if maxAttributes ~= UNBOUNDED and record.attributeCount >= maxAttributes then
            return STATUS_FULL
        end
        record.attributeCount = record.attributeCount + 1
    elseif not hasValue then
        record.attributeCount = record.attributeCount - 1
    end
    rawset(attributes, key, value)
    return STATUS_CHANGED
end

---Fire the change signals of `record` for `key`: the attribute's own list,
---then the any-attribute list. A list nobody connected to costs one test.
---@param record BrokerKit.Record
---@param key string
---@param value any
---@param previous any
local function fireChange(record, key, value, previous)
    local attributeSignal = record.attributeSignals[key]
    if attributeSignal ~= nil then
        attributeSignal:Fire(record.proxy, key, value, previous)
    end
    local anySignal = record.anySignal
    if anySignal ~= false then
        anySignal:Fire(record.proxy, key, value, previous)
    end
end

---Write one attribute of a MoltenCodes object on the owning addon's behalf:
---validate, store, mirror into LibDataBroker when exposed, fire.
---@param record BrokerKit.Record
---@param key any
---@param value any
---@param label string public method name, used in the argument errors
---@param level integer stack level the failures are reported at
local function assignAttribute(record, key, value, label, level)
    if record.foreign then
        error(
            label
                .. ' object "'
                .. record.name
                .. '" is foreign (adopted from LibDataBroker) and read-only',
            level
        )
    end
    validateAttributeName(key, label, level + 1)
    local secret = validateAttributeValue(key, value, label, level + 1)

    local previous = rawget(record.attributes, key)
    local status = writeAttribute(record, key, value, secret)
    if status == STATUS_UNCHANGED then
        return
    end
    if status == STATUS_FULL then
        error(
            label
                .. " refuses more than "
                .. rawget(sharedLimits, "maxAttributes")
                .. ' attributes on object "'
                .. record.name
                .. '"',
            level
        )
    end

    -- LibDataBroker compares the new value with the old one inside its own
    -- `__newindex`, which a secret would break, so a secret is never mirrored.
    local mirror = record.mirror
    if mirror ~= false and not secret then
        mirror[key] = value
    end
    fireChange(record, key, value, previous)
end

---The `__newindex` behaviour behind every proxy: `object.text = "..."` is
---`object:Set("text", "...")`. Called through `dispatch` from the stable
---closure in package state.
---@param proxy table
---@param key any
---@param value any
local function assignFromProxy(proxy, key, value)
    -- Levels: this function, the closure in state, the metamethod's caller.
    assignAttribute(records[proxy], key, value, "BrokerKit.Object:Set", 4)
end

-- LibDataBroker --------------------------------------------------------------

---LibDataBroker-1.1 through LibStub, or `nil` when either is not loaded.
---@return BrokerKit.LibDataBroker|nil
local function findLibDataBroker()
    local libStub = readGlobal("LibStub")
    if type(libStub) ~= "table" then
        return nil
    end
    local getLibrary = rawget(libStub, "GetLibrary")
    if type(getLibrary) ~= "function" then
        return nil
    end
    local library = getLibrary(libStub, LIBDATABROKER_MAJOR, true)
    if
        type(library) ~= "table"
        or type(rawget(library, "NewDataObject")) ~= "function"
        or type(rawget(library, "DataObjectIterator")) ~= "function"
    then
        return nil
    end
    return library
end

---Create the LibDataBroker data object of a MoltenCodes object, with every
---non-secret attribute it holds now, and remember it as the record's mirror.
---LibDataBroker fires `LibDataBroker_DataObjectCreated` from inside
---`NewDataObject`; the adoption handler then finds the name already held and
---adopts nothing. A name a foreign object holds in LibDataBroker cannot be
---taken: the object stays local and `false` is returned.
---@param record BrokerKit.Record
---@return boolean exposed
local function exposeObject(record)
    local library = libDataBroker.exposeTarget
    if library == false or record.foreign or record.mirror ~= false then
        return false
    end
    local initial = {}
    for key, value in next, record.attributes do
        if not isSecret(value) then
            initial[key] = value
        end
    end
    local created = library:NewDataObject(record.name, initial)
    if type(created) ~= "table" then
        return false
    end
    record.mirror = created
    return true
end

---Order foreign attribute names so that, when `maxAttributes` cuts the list,
---what a display needs survives: `type` first, then the known attributes,
---then custom ones; each group sorted with `<`.
---@param left string
---@param right string
---@return boolean
local function foreignAttributeBefore(left, right)
    local leftRank = left == "type" and 0 or KNOWN_ATTRIBUTES[left] ~= nil and 1 or 2
    local rightRank = right == "type" and 0 or KNOWN_ATTRIBUTES[right] ~= nil and 1 or 2
    if leftRank ~= rightRank then
        return leftRank < rightRank
    end
    return left < right
end

---Collect the attribute names of a LibDataBroker data object, in the order
---`foreignAttributeBefore` gives, through the library's `pairs`. The real
---library raises for an object nobody has written to yet, so the call is
---protected and such an object has no attributes until its first change
---arrives.
---@param library BrokerKit.LibDataBroker
---@param dataObject table
---@return string[] keys
---@return integer count
local function foreignAttributeNames(library, dataObject)
    local keys = {}
    local count = 0
    local pairsMethod = rawget(library, "pairs")
    if type(pairsMethod) ~= "function" then
        return keys, count
    end
    local ok, iterator, storage, control = pcall(pairsMethod, library, dataObject)
    if not ok or type(iterator) ~= "function" then
        return keys, count
    end
    for key in iterator, storage, control do
        if
            not isSecret(key)
            and type(key) == "string"
            and key ~= ""
            and RESERVED_ATTRIBUTES[key] ~= true
        then
            count = count + 1
            keys[count] = key
        end
    end
    tableSort(keys, foreignAttributeBefore)
    return keys, count
end

---Wrap one LibDataBroker data object as a read-only foreign object. A name
---BrokerKit already holds (a MoltenCodes object, or an earlier adoption) is
---skipped, as are secret and invalid names, and a session at `maxObjects`.
---Attributes past `maxAttributes` are left out quietly, custom ones first.
---@param library BrokerKit.LibDataBroker
---@param name any
---@param dataObject any
---@return boolean adopted
local function adoptObject(library, name, dataObject)
    if isSecret(name) or type(name) ~= "string" or name == "" or type(dataObject) ~= "table" then
        return false
    end
    if objects[name] ~= nil or not underObjectLimit() then
        return false
    end
    local record = createRecord(name, true, dataObject)
    local keys, count = foreignAttributeNames(library, dataObject)
    for index = 1, count do
        local key = keys[index]
        local value = dataObject[key]
        writeAttribute(record, key, value, isSecret(value))
    end
    addedSignal:Fire(record.proxy)
    return true
end

---Handle `LibDataBroker_DataObjectCreated(name, dataObject)`: adopt the new
---object. Called through `dispatch`, so an upgrade replaces it behind the
---callback LibDataBroker already holds.
---@param name any
---@param dataObject any
local function onDataObjectCreated(name, dataObject)
    local library = libDataBroker.adoptSource
    if library == false then
        return
    end
    adoptObject(library, name, dataObject)
end

---Handle `LibDataBroker_AttributeChanged(name, attribute, value, dataObject)`
---for a foreign object: store and fire. A change on a MoltenCodes object
---(our own mirror write coming back) is not foreign and is ignored.
---@param name any
---@param attribute any
---@param value any
---@param dataObject any
local function onAttributeChanged(name, attribute, value, dataObject)
    if libDataBroker.adoptSource == false or isSecret(name) or type(name) ~= "string" then
        return
    end
    local record = objects[name]
    -- `type` before the identity test: `dataObject` comes from LibDataBroker's
    -- callback, and a secret compared with the source would raise.
    if
        record == nil
        or not record.foreign
        or type(dataObject) ~= "table"
        or record.source ~= dataObject
    then
        return
    end
    if
        isSecret(attribute)
        or type(attribute) ~= "string"
        or attribute == ""
        or RESERVED_ATTRIBUTES[attribute] == true
    then
        return
    end
    local previous = rawget(record.attributes, attribute)
    if writeAttribute(record, attribute, value, isSecret(value)) == STATUS_CHANGED then
        fireChange(record, attribute, value, previous)
    end
end

---Register the two callbacks with LibDataBroker's CallbackHandler once.
---@param library BrokerKit.LibDataBroker
local function subscribe(library)
    if libDataBroker.subscribed == library then
        return
    end
    local registerCallback = rawget(library, "RegisterCallback")
    if type(registerCallback) ~= "function" then
        return
    end
    local owner = libDataBroker.callbackOwner
    registerCallback(owner, LIBDATABROKER_CREATED, libDataBroker.onCreated)
    registerCallback(owner, LIBDATABROKER_CHANGED, libDataBroker.onAttributeChanged)
    libDataBroker.subscribed = library
end

-- Object methods -------------------------------------------------------------

---The record behind `self`, or a receiver error at `level`.
---@param self any
---@param methodName string
---@param level integer
---@return BrokerKit.Record
local function requireRecord(self, methodName, level)
    local record = recordOf(self)
    if record == nil then
        error(
            methodName
                .. " must be called on a broker object; use object:"
                .. methodName:match("[^:]+$")
                .. "(...)",
            level
        )
    end
    return record
end

---Write `attribute`. The explicit form of `object.attribute = value`: the same
---checks, the same signals, the same cost.
---@param self BrokerKit.Object
---@param attribute string
---@param value any
local function objectSet(self, attribute, value)
    local record = requireRecord(self, "BrokerKit.Object:Set", 3)
    assignAttribute(record, attribute, value, "BrokerKit.Object:Set", 3)
end

---Read `attribute`. The explicit form of `object.attribute`, accepting exactly
---the names `Set` accepts; `name` is read as a field.
---@param self BrokerKit.Object
---@param attribute string
---@return any value
local function objectGet(self, attribute)
    local record = requireRecord(self, "BrokerKit.Object:Get", 3)
    validateAttributeName(attribute, "BrokerKit.Object:Get", 3)
    return rawget(record.attributes, attribute)
end

---Connect `callback` to changes of `attribute`, or of every attribute when
---called as `object:OnChange(callback)`. The callback receives
---`(object, attribute, value, previous)`. The connection belongs to the caller.
---@param self BrokerKit.Object
---@param attribute string|BrokerKit.ChangeListener
---@param callback BrokerKit.ChangeListener?
---@return SignalKit.Connection connection
local function objectOnChange(self, attribute, callback)
    local record = requireRecord(self, "BrokerKit.Object:OnChange", 3)
    -- `object:OnChange(callback)` and `object:OnChange(nil, callback)` are the
    -- any-attribute form.
    ---@type any
    local attributeName = attribute
    if type(callback) == "nil" and type(attribute) == "function" then
        callback = attribute --[[@as BrokerKit.ChangeListener]]
        attributeName = nil
    end
    local anyAttribute = type(attributeName) == "nil"
    if not anyAttribute then
        validateAttributeName(attributeName, "BrokerKit.Object:OnChange", 3)
    end
    if type(callback) ~= "function" then
        error("BrokerKit.Object:OnChange callback must be a function", 2)
    end

    if anyAttribute then
        local anySignal = record.anySignal
        if anySignal == false then
            anySignal = SignalKit:New()
            record.anySignal = anySignal
        end
        return anySignal:Connect(callback)
    end
    ---@cast attributeName string
    local signal = record.attributeSignals[attributeName]
    if signal == nil then
        signal = SignalKit:New()
        record.attributeSignals[attributeName] = signal
    end
    return signal:Connect(callback)
end

-- Package public API ---------------------------------------------------------

---Count the attributes a definition gives a new object, validating each, and
---raise at `level` when the object would exceed `maxAttributes`.
---@param definition table
---@param level integer stack level the failures are reported at
---@return integer count
local function validateDefinition(definition, level)
    local count = 0
    for key, value in next, definition do
        validateAttributeName(key, "BrokerKit:New", level + 1)
        validateAttributeValue(key, value, "BrokerKit:New", level + 1)
        count = count + 1
    end
    if type(rawget(definition, "type")) == "nil" then
        count = count + 1
    end
    local maxAttributes = rawget(sharedLimits, "maxAttributes")
    if maxAttributes ~= UNBOUNDED and count > maxAttributes then
        error(
            "BrokerKit:New refuses more than " .. maxAttributes .. " attributes on an object",
            level
        )
    end
    return count
end

---Create the data object `name` with the attributes of `definition`, which is
---copied, never kept. `type` defaults to `"data source"`. The object is
---exposed into LibDataBroker when exposing is on, then `OnObjectAdded` fires.
---@param self BrokerKit
---@param name string
---@param definition BrokerKit.Definition?
---@return BrokerKit.Object object
local function packageNew(self, name, definition)
    validateFacade(self, "BrokerKit:New", 3)
    validateName(name, "BrokerKit:New name", 3)
    local existing = objects[name]
    if existing ~= nil then
        if existing.foreign then
            error(
                'BrokerKit:New name "'
                    .. name
                    .. '" is already taken by a foreign LibDataBroker object',
                2
            )
        end
        error('BrokerKit:New name "' .. name .. '" is already taken', 2)
    end
    if type(definition) == "nil" then
        definition = {}
    elseif type(definition) ~= "table" then
        error("BrokerKit:New definition must be a table", 2)
    end
    local count = validateDefinition(definition, 3)
    if not underObjectLimit() then
        error(
            "BrokerKit:New refuses more than " .. rawget(sharedLimits, "maxObjects") .. " objects",
            2
        )
    end

    local record = createRecord(name, false, false)
    local attributes = record.attributes
    rawset(attributes, "type", TYPE_DATA_SOURCE)
    for key, value in next, definition do
        rawset(attributes, key, value)
    end
    record.attributeCount = count

    exposeObject(record)
    addedSignal:Fire(record.proxy)
    return record.proxy
end

---The object named `name`, MoltenCodes or foreign, or `nil`.
---@param self BrokerKit
---@param name string
---@return BrokerKit.Object? object
local function packageGet(self, name)
    validateFacade(self, "BrokerKit:Get", 3)
    validateName(name, "BrokerKit:Get name", 3)
    local record = objects[name]
    if record == nil then
        return nil
    end
    return record.proxy
end

---A fresh array of every object name sorted with `<`. Allocates one array.
---@param self BrokerKit
---@return string[] names
local function packageObjects(self)
    validateFacade(self, "BrokerKit:Objects", 3)
    local names = currentSortedCache().names
    local copy = {}
    for index = 1, #names do
        copy[index] = names[index]
    end
    return copy
end

---Iterate every object as `name, object` in sorted name order, allocating
---nothing while no object was added since the last enumeration. The walk is
---bound to the cache it started with, so every name present at the start is
---visited even when objects are added during the walk.
---@param self BrokerKit
---@return fun(cache: BrokerKit.SortedCache, previous: string?): string?, BrokerKit.Object? iterator
---@return BrokerKit.SortedCache cache
---@return nil
local function packageIterate(self)
    validateFacade(self, "BrokerKit:Iterate", 3)
    return iterateNext, currentSortedCache(), nil
end

---Connect `callback` to every object created or adopted from now on. It
---receives the object. The connection belongs to the caller.
---@param self BrokerKit
---@param callback BrokerKit.AddedListener
---@return SignalKit.Connection connection
local function packageOnObjectAdded(self, callback)
    validateFacade(self, "BrokerKit:OnObjectAdded", 3)
    if type(callback) ~= "function" then
        error("BrokerKit:OnObjectAdded callback must be a function", 2)
    end
    return addedSignal:Connect(callback)
end

---Whether `object` was adopted from LibDataBroker and is therefore read-only.
---@param self BrokerKit
---@param object BrokerKit.Object
---@return boolean
local function packageIsForeign(self, object)
    validateFacade(self, "BrokerKit:IsForeign", 3)
    local record = recordOf(object)
    if record == nil then
        error("BrokerKit:IsForeign object must be a broker object", 2)
    end
    return record.foreign
end

---Register every MoltenCodes object as a LibDataBroker data object, and keep
---doing so for objects created later; attribute changes follow.
---
---Returns `true`, or `false, "absent"` without LibStub or LibDataBroker-1.1,
---or `false, "already"` when this library is already exposed into.
---@param self BrokerKit
---@return boolean exposed
---@return BrokerKit.BridgeReason? reason
local function packageExposeToLibDataBroker(self)
    validateFacade(self, "BrokerKit:ExposeToLibDataBroker", 3)
    local library = findLibDataBroker()
    if library == nil then
        return false, "absent"
    end
    if libDataBroker.exposeTarget == library then
        return false, "already"
    end
    libDataBroker.exposeTarget = library
    -- The cached array is never modified, so re-entrant adoptions fired from
    -- LibDataBroker's callback cannot disturb this walk.
    local names = currentSortedCache().names
    for index = 1, #names do
        exposeObject(objects[names[index]])
    end
    return true
end

---Wrap every LibDataBroker data object as a read-only foreign object, in
---sorted name order, and follow objects created and attributes changed later
---through LibDataBroker's callbacks.
---
---Returns `true`, or `false, "absent"` without LibStub or LibDataBroker-1.1,
---or `false, "already"` when this library is already adopted from.
---@param self BrokerKit
---@return boolean adopted
---@return BrokerKit.BridgeReason? reason
local function packageAdoptFromLibDataBroker(self)
    validateFacade(self, "BrokerKit:AdoptFromLibDataBroker", 3)
    local library = findLibDataBroker()
    if library == nil then
        return false, "absent"
    end
    if libDataBroker.adoptSource == library then
        return false, "already"
    end
    libDataBroker.adoptSource = library
    subscribe(library)

    -- Names are collected and sorted first: the signal order is then
    -- deterministic, and a listener that creates a data object during
    -- adoption cannot disturb a traversal of the library's table.
    local names = {}
    local count = 0
    for name in library:DataObjectIterator() do
        if not isSecret(name) and type(name) == "string" then
            count = count + 1
            names[count] = name
        end
    end
    tableSort(names)
    for index = 1, count do
        local name = names[index]
        adoptObject(library, name, library:GetDataObjectByName(name))
    end
    return true
end

---Change any subset of the shared limits. Affects every consumer.
---
---The whole table is checked before anything changes. Lowering a limit below
---what already exists removes nothing: further objects and attributes are
---refused until the count is under the limit.
---@param self BrokerKit
---@param limits BrokerKit.Limits
local function packageSetLimits(self, limits)
    validateFacade(self, "BrokerKit:SetLimits", 3)
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
---@param self BrokerKit
---@return BrokerKit.Limits limits
local function packageGetLimits(self)
    validateFacade(self, "BrokerKit:GetLimits", 3)
    return {
        maxObjects = rawget(sharedLimits, "maxObjects"),
        maxAttributes = rawget(sharedLimits, "maxAttributes"),
    }
end

-- Commit ---------------------------------------------------------------------

rawset(dispatch, "assignFromProxy", assignFromProxy)
rawset(dispatch, "onDataObjectCreated", onDataObjectCreated)
rawset(dispatch, "onAttributeChanged", onAttributeChanged)

rawset(ObjectPrototype, "Set", objectSet)
rawset(ObjectPrototype, "Get", objectGet)
rawset(ObjectPrototype, "OnChange", objectOnChange)

rawset(BrokerKit, "API", API_GENERATION)
rawset(BrokerKit, "REVISION", IMPLEMENTATION_REVISION)
rawset(BrokerKit, "MAX_OBJECTS", MAX_OBJECTS)
rawset(BrokerKit, "MAX_ATTRIBUTES", MAX_ATTRIBUTES)
rawset(BrokerKit, "UNBOUNDED", UNBOUNDED)
rawset(BrokerKit, "New", packageNew)
rawset(BrokerKit, "Get", packageGet)
rawset(BrokerKit, "Objects", packageObjects)
rawset(BrokerKit, "Iterate", packageIterate)
rawset(BrokerKit, "OnObjectAdded", packageOnObjectAdded)
rawset(BrokerKit, "IsForeign", packageIsForeign)
rawset(BrokerKit, "ExposeToLibDataBroker", packageExposeToLibDataBroker)
rawset(BrokerKit, "AdoptFromLibDataBroker", packageAdoptFromLibDataBroker)
rawset(BrokerKit, "SetLimits", packageSetLimits)
rawset(BrokerKit, "GetLimits", packageGetLimits)

rawset(state, "runtimeRevision", IMPLEMENTATION_REVISION)

if not validatePublicSurface(BrokerKit) or not validateCurrentState(BrokerKit) then
    error("MoltenCodes BrokerKit package state is corrupted or incomplete", 2)
end
for index = 1, #OBJECT_METHODS do
    if type(rawget(ObjectPrototype, OBJECT_METHODS[index])) ~= "function" then
        error("MoltenCodes BrokerKit package state is corrupted or incomplete", 2)
    end
end

return BrokerKit
