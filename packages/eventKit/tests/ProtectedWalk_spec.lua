-- A channel's listener walk runs under `pcall` only while something in it can
-- raise: a one-shot listener, whose release talks to the host, or a signal a
-- revision before 17 left on the channel. Listener calls are isolated either
-- way, so a raising listener never reaches the walk.
local TestEnv = require("EventKitTestEnv")

local function noop() end

---Count the global `pcall` calls `workload` makes.
---@param workload fun()
---@return integer calls
local function countProtectedCalls(workload)
  local original = pcall
  local calls = 0
  -- EventKit resolves `pcall` as a global at call time, so the spec wraps it there.
  -- selene: allow(global_usage)
  rawset(_G, "pcall", function(...)
    calls = calls + 1
    return original(...)
  end)
  local ok, failure = original(workload)
  -- selene: allow(global_usage)
  rawset(_G, "pcall", original)
  if not ok then
    error(failure, 0)
  end
  return calls
end

---@param EventKit table
---@param eventName string
---@return table channel
local function channelOf(EventKit, eventName)
  return EventKit._state.regularChannels[eventName]
end

describe("EventKit protected listener walk", function()
  local EventKit

  before_each(function()
    EventKit = TestEnv.NewPackage()
  end)
  after_each(TestEnv.Reset)

  it("walks a channel of ordinary listeners without a protected call", function()
    EventKit:Connect("BAG_UPDATE", noop)
    EventKit:Connect("BAG_UPDATE", noop)

    local calls = countProtectedCalls(function()
      TestEnv.Emit("BAG_UPDATE")
    end)

    assert.are.equal(0, calls)
    assert.is_nil(channelOf(EventKit, "BAG_UPDATE").onceCount)
  end)

  it("counts the live one-shots of a channel and protects the walk while any is left", function()
    EventKit:Connect("BAG_UPDATE", noop)
    local first = EventKit:Once("BAG_UPDATE", noop)
    EventKit:Once("BAG_UPDATE", noop)
    local channel = channelOf(EventKit, "BAG_UPDATE")
    assert.are.equal(2, channel.onceCount)

    first:Disconnect()
    assert.are.equal(1, channel.onceCount)

    local calls = countProtectedCalls(function()
      TestEnv.Emit("BAG_UPDATE")
    end)
    assert.are.equal(1, calls)
    assert.are.equal(0, channel.onceCount)

    calls = countProtectedCalls(function()
      TestEnv.Emit("BAG_UPDATE")
    end)
    assert.are.equal(0, calls)
  end)

  it("restores the dispatch depth when a one-shot's host release raises", function()
    local failure = { reason = "host refused" }
    local delivered = 0
    EventKit:Once("BAG_UPDATE", function()
      delivered = delivered + 1
    end)
    local frame = TestEnv.Frames()[1]
    local unregister = frame.UnregisterEvent
    function frame:UnregisterEvent()
      error(failure, 0)
    end

    local ok, raised = pcall(TestEnv.Emit, "BAG_UPDATE")
    frame.UnregisterEvent = unregister

    assert.is_false(ok)
    assert.are.equal(failure, raised)
    assert.are.equal(0, EventKit._state.dispatchDepth)
    -- A later scope close is not deferred by a stuck depth.
    local scope = EventKit:CreateScope()
    local connection = scope:Connect("PLAYER_LOGIN", noop)
    scope:Close()
    assert.is_false(connection:IsConnected())
    assert.are.equal(0, delivered)
  end)

  it("keeps delivering past a raising listener on the unprotected walk", function()
    local delivered = 0
    EventKit:Connect("BAG_UPDATE", function()
      error("listener failure")
    end)
    EventKit:Connect("BAG_UPDATE", function()
      delivered = delivered + 1
    end)

    TestEnv.Emit("BAG_UPDATE")

    assert.are.equal(1, delivered)
    assert.are.equal(1, #TestEnv.ReportedErrors())
    assert.are.equal(0, EventKit._state.dispatchDepth)
  end)

  it("resets the one-shot count of a pooled channel record", function()
    local once = EventKit:Once("BAG_UPDATE", noop)
    local channel = channelOf(EventKit, "BAG_UPDATE")
    -- A bookkeeping slip leaves the count high; pooling clears it.
    channel.onceCount = 5
    once:Disconnect()
    assert.are.equal(0, channel.onceCount)
  end)
end)
