local Env = require("ProfileKitTestEnv")

---Load ProfileKit against a `debugprofilestop` that counts its calls.
---@return table ProfileKit
---@return fun(): integer readCount
local function newPackageCountingClockReads()
    Env.Reset()
    Env.InstallWowApi()
    local reads = 0
    -- The spec replaces the host clock ProfileKit reads from the global table.
    -- selene: allow(global_usage)
    rawset(_G, "debugprofilestop", function()
        reads = reads + 1
        return Env.NowMs()
    end)
    require("Registry")
    local ProfileKit = require("ProfileKit")
    return ProfileKit, function()
        return reads
    end
end

local function returnThree(first, second, third)
    return first, second, third
end

describe("ProfileKit disabled path", function()
    before_each(function()
        Env.Reset()
    end)
    after_each(function()
        Env.Reset()
    end)

    it("loads disabled", function()
        local ProfileKit = Env.NewPackage()
        assert.is_false(ProfileKit:IsEnabled())
    end)

    it("binds the same no-op to Begin and End and records nothing", function()
        local ProfileKit, readCount = newPackageCountingClockReads()
        local section = ProfileKit:Section("disabled")

        assert.are.equal(section.Begin, section.End)
        assert.are.equal(0, select("#", section:Begin()))
        Env.AdvanceProfileMs(5)
        assert.are.equal(0, select("#", section:End()))

        assert.are.equal(0, readCount())
        assert.are.equal(0, ProfileKit:Report()[1].count)
    end)

    it("passes Measure straight through without reading the clock", function()
        local ProfileKit, readCount = newPackageCountingClockReads()

        local first, second, third = ProfileKit:Measure("pass", returnThree, 1, nil, 3)
        assert.are.equal(1, first)
        assert.is_nil(second)
        assert.are.equal(3, third)
        assert.are.equal(0, readCount())
        assert.are.equal(0, #ProfileKit:Report())
    end)

    it("allocates nothing on Begin, End and Measure #allocation", function()
        local ProfileKit = Env.NewPackage()
        local section = ProfileKit:Section("allocation")

        local allocated = Env.AllocatedKilobytes(function()
            for _ = 1, 1000 do
                section:Begin()
                section:End()
                ProfileKit:Measure("allocation", returnThree, 1, 2, 3)
            end
        end)
        assert.are.equal(0, allocated)
    end)

    it("allocates nothing on enabled Begin, End and Measure either #allocation", function()
        local ProfileKit = Env.NewPackage()
        ProfileKit:Enable()
        local section = ProfileKit:Section("allocation")

        local allocated = Env.AllocatedKilobytes(function()
            for _ = 1, 1000 do
                section:Begin()
                Env.AdvanceProfileMs(1)
                section:End()
                ProfileKit:Measure("measured", returnThree, 1, 2, 3)
            end
        end)
        assert.are.equal(0, allocated)
    end)
end)
