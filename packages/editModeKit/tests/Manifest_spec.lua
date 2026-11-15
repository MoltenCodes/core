local TestEnv = require("EditModeKitTestEnv")

describe("EditModeKit manifest metadata", function()
  after_each(TestEnv.Reset)

  ---@return string
  local function readManifest()
    local file = assert(io.open("packages/editModeKit/package.manifest.json", "r"))
    local text = file:read("*a")
    file:close()
    return text
  end

  it("matches runtime API and revision", function()
    local EditModeKit = TestEnv.NewPackage()
    local text = readManifest()
    assert.are.equal(EditModeKit.API, tonumber(text:match('"api"%s*:%s*(%d+)')))
    assert.are.equal(EditModeKit.REVISION, tonumber(text:match('"revision"%s*:%s*(%d+)')))
  end)

  it("declares Registry API 2 as its only dependency", function()
    local text = readManifest()
    assert.is_truthy(
      text:find('"dependencies"%s*:%s*{%s*"registry"%s*:%s*{%s*"api"%s*:%s*2%s*}%s*}')
    )
    assert.is_truthy(text:find('"version"%s*:%s*"%d+%.%d+%.%d+"'))
    assert.is_truthy(text:find('"license"%s*:%s*"MIT"'))
  end)
end)
