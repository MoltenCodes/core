local Env = require("ProfileKitTestEnv")

describe("ProfileKit section cap", function()
    local ProfileKit

    before_each(function()
        ProfileKit = Env.NewPackage()
    end)
    after_each(function()
        Env.Reset()
    end)

    ---Create sections until the default cap is reached.
    local function fillToCap()
        for index = 1, ProfileKit.DEFAULT_MAX_SECTIONS do
            assert.is_not_nil(ProfileKit:Section("section " .. index))
        end
    end

    it("defaults to 256 sections", function()
        assert.are.equal(256, ProfileKit.DEFAULT_MAX_SECTIONS)
    end)

    it("refuses a new section beyond the cap with nil and capped", function()
        fillToCap()
        local section, reason = ProfileKit:Section("one too many")
        assert.is_nil(section)
        assert.are.equal("capped", reason)
        assert.are.equal(256, #ProfileKit:Report())
    end)

    it("still returns sections that already exist at the cap", function()
        fillToCap()
        assert.is_not_nil(ProfileKit:Section("section 1"))
    end)

    it("keeps counting sections against the cap after Reset", function()
        fillToCap()
        ProfileKit:Reset()
        local _, reason = ProfileKit:Section("after reset")
        assert.are.equal("capped", reason)
    end)

    it("runs Measure unmeasured for a name the cap refuses", function()
        fillToCap()
        ProfileKit:Enable()
        local value = ProfileKit:Measure("refused", function(argument)
            return argument * 2
        end, 21)
        assert.are.equal(42, value)
        assert.are.equal(256, #ProfileKit:Report())
    end)
end)
