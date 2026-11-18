-- The rules every Kit keeps (tests/support/KitConformance.lua), run against
-- ReadinessKit. The suite's secret cases need a client profile with secret
-- values, so it runs on an environment of ReadinessKit's module chain under
-- the mainline profile; ReadinessKitTestEnv itself installs no client identity.
--
-- `limits` is not described: ReadinessKit has no `SetLimits` (a gate's
-- `maxWaiters` is an option of that gate).
local FrameworkTestEnv = require("FrameworkTestEnv")
local KitConformance = require("KitConformance")
local ReadinessKitTestEnv = require("ReadinessKitTestEnv")

local Environment = FrameworkTestEnv.New({
  modules = ReadinessKitTestEnv.Modules(),
  wowProfile = "mainline",
})

local newPackageWithout = Environment.NewPackageWithout

---Load the chain without `skippedModule`, answering a failure instead of
---raising it: a module loaded before ReadinessKit may already refuse to load
---without the skipped one, and that refusal is the one the suite reads.
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

local function notReady()
  return false
end

KitConformance.Register({ describe = describe, it = it, pending = pending }, {
  environment = Environment,
  packageId = "readinessKit",
  arguments = {
    {
      name = "Gate name",
      call = function(kit, value)
        kit:Gate(value, notReady) -- no `return`: a tail call drops the caller's line
      end,
    },
    {
      name = "Get name",
      call = function(kit, value)
        kit:Get(value)
      end,
    },
  },
  upgrade = {
    seed = function(kit)
      return kit:Gate("spells", notReady)
    end,
    verify = function(kit, gate)
      assert.are.equal(gate, kit:Get("spells"))
      assert.is_false(gate:IsReady())
    end,
  },
})
