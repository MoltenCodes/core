-- The rules every Kit keeps (tests/support/KitConformance.lua), run against
-- DialogKit. The suite's secret cases need a client profile with secret values,
-- so it runs on an environment of DialogKit's module chain under the mainline
-- profile; DialogKitTestEnv itself installs no client identity.
--
-- `limits` is not described: DialogKit's unknown-limit refusal
-- ("limits holds an unknown field; it accepts maxQueued") does not name the key,
-- which the suite's limits group asks for, so that group stays pending until
-- the message changes in a revision of its own.
local FrameworkTestEnv = require("FrameworkTestEnv")
local DialogKitTestEnv = require("DialogKitTestEnv")
local KitConformance = require("KitConformance")

local Environment = FrameworkTestEnv.New({
  modules = DialogKitTestEnv.Modules(),
  wowProfile = "mainline",
})

local newPackage = Environment.NewPackage

---Load the chain and arrange the host as DialogKitTestEnv does.
---@return table DialogKit
function Environment.NewPackage()
  local DialogKit = newPackage()
  -- selene: allow(global_usage)
  local uiParent = rawget(_G, "CreateFrame")("Frame", "UIParent")
  uiParent:SetSize(1920, 1080)
  -- selene: allow(global_usage)
  rawset(_G, "GetTime", function()
    return 100
  end)
  -- selene: allow(global_usage)
  rawset(_G, "UISpecialFrames", { "ItemRefTooltip" })
  return DialogKit
end

local newPackageWithout = Environment.NewPackageWithout

---Load the chain without `skippedModule`, answering a failure instead of
---raising it: without Registry, a module loaded before DialogKit may already
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
  packageId = "dialogKit",
  arguments = {
    {
      name = "Show options.text",
      call = function(kit, value)
        kit:Show({ text = value }) -- no `return`: a tail call loses the caller's line
      end,
    },
  },
  upgrade = {
    seed = function(kit)
      return kit:Show({ text = "kept" })
    end,
    verify = function(_, dialog)
      assert.is_true(dialog:IsShown())
    end,
  },
})
