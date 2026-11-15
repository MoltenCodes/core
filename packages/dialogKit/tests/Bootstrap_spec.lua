local TestEnv = require("DialogKitTestEnv")

describe("DialogKit bootstrap", function()
  after_each(TestEnv.Reset)

  it("publishes through Registry", function()
    local DialogKit, Registry = TestEnv.NewPackage()
    local registered, revision = Registry:Get("dialogKit", 1)
    assert.are.equal(DialogKit, registered)
    assert.are.equal(DialogKit.REVISION, revision)
  end)

  it("returns the same facade on a duplicate embedded load and keeps its dialogs", function()
    local DialogKit = TestEnv.NewPackage()
    local dialog = DialogKit:Show({ text = "x" })
    local reloaded = TestEnv.ReloadPackage()
    assert.are.equal(DialogKit, reloaded)
    assert.is_true(dialog:IsShown())
  end)

  it("does not reinterpret private state owned by a newer compatible revision", function()
    local DialogKit, Registry = TestEnv.NewPackage()
    local shippedRevision = DialogKit.REVISION
    local upgraded, previous = Registry:Register("dialogKit", 1, 99)
    assert.are.equal(DialogKit, upgraded)
    assert.are.equal(shippedRevision, previous)

    rawset(DialogKit, "REVISION", 99)
    rawset(DialogKit, "_state", { schema = 999 })
    package.loaded["DialogKit"] = nil
    local reloaded = require("DialogKit")
    assert.are.equal(DialogKit, reloaded)
    assert.are.equal(99, reloaded.REVISION)
  end)

  it(
    "upgrades in place: the frame, the queue, the limit and the sentinel run the new code",
    function()
      local DialogKit = TestEnv.NewPackage()
      local accepted = 0
      local unbounded = DialogKit.UNBOUNDED
      DialogKit:SetLimits({ maxQueued = unbounded })
      DialogKit:Show({
        text = "first",
        onAccept = function()
          accepted = accepted + 1
        end,
      })
      local waiting = DialogKit:Show({ text = "second" })
      local frame = TestEnv.GetGlobal(DialogKit.FRAME_NAME)

      local upgraded = TestEnv.LoadRevision(DialogKit.REVISION + 1)
      assert.are.equal(DialogKit, upgraded)
      assert.are.equal(unbounded, upgraded.UNBOUNDED)
      assert.are.equal(unbounded, upgraded:GetLimits().maxQueued)
      TestEnv.Run(frame.acceptButton, "OnClick", "LeftButton")
      assert.are.equal(1, accepted)
      assert.is_true(waiting:IsShown())
      TestEnv.PressEscape()
      assert.is_false(frame:IsShown())
      assert.are.equal(2, #TestEnv.GetGlobal("UISpecialFrames"))
    end
  )

  it("refuses shared state whose limit holds an invalid value", function()
    local DialogKit = TestEnv.NewPackage()
    rawset(DialogKit._state.limits, "maxQueued", 0)
    TestEnv.expectErrorContaining("package state is corrupted or incomplete", function()
      TestEnv.ReloadPackage()
    end)
  end)

  it("requires Registry", function()
    TestEnv.Reset()
    TestEnv.InstallWowApi()
    local ok, value = pcall(require, "DialogKit")
    assert.is_false(ok)
    assert.is_truthy(tostring(value):find("Registry API 2", 1, true))
  end)

  it("refuses an incomplete facade left by an earlier failed load", function()
    TestEnv.Reset()
    TestEnv.InstallWowApi()
    local Registry = require("Registry")
    Registry:Register("dialogKit", 1, 1)
    local ok, value = pcall(TestEnv.requireAfterFailedLoad, "DialogKit")
    assert.is_false(ok)
    assert.is_truthy(tostring(value):find("MoltenCodes DialogKit", 1, true))
  end)
end)
