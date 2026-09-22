-- MoltenCodes LifecycleKit
--
-- Per-addon lifecycle coordination built on MoltenCodes EventKit and SignalKit.
-- LifecycleKit keeps WoW event details at the boundary and exposes replay-aware,
-- one-shot phase subscriptions for addon code.

local PACKAGE_NAME = "lifecycleKit"
local API_GENERATION = 1
local IMPLEMENTATION_REVISION = 4
local REQUIRED_REGISTRY_API = 2
local REQUIRED_SIGNAL_API = 1
local REQUIRED_EVENT_KIT_API = 1
local STATE_SCHEMA = 2

-- Dependencies --------------------------------------------------------------

-- The shared MoltenCodes namespace is the one documented global handoff point between independently embedded copies.
-- selene: allow(global_usage)
local namespace = rawget(_G, "MoltenCodes")
if type(namespace) ~= "table" then
    error("MoltenCodes LifecycleKit requires Registry API 2 to be loaded first", 2)
end

local Registry = rawget(namespace, "Registry")
if type(Registry) ~= "table" or rawget(Registry, "API") ~= REQUIRED_REGISTRY_API then
    error("MoltenCodes LifecycleKit requires Registry API 2 to be loaded first", 2)
end

local registerPackage = rawget(Registry, "Register")
local getPackage = rawget(Registry, "Get")
if type(registerPackage) ~= "function" or type(getPackage) ~= "function" then
    error("MoltenCodes LifecycleKit requires a valid Registry API 2 facade", 2)
end

local SignalKit, signalRevision = getPackage(Registry, "signalKit", REQUIRED_SIGNAL_API)
if SignalKit == nil then
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
if EventKit == nil then
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

-- Public-surface validation --------------------------------------------------

local function validatePublicSurface(implementation)
    if
        type(implementation) ~= "table"
        or rawget(implementation, "API") ~= API_GENERATION
        or type(rawget(implementation, "REVISION")) ~= "number"
        or type(rawget(implementation, "Instance")) ~= "table"
        or type(rawget(implementation, "Subscription")) ~= "table"
        or type(rawget(implementation, "ForAddon")) ~= "function"
    then
        return false
    end

    local Instance = rawget(implementation, "Instance")
    local Subscription = rawget(implementation, "Subscription")
    return type(rawget(Instance, "GetAddonName")) == "function"
        and type(rawget(Instance, "GetState")) == "function"
        and type(rawget(Instance, "IsLoaded")) == "function"
        and type(rawget(Instance, "IsReady")) == "function"
        and type(rawget(Instance, "IsShutdown")) == "function"
        and type(rawget(Instance, "OnLoaded")) == "function"
        and type(rawget(Instance, "OnReady")) == "function"
        and type(rawget(Instance, "OnShutdown")) == "function"
        and type(rawget(Subscription, "Disconnect")) == "function"
        and type(rawget(Subscription, "IsConnected")) == "function"
end

local function validateCurrentState(implementation)
    local currentState = rawget(implementation, "_state")
    return type(currentState) == "table"
        and rawget(currentState, "schema") == STATE_SCHEMA
        and type(rawget(currentState, "addons")) == "table"
        and type(rawget(currentState, "globalWatchers")) == "table"
        and type(rawget(currentState, "loginSeen")) == "boolean"
        and type(rawget(currentState, "shutdownSeen")) == "boolean"
end

local existing, existingRevision = getPackage(Registry, PACKAGE_NAME, API_GENERATION)
if existing ~= nil then
    if not validatePublicSurface(existing) or rawget(existing, "REVISION") ~= existingRevision then
        error("MoltenCodes LifecycleKit package state is corrupted or incomplete", 2)
    end

    if existingRevision == IMPLEMENTATION_REVISION and not validateCurrentState(existing) then
        error("MoltenCodes LifecycleKit package state is corrupted or incomplete", 2)
    end
end

local LifecycleKit, previousRevision =
    registerPackage(Registry, PACKAGE_NAME, API_GENERATION, IMPLEMENTATION_REVISION)

if LifecycleKit == nil then
    if existingRevision ~= IMPLEMENTATION_REVISION then
        -- A newer compatible embedded revision already owns the package.
        return existing
    end

    -- Re-run the current implementation bootstrap against the stable facade.
    -- This is intentionally idempotent: if a previous live upgrade committed
    -- the Registry revision but failed while installing shared host watchers,
    -- another embedded copy can repair that incomplete runtime setup.
    LifecycleKit = existing
    previousRevision = existingRevision
end

if previousRevision ~= existingRevision then
    error("MoltenCodes LifecycleKit Registry state changed unexpectedly during bootstrap", 2)
end

-- Past this point the facade is always a table: Registry either handed one back
-- or the branch above adopted the validated `existing` implementation.
--- @cast LifecycleKit table

-- Stable public prototypes and package state --------------------------------

--- Lifecycle phase reported by `Instance:GetState()`.
--- @alias LifecycleKit.State
--- | "loading"   # the addon's `ADDON_LOADED` has not been observed yet
--- | "loaded"    # `ADDON_LOADED` completed for this addon
--- | "ready"     # the addon is loaded and the player is logged in
--- | "shutdown"  # `PLAYER_LOGOUT` was observed

--- Method prototype shared by every per-addon lifecycle instance.
---
--- Registry keeps this table's identity stable across compatible embedded
--- revisions, so instances created by an older copy observe newer methods.
--- @class LifecycleKit.Instance
local Instance = rawget(LifecycleKit, "Instance")

--- Method prototype shared by every one-shot phase subscription handle.
--- @class LifecycleKit.Subscription
local Subscription = rawget(LifecycleKit, "Subscription")

local state = rawget(LifecycleKit, "_state")

if previousRevision == nil then
    if Instance ~= nil or Subscription ~= nil or state ~= nil then
        error("MoltenCodes LifecycleKit package state is corrupted or incomplete", 2)
    end

    Instance = {}
    Subscription = {}
    state = {
        schema = STATE_SCHEMA,
        addons = {},
        globalWatchers = {},
        loginSeen = false,
        shutdownSeen = false,
    }

    rawset(LifecycleKit, "Instance", Instance)
    rawset(LifecycleKit, "Subscription", Subscription)
    rawset(LifecycleKit, "_state", state)
else
    -- An embedded copy is reusing state another copy created. Every revision of
    -- API generation 1 that this implementation accepts carries the same state
    -- schema, so one check covers both a same-revision bootstrap retry and an
    -- in-place upgrade from an older compatible revision.
    if
        type(Instance) ~= "table"
        or type(Subscription) ~= "table"
        or not validateCurrentState(LifecycleKit)
    then
        error("MoltenCodes LifecycleKit package state is corrupted or incomplete", 2)
    end
end

local INSTANCE_METATABLE = { __index = Instance }
local SUBSCRIPTION_METATABLE = { __index = Subscription }

-- Host-state probes ---------------------------------------------------------

--- Report whether `ADDON_LOADED` has already completed for `addonName`.
---
--- Both the modern and the legacy host API return `(loaded, finished)`: an addon
--- that is mid-load answers `true, false`. Only the second value confirms that
--- the `ADDON_LOADED` transition finished, so only that value is trusted here.
--- @param addonName string
--- @return boolean
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

--- Report whether the host says the player is already logged in.
--- @return boolean
local function isPlayerLoggedIn()
    -- IsLoggedIn is a World of Warcraft client API reachable only through the global table.
    -- selene: allow(global_usage)
    local probe = rawget(_G, "IsLoggedIn")
    return type(probe) == "function" and probe() == true
end

-- In-place upgrade ----------------------------------------------------------

--- Drop per-instance fields that an older compatible revision owned.
---
--- Revision 3 kept a second, redundant phase-error slot (`_phaseErrors`) beside
--- `_phaseCaptures`. This revision captures phase-callback failures through
--- `_phaseCaptures` alone, so the retired table is released when an older copy
--- hands its state over rather than being retained for the session's lifetime.
---
--- Pending revision-3 subscription closures stay correct across this upgrade:
--- they report a callback failure through `_phaseCaptures`, whose record shape
--- is unchanged, and never read `_phaseErrors` themselves.
local function releaseRetiredInstanceFields()
    if previousRevision == nil or previousRevision >= IMPLEMENTATION_REVISION then
        return
    end

    for _, instance in pairs(rawget(state, "addons")) do
        if type(instance) ~= "table" then
            error("MoltenCodes LifecycleKit package state is corrupted or incomplete", 2)
        end
        rawset(instance, "_phaseErrors", nil)
    end
end

releaseRetiredInstanceFields()

-- Subscription --------------------------------------------------------------

local function newDisconnectedSubscription()
    return setmetatable({
        _connected = false,
        _inner = nil,
    }, SUBSCRIPTION_METATABLE)
end

--- Report whether this subscription is still pending delivery.
--- @param self LifecycleKit.Subscription
--- @return boolean
local function isSubscriptionConnected(self)
    if rawget(self, "_connected") ~= true then
        return false
    end

    local inner = rawget(self, "_inner")
    if inner == nil or inner:IsConnected() ~= true then
        -- SignalKit may disconnect the inner once-listener as part of terminal
        -- phase cleanup. Keep the public LifecycleKit subscription in sync.
        rawset(self, "_connected", false)
        rawset(self, "_inner", nil)
        return false
    end

    return true
end

--- Cancel a pending subscription.
--- @param self LifecycleKit.Subscription
--- @return boolean changed `true` only when a pending subscription became disconnected
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

-- Phase machinery -----------------------------------------------------------

local function newErrorRecord(value)
    return { value = value }
end

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

--- Dispatch one phase to every pending subscriber of `instance`.
---
--- The capture record is the single error-capture protocol: subscriber wrappers
--- record the first callback failure into it while dispatch continues, so one
--- failing subscriber cannot starve the rest of a one-shot phase.
--- @return table|nil errorRecord first captured error, wrapped so that `nil` and `false` stay representable
local function firePhase(instance, signalKey)
    local signals = rawget(instance, "_signals")
    local signal = rawget(signals, signalKey)
    local captures = getPhaseCaptures(instance)
    local capture = {
        active = true,
        failed = false,
    }

    rawset(captures, signalKey, capture)
    local ok, signalError = pcall(rawget(SignalKit, "Fire"), signal, instance)
    rawset(capture, "active", false)
    rawset(captures, signalKey, nil)

    if not ok then
        return newErrorRecord(signalError)
    end
    if rawget(capture, "failed") == true then
        return newErrorRecord(rawget(capture, "value"))
    end
    return nil
end

local function markReady(instance)
    if rawget(instance, "_ready") == true or rawget(instance, "_shutdown") == true then
        return nil
    end

    rawset(instance, "_ready", true)
    return firePhase(instance, "ready")
end

local function markLoaded(instance)
    if rawget(instance, "_loaded") == true or rawget(instance, "_shutdown") == true then
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

local function markShutdown(instance)
    if rawget(instance, "_shutdown") == true then
        return nil
    end

    rawset(instance, "_shutdown", true)

    -- Once shutdown is reached, any earlier phase that was not reached can no
    -- longer occur. Drop those pending SignalKit listeners so callback closures do
    -- not remain retained behind subscriptions that can never fire.
    local signals = rawget(instance, "_signals")
    if rawget(instance, "_loaded") ~= true then
        rawget(SignalKit, "DisconnectAll")(rawget(signals, "loaded"))
    end
    if rawget(instance, "_ready") ~= true then
        rawget(SignalKit, "DisconnectAll")(rawget(signals, "ready"))
    end

    return firePhase(instance, "shutdown")
end

local function raisePhaseError(errorRecord)
    if errorRecord ~= nil then
        error(rawget(errorRecord, "value"), 0)
    end
end

local function snapshotAddonNames()
    local addons = rawget(state, "addons")
    local names = {}

    for addonName in pairs(addons) do
        names[#names + 1] = addonName
    end

    table.sort(names)
    return names
end

local function runForAllAddons(callback)
    local addons = rawget(state, "addons")
    local names = snapshotAddonNames()
    local firstError = nil

    for index = 1, #names do
        local instance = rawget(addons, names[index])
        if instance ~= nil then
            local ok, result = pcall(callback, instance)
            local candidate = result
            if not ok then
                candidate = newErrorRecord(result)
            end

            if candidate ~= nil and firstError == nil then
                firstError = candidate
            end
        end
    end

    return firstError
end

-- Shared event coordination -------------------------------------------------

local function clearGlobalWatcher(key)
    local watchers = rawget(state, "globalWatchers")
    rawset(watchers, key, nil)
end

local function disconnectGlobalWatcher(key)
    local watchers = rawget(state, "globalWatchers")
    local connection = rawget(watchers, key)
    if connection ~= nil then
        rawset(watchers, key, nil)
        connection:Disconnect()
    end
end

local function onAddonLoaded(_, addonName)
    local instance = rawget(rawget(state, "addons"), addonName)
    if instance ~= nil then
        raisePhaseError(markLoaded(instance))
    end
end

local function onPlayerLogin()
    rawset(state, "loginSeen", true)
    clearGlobalWatcher("playerLogin")

    local firstError = runForAllAddons(function(instance)
        if rawget(instance, "_loaded") == true then
            return markReady(instance)
        end
        return nil
    end)

    raisePhaseError(firstError)
end

local function onPlayerLogout()
    rawset(state, "shutdownSeen", true)
    clearGlobalWatcher("playerLogout")
    disconnectGlobalWatcher("playerLogin")
    disconnectGlobalWatcher("addonLoaded")

    local firstError = runForAllAddons(function(instance)
        return markShutdown(instance)
    end)

    raisePhaseError(firstError)
end

--- Install the shared `ADDON_LOADED` / `PLAYER_LOGIN` / `PLAYER_LOGOUT` watchers.
---
--- Idempotent: only missing watchers are created, and a partial failure rolls
--- back the watchers this call created before re-raising. Once `PLAYER_LOGOUT`
--- has been observed no watcher is installed at all, because every remaining
--- transition is already decided and instances created afterwards go straight
--- to `shutdown`.
local function ensureGlobalWatchers()
    if rawget(state, "shutdownSeen") == true then
        return
    end

    local watchers = rawget(state, "globalWatchers")
    local created = {}

    local ok, message = pcall(function()
        if rawget(watchers, "addonLoaded") == nil then
            local connection = EventKit:Connect("ADDON_LOADED", onAddonLoaded)
            rawset(watchers, "addonLoaded", connection)
            created[#created + 1] = { key = "addonLoaded", connection = connection }
        end

        if rawget(state, "loginSeen") ~= true then
            if isPlayerLoggedIn() then
                rawset(state, "loginSeen", true)
            elseif rawget(watchers, "playerLogin") == nil then
                local connection = EventKit:Once("PLAYER_LOGIN", onPlayerLogin)
                rawset(watchers, "playerLogin", connection)
                created[#created + 1] = { key = "playerLogin", connection = connection }
            end
        end

        if rawget(watchers, "playerLogout") == nil then
            local connection = EventKit:Once("PLAYER_LOGOUT", onPlayerLogout)
            rawset(watchers, "playerLogout", connection)
            created[#created + 1] = { key = "playerLogout", connection = connection }
        end
    end)

    if ok then
        return
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

local function createInstance(addonName)
    ensureGlobalWatchers()

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

    local addons = rawget(state, "addons")
    rawset(addons, addonName, instance)

    if alreadyLoaded then
        raisePhaseError(markLoaded(instance))
    end

    if rawget(state, "shutdownSeen") == true then
        raisePhaseError(markShutdown(instance))
    end

    return instance
end

-- Public instance API -------------------------------------------------------

--- Return the addon name this lifecycle instance was created for.
--- @param self LifecycleKit.Instance
--- @return string addonName
local function getAddonName(self)
    return rawget(self, "_addonName")
end

--- Return the furthest lifecycle phase this instance has reached.
--- @param self LifecycleKit.Instance
--- @return LifecycleKit.State
local function getState(self)
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

--- Report whether the `loaded` phase itself was reached.
--- @param self LifecycleKit.Instance
--- @return boolean
local function isLoaded(self)
    return rawget(self, "_loaded") == true
end

--- Report whether the `ready` phase itself was reached.
--- @param self LifecycleKit.Instance
--- @return boolean
local function isReady(self)
    return rawget(self, "_ready") == true
end

--- Report whether the `shutdown` phase itself was reached.
--- @param self LifecycleKit.Instance
--- @return boolean
local function isShutdown(self)
    return rawget(self, "_shutdown") == true
end

--- Shared implementation of `OnLoaded`, `OnReady` and `OnShutdown`.
---
--- The argument error is raised at level 3 so it points at the addon code that
--- called the public method: level 1 is this function, level 2 the public
--- method, level 3 its caller. That only holds while the public methods call
--- this function in a non-tail position; see `onLoaded` for why.
--- @param self LifecycleKit.Instance
--- @param phaseKey "loaded"|"ready"|"shutdown"
--- @param reached boolean whether the phase has already occurred
--- @param callback fun(instance: LifecycleKit.Instance)
--- @param methodName string public method name, used in the argument error
--- @return LifecycleKit.Subscription
local function subscribePhase(self, phaseKey, reached, callback, methodName)
    if type(callback) ~= "function" then
        error("LifecycleKit.Instance:" .. methodName .. " callback must be a function", 3)
    end

    if reached then
        local subscription = newDisconnectedSubscription()
        local ok, callbackError = pcall(callback, self)
        if not ok then
            -- Replay and dispatch report a failing callback the same way: the
            -- original Lua error object, re-raised unchanged once LifecycleKit
            -- has committed its own state. A subscriber cannot know which of the
            -- two paths it will take, so the two must not differ.
            error(callbackError, 0)
        end
        return subscription
    end

    if phaseKey ~= "shutdown" and rawget(self, "_shutdown") == true then
        return newDisconnectedSubscription()
    end

    local subscription = setmetatable({
        _connected = true,
        _inner = nil,
    }, SUBSCRIPTION_METATABLE)

    local signal = rawget(rawget(self, "_signals"), phaseKey)
    local inner = signal:Once(function(instance)
        rawset(subscription, "_connected", false)
        rawset(subscription, "_inner", nil)

        local ok, message = pcall(callback, instance)
        if not ok then
            local captures = getPhaseCaptures(instance)
            local capture = rawget(captures, phaseKey)
            if type(capture) == "table" and rawget(capture, "active") == true then
                if rawget(capture, "failed") ~= true then
                    -- Preserve the first callback failure, including false or
                    -- nil error objects, while keeping dispatch alive for every
                    -- subscriber already pending for this one-shot phase.
                    rawset(capture, "failed", true)
                    rawset(capture, "value", message)
                end
            else
                -- This wrapper should normally run only inside firePhase().
                -- If the internal signal is invoked outside that guard, do not
                -- silently swallow the callback failure.
                error(message, 0)
            end
        end
    end)
    rawset(subscription, "_inner", inner)
    return subscription
end

--- Subscribe to the `loaded` phase, replaying it if it already occurred.
---
--- The call to `subscribePhase` is deliberately not a tail call. Lua 5.1 drops
--- the calling frame on a tail call, which would collapse one level and make
--- `subscribePhase`'s argument error point one frame past the addon code that
--- called this method. `Errors_spec` pins the reported file and line.
--- @param self LifecycleKit.Instance
--- @param callback fun(instance: LifecycleKit.Instance)
--- @return LifecycleKit.Subscription
local function onLoaded(self, callback)
    local subscription =
        subscribePhase(self, "loaded", rawget(self, "_loaded") == true, callback, "OnLoaded")
    return subscription
end

--- Subscribe to the `ready` phase, replaying it if it already occurred.
--- @param self LifecycleKit.Instance
--- @param callback fun(instance: LifecycleKit.Instance)
--- @return LifecycleKit.Subscription
local function onReady(self, callback)
    -- Not a tail call, for the reason documented on `onLoaded`.
    local subscription =
        subscribePhase(self, "ready", rawget(self, "_ready") == true, callback, "OnReady")
    return subscription
end

--- Subscribe to the `shutdown` phase, replaying it if it already occurred.
--- @param self LifecycleKit.Instance
--- @param callback fun(instance: LifecycleKit.Instance)
--- @return LifecycleKit.Subscription
local function onShutdown(self, callback)
    -- Not a tail call, for the reason documented on `onLoaded`.
    local subscription =
        subscribePhase(self, "shutdown", rawget(self, "_shutdown") == true, callback, "OnShutdown")
    return subscription
end

-- Public package API --------------------------------------------------------

--- Return the stable lifecycle instance for `addonName`, creating it on demand.
---
--- `addonName` is matched exactly against the name WoW reports in
--- `ADDON_LOADED`, which is the addon's folder name as installed. See
--- `docs/API.md` for why the name is not normalised.
---
--- The argument error is raised at level 2 because this function is the frame
--- the consumer calls: level 1 is this function, level 2 its caller.
--- @param addonName string addon folder name, exactly as installed
--- @return LifecycleKit.Instance
local function forAddon(_, addonName)
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

-- Commit --------------------------------------------------------------------

rawset(Subscription, "Disconnect", disconnectSubscription)
rawset(Subscription, "IsConnected", isSubscriptionConnected)

rawset(Instance, "GetAddonName", getAddonName)
rawset(Instance, "GetState", getState)
rawset(Instance, "IsLoaded", isLoaded)
rawset(Instance, "IsReady", isReady)
rawset(Instance, "IsShutdown", isShutdown)
rawset(Instance, "OnLoaded", onLoaded)
rawset(Instance, "OnReady", onReady)
rawset(Instance, "OnShutdown", onShutdown)

rawset(LifecycleKit, "API", API_GENERATION)
rawset(LifecycleKit, "REVISION", IMPLEMENTATION_REVISION)
rawset(LifecycleKit, "ForAddon", forAddon)

if not validatePublicSurface(LifecycleKit) or not validateCurrentState(LifecycleKit) then
    error("MoltenCodes LifecycleKit package state is corrupted or incomplete", 2)
end

-- Re-establish shared watchers for every live compatible state. Besides normal
-- upgrades, this makes same-revision bootstrap idempotent after a prior host
-- registration failure. Reconcile globally observable one-shot phases for all
-- compatible prior revisions: a missing watcher may have allowed PLAYER_LOGIN
-- or PLAYER_LOGOUT to pass before a later embedded copy repaired the bootstrap.
if previousRevision ~= nil and next(rawget(state, "addons")) ~= nil then
    ensureGlobalWatchers()

    local firstError
    if rawget(state, "shutdownSeen") == true then
        firstError = runForAllAddons(function(instance)
            return markShutdown(instance)
        end)
    elseif rawget(state, "loginSeen") == true then
        firstError = runForAllAddons(function(instance)
            if rawget(instance, "_loaded") == true then
                return markReady(instance)
            end
            return nil
        end)
    end

    raisePhaseError(firstError)
end

return LifecycleKit
