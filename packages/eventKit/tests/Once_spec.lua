local TestEnv = require("EventKitTestEnv")

describe("EventKit one-shot subscriptions", function()
  local EventKit
  before_each(function()
    EventKit = TestEnv.NewPackage()
  end)
  after_each(TestEnv.Reset)

  it("runs Once exactly once", function()
    local calls = 0
    local connection = EventKit:Once("PLAYER_LOGIN", function()
      calls = calls + 1
    end)
    TestEnv.Emit("PLAYER_LOGIN")
    TestEnv.Emit("PLAYER_LOGIN")
    assert.are.equal(1, calls)
    assert.is_false(connection:IsConnected())
  end)

  it("disconnects and unregisters before the callback runs", function()
    local connectedDuring, registeredDuring
    local connection
    connection = EventKit:Once("PLAYER_LOGIN", function()
      connectedDuring = connection:IsConnected()
      registeredDuring = TestEnv.Frames()[1].registrations.PLAYER_LOGIN ~= nil
    end)
    TestEnv.Emit("PLAYER_LOGIN")
    assert.is_false(connectedDuring)
    assert.is_false(registeredDuring)
  end)

  it("does not run twice under recursive emission", function()
    local calls = 0
    EventKit:Once("CUSTOM_EVENT", function()
      calls = calls + 1
      TestEnv.Emit("CUSTOM_EVENT")
    end)
    TestEnv.Emit("CUSTOM_EVENT")
    assert.are.equal(1, calls)
  end)

  it("stays disconnected when its callback errors", function()
    local connection = EventKit:Once("CUSTOM_EVENT", function()
      error("once failure")
    end)

    TestEnv.Emit("CUSTOM_EVENT")

    local reported = TestEnv.ReportedErrors()
    assert.are.equal(1, #reported)
    assert.is_not_nil(string.find(reported[1], "once failure", 1, true))
    assert.is_false(connection:IsConnected())
    assert.is_nil(TestEnv.Frames()[1].registrations.CUSTOM_EVENT)
  end)
end)
