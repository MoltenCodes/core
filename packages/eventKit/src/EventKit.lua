-- MoltenCodes EventKit
--
-- Lazy World of Warcraft event subscriptions built on MoltenCodes SignalKit.
-- Regular events share one Frame. Unit-event registrations share a Frame per
-- normalized unit-filter set because RegisterUnitEvent replaces a same-event
-- registration on the same Frame.

local PACKAGE_NAME = "eventKit"
local API_GENERATION = 1
local IMPLEMENTATION_REVISION = 1
local REQUIRED_REGISTRY_API = 2
local REQUIRED_SIGNAL_API = 1
local STATE_SCHEMA = 1

local unpackValues = rawget(table, "unpack") or rawget(_G, "unpack")

-- Dependencies --------------------------------------------------------------

local namespace = rawget(_G, "MoltenCodes")
if type(namespace) ~= "table" then
    error("MoltenCodes EventKit requires Registry API 2 to be loaded first", 2)
end

local Registry = rawget(namespace, "Registry")
if type(Registry) ~= "table" or rawget(Registry, "API") ~= REQUIRED_REGISTRY_API then
    error("MoltenCodes EventKit requires Registry API 2 to be loaded first", 2)
end

local registerPackage = rawget(Registry, "Register")
local getPackage = rawget(Registry, "Get")
if type(registerPackage) ~= "function" or type(getPackage) ~= "function" then
    error("MoltenCodes EventKit requires a valid Registry API 2 facade", 2)
end

local SignalKit, signalRevision = getPackage(Registry, "signalKit", REQUIRED_SIGNAL_API)
if SignalKit == nil then
    error("MoltenCodes EventKit requires SignalKit API 1 to be loaded first", 2)
end

local SignalKitConnection = type(SignalKit) == "table" and rawget(SignalKit, "Connection") or nil
if type(SignalKit) ~= "table"
    or type(signalRevision) ~= "number"
    or rawget(SignalKit, "API") ~= REQUIRED_SIGNAL_API
    or rawget(SignalKit, "REVISION") ~= signalRevision
    or type(rawget(SignalKit, "New")) ~= "function"
    or type(rawget(SignalKit, "Connect")) ~= "function"
    or type(rawget(SignalKit, "Fire")) ~= "function"
    or type(SignalKitConnection) ~= "table"
    or type(rawget(SignalKitConnection, "Disconnect")) ~= "function"
then
    error("MoltenCodes EventKit requires a valid SignalKit API 1 facade", 2)
end

-- Public-surface validation --------------------------------------------------

local function validatePublicSurface(implementation)
    if type(implementation) ~= "table"
        or rawget(implementation, "API") ~= API_GENERATION
        or type(rawget(implementation, "REVISION")) ~= "number"
        or type(rawget(implementation, "Connection")) ~= "table"
        or type(rawget(implementation, "Connect")) ~= "function"
        or type(rawget(implementation, "Once")) ~= "function"
        or type(rawget(implementation, "ConnectUnit")) ~= "function"
        or type(rawget(implementation, "OnceUnit")) ~= "function"
    then
        return false
    end

    local connection = rawget(implementation, "Connection")
    return type(rawget(connection, "Disconnect")) == "function"
        and type(rawget(connection, "IsConnected")) == "function"
end

local function validateCurrentState(implementation)
    local currentState = rawget(implementation, "_state")
    return type(currentState) == "table"
        and rawget(currentState, "schema") == STATE_SCHEMA
        and type(rawget(currentState, "regularChannels")) == "table"
        and type(rawget(currentState, "unitGroups")) == "table"
end

local existing, existingRevision = getPackage(Registry, PACKAGE_NAME, API_GENERATION)
if existing ~= nil then
    if not validatePublicSurface(existing) or rawget(existing, "REVISION") ~= existingRevision then
        error("MoltenCodes EventKit package state is corrupted or incomplete", 2)
    end

    if existingRevision == IMPLEMENTATION_REVISION and not validateCurrentState(existing) then
        error("MoltenCodes EventKit package state is corrupted or incomplete", 2)
    end
end

local EventKit, previousRevision = registerPackage(
    Registry,
    PACKAGE_NAME,
    API_GENERATION,
    IMPLEMENTATION_REVISION
)

if EventKit == nil then
    -- Equal or newer compatible revision already owns the shared package table.
    return existing
end

if previousRevision ~= existingRevision then
    error("MoltenCodes EventKit Registry state changed unexpectedly during bootstrap", 2)
end

-- Shared state --------------------------------------------------------------

local Connection = rawget(EventKit, "Connection")
local state = rawget(EventKit, "_state")

if previousRevision == nil then
    if Connection ~= nil or state ~= nil then
        error("MoltenCodes EventKit package state is corrupted or incomplete", 2)
    end

    Connection = {}
    state = {
        schema = STATE_SCHEMA,
        regularFrame = nil,
        regularChannels = {},
        unitGroups = {},
    }

    rawset(EventKit, "Connection", Connection)
    rawset(EventKit, "_state", state)
elseif type(Connection) ~= "table"
    or type(state) ~= "table"
    or rawget(state, "schema") ~= STATE_SCHEMA
    or type(rawget(state, "regularChannels")) ~= "table"
    or type(rawget(state, "unitGroups")) ~= "table"
then
    error("MoltenCodes EventKit package state is corrupted or incomplete", 2)
end

local CONNECTION_METATABLE = { __index = Connection }

-- Validation ----------------------------------------------------------------

local function validateEventName(eventName, methodName)
    if type(eventName) ~= "string" or eventName == "" then
        error("EventKit:" .. methodName .. " eventName must be a non-empty string", 3)
    end
end

local function validateCallback(callback, methodName)
    if type(callback) ~= "function" then
        error("EventKit:" .. methodName .. " callback must be a function", 3)
    end
end

local function normalizeUnits(methodName, ...)
    local count = select("#", ...)
    if count == 0 then
        error("EventKit:" .. methodName .. " requires at least one unit token", 3)
    end

    local units = {}
    local seen = {}

    for index = 1, count do
        local unit = select(index, ...)
        if type(unit) ~= "string" or unit == "" then
            error("EventKit:" .. methodName .. " unit tokens must be non-empty strings", 3)
        end

        if not seen[unit] then
            seen[unit] = true
            units[#units + 1] = unit
        end
    end

    table.sort(units)

    local keyParts = {}
    for index = 1, #units do
        local unit = units[index]
        keyParts[index] = tostring(#unit) .. ":" .. unit
    end

    return units, table.concat(keyParts, "|")
end

-- WoW Frame boundary --------------------------------------------------------

local function requireFrameMethod(frame, methodName)
    local method = frame and frame[methodName]
    if type(method) ~= "function" then
        error("MoltenCodes EventKit requires Frame:" .. methodName .. " support", 3)
    end
    return method
end

local function createEventFrame(onEvent)
    local createFrame = rawget(_G, "CreateFrame")
    if type(createFrame) ~= "function" then
        error("MoltenCodes EventKit requires the World of Warcraft CreateFrame API", 3)
    end

    local frame = createFrame("Frame")
    if frame == nil then
        error("MoltenCodes EventKit CreateFrame returned no Frame", 3)
    end

    local setScript = requireFrameMethod(frame, "SetScript")
    setScript(frame, "OnEvent", onEvent)
    return frame
end

local function onRegularFrameEvent(_, eventName, ...)
    local dispatcher = rawget(EventKit, "_DispatchRegular")
    if type(dispatcher) ~= "function" then
        error("MoltenCodes EventKit package state is corrupted or incomplete", 2)
    end
    dispatcher(EventKit, eventName, ...)
end

local function ensureRegularFrame()
    local frame = rawget(state, "regularFrame")
    if frame ~= nil then
        return frame
    end

    frame = createEventFrame(onRegularFrameEvent)
    rawset(state, "regularFrame", frame)
    return frame
end

local function ensureUnitGroup(units, key)
    local groups = rawget(state, "unitGroups")
    local group = rawget(groups, key)
    if group ~= nil then
        return group
    end

    group = {
        units = units,
        channels = {},
        frame = nil,
    }

    local function onUnitFrameEvent(_, eventName, ...)
        local dispatcher = rawget(EventKit, "_DispatchUnit")
        if type(dispatcher) ~= "function" then
            error("MoltenCodes EventKit package state is corrupted or incomplete", 2)
        end
        dispatcher(EventKit, group, eventName, ...)
    end

    local frame = createEventFrame(onUnitFrameEvent)
    rawset(group, "frame", frame)
    rawset(groups, key, group)
    return group
end

-- Channels ------------------------------------------------------------------

local function createRegularChannel(eventName, methodName)
    local channels = rawget(state, "regularChannels")
    local existingChannel = rawget(channels, eventName)
    if existingChannel ~= nil then
        return existingChannel
    end

    local frame = ensureRegularFrame()
    local signal = SignalKit:New()
    local registerEvent = requireFrameMethod(frame, "RegisterEvent")
    local registered = registerEvent(frame, eventName)
    if registered == false then
        error("EventKit:" .. methodName .. " could not register event " .. eventName, 3)
    end

    local channel = {
        eventName = eventName,
        frame = frame,
        signal = signal,
        count = 0,
        channels = channels,
    }
    rawset(channels, eventName, channel)
    return channel
end

local function createUnitChannel(eventName, units, key, methodName)
    local group = ensureUnitGroup(units, key)
    local channels = rawget(group, "channels")
    local existingChannel = rawget(channels, eventName)
    if existingChannel ~= nil then
        return existingChannel
    end

    local frame = rawget(group, "frame")
    local signal = SignalKit:New()
    local registerUnitEvent = requireFrameMethod(frame, "RegisterUnitEvent")
    local registered = registerUnitEvent(frame, eventName, unpackValues(units, 1, #units))
    if registered == false then
        error("EventKit:" .. methodName .. " could not register event " .. eventName, 3)
    end

    local channel = {
        eventName = eventName,
        frame = frame,
        signal = signal,
        count = 0,
        channels = channels,
    }
    rawset(channels, eventName, channel)
    return channel
end

local function releaseChannel(channel)
    local count = rawget(channel, "count") - 1
    rawset(channel, "count", count)

    if count ~= 0 then
        return
    end

    local eventName = rawget(channel, "eventName")
    local channels = rawget(channel, "channels")
    local frame = rawget(channel, "frame")

    -- Remove dispatch visibility before touching the host API. Even if an
    -- unexpected host-side UnregisterEvent error occurs, stale callbacks can no
    -- longer be delivered through this package state.
    rawset(channels, eventName, nil)

    local unregisterEvent = requireFrameMethod(frame, "UnregisterEvent")
    unregisterEvent(frame, eventName)
end

-- Connections ---------------------------------------------------------------

local function disconnectEventConnection(connection)
    if rawget(connection, "_connected") ~= true then
        return false
    end

    local inner = rawget(connection, "_inner")
    local channel = rawget(connection, "_channel")

    rawset(connection, "_connected", false)
    rawset(connection, "_inner", nil)
    rawset(connection, "_channel", nil)

    inner:Disconnect()
    releaseChannel(channel)
    return true
end

local function connectToChannel(channel, callback, once)
    local connection = setmetatable({
        _connected = true,
        _inner = nil,
        _channel = channel,
    }, CONNECTION_METATABLE)

    local signal = rawget(channel, "signal")
    local inner

    if once then
        inner = signal:Connect(function(...)
            disconnectEventConnection(connection)
            callback(...)
        end)
    else
        inner = signal:Connect(callback)
    end

    rawset(connection, "_inner", inner)
    rawset(channel, "count", rawget(channel, "count") + 1)
    return connection
end

local function disconnect(self)
    return disconnectEventConnection(self)
end

local function isConnected(self)
    return rawget(self, "_connected") == true
end

-- Dispatch ------------------------------------------------------------------

local function dispatchRegular(_, eventName, ...)
    local channels = rawget(state, "regularChannels")
    local channel = rawget(channels, eventName)
    if channel ~= nil then
        rawget(channel, "signal"):Fire(eventName, ...)
    end
end

local function dispatchUnit(_, group, eventName, ...)
    local channels = rawget(group, "channels")
    local channel = rawget(channels, eventName)
    if channel ~= nil then
        rawget(channel, "signal"):Fire(eventName, ...)
    end
end

-- Public API ----------------------------------------------------------------

local function connectEvent(_, eventName, callback)
    validateEventName(eventName, "Connect")
    validateCallback(callback, "Connect")
    return connectToChannel(createRegularChannel(eventName, "Connect"), callback, false)
end

local function onceEvent(_, eventName, callback)
    validateEventName(eventName, "Once")
    validateCallback(callback, "Once")
    return connectToChannel(createRegularChannel(eventName, "Once"), callback, true)
end

local function connectUnitEvent(_, eventName, callback, ...)
    validateEventName(eventName, "ConnectUnit")
    validateCallback(callback, "ConnectUnit")
    local units, key = normalizeUnits("ConnectUnit", ...)
    return connectToChannel(createUnitChannel(eventName, units, key, "ConnectUnit"), callback, false)
end

local function onceUnitEvent(_, eventName, callback, ...)
    validateEventName(eventName, "OnceUnit")
    validateCallback(callback, "OnceUnit")
    local units, key = normalizeUnits("OnceUnit", ...)
    return connectToChannel(createUnitChannel(eventName, units, key, "OnceUnit"), callback, true)
end

-- Commit --------------------------------------------------------------------
--
-- Existing connection handles and frame callbacks resolve behavior through
-- stable shared tables. Replacing these methods therefore upgrades compatible
-- embedded revisions in place without replacing package or connection identity.

rawset(Connection, "Disconnect", disconnect)
rawset(Connection, "IsConnected", isConnected)

rawset(EventKit, "API", API_GENERATION)
rawset(EventKit, "REVISION", IMPLEMENTATION_REVISION)
rawset(EventKit, "Connect", connectEvent)
rawset(EventKit, "Once", onceEvent)
rawset(EventKit, "ConnectUnit", connectUnitEvent)
rawset(EventKit, "OnceUnit", onceUnitEvent)

rawset(EventKit, "_DispatchRegular", dispatchRegular)
rawset(EventKit, "_DispatchUnit", dispatchUnit)

if not validatePublicSurface(EventKit) then
    error("MoltenCodes EventKit package state is corrupted or incomplete", 2)
end

return EventKit
