local TestEnv = require("LifecycleKitTestEnv")

local function expectErrorContaining(expected, callback)
    local ok, message = pcall(callback)
    assert.is_false(ok)
    assert.is_not_nil(string.find(tostring(message), expected, 1, true))
end

describe("LifecycleKit package bootstrap", function()
    after_each(TestEnv.Reset)

    it("requires Registry to load first", function()
        TestEnv.Reset()
        TestEnv.InstallWowApi()
        expectErrorContaining("requires Registry API 2", function() require("LifecycleKit") end)
    end)

    it("requires SignalKit and EventKit to load first", function()
        TestEnv.Reset()
        TestEnv.InstallWowApi()
        require("Registry")
        expectErrorContaining("requires SignalKit API 1", function() require("LifecycleKit") end)
        require("SignalKit")
        expectErrorContaining("requires EventKit API 1", function() require("LifecycleKit") end)
    end)

    it("registers LifecycleKit API 1 revision 3", function()
        local LifecycleKit, Registry = TestEnv.NewPackage()
        local selected, revision = Registry:Get("lifecycleKit", 1)
        assert.are.equal(LifecycleKit, selected)
        assert.are.equal(3, revision)
        assert.are.equal(1, LifecycleKit.API)
        assert.are.equal(3, LifecycleKit.REVISION)
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
        life:OnLoaded(function() calls = calls + 1 end)

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

        local future = Registry:Register("lifecycleKit", 1, 4)
        future.API = 1
        future.REVISION = 4
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
        assert.are.equal(4, revision)
    end)

    it("keeps revision-2 pending phase callbacks compatible across upgrade", function()
        local LifecycleKit, Registry, SignalKit = TestEnv.NewPackage()
        local life = LifecycleKit:ForAddon("LegacyPending")
        local laterCalls = 0

        -- Model a pending subscription closure created by revision 2. Revision
        -- 2 used _phaseErrors[phase] = false as its active dispatch sentinel.
        local loadedSignal = life._signals.loaded
        SignalKit.Once(loadedSignal, function(instance)
            local ok, message = pcall(function() error("legacy failure") end)
            if not ok then
                local current = instance._phaseErrors.loaded
                if current == false then
                    instance._phaseErrors.loaded = message
                else
                    error(message, 0)
                end
            end
        end)
        life:OnLoaded(function() laterCalls = laterCalls + 1 end)

        expectErrorContaining("legacy failure", function() TestEnv.LoadAddon("LegacyPending") end)
        assert.are.equal(1, laterCalls)
        local selected, revision = Registry:Get("lifecycleKit", 1)
        assert.are.equal(LifecycleKit, selected)
        assert.are.equal(3, revision)
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
        EventKit.Once = function() error("synthetic watcher failure") end
        package.loaded["LifecycleKit"] = nil
        expectErrorContaining("synthetic watcher failure", function() require("LifecycleKit") end)
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
        expectErrorContaining("corrupted or incomplete", function() require("LifecycleKit") end)
    end)
    it("repairs a revision-1 instance that missed PLAYER_LOGIN during live upgrade", function()
        TestEnv.Reset()
        TestEnv.InstallWowApi()
        local Registry = require("Registry")
        local SignalKit = require("SignalKit")
        require("EventKit")

        local old = Registry:Register("lifecycleKit", 1, 1)
        old.API = 1
        old.REVISION = 1
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
            _addonName = "MissedLogin",
            _loaded = true,
            _ready = false,
            _shutdown = false,
            _loginSeen = false,
            _signals = {
                loaded = SignalKit:New(),
                ready = SignalKit:New(),
                shutdown = SignalKit:New(),
            },
            _phaseErrors = {},
            _watchers = {},
        }, { __index = old.Instance })
        old._state = { schema = 1, addons = { MissedLogin = instance } }

        TestEnv.SetLoggedIn(true)
        local upgraded = require("LifecycleKit")

        assert.are.equal(old, upgraded)
        assert.are.equal(3, upgraded.REVISION)
        assert.is_true(instance:IsReady())
    end)

    it("repairs partially delivered revision-1 shutdown state during live upgrade", function()
        TestEnv.Reset()
        TestEnv.InstallWowApi()
        local Registry = require("Registry")
        local SignalKit = require("SignalKit")
        require("EventKit")

        local old = Registry:Register("lifecycleKit", 1, 1)
        old.API = 1
        old.REVISION = 1
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

        local function makeInstance(name, shutdown)
            return setmetatable({
                _addonName = name,
                _loaded = true,
                _ready = true,
                _shutdown = shutdown,
                _loginSeen = true,
                _signals = {
                    loaded = SignalKit:New(),
                    ready = SignalKit:New(),
                    shutdown = SignalKit:New(),
                },
                _phaseErrors = {},
                _watchers = {},
            }, { __index = old.Instance })
        end

        local first = makeInstance("First", true)
        local starved = makeInstance("Starved", false)
        old._state = { schema = 1, addons = { First = first, Starved = starved } }

        local upgraded = require("LifecycleKit")

        assert.are.equal(old, upgraded)
        assert.is_true(first:IsShutdown())
        assert.is_true(starved:IsShutdown())
    end)

end)
