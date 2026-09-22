local TestEnv = require("EventKitTestEnv")

local function expectErrorContaining(expected, callback)
    local ok, message = pcall(callback)
    assert.is_false(ok)
    assert.is_not_nil(string.find(tostring(message), expected, 1, true))
end

local function installFutureEventsFacade(Registry)
    local EventKit = Registry:Register("eventKit", 1, 2)
    EventKit.API = 1
    EventKit.REVISION = 2
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
        expectErrorContaining("requires Registry API 2", function() require("EventKit") end)
    end)

    it("requires SignalKit to load first", function()
        TestEnv.Reset()
        TestEnv.InstallWowApi()
        require("Registry")
        expectErrorContaining("requires SignalKit API 1", function() require("EventKit") end)
    end)

    it("rejects an incomplete SignalKit facade", function()
        TestEnv.Reset()
        TestEnv.InstallWowApi()
        require("Registry")
        local SignalKit = require("SignalKit")
        SignalKit.Fire = nil
        expectErrorContaining("valid SignalKit API 1 facade", function() require("EventKit") end)
    end)

    it("registers EventKit API 1 revision 1", function()
        local EventKit, Registry = TestEnv.NewPackage()
        local selected, revision = Registry:Get("eventKit", 1)
        assert.are.equal(EventKit, selected)
        assert.are.equal(1, revision)
        assert.are.equal(1, EventKit.API)
        assert.are.equal(1, EventKit.REVISION)
    end)

    it("reuses the package facade across duplicate embedding", function()
        local first = TestEnv.NewPackage()
        local second = TestEnv.ReloadPackage()
        assert.are.equal(first, second)
    end)

    it("preserves active listeners across duplicate embedding", function()
        local first = TestEnv.NewPackage()
        local calls = 0
        first:Connect("PLAYER_LOGIN", function() calls = calls + 1 end)
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
        expectErrorContaining("corrupted or incomplete", function() require("EventKit") end)
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
        assert.are.equal(2, revision)
    end)
end)
