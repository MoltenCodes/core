local TestEnv = require("MenuKitTestEnv")

describe("MenuKit extensions", function()
  local MenuKit, api
  before_each(function()
    MenuKit, api = TestEnv.NewPackage()
    TestEnv.InstallHostErrorHandler()
  end)
  after_each(TestEnv.Reset)

  it("adds entries after Blizzard's own every time the tagged menu opens", function()
    local extension = MenuKit:ExtendMenu("MENU_UNIT_SELF", {
      { kind = "divider" },
      { kind = "title", text = "My Addon" },
    })
    assert.is_true(extension:IsActive())
    local root = api.OpenTagged("MENU_UNIT_SELF", {}, {})
    assert.are.same({ "button:Blizzard's own line", "divider", "title:My Addon" }, root:Outline())
    assert.are.same(
      { "button:Blizzard's own line" },
      api.OpenTagged("MENU_UNIT_PARTY", {}, {}):Outline()
    )
  end)

  it("hands a menu function the owner and Blizzard's context data", function()
    local seen = {}
    local owner = {}
    local contextData = { unit = "target", name = "Someone" }
    MenuKit:ExtendMenu("MENU_UNIT_TARGET", function(receivedOwner, receivedData)
      seen[#seen + 1] = { receivedOwner, receivedData }
      return { { kind = "button", text = "Whisper " .. receivedData.name } }
    end)
    local root = api.OpenTagged("MENU_UNIT_TARGET", owner, contextData)
    assert.are.same({ "button:Blizzard's own line", "button:Whisper Someone" }, root:Outline())
    assert.are.equal(owner, seen[1][1])
    assert.are.equal(contextData, seen[1][2])
  end)

  it("removes an extension once, and it is not called again", function()
    local extension = MenuKit:ExtendMenu("MENU_UNIT_SELF", { { kind = "title", text = "Mine" } })
    assert.is_true(extension:Remove())
    assert.is_false(extension:IsActive())
    assert.is_false(extension:Remove())
    assert.are.equal(0, api.CallbackCount("MENU_UNIT_SELF"))
    assert.are.same(
      { "button:Blizzard's own line" },
      api.OpenTagged("MENU_UNIT_SELF", {}, {}):Outline()
    )
  end)

  it(
    "reports a handle that fails to unregister and still counts the extension as removed",
    function()
      rawset(api.Menu, "ModifyMenu", function()
        return {
          Unregister = function()
            error("unregister failed", 0)
          end,
        }
      end)
      local extension = MenuKit:ExtendMenu("MENU_UNIT_SELF", {})
      assert.is_true(extension:Remove())
      assert.are.same({ "unregister failed" }, TestEnv.TakeReportedValues())
      assert.is_false(extension:IsActive())
    end
  )

  it("fills the last menu Blizzard generated under the tag at once, as ModifyMenu does", function()
    local opened = api.OpenTagged("MENU_UNIT_SELF", {}, { unit = "player" })
    local seen = nil
    MenuKit:ExtendMenu("MENU_UNIT_SELF", function(_, contextData)
      seen = contextData
      return { { kind = "title", text = "Mine" } }
    end)
    assert.are.same({ unit = "player" }, seen)
    assert.are.same({ "button:Blizzard's own line", "title:Mine" }, opened:Outline())
  end)

  it("holds at most maxExtensions and frees a slot on Remove", function()
    MenuKit:SetLimits({ maxExtensions = 2 })
    local first = MenuKit:ExtendMenu("MENU_UNIT_SELF", {})
    MenuKit:ExtendMenu("MENU_UNIT_PARTY", {})
    TestEnv.expectErrorContaining(
      "MenuKit:ExtendMenu holds at most 2 extensions; remove one, or raise maxExtensions with MenuKit:SetLimits",
      function()
        MenuKit:ExtendMenu("MENU_UNIT_RAID", {})
      end
    )
    assert.are.equal(0, api.CallbackCount("MENU_UNIT_RAID"))
    first:Remove()
    MenuKit:ExtendMenu("MENU_UNIT_RAID", {})
    assert.are.equal(1, api.CallbackCount("MENU_UNIT_RAID"))
  end)

  it("refuses an extension method called on anything else", function()
    local extension = MenuKit:ExtendMenu("MENU_UNIT_SELF", {})
    TestEnv.expectErrorContaining(
      "MenuKit.Extension:Remove must be called on a MenuKit extension",
      function()
        extension.Remove({})
      end
    )
    TestEnv.expectErrorContaining(
      "MenuKit.Extension:IsActive must be called on a MenuKit extension",
      function()
        extension.IsActive(nil)
      end
    )
    assert.are.equal("MenuKit.Extension", getmetatable(extension))
  end)
end)
