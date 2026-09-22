local TestEnv = require("ModuleKitTestEnv")

describe("ModuleKit manifest metadata", function()
    after_each(TestEnv.Reset)

    it("matches runtime API and revision", function()
        local ModuleKit = TestEnv.NewPackage()
        local file = assert(io.open("packages/moduleKit/package.manifest.json", "r"))
        local text = file:read("*a")
        file:close()

        local api = tonumber(text:match('"api"%s*:%s*(%d+)'))
        local revision = tonumber(text:match('"revision"%s*:%s*(%d+)'))

        assert.are.equal(ModuleKit.API, api)
        assert.are.equal(ModuleKit.REVISION, revision)
    end)
end)
