local KitConformance = require("KitConformance")
local FrameworkTestEnv = require("FrameworkTestEnv")

-- The rules every Kit keeps (docs/TESTING.md, "The conformance suite"), on a
-- client profile with secret values. The chain carries SignalKit only because
-- the committed revision 22, which the upgrade group loads, required it; the
-- core of this revision does not.
local ConformanceEnv = FrameworkTestEnv.New({
  modules = { "Registry", "SignalKit", "EventKit" },
  wowProfile = "mainline",
})

-- SignalKit needs Registry too, so the "without Registry" case leaves both
-- out: what it proves is that EventKit itself names Registry.
local loadWithout = ConformanceEnv.NewPackageWithout
function ConformanceEnv.NewPackageWithout(skippedModule)
  if skippedModule ~= "Registry" then
    return loadWithout(skippedModule)
  end
  ConformanceEnv.Reset()
  ConformanceEnv.InstallWowApi()
  return pcall(require, "EventKit")
end

KitConformance.Register({ describe = describe, it = it, pending = pending }, {
  environment = ConformanceEnv,
  packageId = "eventKit",
  limits = {
    maxUnitFrames = { default = 64, ceiling = 512 },
  },
  -- Neither reads an argument, so neither has one to refuse: `CreateScope`
  -- builds a manual scope and `IsCombatLogAvailable` answers for the client.
  receiverExempt = { "CreateScope", "IsCombatLogAvailable" },
  arguments = {
    {
      name = "Connect eventName",
      call = function(kit, value)
        kit:Connect(value, function() end)
      end,
    },
    {
      name = "Once eventName",
      call = function(kit, value)
        kit:Once(value, function() end)
      end,
    },
    {
      name = "ForAddon addonName",
      call = function(kit, value)
        kit:ForAddon(value)
      end,
    },
    {
      name = "CloseAddonScopes addonName",
      call = function(kit, value)
        kit:CloseAddonScopes(value)
      end,
    },
    {
      name = "HasPart name",
      call = function(kit, value)
        kit:HasPart(value)
      end,
    },
  },
  upgrade = {
    seed = function(kit)
      local calls = { count = 0 }
      kit:ForAddon("MyAddon"):Connect("PLAYER_LOGIN", function()
        calls.count = calls.count + 1
      end)
      return calls
    end,
    verify = function(kit, calls)
      ConformanceEnv.Emit("PLAYER_LOGIN")
      assert.are.equal(1, calls.count)
      assert.is_true(kit:CloseAddonScopes("MyAddon"))
    end,
  },
})
