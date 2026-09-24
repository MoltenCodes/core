local Env = require("LogKitTestEnv")

describe("LogKit and secret values", function()
    local LogKit, logger, delivered

    before_each(function()
        LogKit = Env.NewPackage()
        logger = LogKit:ForAddon("MyAddon")
        delivered = {}
        LogKit:AddSink(function(record)
            delivered[#delivered + 1] = record.message
        end)
    end)
    after_each(function()
        Env.Reset()
    end)

    it("replaces a secret format argument by the placeholder before formatting", function()
        local secret = Env.NewSecretValue()
        logger:Warn("target %s at %d", secret, 5)
        assert.are.equal("<secret>", LogKit.SECRET_PLACEHOLDER)
        assert.are.same({ "target <secret> at 5" }, delivered)
    end)

    it("never hands a secret to string.format or tostring", function()
        local touched = false
        local secret = setmetatable({}, {
            __tostring = function()
                touched = true
                return "leaked"
            end,
        })
        Env.InstallSecretProbe(secret)
        logger:Error("%s", secret)
        assert.is_false(touched)
        assert.are.same({ "<secret>" }, delivered)
    end)

    it("refuses a secret message at the caller", function()
        local secret = Env.NewSecretValue()
        Env.expectErrorContaining(
            "LogKit.Logger:Warn message must not be a secret value",
            function()
                logger:Warn(secret)
            end
        )
        assert.are.same({}, delivered)
    end)

    it("does not look at a secret message while the level is disabled", function()
        local secret = Env.NewSecretValue()
        assert.has_no.errors(function()
            logger:Debug(secret, secret)
        end)
    end)

    it("refuses a secret addon name, level, sink and chat frame at the caller", function()
        local secret = Env.NewSecretValue()
        Env.expectErrorContaining("LogKit:ForAddon addonName must not be a secret value", function()
            LogKit:ForAddon(secret)
        end)
        Env.expectErrorContaining(
            "LogKit.Logger:SetLevel level must not be a secret value",
            function()
                logger:SetLevel(secret)
            end
        )
        Env.expectErrorContaining(
            "LogKit:SetGlobalLevel level must not be a secret value",
            function()
                LogKit:SetGlobalLevel(secret)
            end
        )
        Env.expectErrorContaining("LogKit.Logger:Log level must not be a secret value", function()
            logger:Log(secret, "x")
        end)
        Env.expectErrorContaining("LogKit:AddSink sink must not be a secret value", function()
            LogKit:AddSink(secret)
        end)
        assert.is_false(LogKit:RemoveSink(secret))
        Env.expectErrorContaining("LogKit:ChatSink chatFrame must not be a secret value", function()
            LogKit:ChatSink(secret)
        end)
    end)

    it("refuses a secret limit key or value at the caller, changing nothing", function()
        local secret = Env.NewSecretValue()
        Env.expectErrorContaining("LogKit:SetLimits limits must not have a secret key", function()
            LogKit:SetLimits({ [secret] = 4 })
        end)
        for _, name in ipairs({ "journalCapacity", "maxSinks", "maxMessageLength", "maxLoggers" }) do
            Env.expectErrorContaining(
                "LogKit:SetLimits limits." .. name .. " must not be a secret value",
                function()
                    LogKit:SetLimits({ [name] = secret })
                end
            )
        end
        assert.are.equal(16, LogKit:GetLimits().maxSinks)
    end)

    it("looks the probe up at call time", function()
        Env.SetGlobal("issecretvalue", nil)
        local value = {}
        logger:Warn("%s", "plain")
        Env.InstallSecretProbe(value)
        logger:Warn("%s", value)
        assert.are.same({ "plain", "<secret>" }, delivered)
    end)
end)
