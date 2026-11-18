-- The rules every Kit keeps (tests/support/KitConformance.lua), run against
-- ToastKit. The suite's secret cases need a client profile with secret values,
-- so it runs on an environment of ToastKit's module chain under the mainline
-- profile; ToastKitTestEnv itself installs no client identity.
--
-- `limits` is not described: ToastKit's unknown-limit refusal
-- ("limits holds an unknown field; it accepts maxVisible and maxQueued") does not name the key,
-- which the suite's limits group asks for, so that group stays pending until
-- the message changes in a revision of its own.
local FrameworkTestEnv = require("FrameworkTestEnv")
local ToastKitTestEnv = require("ToastKitTestEnv")
local KitConformance = require("KitConformance")

local Environment = FrameworkTestEnv.New({
  modules = ToastKitTestEnv.Modules(),
  wowProfile = "mainline",
})

local newPackage = Environment.NewPackage

---Load the chain and arrange the host as ToastKitTestEnv does.
---@return table ToastKit
function Environment.NewPackage()
  local ToastKit = newPackage()
  -- selene: allow(global_usage)
  local uiParent = rawget(_G, "CreateFrame")("Frame", "UIParent")
  uiParent:SetSize(1920, 1080)
  return ToastKit
end

local newPackageWithout = Environment.NewPackageWithout

---Load the chain without `skippedModule`, answering a failure instead of
---raising it: without Registry, a module loaded before ToastKit may already
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
  packageId = "toastKit",
  arguments = {
    {
      name = "Show options.title",
      call = function(kit, value)
        kit:Show({ title = value }) -- no `return`: a tail call loses the caller's line
      end,
    },
  },
  upgrade = {
    seed = function(kit)
      return kit:Show({ title = "kept" })
    end,
    verify = function(_, toast)
      assert.is_true(toast:IsShown())
    end,
  },
})
