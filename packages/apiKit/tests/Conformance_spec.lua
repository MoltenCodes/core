-- The rules every Kit keeps (tests/support/KitConformance.lua), run against
-- ApiKit. The suite's secret cases need a client profile with secret values,
-- so it runs on an environment of ApiKit's module chain under the mainline
-- profile.
--
-- `limits` is not described: ApiKit has no `SetLimits`, so that group stays
-- pending.
local ApiKitTestEnv = require("ApiKitTestEnv")
local FrameworkTestEnv = require("FrameworkTestEnv")
local KitConformance = require("KitConformance")

local Environment = FrameworkTestEnv.New({
  modules = ApiKitTestEnv.Modules(),
  wowProfile = "mainline",
})

local newPackageWithout = Environment.NewPackageWithout

---Load the chain without `skippedModule`, answering a failure instead of
---raising it, so the suite reads the refusal of whichever module needs it.
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
  packageId = "apiKit",
  arguments = {
    {
      name = "RegisterFlavor flavor",
      call = function(kit, value)
        kit:RegisterFlavor(value, function() end)
      end,
    },
    {
      name = "GetMetadataBuild flavor",
      call = function(kit, value)
        kit:GetMetadataBuild(value)
      end,
    },
  },
  upgrade = {
    seed = function(kit)
      return kit:GetFlavor()
    end,
    verify = function(kit, seeded)
      assert.are.equal(seeded, kit:GetFlavor())
    end,
  },
})
