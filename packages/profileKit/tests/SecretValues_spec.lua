local Env = require("ProfileKitTestEnv")

local SOURCE = debug.getinfo(1, "S").short_src

---Return the line number of the statement that called this helper.
---@return integer line
local function currentLine()
    return debug.getinfo(2, "l").currentline
end

describe("ProfileKit secret values", function()
    local ProfileKit
    local secret

    ---Load the module chain on a host whose `issecretvalue` reports `secret`.
    ---ProfileKit binds the probe once at load, so it is installed first.
    before_each(function()
        Env.Reset()
        Env.InstallWowApi()
        secret = Env.NewSecretValue()
        -- selene: allow(global_usage)
        rawset(_G, "issecretvalue", function(value)
            return rawequal(value, secret)
        end)
        require("Registry")
        ProfileKit = require("ProfileKit")
    end)
    after_each(function()
        Env.Reset()
    end)

    it("refuses a secret maxSections at the caller before comparing it", function()
        local line
        local ok, value = pcall(function()
            line = currentLine() + 1
            ProfileKit:SetLimits({ maxSections = secret })
        end)
        assert.is_false(ok)
        assert.are.equal(
            SOURCE
                .. ":"
                .. line
                .. ": ProfileKit:SetLimits limits.maxSections must be a positive integer or ProfileKit.UNBOUNDED",
            value
        )
        assert.are.equal(ProfileKit.DEFAULT_MAX_SECTIONS, ProfileKit:GetLimits().maxSections)
    end)

    it("still accepts a plain positive integer and UNBOUNDED", function()
        ProfileKit:SetLimits({ maxSections = 8 })
        assert.are.equal(8, ProfileKit:GetLimits().maxSections)
        ProfileKit:SetLimits({ maxSections = ProfileKit.UNBOUNDED })
        assert.are.equal(ProfileKit.UNBOUNDED, ProfileKit:GetLimits().maxSections)
    end)

    it("refuses a secret receiver as a non-facade receiver", function()
        local line
        local ok, value = pcall(function()
            line = currentLine() + 1
            ProfileKit.GetLimits(secret)
        end)
        assert.is_false(ok)
        assert.are.equal(
            SOURCE
                .. ":"
                .. line
                .. ": ProfileKit:GetLimits must be called on the ProfileKit facade; use ProfileKit:GetLimits(...)",
            value
        )
    end)
end)
