-- BridgeKit's shared limits: defaults, validation before anything changes,
-- the UNBOUNDED sentinel where it is allowed and refused where it is not.
local Env = require("BridgeKitTestEnv")

local SOURCE = debug.getinfo(1, "S").short_src

---The message `SetLimits(update)` raises, without its position.
local function refusal(BridgeKit, update)
  local ok, failure = pcall(BridgeKit.SetLimits, BridgeKit, update)
  assert.is_false(ok)
  return (tostring(failure):gsub("^[^:]+:%d+: ", ""))
end

describe("BridgeKit limits", function()
  local BridgeKit
  before_each(function()
    BridgeKit = Env.NewPackage()
  end)
  after_each(Env.Reset)

  it("start at the documented defaults", function()
    assert.are.same({
      maxDepth = 16,
      maxValues = 65536,
      maxStringLength = 65536,
      maxTextBytes = 1048576,
      maxListValues = 4096,
      maxReportEntries = 1024,
      maxImportEntries = 65536,
      maxAceStreams = 64,
      maxAceStreamsPerSender = 4,
      maxAceStreamBytes = 65536,
      maxAceSpoolBytes = 1048576,
      aceStreamTimeout = 30,
      maxDropReportSenders = 64,
    }, BridgeKit:GetLimits())
  end)

  it("are returned as a fresh table each time", function()
    local first = BridgeKit:GetLimits()
    first.maxDepth = 1
    assert.are.equal(16, BridgeKit:GetLimits().maxDepth)
    assert.are_not.equal(first, BridgeKit:GetLimits())
  end)

  it("change only the named limits", function()
    BridgeKit:SetLimits({ maxDepth = 8, maxValues = BridgeKit.UNBOUNDED })
    local current = BridgeKit:GetLimits()
    assert.are.equal(8, current.maxDepth)
    assert.are.equal(BridgeKit.UNBOUNDED, current.maxValues)
    assert.are.equal(1048576, current.maxTextBytes)
  end)

  it("check every entry before changing any", function()
    assert.are.equal(
      "BridgeKit:SetLimits limits.maxTextBytes must be an integer from 1 to 67108864",
      refusal(BridgeKit, { maxDepth = 2, maxTextBytes = 0 })
    )
    assert.are.equal(16, BridgeKit:GetLimits().maxDepth)
  end)

  it("refuse values outside their range and names they do not know", function()
    assert.are.equal("BridgeKit:SetLimits limits must be a table", refusal(BridgeKit, 5))
    assert.are.equal(
      "BridgeKit:SetLimits limits has no limit named maxCount",
      refusal(BridgeKit, { maxCount = 1 })
    )
    assert.are.equal(
      "BridgeKit:SetLimits limits has no limit named [number]",
      refusal(BridgeKit, { 1 })
    )
    assert.are.equal(
      "BridgeKit:SetLimits limits.maxDepth must be an integer from 1 to 128",
      refusal(BridgeKit, { maxDepth = 129 })
    )
    assert.are.equal(
      "BridgeKit:SetLimits limits.maxListValues must be an integer from 1 to 7900",
      refusal(BridgeKit, { maxListValues = 1.5 })
    )
    assert.are.equal(
      "BridgeKit:SetLimits limits.maxValues must be an integer from 1 to 16777216 or BridgeKit.UNBOUNDED",
      refusal(BridgeKit, { maxValues = 0 / 0 })
    )
  end)

  it("refuse UNBOUNDED where it cannot be lifted, saying why", function()
    assert.are.equal(
      "BridgeKit:SetLimits limits.maxDepth cannot be BridgeKit.UNBOUNDED because the reader and writer"
        .. " recurse on the Lua call stack; use an integer from 1 to 128",
      refusal(BridgeKit, { maxDepth = BridgeKit.UNBOUNDED })
    )
    assert.is_truthy(
      refusal(BridgeKit, { maxTextBytes = BridgeKit.UNBOUNDED }):find("a peer chooses", 1, true)
    )
    assert.is_truthy(
      refusal(BridgeKit, { maxListValues = BridgeKit.UNBOUNDED }):find("unpack", 1, true)
    )
  end)

  it("refuse a secret key or value", function()
    local secret = {}
    Env.MarkSecret(secret)
    assert.are.equal(
      "BridgeKit:SetLimits limits must not have a secret key",
      refusal(BridgeKit, { [secret] = 1 })
    )
    assert.are.equal(
      "BridgeKit:SetLimits limits.maxDepth must not be a secret value",
      refusal(BridgeKit, { maxDepth = secret })
    )
  end)

  it("raise at the caller's line", function()
    local line
    local ok, failure = pcall(function()
      line = debug.getinfo(1, "l").currentline + 1
      BridgeKit:SetLimits({ maxDepth = 0 })
    end)
    assert.is_false(ok)
    assert.are.equal(
      SOURCE
        .. ":"
        .. line
        .. ": BridgeKit:SetLimits limits.maxDepth must be an integer from 1 to 128",
      failure
    )
  end)
end)
