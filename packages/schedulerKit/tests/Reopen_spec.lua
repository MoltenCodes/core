local TestEnv = require("SchedulerKitTestEnv")

local SOURCE = debug.getinfo(1, "S").short_src

-- `Scope:Reopen` returns a closed manual scope to service, empty, so an owner
-- such as a ModuleKit module keeps one scope object across its enable cycles.
-- An addon scope stays terminal once closed.

describe("SchedulerKit Scope:Reopen", function()
  after_each(TestEnv.Reset)

  it("reopens a closed manual scope and answers false for an open one", function()
    local SchedulerKit = TestEnv.NewPackage()
    local scope = SchedulerKit:CreateScope()

    assert.is_false(scope:Reopen())
    scope:Close()
    assert.is_true(scope:Reopen())
    assert.is_false(scope:IsClosed())
    assert.is_false(scope:Reopen())
    assert.are.equal(0, scope:GetActiveCount())
  end)

  it("keeps the jobs and handles of the closed period cancelled", function()
    local SchedulerKit = TestEnv.NewPackage()
    local scope = SchedulerKit:CreateScope()
    local ran = 0
    local pending = scope:Schedule(function()
      ran = ran + 1
    end)
    local delayed = scope:After(1, function()
      ran = ran + 10
    end)
    local debounced = scope:Debounce(function()
      ran = ran + 100
    end, 1)

    scope:Close()
    scope:Reopen()
    TestEnv.Tick()
    TestEnv.FireNative(#TestEnv.NativeTimers())

    assert.are.equal(0, ran)
    assert.are.equal("cancelled", pending:GetState())
    assert.are.equal("cancelled", delayed:GetState())
    assert.is_true(debounced:IsClosed())
  end)

  it("schedules immediate and delayed work again after reopening", function()
    local SchedulerKit, _, TimerKit = TestEnv.NewPackage()
    local scope = SchedulerKit:CreateScope()
    scope:After(5, function() end)
    scope:Close()

    local createCalls = 0
    local originalCreateScope = TimerKit.CreateScope
    TimerKit.CreateScope = function(...)
      createCalls = createCalls + 1
      return originalCreateScope(...)
    end

    assert.is_true(scope:Reopen())
    local ran = {}
    scope:Schedule(function()
      ran[#ran + 1] = "now"
    end)
    local delayed = scope:After(1, function()
      ran[#ran + 1] = "later"
    end)
    TimerKit.CreateScope = originalCreateScope

    -- The TimerKit scope the close ended is replaced, never reused.
    assert.are.equal(1, createCalls)
    TestEnv.Tick()
    TestEnv.FireNative(#TestEnv.NativeTimers())
    TestEnv.Tick()
    assert.are.same({ "now", "later" }, ran)
    assert.are.equal("completed", delayed:GetState())
  end)

  it("refuses an addon scope at the caller's line", function()
    local SchedulerKit = TestEnv.NewPackage()
    local scope = SchedulerKit:ForAddon("MyAddon")
    SchedulerKit:CloseAddonScopes("MyAddon")

    local line
    local ok, message = pcall(function()
      line = debug.getinfo(1, "l").currentline + 1
      scope:Reopen()
    end)
    assert.is_false(ok)
    assert.are.equal(
      SOURCE .. ":" .. line .. ": SchedulerKit.Scope:Reopen cannot reopen an addon scope",
      message
    )
    assert.is_true(scope:IsClosed())
  end)

  it("refuses a receiver that is not a SchedulerKit scope", function()
    local SchedulerKit = TestEnv.NewPackage()
    local Scope = SchedulerKit.Scope
    local receivers = { "scope", 1, {}, setmetatable({}, {}) }
    for index = 1, #receivers do
      local ok, message = pcall(Scope.Reopen, receivers[index])
      assert.is_false(ok)
      assert.is_truthy(
        string.find(
          message,
          "SchedulerKit.Scope:Reopen must be called on a SchedulerKit scope",
          1,
          true
        )
      )
    end
  end)

  it("reopens a scope the previous revision created and closed", function()
    TestEnv.Reset()
    TestEnv.InstallWowApi()
    require("Registry")
    require("TimerKit")
    local current = require("SchedulerKit").REVISION
    TestEnv.Reset()
    TestEnv.InstallWowApi()
    require("Registry")
    require("TimerKit")
    local old = TestEnv.LoadRevision(current - 1)
    TestEnv.LoadParts()
    local scope = old:CreateScope()
    scope:Close()

    package.loaded["SchedulerKit"] = nil
    local upgraded = require("SchedulerKit")
    TestEnv.LoadParts()
    assert.are.equal(current, upgraded.REVISION)
    assert.is_true(scope:Reopen())
    local ran = false
    scope:Schedule(function()
      ran = true
    end)
    TestEnv.Tick()
    assert.is_true(ran)
  end)
end)
