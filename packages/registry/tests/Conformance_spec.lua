-- Registry takes the `manifest` group of the Kit conformance suite, except its
-- `Registry:Get(packageId, api)` case: Registry is the registry and does not
-- register itself. The other groups do not fit, so the cases are registered
-- here one by one rather than through `KitConformance.Register`:
--   receivers  Registry's methods take `_` and never test their receiver.
--   limits     Registry keeps no package-wide limits.
--   arguments  Registry refuses a secret identifier with the message it gives
--              any malformed one ("must be a non-empty string"), which never
--              names the secret; `SecretValues_spec.lua` tests each refusal.
--   upgrade    an older Registry is the previous owner of the shared state,
--              not an older copy of a Kit; `Parts_spec.lua` loads the revision
--              16 whole file and upgrades over it.
local KitConformance = require("KitConformance")
local FrameworkTestEnv = require("FrameworkTestEnv")
local TestEnv = require("RegistryTestEnv")

-- The core alone, so the subject the suite reads parts from is the core.
local Environment = FrameworkTestEnv.New({
  modules = { "Registry" },
  wowApi = false,
  legacyRegistryState = true,
})

local SKIPPED_MANIFEST_CASE = "Registry:Get(packageId, api) answers the facade"

local cases = KitConformance.Cases({
  environment = Environment,
  packageId = "registry",
})

describe("Registry conformance", function()
  after_each(function()
    Environment.Reset()
    TestEnv.Reset()
  end)

  for _, case in ipairs(cases) do
    if case.group == "manifest" and case.name ~= SKIPPED_MANIFEST_CASE then
      it(case.group .. ": " .. case.name, case.run)
    end
  end
end)
