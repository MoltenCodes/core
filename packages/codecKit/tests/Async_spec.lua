local TestEnv = require("CodecKitTestEnv")
local Async = TestEnv.Async

describe("CodecKit asynchronous variants", function()
  after_each(Async.Reset)

  ---A value large enough to need many frames under a 2 ms budget.
  local function largeValue()
    local random = TestEnv.NewRandom(27)
    local rows = {}
    for index = 1, 3000 do
      rows[index] = { id = index, name = TestEnv.RandomText(random, 4), score = index / 7 }
    end
    return { rows = rows }
  end

  it("encodes under the frame budget, yielding at least once, to the synchronous result", function()
    -- Every clock read costs 0.5 ms, so a 2 ms frame holds about four
    -- budget checks.
    local CodecKit, SchedulerKit = Async.NewPackageWithTickingClock(0.5)
    local scope = SchedulerKit:CreateScope()
    local value = largeValue()
    local options = { compress = "deflate", channel = "print", level = 6 }

    local results = nil
    local job = CodecKit:EncodeAsync(value, options, scope, function(ok, text)
      results = { ok, text }
    end)
    assert.is_nil(results)
    assert.are.equal("pending", job:GetState())

    local ticks = Async.TickUntil(function()
      return results ~= nil
    end, 10000)
    assert.is_not_nil(results)
    assert.is_true(ticks > 1, "the job finished in one frame")
    assert.is_true(results[1])
    assert.are.equal("completed", job:GetState())
    local syncOk, expected = CodecKit:Encode(value, options)
    assert.is_true(syncOk)
    assert.are.equal(expected, results[2])
    assert.are.same({}, Async.ReportedErrors())
  end)

  it("decodes under the frame budget, yielding at least once", function()
    local CodecKit, SchedulerKit = Async.NewPackageWithTickingClock(0.5)
    local scope = SchedulerKit:CreateScope()
    local value = largeValue()
    local _, text = CodecKit:Encode(value, { compress = "deflate", channel = "print" })

    local results = nil
    CodecKit:DecodeAsync(text, nil, scope, function(ok, decoded)
      results = { ok, decoded }
    end)
    local ticks = Async.TickUntil(function()
      return results ~= nil
    end, 10000)
    assert.is_true(ticks > 1)
    assert.is_true(results[1])
    assert.is_true(TestEnv.Same(value, results[2]))
  end)

  it("hands failures to the callback as reasons", function()
    local CodecKit, SchedulerKit = Async.NewPackageWithTickingClock(0.5)
    local scope = SchedulerKit:CreateScope()
    local cyclic = {}
    cyclic[1] = cyclic
    local reasons = {}
    CodecKit:EncodeAsync(cyclic, nil, scope, function(ok, reason)
      reasons[#reasons + 1] = { ok, reason }
    end)
    CodecKit:DecodeAsync("\1\1\12", { channel = "none" }, scope, function(ok, reason)
      reasons[#reasons + 1] = { ok, reason }
    end)
    Async.TickUntil(function()
      return #reasons == 2
    end, 100)
    assert.are.same({ { false, "cycle" }, { false, "unknownType" } }, reasons)
  end)

  it("never calls back for a cancelled job and leaks nothing into the pool", function()
    local CodecKit, SchedulerKit = Async.NewPackageWithTickingClock(0.5)
    local scope = SchedulerKit:CreateScope()
    local pool = CodecKit._state.pool
    local activeBefore = pool:GetActiveCount()
    local called = false
    CodecKit:EncodeAsync(largeValue(), { compress = "deflate" }, scope, function()
      called = true
    end)
    Async.Tick()
    scope:Close()
    for _ = 1, 50 do
      Async.Tick()
    end
    assert.is_false(called)
    assert.are.equal(activeBefore, pool:GetActiveCount())
  end)

  it("raises at the caller without SchedulerKit", function()
    local CodecKit = TestEnv.NewPackage()
    local ok, message = pcall(CodecKit.EncodeAsync, CodecKit, 1, nil, {}, function() end)
    assert.is_false(ok)
    assert.is_not_nil(
      message:find(
        "CodecKit:EncodeAsync requires SchedulerKit API 1, which is not loaded (absent)",
        1,
        true
      )
    )
    ok, message = pcall(CodecKit.DecodeAsync, CodecKit, "", nil, {}, function() end)
    assert.is_false(ok)
    assert.is_not_nil(message:find("CodecKit:DecodeAsync requires SchedulerKit API 1", 1, true))
    TestEnv.Reset()
  end)

  it("refuses a foreign scope, a closed scope and a missing callback", function()
    local CodecKit, SchedulerKit = Async.NewPackageWithTickingClock(0.5)
    local scope = SchedulerKit:CreateScope()
    Async.expectErrorContaining(
      "CodecKit:EncodeAsync scope must be a SchedulerKit scope",
      function()
        CodecKit:EncodeAsync(1, nil, {}, function() end)
      end
    )
    Async.expectErrorContaining("CodecKit:DecodeAsync callback must be a function", function()
      CodecKit:DecodeAsync("", nil, scope, nil)
    end)
    scope:Close()
    Async.expectErrorContaining("CodecKit:EncodeAsync scope is closed", function()
      CodecKit:EncodeAsync(1, nil, scope, function() end)
    end)
  end)

  it("refuses a secret anywhere in the value at the caller", function()
    local CodecKit, SchedulerKit = Async.NewPackageWithTickingClock(0.5)
    local scope = SchedulerKit:CreateScope()
    local secret = TestEnv.NewSecret()
    TestEnv.InstallSecretProbe({ [secret] = true })
    Async.expectErrorContaining(
      "CodecKit:EncodeAsync value must not contain a secret value",
      function()
        CodecKit:EncodeAsync({ 1, { deep = { secret } } }, nil, scope, function() end)
      end
    )
    assert.are.equal(0, scope:GetActiveCount())
  end)

  it("scans as far as the encoder reaches before refusing a secret at the caller", function()
    local CodecKit, SchedulerKit = Async.NewPackageWithTickingClock(0.5)
    local scope = SchedulerKit:CreateScope()
    local secret = TestEnv.NewSecret()
    TestEnv.InstallSecretProbe({ [secret] = true })
    CodecKit:SetLimits({ maxValues = 100 })
    -- The encoder counts one per array element, so it reaches the secret
    -- at value 62; a scan that counted keys too stopped at element 50.
    local value = {}
    for index = 1, 60 do
      value[index] = index
    end
    value[61] = secret
    Async.expectErrorContaining(
      "CodecKit:EncodeAsync value must not contain a secret value",
      function()
        CodecKit:EncodeAsync(value, nil, scope, function() end)
      end
    )
    assert.are.equal(0, scope:GetActiveCount())
  end)

  it("bounds the call-time secret scan by maxOutputBytes when maxValues is lifted", function()
    local CodecKit, SchedulerKit = Async.NewPackageWithTickingClock(0.5)
    local scope = SchedulerKit:CreateScope()
    TestEnv.InstallSecretProbe({})
    CodecKit:SetLimits({
      maxValues = CodecKit.UNBOUNDED,
      maxOutputBytes = 1000,
      maxDepth = 64,
    })
    -- Two references to itself: a walk bounded only by depth would visit
    -- 2^64 tables. The encoder refuses it with "cycle"; the scan stops
    -- after at most maxOutputBytes + maxDepth + 2 values.
    local cyclic = {}
    cyclic[1] = cyclic
    cyclic[2] = cyclic
    local result
    CodecKit:EncodeAsync(cyclic, nil, scope, function(ok, reason)
      result = { ok, reason }
    end)
    Async.TickUntil(function()
      return result ~= nil
    end, 50)
    assert.are.same({ false, "cycle" }, result)
  end)
end)
