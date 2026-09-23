local Env = require("ProfileKitTestEnv")

local SOURCE_PATH = "packages/profileKit/src/ProfileKit.lua"

---Run ProfileKit's own source as if it carried `revision`.
---
---ProfileKit starts at revision 1, so no older copy exists to upgrade from.
---Rewriting the revision constant of the real file produces the next embedded
---copy a consumer could load, which is exactly what an in-place upgrade meets.
---@param revision integer
---@return table ProfileKit
local function loadSourceAsRevision(revision)
    local file = assert(io.open(SOURCE_PATH, "r"))
    local source = file:read("*a")
    file:close()

    local rewritten, replacements = source:gsub(
        "local IMPLEMENTATION_REVISION = %d+",
        "local IMPLEMENTATION_REVISION = " .. revision,
        1
    )
    assert.are.equal(1, replacements)
    local chunk = assert(loadstring(rewritten, "@" .. SOURCE_PATH))
    return chunk()
end

describe("ProfileKit bootstrap", function()
    before_each(function()
        Env.Reset()
    end)
    after_each(function()
        Env.Reset()
    end)

    it("refuses to load without Registry", function()
        Env.InstallWowApi()
        Env.expectErrorContaining("requires Registry API 2 to be loaded first", function()
            Env.requireAfterFailedLoad("ProfileKit")
        end)
    end)

    it("publishes through Registry and the shared namespace", function()
        local ProfileKit, Registry = Env.NewPackage()
        assert.are.equal(ProfileKit, Registry:Get("profileKit", 1))
        assert.are.equal(1, ProfileKit.API)
    end)

    it("reuses the shared facade, sections and statistics on duplicate load", function()
        local ProfileKit = Env.NewPackage()
        ProfileKit:Enable()
        local section = ProfileKit:Section("kept")
        section:Begin()
        Env.AdvanceProfileMs(2)
        section:End()

        local reloaded = Env.ReloadPackage()
        assert.are.equal(ProfileKit, reloaded)
        assert.are.equal(section, reloaded:Section("kept"))
        assert.is_true(reloaded:IsEnabled())
        assert.are.equal(2, reloaded:Report()[1].total)
    end)

    it("does not downgrade a newer compatible embedded revision", function()
        local ProfileKit, Registry = Env.NewPackage()
        local shared = Registry:Register("profileKit", 1, 99)
        assert.are.equal(ProfileKit, shared)
        rawset(shared, "REVISION", 99)

        local reloaded = Env.ReloadPackage()
        assert.are.equal(shared, reloaded)
        assert.are.equal(99, reloaded.REVISION)
    end)

    it("upgrades in place, keeping sections, statistics and the enabled binding", function()
        local ProfileKit = Env.NewPackage()
        ProfileKit:Enable()
        local section = ProfileKit:Section("upgraded")
        section:Begin()
        Env.AdvanceProfileMs(3)
        section:End()
        local oldBegin = section.Begin
        section:Begin()

        local upgraded = loadSourceAsRevision(2)

        assert.are.equal(ProfileKit, upgraded)
        assert.are.equal(2, upgraded.REVISION)
        assert.is_true(upgraded:IsEnabled())
        assert.are.equal(section, upgraded:Section("upgraded"))
        -- The old copy's section now resolves to the new copy's methods.
        assert.are_not.equal(oldBegin, section.Begin)

        -- A measurement opened under revision 1 is closed by revision 2.
        Env.AdvanceProfileMs(4)
        assert.are.equal(4, section:End())
        assert.are.same(
            { { name = "upgraded", count = 2, total = 7, max = 4, last = 4 } },
            upgraded:Report()
        )
    end)

    it("upgrades a disabled copy into a disabled binding", function()
        local ProfileKit = Env.NewPackage()
        local section = ProfileKit:Section("quiet")

        local upgraded = loadSourceAsRevision(2)
        assert.is_false(upgraded:IsEnabled())
        assert.are.equal(0, select("#", section:Begin()))
    end)

    it("comes up disabled when the upgrading copy's host has no clock", function()
        local ProfileKit = Env.NewPackage()
        ProfileKit:Enable()
        -- The spec removes the host clock the next embedded copy would read.
        -- selene: allow(global_usage)
        rawset(_G, "debugprofilestop", nil)

        local upgraded = loadSourceAsRevision(2)
        assert.is_false(upgraded:IsEnabled())
        local enabled, reason = upgraded:Enable()
        assert.is_false(enabled)
        assert.are.equal("unavailable", reason)
    end)

    it("refuses corrupted shared state on reload", function()
        local ProfileKit = Env.NewPackage()
        rawset(ProfileKit._state, "sections", false)
        Env.expectErrorContaining("package state is corrupted or incomplete", function()
            Env.ReloadPackage()
        end)
    end)
end)
