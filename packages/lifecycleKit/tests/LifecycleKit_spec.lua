local TestEnv = require("LifecycleKitTestEnv")

describe("LifecycleKit", function()
  local LifecycleKit
  before_each(function()
    LifecycleKit = TestEnv.NewPackage()
  end)
  after_each(TestEnv.Reset)

  it("returns one stable instance per addon name", function()
    local first = LifecycleKit:ForAddon("MyAddon")
    local second = LifecycleKit:ForAddon("MyAddon")
    local other = LifecycleKit:ForAddon("OtherAddon")
    assert.are.equal(first, second)
    assert.are_not.equal(first, other)
  end)

  it("starts in loading state", function()
    local life = LifecycleKit:ForAddon("MyAddon")
    assert.are.equal("loading", life:GetState())
    assert.is_false(life:IsLoaded())
    assert.is_false(life:IsReady())
    assert.is_false(life:IsShutdown())
    assert.are.equal("MyAddon", life:GetAddonName())
  end)

  it("ignores ADDON_LOADED for other addons", function()
    local life = LifecycleKit:ForAddon("MyAddon")
    TestEnv.LoadAddon("OtherAddon")
    assert.are.equal("loading", life:GetState())
  end)

  it("moves to loaded for its own ADDON_LOADED", function()
    local life = LifecycleKit:ForAddon("MyAddon")
    TestEnv.LoadAddon("MyAddon")
    assert.are.equal("loaded", life:GetState())
    assert.is_true(life:IsLoaded())
    assert.is_false(life:IsReady())
  end)

  it("moves to ready after login", function()
    local life = LifecycleKit:ForAddon("MyAddon")
    TestEnv.LoadAddon("MyAddon")
    TestEnv.Login()
    assert.are.equal("ready", life:GetState())
    assert.is_true(life:IsLoaded())
    assert.is_true(life:IsReady())
  end)

  it("remembers login that occurs before addon loaded", function()
    local life = LifecycleKit:ForAddon("MyAddon")
    TestEnv.Login()
    assert.are.equal("loading", life:GetState())
    TestEnv.LoadAddon("MyAddon")
    assert.are.equal("ready", life:GetState())
  end)

  it("moves to shutdown on logout", function()
    local life = LifecycleKit:ForAddon("MyAddon")
    TestEnv.LoadAddon("MyAddon")
    TestEnv.Login()
    TestEnv.Logout()
    assert.are.equal("shutdown", life:GetState())
    assert.is_true(life:IsShutdown())
  end)

  it("matches addon names exactly, the way the host reports them", function()
    local life = LifecycleKit:ForAddon("MyAddon")
    local lowercase = LifecycleKit:ForAddon("myaddon")

    assert.are_not.equal(life, lowercase)

    TestEnv.LoadAddon("myaddon")

    assert.are.equal("loading", life:GetState())
    assert.are.equal("loaded", lowercase:GetState())
  end)

  it("creates an already-shutdown instance for a new addon name after logout", function()
    local life = LifecycleKit:ForAddon("MyAddon")
    TestEnv.LoadAddon("MyAddon")
    TestEnv.Login()
    TestEnv.Logout()
    assert.is_true(life:IsShutdown())

    local late = LifecycleKit:ForAddon("LateAddon")

    assert.are.equal("shutdown", late:GetState())
    assert.is_false(late:IsLoaded())
    assert.is_false(late:IsReady())

    local shutdownCalls = 0
    local subscription = late:OnShutdown(function()
      shutdownCalls = shutdownCalls + 1
    end)
    assert.are.equal(1, shutdownCalls)
    assert.is_false(subscription:IsConnected())
  end)

  it("installs no shared watchers once PLAYER_LOGOUT has been observed", function()
    LifecycleKit:ForAddon("MyAddon")
    TestEnv.LoadAddon("MyAddon")
    TestEnv.Login()
    TestEnv.Logout()

    local watchers = LifecycleKit._state.globalWatchers
    assert.is_nil(next(watchers))

    LifecycleKit:ForAddon("LateAddon")

    -- Every remaining transition is already decided, so creating another
    -- lifecycle must not re-register host events that can no longer fire.
    assert.is_nil(next(watchers))
  end)

  it("runs a full lifecycle again after a reload rebuilds the Lua state", function()
    local first = LifecycleKit:ForAddon("MyAddon")
    TestEnv.LoadAddon("MyAddon")
    TestEnv.Login()
    assert.are.equal("ready", first:GetState())

    -- A /reload tears the Lua state down and replays the whole session:
    -- fresh package tables, another ADDON_LOADED, another PLAYER_LOGIN.
    local reloaded = TestEnv.NewPackage()
    assert.are_not.equal(LifecycleKit, reloaded)

    local life = reloaded:ForAddon("MyAddon")
    assert.are.equal("loading", life:GetState())

    local seen = {}
    life:OnLoaded(function()
      seen[#seen + 1] = "loaded"
    end)
    life:OnReady(function()
      seen[#seen + 1] = "ready"
    end)

    TestEnv.LoadAddon("MyAddon")
    TestEnv.Login()

    assert.are.same({ "loaded", "ready" }, seen)
    assert.are.equal("ready", life:GetState())
  end)
end)
