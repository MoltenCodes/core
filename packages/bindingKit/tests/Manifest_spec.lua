local TestEnv = require("BindingKitTestEnv")

describe("BindingKit manifest metadata", function()
  after_each(TestEnv.Reset)

  ---@return string
  local function readManifest()
    local file = assert(io.open("packages/bindingKit/package.manifest.json", "r"))
    local text = file:read("*a")
    file:close()
    return text
  end

  it("matches runtime API and revision", function()
    local BindingKit = TestEnv.NewPackage()
    local text = readManifest()
    assert.are.equal(BindingKit.API, tonumber(text:match('"api"%s*:%s*(%d+)')))
    assert.are.equal(BindingKit.REVISION, tonumber(text:match('"revision"%s*:%s*(%d+)')))
  end)

  it("declares Registry API 2 as its only dependency", function()
    local text = readManifest()
    assert.is_truthy(
      text:find('"dependencies"%s*:%s*{%s*"registry"%s*:%s*{%s*"api"%s*:%s*2%s*}%s*}')
    )
    assert.is_truthy(text:find('"version"%s*:%s*"0%.1%.1"'))
    assert.is_truthy(text:find('"license"%s*:%s*"MIT"'))
  end)
end)
