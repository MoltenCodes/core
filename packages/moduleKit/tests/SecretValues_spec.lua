local TestEnv = require("ModuleKitTestEnv")

---Load the module chain on the `mainline` host, whose `issecretvalue` reports
---the values `NewSecretValue` returns.
---@return table ModuleKit
local function loadOnSecretHost()
    TestEnv.Reset()
    TestEnv.SetWowProfile("mainline")
    TestEnv.InstallWowApi()
    require("Registry")
    require("SignalKit")
    require("EventKit")
    require("LifecycleKit")
    require("HookKit")
    require("SchemaKit")
    require("CommandKit")
    return require("ModuleKit")
end

describe("ModuleKit and secret values", function()
    local ModuleKit
    local addon
    local secret
    before_each(function()
        ModuleKit = loadOnSecretHost()
        addon = ModuleKit:ForAddon("MyAddon")
        secret = TestEnv.NewSecretValue()
    end)
    after_each(TestEnv.Reset)

    it("refuses secret names at the caller's line before comparing them", function()
        TestEnv.expectCallerError(
            "ModuleKit:ForAddon addonName must not be a secret value",
            function()
                ModuleKit:ForAddon(secret)
            end
        )
        TestEnv.expectCallerError(
            "ModuleKit.Addon:CreateModule name must not be a secret value",
            function()
                addon:CreateModule(secret)
            end
        )
        local module = addon:CreateModule("UI")
        TestEnv.expectCallerError(
            "ModuleKit.Module:DependsOn moduleName must not be a secret value",
            function()
                module:DependsOn(secret)
            end
        )
        TestEnv.expectCallerError(
            "ModuleKit.Addon:Resolve providerName must not be a secret value",
            function()
                addon:Resolve(secret)
            end
        )
        TestEnv.expectCallerError(
            "ModuleKit.Module:Inject target must not be a secret value",
            function()
                module:Inject("db", secret)
            end
        )
    end)

    it("refuses secret entries of a definition list or an implements list", function()
        TestEnv.expectCallerError(
            "ModuleKit module definition requiresAddons entries must not be secret values",
            function()
                addon:CreateModule("Needs", { requiresAddons = { secret } })
            end
        )
        assert.is_nil(addon:GetModule("Needs"))
        TestEnv.expectCallerError(
            "ModuleKit.Addon:ProvideValue options.implements entries must not be secret values",
            function()
                addon:ProvideValue("Checked", {}, { implements = { secret } })
            end
        )
    end)

    it("refuses a secret limit before comparing it with UNBOUNDED", function()
        TestEnv.expectCallerError(
            "ModuleKit:SetLimits limits.maxRequiredAddons must not be a secret value",
            function()
                ModuleKit:SetLimits({ maxRequiredAddons = secret })
            end
        )
        assert.are.same({ maxRequiredAddons = 16 }, ModuleKit:GetLimits())
    end)

    it("accepts a secret provided value without comparing it", function()
        addon:ProvideValue("Token", secret)
        assert.are.equal(secret, addon:Resolve("Token"))
    end)

    it("still accepts ordinary arguments on a host with secret values", function()
        local module = addon:CreateModule("UI", { requiresAddons = { "OtherAddon" } })
        module:DependsOn("Core")
        ModuleKit:SetLimits({ maxRequiredAddons = 8 })
        assert.are.equal(module, addon:GetModule("UI"))
        assert.are.equal(8, ModuleKit:GetLimits().maxRequiredAddons)
    end)
end)
