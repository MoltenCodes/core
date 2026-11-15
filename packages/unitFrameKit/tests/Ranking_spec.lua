local TestEnv = require("UnitFrameKitTestEnv")

---The names of `frames`, in order.
---@param frames table[]
---@return string[]
local function namesOf(frames)
  local names = {}
  for index, frame in ipairs(frames) do
    names[index] = frame.name or (frame.parent.name .. "." .. frame.parentKey)
  end
  return names
end

describe("UnitFrameKit ranking", function()
  local UnitFrameKit
  before_each(function()
    UnitFrameKit = TestEnv.NewPackage()
  end)
  after_each(TestEnv.Reset)

  it("ranks other addons' known frames, then unknown ones, then Blizzard's", function()
    TestEnv.UnitButton("CompactPartyFrameMember2", "party1")
    TestEnv.UnitButton("MyOwnPartyButton", "party1")
    TestEnv.UnitButton("ElvUF_PartyGroup1UnitButton2", "party1")
    TestEnv.UnitButton("CompactRaidFrame3", "party1")
    TestEnv.UnitButton("CellRaidFrameHeader1UnitButton2", "party1")
    TestEnv.RunScan(UnitFrameKit)
    assert.are.same({
      "CellRaidFrameHeader1UnitButton2",
      "ElvUF_PartyGroup1UnitButton2",
      "MyOwnPartyButton",
      "CompactRaidFrame3",
      "CompactPartyFrameMember2",
    }, namesOf(UnitFrameKit:GetUnitFrames("party1")))
    assert.are.equal("CellRaidFrameHeader1UnitButton2", UnitFrameKit:GetUnitFrame("party1").name)
  end)

  it("puts the caller's patterns first, in their order, whatever the kind", function()
    TestEnv.UnitButton("Grid2LayoutHeader1UnitButton1", "player")
    TestEnv.UnitButton("PlayerFrame", "player")
    TestEnv.UnitButton("SUFUnitplayer", "player")
    TestEnv.RunScan(UnitFrameKit)
    local options = { priorities = { "^SUFUnit", "^PlayerFrame$" } }
    assert.are.same(
      { "SUFUnitplayer", "PlayerFrame", "Grid2LayoutHeader1UnitButton1" },
      namesOf(UnitFrameKit:GetUnitFrames("player", options))
    )
    assert.are.equal("SUFUnitplayer", UnitFrameKit:GetUnitFrame("player", options).name)
  end)

  it("answers raid, party and boss frames by default", function()
    TestEnv.SetUnits({ boss1 = "Boss", party1 = "Ann" })
    TestEnv.UnitButton("Boss1TargetFrame", "boss1")
    TestEnv.UnitButton("SUFHeaderbossUnitButton1", "boss1")
    TestEnv.UnitButton("ElvUF_Boss1", "boss1")
    TestEnv.UnitButton("TargetFrame", "party1")
    TestEnv.UnitButton("FocusFrame", "party1")
    TestEnv.UnitButton("TargetFrameToT", "party1")
    TestEnv.RunScan(UnitFrameKit)
    assert.are.same(
      { "SUFHeaderbossUnitButton1", "ElvUF_Boss1", "Boss1TargetFrame" },
      namesOf(UnitFrameKit:GetUnitFrames("boss1"))
    )
    assert.is_nil(UnitFrameKit:GetUnitFrame("party1"))
  end)

  it("lets a solo kind answer for its own token, after the group kinds", function()
    TestEnv.SetUnits({
      player = "Me",
      target = "Bob",
      party2 = "Bob",
      focus = "Cid",
      targettarget = "Me",
    })
    TestEnv.UnitButton("PlayerFrame", "player")
    TestEnv.UnitButton("CompactPartyFrameMember1", "player")
    TestEnv.UnitButton("TargetFrame", "target")
    TestEnv.UnitButton("ElvUF_Target", "target")
    TestEnv.UnitButton("CompactPartyFrameMember3", "party2")
    TestEnv.UnitButton("FocusFrame", "focus")
    TestEnv.UnitButton("TargetFrameToT", "targettarget")
    TestEnv.RunScan(UnitFrameKit)
    assert.are.same(
      { "CompactPartyFrameMember1", "PlayerFrame" },
      namesOf(UnitFrameKit:GetUnitFrames("player"))
    )
    assert.are.same(
      { "ElvUF_Target", "CompactPartyFrameMember3", "TargetFrame" },
      namesOf(UnitFrameKit:GetUnitFrames("target"))
    )
    assert.are.same({ "CompactPartyFrameMember3" }, namesOf(UnitFrameKit:GetUnitFrames("party2")))
    assert.are.equal("FocusFrame", UnitFrameKit:GetUnitFrame("focus").name)
    assert.are.same(
      { "CompactPartyFrameMember1", "TargetFrameToT" },
      namesOf(UnitFrameKit:GetUnitFrames("targettarget"))
    )
  end)

  it("answers only the given kinds, ranked in their order", function()
    TestEnv.UnitButton("CompactRaidGroup1Member2", "party1")
    TestEnv.UnitButton("PartyFrameStandIn", "party1")
    TestEnv.UnitButton("CompactPartyFrameMember2", "party1")
    TestEnv.UnitButton("TargetFrame", "party1")
    TestEnv.RunScan(UnitFrameKit)
    assert.are.same(
      { "PartyFrameStandIn", "TargetFrame", "CompactPartyFrameMember2", "CompactRaidGroup1Member2" },
      namesOf(UnitFrameKit:GetUnitFrames("party1", { kinds = { "target", "party", "raid" } }))
    )
    assert.are.same(
      { "PartyFrameStandIn" },
      namesOf(UnitFrameKit:GetUnitFrames("party1", { kinds = {} }))
    )
  end)

  it("never answers ignored frames, not even a caller's priority", function()
    TestEnv.UnitButton("ElvUF_PartyGroup1UnitButton2", "party1")
    TestEnv.UnitButton("CompactPartyFrameMember2", "party1")
    TestEnv.RunScan(UnitFrameKit)
    local options = { ignore = { "^ElvUF_" }, priorities = { "^ElvUF_" } }
    assert.are.same(
      { "CompactPartyFrameMember2" },
      namesOf(UnitFrameKit:GetUnitFrames("party1", options))
    )
    assert.are.equal("CompactPartyFrameMember2", UnitFrameKit:GetUnitFrame("party1", options).name)
  end)

  it("keeps equal ranks in scan order", function()
    for index = 1, 4 do
      TestEnv.UnitButton("Grid2LayoutHeader1UnitButton" .. index, "party1")
    end
    TestEnv.RunScan(UnitFrameKit)
    assert.are.same({
      "Grid2LayoutHeader1UnitButton1",
      "Grid2LayoutHeader1UnitButton2",
      "Grid2LayoutHeader1UnitButton3",
      "Grid2LayoutHeader1UnitButton4",
    }, namesOf(UnitFrameKit:GetUnitFrames("party1")))
  end)

  it("knows Blizzard's party frame through its parent key", function()
    local partyFrame = TestEnv.Widget({ name = "PartyFrame" })
    TestEnv.UnitButton(nil, "party1", { parent = partyFrame, parentKey = "MemberFrame1" })
    TestEnv.UnitButton("SomeAddonFrame", "party1")
    TestEnv.RunScan(UnitFrameKit)
    assert.are.same(
      { "SomeAddonFrame", "PartyFrame.MemberFrame1" },
      namesOf(UnitFrameKit:GetUnitFrames("party1"))
    )
  end)

  it("publishes each kind's patterns as a copy", function()
    local patterns = UnitFrameKit:GetKindPatterns("party")
    assert.are.same({
      "^CompactPartyFrameMember%d$",
      "^PartyFrame%.MemberFrame%d$",
      "^ElvUF_PartyGroup1UnitButton%d$",
      "^CellPartyFrameHeaderUnitButton%d$",
      "^SUFHeaderpartyUnitButton%d$",
    }, patterns)
    patterns[1] = "changed"
    assert.are.equal("^CompactPartyFrameMember%d$", UnitFrameKit:GetKindPatterns("party")[1])
    for _, kind in ipairs({ "raid", "boss", "player", "target", "targettarget", "focus" }) do
      assert.is_true(#UnitFrameKit:GetKindPatterns(kind) > 0)
    end
  end)
end)
