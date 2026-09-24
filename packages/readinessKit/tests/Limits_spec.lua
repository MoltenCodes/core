local TestEnv = require("ReadinessKitTestEnv")

-- Design principle 4a: a gate's waiter queue holds the consumer's own
-- callbacks, so `maxWaiters` accepts `ReadinessKit.UNBOUNDED`.
describe("ReadinessKit limits", function()
  local ReadinessKit
  before_each(function()
    ReadinessKit = TestEnv.NewPackage()
  end)
  after_each(TestEnv.Reset)

  it("publishes one UNBOUNDED sentinel that survives a reload", function()
    local sentinel = ReadinessKit.UNBOUNDED
    assert.are.equal("table", type(sentinel))
    assert.are.equal(sentinel, TestEnv.ReloadPackage().UNBOUNDED)
  end)

  it("queues past 64 waiters with maxWaiters = UNBOUNDED and calls each once", function()
    local ready = false
    local gate = ReadinessKit:Gate("unbounded", function()
      return ready
    end, { maxWaiters = ReadinessKit.UNBOUNDED })
    local calls = 0
    for _ = 1, 200 do
      assert.is_not_nil(gate:Await(function(isReady)
        if isReady then
          calls = calls + 1
        end
      end))
    end

    ready = true
    TestEnv.Poll(500)

    assert.are.equal(200, calls)
  end)

  it("still refuses the waiter past a numeric maxWaiters", function()
    local gate = ReadinessKit:Gate("bounded", function()
      return false
    end, { maxWaiters = 2 })
    assert.is_not_nil(gate:Await(function() end))
    assert.is_not_nil(gate:Await(function() end))
    assert.are.same({ nil, "full" }, { gate:Await(function() end) })
  end)

  it("refuses any other table as maxWaiters", function()
    TestEnv.expectErrorContaining(
      "ReadinessKit:Gate maxWaiters must be a positive integer or ReadinessKit.UNBOUNDED",
      function()
        ReadinessKit:Gate("wrong", function() end, { maxWaiters = {} })
      end
    )
  end)
end)
