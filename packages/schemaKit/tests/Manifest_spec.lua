local TestEnv = require("SchemaKitTestEnv")

describe("SchemaKit manifest metadata", function()
  after_each(TestEnv.Reset)

  it("matches runtime API and revision", function()
    local SchemaKit = TestEnv.NewPackage()
    local file = assert(io.open("packages/schemaKit/package.manifest.json", "r"))
    local text = file:read("*a")
    file:close()

    local api = tonumber(text:match('"api"%s*:%s*(%d+)'))
    local revision = tonumber(text:match('"revision"%s*:%s*(%d+)'))

    assert.are.equal(SchemaKit.API, api)
    assert.are.equal(SchemaKit.REVISION, revision)
  end)

  it("declares Registry API 2 as its only dependency", function()
    local file = assert(io.open("packages/schemaKit/package.manifest.json", "r"))
    local text = file:read("*a")
    file:close()

    local dependencies = text:match('"dependencies"%s*:%s*(%b{})')
    assert.is_not_nil(dependencies)
    assert.is_not_nil(dependencies:find('"registry"%s*:%s*{%s*"api"%s*:%s*2%s*}'))
    local _, names = dependencies:gsub('"%w+"%s*:%s*{', "")
    assert.are.equal(1, names)
    assert.is_nil(text:find('"optionalDependencies"', 1, true))
  end)
end)
