local TestEnv = require("CommKitTestEnv")

-- An addon scope closes at logout whenever the framework can observe logout,
-- whichever revisions are paired (docs/API.md, "At logout"). `ForAddon`
-- decides who closes it:
--
--   (a) a LifecycleKit whose `CLOSES_ADDON_SCOPES` names "commKit" closes it
--       after the addon's shutdown callbacks;
--   (b) an older LifecycleKit: CommKit's own `OnShutdown` subscription does;
--   (c) no LifecycleKit: CommKit's `PLAYER_LOGOUT` watcher does. EventKit is a
--       required dependency, so the case without any observer does not arise.
--
-- The LifecycleKit on `LUA_PATH` is made to announce the field, or not, with
-- `TestEnv.SetClosesAddonScopes`. An `OnShutdown` callback subscribed after
-- `ForAddon` tells (a) from (b): under (a) it still sees the scope open, under
-- (b) CommKit's earlier subscription has already closed it.

local PREFIX = "CKLogout"

---Register the test prefix in `scope` and return the connection.
---@param scope table
---@return table connection
local function register(scope)
  return assert(scope:Register(PREFIX, function() end))
end

---Subscribe to the addon's shutdown after CommKit did, and report whether the
---scope was still open when the callback ran.
---@param LifecycleKit table
---@param scope table
---@return table seen `seen.open` is `true` or `false` once shutdown ran
local function watchShutdown(LifecycleKit, scope)
  local seen = {}
  LifecycleKit:ForAddon("MyAddon"):OnShutdown(function()
    seen.open = not scope:IsClosed()
  end)
  return seen
end

---Make an addon scope look as revision 1 built it: no logout fields, and no
---package-level watcher, whose connection is disconnected and forgotten.
---@param CommKit table
---@param scope table
local function stripToRevisionOne(CommKit, scope)
  local kitScopes = rawget(rawget(CommKit, "_state"), "kitScopes")
  rawget(kitScopes, "logout"):Disconnect()
  rawset(kitScopes, "logout", nil)
  rawset(scope, "_schema", 1)
  rawset(scope, "_logoutCloser", nil)
  rawset(scope, "_shutdownSubscription", nil)
end

describe("CommKit logout close", function()
  after_each(TestEnv.Reset)

  describe("(a) LifecycleKit names commKit in CLOSES_ADDON_SCOPES", function()
    it("leaves the scope to LifecycleKit, open during the shutdown callbacks", function()
      local CommKit, loaded = TestEnv.Load({ lifecycleKit = true })
      local scope = CommKit:ForAddon("MyAddon")
      local connection = register(scope)
      local seen = watchShutdown(loaded.LifecycleKit, scope)

      assert.are.equal("lifecycleKit", rawget(scope, "_logoutCloser"))
      assert.is_false(rawget(scope, "_shutdownSubscription"))
      TestEnv.Logout()

      assert.is_true(seen.open)
      assert.is_true(scope:IsClosed())
      assert.is_false(connection:IsConnected())
      assert.are.same({}, TestEnv.TakeReportedErrors())
    end)

    it("closes the scope of an addon without its own LifecycleKit instance", function()
      local CommKit, loaded = TestEnv.Load({ lifecycleKit = true })
      local scope = CommKit:ForAddon("MyAddon")

      TestEnv.Logout()

      assert.is_true(loaded.LifecycleKit:ForAddon("MyAddon"):IsShutdown())
      assert.is_true(scope:IsClosed())
    end)
  end)

  describe("(b) an older LifecycleKit", function()
    it("subscribes to the addon's OnShutdown and closes the scope there", function()
      local CommKit, loaded = TestEnv.Load({ lifecycleKit = false })
      local scope = CommKit:ForAddon("MyAddon")
      local connection = register(scope)
      local subscription = rawget(scope, "_shutdownSubscription")
      local seen = watchShutdown(loaded.LifecycleKit, scope)

      assert.is_true(subscription:IsConnected())
      TestEnv.Logout()

      assert.is_false(seen.open)
      assert.is_true(scope:IsClosed())
      assert.is_false(connection:IsConnected())
      assert.is_false(subscription:IsConnected())
      assert.are.same({}, TestEnv.TakeReportedErrors())
    end)

    it("treats a list that does not name commKit as an older LifecycleKit", function()
      local CommKit, loaded = TestEnv.Load({ lifecycleKit = { timerKit = true } })
      local scope = CommKit:ForAddon("MyAddon")
      local seen = watchShutdown(loaded.LifecycleKit, scope)

      TestEnv.Logout()

      assert.is_false(seen.open)
      assert.is_true(scope:IsClosed())
    end)

    it("subscribes once per addon however often ForAddon is called", function()
      local CommKit = TestEnv.Load({ lifecycleKit = false })
      local scope = CommKit:ForAddon("MyAddon")
      local subscription = rawget(scope, "_shutdownSubscription")

      CommKit:ForAddon("MyAddon")
      CommKit:ForAddon("MyAddon")

      assert.are.equal(subscription, rawget(scope, "_shutdownSubscription"))
    end)

    it("disconnects the subscription when CloseAddonScopes closes the scope first", function()
      local CommKit = TestEnv.Load({ lifecycleKit = false })
      local scope = CommKit:ForAddon("MyAddon")
      local subscription = rawget(scope, "_shutdownSubscription")

      assert.is_true(CommKit:CloseAddonScopes("MyAddon"))

      assert.is_false(subscription:IsConnected())
      assert.is_false(rawget(scope, "_shutdownSubscription"))
      TestEnv.Logout()
      assert.are.same({}, TestEnv.TakeReportedErrors())
    end)

    it("disconnects the subscription when the scope's own Close runs first", function()
      local CommKit = TestEnv.Load({ lifecycleKit = false })
      local scope = CommKit:ForAddon("MyAddon")
      local subscription = rawget(scope, "_shutdownSubscription")

      assert.is_true(scope:Close())

      assert.is_false(subscription:IsConnected())
    end)
  end)

  describe("(c) no LifecycleKit", function()
    it("closes every addon scope on PLAYER_LOGOUT through one watcher", function()
      local CommKit = TestEnv.NewPackage()
      local first = CommKit:ForAddon("MyAddon")
      local second = CommKit:ForAddon("OtherAddon")
      local manual = CommKit:CreateScope()
      local connection = register(first)
      local manualConnection = register(manual)

      local kitScopes = rawget(rawget(CommKit, "_state"), "kitScopes")
      local watcher = rawget(kitScopes, "logout")
      assert.is_true(watcher:IsConnected())
      assert.are.equal("playerLogout", rawget(first, "_logoutCloser"))

      TestEnv.Logout()

      assert.is_true(first:IsClosed())
      assert.is_true(second:IsClosed())
      assert.is_false(connection:IsConnected())
      assert.is_false(manual:IsClosed())
      assert.is_true(manualConnection:IsConnected())
      assert.are.same({}, TestEnv.TakeReportedErrors())
    end)

    it("is always arranged, because EventKit is required", function()
      local CommKit = TestEnv.NewPackage()
      local scope = CommKit:ForAddon("MyAddon")
      assert.are.equal("playerLogout", rawget(scope, "_logoutCloser"))
    end)
  end)

  describe("re-evaluation", function()
    it("moves a scope from the watcher to an older LifecycleKit loaded later", function()
      local CommKit = TestEnv.NewPackage()
      local scope = CommKit:ForAddon("MyAddon")
      assert.are.equal("playerLogout", rawget(scope, "_logoutCloser"))

      local LifecycleKit = TestEnv.LoadLifecycleKit(false)
      assert.are.equal(scope, CommKit:ForAddon("MyAddon"))
      assert.are.equal("onShutdown", rawget(scope, "_logoutCloser"))
      local seen = watchShutdown(LifecycleKit, scope)
      TestEnv.Logout()

      assert.is_false(seen.open)
      assert.is_true(scope:IsClosed())
      assert.are.same({}, TestEnv.TakeReportedErrors())
    end)

    it("moves a scope from the watcher to a LifecycleKit that closes it", function()
      local CommKit = TestEnv.NewPackage()
      local scope = CommKit:ForAddon("MyAddon")

      local LifecycleKit = TestEnv.LoadLifecycleKit(true)
      CommKit:ForAddon("MyAddon")
      local seen = watchShutdown(LifecycleKit, scope)
      TestEnv.Logout()

      -- The watcher connected first and runs first, but leaves the scope
      -- to LifecycleKit, whose shutdown callbacks still see it open.
      assert.is_true(seen.open)
      assert.is_true(scope:IsClosed())
      assert.are.same({}, TestEnv.TakeReportedErrors())
    end)

    it("reports a failure in another Kit and asks again on the next ForAddon", function()
      local CommKit, loaded = TestEnv.Load({ lifecycleKit = false })
      local LifecycleKit = loaded.LifecycleKit
      local forAddon = rawget(LifecycleKit, "ForAddon")
      rawset(LifecycleKit, "ForAddon", function()
        error("lifecycle failure", 0)
      end)

      local scope = CommKit:ForAddon("MyAddon")
      assert.are.same({ { value = "lifecycle failure" } }, TestEnv.TakeReportedErrors())
      assert.are.equal("none", rawget(scope, "_logoutCloser"))

      rawset(LifecycleKit, "ForAddon", forAddon)
      CommKit:ForAddon("MyAddon")
      assert.are.equal("onShutdown", rawget(scope, "_logoutCloser"))
    end)
  end)

  describe("upgrades", function()
    it("arranges the PLAYER_LOGOUT watcher for addon scopes a revision 1 layout carried", function()
      local CommKit = TestEnv.NewPackage()
      local scope = CommKit:ForAddon("MyAddon")
      local connection = register(scope)
      stripToRevisionOne(CommKit, scope)

      TestEnv.LoadRevision(CommKit.REVISION + 1)

      assert.are.equal(2, rawget(scope, "_schema"))
      assert.are.equal("playerLogout", rawget(scope, "_logoutCloser"))
      TestEnv.Logout()
      assert.is_true(scope:IsClosed())
      assert.is_false(connection:IsConnected())
      assert.are.same({}, TestEnv.TakeReportedErrors())
    end)

    it(
      "subscribes to an older LifecycleKit for addon scopes a revision 1 layout carried",
      function()
        local CommKit = TestEnv.NewPackage()
        local scope = CommKit:ForAddon("MyAddon")
        stripToRevisionOne(CommKit, scope)
        local LifecycleKit = TestEnv.LoadLifecycleKit(false)

        TestEnv.LoadRevision(CommKit.REVISION + 1)

        assert.are.equal("onShutdown", rawget(scope, "_logoutCloser"))
        local seen = watchShutdown(LifecycleKit, scope)
        TestEnv.Logout()
        assert.is_false(seen.open)
        assert.is_true(scope:IsClosed())
      end
    )

    it("keeps the PLAYER_LOGOUT watcher across an upgrade without connecting another", function()
      local CommKit = TestEnv.NewPackage()
      local scope = CommKit:ForAddon("MyAddon")
      local kitScopes = rawget(rawget(CommKit, "_state"), "kitScopes")
      local watcher = rawget(kitScopes, "logout")
      local eventScope = rawget(kitScopes, "event")
      local connectionsBefore = eventScope:GetActiveCount()

      TestEnv.LoadRevision(CommKit.REVISION + 1)
      CommKit:ForAddon("MyAddon")
      CommKit:ForAddon("OtherAddon")

      assert.are.equal(watcher, rawget(kitScopes, "logout"))
      assert.are.equal(connectionsBefore, eventScope:GetActiveCount())
      TestEnv.Logout()
      assert.is_true(scope:IsClosed())
      assert.is_true(CommKit:ForAddon("OtherAddon"):IsClosed())
      assert.are.same({}, TestEnv.TakeReportedErrors())
    end)

    it("keeps the OnShutdown subscription across an upgrade without subscribing again", function()
      local CommKit, loaded = TestEnv.Load({ lifecycleKit = false })
      local scope = CommKit:ForAddon("MyAddon")
      local subscription = rawget(scope, "_shutdownSubscription")

      TestEnv.LoadRevision(CommKit.REVISION + 1)
      CommKit:ForAddon("MyAddon")

      assert.are.equal(subscription, rawget(scope, "_shutdownSubscription"))
      assert.is_true(subscription:IsConnected())
      local seen = watchShutdown(loaded.LifecycleKit, scope)
      TestEnv.Logout()
      assert.is_false(seen.open)
      assert.is_true(scope:IsClosed())
      assert.are.same({}, TestEnv.TakeReportedErrors())
    end)
  end)
end)
