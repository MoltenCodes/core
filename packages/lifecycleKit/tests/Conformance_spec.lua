-- The rules every Kit keeps (tests/support/KitConformance.lua), run against
-- LifecycleKit's core. The suite's secret cases need a client profile with
-- secret values, so it runs on an environment of LifecycleKit's module chain
-- under the mainline profile. The chain keeps SignalKit: the committed
-- revision 18, which the upgrade group loads first, still requires it.
--
-- The core alone is the subject, so the receivers group meets the stub of
-- `IsInCombat`, which raises at the caller like every other facade method;
-- the CombatGate part's `IsInCombat` takes no receiver, as it never did.
local FrameworkTestEnv = require("FrameworkTestEnv")
local KitConformance = require("KitConformance")
local LifecycleKitTestEnv = require("LifecycleKitTestEnv")

local Environment = FrameworkTestEnv.New({
  modules = LifecycleKitTestEnv.Modules(),
  wowProfile = "mainline",
})

local newPackageWithout = Environment.NewPackageWithout

---Load the chain without `skippedModule`, answering a failure instead of
---raising it: without Registry, SignalKit (loaded before LifecycleKit)
---already refuses to load, and that refusal is the one the suite reads.
---@param skippedModule string
---@return boolean loaded
---@return any failureOrKit
function Environment.NewPackageWithout(skippedModule)
  local ok, loaded, result = pcall(newPackageWithout, skippedModule)
  if not ok then
    return false, loaded
  end
  return loaded, result
end

KitConformance.Register({ describe = describe, it = it, pending = pending }, {
  environment = Environment,
  packageId = "lifecycleKit",
  limits = {
    maxDependencies = { default = 16, ceiling = 2147483647, unbounded = true },
    defaultCombatQueueLimit = { default = 64, ceiling = 2147483647, unbounded = true },
  },
  arguments = {
    {
      name = "ForAddon addonName",
      call = function(kit, value)
        kit:ForAddon(value)
      end,
    },
  },
  upgrade = {
    seed = function(kit)
      kit:SetLimits({ maxDependencies = 5 })
      return kit:ForAddon("MyAddon")
    end,
    verify = function(kit, instance)
      assert.are.equal(instance, kit:ForAddon("MyAddon"))
      assert.are.equal(5, kit:GetLimits().maxDependencies)
      assert.are.equal("loading", instance:GetState())
    end,
  },
})
