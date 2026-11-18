-- The rules every Kit keeps (tests/support/KitConformance.lua), run against
-- BrokerKit. The suite's secret cases need a client profile with secret values,
-- so it runs on an environment of BrokerKit's module chain under the mainline
-- profile; BrokerKitTestEnv itself installs no client identity.
--
-- `limits` is not described: `maxObjects` and `maxAttributes` accept any
-- positive integer or `BrokerKit.UNBOUNDED` and have no ceiling, which the
-- suite's limits group asks for (docs/records/shared-helpers.md, D1).
local FrameworkTestEnv = require("FrameworkTestEnv")
local BrokerKitTestEnv = require("BrokerKitTestEnv")
local KitConformance = require("KitConformance")

local Environment = FrameworkTestEnv.New({
  modules = BrokerKitTestEnv.Modules(),
  wowProfile = "mainline",
})

local newPackageWithout = Environment.NewPackageWithout

---Load the chain without `skippedModule`, answering a failure instead of
---raising it: a dependency loaded before BrokerKit may refuse to load first,
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
  packageId = "brokerKit",
  arguments = {
    {
      name = "New name",
      call = function(kit, value)
        kit:New(value)
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
      return kit:New("Kept", { text = "seeded" })
    end,
    verify = function(kit, object)
      assert.are.equal(object, kit:Get("Kept"))
      assert.are.equal("seeded", object.text)
    end,
  },
})
