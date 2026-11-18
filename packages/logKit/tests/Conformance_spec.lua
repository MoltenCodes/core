-- The rules every Kit keeps (tests/support/KitConformance.lua), run against
-- LogKit. It runs on an environment of LogKit's module chain under the
-- mainline profile, as LogKitTestEnv does, without that environment's chat,
-- slash and probe-steering additions, which the suite does not use.
--
-- `limits` is not described: `maxSinks`, `maxMessageLength` and `maxLoggers`
-- accept any integer in range or `LogKit.UNBOUNDED` and have no ceiling,
-- which the suite's limits group asks for (docs/records/shared-helpers.md,
-- D1).
local FrameworkTestEnv = require("FrameworkTestEnv")
local LogKitTestEnv = require("LogKitTestEnv")
local KitConformance = require("KitConformance")

local Environment = FrameworkTestEnv.New({
  modules = LogKitTestEnv.Modules(),
  wowProfile = "mainline",
})

local newPackageWithout = Environment.NewPackageWithout

---Load the chain without `skippedModule`, answering a failure instead of
---raising it: a dependency loaded before LogKit may refuse to load first,
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
  packageId = "logKit",
  arguments = {
    {
      name = "ForAddon addonName",
      call = function(kit, value)
        kit:ForAddon(value)
      end,
    },
    {
      name = "History addonName",
      call = function(kit, value)
        kit:History(value)
      end,
    },
  },
  upgrade = {
    seed = function(kit)
      local logger = kit:ForAddon("Kept")
      logger:SetLevel("info")
      return logger
    end,
    verify = function(kit, logger)
      assert.are.equal(logger, kit:ForAddon("Kept"))
      assert.are.equal("info", (logger:GetLevel()))
    end,
  },
})
