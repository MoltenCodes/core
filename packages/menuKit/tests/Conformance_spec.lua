-- The rules every Kit keeps (tests/support/KitConformance.lua), run against
-- MenuKit on its own test environment. The suite's secret cases ask the
-- environment for `NewSecretValue`; here that installs MenuKitTestEnv's probe
-- and answers one of its secrets, which MenuKit (with no probe at load) asks
-- through the global.
--
-- `limits` is not described: `maxEntries` and `maxDepth` accept any positive
-- integer or `MenuKit.UNBOUNDED`, with no ceiling, and the suite's limits
-- group needs one for every limit.
local KitConformance = require("KitConformance")
local TestEnv = require("MenuKitTestEnv")

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
  packageId = "menuKit",
  arguments = {
    {
      name = "OpenContextMenu entry text",
      call = function(kit, value)
        kit:OpenContextMenu(nil, { { kind = "button", text = value } })
      end,
    },
  },
  upgrade = {
    seed = function(kit)
      kit:SetLimits({ maxExtensions = 100 })
      return 100
    end,
    verify = function(kit, seeded)
      assert.are.equal(seeded, kit:GetLimits().maxExtensions)
    end,
  },
})
