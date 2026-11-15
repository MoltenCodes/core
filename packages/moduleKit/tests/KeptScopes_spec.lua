local TestEnv = require("ModuleKitTestEnv")

-- Revision 22: a module keeps its Kit scopes across enable cycles when the
-- Kit can reopen a closed scope, a container skips the blocked-module scan
-- while nothing can be blocked, the halt is read from the LifecycleKit
-- instance's `_halted` field, and a container may choose to raise when a
-- scope field's Kit is not loaded.

---A fake Kit whose scopes can be closed and, when `canReopen`, reopened.
---@param canReopen boolean
---@return table kit
---@return table[] created every scope handed out, in order
local function newKit(canReopen)
  local created = {}
  local kit = {}
  kit.CreateScope = function()
    local scope = { closed = false, reopened = 0 }
    scope.Close = function(self)
      self.closed = true
    end
    if canReopen then
      scope.Reopen = function(self)
        if not self.closed then
          return false
        end
        self.closed = false
        self.reopened = self.reopened + 1
        return true
      end
    end
    created[#created + 1] = scope
    return scope
  end
  return kit, created
end

---Publish a fake Kit under `packageName` API 1.
---@param Registry Registry
---@param packageName string
---@param canReopen boolean
---@return table[] created
local function registerKit(Registry, packageName, canReopen)
  local shared = Registry:Register(packageName, 1, 1)
  local kit, created = newKit(canReopen)
  rawset(shared, "CreateScope", kit.CreateScope)
  return created
end

---Enable `module` with an `OnEnable` that reads `field`, then disable it.
---@param module ModuleKit.Module
---@param field string
local function cycle(module, field)
  module.OnEnable = function(self)
    local _ = self.scope[field]
  end
  module:Enable()
  module:Disable()
end

describe("ModuleKit kept module scopes", function()
  local ModuleKit
  local Registry

  before_each(function()
    local packageUnderTest, registry = TestEnv.NewPackage()
    ModuleKit = packageUnderTest
    Registry = registry
  end)

  after_each(TestEnv.Reset)

  it("reopens the same scope on every enable when the Kit can", function()
    local timers = registerKit(Registry, "timerKit", true)
    local module = ModuleKit:ForAddon("MyAddon"):CreateModule("Tracker")

    cycle(module, "Timers")
    assert.is_true(timers[1].closed)
    cycle(module, "Timers")
    cycle(module, "Timers")

    assert.are.equal(1, #timers)
    assert.are.equal(2, timers[1].reopened)
    assert.is_true(timers[1].closed)
    module:Enable()
    assert.are.equal(timers[1], module.scope.Timers)
    assert.is_false(timers[1].closed)
  end)

  it("creates a fresh scope each time for a Kit without Reopen", function()
    local jobs = registerKit(Registry, "schedulerKit", false)
    local module = ModuleKit:ForAddon("MyAddon"):CreateModule("Tracker")

    cycle(module, "Jobs")
    cycle(module, "Jobs")

    assert.are.equal(2, #jobs)
    assert.is_nil(rawget(module, "_keptScopes"))
  end)

  it("gives up a kept scope whose Reopen refuses or raises", function()
    local timers = registerKit(Registry, "timerKit", true)
    local module = ModuleKit:ForAddon("MyAddon"):CreateModule("Tracker")

    cycle(module, "Timers")
    timers[1].Reopen = function()
      return false, "closed"
    end
    cycle(module, "Timers")
    assert.are.equal(2, #timers)

    timers[2].Reopen = function()
      error("reopen failed")
    end
    module.OnEnable = function(self)
      local _ = self.scope.Timers
    end
    module:Enable()
    assert.are.equal(3, #timers)
    assert.are.equal(timers[3], module.scope.Timers)
  end)

  it("does not keep a scope whose Close raised", function()
    local timers = registerKit(Registry, "timerKit", true)
    local module = ModuleKit:ForAddon("MyAddon"):CreateModule("Tracker")
    module.OnEnable = function(self)
      local scope = self.scope.Timers
      scope.Close = function()
        error("close failed")
      end
    end

    module:Enable()
    assert.has_error(function()
      module:Disable()
    end)
    assert.is_nil(rawget(module, "_keptScopes"))
    assert.are.equal(1, #timers)
  end)

  it("keeps a reference from an earlier period refused while disabled", function()
    local timers = registerKit(Registry, "timerKit", true)
    local module = ModuleKit:ForAddon("MyAddon"):CreateModule("Tracker")
    cycle(module, "Timers")

    -- The scope stays closed until the module reads the field again.
    assert.is_true(timers[1].closed)
    assert.has_error(function()
      local _ = module.scope.Timers
    end)
  end)

  it("reuses the real Kit scopes across enables", function()
    local EventKit = require("EventKit")
    local module = ModuleKit:ForAddon("MyAddon"):CreateModule("Listener")
    local scopes = {}
    local heard = 0
    module.OnEnable = function(self)
      local events = self.scope.Events
      scopes[#scopes + 1] = events
      events:Connect("BAG_UPDATE", function()
        heard = heard + 1
      end)
    end

    module:Enable()
    module:Disable()
    module:Enable()
    TestEnv.Emit("BAG_UPDATE")

    assert.are.equal(1, heard)
    assert.is_true(type(EventKit.Scope.Reopen) ~= "function" or scopes[1] == scopes[2])
    assert.are.equal(1, scopes[2]:GetActiveCount())
  end)

  it("keeps scope.Commands across enables now that CommandKit can reopen it", function()
    local module = ModuleKit:ForAddon("MyAddon"):CreateModule("Slash")
    local scopes = {}
    module.OnEnable = function(self)
      local commands = self.scope.Commands
      scopes[#scopes + 1] = commands
      commands:Register("keptslash", { handler = function() end })
    end

    module:Enable()
    module:Disable()
    assert.is_true(scopes[1]:IsClosed())
    module:Enable()

    assert.are.equal(scopes[1], scopes[2])
    assert.is_true(scopes[2]:IsRegistered("keptslash"))
  end)
end)

describe("ModuleKit blocked-module scan flag", function()
  after_each(TestEnv.Reset)

  it("starts a container with nothing blocked and sets the flag on a block", function()
    local ModuleKit = TestEnv.NewPackage()
    local addon = ModuleKit:ForAddon("MyAddon")
    assert.is_false(rawget(addon, "_mayHaveBlocked"))

    local base = addon:CreateModule("Base")
    local dependent = addon:CreateModule("Dependent", { dependsOn = { "Base" } })
    dependent:Enable()
    assert.is_false(rawget(addon, "_mayHaveBlocked"))

    base:Disable()
    assert.are.equal("Base", dependent:GetEnableState().blockedBy)
    assert.is_true(rawget(addon, "_mayHaveBlocked"))

    -- Recovery brings the dependent back, and the next scan finding nothing
    -- clears the flag.
    base:Enable()
    assert.is_true(dependent:IsEnabled())
    base:Disable()
    base:Enable()
    assert.is_true(dependent:IsEnabled())
    local other = addon:CreateModule("Other")
    other:Enable()
    assert.is_false(rawget(addon, "_mayHaveBlocked"))
  end)

  it("scans a container an older revision made, which has no flag", function()
    local ModuleKit = TestEnv.NewPackage()
    local addon = ModuleKit:ForAddon("MyAddon")
    local base = addon:CreateModule("Base")
    local dependent = addon:CreateModule("Dependent", { dependsOn = { "Base" } })
    dependent:Enable()
    base:Disable()
    -- As an older revision left it: blocked, and no flag.
    rawset(addon, "_mayHaveBlocked", nil)

    base:Enable()

    assert.is_true(dependent:IsEnabled())
  end)
end)

describe("ModuleKit halt read", function()
  after_each(TestEnv.Reset)

  it("refuses an enable once the instance's _halted field is set", function()
    local ModuleKit = TestEnv.NewPackage()
    local LifecycleKit = require("LifecycleKit")
    local addon = ModuleKit:ForAddon("MyAddon")
    local module = addon:CreateModule("Core")
    LifecycleKit:ForAddon("MyAddon"):Halt("broken saved variables")

    assert.has_error(function()
      module:Enable()
    end)
    assert.are.equal("halted", module:GetEnableState().blockedBy)
  end)

  it("treats an instance without the field as not halted", function()
    local ModuleKit = TestEnv.NewPackage()
    local LifecycleKit = require("LifecycleKit")
    local addon = ModuleKit:ForAddon("MyAddon")
    local module = addon:CreateModule("Core")
    -- An instance of a LifecycleKit revision older than halts.
    rawset(LifecycleKit:ForAddon("MyAddon"), "_halted", nil)

    module:Enable()

    assert.is_true(module:IsEnabled())
  end)
end)

describe("ModuleKit missing scope Kit policy", function()
  local ModuleKit

  before_each(function()
    ModuleKit = TestEnv.NewPackageWithoutOptionalKits()
  end)

  after_each(TestEnv.Reset)

  it("answers nil by default", function()
    local addon = ModuleKit:ForAddon("MyAddon")
    assert.are.equal("nil", addon:GetMissingScopePolicy())
    local module = addon:CreateModule("Bare")
    local observed = {}
    module.OnEnable = function(self)
      observed.timers = self.scope.Timers
      observed.hooks = self.scope.Hooks
    end

    module:Enable()

    assert.are.same({}, observed)
    assert.is_nil(rawget(addon, "_missingScopePolicy"))
  end)

  it("raises at the reading line naming the file to embed", function()
    local addon = ModuleKit:ForAddon("MyAddon")
    assert.are.equal("nil", addon:SetMissingScopePolicy("raise"))
    assert.are.equal("raise", addon:GetMissingScopePolicy())
    local module = addon:CreateModule("Strict")
    local source = debug.getinfo(1, "S").short_src
    local line
    local ok, message
    module.OnEnable = function(self)
      ok, message = pcall(function()
        line = debug.getinfo(1, "l").currentline + 1
        return self.scope.Timers
      end)
    end

    module:Enable()

    assert.is_false(ok)
    assert.are.equal(
      source
        .. ":"
        .. line
        .. ': ModuleKit module "Strict" scope.Timers needs TimerKit API 1, which is not loaded;'
        .. " add timerKit\\TimerKit.lua from MoltenCodes to your embeds.xml",
      message
    )
  end)

  it("names each field's Kit and file", function()
    local addon = ModuleKit:ForAddon("MyAddon")
    addon:SetMissingScopePolicy("raise")
    local expected = {
      Comm = "CommKit API 1, which is not loaded; add commKit\\CommKit.lua",
      Commands = "CommandKit API 1, which is not loaded; add commandKit\\CommandKit.lua",
      Hooks = "HookKit API 1, which is not loaded; add hookKit\\HookKit.lua",
      Jobs = "SchedulerKit API 1, which is not loaded; add schedulerKit\\SchedulerKit.lua",
      Timers = "TimerKit API 1, which is not loaded; add timerKit\\TimerKit.lua",
    }
    local module = addon:CreateModule("Strict")
    local messages = {}
    module.OnEnable = function(self)
      for field in pairs(expected) do
        local ok, message = pcall(function()
          return self.scope[field]
        end)
        assert.is_false(ok)
        messages[field] = message
      end
    end

    module:Enable()

    for field, text in pairs(expected) do
      assert.is_truthy(string.find(messages[field], text, 1, true), messages[field])
    end
  end)

  it("raises for a Kit revision without owner scopes", function()
    local packageUnderTest, _, _, EventKit = TestEnv.NewPackage()
    rawset(EventKit, "CreateScope", nil)
    local addon = packageUnderTest:ForAddon("MyAddon")
    addon:SetMissingScopePolicy("raise")
    local module = addon:CreateModule("Strict")
    local ok, message
    module.OnEnable = function(self)
      ok, message = pcall(function()
        return self.scope.Events
      end)
    end

    module:Enable()

    assert.is_false(ok)
    assert.is_truthy(string.find(message, "scope.Events needs EventKit API 1", 1, true))
  end)

  it("keeps reading nil for a bus that cannot be had", function()
    local packageUnderTest = TestEnv.NewPackage()
    local SignalKit = require("SignalKit")
    local addon = packageUnderTest:ForAddon("MyAddon")
    addon:SetMissingScopePolicy("raise")
    -- A bus that was used and then closed refuses new scopes.
    SignalKit:ForAddon("MyAddon"):Subscribe("Anything", function() end)
    SignalKit:CloseAddonBus("MyAddon")
    local module = addon:CreateModule("Strict")
    local observed = "unset"
    module.OnEnable = function(self)
      observed = self.scope.Messages
    end

    module:Enable()

    assert.is_nil(observed)
  end)

  it("returns to the default and leaves no field", function()
    local addon = ModuleKit:ForAddon("MyAddon")
    addon:SetMissingScopePolicy("raise")
    assert.are.equal("raise", addon:SetMissingScopePolicy("nil"))
    assert.is_nil(rawget(addon, "_missingScopePolicy"))
  end)

  it("refuses an unknown or secret policy at the caller's line", function()
    local addon = ModuleKit:ForAddon("MyAddon")
    TestEnv.expectCallerError('policy must be "nil" or "raise"', function()
      addon:SetMissingScopePolicy("strict")
    end)
    TestEnv.expectCallerError('policy must be "nil" or "raise"', function()
      addon:SetMissingScopePolicy(nil)
    end)
  end)
end)

describe("ModuleKit in-place upgrade from revision 21", function()
  after_each(TestEnv.Reset)

  it("keeps an older copy's containers and modules working", function()
    TestEnv.LoadDependencies()
    local previous = TestEnv.LoadRevision(21)
    local addon = previous:ForAddon("MyAddon")
    local base = addon:CreateModule("Base")
    local dependent = addon:CreateModule("Dependent", { dependsOn = { "Base" } })
    dependent:Enable()
    base:Disable()
    -- What revision 21 left: a blocked module, no scan flag, no kept scopes,
    -- no policy.
    rawset(addon, "_mayHaveBlocked", nil)

    local upgraded = require("ModuleKit")

    assert.are.equal(previous, upgraded)
    assert.are.equal(23, upgraded.REVISION)
    assert.are.equal(addon, upgraded:ForAddon("MyAddon"))
    assert.are.equal("nil", addon:GetMissingScopePolicy())
    base:Enable()
    assert.is_true(dependent:IsEnabled())
  end)
end)
