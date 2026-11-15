local TestEnv = require("MenuKitTestEnv")

describe("MenuKit limits", function()
  local MenuKit, api
  before_each(function()
    MenuKit, api = TestEnv.NewPackage()
  end)
  after_each(TestEnv.Reset)

  ---A menu of `count` buttons.
  ---@param count integer
  ---@return table
  local function buttons(count)
    local entries = {}
    for index = 1, count do
      entries[index] = { kind = "button", text = "Button " .. index }
    end
    return entries
  end

  ---A menu `depth` menus deep.
  ---@param depth integer
  ---@return table
  local function nested(depth)
    local entries = { { kind = "title", text = "Bottom" } }
    for _ = 2, depth do
      entries = { { kind = "button", text = "Down", entries = entries } }
    end
    return entries
  end

  it("reports the defaults and the constants in a fresh table", function()
    assert.are.equal(256, MenuKit.MAX_ENTRIES)
    assert.are.equal(4, MenuKit.MAX_DEPTH)
    assert.are.equal(64, MenuKit.MAX_EXTENSIONS)
    assert.are.equal(1024, MenuKit.EXTENSIONS_CEILING)
    local limits = MenuKit:GetLimits()
    assert.are.same({ maxEntries = 256, maxDepth = 4, maxExtensions = 64 }, limits)
    assert.are_not.equal(limits, MenuKit:GetLimits())
  end)

  it("counts entries across submenus against maxEntries", function()
    MenuKit:OpenContextMenu(nil, buttons(256))
    TestEnv.expectErrorContaining("menu holds more than 256 entries; maxEntries is 256", function()
      MenuKit:OpenContextMenu(nil, buttons(257))
    end)
    MenuKit:SetLimits({ maxEntries = 3 })
    TestEnv.expectErrorContaining(
      "menu[1].entries holds more than 3 entries; maxEntries is 3",
      function()
        MenuKit:OpenContextMenu(nil, { { kind = "button", text = "Sub", entries = buttons(3) } })
      end
    )
    MenuKit:SetLimits({ maxEntries = MenuKit.UNBOUNDED })
    MenuKit:OpenContextMenu(nil, buttons(2000))
    assert.are.equal(2000, #api.contextMenus[2].children)
  end)

  it("refuses a submenu deeper than maxDepth", function()
    MenuKit:OpenContextMenu(nil, nested(4))
    TestEnv.expectErrorContaining("opens 5 menus deep; maxDepth is 4", function()
      MenuKit:OpenContextMenu(nil, nested(5))
    end)
    MenuKit:SetLimits({ maxDepth = MenuKit.UNBOUNDED })
    MenuKit:OpenContextMenu(nil, nested(40))
  end)

  it("applies the limits to a menu function's result when the menu opens", function()
    TestEnv.InstallHostErrorHandler()
    MenuKit:SetLimits({ maxEntries = 1 })
    MenuKit:OpenContextMenu(nil, function()
      return buttons(2)
    end)
    assert.are.same({}, api.contextMenus[1].children)
    assert.are.same(
      { "MenuKit menu holds more than 1 entries; maxEntries is 1" },
      TestEnv.TakeReportedValues()
    )
  end)

  it("refuses invalid limits without changing any", function()
    local cases = {
      { "limits must be a table", 1 },
      {
        "limits holds an unknown field; it accepts maxEntries, maxDepth and maxExtensions",
        { maxItems = 1 },
      },
      { "limits.maxEntries must be a positive integer or MenuKit.UNBOUNDED", { maxEntries = 0 } },
      { "limits.maxDepth must be a positive integer or MenuKit.UNBOUNDED", { maxDepth = 1.5 } },
      {
        "limits.maxDepth must be a positive integer or MenuKit.UNBOUNDED",
        { maxDepth = math.huge },
      },
      {
        "limits.maxExtensions must be an integer from 1 to 1024",
        { maxExtensions = MenuKit.UNBOUNDED },
      },
      { "limits.maxExtensions must be an integer from 1 to 1024", { maxExtensions = 1025 } },
      {
        "limits.maxExtensions must be an integer from 1 to 1024",
        { maxEntries = 8, maxExtensions = 0 },
      },
    }
    for _, case in ipairs(cases) do
      TestEnv.expectErrorContaining("MenuKit:SetLimits " .. case[1], function()
        MenuKit:SetLimits(case[2])
      end)
    end
    assert.are.same({ maxEntries = 256, maxDepth = 4, maxExtensions = 64 }, MenuKit:GetLimits())
    MenuKit:SetLimits({ maxExtensions = 1024 })
    assert.are.equal(1024, MenuKit:GetLimits().maxExtensions)
  end)

  -- Revision 2: the check reads an entry's own fields, so the build must read
  -- the same ones. Revision 1 built from fields an `__index` metatable
  -- supplied, so a submenu the check never saw bypassed maxEntries.
  it("builds only the entry fields it checked, not ones a metatable supplies", function()
    TestEnv.InstallHostErrorHandler()
    MenuKit:SetLimits({ maxEntries = 3 })
    local inherited = { entries = buttons(10), onClick = "not a function", disabled = true }
    local entry = setmetatable({ kind = "button", text = "Parent" }, { __index = inherited })
    MenuKit:OpenContextMenu(nil, { entry })
    local root = api.contextMenus[1]
    assert.are.same({ "button:Parent" }, root:Outline())
    local button = root.children[1]
    assert.are.same({}, button.children)
    assert.is_nil(button.responder)
    assert.is_true(button:IsEnabled())
    assert.are.same({}, TestEnv.TakeReportedValues())
  end)
end)
