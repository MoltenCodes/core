-- The rules every Kit keeps (tests/support/KitConformance.lua), run against
-- TestKit on an environment of its module chain under the mainline profile.
--
-- Pending groups:
-- * `limits`: TestKit's six limits accept any positive integer or
--   `TestKit.UNBOUNDED` and have no ceiling, which the suite's limits group
--   asks for (docs/records/shared-helpers.md, D1, leaves the ceilings open).
-- * `arguments`: the suite's secret is a table, and every TestKit argument
--   checked for secrets (names, a phase, `ctx:Replace` keys and values) is
--   refused by its type first or is not a facade argument; those refusals
--   are specified in SecretValues_spec.lua.
local FrameworkTestEnv = require("FrameworkTestEnv")
local KitConformance = require("KitConformance")

local Environment = FrameworkTestEnv.New({
  modules = {
    "Registry",
    "SignalKit",
    "EventKit",
    "LifecycleKit",
    "TimerKit",
    "SchedulerKit",
    "TestKit",
  },
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
  packageId = "testKit",
  upgrade = {
    seed = function(kit)
      kit:SetLimits({ maxEqualDepth = 24 })
      return assert(kit:Suite("Carried", { addonName = "MyAddon" }))
    end,
    verify = function(kit, suite)
      assert.are.equal(24, kit:GetLimits().maxEqualDepth)
      assert.is_true(suite:Test("still works", function() end))
      assert.are.same({ nil, "taken" }, { kit:Suite("Carried") })
    end,
  },
})
