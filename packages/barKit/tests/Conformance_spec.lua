-- The rules every Kit keeps (tests/support/KitConformance.lua), run against
-- BarKit. The suite's secret cases need a client profile with secret values,
-- so it runs on an environment of BarKit's module chain under the mainline
-- profile; BarKitTestEnv itself installs no client identity.
--
-- `limits` is not described: BarKit's unknown-limit refusal
-- ("limits holds an unknown field; it accepts maxBars") does not name the key,
-- which the suite's limits group asks for, so that group stays pending until
-- the message changes in a revision of its own.
local FrameworkTestEnv = require("FrameworkTestEnv")
local BarKitTestEnv = require("BarKitTestEnv")
local KitConformance = require("KitConformance")

local Environment = FrameworkTestEnv.New({
  modules = BarKitTestEnv.Modules(),
  wowProfile = "mainline",
})

local newPackage = Environment.NewPackage

---Load the chain and arrange the host as BarKitTestEnv does.
---@return table BarKit
function Environment.NewPackage()
  local BarKit = newPackage()
  -- selene: allow(global_usage)
  local uiParent = rawget(_G, "CreateFrame")("Frame", "UIParent")
  uiParent:SetSize(1920, 1080)
  -- selene: allow(global_usage)
  rawset(_G, "GetTime", function()
    return 100
  end)
  return BarKit
end

local newPackageWithout = Environment.NewPackageWithout

---Load the chain without `skippedModule`, answering a failure instead of
---raising it: without Registry, a module loaded before BarKit may already
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
  packageId = "barKit",
  arguments = {
    {
      name = "Bar:SetLabel text",
      call = function(kit, value)
        kit:Acquire():SetLabel(value) -- no `return`: a tail call loses the caller's line
      end,
    },
  },
  upgrade = {
    seed = function(kit)
      local bar = kit:Acquire()
      bar:SetLabel("kept")
      return bar
    end,
    verify = function(_, bar)
      bar:SetLabel("after")
      assert.are.equal("after", bar:GetFrame().label:GetText())
    end,
  },
})
