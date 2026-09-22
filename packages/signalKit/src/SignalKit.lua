-- MoltenCodes SignalKit
--
-- Deterministic, re-entrant callback dispatch for framework and addon code.
-- SignalKit has no World of Warcraft API dependency. Registry is used only for
-- embedded-package identity and revision reconciliation.

local PACKAGE_NAME = "signalKit"
local API_GENERATION = 1
local IMPLEMENTATION_REVISION = 3
local REQUIRED_REGISTRY_API = 2

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
        and type(rawget(rawget(implementation, "Connection"), "Disconnect")) == "function"
        and type(rawget(rawget(implementation, "Connection"), "IsConnected")) == "function"
end

local SignalKit, previousRevision, selected = bootstrapPackage(Registry, {
    package = PACKAGE_NAME,
    api = API_GENERATION,
    revision = IMPLEMENTATION_REVISION,
    label = "MoltenCodes SignalKit",
    validatePublicSurface = validatePublicSurface,
})

if SignalKit == nil then
    -- Equal or newer compatible revision already owns the shared package table.
    return selected
end

-- Public class/prototype -----------------------------------------------------
--
-- SignalKit is both the package facade and the method prototype for signal
-- instances. Because Registry preserves the facade table identity, existing
-- signal instances automatically observe compatible method upgrades loaded by
-- a newer embedded package revision.

---A connection handle returned by `signal:Connect` or `signal:Once`.
---@class SignalKit.Connection
---@field Disconnect fun(self: SignalKit.Connection): boolean
---@field IsConnected fun(self: SignalKit.Connection): boolean

---An independent dispatch point created by `SignalKit:New()`.
---@class SignalKit.Signal
---@field Connect fun(self: SignalKit.Signal, callback: fun(...)): SignalKit.Connection
---@field Once fun(self: SignalKit.Signal, callback: fun(...)): SignalKit.Connection
---@field Fire fun(self: SignalKit.Signal, ...: any)
---@field DisconnectAll fun(self: SignalKit.Signal): integer

---The shared SignalKit package table.
---@class SignalKit: SignalKit.Signal
---@field API integer SignalKit API generation.
---@field REVISION integer SignalKit implementation revision.
---@field Connection SignalKit.Connection Shared method prototype for connection handles.
---@field New fun(self: SignalKit?): SignalKit.Signal

local Connection = rawget(SignalKit, "Connection")
if previousRevision == nil then
    if Connection ~= nil then
        error("MoltenCodes SignalKit package state is corrupted or incomplete", 2)
    end

    Connection = {}
    rawset(SignalKit, "Connection", Connection)
elseif type(Connection) ~= "table" then
    error("MoltenCodes SignalKit package state is corrupted or incomplete", 2)
end

local SIGNAL_METATABLE = { __index = SignalKit }
local CONNECTION_METATABLE = { __index = Connection }

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

---@param connection table
---@return boolean disconnected `true` only for the call that transitioned the state.
local function disconnectConnection(connection)
    if rawget(connection, "_connected") ~= true then
        return false
    end

    local signal = rawget(connection, "_signal")

    rawset(connection, "_connected", false)
    rawset(connection, "_signal", nil)
    -- The handle stays in the listener array until the next compaction, but the
    -- callback closure is released immediately: it is normally far larger than
    -- the handle that holds it.
    rawset(connection, "_callback", nil)

    local listeners = rawget(signal, "_listeners")
    local tombstones = tombstoneCount(signal) + 1
    rawset(signal, "_tombstones", tombstones)

    if shouldCompact(tombstones, #listeners) then
        compact(signal, listeners)
    end

    return true
end

---Shared implementation of `Connect` and `Once`.
---@param signal any receiver the public method was called on
---@param callback any candidate listener, validated here
---@param once boolean whether the connection disconnects before its first call
---@param methodName "Connect"|"Once" public method name, used in the argument error
---@param receiverMessage string error text raised when `signal` is not a signal
---@return SignalKit.Connection
local function connect(signal, callback, once, methodName, receiverMessage)
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
    }, CONNECTION_METATABLE)

    rawset(listeners, #listeners + 1, connection)

    return connection
end

-- Public methods ---------------------------------------------------------------

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

---Disconnects every listener connected at the moment of the call.
---@param self SignalKit.Signal
---@return integer disconnected
local function disconnectAll(self)
    local listeners = listenersOf(self)
    if listeners == nil then
        error(DISCONNECT_ALL_RECEIVER_MESSAGE, 2)
    end

    local disconnected = 0

    -- Replace the active array first. If a callback is currently dispatching
    -- an older snapshot, marking these shared connection objects disconnected
    -- prevents all remaining callbacks from that snapshot from running.
    rawset(self, "_listeners", {})
    rawset(self, "_tombstones", 0)

    for index = 1, #listeners do
        local connection = listeners[index]
        if rawget(connection, "_connected") == true then
            disconnected = disconnected + 1
            rawset(connection, "_connected", false)
            rawset(connection, "_signal", nil)
            rawset(connection, "_callback", nil)
        end
    end

    return disconnected
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

-- Commit the compatible public surface only after all implementation functions
-- have been constructed successfully. Registry has already accepted this
-- revision, so initialization below intentionally contains no fallible external
-- calls.
rawset(Connection, "Disconnect", disconnect)
rawset(Connection, "IsConnected", isConnected)

rawset(SignalKit, "API", API_GENERATION)
rawset(SignalKit, "REVISION", IMPLEMENTATION_REVISION)
rawset(SignalKit, "New", newSignal)
rawset(SignalKit, "Connect", connectListener)
rawset(SignalKit, "Once", connectOnce)
rawset(SignalKit, "Fire", fire)
rawset(SignalKit, "DisconnectAll", disconnectAll)

if not validatePublicSurface(SignalKit) then
    error("MoltenCodes SignalKit package state is corrupted or incomplete", 2)
end

return SignalKit
