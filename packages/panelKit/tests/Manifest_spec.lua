local TestEnv = require("PanelKitTestEnv")

describe("PanelKit manifest metadata", function()
  after_each(TestEnv.Reset)

  ---@return string
  local function readManifest()
    local file = assert(io.open("packages/panelKit/package.manifest.json", "r"))
    local text = file:read("*a")
    file:close()
    return text
  end

  it("matches runtime API and revision", function()
    local PanelKit = TestEnv.NewPackage()
    local text = readManifest()
    assert.are.equal(PanelKit.API, tonumber(text:match('"api"%s*:%s*(%d+)')))
    assert.are.equal(PanelKit.REVISION, tonumber(text:match('"revision"%s*:%s*(%d+)')))
  end)

  it("declares Registry API 2, WidgetKit API 1 and OptionsKit API 1 as its dependencies", function()
    local text = readManifest()
    assert.is_truthy(text:find('"registry"%s*:%s*{%s*"api"%s*:%s*2%s*}'))
    assert.is_truthy(text:find('"widgetKit"%s*:%s*{%s*"api"%s*:%s*1%s*}'))
    assert.is_truthy(text:find('"optionsKit"%s*:%s*{%s*"api"%s*:%s*1%s*}'))
    assert.is_truthy(text:find('"version"%s*:%s*"0%.1%.1"'))
    assert.is_truthy(text:find('"license"%s*:%s*"MIT"'))
  end)
end)
