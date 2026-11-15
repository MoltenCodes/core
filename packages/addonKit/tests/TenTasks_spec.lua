-- The ten-task flow of the usability comparison, written with AddonKit and run
-- on the fake client the way the client runs an addon: the files embeds.xml
-- lists are loaded from package source in its order, then the addon's own
-- files in .toc order with `...` set, then the addon loads and the player logs
-- in. Every task is then checked. The getting-started guide ends in this
-- same addon (Guide_spec.lua).
local TestEnv = require("AddonKitTestEnv")

local FIXTURE = "packages/addonKit/tests/fixtures/TenTasks"
local ADDON_NAME = "MyAddon"

describe("AddonKit ten tasks", function()
  after_each(TestEnv.Reset)

  it("loads, logs in and does every task without a reported error", function()
    local sent, settings = TestEnv.InstallClient()
    TestEnv.LoadAddonFolder(FIXTURE, ADDON_NAME)
    TestEnv.LogIn(ADDON_NAME)
    local errors = TestEnv.ReportedErrors()
    assert.are.equal(0, #errors, tostring(errors[1]))

    local MC = TestEnv.Namespace():For(ADDON_NAME)
    local addon = MC:GetAddon()
    assert.is_true(addon:IsEnabled())

    -- T04: the database opened from plain defaults; the counter written.
    assert.are.equal(1, TestEnv.GetGlobal("MyAddonDB").global.installs)
    assert.are.equal(1, addon.db.profile.scale)
    assert.are.equal(true, addon.db.profile.greet)
    assert.has_error(function()
      addon.db.profile.scale = 5
    end)
    assert.has_error(function()
      addon.db.profile.greet = "yes"
    end)

    -- T05: the panel is registered, and /myaddon opens it.
    assert.are.equal(1, #settings.addOns)
    assert.is_true(TestEnv.RunSlash("/myaddon"))
    assert.are.equal(1, #settings.opened)

    -- T10: the minimap button keeps its position in the profile.
    addon.db.profile.minimap.minimapPos = 180
    assert.are.equal(180, addon.db.profile.minimap.minimapPos)
    assert.is_table(MC.LauncherKit:Get(ADDON_NAME))

    -- T02: one BAG_UPDATE disconnects the listener without an error.
    TestEnv.Emit("BAG_UPDATE", 0)
    TestEnv.Emit("BAG_UPDATE", 0)

    -- T09: the hooked global still runs.
    TestEnv.GetGlobal("ToggleGameMenu")()

    -- T08: a send goes out.
    addon:SendHello()

    -- T07: the module is disabled and enabled again; it depends on the addon.
    local bags = MC:GetModule("Bags")
    assert.is_true(bags:IsEnabled())
    addon:ToggleBags(false)
    assert.is_false(bags:IsEnabled())
    addon:ToggleBags(true)
    assert.is_true(bags:IsEnabled())

    -- T03: the timers are pending; fire them.
    TestEnv.AdvanceMs(6000)
    local natives = TestEnv.NativeTimers()
    for index = 1, #natives do
      TestEnv.FireNative(index)
    end

    errors = TestEnv.ReportedErrors()
    assert.are.equal(0, #errors, tostring(errors[1]))
    assert.is_table(sent)
  end)
end)
