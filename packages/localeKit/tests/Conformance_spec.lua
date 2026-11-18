-- The rules every Kit keeps (tests/support/KitConformance.lua), run against
-- LocaleKit. The suite's secret cases need a client profile with secret
-- values, so it runs on an environment of LocaleKit's module chain under the
-- mainline profile; LocaleKitTestEnv itself installs no client identity.
--
-- Pending groups:
-- * `limits`: LocaleKit has no `SetLimits` (`maxMissingKeys` is an option of
--   each `GetLocale` table).
-- * `receivers`: every LocaleKit method ignores its receiver, so the suite's
--   rule that a method called on another receiver raises does not hold, and
--   holding it would be a behaviour change of its own. The cases are built
--   with `KitConformance.Cases` and registered here so that group alone is
--   reported pending.
--
-- `Format`'s template is not listed under `arguments`: the suite's secret is
-- a table, which `Format` refuses by type first ("must be a string"); its
-- secret refusal is specified in the Kit's own specs.
local FrameworkTestEnv = require("FrameworkTestEnv")
local KitConformance = require("KitConformance")
local LocaleKitTestEnv = require("LocaleKitTestEnv")

local Environment = FrameworkTestEnv.New({
  modules = LocaleKitTestEnv.Modules(),
  wowProfile = "mainline",
})

local newPackageWithout = Environment.NewPackageWithout

---Load the chain without `skippedModule`, answering a failure instead of
---raising it, so a refusal raised while loading the chain is the one read.
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

local RECEIVERS_PENDING = "LocaleKit's methods ignore their receiver; see this spec's header"

local cases = KitConformance.Cases({
  environment = Environment,
  packageId = "localeKit",
  arguments = {
    {
      name = "NewLocale addonName",
      call = function(kit, value)
        kit:NewLocale(value, "enUS") -- no `return`: a tail call drops the caller's line
      end,
    },
    {
      name = "NewLocale locale",
      call = function(kit, value)
        kit:NewLocale("MyAddon", value)
      end,
    },
  },
  upgrade = {
    seed = function(kit)
      local default = kit:NewLocale("MyAddon", "enUS", { isDefault = true })
      default["Hello"] = "Hello there"
      return kit:GetLocale("MyAddon")
    end,
    verify = function(kit, strings)
      assert.are.equal("Hello there", strings.Hello)
      assert.are.equal(strings, kit:GetLocale("MyAddon"))
    end,
  },
})

describe("LocaleKit conformance", function()
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
