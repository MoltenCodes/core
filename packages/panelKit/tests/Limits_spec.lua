local TestEnv = require("PanelKitTestEnv")

describe("PanelKit limits", function()
  local PanelKit, settings
  before_each(function()
    PanelKit, settings = TestEnv.NewPackage()
  end)
  after_each(TestEnv.Reset)

  it("reports the defaults and the constants in a fresh table", function()
    assert.are.equal(64, PanelKit.MAX_PANELS)
    assert.are.equal(1024, PanelKit.PANELS_CEILING)
    local limits = PanelKit:GetLimits()
    assert.are.same({ maxPanels = 64 }, limits)
    assert.are_not.equal(limits, PanelKit:GetLimits())
  end)

  it("refuses the panel past maxPanels, subcategories counted, without registering it", function()
    PanelKit:SetLimits({ maxPanels = 2 })
    local parent = PanelKit:Register("First")
    PanelKit:Register("FirstChild", { parent = parent })
    TestEnv.expectErrorContaining(
      "PanelKit:Register holds at most 2 panels; raise maxPanels with PanelKit:SetLimits",
      function()
        PanelKit:Register("Second")
      end
    )
    assert.are.equal(2, #settings.categories)
    PanelKit:SetLimits({ maxPanels = 3 })
    PanelKit:Register("Second")
  end)

  it("keeps every panel when lowered below the count", function()
    PanelKit:Register("First")
    PanelKit:Register("Second")
    PanelKit:SetLimits({ maxPanels = 1 })
    assert.is_not_nil(PanelKit:Get("Second"))
    TestEnv.expectErrorContaining("holds at most 1 panels", function()
      PanelKit:Register("Third")
    end)
  end)

  it(
    "accepts the ceiling and refuses anything outside 1 to 1024 without changing the limit",
    function()
      PanelKit:SetLimits({ maxPanels = 1024 })
      assert.are.equal(1024, PanelKit:GetLimits().maxPanels)
      PanelKit:SetLimits({})
      assert.are.equal(1024, PanelKit:GetLimits().maxPanels)
      for _, value in ipairs({ 0, 1025, 1.5, -1, math.huge, 0 / 0, "8", true }) do
        TestEnv.expectErrorContaining(
          "limits.maxPanels must be an integer from 1 to 1024",
          function()
            PanelKit:SetLimits({ maxPanels = value })
          end
        )
      end
      TestEnv.expectErrorContaining(
        "limits holds an unknown field; it accepts maxPanels",
        function()
          PanelKit:SetLimits({ maxPanels = 8, maxPages = 8 })
        end
      )
      TestEnv.expectErrorContaining("PanelKit:SetLimits limits must be a table", function()
        PanelKit:SetLimits(8)
      end)
      assert.are.equal(1024, PanelKit:GetLimits().maxPanels)
    end
  )
end)
