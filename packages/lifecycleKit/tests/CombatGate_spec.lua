local TestEnv = require("LifecycleKitTestEnv")

-- The combat gate: one lockdown state shared by every addon, a bounded
-- per-addon "run when out of combat" queue, and repeating combat notices.
-- `TestEnv.EnterCombat` / `TestEnv.LeaveCombat` send the two host events in
-- the order the client does, with `InCombatLockdown()` following them.

-- Busted loads `LifecycleKit` through the fixture, so specs that seed the host
-- before the package loads require the chain themselves.
local function loadPackageInCombat()
  TestEnv.Reset()
  TestEnv.InstallWowApi()
  TestEnv.SetCombatLockdown(true)
  require("Registry")
  require("SignalKit")
  require("EventKit")
  return require("LifecycleKit")
end

local function takeSingleReportedError()
  local reported = TestEnv.TakeReportedErrors()
  assert.are.equal(1, #reported)
  return reported[1].value
end

describe("LifecycleKit combat state", function()
  local LifecycleKit
  before_each(function()
    LifecycleKit = TestEnv.NewPackage()
  end)
  after_each(TestEnv.Reset)

  it("reports out of combat when the host is not in lockdown", function()
    LifecycleKit:ForAddon("MyAddon")
    assert.is_false(LifecycleKit:IsInCombat())
  end)

  it("flips on PLAYER_REGEN_DISABLED and PLAYER_REGEN_ENABLED", function()
    LifecycleKit:ForAddon("MyAddon")

    TestEnv.EnterCombat()
    assert.is_true(LifecycleKit:IsInCombat())

    TestEnv.LeaveCombat()
    assert.is_false(LifecycleKit:IsInCombat())
  end)

  it("flips before InCombatLockdown does, inside the event itself", function()
    -- The host sends PLAYER_REGEN_DISABLED just before lockdown begins. The
    -- shared state must already say "in combat" to anyone asking then.
    LifecycleKit:ForAddon("MyAddon")
    local seenByKit, seenByHost
    -- Connected after `ForAddon`, so LifecycleKit's watcher runs first.
    require("EventKit"):Connect("PLAYER_REGEN_DISABLED", function()
      seenByKit = LifecycleKit:IsInCombat()
      -- selene: allow(global_usage)
      seenByHost = rawget(_G, "InCombatLockdown")()
    end)

    TestEnv.EnterCombat()

    assert.is_true(seenByKit)
    assert.is_false(seenByHost)
  end)

  it("asks the host directly before any addon installed the watchers", function()
    TestEnv.SetCombatLockdown(true)
    assert.is_true(LifecycleKit:IsInCombat())
    TestEnv.SetCombatLockdown(false)
    assert.is_false(LifecycleKit:IsInCombat())
  end)

  it("seeds the state from InCombatLockdown when the package loads", function()
    local InCombat = loadPackageInCombat()
    InCombat:ForAddon("MyAddon")
    assert.is_true(InCombat:IsInCombat())

    local ran = false
    InCombat:ForAddon("MyAddon"):WhenOutOfCombat(function()
      ran = true
    end)
    assert.is_false(ran)

    TestEnv.LeaveCombat()
    assert.is_true(ran)
    assert.is_false(InCombat:IsInCombat())
  end)

  it("re-reads the host at PLAYER_LOGIN", function()
    -- A /reload in combat loads every addon while lockdown is active; the
    -- first watcher sees no PLAYER_REGEN_DISABLED for that combat.
    local life = LifecycleKit:ForAddon("MyAddon")
    TestEnv.LoadAddon("MyAddon")
    local starts = 0
    life:OnCombatStart(function()
      starts = starts + 1
    end)

    TestEnv.SetCombatLockdown(true)
    TestEnv.Login()

    assert.is_true(LifecycleKit:IsInCombat())
    assert.are.equal(1, starts)
  end)

  it("treats a missing InCombatLockdown as out of combat", function()
    -- Other package suites run without the combat stub.
    -- selene: allow(global_usage)
    rawset(_G, "InCombatLockdown", nil)
    LifecycleKit:ForAddon("MyAddon")
    assert.is_false(LifecycleKit:IsInCombat())
  end)

  it("stops watching combat at logout and falls back to the host", function()
    LifecycleKit:ForAddon("MyAddon")
    TestEnv.Logout()

    TestEnv.Emit("PLAYER_REGEN_DISABLED")
    assert.is_false(LifecycleKit:IsInCombat())
    TestEnv.SetCombatLockdown(true)
    assert.is_true(LifecycleKit:IsInCombat())
  end)
end)

describe("LifecycleKit WhenOutOfCombat", function()
  local LifecycleKit
  before_each(function()
    LifecycleKit = TestEnv.NewPackage()
  end)
  after_each(TestEnv.Reset)

  it("runs at once out of combat and returns a spent handle", function()
    local life = LifecycleKit:ForAddon("MyAddon")
    local received = {}
    local handle = life:WhenOutOfCombat(function(instance, ran, reason)
      received = { instance = instance, ran = ran, reason = reason }
    end)

    assert.are.equal(life, received.instance)
    assert.is_true(received.ran)
    assert.is_nil(received.reason)
    assert.is_false(handle:IsPending())
    assert.is_false(handle:Cancel())
  end)

  it("propagates an immediate callback's error object unchanged", function()
    local life = LifecycleKit:ForAddon("MyAddon")
    local errorObject = { reason = "immediate failure" }
    local ok, message = pcall(function()
      life:WhenOutOfCombat(function()
        error(errorObject)
      end)
    end)
    assert.is_false(ok)
    assert.are.equal(errorObject, message)
  end)

  it("queues in combat and runs on the next PLAYER_REGEN_ENABLED", function()
    local life = LifecycleKit:ForAddon("MyAddon")
    TestEnv.EnterCombat()
    local received
    local handle = life:WhenOutOfCombat(function(instance, ran, reason)
      received = { instance = instance, ran = ran, reason = reason }
    end)

    assert.is_nil(received)
    assert.is_true(handle:IsPending())

    TestEnv.LeaveCombat()

    assert.are.equal(life, received.instance)
    assert.is_true(received.ran)
    assert.is_nil(received.reason)
    assert.is_false(handle:IsPending())
  end)

  it("runs queued calls first in, first out", function()
    local life = LifecycleKit:ForAddon("MyAddon")
    TestEnv.EnterCombat()
    local order = {}
    for index = 1, 3 do
      life:WhenOutOfCombat(function()
        order[#order + 1] = index
      end)
    end

    TestEnv.LeaveCombat()

    assert.are.same({ 1, 2, 3 }, order)
  end)

  it("runs queued calls even for an addon that has not loaded yet", function()
    local life = LifecycleKit:ForAddon("MyAddon")
    TestEnv.EnterCombat()
    local ran = false
    life:WhenOutOfCombat(function()
      ran = true
    end)
    TestEnv.LeaveCombat()
    assert.is_true(ran)
  end)

  it("reuses the queue across combats", function()
    local life = LifecycleKit:ForAddon("MyAddon")
    local runs = 0
    for _ = 1, 3 do
      TestEnv.EnterCombat()
      life:WhenOutOfCombat(function()
        runs = runs + 1
      end)
      TestEnv.LeaveCombat()
    end
    assert.are.equal(3, runs)
  end)

  it("refuses beyond the default limit of 64 without dropping queued calls", function()
    local life = LifecycleKit:ForAddon("MyAddon")
    assert.are.equal(64, life:GetCombatQueueLimit())
    TestEnv.EnterCombat()
    local runs = 0
    for _ = 1, 64 do
      assert.is_not_nil(life:WhenOutOfCombat(function()
        runs = runs + 1
      end))
    end

    local handle, reason = life:WhenOutOfCombat(function()
      runs = runs + 100
    end)

    assert.is_nil(handle)
    assert.are.equal("full", reason)
    TestEnv.LeaveCombat()
    assert.are.equal(64, runs)
  end)

  it("honours a lowered limit and never drops what is already queued", function()
    local life = LifecycleKit:ForAddon("MyAddon")
    TestEnv.EnterCombat()
    local runs = 0
    for _ = 1, 3 do
      life:WhenOutOfCombat(function()
        runs = runs + 1
      end)
    end

    life:SetCombatQueueLimit(2)

    assert.are.equal(2, life:GetCombatQueueLimit())
    local handle, reason = life:WhenOutOfCombat(function() end)
    assert.is_nil(handle)
    assert.are.equal("full", reason)
    TestEnv.LeaveCombat()
    assert.are.equal(3, runs)
  end)

  it("cancels a pending call and frees its place", function()
    local life = LifecycleKit:ForAddon("MyAddon")
    life:SetCombatQueueLimit(1)
    TestEnv.EnterCombat()
    local order = {}
    local first = life:WhenOutOfCombat(function()
      order[#order + 1] = "first"
    end)

    assert.is_true(first:Cancel())
    assert.is_false(first:Cancel())
    assert.is_false(first:IsPending())

    local second = life:WhenOutOfCombat(function()
      order[#order + 1] = "second"
    end)
    assert.is_not_nil(second)
    TestEnv.LeaveCombat()
    assert.are.same({ "second" }, order)
  end)

  it("reclaims cancelled slots while keeping FIFO order", function()
    local life = LifecycleKit:ForAddon("MyAddon")
    life:SetCombatQueueLimit(2)
    TestEnv.EnterCombat()
    local order = {}
    life
      :WhenOutOfCombat(function()
        order[#order + 1] = "a"
      end)
      :Cancel()
    life:WhenOutOfCombat(function()
      order[#order + 1] = "b"
    end)
    -- The array is at the limit with one cancelled slot: this call has to
    -- compact it rather than grow it or refuse.
    local third = life:WhenOutOfCombat(function()
      order[#order + 1] = "c"
    end)

    assert.is_not_nil(third)
    assert.are.equal(2, #life._combatQueue)
    TestEnv.LeaveCombat()
    assert.are.same({ "b", "c" }, order)
  end)

  it("runs every queued call and re-raises the first error after the batch", function()
    local first = LifecycleKit:ForAddon("FirstAddon")
    local second = LifecycleKit:ForAddon("SecondAddon")
    TestEnv.EnterCombat()
    local order = {}
    local errorObject = { reason = "deferred failure" }
    first:WhenOutOfCombat(function()
      order[#order + 1] = "first-a"
      error(errorObject)
    end)
    first:WhenOutOfCombat(function()
      order[#order + 1] = "first-b"
      error("second failure")
    end)
    second:WhenOutOfCombat(function()
      order[#order + 1] = "second"
    end)

    TestEnv.LeaveCombat()

    assert.are.same({ "first-a", "first-b", "second" }, order)
    assert.are.equal(errorObject, takeSingleReportedError())
    assert.is_false(LifecycleKit:IsInCombat())
  end)

  it("keeps the rest queued if a host ever re-enters combat mid-drain", function()
    -- The client cannot deliver PLAYER_REGEN_DISABLED inside a handler;
    -- the nested EnterCombat below models a host that did, to pin the
    -- defensive guard: protected work does not run in combat.
    local life = LifecycleKit:ForAddon("MyAddon")
    TestEnv.EnterCombat()
    local order = {}
    life:WhenOutOfCombat(function()
      order[#order + 1] = "a"
      TestEnv.EnterCombat()
    end)
    local later = life:WhenOutOfCombat(function()
      order[#order + 1] = "b"
    end)

    TestEnv.LeaveCombat()

    assert.are.same({ "a" }, order)
    assert.is_true(later:IsPending())
    assert.is_true(LifecycleKit:IsInCombat())

    TestEnv.LeaveCombat()
    assert.are.same({ "a", "b" }, order)
  end)

  it("runs a call made inside a drain at once, ahead of the rest", function()
    local life = LifecycleKit:ForAddon("MyAddon")
    TestEnv.EnterCombat()
    local order = {}
    life:WhenOutOfCombat(function(instance)
      order[#order + 1] = "a"
      instance:WhenOutOfCombat(function()
        order[#order + 1] = "nested"
      end)
    end)
    life:WhenOutOfCombat(function()
      order[#order + 1] = "b"
    end)

    TestEnv.LeaveCombat()

    assert.are.same({ "a", "nested", "b" }, order)
  end)

  it("calls pending callbacks with false and 'shutdown' at logout", function()
    local life = LifecycleKit:ForAddon("MyAddon")
    TestEnv.EnterCombat()
    local received = {}
    local handle = life:WhenOutOfCombat(function(instance, ran, reason)
      received = { instance = instance, ran = ran, reason = reason }
    end)

    TestEnv.Logout()

    assert.are.equal(life, received.instance)
    assert.is_false(received.ran)
    assert.are.equal("shutdown", received.reason)
    assert.is_false(handle:IsPending())

    local refused, reason = life:WhenOutOfCombat(function() end)
    assert.is_nil(refused)
    assert.are.equal("shutdown", reason)
  end)

  it("closes the queue before the shutdown callbacks run", function()
    local life = LifecycleKit:ForAddon("MyAddon")
    TestEnv.EnterCombat()
    local order = {}
    life:WhenOutOfCombat(function()
      order[#order + 1] = "deferred"
    end)
    life:OnShutdown(function()
      order[#order + 1] = "shutdown"
    end)

    TestEnv.Logout()

    assert.are.same({ "deferred", "shutdown" }, order)
  end)

  it("carries pending calls across a duplicate embedding", function()
    local life = LifecycleKit:ForAddon("MyAddon")
    TestEnv.EnterCombat()
    local ran = false
    life:WhenOutOfCombat(function()
      ran = true
    end)

    assert.are.equal(LifecycleKit, TestEnv.ReloadPackage())
    TestEnv.LeaveCombat()

    assert.is_true(ran)
  end)
end)

describe("LifecycleKit combat notices", function()
  local LifecycleKit
  before_each(function()
    LifecycleKit = TestEnv.NewPackage()
  end)
  after_each(TestEnv.Reset)

  local function loadedAddon(addonName)
    local life = LifecycleKit:ForAddon(addonName)
    TestEnv.LoadAddon(addonName)
    return life
  end

  it("delivers OnCombatStart and OnCombatEnd on every combat", function()
    local life = loadedAddon("MyAddon")
    local seen = {}
    local startSubscription = life:OnCombatStart(function(instance)
      assert.are.equal(life, instance)
      seen[#seen + 1] = "start:" .. tostring(LifecycleKit:IsInCombat())
    end)
    life:OnCombatEnd(function()
      seen[#seen + 1] = "end:" .. tostring(LifecycleKit:IsInCombat())
    end)

    TestEnv.EnterCombat()
    TestEnv.LeaveCombat()
    TestEnv.EnterCombat()
    TestEnv.LeaveCombat()

    assert.are.same({ "start:true", "end:false", "start:true", "end:false" }, seen)
    assert.is_true(startSubscription:IsConnected())
  end)

  it("drains the addon's queue before its OnCombatEnd runs", function()
    local life = loadedAddon("MyAddon")
    local order = {}
    life:OnCombatEnd(function()
      order[#order + 1] = "end"
    end)
    TestEnv.EnterCombat()
    life:WhenOutOfCombat(function()
      order[#order + 1] = "deferred"
    end)

    TestEnv.LeaveCombat()

    assert.are.same({ "deferred", "end" }, order)
  end)

  it("holds notices back until the addon has loaded", function()
    local life = LifecycleKit:ForAddon("MyAddon")
    local starts = 0
    local subscription = life:OnCombatStart(function()
      starts = starts + 1
    end)

    TestEnv.EnterCombat()
    TestEnv.LeaveCombat()
    assert.are.equal(0, starts)
    assert.is_true(subscription:IsConnected())

    TestEnv.LoadAddon("MyAddon")
    TestEnv.EnterCombat()
    assert.are.equal(1, starts)
  end)

  it("gives an addon loaded mid-combat OnCombatEnd without OnCombatStart", function()
    local life = LifecycleKit:ForAddon("OnDemandAddon")
    local seen = {}
    life:OnCombatStart(function()
      seen[#seen + 1] = "start"
    end)
    life:OnCombatEnd(function()
      seen[#seen + 1] = "end"
    end)
    local inCombatAtLoad
    life:OnLoaded(function()
      inCombatAtLoad = LifecycleKit:IsInCombat()
    end)

    TestEnv.EnterCombat()
    TestEnv.LoadAddon("OnDemandAddon")
    TestEnv.LeaveCombat()

    assert.is_true(inCombatAtLoad)
    assert.are.same({ "end" }, seen)
  end)

  it("does not repeat a notice for a redundant host event", function()
    local life = loadedAddon("MyAddon")
    local starts, ends = 0, 0
    life:OnCombatStart(function()
      starts = starts + 1
    end)
    life:OnCombatEnd(function()
      ends = ends + 1
    end)

    TestEnv.LeaveCombat()
    TestEnv.EnterCombat()
    TestEnv.EnterCombat()

    assert.are.equal(0, ends)
    assert.are.equal(1, starts)
  end)

  it("stops delivering to a disconnected subscription", function()
    local life = loadedAddon("MyAddon")
    local starts = 0
    local subscription = life:OnCombatStart(function()
      starts = starts + 1
    end)

    assert.is_true(subscription:Disconnect())
    assert.is_false(subscription:Disconnect())
    TestEnv.EnterCombat()

    assert.are.equal(0, starts)
  end)

  it("isolates a failing subscriber and re-raises the first error", function()
    local first = loadedAddon("FirstAddon")
    local second = loadedAddon("SecondAddon")
    local delivered = {}
    first:OnCombatStart(function()
      delivered[#delivered + 1] = "first-a"
      error(false)
    end)
    first:OnCombatStart(function()
      delivered[#delivered + 1] = "first-b"
    end)
    second:OnCombatStart(function()
      delivered[#delivered + 1] = "second"
    end)

    TestEnv.EnterCombat()

    assert.are.same({ "first-a", "first-b", "second" }, delivered)
    assert.is_false(takeSingleReportedError())
    assert.is_true(LifecycleKit:IsInCombat())
  end)

  it("disconnects combat subscriptions at shutdown", function()
    local life = loadedAddon("MyAddon")
    local startSubscription = life:OnCombatStart(function() end)
    local endSubscription = life:OnCombatEnd(function() end)

    TestEnv.Logout()

    assert.is_false(startSubscription:IsConnected())
    assert.is_false(endSubscription:IsConnected())
    assert.is_false(life:OnCombatStart(function() end):IsConnected())
  end)

  it("allocates nothing per combat once subscribed #allocation", function()
    local life = loadedAddon("MyAddon")
    life:OnCombatStart(function() end)
    life:OnCombatEnd(function() end)
    TestEnv.EnterCombat()
    TestEnv.LeaveCombat()

    collectgarbage("collect")
    collectgarbage("stop")
    local before = collectgarbage("count")
    for _ = 1, 500 do
      TestEnv.EnterCombat()
      TestEnv.LeaveCombat()
    end
    local allocated = collectgarbage("count") - before
    collectgarbage("restart")

    assert.is_true(allocated < 1, "combat cycles allocated " .. allocated .. " KiB")
  end)
end)
