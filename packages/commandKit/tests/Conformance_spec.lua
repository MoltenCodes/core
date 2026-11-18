-- CommandKit against the rules every Kit keeps (docs/TESTING.md, "The
-- conformance suite"): the manifest, the package-wide limits, receivers,
-- secret arguments and the in-place upgrade.
--
-- The suite treats the last module of the chain as the Kit, so it gets an
-- environment of its own whose chain is the core's: Registry, then CommandKit.
local FrameworkTestEnv = require("FrameworkTestEnv")
local KitConformance = require("KitConformance")

local ConformanceEnv = FrameworkTestEnv.New({
  modules = { "Registry", "CommandKit" },
  wowProfile = "mainline",
})

-- The upgrade cases load the older revision over the chain without the Kit.
-- The committed previous revision (11) still needs SchemaKit, which the
-- current core does not, so SchemaKit is loaded fresh for the older copy there.
local loadWithout = ConformanceEnv.NewPackageWithout
function ConformanceEnv.NewPackageWithout(skippedModule)
  local loaded, failure = loadWithout(skippedModule)
  if skippedModule == "CommandKit" then
    package.loaded["SchemaKit"] = nil
    require("SchemaKit")
  end
  return loaded, failure
end

KitConformance.Register({ describe = describe, it = it, pending = pending }, {
  environment = ConformanceEnv,
  packageId = "commandKit",
  limits = {
    maxCaptured = { default = 256, ceiling = 2147483647, unbounded = true },
    maxCompletions = { default = 32, ceiling = 256 },
    maxEmotes = { default = 1024, ceiling = 16384 },
    maxCompletionProviders = { default = 32, ceiling = 256 },
  },
  -- No facade argument qualifies (ADR 0002): every one is tested for its
  -- type before anything compares it, and the suite's secret is a table, so
  -- it is refused as "must be a string". Secret strings are refused before
  -- any comparison; SecretValues_spec.lua proves it with a probe of its own.
  arguments = {},
  upgrade = {
    seed = function(kit)
      kit:SetLimits({ maxCaptured = kit.UNBOUNDED, maxCompletions = 16 })
      local scope = kit:CreateScope({ maxCommands = 3 })
      return { scope = scope, unbounded = kit.UNBOUNDED }
    end,
    verify = function(kit, seeded)
      assert.are.equal(seeded.unbounded, kit.UNBOUNDED)
      local limits = kit:GetLimits()
      assert.are.equal(kit.UNBOUNDED, limits.maxCaptured)
      assert.are.equal(16, limits.maxCompletions)
      assert.is_false(seeded.scope:IsClosed())
      assert.are.equal(3, rawget(seeded.scope, "_maxCommands"))
    end,
  },
})
