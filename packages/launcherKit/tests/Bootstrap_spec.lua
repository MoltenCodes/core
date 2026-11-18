local TestEnv = require("LauncherKitTestEnv")

describe("LauncherKit bootstrap", function()
  after_each(TestEnv.Reset)

  it("publishes through Registry", function()
    local LauncherKit, _, Registry = TestEnv.NewPackage()
    local registered, revision = Registry:Get("launcherKit", 1)
    assert.are.equal(LauncherKit, registered)
    assert.are.equal(LauncherKit.REVISION, revision)
  end)

  it("returns the same facade on a duplicate embedded load and keeps its launchers", function()
    local LauncherKit, BrokerKit = TestEnv.NewPackage()
    BrokerKit:New("MyAddon")
    local launcher = LauncherKit:Register("MyAddon", {})
    local reloaded = TestEnv.ReloadPackage()
    assert.are.equal(LauncherKit, reloaded)
    assert.are.equal(launcher, reloaded:Get("MyAddon"))
  end)

  it("does not reinterpret private state owned by a newer compatible revision", function()
    local LauncherKit, _, Registry = TestEnv.NewPackage()
    local shippedRevision = LauncherKit.REVISION
    local upgraded, previous = Registry:Register("launcherKit", 1, 99)
    assert.are.equal(LauncherKit, upgraded)
    assert.are.equal(shippedRevision, previous)

    rawset(LauncherKit, "REVISION", 99)
    rawset(LauncherKit, "_state", { schema = 999 })
    package.loaded["LauncherKit"] = nil
    local reloaded = require("LauncherKit")
    assert.are.equal(LauncherKit, reloaded)
    assert.are.equal(99, reloaded.REVISION)
  end)

  it(
    "upgrades in place: buttons, connections, the compartment and the limit run the new code",
    function()
      local LauncherKit, BrokerKit = TestEnv.NewPackage()
      local frame = TestEnv.InstallCompartment()
      local clicks = 0
      local object = BrokerKit:New("MyAddon", {
        icon = 1,
        OnClick = function()
          clicks = clicks + 1
        end,
      })
      local storage = {}
      local launcher = LauncherKit:Register("MyAddon", storage)
      LauncherKit:AddToCompartment("MyAddon")
      LauncherKit:SetLimits({ maxLaunchers = 100 })

      local upgraded = TestEnv.LoadRevision(LauncherKit.REVISION + 1)
      assert.are.equal(LauncherKit, upgraded)
      assert.are.equal(launcher, upgraded:Get("MyAddon"))
      assert.are.equal(100, upgraded:GetLimits().maxLaunchers)
      assert.are.same({ nil, "already" }, { upgraded:AddToCompartment("MyAddon") })

      local button = launcher:GetButton()
      TestEnv.Run(button, "OnClick", "LeftButton")
      frame.registered[1].func(nil, { buttonName = "LeftButton" })
      assert.are.equal(2, clicks)
      object.icon = 2
      assert.are.equal(2, button.icon:GetTexture())
      TestEnv.Run(button, "OnDragStart")
      TestEnv.SetCursor(TestEnv.MINIMAP_X + 300, TestEnv.MINIMAP_Y)
      TestEnv.Run(button, "OnUpdate", 0.016)
      TestEnv.Run(button, "OnDragStop")
      assert.are.equal(0, storage.minimapPos)
    end
  )

  it("upgrades a revision 1 copy in place to this revision", function()
    -- Revision 2 changed only how SetLimits reads its argument; the state
    -- schema is the same, so a revision 1 state is taken over as it is.
    TestEnv.Reset()
    TestEnv.InstallWowApi()
    local Registry = require("Registry")
    require("SignalKit")
    local BrokerKit = require("BrokerKit")
    local createFrame = TestEnv.GetGlobal("CreateFrame")
    local minimap = createFrame("Frame", "Minimap", createFrame("Frame", "UIParent"))
    minimap:SetSize(TestEnv.MINIMAP_SIZE, TestEnv.MINIMAP_SIZE)
    local old = TestEnv.LoadRevision(1)
    assert.are.equal(1, old.REVISION)
    BrokerKit:New("MyAddon", { icon = 1 })
    local storage = { minimapPos = 0 }
    local launcher = old:Register("MyAddon", storage)

    package.loaded["LauncherKit"] = nil
    local current = require("LauncherKit")
    assert.are.equal(old, current)
    assert.are.equal(3, current.REVISION)
    assert.are.equal(3, select(2, Registry:Get("launcherKit", 1)))
    assert.are.equal(launcher, current:Get("MyAddon"))
    launcher:Hide()
    assert.is_true(storage.hide)
    current:SetLimits(setmetatable({}, { __index = { maxLaunchers = 100000 } }))
    assert.are.equal(64, current:GetLimits().maxLaunchers)
  end)

  it("refuses shared state whose limit holds an invalid value", function()
    local LauncherKit = TestEnv.NewPackage()
    rawset(LauncherKit._state.limits, "maxLaunchers", 257)
    TestEnv.expectErrorContaining("package state is corrupted or incomplete", function()
      TestEnv.ReloadPackage()
    end)
  end)

  it("requires Registry", function()
    TestEnv.Reset()
    TestEnv.InstallWowApi()
    local ok, value = pcall(require, "LauncherKit")
    assert.is_false(ok)
    assert.is_truthy(tostring(value):find("Registry API 2", 1, true))
  end)

  it("requires BrokerKit", function()
    TestEnv.Reset()
    TestEnv.InstallWowApi()
    require("Registry")
    require("SignalKit")
    local ok, value = pcall(TestEnv.requireAfterFailedLoad, "LauncherKit")
    assert.is_false(ok)
    assert.is_truthy(tostring(value):find("BrokerKit API 1", 1, true))
  end)

  it("refuses an incomplete facade left by an earlier failed load", function()
    TestEnv.Reset()
    TestEnv.InstallWowApi()
    local Registry = require("Registry")
    require("SignalKit")
    require("BrokerKit")
    Registry:Register("launcherKit", 1, 1)
    local ok, value = pcall(TestEnv.requireAfterFailedLoad, "LauncherKit")
    assert.is_false(ok)
    assert.is_truthy(tostring(value):find("MoltenCodes LauncherKit", 1, true))
  end)
end)
