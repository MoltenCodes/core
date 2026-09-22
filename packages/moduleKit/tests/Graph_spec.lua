local TestEnv = require("ModuleKitTestEnv")

describe("ModuleKit dependency graph", function()
    local ModuleKit

    before_each(function()
        ModuleKit = TestEnv.NewPackage()
    end)

    after_each(TestEnv.Reset)

    it("orders hard dependencies before dependents", function()
        local addon = ModuleKit:ForAddon("MyAddon")
        local ui = addon:CreateModule("UI")
        local database = addon:CreateModule("Database")
        ui:DependsOn("Database")

        assert.are.same({ "Database", "UI" }, addon:GetActivationOrder())
    end)

    it("uses creation order for unrelated modules", function()
        local addon = ModuleKit:ForAddon("MyAddon")
        addon:CreateModule("SecondNameFirst")
        addon:CreateModule("Alpha")

        assert.are.same({ "SecondNameFirst", "Alpha" }, addon:GetActivationOrder())
    end)

    it("honors Before and After ordering constraints", function()
        local addon = ModuleKit:ForAddon("MyAddon")
        local ui = addon:CreateModule("UI")
        local database = addon:CreateModule("Database")
        local profiles = addon:CreateModule("Profiles")

        database:Before("UI")
        ui:After("Profiles")

        assert.are.same({ "Database", "Profiles", "UI" }, addon:GetActivationOrder())
    end)

    it("ignores missing optional dependencies", function()
        local addon = ModuleKit:ForAddon("MyAddon")
        local ui = addon:CreateModule("UI")
        ui:OptionalDependency("Analytics")

        assert.is_true(addon:ValidateGraph())
        assert.are.same({ "UI" }, addon:GetActivationOrder())
    end)

    it("orders an optional dependency when it exists", function()
        local addon = ModuleKit:ForAddon("MyAddon")
        local ui = addon:CreateModule("UI")
        ui:OptionalDependency("Analytics")
        addon:CreateModule("Analytics")

        assert.are.same({ "Analytics", "UI" }, addon:GetActivationOrder())
    end)

    it("rejects missing hard dependencies", function()
        local addon = ModuleKit:ForAddon("MyAddon")
        addon:CreateModule("UI"):DependsOn("Database")

        assert.has_error(function()
            addon:ValidateGraph()
        end)
    end)

    it("detects hard dependency cycles", function()
        local addon = ModuleKit:ForAddon("MyAddon")
        local a = addon:CreateModule("A")
        local b = addon:CreateModule("B")
        local c = addon:CreateModule("C")
        a:DependsOn("B")
        b:DependsOn("C")
        c:DependsOn("A")

        assert.has_error(function()
            addon:ValidateGraph()
        end)
    end)

    it("detects cycles introduced by ordering-only constraints", function()
        local addon = ModuleKit:ForAddon("MyAddon")
        local a = addon:CreateModule("A")
        local b = addon:CreateModule("B")
        a:Before("B")
        b:Before("A")

        assert.has_error(function()
            addon:ValidateGraph()
        end)
    end)

    it("disables all modules in reverse topological order", function()
        local addon = ModuleKit:ForAddon("MyAddon")
        local calls = {}
        local database = addon:CreateModule("Database")
        local ui = addon:CreateModule("UI")
        ui:DependsOn("Database")

        database.OnDisable = function()
            calls[#calls + 1] = "Database"
        end
        ui.OnDisable = function()
            calls[#calls + 1] = "UI"
        end

        addon:EnableAll()
        addon:DisableAll()

        assert.are.same({ "UI", "Database" }, calls)
    end)

    it(
        "rejects a late module that would retroactively precede an initialized optional dependent",
        function()
            local addon = ModuleKit:ForAddon("MyAddon")
            local ui = addon:CreateModule("UI")
            ui:OptionalDependency("Analytics")
            ui:Initialize()

            assert.has_error(function()
                addon:CreateModule("Analytics")
            end)
            assert.is_false(addon:HasModule("Analytics"))
        end
    )

    it("rejects a late module definition that must run before an initialized module", function()
        local addon = ModuleKit:ForAddon("MyAddon")
        local ui = addon:CreateModule("UI")
        ui:Initialize()

        assert.has_error(function()
            addon:CreateModule("Bootstrap", {
                before = { "UI" },
            })
        end)
        assert.is_false(addon:HasModule("Bootstrap"))
    end)

    it("allows a late module whose ordering only places it after initialized modules", function()
        local addon = ModuleKit:ForAddon("MyAddon")
        local core = addon:CreateModule("Core")
        core:Initialize()

        local late = addon:CreateModule("Late", {
            after = { "Core" },
        })

        assert.is_not_nil(late)
        assert.are.same({ "Core", "Late" }, addon:GetActivationOrder())
    end)

    it(
        "does not let an unrelated invalid module block targeted hard-dependency operations",
        function()
            local addon = ModuleKit:ForAddon("MyAddon")
            addon:CreateModule("Broken"):DependsOn("Missing")
            local healthy = addon:CreateModule("Healthy")

            healthy:Enable()

            assert.is_true(healthy:IsEnabled())
        end
    )

    it("rejects mutable late Before constraints against initialized modules", function()
        local addon = ModuleKit:ForAddon("MyAddon")
        local ui = addon:CreateModule("UI")
        ui:Initialize()
        local late = addon:CreateModule("Late")

        assert.has_error(function()
            late:Before("UI")
        end)
    end)
end)
