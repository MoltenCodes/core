local TestEnv = require("SchedulerKitTestEnv")

---Read a whole file from the repository root.
---@param path string
---@return string
local function readFile(path)
  local file = assert(io.open(path, "r"))
  local text = file:read("*a")
  file:close()
  return text
end

describe("SchedulerKit manifest", function()
  after_each(TestEnv.Reset)

  it("matches runtime API and revision metadata", function()
    local SchedulerKit = TestEnv.NewPackage()
    local text = readFile("packages/schedulerKit/package.manifest.json")

    local api = tonumber(text:match('"api"%s*:%s*(%d+)'))
    local revision = tonumber(text:match('"revision"%s*:%s*(%d+)'))
    assert.are.equal(api, SchedulerKit.API)
    assert.are.equal(revision, SchedulerKit.REVISION)
  end)

  it("matches each part's revision in the manifest and in its file", function()
    local SchedulerKit = TestEnv.NewPackage()
    local text = readFile("packages/schedulerKit/package.manifest.json")
    local parts = rawget(SchedulerKit, "_state").parts
    for _, part in ipairs(TestEnv.PARTS) do
      local block = text:match('"' .. part .. '"%s*:%s*(%b{})')
      assert.is_string(block, part)
      assert.are.equal(parts[part].revision, tonumber(block:match('"revision"%s*:%s*(%d+)')))
      local source = readFile("packages/schedulerKit/src/parts/SchedulerKit-" .. part .. ".lua")
      assert.are.equal(parts[part].revision, tonumber(source:match("local PART_REVISION = (%d+)")))
    end
  end)
end)
