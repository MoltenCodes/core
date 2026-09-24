local TestEnv = require("ModuleKitTestEnv")

-- ModuleKit resolves timerKit, schedulerKit and eventKit through
-- `Registry:Find` and asks each for `CreateScope()`. None of the three is a
-- runtime dependency, so this suite stands them in with recording fakes: the
-- two that are not on this package's test path are registered through
-- Registry, and the fixture's real EventKit facade is given a `CreateScope`,
-- which also covers the period before EventKit publishes its own.

---A fake Kit whose `CreateScope` hands out closable scopes and records them.
---@return table kit
---@return table[] created every scope handed out, in order
local function newScopedKit()
  local created = {}
  local kit = {}
  kit.CreateScope = function()
    local scope = { closed = false }
    scope.Close = function(self)
      self.closed = true
    end
    created[#created + 1] = scope
    return scope
  end
  return kit, created
end

---Publish a fake scoped Kit under `packageName` API 1.
---@param Registry Registry
---@param packageName string
---@return table[] created
local function registerScopedKit(Registry, packageName)
  local shared = Registry:Register(packageName, 1, 1)
  local kit, created = newScopedKit()
  rawset(shared, "CreateScope", kit.CreateScope)
  return created
end

describe("ModuleKit module scopes", function()
  local ModuleKit
  local timers
  local jobs
  local events

  before_each(function()
    local packageUnderTest, Registry, _, EventKit = TestEnv.NewPackage()
    ModuleKit = packageUnderTest
    timers = registerScopedKit(Registry, "timerKit")
    jobs = registerScopedKit(Registry, "schedulerKit")
    local eventKitStub
    eventKitStub, events = newScopedKit()
    rawset(EventKit, "CreateScope", eventKitStub.CreateScope)
  end)

  after_each(TestEnv.Reset)

  it("creates nothing for a module that never reads its scope", function()
    local module = ModuleKit:ForAddon("MyAddon"):CreateModule("Quiet")

    module:Enable()
    module:Disable()

    assert.are.equal(0, #timers)
    assert.are.equal(0, #jobs)
    assert.are.equal(0, #events)
  end)

  it("creates each scope lazily and hands back the same one while enabled", function()
    local module = ModuleKit:ForAddon("MyAddon"):CreateModule("Tracker")
    local seen = {}
    module.OnEnable = function(self)
      seen.timers = self.scope.Timers
    end

    module:Enable()

    assert.are.equal(1, #timers)
    assert.are.equal(seen.timers, module.scope.Timers)
    assert.are.equal(0, #jobs)
    assert.are.equal(0, #events)
    local eventScope = module.scope.Events
    local jobScope = module.scope.Jobs
    assert.are.equal(events[1], eventScope)
    assert.are.equal(jobs[1], jobScope)
  end)

  it("closes every scope on Disable and re-creates them fresh on Enable", function()
    local module = ModuleKit:ForAddon("MyAddon"):CreateModule("Tracker")
    module.OnEnable = function(self)
      -- Reading a field is what creates its scope.
      local scope = self.scope
      local _ = scope.Timers
      _ = scope.Events
      _ = scope.Jobs
    end

    module:Enable()
    module:Disable()

    assert.is_true(timers[1].closed)
    assert.is_true(events[1].closed)
    assert.is_true(jobs[1].closed)

    module:Enable()

    assert.are.equal(2, #timers)
    assert.is_false(timers[2].closed)
    assert.are.equal(timers[2], module.scope.Timers)
  end)

  it("closes scopes on DisableAll and on terminal shutdown", function()
    local addon = ModuleKit:ForAddon("MyAddon")
    local first = addon:CreateModule("First")
    local second = addon:CreateModule("Second")
    first.OnEnable = function(self)
      local _ = self.scope.Timers
    end
    second.OnEnable = first.OnEnable
    second.OnDisable = function()
      error("disable failed")
    end

    TestEnv.LoadAddon("MyAddon")
    TestEnv.Login()
    first:Disable()
    assert.is_true(timers[1].closed)

    first:Enable()
    assert.has_error(function()
      addon:DisableAll()
    end)
    assert.is_true(timers[3].closed)
    assert.is_false(timers[2].closed)

    -- `Second` failed to disable and is still enabled; shutdown releases
    -- its scope even though its `OnDisable` fails again.
    TestEnv.Logout()
    assert.is_true(timers[2].closed)
  end)

  it("releases what a failed OnEnable registered", function()
    local module = ModuleKit:ForAddon("MyAddon"):CreateModule("Broken")
    module.OnEnable = function(self)
      local _ = self.scope.Jobs
      error("enable failed")
    end

    assert.has_error(function()
      module:Enable()
    end)

    assert.are.equal(1, #jobs)
    assert.is_true(jobs[1].closed)
  end)

  it("reads nil for a Kit that is not loaded or has no owner scopes", function()
    -- A fresh load without the fakes the other cases register.
    local packageUnderTest, _, _, EventKit = TestEnv.NewPackage()
    ModuleKit = packageUnderTest
    rawset(EventKit, "CreateScope", nil)
    local module = ModuleKit:ForAddon("MyAddon"):CreateModule("Bare")
    local observed = {}
    module.OnEnable = function(self)
      observed.timers = self.scope.Timers
      observed.events = self.scope.Events
      observed.jobs = self.scope.Jobs
    end

    module:Enable()
    module:Disable()

    assert.are.same({}, observed)
  end)

  it("refuses a scope read outside the enable window, at the reader's line", function()
    local module = ModuleKit:ForAddon("MyAddon"):CreateModule("Early")

    local source = debug.getinfo(1, "S").short_src
    local line
    local ok, message = pcall(function()
      line = debug.getinfo(1, "l").currentline + 1
      return module.scope.Timers
    end)

    assert.is_false(ok)
    assert.are.equal(
      source
        .. ":"
        .. line
        .. ': ModuleKit module "Early" scope.Timers is available only while the module is enabling or enabled',
      message
    )
    assert.are.equal(0, #timers)
  end)
end)

-- EventKit is on this package's test path as a LifecycleKit dependency, so the
-- event half is also exercised against the real `EventKit:CreateScope()`.
describe("ModuleKit module scopes over the real EventKit", function()
  after_each(TestEnv.Reset)

  it("stops delivering a module's events once the module is disabled", function()
    local ModuleKit = TestEnv.NewPackage()
    local module = ModuleKit:ForAddon("MyAddon"):CreateModule("Listener")
    local deliveries = 0
    module.OnEnable = function(self)
      self.scope.Events:Connect("BAG_UPDATE", function()
        deliveries = deliveries + 1
      end)
    end

    module:Enable()
    TestEnv.Emit("BAG_UPDATE")
    module:Disable()
    TestEnv.Emit("BAG_UPDATE")

    assert.are.equal(1, deliveries)
    assert.is_nil(rawget(module.scope, "Events"))
  end)
end)

-- HookKit is an optional dependency declared in the manifest, so the real
-- `HookKit:CreateScope()` is on this package's test path.
describe("ModuleKit module scopes over the real HookKit", function()
  after_each(TestEnv.Reset)

  ---A table whose method the specs hook.
  local function newTarget()
    local target = { refreshes = 0 }
    function target.Refresh()
      target.refreshes = target.refreshes + 1
    end
    return target
  end

  it("undoes a module's hooks once the module is disabled", function()
    local ModuleKit = TestEnv.NewPackage()
    local module = ModuleKit:ForAddon("MyAddon"):CreateModule("Hooker")
    local target = newTarget()
    local original = target.Refresh
    local hooked = 0
    module.OnEnable = function(self)
      self.scope.Hooks:Hook(target, "Refresh", function()
        hooked = hooked + 1
      end)
    end

    module:Enable()
    target.Refresh()
    module:Disable()
    target.Refresh()

    assert.are.equal(1, hooked)
    assert.are.equal(2, target.refreshes)
    assert.are.equal(original, target.Refresh)
    assert.is_nil(rawget(module.scope, "Hooks"))
  end)

  it("hands a re-enabled module a fresh hook scope", function()
    local ModuleKit = TestEnv.NewPackage()
    local module = ModuleKit:ForAddon("MyAddon"):CreateModule("Hooker")
    local target = newTarget()
    local scopes = {}
    module.OnEnable = function(self)
      scopes[#scopes + 1] = self.scope.Hooks
      self.scope.Hooks:Hook(target, "Refresh", function() end)
    end

    module:Enable()
    module:Disable()
    module:Enable()

    assert.are.equal(2, #scopes)
    assert.is_true(scopes[1]:IsClosed())
    assert.is_false(scopes[2]:IsClosed())
    assert.is_true(scopes[2]:IsHooked(target, "Refresh"))
  end)

  it("undoes the hooks of a failed OnEnable and at shutdown", function()
    local ModuleKit = TestEnv.NewPackage()
    local addon = ModuleKit:ForAddon("MyAddon")
    local broken = addon:CreateModule("Broken")
    local steady = addon:CreateModule("Steady")
    local target = newTarget()
    local original = target.Refresh
    local brokenScope, steadyScope
    broken.OnEnable = function(self)
      brokenScope = self.scope.Hooks
      brokenScope:Hook(target, "Refresh", function() end)
      error("enable failed")
    end
    steady.OnEnable = function(self)
      steadyScope = self.scope.Hooks
      steadyScope:Hook(target, "Refresh", function() end)
    end

    assert.has_error(function()
      broken:Enable()
    end)
    assert.is_true(brokenScope:IsClosed())
    assert.are.equal(original, target.Refresh)

    steady:Enable()
    TestEnv.Logout()

    assert.is_true(steadyScope:IsClosed())
    assert.are.equal(original, target.Refresh)
  end)

  it("reads nil when HookKit is not loaded", function()
    local ModuleKit = TestEnv.NewPackageWithoutOptionalKits()
    local module = ModuleKit:ForAddon("MyAddon"):CreateModule("Bare")
    local observed = {}
    module.OnEnable = function(self)
      observed.hooks = self.scope.Hooks
    end

    module:Enable()

    assert.are.same({}, observed)
  end)
end)

-- SignalKit is a dependency of the chain (LifecycleKit requires it), so the
-- real addon bus is always on this package's test path.
describe("ModuleKit module scopes over the real SignalKit bus", function()
  local ModuleKit, SignalKit
  before_each(function()
    ModuleKit, _, SignalKit = TestEnv.NewPackage()
  end)
  after_each(TestEnv.Reset)

  it("stops delivering a module's messages once the module is disabled", function()
    local module = ModuleKit:ForAddon("MyAddon"):CreateModule("Listener")
    local bus = SignalKit:ForAddon("MyAddon")
    bus:DeclareTopic("Changed", { arguments = 1 })
    local received = {}
    module.OnEnable = function(self)
      self.scope.Messages:Subscribe("Changed", function(value)
        received[#received + 1] = value
      end)
    end

    module:Enable()
    bus:Publish("Changed", "first")
    module:Disable()
    bus:Publish("Changed", "second")

    assert.are.same({ "first" }, received)
    assert.is_nil(rawget(module.scope, "Messages"))
  end)

  it("subscribes on the bus named after the module's addon", function()
    local module = ModuleKit:ForAddon("MyAddon"):CreateModule("Listener")
    local delivered = 0
    module.OnEnable = function(self)
      self.scope.Messages:Subscribe("Ping", function()
        delivered = delivered + 1
      end)
    end
    module:Enable()

    SignalKit:Bus("OtherAddon", { openTopics = true }):Publish("Ping")
    assert.are.equal(0, delivered)
    local bus = SignalKit:ForAddon("MyAddon")
    bus:DeclareTopic("Ping")
    bus:Publish("Ping")
    assert.are.equal(1, delivered)
  end)

  it("reads nil while the session holds no room for the addon's bus", function()
    for index = 1, 64 do
      assert.is_not_nil(SignalKit:Bus("Filler" .. index))
    end
    local module = ModuleKit:ForAddon("MyAddon"):CreateModule("Listener")
    local observed = {}
    module.OnEnable = function(self)
      observed.messages = self.scope.Messages
    end

    module:Enable()

    assert.are.same({}, observed)
  end)

  it("reads nil for a closed bus and for a SignalKit without buses", function()
    local module = ModuleKit:ForAddon("MyAddon"):CreateModule("Listener")
    local observed = {}
    module.OnEnable = function(self)
      observed[#observed + 1] = self.scope.Messages or false
    end
    SignalKit:ForAddon("MyAddon"):Subscribe("Anything", function() end)
    SignalKit:CloseAddonBus("MyAddon")

    module:Enable()
    module:Disable()
    local bus = rawget(SignalKit, "Bus")
    rawset(SignalKit, "Bus", nil)
    module:Enable()
    rawset(SignalKit, "Bus", bus)

    assert.are.same({ false, false }, observed)
  end)
end)

-- CommandKit is an optional dependency declared in the manifest, so the real
-- `CommandKit:CreateScope()` is on this package's test path.
describe("ModuleKit module scopes over the real CommandKit", function()
  after_each(TestEnv.Reset)

  it("leaves a module's slash command inert once the module is disabled", function()
    local ModuleKit = TestEnv.NewPackage()
    local module = ModuleKit:ForAddon("MyAddon"):CreateModule("Console")
    local runs = 0
    local commands
    module.OnEnable = function(self)
      commands = self.scope.Commands
      commands:Register("console", {
        handler = function()
          runs = runs + 1
        end,
      })
    end

    module:Enable()
    assert.is_true(TestEnv.RunSlash("/console"))
    module:Disable()
    assert.is_true(TestEnv.RunSlash("/console"))

    assert.are.equal(1, runs)
    assert.is_false(commands:IsRegistered("console"))
    assert.is_nil(rawget(module.scope, "Commands"))
  end)

  it("reads nil when CommandKit is not loaded", function()
    local ModuleKit = TestEnv.NewPackageWithoutOptionalKits()
    local module = ModuleKit:ForAddon("MyAddon"):CreateModule("Bare")
    local observed = {}
    module.OnEnable = function(self)
      observed.commands = self.scope.Commands
    end

    module:Enable()

    assert.are.same({}, observed)
  end)
end)

-- CommKit is an optional dependency declared in the manifest, so the real
-- `CommKit:CreateScope()` and its required closure are on this package's test
-- path. It loads after the chain; see `ModuleKitTestEnv.LoadCommKit`.
describe("ModuleKit module scopes over the real CommKit", function()
  after_each(TestEnv.Reset)

  it("disconnects a module's prefix registrations once the module is disabled", function()
    local ModuleKit = TestEnv.NewPackage()
    TestEnv.LoadCommKit()
    local module = ModuleKit:ForAddon("MyAddon"):CreateModule("Sync")
    local comm
    module.OnEnable = function(self)
      comm = self.scope.Comm
      assert.is_not_nil(comm:Register("MySync", function() end))
    end

    module:Enable()
    assert.are.equal(1, comm:GetRegistrationCount())
    module:Disable()

    assert.are.equal(0, comm:GetRegistrationCount())
    assert.is_true(comm:IsClosed())
    assert.is_nil(rawget(module.scope, "Comm"))
  end)

  it("reads nil when CommKit is not loaded", function()
    local ModuleKit = TestEnv.NewPackage()
    local module = ModuleKit:ForAddon("MyAddon"):CreateModule("Bare")
    local observed = {}
    module.OnEnable = function(self)
      observed.comm = self.scope.Comm
    end

    module:Enable()

    assert.are.same({}, observed)
  end)
end)
