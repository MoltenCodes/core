-- PoolKit takes the conformance suite's `manifest` (each part's revision
-- included), `receivers`, `arguments` and `upgrade` groups. `limits` does not
-- apply: PoolKit bounds each pool through its own options and keeps no
-- package-wide limits, so it has no `SetLimits`; the cases are registered
-- one by one rather than through `KitConformance.Register`, which would list
-- that group as pending.
local KitConformance = require("KitConformance")
local FrameworkTestEnv = require("FrameworkTestEnv")

-- The core on a client profile with secret values, so the subject is the core.
local Environment = FrameworkTestEnv.New({
  modules = { "Registry", "PoolKit" },
  wowProfile = "mainline",
})

local cases = KitConformance.Cases({
  environment = Environment,
  packageId = "poolKit",
  arguments = {
    {
      name = "New maxRetained",
      call = function(kit, value)
        kit:New({
          create = function()
            return {}
          end,
          maxRetained = value,
        })
      end,
    },
    {
      name = "NewTablePool prewarm",
      call = function(kit, value)
        kit:NewTablePool({ prewarm = value })
      end,
    },
    {
      name = "HasPart name",
      call = function(kit, value)
        kit:HasPart(value)
      end,
    },
    {
      name = "Pool:Trim retainCount",
      call = function(kit, value)
        kit:NewTablePool():Trim(value)
      end,
    },
  },
  upgrade = {
    seed = function(kit)
      local pool = kit:NewTablePool({ maxRetained = 4 })
      local object = pool:Acquire()
      pool:Release(object)
      return { pool = pool, object = object }
    end,
    verify = function(kit, seeded)
      assert.are.equal(kit.Pool, getmetatable(seeded.pool).__index)
      assert.are.equal(1, seeded.pool:GetAvailableCount())
      assert.are.equal(seeded.object, seeded.pool:Acquire())
      assert.are.equal(4, seeded.pool:GetMaxRetained())
    end,
  },
})

describe("PoolKit conformance", function()
  after_each(function()
    Environment.Reset()
  end)

  for _, case in ipairs(cases) do
    if case.group ~= "limits" then
      if case.pending ~= nil then
        pending(case.group .. ": " .. case.name .. " (" .. case.pending .. ")")
      else
        it(case.group .. ": " .. case.name, case.run)
      end
    end
  end
end)
