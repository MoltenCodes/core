local TestEnv = require("TooltipKitTestEnv")

describe("TooltipKit pools", function()
  local TooltipKit
  before_each(function()
    TooltipKit = TestEnv.NewPackage()
  end)
  after_each(TestEnv.Reset)

  local function pools()
    return TooltipKit._state.tooltipPool, TooltipKit._state.linePool
  end

  it("gives the tooltip and every line back on Release, and reuses them cleared", function()
    local tooltip = TooltipKit:Acquire("MyAddon", 2)
    local first = tooltip:AddLine("left", "right")
    tooltip:SetLineColor(first, 1, 0, 0)
    tooltip:SetCellTextColor(first, 1, 0, 1, 0)
    tooltip:SetLineScript(first, "OnMouseUp", function() end)
    tooltip:AddLine("second")
    tooltip:SetAutoHideDelay(1)
    tooltip:SetMaxHeight(30)
    tooltip:SmartAnchorTo(TestEnv.FrameAt(10, 10))
    tooltip:Show()
    local frame = tooltip:GetFrame()
    local lineFrame = TooltipKit._state.records[tooltip].lines[1].frame
    local tooltipPool, linePool = pools()
    assert.are.equal(1, tooltipPool:GetActiveCount())
    assert.are.equal(2, linePool:GetActiveCount())

    TooltipKit:Release(tooltip)
    assert.is_false(TooltipKit:IsAcquired("MyAddon"))
    assert.are.equal(0, tooltipPool:GetActiveCount())
    assert.are.equal(0, linePool:GetActiveCount())
    assert.are.equal(2, linePool:GetAvailableCount())
    assert.is_false(frame:IsShown())
    assert.is_nil(frame:GetScript("OnUpdate"))
    assert.are.equal(0, frame:GetNumPoints())
    assert.is_nil(lineFrame.cells[1]:GetText())
    assert.are.same({ 1, 1, 1, 1 }, { lineFrame.cells[1]:GetTextColor() })
    assert.are.equal(0, lineFrame.background.colorAlpha)
    assert.is_nil(lineFrame:GetScript("OnMouseUp"))
    assert.is_false(lineFrame:IsMouseEnabled())

    local again = TooltipKit:Acquire("Other", 1)
    assert.are.equal(frame, again:GetFrame())
    assert.are_not.equal(tooltip, again)
    again:AddLine("fresh")
    assert.are.equal(1, tooltipPool:GetCreatedCount())
    assert.are.equal(2, linePool:GetCreatedCount())
    assert.are.equal(0, TooltipKit._state.records[again].maxHeight and 1 or 0)
  end)

  it("refuses a released tooltip's handle everywhere", function()
    local tooltip = TooltipKit:Acquire("MyAddon", 1)
    TooltipKit:Release(tooltip)
    TestEnv.expectErrorContaining("must be called on an acquired TooltipKit tooltip", function()
      tooltip:AddLine("late")
    end)
    TestEnv.expectErrorContaining(
      "TooltipKit:Release tooltip must be an acquired TooltipKit tooltip",
      function()
        TooltipKit:Release(tooltip)
      end
    )
  end)

  it("keeps every released frame, so the client's frame count stops growing", function()
    for _ = 1, 5 do
      local tooltip = TooltipKit:Acquire("MyAddon", 1)
      for index = 1, 10 do
        tooltip:AddLine(index)
      end
      TooltipKit:Release(tooltip)
    end
    local tooltipPool, linePool = pools()
    assert.are.equal(1, tooltipPool:GetCreatedCount())
    assert.are.equal(10, linePool:GetCreatedCount())
    assert.are.equal(0, linePool:GetDiscardedCount())
  end)
end)
