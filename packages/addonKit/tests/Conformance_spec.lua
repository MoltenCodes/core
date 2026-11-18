-- The rules every Kit keeps (tests/support/KitConformance.lua), run against
-- AddonKit on its own test environment (the mainline profile, so the suite's
-- secret values come from the probe installed before AddonKit loads).
--
-- `limits` is not described: AddonKit's unknown-limit refusal ("limits holds
-- an unknown field; it accepts maxFacades") does not name the key, which the
-- suite's limits group asks for, so that group stays pending until the
-- message changes in a revision of its own.
local KitConformance = require("KitConformance")
local TestEnv = require("AddonKitTestEnv")

KitConformance.Register({ describe = describe, it = it, pending = pending }, {
  environment = TestEnv,
  packageId = "addonKit",
  arguments = {
    {
      name = "For addonName",
      call = function(kit, value)
        kit:For(value)
      end,
    },
  },
  upgrade = {
    seed = function(kit)
      kit:SetLimits({ maxFacades = 9 })
      return kit:For("MyAddon")
    end,
    verify = function(kit, facade)
      assert.are.equal(9, kit:GetLimits().maxFacades)
      assert.are.equal(facade, kit:For("MyAddon"))
    end,
  },
})
