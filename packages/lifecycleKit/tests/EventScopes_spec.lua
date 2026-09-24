local TestEnv = require("LifecycleKitTestEnv")

-- Shutdown closes the addon's canonical EventKit scope. EventKit loads before
-- LifecycleKit and never sees PLAYER_LOGOUT, so LifecycleKit performs the second
-- half of the two-step that `EventKit:ForAddon` documents.
describe("LifecycleKit event scopes", function()
  local LifecycleKit, EventKit
  before_each(function()
    LifecycleKit, _, _, EventKit = TestEnv.NewPackage()
  end)
  after_each(TestEnv.Reset)

  it("closes the addon's EventKit scope when the addon reaches shutdown", function()
    local life = LifecycleKit:ForAddon("MyAddon")
    local scope = EventKit:ForAddon("MyAddon")
    local calls = 0
    scope:Connect("CHAT_MSG_SAY", function()
      calls = calls + 1
    end)
    TestEnv.LoadAddon("MyAddon")
    TestEnv.Login()
    TestEnv.Emit("CHAT_MSG_SAY")
    assert.are.equal(1, calls)

    TestEnv.Logout()

    assert.is_true(life:IsShutdown())
    assert.is_true(scope:IsClosed())
    assert.are.equal(0, scope:GetActiveCount())
    TestEnv.Emit("CHAT_MSG_SAY")
    assert.are.equal(1, calls)
  end)

  it("closes the scope's combat-log listeners with the rest of the scope", function()
    -- EventKit resolves the combat-log API when the first combat-log
    -- listener connects, so the host function is installed before that.
    local subEvent = nil
    -- The spec stands in for the World of Warcraft client, whose API only exists in the global table.
    -- selene: allow(global_usage)
    rawset(_G, "CombatLogGetCurrentEventInfo", function()
      return 1, subEvent
    end)
    local life = LifecycleKit:ForAddon("MyAddon")
    local scope = EventKit:ForAddon("MyAddon")
    local calls = 0
    local connection = scope:ConnectCombatLog("SPELL_DAMAGE", function()
      calls = calls + 1
    end)
    subEvent = "SPELL_DAMAGE"
    TestEnv.Emit("COMBAT_LOG_EVENT_UNFILTERED")

    TestEnv.Logout()
    TestEnv.Emit("COMBAT_LOG_EVENT_UNFILTERED")
    -- selene: allow(global_usage)
    rawset(_G, "CombatLogGetCurrentEventInfo", nil)

    assert.is_true(life:IsShutdown())
    assert.is_true(scope:IsClosed())
    assert.is_false(connection:IsConnected())
    assert.are.equal(1, calls)
  end)

  it("still delivers PLAYER_LOGOUT to a scope listener connected after LifecycleKit", function()
    -- LifecycleKit's logout watcher is connected by the first ForAddon, so
    -- it runs before this listener and closes the scope mid-dispatch. The
    -- listener must still receive the logout it is waiting for.
    local life = LifecycleKit:ForAddon("MyAddon")
    local scope = EventKit:ForAddon("MyAddon")
    local saves = 0
    scope:Connect("PLAYER_LOGOUT", function()
      saves = saves + 1
    end)

    TestEnv.Logout()

    assert.are.equal(1, saves)
    assert.is_true(life:IsShutdown())
    assert.is_true(scope:IsClosed())
    assert.are.equal(0, scope:GetActiveCount())
  end)

  it("runs shutdown callbacks before the scope is closed", function()
    local life = LifecycleKit:ForAddon("MyAddon")
    local scope = EventKit:ForAddon("MyAddon")
    scope:Connect("CHAT_MSG_SAY", function() end)
    local activeDuringShutdown
    life:OnShutdown(function()
      activeDuringShutdown = scope:GetActiveCount()
    end)

    TestEnv.Logout()

    assert.are.equal(1, activeDuringShutdown)
    assert.are.equal(0, scope:GetActiveCount())
  end)

  it("records no EventKit scope for an addon that never asked for one", function()
    LifecycleKit:ForAddon("MyAddon")
    TestEnv.Logout()

    -- `CloseAddonScopes` answered `false` and recorded nothing, as HookKit,
    -- CommandKit and CommKit do, so the addon-scope map does not grow with
    -- every lifecycle instance.
    assert.is_nil(rawget(rawget(EventKit, "_state").addonScopes, "MyAddon"))
    assert.are.same({}, TestEnv.TakeReportedErrors())
  end)

  it("shuts down unchanged against an EventKit without CloseAddonScopes", function()
    local life = LifecycleKit:ForAddon("MyAddon")
    local original = rawget(EventKit, "CloseAddonScopes")
    rawset(EventKit, "CloseAddonScopes", nil)

    TestEnv.Logout()

    rawset(EventKit, "CloseAddonScopes", original)
    assert.is_true(life:IsShutdown())
    assert.is_false(EventKit:ForAddon("MyAddon"):IsClosed())
  end)

  it("reports a scope-closing failure after every lifecycle has advanced", function()
    local first = LifecycleKit:ForAddon("FirstAddon")
    local second = LifecycleKit:ForAddon("SecondAddon")
    local secondScope = EventKit:ForAddon("SecondAddon")
    local original = rawget(EventKit, "CloseAddonScopes")
    rawset(EventKit, "CloseAddonScopes", function(_, addonName)
      if addonName == "FirstAddon" then
        error("scope teardown failed", 0)
      end
      return original(EventKit, addonName)
    end)

    TestEnv.Logout()

    rawset(EventKit, "CloseAddonScopes", original)
    local reported = TestEnv.TakeReportedErrors()
    assert.are.equal(1, #reported)
    assert.are.equal("scope teardown failed", reported[1].value)
    assert.is_true(first:IsShutdown())
    assert.is_true(second:IsShutdown())
    assert.is_true(secondScope:IsClosed())
  end)
end)
