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
local IMPLEMENTATION_REVISION = 4
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
local generations = type(namespace) == "table" and rawget(namespace, "Registries") or nil

-- Ask for Registry by generation and fall back to the alias. A future Registry
-- API generation takes over `MoltenCodes.Registry`, so reading the alias first
-- would hand this file a facade whose contract it was not written against.
local Registry = type(generations) == "table" and rawget(generations, REQUIRED_REGISTRY_API) or nil
if Registry == nil and type(namespace) == "table" then
    Registry = rawget(namespace, "Registry")
end
if type(Registry) ~= "table" or rawget(Registry, "API") ~= REQUIRED_REGISTRY_API then
    error("MoltenCodes EventKit requires Registry API 2 to be loaded first", 2)
end

local bootstrapPackage = rawget(Registry, "Bootstrap")
local getPackage = rawget(Registry, "Get")
if type(bootstrapPackage) ~= "function" or type(getPackage) ~= "function" then
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

---Whether `implementation` exposes the complete EventKit API 1 surface.
---@param implementation any shared package table handed back by Registry
---@return boolean
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

---Whether `implementation` carries package state of this revision's schema.
---@param implementation table
---@return boolean
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

-- `Registry:Bootstrap` owns the reconciliation every embedded package repeats:
-- look the package up, refuse to reinterpret state owned by a newer revision,
-- and register this one. What stays here is what only EventKit can answer.
local EventKit, previousRevision, selected = bootstrapPackage(Registry, {
    package = PACKAGE_NAME,
    api = API_GENERATION,
    revision = IMPLEMENTATION_REVISION,
    label = "MoltenCodes EventKit",
    validatePublicSurface = validatePublicSurface,
    validateState = validateCurrentState,
})

if EventKit == nil then
    -- Equal or newer compatible revision already owns the shared package table.
    return selected
end

-- Shared state --------------------------------------------------------------
--
-- `_state` is reserved package-private storage on the public facade. Every
-- underscore-prefixed field on the facade is reserved in the same way: consumers
-- must not read or write them, and a future revision may change their shape.

---A listener invoked with the event name followed by the client's payload.
---
---`COMBAT_LOG_EVENT_UNFILTERED` carries no payload; that listener reads the
---event through `CombatLogGetCurrentEventInfo()` instead.
---@alias EventKit.Listener fun(eventName: string, ...: any)

---A connection handle returned by an EventKit subscription.
---@class EventKit.Connection
---@field Disconnect fun(self: EventKit.Connection): boolean
---@field IsConnected fun(self: EventKit.Connection): boolean

---One event name's fan-out: a host registration plus the signal behind it.
---@class EventKit.Channel
---@field eventName string
---@field frame WowFrame Frame holding the host registration.
---@field signal SignalKit.Signal Listener fan-out for this event.
---@field count integer Live EventKit connections sharing the registration.
---@field channels table<string, EventKit.Channel> Owning channel map.
---@field group EventKit.UnitGroup? `nil` for a regular, unfiltered event.

---The channels registered against one normalized unit-token set.
---@class EventKit.UnitGroup
---@field key string Normalized, order-independent unit-set key.
---@field units string[] Sorted, de-duplicated unit tokens.
---@field channels table<string, EventKit.Channel>
---@field frame WowFrame? `nil` once the group has released its Frame.

---The shared EventKit package table.
---@class EventKit
---@field API integer EventKit API generation.
---@field REVISION integer EventKit implementation revision.
---@field Connection EventKit.Connection Shared method prototype for connection handles.
---@field Connect fun(self: EventKit, eventName: string, callback: EventKit.Listener): EventKit.Connection
---@field Once fun(self: EventKit, eventName: string, callback: EventKit.Listener): EventKit.Connection
---@field ConnectUnit fun(self: EventKit, eventName: string, callback: EventKit.Listener, unit1: string, unit2: string?): EventKit.Connection
---@field OnceUnit fun(self: EventKit, eventName: string, callback: EventKit.Listener, unit1: string, unit2: string?): EventKit.Connection

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

-- Connection methods are published on a shared prototype, so `connection.Disconnect()`
-- and `EventKit.Connection.Disconnect()` both reach them with no receiver. Without a
-- guard the first `rawget` inside raises "bad argument #1 to 'rawget'" from EventKit's
-- own line, which names neither the package nor the mistake. Each method therefore
-- tests its receiver first and raises at the caller.
local CONNECTION_RECEIVER_HINT = " must be called on a connection handle; use connection:"

local DISCONNECT_RECEIVER_MESSAGE = "EventKit:Disconnect"
    .. CONNECTION_RECEIVER_HINT
    .. "Disconnect()"
local IS_CONNECTED_RECEIVER_MESSAGE = "EventKit:IsConnected"
    .. CONNECTION_RECEIVER_HINT
    .. "IsConnected()"

---Whether `self` looks like a connection handle owned by this package.
---
---The test is a field type test rather than a metatable comparison on purpose: a
---newer embedded revision builds its own connection metatable, so metatable
---identity would reject handles created by the revision it upgraded. `rawget`
---raises on a non-table, so the table test has to come first.
---@param self any
---@return boolean
local function isConnectionHandle(self)
    return type(self) == "table" and type(rawget(self, "_connected")) == "boolean"
end

---@param eventName any
---@param methodName string public method name, used in the argument error
local function validateEventName(eventName, methodName)
    if type(eventName) ~= "string" or eventName == "" then
        error("EventKit:" .. methodName .. " eventName must be a non-empty string", 3)
    end
end

---@param callback any
---@param methodName string public method name, used in the argument error
local function validateCallback(callback, methodName)
    if type(callback) ~= "function" then
        error("EventKit:" .. methodName .. " callback must be a function", 3)
    end
end

---Sort and de-duplicate unit tokens into a group key.
---
---The key is order-independent, so `"player", "target"` and `"target", "player"`
---share one group and therefore one Frame.
---@param methodName string public method name, used in the argument errors
---@param ... string one or two unit tokens
---@return string[] units sorted, de-duplicated tokens
---@return string key normalized group key
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

---Return one Frame method, or fail naming the host capability that is missing.
---@param frame WowFrame?
---@param methodName string
---@return function
local function requireFrameMethod(frame, methodName)
    local method = frame and frame[methodName]
    if type(method) ~= "function" then
        error("EventKit: requires Frame:" .. methodName .. " support", 0)
    end
    return method
end

---Create one hidden Frame and bind `onEvent` to its `OnEvent` script.
---@param onEvent fun(frame: WowFrame, eventName: string, ...: any)
---@return WowFrame
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

---`OnEvent` handler shared by every unfiltered event registration.
---@param _ WowFrame
---@param eventName string
---@param ... any client payload
local function onRegularFrameEvent(_, eventName, ...)
    -- The dispatcher is validated once at load and kept in shared state, so the
    -- per-event path is a single table read instead of a read plus a type check.
    -- Reading it through `state` rather than capturing it keeps upgrade-in-place
    -- working: a newer revision replaces the slot and existing Frames follow.
    return rawget(state, "dispatchRegular")(EventKit, eventName, ...)
end

---Return the single Frame that carries every unfiltered registration.
---@return WowFrame
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

---Take a Frame for `group`, reusing a released one before creating another.
---@param group EventKit.UnitGroup
---@return WowFrame
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

---Drop `group` and return its Frame to the free list.
---@param group EventKit.UnitGroup
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

---Return the group owning `key`, creating it and its Frame on demand.
---@param units string[]
---@param key string
---@return EventKit.UnitGroup
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

---Return the unfiltered channel for `eventName`, registering it on demand.
---@param eventName string
---@param methodName string public method name, used in the argument error
---@return EventKit.Channel
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

---Return the unit-filtered channel for `eventName`, registering it on demand.
---@param eventName string
---@param units string[]
---@param key string normalized group key produced by `normalizeUnits`
---@param methodName string public method name, used in the argument error
---@return EventKit.Channel
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

---Drop one connection from `channel`, unregistering it once the last one goes.
---@param channel EventKit.Channel
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

---Reusable `xpcall` trampoline that forwards the staged payload.
---@return any ...
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

---Call `callback` so a raised error is reported rather than propagated.
---@param callback EventKit.Listener
---@param ... any event name followed by the client payload
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

---@param connection EventKit.Connection
---@return boolean disconnected `true` only for the call that transitioned the state.
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

---Wrap `callback` in one isolation closure and attach it to `channel`.
---@param channel EventKit.Channel
---@param callback EventKit.Listener
---@param once boolean whether the connection disconnects before its first call
---@return EventKit.Connection
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

---Cancel this subscription and release its share of the host registration.
---@param self EventKit.Connection
---@return boolean disconnected `true` only for the call that transitioned the state.
local function disconnect(self)
    if not isConnectionHandle(self) then
        error(DISCONNECT_RECEIVER_MESSAGE, 2)
    end

    return disconnectEventConnection(self)
end

---Whether this subscription is still delivering.
---@param self EventKit.Connection
---@return boolean connected
local function isConnected(self)
    if not isConnectionHandle(self) then
        error(IS_CONNECTED_RECEIVER_MESSAGE, 2)
    end

    return rawget(self, "_connected") == true
end

-- Dispatch ------------------------------------------------------------------

---Fan one unfiltered event out to its channel.
---@param _ EventKit
---@param eventName string
---@param ... any client payload
local function dispatchRegular(_, eventName, ...)
    local channels = rawget(state, "regularChannels")
    local channel = rawget(channels, eventName)
    if channel ~= nil then
        rawget(channel, "signal"):Fire(eventName, ...)
    end
end

---Fan one unit-filtered event out to its channel inside `group`.
---@param _ EventKit
---@param group EventKit.UnitGroup
---@param eventName string
---@param ... any client payload
local function dispatchUnit(_, group, eventName, ...)
    local channels = rawget(group, "channels")
    local channel = rawget(channels, eventName)
    if channel ~= nil then
        rawget(channel, "signal"):Fire(eventName, ...)
    end
end

-- Public API ----------------------------------------------------------------

---Subscribe to every future occurrence of `eventName`.
---@param _ EventKit
---@param eventName string
---@param callback EventKit.Listener
---@return EventKit.Connection connection
local function connectEvent(_, eventName, callback)
    validateEventName(eventName, "Connect")
    validateCallback(callback, "Connect")
    return connectToChannel(createRegularChannel(eventName, "Connect"), callback, false)
end

---Subscribe to at most one future occurrence of `eventName`.
---@param _ EventKit
---@param eventName string
---@param callback EventKit.Listener
---@return EventKit.Connection connection
local function onceEvent(_, eventName, callback)
    validateEventName(eventName, "Once")
    validateCallback(callback, "Once")
    return connectToChannel(createRegularChannel(eventName, "Once"), callback, true)
end

---Subscribe to `eventName` filtered to one or two unit tokens.
---@param _ EventKit
---@param eventName string
---@param callback EventKit.Listener
---@param ... string one or two unit tokens; `Frame:RegisterUnitEvent` has two slots
---@return EventKit.Connection connection
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

---Subscribe once to `eventName` filtered to one or two unit tokens.
---@param _ EventKit
---@param eventName string
---@param callback EventKit.Listener
---@param ... string one or two unit tokens; `Frame:RegisterUnitEvent` has two slots
---@return EventKit.Connection connection
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
