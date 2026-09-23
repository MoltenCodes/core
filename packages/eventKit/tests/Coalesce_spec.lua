local TestEnv = require("EventKitTestEnv")
local Scheduled = TestEnv.Scheduled

---Fire the most recently created native timer.
---@return boolean fired
local function fireLatest()
    return Scheduled.FireNative(#Scheduled.NativeTimers())
end

---Copy a delivered set, which SchedulerKit wipes as soon as the callback returns.
local function copy(set)
    local result = {}
    for key, value in pairs(set) do
        result[key] = value
    end
    return result
end

---Assert that `callback` fails with `expected` at a line of this spec file.
local function expectErrorAtThisSpec(expected, callback)
    local ok, message = pcall(callback)
    message = tostring(message)
    assert.is_false(ok)
    assert.is_not_nil(string.find(message, expected, 1, true), message)
    assert.is_not_nil(
        string.find(message, "packages/eventKit/tests/Coalesce_spec.lua:", 1, true),
        message
    )
end

---Measure the allocation a workload causes, in kilobytes, with the collector
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

describe("EventKit Coalesce", function()
    local EventKit
    before_each(function()
        EventKit = Scheduled.NewEventKit()
    end)
    after_each(Scheduled.Reset)

    it("collects payloads keyed by the first argument and delivers once per interval", function()
        local deliveries = {}
        local handle = EventKit:Coalesce({ "UNIT_HEALTH", "UNIT_POWER_UPDATE" }, 0.5, function(set)
            deliveries[#deliveries + 1] = copy(set)
        end)

        Scheduled.Emit("UNIT_HEALTH", "player")
        Scheduled.Emit("UNIT_POWER_UPDATE", "target")
        Scheduled.Emit("UNIT_HEALTH", "player")
        assert.is_true(handle:IsPending())
        -- The first event started the interval; the rest joined it.
        assert.are.equal(1, #Scheduled.NativeTimers())
        assert.are.equal(0.5, Scheduled.NativeTimers()[1].seconds)
        assert.are.same({}, deliveries)

        fireLatest()
        assert.are.same({ { player = true, target = true } }, deliveries)
        assert.is_false(handle:IsPending())
        assert.are.equal(1, handle:GetStats().delivered)
    end)

    it("keys by event name with byEvent, and when the first argument is nil", function()
        local byEvent, byPayload = nil, nil
        EventKit:Coalesce({ "BAG_UPDATE", "BAG_UPDATE_DELAYED" }, 1, function(set)
            byEvent = copy(set)
        end, { byEvent = true })
        EventKit:Coalesce("BAG_UPDATE_DELAYED", 1, function(set)
            byPayload = copy(set)
        end)

        Scheduled.Emit("BAG_UPDATE", 3)
        Scheduled.Emit("BAG_UPDATE_DELAYED")
        Scheduled.FireNative(1)
        Scheduled.FireNative(2)

        assert.are.same({ BAG_UPDATE = true, BAG_UPDATE_DELAYED = true }, byEvent)
        assert.are.same({ BAG_UPDATE_DELAYED = true }, byPayload)
    end)

    it("subscribes unit events through ConnectUnit semantics", function()
        local delivered = nil
        EventKit:Coalesce("UNIT_HEALTH", 1, function(set)
            delivered = copy(set)
        end, { units = { "target", "player" } })

        local frame = Scheduled.Frames()[1]
        assert.are.equal(1, #frame.registerUnitEventCalls)
        assert.are.same({ "player", "target" }, frame.registerUnitEventCalls[1].units)

        Scheduled.Emit("UNIT_HEALTH", "player")
        Scheduled.Emit("UNIT_HEALTH", "focus")
        fireLatest()
        assert.are.same({ player = true }, delivered)
    end)

    it("flushes early and reports refusals past maxKeys", function()
        local delivered = nil
        local handle = EventKit:Coalesce("UNIT_AURA", 5, function(set)
            delivered = copy(set)
        end, { maxKeys = 1 })

        assert.is_false(handle:Flush())
        Scheduled.Emit("UNIT_AURA", "player")
        Scheduled.Emit("UNIT_AURA", "target")
        assert.are.equal(1, handle:GetStats().refused)
        assert.is_true(handle:Flush())
        assert.are.same({ player = true }, delivered)
    end)

    it("is released by its scope: events, pending delivery and membership", function()
        local scope = EventKit:CreateScope()
        local deliveries = 0
        local handle = scope:Coalesce("UNIT_HEALTH", 1, function()
            deliveries = deliveries + 1
        end)
        assert.are.equal(1, scope:GetActiveCount())

        Scheduled.Emit("UNIT_HEALTH", "player")
        scope:Close()

        assert.is_true(handle:IsClosed())
        assert.is_false(handle:IsPending())
        assert.are.equal(0, scope:GetActiveCount())
        assert.is_nil(Scheduled.Frames()[1].registrations.UNIT_HEALTH)
        assert.is_false(fireLatest())
        Scheduled.Emit("UNIT_HEALTH", "player")
        assert.are.equal(0, deliveries)
        assert.is_false(handle:Close())
        expectErrorAtThisSpec("cannot connect in a closed scope", function()
            scope:Coalesce("UNIT_HEALTH", 1, function() end)
        end)
    end)

    it("defers a scope close inside a dispatch like any connection", function()
        local scope = EventKit:CreateScope()
        EventKit:Connect("PLAYER_LOGOUT", function()
            scope:Close()
        end)
        local delivered = nil
        local handle = scope:Coalesce("PLAYER_LOGOUT", 0, function(set)
            delivered = copy(set)
        end)

        Scheduled.Emit("PLAYER_LOGOUT")
        -- The event in flight still reached the handle, which armed its
        -- interval; the sweep after the dispatch then released both.
        assert.are.equal(1, #Scheduled.NativeTimers())
        assert.is_true(Scheduled.NativeTimers()[1].cancelled)
        assert.is_true(handle:IsClosed())
        assert.is_nil(delivered)
    end)

    it("closes on its own and leaves its scope", function()
        local scope = EventKit:CreateScope()
        local handle = scope:Coalesce("UNIT_HEALTH", 1, function() end)
        assert.is_true(handle:Close())
        assert.are.equal(0, scope:GetActiveCount())
        assert.are.equal(0, handle:GetStats().keys)
    end)

    it("refuses bad arguments at the caller's line", function()
        expectErrorAtThisSpec(
            "EventKit:Coalesce events must be an event name or a non-empty array",
            function()
                EventKit:Coalesce({}, 1, function() end)
            end
        )
        expectErrorAtThisSpec("EventKit:Coalesce eventName must be a non-empty string", function()
            EventKit:Coalesce("", 1, function() end)
        end)
        expectErrorAtThisSpec(
            "EventKit:Coalesce intervalSeconds must be a finite number",
            function()
                EventKit:Coalesce("UNIT_HEALTH", -1, function() end)
            end
        )
        expectErrorAtThisSpec("EventKit:Coalesce callback must be a function", function()
            EventKit:Coalesce("UNIT_HEALTH", 1, nil)
        end)
        expectErrorAtThisSpec('EventKit:Coalesce options contains unknown field "unit"', function()
            EventKit:Coalesce("UNIT_HEALTH", 1, function() end, { unit = "player" })
        end)
        expectErrorAtThisSpec("EventKit:Coalesce accepts at most 2 distinct unit tokens", function()
            EventKit:Coalesce("UNIT_HEALTH", 1, function() end, { units = { "a", "b", "c" } })
        end)
        expectErrorAtThisSpec("EventKit:Coalesce: SchedulerKit.Scope:Coalesce maxKeys", function()
            EventKit:Coalesce("UNIT_HEALTH", 1, function() end, { maxKeys = 0 })
        end)
        expectErrorAtThisSpec(
            "EventKit.Scope:Coalesce must be called on an EventKit scope",
            function()
                EventKit.Scope.Coalesce({}, "UNIT_HEALTH", 1, function() end)
            end
        )
        -- A refused call registers nothing.
        assert.are.equal(0, #Scheduled.Frames())
    end)

    it("allocates nothing per event in steady state", function()
        local handle = EventKit:Coalesce("UNIT_HEALTH", 1, function() end)
        Scheduled.Emit("UNIT_HEALTH", "player")
        Scheduled.Emit("UNIT_HEALTH", "target")

        local allocated = allocatedKilobytes(function()
            for _ = 1, 10000 do
                Scheduled.Emit("UNIT_HEALTH", "player")
                Scheduled.Emit("UNIT_HEALTH", "target")
            end
        end)
        assert.is_true(allocated < 4, "coalesced dispatch allocated " .. allocated .. " KiB")
        assert.are.equal(2, handle:GetStats().keys)
    end)
end)

describe("EventKit Coalesce without SchedulerKit", function()
    local EventKit
    before_each(function()
        EventKit = TestEnv.NewPackage()
    end)
    after_each(TestEnv.Reset)

    it("refuses at the caller's line and registers nothing", function()
        expectErrorAtThisSpec(
            "EventKit:Coalesce requires SchedulerKit API 1, which is not available (absent)",
            function()
                EventKit:Coalesce("UNIT_HEALTH", 1, function() end)
            end
        )
        local scope = EventKit:CreateScope()
        expectErrorAtThisSpec("EventKit.Scope:Coalesce requires SchedulerKit API 1", function()
            scope:Coalesce("UNIT_HEALTH", 1, function() end)
        end)
        assert.are.equal(0, #TestEnv.Frames())
        assert.are.equal(0, scope:GetActiveCount())
    end)
end)
