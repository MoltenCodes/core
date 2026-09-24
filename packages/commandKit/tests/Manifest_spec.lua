local TestEnv = require("CommandKitTestEnv")

describe("CommandKit manifest metadata", function()
  after_each(TestEnv.Reset)

  it("matches runtime API and revision", function()
    local CommandKit = TestEnv.NewPackage()
    local file = assert(io.open("packages/commandKit/package.manifest.json", "r"))
    local text = file:read("*a")
    file:close()

    local api = tonumber(text:match('"api"%s*:%s*(%d+)'))
    local revision = tonumber(text:match('"revision"%s*:%s*(%d+)'))

    assert.are.equal(CommandKit.API, api)
    assert.are.equal(CommandKit.REVISION, revision)
  end)
end)
