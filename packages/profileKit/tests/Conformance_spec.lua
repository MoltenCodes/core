-- The rules every Kit keeps (tests/support/KitConformance.lua), run against
-- ProfileKit. The suite's secret cases need a client profile with secret
-- values, so it runs on an environment of ProfileKit's module chain under the
-- mainline profile; ProfileKitTestEnv itself installs no client identity.
--
-- `limits` is not described: `maxSections` accepts any positive integer or
-- `ProfileKit.UNBOUNDED` and has no ceiling, and a secret value is refused
-- with the range message, while the suite's limits group asks for a ceiling
-- and for "secret" in that refusal (docs/records/shared-helpers.md, D1 and
-- the profileKit record); Limits_spec.lua specifies the limit.
--
-- `arguments` is not described: `Section` and `Measure` test a name's type
-- before asking the probe, so the suite's stand-in secret (a table) is refused
-- as "must be a non-empty string" without "secret"; a secret string, the
-- client's form, is refused as secret (SecretValues_spec.lua).
--
-- `receiverExempt` names the five methods that never read their receiver
-- (`Enable`, `Disable`, `IsEnabled`, `Report`, `Reset`), so a dot call runs
-- them instead of raising. That predates this spec and is not documented in
-- docs/API.md; holding them to the receiver rule is a separate fix with its
-- own revision (docs/records/shared-helpers.md, point 7 of the clientKit and
-- localeKit record).
local FrameworkTestEnv = require("FrameworkTestEnv")
local KitConformance = require("KitConformance")
local ProfileKitTestEnv = require("ProfileKitTestEnv")

local Environment = FrameworkTestEnv.New({
  modules = ProfileKitTestEnv.Modules(),
  wowProfile = "mainline",
})

KitConformance.Register({ describe = describe, it = it, pending = pending }, {
  environment = Environment,
  packageId = "profileKit",
  receiverExempt = { "Enable", "Disable", "IsEnabled", "Report", "Reset" },
  upgrade = {
    seed = function(kit)
      kit:SetLimits({ maxSections = 9 })
      return kit:Section("kept")
    end,
    verify = function(kit, section)
      assert.are.equal(section, kit:Section("kept"))
      assert.are.equal(9, kit:GetLimits().maxSections)
    end,
  },
})
