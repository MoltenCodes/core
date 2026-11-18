local TestEnv = require("SignalKitTestEnv")
local Scheduled = TestEnv.Scheduled

-- The Coalescing part: bucketed bus messages, AceBucket-3.0's
-- `RegisterBucketMessage` (docs/API.md, "Bucketed messages").

---Fire the most recently created native timer.
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
  assert.is_not_nil(string.find(message, "Coalescing_spec.lua:", 1, true), message)
end

describe("SignalKit bucketed messages", function()
  local SignalKit, bus

  before_each(function()
    SignalKit = Scheduled.NewSignalKit()
    bus = SignalKit:Bus("MyAddon", { openTopics = true })
  end)

  after_each(Scheduled.Reset)

  it("delivers a burst once per interval, keyed by the first argument", function()
    local deliveries = {}
    local handle = bus:Coalesce({ "BagChanged", "BankChanged" }, 0.5, function(set)
      deliveries[#deliveries + 1] = copy(set)
    end)

    bus:Publish("BagChanged", 1)
    bus:Publish("BankChanged", 7)
    bus:Publish("BagChanged", 1)
    assert.is_true(handle:IsPending())
    assert.are.same({}, deliveries)
    fireLatest()

    assert.are.same({ { [1] = true, [7] = true } }, deliveries)
    assert.is_false(handle:IsPending())
    assert.are.equal(1, handle:GetStats().delivered)
  end)

  it("keys a message without a first argument, or with byTopic, by its topic", function()
    local delivered
    bus:Coalesce("Refresh", 0, function(set)
      delivered = copy(set)
    end)
    local byTopic
    bus:Coalesce({ "Refresh", "Other" }, 0, function(set)
      byTopic = copy(set)
    end, { byTopic = true })

    bus:Publish("Refresh")
    bus:Publish("Other", "x")
    Scheduled.FireNative(1)
    Scheduled.FireNative(2)

    assert.are.same({ Refresh = true }, delivered)
    assert.are.same({ Refresh = true, Other = true }, byTopic)
  end)

  it("calls a receiver's method, checked when the handle is made", function()
    local receiver = { sets = {} }
    function receiver:OnBucket(set)
      self.sets[#self.sets + 1] = copy(set)
    end
    bus:Coalesce("Changed", 0, receiver, "OnBucket")

    bus:Publish("Changed", "a")
    fireLatest()

    assert.are.same({ { a = true } }, receiver.sets)
    expectErrorAtThisSpec('SignalKit.Bus:Coalesce receiver has no method "Missing"', function()
      bus:Coalesce("Changed", 0, receiver, "Missing")
    end)
  end)

  it("flushes on demand and stops for good when closed", function()
    local deliveries = 0
    local handle = bus:Coalesce("Changed", 5, function()
      deliveries = deliveries + 1
    end)

    assert.is_false(handle:Flush())
    bus:Publish("Changed", "a")
    assert.is_true(handle:Flush())
    assert.is_true(handle:Close())
    assert.is_false(handle:Close())
    assert.is_true(handle:IsClosed())
    bus:Publish("Changed", "b")

    assert.are.equal(1, deliveries)
    assert.is_false(handle:IsPending())
    assert.is_false(handle:Flush())
  end)

  it("stops a scope's handle when the scope closes, even with a burst pending", function()
    local scope = bus:CreateScope()
    local deliveries = 0
    local handle = scope:Coalesce("Changed", 0.5, function()
      deliveries = deliveries + 1
    end)
    bus:Publish("Changed", "a")

    scope:Close()
    fireLatest()

    assert.are.equal(0, deliveries)
    assert.is_true(handle:IsClosed())
    assert.is_true(scope:Reopen())
    bus:Publish("Changed", "b")
    assert.are.equal(0, deliveries)
    expectErrorAtThisSpec(
      "SignalKit.BusScope:Coalesce cannot subscribe in a closed scope",
      function()
        local closed = bus:CreateScope()
        closed:Close()
        closed:Coalesce("Changed", 0, function() end)
      end
    )
  end)

  it("reports a raising callback through the host error handler", function()
    Scheduled.InstallHostErrorHandler()
    bus:Coalesce("Changed", 0, function()
      error("bucket broke")
    end)

    bus:Publish("Changed", "a")
    fireLatest()

    local reported = Scheduled.ReportedErrors()
    assert.are.equal(1, #reported)
    assert.is_not_nil(tostring(reported[1]):find("bucket broke", 1, true))
  end)

  it("answers full and subscribes nothing when a topic is refused", function()
    local small = SignalKit:Bus("Small", { openTopics = true, maxListeners = 1 })
    small:Subscribe("Second", function() end)

    local handle, reason = small:Coalesce({ "First", "Second" }, 0, function() end)

    assert.is_nil(handle)
    assert.are.equal("full", reason)
    assert.is_true(small:Subscribe("First", function() end) ~= nil)
  end)

  it("checks its arguments at the caller", function()
    local noop = function() end
    expectErrorAtThisSpec("topics must be non-empty strings", function()
      bus:Coalesce({ "" }, 0, noop)
    end)
    expectErrorAtThisSpec("topics must be a topic or an array of topics", function()
      bus:Coalesce(7, 0, noop)
    end)
    expectErrorAtThisSpec("topics must name at least one topic", function()
      bus:Coalesce({}, 0, noop)
    end)
    local many = {}
    for index = 1, 33 do
      many[index] = "Topic" .. index
    end
    expectErrorAtThisSpec("topics must name at most 32 distinct topics", function()
      bus:Coalesce(many, 0, noop)
    end)
    expectErrorAtThisSpec("intervalSeconds must be a finite number of zero or more", function()
      bus:Coalesce("Changed", -1, noop)
    end)
    expectErrorAtThisSpec("callback must be a function, or a receiver table", function()
      bus:Coalesce("Changed", 0, "OnBucket")
    end)
    expectErrorAtThisSpec("methodName must be a non-empty string", function()
      bus:Coalesce("Changed", 0, {})
    end)
    expectErrorAtThisSpec('options contains unknown field "<table>"', function()
      bus:Coalesce("Changed", 0, noop, { [{}] = true })
    end)
    expectErrorAtThisSpec('options contains unknown field "speed"', function()
      bus:Coalesce("Changed", 0, noop, { speed = 1 })
    end)
    expectErrorAtThisSpec('options contains unknown field "1"', function()
      bus:Coalesce("Changed", 0, noop, { true })
    end)
    expectErrorAtThisSpec("must be called on a SignalKit bus scope", function()
      bus:CreateScope().Coalesce(bus, "Changed", 0, noop)
    end)
    expectErrorAtThisSpec("options.byTopic must be a boolean", function()
      bus:Coalesce("Changed", 0, noop, { byTopic = 1 })
    end)
    expectErrorAtThisSpec("options must be a table", function()
      bus:Coalesce("Changed", 0, noop, "fast")
    end)
    expectErrorAtThisSpec("SignalKit.Bus:Coalesce: ", function()
      bus:Coalesce("Changed", 0, noop, { maxKeys = 0 })
    end)
    expectErrorAtThisSpec("must be called on a SignalKit bus with a colon call", function()
      bus.Coalesce({}, "Changed", 0, noop)
    end)
    SignalKit:CloseAddonBus("MyAddon")
    expectErrorAtThisSpec('cannot subscribe on the closed bus "MyAddon"', function()
      bus:Coalesce("Changed", 0, noop)
    end)
  end)

  it("raises at the caller when SchedulerKit cannot be found", function()
    local Registry = require("Registry")
    local parts = rawget(rawget(SignalKit, "_state"), "parts")
    parts.Coalescing.schedulerKit = nil
    local find = rawget(Registry, "Find")
    rawset(Registry, "Find", function()
      return nil, "missing"
    end)

    local ok, message = pcall(function()
      bus:Coalesce("Changed", 0, function() end)
    end)
    rawset(Registry, "Find", find)

    assert.is_false(ok)
    assert.is_not_nil(tostring(message):find("needs SchedulerKit API 1 with Coalesce", 1, true))
  end)
end)

describe("SignalKit secret first arguments in a bucket", function()
  after_each(Scheduled.Reset)

  it("keys a secret first argument by its topic", function()
    Scheduled.Reset()
    Scheduled.SetWowProfile("mainline")
    Scheduled.InstallWowApi()
    require("Registry")
    local SignalKit = require("SignalKit")
    require("SignalKit-Bus")
    require("TimerKit")
    require("SchedulerKit")
    pcall(require, "SchedulerKit-Coalescing")
    require("SignalKit-Coalescing")
    local bus = SignalKit:Bus("MyAddon", { openTopics = true })
    local delivered
    bus:Coalesce("Changed", 0, function(set)
      delivered = copy(set)
    end)

    bus:Publish("Changed", Scheduled.NewSecretValue())
    fireLatest()

    assert.are.same({ Changed = true }, delivered)
    local secret = Scheduled.NewSecretValue()
    expectErrorAtThisSpec("topics must not be secret values", function()
      bus:Coalesce({ secret }, 0, function() end)
    end)
    expectErrorAtThisSpec("callback must not be a secret value", function()
      bus:Coalesce("Changed", 0, secret)
    end)
    expectErrorAtThisSpec("methodName must not be a secret value", function()
      bus:Coalesce("Changed", 0, {}, secret)
    end)
  end)
end)

describe("SignalKit without its Coalescing part", function()
  after_each(TestEnv.Reset)

  it("names the file to embed on a bus and on a scope", function()
    local SignalKit = TestEnv.NewPackage()
    local bus = SignalKit:Bus("MyAddon")

    expectErrorAtThisSpec(
      "SignalKit.Bus:Coalesce needs SignalKit's Coalescing part, which is not loaded:"
        .. " add signalKit\\parts\\SignalKit-Coalescing.lua to your embeds.xml",
      function()
        bus:Coalesce("Changed", 0, function() end)
      end
    )
    expectErrorAtThisSpec(
      "SignalKit.BusScope:Coalesce needs SignalKit's Coalescing part",
      function()
        bus:CreateScope():Coalesce("Changed", 0, function() end)
      end
    )
  end)

  it("refuses to load the part before its core", function()
    TestEnv.Reset()
    local ok, message = pcall(require, "SignalKit-Coalescing")
    package.loaded["SignalKit-Coalescing"] = nil

    assert.is_false(ok)
    assert.is_not_nil(
      tostring(message):find(
        "MoltenCodes SignalKit part Coalescing requires SignalKit API 1 to be loaded first",
        1,
        true
      )
    )
  end)
end)

describe("SignalKit Coalescing across revisions", function()
  after_each(Scheduled.Reset)

  it("keeps the part serving across a core upgrade", function()
    local SignalKit = Scheduled.NewSignalKit()
    local bus = SignalKit:Bus("MyAddon", { openTopics = true })
    local handle = bus:Coalesce("Changed", 0, function() end)
    local served = rawget(rawget(rawget(SignalKit, "_state"), "busPrototype"), "Coalesce")

    local upgraded = TestEnv.LoadRevision(SignalKit.REVISION + 1)

    assert.are.equal(SignalKit, upgraded)
    assert.are.equal(
      served,
      rawget(rawget(rawget(SignalKit, "_state"), "busPrototype"), "Coalesce")
    )
    assert.is_false(handle:IsClosed())
    bus:Publish("Changed", "a")
    assert.is_true(handle:IsPending())
  end)

  it("lets an equal part revision loaded again change nothing", function()
    local SignalKit = Scheduled.NewSignalKit()
    local served = rawget(rawget(rawget(SignalKit, "_state"), "busPrototype"), "Coalesce")
    package.loaded["SignalKit-Coalescing"] = nil

    assert.are.equal(SignalKit, require("SignalKit-Coalescing"))
    assert.are.equal(
      served,
      rawget(rawget(rawget(SignalKit, "_state"), "busPrototype"), "Coalesce")
    )
  end)

  it("adds the parts table over revision-11 state", function()
    local SignalKit = TestEnv.NewPackage()
    rawset(rawget(SignalKit, "_state"), "parts", nil)

    TestEnv.LoadRevision(SignalKit.REVISION + 1)

    assert.are.same({}, rawget(rawget(SignalKit, "_state"), "parts"))
  end)
end)
