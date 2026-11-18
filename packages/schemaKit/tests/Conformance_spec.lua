local KitConformance = require("KitConformance")
local FrameworkTestEnv = require("FrameworkTestEnv")

-- The conformance suite needs secret values, which the "mainline" client
-- profile installs; SchemaKit's own environment installs no client API.
local ConformanceEnv = FrameworkTestEnv.New({
  modules = { "Registry", "SchemaKit" },
  wowProfile = "mainline",
})

KitConformance.Register({ describe = describe, it = it, pending = pending }, {
  environment = ConformanceEnv,
  packageId = "schemaKit",
  -- `limits` stays pending: `defaultArrayMax` accepts any positive integer or
  -- `SchemaKit.UNBOUNDED` and has no ceiling, which the group asserts for
  -- every limit. The three bounded limits (`maxDepth` 1..64,
  -- `maxPatternCaptures` 1..32, `pathKeyLimit` 1..1024) are held by
  -- Limits_spec.lua.
  arguments = {
    {
      name = "GetLimit name",
      call = function(kit, value)
        kit:GetLimit(value)
      end,
    },
    {
      name = "HasPart partName",
      call = function(kit, value)
        kit:HasPart(value)
      end,
    },
  },
  upgrade = {
    seed = function(kit)
      return kit:Seal(kit.table({ fields = { x = kit.number({ min = 0 }) } }))
    end,
    verify = function(kit, schema)
      assert.is_true(schema:Check({ x = 1 }))
      local ok, failure = schema:Check({ x = -1 })
      assert.is_false(ok)
      assert.are.equal("x", failure.path)
      assert.is_true(
        kit:Seal(kit.table({ fields = { inner = schema } })):Check({ inner = { x = 2 } })
      )
    end,
  },
})
