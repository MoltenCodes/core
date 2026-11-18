-- The rules every Kit keeps (tests/support/KitConformance.lua), run against
-- BridgeKit. The suite's secret cases need a client profile with secret
-- values, so it runs on an environment of BridgeKit's module chain under the
-- mainline profile.
--
-- `arguments` lists `AceSerialize`'s values, which take any type. The suite's
-- secret is a table, so a string argument (`AceDeserialize` text, an app or
-- addon name, a prefix) is refused by its type first, without "secret" in the
-- message; those secret refusals are specified in the Kit's own specs.
local FrameworkTestEnv = require("FrameworkTestEnv")
local KitConformance = require("KitConformance")

local Environment = FrameworkTestEnv.New({
  modules = { "Registry", "BridgeKit" },
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
  packageId = "bridgeKit",
  limits = {
    maxDepth = { default = 16, ceiling = 128 },
    maxValues = { default = 65536, ceiling = 2 ^ 24, unbounded = true },
    maxStringLength = { default = 65536, ceiling = 2 ^ 30, unbounded = true },
    maxTextBytes = { default = 1048576, ceiling = 2 ^ 26 },
    maxListValues = { default = 4096, ceiling = 7900 },
    maxReportEntries = { default = 1024, ceiling = 2 ^ 24, unbounded = true },
    maxImportEntries = { default = 65536, ceiling = 2 ^ 30, unbounded = true },
    maxAceStreams = { default = 64, ceiling = 1024 },
    maxAceStreamsPerSender = { default = 4, ceiling = 64 },
    maxAceStreamBytes = { default = 65536, ceiling = 1048576 },
    maxAceSpoolBytes = { default = 1048576, ceiling = 2 ^ 26 },
    aceStreamTimeout = { default = 30, ceiling = 600 },
    maxDropReportSenders = { default = 64, ceiling = 1024 },
  },
  arguments = {
    {
      name = "AceSerialize value",
      call = function(kit, value)
        kit:AceSerialize(value)
      end,
    },
  },
  upgrade = {
    seed = function(kit)
      kit:SetLimits({ maxDepth = 9 })
      local _, text = kit:AceSerialize({ kept = true })
      return text
    end,
    verify = function(kit, text)
      assert.are.equal(9, kit:GetLimits().maxDepth)
      assert.are.same({ true, { kept = true } }, { kit:AceDeserialize(text) })
    end,
  },
})
