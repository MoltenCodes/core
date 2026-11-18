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

    -- The package's own contract comes before `parts`, which is written last.
    local packageText = text:sub(1, (text:find('"parts"', 1, true) or #text + 1) - 1)
    local dependencies = packageText:match('"dependencies"%s*:%s*(%b{})')
    assert.is_not_nil(dependencies)
    assert.is_not_nil(dependencies:find('"registry"%s*:%s*{%s*"api"%s*:%s*2%s*}'))
    local _, names = dependencies:gsub('"%w+"%s*:%s*{', "")
    assert.are.equal(1, names)
    assert.is_nil(packageText:find('"optionalDependencies"', 1, true))
  end)

  it(
    "declares the Rules and Apply parts at their files' revisions, needing nothing more",
    function()
      local file = assert(io.open("packages/schemaKit/package.manifest.json", "r"))
      local text = file:read("*a")
      file:close()

      local parts = text:match('"parts"%s*:%s*(%b{})')
      assert.is_not_nil(parts)
      for _, partName in ipairs({ "Rules", "Apply" }) do
        local entry = parts:match('"' .. partName .. '"%s*:%s*(%b{})')
        assert.is_not_nil(entry, partName)
        local revision = tonumber(entry:match('"revision"%s*:%s*(%d+)'))
        assert.is_not_nil(entry:find('"dependencies"%s*:%s*{%s*}'))
        assert.is_not_nil(entry:find('"optionalDependencies"%s*:%s*{%s*}'))

        local partFile =
          assert(io.open("packages/schemaKit/src/parts/SchemaKit-" .. partName .. ".lua", "r"))
        local source = partFile:read("*a")
        partFile:close()
        assert.are.equal(revision, tonumber(source:match("local PART_REVISION = (%d+)")))
      end
    end
  )
end)
