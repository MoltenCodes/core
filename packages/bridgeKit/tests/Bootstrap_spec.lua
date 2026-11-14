-- BridgeKit's place in the Registry: registration, one shared copy however
-- many addons embed it, in-place upgrades that keep the shared state, and the
-- published constants.
local Env = require("BridgeKitTestEnv")

describe("BridgeKit bootstrap", function()
  after_each(Env.Reset)

  it("registers with Registry as bridgeKit, API 1", function()
    local BridgeKit, Registry = Env.NewPackage()
    local registered, revision = Registry:Get("bridgeKit", 1)
    assert.are.equal(BridgeKit, registered)
    assert.are.equal(BridgeKit.REVISION, revision)
    assert.are.equal(1, BridgeKit.API)
  end)

  it("keeps one copy when a second embedded copy of the same revision loads", function()
    local BridgeKit = Env.NewPackage()
    BridgeKit:SetLimits({ maxDepth = 4 })
    local again = Env.requireAfterFailedLoad("BridgeKit")
    assert.are.equal(BridgeKit, again)
    assert.are.equal(4, again:GetLimits().maxDepth)
  end)

  it("lets an older copy that loads later step aside", function()
    local BridgeKit = Env.NewPackage()
    local newer = Env.LoadRevision(BridgeKit.REVISION + 1)
    assert.are.equal(BridgeKit, newer)
    local older = Env.LoadRevision(1)
    assert.are.equal(newer, older)
    assert.are.equal(2, older.REVISION)
  end)

  it("upgrades in place and keeps the limits, the sentinel and the baseline", function()
    local BridgeKit = Env.NewPackage()
    local unbounded, baseline = BridgeKit.UNBOUNDED, BridgeKit.ACE_BASELINE
    BridgeKit:SetLimits({ maxDepth = 5, maxValues = unbounded })
    -- A newer revision loads over this one, as a newer embedded copy would.
    local upgraded = Env.LoadRevision(BridgeKit.REVISION + 1)
    assert.are.equal(BridgeKit, upgraded)
    assert.are.equal(2, upgraded.REVISION)
    assert.are.equal(unbounded, upgraded.UNBOUNDED)
    assert.are.equal(baseline, upgraded.ACE_BASELINE)
    assert.are.same(
      { 5, unbounded },
      { upgraded:GetLimits().maxDepth, upgraded:GetLimits().maxValues }
    )
  end)

  it("refuses an inherited state it cannot read", function()
    local BridgeKit = Env.NewPackage()
    rawset(rawget(BridgeKit, "_state"), "limits", "corrupted")
    local ok, failure = pcall(Env.LoadRevision, BridgeKit.REVISION + 1)
    assert.is_false(ok)
    assert.is_truthy(tostring(failure):find("package state is corrupted or incomplete", 1, true))
  end)

  it("publishes the Ace3 baseline read-only", function()
    local BridgeKit = Env.NewPackage()
    local baseline = BridgeKit.ACE_BASELINE
    assert.are.equal("5e2e0d3b3fd125ef1518744c6a9dd21f68f6e773", baseline.commit)
    assert.are.same(
      { 14, 5, 37, 22 },
      { baseline.AceComm, baseline.AceSerializer, baseline.AceDB, baseline.AceConfigRegistry }
    )
    local ok, failure = pcall(function()
      baseline.commit = "other"
    end)
    assert.is_false(ok)
    assert.is_truthy(tostring(failure):find("BridgeKit.ACE_BASELINE is read-only", 1, true))
    assert.are.equal(false, getmetatable(baseline))
    assert.are.equal(1, BridgeKit.ACE_WIRE_VERSION)
  end)

  it("requires Registry", function()
    Env.Reset()
    Env.InstallWowApi()
    local ok, failure = pcall(require, "BridgeKit")
    assert.is_false(ok)
    assert.is_truthy(tostring(failure):find("Registry API 2", 1, true))
  end)
end)
