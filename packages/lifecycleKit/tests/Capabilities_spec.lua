local TestEnv = require("LifecycleKitTestEnv")

-- `LifecycleKit.CLOSES_ADDON_SCOPES` is the contract the scope-owning Kits
-- read: a Kit whose package id it names leaves the logout closing of its addon
-- scopes to LifecycleKit, and arranges it itself otherwise (see docs/API.md,
-- "Addon-scope capability").

--- Every package id revision 13 closes at shutdown, in shutdown order.
local CLOSED_PACKAGES = {
  "timerKit",
  "schedulerKit",
  "eventKit",
  "hookKit",
  "commandKit",
  "commKit",
  "signalKit",
}

---Read every listed package id through ordinary indexing, the documented way.
---@param capabilities table
---@return table<string, any>
local function readListed(capabilities)
  local listed = {}
  for index = 1, #CLOSED_PACKAGES do
    local packageId = CLOSED_PACKAGES[index]
    listed[packageId] = capabilities[packageId]
  end
  return listed
end

describe("LifecycleKit.CLOSES_ADDON_SCOPES", function()
  after_each(TestEnv.Reset)

  it("is published on the facade", function()
    local LifecycleKit = TestEnv.NewPackage()
    assert.are.equal("table", type(rawget(LifecycleKit, "CLOSES_ADDON_SCOPES")))
  end)

  it("lists every package whose addon scope or bus shutdown closes", function()
    local LifecycleKit = TestEnv.NewPackage()
    local capabilities = LifecycleKit.CLOSES_ADDON_SCOPES

    assert.are.same({
      timerKit = true,
      schedulerKit = true,
      eventKit = true,
      hookKit = true,
      commandKit = true,
      commKit = true,
      signalKit = true,
    }, readListed(capabilities))
    assert.is_nil(capabilities.lifecycleKit)
    assert.is_nil(capabilities.cacheKit)
  end)

  it("refuses new entries and overwrites of existing ones", function()
    local LifecycleKit = TestEnv.NewPackage()
    local capabilities = LifecycleKit.CLOSES_ADDON_SCOPES

    TestEnv.expectErrorContaining("CLOSES_ADDON_SCOPES is read-only", function()
      capabilities.cacheKit = true
    end)
    TestEnv.expectErrorContaining('field "timerKit" cannot be written', function()
      capabilities.timerKit = false
    end)
    assert.is_true(capabilities.timerKit)
    assert.is_nil(capabilities.cacheKit)
  end)

  it("names a table key by its type at the caller without running its __tostring", function()
    local LifecycleKit = TestEnv.NewPackage()
    local capabilities = LifecycleKit.CLOSES_ADDON_SCOPES
    local ran = false
    local key = setmetatable({}, {
      __tostring = function()
        ran = true
        error("foreign __tostring ran", 0)
      end,
    })
    local source = debug.getinfo(1, "S").short_src
    local callLine
    local ok, message = pcall(function()
      callLine = debug.getinfo(1, "l").currentline + 1
      capabilities[key] = true
    end)
    assert.is_false(ok)
    assert.are.equal(
      source
        .. ":"
        .. callLine
        .. ': LifecycleKit.CLOSES_ADDON_SCOPES is read-only; field "<table>" cannot be written',
      message
    )
    assert.is_false(ran)
  end)

  it("hides its metatable so the view cannot be unsealed", function()
    local LifecycleKit = TestEnv.NewPackage()
    local capabilities = LifecycleKit.CLOSES_ADDON_SCOPES

    assert.is_false(getmetatable(capabilities))
    assert.has_error(function()
      setmetatable(capabilities, nil)
    end)
  end)

  it("keeps one table across a duplicate embedding", function()
    local LifecycleKit = TestEnv.NewPackage()
    local capabilities = LifecycleKit.CLOSES_ADDON_SCOPES

    local reloaded = TestEnv.ReloadPackage()

    assert.are.equal(capabilities, reloaded.CLOSES_ADDON_SCOPES)
    assert.is_true(capabilities.schedulerKit)
  end)

  it("is part of the state an upgrade requires", function()
    local LifecycleKit = TestEnv.NewPackage()
    local state = rawget(LifecycleKit, "_state")

    -- Every revision LifecycleKit upgrades from (18, the upgrade floor) wrote
    -- the capability set; state without it is not one of them.
    rawset(state, "addonScopeCapabilities", nil)
    package.loaded["LifecycleKit"] = nil
    TestEnv.expectErrorContaining("corrupted or incomplete", function()
      require("LifecycleKit")
    end)
  end)

  it("names exactly what shutdown closes", function()
    local LifecycleKit, _, SignalKit, EventKit = TestEnv.NewPackage()
    local HookKit = TestEnv.Module("HookKit")
    local CommandKit = TestEnv.Module("CommandKit")
    local CommKit = TestEnv.LoadCommKit()
    local TimerKit = require("TimerKit")
    local SchedulerKit = require("SchedulerKit")
    local facades = {
      timerKit = TimerKit,
      schedulerKit = SchedulerKit,
      eventKit = EventKit,
      hookKit = HookKit,
      commandKit = CommandKit,
      commKit = CommKit,
    }
    local closed = {}
    for packageId, facade in pairs(facades) do
      local original = rawget(facade, "CloseAddonScopes")
      rawset(facade, "CloseAddonScopes", function(self, addonName)
        closed[packageId] = addonName
        return original(self, addonName)
      end)
    end
    local closeBus = rawget(SignalKit, "CloseAddonBus")
    rawset(SignalKit, "CloseAddonBus", function(self, addonName)
      closed.signalKit = addonName
      return closeBus(self, addonName)
    end)
    LifecycleKit:ForAddon("MyAddon")

    TestEnv.Logout()

    local expected = {}
    for packageId in pairs(readListed(LifecycleKit.CLOSES_ADDON_SCOPES)) do
      expected[packageId] = "MyAddon"
    end
    assert.are.same(expected, closed)
  end)
end)
