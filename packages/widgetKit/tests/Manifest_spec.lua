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

  it("declares the parts' dependencies after the top-level api field", function()
    local file = assert(io.open("packages/widgetKit/package.manifest.json", "r"))
    local text = file:read("*a")
    file:close()

    local apiPosition = text:find('"api"', 1, true)
    local optionalPosition = text:find('"optionalDependencies"', 1, true)
    assert.is_true(apiPosition < optionalPosition)
    for _, name in ipairs({ "optionsKit", "settingsKit", "schedulerKit", "mediaKit", "signalKit" }) do
      assert.is_true(text:find('"' .. name .. '"', optionalPosition, true) ~= nil)
    end
  end)

  it("requires Registry alone for the core", function()
    local file = assert(io.open("packages/widgetKit/package.manifest.json", "r"))
    local text = file:read("*a")
    file:close()
    local dependencies = text:match('"dependencies"%s*:%s*(%b{})')
    assert.are.equal('{\n    "registry": {\n      "api": 2\n    }\n  }', dependencies)
  end)

  it("gives every part file the revision its manifest entry declares", function()
    local file = assert(io.open("packages/widgetKit/package.manifest.json", "r"))
    local text = file:read("*a")
    file:close()
    local partsBlock = text:match('"parts"%s*:%s*(%b{})%s*}%s*$')
    assert.is_not_nil(partsBlock)
    local WidgetKit = TestEnv.NewPackage()
    for index = 1, #TestEnv.PARTS do
      local name = TestEnv.PARTS[index]
      local entry = partsBlock:match('"' .. name .. '"%s*:%s*(%b{})')
      local revision = tonumber(entry:match('"revision"%s*:%s*(%d+)'))
      local source =
        assert(io.open("packages/widgetKit/src/parts/WidgetKit-" .. name .. ".lua", "r"))
      local partText = source:read("*a")
      source:close()
      assert.are.equal(revision, tonumber(partText:match("local PART_REVISION = (%d+)")))
      assert.are.equal(revision, WidgetKit:GetPartRevision(name))
    end
  end)
end)
