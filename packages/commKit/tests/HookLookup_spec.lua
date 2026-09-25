local TestEnv = require("CommKitTestEnv")

local PREFIX = "CKTest"

-- Revision 7: until HookKit is found, a wake from idle looks it up through
-- `Registry:Find` at most once a second instead of on every send. A HookKit
-- that loads later is still found, by the first wake at least a second after
-- the previous lookup. See "Traffic CommKit did not send" in `docs/API.md`.

describe("CommKit HookKit lookup", function()
  local CommKit, Registry, scope, lookups, find
  before_each(function()
    local loaded
    CommKit, loaded = TestEnv.Load()
    Registry = loaded.Registry
    scope = CommKit:CreateScope()
    lookups = 0
    -- Count every lookup CommKit makes for HookKit; other lookups pass.
    find = rawget(Registry, "Find")
    rawset(Registry, "Find", function(self, packageName, api)
      if packageName == "hookKit" then
        lookups = lookups + 1
      end
      return find(self, packageName, api)
    end)
  end)
  after_each(function()
    rawset(Registry, "Find", find)
    TestEnv.Reset()
  end)

  ---Send a short message that leaves inside `Send`, which wakes the driver
  ---from idle, then let the held-callback run finish so the driver is idle
  ---again.
  local function sendOne()
    local handle = scope:Send({ prefix = PREFIX, text = "own", distribution = "PARTY" })
    assert.are.equal("sent", handle:GetState())
    TestEnv.Advance(0)
    TestEnv.TakeOutbox()
  end

  ---Send one outside addon message the way another addon would.
  local function sendOutside()
    -- selene: allow(global_usage)
    rawget(_G, "C_ChatInfo").SendAddonMessage("Other", TestEnv.Text(100), "PARTY")
    TestEnv.TakeOutbox()
  end

  it("looks HookKit up on the first wake of the session", function()
    sendOne()
    assert.are.equal(1, lookups)
  end)

  it("looks it up at most once a second while it is missing", function()
    sendOne()
    for _ = 1, 20 do
      sendOne()
    end
    assert.are.equal(1, lookups)
    TestEnv.Advance(0.5)
    sendOne()
    assert.are.equal(1, lookups)
    TestEnv.Advance(0.5)
    sendOne()
    assert.are.equal(2, lookups)
    for _ = 1, 20 do
      sendOne()
    end
    assert.are.equal(2, lookups)
  end)

  it("looks again on the first wake from idle a second later, not while busy", function()
    sendOne()
    TestEnv.HoldSends(CommKit)
    scope:Send({ prefix = PREFIX, text = "held", distribution = "PARTY" })
    scope:Send({ prefix = PREFIX, text = "held too", distribution = "PARTY" })
    assert.are.equal(1, lookups)
    TestEnv.ReleaseSends(CommKit, 2)
    TestEnv.TakeOutbox()
    -- More than a second has passed: the next wake from idle looks again.
    sendOne()
    assert.are.equal(2, lookups)
  end)

  it("finds a HookKit that loads later within the bound", function()
    sendOne()
    TestEnv.LoadHookKitLater()

    -- Within the second after the last lookup, HookKit is not looked up,
    -- so outside traffic is not charged yet.
    TestEnv.Advance(0.5)
    sendOne()
    sendOutside()
    assert.are.equal(0, CommKit:GetStatistics().outsideMessages)
    assert.are.equal(1, lookups)

    -- The first wake a second after the previous lookup finds it.
    TestEnv.Advance(0.5)
    sendOne()
    assert.are.equal(2, lookups)
    local before = CommKit:GetBudget()
    sendOutside()
    local statistics = CommKit:GetStatistics()
    assert.are.equal(1, statistics.outsideMessages)
    assert.are.equal(before - statistics.outsideBytes, (CommKit:GetBudget()))
  end)

  it("never looks HookKit up again once the hooks are installed", function()
    TestEnv.LoadHookKitLater()
    sendOne()
    assert.are.equal(1, lookups)
    for _ = 1, 5 do
      TestEnv.Advance(2)
      sendOne()
    end
    assert.are.equal(1, lookups)
    sendOutside()
    assert.are.equal(1, CommKit:GetStatistics().outsideMessages)
  end)
end)
