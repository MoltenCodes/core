local TestEnv = require("WidgetKitTestEnv")

describe("WidgetKit manifest metadata", function()
  after_each(TestEnv.Reset)

  it("matches runtime API and revision", function()
    local WidgetKit = TestEnv.NewPackage()
    local file = assert(io.open("packages/widgetKit/package.manifest.json", "r"))
    local text = file:read("*a")
    file:close()

    local api = tonumber(text:match('"api"%s*:%s*(%d+)'))
    local revision = tonumber(text:match('"revision"%s*:%s*(%d+)'))

    assert.are.equal(WidgetKit.API, api)
    assert.are.equal(WidgetKit.REVISION, revision)
  end)

  it("declares its optional dependencies after the top-level api field", function()
    local file = assert(io.open("packages/widgetKit/package.manifest.json", "r"))
    local text = file:read("*a")
    file:close()

    local apiPosition = text:find('"api"', 1, true)
    local optionalPosition = text:find('"optionalDependencies"', 1, true)
    assert.is_true(apiPosition < optionalPosition)
    for _, name in ipairs({ "optionsKit", "settingsKit", "schedulerKit", "mediaKit" }) do
      assert.is_true(text:find('"' .. name .. '"', optionalPosition, true) ~= nil)
    end
  end)
end)
