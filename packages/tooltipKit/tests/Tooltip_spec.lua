local TestEnv = require("TooltipKitTestEnv")

describe("TooltipKit tooltips", function()
  local TooltipKit
  before_each(function()
    TooltipKit = TestEnv.NewPackage()
    TestEnv.InstallHostErrorHandler()
  end)
  after_each(TestEnv.Reset)

  ---The cell font string of `line` (an index) and `column`, and the line's
  ---frame, read from the package state.
  local function cell(tooltip, line, column)
    local record = TooltipKit._state.records[tooltip]
    local lineFrame = record.lines[line].frame
    return lineFrame.cells[column], lineFrame
  end

  it("acquires a tooltip by key, and the same key returns the open one", function()
    local tooltip = TooltipKit:Acquire("MyAddon", 2)
    assert.is_true(TooltipKit:IsAcquired("MyAddon"))
    assert.are.equal(tooltip, TooltipKit:Acquire("MyAddon", 2))
    assert.are.equal(2, tooltip:GetColumnCount())
    assert.is_false(tooltip:IsShown())
    assert.are.equal("TOOLTIP", tooltip:GetFrame():GetFrameStrata())
    assert.are.equal("TooltipKit.Tooltip", getmetatable(tooltip))
    TestEnv.expectErrorContaining("MyAddon is acquired with 2 columns, not 3", function()
      TooltipKit:Acquire("MyAddon", 3)
    end)
  end)

  it("lays columns out from their widest cell, justified as acquired", function()
    local tooltip = TooltipKit:Acquire("MyAddon", 2, "LEFT", "RIGHT")
    assert.are.equal(1, tooltip:AddHeader("Name", "Level"))
    assert.are.equal(2, tooltip:AddLine("Alice", 70))
    assert.are.equal(3, tooltip:AddLine("Bartholomew", 9))
    tooltip:Show()
    assert.is_true(tooltip:IsShown())
    -- Widest cells: "Bartholomew" (11 * 6 = 66) and "Level" (30).
    local frame = tooltip:GetFrame()
    assert.are.equal(10 + 66 + 10 + 30 + 10, frame:GetWidth())
    assert.are.equal(10 + 12 * 3 + 10, frame:GetHeight())
    local name, firstLine = cell(tooltip, 2, 1)
    local level = cell(tooltip, 2, 2)
    assert.are.equal("Alice", name:GetText())
    assert.are.equal("70", level:GetText())
    assert.are.equal("LEFT", name.justifyH)
    assert.are.equal("RIGHT", level.justifyH)
    assert.are.equal(66, name:GetWidth())
    assert.are.equal(30, level:GetWidth())
    assert.are.same({ "LEFT", firstLine, "LEFT", 76, 0 }, { level:GetPoint(1) })
    assert.are.equal("GameTooltipHeaderText", (cell(tooltip, 1, 1)):GetFontObject())
    assert.are.equal("GameTooltipText", name:GetFontObject())
  end)

  it(
    "measures a cell's whole text, not the width the last layout gave it, when it grows or its line is reused",
    function()
      local restore = TestEnv.BoundStringWidths()
      local ok, failure = pcall(function()
        local tooltip = TooltipKit:Acquire("MyAddon", 1)
        local line = tooltip:AddLine("ab")
        tooltip:Show()
        assert.are.equal(10 + 12 + 10, tooltip:GetFrame():GetWidth())
        -- The client truncates "abcdefghij" to the 12 pixels the cell was
        -- given; its unbounded width is 60.
        tooltip:SetCell(line, 1, "abcdefghij")
        assert.are.equal(10 + 60 + 10, tooltip:GetFrame():GetWidth())
        TooltipKit:Release(tooltip)

        -- A pooled line keeps the width its cell had in its last tooltip.
        local narrow = TooltipKit:Acquire("Narrow", 1)
        narrow:AddLine("a")
        narrow:Show()
        TooltipKit:Release(narrow)
        local reused = TooltipKit:Acquire("Reused", 1)
        reused:AddLine("abcdef")
        reused:Show()
        assert.are.equal(10 + 36 + 10, reused:GetFrame():GetWidth())
      end)
      restore()
      if not ok then
        error(failure, 0)
      end
    end
  )

  it("widens the last spanned column when a span needs more room", function()
    local tooltip = TooltipKit:Acquire("MyAddon", 3)
    tooltip:AddLine("a", "b", "c")
    local line = tooltip:AddLine()
    tooltip:SetCell(line, 1, "A long spanning title", { span = 3, justify = "CENTER" })
    tooltip:Show()
    -- Columns 6 + 6 + 6 with two gaps of 10 cover 38; the span needs 126.
    local spanCell = cell(tooltip, 2, 1)
    assert.are.equal(126, spanCell:GetWidth())
    assert.are.equal("CENTER", spanCell.justifyH)
    assert.are.equal(10 + 126 + 10, tooltip:GetFrame():GetWidth())
  end)

  it("lets a span cover cells and a later cell shorten an earlier span", function()
    local tooltip = TooltipKit:Acquire("MyAddon", 3)
    local line = tooltip:AddLine("a", "b", "c")
    tooltip:SetCell(line, 1, "wide", { span = 3 })
    assert.is_nil((cell(tooltip, 1, 2)):GetText())
    tooltip:SetCell(line, 3, "end")
    tooltip:Show()
    assert.are.equal("end", (cell(tooltip, 1, 3)):GetText())
    TestEnv.expectErrorContaining("options.span must be an integer from 1 to 2", function()
      tooltip:SetCell(line, 2, "x", { span = 3 })
    end)
    tooltip:SetCell(line, 1, nil)
    assert.is_nil((cell(tooltip, 1, 1)):GetText())
  end)

  it("draws separators, line colours and cell text colours", function()
    local tooltip = TooltipKit:Acquire("MyAddon", 1)
    tooltip:AddLine("top")
    local separator = tooltip:AddSeparator(3, 1, 0, 0, 1)
    tooltip:AddLine("bottom")
    tooltip:SetLineColor(1, 0, 0.5, 0, 0.4)
    tooltip:SetCellTextColor(3, 1, 0, 1, 0)
    tooltip:Show()
    assert.are.equal(2, separator)
    assert.are.equal(10 + 12 + 3 + 12 + 10, tooltip:GetFrame():GetHeight())
    local _, topLine = cell(tooltip, 1, 1)
    assert.are.same({ 0, 0.5, 0, 0.4 }, {
      topLine.background.colorRed,
      topLine.background.colorGreen,
      topLine.background.colorBlue,
      topLine.background.colorAlpha,
    })
    assert.are.same({ 0, 1, 0, 1 }, { (cell(tooltip, 3, 1)):GetTextColor() })
    tooltip:SetLineColor(1)
    assert.are.equal(0, topLine.background.colorAlpha)
    TestEnv.expectErrorContaining("line 2 is a separator and has no cells", function()
      tooltip:SetCell(2, 1, "x")
    end)
  end)

  it("lays out again when a shown tooltip changes", function()
    local tooltip = TooltipKit:Acquire("MyAddon", 1)
    tooltip:AddLine("a")
    tooltip:Show()
    assert.are.equal(10 + 12 + 10, tooltip:GetFrame():GetHeight())
    tooltip:AddLine("b")
    assert.are.equal(10 + 24 + 10, tooltip:GetFrame():GetHeight())
    tooltip:Clear()
    assert.are.equal(0, tooltip:GetLineCount())
    assert.are.equal(20, tooltip:GetFrame():GetHeight())
  end)

  it(
    "runs line handlers with the line frame and their argument, and reports one that raises",
    function()
      local tooltip = TooltipKit:Acquire("MyAddon", 1)
      local line = tooltip:AddLine("click me")
      local calls = {}
      tooltip:SetLineScript(line, "OnMouseUp", function(frame, arg, mouseButton)
        calls[#calls + 1] = { frame, arg, mouseButton }
      end, "payload")
      local _, lineFrame = cell(tooltip, 1, 1)
      assert.is_true(lineFrame:IsMouseEnabled())
      TestEnv.Run(lineFrame, "OnMouseUp", "LeftButton")
      assert.are.same({ { lineFrame, "payload", "LeftButton" } }, calls)
      tooltip:SetLineScript(line, "OnEnter", function()
        error("enter failed", 0)
      end)
      TestEnv.Run(lineFrame, "OnEnter")
      assert.are.same({ "enter failed" }, TestEnv.TakeReportedValues())
      tooltip:SetLineScript(line, "OnMouseUp", nil)
      tooltip:SetLineScript(line, "OnEnter", nil)
      assert.is_false(lineFrame:IsMouseEnabled())
      assert.is_nil(lineFrame:GetScript("OnMouseUp"))
    end
  )

  it("limits its height and scrolls taller content with the wheel", function()
    local tooltip = TooltipKit:Acquire("MyAddon", 1)
    for index = 1, 20 do
      tooltip:AddLine("line " .. index)
    end
    tooltip:SetMaxHeight(100)
    tooltip:Show()
    local frame = tooltip:GetFrame()
    assert.are.equal(100, frame:GetHeight())
    assert.is_true(frame.mouseWheelEnabled == true)
    TestEnv.Run(frame, "OnMouseWheel", -1)
    assert.are.equal(24, frame.scroll:GetVerticalScroll())
    for _ = 1, 20 do
      TestEnv.Run(frame, "OnMouseWheel", -1)
    end
    -- 20 lines of 12 plus padding is 260; the frame shows 100.
    assert.are.equal(160, frame.scroll:GetVerticalScroll())
    TestEnv.Run(frame, "OnMouseWheel", 100)
    assert.are.equal(0, frame.scroll:GetVerticalScroll())
    tooltip:SetMaxHeight(nil)
    assert.are.equal(260, frame:GetHeight())
    assert.is_false(frame.mouseWheelEnabled == true)
  end)

  it("anchors itself on the side of the frame with room", function()
    local tooltip = TooltipKit:Acquire("MyAddon", 1)
    local cases = {
      { 100, 900, "TOPLEFT", "BOTTOMLEFT" },
      { 1700, 900, "TOPRIGHT", "BOTTOMRIGHT" },
      { 100, 100, "BOTTOMLEFT", "TOPLEFT" },
      { 1700, 100, "BOTTOMRIGHT", "TOPRIGHT" },
    }
    for _, case in ipairs(cases) do
      local owner = TestEnv.FrameAt(case[1], case[2])
      tooltip:SmartAnchorTo(owner)
      local point, relativeTo, relativePoint = tooltip:GetFrame():GetPoint(1)
      assert.are.same({ case[3], owner, case[4] }, { point, relativeTo, relativePoint })
    end
  end)

  it(
    "releases itself once the cursor has been off it, its anchor and the alternate frame long enough",
    function()
      local tooltip = TooltipKit:Acquire("MyAddon", 1)
      tooltip:AddLine("x")
      local owner = TestEnv.FrameAt(100, 900)
      local other = TestEnv.FrameAt(300, 900)
      tooltip:SmartAnchorTo(owner)
      tooltip:SetAutoHideDelay(0.25, other)
      tooltip:Show()
      local frame = tooltip:GetFrame()
      TestEnv.SetMouseOver(frame, false)
      TestEnv.SetMouseOver(owner, false)
      TestEnv.SetMouseOver(other, true)
      TestEnv.Run(frame, "OnUpdate", 1)
      assert.is_true(TooltipKit:IsAcquired("MyAddon"))
      TestEnv.SetMouseOver(other, false)
      TestEnv.Run(frame, "OnUpdate", 0.2)
      assert.is_true(TooltipKit:IsAcquired("MyAddon"))
      TestEnv.SetMouseOver(owner, true)
      TestEnv.Run(frame, "OnUpdate", 0.2)
      TestEnv.SetMouseOver(owner, false)
      TestEnv.Run(frame, "OnUpdate", 0.2)
      assert.is_true(TooltipKit:IsAcquired("MyAddon"))
      TestEnv.Run(frame, "OnUpdate", 0.1)
      assert.is_false(TooltipKit:IsAcquired("MyAddon"))
      assert.is_nil(frame:GetScript("OnUpdate"))
    end
  )

  it("stops auto-hiding with nil", function()
    local tooltip = TooltipKit:Acquire("MyAddon", 1)
    tooltip:SetAutoHideDelay(0)
    assert.is_function(tooltip:GetFrame():GetScript("OnUpdate"))
    tooltip:SetAutoHideDelay(nil)
    assert.is_nil(tooltip:GetFrame():GetScript("OnUpdate"))
  end)

  it("hides without releasing", function()
    local tooltip = TooltipKit:Acquire("MyAddon", 1)
    tooltip:Show()
    tooltip:Hide()
    assert.is_false(tooltip:IsShown())
    assert.is_true(TooltipKit:IsAcquired("MyAddon"))
  end)
end)
