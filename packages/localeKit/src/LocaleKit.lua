-- MoltenCodes LocaleKit
--
-- Translations for World of Warcraft addons. Each addon registers its strings
-- per locale in translation files; a file for a locale the running client does
-- not need is skipped before it builds anything, so a twenty-language addon
-- costs one table on any client. Reading a key nobody translated returns the
-- key itself, reported once through the host error handler, and the keys read
-- but never defined are available as a coverage report. `Format` understands
-- indexed specifiers (`%2$s`) so a translator can reorder arguments.
--
-- LocaleKit is pure Lua apart from three optional host facilities, all read at
-- call time: `GetLocale` (without it the client locale is `enUS`),
-- `geterrorhandler` (without it reports are printed) and `issecretvalue`
-- (without it nothing is secret).
--
-- Contents
-- --------
--   Constants ............. identity, limits, option keys, method lists
--   Public types .......... LuaCATS declarations for the published surface
--   Dependencies .......... Registry and the host facilities
--   Validation ............ public-surface and shared-state predicates
--   Bootstrap ............. Registry registration and inherited state
--   Argument checks ....... names, locale codes, option tables
--   Client locale ......... GetLocale, enGB folding, the override
--   Reporting ............. the host error handler and its fallback
--   Addon records ......... the per-addon translation table and bookkeeping
--   Write proxies ......... the tables translation files write through
--   Read tables ........... the missing-key behaviour per mode
--   Formatting ............ indexed and sequential specifiers
--   Package public API .... the facade published through Registry
--   Commit ................ metatable and facade assignment, self-check
--
-- Layout and invariants are described in `docs/INTERNALS.md`.

-- Constants ------------------------------------------------------------------

local PACKAGE_NAME = "localeKit"
local API_GENERATION = 1
local IMPLEMENTATION_REVISION = 1
local REQUIRED_REGISTRY_API = 2
local STATE_SCHEMA = 1

-- Every addon record carries the layout it was built with, so a later revision
-- that changes the layout can upgrade old records lazily.
local RECORD_SCHEMA = 1

-- The locale a client without `GetLocale` is treated as, and the one `enGB`
-- clients are folded to: the game ships one English and reports British
-- clients separately only for historical reasons.
local FALLBACK_LOCALE = "enUS"
local FOLDED_LOCALES = { enGB = "enUS" }

-- Every client locale code is two lower-case letters and two upper-case
-- letters. Checking the shape catches `"dede"` and `"de"` at the caller instead
-- of silently registering a locale no client will ever ask for.
local LOCALE_CODE_PATTERN = "^%l%l%u%u$"

-- A missing key is stored as its own value so its cost is paid once. A caller
-- that indexes the read table with unbounded runtime data (a unit name, say)
-- would otherwise grow it without limit, so bookkeeping stops at this many
-- missing keys per addon; later ones still read as the key.
local MAX_MISSING_KEYS = 1024

local MISSING_MODES = { report = true, silent = true, raw = true }
local DEFAULT_MISSING_MODE = "report"

-- The complete set of fields each option table accepts. File-local constants
-- keep option validation allocation-free.
local NEW_LOCALE_OPTION_KEYS = { isDefault = true }
local GET_LOCALE_OPTION_KEYS = { missing = true }

-- The published surface, listed once so the public-surface predicate reads as
-- a checklist instead of a long boolean expression.
local FACADE_METHODS = { "NewLocale", "GetLocale", "MissingKeys", "Format", "SetLocaleOverride" }

-- One `%` specifier: an optional argument index or width, an optional `$`
-- that makes the digits an index, flags/width/precision, and the conversion.
-- The conversion is `.?` so an unsupported or truncated specifier is still
-- matched, and refused by name, rather than copied into the output.
local FORMAT_PATTERN = "%%(%d*)(%$?)([-+ #0]*%d*%.?%d*)(.?)"

-- Public types ---------------------------------------------------------------

---Option table accepted by `LocaleKit:NewLocale`.
---@class LocaleKit.NewLocaleOptions
---@field isDefault boolean? Marks the fallback locale every client loads. Its proxy never overwrites a key already present.

---Option table accepted by `LocaleKit:GetLocale`.
---@class LocaleKit.GetLocaleOptions
---@field missing "report"|"silent"|"raw"? What reading an undefined key does. Defaults to `"report"`; fixed by the first `GetLocale` for the addon.

---The table a translation file writes through. `L["key"] = "text"` stores a
---translation; `L["key"] = true` stores the key as its own text.
---@alias LocaleKit.WriteProxy table<string, string|true>

---The table an addon reads its strings from.
---@alias LocaleKit.Strings table<string, string>

---The LocaleKit package facade published through Registry.
---@class LocaleKit
---@field API integer Public API generation.
---@field REVISION integer Compatible implementation revision.
---@field NewLocale fun(self: LocaleKit, addonName: string, locale: string, options: LocaleKit.NewLocaleOptions?): LocaleKit.WriteProxy?
---@field GetLocale fun(self: LocaleKit, addonName: string, options: LocaleKit.GetLocaleOptions?): LocaleKit.Strings
---@field MissingKeys fun(self: LocaleKit, addonName: string): string[]
---@field Format fun(self: LocaleKit, template: string, ...: any): string
---@field SetLocaleOverride fun(self: LocaleKit, locale: string?)

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
    error("MoltenCodes LocaleKit requires Registry API 2 to be loaded first", 2)
end

local bootstrapPackage = rawget(Registry, "Bootstrap")
if type(bootstrapPackage) ~= "function" then
    error("MoltenCodes LocaleKit requires a valid Registry API 2 facade", 2)
end

local stringFormat = string.format
local stringGsub = string.gsub
local tableSort = table.sort

-- Validation -----------------------------------------------------------------

---Whether `implementation` exposes the complete LocaleKit API 1 surface.
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

---Whether `currentState` has the fields every API 1 revision shares.
---@param currentState any
---@return boolean
local function validateStateBase(currentState)
    if type(currentState) ~= "table" or rawget(currentState, "schema") ~= STATE_SCHEMA then
        return false
    end
    local override = rawget(currentState, "localeOverride")
    return type(rawget(currentState, "runtimeRevision")) == "number"
        and type(rawget(currentState, "addons")) == "table"
        and type(rawget(currentState, "recordByStrings")) == "table"
        and type(rawget(currentState, "proxyRecords")) == "table"
        and type(rawget(currentState, "translatedProxyMetatable")) == "table"
        and type(rawget(currentState, "defaultProxyMetatable")) == "table"
        and type(rawget(currentState, "reportMetatable")) == "table"
        and type(rawget(currentState, "silentMetatable")) == "table"
        and (override == false or type(override) == "string")
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
-- and register this one. What stays here is what only LocaleKit can answer.
local LocaleKit, previousRevision, selected = bootstrapPackage(Registry, {
    package = PACKAGE_NAME,
    api = API_GENERATION,
    revision = IMPLEMENTATION_REVISION,
    label = "MoltenCodes LocaleKit",
    validatePublicSurface = validatePublicSurface,
    validateState = validateCurrentState,
})

if LocaleKit == nil then
    -- An equal or newer compatible revision already owns the shared package table.
    return selected
end

local state = rawget(LocaleKit, "_state")

if previousRevision == nil then
    if state ~= nil then
        error("MoltenCodes LocaleKit package state is corrupted or incomplete", 2)
    end

    state = {
        schema = STATE_SCHEMA,
        runtimeRevision = 0,
        -- Addon name to addon record. Records live for the session: a locale
        -- table is what an addon reads its strings from until `/reload`.
        addons = {},
        -- An addon's read table to its record, for the read metatables.
        recordByStrings = {},
        -- A write proxy to its addon record. Weak-keyed, because a proxy is
        -- normally dropped as soon as its translation file has run.
        proxyRecords = setmetatable({}, { __mode = "k" }),
        -- Shared metatables. Their functions are rewritten by every loading
        -- revision, so proxies and read tables an older copy created run the
        -- newer behaviour.
        translatedProxyMetatable = {},
        defaultProxyMetatable = {},
        reportMetatable = {},
        silentMetatable = {},
        -- The translator's override, or `false`.
        localeOverride = false,
    }
    rawset(LocaleKit, "_state", state)
elseif not validateStateBase(state) then
    error("MoltenCodes LocaleKit package state is corrupted or incomplete", 2)
end

local addons = rawget(state, "addons")
local recordByStrings = rawget(state, "recordByStrings")
local proxyRecords = rawget(state, "proxyRecords")
local TRANSLATED_PROXY_METATABLE = rawget(state, "translatedProxyMetatable")
local DEFAULT_PROXY_METATABLE = rawget(state, "defaultProxyMetatable")
local REPORT_METATABLE = rawget(state, "reportMetatable")
local SILENT_METATABLE = rawget(state, "silentMetatable")

-- Argument checks ------------------------------------------------------------
--
-- Argument validation raises with an explicit stack level so the reported
-- position is the line that called the public method, never a line inside
-- LocaleKit. `level` is always the value `error` needs *inside the function
-- that receives it*, so every further hop towards `error` adds exactly one.

---@param value any
---@param label string argument description, used in the argument error
---@param level integer stack level the failure is reported at
local function validateNonEmptyString(value, label, level)
    if type(value) ~= "string" or value == "" then
        error(label .. " must be a non-empty string", level)
    end
end

---@param value any
---@param label string argument description, used in the argument error
---@param level integer stack level the failure is reported at
local function validateLocaleCode(value, label, level)
    if type(value) ~= "string" or value:match(LOCALE_CODE_PATTERN) == nil then
        error(label .. ' must be a client locale code such as "deDE"', level)
    end
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
            -- `tostring` could run a caller's `__tostring`; name other keys by type.
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

-- Client locale --------------------------------------------------------------

---Return `locale` with `enGB` folded to `enUS`.
---@param locale string
---@return string
local function foldLocale(locale)
    return FOLDED_LOCALES[locale] or locale
end

---The locale this client runs in: the translator's override when one is set,
---otherwise the host's `GetLocale()`, folded. Read at call time so a host stub
---or override installed after LocaleKit loaded is honoured.
---@return string locale
local function resolveClientLocale()
    local override = rawget(state, "localeOverride")
    if override ~= false then
        return override
    end

    -- GetLocale is a World of Warcraft client API reachable only through the global table.
    -- selene: allow(global_usage)
    local getLocale = rawget(_G, "GetLocale")
    if type(getLocale) ~= "function" then
        return FALLBACK_LOCALE
    end
    local locale = getLocale()
    if type(locale) ~= "string" or locale:match(LOCALE_CODE_PATTERN) == nil then
        return FALLBACK_LOCALE
    end
    return foldLocale(locale)
end

-- Reporting ------------------------------------------------------------------

---Hand a diagnostic to the host error handler, or print it without one.
---@param message string
local function report(message)
    -- geterrorhandler is a World of Warcraft client API reachable only through the global table.
    -- selene: allow(global_usage)
    local getErrorHandler = rawget(_G, "geterrorhandler")
    if type(getErrorHandler) == "function" then
        local handler = getErrorHandler()
        if type(handler) == "function" then
            handler(message)
            return
        end
    end

    -- Outside a WoW client there is no error handler to report through.
    -- Printing is what the client's own default handler does, and staying
    -- silent would turn a missing translation into an invisible one.
    print(message)
end

-- Addon records --------------------------------------------------------------
--
-- One record per addon name, created by the first `NewLocale` the client
-- needs. Every field exists from construction, so no later write rehashes it.

---@class LocaleKit.Record
---@field schema integer
---@field name string
---@field locale string the client locale this addon's strings are for, fixed at creation
---@field defaultLocale string|false the locale registered with `isDefault`
---@field strings table<string, string> the read table
---@field missing table<string, true> keys read but never defined
---@field missingCount integer
---@field capReported boolean whether the missing-key cap has been reported
---@field mode string|false the missing-key mode fixed by the first `GetLocale`

---@param addonName string
---@param locale string
---@return LocaleKit.Record
local function newRecord(addonName, locale)
    local strings = {}
    local record = {
        schema = RECORD_SCHEMA,
        name = addonName,
        locale = locale,
        defaultLocale = false,
        strings = strings,
        missing = {},
        missingCount = 0,
        capReported = false,
        mode = false,
    }
    addons[addonName] = record
    recordByStrings[strings] = record
    return record
end

---Forget that `key` was missing, because a translation file has now defined it.
---@param record LocaleKit.Record
---@param key string
local function clearMissing(record, key)
    if record.missing[key] == true then
        record.missing[key] = nil
        record.missingCount = record.missingCount - 1
    end
end

-- Write proxies --------------------------------------------------------------
--
-- A proxy is an empty table per `NewLocale` call whose metatable routes every
-- write to its addon's read table. Nothing is ever stored in the proxy itself,
-- so `__newindex` sees every assignment. Two shared metatables encode the two
-- write rules; `proxyRecords` maps a proxy to its addon.

-- A table carrying a proxy metatable that `NewLocale` did not hand out. The
-- metatables are protected by `__metatable`, so only the debug library can
-- build one; it is still refused at the assignment line rather than failing
-- inside LocaleKit.
local FOREIGN_PROXY_MESSAGE =
    "LocaleKit translation target is not a proxy returned by LocaleKit:NewLocale"

---Refuse an assignment that is not `L["non-empty string"] = "text" | true`
---and return the text to store. Level 3 is the assignment line: this
---function, the `__newindex` metamethod, then the line that assigned.
---@param key any
---@param value any
---@return string text
local function translationText(key, value)
    if type(key) ~= "string" or key == "" then
        error("LocaleKit translation key must be a non-empty string", 3)
    end
    if value == true then
        return key
    end
    if type(value) ~= "string" then
        error('LocaleKit translation "' .. key .. '" must be a string or true', 3)
    end
    return value
end

---`__newindex` of a proxy for the client's own locale: always writes, so a
---translation replaces a default that loaded first.
---@param proxy table
---@param key any
---@param value any
local function writeTranslated(proxy, key, value)
    local record = proxyRecords[proxy]
    if record == nil then
        error(FOREIGN_PROXY_MESSAGE, 2)
    end
    local text = translationText(key, value)
    rawset(record.strings, key, text)
    clearMissing(record, key)
end

---`__newindex` of a proxy for the default locale: writes only a key that is
---absent (or holds its own name because it was read while missing), so the
---default never replaces a translation that loaded first.
---@param proxy table
---@param key any
---@param value any
local function writeDefault(proxy, key, value)
    local record = proxyRecords[proxy]
    if record == nil then
        error(FOREIGN_PROXY_MESSAGE, 2)
    end
    local text = translationText(key, value)
    local strings = record.strings
    if rawget(strings, key) == nil or record.missing[key] == true then
        rawset(strings, key, text)
        clearMissing(record, key)
    end
end

---`__index` of every proxy: the stored text or `nil`, never an error, so a
---translation file may check what it has already written.
---@param proxy table
---@param key any
---@return string|nil
local function readThroughProxy(proxy, key)
    local record = proxyRecords[proxy]
    if record == nil then
        return nil
    end
    return rawget(record.strings, key)
end

-- Read tables ----------------------------------------------------------------

---Answer a read of a key the table does not hold. The key is stored as its
---own value, so the next read is a plain table read and the report happens
---once. Past `MAX_MISSING_KEYS` the key is returned without being stored.
---@param strings table
---@param key any
---@param reports boolean
---@return string|nil
local function readMissing(strings, key, reports)
    -- A secret (Retail 12.x) raises when used as a table key or concatenated
    -- into the report, so it is handed back untouched: not stored, recorded
    -- or reported. The probe is looked up at call time; without it nothing
    -- is secret.
    -- issecretvalue is a World of Warcraft client API reachable only through the global table.
    -- selene: allow(global_usage)
    local isSecretValue = rawget(_G, "issecretvalue")
    if type(isSecretValue) == "function" and isSecretValue(key) then
        return key
    end
    if type(key) ~= "string" then
        return nil
    end
    local record = recordByStrings[strings]
    if record == nil then
        return key
    end

    if record.missingCount >= MAX_MISSING_KEYS then
        if reports and not record.capReported then
            record.capReported = true
            report(
                "LocaleKit: "
                    .. record.name
                    .. " has more than "
                    .. MAX_MISSING_KEYS
                    .. " missing translations; further ones are neither recorded nor reported"
            )
        end
        return key
    end

    rawset(strings, key, key)
    record.missing[key] = true
    record.missingCount = record.missingCount + 1
    if reports then
        report(
            'LocaleKit: missing translation "'
                .. key
                .. '" for '
                .. record.name
                .. " ("
                .. record.locale
                .. ")"
        )
    end
    return key
end

---`__index` of a read table in `"report"` mode.
---@param strings table
---@param key any
---@return string|nil
local function readMissingReported(strings, key)
    return readMissing(strings, key, true)
end

---`__index` of a read table in `"silent"` mode.
---@param strings table
---@param key any
---@return string|nil
local function readMissingSilently(strings, key)
    return readMissing(strings, key, false)
end

-- Formatting -----------------------------------------------------------------
--
-- `Format` runs one `string.gsub` over the template with a single file-level
-- replacement function. The arguments are staged in a reused array rather
-- than captured by a closure, so a call allocates no table and no function;
-- the replacement function only calls `string.format` on strings and numbers,
-- which runs no metamethod and so cannot re-enter `Format`.

local formatArguments = {}
local formatArgumentCount = 0
local formatNextSequential = 0

---Drop the staged arguments, so the array retains nothing between calls.
local function clearFormatArguments()
    for index = 1, formatArgumentCount do
        formatArguments[index] = nil
    end
    formatArgumentCount = 0
end

---Raise a template failure at the caller of `Format`: this function, the
---replacement function, `string.gsub`, `Format`, then the caller.
---@param message string
local function failFormat(message)
    clearFormatArguments()
    error("LocaleKit:Format " .. message, 5)
end

---Replace one specifier. Called by `string.gsub` with the four captures of
---`FORMAT_PATTERN`.
---@param digits string
---@param dollar string
---@param flags string
---@param conversion string
---@return string
local function replaceSpecifier(digits, dollar, flags, conversion)
    if conversion == "%" and digits == "" and dollar == "" and flags == "" then
        return "%"
    end
    if conversion ~= "s" and conversion ~= "d" and conversion ~= "f" then
        failFormat(
            'template has an unsupported specifier "%'
                .. digits
                .. dollar
                .. flags
                .. conversion
                .. '"'
        )
    end

    local index
    local specifier
    if dollar == "$" then
        index = tonumber(digits)
        if index == nil or index < 1 then
            failFormat("template argument indexes start at 1")
        end
        specifier = "%" .. flags .. conversion
    else
        formatNextSequential = formatNextSequential + 1
        index = formatNextSequential
        specifier = "%" .. digits .. flags .. conversion
    end

    if index > formatArgumentCount then
        failFormat(
            "template needs argument " .. index .. " but " .. formatArgumentCount .. " were given"
        )
    end

    local value = formatArguments[index]
    local valueType = type(value)
    if conversion == "s" then
        if valueType ~= "string" and valueType ~= "number" then
            failFormat("argument " .. index .. " must be a string or a number, got " .. valueType)
        end
    elseif valueType ~= "number" then
        failFormat("argument " .. index .. " must be a number, got " .. valueType)
    end
    -- The pattern admits shapes `string.format` refuses, such as a width over
    -- 99 or a repeated flag. Run it protected so those fail like every other
    -- template error: named, at the caller, with the arguments cleared.
    local formatted, text = pcall(stringFormat, specifier, value)
    if not formatted then
        failFormat(
            'template has an invalid specifier "%' .. digits .. dollar .. flags .. conversion .. '"'
        )
    end
    return text
end

-- Package public API ---------------------------------------------------------

---Start registering translations for `addonName` in `locale`.
---
---Returns a fresh write proxy when the client needs that locale (it is the
---client's locale, or `options.isDefault` marks it as the fallback), and `nil`
---otherwise, so a translation file ends at once on every other client:
---
---```lua
---local L = LocaleKit:NewLocale("MyAddon", "deDE")
---if not L then return end
---L["Hello"] = "Hallo"
---```
---@param _ LocaleKit
---@param addonName string
---@param locale string a client locale code such as `"deDE"`
---@param options LocaleKit.NewLocaleOptions?
---@return LocaleKit.WriteProxy? proxy
local function packageNewLocale(_, addonName, locale, options)
    validateNonEmptyString(addonName, "LocaleKit:NewLocale addonName", 3)
    validateLocaleCode(locale, "LocaleKit:NewLocale locale", 3)
    local isDefault = false
    if options ~= nil then
        validateOptionKeys(options, NEW_LOCALE_OPTION_KEYS, "LocaleKit:NewLocale", 3)
        local flag = rawget(options, "isDefault")
        if flag ~= nil and type(flag) ~= "boolean" then
            error("LocaleKit:NewLocale isDefault must be a boolean", 2)
        end
        isDefault = flag == true
    end

    local record = addons[addonName]
    if isDefault and record ~= nil then
        local defaultLocale = record.defaultLocale
        if defaultLocale ~= false and defaultLocale ~= locale then
            error(
                "LocaleKit:NewLocale "
                    .. addonName
                    .. " already has default locale "
                    .. defaultLocale,
                2
            )
        end
    end

    local clientLocale = record ~= nil and record.locale or resolveClientLocale()
    if not isDefault and locale ~= clientLocale then
        return nil
    end

    if record == nil then
        record = newRecord(addonName, clientLocale)
    end

    local metatable = TRANSLATED_PROXY_METATABLE
    if isDefault then
        record.defaultLocale = locale
        metatable = DEFAULT_PROXY_METATABLE
    end
    local proxy = setmetatable({}, metatable)
    proxyRecords[proxy] = record
    return proxy
end

---Return the table `addonName` reads its strings from.
---
---The table holds the default locale's strings with the client locale's on
---top. `options.missing` chooses what reading an undefined key does:
---`"report"` (the default) returns the key and reports it once through the
---host error handler, `"silent"` returns the key without the report, and
---`"raw"` returns `nil`. The first call fixes the mode; a later call naming a
---different mode raises, and a later call that names none accepts it.
---@param _ LocaleKit
---@param addonName string
---@param options LocaleKit.GetLocaleOptions?
---@return LocaleKit.Strings strings
local function packageGetLocale(_, addonName, options)
    validateNonEmptyString(addonName, "LocaleKit:GetLocale addonName", 3)
    local requested = nil
    if options ~= nil then
        validateOptionKeys(options, GET_LOCALE_OPTION_KEYS, "LocaleKit:GetLocale", 3)
        requested = rawget(options, "missing")
        if requested ~= nil and MISSING_MODES[requested] ~= true then
            error('LocaleKit:GetLocale missing must be "report", "silent" or "raw"', 2)
        end
    end

    local record = addons[addonName]
    if record == nil then
        error(
            "LocaleKit:GetLocale found no locale registered for "
                .. addonName
                .. "; load its translation files first",
            2
        )
    end

    local mode = record.mode
    if mode == false then
        mode = requested or DEFAULT_MISSING_MODE
        record.mode = mode
        if mode == "report" then
            setmetatable(record.strings, REPORT_METATABLE)
        elseif mode == "silent" then
            setmetatable(record.strings, SILENT_METATABLE)
        end
    elseif requested ~= nil and requested ~= mode then
        error(
            "LocaleKit:GetLocale "
                .. addonName
                .. ' already uses missing mode "'
                .. mode
                .. '", not "'
                .. requested
                .. '"',
            2
        )
    end
    return record.strings
end

---Return the keys `addonName` read but never defined, sorted.
---
---Allocates a new array on every call; meant for a coverage report, not a hot
---path. An unknown addon, or one in `"raw"` mode, has none.
---@param _ LocaleKit
---@param addonName string
---@return string[] keys
local function packageMissingKeys(_, addonName)
    validateNonEmptyString(addonName, "LocaleKit:MissingKeys addonName", 3)
    local keys = {}
    local record = addons[addonName]
    if record == nil then
        return keys
    end
    local count = 0
    for key in next, record.missing do
        count = count + 1
        keys[count] = key
    end
    tableSort(keys)
    return keys
end

---Format `template` with `...`, supporting `%s`, `%d`, `%f` with flags, width
---and precision (`%.2f`), indexed specifiers (`%2$s`) in any order and any
---number of times, and `%%`.
---
---Unindexed specifiers take the arguments in order, independently of indexed
---ones. `%s` takes a string or a number, `%d` and `%f` a number. A specifier
---past the last argument, an unsupported specifier, a wrong argument type or a
---secret template or argument raises at the caller. Allocates only strings,
---no tables.
---@param _ LocaleKit
---@param template string
---@param ... any
---@return string text
local function packageFormat(_, template, ...)
    if type(template) ~= "string" then
        error("LocaleKit:Format template must be a string", 2)
    end

    local count = select("#", ...)
    -- issecretvalue is a World of Warcraft client API reachable only through the global table.
    -- selene: allow(global_usage)
    local isSecretValue = rawget(_G, "issecretvalue")
    if type(isSecretValue) == "function" then
        -- A read table hands a secret key back as itself, so `Format(L[name])`
        -- can pass a secret template; `string.gsub` must never see one.
        if isSecretValue(template) then
            error("LocaleKit:Format template must not be a secret value", 2)
        end
        for index = 1, count do
            if isSecretValue((select(index, ...))) then
                error("LocaleKit:Format argument " .. index .. " must not be a secret value", 2)
            end
        end
    end

    clearFormatArguments()
    for index = 1, count do
        formatArguments[index] = (select(index, ...))
    end
    formatArgumentCount = count
    formatNextSequential = 0

    local text = stringGsub(template, FORMAT_PATTERN, replaceSpecifier)
    clearFormatArguments()
    return text
end

---Make every addon registered from now on use `locale` instead of the
---client's. For translators testing a locale on another client: call it
---before the translation files load. `nil` clears it. An addon keeps the
---locale it was registered with.
---@param _ LocaleKit
---@param locale string? a client locale code, or `nil` to clear
local function packageSetLocaleOverride(_, locale)
    if locale == nil then
        rawset(state, "localeOverride", false)
        return
    end
    validateLocaleCode(locale, "LocaleKit:SetLocaleOverride locale", 3)
    rawset(state, "localeOverride", foldLocale(locale))
end

-- Commit ---------------------------------------------------------------------

-- `__metatable` hides the shared metatables from `getmetatable` and makes
-- `setmetatable` refuse to replace them, so a caller can neither forge a proxy
-- nor detach a read table from its missing-key behaviour.
rawset(TRANSLATED_PROXY_METATABLE, "__metatable", "LocaleKit.WriteProxy")
rawset(DEFAULT_PROXY_METATABLE, "__metatable", "LocaleKit.WriteProxy")
rawset(REPORT_METATABLE, "__metatable", "LocaleKit.Strings")
rawset(SILENT_METATABLE, "__metatable", "LocaleKit.Strings")
rawset(TRANSLATED_PROXY_METATABLE, "__newindex", writeTranslated)
rawset(TRANSLATED_PROXY_METATABLE, "__index", readThroughProxy)
rawset(DEFAULT_PROXY_METATABLE, "__newindex", writeDefault)
rawset(DEFAULT_PROXY_METATABLE, "__index", readThroughProxy)
rawset(REPORT_METATABLE, "__index", readMissingReported)
rawset(SILENT_METATABLE, "__index", readMissingSilently)

rawset(LocaleKit, "API", API_GENERATION)
rawset(LocaleKit, "REVISION", IMPLEMENTATION_REVISION)
rawset(LocaleKit, "NewLocale", packageNewLocale)
rawset(LocaleKit, "GetLocale", packageGetLocale)
rawset(LocaleKit, "MissingKeys", packageMissingKeys)
rawset(LocaleKit, "Format", packageFormat)
rawset(LocaleKit, "SetLocaleOverride", packageSetLocaleOverride)

rawset(state, "runtimeRevision", IMPLEMENTATION_REVISION)

if not validatePublicSurface(LocaleKit) or not validateCurrentState(LocaleKit) then
    error("MoltenCodes LocaleKit package state is corrupted or incomplete", 2)
end

return LocaleKit
