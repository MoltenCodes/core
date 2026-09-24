-- MoltenCodes MediaKit
--
-- A typed registry of named media for World of Warcraft addons: fonts, status
-- bars, borders, backgrounds, sounds, textures and icons. Each entry is a file
-- path or a FileDataID; a font also carries the writing scripts it can render,
-- so a Latin-only font is not offered to a Chinese client. Listing is sorted
-- and cached, defaults belong to the consumer that chose them, and every
-- registration fires a SignalKit signal.
--
-- When LibSharedMedia-3.0 is loaded, MediaKit can adopt its entries read-only
-- (existing media packs stay visible) and mirror its own entries into it
-- (existing LibSharedMedia consumers see ours). Both go through LibStub, found
-- at call time with `rawget(_G, "LibStub")`; neither is required.
--
-- MediaKit requires Registry API 2 and SignalKit API 1. It reads three optional
-- host facilities at call time: `GetLocale` (without it the client writes
-- Latin), `issecretvalue` (without it nothing is secret) and `LibStub`.
--
-- Contents
-- --------
--   Constants ............. identity, limits, media types, scripts, built-ins
--   Public types .......... LuaCATS declarations for the published surface
--   Dependencies .......... Registry, SignalKit, host readers
--   Validation ............ public-surface and shared-state predicates
--   Bootstrap ............. Registry registration and inherited state
--   Host facilities ....... secret values and the client's script
--   Argument checks ....... media types, names, data, option tables
--   Entries ............... the one registration path every origin shares
--   Sorted lists .......... the cached arrays `List` returns
--   LibSharedMedia ........ finding it, adopting from it, mirroring into it
--   Defaults objects ...... per-consumer defaults and their fallbacks
--   Package public API .... the facade published through Registry
--   Commit ................ prototype/facade assignment, built-ins, self-check
--
-- Layout and invariants are described in `docs/INTERNALS.md`.

-- Constants ------------------------------------------------------------------

local PACKAGE_NAME = "mediaKit"
local API_GENERATION = 1
local IMPLEMENTATION_REVISION = 4
local REQUIRED_REGISTRY_API = 2
local REQUIRED_SIGNALKIT_API = 1
local STATE_SCHEMA = 1

-- Every type record carries the layout it was built with, so a later revision
-- that changes the layout can upgrade old records instead of guessing.
local RECORD_SCHEMA = 1
local DEFAULTS_SCHEMA = 1

-- The default of the `maxEntriesPerType` limit: the most entries one media
-- type holds, counting built-ins and adopted entries. Registration is
-- load-time data, so this is a guard against a runaway loop, not a budget any
-- real pack comes near. Published as `MAX_ENTRIES_PER_TYPE`.
local MAX_ENTRIES_PER_TYPE = 1024

-- The highest `maxEntriesPerType` `SetLimits` accepts. Entries are never
-- removed, every addon's `List` sorts and returns all of them, and mirrored
-- entries land in LibSharedMedia, which has no way to unregister. Sixteen
-- times the default covers every media pack seen in the wild many times over
-- while keeping one sorted list a bounded amount of work.
local MAX_ENTRIES_PER_TYPE_CEILING = 16384
local ENTRIES_UNBOUNDED_REASON = "entries are never removed and are mirrored into LibSharedMedia"

-- The default of the `maxConsumers` limit: the most defaults objects
-- `Defaults` creates. Consumers are addons and modules, so this only stops a
-- loop that invents consumer names.
local MAX_CONSUMERS = 1024

-- The limits `SetLimits` accepts, in the order `GetLimits` reports them.
local LIMIT_NAMES = { "maxEntriesPerType", "maxConsumers" }

-- The fixed set of media types, sorted, and the same names as a set so that
-- refusing an unknown one allocates nothing.
local MEDIA_TYPES = { "background", "border", "font", "icon", "sound", "statusbar", "texture" }
local MEDIA_TYPE_SET = {
    background = true,
    border = true,
    font = true,
    icon = true,
    sound = true,
    statusbar = true,
    texture = true,
}
local MEDIA_TYPE_MESSAGE =
    'must be one of "background", "border", "font", "icon", "sound", "statusbar", "texture"'

-- The writing scripts a font may declare, each one bit of the entry's mask.
-- The mask makes "same scripts" a number comparison and a coverage test two
-- arithmetic operations, with no per-entry set table.
local SCRIPT_BITS = {
    latin = 1,
    cyrillic = 2,
    greek = 4,
    cjkSimplified = 8,
    cjkTraditional = 16,
    korean = 32,
    japanese = 64,
}
local ALL_SCRIPTS = 127

-- The scripts of a font registered without `options.scripts`: Latin only.
local DEFAULT_FONT_SCRIPTS = 1

-- The script each client locale writes. `greek` and `japanese` have no client
-- locale today; a font may still declare them for text it renders itself.
-- A locale not listed here, or a client without `GetLocale`, writes Latin.
local LOCALE_SCRIPTS = {
    enUS = "latin",
    enGB = "latin",
    deDE = "latin",
    frFR = "latin",
    esES = "latin",
    esMX = "latin",
    itIT = "latin",
    ptBR = "latin",
    ptPT = "latin",
    ruRU = "cyrillic",
    zhCN = "cjkSimplified",
    zhTW = "cjkTraditional",
    koKR = "korean",
}
local FALLBACK_SCRIPT = "latin"

-- Where an entry came from. Only `registered` and `builtin` entries are ever
-- mirrored into LibSharedMedia; an adopted entry came from there.
local ORIGIN_BUILTIN = "builtin"
local ORIGIN_REGISTERED = "registered"
local ORIGIN_ADOPTED = "libSharedMedia"

-- What the shared registration path reports.
local STATUS_ADDED = "added"
local STATUS_UNCHANGED = "unchanged"
local STATUS_TAKEN = "taken"
local STATUS_FULL = "full"

-- LibSharedMedia-3.0: its LibStub major, the callback it fires after every
-- registration, the media types it shares with MediaKit (same names), and its
-- font locale bits with the values the library has always used, read from the
-- library itself when it publishes them.
local LIBSHAREDMEDIA_MAJOR = "LibSharedMedia-3.0"
local LIBSHAREDMEDIA_EVENT = "LibSharedMedia_Registered"
local LIBSHAREDMEDIA_TYPES = { "background", "border", "font", "sound", "statusbar" }
local LIBSHAREDMEDIA_TYPE_SET =
    { background = true, border = true, font = true, sound = true, statusbar = true }
local LIBSHAREDMEDIA_LOCALE_BITS = {
    { script = "latin", field = "LOCALE_BIT_western", value = 128 },
    { script = "cyrillic", field = "LOCALE_BIT_ruRU", value = 2 },
    { script = "cjkSimplified", field = "LOCALE_BIT_zhCN", value = 4 },
    { script = "cjkTraditional", field = "LOCALE_BIT_zhTW", value = 8 },
    { script = "korean", field = "LOCALE_BIT_koKR", value = 1 },
}

-- The client's own media, registered at load so a consumer always has
-- something to fall back to. These files ship with the game; MediaKit ships
-- none. Paths are the ones LibSharedMedia-3.0 registers for the same names.
local BUILTIN_MEDIA = {
    {
        "background",
        "Blizzard Dialog Background",
        [[Interface\DialogFrame\UI-DialogBox-Background]],
    },
    { "background", "Blizzard Tooltip", [[Interface\Tooltips\UI-Tooltip-Background]] },
    { "background", "Solid", [[Interface\Buttons\WHITE8X8]] },
    { "border", "Blizzard Dialog", [[Interface\DialogFrame\UI-DialogBox-Border]] },
    { "border", "Blizzard Tooltip", [[Interface\Tooltips\UI-Tooltip-Border]] },
    { "border", "None", [[Interface\None]] },
    { "icon", "Question Mark", [[Interface\Icons\INV_Misc_QuestionMark]] },
    { "sound", "None", [[Interface\Quiet.ogg]] },
    { "statusbar", "Blizzard", [[Interface\TargetingFrame\UI-StatusBar]] },
    { "statusbar", "Solid", [[Interface\Buttons\WHITE8X8]] },
    { "texture", "Solid", [[Interface\Buttons\WHITE8X8]] },
}

-- The client's own fonts. A Cyrillic client ships separate files that render
-- both Latin and Cyrillic; every other client gets the Western files, which
-- render Latin only.
local BUILTIN_FONTS = {
    { name = "Arial Narrow", western = [[Fonts\ARIALN.TTF]], cyrillic = [[Fonts\ARIALN.TTF]] },
    {
        name = "Friz Quadrata TT",
        western = [[Fonts\FRIZQT__.TTF]],
        cyrillic = [[Fonts\FRIZQT___CYR.TTF]],
    },
    { name = "Morpheus", western = [[Fonts\MORPHEUS.TTF]], cyrillic = [[Fonts\MORPHEUS_CYR.TTF]] },
    { name = "Skurri", western = [[Fonts\SKURRI.TTF]], cyrillic = [[Fonts\SKURRI_CYR.TTF]] },
}

-- The name `defaults:Get(type)` answers when the consumer chose nothing, or
-- chose something this client cannot use. Every one is a built-in above.
local BUILTIN_FALLBACKS = {
    background = "Blizzard Dialog Background",
    border = "Blizzard Tooltip",
    font = "Friz Quadrata TT",
    icon = "Question Mark",
    sound = "None",
    statusbar = "Blizzard",
    texture = "Solid",
}

-- The complete set of fields each option table accepts.
local REGISTER_OPTION_KEYS = { scripts = true }
local LOOKUP_OPTION_KEYS = { anyScript = true }

local FACADE_METHODS = {
    "Register",
    "Fetch",
    "Has",
    "List",
    "OnRegistered",
    "Defaults",
    "AdoptLibSharedMedia",
    "MirrorToLibSharedMedia",
    "IsFileDataID",
    "SetLimits",
    "GetLimits",
}
local DEFAULTS_METHODS = { "Set", "Get" }

local HUGE = math.huge
local mathFloor = math.floor
local tableSort = table.sort

-- Public types ---------------------------------------------------------------

---One of the seven media types.
---@alias MediaKit.MediaType "background"|"border"|"font"|"icon"|"sound"|"statusbar"|"texture"

---A writing script a font can render.
---@alias MediaKit.Script "latin"|"cyrillic"|"greek"|"cjkSimplified"|"cjkTraditional"|"korean"|"japanese"

---An entry's data: a file path such as `[[Interface\Addons\MyPack\Bar.tga]]`,
---or a FileDataID (a positive integer).
---@alias MediaKit.Data string|integer

---Options accepted by `MediaKit:Register`.
---@class MediaKit.RegisterOptions
---@field scripts MediaKit.Script[]? Fonts only: the scripts the font renders. Defaults to `{ "latin" }`.

---Options accepted by `Fetch`, `Has` and `List`.
---@class MediaKit.LookupOptions
---@field anyScript boolean? Fonts only: ignore whether the font covers the client's script.

---Called after an entry was added, with its type, name and data.
---@alias MediaKit.RegisteredListener fun(mediaType: MediaKit.MediaType, name: string, data: MediaKit.Data)

---One consumer's defaults, returned by `MediaKit:Defaults`.
---@class MediaKit.Defaults
---@field Set fun(self: MediaKit.Defaults, mediaType: MediaKit.MediaType, name: string?)
---@field Get fun(self: MediaKit.Defaults, mediaType: MediaKit.MediaType): string?

---The subset of LibSharedMedia-3.0 MediaKit calls. Private.
---@class MediaKit.LibSharedMedia
---@field Register fun(self: table, mediaType: string, name: string, data: MediaKit.Data, langmask: integer?): boolean
---@field HashTable fun(self: table, mediaType: string): table<string, MediaKit.Data>?
---@field RegisterCallback fun(owner: table, eventName: string, callback: function)?

---The shared limits. `SetLimits` accepts any subset; `GetLimits` returns all.
---@class MediaKit.Limits
---@field maxEntriesPerType integer Most entries one media type holds, built-ins and adopted entries included: an integer from 1 to 16384; default `1024`. `UNBOUNDED` is refused.
---@field maxConsumers integer|table Most defaults objects `Defaults` creates: a positive integer or `MediaKit.UNBOUNDED`; default `1024`.

---The MediaKit package facade published through Registry.
---@class MediaKit
---@field API integer Public API generation.
---@field REVISION integer Compatible implementation revision.
---@field MAX_ENTRIES_PER_TYPE integer Default of the `maxEntriesPerType` limit (`1024`).
---@field UNBOUNDED table Sentinel that lifts a limit where allowed; the same table for every revision.
---@field Register fun(self: MediaKit, mediaType: MediaKit.MediaType, name: string, data: MediaKit.Data, options: MediaKit.RegisterOptions?): true|nil, ("taken"|"full")?
---@field Fetch fun(self: MediaKit, mediaType: MediaKit.MediaType, name: string, options: MediaKit.LookupOptions?): MediaKit.Data?
---@field Has fun(self: MediaKit, mediaType: MediaKit.MediaType, name: string, options: MediaKit.LookupOptions?): boolean
---@field List fun(self: MediaKit, mediaType: MediaKit.MediaType, options: MediaKit.LookupOptions?): string[]
---@field OnRegistered fun(self: MediaKit, mediaType: MediaKit.MediaType, callback: MediaKit.RegisteredListener): SignalKit.Connection
---@field Defaults fun(self: MediaKit, consumerName: string): MediaKit.Defaults
---@field AdoptLibSharedMedia fun(self: MediaKit): boolean, (integer|"absent")
---@field MirrorToLibSharedMedia fun(self: MediaKit): boolean, (integer|"absent")
---@field IsFileDataID fun(self: MediaKit, data: any): boolean
---@field SetLimits fun(self: MediaKit, limits: MediaKit.Limits)
---@field GetLimits fun(self: MediaKit): MediaKit.Limits

---One entry. Private.
---@class MediaKit.Entry
---@field data MediaKit.Data
---@field scriptMask integer
---@field origin string

---Everything MediaKit keeps per media type. Private.
---@class MediaKit.TypeRecord
---@field schema integer
---@field entries table<string, MediaKit.Entry>
---@field count integer
---@field version integer bumped by every added entry; the lists compare against it
---@field signal table the SignalKit signal `OnRegistered` connects to
---@field allList string[]|false every name, sorted
---@field allListVersion integer
---@field clientList string[]|false the names this client can use, sorted
---@field clientListVersion integer
---@field clientListScript string|false the script `clientList` was filtered for

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
    error("MoltenCodes MediaKit requires Registry API 2 to be loaded first", 2)
end

local bootstrapPackage = rawget(Registry, "Bootstrap")
local getPackage = rawget(Registry, "Get")
if type(bootstrapPackage) ~= "function" or type(getPackage) ~= "function" then
    error("MoltenCodes MediaKit requires a valid Registry API 2 facade", 2)
end

-- SignalKit carries one registration signal per media type.
local SignalKit = getPackage(Registry, "signalKit", REQUIRED_SIGNALKIT_API)
if
    type(SignalKit) ~= "table"
    or rawget(SignalKit, "API") ~= REQUIRED_SIGNALKIT_API
    or type(rawget(SignalKit, "New")) ~= "function"
then
    error("MoltenCodes MediaKit requires SignalKit API 1 to be loaded first", 2)
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

---Whether `implementation` exposes the complete MediaKit API 1 surface.
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
    local maxEntriesPerType = rawget(limits, "maxEntriesPerType")
    local maxConsumers = rawget(limits, "maxConsumers")
    return isPositiveInteger(maxEntriesPerType)
        and maxEntriesPerType <= MAX_ENTRIES_PER_TYPE_CEILING
        and (maxConsumers == unbounded or isPositiveInteger(maxConsumers))
end

---Whether `currentState` has the fields every API 1 revision shares.
---@param currentState any
---@return boolean
local function validateStateBase(currentState)
    if type(currentState) ~= "table" or rawget(currentState, "schema") ~= STATE_SCHEMA then
        return false
    end
    local types = rawget(currentState, "types")
    if type(types) ~= "table" then
        return false
    end
    for index = 1, #MEDIA_TYPES do
        local record = rawget(types, MEDIA_TYPES[index])
        if
            type(record) ~= "table"
            or rawget(record, "schema") ~= RECORD_SCHEMA
            or type(rawget(record, "entries")) ~= "table"
            or type(rawget(record, "signal")) ~= "table"
        then
            return false
        end
    end
    local libSharedMedia = rawget(currentState, "libSharedMedia")
    local unbounded = rawget(currentState, "unbounded")
    return type(rawget(currentState, "runtimeRevision")) == "number"
        and type(unbounded) == "table"
        and validateLimitsTable(rawget(currentState, "limits"), unbounded)
        and type(rawget(currentState, "consumers")) == "table"
        and type(rawget(currentState, "consumerCount")) == "number"
        and type(rawget(currentState, "defaultsPrototype")) == "table"
        and type(rawget(currentState, "defaultsMetatable")) == "table"
        and type(rawget(currentState, "dispatch")) == "table"
        and type(libSharedMedia) == "table"
        and type(rawget(libSharedMedia, "callbackOwner")) == "table"
        and type(rawget(libSharedMedia, "callback")) == "function"
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
-- and register this one. What stays here is what only MediaKit can answer.
local MediaKit, previousRevision, selected = bootstrapPackage(Registry, {
    package = PACKAGE_NAME,
    api = API_GENERATION,
    revision = IMPLEMENTATION_REVISION,
    label = "MoltenCodes MediaKit",
    validatePublicSurface = validatePublicSurface,
    validateState = validateCurrentState,
})

if MediaKit == nil then
    -- An equal or newer compatible revision already owns the shared package table.
    return selected
end

---Build the empty record of one media type.
---@return MediaKit.TypeRecord
local function newTypeRecord()
    return {
        schema = RECORD_SCHEMA,
        entries = {},
        count = 0,
        version = 0,
        signal = SignalKit:New(),
        allList = false,
        allListVersion = -1,
        clientList = false,
        clientListVersion = -1,
        clientListScript = false,
    }
end

local state = rawget(MediaKit, "_state")

if previousRevision == nil then
    if state ~= nil then
        error("MoltenCodes MediaKit package state is corrupted or incomplete", 2)
    end

    local types = {}
    for index = 1, #MEDIA_TYPES do
        types[MEDIA_TYPES[index]] = newTypeRecord()
    end

    -- Functions every loading revision rewrites. The LibSharedMedia callback
    -- below is handed to another library and cannot be replaced, so it looks
    -- its behaviour up here at every call.
    local dispatch = {}

    state = {
        schema = STATE_SCHEMA,
        runtimeRevision = 0,
        -- The sentinel `SetLimits` accepts to lift a limit. It lives here, not
        -- in a file local, so every embedded revision hands out the same table.
        unbounded = {},
        -- The shared limits, kept across upgrades like everything else here.
        limits = {
            maxEntriesPerType = MAX_ENTRIES_PER_TYPE,
            maxConsumers = MAX_CONSUMERS,
        },
        -- Media type to its record. Entries live for the session.
        types = types,
        -- Consumer name to its defaults object, and how many there are.
        consumers = {},
        consumerCount = 0,
        -- The prototype and metatable every defaults object shares. The
        -- prototype's functions are rewritten by every loading revision.
        defaultsPrototype = {},
        defaultsMetatable = {},
        dispatch = dispatch,
        libSharedMedia = {
            -- The library adopted from, or `false` before `AdoptLibSharedMedia`.
            adoptSource = false,
            -- The library the callback was registered with, or `false`.
            subscribed = false,
            -- The library mirrored into, or `false` before `MirrorToLibSharedMedia`.
            mirrorTarget = false,
            -- The table CallbackHandler files our registration under. It must
            -- not be the library itself, which CallbackHandler refuses.
            callbackOwner = {},
            callback = function(_, mediaType, name)
                dispatch.onLibSharedMediaRegistered(mediaType, name)
            end,
        },
    }
    rawset(MediaKit, "_state", state)
elseif not validateStateBase(state) then
    error("MoltenCodes MediaKit package state is corrupted or incomplete", 2)
end

local types = rawget(state, "types")
local consumers = rawget(state, "consumers")
local dispatch = rawget(state, "dispatch")
local libSharedMedia = rawget(state, "libSharedMedia")
local DefaultsPrototype = rawget(state, "defaultsPrototype")
local DEFAULTS_METATABLE = rawget(state, "defaultsMetatable")
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

---The script the client writes: from `GetLocale()`, read at every call so a
---host stub installed after load is honoured; Latin without it.
---@return string script
local function resolveClientScript()
    local getLocale = readGlobal("GetLocale")
    if type(getLocale) ~= "function" then
        return FALLBACK_SCRIPT
    end
    local locale = getLocale()
    if type(locale) ~= "string" then
        return FALLBACK_SCRIPT
    end
    return LOCALE_SCRIPTS[locale] or FALLBACK_SCRIPT
end

---Whether `scriptMask` includes `script`. Two arithmetic operations, no table.
---@param scriptMask integer
---@param script string
---@return boolean
local function coversScript(scriptMask, script)
    local bit = SCRIPT_BITS[script]
    return mathFloor(scriptMask / bit) % 2 == 1
end

---Whether `value` is a FileDataID: a finite positive integer. A secret is
---never one, and is not compared.
---@param value any
---@return boolean
local function isFileDataID(value)
    if type(value) ~= "number" or isSecret(value) then
        return false
    end
    return value >= 1 and value < HUGE and value % 1 == 0
end

---Whether `value` is usable entry data: a non-empty path or a FileDataID.
---@param value any
---@return boolean
local function isValidData(value)
    if isSecret(value) then
        return false
    end
    if type(value) == "string" then
        return value ~= ""
    end
    return isFileDataID(value)
end

-- Argument checks ------------------------------------------------------------
--
-- Argument validation raises with an explicit stack level so the reported
-- position is the line that called the public method, never a line inside
-- MediaKit. `level` is always the value `error` needs *inside the function
-- that receives it*, so every further hop towards `error` adds exactly one.
-- Secrets are checked first, because comparing one raises.

---@param value any
---@param methodName string public method name, used in the argument error
---@param level integer stack level the failure is reported at
local function validateMediaType(value, methodName, level)
    if isSecret(value) then
        error(methodName .. " type must not be a secret value", level)
    end
    if type(value) ~= "string" or MEDIA_TYPE_SET[value] ~= true then
        error(methodName .. " type " .. MEDIA_TYPE_MESSAGE, level)
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

---@param value any
---@param level integer stack level the failure is reported at
local function validateData(value, level)
    if isSecret(value) then
        error("MediaKit:Register data must not be a secret value", level)
    end
    if not isValidData(value) then
        error(
            "MediaKit:Register data must be a non-empty file path or a FileDataID (a positive integer)",
            level
        )
    end
end

---Name a value in a message without running a caller's `__tostring`.
---@param value any
---@return string
local function describeValue(value)
    if type(value) == "string" then
        return '"' .. value .. '"'
    end
    return "<" .. type(value) .. ">"
end

---Name a table key in a message without running a caller's `__tostring`: a
---string, number or boolean as itself, anything else by its type.
---@param key any a table key, which can never be `nil` or a secret
---@return string
local function describeKey(key)
    local kind = type(key)
    if kind == "string" then
        return key
    end
    if kind == "number" or kind == "boolean" then
        return tostring(key)
    end
    return "<" .. kind .. ">"
end

---Refuse a non-table option table and any field outside `allowedKeys`.
---@param options any
---@param allowedKeys table<string, true>
---@param methodName string public method name, used in the argument errors
---@param level integer stack level the failures are reported at
local function validateOptionKeys(options, allowedKeys, methodName, level)
    if type(options) ~= "table" then
        error(methodName .. " options must be a table", level)
    end

    -- Report the alphabetically first unknown field without allocating: track
    -- the smallest key seen instead of collecting and sorting every offender.
    local firstUnknown = nil
    for key in next, options do
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

---Read `options.anyScript` of a lookup. Allocates nothing.
---@param options any
---@param methodName string
---@param level integer
---@return boolean anyScript
local function readAnyScript(options, methodName, level)
    if type(options) == "nil" then
        return false
    end
    validateOptionKeys(options, LOOKUP_OPTION_KEYS, methodName, level + 1)
    local flag = rawget(options, "anyScript")
    -- A secret boolean passes the type check and raises when compared, so it
    -- is refused first, at the caller, like every other secret argument.
    if isSecret(flag) then
        error(methodName .. " anyScript must not be a secret value", level)
    end
    if type(flag) ~= "nil" and type(flag) ~= "boolean" then
        error(methodName .. " anyScript must be a boolean", level)
    end
    return flag == true
end

---Turn `options.scripts` into a mask.
---@param scripts any
---@param level integer
---@return integer scriptMask
local function readScriptMask(scripts, level)
    if type(scripts) ~= "table" or #scripts == 0 then
        error("MediaKit:Register scripts must be a non-empty array of script names", level)
    end
    local mask = 0
    for index = 1, #scripts do
        local script = scripts[index]
        -- Before the lookup: a secret used as a table key raises.
        if isSecret(script) then
            error("MediaKit:Register scripts must not contain a secret value", level)
        end
        local bit = type(script) == "string" and SCRIPT_BITS[script] or nil
        if bit == nil then
            error(
                "MediaKit:Register scripts contains unknown script " .. describeValue(script),
                level
            )
        end
        if not coversScript(mask, script) then
            mask = mask + bit
        end
    end
    return mask
end

---Read the options of `Register` and return the entry's script mask.
---@param mediaType string
---@param options any
---@param level integer
---@return integer scriptMask
local function readRegisterOptions(mediaType, options, level)
    -- A font that declares nothing is taken to render Latin only, as
    -- LibSharedMedia assumes: offering an undeclared font to a CJK client
    -- would show missing glyphs, while hiding a wider font only costs the
    -- author one `scripts` line. Other types are never filtered.
    local undeclared = mediaType == "font" and DEFAULT_FONT_SCRIPTS or ALL_SCRIPTS
    if type(options) == "nil" then
        return undeclared
    end
    validateOptionKeys(options, REGISTER_OPTION_KEYS, "MediaKit:Register", level + 1)
    local scripts = rawget(options, "scripts")
    if type(scripts) == "nil" then
        return undeclared
    end
    if mediaType ~= "font" then
        error("MediaKit:Register scripts applies to fonts only", level)
    end
    return readScriptMask(scripts, level + 1)
end

-- Entries --------------------------------------------------------------------
--
-- `Register`, the built-ins and adoption all add entries through
-- `registerEntry`, so the rules (duplicate names, the cap, list invalidation,
-- mirroring, the signal) hold whatever the origin.

---Add one entry, or say why not. The entry is committed and the lists are
---invalidated before anything outside MediaKit runs (the mirror, the signal),
---so a listener that re-enters sees the new entry.
---@param mediaType string
---@param name string
---@param data MediaKit.Data
---@param scriptMask integer
---@param origin string
---@return string status one of the `STATUS_*` values
local function registerEntry(mediaType, name, data, scriptMask, origin)
    local record = types[mediaType]
    local existing = record.entries[name]
    if existing ~= nil then
        if existing.data == data and existing.scriptMask == scriptMask then
            return STATUS_UNCHANGED
        end
        return STATUS_TAKEN
    end
    if record.count >= rawget(sharedLimits, "maxEntriesPerType") then
        return STATUS_FULL
    end

    record.entries[name] = { data = data, scriptMask = scriptMask, origin = origin }
    record.count = record.count + 1
    record.version = record.version + 1

    if origin ~= ORIGIN_ADOPTED then
        dispatch.mirrorEntry(mediaType, name, data, scriptMask)
    end
    record.signal:Fire(mediaType, name, data)
    return STATUS_ADDED
end

---The entry `name` of `mediaType` when this lookup may use it, else `nil`.
---@param mediaType string
---@param name string
---@param anyScript boolean
---@return MediaKit.Entry|nil
local function findUsableEntry(mediaType, name, anyScript)
    local entry = types[mediaType].entries[name]
    if entry == nil then
        return nil
    end
    if mediaType == "font" and not anyScript then
        if not coversScript(entry.scriptMask, resolveClientScript()) then
            return nil
        end
    end
    return entry
end

-- Sorted lists ---------------------------------------------------------------
--
-- A list is rebuilt into a new array when its record's `version` moved (or,
-- for the client's font list, when the client's script changed); otherwise
-- the cached array is returned as is. An array is never modified after it was
-- handed out, so a caller iterating an older one is not disturbed.

---Build a new array of the entry names of `record`, sorted with `<`, keeping
---only fonts that cover `script` unless it is `false`.
---@param record MediaKit.TypeRecord
---@param script string|false
---@return string[]
local function buildSortedNames(record, script)
    local names = {}
    local count = 0
    for name, entry in next, record.entries do
        if script == false or coversScript(entry.scriptMask, script) then
            count = count + 1
            names[count] = name
        end
    end
    tableSort(names)
    return names
end

---Every name of `record`, sorted, from the cache when it is current.
---@param record MediaKit.TypeRecord
---@return string[]
local function currentAllList(record)
    local list = record.allList
    if list == false or record.allListVersion ~= record.version then
        list = buildSortedNames(record, false)
        record.allList = list
        record.allListVersion = record.version
    end
    return list
end

---The font names this client can use, sorted, from the cache when current.
---@param record MediaKit.TypeRecord
---@return string[]
local function currentClientList(record)
    local script = resolveClientScript()
    local list = record.clientList
    if
        list == false
        or record.clientListVersion ~= record.version
        or record.clientListScript ~= script
    then
        list = buildSortedNames(record, script)
        record.clientList = list
        record.clientListVersion = record.version
        record.clientListScript = script
    end
    return list
end

-- LibSharedMedia -------------------------------------------------------------

---LibSharedMedia-3.0 through LibStub, or `nil` when either is not loaded.
---@return MediaKit.LibSharedMedia|nil
local function findLibSharedMedia()
    local libStub = readGlobal("LibStub")
    if type(libStub) ~= "table" then
        return nil
    end
    local getLibrary = rawget(libStub, "GetLibrary")
    if type(getLibrary) ~= "function" then
        return nil
    end
    local library = getLibrary(libStub, LIBSHAREDMEDIA_MAJOR, true)
    if
        type(library) ~= "table"
        or type(rawget(library, "Register")) ~= "function"
        or type(rawget(library, "HashTable")) ~= "function"
    then
        return nil
    end
    return library
end

---The LibSharedMedia `langmask` for a font covering `scriptMask`. Scripts
---LibSharedMedia has no bit for (`greek`, `japanese`) add nothing.
---@param library MediaKit.LibSharedMedia
---@param scriptMask integer
---@return integer
local function libSharedMediaLocaleMask(library, scriptMask)
    local mask = 0
    for index = 1, #LIBSHAREDMEDIA_LOCALE_BITS do
        local localeBit = LIBSHAREDMEDIA_LOCALE_BITS[index]
        if coversScript(scriptMask, localeBit.script) then
            local value = rawget(library, localeBit.field)
            -- A field of a foreign library: a secret number would raise in
            -- the addition, so it is treated like a missing one.
            if type(value) ~= "number" or isSecret(value) then
                value = localeBit.value
            end
            mask = mask + value
        end
    end
    return mask
end

---Register one of our entries into LibSharedMedia when mirroring is on, the
---type is one LibSharedMedia knows and it has no entry of that name yet.
---LibSharedMedia fires its callback from inside `Register`; our adoption
---handler then finds the entry already present and adds nothing.
---@param mediaType string
---@param name string
---@param data MediaKit.Data
---@param scriptMask integer
---@return boolean mirrored
local function mirrorEntry(mediaType, name, data, scriptMask)
    local library = libSharedMedia.mirrorTarget
    if library == false or LIBSHAREDMEDIA_TYPE_SET[mediaType] ~= true then
        return false
    end
    local hash = library:HashTable(mediaType)
    if type(hash) == "table" and type(hash[name]) ~= "nil" then
        return false
    end
    local langmask = nil
    if mediaType == "font" then
        langmask = libSharedMediaLocaleMask(library, scriptMask)
    end
    local registered = library:Register(mediaType, name, data, langmask)
    -- LibSharedMedia's answer is a foreign value: a secret one is never
    -- compared, and counts as "not mirrored".
    if isSecret(registered) then
        return false
    end
    return registered == true
end

---Adopt one LibSharedMedia entry read-only. Invalid names and data, secrets,
---a name MediaKit already holds and a full type are skipped.
---@param mediaType string
---@param name any
---@param data any
---@return boolean added
local function adoptEntry(mediaType, name, data)
    if isSecret(name) or type(name) ~= "string" or name == "" or not isValidData(data) then
        return false
    end
    -- LibSharedMedia has already refused fonts this client cannot render, so
    -- an adopted font covers every script as far as MediaKit is concerned.
    return registerEntry(mediaType, name, data, ALL_SCRIPTS, ORIGIN_ADOPTED) == STATUS_ADDED
end

---Adopt every entry LibSharedMedia holds for `mediaType`, in sorted name order
---so the signals fire deterministically. The names are collected first
---because a listener may register into LibSharedMedia while we walk it.
---@param library MediaKit.LibSharedMedia
---@param mediaType string
---@return integer added
local function adoptType(library, mediaType)
    local hash = library:HashTable(mediaType)
    if type(hash) ~= "table" then
        return 0
    end
    local names = {}
    local count = 0
    for name in next, hash do
        if not isSecret(name) and type(name) == "string" then
            count = count + 1
            names[count] = name
        end
    end
    tableSort(names)

    local added = 0
    for index = 1, count do
        local name = names[index]
        if adoptEntry(mediaType, name, hash[name]) then
            added = added + 1
        end
    end
    return added
end

---Handle `LibSharedMedia_Registered(mediaType, name)`: adopt the new entry.
---Called through `dispatch`, so an upgrade replaces it behind the callback
---LibSharedMedia already holds.
---@param mediaType any
---@param name any
local function onLibSharedMediaRegistered(mediaType, name)
    local library = libSharedMedia.adoptSource
    if library == false or isSecret(mediaType) or isSecret(name) then
        return
    end
    if type(mediaType) ~= "string" or LIBSHAREDMEDIA_TYPE_SET[mediaType] ~= true then
        return
    end
    local hash = library:HashTable(mediaType)
    if type(hash) ~= "table" or type(name) ~= "string" then
        return
    end
    adoptEntry(mediaType, name, hash[name])
end

---Register the callback with LibSharedMedia's CallbackHandler once. A
---LibSharedMedia without one is adopted from on each call only.
---@param library MediaKit.LibSharedMedia
local function subscribe(library)
    if libSharedMedia.subscribed == library then
        return
    end
    local registerCallback = rawget(library, "RegisterCallback")
    if type(registerCallback) ~= "function" then
        return
    end
    registerCallback(libSharedMedia.callbackOwner, LIBSHAREDMEDIA_EVENT, libSharedMedia.callback)
    libSharedMedia.subscribed = library
end

-- Defaults objects -----------------------------------------------------------

---Refuse a receiver that is not a defaults object.
---@param self any
---@param methodName string
---@param level integer
local function validateDefaults(self, methodName, level)
    if type(self) ~= "table" or getmetatable(self) ~= "MediaKit.Defaults" then
        error(
            methodName
                .. " must be called on a defaults object; use defaults:"
                .. methodName:match("[^:]+$")
                .. "(...)",
            level
        )
    end
end

---Choose `name` as this consumer's default for `mediaType`, or clear the
---choice with `nil`. The name need not be registered yet: a pack may load
---later, and `Get` answers the built-in fallback until it does.
---@param self MediaKit.Defaults
---@param mediaType MediaKit.MediaType
---@param name string?
local function defaultsSet(self, mediaType, name)
    validateDefaults(self, "MediaKit.Defaults:Set", 3)
    validateMediaType(mediaType, "MediaKit.Defaults:Set", 3)
    if type(name) ~= "nil" then
        validateName(name, "MediaKit.Defaults:Set name", 3)
    end
    rawget(self, "_names")[mediaType] = name
end

---This consumer's default name for `mediaType`, the first this client can
---use of: its choice, the built-in fallback, the first name of `List(type)`.
---`nil` only when the type holds nothing this client can use. Allocates
---nothing while the list is cached.
---@param self MediaKit.Defaults
---@param mediaType MediaKit.MediaType
---@return string? name
local function defaultsGet(self, mediaType)
    validateDefaults(self, "MediaKit.Defaults:Get", 3)
    validateMediaType(mediaType, "MediaKit.Defaults:Get", 3)
    local name = rawget(self, "_names")[mediaType]
    if name ~= nil and findUsableEntry(mediaType, name, false) ~= nil then
        return name
    end
    local fallback = BUILTIN_FALLBACKS[mediaType]
    if findUsableEntry(mediaType, fallback, false) ~= nil then
        return fallback
    end
    -- Only a font can reach this point: every other type's fallback is a
    -- built-in, which no later registration can replace, and it is never
    -- filtered. That leaves a client whose script no built-in font renders;
    -- the client's list holds what it can render, adopted fonts included.
    return currentClientList(types[mediaType])[1]
end

-- Package public API ---------------------------------------------------------

---Register `data` as `name` of `mediaType`.
---
---Returns `true`, or `nil, "taken"` when the name holds different data (or,
---for a font, different scripts), or `nil, "full"` at the
---`maxEntriesPerType` limit. Registering the same name with the same data again
---is a no-op returning `true`.
---@param _ MediaKit
---@param mediaType MediaKit.MediaType
---@param name string
---@param data MediaKit.Data
---@param options MediaKit.RegisterOptions?
---@return true|nil registered
---@return ("taken"|"full")? reason
local function packageRegister(_, mediaType, name, data, options)
    validateMediaType(mediaType, "MediaKit:Register", 3)
    validateName(name, "MediaKit:Register name", 3)
    validateData(data, 3)
    local scriptMask = readRegisterOptions(mediaType, options, 3)

    local status = registerEntry(mediaType, name, data, scriptMask, ORIGIN_REGISTERED)
    if status == STATUS_ADDED or status == STATUS_UNCHANGED then
        return true
    end
    return nil, status
end

---Return the data registered as `name` of `mediaType`, or `nil`.
---
---A font whose scripts do not cover the client's is `nil` unless
---`options.anyScript`. One table read and no allocation.
---@param _ MediaKit
---@param mediaType MediaKit.MediaType
---@param name string
---@param options MediaKit.LookupOptions?
---@return MediaKit.Data? data
local function packageFetch(_, mediaType, name, options)
    validateMediaType(mediaType, "MediaKit:Fetch", 3)
    validateName(name, "MediaKit:Fetch name", 3)
    local anyScript = readAnyScript(options, "MediaKit:Fetch", 3)
    local entry = findUsableEntry(mediaType, name, anyScript)
    if entry == nil then
        return nil
    end
    return entry.data
end

---Whether `Fetch` with the same arguments would return data.
---@param _ MediaKit
---@param mediaType MediaKit.MediaType
---@param name string
---@param options MediaKit.LookupOptions?
---@return boolean
local function packageHas(_, mediaType, name, options)
    validateMediaType(mediaType, "MediaKit:Has", 3)
    validateName(name, "MediaKit:Has name", 3)
    local anyScript = readAnyScript(options, "MediaKit:Has", 3)
    return findUsableEntry(mediaType, name, anyScript) ~= nil
end

---Return the names of `mediaType`, sorted with `<`.
---
---The array is cached and shared by every caller: treat it as read-only. It
---is rebuilt, as a new array, only after a registration of that type (or, for
---fonts, when the client's script changed). Fonts are filtered to the client's
---script unless `options.anyScript`.
---@param _ MediaKit
---@param mediaType MediaKit.MediaType
---@param options MediaKit.LookupOptions?
---@return string[] names
local function packageList(_, mediaType, options)
    validateMediaType(mediaType, "MediaKit:List", 3)
    local anyScript = readAnyScript(options, "MediaKit:List", 3)
    local record = types[mediaType]
    if mediaType ~= "font" or anyScript then
        return currentAllList(record)
    end
    return currentClientList(record)
end

---Connect `callback` to every entry added to `mediaType` from now on,
---whatever its origin. It receives `(mediaType, name, data)`. The connection
---belongs to the caller; a listener error propagates to whoever registered.
---@param _ MediaKit
---@param mediaType MediaKit.MediaType
---@param callback MediaKit.RegisteredListener
---@return SignalKit.Connection connection
local function packageOnRegistered(_, mediaType, callback)
    validateMediaType(mediaType, "MediaKit:OnRegistered", 3)
    if type(callback) ~= "function" then
        error("MediaKit:OnRegistered callback must be a function", 2)
    end
    return types[mediaType].signal:Connect(callback)
end

---Return `consumerName`'s defaults object, the same one on every call.
---@param _ MediaKit
---@param consumerName string
---@return MediaKit.Defaults defaults
local function packageDefaults(_, consumerName)
    validateName(consumerName, "MediaKit:Defaults consumerName", 3)
    local defaults = consumers[consumerName]
    if defaults ~= nil then
        return defaults
    end
    local consumerCount = rawget(state, "consumerCount")
    local maxConsumers = rawget(sharedLimits, "maxConsumers")
    if maxConsumers ~= UNBOUNDED and consumerCount >= maxConsumers then
        error("MediaKit:Defaults refuses more than " .. maxConsumers .. " consumers", 2)
    end
    defaults = setmetatable({
        _schema = DEFAULTS_SCHEMA,
        _names = {},
    }, DEFAULTS_METATABLE)
    consumers[consumerName] = defaults
    rawset(state, "consumerCount", consumerCount + 1)
    return defaults
end

---Adopt every LibSharedMedia entry of the five types it shares with MediaKit
---as read-only entries, and follow its later registrations.
---
---Returns `true` and the number of entries added by this call, or
---`false, "absent"` without LibStub or LibSharedMedia-3.0. Idempotent.
---@return boolean found
---@return integer|"absent" addedOrReason
local function packageAdoptLibSharedMedia()
    local library = findLibSharedMedia()
    if library == nil then
        return false, "absent"
    end
    libSharedMedia.adoptSource = library
    subscribe(library)
    local added = 0
    for index = 1, #LIBSHAREDMEDIA_TYPES do
        added = added + adoptType(library, LIBSHAREDMEDIA_TYPES[index])
    end
    return true, added
end

---Register every MediaKit entry of the five shared types into
---LibSharedMedia, skipping names it already has and entries adopted from it,
---and mirror later registrations the same way.
---
---Returns `true` and the number of entries mirrored by this call, or
---`false, "absent"` without LibStub or LibSharedMedia-3.0. Idempotent.
---@return boolean found
---@return integer|"absent" mirroredOrReason
local function packageMirrorToLibSharedMedia()
    local library = findLibSharedMedia()
    if library == nil then
        return false, "absent"
    end
    libSharedMedia.mirrorTarget = library
    local mirrored = 0
    for typeIndex = 1, #LIBSHAREDMEDIA_TYPES do
        local mediaType = LIBSHAREDMEDIA_TYPES[typeIndex]
        local record = types[mediaType]
        -- The cached array is never modified, so re-entrant registrations
        -- fired from LibSharedMedia's callback cannot disturb this walk.
        local names = currentAllList(record)
        for index = 1, #names do
            local name = names[index]
            local entry = record.entries[name]
            if
                entry.origin ~= ORIGIN_ADOPTED
                and mirrorEntry(mediaType, name, entry.data, entry.scriptMask)
            then
                mirrored = mirrored + 1
            end
        end
    end
    return true, mirrored
end

---Whether `data` is a FileDataID (a finite positive integer) rather than a
---path. A secret value is never one.
---@param _ MediaKit
---@param data any
---@return boolean
local function packageIsFileDataID(_, data)
    return isFileDataID(data)
end

---@param receiver any the table the method was called on
---@param label string public method name, used in the argument error
---@param level integer stack level the failure is reported at
local function validateFacade(receiver, label, level)
    if receiver ~= MediaKit then
        error(label .. " must be called on the MediaKit facade; use " .. label .. "(...)", level)
    end
end

---Refuse one `SetLimits` value. `maxEntriesPerType` has a ceiling and refuses
---`UNBOUNDED`; `maxConsumers` accepts any positive integer or `UNBOUNDED`.
---@param name string a recognised limit name
---@param value any
---@param level integer stack level the failure is reported at
local function validateLimitValue(name, value, level)
    local label = "MediaKit:SetLimits limits." .. name
    if isSecret(value) then
        error(label .. " must not be a secret value", level)
    end
    if name == "maxEntriesPerType" then
        if value == UNBOUNDED then
            error(label .. " cannot be MediaKit.UNBOUNDED: " .. ENTRIES_UNBOUNDED_REASON, level)
        end
        if not isPositiveInteger(value) or value > MAX_ENTRIES_PER_TYPE_CEILING then
            error(label .. " must be an integer from 1 to " .. MAX_ENTRIES_PER_TYPE_CEILING, level)
        end
    elseif value ~= UNBOUNDED and not isPositiveInteger(value) then
        error(label .. " must be a positive integer or MediaKit.UNBOUNDED", level)
    end
end

---Refuse a `SetLimits` argument before any limit changes, so a call with one
---bad entry leaves every limit as it was.
---@param limits any
---@param level integer stack level the failure is reported at
local function validateLimitUpdate(limits, level)
    if type(limits) ~= "table" then
        error("MediaKit:SetLimits limits must be a table", level)
    end
    for key, value in next, limits do
        if isSecret(key) then
            error("MediaKit:SetLimits limits must not have a secret key", level)
        end
        if type(key) ~= "string" or (key ~= "maxEntriesPerType" and key ~= "maxConsumers") then
            error(
                "MediaKit:SetLimits limits." .. describeKey(key) .. " is not a recognised limit",
                level
            )
        end
        validateLimitValue(key, value, level + 1)
    end
end

---Change any subset of the shared limits. Affects every consumer.
---
---The whole table is checked before anything changes. Lowering a limit below
---what already exists removes nothing: further entries are refused with
---`"full"`, further consumers raise, until the count is under the limit.
---@param self MediaKit
---@param limits MediaKit.Limits
local function packageSetLimits(self, limits)
    validateFacade(self, "MediaKit:SetLimits", 3)
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
---@param self MediaKit
---@return MediaKit.Limits limits
local function packageGetLimits(self)
    validateFacade(self, "MediaKit:GetLimits", 3)
    return {
        maxEntriesPerType = rawget(sharedLimits, "maxEntriesPerType"),
        maxConsumers = rawget(sharedLimits, "maxConsumers"),
    }
end

-- Commit ---------------------------------------------------------------------

rawset(dispatch, "mirrorEntry", mirrorEntry)
rawset(dispatch, "onLibSharedMediaRegistered", onLibSharedMediaRegistered)

rawset(DefaultsPrototype, "Set", defaultsSet)
rawset(DefaultsPrototype, "Get", defaultsGet)
rawset(DEFAULTS_METATABLE, "__index", DefaultsPrototype)
-- `__metatable` hides the prototype and is what `validateDefaults` recognises.
rawset(DEFAULTS_METATABLE, "__metatable", "MediaKit.Defaults")

rawset(MediaKit, "API", API_GENERATION)
rawset(MediaKit, "REVISION", IMPLEMENTATION_REVISION)
rawset(MediaKit, "MAX_ENTRIES_PER_TYPE", MAX_ENTRIES_PER_TYPE)
rawset(MediaKit, "UNBOUNDED", UNBOUNDED)
rawset(MediaKit, "Register", packageRegister)
rawset(MediaKit, "Fetch", packageFetch)
rawset(MediaKit, "Has", packageHas)
rawset(MediaKit, "List", packageList)
rawset(MediaKit, "OnRegistered", packageOnRegistered)
rawset(MediaKit, "Defaults", packageDefaults)
rawset(MediaKit, "AdoptLibSharedMedia", packageAdoptLibSharedMedia)
rawset(MediaKit, "MirrorToLibSharedMedia", packageMirrorToLibSharedMedia)
rawset(MediaKit, "IsFileDataID", packageIsFileDataID)
rawset(MediaKit, "SetLimits", packageSetLimits)
rawset(MediaKit, "GetLimits", packageGetLimits)

if previousRevision == nil then
    -- The client's own media, once per session. An upgrade inherits them.
    for index = 1, #BUILTIN_MEDIA do
        local builtin = BUILTIN_MEDIA[index]
        registerEntry(builtin[1], builtin[2], builtin[3], ALL_SCRIPTS, ORIGIN_BUILTIN)
    end
    local cyrillicClient = resolveClientScript() == "cyrillic"
    local fontScripts = SCRIPT_BITS.latin
    if cyrillicClient then
        fontScripts = SCRIPT_BITS.latin + SCRIPT_BITS.cyrillic
    end
    for index = 1, #BUILTIN_FONTS do
        local font = BUILTIN_FONTS[index]
        local path = cyrillicClient and font.cyrillic or font.western
        registerEntry("font", font.name, path, fontScripts, ORIGIN_BUILTIN)
    end
end

rawset(state, "runtimeRevision", IMPLEMENTATION_REVISION)

if not validatePublicSurface(MediaKit) or not validateCurrentState(MediaKit) then
    error("MoltenCodes MediaKit package state is corrupted or incomplete", 2)
end
for index = 1, #DEFAULTS_METHODS do
    if type(rawget(DefaultsPrototype, DEFAULTS_METHODS[index])) ~= "function" then
        error("MoltenCodes MediaKit package state is corrupted or incomplete", 2)
    end
end

return MediaKit
