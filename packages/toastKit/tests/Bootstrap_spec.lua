local TestEnv = require("ToastKitTestEnv")

describe("ToastKit bootstrap", function()
  after_each(TestEnv.Reset)

  it("publishes through Registry", function()
    local ToastKit, _, Registry = TestEnv.NewPackage()
    local registered, revision = Registry:Get("toastKit", 1)
    assert.are.equal(ToastKit, registered)
    assert.are.equal(ToastKit.REVISION, revision)
  end)

  it("returns the same facade on a duplicate embedded load and keeps its toasts", function()
    local ToastKit = TestEnv.NewPackage()
    local toast = ToastKit:Show({ title = "x" })
    local reloaded = TestEnv.ReloadPackage()
    assert.are.equal(ToastKit, reloaded)
    assert.is_true(toast:IsShown())
  end)

  it("does not reinterpret private state owned by a newer compatible revision", function()
    local ToastKit, _, Registry = TestEnv.NewPackage()
    local shippedRevision = ToastKit.REVISION
    local upgraded, previous = Registry:Register("toastKit", 1, 99)
    assert.are.equal(ToastKit, upgraded)
    assert.are.equal(shippedRevision, previous)

    rawset(ToastKit, "REVISION", 99)
    rawset(ToastKit, "_state", { schema = 999 })
    package.loaded["ToastKit"] = nil
    local reloaded = require("ToastKit")
    assert.are.equal(ToastKit, reloaded)
    assert.are.equal(99, reloaded.REVISION)
  end)

  it("upgrades in place: toasts, the anchor, the pool, the limits and the sentinel", function()
    local ToastKit = TestEnv.NewPackage()
    local unbounded = ToastKit.UNBOUNDED
    ToastKit:SetLimits({ maxVisible = 1, maxQueued = unbounded })
    ToastKit:SetAnchor("BOTTOM", 0, 100, "UP")
    local shown = ToastKit:Show({ title = "shown", duration = 1 })
    local waiting = ToastKit:Show({ title = "waiting" })
    local frame = rawget(shown, "_record").frame

    local upgraded = TestEnv.LoadRevision(ToastKit.REVISION + 1)
    assert.are.equal(ToastKit, upgraded)
    assert.are.equal(unbounded, upgraded.UNBOUNDED)
    assert.are.same({ maxVisible = 1, maxQueued = unbounded }, upgraded:GetLimits())
    TestEnv.SetMouseOver(frame, false)
    TestEnv.Run(frame, "OnUpdate", 2)
    assert.is_false(shown:IsShown())
    assert.is_true(waiting:IsShown())
    assert.are.same(
      { "BOTTOM", TestEnv.GetGlobal("UIParent"), "BOTTOM", 0, 100 },
      { frame:GetPoint(1) }
    )
  end)

  it("refuses shared state whose limits hold an invalid value", function()
    local ToastKit = TestEnv.NewPackage()
    rawset(ToastKit._state.limits, "maxVisible", 21)
    TestEnv.expectErrorContaining("package state is corrupted or incomplete", function()
      TestEnv.ReloadPackage()
    end)
  end)

  it("requires Registry", function()
    TestEnv.Reset()
    TestEnv.InstallWowApi()
    local ok, value = pcall(require, "ToastKit")
    assert.is_false(ok)
    assert.is_truthy(tostring(value):find("Registry API 2", 1, true))
  end)

  it("requires PoolKit", function()
    TestEnv.Reset()
    TestEnv.InstallWowApi()
    require("Registry")
    local ok, value = pcall(TestEnv.requireAfterFailedLoad, "ToastKit")
    assert.is_false(ok)
    assert.is_truthy(tostring(value):find("PoolKit API 1", 1, true))
  end)

  it("refuses an incomplete facade left by an earlier failed load", function()
    TestEnv.Reset()
    TestEnv.InstallWowApi()
    local Registry = require("Registry")
    require("PoolKit")
    Registry:Register("toastKit", 1, 1)
    local ok, value = pcall(TestEnv.requireAfterFailedLoad, "ToastKit")
    assert.is_false(ok)
    assert.is_truthy(tostring(value):find("MoltenCodes ToastKit", 1, true))
  end)
end)
