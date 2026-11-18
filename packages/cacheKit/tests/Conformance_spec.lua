-- The rules every Kit keeps (tests/support/KitConformance.lua), run against
-- CacheKit. The suite's secret cases need a client profile with secret values,
-- so it runs on an environment of CacheKit's module chain under the mainline
-- profile; CacheKitTestEnv itself installs no client identity.
--
-- `limits` is not described: CacheKit folds a secret `maxQueueCapacity` into
-- its range message ("must be an integer from 1 to 65536") instead of naming
-- it secret, as the suite's limits group asks; Limits_spec.lua and
-- SharedHelpers_spec.lua specify that refusal. `arguments` is not described
-- for the same reason: every secret argument CacheKit checks (a size, an age,
-- `overflow`) is refused with that argument's invalid-value message
-- (docs/API.md, "Secret values"). Changing either message is a revision of
-- its own (docs/records/shared-helpers.md, D1).
local FrameworkTestEnv = require("FrameworkTestEnv")
local CacheKitTestEnv = require("CacheKitTestEnv")
local KitConformance = require("KitConformance")

local Environment = FrameworkTestEnv.New({
  modules = CacheKitTestEnv.Modules(),
  wowProfile = "mainline",
})

local newPackageWithout = Environment.NewPackageWithout

---Load the chain without `skippedModule`, answering a failure instead of
---raising it: a dependency loaded before CacheKit may refuse to load first,
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
  packageId = "cacheKit",
  upgrade = {
    seed = function(kit)
      local cache = kit:NewLru({ maxEntries = 4 })
      cache:Set("kept", 1)
      return cache
    end,
    verify = function(_, cache)
      assert.are.equal(1, cache:Get("kept"))
    end,
  },
})
