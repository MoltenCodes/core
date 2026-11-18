local KitConformance = require("KitConformance")
local FrameworkTestEnv = require("FrameworkTestEnv")

-- The conformance suite needs secret values and a named character, which the
-- "mainline" client profile installs.
local ConformanceEnv = FrameworkTestEnv.New({
  modules = { "Registry", "SignalKit", "SchemaKit", "SettingsKit" },
  wowProfile = "mainline",
})

-- SignalKit needs Registry too, so without Registry the chain stops at
-- SignalKit, which names Registry as SettingsKit would. The fixture loads the
-- dependencies unprotected; this answers that refusal as the package's own.
local loadWithout = ConformanceEnv.NewPackageWithout
function ConformanceEnv.NewPackageWithout(skippedModule)
  local ok, loaded, result = pcall(loadWithout, skippedModule)
  if not ok then
    return false, loaded
  end
  return loaded, result
end

---A one-scope schema built with the SchemaKit the environment loaded.
---@return table
local function schema()
  local S = package.loaded["SchemaKit"]
  return { profile = S.table({ fields = { scale = S.optional(S.number(), 1) } }) }
end

KitConformance.Register({ describe = describe, it = it, pending = pending }, {
  environment = ConformanceEnv,
  packageId = "settingsKit",
  limits = {
    maxProfileNameLength = { default = 64, minimum = 64, ceiling = 1024 },
    pathKeyLimit = { default = 32, ceiling = 1024 },
  },
  arguments = {
    {
      name = "Open savedVariable",
      call = function(kit, value)
        kit:Open(value, schema())
      end,
    },
    {
      name = "SetProfile name",
      call = function(kit, value)
        local db = kit:Open("ConformanceDB", schema())
        db:SetProfile(value)
      end,
    },
  },
  upgrade = {
    seed = function(kit)
      local db = kit:Open("ConformanceDB", schema())
      db.profile.scale = 2
      return db
    end,
    verify = function(kit, db)
      assert.are.equal(db, kit:Open("ConformanceDB"))
      assert.are.equal(2, db.profile.scale)
      db.profile.scale = 1.5
      assert.are.equal(1.5, db.profile.scale)
      assert.is_false(pcall(function()
        db.profile.scale = "x"
      end))
    end,
  },
})
