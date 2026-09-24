local TestEnv = require("ApiKitTestEnv")

describe("ApiKit manifest metadata", function()
    after_each(TestEnv.Reset)

    it("matches runtime API and revision", function()
        local ApiKit = TestEnv.NewPackageFor("retail")
        local file = assert(io.open("packages/apiKit/package.manifest.json", "r"))
        local text = file:read("*a")
        file:close()

        local api = tonumber(text:match('"api"%s*:%s*(%d+)'))
        local revision = tonumber(text:match('"revision"%s*:%s*(%d+)'))

        assert.are.equal(ApiKit.API, api)
        assert.are.equal(ApiKit.REVISION, revision)
    end)
end)
