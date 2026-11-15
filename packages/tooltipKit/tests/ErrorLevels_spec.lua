local TestEnv = require("TooltipKitTestEnv")

local SOURCE = debug.getinfo(1, "S").short_src

---Run every `{ action, message }` case and check the failure is reported at
---the line after the function's `function()` line, where its statement sits.
---@param cases { [1]: fun(), [2]: string }[]
local function checkCases(cases)
  for _, case in ipairs(cases) do
    local action = case[1]
    local line = debug.getinfo(action, "S").linedefined + 1
    local ok, value = pcall(action)
    assert.is_false(ok)
    assert.are.equal(SOURCE .. ":" .. line .. ": " .. case[2], value)
  end
end

describe("TooltipKit error levels", function()
  local TooltipKit, tooltip
  before_each(function()
    TooltipKit = TestEnv.NewPackage()
    tooltip = TooltipKit:Acquire("MyAddon", 2)
    tooltip:AddLine("a", "b")
  end)
  after_each(TestEnv.Reset)

  it("points every argument error at the caller", function()
    checkCases({
      {
        function()
          TooltipKit:Acquire("", 1)
        end,
        "TooltipKit:Acquire key must be a non-empty string",
      },
      {
        function()
          TooltipKit:Acquire("Other", 99)
        end,
        "TooltipKit:Acquire columns must be an integer from 1 to 16",
      },
      {
        function()
          TooltipKit:Acquire("MyAddon", 1)
        end,
        "TooltipKit:Acquire MyAddon is acquired with 2 columns, not 1",
      },
      {
        function()
          tooltip:AddLine("a", "b", "c")
        end,
        "TooltipKit.Tooltip:AddLine got 3 values for 2 columns",
      },
      {
        function()
          tooltip:AddLine({})
        end,
        "TooltipKit.Tooltip:AddLine value 1 must be a string, a number or nil",
      },
      {
        function()
          tooltip:AddHeader("a", "b", "c")
        end,
        "TooltipKit.Tooltip:AddHeader got 3 values for 2 columns",
      },
      {
        function()
          tooltip:AddSeparator(1, 5)
        end,
        "TooltipKit.Tooltip:AddSeparator r must be a number from 0 to 1",
      },
      {
        function()
          tooltip:SetCell(9, 1, "x")
        end,
        "TooltipKit.Tooltip:SetCell line must be the index of a line of this tooltip (1 to 1)",
      },
      {
        function()
          tooltip:SetCell(1, 1, "x", { span = 9 })
        end,
        "TooltipKit.Tooltip:SetCell options.span must be an integer from 1 to 2",
      },
      {
        function()
          tooltip:SetCellTextColor(1, 5, 0, 0, 0)
        end,
        "TooltipKit.Tooltip:SetCellTextColor column must be an integer from 1 to 2",
      },
      {
        function()
          tooltip:SetLineScript(1, "OnShow", function() end)
        end,
        'TooltipKit.Tooltip:SetLineScript script must be "OnMouseUp", "OnEnter" or "OnLeave"',
      },
      {
        function()
          tooltip:SetMaxHeight(1)
        end,
        "TooltipKit.Tooltip:SetMaxHeight pixels must be a number of at least 20, or nil",
      },
      {
        function()
          tooltip:SmartAnchorTo(nil)
        end,
        "TooltipKit.Tooltip:SmartAnchorTo frame must be a frame",
      },
      {
        function()
          tooltip:SetAutoHideDelay("soon")
        end,
        "TooltipKit.Tooltip:SetAutoHideDelay seconds must be a number of 0 or more, or nil",
      },
      {
        function()
          tooltip.GetFrame({})
        end,
        "TooltipKit.Tooltip:GetFrame must be called on an acquired TooltipKit tooltip; use tooltip:GetFrame(...)",
      },
      {
        function()
          TooltipKit:Release({})
        end,
        "TooltipKit:Release tooltip must be an acquired TooltipKit tooltip",
      },
      {
        function()
          TooltipKit:SetLimits({ maxColumns = 99 })
        end,
        "TooltipKit:SetLimits limits.maxColumns must be an integer from 1 to 32",
      },
      {
        function()
          TooltipKit.GetLimits({})
        end,
        "TooltipKit:GetLimits must be called on the TooltipKit facade; use TooltipKit:GetLimits(...)",
      },
    })
    TooltipKit:SetLimits({ maxLines = 1 })
    checkCases({
      {
        function()
          tooltip:AddLine("c")
        end,
        "TooltipKit.Tooltip:AddLine holds at most 1 lines; raise maxLines with TooltipKit:SetLimits",
      },
    })
    TooltipKit:SetLimits({ maxTooltips = 1 })
    checkCases({
      {
        function()
          TooltipKit:Acquire("Other", 1)
        end,
        "TooltipKit:Acquire holds at most 1 tooltips at once; release one, or raise maxTooltips",
      },
    })
  end)
end)
