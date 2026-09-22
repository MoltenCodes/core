local TestEnv = require("ModuleKitTestEnv")

describe("ModuleKit failures", function()
    local ModuleKit

    before_each(function()
        ModuleKit = TestEnv.NewPackage()
    end)

    after_each(TestEnv.Reset)

    it("keeps a module created when initialization fails", function()
        local addon = ModuleKit:ForAddon("MyAddon")
        local module = addon:CreateModule("UI")
        module.OnInitialize = function()
            error("initialize failed")
        end

        assert.has_error(function()
            module:Initialize()
        end)
        assert.are.equal("created", module:GetState())
        assert.is_not_nil(module:GetLastError())
    end)

    it("allows initialization retry after failure", function()
        local addon = ModuleKit:ForAddon("MyAddon")
        local module = addon:CreateModule("UI")
        local fail = true
        module.OnInitialize = function()
            if fail then
                error("initialize failed")
            end
        end

        assert.has_error(function()
            module:Initialize()
        end)
        fail = false
        module:Initialize()

        assert.are.equal("initialized", module:GetState())
        assert.is_nil(module:GetLastError())
    end)

    it("keeps a module initialized when enable fails", function()
        local addon = ModuleKit:ForAddon("MyAddon")
        local module = addon:CreateModule("UI")
        module.OnEnable = function()
            error("enable failed")
        end

        assert.has_error(function()
            module:Enable()
        end)
        assert.are.equal("initialized", module:GetState())
    end)

    it("keeps a module enabled when disable fails", function()
        local addon = ModuleKit:ForAddon("MyAddon")
        local module = addon:CreateModule("UI")
        module.OnDisable = function()
            error("disable failed")
        end
        module:Enable()

        assert.has_error(function()
            module:Disable()
        end)
        assert.is_true(module:IsEnabled())
    end)

    it("blocks hard dependents when bulk initialization dependency fails", function()
        local addon = ModuleKit:ForAddon("MyAddon")
        local database = addon:CreateModule("Database")
        local ui = addon:CreateModule("UI")
        ui:DependsOn("Database")
        database.OnInitialize = function()
            error("database failed")
        end

        assert.has_error(function()
            addon:InitializeAll()
        end)
        assert.are.equal("Database", ui:GetBlockedBy())
        assert.are.equal("created", ui:GetState())
    end)

    it("continues independent modules during bulk initialization errors", function()
        local addon = ModuleKit:ForAddon("MyAddon")
        local broken = addon:CreateModule("Broken")
        local healthy = addon:CreateModule("Healthy")
        local healthyCalls = 0
        broken.OnInitialize = function()
            error("broken")
        end
        healthy.OnInitialize = function()
            healthyCalls = healthyCalls + 1
        end

        assert.has_error(function()
            addon:InitializeAll()
        end)
        assert.are.equal(1, healthyCalls)
        assert.are.equal("initialized", healthy:GetState())
    end)
    it("distinguishes nil error objects from no error", function()
        local addon = ModuleKit:ForAddon("MyAddon")
        local module = addon:CreateModule("UI")
        module.OnInitialize = function()
            error(nil)
        end

        assert.has_error(function()
            module:Initialize()
        end)
        assert.is_true(module:HasLastError())
        assert.is_nil(module:GetLastError())
    end)

    it("preserves hard-dependency state when DisableAll cannot disable a dependent", function()
        local addon = ModuleKit:ForAddon("MyAddon")
        local database = addon:CreateModule("Database")
        local ui = addon:CreateModule("UI")
        ui:DependsOn("Database")
        ui.OnDisable = function()
            error("ui disable failed")
        end

        addon:EnableAll()

        assert.has_error(function()
            addon:DisableAll()
        end)
        assert.is_true(ui:IsEnabled())
        assert.is_true(database:IsEnabled())
        assert.are.equal("UI", database:GetBlockedBy())
    end)

    it("preserves false error objects distinctly from successful operations", function()
        local addon = ModuleKit:ForAddon("MyAddon")
        local module = addon:CreateModule("UI")
        module.OnEnable = function()
            error(false)
        end

        local ok, value = pcall(function()
            module:Enable()
        end)

        assert.is_false(ok)
        assert.is_false(value)
        assert.is_true(module:HasLastError())
        assert.is_false(module:GetLastError())
    end)
end)
