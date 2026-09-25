--- Event bucketing: EventKit's `Coalesce` (on SchedulerKit) against AceBucket-3.0.
---
--- Both sides collect a burst of game events into one set keyed by the
--- event's first payload argument and deliver it once per interval, with
--- AceBucket's interval rule on both: the first event of a burst starts the
--- interval, the callback runs at its end with everything collected.
---
---   MoltenCodes  `EventKit:Coalesce(events, interval, callback)`, whose
---                timing half is a SchedulerKit `Coalesce` handle on a
---                TimerKit timer (every handle's in one EventKit-private
---                SchedulerKit scope since EventKit revision 18);
---                `handle:Close()`
---   Ace3         `object:RegisterBucketEvent(events, interval, callback)`
---                on AceEvent-3.0 and AceTimer-3.0; `UnregisterBucket`
---
--- Events are delivered by calling the `OnEvent` script of the frame each
--- library registered, as in the dispatch workloads, and time moves only on
--- the simulated clock the timer workload uses, so a delivery happens exactly
--- when a case advances it.
---
--- What differs is recorded as a check, not hidden in a ratio: AceBucket
--- counts how often each key arrived and keeps every distinct key, while
--- EventKit's set holds `true` per key and refuses new keys past 256 per
--- interval; and after a delivery AceBucket re-arms its timer once more and
--- goes idle only when that timer finds nothing, while the Kit is idle at once.
---
--- Left out: AceBucket's `RegisterBucketMessage`. Its counterpart is a
--- SchedulerKit `Coalesce` handle fed by a SignalKit bus listener, a pairing
--- the application writes itself rather than one call, so the event form is
--- the one compared.

local Buckets = {}

--- The two events every bucket listens to.
local EVENTS = { "UNIT_HEALTH", "UNIT_MAXHEALTH" }
local EVENT = EVENTS[1]

--- The bucket interval, in simulated seconds.
local INTERVAL = 0.2

--- The unit tokens a burst carries, one event each.
local UNITS = {
  "player",
  "target",
  "focus",
  "pet",
  "party1",
  "party2",
  "party3",
  "party4",
  "boss1",
  "boss2",
}
local UNIT_COUNT = #UNITS

--- Events per `record-event` batch.
local RECORD_ITERATIONS = 200000

--- Bursts per `burst` batch.
local BURST_ITERATIONS = 10000

--- Buckets created and removed per `register-remove` batch.
local CHURN_ITERATIONS = 5000

--- Distinct keys sent in one interval by the bound check.
local KEY_PROBE = 300

---@param host table
---@return table adapter, table[] libraries
local function kitAdapter(host)
  local loaded =
    host.RequireAll({ "Registry", "SignalKit", "EventKit", "TimerKit", "SchedulerKit" })
  local SignalKit, EventKit, TimerKit, SchedulerKit = loaded[2], loaded[3], loaded[4], loaded[5]
  local adapter = { side = "moltencodes" }

  function adapter.bucket(callback)
    return EventKit:Coalesce(EVENTS, INTERVAL, callback)
  end

  function adapter.remove(handle)
    handle:Close()
  end

  return adapter,
    {
      { name = "EventKit", revision = EventKit.REVISION },
      { name = "SchedulerKit", revision = SchedulerKit.REVISION },
      { name = "TimerKit", revision = TimerKit.REVISION },
      { name = "SignalKit", revision = SignalKit.REVISION },
    }
end

---@param host table
---@param directory string the Ace3 checkout
---@return table adapter, table[] libraries
local function aceAdapter(host, directory)
  host.LoadFiles(directory, {
    "LibStub/LibStub.lua",
    "CallbackHandler-1.0/CallbackHandler-1.0.lua",
    "AceEvent-3.0/AceEvent-3.0.lua",
    "AceTimer-3.0/AceTimer-3.0.lua",
    "AceBucket-3.0/AceBucket-3.0.lua",
  })
  local LibStub = host.Global("LibStub")
  local AceBucket, bucketMinor = LibStub:GetLibrary("AceBucket-3.0")
  local _, eventMinor = LibStub:GetLibrary("AceEvent-3.0")
  local _, timerMinor = LibStub:GetLibrary("AceTimer-3.0")
  local _, callbackMinor = LibStub:GetLibrary("CallbackHandler-1.0")
  local owner = AceBucket:Embed({})
  local adapter = { side = "ace3" }

  function adapter.bucket(callback)
    return owner:RegisterBucketEvent(EVENTS, INTERVAL, callback)
  end

  function adapter.remove(handle)
    owner:UnregisterBucket(handle)
  end

  return adapter,
    {
      { name = "AceBucket-3.0", minor = bucketMinor },
      { name = "AceEvent-3.0", minor = eventMinor },
      { name = "AceTimer-3.0", minor = timerMinor },
      { name = "CallbackHandler-1.0", minor = callbackMinor },
    }
end

---@param adapter table
---@param host table
---@return Bench.Case[]
local function cases(adapter, host)
  local timers = host.timers

  ---Let every owed delivery and re-armed timer run, outside any measurement.
  local function settle()
    for _ = 1, 3 do
      timers.Advance(INTERVAL)
    end
  end

  return {
    {
      name = "record-event",
      iterations = RECORD_ITERATIONS,
      operation = "one event into an open interval, its key already collected (10 units)",
      prepare = function()
        local delivered = 0
        adapter.bucket(function()
          delivered = delivered + 1
        end)
        local frame, onEvent = host.EventHandler(EVENT)
        return {
          run = function(iterations)
            local slot = 0
            for _ = 1, iterations do
              slot = slot + 1
              if slot > UNIT_COUNT then
                slot = 1
              end
              onEvent(frame, EVENT, UNITS[slot])
            end
          end,
          afterBatch = settle,
          metrics = function()
            return { deliveries = delivered }
          end,
        }
      end,
    },
    {
      name = "burst",
      iterations = BURST_ITERATIONS,
      operation = "a burst of 10 events for 10 units, then the interval ends and delivers it",
      prepare = function()
        local deliveries, keys = 0, 0
        adapter.bucket(function(set)
          deliveries = deliveries + 1
          for _ in pairs(set) do
            keys = keys + 1
          end
        end)
        local frame, onEvent = host.EventHandler(EVENT)
        local bursts = 0
        return {
          run = function(iterations)
            local advance = timers.Advance
            for _ = 1, iterations do
              for slot = 1, UNIT_COUNT do
                onEvent(frame, EVENT, UNITS[slot])
              end
              advance(INTERVAL)
            end
            bursts = bursts + iterations
          end,
          afterBatch = settle,
          metrics = function()
            settle()
            onEvent(frame, EVENT, "player")
            timers.Advance(INTERVAL)
            local pendingAfterDelivery = timers.PendingCount()
            timers.Advance(INTERVAL)
            return {
              deliveriesPerBurst = deliveries / bursts,
              keysPerDelivery = keys / deliveries,
              pendingHostTimersRightAfterDelivery = pendingAfterDelivery,
              pendingHostTimersOneQuietIntervalLater = timers.PendingCount(),
            }
          end,
        }
      end,
    },
    {
      name = "register-remove",
      iterations = CHURN_ITERATIONS,
      operation = "create a bucket over 2 events and remove it, beside another bucket",
      prepare = function()
        local function callback() end
        -- The other bucket keeps both events registered with the client, so
        -- the rows measure the libraries' bookkeeping, not frame registration.
        adapter.bucket(callback)
        return {
          run = function(iterations)
            local bucket, remove = adapter.bucket, adapter.remove
            for _ = 1, iterations do
              remove(bucket(callback))
            end
          end,
        }
      end,
    },
  }
end

---@param adapter table
---@param host table
---@return table[] checks
local function checks(adapter, host)
  local timers = host.timers
  local results = {}
  local isKit = adapter.side == "moltencodes"

  local deliveries, lastSet = 0, {}
  local handle = adapter.bucket(function(set)
    deliveries = deliveries + 1
    lastSet = {}
    for key, value in pairs(set) do
      lastSet[key] = value
    end
  end)
  local frame, onEvent = host.EventHandler(EVENT)

  local function settle()
    for _ = 1, 3 do
      timers.Advance(INTERVAL)
    end
  end

  onEvent(frame, EVENT, "player")
  onEvent(frame, "UNIT_MAXHEALTH", "target")
  onEvent(frame, EVENT, "player")
  onEvent(frame, EVENT, "player")
  timers.Advance(INTERVAL)
  local keyCount = 0
  for _ in pairs(lastSet) do
    keyCount = keyCount + 1
  end
  results[#results + 1] = {
    name = "one-delivery-per-interval",
    passed = deliveries == 1 and keyCount == 2 and lastSet.player ~= nil and lastSet.target ~= nil,
    detail = "deliveries: " .. deliveries .. ", keys: " .. keyCount,
    promised = true,
  }

  results[#results + 1] = {
    name = "counts-per-key",
    passed = lastSet.player == 3,
    detail = "value delivered for a key sent 3 times: " .. tostring(lastSet.player),
    promised = not isKit,
  }

  local pendingAfterDelivery = timers.PendingCount()
  timers.Advance(INTERVAL)
  local pendingLater = timers.PendingCount()
  results[#results + 1] = {
    name = "idle-after-delivery",
    passed = pendingAfterDelivery == 0,
    detail = "host timers pending right after the delivery: "
      .. pendingAfterDelivery
      .. ", one quiet interval later: "
      .. pendingLater,
    promised = isKit,
  }

  settle()
  deliveries = 0
  onEvent(frame, EVENT, "player")
  timers.Advance(INTERVAL / 2)
  onEvent(frame, EVENT, "target")
  timers.Advance(INTERVAL / 2)
  results[#results + 1] = {
    name = "first-event-starts-interval",
    passed = deliveries == 1,
    detail = "deliveries one interval after the first event, with a second event halfway: "
      .. deliveries,
    promised = true,
  }

  settle()
  onEvent(frame, EVENT)
  timers.Advance(INTERVAL)
  local nilKey = next(lastSet)
  results[#results + 1] = {
    name = "missing-payload-keyed",
    passed = nilKey ~= nil,
    detail = "an event without a payload was keyed as " .. tostring(nilKey),
    promised = true,
  }

  settle()
  for index = 1, KEY_PROBE do
    onEvent(frame, EVENT, "unit" .. index)
  end
  timers.Advance(INTERVAL)
  keyCount = 0
  for _ in pairs(lastSet) do
    keyCount = keyCount + 1
  end
  results[#results + 1] = {
    name = "keys-per-interval-bounded",
    passed = keyCount < KEY_PROBE,
    detail = "distinct keys sent in one interval: " .. KEY_PROBE .. ", delivered: " .. keyCount,
    promised = isKit,
  }

  settle()
  host.TakeReportedErrors()
  local failing = adapter.bucket(function()
    error("bucket callback failed", 0)
  end)
  deliveries = 0
  onEvent(frame, EVENT, "player")
  timers.Advance(INTERVAL)
  local reported = #host.TakeReportedErrors()
  settle()
  onEvent(frame, EVENT, "target")
  timers.Advance(INTERVAL)
  host.TakeReportedErrors()
  results[#results + 1] = {
    name = "error-isolated",
    passed = reported == 1 and deliveries == 2,
    detail = "errors reported: " .. reported .. ", other bucket's deliveries: " .. deliveries,
    promised = true,
  }
  adapter.remove(failing)

  settle()
  adapter.remove(handle)
  deliveries = 0
  onEvent(frame, EVENT, "player")
  timers.Advance(INTERVAL)
  results[#results + 1] = {
    name = "removed-bucket-silent",
    passed = deliveries == 0 and timers.PendingCount() == 0,
    detail = "deliveries after removal: "
      .. deliveries
      .. ", host timers pending: "
      .. timers.PendingCount(),
    promised = true,
  }
  return results
end

---Build the workload for one side.
---@param side string `"moltencodes"` or `"ace3"`
---@param host table
---@param settings table
---@return table suite `{ cases, checks, libraries }`
function Buckets.Build(side, host, settings)
  local adapter, libraries
  if side == "moltencodes" then
    adapter, libraries = kitAdapter(host)
  else
    adapter, libraries = aceAdapter(host, settings.ace3)
  end
  return {
    libraries = libraries,
    cases = cases(adapter, host),
    checks = function()
      return checks(adapter, host)
    end,
  }
end

return Buckets
