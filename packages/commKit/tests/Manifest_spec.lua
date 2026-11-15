local TestEnv = require("CommKitTestEnv")

describe("CommKit manifest metadata", function()
  after_each(TestEnv.Reset)

  ---@return string
  local function readManifest()
    local file = assert(io.open("packages/commKit/package.manifest.json", "r"))
    local text = file:read("*a")
    file:close()
    return text
  end

  it("matches runtime API and revision", function()
    local CommKit = TestEnv.NewPackage()
    local text = readManifest()
    local api = tonumber(text:match('"api"%s*:%s*(%d+)'))
    local revision = tonumber(text:match('"revision"%s*:%s*(%d+)'))
    assert.are.equal(CommKit.API, api)
    assert.are.equal(CommKit.REVISION, revision)
  end)

  it("declares the five required and five optional dependencies", function()
    local text = readManifest()
    local required = text:match('"dependencies"%s*:%s*(%b{})')
    local optional = text:match('"optionalDependencies"%s*:%s*(%b{})')
    for _, name in ipairs({
      "registry",
      "signalKit",
      "eventKit",
      "timerKit",
      "poolKit",
    }) do
      assert.is_truthy(required:find('"' .. name .. '"', 1, true), name)
    end
    -- Addon shutdown reaches CommKit through `CloseAddonScopes`, called by
    -- LifecycleKit when it is loaded, so CommKit does not depend on it; it
    -- only finds it, to leave the logout close to it. SchedulerKit runs the
    -- send driver when it is loaded (revision 11) and TimerKit otherwise.
    for _, name in ipairs({ "schedulerKit", "codecKit", "hookKit", "schemaKit", "lifecycleKit" }) do
      assert.is_truthy(optional:find('"' .. name .. '"', 1, true), name)
      assert.is_nil(required:find('"' .. name .. '"', 1, true), name)
    end
    assert.is_true(text:find('"optionalDependencies"', 1, true) > text:find('"api"', 1, true))
  end)

  it("declares the two parts last, with the revisions their files carry", function()
    local text = readManifest()
    local partsAt = text:find('"parts"', 1, true)
    assert.is_truthy(partsAt)
    assert.is_true(partsAt > text:find('"optionalDependencies"', 1, true))
    for _, name in ipairs({ "SyncSet", "ChatThrottle" }) do
      local entry = text:match('"' .. name .. '"%s*:%s*(%b{})', partsAt)
      assert.is_truthy(entry, name)
      local revision = tonumber(entry:match('"revision"%s*:%s*(%d+)'))
      local file = assert(io.open("packages/commKit/src/parts/CommKit-" .. name .. ".lua", "r"))
      local source = file:read("*a")
      file:close()
      assert.are.equal(revision, tonumber(source:match("local PART_REVISION = (%d+)")), name)
    end
    local syncSet = text:match('"SyncSet"%s*:%s*(%b{})', partsAt)
    assert.is_truthy(syncSet:match('"dependencies"%s*:%s*(%b{})'):find('"codecKit"', 1, true))
  end)
end)
