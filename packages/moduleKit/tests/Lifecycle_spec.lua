local TestEnv = require("ModuleKitTestEnv")

describe("ModuleKit lifecycle integration", function()
    local ModuleKit

    before_each(function()
        ModuleKit = TestEnv.NewPackage()
    end)

    after_each(TestEnv.Reset)

    it("initializes modules when the addon loads", function()
        local addon = ModuleKit:ForAddon("MyAddon")
        local module = addon:CreateModule("UI")
        local calls = 0
        module.OnInitialize = function()
            calls = calls + 1
        end

        TestEnv.LoadAddon("MyAddon")

        assert.are.equal(1, calls)
        assert.are.equal("initialized", module:GetState())
    end)

    it("enables modules when the addon becomes ready", function()
        local addon = ModuleKit:ForAddon("MyAddon")
        local module = addon:CreateModule("UI")
        local calls = {}
        module.OnInitialize = function()
            calls[#calls + 1] = "initialize"
        end
        module.OnEnable = function()
            calls[#calls + 1] = "enable"
        end

        TestEnv.LoadAddon("MyAddon")
        TestEnv.Login()

        assert.are.same({ "initialize", "enable" }, calls)
        assert.is_true(module:IsEnabled())
    end)

    it("uses reverse graph order during shutdown", function()
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

        TestEnv.LoadAddon("MyAddon")
        TestEnv.Login()
        TestEnv.Logout()

        assert.are.same({ "UI", "Database" }, calls)
        assert.are.equal("disabled", ui:GetState())
        assert.are.equal("disabled", database:GetState())
    end)

    it("rejects new modules after shutdown", function()
        local addon = ModuleKit:ForAddon("MyAddon")
        TestEnv.LoadAddon("MyAddon")
        TestEnv.Login()
        TestEnv.Logout()

        assert.has_error(function()
            addon:CreateModule("Late")
        end)
    end)

    it("catches up late definition-table modules", function()
        TestEnv.MarkAddonLoaded("MyAddon")
        TestEnv.SetLoggedIn(true)
        local addon = ModuleKit:ForAddon("MyAddon")
        local calls = {}

        local module = addon:CreateModule("Late", {
            onInitialize = function()
                calls[#calls + 1] = "initialize"
            end,
            onEnable = function()
                calls[#calls + 1] = "enable"
            end,
        })

        assert.are.same({ "initialize", "enable" }, calls)
        assert.is_true(module:IsEnabled())
    end)

    it("supports explicit activation for mutable late modules", function()
        TestEnv.MarkAddonLoaded("MyAddon")
        TestEnv.SetLoggedIn(true)
        local addon = ModuleKit:ForAddon("MyAddon")
        local module = addon:CreateModule("Late")
        local calls = 0
        module.OnInitialize = function()
            calls = calls + 1
        end
        module.OnEnable = function()
            calls = calls + 10
        end

        assert.are.equal(0, calls)
        module:Activate()

        assert.are.equal(11, calls)
        assert.is_true(module:IsEnabled())
    end)
    it("rejects direct initialization after shutdown", function()
        local addon = ModuleKit:ForAddon("MyAddon")
        local module = addon:CreateModule("Late")
        TestEnv.LoadAddon("MyAddon")
        TestEnv.Login()
        TestEnv.Logout()

        assert.has_error(function()
            module:Initialize()
        end)
    end)

    it("rejects provider registration after shutdown", function()
        local addon = ModuleKit:ForAddon("MyAddon")
        TestEnv.LoadAddon("MyAddon")
        TestEnv.Login()
        TestEnv.Logout()

        assert.has_error(function()
            addon:ProvideValue("Late", {})
        end)
    end)

    it("does not let one addon enable failure starve another addon", function()
        local brokenAddon = ModuleKit:ForAddon("BrokenAddon")
        local healthyAddon = ModuleKit:ForAddon("HealthyAddon")
        local broken = brokenAddon:CreateModule("Broken")
        local healthy = healthyAddon:CreateModule("Healthy")

        broken.OnEnable = function()
            error("broken enable")
        end

        TestEnv.LoadAddon("BrokenAddon")
        TestEnv.LoadAddon("HealthyAddon")

        assert.has_error(function()
            TestEnv.Login()
        end)

        assert.is_false(broken:IsEnabled())
        assert.is_true(healthy:IsEnabled())
    end)

    it("continues shutdown cleanup after a module disable error", function()
        local addon = ModuleKit:ForAddon("MyAddon")
        local calls = {}
        local first = addon:CreateModule("First")
        local second = addon:CreateModule("Second")

        first.OnDisable = function()
            calls[#calls + 1] = "First"
        end
        second.OnDisable = function()
            calls[#calls + 1] = "Second"
            error("disable failed")
        end

        TestEnv.LoadAddon("MyAddon")
        TestEnv.Login()

        assert.has_error(function()
            TestEnv.Logout()
        end)

        assert.are.same({ "Second", "First" }, calls)
        assert.are.equal("disabled", first:GetState())
        assert.is_true(second:IsEnabled())
        assert.has_error(function()
            first:Enable()
        end)
    end)


    it("performs terminal cleanup even when an inactive late definition makes the full graph invalid", function()
        local addon = ModuleKit:ForAddon("MyAddon")
        local healthy = addon:CreateModule("Healthy")
        local disables = 0
        healthy.OnDisable = function()
            disables = disables + 1
        end

        TestEnv.LoadAddon("MyAddon")
        TestEnv.Login()
        addon:CreateModule("Broken"):DependsOn("Missing")

        assert.has_error(function()
            TestEnv.Logout()
        end)

        assert.are.equal(1, disables)
        assert.is_false(healthy:IsEnabled())
    end)

end)
