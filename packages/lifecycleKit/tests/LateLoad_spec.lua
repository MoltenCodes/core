local TestEnv = require("LifecycleKitTestEnv")

describe("LifecycleKit late-load detection", function()
    after_each(TestEnv.Reset)

    it("catches up to ready when addon is already loaded and player logged in", function()
        local LifecycleKit = TestEnv.NewPackage()
        TestEnv.MarkAddonLoaded("LateAddon")
        TestEnv.SetLoggedIn(true)
        local life = LifecycleKit:ForAddon("LateAddon")
        assert.are.equal("ready", life:GetState())
        assert.is_true(life:IsLoaded())
        assert.is_true(life:IsReady())
    end)

    it("catches up only to loaded when player is not logged in", function()
        local LifecycleKit = TestEnv.NewPackage()
        TestEnv.MarkAddonLoaded("LateAddon")
        local life = LifecycleKit:ForAddon("LateAddon")
        assert.are.equal("loaded", life:GetState())
    end)

    it("does not treat a legacy single loading return as loaded", function()
        local LifecycleKit = TestEnv.NewPackage()
        -- The package reads this host global at load time, so the spec has to install it in the global table.
        -- selene: allow(global_usage)
        rawset(_G, "C_AddOns", nil)
        -- The package reads this host global at load time, so the spec has to install it in the global table.
        -- selene: allow(global_usage)
        rawset(_G, "IsAddOnLoaded", function()
            return true
        end)
        local life = LifecycleKit:ForAddon("LegacyAddon")
        assert.are.equal("loading", life:GetState())
    end)

    it("does not treat a modern loading-but-not-finished addon as loaded", function()
        local LifecycleKit = TestEnv.NewPackage()
        TestEnv.MarkAddonLoading("PartialAddon")

        -- C_AddOns.IsAddOnLoaded answers (true, false) while an addon's files
        -- are executing but its ADDON_LOADED transition has not completed.
        local life = LifecycleKit:ForAddon("PartialAddon")
        assert.are.equal("loading", life:GetState())

        -- The normal transition still arrives once loading finishes.
        TestEnv.LoadAddon("PartialAddon")
        assert.are.equal("loaded", life:GetState())
    end)

    it("uses the legacy finished return when explicitly available", function()
        local LifecycleKit = TestEnv.NewPackage()
        -- The package reads this host global at load time, so the spec has to install it in the global table.
        -- selene: allow(global_usage)
        rawset(_G, "C_AddOns", nil)
        -- The package reads this host global at load time, so the spec has to install it in the global table.
        -- selene: allow(global_usage)
        rawset(_G, "IsAddOnLoaded", function()
            return true, true
        end)
        local life = LifecycleKit:ForAddon("LegacyAddon")
        assert.are.equal("loaded", life:GetState())
    end)
end)
