local TestEnv = require("CommKitTestEnv")

local PREFIX = "CKDriver"

describe("CommKit send driver (revision 11)", function()
  after_each(TestEnv.Reset)

  it("loads and sends without SchedulerKit, on a TimerKit timer", function()
    local CommKit = TestEnv.Load({ schedulerKit = false })
    assert.is_nil(package.loaded["SchedulerKit"])
    local scope = CommKit:CreateScope()
    TestEnv.HoldSends(CommKit)
    local handle = scope:Send({ prefix = PREFIX, text = "x", distribution = "PARTY" })
    assert.are.equal("queued", handle:GetState())
    assert.are.equal(1, TestEnv.DriverRuns(CommKit))
    assert.are.equal(false, CommKit._state.kitScopes.scheduler)
    TestEnv.ReleaseSends(CommKit)
    assert.are.equal("sent", handle:GetState())
    assert.are.equal(0, TestEnv.DriverRuns(CommKit))
    assert.are.equal(0, CommKit._state.kitScopes.timer:GetActiveCount())
  end)

  it("runs as a SchedulerKit job while SchedulerKit is loaded", function()
    local CommKit = TestEnv.Load()
    TestEnv.HoldSends(CommKit)
    CommKit:CreateScope():Send({ prefix = PREFIX, text = "x", distribution = "PARTY" })
    assert.are.equal(1, CommKit._state.kitScopes.scheduler:GetActiveCount())
  end)

  it("continues after the run cap on a later frame without SchedulerKit", function()
    local CommKit = TestEnv.Load({ schedulerKit = false })
    CommKit:SetLimits({ burst = 1000000, maxCps = 100000, maxQueuedMessages = 1000 })
    local scope = CommKit:CreateScope()
    TestEnv.HoldSends(CommKit)
    for _ = 1, 40 do
      scope:Send({ prefix = PREFIX, text = "c", distribution = "PARTY" })
    end
    CommKit._state.budget.tokens = 1000000
    TestEnv.Advance(1)
    assert.are.equal(40, #TestEnv.TakeOutbox())
  end)

  it(
    "uses a SchedulerKit loaded after CommKit from the next schedule after the lookup interval",
    function()
      local CommKit = TestEnv.Load({ schedulerKit = false })
      local scope = CommKit:CreateScope()
      TestEnv.HoldSends(CommKit)
      scope:Send({ prefix = PREFIX, text = "a", distribution = "PARTY" })
      TestEnv.ReleaseSends(CommKit, 2)
      require("SchedulerKit")
      TestEnv.HoldSends(CommKit)
      scope:Send({ prefix = PREFIX, text = "b", distribution = "PARTY" })
      local schedulerScope = CommKit._state.kitScopes.scheduler
      assert.are_not.equal(false, schedulerScope)
      assert.are.equal(1, schedulerScope:GetActiveCount())
      TestEnv.ReleaseSends(CommKit)
      assert.are.equal(2, #TestEnv.TakeOutbox())
    end
  )

  it("finishes a message waiting on a revision 10 driver job after the upgrade", function()
    local older = TestEnv.Load({ commKitRevision = 10 })
    local scope = older:CreateScope()
    TestEnv.HoldSends(older)
    local handle = scope:Send({ prefix = PREFIX, text = TestEnv.Text(600), distribution = "PARTY" })
    assert.are.equal("queued", handle:GetState())
    assert.are_not.equal(false, older._state.driver.job)
    package.loaded["CommKit"] = nil
    local CommKit = require("CommKit")
    assert.are.equal(older, CommKit)
    TestEnv.ReleaseSends(CommKit, 10)
    assert.are.equal("sent", handle:GetState())
    assert.are.equal(3, #TestEnv.TakeOutbox())
    assert.are.equal(0, TestEnv.DriverRuns(CommKit))
  end)
end)
