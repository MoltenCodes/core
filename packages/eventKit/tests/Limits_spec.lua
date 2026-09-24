local TestEnv = require("EventKitTestEnv")

local SPEC_FILE = "packages/eventKit/tests/Limits_spec.lua:"

---Assert `callback` raises `expected`, reported at a line of this spec file.
---@param expected string
---@param callback function
local function expectCallerError(expected, callback)
  local ok, message = pcall(callback)
  message = tostring(message)
  assert.is_false(ok)
  assert.is_not_nil(string.find(message, expected, 1, true))
  assert.is_not_nil(string.find(message, SPEC_FILE, 1, true))
  assert.is_nil(string.find(message, "src/EventKit.lua", 1, true))
end

---Subscribe to `count` distinct unit sets, one Frame each.
---@param EventKit table
---@param first integer
---@param last integer
---@return table[] connections
local function connectDistinctUnits(EventKit, first, last)
  local connections = {}
  for index = first, last do
    connections[#connections + 1] = EventKit:ConnectUnit(
      "UNIT_HEALTH",
      function() end,
      "raid" .. index
    )
  end
  return connections
end

describe("EventKit limits", function()
  local EventKit
  before_each(function()
    EventKit = TestEnv.NewPackage()
  end)
  after_each(TestEnv.Reset)

  it("exposes one sentinel table kept in package state", function()
    assert.are.equal("table", type(EventKit.UNBOUNDED))
    assert.are.equal(EventKit._state.unbounded, EventKit.UNBOUNDED)
  end)

  it("reports the default maxUnitFrames", function()
    assert.are.same({ maxUnitFrames = 64 }, EventKit:GetLimits())
  end)

  it("returns a fresh table from every GetLimits call", function()
    local first = EventKit:GetLimits()
    local second = EventKit:GetLimits()
    assert.are_not.equal(first, second)

    first.maxUnitFrames = 1
    assert.are.equal(64, EventKit:GetLimits().maxUnitFrames)
  end)

  it("enforces the default of 64 unit-filter Frames", function()
    connectDistinctUnits(EventKit, 1, 64)
    local ok, message = pcall(function()
      EventKit:ConnectUnit("UNIT_HEALTH", function() end, "raid65")
    end)
    assert.is_false(ok)
    assert.is_not_nil(string.find(tostring(message), "refusing to create more than 64", 1, true))
    assert.is_not_nil(string.find(tostring(message), "SetLimits{ maxUnitFrames }", 1, true))
  end)

  it("honours a raised maxUnitFrames", function()
    EventKit:SetLimits({ maxUnitFrames = 100 })
    assert.are.equal(100, EventKit:GetLimits().maxUnitFrames)

    connectDistinctUnits(EventKit, 1, 100)
    assert.are.equal(100, #TestEnv.Frames())

    local ok, message = pcall(function()
      EventKit:ConnectUnit("UNIT_HEALTH", function() end, "raid101")
    end)
    assert.is_false(ok)
    assert.is_not_nil(string.find(tostring(message), "refusing to create more than 100", 1, true))
  end)

  it("accepts the ceiling of 512", function()
    EventKit:SetLimits({ maxUnitFrames = 512 })
    assert.are.equal(512, EventKit:GetLimits().maxUnitFrames)
  end)

  it("evicts nothing when lowered below the Frames already created", function()
    local connections = connectDistinctUnits(EventKit, 1, 4)
    EventKit:SetLimits({ maxUnitFrames = 2 })

    for index = 1, #connections do
      assert.is_true(connections[index]:IsConnected())
    end
    assert.are.equal(4, #TestEnv.Frames())

    -- Released Frames are still reused below the new limit.
    connections[1]:Disconnect()
    local reused = EventKit:ConnectUnit("UNIT_HEALTH", function() end, "raid5")
    assert.is_true(reused:IsConnected())
    assert.are.equal(4, #TestEnv.Frames())

    -- A new Frame is refused.
    local ok = pcall(function()
      EventKit:ConnectUnit("UNIT_HEALTH", function() end, "raid6")
    end)
    assert.is_false(ok)
  end)

  it("refuses UNBOUNDED for maxUnitFrames at the caller, with the reason", function()
    expectCallerError(
      "EventKit:SetLimits limits.maxUnitFrames cannot be EventKit.UNBOUNDED: "
        .. "the client never frees a Frame",
      function()
        EventKit:SetLimits({ maxUnitFrames = EventKit.UNBOUNDED })
      end
    )
    assert.are.equal(64, EventKit:GetLimits().maxUnitFrames)
  end)

  it("refuses invalid values at the caller", function()
    local invalid = { "64", true, {}, 0, -1, 1.5, 0 / 0, math.huge, -math.huge, 513 }
    for index = 1, #invalid do
      expectCallerError(
        "EventKit:SetLimits limits.maxUnitFrames must be an integer from 1 to 512",
        function()
          EventKit:SetLimits({ maxUnitFrames = invalid[index] })
        end
      )
    end
    assert.are.equal(64, EventKit:GetLimits().maxUnitFrames)
  end)

  it("refuses unknown limits and non-table arguments at the caller", function()
    expectCallerError("EventKit:SetLimits limits.maxFrames is not a recognised limit", function()
      EventKit:SetLimits({ maxFrames = 10 })
    end)
    expectCallerError("EventKit:SetLimits limits.1 is not a recognised limit", function()
      EventKit:SetLimits({ 10 })
    end)
    expectCallerError("EventKit:SetLimits limits must be a table", function()
      EventKit:SetLimits(10)
    end)
  end)

  it("changes nothing when any value is refused", function()
    EventKit:SetLimits({ maxUnitFrames = 80 })
    expectCallerError("is not a recognised limit", function()
      EventKit:SetLimits({ maxUnitFrames = 90, unknown = 1 })
    end)
    assert.are.equal(80, EventKit:GetLimits().maxUnitFrames)
  end)

  it("accepts an empty table as a no-op", function()
    EventKit:SetLimits({})
    assert.are.same({ maxUnitFrames = 64 }, EventKit:GetLimits())
  end)

  it("refuses SetLimits and GetLimits without the facade receiver", function()
    expectCallerError("EventKit:SetLimits must be called on the EventKit facade", function()
      EventKit.SetLimits({ maxUnitFrames = 10 })
    end)
    expectCallerError("EventKit:GetLimits must be called on the EventKit facade", function()
      EventKit.GetLimits()
    end)
  end)
end)
