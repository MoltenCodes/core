local TestEnv = require("LifecycleKitTestEnv")

local expectErrorContaining = TestEnv.expectErrorContaining

---The implementation revision `src/LifecycleKit.lua` carries; `Manifest_spec.lua`
---pins the same number against `package.manifest.json`.
local CURRENT_REVISION = 19

-- Instance prototypes that model other revisions' published surfaces. Only the
-- presence of each method matters to the bootstrap checks under test.
local REVISION_6_METHODS = {
  "GetAddonName",
  "GetState",
  "IsLoaded",
  "IsReady",
  "IsShutdown",
  "OnLoaded",
  "OnReady",
  "OnShutdown",
}

local REVISION_7_METHODS = {
  "IsHalted",
  "GetHaltReason",
  "OnHalted",
  "Halt",
  "DependsOn",
  "OnDependencyHalted",
  "WhenOutOfCombat",
  "OnCombatStart",
  "OnCombatEnd",
  "SetCombatQueueLimit",
  "GetCombatQueueLimit",
}

local function addMethods(prototype, methodNames)
  for index = 1, #methodNames do
    prototype[methodNames[index]] = function() end
  end
  return prototype
end

local function newRevision6InstancePrototype()
  return addMethods({}, REVISION_6_METHODS)
end

local function newInstancePrototype()
  return addMethods(newRevision6InstancePrototype(), REVISION_7_METHODS)
end

describe("LifecycleKit package bootstrap", function()
  after_each(TestEnv.Reset)

  it("requires Registry to load first", function()
    TestEnv.Reset()
    TestEnv.InstallWowApi()
    expectErrorContaining("requires Registry API 2", function()
      require("LifecycleKit")
    end)
  end)

  it("requires EventKit to load first", function()
    TestEnv.Reset()
    TestEnv.InstallWowApi()
    require("Registry")
    expectErrorContaining("requires EventKit API 1", function()
      require("LifecycleKit")
    end)
  end)

  it("registers LifecycleKit API 1 at the current revision", function()
    local LifecycleKit, Registry = TestEnv.NewPackage()
    local selected, revision = Registry:Get("lifecycleKit", 1)
    assert.are.equal(LifecycleKit, selected)
    assert.are.equal(CURRENT_REVISION, revision)
    assert.are.equal(1, LifecycleKit.API)
    assert.are.equal(CURRENT_REVISION, LifecycleKit.REVISION)
  end)

  it("reuses facade and addon instances across duplicate embedding", function()
    local first = TestEnv.NewPackage()
    local instance = first:ForAddon("MyAddon")
    local second = TestEnv.ReloadPackage()
    assert.are.equal(first, second)
    assert.are.equal(instance, second:ForAddon("MyAddon"))
  end)

  it("preserves pending phase subscriptions across duplicate embedding", function()
    local first = TestEnv.NewPackage()
    local life = first:ForAddon("MyAddon")
    local calls = 0
    life:OnLoaded(function()
      calls = calls + 1
    end)

    local second = TestEnv.ReloadPackage()
    TestEnv.LoadAddon("MyAddon")
    assert.are.equal(first, second)
    assert.are.equal(1, calls)
  end)

  it("does not downgrade a newer compatible embedded revision", function()
    TestEnv.Reset()
    TestEnv.InstallWowApi()
    local Registry = require("Registry")
    require("SignalKit")
    require("EventKit")

    local future = Registry:Register("lifecycleKit", 1, CURRENT_REVISION + 1)
    future.API = 1
    future.REVISION = CURRENT_REVISION + 1
    future.Instance = newInstancePrototype()
    future.Subscription = { Disconnect = function() end, IsConnected = function() end }
    future.DeferredCall = { Cancel = function() end, IsPending = function() end }
    future.ForAddon = function() end
    future.IsInCombat = function() end
    future.UNBOUNDED = {}
    future.SetLimits = function() end
    future.GetLimits = function() end
    future.CLOSES_ADDON_SCOPES = {}

    local loaded = require("LifecycleKit")
    local selected, revision = Registry:Get("lifecycleKit", 1)
    assert.are.equal(future, loaded)
    assert.are.equal(future, selected)
    assert.are.equal(CURRENT_REVISION + 1, revision)
  end)

  it("refuses a newer revision that lacks CLOSES_ADDON_SCOPES", function()
    TestEnv.Reset()
    TestEnv.InstallWowApi()
    local Registry = require("Registry")
    require("SignalKit")
    require("EventKit")

    -- The capability field is part of the public surface from revision
    -- 13 on: the scope-owning Kits read it to decide who closes their
    -- addon scopes at logout.
    local future = Registry:Register("lifecycleKit", 1, CURRENT_REVISION + 1)
    future.API = 1
    future.REVISION = CURRENT_REVISION + 1
    future.Instance = newInstancePrototype()
    future.Subscription = { Disconnect = function() end, IsConnected = function() end }
    future.DeferredCall = { Cancel = function() end, IsPending = function() end }
    future.ForAddon = function() end
    future.IsInCombat = function() end
    future.UNBOUNDED = {}
    future.SetLimits = function() end
    future.GetLimits = function() end

    expectErrorContaining("corrupted or incomplete", function()
      require("LifecycleKit")
    end)
  end)

  it("refuses a newer revision that lacks the combat gate surface", function()
    TestEnv.Reset()
    TestEnv.InstallWowApi()
    local Registry = require("Registry")
    require("SignalKit")
    require("EventKit")

    -- A revision 14 that publishes only the revision 6 surface is not a
    -- compatible successor: consumers of revision 7 and later would call
    -- methods it does not have.
    local future = Registry:Register("lifecycleKit", 1, CURRENT_REVISION + 1)
    future.API = 1
    future.REVISION = CURRENT_REVISION + 1
    future.Instance = newRevision6InstancePrototype()
    future.Subscription = { Disconnect = function() end, IsConnected = function() end }
    future.ForAddon = function() end

    expectErrorContaining("corrupted or incomplete", function()
      require("LifecycleKit")
    end)
  end)

  it("retries shared watcher setup after a same-revision bootstrap failure", function()
    local LifecycleKit, _, _, EventKit = TestEnv.NewPackage()
    local life = LifecycleKit:ForAddon("RetryAddon")
    TestEnv.LoadAddon("RetryAddon")

    local state = LifecycleKit._state
    local loginWatcher = state.globalWatchers.playerLogin
    assert.is_not_nil(loginWatcher)
    loginWatcher:Disconnect()
    state.globalWatchers.playerLogin = nil

    local originalOnce = EventKit.Once
    EventKit.Once = function()
      error("synthetic watcher failure")
    end
    package.loaded["LifecycleKit"] = nil
    expectErrorContaining("synthetic watcher failure", function()
      require("LifecycleKit")
    end)
    EventKit.Once = originalOnce

    package.loaded["LifecycleKit"] = nil
    local recovered = require("LifecycleKit")
    assert.are.equal(LifecycleKit, recovered)

    TestEnv.Login()
    assert.is_true(life:IsReady())
  end)

  it("catches up loaded instances after a missed login watcher", function()
    local LifecycleKit = TestEnv.NewPackage()
    local life = LifecycleKit:ForAddon("CatchUpAddon")
    TestEnv.LoadAddon("CatchUpAddon")

    local state = LifecycleKit._state
    local loginWatcher = state.globalWatchers.playerLogin
    assert.is_not_nil(loginWatcher)
    loginWatcher:Disconnect()
    state.globalWatchers.playerLogin = nil

    TestEnv.Login()
    assert.is_false(life:IsReady())

    package.loaded["LifecycleKit"] = nil
    local recovered = require("LifecycleKit")
    assert.are.equal(LifecycleKit, recovered)
    assert.is_true(life:IsReady())
  end)

  it("rejects corrupted current-revision state", function()
    local LifecycleKit = TestEnv.NewPackage()
    LifecycleKit._state = nil
    package.loaded["LifecycleKit"] = nil
    expectErrorContaining("corrupted or incomplete", function()
      require("LifecycleKit")
    end)
  end)

  it("upgrades the previous revision in place, keeping facade, state and instances", function()
    TestEnv.Reset()
    TestEnv.InstallWowApi()
    require("Registry")
    require("SignalKit")
    require("EventKit")

    local legacy = TestEnv.LoadSourceAtRevision(CURRENT_REVISION - 1)
    local legacyState = legacy._state
    legacy:SetLimits({ maxDependencies = 5 })
    local instance = legacy:ForAddon("MyAddon")
    local shutdowns = 0
    instance:OnShutdown(function()
      shutdowns = shutdowns + 1
    end)

    local upgraded = require("LifecycleKit")

    assert.are.equal(legacy, upgraded)
    assert.are.equal(CURRENT_REVISION, upgraded.REVISION)
    assert.are.equal(legacyState, upgraded._state)
    assert.are.equal(instance, upgraded:ForAddon("MyAddon"))
    assert.are.equal(5, upgraded:GetLimits().maxDependencies)
    -- Revision 17 names a table limit key by its type, never by `__tostring`.
    local key = setmetatable({}, {
      __tostring = function()
        error("foreign __tostring ran", 0)
      end,
    })
    TestEnv.expectErrorContaining(
      "LifecycleKit:SetLimits limits.<table> is not a recognised limit",
      function()
        upgraded:SetLimits({ [key] = 1 })
      end
    )
    assert.are.equal(5, upgraded:GetLimits().maxDependencies)
    TestEnv.Logout()
    assert.are.equal(1, shutdowns)
  end)

  it("refuses state older than revision 18's schema", function()
    TestEnv.Reset()
    TestEnv.InstallWowApi()
    local Registry = require("Registry")
    require("SignalKit")
    require("EventKit")

    -- The upgrade floor: schema 2 (revisions 4 to 6) is no longer migrated.
    local old = Registry:Register("lifecycleKit", 1, 6)
    old.API = 1
    old.REVISION = 6
    old.Instance = newRevision6InstancePrototype()
    old.Subscription = { Disconnect = function() end, IsConnected = function() end }
    old.ForAddon = function() end
    old._state = {
      schema = 2,
      addons = {},
      globalWatchers = {},
      loginSeen = false,
      shutdownSeen = false,
    }

    expectErrorContaining("corrupted or incomplete", function()
      require("LifecycleKit")
    end)
  end)

  it("repairs missing combat watchers and reconciles the combat state", function()
    local LifecycleKit = TestEnv.NewPackage()
    local life = LifecycleKit:ForAddon("MyAddon")
    TestEnv.LoadAddon("MyAddon")
    local starts = 0
    life:OnCombatStart(function()
      starts = starts + 1
    end)

    local watchers = LifecycleKit._state.globalWatchers
    watchers.combatStart:Disconnect()
    watchers.combatStart = nil
    TestEnv.SetCombatLockdown(true)

    package.loaded["LifecycleKit"] = nil
    assert.are.equal(LifecycleKit, require("LifecycleKit"))

    assert.is_true(LifecycleKit:IsInCombat())
    assert.are.equal(1, starts)
    TestEnv.LeaveCombat()
    assert.is_false(LifecycleKit:IsInCombat())
  end)

  ---Load a package whose login and combat watchers missed `PLAYER_LOGIN` and
  ---the start of combat, with one loaded addon whose `OnReady` records what
  ---`IsInCombat()` answers and, when `readyRaises` is set, then raises.
  local function packageThatMissedLoginInCombat(readyRaises)
    local LifecycleKit = TestEnv.NewPackage()
    local life = LifecycleKit:ForAddon("MyAddon")
    TestEnv.LoadAddon("MyAddon")
    local seen = {}
    life:OnReady(function()
      seen.inCombat = LifecycleKit:IsInCombat()
      if readyRaises then
        error("ready failed", 0)
      end
    end)

    local watchers = LifecycleKit._state.globalWatchers
    for _, key in ipairs({ "playerLogin", "combatStart", "combatEnd" }) do
      watchers[key]:Disconnect()
      watchers[key] = nil
    end
    TestEnv.SetCombatLockdown(true)
    TestEnv.Login()
    return LifecycleKit, life, seen
  end

  it("reconciles combat before a bootstrap catch-up runs OnReady", function()
    local LifecycleKit, life, seen = packageThatMissedLoginInCombat(false)
    assert.is_false(life:IsReady())

    package.loaded["LifecycleKit"] = nil
    assert.are.equal(LifecycleKit, require("LifecycleKit"))

    assert.is_true(life:IsReady())
    assert.is_true(seen.inCombat)
    assert.is_true(LifecycleKit:IsInCombat())
  end)

  it("reconciles combat at bootstrap when a catch-up OnReady raises", function()
    local LifecycleKit, life, seen = packageThatMissedLoginInCombat(true)

    package.loaded["LifecycleKit"] = nil
    expectErrorContaining("ready failed", function()
      require("LifecycleKit")
    end)

    assert.is_true(life:IsReady())
    assert.is_true(seen.inCombat)
    assert.is_true(LifecycleKit:IsInCombat())
  end)
end)
