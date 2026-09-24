local TestEnv = require("LocaleKitTestEnv")

describe("LocaleKit manifest metadata", function()
  after_each(TestEnv.Reset)

  it("matches runtime API and revision", function()
    local LocaleKit = TestEnv.NewPackage()
    local file = assert(io.open("packages/localeKit/package.manifest.json", "r"))
    local text = file:read("*a")
    file:close()

    local api = tonumber(text:match('"api"%s*:%s*(%d+)'))
    local revision = tonumber(text:match('"revision"%s*:%s*(%d+)'))

    assert.are.equal(LocaleKit.API, api)
    assert.are.equal(LocaleKit.REVISION, revision)
  end)
end)
