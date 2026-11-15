local TestEnv = require("MenuKitTestEnv")

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

describe("MenuKit error levels", function()
  local MenuKit, api, extension
  before_each(function()
    MenuKit, api = TestEnv.NewPackage()
    extension = MenuKit:ExtendMenu("MENU_UNIT_SELF", {})
  end)
  after_each(TestEnv.Reset)

  it("points every argument error at the caller", function()
    checkCases({
      {
        function()
          MenuKit:OpenContextMenu("frame", {})
        end,
        "MenuKit:OpenContextMenu owner must be a frame or nil",
      },
      {
        function()
          MenuKit:OpenContextMenu(nil, { { kind = "button" } })
        end,
        "MenuKit:OpenContextMenu menu[1].text must be a non-empty string",
      },
      {
        function()
          MenuKit:SetupDropdown({}, {})
        end,
        "MenuKit:SetupDropdown dropdown must be a DropdownButton",
      },
      {
        function()
          MenuKit:SetupDropdown(api.NewDropdown(), { 1 })
        end,
        "MenuKit:SetupDropdown menu[1] must be an entry table",
      },
      {
        function()
          MenuKit:ExtendMenu(1, {})
        end,
        "MenuKit:ExtendMenu tag must be a non-empty string",
      },
      {
        function()
          MenuKit:ExtendMenu("MENU_UNIT_SELF", "menu")
        end,
        "MenuKit:ExtendMenu menu must be an array of entries",
      },
      {
        function()
          MenuKit.CloseMenus(nil)
        end,
        "MenuKit:CloseMenus must be called on the MenuKit facade; use MenuKit:CloseMenus(...)",
      },
      {
        function()
          MenuKit:SetLimits({ maxDepth = 0 })
        end,
        "MenuKit:SetLimits limits.maxDepth must be a positive integer or MenuKit.UNBOUNDED",
      },
      {
        function()
          MenuKit.GetLimits({})
        end,
        "MenuKit:GetLimits must be called on the MenuKit facade; use MenuKit:GetLimits(...)",
      },
      {
        function()
          extension.Remove({})
        end,
        "MenuKit.Extension:Remove must be called on a MenuKit extension; use extension:Remove(...)",
      },
      {
        function()
          extension.IsActive(1)
        end,
        "MenuKit.Extension:IsActive must be called on a MenuKit extension; use extension:IsActive(...)",
      },
    })
    MenuKit:SetLimits({ maxExtensions = 1 })
    TestEnv.SetGlobal("Menu", nil)
    checkCases({
      {
        function()
          MenuKit:CloseMenus()
        end,
        "MenuKit:CloseMenus needs the client's Menu API (Blizzard_Menu), which this host does not have",
      },
    })
    api = TestEnv.InstallMenu()
    checkCases({
      {
        function()
          MenuKit:ExtendMenu("MENU_UNIT_PARTY", {})
        end,
        "MenuKit:ExtendMenu holds at most 1 extensions; remove one, or raise maxExtensions with MenuKit:SetLimits",
      },
    })
  end)
end)
