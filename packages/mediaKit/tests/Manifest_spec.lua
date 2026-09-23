local TestEnv = require("MediaKitTestEnv")

describe("MediaKit manifest metadata", function()
    after_each(TestEnv.Reset)

    it("matches runtime API and revision", function()
        local MediaKit = TestEnv.NewPackage()
        local file = assert(io.open("packages/mediaKit/package.manifest.json", "r"))
        local text = file:read("*a")
        file:close()

        local api = tonumber(text:match('"api"%s*:%s*(%d+)'))
        local revision = tonumber(text:match('"revision"%s*:%s*(%d+)'))

        assert.are.equal(MediaKit.API, api)
        assert.are.equal(MediaKit.REVISION, revision)
    end)

    it("declares Registry API 2 and SignalKit API 1 as its dependencies", function()
        local file = assert(io.open("packages/mediaKit/package.manifest.json", "r"))
        local text = file:read("*a")
        file:close()

        assert.is_truthy(text:find('"registry"%s*:%s*{%s*"api"%s*:%s*2%s*}'))
        assert.is_truthy(text:find('"signalKit"%s*:%s*{%s*"api"%s*:%s*1%s*}'))
        assert.is_truthy(text:find('"version"%s*:%s*"0%.1%.0"'))
        assert.is_truthy(text:find('"license"%s*:%s*"MIT"'))
    end)
end)
