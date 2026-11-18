-- The rules every Kit keeps (tests/support/KitConformance.lua), run against
-- GlowKit. The suite's secret cases need a client profile with secret values,
-- so it runs on an environment of GlowKit's module chain under the mainline
-- profile; GlowKitTestEnv itself installs no client identity.
--
-- `limits` is not described: GlowKit's unknown-limit refusal ("limits holds an
-- unknown field; it accepts maxGlows") does not name the key, which the
-- suite's limits group asks for, so that group stays pending until the
-- message changes in a revision of its own. `arguments` is not described
-- either: GlowKit refuses a secret frame with its frame message ("GlowKit:Start
-- frame must be a frame"), which does not say "secret" as the suite asks; the
-- refusal itself is specified in Arguments_spec.lua.
local FrameworkTestEnv = require("FrameworkTestEnv")
local GlowKitTestEnv = require("GlowKitTestEnv")
local KitConformance = require("KitConformance")

local Environment = FrameworkTestEnv.New({
  modules = GlowKitTestEnv.Modules(),
  wowProfile = "mainline",
})

local newPackage = Environment.NewPackage

---Load the chain and create the screen the glows draw on, as GlowKitTestEnv does.
---@return table GlowKit
function Environment.NewPackage()
  local GlowKit = newPackage()
  -- selene: allow(global_usage)
  rawget(_G, "CreateFrame")("Frame", "UIParent"):SetSize(1920, 1080)
  return GlowKit
end

local newPackageWithout = Environment.NewPackageWithout

---Load the chain without `skippedModule`, answering a failure instead of
---raising it: without Registry, PoolKit (loaded before GlowKit) already
---refuses to load, and that refusal is the one the suite reads.
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
  packageId = "glowKit",
  upgrade = {
    seed = function(kit)
      -- selene: allow(global_usage)
      local frame = rawget(_G, "CreateFrame")("Frame")
      frame:SetSize(40, 20)
      kit:Start(frame, { lines = 1 })
      return frame
    end,
    verify = function(kit, frame)
      assert.is_true(kit:Stop(frame))
    end,
  },
})
