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
end)
