local TestEnv = require("SignalKitTestEnv")

local SPEC_FILE = "packages/signalKit/tests/SecretValues_spec.lua:"

---Assert that `callback` raises a message naming `expected` at this spec file's
---line rather than somewhere inside the package.
---@param expected string
---@param callback fun()
local function expectRefusalAtCaller(expected, callback)
    TestEnv.ExpectRefusalAtCaller(SPEC_FILE, expected, callback)
end

---Install an `issecretvalue` probe that reports exactly `secret` as secret.
---`TestEnv.Reset` clears the global again.
---@param secret any
local function installSecretProbe(secret)
    -- The package reads this host global at call time, so the spec installs it in the global table.
    -- selene: allow(global_usage)
    rawset(_G, "issecretvalue", function(value)
        return rawequal(value, secret)
    end)
end

describe("SignalKit secret values", function()
    local SignalKit

    before_each(function()
        SignalKit = TestEnv.NewPackage()
    end)

    after_each(TestEnv.Reset)

    it("refuses a secret journal capacity before comparing it", function()
        local secret = {}
        installSecretProbe(secret)

        expectRefusalAtCaller("SignalKit:NewJournal capacity must not be a secret value", function()
            SignalKit:NewJournal(secret)
        end)
    end)

    it("refuses secret bus options before comparing them", function()
        local secret = {}
        installSecretProbe(secret)

        expectRefusalAtCaller(
            "SignalKit:Bus options.maxTopics must not be a secret value",
            function()
                SignalKit:Bus("Guarded", { maxTopics = secret })
            end
        )
        expectRefusalAtCaller(
            "SignalKit:Bus options.maxListeners must not be a secret value",
            function()
                SignalKit:Bus("Guarded", { maxListeners = secret })
            end
        )
        expectRefusalAtCaller(
            "SignalKit:Bus options.openTopics must not be a secret value",
            function()
                SignalKit:Bus("Guarded", { openTopics = secret })
            end
        )
    end)

    it("refuses a secret limit before comparing it", function()
        local secret = {}
        installSecretProbe(secret)

        expectRefusalAtCaller(
            "SignalKit:SetLimits limits.maxBuses must not be a secret value",
            function()
                SignalKit:SetLimits({ maxBuses = secret })
            end
        )
        assert.are.equal(64, SignalKit:GetLimits().maxBuses)
    end)

    it("refuses a secret argument count before comparing it", function()
        local bus = SignalKit:Bus("Counted")
        installSecretProbe(2)

        expectRefusalAtCaller(
            "SignalKit.Bus:DeclareTopic options.arguments must not be a secret value",
            function()
                bus:DeclareTopic("Pair", { arguments = 2 })
            end
        )
    end)

    it("refuses a publish whose validator verdict is secret", function()
        local bus = SignalKit:Bus("Validated")
        local delivered = false
        bus:DeclareTopic("Checked", {
            arguments = function()
                return true
            end,
        })
        bus:Subscribe("Checked", function()
            delivered = true
        end)
        installSecretProbe(true)

        expectRefusalAtCaller(
            'SignalKit.Bus:Publish topic "Checked" on bus "Validated" refused its arguments',
            function()
                bus:Publish("Checked")
            end
        )
        assert.is_false(delivered)
    end)

    it("refuses a secret receiver handed to a facade method with a dot call", function()
        installSecretProbe("Guarded")

        expectRefusalAtCaller("SignalKit:Bus must be called on the SignalKit facade", function()
            SignalKit.Bus("Guarded")
        end)
    end)
end)
