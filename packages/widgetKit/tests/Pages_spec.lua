local TestEnv = require("WidgetKitTestEnv")

describe("WidgetKit renderer pages", function()
  local WidgetKit, OptionsKit, window, store
  before_each(function()
    local _
    WidgetKit, _, _, _, _, OptionsKit = TestEnv.NewPackage()
    TestEnv.TakeReportedErrors()
    store = { volume = 1, hidePage = false }
    window = WidgetKit:Create("Frame")
  end)
  after_each(TestEnv.Reset)

  ---A toggle stored in `store[key]`.
  local function toggle(name, key, order)
    return {
      type = "toggle",
      name = name,
      order = order,
      get = function()
        return store[key]
      end,
      set = function(_, value)
        store[key] = value
      end,
    }
  end

  ---Define a tree whose root group `general` has `childGroups = layout`.
  local function define(layout, rootLayout, name)
    return OptionsKit:Define(name or "PagesSpec", {
      type = "group",
      childGroups = rootLayout,
      args = {
        general = {
          type = "group",
          name = "General",
          order = 1,
          childGroups = layout,
          args = {
            enabled = toggle("Enabled", "enabled", 1),
            box = {
              type = "group",
              name = "Box",
              inline = true,
              order = 2,
              args = { boxed = toggle("Boxed", "boxed", 1) },
            },
            sound = {
              type = "group",
              name = "Sound",
              order = 3,
              args = { mute = toggle("Mute", "mute", 1) },
            },
            look = {
              type = "group",
              name = "Look",
              order = 4,
              hidden = function()
                return store.hidePage
              end,
              args = { dark = toggle("Dark", "dark", 1) },
            },
            more = {
              type = "group",
              name = "More",
              order = 5,
              args = { extra = toggle("Extra", "extra", 1) },
            },
          },
        },
      },
    })
  end

  ---The types of `container`'s children, in order.
  local function childTypes(container)
    local types = {}
    for index, child in ipairs(container:GetChildren()) do
      types[index] = child:GetType()
    end
    return types
  end

  it("renders a group without childGroups as nested groups, as before", function()
    local rendering = WidgetKit:RenderOptions(define(nil), window)
    for _, path in ipairs({ "general.sound.mute", "general.look.dark", "general.more.extra" }) do
      assert.is_not_nil(rendering:GetWidget(path), path)
    end
  end)

  it("shows tab pages one at a time behind a row of buttons, the shown one disabled", function()
    local rendering = WidgetKit:RenderOptions(define("tab"), window)
    local general = rendering:GetWidget("general")
    -- Options and inline groups first, then the button row, then the page.
    assert.are.same({ "CheckBox", "Group", "Group", "Group" }, childTypes(general))
    local row = general:GetChildren()[3]
    assert.are.equal("Flow", row:GetLayoutName())
    local buttons = row:GetChildren()
    assert.are.same(
      { "Sound", "Look", "More" },
      { buttons[1]:GetText(), buttons[2]:GetText(), buttons[3]:GetText() }
    )
    assert.is_true(buttons[1]:GetFrame():IsEnabled() == false)
    assert.is_false(buttons[2]:GetFrame():IsEnabled() == false)
    assert.is_not_nil(rendering:GetWidget("general.sound.mute"))
    assert.is_nil(rendering:GetWidget("general.look.dark"))
    assert.is_not_nil(rendering:GetWidget("general.box.boxed"))

    buttons[3]:Fire("OnClick", "LeftButton")
    assert.is_nil(rendering:GetWidget("general.sound.mute"))
    assert.is_not_nil(rendering:GetWidget("general.more.extra"))
    local newButtons = rendering:GetWidget("general"):GetChildren()[3]:GetChildren()
    assert.is_true(newButtons[3]:GetFrame():IsEnabled() == false)
    assert.is_false(newButtons[1]:GetFrame():IsEnabled() == false)
    assert.are.same({}, TestEnv.TakeReportedErrors())
  end)

  it(
    "keeps the chosen page through refreshes and rebuilds, and falls back when it is hidden",
    function()
      local tree = define("tab")
      local rendering = WidgetKit:RenderOptions(tree, window)
      rendering:GetWidget("general"):GetChildren()[3]:GetChildren()[2]:Fire("OnClick", "LeftButton")
      assert.is_not_nil(rendering:GetWidget("general.look.dark"))
      tree:Set("general.enabled", true)
      assert.is_not_nil(rendering:GetWidget("general.look.dark"))
      rendering:Rebuild()
      assert.is_not_nil(rendering:GetWidget("general.look.dark"))
      store.hidePage = true
      rendering:Refresh()
      assert.is_nil(rendering:GetWidget("general.look.dark"))
      assert.is_not_nil(rendering:GetWidget("general.sound.mute"))
      local buttons = rendering:GetWidget("general"):GetChildren()[3]:GetChildren()
      assert.are.equal(2, #buttons)
    end
  )

  it("shows tree pages in a column of buttons beside the page", function()
    local rendering = WidgetKit:RenderOptions(define("tree"), window)
    local general = rendering:GetWidget("general")
    local row = general:GetChildren()[3]
    local list, page = row:GetChildren()[1], row:GetChildren()[2]
    assert.are.equal(0.3, list:GetRelativeWidth())
    assert.are.equal(0.7, page:GetRelativeWidth())
    assert.are.equal(3, list:GetNumChildren())
    assert.are.equal(rendering:GetWidget("general.sound"), page:GetChildren()[1])
    list:GetChildren()[2]:Fire("OnClick", "LeftButton")
    assert.is_not_nil(rendering:GetWidget("general.look.dark"))
  end)

  it("chooses select pages with a dropdown", function()
    local rendering = WidgetKit:RenderOptions(define("select"), window)
    local general = rendering:GetWidget("general")
    local dropdown = general:GetChildren()[3]
    assert.are.equal("Dropdown", dropdown:GetType())
    assert.are.equal(3, dropdown:GetNumEntries())
    assert.are.equal("general.sound", dropdown:GetValue())
    assert.is_true(dropdown:PickIndex(3))
    assert.is_not_nil(rendering:GetWidget("general.more.extra"))
    assert.are.equal("general.more", rendering:GetWidget("general"):GetChildren()[3]:GetValue())
  end)

  it("honours the hint on the root and on a page, one level at a time", function()
    local tree = OptionsKit:Define("Nested", {
      type = "group",
      childGroups = "tab",
      args = {
        first = {
          type = "group",
          name = "First",
          order = 1,
          childGroups = "select",
          args = {
            inner = { type = "group", name = "Inner", args = { a = toggle("A", "a", 1) } },
            other = { type = "group", name = "Other", args = { b = toggle("B", "b", 1) } },
          },
        },
        second = { type = "group", name = "Second", order = 2, args = { c = toggle("C", "c", 1) } },
      },
    })
    local rendering = WidgetKit:RenderOptions(tree, window)
    assert.are.same({ "Group", "Group" }, childTypes(window))
    assert.is_not_nil(rendering:GetWidget("first.inner.a"))
    assert.is_nil(rendering:GetWidget("first.other.b"))
    assert.is_nil(rendering:GetWidget("second.c"))
    rendering:GetWidget("first"):GetChildren()[1]:PickIndex(2)
    assert.is_not_nil(rendering:GetWidget("first.other.b"))
    window:GetChildren()[1]:GetChildren()[2]:Fire("OnClick", "LeftButton")
    assert.is_not_nil(rendering:GetWidget("second.c"))
    -- Back on the first page, its own choice is still the one made.
    window:GetChildren()[1]:GetChildren()[1]:Fire("OnClick", "LeftButton")
    assert.is_not_nil(rendering:GetWidget("first.other.b"))
  end)

  it("draws only the options when every child group is inline or hidden", function()
    store.hidePage = true
    local tree = OptionsKit:Define("NoPages", {
      type = "group",
      childGroups = "tab",
      args = {
        enabled = toggle("Enabled", "enabled", 1),
        box = {
          type = "group",
          name = "Box",
          inline = true,
          args = { boxed = toggle("Boxed", "boxed", 1) },
        },
      },
    })
    WidgetKit:RenderOptions(tree, window)
    assert.are.same({ "CheckBox", "Group" }, childTypes(window))
  end)

  it("gives a rendering made before the upgrade its page selection on its first rebuild", function()
    local rendering = WidgetKit:RenderOptions(define(nil), window)
    rawset(rendering, "_selected", nil)
    local upgraded = TestEnv.LoadRevision(WidgetKit.REVISION + 1)
    assert.are.equal(WidgetKit, upgraded)
    rendering:Rebuild()
    assert.is_nil(rawget(rendering, "_selected"))
    local paged =
      WidgetKit:RenderOptions(define("tab", nil, "PagesSpecPaged"), WidgetKit:Create("Frame"))
    rawset(paged, "_selected", nil)
    paged:Rebuild()
    assert.is_table(rawget(paged, "_selected"))
    assert.is_not_nil(paged:GetWidget("general.sound.mute"))
  end)
end)
