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
--
-- Owner scopes group connections so one call tears down everything an owner
-- subscribed to. They mirror TimerKit's scope model: `CreateScope` for manual
-- ownership, `ForAddon` for the canonical per-addon scope. EventKit sits below
-- LifecycleKit, so addon scopes are closed through `CloseAddonScopes`: by a
-- LifecycleKit that lists EventKit in `CLOSES_ADDON_SCOPES`, from an older
-- LifecycleKit's `OnShutdown`, or, without LifecycleKit, from EventKit's own
-- `PLAYER_LOGOUT` connection, after that dispatch completes.
--
-- `COMBAT_LOG_EVENT_UNFILTERED` carries no payload; the client hands the event
-- out through `CombatLogGetCurrentEventInfo()`. `ConnectCombatLog` reads it
-- once per event and routes it by sub-event, so the hottest event in the
-- client costs one read and one lookup however many addons listen.
--
-- Contents
-- --------
--   Constants ............. package identity, host limits, staging sizes
--   Dependencies .......... Registry, SignalKit; SchedulerKit and
--                           LifecycleKit (optional)
--   Public-surface validation  facade shape accepted from other copies
--   Bootstrap ............. Registry registration
--   Shared state .......... LuaCATS types, state creation and migration
--   Validation ............ receiver and argument checks
--   WoW Frame boundary .... CreateFrame and Frame method access
--   Unit-group Frames ..... bounded, reused unit-filter Frames
--   Channels .............. per-event host registration and fan-out
--   Listener isolation .... allocation-free protected dispatch
--   Combat log routing .... one CombatLogGetCurrentEventInfo read per event,
--                           fanned out by sub-event
--   Scope ownership ....... intrusive scope links and bulk teardown
--   Connections ........... connection lifecycle and handle methods
--   Dispatch .............. OnEvent to channel fan-out
--   Subscription .......... shared validation and connect path
--   Logout coverage ....... who closes an addon scope at logout, decided at
--                           the first ForAddon (LifecycleKit or EventKit)
--   Coalescing ............ Coalesce and Derive over SchedulerKit, when present
--   Public API ............ package-level subscriptions and scopes
--   Limits ................ SetLimits and GetLimits over the shared limits
--   Scope methods ......... the handle a scope owner receives
--   Commit ................ prototype/facade assignment and self-check

local PACKAGE_NAME = "eventKit"
local API_GENERATION = 1
local IMPLEMENTATION_REVISION = 14
local REQUIRED_REGISTRY_API = 2
local REQUIRED_SIGNAL_API = 1
local STATE_SCHEMA = 8

-- Coalesce and Derive find SchedulerKit through `Registry:Find` when they are
-- called. EventKit never depends on SchedulerKit: SchedulerKit depends on
-- LifecycleKit, which depends on EventKit.
local OPTIONAL_SCHEDULER_API = 1

-- LifecycleKit is optional as well: it depends on EventKit, so EventKit only
-- finds it through `Registry:Find` when an addon asks for its scope, to learn
-- whether LifecycleKit closes that scope at logout.
local OPTIONAL_LIFECYCLE_KIT_API = 1
local LOGOUT_EVENT = "PLAYER_LOGOUT"

-- How an addon scope is closed at logout, recorded on the scope as
-- `_logoutRoute`. `false` means "not decided yet" (a scope an older revision
-- created); `LOGOUT_ROUTE_NONE` (EventKit could not connect its own logout
-- listener) is re-examined at the next `ForAddon`.
local LOGOUT_ROUTE_LIFECYCLE = "lifecycleKit"
local LOGOUT_ROUTE_SHUTDOWN_SUBSCRIPTION = "onShutdown"
local LOGOUT_ROUTE_EVENT = "playerLogout"
local LOGOUT_ROUTE_NONE = "none"

-- The combat-log event and the sub-event name `ConnectCombatLog` accepts for
-- "every sub-event". `*` cannot be a client sub-event name, which are upper-case
-- words joined by underscores, so the wildcard never shadows a real one.
local COMBAT_LOG_EVENT = "COMBAT_LOG_EVENT_UNFILTERED"
local ANY_COMBAT_LOG_SUB_EVENT = "*"

-- One Coalesce or Derive call listens to at most this many distinct events.
-- Per call, not per session: the handle holds one connection per event until
-- `Close`. Real composites merge a handful of related events, so a longer list
-- is refused at the caller as a generated or mistaken argument.
local MAXIMUM_COMPOSITE_EVENTS = 32

-- `Frame:RegisterUnitEvent(event, unit1, unit2)` has exactly two filter slots.
local MAXIMUM_UNIT_TOKENS = 2

-- WoW Frames cannot be destroyed, so the only real bound is on how many EventKit
-- ever creates. Released groups return their Frame to a free list that is
-- therefore bounded by the same number. The bound is the shared `maxUnitFrames`
-- limit: this default, raised through `SetLimits` up to the ceiling. It never
-- accepts `EventKit.UNBOUNDED`, because every Frame it admits lives for the rest
-- of the session whatever the consumer does afterwards.
local DEFAULT_MAX_UNIT_FRAMES = 64
local MAX_UNIT_FRAMES_CEILING = 512

-- Payloads up to this size are staged in reusable upvalues; larger ones use one
-- reusable buffer table. Neither path allocates per event.
local INLINE_ARGUMENT_SLOTS = 6

-- How many buffer slots one multiple assignment fills. Wider payloads fall back
-- to a per-slot `select` for the slots past it. A `ConnectCombatLog` listener
-- receives up to about 24 values, so it takes that fallback on the `xpcall`
-- path; with `securecallfunction` the client forwards the payload itself.
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
if type(Registry) == "nil" and type(namespace) == "table" then
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
if type(SignalKit) == "nil" then
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
        or type(rawget(implementation, "ConnectCombatLog")) ~= "function"
        or type(rawget(implementation, "CreateScope")) ~= "function"
        or type(rawget(implementation, "ForAddon")) ~= "function"
        or type(rawget(implementation, "CloseAddonScopes")) ~= "function"
        or type(rawget(implementation, "Scope")) ~= "table"
        or type(rawget(implementation, "Coalesce")) ~= "function"
        or type(rawget(implementation, "Derive")) ~= "function"
        or type(rawget(implementation, "UNBOUNDED")) ~= "table"
        or type(rawget(implementation, "SetLimits")) ~= "function"
        or type(rawget(implementation, "GetLimits")) ~= "function"
    then
        return false
    end

    local connection = rawget(implementation, "Connection")
    local scope = rawget(implementation, "Scope")
    return type(rawget(connection, "Disconnect")) == "function"
        and type(rawget(connection, "IsConnected")) == "function"
        and type(rawget(scope, "Connect")) == "function"
        and type(rawget(scope, "Once")) == "function"
        and type(rawget(scope, "ConnectUnit")) == "function"
        and type(rawget(scope, "OnceUnit")) == "function"
        and type(rawget(scope, "ConnectCombatLog")) == "function"
        and type(rawget(scope, "DisconnectAll")) == "function"
        and type(rawget(scope, "Close")) == "function"
        and type(rawget(scope, "IsClosed")) == "function"
        and type(rawget(scope, "GetAddonName")) == "function"
        and type(rawget(scope, "GetActiveCount")) == "function"
        and type(rawget(scope, "Coalesce")) == "function"
        and type(rawget(scope, "Derive")) == "function"
end

---Whether `limits` holds every shared limit with a value this revision accepts.
---@param limits any
---@return boolean
local function validateLimitsState(limits)
    if type(limits) ~= "table" then
        return false
    end
    local maxUnitFrames = rawget(limits, "maxUnitFrames")
    return type(maxUnitFrames) == "number"
        and maxUnitFrames % 1 == 0
        and maxUnitFrames >= 1
        and maxUnitFrames <= MAX_UNIT_FRAMES_CEILING
end

---Whether `implementation` carries package state of this revision's schema.
---@param implementation table
---@return boolean
local function validateCurrentState(implementation)
    local currentState = rawget(implementation, "_state")
    return type(currentState) == "table"
        and rawget(currentState, "schema") == STATE_SCHEMA
        and type(rawget(currentState, "unbounded")) == "table"
        and rawget(implementation, "UNBOUNDED") == rawget(currentState, "unbounded")
        and validateLimitsState(rawget(currentState, "limits"))
        and type(rawget(currentState, "regularChannels")) == "table"
        and type(rawget(currentState, "unitGroups")) == "table"
        and type(rawget(currentState, "unitFrames")) == "table"
        and type(rawget(currentState, "unitFrameCount")) == "number"
        and type(rawget(currentState, "dispatchRegular")) == "function"
        and type(rawget(currentState, "dispatchUnit")) == "function"
        and type(rawget(currentState, "isolate")) == "function"
        and type(rawget(currentState, "combatLog")) == "table"
        and type(rawget(currentState, "dispatchCombatLog")) == "function"
        and type(rawget(currentState, "dispatchDepth")) == "number"
        and type(rawget(currentState, "pendingScopes")) == "table"
        and type(rawget(currentState, "pendingScopeCount")) == "number"
        and type(rawget(currentState, "addonScopes")) == "table"
        and type(rawget(currentState, "scopeMetatable")) == "table"
        and type(rawget(currentState, "composites")) == "table"
        and type(rawget(currentState, "compositeMetatables")) == "table"
        and type(rawget(currentState, "compositePrototypes")) == "table"
        and rawget(currentState, "logoutConnection") ~= nil
        and type(rawget(currentState, "closeOnLogout")) == "function"
        and type(rawget(currentState, "closeOnShutdown")) == "function"
end

-- Bootstrap -----------------------------------------------------------------

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

if type(EventKit) == "nil" then
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
---`COMBAT_LOG_EVENT_UNFILTERED` carries no payload: a `Connect` listener for it
---receives the event name alone and reads the event through
---`CombatLogGetCurrentEventInfo()` itself. `ConnectCombatLog` does that read
---once for every listener and hands them an `EventKit.CombatLogListener` call.
---@alias EventKit.Listener fun(eventName: string, ...: any)

---A combat-log listener. It receives every return of
---`CombatLogGetCurrentEventInfo()` unchanged: the eleven base values, then the
---sub-event's own suffix (`spellId, spellName, spellSchool, amount, ...` for a
---spell sub-event), whose count varies by sub-event. There is no event name in
---front; the sub-event is the second value.
---@alias EventKit.CombatLogListener fun(timestamp: number, subEvent: string, hideCaster: boolean, sourceGUID: string, sourceName: string?, sourceFlags: integer, sourceRaidFlags: integer, destGUID: string, destName: string?, destFlags: integer, destRaidFlags: integer, ...: any)

---A connection handle returned by an EventKit subscription.
---@class EventKit.Connection
---@field Disconnect fun(self: EventKit.Connection): boolean
---@field IsConnected fun(self: EventKit.Connection): boolean

---An ownership scope for connections, closed by its owner or, for an addon
---scope, through `EventKit:CloseAddonScopes`.
---@class EventKit.Scope
---@field Connect fun(self: EventKit.Scope, eventName: string, callback: EventKit.Listener): EventKit.Connection
---@field Once fun(self: EventKit.Scope, eventName: string, callback: EventKit.Listener): EventKit.Connection
---@field ConnectUnit fun(self: EventKit.Scope, eventName: string, callback: EventKit.Listener, unit1: string, unit2: string?): EventKit.Connection
---@field OnceUnit fun(self: EventKit.Scope, eventName: string, callback: EventKit.Listener, unit1: string, unit2: string?): EventKit.Connection
---@field ConnectCombatLog fun(self: EventKit.Scope, subEvent: string, callback: EventKit.CombatLogListener): EventKit.Connection
---@field DisconnectAll fun(self: EventKit.Scope): integer
---@field Close fun(self: EventKit.Scope): boolean
---@field IsClosed fun(self: EventKit.Scope): boolean
---@field GetAddonName fun(self: EventKit.Scope): string?
---@field GetActiveCount fun(self: EventKit.Scope): integer
---@field Coalesce fun(self: EventKit.Scope, events: string|string[], intervalSeconds: number, callback: fun(set: table<any, any>), options: EventKit.CoalesceOptions?): EventKit.CoalesceHandle
---@field Derive fun(self: EventKit.Scope, events: string|string[], compute: fun(): any, options: EventKit.DeriveOptions?): EventKit.DeriveHandle

---Options accepted by `Coalesce`.
---@class EventKit.CoalesceOptions
---@field byEvent boolean? Key the set by event name instead of the first payload argument.
---@field units string[]? One or two unit tokens; the events are then unit events, as with `ConnectUnit`.
---@field maxKeys integer? Distinct keys one interval may collect; SchedulerKit's default is 256.
---@field lane table? A SchedulerKit lane (`SchedulerKit:Lane`) to deliver through.

---Options accepted by `Derive`.
---@class EventKit.DeriveOptions
---@field delaySeconds number? Debounce before recomputing; `0`, the default, is the next frame.
---@field equals (fun(previous: any, current: any): boolean)? Decides whether a new value is a change; `==` when omitted.
---@field units string[]? One or two unit tokens; the events are then unit events, as with `ConnectUnit`.

---Events coalesced into one callback per interval.
---@class EventKit.CoalesceHandle
---@field Flush fun(self: EventKit.CoalesceHandle): boolean, string?
---@field IsPending fun(self: EventKit.CoalesceHandle): boolean
---@field GetStats fun(self: EventKit.CoalesceHandle): table<string, integer>
---@field Close fun(self: EventKit.CoalesceHandle): boolean
---@field IsClosed fun(self: EventKit.CoalesceHandle): boolean

---A value recomputed when any of its events fires.
---@class EventKit.DeriveHandle
---@field Get fun(self: EventKit.DeriveHandle): any
---@field OnChange fun(self: EventKit.DeriveHandle, callback: fun(value: any, previous: any)): SignalKit.Connection
---@field Invalidate fun(self: EventKit.DeriveHandle)
---@field Close fun(self: EventKit.DeriveHandle): boolean
---@field IsClosed fun(self: EventKit.DeriveHandle): boolean

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

---One combat-log sub-event's fan-out: the listeners that asked for it.
---@class EventKit.CombatLogRoute
---@field subEvent string The sub-event routed here, or `"*"` for the wildcard route.
---@field signal SignalKit.Signal Listener fan-out for this sub-event.
---@field count integer Live connections on this route; it leaves the router at zero.

---The combat-log router: the package's one share of the
---`COMBAT_LOG_EVENT_UNFILTERED` registration and the routes behind it.
---@class EventKit.CombatLogRouter
---@field channel EventKit.Channel|false The event's channel while at least one combat-log listener exists.
---@field inner SignalKit.Connection|false The router's connection on that channel's signal.
---@field readEventInfo function|false `CombatLogGetCurrentEventInfo`, or `C_CombatLog.GetCurrentEventInfo` without it, resolved each time the router attaches.
---@field routes table<string, EventKit.CombatLogRoute> Routes by sub-event name.
---@field anyRoute EventKit.CombatLogRoute|false The wildcard route, delivered after the sub-event's own.
---@field listenerCount integer Live combat-log connections; the router attaches at the first and detaches after the last.

---The shared limits. `SetLimits` accepts any subset; `GetLimits` returns a copy.
---@class EventKit.Limits
---@field maxUnitFrames integer Unit-filter Frames EventKit may ever create in the session; default 64, at most 512, never `EventKit.UNBOUNDED`.

---The shared EventKit package table.
---@class EventKit
---@field API integer EventKit API generation.
---@field REVISION integer EventKit implementation revision.
---@field UNBOUNDED table The package sentinel for "no limit", where a limit accepts it. No EventKit limit does yet.
---@field SetLimits fun(self: EventKit, limits: EventKit.Limits)
---@field GetLimits fun(self: EventKit): EventKit.Limits
---@field Connection EventKit.Connection Shared method prototype for connection handles.
---@field Scope EventKit.Scope Shared method prototype for scopes.
---@field Connect fun(self: EventKit, eventName: string, callback: EventKit.Listener): EventKit.Connection
---@field Once fun(self: EventKit, eventName: string, callback: EventKit.Listener): EventKit.Connection
---@field ConnectUnit fun(self: EventKit, eventName: string, callback: EventKit.Listener, unit1: string, unit2: string?): EventKit.Connection
---@field OnceUnit fun(self: EventKit, eventName: string, callback: EventKit.Listener, unit1: string, unit2: string?): EventKit.Connection
---@field ConnectCombatLog fun(self: EventKit, subEvent: string, callback: EventKit.CombatLogListener): EventKit.Connection
---@field CreateScope fun(self: EventKit): EventKit.Scope
---@field ForAddon fun(self: EventKit, addonName: string): EventKit.Scope
---@field CloseAddonScopes fun(self: EventKit, addonName: string): boolean
---@field Coalesce fun(self: EventKit, events: string|string[], intervalSeconds: number, callback: fun(set: table<any, any>), options: EventKit.CoalesceOptions?): EventKit.CoalesceHandle
---@field Derive fun(self: EventKit, events: string|string[], compute: fun(): any, options: EventKit.DeriveOptions?): EventKit.DeriveHandle

local Connection = rawget(EventKit, "Connection")
local Scope = rawget(EventKit, "Scope")
local state = rawget(EventKit, "_state")

if type(previousRevision) == "nil" then
    if Connection ~= nil or Scope ~= nil or state ~= nil then
        error("MoltenCodes EventKit package state is corrupted or incomplete", 2)
    end

    Connection = {}
    Scope = {}
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
        -- The combat-log router (see "Combat log routing") and the dispatch
        -- its channel listener resolves through, installed at commit.
        combatLog = {
            channel = false,
            inner = false,
            readEventInfo = false,
            routes = {},
            anyRoute = false,
            listenerCount = 0,
        },
        dispatchCombatLog = nil,
        addonScopes = {},
        scopeMetatable = {},
        -- How many dispatches are on the stack, and the scopes closed during
        -- them whose connections are swept once the outermost one returns.
        dispatchDepth = 0,
        pendingScopes = {},
        pendingScopeCount = 0,
        -- Coalesce and Derive handles: the dispatch their listener closures
        -- resolve through, and one metatable plus method table per kind.
        composites = {},
        compositeMetatables = {},
        compositePrototypes = {},
        -- The package sentinel published as `EventKit.UNBOUNDED`, kept here so
        -- every revision hands out the same table, and the shared limits
        -- `SetLimits` writes, which a newer revision inherits.
        unbounded = {},
        limits = { maxUnitFrames = DEFAULT_MAX_UNIT_FRAMES },
        -- The one `PLAYER_LOGOUT` connection that closes addon scopes when no
        -- LifecycleKit does, `false` until an addon needs it. The handlers the
        -- logout routes resolve when they run (`closeOnLogout`,
        -- `closeOnShutdown`) are installed at commit, like `isolate`.
        logoutConnection = false,
    }

    rawset(EventKit, "Connection", Connection)
    rawset(EventKit, "Scope", Scope)
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
        rawset(state, "schema", 2)
        schema = 2
    end

    if schema == 2 then
        -- Revisions 2 to 4 had no scopes. Their connections carry no scope
        -- link, which every scope path reads as "not owned by a scope".
        rawset(state, "addonScopes", {})
        rawset(state, "scopeMetatable", {})
        rawset(state, "schema", 3)
        schema = 3
    end

    if schema == 3 then
        -- Revision 5 closed scopes immediately, even mid-dispatch.
        rawset(state, "dispatchDepth", 0)
        rawset(state, "pendingScopes", {})
        rawset(state, "pendingScopeCount", 0)
        rawset(state, "schema", 4)
        schema = 4
    end

    if schema == 4 then
        -- Revision 6 had no Coalesce or Derive. Its scopes hold only plain
        -- connections, which the revision-7 sweep still recognises.
        rawset(state, "composites", {})
        rawset(state, "compositeMetatables", {})
        rawset(state, "compositePrototypes", {})
        rawset(state, "schema", 5)
        schema = 5
    end

    if schema == 5 then
        -- Revisions 7 to 9 had no sentinel and a fixed Frame cap of 64, which
        -- becomes the default of the shared `maxUnitFrames` limit. Frames
        -- they already created stay counted against it.
        rawset(state, "unbounded", {})
        rawset(state, "limits", { maxUnitFrames = DEFAULT_MAX_UNIT_FRAMES })
        rawset(state, "schema", 6)
        schema = 6
    end

    if schema == 6 then
        -- Revision 10 had no logout fallback. Its addon scopes are given a
        -- logout route at the end of the bootstrap; the two handlers are
        -- installed with the other shared functions.
        if rawget(state, "logoutConnection") == nil then
            rawset(state, "logoutConnection", false)
        end
        rawset(state, "schema", 7)
        schema = 7
    end

    if schema == 7 then
        -- Revision 11 had no combat-log routing. A `Connect` listener it made
        -- for the combat-log event keeps its channel; the router shares that
        -- channel when the first `ConnectCombatLog` arrives.
        rawset(state, "combatLog", {
            channel = false,
            inner = false,
            readEventInfo = false,
            routes = {},
            anyRoute = false,
            listenerCount = 0,
        })
        rawset(state, "schema", STATE_SCHEMA)
        schema = STATE_SCHEMA
    end

    if schema ~= STATE_SCHEMA then
        error("MoltenCodes EventKit package state is corrupted or incomplete", 2)
    end

    if Scope == nil then
        Scope = {}
        rawset(EventKit, "Scope", Scope)
    elseif type(Scope) ~= "table" then
        error("MoltenCodes EventKit package state is corrupted or incomplete", 2)
    end
end

local CONNECTION_METATABLE = { __index = Connection }

-- The sentinel and the shared limits outlive this copy: a newer revision reads
-- the same tables, so a consumer's `SetLimits` and its `UNBOUNDED` comparisons
-- survive an in-place upgrade.
local UNBOUNDED = rawget(state, "unbounded")
local sharedLimits = rawget(state, "limits")

-- Coalesce and Derive handles are validated by metatable identity, so their
-- metatables live in shared state beside the scope metatable.
local COMPOSITE_METATABLES = rawget(state, "compositeMetatables")
local COMPOSITE_PROTOTYPES = rawget(state, "compositePrototypes")
for _, kind in ipairs({ "coalesce", "derive" }) do
    if type(rawget(COMPOSITE_METATABLES, kind)) ~= "table" then
        rawset(COMPOSITE_METATABLES, kind, {})
    end
    if type(rawget(COMPOSITE_PROTOTYPES, kind)) ~= "table" then
        rawset(COMPOSITE_PROTOTYPES, kind, {})
    end
    rawset(rawget(COMPOSITE_METATABLES, kind), "__index", rawget(COMPOSITE_PROTOTYPES, kind))
end
local COALESCE_METATABLE = rawget(COMPOSITE_METATABLES, "coalesce")
local DERIVE_METATABLE = rawget(COMPOSITE_METATABLES, "derive")

-- Unlike the connection metatable, the scope metatable lives in shared state:
-- scope receivers are validated by metatable identity, which therefore has to
-- survive an in-place upgrade.
local SCOPE_METATABLE = rawget(state, "scopeMetatable")
rawset(SCOPE_METATABLE, "__index", Scope)

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

-- Argument validation raises with an explicit stack level so the reported
-- position is the line that called the public method, never a line inside
-- EventKit. `level` is always the value `error` needs *inside the function that
-- receives it*, so every further hop towards `error` adds exactly one.
--
-- On a client with secret values, comparing a secret with anything, `nil`
-- included, raises inside EventKit instead of at the caller. Values EventKit
-- did not create are therefore tested for absence with `type(value) == "nil"`,
-- and a secret is refused (or, for event payloads, not compared) before any
-- other comparison.

---Whether the client reports `value` as secret; always `false` elsewhere.
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
---@param label string qualified argument name, used in the argument error
---@param level integer stack level the failure is reported at
local function refuseSecret(value, label, level)
    if isSecret(value) then
        error(label .. " must not be a secret value", level)
    end
end

---@param eventName any
---@param label string qualified public method name, used in the argument error
---@param level integer stack level the failure is reported at
local function validateEventName(eventName, label, level)
    refuseSecret(eventName, label .. " eventName", level + 1)
    if type(eventName) ~= "string" or eventName == "" then
        error(label .. " eventName must be a non-empty string", level)
    end
end

---Sub-event names are the client's (`SPELL_DAMAGE`), plus the `*` wildcard.
---The running client stays authoritative on which exist, as for event names.
---@param subEvent any
---@param label string qualified public method name, used in the argument error
---@param level integer stack level the failure is reported at
local function validateSubEvent(subEvent, label, level)
    refuseSecret(subEvent, label .. " subEvent", level + 1)
    if type(subEvent) ~= "string" or subEvent == "" then
        error(label .. " subEvent must be a non-empty string", level)
    end
end

---@param callback any
---@param label string qualified public method name, used in the argument error
---@param level integer stack level the failure is reported at
local function validateCallback(callback, label, level)
    if type(callback) ~= "function" then
        error(label .. " callback must be a function", level)
    end
end

---@param value any
---@param label string argument description, used in the argument error
---@param level integer stack level the failure is reported at
local function validateNonEmptyString(value, label, level)
    refuseSecret(value, label, level + 1)
    if type(value) ~= "string" or value == "" then
        error(label .. " must be a non-empty string", level)
    end
end

---@param scope any receiver the public method was called on
---@param label string qualified public method name, used in the argument error
---@param level integer stack level the failure is reported at
local function validateScope(scope, label, level)
    if type(scope) ~= "table" or getmetatable(scope) ~= SCOPE_METATABLE then
        error(label .. " must be called on an EventKit scope", level)
    end
end

---@param scope EventKit.Scope
---@param label string qualified public method name, used in the argument error
---@param level integer stack level the failure is reported at
local function ensureScopeOpen(scope, label, level)
    if rawget(scope, "_closed") == true then
        error(label .. " cannot connect in a closed scope", level)
    end
end

---Sort and de-duplicate unit tokens into a group key.
---
---The key is order-independent, so `"player", "target"` and `"target", "player"`
---share one group and therefore one Frame.
---@param label string qualified public method name, used in the argument errors
---@param level integer stack level the failures are reported at
---@param ... string one or two unit tokens
---@return string[] units sorted, de-duplicated tokens
---@return string key normalized group key
local function normalizeUnits(label, level, ...)
    local count = select("#", ...)
    if count == 0 then
        error(label .. " requires at least one unit token", level)
    end

    local units = {}
    local seen = {}

    for index = 1, count do
        local unit = select(index, ...)
        refuseSecret(unit, label .. " unit token", level + 1)
        if type(unit) ~= "string" or unit == "" then
            error(label .. " unit tokens must be non-empty strings", level)
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
            label
                .. " accepts at most "
                .. MAXIMUM_UNIT_TOKENS
                .. " distinct unit tokens because Frame:RegisterUnitEvent has "
                .. MAXIMUM_UNIT_TOKENS
                .. " filter slots; received "
                .. #units,
            level
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
    if type(frame) == "nil" then
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
    local maxUnitFrames = rawget(sharedLimits, "maxUnitFrames")
    if created >= maxUnitFrames then
        error(
            "EventKit: refusing to create more than "
                .. maxUnitFrames
                .. " unit-filter Frames; disconnect unused unit subscriptions, "
                .. "reuse unit sets or raise EventKit:SetLimits{ maxUnitFrames }",
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
---@param label string qualified public method name, used in the argument error
---@param level integer stack level the failure is reported at
---@return EventKit.Channel
local function createRegularChannel(eventName, label, level)
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
        error(label .. " could not register event " .. eventName, level)
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
---@param label string qualified public method name, used in the argument error
---@param level integer stack level the failure is reported at
---@return EventKit.Channel
local function createUnitChannel(eventName, units, key, label, level)
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
        error(label .. " could not register event " .. eventName, level)
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

---Build the one wrapper closure a connection (or the combat-log router) hands
---SignalKit: one per connection, never per event. The isolation function is
---read from shared state so a compatible newer revision can replace it for
---connections that already exist.
---@param callback function
---@return fun(...: any): any
local function newIsolatedListener(callback)
    return function(...)
        return rawget(state, "isolate")(callback, ...)
    end
end

-- Combat log routing ----------------------------------------------------------
--
-- `COMBAT_LOG_EVENT_UNFILTERED` is the highest-frequency event in the client
-- and carries no payload: every listener would otherwise call
-- `CombatLogGetCurrentEventInfo()` itself and test the sub-event it wants. The
-- router is one listener on that event's ordinary channel, so it shares the
-- host registration with plain `Connect` listeners and holds it only while a
-- combat-log listener exists. Per event it reads the client once, looks up the
-- sub-event's route and fires it with the returns unchanged, then the wildcard
-- route. A sub-event nobody listens for costs the read and one lookup.
--
-- The router's listener runs through the same isolation as any listener, so a
-- client read that raises is reported and the plain `Connect` listeners behind
-- the router on the channel still receive the event. Each route listener is
-- then isolated individually, exactly as a `Connect` listener is. The extra
-- isolated call stages no arguments and allocates nothing per event.

---The one listener the router connects to the combat-log channel. It resolves
---the dispatcher through shared state so a newer revision replaces it while
---the connection an older copy made stays in place.
local function onCombatLogEvent()
    return rawget(state, "dispatchCombatLog")()
end

---Fan one combat-log event out by its sub-event, then to the wildcard route.
---@param combatLog EventKit.CombatLogRouter
---@param ... any every return of `CombatLogGetCurrentEventInfo()`
local function routeCombatLogEvent(combatLog, ...)
    -- The sub-event is the second return. A multiple assignment reads it
    -- without copying the rest of the payload, which `select` would.
    local _, subEvent = ...
    local route = rawget(rawget(combatLog, "routes"), subEvent)
    -- Both routes are read before either fires: a wildcard listener connected
    -- by a sub-event listener must not receive the event being dispatched,
    -- as a listener connected during a `Connect` dispatch does not. A wildcard
    -- route dropped during the first fire is harmless, because SignalKit has
    -- marked its connections disconnected.
    local anyRoute = rawget(combatLog, "anyRoute")
    if route ~= nil then
        rawget(route, "signal"):Fire(...)
    end
    if anyRoute ~= false then
        rawget(anyRoute, "signal"):Fire(...)
    end
end

---Read the client's current combat-log event once and route it.
local function dispatchCombatLog()
    local combatLog = rawget(state, "combatLog")
    return routeCombatLogEvent(combatLog, rawget(combatLog, "readEventInfo")())
end

---Take the router's share of the combat-log registration.
---
---Called for the first combat-log listener. The client API is resolved here
---rather than at load so a copy loaded before the API existed still works,
---and it is checked before anything is registered so a refusal leaves nothing
---behind. The registration itself is refused at the caller, like `Connect`.
---
---The global `CombatLogGetCurrentEventInfo` is preferred, so a replacement
---another addon installed there is honoured as before. Current classic
---clients document only `C_CombatLog.GetCurrentEventInfo`, so the namespaced
---function is used when the global is absent. Retail 12 clients document
---neither for addons (only `C_CombatLogSecure`), so there the call raises.
---@param combatLog EventKit.CombatLogRouter
---@param label string qualified public method name, used in the argument error
---@param level integer stack level a refused registration is reported at
local function attachCombatLogRouter(combatLog, label, level)
    -- CombatLogGetCurrentEventInfo and C_CombatLog are World of Warcraft client APIs reachable only through the global table.
    -- selene: allow(global_usage)
    local readEventInfo = rawget(_G, "CombatLogGetCurrentEventInfo")
    if type(readEventInfo) ~= "function" then
        -- selene: allow(global_usage)
        local combatLogNamespace = rawget(_G, "C_CombatLog")
        if type(combatLogNamespace) == "table" then
            readEventInfo = rawget(combatLogNamespace, "GetCurrentEventInfo")
        end
    end
    if type(readEventInfo) ~= "function" then
        error("EventKit: requires the World of Warcraft CombatLogGetCurrentEventInfo API", 0)
    end

    local channel = createRegularChannel(COMBAT_LOG_EVENT, label, level + 1)
    local inner = rawget(channel, "signal"):Connect(newIsolatedListener(onCombatLogEvent))
    rawset(channel, "count", rawget(channel, "count") + 1)

    rawset(combatLog, "channel", channel)
    rawset(combatLog, "inner", inner)
    rawset(combatLog, "readEventInfo", readEventInfo)
end

---Give the router's share of the registration back; the channel unregisters
---the event only when no plain `Connect` listener holds it.
---@param combatLog EventKit.CombatLogRouter
local function detachCombatLogRouter(combatLog)
    local channel = rawget(combatLog, "channel")
    local inner = rawget(combatLog, "inner")
    rawset(combatLog, "channel", false)
    rawset(combatLog, "inner", false)
    rawset(combatLog, "readEventInfo", false)

    inner:Disconnect()
    releaseChannel(channel)
end

---Return the route for `subEvent`, attaching the router and creating the route
---on demand.
---@param subEvent string a client sub-event name, or `"*"`
---@param label string qualified public method name, used in the argument error
---@param level integer stack level a refused registration is reported at
---@return EventKit.CombatLogRoute
local function acquireCombatLogRoute(subEvent, label, level)
    local combatLog = rawget(state, "combatLog")
    if rawget(combatLog, "channel") == false then
        attachCombatLogRouter(combatLog, label, level + 1)
    end

    local routes = rawget(combatLog, "routes")
    local isWildcard = subEvent == ANY_COMBAT_LOG_SUB_EVENT
    local route
    if isWildcard then
        route = rawget(combatLog, "anyRoute")
        if route == false then
            route = nil
        end
    else
        route = rawget(routes, subEvent)
    end
    if route ~= nil then
        return route
    end

    route = {
        subEvent = subEvent,
        signal = SignalKit:New(),
        count = 0,
    }
    if isWildcard then
        rawset(combatLog, "anyRoute", route)
    else
        rawset(routes, subEvent, route)
    end
    return route
end

---Drop one connection from `route`, dropping the route with its last listener
---and detaching the router with the last listener of any route.
---@param route EventKit.CombatLogRoute
local function releaseCombatLogRoute(route)
    local combatLog = rawget(state, "combatLog")
    local count = rawget(route, "count") - 1
    rawset(route, "count", count)
    local listenerCount = rawget(combatLog, "listenerCount") - 1
    rawset(combatLog, "listenerCount", listenerCount)

    -- As in `releaseChannel`, any non-positive count is "empty", so a
    -- bookkeeping slip cannot pin a route or the registration for the session.
    if count <= 0 then
        local subEvent = rawget(route, "subEvent")
        if subEvent == ANY_COMBAT_LOG_SUB_EVENT then
            rawset(combatLog, "anyRoute", false)
        else
            rawset(rawget(combatLog, "routes"), subEvent, nil)
        end
    end

    if listenerCount <= 0 and rawget(combatLog, "channel") ~= false then
        detachCombatLogRouter(combatLog)
    end
end

-- Scope ownership -----------------------------------------------------------
--
-- A scope keeps its live connections on an intrusive doubly linked list: the
-- links are fields on the connection itself, so joining or leaving a scope
-- allocates nothing and a disconnected handle is unlinked in O(1) the moment
-- it disconnects. `false` marks an empty link so the fields exist from the
-- connection's creation and never rehash it. Connections made by a revision
-- before scopes existed carry no `_scope` field at all, which reads the same.

---Append `connection` to `scope`'s live list, keeping creation order.
---@param scope EventKit.Scope
---@param connection EventKit.Connection
local function linkToScope(scope, connection)
    local tail = rawget(scope, "_tail")
    rawset(connection, "_scope", scope)
    rawset(connection, "_scopePrevious", tail)
    rawset(connection, "_scopeNext", false)
    if tail == false then
        rawset(scope, "_head", connection)
    else
        rawset(tail, "_scopeNext", connection)
    end
    rawset(scope, "_tail", connection)
    rawset(scope, "_activeCount", rawget(scope, "_activeCount") + 1)
end

---Remove `connection` from the scope that owns it, if any. Never raises.
---@param connection EventKit.Connection
local function unlinkFromScope(connection)
    local scope = rawget(connection, "_scope")
    if type(scope) ~= "table" then
        return
    end

    local previous = rawget(connection, "_scopePrevious")
    local following = rawget(connection, "_scopeNext")
    if previous == false then
        rawset(scope, "_head", following)
    else
        rawset(previous, "_scopeNext", following)
    end
    if following == false then
        rawset(scope, "_tail", previous)
    else
        rawset(following, "_scopePrevious", previous)
    end

    rawset(connection, "_scope", false)
    rawset(connection, "_scopePrevious", false)
    rawset(connection, "_scopeNext", false)
    rawset(scope, "_activeCount", rawget(scope, "_activeCount") - 1)
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
    local route = rawget(connection, "_route")

    rawset(connection, "_connected", false)
    rawset(connection, "_inner", nil)
    rawset(connection, "_channel", nil)
    rawset(connection, "_route", nil)

    -- Leave the scope before touching SignalKit or the host, both of which can
    -- raise. Bulk teardown relies on every attempted connection leaving the
    -- list, whatever happens after this line.
    unlinkFromScope(connection)

    inner:Disconnect()
    -- A combat-log connection shares the host registration through its route
    -- instead of holding a channel. Connections made before revision 12 carry
    -- no `_route` field at all, which reads the same as `false`.
    if route ~= nil and route ~= false then
        releaseCombatLogRoute(route)
    else
        releaseChannel(channel)
    end
    return true
end

---Wrap `callback` in one isolation closure and attach it to `channel`.
---@param channel EventKit.Channel
---@param callback EventKit.Listener
---@param once boolean whether the connection disconnects before its first call
---@param scope EventKit.Scope|false owning scope, or `false` for none
---@return EventKit.Connection
local function connectToChannel(channel, callback, once, scope)
    local connection = setmetatable({
        _connected = true,
        _inner = nil,
        _channel = channel,
        _route = false,
        _scope = false,
        _scopePrevious = false,
        _scopeNext = false,
    }, CONNECTION_METATABLE)

    local signal = rawget(channel, "signal")
    local inner

    -- A one-shot disconnects itself before the isolated call, so it needs its
    -- own wrapper; every other connection shares the plain one.
    if once then
        inner = signal:Connect(function(...)
            disconnectEventConnection(connection)
            return rawget(state, "isolate")(callback, ...)
        end)
    else
        inner = signal:Connect(newIsolatedListener(callback))
    end

    rawset(connection, "_inner", inner)
    rawset(channel, "count", rawget(channel, "count") + 1)
    if scope ~= false then
        linkToScope(scope, connection)
    end
    return connection
end

---Attach `callback` to a combat-log route as an ordinary connection handle.
---@param route EventKit.CombatLogRoute
---@param callback EventKit.CombatLogListener
---@param scope EventKit.Scope|false owning scope, or `false` for none
---@return EventKit.Connection
local function connectToRoute(route, callback, scope)
    local connection = setmetatable({
        _connected = true,
        _inner = nil,
        _channel = false,
        _route = route,
        _scope = false,
        _scopePrevious = false,
        _scopeNext = false,
    }, CONNECTION_METATABLE)

    local inner = rawget(route, "signal"):Connect(newIsolatedListener(callback))
    rawset(connection, "_inner", inner)
    rawset(route, "count", rawget(route, "count") + 1)

    local combatLog = rawget(state, "combatLog")
    rawset(combatLog, "listenerCount", rawget(combatLog, "listenerCount") + 1)
    if scope ~= false then
        linkToScope(scope, connection)
    end
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
--
-- EventKit counts the dispatches on the stack so that closing a scope from
-- inside a listener never cuts short the delivery already in flight: the
-- scope refuses new connections at once, and its connections are swept when
-- the outermost dispatch returns. The count is two field writes per event and
-- the sweep check one comparison, so the per-event path stays allocation-free.

-- Assigned in the subscription section, once bulk disconnection exists.
local sweepPendingScopes

---Fire `channel`'s signal with the dispatch depth raised around it.
---@param channel EventKit.Channel
---@param eventName string
---@param ... any client payload
local function fireChannel(channel, eventName, ...)
    local signal = rawget(channel, "signal")
    rawset(state, "dispatchDepth", rawget(state, "dispatchDepth") + 1)
    -- Listeners are isolated and never raise; SignalKit itself could only
    -- raise on a bug. `pcall` still guarantees the depth is restored, because a
    -- stuck depth would defer every later scope close for the whole session.
    local ok, failure = pcall(signal.Fire, signal, eventName, ...)
    local depth = rawget(state, "dispatchDepth") - 1
    rawset(state, "dispatchDepth", depth)
    if depth <= 0 and rawget(state, "pendingScopeCount") > 0 then
        sweepPendingScopes()
    end
    if not ok then
        error(failure, 0)
    end
end

---Fan one unfiltered event out to its channel.
---@param _ EventKit
---@param eventName string
---@param ... any client payload
local function dispatchRegular(_, eventName, ...)
    local channels = rawget(state, "regularChannels")
    local channel = rawget(channels, eventName)
    if channel ~= nil then
        fireChannel(channel, eventName, ...)
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
        fireChannel(channel, eventName, ...)
    end
end

-- Subscription --------------------------------------------------------------
--
-- Package-level and scope-level entry points share these two paths, so both sit
-- at the same distance from the validators and report at their caller's line.
-- Callers keep the result in a local before returning it: a Lua tail call would
-- remove the public frame the stack level is counted against.

---Validate and attach one unfiltered subscription.
---@param scope EventKit.Scope|false owning scope, or `false` for none
---@param label string qualified public method name, used in the argument errors
---@param level integer stack level the failures are reported at
---@param eventName any
---@param callback any
---@param once boolean
---@return EventKit.Connection
local function subscribeRegular(scope, label, level, eventName, callback, once)
    validateEventName(eventName, label, level + 1)
    validateCallback(callback, label, level + 1)
    local channel = createRegularChannel(eventName, label, level + 1)
    local connection = connectToChannel(channel, callback, once, scope)
    return connection
end

---Validate and attach one unit-filtered subscription.
---@param scope EventKit.Scope|false owning scope, or `false` for none
---@param label string qualified public method name, used in the argument errors
---@param level integer stack level the failures are reported at
---@param eventName any
---@param callback any
---@param once boolean
---@param ... string one or two unit tokens
---@return EventKit.Connection
local function subscribeUnit(scope, label, level, eventName, callback, once, ...)
    validateEventName(eventName, label, level + 1)
    validateCallback(callback, label, level + 1)
    local units, key = normalizeUnits(label, level + 1, ...)
    local channel = createUnitChannel(eventName, units, key, label, level + 1)
    local connection = connectToChannel(channel, callback, once, scope)
    return connection
end

---Validate and attach one combat-log subscription.
---@param scope EventKit.Scope|false owning scope, or `false` for none
---@param label string qualified public method name, used in the argument errors
---@param level integer stack level the failures are reported at
---@param subEvent any
---@param callback any
---@return EventKit.Connection
local function subscribeCombatLog(scope, label, level, subEvent, callback)
    validateSubEvent(subEvent, label, level + 1)
    validateCallback(callback, label, level + 1)
    local route = acquireCombatLogRoute(subEvent, label, level + 1)
    local connection = connectToRoute(route, callback, scope)
    return connection
end

---Release one member of a scope: a connection, or a Coalesce or Derive
---handle, which carries a `_kind` and releases everything it owns.
---@param member table
---@return boolean released `true` only for the call that transitioned it.
local function disconnectScopeMember(member)
    if rawget(member, "_kind") ~= nil then
        return rawget(rawget(state, "composites"), "close")(member)
    end
    return disconnectEventConnection(member)
end

---Disconnect every live connection of `scope` in creation order.
---
---Best effort: a failure does not stop the sweep, and the first error object is
---re-raised unchanged once every connection has been attempted. The caller
---owns validation, so addon-scope closing does not have to fake a call site.
---@param scope EventKit.Scope
---@return integer disconnected
local function disconnectAllInScope(scope)
    local disconnected = 0
    local firstError = nil
    local connection = rawget(scope, "_head")

    while connection ~= false do
        local ok, result = pcall(disconnectScopeMember, connection)
        if not ok then
            if firstError == nil then
                firstError = { value = result }
            end
        elseif result == true then
            disconnected = disconnected + 1
        end

        -- `disconnectEventConnection` unlinks before anything that can raise.
        -- A handle that was somehow linked while already disconnected is
        -- unlinked here, so the sweep always terminates.
        if rawget(connection, "_scope") == scope then
            unlinkFromScope(connection)
        end
        connection = rawget(scope, "_head")
    end

    if firstError ~= nil then
        error(firstError.value, 0)
    end
    return disconnected
end

---Disconnect every scope closed during the dispatch that just returned.
---
---Nobody is left to raise a failure to, so it goes to the host error handler.
function sweepPendingScopes()
    local pending = rawget(state, "pendingScopes")
    local index = 1
    -- Disconnecting never dispatches, so the count cannot grow while sweeping;
    -- it is re-read anyway so the loop stays correct if that ever changes.
    while index <= rawget(state, "pendingScopeCount") do
        local scope = rawget(pending, index)
        rawset(pending, index, false)
        local ok, failure = pcall(disconnectAllInScope, scope)
        if not ok then
            reportListenerError(failure)
        end
        index = index + 1
    end
    rawset(state, "pendingScopeCount", 0)
end

---Disconnect the LifecycleKit `OnShutdown` subscription an addon scope holds,
---if any. Best-effort: the subscription only closes a scope, and closing a
---closed scope is a no-op, so one that cannot be disconnected is harmless.
---@param scope EventKit.Scope
local function releaseLogoutSubscription(scope)
    local subscription = rawget(scope, "_logoutSubscription")
    if type(subscription) ~= "table" then
        return
    end
    rawset(scope, "_logoutSubscription", false)
    local disconnectSubscription = subscription.Disconnect
    if type(disconnectSubscription) == "function" then
        pcall(disconnectSubscription, subscription)
    end
end

---Terminally close `scope`, disconnecting everything it owns.
---
---Inside a dispatch the scope is closed at once but its connections are swept
---when the outermost dispatch returns: `Close` prevents future deliveries and
---never the one in flight. An addon scope also lets go of its LifecycleKit
---shutdown subscription, which has nothing left to do.
---@param scope EventKit.Scope
---@return boolean closed `false` when the scope was already closed.
local function closeScope(scope)
    if rawget(scope, "_closed") == true then
        return false
    end

    -- Terminal before cleanup begins, so nothing reached during the sweep can
    -- add a replacement connection.
    rawset(scope, "_closed", true)
    releaseLogoutSubscription(scope)

    if rawget(state, "dispatchDepth") > 0 then
        if rawget(scope, "_head") ~= false then
            local count = rawget(state, "pendingScopeCount") + 1
            rawset(rawget(state, "pendingScopes"), count, scope)
            rawset(state, "pendingScopeCount", count)
        end
        return true
    end

    disconnectAllInScope(scope)
    return true
end

---Build one open scope. `addonName` is `nil` for a manually owned scope.
---@param addonName string|nil
---@return EventKit.Scope
local function newScope(addonName)
    return setmetatable({
        _addonName = addonName,
        _head = false,
        _tail = false,
        _activeCount = 0,
        _closed = false,
    }, SCOPE_METATABLE)
end

-- Logout coverage -----------------------------------------------------------
--
-- An addon scope must close at logout whenever the framework can observe
-- logout, whatever LifecycleKit revision is paired with EventKit. EventKit
-- observes `PLAYER_LOGOUT` itself, so it always can. The first `ForAddon` for
-- an addon picks the first of these that applies and records it on the scope
-- as `_logoutRoute`:
--
--   1. LifecycleKit lists "eventKit" in `CLOSES_ADDON_SCOPES`: it calls
--      `CloseAddonScopes` at shutdown, after the addon's shutdown callbacks.
--      Nothing is subscribed; `LifecycleKit:ForAddon` is called once so the
--      addon has an instance and its shutdown pass reaches this scope.
--   2. An older LifecycleKit, without that capability: one `OnShutdown`
--      subscription per addon closes the scope among the shutdown callbacks.
--      The handle is kept on the scope, so closing the scope disconnects it.
--   3. No LifecycleKit: one package-level `PLAYER_LOGOUT` one-shot closes
--      every addon scope that neither LifecycleKit route covers.
--
-- Every route closes inside the `PLAYER_LOGOUT` dispatch, so the deferred
-- sweep (see "Dispatch") disconnects after that dispatch completes and a
-- scoped `PLAYER_LOGOUT` listener still runs, whether it was connected before
-- or after the closing one. Only when EventKit cannot connect its own
-- listener is the outcome "none"; it is examined again at the next
-- `ForAddon`. Callbacks resolve their handler through `state` when they run,
-- so a newer revision upgrades them in place.

---Silent lookup of an optional package, through `Registry:Find` (or `Get` on a
---Registry older than revision 7, which also answers `nil` for a missing one).
---@param packageName string
---@param api integer
---@return table|nil implementation
local function findOptionalPackage(packageName, api)
    local find = rawget(Registry, "Find")
    if type(find) ~= "function" then
        find = getPackage
    end
    local implementation = find(Registry, packageName, api)
    if type(implementation) ~= "table" then
        return nil
    end
    return implementation
end

---Whether `LifecycleKit` closes EventKit's addon scopes at shutdown itself.
---
---`CLOSES_ADDON_SCOPES` is a read-only view, so it is read by ordinary
---indexing; a revision without the field closes none.
---@param LifecycleKit table
---@return boolean
local function lifecycleClosesAddonScopes(LifecycleKit)
    local capabilities = rawget(LifecycleKit, "CLOSES_ADDON_SCOPES")
    return type(capabilities) == "table" and capabilities[PACKAGE_NAME] == true
end

---Close an addon scope from a LifecycleKit `OnShutdown` callback (route 2).
---
---When a LifecycleKit that closes EventKit's scopes itself has replaced the
---older one in the meantime, it makes the call after the shutdown callbacks,
---so this one steps aside and keeps that ordering.
---@param addonName string
---@return boolean closed
local function closeOnShutdown(addonName)
    local scope = rawget(rawget(state, "addonScopes"), addonName)
    if scope == nil then
        return false
    end
    -- The subscription is one-shot and has fired; nothing is left to release.
    rawset(scope, "_logoutSubscription", false)
    local LifecycleKit = findOptionalPackage("lifecycleKit", OPTIONAL_LIFECYCLE_KIT_API)
    if LifecycleKit ~= nil and lifecycleClosesAddonScopes(LifecycleKit) then
        return false
    end
    return closeScope(scope)
end

---Close, at `PLAYER_LOGOUT`, every addon scope no LifecycleKit route covers
---(route 3), in addon-name order. The listener runs inside the dispatch, so
---each scope refuses new connections at once and is swept after the dispatch;
---every scope's own `PLAYER_LOGOUT` listeners still receive the event.
local function closeOnLogout()
    rawset(state, "logoutConnection", false)

    local addonScopes = rawget(state, "addonScopes")
    local names = {}
    for addonName in pairs(addonScopes) do
        names[#names + 1] = addonName
    end
    table.sort(names)

    local firstError = nil
    for index = 1, #names do
        local scope = rawget(addonScopes, names[index])
        local route = rawget(scope, "_logoutRoute")
        if route ~= LOGOUT_ROUTE_LIFECYCLE and route ~= LOGOUT_ROUTE_SHUTDOWN_SUBSCRIPTION then
            local ok, closeError = pcall(closeScope, scope)
            if not ok and firstError == nil then
                firstError = { value = closeError }
            end
        end
    end
    if firstError ~= nil then
        error(firstError.value, 0)
    end
end

---Subscribe the addon scope to an older LifecycleKit's shutdown (route 2).
---@param LifecycleKit table
---@param addonName string
---@return table|nil subscription `nil` when LifecycleKit refused
local function subscribeToShutdown(LifecycleKit, addonName)
    local ok, subscription = pcall(function()
        return LifecycleKit:ForAddon(addonName):OnShutdown(function()
            local handler = rawget(state, "closeOnShutdown")
            if type(handler) == "function" then
                handler(addonName)
            end
        end)
    end)
    if not ok or type(subscription) ~= "table" then
        return nil
    end
    return subscription
end

---Make sure EventKit's own `PLAYER_LOGOUT` one-shot is connected (route 3),
---creating it on first need.
---@return boolean covered `false` when the host refused the registration
local function ensureLogoutConnection()
    local existing = rawget(state, "logoutConnection")
    if type(existing) == "table" and rawget(existing, "_connected") == true then
        return true
    end

    local ok, connection = pcall(function()
        local channel = createRegularChannel(LOGOUT_EVENT, "EventKit:ForAddon", 2)
        return connectToChannel(channel, function()
            local handler = rawget(state, "closeOnLogout")
            if type(handler) == "function" then
                handler()
            end
        end, true, false)
    end)
    if not ok then
        return false
    end
    rawset(state, "logoutConnection", connection)
    return true
end

---Decide who closes `scope` at logout, unless that is already decided.
---
---Called by `ForAddon` for every scope it returns, so the common case costs one
---field read.
---@param scope EventKit.Scope an addon scope
local function ensureLogoutRoute(scope)
    local route = rawget(scope, "_logoutRoute")
    if (route ~= false and route ~= LOGOUT_ROUTE_NONE) or rawget(scope, "_closed") == true then
        return
    end

    local LifecycleKit = findOptionalPackage("lifecycleKit", OPTIONAL_LIFECYCLE_KIT_API)
    if LifecycleKit ~= nil then
        if lifecycleClosesAddonScopes(LifecycleKit) then
            -- LifecycleKit closes the scopes of the addons it has an
            -- instance for, so make sure this addon has one. Nothing is
            -- subscribed; a refusal only leaves the addon unknown to it.
            pcall(function()
                LifecycleKit:ForAddon(rawget(scope, "_addonName"))
            end)
            rawset(scope, "_logoutRoute", LOGOUT_ROUTE_LIFECYCLE)
            return
        end
        local subscription = subscribeToShutdown(LifecycleKit, rawget(scope, "_addonName"))
        if subscription ~= nil then
            rawset(scope, "_logoutSubscription", subscription)
            rawset(scope, "_logoutRoute", LOGOUT_ROUTE_SHUTDOWN_SUBSCRIPTION)
            return
        end
    end

    if ensureLogoutConnection() then
        rawset(scope, "_logoutRoute", LOGOUT_ROUTE_EVENT)
        return
    end
    rawset(scope, "_logoutRoute", LOGOUT_ROUTE_NONE)
end

-- Coalescing ------------------------------------------------------------------
--
-- `Coalesce` and `Derive` are the event half of the coalescing family whose
-- scheduler half is SchedulerKit's `Coalesce`, `Debounce` and lanes; the
-- family is documented once, in SchedulerKit's docs/API.md under "Coalescing
-- and lanes". EventKit supplies the subscriptions and SchedulerKit the timing.
--
-- SchedulerKit is optional. It is found through `Registry:Find` when a handle
-- is created. `Coalesce` without it is refused at the caller; `Derive` without
-- it recomputes synchronously on every event, which still works.
--
-- Each handle owns its event connections (not scope-linked themselves) and,
-- with SchedulerKit, one SchedulerKit scope holding its timing handle. The
-- handle itself joins the EventKit scope it was created through, so the scope
-- sweep releases everything in one step. Listener closures resolve behaviour
-- through `state.composites`, so a later compatible revision upgrades them.

---Silent optional lookup of a SchedulerKit revision that has coalescing.
---@return table|nil SchedulerKit
---@return string|nil reason why it is unavailable
local function findSchedulerKit()
    local find = rawget(Registry, "Find")
    if type(find) ~= "function" then
        return nil, "Registry:Find is unavailable"
    end
    local SchedulerKit, reason = find(Registry, "schedulerKit", OPTIONAL_SCHEDULER_API)
    if type(SchedulerKit) ~= "table" then
        return nil, tostring(reason)
    end
    local prototype = rawget(SchedulerKit, "Scope")
    if
        type(rawget(SchedulerKit, "CreateScope")) ~= "function"
        or type(prototype) ~= "table"
        or type(rawget(prototype, "Coalesce")) ~= "function"
        or type(rawget(prototype, "Debounce")) ~= "function"
    then
        return nil, "the loaded SchedulerKit predates coalescing, added in its revision 7"
    end
    return SchedulerKit, nil
end

---Drop a Lua error position prefix, so a SchedulerKit refusal can be raised
---again at EventKit's caller without naming a line inside either package.
---@param message any
---@return string
local function withoutPosition(message)
    local text = tostring(message)
    local stripped = string.gsub(text, "^[^:\n]+:%d+: ", "", 1)
    return stripped
end

---Validate `events` into a fresh array of distinct event names.
---@param events any a string or an array of strings
---@param label string qualified public method name, used in the argument errors
---@param level integer stack level the failures are reported at
---@return string[]
local function readEventList(events, label, level)
    if type(events) == "string" then
        validateEventName(events, label, level + 1)
        return { events }
    end
    if type(events) ~= "table" or type(events[1]) == "nil" then
        error(label .. " events must be an event name or a non-empty array of them", level)
    end

    local list, seen = {}, {}
    for index = 1, #events do
        local eventName = events[index]
        refuseSecret(eventName, label .. " events entry", level + 1)
        if type(eventName) ~= "string" or eventName == "" then
            error(label .. " events must contain only non-empty strings", level)
        end
        if not seen[eventName] then
            seen[eventName] = true
            list[#list + 1] = eventName
        end
    end
    if #list > MAXIMUM_COMPOSITE_EVENTS then
        error(label .. " accepts at most " .. MAXIMUM_COMPOSITE_EVENTS .. " distinct events", level)
    end
    return list
end

---Reject an options value that is not a table or names an unknown field.
---@param options any
---@param allowed table<string, boolean>
---@param label string qualified public method name, used in the argument errors
---@param level integer stack level the failures are reported at
local function validateOptionTable(options, allowed, label, level)
    if type(options) == "nil" then
        return
    end
    if type(options) ~= "table" then
        error(label .. " options must be a table", level)
    end
    local unknown = nil
    for key in pairs(options) do
        if allowed[key] ~= true then
            local display = tostring(key)
            if unknown == nil or display < unknown then
                unknown = display
            end
        end
    end
    if unknown ~= nil then
        error(label .. ' options contains unknown field "' .. unknown .. '"', level)
    end
end

---@param value any
---@param label string argument description, used in the argument error
---@param level integer stack level the failure is reported at
local function validateDelay(value, label, level)
    refuseSecret(value, label, level + 1)
    if type(value) ~= "number" or value ~= value or value == math.huge or value < 0 then
        error(label .. " must be a finite number greater than or equal to zero", level)
    end
end

---Read the optional `units` option into the normalized unit set.
---@param units any
---@param label string qualified public method name, used in the argument errors
---@param level integer stack level the failures are reported at
---@return string[]|nil units
---@return string|nil key
local function readUnits(units, label, level)
    if type(units) == "nil" then
        return nil, nil
    end
    if type(units) ~= "table" then
        error(label .. " units must be an array of one or two unit tokens", level)
    end
    return normalizeUnits(label, level + 1, unpackValues(units, 1, #units))
end

---Connect `listener` to every event of `list`, owned by `handle`.
---
---Called under `pcall` so a refused registration can release what was
---already connected; `level` already counts the protected call.
---@param handle table
---@param list string[]
---@param units string[]|nil
---@param key string|nil
---@param listener EventKit.Listener
---@param label string qualified public method name, used in the argument errors
---@param level integer stack level the failures are reported at
local function connectHandleEvents(handle, list, units, key, listener, label, level)
    local connections = rawget(handle, "_connections")
    for index = 1, #list do
        local channel
        if units ~= nil then
            -- `readUnits` returns a key whenever it returns units.
            local unitKey = key --[[@as string]]
            channel = createUnitChannel(list[index], units, unitKey, label, level + 1)
        else
            channel = createRegularChannel(list[index], label, level + 1)
        end
        connections[#connections + 1] = connectToChannel(channel, listener, false, false)
    end
end

---Release everything a Coalesce or Derive handle owns. Terminal, idempotent,
---and best effort: the first failure is raised once everything was tried.
---@param handle table
---@return boolean closed `false` when it was already closed.
local function closeCompositeHandle(handle)
    if rawget(handle, "_closed") == true then
        return false
    end
    rawset(handle, "_closed", true)
    unlinkFromScope(handle)

    local firstError = nil
    local connections = rawget(handle, "_connections")
    for index = 1, #connections do
        local ok, value = pcall(disconnectEventConnection, connections[index])
        if not ok and firstError == nil then
            firstError = { value = value }
        end
        connections[index] = nil
    end

    -- Closing the SchedulerKit scope closes the timing handle in it. The
    -- closed timing handle is kept, so a closed Coalesce handle still answers
    -- `IsPending` and `GetStats`.
    local schedulerScope = rawget(handle, "_schedulerScope")
    rawset(handle, "_schedulerScope", false)
    if schedulerScope ~= false then
        local ok, value = pcall(schedulerScope.Close, schedulerScope)
        if not ok and firstError == nil then
            firstError = { value = value }
        end
    end
    -- Disconnect the `OnChange` listeners rather than only dropping the
    -- signal, so the connections their owners hold stop reporting connected.
    local signal = rawget(handle, "_signal")
    rawset(handle, "_signal", false)
    if signal ~= false then
        local ok, value = pcall(signal.DisconnectAll, signal)
        if not ok and firstError == nil then
            firstError = { value = value }
        end
    end

    if firstError ~= nil then
        error(firstError.value, 0)
    end
    return true
end

---Build the one listener a handle connects to each of its events.
---@param handle table
---@return EventKit.Listener
local function newCompositeListener(handle)
    return function(eventName, first)
        return rawget(rawget(state, "composites"), "onEvent")(handle, eventName, first)
    end
end

---Finish building a handle: connect its events, then join `scope`. Releases
---the handle and raises when a registration is refused or `scope` closed
---while the handle was being built.
---@param handle table
---@param scope EventKit.Scope|false
---@param list string[]
---@param units string[]|nil
---@param key string|nil
---@param label string qualified public method name, used in the argument errors
---@param level integer stack level the failures are reported at
local function attachCompositeHandle(handle, scope, list, units, key, label, level)
    -- The scope was open when the public method checked it, but `Derive` ran
    -- the caller's `compute` since then. A compute that closed the scope must
    -- not leave a live handle linked into it, where no sweep would reach it.
    if scope ~= false and rawget(scope, "_closed") == true then
        pcall(closeCompositeHandle, handle)
        error(label .. " cannot connect in a closed scope", level)
    end

    local listener = newCompositeListener(handle)
    -- Levels inside the protected call: connectHandleEvents, pcall, this
    -- function, and then `level` more to the caller.
    local ok, failure =
        pcall(connectHandleEvents, handle, list, units, key, listener, label, level + 2)
    if not ok then
        pcall(closeCompositeHandle, handle)
        error(failure, 0)
    end
    if scope ~= false then
        linkToScope(scope, handle)
    end
end

---Record one event on a Coalesce handle.
---@param handle EventKit.CoalesceHandle
---@param eventName string
---@param first any the event's first payload argument
local function recordCoalescedEvent(handle, eventName, first)
    local key = first
    -- A secret payload cannot be compared or used as a key, so it coalesces
    -- under the event name, like a missing one.
    if rawget(handle, "_byEvent") == true or type(key) == "nil" or isSecret(key) or key ~= key then
        key = eventName
    end
    rawget(handle, "_timing")(key)
end

---Recompute a Derive handle's value and announce a change.
---@param handle EventKit.DeriveHandle
local function recomputeDerived(handle)
    if rawget(handle, "_closed") == true then
        return
    end
    local ok, value = pcall(rawget(handle, "_compute"))
    if not ok then
        reportListenerError(value)
        return
    end

    local previous = rawget(handle, "_value")
    local changed
    local equals = rawget(handle, "_equals")
    if equals ~= false then
        local equalsOk, same = pcall(equals, previous, value)
        if not equalsOk then
            reportListenerError(same)
            changed = true
        else
            changed = not same
        end
    else
        -- A secret on either side cannot be compared, so it counts as a change.
        changed = isSecret(previous) or isSecret(value) or previous ~= value
    end
    if not changed then
        return
    end

    rawset(handle, "_value", value)
    local signal = rawget(handle, "_signal")
    if signal ~= false then
        signal:Fire(value, previous)
    end
end

---Mark a Derive handle's value stale: debounced through SchedulerKit when it
---was present at creation, otherwise recomputed at once.
---@param handle EventKit.DeriveHandle
local function invalidateDerived(handle)
    if rawget(handle, "_closed") == true then
        return
    end
    local timing = rawget(handle, "_timing")
    -- A timing handle whose SchedulerKit scope was closed from outside
    -- refuses the call; fall back to recomputing now rather than going stale.
    if timing ~= false and timing() == true then
        return
    end
    recomputeDerived(handle)
end

---Route an event to the handle kind that listens for it.
---@param handle table
---@param eventName string
---@param first any
local function onCompositeEvent(handle, eventName, first)
    if rawget(handle, "_closed") == true then
        return
    end
    if rawget(handle, "_kind") == "coalesce" then
        recordCoalescedEvent(handle, eventName, first)
        return
    end
    invalidateDerived(handle)
end

---Build a Coalesce handle.
---@param scope EventKit.Scope|false owning scope, or `false` for none
---@param label string qualified public method name, used in the argument errors
---@param level integer stack level the failures are reported at
---@return EventKit.CoalesceHandle
local function createCoalesceHandle(scope, label, level, events, interval, callback, options)
    local list = readEventList(events, label, level + 1)
    validateDelay(interval, label .. " intervalSeconds", level + 1)
    validateCallback(callback, label, level + 1)
    validateOptionTable(
        options,
        { byEvent = true, units = true, maxKeys = true, lane = true },
        label,
        level + 1
    )

    local byEvent, units, key, timingOptions = false, nil, nil, nil
    if type(options) ~= "nil" then
        local byEventOption = rawget(options, "byEvent")
        refuseSecret(byEventOption, label .. " byEvent", level + 1)
        if type(byEventOption) ~= "nil" and type(byEventOption) ~= "boolean" then
            error(label .. " byEvent must be a boolean", level)
        end
        byEvent = byEventOption == true
        units, key = readUnits(rawget(options, "units"), label, level + 1)
        timingOptions = { maxKeys = rawget(options, "maxKeys"), lane = rawget(options, "lane") }
    end

    local SchedulerKit, reason = findSchedulerKit()
    if SchedulerKit == nil then
        error(
            label .. " requires SchedulerKit API 1, which is not available (" .. reason .. ")",
            level
        )
    end

    local schedulerScope = SchedulerKit:CreateScope()
    local ok, timing =
        pcall(schedulerScope.Coalesce, schedulerScope, callback, interval, timingOptions)
    if not ok then
        pcall(schedulerScope.Close, schedulerScope)
        error(label .. ": " .. withoutPosition(timing), level)
    end

    local handle = setmetatable({
        _kind = "coalesce",
        _closed = false,
        _byEvent = byEvent,
        _connections = {},
        _schedulerScope = schedulerScope,
        _timing = timing,
        _signal = false,
        _scope = false,
        _scopePrevious = false,
        _scopeNext = false,
    }, COALESCE_METATABLE)
    attachCompositeHandle(handle, scope, list, units, key, label, level + 1)
    return handle
end

---Build a Derive handle.
---@param scope EventKit.Scope|false owning scope, or `false` for none
---@param label string qualified public method name, used in the argument errors
---@param level integer stack level the failures are reported at
---@return EventKit.DeriveHandle
local function createDeriveHandle(scope, label, level, events, compute, options)
    local list = readEventList(events, label, level + 1)
    if type(compute) ~= "function" then
        error(label .. " compute must be a function", level)
    end
    validateOptionTable(
        options,
        { delaySeconds = true, equals = true, units = true },
        label,
        level + 1
    )

    local delay, equals, units, key = 0, false, nil, nil
    if type(options) ~= "nil" then
        if type(rawget(options, "delaySeconds")) ~= "nil" then
            delay = rawget(options, "delaySeconds")
            validateDelay(delay, label .. " delaySeconds", level + 1)
        end
        if type(rawget(options, "equals")) ~= "nil" then
            equals = rawget(options, "equals")
            if type(equals) ~= "function" then
                error(label .. " equals must be a function", level)
            end
        end
        units, key = readUnits(rawget(options, "units"), label, level + 1)
    end

    -- The first value is computed before anything is registered, so a
    -- compute that raises leaves nothing behind.
    local initial = compute()

    local handle = setmetatable({
        _kind = "derive",
        _closed = false,
        _compute = compute,
        _equals = equals,
        _value = initial,
        _connections = {},
        _schedulerScope = false,
        _timing = false,
        _signal = false,
        _scope = false,
        _scopePrevious = false,
        _scopeNext = false,
    }, DERIVE_METATABLE)

    local SchedulerKit = findSchedulerKit()
    if SchedulerKit ~= nil then
        local schedulerScope = SchedulerKit:CreateScope()
        rawset(handle, "_schedulerScope", schedulerScope)
        rawset(
            handle,
            "_timing",
            schedulerScope:Debounce(function()
                return rawget(rawget(state, "composites"), "recompute")(handle)
            end, delay)
        )
    end

    attachCompositeHandle(handle, scope, list, units, key, label, level + 1)
    return handle
end

---@param handle any receiver the public method was called on
---@param metatable table
---@param label string qualified public method name, used in the argument error
---@param noun string what the receiver should have been
local function validateCompositeReceiver(handle, metatable, label, noun)
    if type(handle) ~= "table" or getmetatable(handle) ~= metatable then
        error(label .. " must be called on an EventKit " .. noun, 3)
    end
end

---Deliver what the handle collected now instead of at the end of the interval.
---@param self EventKit.CoalesceHandle
---@return boolean delivered `false` when nothing was collected or it is closed.
---@return string? reason `"deferred"` or `"dropped"` when a SchedulerKit lane did not take it
local function coalesceFlush(self)
    validateCompositeReceiver(
        self,
        COALESCE_METATABLE,
        "EventKit.CoalesceHandle:Flush",
        "coalesce handle"
    )
    return rawget(self, "_timing"):Flush()
end

---Whether events were collected and wait for delivery.
---@param self EventKit.CoalesceHandle
---@return boolean pending
local function coalesceIsPending(self)
    validateCompositeReceiver(
        self,
        COALESCE_METATABLE,
        "EventKit.CoalesceHandle:IsPending",
        "coalesce handle"
    )
    return rawget(self, "_timing"):IsPending()
end

---Return SchedulerKit's counters for this handle, in a reused table.
---@param self EventKit.CoalesceHandle
---@return table<string, integer> stats
local function coalesceGetStats(self)
    validateCompositeReceiver(
        self,
        COALESCE_METATABLE,
        "EventKit.CoalesceHandle:GetStats",
        "coalesce handle"
    )
    return rawget(self, "_timing"):GetStats()
end

---Release the handle: its events, its pending delivery, its scope membership.
---@param self EventKit.CoalesceHandle
---@return boolean closed `false` when it was already closed.
local function coalesceClose(self)
    validateCompositeReceiver(
        self,
        COALESCE_METATABLE,
        "EventKit.CoalesceHandle:Close",
        "coalesce handle"
    )
    return closeCompositeHandle(self)
end

---Whether the handle is closed.
---@param self EventKit.CoalesceHandle
---@return boolean closed
local function coalesceIsClosed(self)
    validateCompositeReceiver(
        self,
        COALESCE_METATABLE,
        "EventKit.CoalesceHandle:IsClosed",
        "coalesce handle"
    )
    return rawget(self, "_closed") == true
end

---Return the cached value.
---@param self EventKit.DeriveHandle
---@return any value
local function deriveGet(self)
    validateCompositeReceiver(self, DERIVE_METATABLE, "EventKit.DeriveHandle:Get", "derived value")
    return rawget(self, "_value")
end

---Subscribe to changes of the value. Listeners are isolated like event
---listeners: one that raises is reported and the rest still run.
---@param self EventKit.DeriveHandle
---@param callback fun(value: any, previous: any)
---@return SignalKit.Connection connection
local function deriveOnChange(self, callback)
    validateCompositeReceiver(
        self,
        DERIVE_METATABLE,
        "EventKit.DeriveHandle:OnChange",
        "derived value"
    )
    validateCallback(callback, "EventKit.DeriveHandle:OnChange", 3)
    if rawget(self, "_closed") == true then
        error("EventKit.DeriveHandle:OnChange cannot subscribe to a closed derived value", 2)
    end
    local signal = rawget(self, "_signal")
    if signal == false then
        signal = SignalKit:New()
        rawset(self, "_signal", signal)
    end
    local connection = signal:Connect(function(...)
        return rawget(state, "isolate")(callback, ...)
    end)
    return connection
end

---Mark the value stale, exactly as one of its events would.
---@param self EventKit.DeriveHandle
local function deriveInvalidate(self)
    validateCompositeReceiver(
        self,
        DERIVE_METATABLE,
        "EventKit.DeriveHandle:Invalidate",
        "derived value"
    )
    invalidateDerived(self)
end

---Release the handle: its events, its pending recompute, its listeners.
---@param self EventKit.DeriveHandle
---@return boolean closed `false` when it was already closed.
local function deriveClose(self)
    validateCompositeReceiver(
        self,
        DERIVE_METATABLE,
        "EventKit.DeriveHandle:Close",
        "derived value"
    )
    return closeCompositeHandle(self)
end

---Whether the handle is closed.
---@param self EventKit.DeriveHandle
---@return boolean closed
local function deriveIsClosed(self)
    validateCompositeReceiver(
        self,
        DERIVE_METATABLE,
        "EventKit.DeriveHandle:IsClosed",
        "derived value"
    )
    return rawget(self, "_closed") == true
end

-- Public API ----------------------------------------------------------------

---Subscribe to every future occurrence of `eventName`.
---@param _ EventKit
---@param eventName string
---@param callback EventKit.Listener
---@return EventKit.Connection connection
local function connectEvent(_, eventName, callback)
    local connection = subscribeRegular(false, "EventKit:Connect", 3, eventName, callback, false)
    return connection
end

---Subscribe to at most one future occurrence of `eventName`.
---@param _ EventKit
---@param eventName string
---@param callback EventKit.Listener
---@return EventKit.Connection connection
local function onceEvent(_, eventName, callback)
    local connection = subscribeRegular(false, "EventKit:Once", 3, eventName, callback, true)
    return connection
end

---Subscribe to `eventName` filtered to one or two unit tokens.
---@param _ EventKit
---@param eventName string
---@param callback EventKit.Listener
---@param ... string one or two unit tokens; `Frame:RegisterUnitEvent` has two slots
---@return EventKit.Connection connection
local function connectUnitEvent(_, eventName, callback, ...)
    local connection =
        subscribeUnit(false, "EventKit:ConnectUnit", 3, eventName, callback, false, ...)
    return connection
end

---Subscribe once to `eventName` filtered to one or two unit tokens.
---@param _ EventKit
---@param eventName string
---@param callback EventKit.Listener
---@param ... string one or two unit tokens; `Frame:RegisterUnitEvent` has two slots
---@return EventKit.Connection connection
local function onceUnitEvent(_, eventName, callback, ...)
    local connection = subscribeUnit(false, "EventKit:OnceUnit", 3, eventName, callback, true, ...)
    return connection
end

---Subscribe to one combat-log sub-event, or to every one with `"*"`. The
---callback receives every return of `CombatLogGetCurrentEventInfo()`, read
---once per event for all combat-log listeners. See docs/API.md,
---"EventKit:ConnectCombatLog".
---@param _ EventKit
---@param subEvent string a client sub-event name such as `"SPELL_DAMAGE"`, or `"*"`
---@param callback EventKit.CombatLogListener
---@return EventKit.Connection connection
local function connectCombatLog(_, subEvent, callback)
    local connection = subscribeCombatLog(false, "EventKit:ConnectCombatLog", 3, subEvent, callback)
    return connection
end

---Coalesce `events` into at most one `callback(set)` per interval. Requires
---SchedulerKit; see docs/API.md, "Coalescing events".
---@param _ EventKit
---@param events string|string[]
---@param intervalSeconds number Finite seconds greater than or equal to zero.
---@param callback fun(set: table<any, any>)
---@param options EventKit.CoalesceOptions?
---@return EventKit.CoalesceHandle handle
local function coalesceEvents(_, events, intervalSeconds, callback, options)
    local handle = createCoalesceHandle(
        false,
        "EventKit:Coalesce",
        3,
        events,
        intervalSeconds,
        callback,
        options
    )
    return handle
end

---Derive a value from `compute`, recomputed when any of `events` fires.
---@param _ EventKit
---@param events string|string[]
---@param compute fun(): any
---@param options EventKit.DeriveOptions?
---@return EventKit.DeriveHandle handle
local function deriveValue(_, events, compute, options)
    local handle = createDeriveHandle(false, "EventKit:Derive", 3, events, compute, options)
    return handle
end

---Create a manually owned connection scope, closed only by its owner.
---@return EventKit.Scope scope
local function createScope()
    return newScope(nil)
end

---Return the canonical connection scope for an addon, creating it on demand.
---
---The scope is closed at logout through `EventKit:CloseAddonScopes(addonName)`:
---by LifecycleKit when it is loaded, otherwise by EventKit's own
---`PLAYER_LOGOUT` listener. See "Logout coverage" above and docs/API.md,
---"At logout".
---@param _ EventKit
---@param addonName string addon folder name
---@return EventKit.Scope scope
local function forAddon(_, addonName)
    validateNonEmptyString(addonName, "EventKit:ForAddon addonName", 3)

    local addonScopes = rawget(state, "addonScopes")
    local scope = rawget(addonScopes, addonName)
    if scope == nil then
        scope = newScope(addonName)
        rawset(scope, "_logoutRoute", false)
        rawset(scope, "_logoutSubscription", false)
        rawset(addonScopes, addonName, scope)
    end
    ensureLogoutRoute(scope)
    return scope
end

---Close the canonical scope of an addon, disconnecting everything it owns.
---
---Closing is terminal, exactly like addon shutdown: the closed scope stays the
---canonical scope, so a later `ForAddon(addonName)` returns it and refuses new
---connections. An addon that never asked for a scope has nothing to close:
---nothing is recorded, so the addon-scope map grows only with `ForAddon`
---calls, as HookKit, CommandKit and CommKit do.
---@param self EventKit
---@param addonName string addon folder name
---@return boolean closed `false` when the addon has no scope or it was already closed.
local function closeAddonScopes(self, addonName)
    -- The type test comes first: a dot call can hand a secret in as `self`.
    if type(self) ~= "table" or self ~= EventKit then
        error(
            "EventKit:CloseAddonScopes must be called on the EventKit facade; "
                .. "use EventKit:CloseAddonScopes(addonName)",
            2
        )
    end
    validateNonEmptyString(addonName, "EventKit:CloseAddonScopes addonName", 3)

    local scope = rawget(rawget(state, "addonScopes"), addonName)
    if scope == nil then
        return false
    end
    return closeScope(scope)
end

-- Limits --------------------------------------------------------------------

-- Every limit name maps to its ceiling. A ceiling guards a resource the client
-- never gives back, so the limit has no `UNBOUNDED` value.
local LIMIT_CEILINGS = {
    maxUnitFrames = MAX_UNIT_FRAMES_CEILING,
}

-- Why a limit refuses `EventKit.UNBOUNDED`, quoted in the refusal.
local UNBOUNDED_REFUSALS = {
    maxUnitFrames = "the client never frees a Frame",
}

---Reject a `SetLimits` table before anything in it is applied.
---@param limits any
---@param level integer stack level the failure is reported at
local function validateLimitUpdate(limits, level)
    if type(limits) ~= "table" then
        error("EventKit:SetLimits limits must be a table", level)
    end
    local key = next(limits)
    while type(key) ~= "nil" do
        if type(key) ~= "string" or LIMIT_CEILINGS[key] == nil then
            error(
                "EventKit:SetLimits limits." .. tostring(key) .. " is not a recognised limit",
                level
            )
        end
        local value = rawget(limits, key)
        refuseSecret(value, "EventKit:SetLimits limits." .. key, level + 1)
        if value == UNBOUNDED then
            error(
                "EventKit:SetLimits limits."
                    .. key
                    .. " cannot be EventKit.UNBOUNDED: "
                    .. UNBOUNDED_REFUSALS[key],
                level
            )
        end
        local ceiling = LIMIT_CEILINGS[key]
        -- `nan` fails every comparison and `math.huge % 1` is `nan`, so the
        -- range test below refuses both infinities and `nan`.
        if
            type(value) ~= "number"
            or not (value % 1 == 0)
            or not (value >= 1)
            or not (value <= ceiling)
        then
            error(
                "EventKit:SetLimits limits." .. key .. " must be an integer from 1 to " .. ceiling,
                level
            )
        end
        key = next(limits, key)
    end
end

---Change any subset of the shared limits. Affects every consumer in the session.
---
---The whole table is validated first, so nothing changes when one value is
---refused. Lowering a limit below current usage evicts nothing; further
---creation is refused until usage drops below it.
---@param self EventKit
---@param limits EventKit.Limits
local function setLimits(self, limits)
    if type(self) ~= "table" or self ~= EventKit then
        error(
            "EventKit:SetLimits must be called on the EventKit facade; "
                .. "use EventKit:SetLimits(limits)",
            2
        )
    end
    validateLimitUpdate(limits, 3)
    local key = next(LIMIT_CEILINGS)
    while key ~= nil do
        local value = rawget(limits, key)
        if type(value) ~= "nil" then
            rawset(sharedLimits, key, value)
        end
        key = next(LIMIT_CEILINGS, key)
    end
end

---Return a fresh copy of the shared limits. Allocates one table per call.
---@param self EventKit
---@return EventKit.Limits
local function getLimits(self)
    if type(self) ~= "table" or self ~= EventKit then
        error(
            "EventKit:GetLimits must be called on the EventKit facade; "
                .. "use EventKit:GetLimits()",
            2
        )
    end
    return {
        maxUnitFrames = rawget(sharedLimits, "maxUnitFrames"),
    }
end

-- Scope methods -------------------------------------------------------------

---Subscribe to every future occurrence of `eventName` inside this scope.
---@param self EventKit.Scope
---@param eventName string
---@param callback EventKit.Listener
---@return EventKit.Connection connection
local function scopeConnect(self, eventName, callback)
    validateScope(self, "EventKit.Scope:Connect", 3)
    ensureScopeOpen(self, "EventKit.Scope:Connect", 3)
    local connection =
        subscribeRegular(self, "EventKit.Scope:Connect", 3, eventName, callback, false)
    return connection
end

---Subscribe to at most one future occurrence of `eventName` inside this scope.
---@param self EventKit.Scope
---@param eventName string
---@param callback EventKit.Listener
---@return EventKit.Connection connection
local function scopeOnce(self, eventName, callback)
    validateScope(self, "EventKit.Scope:Once", 3)
    ensureScopeOpen(self, "EventKit.Scope:Once", 3)
    local connection = subscribeRegular(self, "EventKit.Scope:Once", 3, eventName, callback, true)
    return connection
end

---Subscribe to a unit-filtered event inside this scope.
---@param self EventKit.Scope
---@param eventName string
---@param callback EventKit.Listener
---@param ... string one or two unit tokens; `Frame:RegisterUnitEvent` has two slots
---@return EventKit.Connection connection
local function scopeConnectUnit(self, eventName, callback, ...)
    validateScope(self, "EventKit.Scope:ConnectUnit", 3)
    ensureScopeOpen(self, "EventKit.Scope:ConnectUnit", 3)
    local connection =
        subscribeUnit(self, "EventKit.Scope:ConnectUnit", 3, eventName, callback, false, ...)
    return connection
end

---Subscribe once to a unit-filtered event inside this scope.
---@param self EventKit.Scope
---@param eventName string
---@param callback EventKit.Listener
---@param ... string one or two unit tokens; `Frame:RegisterUnitEvent` has two slots
---@return EventKit.Connection connection
local function scopeOnceUnit(self, eventName, callback, ...)
    validateScope(self, "EventKit.Scope:OnceUnit", 3)
    ensureScopeOpen(self, "EventKit.Scope:OnceUnit", 3)
    local connection =
        subscribeUnit(self, "EventKit.Scope:OnceUnit", 3, eventName, callback, true, ...)
    return connection
end

---Subscribe to a combat-log sub-event inside this scope.
---@param self EventKit.Scope
---@param subEvent string a client sub-event name such as `"SPELL_DAMAGE"`, or `"*"`
---@param callback EventKit.CombatLogListener
---@return EventKit.Connection connection
local function scopeConnectCombatLog(self, subEvent, callback)
    validateScope(self, "EventKit.Scope:ConnectCombatLog", 3)
    ensureScopeOpen(self, "EventKit.Scope:ConnectCombatLog", 3)
    local connection =
        subscribeCombatLog(self, "EventKit.Scope:ConnectCombatLog", 3, subEvent, callback)
    return connection
end

---Coalesce `events` inside this scope.
---@param self EventKit.Scope
---@param events string|string[]
---@param intervalSeconds number Finite seconds greater than or equal to zero.
---@param callback fun(set: table<any, any>)
---@param options EventKit.CoalesceOptions?
---@return EventKit.CoalesceHandle handle
local function scopeCoalesce(self, events, intervalSeconds, callback, options)
    validateScope(self, "EventKit.Scope:Coalesce", 3)
    ensureScopeOpen(self, "EventKit.Scope:Coalesce", 3)
    local handle = createCoalesceHandle(
        self,
        "EventKit.Scope:Coalesce",
        3,
        events,
        intervalSeconds,
        callback,
        options
    )
    return handle
end

---Derive a value inside this scope.
---@param self EventKit.Scope
---@param events string|string[]
---@param compute fun(): any
---@param options EventKit.DeriveOptions?
---@return EventKit.DeriveHandle handle
local function scopeDerive(self, events, compute, options)
    validateScope(self, "EventKit.Scope:Derive", 3)
    ensureScopeOpen(self, "EventKit.Scope:Derive", 3)
    local handle = createDeriveHandle(self, "EventKit.Scope:Derive", 3, events, compute, options)
    return handle
end

---Disconnect every live connection while keeping the scope reusable.
---@param self EventKit.Scope
---@return integer disconnected
local function scopeDisconnectAll(self)
    validateScope(self, "EventKit.Scope:DisconnectAll", 3)
    return disconnectAllInScope(self)
end

---Terminally close the scope after best-effort disconnection.
---@param self EventKit.Scope
---@return boolean closed `false` when the scope was already closed.
local function scopeClose(self)
    validateScope(self, "EventKit.Scope:Close", 3)
    return closeScope(self)
end

---Return whether the scope is terminally closed.
---@param self EventKit.Scope
---@return boolean closed
local function scopeIsClosed(self)
    validateScope(self, "EventKit.Scope:IsClosed", 3)
    return rawget(self, "_closed") == true
end

---Return the owning addon name, or `nil` for a manual scope.
---@param self EventKit.Scope
---@return string? addonName
local function scopeGetAddonName(self)
    validateScope(self, "EventKit.Scope:GetAddonName", 3)
    return rawget(self, "_addonName")
end

---Return the number of live connections owned by this scope.
---@param self EventKit.Scope
---@return integer activeCount
local function scopeGetActiveCount(self)
    validateScope(self, "EventKit.Scope:GetActiveCount", 3)
    return rawget(self, "_activeCount")
end

-- Commit --------------------------------------------------------------------
--
-- Existing connection handles and frame callbacks resolve behavior through
-- stable shared tables. Replacing these methods therefore upgrades compatible
-- embedded revisions in place without replacing package or connection identity.

rawset(Connection, "Disconnect", disconnect)
rawset(Connection, "IsConnected", isConnected)

rawset(Scope, "Connect", scopeConnect)
rawset(Scope, "Once", scopeOnce)
rawset(Scope, "ConnectUnit", scopeConnectUnit)
rawset(Scope, "OnceUnit", scopeOnceUnit)
rawset(Scope, "ConnectCombatLog", scopeConnectCombatLog)
rawset(Scope, "DisconnectAll", scopeDisconnectAll)
rawset(Scope, "Close", scopeClose)
rawset(Scope, "IsClosed", scopeIsClosed)
rawset(Scope, "GetAddonName", scopeGetAddonName)
rawset(Scope, "GetActiveCount", scopeGetActiveCount)
rawset(Scope, "Coalesce", scopeCoalesce)
rawset(Scope, "Derive", scopeDerive)

local COALESCE_PROTOTYPE = rawget(COMPOSITE_PROTOTYPES, "coalesce")
rawset(COALESCE_PROTOTYPE, "Flush", coalesceFlush)
rawset(COALESCE_PROTOTYPE, "IsPending", coalesceIsPending)
rawset(COALESCE_PROTOTYPE, "GetStats", coalesceGetStats)
rawset(COALESCE_PROTOTYPE, "Close", coalesceClose)
rawset(COALESCE_PROTOTYPE, "IsClosed", coalesceIsClosed)

local DERIVE_PROTOTYPE = rawget(COMPOSITE_PROTOTYPES, "derive")
rawset(DERIVE_PROTOTYPE, "Get", deriveGet)
rawset(DERIVE_PROTOTYPE, "OnChange", deriveOnChange)
rawset(DERIVE_PROTOTYPE, "Invalidate", deriveInvalidate)
rawset(DERIVE_PROTOTYPE, "Close", deriveClose)
rawset(DERIVE_PROTOTYPE, "IsClosed", deriveIsClosed)

rawset(EventKit, "API", API_GENERATION)
rawset(EventKit, "REVISION", IMPLEMENTATION_REVISION)
rawset(EventKit, "Connect", connectEvent)
rawset(EventKit, "Once", onceEvent)
rawset(EventKit, "ConnectUnit", connectUnitEvent)
rawset(EventKit, "OnceUnit", onceUnitEvent)
rawset(EventKit, "ConnectCombatLog", connectCombatLog)
rawset(EventKit, "CreateScope", createScope)
rawset(EventKit, "ForAddon", forAddon)
rawset(EventKit, "CloseAddonScopes", closeAddonScopes)
rawset(EventKit, "Coalesce", coalesceEvents)
rawset(EventKit, "Derive", deriveValue)
rawset(EventKit, "UNBOUNDED", UNBOUNDED)
rawset(EventKit, "SetLimits", setLimits)
rawset(EventKit, "GetLimits", getLimits)

rawset(state, "dispatchRegular", dispatchRegular)
rawset(state, "dispatchUnit", dispatchUnit)
rawset(state, "isolate", isolate)
rawset(state, "dispatchCombatLog", dispatchCombatLog)
rawset(state, "closeOnLogout", closeOnLogout)
rawset(state, "closeOnShutdown", closeOnShutdown)

local composites = rawget(state, "composites")
rawset(composites, "onEvent", onCompositeEvent)
rawset(composites, "close", closeCompositeHandle)
rawset(composites, "recompute", recomputeDerived)

-- Frames created by implementation revision 1 resolve dispatch through these
-- reserved facade fields. Keep them pointing at the current dispatchers so an
-- in-place upgrade over revision 1 keeps those Frames delivering.
rawset(EventKit, "_DispatchRegular", dispatchRegular)
rawset(EventKit, "_DispatchUnit", dispatchUnit)

if not validatePublicSurface(EventKit) or not validateCurrentState(EventKit) then
    error("MoltenCodes EventKit package state is corrupted or incomplete", 2)
end

-- Addon scopes an older revision created have no logout route yet. They are
-- given one now, in addon-name order, exactly as a first `ForAddon` would;
-- scopes whose route a revision 11+ copy already decided keep it, with any
-- subscription or connection it made.
local function routeInheritedAddonScopes()
    local addonScopes = rawget(state, "addonScopes")
    local names = {}
    for addonName, scope in pairs(addonScopes) do
        if type(scope) == "table" and rawget(scope, "_logoutRoute") == nil then
            names[#names + 1] = addonName
        end
    end
    table.sort(names)
    for index = 1, #names do
        local scope = rawget(addonScopes, names[index])
        rawset(scope, "_logoutRoute", false)
        rawset(scope, "_logoutSubscription", false)
        ensureLogoutRoute(scope)
    end
end

if type(previousRevision) ~= "nil" and previousRevision < IMPLEMENTATION_REVISION then
    routeInheritedAddonScopes()
end

return EventKit
