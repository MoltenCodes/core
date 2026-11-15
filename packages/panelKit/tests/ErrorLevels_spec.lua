local TestEnv = require("PanelKitTestEnv")

local SOURCE = debug.getinfo(1, "S").short_src

---Run every `{ action, message }` case and check the failure is reported at
---the line after the function's `function()` line, where its statement sits.
---A wrong `error` level shows up as another line, or as a message without
---the `file:line` prefix.
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

describe("PanelKit error levels", function()
  local PanelKit, panel
  before_each(function()
    PanelKit = TestEnv.NewPackage()
    panel = PanelKit:Register("MyAddon")
  end)
  after_each(TestEnv.Reset)

  it("points Register's errors at the caller", function()
    checkCases({
      {
        function()
          PanelKit:Register("")
        end,
        "PanelKit:Register treeName must be a non-empty string",
      },
      {
        function()
          PanelKit:Register("Other", 1)
        end,
        "PanelKit:Register options must be a table or nil",
      },
      {
        function()
          PanelKit:Register("Other", { other = 1 })
        end,
        "PanelKit:Register options holds an unknown field; it accepts name and parent",
      },
      {
        function()
          PanelKit:Register("Other", { name = 1 })
        end,
        "PanelKit:Register options.name must be a non-empty string",
      },
      {
        function()
          PanelKit:Register("Other", { parent = 1 })
        end,
        "PanelKit:Register options.parent must be a PanelKit panel",
      },
      {
        function()
          PanelKit:Register("MyAddon")
        end,
        "PanelKit:Register a panel named MyAddon is already registered there",
      },
      {
        function()
          PanelKit.Register(nil, "Other")
        end,
        "PanelKit:Register must be called on the PanelKit facade; use PanelKit:Register(...)",
      },
    })
    PanelKit:SetLimits({ maxPanels = 1 })
    checkCases({
      {
        function()
          PanelKit:Register("Other")
        end,
        "PanelKit:Register holds at most 1 panels; raise maxPanels with PanelKit:SetLimits",
      },
    })
    TestEnv.SetGlobal("Settings", nil)
    PanelKit:SetLimits({ maxPanels = 2 })
    checkCases({
      {
        function()
          PanelKit:Register("Other")
        end,
        "PanelKit:Register needs the client's Settings API, which this host does not have",
      },
    })
  end)

  it("points Get, SetLimits and GetLimits errors at the caller", function()
    checkCases({
      {
        function()
          PanelKit:Get(1)
        end,
        "PanelKit:Get name must be a non-empty string",
      },
      {
        function()
          PanelKit:Get("MyAddon", 1)
        end,
        "PanelKit:Get parent must be a PanelKit panel or nil",
      },
      {
        function()
          PanelKit:SetLimits(1)
        end,
        "PanelKit:SetLimits limits must be a table",
      },
      {
        function()
          PanelKit:SetLimits({ other = 1 })
        end,
        "PanelKit:SetLimits limits holds an unknown field; it accepts maxPanels",
      },
      {
        function()
          PanelKit:SetLimits({ maxPanels = 0 })
        end,
        "PanelKit:SetLimits limits.maxPanels must be an integer from 1 to 1024",
      },
      {
        function()
          PanelKit.GetLimits({})
        end,
        "PanelKit:GetLimits must be called on the PanelKit facade; use PanelKit:GetLimits(...)",
      },
    })
  end)

  it("points panel method errors at the caller", function()
    checkCases({
      {
        function()
          panel.Open({})
        end,
        "PanelKit.Panel:Open must be called on a PanelKit panel; use panel:Open(...)",
      },
      {
        function()
          panel.GetName(nil)
        end,
        "PanelKit.Panel:GetName must be called on a PanelKit panel; use panel:GetName(...)",
      },
      {
        function()
          panel.GetCategoryID(1)
        end,
        "PanelKit.Panel:GetCategoryID must be called on a PanelKit panel; use panel:GetCategoryID(...)",
      },
      {
        function()
          panel.GetRendering("panel")
        end,
        "PanelKit.Panel:GetRendering must be called on a PanelKit panel; use panel:GetRendering(...)",
      },
      {
        function()
          panel:SetDefaultHandler(1)
        end,
        "PanelKit.Panel:SetDefaultHandler callback must be a function or nil",
      },
    })
  end)
end)
