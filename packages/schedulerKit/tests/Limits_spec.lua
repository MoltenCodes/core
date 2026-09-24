local TestEnv = require("SchedulerKitTestEnv")

-- Design principle 4a: every retained collection SchedulerKit keeps across
-- addons is bounded by default and opened through `SetLimits`, with
-- `SchedulerKit.UNBOUNDED` where the retention is the consumer's own.

---Fire the most recently created native timer.
local function fireLatest()
  return TestEnv.FireNative(#TestEnv.NativeTimers())
end

local DEFAULTS = {
  maxLanes = 32,
  maxWatchIntervals = 32,
  maxWatchersPerInterval = 128,
  maxDebounceArguments = 8,
}

describe("SchedulerKit limits", function()
  local SchedulerKit
  before_each(function()
    SchedulerKit = TestEnv.NewPackage()
  end)
  after_each(TestEnv.Reset)

  it("reports the defaults as a fresh table on every call", function()
    local limits = SchedulerKit:GetLimits()
    assert.are.same(DEFAULTS, limits)
    limits.maxLanes = 1
    assert.are.equal(32, SchedulerKit:GetLimits().maxLanes)
    assert.are.equal("table", type(SchedulerKit.UNBOUNDED))
  end)

  it("opens the 33rd lane when maxLanes is raised", function()
    SchedulerKit:SetLimits({ maxLanes = 33 })
    for index = 1, 33 do
      SchedulerKit:Lane("lane" .. index)
    end
    TestEnv.expectErrorContaining("refuses to create more than 33 open lanes", function()
      SchedulerKit:Lane("lane34")
    end)
  end)

  it("lifts maxLanes with UNBOUNDED", function()
    SchedulerKit:SetLimits({ maxLanes = SchedulerKit.UNBOUNDED })
    for index = 1, 100 do
      SchedulerKit:Lane("lane" .. index)
    end
    assert.are.equal(SchedulerKit.UNBOUNDED, SchedulerKit:GetLimits().maxLanes)
  end)

  it("raises maxWatchIntervals up to its ceiling and refuses UNBOUNDED", function()
    SchedulerKit:SetLimits({ maxWatchIntervals = 33 })
    for index = 1, 33 do
      SchedulerKit:Watch(function() end, index, function() end)
    end
    TestEnv.expectErrorContaining("refuses more than 33 distinct watch intervals", function()
      SchedulerKit:Watch(function() end, 34, function() end)
    end)

    SchedulerKit:SetLimits({ maxWatchIntervals = 256 })
    TestEnv.expectErrorContaining(
      "limits.maxWatchIntervals must be an integer from 1 to 256",
      function()
        SchedulerKit:SetLimits({ maxWatchIntervals = 257 })
      end
    )
    TestEnv.expectErrorContaining(
      "limits.maxWatchIntervals cannot be SchedulerKit.UNBOUNDED: each interval is one TimerKit ticker",
      function()
        SchedulerKit:SetLimits({ maxWatchIntervals = SchedulerKit.UNBOUNDED })
      end
    )
  end)

  it("lifts maxWatchersPerInterval with UNBOUNDED", function()
    SchedulerKit:SetLimits({ maxWatchersPerInterval = SchedulerKit.UNBOUNDED })
    for _ = 1, 200 do
      SchedulerKit:Watch(function() end, 1, function() end)
    end
    SchedulerKit:SetLimits({ maxWatchersPerInterval = 200 })
    TestEnv.expectErrorContaining("refuses more than 200 watchers on one interval", function()
      SchedulerKit:Watch(function() end, 1, function() end)
    end)
  end)

  it("opens the ninth debounce argument and delivers every value", function()
    SchedulerKit:SetLimits({ maxDebounceArguments = 12 })
    local received, receivedCount
    local debounced = SchedulerKit:Debounce(function(...)
      receivedCount = select("#", ...)
      received = { ... }
    end, 0)

    debounced(1, 2, 3, 4, 5, 6, 7, 8, 9, nil, 11)
    fireLatest()

    assert.are.equal(11, receivedCount)
    assert.are.equal(9, received[9])
    assert.is_nil(received[10])
    assert.are.equal(11, received[11])

    -- A narrower call afterwards leaves nothing of the wide one behind.
    debounced("a")
    fireLatest()
    assert.are.equal(1, receivedCount)
    assert.are.same({ "a" }, received)

    TestEnv.expectErrorContaining("accepts at most 12 arguments; received 13", function()
      debounced(1, 2, 3, 4, 5, 6, 7, 8, 9, 10, 11, 12, 13)
    end)
  end)

  it("delivers wide debounce calls through a lane", function()
    SchedulerKit:SetLimits({ maxDebounceArguments = 10 })
    local lane = SchedulerKit:Lane("wide")
    local received, receivedCount
    local debounced = SchedulerKit:Debounce(function(...)
      receivedCount = select("#", ...)
      received = { ... }
    end, 0, { lane = lane })

    debounced(1, 2, 3, 4, 5, 6, 7, 8, 9, 10)
    fireLatest()
    TestEnv.Tick()

    assert.are.equal(10, receivedCount)
    assert.are.equal(10, received[10])
  end)

  it("caps maxDebounceArguments at 64 and refuses UNBOUNDED", function()
    SchedulerKit:SetLimits({ maxDebounceArguments = 64 })
    TestEnv.expectErrorContaining(
      "limits.maxDebounceArguments must be an integer from 1 to 64",
      function()
        SchedulerKit:SetLimits({ maxDebounceArguments = 65 })
      end
    )
    TestEnv.expectErrorContaining(
      "limits.maxDebounceArguments cannot be SchedulerKit.UNBOUNDED: the argument slot is reused per handle",
      function()
        SchedulerKit:SetLimits({ maxDebounceArguments = SchedulerKit.UNBOUNDED })
      end
    )
  end)

  it("applies a SetLimits table atomically and refuses bad input", function()
    TestEnv.expectErrorContaining(
      "limits.maxDebounceArguments must be an integer from 1 to 64",
      function()
        SchedulerKit:SetLimits({ maxLanes = 40, maxDebounceArguments = 0 })
      end
    )
    assert.are.same(DEFAULTS, SchedulerKit:GetLimits())

    TestEnv.expectErrorContaining("SchedulerKit:SetLimits limits must be a table", function()
      SchedulerKit:SetLimits(3)
    end)
    TestEnv.expectErrorContaining("limits.maxJobs is not a recognised limit", function()
      SchedulerKit:SetLimits({ maxJobs = 3 })
    end)
    for _, invalid in ipairs({ 0, -1, 1.5, "8", math.huge, 0 / 0, {} }) do
      TestEnv.expectErrorContaining(
        "limits.maxLanes must be a positive integer or SchedulerKit.UNBOUNDED",
        function()
          SchedulerKit:SetLimits({ maxLanes = invalid })
        end
      )
    end
  end)

  it("reports SetLimits errors at the caller's line and checks the receiver", function()
    local source = debug.getinfo(1, "S").short_src
    local line
    local ok, message = pcall(function()
      line = debug.getinfo(1, "l").currentline + 1
      SchedulerKit:SetLimits({ maxLanes = 0 })
    end)
    assert.is_false(ok)
    assert.are.equal(
      source
        .. ":"
        .. line
        .. ": SchedulerKit:SetLimits limits.maxLanes must be a positive integer"
        .. " or SchedulerKit.UNBOUNDED",
      message
    )
    TestEnv.expectErrorContaining("must be called on the SchedulerKit facade", function()
      SchedulerKit.SetLimits({}, {})
    end)
    TestEnv.expectErrorContaining("must be called on the SchedulerKit facade", function()
      SchedulerKit.GetLimits({})
    end)
  end)

  it("keeps limits and the sentinel across a reload", function()
    local sentinel = SchedulerKit.UNBOUNDED
    SchedulerKit:SetLimits({ maxLanes = 40 })

    local reloaded = TestEnv.ReloadPackage()
    assert.are.equal(sentinel, reloaded.UNBOUNDED)
    assert.are.equal(40, reloaded:GetLimits().maxLanes)
  end)
end)
