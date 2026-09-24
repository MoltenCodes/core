local TestEnv = require("EventKitTestEnv")
local Scheduled = TestEnv.Scheduled

local SPEC_FILE = "packages/eventKit/tests/SecretValues_spec.lua:"

---Assert that `callback` fails with `expected` at a line of this spec file,
---never inside EventKit.
---@param expected string
---@param callback fun()
local function expectRefusalAtCaller(expected, callback)
    local ok, message = pcall(callback)
    message = tostring(message)
    assert.is_false(ok)
    assert.is_not_nil(string.find(message, expected, 1, true), message)
    assert.is_not_nil(string.find(message, SPEC_FILE, 1, true), message)
end

---Install an `issecretvalue` probe that reports exactly `secret` as secret.
---The environment's `Reset` clears the global again.
---@param secret any
local function installSecretProbe(secret)
    -- The package reads this host global at call time, so the spec installs it in the global table.
    -- selene: allow(global_usage)
    rawset(_G, "issecretvalue", function(value)
        return rawequal(value, secret)
    end)
end

---Fire the most recently created native timer.
local function fireLatest()
    Scheduled.FireNative(#Scheduled.NativeTimers())
end

describe("EventKit secret values", function()
    local EventKit

    before_each(function()
        EventKit = Scheduled.NewEventKit()
    end)
    after_each(Scheduled.Reset)

    it("refuses secret event names, sub-events and unit tokens before comparing them", function()
        installSecretProbe("SECRET_EVENT")

        expectRefusalAtCaller("EventKit:Connect eventName must not be a secret value", function()
            EventKit:Connect("SECRET_EVENT", function() end)
        end)
        expectRefusalAtCaller(
            "EventKit:ConnectCombatLog subEvent must not be a secret value",
            function()
                EventKit:ConnectCombatLog("SECRET_EVENT", function() end)
            end
        )
        expectRefusalAtCaller(
            "EventKit:ConnectUnit unit token must not be a secret value",
            function()
                EventKit:ConnectUnit("UNIT_HEALTH", function() end, "SECRET_EVENT")
            end
        )
        expectRefusalAtCaller(
            "EventKit:Coalesce events entry must not be a secret value",
            function()
                EventKit:Coalesce({ "BAG_UPDATE", "SECRET_EVENT" }, 1, function() end)
            end
        )
        expectRefusalAtCaller("EventKit:ForAddon addonName must not be a secret value", function()
            EventKit:ForAddon("SECRET_EVENT")
        end)
    end)

    it("refuses secret option values before comparing them", function()
        local secret = {}
        installSecretProbe(secret)

        expectRefusalAtCaller(
            "EventKit:Coalesce intervalSeconds must not be a secret value",
            function()
                EventKit:Coalesce("BAG_UPDATE", secret, function() end)
            end
        )
        expectRefusalAtCaller("EventKit:Coalesce byEvent must not be a secret value", function()
            EventKit:Coalesce("BAG_UPDATE", 1, function() end, { byEvent = secret })
        end)
        expectRefusalAtCaller("EventKit:Derive delaySeconds must not be a secret value", function()
            EventKit:Derive("BAG_UPDATE", function() end, { delaySeconds = secret })
        end)
        expectRefusalAtCaller(
            "EventKit:SetLimits limits.maxUnitFrames must not be a secret value",
            function()
                EventKit:SetLimits({ maxUnitFrames = secret })
            end
        )
        assert.are.equal(64, EventKit:GetLimits().maxUnitFrames)
    end)

    it("refuses a secret receiver handed to a facade method with a dot call", function()
        installSecretProbe("MyAddon")

        expectRefusalAtCaller(
            "EventKit:CloseAddonScopes must be called on the EventKit facade",
            function()
                EventKit.CloseAddonScopes("MyAddon")
            end
        )
    end)

    it("coalesces a secret first payload argument under the event name", function()
        local secret = {}
        local delivered = nil
        EventKit:Coalesce("BAG_UPDATE", 1, function(set)
            delivered = {}
            for key in pairs(set) do
                delivered[#delivered + 1] = key
            end
        end)
        installSecretProbe(secret)

        Scheduled.Emit("BAG_UPDATE", secret)
        fireLatest()

        assert.are.same({ "BAG_UPDATE" }, delivered)
    end)

    it("announces a secret derived value as a change without comparing it", function()
        local secret = {}
        local derived = EventKit:Derive("CUSTOM_EVENT", function()
            return secret
        end)
        local changes = 0
        derived:OnChange(function()
            changes = changes + 1
        end)
        installSecretProbe(secret)

        Scheduled.Emit("CUSTOM_EVENT")
        fireLatest()

        assert.are.equal(1, changes)
        assert.are.equal(secret, derived:Get())
    end)

    it("counts a secret equals answer as a change without testing it", function()
        local secret = {}
        local current = 1
        local derived = EventKit:Derive("CUSTOM_EVENT", function()
            return current
        end, {
            -- A plain table would read as "equal"; the probe makes it secret.
            equals = function()
                return secret
            end,
        })
        local seen = {}
        derived:OnChange(function(value, previous)
            seen[#seen + 1] = { value, previous }
        end)
        installSecretProbe(secret)

        current = 2
        Scheduled.Emit("CUSTOM_EVENT")
        fireLatest()

        assert.are.same({ { 2, 1 } }, seen)
        assert.are.equal(2, derived:Get())
    end)
end)

describe("EventKit secret combat-log sub-events", function()
    local EventKit
    before_each(function()
        EventKit = TestEnv.NewPackage()
    end)
    after_each(TestEnv.Reset)

    it("routes a secret sub-event to the wildcard listeners only, unchanged", function()
        local routed = 0
        EventKit:ConnectCombatLog("SPELL_DAMAGE", function()
            routed = routed + 1
        end)
        local wildcard = {}
        EventKit:ConnectCombatLog("*", function(...)
            wildcard[#wildcard + 1] = { ... }
        end)
        -- The stand-in is a string the route table holds, so only the probe
        -- keeps it from being looked up.
        installSecretProbe("SPELL_DAMAGE")

        TestEnv.EmitCombatLogEvent(1.5, "SPELL_DAMAGE", false, "Player-1")

        assert.are.equal(0, routed)
        assert.are.same({ { 1.5, "SPELL_DAMAGE", false, "Player-1" } }, wildcard)
        assert.are.equal(1, TestEnv.CombatLogEventInfoReads())
    end)
end)
