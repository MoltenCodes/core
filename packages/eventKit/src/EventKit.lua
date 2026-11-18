-- MoltenCodes EventKit
--
-- Lazy World of Warcraft event subscriptions with SignalKit's dispatch
-- semantics: listeners run in connection order, a disconnect takes effect at
-- once and a connection made during a dispatch waits for the next. EventKit
-- keeps each event's listeners in an array of its own that applies those
-- rules, so a connection is one handle and a delivery one isolated call
-- (docs/INTERNALS.md). The core needs no SignalKit: only the Coalescing
-- part's `Derive` does, for its change listeners. Regular events share one
-- Frame.
--
-- EventKit is multi-tenant: one shared instance serves every addon in a WoW
-- session. Listeners are therefore isolated from each other at dispatch, so one
-- addon's failing handler cannot stop delivery to the rest.
--
-- Owner scopes group connections so one call tears down everything an owner
-- subscribed to. They mirror TimerKit's scope model: `CreateScope` for manual
-- ownership, `ForAddon` for the canonical per-addon scope. EventKit sits below
-- LifecycleKit, so addon scopes are closed through `CloseAddonScopes`: by a
-- LifecycleKit that lists EventKit in `CLOSES_ADDON_SCOPES`, or, without one,
-- from EventKit's own `PLAYER_LOGOUT` connection, after that dispatch
-- completes.
--
-- Three features are parts (docs/decisions/0001-kit-core-and-parts.md), each
-- a file of its own under `parts/`, loaded after this core only by an addon
-- that uses it; without its part a member raises at the caller with the file
-- to embed (docs/API.md, "Parts"):
--
--   * Units (`ConnectUnit`, `OnceUnit`): unit-filtered registrations on a
--     bounded set of Frames, one per unit-token set.
--   * CombatLog (`ConnectCombatLog`): the combat log read once per event and
--     routed by sub-event. `IsCombatLogAvailable` stays here, because it
--     answers for the client: Retail 12 gives addon code no reader.
--   * Coalescing (`Coalesce`, `Derive`), timed by TimerKit.
--
-- The core keeps the state the parts fill (unit groups and Frames, the
-- combat-log router), so an upgraded part takes it over, and calls a part only
-- through the `state.dispatch` and `state.composites` entries the part fills.
--
-- Event names a subscribing call receives are checked with the client's
-- `C_EventUtils.IsEventValid`, probed once when this copy loads, so an unknown
-- name is refused at the caller's line before anything is registered. Clients
-- without the function leave the verdict to `RegisterEvent`, as before.
--
-- Contents
-- --------
--   Constants ............. package identity, host limits, staging sizes
--   Dependencies .......... Registry; LifecycleKit (optional)
--   Public-surface validation  facade shape accepted from other copies
--   Bootstrap ............. Registry registration
--   Shared state .......... LuaCATS types, state creation, the upgrade from
--                           revision 22
--   Validation ............ receiver and argument checks, including the
--                           client's verdict on an event name
--   WoW Frame boundary .... CreateFrame and Frame method access
--   Channels .............. per-event host registration and fan-out,
--                           released records kept in a bounded pool
--   Listener storage ...... in-place settling outside a dispatch,
--                           compaction by copy during one
--   Listener isolation .... allocation-free protected dispatch
--   Combat log reader ..... whether this client gives addon code one
--   Scope ownership ....... intrusive scope links (array slots on
--                           connections, named fields on other members)
--   Connections ........... array-part handles, their lifecycle and methods
--   Dispatch .............. OnEvent to channel fan-out
--   Subscription .......... shared validation and connect path, the
--                           method-name form, scope closing
--   Logout coverage ....... who closes an addon scope at logout, decided at
--                           the first ForAddon (LifecycleKit or EventKit)
--   Parts ................. the stubs for absent parts, retiring what an
--                           absent part's objects hold, HasPart
--   Public API ............ package-level subscriptions and scopes
--   Limits ................ SetLimits and GetLimits over the shared limits
--   Scope methods ......... the handle a scope owner receives, Reopen
--   Commit ................ prototype/facade assignment and self-check

local PACKAGE_NAME = "eventKit"
local API_GENERATION = 1
local IMPLEMENTATION_REVISION = 23
local REQUIRED_REGISTRY_API = 2
local STATE_SCHEMA = 10

-- The revision this one upgrades in place. Older revisions were never
-- published, so their state and handles are not adopted (the upgrade floor,
-- docs/API.md, "Upgrading in place").
local UPGRADE_FLOOR_REVISION = 22

-- The interface the core offers its parts (`state.helpers`, `state.parts`,
-- the `state.dispatch` and `state.composites` entries). Entries are only ever
-- added; a core that has to change one adds a new entry and raises this
-- number. Interface 2 added `state.dispatch` and the helpers the Units and
-- CombatLog parts call.
local PART_INTERFACE = 2

-- LifecycleKit is optional as well: it depends on EventKit, so EventKit only
-- finds it through `Registry:Find` when an addon asks for its scope, to learn
-- whether LifecycleKit closes that scope at logout.
local OPTIONAL_LIFECYCLE_KIT_API = 1
local LOGOUT_EVENT = "PLAYER_LOGOUT"

-- How an addon scope is closed at logout, recorded on the scope as
-- `_logoutRoute`. `false` means "not decided yet"; `LOGOUT_ROUTE_NONE`
-- (EventKit could not connect its own logout listener) is re-examined at the
-- next `ForAddon`.
local LOGOUT_ROUTE_LIFECYCLE = "lifecycleKit"
local LOGOUT_ROUTE_EVENT = "playerLogout"
local LOGOUT_ROUTE_NONE = "none"

-- Channel records whose last connection went are kept for the next channel,
-- up to this many, so an event connected and disconnected in turn (the first
-- listener and the last) reuses one record and its listener array instead of
-- allocating both every time. The pool is package state shared by every
-- addon, so it is small and fixed.
local CHANNEL_POOL_SIZE = 16

-- WoW Frames cannot be destroyed, so the only real bound is on how many
-- unit-filter Frames the Units part ever creates. The bound is the shared
-- `maxUnitFrames` limit: this default, raised through `SetLimits` up to the
-- ceiling. It never accepts `EventKit.UNBOUNDED`, because every Frame it admits
-- lives for the rest of the session whatever the consumer does afterwards. The
-- limit stays in the core, so `SetLimits` and `GetLimits` keep one shape with or
-- without the part.
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

-- Where each part's members are, for the stubs' messages, and the file a
-- part's line follows in embeds.xml.
local CORE_FILE = "eventKit\\EventKit.lua"
local PART_FILES = {
  Units = "eventKit\\parts\\EventKit-Units.lua",
  CombatLog = "eventKit\\parts\\EventKit-CombatLog.lua",
  Coalescing = "eventKit\\parts\\EventKit-Coalescing.lua",
}

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
    or type(rawget(implementation, "IsCombatLogAvailable")) ~= "function"
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
    and type(rawget(scope, "Reopen")) == "function"
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
    and type(rawget(currentState, "connectionMetatable")) == "table"
    and type(rawget(currentState, "composites")) == "table"
    and type(rawget(currentState, "compositeMetatables")) == "table"
    and type(rawget(currentState, "compositePrototypes")) == "table"
    and rawget(currentState, "logoutConnection") ~= nil
    and type(rawget(currentState, "closeOnLogout")) == "function"
    and type(rawget(currentState, "channelPool")) == "table"
    and type(rawget(currentState, "dispatch")) == "table"
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

---A connection handle returned by an EventKit subscription. Its fields live
---in the array part (see "Connections"): `[1]` the listener, `[2]` whether it
---still delivers, `[3]` whether it is a one-shot, `[4]` its channel or route,
---and on a scoped handle `[5]` its scope, `[6]` and `[7]` its scope links.
---@class EventKit.Connection
---@field Disconnect fun(self: EventKit.Connection): boolean
---@field IsConnected fun(self: EventKit.Connection): boolean

---An ownership scope for connections, closed by its owner or, for an addon
---scope, through `EventKit:CloseAddonScopes`.
---@class EventKit.Scope
---@field Connect fun(self: EventKit.Scope, eventName: string, callback: EventKit.Listener|table, methodName: string?): EventKit.Connection
---@field Once fun(self: EventKit.Scope, eventName: string, callback: EventKit.Listener|table, methodName: string?): EventKit.Connection
---@field ConnectUnit fun(self: EventKit.Scope, eventName: string, callback: EventKit.Listener|table, ...: string): EventKit.Connection
---@field OnceUnit fun(self: EventKit.Scope, eventName: string, callback: EventKit.Listener|table, ...: string): EventKit.Connection
---@field ConnectCombatLog fun(self: EventKit.Scope, subEvent: string, callback: EventKit.CombatLogListener): EventKit.Connection
---@field DisconnectAll fun(self: EventKit.Scope): integer
---@field Close fun(self: EventKit.Scope): boolean
---@field IsClosed fun(self: EventKit.Scope): boolean
---@field Reopen fun(self: EventKit.Scope): boolean
---@field package _addonName string? The owning addon, `nil` for a manual scope.
---@field package _head table|false The first member of the live list.
---@field package _tail table|false The last member of the live list.
---@field package _activeCount integer Live members.
---@field package _closed boolean Whether the scope is closed.
---@field GetAddonName fun(self: EventKit.Scope): string?
---@field GetActiveCount fun(self: EventKit.Scope): integer
---@field Coalesce fun(self: EventKit.Scope, events: string|string[], intervalSeconds: number, callback: fun(set: table<any, any>), options: EventKit.CoalesceOptions?): EventKit.CoalesceHandle
---@field Derive fun(self: EventKit.Scope, events: string|string[], compute: (fun(): any), options: EventKit.DeriveOptions?): EventKit.DeriveHandle

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

---One event name's fan-out: a host registration plus the listeners behind it.
---A released record waits in `channelPool` with `false` in its references.
---@class EventKit.Channel
---@field eventName string|false `false` while the record waits in the pool.
---@field frame WowFrame|false Frame holding the host registration.
---@field listeners EventKit.Connection[] Connections in connection order, tombstones included (see "Listener storage").
---@field tombstones integer Disconnected connections still in `listeners`.
---@field count integer Live EventKit connections sharing the registration.
---@field onceCount integer? Live one-shot connections; created by the first one (see "Dispatch").
---@field channels table<string, EventKit.Channel>|false Owning channel map.
---@field group EventKit.UnitGroup|false `false` for a regular, unfiltered event.

---The channels registered against one normalized unit-token set.
---@class EventKit.UnitGroup
---@field key string Normalized, order-independent unit-set key.
---@field channels table<string, EventKit.Channel>
---@field frame WowFrame? `nil` once the group has released its Frame.

---One combat-log sub-event's fan-out: the listeners that asked for it.
---@class EventKit.CombatLogRoute
---@field subEvent string The sub-event routed here, or `"*"` for the wildcard route.
---@field listeners EventKit.Connection[] Connections in connection order, tombstones included (see "Listener storage").
---@field tombstones integer Disconnected connections still in `listeners`.
---@field count integer Live connections on this route; it leaves the router at zero.
---@field onceCount integer? Never above zero: a route takes no one-shots.

---The combat-log router: the package's one share of the
---`COMBAT_LOG_EVENT_UNFILTERED` registration and the routes behind it.
---@class EventKit.CombatLogRouter
---@field channel EventKit.Channel|false The event's channel while at least one combat-log listener exists.
---@field inner EventKit.Connection|false The router's connection on that channel.
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
---@field Connect fun(self: EventKit, eventName: string, callback: EventKit.Listener|table, methodName: string?): EventKit.Connection
---@field Once fun(self: EventKit, eventName: string, callback: EventKit.Listener|table, methodName: string?): EventKit.Connection
---@field ConnectUnit fun(self: EventKit, eventName: string, callback: EventKit.Listener|table, ...: string): EventKit.Connection
---@field OnceUnit fun(self: EventKit, eventName: string, callback: EventKit.Listener|table, ...: string): EventKit.Connection
---@field ConnectCombatLog fun(self: EventKit, subEvent: string, callback: EventKit.CombatLogListener): EventKit.Connection
---@field IsCombatLogAvailable fun(self: EventKit): boolean Whether this client gives addon code a combat-log reader, so `ConnectCombatLog` can connect.
---@field CreateScope fun(self: EventKit): EventKit.Scope
---@field ForAddon fun(self: EventKit, addonName: string): EventKit.Scope
---@field CloseAddonScopes fun(self: EventKit, addonName: string): boolean
---@field Coalesce fun(self: EventKit, events: string|string[], intervalSeconds: number, callback: fun(set: table<any, any>), options: EventKit.CoalesceOptions?): EventKit.CoalesceHandle
---@field Derive fun(self: EventKit, events: string|string[], compute: (fun(): any), options: EventKit.DeriveOptions?): EventKit.DeriveHandle
---@field HasPart fun(self: EventKit, name: string): boolean Whether the named part (`"Units"`, `"CombatLog"` or `"Coalescing"`) is installed in this session.

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
    -- The metatable every connection handle carries. Shared, so a newer
    -- revision checks a receiver by metatable identity and keeps the
    -- handles the older copy made.
    connectionMetatable = {},
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
    -- The parts installed in this session (name to `{ revision = n }`), the
    -- core functions they call, read at call time so an upgraded core
    -- serves a part loaded before it, and the interface number they check.
    parts = {},
    helpers = {},
    partInterface = PART_INTERFACE,
    -- The package sentinel published as `EventKit.UNBOUNDED`, kept here so
    -- every revision hands out the same table, and the shared limits
    -- `SetLimits` writes, which a newer revision inherits.
    unbounded = {},
    limits = { maxUnitFrames = DEFAULT_MAX_UNIT_FRAMES },
    -- The one `PLAYER_LOGOUT` connection that closes addon scopes when no
    -- LifecycleKit does, `false` until an addon needs it. The handler it
    -- resolves when it runs (`closeOnLogout`) is installed at commit, like
    -- `isolate`.
    logoutConnection = false,
    -- Released channel records kept for reuse (see `CHANNEL_POOL_SIZE`).
    channelPool = {},
    -- What the core calls in a part (see "Parts"): `releaseUnitGroup` and
    -- `releaseRoute`, filled by the Units and CombatLog parts.
    dispatch = {},
  }

  rawset(EventKit, "Connection", Connection)
  rawset(EventKit, "Scope", Scope)
  rawset(EventKit, "_state", state)
elseif previousRevision < UPGRADE_FLOOR_REVISION then
  -- Revisions before 22 were never published: the floor adopts revision 22's
  -- state only (docs/API.md, "Upgrading in place").
  error(
    "MoltenCodes EventKit revision "
      .. IMPLEMENTATION_REVISION
      .. " upgrades revision "
      .. UPGRADE_FLOOR_REVISION
      .. " or newer in place, not revision "
      .. tostring(previousRevision),
    2
  )
elseif
  type(Connection) ~= "table"
  or type(state) ~= "table"
  or type(rawget(state, "regularChannels")) ~= "table"
  or type(rawget(state, "unitGroups")) ~= "table"
  or rawget(state, "schema") ~= STATE_SCHEMA
  or type(Scope) ~= "table"
  or type(rawget(state, "parts")) ~= "table"
  or type(rawget(state, "helpers")) ~= "table"
then
  error("MoltenCodes EventKit package state is corrupted or incomplete", 2)
elseif type(rawget(state, "dispatch")) ~= "table" then
  -- Revision 22 had no dispatch entries: its unit and combat-log code was in
  -- the core. The parts fill them; the defaults are installed at commit.
  rawset(state, "dispatch", {})
end
rawset(state, "partInterface", PART_INTERFACE)

-- Connection handles are validated by metatable identity, so their metatable
-- lives in shared state like the scope metatable below.
local CONNECTION_METATABLE = rawget(state, "connectionMetatable")
rawset(CONNECTION_METATABLE, "__index", Connection)

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

-- The scope metatable lives in shared state too: scope receivers are
-- validated by metatable identity, which therefore has to survive an
-- in-place upgrade.
local SCOPE_METATABLE = rawget(state, "scopeMetatable")
rawset(SCOPE_METATABLE, "__index", Scope)

-- Validation ----------------------------------------------------------------

-- Argument validation raises with an explicit stack level so the reported
-- position is the line that called the public method, never a line inside
-- EventKit. `level` is always the value `error` needs *inside the function that
-- receives it*, so every further hop towards `error` adds exactly one.
--
-- On a client with secret values, comparing a secret with a value of its own
-- type (`rawequal` included) or using it as a key raises inside EventKit instead
-- of at the caller; a comparison with `nil` happens not to raise. Values EventKit
-- did not create are tested for absence with `type(value) == "nil"`, the
-- repository rule, and a secret is refused (payloads: not compared) first.

-- The client's secret probe is resolved once, when this copy loads: every
-- client flavour defines `issecretvalue` before any addon runs. Only when it
-- was absent at load is the global read again on each check, so a probe a
-- test environment or a compatibility shim installs later is still honoured.
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

---Raise at `level` when `value` is secret, naming `label`.
---@param value any
---@param label string qualified argument name, used in the argument error
---@param level integer stack level the failure is reported at
local function refuseSecret(value, label, level)
  if isSecret(value) then
    error(label .. " must not be a secret value", level)
  end
end

-- A caller's table key is named in a refusal without running its `__tostring`,
-- which could raise or answer a secret and so lose the real refusal.
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

-- `C_EventUtils.IsEventValid(eventName)` is the client's own answer to "is this
-- an event I know?". It is probed once, when this copy loads, like the rest of
-- the client's API set, which is fixed for the session. Registering an unknown
-- name raises inside `Frame:RegisterEvent` with a message that names no caller
-- line (measured on Retail 12.1.0), so with the function EventKit refuses the
-- name itself, at the caller's line, before it registers or allocates anything.
-- `false` means the client has no such function (older clients); the verdict
-- is then left to `RegisterEvent`, as before revision 15.
local hostIsEventValid = false
do
  -- C_EventUtils is a World of Warcraft client namespace reachable only through the global table.
  -- selene: allow(global_usage)
  local eventUtils = rawget(_G, "C_EventUtils")
  if type(eventUtils) == "table" and type(rawget(eventUtils, "IsEventValid")) == "function" then
    hostIsEventValid = rawget(eventUtils, "IsEventValid")
  end
end

---Raise at `level` when the client says it does not know `eventName`.
---
---Only called with a non-empty string that is not secret. Only a plain `false`
---refuses: any other answer, a secret one included, leaves the verdict to the
---host's registration, so a client quirk can never refuse a real event.
---@param eventName string
---@param description string qualified argument name, used in the argument error
---@param level integer stack level the failure is reported at
local function refuseUnknownEvent(eventName, description, level)
  if hostIsEventValid == false then
    return
  end
  local known = hostIsEventValid(eventName)
  if type(known) == "boolean" and not isSecret(known) and known == false then
    error(description .. ' "' .. eventName .. '" is not an event this client knows', level)
  end
end

---Validate an event name a public method will register: whether it is
---secret, then its type, then whether the client knows it, in that order. The
---secret refusal comes first so that no later test compares a secret value.
---@param eventName any
---@param label string qualified public method name, used in the argument error
---@param level integer stack level the failure is reported at
local function validateEventName(eventName, label, level)
  refuseSecret(eventName, label .. " eventName", level + 1)
  if type(eventName) ~= "string" or eventName == "" then
    error(label .. " eventName must be a non-empty string", level)
  end
  refuseUnknownEvent(eventName, label .. " eventName", level + 1)
end

---@param callback any
---@param label string qualified public method name, used in the argument error
---@param level integer stack level the failure is reported at
local function validateCallback(callback, label, level)
  if type(callback) ~= "function" then
    error(label .. " callback must be a function", level)
  end
end

---Turn a receiver table and a method name into a listener, the counterpart of
---AceEvent's `RegisterEvent("X", "OnX")`.
---
---The method must exist when the connection is made, so a misspelt name
---raises at the caller's line. It is then looked up on the receiver at every
---delivery, as AceEvent does, so a method replaced later (by a hook, say)
---is the one that runs. A method gone by then raises inside the listener's
---isolation, which reports it to the host error handler; the connection
---stays. The listener holds two upvalues, so it costs one closure per
---connection and one extra Lua call per delivery.
---@param receiver any the table the method is called on
---@param methodName any the method's name; `defaultName` when `nil`
---@param defaultName string|nil the name used when `methodName` is omitted
---@param label string qualified public method name, used in the argument errors
---@param level integer stack level the failures are reported at
---@return EventKit.Listener listener
local function bindMethod(receiver, methodName, defaultName, label, level)
  if type(receiver) ~= "table" then
    error(
      label .. " callback must be a function, or a receiver table followed by a method name",
      level
    )
  end
  if type(methodName) == "nil" and type(defaultName) ~= "nil" then
    methodName = defaultName
  end
  refuseSecret(methodName, label .. " methodName", level + 1)
  if type(methodName) ~= "string" or methodName == "" then
    error(label .. " methodName must be a non-empty string", level)
  end
  if type(receiver[methodName]) ~= "function" then
    error(label .. ' receiver has no method "' .. methodName .. '"', level)
  end
  return function(...)
    local method = receiver[methodName]
    -- `== nil` answers `false` without raising for a secret value (measured
    -- on Retail 12.1.0, docs/EMBEDDING.md), and a call on anything else
    -- that is not a function raises in the isolation anyway.
    if method == nil then
      error('EventKit receiver has no method "' .. methodName .. '"', 0)
    end
    return method(receiver, ...)
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
  -- `getmetatable` answers the shared scope metatable for a scope only, so
  -- no type test is needed first.
  if getmetatable(scope) ~= SCOPE_METATABLE then
    error(label .. " must be called on an EventKit scope", level)
  end
end

---@param scope EventKit.Scope
---@param label string qualified public method name, used in the argument error
---@param level integer stack level the failure is reported at
local function ensureScopeOpen(scope, label, level)
  if scope._closed == true then
    error(label .. " cannot connect in a closed scope", level)
  end
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
  return state.dispatchRegular(EventKit, eventName, ...)
end

---Return the single Frame that carries every unfiltered registration.
---@return WowFrame
local function ensureRegularFrame()
  local frame = state.regularFrame
  if frame ~= nil then
    return frame
  end

  frame = createEventFrame(onRegularFrameEvent)
  state.regularFrame = frame
  return frame
end

-- Channels ------------------------------------------------------------------
--
-- A channel is one event name's host registration and the listeners behind
-- it. When its last connection goes, the registration is released and, when
-- no dispatch is running, the record itself waits in the bounded
-- `channelPool` for the next channel, with its emptied listener array. A
-- record reached by a dispatch in flight is left to the collector instead,
-- because that dispatch may still read it.

---Return a channel record for `eventName`: a pooled one, reset, or a new one.
---@param eventName string
---@param frame WowFrame
---@param channels table<string, EventKit.Channel> the map the channel joins
---@param group EventKit.UnitGroup|false
---@return EventKit.Channel
local function newChannel(eventName, frame, channels, group)
  local pool = state.channelPool
  local pooled = #pool
  if pooled == 0 then
    return {
      eventName = eventName,
      frame = frame,
      listeners = {},
      tombstones = 0,
      count = 0,
      channels = channels,
      group = group,
    }
  end

  local channel = pool[pooled]
  pool[pooled] = nil
  channel.eventName = eventName
  channel.frame = frame
  channel.count = 0
  channel.channels = channels
  channel.group = group
  return channel
end

---Return the unfiltered channel for `eventName`, registering it on demand.
---@param eventName string
---@param label string qualified public method name, used in the argument error
---@param level integer stack level the failure is reported at
---@return EventKit.Channel
local function createRegularChannel(eventName, label, level)
  local channels = state.regularChannels
  local existingChannel = channels[eventName]
  if existingChannel ~= nil then
    return existingChannel
  end

  -- The Frame and its method are read inline; the helpers, which create the
  -- Frame or name a missing method, run only when a read comes back empty.
  local frame = state.regularFrame or ensureRegularFrame()
  local registerEvent = frame.RegisterEvent
  if type(registerEvent) ~= "function" then
    registerEvent = requireFrameMethod(frame, "RegisterEvent")
  end
  local registered = registerEvent(frame, eventName)
  if registered == false then
    error(label .. " could not register event " .. eventName, level)
  end

  local channel = newChannel(eventName, frame, channels, false)
  channels[eventName] = channel
  return channel
end

---Put a released channel record into the pool when that is safe: no dispatch
---is running and its listener array is empty. Every reference it holds is
---dropped, so a pooled record keeps nothing alive.
---@param channel EventKit.Channel
local function poolChannel(channel)
  local pool = state.channelPool
  if state.dispatchDepth > 0 or #channel.listeners ~= 0 or #pool >= CHANNEL_POOL_SIZE then
    return
  end
  channel.eventName = false
  channel.frame = false
  channel.channels = false
  channel.group = false
  channel.tombstones = 0
  -- Zero once every one-shot left; reset anyway, so a bookkeeping slip
  -- cannot keep a reused record on the protected walk.
  if channel.onceCount ~= nil then
    channel.onceCount = 0
  end
  pool[#pool + 1] = channel
end

---Drop one connection from `channel`, unregistering it once the last one goes.
---@param channel EventKit.Channel
local function releaseChannel(channel)
  local count = channel.count - 1
  channel.count = count

  -- The count is decremented once per connection and a connection disconnects
  -- at most once, so it can only ever reach zero. Treating any non-positive
  -- value as "empty" keeps a bookkeeping slip from pinning a registration for
  -- the rest of the session.
  if count > 0 then
    return
  end

  -- A record already released and pooled holds `false` here; a slip that
  -- releases it twice must not touch whichever channel reuses it.
  local eventName = channel.eventName
  if eventName == false then
    return
  end
  local channels = channel.channels --[[@as table<string, EventKit.Channel>]]
  local frame = channel.frame --[[@as WowFrame]]
  if channels[eventName] ~= channel then
    return
  end

  -- Remove dispatch visibility before touching the host API. Even if an
  -- unexpected host-side UnregisterEvent error occurs, stale callbacks can no
  -- longer be delivered through this package state.
  channels[eventName] = nil

  local unregisterEvent = frame.UnregisterEvent
  if type(unregisterEvent) ~= "function" then
    unregisterEvent = requireFrameMethod(frame, "UnregisterEvent")
  end
  unregisterEvent(frame, eventName)

  -- A unit channel's group gives its Frame back with its last channel; only
  -- the Units part makes such a channel, and it fills the entry.
  local group = channel.group
  if group ~= false and group.frame ~= nil and next(channels) == nil then
    state.dispatch.releaseUnitGroup(group)
  end

  poolChannel(channel)
end

-- Listener storage ----------------------------------------------------------
--
-- Channels and combat-log routes keep their connections in a `listeners`
-- array in connection order, with SignalKit's rules for a signal (see
-- SignalKit's docs/API.md, "Mutation semantics"): a dispatch walks the array
-- up to the length it read when it started, so a connection made during it
-- waits for the next dispatch; a disconnect marks the connection, so a
-- dispatch skips it at once; and a disconnected connection stays in the
-- array as a tombstone until the array is settled.
--
-- While no EventKit dispatch runs (`dispatchDepth` is zero), nothing holds a
-- position in any array, so a disconnect edits the array in place and
-- allocates nothing: tombstones at the tail are dropped at once, which is
-- where connect-then-disconnect churn leaves them, and once at least half of
-- the array is tombstones the live entries are shifted down. During a
-- dispatch the array is instead replaced by a compacted copy at that
-- threshold, so the dispatch keeps walking the array it started with.
-- Connection objects are shared, so a disconnect is visible in both. Either
-- way disconnecting is amortized O(1) and an array holds at most twice its
-- live connections.
--
-- The depth is package-wide rather than per array, and revision 22 raises the
-- same counter around its dispatches, so an older copy's dispatch still on the
-- stack below an in-place upgrade is seen too.

---Drop the tombstones of an array no dispatch is walking: first those at the
---tail, then, past the threshold, every other one by shifting the live
---entries down in order.
---@param listeners EventKit.Connection[]
---@param total integer the array length
---@param tombstones integer the tombstones in the array
---@return integer tombstones the tombstones left
local function settleInPlace(listeners, total, tombstones)
  while total > 0 and listeners[total][2] ~= true do
    listeners[total] = nil
    total = total - 1
    tombstones = tombstones - 1
  end
  if tombstones == 0 or tombstones * 2 < total then
    return tombstones
  end

  local live = 0
  for index = 1, total do
    local connection = listeners[index]
    if connection[2] == true then
      live = live + 1
      listeners[live] = connection
    end
  end
  for index = live + 1, total do
    listeners[index] = nil
  end
  return 0
end

---Account for `connection`, just marked disconnected, in the array of
---`fanOut` (a channel or a combat-log route).
---@param fanOut EventKit.Channel|EventKit.CombatLogRoute
---@param connection EventKit.Connection
local function dropListener(fanOut, connection)
  local listeners = fanOut.listeners
  local total = #listeners
  local tombstones = fanOut.tombstones + 1

  if state.dispatchDepth > 0 then
    if tombstones * 2 >= total then
      local compacted = {}
      local live = 0
      for index = 1, total do
        local entry = listeners[index]
        if entry[2] == true then
          live = live + 1
          compacted[live] = entry
        end
      end
      fanOut.listeners = compacted
      tombstones = 0
    end
  elseif tombstones == 1 and listeners[total] == connection then
    -- The churn case: the only tombstone is the tail, so settling is one
    -- removal.
    listeners[total] = nil
    tombstones = 0
  else
    tombstones = settleInPlace(listeners, total, tombstones)
  end

  fanOut.tombstones = tombstones
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

-- Combat log reader ------------------------------------------------------------
--
-- Routing the combat log is the CombatLog part. Whether this client gives
-- addon code a reader at all is the core's answer, because it is a fact about
-- the client: Retail 12 has none, so an addon there should not have to embed
-- the part to learn that.

-- Assigned in the dispatch section: the walk that delivers a channel's or a
-- route's listeners.
local deliverListeners

-- Assigned in the connections section; the parts call them through helpers.
local connectToChannel
local disconnectEventConnection

---Return the client's combat-log reader, or `nil` when addon code has none.
---
---The global `CombatLogGetCurrentEventInfo` is preferred, so a replacement
---another addon installed there is honoured. Current classic clients document
---only `C_CombatLog.GetCurrentEventInfo`, so the namespaced function is used
---when the global is absent. Retail 12 clients give addon code neither: the
---reader exists only under `C_CombatLogSecure` and `C_CombatLogInternal`, which
---a measured Retail 12.1.0 client also withholds from addon code, and
---`C_CombatLog.IsCombatLogRestricted()` answers `true` there.
---
---Resolved on every call rather than once at load, so a copy loaded before
---the reader existed still finds it. Two table reads; allocates nothing.
---@return function|nil readEventInfo
local function findCombatLogReader()
  -- CombatLogGetCurrentEventInfo and C_CombatLog are World of Warcraft client APIs reachable only through the global table.
  -- selene: allow(global_usage)
  local readEventInfo = rawget(_G, "CombatLogGetCurrentEventInfo")
  if type(readEventInfo) == "function" then
    return readEventInfo
  end
  -- selene: allow(global_usage)
  local combatLogNamespace = rawget(_G, "C_CombatLog")
  if type(combatLogNamespace) == "table" then
    readEventInfo = rawget(combatLogNamespace, "GetCurrentEventInfo")
    if type(readEventInfo) == "function" then
      return readEventInfo
    end
  end
  return nil
end

-- Scope ownership -----------------------------------------------------------
--
-- A scope keeps its live members on an intrusive doubly linked list: the
-- links are fields on the member itself, so joining or leaving a scope
-- allocates nothing and a disconnected handle is unlinked in O(1) the moment
-- it disconnects. `false` marks an empty link so the fields exist from the
-- member's creation and never rehash it.
--
-- A connection keeps its links in array slots 5 to 7 (see "Connections"); a
-- Coalesce or Derive handle keeps them by name (`_scope`, `_scopePrevious`,
-- `_scopeNext`). Slot 2 tells the two apart: it holds a connection's connected
-- flag, a boolean, and nothing on a handle.
--
-- Neither the scope metatable nor the connection metatable has
-- `__newindex`, and every field written here already exists on the record,
-- so plain indexing is exact and costs a VM instruction where `rawget` and
-- `rawset` cost a C call each.

local scopeOfMember, linkToScope, unlinkFromScope
do
  ---The scope `member` belongs to, or `false`/`nil` for none.
  ---@param member table a connection or a Coalesce or Derive handle
  ---@return EventKit.Scope|false|nil
  local function findMemberScope(member)
    if member[2] ~= nil then
      return member[5]
    end
    return member._scope
  end
  scopeOfMember = findMemberScope

  ---Point `member`'s link to the following member at `following`.
  ---@param member table
  ---@param following table|false
  local function setNextMember(member, following)
    if member[2] ~= nil then
      member[7] = following
    else
      member._scopeNext = following
    end
  end

  ---Point `member`'s link to the previous member at `previous`.
  ---@param member table
  ---@param previous table|false
  local function setPreviousMember(member, previous)
    if member[2] ~= nil then
      member[6] = previous
    else
      member._scopePrevious = previous
    end
  end

  ---Append `member` to `scope`'s live list, keeping creation order.
  ---@param scope EventKit.Scope
  ---@param member table a connection or a Coalesce or Derive handle
  local function appendToScope(scope, member)
    local tail = scope._tail
    if member[2] ~= nil then
      member[5] = scope
      member[6] = tail
      member[7] = false
    else
      member._scope = scope
      member._scopePrevious = tail
      member._scopeNext = false
    end
    if tail == false then
      scope._head = member
    else
      setNextMember(tail, member)
    end
    scope._tail = member
    scope._activeCount = scope._activeCount + 1
  end
  linkToScope = appendToScope

  ---Remove `member` from the scope that owns it, if any. Never raises.
  ---@param member table a connection or a Coalesce or Derive handle
  local function removeFromScope(member)
    local scope, previous, following
    local arrayLayout = member[2] ~= nil
    if arrayLayout then
      scope, previous, following = member[5], member[6], member[7]
    else
      scope, previous, following = member._scope, member._scopePrevious, member._scopeNext
    end
    if scope == nil or scope == false then
      return
    end
    local owner = scope --[[@as EventKit.Scope]]

    if previous == false then
      owner._head = following
    else
      setNextMember(previous --[[@as table]], following)
    end
    if following == false then
      owner._tail = previous
    else
      setPreviousMember(following --[[@as table]], previous)
    end

    if arrayLayout then
      member[5] = false
      member[6] = false
      member[7] = false
    else
      member._scope = false
      member._scopePrevious = false
      member._scopeNext = false
    end
    owner._activeCount = owner._activeCount - 1
  end
  unlinkFromScope = removeFromScope
end

-- Connections ---------------------------------------------------------------
--
-- A connection handle is also the record in its channel's or route's
-- listener array, so connecting allocates the handle and nothing else: no
-- wrapper closure and no second record. Its fields live in the array part,
-- sized exactly by the constructor:
--
--   [1] the listener, `nil` once disconnected
--   [2] whether it still delivers (a boolean, never `nil`)
--   [3] whether it disconnects before its first call
--   [4] its fan-out: a channel, or a combat-log route (which carries
--       `subEvent`), `nil` once disconnected
--   [5] the owning scope or `false`, [6] the previous and [7] the next
--       member of that scope's list; only on a scoped handle
--
-- An array part costs 16 bytes a slot where a hash part costs 40 a node, so
-- an unscoped handle is 128 bytes instead of 224 and a scoped one 176
-- instead of 384. Slots past the constructor's are never written: in Lua 5.1
-- assigning even `nil` to a missing key inserts it, which can grow a table.

---@param connection EventKit.Connection
---@return boolean disconnected `true` only for the call that transitioned the state.
function disconnectEventConnection(connection)
  if connection[2] ~= true then
    return false
  end

  local fanOut = connection[4]
  connection[2] = false
  connection[1] = nil
  connection[4] = nil

  -- A route carries `subEvent`; a channel has no such field.
  local isRoute = fanOut.subEvent ~= nil
  if connection[3] == true and not isRoute then
    -- One live one-shot fewer; `onceCount` exists once the first came.
    local onceCount = fanOut.onceCount
    if onceCount ~= nil and onceCount > 0 then
      fanOut.onceCount = onceCount - 1
    end
  end

  -- Leave the scope before touching the host, which can raise. Bulk
  -- teardown relies on every attempted connection leaving the list,
  -- whatever happens after this line. An unscoped handle has no slot 5.
  if connection[5] then
    unlinkFromScope(connection)
  end

  if isRoute then
    -- Only the CombatLog part makes a route, and it fills the entry.
    dropListener(fanOut, connection)
    state.dispatch.releaseRoute(fanOut)
    return true
  end

  -- The churn case inline: no dispatch running and this connection the
  -- tail of an array without tombstones is one removal (see
  -- `dropListener`), and a channel other connections still share needs
  -- only its count.
  local channel = fanOut
  local listeners = channel.listeners
  local total = #listeners
  if channel.tombstones == 0 and listeners[total] == connection and state.dispatchDepth <= 0 then
    listeners[total] = nil
  else
    dropListener(channel, connection)
  end
  local count = channel.count
  if count > 1 then
    channel.count = count - 1
  else
    releaseChannel(channel)
  end
  return true
end

---Build a connection handle for `callback` on `fanOut`, owned by `scope` when
---it is one.
---@param fanOut EventKit.Channel|EventKit.CombatLogRoute
---@param callback function
---@param once boolean whether the connection disconnects before its first call
---@param scope EventKit.Scope|false owning scope, or `false` for none
---@return EventKit.Connection
local function newConnection(fanOut, callback, once, scope)
  -- Two constructors, because a constructor sizes the array part by the
  -- values it lists: listing the scope links on every handle would add
  -- three slots to the handles that have no scope.
  local connection
  if scope == false then
    connection = { callback, true, once, fanOut }
  else
    connection = { callback, true, once, fanOut, false, false, false }
  end
  setmetatable(connection, CONNECTION_METATABLE)

  local listeners = fanOut.listeners
  listeners[#listeners + 1] = connection
  fanOut.count = fanOut.count + 1
  if once then
    -- Only channels take one-shots; the count tells `fireChannel` that a
    -- delivery may release a registration (see "Dispatch").
    fanOut.onceCount = (fanOut.onceCount or 0) + 1
  end
  if scope ~= false then
    linkToScope(scope --[[@as EventKit.Scope]], connection)
  end
  return connection --[[@as EventKit.Connection]]
end

---Attach `callback` to `channel`.
---@param channel EventKit.Channel
---@param callback EventKit.Listener
---@param once boolean whether the connection disconnects before its first call
---@param scope EventKit.Scope|false owning scope, or `false` for none
---@return EventKit.Connection
function connectToChannel(channel, callback, once, scope)
  return newConnection(channel, callback, once, scope)
end

local disconnect, isConnected
do
  -- Connection methods are published on a shared prototype, so `connection.Disconnect()`
  -- and `EventKit.Connection.Disconnect()` both reach them with no receiver. Without a
  -- guard the first `rawget` inside raises "bad argument #1 to 'rawget'" from EventKit's
  -- own line, which names neither the package nor the mistake. Each method therefore
  -- tests its receiver first and raises at the caller.
  local DISCONNECT_RECEIVER_MESSAGE =
    "EventKit:Disconnect must be called on a connection handle; use connection:Disconnect()"
  local IS_CONNECTED_RECEIVER_MESSAGE =
    "EventKit:IsConnected must be called on a connection handle; use connection:IsConnected()"

  ---Cancel this subscription and release its share of the host registration.
  ---@param self EventKit.Connection
  ---@return boolean disconnected `true` only for the call that transitioned the state.
  local function disconnectHandle(self)
    -- The receiver check by metatable identity: the shared metatable is on
    -- every handle, and on nothing else.
    if getmetatable(self) ~= CONNECTION_METATABLE then
      error(DISCONNECT_RECEIVER_MESSAGE, 2)
    end

    return disconnectEventConnection(self)
  end
  disconnect = disconnectHandle

  ---Whether this subscription is still delivering.
  ---@param self EventKit.Connection
  ---@return boolean connected
  local function isHandleConnected(self)
    if getmetatable(self) ~= CONNECTION_METATABLE then
      error(IS_CONNECTED_RECEIVER_MESSAGE, 2)
    end

    return self[2] == true
  end
  isConnected = isHandleConnected
end

-- Dispatch ------------------------------------------------------------------
--
-- EventKit counts the dispatches on the stack so that closing a scope from
-- inside a listener never cuts short the delivery already in flight: the
-- scope refuses new connections at once, and its connections are swept when
-- the outermost dispatch returns. The same count tells a disconnect whether it
-- may edit a listener array in place (see "Listener storage"). The count is
-- two field writes per event and the sweep check one comparison, so the
-- per-event path stays allocation-free.
--
-- The per-event path reads EventKit's own tables with plain indexing, a VM
-- instruction, rather than `rawget`, a C call: every table read here is one
-- EventKit created and fills completely.

-- Assigned in the subscription section, once bulk disconnection exists.
local sweepPendingScopes

---Deliver `...` to every eligible listener of `fanOut`, a channel or a
---combat-log route, in connection order, each call isolated.
---@param fanOut EventKit.Channel|EventKit.CombatLogRoute
---@param ... any what each listener receives
function deliverListeners(fanOut, ...)
  local listeners = fanOut.listeners
  -- Read once per event, so a newer revision replaces the isolation for
  -- the connections that already exist.
  local isolateCall = state.isolate --[[@as function]]
  for index = 1, #listeners do
    local connection = listeners[index]
    -- Slots 2, 1 and 3: connected, listener, once (see "Connections").
    if connection[2] == true then
      local callback = connection[1]
      if connection[3] == true then
        -- Disconnected before the call, so a nested dispatch the callback
        -- starts cannot deliver to it a second time.
        disconnectEventConnection(connection)
      end
      isolateCall(callback, ...)
    end
  end
end

---Deliver one event to `channel`'s listeners with the dispatch depth raised
---around it.
---@param channel EventKit.Channel
---@param eventName string
---@param ... any client payload
local function fireChannel(channel, eventName, ...)
  state.dispatchDepth = state.dispatchDepth + 1
  -- Listeners are isolated: `securecallfunction` and `xpcall` both report a
  -- listener's error instead of propagating it (docs/EMBEDDING.md, "Secure
  -- calls and secure variables"). The walk itself can raise only where it
  -- reaches outside: a one-shot listener's release talks to the host. Only
  -- then is the walk protected, so the depth is restored whatever happens: a
  -- stuck depth would defer every later scope close for the whole session.
  -- The common channel pays no second `pcall`.
  local ok, failure = true, nil
  if (channel.onceCount or 0) > 0 then
    ok, failure = pcall(deliverListeners, channel, eventName, ...)
  else
    deliverListeners(channel, eventName, ...)
  end
  local depth = state.dispatchDepth - 1
  state.dispatchDepth = depth
  if depth <= 0 and state.pendingScopeCount > 0 then
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
  local channel = state.regularChannels[eventName]
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
---@param callback any a function, or a receiver table for the method form
---@param once boolean
---@param methodName any the method form's method name; `eventName` when omitted
---@return EventKit.Connection
local function subscribeRegular(scope, label, level, eventName, callback, once, methodName)
  -- `Connect` is half of every connect-disconnect pair, so the common valid
  -- call is recognised inline and the validators, which raise at the
  -- caller's line, run in full only otherwise: for a secret or malformed
  -- name, a callback that is not a function (the method form included), or
  -- on a client that can judge the name (`C_EventUtils.IsEventValid`). The
  -- secret test comes first, because comparing a secret with `""` would
  -- raise here instead of at the caller.
  if
    isSecret(eventName)
    or type(eventName) ~= "string"
    or eventName == ""
    or hostIsEventValid ~= false
  then
    validateEventName(eventName, label, level + 1)
  end
  if type(callback) ~= "function" then
    callback = bindMethod(callback, methodName, eventName, label, level + 1)
  end
  local channel = state.regularChannels[eventName]
    or createRegularChannel(eventName, label, level + 1)
  local connection = newConnection(channel, callback, once, scope)
  return connection
end

---Release one member of a scope: a connection, or a Coalesce or Derive
---handle, which carries a `_kind` and releases everything it owns.
---@param member table
---@return boolean released `true` only for the call that transitioned it.
local function disconnectScopeMember(member)
  if member._kind ~= nil then
    return state.composites.close(member)
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
  local connection = scope._head

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
    if scopeOfMember(connection) == scope then
      unlinkFromScope(connection)
    end
    connection = scope._head
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
  local pending = state.pendingScopes
  local index = 1
  -- Disconnecting never dispatches, so the count cannot grow while sweeping;
  -- it is re-read anyway so the loop stays correct if that ever changes.
  while index <= state.pendingScopeCount do
    local scope = pending[index]
    pending[index] = false
    local ok, failure = pcall(disconnectAllInScope, scope)
    if not ok then
      reportListenerError(failure)
    end
    index = index + 1
  end
  state.pendingScopeCount = 0
end

---Terminally close `scope`, disconnecting everything it owns.
---
---Inside a dispatch the scope is closed at once but its connections are swept
---when the outermost dispatch returns: `Close` prevents future deliveries and
---never the one in flight.
---@param scope EventKit.Scope
---@return boolean closed `false` when the scope was already closed.
local function closeScope(scope)
  if scope._closed == true then
    return false
  end

  -- Terminal before cleanup begins, so nothing reached during the sweep can
  -- add a replacement connection.
  scope._closed = true

  if state.dispatchDepth > 0 then
    if scope._head ~= false then
      local count = state.pendingScopeCount + 1
      state.pendingScopes[count] = scope
      state.pendingScopeCount = count
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
--   2. Otherwise: one package-level `PLAYER_LOGOUT` one-shot closes every
--      addon scope LifecycleKit does not close. (Revisions before 23 also
--      subscribed to `OnShutdown` of a LifecycleKit without the capability,
--      which only its never-published revisions before 13 lacked.)
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

---Close, at `PLAYER_LOGOUT`, every addon scope LifecycleKit does not close
---(route 2), in addon-name order. The listener runs inside the dispatch, so
---each scope refuses new connections at once and is swept after the dispatch;
---every scope's own `PLAYER_LOGOUT` listeners still receive the event.
local function closeOnLogout()
  state.logoutConnection = false

  local addonScopes = state.addonScopes
  local names = {}
  for addonName in pairs(addonScopes) do
    names[#names + 1] = addonName
  end
  table.sort(names)

  local firstError = nil
  for index = 1, #names do
    local scope = addonScopes[names[index]]
    local route = scope._logoutRoute
    if route ~= LOGOUT_ROUTE_LIFECYCLE then
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

---Make sure EventKit's own `PLAYER_LOGOUT` one-shot is connected (route 2),
---creating it on first need.
---@return boolean covered `false` when the host refused the registration
local function ensureLogoutConnection()
  local existing = state.logoutConnection
  if existing ~= false and existing[2] == true then
    return true
  end

  local ok, connection = pcall(function()
    local channel = createRegularChannel(LOGOUT_EVENT, "EventKit:ForAddon", 2)
    return connectToChannel(channel, function()
      local handler = state.closeOnLogout
      if type(handler) == "function" then
        handler()
      end
    end, true, false)
  end)
  if not ok then
    return false
  end
  state.logoutConnection = connection
  return true
end

---Decide who closes `scope` at logout, unless that is already decided.
---
---Called by `ForAddon` for every scope it returns, so the common case costs one
---field read.
---@param scope EventKit.Scope an addon scope
local function ensureLogoutRoute(scope)
  local route = scope._logoutRoute
  if (route ~= false and route ~= LOGOUT_ROUTE_NONE) or scope._closed == true then
    return
  end

  local LifecycleKit = findOptionalPackage("lifecycleKit", OPTIONAL_LIFECYCLE_KIT_API)
  if LifecycleKit ~= nil and lifecycleClosesAddonScopes(LifecycleKit) then
    -- LifecycleKit closes the scopes of the addons it has an instance for,
    -- so make sure this addon has one. Nothing is subscribed; a refusal
    -- only leaves the addon unknown to it.
    pcall(function()
      LifecycleKit:ForAddon(scope._addonName)
    end)
    scope._logoutRoute = LOGOUT_ROUTE_LIFECYCLE
    return
  end

  if ensureLogoutConnection() then
    scope._logoutRoute = LOGOUT_ROUTE_EVENT
    return
  end
  scope._logoutRoute = LOGOUT_ROUTE_NONE
end

-- Parts ------------------------------------------------------------------------
--
-- `ConnectUnit` and `OnceUnit` live in the Units part, `ConnectCombatLog` in
-- the CombatLog part, `Coalesce` and `Derive` in the Coalescing part
-- (docs/decisions/0001-kit-core-and-parts.md). What stays here is what the
-- core needs whether or not a part is loaded: the state each part fills
-- (unit groups and Frames, the combat-log router, the handles' metatables and
-- method tables), the stubs that stand in for an absent part's members, the
-- defaults of the `state.dispatch` and `state.composites` entries, and the
-- interface the parts read (`state.helpers`, `state.parts`,
-- `state.partInterface`).
--
-- Without its part no unit connection, route or Coalesce or Derive handle can
-- be made, so the defaults do nothing for objects of this revision. What
-- revision 22 left behind for an absent part is retired at the end of this
-- file, by code that only an upgrade from revision 22 runs.

---The fix-it message for `memberLabel` of a part that is not loaded.
---@param memberLabel string `EventKit:ConnectUnit`, `EventKit.Scope:Derive`...
---@param part string
---@return string
local function missingPartMessage(memberLabel, part)
  return memberLabel
    .. " is in EventKit's "
    .. part
    .. " part, which is not loaded: add "
    .. PART_FILES[part]
    .. " to embeds.xml after "
    .. CORE_FILE
end

---A stand-in for a member of `part`: present, so every copy's public-surface
---check still accepts the facade, and raising at the caller's line. The
---message is built only when the stub raises.
---@param memberLabel string
---@param part string
---@return function
local function newPartStub(memberLabel, part)
  return function()
    error(missingPartMessage(memberLabel, part), 2)
  end
end

---Whether the named part is installed in this session.
---@param name string
---@return boolean
local function isPartInstalled(name)
  return type(state.parts[name]) == "table"
end

---The default of `state.dispatchUnit`, `state.dispatchCombatLog` and the
---`state.dispatch` entries while their part is not loaded: no unit group or
---route of this revision exists then, so there is nothing to serve.
local function ignoreUnservedCall() end

---The `state.composites.close` default. A handle exists only when the
---Coalescing part made it; this one serves a handle of a part revision that
---predates the part's own `close` and loaded after this core. It stops the
---handle's events and leaves its scope; the part's timer callback ignores a
---closed handle.
---@param handle table
---@return boolean closed `false` when it was already closed.
local function closeCompositeEvents(handle)
  if handle._closed == true then
    return false
  end
  handle._closed = true
  unlinkFromScope(handle)
  local connections = handle._connections
  for index = 1, #connections do
    pcall(disconnectEventConnection, connections[index])
    connections[index] = nil
  end
  return true
end

---Whether the named part is installed in this session.
---@param _ EventKit
---@param name string a part name, such as `"Units"`
---@return boolean installed
local function hasPart(_, name)
  refuseSecret(name, "EventKit:HasPart name", 3)
  if type(name) ~= "string" then
    error("EventKit:HasPart name must be a part name string", 2)
  end
  return isPartInstalled(name)
end

-- Public API ----------------------------------------------------------------

---Subscribe to every future occurrence of `eventName`.
---@param _ EventKit
---@param eventName string
---@param callback EventKit.Listener
---@return EventKit.Connection connection
local function connectEvent(_, eventName, callback, methodName)
  local connection =
    subscribeRegular(false, "EventKit:Connect", 3, eventName, callback, false, methodName)
  return connection
end

---Subscribe to at most one future occurrence of `eventName`.
---@param _ EventKit
---@param eventName string
---@param callback EventKit.Listener
---@return EventKit.Connection connection
local function onceEvent(_, eventName, callback, methodName)
  local connection =
    subscribeRegular(false, "EventKit:Once", 3, eventName, callback, true, methodName)
  return connection
end

---Whether EventKit can read the combat log on this client, which is whether
---`ConnectCombatLog` can connect. `false` on clients that give addon code no
---reader, as Retail 12 does. Cheap and allocation-free: two table reads, so it
---may be asked at any time; the answer does not change within a session unless
---another addon installs a reader. See docs/API.md,
---"EventKit:IsCombatLogAvailable".
---@param _ EventKit
---@return boolean available
local function isCombatLogAvailable(_)
  return type(findCombatLogReader()) == "function"
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

  local addonScopes = state.addonScopes
  local scope = addonScopes[addonName]
  if scope == nil then
    scope = newScope(addonName)
    scope._logoutRoute = false
    addonScopes[addonName] = scope
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

  local scope = state.addonScopes[addonName]
  if scope == nil then
    return false
  end
  return closeScope(scope)
end

-- Limits --------------------------------------------------------------------
--
-- One limit, `maxUnitFrames`, which the Units part enforces. It stays here so
-- `SetLimits` and `GetLimits` keep one shape with or without the part. It
-- guards a resource the client never gives back, so it has a ceiling and no
-- `UNBOUNDED` value.

local LIMIT_RULES = {
  {
    name = "maxUnitFrames",
    ceiling = MAX_UNIT_FRAMES_CEILING,
    unboundedReason = "the client never frees a Frame",
  },
}

-- shared:begin limits 1 __FACADE__=EventKit
-- Copied from tooling/shared/lua/limits.lua by python3 -m tooling.shared.sync; edit that file, not this copy.
---Check a whole `SetLimits` update; raises at `level`.
---@type fun(limits: any, level: integer)
local validateLimitUpdate
---Write the names an update gives into `target`.
---@type fun(target: table, limits: table)
local applyLimitUpdate
---A fresh table of every limit in `source`.
---@type fun(source: table): table
local copyLimits
do
  local rulesByName = {}
  local names = {}
  for index = 1, #LIMIT_RULES do
    local rule = LIMIT_RULES[index]
    rulesByName[rule.name] = rule
    names[index] = rule.name
  end
  local accepted = table.concat(names, ", ")

  local function validateValue(rule, value, level)
    local where = "EventKit:SetLimits limits." .. rule.name
    if isSecret(value) then
      error(where .. " must not be a secret value", level)
    end
    if value == UNBOUNDED and UNBOUNDED ~= nil then
      if rule.unbounded then
        return
      end
      local reason = rule.unboundedReason and (": " .. rule.unboundedReason) or ""
      error(where .. " cannot be EventKit.UNBOUNDED" .. reason, level)
    end
    local minimum = rule.minimum or 1
    local integer = rule.integer ~= false
    if
      type(value) ~= "number"
      or value ~= value
      or value < minimum
      or value > rule.ceiling
      or (integer and value % 1 ~= 0)
    then
      local kind = integer and "an integer" or "a number"
      local range = " from " .. minimum .. " to " .. rule.ceiling
      error(where .. " must be " .. kind .. range, level)
    end
    if rule.check then
      rule.check(value, level + 1)
    end
  end

  validateLimitUpdate = function(limits, level)
    if isSecret(limits) or type(limits) ~= "table" then
      error("EventKit:SetLimits limits must be a table", level)
    end
    local key = next(limits)
    while type(key) ~= "nil" do
      local rule = type(key) == "string" and rulesByName[key] or nil
      if rule == nil then
        local named = "EventKit:SetLimits limits." .. describeKey(key)
        error(named .. " is not a recognised limit; it accepts " .. accepted, level)
      end
      validateValue(rule, rawget(limits, key), level + 1)
      key = next(limits, key)
    end
  end

  applyLimitUpdate = function(target, limits)
    for index = 1, #LIMIT_RULES do
      local name = LIMIT_RULES[index].name
      local value = rawget(limits, name)
      if type(value) ~= "nil" then
        rawset(target, name, value)
      end
    end
  end

  copyLimits = function(source)
    local copy = {}
    for index = 1, #LIMIT_RULES do
      local name = LIMIT_RULES[index].name
      copy[name] = rawget(source, name)
    end
    return copy
  end
end
-- shared:end limits

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
      "EventKit:SetLimits must be called on the EventKit facade; use EventKit:SetLimits(limits)",
      2
    )
  end
  validateLimitUpdate(limits, 3)
  applyLimitUpdate(sharedLimits, limits)
end

---Return a fresh copy of the shared limits. Allocates one table per call.
---@param self EventKit
---@return EventKit.Limits
local function getLimits(self)
  if type(self) ~= "table" or self ~= EventKit then
    error("EventKit:GetLimits must be called on the EventKit facade; use EventKit:GetLimits()", 2)
  end
  return copyLimits(sharedLimits)
end

-- Scope methods -------------------------------------------------------------

---Subscribe to every future occurrence of `eventName` inside this scope.
---@param self EventKit.Scope
---@param eventName string
---@param callback EventKit.Listener
---@return EventKit.Connection connection
local function scopeConnect(self, eventName, callback, methodName)
  validateScope(self, "EventKit.Scope:Connect", 3)
  ensureScopeOpen(self, "EventKit.Scope:Connect", 3)
  local connection =
    subscribeRegular(self, "EventKit.Scope:Connect", 3, eventName, callback, false, methodName)
  return connection
end

---Subscribe to at most one future occurrence of `eventName` inside this scope.
---@param self EventKit.Scope
---@param eventName string
---@param callback EventKit.Listener
---@return EventKit.Connection connection
local function scopeOnce(self, eventName, callback, methodName)
  validateScope(self, "EventKit.Scope:Once", 3)
  ensureScopeOpen(self, "EventKit.Scope:Once", 3)
  local connection =
    subscribeRegular(self, "EventKit.Scope:Once", 3, eventName, callback, true, methodName)
  return connection
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

local scopeReopen
do
  ---Move the members a closed scope still holds, because it was closed inside
  ---a dispatch and waits for the sweep, to a closed carrier scope that takes
  ---its place in the pending sweep. The scope is left with an empty list.
  ---@param scope EventKit.Scope
  local function handOverPendingSweep(scope)
    local carrier = setmetatable({
      _addonName = nil,
      _head = scope._head,
      _tail = scope._tail,
      _activeCount = scope._activeCount,
      _closed = true,
    }, SCOPE_METATABLE)
    local member = carrier._head
    while member ~= false do
      if member[2] ~= nil then
        member[5] = carrier
        member = member[7]
      else
        member._scope = carrier
        member = member._scopeNext
      end
    end
    scope._head = false
    scope._tail = false
    scope._activeCount = 0

    local pending = state.pendingScopes
    for index = 1, state.pendingScopeCount do
      if pending[index] == scope then
        pending[index] = carrier
      end
    end
  end

  ---Open a closed manual scope again, empty, so its owner can reuse the same
  ---object (ModuleKit keeps a module's scope across enable cycles this way).
  ---
  ---An addon scope stays closed: closing it is its addon's teardown. When the
  ---scope is closed inside a dispatch, the connections it held are still swept
  ---when the outermost dispatch returns, and the connections made after the
  ---reopen are not: the held ones move to a closed carrier scope that takes the
  ---scope's place in the pending sweep.
  ---@param self EventKit.Scope
  ---@return boolean reopened `false` when the scope was open.
  local function reopenScope(self)
    validateScope(self, "EventKit.Scope:Reopen", 3)
    if self._addonName ~= nil then
      error("EventKit.Scope:Reopen cannot reopen an addon scope", 2)
    end
    if self._closed ~= true then
      return false
    end
    if self._head ~= false then
      handOverPendingSweep(self)
    end
    self._closed = false
    return true
  end
  scopeReopen = reopenScope
end

---Return whether the scope is terminally closed.
---@param self EventKit.Scope
---@return boolean closed
local function scopeIsClosed(self)
  validateScope(self, "EventKit.Scope:IsClosed", 3)
  return self._closed == true
end

---Return the owning addon name, or `nil` for a manual scope.
---@param self EventKit.Scope
---@return string? addonName
local function scopeGetAddonName(self)
  validateScope(self, "EventKit.Scope:GetAddonName", 3)
  return self._addonName
end

---Return the number of live connections owned by this scope.
---@param self EventKit.Scope
---@return integer activeCount
local function scopeGetActiveCount(self)
  validateScope(self, "EventKit.Scope:GetActiveCount", 3)
  return self._activeCount
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
rawset(Scope, "DisconnectAll", scopeDisconnectAll)
rawset(Scope, "Close", scopeClose)
rawset(Scope, "IsClosed", scopeIsClosed)
rawset(Scope, "Reopen", scopeReopen)
rawset(Scope, "GetAddonName", scopeGetAddonName)
rawset(Scope, "GetActiveCount", scopeGetActiveCount)

rawset(EventKit, "API", API_GENERATION)
rawset(EventKit, "REVISION", IMPLEMENTATION_REVISION)
rawset(EventKit, "Connect", connectEvent)
rawset(EventKit, "Once", onceEvent)
rawset(EventKit, "IsCombatLogAvailable", isCombatLogAvailable)
rawset(EventKit, "CreateScope", createScope)
rawset(EventKit, "ForAddon", forAddon)
rawset(EventKit, "CloseAddonScopes", closeAddonScopes)
rawset(EventKit, "HasPart", hasPart)
rawset(EventKit, "UNBOUNDED", UNBOUNDED)
rawset(EventKit, "SetLimits", setLimits)
rawset(EventKit, "GetLimits", getLimits)
-- Revision 1's Frames read these; the floor leaves none, so revision 22's
-- copies of the fields go.
rawset(EventKit, "_DispatchRegular", nil)
rawset(EventKit, "_DispatchUnit", nil)

state.dispatchRegular = dispatchRegular
state.isolate = isolate
state.closeOnLogout = closeOnLogout
state.closeOnShutdown = nil

-- The core functions a part calls, always this revision's.
local helpers = state.helpers
helpers.isSecret = isSecret
helpers.refuseSecret = refuseSecret
helpers.describeKey = describeKey
helpers.validateEventName = validateEventName
helpers.refuseUnknownEvent = refuseUnknownEvent
helpers.validateCallback = validateCallback
helpers.bindMethod = bindMethod
helpers.validateScope = validateScope
helpers.ensureScopeOpen = ensureScopeOpen
helpers.requireFrameMethod = requireFrameMethod
helpers.createEventFrame = createEventFrame
helpers.newChannel = newChannel
helpers.createRegularChannel = createRegularChannel
helpers.connectToChannel = connectToChannel
helpers.disconnectEventConnection = disconnectEventConnection
helpers.deliverListeners = deliverListeners
helpers.fireChannel = fireChannel
helpers.findCombatLogReader = findCombatLogReader
helpers.linkToScope = linkToScope
helpers.unlinkFromScope = unlinkFromScope
helpers.reportListenerError = reportListenerError
helpers.missingPartMessage = missingPartMessage
-- Kept for a Coalescing part of revision 1, which closes its handles through
-- this entry; revision 2 owns `state.composites.close` itself.
helpers.closeCompositeHandle = function(handle)
  return state.composites.close(handle)
end

-- Each part's members. While a part is not installed they are stubs, and the
-- entries the core calls in it take their defaults. An installed part keeps
-- its own: it reads the helpers above at call time, so this core serves it.
local dispatchEntries = state.dispatch
if not isPartInstalled("Units") then
  rawset(Scope, "ConnectUnit", newPartStub("EventKit.Scope:ConnectUnit", "Units"))
  rawset(Scope, "OnceUnit", newPartStub("EventKit.Scope:OnceUnit", "Units"))
  rawset(EventKit, "ConnectUnit", newPartStub("EventKit:ConnectUnit", "Units"))
  rawset(EventKit, "OnceUnit", newPartStub("EventKit:OnceUnit", "Units"))
  state.dispatchUnit = ignoreUnservedCall
  dispatchEntries.releaseUnitGroup = ignoreUnservedCall
  -- The Coalescing part's `units` option builds unit channels through these.
  helpers.normalizeUnits = function(label, level)
    error(missingPartMessage(label .. ' option "units"', "Units"), level)
  end
  helpers.createUnitChannel = function(_, _, _, label, level)
    error(missingPartMessage(label .. ' option "units"', "Units"), level)
  end
end
if not isPartInstalled("CombatLog") then
  rawset(Scope, "ConnectCombatLog", newPartStub("EventKit.Scope:ConnectCombatLog", "CombatLog"))
  rawset(EventKit, "ConnectCombatLog", newPartStub("EventKit:ConnectCombatLog", "CombatLog"))
  state.dispatchCombatLog = ignoreUnservedCall
  dispatchEntries.releaseRoute = ignoreUnservedCall
end
local composites = state.composites
if not isPartInstalled("Coalescing") then
  rawset(Scope, "Coalesce", newPartStub("EventKit.Scope:Coalesce", "Coalescing"))
  rawset(Scope, "Derive", newPartStub("EventKit.Scope:Derive", "Coalescing"))
  rawset(EventKit, "Coalesce", newPartStub("EventKit:Coalesce", "Coalescing"))
  rawset(EventKit, "Derive", newPartStub("EventKit:Derive", "Coalescing"))
  composites.close = closeCompositeEvents
end

if not validatePublicSurface(EventKit) or not validateCurrentState(EventKit) then
  error("MoltenCodes EventKit package state is corrupted or incomplete", 2)
end

-- Revision 22 had unit events and the combat log in its core, so it may have
-- left unit groups or a combat-log router behind that a part now serves. When
-- that part is not loaded they cannot be served: they are retired
-- (disconnected, their Frames and registration given back) and the error
-- handler is told once which file to embed. The part an addon embeds loads
-- right after this core, so whether it is missing is decided on the next
-- frame; an event that reaches them first decides at once. This code runs
-- only for such an upgrade, so a fresh load keeps none of it resident.
if
  type(previousRevision) ~= "nil"
  and previousRevision < IMPLEMENTATION_REVISION
  and (next(state.unitGroups) ~= nil or state.combatLog.channel ~= false)
then
  ---Tell the error handler once per part that objects an earlier revision made
  ---were retired because `part` is not loaded.
  ---@param part string
  ---@param what string the objects, as the message names them
  local function reportRetired(part, what)
    local reported = state.retiredReported
    if type(reported) ~= "table" then
      reported = {}
      state.retiredReported = reported
    end
    if reported[part] == true then
      return
    end
    reported[part] = true
    reportListenerError(
      "MoltenCodes EventKit disconnected the "
        .. what
        .. " an earlier revision made: "
        .. missingPartMessage("their delivery", part)
    )
  end

  ---Mark every live connection of `fanOut` disconnected without the part's
  ---release code, leaving its scope. Never raises.
  ---@param fanOut EventKit.Channel|EventKit.CombatLogRoute
  local function retireListeners(fanOut)
    local listeners = fanOut.listeners
    for index = 1, #listeners do
      local connection = listeners[index]
      if connection[2] == true then
        connection[2] = false
        connection[1] = nil
        connection[4] = nil
        if connection[5] then
          unlinkFromScope(connection)
        end
      end
      listeners[index] = nil
    end
    fanOut.tombstones = 0
    fanOut.count = 0
    if fanOut.onceCount ~= nil then
      fanOut.onceCount = 0
    end
  end

  ---Retire the unit groups revision 22 left when the Units part is not loaded:
  ---disconnect their connections, unregister their events and put their Frames
  ---on the free list for a Units part loaded later.
  local function retireUnitGroups()
    if isPartInstalled("Units") or next(state.unitGroups) == nil then
      return
    end
    local retired = false
    for key, group in pairs(state.unitGroups) do
      state.unitGroups[key] = nil
      local frame = group.frame
      for eventName, channel in pairs(group.channels) do
        retired = retired or channel.count > 0
        retireListeners(channel)
        group.channels[eventName] = nil
        if frame ~= nil then
          pcall(requireFrameMethod(frame, "UnregisterEvent"), frame, eventName)
        end
      end
      if frame ~= nil then
        group.frame = nil
        pcall(requireFrameMethod(frame, "SetScript"), frame, "OnEvent", nil)
        local freeFrames = state.unitFrames
        freeFrames[#freeFrames + 1] = frame
      end
    end
    if retired then
      reportRetired("Units", "unit-event connections")
    end
  end

  ---Retire the combat-log routes revision 22 left when the CombatLog part is not
  ---loaded: disconnect their connections and give the router's share of the
  ---registration back.
  local function retireCombatLogRoutes()
    local combatLog = state.combatLog
    if isPartInstalled("CombatLog") or combatLog.channel == false then
      return
    end
    for subEvent, route in pairs(combatLog.routes) do
      retireListeners(route)
      combatLog.routes[subEvent] = nil
    end
    if combatLog.anyRoute ~= false then
      retireListeners(combatLog.anyRoute)
      combatLog.anyRoute = false
    end
    local inner = combatLog.inner
    combatLog.channel = false
    combatLog.inner = false
    combatLog.readEventInfo = false
    combatLog.listenerCount = 0
    if inner ~= false then
      pcall(disconnectEventConnection, inner)
    end
    reportRetired("CombatLog", "combat-log connections")
  end

  ---Retire what each absent part's revision-22 objects hold; reported, never
  ---raised, since it runs from a timer or an event.
  local function retireUnservedObjects()
    local ok, failure = pcall(retireUnitGroups)
    if not ok then
      reportListenerError(failure)
    end
    ok, failure = pcall(retireCombatLogRoutes)
    if not ok then
      reportListenerError(failure)
    end
  end

  if not isPartInstalled("Units") then
    state.dispatchUnit = retireUnservedObjects
  end
  if not isPartInstalled("CombatLog") then
    state.dispatchCombatLog = retireUnservedObjects
  end

  -- C_Timer is a World of Warcraft client API reachable only through the global table.
  -- selene: allow(global_usage)
  local timers = rawget(_G, "C_Timer")
  local newTimer = type(timers) == "table" and rawget(timers, "NewTimer") or nil
  if type(newTimer) == "function" then
    -- `NewTimer` rather than `After`: TimerKit relies on it on every flavour.
    newTimer(0, function()
      retireUnservedObjects()
    end)
  end
end

return EventKit
