local TestEnv = require("CacheKitTestEnv")

describe("CacheKit manifest metadata", function()
    after_each(TestEnv.Reset)

    it("matches runtime API and revision", function()
        local CacheKit = TestEnv.NewPackage()
        local file = assert(io.open("packages/cacheKit/package.manifest.json", "r"))
        local text = file:read("*a")
        file:close()

        local api = tonumber(text:match('"api"%s*:%s*(%d+)'))
        local revision = tonumber(text:match('"revision"%s*:%s*(%d+)'))

        assert.are.equal(CacheKit.API, api)
        assert.are.equal(CacheKit.REVISION, revision)
    end)
end)
