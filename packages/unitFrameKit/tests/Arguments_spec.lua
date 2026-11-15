local TestEnv = require("UnitFrameKitTestEnv")

local SOURCE = debug.getinfo(1, "S").short_src

---Run every `{ action, message }` case and check the failure is reported at
---the line after the function's `function()` line, where its statement sits.
---@param cases { [1]: fun(), [2]: string }[]
local function checkCases(cases)
  for _, case in ipairs(cases) do
    local action = case[1]
    local line = debug.getinfo(action, "S").linedefined + 1
    local ok, value = pcall(action)
    assert.is_false(ok)
    assert.are.equal(SOURCE .. ":" .. line .. ": " .. case[2], value)
  end
end

---An array of `count` copies of `value`.
---@param count integer
---@param value any
---@return any[]
local function filled(count, value)
  local list = {}
  for index = 1, count do
    list[index] = value
  end
  return list
end

local KINDS = "raid, party, boss, player, target, targettarget, focus"

describe("UnitFrameKit arguments", function()
  local UnitFrameKit
  before_each(function()
    UnitFrameKit = TestEnv.NewPackage()
  end)
  after_each(TestEnv.Reset)

  it("points every query argument error at the caller", function()
    checkCases({
      {
        function()
          UnitFrameKit:GetUnitFrame("")
        end,
        "UnitFrameKit:GetUnitFrame unit must be a non-empty unit token",
      },
      {
        function()
          UnitFrameKit:GetUnitFrames(1)
        end,
        "UnitFrameKit:GetUnitFrames unit must be a non-empty unit token",
      },
      {
        function()
          UnitFrameKit:GetUnitFrame("party1", "raid")
        end,
        "UnitFrameKit:GetUnitFrame options must be a table or nil",
      },
      {
        function()
          UnitFrameKit:GetUnitFrame("party1", { returnAll = true })
        end,
        "UnitFrameKit:GetUnitFrame options holds an unknown field; it accepts kinds, priorities, ignore",
      },
      {
        function()
          UnitFrameKit:GetUnitFrame("party1", { kinds = "raid" })
        end,
        "UnitFrameKit:GetUnitFrame options.kinds must be an array of kinds",
      },
      {
        function()
          UnitFrameKit:GetUnitFrame("party1", { kinds = { "arena" } })
        end,
        "UnitFrameKit:GetUnitFrame options.kinds[1] is not a kind; kinds are " .. KINDS,
      },
      {
        function()
          UnitFrameKit:GetUnitFrames("party1", { priorities = { "^Elv", "" } })
        end,
        "UnitFrameKit:GetUnitFrames options.priorities[2] must be a non-empty string",
      },
      {
        function()
          UnitFrameKit:GetUnitFrames("party1", { priorities = { "[unclosed" } })
        end,
        "UnitFrameKit:GetUnitFrames options.priorities[1] is not a valid pattern",
      },
      {
        function()
          UnitFrameKit:GetUnitFrame("party1", { ignore = { first = "^Elv" } })
        end,
        "UnitFrameKit:GetUnitFrame options.ignore must be an array of patterns",
      },
      {
        function()
          UnitFrameKit:GetUnitFrame("party1", { ignore = filled(65, "^Elv") })
        end,
        "UnitFrameKit:GetUnitFrame options.ignore holds at most 64 patterns",
      },
      {
        function()
          UnitFrameKit:GetNamePlate(nil)
        end,
        "UnitFrameKit:GetNamePlate unit must be a non-empty unit token",
      },
    })
  end)

  it("points every other argument error at the caller", function()
    checkCases({
      {
        function()
          UnitFrameKit:OnChange("callback")
        end,
        "UnitFrameKit:OnChange callback must be a function",
      },
      {
        function()
          UnitFrameKit:GetKindPatterns("arena")
        end,
        "UnitFrameKit:GetKindPatterns kind must be one of " .. KINDS,
      },
      {
        function()
          UnitFrameKit:SetLimits(5)
        end,
        "UnitFrameKit:SetLimits limits must be a table",
      },
      {
        function()
          UnitFrameKit:SetLimits({ maxGlows = 5 })
        end,
        "UnitFrameKit:SetLimits limits holds an unknown field; it accepts maxFrames, scanFramesPerStep, maxListeners",
      },
      {
        function()
          UnitFrameKit:SetLimits({ maxFrames = 4097 })
        end,
        "UnitFrameKit:SetLimits limits.maxFrames must be an integer from 1 to 4096",
      },
      {
        function()
          UnitFrameKit:SetLimits({ scanFramesPerStep = 0 })
        end,
        "UnitFrameKit:SetLimits limits.scanFramesPerStep must be an integer from 1 to 4000",
      },
      {
        function()
          UnitFrameKit:SetLimits({ maxListeners = 1.5 })
        end,
        "UnitFrameKit:SetLimits limits.maxListeners must be an integer from 1 to 512",
      },
    })
  end)

  it("refuses every method called on anything but the facade", function()
    for _, method in ipairs({
      "GetUnitFrame",
      "GetUnitFrames",
      "GetNamePlate",
      "Rescan",
      "IsScanning",
      "OnChange",
      "GetKindPatterns",
      "SetLimits",
      "GetLimits",
    }) do
      local ok, value = pcall(UnitFrameKit[method], {})
      assert.is_false(ok)
      assert.is_truthy(
        tostring(value):find(
          "UnitFrameKit:"
            .. method
            .. " must be called on the UnitFrameKit facade; use UnitFrameKit:"
            .. method
            .. "(...)",
          1,
          true
        )
      )
    end
    checkCases({
      {
        function()
          UnitFrameKit.GetUnitFrame(nil, "party1")
        end,
        "UnitFrameKit:GetUnitFrame must be called on the UnitFrameKit facade; use UnitFrameKit:GetUnitFrame(...)",
      },
    })
  end)

  it("refuses connection methods called on anything but a connection", function()
    local connection = UnitFrameKit:OnChange(function() end)
    checkCases({
      {
        function()
          connection.Disconnect({})
        end,
        "UnitFrameKit.Connection:Disconnect must be called on a UnitFrameKit connection; use connection:Disconnect(...)",
      },
      {
        function()
          connection.IsConnected(nil)
        end,
        "UnitFrameKit.Connection:IsConnected must be called on a UnitFrameKit connection; use connection:IsConnected(...)",
      },
    })
  end)

  it("accepts every option at its largest", function()
    local options = {
      kinds = { "raid", "party", "boss", "player", "target", "targettarget", "focus" },
      priorities = filled(64, "^Mine"),
      ignore = filled(64, "^Theirs"),
    }
    assert.is_nil(UnitFrameKit:GetUnitFrame("party1", options))
    assert.are.same({}, UnitFrameKit:GetUnitFrames("party1", options))
  end)
end)
