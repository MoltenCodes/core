local TestEnv = require("LifecycleKitTestEnv")

local function expectErrorContaining(expected, callback)
    local ok, message = pcall(callback)
    assert.is_false(ok)
    assert.is_not_nil(string.find(tostring(message), expected, 1, true))
end

describe("LifecycleKit validation", function()
    local LifecycleKit
    before_each(function() LifecycleKit = TestEnv.NewPackage() end)
    after_each(TestEnv.Reset)

    it("rejects invalid addon names", function()
        expectErrorContaining("addonName must be a non-empty string", function()
            LifecycleKit:ForAddon(42)
        end)
        expectErrorContaining("addonName must be a non-empty string", function()
            LifecycleKit:ForAddon("")
        end)
    end)

    it("rejects invalid callbacks", function()
        local life = LifecycleKit:ForAddon("MyAddon")
        expectErrorContaining("callback must be a function", function() life:OnLoaded(false) end)
        expectErrorContaining("callback must be a function", function() life:OnReady({}) end)
        expectErrorContaining("callback must be a function", function() life:OnShutdown("no") end)
    end)

    it("does not cache a partially constructed instance when event setup fails", function()
        local Registry = rawget(rawget(_G, "MoltenCodes"), "Registry")
        local EventKit = Registry:Get("eventKit", 1)
        local originalOnce = EventKit.Once
        EventKit.Once = function() error("synthetic setup failure") end

        expectErrorContaining("synthetic setup failure", function()
            LifecycleKit:ForAddon("RetryAddon")
        end)
        EventKit.Once = originalOnce

        local life = LifecycleKit:ForAddon("RetryAddon")
        TestEnv.LoadAddon("RetryAddon")
        assert.is_true(life:IsLoaded())
    end)

    it("leaves phase state committed when a callback raises", function()
        local life = LifecycleKit:ForAddon("MyAddon")
        life:OnLoaded(function() error("boom") end)
        expectErrorContaining("boom", function() TestEnv.LoadAddon("MyAddon") end)
        assert.is_true(life:IsLoaded())
    end)


    it("delivers all subscribers and preserves the first error when several fail", function()
        local life = LifecycleKit:ForAddon("MyAddon")
        local seen = {}

        life:OnLoaded(function()
            seen[#seen + 1] = "first"
            error("first failure")
        end)
        life:OnLoaded(function()
            seen[#seen + 1] = "second"
            error("second failure")
        end)
        local final = life:OnLoaded(function()
            seen[#seen + 1] = "third"
        end)

        expectErrorContaining("first failure", function() TestEnv.LoadAddon("MyAddon") end)
        assert.are.same({ "first", "second", "third" }, seen)
        assert.is_false(final:IsConnected())
    end)
    it("preserves false as a valid first callback error object", function()
        local life = LifecycleKit:ForAddon("MyAddon")
        local laterCalls = 0
        life:OnLoaded(function() error(false) end)
        life:OnLoaded(function()
            laterCalls = laterCalls + 1
            error("second failure")
        end)
        life:OnLoaded(function() laterCalls = laterCalls + 1 end)

        local ok, message = pcall(function() TestEnv.LoadAddon("MyAddon") end)
        assert.is_false(ok)
        assert.are.equal(false, message)
        assert.are.equal(2, laterCalls)
    end)

    it("preserves nil as a valid callback error object", function()
        local life = LifecycleKit:ForAddon("MyAddon")
        local laterCalls = 0
        life:OnLoaded(function() error(nil) end)
        life:OnLoaded(function() laterCalls = laterCalls + 1 end)

        local ok, message = pcall(function() TestEnv.LoadAddon("MyAddon") end)
        assert.is_false(ok)
        assert.is_nil(message)
        assert.are.equal(1, laterCalls)
    end)

    it("delivers later phase subscribers before re-raising the first callback error", function()
        local life = LifecycleKit:ForAddon("MyAddon")
        local laterCalls = 0
        life:OnLoaded(function() error("first failure") end)
        local later = life:OnLoaded(function() laterCalls = laterCalls + 1 end)

        expectErrorContaining("first failure", function() TestEnv.LoadAddon("MyAddon") end)
        assert.are.equal(1, laterCalls)
        assert.is_false(later:IsConnected())
    end)
end)
