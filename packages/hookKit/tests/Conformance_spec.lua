-- The rules every Kit keeps (tests/support/KitConformance.lua), run against
-- HookKit. The suite's secret cases need a client profile with secret values,
-- so it runs on an environment of HookKit's module chain under the mainline
-- profile, with HookKit's host functions installed as HookKitTestEnv does.
--
-- `limits` is not described: HookKit has no `SetLimits` (a scope's `maxHooks`
-- is the owner's own bound). `arguments` is not described: the suite's
-- secret is a table, and every HookKit argument it could reach refuses a
-- table by type before the secret check, with no "secret" in the message.
local FrameworkTestEnv = require("FrameworkTestEnv")
local HookKitTestEnv = require("HookKitTestEnv")
local KitConformance = require("KitConformance")

local Environment = FrameworkTestEnv.New({
  modules = HookKitTestEnv.Modules(),
  wowProfile = "mainline",
})

---Load the chain with `hooksecurefunc`, `issecurevariable` and
---`InCombatLockdown` installed first, which HookKit reads at load.
---@return table HookKit
function Environment.NewPackage()
  Environment.Reset()
  Environment.InstallWowApi()
  HookKitTestEnv.InstallHookApi()
  for _, moduleName in ipairs(Environment.Modules()) do
    require(moduleName)
  end
  return package.loaded["HookKit"]
end

local newPackageWithout = Environment.NewPackageWithout

---Load the chain without `skippedModule`, answering a failure instead of
---raising it, so a refusal raised while loading the chain is the one read.
---@param skippedModule string
---@return boolean loaded
---@return any failureOrKit
function Environment.NewPackageWithout(skippedModule)
  local ok, loaded, result = pcall(newPackageWithout, skippedModule)
  if not ok then
    return false, loaded
  end
  return loaded, result
end

---A target with one method to hook.
---@return table target
local function newTarget()
  local target = {}
  function target.Method() end
  return target
end

KitConformance.Register({ describe = describe, it = it, pending = pending }, {
  environment = Environment,
  packageId = "hookKit",
  upgrade = {
    seed = function(kit)
      local scope = kit:CreateScope()
      local target = newTarget()
      assert.is_true(scope:SecureHook(target, "Method", function() end))
      return { scope = scope, target = target }
    end,
    verify = function(_, seeded)
      assert.is_true(seeded.scope:IsHooked(seeded.target, "Method"))
    end,
  },
})
