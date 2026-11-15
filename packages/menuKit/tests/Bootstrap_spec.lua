local TestEnv = require("MenuKitTestEnv")

describe("MenuKit bootstrap", function()
  after_each(TestEnv.Reset)

  it("publishes through Registry", function()
    local MenuKit, _, Registry = TestEnv.NewPackage()
    local registered, revision = Registry:Get("menuKit", 1)
    assert.are.equal(MenuKit, registered)
    assert.are.equal(MenuKit.REVISION, revision)
  end)

  it("returns the same facade on a duplicate embedded load and keeps its extensions", function()
    local MenuKit = TestEnv.NewPackage()
    local extension = MenuKit:ExtendMenu("MENU_UNIT_SELF", {})
    local reloaded = TestEnv.ReloadPackage()
    assert.are.equal(MenuKit, reloaded)
    assert.is_true(extension:IsActive())
  end)

  it("does not reinterpret private state owned by a newer compatible revision", function()
    local MenuKit, _, Registry = TestEnv.NewPackage()
    local shippedRevision = MenuKit.REVISION
    local upgraded, previous = Registry:Register("menuKit", 1, 99)
    assert.are.equal(MenuKit, upgraded)
    assert.are.equal(shippedRevision, previous)

    rawset(MenuKit, "REVISION", 99)
    rawset(MenuKit, "_state", { schema = 999 })
    package.loaded["MenuKit"] = nil
    local reloaded = require("MenuKit")
    assert.are.equal(MenuKit, reloaded)
    assert.are.equal(99, reloaded.REVISION)
  end)

  it(
    "upgrades in place: limits, the sentinel, extensions and generators handed out before run the new code",
    function()
      local MenuKit, api = TestEnv.NewPackage()
      local unbounded = MenuKit.UNBOUNDED
      MenuKit:SetLimits({ maxEntries = unbounded, maxExtensions = 100 })
      local dropdown = api.NewDropdown()
      MenuKit:SetupDropdown(dropdown, { { kind = "title", text = "Before" } })
      local extension = MenuKit:ExtendMenu("MENU_UNIT_SELF", { { kind = "title", text = "Mine" } })

      local nextRevision = MenuKit.REVISION + 1
      local upgraded = TestEnv.LoadRevision(nextRevision)
      assert.are.equal(MenuKit, upgraded)
      assert.are.equal(nextRevision, upgraded.REVISION)
      assert.are.equal(unbounded, upgraded.UNBOUNDED)
      assert.are.same(
        { maxEntries = unbounded, maxDepth = 4, maxExtensions = 100 },
        upgraded:GetLimits()
      )

      assert.are.same({ "title:Before" }, dropdown:Open():Outline())
      assert.are.same(
        { "button:Blizzard's own line", "title:Mine" },
        api.OpenTagged("MENU_UNIT_SELF", {}, {}):Outline()
      )
      assert.is_true(extension:IsActive())
      assert.is_true(extension:Remove())
      assert.are.equal(0, api.CallbackCount("MENU_UNIT_SELF"))
    end
  )

  it(
    "upgrades from revision 1 in place: its dropdowns and extensions are built by this revision",
    function()
      -- Install the host stand-ins, then start over with a copy carrying
      -- revision 1, the way an older addon's embedded copy loads first.
      local _, api = TestEnv.NewPackage()
      TestEnv.SetGlobal("MoltenCodes", nil)
      package.loaded.Registry = nil
      package.loaded.MenuKit = nil
      require("Registry")
      local old = TestEnv.LoadRevision(1)
      local dropdown = api.NewDropdown()
      old:SetupDropdown(dropdown, { { kind = "title", text = "Before" } })
      local extension = old:ExtendMenu("MENU_UNIT_SELF", { { kind = "title", text = "Mine" } })

      local upgraded = TestEnv.ReloadPackage()
      assert.are.equal(old, upgraded)
      assert.is_true(upgraded.REVISION > 1)
      assert.are.same({ "title:Before" }, dropdown:Open():Outline())
      assert.are.same(
        { "button:Blizzard's own line", "title:Mine" },
        api.OpenTagged("MENU_UNIT_SELF", {}, {}):Outline()
      )
      assert.is_true(extension:Remove())
    end
  )

  it("refuses shared state whose limits hold an invalid value", function()
    local MenuKit = TestEnv.NewPackage()
    rawset(MenuKit._state.limits, "maxExtensions", MenuKit.UNBOUNDED)
    TestEnv.expectErrorContaining("package state is corrupted or incomplete", function()
      TestEnv.ReloadPackage()
    end)
  end)

  it("requires Registry", function()
    TestEnv.Reset()
    TestEnv.InstallWowApi()
    local ok, value = pcall(require, "MenuKit")
    assert.is_false(ok)
    assert.is_truthy(tostring(value):find("Registry API 2", 1, true))
  end)

  it("refuses an incomplete facade left by an earlier failed load", function()
    TestEnv.Reset()
    TestEnv.InstallWowApi()
    local Registry = require("Registry")
    Registry:Register("menuKit", 1, 1)
    local ok, value = pcall(TestEnv.requireAfterFailedLoad, "MenuKit")
    assert.is_false(ok)
    assert.is_truthy(tostring(value):find("MoltenCodes MenuKit", 1, true))
  end)
end)
