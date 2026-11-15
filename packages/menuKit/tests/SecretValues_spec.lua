local TestEnv = require("MenuKitTestEnv")

describe("MenuKit secret values", function()
  local MenuKit, api, secret
  before_each(function()
    MenuKit, api = TestEnv.NewPackage()
    TestEnv.InstallSecretProbe()
    secret = TestEnv.NewSecret()
  end)
  after_each(TestEnv.Reset)

  it("refuses a secret text, tooltip, kind, field name, entry or menu", function()
    local cases = {
      { "menu[1].text must not be a secret value", { { kind = "button", text = secret } } },
      {
        "menu[1].tooltip must not be a secret value",
        { { kind = "button", text = "B", tooltip = secret } },
      },
      { 'menu[1].kind must be "button"', { { kind = secret } } },
      {
        "menu[1] holds the field <secret value>, which a button does not take",
        { { kind = "button", text = "B", [secret] = true } },
      },
      { "menu[1] must be an entry table", { secret } },
      { "menu must be an array of entries", secret },
    }
    for _, case in ipairs(cases) do
      TestEnv.expectErrorContaining("MenuKit:OpenContextMenu " .. case[1], function()
        MenuKit:OpenContextMenu(nil, case[2])
      end)
    end
    assert.are.equal(0, #api.contextMenus)
  end)

  it("passes a secret data value through to the callbacks untouched", function()
    local received = nil
    MenuKit:OpenContextMenu(nil, {
      {
        kind = "button",
        text = "B",
        data = secret,
        onClick = function(data)
          received = data
        end,
      },
    })
    api.contextMenus[1].children[1]:Click()
    assert.are.equal(secret, received)
  end)

  it("refuses a secret owner, dropdown, tag, receiver and limits", function()
    TestEnv.expectErrorContaining("MenuKit:OpenContextMenu owner must be a frame or nil", function()
      MenuKit:OpenContextMenu(secret, {})
    end)
    TestEnv.expectErrorContaining(
      "MenuKit:SetupDropdown dropdown must be a DropdownButton",
      function()
        MenuKit:SetupDropdown(secret, {})
      end
    )
    TestEnv.expectErrorContaining("MenuKit:ExtendMenu tag must not be a secret value", function()
      MenuKit:ExtendMenu(secret, {})
    end)
    TestEnv.expectErrorContaining("must be called on the MenuKit facade", function()
      MenuKit.GetLimits(secret)
    end)
    TestEnv.expectErrorContaining("MenuKit:SetLimits limits must be a table", function()
      MenuKit:SetLimits(secret)
    end)
    TestEnv.expectErrorContaining("MenuKit:SetLimits limits holds an unknown field", function()
      MenuKit:SetLimits({ [secret] = 1 })
    end)
    TestEnv.expectErrorContaining(
      "MenuKit:SetLimits limits.maxDepth must not be a secret value",
      function()
        MenuKit:SetLimits({ maxDepth = secret })
      end
    )
    local extension = MenuKit:ExtendMenu("MENU_UNIT_SELF", {})
    TestEnv.expectErrorContaining(
      "MenuKit.Extension:Remove must be called on a MenuKit extension",
      function()
        extension.Remove(secret)
      end
    )
  end)
end)
