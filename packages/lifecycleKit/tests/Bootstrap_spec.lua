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

    it("registers LifecycleKit API 1 revision 5", function()
        local LifecycleKit, Registry = TestEnv.NewPackage()
        local selected, revision = Registry:Get("lifecycleKit", 1)
        assert.are.equal(LifecycleKit, selected)
        assert.are.equal(5, revision)
        assert.are.equal(1, LifecycleKit.API)
        assert.are.equal(5, LifecycleKit.REVISION)
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

        local future = Registry:Register("lifecycleKit", 1, 6)
        future.API = 1
        future.REVISION = 6
        future.Instance = {
            GetAddonName = function() end,
            GetState = function() end,
            IsLoaded = function() end,
            IsReady = function() end,
            IsShutdown = function() end,
            OnLoaded = function() end,
            OnReady = function() end,
            OnShutdown = function() end,
        }
        future.Subscription = { Disconnect = function() end, IsConnected = function() end }
        future.ForAddon = function() end

        local loaded = require("LifecycleKit")
        local selected, revision = Registry:Get("lifecycleKit", 1)
        assert.are.equal(future, loaded)
        assert.are.equal(future, selected)
        assert.are.equal(6, revision)
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
        old.Instance = {
            GetAddonName = function() end,
            GetState = function() end,
            IsLoaded = function() end,
            IsReady = function() end,
            IsShutdown = function() end,
            OnLoaded = function() end,
            OnReady = function() end,
            OnShutdown = function() end,
        }
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
        assert.are.equal(5, upgraded.REVISION)
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
end)
