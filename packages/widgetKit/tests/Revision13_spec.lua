local TestEnv = require("WidgetKitTestEnv")

-- Upgrades from revision 13, the last revision that was one file and kept its
-- widgets in PoolKit pools, to this core and its parts. The specs load the
-- fixture copy of that file (`tests/support/WidgetKitRevision13.lua`).

---Load the Kits revision 13 needs, then the fixture copy.
---@return table WidgetKit
local function loadRevision13()
  TestEnv.Reset()
  TestEnv.InstallWowApi()
  TestEnv.InstallClientRules()
  TestEnv.InstallScreen()
  -- Revision 13 creates its pools with a `generation`, which PoolKit serves
  -- from its Generations part since PoolKit 0.5.0.
  for _, name in ipairs({
    "Registry",
    "SignalKit",
    "PoolKit",
    "PoolKit-Generations",
    "SchemaKit",
    "OptionsKit",
  }) do
    require(name)
  end
  return TestEnv.LoadRevision13()
end

---A tree with one toggle, its value in `store.flag`.
---@param store table
---@return table tree
local function defineTree(store)
  return require("OptionsKit"):Define("SpecRevision13", {
    type = "group",
    args = {
      flag = {
        type = "toggle",
        name = "Flag",
        get = function()
          return store.flag
        end,
        set = function(_, value)
          store.flag = value
        end,
      },
    },
  })
end

---Every function still reachable from `_G` and the registry whose source is
---`path`.
---@param path string
---@return integer
local function reachableFunctionsOf(path)
  local seen = {}
  local count = 0
  local source = "@" .. path
  local function walk(value)
    local kind = type(value)
    if (kind ~= "table" and kind ~= "function") or seen[value] then
      return
    end
    seen[value] = true
    if kind == "function" then
      if debug.getinfo(value, "S").source == source then
        count = count + 1
      end
      local index = 1
      while true do
        local name, upvalue = debug.getupvalue(value, index)
        if name == nil then
          break
        end
        walk(upvalue)
        index = index + 1
      end
      return
    end
    walk(debug.getmetatable(value))
    for key, item in next, value do
      walk(key)
      walk(item)
    end
  end
  collectgarbage("collect")
  -- The walk starts at the global table: everything a session keeps alive is
  -- reachable from it or from the registry.
  -- selene: allow(global_usage)
  walk(_G)
  walk(debug.getregistry())
  return count
end

describe("WidgetKit upgrade from revision 13", function()
  after_each(TestEnv.Reset)

  it("adopts the PoolKit pools, live widgets, renderings and bindings", function()
    local old = loadRevision13()
    assert.are.equal(13, old.REVISION)
    local state = old._state
    local group = old:Create("Group") ---@cast group -nil
    local borrowed = old:Create("Label") ---@cast borrowed -nil
    borrowed:SetText("kept")
    group:AddChild(borrowed)
    local pooled = old:Create("Label") ---@cast pooled -nil
    old:Release(pooled)
    local store = { flag = false }
    local rendering = old:RenderOptions(defineTree(store), group)
    local window = old:Create("Frame") ---@cast window -nil
    local saved = {}
    local binding = window:BindPosition(saved)
    local labelsBuilt = state.types.Label.pool:GetCreatedCount()

    local upgraded = require("WidgetKit")
    TestEnv.LoadParts()
    assert.are.equal(old, upgraded)
    assert.are.equal(state, upgraded._state)
    assert.are.equal(14, upgraded.REVISION)
    for _, typeRecord in pairs(state.types) do
      assert.is_nil(typeRecord.pool)
      assert.is_true(typeRecord.trusted)
    end
    assert.is_nil(state.scratch)
    assert.are.equal(labelsBuilt, upgraded:GetStatistics().byType.Label.created)

    -- The idle widget is reused, the borrowed one keeps its record.
    assert.are.equal(pooled, upgraded:Create("Label"))
    assert.are.equal("kept", borrowed:GetText())
    -- The revision 13 rendering refreshes and writes through the new part.
    store.flag = true
    assert.is_true(rendering:Refresh())
    rendering:GetWidget("flag"):Fire("OnValueChanged", false)
    -- The revision 13 binding captures through the new part.
    window:SetPoint("CENTER", TestEnv.GetGlobal("UIParent"), "CENTER", 10, 20)
    binding:Capture()
    assert.are.equal("CENTER", saved.anchor.point)

    upgraded:Release(group)
    assert.is_true(rendering:IsReleased())
    -- Released, the borrowed revision 13 label joins the free list.
    assert.are.equal(borrowed, upgraded:Create("Label"))
    upgraded:Release(window)
  end)

  it("keeps revision 13's members for parts nobody loaded", function()
    local old = loadRevision13()
    local renderOptions = old.RenderOptions
    local fromRect = old.Anchor.FromRect
    local upgraded = require("WidgetKit")
    assert.are.equal(renderOptions, upgraded.RenderOptions)
    assert.are.equal(fromRect, upgraded.Anchor.FromRect)
    assert.is_nil(upgraded:GetPartRevision("Renderer"))
    -- Its types keep revision 13's constructors, now on free lists.
    local slider = upgraded:Create("Slider") ---@cast slider -nil
    slider:SetSliderValues(0, 10, 1)
    upgraded:Release(slider)
    assert.are.equal(slider, upgraded:Create("Slider"))
    local group = upgraded:Create("Group") ---@cast group -nil
    local rendering = upgraded:RenderOptions(defineTree({ flag = true }), group)
    assert.is_true(rendering:Refresh())
    upgraded:Release(group)
  end)

  it("yields to a newer core loaded first and names the parts it lacks", function()
    local WidgetKit = TestEnv.NewCore({ "Text" })
    require("SignalKit")
    require("PoolKit")
    local yielded = TestEnv.LoadRevision13()
    assert.are.equal(WidgetKit, yielded)
    assert.are.equal(14, WidgetKit.REVISION)
    assert.is_true(WidgetKit:IsWidget(WidgetKit:Create("Label")))
    TestEnv.expectErrorContaining("Slider part, which is not loaded", function()
      WidgetKit:Create("Slider")
    end)
  end)

  it("leaves none of revision 13's functions reachable once every part loaded", function()
    loadRevision13()
    require("WidgetKit")
    TestEnv.LoadParts()
    assert.are.equal(0, reachableFunctionsOf(TestEnv.REVISION_13_PATH))
  end)
end)
