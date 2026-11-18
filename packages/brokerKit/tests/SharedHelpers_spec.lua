-- The shared helper blocks BrokerKit carries (tooling/shared/lua/), and the
-- in-place upgrade from revision 3, whose file is kept verbatim as a fixture.
local TestEnv = require("BrokerKitTestEnv")

local FIXTURE_DIRECTORY = (debug.getinfo(1, "S").source:match("^@(.*[/\\])") or "./") .. "fixtures/"

---Load the committed revision 3 file, the copy an addon embedded before the
---shared blocks, and return what it returns.
---@return table BrokerKit
local function loadPreviousRevision()
  local path = FIXTURE_DIRECTORY .. "BrokerKit-revision3.lua"
  local file = assert(io.open(path, "r"))
  local text = file:read("*a")
  file:close()
  return assert(loadstring(text, "@" .. path))()
end

---Load BrokerKit's dependencies, run `beforeLoad`, then load `loadKit`'s copy.
---@param beforeLoad fun()|nil
---@param loadKit fun(): table
---@return table BrokerKit
local function loadWith(beforeLoad, loadKit)
  TestEnv.NewPackageWithout("BrokerKit")
  if beforeLoad ~= nil then
    beforeLoad()
  end
  return loadKit()
end

local function requireCurrent()
  return require("BrokerKit")
end

---Replace the host's `issecretvalue` with one that reports nothing secret.
local function replaceProbeWithNone()
  -- selene: allow(global_usage)
  rawset(_G, "issecretvalue", function()
    return false
  end)
end

describe("BrokerKit shared helpers", function()
  after_each(TestEnv.Reset)

  it("keeps the secret probe it found at load when the global is replaced", function()
    local secret = "Secret Name"
    local BrokerKit = loadWith(function()
      TestEnv.InstallSecretProbe(secret)
    end, requireCurrent)
    replaceProbeWithNone()
    TestEnv.expectErrorContaining("BrokerKit:New name must not be a secret value", function()
      BrokerKit:New(secret)
    end)
  end)

  it("asks a probe installed after load when there was none at load", function()
    local BrokerKit = loadWith(nil, requireCurrent)
    TestEnv.InstallSecretProbe("Secret Name")
    TestEnv.expectErrorContaining("BrokerKit:New name must not be a secret value", function()
      BrokerKit:New("Secret Name")
    end)
  end)

  it("keeps the facade message of the shared validateFacade", function()
    local BrokerKit = loadWith(nil, requireCurrent)
    TestEnv.expectErrorContaining(
      "BrokerKit:GetLimits must be called on the BrokerKit facade; use BrokerKit:GetLimits(...)",
      function()
        BrokerKit.GetLimits({})
      end
    )
  end)

  it("upgrades in place over revision 3: objects, limits and the new probe rule", function()
    local secret = "Secret Name"
    local older = loadWith(function()
      TestEnv.InstallSecretProbe(secret)
    end, loadPreviousRevision)
    assert.are.equal(3, older.REVISION)
    local object = older:New("Kept", { text = "before" })
    older:SetLimits({ maxObjects = 100 })

    local BrokerKit = require("BrokerKit")
    assert.are.equal(older, BrokerKit)
    assert.are.equal(4, BrokerKit.REVISION)
    assert.are.equal(100, BrokerKit:GetLimits().maxObjects)
    assert.are.equal(object, BrokerKit:Get("Kept"))
    object.text = "after"
    assert.are.equal("after", BrokerKit:Get("Kept").text)

    replaceProbeWithNone()
    TestEnv.expectErrorContaining("BrokerKit:New name must not be a secret value", function()
      BrokerKit:New(secret)
    end)
  end)
end)
