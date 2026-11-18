-- MoltenCodes SignalKit
--
-- Deterministic, re-entrant callback dispatch for framework and addon code:
-- the counterpart of CallbackHandler-1.0.
--
-- A signal is an anonymous dispatch point: whoever holds the reference owns
-- its listeners, and a listener error propagates to the caller of `Fire`. A
-- signal may carry two hooks that tell its owner when it becomes observed and
-- when it stops being observed, and counts its firings as a generation.
--
-- This file is the core (ADR 0001, docs/decisions/0001-kit-core-and-parts.md):
-- raw signals, connection handles and the package-wide limits, which every
-- user of SignalKit needs. Three parts load after it:
--   Bus ......... named message buses (AceEvent-3.0's messages): topics and
--                 their argument policies, Publish and Subscribe, bus scopes,
--                 `ForAddon` with the close of an addon's bus at logout, and
--                 isolated delivery;
--   Journal ..... `NewJournal`: a signal that records its last firings;
--   Coalescing .. bucketed bus messages (needs the Bus part).
-- The core publishes what a part may call in `_state.helpers`, the parts
-- loaded in `_state.parts`, and the interface generation in
-- `_state.partInterface`. Without its part, `Bus`, `ForAddon` and
-- `NewJournal` raise at the caller with the file to embed, and
-- `CloseAddonBus` answers `false` after its argument checks.
--
-- SignalKit needs nothing but Lua 5.1 and Registry.
--
-- Contents
-- --------
--   Constants ............. package identity, default limits and ceilings
--   Bootstrap ............. Registry resolution and registration
--   Shared state .......... LuaCATS types, state creation and migration
--   Secret values ......... the shared isSecret block
--   Receiver validation ... signal and connection receiver checks
--   Listener storage ...... tombstones, in-place settling, compaction, connect,
--                           disconnect
--   Signal methods ........ New, Connect, Once, Fire, DisconnectAll, GetGeneration
--   Argument checks ....... secret refusal, strings, the facade receiver
--   Parts ................. HasPart, the members of a part that is not loaded,
--                           and buses an older revision left
--   Facade methods ........ CloseAddonBus, SetLimits, GetLimits
--   Commit ................ prototype/facade assignment, part helpers, self-check

-- Constants ------------------------------------------------------------------

local PACKAGE_NAME = "signalKit"
local API_GENERATION = 1
local IMPLEMENTATION_REVISION = 13
local REQUIRED_REGISTRY_API = 2

-- Schema of the private `_state` table. Revisions 1 to 3 carried no state at
-- all; revision 4 introduced it together with named buses (schema 1),
-- revision 5 added the `UNBOUNDED` sentinel and the package-wide limits
-- (schema 2), revision 6 the logout watcher and the two logout fields of
-- every bus (schema 3), revision 7 the journal prototype and the two journal
-- limits (schema 4), revision 9 the isolation flag every bus topic signal
-- carries (schema 5), and revision 11 the shared metatable of array-part
-- connection handles (schema 6). Revision 13 keeps schema 6: it adds the
-- optional `parts`, `helpers` and `partInterface`, and a state it creates no
-- longer holds the journal tables or the logout watcher, which the Journal
-- and Bus parts create when they load. A revision older than 13 never reads
-- such a state: it yields to the newer copy.
local STATE_SCHEMA = 6

-- The generation of what the core offers its parts: the `_state.helpers`
-- entries and the part records the core reads. Entries are only ever added; a
-- core that must change one adds a new entry and raises this number.
local PART_INTERFACE = 1

-- What a member of a part that is not loaded tells the caller to embed.
local PART_FILES = {
  Bus = "signalKit\\parts\\SignalKit-Bus.lua",
  Journal = "signalKit\\parts\\SignalKit-Journal.lua",
  Coalescing = "signalKit\\parts\\SignalKit-Coalescing.lua",
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

-- The methods the Bus part puts on the bus and bus-scope prototypes, which
-- stay core state; without the part each is a stub naming the file to embed.
-- `Coalesce` is the Coalescing part's.
local BUS_METHODS = {
  "DeclareTopic",
  "Publish",
  "Subscribe",
  "SubscribeOnce",
  "Unsubscribe",
  "Topics",
  "CreateScope",
}
local BUS_SCOPE_METHODS =
  { "Subscribe", "SubscribeOnce", "DisconnectAll", "Close", "IsClosed", "Reopen" }

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
    and type(rawget(implementation, "HasPart")) == "function"
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

---Whether `currentState` has this revision's shape: the base fields, the
---`UNBOUNDED` sentinel, the connection metatable, a valid set of package-wide
---limits, and the part records, helpers and interface generation. The journal
---tables and the logout watcher belong to the parts.
---@param currentState any
---@return boolean
local function validateState(currentState)
  local partInterface = validateStateBase(currentState) and rawget(currentState, "partInterface")
  return type(partInterface) == "number"
    and partInterface >= PART_INTERFACE
    and rawget(currentState, "schema") == STATE_SCHEMA
    and type(rawget(currentState, "unbounded")) == "table"
    and type(rawget(currentState, "connectionMetatable")) == "table"
    and type(rawget(currentState, "parts")) == "table"
    and type(rawget(currentState, "helpers")) == "table"
    and validateLimits(rawget(currentState, "limits"))
end

---Whether `implementation` carries package state of this revision's shape,
---with the published sentinel the one the state keeps.
---@param implementation table
---@return boolean
local function validateCurrentState(implementation)
  local currentState = rawget(implementation, "_state")
  return validateState(currentState)
    and rawget(implementation, "UNBOUNDED") == rawget(currentState, "unbounded")
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
-- subscriptions survive an in-place upgrade and gain the newer methods, the
-- package-wide limits, and what the parts share with the core.

---A connection handle returned by `signal:Connect`, `signal:Once` or a bus
---subscription.
---
---Since revision 11 a handle keeps its fields in the array part (see
---"Listener storage"): `[1]` the listener, `[2]` whether it still delivers,
---`[3]` whether it disconnects before its first call, `[4]` its signal and,
---for a bus scope's subscription, `[5]` the scope. Handles of a signal an
---older revision created keep the named fields below.
---@class SignalKit.Connection
---@field Disconnect fun(self: SignalKit.Connection): boolean
---@field IsConnected fun(self: SignalKit.Connection): boolean
---@field package [integer] any The array-part fields; private to this file.
---@field package _connected boolean? Older layout: whether the connection still delivers.
---@field package _signal SignalKit.Signal? Older layout: the signal it is on, `nil` once disconnected.
---@field package _callback function? Older layout: the listener, `nil` once disconnected.
---@field package _once boolean? Older layout: whether it disconnects before its first call.
---@field package _busScope SignalKit.BusScope? Older layout: the bus scope that owns it, if any.
---@field package _busCallback function? Only on a bus subscription made before revision 9.

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
---@field package _listeners SignalKit.Connection[] Connections in connection order, tombstones included; private to this file.
---@field package _tombstones integer? Disconnected connections still in `_listeners`; absent before revision 2.
---@field package _generation integer? Firings so far; absent before revision 7.
---@field package _firing integer? `Fire` calls walking `_listeners`; absent before revision 9.
---@field package _isolated boolean? Whether `Fire` isolates each delivery (a bus topic).
---@field package _layout integer? `2` when its handles use the array-part layout (revision 11); absent before.
---@field package _onFirst SignalKit.SignalHook|false|nil
---@field package _onLast SignalKit.SignalHook|false|nil
---@field Connect fun(self: SignalKit.Signal, callback: fun(...)|table, methodName: string?): SignalKit.Connection
---@field Once fun(self: SignalKit.Signal, callback: fun(...)|table, methodName: string?): SignalKit.Connection
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
---@field package _name string The bus name; private to this file.
---@field package _closed boolean Whether the bus is closed.
---@field package _openTopics boolean Whether undeclared topics may be published.
---@field package _topics table<string, SignalKit.TopicRecord> Topic records by name.
---@field package _maxListeners integer|table Live listeners one topic may hold, or `UNBOUNDED`.
---@field DeclareTopic fun(self: SignalKit.Bus, topic: string, options: SignalKit.TopicOptions?): true|nil, "full"?
---@field Publish fun(self: SignalKit.Bus, topic: string, ...: any)
---@field Subscribe fun(self: SignalKit.Bus, topic: string, callback: fun(...: any)|table, methodName: string?): SignalKit.Connection|nil, "full"?
---@field SubscribeOnce fun(self: SignalKit.Bus, topic: string, callback: fun(...: any)|table, methodName: string?): SignalKit.Connection|nil, "full"?
---@field Unsubscribe fun(self: SignalKit.Bus, topic: string, callback: fun(...: any)): integer
---@field Topics fun(self: SignalKit.Bus): string[]
---@field CreateScope fun(self: SignalKit.Bus): SignalKit.BusScope

---An ownership scope for subscriptions on one bus.
---@class SignalKit.BusScope
---@field Subscribe fun(self: SignalKit.BusScope, topic: string, callback: fun(...: any)|table, methodName: string?): SignalKit.Connection|nil, "full"?
---@field SubscribeOnce fun(self: SignalKit.BusScope, topic: string, callback: fun(...: any)|table, methodName: string?): SignalKit.Connection|nil, "full"?
---@field DisconnectAll fun(self: SignalKit.BusScope): integer
---@field Close fun(self: SignalKit.BusScope): boolean
---@field IsClosed fun(self: SignalKit.BusScope): boolean
---@field Reopen fun(self: SignalKit.BusScope): boolean, "closed"?

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
---@field HasPart fun(self: SignalKit, name: string): boolean Whether the named part (`"Bus"`, `"Journal"`, `"Coalescing"`) is loaded.

local Connection = rawget(SignalKit, "Connection")
local state = rawget(SignalKit, "_state")

---Build the journal method table and the metatable journal instances carry,
---for state an older revision created (the Journal part builds them for a
---state this revision created).
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

---Build empty package state of the current schema. The journal tables and the
---logout watcher are created by the Journal and Bus parts when they load.
---@return table
local function newState()
  local busPrototype = {}
  local scopePrototype = {}
  return {
    schema = STATE_SCHEMA,
    -- Bus name to bus, and how many there are, for the `maxBuses` bound.
    buses = {},
    busCount = 0,
    -- Buses and scopes are recognised by metatable identity, so the
    -- metatables live here and survive upgrades; the Bus part fills the
    -- prototypes they index, and a newer copy refills them.
    busPrototype = busPrototype,
    busMetatable = { __index = busPrototype },
    scopePrototype = scopePrototype,
    scopeMetatable = { __index = scopePrototype },
    -- Array-part connection handles are recognised by metatable identity,
    -- so their metatable lives here and every later revision shares it.
    connectionMetatable = { __index = Connection },
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
    -- The parts loaded (name to record), what they call, and the generation
    -- of that interface.
    parts = {},
    helpers = {},
    partInterface = PART_INTERFACE,
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
  rawset(oldState, "schema", 4)
end

---Bring schema-4 state (revisions 7 and 8) to schema 5 in place: flag every
---existing bus topic signal as isolated, so `Fire` isolates each delivery
---itself from now on (see "Listener isolation").
---
---Subscriptions those revisions made wrap their callback in a delivery closure
---that isolates on its own; they keep it and are isolated twice, which reports
---an error exactly once and costs only them an extra call. Their `_callback` is
---not rewritten, because an older copy's `Fire` may still be walking the
---signal below this upgrade and would then call the bare callback without isolation.
---@param oldState table
local function upgradeSchemaFour(oldState)
  for _, bus in pairs(rawget(oldState, "buses")) do
    local topics = type(bus) == "table" and rawget(bus, "_topics") or nil
    if type(topics) == "table" then
      for _, record in pairs(topics) do
        local signal = type(record) == "table" and rawget(record, "signal") or nil
        if type(signal) == "table" then
          rawset(signal, "_isolated", true)
        end
      end
    end
  end
  rawset(oldState, "schema", 5)
end

---Bring schema-5 state (revisions 9 and 10) to schema 6 in place: add the
---shared metatable of array-part connection handles. The bus topic signals
---those revisions created are converted to the array-part layout once the
---listener storage below exists (see "Commit"); raw signals keep their layout
---until a connect finds them idle.
---@param oldState table
local function upgradeSchemaFive(oldState)
  -- A metatable already present is kept, so handles that carry it stay
  -- recognised.
  if type(rawget(oldState, "connectionMetatable")) ~= "table" then
    rawset(oldState, "connectionMetatable", { __index = Connection })
  end
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
  if rawget(state, "schema") == 4 then
    upgradeSchemaFour(state)
  end
  if rawget(state, "schema") == 5 then
    upgradeSchemaFive(state)
  end
  -- Revision 12 kept `parts` for the Coalescing part; older ones had none.
  if type(rawget(state, "parts")) ~= "table" then
    rawset(state, "parts", {})
  end
  if type(rawget(state, "helpers")) ~= "table" then
    rawset(state, "helpers", {})
  end
  local partInterface = rawget(state, "partInterface")
  if type(partInterface) ~= "number" or partInterface < PART_INTERFACE then
    rawset(state, "partInterface", PART_INTERFACE)
  end
  if not validateState(state) then
    error("MoltenCodes SignalKit package state is corrupted or incomplete", 2)
  end
end

local SIGNAL_METATABLE = { __index = SignalKit }
local CONNECTION_METATABLE = rawget(state, "connectionMetatable")
local BUS_PROTOTYPE = rawget(state, "busPrototype")
local SCOPE_PROTOTYPE = rawget(state, "scopePrototype")
local UNBOUNDED = rawget(state, "unbounded")
local sharedLimits = rawget(state, "limits")
local parts = rawget(state, "parts")

-- Secret values ----------------------------------------------------------------
--
-- On a client with secret values, comparing a secret with a value of its own
-- type, or using it as a key, raises inside SignalKit instead of at the caller.
-- Values SignalKit did not create are tested for absence with `type`, the
-- repository rule, and checked with the client's `issecretvalue` before any
-- comparison.

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

-- Receiver validation ---------------------------------------------------------
--
-- `SignalKit.Connect(callback)` is an easy typo for `signal:Connect(callback)`.
-- Without a receiver check the misuse surfaced as "attempt to index a function
-- value" or "attempt to get length of a nil value" somewhere inside SignalKit,
-- which names neither the mistake nor the line that made it.
--
-- A signal is recognised by a field type test rather than a metatable
-- comparison on purpose: each revision builds its own signal metatable, so
-- metatable identity would reject instances created by the revision it
-- upgraded. Buses, scopes and connection handles carry metatables kept in the
-- shared state instead, so they are recognised by identity.

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

---Whether `self` is a connection handle in the named-field layout: a handle of
---a signal an older revision created, which keeps that layout until the
---signal is converted (see "Listener storage").
---@param self any
---@return boolean
local function isNamedLayoutHandle(self)
  return type(self) == "table" and type(rawget(self, "_connected")) == "boolean"
end

---Whether `self` is a connection handle of this package, in either layout.
---
---Every handle this revision creates carries the shared connection metatable,
---which only SignalKit holds, so one comparison proves it; `getmetatable`
---answers `nil` or another table for anything else and never raises.
---@param self any
---@return boolean
local function isConnectionHandle(self)
  return getmetatable(self) == CONNECTION_METATABLE or isNamedLayoutHandle(self)
end

-- Listener storage -------------------------------------------------------------
--
-- A disconnect marks its connection and leaves it in place as a tombstone, so
-- disconnecting is O(1). The array is compacted once at least half of its
-- slots are tombstones: each compaction is O(n) but removes n/2 slots, which
-- keeps disconnect amortized O(1) and bounds the array at twice the live
-- listener count.
--
-- How the array is edited depends on whether a dispatch of the signal is
-- walking it. `Fire` raises the signal's `_firing` depth for the length of its
-- walk. At depth zero nothing holds a position in the array, so a disconnect
-- edits it in place and allocates nothing: tombstones at the tail are dropped
-- at once, which is where connect-then-disconnect churn leaves them, and a
-- compaction shifts the live entries down. While a dispatch runs, compaction
-- replaces the array instead of editing it, as every revision before 9 always
-- did: the dispatch keeps its own array and fixed boundary, and because
-- connection objects are shared between the old and new arrays the
-- disconnected flag stays visible in both.
--
-- A listener error that escapes the outermost `Fire` of a raw signal skips the
-- restore and leaves the depth raised. That signal then compacts by
-- replacement, which is always safe; nothing else changes. A signal created by
-- an older revision carries no depth and is treated the same way for good,
-- because an older copy's `Fire` may still be walking it on the stack below an
-- in-place upgrade.
--
-- The live listener count is the array length minus the tombstones, both of
-- which connect and disconnect already maintain, so the `onFirst` and `onLast`
-- hooks cost a signal without them one truthiness test per connect and
-- disconnect. A hook runs after its transition is committed and after the
-- array is in its final shape, so a hook that connects or disconnects inside
-- itself sees a consistent signal and causes, at most, the opposite hook.
--
-- Connection handles are the only per-connection allocation. Since revision 11
-- a handle keeps its fields in the array part, which costs 16 bytes a slot
-- where a hash node costs 40:
--
--   [1] the listener, `nil` once disconnected
--   [2] `true` while it delivers, `false` afterwards
--   [3] whether it disconnects before its first call
--   [4] its signal, `nil` once disconnected
--   [5] the bus scope that owns it, only on a bus scope's subscription
--
-- That is 128 bytes for a handle (144 with a scope) against 224 (384) for the
-- named fields revisions up to 10 used. A signal created by revision 11 or
-- later carries `_layout = 2` and only array-part handles. A signal an older
-- revision created keeps its named-field handles (`_callback`, `_connected`,
-- `_once`, `_signal`, `_busScope`), and a connect adds named-field handles to
-- it, until a connect finds it idle (`_firing` is `0`, so no `Fire` of any
-- revision is walking it): then every handle is rewritten in place, the same
-- tables, so handles held elsewhere keep working. A signal from before
-- revision 9 has no depth and is never converted. The walks below read the
-- layout once per signal and index with the matching keys, so both layouts
-- cost the same per listener. Fields are only ever written when they exist:
-- in Lua 5.1 assigning even `nil` to a missing key inserts it, which can grow
-- a full table.

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

---The key under which the handles of `signal` keep their connected flag: `2`
---in the array-part layout, `"_connected"` in the named-field layout.
---@param signal table
---@return integer|string
local function connectedKeyOf(signal)
  -- A field an older revision's signal lacks reads `nil` through the facade.
  if signal._layout == 2 then
    return 2
  end
  return "_connected"
end

---Whether `connection` still delivers, whichever layout it has.
---@param connection table
---@return boolean
local function isLiveHandle(connection)
  -- A named-field handle has no `[2]`, and an array-part handle no
  -- `_connected`; both read `nil` through the connection prototype.
  return connection[2] == true or connection._connected == true
end

---Replaces the listener array of `signal` with one holding only live entries,
---leaving the old array untouched for a dispatch that is walking it.
---@param signal table
---@param listeners table
---@param connectedKey integer|string see `connectedKeyOf`
local function compact(signal, listeners, connectedKey)
  local compacted = {}
  local nextIndex = 1

  for index = 1, #listeners do
    local connection = listeners[index]
    if connection[connectedKey] == true then
      compacted[nextIndex] = connection
      nextIndex = nextIndex + 1
    end
  end

  rawset(signal, "_listeners", compacted)
  rawset(signal, "_tombstones", 0)
end

---Drop the tombstones of an array no dispatch is walking, without allocating:
---first those at the tail, then, past the compaction threshold, every other
---one by shifting the live entries down in order.
---@param listeners table
---@param total integer the array length
---@param tombstones integer the tombstones in the array
---@param connectedKey integer|string see `connectedKeyOf`
---@return integer tombstones the tombstones left in the array
local function settleInPlace(listeners, total, tombstones, connectedKey)
  while total > 0 and listeners[total][connectedKey] ~= true do
    listeners[total] = nil
    total = total - 1
    tombstones = tombstones - 1
  end

  if not shouldCompact(tombstones, total) then
    return tombstones
  end

  local live = 0
  for index = 1, total do
    local connection = listeners[index]
    if connection[connectedKey] == true then
      live = live + 1
      listeners[live] = connection
    end
  end
  for index = live + 1, total do
    listeners[index] = nil
  end
  return 0
end

---Mark `connection` disconnected and release what it references.
---
---The handle stays in the listener array until it is settled or compacted
---away, but the callback is released immediately: it is normally far larger
---than the handle that holds it. `_busCallback` exists only on bus
---subscriptions made before revision 9 and a bus scope exists only on a bus
---scope's subscriptions, so each is cleared only where it exists.
---@param connection table
local function releaseConnection(connection)
  local scope
  if connection[2] ~= nil then
    connection[2] = false
    connection[4] = nil
    connection[1] = nil
    scope = connection[5]
    if scope ~= nil then
      connection[5] = nil
    end
  else
    connection._connected = false
    connection._signal = nil
    connection._callback = nil
    scope = connection._busScope
    if scope ~= nil then
      connection._busScope = nil
    end
  end

  -- An absent field reads `nil` through the connection prototype, which has
  -- no such field; plain indexing keeps these reads VM instructions.
  if connection._busCallback ~= nil then
    connection._busCallback = nil
  end
  -- A bus scope's subscription reports its disconnect so the scope can
  -- compact its list (Bus part). A scope exists only with the part, or as
  -- one an older revision made, which the part adopts when it loads.
  if scope ~= nil then
    local busPart = parts.Bus
    if busPart ~= nil then
      busPart.noteScopeDisconnect(scope)
    end
  end
end

---@param connection table
---@return boolean disconnected `true` only for the call that transitioned the state.
local function disconnectConnection(connection)
  local signal, connectedKey
  if connection[2] == true then
    signal, connectedKey = connection[4], 2
  elseif connection._connected == true then
    signal, connectedKey = connection._signal, "_connected"
  else
    return false
  end
  releaseConnection(connection)

  -- A signal from revision 1 has no counter and reads as zero tombstones.
  local listeners = signal._listeners
  local total = #listeners
  local tombstones = (signal._tombstones or 0) + 1
  -- The live count before the array is settled; settling only removes
  -- tombstones, so it is the same afterwards.
  local live = total - tombstones

  if signal._firing == 0 then
    if tombstones == 1 and listeners[total] == connection then
      -- The churn case, a connect undone before anything else: the only
      -- tombstone is the tail, so settling is one removal.
      listeners[total] = nil
      tombstones = 0
    else
      tombstones = settleInPlace(listeners, total, tombstones, connectedKey)
    end
    signal._tombstones = tombstones
  elseif shouldCompact(tombstones, total) then
    compact(signal, listeners, connectedKey)
  else
    signal._tombstones = tombstones
  end

  -- A signal without hooks, or one created before hooks existed, stores
  -- `false` or nothing here and pays only this test.
  local onLast = signal._onLast
  if onLast and live == 0 then
    onLast(signal)
  end

  return true
end

---Rewrite every handle of an idle signal an older revision created into the
---array-part layout, in place, and mark the signal converted.
---
---The caller has checked that `_firing` is `0`, so no `Fire` of any revision
---is walking the array. Each handle stays the same table, so a handle an
---addon holds keeps working; it takes the shared connection metatable, whose
---prototype is the same `Connection` table its old one indexed. A delivery
---closure and `_busCallback` of a subscription made before revision 9 are
---kept as they are.
---@param signal table
local function convertToArrayLayout(signal)
  local listeners = signal._listeners
  for index = 1, #listeners do
    local connection = listeners[index]
    local callback = connection._callback
    local connected = connection._connected == true
    local once = connection._once == true
    local owner = connection._signal
    local scope = connection._busScope
    connection._callback = nil
    connection._connected = nil
    connection._once = nil
    connection._signal = nil
    if scope ~= nil then
      connection._busScope = nil
    end
    connection[1] = callback
    connection[2] = connected
    connection[3] = once
    connection[4] = owner
    if scope ~= nil then
      connection[5] = scope
    end
    setmetatable(connection, CONNECTION_METATABLE)
  end
  signal._layout = 2
end

---Append a new connection of `callback` to `signal`, whose listener array is
---`listeners`; the caller validated both.
---@param signal table
---@param listeners table
---@param callback function
---@param once boolean whether the connection disconnects before its first call
---@param busScope table|nil the bus scope that owns the subscription
---@return SignalKit.Connection
local function attach(signal, listeners, callback, once, busScope)
  local connection
  if signal._layout ~= 2 and signal._firing == 0 then
    convertToArrayLayout(signal)
  end
  -- Separate constructors, because a constructor sizes the table by the
  -- items it names: naming the scope for every handle would grow the ones
  -- that have none.
  if signal._layout == 2 then
    if busScope == nil then
      connection = { callback, true, once, signal }
    else
      connection = { callback, true, once, signal, busScope }
    end
  elseif busScope == nil then
    -- A signal an older revision created, while a dispatch walks it.
    connection = { _signal = signal, _callback = callback, _connected = true, _once = once }
  else
    connection = {
      _signal = signal,
      _callback = callback,
      _connected = true,
      _once = once,
      _busScope = busScope,
    }
  end
  setmetatable(connection, CONNECTION_METATABLE)

  local nextIndex = #listeners + 1
  listeners[nextIndex] = connection

  -- The listener is in place before the hook runs, so a hook that connects
  -- again sees two live listeners and one that disconnects everything sees
  -- the 1→0 transition. The subtraction is paid only when a hook exists.
  local onFirst = signal._onFirst
  if onFirst and nextIndex - (signal._tombstones or 0) == 1 then
    onFirst(signal)
  end

  return connection
end

-- Method-name callbacks ----------------------------------------------------------
--
-- Every method that takes a listener also takes a receiver table and the name
-- of one of its methods, the form CallbackHandler-1.0 and AceEvent-3.0 offer.
-- The name is checked when the listener is registered: a receiver without
-- such a method raises at the caller's line. The method is then looked up on
-- the receiver at every delivery, as those libraries do, so replacing it later
-- (a hook on it, say) reaches existing connections. A method missing at
-- delivery time raises inside the delivery: a bus reports it through the host
-- error handler and goes on, a raw signal propagates it to the caller of
-- `Fire`, exactly as for any listener error; the connection stays.

---Check the method form of a listener and return the function that delivers
---to it: `receiver[methodName](receiver, ...)`, looked up at each call.
---@param receiver table
---@param methodName any
---@param label string qualified public method name
---@param level integer stack level the failures are reported at
---@return function
local function bindMethod(receiver, methodName, label, level)
  if isSecret(methodName) then
    error(label .. " methodName must not be a secret value", level)
  end
  if type(methodName) ~= "string" or methodName == "" then
    error(label .. " methodName must be a non-empty string", level)
  end
  if type(receiver[methodName]) ~= "function" then
    error(label .. ' receiver has no method "' .. methodName .. '"', level)
  end
  return function(...)
    local method = receiver[methodName]
    -- `== nil` is safe even for a secret: on the client a comparison with
    -- `nil` answers `false` without raising (docs/EMBEDDING.md).
    if method == nil then
      error('SignalKit receiver has no method "' .. methodName .. '"', 2)
    end
    return method(receiver, ...)
  end
end

---Shared implementation of `Connect` and `Once`.
---@param signal any receiver the public method was called on
---@param callback any candidate listener, or a receiver table, validated here
---@param once boolean whether the connection disconnects before its first call
---@param methodName "Connect"|"Once" public method name, used in the argument error
---@param receiverMessage string error text raised when `signal` is not a signal
---@param listenerMethod any the method name when `callback` is a receiver
---@return SignalKit.Connection
local function connect(signal, callback, once, methodName, receiverMessage, listenerMethod)
  local listeners = listenersOf(signal)
  if listeners == nil then
    error(receiverMessage, 3)
  end

  if type(callback) ~= "function" then
    local label = "SignalKit:" .. methodName
    if type(callback) ~= "table" then
      error(
        label .. " callback must be a function, or a receiver table followed by a method name",
        3
      )
    end
    callback = bindMethod(callback, listenerMethod, label, 4)
  end

  local connection = attach(signal, listeners, callback, once, nil)
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
    and (type(rawget(receiver, "onFirst")) ~= "nil" or type(rawget(receiver, "onLast")) ~= "nil")
end

---Build a signal table with the shared listener layout.
---@param onFirst SignalKit.SignalHook|false
---@param onLast SignalKit.SignalHook|false
---@param isolated boolean whether `Fire` isolates each delivery (bus topics)
---@return table
local function newSignalTable(onFirst, onLast, isolated)
  return {
    _listeners = {},
    _tombstones = 0,
    -- Incremented by every `Fire`; a Lua 5.1 double counts exactly to 2^53.
    _generation = 0,
    -- How many `Fire` calls are walking `_listeners`; see "Listener storage".
    _firing = 0,
    _isolated = isolated,
    _onFirst = onFirst,
    _onLast = onLast,
    -- Its handles use the array-part layout; see "Listener storage".
    _layout = 2,
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
  return setmetatable(newSignalTable(onFirst, onLast, false), SIGNAL_METATABLE)
end

---Connects `callback` for every future dispatch, or the method `methodName`
---of the receiver table `callback`.
---@param self SignalKit.Signal
---@param callback fun(...: any)|table
---@param methodName string? required with a receiver
---@return SignalKit.Connection connection
local function connectListener(self, callback, methodName)
  return connect(self, callback, false, "Connect", CONNECT_RECEIVER_MESSAGE, methodName)
end

---Connects `callback` for at most one dispatch, or the method `methodName` of
---the receiver table `callback`.
---@param self SignalKit.Signal
---@param callback fun(...: any)|table
---@param methodName string? required with a receiver
---@return SignalKit.Connection connection
local function connectOnce(self, callback, methodName)
  return connect(self, callback, true, "Once", ONCE_RECEIVER_MESSAGE, methodName)
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

  -- Past the receiver check the signal is known, so its fields are read
  -- with plain indexing, a VM instruction, instead of `rawget`, a C call. A
  -- field an older revision's signal lacks falls through to the facade,
  -- which carries no underscore field of a signal, and reads as `nil`.
  -- Only a bus topic signal carries the flag, and the Bus part delivers to
  -- it, each delivery isolated. A topic signal an older revision left in a
  -- session without the part falls through to the plain walk below.
  if self._isolated == true then
    local busPart = parts.Bus
    if busPart ~= nil then
      busPart.fireIsolated(self, ...)
      return
    end
  end

  -- The generation moves before any listener runs, so a listener reading it
  -- sees the firing it is being delivered. A signal created before revision
  -- 7 has no counter; `or 0` is its in-place upgrade path.
  self._generation = (self._generation or 0) + 1

  -- The depth is restored to the value read here rather than decremented,
  -- so an outer dispatch also repairs a nested one an error cut short. A
  -- signal from before revision 9 has no depth and keeps none (see
  -- "Listener storage").
  local depth = self._firing
  if depth ~= nil then
    self._firing = depth + 1
  end

  -- The layout is read once per dispatch; see "Listener storage".
  ---@type integer|string, integer|string, integer|string
  local callbackKey, connectedKey, onceKey = 1, 2, 3
  if self._layout ~= 2 then
    callbackKey, connectedKey, onceKey = "_callback", "_connected", "_once"
  end
  for index = 1, #listeners do
    local connection = listeners[index]
    if connection[connectedKey] == true then
      local callback = connection[callbackKey]

      if connection[onceKey] == true then
        -- Disconnect before invocation so recursive Fire calls cannot
        -- observe the once-listener a second time.
        disconnectConnection(connection)
      end

      callback(...)
    end
  end

  if depth ~= nil then
    self._firing = depth
  end
end

---Disconnect every live listener of `signal`; the caller validated it.
---@param signal table
---@param listeners table
---@return integer disconnected
local function disconnectEveryListener(signal, listeners)
  local disconnected = 0
  local count = #listeners

  -- With no dispatch walking the array it is emptied in place. Otherwise it
  -- is replaced first: a callback dispatching the older array finds these
  -- shared connection objects disconnected and none of the remaining
  -- callbacks in it runs.
  local idle = rawget(signal, "_firing") == 0
  if not idle then
    rawset(signal, "_listeners", {})
  end
  rawset(signal, "_tombstones", 0)

  local connectedKey = connectedKeyOf(signal)
  for index = 1, count do
    local connection = listeners[index]
    if connection[connectedKey] == true then
      disconnected = disconnected + 1
      releaseConnection(connection)
    end
  end

  if idle then
    for index = count, 1, -1 do
      listeners[index] = nil
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
  -- `isConnectionHandle`, inlined: this is half of every connect-disconnect
  -- pair, and the call frame would cost more than the test. The metatable
  -- comparison settles every handle this revision or a later one made; only
  -- a named-field handle of an older revision's signal takes the second test.
  if getmetatable(self) ~= CONNECTION_METATABLE and not isNamedLayoutHandle(self) then
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

  return isLiveHandle(self)
end

-- Argument checks --------------------------------------------------------------
--
-- Every public entry point validates at its own caller's line. Callers keep
-- results in a local before returning them: a Lua tail call would remove the
-- public frame the stack level is counted against.

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

-- shared:begin validateFacade 1 __FACADE__=SignalKit
-- Copied from tooling/shared/lua/validateFacade.lua by python3 -m tooling.shared.sync; edit that file, not this copy.
---Raise at `level` unless `receiver` is the SignalKit facade.
---@param receiver any the table the method was called on
---@param label string qualified method name, used in the argument error
---@param level integer stack level the failure is reported at
local function validateFacade(receiver, label, level)
  if type(receiver) ~= "table" or receiver ~= SignalKit then
    local hint = "; use " .. label .. "(...)"
    error(label .. " must be called on the SignalKit facade" .. hint, level)
  end
end
-- shared:end validateFacade

-- shared:begin describeKey 1
-- Copied from tooling/shared/lua/describeKey.lua by python3 -m tooling.shared.sync; edit that file, not this copy.
---Name `key` for an error message without running any of the caller's code.
---@param key any
---@return string
local function describeKey(key)
  if isSecret(key) then
    return "<secret>"
  end
  local kind = type(key)
  if kind == "string" then
    return key
  end
  if kind == "number" or kind == "boolean" then
    return tostring(key)
  end
  return "<" .. kind .. ">"
end
-- shared:end describeKey

-- Parts ------------------------------------------------------------------------
--
-- A part records itself in `_state.parts.<Part>` with its revision and the
-- methods it provides, by target: `facadeMethods` on the facade,
-- `busMethods` and `scopeMethods` on the bus and bus-scope prototypes,
-- `journalMethods` on the journal prototype (the Coalescing part keeps its
-- revision 1 record shape, `methods.BusCoalesce` and `methods.ScopeCoalesce`).
-- It reads the core's functions from `_state.helpers` at call time, so a core
-- upgraded after the part loaded serves it. The commit below installs a stub
-- for every member and then the methods of every part already loaded, so
-- whichever loaded first, the part serves.

---The message a member of `partName` raises while that part is not loaded.
---@param member string the member as its caller wrote it
---@param partName string
---@return string
local function missingPart(member, partName)
  return member
    .. " is in SignalKit's "
    .. partName
    .. " part, which is not loaded: add "
    .. PART_FILES[partName]
    .. " to embeds.xml after signalKit\\SignalKit.lua"
end

---A method that raises at its caller, naming the part to embed. The message is
---built when it raises, so no stub keeps a long string resident.
---@param member string the member as its caller wrote it
---@param partName string
---@return function
local function newPartStub(member, partName)
  return function()
    error(missingPart(member, partName), 2)
  end
end

---Whether the named part is loaded in this session: `"Bus"`, `"Journal"` or
---`"Coalescing"`. Code that uses a part only when it is there asks this, never
---whether a method is a function: the facade keeps every member, raising when
---its part is absent.
---@param self SignalKit
---@param name string
---@return boolean
local function hasPart(self, name)
  validateFacade(self, "SignalKit:HasPart", 3)
  refuseSecret(name, "SignalKit:HasPart name", 3)
  if type(name) ~= "string" then
    error("SignalKit:HasPart name must be a string", 2)
  end
  return type(rawget(parts, name)) == "table"
end

-- Buses an older revision left. A revision before 13 kept buses in the core,
-- so a session that upgraded from one may hold buses with live subscriptions
-- before the Bus part loads. The part adopts them as they are when it loads;
-- until then their methods are the stubs below, and `CloseAddonBus` still
-- performs the terminal close LifecycleKit and the logout watcher ask for.
-- Built only in such a session (`_state.inheritedBuses`, sticky); elsewhere
-- no bus can exist without the part and this code is freed after load.

---@type fun(addonName: string): boolean|nil
local closeInheritedBus = nil
if type(previousRevision) ~= "nil" and previousRevision < 13 and next(rawget(state, "buses")) then
  rawset(state, "inheritedBuses", true)
end
if rawget(state, "inheritedBuses") == true then
  closeInheritedBus = function(addonName)
    local bus = rawget(rawget(state, "buses"), addonName)
    if bus == nil or rawget(bus, "_closed") == true then
      return false
    end
    rawset(bus, "_closed", true)
    local subscription = rawget(bus, "_shutdownSubscription")
    if subscription ~= nil and subscription ~= false then
      rawset(bus, "_shutdownSubscription", false)
      subscription:Disconnect()
    end
    for _, record in pairs(rawget(bus, "_topics")) do
      local signal = rawget(record, "signal")
      if signal ~= false then
        disconnectEveryListener(signal, rawget(signal, "_listeners"))
      end
    end
    return true
  end
end

-- Facade methods ---------------------------------------------------------------

---Close the bus named after an addon, disconnecting every subscription on it.
---
---Closing is terminal: the closed bus stays registered under its name, refuses
---new subscriptions and scopes, and publishes on it deliver nothing. Without
---the Bus part no addon bus can exist, so the answer is `false` after the
---argument checks, and LifecycleKit's shutdown keeps working unchanged.
---@param self SignalKit
---@param addonName string addon folder name
---@return boolean closed `false` when there was no such bus or it was already closed.
local function facadeCloseAddonBus(self, addonName)
  validateFacade(self, "SignalKit:CloseAddonBus", 3)
  validateNonEmptyString(addonName, "SignalKit:CloseAddonBus addonName", 3)
  local busPart = parts.Bus
  if busPart ~= nil then
    local closed = busPart.closeAddonBus(addonName)
    return closed
  end
  if closeInheritedBus ~= nil then
    local closed = closeInheritedBus(addonName)
    return closed
  end
  return false
end

---Validate one `SetLimits` entry: a recognised name, an integer within the
---limit's ceiling, never `UNBOUNDED` (each limit names its reason).
---@param key any
---@param value any
---@param level integer stack level the failures are reported at
local function validateLimitEntry(key, value, level)
  local ceiling = LIMIT_CEILINGS[key]
  if ceiling == nil then
    error("SignalKit:SetLimits limits." .. describeKey(key) .. " is not a recognised limit", level)
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
---integer only up to its ceiling. The limits guard the Bus and Journal parts'
---memory, but they stay here so `SetLimits` and `GetLimits` keep one shape
---whichever parts are loaded. This loop stays hand-written: the shared
---`limits` block measures more resident (`tooling/shared/pins.json`).
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

-- Every member a part provides, as a stub until the part's methods replace it.
rawset(SignalKit, "Bus", newPartStub("SignalKit:Bus", "Bus"))
rawset(SignalKit, "ForAddon", newPartStub("SignalKit:ForAddon", "Bus"))
rawset(SignalKit, "NewJournal", newPartStub("SignalKit:NewJournal", "Journal"))
-- Without the Bus part no bus or scope can exist, so the prototypes need stubs
-- only for the buses an older revision left (see "Parts").
if rawget(state, "inheritedBuses") == true then
  for index = 1, #BUS_METHODS do
    local name = BUS_METHODS[index]
    rawset(BUS_PROTOTYPE, name, newPartStub("SignalKit.Bus:" .. name, "Bus"))
  end
  for index = 1, #BUS_SCOPE_METHODS do
    local name = BUS_SCOPE_METHODS[index]
    rawset(SCOPE_PROTOTYPE, name, newPartStub("SignalKit.BusScope:" .. name, "Bus"))
  end
end
-- A state an older revision created holds the journal prototype, and its
-- journals keep their slots; they record again once the Journal part loads.
local inheritedJournalPrototype = rawget(state, "journalPrototype")
if type(inheritedJournalPrototype) == "table" then
  rawset(inheritedJournalPrototype, "Fire", newPartStub("SignalKit.Journal:Fire", "Journal"))
  rawset(inheritedJournalPrototype, "History", newPartStub("SignalKit.Journal:History", "Journal"))
end

---Install the methods `methods` names on `target`.
---@param target table|nil
---@param methods any
local function installMethods(target, methods)
  if type(target) ~= "table" or type(methods) ~= "table" then
    return
  end
  for name, method in next, methods do
    rawset(target, name, method)
  end
end

-- A part loaded before this core keeps serving: its methods replace the stubs.
for _, part in next, parts do
  if type(part) == "table" then
    installMethods(SignalKit, rawget(part, "facadeMethods"))
    installMethods(BUS_PROTOTYPE, rawget(part, "busMethods"))
    installMethods(SCOPE_PROTOTYPE, rawget(part, "scopeMethods"))
    installMethods(rawget(state, "journalPrototype"), rawget(part, "journalMethods"))
  end
end

---Put `Coalesce` on the bus and bus-scope prototypes: the Coalescing part's
---methods when it is loaded (ADR 0001), and otherwise a method that names the
---file to embed. The part records itself in `_state.parts` and installs its
---methods; a later core revision reinstalls them here, so either load order
---ends with the part serving.
local function installPartMethods()
  if type(rawget(state, "parts")) ~= "table" then
    rawset(state, "parts", {})
  end
  local part = rawget(rawget(state, "parts"), "Coalescing")
  local methods = type(part) == "table" and part.methods or nil
  local busCoalesce = type(methods) == "table" and methods.BusCoalesce or nil
  local scopeCoalesce = type(methods) == "table" and methods.ScopeCoalesce or nil
  local fix = " needs SignalKit's Coalescing part, which is not loaded:"
    .. " add signalKit\\parts\\SignalKit-Coalescing.lua to your embeds.xml"
  if type(busCoalesce) ~= "function" then
    busCoalesce = function()
      error("SignalKit.Bus:Coalesce" .. fix, 2)
    end
  end
  if type(scopeCoalesce) ~= "function" then
    scopeCoalesce = function()
      error("SignalKit.BusScope:Coalesce" .. fix, 2)
    end
  end
  rawset(BUS_PROTOTYPE, "Coalesce", busCoalesce)
  rawset(SCOPE_PROTOTYPE, "Coalesce", scopeCoalesce)
end
installPartMethods()

rawset(SignalKit, "API", API_GENERATION)
rawset(SignalKit, "REVISION", IMPLEMENTATION_REVISION)
rawset(SignalKit, "New", newSignal)
rawset(SignalKit, "Connect", connectListener)
rawset(SignalKit, "Once", connectOnce)
rawset(SignalKit, "Fire", fire)
rawset(SignalKit, "DisconnectAll", disconnectAll)
rawset(SignalKit, "GetGeneration", getGeneration)
rawset(SignalKit, "CloseAddonBus", facadeCloseAddonBus)
rawset(SignalKit, "UNBOUNDED", UNBOUNDED)
rawset(SignalKit, "SetLimits", facadeSetLimits)
rawset(SignalKit, "GetLimits", facadeGetLimits)
rawset(SignalKit, "HasPart", hasPart)

-- What the parts call, refilled by every core revision so a part loaded
-- before an upgrade is served by the newer core. Parts read it at call time.
do
  local helpers = rawget(state, "helpers")
  rawset(helpers, "signalMetatable", SIGNAL_METATABLE)
  rawset(helpers, "attach", attach)
  rawset(helpers, "bindMethod", bindMethod)
  rawset(helpers, "newSignalTable", newSignalTable)
  rawset(helpers, "readSignalOptions", readSignalOptions)
  rawset(helpers, "fire", fire)
  rawset(helpers, "releaseConnection", releaseConnection)
  rawset(helpers, "disconnectConnection", disconnectConnection)
  rawset(helpers, "disconnectEveryListener", disconnectEveryListener)
  rawset(helpers, "tombstoneCount", tombstoneCount)
  rawset(helpers, "shouldCompact", shouldCompact)
  rawset(helpers, "compact", compact)
  rawset(helpers, "settleInPlace", settleInPlace)
  rawset(helpers, "connectedKeyOf", connectedKeyOf)
  rawset(helpers, "isLiveHandle", isLiveHandle)
  rawset(helpers, "convertToArrayLayout", convertToArrayLayout)
  rawset(helpers, "isIntegerUpTo", isIntegerUpTo)
  rawset(helpers, "refuseSecret", refuseSecret)
  rawset(helpers, "validateNonEmptyString", validateNonEmptyString)
  rawset(helpers, "validateFacade", validateFacade)
  rawset(helpers, "describeKey", describeKey)
end

if not validatePublicSurface(SignalKit) or not validateCurrentState(SignalKit) then
  error("MoltenCodes SignalKit package state is corrupted or incomplete", 2)
end

---Convert the idle bus topic signals an older revision created to the
---array-part handle layout, so later subscriptions on them are small too.
---A topic signal a dispatch is walking, or one from before revision 9 (no
---depth), keeps its layout; a later idle subscribe converts the first.
local function convertInheritedTopicSignals()
  for _, bus in pairs(rawget(state, "buses")) do
    for _, record in pairs(rawget(bus, "_topics")) do
      local signal = rawget(record, "signal")
      if signal ~= false and rawget(signal, "_layout") ~= 2 and rawget(signal, "_firing") == 0 then
        convertToArrayLayout(signal)
      end
    end
  end
end

if type(previousRevision) ~= "nil" then
  convertInheritedTopicSignals()
  -- Every in-place upgrade arranges the logout close of the addon buses it
  -- inherited; with the Bus part not loaded yet, the part does it when it
  -- loads.
  local busPart = rawget(parts, "Bus")
  if busPart ~= nil then
    busPart.arrangeInherited()
  end
end

return SignalKit
