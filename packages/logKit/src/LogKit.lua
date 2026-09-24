-- MoltenCodes LogKit
--
-- Levelled, structured logging for addons and Kits. Every addon owns one
-- logger with `Trace`, `Debug`, `Info`, `Warn` and `Error` methods whose
-- arguments are formatted only when the level is enabled, a tri-state level
-- (addon override, global level, default), a bounded in-memory journal built on
-- SignalKit's journal, and sinks that receive each record: a chat frame, a
-- callback, or anything with a `Write` method.
--
-- The one path LogKit exists to keep cheap is the disabled call: a level
-- below the logger's effective level costs a receiver check and one
-- comparison, and returns before the message or its arguments are touched.
-- An enabled call formats once, truncates once and delivers to the journal and
-- every sink through one reused record table; only the formatted string is
-- allocated.
--
-- LogKit requires Registry API 2 and SignalKit API 1. CommandKit API 1
-- (`RegisterCommand`) and SettingsKit API 1 (`BindLevels`) are optional and
-- found through `Registry:Find` when those methods are called.
--
-- Contents
-- --------
--   Constants ............. identity, levels, defaults, refusal reasons
--   Public types .......... LuaCATS declarations for the published surface
--   Dependencies .......... Registry, SignalKit, the clock, host readers
--   Validation ............ public-surface and shared-state predicates
--   Bootstrap ............. registration and inherited state
--   Argument checks ....... errors reported at the caller's line
--   Levels ................ reading level arguments, effective levels
--   Formatting ............ secret-safe lazy formatting and truncation
--   Delivery .............. the journal, the record and the sinks
--   Logger methods ........ the per-level methods and Log
--   Journal ............... History and the journal ring
--   Sinks ................. AddSink, RemoveSink, ChatSink
--   Limits ................ validating and applying the shared limits
--   Command ............... the optional /log slash command
--   Persistence ........... the optional SettingsKit binding
--   Package public API .... the facade published through Registry
--   Commit ................ facade assignment and self-check

-- Constants ------------------------------------------------------------------

local PACKAGE_NAME = "logKit"
local API_GENERATION = 1
local IMPLEMENTATION_REVISION = 3
local REQUIRED_REGISTRY_API = 2
local REQUIRED_SIGNALKIT_API = 1
local OPTIONAL_COMMANDKIT_API = 1
local OPTIONAL_SETTINGSKIT_API = 1
local STATE_SCHEMA = 1

-- The levels, in order of severity. A message is delivered when its level is
-- at least the logger's effective level; `off` is a level only for settings,
-- so no message level reaches it.
local LEVEL_TRACE = 1
local LEVEL_DEBUG = 2
local LEVEL_INFO = 3
local LEVEL_WARN = 4
local LEVEL_ERROR = 5
local LEVEL_OFF = 6
local LEVEL_NAMES = { "trace", "debug", "info", "warn", "error", "off" }
local LEVEL_VALUES = {
    trace = LEVEL_TRACE,
    debug = LEVEL_DEBUG,
    info = LEVEL_INFO,
    warn = LEVEL_WARN,
    error = LEVEL_ERROR,
    off = LEVEL_OFF,
}
local LEVEL_LIST_TEXT = "trace, debug, info, warn, error, off"

-- What every logger uses until an addon override or a global level is set.
local DEFAULT_LEVEL = LEVEL_WARN

-- The journal is a preallocated ring, so its capacity must be a size:
-- `UNBOUNDED` is refused, and the ceiling keeps one `SetLimits` call from
-- allocating without bound. Both numbers follow the rule every Kit applies to
-- a preallocated ring and match SignalKit's own journal bound.
local DEFAULT_JOURNAL_CAPACITY = 1024
local MAX_JOURNAL_CAPACITY_CEILING = 65536

-- Sinks are the consumers' own registrations and are removed by handle, so
-- the bound may be lifted with `UNBOUNDED`.
local DEFAULT_MAX_SINKS = 16

-- A delivered message longer than this, in bytes, is cut and marked. The
-- floor leaves room for the marker and a few bytes of text.
local DEFAULT_MAX_MESSAGE_LENGTH = 1024
local MIN_MESSAGE_LENGTH = 16
local TRUNCATION_MARKER = "..."

-- Loggers live for the session because callers hold them, so the bound is
-- what keeps code that builds addon names from data from growing the package
-- state without limit.
local DEFAULT_MAX_LOGGERS = 256

-- Format arguments are staged into one reused table before `string.format`
-- sees them, so a secret can be replaced. Staging past a fixed width is
-- quadratic in the width (`select` walks the list once per argument), so the
-- width is a ceiling with a reason, like SignalKit's journal argument bound.
local MAX_FORMAT_ARGUMENTS = 16

-- What replaces a secret format argument. A secret must never reach
-- `string.format`, `tostring` or `..`, because the result would be secret too.
local SECRET_PLACEHOLDER = "<secret>"

-- The limits `SetLimits` accepts, in the order `GetLimits` reports them.
local LIMIT_NAMES = { "journalCapacity", "maxSinks", "maxMessageLength", "maxLoggers" }
local LIMIT_NAME_SET = {
    journalCapacity = true,
    maxSinks = true,
    maxMessageLength = true,
    maxLoggers = true,
}

-- Refusal reasons. Plain strings, so a caller compares them without importing
-- anything; the API documentation lists each one.
local REASON_CAPPED = "capped"
local REASON_FULL = "full"
local REASON_ABSENT = "absent"
local REASON_UNAVAILABLE = "unavailable"

-- Where a logger's effective level comes from, as `GetLevel` reports it.
local SOURCE_ADDON = "addon"
local SOURCE_GLOBAL = "global"
local SOURCE_DEFAULT = "default"

-- The slash command `RegisterCommand` registers, and the key under which the
-- global level is persisted by `BindLevels`.
local COMMAND_NAME = "log"
local GLOBAL_LEVEL_KEY = "*"
local PERSISTED_SECTION = "logLevels"
local CLEAR_LEVEL_WORD = "default"

-- Chat colours per level, as `|cAARRGGBB` escapes the chat frame renders.
local LEVEL_COLOURS = {
    "|cff9d9d9d", -- trace: grey
    "|cff6699ff", -- debug: blue
    "|cffffffff", -- info: white
    "|cffffa500", -- warn: orange
    "|cffff4040", -- error: red
}

-- Public types ---------------------------------------------------------------
--
-- LogKit publishes its methods by writing them onto Registry-owned tables, so
-- the editor-facing contract is declared here rather than inferred.

---A level name. `"off"` is accepted by the level setters only.
---@alias LogKit.LevelName "trace"|"debug"|"info"|"warn"|"error"|"off"

---A level: its name, or its numeric value from `LogKit.LEVELS`.
---@alias LogKit.Level LogKit.LevelName|integer

---Why a LogKit call declined to act. See docs/API.md for each value.
---@alias LogKit.Reason "capped"|"full"|"absent"|"unavailable"|"taken"|"emote"

---Where a logger's effective level comes from.
---@alias LogKit.LevelSource "addon"|"global"|"default"

---The numeric value of every level name, read-only: `trace` 1, `debug` 2,
---`info` 3, `warn` 4, `error` 5, `off` 6. Writing to it raises.
---@class LogKit.Levels
---@field trace integer 1
---@field debug integer 2
---@field info integer 3
---@field warn integer 4
---@field error integer 5
---@field off integer 6

---One delivered message, handed to every sink. The table is reused for the
---next message: read it during the call and copy what you keep.
---@class LogKit.Record
---@field addon string The addon name the logger was created for.
---@field level integer The message level, a `LogKit.LEVELS` value.
---@field levelName LogKit.LevelName The message level's name.
---@field message string The formatted, truncated message.
---@field time number|false `GetTimePreciseSec()` when delivered, or `false` on a host without the clock.

---A sink given as a function.
---@alias LogKit.SinkFunction fun(record: LogKit.Record)

---A sink given as a table: `sink:Write(record)` receives every message.
---@class LogKit.SinkTable
---@field Write fun(self: LogKit.SinkTable, record: LogKit.Record)

---What `AddSink` accepts.
---@alias LogKit.Sink LogKit.SinkFunction|LogKit.SinkTable

---The handle `AddSink` returns; pass it to `RemoveSink`.
---@class LogKit.SinkHandle
---@field package write function|false The function sink, or `false` for a table sink; private to this file.
---@field package receiver table|false The table sink, whose `Write` is looked up per call, or `false`.
---@field package active boolean `false` once removed.

---One addon's logger. Obtain it with `LogKit:ForAddon(addonName)`.
---@class LogKit.Logger
---@field Trace fun(self: LogKit.Logger, message: string, ...: any)
---@field Debug fun(self: LogKit.Logger, message: string, ...: any)
---@field Info fun(self: LogKit.Logger, message: string, ...: any)
---@field Warn fun(self: LogKit.Logger, message: string, ...: any)
---@field Error fun(self: LogKit.Logger, message: string, ...: any)
---@field Log fun(self: LogKit.Logger, level: LogKit.Level, message: string, ...: any)
---@field IsEnabled fun(self: LogKit.Logger, level: LogKit.Level): boolean
---@field SetLevel fun(self: LogKit.Logger, level: LogKit.Level?)
---@field GetLevel fun(self: LogKit.Logger): LogKit.LevelName, LogKit.LevelSource
---@field GetAddonName fun(self: LogKit.Logger): string
---@field package _name string Addon name; private to this file.
---@field package _effective integer Effective level, kept current by every level change.

---The shared limits. `SetLimits` accepts any subset; `GetLimits` returns all.
---@class LogKit.Limits
---@field journalCapacity integer Entries the journal keeps: an integer from 1 to 65536, at most SignalKit's `maxJournalCapacity`; default `1024`.
---@field maxSinks integer|table Most sinks at once: a positive integer or `LogKit.UNBOUNDED`; default `16`.
---@field maxMessageLength integer|table Longest delivered message in bytes: an integer of at least 16 or `LogKit.UNBOUNDED`; default `1024`.
---@field maxLoggers integer|table Most loggers one session creates: a positive integer or `LogKit.UNBOUNDED`; default `256`.

---The LogKit package facade published through Registry.
---@class LogKit
---@field API integer Public API generation.
---@field REVISION integer Compatible implementation revision.
---@field LEVELS LogKit.Levels Level name to numeric value, read-only.
---@field DEFAULT_LEVEL LogKit.LevelName `"warn"`, the level every logger starts at.
---@field DEFAULT_JOURNAL_CAPACITY integer Default of the `journalCapacity` limit (`1024`).
---@field DEFAULT_MAX_SINKS integer Default of the `maxSinks` limit (`16`).
---@field DEFAULT_MAX_MESSAGE_LENGTH integer Default of the `maxMessageLength` limit (`1024`).
---@field DEFAULT_MAX_LOGGERS integer Default of the `maxLoggers` limit (`256`).
---@field MAX_FORMAT_ARGUMENTS integer Most format arguments one call accepts (`16`).
---@field SECRET_PLACEHOLDER string What replaces a secret format argument (`"<secret>"`).
---@field UNBOUNDED table Sentinel that lifts a limit; the same table for every revision.
---@field ForAddon fun(self: LogKit, addonName: string): LogKit.Logger?, LogKit.Reason?
---@field SetGlobalLevel fun(self: LogKit, level: LogKit.Level?)
---@field GetGlobalLevel fun(self: LogKit): LogKit.LevelName?
---@field AddSink fun(self: LogKit, sink: LogKit.Sink): LogKit.SinkHandle?, LogKit.Reason?
---@field RemoveSink fun(self: LogKit, handle: LogKit.SinkHandle): boolean
---@field ChatSink fun(self: LogKit, chatFrame: table?): LogKit.SinkTable
---@field History fun(self: LogKit, addonName: string?, minimumLevel: LogKit.Level?): (fun(cursor: table, position: integer): integer?, string?, LogKit.LevelName?, string?, number|false?), table, integer
---@field RegisterCommand fun(self: LogKit): boolean, LogKit.Reason?
---@field BindLevels fun(self: LogKit, db: table?): boolean
---@field SetLimits fun(self: LogKit, limits: LogKit.Limits)
---@field GetLimits fun(self: LogKit): LogKit.Limits

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
    error("MoltenCodes LogKit requires Registry API 2 to be loaded first", 2)
end

local bootstrapPackage = rawget(Registry, "Bootstrap")
local getPackage = rawget(Registry, "Get")
if type(bootstrapPackage) ~= "function" or type(getPackage) ~= "function" then
    error("MoltenCodes LogKit requires a valid Registry API 2 facade", 2)
end

-- SignalKit owns the journal ring; LogKit adds levels and filtering on top
-- rather than writing a second ring.
local SignalKit = getPackage(Registry, "signalKit", REQUIRED_SIGNALKIT_API)
if
    type(SignalKit) ~= "table"
    or rawget(SignalKit, "API") ~= REQUIRED_SIGNALKIT_API
    or type(rawget(SignalKit, "NewJournal")) ~= "function"
    or type(rawget(SignalKit, "GetLimits")) ~= "function"
then
    error("MoltenCodes LogKit requires SignalKit API 1 to be loaded first", 2)
end

---Read a host global without triggering a metatable, or `nil`.
---@param name string
---@return any
local function readGlobal(name)
    -- Host APIs are reachable only through the global table.
    -- selene: allow(global_usage)
    return rawget(_G, name)
end

-- `GetTimePreciseSec` is the wall clock every other Kit stamps with. It is
-- optional, as it is for TimerKit and CacheKit: without it a record's `time`
-- is `false`, the way those Kits report a missing clock, rather than a value
-- from a different clock that would silently mean something else.
local nativeGetTimePreciseSec = readGlobal("GetTimePreciseSec")
if type(nativeGetTimePreciseSec) ~= "function" then
    nativeGetTimePreciseSec = nil
end

---The current clock reading in seconds, or `false` on a host without the clock.
---@return number|false
local function readClock()
    if nativeGetTimePreciseSec == nil then
        return false
    end
    return nativeGetTimePreciseSec()
end

---Whether `value` is a secret value, asking the host's `issecretvalue` at
---call time. Clients without secret values publish no probe, and nothing is
---secret there.
---@param value any
---@return boolean
local function isSecret(value)
    local probe = readGlobal("issecretvalue")
    return type(probe) == "function" and probe(value) == true
end

---Hand a failure nobody called for (a failing sink, a format error) to the
---host error handler.
---
---The failure is passed on unchanged: a sink's error value may be secret, and
---LogKit never inspects it.
---@param failure any
local function reportError(failure)
    local getErrorHandler = readGlobal("geterrorhandler")
    if type(getErrorHandler) == "function" then
        local handler = getErrorHandler()
        -- The handler is another addon's code. One that raises must not turn
        -- a report into a failure of the logging caller, so it runs under
        -- `pcall` and the report falls through to `print`.
        if type(handler) == "function" and pcall(handler, failure) then
            return
        end
    end

    -- Outside a WoW client there is no error handler to report through.
    -- Printing is what the client's own default handler does, and staying
    -- silent would turn a sink bug into an invisible one.
    print(failure)
end

---Find an optional package through `Registry:Find`, or `nil` and the reason.
---@param packageName string
---@param api integer
---@return table|nil package
---@return string|nil reason `"absent"` when Registry cannot look packages up
local function findOptional(packageName, api)
    local findPackage = rawget(Registry, "Find")
    if type(findPackage) ~= "function" then
        return nil, REASON_ABSENT
    end
    local found, revisionOrReason = findPackage(Registry, packageName, api)
    if type(found) == "table" then
        return found
    end
    return nil, revisionOrReason
end

local getmetatable = getmetatable
local select = select
local type = type
local unpack = unpack
local stringFormat = string.format

-- Validation -----------------------------------------------------------------

---Whether `implementation` exposes the complete LogKit API 1 surface.
---@param implementation any shared package table handed back by Registry
---@return boolean
local function validatePublicSurface(implementation)
    return type(implementation) == "table"
        and rawget(implementation, "API") == API_GENERATION
        and type(rawget(implementation, "REVISION")) == "number"
        and type(rawget(implementation, "LEVELS")) == "table"
        and rawget(implementation, "DEFAULT_LEVEL") == LEVEL_NAMES[DEFAULT_LEVEL]
        and type(rawget(implementation, "DEFAULT_JOURNAL_CAPACITY")) == "number"
        and type(rawget(implementation, "DEFAULT_MAX_SINKS")) == "number"
        and type(rawget(implementation, "DEFAULT_MAX_MESSAGE_LENGTH")) == "number"
        and type(rawget(implementation, "DEFAULT_MAX_LOGGERS")) == "number"
        and type(rawget(implementation, "MAX_FORMAT_ARGUMENTS")) == "number"
        and type(rawget(implementation, "SECRET_PLACEHOLDER")) == "string"
        and type(rawget(implementation, "UNBOUNDED")) == "table"
        and type(rawget(implementation, "ForAddon")) == "function"
        and type(rawget(implementation, "SetGlobalLevel")) == "function"
        and type(rawget(implementation, "GetGlobalLevel")) == "function"
        and type(rawget(implementation, "AddSink")) == "function"
        and type(rawget(implementation, "RemoveSink")) == "function"
        and type(rawget(implementation, "ChatSink")) == "function"
        and type(rawget(implementation, "History")) == "function"
        and type(rawget(implementation, "RegisterCommand")) == "function"
        and type(rawget(implementation, "BindLevels")) == "function"
        and type(rawget(implementation, "SetLimits")) == "function"
        and type(rawget(implementation, "GetLimits")) == "function"
end

---Whether `value` is an exact integer from `minimum` to `maximum`. `nan` fails
---every comparison and both infinities fail the bounds before the integer test.
---@param value any
---@param minimum number
---@param maximum number
---@return boolean
local function isIntegerBetween(value, minimum, maximum)
    return type(value) == "number" and value >= minimum and value <= maximum and value % 1 == 0
end

---Whether `value` is a valid level number.
---@param value any
---@return boolean
local function isLevelNumber(value)
    return isIntegerBetween(value, LEVEL_TRACE, LEVEL_OFF)
end

---Whether `value` is valid for the limit called `name`, given the sentinel.
---@param name string
---@param value any
---@param unbounded any the package's sentinel
---@return boolean
local function isValidLimitValue(name, value, unbounded)
    if name == "journalCapacity" then
        return isIntegerBetween(value, 1, MAX_JOURNAL_CAPACITY_CEILING)
    end
    if value == unbounded then
        return true
    end
    if name == "maxMessageLength" then
        return isIntegerBetween(value, MIN_MESSAGE_LENGTH, math.huge)
    end
    return isIntegerBetween(value, 1, math.huge)
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
        local name = LIMIT_NAMES[index]
        if not isValidLimitValue(name, rawget(limits, name), unbounded) then
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
    local globalLevel = rawget(currentState, "globalLevel")
    local binding = rawget(currentState, "binding")
    return type(rawget(currentState, "unbounded")) == "table"
        and type(rawget(currentState, "delivering")) == "boolean"
        and type(rawget(currentState, "pendingRemovals")) == "number"
        and (binding == false or type(binding) == "table")
        and validateLimitsTable(rawget(currentState, "limits"), rawget(currentState, "unbounded"))
        and (globalLevel == false or isLevelNumber(globalLevel))
        and type(rawget(currentState, "addonLevels")) == "table"
        and type(rawget(currentState, "loggers")) == "table"
        and type(rawget(currentState, "loggerCount")) == "number"
        and type(rawget(currentState, "loggerPrototype")) == "table"
        and type(rawget(currentState, "loggerMetatable")) == "table"
        and type(rawget(currentState, "chatSinkPrototype")) == "table"
        and type(rawget(currentState, "chatSinkMetatable")) == "table"
        and type(rawget(currentState, "levels")) == "table"
        and type(rawget(currentState, "sinks")) == "table"
        and type(rawget(currentState, "sinkHandles")) == "table"
        and type(rawget(currentState, "journal")) == "table"
        and type(rawget(currentState, "record")) == "table"
        and type(rawget(currentState, "formatArguments")) == "table"
        and type(rawget(currentState, "historyCursor")) == "table"
        and type(rawget(currentState, "dispatch")) == "table"
        and type(rawget(currentState, "command")) == "table"
end

---Whether `implementation` carries package state of this revision's schema,
---and publishes the sentinel and the level table that state owns.
---@param implementation table
---@return boolean
local function validateCurrentState(implementation)
    local currentState = rawget(implementation, "_state")
    return validateStateBase(currentState)
        and rawget(implementation, "UNBOUNDED") == rawget(currentState, "unbounded")
        and rawget(implementation, "LEVELS") == rawget(currentState, "levels")
end

-- Bootstrap ------------------------------------------------------------------

-- `Registry:Bootstrap` owns the reconciliation every embedded package repeats:
-- look the package up, refuse to reinterpret state owned by a newer revision,
-- and register this one. Every closure LogKit hands out (the slash-command
-- handlers) calls through the `dispatch` table in the shared state, so a newer
-- revision replaces their behaviour without a retire hook.
local LogKit, previousRevision, selected = bootstrapPackage(Registry, {
    package = PACKAGE_NAME,
    api = API_GENERATION,
    revision = IMPLEMENTATION_REVISION,
    label = "MoltenCodes LogKit",
    validatePublicSurface = validatePublicSurface,
    validateState = validateCurrentState,
})

if LogKit == nil then
    -- Equal or newer compatible revision already owns the shared package table.
    return selected
end

local state = rawget(LogKit, "_state")

---Build the read-only `LEVELS` table. It lives in the state so every embedded
---revision publishes the same table and a consumer's `LogKit.LEVELS.debug`
---keeps its meaning after an upgrade.
---@return LogKit.Levels
local function newLevelsTable()
    local values = {}
    for name, value in pairs(LEVEL_VALUES) do
        values[name] = value
    end
    return setmetatable({}, {
        __index = values,
        __newindex = function()
            error("LogKit.LEVELS is read-only", 2)
        end,
        __metatable = "LogKit.Levels",
    })
end

---The capacity the first journal is created with: the default, or SignalKit's
---`maxJournalCapacity` when a consumer lowered that below the default before
---LogKit loaded, so that loading never raises over a neighbour's limit.
---@return integer
local function initialJournalCapacity()
    local signalLimits = SignalKit:GetLimits()
    local maxCapacity = rawget(signalLimits, "maxJournalCapacity")
    if type(maxCapacity) == "number" and maxCapacity < DEFAULT_JOURNAL_CAPACITY then
        return maxCapacity
    end
    return DEFAULT_JOURNAL_CAPACITY
end

if previousRevision == nil then
    if state ~= nil then
        error("MoltenCodes LogKit package state is corrupted or incomplete", 2)
    end

    local loggerPrototype = {}
    local chatSinkPrototype = {}
    local journalCapacity = initialJournalCapacity()
    state = {
        schema = STATE_SCHEMA,
        -- The sentinel `SetLimits` accepts to lift a limit. It lives here, not
        -- in a file local, so every embedded revision hands out the same table.
        unbounded = {},
        limits = {
            journalCapacity = journalCapacity,
            maxSinks = DEFAULT_MAX_SINKS,
            maxMessageLength = DEFAULT_MAX_MESSAGE_LENGTH,
            maxLoggers = DEFAULT_MAX_LOGGERS,
        },
        -- The global level, or `false` while none is set.
        globalLevel = false,
        -- Addon name to its override level. Kept apart from the loggers so
        -- a level restored by `BindLevels` applies to a logger created later.
        addonLevels = {},
        loggers = {},
        loggerCount = 0,
        -- Prototypes and metatables live in the shared state, never on a file
        -- local, so objects created by an older embedded copy resolve to the
        -- methods the newest copy installs.
        loggerPrototype = loggerPrototype,
        loggerMetatable = { __index = loggerPrototype },
        chatSinkPrototype = chatSinkPrototype,
        chatSinkMetatable = { __index = chatSinkPrototype },
        levels = newLevelsTable(),
        -- Sink handles in registration order, and the set of live handles.
        sinks = {},
        sinkHandles = {},
        -- Whether sinks are being called right now, and how many were removed
        -- meanwhile; the array is compacted once the dispatch ends.
        delivering = false,
        pendingRemovals = 0,
        journal = SignalKit:NewJournal(journalCapacity),
        -- The one record every sink receives, rewritten per message.
        record = {
            addon = "",
            level = LEVEL_TRACE,
            levelName = "trace",
            message = "",
            time = false,
        },
        -- Staging for format arguments, cleared after each call.
        formatArguments = {},
        -- The filter of the walk `History` most recently started.
        historyCursor = {
            journal = false,
            iterator = false,
            addon = false,
            minimumLevel = LEVEL_TRACE,
        },
        -- Functions the closures handed to CommandKit call through.
        dispatch = {},
        -- The slash command's scope and whether `/log` is registered.
        command = { scope = false, registered = false },
        -- The SettingsKit binding: `{ db, view }`, or `false`.
        binding = false,
    }
    rawset(LogKit, "_state", state)
elseif not validateStateBase(state) then
    error("MoltenCodes LogKit package state is corrupted or incomplete", 2)
end

local LOGGER_PROTOTYPE = rawget(state, "loggerPrototype")
local LOGGER_METATABLE = rawget(state, "loggerMetatable")
local CHAT_SINK_PROTOTYPE = rawget(state, "chatSinkPrototype")
local CHAT_SINK_METATABLE = rawget(state, "chatSinkMetatable")
local LEVELS = rawget(state, "levels")
local UNBOUNDED = rawget(state, "unbounded")
local sharedLimits = rawget(state, "limits")
local addonLevels = rawget(state, "addonLevels")
local loggers = rawget(state, "loggers")
local sinks = rawget(state, "sinks")
local sinkHandles = rawget(state, "sinkHandles")
local record = rawget(state, "record")
local formatArguments = rawget(state, "formatArguments")
local historyCursor = rawget(state, "historyCursor")
local dispatch = rawget(state, "dispatch")
local commandState = rawget(state, "command")
rawset(LOGGER_METATABLE, "__index", LOGGER_PROTOTYPE)
rawset(CHAT_SINK_METATABLE, "__index", CHAT_SINK_PROTOTYPE)

-- Argument checks ------------------------------------------------------------
--
-- Every check raises with an explicit stack level so the reported position is
-- the line that called the public method, never a line inside LogKit. `level`
-- is the value `error` needs inside the function that receives it.

---@param receiver any the table the method was called on
---@param label string public method name, used in the argument error
---@param level integer stack level the failure is reported at
local function validateFacade(receiver, label, level)
    -- `type` first: a secret receiver is never a table, and comparing it raises.
    if type(receiver) ~= "table" or receiver ~= LogKit then
        error(label .. " must be called on the LogKit facade; use " .. label .. "(...)", level)
    end
end

---@param logger any receiver the logger method was called on
---@param methodName string public method name, used in the argument error
---@param level integer stack level the failure is reported at
local function validateLogger(logger, methodName, level)
    if getmetatable(logger) ~= LOGGER_METATABLE then
        error(methodName .. " must be called on a LogKit logger", level)
    end
end

---An addon name: a non-empty, non-secret string. The secret check comes
---first, because comparing a secret string raises.
---@param name any
---@param methodName string public method name, used in the argument error
---@param argumentName string
---@param level integer stack level the failure is reported at
local function validateAddonName(name, methodName, argumentName, level)
    if isSecret(name) then
        error(methodName .. " " .. argumentName .. " must not be a secret value", level)
    end
    if type(name) ~= "string" or name == "" then
        error(methodName .. " " .. argumentName .. " must be a non-empty string", level)
    end
end

-- Levels -----------------------------------------------------------------------

---Read a level argument: a level name or a `LogKit.LEVELS` value.
---@param value any
---@param methodName string public method name, used in the argument error
---@param argumentName string
---@param allowOff boolean whether `"off"` is a valid answer
---@param level integer stack level the failure is reported at
---@return integer
local function readLevel(value, methodName, argumentName, allowOff, level)
    if isSecret(value) then
        error(methodName .. " " .. argumentName .. " must not be a secret value", level)
    end
    local number = nil
    if type(value) == "string" then
        number = LEVEL_VALUES[value]
    elseif isLevelNumber(value) then
        number = value
    end
    if number == nil then
        error(
            methodName
                .. " "
                .. argumentName
                .. " must be a level name ("
                .. LEVEL_LIST_TEXT
                .. ") or a LogKit.LEVELS value",
            level
        )
    end
    if number == LEVEL_OFF and not allowOff then
        error(methodName .. " " .. argumentName .. " cannot be off", level)
    end
    return number
end

---The level `logger` delivers from, and where it comes from.
---@param addonName string
---@return integer level
---@return LogKit.LevelSource source
local function resolveLevel(addonName)
    local override = addonLevels[addonName]
    if override ~= nil then
        return override, SOURCE_ADDON
    end
    local globalLevel = rawget(state, "globalLevel")
    if globalLevel then
        return globalLevel, SOURCE_GLOBAL
    end
    return DEFAULT_LEVEL, SOURCE_DEFAULT
end

---Recompute every logger's cached effective level. Called after any level
---change, so the hot path reads one field and never resolves precedence.
local function refreshEffectiveLevels()
    for addonName, logger in pairs(loggers) do
        logger._effective = resolveLevel(addonName)
    end
end

-- Formatting ---------------------------------------------------------------------

---Stage `...` into the shared staging table, replacing every secret value by
---the placeholder, so `string.format` never sees a secret.
---@param count integer
---@param ... any
local function stageArguments(count, ...)
    local probe = readGlobal("issecretvalue")
    if type(probe) ~= "function" then
        probe = nil
    end
    for index = 1, count do
        local value = select(index, ...)
        if probe ~= nil and probe(value) == true then
            value = SECRET_PLACEHOLDER
        elseif type(value) ~= "string" and type(value) ~= "number" then
            -- Lua 5.1's `%s` accepts strings and numbers only, so every other
            -- value is converted here, the way Lua 5.2 does. `nil` and
            -- booleans convert to interned strings; a table's `__tostring`
            -- runs only now, on an enabled call, which keeps the lazy contract.
            value = tostring(value)
        end
        formatArguments[index] = value
    end
end

---Drop the staged arguments so a logged table is not kept alive by LogKit.
---@param count integer
local function clearStagedArguments(count)
    for index = 1, count do
        formatArguments[index] = nil
    end
end

---Format `message` with `...`, or report the failure and return `nil`.
---
---A bad format string is the caller's bug, but a log call must never raise
---into the code that is trying to report something, so the failure goes to
---the host error handler and the message is dropped.
---@param logger LogKit.Logger
---@param methodName string
---@param message string
---@param count integer
---@param ... any
---@return string|nil
local function formatMessage(logger, methodName, message, count, ...)
    stageArguments(count, ...)
    local ok, result = pcall(stringFormat, message, unpack(formatArguments, 1, count))
    clearStagedArguments(count)
    if not ok then
        -- Every argument is a placeholder or a value the caller passed to be
        -- formatted, so the failure text names no secret.
        reportError(
            methodName
                .. " could not format a message for addon "
                .. logger._name
                .. ": "
                .. tostring(result)
        )
        return nil
    end
    return result
end

---Whether `byte` continues a UTF-8 sequence (`10xxxxxx`).
---@param byte integer|nil
---@return boolean
local function isContinuationByte(byte)
    return byte ~= nil and byte >= 0x80 and byte <= 0xBF
end

---Cut `text` to the `maxMessageLength` limit and mark the cut, never inside a
---UTF-8 sequence.
---@param text string
---@return string
local function truncateMessage(text)
    local maxLength = rawget(sharedLimits, "maxMessageLength")
    if maxLength == UNBOUNDED or #text <= maxLength then
        return text
    end
    local keep = maxLength - #TRUNCATION_MARKER
    while keep > 0 and isContinuationByte(string.byte(text, keep + 1)) do
        keep = keep - 1
    end
    return string.sub(text, 1, keep) .. TRUNCATION_MARKER
end

-- Delivery -------------------------------------------------------------------------

---Remove the handles `RemoveSink` marked while sinks were being called.
local function compactSinks()
    local kept = 0
    for index = 1, #sinks do
        local handle = sinks[index]
        sinks[index] = nil
        if handle.active then
            kept = kept + 1
            sinks[kept] = handle
        end
    end
    rawset(state, "pendingRemovals", 0)
end

---Call a table sink's `Write` with the shared record. The method is looked
---up now rather than at `AddSink`, so a sink built by an older embedded copy
---(a chat sink) writes through the newest revision's `Write`.
---@param receiver LogKit.SinkTable
local function writeThrough(receiver)
    receiver:Write(record)
end

---Call every sink with the shared record. A sink that raises is reported
---through the host error handler and the others still run.
local function callSinks()
    local count = #sinks
    for index = 1, count do
        local handle = sinks[index]
        if handle.active then
            local ok, failure
            local receiver = handle.receiver
            if receiver then
                ok, failure = pcall(writeThrough, receiver)
            else
                ok, failure = pcall(handle.write, record)
            end
            if not ok then
                reportError(failure)
            end
        end
    end
end

---Record one firing in the journal without letting a SignalKit refusal
---escape into the logging caller.
---
---One firing carries four values, so SignalKit's `maxJournalArguments` (8 by
---default) must stay at least 4; a session that lowered it below that makes
---`journal:Fire` raise, which is reported once per message while the message
---still reaches the sinks.
---@param addonName string
---@param level integer
---@param text string
---@param time number|false
local function recordInJournal(addonName, level, text, time)
    local journal = rawget(state, "journal")
    local ok, failure = pcall(journal.Fire, journal, addonName, level, text, time)
    if not ok then
        reportError(failure)
    end
end

---Record one message in the journal and hand it to the sinks.
---
---A message logged from inside a sink is journaled but not delivered to the
---sinks: the record table is in use, and a sink that logs at its own level
---would otherwise recurse without end.
---
---The sink pass runs under `pcall` so that whatever escapes it (the host's
---`geterrorhandler` or `print` raising while a sink failure is reported; the
---handler it returns already runs under `pcall`) can never leave `delivering`
---set for the rest of the session or reach the logging caller; the flag is
---cleared first, then the failure is reported.
---@param logger LogKit.Logger
---@param level integer
---@param text string
local function deliver(logger, level, text)
    local time = readClock()
    local addonName = logger._name
    recordInJournal(addonName, level, text, time)

    if rawget(state, "delivering") or #sinks == 0 then
        return
    end

    record.addon = addonName
    record.level = level
    record.levelName = LEVEL_NAMES[level]
    record.message = text
    record.time = time

    rawset(state, "delivering", true)
    local ok, failure = pcall(callSinks)
    rawset(state, "delivering", false)
    if rawget(state, "pendingRemovals") > 0 then
        compactSinks()
    end
    if not ok then
        reportError(failure)
    end
end

---Check, format, truncate and deliver one enabled message.
---
---Called by the level methods after the level comparison, so `level` 3 is
---the line that called the logger method.
---@param logger LogKit.Logger
---@param level integer
---@param methodName string
---@param message any
---@param ... any
local function emit(logger, level, methodName, message, ...)
    if isSecret(message) then
        error(methodName .. " message must not be a secret value", 3)
    end
    if type(message) ~= "string" then
        error(methodName .. " message must be a string", 3)
    end

    local text = message
    local count = select("#", ...)
    if count > 0 then
        if count > MAX_FORMAT_ARGUMENTS then
            error(
                methodName
                    .. " accepts at most "
                    .. MAX_FORMAT_ARGUMENTS
                    .. " format arguments; received "
                    .. count,
                3
            )
        end
        text = formatMessage(logger, methodName, message, count, ...)
        if text == nil then
            return
        end
    end

    deliver(logger, level, truncateMessage(text))
end

-- Logger methods ---------------------------------------------------------------------

---Build the method for one level. The comparison against the cached effective
---level is the whole disabled path: the message and its arguments are not
---read before it.
---@param level integer
---@param methodName string
---@return fun(self: LogKit.Logger, message: string, ...: any)
local function newLevelMethod(level, methodName)
    return function(self, message, ...)
        if getmetatable(self) ~= LOGGER_METATABLE then
            error(methodName .. " must be called on a LogKit logger", 2)
        end
        if level < self._effective then
            return
        end
        emit(self, level, methodName, message, ...)
    end
end

---Log `message` at `level`, given as a name or a `LogKit.LEVELS` value.
---
---Reading the level costs a few comparisons more than the fixed methods, so
---prefer those where the level is known when the code is written.
---@param self LogKit.Logger
---@param level LogKit.Level
---@param message string
---@param ... any
local function loggerLog(self, level, message, ...)
    validateLogger(self, "LogKit.Logger:Log", 3)
    local number = readLevel(level, "LogKit.Logger:Log", "level", false, 3)
    if number < self._effective then
        return
    end
    emit(self, number, "LogKit.Logger:Log", message, ...)
end

---Whether a message at `level` would be delivered right now.
---@param self LogKit.Logger
---@param level LogKit.Level
---@return boolean
local function loggerIsEnabled(self, level)
    validateLogger(self, "LogKit.Logger:IsEnabled", 3)
    local number = readLevel(level, "LogKit.Logger:IsEnabled", "level", false, 3)
    return number >= self._effective
end

---Persist one level into the bound SettingsKit section, when there is one.
---
---A write the database refuses (a schema tighter than the documented one, a
---full section) is reported through the host error handler; the level still
---applies for the session.
---@param key string addon name, or `"*"` for the global level
---@param levelNumber integer|false
local function persistLevel(key, levelNumber)
    local binding = rawget(state, "binding")
    if not binding then
        return
    end
    local view = binding.view
    local value = levelNumber and LEVEL_NAMES[levelNumber] or nil
    local ok, failure = pcall(function()
        view[key] = value
    end)
    if not ok then
        reportError(failure)
    end
end

---Set or clear one addon's override, whether or not its logger exists, and
---persist it. A level already in force changes nothing: no refresh, no
---saved-variable write, so no `OnChange` fires for a repeated call.
---@param addonName string
---@param number integer|false the level, or `false` to clear the override
local function setAddonLevel(addonName, number)
    if (addonLevels[addonName] or false) == number then
        return
    end
    addonLevels[addonName] = number or nil
    refreshEffectiveLevels()
    persistLevel(addonName, number)
end

---Set this addon's override, or clear it with `nil`.
---@param self LogKit.Logger
---@param level LogKit.Level?
local function loggerSetLevel(self, level)
    validateLogger(self, "LogKit.Logger:SetLevel", 3)
    ---@type integer|false
    local number = false
    if type(level) ~= "nil" then
        number = readLevel(level, "LogKit.Logger:SetLevel", "level", true, 3)
    end
    setAddonLevel(self._name, number)
end

---The effective level's name and where it comes from.
---@param self LogKit.Logger
---@return LogKit.LevelName level
---@return LogKit.LevelSource source
local function loggerGetLevel(self)
    validateLogger(self, "LogKit.Logger:GetLevel", 3)
    local number, source = resolveLevel(self._name)
    return LEVEL_NAMES[number], source
end

---The addon name this logger was created for.
---@param self LogKit.Logger
---@return string
local function loggerGetAddonName(self)
    validateLogger(self, "LogKit.Logger:GetAddonName", 3)
    return self._name
end

---Install every logger method on the shared prototype.
local function bindLoggerMethods()
    rawset(LOGGER_PROTOTYPE, "Trace", newLevelMethod(LEVEL_TRACE, "LogKit.Logger:Trace"))
    rawset(LOGGER_PROTOTYPE, "Debug", newLevelMethod(LEVEL_DEBUG, "LogKit.Logger:Debug"))
    rawset(LOGGER_PROTOTYPE, "Info", newLevelMethod(LEVEL_INFO, "LogKit.Logger:Info"))
    rawset(LOGGER_PROTOTYPE, "Warn", newLevelMethod(LEVEL_WARN, "LogKit.Logger:Warn"))
    rawset(LOGGER_PROTOTYPE, "Error", newLevelMethod(LEVEL_ERROR, "LogKit.Logger:Error"))
    rawset(LOGGER_PROTOTYPE, "Log", loggerLog)
    rawset(LOGGER_PROTOTYPE, "IsEnabled", loggerIsEnabled)
    rawset(LOGGER_PROTOTYPE, "SetLevel", loggerSetLevel)
    rawset(LOGGER_PROTOTYPE, "GetLevel", loggerGetLevel)
    rawset(LOGGER_PROTOTYPE, "GetAddonName", loggerGetAddonName)
end

---Create the logger for `addonName`, or report that the cap refuses it.
---@param addonName string
---@return LogKit.Logger? logger
---@return LogKit.Reason? reason `"capped"` when `maxLoggers` is reached
local function createLogger(addonName)
    local maxLoggers = rawget(sharedLimits, "maxLoggers")
    local count = rawget(state, "loggerCount")
    if maxLoggers ~= UNBOUNDED and count >= maxLoggers then
        return nil, REASON_CAPPED
    end

    local logger = setmetatable({
        _name = addonName,
        _effective = resolveLevel(addonName),
    }, LOGGER_METATABLE)
    loggers[addonName] = logger
    rawset(state, "loggerCount", count + 1)
    return logger
end

-- Journal --------------------------------------------------------------------------

---The stateless iterator `History` returns. It walks SignalKit's ring through
---the iterator that journal hands out and skips entries the cursor's filter
---excludes, so a walk allocates nothing. `position` is the entry's position
---in the journal, 1 for the oldest.
---@param cursor table the shared history cursor
---@param position integer
---@return integer? position
---@return string? addon
---@return LogKit.LevelName? levelName
---@return string? message
---@return number|false? time
local function nextHistoryEntry(cursor, position)
    local journal = cursor.journal
    local iterator = cursor.iterator
    local addonFilter = cursor.addon
    local minimumLevel = cursor.minimumLevel
    while true do
        local nextPosition, entry = iterator(journal, position)
        if nextPosition == nil then
            return nil
        end
        position = nextPosition
        local level = entry[2]
        if level >= minimumLevel and (addonFilter == false or entry[1] == addonFilter) then
            return position, entry[1], LEVEL_NAMES[level], entry[3], entry[4]
        end
    end
end

---Replace the journal with one of `capacity` entries, carrying over the
---newest entries that fit.
---@param capacity integer
local function replaceJournal(capacity)
    local oldJournal = rawget(state, "journal")
    local newJournal = SignalKit:NewJournal(capacity)
    local recorded = 0
    for _ in oldJournal:History() do
        recorded = recorded + 1
    end
    local skip = recorded - capacity
    for position, entry in oldJournal:History() do
        if position > skip then
            newJournal:Fire(entry[1], entry[2], entry[3], entry[4])
        end
    end
    rawset(state, "journal", newJournal)
end

-- Sinks ------------------------------------------------------------------------------

---Write one record to a chat frame as `[addon] level: message`, the level
---coloured. The frame given to `ChatSink` wins; otherwise `DEFAULT_CHAT_FRAME`
---is read when the line is written, and `print` is the fallback outside the
---client.
---@param self LogKit.SinkTable
---@param entry LogKit.Record
local function chatSinkWrite(self, entry)
    local line = "["
        .. entry.addon
        .. "] "
        .. LEVEL_COLOURS[entry.level]
        .. entry.levelName
        .. "|r: "
        .. entry.message
    local chatFrame = rawget(self, "_chatFrame") or readGlobal("DEFAULT_CHAT_FRAME")
    if type(chatFrame) == "table" and type(chatFrame.AddMessage) == "function" then
        chatFrame:AddMessage(line)
        return
    end
    print(line)
end

---Read a sink argument into the function to call, or the table to call
---`Write` on.
---@param sink any
---@param level integer stack level the failure is reported at
---@return function|false write the function sink, or `false` for a table sink
---@return table|false receiver the table sink, or `false` for a function sink
local function readSink(sink, level)
    if isSecret(sink) then
        error("LogKit:AddSink sink must not be a secret value", level)
    end
    if type(sink) == "function" then
        return sink, false
    end
    if type(sink) == "table" and type(sink.Write) == "function" then
        return false, sink
    end
    error("LogKit:AddSink sink must be a function or a table with a Write method", level)
end

-- Limits ---------------------------------------------------------------------------

---Refuse a `SetLimits` argument before any limit changes, so a call with one
---bad entry leaves every limit as it was. A secret key or value is refused
---before it is used as a key or compared, because either raises.
---@param limits any
---@param level integer stack level the failure is reported at
local function validateLimitUpdate(limits, level)
    if type(limits) ~= "table" then
        error("LogKit:SetLimits limits must be a table", level)
    end
    local key = next(limits)
    while type(key) ~= "nil" do
        if isSecret(key) then
            error("LogKit:SetLimits limits must not have a secret key", level)
        end
        if type(key) ~= "string" or LIMIT_NAME_SET[key] ~= true then
            error(
                "LogKit:SetLimits limits." .. tostring(key) .. " is not a recognised limit",
                level
            )
        end
        local value = rawget(limits, key)
        if isSecret(value) then
            error("LogKit:SetLimits limits." .. key .. " must not be a secret value", level)
        end
        if key == "journalCapacity" then
            if value == UNBOUNDED then
                error(
                    "LogKit:SetLimits limits.journalCapacity cannot be LogKit.UNBOUNDED: "
                        .. "the ring is allocated when the journal is created",
                    level
                )
            end
            if not isValidLimitValue(key, value, UNBOUNDED) then
                error(
                    "LogKit:SetLimits limits.journalCapacity must be an integer from 1 to "
                        .. MAX_JOURNAL_CAPACITY_CEILING,
                    level
                )
            end
            local maxCapacity = rawget(SignalKit:GetLimits(), "maxJournalCapacity")
            if type(maxCapacity) == "number" and value > maxCapacity then
                error(
                    "LogKit:SetLimits limits.journalCapacity exceeds SignalKit maxJournalCapacity ("
                        .. maxCapacity
                        .. "); raise it with SignalKit:SetLimits first",
                    level
                )
            end
        elseif key == "maxMessageLength" then
            if not isValidLimitValue(key, value, UNBOUNDED) then
                error(
                    "LogKit:SetLimits limits.maxMessageLength must be an integer of at least "
                        .. MIN_MESSAGE_LENGTH
                        .. " or LogKit.UNBOUNDED",
                    level
                )
            end
        elseif not isValidLimitValue(key, value, UNBOUNDED) then
            error(
                "LogKit:SetLimits limits."
                    .. key
                    .. " must be a positive integer or LogKit.UNBOUNDED",
                level
            )
        end
        key = next(limits, key)
    end
end

-- Command ----------------------------------------------------------------------------

---Describe one logger's level for `/log show`.
---@param addonName string
---@return string
local function describeLevel(addonName)
    local number, source = resolveLevel(addonName)
    return addonName .. ": " .. LEVEL_NAMES[number] .. " (" .. source .. ")"
end

---`/log show [addon]`: print the global level and every logger's level, or
---one addon's. Allocates by design; it runs from the chat box.
---@param context table CommandKit context
---@param addonName string?
function dispatch.commandShow(context, addonName)
    local globalLevel = rawget(state, "globalLevel")
    if isSecret(addonName) then
        context:Usage()
        return
    end
    if type(addonName) ~= "nil" then
        context:Print(describeLevel(addonName))
        return
    end
    context:Print("global: " .. (globalLevel and LEVEL_NAMES[globalLevel] or "not set"))
    local names = {}
    for name in pairs(loggers) do
        names[#names + 1] = name
    end
    table.sort(names)
    for index = 1, #names do
        context:Print(describeLevel(names[index]))
    end
end

---`/log <addon|*> <level|default>`: set an addon override or the global level.
---
---The level word is read without case, as CommandKit reads sub-commands; the
---addon name keeps its case, because addon names are case-sensitive keys.
---Tokens after the level are ignored. Setting an addon's level never creates
---its logger, so a typed name cannot consume `maxLoggers`.
---@param context table CommandKit context
---@param target string?
---@param levelWord string?
function dispatch.commandSetLevel(context, target, levelWord)
    -- The tokens come from the chat box through CommandKit: absence is tested
    -- with `type`, and a secret is refused before it is compared.
    if
        type(target) == "nil"
        or type(levelWord) == "nil"
        or isSecret(target)
        or isSecret(levelWord)
        or target == ""
    then
        context:Usage()
        return
    end
    levelWord = string.lower(levelWord)
    ---@type integer|false
    local number = false
    if levelWord ~= CLEAR_LEVEL_WORD then
        number = LEVEL_VALUES[levelWord]
        if number == nil then
            context:Fail(
                'unknown level "'
                    .. levelWord
                    .. '"; use one of '
                    .. LEVEL_LIST_TEXT
                    .. ", or default to clear"
            )
            return
        end
    end

    if target == GLOBAL_LEVEL_KEY then
        LogKit:SetGlobalLevel(number or nil)
        context:Print("global: " .. (number and LEVEL_NAMES[number] or "not set"))
        return
    end

    setAddonLevel(target, number)
    context:Print(describeLevel(target))
end

---Build the CommandKit spec for `/log`. The handlers are closures that call
---through `dispatch`, so a newer revision replaces their behaviour.
---@return table
local function newCommandSpec()
    return {
        description = "Set or show LogKit levels. Levels: " .. LEVEL_LIST_TEXT .. ".",
        usage = "<addon|*> <level|default>",
        handler = function(context, target, levelWord)
            return dispatch.commandSetLevel(context, target, levelWord)
        end,
        subcommands = {
            show = {
                description = "Show the global level and every addon's effective level.",
                usage = "[addon]",
                handler = function(context, addonName)
                    return dispatch.commandShow(context, addonName)
                end,
            },
        },
    }
end

-- Persistence --------------------------------------------------------------------------

---Whether `db` is a SettingsKit database: the two methods LogKit calls
---resolve to the functions of the published `SettingsKit.Database` prototype.
---The prototype is public surface; the database metatable is not.
---@param SettingsKit table
---@param db any
---@return boolean
local function isSettingsDatabase(SettingsKit, db)
    if type(db) ~= "table" then
        return false
    end
    local prototype = rawget(SettingsKit, "Database")
    return type(prototype) == "table"
        and type(db.Validate) == "function"
        and type(db.Pairs) == "function"
        and db.Validate == rawget(prototype, "Validate")
        and db.Pairs == rawget(prototype, "Pairs")
end

---Copy the levels a bound section holds into the session. Entries that are
---not a known level name are ignored rather than refused, because the section
---is the addon's saved data and may hold a level a later LogKit removed.
---@param db table
---@param view table
local function restoreLevels(db, view)
    for key, value in db:Pairs(view) do
        -- Saved data is not LogKit's: a secret value is skipped before it is
        -- used as a key. SettingsKit's `Pairs` never yields a secret key.
        local number = nil
        if type(value) == "string" and not isSecret(value) then
            number = LEVEL_VALUES[value]
        end
        if type(key) == "string" and number ~= nil then
            if key == GLOBAL_LEVEL_KEY then
                rawset(state, "globalLevel", number)
            else
                addonLevels[key] = number
            end
        end
    end
    refreshEffectiveLevels()
end

-- Package public API -------------------------------------------------------------------

---Return the logger for `addonName`, creating it on first use.
---@param self LogKit
---@param addonName string
---@return LogKit.Logger? logger
---@return LogKit.Reason? reason `"capped"` when a new logger would exceed `maxLoggers`
local function forAddon(self, addonName)
    validateFacade(self, "LogKit:ForAddon", 3)
    validateAddonName(addonName, "LogKit:ForAddon", "addonName", 3)
    local logger = loggers[addonName]
    if logger ~= nil then
        return logger
    end
    return createLogger(addonName)
end

---Set the global level, or clear it with `nil`.
---@param self LogKit
---@param level LogKit.Level?
local function setGlobalLevel(self, level)
    validateFacade(self, "LogKit:SetGlobalLevel", 3)
    ---@type integer|false
    local number = false
    if type(level) ~= "nil" then
        number = readLevel(level, "LogKit:SetGlobalLevel", "level", true, 3)
    end
    if rawget(state, "globalLevel") == number then
        return
    end
    rawset(state, "globalLevel", number)
    refreshEffectiveLevels()
    persistLevel(GLOBAL_LEVEL_KEY, number)
end

---The global level's name, or `nil` while none is set.
---@param self LogKit
---@return LogKit.LevelName?
local function getGlobalLevel(self)
    validateFacade(self, "LogKit:GetGlobalLevel", 3)
    local number = rawget(state, "globalLevel")
    if number then
        return LEVEL_NAMES[number]
    end
    return nil
end

---Add a sink and return its handle.
---@param self LogKit
---@param sink LogKit.Sink
---@return LogKit.SinkHandle? handle
---@return LogKit.Reason? reason `"full"` when `maxSinks` sinks are registered
local function addSink(self, sink)
    validateFacade(self, "LogKit:AddSink", 3)
    local write, receiver = readSink(sink, 3)
    local maxSinks = rawget(sharedLimits, "maxSinks")
    local count = #sinks - rawget(state, "pendingRemovals")
    if maxSinks ~= UNBOUNDED and count >= maxSinks then
        return nil, REASON_FULL
    end

    -- A function sink is called through `write`; a table sink through its
    -- `Write` method, looked up at each call (see `writeThrough`).
    local handle = { write = write, receiver = receiver, active = true }
    sinks[#sinks + 1] = handle
    sinkHandles[handle] = true
    return handle
end

---Remove a sink by its handle. Returns whether it was registered.
---@param self LogKit
---@param handle LogKit.SinkHandle
---@return boolean removed
local function removeSink(self, handle)
    validateFacade(self, "LogKit:RemoveSink", 3)
    -- A secret cannot be a handle LogKit issued, and using it as a table key
    -- would raise, so it is answered like any other unknown value.
    if isSecret(handle) or type(handle) ~= "table" or sinkHandles[handle] ~= true then
        return false
    end
    sinkHandles[handle] = nil
    handle.active = false
    if rawget(state, "delivering") then
        rawset(state, "pendingRemovals", rawget(state, "pendingRemovals") + 1)
    else
        compactSinks()
    end
    return true
end

---Build a sink that prints to a chat frame. Pass it to `AddSink`.
---@param self LogKit
---@param chatFrame table? anything with `AddMessage`; default `DEFAULT_CHAT_FRAME`, read per line
---@return LogKit.SinkTable sink
local function chatSink(self, chatFrame)
    validateFacade(self, "LogKit:ChatSink", 3)
    if type(chatFrame) ~= "nil" then
        if isSecret(chatFrame) then
            error("LogKit:ChatSink chatFrame must not be a secret value", 2)
        end
        if type(chatFrame) ~= "table" or type(chatFrame.AddMessage) ~= "function" then
            error("LogKit:ChatSink chatFrame must be a table with an AddMessage method", 2)
        end
    end
    return setmetatable({ _chatFrame = chatFrame or false }, CHAT_SINK_METATABLE)
end

---Walk the journal oldest to newest: `for position, addon, levelName, message,
---time in LogKit:History() do`. The filter is kept in one shared cursor, so
---the call allocates nothing and walks do not nest.
---@param self LogKit
---@param addonName string? only this addon's entries
---@param minimumLevel LogKit.Level? only entries at this level or above
---@return fun(cursor: table, position: integer): integer?, string?, LogKit.LevelName?, string?, number|false? iterator
---@return table cursor
---@return integer start
local function history(self, addonName, minimumLevel)
    validateFacade(self, "LogKit:History", 3)
    if type(addonName) ~= "nil" then
        validateAddonName(addonName, "LogKit:History", "addonName", 3)
    end
    local level = LEVEL_TRACE
    if type(minimumLevel) ~= "nil" then
        level = readLevel(minimumLevel, "LogKit:History", "minimumLevel", true, 3)
    end

    local journal = rawget(state, "journal")
    historyCursor.journal = journal
    historyCursor.iterator = journal:History()
    historyCursor.addon = addonName or false
    historyCursor.minimumLevel = level
    return nextHistoryEntry, historyCursor, 0
end

---Register `/log` through CommandKit when it is loaded. Idempotent.
---@param self LogKit
---@return boolean registered
---@return LogKit.Reason? reason `"absent"` without CommandKit, `"unavailable"` without `SlashCmdList`, or CommandKit's own refusal
local function registerCommand(self)
    validateFacade(self, "LogKit:RegisterCommand", 3)
    if rawget(commandState, "registered") then
        return true
    end
    local CommandKit = findOptional("commandKit", OPTIONAL_COMMANDKIT_API)
    if CommandKit == nil then
        return false, REASON_ABSENT
    end
    if type(readGlobal("SlashCmdList")) ~= "table" then
        return false, REASON_UNAVAILABLE
    end

    local scope = rawget(commandState, "scope")
    if not scope then
        scope = CommandKit:CreateScope()
        rawset(commandState, "scope", scope)
    end
    local registered, reason = scope:Register(COMMAND_NAME, newCommandSpec())
    if not registered then
        return false, reason
    end
    rawset(commandState, "registered", true)
    return true
end

---Persist levels in a SettingsKit database, restoring what it holds; `nil`
---stops persisting.
---@param self LogKit
---@param db table? a SettingsKit database whose `global` scope declares `logLevels`
---@return boolean bound
local function bindLevels(self, db)
    validateFacade(self, "LogKit:BindLevels", 3)
    if type(db) == "nil" then
        rawset(state, "binding", false)
        return false
    end

    local SettingsKit, reason = findOptional("settingsKit", OPTIONAL_SETTINGSKIT_API)
    if SettingsKit == nil then
        error(
            "LogKit:BindLevels requires SettingsKit API 1, which is not loaded ("
                .. tostring(reason)
                .. ")",
            2
        )
    end
    if not isSettingsDatabase(SettingsKit, db) then
        error("LogKit:BindLevels db must be a SettingsKit database", 2)
    end
    -- `Validate` raises when the scope is not declared and answers `false`
    -- when the section refuses a level name; both mean the schema is not the
    -- documented one. A section without a default has no view to write to.
    local ok, accepted = pcall(
        db.Validate,
        db,
        "global",
        { PERSISTED_SECTION, GLOBAL_LEVEL_KEY },
        LEVEL_NAMES[DEFAULT_LEVEL]
    )
    local view = nil
    if ok and accepted then
        view = db.global[PERSISTED_SECTION]
    end
    if type(view) ~= "table" then
        error(
            "LogKit:BindLevels db must declare global.logLevels as an optional map of "
                .. "addon name to level name; see LogKit docs/API.md",
            2
        )
    end

    rawset(state, "binding", { db = db, view = view })
    restoreLevels(db, view)
    return true
end

---Change any subset of the shared limits. Affects every consumer.
---
---The whole table is checked before anything changes. A new `journalCapacity`
---re-creates the journal, keeping the newest entries that fit. Lowering
---`maxSinks` or `maxLoggers` below what exists removes nothing.
---@param self LogKit
---@param limits LogKit.Limits
local function setLimits(self, limits)
    validateFacade(self, "LogKit:SetLimits", 3)
    validateLimitUpdate(limits, 3)
    for index = 1, #LIMIT_NAMES do
        local name = LIMIT_NAMES[index]
        local value = rawget(limits, name)
        if type(value) ~= "nil" then
            if name == "journalCapacity" and value ~= rawget(sharedLimits, name) then
                replaceJournal(value)
            end
            rawset(sharedLimits, name, value)
        end
    end
end

---Return a fresh copy of the shared limits. Allocates one table per call.
---@param self LogKit
---@return LogKit.Limits limits
local function getLimits(self)
    validateFacade(self, "LogKit:GetLimits", 3)
    return {
        journalCapacity = rawget(sharedLimits, "journalCapacity"),
        maxSinks = rawget(sharedLimits, "maxSinks"),
        maxMessageLength = rawget(sharedLimits, "maxMessageLength"),
        maxLoggers = rawget(sharedLimits, "maxLoggers"),
    }
end

-- Commit ---------------------------------------------------------------------------

rawset(LogKit, "API", API_GENERATION)
rawset(LogKit, "REVISION", IMPLEMENTATION_REVISION)
rawset(LogKit, "LEVELS", LEVELS)
rawset(LogKit, "DEFAULT_LEVEL", LEVEL_NAMES[DEFAULT_LEVEL])
rawset(LogKit, "DEFAULT_JOURNAL_CAPACITY", DEFAULT_JOURNAL_CAPACITY)
rawset(LogKit, "DEFAULT_MAX_SINKS", DEFAULT_MAX_SINKS)
rawset(LogKit, "DEFAULT_MAX_MESSAGE_LENGTH", DEFAULT_MAX_MESSAGE_LENGTH)
rawset(LogKit, "DEFAULT_MAX_LOGGERS", DEFAULT_MAX_LOGGERS)
rawset(LogKit, "MAX_FORMAT_ARGUMENTS", MAX_FORMAT_ARGUMENTS)
rawset(LogKit, "SECRET_PLACEHOLDER", SECRET_PLACEHOLDER)
rawset(LogKit, "UNBOUNDED", UNBOUNDED)
rawset(LogKit, "ForAddon", forAddon)
rawset(LogKit, "SetGlobalLevel", setGlobalLevel)
rawset(LogKit, "GetGlobalLevel", getGlobalLevel)
rawset(LogKit, "AddSink", addSink)
rawset(LogKit, "RemoveSink", removeSink)
rawset(LogKit, "ChatSink", chatSink)
rawset(LogKit, "History", history)
rawset(LogKit, "RegisterCommand", registerCommand)
rawset(LogKit, "BindLevels", bindLevels)
rawset(LogKit, "SetLimits", setLimits)
rawset(LogKit, "GetLimits", getLimits)

bindLoggerMethods()
rawset(CHAT_SINK_PROTOTYPE, "Write", chatSinkWrite)
-- An upgrade inherits loggers whose cached level was computed by the older
-- copy; recomputing costs nothing and keeps the invariant in one place.
refreshEffectiveLevels()

if not validatePublicSurface(LogKit) or not validateCurrentState(LogKit) then
    error("MoltenCodes LogKit package state is corrupted or incomplete", 2)
end

return LogKit
