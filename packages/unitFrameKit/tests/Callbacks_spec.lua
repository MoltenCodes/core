local TestEnv = require("UnitFrameKitTestEnv")

describe("UnitFrameKit change notifications", function()
  local UnitFrameKit, calls, connection
  before_each(function()
    UnitFrameKit = TestEnv.NewPackage()
    calls = {}
    connection = UnitFrameKit:OnChange(function(frame, unit, previousUnit)
      calls[#calls + 1] = { frame.name, unit, previousUnit }
    end)
  end)
  after_each(TestEnv.Reset)

  it("reports frames new to the cache, changed and gone, after each scan", function()
    local first = TestEnv.UnitButton("One", "party1")
    local second = TestEnv.UnitButton("Two", "party2")
    TestEnv.RunScan(UnitFrameKit)
    assert.are.same({ { "One", "party1", nil }, { "Two", "party2", nil } }, calls)
    calls = {}
    first.attributes.unit = "party3"
    second.visible = false
    TestEnv.RunScan(UnitFrameKit)
    assert.are.same({ { "One", "party3", "party1" }, { "Two", nil, "party2" } }, calls)
    calls = {}
    TestEnv.RunScan(UnitFrameKit)
    assert.are.same({}, calls)
  end)

  it("lets a listener query the new cache and ask for another scan", function()
    local found = {}
    UnitFrameKit:OnChange(function(_, unit)
      found[#found + 1] = unit and UnitFrameKit:GetUnitFrame(unit)
      UnitFrameKit:Rescan()
    end)
    local frame = TestEnv.UnitButton("CompactPartyFrameMember2", "party1")
    UnitFrameKit:Rescan()
    TestEnv.Tick(0.016)
    assert.are.same({ frame }, found)
    assert.is_true(UnitFrameKit:IsScanning())
    TestEnv.Tick(0.016)
    assert.is_false(UnitFrameKit:IsScanning())
  end)

  it("reports a listener that raises and still runs the others", function()
    local later = {}
    UnitFrameKit:OnChange(function()
      error("listener failed", 0)
    end)
    UnitFrameKit:OnChange(function(frame)
      later[#later + 1] = frame.name
    end)
    TestEnv.UnitButton("One", "party1")
    TestEnv.RunScan(UnitFrameKit)
    assert.are.same({ "listener failed" }, TestEnv.TakeReportedValues())
    assert.are.same({ "One" }, later)
    assert.are.equal(1, #calls)
  end)

  it("disconnects once, also from inside a notification", function()
    assert.is_true(connection:IsConnected())
    assert.is_true(connection:Disconnect())
    assert.is_false(connection:IsConnected())
    assert.is_false(connection:Disconnect())
    local seen = 0
    local selfConnection
    selfConnection = UnitFrameKit:OnChange(function()
      seen = seen + 1
      selfConnection:Disconnect()
    end)
    TestEnv.UnitButton("One", "party1")
    TestEnv.UnitButton("Two", "party2")
    TestEnv.RunScan(UnitFrameKit)
    assert.are.equal(1, seen)
    assert.are.same({}, calls)
    assert.are.same({}, rawget(UnitFrameKit._state, "listeners"))
  end)

  it("holds at most maxListeners connections and frees a slot on Disconnect", function()
    UnitFrameKit:SetLimits({ maxListeners = 2 })
    local second = UnitFrameKit:OnChange(function() end)
    TestEnv.expectErrorContaining(
      "UnitFrameKit:OnChange holds at most 2 listeners; raise maxListeners with UnitFrameKit:SetLimits",
      function()
        UnitFrameKit:OnChange(function() end)
      end
    )
    second:Disconnect()
    assert.is_true(UnitFrameKit:OnChange(function() end):IsConnected())
  end)
end)
