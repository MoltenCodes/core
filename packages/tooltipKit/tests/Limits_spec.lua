local TestEnv = require("TooltipKitTestEnv")

describe("TooltipKit limits", function()
  local TooltipKit
  before_each(function()
    TooltipKit = TestEnv.NewPackage()
  end)
  after_each(TestEnv.Reset)

  it("reports the defaults and the constants in a fresh table", function()
    assert.are.same(
      { 16, 256, 16 },
      { TooltipKit.MAX_TOOLTIPS, TooltipKit.MAX_LINES, TooltipKit.MAX_COLUMNS }
    )
    assert.are.same(
      { 64, 1024, 32 },
      { TooltipKit.TOOLTIPS_CEILING, TooltipKit.LINES_CEILING, TooltipKit.COLUMNS_CEILING }
    )
    local limits = TooltipKit:GetLimits()
    assert.are.same({ maxTooltips = 16, maxLines = 256, maxColumns = 16 }, limits)
    assert.are_not.equal(limits, TooltipKit:GetLimits())
  end)

  it("refuses the tooltip past maxTooltips and frees a slot on Release", function()
    TooltipKit:SetLimits({ maxTooltips = 2 })
    local first = TooltipKit:Acquire("A", 1)
    TooltipKit:Acquire("B", 1)
    TestEnv.expectErrorContaining(
      "TooltipKit:Acquire holds at most 2 tooltips at once; release one, or raise maxTooltips",
      function()
        TooltipKit:Acquire("C", 1)
      end
    )
    assert.are.equal(first, TooltipKit:Acquire("A", 1))
    TooltipKit:Release(first)
    TooltipKit:Acquire("C", 1)
  end)

  it("refuses the line past maxLines", function()
    TooltipKit:SetLimits({ maxLines = 3 })
    local tooltip = TooltipKit:Acquire("A", 1)
    tooltip:AddLine("1")
    tooltip:AddSeparator()
    tooltip:AddHeader("3")
    TestEnv.expectErrorContaining(
      "TooltipKit.Tooltip:AddLine holds at most 3 lines; raise maxLines with TooltipKit:SetLimits",
      function()
        tooltip:AddLine("4")
      end
    )
    assert.are.equal(3, tooltip:GetLineCount())
  end)

  it("takes maxColumns at Acquire and raises the line pool's cap with the other two", function()
    TooltipKit:SetLimits({ maxColumns = 32 })
    TooltipKit:Acquire("Wide", 32)
    TooltipKit:SetLimits({ maxTooltips = 64, maxLines = 1024 })
    assert.are.equal(64 * 1024, TooltipKit._state.linePool:GetMaxCreated())
    TooltipKit:SetLimits({ maxLines = 1 })
    assert.are.equal(64 * 1024, TooltipKit._state.linePool:GetMaxCreated())
  end)

  it("refuses invalid limits without changing any", function()
    local cases = {
      { "limits must be a table", 1 },
      {
        "limits holds an unknown field; it accepts maxTooltips, maxLines and maxColumns",
        { maxCells = 1 },
      },
      { "limits.maxTooltips must be an integer from 1 to 64", { maxTooltips = 65 } },
      { "limits.maxLines must be an integer from 1 to 1024", { maxLines = 0 } },
      { "limits.maxColumns must be an integer from 1 to 32", { maxColumns = 1.5 } },
      {
        "limits.maxLines must be an integer from 1 to 1024",
        { maxTooltips = 2, maxLines = 0 / 0 },
      },
    }
    for _, case in ipairs(cases) do
      TestEnv.expectErrorContaining("TooltipKit:SetLimits " .. case[1], function()
        TooltipKit:SetLimits(case[2])
      end)
    end
    assert.are.same({ maxTooltips = 16, maxLines = 256, maxColumns = 16 }, TooltipKit:GetLimits())
  end)
end)
