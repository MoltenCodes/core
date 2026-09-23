local TestEnv = require("LifecycleKitTestEnv")

local function expectErrorContaining(expected, callback)
    local ok, message = pcall(callback)
    assert.is_false(ok)
    assert.is_not_nil(string.find(tostring(message), expected, 1, true))
end

-- Lua 5.1 leaves a sentinel in `package.loaded` when a `require` raises, so a
-- second `require` of the same module reports "loop or previous error loading
-- module" instead of re-running the chunk. Clearing the sentinel is what lets a
-- single test observe more than one bootstrap guard.
local function requireAfterFailedLoad(moduleName)
    package.loaded[moduleName] = nil
    return require(moduleName)
end

-- Instance prototypes that model other revisions' published surfaces. Only the
-- presence of each method matters to the bootstrap checks under test.
local REVISION_6_METHODS = {
    "GetAddonName",
    "GetState",
    "IsLoaded",
    "IsReady",
    "IsShutdown",
    "OnLoaded",
    "OnReady",
    "OnShutdown",
}

local REVISION_7_METHODS = {
    "IsHalted",
    "GetHaltReason",
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

local function addMethods(prototype, methodNames)
    for index = 1, #methodNames do
        prototype[methodNames[index]] = function() end
    end
    return prototype
end

local function newRevision6InstancePrototype()
    return addMethods({}, REVISION_6_METHODS)
end

local function newInstancePrototype()
    return addMethods(newRevision6InstancePrototype(), REVISION_7_METHODS)
end

describe("LifecycleKit package bootstrap", function()
    after_each(TestEnv.Reset)

    it("requires Registry to load first", function()
        TestEnv.Reset()
        TestEnv.InstallWowApi()
        expectErrorContaining("requires Registry API 2", function()
            require("LifecycleKit")
        end)
    end)

    it("requires SignalKit to load first", function()
        TestEnv.Reset()
        TestEnv.InstallWowApi()
        require("Registry")
        expectErrorContaining("requires SignalKit API 1", function()
            require("LifecycleKit")
        end)
    end)

    it("requires EventKit to load first", function()
        TestEnv.Reset()
        TestEnv.InstallWowApi()
        require("Registry")
        expectErrorContaining("requires SignalKit API 1", function()
            require("LifecycleKit")
        end)

        require("SignalKit")
        expectErrorContaining("requires EventKit API 1", function()
            requireAfterFailedLoad("LifecycleKit")
        end)
    end)

    it("registers LifecycleKit API 1 revision 13", function()
        local LifecycleKit, Registry = TestEnv.NewPackage()
        local selected, revision = Registry:Get("lifecycleKit", 1)
        assert.are.equal(LifecycleKit, selected)
        assert.are.equal(13, revision)
        assert.are.equal(1, LifecycleKit.API)
        assert.are.equal(13, LifecycleKit.REVISION)
    end)

    it("reuses facade and addon instances across duplicate embedding", function()
        local first = TestEnv.NewPackage()
        local instance = first:ForAddon("MyAddon")
        local second = TestEnv.ReloadPackage()
        assert.are.equal(first, second)
        assert.are.equal(instance, second:ForAddon("MyAddon"))
    end)

    it("preserves pending phase subscriptions across duplicate embedding", function()
        local first = TestEnv.NewPackage()
        local life = first:ForAddon("MyAddon")
        local calls = 0
        life:OnLoaded(function()
            calls = calls + 1
        end)

        local second = TestEnv.ReloadPackage()
        TestEnv.LoadAddon("MyAddon")
        assert.are.equal(first, second)
        assert.are.equal(1, calls)
    end)

    it("does not downgrade a newer compatible embedded revision", function()
        TestEnv.Reset()
        TestEnv.InstallWowApi()
        local Registry = require("Registry")
        require("SignalKit")
        require("EventKit")

        local future = Registry:Register("lifecycleKit", 1, 14)
        future.API = 1
        future.REVISION = 14
        future.Instance = newInstancePrototype()
        future.Subscription = { Disconnect = function() end, IsConnected = function() end }
        future.DeferredCall = { Cancel = function() end, IsPending = function() end }
        future.ForAddon = function() end
        future.IsInCombat = function() end
        future.UNBOUNDED = {}
        future.SetLimits = function() end
        future.GetLimits = function() end
        future.CLOSES_ADDON_SCOPES = {}

        local loaded = require("LifecycleKit")
        local selected, revision = Registry:Get("lifecycleKit", 1)
        assert.are.equal(future, loaded)
        assert.are.equal(future, selected)
        assert.are.equal(14, revision)
    end)

    it("refuses a newer revision that lacks CLOSES_ADDON_SCOPES", function()
        TestEnv.Reset()
        TestEnv.InstallWowApi()
        local Registry = require("Registry")
        require("SignalKit")
        require("EventKit")

        -- The capability field is part of the public surface from revision
        -- 13 on: the scope-owning Kits read it to decide who closes their
        -- addon scopes at logout.
        local future = Registry:Register("lifecycleKit", 1, 14)
        future.API = 1
        future.REVISION = 14
        future.Instance = newInstancePrototype()
        future.Subscription = { Disconnect = function() end, IsConnected = function() end }
        future.DeferredCall = { Cancel = function() end, IsPending = function() end }
        future.ForAddon = function() end
        future.IsInCombat = function() end
        future.UNBOUNDED = {}
        future.SetLimits = function() end
        future.GetLimits = function() end

        expectErrorContaining("corrupted or incomplete", function()
            require("LifecycleKit")
        end)
    end)

    it("refuses a newer revision that lacks the combat gate surface", function()
        TestEnv.Reset()
        TestEnv.InstallWowApi()
        local Registry = require("Registry")
        require("SignalKit")
        require("EventKit")

        -- A revision 14 that publishes only the revision 6 surface is not a
        -- compatible successor: consumers of revision 7 and later would call
        -- methods it does not have.
        local future = Registry:Register("lifecycleKit", 1, 14)
        future.API = 1
        future.REVISION = 14
        future.Instance = newRevision6InstancePrototype()
        future.Subscription = { Disconnect = function() end, IsConnected = function() end }
        future.ForAddon = function() end

        expectErrorContaining("corrupted or incomplete", function()
            require("LifecycleKit")
        end)
    end)

    it("retries shared watcher setup after a same-revision bootstrap failure", function()
        local LifecycleKit, _, _, EventKit = TestEnv.NewPackage()
        local life = LifecycleKit:ForAddon("RetryAddon")
        TestEnv.LoadAddon("RetryAddon")

        local state = LifecycleKit._state
        local loginWatcher = state.globalWatchers.playerLogin
        assert.is_not_nil(loginWatcher)
        loginWatcher:Disconnect()
        state.globalWatchers.playerLogin = nil

        local originalOnce = EventKit.Once
        EventKit.Once = function()
            error("synthetic watcher failure")
        end
        package.loaded["LifecycleKit"] = nil
        expectErrorContaining("synthetic watcher failure", function()
            require("LifecycleKit")
        end)
        EventKit.Once = originalOnce

        package.loaded["LifecycleKit"] = nil
        local recovered = require("LifecycleKit")
        assert.are.equal(LifecycleKit, recovered)

        TestEnv.Login()
        assert.is_true(life:IsReady())
    end)

    it("catches up loaded instances after a missed login watcher", function()
        local LifecycleKit = TestEnv.NewPackage()
        local life = LifecycleKit:ForAddon("CatchUpAddon")
        TestEnv.LoadAddon("CatchUpAddon")

        local state = LifecycleKit._state
        local loginWatcher = state.globalWatchers.playerLogin
        assert.is_not_nil(loginWatcher)
        loginWatcher:Disconnect()
        state.globalWatchers.playerLogin = nil

        TestEnv.Login()
        assert.is_false(life:IsReady())

        package.loaded["LifecycleKit"] = nil
        local recovered = require("LifecycleKit")
        assert.are.equal(LifecycleKit, recovered)
        assert.is_true(life:IsReady())
    end)

    it("rejects corrupted current-revision state", function()
        local LifecycleKit = TestEnv.NewPackage()
        LifecycleKit._state = nil
        package.loaded["LifecycleKit"] = nil
        expectErrorContaining("corrupted or incomplete", function()
            require("LifecycleKit")
        end)
    end)
    it("releases the retired revision-3 capture slot during an in-place upgrade", function()
        TestEnv.Reset()
        TestEnv.InstallWowApi()
        local Registry = require("Registry")
        local SignalKit = require("SignalKit")
        require("EventKit")

        -- Model the shared state a revision-3 embedded copy leaves behind: the
        -- same schema, plus the retired per-instance `_phaseErrors` slot.
        local old = Registry:Register("lifecycleKit", 1, 3)
        old.API = 1
        old.REVISION = 3
        old.Instance = newRevision6InstancePrototype()
        old.Subscription = { Disconnect = function() end, IsConnected = function() end }
        old.ForAddon = function() end

        local instance = setmetatable({
            _addonName = "CarriedOver",
            _loaded = true,
            _ready = false,
            _shutdown = false,
            _signals = {
                loaded = SignalKit:New(),
                ready = SignalKit:New(),
                shutdown = SignalKit:New(),
            },
            _phaseErrors = {},
            _phaseCaptures = {},
        }, { __index = old.Instance })
        old._state = {
            schema = 2,
            addons = { CarriedOver = instance },
            globalWatchers = {},
            loginSeen = false,
            shutdownSeen = false,
        }

        local upgraded = require("LifecycleKit")

        assert.are.equal(old, upgraded)
        assert.are.equal(13, upgraded.REVISION)
        assert.are.equal(instance, upgraded:ForAddon("CarriedOver"))
        assert.is_nil(rawget(instance, "_phaseErrors"))

        -- The carried-over instance still dispatches through the new capture
        -- protocol, so an upgrade does not strand its pending phases.
        local readyCalls = 0
        instance:OnReady(function()
            readyCalls = readyCalls + 1
        end)
        TestEnv.Login()
        assert.is_true(instance:IsReady())
        assert.are.equal(1, readyCalls)
    end)
    -- Models the shared state a revision 6 copy leaves behind: schema 2, no
    -- combat flag or instance list, instances without the gate fields, and
    -- host watchers that call revision 6's handlers.
    local function registerRevision6(Registry, SignalKit, EventKit)
        local old = Registry:Register("lifecycleKit", 1, 6)
        old.API = 1
        old.REVISION = 6
        old.Instance = newRevision6InstancePrototype()
        old.Subscription = { Disconnect = function() end, IsConnected = function() end }
        old.ForAddon = function() end

        local oldHandlerCalls = { count = 0 }
        local function oldHandler()
            oldHandlerCalls.count = oldHandlerCalls.count + 1
        end

        local instance = setmetatable({
            _addonName = "CarriedOver",
            _loaded = false,
            _ready = false,
            _shutdown = false,
            _signals = {
                loaded = SignalKit:New(),
                ready = SignalKit:New(),
                shutdown = SignalKit:New(),
            },
            _phaseCaptures = {},
        }, { __index = old.Instance })
        old._state = {
            schema = 2,
            addons = { CarriedOver = instance },
            globalWatchers = {
                addonLoaded = EventKit:Connect("ADDON_LOADED", oldHandler),
                playerLogin = EventKit:Once("PLAYER_LOGIN", oldHandler),
                playerLogout = EventKit:Once("PLAYER_LOGOUT", oldHandler),
            },
            loginSeen = false,
            shutdownSeen = false,
        }
        return old, instance, oldHandlerCalls
    end

    it("upgrades revision 6 state to schema 3 and carries pending phases", function()
        TestEnv.Reset()
        TestEnv.InstallWowApi()
        local Registry = require("Registry")
        local SignalKit = require("SignalKit")
        local EventKit = require("EventKit")
        local old, instance, oldHandlerCalls = registerRevision6(Registry, SignalKit, EventKit)
        local oldLoadedWatcher = old._state.globalWatchers.addonLoaded

        -- A pending subscription revision 6 created: a SignalKit once-listener
        -- on the instance's own signal, which the upgrade must not strand.
        local loadedCalls = 0
        instance._signals.loaded:Once(function()
            loadedCalls = loadedCalls + 1
        end)

        TestEnv.SetCombatLockdown(true)
        local upgraded = require("LifecycleKit")

        assert.are.equal(old, upgraded)
        assert.are.equal(13, upgraded.REVISION)
        assert.are.equal(3, upgraded._state.schema)
        assert.are.same({ instance }, upgraded._state.instances)
        assert.is_true(upgraded:IsInCombat())
        assert.are.equal(instance, upgraded:ForAddon("CarriedOver"))
        assert.are.equal("table", type(upgraded.DeferredCall))

        -- Revision 6's watchers are replaced, so its handlers no longer run.
        assert.is_false(oldLoadedWatcher:IsConnected())
        TestEnv.LoadAddon("CarriedOver")
        TestEnv.Login()
        assert.are.equal(0, oldHandlerCalls.count)
        assert.are.equal(1, loadedCalls)
        assert.are.equal("ready", instance:GetState())

        -- The carried-over instance has a working combat gate and can halt.
        local ran = false
        local handle = instance:WhenOutOfCombat(function()
            ran = true
        end)
        assert.is_true(handle:IsPending())
        TestEnv.LeaveCombat()
        assert.is_true(ran)
        assert.is_true(instance:Halt("carried over and broken"))
        assert.are.equal("halted", instance:GetState())
    end)

    it("rejects older-revision state whose schema it does not know", function()
        TestEnv.Reset()
        TestEnv.InstallWowApi()
        local Registry = require("Registry")
        local SignalKit = require("SignalKit")
        local EventKit = require("EventKit")
        local old = registerRevision6(Registry, SignalKit, EventKit)
        old._state.schema = 1

        expectErrorContaining("corrupted or incomplete", function()
            require("LifecycleKit")
        end)
    end)

    it("repairs missing combat watchers and reconciles the combat state", function()
        local LifecycleKit = TestEnv.NewPackage()
        local life = LifecycleKit:ForAddon("MyAddon")
        TestEnv.LoadAddon("MyAddon")
        local starts = 0
        life:OnCombatStart(function()
            starts = starts + 1
        end)

        local watchers = LifecycleKit._state.globalWatchers
        watchers.combatStart:Disconnect()
        watchers.combatStart = nil
        TestEnv.SetCombatLockdown(true)

        package.loaded["LifecycleKit"] = nil
        assert.are.equal(LifecycleKit, require("LifecycleKit"))

        assert.is_true(LifecycleKit:IsInCombat())
        assert.are.equal(1, starts)
        TestEnv.LeaveCombat()
        assert.is_false(LifecycleKit:IsInCombat())
    end)
end)
