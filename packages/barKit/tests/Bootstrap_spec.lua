local TestEnv = require("BarKitTestEnv")

describe("BarKit bootstrap", function()
  after_each(TestEnv.Reset)

  it("publishes through Registry", function()
    local BarKit, _, Registry = TestEnv.NewPackage()
    local registered, revision = Registry:Get("barKit", 1)
    assert.are.equal(BarKit, registered)
    assert.are.equal(BarKit.REVISION, revision)
  end)

  it("returns the same facade on a duplicate embedded load and keeps its bars", function()
    local BarKit = TestEnv.NewPackage()
    local bar = BarKit:Acquire()
    local reloaded = TestEnv.ReloadPackage()
    assert.are.equal(BarKit, reloaded)
    bar:SetLabel("still mine")
    assert.are.equal("still mine", bar:GetFrame().label:GetText())
  end)

  it("does not reinterpret private state owned by a newer compatible revision", function()
    local BarKit, _, Registry = TestEnv.NewPackage()
    local shippedRevision = BarKit.REVISION
    local upgraded, previous = Registry:Register("barKit", 1, 99)
    assert.are.equal(BarKit, upgraded)
    assert.are.equal(shippedRevision, previous)

    rawset(BarKit, "REVISION", 99)
    rawset(BarKit, "_state", { schema = 999 })
    package.loaded["BarKit"] = nil
    local reloaded = require("BarKit")
    assert.are.equal(BarKit, reloaded)
    assert.are.equal(99, reloaded.REVISION)
  end)

  it("upgrades in place: bars, the pool, the limit and running timers run the new code", function()
    local BarKit = TestEnv.NewPackage()
    local finished = 0
    local bar = BarKit:Acquire()
    bar:Start(2, {
      onFinished = function()
        finished = finished + 1
      end,
    })
    BarKit:SetLimits({ maxBars = 100 })
    local pool = BarKit._state.pool

    local upgraded = TestEnv.LoadRevision(BarKit.REVISION + 1)
    assert.are.equal(BarKit, upgraded)
    assert.are.equal(100, upgraded:GetLimits().maxBars)
    assert.are.equal(pool, upgraded._state.pool)
    assert.is_true(bar:IsRunning())
    TestEnv.Advance(bar:GetFrame(), 3)
    assert.are.equal(1, finished)
    upgraded:Release(bar)
    assert.are.equal(0, pool:GetActiveCount())
  end)

  it("takes over a bar acquired by revision 1, whose record has no secret text fields", function()
    local BarKit = TestEnv.NewPackage()
    TestEnv.InstallSecretProbe()
    local bar = BarKit:Acquire()
    local record = BarKit._state.records[bar]
    record.secretLabel, record.secretValueText = nil, nil
    bar:SetLabel("plain")
    bar:SetLabel(TestEnv.NewSecret(), { allowSecret = true })
    bar:Start(1, { releaseOnFinish = true })
    TestEnv.Advance(bar:GetFrame(), 2)
    assert.are.equal(0, BarKit._state.acquiredCount)
  end)

  it("refuses shared state whose limit holds an invalid value", function()
    local BarKit = TestEnv.NewPackage()
    rawset(BarKit._state.limits, "maxBars", 513)
    TestEnv.expectErrorContaining("package state is corrupted or incomplete", function()
      TestEnv.ReloadPackage()
    end)
  end)

  it("requires Registry", function()
    TestEnv.Reset()
    TestEnv.InstallWowApi()
    local ok, value = pcall(require, "BarKit")
    assert.is_false(ok)
    assert.is_truthy(tostring(value):find("Registry API 2", 1, true))
  end)

  it("requires PoolKit", function()
    TestEnv.Reset()
    TestEnv.InstallWowApi()
    require("Registry")
    local ok, value = pcall(TestEnv.requireAfterFailedLoad, "BarKit")
    assert.is_false(ok)
    assert.is_truthy(tostring(value):find("PoolKit API 1", 1, true))
  end)

  it("refuses an incomplete facade left by an earlier failed load", function()
    TestEnv.Reset()
    TestEnv.InstallWowApi()
    local Registry = require("Registry")
    require("PoolKit")
    Registry:Register("barKit", 1, 1)
    local ok, value = pcall(TestEnv.requireAfterFailedLoad, "BarKit")
    assert.is_false(ok)
    assert.is_truthy(tostring(value):find("MoltenCodes BarKit", 1, true))
  end)
end)
