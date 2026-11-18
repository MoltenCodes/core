local TestEnv = require("LifecycleKitTestEnv")

-- The in-place upgrade from revision 18, the upgrade floor (docs/API.md,
-- "Embedded bootstrap recovery"). `TestEnv.LoadRevision18` runs a byte copy of
-- revision 18's file, as an addon embedding it would, before this revision's
-- core and parts load over it.

---Load Registry, SignalKit and EventKit, then revision 18.
---@return table LifecycleKit
---@return table SignalKit
local function loadRevision18()
  TestEnv.Reset()
  TestEnv.InstallWowApi()
  require("Registry")
  local SignalKit = require("SignalKit")
  require("EventKit")
  return TestEnv.LoadRevision18(), SignalKit
end

---Load this revision's core over what is there, and optionally the parts.
---@param withParts boolean
---@return table LifecycleKit
local function upgrade(withParts)
  package.loaded["LifecycleKit"] = nil
  local LifecycleKit = require("LifecycleKit")
  if withParts then
    TestEnv.LoadParts()
  end
  return LifecycleKit
end

describe("LifecycleKit upgrade from revision 18", function()
  after_each(TestEnv.Reset)

  it("keeps the facade, the state, the limits and the instances", function()
    local old = loadRevision18()
    local state = rawget(old, "_state")
    old:SetLimits({ maxDependencies = 5 })
    local life = old:ForAddon("MyAddon")

    local upgraded = upgrade(true)

    assert.are.equal(old, upgraded)
    assert.are.equal(19, upgraded.REVISION)
    assert.are.equal(state, rawget(upgraded, "_state"))
    assert.are.equal(4, state.schema)
    assert.are.equal(life, upgraded:ForAddon("MyAddon"))
    assert.are.equal(5, upgraded:GetLimits().maxDependencies)
    assert.is_nil(rawget(life, "_combatCaptures"))
  end)

  it("delivers revision 18's pending phase subscriptions before new ones", function()
    local old = loadRevision18()
    local life = old:ForAddon("MyAddon")
    local seen = {}
    local oldReady = life:OnReady(function()
      seen[#seen + 1] = "old ready"
    end)
    life:OnShutdown(function()
      error("old shutdown failed", 0)
    end)

    upgrade(true)
    life:OnReady(function()
      seen[#seen + 1] = "new ready"
    end)
    assert.is_true(oldReady:IsConnected())

    TestEnv.LoadAddon("MyAddon")
    TestEnv.Login()
    assert.are.same({ "old ready", "new ready" }, seen)
    assert.is_false(oldReady:IsConnected())

    TestEnv.Logout()
    local reported = TestEnv.TakeReportedErrors()
    assert.are.equal(1, #reported)
    assert.are.equal("old shutdown failed", reported[1].value)
    assert.are.equal("shutdown", life:GetState())
  end)

  it("answers Disconnect and IsConnected of a revision 18 subscription", function()
    local old = loadRevision18()
    local life = old:ForAddon("MyAddon")
    local calls = 0
    local subscription = life:OnLoaded(function()
      calls = calls + 1
    end)

    upgrade(true)
    assert.is_true(subscription:IsConnected())
    assert.is_true(subscription:Disconnect())
    assert.is_false(subscription:Disconnect())
    TestEnv.LoadAddon("MyAddon")
    assert.are.equal(0, calls)
  end)

  it("keeps revision 18's combat notices, queued calls and dependencies working", function()
    local old = loadRevision18()
    local life = old:ForAddon("MyAddon")
    local other = old:ForAddon("Other")
    TestEnv.LoadAddon("MyAddon")
    local seen = {}
    life:OnCombatStart(function()
      seen[#seen + 1] = "start"
    end)
    life:DependsOn("Other")
    life:OnDependencyHalted(function(_, name, reason)
      seen[#seen + 1] = name .. ": " .. reason
    end)
    TestEnv.EnterCombat()
    local call = life:WhenOutOfCombat(function(_, ran)
      seen[#seen + 1] = "queued " .. tostring(ran)
    end)

    local upgraded = upgrade(true)
    assert.is_true(upgraded:IsInCombat())
    assert.is_true(call:IsPending())

    TestEnv.LeaveCombat()
    TestEnv.EnterCombat()
    other:Halt("broken")

    assert.are.same({ "start", "queued true", "start", "Other: broken" }, seen)
    assert.is_false(call:IsPending())
  end)

  it("keeps a halt revision 18 made", function()
    local old = loadRevision18()
    local life = old:ForAddon("MyAddon")
    life:Halt("broken")

    upgrade(true)

    assert.are.equal("halted", life:GetState())
    assert.are.equal("broken", life:GetHaltReason())
    local replayed
    life:OnHalted(function(_, reason)
      replayed = reason
    end)
    assert.are.equal("broken", replayed)
    assert.is_false(life:Halt("again"))
  end)

  it("replaces revision 18's watchers with its own", function()
    local old = loadRevision18()
    old:ForAddon("MyAddon")
    local watchers = rawget(old, "_state").globalWatchers
    local inherited = watchers.addonLoaded

    upgrade(true)

    assert.is_false(inherited:IsConnected())
    assert.is_not_nil(watchers.addonLoaded)
    assert.is_not_nil(watchers.combatStart)
  end)

  it("runs revision 18's queued calls on the next frame without the CombatGate part", function()
    local old = loadRevision18()
    local life = old:ForAddon("MyAddon")
    TestEnv.EnterCombat()
    local ran
    life:WhenOutOfCombat(function(_, wasRun)
      ran = wasRun
    end)

    upgrade(false)
    TestEnv.SetCombatLockdown(false)
    local timers = TestEnv.NativeTimers()
    TestEnv.FireNative(#timers)

    assert.is_true(ran)
    local reported = TestEnv.TakeReportedErrors()
    assert.are.equal(1, #reported)
    assert.is_truthy(tostring(reported[1].value):find("LifecycleKit-CombatGate.lua", 1, true))
  end)

  it("closes revision 18's queued calls at shutdown when combat lasts", function()
    local old = loadRevision18()
    local life = old:ForAddon("MyAddon")
    TestEnv.EnterCombat()
    local outcome
    life:WhenOutOfCombat(function(_, ran, reason)
      outcome = tostring(ran) .. " " .. tostring(reason)
    end)

    upgrade(false)
    local timers = TestEnv.NativeTimers()
    TestEnv.FireNative(#timers)
    assert.is_nil(outcome)
    TestEnv.TakeReportedErrors()

    TestEnv.Logout()
    assert.are.equal("false shutdown", outcome)
  end)

  it("hands revision 18's halt members to the stubs without the Halt part", function()
    local old = loadRevision18()
    local life = old:ForAddon("MyAddon")

    upgrade(false)

    TestEnv.expectErrorContaining("LifecycleKit-Halt.lua", function()
      life:Halt("broken")
    end)
    assert.is_false(old:HasPart("Halt"))
  end)
end)

describe("LifecycleKit without SignalKit", function()
  after_each(TestEnv.Reset)

  -- EventKit up to revision 22 requires SignalKit, so the chain loads it; the
  -- Registry is made to deny it while LifecycleKit loads and runs, which is
  -- what LifecycleKit sees in a session that never embedded SignalKit.

  ---Make `Registry:Get` and `Registry:Find` answer nothing for SignalKit.
  ---@param Registry table
  ---@return fun() restore
  local function hideSignalKit(Registry)
    local get, find = rawget(Registry, "Get"), rawget(Registry, "Find")
    rawset(Registry, "Get", function(self, packageName, ...)
      if packageName == "signalKit" then
        return nil
      end
      return get(self, packageName, ...)
    end)
    rawset(Registry, "Find", function(self, packageName, ...)
      if packageName == "signalKit" then
        return nil, "signalKit is not loaded"
      end
      return find(self, packageName, ...)
    end)
    return function()
      rawset(Registry, "Get", get)
      rawset(Registry, "Find", find)
    end
  end

  it("loads, replays and shuts down", function()
    TestEnv.Reset()
    TestEnv.InstallWowApi()
    local Registry = require("Registry")
    require("SignalKit")
    require("EventKit")
    local restore = hideSignalKit(Registry)

    local LifecycleKit = require("LifecycleKit")
    TestEnv.LoadParts()
    local life = LifecycleKit:ForAddon("MyAddon")
    local seen = {}
    life:OnLoaded(function()
      seen[#seen + 1] = "loaded"
    end)
    TestEnv.LoadAddon("MyAddon")
    TestEnv.Login()
    life:OnReady(function()
      seen[#seen + 1] = "ready replayed"
    end)
    TestEnv.Logout()
    restore()

    assert.are.same({ "loaded", "ready replayed" }, seen)
    assert.is_true(life:IsShutdown())
    assert.are.same({}, TestEnv.TakeReportedErrors())
  end)

  it("closes the addon bus of a SignalKit found later", function()
    TestEnv.Reset()
    TestEnv.InstallWowApi()
    local Registry = require("Registry")
    local SignalKit = require("SignalKit")
    require("EventKit")
    local restore = hideSignalKit(Registry)
    local LifecycleKit = require("LifecycleKit")
    LifecycleKit:ForAddon("MyAddon")
    restore()

    local subscription = SignalKit:ForAddon("MyAddon"):Subscribe("Anything", function() end)
    TestEnv.Logout()

    assert.is_false(subscription:IsConnected())
  end)
end)
