local TestEnv = require("HookKitTestEnv")

describe("HookKit bootstrap", function()
  after_each(TestEnv.Reset)

  it("returns the same facade on duplicate embedded load", function()
    local HookKit = TestEnv.NewPackage()
    local scope = HookKit:CreateScope()
    local target = {
      Method = function()
        return "original"
      end,
    }
    scope:Hook(target, "Method", function() end)

    local reloaded = TestEnv.ReloadPackage()
    assert.are.equal(HookKit, reloaded)
    assert.is_true((scope:IsHooked(target, "Method")))
  end)

  it("publishes through Registry", function()
    local HookKit, Registry = TestEnv.NewPackage()
    local registered, revision = Registry:Get("hookKit", 1)
    assert.are.equal(HookKit, registered)
    assert.are.equal(HookKit.REVISION, revision)
    assert.are.equal(256, HookKit.MAX_HOOKS)
  end)

  it("loads and hooks with Registry alone", function()
    local HookKit, Registry = TestEnv.NewPackageWithoutClientKit()
    assert.are.equal(HookKit, Registry:Get("hookKit", 1))
    local calls = 0
    local target = {
      Method = function()
        return 1
      end,
    }
    HookKit:CreateScope():Hook(target, "Method", function()
      calls = calls + 1
    end)
    assert.are.equal(1, target.Method())
    assert.are.equal(1, calls)
  end)

  it("does not reinterpret private state owned by a newer compatible revision", function()
    local HookKit, Registry = TestEnv.NewPackage()
    local shippedRevision = HookKit.REVISION
    local upgraded, previous = Registry:Register("hookKit", 1, 99)
    assert.are.equal(HookKit, upgraded)
    assert.are.equal(shippedRevision, previous)

    rawset(HookKit, "REVISION", 99)
    rawset(HookKit, "_state", { schema = 999 })
    package.loaded["HookKit"] = nil

    local reloaded = require("HookKit")
    assert.are.equal(HookKit, reloaded)
    assert.are.equal(99, reloaded.REVISION)
  end)

  it("upgrades in place to the next revision and keeps every hook active and releasable", function()
    local HookKit = TestEnv.NewPackage()
    local scopePrototype = HookKit.Scope
    local calls = {}
    local function record(name)
      return function()
        calls[#calls + 1] = name
      end
    end

    local target = {
      Pre = function()
        return "pre"
      end,
      Raw = function()
        return "raw"
      end,
      Post = function()
        return "post"
      end,
    }
    local originalPre = target.Pre
    local frame = TestEnv.NewFrame()
    frame:SetScript("OnShow", record("previous OnShow"))

    local scope = HookKit:ForAddon("MyAddon")
    scope:Hook(target, "Pre", record("pre handler"))
    scope:RawHook(target, "Raw", function(original)
      calls[#calls + 1] = "raw handler"
      return original()
    end)
    scope:SecureHook(target, "Post", record("post handler"))
    scope:HookScript(frame, "OnShow", record("script handler"))
    scope:SecureHookScript(frame, "OnHide", record("secure script handler"))

    local nextRevision = HookKit.REVISION + 1
    local upgraded = TestEnv.LoadRevision(nextRevision)
    assert.are.equal(HookKit, upgraded)
    assert.are.equal(nextRevision, upgraded.REVISION)
    assert.are.equal(scopePrototype, upgraded.Scope)
    assert.are.equal(scope, upgraded:ForAddon("MyAddon"))
    assert.are.equal(5, scope:GetActiveCount())

    assert.are.equal("pre", target.Pre())
    assert.are.equal("raw", target.Raw())
    assert.are.equal("post", target.Post())
    TestEnv.RunScript(frame, "OnShow")
    TestEnv.RunScript(frame, "OnHide")
    assert.are.same({
      "pre handler",
      "raw handler",
      "post handler",
      "script handler",
      "previous OnShow",
      "secure script handler",
    }, calls)

    assert.is_true(scope:Unhook(target, "Pre"))
    assert.are.equal(originalPre, target.Pre)
    assert.is_true(upgraded:CloseAddonScopes("MyAddon"))
    assert.are.equal(0, scope:GetActiveCount())
  end)

  ---Load `previousRevision` in place, hook through it, then load the working
  ---file over it and prove the state, the addon scope and the hook survived.
  ---@param previousRevision integer
  local function assertUpgradesFrom(previousRevision)
    local workingRevision = TestEnv.NewPackage().REVISION
    TestEnv.Reset()
    TestEnv.InstallWowApi()
    TestEnv.InstallHookApi()
    require("Registry")
    local previous = TestEnv.LoadRevision(previousRevision)
    local state = previous._state
    local scope = previous:ForAddon("MyAddon", { maxHooks = 7 })
    local calls = 0
    local target = {
      Run = function()
        return "run"
      end,
    }
    scope:Hook(target, "Run", function()
      calls = calls + 1
    end)

    local current = require("HookKit")
    assert.are.equal(previous, current)
    assert.are.equal(workingRevision, current.REVISION)
    assert.are.equal(state, current._state)
    assert.are.equal(scope, current:ForAddon("MyAddon", { maxHooks = 7 }))
    assert.are.equal("run", target.Run())
    assert.are.equal(1, calls)
    assert.is_true(current:CloseAddonScopes("MyAddon"))
  end

  it("upgrades a revision 2 package in place to the working file", function()
    assertUpgradesFrom(2)
  end)

  it("upgrades the previous revision in place to the working file", function()
    assertUpgradesFrom(TestEnv.NewPackage().REVISION - 1)
  end)

  it(
    "releases a script hook of a revision 4 copy by the secret-handler rule after an upgrade",
    function()
      local secretHandler = nil
      TestEnv.Reset()
      TestEnv.InstallWowApi()
      TestEnv.InstallHookApi()
      TestEnv.SetGlobal("issecretvalue", function(value)
        return secretHandler ~= nil and rawequal(value, secretHandler)
      end)
      require("Registry")
      local previous = TestEnv.LoadRevision(4)
      local scope = previous:ForAddon("MyAddon")
      local frame = TestEnv.NewFrame()
      frame:SetScript("OnShow", function() end)
      assert.is_true(scope:HookScript(frame, "OnShow", function() end))
      local installed = frame:GetScript("OnShow")

      local current = require("HookKit")
      assert.are.equal(previous, current)
      assert.is_true(current.REVISION > 4)
      secretHandler = installed

      assert.is_true(scope:Unhook(frame, "OnShow"))
      assert.are.equal(installed, frame:GetScript("OnShow"))
    end
  )

  it("keeps the UNBOUNDED sentinel and every scope's limit across an upgrade", function()
    local HookKit = TestEnv.NewPackage()
    local sentinel = HookKit.UNBOUNDED
    local opened = HookKit:CreateScope({ maxHooks = sentinel })
    local raised = HookKit:ForAddon("MyAddon", { maxHooks = 300 })
    local default = HookKit:CreateScope()

    local nextRevision = HookKit.REVISION + 1
    local upgraded = TestEnv.LoadRevision(nextRevision)
    assert.are.equal(nextRevision, upgraded.REVISION)
    assert.are.equal(sentinel, upgraded.UNBOUNDED)
    assert.are.equal(sentinel, opened:GetMaxHooks())
    assert.are.equal(300, raised:GetMaxHooks())
    assert.are.equal(upgraded.MAX_HOOKS, default:GetMaxHooks())
    assert.are.equal(sentinel, upgraded:CreateScope({ maxHooks = sentinel }):GetMaxHooks())
  end)

  it("requires Registry", function()
    TestEnv.Reset()
    TestEnv.InstallWowApi()
    local ok, value = pcall(require, "HookKit")
    assert.is_false(ok)
    assert.is_true(tostring(value):find("Registry API 2", 1, true) ~= nil)
  end)

  it("refuses an incomplete facade left by an earlier failed load", function()
    TestEnv.Reset()
    TestEnv.InstallWowApi()
    local Registry = require("Registry")
    Registry:Register("hookKit", 1, 1)

    local ok, value = pcall(TestEnv.requireAfterFailedLoad, "HookKit")
    assert.is_false(ok)
    assert.is_true(tostring(value):find("MoltenCodes HookKit", 1, true) ~= nil)
  end)
end)
