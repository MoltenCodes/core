local TestEnv = require("ReadinessKitTestEnv")

describe("ReadinessKit waiters", function()
  local ReadinessKit
  local ready
  local gate
  before_each(function()
    ReadinessKit = TestEnv.NewPackage()
    ready = false
    gate = ReadinessKit:Gate("spellbook", function()
      return ready
    end, { maxWaiters = 3 })
  end)
  after_each(TestEnv.Reset)

  it("calls queued waiters once, in the order they were queued", function()
    local order = {}
    for index = 1, 3 do
      gate:Await(function(isReady, reason)
        order[#order + 1] = { index, isReady, reason }
      end)
    end

    ready = true
    TestEnv.Poll(500)
    assert.are.same({ { 1, true }, { 2, true }, { 3, true } }, order)

    gate:Invalidate()
    TestEnv.Poll(500)
    assert.are.equal(3, #order)
  end)

  it("refuses with full beyond maxWaiters", function()
    for _ = 1, 3 do
      assert.is_not_nil(gate:Await(function() end))
    end
    local waiter, reason = gate:Await(function() end)
    assert.is_nil(waiter)
    assert.are.equal("full", reason)
  end)

  it("frees a slot when a waiter is cancelled", function()
    local handles = {}
    for index = 1, 3 do
      handles[index] = gate:Await(function() end)
    end
    assert.is_true(handles[2]:Cancel())
    assert.is_false(handles[2]:Cancel())
    assert.is_false(handles[2]:IsPending())
    assert.is_not_nil(gate:Await(function() end))
  end)

  it("never calls a cancelled waiter and keeps the order of the rest", function()
    local order = {}
    local handles = {}
    for index = 1, 3 do
      handles[index] = gate:Await(function()
        order[#order + 1] = index
      end)
    end
    handles[1]:Cancel()

    ready = true
    TestEnv.Poll(500)
    assert.are.same({ 2, 3 }, order)
    assert.is_false(handles[2]:IsPending())
  end)

  it("honours a Cancel made by an earlier callback of the same batch", function()
    local order = {}
    local second
    gate:Await(function()
      order[#order + 1] = 1
      assert.is_true(second:Cancel())
    end)
    second = gate:Await(function()
      order[#order + 1] = 2
    end)
    gate:Await(function()
      order[#order + 1] = 3
    end)

    ready = true
    TestEnv.Poll(500)
    assert.are.same({ 1, 3 }, order)
  end)

  it("reports a queued callback's error to the host handler and continues the batch", function()
    local order = {}
    gate:Await(function()
      error("first failure", 0)
    end)
    gate:Await(function()
      order[#order + 1] = "second"
    end)
    gate:Await(function()
      error("third failure", 0)
    end)

    ready = true
    TestEnv.Poll(500)
    assert.are.same({ "second" }, order)
    assert.are.same({ "first failure", "third failure" }, TestEnv.ReportedErrors())
    assert.is_true(gate:IsReady())
  end)

  it("raises an immediate callback's error at the Await caller", function()
    ready = true
    TestEnv.AdvanceMs(500)
    gate:Probe()
    local ok, message = pcall(gate.Await, gate, function()
      error("immediate failure", 0)
    end)
    assert.is_false(ok)
    assert.are.equal("immediate failure", message)
    assert.are.same({}, TestEnv.ReportedErrors())
  end)

  it("reuses the waiter arrays across rounds", function()
    local first = rawget(gate, "_waiters")
    local spare = rawget(gate, "_spareWaiters")
    gate:Await(function() end)
    ready = true
    TestEnv.Poll(500)
    gate:Invalidate()
    ready = false
    gate:Await(function() end)
    ready = true
    TestEnv.Poll(500)

    assert.are.equal(first, rawget(gate, "_waiters"))
    assert.are.equal(spare, rawget(gate, "_spareWaiters"))
  end)
end)
