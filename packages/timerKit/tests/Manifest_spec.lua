local TestEnv = require("TimerKitTestEnv")

describe("TimerKit manifest metadata", function()
  after_each(TestEnv.Reset)

  it("matches runtime API and revision", function()
    local TimerKit = TestEnv.NewPackage()
    local file = assert(io.open("packages/timerKit/package.manifest.json", "r"))
    local text = file:read("*a")
    file:close()

    local api = tonumber(text:match('"api"%s*:%s*(%d+)'))
    local revision = tonumber(text:match('"revision"%s*:%s*(%d+)'))

    assert.are.equal(TimerKit.API, api)
    assert.are.equal(TimerKit.REVISION, revision)
  end)
end)
