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

    it("refuses a secret dependency policy before comparing it and keeps the policy", function()
        TestEnv.expectCallerError(
            "ModuleKit.Addon:SetDependencyPolicy policy must not be a secret value",
            function()
                addon:SetDependencyPolicy(secret)
            end
        )
        assert.are.equal("automatic", addon:GetDependencyPolicy())

        addon:SetDependencyPolicy("strict")
        TestEnv.expectCallerError(
            "ModuleKit.Addon:SetDependencyPolicy policy must not be a secret value",
            function()
                addon:SetDependencyPolicy(secret)
            end
        )
        assert.are.equal("strict", addon:GetDependencyPolicy())
    end)

    it("refuses a secret limit name before using it as a key", function()
        TestEnv.expectCallerError(
            "ModuleKit:SetLimits limit names must not be secret values",
            function()
                ModuleKit:SetLimits({ [secret] = 4 })
            end
        )
        -- The whole table is validated first, so the valid entry beside the
        -- secret name is not applied either.
        TestEnv.expectCallerError(
            "ModuleKit:SetLimits limit names must not be secret values",
            function()
                ModuleKit:SetLimits({ maxRequiredAddons = 4, [secret] = 4 })
            end
        )
        assert.are.same({ maxRequiredAddons = 16 }, ModuleKit:GetLimits())
    end)

    it("refuses secret keys of definition, options and injection tables", function()
        TestEnv.expectCallerError(
            "ModuleKit module definition field names must not be secret values",
            function()
                addon:CreateModule("Keyed", { [secret] = true })
            end
        )
        assert.is_false(addon:HasModule("Keyed"))
        TestEnv.expectCallerError(
            "ModuleKit module definition dependsOn must be a dense array",
            function()
                addon:CreateModule("Keyed", { dependsOn = { [secret] = "Core" } })
            end
        )
        assert.is_false(addon:HasModule("Keyed"))
        TestEnv.expectCallerError(
            "ModuleKit.Addon:ProvideValue options field names must not be secret values",
            function()
                addon:ProvideValue("Checked", {}, { [secret] = true })
            end
        )
        TestEnv.expectCallerError(
            "ModuleKit.Addon:ProvideValue options.implements must be a dense array",
            function()
                addon:ProvideValue("Checked", {}, { implements = { [secret] = "Save" } })
            end
        )
        assert.is_false(addon:HasModule("Checked"))
        addon:ProvideValue("Checked", true)

        local module = addon:CreateModule("UI")
        TestEnv.expectCallerError(
            "ModuleKit.Module:Inject map aliases must not be secret values",
            function()
                module:Inject({ [secret] = "Checked" })
            end
        )
        TestEnv.expectCallerError(
            "ModuleKit.Module:Inject map aliases must not be secret values",
            function()
                addon:CreateModule("Injected", { inject = { [secret] = "Checked" } })
            end
        )
        assert.is_false(addon:HasModule("Injected"))
    end)

    it("refuses a secret requesting module and a module whose name is secret", function()
        addon:ProvideModule("PerModule", function()
            return {}
        end)
        TestEnv.expectCallerError(
            "ModuleKit.Addon:Resolve requestingModule must not be a secret value",
            function()
                addon:Resolve("PerModule", secret)
            end
        )
        TestEnv.expectCallerError(
            "ModuleKit.Addon:Resolve requestingModule must be a module owned by this addon",
            function()
                addon:Resolve("PerModule", { _name = secret, _addon = addon })
            end
        )
        local module = addon:CreateModule("UI")
        assert.are.equal(addon:Resolve("PerModule", module), module:Resolve("PerModule"))
    end)

    it("treats a list whose metatable name is secret as a method list", function()
        local list = setmetatable({ "Save" }, { __metatable = secret })
        addon:ProvideValue("Store", { Save = function() end }, { implements = list })
        TestEnv.expectCallerError(
            'ModuleKit provider "Broken" must implement "Save": no such member',
            function()
                addon:ProvideValue("Broken", {}, { implements = list })
            end
        )
    end)

    it("reads a secret scope key as no field", function()
        local module = addon:CreateModule("UI")
        assert.is_nil(module.scope[secret])
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
