local TestEnv = require("BindingKitTestEnv")

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

describe("BindingKit arguments and secrets", function()
  local BindingKit, scope
  before_each(function()
    BindingKit = TestEnv.NewPackage()
    scope = BindingKit:CreateScope("MyAddon")
  end)
  after_each(TestEnv.Reset)

  it("points every argument error at the caller", function()
    checkCases({
      {
        function()
          BindingKit:CreateScope("")
        end,
        "BindingKit:CreateScope name must be a non-empty string",
      },
      {
        function()
          BindingKit:CreateScope("Other", true)
        end,
        "BindingKit:CreateScope options must be a table or nil",
      },
      {
        function()
          BindingKit:CreateScope("Other", { override = true })
        end,
        "BindingKit:CreateScope options holds an unknown field; it accepts priority",
      },
      {
        function()
          BindingKit:CreateScope("Other", { priority = 1 })
        end,
        "BindingKit:CreateScope options.priority must be a boolean",
      },
      {
        function()
          BindingKit:GetScope(1)
        end,
        "BindingKit:GetScope name must be a non-empty string",
      },
      {
        function()
          scope:BindCommand("", "A")
        end,
        "BindingKit.Scope:BindCommand key must be a non-empty string",
      },
      {
        function()
          scope:BindCommand("F1", nil)
        end,
        "BindingKit.Scope:BindCommand command must be a non-empty string",
      },
      {
        function()
          scope:BindClick("F1", "")
        end,
        "BindingKit.Scope:BindClick buttonName must be a non-empty string",
      },
      {
        function()
          scope:BindClick("F1", "Button", 2)
        end,
        "BindingKit.Scope:BindClick mouseButton must be a non-empty string",
      },
      {
        function()
          scope:BindFunction("F1", "Toggle")
        end,
        "BindingKit.Scope:BindFunction func must be a function",
      },
      {
        function()
          scope:Unbind(nil)
        end,
        "BindingKit.Scope:Unbind key must be a non-empty string",
      },
      {
        function()
          scope:GetBinding(false)
        end,
        "BindingKit.Scope:GetBinding key must be a non-empty string",
      },
      {
        function()
          scope.ClearAll({})
        end,
        "BindingKit.Scope:ClearAll must be called on a BindingKit scope; use scope:ClearAll(...)",
      },
      {
        function()
          BindingKit.CreateScope(nil, "x")
        end,
        "BindingKit:CreateScope must be called on the BindingKit facade; use BindingKit:CreateScope(...)",
      },
      {
        function()
          BindingKit:SetLimits({ maxScopes = 257 })
        end,
        "BindingKit:SetLimits limits.maxScopes must be an integer from 1 to 256",
      },
      {
        function()
          BindingKit:SetLimits({ maxKeys = 1 })
        end,
        "BindingKit:SetLimits limits holds an unknown field; it accepts maxScopes and maxFunctionKeys",
      },
      {
        function()
          BindingKit:SetLimits(1)
        end,
        "BindingKit:SetLimits limits must be a table",
      },
    })
  end)

  it("refuses secret names, keys, targets, options, limits and receivers", function()
    TestEnv.InstallSecretProbe()
    local secret = TestEnv.NewSecret()
    for _, case in ipairs({
      {
        "BindingKit:CreateScope name must not be a secret value",
        function()
          BindingKit:CreateScope(secret)
        end,
      },
      {
        "BindingKit:CreateScope options must be a table or nil",
        function()
          BindingKit:CreateScope("x", secret)
        end,
      },
      {
        "BindingKit.Scope:BindCommand key must not be a secret value",
        function()
          scope:BindCommand(secret, "A")
        end,
      },
      {
        "BindingKit.Scope:BindClick buttonName must not be a secret value",
        function()
          scope:BindClick("F1", secret)
        end,
      },
      {
        "BindingKit:SetLimits limits.maxScopes must not be a secret value",
        function()
          BindingKit:SetLimits({ maxScopes = secret })
        end,
      },
      {
        "must be called on a BindingKit scope",
        function()
          scope.GetName(secret)
        end,
      },
    }) do
      TestEnv.expectErrorContaining(case[1], case[2])
    end
  end)

  it("treats a missing or secret InCombatLockdown as out of combat", function()
    TestEnv.InstallSecretProbe()
    local secret = TestEnv.NewSecret()
    TestEnv.SetGlobal("InCombatLockdown", function()
      return secret
    end)
    scope:BindCommand("F1", "A")
    assert.is_false(scope:IsPending())
    TestEnv.SetGlobal("InCombatLockdown", nil)
    scope:BindCommand("F2", "B")
    assert.is_false(scope:IsPending())
  end)
end)
