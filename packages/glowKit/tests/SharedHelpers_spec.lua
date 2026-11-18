-- The shared helper blocks GlowKit carries (tooling/shared/lua/), and the
-- in-place upgrade from revision 1, whose file is kept verbatim as a fixture.
local TestEnv = require("GlowKitTestEnv")

local FIXTURE_DIRECTORY = (debug.getinfo(1, "S").source:match("^@(.*[/\\])") or "./") .. "fixtures/"

---Load the committed revision 1 file, the copy an addon embedded before the
---shared blocks, and return what it returns.
---@return table GlowKit
local function loadRevisionOne()
  local path = FIXTURE_DIRECTORY .. "GlowKit-revision1.lua"
  local file = assert(io.open(path, "r"))
  local text = file:read("*a")
  file:close()
  return assert(loadstring(text, "@" .. path))()
end

---Load GlowKit's dependencies, run `beforeLoad`, then load `loadKit`'s copy
---and create the screen the glows draw on.
---@param beforeLoad fun()|nil
---@param loadKit fun(): table
---@return table GlowKit
local function loadWith(beforeLoad, loadKit)
  TestEnv.NewPackageWithout("GlowKit")
  if beforeLoad ~= nil then
    beforeLoad()
  end
  local GlowKit = loadKit()
  TestEnv.GetGlobal("CreateFrame")("Frame", "UIParent"):SetSize(1920, 1080)
  return GlowKit
end

local function requireCurrent()
  return require("GlowKit")
end

describe("GlowKit shared helpers", function()
  after_each(TestEnv.Reset)

  it("keeps the secret probe it found at load when the global is replaced", function()
    local GlowKit = loadWith(TestEnv.InstallSecretProbe, requireCurrent)
    local secret = TestEnv.NewSecret()
    TestEnv.SetGlobal("issecretvalue", function()
      return false
    end)
    TestEnv.expectErrorContaining("limits.maxGlows must not be a secret value", function()
      GlowKit:SetLimits({ maxGlows = secret })
    end)
  end)

  it("asks a probe installed after load when there was none at load", function()
    local GlowKit = loadWith(nil, requireCurrent)
    TestEnv.InstallSecretProbe()
    TestEnv.expectErrorContaining("limits.maxGlows must not be a secret value", function()
      GlowKit:SetLimits({ maxGlows = TestEnv.NewSecret() })
    end)
  end)

  it("keeps the facade message of the shared validateFacade", function()
    local GlowKit = loadWith(nil, requireCurrent)
    TestEnv.expectErrorContaining(
      "GlowKit:GetLimits must be called on the GlowKit facade; use GlowKit:GetLimits(...)",
      function()
        GlowKit.GetLimits({})
      end
    )
  end)

  it("upgrades in place over revision 1: glows, limits and the new probe rule", function()
    local older = loadWith(TestEnv.InstallSecretProbe, loadRevisionOne)
    assert.are.equal(1, older.REVISION)
    local button = TestEnv.FrameAt(0, 0)
    local glow = older:Start(button, { lines = 1, frequency = 1 })
    older:SetLimits({ maxGlows = 100 })

    local GlowKit = require("GlowKit")
    assert.are.equal(older, GlowKit)
    assert.are.equal(2, GlowKit.REVISION)
    assert.are.equal(100, GlowKit:GetLimits().maxGlows)
    assert.is_true(glow:IsActive())

    local secret = TestEnv.NewSecret()
    TestEnv.SetGlobal("issecretvalue", function()
      return false
    end)
    TestEnv.expectErrorContaining("limits.maxGlows must not be a secret value", function()
      GlowKit:SetLimits({ maxGlows = secret })
    end)
    assert.is_true(GlowKit:Stop(button))
    assert.are.equal(0, GlowKit._state.pool:GetActiveCount())
  end)
end)
