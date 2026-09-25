local TestEnv = require("EventKitTestEnv")

-- Channel records, their listener arrays, the tombstone counters and the
-- channel pool are private implementation detail. These specs read them
-- because what they pin is a retention and allocation guarantee (revision 17
-- keeps its own listener arrays and edits them in place while no dispatch
-- runs), which cannot be regression-tested without observing the storage.

---Measure the allocation a workload causes, in kilobytes, with the collector
---stopped so that a collection cycle cannot hide or invent growth.
---@param workload fun()
---@return number kilobytes
local function allocatedKilobytes(workload)
  collectgarbage()
  collectgarbage("stop")
  local before = collectgarbage("count")
  workload()
  local after = collectgarbage("count")
  collectgarbage("restart")
  return after - before
end

-- One unscoped connection handle: a table with a four-slot hash part (64 +
-- 4 * 40 bytes on a 64-bit Lua 5.1). Tolerance above it covers interpreter
-- bookkeeping; a closure or a second record per connection would exceed it.
local HANDLE_BYTES_BOUND = 240

---@param EventKit table
---@param eventName string
---@return table|nil channel
local function channelOf(EventKit, eventName)
  return EventKit._state.regularChannels[eventName]
end

describe("EventKit listener storage with no dispatch running", function()
  local EventKit
  before_each(function()
    EventKit = TestEnv.NewPackage()
  end)
  after_each(TestEnv.Reset)

  it("keeps one handle per connection, holding the callback itself", function()
    local function listener() end
    local connection = EventKit:Connect("CUSTOM_EVENT", listener)
    local channel = channelOf(EventKit, "CUSTOM_EVENT")

    assert.are.equal(connection, channel.listeners[1])
    assert.are.equal(listener, rawget(connection, "_callback"))
    assert.is_nil(rawget(connection, "_inner"))
    assert.is_nil(rawget(channel, "signal"))
  end)

  it("drops a connection disconnected at the tail at once", function()
    for _ = 1, 10 do
      EventKit:Connect("CUSTOM_EVENT", function() end)
    end
    local channel = channelOf(EventKit, "CUSTOM_EVENT")
    local listeners = channel.listeners

    for _ = 1, 100 do
      assert.is_true(EventKit:Connect("CUSTOM_EVENT", function() end):Disconnect())
    end

    assert.are.equal(listeners, channel.listeners)
    assert.are.equal(10, #listeners)
    assert.are.equal(0, channel.tombstones)
    assert.are.equal(10, channel.count)
  end)

  it("compacts in place, keeping the array and connection order", function()
    local calls, connections = {}, {}
    for index = 1, 8 do
      connections[index] = EventKit:Connect("CUSTOM_EVENT", function()
        calls[#calls + 1] = index
      end)
    end
    local channel = channelOf(EventKit, "CUSTOM_EVENT")
    local listeners = channel.listeners

    for index = 1, 7, 2 do
      connections[index]:Disconnect()
    end
    TestEnv.Emit("CUSTOM_EVENT")

    assert.are.equal(listeners, channel.listeners)
    assert.are.equal(4, #listeners)
    assert.are.equal(0, channel.tombstones)
    assert.are.same({ 2, 4, 6, 8 }, calls)
  end)

  it("keeps connection order for a listener connected after the tail was dropped", function()
    local calls = {}
    EventKit:Connect("CUSTOM_EVENT", function()
      calls[#calls + 1] = "first"
    end)
    EventKit:Connect("CUSTOM_EVENT", function()
      calls[#calls + 1] = "dropped"
    end):Disconnect()
    EventKit:Connect("CUSTOM_EVENT", function()
      calls[#calls + 1] = "second"
    end)

    TestEnv.Emit("CUSTOM_EVENT")

    assert.are.same({ "first", "second" }, calls)
  end)

  it("settles a scope's connections in place once its deferred sweep runs", function()
    local scope = EventKit:CreateScope()
    local calls = {}
    scope:Connect("CUSTOM_EVENT", function()
      calls[#calls + 1] = "closer"
      scope:Close()
    end)
    scope:Connect("CUSTOM_EVENT", function()
      calls[#calls + 1] = "in flight"
    end)
    local outside = EventKit:Connect("CUSTOM_EVENT", function()
      calls[#calls + 1] = "outside"
    end)
    local channel = channelOf(EventKit, "CUSTOM_EVENT")

    TestEnv.Emit("CUSTOM_EVENT")
    assert.are.same({ "closer", "in flight", "outside" }, calls)
    assert.are.equal(0, scope:GetActiveCount())

    TestEnv.Emit("CUSTOM_EVENT")
    assert.are.same({ "closer", "in flight", "outside", "outside" }, calls)
    assert.are.equal(1, #channel.listeners)
    assert.is_true(outside:Disconnect())
    assert.is_nil(channelOf(EventKit, "CUSTOM_EVENT"))
  end)
end)

describe("EventKit listener storage during a dispatch", function()
  local EventKit
  before_each(function()
    EventKit = TestEnv.NewPackage()
  end)
  after_each(TestEnv.Reset)

  it("keeps a tail tombstone in place while the dispatch walks the array", function()
    local tail
    local tailCalls = 0
    local slotsDuringDispatch
    EventKit:Connect("CUSTOM_EVENT", function()
      tail:Disconnect()
      slotsDuringDispatch = #channelOf(EventKit, "CUSTOM_EVENT").listeners
    end)
    EventKit:Connect("CUSTOM_EVENT", function() end)
    EventKit:Connect("CUSTOM_EVENT", function() end)
    tail = EventKit:Connect("CUSTOM_EVENT", function()
      tailCalls = tailCalls + 1
    end)

    TestEnv.Emit("CUSTOM_EVENT")

    local channel = channelOf(EventKit, "CUSTOM_EVENT")
    assert.are.equal(0, tailCalls)
    assert.are.equal(4, slotsDuringDispatch)
    assert.are.equal(1, channel.tombstones)
  end)

  it(
    "replaces rather than edits the array once a dispatch disconnects past the threshold",
    function()
      local connections, calls = {}, {}
      for index = 1, 8 do
        connections[index] = EventKit:Connect("CUSTOM_EVENT", function()
          calls[#calls + 1] = index
          if index == 1 then
            for victim = 2, 8 do
              connections[victim]:Disconnect()
            end
          end
        end)
      end
      local channel = channelOf(EventKit, "CUSTOM_EVENT")
      local original = channel.listeners

      TestEnv.Emit("CUSTOM_EVENT")

      assert.are.same({ 1 }, calls)
      assert.are_not.equal(original, channel.listeners)
      assert.are.equal(8, #original)
      assert.are.equal(1, #channel.listeners)
    end
  )

  it("settles a Once listener's tombstone at the next disconnect without a dispatch", function()
    EventKit:Connect("CUSTOM_EVENT", function() end)
    EventKit:Connect("CUSTOM_EVENT", function() end)
    local last = EventKit:Connect("CUSTOM_EVENT", function() end)
    local onceCalls = 0
    EventKit:Once("CUSTOM_EVENT", function()
      onceCalls = onceCalls + 1
    end)
    local channel = channelOf(EventKit, "CUSTOM_EVENT")

    TestEnv.Emit("CUSTOM_EVENT")
    TestEnv.Emit("CUSTOM_EVENT")
    assert.are.equal(1, onceCalls)
    assert.are.equal(4, #channel.listeners)
    assert.are.equal(1, channel.tombstones)

    -- The Once tombstone is the tail; the next disconnect drops both.
    last:Disconnect()
    assert.are.equal(2, #channel.listeners)
    assert.are.equal(0, channel.tombstones)
  end)

  it("defers a listener connected behind a tail tombstone to the next event", function()
    local lateCalls = 0
    EventKit:Connect("CUSTOM_EVENT", function() end)
    EventKit:Once("CUSTOM_EVENT", function()
      EventKit:Connect("CUSTOM_EVENT", function()
        lateCalls = lateCalls + 1
      end)
    end)

    TestEnv.Emit("CUSTOM_EVENT")
    assert.are.equal(0, lateCalls)

    TestEnv.Emit("CUSTOM_EVENT")
    assert.are.equal(1, lateCalls)
  end)

  it(
    "restores the dispatch depth after a listener error, so storage is edited in place again",
    function()
      EventKit:Connect("CUSTOM_EVENT", function()
        error("listener failure", 0)
      end)

      TestEnv.Emit("CUSTOM_EVENT")

      assert.are.equal(1, #TestEnv.TakeReportedErrors())
      assert.are.equal(0, EventKit._state.dispatchDepth)
      EventKit:Connect("CUSTOM_EVENT", function() end):Disconnect()
      assert.are.equal(1, #channelOf(EventKit, "CUSTOM_EVENT").listeners)
    end
  )
end)

describe("EventKit channel record pool", function()
  local EventKit
  before_each(function()
    EventKit = TestEnv.NewPackage()
  end)
  after_each(TestEnv.Reset)

  it("reuses a released channel record for the next event, delivering only that event", function()
    local first = EventKit:Connect("FIRST_EVENT", function() end)
    local record = channelOf(EventKit, "FIRST_EVENT")
    first:Disconnect()

    local calls = 0
    EventKit:Connect("SECOND_EVENT", function(eventName)
      calls = calls + 1
      assert.are.equal("SECOND_EVENT", eventName)
    end)

    assert.are.equal(record, channelOf(EventKit, "SECOND_EVENT"))
    assert.is_nil(channelOf(EventKit, "FIRST_EVENT"))
    TestEnv.Emit("FIRST_EVENT")
    TestEnv.Emit("SECOND_EVENT")
    assert.are.equal(1, calls)
    local frame = TestEnv.Frames()[1]
    assert.are.same({ "FIRST_EVENT", "SECOND_EVENT" }, frame.registerEventCalls)
    assert.are.same({ "FIRST_EVENT" }, frame.unregisterEventCalls)
  end)

  it("keeps at most sixteen released records, each holding no reference", function()
    local connections = {}
    for index = 1, 20 do
      connections[index] = EventKit:Connect("EVENT_" .. index, function() end)
    end
    for index = 1, 20 do
      connections[index]:Disconnect()
    end

    local pool = EventKit._state.channelPool
    assert.are.equal(16, #pool)
    for index = 1, #pool do
      local record = pool[index]
      assert.is_false(record.eventName)
      assert.is_false(record.frame)
      assert.is_false(record.channels)
      assert.is_false(record.group)
      assert.are.equal(0, #record.listeners)
      assert.are.equal(0, record.tombstones)
    end
  end)

  it("does not pool a channel released while a dispatch runs", function()
    local other = EventKit:Connect("OTHER_EVENT", function() end)
    EventKit:Connect("CUSTOM_EVENT", function()
      other:Disconnect()
    end)

    TestEnv.Emit("CUSTOM_EVENT")

    assert.is_nil(channelOf(EventKit, "OTHER_EVENT"))
    assert.are.equal(0, #EventKit._state.channelPool)
  end)

  it("pools a unit channel and releases its group's Frame to the free list", function()
    local calls = 0
    local connection = EventKit:ConnectUnit("UNIT_HEALTH", function() end, "player")
    connection:Disconnect()

    assert.are.equal(1, #EventKit._state.channelPool)
    assert.is_nil(next(EventKit._state.unitGroups))
    assert.are.equal(1, #EventKit._state.unitFrames)

    EventKit:ConnectUnit("UNIT_POWER_UPDATE", function()
      calls = calls + 1
    end, "target")
    TestEnv.Emit("UNIT_POWER_UPDATE", "target")
    assert.are.equal(1, calls)
    assert.are.equal(0, #EventKit._state.channelPool)
    assert.are.equal(1, EventKit._state.unitFrameCount)
  end)
end)

describe("EventKit listener storage allocation #allocation", function()
  local EventKit
  before_each(function()
    EventKit = TestEnv.NewPackage()
  end)
  after_each(TestEnv.Reset)

  it("allocates only the handle to connect and disconnect beside other listeners", function()
    local function listener() end
    for _ = 1, 10 do
      EventKit:Connect("CUSTOM_EVENT", listener)
    end
    EventKit:Connect("CUSTOM_EVENT", listener):Disconnect()

    local bytes = allocatedKilobytes(function()
      for _ = 1, 2000 do
        EventKit:Connect("CUSTOM_EVENT", listener):Disconnect()
      end
    end) * 1024 / 2000

    assert.is_true(bytes < HANDLE_BYTES_BOUND, bytes)
  end)

  it("allocates only the handle to connect and disconnect the only listener", function()
    local function listener() end
    -- The first round creates the Frame, the channel record and the
    -- interned name; every later round reuses the pooled record.
    EventKit:Connect("CUSTOM_EVENT", listener):Disconnect()

    -- The Frame stub records every registration call, which allocates on
    -- its own; that host cost is measured alone and taken off.
    local frame = TestEnv.Frames()[1]
    local hostBytes = allocatedKilobytes(function()
      for _ = 1, 2000 do
        frame:RegisterEvent("CUSTOM_EVENT")
        frame:UnregisterEvent("CUSTOM_EVENT")
      end
    end) * 1024 / 2000
    local bytes = allocatedKilobytes(function()
      for _ = 1, 2000 do
        EventKit:Connect("CUSTOM_EVENT", listener):Disconnect()
      end
    end) * 1024 / 2000

    assert.is_true(bytes - hostBytes < HANDLE_BYTES_BOUND, bytes - hostBytes)
  end)

  it("allocates nothing to disconnect every listener one by one", function()
    local connections = {}
    for index = 1, 2048 do
      connections[index] = EventKit:Connect("CUSTOM_EVENT", function() end)
    end
    -- One more channel keeps the pool from receiving the record, so only
    -- the disconnects are measured.
    EventKit:Connect("OTHER_EVENT", function() end)

    local allocated = allocatedKilobytes(function()
      for index = 1, 2048 do
        connections[index]:Disconnect()
      end
    end)

    assert.is_true(allocated < 4, allocated)
  end)
end)
