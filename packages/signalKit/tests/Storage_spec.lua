local TestEnv = require("SignalKitTestEnv")

-- The listener array, its tombstone counter and the dispatch depth are private
-- implementation detail. These specs read them because what they pin is a
-- retention and allocation guarantee (revision 9 edits the array in place
-- while no dispatch walks it), and such a guarantee cannot be regression-
-- tested without observing the array.

---@param signal table
---@return table
local function listenersOf(signal)
  return rawget(signal, "_listeners")
end

---@param signal table
---@return integer
local function tombstonesOf(signal)
  return rawget(signal, "_tombstones")
end

---The topic signal behind `topic` on `bus`, once something subscribed to it.
---@param bus table
---@param topic string
---@return table
local function topicSignal(bus, topic)
  return rawget(rawget(rawget(bus, "_topics"), topic), "signal")
end

---Bytes per operation a workload of `operations` operations allocates.
---@param operations integer
---@param workload fun()
---@return number
local function bytesPerOperation(operations, workload)
  return TestEnv.AllocatedKilobytes(workload) * 1024 / operations
end

-- One unscoped connection handle: a table with a four-slot hash part (64 +
-- 4 * 40 bytes on a 64-bit Lua 5.1). Tolerance above it covers interpreter
-- bookkeeping; a compaction array or a closure per connection would exceed it.
local HANDLE_BYTES_BOUND = 240

describe("SignalKit listener storage with no dispatch running", function()
  local SignalKit

  before_each(function()
    SignalKit = TestEnv.NewPackage()
  end)

  after_each(TestEnv.Reset)

  it("drops a connection disconnected at the tail at once", function()
    local signal = SignalKit:New()
    for _ = 1, 10 do
      signal:Connect(function() end)
    end
    local listeners = listenersOf(signal)

    for _ = 1, 100 do
      assert.is_true(signal:Connect(function() end):Disconnect())
    end

    assert.are.equal(listeners, listenersOf(signal))
    assert.are.equal(10, #listeners)
    assert.are.equal(0, tombstonesOf(signal))
  end)

  it("drops the tombstones a tail disconnect leaves at the end", function()
    local signal = SignalKit:New()
    signal:Connect(function() end)
    local second = signal:Connect(function() end)
    local third = signal:Connect(function() end)

    second:Disconnect()
    assert.are.equal(3, #listenersOf(signal))
    assert.are.equal(1, tombstonesOf(signal))

    third:Disconnect()
    assert.are.equal(1, #listenersOf(signal))
    assert.are.equal(0, tombstonesOf(signal))
  end)

  it("compacts in place, keeping the array and connection order", function()
    local signal = SignalKit:New()
    local calls, connections = {}, {}
    for index = 1, 8 do
      connections[index] = signal:Connect(function()
        calls[#calls + 1] = index
      end)
    end
    local listeners = listenersOf(signal)

    for index = 1, 7, 2 do
      connections[index]:Disconnect()
    end
    signal:Fire()

    assert.are.equal(listeners, listenersOf(signal))
    assert.are.equal(4, #listeners)
    assert.are.equal(0, tombstonesOf(signal))
    assert.are.same({ 2, 4, 6, 8 }, calls)
  end)

  it("keeps connection order for a listener connected after the tail was dropped", function()
    local signal = SignalKit:New()
    local calls = {}
    signal:Connect(function()
      calls[#calls + 1] = "first"
    end)
    signal
      :Connect(function()
        calls[#calls + 1] = "dropped"
      end)
      :Disconnect()
    signal:Connect(function()
      calls[#calls + 1] = "second"
    end)

    signal:Fire()

    assert.are.same({ "first", "second" }, calls)
  end)

  it("empties the array in place on DisconnectAll", function()
    local signal = SignalKit:New()
    local connections = {}
    for index = 1, 5 do
      connections[index] = signal:Connect(function() end)
    end
    local listeners = listenersOf(signal)

    assert.are.equal(5, signal:DisconnectAll())

    assert.are.equal(listeners, listenersOf(signal))
    assert.are.equal(0, #listeners)
    for index = 1, 5 do
      assert.is_false(connections[index]:IsConnected())
    end
  end)

  it("runs onLast once when the last listener is dropped at the tail", function()
    local transitions = {}
    local signal = SignalKit:New({
      onFirst = function()
        transitions[#transitions + 1] = "first"
      end,
      onLast = function()
        transitions[#transitions + 1] = "last"
      end,
    })

    signal:Connect(function() end):Disconnect()
    signal:Connect(function() end):Disconnect()

    assert.are.same({ "first", "last", "first", "last" }, transitions)
  end)
end)

describe("SignalKit listener storage during a dispatch", function()
  local SignalKit

  before_each(function()
    SignalKit = TestEnv.NewPackage()
  end)

  after_each(TestEnv.Reset)

  it("keeps a tail tombstone in place while the dispatch walks the array", function()
    local signal = SignalKit:New()
    local tail
    local tailCalls = 0
    local slotsDuringDispatch
    signal:Connect(function()
      tail:Disconnect()
      slotsDuringDispatch = #listenersOf(signal)
    end)
    signal:Connect(function() end)
    signal:Connect(function() end)
    tail = signal:Connect(function()
      tailCalls = tailCalls + 1
    end)

    signal:Fire()

    assert.are.equal(0, tailCalls)
    assert.are.equal(4, slotsDuringDispatch)
    assert.are.equal(4, #listenersOf(signal))
    assert.are.equal(1, tombstonesOf(signal))
  end)

  it(
    "replaces rather than edits the array once a dispatch disconnects past the threshold",
    function()
      local signal = SignalKit:New()
      local connections, calls = {}, {}
      local original = nil
      for index = 1, 8 do
        connections[index] = signal:Connect(function()
          calls[#calls + 1] = index
          if index == 1 then
            for victim = 2, 8 do
              connections[victim]:Disconnect()
            end
          end
        end)
      end
      original = listenersOf(signal)

      signal:Fire()

      assert.are.same({ 1 }, calls)
      assert.are_not.equal(original, listenersOf(signal))
      -- The array the dispatch walked was left whole.
      assert.are.equal(8, #original)
      assert.are.equal(1, #listenersOf(signal))
    end
  )

  it("settles a Once listener's tombstone at the next disconnect without a dispatch", function()
    local signal = SignalKit:New()
    signal:Connect(function() end)
    signal:Connect(function() end)
    local last = signal:Connect(function() end)
    local onceCalls = 0
    signal:Once(function()
      onceCalls = onceCalls + 1
    end)

    signal:Fire()
    signal:Fire()
    assert.are.equal(1, onceCalls)
    assert.are.equal(4, #listenersOf(signal))
    assert.are.equal(1, tombstonesOf(signal))

    -- The Once tombstone is the tail; the next disconnect drops both.
    last:Disconnect()
    assert.are.equal(2, #listenersOf(signal))
    assert.are.equal(0, tombstonesOf(signal))
  end)

  it("defers a listener connected during Fire behind a tail tombstone to the next Fire", function()
    local signal = SignalKit:New()
    local lateCalls = 0
    signal:Once(function()
      signal:Connect(function()
        lateCalls = lateCalls + 1
      end)
    end)

    signal:Fire()
    assert.are.equal(0, lateCalls)

    signal:Fire()
    assert.are.equal(1, lateCalls)
  end)

  it("restores the depth of a nested Fire whose error an outer listener caught", function()
    local signal = SignalKit:New()
    local nested = false
    signal:Connect(function()
      if not nested then
        nested = true
        assert.is_false((pcall(signal.Fire, signal)))
      else
        error("nested failure", 0)
      end
    end)

    signal:Fire()

    assert.are.equal(0, rawget(signal, "_firing"))
    -- In-place editing works again: a tail disconnect is dropped at once.
    signal:Connect(function() end):Disconnect()
    assert.are.equal(1, #listenersOf(signal))
  end)

  it(
    "keeps a signal usable after a listener error escapes Fire, compacting by replacement",
    function()
      local signal = SignalKit:New()
      local calls = 0
      local failing = signal:Connect(function()
        error("listener failure", 0)
      end)
      signal:Connect(function()
        calls = calls + 1
      end)

      local ok, message = pcall(signal.Fire, signal)
      assert.is_false(ok)
      assert.are.equal("listener failure", message)

      -- The escaped error left the depth raised, so the array is no longer
      -- edited in place; everything observable still behaves.
      assert.is_true(failing:Disconnect())
      local before = listenersOf(signal)
      local extra = signal:Connect(function() end)
      assert.is_true(extra:Disconnect())
      signal:Fire()
      assert.are.equal(1, calls)
      assert.are_not.equal(before, listenersOf(signal))
      assert.is_true(#listenersOf(signal) <= 2)
    end
  )
end)

describe("SignalKit bus storage", function()
  local SignalKit

  before_each(function()
    SignalKit = TestEnv.NewPackage()
    TestEnv.InstallHostErrorHandler()
  end)

  after_each(TestEnv.Reset)

  it("holds the subscriber's own callback and isolates it at Fire", function()
    local bus = SignalKit:Bus("Storage", { openTopics = true })
    local calls = 0
    local function subscriber()
      calls = calls + 1
      error("subscriber failure", 0)
    end
    local connection = bus:Subscribe("Topic", subscriber)

    bus:Publish("Topic")

    assert.are.equal(subscriber, rawget(connection, "_callback"))
    assert.is_nil(rawget(connection, "_busCallback"))
    assert.is_true(rawget(topicSignal(bus, "Topic"), "_isolated"))
    assert.are.equal(1, calls)
    assert.are.equal(1, #TestEnv.TakeReportedErrors())
  end)

  it("Unsubscribe settles the array in place after its walk", function()
    local bus = SignalKit:Bus("Storage", { openTopics = true })
    local calls = {}
    local function removed() end
    local function kept()
      calls[#calls + 1] = "kept"
    end
    for _ = 1, 3 do
      bus:Subscribe("Topic", removed)
      bus:Subscribe("Topic", kept)
    end
    local signal = topicSignal(bus, "Topic")
    local listeners = listenersOf(signal)

    assert.are.equal(3, bus:Unsubscribe("Topic", removed))
    bus:Publish("Topic")

    assert.are.equal(listeners, listenersOf(signal))
    assert.are.equal(3, #listeners)
    assert.are.equal(0, tombstonesOf(signal))
    assert.are.same({ "kept", "kept", "kept" }, calls)
  end)

  it("counts live subscriptions against maxListeners, not tombstones", function()
    local bus = SignalKit:Bus("Storage", { openTopics = true, maxListeners = 2 })
    local first = bus:Subscribe("Topic", function() end)
    bus:Subscribe("Topic", function() end)
    first:Disconnect()

    assert.is_not_nil(bus:Subscribe("Topic", function() end))
    local refused, reason = bus:Subscribe("Topic", function() end)
    assert.is_nil(refused)
    assert.are.equal("full", reason)
  end)

  it(
    "skips the rest of a scope closed during a publish, then settles at the next disconnect",
    function()
      local bus = SignalKit:Bus("Storage", { openTopics = true })
      local scope = bus:CreateScope()
      local calls = {}
      scope:Subscribe("Topic", function()
        calls[#calls + 1] = "closer"
        scope:Close()
      end)
      scope:Subscribe("Topic", function()
        calls[#calls + 1] = "skipped"
      end)
      local outside = bus:Subscribe("Topic", function()
        calls[#calls + 1] = "outside"
      end)

      bus:Publish("Topic")
      assert.are.same({ "closer", "outside" }, calls)

      outside:Disconnect()
      assert.are.equal(0, #listenersOf(topicSignal(bus, "Topic")))
    end
  )
end)

describe("SignalKit storage allocation #allocation", function()
  local SignalKit

  before_each(function()
    SignalKit = TestEnv.NewPackage()
  end)

  after_each(TestEnv.Reset)

  it("allocates only the handle per Connect and Disconnect beside other listeners", function()
    local signal = SignalKit:New()
    local function listener() end
    for _ = 1, 10 do
      signal:Connect(listener)
    end
    signal:Connect(listener):Disconnect()

    local bytes = bytesPerOperation(2000, function()
      for _ = 1, 2000 do
        signal:Connect(listener):Disconnect()
      end
    end)

    assert.is_true(bytes < HANDLE_BYTES_BOUND, bytes)
  end)

  it("allocates only the handle per bus Subscribe and Disconnect", function()
    TestEnv.InstallHostErrorHandler()
    local bus = SignalKit:Bus("Storage", { openTopics = true })
    local function listener() end
    for _ = 1, 10 do
      bus:Subscribe("Topic", listener)
    end
    bus:Subscribe("Topic", listener):Disconnect()

    local bytes = bytesPerOperation(2000, function()
      for _ = 1, 2000 do
        bus:Subscribe("Topic", listener):Disconnect()
      end
    end)

    assert.is_true(bytes < HANDLE_BYTES_BOUND, bytes)
  end)

  it("allocates nothing to disconnect every listener one by one", function()
    local signal = SignalKit:New()
    local connections = {}
    for index = 1, 4096 do
      connections[index] = signal:Connect(function() end)
    end

    -- Front to back: every compaction threshold is crossed on the way.
    local allocated = TestEnv.AllocatedKilobytes(function()
      for index = 1, 4096 do
        connections[index]:Disconnect()
      end
    end)

    assert.is_true(allocated < 4, allocated)
    assert.are.equal(0, #listenersOf(signal))
  end)

  it("allocates nothing for DisconnectAll or Unsubscribe", function()
    TestEnv.InstallHostErrorHandler()
    local signal = SignalKit:New()
    local bus = SignalKit:Bus("Storage", { openTopics = true })
    local function listener() end
    for _ = 1, 256 do
      signal:Connect(listener)
      bus:Subscribe("Topic", listener)
    end

    local allocated = TestEnv.AllocatedKilobytes(function()
      signal:DisconnectAll()
      bus:Unsubscribe("Topic", listener)
    end)

    assert.is_true(allocated < 1, allocated)
  end)
end)
