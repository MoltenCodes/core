local TestEnv = require("EventKitTestEnv")

local function expectErrorContaining(expected, callback)
    local ok, message = pcall(callback)
    assert.is_false(ok)
    assert.is_not_nil(string.find(tostring(message), expected, 1, true))
end

local function installFutureEventsFacade(Registry)
    local EventKit = Registry:Register("eventKit", 1, 9)
    local function stub() end
    EventKit.API = 1
    EventKit.REVISION = 9
    EventKit.Connection = { Disconnect = stub, IsConnected = stub }
    EventKit.Scope = {
        Connect = stub,
        Once = stub,
        ConnectUnit = stub,
        OnceUnit = stub,
        DisconnectAll = stub,
        Close = stub,
        IsClosed = stub,
        GetAddonName = stub,
        GetActiveCount = stub,
        Coalesce = stub,
        Derive = stub,
    }
    EventKit.Connect = stub
    EventKit.Once = stub
    EventKit.ConnectUnit = stub
    EventKit.OnceUnit = stub
    EventKit.CreateScope = stub
    EventKit.Coalesce = stub
    EventKit.Derive = stub
    EventKit.ForAddon = stub
    EventKit.CloseAddonScopes = stub
    return EventKit
end

describe("EventKit package bootstrap", function()
    after_each(TestEnv.Reset)

    it("requires Registry to load first", function()
        TestEnv.Reset()
        TestEnv.InstallWowApi()
        expectErrorContaining("requires Registry API 2", function()
            require("EventKit")
        end)
    end)

    it("requires SignalKit to load first", function()
        TestEnv.Reset()
        TestEnv.InstallWowApi()
        require("Registry")
        expectErrorContaining("requires SignalKit API 1", function()
            require("EventKit")
        end)
    end)

    it("rejects an incomplete SignalKit facade", function()
        TestEnv.Reset()
        TestEnv.InstallWowApi()
        require("Registry")
        local SignalKit = require("SignalKit")
        SignalKit.Fire = nil
        expectErrorContaining("valid SignalKit API 1 facade", function()
            require("EventKit")
        end)
    end)

    it("registers EventKit API 1 revision 8", function()
        local EventKit, Registry = TestEnv.NewPackage()
        local selected, revision = Registry:Get("eventKit", 1)
        assert.are.equal(EventKit, selected)
        assert.are.equal(8, revision)
        assert.are.equal(1, EventKit.API)
        assert.are.equal(8, EventKit.REVISION)
    end)

    it("reuses the package facade across duplicate embedding", function()
        local first = TestEnv.NewPackage()
        local second = TestEnv.ReloadPackage()
        assert.are.equal(first, second)
    end)

    it("preserves active listeners across duplicate embedding", function()
        local first = TestEnv.NewPackage()
        local calls = 0
        first:Connect("PLAYER_LOGIN", function()
            calls = calls + 1
        end)
        local second = TestEnv.ReloadPackage()
        TestEnv.Emit("PLAYER_LOGIN")
        assert.are.equal(first, second)
        assert.are.equal(1, calls)
    end)

    it("keeps the connection method table stable across duplicate embedding", function()
        local first = TestEnv.NewPackage()
        local methods = first.Connection
        local second = TestEnv.ReloadPackage()
        assert.are.equal(methods, second.Connection)
    end)

    it("rejects corrupted current-revision state", function()
        local EventKit = TestEnv.NewPackage()
        EventKit._state = nil
        package.loaded["EventKit"] = nil
        expectErrorContaining("corrupted or incomplete", function()
            require("EventKit")
        end)
    end)

    it("upgrades revision-1 package state in place", function()
        TestEnv.Reset()
        TestEnv.InstallWowApi()
        local Registry = require("Registry")
        require("SignalKit")

        -- A revision-1 copy loaded first and already created a unit-filter Frame.
        -- Revision 1 kept no free list, no creation counter, no dispatch slots
        -- and no group key, so the upgrade has to supply all of them without
        -- replacing the package table or the Frame.
        local legacyFrame = { scripts = {} }
        function legacyFrame:SetScript(scriptName, callback)
            self.scripts[scriptName] = callback
        end

        local legacyGroup = { units = { "player" }, channels = {}, frame = legacyFrame }
        local legacy = Registry:Register("eventKit", 1, 1)
        legacy.API = 1
        legacy.REVISION = 1
        legacy.Connection = { Disconnect = function() end, IsConnected = function() end }
        legacy.Connect = function() end
        legacy.Once = function() end
        legacy.ConnectUnit = function() end
        legacy.OnceUnit = function() end
        legacy._state = {
            schema = 1,
            regularFrame = nil,
            regularChannels = {},
            unitGroups = { ["6:player"] = legacyGroup },
        }
        local legacyConnectionMethods = legacy.Connection

        local EventKit = require("EventKit")
        local state = EventKit._state

        assert.are.equal(legacy, EventKit)
        assert.are.equal(8, EventKit.REVISION)
        assert.are.equal(legacyConnectionMethods, EventKit.Connection)
        assert.are.equal(5, state.schema)
        assert.are.equal(legacyGroup, state.unitGroups["6:player"])
        assert.are.equal("6:player", legacyGroup.key)
        assert.are.equal(1, state.unitFrameCount)
        assert.are.equal(0, #state.unitFrames)
        assert.are.equal("function", type(state.dispatchRegular))
        assert.are.equal("function", type(state.isolate))
        assert.are.equal("table", type(state.addonScopes))
        assert.are.equal("table", type(EventKit.Scope))
    end)

    it("upgrades revision-4 package state in place", function()
        TestEnv.Reset()
        TestEnv.InstallWowApi()
        local Registry = require("Registry")
        require("SignalKit")

        -- Revision 4 left schema-2 state behind: no scope prototype, no addon
        -- scopes and no shared scope metatable.
        local function stub() end
        local legacy = Registry:Register("eventKit", 1, 4)
        legacy.API = 1
        legacy.REVISION = 4
        legacy.Connection = { Disconnect = stub, IsConnected = stub }
        legacy.Connect = stub
        legacy.Once = stub
        legacy.ConnectUnit = stub
        legacy.OnceUnit = stub
        legacy._state = {
            schema = 2,
            regularFrame = nil,
            regularChannels = {},
            unitGroups = {},
            unitFrames = {},
            unitFrameCount = 0,
            dispatchRegular = stub,
            dispatchUnit = stub,
            isolate = stub,
        }
        local legacyConnectionMethods = legacy.Connection

        local EventKit = require("EventKit")
        local state = EventKit._state

        assert.are.equal(legacy, EventKit)
        assert.are.equal(8, EventKit.REVISION)
        assert.are.equal(legacyConnectionMethods, EventKit.Connection)
        assert.are.equal(5, state.schema)
        assert.are.equal("table", type(state.addonScopes))
        assert.are.equal("table", type(EventKit.Scope))

        local scope = EventKit:CreateScope()
        scope:Connect("PLAYER_LOGIN", stub)
        assert.are.equal(1, scope:GetActiveCount())
    end)

    it("upgrades revision-5 package state in place", function()
        TestEnv.Reset()
        TestEnv.InstallWowApi()
        local Registry = require("Registry")
        require("SignalKit")

        -- Revision 5 left schema-3 state behind: scopes, but no dispatch
        -- accounting, so a scope closed mid-dispatch was swept at once.
        local function stub() end
        local legacyScopePrototype = {}
        local legacyAddonScope = setmetatable({
            _addonName = "MyAddon",
            _head = false,
            _tail = false,
            _activeCount = 0,
            _closed = false,
        }, { __index = legacyScopePrototype })
        local legacyScopeMetatable = getmetatable(legacyAddonScope)
        local legacy = Registry:Register("eventKit", 1, 5)
        legacy.API = 1
        legacy.REVISION = 5
        legacy.Connection = { Disconnect = stub, IsConnected = stub }
        legacy.Scope = legacyScopePrototype
        legacy._state = {
            schema = 3,
            regularFrame = nil,
            regularChannels = {},
            unitGroups = {},
            unitFrames = {},
            unitFrameCount = 0,
            dispatchRegular = stub,
            dispatchUnit = stub,
            isolate = stub,
            addonScopes = { MyAddon = legacyAddonScope },
            scopeMetatable = legacyScopeMetatable,
        }

        local EventKit = require("EventKit")
        local state = EventKit._state

        assert.are.equal(8, EventKit.REVISION)
        assert.are.equal(legacyScopePrototype, EventKit.Scope)
        assert.are.equal(5, state.schema)
        assert.are.equal(0, state.dispatchDepth)
        assert.are.equal(0, state.pendingScopeCount)

        -- The scope revision 5 created keeps working, now with deferred close.
        assert.are.equal(legacyAddonScope, EventKit:ForAddon("MyAddon"))
        -- The closing listener runs first, as LifecycleKit's watcher does.
        EventKit:Once("PLAYER_LOGOUT", function()
            EventKit:CloseAddonScopes("MyAddon")
        end)
        local calls = 0
        legacyAddonScope:Connect("PLAYER_LOGOUT", function()
            calls = calls + 1
        end)
        TestEnv.Emit("PLAYER_LOGOUT")
        assert.are.equal(1, calls)
        assert.are.equal(0, legacyAddonScope:GetActiveCount())
    end)

    it("upgrades revision-6 package state in place", function()
        TestEnv.Reset()
        TestEnv.InstallWowApi()
        local Registry = require("Registry")
        require("SignalKit")

        -- Revision 6 left schema-4 state behind: no Coalesce or Derive
        -- dispatch, and no handle metatables for them.
        local function stub() end
        local legacyScopePrototype = {}
        local legacyScope = setmetatable({
            _addonName = "MyAddon",
            _head = false,
            _tail = false,
            _activeCount = 0,
            _closed = false,
        }, { __index = legacyScopePrototype })
        local legacy = Registry:Register("eventKit", 1, 6)
        legacy.API = 1
        legacy.REVISION = 6
        legacy.Connection = { Disconnect = stub, IsConnected = stub }
        legacy.Scope = legacyScopePrototype
        legacy._state = {
            schema = 4,
            regularFrame = nil,
            regularChannels = {},
            unitGroups = {},
            unitFrames = {},
            unitFrameCount = 0,
            dispatchRegular = stub,
            dispatchUnit = stub,
            isolate = stub,
            addonScopes = { MyAddon = legacyScope },
            scopeMetatable = getmetatable(legacyScope),
            dispatchDepth = 0,
            pendingScopes = {},
            pendingScopeCount = 0,
        }

        local EventKit = require("EventKit")
        local state = EventKit._state
        assert.are.equal(8, EventKit.REVISION)
        assert.are.equal(5, state.schema)
        assert.is_function(state.composites.onEvent)
        assert.is_table(state.compositeMetatables.coalesce)
        assert.is_table(state.compositeMetatables.derive)

        -- The scope revision 6 created can own a Derive and sweep it.
        local derived = legacyScope:Derive("CUSTOM_EVENT", function()
            return 1
        end)
        assert.are.equal(1, legacyScope:GetActiveCount())
        EventKit:CloseAddonScopes("MyAddon")
        assert.is_true(derived:IsClosed())
        assert.are.equal(0, legacyScope:GetActiveCount())
    end)

    it("disconnects a handle shaped by a revision before scopes existed", function()
        local EventKit = TestEnv.NewPackage()
        local calls = 0
        local connection = EventKit:Connect("PLAYER_LOGIN", function()
            calls = calls + 1
        end)

        -- A revision-4 handle carries no scope link fields at all.
        rawset(connection, "_scope", nil)
        rawset(connection, "_scopePrevious", nil)
        rawset(connection, "_scopeNext", nil)

        assert.is_true(connection:Disconnect())
        TestEnv.Emit("PLAYER_LOGIN")
        assert.are.equal(0, calls)
    end)

    it("keeps serving revision-1 Frames after an in-place upgrade", function()
        -- Revision-1 Frame handlers call `EventKit._DispatchRegular`. Emulate one
        -- and prove it still reaches listeners connected by revision 2.
        local EventKit = TestEnv.NewPackage()
        local calls = 0
        EventKit:Connect("CUSTOM_EVENT", function()
            calls = calls + 1
        end)

        local function revisionOneFrameHandler(_, eventName, ...)
            local dispatcher = rawget(EventKit, "_DispatchRegular")
            dispatcher(EventKit, eventName, ...)
        end

        revisionOneFrameHandler(nil, "CUSTOM_EVENT")

        assert.are.equal(1, calls)
    end)

    it("does not downgrade a newer compatible embedded revision", function()
        TestEnv.Reset()
        TestEnv.InstallWowApi()
        local Registry = require("Registry")
        require("SignalKit")
        local future = installFutureEventsFacade(Registry)
        local loaded = require("EventKit")
        local selected, revision = Registry:Get("eventKit", 1)
        assert.are.equal(future, loaded)
        assert.are.equal(future, selected)
        assert.are.equal(9, revision)
    end)
end)
