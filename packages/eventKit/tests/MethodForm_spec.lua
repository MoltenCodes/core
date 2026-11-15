-- The method form of the connecting methods: a receiver table and a method
-- name in place of the callback, checked when the connection is made and
-- looked up on the receiver at every delivery.
local TestEnv = require("EventKitTestEnv")

local SPEC_FILE = "packages/eventKit/tests/MethodForm_spec.lua:"

---Assert that `callback` fails with `expected` at a line of this spec file.
---@param expected string
---@param callback fun()
local function expectRefusalAtCaller(expected, callback)
  local ok, message = pcall(callback)
  message = tostring(message)
  assert.is_false(ok)
  assert.is_not_nil(string.find(message, expected, 1, true), message)
  assert.is_not_nil(string.find(message, SPEC_FILE, 1, true), message)
end

---A receiver that records every call of its methods.
---@return table receiver
local function newReceiver()
  local receiver = { calls = {} }
  function receiver:OnEvent(...)
    self.calls[#self.calls + 1] = { "OnEvent", select("#", ...), ... }
  end
  function receiver:PLAYER_LOGIN(...)
    self.calls[#self.calls + 1] = { "PLAYER_LOGIN", select("#", ...), ... }
  end
  return receiver
end

describe("EventKit method-name callbacks", function()
  local EventKit

  before_each(function()
    EventKit = TestEnv.NewPackage()
  end)
  after_each(TestEnv.Reset)

  it("calls the method on its receiver with the event name and payload", function()
    local receiver = newReceiver()
    local connection = EventKit:Connect("BAG_UPDATE", receiver, "OnEvent")

    TestEnv.Emit("BAG_UPDATE", 3, nil)

    assert.is_true(connection:IsConnected())
    assert.are.same({ { "OnEvent", 3, "BAG_UPDATE", 3, nil } }, receiver.calls)
  end)

  it("defaults the method name to the event name, as AceEvent does", function()
    local receiver = newReceiver()
    EventKit:Connect("PLAYER_LOGIN", receiver)
    local scope = EventKit:CreateScope()
    scope:Once("PLAYER_LOGIN", receiver)

    TestEnv.Emit("PLAYER_LOGIN")
    TestEnv.Emit("PLAYER_LOGIN")

    assert.are.equal(3, #receiver.calls)
    assert.are.equal("PLAYER_LOGIN", receiver.calls[1][1])
    assert.are.equal("PLAYER_LOGIN", receiver.calls[1][3])
  end)

  it("delivers a one-shot method connection once", function()
    local receiver = newReceiver()
    local connection = EventKit:Once("BAG_UPDATE", receiver, "OnEvent")

    TestEnv.Emit("BAG_UPDATE")
    TestEnv.Emit("BAG_UPDATE")

    assert.are.equal(1, #receiver.calls)
    assert.is_false(connection:IsConnected())
  end)

  it("takes the method name before the unit tokens on the unit forms", function()
    local receiver = newReceiver()
    EventKit:ConnectUnit("UNIT_HEALTH", receiver, "OnEvent", "player")
    local scope = EventKit:CreateScope()
    scope:OnceUnit("UNIT_POWER_UPDATE", receiver, "OnEvent", "target", "player")

    TestEnv.Emit("UNIT_HEALTH", "player")
    TestEnv.Emit("UNIT_POWER_UPDATE", "target")
    TestEnv.Emit("UNIT_POWER_UPDATE", "target")

    assert.are.equal(2, #receiver.calls)
    assert.are.equal("UNIT_HEALTH", receiver.calls[1][3])
    assert.are.equal("player", receiver.calls[1][4])
    assert.are.equal("UNIT_POWER_UPDATE", receiver.calls[2][3])
  end)

  it("looks the method up at every delivery, so a later replacement runs", function()
    local receiver = newReceiver()
    EventKit:Connect("BAG_UPDATE", receiver, "OnEvent")
    local replaced = 0
    function receiver:OnEvent()
      replaced = replaced + 1
    end

    TestEnv.Emit("BAG_UPDATE")

    assert.are.equal(1, replaced)
    assert.are.equal(0, #receiver.calls)
  end)

  it("reports a method gone at delivery and keeps the connection", function()
    local receiver = newReceiver()
    local connection = EventKit:Connect("BAG_UPDATE", receiver, "OnEvent")
    local other = 0
    EventKit:Connect("BAG_UPDATE", function()
      other = other + 1
    end)
    local method = receiver.OnEvent
    receiver.OnEvent = nil

    TestEnv.Emit("BAG_UPDATE")

    local reported = TestEnv.ReportedErrors()
    assert.are.equal(1, #reported)
    local message = tostring(reported[1])
    assert.is_not_nil(string.find(message, 'receiver has no method "OnEvent"', 1, true), message)
    assert.are.equal(1, other)
    assert.is_true(connection:IsConnected())

    receiver.OnEvent = method
    TestEnv.Emit("BAG_UPDATE")
    assert.are.equal(1, #receiver.calls)
  end)

  it("refuses a callback that is neither a function nor a receiver at the caller", function()
    expectRefusalAtCaller(
      "EventKit:Connect callback must be a function, or a receiver table followed by a method name",
      function()
        EventKit:Connect("BAG_UPDATE", "OnEvent")
      end
    )
    expectRefusalAtCaller(
      "EventKit.Scope:OnceUnit callback must be a function, or a receiver table",
      function()
        EventKit:CreateScope():OnceUnit("UNIT_HEALTH", 42, "OnEvent", "player")
      end
    )
  end)

  it("refuses a missing or non-function method at the caller", function()
    local receiver = newReceiver()
    receiver.NotAFunction = true
    expectRefusalAtCaller('EventKit:Connect receiver has no method "OnMissing"', function()
      EventKit:Connect("BAG_UPDATE", receiver, "OnMissing")
    end)
    expectRefusalAtCaller('EventKit.Scope:Once receiver has no method "NotAFunction"', function()
      EventKit:CreateScope():Once("BAG_UPDATE", receiver, "NotAFunction")
    end)
    expectRefusalAtCaller('EventKit:Connect receiver has no method "BAG_UPDATE"', function()
      EventKit:Connect("BAG_UPDATE", receiver)
    end)
    -- Nothing was registered by the refused calls.
    assert.is_nil(EventKit._state.regularChannels["BAG_UPDATE"])
  end)

  it("requires a non-empty method name on the unit forms", function()
    local receiver = newReceiver()
    expectRefusalAtCaller("EventKit:ConnectUnit methodName must be a non-empty string", function()
      EventKit:ConnectUnit("UNIT_HEALTH", receiver, nil, "player")
    end)
    expectRefusalAtCaller("EventKit:Connect methodName must be a non-empty string", function()
      EventKit:Connect("BAG_UPDATE", receiver, "")
    end)
    expectRefusalAtCaller("EventKit.Scope:Connect methodName must be a non-empty string", function()
      EventKit:CreateScope():Connect("BAG_UPDATE", receiver, 7)
    end)
  end)

  it("refuses a secret method name before comparing it", function()
    local receiver = newReceiver()
    local secretName = "OnEvent"
    -- The package reads this host global at call time when it had none at load.
    -- selene: allow(global_usage)
    rawset(_G, "issecretvalue", function(value)
      return rawequal(value, secretName)
    end)
    expectRefusalAtCaller("EventKit:Connect methodName must not be a secret value", function()
      EventKit:Connect("BAG_UPDATE", receiver, secretName)
    end)
  end)

  it("owns a method connection in its scope like any other", function()
    local receiver = newReceiver()
    local scope = EventKit:CreateScope()
    local connection = scope:Connect("BAG_UPDATE", receiver, "OnEvent")

    assert.are.equal(1, scope:GetActiveCount())
    assert.are.equal(1, scope:DisconnectAll())
    assert.is_false(connection:IsConnected())
    TestEnv.Emit("BAG_UPDATE")
    assert.are.equal(0, #receiver.calls)
  end)
end)
