local TestEnv = require("TooltipKitTestEnv")

describe("TooltipKit bootstrap", function()
  after_each(TestEnv.Reset)

  it("publishes through Registry", function()
    local TooltipKit, _, Registry = TestEnv.NewPackage()
    local registered, revision = Registry:Get("tooltipKit", 1)
    assert.are.equal(TooltipKit, registered)
    assert.are.equal(TooltipKit.REVISION, revision)
  end)

  it("returns the same facade on a duplicate embedded load and keeps its tooltips", function()
    local TooltipKit = TestEnv.NewPackage()
    local tooltip = TooltipKit:Acquire("MyAddon", 1)
    local reloaded = TestEnv.ReloadPackage()
    assert.are.equal(TooltipKit, reloaded)
    assert.are.equal(tooltip, reloaded:Acquire("MyAddon", 1))
  end)

  it("does not reinterpret private state owned by a newer compatible revision", function()
    local TooltipKit, _, Registry = TestEnv.NewPackage()
    local shippedRevision = TooltipKit.REVISION
    local upgraded, previous = Registry:Register("tooltipKit", 1, 99)
    assert.are.equal(TooltipKit, upgraded)
    assert.are.equal(shippedRevision, previous)

    rawset(TooltipKit, "REVISION", 99)
    rawset(TooltipKit, "_state", { schema = 999 })
    package.loaded["TooltipKit"] = nil
    local reloaded = require("TooltipKit")
    assert.are.equal(TooltipKit, reloaded)
    assert.are.equal(99, reloaded.REVISION)
  end)

  it(
    "upgrades in place: tooltips, pools, limits and the scripts frames hold run the new code",
    function()
      local TooltipKit = TestEnv.NewPackage()
      TestEnv.InstallHostErrorHandler()
      local tooltip = TooltipKit:Acquire("MyAddon", 1)
      local clicks = 0
      local line = tooltip:AddLine("x")
      tooltip:SetLineScript(line, "OnMouseUp", function()
        clicks = clicks + 1
      end)
      tooltip:SetAutoHideDelay(0.1)
      tooltip:Show()
      TooltipKit:SetLimits({ maxLines = 300 })
      local tooltipPool = TooltipKit._state.tooltipPool

      local upgraded = TestEnv.LoadRevision(TooltipKit.REVISION + 1)
      assert.are.equal(TooltipKit, upgraded)
      assert.are.equal(300, upgraded:GetLimits().maxLines)
      assert.are.equal(tooltipPool, upgraded._state.tooltipPool)
      assert.are.equal(tooltip, upgraded:Acquire("MyAddon", 1))
      tooltip:AddLine("after")
      assert.are.equal(2, tooltip:GetLineCount())

      local lineFrame = upgraded._state.records[tooltip].lines[1].frame
      TestEnv.Run(lineFrame, "OnMouseUp", "LeftButton")
      assert.are.equal(1, clicks)
      local frame = tooltip:GetFrame()
      TestEnv.SetMouseOver(frame, false)
      TestEnv.Run(frame, "OnUpdate", 1)
      assert.is_false(upgraded:IsAcquired("MyAddon"))
      assert.are.equal(0, upgraded._state.linePool:GetActiveCount())
    end
  )

  it("refuses shared state whose limits hold an invalid value", function()
    local TooltipKit = TestEnv.NewPackage()
    rawset(TooltipKit._state.limits, "maxColumns", 33)
    TestEnv.expectErrorContaining("package state is corrupted or incomplete", function()
      TestEnv.ReloadPackage()
    end)
  end)

  it("requires Registry", function()
    TestEnv.Reset()
    TestEnv.InstallWowApi()
    local ok, value = pcall(require, "TooltipKit")
    assert.is_false(ok)
    assert.is_truthy(tostring(value):find("Registry API 2", 1, true))
  end)

  it("requires PoolKit", function()
    TestEnv.Reset()
    TestEnv.InstallWowApi()
    require("Registry")
    local ok, value = pcall(TestEnv.requireAfterFailedLoad, "TooltipKit")
    assert.is_false(ok)
    assert.is_truthy(tostring(value):find("PoolKit API 1", 1, true))
  end)

  it("refuses an incomplete facade left by an earlier failed load", function()
    TestEnv.Reset()
    TestEnv.InstallWowApi()
    local Registry = require("Registry")
    require("PoolKit")
    Registry:Register("tooltipKit", 1, 1)
    local ok, value = pcall(TestEnv.requireAfterFailedLoad, "TooltipKit")
    assert.is_false(ok)
    assert.is_truthy(tostring(value):find("MoltenCodes TooltipKit", 1, true))
  end)
end)
