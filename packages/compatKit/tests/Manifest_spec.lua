local Env = require("CompatKitTestEnv")

local MANIFEST_PATH = "packages/compatKit/package.manifest.json"

describe("CompatKit manifest", function()
    after_each(Env.Reset)

    it("matches runtime API and revision metadata", function()
        local CompatKit = Env.NewPackage()
        local text = Env.ReadFile(MANIFEST_PATH)
        local api = tonumber(text:match('"api"%s*:%s*(%d+)'))
        local revision = tonumber(text:match('"revision"%s*:%s*(%d+)'))
        assert.are.equal(CompatKit.API, api)
        assert.are.equal(CompatKit.REVISION, revision)
    end)

    it("declares Registry API 2 as its one dependency and the two optional Kits", function()
        local text = Env.ReadFile(MANIFEST_PATH)
        local dependencies = text:match('"dependencies"%s*:%s*(%b{})')
        assert.is_truthy(dependencies:find('"registry"%s*:%s*{%s*"api"%s*:%s*2%s*}'))
        assert.is_nil(dependencies:find("clientKit", 1, true))
        assert.is_nil(dependencies:find("apiKit", 1, true))

        local optional = text:match('"optionalDependencies"%s*:%s*(%b{})')
        assert.is_truthy(optional:find('"clientKit"%s*:%s*{%s*"api"%s*:%s*1%s*}'))
        assert.is_truthy(optional:find('"apiKit"%s*:%s*{%s*"api"%s*:%s*1%s*}'))
        assert.is_truthy(text:find('"version"%s*:%s*"0%.1%.2"'))
        assert.is_truthy(text:find('"license"%s*:%s*"MIT"'))
    end)

    it("writes optionalDependencies after the api field", function()
        local text = Env.ReadFile(MANIFEST_PATH)
        assert.is_true(text:find('"api"', 1, true) < text:find('"optionalDependencies"', 1, true))
    end)
end)
