local KitConformance = require("KitConformance")
local FrameworkTestEnv = require("FrameworkTestEnv")

-- The conformance suite needs secret values, which the "mainline" client
-- profile installs. OptionsKit's manifest names SchemaKit's Rules part, so
-- the chain loads it; the subject is the core.
local ConformanceEnv = FrameworkTestEnv.New({
  modules = { "Registry", "SignalKit", "SchemaKit", "SchemaKit-Rules", "OptionsKit" },
  wowProfile = "mainline",
})

-- `NewPackageWithout` loads the rest of the chain unprotected, so a skipped
-- Registry would stop SignalKit before OptionsKit is tried. This chain has
-- dependencies of dependencies; a module that cannot load without the
-- skipped one is left out as well, and only OptionsKit's own load is judged.
local baseNewPackageWithout = ConformanceEnv.NewPackageWithout
function ConformanceEnv.NewPackageWithout(skippedModule)
  if skippedModule == "OptionsKit" then
    return baseNewPackageWithout(skippedModule)
  end
  ConformanceEnv.Reset()
  ConformanceEnv.InstallWowApi()
  local modules = ConformanceEnv.Modules()
  for index = 1, #modules - 1 do
    if modules[index] ~= skippedModule then
      pcall(require, modules[index])
    end
  end
  return pcall(require, "OptionsKit")
end

local function getter()
  return true
end

local function setter() end

KitConformance.Register({ describe = describe, it = it, pending = pending }, {
  environment = ConformanceEnv,
  packageId = "optionsKit",
  -- `limits` stays pending: OptionsKit has no `SetLimits`; its bounds are
  -- `Define` options (Limits_spec.lua).
  -- `GetTrees` takes no argument and reads no receiver: it answers the same
  -- on any receiver, as docs/API.md says.
  receiverExempt = { "GetTrees" },
  arguments = {
    {
      name = "Define addonName",
      call = function(kit, value)
        kit:Define(value, { type = "group", args = {} })
      end,
    },
    {
      name = "Get addonName",
      call = function(kit, value)
        kit:Get(value)
      end,
    },
  },
  upgrade = {
    seed = function(kit)
      return kit:Define("ConformanceAddon", {
        type = "group",
        args = { enabled = { type = "toggle", name = "Enabled", get = getter, set = setter } },
      })
    end,
    verify = function(kit, tree)
      assert.are.equal(tree, kit:Get("ConformanceAddon"))
      assert.is_true(tree:Get("enabled"))
      assert.is_true((tree:Set("enabled", false)))
    end,
  },
})
