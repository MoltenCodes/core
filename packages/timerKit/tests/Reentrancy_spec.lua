local TestEnv = require("TimerKitTestEnv")

describe("TimerKit re-entrancy", function()
  after_each(TestEnv.Reset)

  it("marks one-shot completion before invoking user code", function()
    local TimerKit = TestEnv.NewPackage()
    local observedState
    local timer = TimerKit:After(1, function(self)
      observedState = self:GetState()
    end)

    TestEnv.FireNative(1)
    assert.are.equal("completed", observedState)
    assert.are.equal("completed", timer:GetState())
  end)

  it("can restart a one-shot from inside its callback", function()
    local TimerKit = TestEnv.NewPackage()
    local calls = 0
    local timer
    timer = TimerKit:After(1, function(self)
      calls = calls + 1
      if calls == 1 then
        self:Restart()
      end
    end)

    TestEnv.FireNative(1)
    assert.are.equal("running", timer:GetState())
    TestEnv.FireNative(2)
    assert.are.equal(2, calls)
    assert.are.equal("completed", timer:GetState())
  end)

  it("prevents stale native callbacks after cancellation", function()
    local TimerKit = TestEnv.NewPackage()
    local calls = 0
    local timer = TimerKit:After(1, function()
      calls = calls + 1
    end)

    timer:Cancel()
    TestEnv.InvokeRaw(1)
    assert.are.equal(0, calls)
  end)
end)
