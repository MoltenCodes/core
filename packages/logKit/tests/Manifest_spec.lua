local Env = require("LogKitTestEnv")

local MANIFEST_PATH = "packages/logKit/package.manifest.json"

---Read the manifest file.
---@return string
local function readManifest()
  local file = assert(io.open(MANIFEST_PATH, "r"))
  local contents = file:read("*a")
  file:close()
  return contents
end

describe("LogKit manifest", function()
  before_each(function()
    Env.Reset()
  end)
  after_each(function()
    Env.Reset()
  end)

  it("matches runtime API and revision metadata", function()
    local LogKit = Env.NewPackage()
    local contents = readManifest()
    assert.are.equal(LogKit.API, tonumber(contents:match('"api"%s*:%s*(%d+)')))
    assert.are.equal(LogKit.REVISION, tonumber(contents:match('"revision"%s*:%s*(%d+)')))
  end)

  it("declares the Registry API 2 and SignalKit API 1 dependencies only", function()
    local contents = readManifest()
    local dependencies = contents:match('"dependencies"%s*:%s*(%b{})')
    assert.is_not_nil(dependencies)
    assert.is_not_nil(dependencies:match('"registry"%s*:%s*{%s*"api"%s*:%s*2%s*}'))
    assert.is_not_nil(dependencies:match('"signalKit"%s*:%s*{%s*"api"%s*:%s*1%s*}'))
    local _, dependencyCount = dependencies:gsub('"%w+"%s*:%s*{', "")
    assert.are.equal(2, dependencyCount)
  end)

  it("declares CommandKit and SettingsKit API 1 as optional dependencies", function()
    local contents = readManifest()
    local optional = contents:match('"optionalDependencies"%s*:%s*(%b{})')
    assert.is_not_nil(optional)
    assert.is_not_nil(optional:match('"commandKit"%s*:%s*{%s*"api"%s*:%s*1%s*}'))
    assert.is_not_nil(optional:match('"settingsKit"%s*:%s*{%s*"api"%s*:%s*1%s*}'))
    local _, optionalCount = optional:gsub('"%w+"%s*:%s*{', "")
    assert.are.equal(2, optionalCount)
  end)
end)
