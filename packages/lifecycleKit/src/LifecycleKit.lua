-- MoltenCodes LifecycleKit
--
-- Per-addon lifecycle coordination built on MoltenCodes EventKit and SignalKit.
-- LifecycleKit keeps WoW event details at the boundary and exposes replay-aware,
-- one-shot phase subscriptions for addon code.
--
-- Beside the four phases it owns two package-wide concerns every addon meets:
-- the combat gate (one shared lockdown state and a bounded per-addon "run when
-- out of combat" queue) and the halted state, in which an addon declares itself
-- non-functional and the addons that depend on it are told.
--
-- Contents
-- --------
--   Constants ............. package identity, state schema, default bounds
--   Public types .......... LuaCATS classes and aliases for the public surface
--   Dependencies .......... Registry, SignalKit, EventKit; TimerKit,
--                           SchedulerKit, HookKit, CommandKit and CommKit
--                           (optional)
--   Public-surface validation  facade shape accepted from other copies
--   Bootstrap ............. Registry registration, prototypes, package state,
--                           the combat-lockdown probe the state is seeded from
--   Host-state probes ..... addon load state, login
--   In-place upgrade ...... schema 2 to 3, retired fields, stale watchers
--   Subscription .......... the handle every subscription method returns
--   Signal dispatch ....... the error-capture protocol and callback wrappers
--   Combat queue .......... bounded FIFO of deferred calls, drain and close
--   Phase machinery ....... loaded, ready, shutdown and halted transitions
--   Combat state .......... the shared lockdown flag and its announcements
--   Shared event coordination  the package-wide host watchers
--   Instance creation ..... ForAddon's slow path
--   Public instance API ... queries, subscriptions, combat gate, halting
--   Public package API .... ForAddon, IsInCombat, SetLimits, GetLimits
--   Commit ................ prototype/facade assignment, the
--                           CLOSES_ADDON_SCOPES capability and self-check

local PACKAGE_NAME = "lifecycleKit"
local API_GENERATION = 1
local IMPLEMENTATION_REVISION = 14
local REQUIRED_REGISTRY_API = 2
local REQUIRED_SIGNAL_API = 1
local REQUIRED_EVENT_KIT_API = 1
-- TimerKit, SchedulerKit, HookKit, CommandKit and CommKit are optional: each is
-- found through `Registry:Find` at shutdown, so an addon that embeds none of
-- them shuts down exactly as before. TimerKit and SchedulerKit do not depend on
-- LifecycleKit; LifecycleKit calls into them (design constitution, 4b).
local OPTIONAL_TIMER_KIT_API = 1
local OPTIONAL_SCHEDULER_KIT_API = 1
local OPTIONAL_HOOK_KIT_API = 1
local OPTIONAL_COMMAND_KIT_API = 1
local OPTIONAL_COMM_KIT_API = 1

-- The package ids whose addon scopes (for SignalKit, the addon bus) shutdown
-- closes, in `closeAddonOwnedScopes` order. Published read-only as
-- `LifecycleKit.CLOSES_ADDON_SCOPES`: a scope-owning Kit reads it to decide
-- whether LifecycleKit covers its addon scopes at logout or whether it has to
-- arrange that itself. An older revision without the field closes none of
-- them as far as such a reader is concerned. Every revision from 13 on
-- publishes the same set; a revision that stops closing one of them has to
-- drop it from this list.
local CLOSED_ADDON_SCOPE_PACKAGES = {
    "timerKit",
    "schedulerKit",
    "eventKit",
    "hookKit",
    "commandKit",
    "commKit",
    "signalKit",
}

-- Schema 3 added the combat state (`inCombat`) and the creation-ordered
-- instance list (`instances`). Schema 2 state is migrated in place.
local STATE_SCHEMA = 3
local PREVIOUS_STATE_SCHEMA = 2

-- How many deferred calls one addon may have waiting for the end of combat,
-- unless changed. `SetLimits{ defaultCombatQueueLimit = ... }` changes the
-- value new instances start with; an addon changes its own with
-- `SetCombatQueueLimit`. Both accept `LifecycleKit.UNBOUNDED`: the queue holds
-- that addon's own callbacks and nothing else's (design constitution, 4a).
local DEFAULT_COMBAT_QUEUE_LIMIT = 64

-- How many other addons one addon may declare with `DependsOn`, unless changed
-- through `SetLimits{ maxDependencies = ... }`, which also accepts
-- `LifecycleKit.UNBOUNDED`: the list is the declaring addon's own.
local DEFAULT_MAX_DEPENDENCIES = 16

-- Names `SetLimits` recognises, in the order `GetLimits` reads them.
local LIMIT_NAMES = { "maxDependencies", "defaultCombatQueueLimit" }

-- The combat queue of an `UNBOUNDED` addon is compacted once its array holds
-- this many slots and at least twice as many as are still pending, so
-- reclaiming cancelled slots stays amortised constant time per call.
local UNBOUNDED_COMPACTION_FLOOR = DEFAULT_COMBAT_QUEUE_LIMIT

-- Public types --------------------------------------------------------------
--
-- LifecycleKit publishes its methods by writing them onto Registry-owned
-- prototype tables, so the editor-facing contract is declared here as LuaCATS
-- classes rather than inferred from those assignments.

---Lifecycle state reported by `Instance:GetState()`.
---@alias LifecycleKit.State
---| "loading"   # the addon's `ADDON_LOADED` has not been observed yet
---| "loaded"    # `ADDON_LOADED` completed for this addon
---| "ready"     # the addon is loaded and the player is logged in
---| "shutdown"  # `PLAYER_LOGOUT` was observed
---| "halted"    # the addon called `Halt`; terminal for the session

---A callback invoked once for the phase it subscribed to.
---@alias LifecycleKit.PhaseCallback fun(instance: LifecycleKit.Instance)

---A callback invoked once when the addon halts.
---@alias LifecycleKit.HaltedCallback fun(instance: LifecycleKit.Instance, reason: string)

---A callback invoked each time a declared dependency halts.
---@alias LifecycleKit.DependencyHaltedCallback fun(instance: LifecycleKit.Instance, dependencyName: string, reason: string)

---A callback invoked on every combat start or combat end.
---@alias LifecycleKit.CombatCallback fun(instance: LifecycleKit.Instance)

---A deferred call: `ran` is `true` when it ran out of combat, and `false` with
---a reason when the queue was closed before it could run.
---@alias LifecycleKit.DeferredCallback fun(instance: LifecycleKit.Instance, ran: boolean, reason: "shutdown"|"halted"|nil)

---An error object wrapped so that `nil` and `false` stay representable.
---@class LifecycleKit.ErrorRecord
---@field value any the original Lua error object

---The per-addon lifecycle handle returned by `LifecycleKit:ForAddon`.
---@class LifecycleKit.Instance
---@field GetAddonName fun(self: LifecycleKit.Instance): string
---@field GetState fun(self: LifecycleKit.Instance): LifecycleKit.State
---@field IsLoaded fun(self: LifecycleKit.Instance): boolean
---@field IsReady fun(self: LifecycleKit.Instance): boolean
---@field IsShutdown fun(self: LifecycleKit.Instance): boolean
---@field IsHalted fun(self: LifecycleKit.Instance): boolean
---@field GetHaltReason fun(self: LifecycleKit.Instance): string|nil
---@field OnLoaded fun(self: LifecycleKit.Instance, callback: LifecycleKit.PhaseCallback): LifecycleKit.Subscription
---@field OnReady fun(self: LifecycleKit.Instance, callback: LifecycleKit.PhaseCallback): LifecycleKit.Subscription
---@field OnShutdown fun(self: LifecycleKit.Instance, callback: LifecycleKit.PhaseCallback): LifecycleKit.Subscription
---@field OnHalted fun(self: LifecycleKit.Instance, callback: LifecycleKit.HaltedCallback): LifecycleKit.Subscription
---@field Halt fun(self: LifecycleKit.Instance, reason: string): boolean
---@field DependsOn fun(self: LifecycleKit.Instance, addonName: string): boolean|nil, string|nil
---@field OnDependencyHalted fun(self: LifecycleKit.Instance, callback: LifecycleKit.DependencyHaltedCallback): LifecycleKit.Subscription
---@field WhenOutOfCombat fun(self: LifecycleKit.Instance, callback: LifecycleKit.DeferredCallback): LifecycleKit.DeferredCall|nil, string|nil
---@field OnCombatStart fun(self: LifecycleKit.Instance, callback: LifecycleKit.CombatCallback): LifecycleKit.Subscription
---@field OnCombatEnd fun(self: LifecycleKit.Instance, callback: LifecycleKit.CombatCallback): LifecycleKit.Subscription
---@field SetCombatQueueLimit fun(self: LifecycleKit.Instance, limit: integer|table)
---@field GetCombatQueueLimit fun(self: LifecycleKit.Instance): integer|table

---A subscription handle: one-shot for phases, repeating for combat and
---dependency notifications.
---@class LifecycleKit.Subscription
---@field Disconnect fun(self: LifecycleKit.Subscription): boolean
---@field IsConnected fun(self: LifecycleKit.Subscription): boolean

---A call waiting in an addon's combat queue.
---@class LifecycleKit.DeferredCall
---@field Cancel fun(self: LifecycleKit.DeferredCall): boolean
---@field IsPending fun(self: LifecycleKit.DeferredCall): boolean

---The LifecycleKit package facade published through Registry.
---@class LifecycleKit
---@field API integer Public API generation.
---@field REVISION integer Compatible implementation revision.
---@field Instance LifecycleKit.Instance Shared lifecycle-instance prototype.
---@field Subscription LifecycleKit.Subscription Shared subscription prototype.
---@field DeferredCall LifecycleKit.DeferredCall Shared deferred-call prototype.
---@field ForAddon fun(self: LifecycleKit, addonName: string): LifecycleKit.Instance
---@field IsInCombat fun(self: LifecycleKit): boolean
---@field UNBOUNDED table Sentinel a limit takes to be lifted.
---@field SetLimits fun(self: LifecycleKit, limits: table)
---@field GetLimits fun(self: LifecycleKit): LifecycleKit.Limits
---@field CLOSES_ADDON_SCOPES table<string, boolean> Read-only set of the package ids whose addon scopes (or, for `signalKit`, bus) shutdown closes.

---The package-wide limits. `SetLimits` accepts any subset; `GetLimits` returns
---a fresh copy of all of them.
---@class LifecycleKit.Limits
---@field maxDependencies integer|table Addons one addon may declare with `DependsOn`: a positive integer or `LifecycleKit.UNBOUNDED`; default `16`.
---@field defaultCombatQueueLimit integer|table The combat-queue limit new instances start with: a positive integer or `LifecycleKit.UNBOUNDED`; default `64`.

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
    error("MoltenCodes LifecycleKit requires Registry API 2 to be loaded first", 2)
end

local bootstrapPackage = rawget(Registry, "Bootstrap")
local getPackage = rawget(Registry, "Get")
if type(bootstrapPackage) ~= "function" or type(getPackage) ~= "function" then
    error("MoltenCodes LifecycleKit requires a valid Registry API 2 facade", 2)
end

local SignalKit, signalRevision = getPackage(Registry, "signalKit", REQUIRED_SIGNAL_API)
if type(SignalKit) == "nil" then
    error("MoltenCodes LifecycleKit requires SignalKit API 1 to be loaded first", 2)
end
local SignalKitConnection = type(SignalKit) == "table" and rawget(SignalKit, "Connection") or nil
if
    type(SignalKit) ~= "table"
    or type(signalRevision) ~= "number"
    or rawget(SignalKit, "API") ~= REQUIRED_SIGNAL_API
    or rawget(SignalKit, "REVISION") ~= signalRevision
    or type(rawget(SignalKit, "New")) ~= "function"
    or type(rawget(SignalKit, "Once")) ~= "function"
    or type(rawget(SignalKit, "Fire")) ~= "function"
    or type(rawget(SignalKit, "DisconnectAll")) ~= "function"
    or type(SignalKitConnection) ~= "table"
    or type(rawget(SignalKitConnection, "Disconnect")) ~= "function"
    or type(rawget(SignalKitConnection, "IsConnected")) ~= "function"
then
    error("MoltenCodes LifecycleKit requires a valid SignalKit API 1 facade", 2)
end

local EventKit, eventKitRevision = getPackage(Registry, "eventKit", REQUIRED_EVENT_KIT_API)
if type(EventKit) == "nil" then
    error("MoltenCodes LifecycleKit requires EventKit API 1 to be loaded first", 2)
end
local EventKitConnection = type(EventKit) == "table" and rawget(EventKit, "Connection") or nil
if
    type(EventKit) ~= "table"
    or type(eventKitRevision) ~= "number"
    or rawget(EventKit, "API") ~= REQUIRED_EVENT_KIT_API
    or rawget(EventKit, "REVISION") ~= eventKitRevision
    or type(rawget(EventKit, "Connect")) ~= "function"
    or type(rawget(EventKit, "Once")) ~= "function"
    or type(EventKitConnection) ~= "table"
    or type(rawget(EventKitConnection, "Disconnect")) ~= "function"
then
    error("MoltenCodes LifecycleKit requires a valid EventKit API 1 facade", 2)
end

---Silent lookup of an optional dependency.
---
---Registry revision 7 added `Find`; an older Registry's `Get` also returns
---`nil` for a missing package, so it is a correct fallback. The method is read
---on every call because an embedded Registry upgrade replaces it in place.
---@param packageName string
---@param api integer
---@return table|nil implementation `nil` when the package is not loaded
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

-- Public-surface validation --------------------------------------------------

-- Every method a compatible copy must publish on the instance prototype.
local INSTANCE_METHODS = {
    "GetAddonName",
    "GetState",
    "IsLoaded",
    "IsReady",
    "IsShutdown",
    "IsHalted",
    "GetHaltReason",
    "OnLoaded",
    "OnReady",
    "OnShutdown",
    "OnHalted",
    "Halt",
    "DependsOn",
    "OnDependencyHalted",
    "WhenOutOfCombat",
    "OnCombatStart",
    "OnCombatEnd",
    "SetCombatQueueLimit",
    "GetCombatQueueLimit",
}

---Whether every name in `methodNames` is a function on `prototype`.
---@param prototype table
---@param methodNames string[]
---@return boolean
local function hasMethods(prototype, methodNames)
    for index = 1, #methodNames do
        if type(rawget(prototype, methodNames[index])) ~= "function" then
            return false
        end
    end
    return true
end

---Whether `implementation` exposes the complete LifecycleKit API 1 surface.
---@param implementation any shared package table handed back by Registry
---@return boolean
local function validatePublicSurface(implementation)
    if
        type(implementation) ~= "table"
        or rawget(implementation, "API") ~= API_GENERATION
        or type(rawget(implementation, "REVISION")) ~= "number"
        or type(rawget(implementation, "Instance")) ~= "table"
        or type(rawget(implementation, "Subscription")) ~= "table"
        or type(rawget(implementation, "DeferredCall")) ~= "table"
        or type(rawget(implementation, "ForAddon")) ~= "function"
        or type(rawget(implementation, "IsInCombat")) ~= "function"
        or type(rawget(implementation, "UNBOUNDED")) ~= "table"
        or type(rawget(implementation, "SetLimits")) ~= "function"
        or type(rawget(implementation, "GetLimits")) ~= "function"
        or type(rawget(implementation, "CLOSES_ADDON_SCOPES")) ~= "table"
    then
        return false
    end

    local Subscription = rawget(implementation, "Subscription")
    local DeferredCall = rawget(implementation, "DeferredCall")
    return hasMethods(rawget(implementation, "Instance"), INSTANCE_METHODS)
        and type(rawget(Subscription, "Disconnect")) == "function"
        and type(rawget(Subscription, "IsConnected")) == "function"
        and type(rawget(DeferredCall, "Cancel")) == "function"
        and type(rawget(DeferredCall, "IsPending")) == "function"
end

---Whether the client reports `value` as secret; always `false` elsewhere.
---
---On a client with secret values, comparing a secret with a value of its own
---type, or using it as a key, raises inside LifecycleKit instead of at the
---caller. Values LifecycleKit did not create are tested for absence with
---`type(value) == "nil"`, the repository rule, and a secret is refused first.
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

---Whether `value` is a positive integer or the `UNBOUNDED` sentinel `sentinel`.
---@param value any
---@param sentinel table
---@return boolean
local function isLimitValue(value, sentinel)
    if value == sentinel then
        return true
    end
    return type(value) == "number"
        and value >= 1
        and value ~= math.huge
        and math.floor(value) == value
end

---Whether `currentState` carries the `UNBOUNDED` sentinel and a valid set of
---package-wide limits (added in revision 12 without a schema change).
---@param currentState table
---@return boolean
local function validateLimitState(currentState)
    local sentinel = rawget(currentState, "unbounded")
    local limits = rawget(currentState, "limits")
    if type(sentinel) ~= "table" or type(limits) ~= "table" then
        return false
    end
    for index = 1, #LIMIT_NAMES do
        if not isLimitValue(rawget(limits, LIMIT_NAMES[index]), sentinel) then
            return false
        end
    end
    return true
end

---Whether `currentState` carries the addon-scope capability set and its
---read-only view (added in revision 13 without a schema change).
---@param currentState table
---@return boolean
local function validateCapabilityState(currentState)
    local capabilities = rawget(currentState, "addonScopeCapabilities")
    return type(capabilities) == "table"
        and type(rawget(capabilities, "entries")) == "table"
        and type(rawget(capabilities, "view")) == "table"
end

---Whether `implementation` carries package state of this revision's schema.
---@param implementation table
---@return boolean
local function validateCurrentState(implementation)
    local currentState = rawget(implementation, "_state")
    return type(currentState) == "table"
        and validateLimitState(currentState)
        and validateCapabilityState(currentState)
        and rawget(currentState, "schema") == STATE_SCHEMA
        and type(rawget(currentState, "addons")) == "table"
        and type(rawget(currentState, "instances")) == "table"
        and type(rawget(currentState, "globalWatchers")) == "table"
        and type(rawget(currentState, "loginSeen")) == "boolean"
        and type(rawget(currentState, "shutdownSeen")) == "boolean"
        and type(rawget(currentState, "inCombat")) == "boolean"
end

-- Bootstrap -----------------------------------------------------------------
--
-- `Registry:Bootstrap` owns the reconciliation every embedded package repeats:
-- look the package up, refuse to reinterpret state owned by a newer revision,
-- and register this one. What stays here is what only LifecycleKit can answer.
--
-- LifecycleKit always resumes a copy that carries its own revision. Its shared
-- host watchers live outside the package state this file validates, so a
-- previous live upgrade can have committed the Registry revision and then
-- failed while installing them. Re-running the rest of this file against the
-- stable facade is idempotent and repairs that incomplete runtime setup; the
-- state checks below still reject a facade whose package state is unusable.
local LifecycleKit, previousRevision, selected = bootstrapPackage(Registry, {
    package = PACKAGE_NAME,
    api = API_GENERATION,
    revision = IMPLEMENTATION_REVISION,
    label = "MoltenCodes LifecycleKit",
    validatePublicSurface = validatePublicSurface,
    resume = function()
        return IMPLEMENTATION_REVISION
    end,
})

if type(LifecycleKit) == "nil" then
    -- A newer compatible embedded revision already owns the package.
    return selected
end

-- Past this point the facade is always a table: Registry handed back the one
-- this copy fills in, whether fresh, inherited from an older revision or
-- resumed at this revision.
---@cast LifecycleKit table

-- Registry keeps the identity of the prototype tables below stable across
-- compatible embedded revisions, so instances created by an older copy observe
-- newer methods.
local Instance = rawget(LifecycleKit, "Instance")
local Subscription = rawget(LifecycleKit, "Subscription")
local DeferredCall = rawget(LifecycleKit, "DeferredCall")

local state = rawget(LifecycleKit, "_state")

-- Whether this copy upgrades state an older revision created. Revision 6 and
-- earlier wrote schema 2, which `migrateState` below brings to schema 3.
local upgradesOlderRevision = type(previousRevision) ~= "nil"
    and previousRevision < IMPLEMENTATION_REVISION

---Report whether the host says combat lockdown is active.
---
---Declared before the package state because a first bootstrap seeds the
---shared combat flag from it.
---@return boolean
local function isHostInCombatLockdown()
    -- InCombatLockdown is a World of Warcraft client API reachable only through the global table.
    -- selene: allow(global_usage)
    local probe = rawget(_G, "InCombatLockdown")
    return type(probe) == "function" and probe() == true
end

if type(previousRevision) == "nil" then
    if Instance ~= nil or Subscription ~= nil or DeferredCall ~= nil or state ~= nil then
        error("MoltenCodes LifecycleKit package state is corrupted or incomplete", 2)
    end

    Instance = {}
    Subscription = {}
    DeferredCall = {}
    state = {
        schema = STATE_SCHEMA,
        -- addonName -> instance, for lookup by name.
        addons = {},
        -- Every instance, in creation order for instances this revision
        -- created (an upgrade appends inherited ones in name order): the
        -- allocation-free iteration order of the combat announcements, which
        -- run on every combat.
        instances = {},
        globalWatchers = {},
        loginSeen = false,
        shutdownSeen = false,
        -- The one lockdown state every addon shares. The host may load an
        -- addon mid-combat, so it starts from the host's own answer.
        inCombat = isHostInCombatLockdown(),
        -- `LifecycleKit.UNBOUNDED`. It lives in the state so that every
        -- revision publishes the same table and a comparison against it keeps
        -- working across an upgrade.
        unbounded = {},
        -- The package-wide limits `SetLimits` writes; a newer copy inherits
        -- what a consumer set.
        limits = {
            maxDependencies = DEFAULT_MAX_DEPENDENCIES,
            defaultCombatQueueLimit = DEFAULT_COMBAT_QUEUE_LIMIT,
        },
    }

    rawset(LifecycleKit, "Instance", Instance)
    rawset(LifecycleKit, "Subscription", Subscription)
    rawset(LifecycleKit, "DeferredCall", DeferredCall)
    rawset(LifecycleKit, "_state", state)
else
    -- An embedded copy is reusing state another copy created. The prototype
    -- for deferred calls is new in revision 7, so only an upgrade may lack it.
    if DeferredCall == nil and upgradesOlderRevision then
        DeferredCall = {}
        rawset(LifecycleKit, "DeferredCall", DeferredCall)
    end
    if
        type(Instance) ~= "table"
        or type(Subscription) ~= "table"
        or type(DeferredCall) ~= "table"
        or type(state) ~= "table"
    then
        error("MoltenCodes LifecycleKit package state is corrupted or incomplete", 2)
    end
end

-- Revision 12 added the `UNBOUNDED` sentinel and the package-wide limits
-- without changing the schema. State an older revision wrote is seeded with
-- the defaults those revisions enforced as constants, so behaviour carries
-- over unchanged until a consumer calls `SetLimits`.
if type(state) == "table" then
    if rawget(state, "unbounded") == nil then
        rawset(state, "unbounded", {})
    end
    if rawget(state, "limits") == nil then
        rawset(state, "limits", {
            maxDependencies = DEFAULT_MAX_DEPENDENCIES,
            defaultCombatQueueLimit = DEFAULT_COMBAT_QUEUE_LIMIT,
        })
    end
end
local UNBOUNDED = rawget(state, "unbounded")
local sharedLimits = rawget(state, "limits")

---Refuse every write to `LifecycleKit.CLOSES_ADDON_SCOPES`.
---
---The view holds no keys of its own, so `__newindex` sees every assignment,
---including one that would overwrite an existing entry.
---@param _ table
---@param key any
local function refuseCapabilityWrite(_, key)
    error(
        'LifecycleKit.CLOSES_ADDON_SCOPES is read-only; field "'
            .. tostring(key)
            .. '" cannot be written',
        2
    )
end

-- Revision 13 publishes `CLOSES_ADDON_SCOPES` without a schema change. The
-- entries and the read-only view over them live in the state, so every
-- revision from 13 on hands out the same table and a reader that kept it
-- across an upgrade still reads the current set. The entries are rewritten on
-- every bootstrap, so they always describe the copy that is running.
if rawget(state, "addonScopeCapabilities") == nil then
    local entries = {}
    rawset(state, "addonScopeCapabilities", {
        entries = entries,
        view = setmetatable({}, {
            __index = entries,
            __newindex = refuseCapabilityWrite,
            __metatable = false,
        }),
    })
end
local addonScopeCapabilities = rawget(state, "addonScopeCapabilities")
local CLOSES_ADDON_SCOPES = rawget(addonScopeCapabilities, "view")

local INSTANCE_METATABLE = { __index = Instance }
local SUBSCRIPTION_METATABLE = { __index = Subscription }
local DEFERRED_CALL_METATABLE = { __index = DeferredCall }

-- Host-state probes ---------------------------------------------------------

---Report whether `ADDON_LOADED` has already completed for `addonName`.
---
---Both the modern and the legacy host API return `(loaded, finished)`: an addon
---that is mid-load answers `true, false`. Only the second value confirms that
---the `ADDON_LOADED` transition finished, so only that value is trusted here.
---@param addonName string
---@return boolean
local function isAddonFinishedLoading(addonName)
    -- C_AddOns is a World of Warcraft client API reachable only through the global table.
    -- selene: allow(global_usage)
    local addonsApi = rawget(_G, "C_AddOns")
    local modern = type(addonsApi) == "table" and rawget(addonsApi, "IsAddOnLoaded") or nil
    if type(modern) == "function" then
        local _, finished = modern(addonName)
        return finished == true
    end

    -- Legacy IsAddOnLoaded exposes loading and finished states separately.
    -- Only the second return confirms that ADDON_LOADED already completed.
    -- Legacy IsAddOnLoaded is a World of Warcraft client global kept for older clients.
    -- selene: allow(global_usage)
    local legacy = rawget(_G, "IsAddOnLoaded")
    if type(legacy) == "function" then
        local _, finished = legacy(addonName)
        return finished == true
    end

    return false
end

---Report whether the host says the player is already logged in.
---@return boolean
local function isPlayerLoggedIn()
    -- IsLoggedIn is a World of Warcraft client API reachable only through the global table.
    -- selene: allow(global_usage)
    local probe = rawget(_G, "IsLoggedIn")
    return type(probe) == "function" and probe() == true
end

-- In-place upgrade ----------------------------------------------------------

---Give `instance` the per-instance fields revision 7 introduced.
---
---Used for a new instance and for every instance an older revision hands
---over, so both carry exactly the same shape.
---@param instance table
local function installGateFields(instance)
    local signals = rawget(instance, "_signals")
    if type(signals) ~= "table" then
        error("MoltenCodes LifecycleKit instance state is corrupted or incomplete", 2)
    end

    rawset(signals, "halted", SignalKit:New())
    rawset(signals, "dependencyHalted", SignalKit:New())
    rawset(signals, "combatStart", SignalKit:New())
    rawset(signals, "combatEnd", SignalKit:New())

    rawset(instance, "_halted", false)
    rawset(instance, "_dependencies", {})
    -- The combat queue is an array of deferred-call handles reused across
    -- combats. `_combatQueueLength` is its end index, `_combatPending` the
    -- number of slots still waiting; cancelled slots stay in place until the
    -- next compaction so cancelling never allocates or shifts.
    rawset(instance, "_combatQueue", {})
    rawset(instance, "_combatQueueLength", 0)
    rawset(instance, "_combatPending", 0)
    rawset(instance, "_combatQueueLimit", rawget(sharedLimits, "defaultCombatQueueLimit"))
    rawset(instance, "_draining", false)
    -- One reusable capture record per combat signal keeps the per-combat
    -- announcements free of allocation.
    rawset(instance, "_combatCaptures", {
        combatStart = { active = false, failed = false },
        combatEnd = { active = false, failed = false },
    })
end

---Return every instance in `addons`, ordered by addon name.
---@param addons table<string, table>
---@return table[]
local function sortedInstances(addons)
    local names = {}
    for addonName in pairs(addons) do
        names[#names + 1] = addonName
    end
    table.sort(names)

    local ordered = {}
    for index = 1, #names do
        local instance = rawget(addons, names[index])
        if type(instance) ~= "table" then
            error("MoltenCodes LifecycleKit package state is corrupted or incomplete", 2)
        end
        ordered[index] = instance
    end
    return ordered
end

---Disconnect every shared host watcher an older revision installed.
---
---A watcher calls the handler of the revision that connected it, so leaving
---an older one in place would keep running that revision's phase machinery,
---which knows nothing of halting or of the combat queue. The bootstrap tail
---installs this revision's watchers again and reconciles any one-shot phase
---that passed in between.
local function disconnectInheritedWatchers()
    local watchers = rawget(state, "globalWatchers")
    if type(watchers) ~= "table" then
        return
    end

    for key, connection in pairs(watchers) do
        rawset(watchers, key, nil)
        if type(connection) == "table" and type(connection.Disconnect) == "function" then
            connection:Disconnect()
        end
    end
end

---Bring state an older compatible revision created to this revision's shape.
---
---Every older revision's shared host watchers are replaced, because a watcher
---keeps calling the handler of the revision that connected it: revision 7's
---logout handler, for one, closes no HookKit scope and no SignalKit bus,
---revision 8's closes no CommandKit scope, revision 9's no CommKit scope, and
---no revision before 12 closes a TimerKit or SchedulerKit scope. Revision
---10's and 11's watchers are replaced for the same reason, so the running
---handlers are always the newest copy's. The bootstrap tail installs this
---revision's watchers again and reconciles any one-shot phase that passed in
---between. Revisions 7 to 11 already wrote schema 3, so that is all their
---state needs.
---
---Schema 2 (revisions 4 to 6) lacks the combat flag, the instance list and
---every per-instance field of the combat gate and the halted state. Revision 3
---also kept a second, redundant phase-error slot (`_phaseErrors`) beside
---`_phaseCaptures`; it is released here rather than retained for the session.
---
---Pending phase subscriptions created by the older revision stay valid: their
---wrappers report a callback failure through `_phaseCaptures`, whose record
---shape is unchanged.
local function migrateState()
    if not upgradesOlderRevision then
        return
    end
    if rawget(state, "schema") == STATE_SCHEMA then
        disconnectInheritedWatchers()
        return
    end
    if
        rawget(state, "schema") ~= PREVIOUS_STATE_SCHEMA
        or type(rawget(state, "addons")) ~= "table"
    then
        -- Left for `validateCurrentState` to reject with the standard message.
        return
    end

    local instances = sortedInstances(rawget(state, "addons"))
    for index = 1, #instances do
        local instance = instances[index]
        rawset(instance, "_phaseErrors", nil)
        installGateFields(instance)
    end

    disconnectInheritedWatchers()

    rawset(state, "instances", instances)
    rawset(state, "inCombat", isHostInCombatLockdown())
    rawset(state, "schema", STATE_SCHEMA)
end

migrateState()

if not validateCurrentState(LifecycleKit) then
    error("MoltenCodes LifecycleKit package state is corrupted or incomplete", 2)
end

-- Subscription --------------------------------------------------------------

---Return a subscription handle that is already spent.
---@return LifecycleKit.Subscription
local function newDisconnectedSubscription()
    return setmetatable({
        _connected = false,
        _inner = nil,
    }, SUBSCRIPTION_METATABLE)
end

---Report whether this subscription is still pending delivery.
---@param self LifecycleKit.Subscription
---@return boolean
local function isSubscriptionConnected(self)
    if rawget(self, "_connected") ~= true then
        return false
    end

    local inner = rawget(self, "_inner")
    if inner == nil or inner:IsConnected() ~= true then
        -- SignalKit may disconnect the inner listener as part of terminal
        -- cleanup. Keep the public LifecycleKit subscription in sync.
        rawset(self, "_connected", false)
        rawset(self, "_inner", nil)
        return false
    end

    return true
end

---Cancel a pending subscription.
---@param self LifecycleKit.Subscription
---@return boolean changed `true` only when a pending subscription became disconnected
local function disconnectSubscription(self)
    if not isSubscriptionConnected(self) then
        return false
    end

    local inner = rawget(self, "_inner")
    rawset(self, "_connected", false)
    rawset(self, "_inner", nil)
    inner:Disconnect()
    return true
end

-- Signal dispatch -------------------------------------------------------------
--
-- Every notification LifecycleKit delivers — a phase, a halt, a combat change,
-- a halted dependency — goes through one error-capture protocol. While a
-- signal fires, `_phaseCaptures[signalKey]` holds a capture record; each
-- subscriber wrapper records the first callback failure into it and returns,
-- so dispatch continues and one failing subscriber cannot starve the rest. The
-- caller re-raises the captured error once its own state is committed.

---@param value any
---@return LifecycleKit.ErrorRecord
local function newErrorRecord(value)
    return { value = value }
end

---Return the per-signal error-capture map of `instance`, creating it on demand.
---@param instance LifecycleKit.Instance
---@return table<string, table>
local function getPhaseCaptures(instance)
    local captures = rawget(instance, "_phaseCaptures")
    if captures == nil then
        captures = {}
        rawset(instance, "_phaseCaptures", captures)
    elseif type(captures) ~= "table" then
        error("MoltenCodes LifecycleKit instance state is corrupted or incomplete", 2)
    end
    return captures
end

---Fire one of `instance`'s signals under the capture protocol.
---
---The capture that was installed for `signalKey` before this call is restored
---afterwards, so a nested dispatch of the same signal records into its own
---record and hands the outer one back intact.
---@param instance LifecycleKit.Instance
---@param signalKey string
---@param capture table capture record to install for the duration of the fire
---@param first any second argument delivered to subscribers
---@param second any third argument delivered to subscribers
---@return LifecycleKit.ErrorRecord|nil errorRecord first captured error, wrapped so that `nil` and `false` stay representable
local function fireSignal(instance, signalKey, capture, first, second)
    local signal = rawget(rawget(instance, "_signals"), signalKey)
    local captures = getPhaseCaptures(instance)
    local enclosing = rawget(captures, signalKey)

    rawset(capture, "active", true)
    rawset(capture, "failed", false)
    rawset(capture, "value", nil)
    rawset(captures, signalKey, capture)

    local ok, signalError = pcall(rawget(SignalKit, "Fire"), signal, instance, first, second)

    rawset(capture, "active", false)
    rawset(captures, signalKey, enclosing)

    if not ok then
        return newErrorRecord(signalError)
    end
    if rawget(capture, "failed") == true then
        local value = rawget(capture, "value")
        rawset(capture, "value", nil)
        return newErrorRecord(value)
    end
    return nil
end

---Fire a one-shot or rare signal with a fresh capture record.
---@param instance LifecycleKit.Instance
---@param signalKey string
---@param first any
---@param second any
---@return LifecycleKit.ErrorRecord|nil
local function firePhase(instance, signalKey, first, second)
    return fireSignal(instance, signalKey, { active = false, failed = false }, first, second)
end

---Fire a combat signal with the instance's reusable capture record.
---
---A combat signal fires on every combat, so it must not allocate. Only a
---nested dispatch of the same signal, whose record is still active, falls back
---to a fresh one.
---@param instance LifecycleKit.Instance
---@param signalKey "combatStart"|"combatEnd"
---@return LifecycleKit.ErrorRecord|nil
local function fireCombatSignal(instance, signalKey)
    local capture = rawget(rawget(instance, "_combatCaptures"), signalKey)
    if rawget(capture, "active") == true then
        capture = { active = false, failed = false }
    end
    return fireSignal(instance, signalKey, capture, nil, nil)
end

---Record a subscriber failure into the active capture for `signalKey`.
---@param instance LifecycleKit.Instance
---@param signalKey string
---@param message any the original Lua error object
local function recordCallbackFailure(instance, signalKey, message)
    local capture = rawget(getPhaseCaptures(instance), signalKey)
    if type(capture) == "table" and rawget(capture, "active") == true then
        if rawget(capture, "failed") ~= true then
            -- Preserve the first callback failure, including false or nil
            -- error objects, while keeping dispatch alive for every subscriber
            -- of this signal.
            rawset(capture, "failed", true)
            rawset(capture, "value", message)
        end
        return
    end

    -- The wrapper should only run inside `fireSignal`. If the internal signal
    -- is fired outside that guard, do not silently swallow the failure.
    error(message, 0)
end

---Build the SignalKit listener that delivers to one subscriber.
---@param subscription LifecycleKit.Subscription
---@param signalKey string
---@param callback function
---@param once boolean whether the subscription is spent by its first delivery
---@return fun(instance: LifecycleKit.Instance, first: any, second: any)
local function newListener(subscription, signalKey, callback, once)
    return function(instance, first, second)
        if once then
            rawset(subscription, "_connected", false)
            rawset(subscription, "_inner", nil)
        end

        local ok, message = pcall(callback, instance, first, second)
        if not ok then
            recordCallbackFailure(instance, signalKey, message)
        end
    end
end

---Re-raise a captured error unchanged, or return when there was none.
---@param errorRecord LifecycleKit.ErrorRecord|nil
local function raisePhaseError(errorRecord)
    if errorRecord ~= nil then
        error(rawget(errorRecord, "value"), 0)
    end
end

-- Combat queue --------------------------------------------------------------

---Pack the still-pending deferred calls to the front of the queue.
---
---Runs in place: spent and cancelled slots are dropped, the pending ones keep
---their FIFO order, and the array itself is reused.
---@param instance LifecycleKit.Instance
local function compactCombatQueue(instance)
    local queue = rawget(instance, "_combatQueue")
    local length = rawget(instance, "_combatQueueLength")
    local written = 0

    for index = 1, length do
        local handle = rawget(queue, index)
        if handle ~= nil and rawget(handle, "_pending") == true then
            written = written + 1
            rawset(queue, written, handle)
        end
    end
    for index = written + 1, length do
        rawset(queue, index, nil)
    end

    rawset(instance, "_combatQueueLength", written)
end

---Take `handle` out of the pending set and return the callback it carried.
---@param instance LifecycleKit.Instance
---@param handle LifecycleKit.DeferredCall
---@return function callback
local function claimDeferredCall(instance, handle)
    local callback = rawget(handle, "_callback")
    rawset(handle, "_pending", false)
    rawset(handle, "_callback", nil)
    rawset(handle, "_instance", nil)
    rawset(instance, "_combatPending", rawget(instance, "_combatPending") - 1)
    return callback
end

---Deliver every pending deferred call of `instance`, oldest first.
---
---Each call runs protected; the first failure is returned once the rest have
---run, which is the phase machinery's first-error policy.
---
---`stopWhenInCombat` is a defensive guard. The client never delivers
---`PLAYER_REGEN_DISABLED` synchronously inside another handler, so a real
---drain is never interrupted. Should a host ever do so, the remaining calls
---stay queued for the next combat end rather than running protected work in
---combat.
---@param instance LifecycleKit.Instance
---@param ran boolean `true` for an out-of-combat run, `false` for a closed queue
---@param reason "shutdown"|"halted"|nil why a closed queue did not run the calls
---@param stopWhenInCombat boolean
---@return LifecycleKit.ErrorRecord|nil
local function drainCombatQueue(instance, ran, reason, stopWhenInCombat)
    if rawget(instance, "_combatPending") == 0 and rawget(instance, "_combatQueueLength") == 0 then
        return nil
    end

    local queue = rawget(instance, "_combatQueue")
    local firstError = nil
    local index = 1

    rawset(instance, "_draining", true)
    while index <= rawget(instance, "_combatQueueLength") do
        if stopWhenInCombat and rawget(state, "inCombat") == true then
            break
        end

        local handle = rawget(queue, index)
        rawset(queue, index, nil)
        if handle ~= nil and rawget(handle, "_pending") == true then
            local callback = claimDeferredCall(instance, handle)
            local ok, message = pcall(callback, instance, ran, reason)
            if not ok and firstError == nil then
                firstError = newErrorRecord(message)
            end
        end
        index = index + 1
    end
    rawset(instance, "_draining", false)

    compactCombatQueue(instance)
    return firstError
end

---Close the combat queue for good, telling each pending call why it never ran.
---@param instance LifecycleKit.Instance
---@param reason "shutdown"|"halted"
---@return LifecycleKit.ErrorRecord|nil
local function closeCombatQueue(instance, reason)
    return drainCombatQueue(instance, false, reason, false)
end

-- Phase machinery -----------------------------------------------------------

---Whether `instance` has reached a terminal state (shutdown or halted).
---@param instance LifecycleKit.Instance
---@return boolean
local function isTerminal(instance)
    return rawget(instance, "_shutdown") == true or rawget(instance, "_halted") == true
end

---Enter the `ready` phase unless an earlier transition already made it impossible.
---@param instance LifecycleKit.Instance
---@return LifecycleKit.ErrorRecord|nil
local function markReady(instance)
    if rawget(instance, "_ready") == true or isTerminal(instance) then
        return nil
    end

    rawset(instance, "_ready", true)
    return firePhase(instance, "ready")
end

---Enter the `loaded` phase, continuing straight into `ready` when applicable.
---@param instance LifecycleKit.Instance
---@return LifecycleKit.ErrorRecord|nil
local function markLoaded(instance)
    if rawget(instance, "_loaded") == true or isTerminal(instance) then
        return nil
    end

    rawset(instance, "_loaded", true)

    local firstError = firePhase(instance, "loaded")
    if rawget(state, "loginSeen") == true or isPlayerLoggedIn() then
        rawset(state, "loginSeen", true)
        local readyError = markReady(instance)
        if firstError == nil then
            firstError = readyError
        end
    end

    return firstError
end

---Close the addon's canonical TimerKit scope, cancelling every timer it owns.
---
---TimerKit does not depend on LifecycleKit and never observes shutdown, so
---this is the second half of the two-step `TimerKit:ForAddon` documents. A
---TimerKit revision older than 0.5.0 has no `CloseAddonScopes`; it closes its
---addon scopes itself from a shutdown subscription, among the shutdown
---callbacks, so there is nothing to do here. Without TimerKit there is nothing
---to close either; `false` (the addon never had a scope) is a normal result.
---A failure is returned as an error record for the first-error policy.
---@param instance LifecycleKit.Instance
---@return LifecycleKit.ErrorRecord|nil
local function closeAddonTimerScopes(instance)
    local TimerKit = findOptionalPackage("timerKit", OPTIONAL_TIMER_KIT_API)
    local closeAddonScopes = TimerKit ~= nil and rawget(TimerKit, "CloseAddonScopes") or nil
    if type(closeAddonScopes) ~= "function" then
        return nil
    end

    local ok, closeError = pcall(closeAddonScopes, TimerKit, rawget(instance, "_addonName"))
    if not ok then
        return newErrorRecord(closeError)
    end
    return nil
end

---Close the addon's canonical SchedulerKit scope: its jobs are cancelled, its
---coalescing handles closed and its delay timers released.
---
---SchedulerKit does not depend on LifecycleKit either, so this is the second
---half of the two-step `SchedulerKit:ForAddon` documents. A SchedulerKit
---revision older than 0.6.0 has no `CloseAddonScopes` and closes its addon
---scopes itself; without SchedulerKit there is nothing to close. A failure is
---returned as an error record for the first-error policy.
---@param instance LifecycleKit.Instance
---@return LifecycleKit.ErrorRecord|nil
local function closeAddonSchedulerScopes(instance)
    local SchedulerKit = findOptionalPackage("schedulerKit", OPTIONAL_SCHEDULER_KIT_API)
    local closeAddonScopes = SchedulerKit ~= nil and rawget(SchedulerKit, "CloseAddonScopes") or nil
    if type(closeAddonScopes) ~= "function" then
        return nil
    end

    local ok, closeError = pcall(closeAddonScopes, SchedulerKit, rawget(instance, "_addonName"))
    if not ok then
        return newErrorRecord(closeError)
    end
    return nil
end

---Close the addon's canonical EventKit scope once its shutdown phase has run.
---
---EventKit cannot observe addon shutdown itself because it sits below
---LifecycleKit in the dependency order, so this is the other half of the
---two-step `EventKit:ForAddon` documents. Shutdown callbacks run first: they may
---still need their event connections. An EventKit revision older than the one
---that introduced scopes has no `CloseAddonScopes`, and then there is nothing
---to close. A failure while disconnecting is reported like a phase error so the
---shutdown still completes for every other addon.
---@param instance LifecycleKit.Instance
---@return LifecycleKit.ErrorRecord|nil
local function closeAddonEventScope(instance)
    local closeAddonScopes = rawget(EventKit, "CloseAddonScopes")
    if type(closeAddonScopes) ~= "function" then
        return nil
    end

    local ok, closeError = pcall(closeAddonScopes, EventKit, rawget(instance, "_addonName"))
    if not ok then
        return newErrorRecord(closeError)
    end
    return nil
end

---Close the addon's canonical HookKit scope, undoing every hook it holds.
---
---HookKit is an optional dependency and has no lifecycle of its own, so this
---is the second half of the two-step `HookKit:ForAddon` documents. Without
---HookKit, or with a revision that has no `CloseAddonScopes`, there is nothing
---to close. A failure is returned as an error record for the first-error
---policy, like `closeAddonEventScope`.
---@param instance LifecycleKit.Instance
---@return LifecycleKit.ErrorRecord|nil
local function closeAddonHookScopes(instance)
    local HookKit = findOptionalPackage("hookKit", OPTIONAL_HOOK_KIT_API)
    local closeAddonScopes = HookKit ~= nil and rawget(HookKit, "CloseAddonScopes") or nil
    if type(closeAddonScopes) ~= "function" then
        return nil
    end

    local ok, closeError = pcall(closeAddonScopes, HookKit, rawget(instance, "_addonName"))
    if not ok then
        return newErrorRecord(closeError)
    end
    return nil
end

---Close the addon's canonical CommandKit scope, leaving its slash commands inert.
---
---CommandKit is an optional dependency and has no lifecycle of its own, so this
---is the second half of the two-step `CommandKit:ForAddon` documents. Without
---CommandKit, or with a revision that has no `CloseAddonScopes`, there is
---nothing to close; `false` (the addon never had a scope) is a normal result.
---A failure is returned as an error record for the first-error policy.
---@param instance LifecycleKit.Instance
---@return LifecycleKit.ErrorRecord|nil
local function closeAddonCommandScopes(instance)
    local CommandKit = findOptionalPackage("commandKit", OPTIONAL_COMMAND_KIT_API)
    local closeAddonScopes = CommandKit ~= nil and rawget(CommandKit, "CloseAddonScopes") or nil
    if type(closeAddonScopes) ~= "function" then
        return nil
    end

    local ok, closeError = pcall(closeAddonScopes, CommandKit, rawget(instance, "_addonName"))
    if not ok then
        return newErrorRecord(closeError)
    end
    return nil
end

---Close the addon's canonical CommKit scope: its pending sends are cancelled,
---its SyncSets closed and its prefix registrations disconnected.
---
---CommKit does not depend on LifecycleKit; it learns from
---`CLOSES_ADDON_SCOPES` that this step exists and subscribes nothing of its
---own, so this call is what closes the scope, at its place in the shutdown
---order. A CommKit revision that closed the scope itself answers `false`
---here, a normal result.
---Without CommKit, or with a revision that has no `CloseAddonScopes`, there is
---nothing to close. A failure is returned as an error record for the
---first-error policy.
---@param instance LifecycleKit.Instance
---@return LifecycleKit.ErrorRecord|nil
local function closeAddonCommScopes(instance)
    local CommKit = findOptionalPackage("commKit", OPTIONAL_COMM_KIT_API)
    local closeAddonScopes = CommKit ~= nil and rawget(CommKit, "CloseAddonScopes") or nil
    if type(closeAddonScopes) ~= "function" then
        return nil
    end

    local ok, closeError = pcall(closeAddonScopes, CommKit, rawget(instance, "_addonName"))
    if not ok then
        return newErrorRecord(closeError)
    end
    return nil
end

---Close the addon's SignalKit bus, disconnecting every subscription on it.
---
---SignalKit is a required dependency, and Registry keeps its facade identity
---across compatible upgrades, so the facade captured at load time is asked
---directly rather than looked up again. A SignalKit revision older than the
---one that introduced buses has no `CloseAddonBus`; then there is nothing to
---close. `CloseAddonBus` answers `false` for an addon that never asked for a
---bus, which is a normal result, not a failure.
---@param instance LifecycleKit.Instance
---@return LifecycleKit.ErrorRecord|nil
local function closeAddonBus(instance)
    local closeBus = rawget(SignalKit, "CloseAddonBus")
    if type(closeBus) ~= "function" then
        return nil
    end

    local ok, closeError = pcall(closeBus, SignalKit, rawget(instance, "_addonName"))
    if not ok then
        return newErrorRecord(closeError)
    end
    return nil
end

---Release everything the addon owns through the other Kits' addon scopes.
---
---The order is deliberate, and it is also the first-error precedence:
---
---1. the TimerKit scope and
---2. the SchedulerKit scope first, so no timer fires and no job runs into
---   event listeners, hooks or subscribers that are being torn down;
---3. the EventKit scope, so no host event fires into hooks or subscribers
---   that are being torn down;
---4. the HookKit scope, so the addon's hooks stop running;
---5. the CommandKit scope, so the addon's slash commands become inert;
---6. the CommKit scope, so the addon's addon messages stop being sent and
---   received;
---7. the SignalKit bus last, because other addons' shutdown paths may still
---   publish on it. Publishing on a closed bus delivers nothing and does not
---   raise, so closing it last only keeps it useful for longer.
---
---Every step runs even when an earlier one failed.
---@param instance LifecycleKit.Instance
---@return LifecycleKit.ErrorRecord|nil firstError
local function closeAddonOwnedScopes(instance)
    local timerError = closeAddonTimerScopes(instance)
    local schedulerError = closeAddonSchedulerScopes(instance)
    local eventError = closeAddonEventScope(instance)
    local hookError = closeAddonHookScopes(instance)
    local commandError = closeAddonCommandScopes(instance)
    local commError = closeAddonCommScopes(instance)
    local busError = closeAddonBus(instance)
    return timerError
        or schedulerError
        or eventError
        or hookError
        or commandError
        or commError
        or busError
end

---Drop every pending listener of the signals a terminal state makes unreachable.
---
---Called on shutdown and on halt. The phases already reached keep nothing
---pending (their listeners were one-shot), so only the unreached ones and the
---repeating notifications are cleared. The signal named by `keepKey` is the
---terminal phase itself, which still has to fire.
---@param instance LifecycleKit.Instance
---@param keepKey "shutdown"|"halted"
local function disconnectUnreachableSignals(instance, keepKey)
    local disconnectAll = rawget(SignalKit, "DisconnectAll")
    local signals = rawget(instance, "_signals")

    if rawget(instance, "_loaded") ~= true then
        disconnectAll(rawget(signals, "loaded"))
    end
    if rawget(instance, "_ready") ~= true then
        disconnectAll(rawget(signals, "ready"))
    end
    if keepKey ~= "shutdown" then
        disconnectAll(rawget(signals, "shutdown"))
    end
    if keepKey ~= "halted" then
        disconnectAll(rawget(signals, "halted"))
    end
    disconnectAll(rawget(signals, "dependencyHalted"))
    disconnectAll(rawget(signals, "combatStart"))
    disconnectAll(rawget(signals, "combatEnd"))
end

---Enter the terminal `shutdown` phase and release unreachable subscriptions.
---
---Order, and therefore first-error precedence: the combat queue is closed
---(each pending call learns it will never run), then the shutdown callbacks
---run, then the addon's TimerKit scope, SchedulerKit scope, EventKit scope,
---HookKit scope, CommandKit scope, CommKit scope and SignalKit bus are closed,
---in that order (see `closeAddonOwnedScopes`).
---
---A halted addon never reaches `shutdown`: halted is terminal. Its scopes and
---its bus are still closed at logout so they end with the session like
---everyone else's.
---@param instance LifecycleKit.Instance
---@return LifecycleKit.ErrorRecord|nil
local function markShutdown(instance)
    if rawget(instance, "_shutdown") == true then
        return nil
    end
    if rawget(instance, "_halted") == true then
        return closeAddonOwnedScopes(instance)
    end

    rawset(instance, "_shutdown", true)

    -- Once shutdown is reached, anything not yet delivered can no longer
    -- occur. Drop those pending SignalKit listeners so callback closures do
    -- not remain retained behind subscriptions that can never fire.
    disconnectUnreachableSignals(instance, "shutdown")

    local queueError = closeCombatQueue(instance, "shutdown")
    local phaseError = firePhase(instance, "shutdown")
    local scopeError = closeAddonOwnedScopes(instance)
    return queueError or phaseError or scopeError
end

---Whether `instance` declared `addonName` with `DependsOn`.
---@param instance LifecycleKit.Instance
---@param addonName string
---@return boolean
local function dependsOnAddon(instance, addonName)
    local dependencies = rawget(instance, "_dependencies")
    for index = 1, #dependencies do
        if rawget(dependencies, index) == addonName then
            return true
        end
    end
    return false
end

---Tell every live addon that declared `halted` as a dependency.
---@param halted LifecycleKit.Instance
---@param reason string
---@return LifecycleKit.ErrorRecord|nil
local function announceHalt(halted, reason)
    local instances = rawget(state, "instances")
    local count = #instances
    local addonName = rawget(halted, "_addonName")
    local firstError = nil

    for index = 1, count do
        local dependent = rawget(instances, index)
        if
            dependent ~= halted
            and not isTerminal(dependent)
            and dependsOnAddon(dependent, addonName)
        then
            local notifyError = firePhase(dependent, "dependencyHalted", addonName, reason)
            if firstError == nil then
                firstError = notifyError
            end
        end
    end

    return firstError
end

-- Combat state ----------------------------------------------------------------

---Whether `instance` receives `OnCombatStart` / `OnCombatEnd` notifications.
---
---Only an addon that has reached `loaded` is told. This costs nothing: an
---addon's files run and its `ADDON_LOADED` follows in one synchronous load, so
---no `PLAYER_REGEN_*` event can arrive in between, and the rule only keeps
---notices away from lifecycle instances created for addons that have not
---loaded yet. Their subscriptions stay connected and start receiving once the
---addon has loaded. A load-on-demand addon loaded mid-combat therefore sees
---`OnCombatEnd` without a matching `OnCombatStart`; it should read
---`IsInCombat()` in `OnLoaded`. Terminal addons have no combat subscriptions
---left.
---@param instance LifecycleKit.Instance
---@return boolean
local function receivesCombatNotices(instance)
    return rawget(instance, "_loaded") == true and not isTerminal(instance)
end

---Deliver `OnCombatStart` to every eligible addon, in `state.instances` order.
---@return LifecycleKit.ErrorRecord|nil
local function announceCombatStart()
    local instances = rawget(state, "instances")
    local count = #instances
    local firstError = nil

    for index = 1, count do
        local instance = rawget(instances, index)
        if receivesCombatNotices(instance) then
            local noticeError = fireCombatSignal(instance, "combatStart")
            if firstError == nil then
                firstError = noticeError
            end
        end
    end

    return firstError
end

---Drain every addon's combat queue and, after a real flip, announce the end.
---
---Per addon, in `state.instances` order: the queued calls run first, then its
---`OnCombatEnd` subscribers.
---@param announce boolean whether the shared state flipped and `OnCombatEnd` is due
---@return LifecycleKit.ErrorRecord|nil
local function finishCombat(announce)
    local instances = rawget(state, "instances")
    local count = #instances
    local firstError = nil

    for index = 1, count do
        local instance = rawget(instances, index)
        if not isTerminal(instance) then
            local queueError = drainCombatQueue(instance, true, nil, true)
            if firstError == nil then
                firstError = queueError
            end
            if announce and receivesCombatNotices(instance) then
                local noticeError = fireCombatSignal(instance, "combatEnd")
                if firstError == nil then
                    firstError = noticeError
                end
            end
        end
    end

    return firstError
end

---Move the shared combat flag to `inCombat` and run what the change implies.
---@param inCombat boolean
---@return LifecycleKit.ErrorRecord|nil
local function setCombatState(inCombat)
    local wasInCombat = rawget(state, "inCombat") == true
    rawset(state, "inCombat", inCombat)

    if inCombat then
        if wasInCombat then
            return nil
        end
        return announceCombatStart()
    end

    -- A queue can hold calls only while in combat, so a redundant end still
    -- drains safely; `OnCombatEnd` is announced only for a real flip.
    return finishCombat(wasInCombat)
end

---Bring the shared flag in line with the host after a moment it may have
---changed unobserved (a login, or combat watchers that were missing).
---@return LifecycleKit.ErrorRecord|nil
local function reconcileCombatState()
    local hostInCombat = isHostInCombatLockdown()
    if hostInCombat == (rawget(state, "inCombat") == true) then
        return nil
    end
    return setCombatState(hostInCombat)
end

-- Shared event coordination -------------------------------------------------

---Forget a shared watcher that has already delivered its one-shot event.
---@param key "addonLoaded"|"playerLogin"|"playerLogout"
local function clearGlobalWatcher(key)
    local watchers = rawget(state, "globalWatchers")
    rawset(watchers, key, nil)
end

---Cancel a shared watcher that can no longer deliver anything useful.
---@param key "addonLoaded"|"playerLogin"|"playerLogout"|"combatStart"|"combatEnd"
local function disconnectGlobalWatcher(key)
    local watchers = rawget(state, "globalWatchers")
    local connection = rawget(watchers, key)
    if connection ~= nil then
        rawset(watchers, key, nil)
        connection:Disconnect()
    end
end

---`ADDON_LOADED` handler shared by every addon LifecycleKit tracks.
---@param _ string event name
---@param addonName string
local function onAddonLoaded(_, addonName)
    local instance = rawget(rawget(state, "addons"), addonName)
    if instance ~= nil then
        raisePhaseError(markLoaded(instance))
    end
end

---Run `callback` for every instance, by addon name, keeping the first error only.
---
---Used for the one-shot global phases, where a sorted snapshot is affordable
---and protects the iteration from instances created by a callback.
---@param callback fun(instance: LifecycleKit.Instance): LifecycleKit.ErrorRecord|nil
---@return LifecycleKit.ErrorRecord|nil firstError first captured error, or `nil`
local function runForAllAddons(callback)
    local ordered = sortedInstances(rawget(state, "addons"))
    local firstError = nil

    for index = 1, #ordered do
        local ok, result = pcall(callback, ordered[index])
        local candidate = result
        if not ok then
            candidate = newErrorRecord(result)
        end

        if candidate ~= nil and firstError == nil then
            firstError = candidate
        end
    end

    return firstError
end

---`PLAYER_LOGIN` handler: promote every loaded instance to `ready`.
---
---The host may have entered combat before login (a `/reload` in combat), so
---the combat flag is re-read from the host here too.
local function onPlayerLogin()
    rawset(state, "loginSeen", true)
    clearGlobalWatcher("playerLogin")

    local firstError = runForAllAddons(function(instance)
        if rawget(instance, "_loaded") == true then
            return markReady(instance)
        end
        return nil
    end)

    local combatError = reconcileCombatState()
    raisePhaseError(firstError or combatError)
end

---`PLAYER_LOGOUT` handler: drive every instance into `shutdown`.
local function onPlayerLogout()
    rawset(state, "shutdownSeen", true)
    clearGlobalWatcher("playerLogout")
    disconnectGlobalWatcher("playerLogin")
    disconnectGlobalWatcher("addonLoaded")
    disconnectGlobalWatcher("combatStart")
    disconnectGlobalWatcher("combatEnd")

    local firstError = runForAllAddons(function(instance)
        return markShutdown(instance)
    end)

    raisePhaseError(firstError)
end

---`PLAYER_REGEN_DISABLED` handler: the player entered combat.
---
---The host raises this event just before lockdown begins, so the flag flips
---here, one step ahead of `InCombatLockdown()`: from this point protected work
---must be deferred.
local function onRegenDisabled()
    raisePhaseError(setCombatState(true))
end

---`PLAYER_REGEN_ENABLED` handler: combat ended and lockdown has lifted.
local function onRegenEnabled()
    raisePhaseError(setCombatState(false))
end

---Install the shared host watchers.
---
---`ADDON_LOADED`, `PLAYER_LOGIN` and `PLAYER_LOGOUT` drive the phases;
---`PLAYER_REGEN_DISABLED` and `PLAYER_REGEN_ENABLED` drive the combat flag.
---
---Idempotent: only missing watchers are created, and a partial failure rolls
---back the watchers this call created before re-raising. Once `PLAYER_LOGOUT`
---has been observed no watcher is installed at all, because every remaining
---transition is already decided and instances created afterwards go straight
---to `shutdown`.
---@return boolean combatWatchersCreated whether this call installed the combat watchers
local function ensureGlobalWatchers()
    if rawget(state, "shutdownSeen") == true then
        return false
    end

    local watchers = rawget(state, "globalWatchers")
    local created = {}
    local combatWatchersCreated = false

    ---@param key string
    ---@param connection table
    local function remember(key, connection)
        rawset(watchers, key, connection)
        created[#created + 1] = { key = key, connection = connection }
    end

    local ok, message = pcall(function()
        if rawget(watchers, "addonLoaded") == nil then
            remember("addonLoaded", EventKit:Connect("ADDON_LOADED", onAddonLoaded))
        end

        if rawget(state, "loginSeen") ~= true then
            if isPlayerLoggedIn() then
                rawset(state, "loginSeen", true)
            elseif rawget(watchers, "playerLogin") == nil then
                remember("playerLogin", EventKit:Once("PLAYER_LOGIN", onPlayerLogin))
            end
        end

        if rawget(watchers, "playerLogout") == nil then
            remember("playerLogout", EventKit:Once("PLAYER_LOGOUT", onPlayerLogout))
        end

        if rawget(watchers, "combatStart") == nil then
            remember("combatStart", EventKit:Connect("PLAYER_REGEN_DISABLED", onRegenDisabled))
            combatWatchersCreated = true
        end
        if rawget(watchers, "combatEnd") == nil then
            remember("combatEnd", EventKit:Connect("PLAYER_REGEN_ENABLED", onRegenEnabled))
            combatWatchersCreated = true
        end
    end)

    if ok then
        return combatWatchersCreated
    end

    for index = #created, 1, -1 do
        local item = created[index]
        if rawget(watchers, item.key) == item.connection then
            rawset(watchers, item.key, nil)
        end
        item.connection:Disconnect()
    end

    error(message, 0)
end

-- Instance creation ---------------------------------------------------------

---Create, publish and catch up the lifecycle instance for `addonName`.
---@param addonName string
---@return LifecycleKit.Instance
local function createInstance(addonName)
    if ensureGlobalWatchers() then
        -- Combat may have started or ended while nobody was watching.
        raisePhaseError(reconcileCombatState())
    end

    -- Probe before publishing the instance into shared package state so a host
    -- API error cannot leave a half-constructed cached object behind.
    local alreadyLoaded = isAddonFinishedLoading(addonName)

    local instance = setmetatable({
        _addonName = addonName,
        _loaded = false,
        _ready = false,
        _shutdown = false,
        _signals = {
            loaded = SignalKit:New(),
            ready = SignalKit:New(),
            shutdown = SignalKit:New(),
        },
        _phaseCaptures = {},
    }, INSTANCE_METATABLE)
    installGateFields(instance)

    local addons = rawget(state, "addons")
    local instances = rawget(state, "instances")
    rawset(addons, addonName, instance)
    rawset(instances, #instances + 1, instance)

    if alreadyLoaded then
        raisePhaseError(markLoaded(instance))
    end

    if rawget(state, "shutdownSeen") == true then
        raisePhaseError(markShutdown(instance))
    end

    return instance
end

-- Public instance API -------------------------------------------------------

---Return the addon name this lifecycle instance was created for.
---@param self LifecycleKit.Instance
---@return string addonName
local function getAddonName(self)
    return rawget(self, "_addonName")
end

---Return the lifecycle state this instance is in.
---
---`halted` wins over every phase: an addon that halted stays halted for the
---rest of the session.
---@param self LifecycleKit.Instance
---@return LifecycleKit.State
local function getState(self)
    if rawget(self, "_halted") == true then
        return "halted"
    end
    if rawget(self, "_shutdown") == true then
        return "shutdown"
    end
    if rawget(self, "_ready") == true then
        return "ready"
    end
    if rawget(self, "_loaded") == true then
        return "loaded"
    end
    return "loading"
end

---Report whether the `loaded` phase itself was reached.
---@param self LifecycleKit.Instance
---@return boolean
local function isLoaded(self)
    return rawget(self, "_loaded") == true
end

---Report whether the `ready` phase itself was reached.
---@param self LifecycleKit.Instance
---@return boolean
local function isReady(self)
    return rawget(self, "_ready") == true
end

---Report whether the `shutdown` phase itself was reached.
---@param self LifecycleKit.Instance
---@return boolean
local function isShutdown(self)
    return rawget(self, "_shutdown") == true
end

---Report whether the addon halted.
---@param self LifecycleKit.Instance
---@return boolean
local function isHalted(self)
    return rawget(self, "_halted") == true
end

---Return the reason given to `Halt`, or `nil` while the addon is not halted.
---@param self LifecycleKit.Instance
---@return string|nil reason
local function getHaltReason(self)
    return rawget(self, "_haltReason")
end

---Shared implementation of the one-shot phase subscriptions.
---
---The argument error is raised at level 3 so it points at the addon code that
---called the public method: level 1 is this function, level 2 the public
---method, level 3 its caller. That only holds while the public methods call
---this function in a non-tail position; see `onLoaded` for why.
---@param self LifecycleKit.Instance
---@param phaseKey "loaded"|"ready"|"shutdown"|"halted"
---@param reached boolean whether the phase has already occurred
---@param callback function
---@param methodName string public method name, used in the argument error
---@param replayArgument any second argument of a replayed delivery
---@return LifecycleKit.Subscription
local function subscribePhase(self, phaseKey, reached, callback, methodName, replayArgument)
    if type(callback) ~= "function" then
        error("LifecycleKit.Instance:" .. methodName .. " callback must be a function", 3)
    end

    if reached then
        local subscription = newDisconnectedSubscription()
        local ok, callbackError = pcall(callback, self, replayArgument)
        if not ok then
            -- Replay and dispatch report a failing callback the same way: the
            -- original Lua error object, re-raised unchanged once LifecycleKit
            -- has committed its own state. A subscriber cannot know which of the
            -- two paths it will take, so the two must not differ.
            error(callbackError, 0)
        end
        return subscription
    end

    -- A terminal state makes every phase other than itself unreachable:
    -- shutdown rules out loaded, ready and halted; halted rules out all four.
    if rawget(self, "_halted") == true then
        return newDisconnectedSubscription()
    end
    if phaseKey ~= "shutdown" and rawget(self, "_shutdown") == true then
        return newDisconnectedSubscription()
    end

    local subscription = setmetatable({
        _connected = true,
        _inner = nil,
    }, SUBSCRIPTION_METATABLE)

    local signal = rawget(rawget(self, "_signals"), phaseKey)
    local inner = signal:Once(newListener(subscription, phaseKey, callback, true))
    rawset(subscription, "_inner", inner)
    return subscription
end

---Shared implementation of the repeating subscriptions.
---
---Callers validate `callback` themselves, at their own level.
---@param self LifecycleKit.Instance
---@param signalKey "dependencyHalted"|"combatStart"|"combatEnd"
---@param callback function
---@return LifecycleKit.Subscription
local function subscribeRepeating(self, signalKey, callback)
    if isTerminal(self) then
        return newDisconnectedSubscription()
    end

    local subscription = setmetatable({
        _connected = true,
        _inner = nil,
    }, SUBSCRIPTION_METATABLE)

    local signal = rawget(rawget(self, "_signals"), signalKey)
    local inner = signal:Connect(newListener(subscription, signalKey, callback, false))
    rawset(subscription, "_inner", inner)
    return subscription
end

---Subscribe to the `loaded` phase, replaying it if it already occurred.
---
---The call to `subscribePhase` is deliberately not a tail call. Lua 5.1 drops
---the calling frame on a tail call, which would collapse one level and make
---`subscribePhase`'s argument error point one frame past the addon code that
---called this method. `Errors_spec` pins the reported file and line.
---@param self LifecycleKit.Instance
---@param callback LifecycleKit.PhaseCallback
---@return LifecycleKit.Subscription subscription
local function onLoaded(self, callback)
    local subscription =
        subscribePhase(self, "loaded", rawget(self, "_loaded") == true, callback, "OnLoaded")
    return subscription
end

---Subscribe to the `ready` phase, replaying it if it already occurred.
---@param self LifecycleKit.Instance
---@param callback LifecycleKit.PhaseCallback
---@return LifecycleKit.Subscription subscription
local function onReady(self, callback)
    -- Not a tail call, for the reason documented on `onLoaded`.
    local subscription =
        subscribePhase(self, "ready", rawget(self, "_ready") == true, callback, "OnReady")
    return subscription
end

---Subscribe to the `shutdown` phase, replaying it if it already occurred.
---@param self LifecycleKit.Instance
---@param callback LifecycleKit.PhaseCallback
---@return LifecycleKit.Subscription subscription
local function onShutdown(self, callback)
    -- Not a tail call, for the reason documented on `onLoaded`.
    local subscription =
        subscribePhase(self, "shutdown", rawget(self, "_shutdown") == true, callback, "OnShutdown")
    return subscription
end

---Subscribe to the addon halting, replaying it if the addon already halted.
---@param self LifecycleKit.Instance
---@param callback LifecycleKit.HaltedCallback
---@return LifecycleKit.Subscription subscription
local function onHalted(self, callback)
    -- Not a tail call, for the reason documented on `onLoaded`.
    local subscription = subscribePhase(
        self,
        "halted",
        rawget(self, "_halted") == true,
        callback,
        "OnHalted",
        rawget(self, "_haltReason")
    )
    return subscription
end

---Declare this addon non-functional for the rest of the session.
---
---Every phase not yet reached becomes unreachable and its pending callbacks
---are disconnected, the combat queue is closed with `(instance, false,
---"halted")`, the `OnHalted` subscribers run, and then every addon that
---declared this one with `DependsOn` receives `OnDependencyHalted`. Halted is
---terminal: there is no resume in API 1.
---@param self LifecycleKit.Instance
---@param reason string why the addon cannot work, for dependents and diagnostics
---@return boolean halted `true` for the call that halted; `false` when already halted or shut down
local function halt(self, reason)
    refuseSecret(reason, "LifecycleKit.Instance:Halt reason", 3)
    if type(reason) ~= "string" or reason == "" then
        error("LifecycleKit.Instance:Halt reason must be a non-empty string", 2)
    end
    if isTerminal(self) then
        return false
    end

    rawset(self, "_halted", true)
    rawset(self, "_haltReason", reason)
    disconnectUnreachableSignals(self, "halted")

    local queueError = closeCombatQueue(self, "halted")
    local haltedError = firePhase(self, "halted", reason)
    -- Nothing may subscribe after the halt, and the one-shot listeners just
    -- ran, so the signal holds nothing that could ever fire again.
    rawget(SignalKit, "DisconnectAll")(rawget(rawget(self, "_signals"), "halted"))
    local announceError = announceHalt(self, reason)

    raisePhaseError(queueError or haltedError or announceError)
    return true
end

---Record that this addon cannot work without `addonName`.
---
---When `addonName` halts, this addon's `OnDependencyHalted` subscribers are
---told. If it has already halted, they are told at once.
---@param self LifecycleKit.Instance
---@param addonName string the dependency's folder name, exactly as installed
---@return boolean|nil recorded `true` when newly recorded, `false` when already recorded, `nil` when refused
---@return string|nil reason `"full"`, `"halted"` or `"shutdown"` when refused
local function dependsOn(self, addonName)
    refuseSecret(addonName, "LifecycleKit.Instance:DependsOn addonName", 3)
    if type(addonName) ~= "string" or addonName == "" then
        error("LifecycleKit.Instance:DependsOn addonName must be a non-empty string", 2)
    end
    if addonName == rawget(self, "_addonName") then
        error("LifecycleKit.Instance:DependsOn addonName must name another addon", 2)
    end
    if rawget(self, "_halted") == true then
        return nil, "halted"
    end
    if rawget(self, "_shutdown") == true then
        return nil, "shutdown"
    end
    if dependsOnAddon(self, addonName) then
        return false
    end

    local dependencies = rawget(self, "_dependencies")
    local maxDependencies = rawget(sharedLimits, "maxDependencies")
    if maxDependencies ~= UNBOUNDED and #dependencies >= maxDependencies then
        return nil, "full"
    end
    rawset(dependencies, #dependencies + 1, addonName)

    local dependency = rawget(rawget(state, "addons"), addonName)
    if dependency ~= nil and rawget(dependency, "_halted") == true then
        raisePhaseError(
            firePhase(self, "dependencyHalted", addonName, rawget(dependency, "_haltReason"))
        )
    end
    return true
end

---Subscribe to every halt of a declared dependency.
---
---Dependencies that halted before this call are replayed at once, so the order
---of `DependsOn` and `OnDependencyHalted` does not matter: each subscriber
---hears of each halted dependency exactly once.
---@param self LifecycleKit.Instance
---@param callback LifecycleKit.DependencyHaltedCallback
---@return LifecycleKit.Subscription subscription
local function onDependencyHalted(self, callback)
    if type(callback) ~= "function" then
        error("LifecycleKit.Instance:OnDependencyHalted callback must be a function", 2)
    end

    local subscription = subscribeRepeating(self, "dependencyHalted", callback)
    if not isSubscriptionConnected(subscription) then
        return subscription
    end

    local addons = rawget(state, "addons")
    local dependencies = rawget(self, "_dependencies")
    local firstError = nil
    for index = 1, #dependencies do
        -- A replayed callback may end its own subscription, typically by
        -- halting this addon in response, which disconnects it like a
        -- dispatch would. A disconnected subscription hears nothing more.
        if not isSubscriptionConnected(subscription) then
            break
        end
        local dependencyName = rawget(dependencies, index)
        local dependency = rawget(addons, dependencyName)
        if dependency ~= nil and rawget(dependency, "_halted") == true then
            local ok, message =
                pcall(callback, self, dependencyName, rawget(dependency, "_haltReason"))
            if not ok and firstError == nil then
                firstError = newErrorRecord(message)
            end
        end
    end

    -- A failing replay leaves the subscription connected, exactly as a
    -- failing dispatch would: later halts are still delivered to it.
    raisePhaseError(firstError)
    return subscription
end

-- A deferred call handed back when the callback already ran: it is never
-- pending, and sharing it keeps the out-of-combat path free of allocation.
local SPENT_DEFERRED_CALL = setmetatable({ _pending = false }, DEFERRED_CALL_METATABLE)

---Run `callback` now when out of combat, otherwise once combat ends.
---
---Out of combat the callback runs synchronously as `callback(instance, true)`
---and any error it raises leaves this call unchanged. In combat it is queued,
---first in first out, and runs on the next `PLAYER_REGEN_ENABLED`. Closing the
---queue (shutdown or halt) calls each pending callback with `(instance,
---false, reason)` instead.
---@param self LifecycleKit.Instance
---@param callback LifecycleKit.DeferredCallback
---@return LifecycleKit.DeferredCall|nil call a handle to cancel the call, or `nil` when refused
---@return string|nil reason `"full"`, `"halted"` or `"shutdown"` when refused
local function whenOutOfCombat(self, callback)
    if type(callback) ~= "function" then
        error("LifecycleKit.Instance:WhenOutOfCombat callback must be a function", 2)
    end
    if rawget(self, "_halted") == true then
        return nil, "halted"
    end
    if rawget(self, "_shutdown") == true then
        return nil, "shutdown"
    end

    if rawget(state, "inCombat") ~= true then
        callback(self, true)
        return SPENT_DEFERRED_CALL
    end

    local limit = rawget(self, "_combatQueueLimit")
    local pending = rawget(self, "_combatPending")
    local compactAt = limit
    if limit == UNBOUNDED then
        compactAt = math.max(UNBOUNDED_COMPACTION_FLOOR, 2 * pending)
    elseif pending >= limit then
        return nil, "full"
    end

    -- Cancelled slots are only reclaimed here, so outside a drain the array
    -- never grows past the limit (for an `UNBOUNDED` queue, past twice the
    -- pending count). A drain in progress owns the indices, so it is left
    -- alone; that only happens when a host enters combat inside a drain (see
    -- `drainCombatQueue`), and the drain compacts when it stops.
    if rawget(self, "_combatQueueLength") >= compactAt and rawget(self, "_draining") ~= true then
        compactCombatQueue(self)
    end

    local handle = setmetatable({
        _instance = self,
        _callback = callback,
        _pending = true,
    }, DEFERRED_CALL_METATABLE)

    local length = rawget(self, "_combatQueueLength") + 1
    rawset(rawget(self, "_combatQueue"), length, handle)
    rawset(self, "_combatQueueLength", length)
    rawset(self, "_combatPending", rawget(self, "_combatPending") + 1)
    return handle
end

---Subscribe to every combat start, delivered once the shared flag is `true`.
---@param self LifecycleKit.Instance
---@param callback LifecycleKit.CombatCallback
---@return LifecycleKit.Subscription subscription
local function onCombatStart(self, callback)
    if type(callback) ~= "function" then
        error("LifecycleKit.Instance:OnCombatStart callback must be a function", 2)
    end
    return subscribeRepeating(self, "combatStart", callback)
end

---Subscribe to every combat end, delivered after this addon's queue drained.
---@param self LifecycleKit.Instance
---@param callback LifecycleKit.CombatCallback
---@return LifecycleKit.Subscription subscription
local function onCombatEnd(self, callback)
    if type(callback) ~= "function" then
        error("LifecycleKit.Instance:OnCombatEnd callback must be a function", 2)
    end
    return subscribeRepeating(self, "combatEnd", callback)
end

---Set how many deferred calls this addon may have waiting at once.
---
---Lowering the limit below the number already waiting drops nothing; new calls
---are refused until the queue is below the new limit. `LifecycleKit.UNBOUNDED`
---lifts the limit: the queue holds only this addon's own callbacks.
---@param self LifecycleKit.Instance
---@param limit integer|table a positive integer or `LifecycleKit.UNBOUNDED`
local function setCombatQueueLimit(self, limit)
    refuseSecret(limit, "LifecycleKit.Instance:SetCombatQueueLimit limit", 3)
    if not isLimitValue(limit, UNBOUNDED) then
        error(
            "LifecycleKit.Instance:SetCombatQueueLimit limit must be a positive integer"
                .. " or LifecycleKit.UNBOUNDED",
            2
        )
    end
    rawset(self, "_combatQueueLimit", limit)
end

---Return how many deferred calls this addon may have waiting at once, or
---`LifecycleKit.UNBOUNDED`.
---@param self LifecycleKit.Instance
---@return integer|table limit
local function getCombatQueueLimit(self)
    return rawget(self, "_combatQueueLimit")
end

---Cancel a deferred call that is still waiting.
---
---Only flags the slot, so cancelling never allocates or shifts the queue.
---@param self LifecycleKit.DeferredCall
---@return boolean cancelled `true` only for the call that cancelled a pending call
local function cancelDeferredCall(self)
    if rawget(self, "_pending") ~= true then
        return false
    end

    local instance = rawget(self, "_instance")
    rawset(self, "_pending", false)
    rawset(self, "_callback", nil)
    rawset(self, "_instance", nil)
    if instance ~= nil then
        rawset(instance, "_combatPending", rawget(instance, "_combatPending") - 1)
    end
    return true
end

---Report whether the deferred call is still waiting for combat to end.
---@param self LifecycleKit.DeferredCall
---@return boolean
local function isDeferredCallPending(self)
    return rawget(self, "_pending") == true
end

-- Public package API --------------------------------------------------------

---Return the stable lifecycle instance for `addonName`, creating it on demand.
---
---`addonName` is matched exactly against the name WoW reports in
---`ADDON_LOADED`, which is the addon's folder name as installed. See
---`docs/API.md` for why the name is not normalised.
---
---The argument error is raised at level 2 because this function is the frame
---the consumer calls: level 1 is this function, level 2 its caller.
---@param _ LifecycleKit
---@param addonName string addon folder name, exactly as installed
---@return LifecycleKit.Instance instance
local function forAddon(_, addonName)
    refuseSecret(addonName, "LifecycleKit:ForAddon addonName", 3)
    if type(addonName) ~= "string" or addonName == "" then
        error("LifecycleKit:ForAddon addonName must be a non-empty string", 2)
    end

    local addons = rawget(state, "addons")
    local existingInstance = rawget(addons, addonName)
    if existingInstance ~= nil then
        return existingInstance
    end

    return createInstance(addonName)
end

---Report whether the player is in combat, by the one shared lockdown state.
---
---The state follows `PLAYER_REGEN_DISABLED` / `PLAYER_REGEN_ENABLED` once the
---shared watchers are installed (by the first `ForAddon`). Before that, and
---after logout, nothing watches the events, so the host is asked directly.
---@param _ LifecycleKit
---@return boolean
local function isInCombat(_)
    local watchers = rawget(state, "globalWatchers")
    if rawget(watchers, "combatStart") ~= nil and rawget(watchers, "combatEnd") ~= nil then
        return rawget(state, "inCombat") == true
    end
    return isHostInCombatLockdown()
end

---Validate a whole `SetLimits` table before any of it is applied, so a
---refused call changes nothing.
---@param limits any
---@param level integer stack level the failures are reported at
local function validateLimitUpdate(limits, level)
    if type(limits) ~= "table" then
        error("LifecycleKit:SetLimits limits must be a table", level)
    end
    local key = next(limits)
    while type(key) ~= "nil" do
        if key ~= "maxDependencies" and key ~= "defaultCombatQueueLimit" then
            error(
                "LifecycleKit:SetLimits limits." .. tostring(key) .. " is not a recognised limit",
                level
            )
        end
        refuseSecret(rawget(limits, key), "LifecycleKit:SetLimits limits." .. key, level + 1)
        if not isLimitValue(rawget(limits, key), UNBOUNDED) then
            error(
                "LifecycleKit:SetLimits limits."
                    .. key
                    .. " must be a positive integer or LifecycleKit.UNBOUNDED",
                level
            )
        end
        key = next(limits, key)
    end
end

---Change any subset of the package-wide limits, shared by every addon in the
---session. The whole table is validated first, so a refused call changes
---nothing.
---
---Lowering `maxDependencies` forgets no dependency already declared; further
---`DependsOn` calls answer `nil, "full"` until the list is below it.
---`defaultCombatQueueLimit` is the limit instances created from now on start
---with; instances that already exist keep theirs (`SetCombatQueueLimit`
---changes one).
---@param self LifecycleKit
---@param limits table any subset of `LifecycleKit.Limits`
local function setLimits(self, limits)
    -- The type test comes first: a dot call can hand a secret in as `self`.
    if type(self) ~= "table" or self ~= LifecycleKit then
        error(
            "LifecycleKit:SetLimits must be called on the LifecycleKit facade; "
                .. "use LifecycleKit:SetLimits(limits)",
            2
        )
    end
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
---@param self LifecycleKit
---@return LifecycleKit.Limits
local function getLimits(self)
    if type(self) ~= "table" or self ~= LifecycleKit then
        error(
            "LifecycleKit:GetLimits must be called on the LifecycleKit facade; "
                .. "use LifecycleKit:GetLimits()",
            2
        )
    end
    return {
        maxDependencies = rawget(sharedLimits, "maxDependencies"),
        defaultCombatQueueLimit = rawget(sharedLimits, "defaultCombatQueueLimit"),
    }
end

-- Commit --------------------------------------------------------------------

rawset(Subscription, "Disconnect", disconnectSubscription)
rawset(Subscription, "IsConnected", isSubscriptionConnected)

rawset(DeferredCall, "Cancel", cancelDeferredCall)
rawset(DeferredCall, "IsPending", isDeferredCallPending)

rawset(Instance, "GetAddonName", getAddonName)
rawset(Instance, "GetState", getState)
rawset(Instance, "IsLoaded", isLoaded)
rawset(Instance, "IsReady", isReady)
rawset(Instance, "IsShutdown", isShutdown)
rawset(Instance, "IsHalted", isHalted)
rawset(Instance, "GetHaltReason", getHaltReason)
rawset(Instance, "OnLoaded", onLoaded)
rawset(Instance, "OnReady", onReady)
rawset(Instance, "OnShutdown", onShutdown)
rawset(Instance, "OnHalted", onHalted)
rawset(Instance, "Halt", halt)
rawset(Instance, "DependsOn", dependsOn)
rawset(Instance, "OnDependencyHalted", onDependencyHalted)
rawset(Instance, "WhenOutOfCombat", whenOutOfCombat)
rawset(Instance, "OnCombatStart", onCombatStart)
rawset(Instance, "OnCombatEnd", onCombatEnd)
rawset(Instance, "SetCombatQueueLimit", setCombatQueueLimit)
rawset(Instance, "GetCombatQueueLimit", getCombatQueueLimit)

rawset(LifecycleKit, "API", API_GENERATION)
rawset(LifecycleKit, "REVISION", IMPLEMENTATION_REVISION)
rawset(LifecycleKit, "ForAddon", forAddon)
rawset(LifecycleKit, "IsInCombat", isInCombat)
rawset(LifecycleKit, "UNBOUNDED", UNBOUNDED)
rawset(LifecycleKit, "SetLimits", setLimits)
rawset(LifecycleKit, "GetLimits", getLimits)

-- The capability set is rewritten in place so it names exactly what this
-- copy's `closeAddonOwnedScopes` closes.
local capabilityEntries = rawget(addonScopeCapabilities, "entries")
for packageId in pairs(capabilityEntries) do
    rawset(capabilityEntries, packageId, nil)
end
for index = 1, #CLOSED_ADDON_SCOPE_PACKAGES do
    rawset(capabilityEntries, CLOSED_ADDON_SCOPE_PACKAGES[index], true)
end
rawset(LifecycleKit, "CLOSES_ADDON_SCOPES", CLOSES_ADDON_SCOPES)

if
    not validatePublicSurface(LifecycleKit)
    or not validateCurrentState(LifecycleKit)
    or rawget(LifecycleKit, "UNBOUNDED") ~= UNBOUNDED
    or rawget(LifecycleKit, "CLOSES_ADDON_SCOPES") ~= CLOSES_ADDON_SCOPES
then
    error("MoltenCodes LifecycleKit package state is corrupted or incomplete", 2)
end

-- Re-establish shared watchers for every live compatible state. Besides normal
-- upgrades, this makes same-revision bootstrap idempotent after a prior host
-- registration failure. Reconcile globally observable state for all compatible
-- prior revisions: a missing watcher may have allowed PLAYER_LOGIN,
-- PLAYER_LOGOUT or a combat change to pass before a later embedded copy
-- repaired the bootstrap.
if type(previousRevision) ~= "nil" and next(rawget(state, "addons")) ~= nil then
    ensureGlobalWatchers()

    local firstError
    if rawget(state, "shutdownSeen") == true then
        firstError = runForAllAddons(function(instance)
            return markShutdown(instance)
        end)
    else
        if rawget(state, "loginSeen") == true then
            firstError = runForAllAddons(function(instance)
                if rawget(instance, "_loaded") == true then
                    return markReady(instance)
                end
                return nil
            end)
        end
        firstError = firstError or reconcileCombatState()
    end

    raisePhaseError(firstError)
end

return LifecycleKit
