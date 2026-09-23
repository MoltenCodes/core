-- MoltenCodes SignalKit
--
-- Deterministic, re-entrant callback dispatch for framework and addon code,
-- plus named message buses built on the same signals.
--
-- A signal is an anonymous dispatch point: whoever holds the reference owns
-- its listeners, and a listener error propagates to the caller of `Fire`.
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
-- Contents
-- --------
--   Constants ............. package identity, bus and listener bounds
--   Bootstrap ............. Registry resolution and registration
--   Shared state .......... LuaCATS types, state creation and migration
--   Receiver validation ... signal and connection receiver checks
--   Listener storage ...... tombstones, compaction, connect and disconnect
--   Signal methods ........ New, Connect, Once, Fire, DisconnectAll
--   Listener isolation .... allocation-free protected delivery for buses
--   Bus validation ........ receiver, name, topic and policy checks
--   Bus topics ............ topic records, declaration, subscription
--   Bus methods ........... DeclareTopic, Publish, Subscribe, Topics, ...
--   Bus scopes ............ owner scopes over one bus
--   Facade methods ........ Bus, ForAddon, CloseAddonBus
--   Commit ................ prototype/facade assignment and self-check

-- Constants ------------------------------------------------------------------

local PACKAGE_NAME = "signalKit"
local API_GENERATION = 1
local IMPLEMENTATION_REVISION = 4
local REQUIRED_REGISTRY_API = 2

-- Schema of the private `_state` table. Revisions 1 to 3 carried no state at
-- all; revision 4 introduced it together with named buses.
local STATE_SCHEMA = 1

-- Named buses are package state shared by every addon in the session, so their
-- number is bounded. Beyond it `SignalKit:Bus` answers `nil, "full"`.
local MAXIMUM_BUSES = 64

-- Distinct topics one bus may know, declared or merely subscribed to. Beyond it
-- `DeclareTopic` and a subscription to a new topic answer `nil, "full"`.
local MAXIMUM_TOPICS = 256

-- Live listeners one topic may hold. Beyond it a subscription answers
-- `nil, "full"`.
local MAXIMUM_LISTENERS = 256

-- A bus scope compacts its connection list once it reaches this many entries,
-- and afterwards at twice its live count, so it never grows beyond twice the
-- subscriptions it still owns.
local MINIMUM_SCOPE_COMPACTION = 16

-- Payload values staged in the reusable `xpcall` buffer with one multiple
-- assignment; wider payloads fall back to a `select` loop for the remainder.
local STAGED_ASSIGNMENT_SLOTS = 8

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
if Registry == nil and type(namespace) == "table" then
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
        and type(rawget(implementation, "Connect")) == "function"
        and type(rawget(implementation, "Once")) == "function"
        and type(rawget(implementation, "Fire")) == "function"
        and type(rawget(implementation, "DisconnectAll")) == "function"
        and type(rawget(implementation, "Bus")) == "function"
        and type(rawget(implementation, "ForAddon")) == "function"
        and type(rawget(implementation, "CloseAddonBus")) == "function"
        and type(rawget(rawget(implementation, "Connection"), "Disconnect")) == "function"
        and type(rawget(rawget(implementation, "Connection"), "IsConnected")) == "function"
end

---Whether `currentState` has the fields every schema-1 revision shares.
---@param currentState any
---@return boolean
local function validateStateBase(currentState)
    return type(currentState) == "table"
        and rawget(currentState, "schema") == STATE_SCHEMA
        and type(rawget(currentState, "buses")) == "table"
        and type(rawget(currentState, "busCount")) == "number"
        and type(rawget(currentState, "busPrototype")) == "table"
        and type(rawget(currentState, "busMetatable")) == "table"
        and type(rawget(currentState, "scopePrototype")) == "table"
        and type(rawget(currentState, "scopeMetatable")) == "table"
end

---Whether `implementation` carries package state of this revision's schema,
---with every bus and scope method committed.
---@param implementation table
---@return boolean
local function validateCurrentState(implementation)
    local currentState = rawget(implementation, "_state")
    return validateStateBase(currentState)
        and type(rawget(currentState, "isolate")) == "function"
        and hasMethods(rawget(currentState, "busPrototype"), BUS_METHODS)
        and hasMethods(rawget(currentState, "scopePrototype"), BUS_SCOPE_METHODS)
end

local SignalKit, previousRevision, selected = bootstrapPackage(Registry, {
    package = PACKAGE_NAME,
    api = API_GENERATION,
    revision = IMPLEMENTATION_REVISION,
    label = "MoltenCodes SignalKit",
    validatePublicSurface = validatePublicSurface,
    validateState = validateCurrentState,
})

if SignalKit == nil then
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

---An independent dispatch point created by `SignalKit:New()`.
---@class SignalKit.Signal
---@field Connect fun(self: SignalKit.Signal, callback: fun(...)): SignalKit.Connection
---@field Once fun(self: SignalKit.Signal, callback: fun(...)): SignalKit.Connection
---@field Fire fun(self: SignalKit.Signal, ...: any)
---@field DisconnectAll fun(self: SignalKit.Signal): integer

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
---@field New fun(self: SignalKit?): SignalKit.Signal
---@field Bus fun(self: SignalKit, name: string, options: SignalKit.BusOptions?): SignalKit.Bus|nil, "full"?
---@field ForAddon fun(self: SignalKit, addonName: string): SignalKit.Bus|nil, "full"?
---@field CloseAddonBus fun(self: SignalKit, addonName: string): boolean

local Connection = rawget(SignalKit, "Connection")
local state = rawget(SignalKit, "_state")

---Build empty package state of the current schema.
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
        -- metatables live here and survive upgrades; a newer copy refills the
        -- prototypes they index.
        busPrototype = busPrototype,
        busMetatable = { __index = busPrototype },
        scopePrototype = scopePrototype,
        scopeMetatable = { __index = scopePrototype },
        -- Delivery closures read the isolation function from here, so a newer
        -- copy replaces it for subscriptions that already exist.
        isolate = false,
    }
end

if previousRevision == nil then
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
end

local SIGNAL_METATABLE = { __index = SignalKit }
local CONNECTION_METATABLE = { __index = Connection }
local BUS_PROTOTYPE = rawget(state, "busPrototype")
local BUS_METATABLE = rawget(state, "busMetatable")
local SCOPE_PROTOTYPE = rawget(state, "scopePrototype")
local SCOPE_METATABLE = rawget(state, "scopeMetatable")

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

---Mark `connection` disconnected and release what it references.
---
---The handle stays in the listener array until the next compaction, but the
---callback closures are released immediately: they are normally far larger
---than the handle that holds them. `_busCallback` exists only on bus
---subscriptions; clearing an absent field is a no-op.
---@param connection table
local function releaseConnection(connection)
    rawset(connection, "_connected", false)
    rawset(connection, "_signal", nil)
    rawset(connection, "_callback", nil)
    rawset(connection, "_busCallback", nil)
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
    local tombstones = tombstoneCount(signal) + 1
    rawset(signal, "_tombstones", tombstones)

    if shouldCompact(tombstones, #listeners) then
        compact(signal, listeners)
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
---@return SignalKit.Connection
local function connect(signal, callback, once, methodName, receiverMessage, busCallback)
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
    }, CONNECTION_METATABLE)

    rawset(listeners, #listeners + 1, connection)

    return connection
end

-- Signal methods ---------------------------------------------------------------

---Creates an independent signal instance.
---@return SignalKit.Signal signal
local function newSignal()
    return setmetatable({
        _listeners = {},
        _tombstones = 0,
    }, SIGNAL_METATABLE)
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
    for index = STAGED_ASSIGNMENT_SLOTS + 1, count do
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

---@param value any
---@param label string qualified public name of the argument
---@param level integer stack level the failure is reported at
local function validateNonEmptyString(value, label, level)
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
    if self ~= SignalKit then
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
    if options == nil then
        return false, false
    end
    if type(options) ~= "table" then
        error("SignalKit.Bus:DeclareTopic options must be a table or nil", level)
    end

    local arguments = rawget(options, "arguments")
    if arguments == nil then
        arguments = false
    elseif type(arguments) == "number" then
        if arguments < 0 or arguments ~= math.floor(arguments) then
            error(
                "SignalKit.Bus:DeclareTopic options.arguments count must be a non-negative integer",
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
    if description == nil then
        description = false
    elseif type(description) ~= "string" then
        error("SignalKit.Bus:DeclareTopic options.description must be a string or nil", level)
    end

    return arguments, description
end

---Describe a validator's refusal reason without ever inspecting a secret.
---@param reason any
---@return string
local function describeRefusal(reason)
    -- issecretvalue is a World of Warcraft client API reachable only through the global table.
    -- selene: allow(global_usage)
    local isSecretValue = rawget(_G, "issecretvalue")
    if type(isSecretValue) == "function" and isSecretValue(reason) then
        return "the validator gave a secret reason"
    end
    if type(reason) == "string" and reason ~= "" then
        return reason
    end
    return "the validator gave no reason"
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
    if count >= MAXIMUM_TOPICS then
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
---@return SignalKit.Connection|nil connection
---@return "full"|nil reason
local function subscribe(bus, label, level, topic, callback, once)
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
        signal = newSignal()
        rawset(record, "signal", signal)
    end

    local listeners = rawget(signal, "_listeners")
    if #listeners - tombstoneCount(signal) >= MAXIMUM_LISTENERS then
        return nil, "full"
    end

    local connection =
        connect(signal, newDelivery(callback), once, "Connect", CONNECT_RECEIVER_MESSAGE, callback)
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
    if rawget(self, "_closed") == true then
        -- A closed bus belongs to an addon that has shut down. Late publishes
        -- from other addons' shutdown paths are expected and deliver nothing.
        return
    end
    validateNonEmptyString(topic, "SignalKit.Bus:Publish topic", 3)

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
            local accepted, reason = arguments(...)
            if accepted ~= true then
                refuseArguments(self, topic, describeRefusal(reason))
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
-- A scope keeps the connections it created in an array. Disconnecting a
-- connection directly leaves its entry behind, so the array is compacted in
-- place once it reaches twice its live count at the last compaction: amortized
-- O(1) per subscription, and never more than twice the live subscriptions.
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
        _compactAt = MINIMUM_SCOPE_COMPACTION,
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
    rawset(scope, "_compactAt", math.max(MINIMUM_SCOPE_COMPACTION, live * 2))
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

    local connection, reason = subscribe(rawget(scope, "_bus"), label, 4, topic, callback, once)
    if connection == nil then
        return nil, reason
    end

    if rawget(scope, "_count") >= rawget(scope, "_compactAt") then
        compactScope(scope)
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
        if disconnectConnection(connection) then
            disconnected = disconnected + 1
        end
    end
    rawset(scope, "_count", 0)
    rawset(scope, "_compactAt", MINIMUM_SCOPE_COMPACTION)
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

-- Facade methods ---------------------------------------------------------------

---Validate a `SignalKit:Bus` options table and return its topic policy.
---@param options any
---@param level integer stack level the failures are reported at
---@return boolean|nil openTopics `nil` when the caller did not state one.
local function readBusOptions(options, level)
    if options == nil then
        return nil
    end
    if type(options) ~= "table" then
        error("SignalKit:Bus options must be a table or nil", level)
    end
    local openTopics = rawget(options, "openTopics")
    if openTopics ~= nil and type(openTopics) ~= "boolean" then
        error("SignalKit:Bus options.openTopics must be a boolean or nil", level)
    end
    return openTopics
end

---Return the bus called `name`, creating it on the first request.
---@param name string
---@param openTopics boolean|nil
---@param label string qualified public method name
---@param level integer stack level the failures are reported at
---@return SignalKit.Bus|nil bus
---@return "full"|nil reason
local function obtainBus(name, openTopics, label, level)
    local buses = rawget(state, "buses")
    local bus = rawget(buses, name)
    if bus ~= nil then
        if openTopics ~= nil and openTopics ~= rawget(bus, "_openTopics") then
            error(
                label .. ' bus "' .. name .. '" already exists with a different openTopics policy',
                level
            )
        end
        return bus, nil
    end

    local count = rawget(state, "busCount")
    if count >= MAXIMUM_BUSES then
        return nil, "full"
    end

    bus = setmetatable({
        _name = name,
        _openTopics = openTopics == true,
        _closed = false,
        _topics = {},
        _topicCount = 0,
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
    local openTopics = readBusOptions(options, 3)
    local bus, reason = obtainBus(name, openTopics, "SignalKit:Bus", 3)
    return bus, reason
end

---Return the default bus of an addon: the bus named after it.
---
---SignalKit does not observe addon shutdown; whoever does closes this bus
---through `SignalKit:CloseAddonBus(addonName)`.
---@param self SignalKit
---@param addonName string addon folder name
---@return SignalKit.Bus|nil bus `nil` when `maxBuses` buses already exist.
---@return "full"|nil reason
local function facadeForAddon(self, addonName)
    validateFacade(self, "SignalKit:ForAddon", 3)
    validateNonEmptyString(addonName, "SignalKit:ForAddon addonName", 3)
    local bus, reason = obtainBus(addonName, nil, "SignalKit:ForAddon", 3)
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
    for _, record in pairs(rawget(bus, "_topics")) do
        local signal = rawget(record, "signal")
        if signal ~= false then
            disconnectEveryListener(signal, rawget(signal, "_listeners"))
        end
    end
    return true
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

rawset(state, "isolate", isolate)

rawset(SignalKit, "API", API_GENERATION)
rawset(SignalKit, "REVISION", IMPLEMENTATION_REVISION)
rawset(SignalKit, "New", newSignal)
rawset(SignalKit, "Connect", connectListener)
rawset(SignalKit, "Once", connectOnce)
rawset(SignalKit, "Fire", fire)
rawset(SignalKit, "DisconnectAll", disconnectAll)
rawset(SignalKit, "Bus", facadeBus)
rawset(SignalKit, "ForAddon", facadeForAddon)
rawset(SignalKit, "CloseAddonBus", facadeCloseAddonBus)

if not validatePublicSurface(SignalKit) or not validateCurrentState(SignalKit) then
    error("MoltenCodes SignalKit package state is corrupted or incomplete", 2)
end

return SignalKit
