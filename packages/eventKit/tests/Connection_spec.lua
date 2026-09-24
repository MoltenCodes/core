local TestEnv = require("EventKitTestEnv")

describe("EventKit connections", function()
  local EventKit
  before_each(function()
    EventKit = TestEnv.NewPackage()
  end)
  after_each(TestEnv.Reset)

  it("returns a connected handle", function()
    local connection = EventKit:Connect("PLAYER_LOGIN", function() end)
    assert.is_true(connection:IsConnected())
  end)

  it("disconnects exactly once", function()
    local connection = EventKit:Connect("PLAYER_LOGIN", function() end)
    assert.is_true(connection:Disconnect())
    assert.is_false(connection:Disconnect())
    assert.is_false(connection:IsConnected())
  end)

  it("disconnecting one listener leaves another active", function()
    local firstCalls, secondCalls = 0, 0
    local first = EventKit:Connect("PLAYER_LOGIN", function()
      firstCalls = firstCalls + 1
    end)
    EventKit:Connect("PLAYER_LOGIN", function()
      secondCalls = secondCalls + 1
    end)
    first:Disconnect()
    TestEnv.Emit("PLAYER_LOGIN")
    assert.are.equal(0, firstCalls)
    assert.are.equal(1, secondCalls)
  end)
end)
