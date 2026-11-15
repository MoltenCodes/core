local TestEnv = require("EventKitTestEnv")
local Scheduled = TestEnv.Scheduled

---Fire the most recently created native timer.
---@return boolean fired
local function fireLatest()
  return Scheduled.FireNative(#Scheduled.NativeTimers())
end

---Copy a delivered set, which is emptied as soon as the callback returns.
local function copy(set)
  local result = {}
  for key, value in pairs(set) do
    result[key] = value
  end
  return result
end

---Assert that `callback` fails with `expected` at a line of this spec file.
local function expectErrorAtThisSpec(expected, callback)
  local ok, message = pcall(callback)
  message = tostring(message)
  assert.is_false(ok)
  assert.is_not_nil(string.find(message, expected, 1, true), message)
  assert.is_not_nil(
    string.find(message, "packages/eventKit/tests/Coalesce_spec.lua:", 1, true),
    message
  )
end

---Measure the allocation a workload causes, in kilobytes, with the collector
---stopped so that a collection cycle cannot hide or invent growth.
local function allocatedKilobytes(workload)
  collectgarbage()
  collectgarbage("stop")
  local before = collectgarbage("count")
  workload()
  local after = collectgarbage("count")
  collectgarbage("restart")
  return after - before
end

describe("EventKit Coalesce", function()
  local EventKit
  before_each(function()
    EventKit = Scheduled.NewEventKit()
  end)
  after_each(Scheduled.Reset)

  it("collects payloads keyed by the first argument and delivers once per interval", function()
    local deliveries = {}
    local handle = EventKit:Coalesce({ "UNIT_HEALTH", "UNIT_POWER_UPDATE" }, 0.5, function(set)
      deliveries[#deliveries + 1] = copy(set)
    end)

    Scheduled.Emit("UNIT_HEALTH", "player")
    Scheduled.Emit("UNIT_POWER_UPDATE", "target")
    Scheduled.Emit("UNIT_HEALTH", "player")
    assert.is_true(handle:IsPending())
    -- The first event started the interval; the rest joined it.
    assert.are.equal(1, #Scheduled.NativeTimers())
    assert.are.equal(0.5, Scheduled.NativeTimers()[1].seconds)
    assert.are.same({}, deliveries)

    fireLatest()
    assert.are.same({ { player = true, target = true } }, deliveries)
    assert.is_false(handle:IsPending())
    assert.are.equal(1, handle:GetStats().delivered)
  end)

  it("keys by event name with byEvent, and when the first argument is nil", function()
    local byEvent, byPayload = nil, nil
    EventKit:Coalesce({ "BAG_UPDATE", "BAG_UPDATE_DELAYED" }, 1, function(set)
      byEvent = copy(set)
    end, { byEvent = true })
    EventKit:Coalesce("BAG_UPDATE_DELAYED", 1, function(set)
      byPayload = copy(set)
    end)

    Scheduled.Emit("BAG_UPDATE", 3)
    Scheduled.Emit("BAG_UPDATE_DELAYED")
    Scheduled.FireNative(1)
    Scheduled.FireNative(2)

    assert.are.same({ BAG_UPDATE = true, BAG_UPDATE_DELAYED = true }, byEvent)
    assert.are.same({ BAG_UPDATE_DELAYED = true }, byPayload)
  end)

  it("releases a new unit group when RegisterUnitEvent raises", function()
    EventKit:ConnectUnit("UNIT_POWER_UPDATE", function() end, "focus"):Disconnect()
    -- The released Frame is the one the next unit set re-purposes.
    local frame = EventKit._state.unitFrames[1]
    frame.RegisterUnitEvent = function()
      error("host refused", 0)
    end

    local ok, message = pcall(function()
      EventKit:Coalesce("UNIT_HEALTH", 1, function() end, { units = { "player" } })
    end)
    assert.is_false(ok)
    assert.are.equal("host refused", message)
    assert.is_nil(next(EventKit._state.unitGroups))
    assert.are.equal(1, #EventKit._state.unitFrames)
  end)

  it("subscribes unit events through ConnectUnit semantics", function()
    local delivered = nil
    EventKit:Coalesce("UNIT_HEALTH", 1, function(set)
      delivered = copy(set)
    end, { units = { "target", "player" } })

    local frame = Scheduled.Frames()[1]
    assert.are.equal(1, #frame.registerUnitEventCalls)
    assert.are.same({ "player", "target" }, frame.registerUnitEventCalls[1].units)

    Scheduled.Emit("UNIT_HEALTH", "player")
    Scheduled.Emit("UNIT_HEALTH", "focus")
    fireLatest()
    assert.are.same({ player = true }, delivered)
  end)

  it("flushes early and reports refusals past maxKeys", function()
    local delivered = nil
    local handle = EventKit:Coalesce("UNIT_AURA", 5, function(set)
      delivered = copy(set)
    end, { maxKeys = 1 })

    assert.is_false(handle:Flush())
    Scheduled.Emit("UNIT_AURA", "player")
    Scheduled.Emit("UNIT_AURA", "target")
    assert.are.equal(1, handle:GetStats().refused)
    assert.is_true(handle:Flush())
    assert.are.same({ player = true }, delivered)
  end)

  it("is released by its scope: events, pending delivery and membership", function()
    local scope = EventKit:CreateScope()
    local deliveries = 0
    local handle = scope:Coalesce("UNIT_HEALTH", 1, function()
      deliveries = deliveries + 1
    end)
    assert.are.equal(1, scope:GetActiveCount())

    Scheduled.Emit("UNIT_HEALTH", "player")
    scope:Close()

    assert.is_true(handle:IsClosed())
    assert.is_false(handle:IsPending())
    assert.are.equal(0, scope:GetActiveCount())
    assert.is_nil(Scheduled.Frames()[1].registrations.UNIT_HEALTH)
    assert.is_false(fireLatest())
    Scheduled.Emit("UNIT_HEALTH", "player")
    assert.are.equal(0, deliveries)
    assert.is_false(handle:Close())
    expectErrorAtThisSpec("cannot connect in a closed scope", function()
      scope:Coalesce("UNIT_HEALTH", 1, function() end)
    end)
  end)

  it("defers a scope close inside a dispatch like any connection", function()
    local scope = EventKit:CreateScope()
    EventKit:Connect("PLAYER_LOGOUT", function()
      scope:Close()
    end)
    local delivered = nil
    local handle = scope:Coalesce("PLAYER_LOGOUT", 0, function(set)
      delivered = copy(set)
    end)

    Scheduled.Emit("PLAYER_LOGOUT")
    -- The event in flight still reached the handle, which armed its
    -- interval; the sweep after the dispatch then released both.
    assert.are.equal(1, #Scheduled.NativeTimers())
    assert.is_true(Scheduled.NativeTimers()[1].cancelled)
    assert.is_true(handle:IsClosed())
    assert.is_nil(delivered)
  end)

  it("closes on its own and leaves its scope", function()
    local scope = EventKit:CreateScope()
    local handle = scope:Coalesce("UNIT_HEALTH", 1, function() end)
    assert.is_true(handle:Close())
    assert.are.equal(0, scope:GetActiveCount())
    assert.are.equal(0, handle:GetStats().keys)
  end)

  it("refuses bad arguments at the caller's line", function()
    expectErrorAtThisSpec(
      "EventKit:Coalesce events must be an event name or a non-empty array",
      function()
        EventKit:Coalesce({}, 1, function() end)
      end
    )
    expectErrorAtThisSpec("EventKit:Coalesce eventName must be a non-empty string", function()
      EventKit:Coalesce("", 1, function() end)
    end)
    expectErrorAtThisSpec("EventKit:Coalesce intervalSeconds must be a finite number", function()
      EventKit:Coalesce("UNIT_HEALTH", -1, function() end)
    end)
    expectErrorAtThisSpec("EventKit:Coalesce callback must be a function", function()
      EventKit:Coalesce("UNIT_HEALTH", 1, nil)
    end)
    expectErrorAtThisSpec('EventKit:Coalesce options contains unknown field "unit"', function()
      EventKit:Coalesce("UNIT_HEALTH", 1, function() end, { unit = "player" })
    end)
    -- A table key is named by its type: its `__tostring` is foreign code
    -- that could raise or answer a secret and lose the real refusal.
    local ran = false
    local hostileKey = setmetatable({}, {
      __tostring = function()
        ran = true
        error("foreign __tostring ran", 0)
      end,
    })
    expectErrorAtThisSpec('EventKit:Coalesce options contains unknown field "<table>"', function()
      EventKit:Coalesce("UNIT_HEALTH", 1, function() end, { [hostileKey] = true })
    end)
    expectErrorAtThisSpec('EventKit:Derive options contains unknown field "<table>"', function()
      EventKit:Derive("UNIT_HEALTH", function() end, { [hostileKey] = true })
    end)
    assert.is_false(ran)
    expectErrorAtThisSpec("EventKit:Coalesce accepts at most 2 distinct unit tokens", function()
      EventKit:Coalesce("UNIT_HEALTH", 1, function() end, { units = { "a", "b", "c" } })
    end)
    expectErrorAtThisSpec("EventKit:Coalesce: SchedulerKit.Scope:Coalesce maxKeys", function()
      EventKit:Coalesce("UNIT_HEALTH", 1, function() end, { maxKeys = 0 })
    end)
    expectErrorAtThisSpec("EventKit.Scope:Coalesce must be called on an EventKit scope", function()
      EventKit.Scope.Coalesce({}, "UNIT_HEALTH", 1, function() end)
    end)
    -- A refused call registers nothing.
    assert.are.equal(0, #Scheduled.Frames())
  end)

  it("allocates nothing per event in steady state #allocation", function()
    local handle = EventKit:Coalesce("UNIT_HEALTH", 1, function() end)
    Scheduled.Emit("UNIT_HEALTH", "player")
    Scheduled.Emit("UNIT_HEALTH", "target")

    local allocated = allocatedKilobytes(function()
      for _ = 1, 10000 do
        Scheduled.Emit("UNIT_HEALTH", "player")
        Scheduled.Emit("UNIT_HEALTH", "target")
      end
    end)
    assert.is_true(allocated < 4, "coalesced dispatch allocated " .. allocated .. " KiB")
    assert.are.equal(2, handle:GetStats().keys)
  end)
end)

describe("EventKit Coalesce without TimerKit", function()
  local EventKit
  before_each(function()
    EventKit = TestEnv.NewPackage()
    TestEnv.LoadCoalescing()
  end)
  after_each(TestEnv.Reset)

  it("refuses at the caller's line and registers nothing", function()
    expectErrorAtThisSpec(
      "EventKit:Coalesce requires TimerKit API 1, which is not available (absent)",
      function()
        EventKit:Coalesce("UNIT_HEALTH", 1, function() end)
      end
    )
    local scope = EventKit:CreateScope()
    expectErrorAtThisSpec("EventKit.Scope:Coalesce requires TimerKit API 1", function()
      scope:Coalesce("UNIT_HEALTH", 1, function() end)
    end)
    assert.are.equal(0, #TestEnv.Frames())
    assert.are.equal(0, scope:GetActiveCount())
  end)

  it("still asks for SchedulerKit when a lane is given", function()
    expectErrorAtThisSpec(
      "EventKit:Coalesce requires SchedulerKit API 1, which is not available (absent)",
      function()
        EventKit:Coalesce("UNIT_HEALTH", 1, function() end, { lane = {} })
      end
    )
    assert.are.equal(0, #TestEnv.Frames())
  end)
end)

describe("EventKit Coalesce handle cost", function()
  local EventKit
  before_each(function()
    EventKit = Scheduled.NewEventKit()
  end)
  after_each(Scheduled.Reset)

  it("keeps every handle's timer in the part's one TimerKit scope", function()
    local first = EventKit:Coalesce("UNIT_HEALTH", 0.5, function() end)
    local second = EventKit:CreateScope():Coalesce("UNIT_AURA", 0.5, function() end)
    assert.is_nil(rawget(EventKit._state, "compositeTimerScope"))

    Scheduled.Emit("UNIT_HEALTH", "player")
    Scheduled.Emit("UNIT_AURA", "player")
    local shared = rawget(EventKit._state, "compositeTimerScope")
    assert.are.equal("table", type(shared))
    assert.are.equal(2, shared:GetActiveCount())
    assert.is_nil(rawget(first, "_schedulerScope"))
    assert.is_nil(rawget(first, "_timing"))
    assert.is_nil(rawget(second, "_timing"))
    assert.are.equal(first, rawget(first, "_timer"):GetUserData())
  end)

  it("closes only its own timer and cancels its pending delivery", function()
    local closedDeliveries, openDeliveries = 0, 0
    local closing = EventKit:Coalesce("UNIT_HEALTH", 0.5, function()
      closedDeliveries = closedDeliveries + 1
    end)
    local open = EventKit:Coalesce("UNIT_HEALTH", 0.5, function()
      openDeliveries = openDeliveries + 1
    end)
    Scheduled.Emit("UNIT_HEALTH", "player")

    assert.is_true(closing:Close())
    assert.is_false(rawget(closing, "_timer"))
    assert.is_false(closing:IsPending())
    assert.are.equal(0, closing:GetStats().keys)
    assert.is_true(open:IsPending())
    for index = 1, #Scheduled.NativeTimers() do
      Scheduled.FireNative(index)
    end
    assert.are.equal(0, closedDeliveries)
    assert.are.equal(1, openDeliveries)
    assert.is_false(closing:Close())
  end)

  it("replaces a TimerKit scope that was closed", function()
    EventKit:Coalesce("UNIT_HEALTH", 0.5, function() end)
    Scheduled.Emit("UNIT_HEALTH", "player")
    local shared = rawget(EventKit._state, "compositeTimerScope")
    shared:Close()

    local deliveries = 0
    local handle = EventKit:Coalesce("UNIT_AURA", 0.5, function()
      deliveries = deliveries + 1
    end)
    Scheduled.Emit("UNIT_AURA", "player")
    local replacement = rawget(EventKit._state, "compositeTimerScope")
    assert.are_not.equal(shared, replacement)
    fireLatest()
    assert.are.equal(1, deliveries)
    assert.is_true(handle:Close())
  end)

  it("still closes the SchedulerKit scope of a handle an older revision built", function()
    local SchedulerKit = require("SchedulerKit")
    local handle = EventKit:Coalesce("UNIT_HEALTH", 0.5, function() end)
    -- Revisions before 18 gave each handle a SchedulerKit scope of its own.
    local ownScope = SchedulerKit:CreateScope()
    rawset(handle, "_schedulerScope", ownScope)
    rawset(handle, "_signal", false)

    assert.is_true(handle:Close())
    assert.is_true(ownScope:IsClosed())
    assert.is_false(rawget(handle, "_schedulerScope"))
  end)

  it("looks TimerKit up once and reuses what it found", function()
    EventKit:Coalesce("UNIT_HEALTH", 0.5, function() end):Close()
    local Registry = require("Registry")
    local find = Registry.Find
    local lookups = 0
    Registry.Find = function(...)
      lookups = lookups + 1
      return find(...)
    end
    local ok, failure = pcall(function()
      EventKit:Coalesce("UNIT_HEALTH", 0.5, function() end):Close()
      EventKit:Derive("UNIT_HEALTH", function() end):Close()
    end)
    Registry.Find = find
    assert.is_true(ok, tostring(failure))
    assert.are.equal(0, lookups)
  end)

  it("drops duplicate event names and still bounds the distinct ones", function()
    local deliveries = {}
    local handle = EventKit:Coalesce(
      { "UNIT_HEALTH", "UNIT_AURA", "UNIT_HEALTH" },
      0.5,
      function(set)
        deliveries[#deliveries + 1] = copy(set)
      end,
      { byEvent = true }
    )
    assert.are.equal(2, #rawget(handle, "_connections"))

    local tooMany, mixed = {}, {}
    for index = 1, 33 do
      tooMany[index] = "EVENT_" .. index
      mixed[index] = "EVENT_" .. index
    end
    mixed[34] = 7
    expectErrorAtThisSpec("EventKit:Coalesce accepts at most 32 distinct events", function()
      EventKit:Coalesce(tooMany, 0.5, function() end)
    end)
    -- Every entry is still checked, so a bad one after the bound names itself.
    expectErrorAtThisSpec("EventKit:Coalesce events must contain only non-empty strings", function()
      EventKit:Coalesce(mixed, 0.5, function() end)
    end)
  end)

  it("creates and closes a handle in under 2.5 KiB #allocation", function()
    local function callback() end
    EventKit:Coalesce({ "UNIT_HEALTH", "UNIT_AURA" }, 0.5, callback):Close()

    local handles = 100
    local allocated = allocatedKilobytes(function()
      for _ = 1, handles do
        EventKit:Coalesce({ "UNIT_HEALTH", "UNIT_AURA" }, 0.5, callback):Close()
      end
    end)
    assert.is_true(
      allocated / handles < 2.5,
      "one handle allocated " .. allocated / handles .. " KiB"
    )
  end)
end)

describe("EventKit Coalesce with TimerKit loaded later", function()
  after_each(Scheduled.Reset)

  it("finds TimerKit once it loads after a refused call", function()
    Scheduled.Reset()
    Scheduled.InstallWowApi()
    require("Registry")
    require("SignalKit")
    local EventKit = require("EventKit")
    TestEnv.LoadCoalescing()
    local ok = pcall(EventKit.Coalesce, EventKit, "UNIT_HEALTH", 0.5, function() end)
    assert.is_false(ok)

    require("TimerKit")
    local handle = EventKit:Coalesce("UNIT_HEALTH", 0.5, function() end)
    assert.is_false(handle:IsClosed())
    assert.is_true(handle:Close())
  end)
end)

describe("EventKit Coalesce across an upgrade", function()
  after_each(Scheduled.Reset)

  it("keeps a handle from revision 17 delivering and closing under this revision", function()
    Scheduled.Reset()
    Scheduled.InstallWowApi()
    require("Registry")
    require("SignalKit")
    require("TimerKit")
    local legacy = TestEnv.LoadSourceAtRevision(17)
    local SchedulerKit = require("SchedulerKit")
    local deliveries = 0
    local handle = legacy:Coalesce("UNIT_HEALTH", 0.5, function()
      deliveries = deliveries + 1
    end)
    -- Revision 17 gave each handle a SchedulerKit scope of its own.
    local ownScope = SchedulerKit:CreateScope()
    rawset(handle, "_schedulerScope", ownScope)

    package.loaded["EventKit"] = nil
    local EventKit = require("EventKit")
    TestEnv.LoadCoalescing()
    assert.are.equal(legacy, EventKit)
    assert.are.equal(22, EventKit.REVISION)

    Scheduled.Emit("UNIT_HEALTH", "player")
    fireLatest()
    assert.are.equal(1, deliveries)
    assert.is_true(handle:Close())
    assert.is_true(ownScope:IsClosed())

    local fresh = EventKit:Coalesce("UNIT_AURA", 0.5, function() end)
    assert.is_nil(rawget(fresh, "_schedulerScope"))
    assert.is_true(fresh:Close())
  end)
end)
