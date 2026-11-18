-- The rules every Kit keeps (tests/support/KitConformance.lua), run against
-- CompatKit. The suite's secret cases need a client profile with secret values,
-- so it runs on an environment of CompatKit's module chain under the mainline
-- profile; CompatKitTestEnv itself installs no client identity.
--
-- `limits` is not described: `maxShims`, `maxProviders` and
-- `maxProviderKinds` accept any positive integer or `CompatKit.UNBOUNDED` and
-- have no ceiling, which the suite's limits group asks for
-- (docs/records/shared-helpers.md, D1).
local FrameworkTestEnv = require("FrameworkTestEnv")
local CompatKitTestEnv = require("CompatKitTestEnv")
local KitConformance = require("KitConformance")

local Environment = FrameworkTestEnv.New({
  modules = CompatKitTestEnv.Modules(),
  wowProfile = "mainline",
})

local newPackageWithout = Environment.NewPackageWithout

---Load the chain without `skippedModule`, answering a failure instead of
---raising it: a dependency loaded before CompatKit may refuse to load first,
---and that refusal is the one the suite reads.
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
  packageId = "compatKit",
  arguments = {
    {
      name = "Shim name",
      call = function(kit, value)
        kit:Shim(value, 1, function() end)
      end,
    },
    {
      name = "SkipShim name",
      call = function(kit, value)
        kit:SkipShim(value)
      end,
    },
  },
  upgrade = {
    seed = function(kit)
      kit:Shim("kept", 1, function() end)
      return "kept"
    end,
    verify = function(kit, name)
      assert.are.equal(name, kit:GetShims()[1].name)
    end,
  },
})
