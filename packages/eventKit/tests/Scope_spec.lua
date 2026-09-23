local TestEnv = require("EventKitTestEnv")

local function noop() end

---Measures the allocation a workload causes, in kilobytes, with the collector
---stopped so that a collection cycle cannot hide or invent growth.
local function allocatedKilobytes(workload)
    collectgarbage()
    collectgarbage("stop")
    local before = collectgarbage("count")
    workload()
    local after = collectgarbage("count")
    collectgarbage("restart")
    return after - before
end

---Assert that `callback` fails with `expected` at a line of this spec file.
local function expectErrorAtThisSpec(expected, callback)
    local ok, message = pcall(callback)
    message = tostring(message)
    assert.is_false(ok)
    assert.is_not_nil(string.find(message, expected, 1, true))
    assert.is_not_nil(string.find(message, "packages/eventKit/tests/Scope_spec.lua:", 1, true))
end

describe("EventKit scopes", function()
    local EventKit
    before_each(function()
        EventKit = TestEnv.NewPackage()
    end)
    after_each(TestEnv.Reset)

    it("counts the live connections made through a manual scope", function()
        local scope = EventKit:CreateScope()

        assert.is_nil(scope:GetAddonName())
        assert.is_false(scope:IsClosed())
        assert.are.equal(0, scope:GetActiveCount())

        scope:Connect("PLAYER_LOGIN", noop)
        scope:Once("PLAYER_LOGOUT", noop)
        scope:ConnectUnit("UNIT_HEALTH", noop, "player")
        scope:OnceUnit("UNIT_POWER_UPDATE", noop, "player", "target")

        assert.are.equal(4, scope:GetActiveCount())
    end)

    it("delivers events to scoped listeners exactly like package-level ones", function()
        local scope = EventKit:CreateScope()
        local received = {}
        scope:Connect("CUSTOM_EVENT", function(eventName, value)
            received[#received + 1] = eventName .. ":" .. tostring(value)
        end)
        scope:ConnectUnit("UNIT_HEALTH", function(eventName, unit)
            received[#received + 1] = eventName .. ":" .. unit
        end, "player")

        TestEnv.Emit("CUSTOM_EVENT", 7)
        TestEnv.Emit("UNIT_HEALTH", "player")

        assert.are.same({ "CUSTOM_EVENT:7", "UNIT_HEALTH:player" }, received)
    end)

    it("drops an individually disconnected connection from the scope", function()
        local scope = EventKit:CreateScope()
        local first = scope:Connect("FIRST_EVENT", noop)
        local middle = scope:Connect("MIDDLE_EVENT", noop)
        local last = scope:Connect("LAST_EVENT", noop)

        assert.is_true(middle:Disconnect())
        assert.are.equal(2, scope:GetActiveCount())
        assert.is_true(first:Disconnect())
        assert.is_true(last:Disconnect())
        assert.are.equal(0, scope:GetActiveCount())

        -- No dead handle stays linked: the intrusive list is empty again.
        assert.is_false(rawget(scope, "_head"))
        assert.is_false(rawget(scope, "_tail"))
        assert.are.equal(0, scope:DisconnectAll())
    end)

    it("drops a one-shot connection from the scope when it fires", function()
        local scope = EventKit:CreateScope()
        local calls = 0
        local connection = scope:Once("CUSTOM_EVENT", function()
            calls = calls + 1
        end)
        local unitConnection = scope:OnceUnit("UNIT_HEALTH", noop, "player")

        TestEnv.Emit("CUSTOM_EVENT")
        TestEnv.Emit("CUSTOM_EVENT")
        TestEnv.Emit("UNIT_HEALTH", "player")

        assert.are.equal(1, calls)
        assert.is_false(connection:IsConnected())
        assert.is_false(unitConnection:IsConnected())
        assert.are.equal(0, scope:GetActiveCount())
    end)

    it("disconnects everything in creation order and stays reusable", function()
        local scope = EventKit:CreateScope()
        local outside = EventKit:Connect("SHARED_EVENT", noop)
        local first = scope:Connect("SHARED_EVENT", noop)
        local second = scope:Connect("OTHER_EVENT", noop)
        local third = scope:ConnectUnit("UNIT_HEALTH", noop, "player")

        assert.are.equal(3, scope:DisconnectAll())

        assert.is_false(first:IsConnected())
        assert.is_false(second:IsConnected())
        assert.is_false(third:IsConnected())
        assert.is_true(outside:IsConnected())
        assert.is_false(scope:IsClosed())
        assert.are.equal(0, scope:GetActiveCount())

        -- The unrelated connection keeps its host registration; the other
        -- event lost its last listener and was unregistered.
        local regularFrame = TestEnv.Frames()[1]
        assert.is_not_nil(regularFrame.registrations.SHARED_EVENT)
        assert.is_nil(regularFrame.registrations.OTHER_EVENT)
        assert.are.same({ "OTHER_EVENT" }, regularFrame.unregisterEventCalls)

        local replacement = scope:Connect("OTHER_EVENT", noop)
        assert.is_true(replacement:IsConnected())
        assert.are.equal(1, scope:GetActiveCount())
    end)

    it("keeps disconnecting past a host failure and re-raises the first error", function()
        local scope = EventKit:CreateScope()
        local first = scope:Connect("FIRST_EVENT", noop)
        local second = scope:Connect("SECOND_EVENT", noop)
        local third = scope:Connect("THIRD_EVENT", noop)

        local frame = TestEnv.Frames()[1]
        local unregister = frame.UnregisterEvent
        local failure = { reason = "host refused" }
        function frame:UnregisterEvent(eventName)
            if eventName == "SECOND_EVENT" then
                error(failure, 0)
            end
            return unregister(self, eventName)
        end

        local ok, raised = pcall(function()
            scope:DisconnectAll()
        end)

        assert.is_false(ok)
        assert.are.equal(failure, raised)
        assert.is_false(first:IsConnected())
        assert.is_false(second:IsConnected())
        assert.is_false(third:IsConnected())
        assert.are.equal(0, scope:GetActiveCount())
    end)

    it("closes terminally and refuses new connections at the caller's line", function()
        local scope = EventKit:CreateScope()
        local connection = scope:Connect("PLAYER_LOGIN", noop)

        assert.is_true(scope:Close())
        assert.is_true(scope:IsClosed())
        assert.is_false(connection:IsConnected())
        assert.are.equal(0, scope:GetActiveCount())
        assert.is_false(scope:Close())

        expectErrorAtThisSpec("EventKit.Scope:Connect cannot connect in a closed scope", function()
            scope:Connect("PLAYER_LOGIN", noop)
        end)
        expectErrorAtThisSpec("EventKit.Scope:Once cannot connect in a closed scope", function()
            scope:Once("PLAYER_LOGIN", noop)
        end)
        expectErrorAtThisSpec(
            "EventKit.Scope:ConnectUnit cannot connect in a closed scope",
            function()
                scope:ConnectUnit("UNIT_HEALTH", noop, "player")
            end
        )
        expectErrorAtThisSpec("EventKit.Scope:OnceUnit cannot connect in a closed scope", function()
            scope:OnceUnit("UNIT_HEALTH", noop, "player")
        end)
    end)

    it("reports scope argument errors at the caller's line with the scope's name", function()
        local scope = EventKit:CreateScope()

        expectErrorAtThisSpec(
            "EventKit.Scope:Connect eventName must be a non-empty string",
            function()
                scope:Connect("", noop)
            end
        )
        expectErrorAtThisSpec("EventKit.Scope:Once callback must be a function", function()
            scope:Once("PLAYER_LOGIN", "nope")
        end)
        expectErrorAtThisSpec(
            "EventKit.Scope:ConnectUnit requires at least one unit token",
            function()
                scope:ConnectUnit("UNIT_HEALTH", noop)
            end
        )
        expectErrorAtThisSpec(
            "EventKit.Scope:OnceUnit accepts at most 2 distinct unit tokens",
            function()
                scope:OnceUnit("UNIT_HEALTH", noop, "player", "target", "focus")
            end
        )
        expectErrorAtThisSpec("EventKit.Scope:Connect could not register event", function()
            TestEnv.FailNextRegisterEvent()
            scope:Connect("PLAYER_LOGIN", noop)
        end)
        assert.are.equal(0, scope:GetActiveCount())
    end)

    it("names the misuse when a scope method is called without a scope", function()
        local calls = {
            { "EventKit.Scope:Connect", EventKit.Scope.Connect },
            { "EventKit.Scope:Once", EventKit.Scope.Once },
            { "EventKit.Scope:ConnectUnit", EventKit.Scope.ConnectUnit },
            { "EventKit.Scope:OnceUnit", EventKit.Scope.OnceUnit },
            { "EventKit.Scope:DisconnectAll", EventKit.Scope.DisconnectAll },
            { "EventKit.Scope:Close", EventKit.Scope.Close },
            { "EventKit.Scope:IsClosed", EventKit.Scope.IsClosed },
            { "EventKit.Scope:GetAddonName", EventKit.Scope.GetAddonName },
            { "EventKit.Scope:GetActiveCount", EventKit.Scope.GetActiveCount },
        }

        for index = 1, #calls do
            local label, method = calls[index][1], calls[index][2]
            expectErrorAtThisSpec(label .. " must be called on an EventKit scope", function()
                method({}, "PLAYER_LOGIN", noop)
            end)
        end
    end)

    it("allocates nothing per event for scoped listeners", function()
        local scope = EventKit:CreateScope()
        local sink = 0
        for _ = 1, 8 do
            scope:Connect("CUSTOM_EVENT", function(_, first, second)
                sink = sink + first + second
            end)
        end

        local allocated = allocatedKilobytes(function()
            for _ = 1, 20000 do
                TestEnv.Emit("CUSTOM_EVENT", 1, 2)
            end
        end)

        assert.are.equal(8 * 3 * 20000, sink)
        assert.is_true(allocated < 4, "dispatch allocated " .. allocated .. " KiB")
    end)
end)

describe("EventKit addon scopes", function()
    local EventKit
    before_each(function()
        EventKit = TestEnv.NewPackage()
    end)
    after_each(TestEnv.Reset)

    it("returns one canonical scope per addon name", function()
        local scope = EventKit:ForAddon("MyAddon")

        assert.are.equal(scope, EventKit:ForAddon("MyAddon"))
        assert.are_not.equal(scope, EventKit:ForAddon("OtherAddon"))
        assert.are.equal("MyAddon", scope:GetAddonName())
    end)

    it("rejects an invalid addon name at the caller's line", function()
        expectErrorAtThisSpec("EventKit:ForAddon addonName must be a non-empty string", function()
            EventKit:ForAddon("")
        end)
        expectErrorAtThisSpec(
            "EventKit:CloseAddonScopes addonName must be a non-empty string",
            function()
                EventKit:CloseAddonScopes(42)
            end
        )
    end)

    it("closes an addon's scope through CloseAddonScopes and keeps it canonical", function()
        local scope = EventKit:ForAddon("MyAddon")
        local connection = scope:Connect("PLAYER_LOGIN", noop)
        local other = EventKit:ForAddon("OtherAddon"):Connect("PLAYER_LOGIN", noop)

        assert.is_true(EventKit:CloseAddonScopes("MyAddon"))

        assert.is_true(scope:IsClosed())
        assert.is_false(connection:IsConnected())
        assert.is_true(other:IsConnected())
        assert.are.equal(scope, EventKit:ForAddon("MyAddon"))
        assert.is_false(EventKit:CloseAddonScopes("MyAddon"))
        expectErrorAtThisSpec("cannot connect in a closed scope", function()
            EventKit:ForAddon("MyAddon"):Connect("PLAYER_LOGIN", noop)
        end)
    end)

    it("records an addon that never asked for a scope as closed", function()
        assert.is_true(EventKit:CloseAddonScopes("LateAddon"))

        local scope = EventKit:ForAddon("LateAddon")
        assert.is_true(scope:IsClosed())
        assert.are.equal("LateAddon", scope:GetAddonName())
    end)

    it("supports the documented two-step shutdown wiring without LifecycleKit", function()
        -- EventKit cannot depend on LifecycleKit, so whoever observes the
        -- addon's shutdown closes its scope. Here the consumer wires it to
        -- PLAYER_LOGOUT itself; LifecycleKit makes the same call on shutdown.
        local scope = EventKit:ForAddon("MyAddon")
        local combatEvents = 0
        scope:Connect("PLAYER_REGEN_DISABLED", function()
            combatEvents = combatEvents + 1
        end)
        EventKit:Once("PLAYER_LOGOUT", function()
            EventKit:CloseAddonScopes("MyAddon")
        end)

        TestEnv.Emit("PLAYER_REGEN_DISABLED")
        TestEnv.Emit("PLAYER_LOGOUT")
        TestEnv.Emit("PLAYER_REGEN_DISABLED")

        assert.are.equal(1, combatEvents)
        assert.is_true(scope:IsClosed())
        assert.is_nil(TestEnv.Frames()[1].registrations.PLAYER_REGEN_DISABLED)
    end)

    it("keeps addon scopes and the scope prototype across duplicate embedding", function()
        local scope = EventKit:ForAddon("MyAddon")
        local prototype = EventKit.Scope
        local reloaded = TestEnv.ReloadPackage()

        assert.are.equal(prototype, reloaded.Scope)
        assert.are.equal(scope, reloaded:ForAddon("MyAddon"))
        scope:Connect("PLAYER_LOGIN", noop)
        assert.are.equal(1, scope:GetActiveCount())
    end)
end)
