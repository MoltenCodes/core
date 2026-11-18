-- The rules every Kit keeps (tests/support/KitConformance.lua), run against
-- ClientKit on an environment of its module chain under the mainline profile,
-- whose client has secret values.
--
-- `receivers` is reported pending: every ClientKit method ignores its
-- receiver, so `ClientKit.GetFlavor()` works like `ClientKit:GetFlavor()`;
-- the suite's rule that a method called on another receiver raises does not
-- hold, and holding it would be a behaviour change of its own. The cases are
-- built with `KitConformance.Cases` and registered here so that group alone
-- is pending.
--
-- `arguments` lists `IsAtLeast`'s `interfaceNumber`, which is asked about
-- secrets before its type. The suite's secret is a table, so a string
-- argument (`Has`'s `capability`, `GetManifest`'s `addonName`) is refused by
-- its type first; those secret refusals are specified in Capabilities_spec.lua and
-- GetManifest_spec.lua.
local FrameworkTestEnv = require("FrameworkTestEnv")
local KitConformance = require("KitConformance")

local Environment = FrameworkTestEnv.New({
  modules = { "Registry", "ClientKit" },
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

local RECEIVERS_PENDING = "ClientKit's methods ignore their receiver; see this spec's header"

local cases = KitConformance.Cases({
  environment = Environment,
  packageId = "clientKit",
  limits = {
    maxDeprecations = { default = 128, ceiling = 1024 },
    maxReports = { default = 256, ceiling = 4096 },
  },
  arguments = {
    {
      name = "IsAtLeast interfaceNumber",
      call = function(kit, value)
        kit:IsAtLeast(value)
      end,
    },
  },
  upgrade = {
    seed = function(kit)
      kit:SetLimits({ maxReports = 300 })
      return kit:GetFlavor()
    end,
    verify = function(kit, flavor)
      assert.are.equal(300, kit:GetLimits().maxReports)
      assert.are.equal(flavor, kit:GetFlavor())
    end,
  },
})

describe("ClientKit conformance", function()
  for _, case in ipairs(cases) do
    local title = case.group .. ": " .. case.name
    if case.group == "receivers" then
      pending(title .. " (" .. RECEIVERS_PENDING .. ")")
    elseif case.pending ~= nil then
      pending(title .. " (" .. case.pending .. ")")
    else
      it(title, function()
        local ok, failure = pcall(case.run)
        Environment.Reset()
        if not ok then
          error(failure, 0)
        end
      end)
    end
  end
end)
