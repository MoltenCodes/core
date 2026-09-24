local TestEnv = require("OptionsKitTestEnv")

describe("OptionsKit manifest metadata", function()
  after_each(TestEnv.Reset)

  it("matches runtime API and revision", function()
    local OptionsKit = TestEnv.NewPackage()
    local file = assert(io.open("packages/optionsKit/package.manifest.json", "r"))
    local text = file:read("*a")
    file:close()

    local api = tonumber(text:match('"api"%s*:%s*(%d+)'))
    local revision = tonumber(text:match('"revision"%s*:%s*(%d+)'))

    assert.are.equal(OptionsKit.API, api)
    assert.are.equal(OptionsKit.REVISION, revision)
  end)
end)
