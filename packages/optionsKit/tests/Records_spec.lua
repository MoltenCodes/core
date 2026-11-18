local TestEnv = require("OptionsKitTestEnv")

---Count the fields of a table.
---@param record table
---@return integer
local function countFields(record)
  local count = 0
  for _ in next, record do
    count = count + 1
  end
  return count
end

local function getter()
  return true
end

local function setter() end

---A tree of `count` toggles, each with a name, a description, a getter and a
---setter, under one group.
---@param count integer
---@return table spec
local function toggleTree(count)
  local args = {}
  for index = 1, count do
    args["option" .. index] = {
      type = "toggle",
      name = "Option " .. index,
      desc = "Toggles " .. index,
      get = getter,
      set = setter,
    }
  end
  return { type = "group", args = { general = { type = "group", name = "General", args = args } } }
end

describe("OptionsKit records", function()
  local OptionsKit
  before_each(function()
    OptionsKit = TestEnv.NewPackage()
  end)
  after_each(TestEnv.Reset)

  it("keeps the common option to 8 fields, deriving key, depth and bind text", function()
    local tree = OptionsKit:Define("Addon", toggleTree(1))
    local record = rawget(rawget(tree, "_records"), "general.option1")
    -- kind, path, parent, name, get, set, schema and hints; the description
    -- and an `order` live in the hints.
    assert.are.equal(8, countFields(record))
    assert.is_nil(rawget(record, "_key"))
    assert.is_nil(rawget(record, "_depth"))
    assert.is_nil(rawget(record, "_order"))
    assert.is_nil(rawget(record, "_desc"))
    assert.are.equal("Toggles 1", rawget(record, "_hints").desc)
    local ordered = OptionsKit:Define("Ordered", {
      type = "group",
      args = { pick = { type = "toggle", name = "Pick", order = 2, get = getter, set = setter } },
    })
    local orderedRecord = rawget(rawget(ordered, "_records"), "pick")
    assert.are.equal(2, rawget(orderedRecord, "_hints").order)
    assert.is_true(countFields(orderedRecord) <= 8)

    local visited = {}
    tree:Walk(function(path, _, depth)
      visited[path] = depth
    end)
    assert.are.same({ general = 1, ["general.option1"] = 2 }, visited)

    local node = tree:DescribeOption("general.option1")
    assert.are.equal("option1", node.key)
    assert.are.equal(2, node.depth)
    assert.are.equal(100, node.order)
    assert.are.equal("Toggles 1", node.desc)
    assert.is_nil(tree:DescribeOption("").key)
    assert.are.equal(0, tree:DescribeOption("").depth)
  end)

  it("allocates well under the 1 200 B per option revision 12 did #allocation", function()
    local spec = toggleTree(200)
    local small = toggleTree(1)
    OptionsKit:Define("Warm", spec)
    local smallBytes = TestEnv.AllocatedKilobytes(function()
      OptionsKit:Define("Small", small)
    end) * 1024
    local largeBytes = TestEnv.AllocatedKilobytes(function()
      OptionsKit:Define("Large", spec)
    end) * 1024
    -- Revision 12 allocated about 1 200 B per option here (a 16-slot record
    -- and every error label built on success); revision 13 about 620 B (an
    -- 8-slot record and a small hints table for the description).
    local perOption = (largeBytes - smallBytes) / 199
    assert.is_true(perOption < 700, "one option allocated " .. perOption .. " B")
  end)

  it("names the whole path in a Define failure, built only then", function()
    TestEnv.expectErrorContaining(
      "OptionsKit:Define tree.args.general.args.option1.desc must be a string or a function",
      function()
        local spec = toggleTree(1)
        spec.args.general.args.option1.desc = 5
        OptionsKit:Define("Broken", spec)
      end
    )
  end)

  it("keeps the bind text it was given, in Describe and in a failure", function()
    TestEnv.InstallWowApi()
    local SettingsKit = TestEnv.RequireSettingsKit()
    local S = require("SchemaKit")
    local db = SettingsKit:Open("RecordsDB", {
      profile = S.table({
        fields = {
          frame = S.optional(S.table({ fields = { scale = S.optional(S.number(), 1) } }), {}),
        },
      }),
    })
    local tree = OptionsKit:Define("Bound", {
      type = "group",
      args = {
        scale = { type = "range", name = "Scale", min = 0, max = 2, bind = "profile.frame.scale" },
      },
    }, { db = db })
    local record = rawget(rawget(tree, "_records"), "scale")
    assert.is_nil(rawget(record, "_bind"))
    assert.is_nil(rawget(record, "_bindCount"))
    assert.are.equal("profile.frame.scale", tree:DescribeOption("scale").bind)
    assert.are.equal(1, tree:Get("scale"))
    assert.is_true(tree:Set("scale", 1.5))
    assert.are.equal(1.5, db.profile.frame.scale)
  end)

  it("upgrades a revision 12 tree whose records hold the fields now derived", function()
    TestEnv.Reset()
    TestEnv.InstallWowApi()
    require("Registry")
    require("SignalKit")
    require("SchemaKit")
    local previous = TestEnv.LoadRevision(12)
    local tree = previous:Define("Old", toggleTree(2))
    -- Lay revision 12's record fields over the records the working file built.
    local NO_HINTS = {}
    for path, record in next, rawget(tree, "_records") do
      local key = path:match("[^.]+$")
      local depth = select(2, path:gsub("%.", "")) + 1
      rawset(record, "_key", key)
      rawset(record, "_depth", depth)
      local hints = rawget(record, "_hints")
      rawset(record, "_order", 100 + depth)
      rawset(record, "_desc", hints and hints.desc)
      rawset(record, "_hints", NO_HINTS)
    end
    local root = rawget(tree, "_root")
    rawset(root, "_key", false)
    rawset(root, "_depth", 0)

    local upgraded = require("OptionsKit")
    assert.are.equal(previous, upgraded)
    assert.is_true(upgraded.REVISION > 12)
    local visited = {}
    tree:Walk(function(path, _, depth)
      visited[#visited + 1] = path .. "=" .. depth
    end)
    assert.are.same({ "general=1", "general.option1=2", "general.option2=2" }, visited)
    local described = tree:DescribeOption("general.option2")
    assert.are.equal("option2", described.key)
    assert.are.equal("Toggles 2", described.desc)
    assert.are.equal(102, described.order)
    assert.is_true(tree:Set("general.option1", false))
  end)
end)
