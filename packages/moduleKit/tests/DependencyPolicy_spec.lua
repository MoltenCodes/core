local TestEnv = require("ModuleKitTestEnv")

describe("ModuleKit dependency policy", function()
    local ModuleKit

    before_each(function()
        ModuleKit = TestEnv.NewPackage()
    end)

    after_each(TestEnv.Reset)

    it("automatically enables hard dependencies", function()
        local addon = ModuleKit:ForAddon("MyAddon")
        local database = addon:CreateModule("Database")
        local inventory = addon:CreateModule("Inventory")
        inventory:DependsOn("Database")

        inventory:Enable()

        assert.is_true(database:IsEnabled())
        assert.is_true(inventory:IsEnabled())
    end)

    it("automatically enables transitive hard dependencies", function()
        local addon = ModuleKit:ForAddon("MyAddon")
        local storage = addon:CreateModule("Storage")
        local database = addon:CreateModule("Database")
        local ui = addon:CreateModule("UI")
        database:DependsOn("Storage")
        ui:DependsOn("Database")

        ui:Enable()

        assert.is_true(storage:IsEnabled())
        assert.is_true(database:IsEnabled())
        assert.is_true(ui:IsEnabled())
    end)

    it("automatic disable cascades to enabled hard dependents", function()
        local addon = ModuleKit:ForAddon("MyAddon")
        local database = addon:CreateModule("Database")
        local inventory = addon:CreateModule("Inventory")
        local ui = addon:CreateModule("UI")
        inventory:DependsOn("Database")
        ui:DependsOn("Inventory")
        ui:Enable()

        database:Disable()

        assert.is_false(database:IsEnabled())
        assert.is_false(inventory:IsEnabled())
        assert.is_false(ui:IsEnabled())
    end)

    it("strict enable requires hard dependencies to already be enabled", function()
        local addon = ModuleKit:ForAddon("MyAddon")
        addon:SetDependencyPolicy("strict")
        addon:CreateModule("Database")
        local inventory = addon:CreateModule("Inventory")
        inventory:DependsOn("Database")

        assert.has_error(function()
            inventory:Enable()
        end)
        assert.are.equal("Database", inventory:GetBlockedBy())
    end)

    it("strict enable succeeds after the dependency is enabled", function()
        local addon = ModuleKit:ForAddon("MyAddon")
        addon:SetDependencyPolicy("strict")
        local database = addon:CreateModule("Database")
        local inventory = addon:CreateModule("Inventory")
        inventory:DependsOn("Database")

        database:Enable()
        inventory:Enable()

        assert.is_true(inventory:IsEnabled())
    end)

    it("strict disable rejects enabled hard dependents", function()
        local addon = ModuleKit:ForAddon("MyAddon")
        addon:SetDependencyPolicy("strict")
        local database = addon:CreateModule("Database")
        local inventory = addon:CreateModule("Inventory")
        inventory:DependsOn("Database")
        database:Enable()
        inventory:Enable()

        assert.has_error(function()
            database:Disable()
        end)
        assert.is_true(database:IsEnabled())
        assert.is_true(inventory:IsEnabled())
    end)

    it("bulk enable works topologically under strict policy", function()
        local addon = ModuleKit:ForAddon("MyAddon")
        addon:SetDependencyPolicy("strict")
        local database = addon:CreateModule("Database")
        local inventory = addon:CreateModule("Inventory")
        inventory:DependsOn("Database")

        addon:EnableAll()

        assert.is_true(database:IsEnabled())
        assert.is_true(inventory:IsEnabled())
    end)
end)
