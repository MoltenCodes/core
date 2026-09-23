local Env = require("ProfileKitTestEnv")

local MANIFEST_PATH = "packages/profileKit/package.manifest.json"

describe("ProfileKit manifest", function()
    before_each(function()
        Env.Reset()
    end)
    after_each(function()
        Env.Reset()
    end)

    it("matches runtime API and revision metadata", function()
        local ProfileKit = Env.NewPackage()
        local file = assert(io.open(MANIFEST_PATH, "r"))
        local contents = file:read("*a")
        file:close()

        assert.are.equal(ProfileKit.API, tonumber(contents:match('"api"%s*:%s*(%d+)')))
        assert.are.equal(ProfileKit.REVISION, tonumber(contents:match('"revision"%s*:%s*(%d+)')))
    end)

    it("declares only the Registry API 2 dependency", function()
        local file = assert(io.open(MANIFEST_PATH, "r"))
        local contents = file:read("*a")
        file:close()

        local dependencies = contents:match('"dependencies"%s*:%s*(%b{})')
        assert.is_not_nil(dependencies)
        assert.is_not_nil(dependencies:match('"registry"%s*:%s*{%s*"api"%s*:%s*2%s*}'))
        local _, dependencyCount = dependencies:gsub('"%w+"%s*:%s*{', "")
        assert.are.equal(1, dependencyCount)
    end)
end)
