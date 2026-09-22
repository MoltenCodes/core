local TestEnv = require("EventKitTestEnv")

local function expectErrorContaining(expected, callback)
    local ok, message = pcall(callback)
    assert.is_false(ok)
    assert.is_not_nil(string.find(tostring(message), expected, 1, true))
end

describe("EventKit errors", function()
    local EventKit
    before_each(function()
        EventKit = TestEnv.NewPackage()
    end)
    after_each(TestEnv.Reset)

    it("rejects invalid event names", function()
        expectErrorContaining("eventName must be a non-empty string", function()
            EventKit:Connect("", function() end)
        end)
        expectErrorContaining("eventName must be a non-empty string", function()
            EventKit:Connect(42, function() end)
        end)
    end)

    it("rejects non-function callbacks", function()
        expectErrorContaining("callback must be a function", function()
            EventKit:Connect("PLAYER_LOGIN", "nope")
        end)
    end)

    it("requires at least one unit token", function()
        expectErrorContaining("requires at least one unit token", function()
            EventKit:ConnectUnit("UNIT_HEALTH", function() end)
        end)
    end)

    it("rejects invalid unit tokens", function()
        expectErrorContaining("unit tokens must be non-empty strings", function()
            EventKit:ConnectUnit("UNIT_HEALTH", function() end, "player", nil)
        end)
    end)

    it("reports missing CreateFrame lazily", function()
        -- The package reads this host global at load time, so the spec has to install it in the global table.
        -- selene: allow(global_usage)
        rawset(_G, "CreateFrame", nil)
        expectErrorContaining("requires the World of Warcraft CreateFrame API", function()
            EventKit:Connect("PLAYER_LOGIN", function() end)
        end)
    end)

    it("points argument errors at the calling line, not at EventKit", function()
        local function callConnectWithABadEventName()
            EventKit:Connect("", function() end)
        end

        local function callConnectWithABadCallback()
            EventKit:Connect("PLAYER_LOGIN", "nope")
        end

        local function callConnectUnitWithTooManyTokens()
            EventKit:ConnectUnit("UNIT_HEALTH", function() end, "player", "target", "focus")
        end

        local function callConnectWithARejectedRegistration()
            TestEnv.FailNextRegisterEvent()
            EventKit:Connect("PLAYER_LOGIN", function() end)
        end

        local calls = {
            callConnectWithABadEventName,
            callConnectWithABadCallback,
            callConnectUnitWithTooManyTokens,
            callConnectWithARejectedRegistration,
        }

        for index = 1, #calls do
            local ok, message = pcall(calls[index])
            message = tostring(message)

            assert.is_false(ok)
            assert.is_not_nil(
                string.find(message, "packages/eventKit/tests/Errors_spec.lua:", 1, true)
            )
            assert.is_nil(string.find(message, "src/EventKit.lua", 1, true))
        end
    end)

    it("names the misuse when a connection method is called without a receiver", function()
        -- `EventKit.Connection` is a shared prototype, so a caller can reach these
        -- methods with no receiver at all. Without the guard the first `rawget`
        -- inside raised "bad argument #1 to 'rawget'" from EventKit's own line.
        expectErrorContaining(
            "EventKit:Disconnect must be called on a connection handle",
            function()
                EventKit.Connection.Disconnect(nil)
            end
        )

        expectErrorContaining(
            "EventKit:IsConnected must be called on a connection handle",
            function()
                EventKit.Connection.IsConnected(nil)
            end
        )

        expectErrorContaining(
            "EventKit:Disconnect must be called on a connection handle",
            function()
                EventKit.Connection.Disconnect({})
            end
        )

        expectErrorContaining(
            "EventKit:IsConnected must be called on a connection handle",
            function()
                EventKit.Connection.IsConnected("not a connection")
            end
        )
    end)

    it("points connection receiver errors at the calling line", function()
        local function callDisconnectWithoutReceiver()
            EventKit.Connection.Disconnect()
        end

        local function callIsConnectedWithoutReceiver()
            EventKit.Connection.IsConnected()
        end

        local calls = { callDisconnectWithoutReceiver, callIsConnectedWithoutReceiver }

        for index = 1, #calls do
            local ok, message = pcall(calls[index])
            message = tostring(message)

            assert.is_false(ok)
            assert.is_not_nil(
                string.find(message, "packages/eventKit/tests/Errors_spec.lua:", 1, true)
            )
            assert.is_nil(string.find(message, "src/EventKit.lua", 1, true))
        end
    end)

    it("names the package instead of a misleading line for host failures", function()
        -- These are raised two to four frames below the public API and describe
        -- the host environment, not the caller's arguments. A stack level there
        -- names a line inside EventKit, so they carry an `EventKit:` prefix and
        -- no source position at all.
        -- The package reads this host global at load time, so the spec has to install it in the global table.
        -- selene: allow(global_usage)
        rawset(_G, "CreateFrame", nil)

        local ok, message = pcall(function()
            EventKit:Connect("PLAYER_LOGIN", function() end)
        end)

        assert.is_false(ok)
        assert.are.equal(
            "EventKit: requires the World of Warcraft CreateFrame API",
            tostring(message)
        )
    end)

    it("does not retain a channel after RegisterEvent rejects it", function()
        TestEnv.FailNextRegisterEvent()
        expectErrorContaining("could not register event", function()
            EventKit:Connect("PLAYER_LOGIN", function() end)
        end)
        local frame = TestEnv.Frames()[1]
        assert.is_nil(frame.registrations.PLAYER_LOGIN)
        local connection = EventKit:Connect("PLAYER_LOGIN", function() end)
        assert.is_true(connection:IsConnected())
        assert.are.equal(2, #frame.registerEventCalls)
    end)

    it("does not retain a channel after RegisterUnitEvent rejects it", function()
        TestEnv.FailNextRegisterUnitEvent()
        expectErrorContaining("could not register event", function()
            EventKit:ConnectUnit("UNIT_HEALTH", function() end, "player")
        end)
        local frame = TestEnv.Frames()[1]
        assert.is_nil(frame.registrations.UNIT_HEALTH)
        local connection = EventKit:ConnectUnit("UNIT_HEALTH", function() end, "player")
        assert.is_true(connection:IsConnected())
        assert.are.equal(2, #frame.registerUnitEventCalls)
    end)

    it("reports a listener error instead of raising it", function()
        EventKit:Connect("CUSTOM_EVENT", function()
            error("listener failure")
        end)

        TestEnv.Emit("CUSTOM_EVENT")

        local reported = TestEnv.ReportedErrors()
        assert.are.equal(1, #reported)
        assert.is_not_nil(string.find(reported[1], "listener failure", 1, true))
    end)

    it("keeps delivering to the other tenants when the first one throws", function()
        -- EventKit is one shared instance per WoW session. A failing handler in
        -- one addon must not cost every addon behind it its event.
        local secondTenantCalls = 0
        local thirdTenantCalls = 0

        EventKit:Connect("CUSTOM_EVENT", function()
            error("first tenant failure")
        end)
        EventKit:Connect("CUSTOM_EVENT", function()
            secondTenantCalls = secondTenantCalls + 1
        end)
        EventKit:Connect("CUSTOM_EVENT", function()
            thirdTenantCalls = thirdTenantCalls + 1
        end)

        TestEnv.Emit("CUSTOM_EVENT")
        TestEnv.Emit("CUSTOM_EVENT")

        assert.are.equal(2, secondTenantCalls)
        assert.are.equal(2, thirdTenantCalls)
        assert.are.equal(2, #TestEnv.ReportedErrors())
    end)

    it("isolates listeners through securecallfunction when the client has it", function()
        TestEnv.Reset()
        TestEnv.InstallWowApi()
        TestEnv.InstallSecureCallFunction()
        require("Registry")
        require("SignalKit")
        local isolated = require("EventKit")

        local laterCalls = 0
        isolated:Connect("CUSTOM_EVENT", function()
            error("first tenant failure")
        end)
        isolated:Connect("CUSTOM_EVENT", function()
            laterCalls = laterCalls + 1
        end)

        TestEnv.Emit("CUSTOM_EVENT")

        assert.are.equal(1, laterCalls)
        assert.are.equal(1, #TestEnv.ReportedErrors())
    end)

    it("keeps large payloads and nesting intact while isolating", function()
        local outer, inner
        local nested = false

        EventKit:Connect("WIDE_EVENT", function(...)
            outer = { select("#", ...), ... }
            if not nested then
                nested = true
                TestEnv.Emit("NESTED_EVENT", "a", nil, "c")
            end
        end)
        EventKit:Connect("NESTED_EVENT", function(...)
            inner = { select("#", ...), ... }
        end)

        TestEnv.Emit("WIDE_EVENT", 1, 2, 3, 4, 5, 6, 7, 8, 9)

        assert.are.equal(10, outer[1])
        assert.are.equal("WIDE_EVENT", outer[2])
        assert.are.equal(9, outer[11])
        assert.are.equal(4, inner[1])
        assert.are.equal("NESTED_EVENT", inner[2])
        assert.are.equal("a", inner[3])
        assert.is_nil(inner[4])
        assert.are.equal("c", inner[5])
    end)
end)
