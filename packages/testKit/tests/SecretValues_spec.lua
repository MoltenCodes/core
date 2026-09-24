local TestEnv = require("TestKitTestEnv")

describe("TestKit and secret values", function()
  local TestKit
  local secret
  local secrets

  before_each(function()
    TestKit = TestEnv.NewReadyPackage("MyAddon")
    -- A local stand-in for the Retail client's `issecretvalue`: exactly the
    -- values in `secrets` are secret.
    secret = setmetatable({}, {
      __eq = function()
        error("a secret value was compared")
      end,
    })
    secrets = { [secret] = true }
    TestEnv.SetGlobal("issecretvalue", function(value)
      return secrets[value] == true
    end)
  end)
  after_each(TestEnv.Reset)

  ---@param body fun(ctx: table)
  ---@return table result
  local function run(body)
    return TestEnv.RunOne(TestKit, body)
  end

  it("refuses a secret suite phase and a secret limit before comparing them", function()
    TestEnv.expectErrorContaining("TestKit:Suite phase must not be a secret value", function()
      TestKit:Suite("SecretPhase", { phase = secret })
    end)
    TestEnv.expectErrorContaining(
      "TestKit:SetLimits limits.maxTests must not be a secret value",
      function()
        TestKit:SetLimits({ maxTests = secret })
      end
    )
    TestEnv.expectErrorContaining(
      "TestKit:SetLimits limits.maxEqualDepth must not be a secret value",
      function()
        TestKit:SetLimits({ maxEqualDepth = secret })
      end
    )
    assert.are.equal(256, TestKit:GetLimits().maxTests)
  end)

  it("never prints a secret in a matcher failure, and never lets negation pass it", function()
    local messages = {}
    local result = run(function(ctx)
      messages[1] = select(2, pcall(ctx.Expect(ctx, secret).ToBe, ctx:Expect(secret), 1))
      local negated = ctx:Expect(secret).Not
      messages[2] = select(2, pcall(negated.ToBe, negated, 1))
      local equal = ctx:Expect({ nested = { secret } })
      messages[3] = select(2, pcall(equal.ToEqual, equal, { nested = { 1 } }))
      local negatedEqual = ctx:Expect({ secret }).Not
      messages[4] = select(2, pcall(negatedEqual.ToEqual, negatedEqual, { 2 }))
    end)
    assert.are.equal("passed", result.status)
    for index = 1, 4 do
      assert.is_string(messages[index])
      assert.is_truthy(messages[index]:find("a secret value cannot be compared", 1, true))
    end
    assert.is_truthy(messages[1]:find("expected <secret value>", 1, true))
    assert.is_truthy(messages[3]:find("at .nested[1]", 1, true))
  end)

  it("refuses to test a secret boolean for truth", function()
    secrets[true] = true
    local result = run(function(ctx)
      ctx:Expect(true):ToBeTruthy()
    end)
    assert.are.equal("failed", result.status)
    assert.is_truthy(
      result.message:find("expected <secret value>: a secret boolean cannot be tested", 1, true)
    )
  end)

  it("fails WaitUntil at the caller's line when the predicate answers a secret boolean", function()
    secrets[true] = true
    local callLine = nil
    local returned = false
    local result = run(function(ctx)
      callLine = debug.getinfo(1, "l").currentline + 1
      ctx:WaitUntil(function()
        return true
      end, 1)
      returned = true
    end)
    assert.are.equal("failed", result.status)
    assert.is_false(returned)
    assert.is_truthy(
      result.message:find(
        "SecretValues_spec.lua:"
          .. callLine
          .. ": TestKit.Context:WaitUntil predicate returned a secret boolean,"
          .. " which cannot be tested",
        1,
        true
      )
    )
  end)

  it("fails WaitUntil when a later poll answers a secret boolean, before the timeout", function()
    local polls = 0
    local result = run(function(ctx)
      ctx:WaitUntil(function()
        polls = polls + 1
        if polls < 3 then
          return false
        end
        -- From the third poll on, `true` is the stand-in for a secret boolean.
        secrets[true] = true
        return true
      end, 5)
    end)
    assert.are.equal(3, polls)
    assert.are.equal("failed", result.status)
    assert.is_truthy(result.message:find("WaitUntil predicate returned a secret boolean", 1, true))
  end)

  it("treats a secret WaitUntil answer of another type as truthy", function()
    local outcome = nil
    local result = run(function(ctx)
      outcome = { ctx:WaitUntil(function()
        return secret
      end, 1) }
    end)
    assert.are.equal("passed", result.status)
    assert.are.same({ true }, outcome)
  end)

  it("treats a secret of another type as truthy, and a secret is never nil", function()
    local result = run(function(ctx)
      ctx:Expect(secret):ToBeTruthy()
      ctx:Expect(secret).Not:ToBeNil()
    end)
    assert.are.equal("passed", result.status)
  end)

  it("describes a secret error object, Fail message and log line by a placeholder", function()
    local raised = run(function()
      error(secret)
    end)
    assert.are.equal("<secret value>", raised.message)

    local failed = run(function(ctx)
      ctx:Log(secret)
      ctx:Fail(secret)
    end)
    assert.is_truthy(failed.message:find("<secret value>", 1, true))
    assert.are.same({ "<secret value>" }, failed.logs)
  end)

  it("refuses to match a secret raised by ToRaise", function()
    local result = run(function(ctx)
      ctx
        :Expect(function()
          error(secret)
        end).Not
        :ToRaise("anything")
    end)
    assert.are.equal("failed", result.status)
    assert.is_truthy(
      result.message:find("it raised a secret value, which cannot be matched", 1, true)
    )
  end)

  it("refuses a secret value or key in ctx:Replace", function()
    local target = { key = "kept" }
    local messages = {}
    run(function(ctx)
      messages[1] = select(2, pcall(ctx.Replace, ctx, target, "key", secret))
      messages[2] = select(2, pcall(ctx.Replace, ctx, target, secret, 1))
    end)
    assert.is_truthy(messages[1]:find("value must not be a secret value", 1, true))
    assert.is_truthy(messages[2]:find("key must not be a secret value", 1, true))
    assert.are.equal("kept", target.key)
  end)

  it("hands a secret event payload to the test untouched", function()
    local received = nil
    TestKit:Suite("MyAddon"):Test("waits", function(ctx)
      local _, value = ctx:WaitFor("UNIT_NAME_UPDATE", 1)
      received = value
    end)
    TestKit:Run()
    TestEnv.Frame()
    TestEnv.Emit("UNIT_NAME_UPDATE", secret)
    TestEnv.Frame()
    assert.is_true(rawequal(secret, received))
  end)

  it("quotes at most 64 bytes of a string in a failure message", function()
    local long = string.rep("a", 64) .. string.rep("b", 100)
    local result = run(function(ctx)
      ctx:Expect(long):ToBe("short")
    end)
    assert.is_nil(result.message:find("ab", 1, true))
    assert.is_truthy(
      result.message:find('string "' .. string.rep("a", 64) .. '"... (164 bytes)', 1, true)
    )
  end)

  it("refuses a secret suite name at the caller", function()
    secrets["Secret"] = true
    TestEnv.expectErrorContaining("TestKit:Suite name must not be a secret value", function()
      TestKit:Suite("Secret")
    end)
  end)
end)
