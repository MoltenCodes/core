local TestEnv = require("TooltipKitTestEnv")

describe("TooltipKit manifest metadata", function()
  after_each(TestEnv.Reset)

  ---@return string
  local function readManifest()
    local file = assert(io.open("packages/tooltipKit/package.manifest.json", "r"))
    local text = file:read("*a")
    file:close()
    return text
  end

  it("matches runtime API and revision", function()
    local TooltipKit = TestEnv.NewPackage()
    local text = readManifest()
    assert.are.equal(TooltipKit.API, tonumber(text:match('"api"%s*:%s*(%d+)')))
    assert.are.equal(TooltipKit.REVISION, tonumber(text:match('"revision"%s*:%s*(%d+)')))
  end)

  it("declares Registry API 2 and PoolKit API 1 as its dependencies", function()
    local text = readManifest()
    assert.is_truthy(text:find('"registry"%s*:%s*{%s*"api"%s*:%s*2%s*}'))
    assert.is_truthy(text:find('"poolKit"%s*:%s*{%s*"api"%s*:%s*1%s*}'))
    assert.is_truthy(text:find('"version"%s*:%s*"%d+%.%d+%.%d+"'))
    assert.is_truthy(text:find('"license"%s*:%s*"MIT"'))
  end)
end)
