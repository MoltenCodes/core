local TestEnv = require("SignalKitTestEnv")

local SPEC_FILE = "packages/signalKit/tests/BusScope_spec.lua:"

---Assert that `callback` raises a message naming `expected` at this spec file's
---line rather than somewhere inside the package.
---@param expected string
---@param callback fun()
local function expectRefusalAtCaller(expected, callback)
    TestEnv.ExpectRefusalAtCaller(SPEC_FILE, expected, callback)
end

describe("SignalKit bus scopes", function()
    local SignalKit
    local bus

    before_each(function()
        SignalKit = TestEnv.NewPackage()
        bus = SignalKit:Bus("Scoped", { openTopics = true })
    end)

    after_each(TestEnv.Reset)

    it("releases every subscription it owns on DisconnectAll and stays reusable", function()
        local scope = bus:CreateScope()
        local calls = {}
        local owned = scope:Subscribe("Topic", function()
            calls[#calls + 1] = "owned"
        end)
        scope:SubscribeOnce("Other", function()
            calls[#calls + 1] = "once"
        end)
        bus:Subscribe("Topic", function()
            calls[#calls + 1] = "unscoped"
        end)

        assert.are.equal(2, scope:DisconnectAll())
        assert.is_false(owned:IsConnected())
        assert.is_false(scope:IsClosed())

        scope:Subscribe("Topic", function()
            calls[#calls + 1] = "again"
        end)
        bus:Publish("Topic")
        bus:Publish("Other")

        assert.are.same({ "unscoped", "again" }, calls)
    end)

    it("counts only subscriptions still connected", function()
        local scope = bus:CreateScope()
        local first = scope:Subscribe("Topic", function() end)
        scope:SubscribeOnce("Topic", function() end)
        scope:Subscribe("Topic", function() end)

        first:Disconnect()
        bus:Publish("Topic")

        assert.are.equal(1, scope:DisconnectAll())
    end)

    it("closes terminally and refuses new subscriptions at the caller", function()
        local scope = bus:CreateScope()
        local connection = scope:Subscribe("Topic", function() end)

        assert.is_true(scope:Close())
        assert.is_false(scope:Close())
        assert.is_true(scope:IsClosed())
        assert.is_false(connection:IsConnected())

        expectRefusalAtCaller(
            "SignalKit.BusScope:Subscribe cannot subscribe in a closed scope",
            function()
                scope:Subscribe("Topic", function() end)
            end
        )
        expectRefusalAtCaller(
            "SignalKit.BusScope:SubscribeOnce cannot subscribe in a closed scope",
            function()
                scope:SubscribeOnce("Topic", function() end)
            end
        )
    end)

    it("skips its later subscribers when closed during a publish, as a signal would", function()
        local scope = bus:CreateScope()
        local calls = {}
        bus:Subscribe("Topic", function()
            calls[#calls + 1] = "closer"
            scope:Close()
        end)
        scope:Subscribe("Topic", function()
            calls[#calls + 1] = "scoped"
        end)

        bus:Publish("Topic")

        assert.are.same({ "closer" }, calls)
    end)

    it("reports argument and receiver errors at the caller", function()
        local scope = bus:CreateScope()

        expectRefusalAtCaller(
            "SignalKit.BusScope:Subscribe topic must be a non-empty string",
            function()
                scope:Subscribe(nil, function() end)
            end
        )
        expectRefusalAtCaller("SignalKit.BusScope:Subscribe callback must be a function", function()
            scope:Subscribe("Topic", 7)
        end)
        expectRefusalAtCaller("must be called on a SignalKit bus scope", function()
            scope.Subscribe("Topic", function() end)
        end)
        expectRefusalAtCaller("must be called on a SignalKit bus scope", function()
            scope.Close()
        end)
    end)

    it("answers nil and full when the topic is at its listener cap", function()
        for _ = 1, 256 do
            bus:Subscribe("Crowded", function() end)
        end
        local scope = bus:CreateScope()

        local connection, reason = scope:Subscribe("Crowded", function() end)

        assert.is_nil(connection)
        assert.are.equal("full", reason)
        assert.are.equal(0, scope:DisconnectAll())
    end)

    it("compacts on direct disconnects, without waiting for the next subscription", function()
        local scope = bus:CreateScope()
        local connections = {}
        for index = 1, 100 do
            connections[index] = scope:Subscribe("Topic", function() end)
        end

        for index = 1, 100 do
            connections[index]:Disconnect()
            local live = 100 - index
            -- Private field, read only to pin the retention bound.
            assert.is_true(rawget(scope, "_count") <= live * 2 + 1)
        end

        assert.are.equal(0, rawget(scope, "_count"))
        assert.are.equal(0, scope:DisconnectAll())
    end)

    it("compacts when Unsubscribe or the bus closing disconnects its subscriptions", function()
        local addonBus = SignalKit:ForAddon("Compacting")
        local scope = addonBus:CreateScope()
        local shared = function() end
        for _ = 1, 50 do
            scope:Subscribe("Topic", shared)
        end
        scope:Subscribe("Other", function() end)

        assert.are.equal(50, addonBus:Unsubscribe("Topic", shared))
        assert.is_true(rawget(scope, "_count") <= 3)

        SignalKit:CloseAddonBus("Compacting")
        assert.are.equal(0, rawget(scope, "_count"))
    end)

    it("keeps its connection list within twice its live subscriptions", function()
        local scope = bus:CreateScope()
        scope:Subscribe("Kept", function() end)

        for _ = 1, 1000 do
            scope:SubscribeOnce("Churn", function() end)
            bus:Publish("Churn")
        end

        -- Private field, read only to pin the retention bound.
        assert.is_true(rawget(scope, "_count") <= 16)
        assert.are.equal(1, scope:DisconnectAll())
    end)
end)

describe("SignalKit addon buses", function()
    local SignalKit

    before_each(function()
        SignalKit = TestEnv.NewPackage()
    end)

    after_each(TestEnv.Reset)

    it("returns the bus named after the addon", function()
        local bus = SignalKit:ForAddon("MyAddon")

        assert.are.equal(bus, SignalKit:Bus("MyAddon"))
        assert.are.equal(bus, SignalKit:ForAddon("MyAddon"))
    end)

    it("closes the addon bus terminally, disconnecting every subscriber", function()
        local bus = SignalKit:ForAddon("MyAddon")
        bus:DeclareTopic("Ready")
        local calls = 0
        local connection = bus:Subscribe("Ready", function()
            calls = calls + 1
        end)
        local scope = bus:CreateScope()
        local scoped = scope:Subscribe("Ready", function()
            calls = calls + 1
        end)

        assert.is_true(SignalKit:CloseAddonBus("MyAddon"))
        assert.is_false(SignalKit:CloseAddonBus("MyAddon"))

        assert.is_false(connection:IsConnected())
        assert.is_false(scoped:IsConnected())
        -- A late publish from another addon's shutdown path delivers nothing
        -- and does not raise, even for an undeclared topic.
        bus:Publish("Ready")
        bus:Publish("Undeclared")
        assert.are.equal(0, calls)

        assert.are.equal(bus, SignalKit:ForAddon("MyAddon"))
        expectRefusalAtCaller('cannot subscribe on the closed bus "MyAddon"', function()
            bus:Subscribe("Ready", function() end)
        end)
        expectRefusalAtCaller('cannot subscribe on the closed bus "MyAddon"', function()
            scope:Subscribe("Ready", function() end)
        end)
        expectRefusalAtCaller('cannot create a scope on the closed bus "MyAddon"', function()
            bus:CreateScope()
        end)
        -- Declaring on a closed bus is refused, so it cannot spend a topic slot.
        expectRefusalAtCaller('cannot declare on the closed bus "MyAddon"', function()
            bus:DeclareTopic("Late")
        end)
        assert.are.same({ "Ready" }, bus:Topics())
        -- The topic name is still type-checked on a closed bus.
        expectRefusalAtCaller("SignalKit.Bus:Publish topic must be a non-empty string", function()
            bus:Publish(42)
        end)
    end)

    it("answers false for an addon that never asked for a bus", function()
        assert.is_false(SignalKit:CloseAddonBus("NeverAsked"))
        -- Nothing was recorded, so no bus slot was spent.
        assert.is_false(SignalKit:ForAddon("NeverAsked"):CreateScope():IsClosed())
    end)

    it("validates addon names and the facade receiver at the caller", function()
        expectRefusalAtCaller("SignalKit:ForAddon addonName must be a non-empty string", function()
            SignalKit:ForAddon("")
        end)
        expectRefusalAtCaller(
            "SignalKit:CloseAddonBus addonName must be a non-empty string",
            function()
                SignalKit:CloseAddonBus(nil)
            end
        )
        expectRefusalAtCaller(
            "SignalKit:CloseAddonBus must be called on the SignalKit facade",
            function()
                SignalKit.CloseAddonBus("MyAddon")
            end
        )
    end)
end)
