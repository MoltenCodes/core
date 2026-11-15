local TestEnv = require("EventKitTestEnv")
local Timed = TestEnv.Timed
local Scheduled = TestEnv.Scheduled

-- Revision 22 times `Coalesce` and `Derive` by TimerKit, inside the
-- Coalescing part, with the semantics SchedulerKit documents for its own
-- `Coalesce` and `Debounce` (schedulerKit docs/API.md, "Coalescing and
-- lanes"). Each spec below is one of those rules, run with no SchedulerKit
-- loaded at all.

---Fire the most recently created native timer.
---@return boolean fired
local function fireLatest()
  return Timed.FireNative(#Timed.NativeTimers())
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
    string.find(message, "packages/eventKit/tests/Timing_spec.lua:", 1, true),
    message
  )
end

describe("EventKit Coalesce timed by TimerKit", function()
  local EventKit
  before_each(function()
    EventKit = Timed.NewEventKit()
  end)
  after_each(Timed.Reset)

  it("needs no SchedulerKit", function()
    assert.is_nil(package.loaded["SchedulerKit"])
    local handle = EventKit:Coalesce("UNIT_HEALTH", 0.5, function() end)
    assert.is_false(handle:IsClosed())
  end)

  it("starts the interval at the first key and arms one timer per burst", function()
    local deliveries = {}
    local handle = EventKit:Coalesce("UNIT_HEALTH", 0.25, function(set)
      deliveries[#deliveries + 1] = copy(set)
    end)
    assert.are.equal(0, #Timed.NativeTimers())

    Timed.Emit("UNIT_HEALTH", "player")
    Timed.Emit("UNIT_HEALTH", "target")
    Timed.Emit("UNIT_HEALTH", "player")
    assert.are.equal(1, #Timed.NativeTimers())
    assert.are.equal(0.25, Timed.NativeTimers()[1].seconds)

    fireLatest()
    assert.are.same({ { player = true, target = true } }, deliveries)
    assert.is_false(handle:IsPending())

    -- The next key starts the next interval.
    Timed.Emit("UNIT_HEALTH", "focus")
    assert.are.equal(2, #Timed.NativeTimers())
    fireLatest()
    assert.are.same({ focus = true }, deliveries[2])
  end)

  it("refuses new keys past maxKeys, counts them, and still updates a known key", function()
    local delivered = nil
    local handle = EventKit:Coalesce("UNIT_AURA", 1, function(set)
      delivered = copy(set)
    end, { maxKeys = 2 })

    Timed.Emit("UNIT_AURA", "player")
    Timed.Emit("UNIT_AURA", "target")
    Timed.Emit("UNIT_AURA", "focus")
    Timed.Emit("UNIT_AURA", "player")
    local stats = handle:GetStats()
    assert.are.equal(2, stats.keys)
    assert.are.equal(1, stats.refused)

    fireLatest()
    assert.are.same({ player = true, target = true }, delivered)
  end)

  it("defaults maxKeys to 256", function()
    local handle = EventKit:Coalesce("UNIT_AURA", 1, function() end)
    for index = 1, 257 do
      Timed.Emit("UNIT_AURA", "unit" .. index)
    end
    assert.are.equal(256, handle:GetStats().keys)
    assert.are.equal(1, handle:GetStats().refused)
  end)

  it("hands the callback one of two reused sets and empties it afterwards", function()
    local sets = {}
    EventKit:Coalesce("UNIT_HEALTH", 1, function(set)
      sets[#sets + 1] = set
    end)
    for _ = 1, 3 do
      Timed.Emit("UNIT_HEALTH", "player")
      fireLatest()
    end
    assert.are_not.equal(sets[1], sets[2])
    assert.are.equal(sets[1], sets[3])
    assert.is_nil(next(sets[1]))
    assert.is_nil(next(sets[2]))
  end)

  it("collects keys recorded during the callback into the next interval", function()
    local deliveries = {}
    EventKit:Coalesce("UNIT_HEALTH", 1, function(set)
      deliveries[#deliveries + 1] = copy(set)
      if #deliveries == 1 then
        Timed.Emit("UNIT_HEALTH", "target")
      end
    end)

    Timed.Emit("UNIT_HEALTH", "player")
    fireLatest()
    assert.are.same({ { player = true } }, deliveries)
    assert.are.equal(2, #Timed.NativeTimers())
    fireLatest()
    assert.are.same({ target = true }, deliveries[2])
  end)

  it("takes an interval of zero as the next frame", function()
    EventKit:Coalesce("UNIT_HEALTH", 0, function() end)
    Timed.Emit("UNIT_HEALTH", "player")
    assert.are.equal(0, Timed.NativeTimers()[1].seconds)
  end)

  it("keeps the key when TimerKit cannot arm, and arms again at the next event", function()
    local delivered = nil
    local handle = EventKit:Coalesce("UNIT_HEALTH", 1, function(set)
      delivered = copy(set)
    end)
    Timed.TakeReportedErrors()
    Timed.FailNextTimerCreate("no timer")
    Timed.Emit("UNIT_HEALTH", "player")
    -- The event path reports the refusal through listener isolation.
    local reported = Timed.TakeReportedErrors()
    assert.are.equal(1, #reported)
    assert.is_not_nil(string.find(tostring(reported[1].value), "no timer", 1, true))
    assert.is_true(handle:IsPending())

    Timed.Emit("UNIT_HEALTH", "target")
    fireLatest()
    assert.are.same({ player = true, target = true }, delivered)
  end)

  it("returns false from Flush inside its own callback", function()
    local inside = nil
    local handle
    handle = EventKit:Coalesce("UNIT_HEALTH", 1, function()
      inside = { handle:Flush() }
    end)
    Timed.Emit("UNIT_HEALTH", "player")
    assert.is_true((handle:Flush()))
    assert.are.same({ false }, inside)
    assert.is_false((handle:Flush()))
  end)

  it("flushes early, cancelling the interval's timer", function()
    local deliveries = 0
    local handle = EventKit:Coalesce("UNIT_HEALTH", 1, function()
      deliveries = deliveries + 1
    end)
    Timed.Emit("UNIT_HEALTH", "player")
    assert.is_true((handle:Flush()))
    assert.is_true(Timed.NativeTimers()[1].cancelled)
    assert.are.equal(1, deliveries)
  end)

  it("reports the counters in one reused table", function()
    local handle = EventKit:Coalesce("UNIT_HEALTH", 1, function() end)
    local first = handle:GetStats()
    Timed.Emit("UNIT_HEALTH", "player")
    fireLatest()
    local second = handle:GetStats()
    assert.are.equal(first, second)
    assert.are.same({ keys = 0, refused = 0, delivered = 1, deferred = 0, dropped = 0 }, second)
  end)

  it("reports a raising callback and delivers the next interval", function()
    local calls = 0
    EventKit:Coalesce("UNIT_HEALTH", 1, function()
      calls = calls + 1
      error("callback failed", 0)
    end)
    Timed.TakeReportedErrors()
    Timed.Emit("UNIT_HEALTH", "player")
    fireLatest()
    Timed.Emit("UNIT_HEALTH", "player")
    fireLatest()
    assert.are.equal(2, calls)
    local reported = Timed.TakeReportedErrors()
    assert.are.equal(2, #reported)
    assert.is_not_nil(string.find(tostring(reported[1].value), "callback failed", 1, true))
  end)

  it("keeps the maxKeys refusal SchedulerKit gave, at the caller's line", function()
    expectErrorAtThisSpec(
      "EventKit:Coalesce: SchedulerKit.Scope:Coalesce maxKeys must be a finite positive integer",
      function()
        EventKit:Coalesce("UNIT_HEALTH", 1, function() end, { maxKeys = 1.5 })
      end
    )
    local secret = Timed.NewSecretValue()
    -- selene: allow(global_usage)
    rawset(_G, "issecretvalue", function(value)
      return rawequal(value, secret)
    end)
    expectErrorAtThisSpec(
      "EventKit:Coalesce: SchedulerKit.Scope:Coalesce maxKeys must not be a secret value",
      function()
        EventKit:Coalesce("UNIT_HEALTH", 1, function() end, { maxKeys = secret })
      end
    )
    -- selene: allow(global_usage)
    rawset(_G, "issecretvalue", nil)
  end)

  it("ignores a stale timer whose handle moved on", function()
    local deliveries = 0
    local handle = EventKit:Coalesce("UNIT_HEALTH", 1, function()
      deliveries = deliveries + 1
    end)
    Timed.Emit("UNIT_HEALTH", "player")
    handle:Flush()
    -- The cancelled native timer is invoked anyway, as a stale host callback.
    Timed.InvokeRaw(1)
    assert.are.equal(1, deliveries)
  end)
end)

describe("EventKit Derive timed by TimerKit", function()
  local EventKit
  before_each(function()
    EventKit = Timed.NewEventKit()
  end)
  after_each(Timed.Reset)

  it("recomputes after the quiet period, re-arming once for a call during it", function()
    local source, computes = 1, 0
    local derived = EventKit:Derive("CUSTOM_EVENT", function()
      computes = computes + 1
      return source
    end, { delaySeconds = 1 })
    assert.are.equal(1, computes)

    source = 2
    Timed.Emit("CUSTOM_EVENT")
    assert.are.equal(1, #Timed.NativeTimers())
    assert.are.equal(1, Timed.NativeTimers()[1].seconds)
    Timed.AdvanceMs(600)
    Timed.Emit("CUSTOM_EVENT")
    -- No second timer while the window is open.
    assert.are.equal(1, #Timed.NativeTimers())

    Timed.AdvanceMs(400)
    fireLatest()
    -- Only 0.4 s were quiet: re-armed for the remaining 0.6 s.
    assert.are.equal(1, computes)
    assert.are.equal(2, #Timed.NativeTimers())
    assert.is_true(math.abs(Timed.NativeTimers()[2].seconds - 0.6) < 1e-9)

    Timed.AdvanceMs(600)
    fireLatest()
    assert.are.equal(2, computes)
    assert.are.equal(2, derived:Get())
  end)

  it("defaults to the next frame", function()
    EventKit:Derive("CUSTOM_EVENT", function() end)
    Timed.Emit("CUSTOM_EVENT")
    assert.are.equal(0, Timed.NativeTimers()[1].seconds)
  end)

  it("recomputes on wake without a clock", function()
    local computes = 0
    EventKit:Derive("CUSTOM_EVENT", function()
      computes = computes + 1
    end, { delaySeconds = 1 })
    -- selene: allow(global_usage)
    rawset(_G, "GetTimePreciseSec", nil)
    Timed.Emit("CUSTOM_EVENT")
    fireLatest()
    assert.are.equal(2, computes)
  end)

  it(
    "raises a timer TimerKit cannot arm to Invalidate's caller and keeps nothing pending",
    function()
      local computes = 0
      local derived = EventKit:Derive("CUSTOM_EVENT", function()
        computes = computes + 1
      end, { delaySeconds = 1 })
      Timed.FailNextTimerCreate("no timer")
      local ok, message = pcall(derived.Invalidate, derived)
      assert.is_false(ok)
      assert.is_not_nil(string.find(tostring(message), "no timer", 1, true))
      assert.is_false(rawget(derived, "_lastCall"))
      assert.is_false(rawget(derived, "_timer"))

      derived:Invalidate()
      Timed.AdvanceMs(1000)
      fireLatest()
      assert.are.equal(2, computes)
    end
  )

  it("cancels a pending recompute when closed", function()
    local computes = 0
    local derived = EventKit:Derive("CUSTOM_EVENT", function()
      computes = computes + 1
    end, { delaySeconds = 1 })
    Timed.Emit("CUSTOM_EVENT")
    assert.is_true(derived:Close())
    assert.is_true(Timed.NativeTimers()[1].cancelled)
    assert.is_false(fireLatest())
    assert.are.equal(1, computes)
  end)
end)

describe("EventKit Coalesce with a lane", function()
  local EventKit, SchedulerKit
  before_each(function()
    EventKit, SchedulerKit = Scheduled.NewEventKit()
  end)
  after_each(Scheduled.Reset)

  it("is timed by SchedulerKit's Coalesce in the shared scope", function()
    local delivered = nil
    local lane = SchedulerKit:Lane("EventKitTimingSpec")
    local handle = EventKit:Coalesce("UNIT_HEALTH", 0.5, function(set)
      delivered = copy(set)
    end, { lane = lane })
    local timing = rawget(handle, "_timing")
    assert.are.equal("table", type(timing))
    assert.are.equal(rawget(EventKit._state, "coalesceSchedulerScope"), rawget(timing, "_scope"))

    Scheduled.Emit("UNIT_HEALTH", "player")
    assert.is_true(handle:IsPending())
    assert.are.equal(1, handle:GetStats().keys)
    for index = 1, #Scheduled.NativeTimers() do
      Scheduled.FireNative(index)
    end
    Scheduled.Tick(0.016)
    assert.are.same({ player = true }, delivered)
    assert.is_false((handle:Flush()))
    assert.is_true(handle:Close())
  end)

  it("refuses a lane without SchedulerKit's Coalescing or Lanes part, naming the file", function()
    rawset(SchedulerKit, "HasPart", function(_, name)
      return name ~= "Lanes"
    end)
    expectErrorAtThisSpec(
      "EventKit:Coalesce with a lane needs SchedulerKit's Lanes part, which is not loaded: add "
        .. "schedulerKit\\parts\\SchedulerKit-Lanes.lua to embeds.xml after schedulerKit\\SchedulerKit.lua",
      function()
        EventKit:Coalesce("UNIT_HEALTH", 0.5, function() end, { lane = {} })
      end
    )
    rawset(SchedulerKit, "HasPart", function(_, name)
      return name ~= "Coalescing"
    end)
    expectErrorAtThisSpec("needs SchedulerKit's Coalescing part", function()
      EventKit:CreateScope():Coalesce("UNIT_HEALTH", 0.5, function() end, { lane = {} })
    end)
    rawset(SchedulerKit, "HasPart", nil)
  end)

  it("raises SchedulerKit's lane refusal at the caller without its position", function()
    expectErrorAtThisSpec("EventKit:Coalesce: SchedulerKit.Scope:Coalesce lane", function()
      EventKit:Coalesce("UNIT_HEALTH", 0.5, function() end, { lane = {} })
    end)
  end)
end)
