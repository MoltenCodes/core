-- The Kit conformance suite (tests/support/KitConformance.lua): manifest,
-- limits, receivers, secret arguments and the in-place upgrade, tested the
-- same way for every Kit.

local FrameworkTestEnv = require("FrameworkTestEnv")
local KitConformance = require("KitConformance")

-- The core alone, on the `mainline` profile, whose `issecretvalue` reports the
-- values `NewSecretValue` returns. ModuleKit's chain is longer than its own
-- dependencies: SignalKit, EventKit and LifecycleKit all need Registry too.
local environment = FrameworkTestEnv.New({
  modules = { "Registry", "SignalKit", "EventKit", "LifecycleKit", "ModuleKit" },
  wowProfile = "mainline",
})

-- Without Registry nothing of the chain loads, so that case loads ModuleKit
-- alone and lets it name what is missing; every other case is the fixture's.
local newPackageWithout = environment.NewPackageWithout
function environment.NewPackageWithout(skippedModule)
  if skippedModule ~= "Registry" then
    return newPackageWithout(skippedModule)
  end
  environment.Reset()
  environment.InstallWowApi()
  return pcall(require, "ModuleKit")
end

KitConformance.Register({ describe = describe, it = it, pending = pending }, {
  environment = environment,
  packageId = "moduleKit",
  -- LifecycleKit's default `maxDependencies` (16) is the ceiling in force
  -- while LifecycleKit reports it, so `UNBOUNDED` is refused here too.
  limits = { maxRequiredAddons = { default = 16, ceiling = 16 } },
  arguments = {
    {
      name = "ForAddon addonName",
      call = function(kit, value)
        kit:ForAddon(value)
      end,
    },
    {
      name = "FindAddon addonName",
      call = function(kit, value)
        kit:FindAddon(value)
      end,
    },
    {
      name = "HasPart name",
      call = function(kit, value)
        kit:HasPart(value)
      end,
    },
    {
      name = "CreateModule name",
      call = function(kit, value)
        kit:ForAddon("ConformanceAddon"):CreateModule(value)
      end,
    },
  },
  upgrade = {
    seed = function(kit)
      local addon = kit:ForAddon("UpgradeAddon")
      addon:SetDependencyPolicy("strict")
      return { addon = addon, module = addon:CreateModule("UI") }
    end,
    verify = function(kit, seeded)
      assert.are.equal(seeded.addon, kit:ForAddon("UpgradeAddon"))
      assert.are.equal(seeded.module, seeded.addon:GetModule("UI"))
      assert.are.equal("strict", seeded.addon:GetDependencyPolicy())
    end,
  },
})
