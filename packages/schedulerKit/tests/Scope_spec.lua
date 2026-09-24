local TestEnv = require("SchedulerKitTestEnv")

describe("SchedulerKit scopes", function()
  after_each(TestEnv.Reset)

  it("allocates TimerKit scope only when delayed work is first used", function()
    local SchedulerKit, _, TimerKit = TestEnv.NewPackage()
    local originalCreateScope = TimerKit.CreateScope
    local createCalls = 0
    TimerKit.CreateScope = function(...)
      createCalls = createCalls + 1
      return originalCreateScope(...)
    end

    local scope = SchedulerKit:CreateScope()
    assert.are.equal(0, createCalls)

    scope:Schedule(function() end)
    TestEnv.Tick()
    assert.are.equal(0, createCalls)

    scope:After(1, function() end)
    assert.are.equal(1, createCalls)

    scope:After(2, function() end)
    assert.are.equal(1, createCalls)

    TimerKit.CreateScope = originalCreateScope
  end)

  it("tracks and cancels active jobs", function()
    local SchedulerKit = TestEnv.NewPackage()
    local scope = SchedulerKit:CreateScope()
    local pending = scope:Schedule(function() end)
    local delayed = scope:After(5, function() end)

    assert.are.equal(2, scope:GetActiveCount())
    scope:CancelAll()
    assert.are.equal(0, scope:GetActiveCount())
    assert.are.equal("cancelled", pending:GetState())
    assert.are.equal("cancelled", delayed:GetState())
    assert.is_false(scope:IsClosed())
  end)

  it("continues bulk cancellation after one native cancellation error", function()
    local SchedulerKit = TestEnv.NewPackage()
    local scope = SchedulerKit:CreateScope()
    local first = scope:After(5, function() end)
    local second = scope:After(5, function() end)
    TestEnv.FailNextTimerCancel("first cancel failed")

    local ok, value = pcall(function()
      scope:CancelAll()
    end)
    assert.is_false(ok)
    assert.are.equal("first cancel failed", value)
    assert.are.equal("cancelled", first:GetState())
    assert.are.equal("cancelled", second:GetState())
    assert.are.equal(0, scope:GetActiveCount())
  end)

  it("closes terminally", function()
    local SchedulerKit = TestEnv.NewPackage()
    local scope = SchedulerKit:CreateScope()
    scope:Schedule(function() end)

    assert.is_true(scope:Close())
    assert.is_true(scope:IsClosed())
    assert.is_false(scope:Close())
    assert.has_error(function()
      scope:Schedule(function() end)
    end)
  end)

  it("survives a job closing its own scope mid-run", function()
    local SchedulerKit = TestEnv.NewPackage()
    local scope = SchedulerKit:CreateScope()
    local afterClose = {}

    local job = scope:Schedule(function(context)
      context:GetJob():GetScope():Close()
      afterClose.closed = scope:IsClosed()
      afterClose.cancelled = context:IsCancelled()
      afterClose.shouldYield = context:ShouldYield()
    end)
    -- Queued behind the closing job, so it must be cancelled rather than
    -- resumed after its scope became terminal.
    local sibling = scope:Schedule(function() end)

    TestEnv.Tick()
    assert.is_true(afterClose.closed)
    assert.is_true(afterClose.cancelled)
    assert.is_true(afterClose.shouldYield)
    assert.are.equal("cancelled", job:GetState())
    assert.are.equal("cancelled", sibling:GetState())
    assert.are.equal(0, scope:GetActiveCount())
    assert.are.equal(0, SchedulerKit:GetActiveCount())
    assert.are.equal(0, TestEnv.ActiveOnUpdateCount())
  end)

  it("keeps a job that closes its own scope from being requeued after yielding", function()
    local SchedulerKit = TestEnv.NewPackage()
    local scope = SchedulerKit:CreateScope()
    local passes = 0

    local job = scope:Schedule(function(context)
      passes = passes + 1
      context:GetJob():GetScope():Close()
      context:Yield()
      passes = passes + 1
    end)

    TestEnv.Tick()
    TestEnv.Tick()
    assert.are.equal(1, passes)
    assert.are.equal("cancelled", job:GetState())
    assert.is_false(job:HasError())
  end)

  it("uses canonical addon scopes and keeps them open until CloseAddonScopes", function()
    local SchedulerKit = TestEnv.NewPackage()

    local first = SchedulerKit:ForAddon("Example")
    local second = SchedulerKit:ForAddon("Example")
    local job = first:Schedule(function() end)
    assert.are.equal(first, second)
    assert.are.equal("Example", first:GetAddonName())

    -- With neither LifecycleKit nor EventKit loaded nobody observes
    -- logout, so the scope stays open until the addon's own call
    -- (LogoutCoverage_spec.lua covers the other routes).
    TestEnv.Logout()
    assert.is_false(first:IsClosed())
    assert.are.equal("pending", job:GetState())
  end)

  it(
    "closes the addon scope, its delays and its family handles through CloseAddonScopes",
    function()
      local SchedulerKit = TestEnv.NewPackage()
      local scope = SchedulerKit:ForAddon("Example")
      local job = scope:Schedule(function() end)
      local delayed = scope:After(5, function() end)
      local debounced = scope:Debounce(function() end, 1)
      debounced()

      assert.is_true(SchedulerKit:CloseAddonScopes("Example"))

      assert.is_true(scope:IsClosed())
      assert.are.equal("cancelled", job:GetState())
      assert.are.equal("cancelled", delayed:GetState())
      assert.are.equal(0, scope:GetActiveCount())
      assert.are.equal(0, SchedulerKit:GetActiveCount())
      for index, native in ipairs(TestEnv.NativeTimers()) do
        assert.is_true(native.cancelled, "native timer " .. index .. " is still armed")
      end
    end
  )

  it("keeps the closed addon scope canonical and terminal", function()
    local SchedulerKit = TestEnv.NewPackage()
    local scope = SchedulerKit:ForAddon("Example")
    SchedulerKit:CloseAddonScopes("Example")

    assert.are.equal(scope, SchedulerKit:ForAddon("Example"))
    assert.is_false(SchedulerKit:CloseAddonScopes("Example"))
    assert.has_error(function()
      scope:Schedule(function() end)
    end)
  end)

  it("returns false and records nothing for an addon that never had a scope", function()
    local SchedulerKit = TestEnv.NewPackage()

    assert.is_false(SchedulerKit:CloseAddonScopes("Unknown"))

    local scope = SchedulerKit:ForAddon("Unknown")
    assert.is_false(scope:IsClosed())
    assert.is_not_nil(scope:Schedule(function() end))
  end)

  it("lets a running job close its own addon scope", function()
    local SchedulerKit = TestEnv.NewPackage()
    local scope = SchedulerKit:ForAddon("Example")
    local passes = 0
    local job = scope:Schedule(function(context)
      passes = passes + 1
      SchedulerKit:CloseAddonScopes("Example")
      context:Yield()
      passes = passes + 1
    end)
    local sibling = scope:Schedule(function() end)

    TestEnv.Tick()
    TestEnv.Tick()

    assert.are.equal(1, passes)
    assert.are.equal("cancelled", job:GetState())
    assert.are.equal("cancelled", sibling:GetState())
    assert.is_true(scope:IsClosed())
  end)

  it("isolates addon scopes and manual scopes from each other's closure", function()
    local SchedulerKit = TestEnv.NewPackage()
    local first = SchedulerKit:ForAddon("First")
    local second = SchedulerKit:ForAddon("Second")
    local manual = SchedulerKit:CreateScope()
    first:Schedule(function() end)
    local secondJob = second:Schedule(function() end)
    local manualJob = manual:Schedule(function() end)

    SchedulerKit:CloseAddonScopes("First")

    assert.is_true(first:IsClosed())
    assert.is_false(second:IsClosed())
    assert.is_false(manual:IsClosed())
    assert.are.equal("pending", secondJob:GetState())
    assert.are.equal("pending", manualJob:GetState())
  end)

  it("must be called on the SchedulerKit facade with an addon name", function()
    local SchedulerKit = TestEnv.NewPackage()
    SchedulerKit:ForAddon("Example")

    TestEnv.expectErrorContaining("must be called on the SchedulerKit facade", function()
      SchedulerKit.CloseAddonScopes({}, "Example")
    end)
    TestEnv.expectErrorContaining("must be called on the SchedulerKit facade", function()
      SchedulerKit.CloseAddonScopes("Example")
    end)
    TestEnv.expectErrorContaining(
      "SchedulerKit:CloseAddonScopes addonName must be a non-empty string",
      function()
        SchedulerKit:CloseAddonScopes("")
      end
    )
    assert.is_false(SchedulerKit:ForAddon("Example"):IsClosed())
  end)
end)
