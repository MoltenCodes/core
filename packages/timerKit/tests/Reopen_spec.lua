local TestEnv = require("TimerKitTestEnv")

describe("TimerKit scope reopening", function()
  after_each(TestEnv.Reset)

  it("reopens a closed manual scope, empty and usable again", function()
    local TimerKit = TestEnv.NewPackage()
    local scope = TimerKit:CreateScope()
    local closedOver = scope:Every(1, function() end)
    assert.is_true(scope:Close())

    assert.is_true(scope:Reopen())

    assert.is_false(scope:IsClosed())
    assert.are.equal(0, scope:GetActiveCount())
    -- The timer the close cancelled stays cancelled until it is started.
    assert.is_true(closedOver:IsCancelled())
    local fired = false
    scope:After(1, function()
      fired = true
    end)
    TestEnv.FireNative(2)
    assert.is_true(fired)
    assert.is_true(closedOver:Start())
    assert.are.equal(1, scope:GetActiveCount())
  end)

  it("answers false for an open scope", function()
    local TimerKit = TestEnv.NewPackage()
    local scope = TimerKit:CreateScope()

    assert.is_false(scope:Reopen())
    assert.is_false(scope:IsClosed())
  end)

  it("refuses an addon scope at the caller's line", function()
    local TimerKit = TestEnv.NewPackage()
    local scope = TimerKit:ForAddon("Reopened")
    TimerKit:CloseAddonScopes("Reopened")

    local ok, message = pcall(scope.Reopen, scope)

    assert.is_false(ok)
    assert.is_truthy(
      string.find(message, "TimerKit.Scope:Reopen cannot reopen an addon scope", 1, true)
    )
    assert.is_true(scope:IsClosed())
  end)

  it("refuses a receiver that is not a scope", function()
    local TimerKit = TestEnv.NewPackage()
    local Scope = TimerKit.Scope

    for _, receiver in ipairs({ "scope", 1, {}, setmetatable({}, { __metatable = false }) }) do
      local ok, message = pcall(Scope.Reopen, receiver)
      assert.is_false(ok)
      assert.is_truthy(
        string.find(message, "TimerKit.Scope:Reopen must be called on a TimerKit scope", 1, true)
      )
    end
  end)
end)
