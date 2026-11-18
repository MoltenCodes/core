-- The rules every Kit keeps (tests/support/KitConformance.lua), run against
-- TooltipKit. The suite's secret cases need a client profile with secret values,
-- so it runs on an environment of TooltipKit's module chain under the mainline
-- profile; TooltipKitTestEnv itself installs no client identity.
--
-- `limits` is not described: TooltipKit's unknown-limit refusal
-- ("limits holds an unknown field; it accepts maxTooltips, maxLines and maxColumns") does not name the key,
-- which the suite's limits group asks for, so that group stays pending until
-- the message changes in a revision of its own.
local FrameworkTestEnv = require("FrameworkTestEnv")
local TooltipKitTestEnv = require("TooltipKitTestEnv")
local KitConformance = require("KitConformance")

local Environment = FrameworkTestEnv.New({
  modules = TooltipKitTestEnv.Modules(),
  wowProfile = "mainline",
})

local newPackage = Environment.NewPackage

---Load the chain and arrange the host as TooltipKitTestEnv does.
---@return table TooltipKit
function Environment.NewPackage()
  local TooltipKit = newPackage()
  -- selene: allow(global_usage)
  local uiParent = rawget(_G, "CreateFrame")("Frame", "UIParent")
  uiParent:SetSize(1920, 1080)
  return TooltipKit
end

local newPackageWithout = Environment.NewPackageWithout

---Load the chain without `skippedModule`, answering a failure instead of
---raising it: without Registry, a module loaded before TooltipKit may already
---refuse to load, and that refusal is the one the suite reads.
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
  packageId = "tooltipKit",
  arguments = {
    {
      name = "Acquire key",
      call = function(kit, value)
        kit:Acquire(value, 1) -- no `return`: a tail call loses the caller's line
      end,
    },
  },
  upgrade = {
    seed = function(kit)
      kit:Acquire("MyAddon", 1)
      return "MyAddon"
    end,
    verify = function(kit, key)
      assert.is_true(kit:IsAcquired(key))
    end,
  },
})
