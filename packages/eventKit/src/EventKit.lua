-- MoltenCodes EventKit
--
-- Lazy World of Warcraft event subscriptions built on MoltenCodes SignalKit.
-- Regular events share one Frame. Unit-event registrations share a Frame per
-- normalized unit-filter set because RegisterUnitEvent replaces a same-event
-- registration on the same Frame.
--
-- EventKit is multi-tenant: one shared instance serves every addon in a WoW
-- session. Listeners are therefore isolated from each other at dispatch, so one
-- addon's failing handler cannot stop delivery to the rest.

local PACKAGE_NAME = "eventKit"
local API_GENERATION = 1
local IMPLEMENTATION_REVISION = 2
local REQUIRED_REGISTRY_API = 2
local REQUIRED_SIGNAL_API = 1
local STATE_SCHEMA = 2

-- `Frame:RegisterUnitEvent(event, unit1, unit2)` has exactly two filter slots.
local MAXIMUM_UNIT_TOKENS = 2

-- WoW Frames cannot be destroyed, so the only real bound is on how many EventKit
-- ever creates. Released groups return their Frame to a free list that is
-- therefore bounded by the same number.
local MAXIMUM_UNIT_GROUP_FRAMES = 64

-- Payloads up to this size are staged in reusable upvalues; larger ones use one
-- reusable buffer table. Neither path allocates per event.
local INLINE_ARGUMENT_SLOTS = 6

-- How many buffer slots one multiple assignment fills. Wider payloads than this
-- fall back to a per-slot `select`, which no WoW event is known to need.
local BUFFERED_ARGUMENT_SLOTS = 16

-- Lua 5.1 publishes unpack as a global; newer clients move it onto table.
-- selene: allow(global_usage)
local unpackValues = rawget(table, "unpack") or rawget(_G, "unpack")

-- Dependencies --------------------------------------------------------------

-- The shared MoltenCodes namespace is the one documented global handoff point between independently embedded copies.
-- selene: allow(global_usage)
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
if
    type(SignalKit) ~= "table"
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
    if
        type(implementation) ~= "table"
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
        and type(rawget(currentState, "unitFrames")) == "table"
        and type(rawget(currentState, "unitFrameCount")) == "number"
        and type(rawget(currentState, "dispatchRegular")) == "function"
        and type(rawget(currentState, "dispatchUnit")) == "function"
        and type(rawget(currentState, "isolate")) == "function"
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

local EventKit, previousRevision =
    registerPackage(Registry, PACKAGE_NAME, API_GENERATION, IMPLEMENTATION_REVISION)

if EventKit == nil then
    -- Equal or newer compatible revision already owns the shared package table.
    return existing
end

if previousRevision ~= existingRevision then
    error("MoltenCodes EventKit Registry state changed unexpectedly during bootstrap", 2)
end

-- Shared state --------------------------------------------------------------
--
-- `_state` is reserved package-private storage on the public facade. Every
-- underscore-prefixed field on the facade is reserved in the same way: consumers
-- must not read or write them, and a future revision may change their shape.

---A connection handle returned by an EventKit subscription.
---@class EventKitConnection
---@field Disconnect fun(self: EventKitConnection): boolean
---@field IsConnected fun(self: EventKitConnection): boolean

---The shared EventKit package table.
---@class EventKit
---@field API integer EventKit API generation.
---@field REVISION integer EventKit implementation revision.
---@field Connection EventKitConnection Shared method prototype for connection handles.
---@field Connect fun(self: EventKit, eventName: string, callback: fun(eventName: string, ...: any)): EventKitConnection
---@field Once fun(self: EventKit, eventName: string, callback: fun(eventName: string, ...: any)): EventKitConnection
---@field ConnectUnit fun(self: EventKit, eventName: string, callback: fun(eventName: string, ...: any), unit1: string, unit2: string?): EventKitConnection
---@field OnceUnit fun(self: EventKit, eventName: string, callback: fun(eventName: string, ...: any), unit1: string, unit2: string?): EventKitConnection

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
        unitFrames = {},
        unitFrameCount = 0,
        dispatchRegular = nil,
        dispatchUnit = nil,
        isolate = nil,
    }

    rawset(EventKit, "Connection", Connection)
    rawset(EventKit, "_state", state)
elseif
    type(Connection) ~= "table"
    or type(state) ~= "table"
    or type(rawget(state, "regularChannels")) ~= "table"
    or type(rawget(state, "unitGroups")) ~= "table"
then
    error("MoltenCodes EventKit package state is corrupted or incomplete", 2)
else
    local schema = rawget(state, "schema")

    if schema == 1 then
        -- Revision 1 retained every unit-group Frame for the package lifetime
        -- and kept no free list, no creation counter and no dispatch slots.
        -- Adopt its live groups: they already own Frames this copy created.
        local liveGroups = 0
        for key, group in pairs(rawget(state, "unitGroups")) do
            if type(group) == "table" then
                rawset(group, "key", key)
                liveGroups = liveGroups + 1
            end
        end

        rawset(state, "unitFrames", {})
        rawset(state, "unitFrameCount", liveGroups)
        rawset(state, "schema", STATE_SCHEMA)
    elseif schema ~= STATE_SCHEMA then
        error("MoltenCodes EventKit package state is corrupted or incomplete", 2)
    end
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

    -- Frame:RegisterUnitEvent has two filter slots. A third distinct token used
    -- to be sorted, dropped by the client, and then still claimed by the group
    -- key, so the caller silently received a filter they never asked for.
    if #units > MAXIMUM_UNIT_TOKENS then
        error(
            "EventKit:"
                .. methodName
                .. " accepts at most "
                .. MAXIMUM_UNIT_TOKENS
                .. " distinct unit tokens because Frame:RegisterUnitEvent has "
                .. MAXIMUM_UNIT_TOKENS
                .. " filter slots; received "
                .. #units,
            3
        )
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
--
-- These failures describe the host environment, not the caller's arguments, and
-- they are raised two to four frames below the public API. A stack level here
-- would name a line inside EventKit, so they raise at level 0 with an explicit
-- `EventKit:` prefix instead. Argument errors keep pointing at the caller.

local function requireFrameMethod(frame, methodName)
    local method = frame and frame[methodName]
    if type(method) ~= "function" then
        error("EventKit: requires Frame:" .. methodName .. " support", 0)
    end
    return method
end

local function createEventFrame(onEvent)
    -- CreateFrame is a World of Warcraft client API reachable only through the global table.
    -- selene: allow(global_usage)
    local createFrame = rawget(_G, "CreateFrame")
    if type(createFrame) ~= "function" then
        error("EventKit: requires the World of Warcraft CreateFrame API", 0)
    end

    local frame = createFrame("Frame")
    if frame == nil then
        error("EventKit: CreateFrame returned no Frame", 0)
    end

    local setScript = requireFrameMethod(frame, "SetScript")
    setScript(frame, "OnEvent", onEvent)
    return frame
end

local function onRegularFrameEvent(_, eventName, ...)
    -- The dispatcher is validated once at load and kept in shared state, so the
    -- per-event path is a single table read instead of a read plus a type check.
    -- Reading it through `state` rather than capturing it keeps upgrade-in-place
    -- working: a newer revision replaces the slot and existing Frames follow.
    return rawget(state, "dispatchRegular")(EventKit, eventName, ...)
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

-- Unit-group Frames -----------------------------------------------------------

local function acquireUnitFrame(group)
    local function onUnitFrameEvent(_, eventName, ...)
        return rawget(state, "dispatchUnit")(EventKit, group, eventName, ...)
    end

    local freeFrames = rawget(state, "unitFrames")
    local freeCount = #freeFrames
    if freeCount > 0 then
        local frame = freeFrames[freeCount]
        freeFrames[freeCount] = nil

        -- Re-purpose the Frame for this unit set. Its events were already
        -- unregistered when the previous group released it.
        local setScript = requireFrameMethod(frame, "SetScript")
        setScript(frame, "OnEvent", onUnitFrameEvent)
        return frame
    end

    local created = rawget(state, "unitFrameCount")
    if created >= MAXIMUM_UNIT_GROUP_FRAMES then
        error(
            "EventKit: refusing to create more than "
                .. MAXIMUM_UNIT_GROUP_FRAMES
                .. " unit-filter Frames; disconnect unused unit subscriptions or "
                .. "reuse unit sets",
            0
        )
    end

    local frame = createEventFrame(onUnitFrameEvent)
    rawset(state, "unitFrameCount", created + 1)
    return frame
end

local function releaseUnitGroup(group)
    local groups = rawget(state, "unitGroups")
    rawset(groups, rawget(group, "key"), nil)

    local frame = rawget(group, "frame")
    rawset(group, "frame", nil)

    -- Detach the handler before pooling the Frame: an event the host already
    -- queued must not reach a group that no longer exists.
    local setScript = requireFrameMethod(frame, "SetScript")
    setScript(frame, "OnEvent", nil)

    local freeFrames = rawget(state, "unitFrames")
    freeFrames[#freeFrames + 1] = frame
end

local function ensureUnitGroup(units, key)
    local groups = rawget(state, "unitGroups")
    local group = rawget(groups, key)
    if group ~= nil then
        return group
    end

    group = {
        key = key,
        units = units,
        channels = {},
        frame = nil,
    }

    rawset(group, "frame", acquireUnitFrame(group))
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
        group = nil,
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
        if next(channels) == nil then
            -- The group exists only because this registration was attempted.
            releaseUnitGroup(group)
        end
        error("EventKit:" .. methodName .. " could not register event " .. eventName, 3)
    end

    local channel = {
        eventName = eventName,
        frame = frame,
        signal = signal,
        count = 0,
        channels = channels,
        group = group,
    }
    rawset(channels, eventName, channel)
    return channel
end

local function releaseChannel(channel)
    local count = rawget(channel, "count") - 1
    rawset(channel, "count", count)

    -- The count is decremented once per connection and a connection disconnects
    -- at most once, so it can only ever reach zero. Treating any non-positive
    -- value as "empty" keeps a bookkeeping slip from pinning a registration for
    -- the rest of the session.
    if count > 0 then
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

    local group = rawget(channel, "group")
    if group ~= nil and rawget(group, "frame") ~= nil and next(channels) == nil then
        releaseUnitGroup(group)
    end
end

-- Listener isolation ----------------------------------------------------------
--
-- EventKit is shared by every addon in the session, so a listener that raises
-- must not abort the dispatch for the listeners behind it. Errors are reported
-- through the host error handler rather than raised.
--
-- Modern clients provide `securecallfunction`, which both isolates the call and
-- keeps the caller's taint state out of the listener. Elsewhere this falls back
-- to `xpcall`, which in Lua 5.1 accepts no extra arguments: the payload is
-- staged in reusable upvalues and a single reusable trampoline forwards it, so
-- no closure or argument table is allocated per event.

local pendingCallback
local pendingCount = 0
local pendingFirst, pendingSecond, pendingThird, pendingFourth, pendingFifth, pendingSixth
local pendingBuffer = {}

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

local function invokePending()
    local callback = pendingCallback
    local count = pendingCount
    pendingCallback = nil

    if count > INLINE_ARGUMENT_SLOTS then
        -- `unpack` pushes the buffer onto the call stack before the callback
        -- runs, so a nested dispatch reusing the buffer cannot corrupt this call.
        return callback(unpackValues(pendingBuffer, 1, count))
    end

    -- Copy the staged payload out before invoking: the callback may dispatch a
    -- nested event, which reuses these same slots.
    local first, second, third = pendingFirst, pendingSecond, pendingThird
    local fourth, fifth, sixth = pendingFourth, pendingFifth, pendingSixth
    pendingFirst, pendingSecond, pendingThird = nil, nil, nil
    pendingFourth, pendingFifth, pendingSixth = nil, nil, nil

    if count == 0 then
        return callback()
    elseif count == 1 then
        return callback(first)
    elseif count == 2 then
        return callback(first, second)
    elseif count == 3 then
        return callback(first, second, third)
    elseif count == 4 then
        return callback(first, second, third, fourth)
    elseif count == 5 then
        return callback(first, second, third, fourth, fifth)
    end

    return callback(first, second, third, fourth, fifth, sixth)
end

---Stages a payload too wide for the inline slots into the reusable buffer.
---
---One multiple assignment costs the same whatever the payload size, while
---assigning `select(index, ...)` per slot is quadratic in it. Slots past `count`
---are left holding stale values on purpose: the trampoline unpacks the buffer
---with explicit `1, count` bounds, so they are never read.
---@param count integer
local function stageWidePayload(count, ...)
    local buffer = pendingBuffer

    buffer[1], buffer[2], buffer[3], buffer[4], buffer[5], buffer[6], buffer[7], buffer[8], buffer[9], buffer[10], buffer[11], buffer[12], buffer[13], buffer[14], buffer[15], buffer[16] =
        ...

    for index = BUFFERED_ARGUMENT_SLOTS + 1, count do
        buffer[index] = select(index, ...)
    end
end

local function isolateWithXpcall(callback, ...)
    local count = select("#", ...)
    pendingCallback = callback
    pendingCount = count

    if count > INLINE_ARGUMENT_SLOTS then
        stageWidePayload(count, ...)
    else
        pendingFirst, pendingSecond, pendingThird, pendingFourth, pendingFifth, pendingSixth = ...
    end

    xpcall(invokePending, reportListenerError)
end

-- securecallfunction is a World of Warcraft client API reachable only through the global table.
-- selene: allow(global_usage)
local secureCallFunction = rawget(_G, "securecallfunction")
local isolate = isolateWithXpcall
if type(secureCallFunction) == "function" then
    -- Its signature is already `(callback, ...)`, so no adapter frame is needed.
    isolate = secureCallFunction
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

    -- One wrapper closure per connection, never per event. The isolation
    -- function is read from shared state so a compatible newer revision can
    -- replace it for connections that already exist.
    if once then
        inner = signal:Connect(function(...)
            disconnectEventConnection(connection)
            return rawget(state, "isolate")(callback, ...)
        end)
    else
        inner = signal:Connect(function(...)
            return rawget(state, "isolate")(callback, ...)
        end)
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
    return connectToChannel(
        createUnitChannel(eventName, units, key, "ConnectUnit"),
        callback,
        false
    )
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

rawset(state, "dispatchRegular", dispatchRegular)
rawset(state, "dispatchUnit", dispatchUnit)
rawset(state, "isolate", isolate)

-- Frames created by implementation revision 1 resolve dispatch through these
-- reserved facade fields. Keep them pointing at the current dispatchers so an
-- in-place upgrade over revision 1 keeps those Frames delivering.
rawset(EventKit, "_DispatchRegular", dispatchRegular)
rawset(EventKit, "_DispatchUnit", dispatchUnit)

if not validatePublicSurface(EventKit) or not validateCurrentState(EventKit) then
    error("MoltenCodes EventKit package state is corrupted or incomplete", 2)
end

return EventKit
