local TestEnv = require("HookKitTestEnv")

describe("HookKit manifest metadata", function()
  after_each(TestEnv.Reset)

  it("matches runtime API and revision", function()
    local HookKit = TestEnv.NewPackage()
    local file = assert(io.open("packages/hookKit/package.manifest.json", "r"))
    local text = file:read("*a")
    file:close()

    local api = tonumber(text:match('"api"%s*:%s*(%d+)'))
    local revision = tonumber(text:match('"revision"%s*:%s*(%d+)'))

    assert.are.equal(HookKit.API, api)
    assert.are.equal(HookKit.REVISION, revision)
  end)
end)
