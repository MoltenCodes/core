local KitConformance = require("KitConformance")
local DemoKitTestEnv = require("DemoKitTestEnv")

KitConformance.Register({ describe = describe, it = it, pending = pending }, {
  environment = DemoKitTestEnv,
  packageId = "demoKit",
  root = os.getenv("CONFORMANCE_FIXTURE_ROOT"),
  limits = {
    maxItems = { default = 8, ceiling = 64 },
  },
  arguments = {
    {
      name = "Add name",
      call = function(kit, value)
        kit:Add(value)
      end,
    },
  },
  upgrade = {
    seed = function(kit)
      kit:Add("kept")
      return 1
    end,
    verify = function(kit, seeded)
      assert.are.equal(seeded, kit:Count())
    end,
  },
})
