local TestEnv = require("EventKitTestEnv")
local Scheduled = TestEnv.Scheduled

---Fire the most recently created native timer.
---@return boolean fired
local function fireLatest()
  return Scheduled.FireNative(#Scheduled.NativeTimers())
end

---Copy a delivered set, which SchedulerKit wipes as soon as the callback returns.
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

describe("EventKit Coalesce without SchedulerKit", function()
  local EventKit
  before_each(function()
    EventKit = TestEnv.NewPackage()
  end)
  after_each(TestEnv.Reset)

  it("refuses at the caller's line and registers nothing", function()
    expectErrorAtThisSpec(
      "EventKit:Coalesce requires SchedulerKit API 1, which is not available (absent)",
      function()
        EventKit:Coalesce("UNIT_HEALTH", 1, function() end)
      end
    )
    local scope = EventKit:CreateScope()
    expectErrorAtThisSpec("EventKit.Scope:Coalesce requires SchedulerKit API 1", function()
      scope:Coalesce("UNIT_HEALTH", 1, function() end)
    end)
    assert.are.equal(0, #TestEnv.Frames())
    assert.are.equal(0, scope:GetActiveCount())
  end)
end)

describe("EventKit Coalesce handle cost", function()
  local EventKit, SchedulerKit
  before_each(function()
    EventKit, SchedulerKit = Scheduled.NewEventKit()
  end)
  after_each(Scheduled.Reset)

  it("keeps every handle's timing in one shared SchedulerKit scope", function()
    local first = EventKit:Coalesce("UNIT_HEALTH", 0.5, function() end)
    local second = EventKit:CreateScope():Coalesce("UNIT_AURA", 0.5, function() end)

    local shared = rawget(EventKit._state, "coalesceSchedulerScope")
    assert.are.equal("table", type(shared))
    assert.is_false(shared:IsClosed())
    assert.is_nil(rawget(first, "_schedulerScope"))
    assert.is_nil(rawget(second, "_schedulerScope"))
    assert.are.equal(shared, rawget(rawget(first, "_timing"), "_scope"))
    assert.are.equal(shared, rawget(rawget(second, "_timing"), "_scope"))
  end)

  it("closes only its own timing handle and cancels its pending delivery", function()
    local closedDeliveries, openDeliveries = 0, 0
    local closing = EventKit:Coalesce("UNIT_HEALTH", 0.5, function()
      closedDeliveries = closedDeliveries + 1
    end)
    local open = EventKit:Coalesce("UNIT_HEALTH", 0.5, function()
      openDeliveries = openDeliveries + 1
    end)
    Scheduled.Emit("UNIT_HEALTH", "player")

    assert.is_true(closing:Close())
    assert.is_true(rawget(closing, "_timing"):IsClosed())
    assert.is_false(closing:IsPending())
    assert.is_true(open:IsPending())
    for index = 1, #Scheduled.NativeTimers() do
      Scheduled.FireNative(index)
    end
    assert.are.equal(0, closedDeliveries)
    assert.are.equal(1, openDeliveries)
    assert.is_false(closing:Close())
  end)

  it("replaces a shared scope that was closed", function()
    EventKit:Coalesce("UNIT_HEALTH", 0.5, function() end)
    local shared = rawget(EventKit._state, "coalesceSchedulerScope")
    shared:Close()

    local deliveries = 0
    local handle = EventKit:Coalesce("UNIT_AURA", 0.5, function()
      deliveries = deliveries + 1
    end)
    local replacement = rawget(EventKit._state, "coalesceSchedulerScope")
    assert.are_not.equal(shared, replacement)
    Scheduled.Emit("UNIT_AURA", "player")
    fireLatest()
    assert.are.equal(1, deliveries)
    assert.is_true(handle:Close())
  end)

  it("still closes the SchedulerKit scope of a handle an older revision built", function()
    local handle = EventKit:Coalesce("UNIT_HEALTH", 0.5, function() end)
    -- Revisions before 18 gave each handle a SchedulerKit scope of its own.
    local ownScope = SchedulerKit:CreateScope()
    rawset(handle, "_schedulerScope", ownScope)
    rawset(handle, "_signal", false)

    assert.is_true(handle:Close())
    assert.is_true(ownScope:IsClosed())
    assert.is_false(rawget(handle, "_schedulerScope"))
  end)

  it("looks SchedulerKit up once and reuses what it found", function()
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

describe("EventKit Coalesce with SchedulerKit loaded later", function()
  after_each(Scheduled.Reset)

  it("finds SchedulerKit once it loads after a refused call", function()
    Scheduled.Reset()
    Scheduled.InstallWowApi()
    require("Registry")
    require("SignalKit")
    local EventKit = require("EventKit")
    local ok = pcall(EventKit.Coalesce, EventKit, "UNIT_HEALTH", 0.5, function() end)
    assert.is_false(ok)

    require("TimerKit")
    require("SchedulerKit")
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
    local legacy = TestEnv.LoadSourceAtRevision(17)
    require("TimerKit")
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
    assert.are.equal(legacy, EventKit)
    assert.are.equal(18, EventKit.REVISION)

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
