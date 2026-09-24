local TestEnv = require("SignalKitTestEnv")

---Subscribe a failing listener between two recording ones and publish once.
---@param bus table
---@return string[] calls
local function publishPastAFailingListener(bus)
  local calls = {}
  bus:Subscribe("Topic", function(value)
    calls[#calls + 1] = "before:" .. value
  end)
  bus:Subscribe("Topic", function()
    error("listener failure")
  end)
  bus:Subscribe("Topic", function(value)
    calls[#calls + 1] = "after:" .. value
  end)

  bus:Publish("Topic", "payload")
  return calls
end

describe("SignalKit bus listener isolation", function()
  after_each(TestEnv.Reset)

  it("reports a listener error through the host error handler and keeps delivering", function()
    local SignalKit = TestEnv.NewPackage()
    TestEnv.InstallHostErrorHandler()
    local bus = SignalKit:Bus("Isolated", { openTopics = true })

    local calls = publishPastAFailingListener(bus)
    local reported = TestEnv.ReportedErrors()

    assert.are.same({ "before:payload", "after:payload" }, calls)
    assert.are.equal(1, #reported)
    assert.is_not_nil(string.find(tostring(reported[1]), "listener failure", 1, true))
  end)

  it("routes deliveries through securecallfunction when the host provides it", function()
    local SignalKit = TestEnv.NewPackageWithSecureCall()
    local bus = SignalKit:Bus("Secure", { openTopics = true })

    local calls = publishPastAFailingListener(bus)
    local reported = TestEnv.ReportedErrors()

    assert.are.same({ "before:payload", "after:payload" }, calls)
    assert.are.equal(1, #reported)
    assert.is_not_nil(string.find(tostring(reported[1]), "listener failure", 1, true))
  end)

  it("never propagates a listener error to the publisher", function()
    local SignalKit = TestEnv.NewPackage()
    TestEnv.InstallHostErrorHandler()
    local bus = SignalKit:Bus("Publisher", { openTopics = true })
    bus:Subscribe("Topic", function()
      error("listener failure")
    end)

    assert.has_no.errors(function()
      bus:Publish("Topic")
    end)
    assert.are.equal(1, #TestEnv.ReportedErrors())
  end)

  it("still propagates listener errors from a raw signal to its caller", function()
    local SignalKit = TestEnv.NewPackage()
    TestEnv.InstallHostErrorHandler()
    local signal = SignalKit:New()
    signal:Connect(function()
      error("listener failure")
    end)

    assert.has_error(function()
      signal:Fire()
    end)
    assert.are.same({}, TestEnv.ReportedErrors())
  end)

  it("forwards wide payloads and nested publishes intact on the xpcall path", function()
    local SignalKit = TestEnv.NewPackage()
    TestEnv.InstallHostErrorHandler()
    local bus = SignalKit:Bus("Wide", { openTopics = true })
    local outerCount, outerValues, innerCount, innerValues

    bus:Subscribe("Outer", function(...)
      bus:Publish("Inner", "a", nil, "c")
      outerCount, outerValues = select("#", ...), { ... }
    end)
    bus:Subscribe("Inner", function(...)
      innerCount, innerValues = select("#", ...), { ... }
    end)

    bus:Publish("Outer", 1, 2, 3, 4, 5, 6, 7, 8, 9, 10, nil, 12)

    assert.are.equal(12, outerCount)
    for index = 1, 12 do
      local expected = index ~= 11 and index or nil
      assert.are.equal(expected, outerValues[index])
    end
    assert.are.equal(3, innerCount)
    assert.are.equal("a", innerValues[1])
    assert.is_nil(innerValues[2])
    assert.are.equal("c", innerValues[3])
    assert.are.same({}, TestEnv.ReportedErrors())
  end)

  it("keeps the bus usable after a listener error", function()
    local SignalKit = TestEnv.NewPackage()
    TestEnv.InstallHostErrorHandler()
    local bus = SignalKit:Bus("Recovering", { openTopics = true })
    local failing = bus:Subscribe("Topic", function()
      error("listener failure")
    end)
    local calls = 0
    bus:Subscribe("Topic", function()
      calls = calls + 1
    end)

    bus:Publish("Topic")
    failing:Disconnect()
    bus:Publish("Topic")

    assert.are.equal(2, calls)
    assert.are.equal(1, #TestEnv.ReportedErrors())
  end)
end)

describe("SignalKit bus allocation behaviour #allocation", function()
  after_each(TestEnv.Reset)

  it("allocates nothing per steady-state Publish", function()
    local SignalKit = TestEnv.NewPackage()
    TestEnv.InstallHostErrorHandler()
    local bus = SignalKit:Bus("Hot")
    bus:DeclareTopic("Counted", { arguments = 2 })
    bus:DeclareTopic("Validated", {
      arguments = function(first)
        return type(first) == "number", "not a number"
      end,
    })
    local sink = 0
    for _ = 1, 8 do
      bus:Subscribe("Counted", function(first, second)
        sink = sink + first + second
      end)
      bus:Subscribe("Validated", function(first, second)
        sink = sink + first + second
      end)
    end
    -- The first publish grows the reusable staging buffer once.
    bus:Publish("Counted", 1, 2)

    local allocated = TestEnv.AllocatedKilobytes(function()
      for _ = 1, 20000 do
        bus:Publish("Counted", 1, 2)
        bus:Publish("Validated", 1, 2)
      end
    end)

    assert.is_true(allocated < 4, allocated .. " KB allocated")
    assert.are.equal(20000 * 8 * 3 * 2 + 8 * 3, sink)
  end)

  it("allocates nothing publishing a declared topic nobody subscribed to", function()
    local SignalKit = TestEnv.NewPackage()
    local bus = SignalKit:Bus("Quiet")
    bus:DeclareTopic("Unheard")

    local allocated = TestEnv.AllocatedKilobytes(function()
      for _ = 1, 20000 do
        bus:Publish("Unheard", 1)
      end
    end)

    assert.is_true(allocated < 4, allocated .. " KB allocated")
  end)
end)
