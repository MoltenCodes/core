local TestEnv = require("UnitFrameKitTestEnv")

describe("UnitFrameKit bootstrap", function()
  after_each(TestEnv.Reset)

  it("publishes through Registry", function()
    local UnitFrameKit, Registry = TestEnv.NewPackage()
    local registered, revision = Registry:Get("unitFrameKit", 1)
    assert.are.equal(UnitFrameKit, registered)
    assert.are.equal(UnitFrameKit.REVISION, revision)
  end)

  it("returns the same facade on a duplicate embedded load and keeps its cache", function()
    local UnitFrameKit = TestEnv.NewPackage()
    local frame = TestEnv.UnitButton("CompactPartyFrameMember2", "party1")
    TestEnv.RunScan(UnitFrameKit)
    local reloaded = TestEnv.ReloadPackage()
    assert.are.equal(UnitFrameKit, reloaded)
    assert.are.equal(frame, reloaded:GetUnitFrame("party1"))
  end)

  it("does not reinterpret private state owned by a newer compatible revision", function()
    local UnitFrameKit, Registry = TestEnv.NewPackage()
    local shippedRevision = UnitFrameKit.REVISION
    local upgraded, previous = Registry:Register("unitFrameKit", 1, 99)
    assert.are.equal(UnitFrameKit, upgraded)
    assert.are.equal(shippedRevision, previous)

    rawset(UnitFrameKit, "REVISION", 99)
    rawset(UnitFrameKit, "_state", { schema = 999 })
    package.loaded["UnitFrameKit"] = nil
    local reloaded = require("UnitFrameKit")
    assert.are.equal(UnitFrameKit, reloaded)
    assert.are.equal(99, reloaded.REVISION)
  end)

  it(
    "upgrades in place: the event frame, a running scan, listeners and limits run the new code",
    function()
      local UnitFrameKit = TestEnv.NewPackage()
      UnitFrameKit:SetLimits({ scanFramesPerStep = 1 })
      local seen = {}
      local connection = UnitFrameKit:OnChange(function(frame, unit)
        seen[#seen + 1] = { frame.name, unit }
      end)
      TestEnv.UnitButton("One", "party1")
      TestEnv.UnitButton("Two", "party2")
      UnitFrameKit:Rescan()
      TestEnv.Tick(0.016)
      assert.is_true(UnitFrameKit:IsScanning())

      local upgraded = TestEnv.LoadRevision(UnitFrameKit.REVISION + 1)
      assert.are.equal(UnitFrameKit, upgraded)
      assert.are.equal(1, upgraded:GetLimits().scanFramesPerStep)
      while upgraded:IsScanning() do
        TestEnv.Tick(0.016)
      end
      assert.are.same({ { "One", "party1" }, { "Two", "party2" } }, seen)
      assert.is_truthy(upgraded:GetUnitFrame("party2"))
      assert.is_true(connection:Disconnect())
      TestEnv.Emit("GROUP_ROSTER_UPDATE")
      assert.is_true(upgraded:IsScanning())
      assert.are.equal(1, #TestEnv.Frames())
    end
  )

  it("upgrades a revision 1 copy in place, keeping its cache and listeners", function()
    local UnitFrameKit = TestEnv.NewPackageAtRevision(1)
    assert.are.equal(1, UnitFrameKit.REVISION)
    TestEnv.SetUnits({ party1 = "Ann", focustarget = "Ann" })
    TestEnv.UnitButton("FocusFrameToT", "focustarget")
    TestEnv.UnitButton("CompactPartyFrameMember2", "party1")
    local seen = 0
    local connection = UnitFrameKit:OnChange(function()
      seen = seen + 1
    end)
    TestEnv.RunScan(UnitFrameKit)
    assert.are.equal(2, seen)
    local state = UnitFrameKit._state

    local upgraded = TestEnv.ReloadPackage()
    assert.are.equal(UnitFrameKit, upgraded)
    assert.are.equal(2, upgraded.REVISION)
    assert.are.equal(state, upgraded._state)
    assert.is_true(connection:IsConnected())
    -- Revision 2 changed no state field: the cache and the listener carry
    -- over, and a scan of the same frames reports no change.
    TestEnv.RunScan(upgraded)
    assert.are.equal("CompactPartyFrameMember2", upgraded:GetUnitFrame("party1").name)
    assert.are.equal(2, seen)
  end)

  it("refuses shared state whose limit holds an invalid value", function()
    local UnitFrameKit = TestEnv.NewPackage()
    rawset(UnitFrameKit._state.limits, "maxFrames", 4097)
    TestEnv.expectErrorContaining("package state is corrupted or incomplete", function()
      TestEnv.ReloadPackage()
    end)
  end)

  it("refuses shared state without its limits or caches", function()
    local UnitFrameKit = TestEnv.NewPackage()
    rawset(UnitFrameKit._state, "limits", nil)
    TestEnv.expectErrorContaining("package state is corrupted or incomplete", function()
      TestEnv.ReloadPackage()
    end)
    UnitFrameKit = TestEnv.NewPackage()
    rawset(UnitFrameKit._state.cache, "units", nil)
    TestEnv.expectErrorContaining("package state is corrupted or incomplete", function()
      TestEnv.ReloadPackage()
    end)
  end)

  it("requires Registry", function()
    TestEnv.Reset()
    TestEnv.InstallWowApi()
    local ok, value = pcall(require, "UnitFrameKit")
    assert.is_false(ok)
    assert.is_truthy(tostring(value):find("Registry API 2", 1, true))
  end)

  it("refuses an incomplete facade left by an earlier failed load", function()
    TestEnv.Reset()
    TestEnv.InstallWowApi()
    local Registry = require("Registry")
    Registry:Register("unitFrameKit", 1, 1)
    local ok, value = pcall(TestEnv.requireAfterFailedLoad, "UnitFrameKit")
    assert.is_false(ok)
    assert.is_truthy(tostring(value):find("MoltenCodes UnitFrameKit", 1, true))
  end)
end)
