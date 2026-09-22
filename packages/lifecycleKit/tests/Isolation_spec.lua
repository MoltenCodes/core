local TestEnv = require("LifecycleKitTestEnv")

local function expectErrorContaining(expected, callback)
    local ok, message = pcall(callback)
    assert.is_false(ok)
    assert.is_not_nil(string.find(tostring(message), expected, 1, true))
end

describe("LifecycleKit cross-addon phase isolation", function()
    local LifecycleKit
    before_each(function()
        LifecycleKit = TestEnv.NewPackage()
    end)
    after_each(TestEnv.Reset)

    it("advances every loaded addon to ready before re-raising a callback error", function()
        local broken = LifecycleKit:ForAddon("BrokenAddon")
        local healthy = LifecycleKit:ForAddon("HealthyAddon")
        local healthyCalls = 0

        broken:OnReady(function()
            error("ready failure")
        end)
        healthy:OnReady(function()
            healthyCalls = healthyCalls + 1
        end)

        TestEnv.LoadAddon("BrokenAddon")
        TestEnv.LoadAddon("HealthyAddon")

        expectErrorContaining("ready failure", TestEnv.Login)

        assert.is_true(broken:IsReady())
        assert.is_true(healthy:IsReady())
        assert.are.equal(1, healthyCalls)
    end)

    it("advances every addon to shutdown before re-raising a callback error", function()
        local broken = LifecycleKit:ForAddon("BrokenAddon")
        local healthy = LifecycleKit:ForAddon("HealthyAddon")
        local healthyCalls = 0

        broken:OnShutdown(function()
            error("shutdown failure")
        end)
        healthy:OnShutdown(function()
            healthyCalls = healthyCalls + 1
        end)

        TestEnv.LoadAddon("BrokenAddon")
        TestEnv.LoadAddon("HealthyAddon")
        TestEnv.Login()

        expectErrorContaining("shutdown failure", TestEnv.Logout)

        assert.is_true(broken:IsShutdown())
        assert.is_true(healthy:IsShutdown())
        assert.are.equal(1, healthyCalls)
    end)
end)
