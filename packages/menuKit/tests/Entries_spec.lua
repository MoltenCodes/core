local TestEnv = require("MenuKitTestEnv")

describe("MenuKit entry checks", function()
  local MenuKit, api
  before_each(function()
    MenuKit, api = TestEnv.NewPackage()
  end)
  after_each(TestEnv.Reset)

  local function noop() end

  ---Assert that opening `menu` raises `message` and opens nothing.
  ---@param message string
  ---@param menu any
  local function refuses(message, menu)
    TestEnv.expectErrorContaining(message, function()
      MenuKit:OpenContextMenu(nil, menu)
    end)
    assert.are.equal(0, #api.contextMenus)
  end

  it("refuses a menu that is not an array of entries or a function", function()
    refuses("MenuKit:OpenContextMenu menu must be an array of entries", nil)
    refuses("MenuKit:OpenContextMenu menu must be an array of entries", "menu")
    refuses("MenuKit:OpenContextMenu menu[1] must be an entry table", { "button" })
  end)

  it("refuses an unknown kind and a field the kind does not take", function()
    refuses(
      'menu[1].kind must be "button", "checkbox", "radio", "title", "divider" or "spacer"',
      { { kind = "link", text = "x" } }
    )
    refuses('menu[1].kind must be "button"', { { text = "x" } })
    refuses(
      "menu[1] holds the field onClick, which a title does not take",
      { { kind = "title", text = "T", onClick = noop } }
    )
    refuses(
      "menu[1] holds the field text, which a divider does not take",
      { { kind = "divider", text = "T" } }
    )
    refuses(
      "menu[1] holds the field onclick, which a button does not take",
      { { kind = "button", text = "T", onclick = noop } }
    )
    refuses(
      "menu[1] holds the field <number>, which a spacer does not take",
      { { kind = "spacer", [1] = 1 } }
    )
  end)

  it("checks texts, tooltips, disabled and the callbacks of each kind", function()
    refuses("menu[1].text must be a non-empty string", { { kind = "button" } })
    refuses("menu[1].text must be a non-empty string", { { kind = "title", text = "" } })
    refuses(
      "menu[1].tooltip must be a non-empty string",
      { { kind = "button", text = "B", tooltip = 1 } }
    )
    refuses(
      "menu[1].disabled must be a boolean, a function or nil",
      { { kind = "button", text = "B", disabled = "yes" } }
    )
    refuses(
      "menu[1].onClick must be a function or nil",
      { { kind = "button", text = "B", onClick = "Open" } }
    )
    refuses(
      "menu[1].isSelected must be a function",
      { { kind = "checkbox", text = "C", setSelected = noop } }
    )
    refuses(
      "menu[1].setSelected must be a function",
      { { kind = "radio", text = "R", isSelected = noop } }
    )
  end)

  it("names the path of a problem in a submenu", function()
    refuses("menu[2].entries[1].text must be a non-empty string", {
      { kind = "title", text = "T" },
      { kind = "button", text = "Sub", entries = { { kind = "button" } } },
    })
    refuses(
      "menu[1].entries must be an array of entries",
      { { kind = "button", text = "Sub", entries = "none" } }
    )
  end)

  it("refuses an entry array that contains itself", function()
    local entries = { { kind = "button", text = "Loop" } }
    entries[1].entries = entries
    MenuKit:SetLimits({ maxDepth = MenuKit.UNBOUNDED })
    refuses("menu[1].entries contains itself", entries)
  end)

  it("accepts the same entry array twice in one menu", function()
    local shared = { { kind = "button", text = "Shared" } }
    MenuKit:OpenContextMenu(nil, {
      { kind = "button", text = "A", entries = shared },
      { kind = "button", text = "B", entries = shared },
    })
    assert.are.equal(1, #api.contextMenus)
  end)

  it("checks the menu each public method receives", function()
    TestEnv.expectErrorContaining(
      "MenuKit:SetupDropdown menu[1].text must be a non-empty string",
      function()
        MenuKit:SetupDropdown(api.NewDropdown(), { { kind = "button" } })
      end
    )
    TestEnv.expectErrorContaining("MenuKit:ExtendMenu menu must be an array of entries", function()
      MenuKit:ExtendMenu("MENU_UNIT_SELF", 1)
    end)
  end)

  it("checks the owner, the dropdown and the tag", function()
    TestEnv.expectErrorContaining("MenuKit:OpenContextMenu owner must be a frame or nil", function()
      MenuKit:OpenContextMenu("UIParent", {})
    end)
    TestEnv.expectErrorContaining(
      "MenuKit:SetupDropdown dropdown must be a DropdownButton",
      function()
        MenuKit:SetupDropdown({}, {})
      end
    )
    TestEnv.expectErrorContaining("MenuKit:ExtendMenu tag must be a non-empty string", function()
      MenuKit:ExtendMenu("", {})
    end)
  end)

  it("refuses a facade method called without the facade", function()
    for _, call in ipairs({
      function()
        MenuKit.OpenContextMenu({}, nil, {})
      end,
      function()
        MenuKit.SetupDropdown(nil, api.NewDropdown(), {})
      end,
      function()
        MenuKit.ExtendMenu("MenuKit", "MENU_UNIT_SELF", {})
      end,
      function()
        MenuKit.CloseMenus({})
      end,
      function()
        MenuKit.SetLimits({}, {})
      end,
      function()
        MenuKit.GetLimits(1)
      end,
    }) do
      TestEnv.expectErrorContaining("must be called on the MenuKit facade", call)
    end
  end)
end)
