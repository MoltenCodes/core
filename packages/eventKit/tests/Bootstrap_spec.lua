local TestEnv = require("EventKitTestEnv")

local function expectErrorContaining(expected, callback)
    local ok, message = pcall(callback)
    assert.is_false(ok)
    assert.is_not_nil(string.find(tostring(message), expected, 1, true))
end

local function installFutureEventsFacade(Registry)
    local EventKit = Registry:Register("eventKit", 1, 4)
    EventKit.API = 1
    EventKit.REVISION = 4
    EventKit.Connection = { Disconnect = function() end, IsConnected = function() end }
    EventKit.Connect = function() end
    EventKit.Once = function() end
    EventKit.ConnectUnit = function() end
    EventKit.OnceUnit = function() end
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

    it("registers EventKit API 1 revision 3", function()
        local EventKit, Registry = TestEnv.NewPackage()
        local selected, revision = Registry:Get("eventKit", 1)
        assert.are.equal(EventKit, selected)
        assert.are.equal(3, revision)
        assert.are.equal(1, EventKit.API)
        assert.are.equal(3, EventKit.REVISION)
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
        assert.are.equal(3, EventKit.REVISION)
        assert.are.equal(legacyConnectionMethods, EventKit.Connection)
        assert.are.equal(2, state.schema)
        assert.are.equal(legacyGroup, state.unitGroups["6:player"])
        assert.are.equal("6:player", legacyGroup.key)
        assert.are.equal(1, state.unitFrameCount)
        assert.are.equal(0, #state.unitFrames)
        assert.are.equal("function", type(state.dispatchRegular))
        assert.are.equal("function", type(state.isolate))
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
        assert.are.equal(4, revision)
    end)
end)
