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
    local revision = BridgeKit.REVISION
    local newer = Env.LoadRevision(revision + 1)
    assert.are.equal(BridgeKit, newer)
    local older = Env.LoadRevision(1)
    assert.are.equal(newer, older)
    assert.are.equal(revision + 1, older.REVISION)
  end)

  it("upgrades in place and keeps the limits, the sentinel and the baseline", function()
    local BridgeKit = Env.NewPackage()
    local unbounded, baseline = BridgeKit.UNBOUNDED, BridgeKit.ACE_BASELINE
    BridgeKit:SetLimits({ maxDepth = 5, maxValues = unbounded })
    local revision = BridgeKit.REVISION
    -- A newer revision loads over this one, as a newer embedded copy would.
    local upgraded = Env.LoadRevision(revision + 1)
    assert.are.equal(BridgeKit, upgraded)
    assert.are.equal(revision + 1, upgraded.REVISION)
    assert.are.equal(unbounded, upgraded.UNBOUNDED)
    assert.are.equal(baseline, upgraded.ACE_BASELINE)
    assert.are.same(
      { 5, unbounded },
      { upgraded:GetLimits().maxDepth, upgraded:GetLimits().maxValues }
    )
  end)

  it("upgrades a revision 6 copy in place and writes and reads the same text", function()
    Env.Reset()
    require("Registry")
    local older = Env.LoadRevision(6)
    assert.are.equal(6, older.REVISION)
    older:SetLimits({ maxDepth = 6 })
    local value = { name = "kept", list = { 1, 2.5, true }, ["a b"] = "x^y" }
    local _, text = older:AceSerialize(value)

    package.loaded["BridgeKit"] = nil
    local upgraded = require("BridgeKit")
    assert.are.equal(older, upgraded)
    assert.are.equal(9, upgraded.REVISION)
    assert.are.equal(6, upgraded:GetLimits().maxDepth)
    assert.are.same({ true, text }, { upgraded:AceSerialize(value) })
    assert.are.same({ true, value }, { upgraded:AceDeserialize(text) })
  end)

  it("upgrades a revision 7 copy in place, its limits and conversions kept", function()
    Env.Reset()
    require("Registry")
    local older = Env.LoadRevision(7)
    assert.are.equal(7, older.REVISION)
    older:SetLimits({ maxDepth = 5 })
    package.loaded["BridgeKit"] = nil
    local upgraded = require("BridgeKit")
    assert.are.equal(older, upgraded)
    assert.are.equal(9, upgraded.REVISION)
    assert.are.equal(5, upgraded:GetLimits().maxDepth)
    local conversion = upgraded:ConvertAceConfig("MyAddon", {
      type = "group",
      args = { a = { type = "header", name = "a", width = "full" } },
    })
    -- Without OptionsKit a field is still reported dropped, as before.
    assert.are.equal("presentation", conversion.report.entries[1].reason)
  end)

  it("lets a newer revision publish a new baseline through the same table", function()
    local BridgeKit = Env.NewPackage()
    local baseline = BridgeKit.ACE_BASELINE
    local upgraded = Env.LoadRevision(BridgeKit.REVISION + 1, {
      ['commit = "5e2e0d3b3fd125ef1518744c6a9dd21f68f6e773"'] = 'commit = "a newer pin"',
    })
    assert.are.equal(baseline, upgraded.ACE_BASELINE)
    assert.are.equal("a newer pin", baseline.commit)
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
