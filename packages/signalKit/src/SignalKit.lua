-- MoltenCodes SignalKit
--
-- Deterministic, re-entrant callback dispatch for framework and addon code,
-- plus named message buses built on the same signals.
--
-- A signal is an anonymous dispatch point: whoever holds the reference owns
-- its listeners, and a listener error propagates to the caller of `Fire`. A
-- signal may carry two hooks that tell its owner when it becomes observed and
-- when it stops being observed, counts its firings as a generation, and, as a
-- journal, records its last firings in a preallocated ring for explicit pull.
-- A bus is a named, package-wide map from topic to signal, so two modules or
-- two addons that share no reference can still talk. Because a bus is shared
-- by every addon in the session, bus listeners are isolated from each other
-- and their errors are reported through the host error handler instead.
--
-- SignalKit needs nothing but Lua 5.1. On a World of Warcraft client it uses
-- `securecallfunction` and `geterrorhandler` when they exist, and only at the
-- bus boundary. Registry is used for embedded-package identity and revision
-- reconciliation.
--
-- SignalKit does not observe addon shutdown and depends on neither
-- LifecycleKit nor EventKit, yet an addon's bus is closed at logout whenever
-- the framework can observe logout at all (design constitution, principle
-- 4b). `ForAddon` arranges it through whichever of LifecycleKit API 1 and
-- EventKit API 1 is registered, both found through `Registry:Find`: see
-- "Logout close" below and "At logout" in `docs/API.md`.
--
-- Contents
-- --------
--   Constants ............. package identity, default limits and ceilings
--   Bootstrap ............. Registry resolution and registration
--   Shared state .......... LuaCATS types, state creation and migration
--   Receiver validation ... signal and connection receiver checks
--   Listener storage ...... tombstones, compaction, connect and disconnect
--   Signal methods ........ New, Connect, Once, Fire, DisconnectAll, GetGeneration
--   Listener isolation .... allocation-free protected delivery for buses
--   Bus validation ........ receiver, name, topic and policy checks
--   Journals .............. NewJournal, the firing ring and History
--   Bus topics ............ topic records, declaration, subscription
--   Bus methods ........... DeclareTopic, Publish, Subscribe, Topics, ...
--   Bus scopes ............ owner scopes over one bus
--   Logout close .......... who closes an addon's bus at logout
--   Facade methods ........ Bus, ForAddon, CloseAddonBus, SetLimits, GetLimits
--   Commit ................ prototype/facade assignment and self-check

-- Constants ------------------------------------------------------------------

local PACKAGE_NAME = "signalKit"
local API_GENERATION = 1
local IMPLEMENTATION_REVISION = 8
local REQUIRED_REGISTRY_API = 2

-- Schema of the private `_state` table. Revisions 1 to 3 carried no state at
-- all; revision 4 introduced it together with named buses (schema 1),
-- revision 5 added the `UNBOUNDED` sentinel and the package-wide limits
-- (schema 2), revision 6 the logout watcher and the two logout fields of
-- every bus (schema 3), and revision 7 the journal prototype and the two
-- journal limits (schema 4).
local STATE_SCHEMA = 4

-- Who closes an addon's bus at logout, as the bus's `_logoutCloser` records it
-- (docs/API.md, "At logout"). A bus nobody asked for through `ForAddon`
-- records `false`: it is closed only by an explicit `CloseAddonBus`.
--
--   "lifecycleKit"   LifecycleKit names SignalKit in `CLOSES_ADDON_SCOPES` and
--                    closes the bus after the addon's shutdown callbacks.
--   "onShutdown"     an older LifecycleKit is registered: SignalKit subscribed
--                    to the addon's `OnShutdown`, kept in
--                    `_shutdownSubscription`.
--   "playerLogout"   no LifecycleKit, but EventKit: the package-level
--                    `PLAYER_LOGOUT` watcher closes the bus.
--   "none"           neither was registered; the next `ForAddon` asks again.
--
-- Only "none" and "playerLogout" are asked again: a LifecycleKit that loads
-- later still takes the bus over, so its shutdown callbacks run before the bus
-- closes. The API generations of the two Kits asked share the table.
local LOGOUT = {
    lifecycleKitApi = 1,
    eventKitApi = 1,
    byLifecycle = "lifecycleKit",
    byShutdownCallback = "onShutdown",
    byEvent = "playerLogout",
    byNobody = "none",
}

-- Named buses are package state shared by every addon in the session and are
-- never freed (a closed bus stays registered under its name), so their number
-- is bounded. Beyond `maxBuses` `SignalKit:Bus` answers `nil, "full"`. The
-- limit is package-wide and set through `SignalKit:SetLimits`; it accepts no
-- `UNBOUNDED` because the memory it guards belongs to every addon at once.
local DEFAULT_MAX_BUSES = 64
local MAX_BUSES_CEILING = 1024

-- Distinct topics one bus may know, declared or merely subscribed to, unless
-- the bus was created with `options.maxTopics`. Beyond it `DeclareTopic` and a
-- subscription to a new topic answer `nil, "full"`.
local DEFAULT_MAX_TOPICS = 256

-- Live listeners one topic may hold, unless the bus was created with
-- `options.maxListeners`. Beyond it a subscription answers `nil, "full"`.
local DEFAULT_MAX_LISTENERS = 256

-- A journal records its last firings in a ring of slot tables allocated when
-- the journal is created, so its capacity must be a size: `UNBOUNDED` is
-- refused, and the ceiling keeps one `NewJournal` call from allocating an
-- unbounded number of tables at once. The capacity a call may ask for is
-- bounded by the package-wide `maxJournalCapacity`.
local DEFAULT_JOURNAL_CAPACITY = 128
local DEFAULT_MAX_JOURNAL_CAPACITY = 1024
local MAX_JOURNAL_CAPACITY_CEILING = 65536

-- Arguments one journal firing may carry. Each slot is sized in advance for
-- `MULTIPLE_ASSIGNMENT_SLOTS` values and grows once for a wider firing, then
-- is reused, so `UNBOUNDED` is refused; the ceiling bounds the `select` loop
-- that stages values past the multiple assignment, which is quadratic in the
-- width. A wider firing is refused at the firing line.
local DEFAULT_MAX_JOURNAL_ARGUMENTS = 8
local MAX_JOURNAL_ARGUMENTS_CEILING = 64

-- Names `SetLimits` recognises, in the order `GetLimits` reads them, with the
-- ceiling each accepts and why each refuses `UNBOUNDED`.
local LIMIT_NAMES = { "maxBuses", "maxJournalCapacity", "maxJournalArguments" }
local LIMIT_CEILINGS = {
    maxBuses = MAX_BUSES_CEILING,
    maxJournalCapacity = MAX_JOURNAL_CAPACITY_CEILING,
    maxJournalArguments = MAX_JOURNAL_ARGUMENTS_CEILING,
}
local LIMIT_UNBOUNDED_REFUSALS = {
    maxBuses = "buses are shared by every addon and never freed",
    maxJournalCapacity = "the ring is allocated when the journal is created",
    maxJournalArguments = "each firing is staged into a reused slot table",
}

-- Values staged with one multiple assignment, both into the reusable `xpcall`
-- buffer and into a journal slot; wider payloads fall back to a `select` loop
-- for the remainder. Journal slots are sized in advance for this many values.
local MULTIPLE_ASSIGNMENT_SLOTS = 8

-- Lua 5.1 names it `unpack`; `table.unpack` is its later spelling.
local unpackValues = rawget(table, "unpack") or unpack

-- Bootstrap ----------------------------------------------------------------
--
-- `Registry:Bootstrap` owns the reconciliation every embedded package repeats:
-- look the package up, refuse to reinterpret state owned by a newer revision,
-- and register this one. What stays here is what only SignalKit can answer —
-- which fields make a SignalKit facade complete, and how to build or inherit
-- its private state.

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
    error("MoltenCodes SignalKit requires Registry API 2 to be loaded first", 2)
end

local bootstrapPackage = rawget(Registry, "Bootstrap")
if type(bootstrapPackage) ~= "function" then
    error("MoltenCodes SignalKit requires a valid Registry API 2 facade", 2)
end

-- Method names each shared prototype must carry once a copy has committed.
local BUS_METHODS = {
    "DeclareTopic",
    "Publish",
    "Subscribe",
    "SubscribeOnce",
    "Unsubscribe",
    "Topics",
    "CreateScope",
}
local BUS_SCOPE_METHODS = { "Subscribe", "SubscribeOnce", "DisconnectAll", "Close", "IsClosed" }
local JOURNAL_METHODS = { "Fire", "History" }

---Whether every name in `methods` is a function field of `prototype`.
---@param prototype any
---@param methods string[]
---@return boolean
local function hasMethods(prototype, methods)
    if type(prototype) ~= "table" then
        return false
    end
    for index = 1, #methods do
        if type(rawget(prototype, methods[index])) ~= "function" then
            return false
        end
    end
    return true
end

---Whether `implementation` exposes the complete SignalKit API 1 surface.
---@param implementation any shared package table handed back by Registry
---@return boolean
local function validatePublicSurface(implementation)
    return type(implementation) == "table"
        and rawget(implementation, "API") == API_GENERATION
        and type(rawget(implementation, "REVISION")) == "number"
        and type(rawget(implementation, "Connection")) == "table"
        and type(rawget(implementation, "New")) == "function"
        and type(rawget(implementation, "NewJournal")) == "function"
        and type(rawget(implementation, "Connect")) == "function"
        and type(rawget(implementation, "Once")) == "function"
        and type(rawget(implementation, "Fire")) == "function"
        and type(rawget(implementation, "DisconnectAll")) == "function"
        and type(rawget(implementation, "GetGeneration")) == "function"
        and type(rawget(implementation, "Bus")) == "function"
        and type(rawget(implementation, "ForAddon")) == "function"
        and type(rawget(implementation, "CloseAddonBus")) == "function"
        and type(rawget(implementation, "UNBOUNDED")) == "table"
        and type(rawget(implementation, "SetLimits")) == "function"
        and type(rawget(implementation, "GetLimits")) == "function"
        and type(rawget(rawget(implementation, "Connection"), "Disconnect")) == "function"
        and type(rawget(rawget(implementation, "Connection"), "IsConnected")) == "function"
end

---Whether `currentState` has the fields every state schema shares, from
---schema 1 (revision 4) onwards.
---@param currentState any
---@return boolean
local function validateStateBase(currentState)
    return type(currentState) == "table"
        and type(rawget(currentState, "schema")) == "number"
        and type(rawget(currentState, "buses")) == "table"
        and type(rawget(currentState, "busCount")) == "number"
        and type(rawget(currentState, "busPrototype")) == "table"
        and type(rawget(currentState, "busMetatable")) == "table"
        and type(rawget(currentState, "scopePrototype")) == "table"
        and type(rawget(currentState, "scopeMetatable")) == "table"
end

---Whether `value` is a finite integer from 1 to `ceiling`. `nan` fails every
---comparison and infinity is named because it passes the integer test.
---@param value any
---@param ceiling number `math.huge` for a limit without a ceiling
---@return boolean
local function isIntegerUpTo(value, ceiling)
    return type(value) == "number"
        and value ~= math.huge
        and value >= 1
        and value <= ceiling
        and value == math.floor(value)
end

---Whether `limits` holds every package-wide limit as an integer within its
---ceiling.
---@param limits any
---@return boolean
local function validateLimits(limits)
    if type(limits) ~= "table" then
        return false
    end
    for index = 1, #LIMIT_NAMES do
        local name = LIMIT_NAMES[index]
        if not isIntegerUpTo(rawget(limits, name), LIMIT_CEILINGS[name]) then
            return false
        end
    end
    return true
end

---Whether `currentState` has this revision's schema: the base fields, the
---`UNBOUNDED` sentinel, the logout watcher, the journal prototype and a valid
---set of package-wide limits.
---@param currentState any
---@return boolean
local function validateState(currentState)
    return validateStateBase(currentState)
        and rawget(currentState, "schema") == STATE_SCHEMA
        and type(rawget(currentState, "unbounded")) == "table"
        and type(rawget(currentState, "logoutWatch")) == "table"
        and type(rawget(currentState, "journalPrototype")) == "table"
        and type(rawget(currentState, "journalMetatable")) == "table"
        and validateLimits(rawget(currentState, "limits"))
end

---Whether `implementation` carries package state of this revision's schema,
---with every bus, scope and journal method committed and the published
---sentinel the one the state keeps.
---@param implementation table
---@return boolean
local function validateCurrentState(implementation)
    local currentState = rawget(implementation, "_state")
    return validateState(currentState)
        and rawget(implementation, "UNBOUNDED") == rawget(currentState, "unbounded")
        and type(rawget(currentState, "isolate")) == "function"
        and type(rawget(rawget(currentState, "logoutWatch"), "close")) == "function"
        and hasMethods(rawget(currentState, "busPrototype"), BUS_METHODS)
        and hasMethods(rawget(currentState, "scopePrototype"), BUS_SCOPE_METHODS)
        and hasMethods(rawget(currentState, "journalPrototype"), JOURNAL_METHODS)
end

local SignalKit, previousRevision, selected = bootstrapPackage(Registry, {
    package = PACKAGE_NAME,
    api = API_GENERATION,
    revision = IMPLEMENTATION_REVISION,
    label = "MoltenCodes SignalKit",
    validatePublicSurface = validatePublicSurface,
    validateState = validateCurrentState,
})

if type(SignalKit) == "nil" then
    -- Equal or newer compatible revision already owns the shared package table.
    return selected
end

-- Shared state ---------------------------------------------------------------
--
-- SignalKit is both the package facade and the method prototype for signal
-- instances. Because Registry preserves the facade table identity, existing
-- signal instances automatically observe compatible method upgrades loaded by
-- a newer embedded package revision.
--
-- `_state` is reserved package-private storage on the facade. It holds the
-- named buses and the bus and scope prototypes, so buses, topics and
-- subscriptions survive an in-place upgrade and gain the newer methods.

---A connection handle returned by `signal:Connect`, `signal:Once` or a bus
---subscription.
---@class SignalKit.Connection
---@field Disconnect fun(self: SignalKit.Connection): boolean
---@field IsConnected fun(self: SignalKit.Connection): boolean

---A hook `SignalKit:New` takes in `options.onFirst` or `options.onLast`. It
---receives the signal and no payload: it is not a listener and `Fire` never
---calls it. An error it raises propagates to the caller of `Connect`,
---`Disconnect` or `DisconnectAll` that caused the transition (or of `Fire`,
---when a `Once` listener's disconnect did).
---@alias SignalKit.SignalHook fun(signal: SignalKit.Signal)

---Options accepted by `SignalKit:New` and `SignalKit:NewJournal`.
---@class SignalKit.SignalOptions
---@field onFirst SignalKit.SignalHook? Runs after the live listener count goes from 0 to 1.
---@field onLast SignalKit.SignalHook? Runs after the live listener count goes from 1 to 0.

---An independent dispatch point created by `SignalKit:New()`.
---@class SignalKit.Signal
---@field Connect fun(self: SignalKit.Signal, callback: fun(...)): SignalKit.Connection
---@field Once fun(self: SignalKit.Signal, callback: fun(...)): SignalKit.Connection
---@field Fire fun(self: SignalKit.Signal, ...: any)
---@field DisconnectAll fun(self: SignalKit.Signal): integer
---@field GetGeneration fun(self: SignalKit.Signal): integer

---One recorded firing of a journal: `count` arguments in `[1]` to `[count]`,
---explicit `nil`s included, and the generation `Fire` gave that firing. The
---table belongs to the journal's ring and is overwritten by a later firing;
---read it at once and never keep or mutate it.
---@class SignalKit.HistoryEntry
---@field count integer How many arguments the firing carried.
---@field generation integer The journal's generation after that firing.
---@field [integer] any The arguments, from `1` to `count`.

---A signal that also records its last firings, created by
---`SignalKit:NewJournal(capacity)`.
---@class SignalKit.Journal: SignalKit.Signal
---@field History fun(self: SignalKit.Journal): (fun(journal: SignalKit.Journal, position: integer): integer?, SignalKit.HistoryEntry?), SignalKit.Journal, integer

---Argument policy of a declared topic: either an exact argument count, or a
---validator called with the published arguments that returns `true` to accept
---them or `false, reason` to refuse. A validator that compares arguments must
---test them with `issecretvalue` first.
---@alias SignalKit.TopicValidator fun(...: any): boolean, string?

---Options accepted by `bus:DeclareTopic`.
---@class SignalKit.TopicOptions
---@field arguments (integer|SignalKit.TopicValidator)? Exact argument count, or a validator. Omitted: any arguments are accepted.
---@field description string? What the topic means, for diagnostics and documentation.

---Options accepted by `SignalKit:Bus`.
---@class SignalKit.BusOptions
---@field openTopics boolean? `true` lets `Publish` use topics that were never declared. Defaults to `false`.
---@field maxTopics (integer|table)? Positive integer or `SignalKit.UNBOUNDED`: distinct topics the bus may know. Default `256`.
---@field maxListeners (integer|table)? Positive integer or `SignalKit.UNBOUNDED`: live listeners one topic may hold. Default `256`.

---The package-wide limits. `SetLimits` accepts any subset; `GetLimits`
---returns a fresh copy. None accepts `UNBOUNDED`.
---@class SignalKit.Limits
---@field maxBuses integer Named buses the session may hold; default `64`, at most `1024`.
---@field maxJournalCapacity integer Largest `capacity` `NewJournal` accepts; default `1024`, at most `65536`.
---@field maxJournalArguments integer Arguments one journal firing may record; default `8`, at most `64`.

---A named message bus shared by everything in the session that asks for its
---name. Obtained from `SignalKit:Bus(name)` or `SignalKit:ForAddon(addonName)`.
---@class SignalKit.Bus
---@field DeclareTopic fun(self: SignalKit.Bus, topic: string, options: SignalKit.TopicOptions?): true|nil, "full"?
---@field Publish fun(self: SignalKit.Bus, topic: string, ...: any)
---@field Subscribe fun(self: SignalKit.Bus, topic: string, callback: fun(...: any)): SignalKit.Connection|nil, "full"?
---@field SubscribeOnce fun(self: SignalKit.Bus, topic: string, callback: fun(...: any)): SignalKit.Connection|nil, "full"?
---@field Unsubscribe fun(self: SignalKit.Bus, topic: string, callback: fun(...: any)): integer
---@field Topics fun(self: SignalKit.Bus): string[]
---@field CreateScope fun(self: SignalKit.Bus): SignalKit.BusScope

---An ownership scope for subscriptions on one bus.
---@class SignalKit.BusScope
---@field Subscribe fun(self: SignalKit.BusScope, topic: string, callback: fun(...: any)): SignalKit.Connection|nil, "full"?
---@field SubscribeOnce fun(self: SignalKit.BusScope, topic: string, callback: fun(...: any)): SignalKit.Connection|nil, "full"?
---@field DisconnectAll fun(self: SignalKit.BusScope): integer
---@field Close fun(self: SignalKit.BusScope): boolean
---@field IsClosed fun(self: SignalKit.BusScope): boolean

---One topic of a bus: its policy, and the signal behind it once subscribed.
---@class SignalKit.TopicRecord
---@field declared boolean Whether `DeclareTopic` has run for it.
---@field arguments integer|SignalKit.TopicValidator|false Argument policy; `false` accepts anything.
---@field description string|false
---@field signal SignalKit.Signal|false Created on the first subscription.

---The shared SignalKit package table.
---@class SignalKit: SignalKit.Signal
---@field API integer SignalKit API generation.
---@field REVISION integer SignalKit implementation revision.
---@field Connection SignalKit.Connection Shared method prototype for connection handles.
---@field New fun(self: SignalKit?, options: SignalKit.SignalOptions?): SignalKit.Signal
---@field NewJournal fun(self: SignalKit, capacity: integer?, options: SignalKit.SignalOptions?): SignalKit.Journal
---@field Bus fun(self: SignalKit, name: string, options: SignalKit.BusOptions?): SignalKit.Bus|nil, "full"?
---@field ForAddon fun(self: SignalKit, addonName: string): SignalKit.Bus|nil, "full"?
---@field CloseAddonBus fun(self: SignalKit, addonName: string): boolean
---@field UNBOUNDED table Sentinel a bus option takes to lift a per-bus limit.
---@field SetLimits fun(self: SignalKit, limits: table)
---@field GetLimits fun(self: SignalKit): SignalKit.Limits

local Connection = rawget(SignalKit, "Connection")
local state = rawget(SignalKit, "_state")

---Build the journal method table and the metatable journal instances carry.
---
---A journal's own methods (`Fire`, `History`) shadow the signal methods it
---inherits from the facade, so the prototype falls back to `SignalKit`, whose
---identity Registry preserves. Both tables live in the state so that journals
---survive an upgrade and gain the newer methods when the prototype is refilled.
---@return table journalPrototype
---@return table journalMetatable
local function newJournalTables()
    local journalPrototype = setmetatable({}, { __index = SignalKit })
    return journalPrototype, { __index = journalPrototype }
end

---Build empty package state of the current schema.
---@return table
local function newState()
    local busPrototype = {}
    local scopePrototype = {}
    local journalPrototype, journalMetatable = newJournalTables()
    return {
        schema = STATE_SCHEMA,
        -- Bus name to bus, and how many there are, for the `maxBuses` bound.
        buses = {},
        busCount = 0,
        -- Buses and scopes are recognised by metatable identity, so the
        -- metatables live here and survive upgrades; a newer copy refills the
        -- prototypes they index.
        busPrototype = busPrototype,
        busMetatable = { __index = busPrototype },
        scopePrototype = scopePrototype,
        scopeMetatable = { __index = scopePrototype },
        journalPrototype = journalPrototype,
        journalMetatable = journalMetatable,
        -- Delivery closures read the isolation function from here, so a newer
        -- copy replaces it for subscriptions that already exist.
        isolate = false,
        -- `SignalKit.UNBOUNDED`. It lives in the state so that every revision
        -- publishes the same table and a comparison against it keeps working
        -- across an upgrade.
        unbounded = {},
        -- The package-wide limits `SetLimits` writes; a newer copy inherits
        -- what a consumer set.
        limits = {
            maxBuses = DEFAULT_MAX_BUSES,
            maxJournalCapacity = DEFAULT_MAX_JOURNAL_CAPACITY,
            maxJournalArguments = DEFAULT_MAX_JOURNAL_ARGUMENTS,
        },
        -- The package-level `PLAYER_LOGOUT` watcher (see "Logout close"): the
        -- EventKit scope that owns it, the connection once made, the
        -- trampoline handed to EventKit, and the function it calls, which a
        -- newer copy replaces.
        logoutWatch = { scope = false, connection = false, trampoline = false, close = false },
    }
end

---Bring schema-1 state (revision 4) to schema 2 in place: add the sentinel
---and the package-wide limits, and give every existing bus the default
---per-bus limits it was created under.
---@param oldState table
local function upgradeSchemaOne(oldState)
    rawset(oldState, "unbounded", {})
    rawset(oldState, "limits", { maxBuses = DEFAULT_MAX_BUSES })
    for _, bus in pairs(rawget(oldState, "buses")) do
        if type(bus) == "table" then
            rawset(bus, "_maxTopics", DEFAULT_MAX_TOPICS)
            rawset(bus, "_maxListeners", DEFAULT_MAX_LISTENERS)
            rawset(bus, "_maxTopicsStated", false)
            rawset(bus, "_maxListenersStated", false)
        end
    end
    rawset(oldState, "schema", 2)
end

---Bring schema-2 state (revision 5) to schema 3 in place: add the logout
---watcher, and give every existing bus the two logout fields. Revision 5 did
---not record which buses `ForAddon` returned, so none is taken for an addon's
---bus until the next `ForAddon` names it.
---@param oldState table
local function upgradeSchemaTwo(oldState)
    rawset(
        oldState,
        "logoutWatch",
        { scope = false, connection = false, trampoline = false, close = false }
    )
    for _, bus in pairs(rawget(oldState, "buses")) do
        if type(bus) == "table" then
            rawset(bus, "_logoutCloser", false)
            rawset(bus, "_shutdownSubscription", false)
        end
    end
    rawset(oldState, "schema", 3)
end

---Bring schema-3 state (revision 6) to schema 4 in place: add the journal
---prototype and metatable, and the two journal limits with their defaults.
---Signals revision 6 created carry no generation and no hooks; every read of
---those fields treats their absence as zero and none, so they need no visit.
---Schema 3 always carried a `limits` table; a state without one is corrupted
---and refused here rather than indexed.
---@param oldState table
local function upgradeSchemaThree(oldState)
    local limits = rawget(oldState, "limits")
    if type(limits) ~= "table" then
        error("MoltenCodes SignalKit package state is corrupted or incomplete", 2)
    end
    local journalPrototype, journalMetatable = newJournalTables()
    rawset(oldState, "journalPrototype", journalPrototype)
    rawset(oldState, "journalMetatable", journalMetatable)
    rawset(limits, "maxJournalCapacity", DEFAULT_MAX_JOURNAL_CAPACITY)
    rawset(limits, "maxJournalArguments", DEFAULT_MAX_JOURNAL_ARGUMENTS)
    rawset(oldState, "schema", STATE_SCHEMA)
end

if type(previousRevision) == "nil" then
    if Connection ~= nil or state ~= nil then
        error("MoltenCodes SignalKit package state is corrupted or incomplete", 2)
    end

    Connection = {}
    state = newState()
    rawset(SignalKit, "Connection", Connection)
    rawset(SignalKit, "_state", state)
else
    -- Revisions 1 to 3 had no buses and therefore no private state; a later
    -- revision's state must already have this schema's shape.
    if state == nil and type(Connection) == "table" then
        state = newState()
        rawset(SignalKit, "_state", state)
    end

    if type(Connection) ~= "table" or not validateStateBase(state) then
        error("MoltenCodes SignalKit package state is corrupted or incomplete", 2)
    end
    if rawget(state, "schema") == 1 then
        upgradeSchemaOne(state)
    end
    if rawget(state, "schema") == 2 then
        upgradeSchemaTwo(state)
    end
    if rawget(state, "schema") == 3 then
        upgradeSchemaThree(state)
    end
    if not validateState(state) then
        error("MoltenCodes SignalKit package state is corrupted or incomplete", 2)
    end
end

local SIGNAL_METATABLE = { __index = SignalKit }
local CONNECTION_METATABLE = { __index = Connection }
local BUS_PROTOTYPE = rawget(state, "busPrototype")
local BUS_METATABLE = rawget(state, "busMetatable")
local SCOPE_PROTOTYPE = rawget(state, "scopePrototype")
local SCOPE_METATABLE = rawget(state, "scopeMetatable")
local JOURNAL_PROTOTYPE = rawget(state, "journalPrototype")
local JOURNAL_METATABLE = rawget(state, "journalMetatable")
local UNBOUNDED = rawget(state, "unbounded")
local sharedLimits = rawget(state, "limits")
local logoutWatch = rawget(state, "logoutWatch")

-- Receiver validation ---------------------------------------------------------
--
-- `SignalKit.Connect(callback)` is an easy typo for `signal:Connect(callback)`.
-- Without a receiver check the misuse surfaced as "attempt to index a function
-- value" or "attempt to get length of a nil value" somewhere inside SignalKit,
-- which names neither the mistake nor the line that made it.
--
-- The check is a field type test rather than a metatable comparison on purpose:
-- a newer embedded revision builds its own signal metatable, so metatable
-- identity would reject instances created by the revision it upgraded.

local RECEIVER_HINT = " must be called on a signal instance; use signal:"
local CONNECTION_RECEIVER_HINT = " must be called on a connection handle; use connection:"

local CONNECT_RECEIVER_MESSAGE = "SignalKit:Connect" .. RECEIVER_HINT .. "Connect(callback)"
local ONCE_RECEIVER_MESSAGE = "SignalKit:Once" .. RECEIVER_HINT .. "Once(callback)"
local FIRE_RECEIVER_MESSAGE = "SignalKit:Fire" .. RECEIVER_HINT .. "Fire(...)"
local DISCONNECT_ALL_RECEIVER_MESSAGE = "SignalKit:DisconnectAll"
    .. RECEIVER_HINT
    .. "DisconnectAll()"
local GET_GENERATION_RECEIVER_MESSAGE = "SignalKit:GetGeneration"
    .. RECEIVER_HINT
    .. "GetGeneration()"
local JOURNAL_RECEIVER_HINT = " must be called on a journal; use journal:"
local JOURNAL_FIRE_RECEIVER_MESSAGE = "SignalKit.Journal:Fire"
    .. JOURNAL_RECEIVER_HINT
    .. "Fire(...)"
local HISTORY_RECEIVER_MESSAGE = "SignalKit.Journal:History" .. JOURNAL_RECEIVER_HINT .. "History()"
local DISCONNECT_RECEIVER_MESSAGE = "SignalKit:Disconnect"
    .. CONNECTION_RECEIVER_HINT
    .. "Disconnect()"
local IS_CONNECTED_RECEIVER_MESSAGE = "SignalKit:IsConnected"
    .. CONNECTION_RECEIVER_HINT
    .. "IsConnected()"

---Returns the listener array of `self`, or `nil` when `self` is not a signal.
---
---`rawget` raises on a non-table, so the table test has to come first.
---@param self any
---@return table|nil
local function listenersOf(self)
    if type(self) ~= "table" then
        return nil
    end

    local listeners = rawget(self, "_listeners")
    if type(listeners) ~= "table" then
        return nil
    end

    return listeners
end

---Whether `self` looks like a connection handle owned by this package.
---@param self any
---@return boolean
local function isConnectionHandle(self)
    return type(self) == "table" and type(rawget(self, "_connected")) == "boolean"
end

-- Listener storage -------------------------------------------------------------
--
-- A disconnect marks its connection and leaves it in place as a tombstone, so
-- disconnecting is O(1) and allocates nothing. The array is compacted once at
-- least half of its slots are tombstones: each compaction is O(n) but removes
-- n/2 slots, which keeps disconnect amortized O(1) and bounds the array at
-- twice the live listener count.
--
-- Compaction replaces the array instead of editing it, exactly as the previous
-- copy-on-write disconnect did. A dispatch already iterating an older array
-- therefore keeps its own fixed boundary, and because connection objects are
-- shared between the old and new arrays the disconnected flag stays visible in
-- both.
--
-- The live listener count is the array length minus the tombstones, both of
-- which connect and disconnect already maintain, so the `onFirst` and `onLast`
-- hooks cost a signal without them one truthiness test per connect and
-- disconnect. A hook runs after its transition is committed and after the
-- array is in its final shape, so a hook that connects or disconnects inside
-- itself sees a consistent signal and causes, at most, the opposite hook.

---Returns the tombstone count of `signal`.
---
---Signals created by implementation revision 1 carry no counter. Treating a
---missing counter as zero is the in-place upgrade path for those instances.
---@param signal table
---@return integer
local function tombstoneCount(signal)
    local tombstones = rawget(signal, "_tombstones")
    if type(tombstones) ~= "number" then
        return 0
    end

    return tombstones
end

---@param tombstones integer
---@param total integer
---@return boolean
local function shouldCompact(tombstones, total)
    return tombstones > 0 and tombstones * 2 >= total
end

---Replaces the listener array of `signal` with one holding only live entries.
---@param signal table
---@param listeners table
local function compact(signal, listeners)
    local compacted = {}
    local nextIndex = 1

    for index = 1, #listeners do
        local connection = listeners[index]
        if rawget(connection, "_connected") == true then
            compacted[nextIndex] = connection
            nextIndex = nextIndex + 1
        end
    end

    rawset(signal, "_listeners", compacted)
    rawset(signal, "_tombstones", 0)
end

-- Assigned in the bus scope section; a scope-owned connection reports its
-- disconnect so the scope can compact its list.
local noteScopeDisconnect

---Mark `connection` disconnected and release what it references.
---
---The handle stays in the listener array until the next compaction, but the
---callback closures are released immediately: they are normally far larger
---than the handle that holds them. `_busCallback` and `_busScope` exist only on
---bus subscriptions; clearing an absent field is a no-op.
---@param connection table
local function releaseConnection(connection)
    rawset(connection, "_connected", false)
    rawset(connection, "_signal", nil)
    rawset(connection, "_callback", nil)
    rawset(connection, "_busCallback", nil)

    local scope = rawget(connection, "_busScope")
    if scope ~= nil then
        rawset(connection, "_busScope", nil)
        noteScopeDisconnect(scope)
    end
end

---@param connection table
---@return boolean disconnected `true` only for the call that transitioned the state.
local function disconnectConnection(connection)
    if rawget(connection, "_connected") ~= true then
        return false
    end

    local signal = rawget(connection, "_signal")
    releaseConnection(connection)

    local listeners = rawget(signal, "_listeners")
    local total = #listeners
    local tombstones = tombstoneCount(signal) + 1
    rawset(signal, "_tombstones", tombstones)

    if shouldCompact(tombstones, total) then
        compact(signal, listeners)
    end

    -- `total - tombstones` is the live count whether or not compaction ran.
    -- A signal without hooks, or one created before hooks existed, stores
    -- `false` or nothing here and pays only this test.
    local onLast = rawget(signal, "_onLast")
    if onLast and total - tombstones == 0 then
        onLast(signal)
    end

    return true
end

---Shared implementation of `Connect`, `Once` and bus subscriptions.
---@param signal any receiver the public method was called on
---@param callback any candidate listener, validated here
---@param once boolean whether the connection disconnects before its first call
---@param methodName "Connect"|"Once" public method name, used in the argument error
---@param receiverMessage string error text raised when `signal` is not a signal
---@param busCallback function|nil the subscriber's own callback, for `Unsubscribe`
---@param busScope table|nil the bus scope that owns the subscription
---@return SignalKit.Connection
local function connect(signal, callback, once, methodName, receiverMessage, busCallback, busScope)
    local listeners = listenersOf(signal)
    if listeners == nil then
        error(receiverMessage, 3)
    end

    if type(callback) ~= "function" then
        error("SignalKit:" .. methodName .. " callback must be a function", 3)
    end

    local connection = setmetatable({
        _signal = signal,
        _callback = callback,
        _connected = true,
        _once = once,
        _busCallback = busCallback,
        _busScope = busScope,
    }, CONNECTION_METATABLE)

    local nextIndex = #listeners + 1
    rawset(listeners, nextIndex, connection)

    -- The listener is in place before the hook runs, so a hook that connects
    -- again sees two live listeners and one that disconnects everything sees
    -- the 1→0 transition. The subtraction is paid only when a hook exists.
    local onFirst = rawget(signal, "_onFirst")
    if onFirst and nextIndex - tombstoneCount(signal) == 1 then
        onFirst(signal)
    end

    return connection
end

-- Signal methods ---------------------------------------------------------------

---Validate a `SignalKit:New` or `SignalKit:NewJournal` options table and
---return its two hooks, `false` for one the caller did not state.
---@param options any
---@param label string qualified public method name
---@param level integer stack level the failures are reported at
---@return SignalKit.SignalHook|false onFirst
---@return SignalKit.SignalHook|false onLast
local function readSignalOptions(options, label, level)
    if type(options) == "nil" then
        return false, false
    end
    if type(options) ~= "table" then
        error(label .. " options must be a table or nil", level)
    end

    local onFirst = rawget(options, "onFirst")
    if type(onFirst) == "nil" then
        onFirst = false
    elseif type(onFirst) ~= "function" then
        error(label .. " options.onFirst must be a function or nil", level)
    end

    local onLast = rawget(options, "onLast")
    if type(onLast) == "nil" then
        onLast = false
    elseif type(onLast) ~= "function" then
        error(label .. " options.onLast must be a function or nil", level)
    end

    return onFirst, onLast
end

---Whether `receiver` is an options table handed to `SignalKit.New(options)`
---with a dot, where it arrives as the receiver and the options would be
---silently ignored. A signal instance calling `signal:New()` carries its hooks
---under private names, so it never matches.
---@param receiver any
---@return boolean
local function isMisplacedOptionsTable(receiver)
    return type(receiver) == "table"
        and receiver ~= SignalKit
        and (
            type(rawget(receiver, "onFirst")) ~= "nil"
            or type(rawget(receiver, "onLast")) ~= "nil"
        )
end

---Build a signal table with the shared listener layout.
---@param onFirst SignalKit.SignalHook|false
---@param onLast SignalKit.SignalHook|false
---@return table
local function newSignalTable(onFirst, onLast)
    return {
        _listeners = {},
        _tombstones = 0,
        -- Incremented by every `Fire`; a Lua 5.1 double counts exactly to 2^53.
        _generation = 0,
        _onFirst = onFirst,
        _onLast = onLast,
    }
end

---Creates an independent signal instance, with the `onFirst` and `onLast`
---hooks `options` names.
---
---`SignalKit.New()` without options is still accepted; options need the colon
---form, and an options table arriving as the receiver is refused rather than
---ignored.
---@param self SignalKit?
---@param options SignalKit.SignalOptions?
---@return SignalKit.Signal signal
local function newSignal(self, options)
    if type(options) == "nil" and isMisplacedOptionsTable(self) then
        error("SignalKit:New options must be passed with a colon call: SignalKit:New(options)", 2)
    end
    local onFirst, onLast = readSignalOptions(options, "SignalKit:New", 3)
    return setmetatable(newSignalTable(onFirst, onLast), SIGNAL_METATABLE)
end

---Connects `callback` for every future dispatch.
---@param self SignalKit.Signal
---@param callback fun(...: any)
---@return SignalKit.Connection connection
local function connectListener(self, callback)
    return connect(self, callback, false, "Connect", CONNECT_RECEIVER_MESSAGE)
end

---Connects `callback` for at most one dispatch.
---@param self SignalKit.Signal
---@param callback fun(...: any)
---@return SignalKit.Connection connection
local function connectOnce(self, callback)
    return connect(self, callback, true, "Once", ONCE_RECEIVER_MESSAGE)
end

---Invokes every currently eligible listener in connection order.
---@param self SignalKit.Signal
---@param ... any Forwarded to each listener exactly, including `nil` values.
local function fire(self, ...)
    -- Capture both the current listener array and its length. Connect appends
    -- beyond this fixed boundary, while disconnect marks the shared connection
    -- inactive. This makes the current dispatch stable without allocating a
    -- per-Fire snapshot.
    -- The receiver check is inlined rather than delegated to `listenersOf`:
    -- Fire is the one hot path here, and the extra call frame costs more than
    -- the two type tests it would hide.
    if type(self) ~= "table" then
        error(FIRE_RECEIVER_MESSAGE, 2)
    end

    local listeners = rawget(self, "_listeners")
    if type(listeners) ~= "table" then
        error(FIRE_RECEIVER_MESSAGE, 2)
    end

    -- The generation moves before any listener runs, so a listener reading it
    -- sees the firing it is being delivered. A signal created before revision
    -- 7 has no counter; `or 0` is its in-place upgrade path.
    rawset(self, "_generation", (rawget(self, "_generation") or 0) + 1)

    local count = #listeners

    for index = 1, count do
        local connection = listeners[index]
        if rawget(connection, "_connected") == true then
            local callback = rawget(connection, "_callback")

            if rawget(connection, "_once") == true then
                -- Disconnect before invocation so recursive Fire calls cannot
                -- observe the once-listener a second time.
                disconnectConnection(connection)
            end

            callback(...)
        end
    end
end

---Disconnect every live listener of `signal`; the caller validated it.
---@param signal table
---@param listeners table
---@return integer disconnected
local function disconnectEveryListener(signal, listeners)
    local disconnected = 0

    -- Replace the active array first. If a callback is currently dispatching
    -- an older snapshot, marking these shared connection objects disconnected
    -- prevents all remaining callbacks from that snapshot from running.
    rawset(signal, "_listeners", {})
    rawset(signal, "_tombstones", 0)

    for index = 1, #listeners do
        local connection = listeners[index]
        if rawget(connection, "_connected") == true then
            disconnected = disconnected + 1
            releaseConnection(connection)
        end
    end

    -- One 1→0 transition however many listeners went, so `onLast` runs once,
    -- after the signal is empty and ready for a hook that connects again.
    if disconnected > 0 then
        local onLast = rawget(signal, "_onLast")
        if onLast then
            onLast(signal)
        end
    end

    return disconnected
end

---Disconnects every listener connected at the moment of the call.
---@param self SignalKit.Signal
---@return integer disconnected
local function disconnectAll(self)
    local listeners = listenersOf(self)
    if listeners == nil then
        error(DISCONNECT_ALL_RECEIVER_MESSAGE, 2)
    end

    return disconnectEveryListener(self, listeners)
end

---Returns how many times this signal has fired: `0` for a new signal, and for
---a signal created before revision 7 until its next `Fire`.
---@param self SignalKit.Signal
---@return integer generation
local function getGeneration(self)
    if listenersOf(self) == nil then
        error(GET_GENERATION_RECEIVER_MESSAGE, 2)
    end

    return rawget(self, "_generation") or 0
end

---Disconnects this connection.
---@param self SignalKit.Connection
---@return boolean disconnected `true` only for the call that transitioned the state.
local function disconnect(self)
    if not isConnectionHandle(self) then
        error(DISCONNECT_RECEIVER_MESSAGE, 2)
    end

    return disconnectConnection(self)
end

---Whether this connection is still active.
---@param self SignalKit.Connection
---@return boolean connected
local function isConnected(self)
    if not isConnectionHandle(self) then
        error(IS_CONNECTED_RECEIVER_MESSAGE, 2)
    end

    return rawget(self, "_connected") == true
end

-- Listener isolation -----------------------------------------------------------
--
-- A raw signal belongs to whoever holds it, so its listener errors propagate to
-- the caller of `Fire`, who owns those listeners. A bus is shared by every
-- addon in the session: the publisher does not own its subscribers and must
-- not be aborted by one of them, nor may one subscriber stop delivery to the
-- ones behind it. Bus deliveries are therefore isolated and a failure is
-- reported through the host error handler.
--
-- Modern clients provide `securecallfunction`, which both isolates the call and
-- keeps one listener's taint out of the next. Elsewhere this falls back to
-- `xpcall`, which in Lua 5.1 accepts no extra arguments: the payload is staged
-- in one reusable buffer and a single reusable trampoline forwards it, so no
-- closure or argument table is allocated per publish. This is the same model
-- EventKit uses at its own multi-tenant boundary.

local stagedCallback = nil
local stagedCount = 0
local stagedPayload = {}

---Hand a failing listener's error to the host error handler.
---@param message any
local function reportListenerError(message)
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

    -- Outside a WoW client there is no error handler to report through. Printing
    -- is what the client's own default handler does, and staying silent would
    -- turn a listener bug into an invisible one.
    print(message)
end

---Clear the staged payload slots and pass the values through unchanged.
---
---The values are already on the call stack by the time this runs, so a nested
---publish that restages the buffer cannot corrupt the delivery in progress,
---and the buffer does not keep the payload alive after it.
---@param count integer
---@param ... any
---@return any ...
local function releaseStagedPayload(count, ...)
    for index = 1, count do
        stagedPayload[index] = nil
    end
    return ...
end

---Reusable `xpcall` trampoline that forwards the staged payload.
---@return any ...
local function invokeStaged()
    -- Always set by `isolateWithXpcall` immediately before `xpcall` runs this.
    local callback = stagedCallback --[[@as function]]
    local count = stagedCount
    stagedCallback = nil
    return callback(releaseStagedPayload(count, unpackValues(stagedPayload, 1, count)))
end

---Stage `...` into the reusable buffer.
---
---One multiple assignment costs the same whatever the payload size, while
---assigning `select(index, ...)` per slot is quadratic in it; only slots past
---the multiple assignment take the loop. Slots past `count` are nil or stale
---and never read, because the trampoline unpacks with explicit bounds.
---@param count integer
---@param ... any
local function stagePayload(count, ...)
    local payload = stagedPayload
    payload[1], payload[2], payload[3], payload[4], payload[5], payload[6], payload[7], payload[8] =
        ...
    for index = MULTIPLE_ASSIGNMENT_SLOTS + 1, count do
        payload[index] = select(index, ...)
    end
end

---Call `callback` so a raised error is reported rather than propagated.
---@param callback function
---@param ... any published arguments
local function isolateWithXpcall(callback, ...)
    local count = select("#", ...)
    stagedCallback = callback
    stagedCount = count
    stagePayload(count, ...)
    xpcall(invokeStaged, reportListenerError)
end

-- securecallfunction is a World of Warcraft client API reachable only through the global table.
-- selene: allow(global_usage)
local secureCallFunction = rawget(_G, "securecallfunction")
local isolate = isolateWithXpcall
if type(secureCallFunction) == "function" then
    -- Its signature is already `(callback, ...)`, so no adapter frame is needed.
    isolate = secureCallFunction
end

---Build the one delivery closure a bus subscription connects to its signal.
---
---One closure per subscription, never per publish. It reads the isolation
---function from shared state so a newer revision can replace it for
---subscriptions that already exist.
---@param callback function the subscriber's callback
---@return function delivery
local function newDelivery(callback)
    return function(...)
        return rawget(state, "isolate")(callback, ...)
    end
end

-- Bus validation ---------------------------------------------------------------
--
-- Every public bus entry point validates at its own caller's line. Callers keep
-- results in a local before returning them: a Lua tail call would remove the
-- public frame the stack level is counted against.

---Whether the client reports `value` as secret; always `false` elsewhere.
---
---On a client with secret values, comparing a secret with anything, `nil`
---included, raises inside SignalKit instead of at the caller. Values SignalKit
---did not create are therefore tested for absence with `type(value) == "nil"`,
---and checked with this before any other comparison.
---@param value any
---@return boolean
local function isSecret(value)
    -- issecretvalue is a World of Warcraft client API reachable only through the global table.
    -- selene: allow(global_usage)
    local isSecretValue = rawget(_G, "issecretvalue")
    return type(isSecretValue) == "function" and isSecretValue(value) == true
end

---Raise at `level` when `value` is secret, naming `label`.
---@param value any
---@param label string qualified public name of the argument
---@param level integer stack level the failure is reported at
local function refuseSecret(value, label, level)
    if isSecret(value) then
        error(label .. " must not be a secret value", level)
    end
end

---@param value any
---@param label string qualified public name of the argument
---@param level integer stack level the failure is reported at
local function validateNonEmptyString(value, label, level)
    -- Refused before `== ""` could raise inside SignalKit instead of at the caller.
    refuseSecret(value, label, level + 1)
    if type(value) ~= "string" or value == "" then
        error(label .. " must be a non-empty string", level)
    end
end

---@param bus any receiver the public method was called on
---@param label string qualified public method name
---@param level integer stack level the failure is reported at
local function validateBus(bus, label, level)
    if type(bus) ~= "table" or getmetatable(bus) ~= BUS_METATABLE then
        error(label .. " must be called on a SignalKit bus with a colon call", level)
    end
end

---@param scope any receiver the public method was called on
---@param label string qualified public method name
---@param level integer stack level the failure is reported at
local function validateScope(scope, label, level)
    if type(scope) ~= "table" or getmetatable(scope) ~= SCOPE_METATABLE then
        error(label .. " must be called on a SignalKit bus scope", level)
    end
end

---@param self any receiver the facade method was called on
---@param label string qualified public method name
---@param level integer stack level the failure is reported at
local function validateFacade(self, label, level)
    -- The type test comes first: a dot call can hand a secret in as `self`.
    if type(self) ~= "table" or self ~= SignalKit then
        error(label .. " must be called on the SignalKit facade; use " .. label .. "(...)", level)
    end
end

---@param bus SignalKit.Bus
---@param label string qualified public method name
---@param level integer stack level the failure is reported at
local function ensureBusOpen(bus, label, level)
    if rawget(bus, "_closed") == true then
        error(
            label .. ' cannot subscribe on the closed bus "' .. rawget(bus, "_name") .. '"',
            level
        )
    end
end

---Validate a `DeclareTopic` options table and return its two policies.
---@param options any
---@param level integer stack level the failures are reported at
---@return integer|function|false arguments
---@return string|false description
local function readTopicOptions(options, level)
    if type(options) == "nil" then
        return false, false
    end
    if type(options) ~= "table" then
        error("SignalKit.Bus:DeclareTopic options must be a table or nil", level)
    end

    local arguments = rawget(options, "arguments")
    if type(arguments) == "nil" then
        arguments = false
    elseif type(arguments) == "number" then
        refuseSecret(arguments, "SignalKit.Bus:DeclareTopic options.arguments", level + 1)
        -- `math.huge` passes the integer test and NaN fails every comparison,
        -- so both are named explicitly.
        if
            arguments ~= arguments
            or arguments == math.huge
            or arguments < 0
            or arguments ~= math.floor(arguments)
        then
            error(
                "SignalKit.Bus:DeclareTopic options.arguments count must be a finite non-negative integer",
                level
            )
        end
    elseif type(arguments) ~= "function" then
        error(
            "SignalKit.Bus:DeclareTopic options.arguments must be a count, a validator function or nil",
            level
        )
    end

    local description = rawget(options, "description")
    if type(description) == "nil" then
        description = false
    elseif type(description) ~= "string" then
        error("SignalKit.Bus:DeclareTopic options.description must be a string or nil", level)
    end

    return arguments, description
end

---Describe a validator's refusal reason or error without ever inspecting a
---secret. The text is the validator's own; SignalKit never adds the published
---argument values to it.
---@param reason any
---@param fallback string text used when `reason` is not a non-empty string
---@return string
local function describeRefusal(reason, fallback)
    if isSecret(reason) then
        return "the validator gave a secret reason"
    end
    if type(reason) == "string" and reason ~= "" then
        return reason
    end
    return fallback
end

-- Journals ---------------------------------------------------------------------
--
-- A journal is a signal that also keeps its last `capacity` firings in a ring
-- of slot tables, allocated when the journal is created and reused for ever
-- after: a firing overwrites the oldest slot in place. Nothing is replayed to
-- a listener that connects; a consumer that wants the past pulls it through
-- `History()`, which walks the ring oldest to newest through one shared,
-- stateless iterator function, so the walk allocates nothing either.
--
-- Each slot is sized in advance for `MULTIPLE_ASSIGNMENT_SLOTS` values. A wider
-- firing grows its slot once; after every slot has seen the widest firing the
-- journal allocates nothing per `Fire`. The width is bounded by the
-- package-wide `maxJournalArguments` and refused at the firing line with a
-- message that names the two counts and never a value, which may be secret.
-- The values themselves are only stored and handed back, never compared, so
-- a secret value passes through the ring untouched.

---Build one empty slot sized in advance. The eight `nil` items size the array part
---so the first firing into the slot does not grow it, and the two named
---fields have to be in the same constructor: adding them afterwards would
---rehash a table whose array holds only `nil`s and shrink it back to nothing.
---@return SignalKit.HistoryEntry
local function newJournalSlot()
    -- The entry is documented as this exact mixed shape: `count`, `generation` and the arguments at `1` to `count`.
    -- selene: allow(mixed_table)
    return { nil, nil, nil, nil, nil, nil, nil, nil, count = 0, generation = 0 }
end

---Build the ring of `capacity` slots.
---@param capacity integer
---@return SignalKit.HistoryEntry[]
local function newJournalSlots(capacity)
    local slots = {}
    for index = 1, capacity do
        slots[index] = newJournalSlot()
    end
    return slots
end

---Validate a `NewJournal` capacity: `nil` for the default, otherwise an
---integer from 1 to the package-wide `maxJournalCapacity`. The default is
---checked too, so a session that lowered the limit below it is told to state
---a capacity rather than handed a ring over the limit.
---@param capacity any
---@param level integer stack level the failures are reported at
---@return integer
local function readJournalCapacity(capacity, level)
    local maxCapacity = rawget(sharedLimits, "maxJournalCapacity")
    if type(capacity) == "nil" then
        if DEFAULT_JOURNAL_CAPACITY > maxCapacity then
            error(
                "SignalKit:NewJournal default capacity "
                    .. DEFAULT_JOURNAL_CAPACITY
                    .. " exceeds maxJournalCapacity "
                    .. maxCapacity
                    .. "; pass a capacity",
                level
            )
        end
        return DEFAULT_JOURNAL_CAPACITY
    end
    refuseSecret(capacity, "SignalKit:NewJournal capacity", level + 1)
    if capacity == UNBOUNDED then
        error(
            "SignalKit:NewJournal capacity cannot be SignalKit.UNBOUNDED: "
                .. LIMIT_UNBOUNDED_REFUSALS.maxJournalCapacity,
            level
        )
    end
    if not isIntegerUpTo(capacity, maxCapacity) then
        error(
            "SignalKit:NewJournal capacity must be an integer from 1 to "
                .. maxCapacity
                .. " (SignalKit:SetLimits maxJournalCapacity)",
            level
        )
    end
    return capacity
end

---Store `...` into `slot`, clearing what a wider earlier firing left behind.
---
---The multiple assignment writes the first eight positions, `nil` included,
---so only positions past eight can hold stale values.
---@param slot SignalKit.HistoryEntry
---@param count integer
---@param ... any
local function recordArguments(slot, count, ...)
    local previousCount = slot.count
    slot[1], slot[2], slot[3], slot[4], slot[5], slot[6], slot[7], slot[8] = ...
    for index = MULTIPLE_ASSIGNMENT_SLOTS + 1, count do
        slot[index] = select(index, ...)
    end
    local clearFrom = count
    if clearFrom < MULTIPLE_ASSIGNMENT_SLOTS then
        clearFrom = MULTIPLE_ASSIGNMENT_SLOTS
    end
    for index = clearFrom + 1, previousCount do
        slot[index] = nil
    end
    slot.count = count
end

---Record `...` as the newest entry, then dispatch it exactly as `signal:Fire`.
---
---The entry is recorded before any listener runs, so a listener reading
---`History` during the dispatch sees the firing being delivered as the newest
---entry, and a listener error leaves the firing recorded.
---@param self SignalKit.Journal
---@param ... any at most `maxJournalArguments` values (8 by default)
local function journalFire(self, ...)
    if type(self) ~= "table" then
        error(JOURNAL_FIRE_RECEIVER_MESSAGE, 2)
    end
    local slots = rawget(self, "_journalSlots")
    if type(slots) ~= "table" then
        error(JOURNAL_FIRE_RECEIVER_MESSAGE, 2)
    end

    local count = select("#", ...)
    local maxArguments = rawget(sharedLimits, "maxJournalArguments")
    if count > maxArguments then
        error(
            "SignalKit.Journal:Fire records at most "
                .. maxArguments
                .. " arguments per firing; received "
                .. count,
            2
        )
    end

    local head = rawget(self, "_journalHead")
    local slot = slots[head]
    recordArguments(slot, count, ...)
    -- `fire` moves the generation to exactly this value before dispatching.
    slot.generation = (rawget(self, "_generation") or 0) + 1

    local capacity = rawget(self, "_journalCapacity")
    if head == capacity then
        rawset(self, "_journalHead", 1)
    else
        rawset(self, "_journalHead", head + 1)
    end
    local recorded = rawget(self, "_journalRecorded")
    if recorded < capacity then
        rawset(self, "_journalRecorded", recorded + 1)
    end

    fire(self, ...)
end

---The stateless iterator `History` returns. `position` counts the entries
---already returned, so the next one is the oldest recorded entry moved
---forward by `position`; the oldest sits `recorded` slots behind the write
---position, wrapping around the ring.
---@param journal SignalKit.Journal
---@param position integer
---@return integer|nil nextPosition
---@return SignalKit.HistoryEntry|nil entry
local function nextHistoryEntry(journal, position)
    local recorded = rawget(journal, "_journalRecorded")
    if position >= recorded then
        return nil
    end
    local index = rawget(journal, "_journalHead") - recorded + position
    if index < 1 then
        index = index + rawget(journal, "_journalCapacity")
    end
    return position + 1, rawget(journal, "_journalSlots")[index]
end

---Returns what a generic `for` needs to walk the recorded firings, oldest to
---newest: `for position, entry in journal:History() do`. The iterator
---function is shared, so the call allocates nothing.
---@param self SignalKit.Journal
---@return fun(journal: SignalKit.Journal, position: integer): integer?, SignalKit.HistoryEntry? iterator
---@return SignalKit.Journal journal
---@return integer start
local function journalHistory(self)
    if type(self) ~= "table" or type(rawget(self, "_journalSlots")) ~= "table" then
        error(HISTORY_RECEIVER_MESSAGE, 2)
    end
    return nextHistoryEntry, self, 0
end

---Creates a journal: a signal that also records its last `capacity` firings.
---@param self SignalKit
---@param capacity integer? `1` to `maxJournalCapacity`; default `128`.
---@param options SignalKit.SignalOptions?
---@return SignalKit.Journal journal
local function facadeNewJournal(self, capacity, options)
    validateFacade(self, "SignalKit:NewJournal", 3)
    local ringCapacity = readJournalCapacity(capacity, 3)
    local onFirst, onLast = readSignalOptions(options, "SignalKit:NewJournal", 3)

    local journal = newSignalTable(onFirst, onLast)
    rawset(journal, "_journalCapacity", ringCapacity)
    rawset(journal, "_journalSlots", newJournalSlots(ringCapacity))
    -- The slot the next firing writes, and how many slots hold a firing.
    rawset(journal, "_journalHead", 1)
    rawset(journal, "_journalRecorded", 0)
    return setmetatable(journal, JOURNAL_METATABLE)
end

-- Bus topics -------------------------------------------------------------------

---Return the record of `topic` on `bus`, creating an undeclared one on demand.
---@param bus SignalKit.Bus
---@param topic string
---@return SignalKit.TopicRecord|nil record `nil` when the bus already knows `maxTopics` topics.
local function obtainTopicRecord(bus, topic)
    local topics = rawget(bus, "_topics")
    local record = rawget(topics, topic)
    if record ~= nil then
        return record
    end

    local count = rawget(bus, "_topicCount")
    local maxTopics = rawget(bus, "_maxTopics")
    if maxTopics ~= UNBOUNDED and count >= maxTopics then
        return nil
    end

    record = { declared = false, arguments = false, description = false, signal = false }
    rawset(topics, topic, record)
    rawset(bus, "_topicCount", count + 1)
    return record
end

---Validate and attach one bus subscription.
---@param bus any
---@param label string qualified public method name
---@param level integer stack level, counted from this function, of the public caller
---@param topic any
---@param callback any
---@param once boolean
---@param scope table|nil the bus scope that will own the subscription
---@return SignalKit.Connection|nil connection
---@return "full"|nil reason
local function subscribe(bus, label, level, topic, callback, once, scope)
    validateNonEmptyString(topic, label .. " topic", level + 1)
    if type(callback) ~= "function" then
        error(label .. " callback must be a function", level)
    end
    ensureBusOpen(bus, label, level + 1)

    local record = obtainTopicRecord(bus, topic)
    if record == nil then
        return nil, "full"
    end

    local signal = rawget(record, "signal")
    if signal == false then
        -- A topic signal carries no hooks: the bus, not the topic, is what a
        -- consumer observes.
        signal = setmetatable(newSignalTable(false, false), SIGNAL_METATABLE)
        rawset(record, "signal", signal)
    end

    local maxListeners = rawget(bus, "_maxListeners")
    if maxListeners ~= UNBOUNDED then
        local listeners = rawget(signal, "_listeners")
        if #listeners - tombstoneCount(signal) >= maxListeners then
            return nil, "full"
        end
    end

    local connection = connect(
        signal,
        newDelivery(callback),
        once,
        "Connect",
        CONNECT_RECEIVER_MESSAGE,
        callback,
        scope
    )
    return connection, nil
end

-- Bus methods ------------------------------------------------------------------

---Declare `topic` and its argument policy on this bus.
---
---Declaring the same topic again with the same argument policy is accepted and
---changes nothing, so a publisher and a consumer may both declare it; a
---different policy is refused at the caller.
---@param self SignalKit.Bus
---@param topic string
---@param options SignalKit.TopicOptions?
---@return true|nil declared `nil` when the bus already knows `maxTopics` topics.
---@return "full"|nil reason
local function busDeclareTopic(self, topic, options)
    validateBus(self, "SignalKit.Bus:DeclareTopic", 3)
    validateNonEmptyString(topic, "SignalKit.Bus:DeclareTopic topic", 3)
    local arguments, description = readTopicOptions(options, 3)
    if rawget(self, "_closed") == true then
        error(
            'SignalKit.Bus:DeclareTopic cannot declare on the closed bus "'
                .. rawget(self, "_name")
                .. '"',
            2
        )
    end

    local record = obtainTopicRecord(self, topic)
    if record == nil then
        return nil, "full"
    end

    if rawget(record, "declared") == true then
        if rawget(record, "arguments") ~= arguments then
            error(
                'SignalKit.Bus:DeclareTopic topic "'
                    .. topic
                    .. '" is already declared on bus "'
                    .. rawget(self, "_name")
                    .. '" with a different arguments policy',
                2
            )
        end
        return true, nil
    end

    rawset(record, "declared", true)
    rawset(record, "arguments", arguments)
    rawset(record, "description", description)
    return true, nil
end

---Raise the refusal of an undeclared topic at the publisher's line.
---@param bus SignalKit.Bus
---@param topic string
local function refuseUndeclared(bus, topic)
    error(
        'SignalKit.Bus:Publish topic "'
            .. topic
            .. '" is not declared on bus "'
            .. rawget(bus, "_name")
            .. '"; declare it with bus:DeclareTopic(topic, options)'
            .. " or create the bus with options.openTopics = true",
        3
    )
end

---Raise the refusal of an argument list at the publisher's line.
---@param bus SignalKit.Bus
---@param topic string
---@param detail string
local function refuseArguments(bus, topic, detail)
    error(
        'SignalKit.Bus:Publish topic "'
            .. topic
            .. '" on bus "'
            .. rawget(bus, "_name")
            .. '" refused its arguments: '
            .. detail,
        3
    )
end

---Raise a validator's own failure as a refusal at the publisher's line.
---@param bus SignalKit.Bus
---@param topic string
---@param detail string
local function refuseFailedValidator(bus, topic, detail)
    error(
        'SignalKit.Bus:Publish validator for topic "'
            .. topic
            .. '" on bus "'
            .. rawget(bus, "_name")
            .. '" failed: '
            .. detail,
        3
    )
end

---Deliver `...` to every subscriber of `topic`, in subscription order.
---
---Refused at the caller when the topic is undeclared on a bus without
---`openTopics`, or when its arguments fail the declared policy. Subscriber
---errors are reported through the host error handler, never raised here.
---@param self SignalKit.Bus
---@param topic string
---@param ... any
local function busPublish(self, topic, ...)
    validateBus(self, "SignalKit.Bus:Publish", 3)
    validateNonEmptyString(topic, "SignalKit.Bus:Publish topic", 3)
    if rawget(self, "_closed") == true then
        -- A closed bus belongs to an addon that has shut down. Late publishes
        -- from other addons' shutdown paths are expected and deliver nothing,
        -- so the topic policy is not applied to them.
        return
    end

    local record = rawget(rawget(self, "_topics"), topic)
    if record == nil or rawget(record, "declared") ~= true then
        if rawget(self, "_openTopics") ~= true then
            refuseUndeclared(self, topic)
        end
    else
        local arguments = rawget(record, "arguments")
        if type(arguments) == "number" then
            local count = select("#", ...)
            if count ~= arguments then
                refuseArguments(
                    self,
                    topic,
                    "expected " .. arguments .. " arguments, got " .. count
                )
            end
        elseif arguments ~= false then
            -- The validator may belong to another addon, so its failure is
            -- turned into a refusal at the publisher's line. `pcall` with the
            -- arguments passed through allocates nothing.
            local ran, accepted, reason = pcall(arguments, ...)
            if not ran then
                refuseFailedValidator(self, topic, describeRefusal(accepted, "a non-string error"))
            elseif isSecret(accepted) or accepted ~= true then
                -- A secret verdict cannot be compared, so it is not an acceptance.
                refuseArguments(
                    self,
                    topic,
                    describeRefusal(reason, "the validator gave no reason")
                )
            end
        end
    end

    if record ~= nil then
        local signal = rawget(record, "signal")
        if signal ~= false then
            fire(signal, ...)
        end
    end
end

---Subscribe `callback` to every future publish of `topic`.
---
---A topic does not have to be declared before it is subscribed to, so a
---subscriber may load before the publisher that declares it.
---@param self SignalKit.Bus
---@param topic string
---@param callback fun(...: any)
---@return SignalKit.Connection|nil connection
---@return "full"|nil reason
local function busSubscribe(self, topic, callback)
    validateBus(self, "SignalKit.Bus:Subscribe", 3)
    local connection, reason = subscribe(self, "SignalKit.Bus:Subscribe", 3, topic, callback, false)
    return connection, reason
end

---Subscribe `callback` to at most one future publish of `topic`.
---@param self SignalKit.Bus
---@param topic string
---@param callback fun(...: any)
---@return SignalKit.Connection|nil connection
---@return "full"|nil reason
local function busSubscribeOnce(self, topic, callback)
    validateBus(self, "SignalKit.Bus:SubscribeOnce", 3)
    local connection, reason =
        subscribe(self, "SignalKit.Bus:SubscribeOnce", 3, topic, callback, true)
    return connection, reason
end

---Disconnect every subscription of `callback` to `topic`.
---@param self SignalKit.Bus
---@param topic string
---@param callback fun(...: any)
---@return integer disconnected
local function busUnsubscribe(self, topic, callback)
    validateBus(self, "SignalKit.Bus:Unsubscribe", 3)
    validateNonEmptyString(topic, "SignalKit.Bus:Unsubscribe topic", 3)
    if type(callback) ~= "function" then
        error("SignalKit.Bus:Unsubscribe callback must be a function", 2)
    end

    local record = rawget(rawget(self, "_topics"), topic)
    if record == nil or rawget(record, "signal") == false then
        return 0
    end

    -- A disconnect may compact and replace the array. This walk keeps the
    -- array it started with; connection objects are shared, so the flags it
    -- reads stay current.
    local listeners = rawget(rawget(record, "signal"), "_listeners")
    local disconnected = 0
    for index = 1, #listeners do
        local connection = listeners[index]
        if rawget(connection, "_busCallback") == callback and disconnectConnection(connection) then
            disconnected = disconnected + 1
        end
    end
    return disconnected
end

---Return the declared topic names of this bus, sorted. Allocates the array.
---@param self SignalKit.Bus
---@return string[] topics
local function busTopics(self)
    validateBus(self, "SignalKit.Bus:Topics", 3)

    local names = {}
    for topic, record in pairs(rawget(self, "_topics")) do
        if rawget(record, "declared") == true then
            names[#names + 1] = topic
        end
    end
    table.sort(names)
    return names
end

-- Bus scopes -------------------------------------------------------------------
--
-- A scope keeps the connections it created in an array. A connection that
-- disconnects by any path (its handle, `Unsubscribe`, a once-delivery, the bus
-- closing) reports it through `noteScopeDisconnect`, and the array is compacted
-- in place as soon as its dead entries outnumber its live ones. Each compaction
-- removes more than half of the entries it walks, so it is amortized O(1) per
-- disconnect, and the array never holds more than twice the live subscriptions
-- plus one.
--
-- Closing a scope disconnects at once, even inside a publish: a subscription
-- disconnected mid-dispatch is skipped, exactly as SignalKit's own disconnect
-- semantics say. (EventKit instead defers a scope sweep to the end of the
-- dispatch; buses keep SignalKit's rule so their semantics stay a signal's.)

---Build one open scope over `bus`.
---@param bus SignalKit.Bus
---@return SignalKit.BusScope
local function newScope(bus)
    return setmetatable({
        _bus = bus,
        _connections = {},
        _count = 0,
        _dead = 0,
        _closed = false,
    }, SCOPE_METATABLE)
end

---Drop the entries of connections that are no longer connected.
---@param scope SignalKit.BusScope
local function compactScope(scope)
    local connections = rawget(scope, "_connections")
    local count = rawget(scope, "_count")
    local live = 0
    for index = 1, count do
        local connection = connections[index]
        connections[index] = nil
        if rawget(connection, "_connected") == true then
            live = live + 1
            connections[live] = connection
        end
    end
    rawset(scope, "_count", live)
    rawset(scope, "_dead", 0)
end

---Count one disconnected entry of `scope`, compacting once dead entries
---outnumber live ones.
---@param scope SignalKit.BusScope
function noteScopeDisconnect(scope)
    local dead = rawget(scope, "_dead") + 1
    rawset(scope, "_dead", dead)
    if dead * 2 > rawget(scope, "_count") then
        compactScope(scope)
    end
end

---Validate, subscribe through the scope's bus, and remember the connection.
---@param scope any
---@param label string qualified public method name
---@param topic any
---@param callback any
---@param once boolean
---@return SignalKit.Connection|nil connection
---@return "full"|nil reason
local function scopeSubscribeShared(scope, label, topic, callback, once)
    validateScope(scope, label, 4)
    if rawget(scope, "_closed") == true then
        error(label .. " cannot subscribe in a closed scope", 3)
    end

    local connection, reason =
        subscribe(rawget(scope, "_bus"), label, 4, topic, callback, once, scope)
    if connection == nil then
        return nil, reason
    end

    local count = rawget(scope, "_count") + 1
    rawget(scope, "_connections")[count] = connection
    rawset(scope, "_count", count)
    return connection, nil
end

---Subscribe `callback` to `topic` inside this scope.
---@param self SignalKit.BusScope
---@param topic string
---@param callback fun(...: any)
---@return SignalKit.Connection|nil connection
---@return "full"|nil reason
local function scopeSubscribe(self, topic, callback)
    local connection, reason =
        scopeSubscribeShared(self, "SignalKit.BusScope:Subscribe", topic, callback, false)
    return connection, reason
end

---Subscribe `callback` to at most one publish of `topic` inside this scope.
---@param self SignalKit.BusScope
---@param topic string
---@param callback fun(...: any)
---@return SignalKit.Connection|nil connection
---@return "full"|nil reason
local function scopeSubscribeOnce(self, topic, callback)
    local connection, reason =
        scopeSubscribeShared(self, "SignalKit.BusScope:SubscribeOnce", topic, callback, true)
    return connection, reason
end

---Disconnect every subscription of `scope` in creation order.
---@param scope SignalKit.BusScope
---@return integer disconnected
local function disconnectScope(scope)
    local connections = rawget(scope, "_connections")
    local count = rawget(scope, "_count")
    local disconnected = 0
    for index = 1, count do
        local connection = connections[index]
        connections[index] = nil
        -- Detach first, so this walk is never compacted underneath itself.
        rawset(connection, "_busScope", nil)
        if disconnectConnection(connection) then
            disconnected = disconnected + 1
        end
    end
    rawset(scope, "_count", 0)
    rawset(scope, "_dead", 0)
    return disconnected
end

---Disconnect every subscription while keeping the scope reusable.
---@param self SignalKit.BusScope
---@return integer disconnected
local function scopeDisconnectAll(self)
    validateScope(self, "SignalKit.BusScope:DisconnectAll", 3)
    return disconnectScope(self)
end

---Terminally close the scope, disconnecting everything it owns.
---@param self SignalKit.BusScope
---@return boolean closed `false` when the scope was already closed.
local function scopeClose(self)
    validateScope(self, "SignalKit.BusScope:Close", 3)
    if rawget(self, "_closed") == true then
        return false
    end
    rawset(self, "_closed", true)
    disconnectScope(self)
    return true
end

---Return whether the scope is terminally closed.
---@param self SignalKit.BusScope
---@return boolean closed
local function scopeIsClosed(self)
    validateScope(self, "SignalKit.BusScope:IsClosed", 3)
    return rawget(self, "_closed") == true
end

---Create an ownership scope for subscriptions on this bus.
---@param self SignalKit.Bus
---@return SignalKit.BusScope scope
local function busCreateScope(self)
    validateBus(self, "SignalKit.Bus:CreateScope", 3)
    if rawget(self, "_closed") == true then
        error(
            'SignalKit.Bus:CreateScope cannot create a scope on the closed bus "'
                .. rawget(self, "_name")
                .. '"',
            2
        )
    end
    return newScope(self)
end

-- Logout close -----------------------------------------------------------------
--
-- SignalKit never observes logout itself and depends on neither LifecycleKit
-- nor EventKit (design constitution, principle 4b). What it does instead is
-- make sure that somebody who does observe logout closes each addon's bus,
-- whichever revisions of the other Kits are loaded. `ForAddon` asks, in this
-- order:
--
--   (a) LifecycleKit is registered and its `CLOSES_ADDON_SCOPES` names
--       "signalKit": it closes the bus after the addon's shutdown callbacks.
--       SignalKit only makes sure the addon has a LifecycleKit instance,
--       because LifecycleKit closes the buses of the addons it tracks.
--   (b) LifecycleKit is registered without that field (an older revision):
--       SignalKit subscribes to the addon's `OnShutdown` and closes the bus
--       from there. The subscription is kept on the bus, so closing the bus
--       earlier disconnects it.
--   (c) no LifecycleKit, but EventKit: one package-level `PLAYER_LOGOUT`
--       watcher, in SignalKit's own EventKit scope, closes the addon buses
--       that nobody else closes.
--   (d) neither: nothing is arranged, and the consumer calls
--       `SignalKit:CloseAddonBus(addonName)` itself on `PLAYER_LOGOUT`.
--
-- Outcomes (c) and (d) are asked again by every later `ForAddon`, so a
-- LifecycleKit that loads after the first call still takes the bus over. A
-- bus obtained only through `SignalKit:Bus` is never closed at logout.
--
-- The functions are fields of one table, as in the other scope-owning Kits.

local LogoutClose = {}

---Find an optional package through `Registry:Find`, or `nil` when it is not
---registered (or the Registry revision has no `Find`).
---@param packageName string
---@param api integer
---@return table|nil
function LogoutClose.findOptional(packageName, api)
    local findPackage = rawget(Registry, "Find")
    if type(findPackage) ~= "function" then
        return nil
    end
    local found = findPackage(Registry, packageName, api)
    if type(found) == "table" then
        return found
    end
    return nil
end

---Whether `LifecycleKit` announces that it closes SignalKit's addon buses.
---
---The field is a read-only table, so it is indexed normally rather than with
---`rawget`: a proxy answers through `__index`. A revision without the field
---closes none.
---@param LifecycleKit table
---@return boolean
function LogoutClose.lifecycleClosesBuses(LifecycleKit)
    local closes = rawget(LifecycleKit, "CLOSES_ADDON_SCOPES")
    return type(closes) == "table" and closes[PACKAGE_NAME] == true
end

---Make the package-level `PLAYER_LOGOUT` watcher exist, once per session.
---
---The watcher lives in SignalKit's own EventKit scope and calls through a
---trampoline kept in state, which looks up `logoutWatch.close`, so a newer
---SignalKit revision replaces what an older revision's watcher does.
---@param EventKit table
function LogoutClose.ensureWatch(EventKit)
    if rawget(logoutWatch, "connection") ~= false then
        return
    end
    local trampoline = rawget(logoutWatch, "trampoline")
    if trampoline == false then
        trampoline = function()
            rawget(logoutWatch, "close")()
        end
        rawset(logoutWatch, "trampoline", trampoline)
    end
    local eventScope = rawget(logoutWatch, "scope")
    if eventScope == false or eventScope:IsClosed() then
        eventScope = EventKit:CreateScope()
        rawset(logoutWatch, "scope", eventScope)
    end
    rawset(logoutWatch, "connection", eventScope:Once("PLAYER_LOGOUT", trampoline))
end

---Subscribe to the addon's LifecycleKit shutdown and close its bus there.
---
---The callback calls the facade method, so the SignalKit revision loaded at
---logout does the closing.
---@param LifecycleKit table
---@param addonName string
---@return table subscription LifecycleKit subscription handle
function LogoutClose.subscribeShutdown(LifecycleKit, addonName)
    local instance = LifecycleKit:ForAddon(addonName)
    return instance:OnShutdown(function()
        SignalKit:CloseAddonBus(addonName)
    end)
end

---Arrange, once, who closes the addon bus `bus` at logout.
---
---Does nothing for a closed bus, and nothing once LifecycleKit has taken the
---bus over; see the section comment for the four outcomes.
---@param addonName string
---@param bus SignalKit.Bus
function LogoutClose.arrange(addonName, bus)
    local closer = rawget(bus, "_logoutCloser")
    if closer ~= LOGOUT.byNobody and closer ~= LOGOUT.byEvent then
        return
    end
    if rawget(bus, "_closed") == true then
        return
    end

    local LifecycleKit = LogoutClose.findOptional("lifecycleKit", LOGOUT.lifecycleKitApi)
    if LifecycleKit ~= nil then
        if LogoutClose.lifecycleClosesBuses(LifecycleKit) then
            LifecycleKit:ForAddon(addonName)
            rawset(bus, "_logoutCloser", LOGOUT.byLifecycle)
        else
            local subscription = LogoutClose.subscribeShutdown(LifecycleKit, addonName)
            rawset(bus, "_shutdownSubscription", subscription)
            rawset(bus, "_logoutCloser", LOGOUT.byShutdownCallback)
        end
        return
    end

    if closer == LOGOUT.byEvent then
        return
    end
    local EventKit = LogoutClose.findOptional("eventKit", LOGOUT.eventKitApi)
    if EventKit ~= nil then
        LogoutClose.ensureWatch(EventKit)
        rawset(bus, "_logoutCloser", LOGOUT.byEvent)
    end
end

---Take `bus` for the addon bus of `addonName` and arrange its logout close,
---without letting a failure in another Kit break the caller: the failure goes
---to the host error handler and the bus stays undecided, so the next
---`ForAddon` asks again.
---@param addonName string
---@param bus SignalKit.Bus
function LogoutClose.arrangeProtected(addonName, bus)
    local closer = rawget(bus, "_logoutCloser")
    if closer == false or closer == nil then
        rawset(bus, "_logoutCloser", LOGOUT.byNobody)
        rawset(bus, "_shutdownSubscription", false)
    end
    local ok, failure = pcall(LogoutClose.arrange, addonName, bus)
    if not ok then
        reportListenerError(failure)
    end
end

---Disconnect the `OnShutdown` subscription of an addon bus, if it has one.
---
---Called when the bus closes: a bus closed before logout needs no shutdown
---callback, and one closing from inside that callback finds it already
---delivered.
---@param bus SignalKit.Bus
function LogoutClose.releaseSubscription(bus)
    local subscription = rawget(bus, "_shutdownSubscription")
    if subscription == nil or subscription == false then
        return
    end
    rawset(bus, "_shutdownSubscription", false)
    subscription:Disconnect()
end

---The `PLAYER_LOGOUT` watcher's work: close every addon bus nobody else
---closes, in name order so the outcome does not depend on hash order.
---
---A bus LifecycleKit took over (outcomes a and b) is left to it, so its
---shutdown callbacks still run first. Every close is attempted; each failure
---goes to the host error handler.
function LogoutClose.closeAtLogout()
    local names = {}
    for name, bus in pairs(rawget(state, "buses")) do
        local closer = rawget(bus, "_logoutCloser")
        if closer == LOGOUT.byEvent or closer == LOGOUT.byNobody then
            names[#names + 1] = name
        end
    end
    table.sort(names)
    for index = 1, #names do
        local ok, failure = pcall(SignalKit.CloseAddonBus, SignalKit, names[index])
        if not ok then
            reportListenerError(failure)
        end
    end
end

---Arrange the logout close of every open addon bus an upgrade inherited, in
---name order, rather than waiting for a `ForAddon` call the addon may never
---make again. Buses a revision before 6 created are not known to be addon
---buses and wait for their `ForAddon`.
function LogoutClose.arrangeInherited()
    local names = {}
    for name, bus in pairs(rawget(state, "buses")) do
        local closer = rawget(bus, "_logoutCloser")
        if closer ~= false and closer ~= nil and rawget(bus, "_closed") ~= true then
            names[#names + 1] = name
        end
    end
    table.sort(names)
    for index = 1, #names do
        LogoutClose.arrangeProtected(names[index], rawget(rawget(state, "buses"), names[index]))
    end
end

-- Facade methods ---------------------------------------------------------------

---The options a `SignalKit:Bus` call stated. A field is `nil` when the caller
---did not state it.
---@class SignalKit.StatedBusOptions
---@field openTopics boolean|nil
---@field maxTopics integer|table|nil
---@field maxListeners integer|table|nil

---Validate one per-bus limit option: a positive integer or `UNBOUNDED`.
---@param value any
---@param name string option name, for the message
---@param level integer stack level the failure is reported at
local function validateBusLimit(value, name, level)
    if type(value) == "nil" then
        return
    end
    refuseSecret(value, "SignalKit:Bus options." .. name, level + 1)
    if value ~= UNBOUNDED and not isIntegerUpTo(value, math.huge) then
        error(
            "SignalKit:Bus options." .. name .. " must be a positive integer or SignalKit.UNBOUNDED",
            level
        )
    end
end

---Validate a `SignalKit:Bus` options table.
---@param options any
---@param level integer stack level the failures are reported at
---@return boolean|nil openTopics `nil` when the caller did not state one.
---@return integer|table|nil maxTopics `nil` when the caller did not state one.
---@return integer|table|nil maxListeners `nil` when the caller did not state one.
local function readBusOptions(options, level)
    if type(options) == "nil" then
        return nil, nil, nil
    end
    if type(options) ~= "table" then
        error("SignalKit:Bus options must be a table or nil", level)
    end
    local openTopics = rawget(options, "openTopics")
    refuseSecret(openTopics, "SignalKit:Bus options.openTopics", level + 1)
    if type(openTopics) ~= "nil" and type(openTopics) ~= "boolean" then
        error("SignalKit:Bus options.openTopics must be a boolean or nil", level)
    end
    local maxTopics = rawget(options, "maxTopics")
    validateBusLimit(maxTopics, "maxTopics", level + 1)
    local maxListeners = rawget(options, "maxListeners")
    validateBusLimit(maxListeners, "maxListeners", level + 1)
    return openTopics, maxTopics, maxListeners
end

---Whether a caller stating `value` for `limitName` disagrees with what an
---earlier caller stated for the existing `bus`.
---
---A bus created without stating a limit carries the default; the first caller
---that states it sets it, whichever order the addons load in. A second,
---different statement is refused at the caller, because two owners
---disagreeing about a shared bus is a mistake one of them has to see.
---@param bus SignalKit.Bus
---@param limitName "maxTopics"|"maxListeners"
---@param value integer|table|nil
---@return boolean
local function conflictsWithStatedLimit(bus, limitName, value)
    return type(value) ~= "nil"
        and rawget(bus, "_" .. limitName .. "Stated") == true
        and rawget(bus, "_" .. limitName) ~= value
end

---Record `value` as the stated `limitName` of `bus` when the caller stated one.
---@param bus SignalKit.Bus
---@param limitName "maxTopics"|"maxListeners"
---@param value integer|table|nil
local function applyStatedLimit(bus, limitName, value)
    if type(value) ~= "nil" then
        rawset(bus, "_" .. limitName, value)
        rawset(bus, "_" .. limitName .. "Stated", true)
    end
end

---Return the bus called `name`, creating it on the first request.
---@param name string
---@param openTopics boolean|nil
---@param maxTopics integer|table|nil
---@param maxListeners integer|table|nil
---@param label string qualified public method name
---@param level integer stack level the failures are reported at
---@return SignalKit.Bus|nil bus
---@return "full"|nil reason
local function obtainBus(name, openTopics, maxTopics, maxListeners, label, level)
    local buses = rawget(state, "buses")
    local bus = rawget(buses, name)
    if bus ~= nil then
        if type(openTopics) ~= "nil" and openTopics ~= rawget(bus, "_openTopics") then
            error(
                label .. ' bus "' .. name .. '" already exists with a different openTopics policy',
                level
            )
        end
        -- Both statements are checked before either is applied, so a refused
        -- call changes nothing.
        if conflictsWithStatedLimit(bus, "maxTopics", maxTopics) then
            error(label .. ' bus "' .. name .. '" already exists with a different maxTopics', level)
        end
        if conflictsWithStatedLimit(bus, "maxListeners", maxListeners) then
            error(
                label .. ' bus "' .. name .. '" already exists with a different maxListeners',
                level
            )
        end
        applyStatedLimit(bus, "maxTopics", maxTopics)
        applyStatedLimit(bus, "maxListeners", maxListeners)
        return bus, nil
    end

    local count = rawget(state, "busCount")
    if count >= rawget(sharedLimits, "maxBuses") then
        return nil, "full"
    end

    bus = setmetatable({
        _name = name,
        _openTopics = openTopics == true,
        _closed = false,
        _topics = {},
        _topicCount = 0,
        _maxTopics = maxTopics or DEFAULT_MAX_TOPICS,
        _maxTopicsStated = type(maxTopics) ~= "nil",
        _maxListeners = maxListeners or DEFAULT_MAX_LISTENERS,
        _maxListenersStated = type(maxListeners) ~= "nil",
        -- See "Logout close": `false` until `ForAddon` names this bus.
        _logoutCloser = false,
        _shutdownSubscription = false,
    }, BUS_METATABLE)
    rawset(buses, name, bus)
    rawset(state, "busCount", count + 1)
    return bus, nil
end

---Return the named bus shared by everything in the session that asks for
---`name`, creating it on the first request.
---@param self SignalKit
---@param name string
---@param options SignalKit.BusOptions?
---@return SignalKit.Bus|nil bus `nil` when `maxBuses` buses already exist.
---@return "full"|nil reason
local function facadeBus(self, name, options)
    validateFacade(self, "SignalKit:Bus", 3)
    validateNonEmptyString(name, "SignalKit:Bus name", 3)
    local openTopics, maxTopics, maxListeners = readBusOptions(options, 3)
    local bus, reason = obtainBus(name, openTopics, maxTopics, maxListeners, "SignalKit:Bus", 3)
    return bus, reason
end

---Return the default bus of an addon: the bus named after it.
---
---SignalKit does not observe addon shutdown, but every call makes sure
---somebody who does closes this bus through `SignalKit:CloseAddonBus(addonName)`:
---LifecycleKit, SignalKit's own `PLAYER_LOGOUT` watcher through EventKit, or,
---with neither loaded, the addon itself (docs/API.md, "At logout").
---@param self SignalKit
---@param addonName string addon folder name
---@return SignalKit.Bus|nil bus `nil` when `maxBuses` buses already exist.
---@return "full"|nil reason
local function facadeForAddon(self, addonName)
    validateFacade(self, "SignalKit:ForAddon", 3)
    validateNonEmptyString(addonName, "SignalKit:ForAddon addonName", 3)
    local bus, reason = obtainBus(addonName, nil, nil, nil, "SignalKit:ForAddon", 3)
    if bus ~= nil then
        LogoutClose.arrangeProtected(addonName, bus)
    end
    return bus, reason
end

---Close the bus named after an addon, disconnecting every subscription on it.
---
---Closing is terminal: the closed bus stays registered under its name, refuses
---new subscriptions and scopes, and publishes on it deliver nothing.
---@param self SignalKit
---@param addonName string addon folder name
---@return boolean closed `false` when there was no such bus or it was already closed.
local function facadeCloseAddonBus(self, addonName)
    validateFacade(self, "SignalKit:CloseAddonBus", 3)
    validateNonEmptyString(addonName, "SignalKit:CloseAddonBus addonName", 3)

    local bus = rawget(rawget(state, "buses"), addonName)
    if bus == nil or rawget(bus, "_closed") == true then
        return false
    end

    rawset(bus, "_closed", true)
    LogoutClose.releaseSubscription(bus)
    for _, record in pairs(rawget(bus, "_topics")) do
        local signal = rawget(record, "signal")
        if signal ~= false then
            disconnectEveryListener(signal, rawget(signal, "_listeners"))
        end
    end
    return true
end

---Validate one `SetLimits` entry: a recognised name, an integer within the
---limit's ceiling, never `UNBOUNDED` (each limit names its reason).
---@param key any
---@param value any
---@param level integer stack level the failures are reported at
local function validateLimitEntry(key, value, level)
    local ceiling = LIMIT_CEILINGS[key]
    if ceiling == nil then
        error("SignalKit:SetLimits limits." .. tostring(key) .. " is not a recognised limit", level)
    end
    refuseSecret(value, "SignalKit:SetLimits limits." .. key, level + 1)
    if value == UNBOUNDED then
        error(
            "SignalKit:SetLimits limits."
                .. key
                .. " cannot be SignalKit.UNBOUNDED: "
                .. LIMIT_UNBOUNDED_REFUSALS[key],
            level
        )
    end
    if not isIntegerUpTo(value, ceiling) then
        error(
            "SignalKit:SetLimits limits." .. key .. " must be an integer from 1 to " .. ceiling,
            level
        )
    end
end

---Validate a whole `SetLimits` table before any of it is applied.
---
---Every limit here guards memory that is either shared by the session
---(`maxBuses`) or allocated in one go (`maxJournalCapacity`,
---`maxJournalArguments`), so each refuses `UNBOUNDED` and accepts a larger
---integer only up to its ceiling.
---@param limits any
---@param level integer stack level the failures are reported at
local function validateLimitUpdate(limits, level)
    if type(limits) ~= "table" then
        error("SignalKit:SetLimits limits must be a table", level)
    end
    local key = next(limits)
    while type(key) ~= "nil" do
        validateLimitEntry(key, rawget(limits, key), level + 1)
        key = next(limits, key)
    end
end

---Change any subset of the package-wide limits. The limits are shared by every
---consumer in the session. Lowering one never closes a bus or shrinks a
---journal; further buses, and journals asking for more than the new bound, are
---refused until the value allows them again.
---@param self SignalKit
---@param limits table
local function facadeSetLimits(self, limits)
    validateFacade(self, "SignalKit:SetLimits", 3)
    validateLimitUpdate(limits, 3)
    for index = 1, #LIMIT_NAMES do
        local name = LIMIT_NAMES[index]
        local value = rawget(limits, name)
        if type(value) ~= "nil" then
            rawset(sharedLimits, name, value)
        end
    end
end

---Return a fresh copy of the package-wide limits. Allocates one table.
---@param self SignalKit
---@return SignalKit.Limits
local function facadeGetLimits(self)
    validateFacade(self, "SignalKit:GetLimits", 3)
    local copy = {}
    for index = 1, #LIMIT_NAMES do
        local name = LIMIT_NAMES[index]
        copy[name] = rawget(sharedLimits, name)
    end
    return copy
end

-- Commit -----------------------------------------------------------------------
--
-- Commit the compatible public surface only after all implementation functions
-- have been constructed successfully. Registry has already accepted this
-- revision, so initialization below intentionally contains no fallible external
-- calls.

rawset(Connection, "Disconnect", disconnect)
rawset(Connection, "IsConnected", isConnected)

rawset(BUS_PROTOTYPE, "DeclareTopic", busDeclareTopic)
rawset(BUS_PROTOTYPE, "Publish", busPublish)
rawset(BUS_PROTOTYPE, "Subscribe", busSubscribe)
rawset(BUS_PROTOTYPE, "SubscribeOnce", busSubscribeOnce)
rawset(BUS_PROTOTYPE, "Unsubscribe", busUnsubscribe)
rawset(BUS_PROTOTYPE, "Topics", busTopics)
rawset(BUS_PROTOTYPE, "CreateScope", busCreateScope)

rawset(SCOPE_PROTOTYPE, "Subscribe", scopeSubscribe)
rawset(SCOPE_PROTOTYPE, "SubscribeOnce", scopeSubscribeOnce)
rawset(SCOPE_PROTOTYPE, "DisconnectAll", scopeDisconnectAll)
rawset(SCOPE_PROTOTYPE, "Close", scopeClose)
rawset(SCOPE_PROTOTYPE, "IsClosed", scopeIsClosed)

rawset(JOURNAL_PROTOTYPE, "Fire", journalFire)
rawset(JOURNAL_PROTOTYPE, "History", journalHistory)

rawset(state, "isolate", isolate)
rawset(logoutWatch, "close", LogoutClose.closeAtLogout)

rawset(SignalKit, "API", API_GENERATION)
rawset(SignalKit, "REVISION", IMPLEMENTATION_REVISION)
rawset(SignalKit, "New", newSignal)
rawset(SignalKit, "NewJournal", facadeNewJournal)
rawset(SignalKit, "Connect", connectListener)
rawset(SignalKit, "Once", connectOnce)
rawset(SignalKit, "Fire", fire)
rawset(SignalKit, "DisconnectAll", disconnectAll)
rawset(SignalKit, "GetGeneration", getGeneration)
rawset(SignalKit, "Bus", facadeBus)
rawset(SignalKit, "ForAddon", facadeForAddon)
rawset(SignalKit, "CloseAddonBus", facadeCloseAddonBus)
rawset(SignalKit, "UNBOUNDED", UNBOUNDED)
rawset(SignalKit, "SetLimits", facadeSetLimits)
rawset(SignalKit, "GetLimits", facadeGetLimits)

if not validatePublicSurface(SignalKit) or not validateCurrentState(SignalKit) then
    error("MoltenCodes SignalKit package state is corrupted or incomplete", 2)
end

if type(previousRevision) ~= "nil" then
    LogoutClose.arrangeInherited()
end

return SignalKit
