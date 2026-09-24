-- Every argument and state refusal raises at the line that called the public
-- method, whichever helper found the problem and however many frames lie
-- between them, and names the public method it belongs to.

local TestEnv = require("ModuleKitTestEnv")

local expectCallerError = TestEnv.expectCallerError

describe("ModuleKit error levels", function()
    local ModuleKit, addon

    before_each(function()
        ModuleKit = TestEnv.NewPackage()
        addon = ModuleKit:ForAddon("MyAddon")
    end)

    after_each(TestEnv.Reset)

    it("points the container's argument errors at the caller", function()
        expectCallerError("ModuleKit.Addon:CreateModule name must be a non-empty string", function()
            addon:CreateModule("")
        end)
        addon:CreateModule("UI")
        expectCallerError('ModuleKit.Addon:CreateModule name "UI" is already in use', function()
            addon:CreateModule("UI")
        end)
        expectCallerError("ModuleKit.Addon:GetModule name must be a non-empty string", function()
            addon:GetModule(1)
        end)
        expectCallerError("ModuleKit.Addon:HasModule name must be a non-empty string", function()
            addon:HasModule("")
        end)
        expectCallerError(
            'ModuleKit.Addon:SetDependencyPolicy policy must be "automatic" or "strict"',
            function()
                addon:SetDependencyPolicy("lazy")
            end
        )
    end)

    it("points provider registration and resolution errors at the caller", function()
        expectCallerError("ModuleKit.Addon:ProvideValue value must not be nil", function()
            addon:ProvideValue("Config", nil)
        end)
        expectCallerError(
            "ModuleKit.Addon:ProvideSingleton providerName must be a non-empty string",
            function()
                addon:ProvideSingleton("", function() end)
            end
        )
        expectCallerError("ModuleKit.Addon:ProvideTransient factory must be a function", function()
            addon:ProvideTransient("Request", "factory")
        end)
        expectCallerError(
            "ModuleKit.Addon:Resolve providerName must be a non-empty string",
            function()
                addon:Resolve("")
            end
        )
        expectCallerError(
            "ModuleKit.Addon:Resolve requestingModule must be a module owned by this addon",
            function()
                addon:Resolve("Config", {})
            end
        )
        local module = addon:CreateModule("UI")
        expectCallerError(
            "ModuleKit.Module:Resolve providerName must be a non-empty string",
            function()
                module:Resolve("")
            end
        )
    end)

    it("points the module's graph and injection errors at the caller", function()
        local module = addon:CreateModule("UI")
        expectCallerError(
            "ModuleKit.Module:DependsOn moduleName must be a non-empty string",
            function()
                module:DependsOn("")
            end
        )
        expectCallerError(
            "ModuleKit.Module:Inject map aliases must be non-empty strings",
            function()
                module:Inject({ [1] = "Database" })
            end
        )

        module:Initialize()
        expectCallerError(
            'ModuleKit.Module:After cannot change module "UI" after initialization',
            function()
                module:After("Database")
            end
        )
    end)

    it("points definition-table errors at the CreateModule line", function()
        expectCallerError(
            "ModuleKit.Addon:CreateModule definition must be a table when provided",
            function()
                addon:CreateModule("UI", "definition")
            end
        )
        expectCallerError(
            'ModuleKit module definition contains unknown field "dependOn"',
            function()
                addon:CreateModule("UI", { dependOn = { "Database" } })
            end
        )
        expectCallerError(
            "ModuleKit.Module:DependsOn moduleName must be a non-empty string",
            function()
                addon:CreateModule("UI", { dependsOn = { 1 } })
            end
        )
        expectCallerError('ModuleKit module "UI" cannot depend/order against itself', function()
            addon:CreateModule("UI", { after = { "UI" } })
        end)
        expectCallerError("ModuleKit.Module:Inject target must be a non-empty string", function()
            addon:CreateModule("UI", { inject = { database = 1 } })
        end)
        assert.is_false(addon:HasModule("UI"))
    end)

    it("points a definition's catch-up failure at the CreateModule line", function()
        TestEnv.LoadAddon("MyAddon")

        expectCallerError(
            'ModuleKit module "Late" requires missing dependency "Missing"',
            function()
                addon:CreateModule("Late", { dependsOn = { "Missing" } })
            end
        )
    end)

    it("points DisableAll's graph error at the caller", function()
        addon:CreateModule("UI"):DependsOn("Missing")

        expectCallerError('ModuleKit module "UI" requires missing dependency "Missing"', function()
            addon:DisableAll()
        end)
    end)

    it("names the module method refused after shutdown", function()
        local module = addon:CreateModule("UI")
        TestEnv.LoadAddon("MyAddon")
        TestEnv.Login()
        TestEnv.Logout()

        expectCallerError("ModuleKit.Module:Initialize cannot run after addon shutdown", function()
            module:Initialize()
        end)
        expectCallerError("ModuleKit.Module:Enable cannot run after addon shutdown", function()
            module:Enable()
        end)
        expectCallerError("ModuleKit.Addon:ProvideValue cannot run after addon shutdown", function()
            addon:ProvideValue("Config", {})
        end)
    end)

    it("points SetLimits refusals at the caller", function()
        expectCallerError("ModuleKit:SetLimits limits must be a table", function()
            ModuleKit:SetLimits(16)
        end)
        expectCallerError(
            "ModuleKit:SetLimits limits.maxModules is not a recognised limit",
            function()
                ModuleKit:SetLimits({ maxModules = 4 })
            end
        )
        expectCallerError(
            "ModuleKit:SetLimits limits.maxRequiredAddons must be a positive integer or ModuleKit.UNBOUNDED",
            function()
                ModuleKit:SetLimits({ maxRequiredAddons = 0 })
            end
        )
        assert.are.equal(16, ModuleKit:GetLimits().maxRequiredAddons)
    end)

    it("names the first unknown option in sorted order", function()
        expectCallerError(
            'ModuleKit.Addon:ProvideValue options contains unknown field "alpha"',
            function()
                addon:ProvideValue(
                    "Config",
                    {},
                    { zeta = true, alpha = true, implements = { "Save" } }
                )
            end
        )
    end)
end)
