local TestEnv = require("EventKitTestEnv")

describe("EventKit unit subscriptions", function()
  local EventKit
  before_each(function()
    EventKit = TestEnv.NewPackage()
  end)
  after_each(TestEnv.Reset)

  it("uses RegisterUnitEvent", function()
    EventKit:ConnectUnit("UNIT_HEALTH", function() end, "player")
    local frame = TestEnv.Frames()[1]
    assert.are.equal(1, #frame.registerUnitEventCalls)
    assert.are.equal("UNIT_HEALTH", frame.registerUnitEventCalls[1].eventName)
    assert.are.equal("player", frame.registerUnitEventCalls[1].units[1])
  end)

  it("normalizes equivalent unit sets onto one registration", function()
    EventKit:ConnectUnit("UNIT_HEALTH", function() end, "target", "player", "player")
    EventKit:ConnectUnit("UNIT_HEALTH", function() end, "player", "target")
    local frame = TestEnv.Frames()[1]
    assert.are.equal(1, #TestEnv.Frames())
    assert.are.equal(1, #frame.registerUnitEventCalls)
    assert.are.equal("player", frame.registerUnitEventCalls[1].units[1])
    assert.are.equal("target", frame.registerUnitEventCalls[1].units[2])
  end)

  it("shares one unit-filter Frame across different event names", function()
    EventKit:ConnectUnit("UNIT_HEALTH", function() end, "player")
    EventKit:ConnectUnit("UNIT_POWER_UPDATE", function() end, "player")
    assert.are.equal(1, #TestEnv.Frames())
    assert.are.equal(2, #TestEnv.Frames()[1].registerUnitEventCalls)
  end)

  it("uses separate Frames for different unit filters", function()
    EventKit:ConnectUnit("UNIT_HEALTH", function() end, "player")
    EventKit:ConnectUnit("UNIT_HEALTH", function() end, "target")
    assert.are.equal(2, #TestEnv.Frames())
  end)

  it("delivers only matching unit payloads", function()
    local playerCalls, targetCalls = 0, 0
    EventKit:ConnectUnit("UNIT_HEALTH", function(_, unit)
      assert.are.equal("player", unit)
      playerCalls = playerCalls + 1
    end, "player")
    EventKit:ConnectUnit("UNIT_HEALTH", function(_, unit)
      assert.are.equal("target", unit)
      targetCalls = targetCalls + 1
    end, "target")
    TestEnv.Emit("UNIT_HEALTH", "player")
    TestEnv.Emit("UNIT_HEALTH", "target")
    TestEnv.Emit("UNIT_HEALTH", "focus")
    assert.are.equal(1, playerCalls)
    assert.are.equal(1, targetCalls)
  end)

  it("keeps regular and unit registrations independent", function()
    local regularCalls, unitCalls = 0, 0
    EventKit:Connect("UNIT_HEALTH", function()
      regularCalls = regularCalls + 1
    end)
    EventKit:ConnectUnit("UNIT_HEALTH", function()
      unitCalls = unitCalls + 1
    end, "player")
    TestEnv.Emit("UNIT_HEALTH", "target")
    TestEnv.Emit("UNIT_HEALTH", "player")
    assert.are.equal(2, regularCalls)
    assert.are.equal(1, unitCalls)
  end)

  it("unregisters and reuses the cached unit-filter Frame", function()
    local first = EventKit:ConnectUnit("UNIT_HEALTH", function() end, "player")
    local frame = TestEnv.Frames()[1]
    first:Disconnect()
    assert.is_nil(frame.registrations.UNIT_HEALTH)
    EventKit:ConnectUnit("UNIT_HEALTH", function() end, "player")
    assert.are.equal(1, #TestEnv.Frames())
    assert.are.equal(frame, TestEnv.Frames()[1])
    assert.are.equal(2, #frame.registerUnitEventCalls)
  end)

  it("rejects more than two distinct unit tokens", function()
    local ok, message = pcall(function()
      EventKit:ConnectUnit("UNIT_HEALTH", function() end, "player", "target", "focus")
    end)

    assert.is_false(ok)
    assert.is_not_nil(
      string.find(tostring(message), "accepts at most 2 distinct unit tokens", 1, true)
    )
    assert.are.equal(0, #TestEnv.Frames())
  end)

  it("counts duplicates once before applying the two-token limit", function()
    local connection = EventKit:ConnectUnit(
      "UNIT_HEALTH",
      function() end,
      "player",
      "target",
      "player",
      "target"
    )

    assert.is_true(connection:IsConnected())
    assert.are.equal(2, #TestEnv.Frames()[1].registerUnitEventCalls[1].units)
  end)

  it("applies the same limit to OnceUnit", function()
    local ok, message = pcall(function()
      EventKit:OnceUnit("UNIT_HEALTH", function() end, "player", "target", "pet")
    end)

    assert.is_false(ok)
    assert.is_not_nil(string.find(tostring(message), "EventKit:OnceUnit accepts at most", 1, true))
  end)

  it("releases a unit group when its last channel goes", function()
    local connection = EventKit:ConnectUnit("UNIT_HEALTH", function() end, "player")
    local groups = EventKit._state.unitGroups

    assert.is_not_nil(next(groups))

    connection:Disconnect()

    assert.is_nil(next(groups))
    assert.are.equal(1, #EventKit._state.unitFrames)
  end)

  it("keeps a unit group while another of its channels is still in use", function()
    local first = EventKit:ConnectUnit("UNIT_HEALTH", function() end, "player")
    EventKit:ConnectUnit("UNIT_POWER_UPDATE", function() end, "player")

    first:Disconnect()

    assert.is_not_nil(next(EventKit._state.unitGroups))
    assert.are.equal(0, #EventKit._state.unitFrames)
  end)

  it("reuses released Frames instead of creating one per unit set", function()
    for index = 1, 100 do
      local connection = EventKit:ConnectUnit("UNIT_HEALTH", function() end, "raid" .. index)
      connection:Disconnect()
    end

    assert.are.equal(1, #TestEnv.Frames())
    assert.are.equal(1, EventKit._state.unitFrameCount)
  end)

  it("bounds how many unit-filter Frames it will ever create", function()
    local connections = {}
    for index = 1, 64 do
      connections[index] = EventKit:ConnectUnit("UNIT_HEALTH", function() end, "raid" .. index)
    end

    assert.are.equal(64, #TestEnv.Frames())

    local ok, message = pcall(function()
      EventKit:ConnectUnit("UNIT_HEALTH", function() end, "raid65")
    end)

    assert.is_false(ok)
    assert.is_not_nil(string.find(tostring(message), "refusing to create more than 64", 1, true))
    -- The failed group must not be left behind half-created.
    assert.is_nil(EventKit._state.unitGroups["6:raid65"])

    for index = 1, 64 do
      connections[index]:Disconnect()
    end

    assert.are.equal(64, #EventKit._state.unitFrames)

    local reused = EventKit:ConnectUnit("UNIT_HEALTH", function() end, "raid65")

    assert.is_true(reused:IsConnected())
    assert.are.equal(64, #TestEnv.Frames())
    assert.are.equal(64, EventKit._state.unitFrameCount)
  end)

  it("stops delivering to a released group even if the host emits again", function()
    local calls = 0
    local connection = EventKit:ConnectUnit("UNIT_HEALTH", function()
      calls = calls + 1
    end, "player")
    local frame = TestEnv.Frames()[1]

    connection:Disconnect()

    assert.is_nil(frame.scripts.OnEvent)

    EventKit:ConnectUnit("UNIT_HEALTH", function() end, "target")
    TestEnv.Emit("UNIT_HEALTH", "player")

    assert.are.equal(0, calls)
  end)

  it("supports OnceUnit", function()
    local calls = 0
    local connection = EventKit:OnceUnit("UNIT_HEALTH", function(eventName, unit)
      assert.are.equal("UNIT_HEALTH", eventName)
      assert.are.equal("player", unit)
      calls = calls + 1
    end, "player")
    TestEnv.Emit("UNIT_HEALTH", "player")
    TestEnv.Emit("UNIT_HEALTH", "player")
    assert.are.equal(1, calls)
    assert.is_false(connection:IsConnected())
  end)
end)
