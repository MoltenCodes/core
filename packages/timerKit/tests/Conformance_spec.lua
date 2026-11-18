-- TimerKit's opt-in to the Kit conformance suite (docs/TESTING.md, "The
-- conformance suite"). TimerKit has no limits ("no limits" is a documented
-- rule of the Kit), so that group stays one pending case. `HasPart` refuses a
-- secret name with its own documented message (Parts_spec), so it is not
-- listed under `arguments`, whose cases look for "secret".
local FrameworkTestEnv = require("FrameworkTestEnv")
local KitConformance = require("KitConformance")

-- The secret cases need a client profile with secret values.
local MainlineTestEnv = FrameworkTestEnv.New({
  modules = { "Registry", "TimerKit" },
  wowProfile = "mainline",
})

local function callback() end

KitConformance.Register({ describe = describe, it = it, pending = pending }, {
  environment = MainlineTestEnv,
  packageId = "timerKit",
  -- `CreateScope` takes no argument and ignores its receiver (docs/API.md).
  receiverExempt = { "CreateScope" },
  arguments = {
    {
      name = "After delay",
      call = function(kit, value)
        kit:After(value, callback)
      end,
    },
    {
      name = "Every interval",
      call = function(kit, value)
        kit:Every(value, callback)
      end,
    },
    {
      name = "Scope:After delay",
      call = function(kit, value)
        kit:CreateScope():After(value, callback)
      end,
    },
    {
      name = "After methodName",
      call = function(kit, value)
        kit:After(1, { Tick = callback }, value)
      end,
    },
    {
      name = "ForAddon addonName",
      call = function(kit, value)
        kit:ForAddon(value)
      end,
    },
    {
      name = "CloseAddonScopes addonName",
      call = function(kit, value)
        kit:CloseAddonScopes(value)
      end,
    },
  },
  upgrade = {
    seed = function(kit)
      local scope = kit:ForAddon("Conformance")
      local fired = { count = 0 }
      local ticker = scope:Every(1, function()
        fired.count = fired.count + 1
      end)
      return { scope = scope, ticker = ticker, fired = fired }
    end,
    verify = function(kit, seeded)
      assert.are.equal(seeded.scope, kit:ForAddon("Conformance"))
      assert.is_true(seeded.ticker:IsPending())
      MainlineTestEnv.FireNative(1)
      assert.are.equal(1, seeded.fired.count)
      assert.is_true(kit:CloseAddonScopes("Conformance"))
      assert.is_true(seeded.ticker:IsCancelled())
    end,
  },
})
