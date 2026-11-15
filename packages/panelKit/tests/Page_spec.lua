local TestEnv = require("PanelKitTestEnv")

describe("PanelKit pages", function()
  local PanelKit, settings, WidgetKit, OptionsKit
  before_each(function()
    PanelKit, settings, WidgetKit, OptionsKit = TestEnv.NewPackage()
    TestEnv.InstallHostErrorHandler()
  end)
  after_each(TestEnv.Reset)

  ---The values the host error handler received since the last call.
  ---@return any[]
  local function takeReported()
    local values = {}
    for index, entry in ipairs(TestEnv.TakeReportedErrors()) do
      values[index] = entry.value
    end
    return values
  end

  ---Widgets acquired from WidgetKit right now, every type together.
  local function activeWidgets()
    return WidgetKit:GetStatistics().active
  end

  it("draws nothing until the page is shown", function()
    TestEnv.DefineTree(OptionsKit, "MyAddon")
    local panel = PanelKit:Register("MyAddon")
    assert.are.equal(0, activeWidgets())
    assert.is_nil(panel:GetRendering())
  end)

  it("renders the tree into a scroll frame on the canvas when Blizzard shows the page", function()
    TestEnv.DefineTree(OptionsKit, "MyAddon")
    local panel = PanelKit:Register("MyAddon")
    assert.are.same({ true }, { panel:Open() })
    assert.are.same({ panel:GetCategoryID() }, settings.opened)

    local rendering = panel:GetRendering()
    assert.is_not_nil(rendering)
    local toggle = rendering:GetWidget("enabled")
    assert.are.equal("CheckBox", toggle:GetType())
    assert.are.equal("Slider", rendering:GetWidget("scale"):GetType())

    local scroll = toggle:GetParentContainer()
    assert.are.equal("ScrollFrame", scroll:GetType())
    local canvas = settings.Shown().frame
    assert.are.equal(canvas, scroll:GetFrame():GetParent())
    assert.are.same({ "TOPLEFT", canvas, "TOPLEFT", 8, -8 }, { scroll:GetPoint(1) })
    assert.are.same({ "BOTTOMRIGHT", canvas, "BOTTOMRIGHT", -8, 8 }, { scroll:GetPoint(2) })
  end)

  it(
    "gives every widget back to its pool when the page is hidden, and draws again on the next show",
    function()
      TestEnv.DefineTree(OptionsKit, "MyAddon")
      local panel = PanelKit:Register("MyAddon")
      local other = PanelKit:Register("Other")

      panel:Open()
      local drawn = activeWidgets()
      assert.is_true(drawn > 0)
      other:Open()
      assert.is_nil(panel:GetRendering())
      settings.Close()
      assert.are.equal(0, activeWidgets())

      panel:Open()
      assert.are.equal(drawn, activeWidgets())
      settings.Close()
      assert.are.equal(0, activeWidgets())
      assert.are.equal(0, WidgetKit:GetStatistics().discarded)
    end
  )

  it("writes through the rendered widgets into the tree", function()
    local _, values = TestEnv.DefineTree(OptionsKit, "MyAddon")
    local panel = PanelKit:Register("MyAddon")
    panel:Open()
    panel:GetRendering():GetWidget("enabled"):Fire("OnValueChanged", false)
    assert.is_false(values.enabled)
  end)

  it("shows one line while no tree has the name, and the tree once it is defined", function()
    local panel = PanelKit:Register("MyAddon")
    panel:Open()
    assert.is_nil(panel:GetRendering())
    assert.are.equal(2, activeWidgets())

    TestEnv.DefineTree(OptionsKit, "MyAddon")
    settings.Refresh()
    assert.is_not_nil(panel:GetRendering())
    settings.Close()
    assert.are.equal(0, activeWidgets())
  end)

  it("refreshes values on Blizzard's OnRefresh and draws a redefined tree again", function()
    local tree, values = TestEnv.DefineTree(OptionsKit, "MyAddon")
    local panel = PanelKit:Register("MyAddon")
    panel:Open()
    local rendering = panel:GetRendering()
    values.enabled = false
    settings.Refresh()
    assert.are.equal(rendering, panel:GetRendering())
    assert.is_false(rendering:GetWidget("enabled"):GetValue())

    assert.is_true(OptionsKit:Undefine("MyAddon"))
    local replaced = TestEnv.DefineTree(OptionsKit, "MyAddon")
    assert.are_not.equal(tree, replaced)
    settings.Refresh()
    assert.are_not.equal(rendering, panel:GetRendering())
    assert.is_true(rendering:IsReleased())

    OptionsKit:Undefine("MyAddon")
    settings.Refresh()
    assert.is_nil(panel:GetRendering())
  end)

  it("ignores OnRefresh while the page is hidden", function()
    TestEnv.DefineTree(OptionsKit, "MyAddon")
    local panel = PanelKit:Register("MyAddon")
    panel:GetCategoryID()
    local canvas = settings.categories[1].frame
    canvas:OnRefresh()
    canvas:OnDefault()
    assert.are.equal(0, activeWidgets())
  end)

  it("keeps the rendering through the refresh Blizzard sends right after the show", function()
    local _, values = TestEnv.DefineTree(OptionsKit, "MyAddon")
    local panel = PanelKit:Register("MyAddon")
    local frame = settings.categories[1].frame
    local refreshes = 0
    local refresh = frame.OnRefresh
    frame.OnRefresh = function(canvas)
      refreshes = refreshes + 1
      refresh(canvas)
    end
    values.enabled = false
    panel:Open()
    assert.are.equal(1, refreshes)
    local drawn = activeWidgets()
    local rendering = panel:GetRendering()
    settings.Refresh()
    assert.are.equal(rendering, panel:GetRendering())
    assert.are.equal(drawn, activeWidgets())
    assert.is_false(rendering:GetWidget("enabled"):GetValue())
  end)

  it("runs the default handler of a hidden page when every setting is reset", function()
    TestEnv.DefineTree(OptionsKit, "MyAddon")
    local panel = PanelKit:Register("MyAddon")
    local other = PanelKit:Register("Other")
    local calls = {}
    panel:SetDefaultHandler(function(received)
      calls[#calls + 1] = received
    end)
    other:Open()
    settings.DefaultAll()
    assert.are.same({ panel }, calls)
    assert.is_nil(panel:GetRendering())
  end)

  it("runs the default handler on the Defaults button, then refreshes", function()
    local _, values = TestEnv.DefineTree(OptionsKit, "MyAddon")
    local panel = PanelKit:Register("MyAddon")
    local calls = {}
    panel:SetDefaultHandler(function(received)
      calls[#calls + 1] = received
      values.enabled = false
    end)
    panel:Open()
    settings.Default()
    assert.are.same({ panel }, calls)
    assert.is_false(panel:GetRendering():GetWidget("enabled"):GetValue())

    panel:SetDefaultHandler(nil)
    settings.Default()
    assert.are.equal(1, #calls)
  end)

  it("reports a raising default handler and keeps the page", function()
    TestEnv.DefineTree(OptionsKit, "MyAddon")
    local panel = PanelKit:Register("MyAddon")
    panel:SetDefaultHandler(function()
      error("handler failed", 0)
    end)
    panel:Open()
    settings.Default()
    assert.are.same({ "handler failed" }, takeReported())
    assert.is_not_nil(panel:GetRendering())
  end)

  it("reports a tree that fails to render and leaves the page empty", function()
    OptionsKit:Define("MyAddon", {
      type = "group",
      args = {
        broken = {
          type = "toggle",
          name = "Broken",
          hidden = function()
            error("hidden failed", 0)
          end,
          get = function()
            return true
          end,
          set = function() end,
        },
      },
    })
    local panel = PanelKit:Register("MyAddon")
    panel:Open()
    local reported = takeReported()
    assert.are.equal(1, #reported)
    assert.is_truthy(tostring(reported[1]):find("hidden failed", 1, true))
    assert.is_nil(panel:GetRendering())
    settings.Close()
    assert.are.equal(0, activeWidgets())
  end)

  it("reports a scroll frame it cannot acquire and draws nothing", function()
    TestEnv.DefineTree(OptionsKit, "MyAddon")
    local panel = PanelKit:Register("MyAddon")
    local create = WidgetKit.Create
    rawset(WidgetKit, "Create", function()
      return nil, "exhausted"
    end)
    panel:Open()
    rawset(WidgetKit, "Create", create)
    assert.are.same(
      { "PanelKit could not draw the page MyAddon: no ScrollFrame is free" },
      takeReported()
    )
    assert.is_nil(panel:GetRendering())
    settings.Close()
    panel:Open()
    assert.is_not_nil(panel:GetRendering())
  end)

  it("reports a message line it cannot acquire and keeps the empty page", function()
    local panel = PanelKit:Register("MyAddon")
    local create = WidgetKit.Create
    rawset(WidgetKit, "Create", function(self, typeName)
      if typeName == "Label" then
        return nil, "exhausted"
      end
      return create(self, typeName)
    end)
    panel:Open()
    rawset(WidgetKit, "Create", create)
    assert.are.same(
      { "PanelKit could not draw the page MyAddon: no Label is free" },
      takeReported()
    )
    assert.are.equal(1, activeWidgets())
    settings.Close()
    assert.are.equal(0, activeWidgets())
  end)

  it("draws a subcategory's own tree", function()
    TestEnv.DefineTree(OptionsKit, "MyAddon")
    TestEnv.DefineTree(OptionsKit, "MyAddonExtra")
    local parent = PanelKit:Register("MyAddon")
    local child = PanelKit:Register("MyAddonExtra", { name = "Extra", parent = parent })
    child:Open()
    assert.is_nil(parent:GetRendering())
    assert.is_not_nil(child:GetRendering())
  end)

  it("answers unavailable from Open when the client cannot open its panel", function()
    local panel = PanelKit:Register("MyAddon")
    settings.OpenToCategory = nil
    assert.are.same({ nil, "unavailable" }, { panel:Open() })
    TestEnv.SetGlobal("Settings", nil)
    assert.are.same({ nil, "unavailable" }, { panel:Open() })
  end)

  it("checks SetDefaultHandler's callback", function()
    local panel = PanelKit:Register("MyAddon")
    TestEnv.expectErrorContaining(
      "PanelKit.Panel:SetDefaultHandler callback must be a function or nil",
      function()
        panel:SetDefaultHandler("reset")
      end
    )
  end)
end)
