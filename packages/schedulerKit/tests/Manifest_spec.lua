local TestEnv = require("SchedulerKitTestEnv")

describe("SchedulerKit manifest", function()
    after_each(TestEnv.Reset)

    it("matches runtime API and revision metadata", function()
        local SchedulerKit = TestEnv.NewPackage()
        local file = assert(io.open("packages/schedulerKit/package.manifest.json", "r"))
        local text = file:read("*a")
        file:close()

        local api = tonumber(text:match('"api"%s*:%s*(%d+)'))
        local revision = tonumber(text:match('"revision"%s*:%s*(%d+)'))
        assert.are.equal(api, SchedulerKit.API)
        assert.are.equal(revision, SchedulerKit.REVISION)
    end)
end)
