local TestEnv = require("TooltipKitTestEnv")

describe("TooltipKit secret values", function()
  local TooltipKit, tooltip, secret
  before_each(function()
    TooltipKit = TestEnv.NewPackage()
    TestEnv.InstallSecretProbe()
    secret = TestEnv.NewSecret()
    tooltip = TooltipKit:Acquire("MyAddon", 2)
    tooltip:AddLine("a", "b")
  end)
  after_each(TestEnv.Reset)

  it("refuses a secret text in AddLine, AddHeader and SetCell without allowSecret", function()
    TestEnv.expectErrorContaining(
      "TooltipKit.Tooltip:AddLine value 2 must not be a secret value; pass { allowSecret = true } to SetCell to draw one",
      function()
        tooltip:AddLine("a", secret)
      end
    )
    TestEnv.expectErrorContaining(
      "TooltipKit.Tooltip:AddHeader value 1 must not be a secret value",
      function()
        tooltip:AddHeader(secret)
      end
    )
    TestEnv.expectErrorContaining(
      "TooltipKit.Tooltip:SetCell text must not be a secret value",
      function()
        tooltip:SetCell(1, 1, secret)
      end
    )
    assert.are.equal(1, tooltip:GetLineCount())
  end)

  it("draws a secret text with allowSecret, and lays out with its size as 0", function()
    tooltip:SetCell(1, 1, secret, { allowSecret = true })
    local lineFrame = TooltipKit._state.records[tooltip].lines[1].frame
    assert.are.equal(secret, lineFrame.cells[1]:GetText())
    lineFrame.cells[1].GetStringWidth = function()
      return secret
    end
    lineFrame.cells[1].GetStringHeight = function()
      return secret
    end
    tooltip:Show()
    assert.are.equal(10 + 0 + 10 + 6 + 10, tooltip:GetFrame():GetWidth())
  end)

  it("refuses secret keys, columns, lines, options, colours, limits and receivers", function()
    local cases = {
      {
        "TooltipKit:Acquire key must not be a secret value",
        function()
          TooltipKit:Acquire(secret, 1)
        end,
      },
      {
        "TooltipKit:Acquire columns must be an integer",
        function()
          TooltipKit:Acquire("Other", secret)
        end,
      },
      {
        "TooltipKit:Acquire justify 1 must be",
        function()
          TooltipKit:Acquire("Other", 1, secret)
        end,
      },
      {
        "TooltipKit.Tooltip:SetCell line must not be a secret value",
        function()
          tooltip:SetCell(secret, 1, "x")
        end,
      },
      {
        "TooltipKit.Tooltip:SetCell column must not be a secret value",
        function()
          tooltip:SetCell(1, secret, "x")
        end,
      },
      {
        "options holds an unknown field",
        function()
          tooltip:SetCell(1, 1, "x", { [secret] = 1 })
        end,
      },
      {
        "options.span must be an integer",
        function()
          tooltip:SetCell(1, 1, "x", { span = secret })
        end,
      },
      {
        "TooltipKit.Tooltip:SetLineColor r must not be a secret value",
        function()
          tooltip:SetLineColor(1, secret, 0, 0)
        end,
      },
      {
        "TooltipKit:SetLimits limits.maxLines must not be a secret value",
        function()
          TooltipKit:SetLimits({ maxLines = secret })
        end,
      },
      {
        "must be called on an acquired TooltipKit tooltip",
        function()
          tooltip.Show(secret)
        end,
      },
      {
        "TooltipKit:Release tooltip must be an acquired TooltipKit tooltip",
        function()
          TooltipKit:Release(secret)
        end,
      },
    }
    for _, case in ipairs(cases) do
      TestEnv.expectErrorContaining(case[1], case[2])
    end
  end)

  it("treats a secret mouse-over answer as off and a secret wheel delta as nothing", function()
    tooltip:SetAutoHideDelay(0.1)
    tooltip:Show()
    local frame = tooltip:GetFrame()
    TestEnv.SetMouseOver(frame, secret)
    TestEnv.Run(frame, "OnUpdate", 0.2)
    assert.is_false(TooltipKit:IsAcquired("MyAddon"))
    local other = TooltipKit:Acquire("Other", 1)
    other:SetMaxHeight(20)
    other:AddLine("x")
    other:Show()
    TestEnv.Run(other:GetFrame(), "OnMouseWheel", secret)
    assert.are.equal(0, other:GetFrame().scroll:GetVerticalScroll())
  end)
end)
