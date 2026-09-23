local TestEnv = require("EventKitTestEnv")
local Scheduled = TestEnv.Scheduled

---Fire the most recently created native timer.
---@return boolean fired
local function fireLatest()
    return Scheduled.FireNative(#Scheduled.NativeTimers())
end

---Assert that `callback` fails with `expected` at a line of this spec file.
local function expectErrorAtThisSpec(expected, callback)
    local ok, message = pcall(callback)
    message = tostring(message)
    assert.is_false(ok)
    assert.is_not_nil(string.find(message, expected, 1, true), message)
    assert.is_not_nil(
        string.find(message, "packages/eventKit/tests/Derive_spec.lua:", 1, true),
        message
    )
end

describe("EventKit Derive", function()
    local EventKit
    before_each(function()
        EventKit = Scheduled.NewEventKit()
    end)
    after_each(Scheduled.Reset)

    it("computes at creation and recomputes, debounced, when an event fires", function()
        local source, computes = 1, 0
        local derived = EventKit:Derive({ "BAG_UPDATE", "PLAYER_MONEY" }, function()
            computes = computes + 1
            return source * 10
        end)
        assert.are.equal(10, derived:Get())
        assert.are.equal(1, computes)

        source = 2
        Scheduled.Emit("BAG_UPDATE", 1)
        Scheduled.Emit("PLAYER_MONEY")
        Scheduled.Emit("BAG_UPDATE", 2)
        -- Still the cached value: the recompute waits for the next frame.
        assert.are.equal(10, derived:Get())
        assert.are.equal(1, #Scheduled.NativeTimers())
        assert.are.equal(0, Scheduled.NativeTimers()[1].seconds)

        fireLatest()
        assert.are.equal(20, derived:Get())
        assert.are.equal(2, computes)
    end)

    it("waits delaySeconds of quiet before recomputing", function()
        local computes = 0
        local derived = EventKit:Derive("BAG_UPDATE", function()
            computes = computes + 1
            return computes
        end, { delaySeconds = 0.25 })

        Scheduled.Emit("BAG_UPDATE", 1)
        assert.are.equal(0.25, Scheduled.NativeTimers()[1].seconds)
        Scheduled.AdvanceMs(100)
        Scheduled.Emit("BAG_UPDATE", 1)
        Scheduled.AdvanceMs(150)
        fireLatest()
        assert.are.equal(1, derived:Get())
        Scheduled.AdvanceMs(100)
        fireLatest()
        assert.are.equal(2, derived:Get())
    end)

    it("announces a change with the new and previous value, and only a change", function()
        local source = "a"
        local derived = EventKit:Derive("CUSTOM_EVENT", function()
            return source
        end)
        local changes = {}
        derived:OnChange(function(value, previous)
            changes[#changes + 1] = previous .. ">" .. value
        end)

        Scheduled.Emit("CUSTOM_EVENT")
        fireLatest()
        assert.are.same({}, changes)

        source = "b"
        Scheduled.Emit("CUSTOM_EVENT")
        fireLatest()
        assert.are.same({ "a>b" }, changes)
    end)

    it("uses options.equals to decide what a change is", function()
        local source = { id = 1, label = "one" }
        local derived = EventKit:Derive("CUSTOM_EVENT", function()
            return source
        end, {
            equals = function(previous, current)
                return previous.id == current.id
            end,
        })
        local changes = 0
        derived:OnChange(function()
            changes = changes + 1
        end)

        source = { id = 1, label = "uno" }
        Scheduled.Emit("CUSTOM_EVENT")
        fireLatest()
        assert.are.equal(0, changes)
        assert.are.equal("one", derived:Get().label)

        source = { id = 2, label = "two" }
        Scheduled.Emit("CUSTOM_EVENT")
        fireLatest()
        assert.are.equal(1, changes)
        assert.are.equal("two", derived:Get().label)
    end)

    it("recomputes on Invalidate like an event", function()
        local source = 1
        local derived = EventKit:Derive("CUSTOM_EVENT", function()
            return source
        end)
        source = 5
        derived:Invalidate()
        assert.are.equal(1, derived:Get())
        fireLatest()
        assert.are.equal(5, derived:Get())
    end)

    it("reports a raising compute and keeps the previous value", function()
        local fail = false
        local derived = EventKit:Derive("CUSTOM_EVENT", function()
            if fail then
                error("compute failure")
            end
            return "kept"
        end)
        fail = true
        Scheduled.Emit("CUSTOM_EVENT")
        fireLatest()
        assert.are.equal("kept", derived:Get())
        local reported = Scheduled.TakeReportedErrors()
        assert.are.equal(1, #reported)
        assert.is_not_nil(string.find(tostring(reported[1].value), "compute failure", 1, true))
    end)

    it("isolates a raising change listener from the others", function()
        local source = 1
        local derived = EventKit:Derive("CUSTOM_EVENT", function()
            return source
        end)
        local reached = false
        derived:OnChange(function()
            error("listener failure")
        end)
        derived:OnChange(function()
            reached = true
        end)
        source = 2
        Scheduled.Emit("CUSTOM_EVENT")
        fireLatest()
        assert.is_true(reached)
        assert.are.equal(1, #Scheduled.TakeReportedErrors())
    end)

    it("closes: no more recomputes, pending one dropped, scope released", function()
        local scope = EventKit:CreateScope()
        local computes = 0
        local derived = scope:Derive("CUSTOM_EVENT", function()
            computes = computes + 1
            return computes
        end)
        Scheduled.Emit("CUSTOM_EVENT")
        scope:Close()

        assert.is_true(derived:IsClosed())
        assert.are.equal(0, scope:GetActiveCount())
        assert.is_false(fireLatest())
        Scheduled.Emit("CUSTOM_EVENT")
        derived:Invalidate()
        assert.are.equal(1, computes)
        assert.are.equal(1, derived:Get())
        assert.is_false(derived:Close())
        expectErrorAtThisSpec("cannot subscribe to a closed derived value", function()
            derived:OnChange(function() end)
        end)
    end)

    it("disconnects its change listeners when it closes", function()
        local derived = EventKit:Derive("CUSTOM_EVENT", function()
            return 1
        end)
        local first = derived:OnChange(function() end)
        local second = derived:OnChange(function() end)

        assert.is_true(derived:Close())
        assert.is_false(first:IsConnected())
        assert.is_false(second:IsConnected())
    end)

    it("refuses a scope that its own compute closed, and leaves nothing behind", function()
        local scope = EventKit:CreateScope()
        expectErrorAtThisSpec("EventKit.Scope:Derive cannot connect in a closed scope", function()
            scope:Derive("CUSTOM_EVENT", function()
                scope:Close()
                return 1
            end)
        end)
        assert.are.equal(0, scope:GetActiveCount())
        assert.are.equal(0, #Scheduled.NativeTimers())
        local computes = 0
        EventKit:Connect("CUSTOM_EVENT", function()
            computes = computes + 1
        end)
        Scheduled.Emit("CUSTOM_EVENT")
        assert.are.equal(1, computes)
        -- The closed handle heard nothing, so no recompute was armed.
        assert.are.equal(0, #Scheduled.NativeTimers())
    end)

    it("refuses bad arguments at the caller's line", function()
        expectErrorAtThisSpec("EventKit:Derive compute must be a function", function()
            EventKit:Derive("CUSTOM_EVENT", 42)
        end)
        expectErrorAtThisSpec("EventKit:Derive delaySeconds must be a finite number", function()
            EventKit:Derive("CUSTOM_EVENT", function() end, { delaySeconds = -1 })
        end)
        expectErrorAtThisSpec("EventKit:Derive equals must be a function", function()
            EventKit:Derive("CUSTOM_EVENT", function() end, { equals = true })
        end)
        expectErrorAtThisSpec(
            "EventKit:Derive events must contain only non-empty strings",
            function()
                EventKit:Derive({ "CUSTOM_EVENT", 7 }, function() end)
            end
        )
        local derived = EventKit:Derive("CUSTOM_EVENT", function() end)
        expectErrorAtThisSpec(
            "EventKit.DeriveHandle:OnChange callback must be a function",
            function()
                derived:OnChange("nope")
            end
        )
        expectErrorAtThisSpec("must be called on an EventKit derived value", function()
            derived.Get({})
        end)
    end)
end)

describe("EventKit Derive without SchedulerKit", function()
    local EventKit
    before_each(function()
        EventKit = TestEnv.NewPackage()
    end)
    after_each(TestEnv.Reset)

    it("recomputes synchronously on every event", function()
        local source, computes = 1, 0
        local derived = EventKit:Derive("CUSTOM_EVENT", function()
            computes = computes + 1
            return source
        end)
        local changes = {}
        derived:OnChange(function(value)
            changes[#changes + 1] = value
        end)

        source = 2
        TestEnv.Emit("CUSTOM_EVENT")
        assert.are.equal(2, derived:Get())
        TestEnv.Emit("CUSTOM_EVENT")
        assert.are.equal(3, computes)
        assert.are.same({ 2 }, changes)

        source = 3
        derived:Invalidate()
        assert.are.equal(3, derived:Get())
        assert.are.equal(0, #TestEnv.NativeTimers())
    end)

    it("is released by its scope", function()
        local scope = EventKit:CreateScope()
        local computes = 0
        scope:Derive("CUSTOM_EVENT", function()
            computes = computes + 1
        end)
        scope:Close()
        TestEnv.Emit("CUSTOM_EVENT")
        assert.are.equal(1, computes)
    end)
end)
