local TestEnv = require("ReadinessKitTestEnv")

describe("ReadinessKit manifest metadata", function()
  after_each(TestEnv.Reset)

  it("matches runtime API and revision", function()
    local ReadinessKit = TestEnv.NewPackage()
    local file = assert(io.open("packages/readinessKit/package.manifest.json", "r"))
    local text = file:read("*a")
    file:close()

    local api = tonumber(text:match('"api"%s*:%s*(%d+)'))
    local revision = tonumber(text:match('"revision"%s*:%s*(%d+)'))

    assert.are.equal(ReadinessKit.API, api)
    assert.are.equal(ReadinessKit.REVISION, revision)
  end)
end)
