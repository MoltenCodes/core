local TestEnv = require("SettingsKitTestEnv")

describe("SettingsKit manifest metadata", function()
    after_each(TestEnv.Reset)

    it("matches runtime API and revision", function()
        local SettingsKit = TestEnv.NewPackage()
        local file = assert(io.open("packages/settingsKit/package.manifest.json", "r"))
        local text = file:read("*a")
        file:close()

        local api = tonumber(text:match('"api"%s*:%s*(%d+)'))
        local revision = tonumber(text:match('"revision"%s*:%s*(%d+)'))

        assert.are.equal(SettingsKit.API, api)
        assert.are.equal(SettingsKit.REVISION, revision)
    end)
end)
