local TestEnv = require("EditModeKitTestEnv")

describe("EditModeKit bootstrap", function()
  after_each(TestEnv.Reset)

  it("publishes through Registry", function()
    local EditModeKit, Registry = TestEnv.NewPackage()
    local registered, revision = Registry:Get("editModeKit", 1)
    assert.are.equal(EditModeKit, registered)
    assert.are.equal(EditModeKit.REVISION, revision)
  end)

  it("returns the same facade on a duplicate embedded load and keeps its frames", function()
    local EditModeKit = TestEnv.NewPackage()
    local registration = EditModeKit:Register(TestEnv.FrameAt(0, 0), {})
    local reloaded = TestEnv.ReloadPackage()
    assert.are.equal(EditModeKit, reloaded)
    assert.is_true(registration:Unregister())
  end)

  it("does not reinterpret private state owned by a newer compatible revision", function()
    local EditModeKit, Registry = TestEnv.NewPackage()
    local shippedRevision = EditModeKit.REVISION
    local upgraded, previous = Registry:Register("editModeKit", 1, 99)
    assert.are.equal(EditModeKit, upgraded)
    assert.are.equal(shippedRevision, previous)

    rawset(EditModeKit, "REVISION", 99)
    rawset(EditModeKit, "_state", { schema = 999 })
    package.loaded["EditModeKit"] = nil
    local reloaded = require("EditModeKit")
    assert.are.equal(EditModeKit, reloaded)
    assert.are.equal(99, reloaded.REVISION)
  end)

  it(
    "upgrades in place: Edit Mode callbacks, events, drags and the limit run the new code",
    function()
      local EditModeKit = TestEnv.NewPackage()
      local storage = {}
      local frame = TestEnv.FrameAt(300, 300)
      local registration = EditModeKit:Register(frame, storage)
      EditModeKit:SetLimits({ maxRegistrations = 100 })
      local overlay = rawget(registration, "_record").overlay

      local upgraded = TestEnv.LoadRevision(EditModeKit.REVISION + 1)
      assert.are.equal(EditModeKit, upgraded)
      assert.are.equal(100, upgraded:GetLimits().maxRegistrations)
      TestEnv.EnterEditMode()
      assert.is_true(overlay:IsShown())
      TestEnv.Run(overlay, "OnDragStart")
      TestEnv.Run(overlay, "OnDragStop")
      assert.are.same({ x = -660, y = -240 }, storage.Modern)
      storage.Raid = { x = 1, y = 2 }
      TestEnv.SwitchLayout("Raid")
      assert.are.same({ "CENTER", TestEnv.GetGlobal("UIParent"), "CENTER", 1, 2 }, {
        frame:GetPoint(1),
      })
      assert.are.equal(1, TestEnv.GetGlobal("EventRegistry"):CallbackCount("EditMode.Enter"))
      assert.is_true(registration:Unregister())
    end
  )

  it(
    "upgrades revision 1 in place: a drag under way ends when its frame is unregistered",
    function()
      -- Install the host stand-ins, then start over with a copy carrying
      -- revision 1, the way an older addon's embedded copy loads first.
      TestEnv.NewPackage()
      TestEnv.SetGlobal("MoltenCodes", nil)
      package.loaded.Registry = nil
      package.loaded.EditModeKit = nil
      require("Registry")
      local old = TestEnv.LoadRevision(1)
      local storage = {}
      local frame = TestEnv.FrameAt(300, 300)
      local registration = old:Register(frame, storage)
      TestEnv.EnterEditMode()
      TestEnv.Run(rawget(registration, "_record").overlay, "OnDragStart")

      local upgraded = TestEnv.ReloadPackage()
      assert.are.equal(old, upgraded)
      assert.is_true(upgraded.REVISION > 1)
      assert.is_true(frame.moving)
      assert.is_true(registration:Unregister())
      assert.is_nil(frame.moving)
      assert.are.same({}, storage)
    end
  )

  it("reads whether Edit Mode is already open when it first listens", function()
    local EditModeKit = TestEnv.NewPackage()
    TestEnv.GetGlobal("EditModeManagerFrame").IsEditModeActive = function()
      return true
    end
    local registration = EditModeKit:Register(TestEnv.FrameAt(0, 0), {})
    assert.is_true(EditModeKit:IsEditing())
    assert.is_true(rawget(registration, "_record").overlay:IsShown())
  end)

  it("refuses shared state whose limit holds an invalid value", function()
    local EditModeKit = TestEnv.NewPackage()
    rawset(EditModeKit._state.limits, "maxRegistrations", 257)
    TestEnv.expectErrorContaining("package state is corrupted or incomplete", function()
      TestEnv.ReloadPackage()
    end)
  end)

  it("requires Registry", function()
    TestEnv.Reset()
    TestEnv.InstallWowApi()
    local ok, value = pcall(require, "EditModeKit")
    assert.is_false(ok)
    assert.is_truthy(tostring(value):find("Registry API 2", 1, true))
  end)

  it("refuses an incomplete facade left by an earlier failed load", function()
    TestEnv.Reset()
    TestEnv.InstallWowApi()
    local Registry = require("Registry")
    Registry:Register("editModeKit", 1, 1)
    local ok, value = pcall(TestEnv.requireAfterFailedLoad, "EditModeKit")
    assert.is_false(ok)
    assert.is_truthy(tostring(value):find("MoltenCodes EditModeKit", 1, true))
  end)
end)
