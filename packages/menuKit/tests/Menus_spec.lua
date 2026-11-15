local TestEnv = require("MenuKitTestEnv")

describe("MenuKit menus", function()
  local MenuKit, api
  before_each(function()
    MenuKit, api = TestEnv.NewPackage()
    TestEnv.InstallHostErrorHandler()
  end)
  after_each(TestEnv.Reset)

  local owner = { name = "owner" }

  it("builds every kind of entry into Blizzard's description, in order", function()
    local selected = { a = true }
    MenuKit:OpenContextMenu(owner, {
      { kind = "title", text = "My Addon" },
      { kind = "button", text = "Open", onClick = function() end },
      { kind = "divider" },
      {
        kind = "checkbox",
        text = "Locked",
        data = "a",
        isSelected = function(key)
          return selected[key]
        end,
        setSelected = function(key)
          selected[key] = not selected[key]
        end,
      },
      {
        kind = "radio",
        text = "Small",
        data = "b",
        isSelected = function(key)
          return selected[key]
        end,
        setSelected = function() end,
      },
      { kind = "spacer" },
    })
    local root = api.contextMenus[1]
    assert.are.equal(owner, root.owner)
    assert.are.same(
      { "title:My Addon", "button:Open", "divider", "checkbox:Locked", "radio:Small", "spacer" },
      root:Outline()
    )
    local checkbox, radio = root.children[4], root.children[5]
    assert.are.equal("a", checkbox.data)
    assert.is_true(checkbox.isSelected("a"))
    assert.is_false(radio.isSelected("b"))
    checkbox:Click()
    assert.is_false(selected.a)
    assert.is_false(checkbox.isSelected("a"))
  end)

  it("runs a button's onClick with its data", function()
    local clicked = {}
    MenuKit:OpenContextMenu(owner, {
      {
        kind = "button",
        text = "Pick",
        data = 7,
        onClick = function(data)
          clicked[#clicked + 1] = data
        end,
      },
    })
    api.contextMenus[1].children[1]:Click()
    assert.are.same({ 7 }, clicked)
  end)

  it("builds submenus below a button", function()
    MenuKit:OpenContextMenu(owner, {
      {
        kind = "button",
        text = "Size",
        entries = {
          { kind = "button", text = "Small" },
          { kind = "button", text = "Large", entries = { { kind = "title", text = "Deep" } } },
        },
      },
    })
    local size = api.contextMenus[1].children[1]
    assert.is_nil(size.responder)
    assert.are.same({ "button:Small", "button:Large" }, size:Outline())
    assert.are.same({ "title:Deep" }, size.children[2]:Outline())
  end)

  it("gives a line its enabled state and tooltip", function()
    local locked = true
    MenuKit:OpenContextMenu(owner, {
      { kind = "button", text = "Off", disabled = true },
      { kind = "button", text = "On", disabled = false, tooltip = "Turns it on." },
      {
        kind = "button",
        text = "Polled",
        data = "x",
        disabled = function(data)
          assert.are.equal("x", data)
          return locked
        end,
      },
      { kind = "button", text = "Plain" },
    })
    local children = api.contextMenus[1].children
    assert.is_false(children[1]:IsEnabled())
    assert.is_true(children[2]:IsEnabled())
    assert.are.equal("Turns it on.", children[2]:TooltipText())
    assert.is_false(children[3]:IsEnabled())
    locked = false
    assert.is_true(children[3]:IsEnabled())
    assert.is_nil(children[4].enabled)
    assert.is_nil(children[4].tooltip)
  end)

  it("calls a menu function each time the menu opens, with the owner", function()
    local count = 0
    local function menu(receivedOwner)
      assert.are.equal(owner, receivedOwner)
      count = count + 1
      return { { kind = "title", text = "Opened " .. count } }
    end
    MenuKit:OpenContextMenu(owner, menu)
    MenuKit:OpenContextMenu(owner, menu)
    assert.are.same({ "title:Opened 1" }, api.contextMenus[1]:Outline())
    assert.are.same({ "title:Opened 2" }, api.contextMenus[2]:Outline())
  end)

  it("reads an entry array again at every opening", function()
    local dropdown = api.NewDropdown()
    local entries = { { kind = "button", text = "First" } }
    MenuKit:SetupDropdown(dropdown, entries)
    assert.are.same({ "button:First" }, dropdown:Open():Outline())
    entries[2] = { kind = "button", text = "Second" }
    assert.are.same({ "button:First", "button:Second" }, dropdown:Open():Outline())
  end)

  it("reports callbacks that raise and keeps the menu working", function()
    local function failing()
      error("callback failed", 0)
    end
    MenuKit:OpenContextMenu(owner, {
      { kind = "button", text = "Click", onClick = failing, disabled = failing },
      { kind = "checkbox", text = "Box", isSelected = failing, setSelected = failing },
    })
    local children = api.contextMenus[1].children
    children[1]:Click()
    assert.is_true(children[1]:IsEnabled())
    assert.is_false(children[2].isSelected())
    children[2]:Click()
    assert.are.same(
      { "callback failed", "callback failed", "callback failed", "callback failed" },
      TestEnv.TakeReportedValues()
    )
  end)

  it(
    "reports a menu function that raises or returns a bad menu, and leaves the menu empty",
    function()
      MenuKit:OpenContextMenu(owner, function()
        error("menu failed", 0)
      end)
      MenuKit:OpenContextMenu(owner, function()
        return { { kind = "button" } }
      end)
      MenuKit:OpenContextMenu(owner, function()
        return "entries"
      end)
      assert.are.same({}, api.contextMenus[1].children)
      assert.are.same({}, api.contextMenus[2].children)
      assert.are.same({
        "menu failed",
        "MenuKit menu[1].text must be a non-empty string",
        "MenuKit menu must be an array of entries",
      }, TestEnv.TakeReportedValues())
    end
  )

  it("reports a failure while building and keeps what was added", function()
    rawset(api.MenuUtil, "CreateContextMenu", function(menuOwner, generator)
      local root = { children = {} }
      function root.CreateTitle()
        error("CreateTitle failed", 0)
      end
      generator(menuOwner, root)
      return root
    end)
    MenuKit:OpenContextMenu(owner, { { kind = "title", text = "T" } })
    assert.are.same({ "CreateTitle failed" }, TestEnv.TakeReportedValues())
  end)

  it("opens a context menu without an owner", function()
    MenuKit:OpenContextMenu(nil, { { kind = "title", text = "Nowhere" } })
    assert.is_nil(api.contextMenus[1].owner)
  end)

  it("closes every menu", function()
    MenuKit:CloseMenus()
    assert.are.equal(1, api.closed)
  end)

  it("refuses to work without Blizzard's Menu API", function()
    TestEnv.SetGlobal("Menu", nil)
    for _, call in ipairs({
      function()
        MenuKit:OpenContextMenu(owner, {})
      end,
      function()
        MenuKit:SetupDropdown(api.NewDropdown(), {})
      end,
      function()
        MenuKit:ExtendMenu("MENU_UNIT_SELF", {})
      end,
      function()
        MenuKit:CloseMenus()
      end,
    }) do
      TestEnv.expectErrorContaining("needs the client's Menu API (Blizzard_Menu)", call)
    end
  end)
end)
