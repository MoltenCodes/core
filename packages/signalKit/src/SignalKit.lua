-- MoltenCodes SignalKit
--
-- Deterministic, re-entrant callback dispatch for framework and addon code.
-- SignalKit has no World of Warcraft API dependency. Registry is used only for
-- embedded-package identity and revision reconciliation.

local PACKAGE_NAME = "signalKit"
local API_GENERATION = 1
local IMPLEMENTATION_REVISION = 1
local REQUIRED_REGISTRY_API = 2

-- Bootstrap ----------------------------------------------------------------

-- The shared MoltenCodes namespace is the one documented global handoff point between independently embedded copies.
-- selene: allow(global_usage)
local namespace = rawget(_G, "MoltenCodes")
if type(namespace) ~= "table" then
    error("MoltenCodes SignalKit requires Registry API 2 to be loaded first", 2)
end

local Registry = rawget(namespace, "Registry")
if type(Registry) ~= "table" or rawget(Registry, "API") ~= REQUIRED_REGISTRY_API then
    error("MoltenCodes SignalKit requires Registry API 2 to be loaded first", 2)
end

local register = rawget(Registry, "Register")
local get = rawget(Registry, "Get")
if type(register) ~= "function" or type(get) ~= "function" then
    error("MoltenCodes SignalKit requires a valid Registry API 2 facade", 2)
end

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

local existing, existingRevision = get(Registry, PACKAGE_NAME, API_GENERATION)
if existing ~= nil then
    if not validatePublicSurface(existing) or rawget(existing, "REVISION") ~= existingRevision then
        error("MoltenCodes SignalKit package state is corrupted or incomplete", 2)
    end
end

local SignalKit, previousRevision =
    register(Registry, PACKAGE_NAME, API_GENERATION, IMPLEMENTATION_REVISION)

if SignalKit == nil then
    -- Equal or newer compatible revision already owns the shared package table.
    return existing
end

if previousRevision ~= existingRevision then
    error("MoltenCodes SignalKit Registry state changed unexpectedly during bootstrap", 2)
end

-- Public class/prototype -----------------------------------------------------
--
-- SignalKit is both the package facade and the method prototype for signal
-- instances. Because Registry preserves the facade table identity, existing
-- signal instances automatically observe compatible method upgrades loaded by
-- a newer embedded package revision.

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

local function copyWithout(listeners, connection)
    local nextListeners = {}
    local nextIndex = 1

    for index = 1, #listeners do
        local candidate = listeners[index]
        if candidate ~= connection then
            nextListeners[nextIndex] = candidate
            nextIndex = nextIndex + 1
        end
    end

    return nextListeners
end

local function disconnectConnection(connection)
    if rawget(connection, "_connected") ~= true then
        return false
    end

    local signal = rawget(connection, "_signal")
    local listeners = rawget(signal, "_listeners")

    rawset(connection, "_connected", false)
    rawset(connection, "_signal", nil)
    rawset(connection, "_callback", nil)
    rawset(signal, "_listeners", copyWithout(listeners, connection))

    return true
end

local function connect(signal, callback, once, methodName)
    if type(callback) ~= "function" then
        error("SignalKit:" .. methodName .. " callback must be a function", 3)
    end

    local connection = setmetatable({
        _signal = signal,
        _callback = callback,
        _connected = true,
        _once = once,
    }, CONNECTION_METATABLE)

    local listeners = rawget(signal, "_listeners")
    rawset(listeners, #listeners + 1, connection)

    return connection
end

local function newSignal()
    return setmetatable({
        _listeners = {},
    }, SIGNAL_METATABLE)
end

local function connectListener(self, callback)
    return connect(self, callback, false, "Connect")
end

local function connectOnce(self, callback)
    return connect(self, callback, true, "Once")
end

local function fire(self, ...)
    -- Capture both the current listener array and its length. Connect appends
    -- beyond this fixed boundary, while disconnect replaces the signal's active
    -- array and marks the shared connection inactive. This makes the current
    -- dispatch stable without allocating a per-Fire snapshot.
    local listeners = rawget(self, "_listeners")
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

local function disconnectAll(self)
    local listeners = rawget(self, "_listeners")
    local disconnected = 0

    -- Replace the active array first. If a callback is currently dispatching
    -- an older snapshot, marking these shared connection objects disconnected
    -- prevents all remaining callbacks from that snapshot from running.
    rawset(self, "_listeners", {})

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

local function disconnect(self)
    return disconnectConnection(self)
end

local function isConnected(self)
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
