local TestEnv = require("TestKitTestEnv")

describe("TestKit manifest metadata", function()
    after_each(TestEnv.Reset)

    it("matches runtime API and revision", function()
        local TestKit = TestEnv.NewPackage()
        local file = assert(io.open("packages/testKit/package.manifest.json", "r"))
        local text = file:read("*a")
        file:close()

        local api = tonumber(text:match('"api"%s*:%s*(%d+)'))
        local revision = tonumber(text:match('"revision"%s*:%s*(%d+)'))

        assert.are.equal(TestKit.API, api)
        assert.are.equal(TestKit.REVISION, revision)
    end)
end)
