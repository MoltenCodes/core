-- SignalKit takes every group of the conformance suite: `manifest` (each
-- part's revision included), `limits` for the three package-wide limits,
-- `receivers`, `arguments` and `upgrade`. `SignalKit.New()` without options is
-- accepted with a dot by design (docs/API.md), so `New` is exempt from the
-- receiver group.
local KitConformance = require("KitConformance")
local FrameworkTestEnv = require("FrameworkTestEnv")

-- The core on a client profile with secret values, so the subject is the core.
local Environment = FrameworkTestEnv.New({
  modules = { "Registry", "SignalKit" },
  wowProfile = "mainline",
  legacyRegistryState = true,
})

KitConformance.Register({ describe = describe, it = it, pending = pending }, {
  environment = Environment,
  packageId = "signalKit",
  limits = {
    maxBuses = { default = 64, ceiling = 1024 },
    maxJournalCapacity = { default = 1024, ceiling = 65536 },
    maxJournalArguments = { default = 8, ceiling = 64 },
  },
  receiverExempt = { "New" },
  arguments = {
    {
      name = "CloseAddonBus addonName",
      call = function(kit, value)
        kit:CloseAddonBus(value)
      end,
    },
    {
      name = "HasPart name",
      call = function(kit, value)
        kit:HasPart(value)
      end,
    },
    {
      name = "Connect methodName",
      call = function(kit, value)
        kit:New():Connect({
          Method = function() end,
        }, value)
      end,
    },
  },
  upgrade = {
    seed = function(kit)
      local signal = kit:New()
      local received = {}
      local connection = signal:Connect(function(value)
        received[#received + 1] = value
      end)
      return { signal = signal, connection = connection, received = received }
    end,
    verify = function(_, seeded)
      seeded.signal:Fire("after")
      assert.are.same({ "after" }, seeded.received)
      assert.is_true(seeded.connection:Disconnect())
    end,
  },
})
