local TestEnv = require("ModuleKitTestEnv")

describe("ModuleKit", function()
    local ModuleKit

    before_each(function()
        ModuleKit = TestEnv.NewPackage()
    end)

    after_each(TestEnv.Reset)

    it("returns one stable container per addon", function()
        local first = ModuleKit:ForAddon("MyAddon")
        local second = ModuleKit:ForAddon("MyAddon")
        local other = ModuleKit:ForAddon("OtherAddon")

        assert.are.equal(first, second)
        assert.are_not.equal(first, other)
        assert.are.equal("MyAddon", first:GetAddonName())
    end)

    it("uses automatic dependency policy by default", function()
        local addon = ModuleKit:ForAddon("MyAddon")
        assert.are.equal("automatic", addon:GetDependencyPolicy())
    end)

    it("supports strict dependency policy explicitly", function()
        local addon = ModuleKit:ForAddon("MyAddon")
        local previous = addon:SetDependencyPolicy("strict")

        assert.are.equal("automatic", previous)
        assert.are.equal("strict", addon:GetDependencyPolicy())
    end)

    it("rejects unknown dependency policies", function()
        local addon = ModuleKit:ForAddon("MyAddon")
        assert.has_error(function()
            addon:SetDependencyPolicy("magic")
        end)
    end)

    it("creates and looks up modules", function()
        local addon = ModuleKit:ForAddon("MyAddon")
        local module = addon:CreateModule("Inventory")

        assert.are.equal(module, addon:GetModule("Inventory"))
        assert.is_true(addon:HasModule("Inventory"))
        assert.are.equal("Inventory", module:GetName())
        assert.are.equal(addon, module:GetAddon())
        assert.are.equal("created", module:GetState())
    end)

    it("rejects duplicate module names", function()
        local addon = ModuleKit:ForAddon("MyAddon")
        addon:CreateModule("Inventory")

        assert.has_error(function()
            addon:CreateModule("Inventory")
        end)
    end)

    it("initializes at most once", function()
        local addon = ModuleKit:ForAddon("MyAddon")
        local module = addon:CreateModule("Inventory")
        local calls = 0

        module.OnInitialize = function()
            calls = calls + 1
        end

        module:Initialize()
        module:Initialize()

        assert.are.equal(1, calls)
        assert.are.equal("initialized", module:GetState())
        assert.is_true(module:IsInitialized())
    end)

    it("enables and disables idempotently", function()
        local addon = ModuleKit:ForAddon("MyAddon")
        local module = addon:CreateModule("Inventory")
        local enables = 0
        local disables = 0

        module.OnEnable = function()
            enables = enables + 1
        end
        module.OnDisable = function()
            disables = disables + 1
        end

        module:Enable()
        module:Enable()
        module:Disable()
        module:Disable()

        assert.are.equal(1, enables)
        assert.are.equal(1, disables)
        assert.are.equal("disabled", module:GetState())
        assert.is_false(module:IsEnabled())
    end)

    it("freezes graph configuration after initialization", function()
        local addon = ModuleKit:ForAddon("MyAddon")
        local module = addon:CreateModule("Inventory")
        module:Initialize()

        assert.has_error(function()
            module:DependsOn("Database")
        end)
        assert.has_error(function()
            module:Inject("database", "Database")
        end)
    end)

    it("rejects unknown definition fields instead of silently ignoring typos", function()
        local addon = ModuleKit:ForAddon("MyAddon")

        assert.has_error(function()
            addon:CreateModule("Inventory", {
                depensOn = { "Database" },
            })
        end)
        assert.is_false(addon:HasModule("Inventory"))
    end)

    it("rejects sparse definition arrays", function()
        local addon = ModuleKit:ForAddon("MyAddon")

        assert.has_error(function()
            addon:CreateModule("Inventory", {
                dependsOn = {
                    [1] = "Database",
                    [3] = "Profiles",
                },
            })
        end)
    end)


    it("returns a new module-list snapshot on every GetModules call", function()
        local addon = ModuleKit:ForAddon("MyAddon")
        local firstModule = addon:CreateModule("First")
        local first = addon:GetModules()
        local second = addon:GetModules()

        assert.are_not.equal(first, second)
        first[1] = nil
        assert.are.equal(firstModule, second[1])
        assert.are.equal(firstModule, addon:GetModules()[1])
    end)

end)
