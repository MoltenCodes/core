-- The shared helper blocks MediaKit carries (tooling/shared/lua/), and the
-- in-place upgrade from revision 5, whose file is kept verbatim as a fixture.
local TestEnv = require("MediaKitTestEnv")

local FIXTURE_DIRECTORY = (debug.getinfo(1, "S").source:match("^@(.*[/\\])") or "./") .. "fixtures/"

---Load the committed revision 5 file, the copy an addon embedded before the
---shared blocks, and return what it returns.
---@return table MediaKit
local function loadPreviousRevision()
  local path = FIXTURE_DIRECTORY .. "MediaKit-revision5.lua"
  local file = assert(io.open(path, "r"))
  local text = file:read("*a")
  file:close()
  return assert(loadstring(text, "@" .. path))()
end

---Load MediaKit's dependencies and the client locale, run `beforeLoad`, then
---load `loadKit`'s copy.
---@param beforeLoad fun()|nil
---@param loadKit fun(): table
---@return table MediaKit
local function loadWith(beforeLoad, loadKit)
  TestEnv.NewPackageWithout("MediaKit")
  TestEnv.SetClientLocale(TestEnv.DEFAULT_CLIENT_LOCALE)
  if beforeLoad ~= nil then
    beforeLoad()
  end
  return loadKit()
end

local function requireCurrent()
  return require("MediaKit")
end

---Replace the host's `issecretvalue` with one that reports nothing secret.
local function replaceProbeWithNone()
  -- selene: allow(global_usage)
  rawset(_G, "issecretvalue", function()
    return false
  end)
end

describe("MediaKit shared helpers", function()
  after_each(TestEnv.Reset)

  it("keeps the secret probe it found at load when the global is replaced", function()
    local secret = "Secret Name"
    local MediaKit = loadWith(function()
      TestEnv.InstallSecretProbe(secret)
    end, requireCurrent)
    replaceProbeWithNone()
    TestEnv.expectErrorContaining("MediaKit:Register name must not be a secret value", function()
      MediaKit:Register("statusbar", secret, "Interface\\Pack\\Bar")
    end)
  end)

  it("asks a probe installed after load when there was none at load", function()
    local MediaKit = loadWith(nil, requireCurrent)
    TestEnv.InstallSecretProbe("Secret Name")
    TestEnv.expectErrorContaining("MediaKit:Register name must not be a secret value", function()
      MediaKit:Register("statusbar", "Secret Name", "Interface\\Pack\\Bar")
    end)
  end)

  it("keeps the facade message of the shared validateFacade", function()
    local MediaKit = loadWith(nil, requireCurrent)
    TestEnv.expectErrorContaining(
      "MediaKit:GetLimits must be called on the MediaKit facade; use MediaKit:GetLimits(...)",
      function()
        MediaKit.GetLimits({})
      end
    )
  end)

  it("refuses a secret receiver with the facade message, at the caller", function()
    local secret = {}
    local MediaKit = loadWith(function()
      TestEnv.InstallSecretProbe(secret)
    end, requireCurrent)
    TestEnv.expectErrorContaining(
      "MediaKit:GetLimits must be called on the MediaKit facade; use MediaKit:GetLimits(...)",
      function()
        MediaKit.GetLimits(secret)
      end
    )
  end)

  it("upgrades in place over revision 5: media, limits and the new probe rule", function()
    local secret = "Secret Name"
    local older = loadWith(function()
      TestEnv.InstallSecretProbe(secret)
    end, loadPreviousRevision)
    assert.are.equal(5, older.REVISION)
    older:Register("statusbar", "Kept", "Interface\\Pack\\Kept")
    older:SetLimits({ maxConsumers = 7 })

    local MediaKit = require("MediaKit")
    assert.are.equal(older, MediaKit)
    assert.are.equal(6, MediaKit.REVISION)
    assert.are.equal(7, MediaKit:GetLimits().maxConsumers)
    assert.are.equal("Interface\\Pack\\Kept", MediaKit:Fetch("statusbar", "Kept"))

    replaceProbeWithNone()
    TestEnv.expectErrorContaining("MediaKit:Register name must not be a secret value", function()
      MediaKit:Register("statusbar", secret, "Interface\\Pack\\Bar")
    end)
  end)
end)
