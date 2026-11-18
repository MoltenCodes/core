-- The rules every Kit keeps (tests/support/KitConformance.lua), run against
-- MediaKit. The suite's secret cases need a client profile with secret values,
-- so it runs on an environment of MediaKit's module chain under the mainline
-- profile; MediaKitTestEnv itself installs no client identity. Without
-- `GetLocale` MediaKit takes the Latin script, which no case here depends on.
--
-- `limits` is not described: `maxConsumers` accepts any positive integer or
-- `MediaKit.UNBOUNDED` and has no ceiling, which the suite's limits group asks
-- for (docs/records/shared-helpers.md, D1); Limits_spec.lua specifies both
-- limits.
--
-- `receiverExempt` names the three methods that never read their receiver
-- (`AdoptLibSharedMedia`, `MirrorToLibSharedMedia`, `IsFileDataID`), so a dot
-- call with any receiver runs them instead of raising. That predates this
-- spec and is not documented in docs/API.md; holding them to the receiver
-- rule is a separate fix with its own revision (docs/records/shared-helpers.md,
-- point 7 of the clientKit and localeKit record).
local FrameworkTestEnv = require("FrameworkTestEnv")
local MediaKitTestEnv = require("MediaKitTestEnv")
local KitConformance = require("KitConformance")

local Environment = FrameworkTestEnv.New({
  modules = MediaKitTestEnv.Modules(),
  wowProfile = "mainline",
})

local newPackageWithout = Environment.NewPackageWithout

---Load the chain without `skippedModule`, answering a failure instead of
---raising it: a dependency loaded before MediaKit may refuse to load first,
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
  packageId = "mediaKit",
  receiverExempt = { "AdoptLibSharedMedia", "MirrorToLibSharedMedia", "IsFileDataID" },
  arguments = {
    {
      name = "Register name",
      call = function(kit, value)
        kit:Register("statusbar", value, "Interface\\Pack\\Bar")
      end,
    },
    {
      name = "Fetch name",
      call = function(kit, value)
        kit:Fetch("statusbar", value)
      end,
    },
  },
  upgrade = {
    seed = function(kit)
      kit:Register("statusbar", "Kept", "Interface\\Pack\\Kept")
      return "Kept"
    end,
    verify = function(kit, name)
      assert.are.equal("Interface\\Pack\\Kept", kit:Fetch("statusbar", name))
    end,
  },
})
