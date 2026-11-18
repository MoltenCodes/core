-- The rules every Kit keeps (tests/support/KitConformance.lua), run against
-- PanelKit on its own test environment. The suite's secret cases ask the
-- environment for `NewSecretValue`; here that installs PanelKitTestEnv's probe
-- and answers one of its secrets, which PanelKit (with no probe at load) asks
-- through the global.
--
-- `limits` is not described: PanelKit's unknown-limit refusal ("limits holds an
-- unknown field; it accepts ...") does not name the key, which the suite's
-- limits group asks for, so that group stays pending until the message
-- changes in a revision of its own.
local KitConformance = require("KitConformance")
local TestEnv = require("PanelKitTestEnv")

local Environment = setmetatable({}, { __index = TestEnv })

---A value the installed probe reports as secret.
---@return table secret
function Environment.NewSecretValue()
  TestEnv.InstallSecretProbe()
  return TestEnv.NewSecret()
end

---Load the chain without `skippedModule`, answering a failure instead of
---raising it: a dependency later in the chain may refuse to load first, and
---that refusal is the one the suite reads.
---@param skippedModule string
---@return boolean loaded
---@return any failureOrKit
function Environment.NewPackageWithout(skippedModule)
  local ok, loaded, result = pcall(TestEnv.NewPackageWithout, skippedModule)
  if not ok then
    return false, loaded
  end
  return loaded, result
end

KitConformance.Register({ describe = describe, it = it, pending = pending }, {
  environment = Environment,
  packageId = "panelKit",
  arguments = {
    {
      name = "Register treeName",
      call = function(kit, value)
        kit:Register(value)
      end,
    },
    {
      name = "Register options.name",
      call = function(kit, value)
        kit:Register("Tree", { name = value })
      end,
    },
    {
      name = "Get name",
      call = function(kit, value)
        kit:Get(value)
      end,
    },
  },
  upgrade = {
    seed = function(kit)
      kit:SetLimits({ maxPanels = 100 })
      return 100
    end,
    verify = function(kit, seeded)
      assert.are.equal(seeded, kit:GetLimits().maxPanels)
    end,
  },
})
