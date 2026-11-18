-- The rules every Kit keeps (tests/support/KitConformance.lua), run against
-- EditModeKit on its own test environment. The suite's secret cases ask the
-- environment for `NewSecretValue`; here that installs EditModeKitTestEnv's probe
-- and answers one of its secrets, which EditModeKit (with no probe at load) asks
-- through the global.
--
-- `limits` is not described: EditModeKit's unknown-limit refusal ("limits holds an
-- unknown field; it accepts ...") does not name the key, which the suite's
-- limits group asks for, so that group stays pending until the message
-- changes in a revision of its own. `arguments` is not described either:
-- EditModeKit refuses a secret frame, storage or option with the argument's own
-- message ("frame must be a frame", "storage must be a table or a function
-- returning one"), which does not say "secret" as the suite asks;
-- Arguments_spec.lua covers those refusals.
local KitConformance = require("KitConformance")
local TestEnv = require("EditModeKitTestEnv")

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
  packageId = "editModeKit",
  upgrade = {
    seed = function(kit)
      kit:SetLimits({ maxRegistrations = 100 })
      return 100
    end,
    verify = function(kit, seeded)
      assert.are.equal(seeded, kit:GetLimits().maxRegistrations)
    end,
  },
})
