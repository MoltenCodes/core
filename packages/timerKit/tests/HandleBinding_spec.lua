local TestEnv = require("TimerKitTestEnv")

-- Revision 10 binds every host callback to the host handle its start created
-- (docs/INTERNALS.md, "Stale host callbacks") and builds one-shot timers with
-- eight fields. These specs pin what that fast path must keep: a callback of
-- an earlier start never re-enters, cancellation and scope closure from inside
-- a callback behave as before, and a raising callback leaves the timer in the
-- state the host error handler expects.

describe("TimerKit handle binding", function()
  after_each(TestEnv.Reset)

  local function noop() end

  it("ignores the callback of a start that Restart replaced", function()
    local TimerKit = TestEnv.NewPackage()
    local calls = 0
    local timer = TimerKit:After(1, function()
      calls = calls + 1
    end)

    assert.is_true(timer:Restart())
    TestEnv.InvokeRaw(1)
    assert.are.equal(0, calls)
    assert.are.equal("running", timer:GetState())

    TestEnv.FireNative(2)
    assert.are.equal(1, calls)
    assert.are.equal("completed", timer:GetState())
  end)

  it("ignores the callback of a completed start once the timer runs again", function()
    local TimerKit = TestEnv.NewPackage()
    local calls = 0
    local timer = TimerKit:After(1, function()
      calls = calls + 1
    end)
    TestEnv.FireNative(1)
    assert.is_true(timer:Start())

    TestEnv.InvokeRaw(1)
    assert.are.equal(1, calls)
    assert.are.equal("running", timer:GetState())
    TestEnv.FireNative(2)
    assert.are.equal(2, calls)
  end)

  it("ignores a callback the host delivers from inside its constructor", function()
    TestEnv.Reset()
    TestEnv.InstallWowApi()
    -- The fixture's C_Timer is a global, as the client's is.
    -- selene: allow(global_usage)
    local hostTimers = rawget(_G, "C_Timer")
    local original = hostTimers.NewTimer
    local deliveredEarly = 0
    hostTimers.NewTimer = function(delay, callback)
      local native = original(delay, callback)
      if callback() then
        deliveredEarly = deliveredEarly + 1
      end
      return native
    end
    require("Registry")
    local TimerKit = require("TimerKit")

    local calls = 0
    local timer = TimerKit:After(1, function()
      calls = calls + 1
    end)
    assert.are.equal(0, deliveredEarly)
    assert.are.equal(0, calls)
    assert.are.equal("running", timer:GetState())

    TestEnv.FireNative(1)
    assert.are.equal(1, calls)
    assert.are.equal("completed", timer:GetState())
  end)

  it("answers false to Cancel from inside a one-shot's own callback", function()
    local TimerKit = TestEnv.NewPackage()
    local cancelled
    local timer = TimerKit:After(1, function(self)
      cancelled = self:Cancel()
    end)

    TestEnv.FireNative(1)
    assert.is_false(cancelled)
    assert.are.equal("completed", timer:GetState())
  end)

  it("stops a ticker cancelled from inside its own callback", function()
    local TimerKit = TestEnv.NewPackage()
    local ticks = 0
    local cancelled
    local ticker = TimerKit:Every(1, function(self)
      ticks = ticks + 1
      if ticks == 2 then
        cancelled = self:Cancel()
      end
    end)

    TestEnv.FireNative(1)
    TestEnv.FireNative(1)
    TestEnv.InvokeRaw(1)
    assert.are.equal(2, ticks)
    assert.is_true(cancelled)
    assert.is_true(TestEnv.NativeTimers()[1].cancelled)
    assert.are.equal("cancelled", ticker:GetState())
  end)

  it("cancels every timer when a callback closes its own scope", function()
    local TimerKit = TestEnv.NewPackage()
    local scope = TimerKit:CreateScope()
    local ticks, other = 0, 0
    local ticker = scope:Every(1, function(self)
      ticks = ticks + 1
      self:GetScope():Close()
    end)
    local pending = scope:After(5, function()
      other = other + 1
    end)

    TestEnv.FireNative(1)
    TestEnv.InvokeRaw(1)
    TestEnv.InvokeRaw(2)
    assert.are.equal(1, ticks)
    assert.are.equal(0, other)
    assert.are.equal("cancelled", ticker:GetState())
    assert.are.equal("cancelled", pending:GetState())
    assert.are.equal(0, scope:GetActiveCount())
    assert.is_true(scope:IsClosed())
  end)

  it("completes a one-shot whose callback raised, and keeps a raising ticker running", function()
    local TimerKit = TestEnv.NewPackage()
    local scope = TimerKit:CreateScope()
    local oneShot = scope:After(1, function()
      error("one-shot failed", 0)
    end)
    local ticks = 0
    local ticker = scope:Every(1, function()
      ticks = ticks + 1
      error("tick failed", 0)
    end)

    -- The host calls the callback unprotected and reports the error itself.
    assert.are.equal("one-shot failed", select(2, pcall(TestEnv.FireNative, 1)))
    assert.are.equal("completed", oneShot:GetState())
    assert.are.equal(1, scope:GetActiveCount())

    assert.is_false((pcall(TestEnv.FireNative, 2)))
    assert.is_false((pcall(TestEnv.FireNative, 2)))
    assert.are.equal(2, ticks)
    assert.are.equal("running", ticker:GetState())
    assert.is_true(ticker:Cancel())
    assert.are.equal(0, scope:GetActiveCount())
  end)

  it("keeps a one-shot's user data across Start, Cancel and completion", function()
    local TimerKit = TestEnv.NewPackage()
    local timer = TimerKit:New({ delay = 1, callback = noop })
    timer:SetUserData("first")
    assert.is_true(timer:Start())
    assert.is_true(timer:Cancel())
    timer:SetUserData("second")
    assert.is_true(timer:Restart())
    TestEnv.FireNative(2)
    assert.are.equal("second", timer:GetUserData())
    assert.is_false(timer:IsRepeating())
    assert.is_true(TimerKit:Every(1, noop):IsRepeating())
  end)

  it("keeps bulk cancellation in creation order across restarts", function()
    local TimerKit = TestEnv.NewPackage()
    local scope = TimerKit:CreateScope()
    local first = scope:After(1, noop)
    local second = scope:Every(1, noop)
    local third = scope:After(1, noop)
    first:Restart()

    -- Natives 1 to 3 are the three starts and 4 the restart of `first`.
    -- Record the order in which the sweep cancels them.
    local order = {}
    local natives = TestEnv.NativeTimers()
    for index = 2, 4 do
      local cancel = natives[index].Cancel
      natives[index].Cancel = function(native)
        order[#order + 1] = index
        return cancel(native)
      end
    end

    assert.are.equal(3, scope:CancelAll())
    assert.are.same({ 4, 2, 3 }, order)
    assert.are.equal("cancelled", first:GetState())
    assert.are.equal("cancelled", second:GetState())
    assert.are.equal("cancelled", third:GetState())
  end)
end)
