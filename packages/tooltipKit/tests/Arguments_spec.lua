local TestEnv = require("TooltipKitTestEnv")

describe("TooltipKit argument checks", function()
  local TooltipKit, tooltip
  before_each(function()
    TooltipKit = TestEnv.NewPackage()
    tooltip = TooltipKit:Acquire("MyAddon", 2)
    tooltip:AddLine("a", "b")
  end)
  after_each(TestEnv.Reset)

  local function refuses(message, call)
    TestEnv.expectErrorContaining(message, call)
  end

  it("checks Acquire's key, columns and justification", function()
    refuses("TooltipKit:Acquire key must be a non-empty string", function()
      TooltipKit:Acquire("", 1)
    end)
    refuses("TooltipKit:Acquire columns must be an integer from 1 to 16", function()
      TooltipKit:Acquire("Other", 0)
    end)
    refuses("TooltipKit:Acquire columns must be an integer from 1 to 16", function()
      TooltipKit:Acquire("Other", 17)
    end)
    refuses('TooltipKit:Acquire justify 2 must be "LEFT", "CENTER", "RIGHT" or nil', function()
      TooltipKit:Acquire("Other", 2, "LEFT", "MIDDLE")
    end)
    assert.is_false(TooltipKit:IsAcquired("Other"))
    refuses("TooltipKit:IsAcquired key must be a non-empty string", function()
      TooltipKit:IsAcquired(1)
    end)
  end)

  it("refuses to acquire without CreateFrame or UIParent", function()
    TestEnv.SetGlobal("UIParent", nil)
    refuses("needs the client's CreateFrame and UIParent", function()
      TooltipKit:Acquire("Other", 1)
    end)
  end)

  it("checks the values of AddLine and AddHeader", function()
    refuses("TooltipKit.Tooltip:AddLine got 3 values for 2 columns", function()
      tooltip:AddLine("a", "b", "c")
    end)
    refuses("TooltipKit.Tooltip:AddLine value 2 must be a string, a number or nil", function()
      tooltip:AddLine("a", {})
    end)
    refuses("TooltipKit.Tooltip:AddHeader value 1 must be a string, a number or nil", function()
      tooltip:AddHeader(true)
    end)
    assert.are.equal(1, tooltip:GetLineCount())
  end)

  it("checks AddSeparator's height and colour", function()
    refuses("height must be a number above 0 and at most 100, or nil", function()
      tooltip:AddSeparator(0)
    end)
    refuses("TooltipKit.Tooltip:AddSeparator g must be a number from 0 to 1", function()
      tooltip:AddSeparator(1, 0, 2)
    end)
    assert.are.equal(1, tooltip:GetLineCount())
  end)

  it("checks SetCell's line, column, text and options", function()
    refuses(
      "TooltipKit.Tooltip:SetCell line must be the index of a line of this tooltip (1 to 1)",
      function()
        tooltip:SetCell(2, 1, "x")
      end
    )
    refuses("TooltipKit.Tooltip:SetCell column must be an integer from 1 to 2", function()
      tooltip:SetCell(1, 3, "x")
    end)
    refuses("TooltipKit.Tooltip:SetCell text must be a string, a number or nil", function()
      tooltip:SetCell(1, 1, false)
    end)
    refuses("TooltipKit.Tooltip:SetCell options must be a table or nil", function()
      tooltip:SetCell(1, 1, "x", "wide")
    end)
    refuses(
      "options holds an unknown field; it accepts span, justify, font and allowSecret",
      function()
        tooltip:SetCell(1, 1, "x", { colspan = 2 })
      end
    )
    refuses('options.justify must be "LEFT", "CENTER" or "RIGHT"', function()
      tooltip:SetCell(1, 1, "x", { justify = "left" })
    end)
    refuses("options.font must be a font object or its name", function()
      tooltip:SetCell(1, 1, "x", { font = 12 })
    end)
    refuses("options.allowSecret must be a boolean", function()
      tooltip:SetCell(1, 1, "x", { allowSecret = "yes" })
    end)
  end)

  it("uses a cell's own font", function()
    tooltip:SetCell(1, 1, "x", { font = "GameFontNormalSmall" })
    local lineFrame = TooltipKit._state.records[tooltip].lines[1].frame
    assert.are.equal("GameFontNormalSmall", lineFrame.cells[1]:GetFontObject())
  end)

  it("checks colours, scripts, the height limit, the anchor and the auto-hide delay", function()
    refuses("TooltipKit.Tooltip:SetCellTextColor b must be a number from 0 to 1", function()
      tooltip:SetCellTextColor(1, 1, 0, 0)
    end)
    refuses("TooltipKit.Tooltip:SetLineColor a must be a number from 0 to 1", function()
      tooltip:SetLineColor(1, 0, 0, 0, -1)
    end)
    refuses(
      'TooltipKit.Tooltip:SetLineScript script must be "OnMouseUp", "OnEnter" or "OnLeave"',
      function()
        tooltip:SetLineScript(1, "OnClick", function() end)
      end
    )
    refuses("TooltipKit.Tooltip:SetLineScript handler must be a function or nil", function()
      tooltip:SetLineScript(1, "OnEnter", "handler")
    end)
    refuses(
      "TooltipKit.Tooltip:SetMaxHeight pixels must be a number of at least 20, or nil",
      function()
        tooltip:SetMaxHeight(10)
      end
    )
    refuses("TooltipKit.Tooltip:SmartAnchorTo frame must be a frame", function()
      tooltip:SmartAnchorTo({})
    end)
    refuses(
      "TooltipKit.Tooltip:SetAutoHideDelay seconds must be a number of 0 or more, or nil",
      function()
        tooltip:SetAutoHideDelay(-1)
      end
    )
    refuses("TooltipKit.Tooltip:SetAutoHideDelay alternateFrame must be a frame or nil", function()
      tooltip:SetAutoHideDelay(1, "frame")
    end)
  end)

  it("refuses every method called without the facade or a tooltip", function()
    for _, call in ipairs({
      function()
        TooltipKit.Acquire({}, "Other", 1)
      end,
      function()
        TooltipKit.Release(nil, tooltip)
      end,
      function()
        TooltipKit.IsAcquired("TooltipKit", "MyAddon")
      end,
      function()
        TooltipKit.SetLimits({}, {})
      end,
      function()
        TooltipKit.GetLimits(1)
      end,
    }) do
      refuses("must be called on the TooltipKit facade", call)
    end
    for _, name in ipairs({
      "AddHeader",
      "AddLine",
      "Clear",
      "Show",
      "Hide",
      "IsShown",
      "GetLineCount",
      "GetColumnCount",
      "GetFrame",
    }) do
      refuses(
        "TooltipKit.Tooltip:" .. name .. " must be called on an acquired TooltipKit tooltip",
        function()
          tooltip[name]({})
        end
      )
    end
  end)
end)
