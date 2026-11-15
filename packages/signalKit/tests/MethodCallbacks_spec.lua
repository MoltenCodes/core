local TestEnv = require("SignalKitTestEnv")

local SPEC_FILE = "packages/signalKit/tests/MethodCallbacks_spec.lua:"

---Assert that `callback` raises a message naming `expected` at this spec file's
---line rather than somewhere inside the package.
---@param expected string
---@param callback fun()
local function expectRefusalAtCaller(expected, callback)
  TestEnv.ExpectRefusalAtCaller(SPEC_FILE, expected, callback)
end

---A receiver that records every call of its `OnMessage` and `Changed` methods.
---@return table
local function newReceiver()
  local receiver = { calls = {} }
  function receiver:OnMessage(...)
    self.calls[#self.calls + 1] = { "OnMessage", ... }
  end
  function receiver:Changed(...)
    self.calls[#self.calls + 1] = { "Changed", ... }
  end
  return receiver
end

describe("SignalKit method-name callbacks on buses", function()
  local SignalKit
  local bus

  before_each(function()
    SignalKit = TestEnv.NewPackage()
    TestEnv.InstallHostErrorHandler()
    bus = SignalKit:Bus("Methods", { openTopics = true })
  end)

  after_each(TestEnv.Reset)

  it("delivers to the named method with the receiver and the published arguments", function()
    local receiver = newReceiver()
    local connection = bus:Subscribe("Topic", receiver, "OnMessage")

    bus:Publish("Topic", 1, nil, "three")

    assert.are.same({ { "OnMessage", 1, nil, "three" } }, receiver.calls)
    assert.are.equal(3, select("#", unpack(receiver.calls[1], 2, 4)))
    assert.is_true(connection:Disconnect())
    bus:Publish("Topic", 4)
    assert.are.equal(1, #receiver.calls)
  end)

  it("defaults the method to the topic, as AceEvent-3.0 does for messages", function()
    local receiver = newReceiver()
    bus:Subscribe("Changed", receiver)
    bus:SubscribeOnce("Changed", receiver)

    bus:Publish("Changed", "first")
    bus:Publish("Changed", "second")

    assert.are.same(
      { { "Changed", "first" }, { "Changed", "first" }, { "Changed", "second" } },
      receiver.calls
    )
  end)

  it("works on bus scopes, which release method subscriptions like any other", function()
    local receiver = newReceiver()
    local scope = bus:CreateScope()
    scope:Subscribe("Topic", receiver, "OnMessage")
    scope:SubscribeOnce("Changed", receiver)

    bus:Publish("Topic", "scoped")
    assert.are.equal(2, scope:DisconnectAll())
    bus:Publish("Topic", "after")

    assert.are.same({ { "OnMessage", "scoped" } }, receiver.calls)
  end)

  it("looks the method up at every delivery, so replacing it reaches the subscription", function()
    local receiver = newReceiver()
    bus:Subscribe("Topic", receiver, "OnMessage")
    local replaced = {}
    function receiver:OnMessage(value)
      replaced[#replaced + 1] = value
    end

    bus:Publish("Topic", "late")

    assert.are.same({ "late" }, replaced)
    assert.are.equal(0, #receiver.calls)
  end)

  it("reports a method removed after subscribing and keeps the subscription", function()
    local receiver = newReceiver()
    local connection = bus:Subscribe("Topic", receiver, "OnMessage")
    bus:Subscribe("Topic", receiver, "Changed")
    receiver.OnMessage = nil

    bus:Publish("Topic", "value")

    local reported = TestEnv.TakeReportedErrors()
    assert.are.equal(1, #reported)
    assert.is_truthy(
      string.find(tostring(reported[1].value), 'receiver has no method "OnMessage"', 1, true)
    )
    assert.are.same({ { "Changed", "value" } }, receiver.calls)
    assert.is_true(connection:IsConnected())
  end)

  it("checks the receiver and the method name at the caller's line", function()
    local receiver = newReceiver()

    expectRefusalAtCaller(
      "SignalKit.Bus:Subscribe callback must be a function, or a receiver table followed by a method name",
      function()
        bus:Subscribe("Topic", 42)
      end
    )
    expectRefusalAtCaller('SignalKit.Bus:Subscribe receiver has no method "Missing"', function()
      bus:Subscribe("Topic", receiver, "Missing")
    end)
    expectRefusalAtCaller('SignalKit.Bus:SubscribeOnce receiver has no method "Topic"', function()
      bus:SubscribeOnce("Topic", receiver)
    end)
    receiver.notAFunction = true
    expectRefusalAtCaller('receiver has no method "notAFunction"', function()
      bus:Subscribe("Topic", receiver, "notAFunction")
    end)
    expectRefusalAtCaller(
      "SignalKit.Bus:Subscribe methodName must be a non-empty string",
      function()
        bus:Subscribe("Topic", receiver, "")
      end
    )
    expectRefusalAtCaller(
      "SignalKit.Bus:Subscribe methodName must be a non-empty string",
      function()
        bus:Subscribe("Topic", receiver, 7)
      end
    )
    local scope = bus:CreateScope()
    expectRefusalAtCaller('SignalKit.BusScope:Subscribe receiver has no method "Nope"', function()
      scope:Subscribe("Topic", receiver, "Nope")
    end)
  end)

  it("refuses a secret method name before comparing it", function()
    local secret = {}
    -- The package reads this host global at call time, so the spec installs it in the global table.
    -- selene: allow(global_usage)
    rawset(_G, "issecretvalue", function(value)
      return rawequal(value, secret)
    end)

    expectRefusalAtCaller(
      "SignalKit.Bus:Subscribe methodName must not be a secret value",
      function()
        bus:Subscribe("Topic", newReceiver(), secret)
      end
    )
  end)

  it("matches Unsubscribe by function only, so a method subscription stays", function()
    local receiver = newReceiver()
    local connection = bus:Subscribe("Topic", receiver, "OnMessage")

    assert.are.equal(0, bus:Unsubscribe("Topic", receiver.OnMessage))
    assert.is_true(connection:IsConnected())
  end)
end)

describe("SignalKit method-name callbacks on raw signals", function()
  local SignalKit

  before_each(function()
    SignalKit = TestEnv.NewPackage()
  end)

  after_each(TestEnv.Reset)

  it("connects a named method for every firing or for one", function()
    local receiver = newReceiver()
    local signal = SignalKit:New()
    signal:Connect(receiver, "OnMessage")
    signal:Once(receiver, "Changed")

    signal:Fire("a")
    signal:Fire("b")

    assert.are.same(
      { { "OnMessage", "a" }, { "Changed", "a" }, { "OnMessage", "b" } },
      receiver.calls
    )
  end)

  it("requires the method name: a raw signal has no name to default to", function()
    local signal = SignalKit:New()

    expectRefusalAtCaller("SignalKit:Connect methodName must be a non-empty string", function()
      signal:Connect(newReceiver())
    end)
    expectRefusalAtCaller('SignalKit:Once receiver has no method "Missing"', function()
      signal:Once(newReceiver(), "Missing")
    end)
  end)

  it("propagates a method missing at Fire to the caller, as any listener error", function()
    local receiver = newReceiver()
    local signal = SignalKit:New()
    local connection = signal:Connect(receiver, "OnMessage")
    receiver.OnMessage = nil

    local ok, message = pcall(signal.Fire, signal, "value")

    assert.is_false(ok)
    assert.is_truthy(string.find(tostring(message), 'receiver has no method "OnMessage"', 1, true))
    assert.is_true(connection:IsConnected())
  end)
end)
