local TestEnv = require("RangeKitTestEnv")

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

describe("RangeKit arguments", function()
  local RangeKit
  before_each(function()
    RangeKit = TestEnv.NewPackage()
  end)
  after_each(TestEnv.Reset)

  it("points every argument error at the caller", function()
    checkCases({
      {
        function()
          RangeKit:GetRange(1)
        end,
        "RangeKit:GetRange unit must be a unit token string",
      },
      {
        function()
          RangeKit:GetRange("")
        end,
        "RangeKit:GetRange unit must be a unit token string",
      },
      {
        function()
          RangeKit:IsInRange(nil, 30)
        end,
        "RangeKit:IsInRange unit must be a unit token string",
      },
      {
        function()
          RangeKit:IsInRange("target", "30")
        end,
        "RangeKit:IsInRange yards must be a finite number of at least 0",
      },
      {
        function()
          RangeKit:IsInRange("target", -1)
        end,
        "RangeKit:IsInRange yards must be a finite number of at least 0",
      },
      {
        function()
          RangeKit:IsInRange("target", math.huge)
        end,
        "RangeKit:IsInRange yards must be a finite number of at least 0",
      },
      {
        function()
          RangeKit:IsInRange("target", 0 / 0)
        end,
        "RangeKit:IsInRange yards must be a finite number of at least 0",
      },
      {
        function()
          RangeKit:DescribeCheckers("enemy")
        end,
        "RangeKit:DescribeCheckers kind must be harm, friend, resurrect, pet or interact",
      },
      {
        function()
          RangeKit:DescribeCheckers(nil)
        end,
        "RangeKit:DescribeCheckers kind must be harm, friend, resurrect, pet or interact",
      },
      {
        function()
          RangeKit:OnCheckersChanged("refresh")
        end,
        "RangeKit:OnCheckersChanged callback must be a function",
      },
      {
        function()
          RangeKit:SetLimits(1)
        end,
        "RangeKit:SetLimits limits must be a table",
      },
      {
        function()
          RangeKit:SetLimits({ listeners = 1 })
        end,
        "RangeKit:SetLimits limits holds an unknown field; it accepts maxListeners",
      },
      {
        function()
          RangeKit:SetLimits({ maxListeners = 257 })
        end,
        "RangeKit:SetLimits limits.maxListeners must be an integer from 1 to 256",
      },
      {
        function()
          RangeKit:SetLimits({ maxListeners = 1.5 })
        end,
        "RangeKit:SetLimits limits.maxListeners must be an integer from 1 to 256",
      },
    })
  end)

  it("points every receiver error at the caller", function()
    checkCases({
      {
        function()
          RangeKit.GetRange(nil, "target")
        end,
        "RangeKit:GetRange must be called on the RangeKit facade; use RangeKit:GetRange(...)",
      },
      {
        function()
          RangeKit.IsInRange({}, "target", 30)
        end,
        "RangeKit:IsInRange must be called on the RangeKit facade; use RangeKit:IsInRange(...)",
      },
      {
        function()
          RangeKit.DescribeCheckers("harm")
        end,
        "RangeKit:DescribeCheckers must be called on the RangeKit facade; use RangeKit:DescribeCheckers(...)",
      },
      {
        function()
          RangeKit.OnCheckersChanged(function() end)
        end,
        "RangeKit:OnCheckersChanged must be called on the RangeKit facade; use RangeKit:OnCheckersChanged(...)",
      },
      {
        function()
          RangeKit.SetLimits({})
        end,
        "RangeKit:SetLimits must be called on the RangeKit facade; use RangeKit:SetLimits(...)",
      },
      {
        function()
          RangeKit.GetLimits(nil)
        end,
        "RangeKit:GetLimits must be called on the RangeKit facade; use RangeKit:GetLimits(...)",
      },
    })
    local connection = RangeKit:OnCheckersChanged(function() end)
    checkCases({
      {
        function()
          connection.Disconnect({})
        end,
        "RangeKit.Connection:Disconnect must be called on a RangeKit connection; use connection:Disconnect(...)",
      },
      {
        function()
          connection.IsConnected(nil)
        end,
        "RangeKit.Connection:IsConnected must be called on a RangeKit connection; use connection:IsConnected(...)",
      },
    })
  end)
end)
