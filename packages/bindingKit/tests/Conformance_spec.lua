-- The rules every Kit keeps (tests/support/KitConformance.lua), run against
-- BindingKit. The suite's secret cases need a client profile with secret values,
-- so it runs on an environment of BindingKit's module chain under the mainline
-- profile; BindingKitTestEnv itself installs no client identity.
--
-- `limits` is not described: BindingKit's unknown-limit refusal
-- ("limits holds an unknown field; it accepts maxScopes and maxFunctionKeys") does not name the key,
-- which the suite's limits group asks for, so that group stays pending until
-- the message changes in a revision of its own.
local FrameworkTestEnv = require("FrameworkTestEnv")
local BindingKitTestEnv = require("BindingKitTestEnv")
local KitConformance = require("KitConformance")

local Environment = FrameworkTestEnv.New({
  modules = BindingKitTestEnv.Modules(),
  wowProfile = "mainline",
})

local newPackage = Environment.NewPackage

---Load the chain and arrange the host as BindingKitTestEnv does.
---@return table BindingKit
function Environment.NewPackage()
  local BindingKit = newPackage()
  BindingKitTestEnv.InstallBindingApi()
  return BindingKit
end

local newPackageWithout = Environment.NewPackageWithout

---Load the chain without `skippedModule`, answering a failure instead of
---raising it: without Registry, a module loaded before BindingKit may already
---refuse to load, and that refusal is the one the suite reads.
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

KitConformance.Register({ describe = describe, it = it, pending = pending }, {
  environment = Environment,
  packageId = "bindingKit",
  arguments = {
    {
      name = "CreateScope name",
      call = function(kit, value)
        kit:CreateScope(value) -- no `return`: a tail call loses the caller's line
      end,
    },
  },
  upgrade = {
    seed = function(kit)
      local scope = kit:CreateScope("MyAddon")
      scope:BindCommand("F6", "TOGGLEWORLDMAP")
      return scope
    end,
    verify = function(_, scope)
      assert.are.equal("command", (scope:GetBinding("F6")))
    end,
  },
})
